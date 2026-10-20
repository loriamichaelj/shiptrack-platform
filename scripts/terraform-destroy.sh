#!/usr/bin/env bash
# Take down the platform root (ADR-0038). Run by destroy-all.yml as <PREFIX>-platform-apply, in the dev
# environment, in two jobs that each need an approval.
# Usage: scripts/terraform-destroy.sh plan|destroy <name>
#
# plan     shows the addresses and actions a destroy of the whole root would make.
# destroy  makes a fresh plan and applies that plan in the same run; no plan file leaves the runner.
#
# Both modes fail unless the CONFIRM environment variable equals <name>, and unless the legacy and modern
# stacks are gone: their parameters under /shiptrack/legacy and /shiptrack/modern are what the guard
# looks for, and the stacks use this root's keys, network, and target groups. As in terraform-ci.sh, only
# addresses and actions are printed, and a failure prints Terraform's output with identifiers masked.
#
# A protected resource (the database, the load balancer, a versioned bucket, a secret that would keep its
# name for 30 days) cannot be destroyed as it is, and the provider reads the stored value when it deletes.
# When UNPROTECT_VARS lists assignments, `destroy` first applies the addresses in UNPROTECT_TARGETS with
# those variables set, then destroys with them still set. The next normal apply sets the protection back
# for anything that remains.
#
# Environment:
#   CONFIRM            the value the person typed; must equal <name> (required)
#   AWS_REGION         region of the state bucket (required)
#   TF_STATE_KEY       state object key (default: platform/dev/terraform.tfstate)
#   UNPROTECT_VARS     optional; variable assignments, separated by spaces, such as deletion_protection=false
#   UNPROTECT_TARGETS  addresses, separated by spaces, that the unprotecting step applies (required with UNPROTECT_VARS)
#   DESTROY_ATTEMPTS   how many times `destroy` plans and applies again after a failure (default 1). The
#                      network interfaces of a deleted load balancer or database can outlive it by minutes
#   RETRY_WAIT_SECONDS wait between attempts (default 300)
#   TF_VAR_*           input variables
set -euo pipefail

mode=${1:?usage: terraform-destroy.sh plan|destroy <name>}
name=${2:?usage: terraform-destroy.sh plan|destroy <name>}
[[ "$mode" == plan || "$mode" == destroy ]] || { echo "unknown mode: $mode" >&2; exit 2; }
: "${AWS_REGION:?AWS_REGION is required}"

if [[ "${CONFIRM:-}" != "$name" ]]; then
  echo "::error::The confirmation does not match. Type ${name} to take it down."
  exit 1
fi
export TF_IN_AUTOMATION=1 TF_INPUT=0

state_key=${TF_STATE_KEY:-platform/dev/terraform.tfstate}
cd "$(dirname "${BASH_SOURCE[0]}")/../terraform/envs/dev"

account=$(aws sts get-caller-identity --query Account --output text)
echo "::add-mask::$account"
bucket="shiptrack-tfstate-${account}-${AWS_REGION}"

log() { printf '%s\n' "$*"; }

# The legacy and modern stacks publish parameters under their own paths and remove them when they go.
for stack in legacy modern; do
  left=$(aws ssm get-parameters-by-path --path "/shiptrack/${stack}" --recursive --query 'length(Parameters)' --output text)
  if [[ "$left" != 0 ]]; then
    echo "::error::The ${stack} stack still has ${left} parameter(s) under /shiptrack/${stack}. Run its destroy-all first."
    exit 1
  fi
done
log "The legacy and modern stacks are gone."

# Run a terraform command quietly; show its output only if it fails, with identifiers masked.
quietly() {
  local out
  out=$(mktemp)
  if ! "$@" >"$out" 2>&1; then
    sed -E "s/${account}/***/g; s/\[id=[^]]*\]/[id=***]/g; s/(vpc|subnet|sg|rtb|igw|eipalloc|nat|vpce|eni|acl|rtbassoc)-[0-9a-f]{8,17}/\1-***/g" "$out" >&2
    rm -f "$out"
    return 1
  fi
  rm -f "$out"
}

# summarize <plan> <step>: the addresses and actions of a saved plan, never values.
summarize() {
  local text
  text=$(terraform show -json "$1" | jq -r '
    [.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])] as $changes
    | (if ($changes | length) == 0 then "Nothing to change."
       else ($changes | map("- `\(.change.actions | join("+"))` \(.address)") | join("\n")) end)
      + "\n\n\($changes | length) resource change(s).\n"')
  log "$text"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '## destroy %s: %s (%s)\n\n%s\n' "$name" "$2" "$mode" "$text" >>"$GITHUB_STEP_SUMMARY"
  fi
}

unprotect=()
for assignment in ${UNPROTECT_VARS:-}; do
  [[ "$assignment" =~ ^[a-z_]+=(true|false|[0-9]+)$ ]] || { echo "bad UNPROTECT_VARS" >&2; exit 2; }
  unprotect+=(-var "$assignment")
done
unprotect_targets=()
for address in ${UNPROTECT_TARGETS:-}; do unprotect_targets+=("-target=${address}"); done
if [[ ${#unprotect[@]} -gt 0 && ${#unprotect_targets[@]} -eq 0 ]]; then
  echo "UNPROTECT_TARGETS is required with UNPROTECT_VARS" >&2
  exit 2
fi

attempts=${DESTROY_ATTEMPTS:-1}
retry_wait=${RETRY_WAIT_SECONDS:-300}
[[ "$attempts" =~ ^[1-9][0-9]?$ && "$retry_wait" =~ ^[0-9]+$ ]] || { echo "bad DESTROY_ATTEMPTS or RETRY_WAIT_SECONDS" >&2; exit 2; }

# The plan files stay on the runner: they are never uploaded.
quietly terraform init -input=false \
  -backend-config="bucket=${bucket}" \
  -backend-config="key=${state_key}" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="use_lockfile=true"

if [[ "$mode" == destroy && ${#unprotect[@]} -gt 0 ]]; then
  log "Lowering the protection (${UNPROTECT_VARS}) on the targets."
  quietly terraform plan -input=false -lock-timeout=120s "${unprotect_targets[@]}" "${unprotect[@]}" -out=unprotect.tfplan
  summarize unprotect.tfplan "lower the protection"
  # Lowering a protection only updates. A plan that creates something means a target is gone, as when a
  # run that stopped part-way is dispatched again, and applying it would build it again.
  creates=$(terraform show -json unprotect.tfplan | jq '[.resource_changes[]? | select(.change.actions | index("create"))] | length')
  if ((creates > 0)); then
    log "The plan would create ${creates} resource(s): a target is gone. Not applying it."
  else
    quietly terraform apply -input=false -lock-timeout=120s unprotect.tfplan
  fi
fi

attempt=1
while true; do
  quietly terraform plan -destroy -input=false -lock-timeout=120s ${unprotect[@]+"${unprotect[@]}"} -out=tfplan
  summarize tfplan "destroy"
  [[ "$mode" == destroy ]] || break
  if quietly terraform apply -input=false -lock-timeout=120s tfplan; then
    log "Destroy complete."
    break
  fi
  if ((attempt >= attempts)); then
    echo "::error::The destroy failed after ${attempt} attempt(s)."
    exit 1
  fi
  log "Attempt ${attempt} of ${attempts} failed; planning again in ${retry_wait} s."
  sleep "$retry_wait"
  attempt=$((attempt + 1))
done
