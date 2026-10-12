#!/usr/bin/env bash
# Exercise scripts/reset-data.sh against a fake aws, psql, and curl: the order of the steps, what it
# refuses, what it removes, and that the password never reaches a command line. Nothing contacts
# AWS and nothing is deleted on this machine outside a temporary directory. Needs jq.
# Usage: scripts/tests/test_reset_data.sh
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/reset-data.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected [$3] got [$2]"; fi; }

mkdir -p "$work/bin" "$work/pod/aa/bb"
export CALLS="$work/calls"
cat >"$work/bin/aws" <<'AWS'
#!/usr/bin/env bash
echo "aws $*" >>"$CALLS"
case "$1 $2" in
  "ssm get-parameter") echo "arn:aws:secretsmanager:us-east-1:123456789012:secret:shiptrack/dev/db/app-AbCdEf" ;;
  "secretsmanager get-secret-value")
    echo '{"username":"shiptrack_app","password":"s3cret-pw","host":"db.example.internal","port":5432,"dbname":"shiptrack"}' ;;
  "s3 ls")
    # Like the real CLI: exit 1 with nothing on stderr for an empty prefix, 254 for a service error.
    case "${FAKE_S3:-two}" in
      two) printf '2026-10-11 10:00:00 12 pod/a/b\n2026-10-11 10:00:01 12 pod/a/c\n' ;;
      none) exit 1 ;;
      error) echo "An error occurred (NoSuchBucket) when calling the ListObjectsV2 operation" >&2; exit 254 ;;
    esac ;;
esac
exit 0
AWS
cat >"$work/bin/psql" <<'PSQL'
#!/usr/bin/env bash
echo "psql $*" >>"$CALLS"
echo "password-in-env=${PGPASSWORD:-none}" >>"$CALLS"
echo "RESET_DATA deleted shipments=3 tracking_events=9 pod_documents=2 sla_alerts=1"
[[ -n "${FAKE_PSQL_FAILS:-}" ]] && exit 3
exit 0
PSQL
chmod +x "$work/bin/aws" "$work/bin/psql"
: >"$work/sql.sql"
: >"$work/bundle.pem"
echo x >"$work/pod/aa/bb/one"
echo y >"$work/pod/aa/two"

export PATH="$work/bin:$PATH" AWS_DEFAULT_REGION=us-east-1 RESET_DATA_SQL="$work/sql.sql" \
  POD_DIR="$work/pod" RDS_CA_BUNDLE="$work/bundle.pem"
: >"$CALLS"

out=$("$script" delete-all-shipments shiptrack-pod-test yes 2>&1)
check "a full run succeeds" "$?" "0"
check "it connects as the application role over verified TLS" \
  "$(grep -c 'host=db.example.internal port=5432 dbname=shiptrack user=shiptrack_app sslmode=verify-full' "$CALLS")" "1"
check "the seed flag reaches the SQL" "$(grep -c -- '-v seed=yes' "$CALLS")" "1"
check "the SQL runs in one transaction" "$(grep -c -- '--single-transaction' "$CALLS")" "1"
check "the password is in the environment, not on a command line" \
  "$(grep -c 'password-in-env=s3cret-pw' "$CALLS") $(grep -c 's3cret-pw' <(grep -v '^password-in-env=' "$CALLS"))" "1 0"
check "the password is never printed" "$(grep -c 's3cret-pw' <<<"$out")" "0"
check "it removes the objects under pod/ in the bucket" "$(grep -c 'aws s3 rm s3://shiptrack-pod-test/pod/ --recursive' "$CALLS")" "1"
check "it counts the objects it removes" "$(grep -c '^RESET_DATA s3_objects_removed=2$' <<<"$out")" "1"
check "it removes this host's local files" "$(grep -c '^RESET_DATA local_files_removed=2$' <<<"$out")" "1"
check "the local directory is empty and still there" "$(find "$work/pod" -mindepth 1 | wc -l | tr -d ' ') $([[ -d "$work/pod" ]] && echo dir)" "0 dir"
check "the database step comes before the S3 and file steps" \
  "$(grep -n -E '^psql|s3 rm' "$CALLS" | head -1 | grep -c psql)" "1"

# a failing database step stops everything after it
echo x >"$work/pod/keep"
: >"$CALLS"
FAKE_PSQL_FAILS=1 "$script" delete-all-shipments shiptrack-pod-test no >/dev/null 2>&1
check "a failing database step is an error" "$?" "3"
check "...and nothing is removed from S3" "$(grep -c 's3 rm' "$CALLS")" "0"
check "...or from the host" "$([[ -f "$work/pod/keep" ]] && echo kept)" "kept"

: >"$CALLS"
"$script" yes shiptrack-pod-test yes >/dev/null 2>&1
check "a wrong confirmation is refused" "$?" "1"
"$script" delete-all-shipments 'bad bucket;rm -rf /' yes >/dev/null 2>&1
check "a bucket name with shell characters is refused" "$?" "1"
"$script" delete-all-shipments shiptrack-pod-test maybe >/dev/null 2>&1
check "a seed value other than yes or no is refused" "$?" "1"
check "none of the refusals reached the database" "$(grep -c '^psql' "$CALLS")" "0"

# a host that finds nothing in S3 (every host after the first) carries on and cleans its own files
echo x >"$work/pod/again"
files=$(find "$work/pod" -type f | wc -l | tr -d ' ')
: >"$CALLS"
out=$(FAKE_S3=none "$script" delete-all-shipments shiptrack-pod-test yes 2>&1)
check "an empty bucket is not an error" "$?" "0"
check "...it reports zero objects" "$(grep -c '^RESET_DATA s3_objects_removed=0$' <<<"$out")" "1"
check "...it removes nothing from S3" "$(grep -c 's3 rm' "$CALLS")" "0"
check "...and still removes this host's files" "$(grep -c "^RESET_DATA local_files_removed=$files\$" <<<"$out")" "1"

# any other failure to list stops the run before the host's files are touched
echo x >"$work/pod/keep2"
: >"$CALLS"
FAKE_S3=error "$script" delete-all-shipments shiptrack-pod-test yes >/dev/null 2>&1
check "a listing error is an error" "$?" "1"
check "...and the host's files are kept" "$([[ -f "$work/pod/keep2" ]] && echo kept)" "kept"

rm "$work/sql.sql"
"$script" delete-all-shipments shiptrack-pod-test yes >/dev/null 2>&1
check "a missing SQL file is an error" "$?" "1"

if ((failures > 0)); then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
