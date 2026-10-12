# ShipTrack Platform — Architecture Decision Log

Decisions are recorded here, oldest first. Each entry has a status (Planned, Accepted, Superseded) and, once decided, Context, Decision, and Consequences. Entries marked Planned are decisions the design expects to be made during the build.

| # | Title | Status |
|---|---|---|
| 0001 | `security-hub-cspm-scope` | Planned |
| 0002 | `test-routing-header-token` | Planned |
| 0003 | `plan-role-secret-access` | Planned |
| 0004 | `nat-vs-interface-endpoints` | Planned |
| 0005 | `seed-role-and-bootstrap-workflow` | Accepted; role names superseded by ADR-0011 |
| 0006 | `public-repositories` | Planned |
| 0007 | `dev-branch-and-environment` | Planned |
| 0008 | `branching-and-environment-protection` | Accepted |
| 0009 | `bootstrap-iam-hardening` | Accepted |
| 0010 | `local-verification-with-moto` | Accepted |
| 0011 | `iam-naming-convention` | Accepted |
| 0012 | `immutable-oidc-subjects` | Accepted |
| 0013 | `terraform-workflow-structure` | Accepted |
| 0014 | `p1-network-and-keys` | Accepted |
| 0015 | `p2-database` | Accepted |
| 0016 | `db-instance-class-and-failure-logs` | Accepted |
| 0017 | `p3-storage-and-ingress` | Accepted |
| 0018 | `group-stickiness-on-weighted-forwards` | Accepted |
| 0019 | `parameter-group-apply-method` | Accepted |
| 0020 | `p5-observability-and-contract` | Accepted |
| 0021 | `p4-security-services` | Accepted |
| 0022 | `adopt-the-accounts-existing-security-services` | Accepted |
| 0023 | `carrier-event-simulator` | Accepted |
| 0024 | `composite-alarms-need-an-unscoped-grant` | Accepted |
| 0025 | `state-lock-recovery-workflow` | Accepted |
| 0026 | `modern-preview-listener` | Accepted |
| 0027 | `validation-tooling-and-the-nightly-drift-check` | Accepted |
| 0028 | `cutover-controls-as-workflows` | Accepted |
| 0029 | `findings-gate-covers-modern-only` | Accepted |
| 0030 | `cutover-steps-gated-by-evidence-not-durations` | Accepted |
| 0031 | `g3-per-route-with-an-event-route-allowance` | Accepted |
| 0032 | `legacy-kept-reachable-on-the-preview-port` | Accepted |
| 0033 | `retire-ui-build-parity-gate` | Accepted |

## ADR-0001: security-hub-cspm-scope

**Status:** Planned

**Records:** Security Hub CSPM in scope; the unified Security Hub (GA December 2025) out of scope (design §6.7).

**Context:** _to be written when decided_

**Decision:** _to be written when decided_

**Consequences:** _to be written when decided_

## ADR-0002: test-routing-header-token

**Status:** Planned

**Records:** Header + token routing instead of a source-IP condition (design §6.6, R-04).

**Context:** _to be written when decided_

**Decision:** _to be written when decided_

**Consequences:** _to be written when decided_

## ADR-0003: plan-role-secret-access

**Status:** Planned

**Records:** Plan-role access to the DB secrets, its trust surface, and the outcome of the [VERIFY] (design §6.1, R-09).

**Context:** _to be written when decided_

**Decision:** _to be written when decided_

**Consequences:** _to be written when decided_

## ADR-0004: nat-vs-interface-endpoints

**Status:** Planned

**Records:** O-P1 decision, made from measured data.

**Context:** _to be written when decided_

**Decision:** _to be written when decided_

**Consequences:** _to be written when decided_

## ADR-0005: seed-role-and-bootstrap-workflow

**Status:** Accepted; role names superseded by ADR-0011

**Context:** Every pipeline needs roles and a state bucket before it can run, and all AWS changes must go through GitHub Actions. An account can hold only one OIDC provider per URL.

**Decision:** The OIDC provider and the `shiptrack-bootstrap` seed role (AdministratorAccess, trusted only for the protected `bootstrap` environment of the platform repository) are created by hand. Terraform reads the provider by data source and does not manage the seed role. `apply-bootstrap.yml` creates the state bucket, the permission boundary, and the nine deploy roles. On the first run only the state bucket is created with local state, which is then migrated into the bucket before anything else is applied.

**Consequences:** Pipelines cannot modify their own foundation. The seed role is the most privileged credential in the account and is tracked as risk R-10; narrow or delete it once bootstrap no longer needs to change. A failure while creating the bucket on the first run needs the recovery steps in `bootstrap/README.md`.

## ADR-0006: public-repositories

**Status:** Planned

**Records:** Public repos, the §6.12 rules, and residual exposure (R-11).

**Context:** _to be written when decided_

**Decision:** _to be written when decided_

**Consequences:** _to be written when decided_

## ADR-0007: dev-branch-and-environment

**Status:** Planned

**Records:** Development runs on the `dev` branch and `dev` environment; the design's former `main`/`prod` names were replaced with `dev`.

**Context:** _to be written when decided_

**Decision:** _to be written when decided_

**Consequences:** _to be written when decided_

## ADR-0008: branching-and-environment-protection

**Status:** Accepted

**Context:** The designs gate everything on pull requests (CI, plans) and on the `dev` environment, but the first plan was to commit straight to `dev`. An environment job's OIDC `sub` carries no branch, so approval alone does not stop other branches from requesting apply roles.

**Decision:** Work happens on short-lived branches off `dev` and merges by pull request into the protected `dev` branch. Environments `dev` and `bootstrap` allow deployments from `dev` only. Role ARNs are stored as secrets so GitHub masks them.

**Consequences:** Every change runs CI and a plan before merge. Direct pushes to `dev` are blocked. The one-time setup in each repo is documented in `bootstrap/README.md`.

