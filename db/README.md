# Database

`vh-db` is **provided infrastructure**. PostgreSQL 18 is installed and backed up
by whoever owns that VM. This repo does not install postgres, does not run it in
Docker, and does not manage backups — it only provisions what the applications
need on top.

## Provisioning

Run it **as root on `pgsql4`**, from a checkout of this repo:

```bash
cd /root/vh-docker/db/provision
cp provision.env.example provision.env && chmod 600 provision.env
$EDITOR provision.env
./provision.sh production        # or: staging
```

The script reads `provision.env` itself. **Do not `source` it** — an earlier
version of these instructions said to, and that is wrong for any realistic
password: sourcing executes the file as shell, so a `$`, backtick, quote, space
or `#` is interpreted, a value silently truncates, or a command substitution
runs. Values are taken verbatim, so passwords need no quoting or escaping.

Run it as **root**, on the vh-db host. There is deliberately **no remote mode**:
`psql` always goes through `sudo -u postgres` on the unix socket — peer auth,
superuser, no password and no network. That matters because the host exports
`PGHOST`/`PGUSER` system-wide, and a remote mode let those quietly take over the
connection and run as a non-superuser, which gets far enough to create the roles
and then fails on `CREATE DATABASE ... OWNER`. `sudo` resets the environment, so
they cannot.

Root, not `postgres`: `provision.env` is `0600` root-owned, and the SQL lives
under `/root` (`0700`). The script feeds the SQL to psql on **stdin** rather than
with `-f` for the same reason — `postgres` cannot open those files itself.

Idempotent **and convergent**. Re-running creates nothing that already exists,
but it does re-apply every role's password, so a credential change is rolled out
by editing `provision.env` and re-running — never by a hand-written `ALTER ROLE`.

That distinction is the whole point of this directory: the moment the live
cluster is patched by hand, it stops being reproducible from the repo, and the
next person has no way to tell what is actually configured. `provision.env` is
therefore authoritative — running it with a wrong password overwrites a working
one.

## Names

Production names are inherited from the managed instance, not chosen. They are
not uniform, and the app `.env` files (copied over verbatim) plus the
`pg_dump`/restore both depend on them:

| Service | Database | Role |
|---|---|---|
| vh-srv-orders | `prod_grom` | `prod_vh_order` |
| vh-srv-events | `prod_events_srv` | `prod_events` |
| vh-srv-profile | `prod_profile` | `prod_profile` |
| vh-srv-accounting | `prod_accounting` | `prod_accounting` |

Staging is fresh, so it mirrors the same shape with a `staging_` prefix. The
current staging databases have unrelated ad-hoc names (`dev_gorm`,
`event_database`, user `app_user`…) because they were throwaway on-box
containers; none of that carries over.

## Isolation model

`prod_*` and `staging_*` live on the same cluster, so the boundary between them
is enforced by grants, not by separate servers:

- **Each app role owns exactly one database and can connect to only that one.**
- **`redash_readonly` is the single exception** — it gets `CONNECT` plus
  read-only grants on every database, in both environments.
- Roles are **cluster-wide** in PostgreSQL, which is why the `prod_`/`staging_`
  prefixes exist. Never drop them; two environments cannot both have a role
  called `vh_order`.

The revoke that makes this true is in `00_roles_and_databases.sql`. PostgreSQL
grants `CONNECT` and `TEMPORARY` to `PUBLIC` on every new database, so **without
it any role can connect to any database** — including a staging service account
reaching `prod_grom`, reading its whole schema from `information_schema`,
enumerating every role, and creating temp tables in it. Table data stays
unreadable, but that is not the boundary we want.

Left deliberately open: the `postgres` maintenance database, so the shared
catalogs stay listable. The *names* of the other environment's databases and
roles are therefore visible — no schema, no data.

## Two things that will bite

**PG15 removed PUBLIC's `CREATE` on the `public` schema.** A non-owner app role
cannot create tables there, so `migrate` fails on a fresh PG18 database. The
provisioning script makes each app role the **owner** of its database, which
makes it an implicit member of `pg_database_owner` — the owner of `public` — and
the problem goes away. Keep it that way; granting schema privileges by hand
instead works until the next restore re-creates the schema.

