#!/usr/bin/env bash
#
# Unit tests for lib/acr-api.sh. The HTTP transport is stubbed via
# ACR_TRANSPORT_FN, so retry, pagination, scope selection and fail-closed
# behaviour are all exercised without a registry.
#
#   ./tests/acr-api.test.sh

set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname -- "$TESTS_DIR")"

# shellcheck source=../lib/common.sh
source "${MODULE_DIR}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${MODULE_DIR}/lib/config.sh"
# shellcheck source=../lib/acr-api.sh
source "${MODULE_DIR}/lib/acr-api.sh"

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
YAML

config_init --file "${TMP_ROOT}/config.yaml" --work-dir "${TMP_ROOT}/work" >/dev/null 2>&1 \
  || { echo "test setup failed: config did not load"; exit 1; }

# Pretend we are authenticated; the token exchange is never reached because the
# access-token cache is pre-seeded below.
ACR_LOGIN_SERVER="testacr.azurecr.io"
ACR_REFRESH_TOKEN="fake-refresh-token"
ACR_REFRESH_TOKEN_AT="$SECONDS"
ACR_MAX_RETRIES=3

_acr_ensure_access_token() { ACR_ACCESS_TOKEN="fake-access-token-for-$1"; }

# Stub transport. Each test sets a plan of "status|body|headers" lines, one per
# call. State lives in files because acr_request invokes the transport inside a
# command substitution, so a subshell cannot report back through variables.
STUB_PLAN_FILE="${TMP_ROOT}/stub-plan"
STUB_COUNT_FILE="${TMP_ROOT}/stub-count"
STUB_LOG_FILE="${TMP_ROOT}/stub-log"

stub_transport() {
  local method="$1" url="$2" token="$3" body="$4" out_body="$5" out_headers="$6"
  printf '%s %s token=%s body=%s\n' "$method" "$url" "$token" "$body" >> "$STUB_LOG_FILE"

  local index plan
  index="$(cat "$STUB_COUNT_FILE")"
  printf '%s' "$((index + 1))" > "$STUB_COUNT_FILE"

  plan="$(sed -n "$((index + 1))p" "$STUB_PLAN_FILE")"
  [[ -n "$plan" ]] || plan='500||'

  # IFS-split with read, not ${var#*|}: prefix stripping is quadratic in bash
  # and stalls for minutes on the megabyte-sized large-repository fixture.
  local status response_body response_headers
  IFS='|' read -r status response_body response_headers <<<"$plan"

  printf '%s' "$response_body" > "$out_body"
  printf '%b' "$response_headers" > "$out_headers"
  printf '%s' "$status"
}

reset_stub() {
  printf '%s\n' "$@" > "$STUB_PLAN_FILE"
  printf '0' > "$STUB_COUNT_FILE"
  : > "$STUB_LOG_FILE"
}

stub_calls() { cat "$STUB_COUNT_FILE"; }
stub_log_matches() { grep -c -- "$1" "$STUB_LOG_FILE" || true; }

ACR_TRANSPORT_FN=stub_transport
# Keep the suite fast: retries must not really sleep.
sleep() { :; }

echo "acr-api: scopes"

check_equals "catalog scope" \
  "registry:catalog:*" "$(_acr_scope_for "" catalog)"
check_equals "read scope is metadata_read + pull" \
  "repository:routemax/api:metadata_read,pull" "$(_acr_scope_for routemax/api read)"
# A read-only run must never hold a delete-capable token.
check_equals "write scope adds metadata_write and delete" \
  "repository:routemax/api:metadata_read,metadata_write,delete,pull" \
  "$(_acr_scope_for routemax/api write)"

echo "acr-api: request handling"

reset_stub '200|{"tags":[]}|'
if acr_request GET "/acr/v1/routemax/api/_tags" read routemax/api; then
  pass "2xx returns success"
else
  fail_test "2xx returns success"
fi
check_equals "status is recorded" "200" "$ACR_HTTP_STATUS"

reset_stub '404|{"errors":[]}|'
if acr_request GET "/acr/v1/routemax/api/_tags" read routemax/api; then
  fail_test "404 returns failure"
