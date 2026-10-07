#!/usr/bin/env bash
#
# Unit tests for lib/classify.sh: retention decisions from a fixture inventory
# and protection set. Pure: no Azure, no network, no cluster access.
#
#   ./tests/classify.test.sh

set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname -- "$TESTS_DIR")"

# shellcheck source=../lib/common.sh
source "${MODULE_DIR}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${MODULE_DIR}/lib/config.sh"
# shellcheck source=../lib/classify.sh
source "${MODULE_DIR}/lib/classify.sh"

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
  tag_patterns:
    - { pattern: '^latest$', reason: "floating tag" }
    - { pattern: '.*-donotdelete$', reason: "manual pin" }
image_cleanup_rules:
  - tag_group: legacy_inuse_markers
    tag_pattern: '-inUse$'
    delete_when_older_than_days: 0
    always_keep_newest: 0
  - tag_group: pull_request_builds
    tag_pattern: '^[0-9]+\.[0-9]+\.[0-9]+-PullRequest[0-9]+\.'
    delete_when_older_than_days: 7
    always_keep_newest: 2
  - tag_group: release_builds
    tag_pattern: '^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+'
    delete_when_older_than_days: 180
    always_keep_newest: 10
  - tag_group: develop_builds
    tag_pattern: '^[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+'
    delete_when_older_than_days: 45
    always_keep_newest: 3
in_use_protection:
  min_untagged_manifest_age_days: 14
  clusters:
    - name: test-aks
      resource_group: test-rg
      service_connection: sc-test
image_lock:
  unlock_when_unused:
    never_unlock:
      tag_patterns:
        - { pattern: '.*-keeplock$', reason: "pinned" }
YAML

WORK="${TMP_ROOT}/work"
config_init --file "${TMP_ROOT}/config.yaml" --work-dir "$WORK" >/dev/null 2>&1 \
  || { echo "test setup failed: config did not load"; exit 1; }

# Timestamps relative to now so the suite does not rot.
ts() { date -u -v-"$1"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "$1 days ago" '+%Y-%m-%dT%H:%M:%SZ'; }

tag() {   # name digest age_days [locked]
  local locked="${4:-false}" enabled=true
  [[ "$locked" == "true" ]] && enabled=false
  jq -nc --arg n "$1" --arg d "$2" --arg t "$(ts "$3")" --argjson e "$enabled" \
    '{ name: $n, digest: $d, created: $t, modified: $t, write_enabled: true, delete_enabled: $e }'
}
manifest() {   # digest age_days tags_json [locked] [references_json] [media_type]
  local locked="${4:-false}" enabled=true
  [[ "$locked" == "true" ]] && enabled=false
  jq -nc --arg d "$1" --arg t "$(ts "$2")" --argjson tags "$3" --argjson e "$enabled" \
    --argjson refs "${5:-[]}" --arg mt "${6:-application/vnd.docker.distribution.manifest.v2+json}" \
    '{ digest: $d, tags: $tags, created: $t, modified: $t, size: 1000, media_type: $mt,
       references: $refs, write_enabled: true, delete_enabled: $e }'
}

# routemax/api: the main scenario repository.
API_TAGS="$(jq -s '.' <<EOJ
$(tag "5.6.0-PullRequest1.1"  sha256:pr1  1)
$(tag "5.6.0-PullRequest2.1"  sha256:pr2  3)
$(tag "5.6.0-PullRequest3.1"  sha256:pr3  5)
$(tag "5.6.0-PullRequest4.1"  sha256:pr4  30)
$(tag "5.6.0-PullRequest5.1"  sha256:pr5  40)
$(tag "5.6.0-PullRequest6.1"  sha256:pr6  50)
$(tag "5.6.0-PullRequest7.1"  sha256:pr7  60 true)
$(tag "5.6.0-PullRequest8.1"  sha256:deployed  90)
$(tag "5.5.0-beta.1-136"      sha256:deployed  200)
$(tag "5.5.0-beta.1-136-prod-inUse" sha256:deployed 200)
$(tag "5.4.0-beta.1-100-qa-inUse"   sha256:old 300)
$(tag "5.4.0-beta.1-99"       sha256:helm  400)
$(tag "5.3.0"                 sha256:rel   500)
$(tag "latest"                sha256:rel   500)
$(tag "5.2.0-beta.1-1-donotdelete" sha256:pinned 900)
$(tag "2be4aca5-revert.1-3"   sha256:odd   900)
$(tag "5.1.0-beta.1-7-keeplock" sha256:kl 900 true)
$(tag "5.6.0-alpha.1"  sha256:young-locked 2 true)
EOJ
)"

