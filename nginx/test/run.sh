#!/usr/bin/env bash
#
# Exercise the ingress config against stub backends, locally, before it ever
# reaches a VM. Needs Docker; touches nothing outside the throwaway container.
#
#   ./nginx/test/run.sh              # production
#   ./nginx/test/run.sh staging
#
# `nginx -t` only proves the config parses. These assertions cover the parts that
# parse fine and still behave wrongly:
#   - prefix stripping matches Kong's strip_path (no doubled slash)
#   - CORS survives the rewrite (ordering bug: `rewrite ... break` before an
#     `if` kills it silently)
#   - retired Kong routes 404 instead of falling through
#   - unknown Host hits the default_server 404, not somebody's site
#
set -euo pipefail

ENVIRONMENT="${1:-production}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAME="vh-nginx-test"
PORT=18080

if [[ "$ENVIRONMENT" == "production" ]]; then WEB=kli.one; API=api.kli.one
else WEB=staging-vh.kli.one; API=staging-vh-api.kli.one; fi

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

# The placeholder LB address makes install_rocky_9.sh refuse to run; for a config
# test it is irrelevant, so feed nginx a copy with a routable value.
tmp="$(mktemp -d)"
sed 's|0\.0\.0\.0/32|10.0.0.0/8|' "$REPO/nginx/conf.d/10-realip.conf" > "$tmp/10-realip.conf"

docker run -d --rm --name "$NAME" -p "$PORT:80" \
  -v "$REPO/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$REPO/nginx/conf.d/00-upstreams.conf:/etc/nginx/conf.d/00-upstreams.conf:ro" \
  -v "$tmp/10-realip.conf:/etc/nginx/conf.d/10-realip.conf:ro" \
  -v "$REPO/nginx/sites/$ENVIRONMENT.conf:/etc/nginx/conf.d/50-vh.conf:ro" \
  -v "$REPO/nginx/snippets:/etc/nginx/snippets:ro" \
  -v "$REPO/nginx/test/stubs.conf:/etc/nginx/conf.d/90-stubs.conf:ro" \
  nginx:1.28 sh -c 'rm -f /etc/nginx/conf.d/default.conf; nginx -g "daemon off;"' >/dev/null

for _ in $(seq 1 30); do
  curl -sf -o /dev/null -H "Host: $WEB" "http://127.0.0.1:$PORT/" && break
  sleep 0.3
done

fails=0
check() { # check <host> <path> <expected-body>
  local got; got="$(curl -s --max-time 5 -H "Host: $1" "http://127.0.0.1:$PORT$2")"
  if [[ "$got" == "$3" ]]; then printf '  ok    %-24s %s\n' "$2" "$3"
  else printf '  FAIL  %-24s expected %-32s got %s\n' "$2" "$3" "$got"; fails=$((fails+1)); fi
}
code() { # code <host> <path> <expected-status>
  local got; got="$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -H "Host: $1" "http://127.0.0.1:$PORT$2")"
  if [[ "$got" == "$3" ]]; then printf '  ok    %-24s %s\n' "$2" "$3"
  else printf '  FAIL  %-24s expected %s got %s\n' "$2" "$3" "$got"; fails=$((fails+1)); fi
}

echo "web ($WEB)"
check "$WEB" /                    "vh-front:/"
check "$WEB" /dash                "vh-dash:/"
check "$WEB" /dash/               "vh-dash:/"
check "$WEB" /dash/assets/x.js    "vh-dash:/assets/x.js"
check "$WEB" /pay/checkout        "vh-payment:/checkout"
check "$WEB" /admin/payments/list "vh-payment-bo:/list"
check "$WEB" /admin/events/x      "vh-events-bo:/x"

echo "api ($API)"
check "$API" /pay                 "vh-srv-orders:/"
check "$API" /pay/v1/orders       "vh-srv-orders:/v1/orders"
check "$API" /profile/me          "vh-srv-profile:/me"
check "$API" /events/list         "vh-srv-events:/list"
check "$API" /accounting/health   "vh-srv-accounting:/health"

echo "retired routes 404"
for p in /register /srvtest /survey /kc/x; do code "$API" "$p" 404; done

echo "unknown host 404"
code bogus.example / 404

echo "cors"
hdrs="$(curl -s --max-time 5 -o /dev/null -D- -X OPTIONS -H "Host: $API" \
        -H 'Origin: https://example.com' "http://127.0.0.1:$PORT/pay/v1/orders")"
if grep -qi '204' <<<"$hdrs" && grep -qi 'access-control-allow-origin: \*' <<<"$hdrs"; then
  echo "  ok    preflight 204 + headers"
else
  echo "  FAIL  preflight"; echo "$hdrs" | sed 's/^/        /'; fails=$((fails+1))
fi
if curl -s --max-time 5 -o /dev/null -D- -H "Host: $API" "http://127.0.0.1:$PORT/profile/me" \
   | grep -qi 'access-control-allow-origin: \*'; then
  echo "  ok    GET carries CORS headers"
else
  echo "  FAIL  GET missing CORS headers"; fails=$((fails+1))
fi

rm -rf "$tmp"
echo
if (( fails )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed ($ENVIRONMENT)"
