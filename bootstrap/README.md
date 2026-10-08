# bootstrap

Creates what every other pipeline needs before it can run: the Terraform state bucket and its key,
the `shiptrack-workload-boundary` permission boundary, and the nine GitHub OIDC deploy roles.

It is applied **only** by `.github/workflows/bootstrap-apply.yml`, using a seed role that you create
by hand once. Nothing is applied from a workstation. See `docs/DESIGN.md` §6.1 for the design.

## One-time setup

Replace `<ORG>` with your GitHub user or organization. Account IDs stay out of this repository, so
the examples read the account from your own AWS session.

### 1. OIDC provider and seed role (AWS, by hand)

An account can hold one OIDC provider per URL, so Terraform reads this one rather than creating it.

```sh
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
cat >/tmp/seed-trust.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:<ORG>/shiptrack-platform:environment:bootstrap"
      }
    }
  }]
}
JSON
aws iam create-role --role-name shiptrack-bootstrap \
  --assume-role-policy-document file:///tmp/seed-trust.json
aws iam attach-role-policy --role-name shiptrack-bootstrap \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
rm /tmp/seed-trust.json
```

The seed role is trusted only for jobs that run in the protected `bootstrap` environment of this
repository. It holds `AdministratorAccess` because bootstrap creates IAM roles, the boundary, and
KMS keys (risk R-10). Terraform does not manage it, so the pipeline cannot modify its own
foundation. Narrow or delete it once the nine roles exist and you no longer need to change bootstrap.

### 2. Repository settings (GitHub)

For each of the three repositories, run the setup script. Use `--dry-run` first to see the calls.

```sh
bootstrap/scripts/github-setup.sh --dry-run --bootstrap-env <ORG>/shiptrack-platform
bootstrap/scripts/github-setup.sh --bootstrap-env <ORG>/shiptrack-platform
bootstrap/scripts/github-setup.sh <ORG>/shiptrack-legacy
bootstrap/scripts/github-setup.sh <ORG>/shiptrack-modern
```

It creates the `dev` environment (and `bootstrap` on this repository) with you as the required
reviewer and `dev` as the only branch allowed to deploy, protects the `dev` branch so changes
arrive by pull request, makes the default workflow token read-only, requires approval for every
outside contributor's workflow, and turns on secret scanning and push protection. Add
`--check <job name>` once a repository has CI jobs to require them before merging.

An environment job's OIDC `sub` claim carries no branch, so the deployment-branch rule is what keeps
a workflow on another branch from requesting an apply role.

### 3. Seed role ARN and region (GitHub)

The ARN contains your account ID, so it is stored as a secret (GitHub masks secrets in logs).

```sh
gh secret set AWS_BOOTSTRAP_ROLE_ARN -R <ORG>/shiptrack-platform \
  --body "$(aws iam get-role --role-name shiptrack-bootstrap --query Role.Arn --output text)"
gh variable set AWS_REGION -R <ORG>/shiptrack-platform --body us-east-1
```

### 4. Merge this to `dev`

The `bootstrap` environment only accepts deployments from `dev`, so the workflow can run only after
this code is on `dev`.

## Running it

1. Actions, then **bootstrap-apply**, then **Run workflow** on `dev`.
2. Approve the **plan** job. Its summary lists each resource and action, never values.
3. If the plan is what you expect, approve the **apply** job.

The first run creates the state bucket with local state, then moves state into the bucket before
creating anything else. Later runs use the bucket directly, and a run with no changes ends with
"No changes".

## Wiring the other repositories

After the first apply, give each repository the ARNs of its roles. They are stored as secrets
because they contain the account ID. The `$(...)` keeps them out of your terminal and logs.

