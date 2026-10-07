# ShipTrack Platform — Design Document

| | |
|---|---|
| **Repository** | `shiptrack-platform` |
| **Author** | M.L. |
| **Status** | v0.1 |
| **Last updated** | 2026-10-06 |
| **Related** | `shiptrack-legacy/docs/DESIGN.md`, `shiptrack-modern/docs/DESIGN.md` |

---

## 0. Instructions for the implementing agent

1. Read this entire document before writing code. Implement in the phase order in §13. Complete each phase's "Done when" checks before starting the next.
2. **Never run `terraform apply`, `terraform destroy`, or any command that creates, changes, or deletes AWS resources from a workstation.** No AWS credentials are present locally. Infrastructure changes only through GitHub Actions workflows (§6.11) assuming OIDC roles, with environment approval for every apply. Locally you may run `fmt`, `validate`, `tflint`, `checkov`, `trivy config`, and (against LocalStack only) `terraform plan`; plans against real AWS run in workflows.
3. No hardcoded account IDs, ARNs, regions, GitHub org names, or email addresses. Use variables and data sources.
4. No secrets in code, `.tfvars`, or Terraform state where avoidable (see §6.4).
5. Pin every version (§3). Pin third-party GitHub Actions to full commit SHAs, with the tag in a trailing comment.
6. If a requirement is ambiguous or conflicts with a provider/API constraint, stop and ask. Record every non-trivial decision in `docs/ADR.md` (context, decision, consequences).
7. Items marked **[VERIFY]** depend on fast-moving AWS/tooling details. Confirm against current documentation before implementing; if reality differs, follow reality and record it in `docs/ADR.md`.
8. **Public repository.** All three repositories are public. Follow §6.12: no account IDs, ARNs containing account IDs, DNS names, host IDs, or tokens in committed files, workflow logs, PR comments, artifacts, or evidence.

---

## 1. Context

Meridian Freight runs **ShipTrack**, a shipment-tracking application, on EC2. This project migrates it to Amazon EKS using a three-repository migration factory:

| Repo | Owns | Lifecycle |
|---|---|---|
| **`shiptrack-platform`** (this repo) | Shared, long-lived infrastructure and the **cutover control point** (ALB weights) | Outlives both app stacks |
| `shiptrack-legacy` | EC2/ASG tarball deployment of ShipTrack v1.x ("before" state) | Decommissioned after Wave 3 |
| `shiptrack-modern` | EKS/Helm containerized ShipTrack v2.x ("after" state) | Target state |

**Ownership rule:** a resource belongs here if it is long-lived, shared by both stacks, or controls cutover. Everything else belongs to the app repo that consumes it.

Platform publishes its outputs as an **SSM Parameter Store contract** (§6.9). App repos never read this repo's Terraform state.

---

## 2. Scope

### In scope
- One-time bootstrap: Terraform state bucket, GitHub OIDC provider, deploy roles, workload permission boundary
- Network: VPC, subnets, NAT, VPC endpoints, flow logs, shared security groups
- KMS keys for data, secrets, and logs
- RDS PostgreSQL, database credentials, DB bootstrap SQL and runbook
- POD (proof-of-delivery) S3 bucket and log buckets
- Ingress: ALB, listeners, both target groups, weighted, header, and path routing
- Account security services: CloudTrail, GuardDuty, AWS Config, Security Hub CSPM, Inspector, IAM Access Analyzer
- Shared observability: SNS alert topics, ALB/RDS alarms, cutover dashboard
- Validation tooling: API contract tests, k6 load tests, carrier event simulator
- Cutover and break-glass runbooks
- CI/CD for this repo's Terraform

### Non-goals (documented as known gaps)
- Multi-account landing zone / AWS Control Tower
- Multi-region DR
- Application authentication/authorization
- A custom domain is optional; without it, HTTPS is not available (risk R-01)

---

## 3. Toolchain and versions

| Tool | Constraint | Notes |
|---|---|---|
| Terraform | `>= 1.11, < 2.0` | Needed for S3 native locking, ephemeral resources, and write-only arguments |
| AWS provider | `~> 6.0` **[VERIFY latest minor]** | |
| Random provider | `~> 3.7` | Ephemeral `random_password` |
| TFLint | Latest + `tflint-ruleset-aws` | |
| Checkov, Trivy | Latest | IaC scanning |
| Python | 3.12 | Validation tooling only; `uv` with lockfiles |
| k6 | Latest stable | Load testing |
| OrbStack, LocalStack | Latest | Local development only (Docker, Kubernetes, AWS API emulation); never a substitute for the checks that run in workflows |

Default region is the `aws_region` variable (default `us-east-1`).

---

## 4. Architecture

```
                              Internet
                                  │
                ┌─────────────────▼──────────────────┐  public subnets (3 AZ)
                │   ALB  shiptrack-alb               │──► access logs → S3 (SSE-S3)
                │   rules: header │ path │ weighted  │
                └───────┬───────────────────┬────────┘
                        │                   │
              ┌─────────▼────────┐ ┌────────▼──────────────┐
              │ tg-legacy        │ │ tg-modern (ip)        │
              │ (instance, :80)  │ │ (:8000, registered by │
              └─────────┬────────┘ │  TargetGroupBinding)  │
                        │          └────────┬──────────────┘
   private-app subnets  │                   │
              ┌─────────▼────────┐ ┌────────▼──────────────┐
              │ legacy ASG (EC2) │ │ EKS pods              │
              │ [shiptrack-legacy]│ │ [shiptrack-modern]   │
              └─────────┬────────┘ └────────┬──────────────┘
                        └───── sg-db-client ┘
   private-data subnets          │
                        ┌────────▼─────────┐
                        │ RDS PostgreSQL   │  KMS: shiptrack-data
                        └──────────────────┘

  Shared: S3 POD bucket · Secrets Manager (db/app, db/migrator) · KMS ×3
          CloudTrail · GuardDuty · Config · Security Hub CSPM · Inspector
          SNS sev1/sev2 · cutover dashboard · SSM contract /shiptrack/platform/*
```

---

## 5. Repository layout

