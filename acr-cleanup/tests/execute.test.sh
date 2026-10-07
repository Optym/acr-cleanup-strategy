#!/usr/bin/env bash
#
# Unit tests for lib/execute.sh. ACR calls are stubbed and recorded through
# files, because the workers run in forked subshells.
#
#   ./tests/execute.test.sh

set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname -- "$TESTS_DIR")"

# shellcheck source=../lib/common.sh
source "${MODULE_DIR}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${MODULE_DIR}/lib/config.sh"
# shellcheck source=../lib/acr-api.sh
source "${MODULE_DIR}/lib/acr-api.sh"
# shellcheck source=../lib/execute.sh
source "${MODULE_DIR}/lib/execute.sh"

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
run_settings:
  parallel_delete_workers: 3
YAML

CALLS="${TMP_ROOT}/calls"
: > "$CALLS"

# Stubs. A tag containing "fails" fails; a manifest containing "retagged" is
# reported as tagged again by the pre-delete check; "gone" is a 404.
acr_untag() { printf 'untag %s %s\n' "$1" "$2" >> "$CALLS"; ACR_HTTP_STATUS=202; [[ "$2" != *fails* ]] || { ACR_HTTP_STATUS=403; return 1; }; }
acr_delete_manifest() { printf 'delete %s %s\n' "$1" "$2" >> "$CALLS"; ACR_HTTP_STATUS=202; return 0; }
acr_request() {
  # only the pre-delete manifest read reaches here
  local digest="${2##*/}"
  printf 'check %s\n' "$digest" >> "$CALLS"
  case "$digest" in
    *gone*)     ACR_HTTP_STATUS=404; ACR_HTTP_BODY=""; return 1 ;;
    *retagged*) ACR_HTTP_STATUS=200; ACR_HTTP_BODY='{"manifest":{"tags":["new-tag"],"changeableAttributes":{"deleteEnabled":true,"writeEnabled":true}}}'; return 0 ;;
    *locked*)   ACR_HTTP_STATUS=200; ACR_HTTP_BODY='{"manifest":{"tags":[],"changeableAttributes":{"deleteEnabled":false,"writeEnabled":true}}}'; return 0 ;;
    *)          ACR_HTTP_STATUS=200; ACR_HTTP_BODY='{"manifest":{"tags":[],"changeableAttributes":{"deleteEnabled":true,"writeEnabled":true}}}'; return 0 ;;
  esac
}

write_plan() {
  local work="$1"
  mkdir -p "$work"
  jq -n '{
    protection: { tags: 1, digests: 0 },
    untag: [ range(10) | { repository: "myproduct/api", tag: ("5.6.0-PullRequest\(.).1" + (if . == 4 then "-fails" else "" end)), digest: ("sha256:\(.)"), tag_group: "pull_request_builds", age_days: (100 - .), size: 10 } ],
    manifests: [
      { repository: "myproduct/api", digest: "sha256:ok-1",     age_days: 30, size: 100 },
      { repository: "myproduct/api", digest: "sha256:ok-2",     age_days: 30, size: 100 },
      { repository: "myproduct/api", digest: "sha256:retagged", age_days: 30, size: 100 },
      { repository: "myproduct/api", digest: "sha256:locked",   age_days: 30, size: 100 },
      { repository: "myproduct/api", digest: "sha256:gone",     age_days: 30, size: 100 }
    ]
  }' > "${work}/plan.json"
}

run_execute() {   # work_dir mode [--set ...]
  local work="$1" mode="$2"; shift 2
  ( config_init --file "${TMP_ROOT}/config.yaml" --work-dir "$work" "$@" >/dev/null 2>&1 \
      && execute_run "$work" "$mode" ) >/dev/null 2>&1
}

status_count() { jq --arg s "$1" '[ .items[] | select(.status == $s) ] | length' "$2/delete-result.json"; }

