#!/usr/bin/env bash
#
# Move the production data from the Scaleway managed PostgreSQL onto vh-db.
#
#   ./migrate-data.sh dump            # read-only against the managed instance
#   ./migrate-data.sh restore --confirm
#   ./migrate-data.sh verify
#   ./migrate-data.sh all --confirm
#
# Run it as root ON the vh-db host. Used twice: once as the Phase-2 rehearsal,
# then again in the cutover window — the window should be a replay of a sequence
# already run, not a first attempt.
#
# The application credentials are the same on both sides: provisioning
# deliberately reused the managed instance's passwords, so only host and port
# differ. Passwords are read from provision/provision.env — no second secrets
# file.
#
# STOP THE SERVICES FIRST. They are on the app VM, not here, so this script
# cannot do it and deliberately does not try:
#
#   ssh production-vh-new
#   docker stop vh-srv-orders vh-srv-profile vh-srv-events vh-srv-accounting
#
# Plain docker, not `docker compose stop`: compose interpolates ${IMAGE_NAME}
# whenever it parses the file — for every subcommand, not just `up` — and that
# variable is only set during a deploy. All four backends set container_name, so
# addressing them by name works.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVFILE="$HERE/provision/provision.env"

SRC_HOST="${SRC_HOST:-195.154.69.180}"   # Scaleway managed PostgreSQL 12
SRC_PORT="${SRC_PORT:-64612}"
DST_HOST="${DST_HOST:-127.0.0.1}"        # vh-db, over TCP: the app roles are not
DST_PORT="${DST_PORT:-5432}"             # OS users, so peer auth cannot be used
DUMP_DIR="${DUMP_DIR:-/root/pgdump}"
JOBS="${JOBS:-4}"

# database : owning role : password variable in provision.env
TARGETS=(
  "prod_grom:prod_vh_order:ORDERS_PW"
  "prod_events_srv:prod_events:EVENTS_PW"
  "prod_profile:prod_profile:PROFILE_PW"
  "prod_accounting:prod_accounting:ACCOUNTING_PW"
)

ACTION="${1:-}"
CONFIRM="${2:-}"
case "$ACTION" in dump|restore|verify|all) ;; *)
  echo "usage: $0 dump|restore|verify|all [--confirm]" >&2; exit 1 ;;
esac

[[ -f "$ENVFILE" ]] || { echo "ERROR: $ENVFILE not found." >&2; exit 1; }

# Same reader as provision.sh: taken as data, never sourced, so passwords with
# $, backticks, quotes, spaces or # survive verbatim.
while IFS='=' read -r key val || [[ -n "$key" ]]; do
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
  declare "$key=${val%$'\r'}"
done < "$ENVFILE"

pw_of () { local n="$1"; echo "${!n:-}"; }

for t in "${TARGETS[@]}"; do
  v="${t##*:}"
  [[ -n "$(pw_of "$v")" ]] || { echo "ERROR: $v is not set in $ENVFILE" >&2; exit 1; }
done

hms () { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }
declare -A TOOK=()
TIMED=0   # separate flag: ${#TOOK[@]} on an empty assoc array trips `set -u`

# ---------------------------------------------------------------------- dump --
do_dump () {
  mkdir -p "$DUMP_DIR"; chmod 700 "$DUMP_DIR"
  echo "==> Dumping from $SRC_HOST:$SRC_PORT into $DUMP_DIR"
  for t in "${TARGETS[@]}"; do
    db="${t%%:*}"; rest="${t#*:}"; user="${rest%%:*}"; pwv="${rest##*:}"
    local start=$SECONDS
    PGPASSWORD="$(pw_of "$pwv")" pg_dump -h "$SRC_HOST" -p "$SRC_PORT" -U "$user" \
      -d "$db" -Fc -f "$DUMP_DIR/$db.dump"
    TOOK["dump:$db"]=$(( SECONDS - start )); TIMED=1
    printf '    %-18s %8s  %s\n' "$db" "$(du -h "$DUMP_DIR/$db.dump" | cut -f1)" "$(hms ${TOOK[dump:$db]})"
  done
}

