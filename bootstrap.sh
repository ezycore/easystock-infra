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
#   2. Firewall (ufw): SSH + HTTP + HTTPS only
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
if [ -f /root/.ssh/authorized_keys ]; then
  install -d -m 700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"
  install -m 600 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" \
    /root/.ssh/authorized_keys "/home/${DEPLOY_USER}/.ssh/authorized_keys"
fi

log "2/7  Firewall (ufw): SSH + web only"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ufw curl ca-certificates
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

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