## ADR-0009: bootstrap-iam-hardening

**Status:** Accepted

**Context:** The platform apply role has PowerUserAccess and could otherwise rewrite the deploy roles, the boundary, or other stacks' state. The legacy and modern apply roles could change the platform's keys.

**Decision:** The platform apply role carries explicit denies on the bootstrap-owned roles, the boundary policy, the state bucket and key, and the other stacks' state prefixes. The legacy and modern apply roles deny key-changing actions on keys with a platform alias. The legacy apply role also denies creating key pairs, matching the no-SSH rule.

**Consequences:** A privilege-escalation path through the platform pipeline is closed. Changes to bootstrap-owned resources always go through apply-bootstrap.yml.


## ADR-0010: local-verification-with-moto

**Status:** Accepted

**Context:** The bootstrap workflow needs a manual approval loop in a real account, so a mistake in a trust policy or in the first-run state migration would be slow to find. LocalStack needs an account token.

**Decision:** `bootstrap/tests/moto.sh` runs the real `ci.sh` against a local moto server: first-run seeding and state migration, a no-op second run, the exact trust-policy `sub` claims, and IAM policy size limits. The bucket's TLS-only policy is left out of the copy that runs against moto, because moto serves plain HTTP and enforces the policy; its content is checked from a plan of the unmodified configuration.

**Consequences:** Most bootstrap defects are found before the first real run. IAM actions and condition keys are not validated against AWS, so permission gaps still surface as AccessDenied in the pipelines that need them.

## ADR-0011: iam-naming-convention

**Status:** Accepted

**Context:** Roles in the AWS account must be named `<owner>-<environment>-<project>-...`. Role names were `shiptrack-*`, hardcoded in the bootstrap policies, so a change of convention would touch every IAM statement.

**Decision:** Every IAM role, instance profile, and customer managed policy is named under a role prefix, `<owner>-<environment>-<project>`, supplied as the `role_prefix` Terraform variable and the `ROLE_PREFIX` repository variable; nothing hardcodes it. The nine deploy roles and the permission boundary are `<PREFIX>-<stack>-<purpose>` and `<PREFIX>-workload-boundary` for the `dev` environment. The hand-made seed role is `<owner>-bootstrap-<project>-seed`, supplied as `seed_role_name` and `SEED_ROLE_NAME`. The IAM scopes of the pipeline roles follow the prefix: platform `<PREFIX>-*`, legacy `<PREFIX>-legacy-*`, modern `<PREFIX>-modern-*`. Non-IAM resources (state bucket, key aliases, log groups, alarms, S3 buckets) keep their `shiptrack-` names. This replaces the `shiptrack-*` role and seed role names in ADR-0005.

**Consequences:** The convention is changed in one variable. The prefix must be 2 to 40 characters so role names stay within the 64-character IAM limit. `ROLE_PREFIX` must be consistent with the `Environment` the roles trust, because the deploy roles' trust and the prefix are set independently. The legacy and modern Terraform must name their roles under the prefix or the apply roles are denied.

## ADR-0012: immutable-oidc-subjects

**Status:** Accepted

**Context:** The three repositories issue OIDC tokens with an immutable subject: `repo:<owner>@<owner-id>/<repo>@<repo-id>:<suffix>`. The trust policies were written for the name-only subject and would never match.

**Decision:** The deploy roles and the seed role trust the immutable subject. Bootstrap takes the owner ID from the workflow context (`github.repository_owner_id`) and the repository IDs from the `REPO_IDS` repository variable on the platform repository. The IDs are public and carry no account information.

**Consequences:** A renamed or transferred repository keeps its trust only if its IDs are unchanged, and a deleted and recreated repository does not inherit it. The documented subject forms cover branch refs; the `environment` and `pull_request` suffixes follow the same pattern but are not shown in GitHub's documentation. The `:environment:bootstrap` suffix is confirmed: the seed role was assumed by the first `apply-bootstrap` run. The `pull_request` and `ref:refs/heads/dev` suffixes are confirmed by the first plan-role run **[VERIFY]**.

## ADR-0013: terraform-workflow-structure

**Status:** Accepted

**Context:** §6.11 lists the pull-request checks in one sequence that starts with `init` under the plan role. The state bucket name contains the account ID, so the backend cannot be committed, and fork pull requests receive no OIDC token.

**Decision:** `ci-terraform.yml` has two jobs. `lint` (format, `validate` with `init -backend=false`, TFLint, Checkov, Trivy) needs no AWS access and runs for forks. `plan` runs only for same-repository pull requests, after `lint`, under the plan role. Both `plan` and `apply-terraform.yml` run `scripts/terraform-ci.sh`, which looks up the account, derives the bucket name `shiptrack-tfstate-<account>-<region>` as bootstrap does, and passes the backend settings to `init`, so `terraform/envs/dev/backend.tf` holds only an empty `backend "s3" {}` block. Trivy runs twice over the repository: once for the SARIF report sent to code scanning, once as the gate. Checkov is installed with `pipx` at a pinned version because it has no action to pin to a SHA.

**Consequences:** Lint runs on every Terraform pull request without credentials. The apply workflow's path filter is `terraform/**` only, so edits to the workflow or the script are exercised by the plan job on the pull request rather than by an approval-gated apply. `apply-terraform.yml` fails if `terraform/envs/dev` does not exist when `terraform/**` changes, which P1 prevents by adding both together.

## ADR-0014: p1-network-and-keys

**Status:** Accepted

**Context:** P1 creates the first resources the platform pipeline applies. Several values the design leaves open had to be chosen.

