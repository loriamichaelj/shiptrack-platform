#!/usr/bin/env bash
# Put all traffic back on legacy: weight legacy 100 and modern 0 on every weighted rule and on the
# listener's default action. Run by .github/workflows/ops-rollback-cutover.yml (break-glass, design §7).
# Usage: scripts/rollback-cutover.sh
#
# It changes the ALB directly, without a pull request, so the weights then differ from
# `var.cutover`. check-drift.yml reports that until a pull request sets `cutover` to match, which
# docs/runbooks/break-glass-rollback.md requires within 24 hours.
#
# Only rules that forward to both target groups are touched: the header rules for tests (one
# target group each) and the preview listener are left alone. Stickiness is preserved, because only
# the weights are rewritten. Running it again when traffic is already on legacy changes nothing.
#
# Nothing in the output names the account: it prints rule priorities and weights.
#
# Environment:
#   AWS_REGION      region of the ALB (required)
#   ALB_NAME        default shiptrack-alb
#   LEGACY_TG_NAME  default shiptrack-tg-legacy
#   MODERN_TG_NAME  default shiptrack-tg-modern
#   DRY_RUN         `true` shows what would change and changes nothing
set -euo pipefail

: "${AWS_REGION:?AWS_REGION is required}"
alb_name=${ALB_NAME:-shiptrack-alb}
legacy_name=${LEGACY_TG_NAME:-shiptrack-tg-legacy}
modern_name=${MODERN_TG_NAME:-shiptrack-tg-modern}
dry_run=${DRY_RUN:-false}

account=$(aws sts get-caller-identity --query Account --output text)
echo "::add-mask::$account"

lb_arn=$(aws elbv2 describe-load-balancers --names "$alb_name" --output json | jq -r '.LoadBalancers[0].LoadBalancerArn // empty')
legacy_arn=$(aws elbv2 describe-target-groups --names "$legacy_name" --output json | jq -r '.TargetGroups[0].TargetGroupArn // empty')
modern_arn=$(aws elbv2 describe-target-groups --names "$modern_name" --output json | jq -r '.TargetGroups[0].TargetGroupArn // empty')
for v in lb_arn legacy_arn modern_arn; do
  [[ -n "${!v}" ]] || { echo "::error::could not find ${v%_arn} ($alb_name, $legacy_name, $modern_name)"; exit 1; }
done

# The listener that serves traffic: 443 when TLS is on, otherwise 80. Never the preview port.
listeners=$(aws elbv2 describe-listeners --load-balancer-arn "$lb_arn" --output json)
listener_arn=$(jq -r '[.Listeners[] | select(.Port == 443)][0].ListenerArn // ([.Listeners[] | select(.Port == 80)][0].ListenerArn // empty)' <<<"$listeners")
[[ -n "$listener_arn" ]] || { echo "::error::the ALB has no listener on port 443 or 80"; exit 1; }

# Rewrite the weights of a forward action that has both target groups. Everything else in the
# action, including stickiness, is kept. The $legacy and $modern are jq variables, not shell ones.
# shellcheck disable=SC2016
reweight='map(
  if .Type == "forward" and ((.ForwardConfig.TargetGroups // []) | map(.TargetGroupArn) | (index($legacy) != null and index($modern) != null))
  then .ForwardConfig.TargetGroups |= map(
         if .TargetGroupArn == $legacy then .Weight = 100
         elif .TargetGroupArn == $modern then .Weight = 0
         else . end)
  else . end)'

weights() { # print "legacy N modern M" for an Actions array
  jq -r --arg legacy "$legacy_arn" --arg modern "$modern_arn" '
    [.[] | select(.Type == "forward") | .ForwardConfig.TargetGroups[]?] as $t
    | "legacy \([$t[] | select(.TargetGroupArn == $legacy) | .Weight][0] // "-") modern \([$t[] | select(.TargetGroupArn == $modern) | .Weight][0] // "-")"' <<<"$1"
}

changed=0

# The default action of the listener.
current=$(jq -c '.Listeners[] | select(.ListenerArn == $l) | .DefaultActions' --arg l "$listener_arn" <<<"$listeners")
updated=$(jq -c --arg legacy "$legacy_arn" --arg modern "$modern_arn" "$reweight" <<<"$current")
if [[ "$current" == "$updated" ]]; then
  echo "default action: already $(weights "$current")"
else
  echo "default action: $(weights "$current") -> $(weights "$updated")"
  changed=$((changed + 1))
  if [[ "$dry_run" != true ]]; then
    aws elbv2 modify-listener --listener-arn "$listener_arn" --default-actions "$updated" >/dev/null
  fi
fi

# The weighted rules (the UI rule and the track rule).
rules=$(aws elbv2 describe-rules --listener-arn "$listener_arn" --output json)
while IFS= read -r rule; do
  [[ -n "$rule" ]] || continue
  rule_arn=$(jq -r '.RuleArn' <<<"$rule")
  priority=$(jq -r '.Priority' <<<"$rule")
  current=$(jq -c '.Actions' <<<"$rule")
  updated=$(jq -c --arg legacy "$legacy_arn" --arg modern "$modern_arn" "$reweight" <<<"$current")
  if [[ "$current" == "$updated" ]]; then
    echo "rule $priority: already $(weights "$current")"
    continue
  fi
  echo "rule $priority: $(weights "$current") -> $(weights "$updated")"
  changed=$((changed + 1))
  if [[ "$dry_run" != true ]]; then
    aws elbv2 modify-rule --rule-arn "$rule_arn" --actions "$updated" >/dev/null
  fi
done < <(jq -c --arg legacy "$legacy_arn" --arg modern "$modern_arn" '
  .Rules[]
  | select(.IsDefault | not)
  | select([.Actions[] | select(.Type == "forward") | .ForwardConfig.TargetGroups[]?.TargetGroupArn] | (index($legacy) != null and index($modern) != null))' <<<"$rules")

if [[ "$dry_run" == true ]]; then
  echo "dry run: $changed change(s) would be made; nothing was changed"
  exit 0
fi

# Check it took: every weighted action now sends everything to legacy.
rules=$(aws elbv2 describe-rules --listener-arn "$listener_arn" --output json)
listeners=$(aws elbv2 describe-listeners --load-balancer-arn "$lb_arn" --output json)
bad=$(jq -r --arg legacy "$legacy_arn" --arg modern "$modern_arn" --arg l "$listener_arn" '
  def both: [.[] | select(.Type == "forward") | .ForwardConfig.TargetGroups[]?] as $t
            | ($t | map(.TargetGroupArn) | (index($legacy) != null and index($modern) != null));
  def modern_weight: [.[] | select(.Type == "forward") | .ForwardConfig.TargetGroups[]? | select(.TargetGroupArn == $modern) | .Weight][0];
  ([.[0].Rules[] | select(.IsDefault | not) | .Actions | select(both) | select(modern_weight != 0)] | length)
  + ([.[1].Listeners[] | select(.ListenerArn == $l) | .DefaultActions | select(both) | select(modern_weight != 0)] | length)' \
  <(jq -s '.' <<<"$rules"$'\n'"$listeners"))
if [[ "$bad" != 0 ]]; then
  echo "::error::$bad weighted action(s) still send traffic to modern"
  exit 1
fi
echo "done: $changed change(s); all weighted routing is legacy 100, modern 0"
