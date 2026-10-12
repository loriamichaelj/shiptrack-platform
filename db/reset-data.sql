-- Deletes every shipment and what hangs off it, then optionally seeds five demo shipments.
--
-- Run as the application role (shiptrack_app, which has DML on every table), connected to the
-- `shiptrack` database, in one transaction, with the seed switch as a psql variable:
--   psql -X -q -tA --single-transaction -v ON_ERROR_STOP=1 -v seed=yes -f db/reset-data.sql <conninfo>
-- scripts/reset-data.sh does this on a legacy host (ADR-0034); the ShipTrack-ResetData document
-- carries a copy of this file.
--
-- Deleted: sla_alerts, pod_documents, tracking_events, shipments, in foreign-key order.
-- Kept: carriers (reference data) and the schema.
--
-- The seeded shipments have fixed tracking numbers so that they can be looked up by hand:
--   MF0000000001 Created, MF0000000002 Picked up, MF0000000003 In transit,
--   MF0000000004 Out for delivery, MF0000000005 Delivered
--
-- Output is lines of numbers and these synthetic tracking numbers:
--   RESET_DATA deleted shipments=<n> tracking_events=<n> pod_documents=<n> sla_alerts=<n>
--   RESET_DATA now shipments=<n> carriers=<n>
--   SEEDED MF0000000001 MF0000000002 ...

\set ON_ERROR_STOP on

WITH d AS (DELETE FROM shiptrack.sla_alerts RETURNING 1)
SELECT count(*) AS sla_alerts FROM d \gset deleted_
WITH d AS (DELETE FROM shiptrack.pod_documents RETURNING 1)
SELECT count(*) AS pod_documents FROM d \gset deleted_
WITH d AS (DELETE FROM shiptrack.tracking_events RETURNING 1)
SELECT count(*) AS tracking_events FROM d \gset deleted_
WITH d AS (DELETE FROM shiptrack.shipments RETURNING 1)
SELECT count(*) AS shipments FROM d \gset deleted_

\echo RESET_DATA deleted shipments=:deleted_shipments tracking_events=:deleted_tracking_events pod_documents=:deleted_pod_documents sla_alerts=:deleted_sla_alerts

\if :seed
  DO $$
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM shiptrack.carriers) THEN
      RAISE EXCEPTION 'there is no carrier to seed shipments with';
    END IF;
  END
  $$;

  -- One statement: the shipments, then each one's events, which hang off the rows just inserted.
  -- The carrier is ACME when it exists, otherwise the first one. A number that is already taken is
  -- left alone.
  WITH seed (idx, tracking_number, origin, destination, steps) AS (
    VALUES
      (0, 'MF0000000001', 'Rotterdam', 'Hamburg', 0),
      (1, 'MF0000000002', 'Leeds',     'Cardiff', 1),
      (2, 'MF0000000003', 'Lyon',      'Gdansk',  2),
      (3, 'MF0000000004', 'Bilbao',    'Antwerp', 3),
      (4, 'MF0000000005', 'Hamburg',   'Leeds',   4)
  ),
  carrier AS (
    SELECT id FROM shiptrack.carriers ORDER BY (code = 'ACME') DESC, id LIMIT 1
  ),
  inserted AS (
    INSERT INTO shiptrack.shipments (
      tracking_number, carrier_id, origin, destination, status,
      promised_delivery_at, estimated_delivery_at, delivered_at, last_event_at,
      created_at, updated_at
    )
    SELECT
      s.tracking_number, carrier.id, s.origin, s.destination,
      (ARRAY['CREATED', 'PICKED_UP', 'IN_TRANSIT', 'OUT_FOR_DELIVERY', 'DELIVERED'])[s.steps + 1],
      now() + interval '2 days',
      CASE WHEN s.steps > 0 THEN now() + interval '2 days' - interval '3 hours' END,
      CASE WHEN s.steps = 4 THEN made.at + s.steps * interval '3 hours' END,
      CASE WHEN s.steps > 0 THEN made.at + s.steps * interval '3 hours' END,
      made.at,
      COALESCE(made.at + s.steps * interval '3 hours', made.at)
    FROM seed s
    CROSS JOIN carrier
    CROSS JOIN LATERAL (SELECT now() - (30 - s.idx) * interval '1 hour' AS at) made
    ON CONFLICT (tracking_number) DO NOTHING
    RETURNING id, tracking_number, created_at
  )
  INSERT INTO shiptrack.tracking_events (
    shipment_id, event_type, location, occurred_at, idempotency_key, applied
  )
  SELECT
    i.id,
    (ARRAY['PICKED_UP', 'IN_TRANSIT', 'OUT_FOR_DELIVERY', 'DELIVERED'])[g.n],
    (ARRAY['Origin depot', 'Sorting hub', 'Local depot', 'Destination'])[g.n],
    i.created_at + g.n * interval '3 hours',
    'seed-' || i.tracking_number || '-'
      || (ARRAY['PICKED_UP', 'IN_TRANSIT', 'OUT_FOR_DELIVERY', 'DELIVERED'])[g.n],
    true
  FROM inserted i
  JOIN seed s ON s.tracking_number = i.tracking_number
  CROSS JOIN LATERAL generate_series(1, s.steps) AS g (n)
  ON CONFLICT (idempotency_key) DO NOTHING;
\endif

SELECT 'RESET_DATA now shipments=' || (SELECT count(*) FROM shiptrack.shipments)
       || ' carriers=' || (SELECT count(*) FROM shiptrack.carriers);

SELECT 'SEEDED ' || string_agg(tracking_number, ' ' ORDER BY tracking_number)
FROM shiptrack.shipments
WHERE tracking_number IN
  ('MF0000000001', 'MF0000000002', 'MF0000000003', 'MF0000000004', 'MF0000000005')
HAVING count(*) > 0 AND :'seed' = 'yes';
