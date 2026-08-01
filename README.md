# vh-docker

Shared infrastructure for the Virtual Home VMs: host bootstrap, nginx ingress,
NATS, database provisioning, cron and monitoring.

Modelled on [archive-docker](https://github.com/Bnei-Baruch/archive-docker) and
[mdb-docker](https://github.com/Bnei-Baruch/mdb-docker).

> Context: this repo exists for the Scaleway → on-prem migration. Plan and task
> breakdown live in `mdhub/vh_onprem_migration/`.

## What this repo is not

**It does not contain application compose files.** Each service repo owns and
ships its own `docker-compose.yml` through its `cicd.yml`: build → ghcr, scp the
compose file to `/root/vh-docker/apps/<service>/`, then ssh in and
`docker compose up -d`. That model is unchanged by the migration.

So `apps/` is a **deploy target, not source**. CI/CD writes into it; git ignores
everything in it. The `.env` beside each compose file is created by hand on the
VM and exists nowhere else.

## Layout

```
host/       install_rocky_9.sh, post-install.sh   — one-time VM bootstrap
nginx/      conf.d/ + sites/ + snippets/          — host nginx, replaces Kong
nats/       nats.yml                              — JetStream, host-managed
db/         provision/                            — roles, databases, grants on vh-db
cron/       vh.cron                               — 3 production jobs (installed at cutover)
monitoring/ Grafana Agent + exporters             — production only
apps/       (gitignored)                          — CI/CD deploy target
```

## Bring-up

```bash
# 1. bootstrap (as root, on a fresh Rocky 9 VM)
git clone https://github.com/Bnei-Baruch/vh-docker.git /root/vh-docker
cd /root/vh-docker
./host/install_rocky_9.sh production        # or: staging

# 2. host secrets
cp .env.example .env && "$EDITOR" .env

# 3. registry, NATS, monitoring
./host/post-install.sh production           # or: staging

# 4. databases (from anywhere with psql reach to vh-db)
cd db/provision
cp provision.env.example provision.env && "$EDITOR" provision.env
set -a; source provision.env; set +a
./provision.sh production

# 5. per service: create apps/<service>/.env by hand, then deploy from GitHub Actions
```

Cron is **not** installed by step 3 — see `cron/README.md`.

## Topology

```
Internet ──TLS──> edge LB ──plain HTTP :80──> host nginx ──> 127.0.0.1:<port> containers
```

The edge LB terminates TLS. These hosts never see HTTPS, run no certbot, and
hold no certificates. nginx runs on the host (not in a container) and reaches
each service through its published loopback port.

**Ingress map** — every path strips its prefix, matching Kong's `strip_path=true`:

| Host | Path | Upstream |
|---|---|---|
| `kli.one` | `/` | vh-front `:8081` |
| | `/dash` | vh-dash `:8080` |
| | `/pay` | vh-payment `:8084` |
| | `/admin/payments` | vh-payment-bo `:8087` |
| | `/admin/events` | vh-events-bo `:8089` |
| `api.kli.one` | `/pay` | vh-srv-orders `:8185` |
| | `/profile` | vh-srv-profile `:7471` |
| | `/events` | vh-srv-events `:7475` |
| | `/accounting` | vh-srv-accounting `:8190` |

Staging is identical on `staging-vh.kli.one` / `staging-vh-api.kli.one`.

## Testing the ingress

```bash
./nginx/test/run.sh              # production
./nginx/test/run.sh staging
```

Runs the real config in a throwaway nginx container against stub backends that
echo the URI they received, and asserts on prefix stripping, CORS preflight,
retired-route 404s and unknown-Host handling. `nginx -t` only proves the config
parses; every bug found while writing these configs parsed fine.

## Things that fail silently

Collected because each one produces a *working-looking* system that is wrong.

**`vh-srv-events` is `:7475` here, not `:8080`.** Kong addressed it by container
name over the docker network, so its service table says `vh-srv-events:8080`.
Host nginx must use the published host port, which is `7475`. Both numbers are
correct in their own context; copying the wrong one gives a 502.

**`set_real_ip_from` needs no per-host edit, but it still fails quietly if
wrong.** `nginx/conf.d/10-realip.conf` trusts `10.0.0.0/8` and `fd00::/8` rather
than one LB address, so it is correct as shipped and survives the LB being
re-addressed. If a hop ever sits *outside* those ranges, `real_ip` silently has
no effect — nginx does not warn — and every client IP in the payment audit
trail, Sentry and the Loki-shipped access logs becomes the proxy's, with no way
to recover the real ones afterwards. `nginx/test/run.sh` asserts both directions.

**CORS is nginx's job, not Kong's.** The wildcard CORS block on `api.kli.one`
lived in nginx in front of Kong. Removing Kong does not remove the need for it;
`nginx/snippets/cors.conf` carries it over verbatim.

**Prefix stripping uses `rewrite`, not a trailing slash on `proxy_pass`.** The
trailing-slash form substitutes the matched prefix with `/`, so `location ^~ /pay`
turns `/pay/v1/orders` into `//v1/orders`. Static frontends normalise that away —
which is why the current Scaleway config gets away with it — but Kong produced a
clean `/v1/orders` and Go routers generally will not forgive the difference.

**`include cors.conf` must come BEFORE the `rewrite` in each location.** `rewrite`
and `if` are both ngx_http_rewrite_module and run in one ordered phase, so a
`rewrite ... break` above the `if` ends the phase and CORS disappears entirely —
config still parses, preflights just quietly return the upstream's 200 with no
headers.

**App roles must own their databases.** PostgreSQL 15 removed PUBLIC's `CREATE`
on the `public` schema, so a non-owner role cannot create tables and every
`migrate` fails on fresh PG18. See `db/README.md`.

**Cron installed early hits real customers.** Phase 2 validates against restored
production data. See `cron/README.md`.

## Open before first deploy

- [x] ~~Real edge LB address~~ — `10-realip.conf` trusts the private ranges; no
      per-host edit.
- [x] ~~Confirm `vh-db`'s SSL policy~~ — `ssl = off` with scram over plain TCP,
      so the hardcoded `?sslmode=disable` works. **Nothing may use
      `sslmode=require`**; it fails outright.
- [x] ~~How app `.env`s address `vh-db`~~ — by hostname `pgsql4`, which resolves
      from the app VMs.
- [x] ~~Timezone~~ — `Etc/UTC`, matching the current hosts.
- [ ] `/root/vh-docker/.env` on each VM (GHCR token, NATS credentials, and on
      production the Loki password).
- [ ] Authorize the `BBDEPLOYMENT_SSH_PRIVATE_KEY` public half for `root`.

## Related service-side changes

These live in the service repos' `migration` branches, not here, but this repo
assumes they have happened:

- Deploy path `/opt/vh/<svc>` → `/root/vh-docker/apps/<svc>`, in **all 3–4 sites
  per service** — the scp `target:`, the `cd`, the gomplate `--output-map`, and
  the config bind mount inside each frontend's own `docker-compose.yml`.
- Staging-DB choreography removed from **all four** backends.
- Per-deploy NATS bring-up removed from `vh-srv-orders`.
- `vh-srv-accounting/docker-compose.yml`: `networks.default.external.name` →
  `networks.default: {name: vh, external: true}` (the long form was removed in
  current Compose and will fail on Rocky 9).
- Containers publish on `0.0.0.0` today. With firewalld off on the Rocky
  baseline, that exposes every service directly on the VM's public IP,
  bypassing the LB and nginx. Bind them to `127.0.0.1:<port>:<port>` unless the
  network perimeter already prevents it.
