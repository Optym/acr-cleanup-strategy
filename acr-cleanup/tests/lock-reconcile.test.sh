#!/usr/bin/env bash
#
# Unit tests for lib/lock-reconcile.sh. ACR calls are stubbed; the ledger
# round-trip and the unlock invariants are exercised on a fixture plan.
#
#   ./tests/lock-reconcile.test.sh

set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname -- "$TESTS_DIR")"

# shellcheck source=../lib/common.sh
source "${MODULE_DIR}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${MODULE_DIR}/lib/config.sh"
# shellcheck source=../lib/acr-api.sh
source "${MODULE_DIR}/lib/acr-api.sh"
# shellcheck source=../lib/lock-reconcile.sh
source "${MODULE_DIR}/lib/lock-reconcile.sh"

PASSED=0
FAILED=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

pass() { PASSED=$((PASSED + 1)); printf '  ok   %s\n' "$1"; }
fail_test() { FAILED=$((FAILED + 1)); printf '  FAIL %s\n' "$1"; }

check_equals() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$label"
  else
    fail_test "$label (expected '$expected', got '$actual')"
  fi
}

cat > "${TMP_ROOT}/config.yaml" <<'YAML'
registry:
  name: testacr
  resource_group: test-rg
  subscription_id: 00000000-0000-0000-0000-000000000000
image_cleanup_rules:
  - tag_group: pull_request_builds
    tag_pattern: '^[0-9]+\.[0-9]+\.[0-9]+-PullRequest[0-9]+\.'
    delete_when_older_than_days: 7
    always_keep_newest: 2
in_use_protection:
  clusters:
    - name: test-aks
      resource_group: test-rg
      service_connection: sc-test
image_lock:
  unlock_when_unused:
    enabled: true
    wait_days_before_unlocking: 14
YAML

# Stubbed ACR mutations, recorded to a file because workers may run in subshells.
CALLS="${TMP_ROOT}/calls"
: > "$CALLS"
acr_set_tag_attributes() { printf 'tag %s %s %s %s\n' "$@" >> "$CALLS"; [[ "$2" != *fails* ]]; }
acr_set_manifest_attributes() { printf 'manifest %s %s %s %s\n' "$@" >> "$CALLS"; return 0; }
ACR_HTTP_STATUS="500"

NOW="$(date -u +%s)"
DAYS_AGO_20=$((NOW - 20 * 86400))
DAYS_AGO_3=$((NOW - 3 * 86400))

write_plan() {
  local work="$1"
  mkdir -p "$work"
  jq -n '{
    protection: { tags: 1, digests: 1 },
    locks: {
      tags: [
        { repository: "myproduct/api", tag: "held-1",      digest: "sha256:h1", age_days: 100, protected: true,  protection: ["protected:cluster=test-aks"], never_unlock: false },
        { repository: "myproduct/api", tag: "pinned-1",    digest: "sha256:p1", age_days: 100, protected: false, protection: [], never_unlock: true },
        { repository: "myproduct/api", tag: "orphan-old",  digest: "sha256:o1", age_days: 300, protected: false, protection: [], never_unlock: false },
        { repository: "myproduct/api", tag: "orphan-new",  digest: "sha256:o2", age_days: 300, protected: false, protection: [], never_unlock: false },
        { repository: "myproduct/api", tag: "orphan-fails", digest: "sha256:o3", age_days: 300, protected: false, protection: [], never_unlock: false },
        { repository: "myproduct/api", tag: "orphan-first", digest: "sha256:o4", age_days: 300, protected: false, protection: [], never_unlock: false },
        { repository: "myproduct/api", tag: "stale-immediate", digest: "sha256:o5", age_days: 200, protected: false, protection: [], never_unlock: false, would_delete: true }
      ],
      manifests: [
        { repository: "myproduct/api", digest: "sha256:m-orphan", tags: [], age_days: 300, protected: false, protection: [], never_unlock: false },
        { repository: "myproduct/api", digest: "sha256:m-stale-immediate", tags: [], age_days: 200, protected: false, protection: [], never_unlock: false, would_sweep: true }
      ]
    }
  }' > "${work}/plan.json"
}

run_reconcile() {   # work_dir [--set ...]
  local work="$1"; shift
  ( config_init --file "${TMP_ROOT}/config.yaml" --work-dir "$work" "$@" >/dev/null 2>&1 \
      && lock_reconcile_run "$work" "${work}/previous" ) >/dev/null 2>&1
}

