#!/usr/bin/env bash
# Delete every shipment and its proof-of-delivery files, and optionally seed five demo shipments.
# Run by the ShipTrack-ResetData SSM document on each legacy host in turn (ADR-0034); the document
# writes db/reset-data.sql to $RESET_DATA_SQL first. The database is private, and a legacy host is
# the one place a workflow can reach it from (legacy ADR-0011).
# Usage: reset-data.sh <delete-all-shipments> <pod-bucket> <yes|no>
#
# In this order, so that a failure leaves the database and the files agreeing as far as possible:
#   1. the database, in one transaction, as the application role;
#   2. the objects under pod/ in the proof-of-delivery bucket (every host sees the same bucket, so a
#      second host finds none);
#   3. the files in this host's local proof-of-delivery directory.
#
# Stop the live traffic and let the events queue drain first: an event for a shipment that is gone
# fails to apply, is retried, and ends in the dead-letter queue, which alarms.
#
# The password reaches psql through the environment, never a command line, and is never printed.
# Environment (for tests): RESET_DATA_SQL, POD_DIR, RDS_CA_BUNDLE.
set -euo pipefail

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

confirm=${1:?usage: reset-data.sh <delete-all-shipments> <pod-bucket> <yes|no>}
bucket=${2:?usage: reset-data.sh <delete-all-shipments> <pod-bucket> <yes|no>}
seed=${3:?usage: reset-data.sh <delete-all-shipments> <pod-bucket> <yes|no>}

[[ "$confirm" == delete-all-shipments ]] || die "refused: the first argument must be delete-all-shipments"
[[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "invalid bucket name"
[[ "$seed" == yes || "$seed" == no ]] || die "the third argument must be yes or no"

sql=${RESET_DATA_SQL:-/tmp/shiptrack-reset-data.sql}
pod_dir=${POD_DIR:-/var/lib/shiptrack/pod}
[[ -f "$sql" ]] || die "the reset SQL is missing"

work=$(mktemp -d)
chmod 700 "$work"
cleanup() { rm -rf "$work"; unset PGPASSWORD; }
trap cleanup EXIT

# The region comes from the instance: the SSM agent does not set one for the aws CLI.
if [[ -z "${AWS_DEFAULT_REGION:-}" ]]; then
  token=$(curl -sS --max-time 3 -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)
  AWS_DEFAULT_REGION=$(curl -sS --max-time 3 ${token:+-H "X-aws-ec2-metadata-token: $token"} \
    http://169.254.169.254/latest/meta-data/placement/region)
fi
export AWS_DEFAULT_REGION

# A PostgreSQL client and jq. The 17 client matches the server; 16 also works for this.
if ! command -v psql >/dev/null 2>&1; then
  dnf install -y postgresql17 jq >/dev/null 2>&1 || dnf install -y postgresql16 jq >/dev/null 2>&1 \
    || die "could not install a PostgreSQL client"
fi
command -v jq >/dev/null 2>&1 || dnf install -y jq >/dev/null 2>&1 || die "jq is not available"

# The connection verifies the server against the RDS certificate bundle.
bundle=${RDS_CA_BUNDLE:-$work/rds-bundle.pem}
if [[ ! -f "$bundle" ]]; then
  curl -fsSL --retry 3 -o "$bundle" https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
fi

# The application credentials: its secret holds the host, port, database, user, and password.
secret_arn=$(aws ssm get-parameter --name /shiptrack/platform/db_app_secret_arn \
  --query Parameter.Value --output text)
secret=$(aws secretsmanager get-secret-value --secret-id "$secret_arn" \
  --query SecretString --output text)
host=$(jq -r .host <<<"$secret")
port=$(jq -r '.port // 5432' <<<"$secret")
dbname=$(jq -r '.dbname // "shiptrack"' <<<"$secret")
user=$(jq -r .username <<<"$secret")
PGPASSWORD=$(jq -r .password <<<"$secret")
export PGPASSWORD
unset secret

# 1. The database
export PGSSLROOTCERT="$bundle"
psql -X -q -tA --single-transaction -v ON_ERROR_STOP=1 -v "seed=$seed" -f "$sql" \
  "host=$host port=$port dbname=$dbname user=$user sslmode=verify-full"

# 2. The documents in S3 (nothing in the database points at them any more). `aws s3 ls` exits 1
# with nothing on stderr when there is nothing under the prefix, which is what every host after the
# first sees; any other failure (a missing bucket exits 254) stops the run.
status=0
listing=$(aws s3 ls "s3://$bucket/pod/" --recursive 2>"$work/ls.err") || status=$?
if [[ "$status" -ne 0 && ( "$status" -ne 1 || -s "$work/ls.err" ) ]]; then
  die "could not list the proof-of-delivery bucket (exit $status)"
fi
objects=$(grep -c . <<<"$listing" || true)
if [[ "$objects" -gt 0 ]]; then
  aws s3 rm "s3://$bucket/pod/" --recursive --only-show-errors
fi
echo "RESET_DATA s3_objects_removed=$objects"

# 3. The files this host still holds
local_files=0
if [[ -d "$pod_dir" ]]; then
  local_files=$(find "$pod_dir" -type f | wc -l | tr -d ' ')
  find "$pod_dir" -mindepth 1 -delete
fi
echo "RESET_DATA local_files_removed=$local_files"
