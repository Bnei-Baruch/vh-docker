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
# Passwords come from the environment (see db/provision/provision.env.example)
# and are never stored in git.
#
set -euo pipefail

ENVIRONMENT="${1:-}"
if [[ "$ENVIRONMENT" != "staging" && "$ENVIRONMENT" != "production" ]]; then
  echo "usage: $0 staging|production" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${PGPORT:=5432}"
: "${PGUSER:?set PGUSER to a superuser on vh-db}"
# PGHOST/PGPASSWORD are optional: run this on vh-db itself as the postgres user
# and libpq uses the unix socket with peer auth, no password involved. Set both
# to run it remotely.
export PGPORT PGUSER
[[ -n "${PGHOST:-}" ]]     && export PGHOST
[[ -n "${PGPASSWORD:-}" ]] && export PGPASSWORD

: "${ORDERS_PW:?}" "${EVENTS_PW:?}" "${PROFILE_PW:?}" "${ACCOUNTING_PW:?}" "${REDASH_PW:?}"

# Names are NOT uniform and are not ours to choose on the production side — they
# come from the existing managed instance and must match, because the app .env
# files and the pg_dump/restore both reference them verbatim. Staging is fresh,
# so it mirrors the production shape for the sake of a like-for-like rehearsal.
if [[ "$ENVIRONMENT" == "production" ]]; then
  ORDERS_DB=prod_grom;            ORDERS_USER=prod_vh_order
  EVENTS_DB=prod_events_srv;      EVENTS_USER=prod_events
  PROFILE_DB=prod_profile;        PROFILE_USER=prod_profile
  ACCOUNTING_DB=prod_accounting;  ACCOUNTING_USER=prod_accounting
  REDASH_USER=redash_ro
else
  ORDERS_DB=staging_grom;             ORDERS_USER=staging_vh_order
  EVENTS_DB=staging_events_srv;       EVENTS_USER=staging_events
  PROFILE_DB=staging_profile;         PROFILE_USER=staging_profile
  ACCOUNTING_DB=staging_accounting;   ACCOUNTING_USER=staging_accounting
  REDASH_USER=redash_ro
fi

echo "==> Creating roles and databases for $ENVIRONMENT on ${PGHOST:-local socket}:$PGPORT"
psql -d postgres -v ON_ERROR_STOP=1 \
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
  psql -d "$db" -v ON_ERROR_STOP=1 \
    -v redash_user="$REDASH_USER" -v redash_pw="$REDASH_PW" -v owner="$owner" \
    -f "$HERE/sql/10_redash_readonly.sql"
done

echo "==> Done."
echo
echo "Reminder: run each service's migrations after this — they are not uniform."
echo "  vh-srv-orders / vh-srv-profile / vh-srv-events : Go cobra 'migrate'"
echo "  vh-srv-accounting                              : npm run migrate (node-pg-migrate)"