**Three services hardcode `?sslmode=disable`** in their migration DSN —
`vh-srv-orders/repo/common.go:32`, `vh-srv-events/repo/common.go:28`,
`vh-srv-profile/repo/db_common.go:84`. If `vh-db`'s `pg_hba.conf` requires SSL,
migrations fail while the running services (which use libpq defaults) may still
connect, so it looks like a migration bug rather than a policy mismatch. Confirm
the policy in Phase 0.

## Restore (Phase 2 rehearsal, Phase 3 cutover)

The full step-by-step sequence lives in `mdhub/vh_onprem_migration/task-breakdown.md`
("Data migration playbook"). The essentials:

Dump with the **PG18** client against the managed PG12 instance
(`195.154.69.180:64612`), not the PG12 client:

```bash
pg_dump    -h 195.154.69.180 -p 64612 -U prod_vh_order -d prod_grom -Fc -f prod_grom.dump
pg_restore -h pgsql4.bb.local          -U prod_vh_order -d prod_grom \
           --no-owner --no-privileges -j4 prod_grom.dump
```

**Restore as the role that owns the database, not as `postgres`.** With
`--no-owner`, restored objects belong to whoever runs the restore. Running it as
a superuser therefore leaves the app role *not* owning its own tables, which
breaks the PG15 `public`-schema arrangement this whole design depends on (see
above) and attaches the Redash default privileges to the wrong role. The
credentials are the same ones already in each service's `.env`, because
`provision.sh` deliberately reuses them.

`--no-privileges` because the source grants refer to managed-instance roles that
do not exist here.

**Re-run the provisioning after every restore** — restored tables carry no
grants, and `ALTER DEFAULT PRIVILEGES` only covers objects created after it was
set:

```bash
cd /root/vh-docker/db/provision && ./provision.sh production
```

Verify with **exact per-table counts** on both sides, not
`pg_stat_user_tables.n_live_tup` — that is an estimate. Sequences need no manual
step: a full dump/restore carries their values.

**Time every dump and restore.** The cutover window is a full dump + restore
(decided — no incremental path), so these numbers *are* the window length.

## vh-db as provisioned (2026-08-01)

`pgsql4` / `pgsql-vh` — **PostgreSQL 18.4**, `10.103.105.34:5432`, `listen_addresses = '*'`.

**Always address it as the FQDN `pgsql4.bb.local` in service `.env` files — never
the bare `pgsql4`.** The short name works from a shell on the VM, because the
host resolver applies `search bb.local`. It does **not** work reliably inside a
container: Docker writes `options ndots:0` into the container's `/etc/resolv.conf`,
which makes a name with no dots count as already fully qualified, so the search
suffix is never appended.

Whether that bites depends on the runtime, which makes it a nasty one to debug:

| Runtime | Bare `pgsql4` | Why |
|---|---|---|
| Go services | works | Go's own resolver retries with the search suffix after NXDOMAIN |
| Node (`vh-srv-accounting`) | **`ENOTFOUND`** | musl's `getaddrinfo` honours `ndots:0` and never tries the suffix |

Both run on Alpine, so the base image is not the difference — the resolver is.
The FQDN is correct everywhere and depends on no fallback behaviour.

Verify from a container, not from the host — the two resolve differently:

```bash
docker run --rm --network vh alpine:3.20 getent hosts pgsql4.bb.local
```

**`ssl = off`, and `pg_hba` is `host all all 0.0.0.0/0 scram-sha-256`.** So the
hardcoded `?sslmode=disable` in the three Go migration DSNs works as-is — and
the converse is now a rule: **nothing may use `sslmode=require`**, it fails with
"server does not support SSL". Verified from the staging VM in both directions.

Staging is provisioned and verified: an app role can create, insert and drop in
`public`, which confirms the PG15 privilege change is handled by ownership.
Generated staging passwords live only at `/root/staging-db-credentials.env` on
`pgsql4` (mode 600) — they are the source for the staging service `.env` files.

The Redash role is **`redash_readonly`**, and its password is **not** generated
here: set `REDASH_PW` to whatever Redash is already configured with in its own
`.env`. This script creates the role and its grants; it does not pick the
credential.

Production database sizes, measured on the managed instance:

| Database | Size |
|---|---|
| `prod_grom` | 270 MB |
| `prod_profile` | 68 MB |
| `prod_events_srv` | 16 MB |
| `prod_accounting` | 8 MB |
| **total** | **~362 MB** |

At that size a full dump + restore is a matter of minutes, which settles the
cutover-window question: the decided full-dump approach is comfortably fine and
there was never a case for an incremental path.
