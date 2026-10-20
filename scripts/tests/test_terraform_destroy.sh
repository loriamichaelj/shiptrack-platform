#!/usr/bin/env bash
# Exercise scripts/terraform-destroy.sh against fake `aws` and `terraform` programs: the confirmation
# check, the guard that refuses to start while the legacy or modern stack has parameters, the order of
# the steps in each mode, the retry, and the guard that refuses to apply a plan that would create the
# protected resources again. Needs jq. Nothing contacts AWS.
# Usage: scripts/tests/test_terraform_destroy.sh
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo/scripts/terraform-destroy.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
ok() { if "${@:2}"; then pass "$1"; else fail "$1"; fi; }
not() { ! "$@"; }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected [$3] got [$2]"; fi; }

mkdir -p "$work/bin"
# FAKE_LEGACY and FAKE_MODERN are the number of parameters each stack still has.
cat >"$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "sts get-caller-identity") echo 123456789012 ;;
  "ssm get-parameters-by-path")
    case "$*" in
      *"/shiptrack/legacy"*) echo "${FAKE_LEGACY:-0}" ;;
      *"/shiptrack/modern"*) echo "${FAKE_MODERN:-0}" ;;
    esac ;;
  *) echo "fake aws: unexpected call: $*" >&2; exit 99 ;;
esac
FAKE
# `show` prints a plan with one update, or one create when FAKE_CREATES is set. FAKE_FAIL_APPLIES is the
# number of destroy applies that fail before one passes.
cat >"$work/bin/terraform" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DIR/calls"
case "$1" in
  show)
    action=update
    [[ -z "${FAKE_CREATES:-}" || "$3" != unprotect.tfplan ]] || action=create
    printf '{"resource_changes":[{"address":"module.database.aws_db_instance.this","change":{"actions":["%s"]}}]}\n' "$action" ;;
  apply)
    if [[ "$*" == *" tfplan" ]]; then
      n=$(cat "$FAKE_DIR/failed" 2>/dev/null || echo 0)
      if ((n < ${FAKE_FAIL_APPLIES:-0})); then echo $((n + 1)) >"$FAKE_DIR/failed"; echo "Error: DependencyViolation vpc-0d3fc87aef6e0d577"; exit 1; fi
    fi ;;
esac
FAKE
chmod +x "$work/bin/aws" "$work/bin/terraform"

# run <mode> <confirm>: output in $work/out, calls in $work/calls
run() {
  : >"$work/calls"
  rm -f "$work/failed"
  PATH="$work/bin:$PATH" FAKE_DIR="$work" AWS_REGION=us-east-1 CONFIRM="$2" \
    UNPROTECT_VARS="${UNPROTECT_VARS:-}" UNPROTECT_TARGETS="${UNPROTECT_TARGETS:-}" \
    "$script" "$1" all >"$work/out" 2>&1
}
export UNPROTECT_VARS="deletion_protection=false skip_final_snapshot=true force_destroy_buckets=true secret_recovery_window_days=0"
export UNPROTECT_TARGETS="module.database.aws_db_instance.this module.ingress.aws_lb.this module.storage.aws_s3_bucket.pod"

echo "terraform-destroy.sh"

status=0
run destroy nope || status=$?
check "a wrong confirmation fails" "$status" "1"
check "a wrong confirmation runs no terraform" "$(wc -l <"$work/calls" | tr -d ' ')" "0"

status=0
FAKE_LEGACY=2 run plan all || status=$?
check "a legacy stack that is still there stops the plan" "$status" "1"
ok "the guard names the stack" grep -q 'legacy stack still has 2' "$work/out"
check "the guard runs no terraform" "$(wc -l <"$work/calls" | tr -d ' ')" "0"

status=0
FAKE_MODERN=40 run destroy all || status=$?
check "a modern stack that is still there stops the destroy" "$status" "1"
check "the guard runs no terraform in destroy" "$(wc -l <"$work/calls" | tr -d ' ')" "0"

run plan all
check "plan: init, one destroy plan, no apply" \
  "$(grep -c '^init \|^plan -destroy ' "$work/calls") $(grep -c '^apply' "$work/calls")" "2 0"
ok "plan: the state key is the platform's" grep -q -- '-backend-config=key=platform/dev/terraform.tfstate' "$work/calls"
ok "plan: the destroy plan carries the variables" grep -q -- '^plan -destroy .*-var deletion_protection=false .*-var secret_recovery_window_days=0' "$work/calls"
check "plan: no targeted plan" "$(grep -c -- '-target=' "$work/calls")" "0"

run destroy all
check "destroy: two applies" "$(grep -c '^apply' "$work/calls")" "2"
first=$(grep -n -- '-target=' "$work/calls" | head -1 | cut -d: -f1)
last=$(grep -n '^plan -destroy' "$work/calls" | head -1 | cut -d: -f1)
ok "destroy: the protection is lowered before the destroy plan" test "${first:-9}" -lt "${last:-0}"
ok "destroy: reports completion" grep -q 'Destroy complete' "$work/out"

FAKE_CREATES=1 run destroy all
check "destroy: a plan that would create the targets is not applied" "$(grep -c '^apply' "$work/calls")" "1"
ok "destroy: says why it skipped" grep -q 'Not applying it' "$work/out"

status=0
DESTROY_ATTEMPTS=1 FAKE_FAIL_APPLIES=1 run destroy all || status=$?
check "destroy: a failure with one attempt fails the run" "$status" "1"

DESTROY_ATTEMPTS=2 RETRY_WAIT_SECONDS=0 FAKE_FAIL_APPLIES=1 run destroy all
check "destroy: a second attempt plans afresh and passes" "$(grep -c '^plan -destroy' "$work/calls")" "2"
ok "destroy: reports completion after a retry" grep -q 'Destroy complete' "$work/out"
ok "a failure's identifiers are masked" not grep -q 'vpc-0d3fc87aef6e0d577' "$work/out"

status=0
UNPROTECT_VARS="x=\$(id)" run destroy all || status=$?
check "a malformed assignment is refused" "$status" "2"

ok "the account ID is masked, not printed" test "$(grep -v '^::add-mask::' "$work/out" | grep -c '123456789012' || true)" = 0

if ((failures > 0)); then
  printf '%d failure(s)\n' "$failures"
  exit 1
fi
echo "all passed"
