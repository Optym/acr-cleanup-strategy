#!/usr/bin/env bash
#
# Unit tests for lib/report.sh and lib/notify-sendgrid.sh, driven end to end
# through classify -> lock-reconcile -> execute (all stubbed / dry-run) so the
# report is built from real stage output rather than a hand-written fixture.
#
#   ./tests/report.test.sh

set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname -- "$TESTS_DIR")"

# shellcheck source=../lib/common.sh
source "${MODULE_DIR}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${MODULE_DIR}/lib/config.sh"
# shellcheck source=../lib/acr-api.sh
source "${MODULE_DIR}/lib/acr-api.sh"
# shellcheck source=../lib/classify.sh
source "${MODULE_DIR}/lib/classify.sh"
# shellcheck source=../lib/lock-reconcile.sh
source "${MODULE_DIR}/lib/lock-reconcile.sh"
# shellcheck source=../lib/execute.sh
source "${MODULE_DIR}/lib/execute.sh"
# shellcheck source=../lib/report.sh
source "${MODULE_DIR}/lib/report.sh"
# shellcheck source=../lib/notify-sendgrid.sh
source "${MODULE_DIR}/lib/notify-sendgrid.sh"

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
never_delete:
  repositories:
    - { name: tools/kubectl, reason: "shared tooling image" }
image_cleanup_rules:
  - tag_group: pull_request_builds
    tag_pattern: '^[0-9]+\.[0-9]+\.[0-9]+-PullRequest[0-9]+\.'
    delete_when_older_than_days: 7
    always_keep_newest: 1
  - tag_group: release_builds
    tag_pattern: '^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+'
    delete_when_older_than_days: 180
    always_keep_newest: 10
in_use_protection:
  clusters:
    - name: test-aks
      resource_group: test-rg
      service_connection: sc-test
run_settings:
  parallel_delete_workers: 2
email_report:
  enabled: true
  from: noreply@example.com
  to: [ one@example.com, two@example.com ]
YAML

WORK="${TMP_ROOT}/work"
config_init --file "${TMP_ROOT}/config.yaml" --work-dir "$WORK" --set run_settings.dry_run=false >/dev/null 2>&1 \
  || { echo "test setup failed: config did not load"; exit 1; }

ts() { date -u -v-"$1"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "$1 days ago" '+%Y-%m-%dT%H:%M:%SZ'; }

jq -n --arg t1 "$(ts 1)" --arg t30 "$(ts 30)" --arg t60 "$(ts 60)" --arg t400 "$(ts 400)" '{
  generated_at: "2026-09-04T00:00:00Z", registry: "testacr",
  repositories: [
    { repository: "myproduct/api",
      tags: [
        { name: "5.6.0-PullRequest1.1", digest: "sha256:a", created: $t1,  modified: $t1,  write_enabled: true, delete_enabled: true },
        { name: "5.6.0-PullRequest2.1", digest: "sha256:b", created: $t30, modified: $t30, write_enabled: true, delete_enabled: true },
        { name: "5.6.0-PullRequest3.1", digest: "sha256:c", created: $t60, modified: $t60, write_enabled: true, delete_enabled: true },
        { name: "5.6.0-PullRequest4.1", digest: "sha256:d", created: $t60, modified: $t60, write_enabled: true, delete_enabled: false },
        { name: "5.5.0-beta.1-1",       digest: "sha256:e", created: $t60, modified: $t60, write_enabled: true, delete_enabled: true }
      ],
      manifests: [
        { digest: "sha256:a", tags: ["5.6.0-PullRequest1.1"], created: $t1, modified: $t1, size: 100, media_type: "m", references: [], write_enabled: true, delete_enabled: true },
        { digest: "sha256:b", tags: ["5.6.0-PullRequest2.1"], created: $t30, modified: $t30, size: 100, media_type: "m", references: [], write_enabled: true, delete_enabled: true },
        { digest: "sha256:c", tags: ["5.6.0-PullRequest3.1"], created: $t60, modified: $t60, size: 100, media_type: "m", references: [], write_enabled: true, delete_enabled: true },
        { digest: "sha256:d", tags: ["5.6.0-PullRequest4.1"], created: $t60, modified: $t60, size: 100, media_type: "m", references: [], write_enabled: true, delete_enabled: false },
        { digest: "sha256:e", tags: ["5.5.0-beta.1-1"], created: $t60, modified: $t60, size: 100, media_type: "m", references: [], write_enabled: true, delete_enabled: true },
        { digest: "sha256:orphan", tags: [], created: $t60, modified: $t60, size: 500, media_type: "m", references: [], write_enabled: true, delete_enabled: true }
      ] },
    { repository: "tools/kubectl",
      tags: [ { name: "1.31.8", digest: "sha256:k", created: $t400, modified: $t400, write_enabled: true, delete_enabled: true } ],
      manifests: [ { digest: "sha256:k", tags: ["1.31.8"], created: $t400, modified: $t400, size: 100, media_type: "m", references: [], write_enabled: true, delete_enabled: true } ] }
  ],
  totals: {}
}' > "${WORK}/inventory.json"

