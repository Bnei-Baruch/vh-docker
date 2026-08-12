#!/usr/bin/env bash
#
# Provision roles + databases for one VH environment on the shared vh-db host.
#
#   ./provision.sh staging|production
#
# vh-db is PROVIDED infrastructure: PostgreSQL 18 is installed there by whoever
# owns the VM, and backups are theirs too. This repo only creates the schemas,
# roles and grants the applications need — it never installs, configures or
# backs up postgres.
#
# Passwords are read from provision.env beside this script (gitignored), or from
# the environment. They are never stored in git.
#
# Run it on vh-db as root:
#
#   cd /root/vh-docker/db/provision && ./provision.sh production
#
set -euo pipefail

ENVIRONMENT="${1:-}"
if [[ "$ENVIRONMENT" != "staging" && "$ENVIRONMENT" != "production" ]]; then
  echo "usage: $0 staging|production" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------ provision.env ---
# Read as data, NOT sourced. `set -a; . provision.env` runs the file as shell, so
# any $, backtick, quote, space or # in a password is interpreted or truncates
# the value — which real passwords routinely contain. Splitting on the first "="
# and assigning through a variable keeps the value verbatim.
#
# Anything already exported wins, so a one-off override still works.
ENVFILE="${PROVISION_ENV:-$HERE/provision.env}"
if [[ -f "$ENVFILE" ]]; then
  echo "==> Reading $ENVFILE"
  while IFS='=' read -r key val || [[ -n "$key" ]]; do
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue   # skips comments and blanks
    val="${val%$'\r'}"                                     # tolerate CRLF
    [[ -n "${!key:-}" ]] && continue                       # environment wins
    export "$key=$val"
  done < "$ENVFILE"
fi

: "${PGPORT:=5432}"
# PGHOST/PGPASSWORD/PGUSER are all optional. With none of them set this runs psql
# through `sudo -u postgres`, i.e. the unix socket with peer auth and no password
# anywhere — which is why the script wants to be run as root on vh-db rather than
# as the postgres user (postgres cannot read a 0600 root-owned provision.env).
export PGPORT
[[ -n "${PGHOST:-}" ]]     && export PGHOST
[[ -n "${PGUSER:-}" ]]     && export PGUSER
[[ -n "${PGPASSWORD:-}" ]] && export PGPASSWORD

psql_run () {
  if [[ -z "${PGHOST:-}" ]]; then
    sudo -u postgres psql "$@"
  else
    psql "$@"
  fi
}

missing=()
for v in ORDERS_PW EVENTS_PW PROFILE_PW ACCOUNTING_PW REDASH_PW; do
  [[ -n "${!v:-}" ]] || missing+=("$v")
done
if (( ${#missing[@]} )); then
  echo "ERROR: missing password(s): ${missing[*]}" >&2
  echo "       set them in $ENVFILE (copy provision.env.example) or in the environment." >&2
  exit 1
fi

# Names are NOT uniform and are not ours to choose on the production side — they
# come from the existing managed instance and must match, because the app .env
# files and the pg_dump/restore both reference them verbatim. Staging is fresh,
# so it mirrors the production shape for the sake of a like-for-like rehearsal.
if [[ "$ENVIRONMENT" == "production" ]]; then
  ORDERS_DB=prod_grom;            ORDERS_USER=prod_vh_order
  EVENTS_DB=prod_events_srv;      EVENTS_USER=prod_events
  PROFILE_DB=prod_profile;        PROFILE_USER=prod_profile
  ACCOUNTING_DB=prod_accounting;  ACCOUNTING_USER=prod_accounting
  REDASH_USER=redash_readonly
else
  ORDERS_DB=staging_grom;             ORDERS_USER=staging_vh_order
  EVENTS_DB=staging_events_srv;       EVENTS_USER=staging_events
  PROFILE_DB=staging_profile;         PROFILE_USER=staging_profile
  ACCOUNTING_DB=staging_accounting;   ACCOUNTING_USER=staging_accounting
  REDASH_USER=redash_readonly
fi

echo "==> Creating roles and databases for $ENVIRONMENT on ${PGHOST:-local socket}:$PGPORT"
psql_run -d postgres -v ON_ERROR_STOP=1 \
  -v orders_db="$ORDERS_DB"         -v orders_user="$ORDERS_USER"         -v orders_pw="$ORDERS_PW" \
  -v events_db="$EVENTS_DB"         -v events_user="$EVENTS_USER"         -v events_pw="$EVENTS_PW" \
  -v profile_db="$PROFILE_DB"       -v profile_user="$PROFILE_USER"       -v profile_pw="$PROFILE_PW" \
  -v accounting_db="$ACCOUNTING_DB" -v accounting_user="$ACCOUNTING_USER" -v accounting_pw="$ACCOUNTING_PW" \
  -f "$HERE/sql/00_roles_and_databases.sql"

# Redash reads production reporting data. Staging gets the same treatment so the
# grant path is exercised before it matters.
for pair in "$ORDERS_DB:$ORDERS_USER" "$EVENTS_DB:$EVENTS_USER" \
            "$PROFILE_DB:$PROFILE_USER" "$ACCOUNTING_DB:$ACCOUNTING_USER"; do
  db="${pair%%:*}"; owner="${pair##*:}"
  echo "==> Redash read-only grants on $db"
  psql_run -d "$db" -v ON_ERROR_STOP=1 \
    -v redash_user="$REDASH_USER" -v redash_pw="$REDASH_PW" -v owner="$owner" \
    -f "$HERE/sql/10_redash_readonly.sql"
done

echo "==> Done."
echo
echo "Reminder: run each service's migrations after this — they are not uniform."
echo "  vh-srv-orders / vh-srv-profile / vh-srv-events : Go cobra 'migrate'"
echo "  vh-srv-accounting                              : npm run migrate (node-pg-migrate)"
