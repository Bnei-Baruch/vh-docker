-- Read-only role for Redash, applied per database.
--
-- The managed Scaleway instance had an equivalent; the new databases start with
-- nothing, so Redash cannot connect until this runs. Run once per database (see
-- provision.sh) — object-level grants are database-scoped.
--
-- Invoked with :'redash_user' and :'owner' (the app role that owns this database),
-- and connected TO the target database, not to `postgres`.

\set ON_ERROR_STOP on

-- The role is cluster-wide, so create it only once; provision.sh calls this file
-- per database and the guard makes the repeats harmless.
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'redash_user', :'redash_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'redash_user')
\gexec

SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'redash_user')
\gexec

GRANT USAGE ON SCHEMA public TO :"redash_user";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO :"redash_user";
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO :"redash_user";

-- Tables created later — by `migrate`, or by the cutover restore — would not be
-- covered by the grants above. Default privileges must be attached to the role
-- that will create them, which is the database owner.
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public
    GRANT SELECT ON TABLES TO :"redash_user";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public
    GRANT SELECT ON SEQUENCES TO :"redash_user";