```sh
set_role() { # set_role <repo> <secret> <role>
  gh secret set "$2" -R "<ORG>/$1" \
    --body "$(aws iam get-role --role-name "$3" --query Role.Arn --output text)"
}
set_role shiptrack-platform AWS_PLAN_ROLE_ARN   shiptrack-platform-plan
set_role shiptrack-platform AWS_APPLY_ROLE_ARN  shiptrack-platform-apply
set_role shiptrack-legacy   AWS_PLAN_ROLE_ARN   shiptrack-legacy-plan
set_role shiptrack-legacy   AWS_APPLY_ROLE_ARN  shiptrack-legacy-apply
set_role shiptrack-legacy   AWS_DEPLOY_ROLE_ARN shiptrack-legacy-deploy
set_role shiptrack-modern   AWS_PLAN_ROLE_ARN    shiptrack-modern-plan
set_role shiptrack-modern   AWS_APPLY_ROLE_ARN   shiptrack-modern-apply
set_role shiptrack-modern   AWS_RELEASE_ROLE_ARN shiptrack-modern-release
set_role shiptrack-modern   AWS_DEPLOY_ROLE_ARN  shiptrack-modern-deploy
for repo in shiptrack-platform shiptrack-legacy shiptrack-modern; do
  gh variable set AWS_REGION -R "<ORG>/$repo" --body us-east-1
done
```

## Trust policies

Every role trusts the GitHub OIDC provider with `aud = sts.amazonaws.com` and a `sub` claim from
this table. `bootstrap/tests/moto.sh` checks these exact strings.

| Role | `sub` claims |
|---|---|
| `shiptrack-platform-plan` | `repo:<ORG>/shiptrack-platform:pull_request`, `repo:<ORG>/shiptrack-platform:ref:refs/heads/dev` |
| `shiptrack-platform-apply` | `repo:<ORG>/shiptrack-platform:environment:dev` |
| `shiptrack-legacy-plan` | `repo:<ORG>/shiptrack-legacy:pull_request`, `repo:<ORG>/shiptrack-legacy:ref:refs/heads/dev` |
| `shiptrack-legacy-apply` | `repo:<ORG>/shiptrack-legacy:environment:dev` |
| `shiptrack-legacy-deploy` | `repo:<ORG>/shiptrack-legacy:environment:dev` |
| `shiptrack-modern-plan` | `repo:<ORG>/shiptrack-modern:pull_request`, `repo:<ORG>/shiptrack-modern:ref:refs/heads/dev` |
| `shiptrack-modern-apply` | `repo:<ORG>/shiptrack-modern:environment:dev` |
| `shiptrack-modern-release` | `repo:<ORG>/shiptrack-modern:ref:refs/heads/dev` |
| `shiptrack-modern-deploy` | `repo:<ORG>/shiptrack-modern:environment:dev` |

## State layout

Bucket `shiptrack-tfstate-<account-id>-<region>`, encrypted with `alias/shiptrack-tfstate`, locked
with S3 native lock files (`use_lockfile`; no DynamoDB).

| Key | Owner |
|---|---|
| `bootstrap/terraform.tfstate` | bootstrap |
| `platform/dev.tfstate` | platform |
| `legacy/dev.tfstate` | legacy |
| `modern/cluster/dev.tfstate` | modern, cluster root |
| `modern/addons/dev.tfstate` | modern, addons root |

## Recovery

- **A failure after "State is now stored remotely"**: re-run the workflow. State is in the bucket, so
  it picks up where it stopped.
- **The run failed while creating the bucket**: nothing is stored yet. If the bucket exists, import it
  from a workstation with credentials, or delete the empty bucket and re-run:
  `terraform import module.state.aws_s3_bucket.state <bucket-name>` (then re-run the workflow).
- **A stuck lock** (`bootstrap/terraform.tfstate.tflock` left behind by a cancelled run): delete that
  one object from the bucket after confirming no run is in progress.
- **A role needs a new permission**: change `bootstrap/policies/` and re-run the workflow. A missing
  permission appears as `AccessDenied` in the failing pipeline, and the fix always lands here.

## Local verification

No AWS credentials are needed. `bootstrap/tests/moto.sh` starts a local `moto` server and runs the
real `ci.sh` against it: first-run seeding and state migration, a no-op second run, the exact trust
policies, and the IAM policy size limits.

```sh
bootstrap/tests/moto.sh
terraform -chdir=bootstrap init -backend=false && terraform -chdir=bootstrap validate
```
