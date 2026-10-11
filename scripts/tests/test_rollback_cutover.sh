#!/usr/bin/env bash
# Tests scripts/rollback-cutover.sh against a fake `aws` that keeps the ALB's listeners and rules in
# a state file, so the test sees exactly which rules were modified. No credentials are needed.
# Run: scripts/tests/test_rollback_cutover.sh
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rollback-cutover.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

LB=arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/shiptrack-alb/0123456789abcdef
LEG=arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/shiptrack-tg-legacy/aaaaaaaaaaaaaaaa
MOD=arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/shiptrack-tg-modern/bbbbbbbbbbbbbbbb
L80=arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/shiptrack-alb/0123456789abcdef/l80
L443=arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/shiptrack-alb/0123456789abcdef/l443
L8080=arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/shiptrack-alb/0123456789abcdef/l8080

cat >"$work/bin/aws" <<'EOF'
#!/usr/bin/env bash
# Fake aws: state lives in $FAKE_STATE (JSON); every call is logged to $FAKE_CALLS.
echo "$*" >>"$FAKE_CALLS"
sub="$1 $2"; shift 2
arg() { # arg <flag>: the value after a flag
  local f=$1; shift
  while (($#)); do if [[ "$1" == "$f" ]]; then echo "$2"; return; fi; shift; done
}
case "$sub" in
  "sts get-caller-identity") echo 123456789012 ;;
  "elbv2 describe-load-balancers") jq -n --arg a "$FAKE_LB" '{LoadBalancers:[{LoadBalancerArn:$a}]}' ;;
  "elbv2 describe-target-groups")
    n=$(arg --names "$@")
    case "$n" in
      shiptrack-tg-legacy) jq -n --arg a "$FAKE_LEG" '{TargetGroups:[{TargetGroupArn:$a}]}' ;;
      shiptrack-tg-modern) jq -n --arg a "$FAKE_MOD" '{TargetGroups:[{TargetGroupArn:$a}]}' ;;
      *) echo '{"TargetGroups":[]}' ;;
    esac ;;
  "elbv2 describe-listeners") jq '{Listeners: .listeners}' "$FAKE_STATE" ;;
  "elbv2 describe-rules")
    l=$(arg --listener-arn "$@")
    jq --arg l "$l" '{Rules: [.rules[] | select(.ListenerArn == $l)]}' "$FAKE_STATE" ;;
  "elbv2 modify-rule")
    r=$(arg --rule-arn "$@"); a=$(arg --actions "$@")
    jq --arg r "$r" --argjson a "$a" '.rules |= map(if .RuleArn == $r then .Actions = $a else . end)' "$FAKE_STATE" >"$FAKE_STATE.new" && mv "$FAKE_STATE.new" "$FAKE_STATE" ;;
  "elbv2 modify-listener")
    l=$(arg --listener-arn "$@"); a=$(arg --default-actions "$@")
    jq --arg l "$l" --argjson a "$a" '.listeners |= map(if .ListenerArn == $l then .DefaultActions = $a else . end)' "$FAKE_STATE" >"$FAKE_STATE.new" && mv "$FAKE_STATE.new" "$FAKE_STATE" ;;
  *) echo "unexpected aws call: $sub" >&2; exit 99 ;;
esac
EOF
chmod +x "$work/bin/aws"

export PATH="$work/bin:$PATH"
export AWS_REGION=us-east-1 FAKE_LB="$LB" FAKE_LEG="$LEG" FAKE_MOD="$MOD"
export FAKE_STATE="$work/state.json" FAKE_CALLS="$work/calls"
failures=0

# weighted <legacy> <modern> <stickiness-seconds>: a forward action to both groups
weighted() {
  jq -nc --arg l "$LEG" --arg m "$MOD" --argjson lw "$1" --argjson mw "$2" --argjson s "$3" \
    '[{Type:"forward",Order:1,ForwardConfig:{TargetGroups:[{TargetGroupArn:$l,Weight:$lw},{TargetGroupArn:$m,Weight:$mw}],TargetGroupStickinessConfig:{Enabled:true,DurationSeconds:$s}}}]'
}
single() { jq -nc --arg t "$1" '[{Type:"forward",Order:1,TargetGroupArn:$t,ForwardConfig:{TargetGroups:[{TargetGroupArn:$t,Weight:1}]}}]'; }

