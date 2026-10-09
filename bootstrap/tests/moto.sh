#!/usr/bin/env bash
# Exercise bootstrap/scripts/ci.sh against a local moto server (a stand-in for AWS: no
# credentials, nothing real is created). Verifies the first-run seeding and state migration, that
# a second run is a no-op, the exact trust-policy `sub` strings, and IAM policy size limits.
# Usage: bootstrap/tests/moto.sh
# shellcheck disable=SC2015  # `cond && pass || fail` is safe: pass and fail never return non-zero
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
port=${MOTO_PORT:-5555}
org=testorg
work=$(mktemp -d)
moto_pid=""
failures=0

cleanup() {
  if [[ -n "$moto_pid" ]]; then kill "$moto_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected [$3] got [$2]"; fi; }
section() { printf '\n== %s\n' "$1"; }

# --- start moto -------------------------------------------------------------------------------
MOTO_IAM_LOAD_MANAGED_POLICIES=true uvx --quiet --from 'moto[server]' moto_server -H 127.0.0.1 -p "$port" >"$work/moto.log" 2>&1 &
moto_pid=$!
for _ in $(seq 1 60); do
  curl -s "http://127.0.0.1:$port/moto-api/" >/dev/null 2>&1 && break
  sleep 1
done
curl -s "http://127.0.0.1:$port/moto-api/" >/dev/null || { echo "moto did not start"; cat "$work/moto.log"; exit 1; }

export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
export AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1
# S3 Control calls go to <account-id>.<endpoint host>, so the host must be a name, not an IP.
export AWS_ENDPOINT_URL="http://localhost:$port"
export AWS_S3_USE_PATH_STYLE=true
export TF_VAR_github_org=$org
# Numeric IDs differ from each other so a mix-up between repositories is caught.
export TF_VAR_github_owner_id=1000
export TF_VAR_repository_ids='{"platform":"11","legacy":"22","modern":"33"}'
# A prefix unlike the real one: the roles must follow the variable, not a hardcoded name.
rp=testowner-dev-shiptrack
export TF_VAR_role_prefix=$rp
export TF_VAR_seed_role_name=testowner-bootstrap-shiptrack-seed
export TF_BACKEND_EXTRA='    use_path_style              = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    endpoints = { s3 = "'"$AWS_ENDPOINT_URL"'" }'
unset AWS_PROFILE

# The OIDC provider is created by hand in a real account; do the same here.
aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com --thumbprint-list 0000000000000000000000000000000000000000 >/dev/null

# Run from a copy so the repository's bootstrap/ stays free of .terraform and state.
mkdir -p "$work/bootstrap"
tar -C "$here" --exclude=.terraform --exclude=backend.tf --exclude='*.tfstate*' --exclude='*tfplan' \
  -cf - . | tar -C "$work/bootstrap" -xf -
# moto serves plain HTTP and enforces the bucket's TLS-only policy against it, which would lock the
# test out of its own state. Leave that one resource out of the copy; its content is checked below.
cat >"$work/bootstrap/state/override.tf" <<'OVERRIDE'
resource "aws_s3_bucket_policy" "state" {
  count = 0
}
OVERRIDE
ci="$work/bootstrap/scripts/ci.sh"
account=$(aws sts get-caller-identity --query Account --output text)
bucket="shiptrack-tfstate-${account}-${AWS_REGION}"

section "first run"
out=$("$ci" plan 2>&1) || { echo "$out"; fail "plan on a fresh account"; }
grep -q "state bucket: missing" <<<"$out" && pass "plan detects the missing state bucket" || fail "plan detects the missing state bucket"
grep -q "module.state.aws_s3_bucket.state\b" <<<"$out" && pass "plan lists the bucket" || fail "plan lists the bucket"
if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then fail "plan must not create the bucket"; else pass "plan creates nothing"; fi

