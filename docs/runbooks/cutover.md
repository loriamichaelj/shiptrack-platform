# Cutover runbook

How traffic moves from `shiptrack-legacy` to `shiptrack-modern`, one reviewed step at a time, and
what to do when an alarm fires while it does. The design is modern design §9 (waves) and platform §7
(gates). The decision to use workflows for rollback and for judging the gates is ADR-0028.

Nobody needs the AWS CLI or the console for any step here: every read and every change is a GitHub
Actions workflow or a pull request, and the `dev` environment's reviewer approves each change.

## What moves traffic

One ALB, two target groups, and weights in `terraform/envs/dev/terraform.tfvars`:

```hcl
cutover = {
  track   = { legacy = 100, modern = 0 }   # GET /api/v1/track/* and GET /ui/*
  default = { legacy = 100, modern = 0 }   # everything else, including every write
}
```

Header rules (`X-ShipTrack-Target` with the test token) send a request to one stack whatever the
weights say, and the preview listener on port 8080 always goes to modern. Neither changes with the
weights. Changing the weights **is** the cutover, so each change is a pull request.

## Tools

| Tool | What it does | Where it runs |
|---|---|---|
| `validation.yml` | The contract suite (`contract-smoke`, `contract-full`, `contract-ui-parity`) or a k6 baseline against one stack | Actions, plan role, no approval |
| `cutover-gates.yml` | Judges G2 to G5 over an evidence window and prints a table of numbers | Actions, plan role, no approval |
| `security-findings.yml` | Inspector findings by scope (modern, legacy, other) and Security Hub CRITICAL and HIGH; fails on a fixable CRITICAL or HIGH in modern | Actions, plan role, no approval |
| `terraform-apply.yml` | Applies a weight change after a reviewer approves the `dev` gate | Actions, apply role |
| `rollback-cutover.yml` | Break-glass: all traffic back to legacy now (`break-glass-rollback.md`) | Actions, apply role, `dev` gate |

## The gates

| Gate | Criterion | Measured by |
|---|---|---|
| G1 Correctness | The contract suite passes against `TARGET=modern` | `validation.yml` `contract-full` |
| G2 Errors | tg-modern 5xx ratio is at most tg-legacy's plus 0.5 pp | `cutover-gates.yml` |
| G3 Latency | Per route, from one runner: p95 at most 1.2 times legacy's, except `POST /events`, which is at most legacy's plus 50 ms (ADR-0031) | `validation.yml` `k6-baseline` with target `both`; `cutover-gates.yml` prints the target-group p95 as information |
| G4 Stability | No SEV1 alarm, no pod restarts from the release | `cutover-gates.yml` |
| G5 Async health (wave 2 on) | Events queue age under 60 s, dead-letter queues empty | `cutover-gates.yml` with wave 2 |
| G6 UI build parity (before wave 1) | Both stacks serve identical hashed UI asset names | `validation.yml` `contract-ui-parity` |

Evidence window: a step is judged once each target group has seen at least `MIN_REQUESTS` requests
(default 100). A gate with too little traffic says `NO DATA`, which is not a pass: run
`validation.yml` with `k6-baseline` and target `none` first, so the weighted rules see load.

## One weight step

1. **Pull request.** Change only the weights in `terraform/envs/dev/terraform.tfvars`. The plan
   comment must show only in-place updates of `module.ingress.aws_lb_listener_rule.ui` and
   `module.ingress.aws_lb_listener_rule.track` (wave 1), or of `module.ingress.aws_lb_listener.http`
   (wave 2; `module.ingress.aws_lb_listener.https` when TLS is on), and of
   `module.observability.aws_cloudwatch_dashboard.cutover`, whose weights table is rendered from the
   same variable. Anything else in the plan stops the step.
2. **Merge and apply.** Merging starts `terraform-apply`, which waits at the `dev` gate. Approve it.
   It takes under a minute.
3. **Load.** Dispatch `validation.yml`: suite `k6-baseline`, target `none`. Then `contract-smoke`
   against `modern` once.
4. **Watch.** Let the load run, and watch for SEV1 notifications while it does.
5. **Judge.** Dispatch `cutover-gates.yml` with a `window_minutes` that covers the load, and the wave. Every row must be
   PASS (or `run validation.yml` for G1 and G6, `n/a` for G5 before wave 2). `NO DATA` is a stop.
