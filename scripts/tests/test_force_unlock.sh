#!/usr/bin/env bash
# Tests scripts/force-unlock.sh against fake `aws` and `terraform` programs, so no credentials are
# needed. Run: scripts/tests/test_force_unlock.sh
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/force-unlock.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/tf"

cat >"$work/bin/aws" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "sts get-caller-identity"*) echo 123456789012 ;;
  "s3api get-object"*)
    out="${@: -1}"
    if [[ -n "${FAKE_LOCK_FILE:-}" && -f "$FAKE_LOCK_FILE" ]]; then cp "$FAKE_LOCK_FILE" "$out"; else exit 254; fi ;;
  *) echo "unexpected aws call: $*" >&2; exit 99 ;;
esac
EOF
cat >"$work/bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_CALLS"
EOF
chmod +x "$work/bin/aws" "$work/bin/terraform"

export PATH="$work/bin:$PATH"
export AWS_REGION=us-east-1 TF_DIR="$work/tf" FAKE_CALLS="$work/calls"

id=c8b34ca1-492e-821d-0265-fe71e200febf
other=11111111-2222-3333-4444-55555555555a
failures=0

# lock <file> <id> <created>
lock() {
  printf '{"ID":"%s","Operation":"OperationTypeApply","Info":"","Who":"runner@host","Version":"1.16.4","Created":"%s","Path":"bucket/key"}\n' \
    "$2" "$3" >"$1"
}

# check <name> <expected exit code> <"unlocked"|"untouched"> -- <args...>
check() {
  local name=$1 want=$2 effect=$3
  shift 4
  : >"$FAKE_CALLS"
  local out code
  out=$("$script" "$@" 2>&1)
  code=$?
  local unlocked=untouched
  grep -q 'force-unlock -force' "$FAKE_CALLS" && unlocked=unlocked
  if [[ $code -eq $want && $unlocked == "$effect" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: exit $code (want $want), $unlocked (want $effect)"
    printf '     %s\n' "${out//$'\n'/$'\n'     }"
    failures=$((failures + 1))
  fi
}

old=2026-10-09T17:24:19.41752531Z
now=$(date -u +%Y-%m-%dT%H:%M:%S.000000000Z)

unset FAKE_LOCK_FILE
check "rejects an ID that is not a UUID" 2 untouched -- "not-a-uuid"
check "does nothing when there is no lock object" 0 untouched -- "$id"

export FAKE_LOCK_FILE="$work/lock.json"
lock "$FAKE_LOCK_FILE" "$other" "$old"
check "refuses a lock held under a different ID" 1 untouched -- "$id"

lock "$FAKE_LOCK_FILE" "$id" "$now"
check "refuses a lock younger than the minimum age" 1 untouched -- "$id"

lock "$FAKE_LOCK_FILE" "$id" "$old"
check "removes an old lock with the matching ID" 0 unlocked -- "$id"

if grep -q "force-unlock -force $id" "$FAKE_CALLS"; then
  echo "ok   passes the lock ID to terraform"
else
  echo "FAIL passes the lock ID to terraform"
  failures=$((failures + 1))
fi

lock "$FAKE_LOCK_FILE" "$id" "$now"
export MIN_LOCK_AGE_MINUTES=0
check "removes a fresh lock when the minimum age is zero" 0 unlocked -- "$id"
unset MIN_LOCK_AGE_MINUTES

if ((failures > 0)); then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all passed"
