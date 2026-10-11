#!/usr/bin/env bash
# Exercise scripts/terraform-ci.sh against fake `aws` and `terraform` programs: the three exit codes
# of `drift`, the address-and-action summary, and the masking of identifiers when a step fails.
# Needs jq. Nothing contacts AWS.
# Usage: scripts/tests/test_terraform_ci.sh
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected [$3] got [$2]"; fi; }

mkdir -p "$work/bin" "$work/repo/scripts" "$work/repo/terraform/envs/dev"
cp "$repo/scripts/terraform-ci.sh" "$work/repo/scripts/"

# The fake account and plan contents are fixed here; FAKE_PLAN_RC and FAKE_FAIL pick the behaviour.
cat >"$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
[[ "$1 $2" == "sts get-caller-identity" ]] && { echo 123456789012; exit 0; }
echo "fake aws: unexpected call: $*" >&2; exit 99
FAKE
cat >"$work/bin/terraform" <<'FAKE'
#!/usr/bin/env bash
cmd=$1
case "$cmd" in
  init) [[ "${FAKE_FAIL:-}" == init ]] && { echo "Error: bucket 123456789012 vpc-0d3fc87aef6e0d577 [id=sg-07054fd70a2b826bd]"; exit 1; }; exit 0 ;;
  plan)
    for a in "$@"; do case "$a" in -out=*) echo "plan" >"${a#-out=}" ;; esac; done
    [[ "${FAKE_FAIL:-}" == plan ]] && { echo "Error: in vpc-0d3fc87aef6e0d577 of account 123456789012 [id=subnet-033316524a052dc06]"; exit 1; }
    exit "${FAKE_PLAN_RC:-0}" ;;
  show) cat "$FAKE_PLAN_JSON" ;;
  apply) echo applied >>"$FAKE_LOG"; exit 0 ;;
  *) exit 99 ;;
esac
FAKE
chmod +x "$work/bin/aws" "$work/bin/terraform"

cat >"$work/changes.json" <<'JSON'
{"resource_changes":[
 {"address":"module.network.aws_vpc.this","change":{"actions":["update"],"before":{"tags":{"a":"1"},"cidr_block":"10.40.0.0/16"},"after":{"tags":{"a":"2"},"cidr_block":"10.40.0.0/16"}}},
 {"address":"module.x.aws_s3_bucket.b","change":{"actions":["create"],"before":null,"after":{"bucket":"secret-looking-value"}}},
 {"address":"module.y.aws_thing.t","change":{"actions":["no-op"],"before":{},"after":{}}}]}
JSON
echo '{"resource_changes":[]}' >"$work/none.json"

# The runner consumes `::add-mask::` lines and never shows them, so they are dropped from what the
# tests see.
run() { # run <mode> [env...]
  local mode=$1
  shift
  (cd "$work/repo" && env PATH="$work/bin:$PATH" AWS_REGION=us-east-1 FAKE_LOG="$work/apply.log" \
    SUMMARY_FILE="$work/summary.md" "$@" scripts/terraform-ci.sh "$mode") 2>&1 | { grep -v '^::add-mask::' || true; }
}

echo "== drift with no changes exits 0"
out=$(run drift FAKE_PLAN_RC=0 FAKE_PLAN_JSON="$work/none.json") && rc=0 || rc=$?
check "exit code" "$rc" "0"
check "says there are no changes" "$(grep -c 'No changes' <<<"$out")" "1"

echo "== drift with changes exits 2 and writes the summary"
rm -f "$work/summary.md"
out=$(run drift FAKE_PLAN_RC=2 FAKE_PLAN_JSON="$work/changes.json") && rc=0 || rc=$?
check "exit code" "$rc" "2"
check "lists the update with the attribute name" "$(grep -c 'update. module.network.aws_vpc.this (changed: tags)' <<<"$out")" "1"
check "lists the create" "$(grep -c 'create. module.x.aws_s3_bucket.b' <<<"$out")" "1"
check "never prints an attribute value" "$(grep -c 'secret-looking-value\|10.40.0.0' <<<"$out")" "0"
check "the summary file has the same text" "$(grep -c 'module.network.aws_vpc.this' "$work/summary.md")" "1"

echo "== drift on an error exits 1 with identifiers masked"
out=$(run drift FAKE_FAIL=plan FAKE_PLAN_JSON="$work/none.json") && rc=0 || rc=$?
check "exit code" "$rc" "1"
check "the error text is shown" "$(grep -c 'Error: in' <<<"$out")" "1"
check "account ID masked" "$(grep -c '123456789012' <<<"$out")" "0"
check "VPC ID masked" "$(grep -c 'vpc-0d3fc87aef6e0d577' <<<"$out")" "0"
check "subnet ID masked" "$(grep -c 'subnet-033316524a052dc06' <<<"$out")" "0"

echo "== plan exits 0 even with changes"
out=$(run plan FAKE_PLAN_RC=0 FAKE_PLAN_JSON="$work/changes.json") && rc=0 || rc=$?
check "exit code" "$rc" "0"

echo "== plan masks identifiers when init fails"
out=$(run plan FAKE_FAIL=init FAKE_PLAN_JSON="$work/none.json") && rc=0 || rc=$?
check "exit code" "$rc" "1"
check "ids masked" "$(grep -cE '123456789012|vpc-0d3fc87aef6e0d577|sg-07054fd70a2b826bd' <<<"$out")" "0"

echo "== apply applies"
rm -f "$work/apply.log"
run apply FAKE_PLAN_RC=0 FAKE_PLAN_JSON="$work/changes.json" >/dev/null 2>&1 && rc=0 || rc=$?
check "exit code" "$rc" "0"
check "terraform apply ran" "$(grep -c applied "$work/apply.log")" "1"

echo "== an unknown mode is refused"
run bogus >/dev/null 2>&1 && rc=0 || rc=$?
check "exit code" "$rc" "2"

echo
if [[ "$failures" -eq 0 ]]; then echo "all checks passed"; else echo "$failures check(s) failed"; exit 1; fi
