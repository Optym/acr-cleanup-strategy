#!/usr/bin/env bash
#
# Unit tests for the pure parts of lib/discover-k8s.sh: image reference parsing,
# registry host matching, and protection-set merging. No Azure, no cluster access.
#
#   ./tests/discover-k8s.test.sh

set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname -- "$TESTS_DIR")"

# shellcheck source=../lib/common.sh
source "${MODULE_DIR}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${MODULE_DIR}/lib/config.sh"
# shellcheck source=../lib/discover-k8s.sh
source "${MODULE_DIR}/lib/discover-k8s.sh"

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
  name: rmxacrcommon
  resource_group: immortal-rg-eus
  subscription_id: 00000000-0000-0000-0000-000000000000
  host_aliases:
    - rmxacrcommon.eastus.data.azurecr.io
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
YAML

config_init --file "${TMP_ROOT}/config.yaml" --work-dir "${TMP_ROOT}/work" >/dev/null 2>&1 \
  || { echo "test setup failed: config did not load"; exit 1; }

# Convenience: one ref in, one parsed entry out. _dk8s_refs_to_entries now
# expects "namespace<TAB>ref" lines, so every ref is attributed to a fixed
# test namespace here.
parse_one() {
  printf 'test-ns\t%s\n' "$1" | _dk8s_refs_to_entries test-aks pod running
}

echo "discover: image reference parsing"

ENTRY="$(parse_one 'rmxacrcommon.azurecr.io/routemax/api:5.5.0-beta.1-136')"
check_equals "tagged image: repository" \
  "routemax/api" "$(jq -r '.[0].repository' <<<"$ENTRY")"
check_equals "tagged image: tag" \
  "5.5.0-beta.1-136" "$(jq -r '.[0].tag' <<<"$ENTRY")"
check_equals "tagged image: matched as ours" \
  "registry" "$(jq -r '.[0].match' <<<"$ENTRY")"
check_equals "tagged image: carries its namespace" \
  "test-ns" "$(jq -r '.[0].namespace' <<<"$ENTRY")"

ENTRY="$(parse_one 'rmxacrcommon.azurecr.io/routemax/appointment-ai/web:1.2.3')"
check_equals "nested repository path is preserved" \
  "routemax/appointment-ai/web" "$(jq -r '.[0].repository' <<<"$ENTRY")"

ENTRY="$(parse_one 'rmxacrcommon.azurecr.io/routemax/api@sha256:abc123')"
check_equals "digest-pinned image: repository" \
  "routemax/api" "$(jq -r '.[0].repository' <<<"$ENTRY")"
check_equals "digest-pinned image: digest" \
  "sha256:abc123" "$(jq -r '.[0].digest' <<<"$ENTRY")"
check_equals "digest-pinned image: carries no tag" \
  "null" "$(jq -r '.[0].tag // "null"' <<<"$ENTRY")"

ENTRY="$(parse_one 'rmxacrcommon.azurecr.io/routemax/api:5.5.0@sha256:abc123')"
check_equals "tag+digest form drops the tag and keeps the repository" \
  "routemax/api" "$(jq -r '.[0].repository' <<<"$ENTRY")"

# kubelet reports imageID with a runtime prefix; without stripping it the host
# parses as "docker-pullable:" and the image looks foreign, i.e. unprotected.
ENTRY="$(parse_one 'docker-pullable://rmxacrcommon.azurecr.io/routemax/ui@sha256:def456')"
check_equals "imageID runtime prefix is stripped" \
  "routemax/ui" "$(jq -r '.[0].repository' <<<"$ENTRY")"
check_equals "imageID is still recognised as ours" \
  "registry" "$(jq -r '.[0].match' <<<"$ENTRY")"

ENTRY="$(parse_one 'rmxacrcommon.azurecr.io/routemax/api')"
check_equals "untagged reference defaults to latest" \
  "latest" "$(jq -r '.[0].tag' <<<"$ENTRY")"