status_of() { jq -r --arg t "$1" '[ (.held[], .pinned[], .waiting[], .orphan[], .unlocked[], .failed[]) | select(.ref == $t) | .status ] | first // "absent"' "$2/lock-result.json"; }

echo "lock-reconcile: first run, no ledger"
W1="${TMP_ROOT}/run1"
write_plan "$W1"
run_reconcile "$W1" --set run_settings.dry_run=false; RC=$?
check_equals "first run succeeds" "0" "$RC"
check_equals "protected lock is held" "held" "$(status_of held-1 "$W1")"
check_equals "never_unlock lock is pinned" "pinned" "$(status_of pinned-1 "$W1")"
check_equals "orphan seen for the first time waits, whatever its age" "waiting" "$(status_of orphan-old "$W1")"
check_equals "orphan manifest waits too" "waiting" "$(status_of sha256:m-orphan "$W1")"
check_equals "on a first run, only the already-stale items unlock; the merely-young orphans wait" \
  "2" "$(wc -l < "$CALLS" | tr -d ' ')"
check_equals "ledger records every waiting orphan" "5" "$(jq '.entries | length' "${W1}/lock-ledger.json")"
check_equals "ledger does not record held locks" \
  "0" "$(jq '[ .entries[] | select(.ref == "held-1") ] | length' "${W1}/lock-ledger.json")"
check_equals "ledger does not record pinned locks" \
  "0" "$(jq '[ .entries[] | select(.ref == "pinned-1") ] | length' "${W1}/lock-ledger.json")"
check_equals "not_protected totals count every unprotected, unpinned lock" "7" "$(jq '.totals.not_protected' "${W1}/lock-result.json")"
check_equals "the per-status orphan bucket is empty when unlocking is enabled" "null" "$(jq '.totals.orphan' "${W1}/lock-result.json")"

echo "lock-reconcile: an orphan already past its own retention unlocks immediately, no ledger at all"
check_equals "a stale orphan tag unlocks on the very first run" "unlocked" "$(status_of stale-immediate "$W1")"
check_equals "its unlock reason is recorded as already past retention" \
  "already_past_retention" "$(jq -r '.unlocked[] | select(.ref == "stale-immediate") | .unlock_basis' "${W1}/lock-result.json")"
check_equals "the ACR call actually happened, no waiting" \
  "1" "$(grep -c '^tag myproduct/api stale-immediate true true$' "$CALLS")"
check_equals "totals count both the stale tag and the stale manifest as immediate unlocks" \
  "2" "$(jq '.totals.unlocked_immediately' "${W1}/lock-result.json")"
check_equals "a genuinely unlocked item does not linger in the next ledger" \
  "0" "$(jq '[ .entries[] | select(.ref == "stale-immediate") ] | length' "${W1}/lock-ledger.json")"
check_equals "a stale orphan manifest unlocks immediately too" "unlocked" "$(status_of sha256:m-stale-immediate "$W1")"
check_equals "the manifest unlock call happened" \
  "1" "$(grep -c '^manifest myproduct/api sha256:m-stale-immediate true true$' "$CALLS")"

echo "lock-reconcile: second run, ledger older than the wait"
W2="${TMP_ROOT}/run2"
write_plan "$W2"
mkdir -p "${W2}/previous"
jq -n --argjson old "$DAYS_AGO_20" --argjson new "$DAYS_AGO_3" '{
  entries: [
    { kind: "tag", repository: "myproduct/api", ref: "orphan-old",   first_unprotected_at: $old },
    { kind: "tag", repository: "myproduct/api", ref: "orphan-new",   first_unprotected_at: $new },
    { kind: "tag", repository: "myproduct/api", ref: "orphan-fails", first_unprotected_at: $old },
    { kind: "tag", repository: "myproduct/api", ref: "held-1",       first_unprotected_at: $old },
    { kind: "manifest", repository: "myproduct/api", ref: "sha256:m-orphan", first_unprotected_at: $old }
  ]
}' > "${W2}/previous/lock-ledger.json"
: > "$CALLS"
run_reconcile "$W2" --set run_settings.dry_run=false; RC=$?
check_equals "run reports the failed unlock via exit code" "1" "$RC"
check_equals "orphan past the wait is unlocked" "unlocked" "$(status_of orphan-old "$W2")"
check_equals "unlock sets both attributes back to true" \
  "1" "$(grep -c '^tag myproduct/api orphan-old true true$' "$CALLS")"
