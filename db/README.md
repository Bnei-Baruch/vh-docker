# Database

`vh-db` is **provided infrastructure**. PostgreSQL 18 is installed and backed up
by whoever owns that VM. This repo does not install postgres, does not run it in
Docker, and does not manage backups — it only provisions what the applications
need on top.

## Provisioning

```bash
cd db/provision
cp provision.env.example provision.env   # fill in
set -a; source provision.env; set +a
./provision.sh staging          # or: production
```

Idempotent. Re-running creates nothing that already exists — and deliberately
does **not** reset passwords; use `ALTER ROLE` by hand for that.

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

Dump with the **PG18** client against the managed PG12 instance
(`195.154.69.180:64612`), not the PG12 client:

```bash
pg_dump -h 195.154.69.180 -p 64612 -U <user> -Fc -f prod_grom.dump prod_grom
pg_restore -h vh-db -U postgres -d prod_grom --no-owner --no-privileges prod_grom.dump
```

`--no-owner --no-privileges` because the source ownership and grants refer to
managed-instance roles that do not exist here; ownership comes from the
provisioning above instead. Re-run `10_redash_readonly.sql` after a restore —
it replaces objects the grants were attached to.

**Time every dump and restore.** The cutover window is a full dump + restore
(decided — no incremental path), so these numbers *are* the window length.
