#!/usr/bin/env bash
# Evaluate the cutover gates G2 to G5 over the last WINDOW_MINUTES from CloudWatch, and print a
# table of numbers. Run by .github/workflows/cutover-gates.yml with the read-only plan role, so
# nobody needs the console or the AWS CLI to judge a soak.
# Usage: scripts/cutover-gates.sh
#
# G1 (the contract suite) and G6 (UI parity) are run by validation.yml. The table says so.
#
#   G2  tg-modern 5xx ratio <= tg-legacy 5xx ratio + 0.5 percentage points
#   G3  tg-modern p95 response time <= 1.2 x tg-legacy p95
#   G4  no SEV1 alarm in ALARM, and no pod restart alarm
#   G5  (WAVE 2 or later) events queue age < 60 s and the dead-letter queues empty
#
# A gate that cannot be judged because a target group saw fewer than MIN_REQUESTS requests is
# reported as NO DATA, never as a pass: at 10% weight with no load there may be almost no traffic,
# so run the k6 baseline with target `none` (weighted routing) during the soak.
#
# The output has request counts, ratios, seconds, and alarm names: no account ID, ARN, or address.
#
# Environment:
#   AWS_REGION        required
#   WINDOW_MINUTES    default 30
#   MIN_REQUESTS      default 100
#   WAVE              1 or 2 (default 1); G5 is judged from 2
#   ALB_NAME, LEGACY_TG_NAME, MODERN_TG_NAME  defaults shiptrack-alb, shiptrack-tg-legacy, shiptrack-tg-modern
set -euo pipefail

: "${AWS_REGION:?AWS_REGION is required}"
window=${WINDOW_MINUTES:-30}
min_requests=${MIN_REQUESTS:-100}
wave=${WAVE:-1}
alb_name=${ALB_NAME:-shiptrack-alb}
legacy_name=${LEGACY_TG_NAME:-shiptrack-tg-legacy}
modern_name=${MODERN_TG_NAME:-shiptrack-tg-modern}

account=$(aws sts get-caller-identity --query Account --output text)
echo "::add-mask::$account"

iso_ago() { # an ISO time N minutes ago, with GNU or BSD date
  date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ
}
end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start=$(iso_ago "$window")
period=$((window * 60))

lb_arn=$(aws elbv2 describe-load-balancers --names "$alb_name" --output json | jq -r '.LoadBalancers[0].LoadBalancerArn // empty')
legacy_arn=$(aws elbv2 describe-target-groups --names "$legacy_name" --output json | jq -r '.TargetGroups[0].TargetGroupArn // empty')
modern_arn=$(aws elbv2 describe-target-groups --names "$modern_name" --output json | jq -r '.TargetGroups[0].TargetGroupArn // empty')
for v in lb_arn legacy_arn modern_arn; do
  [[ -n "${!v}" ]] || { echo "::error::could not find ${v%_arn}"; exit 1; }
