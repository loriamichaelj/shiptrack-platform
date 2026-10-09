#!/usr/bin/env bash
# One-time GitHub settings for a ShipTrack repository (platform design §6.1 and §6.12). Run by a
# human with admin rights; needs an authenticated `gh`. Safe to re-run.
#
#   - environment `dev` (and `bootstrap` with --bootstrap-env): you are the required reviewer,
#     and only the `dev` branch may deploy to it
#   - branch protection on `dev`: changes arrive by pull request
#   - Actions: read-only default token, approval required for every outside contributor
#   - secret scanning and push protection on
#
# Usage: github-setup.sh [--dry-run] [--bootstrap-env] [--check NAME]... <owner>/<repo>
set -euo pipefail

dry_run=false
bootstrap_env=false
checks=()
repo=""
branch=dev

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=true ;;
    --bootstrap-env) bootstrap_env=true ;;
    --check) shift; checks+=("${1:?--check needs a name}") ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) repo=$1 ;;
  esac
  shift
done
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "usage: $0 [--dry-run] [--bootstrap-env] [--check NAME]... <owner>/<repo>" >&2; exit 2; }

failed=0
api() { # api <method> <path> <json-body>
  local method=$1 path=$2 body=$3
  if $dry_run; then
    printf 'gh api -X %s %s\n  %s\n' "$method" "$path" "$body"
    return 0
  fi
  if gh api -X "$method" "$path" --input - <<<"$body" >/dev/null; then
    echo "ok      $method $path"
  else
    echo "FAILED  $method $path" >&2
    failed=$((failed + 1))
  fi
}

user_id=$(gh api user --jq .id)

setup_environment() {
  local name=$1
  api PUT "repos/$repo/environments/$name" "$(jq -nc --argjson id "$user_id" '{
    wait_timer: 0,
    prevent_self_review: false,
    reviewers: [{type: "User", id: $id}],
    deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}
  }')"
  api POST "repos/$repo/environments/$name/deployment-branch-policies" \
    "$(jq -nc --arg b "$branch" '{name: $b, type: "branch"}')"
}

setup_environment dev
$bootstrap_env && setup_environment bootstrap

if [[ ${#checks[@]} -gt 0 ]]; then
  status_checks=$(printf '%s\n' "${checks[@]}" | jq -R . | jq -sc '{strict: false, contexts: .}')
else
  status_checks=null
fi
api PUT "repos/$repo/branches/$branch/protection" "$(jq -nc --argjson checks "$status_checks" '{
  required_status_checks: $checks,
  enforce_admins: false,
  required_pull_request_reviews: {required_approving_review_count: 0, dismiss_stale_reviews: true},
  restrictions: null,
  allow_force_pushes: false,
  allow_deletions: false,
  required_conversation_resolution: true
}')"

api PUT "repos/$repo/actions/permissions/workflow" \
  '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}'
api PUT "repos/$repo/actions/permissions/fork-pr-contributor-approval" \
  '{"approval_policy":"all_external_contributors"}'
api PATCH "repos/$repo" \
  '{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'

if [[ $failed -gt 0 ]]; then
  echo "$failed call(s) failed" >&2
  exit 1
fi
