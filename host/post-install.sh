#!/usr/bin/env bash
#
# Second-stage host setup: registry auth, NATS, monitoring.
# Run after install_rocky_9.sh, and after /root/vh-docker/.env exists.
#
# Usage:  ./post-install.sh staging|production
#
set -euo pipefail

ENVIRONMENT="${1:-}"
if [[ "$ENVIRONMENT" != "staging" && "$ENVIRONMENT" != "production" ]]; then
  echo "usage: $0 staging|production" >&2
  exit 1
fi

REPO_DIR="/root/vh-docker"
NODE_EXPORTER_VERSION="1.9.1"   # matches the version on the current prod host
cd "$REPO_DIR"

log() { echo -e "\n\033[1;34m==> $*\033[0m"; }

# Host-level secrets (GHCR token, NATS credentials, Loki password) live here.
# Hand-created on the VM, never in git. See .env.example.
if [[ ! -f "$REPO_DIR/.env" ]]; then
  echo "$REPO_DIR/.env is missing — copy .env.example and fill it in." >&2
  exit 1
fi
set -a; source "$REPO_DIR/.env"; set +a

# ---------------------------------------------------------------- registry ---
log "Logging in to ghcr.io"
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

# -------------------------------------------------------------------- ssh ----
# The deploy key CI/CD uses (BBDEPLOYMENT_SSH_PRIVATE_KEY) must be authorized for
# root, because every cicd.yml scp's and ssh's in as root.
log "Checking deploy key authorization"
if [[ ! -s /root/.ssh/authorized_keys ]]; then
  echo "WARNING: /root/.ssh/authorized_keys is empty — CI/CD deploys will fail." >&2
  echo "         Add the public half of BBDEPLOYMENT_SSH_PRIVATE_KEY." >&2
fi

# ------------------------------------------------------------------- NATS ----
# NATS is host-managed here, not brought up per-deploy by vh-srv-orders any more.
# JetStream starts from an empty volume: vh-srv-orders calls CreateOrUpdateStream
# on boot (events/handlers.go), so streams re-create themselves. No state to move.
# --project-directory pins interpolation and the .env lookup to the repo root;
# without it Compose resolves both relative to nats/, which has no .env.
log "Starting NATS"
docker compose --project-directory "$REPO_DIR" -f nats/nats.yml up -d
docker compose --project-directory "$REPO_DIR" -f nats/nats.yml ps

# ------------------------------------------------------------- monitoring ----
# Production only, matching the current setup.
if [[ "$ENVIRONMENT" == "production" ]]; then
  # node_exporter is a host binary under systemd, not a container — same as the
  # old host, where it ran from /opt/monitoring/node_exporter/.
  if ! command -v node_exporter >/dev/null; then
    log "Installing node_exporter $NODE_EXPORTER_VERSION"
    tmp="$(mktemp -d)"
    curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" \
      | tar xz -C "$tmp" --strip-components=1
    install -m 0755 "$tmp/node_exporter" /usr/local/bin/node_exporter
    rm -rf "$tmp"
  fi
  mkdir -p /etc/prometheus/node_exporter/data
  install -m 0644 monitoring/node_exporter.service /etc/systemd/system/node_exporter.service
  systemctl daemon-reload
  systemctl enable --now node_exporter

  log "Rendering monitoring config"
  # grafana.river carries the Loki remote-write password, so the repo holds only
  # the template and the rendered file is gitignored.
  gomplate --file monitoring/config/grafana.river.tmpl \
           --out  monitoring/config/grafana.river

  log "Starting monitoring stack"
  docker compose --project-directory "$REPO_DIR" -f monitoring/docker-compose.yml up -d
  docker compose --project-directory "$REPO_DIR" -f monitoring/docker-compose.yml ps
else
  log "Skipping monitoring (production only)"
fi

# ------------------------------------------------------------------- cron ----
# DELIBERATELY NOT INSTALLED HERE.
#
# cron/vh.cron drives robokasa.sh, activate_specials.sh and
# invalidate_memberships.sh against real customer rows. During Phase 2 the new
# production VM holds a restored copy of live production data, so installing
# cron then would charge and email real customers. It goes in at cutover only:
#
#     install -m 0644 /root/vh-docker/cron/vh.cron /etc/cron.d/vh
#
log "Reminder: /etc/cron.d/vh is installed at cutover, not now (see cron/README.md)"

log "Done."