API_MANIFESTS="$(jq -s '.' <<EOJ
$(manifest sha256:pr1 1 '["5.6.0-PullRequest1.1"]')
$(manifest sha256:young-locked 2 '["5.6.0-alpha.1"]' true)
$(manifest sha256:deployed 200 '["5.6.0-PullRequest8.1","5.5.0-beta.1-136","5.5.0-beta.1-136-prod-inUse"]')
$(manifest sha256:orphan-old 30 '[]')
$(manifest sha256:orphan-young 3 '[]')
$(manifest sha256:orphan-locked 60 '[]' true)
$(manifest sha256:orphan-running 60 '[]')
$(manifest sha256:index 60 '["5.5.0-beta.1-50"]' false '["sha256:child-amd64","sha256:child-arm64"]' 'application/vnd.oci.image.index.v1+json')
$(manifest sha256:child-amd64 60 '[]')
$(manifest sha256:child-arm64 60 '[]')
$(manifest sha256:dead-index 60 '[]' false '["sha256:dead-child"]' 'application/vnd.oci.image.index.v1+json')
$(manifest sha256:dead-child 60 '[]')
EOJ
)"

# Note the index tag is in the manifest list but not in the tag list; the manifest
# side is what matters for the sweep.

jq -n \
  --argjson api_tags "$API_TAGS" --argjson api_manifests "$API_MANIFESTS" \
  --argjson tool_tags "$(jq -s '.' <<<"$(tag 1.31.8 sha256:kubectl 900)")" \
  --argjson tool_manifests "$(jq -s '.' <<<"$(manifest sha256:kubectl 900 '["1.31.8"]')")" \
  --argjson quiet_tags "$(jq -s '.' <<<"$(tag 5.6.0-PullRequest9.1 sha256:q1 400)$(tag 5.6.0-PullRequest10.1 sha256:q2 500)")" \
  --argjson quiet_manifests "[]" \
  '{
     generated_at: "2026-09-04T00:00:00Z", registry: "testacr",
     repositories: [
       { repository: "routemax/api", tags: $api_tags, manifests: $api_manifests },
       { repository: "tools/kubectl", tags: $tool_tags, manifests: $tool_manifests },
       { repository: "routemax/quiet", tags: $quiet_tags, manifests: $quiet_manifests }
     ],
     totals: {}
   }' > "${WORK}/inventory.json"

cat > "${WORK}/protection-set.json" <<'JSON'
{
  "generated_at": "2026-09-04T00:00:00Z",
  "registry": "testacr",
  "clusters": [ { "cluster": "test-aks", "status": "ok", "required": true, "entry_count": 3 } ],
  "protected_tags": [ { "repository": "routemax/api", "tag": "5.5.0-beta.1-136" },
                      { "repository": "routemax/api", "tag": "5.4.0-beta.1-99" } ],
  "protected_digests": [ { "repository": "routemax/api", "digest": "sha256:deployed" },
                         { "repository": "routemax/api", "digest": "sha256:orphan-running" } ],
  "sources": [
    { "repository": "routemax/api", "tag": "5.5.0-beta.1-136", "cluster": "test-aks", "source": "pod", "detail": "running" },
    { "repository": "routemax/api", "digest": "sha256:deployed", "cluster": "test-aks", "source": "pod", "detail": "running" },
    { "repository": "routemax/api", "digest": "sha256:orphan-running", "cluster": "test-aks", "source": "pod", "detail": "running" },
    { "repository": "routemax/api", "tag": "5.4.0-beta.1-99", "cluster": "test-aks", "source": "helm-history", "detail": "ns/rel@rev2" }
  ],
  "suspect_hosts": [], "unlisted_clusters": []
}
JSON

