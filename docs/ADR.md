# ShipTrack Platform — Architecture Decision Log

Decisions are recorded here, oldest first. Each entry has a status (Planned, Accepted, Superseded) and, once decided, Context, Decision, and Consequences. Entries marked Planned are decisions the design expects to be made during the build.

| # | Title | Status |
|---|---|---|
| 0001 | `security-hub-cspm-scope` | Planned |
| 0002 | `test-routing-header-token` | Planned |
| 0003 | `plan-role-secret-access` | Planned |
| 0004 | `nat-vs-interface-endpoints` | Planned |
| 0005 | `seed-role-and-bootstrap-workflow` | Accepted |
| 0006 | `public-repositories` | Planned |
| 0007 | `dev-branch-and-environment` | Planned |
| 0008 | `branching-and-environment-protection` | Accepted |
| 0009 | `bootstrap-iam-hardening` | Accepted |
| 0010 | `local-verification-with-moto` | Accepted |

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

**Decision:** The OIDC provider and the `shiptrack-bootstrap` seed role (AdministratorAccess, trusted only for the protected `bootstrap` environment of the platform repository) are created by hand. Terraform reads the provider by data source and does not manage the seed role. `bootstrap-apply.yml` creates the state bucket, the permission boundary, and the nine deploy roles. On the first run only the state bucket is created with local state, which is then migrated into the bucket before anything else is applied.

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

**Consequences:** A privilege-escalation path through the platform pipeline is closed. Changes to bootstrap-owned resources always go through bootstrap-apply.yml.


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

**Consequences:** A renamed or transferred repository keeps its trust only if its IDs are unchanged, and a deleted and recreated repository does not inherit it. The documented subject forms cover branch refs; the `environment` and `pull_request` suffixes follow the same pattern but are not shown in GitHub's documentation. The `:environment:bootstrap` suffix is confirmed: the seed role was assumed by the first `bootstrap-apply` run. The `pull_request` and `ref:refs/heads/dev` suffixes are confirmed by the first plan-role run **[VERIFY]**.

## ADR-0013: terraform-workflow-structure

**Status:** Accepted

**Context:** §6.11 lists the pull-request checks in one sequence that starts with `init` under the plan role. The state bucket name contains the account ID, so the backend cannot be committed, and fork pull requests receive no OIDC token.

**Decision:** `terraform-pr.yml` has two jobs. `lint` (format, `validate` with `init -backend=false`, TFLint, Checkov, Trivy) needs no AWS access and runs for forks. `plan` runs only for same-repository pull requests, after `lint`, under the plan role. Both `plan` and `terraform-apply.yml` run `scripts/terraform-ci.sh`, which looks up the account, derives the bucket name `shiptrack-tfstate-<account>-<region>` as bootstrap does, and passes the backend settings to `init`, so `terraform/envs/dev/backend.tf` holds only an empty `backend "s3" {}` block. Trivy runs twice over the repository: once for the SARIF report sent to code scanning, once as the gate. Checkov is installed with `pipx` at a pinned version because it has no action to pin to a SHA.

**Consequences:** Lint runs on every Terraform pull request without credentials. The apply workflow's path filter is `terraform/**` only, so edits to the workflow or the script are exercised by the plan job on the pull request rather than by an approval-gated apply. `terraform-apply.yml` fails if `terraform/envs/dev` does not exist when `terraform/**` changes, which P1 prevents by adding both together.

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
- `.github/workflows/inspect-account.yml` stays as a read-only diagnostic that lists these services by name and status, without ARNs or account IDs.

**Consequences:** The Config setup that existed before this project is changed. The old `config-bucket-*` bucket is left as it is. A fresh account without these services needs the defaults (`shiptrack-recorder`, `shiptrack-delivery`, `manage_access_analyzer = true`) and no import blocks.
