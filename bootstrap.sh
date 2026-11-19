#!/usr/bin/env bash
#
# bootstrap.sh — provision a blank Ubuntu 24.04 VPS for the EasyStock ecosystem.
# Provider-agnostic (DigitalOcean, OVH, Hetzner, …). Idempotent: safe to re-run.
#
# Usage (run as root on a fresh box):
#   ssh root@<NEW_SERVER_IP> 'bash -s' < bootstrap.sh
# or copy it up and:  sudo bash bootstrap.sh
#
# Optional env overrides:
#   DEPLOY_USER=deploy   HARDEN_SSH=1   bash bootstrap.sh
#
# What it does:
#   1. Non-root sudo user ("deploy") + copy root's SSH key
#   2. Firewall (ufw): SSH + HTTP + HTTPS only, plus fail2ban
#   3. Time sync (NTP)  — CRITICAL: MC<->Backend HMAC rejects clock drift > 5 min
#   4. Docker Engine + compose plugin; "deploy" runs docker without sudo
#   5. Global container log rotation (so disks don't fill)
#   6. Shared `edge` Docker network + /opt/easystock
#   7. (optional) SSH hardening: key-only, no root  [HARDEN_SSH=1]
#
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
HARDEN_SSH="${HARDEN_SSH:-0}"
log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 1; }

log "1/7  Non-root sudo user: ${DEPLOY_USER}"
id "${DEPLOY_USER}" &>/dev/null || adduser --disabled-password --gecos "" "${DEPLOY_USER}"
usermod -aG sudo "${DEPLOY_USER}"
echo "${DEPLOY_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${DEPLOY_USER}"
chmod 440 "/etc/sudoers.d/90-${DEPLOY_USER}"
# Key source: root's authorized_keys, else the sudo caller's (OVH images have no
# root key — you log in as 'ubuntu' and run this via sudo).
KEY_SRC=/root/.ssh/authorized_keys
[ -f "${KEY_SRC}" ] || KEY_SRC="/home/${SUDO_USER:-nobody}/.ssh/authorized_keys"
if [ -f "${KEY_SRC}" ]; then
  install -d -m 700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"
  install -m 600 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" \
    "${KEY_SRC}" "/home/${DEPLOY_USER}/.ssh/authorized_keys"
else
  echo "WARNING: no authorized_keys found for root or ${SUDO_USER:-<sudo user>} — '${DEPLOY_USER}' will NOT be reachable over SSH." >&2
fi

log "2/7  Firewall (ufw): SSH + web only"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ufw curl ca-certificates
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp   # HTTP/3 — Caddy publishes it
ufw default deny incoming
ufw --force enable

# fail2ban: bans SSH guessers and the scanners Caddy already blocks (the why
# is in fail2ban/jail.d/ezycore.local). The caddy-scanner jail reads Caddy's access log, which does
# not exist until Caddy has run once, so on a blank box this only installs the package.
# Re-run bootstrap after Caddy is up, or copy the two files by hand (see CHANGELOG 2026-11-19).
apt-get install -y fail2ban
F2B_SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/fail2ban"
if [ -d "${F2B_SRC}" ] && [ -f /opt/easystock/infra/logs/access.log ]; then
  install -m 644 "${F2B_SRC}/filter.d/caddy-scanner.conf" /etc/fail2ban/filter.d/
  install -m 644 "${F2B_SRC}/jail.d/ezycore.local" /etc/fail2ban/jail.d/
  fail2ban-client -t && systemctl enable --now fail2ban && systemctl restart fail2ban
else
  echo "NOTE: fail2ban jails NOT installed yet (no repo copy next to this script, or Caddy has not logged yet)." >&2
fi

log "3/7  Time sync (NTP) — HMAC needs clocks within 5 minutes"
timedatectl set-ntp true 2>/dev/null || systemctl enable --now systemd-timesyncd || true
timedatectl status | grep -i 'System clock synchronized' || true

log "4/7  Docker Engine + compose plugin"
command -v docker &>/dev/null || curl -fsSL https://get.docker.com | sh
usermod -aG docker "${DEPLOY_USER}"
systemctl enable --now docker

log "5/7  Global container log rotation"
install -d /etc/docker
cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON
systemctl restart docker

log "6/7  edge network + /opt/easystock"
docker network inspect edge &>/dev/null || docker network create edge
install -d -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" /opt/easystock

if [ "${HARDEN_SSH}" = "1" ]; then
  log "7/7  Hardening SSH (key-only, no root) — make sure you can log in as ${DEPLOY_USER} first!"
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
  systemctl restart ssh 2>/dev/null || systemctl restart sshd || true
else
  log "7/7  SSH hardening skipped (set HARDEN_SSH=1 to enable)"
fi

cat <<EOF

Done. Next steps (as '${DEPLOY_USER}', after re-login so the docker group applies):
  git clone https://github.com/ezycore/easystock-infra.git /opt/easystock
  # add the gitignored secrets the repo does NOT contain:
  #   /opt/easystock/infra/.env            (CLOUDFLARE_API_TOKEN)
  #   /opt/easystock/{staging,production}/.env.backend|.env.mc-api|.env.frontend|.env.mc-admin
  mkdir -p /opt/easystock/backups
  cd /opt/easystock/infra && docker compose up -d --build   # Caddy (custom image w/ Cloudflare DNS)
  cd /opt/easystock/production && docker compose pull && docker compose up -d
See DEPLOYMENT-RUNBOOK.md for the full order + the gotchas.
EOF
