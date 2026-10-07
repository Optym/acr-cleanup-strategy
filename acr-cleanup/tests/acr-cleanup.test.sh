#!/usr/bin/env bash
#
# Integration tests for acr-cleanup.sh itself, run as a subprocess with a fake
# `az` on PATH (kubectl/helm are never reached because these fixtures skip
# discovery). Covers what the unit suites cannot: that the orchestrator wires
# the stages together correctly end to end, and that --previous-dir carries
# forward automatically between runs against the same --work-dir.
#
#   ./tests/acr-cleanup.test.sh

set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname -- "$TESTS_DIR")"
SCRIPT="${MODULE_DIR}/acr-cleanup.sh"

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

# A fake az: login returns a token, show-usage returns a fixed number. Nothing
# else in this suite reaches az (discovery is always --skip-discover).
FAKE_BIN="${TMP_ROOT}/bin"
mkdir -p "$FAKE_BIN"
cat > "${FAKE_BIN}/az" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"acr login"*)     echo '{"loginServer":"testacr.azurecr.io","accessToken":"fake"}' ;;
  *"show-usage"*)    echo 4000000000 ;;
  *) echo "fake az: unexpected invocation: $*" >&2; exit 1 ;;
esac
SH
chmod +x "${FAKE_BIN}/az"
export PATH="${FAKE_BIN}:${PATH}"

cat > "${TMP_ROOT}/config.yaml" <<'YAML'
registry:
  name: testacr
  resource_group: test-rg
  subscription_id: 00000000-0000-0000-0000-000000000000
image_cleanup_rules:
  - tag_group: pull_request_builds
    tag_pattern: '^[0-9]+\.[0-9]+\.[0-9]+-PullRequest[0-9]+\.'
    delete_when_older_than_days: 7
    always_keep_newest: 1
in_use_protection:
  clusters:
    - name: test-aks
      resource_group: test-rg
      service_connection: sc-test
YAML

ts() { date -u -v-"$1"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "$1 days ago" '+%Y-%m-%dT%H:%M:%SZ'; }

write_fixture() {   # work_dir
  local work="$1"
  mkdir -p "$work"
  jq -n --arg t1 "$(ts 1)" --arg t30 "$(ts 30)" '{
    generated_at: "x", registry: "testacr",
    repositories: [ { repository: "myproduct/api",
      tags: [
        { name: "5.6.0-PullRequest1.1", digest: "sha256:a", created: $t1, modified: $t1, write_enabled: true, delete_enabled: true },
        { name: "5.6.0-PullRequest2.1", digest: "sha256:b", created: $t30, modified: $t30, write_enabled: true, delete_enabled: true }
      ],
      manifests: [
        { digest: "sha256:a", tags: ["5.6.0-PullRequest1.1"], created: $t1, modified: $t1, size: 10, media_type: "m", references: [], write_enabled: true, delete_enabled: true },
        { digest: "sha256:b", tags: ["5.6.0-PullRequest2.1"], created: $t30, modified: $t30, size: 10, media_type: "m", references: [], write_enabled: true, delete_enabled: true }
      ] } ],
    totals: {}
  }' > "${work}/inventory.json"

  jq -n '{
    generated_at: "x", registry: "testacr",
    clusters: [ { cluster: "test-aks", status: "ok", required: true, error: null, entry_count: 0 } ],
    protected_tags: [], protected_digests: [ { repository: "myproduct/api", digest: "sha256:zzz-not-a-real-tag" } ],
    sources: [], suspect_hosts: [], unlisted_clusters: []
  }' > "${work}/protection-set.json"
}

echo "acr-cleanup: previous-dir carries forward automatically (local, default work-dir)"
WORK="${TMP_ROOT}/work"
write_fixture "$WORK"
"$SCRIPT" --config "${TMP_ROOT}/config.yaml" --work-dir "$WORK" --operation plan \
  --skip-discover --skip-inventory >/dev/null 2>"${TMP_ROOT}/run1.err"
RC=$?
check_equals "first plan run succeeds" "0" "$RC"
check_equals "the run has no previous to compare against yet" \
  "null" "$(jq '.registry.delta_vs_previous' "${WORK}/result.json")"
check_equals "the run rotates its own result into <work-dir>/previous automatically" \
  "true" "$([[ -f "${WORK}/previous/result.json" ]] && echo true || echo false)"
check_equals "the carried-forward result matches this run's" \
  "$(jq -c '.run.generated_at' "${WORK}/result.json")" "$(jq -c '.run.generated_at' "${WORK}/previous/result.json")"

# Second local run against the SAME work-dir, same default --previous-dir: it
# should see the first run as "previous" with zero extra flags or setup. This
# is the exact scenario the ledger/delta feature was silently broken for.
write_fixture "$WORK"
"$SCRIPT" --config "${TMP_ROOT}/config.yaml" --work-dir "$WORK" --operation plan \
  --skip-discover --skip-inventory >/dev/null 2>"${TMP_ROOT}/run2.err"
