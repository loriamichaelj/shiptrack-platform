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

**Consequences:** A renamed or transferred repository keeps its trust only if its IDs are unchanged, and a deleted and recreated repository does not inherit it. The documented subject forms cover branch refs; the `environment` and `pull_request` suffixes follow the same pattern but are not shown in GitHub's documentation, so the first real run confirms them **[VERIFY]**.

## ADR-0013: terraform-workflow-structure

**Status:** Accepted

**Context:** §6.11 lists the pull-request checks in one sequence that starts with `init` under the plan role. The state bucket name contains the account ID, so the backend cannot be committed, and fork pull requests receive no OIDC token.

**Decision:** `terraform-pr.yml` has two jobs. `lint` (format, `validate` with `init -backend=false`, TFLint, Checkov, Trivy) needs no AWS access and runs for forks. `plan` runs only for same-repository pull requests, after `lint`, under the plan role. Both `plan` and `terraform-apply.yml` run `scripts/terraform-ci.sh`, which looks up the account, derives the bucket name `shiptrack-tfstate-<account>-<region>` as bootstrap does, and passes the backend settings to `init`, so `terraform/envs/dev/backend.tf` holds only an empty `backend "s3" {}` block. Trivy runs twice over the repository: once for the SARIF report sent to code scanning, once as the gate. Checkov is installed with `pipx` at a pinned version because it has no action to pin to a SHA.

**Consequences:** Lint runs on every Terraform pull request without credentials. The apply workflow's path filter is `terraform/**` only, so edits to the workflow or the script are exercised by the plan job on the pull request rather than by an approval-gated apply. `terraform-apply.yml` fails if `terraform/envs/dev` does not exist when `terraform/**` changes, which P1 prevents by adding both together.