# Per-item decisions live in decisions.jsonl; plan.json keeps candidates and samples.
reason_of() { jq -r -s --arg r "$1" --arg t "$2" '[ .[] | select(.kind == "tag" and .repository == $r and .tag == $t) | .reason ] | first // "absent"' "${WORK}/decisions.jsonl"; }
detail_of() { jq -r -s --arg r "$1" --arg t "$2" '[ .[] | select(.kind == "tag" and .repository == $r and .tag == $t) | .detail ] | first // ""' "${WORK}/decisions.jsonl"; }
is_candidate() { jq -r --arg r "$1" --arg t "$2" '[ .untag[] | select(.repository == $r and .tag == $t) ] | length' "${WORK}/plan.json"; }
manifest_reason() { jq -r -s --arg d "$1" '[ .[] | select(.kind == "manifest" and .digest == $d) | .reason ] | first // "absent"' "${WORK}/decisions.jsonl"; }

echo "classify: full run"
( classify_run "$WORK" ) >/dev/null 2>"${TMP_ROOT}/classify.err" \
  || { echo "classify_run failed:"; tail -20 "${TMP_ROOT}/classify.err"; exit 1; }

check_equals "plan lists three repositories" "3" "$(jq '.totals.repositories' "${WORK}/plan.json")"
check_equals "config hash is recorded" "64" "$(jq -r '.config_hash | length' "${WORK}/plan.json")"

echo "classify: never_delete"
check_equals "never_delete repository" "never-delete:repository" "$(reason_of tools/kubectl 1.31.8)"
check_equals "never_delete repository is flagged on the repo row" \
  "true" "$(jq -r '.repositories[] | select(.repository == "tools/kubectl") | .never_delete' "${WORK}/plan.json")"
check_equals "latest is never deleted" "never-delete:pattern" "$(reason_of routemax/api latest)"
check_equals "-donotdelete escape hatch" "never-delete:pattern" "$(reason_of routemax/api 5.2.0-beta.1-1-donotdelete)"
check_equals "never_delete wins over everything, even a matching rule" \
  "never-delete:pattern" "$(reason_of routemax/api 5.2.0-beta.1-1-donotdelete)"

echo "classify: rules"
check_equals "plain release tag matches no rule" "no-matching-rule" "$(reason_of routemax/api 5.3.0)"
check_equals "digit-leading branch tag matches no rule" "no-matching-rule" "$(reason_of routemax/api 2be4aca5-revert.1-3)"
check_equals "inUse marker is claimed by the first rule, not release_builds" \
  "legacy_inuse_markers" "$(jq -r '.untag[] | select(.tag == "5.4.0-beta.1-100-qa-inUse") | .tag_group' "${WORK}/plan.json")"

echo "classify: protection"
check_equals "running tag is protected" "protected" "$(reason_of routemax/api 5.5.0-beta.1-136)"
check_equals "protection detail names the cluster" "protected:cluster=test-aks" "$(detail_of routemax/api 5.5.0-beta.1-136)"
check_equals "helm history protects the rollback target" "protected:helm-history" "$(detail_of routemax/api 5.4.0-beta.1-99)"
check_equals "a second tag on a running digest is protected by digest" \
  "protected" "$(reason_of routemax/api 5.6.0-PullRequest8.1)"
check_equals "inUse marker on a running digest is protected by digest" \
  "protected" "$(reason_of routemax/api 5.5.0-beta.1-136-prod-inUse)"
check_equals "protection is reported before age, so a deployed old image says protected" \
  "protected" "$(reason_of routemax/api 5.5.0-beta.1-136)"

echo "classify: locks"
check_equals "locked tag is skipped, never unlocked here" "locked" "$(reason_of routemax/api 5.6.0-PullRequest7.1)"
check_equals "lock list carries every locked tag" "3" "$(jq '.locks.tags | length' "${WORK}/plan.json")"
check_equals "orphan lock is marked unprotected" \
  "false" "$(jq -r '.locks.tags[] | select(.tag == "5.6.0-PullRequest7.1") | .protected' "${WORK}/plan.json")"
check_equals "never_unlock pattern is carried on the lock entry" \
  "true" "$(jq -r '.locks.tags[] | select(.tag == "5.1.0-beta.1-7-keeplock") | .never_unlock' "${WORK}/plan.json")"