**Decision:**
- The `Owner` tag is the GitHub repository owner, passed by the workflows as `TF_VAR_owner`. `CostCenter` is `shiptrack-migration` in `terraform.tfvars`. Neither is an identifier that needs hiding.
- The VPC flow-log role is `<PREFIX>-platform-flow-logs`, so the platform apply role's IAM scope (`<PREFIX>-*`) covers it. It does not carry the workload boundary, which applies to roles created by the legacy and modern pipelines.
- The private-data subnets have their own route table with no default route: the database needs no internet path. They share the S3 gateway endpoint with the private-app tables.
- The first three zones returned by `aws_availability_zones` are used, as the design says. The Checkov check that asks for pinned zone identity (CKV_AWS_394) is skipped inline for that reason.
- Module tests use Terraform's mocked provider (`terraform test`), so the subnet CIDRs and tags, NAT modes, endpoints, and security-group rules are checked without any AWS access.

**Consequences:** If AWS adds a zone that sorts before the current first three, a plan would move subnets; the plan summary shows it before an apply is approved. Tests assert the design's values but cannot show that AWS accepts the configuration; the first `plan` under the plan role does.

## ADR-0015: p2-database

**Status:** Accepted

**Context:** P2 creates the RDS instance and the application credentials. The design leaves the engine minor version to be checked and does not say how the bootstrap script receives passwords or how the database is created.

**Decision:**
- The engine defaults to PostgreSQL 17.10, the newest 17.x minor confirmed in AWS's own announcements **[VERIFY with `aws rds describe-db-engine-versions`]**; the version is a variable.
- The RDS instance creates no database. `db/bootstrap.sql` creates `shiptrack` (through `\gexec`, because `CREATE DATABASE` cannot run in a DO block), the roles, and the schema.
- Passwords reach the script as psql variables and are passed to the server session with `set_config`, because a psql variable is not expanded inside a dollar-quoted DO body. The script resets both role passwords on every run, so a rotated secret reaches the database by running the script again.
- The master user gets the migrator role for the length of the script (`GRANT ... WITH SET TRUE` before anything is created, `REVOKE` at the end) so it can create the database and the schema owned by it. The RDS master is not a superuser, and without the grant first, `CREATE DATABASE ... OWNER shiptrack_migrator` fails with `must be able to SET ROLE`. The first real run found this, because the test had used a superuser; the test now runs the script as a non-superuser master.
- The module tests keep the AWS provider mocked but use the real random provider, because Terraform's provider mocking does not support ephemeral resources. The random provider makes no network calls.
- `db/tests/bootstrap.sh` runs the script three times, as a non-superuser master like RDS's, against a pinned PostgreSQL 17 container and checks the roles, schema, default privileges, and password changes. It is run locally and is not yet part of CI.

**Consequences:** The first real database bootstrap run is also the test of the master-user grant. Passwords never enter Terraform state, but they are visible in the Secrets Manager secrets to roles allowed to read them (the platform plan role can read `shiptrack/dev/db/*`, risk R-09).

## ADR-0016: db-instance-class-and-failure-logs

**Status:** Accepted

**Context:** The first apply created 58 of 61 resources, then `CreateDBInstance` failed twice, minutes apart, with `InsufficientDBInstanceCapacity`: no Availability Zone had capacity for `db.t4g.medium` on gp3 in the VPC. The account has no CLI access from the workstation, so the orderable options could not be listed. The failure also printed Terraform's full output to the log of a public repository, including VPC, subnet, and security group IDs.

**Decision:** The dev environment uses `db.t3.medium`, which has the same 4 GiB of memory and is the next most widely offered burstable class. Storage stays gp3, as designed. The module default is still `db.t4g.medium`. If this fails the same way, the next change is the storage type, and after that a larger class. `scripts/terraform-ci.sh` masks `[id=...]` values and EC2 network resource IDs, along with the account ID, in the output it prints when a step fails.

**Consequences:** `db.t3.medium` is x86 and has lower baseline performance per dollar than the Graviton class; the cost optimization pass (design §10) can revisit the class once capacity is known. The mask hides IDs that would help to debug a failure from the log; the Terraform state and the AWS console still show them.

## ADR-0017: p3-storage-and-ingress

**Status:** Accepted

**Context:** P3 creates the three buckets and the ALB with its cutover rules. The design left two items to verify and did not say how an unset domain reaches Terraform.

**Decision:**
- The ALB access-log bucket grants `s3:PutObject` to the service principal `logdelivery.elasticloadbalancing.amazonaws.com`, limited by `aws:SourceArn` to load balancers in this account and region. AWS recommends it over the per-region ELB account IDs that regions opened before August 2022 needed, and it works in every region. This resolves the **[VERIFY]** in design §6.5.
- The ALB is created only after the log bucket's policy exists: the bucket-name output depends on the policy, because the ALB checks write access when it is created.
- The CloudTrail bucket's policy also lets AWS Config deliver to `AWSLogs/<account>/Config/`, as the logs key policy anticipates (§6.3). The trail itself is created in P4; its name is the `trail_name` variable.
- The workflows pass `TF_VAR_domain_name` and `TF_VAR_hosted_zone_name` from the optional `DOMAIN_NAME` and `HOSTED_ZONE_NAME` repository variables. An unset variable arrives as an empty string, which the ingress module treats as no domain. With a domain the ALB gets an ACM certificate, an HTTPS listener with `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09`, an HTTP redirect, and an alias record. That policy name is taken from AWS's documentation and not exercised until a domain is set **[VERIFY at first use]**.
- The certificate-validation records are keyed by the configured domain name, not by the certificate's apply-time options.
- Checkov and Trivy findings that follow from the design are skipped inline with reasons: the public ALB, HTTP without a domain (risk R-01), HTTP between the ALB and its targets, the optional WAF, and SSE-S3 on the ALB log bucket.
- Module tests cover the rule priorities, the header conditions, UI-only stickiness, and that moving `cutover.track` leaves the default action, the ALB, and the header rules unchanged.

**Consequences:** The ALB is internet-facing over plain HTTP until a domain is set (R-01). Deletion protection is on, so removing the ALB takes two steps. The test-routing token is in state and in the listener rules (R-04).

## ADR-0018: group-stickiness-on-weighted-forwards

