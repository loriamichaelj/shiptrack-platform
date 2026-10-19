# validation

The shared definition of "correct" for ShipTrack, and the tools that check a live stack against it. Legacy and
modern are judged by the same suite, so a cutover step is a comparison of two stacks by one measuring stick.

| Folder | What it is | Used for |
|---|---|---|
| `contract/` | pytest + httpx suite, the executable form of the API spec in `shiptrack-legacy/docs/DESIGN.md` §3 | Gate G1: does the stack behave correctly? |
| `loadtest/` | k6 scenarios (`baseline`, `stress`, `soak`) | Traffic for the gates to measure, and the G3 latency comparison |
| `simulator/` | Carrier event simulator with a ledger of accepted events | Proving no event is lost (G5 and the wave 2 ledger check) |

This README is the map. The cutover procedure itself is `docs/runbooks/cutover.md`, and the design is
`docs/DESIGN.md` §6.10.

## How it fits in the cutover

Traffic moves by changing ALB weights in `terraform/envs/dev/terraform.tfvars`, by pull request. Validation is
what says whether a weight step is safe to keep. Every step runs the same loop:

```
weights change (PR, apply)  ->  load  ->  watch  ->  judge the gates  ->  record  ->  go / hold / roll back
                                 |                        |
                       check-live-stack.yml     check-live-stack.yml (G1, G3)
                       k6-baseline, target none check-cutover-gates.yml (G2, G3 info, G4, G5)
```

Two workflows do the work. Both run on `dev` with the read-only plan role, need no approval, and change nothing
in AWS.

### `check-live-stack.yml`: the suites

Dispatched by hand. It reads the base URL and the test token from SSM and Secrets Manager (both masked), then runs
one suite against one target.

| Input | Values |
|---|---|
| `suite` | `contract-smoke` (fast, post-deploy), `contract-full` (everything except the SLA wait), `contract-sla` (waits up to 12 minutes for the SLA scan), `k6-baseline` |
| `target` | `legacy`, `modern`, `none` (weighted routing, as real users get it), `both` (k6 only: each iteration goes to one stack at random, from one runner) |
| `duration` | k6 only, for example `10m`; the baseline defaults to 30 minutes at 20 rps |

The `target` value becomes the `X-ShipTrack-Target` header. With the test token it pins a request to one stack
whatever the weights say, so the same suite can be pointed at modern while it holds 0% of traffic.
With `TARGET` set, every response must carry `X-ShipTrack-Stack` equal to it; if not, the run fails and names
routing fall-through as the cause.

### `check-cutover-gates.yml`: the verdict

Reads CloudWatch for a window (`window_minutes`, 30 per weight step) and prints a table to the run summary.

| Gate | Criterion | Judged by |
|---|---|---|
| G1 Correctness | Contract suite passes with `TARGET=modern` | `check-live-stack.yml`, `contract-full` |
| G2 Errors | modern 5xx ratio is at most legacy's plus 0.5 pp | `check-cutover-gates.yml` |
| G3 Latency | per route, p95 at most 1.2 x legacy's (`POST /events`: legacy plus 50 ms) | `check-live-stack.yml`, `k6-baseline`, target `both` |
| G4 Stability | no SEV1 alarm, no pod restarts from the release | `check-cutover-gates.yml` |
| G5 Async health (wave 2 on) | events queue age under 60 s, dead-letter queues empty | `check-cutover-gates.yml`, wave 2 |

A gate with fewer than `min_requests` (default 100) in either target group is `NO DATA`, never a pass. That is why
the load step comes first: at 10% weight with no traffic there is nothing to compare.

## What each tool does

### contract

- Every test creates its own data with unique tracking numbers, under the reserved carrier `ZZTEST`, so it is safe
  against the live environment.
- Markers: `smoke` (at most one shipment), `full`, `ui`, `proof_of_delivery`, `sla`.
- Proof of delivery tests upload and then read back, so they need `TARGET` other than `none`: weighted routing
  could send the two calls to different stacks.
- UI checks assert what each stack serves (the HTML shell, hashed assets with immutable caching, SPA deep links).
  The UI is not compared across stacks.
- Results are JUnit XML in `contract/results/`.

Run it locally against a stack you can reach:

```sh
cd validation/contract
uv sync --frozen
export BASE_URL=...  TARGET=modern  TEST_TOKEN=...
uv run pytest -m smoke
```

### loadtest

Mix: 75% `GET /track`, 15% events, 5% creates, 5% UI page loads. Thresholds: `http_req_failed < 1%` and
`p(95) < 500 ms`, overall and per route. Every request is tagged with its target, and the summary JSON in
`loadtest/results/` is the before and after evidence. With `both`, the summary also prints modern's p50 and p95 as a
ratio of legacy's for each route, which is the number G3 wants.

| Scenario | Shape |
|---|---|
| `baseline` | 20 rps for 30 minutes |
| `stress` | ramps to 200 rps |
| `soak` | 20 rps for 2 hours |

### simulator

Plays carrier traffic (create, `PICKED_UP`, `IN_TRANSIT`, `OUT_FOR_DELIVERY`, `DELIVERED`) with duplicates,
out-of-order events, exceptions, late shipments, and proof of delivery uploads, and writes every accepted event to
a ledger. `verify` then reports events that were accepted but never stored. See `simulator/README.md`.

## By wave

| Wave | Validation |
|---|---|
| 0, dark launch (weights 0) | `contract-full` on modern; `k6-baseline` on legacy then modern for the G2 and G3 baseline; `check-security-findings.yml`; alarms in `OK` |
| 1, read path and UI | each step: `k6-baseline` target `none`, `contract-smoke` on modern, then `check-cutover-gates.yml`; G1 to G4 |
| 2, write path | each step as above with wave `2`, so G5 is judged; plus the simulator ledger shows 0 lost events and no `pod_not_migrated` proof of delivery older than 5 minutes |
| 3, scheduled jobs | verify exactly one SLA alert per breach; legacy stays as the fallback |

`NO DATA` or any `FAIL` is a stop. If a gate fails or a SEV1 alarm fires while a step is judged, roll back first and
investigate second: a pull request that restores the previous weights, or `ops-rollback-cutover.yml` when users are
affected.

## Evidence

Each step is recorded with its run links, the gate table, the k6 summaries, the contract JUnit XML, and a go/no-go
note, stored in `shiptrack-modern` under `docs/migration/wave-N/`. The template is at the end of
`docs/runbooks/cutover.md`. Nothing in the evidence may contain an account ID, ARN, ALB address, or the test token:
the workflows mask them and upload no artifacts, so copy numbers and run links, not logs.

## Consumers

`shiptrack-legacy` and `shiptrack-modern` check this repository out at a pinned commit SHA and run `validation/`
from their own pipelines. The repository is public, so no token is needed. Changing a test here changes what both
stacks are held to, so it is a platform change, reviewed as one.
