-- Creates the ShipTrack database, its two login roles, and the schema. Safe to run again: it
-- creates what is missing and resets the role passwords to the values given.
--
-- Run it as the RDS master user, connected to the `postgres` database:
--   psql "host=<host> dbname=postgres user=<master> sslmode=verify-full sslrootcert=<bundle>" \
--     -v ON_ERROR_STOP=1 -v migrator_password="$MIGRATOR_PASSWORD" -v app_password="$APP_PASSWORD" \
--     -f db/bootstrap.sql
-- See db/RUNBOOK-db-bootstrap.md. Passwords come in as psql variables and are never literals here.

\set ON_ERROR_STOP on

-- Hand the passwords to the server session so the DO blocks below can read them. A psql variable
-- is not expanded inside a dollar-quoted body.
SELECT set_config('shiptrack.migrator_password', :'migrator_password', false) AS _ \gset
SELECT set_config('shiptrack.app_password', :'app_password', false) AS _ \gset

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'shiptrack_migrator') THEN
    CREATE ROLE shiptrack_migrator LOGIN CONNECTION LIMIT 150;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'shiptrack_app') THEN
    CREATE ROLE shiptrack_app LOGIN CONNECTION LIMIT 200;
  END IF;
  -- Reset on every run: this is also how a rotated password reaches the database.
  EXECUTE format('ALTER ROLE shiptrack_migrator PASSWORD %L', current_setting('shiptrack.migrator_password'));
  EXECUTE format('ALTER ROLE shiptrack_app PASSWORD %L', current_setting('shiptrack.app_password'));
END
$$;

-- CREATE DATABASE cannot run inside a DO block or a transaction, so \gexec runs it only when missing.
SELECT 'CREATE DATABASE shiptrack OWNER shiptrack_migrator'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'shiptrack')
\gexec

-- The master needs the migrator role to own objects on its behalf. The grant is removed again at the end.
GRANT shiptrack_migrator TO CURRENT_USER;

\connect shiptrack

REVOKE CREATE ON SCHEMA public FROM PUBLIC;

CREATE SCHEMA IF NOT EXISTS shiptrack AUTHORIZATION shiptrack_migrator;
ALTER SCHEMA shiptrack OWNER TO shiptrack_migrator;

GRANT CONNECT ON DATABASE shiptrack TO shiptrack_migrator, shiptrack_app;
GRANT USAGE ON SCHEMA shiptrack TO shiptrack_app;

-- Tables and sequences the migrator creates later are usable by the application without a new grant.
ALTER DEFAULT PRIVILEGES FOR ROLE shiptrack_migrator IN SCHEMA shiptrack
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO shiptrack_app;
ALTER DEFAULT PRIVILEGES FOR ROLE shiptrack_migrator IN SCHEMA shiptrack
  GRANT USAGE, SELECT ON SEQUENCES TO shiptrack_app;

-- Objects that already exist (a re-run after the first migration) get the same privileges.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA shiptrack TO shiptrack_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA shiptrack TO shiptrack_app;

REVOKE shiptrack_migrator FROM CURRENT_USER;