**Status:** Accepted

**Context:** Design §6.6 puts group-level stickiness on the UI rule only and leaves it off elsewhere, so a weight change moves traffic at once. The first ingress apply failed at the listener: AWS rejects a forward to several target groups when one of them has target stickiness, unless the forward also has group stickiness. The legacy target group has target stickiness by design (AP-05), so the default action and the API rule (priority 100) both failed that check. The header rules forward to one group and are not affected.

**Decision:** Group stickiness is enabled on the default action and on the track rule for `var.api_stickiness_seconds`, default 1 second, the shortest AWS allows. The UI rule keeps `var.ui_stickiness_seconds` (3600). Dropping the target stickiness on the legacy group was rejected because AP-05 is a requirement. A longer duration was rejected because a weight change would then reach existing clients only as their cookies expire.

**Consequences:** A client is re-rolled between stacks on almost every request, so canary statistics stay per-request and a cutover takes effect at once, as the design intends. The legacy group's own 24-hour cookie still pins a client to one instance within legacy. Because group stickiness is on, a request carries the group-stickiness cookie; a client that ignores cookies is unaffected, since the cookie only prefers a group.

## ADR-0019: parameter-group-apply-method

**Status:** Accepted

**Context:** After the database was applied, every plan still showed an in-place update of the database parameter group. The plan summary named only the address, so the cause was hidden. It now also names the attributes that differ, which showed that only `rds.force_ssl` differed.

**Decision:** `rds.force_ssl` is set with `apply_method = "pending-reboot"`. It is a static parameter, so AWS reports that method on read, and the provider's default of `immediate` never matched. The plan summary keeps the changed-attribute names for updates (values are never printed).

**Consequences:** The plan is clean for the parameter group, so the nightly drift check (P6b) will not report it. The value stays 1, so the running instance is not affected; a future change to the value takes effect at the next reboot.

## ADR-0020: p5-observability-and-contract

**Status:** Accepted

**Context:** P5 creates the alert topics, alarms, dashboard, and the SSM contract the other two repositories read. The design names a runbook URL for every alarm, but the runbooks are written after the builds (P8).

**Decision:**
- Every alarm description is `owner: platform | severity: SEVn | runbook: <URL>#<alarm> | <what it means>`. All URLs point at `docs/runbooks/cutover.md` on `dev` in this repository, with the alarm name as the anchor; P8 writes a section for each anchor. The owner of the repository comes from the `owner` variable, so no organisation name is committed.
- Alert email addresses come from the optional `ALERT_EMAILS` repository variable as one comma-separated string, because an unset variable reaches Terraform as an empty string and would break a list-typed variable. Subscriptions are keyed by position so the plan summary and the PR comment never show an address. Each recipient must still confirm by hand.
- The `contract` module takes one object with an attribute per design §6.9 key, so a missing key is a plan-time error and a partial contract cannot be published. The permission boundary and the state bucket are read by data source because bootstrap owns them. The three subnet lists are `StringList` parameters; nothing is a `SecureString`, because only identifiers and ARNs are published.
- The security-services topics (`sev2` accepting EventBridge) are in place; the rule that sends Security Hub findings to it is part of P4.

**Consequences:** Until P8, the runbook links lead to a page without those sections. The EventBridge statement in the `sev2` topic policy is built from a policy document and is exercised by the first apply, not by the offline tests. The alarms use `notBreaching` for missing data, so a target group with no traffic stays quiet.

## ADR-0021: p4-security-services

**Status:** Accepted

**Context:** P4 turns on the account-level security services. Several details were left open, and some of the provider's resources do not match the design's wording.

**Decision:**
- The CloudTrail trail uses advanced event selectors for management events and, behind `enable_pod_data_events`, for S3 data events limited to objects in the POD bucket. Classic and advanced selectors cannot be mixed.
- GuardDuty Runtime Monitoring is the `RUNTIME_MONITORING` feature with the `EKS_ADDON_MANAGEMENT` additional configuration, which is the automated agent management the design asks for. `EKS_RUNTIME_MONITORING` is the deprecated name **[VERIFY]**.
- AWS Config records daily with continuous overrides for IAM roles, policies, users, groups, and security groups. It uses a role named under the role prefix, not the service-linked role, so the first apply does not depend on whether that service-linked role already exists. The role may write only under `config/AWSLogs/<account>/Config/` in the CloudTrail bucket, and the bucket policy allows that path.
- Security Hub CSPM subscribes only to AWS Foundational Security Best Practices v1.0.0 and CIS AWS Foundations Benchmark v3.0.0. The CIS ARN is built for the configured region **[VERIFY at first apply]**.
- Inspector scans EC2 and ECR. The design asks for the ECR re-scan duration as a variable, but no Terraform resource exposes it, so it is left at the account default and noted here. The registry itself is set to enhanced scanning with continuous re-scan for every repository.
- Findings routing is one EventBridge rule, new CRITICAL and HIGH findings to the SEV2 topic. The topic policy (P5) already lets EventBridge publish.

**Consequences:** An account that already has a GuardDuty detector, a Config recorder, or Security Hub enabled makes the first apply fail on "already exists"; the fix is to import the existing resource, not to disable it. Runtime Monitoring bills per vCPU once the EKS cluster runs. The register template is `docs/security/findings-register.md`.

## ADR-0022: adopt-the-accounts-existing-security-services

**Status:** Accepted

**Context:** The first P4 apply created 11 of 21 resources. It failed on three: the account already has an AWS Config recorder and delivery channel, both named `default` (AWS allows one of each per region), and an account Access Analyzer (one per type per region). The recorder is stopped and not recording all types, so nothing relies on it. The Inspector enabler also timed out while EC2 scanning was still enabling.