RC=$?
check_equals "second plan run succeeds" "0" "$RC"
check_equals "a second local run automatically sees the first run as previous" \
  "false" "$([[ "$(jq '.registry.delta_vs_previous' "${WORK}/result.json")" == "null" ]] && echo true || echo false)"

echo "acr-cleanup: previous-dir carries the lock ledger forward across local untag runs"
WORK2="${TMP_ROOT}/work2"
write_fixture "$WORK2"
"$SCRIPT" --config "${TMP_ROOT}/config.yaml" --work-dir "$WORK2" --operation untag-stale-tags \
  --skip-discover --skip-inventory --dry-run >/dev/null 2>"${TMP_ROOT}/run3.err"
RC=$?
check_equals "first dry-run untag succeeds" "0" "$RC"
check_equals "a lock ledger is produced" "true" "$([[ -f "${WORK2}/lock-ledger.json" ]] && echo true || echo false)"
check_equals "the ledger is carried into <work-dir>/previous without any extra flag" \
  "true" "$([[ -f "${WORK2}/previous/lock-ledger.json" ]] && echo true || echo false)"

echo "acr-cleanup: unknown operation is rejected; old names still work with a warning"
if "$SCRIPT" --config "${TMP_ROOT}/config.yaml" --operation bogus --work-dir "${TMP_ROOT}/badop" \
     >/dev/null 2>"${TMP_ROOT}/badop.err"; then
  fail_test "an unrecognised --operation is rejected"
else
  pass "an unrecognised --operation is rejected"
fi
check_equals "the error names the valid operations" \
  "1" "$(grep -c 'untag-stale-tags' "${TMP_ROOT}/badop.err")"

WORK3="${TMP_ROOT}/work3"
write_fixture "$WORK3"
"$SCRIPT" --config "${TMP_ROOT}/config.yaml" --work-dir "$WORK3" --operation untag \
  --skip-discover --skip-inventory --dry-run >/dev/null 2>"${TMP_ROOT}/run4.err"
RC=$?
check_equals "the old operation name 'untag' still works" "0" "$RC"
check_equals "using the old name prints a rename warning" \
  "1" "$(grep -c 'now untag-stale-tags' "${TMP_ROOT}/run4.err")"

# --repository (singular) shards the inventory operation for the pipeline. With
# any other operation it used to be dropped on the floor, and a "targeted"
# untag-and-sweep quietly inventoried the entire registry.
"$SCRIPT" --config "${TMP_ROOT}/config.yaml" --work-dir "${TMP_ROOT}/work5" \
  --operation untag-and-sweep --repository some/repo --print-config >/dev/null 2>"${TMP_ROOT}/run5.err"
check_equals "--repository with a cleanup operation is treated as --repositories" \
  "1" "$(grep -c 'treating it as --repositories some/repo' "${TMP_ROOT}/run5.err")"
"$SCRIPT" --config "${TMP_ROOT}/config.yaml" --work-dir "${TMP_ROOT}/work6" \
  --operation inventory --repository some/repo --print-config >/dev/null 2>"${TMP_ROOT}/run6.err"
check_equals "--repository with the inventory operation keeps its pipeline meaning" \
  "0" "$(grep -c 'treating it as --repositories' "${TMP_ROOT}/run6.err")"

# Ctrl+C has to stop the forked workers too: background subshells in a
# non-interactive shell ignore SIGINT, so without the handler they outlived
# the parent by however long the registry took to answer. The parent launched
# here is itself such a background subshell, so it cannot be sent INT from a
# test; TERM takes the identical handler path (a pipeline cancel sends TERM).
INT_LOG="${TMP_ROOT}/interrupt.log"
bash -c '
  source "'"${MODULE_DIR}"'/lib/common.sh"
  install_interrupt_handler
  ( sleep 31.7; echo child-finished >> "'"$INT_LOG"'" ) &
  ( sleep 31.7; echo child-finished >> "'"$INT_LOG"'" ) &
  echo ready > "'"$INT_LOG"'"
  wait
' 2>/dev/null &
PARENT=$!
until grep -q ready "$INT_LOG" 2>/dev/null; do sleep 0.1; done
sleep 0.3
# Anchored: the parent's and subshells' own command lines contain the string too.
check_equals "the workers are running before the interrupt" \
  "2" "$(pgrep -f '^sleep 31\.7$' | wc -l | tr -d ' ')"
kill -TERM "$PARENT"
wait "$PARENT" 2>/dev/null; RC=$?
sleep 0.5
check_equals "an interrupted run exits 130" "130" "$RC"
check_equals "an interrupted run leaves no worker behind" \
  "0" "$(pgrep -f '^sleep 31\.7$' | wc -l | tr -d ' ')"
check_equals "no worker ran to completion after the interrupt" \
  "0" "$(grep -c child-finished "$INT_LOG")"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