else
  pass "404 returns failure"
fi

# A rejected token gets exactly one forced renewal, then the call proceeds.
reset_stub '401||' '200|{"tags":[]}|'
if acr_request GET "/acr/v1/routemax/api/_tags" read routemax/api; then
  pass "401 triggers a token renewal and retries once"
else
  fail_test "401 triggers a token renewal and retries once"
fi
check_equals "401 retry used exactly two calls" "2" "$(stub_calls)"

reset_stub '429||' '429||' '200|{"tags":[]}|'
if acr_request GET "/acr/v1/routemax/api/_tags" read routemax/api; then
  pass "429 is retried until success"
else
  fail_test "429 is retried until success"
fi
check_equals "429 retried up to the limit" "3" "$(stub_calls)"

reset_stub '503||' '503||' '503||'
if acr_request GET "/acr/v1/routemax/api/_tags" read routemax/api; then
  fail_test "retries give up after ACR_MAX_RETRIES"
else
  pass "retries give up after ACR_MAX_RETRIES"
fi
check_equals "gave up after exactly ACR_MAX_RETRIES calls" "3" "$(stub_calls)"

# 400 is a client error; retrying it just wastes the run.
reset_stub '400||' '200|{"tags":[]}|'
if acr_request GET "/acr/v1/routemax/api/_tags" read routemax/api; then
  fail_test "400 is not retried"
else
  pass "400 is not retried"
fi
check_equals "400 used a single call" "1" "$(stub_calls)"

echo "acr-api: retry backoff"

printf 'Retry-After: 7\r\n' > "${TMP_ROOT}/headers-retry"
check_equals "Retry-After header is honoured" \
  "7" "$(_acr_backoff_seconds 1 "${TMP_ROOT}/headers-retry")"

printf 'Content-Type: application/json\r\n' > "${TMP_ROOT}/headers-plain"
BACKOFF="$(_acr_backoff_seconds 3 "${TMP_ROOT}/headers-plain")"
if ((BACKOFF >= 4 && BACKOFF <= 5)); then
  pass "exponential backoff without Retry-After"
else
  fail_test "exponential backoff without Retry-After (got ${BACKOFF})"
fi

echo "acr-api: pagination"

printf 'Link: </acr/v1/routemax/api/_tags?last=b&n=500>; rel="next"\r\n' \
  > "${TMP_ROOT}/headers-link"
check_equals "next link is parsed from the Link header" \
  "/acr/v1/routemax/api/_tags?last=b&n=500" \
  "$(_acr_parse_next_link "${TMP_ROOT}/headers-link")"

check_equals "absent Link header yields no next page" \
  "" "$(_acr_parse_next_link "${TMP_ROOT}/headers-plain")"

reset_stub \
  '200|{"tags":[{"name":"a"},{"name":"b"}]}|Link: </acr/v1/routemax/api/_tags?last=b&n=500>; rel="next"\r\n' \
  '200|{"tags":[{"name":"c"}]}|'
TAGS="$(acr_list_tags routemax/api)"
check_equals "pages are concatenated" "3" "$(jq 'length' <<<"$TAGS")"
check_equals "pagination stops when the Link header disappears" "2" "$(stub_calls)"
check_equals "second page was requested from the Link URL" \
  "1" "$(stub_log_matches 'last=b')"

echo "acr-api: manifest reference graph"

reset_stub '200|{"manifest":{"references":[{"digest":"sha256:child1"},{"digest":"sha256:child2"}]}}|'
REFS="$(acr_manifest_references routemax/api sha256:parent)"; RC=$?
check_equals "references are returned" "2" "$(jq 'length' <<<"$REFS")"
check_equals "references return code" "0" "$RC"

reset_stub '200|{"manifest":{}}|'
REFS="$(acr_manifest_references routemax/api sha256:parent)"; RC=$?
check_equals "a manifest with no references yields an empty array" "0" "$(jq 'length' <<<"$REFS")"
check_equals "no references is still success" "0" "$RC"