**Decision:**
- AWS Config: the existing recorder and delivery channel are adopted with `import` blocks in `terraform/envs/dev` and keep their names, which are now module variables. The module then reconfigures them: this role, all supported resource types recorded daily (IAM and security groups continuously), delivery to the CloudTrail bucket under `config/`, and recording started. The previous delivery bucket stops receiving anything. Security Hub follows because its controls need Config.
- Access Analyzer: a second account analyzer is not created. The account's own satisfies design §6.7. `manage_access_analyzer` is off in `dev`; the module still creates one where the account has none.
- Inspector and Security Hub: the Inspector enabler (create and delete) and each Security Hub standard (create and delete) wait up to 20 minutes (`inspector_timeout`, `security_hub_timeout`). The first adoption apply ran out of the provider's five-minute and three-minute defaults, while Config recording, the Security Hub account, and the CIS subscription had succeeded. A resource that timed out while waiting is tainted in state, so the next plan replaces it, which disables and enables scanning, or removes and re-adds the standard.
- The `import` blocks are removed in a later change, once an apply has imported the two resources.
- A read-only diagnostic workflow listed these services by name and status, without ARNs or account IDs, while they were being adopted; it was removed once they were.

**Consequences:** The Config setup that existed before this project is changed. The old `config-bucket-*` bucket is left as it is. A fresh account without these services needs the defaults (`shiptrack-recorder`, `shiptrack-delivery`, `manage_access_analyzer = true`) and no import blocks.

## ADR-0023: carrier-event-simulator

**Status:** Accepted

**Context:** Legacy and modern need the same realistic traffic to be compared, and AP-06 (events lost when the in-process queue is lost) needs a record of what was accepted.

**Decision:**
- The simulator is a seeded plan generator, an async runner, and a ledger, with the rates in design §6.10: 1% duplicate events, 2% out-of-order events, 1% exception paths, and 5% of shipments created already late. The same seed plans the same run.
- Only events the API answered with 202 are written to the ledger, one line each, as they are accepted and flushed at once, so a crash loses nothing. A repeated key is written once.
- It uploads a proof of delivery on each delivery and never reads one back, because an upload and its read-back must reach one stack and weighted routing could split them.
- `verify` imports only `psycopg` and nothing else, so the wheel is installed on a host with `--no-deps` and uses the release virtualenv's `psycopg`. Running the simulator needs `httpx`; running `verify` does not.
- The simulator is consumed by the other repositories by checking this one out at a pinned commit; the repository is public, so no token is needed.

**Consequences:** A run writes real shipments and events into the target's database, so it is run deliberately. The ledger holds shipment IDs and tracking numbers, so it stays on the runner or in the private artifact bucket and is not committed.

## ADR-0024: composite-alarms-need-an-unscoped-grant

**Status:** Accepted

**Context:** The first modern apply failed creating the two availability burn-rate composite alarms with `AccessDenied`, although the modern apply role was allowed `cloudwatch:PutCompositeAlarm` on `alarm:shiptrack-modern-*`. The CloudWatch API reference says the caller must hold that permission scoped to `*`, and that a narrower scope cannot create a composite alarm. Metric alarms in the same statement were created without trouble.

**Decision:** `cloudwatch:PutCompositeAlarm` moves out of the `AlarmsAndDashboards` statement into its own `CompositeAlarms` statement in `bootstrap/policies/modern.tf`, with `Resource: *` and an `aws:RequestedRegion` condition. Everything else in the statement stays scoped to `shiptrack-modern-*`. Only the modern apply role gets it; legacy and platform create no composite alarms.

**Consequences:** The modern pipeline can create a composite alarm of any name in the region. A composite alarm only reads the state of other alarms and notifies the actions it names, so the exposure is a misleading alarm, not access to data or resources. The change reaches the role through `apply-bootstrap.yml`, run by hand in the `bootstrap` environment. If CloudWatch ever accepts a scoped grant, the statement can fold back into `AlarmsAndDashboards`.

## ADR-0025: state-lock-recovery-workflow

**Status:** Accepted

**Context:** A platform `apply-terraform` run cancelled by hand left its state lock behind. The lock outlived the run by more than a day, and every pull request plan and every later apply failed on it. Clearing it needs write access to the state bucket, which only a pipeline role has, since nothing is applied from a workstation.

**Decision:** `.github/workflows/ops-unlock-state.yml` runs `scripts/force-unlock.sh` by hand in the `dev` environment, so a reviewer approves each run, with the apply role. It takes the lock ID from the failing run's message. The script reads the lock object in the state bucket and refuses unless the ID matches exactly and the lock is older than 30 minutes. It shares `apply-terraform`'s concurrency group, so it waits for a running apply instead of racing it.

**Consequences:** A stale lock is cleared by a reviewed pipeline run instead of someone's own credentials. A lock younger than 30 minutes cannot be removed this way, which is the case where removing it could corrupt a run that is still writing state. The workflow covers `terraform/envs/dev` only; the bootstrap and legacy and modern states are separate and would need their own.

## ADR-0026: modern-preview-listener

**Status:** Accepted

**Context:** There is one ALB and no custom domain, so legacy and modern share one address. Modern is reachable only through the test-routing headers, which a browser does not send, so a person cannot open its UI next to legacy's. Weighting traffic toward modern to look at it would be the cutover itself.

**Decision:** An optional listener on `preview_port` (default 8080) forwards everything to `tg-modern`, outside the cutover weights. The ALB security group opens that port only to the CIDRs in `preview_ingress_cidrs`. The default is empty, which creates no listener and no rule, and `0.0.0.0/0` is refused by validation. The CIDRs come from the `PREVIEW_CIDRS` repository secret through `TF_VAR_preview_ingress_cidrs`. A secret and not a variable, because the logs and pull request comments of this public repository would otherwise show a person's address: Actions logs print each step's `env:` values and do not mask variables. The workflows also register each address with `::add-mask::`, and the security group rules are keyed by position, so a plan summary prints `preview["0"]` and not the address. The listener is plain HTTP, like the main one without a domain (risk R-01).