echo "classify: age and count"
check_equals "newest PR tag is kept by the floor" "always-keep-newest" "$(reason_of routemax/api 5.6.0-PullRequest1.1)"
check_equals "second newest PR tag is kept by the floor" "always-keep-newest" "$(reason_of routemax/api 5.6.0-PullRequest2.1)"
check_equals "young tag outside the floor is within retention" "within-retention" "$(reason_of routemax/api 5.6.0-PullRequest3.1)"
check_equals "old tag outside the floor is a candidate" "1" "$(is_candidate routemax/api 5.6.0-PullRequest4.1)"
check_equals "the floor keeps an old repository from being emptied" \
  "always-keep-newest" "$(reason_of routemax/quiet 5.6.0-PullRequest9.1)"
check_equals "quiet repository has no candidates" \
  "0" "$(jq '[ .untag[] | select(.repository == "routemax/quiet") ] | length' "${WORK}/plan.json")"
check_equals "inUse marker with 0-day retention is a candidate" "1" "$(is_candidate routemax/api 5.4.0-beta.1-100-qa-inUse)"

echo "classify: would_delete / would_sweep (the lock reconciler's immediate-unlock signal)"
# These are computed regardless of protection or lock state - purely "would the
# normal age/count rules call this a candidate on their own?" - which is what
# lets lock-reconcile.sh unlock a stale orphan on the very first run, with no
# ledger history at all.
check_equals "an old, over-the-floor locked tag is already stale enough to delete" \
  "true" "$(jq '.locks.tags[] | select(.tag == "5.6.0-PullRequest7.1") | .would_delete' "${WORK}/plan.json")"
check_equals "a freshly-locked tag, still within its own rule's retention, is not yet stale" \
  "false" "$(jq '.locks.tags[] | select(.tag == "5.6.0-alpha.1") | .would_delete' "${WORK}/plan.json")"
check_equals "a locked tag still inside its group's always_keep_newest floor is not stale, however old" \
  "false" "$(jq '.locks.tags[] | select(.tag == "5.1.0-beta.1-7-keeplock") | .would_delete' "${WORK}/plan.json")"
check_equals "would_delete is computed for a protected tag too (informational, not gated by protection)" \
  "true" "$(jq -s '[.[] | select(.kind == "tag" and .tag == "5.5.0-beta.1-136")] | .[0] | has("would_delete")' "${WORK}/decisions.jsonl")"
check_equals "an unprotected tag past its own rule already reports would_delete=true even though it is not locked" \
  "true" "$(jq -s '[.[] | select(.kind == "tag" and .tag == "5.6.0-PullRequest4.1")] | .[0].would_delete' "${WORK}/decisions.jsonl")"
check_equals "locked_stale totals count the tags in the plan that are already past retention" \
  "1" "$(jq '.locked_stale.tags' "${WORK}/plan.json")"

check_equals "a locked, still-tagged manifest is never sweep-stale" \
  "false" "$(jq -s '[.[] | select(.kind == "manifest" and .digest == "sha256:young-locked")] | .[0].would_sweep' "${WORK}/decisions.jsonl")"
check_equals "a locked, untagged manifest past the recovery window is sweep-stale" \
  "true" "$(jq '.locks.manifests[] | select(.digest == "sha256:orphan-locked") | .would_sweep' "${WORK}/plan.json")"
check_equals "an untagged manifest inside the recovery window is not sweep-stale" \
  "false" "$(jq -s '[.[] | select(.kind == "manifest" and .digest == "sha256:orphan-young")] | .[0].would_sweep' "${WORK}/decisions.jsonl")"
check_equals "locked_stale totals also cover manifests" \
  "1" "$(jq '.locked_stale.manifests' "${WORK}/plan.json")"
check_equals "candidate total" "4" "$(jq '.totals.untag_candidates' "${WORK}/plan.json")"
check_equals "candidates are oldest first" \
  "5.4.0-beta.1-100-qa-inUse" "$(jq -r '.untag[0].tag' "${WORK}/plan.json")"
check_equals "candidates by group" \
  '{"legacy_inuse_markers":1,"pull_request_builds":3}' "$(jq -c '.totals.candidates_by_group' "${WORK}/plan.json")"

echo "classify: manifest sweep"
check_equals "tagged manifest is not a sweep candidate" "tagged" "$(manifest_reason sha256:deployed)"
check_equals "plan keeps samples per skip reason" \
  "true" "$(jq '.skipped_samples | has("protected") and has("locked")' "${WORK}/plan.json")"