# state <tls: yes|no> <track legacy> <track modern> <default legacy> <default modern>
make_state() {
  local main_arn=$L80 main_port=80 extra="[]"
  if [[ "$1" == yes ]]; then
    main_arn=$L443 main_port=443
    extra=$(jq -nc --arg a "$L80" --arg lb "$LB" '[{ListenerArn:$a,LoadBalancerArn:$lb,Port:80,DefaultActions:[{Type:"redirect"}]}]')
  fi
  jq -n --arg lb "$LB" --arg main "$main_arn" --argjson port "$main_port" --argjson extra "$extra" \
        --arg l8080 "$L8080" --arg leg "$LEG" --arg mod "$MOD" \
        --argjson ui "$(weighted "$2" "$3" 3600)" --argjson track "$(weighted "$2" "$3" 1)" \
        --argjson def "$(weighted "$4" "$5" 3600)" \
        --argjson hl "$(single "$LEG")" --argjson hm "$(single "$MOD")" '
    {listeners: ([{ListenerArn:$main,LoadBalancerArn:$lb,Port:$port,DefaultActions:$def},
                  {ListenerArn:$l8080,LoadBalancerArn:$lb,Port:8080,DefaultActions:$hm}] + $extra),
     rules: [
       {RuleArn:"rule-10",ListenerArn:$main,Priority:"10",IsDefault:false,Actions:$hl},
       {RuleArn:"rule-20",ListenerArn:$main,Priority:"20",IsDefault:false,Actions:$hm},
       {RuleArn:"rule-90",ListenerArn:$main,Priority:"90",IsDefault:false,Actions:$ui},
       {RuleArn:"rule-100",ListenerArn:$main,Priority:"100",IsDefault:false,Actions:$track},
       {RuleArn:"rule-default",ListenerArn:$main,Priority:"default",IsDefault:true,Actions:$def}]}' >"$FAKE_STATE"
  : >"$FAKE_CALLS"
}

ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
modifies() { grep -cE '^elbv2 modify-' "$FAKE_CALLS"; }
mw() { # modern weight of a rule or listener default: mw rule <arn> | mw listener <arn>
  if [[ "$1" == rule ]]; then
    jq -r --arg a "$2" --arg m "$MOD" '.rules[] | select(.RuleArn == $a) | [.Actions[].ForwardConfig.TargetGroups[] | select(.TargetGroupArn == $m) | .Weight][0]' "$FAKE_STATE"
  else
    jq -r --arg a "$2" --arg m "$MOD" '.listeners[] | select(.ListenerArn == $a) | [.DefaultActions[].ForwardConfig.TargetGroups[] | select(.TargetGroupArn == $m) | .Weight][0]' "$FAKE_STATE"
  fi
}

# 1. a live cutover (track 50/50, default 90/10) goes back to legacy 100, modern 0
make_state no 50 50 90 10
out=$("$script" 2>&1); code=$?
if [[ $code -eq 0 && $(mw rule rule-90) == 0 && $(mw rule rule-100) == 0 && $(mw listener "$L80") == 0 ]]; then
  ok "rolls the weighted rules and the default action back to legacy"
else fail "rolls the weighted rules and the default action back to legacy (exit $code)"; printf '     %s\n' "${out//$'\n'/$'\n'     }"; fi

# 2. only the three weighted actions were modified
if [[ $(modifies) -eq 3 ]]; then ok "modifies exactly the two weighted rules and the default action"
else fail "modifies exactly the two weighted rules and the default action ($(modifies) modify calls)"; fi

# 3. the header rules and the preview listener are untouched
if ! grep -qE 'modify-rule --rule-arn rule-(10|20|default) ' "$FAKE_CALLS" && ! grep -q "modify-listener --listener-arn $L8080" "$FAKE_CALLS"; then
  ok "leaves the header rules and the preview listener alone"
else fail "leaves the header rules and the preview listener alone"; fi

# 4. stickiness survives (only weights are rewritten)
if [[ $(jq -r '.rules[] | select(.RuleArn == "rule-90") | .Actions[0].ForwardConfig.TargetGroupStickinessConfig.DurationSeconds' "$FAKE_STATE") == 3600 \
   && $(jq -r '.rules[] | select(.RuleArn == "rule-100") | .Actions[0].ForwardConfig.TargetGroupStickinessConfig.DurationSeconds' "$FAKE_STATE") == 1 ]]; then
  ok "keeps each rule's stickiness"
else fail "keeps each rule's stickiness"; fi

# 5. running it again changes nothing
: >"$FAKE_CALLS"
"$script" >/dev/null 2>&1
if [[ $(modifies) -eq 0 ]]; then ok "is idempotent: a second run makes no modify call"
else fail "is idempotent: a second run makes no modify call ($(modifies))"; fi

# 6. a dry run reports and changes nothing
make_state no 0 100 0 100
out=$(DRY_RUN=true "$script" 2>&1); code=$?
if [[ $code -eq 0 && $(modifies) -eq 0 && $(mw rule rule-90) == 100 ]] && grep -q 'dry run: 3 change' <<<"$out"; then
  ok "a dry run reports three changes and makes none"
else fail "a dry run reports three changes and makes none"; printf '     %s\n' "${out//$'\n'/$'\n'     }"; fi

# 7. with TLS it works on the 443 listener, and leaves the redirect on 80 alone
make_state yes 10 90 50 50
"$script" >/dev/null 2>&1
if [[ $(mw listener "$L443") == 0 && $(mw rule rule-90) == 0 ]] && ! grep -q "modify-listener --listener-arn $L80" "$FAKE_CALLS"; then
  ok "serves the 443 listener when TLS is on and leaves the port 80 redirect"
else fail "serves the 443 listener when TLS is on and leaves the port 80 redirect"; fi

# 8. the output names no account ID or ARN
make_state no 50 50 50 50
out=$("$script" 2>&1)
if ! grep -qE '123456789012|arn:aws' <<<"${out//::add-mask::123456789012/}"; then ok "prints priorities and weights, not identifiers"
else fail "prints priorities and weights, not identifiers"; printf '     %s\n' "${out//$'\n'/$'\n'     }"; fi

if ((failures > 0)); then echo "$failures test(s) failed"; exit 1; fi
echo "all passed"
