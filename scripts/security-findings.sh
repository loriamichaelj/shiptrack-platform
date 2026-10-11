#!/usr/bin/env bash
# Summarise the account's active Inspector findings, and the CRITICAL and HIGH Security Hub
# findings, as counts and finding titles. Run by .github/workflows/security-findings.yml with the
# read-only plan role.
# Usage: scripts/security-findings.sh
#
# This is the wave 0 exit criterion "Inspector shows no fixable CRITICAL or HIGH in deployed images":
# it exits 1 when modern's own resources have one (ADR-0029). Each finding is placed in a scope:
#   modern  an ECR repository named shiptrack/..., a node of the shiptrack EKS cluster, or a
#           resource tagged Stack=modern
#   legacy  a resource tagged Stack=legacy: the pinned AMI is a deliberate anti-pattern (AP-14), so
#           its findings are the "before" baseline, reported and not gated
#   other   everything else in the account, which this project does not own
# Security Hub is reported, not gated.
#
# The output has counts, severities, resource types, and public finding titles such as CVE ids and
# control names. It has no resource ARN, instance or image identifier, account ID, or address,
# because the log of a public repository is public.
#
# Environment:
#   AWS_REGION   required
set -euo pipefail

: "${AWS_REGION:?AWS_REGION is required}"

account=$(aws sts get-caller-identity --query Account --output text)
echo "::add-mask::$account"

# All active Inspector findings, following the pagination token. A page is large (a finding carries
# its whole package and remediation detail), so nothing here passes JSON on a command line, which
# the kernel limits; each page is cut down to the fields used and appended through files.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
echo '[]' >"$work/all.json"
token=""
while :; do
  args=(inspector2 list-findings --max-results 100
        --filter-criteria '{"findingStatus":[{"comparison":"EQUALS","value":"ACTIVE"}]}' --output json)
  [[ -n "$token" ]] && args+=(--next-token "$token")
  aws "${args[@]}" >"$work/page.json"
  jq -c '[(.findings // [])[] | (.resources[0] // {}) as $r
          | {severity, fixAvailable, title, resources: [{type: $r.type}], rid: $r.id,
             scope: (if (($r.details.awsEcrContainerImage.repositoryName // "") | startswith("shiptrack/"))
                        or (($r.tags["eks:cluster-name"] // "") == "shiptrack")
                        or (($r.tags.Stack // "") == "modern")
                     then "modern"
                     elif ($r.tags.Stack // "") == "legacy" then "legacy"
                     else "other" end),
             repo: (if (($r.details.awsEcrContainerImage.repositoryName // "") | startswith("shiptrack/"))
                    then $r.details.awsEcrContainerImage.repositoryName else null end)}]' \
    "$work/page.json" >"$work/slim.json"
  jq -sc '.[0] + .[1]' "$work/all.json" "$work/slim.json" >"$work/next.json"
  mv "$work/next.json" "$work/all.json"
  token=$(jq -r '.nextToken // empty' "$work/page.json")
  [[ -n "$token" ]] || break
done
findings=$(cat "$work/all.json")

total=$(jq 'length' <<<"$findings")
fixable=$(jq '[.[] | select(.severity == "CRITICAL" or .severity == "HIGH")
                   | select(.fixAvailable == "YES" or .fixAvailable == "PARTIAL")] | length' <<<"$findings")
fixable_modern=$(jq '[.[] | select(.scope == "modern")
                         | select(.severity == "CRITICAL" or .severity == "HIGH")
                         | select(.fixAvailable == "YES" or .fixAvailable == "PARTIAL")] | length' <<<"$findings")

{
  echo "### Inspector: active findings"
  echo
  echo "| Severity | Fix available | Count |"
  echo "|---|---|---|"
  jq -r 'group_by([.severity, (.fixAvailable // "UNKNOWN")])
         | map("| \(.[0].severity) | \(.[0].fixAvailable // "UNKNOWN") | \(length) |") | .[]' <<<"$findings"
  echo
  echo "By resource type:"
  echo
  echo "| Resource type | Count |"
  echo "|---|---|"
  jq -r 'group_by(.resources[0].type) | map("| \(.[0].resources[0].type // "unknown") | \(length) |") | .[]' <<<"$findings"
  echo
  echo "By scope (modern: a shiptrack/ ECR repository, a node of the shiptrack EKS cluster, or Stack=modern;"
  echo "legacy: Stack=legacy, a deliberate baseline; other: not this project's). Only modern is gated:"
  echo
  echo "| Scope | Resource type | Distinct resources | Fixable CRITICAL or HIGH | All active |"
  echo "|---|---|---|---|---|"
  jq -r 'group_by([.scope, .resources[0].type])
         | map("| \(.[0].scope) | \(.[0].resources[0].type // "unknown") | \([.[].rid] | unique | length) | \([.[] | select(.severity == "CRITICAL" or .severity == "HIGH") | select(.fixAvailable == "YES" or .fixAvailable == "PARTIAL")] | length) | \(length) |") | .[]' <<<"$findings"
  echo
  echo "Total active: $total. Fixable CRITICAL or HIGH in the account: $fixable."
  echo "**Fixable CRITICAL or HIGH in modern: $fixable_modern.**"
  if [[ "$fixable_modern" -gt 0 ]]; then
    echo
    echo "Fixable CRITICAL and HIGH in modern, by title:"
    echo
    echo "| Severity | Title | Findings |"
    echo "|---|---|---|"
    jq -r '[.[] | select(.scope == "modern")
                | select(.severity == "CRITICAL" or .severity == "HIGH")
                | select(.fixAvailable == "YES" or .fixAvailable == "PARTIAL")]
           | group_by(.title) | map("| \(.[0].severity) | \(.[0].title) | \(length) |") | .[]' <<<"$findings"
  fi
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

# Security Hub: CRITICAL and HIGH findings that are active and unresolved, by title. Reported, not
# gated, but an unreadable Security Hub must not look like an empty one.
filters='{"SeverityLabel":[{"Value":"CRITICAL","Comparison":"EQUALS"},{"Value":"HIGH","Comparison":"EQUALS"}],"RecordState":[{"Value":"ACTIVE","Comparison":"EQUALS"}],"WorkflowStatus":[{"Value":"NEW","Comparison":"EQUALS"},{"Value":"NOTIFIED","Comparison":"EQUALS"}],"ComplianceStatus":[{"Value":"FAILED","Comparison":"EQUALS"}]}'
hub_ok=true
hub=$(aws securityhub get-findings --max-items 500 --output json --filters "$filters" 2>/dev/null) || hub_ok=false
{
  echo
  echo "### Security Hub: CRITICAL and HIGH, failed and unresolved"
  echo
  if [[ "$hub_ok" != true ]]; then
    echo "Security Hub could not be read with this role. This is not the same as no findings."
  elif [[ "$(jq '.Findings | length' <<<"$hub")" -eq 0 ]]; then
    echo "None."
  else
    echo "| Severity | Control | Findings |"
    echo "|---|---|---|"
    jq -r '.Findings | group_by(.Title) | map("| \(.[0].Severity.Label) | \(.[0].Title) | \(length) |") | .[]' <<<"$hub"
  fi
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

if [[ "$fixable_modern" -gt 0 ]]; then
  echo "::error::$fixable_modern fixable CRITICAL or HIGH Inspector finding(s) in modern's resources"
  exit 1
fi
