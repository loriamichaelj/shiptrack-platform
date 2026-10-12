#!/usr/bin/env bash
# Runs db/reset-data.sql as the application role against a throwaway PostgreSQL 17 container that
# has the schema shiptrack-legacy's migration creates, and checks what it deletes, what it keeps,
# and what it seeds. Needs Docker.
# Usage: db/tests/reset-data.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${POSTGRES_IMAGE:-postgres:17@sha256:2d2b8998d31037bf721cfdf764d76ba74171b4fab3431b7f72c27c56ddbdf9e3}
name=shiptrack-reset-test-$$
failures=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected [$3] got [$2]"; fi; }

cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --rm --name "$name" -e POSTGRES_PASSWORD=master-test-only "$image" >/dev/null
for _ in $(seq 1 60); do docker exec "$name" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
for _ in $(seq 1 30); do docker exec "$name" psql -U postgres -tAc 'SELECT 1' >/dev/null 2>&1 && break; sleep 1; done

docker cp "$here/bootstrap.sql" "$name:/tmp/bootstrap.sql"
docker cp "$here/reset-data.sql" "$name:/tmp/reset-data.sql"
docker cp "$here/tests/schema-fixture.sql" "$name:/tmp/schema-fixture.sql"

docker exec "$name" psql -U postgres -q -c "CREATE ROLE rdsmaster LOGIN CREATEROLE CREATEDB PASSWORD 'master-test-only'"
host=$(docker exec "$name" hostname -i | awk '{print $1}')
docker exec -e PGPASSWORD=master-test-only "$name" psql -h "$host" -U rdsmaster -d postgres \
  -v ON_ERROR_STOP=1 -q -v migrator_password=migrator-test-only -v app_password=app-test-only \
  -f /tmp/bootstrap.sql >/dev/null
docker exec -e PGPASSWORD=migrator-test-only "$name" psql -h "$host" -U shiptrack_migrator -d shiptrack \
  -v ON_ERROR_STOP=1 -q -f /tmp/schema-fixture.sql >/dev/null

# The reset, as the application role, the way scripts/reset-data.sh runs it.
reset() {
  docker exec -e PGPASSWORD=app-test-only "$name" psql -h "$host" -U shiptrack_app -d shiptrack \
    -X -q -tA --single-transaction -v ON_ERROR_STOP=1 -v "seed=$1" -f /tmp/reset-data.sql
}
sql() { docker exec "$name" psql -U postgres -d shiptrack -tAc "$1"; }

# Data a run should clear: a shipment with an event, a document, and two alerts.
docker exec -i "$name" psql -U postgres -d shiptrack -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
INSERT INTO shiptrack.shipments (tracking_number, carrier_id, origin, destination, promised_delivery_at)
SELECT 'ZZ' || n, (SELECT id FROM shiptrack.carriers WHERE code = 'ZZTEST'), 'A', 'B', now()
FROM generate_series(1, 3) n;
INSERT INTO shiptrack.tracking_events (shipment_id, event_type, location, occurred_at, idempotency_key, applied)
SELECT id, 'PICKED_UP', 'depot', now(), 'k-' || tracking_number, true FROM shiptrack.shipments;
INSERT INTO shiptrack.pod_documents (id, shipment_id, storage_uri, content_type, size_bytes, sha256)
SELECT gen_random_uuid(), id, 's3://b/pod/x', 'image/png', 1, repeat('0', 64)
FROM shiptrack.shipments LIMIT 1;
INSERT INTO shiptrack.sla_alerts (shipment_id, detected_by)
SELECT id, 'host' FROM shiptrack.shipments LIMIT 1;
INSERT INTO shiptrack.sla_alerts (shipment_id, detected_by)
SELECT id, 'host' FROM shiptrack.shipments LIMIT 1;
SQL

echo "== with the demo shipments"
out=$(reset yes)
eq "it reports what it deleted" "$(grep '^RESET_DATA deleted' <<<"$out")" \
  "RESET_DATA deleted shipments=3 tracking_events=3 pod_documents=1 sla_alerts=2"
eq "it reports the five seeded numbers" "$(grep '^SEEDED' <<<"$out")" \
  "SEEDED MF0000000001 MF0000000002 MF0000000003 MF0000000004 MF0000000005"