# Already deleted is "gone", which is a different answer from "cannot tell".
reset_stub '404||'
acr_manifest_references routemax/api sha256:parent >/dev/null 2>&1; RC=$?
check_equals "404 reports the manifest as already gone" "2" "$RC"

# Fail closed: an unreadable graph must not look like "no children to protect".
reset_stub '500||'
acr_manifest_references routemax/api sha256:parent >/dev/null 2>&1; RC=$?
check_equals "unreadable reference graph fails closed" "1" "$RC"

reset_stub '200|not json at all|'
acr_manifest_references routemax/api sha256:parent >/dev/null 2>&1; RC=$?
check_equals "malformed reference graph fails closed" "1" "$RC"

echo "acr-api: mutations"

reset_stub '202||'
if acr_untag routemax/api 1.2.3; then pass "untag succeeds on 202"; else fail_test "untag succeeds on 202"; fi
check_equals "untag uses DELETE on the tag path" \
  "1" "$(stub_log_matches 'DELETE https://testacr.azurecr.io/acr/v1/routemax/api/_tags/1.2.3')"

# Already untagged is the desired end state, not an error.
reset_stub '404||'
if acr_untag routemax/api 1.2.3; then pass "untag treats 404 as already done"; else fail_test "untag treats 404 as already done"; fi

reset_stub '403||'
if acr_untag routemax/api 1.2.3; then fail_test "untag fails on 403"; else pass "untag fails on 403"; fi

reset_stub '202||'
if acr_delete_manifest routemax/api sha256:abc; then pass "manifest delete succeeds"; else fail_test "manifest delete succeeds"; fi
check_equals "manifest delete uses the v2 path" \
  "1" "$(stub_log_matches 'DELETE https://testacr.azurecr.io/v2/routemax/api/manifests/sha256:abc')"

reset_stub '200||'
acr_set_tag_attributes routemax/api 1.2.3 false false >/dev/null
check_equals "lock sends both attributes as booleans" \
  "1" "$(stub_log_matches 'body={"writeEnabled":false,"deleteEnabled":false}')"

reset_stub '200||'
acr_set_manifest_attributes routemax/api sha256:abc true true >/dev/null
check_equals "unlock sends true for both attributes" \
  "1" "$(stub_log_matches 'body={"writeEnabled":true,"deleteEnabled":true}')"

echo "acr-api: inventory shape"

reset_stub \
  '200|{"tags":[{"name":"1.0.0","digest":"sha256:a","createdTime":"2026-01-01T00:00:00Z","lastUpdateTime":"2026-01-02T00:00:00Z","changeableAttributes":{"writeEnabled":false,"deleteEnabled":false}}]}|' \
  '200|{"manifests":[{"digest":"sha256:a","tags":["1.0.0"],"createdTime":"2026-01-01T00:00:00Z","lastUpdateTime":"2026-01-02T00:00:00Z","imageSize":1234,"mediaType":"application/vnd.oci.image.manifest.v1+json","changeableAttributes":{"writeEnabled":true,"deleteEnabled":true}}]}|'
acr_inventory_repository routemax/api "${TMP_ROOT}/inv.json" 2>/dev/null

check_equals "inventory records the tag" \
  "1.0.0" "$(jq -r '.tags[0].name' "${TMP_ROOT}/inv.json")"
check_equals "inventory records lock state" \
  "false" "$(jq -r '.tags[0].delete_enabled' "${TMP_ROOT}/inv.json")"
check_equals "inventory records manifest size" \
  "1234" "$(jq -r '.manifests[0].size' "${TMP_ROOT}/inv.json")"
check_equals "a plain manifest has no references" \
  "0" "$(jq -r '.manifests[0].references | length' "${TMP_ROOT}/inv.json")"
check_equals "an ordinary manifest costs no extra lookup" \
  "2" "$(stub_calls)"

