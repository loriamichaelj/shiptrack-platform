# shiptrack-platform

The shared, long-lived infrastructure of the ShipTrack EC2-to-EKS migration, and the control point
for the cutover: the ALB weights that move traffic between `shiptrack-legacy` and
`shiptrack-modern`. It also holds the validation tooling that defines "correct" for both stacks.

- Design: [`docs/DESIGN.md`](docs/DESIGN.md)
- Decisions: [`docs/ADR.md`](docs/ADR.md)
- First-time setup, including the manual OIDC provider and seed role: [`bootstrap/README.md`](bootstrap/README.md)
- Database bootstrap: [`db/RUNBOOK-db-bootstrap.md`](db/RUNBOOK-db-bootstrap.md)
- Findings register: [`docs/security/findings-register.md`](docs/security/findings-register.md)

**Terms.** A *proof of delivery* is the document a carrier produces when a shipment is delivered. A *pod* is only ever a Kubernetes pod. Names that stored data and the contract depend on, such as `pod_bucket_name` and the `/pod` API paths, keep the old abbreviation (ADR-0036).

Nothing is applied from a workstation. Every AWS change is a GitHub Actions workflow that assumes
an OIDC role, with a reviewer approving each apply. This repository is public, so no account ID, ALB
address, host ID, or secret value is committed (design §6.12); `ci-scrub.yml` fails a pull request that
adds one.

## The other repositories