out=$("$ci" apply 2>&1) || { echo "$out"; fail "first apply"; }
grep -q "State is now stored remotely" <<<"$out" && pass "state was migrated into the bucket" || fail "state was migrated into the bucket"
grep -q "Apply complete" <<<"$out" && pass "apply completed" || fail "apply completed"
aws s3api head-object --bucket "$bucket" --key bootstrap/terraform.tfstate >/dev/null 2>&1 && pass "state object exists in the bucket" || fail "state object exists in the bucket"
test -f "$work/bootstrap/backend.tf" && pass "backend.tf was generated" || fail "backend.tf was generated"
grep -qE 'skip_credentials_validation|use_path_style' "$work/bootstrap/backend.tf" && pass "test backend options are applied" || fail "test backend options are applied"
if grep -q "AKIA\|password" <<<"$out"; then fail "output contains no secrets"; else pass "output contains no secrets"; fi

section "second run is a no-op"
out=$("$ci" apply 2>&1) || { echo "$out"; fail "second apply"; }
grep -q "state bucket: exists" <<<"$out" && pass "second run finds the bucket" || fail "second run finds the bucket"
grep -q "No changes" <<<"$out" && pass "second apply has no changes" || { fail "second apply has no changes"; echo "$out" | tail -n 12; }
out=$("$ci" plan 2>&1)
grep -q "No changes" <<<"$out" && pass "plan has no changes" || fail "plan has no changes"

section "state bucket"
eq "versioning is enabled" "$(aws s3api get-bucket-versioning --bucket "$bucket" --query Status --output text)" "Enabled"
eq "default encryption is KMS" "$(aws s3api get-bucket-encryption --bucket "$bucket" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text)" "aws:kms"
eq "all four public access blocks are on" "$(aws s3api get-public-access-block --bucket "$bucket" --query 'PublicAccessBlockConfiguration' --output json | jq -c '[.BlockPublicAcls,.BlockPublicPolicy,.IgnorePublicAcls,.RestrictPublicBuckets]')" "[true,true,true,true]"
eq "ownership is BucketOwnerEnforced" "$(aws s3api get-bucket-ownership-controls --bucket "$bucket" --query 'OwnershipControls.Rules[0].ObjectOwnership' --output text)" "BucketOwnerEnforced"
eq "noncurrent versions expire after 90 days" "$(aws s3api get-bucket-lifecycle-configuration --bucket "$bucket" --query 'Rules[0].NoncurrentVersionExpiration.NoncurrentDays' --output text)" "90"
eq "the key alias exists" "$(aws kms list-aliases --query "Aliases[?AliasName=='alias/shiptrack-tfstate'].AliasName" --output text)" "alias/shiptrack-tfstate"

section "trust policies (exact sub claims)"
sub_of() { aws iam get-role --role-name "$1" --query 'Role.AssumeRolePolicyDocument' --output json | jq -r '.Statement[0].Condition.StringEquals."token.actions.githubusercontent.com:sub" | if type=="array" then join(" | ") else . end'; }
r="repo:$org@1000"
eq "platform-plan"  "$(sub_of $rp-platform-plan)"  "$r/shiptrack-platform@11:pull_request | $r/shiptrack-platform@11:ref:refs/heads/dev"
eq "platform-apply" "$(sub_of $rp-platform-apply)" "$r/shiptrack-platform@11:environment:dev"
eq "legacy-plan"    "$(sub_of $rp-legacy-plan)"    "$r/shiptrack-legacy@22:pull_request | $r/shiptrack-legacy@22:ref:refs/heads/dev"
eq "legacy-apply"   "$(sub_of $rp-legacy-apply)"   "$r/shiptrack-legacy@22:environment:dev"
eq "legacy-deploy"  "$(sub_of $rp-legacy-deploy)"  "$r/shiptrack-legacy@22:environment:dev"
eq "modern-plan"    "$(sub_of $rp-modern-plan)"    "$r/shiptrack-modern@33:pull_request | $r/shiptrack-modern@33:ref:refs/heads/dev"
eq "modern-apply"   "$(sub_of $rp-modern-apply)"   "$r/shiptrack-modern@33:environment:dev"
eq "modern-release" "$(sub_of $rp-modern-release)" "$r/shiptrack-modern@33:ref:refs/heads/dev"
eq "modern-deploy"  "$(sub_of $rp-modern-deploy)"  "$r/shiptrack-modern@33:environment:dev"
eq "audience is sts.amazonaws.com" "$(aws iam get-role --role-name $rp-legacy-deploy --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals."token.actions.githubusercontent.com:aud"' --output text)" "sts.amazonaws.com"
eq "exactly nine deploy roles" "$(aws iam list-roles --query "Roles[?starts_with(RoleName,'$rp-')].RoleName" --output json | jq length)" "9"