# ------------------------------------------------------------------- restore --
do_restore () {
  if [[ "$CONFIRM" != "--confirm" ]]; then
    echo "REFUSING: 'restore' drops and re-creates these databases on vh-db:" >&2
    for t in "${TARGETS[@]}"; do echo "    ${t%%:*}" >&2; done
    echo "Re-run with --confirm if that is what you want." >&2
    exit 1
  fi
  for t in "${TARGETS[@]}"; do
    db="${t%%:*}"
    [[ -f "$DUMP_DIR/$db.dump" ]] || { echo "ERROR: $DUMP_DIR/$db.dump missing — run 'dump' first." >&2; exit 1; }
  done

  echo "==> Dropping the target databases"
  { for t in "${TARGETS[@]}"; do echo "DROP DATABASE IF EXISTS ${t%%:*} WITH (FORCE);"; done; } \
    | sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d postgres

  # Re-create through the provisioning script so ownership, the per-database
  # isolation and the Redash role all come back exactly as declared.
  echo "==> Re-creating via provision.sh"
  "$HERE/provision/provision.sh" production

  echo "==> Restoring into $DST_HOST:$DST_PORT"
  for t in "${TARGETS[@]}"; do
    db="${t%%:*}"; rest="${t#*:}"; user="${rest%%:*}"; pwv="${rest##*:}"
    local start=$SECONDS
    # Restored objects belong to whoever runs the restore, so this must be the
    # owning role — not postgres. A superuser restore leaves the app role not
    # owning its own tables, which breaks the PG15 public-schema arrangement and
    # attaches the Redash default privileges to the wrong role.
    PGPASSWORD="$(pw_of "$pwv")" pg_restore -h "$DST_HOST" -p "$DST_PORT" -U "$user" \
      -d "$db" --no-owner --no-privileges -j "$JOBS" "$DUMP_DIR/$db.dump"
    TOOK["restore:$db"]=$(( SECONDS - start )); TIMED=1
    printf '    %-18s %s\n' "$db" "$(hms ${TOOK[restore:$db]})"
  done

  # Restored tables carry no grants, and ALTER DEFAULT PRIVILEGES only covers
  # objects created after it was set — so the grants have to be re-applied.
  echo "==> Re-applying Redash grants"
  "$HERE/provision/provision.sh" production
}

# -------------------------------------------------------------------- verify --
# Exact per-table counts on both sides. pg_stat_user_tables.n_live_tup is an
# estimate and would happily pass a bad restore.
counts () {                      # counts <host> <port> <user> <pw> <db>
  PGPASSWORD="$4" psql -h "$1" -p "$2" -U "$3" -d "$5" -tAX <<'SQL' | sort
select format('select %L as tbl, count(*) as n from public.%I', tablename, tablename)
from pg_tables where schemaname='public' order by tablename
\gexec
SQL
}

do_verify () {
  local rc=0
  echo "==> Comparing exact row counts, source vs target"
  for t in "${TARGETS[@]}"; do
    db="${t%%:*}"; rest="${t#*:}"; user="${rest%%:*}"; pw="$(pw_of "${rest##*:}")"
    counts "$SRC_HOST" "$SRC_PORT" "$user" "$pw" "$db" > "/tmp/.src.$db" 2>/dev/null || true
    counts "$DST_HOST" "$DST_PORT" "$user" "$pw" "$db" > "/tmp/.dst.$db" 2>/dev/null || true
    if [[ ! -s "/tmp/.src.$db" ]]; then
      printf '    %-18s SOURCE UNREADABLE\n' "$db"; rc=1
    elif diff -q "/tmp/.src.$db" "/tmp/.dst.$db" >/dev/null 2>&1; then
      printf '    %-18s identical (%s tables)\n' "$db" "$(wc -l < "/tmp/.src.$db" | tr -d ' ')"
    else
      printf '    %-18s *** MISMATCH ***\n' "$db"
      diff "/tmp/.src.$db" "/tmp/.dst.$db" | head -20 | sed 's/^/        /'
      rc=1
    fi
    rm -f "/tmp/.src.$db" "/tmp/.dst.$db"
  done
  return $rc
}

# Capture the verification result rather than letting `set -e` abort, so the
# timings still print and the exit code still reflects the outcome.
RC=0
case "$ACTION" in
  dump)    do_dump ;;
  restore) do_restore ;;
  verify)  do_verify || RC=$? ;;
  all)     do_dump; do_restore; do_verify || RC=$? ;;
esac

if (( TIMED )); then
  echo
  echo "==> Timings — the total is the cutover window"
  total=0
  for k in $(printf '%s\n' "${!TOOK[@]}" | sort); do
    printf '    %-26s %s\n' "$k" "$(hms ${TOOK[$k]})"; total=$(( total + TOOK[$k] ))
  done
  echo "    ----"
  printf '    %-26s %s\n' "TOTAL" "$(hms $total)"
fi

if [[ "$ACTION" == restore || "$ACTION" == all ]]; then
  echo
  echo "==> Restart the services on the app VM; boot migrations apply any delta:"
  echo "      docker start vh-srv-orders vh-srv-profile vh-srv-events vh-srv-accounting"
  echo "    (plain docker: compose would want IMAGE_NAME, which is only set during a deploy)"
fi

exit $RC