echo "discover: registry host matching"

ENTRY="$(parse_one 'ghcr.io/kedacore/keda:2.14.0')"
check_equals "third-party registry is classified foreign" \
  "foreign" "$(jq -r '.[0].match' <<<"$ENTRY")"

ENTRY="$(parse_one 'mcr.microsoft.com/oss/kubernetes/ingress/nginx:1.2.3')"
check_equals "MCR image is classified foreign" \
  "foreign" "$(jq -r '.[0].match' <<<"$ENTRY")"

ENTRY="$(parse_one 'rmxacrcommon.eastus.data.azurecr.io/routemax/api:1.2.3')"
check_equals "configured host alias counts as ours" \
  "registry" "$(jq -r '.[0].match' <<<"$ENTRY")"

# The dangerous case: looks like our registry, is not in host_aliases, so it would
# not be protected. It must surface as a warning rather than be silently dropped.
ENTRY="$(parse_one 'rmxacrcommon.westus2.data.azurecr.io/routemax/api:1.2.3')"
check_equals "unlisted lookalike host is flagged as suspect" \
  "suspect_host" "$(jq -r '.[0].match' <<<"$ENTRY")"

ENTRY="$(parse_one 'busybox:latest')"
check_equals "Docker Hub short name has no host and is dropped" \
  "0" "$(jq -r 'length' <<<"$ENTRY")"

echo "discover: extraction from kubectl JSON"

cat > "${TMP_ROOT}/pods.json" <<'JSON'
{
  "items": [
    {
      "metadata": { "namespace": "prod-01" },
      "spec": {
        "initContainers": [ { "image": "rmxacrcommon.azurecr.io/routemax/etl:1.0.0" } ],
        "containers": [
          { "image": "rmxacrcommon.azurecr.io/routemax/api:5.5.0-beta.1-136" },
          { "image": "ghcr.io/kedacore/keda:2.14.0" }
        ],
        "ephemeralContainers": [ { "image": "rmxacrcommon.azurecr.io/tools/kubectl:1.31.8" } ]
      },
      "status": {
        "containerStatuses": [
          { "imageID": "docker-pullable://rmxacrcommon.azurecr.io/routemax/api@sha256:aaa" }
        ]
      }
    },
    {
      "metadata": { "namespace": "prod-02" },
      "spec": {
        "containers": [
          { "image": "rmxacrcommon.azurecr.io/routemax/api:6.0.0-beta.1-1" }
        ]
      }
    }
  ]
}
JSON

ENTRIES="$(_dk8s_refs_from_kubectl_json < "${TMP_ROOT}/pods.json" \
  | _dk8s_refs_to_entries test-aks pod running)"

check_equals "initContainers are collected" \
  "1" "$(jq '[.[] | select(.repository=="routemax/etl")] | length' <<<"$ENTRIES")"
check_equals "ephemeralContainers are collected" \
  "1" "$(jq '[.[] | select(.repository=="tools/kubectl")] | length' <<<"$ENTRIES")"
check_equals "imageID digests are collected alongside tags" \
  "1" "$(jq '[.[] | select(.repository=="routemax/api" and has("digest"))] | length' <<<"$ENTRIES")"
check_equals "third-party image is kept out of the protected set" \
  "0" "$(jq '[.[] | select(.match=="registry" and .repository=="kedacore/keda")] | length' <<<"$ENTRIES")"
check_equals "each item's images are attributed to its own namespace" \
  "prod-01" "$(jq -r '[.[] | select(.repository=="routemax/etl")][0].namespace' <<<"$ENTRIES")"
check_equals "a second pod in a different namespace keeps its own namespace" \
  "prod-02" "$(jq -r '[.[] | select(.repository=="routemax/api" and .tag=="6.0.0-beta.1-1")][0].namespace' <<<"$ENTRIES")"

echo "discover: helm manifest extraction"

