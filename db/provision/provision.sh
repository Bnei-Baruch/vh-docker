#!/usr/bin/env bash
#
# Provision roles + databases for one VH environment on the shared vh-db host.
#
#   cd /root/vh-docker/db/provision && ./provision.sh production
#
# Run it as root, ON the vh-db host. psql always goes through `sudo -u postgres`:
# unix socket, peer auth, superuser, no password and no network involved. There
# is deliberately no remote mode — supporting one is what previously made this
# script fragile, because the host exports PGHOST/PGUSER system-wide and those
# would quietly take over the connection. sudo resets the environment, so they
# cannot.
#
# vh-db is PROVIDED infrastructure: PostgreSQL is installed there by whoever owns
# the VM, and backups are theirs. This repo only creates the schemas, roles and
# grants the applications need.
#
# Passwords come from provision.env beside this script (gitignored).
#
set -euo pipefail

ENVIRONMENT="${1:-}"
if [[ "$ENVIRONMENT" != "staging" && "$ENVIRONMENT" != "production" ]]; then
  echo "usage: $0 staging|production" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVFILE="$HERE/provision.env"

if [[ ! -f "$ENVFILE" ]]; then
  echo "ERROR: $ENVFILE not found — copy provision.env.example and fill it in." >&2
  exit 1
fi

# Read as data, NOT sourced. `. provision.env` would run the file as shell, so a
# $, backtick, quote, space or # in a password gets interpreted — the value
# silently truncates, or a command substitution executes. Splitting on the first
# "=" and assigning through a variable keeps it verbatim, so passwords need no
# quoting or escaping in the file.
while IFS='=' read -r key val || [[ -n "$key" ]]; do
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue    # skips comments, blanks
  declare "$key=${val%$'\r'}"                             # tolerate CRLF
done < "$ENVFILE"

missing=()
for v in ORDERS_PW EVENTS_PW PROFILE_PW ACCOUNTING_PW REDASH_PW; do
  [[ -n "${!v:-}" ]] || missing+=("$v")
done
if (( ${#missing[@]} )); then
  echo "ERROR: missing password(s) in $ENVFILE: ${missing[*]}" >&2
  exit 1
fi

# The SQL is fed on stdin rather than with -f: this repo lives under /root, which
# is 0700, so the postgres user cannot open the files itself. The redirect is
# performed by this shell, which is root, and the open descriptor passes through.
run_sql () {                       # run_sql <sqlfile> <psql args...>
  local f="$1"; shift
  sudo -u postgres psql -X -v ON_ERROR_STOP=1 "$@" < "$f"
}

# Production names are inherited from the managed instance, not chosen — the app
# .env files and the pg_dump/restore reference them verbatim. Staging mirrors the
# same shape so the rehearsal is like-for-like.
if [[ "$ENVIRONMENT" == "production" ]]; then
  ORDERS_DB=prod_grom;           ORDERS_USER=prod_vh_order
  EVENTS_DB=prod_events_srv;     EVENTS_USER=prod_events
  PROFILE_DB=prod_profile;       PROFILE_USER=prod_profile
  ACCOUNTING_DB=prod_accounting; ACCOUNTING_USER=prod_accounting
else
  ORDERS_DB=staging_grom;           ORDERS_USER=staging_vh_order
  EVENTS_DB=staging_events_srv;     EVENTS_USER=staging_events
  PROFILE_DB=staging_profile;       PROFILE_USER=staging_profile
  ACCOUNTING_DB=staging_accounting; ACCOUNTING_USER=staging_accounting
fi
REDASH_USER=redash_readonly

echo "==> Creating roles and databases for $ENVIRONMENT"
run_sql "$HERE/sql/00_roles_and_databases.sql" -d postgres \
  -v orders_db="$ORDERS_DB"         -v orders_user="$ORDERS_USER"         -v orders_pw="$ORDERS_PW" \
  -v events_db="$EVENTS_DB"         -v events_user="$EVENTS_USER"         -v events_pw="$EVENTS_PW" \
  -v profile_db="$PROFILE_DB"       -v profile_user="$PROFILE_USER"       -v profile_pw="$PROFILE_PW" \
  -v accounting_db="$ACCOUNTING_DB" -v accounting_user="$ACCOUNTING_USER" -v accounting_pw="$ACCOUNTING_PW"

# Per-database, because object grants are database-scoped. Also re-run after every
# restore: restored tables carry no grants.
for pair in "$ORDERS_DB:$ORDERS_USER" "$EVENTS_DB:$EVENTS_USER" \
            "$PROFILE_DB:$PROFILE_USER" "$ACCOUNTING_DB:$ACCOUNTING_USER"; do
  db="${pair%%:*}"; owner="${pair##*:}"
  echo "==> Redash read-only grants on $db"
  run_sql "$HERE/sql/10_redash_readonly.sql" -d "$db" \
    -v redash_user="$REDASH_USER" -v redash_pw="$REDASH_PW" -v owner="$owner"
done

echo "==> Done."