# The incident this whole block guards against: ACR's bulk _manifests listing
# never actually populates `references` for an index or manifest list - it
# comes back `[]` even when the index genuinely has children - confirmed live
# against rmxacrcommon on 2026-09-06 after that gap let the sweep delete the
# platform manifest and attestation manifest of two still-tagged, still-
# deployed keycloak images. The real list is only ever returned by a per-digest
# GET, so inventory now fetches it for every index/manifest-list entry.
reset_stub \
  '200|{"tags":[]}|' \
  '200|{"manifests":[{"digest":"sha256:idx","tags":["1.0.0"],"mediaType":"application/vnd.oci.image.index.v1+json","references":[]}]}|' \
  '200|{"manifest":{"references":[{"digest":"sha256:amd64"},{"digest":"sha256:arm64"}]}}|'
acr_inventory_repository routemax/api "${TMP_ROOT}/inv-idx.json" 2>/dev/null
check_equals "index children are resolved via a per-digest lookup, since the bulk listing never carries them" \
  "sha256:amd64 sha256:arm64" "$(jq -r '.manifests[0].references | join(" ")' "${TMP_ROOT}/inv-idx.json")"
check_equals "the per-digest lookup targets the index digest" \
  "1" "$(stub_log_matches 'GET https://testacr.azurecr.io/acr/v1/routemax/api/_manifests/sha256:idx ')"

# Even when the bulk API claims something for `references` (past behaviour, or
# a future ACR change), the resolved graph always wins - a stale or partial
# bulk value must never quietly reinstate the bug this closes.
reset_stub \
  '200|{"tags":[]}|' \
  '200|{"manifests":[{"digest":"sha256:idx","tags":["1.0.0"],"mediaType":"application/vnd.docker.distribution.manifest.list.v2+json","references":[{"digest":"sha256:stale-bulk-value"}]}]}|' \
  '200|{"manifest":{"references":[{"digest":"sha256:amd64"}]}}|'
acr_inventory_repository routemax/api "${TMP_ROOT}/inv-list.json" 2>/dev/null
check_equals "the resolved reference graph replaces whatever the bulk listing claimed" \
  "sha256:amd64" "$(jq -r '.manifests[0].references | join(" ")' "${TMP_ROOT}/inv-list.json")"

# An index that vanished between the bulk listing and the per-digest lookup is
# gone, not dangerous: nothing is left under it to protect.
reset_stub \
  '200|{"tags":[]}|' \
  '200|{"manifests":[{"digest":"sha256:idx","tags":["1.0.0"],"mediaType":"application/vnd.oci.image.index.v1+json","references":[]}]}|' \
  '404||'
acr_inventory_repository routemax/api "${TMP_ROOT}/inv-gone.json" 2>/dev/null
check_equals "an index gone by the time of the lookup resolves to no children, not a failure" \
  "0" "$(jq -r '.manifests[0].references | length' "${TMP_ROOT}/inv-gone.json")"

# The safety property the incident needed: a reference graph that cannot be
# read must never be silently recorded as empty - that is indistinguishable
# from "no children to protect" and is exactly what let the sweep through.
reset_stub \
  '200|{"tags":[]}|' \
  '200|{"manifests":[{"digest":"sha256:idx","tags":["1.0.0"],"mediaType":"application/vnd.oci.image.index.v1+json","references":[]}]}|' \
  '500||' '500||' '500||'
( acr_inventory_repository routemax/api "${TMP_ROOT}/inv-unreadable.json" ) >/dev/null 2>"${TMP_ROOT}/backfill.err"; RC=$?
check_equals "an unreadable reference graph fails the inventory rather than recording it empty" "1" "$RC"
check_equals "the failure names the manifest it could not resolve" \
  "1" "$(grep -c 'reference graph for routemax/api@sha256:idx' "${TMP_ROOT}/backfill.err")"
check_equals "no half-written inventory file is left behind" \
  "false" "$([[ -f "${TMP_ROOT}/inv-unreadable.json" ]] && echo true || echo false)"

# Absent changeableAttributes must default to unlocked, never to locked, or the
# cleanup would skip everything it cannot read attributes for.
reset_stub \
  '200|{"tags":[{"name":"2.0.0","digest":"sha256:b"}]}|' \
  '200|{"manifests":[{"digest":"sha256:b"}]}|'