done
lb_dim=${lb_arn#*loadbalancer/}
legacy_dim=${legacy_arn##*:}
modern_dim=${modern_arn##*:}

# metric <namespace> <metric> <stat|pNN> <dimension args...>: one number over the window, 0 if none.
metric() {
  local ns=$1 name=$2 stat=$3
  shift 3
  local statflag=(--statistics "$stat") key=".Datapoints | map(.$stat) | max // 0"
  if [[ "$stat" =~ ^p[0-9]+$ ]]; then
    statflag=(--extended-statistics "$stat")
    key=".Datapoints | map(.ExtendedStatistics.$stat) | max // 0"
  elif [[ "$stat" == Sum ]]; then
    key=".Datapoints | map(.Sum) | add // 0"
  fi
  aws cloudwatch get-metric-statistics --namespace "$ns" --metric-name "$name" \
    --dimensions "$@" --start-time "$start" --end-time "$end" --period "$period" \
    "${statflag[@]}" --output json | jq -r "$key"
}

tg_metric() { # tg_metric <target group dimension> <metric> <stat>
  metric AWS/ApplicationELB "$2" "$3" "Name=LoadBalancer,Value=$lb_dim" "Name=TargetGroup,Value=$1"
}

req_l=$(tg_metric "$legacy_dim" RequestCount Sum)
req_m=$(tg_metric "$modern_dim" RequestCount Sum)
err_l=$(tg_metric "$legacy_dim" HTTPCode_Target_5XX_Count Sum)
err_m=$(tg_metric "$modern_dim" HTTPCode_Target_5XX_Count Sum)
p95_l=$(tg_metric "$legacy_dim" TargetResponseTime p95)
p95_m=$(tg_metric "$modern_dim" TargetResponseTime p95)

ms() { awk -v s="$1" 'BEGIN { printf "%.1f", s * 1000 }'; }
ratio() { awk -v e="$1" -v r="$2" 'BEGIN { if (r > 0) printf "%.2f", 100 * e / r; else print "0.00" }'; }
ratio_l=$(ratio "$err_l" "$req_l")
ratio_m=$(ratio "$err_m" "$req_m")
enough=$(awk -v a="$req_l" -v b="$req_m" -v n="$min_requests" 'BEGIN { print (a >= n && b >= n) ? "yes" : "no" }')

rows=()
fails=0
add() { # add <gate> <verdict> <criterion> <measured>
  rows+=("| $1 | $2 | $3 | $4 |")
  [[ "$2" == FAIL ]] && fails=$((fails + 1))
  return 0
}

add "G1 Correctness" "run validation.yml" "contract suite passes with TARGET=modern" "not measured here"
add "G6 UI parity" "run validation.yml" "ui_parity passes (before wave 1)" "not measured here"

# G2
if [[ "$enough" != yes ]]; then
  add "G2 Errors" "NO DATA" "modern 5xx ratio <= legacy + 0.5 pp" "requests: legacy $req_l, modern $req_m (need $min_requests each)"
elif awk -v m="$ratio_m" -v l="$ratio_l" 'BEGIN { exit !(m <= l + 0.5) }'; then
  add "G2 Errors" "PASS" "modern 5xx ratio <= legacy + 0.5 pp" "legacy ${ratio_l}%, modern ${ratio_m}% (requests $req_l and $req_m)"
else
  add "G2 Errors" "FAIL" "modern 5xx ratio <= legacy + 0.5 pp" "legacy ${ratio_l}%, modern ${ratio_m}% (requests $req_l and $req_m)"
fi

# G3
if [[ "$enough" != yes ]]; then
  add "G3 Latency" "NO DATA" "modern p95 <= 1.2 x legacy p95" "requests: legacy $req_l, modern $req_m (need $min_requests each)"
elif awk -v m="$p95_m" -v l="$p95_l" 'BEGIN { exit !(m <= 1.2 * l) }'; then
  add "G3 Latency" "PASS" "modern p95 <= 1.2 x legacy p95" "legacy $(ms "$p95_l") ms, modern $(ms "$p95_m") ms"
else
  add "G3 Latency" "FAIL" "modern p95 <= 1.2 x legacy p95" "legacy $(ms "$p95_l") ms, modern $(ms "$p95_m") ms"
fi

# G4: alarms in ALARM state. SEV1 or a pod restart alarm fails the gate. An alarm created with its
# actions off (the SLA scan heartbeat, until the CronJob takes over in wave 3) is in ALARM by design
# and notifies no one, so it is counted apart and does not fail the gate.
alarms=$(aws cloudwatch describe-alarms --state-value ALARM --output json)
live='(.MetricAlarms[]?, .CompositeAlarms[]?) | select(.AlarmName | startswith("shiptrack"))'
sev1=$(jq -r "[$live | select(.ActionsEnabled != false)
               | select((.AlarmDescription // \"\") | test(\"SEV1\"))
               | select(.AlarmName | test(\"pod-restarts\") | not) | .AlarmName] | join(\", \")" <<<"$alarms")
restarts=$(jq -r "[$live | select(.ActionsEnabled != false)
                   | select(.AlarmName | test(\"pod-restarts\")) | .AlarmName] | join(\", \")" <<<"$alarms")
sev2_names=$(jq -r "[$live | select(.ActionsEnabled != false)
                    | select((.AlarmDescription // \"\") | test(\"SEV2\")) | .AlarmName] | join(\", \")" <<<"$alarms")
sev2=$(jq -r "[$live | select(.ActionsEnabled != false)
               | select((.AlarmDescription // \"\") | test(\"SEV2\")) | .AlarmName] | length" <<<"$alarms")
muted=$(jq -r "[$live | select(.ActionsEnabled == false) | .AlarmName] | length" <<<"$alarms")
if [[ -n "$sev1" || -n "$restarts" ]]; then
  add "G4 Stability" "FAIL" "no SEV1 alarm, no pod restarts from the release" "in ALARM: ${sev1:+$sev1}${sev1:+${restarts:+, }}${restarts}"
else
  add "G4 Stability" "PASS" "no SEV1 alarm, no pod restarts from the release" "no SEV1 in ALARM; $sev2 SEV2 in ALARM${sev2_names:+ ($sev2_names)}; $muted with actions disabled, not counted"
fi

# G5 (wave 2 and later): the events queue and the dead-letter queues.
if [[ "$wave" -ge 2 ]]; then
  ssm() { aws ssm get-parameter --name "$1" --output json 2>/dev/null | jq -r '.Parameter.Value // empty'; }
  events_url=$(ssm /shiptrack/modern/events_queue_url)
  dlq_url=$(ssm /shiptrack/modern/events_dlq_url)
  notify_dlq_url=$(ssm /shiptrack/modern/notify_dlq_url)
  if [[ -z "$events_url" || -z "$dlq_url" ]]; then
    add "G5 Async health" "NO DATA" "events queue age < 60 s, dead-letter queues empty" "the modern queue names are not in SSM"
  else
    age=$(metric AWS/SQS ApproximateAgeOfOldestMessage Maximum "Name=QueueName,Value=${events_url##*/}")
    dlq=$(metric AWS/SQS ApproximateNumberOfMessagesVisible Maximum "Name=QueueName,Value=${dlq_url##*/}")
    ndlq=0
    [[ -n "$notify_dlq_url" ]] && ndlq=$(metric AWS/SQS ApproximateNumberOfMessagesVisible Maximum "Name=QueueName,Value=${notify_dlq_url##*/}")
    if awk -v a="$age" -v d="$dlq" -v n="$ndlq" 'BEGIN { exit !(a < 60 && d == 0 && n == 0) }'; then
      add "G5 Async health" "PASS" "events queue age < 60 s, dead-letter queues empty" "oldest message ${age}s; DLQ $dlq; notify DLQ $ndlq"
    else
      add "G5 Async health" "FAIL" "events queue age < 60 s, dead-letter queues empty" "oldest message ${age}s; DLQ $dlq; notify DLQ $ndlq"
    fi
  fi
else
  add "G5 Async health" "n/a" "judged from wave 2" "-"
fi

{
  echo "### Cutover gates, last ${window} minutes (wave ${wave})"
  echo
  echo "| Gate | Result | Criterion | Measured |"
  echo "|---|---|---|---|"
  printf '%s\n' "${rows[@]}"
  echo
  echo "Window: ${start} to ${end}. Minimum ${min_requests} requests per target group."
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

if ((fails > 0)); then
  echo "::error::$fails gate(s) failed"
  exit 1
fi
