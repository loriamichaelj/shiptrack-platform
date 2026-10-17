# Architecture

The detailed diagrams of the three repositories. The three main diagrams (the three repositories together, how the ALB routes a request, and the network and data) are in the [README](../README.md). All diagrams use placeholders, never account IDs, addresses, or secret values.

## shiptrack-platform

### Shared services

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

### Bootstrap and pipeline roles

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

## shiptrack-legacy

The anti-patterns are requirements, tagged in code as `LEGACY AP-xx`. Each one is fixed by the
matching `REM-xx` in `shiptrack-modern`.

### One host

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

### Infrastructure around the hosts

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

### Deploying a release

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

## shiptrack-modern

### In the cluster

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

### The UI in the browser

The UI is a single-page app that the `api` pods serve under `/ui/`. It calls only the public API, and
one runtime above the router is shared by every page. Legacy's UI is a separate, minimal tracking page
served by nginx and is not changed.

```mermaid
flowchart TB
    browser(["Browser at /ui/"])

    subgraph served["Served by the api pods, strict CSP, no inline script or style"]
        shell["index.html, no-cache<br/>hashed assets, immutable"]
    end

    subgraph app["React app"]
        chrome["Header: navigation, LIVE pill, API activity<br/>Footer: stack badge"]
        pages["Pages: Live, Track, Browse,<br/>New shipment, Shipment, System"]
        subgraph runtime["One runtime above the router"]
            engine["TrafficEngine<br/>1 to 20 per second, 8 in flight,<br/>stops after an hour or 1,000 created"]
            store["ShipmentStore<br/>one copy of the shipments,<br/>a status never moves backwards"]
            sync["Server sync<br/>every page of the list,<br/>15 s on Browse, 30 s on Track"]
        end
        log["API call log<br/>latest 200 calls, totals counted apart"]
    end

    api["Public API, unchanged<br/>shipments, events, track,<br/>proof of delivery, healthz, readyz"]

    browser --> shell --> app
    engine --> store
    sync --> store
    store --> pages
    engine -- "create, event, read" --> api
    sync -- "GET shipments, cursor pages" --> api
    pages -- "forms, track, proof of delivery" --> api
    api -. "every call is recorded" .-> log
    log -.-> chrome
```

### Event ingestion in the source and target stacks

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

### Observability

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

### Delivery

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
