#!/usr/bin/env bash
# Tests scripts/cutover-gates.sh against a fake `aws` whose CloudWatch answers come from variables,
# so each gate can be driven to pass, fail, or have no data. No credentials are needed.
# Run: scripts/tests/test_cutover_gates.sh
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/cutover-gates.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

cat >"$work/bin/aws" <<'EOF'
#!/usr/bin/env bash
all="$*"
sub="$1 $2"; shift 2
case "$sub" in
  "sts get-caller-identity") echo 123456789012 ;;
  "elbv2 describe-load-balancers")
    echo '{"LoadBalancers":[{"LoadBalancerArn":"arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/shiptrack-alb/0123456789abcdef"}]}' ;;
  "elbv2 describe-target-groups")
    case "$all" in
      *shiptrack-tg-legacy*) echo '{"TargetGroups":[{"TargetGroupArn":"arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/shiptrack-tg-legacy/aaaaaaaaaaaaaaaa"}]}' ;;
      *) echo '{"TargetGroups":[{"TargetGroupArn":"arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/shiptrack-tg-modern/bbbbbbbbbbbbbbbb"}]}' ;;
    esac ;;
  "cloudwatch get-metric-statistics")
    who=L; [[ "$all" == *tg-modern* ]] && who=M
    case "$all" in
      *"--namespace AWS/SQS"*"ApproximateAgeOfOldestMessage"*) v=$FAKE_QUEUE_AGE; kind=max ;;
      *"--namespace AWS/SQS"*"ApproximateNumberOfMessagesVisible"*) v=$FAKE_DLQ; kind=max ;;
      *RequestCount*) eval "v=\$FAKE_${who}_REQ"; kind=sum ;;
      *HTTPCode_Target_5XX_Count*) eval "v=\$FAKE_${who}_5XX"; kind=sum ;;
      *TargetResponseTime*) eval "v=\$FAKE_${who}_P95"; kind=p95 ;;
    esac
    case "$kind" in
      sum) jq -n --argjson v "$v" '{Datapoints:[{Sum:$v}]}' ;;
      max) jq -n --argjson v "$v" '{Datapoints:[{Maximum:$v}]}' ;;
      p95) jq -n --argjson v "$v" '{Datapoints:[{ExtendedStatistics:{p95:$v}}]}' ;;
    esac ;;
  "cloudwatch describe-alarms") echo "$FAKE_ALARMS" ;;
  "ssm get-parameter")
    case "$all" in
      *events_queue_url*) echo '{"Parameter":{"Value":"https://sqs.us-east-1.amazonaws.com/123456789012/shiptrack-events"}}' ;;
      *events_dlq_url*) echo '{"Parameter":{"Value":"https://sqs.us-east-1.amazonaws.com/123456789012/shiptrack-events-dlq"}}' ;;
      *notify_dlq_url*) echo '{"Parameter":{"Value":"https://sqs.us-east-1.amazonaws.com/123456789012/shiptrack-notify-dlq"}}' ;;
    esac ;;
  *) echo "unexpected aws call: $sub" >&2; exit 99 ;;
esac
EOF
chmod +x "$work/bin/aws"

export PATH="$work/bin:$PATH" AWS_REGION=us-east-1
failures=0

defaults() {
  export FAKE_L_REQ=1000 FAKE_M_REQ=1000 FAKE_L_5XX=2 FAKE_M_5XX=3 FAKE_L_P95=0.200 FAKE_M_P95=0.210
  export FAKE_QUEUE_AGE=5 FAKE_DLQ=0 FAKE_ALARMS='{"MetricAlarms":[],"CompositeAlarms":[]}'
  unset WAVE MIN_REQUESTS
}

# run <name> <expected exit> <expected text> [more text...]
run() {
  local name=$1 want=$2 text out code
  shift 2
  out=$("$script" 2>&1)
  code=$?
  local missing=""
  for text in "$@"; do grep -qF -- "$text" <<<"$out" || missing="$missing [$text]"; done
  if [[ $code -eq $want && -z "$missing" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: exit $code (want $want), missing:$missing"
    printf '     %s\n' "${out//$'\n'/$'\n'     }"
    failures=$((failures + 1))
  fi
}

defaults
run "a healthy soak passes G2, G3, and G4" 0 "| G2 Errors | PASS |" "| G3 Latency | PASS |" "| G4 Stability | PASS |" "| G5 Async health | n/a |"

defaults; export FAKE_M_5XX=30
run "a modern 5xx ratio well above legacy fails G2" 1 "| G2 Errors | FAIL |" "legacy 0.20%, modern 3.00%"

defaults; export FAKE_M_P95=0.300
run "a modern p95 above 1.2 x legacy fails G3" 1 "| G3 Latency | FAIL |"

defaults; export FAKE_M_P95=0.240
run "a modern p95 exactly 1.2 x legacy passes G3" 0 "| G3 Latency | PASS |"

defaults; export FAKE_M_REQ=20
run "too few modern requests is NO DATA, not a pass" 0 "| G2 Errors | NO DATA |" "| G3 Latency | NO DATA |" "need 100 each"

defaults; export FAKE_ALARMS='{"MetricAlarms":[{"AlarmName":"shiptrack-platform-tg-modern-5xx-ratio","AlarmDescription":"owner: x | severity: SEV1 | runbook: y"}],"CompositeAlarms":[]}'
run "a SEV1 alarm in ALARM fails G4 and names it" 1 "| G4 Stability | FAIL |" "tg-modern-5xx-ratio"

defaults; export FAKE_ALARMS='{"MetricAlarms":[{"AlarmName":"shiptrack-modern-pod-restarts","AlarmDescription":"SEV2: containers restarted"}],"CompositeAlarms":[]}'
run "a pod restart alarm fails G4" 1 "| G4 Stability | FAIL |" "pod-restarts"

defaults; export FAKE_ALARMS='{"MetricAlarms":[{"AlarmName":"shiptrack-platform-rds-cpu","AlarmDescription":"owner: x | severity: SEV2 | runbook: y"}],"CompositeAlarms":[]}'
run "a SEV2 alarm alone does not fail G4" 0 "| G4 Stability | PASS |" "1 SEV2 in ALARM"

defaults; export WAVE=2
run "wave 2 judges G5 and passes with a fresh queue and empty DLQs" 0 "| G5 Async health | PASS |"

defaults; export WAVE=2 FAKE_QUEUE_AGE=120
run "an old event fails G5" 1 "| G5 Async health | FAIL |" "oldest message 120s"

defaults; export WAVE=2 FAKE_DLQ=1
run "a message in the DLQ fails G5" 1 "| G5 Async health | FAIL |" "DLQ 1"

defaults
out=$("$script" 2>&1)
if ! grep -qE '123456789012|arn:aws|amazonaws\.com' <<<"${out//::add-mask::123456789012/}"; then echo "ok   the table names no account, ARN, or address"
else echo "FAIL the table names no account, ARN, or address"; failures=$((failures + 1)); fi

if ((failures > 0)); then echo "$failures test(s) failed"; exit 1; fi
echo "all passed"
