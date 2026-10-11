#!/usr/bin/env bash
# Tests scripts/security-findings.sh against a fake `aws` that returns canned Inspector and
# Security Hub findings, including two pages of Inspector results. No credentials are needed.
# Run: scripts/tests/test_security_findings.sh
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security-findings.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

cat >"$work/bin/aws" <<'EOF'
#!/usr/bin/env bash
all="$*"
case "$1 $2" in
  "sts get-caller-identity") echo 123456789012 ;;
  "inspector2 list-findings")
    if [[ "$all" == *"--next-token page2"* ]]; then cat "$FAKE_PAGE2"; else cat "$FAKE_PAGE1"; fi ;;
  "securityhub get-findings") [[ -f "$FAKE_HUB" ]] && cat "$FAKE_HUB" || { echo "AccessDenied" >&2; exit 254; } ;;
  *) echo "unexpected aws call: $1 $2" >&2; exit 99 ;;
esac
EOF
chmod +x "$work/bin/aws"
export PATH="$work/bin:$PATH" AWS_REGION=us-east-1
export FAKE_PAGE1="$work/p1.json" FAKE_PAGE2="$work/p2.json" FAKE_HUB="$work/hub.json"
failures=0

finding() { # finding <severity> <fix> <title>
  jq -nc --arg s "$1" --arg f "$2" --arg t "$3" \
    '{severity:$s,fixAvailable:$f,title:$t,resources:[{type:"AWS_ECR_CONTAINER_IMAGE",id:"arn:aws:ecr:us-east-1:123456789012:repository/x"}]}'
}

run() {
  local name=$1 want=$2 text out code missing=""
  shift 2
  out=$("$script" 2>&1)
  code=$?
  for text in "$@"; do grep -qF -- "$text" <<<"$out" || missing="$missing [$text]"; done
  if [[ $code -eq $want && -z "$missing" ]]; then echo "ok   $name"
  else
    echo "FAIL $name: exit $code (want $want), missing:$missing"
    printf '     %s\n' "${out//$'\n'/$'\n'     }"
    failures=$((failures + 1))
  fi
}

echo '{"Findings":[]}' >"$FAKE_HUB"

# no findings at all
echo '{"findings":[]}' >"$FAKE_PAGE1"
run "no findings passes" 0 "Total active: 0." "Fixable CRITICAL or HIGH: 0"

# unfixable CRITICAL and fixable MEDIUM do not fail the gate
jq -n --argjson a "$(finding CRITICAL NO 'CVE-2025-0001 - libx')" --argjson b "$(finding MEDIUM YES 'CVE-2025-0002 - liby')" '{findings:[$a,$b]}' >"$FAKE_PAGE1"
run "an unfixable CRITICAL and a fixable MEDIUM pass" 0 "Fixable CRITICAL or HIGH: 0" "| CRITICAL | NO | 1 |"

# a fixable HIGH fails and is named
jq -n --argjson a "$(finding HIGH YES 'CVE-2025-0003 - libz')" '{findings:[$a]}' >"$FAKE_PAGE1"
run "a fixable HIGH fails the gate and is named" 1 "Fixable CRITICAL or HIGH: 1" "CVE-2025-0003 - libz"

# a partial fix counts as fixable
jq -n --argjson a "$(finding CRITICAL PARTIAL 'CVE-2025-0004 - libw')" '{findings:[$a]}' >"$FAKE_PAGE1"
run "a PARTIAL fix counts as fixable" 1 "Fixable CRITICAL or HIGH: 1"

# findings on the second page are counted
jq -n --argjson a "$(finding LOW NO 'CVE-2025-0005 - liba')" '{findings:[$a],nextToken:"page2"}' >"$FAKE_PAGE1"
jq -n --argjson a "$(finding HIGH YES 'CVE-2025-0006 - libb')" '{findings:[$a]}' >"$FAKE_PAGE2"
run "follows the pagination token" 1 "Total active: 2." "CVE-2025-0006 - libb"

# Security Hub is reported by control title
rm -f "$FAKE_PAGE2"
echo '{"findings":[]}' >"$FAKE_PAGE1"
jq -n '{Findings:[{Title:"S3 buckets should have TLS enforced",Severity:{Label:"HIGH"}},{Title:"S3 buckets should have TLS enforced",Severity:{Label:"HIGH"}}]}' >"$FAKE_HUB"
run "reports Security Hub findings by control title without gating" 0 "S3 buckets should have TLS enforced | 2 |"

# an unreadable Security Hub is said, not shown as empty
rm -f "$FAKE_HUB"
run "an unreadable Security Hub is reported as unreadable, not as none" 0 "could not be read with this role"

# no identifiers anywhere in the output
jq -n --argjson a "$(finding HIGH YES 'CVE-2025-0003 - libz')" '{findings:[$a]}' >"$FAKE_PAGE1"
out=$("$script" 2>&1)
if ! grep -qE '123456789012|arn:aws|repository/' <<<"${out//::add-mask::123456789012/}"; then echo "ok   the output names no account, ARN, or resource id"
else echo "FAIL the output names no account, ARN, or resource id"; failures=$((failures + 1)); fi

if ((failures > 0)); then echo "$failures test(s) failed"; exit 1; fi
echo "all passed"