6. **Record.** Fill in the go/no-go record below and store it with the evidence in modern's
   `docs/migration/wave-N/`, scrubbed of addresses and identifiers.
7. **Decide.** Next step, hold, or roll back.

## Waves

### Wave 0: dark launch (weights stay 0)

Entry: platform applied; modern cluster, add-ons, and release deployed.

1. `validation.yml`: `contract-full` with target `modern`, then `contract-ui-parity` (G6).
2. `validation.yml`: `k6-baseline` with target `legacy`, then with target `modern`. The two summaries
   are the G2 and G3 baseline.
3. `security-findings.yml`: no fixable CRITICAL or HIGH in modern, which is the `shiptrack/` ECR
   repository, the nodes of the `shiptrack` EKS cluster, and anything tagged `Stack=modern`. Legacy's
   findings are printed as the baseline and are not gated (its AMI is pinned on purpose, AP-14), and
   so are other teams' resources (ADR-0029).
4. Confirm the alarms are in `OK` and the `shiptrack-cutover` dashboard shows both target groups.

Exit: contract green, k6 thresholds met (`http_req_failed < 1%`, `p(95) < 500 ms`), G6 passed, no
fixable CRITICAL or HIGH in modern, and the evidence stored in `docs/migration/wave-0/`. Rollback: none needed.

### Wave 1: read path and UI

Entry: wave 0 exit, including G6. Moves `/api/v1/track/*` and `/ui/*` together. The UI rule is
sticky, so a browser session stays on its stack.

| Step | `track` | PR diff |
|---|---|---|
| 1a | legacy 90, modern 10 | `-  track   = { legacy = 100, modern = 0 }` / `+  track   = { legacy = 90, modern = 10 }` |
| 1b | legacy 50, modern 50 | `-  track   = { legacy = 90, modern = 10 }` / `+  track   = { legacy = 50, modern = 50 }` |
| 1c | legacy 0, modern 100 | `-  track   = { legacy = 50, modern = 50 }` / `+  track   = { legacy = 0, modern = 100 }` |

`default` stays `{ legacy = 100, modern = 0 }`. Gates G1 to G4 each step. Rollback: a pull request
that restores the previous line, or `rollback-cutover.yml` first and the pull request after.

### Wave 2: write path

Entry: wave 1 at 100%; legacy v1.1.0 deployed; `migrate_pod_to_s3.py` run on both legacy hosts; the
PodSync cron installed; the G-POD count is 0; legacy change freeze on (modern design §9.2). The
legacy evidence tooling for G-POD and the ledger check is part of legacy L5 and L6, and is not built
yet: do not start wave 2 without it.

| Step | `default` | PR diff |
|---|---|---|
| 2a | legacy 90, modern 10 | `-  default = { legacy = 100, modern = 0 }` / `+  default = { legacy = 90, modern = 10 }` |
| 2b | legacy 75, modern 25 | `-  default = { legacy = 90, modern = 10 }` / `+  default = { legacy = 75, modern = 25 }` |
| 2c | legacy 50, modern 50 | `-  default = { legacy = 75, modern = 25 }` / `+  default = { legacy = 50, modern = 50 }` |
| 2d | legacy 0, modern 100 | `-  default = { legacy = 50, modern = 50 }` / `+  default = { legacy = 0, modern = 100 }` |

`track` stays `{ legacy = 0, modern = 100 }`. Gates G1 to G5 each step, plus the simulator ledger
shows 0 lost events for modern-routed traffic, and no `pod_not_migrated` for a POD older than 5
minutes. Rollback: restore the previous weights, and keep modern's workers running until its events
queue drains. S3 PODs stay readable by legacy v1.1.0.

### Handoff: schema ownership

Entry: wave 2 at 100% with G1 to G5 passing. Set legacy's `RUN_MIGRATIONS` repository variable to `false`,
then deploy modern with `migrations.enabled=true`; the migration job at head is a no-op. Rollback:
revert both flags. Details: modern design §9.1.

### Wave 3: scheduled jobs and decommission

Entry: handoff complete. In order, as in modern design §9.2:

