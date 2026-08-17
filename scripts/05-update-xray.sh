#!/usr/bin/env bash
#
# Обновление Xray-core с сохранением конфига и откатом при неудаче.
# Запускайте раз в 1–2 месяца: свежие версии переживают новые эвристики DPI.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source ./lib.sh

require_root
command -v xray >/dev/null || die "Xray не установлен"

before=$(xray version | head -n1)
log "Текущая версия: ${before}"

backup="${XRAY_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$XRAY_CONFIG" "$backup"
log "Конфиг сохранён в ${backup}"

log "Загрузка свежей версии"
install_xray_core

after=$(xray version | head -n1)
log "Версия после обновления: ${after}"

# Установщик мог перезаписать конфиг шаблоном — возвращаем свой.
if ! cmp -s "$backup" "$XRAY_CONFIG"; then
    warn "Конфиг изменился при обновлении, восстанавливаю из бэкапа"
    cp -a "$backup" "$XRAY_CONFIG"
fi

if xray run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
    systemctl restart xray
    sleep 1
    if systemctl is-active --quiet xray; then
        log "Обновление завершено, Xray работает"
        exit 0
    fi
fi

warn "Новая версия не запустилась с текущим конфигом"
warn "Смотрите: journalctl -u xray -n 50"
warn "Откат конфига: cp ${backup} ${XRAY_CONFIG} && systemctl restart xray"
exit 1
