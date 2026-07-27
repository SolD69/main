#!/usr/bin/env bash
#
# Сборка полного клиентского конфига Xray со split-routing «РФ напрямую»
# из шаблона templates/client-routing.json.
#
#   bash 06-gen-client-config.sh <имя-клиента> [файл-вывода]
#
# Нужен для Nekoray, v2rayN, Furious и для xray-core на Linux/роутере.
# Мобильным клиентам (Hiddify, v2rayNG, Streisand) достаточно ссылки
# vless:// из 02-add-client.sh — маршрутизация в них настраивается в интерфейсе.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source ./lib.sh

require_root
load_state
command -v jq >/dev/null || die "Нужен jq: apt install jq"

NAME="${1:?укажите имя клиента, например: bash $0 laptop}"
OUT="${2:-/root/xray-${NAME}.json}"
TEMPLATE="../templates/client-routing.json"
[[ -f $TEMPLATE ]] || die "Не найден шаблон $TEMPLATE"

UUID=$(jq -r --arg n "$NAME" '
    .inbounds[] | select(.tag=="vless-reality") | .settings.clients[]
    | select(.email == $n) | .id
' "$XRAY_CONFIG")

[[ -n $UUID && $UUID != "null" ]] \
    || die "Клиент «$NAME» не найден. Создайте его: bash 02-add-client.sh $NAME"

sed -e "s|__SERVER_IP__|${SERVER_IP}|g" \
    -e "s|__UUID__|${UUID}|g" \
    -e "s|__SNI__|${SNI}|g" \
    -e "s|__PUBLIC_KEY__|${PUBLIC_KEY}|g" \
    -e "s|__SHORT_ID__|${SHORT_ID}|g" \
    "$TEMPLATE" > "$OUT"

# Порт в шаблоне зафиксирован как 443 — подставляем реальный, если он другой.
if [[ $SERVER_PORT != 443 ]]; then
    tmp=$(mktemp)
    jq --argjson p "$SERVER_PORT" \
        '(.outbounds[] | select(.tag=="proxy") | .settings.vnext[0].port) = $p' \
        "$OUT" > "$tmp" && mv "$tmp" "$OUT"
fi

jq empty "$OUT" || die "Получился невалидный JSON — проверьте шаблон"
chmod 600 "$OUT"

log "Конфиг записан: ${OUT}"
echo
echo "Скопируйте его на клиентскую машину, например:"
echo "  scp root@${SERVER_IP}:${OUT} ."
echo
echo "Проверка локально (нужен установленный xray):"
echo "  xray run -c $(basename "$OUT")"
echo "Затем настройте систему или браузер на SOCKS5 127.0.0.1:10808."
