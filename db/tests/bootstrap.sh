#!/usr/bin/env bash
# Runs db/bootstrap.sql twice against a throwaway PostgreSQL 17 container and checks that the roles,
# schema, and privileges are right and that the second run changes nothing. Needs Docker.
# Usage: db/tests/bootstrap.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${POSTGRES_IMAGE:-postgres:17@sha256:2d2b8998d31037bf721cfdf764d76ba74171b4fab3431b7f72c27c56ddbdf9e3}
name=shiptrack-bootstrap-test-$$
failures=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected [$3] got [$2]"; fi; }

cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --rm --name "$name" -e POSTGRES_PASSWORD=master-test-only "$image" >/dev/null
for _ in $(seq 1 60); do
  docker exec "$name" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
# The image restarts once during initialisation; wait until a query succeeds.
for _ in $(seq 1 30); do
  docker exec "$name" psql -U postgres -tAc 'SELECT 1' >/dev/null 2>&1 && break
  sleep 1
done

docker cp "$here/bootstrap.sql" "$name:/tmp/bootstrap.sql"

# The RDS master is not a superuser: it can create roles and databases, and nothing more. The script
# is run as such a role, because a superuser would hide a statement that is out of order (the grant of
# the migrator role must come before the database it owns is created).
docker exec "$name" psql -U postgres -q -c "CREATE ROLE rdsmaster LOGIN CREATEROLE CREATEDB PASSWORD 'master-test-only'"
host=$(docker exec "$name" hostname -i | awk '{print $1}')

run_bootstrap() {
  docker exec -e PGPASSWORD=master-test-only "$name" psql -h "$host" -U rdsmaster -d postgres \
    -v ON_ERROR_STOP=1 -q -v migrator_password="$1" -v app_password="$2" -f /tmp/bootstrap.sql >/dev/null
}
sql() { docker exec "$name" psql -U postgres -d "${2:-shiptrack}" -tAc "$1"; }

echo "== first run"
run_bootstrap migrator-pw-1 app-pw-1
echo "== second run (must succeed and change nothing)"
run_bootstrap migrator-pw-1 app-pw-1

echo "== roles"
eq "migrator can log in, limit 150" "$(sql "SELECT rolcanlogin || ':' || rolconnlimit FROM pg_roles WHERE rolname='shiptrack_migrator'" postgres)" "true:150"
eq "app can log in, limit 200" "$(sql "SELECT rolcanlogin || ':' || rolconnlimit FROM pg_roles WHERE rolname='shiptrack_app'" postgres)" "true:200"
eq "the master is not a superuser" "$(sql "SELECT rolsuper FROM pg_roles WHERE rolname='rdsmaster'" postgres)" "f"
eq "neither role is a superuser" "$(sql "SELECT count(*) FROM pg_roles WHERE rolname IN ('shiptrack_migrator','shiptrack_app') AND (rolsuper OR rolcreatedb OR rolcreaterole)" postgres)" "0"
eq "each role exists once" "$(sql "SELECT count(*) FROM pg_roles WHERE rolname LIKE 'shiptrack\_%'" postgres)" "2"

echo "== schema"
eq "the database exists once" "$(sql "SELECT count(*) FROM pg_database WHERE datname='shiptrack'" postgres)" "1"
eq "the schema is owned by the migrator" "$(sql "SELECT schema_owner FROM information_schema.schemata WHERE schema_name='shiptrack'")" "shiptrack_migrator"
eq "PUBLIC cannot create in public" "$(sql "SELECT has_schema_privilege('public','public','CREATE')")" "f"
eq "the app can use the schema" "$(sql "SELECT has_schema_privilege('shiptrack_app','shiptrack','USAGE')")" "t"
eq "the app cannot create in the schema" "$(sql "SELECT has_schema_privilege('shiptrack_app','shiptrack','CREATE')")" "f"

echo "== privileges on objects the migrator creates later"
docker exec -i "$name" psql -U postgres -d shiptrack -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
SET ROLE shiptrack_migrator;
CREATE TABLE shiptrack.probe (id serial PRIMARY KEY, note text);
SQL
eq "the app has DML on a new table" "$(sql "SELECT string_agg(p, ',' ORDER BY p) FROM unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE']) p WHERE has_table_privilege('shiptrack_app','shiptrack.probe',p)")" "DELETE,INSERT,SELECT,UPDATE"
eq "the app has no DDL on a new table" "$(sql "SELECT has_table_privilege('shiptrack_app','shiptrack.probe','TRUNCATE') OR has_table_privilege('shiptrack_app','shiptrack.probe','REFERENCES')")" "f"
eq "the app can use a new sequence" "$(sql "SELECT has_sequence_privilege('shiptrack_app','shiptrack.probe_id_seq','USAGE')")" "t"

echo "== a third run, after the table exists, and a password change"
run_bootstrap migrator-pw-2 app-pw-2
eq "the app still has DML after a re-run" "$(sql "SELECT has_table_privilege('shiptrack_app','shiptrack.probe','INSERT')")" "t"
eq "the new password works" "$(docker exec -e PGPASSWORD=app-pw-2 "$name" psql -h "$host" -U shiptrack_app -d shiptrack -tAc 'SELECT current_user')" "shiptrack_app"
eq "the old password is rejected" "$(docker exec -e PGPASSWORD=app-pw-1 "$name" psql -h "$host" -U shiptrack_app -d shiptrack -tAc 'SELECT 1' 2>&1 | grep -c 'password authentication failed')" "1"

echo
if [[ "$failures" -eq 0 ]]; then echo "all checks passed"; else echo "$failures check(s) failed"; exit 1; fi