acr_inventory_repository routemax/api "${TMP_ROOT}/inv2.json" 2>/dev/null
check_equals "missing attributes default to write_enabled true" \
  "true" "$(jq -r '.tags[0].write_enabled' "${TMP_ROOT}/inv2.json")"
check_equals "missing attributes default to delete_enabled true" \
  "true" "$(jq -r '.tags[0].delete_enabled' "${TMP_ROOT}/inv2.json")"

mkdir -p "${TMP_ROOT}/merge/inventory"
cp "${TMP_ROOT}/inv.json" "${TMP_ROOT}/merge/inventory/one.json"
cp "${TMP_ROOT}/inv2.json" "${TMP_ROOT}/merge/inventory/two.json"
( acr_inventory_merge "${TMP_ROOT}/merge" ) >/dev/null 2>&1

check_equals "merged totals count tags" \
  "2" "$(jq -r '.totals.tags' "${TMP_ROOT}/merge/inventory.json")"
check_equals "merged totals count locked tags" \
  "1" "$(jq -r '.totals.locked_tags' "${TMP_ROOT}/merge/inventory.json")"

echo "acr-api: targeted inventory"

# Catalog, then tags + manifests for each of the two requested repositories.
reset_stub \
  '200|{"repositories":["routemax/api","routemax/ui","tools/kubectl"]}|' \
  '200|{"tags":[{"name":"1.0.0","digest":"sha256:a"}]}|' '200|{"manifests":[]}|' \
  '200|{"tags":[{"name":"2.0.0","digest":"sha256:b"}]}|' '200|{"manifests":[]}|'
mkdir -p "${TMP_ROOT}/targeted"
( acr_inventory_all "${TMP_ROOT}/targeted" "routemax/api,routemax/ui" ) >/dev/null 2>&1; RC=$?
check_equals "targeted inventory succeeds" "0" "$RC"
check_equals "only the named repositories are inventoried" \
  "2" "$(jq '.totals.repositories' "${TMP_ROOT}/targeted/inventory.json")"
check_equals "the catalog is still read once, to validate names" \
  "1" "$(stub_log_matches '_catalog')"

reset_stub '200|{"repositories":["routemax/api"]}|'
if ( acr_inventory_all "${TMP_ROOT}/targeted" "routemax/api,routemax/typo" ) >/dev/null 2>&1; then
  fail_test "an unknown repository name fails instead of inventorying nothing"
else
  pass "an unknown repository name fails instead of inventorying nothing"
fi

echo "acr-api: large repositories"

# A real repository has ~10k tags. Passing that through --argjson exceeds ARG_MAX
# and jq dies with "Argument list too long", so the payload must go via files.
LARGE_TAGS="$(jq -nc '[range(8000) | {
  name: ("5.6.0-PullRequest\(.).1"),
  digest: ("sha256:" + (. | tostring)),
  createdTime: "2026-01-01T00:00:00Z",
  lastUpdateTime: "2026-01-02T00:00:00Z",
  changeableAttributes: { writeEnabled: true, deleteEnabled: true }
}]')"
check_equals "large fixture exceeds a typical ARG_MAX" \
  "yes" "$([[ ${#LARGE_TAGS} -gt 1048576 ]] && echo yes || echo no)"

reset_stub \
  "200|{\"tags\":${LARGE_TAGS}}|" \
  '200|{"manifests":[]}|'
if acr_inventory_repository routemax/ui "${TMP_ROOT}/inv-large.json" 2>/dev/null; then
  pass "large repository inventory succeeds"
else
  fail_test "large repository inventory succeeds"
fi
check_equals "all tags survive the large payload" \
  "8000" "$(jq -r '.tags | length' "${TMP_ROOT}/inv-large.json" 2>/dev/null)"

echo "acr-api: real transport"

# curl prints %{http_code} even when the transfer failed, so a reset after the
# headers used to become "200000": not 2xx, not retryable, run over. The exit
# code must win.
FAKE_CURL="${TMP_ROOT}/fake-curl"
cat > "$FAKE_CURL" <<'SH'
#!/usr/bin/env bash
printf '%s' "${FAKE_CURL_STATUS}"
exit "${FAKE_CURL_EXIT}"
SH
chmod +x "$FAKE_CURL"
ACR_CURL_BIN="$FAKE_CURL"
check_equals "a completed transfer reports its status" \
  "200" "$(FAKE_CURL_STATUS=200 FAKE_CURL_EXIT=0 _acr_http GET https://x/y tok "" /dev/null /dev/null)"