check_equals "decision list covers every tag and manifest" \
  "$(jq '.totals.tags + .totals.manifests' "${WORK}/plan.json")" "$(wc -l < "${WORK}/decisions.jsonl" | tr -d ' ')"
check_equals "candidate bytes count a shared digest once" \
  "true" "$(jq '.totals.untag_candidate_bytes <= ([ .untag[].size ] | add)' "${WORK}/plan.json")"
check_equals "old untagged manifest is a sweep candidate" "candidate" "$(manifest_reason sha256:orphan-old)"
check_equals "young untagged manifest is inside the recovery window" "within-recovery-window" "$(manifest_reason sha256:orphan-young)"
check_equals "locked untagged manifest is skipped" "locked" "$(manifest_reason sha256:orphan-locked)"
check_equals "untagged manifest running by digest is protected" "protected" "$(manifest_reason sha256:orphan-running)"
check_equals "children of a tagged index are protected" "referenced-by-parent" "$(manifest_reason sha256:child-amd64)"
check_equals "both index children are protected" "referenced-by-parent" "$(manifest_reason sha256:child-arm64)"
check_equals "an untagged index is itself a candidate" "candidate" "$(manifest_reason sha256:dead-index)"
check_equals "children of a swept index go with it" "candidate" "$(manifest_reason sha256:dead-child)"
check_equals "sweep candidate total" "3" "$(jq '.totals.manifest_candidates' "${WORK}/plan.json")"
check_equals "sweep bytes are summed" "3000" "$(jq '.totals.manifest_candidate_bytes' "${WORK}/plan.json")"
check_equals "never_delete repository manifests are never swept" \
  "0" "$(jq '[ .manifests[] | select(.repository == "tools/kubectl") ] | length' "${WORK}/plan.json")"

echo "classify: tag group filter"
( classify_run "$WORK" pull_request_builds ) >/dev/null 2>"${TMP_ROOT}/classify.err" \
  || { echo "classify_run with filter failed:"; tail -20 "${TMP_ROOT}/classify.err"; exit 1; }
check_equals "out-of-scope group is skipped" "not-in-scope" "$(reason_of routemax/api 5.4.0-beta.1-100-qa-inUse)"
check_equals "in-scope group still yields candidates" "3" "$(jq '.totals.untag_candidates' "${WORK}/plan.json")"
check_equals "filter is recorded in the plan" "pull_request_builds" "$(jq -r '.tag_groups[0]' "${WORK}/plan.json")"

echo "classify: repository filter (targeted cleanup)"
( classify_run "$WORK" "" "routemax/api,routemax/quiet" ) >/dev/null 2>"${TMP_ROOT}/classify.err" \
  || { echo "classify_run with repositories failed:"; tail -5 "${TMP_ROOT}/classify.err"; exit 1; }
check_equals "only the named repositories are in the plan" \
  "routemax/api routemax/quiet" "$(jq -r '[ .repositories[].repository ] | sort | join(" ")' "${WORK}/plan.json")"
check_equals "the filter is recorded" "2" "$(jq '.repositories_filter | length' "${WORK}/plan.json")"
check_equals "decisions cover only the named repositories" \
  "0" "$(grep -c '"repository":"tools/kubectl"' "${WORK}/decisions.jsonl")"
if ( classify_run "$WORK" "" "routemax/api,routemax/nope" ) >/dev/null 2>&1; then
  fail_test "an unknown repository in the filter fails the run"
else
  pass "an unknown repository in the filter fails the run"
fi

echo "classify: fail closed"
jq '.protected_tags = [] | .protected_digests = [] | .sources = []' "${WORK}/protection-set.json" > "${WORK}/empty.json"
mkdir -p "${TMP_ROOT}/empty-work"
cp "${WORK}/inventory.json" "${TMP_ROOT}/empty-work/"
cp "${WORK}/empty.json" "${TMP_ROOT}/empty-work/protection-set.json"
if ( classify_run "${TMP_ROOT}/empty-work" ) >/dev/null 2>&1; then
  fail_test "empty protection set aborts classification"
else
  pass "empty protection set aborts classification"
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