section "managed policies"
attached() { aws iam list-attached-role-policies --role-name "$1" --query 'AttachedPolicies[].PolicyName' --output json | jq -r 'sort | join(",")'; }
eq "platform-apply" "$(attached $rp-platform-apply)" "PowerUserAccess,ReadOnlyAccess"
eq "platform-plan" "$(attached $rp-platform-plan)" "ReadOnlyAccess"
eq "legacy-deploy has none" "$(attached $rp-legacy-deploy)" ""
eq "modern-release has none" "$(attached $rp-modern-release)" ""

section "policy size limits"
nonws() { jq -c . | tr -d ' \n' | wc -c | tr -d ' '; }
for role in "$rp"-{platform-plan,platform-apply,legacy-plan,legacy-apply,legacy-deploy,modern-plan,modern-apply,modern-release,modern-deploy}; do
  size=$(aws iam get-role-policy --role-name "$role" --policy-name "$role-permissions" --query PolicyDocument --output json | nonws)
  trust=$(aws iam get-role --role-name "$role" --query Role.AssumeRolePolicyDocument --output json | nonws)
  [[ $size -le 10240 ]] && pass "$role inline policy $size/10240" || fail "$role inline policy is $size characters (limit 10240)"
  [[ $trust -le 2048 ]] && pass "$role trust policy $trust/2048" || fail "$role trust policy is $trust characters (limit 2048)"
done
arn=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$rp-workload-boundary'].Arn" --output text)
version=$(aws iam get-policy --policy-arn "$arn" --query Policy.DefaultVersionId --output text)
bsize=$(aws iam get-policy-version --policy-arn "$arn" --version-id "$version" --query PolicyVersion.Document --output json | nonws)
[[ $bsize -le 6144 ]] && pass "boundary policy $bsize/6144" || fail "boundary policy is $bsize characters (limit 6144)"

section "boundary content"
doc=$(aws iam get-policy-version --policy-arn "$arn" --version-id "$version" --query PolicyVersion.Document --output json)
eq "allows 26 service namespaces" "$(jq '[.Statement[] | select(.Sid=="AllowedServices") | .Action[]] | length' <<<"$doc")" "26"
eq "denies iam:CreateAccessKey" "$(jq -r '[.Statement[] | select(.Effect=="Deny") | .Action | (if type=="array" then . else [.] end)[]] | map(select(.=="iam:CreateAccessKey")) | length' <<<"$doc")" "1"
eq "denies organizations" "$(jq -r '[.Statement[] | select(.Effect=="Deny" and .Sid=="DenyOrganizations") | .Action] | length' <<<"$doc")" "1"

section "TLS-only bucket policy (checked from a plan of the unmodified configuration)"
mkdir -p "$work/plain"
tar -C "$here" --exclude=.terraform --exclude=backend.tf --exclude='*.tfstate*' --exclude='*tfplan' -cf - . | tar -C "$work/plain" -xf -
cp "$work/bootstrap/backend.tf" "$work/plain/backend.tf"
(cd "$work/plain" && terraform init -input=false >/dev/null 2>&1 && terraform plan -input=false -out=tls.tfplan >/dev/null 2>&1) || fail "plan of the unmodified configuration"
policy=$(cd "$work/plain" && terraform show -json tls.tfplan | jq -r '.resource_changes[] | select(.address=="module.state.aws_s3_bucket_policy.state") | .change.after.policy')
eq "effect is Deny" "$(jq -r '.Statement[0].Effect' <<<"$policy")" "Deny"
eq "condition is aws:SecureTransport = false" "$(jq -r '.Statement[0].Condition.Bool."aws:SecureTransport"' <<<"$policy")" "false"
eq "covers the bucket and its objects" "$(jq -r '.Statement[0].Resource | length' <<<"$policy")" "2"

printf '\n'
if [[ $failures -eq 0 ]]; then echo "ALL BOOTSTRAP CHECKS PASSED"; else echo "$failures BOOTSTRAP CHECK(S) FAILED"; exit 1; fi