**Consequences:** Legacy's routing is not touched, and deleting the secret removes the listener and the rule. Modern answers on a second port to anyone in the named CIDRs, with no token, and shares the legacy database, so what is done in its UI writes real rows. The WAF association, if enabled, covers the ALB and so this listener. The address is a person's current one, so it needs updating when it changes. With a custom domain and TLS this should move to a host-based rule on the TLS listener.

## ADR-0027: validation-tooling-and-the-nightly-drift-check

**Status:** Accepted

**Context:** P6b and P7 add the contract suite, the k6 scenarios, and the workflows that run them and watch for drift. The simulator is already recorded in ADR-0023. Several details were left open, and by the time these landed other changes had added state the workflows have to agree with.

**Decision:**
- The contract suite is checked against the real legacy application, not only by reading the spec: it was run against a local instance and found the real behaviour (a malformed shipment id is a plain 404, an over-long idempotency key is a 422 validation error, event ingestion is asynchronous so the suite polls the track view). `SINGLE_STACK=1` lets the POD tests run when `BASE_URL` points straight at one stack and not at the ALB; without it they need `TARGET` set, as the design requires.
- A test fails if any endpoint in the legacy §3.4 table has no test, so the suite cannot quietly fall behind the spec.
- Modern's `deploy-app.yml` consumes the suite as `cd validation/contract && TARGET=modern uv run --frozen pytest -m smoke`, with `BASE_URL` and `TEST_TOKEN` from the environment, so the `smoke` marker, the lockfile, and those variable names are an interface and change only together.
- `check-live-stack.yml` adds a fourth suite, `contract-ui-parity`, for cutover gate G6, and runs `contract-full` without the parity tests, which need both stacks. It uploads nothing: a failure message can contain the ALB address, which is masked in the log but not in a file.
- `check-drift.yml` runs nightly on `dev` with the plan role (no environment, so the `ref:refs/heads/dev` trust applies). `terraform-ci.sh drift` exits 0, 2, or 1; exit 2 opens or updates one issue, "Drift detected: platform/dev", with addresses and actions only, and a clean plan closes it. Exit 1 fails the job. It passes `TF_VAR_preview_ingress_cidrs` from the same secret as the apply and registers the addresses as masked values, as ADR-0026 requires of every workflow that plans `terraform/envs/dev`; without it the preview listener would look like drift to destroy every night.
- `ci-validation.yml` runs on pull requests that touch `validation/` or `scripts/`: lint and tests for the contract suite and the simulator, `k6 inspect` for each scenario, and the shell tests for `terraform-ci.sh` (the drift exit codes and the masking of identifiers, against fake `aws` and `terraform` programs) and for `force-unlock.sh`.
- The k6 summary JSON holds metrics only, with no URLs or headers; routes are tagged by name, not by address.

**Consequences:** The UI checks cannot be run against the bare application process, because nginx serves `/ui/` in legacy; they run against a deployed stack. The k6 baseline against the bare application shows its UI iterations as failures for the same reason. Any new workflow that plans `terraform/envs/dev` has to pass the preview secret too.

## ADR-0028: cutover-controls-as-workflows

**Status:** Accepted

**Context:** The design's break-glass rollback (§7) is a human with their own admin role running `aws elbv2` commands from a list in `var.breakglass_principal_arns`. That variable was never built, and the person who runs this project has no AWS CLI access: the pipeline roles are assumable only by GitHub OIDC, by design. The only rollback left was a pull request, review, and apply, which is the wrong speed for an incident. Judging the gates (G2 to G5) and the wave 0 exit criterion on Inspector had the same problem: the console and the CLI are not available, and reading them out of a public log must not print an identifier.

**Decision:**
- **`ops-rollback-cutover.yml`** runs `scripts/rollback-cutover.sh` with the apply role behind the `dev` environment's reviewer. It rewrites only weights, only on actions that forward to both target groups, keeps stickiness, leaves the header rules and the preview listener alone, is idempotent, and verifies the result. `check-drift.yml` reports the difference from `var.cutover` until a pull request reconciles it within 24 hours (design R-06).
- **`check-cutover-gates.yml`** runs `scripts/cutover-gates.sh` with the read-only plan role and prints a table: G2 and G3 from `RequestCount`, `HTTPCode_Target_5XX_Count`, and `TargetResponseTime` p95 on each target group, G4 from the alarms in `ALARM`, and G5 from the events queue and the dead-letter queues. A gate without at least `MIN_REQUESTS` on each target group is `NO DATA`, never a pass. G1 and G6 stay in `check-live-stack.yml`.
- **`check-security-findings.yml`** runs `scripts/security-findings.sh` with the plan role: Inspector findings by severity and fix availability, failing on a fixable CRITICAL or HIGH, and Security Hub CRITICAL and HIGH by control title. It says so when Security Hub cannot be read, instead of showing none.
- All three print counts, ratios, seconds, alarm names, and public finding titles, and no ARN, account ID, resource identifier, or address.
- `docs/runbooks/cutover.md` holds the wave procedures with the exact `tfvars` diff per step and one section per alarm, because every alarm description already links to `cutover.md#<alarm>`; `docs/runbooks/break-glass-rollback.md` holds the rollback.

**Consequences:** A rollback is one workflow run and one approval, available to whoever can approve a deploy, and it works with no AWS CLI. It is a second path that changes the ALB outside Terraform, which is the point of break-glass, so the nightly drift check is what keeps it honest; the 24 hour reconcile rule is therefore a requirement and not a courtesy. The apply role can do this because it holds `PowerUserAccess`; the same call would be refused to the plan role. The gates script reads CloudWatch aggregates over one window: its p95 is the larger of the window's data points, which can be stricter than a single p95 across the whole window, and with little traffic it says `NO DATA`. Nothing here lifts the point of no return at wave 3 step 4.

## ADR-0029: findings-gate-covers-modern-only