```
shiptrack-platform/
├── bootstrap/                    # Applied only by bootstrap-apply.yml (seed role, §6.1)
│   ├── main.tf  variables.tf  outputs.tf  versions.tf
│   ├── policies/                 # JSON/HCL policy documents per role
│   └── README.md                 # Manual seed steps + workflow procedure
├── terraform/
│   ├── modules/
│   │   ├── network/
│   │   ├── kms/
│   │   ├── database/
│   │   ├── storage/
│   │   ├── ingress/
│   │   ├── security-services/
│   │   ├── observability/
│   │   └── contract/             # Writes SSM parameters
│   └── envs/dev/
│       ├── backend.tf  versions.tf  providers.tf
│       ├── main.tf  variables.tf  outputs.tf
│       └── terraform.tfvars      # Non-secret, non-identifying values only; org, emails, domain, owner come from repo variables (TF_VAR_*)
├── db/
│   ├── bootstrap.sql             # Roles, schema, grants (psql variables, no literals)
│   └── RUNBOOK-db-bootstrap.md
├── validation/                   # Each package: pyproject.toml + uv.lock
│   ├── contract/                 # pytest API contract suite (canonical); tests/, results/
│   ├── simulator/                # Carrier event simulator; installable package so a workflow can ship it as a wheel
│   └── loadtest/                 # k6 scenarios + results/
├── docs/
│   ├── DESIGN.md                 # This file
│   ├── ADR.md                    # Decision log
│   ├── runbooks/
│   │   ├── cutover.md
│   │   └── break-glass-rollback.md
│   └── security/findings-register.md
├── .github/
│   ├── workflows/
│   │   ├── bootstrap-apply.yml
│   │   ├── terraform-pr.yml
│   │   ├── terraform-apply.yml
│   │   ├── drift.yml
│   │   └── validation.yml
│   ├── dependabot.yml            # github-actions + pip
│   └── CODEOWNERS                # .github/ and bootstrap/ (R-09)
├── .tflint.hcl  .checkov.yaml  .pre-commit-config.yaml  .gitleaks.toml  .gitignore
└── README.md                     # Overview + one-time `gh` commands for branch protection and environments (§6.12)
```

---

## 6. Component design

### 6.1 Bootstrap (`bootstrap/`)

Bootstrap solves the chicken-and-egg problem: the pipelines need roles and a state bucket before any pipeline can run. It is applied **only by the `bootstrap-apply.yml` workflow**, using a manually created seed role. Nothing is ever applied from a workstation.

**Manual prerequisites (a human, once; documented in `bootstrap/README.md`):**
1. In the AWS account, create the GitHub OIDC provider (values below).
2. Create IAM role `shiptrack-bootstrap` with trust `StringEquals` on `token.actions.githubusercontent.com:aud = sts.amazonaws.com` and `:sub = repo:<org>/shiptrack-platform:environment:bootstrap`. Attach `AdministratorAccess` initially, because bootstrap creates IAM roles, the permission boundary, and KMS keys. Narrowing or retiring it is tracked as risk R-10.
3. In GitHub, on `shiptrack-platform`: create environment `bootstrap` with required reviewers; protect `dev`; enable "Require approval for all outside collaborators"; set repo variables for the seed role ARN and the region (§6.12).

Terraform does **not** manage the OIDC provider or the seed role. It reads the provider with `data "aws_iam_openid_connect_provider"`. Keeping the seed role manual means the pipeline cannot modify its own foundation.

**`bootstrap-apply.yml`** (`workflow_dispatch`): jobs `plan` and `apply`, both with `environment: bootstrap`. The second approval is the review of the plan summary (§6.12) printed by the first job. `bootstrap/` has no committed backend block. The workflow checks whether the state bucket exists (`head-bucket`):
- **First run:** apply with local state, then generate `backend_override.tf` (never committed) and run `terraform init -migrate-state -force-copy` in the same job.
- **Later runs:** write the override first and initialize against S3.

Apply uses a fresh plan from the same job. No plan file is uploaded as an artifact.

**State bucket** `shiptrack-tfstate-<account_id>-<region>`
- Versioning on; SSE-KMS with a dedicated CMK `alias/shiptrack-tfstate`; Block Public Access (all four settings); `BucketOwnerEnforced` ownership
- Bucket policy denies `aws:SecureTransport = false`
- Lifecycle: expire noncurrent versions after 90 days
- Locking: S3 backend `use_lockfile = true`. **Do not use DynamoDB locking** (deprecated in Terraform 1.11).
- State keys:

| Key | Owner |
|---|---|
| `bootstrap/terraform.tfstate` | bootstrap |
| `platform/dev.tfstate` | platform |
| `legacy/dev.tfstate` | legacy |
| `modern/cluster/dev.tfstate` | modern (cluster root) |
| `modern/addons/dev.tfstate` | modern (addons root) |

- Bootstrap's own state starts local inside the first `bootstrap-apply.yml` run and is migrated into the bucket in that same job. `bootstrap/README.md` documents the procedure and the recovery if the migration step fails.

**GitHub OIDC provider:** created manually (prerequisite 1): URL `https://token.actions.githubusercontent.com`, client ID `sts.amazonaws.com`. Omit the thumbprint if the console allows it, since AWS no longer validates the GitHub thumbprint **[VERIFY]**. Only one provider per URL can exist in an account, which is why Terraform reads it by data source instead of creating it.

**Workload permission boundary** `shiptrack-workload-boundary` (managed policy)
- Attached to **every** IAM role created by the legacy and modern pipelines
- Allows only the service namespaces ShipTrack workloads and controllers need: `ec2`, `autoscaling`, `elasticloadbalancing`, `eks`, `eks-auth`, `ecr`, `sqs`, `events`, `s3`, `secretsmanager`, `kms`, `ssm`, `ssmmessages`, `ec2messages`, `cloudwatch`, `logs`, `aps`, `xray`, `sts`, `pricing`, `tag`, `acm`, `cognito-idp`, `wafv2`, `waf-regional`, `shield` (the last four appear as read/associate actions in the vendored AWS Load Balancer Controller policy). IAM is limited to `Get*`/`List*`, `iam:PassRole` on `role/shiptrack-*`, and instance-profile actions (`Create`/`Delete`/`Tag`/`AddRoleTo`/`RemoveRoleFrom` `InstanceProfile`) on `instance-profile/*`, because Karpenter creates instance profiles at runtime.
- **Gotcha:** a boundary is an intersection with the role's own policy. An action missing here makes the LBC or Karpenter controller fail at runtime with `AccessDenied`, not at apply time. Add a test that diffs the boundary against every policy attached to a role that carries it: the vendored LBC and Karpenter controller policies, and the managed or vendored policies for the EKS cluster and node-group roles, VPC CNI, the CloudWatch observability add-on, KEDA, and Grafana (`aps`). Actions a policy needs that the boundary excludes (for example `iam:CreateServiceLinkedRole` in `AmazonEKSClusterPolicy`) must be satisfied out of band: the apply roles create the required service-linked roles before the controllers need them.
- Explicitly denies:
  - Modifying or deleting CloudTrail, GuardDuty, Config, Security Hub, Inspector, and Access Analyzer
  - `iam:CreateUser`, `iam:CreateAccessKey`
  - Removing or changing permission boundaries
  - `kms:ScheduleKeyDeletion` on platform keys
  - Organizations actions

**Deploy roles** (9 total). Trust uses `StringEquals` on `token.actions.githubusercontent.com:aud = sts.amazonaws.com` and on `:sub` (a list where two values are shown). The `sub` value depends on how the job runs:
- `pull_request` event → `repo:<org>/<repo>:pull_request`
- job with `environment:` → `repo:<org>/<repo>:environment:<name>`
- push, schedule, or dispatch on `dev` without an environment → `repo:<org>/<repo>:ref:refs/heads/dev`

