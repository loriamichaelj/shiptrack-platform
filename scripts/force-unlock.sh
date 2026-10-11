#!/usr/bin/env bash
# Remove a stale Terraform state lock on terraform/envs/dev. Run by .github/workflows/ops-unlock-state.yml.
# Usage: scripts/force-unlock.sh <lock-id>
#
# A cancelled or killed run can leave its lock behind, and then every plan and apply fails on it.
# This refuses to remove a lock unless the object in the state bucket carries exactly the ID given
# and is older than MIN_LOCK_AGE_MINUTES, so it cannot take a lock from a run that is still working.
# Nothing in the output names the account.
#
# Environment:
#   AWS_REGION             region of the state bucket (required)
#   TF_DIR                 configuration directory (default: terraform/envs/dev)
#   TF_STATE_KEY           state object key (default: platform/dev/terraform.tfstate)
#   MIN_LOCK_AGE_MINUTES   the youngest lock that may be removed (default: 30)
set -euo pipefail

lock_id=${1:?usage: force-unlock.sh <lock-id>}
if [[ ! "$lock_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  echo "::error::The lock ID is not a UUID."
  exit 2
fi
: "${AWS_REGION:?AWS_REGION is required}"
min_age_minutes=${MIN_LOCK_AGE_MINUTES:-30}
export TF_IN_AUTOMATION=1 TF_INPUT=0

dir=${TF_DIR:-terraform/envs/dev}
state_key=${TF_STATE_KEY:-platform/dev/terraform.tfstate}
if [[ "$dir" != /* ]]; then
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
fi
cd "$dir"

account=$(aws sts get-caller-identity --query Account --output text)
echo "::add-mask::$account"
bucket="shiptrack-tfstate-${account}-${AWS_REGION}"
lock_key="${state_key}.tflock"

lock=$(mktemp)
trap 'rm -f "$lock"' EXIT
if ! aws s3api get-object --bucket "$bucket" --key "$lock_key" "$lock" >/dev/null 2>&1; then
  echo "There is no lock object for ${state_key}; nothing to remove."
  exit 0
fi

held=$(jq -r '.ID // ""' "$lock")
operation=$(jq -r '.Operation // "unknown"' "$lock")
created=$(jq -r '.Created // ""' "$lock")
if [[ "$held" != "$lock_id" ]]; then
  echo "::error::The state is locked under ID ${held:-<none>}, not the ID given. Nothing was removed."
  exit 1
fi

created_epoch=$(jq -r '.Created | sub("\\.[0-9]+"; "") | fromdateiso8601' "$lock")
age_minutes=$(( ($(date -u +%s) - created_epoch) / 60 ))
if (( age_minutes < min_age_minutes )); then
  echo "::error::The lock is ${age_minutes} minutes old; the minimum is ${min_age_minutes}. A run may still hold it."
  exit 1
fi

echo "Removing the ${operation} lock created ${created} (${age_minutes} minutes old)."
terraform init -input=false \
  -backend-config="bucket=${bucket}" \
  -backend-config="key=${state_key}" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="use_lockfile=true" >/dev/null
terraform force-unlock -force "$lock_id"
echo "Unlocked."
