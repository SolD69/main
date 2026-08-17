#!/usr/bin/env bash
# Общие функции для скриптов комплекта. Подключается через `source`.

XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
STATE_FILE="${STATE_FILE:-/usr/local/etc/xray/reality.env}"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Запустите от root: sudo bash $0"
}

load_state() {
    [[ -f $STATE_FILE ]] || die "Нет $STATE_FILE — сначала выполните scripts/01-install-reality.sh"
    # shellcheck disable=SC1090
    source "$STATE_FILE"
}

# Внешний IPv4 сервера. Сначала спрашиваем у внешнего сервиса,
# при отсутствии сети — берём адрес интерфейса по умолчанию.
detect_public_ip() {
    local ip
    for url in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
        ip=$(curl -4fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]') || true
        [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { printf '%s' "$ip"; return 0; }
    done
    ip=$(ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    [[ -n $ip ]] || return 1
    printf '%s' "$ip"
}

# Проверка кандидата на роль сайта-маскировки: нужен TLS 1.3, ALPN h2
# и отсутствие редиректа на другой домен.
check_dest() {
    local host=$1 out
    out=$(timeout 10 openssl s_client -connect "${host}:443" -servername "$host" \
            -tls1_3 -alpn h2 </dev/null 2>/dev/null) || return 1
    grep -q 'ALPN protocol: h2' <<<"$out" || return 1
    grep -q 'TLSv1.3' <<<"$out" || return 1
    return 0
}

# vless://-ссылка для клиента.
build_link() {
    local uuid=$1 name=$2
    printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s' \
        "$uuid" "$SERVER_IP" "$SERVER_PORT" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$name"
}

print_qr() {
    if command -v qrencode >/dev/null; then
        qrencode -t ANSIUTF8 -m 2 "$1"
    else
        warn "qrencode не установлен — QR-код пропущен (apt install qrencode)"
    fi
}

# Официальный установщик Xray. Канонический адрес на github.com отдаёт редирект
# на raw.githubusercontent.com, который местами обрывается или отвечает 404,
# поэтому зеркала перебираются по очереди. Скачанный скрипт кладётся в $1.
XRAY_INSTALLER_URLS=(
    https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh
    https://raw.githubusercontent.com/XTLS/Xray-install/master/install-release.sh
    https://github.com/XTLS/Xray-install/raw/main/install-release.sh
)

fetch_xray_installer() {
    local tmp=$1 url
    for url in "${XRAY_INSTALLER_URLS[@]}"; do
        printf '    %-70s ' "${url#https://}" >&2
        if curl -fsSL --max-time 60 -o "$tmp" "$url" && [[ -s $tmp ]]; then
            printf 'ok\n' >&2
            return 0
        fi
        printf 'недоступен\n' >&2
    done
    return 1
}

# Установка из релизного архива, без официального скрипта. Нужна потому, что
# raw.githubusercontent.com отдаёт 429 для адресов из «шумных» подсетей, где
# лимиты GitHub делятся с соседями. Релизы лежат на другом хосте и на отдельном
# лимите, а ссылка /releases/latest/download/ обходится без api.github.com.
manual_install_xray() {
    local tmpdir zip
    tmpdir=$(mktemp -d)
    zip="${tmpdir}/xray.zip"

    log "Загрузка релизного архива Xray"
    curl -fsSL --max-time 180 -o "$zip" \
        https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip \
        || { rm -rf "$tmpdir"; return 1; }

    command -v unzip >/dev/null || apt-get -y -qq install unzip >/dev/null
    unzip -q -o "$zip" -d "$tmpdir" || { rm -rf "$tmpdir"; return 1; }
    [[ -f "${tmpdir}/xray" ]] || { rm -rf "$tmpdir"; return 1; }

    install -m 755 "${tmpdir}/xray" /usr/local/bin/xray
    # Файлы геобаз нужны правилам маршрутизации вида geoip:private
    install -d -m 755 /usr/local/share/xray
    install -m 644 "${tmpdir}/geoip.dat" "${tmpdir}/geosite.dat" /usr/local/share/xray/
    install -d -m 755 /usr/local/etc/xray
    rm -rf "$tmpdir"

    # Юнит повторяет официальный: непривилегированный пользователь плюс
    # CAP_NET_BIND_SERVICE, чтобы слушать 443-й порт без прав root.
    cat > /etc/systemd/system/xray.service <<'UNIT'
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    return 0
}

# Основной путь — официальный установщик; при недоступности зеркал ставим
# из релизного архива. Аргумент после имени файла — команда установщика;
# в документированной форме `bash -c "..." @ install` символ «@» лишь
# занимает $0, поэтому при запуске из файла он не нужен.
install_xray_core() {
    local installer
    installer=$(mktemp)
    if fetch_xray_installer "$installer"; then
        bash "$installer" install >/dev/null || warn "Установщик вернул ошибку, проверяю результат"
        rm -f "$installer"
    else
        rm -f "$installer"
        warn "Зеркала установщика недоступны (частая причина — лимит GitHub, HTTP 429)"
        warn "Ставлю Xray напрямую из релизного архива"
        manual_install_xray || die "Не удалось установить Xray.
    Проверьте доступ к GitHub с сервера:
        curl -sI https://github.com
    Либо скачайте архив на своей машине и скопируйте на сервер:
        curl -LO https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
        scp -P 2222 Xray-linux-64.zip root@<IP>:/tmp/"
    fi
    command -v xray >/dev/null \
        || die "Xray не установился. Смотрите вывод выше."
}

restart_xray() {
    if ! xray run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
        die "Конфиг $XRAY_CONFIG не прошёл проверку, перезапуск отменён"
    fi
    systemctl restart xray
    sleep 1
    systemctl is-active --quiet xray || die "Xray не запустился: journalctl -u xray -n 50"
}
