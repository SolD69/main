#!/usr/bin/env bash
#
# Добавление, удаление и просмотр клиентов VLESS-Reality.
# Один ключ (UUID) на одно устройство — так проще отозвать доступ.
#
#   bash 02-add-client.sh phone-ivan     добавить клиента
#   bash 02-add-client.sh --list         показать всех и их ссылки
#   bash 02-add-client.sh --remove name  удалить клиента

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source ./lib.sh

require_root
load_state
command -v jq >/dev/null || die "Нужен jq: apt install jq"
[[ -f $XRAY_CONFIG ]] || die "Нет $XRAY_CONFIG"

clients_json() {
    jq -r '.inbounds[] | select(.tag=="vless-reality") | .settings.clients[] | "\(.email)\t\(.id)"' "$XRAY_CONFIG"
}

usage() {
    sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

case "${1:-}" in
    --list|-l)
        while IFS=$'\t' read -r name uuid; do
            [[ -z $name ]] && continue
            printf '\n\033[1m%s\033[0m\n%s\n' "$name" "$(build_link "$uuid" "$name")"
        done < <(clients_json)
        echo
        ;;

    --remove|-r)
        name="${2:-}"
        [[ -n $name ]] || usage
        clients_json | cut -f1 | grep -qx -- "$name" || die "Клиент «$name» не найден"
        tmp=$(mktemp)
        jq --arg n "$name" '
            (.inbounds[] | select(.tag=="vless-reality") | .settings.clients)
                |= map(select(.email != $n))
        ' "$XRAY_CONFIG" > "$tmp"
        cp -a "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)"
        cat "$tmp" > "$XRAY_CONFIG"
        rm -f "$tmp"
        restart_xray
        log "Клиент «$name» удалён, доступ отозван"
        ;;

    ''|-h|--help)
        usage
        ;;

    *)
        name="$1"
        [[ $name =~ ^[A-Za-z0-9_.-]+$ ]] || die "Имя может содержать только латиницу, цифры, точку, дефис и подчёркивание"
        clients_json | cut -f1 | grep -qx -- "$name" && die "Клиент «$name» уже существует"

        uuid=$(xray uuid)
        tmp=$(mktemp)
        jq --arg id "$uuid" --arg n "$name" '
            (.inbounds[] | select(.tag=="vless-reality") | .settings.clients)
                += [{ id: $id, flow: "xtls-rprx-vision", email: $n }]
        ' "$XRAY_CONFIG" > "$tmp"
        cp -a "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%s)"
        cat "$tmp" > "$XRAY_CONFIG"
        rm -f "$tmp"
        restart_xray

        link=$(build_link "$uuid" "$name")
        printf '\n\033[1;32m[+]\033[0m Клиент «%s» добавлен\n\n%s\n\n' "$name" "$link"
        print_qr "$link"
        echo
        ;;
esac
