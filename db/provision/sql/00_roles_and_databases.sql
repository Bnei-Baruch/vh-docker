-- Roles and databases for one VH environment.
--
-- Run via ../provision.sh, which supplies every :variable.
--
-- Idempotent and CONVERGENT: re-running creates nothing that already exists, but
-- it does re-apply each role's password every time. That second part matters —
-- an earlier version only set the password at creation time, which meant a
-- changed credential could not be rolled out by re-running the script and had to
-- be fixed with a hand-written ALTER ROLE. That puts the live cluster into a
-- state the repo cannot reproduce, which defeats the point of having this file.
--
-- Consequence: provision.env is authoritative for these passwords. Running with
-- a wrong value overwrites a working credential, so keep it in step with the
-- service .env files.
--
-- Each app role OWNS its database. That is deliberate and not just tidiness:
-- PostgreSQL 15 removed PUBLIC's CREATE privilege on the `public` schema, so a
-- non-owner app role can no longer create tables there and every `migrate` run
-- would fail on a fresh PG18 database. Owning the database makes the role an
-- implicit member of pg_database_owner, which owns `public`, and the problem
-- disappears without hand-granting schema privileges.

\set ON_ERROR_STOP on

-- ------------------------------------------------------------------ roles ---

SELECT format('CREATE ROLE %I LOGIN', :'orders_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'orders_user')
\gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'orders_user', :'orders_pw')
\gexec

SELECT format('CREATE ROLE %I LOGIN', :'events_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'events_user')
\gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'events_user', :'events_pw')
\gexec

SELECT format('CREATE ROLE %I LOGIN', :'profile_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'profile_user')
\gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'profile_user', :'profile_pw')
\gexec

SELECT format('CREATE ROLE %I LOGIN', :'accounting_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'accounting_user')
\gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'accounting_user', :'accounting_pw')
\gexec

-- -------------------------------------------------------------- databases ---

SELECT format('CREATE DATABASE %I OWNER %I', :'orders_db', :'orders_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'orders_db')
\gexec

SELECT format('CREATE DATABASE %I OWNER %I', :'events_db', :'events_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'events_db')
\gexec

SELECT format('CREATE DATABASE %I OWNER %I', :'profile_db', :'profile_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'profile_db')
\gexec

SELECT format('CREATE DATABASE %I OWNER %I', :'accounting_db', :'accounting_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'accounting_db')
\gexec

-- --------------------------------------------------------------- isolation ---
-- Each role may reach ONLY its own database. redash_readonly is the single
-- exception and is granted CONNECT per database by 10_redash_readonly.sql.
--
-- This matters because prod_* and staging_* share one cluster. PostgreSQL grants
-- CONNECT and TEMPORARY to PUBLIC on every new database, so without the revoke
-- below any role — including a staging service account — can connect to any
-- other database, read its full schema out of information_schema, enumerate
-- every role, and create temp tables in it. Application rows stay unreadable
-- (no table grants), but the schema and metadata do not, and a staging
-- credential should never be a way into production at all.
--
-- The owner keeps its own access: ownership carries CONNECT and TEMPORARY
-- independently of PUBLIC, and the explicit GRANT below states it rather than
-- relying on that.
--
-- Not covered: the `postgres` maintenance database is left alone, so the shared
-- catalogs (pg_database, pg_roles) remain listable by any role. That exposes the
-- existence and names of the other environment's databases and roles, but no
-- schema and no data. Locking it down risks the provided infra's own tooling.

SELECT format('REVOKE CONNECT, TEMPORARY ON DATABASE %I FROM PUBLIC', d)
FROM unnest(ARRAY[:'orders_db', :'events_db', :'profile_db', :'accounting_db']) AS d
\gexec

SELECT format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO %I', d.db, d.owner)
FROM (VALUES (:'orders_db', :'orders_user'),
             (:'events_db', :'events_user'),
             (:'profile_db', :'profile_user'),
             (:'accounting_db', :'accounting_user')) AS d(db, owner)
\gexec

-- ------------------------------------------------------------- extensions ---
-- Only plpgsql is in use (confirmed on the managed PG for orders and events),
-- and it is installed by default in every new database. Nothing to do here —
-- this note exists so the next person does not go looking.
