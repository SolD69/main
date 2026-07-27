#!/usr/bin/env bash
#
# Резервный канал: AmneziaWG — WireGuard с обфускацией под «неопознанный» UDP.
# Ubuntu 22.04/24.04 (через официальный PPA). Запускать от root.
#
#   bash 03-install-amneziawg.sh              установка + первый пир
#   bash 03-install-amneziawg.sh --peer name  добавить ещё один пир
#
# Держите этот канал на нестандартном UDP-порту как запасной вариант
# на случай прицельного давления на основной Reality-канал.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source ./lib.sh

require_root

AWG_DIR=/etc/amnezia/amneziawg
AWG_IF=awg0
AWG_CONF="${AWG_DIR}/${AWG_IF}.conf"
AWG_PORT="${AWG_PORT:-51820}"
AWG_SUBNET="${AWG_SUBNET:-10.8.1}"
CLIENT_DIR=/root/amneziawg-clients

# Параметры обфускации. Генерируются один раз и должны совпадать
# на сервере и на всех клиентах.
gen_obfuscation() {
    local h=()
    while [[ ${#h[@]} -lt 4 ]]; do
        local v=$(( (RANDOM << 15 | RANDOM) % 2147483000 + 10 ))
        local dup=0 x
        for x in "${h[@]}"; do [[ $x == "$v" ]] && dup=1; done
        (( dup )) || h+=("$v")
    done
    JC=$(( RANDOM % 8 + 3 ))          # 3..10 мусорных пакетов
    JMIN=50
    JMAX=1000
    S1=$(( RANDOM % 100 + 15 ))       # 15..114
    S2=$(( RANDOM % 100 + 15 ))
    # Требование протокола: S1 + 56 не должно совпадать с S2
    while (( S1 + 56 == S2 )); do S2=$(( RANDOM % 100 + 15 )); done
    H1=${h[0]}; H2=${h[1]}; H3=${h[2]}; H4=${h[3]}
}

wan_iface() {
    ip -4 route show default | awk '/default/ {print $5; exit}'
}

next_peer_ip() {
    local last
    last=$(grep -oP "AllowedIPs\s*=\s*${AWG_SUBNET}\.\K[0-9]+" "$AWG_CONF" 2>/dev/null | sort -n | tail -n1)
    printf '%s' "$(( ${last:-1} + 1 ))"
}

add_peer() {
    local name=$1
    [[ $name =~ ^[A-Za-z0-9_.-]+$ ]] || die "Недопустимое имя пира"
    [[ -f "${CLIENT_DIR}/${name}.conf" ]] && die "Пир «$name» уже существует"

    local octet priv pub psk
    octet=$(next_peer_ip)
    (( octet < 255 )) || die "Подсеть ${AWG_SUBNET}.0/24 заполнена"

    priv=$(awg genkey)
    pub=$(awg pubkey <<<"$priv")
    psk=$(awg genpsk)

    cat >> "$AWG_CONF" <<EOF

# peer: ${name}
[Peer]
PublicKey = ${pub}
PresharedKey = ${psk}
AllowedIPs = ${AWG_SUBNET}.${octet}/32
EOF

    # shellcheck disable=SC1090
    source "${AWG_DIR}/obfuscation.env"
    install -d -m 700 "$CLIENT_DIR"
    cat > "${CLIENT_DIR}/${name}.conf" <<EOF
[Interface]
PrivateKey = ${priv}
Address = ${AWG_SUBNET}.${octet}/32
DNS = 1.1.1.1, 8.8.8.8
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

[Peer]
PublicKey = ${SERVER_PUBKEY}
PresharedKey = ${psk}
AllowedIPs = 0.0.0.0/0
Endpoint = ${AWG_SERVER_IP}:${AWG_PORT}
PersistentKeepalive = 25
EOF
    chmod 600 "${CLIENT_DIR}/${name}.conf"

    systemctl restart "awg-quick@${AWG_IF}"

    log "Пир «${name}» добавлен: ${CLIENT_DIR}/${name}.conf"
    echo
    print_qr "$(cat "${CLIENT_DIR}/${name}.conf")"
}

# --- Режим добавления пира к уже установленному серверу ---------------------
if [[ "${1:-}" == "--peer" ]]; then
    [[ -f $AWG_CONF ]] || die "AmneziaWG ещё не установлен, запустите скрипт без аргументов"
    # shellcheck disable=SC1090
    source "${AWG_DIR}/obfuscation.env"
    add_peer "${2:?укажите имя пира}"
    exit 0
fi

# --- Установка --------------------------------------------------------------
[[ -f $AWG_CONF ]] && die "AmneziaWG уже настроен. Новый пир: bash $0 --peer <имя>"

if ! grep -qi ubuntu /etc/os-release; then
    warn "Официальный PPA есть только для Ubuntu."
    warn "На Debian соберите amneziawg из исходников: https://github.com/amnezia-vpn/amneziawg-linux-kernel-module"
    die  "Установка прервана"
fi

log "Подключение репозитория Amnezia"
export DEBIAN_FRONTEND=noninteractive
apt-get -y -qq install software-properties-common qrencode >/dev/null
add-apt-repository -y ppa:amnezia/ppa >/dev/null 2>&1
apt-get update -qq

log "Установка amneziawg (сборка модуля ядра может занять пару минут)"
apt-get -y -qq install amneziawg amneziawg-tools >/dev/null
command -v awg >/dev/null || die "Установка не удалась: команда awg не найдена"

log "Генерация параметров обфускации"
gen_obfuscation
install -d -m 700 "$AWG_DIR"
cat > "${AWG_DIR}/obfuscation.env" <<EOF
JC=${JC}
JMIN=${JMIN}
JMAX=${JMAX}
S1=${S1}
S2=${S2}
H1=${H1}
H2=${H2}
H3=${H3}
H4=${H4}
EOF

SERVER_PRIVKEY=$(awg genkey)
SERVER_PUBKEY=$(awg pubkey <<<"$SERVER_PRIVKEY")
AWG_SERVER_IP=$(detect_public_ip) || die "Не удалось определить внешний IP"
WAN=$(wan_iface)
[[ -n $WAN ]] || die "Не удалось определить внешний интерфейс"

cat >> "${AWG_DIR}/obfuscation.env" <<EOF
SERVER_PUBKEY=${SERVER_PUBKEY}
AWG_SERVER_IP=${AWG_SERVER_IP}
EOF
chmod 600 "${AWG_DIR}/obfuscation.env"

log "Конфигурация интерфейса ${AWG_IF} на ${AWG_SERVER_IP}:${AWG_PORT}/udp"
cat > "$AWG_CONF" <<EOF
[Interface]
Address = ${AWG_SUBNET}.1/24
ListenPort = ${AWG_PORT}
PrivateKey = ${SERVER_PRIVKEY}

Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

PostUp = iptables -t nat -A POSTROUTING -s ${AWG_SUBNET}.0/24 -o ${WAN} -j MASQUERADE
PostUp = iptables -A FORWARD -i %i -j ACCEPT
PostUp = iptables -A FORWARD -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${AWG_SUBNET}.0/24 -o ${WAN} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -j ACCEPT
EOF
chmod 600 "$AWG_CONF"

log "Включение форвардинга пакетов"
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-amneziawg.conf
sysctl -q -w net.ipv4.ip_forward=1

if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw allow "${AWG_PORT}/udp" comment 'AmneziaWG' >/dev/null
fi

log "Запуск awg-quick@${AWG_IF}"
systemctl enable --now "awg-quick@${AWG_IF}" >/dev/null 2>&1
systemctl is-active --quiet "awg-quick@${AWG_IF}" \
    || die "Интерфейс не поднялся: journalctl -u awg-quick@${AWG_IF} -n 50"

add_peer "${CLIENT_NAME:-main}"

cat <<EOF

Импортируйте конфиг в клиент AmneziaVPN (Android, iOS, Windows, macOS, Linux).
Конфиги пиров лежат в ${CLIENT_DIR}, режим 600.

Важно: AllowedIPs = 0.0.0.0/0 означает, что через этот канал пойдёт весь трафик,
включая российские сайты. Если нужен split-routing «РФ напрямую», настройте
раздельное туннелирование в приложении AmneziaVPN или используйте основной
Reality-канал, где маршрутизация задаётся конфигом.
EOF