| Role | `sub` condition | Permissions summary |
|---|---|---|
| `shiptrack-platform-plan` | `…/shiptrack-platform:pull_request` **or** `…:ref:refs/heads/dev` (drift + validation workflows) | `ReadOnlyAccess`; state read; `PutObject`/`DeleteObject` on `platform/*.tflock`; KMS decrypt on the state key; `secretsmanager:GetSecretValue` on the test-routing token (§6.6) and, because refreshing `aws_secretsmanager_secret_version` reads the value, on `shiptrack/dev/db/*`, plus `kms:Decrypt` on `shiptrack-secrets` conditioned on `kms:ViaService` **[VERIFY: whether the provider still calls `GetSecretValue` on refresh when write-only arguments are used; drop the DB-secret grants if not]** |
| `shiptrack-platform-apply` | `…/shiptrack-platform:environment:dev` | `PowerUserAccess` (includes `iam:CreateServiceLinkedRole`) + IAM write limited to `shiptrack-*` roles/policies; state read/write |
| `shiptrack-legacy-plan` | `…/shiptrack-legacy:pull_request` **or** `…:ref:refs/heads/dev` | Read-only + legacy state/lock |
| `shiptrack-legacy-apply` | `…/shiptrack-legacy:environment:dev` | EC2/ASG/SSM/S3/Logs/CloudWatch for `shiptrack-legacy-*`; `iam:CreateRole`/`PutRolePolicy`/`AttachRolePolicy` only with `iam:PermissionsBoundary` = boundary ARN and name `shiptrack-legacy-*`; `iam:PassRole` to `shiptrack-legacy-*` |
| `shiptrack-legacy-deploy` | `…/shiptrack-legacy:environment:dev` | `s3:PutObject` to the artifact bucket; `ssm:SendCommand` limited to `ShipTrack-*` documents and instances tagged `Stack=legacy`; `ssm:GetCommandInvocation`/`ListCommandInvocations`; `autoscaling:DescribeAutoScalingGroups`, `ec2:DescribeInstances`; `ssm:GetParameter(s)` on `/shiptrack/*`; `ssm:PutParameter` on `/shiptrack/legacy/current_release`; `secretsmanager:GetSecretValue` on the test-routing token |
| `shiptrack-modern-plan` | `…/shiptrack-modern:pull_request` **or** `…:ref:refs/heads/dev` | Read-only + modern state/locks (EKS view access entry is granted in the modern repo) |
| `shiptrack-modern-apply` | `…/shiptrack-modern:environment:dev` | EKS/EC2/ECR/SQS/Events/APS/Logs/CloudWatch/SSM, KMS key creation (`alias/shiptrack-eks`); `iam:CreateServiceLinkedRole`; `iam:CreateRole`/`PutRolePolicy`/`AttachRolePolicy` boundary-conditioned, name `shiptrack-modern-*`; `iam:PassRole` to `shiptrack-modern-*` |
| `shiptrack-modern-release` | `…/shiptrack-modern:ref:refs/heads/dev` | ECR push/pull on `shiptrack/app` only (`ecr:GetAuthorizationToken`, `BatchCheckLayerAvailability`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage`, `BatchGetImage`, `GetDownloadUrlForLayer`) |
| `shiptrack-modern-deploy` | `…/shiptrack-modern:environment:dev` | `eks:DescribeCluster`; `ssm:GetParameter(s)` on `/shiptrack/*`; `secretsmanager:GetSecretValue` on the test-routing token. Kubernetes permissions come from an EKS access entry plus namespace RBAC (modern repo) |

The org name, repo names, and environment name are variables. **Gotcha:** the plan roles must be able to write `.tflock` objects, because S3 native locking writes a lock file even during `plan`. The seed role `shiptrack-bootstrap` is a tenth role but is manual and outside this table.

### 6.2 Network (`modules/network`)

- VPC `10.40.0.0/16` (variable), DNS hostnames and support on, three AZs (first three from `aws_availability_zones`).

| Tier | Size | CIDRs (example) | Tags |
|---|---|---|---|
| public | /24 | 10.40.0.0/24, .1.0/24, .2.0/24 | `kubernetes.io/role/elb=1` |
| private-app | /20 | 10.40.16.0/20, .32.0/20, .48.0/20 | `kubernetes.io/role/internal-elb=1`, `karpenter.sh/discovery=shiptrack` |
| private-data | /24 | 10.40.64.0/24, .65.0/24, .66.0/24 | — |

  The private-app subnets are /20 because the VPC CNI assigns a VPC IP to every pod.
- **NAT:** variable `nat_gateway_mode = "single" | "per_az"`, default `single` for cost. A single NAT means an AZ outage takes out egress for every AZ (risk R-03).
- **VPC endpoints:**
  - The S3 gateway endpoint is always on (free).
  - Interface endpoints sit behind `enable_interface_endpoints` (default `false`): `ecr.api`, `ecr.dkr`, `sts`, `logs`, `secretsmanager`, `sqs`, `ssm`, `ssmmessages`, `ec2messages`, `kms`, `eks-auth` (required for EKS Pod Identity without NAT).
  - Interface endpoints are billed per AZ-hour per endpoint. NAT versus endpoints is optimization item **O-P1**, decided with measured data.
- **Flow logs** to CloudWatch Logs `/shiptrack/vpc/flow-logs`, retention 14 days, encrypted with the logs key.
- **Default security group:** remove all rules.
- **Shared security groups** (the cross-repo network contract):

| SG | Ingress | Egress | Attached by |
|---|---|---|---|
| `shiptrack-alb` | 80 (and 443 if TLS) from `var.allowed_ingress_cidrs` (default `0.0.0.0/0`) | All to VPC CIDR | Platform (ALB) |
| `shiptrack-db-client` | none | 5432 → `shiptrack-db` | Legacy instances, modern EKS nodes |
| `shiptrack-db` | 5432 from `shiptrack-db-client` only | none | Platform (RDS) |

  App repos create their own app security groups that allow ingress from `shiptrack-alb`. They **must not** add rules to platform-owned security groups.

### 6.3 KMS (`modules/kms`)

| Alias | Used for | Key policy notes |
|---|---|---|
| `alias/shiptrack-data` | RDS storage, POD bucket | Root delegation to IAM; services via `kms:ViaService` |
| `alias/shiptrack-secrets` | Secrets Manager (DB secrets, RDS master secret) | Root delegation to IAM |
| `alias/shiptrack-logs` | CloudWatch Logs, SNS, CloudTrail | Grant `logs.<region>.amazonaws.com` with the `kms:EncryptionContext:aws:logs:arn` condition; grant `cloudwatch.amazonaws.com` and `sns.amazonaws.com` for encrypted alarm topics; grant `cloudtrail.amazonaws.com` |

All keys have rotation enabled and a 30-day deletion window. Workload roles in other repos get decrypt through their **IAM policies**, conditioned on `kms:ViaService`. Do not enumerate cross-repo role ARNs in key policies.

### 6.4 Database (`modules/database`)

- RDS PostgreSQL **17.x** (major/minor as variables) **[VERIFY latest RDS-supported minor]**
- Instance class `db.t4g.medium` (variable); gp3 storage, 50 GiB allocated, max 200 GiB
- `multi_az` variable, default `false` (cost; risk R-05)
- Private-data subnet group; `shiptrack-db` security group; not publicly accessible
- Encrypted with `shiptrack-data`; CA `rds-ca-rsa2048-g1`
- `deletion_protection = true`, final snapshot required, backups 7 days, `copy_tags_to_snapshot = true`
- Explicit maintenance and backup windows (variables)
- `auto_minor_version_upgrade = true`
- Monitoring: CloudWatch Database Insights, Standard mode **[VERIFY — Performance Insights console/API transition]**; Enhanced Monitoring at 60 s
- `enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]`, log group retention 14 days
- Parameter group:
  - `rds.force_ssl = 1`
  - `log_min_duration_statement = 500`
  - `idle_in_transaction_session_timeout = 60000`
- **Master credentials:** `manage_master_user_password = true`, with `master_user_secret_kms_key_id` set to the secrets key. The master user is used **only** for DB bootstrap and break-glass.
- **Application credentials:** two Secrets Manager secrets, both KMS-encrypted with `shiptrack-secrets`:

| Secret name | Postgres role | Privileges |
|---|---|---|
| `shiptrack/dev/db/migrator` | `shiptrack_migrator` | Owns schema `shiptrack`; DDL |
| `shiptrack/dev/db/app` | `shiptrack_app` | DML only, via default privileges |

  - Secret value JSON: `{"username","password","host","port","dbname","engine":"postgres"}`
  - Generate passwords with **ephemeral** `random_password` (length 32, no characters that are problematic in URLs). Write them with `aws_secretsmanager_secret_version` write-only arguments (`secret_string_wo` + `secret_string_wo_version`) so **passwords never enter state**. To rotate, bump the `db_secret_version` variable. (Confirmed supported with Terraform ≥ 1.11 and AWS provider 6.x. A fresh ephemeral value is generated every run, but it is written only when `db_secret_version` changes.)
- **`db/bootstrap.sql`**: idempotent, using `DO $$ … IF NOT EXISTS …` blocks. Passwords are supplied as psql variables (`:'migrator_password'`, `:'app_password'`), never as literals.
  - Creates database `shiptrack`, roles `shiptrack_migrator` and `shiptrack_app` (`LOGIN`; `CONNECTION LIMIT` 150 and 200 respectively), and schema `shiptrack` owned by the migrator.
  - `REVOKE CREATE ON SCHEMA public FROM PUBLIC`
  - `GRANT USAGE ON SCHEMA shiptrack TO shiptrack_app`
  - `ALTER DEFAULT PRIVILEGES FOR ROLE shiptrack_migrator IN SCHEMA shiptrack GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO shiptrack_app` (and `USAGE, SELECT` on sequences)
  - Enables `pgcrypto` only if required (`gen_random_uuid()` is built in on PG 13+).
- **`db/RUNBOOK-db-bootstrap.md`**:
  1. Execute from an **AWS CloudShell VPC environment** in a private-app subnet with `shiptrack-db-client` attached, so no bastion host is needed.
  2. Fetch the master and app passwords from Secrets Manager into shell variables.
  3. Run `psql "sslmode=verify-full" -v … -f bootstrap.sql`.
  4. Verify roles and grants.
  5. Clear shell history.
- **DB access from workflows:** GitHub-hosted runners cannot reach the private RDS instance. The first `bootstrap.sql` run is the only manual DB step (CloudShell, above). Every later workflow that needs the database (evidence queries, `simulator verify`) runs on a host inside the VPC through an SSM Run Command document that a workflow dispatches: a legacy host while the legacy ASG exists (legacy §7.6), then a one-shot Kubernetes Job (modern §11.3). Pipelines never open the database to the internet.
- **Connection budget:** publish `/shiptrack/platform/db_max_connections` with the expected `max_connections` (about 400 on `db.t4g.medium`; **[VERIFY with `SHOW max_connections`]**). Consumers must keep their combined pool ceilings at or below 60% of this value.

### 6.5 Storage (`modules/storage`)

**POD bucket** `shiptrack-pod-<account_id>-<region>`
- Block Public Access, `BucketOwnerEnforced`, versioning on
- SSE-KMS (`shiptrack-data`) **with S3 Bucket Keys enabled** (reduces KMS request cost; optimization **O-P4**)
- Policy denies non-TLS requests. **Do not** add a "deny `PutObject` without the `x-amz-server-side-encryption` header" statement: it rejects clients that rely on bucket default encryption, which already enforces SSE-KMS. If an explicit guard is wanted, deny only when the header is present **and** names a different key.
- Key layout: `pod/{shipment_id}/{document_id}`
- Lifecycle:

| Rule | Action |
|---|---|
| Current versions | STANDARD → STANDARD_IA at 30 d → GLACIER_IR at 90 d → expire at `var.pod_retention_days` (default 2555 ≈ 7 years) |
| Noncurrent versions | Expire at 30 d |
| Incomplete multipart uploads | Abort at 7 d |

**ALB access-log bucket** `shiptrack-alb-logs-<account_id>-<region>`
- **SSE-S3 only.** ALB access logs do not support SSE-KMS.
- Bucket policy grants the regional ELB log-delivery principal **[VERIFY: service principal `logdelivery.elasticloadbalancing.amazonaws.com` vs regional account ID for the region]**
- Lifecycle: expire at 90 d

**CloudTrail bucket** `shiptrack-cloudtrail-<account_id>-<region>`
- SSE-KMS via the trail's key (`shiptrack-logs`); standard CloudTrail bucket policy
- Lifecycle: STANDARD_IA at 30 d, expire at 365 d

### 6.6 Ingress (`modules/ingress`) — the cutover control point

**ALB** `shiptrack-alb`
- Internet-facing, public subnets, `shiptrack-alb` security group
- `enable_deletion_protection = true`, `drop_invalid_header_fields = true`, `desync_mitigation_mode = "defensive"`, idle timeout 60 s
- Access logs enabled

**Listeners**
- If `var.domain_name` is set: an ACM certificate (DNS-validated in the existing Route 53 hosted zone, looked up by data source), an HTTPS:443 listener with TLS policy `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09` (the current console default: TLS 1.3/1.2 with hybrid post-quantum key exchange), and HTTP:80 → 301 redirect to HTTPS.
- Otherwise: HTTP:80 only (risk R-01). All rules below attach to whichever listener serves traffic.

**Target groups**

| Setting | `shiptrack-tg-legacy` | `shiptrack-tg-modern` |
|---|---|---|
| `target_type` | `instance` | `ip` |
| Port / protocol | 80 / HTTP | 8000 / HTTP |
| Health check path | `/` (shallow — legacy AP-07, **intentional**) | `/readyz` |
| Interval / healthy / unhealthy / timeout | 30 / 5 / 2 / 5 | 10 / 2 / 2 / 5 |
| Deregistration delay | 300 s (default) | 30 s |
| Stickiness | `lb_cookie`, 86400 s, **enabled** (legacy AP-05, intentional) | disabled |
| Slow start | 0 | 30 s |

Legacy instances register via the legacy ASG's `target_group_arns`. Modern pods register via the AWS Load Balancer Controller `TargetGroupBinding`. Platform never registers targets itself.

**Listener rules** (lower priority number is evaluated first):

| Priority | Conditions | Action |
|---|---|---|
| 10 | Header `X-ShipTrack-Target: legacy` **AND** header `X-ShipTrack-Test-Token: <token>` | Forward 100% → tg-legacy |
| 20 | Header `X-ShipTrack-Target: modern` **AND** header `X-ShipTrack-Test-Token: <token>` | Forward 100% → tg-modern |
| 90 | Path `/ui` or `/ui/*` **AND** method `GET` | Weighted forward per `var.cutover.track`, **group-level stickiness on** (`var.ui_stickiness_seconds`, default 3600) |
| 100 | Path `/api/v1/track/*` **AND** method `GET` | Weighted forward per `var.cutover.track` |
| default | — | Weighted forward per `var.cutover.default` |

```hcl
variable "cutover" {
  description = "ALB traffic weights. Changing this IS the cutover. Each change requires a PR."
  type = object({
    track   = object({ legacy = number, modern = number })
    default = object({ legacy = number, modern = number })
  })
  default = {
    track   = { legacy = 100, modern = 0 }
    default = { legacy = 100, modern = 0 }
  }
  # validation: each weight 0–999; legacy + modern > 0 for both maps
}
```

- Header rules let the team and CI validate a specific stack **before** it receives real traffic. A source-IP condition was rejected: GitHub-hosted runners have no stable egress IPs, so CI smoke tests would silently fall through to the weighted rules and test the wrong stack.
- **Test-routing token:** Terraform generates a 32-character alphanumeric `random_password` and stores it in Secrets Manager `shiptrack/dev/test-routing-token` (KMS `shiptrack-secrets`). The value necessarily appears in the listener-rule configuration and therefore in platform state. It is a low-sensitivity routing selector, not an auth credential (risk R-04). Rotate by replacing the `random_password` resource.
- **Fall-through detection:** both stacks return the response header `X-ShipTrack-Stack: legacy|modern`. The contract suite fails when it doesn't match `TARGET`, so a missing or wrong token is caught instead of silently testing the other stack.
- Group-level stickiness is **off** on the API rules: modern is stateless, and stickiness would skew canary statistics.
- Group-level stickiness is **on** for the UI rule (P90). A browser loads `index.html` and then the hashed JS/CSS assets in separate requests. Without stickiness, the HTML could come from one stack and the assets from the other; if the two builds differ, the assets 404 and the page breaks. Stickiness plus UI build parity (gate G6) prevents this.
- The UI rule and the track API rule share `var.cutover.track`, so the UI and its only API move together in Wave 1.
- Optional `enable_waf` (default `false`): AWS WAF web ACL with `AWSManagedRulesCommonRuleSet`, `AWSManagedRulesKnownBadInputsRuleSet`, and a rate-based rule.

### 6.7 Security services (`modules/security-services`)

- **CloudTrail:** multi-region trail, log-file validation, KMS (`shiptrack-logs`), management events. S3 data events only for the POD bucket, behind `enable_pod_data_events` (default `false`, cost).
- **GuardDuty:** detector with S3 Protection, EKS Audit Log Monitoring, RDS Protection, and Runtime Monitoring for EKS with automated agent management. Runtime Monitoring is billed per vCPU; it sits behind `enable_guardduty_runtime` (default `true`).
- **AWS Config:** recorder and delivery channel (CloudTrail bucket, `config/` prefix). This is required for Security Hub controls. Use `recording_mode` with **DAILY** frequency by default, and **CONTINUOUS** overrides for `AWS::IAM::*` and `AWS::EC2::SecurityGroup` (cost control).
- **Security Hub CSPM:** enable standards *AWS Foundational Security Best Practices* and *CIS AWS Foundations Benchmark v3.0* with the `aws_securityhub_*` resources (these manage CSPM). Context: in 2025 AWS renamed the original Security Hub to **Security Hub CSPM** and launched a new unified **Security Hub** (GA December 2025) that correlates CSPM, GuardDuty, and Inspector findings in OCSF format with consolidated pricing. The unified Security Hub is **out of scope**; everything here, including EventBridge routing, uses CSPM's ASFF findings. **[VERIFY the CIS v3.0 standard ARN in the chosen region.]**
- **Inspector:** enable EC2 (hybrid scanning) and ECR (enhanced, continuous; re-scan duration as a variable).
- **IAM Access Analyzer:** account analyzer (external access).
- **Findings routing:** EventBridge rule for Security Hub findings with severity `CRITICAL` or `HIGH` and workflow status `NEW` → SNS `shiptrack-alerts-sev2`.
- **`docs/security/findings-register.md`** template. All three repos use the same format:

| ID | Source | Resource | Severity | Owner (platform/legacy/modern) | Disposition (remediate / accepted-legacy-AP / false-positive / risk-accepted) | Ticket | Due |
|---|---|---|---|---|---|---|---|

### 6.8 Shared observability (`modules/observability`)

**Alert topics**
- `shiptrack-alerts-sev1` and `shiptrack-alerts-sev2`, encrypted with `shiptrack-logs`. **Gotcha:** CloudWatch alarms cannot publish to SNS topics encrypted with the AWS-managed key, so these must use the CMK.
- Email subscriptions from `var.alert_emails` (each recipient must confirm manually).

**Severity model**

| Severity | Definition | Response | Channel |
|---|---|---|---|
| SEV1 | Customer-facing outage or fast SLO burn | Immediate | `sev1` topic |
| SEV2 | Degradation, slow burn, security HIGH/CRITICAL, capacity risk | Same business day | `sev2` topic |

Every alarm sets `alarm_description` to a string containing **owner**, **severity**, and a **runbook URL**. Alarms have both alarm and OK actions. Count metrics use `treat_missing_data = "notBreaching"`.

**Platform-owned alarms**

| Alarm | Metric / condition | Sev |
|---|---|---|
| `tg-<x>-5xx-ratio` (per TG) | `HTTPCode_Target_5XX_Count / RequestCount > 2%`, 3 of 5 × 1-min periods (metric math) | SEV1 |
| `tg-<x>-p99-latency` (per TG) | `TargetResponseTime` p99 > 1 s, 5 of 5 min | SEV2 |
| `tg-<x>-unhealthy-hosts` (per TG) | `UnHealthyHostCount > 0` for 5 min | SEV2 |
| `alb-elb-5xx` | `HTTPCode_ELB_5XX_Count > 10`/min, 3 of 5 | SEV1 |
| `rds-cpu` | `CPUUtilization > 80%` 15 min | SEV2 |
| `rds-free-storage` | `FreeStorageSpace < 10 GiB` | SEV2 |
| `rds-connections` | `DatabaseConnections > 0.8 × db_max_connections` 5 min | SEV2 |
| `rds-freeable-memory` | `FreeableMemory < 256 MiB` 10 min | SEV2 |

**Dashboard `shiptrack-cutover`** (the primary go/no-go view during cutover):
- Row 1: per-TG RequestCount, side by side (legacy vs modern)
- Row 2: per-TG 5xx ratio, side by side
- Row 3: per-TG p50/p95/p99 TargetResponseTime
- Row 4: per-TG Healthy/UnHealthy host count
- Row 5: RDS connections, CPU, read/write latency
- Text widget: current `var.cutover` weights, rendered at apply time

### 6.9 SSM contract (`modules/contract`)

- All values are written as `aws_ssm_parameter`, Standard tier, under `/shiptrack/platform/`.
- **Secret values are never written to SSM** — only ARNs.
- Removing or renaming a key is a **breaking change** and requires an entry in `docs/ADR.md` plus coordinated PRs in the consuming repos.

| Key | Type | Value |
|---|---|---|
| `vpc_id` | String | |
| `vpc_cidr` | String | |
| `public_subnet_ids` | StringList | |
| `private_app_subnet_ids` | StringList | |
| `private_data_subnet_ids` | StringList | |
| `sg_alb_id` | String | |
| `sg_db_client_id` | String | |
| `alb_arn` | String | |
| `alb_dns_name` | String | |
| `listener_arn` | String | Traffic-serving listener |
| `tg_legacy_arn` | String | |
| `tg_modern_arn` | String | |
| `base_url` | String | `https://<domain>` or `http://<alb_dns>` |
| `rds_endpoint` | String | |
| `rds_port` | String | |
| `db_name` | String | `shiptrack` |
| `db_max_connections` | String | |
| `db_app_secret_arn` | String | |
| `db_migrator_secret_arn` | String | |
| `kms_data_key_arn` | String | |
| `kms_secrets_key_arn` | String | |
| `kms_logs_key_arn` | String | |
| `pod_bucket_name` | String | |
| `pod_bucket_arn` | String | |
| `sns_sev1_arn` | String | |
| `sns_sev2_arn` | String | |
| `permission_boundary_arn` | String | |
| `test_token_secret_arn` | String | Secrets Manager ARN of the test-routing token |
| `state_bucket_name` | String | |

### 6.10 Validation tooling (`validation/`)

These tools own the **shared definition of correct** for both stacks.

**`contract/`** (pytest + httpx)
- Implements every endpoint and behavior in `shiptrack-legacy/docs/DESIGN.md §3` (the canonical API spec). The test suite is the executable source of truth: if a test and the prose disagree, raise it as an issue.
- Environment variables:
  - `BASE_URL`
  - `TARGET` = `legacy | modern | none` (sets `X-ShipTrack-Target`)
  - `TEST_TOKEN` (sets `X-ShipTrack-Test-Token`; CI reads it from `test_token_secret_arn`)
  - `CARRIER_CODE` (default `ZZTEST`)
- Error codes: `QUEUE_UNAVAILABLE` (503, events endpoint) is accepted only when `X-ShipTrack-Stack: modern`; `INJECTED_FAULT` is always a failure.
- POD tests (upload, then read back) require `TARGET` ≠ `none`, so both calls hit one stack. Unpinned weighted traffic could upload to legacy and read through modern inside the PodSync window (legacy §8).
- Each test creates its own data with unique tracking numbers. Tests are safe to run against the live environment, with test data isolated under carrier `ZZTEST`.
- Follow redirects (modern answers POD downloads with 302 to a presigned URL). Strip `X-ShipTrack-*` headers on cross-origin redirects so the token is not sent to S3.
- When `TARGET` is not `none`, every ALB response must carry `X-ShipTrack-Stack` equal to `TARGET`; otherwise fail with a message that names routing fall-through as the cause.
- **UI checks** (marker `ui`, included in `smoke`):
  - `GET /ui/` returns 200 `text/html` containing `<div id="root">`, with `Cache-Control: no-cache`.
  - Every `/ui/assets/*` URL referenced by that HTML returns 200 from the **same** target, with `Cache-Control: public, max-age=31536000, immutable`.
  - Deep link `GET /ui/track/MF0000000000` returns the same HTML shell (SPA fallback), not 404.
- **UI build parity** (marker `ui_parity`; run only when both stacks are deployed): fetch `/ui/` with `TARGET=legacy` and with `TARGET=modern` and assert the referenced asset filenames are identical. This is cutover gate G6. Both stacks must build the UI with the exact Node version in `web/.nvmrc`.
- Markers:
  - `smoke`: fast post-deploy subset (creates at most one `ZZTEST` shipment)
  - `full`: everything
- JUnit XML output goes to `results/`.

**`simulator/`** (async Python, httpx)
- Creates N shipments across carriers, then emits each lifecycle (`PICKED_UP → IN_TRANSIT → OUT_FOR_DELIVERY → DELIVERED`) with realistic jitter.
- Injects 1% duplicate events (same `Idempotency-Key`), 2% out-of-order events, and 1% `EXCEPTION` paths.
- Uploads a small generated PNG/PDF POD on delivery. It never reads PODs back through weighted routing (see the POD-test rule under `contract/`); k6 does not either.
- Creates 5% of shipments with `promised_delivery_at` already in the past, to trigger the SLA scanner.
- **Ledger:** writes every accepted event's idempotency key to `results/sent-<ts>.jsonl`. `simulator verify --ledger … --db-url …` reports events accepted but never persisted. RDS is private, so `verify` runs on a host inside the VPC through an SSM document dispatched by a workflow (§6.4, *DB access from workflows*); the workflow first uploads the ledger and the simulator package to the artifact bucket. This is how legacy AP-06 (lost events) is proven.

**`loadtest/`** (k6)

| Scenario | Mix | Shape |
|---|---|---|
| `baseline` | 75% `GET /track`, 15% events, 5% create, 5% UI page load (`/ui/` + its assets) | constant-arrival-rate 20 rps, 30 min |
| `stress` | same | ramping-arrival-rate to 200 rps |
| `soak` | same | 20 rps, 2 h |

- Thresholds: `http_req_failed < 1%`, `http_req_duration p(95) < 500 ms`.
- Every request is tagged with `target`.
- Writes the summary JSON to `loadtest/results/<scenario>-<target>-<ts>.json`. These files are the before/after evidence.

**`.github/workflows/validation.yml`** (`workflow_dispatch`): inputs are `suite` (contract-smoke | contract-full | k6-baseline) and `target`. It runs on `dev` and uses `shiptrack-platform-plan` (its trust includes `ref:refs/heads/dev`) to read `base_url` and the test token. Legacy and modern workflows consume `validation/` by checking this repository out at a pinned commit SHA; the repository is public, so no token is needed.

### 6.11 CI/CD for this repo

- **`terraform-pr.yml`** (pull_request, paths `terraform/**`, `bootstrap/**`)
  1. `terraform fmt -check -recursive`
  2. `init` (plan role)
  3. `validate`
  4. `tflint`
  5. `checkov -d terraform` (fail on any non-skipped check; skips only via inline `#checkov:skip=CKV_…: <reason>`)
  6. `trivy config`
  7. `plan -out` (never uploaded as an artifact) with an address-and-action-only summary posted as a PR comment (§6.12); SARIF uploaded to code scanning

  `bootstrap/` gets the same lint and scan steps but is never planned here; it is planned and applied only by `bootstrap-apply.yml` (§6.1).
- **`terraform-apply.yml`** (push to `dev`): `environment: dev` (required reviewers), apply role, fresh `plan -out` then `apply` of that plan in the same job. `concurrency: { group: tf-platform-dev, cancel-in-progress: false }`.
- **`drift.yml`** (nightly cron): `plan -detailed-exitcode`. Exit code 2 opens or updates the GitHub issue "Drift detected: platform/dev". This is how break-glass weight changes get caught.
- All workflows: `permissions: { id-token: write, contents: read, pull-requests: write }` (minimum per job). No long-lived AWS keys exist anywhere.

### 6.12 Public repository rules

All three repositories are public.

- **No identifiers in output.** Committed files, workflow logs, PR comments, artifacts, and evidence must not contain account IDs, ARNs with account IDs, ALB DNS names, instance or host IDs, secret values, or the test-routing token. Use variables and data sources (§0.3). Keep `mask-aws-account-id` at its default (`true`) in `configure-aws-credentials` **[VERIFY]**. Run `::add-mask::` on any value fetched at run time (the token) before using it. Never `echo` variables or enable `set -x` in steps that hold credentials.
- **Plan output.** PR comments show only resource addresses and actions (from `terraform show -json`), never attribute values. Plan files are never uploaded as artifacts, because public artifacts are downloadable. Apply uses a fresh plan in the same job.
- **Repository settings.** Branch protection on `dev`; "Require approval for all outside collaborators" for workflows; default `GITHUB_TOKEN` permissions read-only; environments `bootstrap` and `dev` with required reviewers; secret scanning and push protection on. Fork PRs receive no OIDC token, so the plan roles are unreachable from forks.
- **Evidence and screenshots** committed under `docs/` are scrubbed with placeholders (`<ACCOUNT_ID>`, `<ALB_DNS>`) before merge. A CI check (gitleaks plus a custom rule for 12-digit account IDs and `*.elb.amazonaws.com`) fails the PR otherwise.
- The architecture, role names, and trust policies are public by design. No security control may depend on the design being secret.

---

## 7. Runbooks

**`docs/runbooks/cutover.md`** contains:
- The wave plan (summarized here; the detailed per-wave app behavior lives in the modern design §9)
- Exact PR diffs for each weight step
- The go/no-go gates below

| Gate | Criterion (measured on `shiptrack-cutover` dashboard over the soak window) |
|---|---|
| G1 Correctness | Contract suite passes against `TARGET=modern` |
| G2 Errors | tg-modern 5xx ratio ≤ tg-legacy 5xx ratio + 0.5 pp |
| G3 Latency | tg-modern p95 ≤ 1.2 × tg-legacy p95 |
| G4 Stability | No SEV1 alarm during soak; no pod restarts attributable to the release |
| G5 Async health (Wave 2+) | Events queue age < 60 s, DLQ = 0 |
| G6 UI build parity (before Wave 1) | `ui_parity` check passes: both stacks serve identical hashed UI asset filenames |
| Soak | 30 min per weight step |

Weight steps: Wave 1 `track` 10 → 50 → 100 (moves `/api/v1/track/*` and `/ui/*` together). Wave 2 `default` 10 → 25 → 50 → 100.

**`docs/runbooks/break-glass-rollback.md`**: use when an incident cannot wait for PR review.
1. Exact `aws elbv2 describe-rules` / `modify-rule` / `modify-listener` commands to force legacy = 100, modern = 0 for both the track rule and the default action, run by an authorized human with their **own admin role** (listed in `var.breakglass_principal_arns` and the README). Pipeline roles trust GitHub OIDC only and cannot be assumed by humans, by design.
2. Verification commands.
3. **Within 24 h**, open a PR setting `var.cutover` to match; `drift.yml` will flag the drift until this is done.
4. Incident record template.

---

## 8. Tagging and naming

- Provider `default_tags`: `Project=shiptrack`, `Stack=platform`, `Environment=dev`, `Owner=<var>`, `CostCenter=<var>`, `ManagedBy=terraform`, `Repo=shiptrack-platform`. Legacy and modern use the same keys with their own `Stack` value.
- **Early manual step (do this first):** activate `Project`, `Stack`, and `Environment` as **cost allocation tags** in the Billing console. Activation can take up to 24 h and is **not retroactive**. Without it, the before/after cost comparison has no data. Also enable **Split cost allocation data for Amazon EKS** in Cost Management preferences **[VERIFY location in console]**.
- Name pattern: `shiptrack-<stack>-<component>`. Platform resources may omit `<stack>` (for example `shiptrack-alb`).

---

## 9. Security requirements checklist

- [ ] No IAM users or access keys; all CI via GitHub OIDC with `sub` pinned to repo + event/environment
- [ ] Every app-created IAM role carries `shiptrack-workload-boundary`
- [ ] All data at rest encrypted with CMKs except where AWS requires otherwise (ALB logs: SSE-S3)
- [ ] All buckets: BPA, TLS-only policy, ownership enforced
- [ ] RDS: private, TLS enforced, master used only for bootstrap/break-glass, app uses DML-only role
- [ ] No secret values in code, state (write-only args), SSM, or CI logs
- [ ] CloudTrail, GuardDuty, Config, Security Hub CSPM, Inspector, and Access Analyzer enabled
- [ ] Checkov/Trivy gating in PRs; every skip has an inline justification
- [ ] Findings register maintained, with an owner for every CRITICAL/HIGH
- [ ] Repositories are public: no account IDs, ARNs, DNS names, or tokens in files, logs, comments, or artifacts (§6.12)
- [ ] Nothing is applied from a workstation; every apply is a workflow run with environment approval

---

## 10. Cost model and optimization hooks

| Driver | Control | Default | Note |
|---|---|---|---|
| NAT Gateway (hourly + per-GB) | `nat_gateway_mode` | single | per_az ≈ 3× hourly |
| Interface endpoints | `enable_interface_endpoints` | false | Per-endpoint per-AZ hourly; compare against NAT data processing (O-P1) |
| RDS | `db_instance_class`, `multi_az` | t4g.medium, false | Right-size from Database Insights (O-P2) |
| AWS Config | recording frequency | DAILY | Per configuration item recorded |
| GuardDuty Runtime | `enable_guardduty_runtime` | true | Per vCPU monitored |
| CloudWatch Logs | retention per group | 14 d | Ingestion is the big cost; retention controls storage (O-P3) |
| S3 POD | lifecycle + Bucket Keys | on | O-P4 |

**[VERIFY]** all prices in the AWS Pricing Calculator for the chosen region. Do not hardcode prices in code or docs. Cite the calculator export instead.

Platform optimization candidates for the final analysis: **O-P1** (NAT vs endpoints), **O-P2** (RDS right-size), **O-P3** (log retention/ingestion), **O-P4** (S3 lifecycle + Bucket Keys).

---

## 11. Risks and known gaps

| ID | Risk | Mitigation / acceptance |
|---|---|---|
| R-01 | No TLS without a custom domain | Set `domain_name`; otherwise accepted for this exercise and called out in the presentation |
| R-02 | Single account; no Control Tower / SCP guardrails | Permission boundary + deny statements; enterprise target documented |
| R-03 | Single NAT is a cross-AZ egress SPOF | `per_az` toggle; accepted for cost |
| R-04 | Test-routing token is in Terraform state and listener config | Low-sensitivity selector (reaches a stack that will take live traffic anyway); state encrypted and access-restricted; rotate on exposure |
| R-05 | Single-AZ RDS | `multi_az` toggle; RTO/RPO documented in README |
| R-06 | Break-glass changes cause Terraform drift | Nightly drift detection + 24 h reconcile rule |
| R-07 | Plan roles have broad read (`ReadOnlyAccess`) | Accepted; enterprise would scope via SCP/session policies |
| R-09 | The platform plan role can read the DB secrets and is assumable by any `pull_request` run in the repo, and the workflow file comes from the PR branch | The repos are public: fork PRs receive no OIDC token, and only collaborators can push branches; require approval for workflows from outside collaborators; branch protection and `CODEOWNERS` on `dev` and `.github/`. Enterprise: keep secret-bearing resources in a separate state, or plan from `dev` only. |
| R-10 | The seed role has `AdministratorAccess` and is created by hand | Trust pinned to one repo and the protected `bootstrap` environment (required reviewers); used only by `bootstrap-apply.yml`; narrowing or retirement tracked here |
| R-11 | Public repos disclose the architecture, and logs or evidence can leak identifiers | §6.12 rules, masking, and the scrub check; no security control depends on secrecy of the design |
| R-08 | Mixed UI builds across stacks during weighted routing | P90 group stickiness + gate G6 parity + UI source freeze until Wave 2 completes. Long-term fix: serve the UI from S3 + CloudFront (roadmap) |

---

## 12. Acceptance criteria

1. `bootstrap-apply.yml` applies cleanly in an account that has only the manually created OIDC provider and seed role, its state ends up in S3, and a second run is a no-op.
2. `terraform/envs/dev` plans with zero errors; `tflint`, `checkov`, and `trivy config` pass (or every skip is justified inline).
3. Every SSM contract key in §6.9 exists after apply.
4. RDS is reachable only from `shiptrack-db-client`; `bootstrap.sql` runs idempotently (second run is a no-op).
5. `curl -i -H 'X-ShipTrack-Target: legacy' -H "X-ShipTrack-Test-Token: $TOKEN" $BASE_URL/` returns `X-ShipTrack-Stack: legacy`; without the token the request falls through to the weighted rules.
6. Changing `var.cutover` via PR changes ALB weights with no other diff.
7. Security services are enabled, and a test HIGH finding reaches SNS sev2.
8. The `shiptrack-cutover` dashboard renders all rows; every alarm has owner, severity, and runbook in its description.
9. The contract suite, simulator ledger verification, and k6 baseline all run against legacy and produce result files.
10. The drift workflow detects a manual listener-rule change.
11. `/ui/` loads through the ALB for both targets, deep links survive a refresh, and the `ui_parity` check passes when both stacks run the same UI source.
12. The §6.12 scrub check passes on all three repositories.

---

## 13. Implementation phases

**Cross-repo build order** (all applies run through GitHub Actions; the agent never applies):

1. Legacy application, locally and in CI (legacy L1, L1b, and the build parts of L2).
2. Platform Foundation: P0, then **P6a** (`terraform-pr.yml` and `terraform-apply.yml`, built immediately after P0 because every later phase is applied through them), then P1, P2, P3, P5.
3. Legacy infrastructure (legacy L3, L4). Needs the Foundation applied.
4. Platform remainder: P4, **P6b** (`drift.yml`, `validation.yml`), P7, P8. The legacy assessment (legacy L5) needs all of platform.
5. Modern application (modern M0–M2), built locally with OrbStack and LocalStack and tested in CI.
6. Modern infrastructure and migration (modern M3–M10).

Phase numbers are otherwise unchanged, and each phase's "Done when" must pass before the next starts.

| Phase | Deliverables | Done when |
|---|---|---|
| **P0 Bootstrap** | `bootstrap/` (state bucket, state KMS key, boundary, 9 roles; OIDC provider read by data source), `bootstrap-apply.yml`, README with the manual seed steps (§6.1) and workflow procedure | `terraform validate` + `checkov` pass; `actionlint` passes; trust policies show exact `sub` strings in the README; after you run the workflow, the state is in S3 and a second run is a no-op |
| **P1 Network + KMS** | `modules/network`, `modules/kms`, `envs/dev` wiring, backend config | Plan clean; subnet tags match §6.2 |
| **P2 Database** | `modules/database`, secrets with write-only args, `db/bootstrap.sql`, `db/RUNBOOK-db-bootstrap.md` | SQL is idempotent (`psql` run twice against a local Postgres 17 container in a test script) |
| **P3 Storage + Ingress** | `modules/storage`, `modules/ingress` (TGs, rules, `cutover` var with validation) | Plan shows 4 listener rules (P10, P20, P90, P100) + weighted default action; changing weights alters only rules/default action |
| **P4 Security services** | `modules/security-services`, findings register template | Plan clean |
| **P5 Observability + Contract** | `modules/observability` (SNS, alarms, dashboard JSON), `modules/contract` | Every alarm description contains owner/sev/runbook; all §6.9 keys present |
| **P6 CI/CD** (P6a: `terraform-pr`, `terraform-apply`; P6b: `drift`, `validation`) | 3 Terraform workflows, the §6.12 scrub check, `.pre-commit-config.yaml`, `.tflint.hcl`, `.checkov.yaml` | `actionlint` passes; actions pinned to SHAs |
| **P7 Validation tooling** | `validation/contract`, `simulator`, `loadtest`, `validation.yml` | `pytest --collect-only` lists every endpoint in the legacy §3.4 table; `k6 inspect` passes |
| **P8 Runbooks** | `docs/runbooks/cutover.md`, `docs/runbooks/break-glass-rollback.md` | Commands are copy-pasteable with variables only |

---

## 14. Verify-at-build-time list

- [x] Write-only `secret_string_wo` + ephemeral `random_password` (confirmed: Terraform ≥ 1.11, AWS provider 6.x)
- [x] ALB access logs support SSE-S3 only (confirmed)
- [x] Security Hub CSPM naming; unified Security Hub GA December 2025 (confirmed; out of scope)
- [x] ALB console-default TLS policy `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09` (confirmed)
- [ ] AWS provider latest 6.x minor at build time
- [ ] RDS PostgreSQL 17 latest minor; Database Insights vs Performance Insights settings
- [ ] CIS v3.0 standard ARN in the chosen region
- [ ] ALB log-delivery bucket policy principal for the chosen region
- [ ] GitHub OIDC thumbprint requirement in the pinned provider
- [ ] EKS split cost allocation enablement path
- [ ] Current pricing for every §10 driver
- [ ] `mask-aws-account-id` default in `configure-aws-credentials`
- [ ] LocalStack edition and service coverage for the Terraform modules you test locally