eq "five shipments and the carriers remain" "$(grep '^RESET_DATA now' <<<"$out")" "RESET_DATA now shipments=5 carriers=3"
eq "nothing else is printed" "$(wc -l <<<"$out" | tr -d ' ')" "3"
eq "the old shipments are gone" "$(sql "SELECT count(*) FROM shiptrack.shipments WHERE tracking_number LIKE 'ZZ%'")" "0"
eq "documents and alerts are gone" "$(sql "SELECT (SELECT count(*) FROM shiptrack.pod_documents) + (SELECT count(*) FROM shiptrack.sla_alerts)")" "0"
eq "the seeded shipments use ACME" "$(sql "SELECT string_agg(DISTINCT c.code, ',') FROM shiptrack.shipments s JOIN shiptrack.carriers c ON c.id = s.carrier_id")" "ACME"
eq "one shipment in each of five statuses" \
  "$(sql "SELECT string_agg(status, ',' ORDER BY tracking_number) FROM shiptrack.shipments")" \
  "CREATED,PICKED_UP,IN_TRANSIT,OUT_FOR_DELIVERY,DELIVERED"
eq "events per shipment follow the lifecycle" \
  "$(sql "SELECT string_agg(n::text, ',' ORDER BY tracking_number) FROM (SELECT s.tracking_number, count(e.id) n FROM shiptrack.shipments s LEFT JOIN shiptrack.tracking_events e ON e.shipment_id = s.id GROUP BY 1) q")" \
  "0,1,2,3,4"
eq "the delivered one has a delivery time and the others do not" \
  "$(sql "SELECT string_agg((delivered_at IS NOT NULL)::text, ',' ORDER BY tracking_number) FROM shiptrack.shipments")" \
  "false,false,false,false,true"
eq "the last event matches the status" \
  "$(sql "SELECT count(*) FROM shiptrack.shipments s WHERE s.status <> 'CREATED' AND s.status <> (SELECT e.event_type FROM shiptrack.tracking_events e WHERE e.shipment_id = s.id ORDER BY e.occurred_at DESC LIMIT 1)")" "0"

echo "== a second run leaves the same five"
out=$(reset yes)
eq "it deletes the five and seeds them again" "$(grep '^RESET_DATA deleted' <<<"$out")" \
  "RESET_DATA deleted shipments=5 tracking_events=10 pod_documents=0 sla_alerts=0"
eq "the same five remain" "$(sql "SELECT count(*) FROM shiptrack.shipments")" "5"

echo "== without the demo shipments"
out=$(reset no)
eq "nothing is seeded or announced" "$(grep -c '^SEEDED' <<<"$out" || true)" "0"
eq "the tables are empty and the carriers remain" \
  "$(sql "SELECT (SELECT count(*) FROM shiptrack.shipments) || ',' || (SELECT count(*) FROM shiptrack.tracking_events) || ',' || (SELECT count(*) FROM shiptrack.carriers)")" "0,0,3"

echo "== a failure changes nothing"
docker exec "$name" psql -U postgres -d shiptrack -q -c "DELETE FROM shiptrack.carriers" >/dev/null
docker exec "$name" psql -U postgres -d shiptrack -q -c "INSERT INTO shiptrack.carriers (code, name) VALUES ('ACME', 'Acme Freight')" >/dev/null
docker exec "$name" psql -U postgres -d shiptrack -q -c "
  INSERT INTO shiptrack.shipments (tracking_number, carrier_id, origin, destination, promised_delivery_at)
  SELECT 'KEEP1', id, 'A', 'B', now() FROM shiptrack.carriers LIMIT 1" >/dev/null
docker exec "$name" psql -U postgres -d shiptrack -q -c "ALTER TABLE shiptrack.shipments ADD CONSTRAINT ck_boom CHECK (tracking_number <> 'MF0000000003')" >/dev/null
if reset yes >/dev/null 2>&1; then fail "a seed that violates a constraint must fail"; else pass "a seed that violates a constraint fails"; fi
eq "the shipment it was going to delete is still there" "$(sql "SELECT count(*) FROM shiptrack.shipments WHERE tracking_number = 'KEEP1'")" "1"

echo
if [[ "$failures" -eq 0 ]]; then echo "all checks passed"; else echo "$failures check(s) failed"; exit 1; fi