check_equals "a transfer that failed after the headers is a transport error, not 200000" \
  "000" "$(FAKE_CURL_STATUS=200 FAKE_CURL_EXIT=56 _acr_http GET https://x/y tok "" /dev/null /dev/null)"
check_equals "a timeout is a transport error, not 000000" \
  "000" "$(FAKE_CURL_STATUS=000 FAKE_CURL_EXIT=28 _acr_http GET https://x/y tok "" /dev/null /dev/null)"
check_equals "a transport error is retryable" \
  "0" "$(_acr_should_retry 000; echo $?)"
ACR_CURL_BIN=curl

echo "acr-api: parallel index resolution"

# Lookups run several at a time, so the plan-order stub cannot serve them.
# This stub answers by URL instead: the bulk calls from the plan file, each
# per-digest GET from the digest in its path.
stub_by_url() {
  local method="$1" url="$2" token="$3" body="$4" out_body="$5" out_headers="$6"
  printf '%s %s\n' "$method" "$url" >> "$STUB_LOG_FILE"
  : > "$out_headers"
  case "$url" in
    */_manifests/sha256:idx-forbidden)
      : > "$out_body"; printf '403' ;;
    */_manifests/sha256:idx-*)
      local n="${url##*/_manifests/sha256:idx-}"
      printf '{"manifest":{"references":[{"digest":"sha256:child-%s-a"},{"digest":"sha256:child-%s-b"}]}}' "$n" "$n" > "$out_body"
      printf '200' ;;
    *) stub_transport "$@" ;;
  esac
}
ACR_TRANSPORT_FN=stub_by_url

MANY_INDICES="$(jq -nc '[range(1; 13) | {digest: "sha256:idx-\(.)", tags: ["\(.).0.0"], mediaType: "application/vnd.oci.image.index.v1+json", references: []}]')"
reset_stub '200|{"tags":[]}|' "200|{\"manifests\":${MANY_INDICES}}|"
acr_inventory_repository routemax/api "${TMP_ROOT}/inv-parallel.json" 2>/dev/null
check_equals "every index is resolved when lookups run in parallel" \
  "12" "$(jq '[.manifests[] | select(.references | length == 2)] | length' "${TMP_ROOT}/inv-parallel.json")"
check_equals "each index gets its own children, not a neighbour's" \
  "sha256:child-7-a sha256:child-7-b" \
  "$(jq -r '.manifests[] | select(.digest == "sha256:idx-7") | .references | join(" ")' "${TMP_ROOT}/inv-parallel.json")"
check_equals "each index costs exactly one lookup" \
  "12" "$(stub_log_matches '/_manifests/sha256:idx-')"

# The failure must say what actually came back, and how far it got: without
# the status the only way to diagnose a run that died 3,000 lookups in was to
# replay the call by hand.
FORBIDDEN_MIX="$(jq -nc '[range(1; 4) | {digest: "sha256:idx-\(.)", tags: [], mediaType: "application/vnd.oci.image.index.v1+json", references: []}] + [{digest: "sha256:idx-forbidden", tags: [], mediaType: "application/vnd.oci.image.index.v1+json", references: []}]')"
reset_stub '200|{"tags":[]}|' "200|{\"manifests\":${FORBIDDEN_MIX}}|"
( acr_inventory_repository routemax/api "${TMP_ROOT}/inv-forbidden.json" ) >/dev/null 2>"${TMP_ROOT}/forbidden.err"; RC=$?
check_equals "one unreadable index still fails the whole repository" "1" "$RC"
check_equals "the failure reports the HTTP status that came back" \
  "1" "$(grep -c 'routemax/api@sha256:idx-forbidden: HTTP 403' "${TMP_ROOT}/forbidden.err")"
