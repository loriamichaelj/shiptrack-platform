#!/usr/bin/env bash
# Plan or apply the bootstrap configuration. Run by .github/workflows/bootstrap-apply.yml.
# Usage: bootstrap/scripts/ci.sh plan|apply
#
# State lives in the bucket this configuration creates, so the first run is special:
#   1. create only the state bucket, with local state,
#   2. generate backend.tf and migrate the local state into the bucket,
#   3. plan and apply everything else (the key, its alias, the bucket's settings, IAM) with
#      remote state.
# Keeping step 1 to one resource makes the window in which state could be lost as small as
# possible: a failure after step 2 leaves recoverable remote state instead of a lost local file
# on an ephemeral runner.
#
# Output is limited to resource addresses and actions: the repository is public, so plan
# attribute values are never printed or uploaded.
#
# Environment:
#   AWS_REGION          region of the state bucket (required)
#   TF_VAR_github_org   GitHub organization or user (required)
#   TF_BACKEND_EXTRA    extra lines for the backend block; used only by tests against moto
set -euo pipefail

mode=${1:?usage: ci.sh plan|apply}
[[ "$mode" == plan || "$mode" == apply ]] || { echo "unknown mode: $mode" >&2; exit 2; }
: "${AWS_REGION:?AWS_REGION is required}"
: "${TF_VAR_github_org:?TF_VAR_github_org is required}"
export TF_IN_AUTOMATION=1 TF_INPUT=0

cd "$(dirname "${BASH_SOURCE[0]}")/.."

account=$(aws sts get-caller-identity --query Account --output text)
echo "::add-mask::$account"
bucket="shiptrack-tfstate-${account}-${AWS_REGION}"
state_key="bootstrap/terraform.tfstate"

log() { printf '%s\n' "$*"; }

# Prints "exists" or "missing"; fails on anything else (for example access denied).
bucket_state() {
  local output
  if output=$(aws s3api head-bucket --bucket "$bucket" 2>&1); then
    echo exists
  elif grep -qE '404|Not Found|NoSuchBucket' <<<"$output"; then
    echo missing
  else
    echo "head-bucket failed: ${output//$account/***}" >&2
    return 1
  fi
}

write_backend() {
  cat >backend.tf <<BACKEND
terraform {
  backend "s3" {
    bucket       = "${bucket}"
    key          = "${state_key}"
    region       = "${AWS_REGION}"
    use_lockfile = true
${TF_BACKEND_EXTRA:-}
  }
}
BACKEND
}

# Run a terraform command quietly; show its output only if it fails.
quietly() {
  local out
  out=$(mktemp)
  if ! "$@" >"$out" 2>&1; then
    sed "s/${account}/***/g" "$out" >&2
    rm -f "$out"
    return 1
  fi
  rm -f "$out"
}

# Print the changes in a saved plan: addresses and actions, never values.
summarize() {
  local plan=$1 text
  text=$(terraform show -json "$plan" | jq -r '
    [.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])] as $changes
    | (if ($changes | length) == 0 then "No changes."
       else ($changes | map("- `\(.change.actions | join("+"))` \(.address)") | join("\n")) end)
      + "\n\n\($changes | length) resource change(s).\n"')
  log "$text"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '## Bootstrap %s\n\n%s\n' "$mode" "$text" >>"$GITHUB_STEP_SUMMARY"
  fi
}

plan_to() {
  local plan=$1
  shift
  quietly terraform plan -input=false -lock-timeout=120s -out="$plan" "$@"
}

state=$(bucket_state)
log "state bucket: $state"
[[ "$state" == exists ]] && write_backend
quietly terraform init -input=false

if [[ "$mode" == plan ]]; then
  if [[ "$state" == missing ]]; then
    log "First run: the state bucket does not exist yet. Planning the bucket only."
    plan_to tfplan -target=module.state.aws_s3_bucket.state
  else
    plan_to tfplan
  fi
  summarize tfplan
  exit 0
fi

if [[ "$state" == missing ]]; then
  log "First run: creating the state bucket with local state."
  plan_to seed.tfplan -target=module.state.aws_s3_bucket.state
  summarize seed.tfplan
  quietly terraform apply -input=false seed.tfplan
  write_backend
  log "Migrating state into the bucket."
  quietly terraform init -migrate-state -force-copy -input=false
  aws s3api head-object --bucket "$bucket" --key "$state_key" >/dev/null
  log "State is now stored remotely."
fi

plan_to tfplan
summarize tfplan
quietly terraform apply -input=false tfplan
log "Apply complete."
