#!/usr/bin/env bash
#
# Установка Xray-core и настройка VLESS + XTLS-Reality.
# Ubuntu 22.04/24.04, Debian 12. Запускать от root.
#
# Переменные окружения (все необязательные):
#   DEST=www.samsung.com   сайт-маскировка; по умолчанию подбирается автоматически
#   VPN_PORT=443           порт, на котором слушает Xray
#   CLIENT_NAME=main       имя первого клиента

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source ./lib.sh

require_root

VPN_PORT="${VPN_PORT:-443}"
CLIENT_NAME="${CLIENT_NAME:-main}"

# Кандидаты на маскировку: крупные сайты с TLS 1.3 и HTTP/2, живущие
# на собственной инфраструктуре, а не на CDN общего пользования.
# Порядок — от более к менее предпочтительным для серверов в Европе.
DEST_CANDIDATES=(
    www.samsung.com
    www.nvidia.com
    www.lg.com
    dl.google.com
    www.asus.com
    www.philips.com
    swdist.apple.com
)

command -v apt-get >/dev/null || die "Скрипт рассчитан на Debian/Ubuntu"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get -y -qq install curl openssl jq qrencode ca-certificates

# --- Установка Xray ---------------------------------------------------------
if command -v xray >/dev/null; then
    log "Xray уже установлен: $(xray version | head -n1)"
else
    log "Установка Xray-core"
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" \
        @ install >/dev/null
    command -v xray >/dev/null || die "Установка Xray не удалась"
    log "Установлен: $(xray version | head -n1)"
fi

# --- Выбор сайта-маскировки -------------------------------------------------
if [[ -n ${DEST:-} ]]; then
    log "Проверка заданного сайта-маскировки: $DEST"
    check_dest "$DEST" || die "$DEST не поддерживает TLS 1.3 + h2, выберите другой"
else
    log "Подбор сайта-маскировки"
    for candidate in "${DEST_CANDIDATES[@]}"; do
        printf '    %-22s ' "$candidate"
        if check_dest "$candidate"; then
            printf 'ok\n'
            DEST=$candidate
            break
        fi
        printf 'не подходит\n'
    done
    [[ -n ${DEST:-} ]] || die "Ни один кандидат не прошёл проверку — задайте DEST=... вручную"
fi
log "Маскировка под: $DEST"

# --- Генерация ключей -------------------------------------------------------
log "Генерация ключевой пары X25519"
keypair=$(xray x25519)
# Формат вывода менялся между версиями Xray, поддерживаем оба варианта.
PRIVATE_KEY=$(sed -n -e 's/^[Pp]rivate[ ]*[Kk]ey:[[:space:]]*//p' -e 's/^PrivateKey:[[:space:]]*//p' <<<"$keypair" | head -n1)
PUBLIC_KEY=$(sed -n -e 's/^[Pp]ublic[ ]*[Kk]ey:[[:space:]]*//p' -e 's/^Password:[[:space:]]*//p' <<<"$keypair" | head -n1)
[[ -n $PRIVATE_KEY && -n $PUBLIC_KEY ]] || die "Не удалось разобрать вывод 'xray x25519'"

SHORT_ID=$(openssl rand -hex 8)
CLIENT_UUID=$(xray uuid)

SERVER_IP=$(detect_public_ip) || die "Не удалось определить внешний IP сервера"
log "Внешний адрес сервера: $SERVER_IP"

# --- Конфиг сервера ---------------------------------------------------------
log "Запись конфигурации $XRAY_CONFIG"
install -d -m 755 "$(dirname "$XRAY_CONFIG")"
[[ -f $XRAY_CONFIG ]] && cp -a "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)"

cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${VPN_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${CLIENT_UUID}",
            "flow": "xtls-rprx-vision",
            "email": "${CLIENT_NAME}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}:443",
          "xver": 0,
          "serverNames": ["${DEST}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }
    ]
  }
}
EOF
chmod 600 "$XRAY_CONFIG"

# --- Состояние для остальных скриптов ---------------------------------------
cat > "$STATE_FILE" <<EOF
SERVER_IP=${SERVER_IP}
SERVER_PORT=${VPN_PORT}
SNI=${DEST}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
EOF
chmod 600 "$STATE_FILE"

# --- Фаервол ----------------------------------------------------------------
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw allow "${VPN_PORT}/tcp" comment 'VPN (Reality)' >/dev/null
fi

# --- Запуск -----------------------------------------------------------------
log "Запуск Xray"
systemctl enable xray >/dev/null 2>&1 || true
restart_xray
log "Xray работает на порту ${VPN_PORT}/tcp"

# --- Ссылка для первого клиента ---------------------------------------------
load_state
LINK=$(build_link "$CLIENT_UUID" "$CLIENT_NAME")

cat <<EOF

════════════════════════════════════════════════════════════════
  Сервер готов. Конфигурация клиента «${CLIENT_NAME}»:
════════════════════════════════════════════════════════════════

${LINK}

EOF
print_qr "$LINK"

cat <<EOF

Дальше:
  • импортируйте ссылку в Hiddify / v2rayNG / Streisand;
  • включите на клиенте маршрутизацию «РФ напрямую» — см. templates/client-routing.json;
  • добавьте остальные устройства: bash scripts/02-add-client.sh <имя>;
  • поднимите резервный канал: bash scripts/03-install-amneziawg.sh.

Приватный ключ и конфиг лежат в ${XRAY_CONFIG} (режим 600). Не публикуйте их.
EOF
