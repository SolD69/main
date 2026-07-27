#!/usr/bin/env bash
#
# Проверка доступности VPN-сервера снаружи. Запускать НЕ на сервере,
# а на машине в России — именно оттуда важно знать, что канал жив.
#
#   bash 04-healthcheck.sh <IP> [SNI] [порт]
#
# Коды возврата: 0 — всё в порядке, 1 — сервер недоступен,
# 2 — порт открыт, но TLS-ответ не похож на рабочий Reality.
# Годится для cron или Uptime Kuma в режиме «внешний скрипт».

set -uo pipefail

IP="${1:?укажите IP сервера}"
SNI="${2:-www.samsung.com}"
PORT="${3:-443}"

ok()   { printf '\033[1;32m  ok  \033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m fail \033[0m %s\n' "$*"; }
info() { printf '\033[1;34m  ..  \033[0m %s\n' "$*"; }

status=0

info "Проверка ${IP}:${PORT}, SNI ${SNI}"

# 1. ICMP — необязателен, многие хостеры его режут, поэтому только информационно.
if ping -c2 -W2 "$IP" >/dev/null 2>&1; then
    rtt=$(ping -c4 -W2 "$IP" 2>/dev/null | awk -F'/' '/rtt|round-trip/ {printf "%.0f", $5}')
    ok "ICMP отвечает, RTT ~${rtt} мс"
else
    info "ICMP не проходит (нормально, если хостер режет пинг)"
fi

# 2. TCP-соединение — главный признак блокировки по IP или порту.
if timeout 5 bash -c "exec 3<>/dev/tcp/${IP}/${PORT}" 2>/dev/null; then
    ok "TCP ${PORT} открыт"
else
    bad "TCP ${PORT} недоступен — вероятна блокировка IP или сервер лежит"
    exit 1
fi

# 3. TLS-хендшейк. Рабочий Reality обязан отдать настоящий сертификат
#    сайта-маскировки: для DPI и для нас он выглядит как этот сайт.
handshake=$(timeout 10 openssl s_client -connect "${IP}:${PORT}" -servername "$SNI" \
                -tls1_3 </dev/null 2>/dev/null)

if [[ -z $handshake ]]; then
    bad "TLS-хендшейк не состоялся — DPI может рвать соединение"
    exit 2
fi

if grep -q 'Protocol *: *TLSv1.3' <<<"$handshake" || grep -q 'TLSv1.3' <<<"$handshake"; then
    ok "TLS 1.3 согласован"
else
    bad "TLS 1.3 не согласован"
    status=2
fi

subject=$(grep -m1 '^subject=' <<<"$handshake")
if grep -qi -- "$SNI" <<<"$subject"; then
    ok "Сертификат принадлежит ${SNI} — маскировка работает"
else
    bad "Сертификат не совпадает с ${SNI}: ${subject:-нет данных}"
    bad "Возможна подмена сертификата на пути (MITM со стороны DPI)"
    status=2
fi

verify=$(grep -m1 'Verify return code' <<<"$handshake")
if grep -q 'ok' <<<"$verify"; then
    ok "Цепочка сертификата валидна"
else
    bad "${verify:-цепочка не проверена}"
    status=2
fi

exit "$status"
