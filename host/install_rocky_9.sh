#!/usr/bin/env bash
#
# One-time host bootstrap for a VH app VM (Rocky Linux 9).
# Idempotent — safe to re-run.
#
# Usage:  ./install_rocky_9.sh staging|production
#
set -euo pipefail

ENVIRONMENT="${1:-}"
if [[ "$ENVIRONMENT" != "staging" && "$ENVIRONMENT" != "production" ]]; then
  echo "usage: $0 staging|production" >&2
  exit 1
fi

REPO_DIR="/root/vh-docker"
GOMPLATE_VERSION="v4.3.0"
TIMEZONE="Etc/UTC"      # both current Scaleway hosts are UTC; cron is wall-clock

log() { echo -e "\n\033[1;34m==> $*\033[0m"; }

# ---------------------------------------------------------------- baseline ---
log "Verifying baseline"
# The Rocky 9 image we were given already has Docker + Compose and ships with
# SELinux and firewalld disabled. Verify rather than assume — a host where these
# are on will fail later in confusing ways (bind mounts denied, nginx unable to
# reach published container ports).
command -v docker >/dev/null || { echo "docker missing — expected on the base image" >&2; exit 1; }
docker compose version >/dev/null || { echo "docker compose plugin missing" >&2; exit 1; }

if [[ "$(getenforce 2>/dev/null || echo Disabled)" != "Disabled" ]]; then
  echo "WARNING: SELinux is enforcing. The baseline image has it off; bind mounts" >&2
  echo "         (frontend config dirs, monitoring) will need relabeling." >&2
fi
if systemctl is-active --quiet firewalld 2>/dev/null; then
  echo "WARNING: firewalld is active. Baseline has it off. Ensure :80 is reachable" >&2
  echo "         from the edge LB before continuing." >&2
fi

log "Setting timezone to $TIMEZONE"
timedatectl set-timezone "$TIMEZONE"

# ------------------------------------------------------------------ nginx ----
log "Installing nginx"
dnf install -y nginx

# ---------------------------------------------------------------- gomplate ---
# HARD DEPENDENCY: all five frontend deploys shell out to `gomplate` on the VM to
# render config-templates/ into public/config/. Without it every frontend
# deployment fails at the render step.
if ! command -v gomplate >/dev/null; then
  log "Installing gomplate $GOMPLATE_VERSION"
  curl -fsSL -o /usr/local/bin/gomplate \
    "https://github.com/hairyhenderson/gomplate/releases/download/${GOMPLATE_VERSION}/gomplate_linux-amd64"
  chmod +x /usr/local/bin/gomplate
fi
gomplate --version

# ------------------------------------------------------------------ extras ---
log "Installing supporting packages"
# nc  — the vh-db connectivity gate
# git — this repo is updated in place on the VM
dnf install -y nmap-ncat git

# ------------------------------------------------------------ docker network -
# Every service compose file declares `networks.default: {name: vh, external: true}`,
# so this network must exist before any deploy.
log "Creating external docker network 'vh'"
docker network inspect vh >/dev/null 2>&1 || docker network create vh

# -------------------------------------------------------------------- repo ---
if [[ ! -d "$REPO_DIR/.git" ]]; then
  log "Cloning vh-docker to $REPO_DIR"
  git clone https://github.com/Bnei-Baruch/vh-docker.git "$REPO_DIR"
fi

log "Creating apps/ deploy root"
mkdir -p "$REPO_DIR/apps"

# ------------------------------------------------------------------- nginx ---
log "Installing nginx configuration for '$ENVIRONMENT'"

# Rocky's stock nginx.conf embeds its own `listen 80 default_server` block, which
# collides with ours. Replace the whole file rather than patching around it.
[[ -f /etc/nginx/nginx.conf.stock ]] || cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.stock
install -m 0644 "$REPO_DIR/nginx/nginx.conf" /etc/nginx/nginx.conf

install -m 0644 "$REPO_DIR/nginx/conf.d/00-upstreams.conf" /etc/nginx/conf.d/00-upstreams.conf
install -m 0644 "$REPO_DIR/nginx/conf.d/10-realip.conf"    /etc/nginx/conf.d/10-realip.conf
install -d -m 0755 /etc/nginx/snippets
install -m 0644 "$REPO_DIR"/nginx/snippets/*.conf          /etc/nginx/snippets/
install -m 0644 "$REPO_DIR/nginx/sites/${ENVIRONMENT}.conf" /etc/nginx/conf.d/50-vh.conf

# Anything the stock package dropped in conf.d/ would still be loaded.
rm -f /etc/nginx/conf.d/default.conf

# The placeholder LB address has no effect if left in place, and nginx will not
# warn — fail here instead of discovering it in the payment audit trail.
if grep -q "0.0.0.0/32" /etc/nginx/conf.d/10-realip.conf; then
  echo "ERROR: set_real_ip_from is still the placeholder in nginx/conf.d/10-realip.conf." >&2
  echo "       Set the real edge LB address before serving traffic." >&2
  exit 1
fi

nginx -t
systemctl enable --now nginx
systemctl reload nginx

log "Done. Next: host/post-install.sh"