check_equals "the failure reports how many lookups had succeeded" \
  "1" "$(grep -c 'after resolving [0-9]*/4' "${TMP_ROOT}/forbidden.err")"
ACR_TRANSPORT_FN=stub_transport

echo "acr-api: inventory merge safety"

# The 2026-09-13 incident: a straggler repository job (usually the largest,
# slowest one) had not finished writing its file when the merge ran, and it
# silently dropped out of inventory.json with no error. acr_inventory_merge
# now takes the list of repositories the caller actually intended to
# inventory and fails closed if any of them is missing from what got merged.
mkdir -p "${TMP_ROOT}/merge-safety/inventory"
cat > "${TMP_ROOT}/merge-safety/inventory/one.json" <<'JSON'
{"repository":"routemax/api","tags":[],"manifests":[]}
JSON
cat > "${TMP_ROOT}/merge-safety/inventory/two.json" <<'JSON'
{"repository":"routemax/ui","tags":[],"manifests":[]}
JSON

( acr_inventory_merge "${TMP_ROOT}/merge-safety" '["routemax/api","routemax/ui"]' ) >/dev/null 2>&1; RC=$?
check_equals "merge succeeds when every expected repository is present" "0" "$RC"

( acr_inventory_merge "${TMP_ROOT}/merge-safety" '["routemax/api","routemax/ui","routemax/missing"]' ) \
  >/dev/null 2>"${TMP_ROOT}/merge-missing.err"; RC=$?
check_equals "merge fails closed when an expected repository never landed" "1" "$RC"
check_equals "the failure names the missing repository" \
  "1" "$(grep -c 'routemax/missing' "${TMP_ROOT}/merge-missing.err")"

( acr_inventory_merge "${TMP_ROOT}/merge-safety" ) >/dev/null 2>&1; RC=$?
check_equals "omitting the expected-repositories argument keeps the old, unchecked behaviour" "0" "$RC"

echo "acr-api: parallel inventory does not drop a repository at a batch boundary"

# Same config as the top of this file, but parallel_repo_jobs lowered to 2 so
# that 5 repositories force multiple wait-then-launch-more batches, exercising
# the boundary the old counter-based wait -n could lose track of at.
config_init --file "${TMP_ROOT}/config.yaml" --work-dir "${TMP_ROOT}/work-batch" \
  --set run_settings.parallel_repo_jobs=2 >/dev/null 2>&1 \
  || { echo "test setup failed: batch config did not load"; exit 1; }

reset_stub \
  '200|{"repositories":["r1","r2","r3","r4","r5"]}|' \
  '200|{"tags":[{"name":"1.0.0","digest":"sha256:1"}]}|' '200|{"manifests":[]}|' \
  '200|{"tags":[{"name":"1.0.0","digest":"sha256:2"}]}|' '200|{"manifests":[]}|' \
  '200|{"tags":[{"name":"1.0.0","digest":"sha256:3"}]}|' '200|{"manifests":[]}|' \
  '200|{"tags":[{"name":"1.0.0","digest":"sha256:4"}]}|' '200|{"manifests":[]}|' \
  '200|{"tags":[{"name":"1.0.0","digest":"sha256:5"}]}|' '200|{"manifests":[]}|'
mkdir -p "${TMP_ROOT}/batch"
( acr_inventory_all "${TMP_ROOT}/batch" "r1,r2,r3,r4,r5" ) >/dev/null 2>&1; RC=$?
check_equals "inventory with more repositories than parallel_repo_jobs succeeds" "0" "$RC"
check_equals "every repository launched across batch boundaries lands in the merge, none dropped" \
  "5" "$(jq '.totals.repositories' "${TMP_ROOT}/batch/inventory.json")"
check_equals "no repository is missing or duplicated in the merged output" \
  "r1 r2 r3 r4 r5" "$(jq -r '[.repositories[].repository] | sort | join(" ")' "${TMP_ROOT}/batch/inventory.json")"

# Restore the default config in case anything is ever appended after this point.
config_init --file "${TMP_ROOT}/config.yaml" --work-dir "${TMP_ROOT}/work" >/dev/null 2>&1

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