1. Remove `/etc/cron.d/shiptrack-sla` and `/etc/cron.d/shiptrack-podsync` from the legacy hosts.
2. Turn the modern CronJob on (`slaScan.suspend=false`) and enable its heartbeat alarm.
3. Verify exactly one alert per breach.
4. **Contract migration** (three Alembic revisions). **This is the point of no return for rolling
   back to legacy: after it, forward-fix only.** Before it, re-enable legacy's cron and suspend the
   CronJob.
5. Legacy Auto Scaling group to 0 (a legacy pull request).
6. Once steps 3 and 4 are verified: destroy the legacy stack and remove the `tg-legacy` routing (a platform pull request).

## Roll back

| Situation | Do |
|---|---|
| A gate fails or an alarm fires while a step is being judged, and there is time | Pull request restoring the previous weights; merge; approve the apply |
| User impact now | `rollback-cutover.yml` (all weighted routing to legacy 100), then the pull request within 24 hours |
| After wave 3 step 4 | Forward-fix only. Do not route back to legacy |

## Alarms

Every alarm description links here. If one fires during a wave, treat it as a failed gate for that
step: roll back first, investigate second.

### tg-legacy-5xx-ratio

SEV1. More than 2% of requests to legacy's target group returned 5xx. Legacy errors are not a
cutover failure by themselves, but they move the G2 baseline, so a step judged while this is firing
proves nothing. Check the latest legacy deploy (`deploy.yml` in `shiptrack-legacy`) and the legacy
hosts' health before continuing any step.

### tg-modern-5xx-ratio

SEV1. More than 2% of requests to modern's target group returned 5xx. During a wave this is G2
failing: run `rollback-cutover.yml`, then look at modern's latest deploy and its alarms. At weight 0
it can only be your own test traffic.

### tg-legacy-p99-latency

SEV2. Legacy's p99 response time is above 1 second. It moves the G3 baseline. Check the database
alarms below, since both stacks share one RDS instance.

### tg-modern-p99-latency

SEV2. Modern's p99 is above 1 second. During a wave this points at G3. Check the database alarms,
then modern's pod count and restarts. If it persists while a step is judged, roll back.

### tg-legacy-unhealthy-hosts

SEV2. A legacy host has been unhealthy for 5 minutes. The remaining hosts take its share. Do not
start or advance a step until it clears; legacy is the rollback target and must have capacity.

### tg-modern-unhealthy-hosts

SEV2. A modern pod has been unhealthy for 5 minutes. Readiness gates keep new pods out of the target
group, so look at the latest deploy and `/readyz`. If modern has no healthy target at all, the
weights send users to errors: roll back.

### alb-elb-5xx

SEV1. The load balancer itself returned more than 10 5xx responses in a minute: errors that did not
come from a target, such as no healthy targets in the group a rule sends to. Check both target
groups' unhealthy-host alarms, then the last weight change. If it began at a weight step, roll back.

### rds-cpu

SEV2. Database CPU above 80% for 15 minutes. Both stacks use the one instance. If it follows a
weight step, the new stack is heavier than expected: hold the step or roll back.

### rds-free-storage

SEV2. Free database storage below 10 GiB. Not caused by routing, but a cutover with a full disk
fails writes on both stacks. Stop any step until it is resolved.

### rds-connections

SEV2. Connections above 80% of `max_connections` for 5 minutes. Modern's pool is sized by a budget
(modern ADR-0002) and legacy's by its workers; during a cutover both are connected. Do not advance
a step while this fires.

### rds-freeable-memory

SEV2. Freeable database memory below 256 MiB for 10 minutes. Treat like `rds-cpu`.

## Go and no-go record

Copy into `docs/migration/wave-N/` in `shiptrack-modern` for each step, scrubbed of addresses.

```markdown
## Wave N, step X: <weights>

- Decision: go | hold | roll back
- Approved by: <person>
- Pull request: <link>
- Evidence window: <start> to <end>, with the request count of each target group
- Load during the window: k6-baseline, target none, run <link>
- Gates (cutover-gates run <link>): G2 <result>, G3 <result>, G4 <result>, G5 <result or n/a>
- G1 (validation.yml run <link>) and G6: <result>
- Alarms fired during the window: <none | names>
- Notes: <anything a later reader needs>
```