jq -n '{
  generated_at: "2026-09-04T00:00:00Z", registry: "testacr",
  clusters: [ { cluster: "test-aks", resource_group: "test-rg", required: true, status: "ok", error: null, entry_count: 1 },
              { cluster: "test-aks-2", resource_group: "test-rg", required: false, status: "unreachable", error: "could not list pods", entry_count: 0 } ],
  protected_tags: [ { repository: "myproduct/api", tag: "5.5.0-beta.1-1" } ],
  protected_digests: [],
  sources: [
    { repository: "myproduct/api", tag: "5.5.0-beta.1-1", cluster: "test-aks", namespace: "prod", source: "pod", detail: "running" },
    { repository: "myproduct/api", tag: "5.4.0-beta.1-1", cluster: "test-aks", namespace: "prod", source: "helm-history", detail: "prod/api@rev5" }
  ],
  suspect_hosts: [ { host: "testacr.westus2.data.azurecr.io", repository: "myproduct/api", cluster: "test-aks" } ],
  unlisted_clusters: [ { name: "test-aks-3", resource_group: "test-rg", location: "eastus" } ]
}' > "${WORK}/protection-set.json"

# Stubs for the mutating stages.
acr_untag() { ACR_HTTP_STATUS=202; return 0; }
acr_set_tag_attributes() { return 0; }
acr_set_manifest_attributes() { return 0; }

mkdir -p "${WORK}/previous"
jq -n '{ run: { generated_at: "2026-08-28T17:30:00Z", operation: "untag" }, registry: { after: { tags: 10, manifests: 12, bytes: 5000000000 } } }' \
  > "${WORK}/previous/result.json"

echo "report: pipeline through classify, lock-reconcile, execute"
( classify_run "$WORK" && lock_reconcile_run "$WORK" && execute_run "$WORK" untag ) >/dev/null 2>"${TMP_ROOT}/stages.err" \
  || { echo "stages failed:"; tail -20 "${TMP_ROOT}/stages.err"; exit 1; }
report_record_error "$WORK" "execute" "simulated stage error"

STARTED=$(( $(date -u +%s) - 90 ))
( report_run "$WORK" untag "${WORK}/previous" "$STARTED" 4000000000 3900000000 ) >/dev/null 2>"${TMP_ROOT}/report.err" \
  || { echo "report_run failed:"; tail -20 "${TMP_ROOT}/report.err"; exit 1; }

R="${WORK}/result.json"
check_equals "result.json is valid JSON" "true" "$(jq -e '.' "$R" >/dev/null 2>&1 && echo true || echo false)"
check_equals "run header carries the operation" "untag" "$(jq -r '.run.operation' "$R")"
check_equals "run status reflects a recorded stage error" "failed" "$(jq -r '.run.status' "$R")"
check_equals "stage errors are listed" "simulated stage error" "$(jq -r '.errors[0].message' "$R")"
check_equals "duration is measured from the start" "true" "$(jq '.run.duration_seconds >= 90' "$R")"
check_equals "config hash is present" "64" "$(jq -r '.run.config_hash | length' "$R")"

echo "report: registry summary"
check_equals "tags before" "6" "$(jq '.registry.before.tags' "$R")"
check_equals "tags after subtracts successful untags" "4" "$(jq '.registry.after.tags' "$R")"
check_equals "manifests are unchanged by an untag run" "7" "$(jq '.registry.after.manifests' "$R")"
check_equals "storage before is read from usage" "4000000000" "$(jq '.registry.before.bytes' "$R")"
check_equals "storage after is read from usage" "3900000000" "$(jq '.registry.after.bytes' "$R")"
check_equals "delta vs previous run" "-6" "$(jq '.registry.delta_vs_previous.tags' "$R")"
check_equals "byte delta vs previous run" "-1100000000" "$(jq '.registry.delta_vs_previous.bytes' "$R")"

echo "report: repositories"
check_equals "cleaned repository shows deletions" \
  "2" "$(jq '.repositories[] | select(.repository == "myproduct/api") | .deleted' "$R")"
check_equals "tags after per repository" \
  "3" "$(jq '.repositories[] | select(.repository == "myproduct/api") | .tags_after' "$R")"
check_equals "never-deleted repository is flagged" \
  "true" "$(jq '.repositories[] | select(.repository == "tools/kubectl") | .never_delete' "$R")"