check_equals "orphan manifest past the wait is unlocked" "unlocked" "$(status_of sha256:m-orphan "$W2")"
check_equals "manifest unlock uses the manifest endpoint" \
  "1" "$(grep -c '^manifest myproduct/api sha256:m-orphan true true$' "$CALLS")"
check_equals "orphan inside the wait keeps waiting" "waiting" "$(status_of orphan-new "$W2")"
check_equals "orphan never seen before starts waiting now" "waiting" "$(status_of orphan-first "$W2")"
check_equals "a protected lock is held even if the ledger remembers it" "held" "$(status_of held-1 "$W2")"
check_equals "a protected lock is never unlocked" "0" "$(grep -c 'held-1' "$CALLS")"
check_equals "failed unlock is reported" "unlock-failed" "$(status_of orphan-fails "$W2")"
check_equals "failed unlock carries an error line" "1" "$(jq '.errors | length' "${W2}/lock-result.json")"
check_equals "unlocked items leave the ledger" \
  "0" "$(jq '[ .entries[] | select(.ref == "orphan-old") ] | length' "${W2}/lock-ledger.json")"
check_equals "waiting items keep their original first-seen time" \
  "$DAYS_AGO_3" "$(jq '.entries[] | select(.ref == "orphan-new") | .first_unprotected_at' "${W2}/lock-ledger.json")"
check_equals "failed unlocks stay in the ledger for the next run" \
  "1" "$(jq '[ .entries[] | select(.ref == "orphan-fails") ] | length' "${W2}/lock-ledger.json")"

echo "lock-reconcile: unlock-events.jsonl records every unlock attempt for debugging"
check_equals "one event line per unlock attempt (stale-immediate x2 + past-wait x2 + 1 failed)" \
  "5" "$(wc -l < "${W2}/unlock-events.jsonl" | tr -d ' ')"
check_equals "each line is valid, single-object JSON" \
  "5" "$(jq -s 'length' "${W2}/unlock-events.jsonl")"
check_equals "a real unlock is recorded with its status and a timestamp" \
  "unlocked" "$(jq -r 'select(.ref == "orphan-old") | .status' "${W2}/unlock-events.jsonl")"
check_equals "a failed unlock is recorded with its http status" \
  "500" "$(jq -r 'select(.ref == "orphan-fails") | .http_status' "${W2}/unlock-events.jsonl")"

echo "lock-reconcile: dry run"
W3="${TMP_ROOT}/run3"
write_plan "$W3"
mkdir -p "${W3}/previous"
cp "${W2}/previous/lock-ledger.json" "${W3}/previous/"
: > "$CALLS"
run_reconcile "$W3" --set run_settings.dry_run=true; RC=$?
check_equals "dry run succeeds" "0" "$RC"
check_equals "dry run makes no ACR calls" "0" "$(wc -l < "$CALLS" | tr -d ' ')"
check_equals "dry run reports what it would unlock" "unlock-dry-run" "$(status_of orphan-old "$W3")"
check_equals "dry-run unlocks stay in the ledger so the clock is not reset" \
  "$DAYS_AGO_20" "$(jq '.entries[] | select(.ref == "orphan-old") | .first_unprotected_at' "${W3}/lock-ledger.json")"
check_equals "dry-run attempts are recorded in the events file too" \
  "unlock-dry-run" "$(jq -r 'select(.ref == "orphan-old") | .status' "${W3}/unlock-events.jsonl")"

echo "lock-reconcile: disabled"
W4="${TMP_ROOT}/run4"
write_plan "$W4"
mkdir -p "${W4}/previous"
cp "${W2}/previous/lock-ledger.json" "${W4}/previous/"
: > "$CALLS"
run_reconcile "$W4" --set run_settings.dry_run=false --set image_lock.unlock_when_unused.enabled=false; RC=$?
check_equals "disabled run succeeds" "0" "$RC"
check_equals "disabled run unlocks nothing" "0" "$(wc -l < "$CALLS" | tr -d ' ')"
check_equals "orphans are still reported when disabled" "orphan" "$(status_of orphan-old "$W4")"
check_equals "disabled run still tracks first-seen time in the ledger" \
  "$DAYS_AGO_20" "$(jq '.entries[] | select(.ref == "orphan-old") | .first_unprotected_at' "${W4}/lock-ledger.json")"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
