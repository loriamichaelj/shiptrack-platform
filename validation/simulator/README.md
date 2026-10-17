# shiptrack-simulator

A carrier event simulator for ShipTrack. It creates shipments, tells each one's story as a stream of
tracking events, and keeps a ledger of every event the API accepted, so events that were accepted but
never stored can be found afterwards.

```sh
cd validation/simulator
uv sync --frozen

export BASE_URL=http://localhost:8000     # the stack's base URL
export TARGET=legacy                      # legacy | modern | none (sets X-ShipTrack-Target)
export TEST_TOKEN=...                     # the test-routing token, when TARGET is not none

uv run shiptrack-sim run --shipments 100 --concurrency 10 --seed 1
uv run shiptrack-sim verify --ledger results/sent-<timestamp>.jsonl --db-url "$DATABASE_URL"
```

## What a run does

- Creates `--shipments` shipments across the carriers `ACME`, `BOLT`, `CRWN`, and `MFLT`.
- Sends each shipment through `PICKED_UP`, `IN_TRANSIT`, `OUT_FOR_DELIVERY`, and `DELIVERED`, with
  jitter between steps. The same `--seed` plans the same run.
- Injects 1% duplicate events (same `Idempotency-Key`), 2% out-of-order events, and 1% `EXCEPTION`
  paths. 5% of shipments are created already late, so the SLA scanner has work to do.
- Uploads a small generated PNG or PDF as the proof of delivery. It never reads one back: an upload
  and its read-back must reach the same stack, and weighted routing could split them.
- Writes one JSON line per accepted (202) event to `results/sent-<timestamp>.jsonl`.

## verify

`verify` reports events in the ledger that were accepted but never stored. It can look two ways.

**In the database** (`--db-url`). The database is private, so this runs on a host inside the network. It needs
only `psycopg`, which the release virtualenv already has: install the wheel there with `--no-deps`. This is how
legacy AP-06 (an in-process queue that loses events on restart) is proven.

**Through the API** (`--base-url`). An event the API accepted appears in its shipment's tracking timeline once a
worker has applied it, so a runner with no database access can check the same thing, for example through a
`kubectl port-forward`. `--wait SECONDS` keeps looking for the missing events, because workers apply them
after the API answers `202`:

```sh
uv run shiptrack-sim verify --ledger results/sent-<timestamp>.jsonl --base-url http://localhost:18000 --wait 300
```

An event is matched by its type and the time it occurred.

Test data goes under whichever carriers the plan picks; the carrier `ZZTEST` is reserved for the
contract suite. Nothing in the API deletes it: `ops-reset-data.yml` clears every shipment.