cat > "${TMP_ROOT}/manifest.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
        - name: api
          image: "rmxacrcommon.azurecr.io/routemax/api:5.5.0-beta.1-135"
        - name: sidecar
          image: 'rmxacrcommon.azurecr.io/routemax/etl:5.5.0-beta.1-135'
        - name: plain
          image: rmxacrcommon.azurecr.io/routemax/ui:5.5.0-beta.1-135
YAML

ENTRIES="$(_dk8s_refs_from_helm_manifest < "${TMP_ROOT}/manifest.yaml" \
  | awk -v ns="ns" '{ print ns "\t" $0 }' \
  | _dk8s_refs_to_entries test-aks helm-history 'ns/rel@rev3')"

check_equals "double-quoted, single-quoted and bare image values are all read" \
  "3" "$(jq '[.[] | select(.match=="registry")] | length' <<<"$ENTRIES")"
check_equals "helm entries record their source" \
  "helm-history" "$(jq -r '.[0].source' <<<"$ENTRIES")"
check_equals "helm entries record their namespace explicitly" \
  "ns" "$(jq -r '.[0].namespace' <<<"$ENTRIES")"

echo "discover: merge and fail-closed"

merge_fixture() {
  rm -rf "${TMP_ROOT}/merge"
  mkdir -p "${TMP_ROOT}/merge/protection"
  cp "$@" "${TMP_ROOT}/merge/protection/"
  # Subshell: discover_merge aborts with exit, which would otherwise end the suite.
  ( discover_merge "${TMP_ROOT}/merge" >/dev/null 2>&1 )
}

cat > "${TMP_ROOT}/ok.json" <<'JSON'
{
  "cluster": "test-aks", "resource_group": "test-rg", "required": true,
  "status": "ok", "error": null,
  "entries": [
    { "host": "rmxacrcommon.azurecr.io", "repository": "routemax/api", "tag": "1.0.0", "match": "registry", "cluster": "test-aks", "namespace": "prod-01", "source": "pod", "detail": "running" }
  ],
  "suspect_hosts": [], "foreign_count": 0, "unlisted_clusters": []
}
JSON

if merge_fixture "${TMP_ROOT}/ok.json"; then
  pass "merge succeeds when the required cluster is ok"
  check_equals "merged protected tag count" \
    "1" "$(jq '.protected_tags | length' "${TMP_ROOT}/merge/protection-set.json")"
else
  fail_test "merge succeeds when the required cluster is ok"
fi

cat > "${TMP_ROOT}/unreachable.json" <<'JSON'
{
  "cluster": "test-aks", "resource_group": "test-rg", "required": true,
  "status": "unreachable", "error": "could not list pods",
  "entries": [], "suspect_hosts": [], "foreign_count": 0, "unlisted_clusters": []
}
JSON

if merge_fixture "${TMP_ROOT}/unreachable.json"; then
  fail_test "merge aborts when a required cluster is unreachable"
else
  pass "merge aborts when a required cluster is unreachable"
fi

cat > "${TMP_ROOT}/empty.json" <<'JSON'
{
  "cluster": "test-aks", "resource_group": "test-rg", "required": true,
  "status": "ok", "error": null,
  "entries": [], "suspect_hosts": [], "foreign_count": 0, "unlisted_clusters": []
}
JSON

# An empty protection set makes every image look deletable, so it must never proceed.
if merge_fixture "${TMP_ROOT}/empty.json"; then
  fail_test "merge aborts when the protection set is empty"
else
  pass "merge aborts when the protection set is empty"
fi

echo "discover: retries"

sleep() { :; }
RETRY_COUNT_FILE="${TMP_ROOT}/retry-count"
printf '0' > "$RETRY_COUNT_FILE"
flaky() {
  local n; n="$(cat "$RETRY_COUNT_FILE")"; printf '%s' "$((n + 1))" > "$RETRY_COUNT_FILE"
  if ((n < 2)); then printf 'partial'; return 1; fi
  printf 'complete'
}
OUT="$(DK8S_RETRIES=3 _dk8s_retry flaky 2>/dev/null)"; RC=$?
check_equals "a command that succeeds on the third attempt succeeds" "0" "$RC"
check_equals "three attempts were made" "3" "$(cat "$RETRY_COUNT_FILE")"
check_equals "only the successful attempt's output is released" "complete" "$OUT"

