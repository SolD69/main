#!/usr/bin/env bash
#
# Базовая защита свежего VPS перед установкой VPN.
# Ubuntu 22.04/24.04, Debian 12. Запускать от root.
#
# Делает: обновление пакетов, unattended-upgrades, фаервол, fail2ban,
# отключение парольного входа по SSH, включение BBR и сетевой тюнинг.

set -euo pipefail

SSH_PORT="${SSH_PORT:-22}"
VPN_PORT="${VPN_PORT:-443}"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запустите от root: sudo bash $0"
command -v apt-get >/dev/null || die "Скрипт рассчитан на Debian/Ubuntu"

# --- Проверяем, что не отрежем себе SSH -------------------------------------
# Отключать пароли безопасно только если у текущего пользователя есть ключ.
authorized_keys_present() {
    local f
    for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
        [[ -s $f ]] && return 0
    done
    return 1
}

log "Обновление списка пакетов"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

log "Установка обновлений безопасности"
apt-get -y -qq upgrade

log "Установка утилит"
apt-get -y -qq install curl ca-certificates jq qrencode ufw fail2ban \
    unattended-upgrades chrony openssl

# --- Автоматические обновления безопасности ---------------------------------
log "Включение автоматических обновлений безопасности"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# --- Фаервол ----------------------------------------------------------------
log "Настройка ufw: открыты ${SSH_PORT}/tcp и ${VPN_PORT}/tcp"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
ufw allow "${VPN_PORT}/tcp" comment 'VPN (Reality)' >/dev/null
ufw --force enable >/dev/null

# --- fail2ban ---------------------------------------------------------------
log "Настройка fail2ban для SSH"
cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled  = true
port     = ${SSH_PORT}
backend  = systemd
maxretry = 4
findtime = 10m
bantime  = 1h
EOF
systemctl enable --now fail2ban >/dev/null 2>&1 || warn "fail2ban не запустился, проверьте вручную"

# --- SSH --------------------------------------------------------------------
if authorized_keys_present; then
    log "Найден SSH-ключ, отключаю вход по паролю"
    cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
Port ${SSH_PORT}
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
MaxAuthTries 3
EOF
    if sshd -t; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd
    else
        rm -f /etc/ssh/sshd_config.d/99-hardening.conf
        warn "Конфиг sshd не прошёл проверку, изменения откачены"
    fi
else
    warn "SSH-ключ не найден — вход по паролю оставлен включённым."
    warn "Добавьте ключ (ssh-copy-id) и перезапустите этот скрипт."
fi

# --- Сетевой тюнинг ---------------------------------------------------------
log "Включение BBR и сетевой тюнинг"
cat > /etc/sysctl.d/99-vpn-tuning.conf <<'EOF'
# Congestion control: заметно улучшает throughput на длинных маршрутах
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Больше одновременных соединений и буферов
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0

# Защита от простейшего спуфинга
net.ipv4.conf.all.rp_filter = 1
net.ipv4.tcp_syncookies = 1
EOF
sysctl --system >/dev/null

if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]]; then
    log "BBR активен"
else
    warn "BBR не включился — вероятно, ядро без поддержки (OpenVZ?)"
fi

log "Готово. Следующий шаг: bash scripts/01-install-reality.sh"