check_equals "never-deleted repository has no deletions" \
  "0" "$(jq '.repositories[] | select(.repository == "tools/kubectl") | .deleted' "$R")"

echo "report: deleted items and skip reasons"
check_equals "deleted items carry their digest" \
  "sha256:b sha256:c" "$(jq -r '[ .deleted.items[].digest ] | sort | join(" ")' "$R")"
check_equals "deleted bytes are summed" "200" "$(jq '.deleted.bytes' "$R")"
check_equals "protected count" "1" "$(jq '.skipped.tags_by_reason.protected' "$R")"
check_equals "locked count" "1" "$(jq '.skipped.tags_by_reason.locked' "$R")"
check_equals "never-delete count" "1" "$(jq '.skipped.tags_by_reason["never-delete:repository"]' "$R")"
check_equals "protected sample names the cluster" \
  "protected:cluster=test-aks" "$(jq -r '.skipped.samples.protected[0].detail' "$R")"

echo "report: locks and cluster warnings"
check_equals "lock stage ran" "true" "$(jq '.locks.ran' "$R")"
check_equals "the still-tagged locked manifest waits on its first sighting" "1" "$(jq '.locks.waiting | length' "$R")"
check_equals "the locked tag is already past its own retention, so it unlocks on the very first run, no ledger needed" \
  "1" "$(jq '[ .locks.unlocked[] | select(.kind == "tag" and .unlock_basis == "already_past_retention") ] | length' "$R")"
check_equals "locks.totals distinguishes an immediate unlock from a waited one" \
  "1" "$(jq '.locks.totals.unlocked_immediately' "$R")"
check_equals "executive summary surfaces the stale lock backlog" \
  "true" "$(jq '.summary.locked_stale_tags >= 1' "$R")"
check_equals "unreachable optional cluster is a warning" \
  "test-aks-2" "$(jq -r '.cluster_warnings.unreachable[0].cluster' "$R")"
check_equals "unlisted cluster is a warning" \
  "test-aks-3" "$(jq -r '.cluster_warnings.unlisted_clusters[0].name' "$R")"
check_equals "suspect host is a warning" \
  "testacr.westus2.data.azurecr.io" "$(jq -r '.cluster_warnings.suspect_hosts[0].host' "$R")"
check_equals "warnings are rendered as text" "3" "$(jq '.warnings | length' "$R")"

echo "report: deployments (cluster/namespace/deployed/protected-previous)"
check_equals "validation is null when --validate-after was not used" "null" "$(jq '.validation' "$R")"
check_equals "one deployment group for test-aks/prod/myproduct-api" \
  "1" "$(jq '[.protection.deployments[] | select(.cluster=="test-aks" and .namespace=="prod" and .repository=="myproduct/api")] | length' "$R")"
check_equals "deployed version is the running tag" \
  "5.5.0-beta.1-1" "$(jq -r '.protection.deployments[] | select(.repository=="myproduct/api") | .deployed[0]' "$R")"
check_equals "older helm-history tag stays protected as a previous version" \
  "5.4.0-beta.1-1" "$(jq -r '.protection.deployments[] | select(.repository=="myproduct/api") | .protected_previous[0]' "$R")"

echo "report: html"
HS="${WORK}/report-summary.html"
HD="${WORK}/report-deleted.html"
HP="${WORK}/report-protected.html"
check_equals "summary html is written" "true" "$([[ -s "$HS" ]] && echo true || echo false)"
check_equals "deleted html is written" "true" "$([[ -s "$HD" ]] && echo true || echo false)"
check_equals "protected html is written" "true" "$([[ -s "$HP" ]] && echo true || echo false)"
check_equals "summary html has every section" "5" "$(grep -o '<h2>[0-9]\. ' "$HS" | wc -l | tr -d ' ')"
check_equals "deleted html has every section" "3" "$(grep -o '<h2>[0-9]\. ' "$HD" | wc -l | tr -d ' ')"
check_equals "protected html has every section" "3" "$(grep -o '<h2>[0-9]\. ' "$HP" | wc -l | tr -d ' ')"
check_equals "deleted html lists a deleted tag" "1" "$(grep -c '5.6.0-PullRequest2.1' "$HD" | head -1)"
check_equals "summary html shows the failure badge" "1" "$(grep -c 'badge bad' "$HS")"
check_equals "summary html escapes markup in data" "0" "$(grep -c '<script' "$HS")"
check_equals "deleted html escapes markup in data" "0" "$(grep -c '<script' "$HD")"
check_equals "protected html escapes markup in data" "0" "$(grep -c '<script' "$HP")"
check_equals "protected html shows the deployed version" "1" "$(grep -c '5.5.0-beta.1-1' "$HP")"
check_equals "protected html shows the protected previous version" "1" "$(grep -c '5.4.0-beta.1-1' "$HP")"
check_equals "the three reports cross-link each other" "true" \
  "$(grep -q 'report-deleted.html' "$HS" && grep -q 'report-summary.html' "$HD" && grep -q 'report-summary.html' "$HP" && echo true || echo false)"