**Status:** Accepted

**Context:** ADR-0028's `check-security-findings.yml` failed the gate on every account-wide fixable CRITICAL or HIGH Inspector finding. Inspector is enabled for the whole account, and the first run counted 82 fixable findings on EC2 instances: some on ShipTrack's, some on instances this project does not own. The wave 0 exit criterion in modern's design is "0 fixable CRITICAL/HIGH in deployed images". A gate that another team's instance can fail says nothing about the cutover, and one that counts legacy's deliberately pinned AMI (AP-14) as a failure cannot pass until legacy is gone.

**Decision:**
- Each finding is placed in a scope from its resource: **modern** is an ECR repository named `shiptrack/...`, a node tagged `eks:cluster-name=shiptrack`, or a resource tagged `Stack=modern`; **legacy** is a resource tagged `Stack=legacy`; **other** is everything else in the account.
- The gate fails on a fixable CRITICAL or HIGH finding in **modern** only. The legacy and other counts are printed, by resource type, so the baseline stays visible. A finding outside modern is never named in the log.
- A finding is fixable when Inspector reports `fixAvailable` as `YES` or `PARTIAL`, as before.

**Consequences:** The criterion measures what modern deploys, and nobody else's resources can block a wave. The scope comes from tags and a repository prefix, so a modern resource that carries none of them is counted as other and would not fail the gate: a new kind of resource needs its tag checked here. Legacy's findings are not gated, which is correct for a stack whose AMI is pinned on purpose, and they are the "before" number for the assessment.

## ADR-0030: cutover-steps-gated-by-evidence-not-durations

**Status:** Accepted

**Context:** The design held each weight step for 30 minutes, held wave 2 at 100% for 24 hours before the schema handoff, and kept legacy for 7 days before destroying it. The person running the migration decided that the migration is to be finished in one working session, and that the steps are to be gated by what the gates measure, not by elapsed time.

**Decision:**
- A weight step is judged over an **evidence window** in which each target group saw at least `MIN_REQUESTS` requests (default 100). With less, a gate says `NO DATA`, which is not a pass, and the step does not advance.
- A step advances when G1 to G4 pass (G5 from wave 2). The handoff starts when wave 2 is at 100% with G1 to G5 passing, and legacy is destroyed once the wave 3 checks (one alert per breach, contract migration applied) are verified.
- No fixed duration is part of the design. `window_minutes` stays a parameter of `check-cutover-gates.yml`, because a window is how a gate is measured; the operator sets it to cover the load.

**Consequences:** The migration can complete as fast as the gates allow. A fault that shows only over hours (a nightly job, a connection leak, a cache expiry, a daily traffic shape) is not caught by a gate that passes in minutes, and the 7-day legacy retention that served as a second rollback window is gone: after the wave 3 contract migration rollback is forward-fix only, as before, and the only remaining safety net before it is `ops-rollback-cutover.yml`. The alarms, the nightly drift check and the SLO burn alarms keep running after each step, so a late fault still pages; it just no longer holds the next step back.

## ADR-0031: g3-per-route-with-an-event-route-allowance

**Status:** Accepted

**Context:** G3 was "tg-modern p95 ≤ 1.2 × tg-legacy p95", read from the target-group aggregate. At 100% of writes (wave 2, step 2d) it read 18.6 ms against 13.3 ms, 1.40, and failed. The same-runner comparison (`k6-baseline` with `TARGET=both`) shows why: track is 0.98 at p95, creation 1.15, the UI shell 1.12, and `POST /events` 2.76 (36.9 ms against 13.4 ms). That route waits for SQS before it answers `202`, because modern never acknowledges an event it has not durably queued (modern REM-06); legacy answers from an in-process queue (AP-06), which is the defect the migration removes. Events are 15% of the mix, so the aggregate moves.

**Decision:**
- G3 is judged per route from one runner, with `k6-baseline` and `TARGET=both`: every route's p95 is at most 1.2 times legacy's, except `POST /events`.
- `POST /api/v1/shipments/{id}/events` is allowed a p95 of at most legacy's plus 50 ms. The measured gap was 23.5 ms in this environment, and 30 ms with a more distant runner; the bound has margin over both.
- The target-group figure from `check-cutover-gates.yml` is still printed and is information, because it mixes route shares that change as the weights move.

**Consequences:** The allowance is the price of durable event ingestion, written down, instead of a failure that stays open. It is only measured on a short synthetic run, so a regression in the other routes is still caught at 1.2, and a regression in the event route past 50 ms is caught as well. The aggregate can read above 1.2 with every route within its bound. Reducing the gap (a shared SQS client, a regional endpoint) is a performance task and does not block the migration.

## ADR-0032: legacy-kept-reachable-on-the-preview-port

**Status:** Accepted

**Context:** The design ended the migration by scaling legacy to 0, destroying its stack, and removing `tg-legacy` (wave 3, steps 5 and 6). The owner decided that nothing is destroyed and that legacy's address on port 8080 stays. ADR-0026 made the preview listener forward to modern, so that modern's UI could be opened beside legacy's; once modern serves the main address that is the wrong way round.

**Decision:**
- The preview listener's target is a variable, `preview_stack`, `modern` (the default, ADR-0026) or `legacy`. The dev environment sets `legacy` once modern serves the main address.
- Legacy keeps its Auto Scaling group, its hosts, `tg-legacy`, and its database access. Nothing is scaled to zero and nothing is destroyed. The preview CIDRs still decide who can reach the port.
- Modern is still reachable beside it with the test-routing headers on the main address, which the header rules route to modern whatever the weights say.
- The wave 3 steps that scale legacy to zero and destroy it are not taken.

**Consequences:** Legacy continues to cost what two hosts cost, and its AMI stays pinned (AP-14), so its findings stay as the baseline; they are not gated (ADR-0029). Legacy's cron jobs are removed in wave 3 so that it does not scan or sync. A person who opens legacy's UI on 8080 can still write through it to the shared database: legacy is not read-only. Decommissioning later is the change `desired_capacity = 0` and removing `tg-legacy` and the listener, and it needs its own ADR.