| Repository | Role |
|---|---|
| [`shiptrack-legacy`](https://github.com/loriamichaelj/shiptrack-legacy) | The "before" stack: a FastAPI app on EC2 behind this ALB, with deliberate anti-patterns |
| [`shiptrack-modern`](https://github.com/loriamichaelj/shiptrack-modern) | The "after" stack: the same API on EKS, fixing each anti-pattern |

Both read what this repository publishes through the SSM contract under `/shiptrack/platform/`
(`terraform/modules/contract`). They never read this repository's Terraform state.

## Architecture

The diagrams below cover all three repositories and are the same in each README. They use
placeholders, never account IDs, addresses, or secret values.

### The three repositories together

One ALB and one database serve both stacks. `shiptrack-platform` owns everything shared and the
cutover weights, `shiptrack-legacy` and `shiptrack-modern` each read the platform's published values
through SSM and never its Terraform state, and every AWS change comes from a GitHub Actions workflow.

```mermaid
flowchart TB
    users(["Users, carrier simulator,<br/>k6, contract suite"])

    subgraph gha["GitHub Actions: OIDC roles, environment approval on every apply"]
        direction LR
        wfp["platform workflows"]
        wfl["legacy workflows"]
        wfm["modern workflows"]
    end

    subgraph platform["shiptrack-platform: shared, long-lived"]
        alb["ALB shiptrack-alb<br/>cutover weights, header rules,<br/>preview :8080, Grafana :3000"]
        tgl["tg-legacy<br/>instance, :80"]
        tgm["tg-modern<br/>ip, :8000"]
        rds[("RDS PostgreSQL 17<br/>private-data subnets")]
        proofs[("S3 proof-of-delivery<br/>bucket, SSE-KMS")]
        contract[/"SSM contract<br/>/shiptrack/platform/*"/]
        obs["Alarms, SNS sev1 and sev2,<br/>cutover dashboard"]
    end

    subgraph legacy["shiptrack-legacy: the before stack"]
        asg["ASG: 2 EC2 hosts<br/>nginx, gunicorn, FastAPI"]
    end

    subgraph modern["shiptrack-modern: the after stack"]
        eks["EKS pods: api, worker-events,<br/>worker-notify, sla-scan"]
        msg["SQS queues and<br/>EventBridge bus"]
    end

    users --> alb
    alb --> tgl --> asg
    alb --> tgm --> eks
    asg --> rds
    eks --> rds
    asg -. "proof-of-delivery files,<br/>v1.1.0" .-> proofs
    eks --> proofs
    eks --> msg
    asg -. "reads" .-> contract
    eks -. "reads" .-> contract
    asg -. "alarms" .-> obs
    eks -. "alarms" .-> obs
    wfp -. "applies" .-> platform
    wfl -. "applies and deploys" .-> legacy
    wfm -. "applies and deploys" .-> modern
```

### How the ALB routes a request

Changing `var.cutover` in `shiptrack-platform` is the cutover. Rules are evaluated lowest priority
number first. Both stacks answer with `X-ShipTrack-Stack`, so a test that landed on the wrong stack
fails instead of passing quietly.

```mermaid
flowchart TB
    req(["Request to the ALB"]) --> port{"Listener port"}
    port -- "80, or 443 with a domain" --> main["Main listener:<br/>rules, lowest priority first"]
    port -- "8080, allow-listed CIDRs only" --> prev["Preview listener:<br/>forwards everything to preview_stack"]
    port -- "3000, same CIDRs" --> graf["Grafana listener:<br/>forwards everything to tg-grafana"]

    main --> r10{"Priority 10:<br/>X-ShipTrack-Target legacy<br/>and a valid test token?"}
    r10 -- yes --> l100["tg-legacy, 100%"]
    r10 -- no --> r20{"Priority 20:<br/>X-ShipTrack-Target modern<br/>and a valid test token?"}
    r20 -- yes --> m100["tg-modern, 100%"]
    r20 -- no --> r90{"Priority 90:<br/>GET /ui or /ui/*?"}
    r90 -- yes --> w1["Weighted forward by cutover.track<br/>stickiness on, so page and assets<br/>come from one stack"]
    r90 -- no --> r100{"Priority 100:<br/>GET /api/v1/track/*?"}
    r100 -- yes --> w2["Weighted forward by cutover.track"]
    r100 -- no --> w3["Default: weighted forward<br/>by cutover.default"]

    prev --> pv["tg-modern while legacy takes the traffic,<br/>tg-legacy after the cutover"]
    graf --> gt["tg-grafana, filled by modern's<br/>TargetGroupBinding"]
```

### shiptrack-platform

#### Network and data

The private-app subnets are /20 because the VPC CNI gives every pod a VPC address. The database
accepts connections only from the `shiptrack-db-client` security group, which both stacks attach.

```mermaid
flowchart TB
    inet(["Internet"])

    subgraph vpc["VPC, three AZs, DNS support on, default security group emptied"]
        subgraph pub["public subnets, /24 each"]
            alb["ALB shiptrack-alb<br/>security group shiptrack-alb"]
            nat["NAT gateway<br/>single by default, per AZ optional"]
        end
        subgraph appnets["private-app subnets, /20 each"]
            lhosts["Legacy ASG hosts<br/>shiptrack-legacy-app and db-client"]
            nodes["EKS nodes and pods<br/>db-client"]
        end
        subgraph datanets["private-data subnets, /24 each"]
            rds[("RDS PostgreSQL 17, encrypted<br/>sg shiptrack-db: 5432 from db-client only<br/>force_ssl, 7-day backups, deletion protection")]
        end
        s3gw["S3 gateway endpoint"]
        flow["VPC flow logs<br/>CloudWatch, 14 days"]
    end

    inet --> alb
    alb -- "80 / 8000" --> lhosts
    alb --> nodes
    lhosts -- "5432" --> rds
    nodes -- "5432" --> rds
    lhosts -- "egress" --> nat
    nodes -- "egress" --> nat
    nat --> inet
    lhosts --> s3gw
    nodes --> s3gw
```

#### Shared services

```mermaid
flowchart LR
    subgraph keys["KMS, rotation on"]
        kdata["alias shiptrack-data"]
        ksec["alias shiptrack-secrets"]
        klog["alias shiptrack-logs"]
    end

    subgraph store["Storage"]
        proofs[("Proof-of-delivery bucket<br/>versioned, bucket keys,<br/>lifecycle to Glacier IR")]
        albl[("ALB access logs<br/>SSE-S3, 90 days")]
        ct[("CloudTrail bucket")]
    end

    subgraph secrets["Secrets Manager"]
        sapp["db/app<br/>shiptrack_app, DML only"]
        smig["db/migrator<br/>shiptrack_migrator, DDL"]
        stok["test-routing token"]
        smaster["RDS master secret"]
    end

    subgraph sec["Security services"]
        trail["CloudTrail"]
        gd["GuardDuty"]
        cfg["AWS Config"]
        shub["Security Hub CSPM"]
        insp["Inspector"]
        aa["IAM Access Analyzer"]
    end

    subgraph obs["Shared observability"]
        sev1["SNS sev1"]
        sev2["SNS sev2"]
        dash["Dashboard shiptrack-cutover"]
        alarms["Target group, ALB, and RDS alarms"]
    end

    ssm[/"SSM contract<br/>/shiptrack/platform/*<br/>ARNs and IDs, never secret values"/]

    kdata --> proofs
    kdata --> rds[("RDS")]
    ksec --> sapp
    ksec --> smig
    ksec --> smaster
    ksec --> stok
    klog --> ct
    klog --> sev1
    klog --> sev2
    trail --> ct
    cfg --> ct
    shub -- "CRITICAL and HIGH" --> sev2
    gd --> shub
    insp --> shub
    alarms --> sev1
    alarms --> sev2
    store --> ssm
    secrets --> ssm
    keys --> ssm
    obs --> ssm
```

#### Bootstrap and pipeline roles

Nothing is applied from a workstation. The OIDC provider, the seed role, and the GitHub
environments are made by hand once. `apply-bootstrap` then creates the state bucket, the permission
boundary, and the nine roles that every other workflow assumes.

```mermaid
flowchart LR
    subgraph hand["By hand, once"]
        oidc["GitHub OIDC provider"]
        seed["Seed role<br/>owner-bootstrap-project-seed"]
        envs["GitHub environments<br/>bootstrap and dev"]
    end

    ab["apply-bootstrap<br/>bootstrap environment, approved"]

    subgraph made["Created by bootstrap"]
        state[("Terraform state bucket<br/>and KMS key")]
        bound["PREFIX-workload-boundary<br/>on every legacy and modern role"]
        roles["Nine pipeline roles"]
    end

    subgraph roleset["Roles by purpose"]
        plan["platform-plan, legacy-plan, modern-plan<br/>pull requests and the dev branch"]
        apply["platform-apply, legacy-apply, modern-apply<br/>dev environment, approved"]
        dep["legacy-deploy, modern-deploy<br/>dev environment, approved"]
        rel["modern-release<br/>dev branch, builds and pushes the image"]
    end

    wci["ci-terraform and check-*<br/>workflows"]
    wap["apply-* workflows and<br/>platform ops-* workflows"]
    wdp["deploy-app, legacy ops-*,<br/>and check-evidence"]
    wrl["release-image"]

    oidc --> ab
    seed --> ab
    envs --> ab
    ab --> state
    ab --> bound
    ab --> roles
    roles --> roleset
    wci --> plan
    wap --> apply
    wdp --> dep
    wrl --> rel
```

### shiptrack-legacy

The anti-patterns are requirements, tagged in code as `LEGACY AP-xx`. Each one is fixed by the
matching `REM-xx` in `shiptrack-modern`.

#### One host

```mermaid
flowchart TB
    alb["ALB tg-legacy<br/>health check GET / (AP-07)<br/>lb_cookie stickiness (AP-05)"]

    subgraph host["EC2 host, one of two: m5.xlarge (AP-10), 100 GiB gp2 (AP-11), AMI pinned (AP-14), IMDSv1 allowed (AP-04)"]
        nginx["nginx :80<br/>serves /ui/ from web/dist<br/>adds X-ShipTrack-Stack legacy<br/>no security headers (AP-16)"]
        sock(["unix socket<br/>/run/shiptrack/gunicorn.sock"])
        gun["gunicorn, 4 uvicorn workers<br/>systemd shiptrack.service"]
        app["FastAPI application<br/>connects as schema owner<br/>shiptrack_migrator (AP-02)"]
        q["queue.Queue and a daemon thread<br/>per worker: 202 before persistence,<br/>lost on restart (AP-06)"]
        disk[("/var/lib/shiptrack/pod<br/>local-disk proof of delivery (AP-05)")]
        ini[/"/etc/shiptrack/app.ini<br/>plaintext credentials, mode 0644 (AP-01)"/]
        cron["cron: SLA scan every 5 minutes<br/>on every host, no locking (AP-09)"]
        logs["/var/log/shiptrack/*.log<br/>plain text, no request IDs (AP-08)"]
        cwa["CloudWatch agent"]
    end

    rds[("RDS PostgreSQL")]
    s3[("S3 proof-of-delivery bucket<br/>v1.1.0 read path and sync")]
    cwl["CloudWatch Logs<br/>/shiptrack/legacy/*"]

    alb --> nginx --> sock --> gun --> app
    app --> q
    q --> rds
    app --> rds
    app --> disk
    ini -. "read at start" .-> app
    cron --> rds
    app --> logs
    logs --> cwa --> cwl
    disk -. "ops-pod-sync, v1.1.0" .-> s3
```

#### Infrastructure around the hosts

```mermaid
flowchart LR
    subgraph tf["terraform/modules/app_host and envs/dev"]
        lt["Launch template<br/>no key pair, no public IP"]
        asg["ASG shiptrack-legacy<br/>min = max = desired = 2<br/>EC2 health checks (AP-15)"]
        role["IAM role PREFIX-legacy-instance<br/>over-privileged (AP-03), boundary applied"]
        sg["sg shiptrack-legacy-app<br/>80 from the ALB only"]
        art[("Artifact bucket<br/>releases/*, SSE-S3")]
        cur[/"SSM /shiptrack/legacy/current_release"/]
        docs["SSM documents: Migrate, Deploy, Rollback,<br/>Evidence, proof-of-delivery sync, LegacyCron"]
        alm["Host alarms: CPU, status check, memory"]
    end

    plat[/"Platform SSM contract<br/>subnets, tg_legacy_arn, sg ids,<br/>secret ARNs, KMS keys"/]
    tg["tg-legacy"]
    sev2["SNS sev2"]

    plat --> tf
    asg --> tg
    lt --> asg
    role --> asg
    sg --> asg
    art -. "release tarballs" .-> asg
    cur -. "new hosts self-deploy" .-> asg
    docs -. "Run Command" .-> asg
    alm --> sev2
```

#### Deploying a release

`deploy-app` never runs Terraform and Terraform never writes `current_release`. A deploy
restarts each host in place without leaving the target group (AP-12), and the database is not
rolled back.

```mermaid
sequenceDiagram
    autonumber
    participant GH as deploy-app
    participant S3 as Artifact bucket
    participant SSM as SSM Run Command
    participant H1 as Host 1
    participant H2 as Host 2
    participant ALB as ALB

    GH->>GH: build the UI, then the tarball in amazonlinux:2023
    GH->>S3: upload tarball and sha256
    GH->>SSM: ShipTrack-Migrate to one host
    SSM->>H1: extract release, alembic upgrade head
    GH->>SSM: ShipTrack-Deploy, max concurrency 1
    SSM->>H1: verify sha, swap current symlink, restart service
    SSM->>H2: same, after host 1 finishes
    GH->>SSM: put current_release
    GH->>ALB: route check, then contract smoke with TARGET legacy
```

### shiptrack-modern

#### In the cluster

One image runs five roles through `python -m shiptrack <role>`. Each service account has its own
Pod Identity role, named `PREFIX-modern-*` and carrying the platform boundary.

```mermaid
flowchart TB
    tgm["tg-modern, ip :8000<br/>health check /readyz"]

    subgraph eks["EKS cluster shiptrack, managed node group of arm64 nodes, 2 to 3"]
        subgraph ns["namespace shiptrack: Pod Security restricted, default-deny NetworkPolicy"]
            tgb["TargetGroupBinding<br/>readiness gate per pod"]
            api["api Deployment<br/>HPA 2 to 10, :8000 and :9090"]
            we["worker-events<br/>KEDA 1 to 10 on queue depth"]
            wn["worker-notify<br/>KEDA 0 to 3"]
            sla["sla-scan CronJob<br/>every 5 minutes, one statement"]
            mig["migrate Job<br/>Helm pre-upgrade hook"]
        end

        subgraph sys["Add-ons"]
            eksa["EKS add-ons: VPC CNI, CoreDNS, kube-proxy,<br/>Pod Identity agent, metrics-server,<br/>CloudWatch Observability"]
            helm["Helm: AWS Load Balancer Controller,<br/>KEDA, Grafana"]
        end
    end

    subgraph aws["AWS services"]
        evq["SQS shiptrack-carrier-events<br/>and its DLQ"]
        bus["EventBridge bus shiptrack<br/>rule shiptrack-notify, 7-day archive"]
        nq["SQS shiptrack-notifications<br/>and its DLQ"]
        sm["Secrets Manager<br/>app and migrator secrets"]
        s3[("S3 proof-of-delivery bucket<br/>presigned redirect")]
        rds[("RDS PostgreSQL")]
        ecr["ECR shiptrack/app<br/>image by digest"]
    end

    tgm --> tgb --> api
    api -- "SendMessage, then 202" --> evq
    evq --> we
    we -- "apply event" --> rds
    we -- "PutEvents" --> bus --> nq --> wn
    api --> rds
    api --> s3
    api -. "GetSecretValue" .-> sm
    sla --> rds
    mig --> rds
    ecr -. "image pull" .-> ns
    helm -. "scales and routes" .-> ns
```

#### Event ingestion, before and after

Legacy answers `202` before the event is stored, so a restart loses what is in the queue (AP-06).
Modern answers `202` once SQS holds the event, and a worker applies it later (REM-06).

```mermaid
sequenceDiagram
    autonumber
    participant C as Carrier
    participant L as Legacy host
    participant D as Database
    C->>L: POST events
    L->>L: put on the in-process queue
    L-->>C: 202 Accepted
    L->>D: daemon thread writes the event
    Note over L,D: A restart before this write loses the event (AP-06)
```

```mermaid
sequenceDiagram
    autonumber
    participant C as Carrier
    participant A as api
    participant Q as SQS events
    participant W as worker-events
    participant D as Database
    participant B as EventBridge
    participant N as worker-notify
    C->>A: POST events
    A->>Q: SendMessage
    A-->>C: 202 Accepted
    Q->>W: receive
    W->>D: apply the event
    W->>B: PutEvents
    B->>N: through the notifications queue
    Note over Q,W: Failures retry, then go to the DLQ
```

#### Observability

```mermaid
flowchart LR
    pods["Pods<br/>/metrics on :9090 only"]
    scr["AMP managed scraper<br/>every 30 s"]
    amp[("AMP workspace")]
    graf["Grafana, monitoring namespace<br/>read-only viewers, SigV4 to AMP<br/>five provisioned boards"]
    tgg["tg-grafana"]
    alb["ALB :3000<br/>allow-listed CIDRs"]
    ci["CloudWatch Observability add-on<br/>Container Insights and Fluent Bit"]
    cwl["CloudWatch Logs"]
    alm["Alarms: queue age, DLQs, pod restarts,<br/>SLA scan heartbeat, availability burn rate"]
    sns["SNS sev1 and sev2"]

    pods --> scr --> amp
    amp --> graf
    graf --> tgg --> alb
    pods --> ci --> cwl
    cwl --> alm
    amp --> alm
    alm --> sns
```

#### Delivery

`release-image` hands the digest to `deploy-app`, which renders Helm values from SSM, upgrades with
`--atomic`, smoke-tests through the ALB with the platform's contract suite, and rolls back if the
smoke fails. Terraform runs as two roots, `cluster` then `addons`, after one approval.

```mermaid
flowchart LR
    pr["Pull request"] --> ci["ci-checks: test, web, secrets,<br/>image, iac, helm"]
    pr --> cit["ci-terraform<br/>plan comment, addresses only"]
    ci --> merge["Squash merge to dev"]
    merge --> rel["release-image<br/>native amd64 and arm64 builds,<br/>Trivy scan, SBOM"]
    rel --> ecr[("ECR<br/>digest")]
    ecr --> dep["deploy-app<br/>dev environment, approved"]
    dep --> rv["render-values.sh<br/>SSM to Helm values"]
    rv --> up["helm upgrade --atomic<br/>with rollout sampler"]
    up --> smoke["Smoke through the ALB<br/>platform contract suite, TARGET modern"]
    smoke -- "fails" --> rb["Roll back"]
    merge --> ap["apply-terraform<br/>cluster root, then addons root"]
```

## Layout

| Path | What it holds |
|---|---|
| `bootstrap/` | State bucket, state key, the workload permission boundary, and the nine pipeline roles. Applied only by `apply-bootstrap.yml` |
| `terraform/modules/` | `network`, `kms`, `database`, `storage`, `ingress`, `observability`, `contract`, `security-services` |
| `terraform/envs/dev/` | The environment that wires the modules together |
| `db/` | `bootstrap.sql` (database, roles, schema) and its runbook, and `reset-data.sql` (the data reset, ADR-0034) |
| `validation/contract/` | The API contract suite (pytest and httpx): the executable form of legacy design §3, run against either stack through the ALB |
| `validation/simulator/` | The carrier event simulator: creates shipments, sends lifecycles with duplicates and out-of-order events, and records a ledger |
| `validation/loadtest/` | The k6 scenarios: `baseline`, `stress`, and `soak` |
| `scripts/` | `terraform-ci.sh`, the plan, apply, and drift wrapper that masks identifiers in logs; `force-unlock.sh`; `ssm-run.sh` and `reset-data.sh` for the data reset; and their shell tests |

## Workflows

| Workflow | Runs | Does |
|---|---|---|
| `apply-bootstrap.yml` | by hand, `bootstrap` environment | Creates the state bucket on the first run, then the boundary and roles |
| `ci-terraform.yml` | pull requests | Format, validate, tflint, Checkov, Trivy, and a plan comment with addresses and actions only |
| `apply-terraform.yml` | push to `dev` (including a change to `scripts/reset-data.sh` or `db/reset-data.sql`, which the reset document embeds), or by hand, `dev` environment | Plans and applies `terraform/envs/dev`; a reviewer approves each run |
| `ci-scrub.yml` | pull requests | gitleaks plus rules for account IDs and ALB DNS names |
| `ci-simulator.yml` | pull requests touching the simulator | Lint and tests |
| `ops-unlock-state.yml` | by hand, `dev` environment | Removes a stale state lock, given its ID. Refuses a lock with another ID or one younger than 30 minutes (ADR-0025) |
| `ops-reset-data.yml` | by hand, `dev` environment | Deletes every shipment, its events, documents, and alerts, and the document files in S3 and on each legacy host, then seeds five demo shipments (`MF0000000001` to `MF0000000005`). Needs the typed confirmation `delete-all-shipments`; cannot be undone (ADR-0034) |
| `check-drift.yml` | nightly, and by hand | Plans `terraform/envs/dev` with the plan role. Changes open or update one issue, "Drift detected: platform/dev", with addresses and actions only; a clean plan closes it (ADR-0027) |
| `check-live-stack.yml` | by hand | Runs the contract suite (`smoke`, `full`, or `sla`) or a k6 baseline against one stack through the ALB. Uploads nothing |
| `ci-validation.yml` | pull requests touching `validation/` or `scripts/` | Lint and tests for the contract suite and the simulator, `k6 inspect` for each scenario, and the shell tests |
| `check-cutover-gates.yml` | by hand | Judges gates G2 to G5 over a soak window from CloudWatch with the plan role and prints a table of numbers (ADR-0028) |
| `check-security-findings.yml` | by hand | Inspector findings by severity and fix availability, and Security Hub CRITICAL and HIGH; fails on a fixable CRITICAL or HIGH in modern's resources (ADR-0029). The wave 0 exit criterion |
| `ops-rollback-cutover.yml` | by hand, `dev` environment | Break-glass: all weighted routing back to legacy 100, modern 0, without a pull request. See `docs/runbooks/break-glass-rollback.md` |

### Workflow names

A workflow file is `<category>-<what>.yml`, and its `name:` is the file name without `.yml`, so the
Actions list sorts by what a workflow does.

| Prefix | Does | Runs on | Needs approval |
|---|---|---|---|
| `ci-` | Checks a pull request. Changes nothing in AWS | pull request | No |
| `apply-` | Applies Terraform | push to `dev`, or by hand | `dev` environment (`bootstrap` for `apply-bootstrap`) |
| `release-` | Builds an artifact and pushes it | push to `dev`, or by hand | No |
| `deploy-` | Puts a release on the running stack | after a release, or by hand | `dev` environment |
| `ops-` | One operation on a running system: rollback, unlock, cron, database | by hand | `dev` environment |
| `check-` | Reads state or judges evidence. Changes nothing | by hand, or a schedule | No |

## Opening both UIs side by side

The ALB's address serves legacy: the weighted rules send all traffic to it until the cutover moves
weights. To open the modern UI beside it without the test-routing headers, set the `PREVIEW_CIDRS`
repository **secret** to a JSON list of the addresses that may reach it, for example
`["203.0.113.7/32"]`, and run `apply-terraform`. That adds a listener on port 8080 that forwards
everything to one stack: modern while legacy takes the traffic, and legacy after the cutover
(`preview_stack`, ADR-0032), so legacy's UI stays reachable beside modern's. Then:

- legacy: `http://<ALB address>/ui/`
- modern: `http://<ALB address>:8080/ui/`
- Grafana, on modern's metrics: `http://<ALB address>:3000/` (ADR-0035)

It is a secret, not a variable, because it names a person's address and the logs and pull request
comments of this repository are public: a secret is masked in logs, and the plan prints the rules
by position, not by address. Left unset, nothing is created, and `0.0.0.0/0` is refused. The
listeners are outside the cutover weights (ADR-0026, ADR-0035). The Grafana port opens to the same
addresses and no others. Delete the secret and apply to remove both.

## Status

| Phase | State |
|---|---|
| P0 Bootstrap | Done and applied |
| P6a Terraform workflows | Done and in use |
| P6 scrub and local checks | Done: `ci-scrub.yml`, `.gitleaks.toml`, `.pre-commit-config.yaml`, `.tflint.hcl`, `.checkov.yaml` |
| P1 Network and KMS | Done and applied |
| P2 Database | Done and applied; the database is bootstrapped (see the runbook) |
| P3 Storage and ingress | Done and applied; `track` and `default` are both at modern 100, the preview port shows legacy (ADR-0032), and the Grafana port (3000) opens to the same addresses (ADR-0035) |
| P5 Observability and contract | Done and applied |
| P4 Security services | Done and applied. Config is adopted and recording, and the Inspector enabler and ECR scanning configuration are created (ADR-0022) |
| P6b Drift and validation workflows | Done and in use: `check-drift.yml`, `check-live-stack.yml`, `ci-validation.yml` (ADR-0027) |
| P7 Validation tooling | On `dev`: the simulator, which has seeded the legacy stack, the contract suite, and the k6 scenarios. The contract suite is what modern's `deploy-app.yml` runs as its smoke test |
| P8 Runbooks | `docs/runbooks/cutover.md` and `docs/runbooks/break-glass-rollback.md` are written and were used for the cutover, which is complete. The runbooks are still to be iterated |

## Local checks

These need no AWS credentials.

```sh
terraform fmt -check -recursive
terraform -chdir=terraform/envs/dev init -backend=false && terraform -chdir=terraform/envs/dev validate
for m in terraform/modules/*/; do terraform -chdir="$m" init -backend=false && terraform -chdir="$m" test; done   # offline plan tests
tflint --recursive
checkov --config-file .checkov.yaml -d terraform   # one -d per run: repeated -d scans only the first
actionlint
```

`bootstrap/tests/moto.sh` runs the real bootstrap script against a moto server. `db/tests/bootstrap.sh`
runs `bootstrap.sql` twice against a throwaway PostgreSQL 17 container (it needs Docker) and checks
that the second run changes nothing; `db/tests/reset-data.sh` runs `reset-data.sql` as the
application role against the same kind of container.

The wrapper scripts and the validation tooling are checked without AWS too:

```sh
scripts/tests/test_terraform_ci.sh && scripts/tests/test_force_unlock.sh   # against fake aws and terraform
shellcheck scripts/*.sh scripts/tests/*.sh
( cd validation/contract && uv sync --frozen && uv run --frozen pytest --collect-only -q \
    && uv run --frozen pytest tests/test_endpoint_coverage.py -q )         # needs no BASE_URL
( cd validation/simulator && uv sync --frozen && uv run --frozen ruff check . && uv run --frozen pytest -q )
```

## Running the validation suites

`check-live-stack.yml` is dispatched by hand, from `dev`, with the plan role. It reads the base URL and the
test-routing token itself and uploads nothing, because a failure message can contain the ALB address.

| Suite | Marker or script | Notes |
|---|---|---|
| `contract-smoke` | `-m smoke` | The 8-test subset that modern's `deploy-app.yml` runs after every deploy |
| `contract-full` | `-m "not sla"` | Everything that needs one stack |
| `k6-baseline` | `loadtest/baseline.js` | 20 rps for 30 minutes against one stack; the summary stays on the runner |

`target` is `legacy`, `modern`, or `none`. The proof-of-delivery tests need a stack pinned with `legacy` or
`modern`, because an upload and its read-back must reach the same stack. The suites change nothing
about routing: they address a stack with the test-routing headers, so the weights can stay as they are.
