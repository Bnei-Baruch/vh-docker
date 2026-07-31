-- Roles and databases for one VH environment.
--
-- Run via ../provision.sh, which supplies every :variable. Idempotent: re-running
-- creates nothing that already exists (it will NOT reset passwords — do that by
-- hand with ALTER ROLE if you need to).
--
-- Each app role OWNS its database. That is deliberate and not just tidiness:
-- PostgreSQL 15 removed PUBLIC's CREATE privilege on the `public` schema, so a
-- non-owner app role can no longer create tables there and every `migrate` run
-- would fail on a fresh PG18 database. Owning the database makes the role an
-- implicit member of pg_database_owner, which owns `public`, and the problem
-- disappears without hand-granting schema privileges.

\set ON_ERROR_STOP on

-- ------------------------------------------------------------------ roles ---

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'orders_user', :'orders_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'orders_user')
\gexec

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'events_user', :'events_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'events_user')
\gexec

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'profile_user', :'profile_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'profile_user')
\gexec

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'accounting_user', :'accounting_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'accounting_user')
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

-- ------------------------------------------------------------- extensions ---
-- Only plpgsql is in use (confirmed on the managed PG for orders and events),
-- and it is installed by default in every new database. Nothing to do here —
-- this note exists so the next person does not go looking.