## ADR-0033: retire-ui-build-parity-gate

**Status:** Accepted

**Context:** Gate G6 (§7) required both stacks to serve identical hashed UI asset names, with the UI source frozen until wave 2, so that a browser sticky to one stack never loaded a shell from one stack and assets from the other while the weights moved (R-08). The cutover is complete: both rules are at modern 100, legacy serves nothing on the main address, and it is kept as a fallback on the preview port. The owner asked that modern's UI be built out and that legacy's stay as it is.

**Decision:** G6 is retired. The `ui_parity` test, its marker, and the `contract-ui-parity` suite are removed, and the design, runbook, and README no longer list it. The modern UI uses only the endpoints of the frozen contract.

**Consequences:** The two stacks serve different UI builds. Nothing mixes them in normal use: the main address is modern's and the preview port is legacy's, each answering for both page and assets. The one exposure is a rollback of the weights, after which a browser holding modern's cached `index.html` asks legacy for assets that legacy does not have; a reload fixes it. The contract's `ui` checks remain, and assert the shell, its assets, deep links, and the missing-asset 404 on whichever stack is addressed.

## ADR-0034: data-reset-by-gated-workflow

**Status:** Accepted

**Context:** Synthetic traffic, the simulator, and the contract suites create shipments that nothing deletes: the API has no delete and the contract is frozen. Modern's live page and Browse read every shipment, so the data only grows. The owner asked for a workflow that resets all the data, and that it belong to the platform, because the database and the proof-of-delivery bucket are the platform's and both stacks read them. It was first built in `shiptrack-legacy` (legacy ADR-0013) and moved here before it was ever run.

**Decision:**
- `ShipTrack-ResetData` is an SSM document created by `terraform/modules/data_reset`, like the ones the stacks run on the legacy hosts, and it carries its own copy of `db/reset-data.sql` and `scripts/reset-data.sh`, so a reset needs no deploy on either stack. `ops-reset-data.yml` runs it on every host tagged `Stack=legacy`, one at a time, with the apply role, behind the `dev` environment's reviewer, in the `tf-platform-dev` concurrency group.
- The executor is a legacy host because the database is private and a host is the one place a workflow can reach it from (legacy ADR-0011). The script is platform's: it reads the application role's credentials from the contract's `db_app_secret_arn` and runs the SQL as that role over verified TLS. It needs nothing from the legacy application, so retiring the legacy application's code does not break it; retiring the hosts does, and then the executor moves (a Kubernetes Job in modern's chart) without changing the SQL.
- It refuses unless the confirmation is exactly `delete-all-shipments`, in the workflow and in the document's allowed pattern, which has no default.
- Order: the database in one transaction (alerts, documents, events, shipments), then the objects under `pod/` in the proof-of-delivery bucket, then each host's local files. A failure in the database leaves the files alone.
- Carriers and the schema are kept. Five demo shipments with fixed tracking numbers (`MF0000000001` to `MF0000000005`, one in each of five statuses) are created afterwards unless `seed_demo` is `no`, so that there is always something to look up.
- Output is counts and those five synthetic tracking numbers.
- The document already existed, created by the legacy Terraform, so this Terraform adopted it with an `import` block and legacy's forgot it without deleting it (`removed` with `destroy = false`): nothing was destroyed and the name never lapsed. Both blocks were removed once the applies had run.

**Consequences:** It is the only thing that deletes shipments, it cannot be undone, and it needs a person to approve it. Events still in the queue for shipments that are gone fail to apply and end in the dead-letter queue, so the traffic must be stopped and the queue drained first; the workflow says so and nothing checks it. Versioned buckets keep earlier versions of the removed documents as noncurrent versions, unreachable from the application. The seeded numbers are fixed, so a later run reuses them. The document embeds `db/reset-data.sql` and `scripts/reset-data.sh`, so `ci-terraform` and `apply-terraform` also run when either changes, and the change reaches the hosts through the `dev` gate. `db/tests/reset-data.sh` runs the SQL as the application role against a PostgreSQL that has the legacy migration's tables, so a schema change that breaks the reset fails there; the fixture mirrors the migration by hand.

## ADR-0035: grafana-on-the-preview-addresses

**Status:** Accepted

**Context:** Modern's Grafana reads the Amazon Managed Prometheus workspace, but it is a ClusterIP service reached with `kubectl port-forward`, and the owner has no `kubectl` or AWS CLI. The owner wants to open Prometheus and Grafana dashboards in a browser while traffic runs. Amazon Managed Grafana would give HTTPS and a login, but needs IAM Identity Center and a console assignment this account's owner would have to do, and a service-account token for Terraform to provision dashboards.

**Decision:**
- The ALB gets a listener on `grafana_port` (default 3000), created with the preview listener and reachable only from the same `preview_ingress_cidrs` (the `PREVIEW_CIDRS` secret). It forwards everything to `tg-grafana`, an `ip` target group that always exists.
- Platform registers no targets. The modern addons root binds the Grafana service to `tg_grafana_arn`, which the contract publishes, with a TargetGroupBinding.
- The listener is HTTP, like the main listener and the preview listener without a custom domain (risk R-01). Grafana allows anonymous read-only access; the allow-listed addresses are the control. What it shows is metrics: route templates, status classes, and counts, with no tracking numbers or secrets.
- It is outside the cutover weights and never touches the weighted rules.

**Consequences:** One more port is open to the named addresses, and anyone who can send from one of them can read the metrics and use Grafana's query explorer. A path between the owner and the ALB can read them too, which is the same exposure as the preview port. Removing the `PREVIEW_CIDRS` secret and applying removes the listener and its rules; the target group stays. If a custom domain arrives, this listener should move to HTTPS with the rest.
