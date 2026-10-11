#!/usr/bin/env bash
# Summarise the account's active Inspector findings, and the CRITICAL and HIGH Security Hub
# findings, as counts and finding titles. Run by .github/workflows/security-findings.yml with the
# read-only plan role.
# Usage: scripts/security-findings.sh
#
# This is the wave 0 exit criterion "Inspector shows no fixable CRITICAL or HIGH": it exits 1 when
# there is one. Security Hub is reported, not gated.
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

# All active Inspector findings, following the pagination token.
findings='[]'
token=""
while :; do
  args=(inspector2 list-findings --max-results 100
        --filter-criteria '{"findingStatus":[{"comparison":"EQUALS","value":"ACTIVE"}]}' --output json)
  [[ -n "$token" ]] && args+=(--next-token "$token")
  page=$(aws "${args[@]}")
  findings=$(jq -c --argjson page "$page" '. + ($page.findings // [])' <<<"$findings")
  token=$(jq -r '.nextToken // empty' <<<"$page")
  [[ -n "$token" ]] || break
done

total=$(jq 'length' <<<"$findings")
fixable=$(jq '[.[] | select(.severity == "CRITICAL" or .severity == "HIGH")
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
  echo "Total active: $total. **Fixable CRITICAL or HIGH: $fixable.**"
  if [[ "$fixable" -gt 0 ]]; then
    echo
    echo "Fixable CRITICAL and HIGH, by title:"
    echo
    echo "| Severity | Title | Resources |"
    echo "|---|---|---|"
    jq -r '[.[] | select(.severity == "CRITICAL" or .severity == "HIGH")
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

if [[ "$fixable" -gt 0 ]]; then
  echo "::error::$fixable fixable CRITICAL or HIGH Inspector finding(s)"
  exit 1
fi