echo "execute: dry run"
W="${TMP_ROOT}/dry"
write_plan "$W"
: > "$CALLS"
run_execute "$W" untag --set run_settings.dry_run=true; RC=$?
check_equals "dry run succeeds" "0" "$RC"
check_equals "dry run makes no ACR calls" "0" "$(wc -l < "$CALLS" | tr -d ' ')"
check_equals "every candidate is reported as dry-run" "10" "$(status_count dry-run "$W")"
check_equals "dry-run total" "10" "$(jq '.totals.dry_run' "${W}/delete-result.json")"
check_equals "operation is recorded" "untag" "$(jq -r '.operation' "${W}/delete-result.json")"

echo "execute: untag"
W="${TMP_ROOT}/untag"
write_plan "$W"
: > "$CALLS"
run_execute "$W" untag --set run_settings.dry_run=false; RC=$?
check_equals "a failed item makes the stage return non-zero" "1" "$RC"
check_equals "every candidate was attempted" "10" "$(grep -c '^untag ' "$CALLS")"
check_equals "successful untags are recorded" "9" "$(status_count untagged "$W")"
check_equals "failed untag is recorded" "1" "$(status_count failed "$W")"
check_equals "failed item carries the HTTP status" \
  "403" "$(jq -r '.failed[0].http_status' "${W}/delete-result.json")"
check_equals "digest is kept on every item for the recovery catalogue" \
  "10" "$(jq '[ .items[] | select(.digest | startswith("sha256:")) ] | length' "${W}/delete-result.json")"
check_equals "bytes are summed over successes" "90" "$(jq '.totals.bytes' "${W}/delete-result.json")"
check_equals "no manifest is deleted during an untag run" "0" "$(grep -c '^delete ' "$CALLS")"

echo "execute: circuit breaker"
W="${TMP_ROOT}/cap"
write_plan "$W"
: > "$CALLS"
run_execute "$W" untag --set run_settings.dry_run=false --set run_settings.max_deletions_per_run=4; RC=$?
check_equals "only the cap is attempted" "4" "$(grep -c '^untag ' "$CALLS")"
check_equals "the rest is reported as over-cap" "6" "$(status_count skipped:over-cap "$W")"
check_equals "over-cap total" "6" "$(jq '.totals.over_cap' "${W}/delete-result.json")"
# Workers interleave, so check the set that was attempted rather than the order.
check_equals "the oldest candidates go first" \
  "5.6.0-PullRequest0.1 5.6.0-PullRequest1.1 5.6.0-PullRequest2.1 5.6.0-PullRequest3.1" \
  "$(jq -r '[ .items[] | select(.status != "skipped:over-cap") | .tag ] | sort | join(" ")' "${W}/delete-result.json")"

echo "execute: manifest sweep"
W="${TMP_ROOT}/sweep"
write_plan "$W"
: > "$CALLS"
run_execute "$W" manifests --set run_settings.dry_run=false; RC=$?
check_equals "sweep succeeds when nothing fails" "0" "$RC"
check_equals "every manifest is re-read before deletion" "5" "$(grep -c '^check ' "$CALLS")"
check_equals "still-untagged manifests are deleted" "2" "$(grep -c '^delete ' "$CALLS")"
check_equals "manifests re-tagged or locked since the plan are skipped" \
  "2" "$(status_count skipped:changed-since-plan "$W")"
check_equals "a manifest re-tagged since the plan is not deleted" \
  "0" "$(grep -c '^delete myproduct/api sha256:retagged$' "$CALLS")"
check_equals "a manifest locked since the plan is skipped" \
  "0" "$(grep -c '^delete myproduct/api sha256:locked$' "$CALLS")"
check_equals "an already-deleted manifest is reported as gone" "1" "$(status_count already-gone "$W")"
check_equals "no tag is touched during a sweep" "0" "$(grep -c '^untag ' "$CALLS")"

echo "execute: refuses an empty protection set"
W="${TMP_ROOT}/empty"
write_plan "$W"
jq '.protection = { tags: 0, digests: 0 }' "${W}/plan.json" > "${W}/p.json" && mv "${W}/p.json" "${W}/plan.json"
: > "$CALLS"
if run_execute "$W" untag --set run_settings.dry_run=false; then
  fail_test "plan with an empty protection set is refused"
else
  pass "plan with an empty protection set is refused"
fi
check_equals "nothing was called" "0" "$(wc -l < "$CALLS" | tr -d ' ')"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