printf '0' > "$RETRY_COUNT_FILE"
always_fails() { local n; n="$(cat "$RETRY_COUNT_FILE")"; printf '%s' "$((n + 1))" > "$RETRY_COUNT_FILE"; return 7; }
DK8S_RETRIES=2 _dk8s_retry always_fails >/dev/null 2>&1; RC=$?
check_equals "the last exit status is returned after exhausting retries" "7" "$RC"
check_equals "retries stop at DK8S_RETRIES" "2" "$(cat "$RETRY_COUNT_FILE")"

echo "discover: whole-cluster discovery with a large cluster (stubbed)"

# Stubs stand in for az, kubectl and helm. The pod list carries 30k image
# references, well past ARG_MAX, which is the real np cluster's failure mode.
_dk8s_connect() { return 0; }
_dk8s_unlisted_clusters() { printf '[]'; }
_dk8s_kinds_to_read() { printf 'deployments'; }
STUB_HELM_FAIL="${TMP_ROOT}/helm-fail"
_dk8s_run() {
  shift 2
  case "$*" in
    "kubectl get pods"*)
      jq -nc '{ items: [ range(30000) | { spec: { containers: [ { image: ("rmxacrcommon.azurecr.io/routemax/svc\(. % 40):5.6.0-PullRequest\(.).1") } ] } } ] }' ;;
    "kubectl get deployments"*)
      printf '{"items":[{"spec":{"template":{"spec":{"containers":[{"image":"rmxacrcommon.azurecr.io/routemax/api:1.0.0"}]}}}}]}' ;;
    "helm list"*)
      printf '[{"name":"rel","namespace":"ns"},{"name":"gone","namespace":"ns"}]' ;;
    "helm history gone"*)
      printf 'Error: release: not found\n' >&2; return 1 ;;
    "helm history rel"*)
      [[ -f "$STUB_HELM_FAIL" ]] && return 1
      printf '[{"revision":1},{"revision":2}]' ;;
    "helm get manifest"*)
      printf 'kind: Deployment\nspec:\n  template:\n    spec:\n      containers:\n        - image: rmxacrcommon.azurecr.io/routemax/api:0.9.0\n' ;;
    *) return 1 ;;
  esac
}

BIG="${TMP_ROOT}/big"
mkdir -p "$BIG"
( discover_cluster "$BIG" 0 ) >/dev/null 2>"${TMP_ROOT}/big.err"; RC=$?
check_equals "large cluster is discovered" "0" "$RC"
check_equals "cluster status is ok" "ok" "$(jq -r '.status' "${BIG}/protection/test-aks.json")"
check_equals "all 30k pod references plus workload and helm entries are kept" \
  "30003" "$(jq '.entries | length' "${BIG}/protection/test-aks.json")"
check_equals "helm history entries are present" \
  "2" "$(jq '[ .entries[] | select(.source == "helm-history") ] | length' "${BIG}/protection/test-aks.json")"
check_equals "a release that vanished after helm list is skipped, not fatal" \
  "1" "$(grep -c 'no longer exists' "${TMP_ROOT}/big.err")"

# A Helm read that keeps failing must fail the cluster: contributing nothing
# would leave that release's rollback images looking deletable.
: > "$STUB_HELM_FAIL"
( discover_cluster "$BIG" 0 ) >/dev/null 2>&1; RC=$?
check_equals "a persistent helm failure fails a required cluster" "1" "$RC"
check_equals "cluster is recorded as unreachable" "unreachable" "$(jq -r '.status' "${BIG}/protection/test-aks.json")"
rm -f "$STUB_HELM_FAIL"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