# KEEP_REPORT=<dir> copies the three rendered HTML files out for a visual check.
if [[ -n "${KEEP_REPORT:-}" ]]; then
  mkdir -p "$KEEP_REPORT"
  cp "$HS" "$HD" "$HP" "$KEEP_REPORT"/
fi

echo "report: dry run rendering"
DRY="${TMP_ROOT}/dry"
mkdir -p "$DRY"
cp "${WORK}/inventory.json" "${WORK}/protection-set.json" "$DRY/"
( config_init --file "${TMP_ROOT}/config.yaml" --work-dir "$DRY" >/dev/null 2>&1 \
    && classify_run "$DRY" && execute_run "$DRY" untag && report_run "$DRY" untag ) >/dev/null 2>&1 \
  || { echo "dry-run pipeline failed"; exit 1; }
check_equals "dry run status is ok" "ok" "$(jq -r '.run.status' "${DRY}/result.json")"
check_equals "dry run deletes nothing" "0" "$(jq '.deleted.count' "${DRY}/result.json")"
check_equals "dry run lists what it would delete" "2" "$(jq '.execution.dry_run_items | length' "${DRY}/result.json")"
check_equals "dry run html says so" "1" "$(grep -c 'Would be deleted (dry run)' "${DRY}/report-deleted.html")"
check_equals "no previous run is handled" "null" "$(jq '.registry.delta_vs_previous' "${DRY}/result.json")"

echo "report: opt-in post-cleanup validation (--validate-after)"
jq -n '{
  generated_at: "2026-09-04T00:00:00Z", skip_discover: true,
  totals: { checked: 5, ok: 4, broken: 1, unreadable: 0 },
  items: [ { status: "BROKEN", repository: "myproduct/api", tag: "5.5.0-beta.1-1", digest: "sha256:e", clusters: "test-aks", reason: "manifest-not-found" } ]
}' > "${DRY}/validation-result.json"
( report_run "$DRY" untag ) >/dev/null 2>&1 || { echo "report_run (validation) failed"; exit 1; }
check_equals "validation totals surface in result.json" "1" "$(jq '.validation.totals.broken' "${DRY}/result.json")"
check_equals "protected html renders the validation item" "1" "$(grep -c 'manifest-not-found' "${DRY}/report-protected.html")"
check_equals "summary html flags the validation status" "1" "$(grep -c 'Post-cleanup validation' "${DRY}/report-summary.html")"
rm -f "${DRY}/validation-result.json"

echo "notify: sendgrid payload"
# Fake curl that records the payload and answers 202.
FAKE_BIN="${TMP_ROOT}/bin"
mkdir -p "$FAKE_BIN"
cat > "${FAKE_BIN}/curl" <<'SH'
#!/usr/bin/env bash
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "--data-binary" ]]; then j=$((i + 1)); cp "${!j#@}" "${FAKE_PAYLOAD}"; fi
done
printf '202'
SH
chmod +x "${FAKE_BIN}/curl"
export FAKE_PAYLOAD="${TMP_ROOT}/payload.json"

export SENDGRID_API_KEY="SG.fake"
if ( PATH="${FAKE_BIN}:${PATH}" notify_sendgrid_run "$WORK" ) >/dev/null 2>&1; then
  pass "notify succeeds on 202"
else
  fail_test "notify succeeds on 202"
fi
check_equals "payload addresses every recipient" "2" "$(jq '.personalizations[0].to | length' "$FAKE_PAYLOAD")"
check_equals "subject names the registry and operation" \
  "true" "$(jq -r '.subject | startswith("[ACR cleanup] testacr untag")' "$FAKE_PAYLOAD")"
check_equals "subject flags a failed run" "true" "$(jq -r '.subject | endswith("FAILED")' "$FAKE_PAYLOAD")"
check_equals "html report is the body" "text/html" "$(jq -r '.content[0].type' "$FAKE_PAYLOAD")"
check_equals "result.json is attached" "application/json" "$(jq -r '.attachments[0].type' "$FAKE_PAYLOAD")"

unset SENDGRID_API_KEY
if ( PATH="${FAKE_BIN}:${PATH}" notify_sendgrid_run "$WORK" ) >/dev/null 2>&1; then
  fail_test "missing API key is reported"
else
  pass "missing API key is reported"
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
