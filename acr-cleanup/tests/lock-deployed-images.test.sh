#!/usr/bin/env bash
#
# Unit tests for deploy/lock-deployed-images.sh: environment gating, image
# extraction from a Helm manifest, and the lock calls. ACR is stubbed.
#
#   ./tests/lock-deployed-images.test.sh

set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname -- "$TESTS_DIR")"

# Sourcing the script loads its functions without running main.
# shellcheck source=../deploy/lock-deployed-images.sh
source "${MODULE_DIR}/deploy/lock-deployed-images.sh"
set +e

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
  lock_at_deploy:
    enabled: true
    environments:
      include: [ "PROD" ]
      exclude: [ "SEC" ]
YAML

cat > "${TMP_ROOT}/manifest.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    tags.datadoghq.com/env: "mprod-01"
spec:
  template:
    spec:
      containers:
        - name: api
          image: "rmxacrcommon.azurecr.io/routemax/api:5.5.0-beta.1-136"
        - name: ui
          image: rmxacrcommon.azurecr.io/routemax/ui:5.5.0-beta.1-136
        - name: api-again
          image: "rmxacrcommon.azurecr.io/routemax/api:5.5.0-beta.1-136"
        - name: keda
          image: ghcr.io/kedacore/keda:2.14.0
        - name: pinned
          image: rmxacrcommon.azurecr.io/routemax/osrm@sha256:abc
YAML

CALLS="${TMP_ROOT}/calls"
: > "$CALLS"

# Stubs. acr_request answers the tag read (with digest) and the manifest read.
acr_init() { printf 'init\n' >> "$CALLS"; ACR_LOGIN_SERVER="rmxacrcommon.azurecr.io"; }
acr_request() {
  local path="$2"
  printf 'GET %s\n' "$path" >> "$CALLS"
  case "$path" in
    */_tags/missing*) ACR_HTTP_STATUS=404; return 1 ;;
    */_tags/locked*)  ACR_HTTP_STATUS=200; ACR_HTTP_BODY='{"tag":{"digest":"sha256:l","changeableAttributes":{"writeEnabled":true,"deleteEnabled":false}}}'; return 0 ;;
    */_tags/*)        ACR_HTTP_STATUS=200; ACR_HTTP_BODY='{"tag":{"digest":"sha256:d1","changeableAttributes":{"writeEnabled":true,"deleteEnabled":true}}}'; return 0 ;;
    */_manifests/sha256:l) ACR_HTTP_STATUS=200; ACR_HTTP_BODY='{"manifest":{"changeableAttributes":{"writeEnabled":true,"deleteEnabled":false}}}'; return 0 ;;
    */_manifests/*)   ACR_HTTP_STATUS=200; ACR_HTTP_BODY='{"manifest":{"changeableAttributes":{"writeEnabled":true,"deleteEnabled":true}}}'; return 0 ;;
  esac
}
acr_set_tag_attributes()      { printf 'PATCH tag %s %s write=%s delete=%s\n' "$@" >> "$CALLS"; [[ "$2" != *fails* ]]; }
acr_set_manifest_attributes() { printf 'PATCH manifest %s %s write=%s delete=%s\n' "$@" >> "$CALLS"; return 0; }

run_lock() { ( lock_main "$@" ) >/dev/null 2>&1; }

echo "lock-deployed-images: environment gate"
config_init --file "${TMP_ROOT}/config.yaml" --work-dir "${TMP_ROOT}/w0" >/dev/null 2>&1
if lock_environment_qualifies "MPROD-EUS-01" 2>/dev/null; then pass "PROD environment qualifies"; else fail_test "PROD environment qualifies"; fi
if lock_environment_qualifies "sprod-wus2" 2>/dev/null; then pass "matching is case-insensitive"; else fail_test "matching is case-insensitive"; fi
if lock_environment_qualifies "SEFL-DEV-01" 2>/dev/null; then fail_test "non-prod environment is skipped"; else pass "non-prod environment is skipped"; fi
if lock_environment_qualifies "SEC-PROD-01" 2>/dev/null; then fail_test "exclude wins over include"; else pass "exclude wins over include"; fi

echo "lock-deployed-images: image extraction"
IMAGES="$(lock_images_from_manifest < "${TMP_ROOT}/manifest.yaml")"
check_equals "our tagged images are collected, deduplicated" "2" "$(jq 'length' <<<"$IMAGES")"
check_equals "third-party images are ignored" "0" "$(jq '[ .[] | select(.repository | test("keda")) ] | length' <<<"$IMAGES")"
check_equals "digest-pinned references are left alone" "0" "$(jq '[ .[] | select(.repository == "routemax/osrm") ] | length' <<<"$IMAGES")"

echo "lock-deployed-images: locking"
: > "$CALLS"
run_lock --config "${TMP_ROOT}/config.yaml" --environment MPROD-01 --manifest-file "${TMP_ROOT}/manifest.yaml" --work-dir "${TMP_ROOT}/w1"; RC=$?
check_equals "lock run succeeds" "0" "$RC"
check_equals "one ACR login per run" "1" "$(grep -c '^init$' "$CALLS")"
check_equals "each tag is locked for delete only, write untouched" \
  "2" "$(grep -c '^PATCH tag routemax/[a-z]* 5.5.0-beta.1-136 write=true delete=false$' "$CALLS")"
check_equals "each manifest is locked too" \
  "2" "$(grep -c '^PATCH manifest routemax/[a-z]* sha256:d1 write=true delete=false$' "$CALLS")"

: > "$CALLS"
run_lock --config "${TMP_ROOT}/config.yaml" --environment SEFL-DEV-01 --manifest-file "${TMP_ROOT}/manifest.yaml" --work-dir "${TMP_ROOT}/w2"; RC=$?
check_equals "non-prod run exits 0" "0" "$RC"
check_equals "non-prod run touches nothing" "0" "$(wc -l < "$CALLS" | tr -d ' ')"

: > "$CALLS"
run_lock --config "${TMP_ROOT}/config.yaml" --environment MPROD-01 --manifest-file "${TMP_ROOT}/manifest.yaml" --work-dir "${TMP_ROOT}/w3" --dry-run; RC=$?
check_equals "dry run exits 0" "0" "$RC"
check_equals "dry run reads but never patches" "0" "$(grep -c '^PATCH' "$CALLS")"

: > "$CALLS"
ACR_CLEANUP_SET='image_lock.lock_at_deploy.enabled=false' \
  run_lock --config "${TMP_ROOT}/config.yaml" --environment MPROD-01 --manifest-file "${TMP_ROOT}/manifest.yaml" --work-dir "${TMP_ROOT}/w4"; RC=$?
check_equals "disabled lock_at_deploy exits 0" "0" "$RC"
check_equals "disabled lock_at_deploy touches nothing" "0" "$(wc -l < "$CALLS" | tr -d ' ')"

echo "lock-deployed-images: idempotence and failures"
sed 's/5.5.0-beta.1-136/locked-1/' "${TMP_ROOT}/manifest.yaml" > "${TMP_ROOT}/manifest-locked.yaml"
: > "$CALLS"
run_lock --config "${TMP_ROOT}/config.yaml" --environment MPROD-01 --manifest-file "${TMP_ROOT}/manifest-locked.yaml" --work-dir "${TMP_ROOT}/w5"; RC=$?
check_equals "already-locked images exit 0" "0" "$RC"
check_equals "already-locked images are not patched again" "0" "$(grep -c '^PATCH' "$CALLS")"

sed 's/routemax\/api:5.5.0-beta.1-136/routemax\/api:missing-1/' "${TMP_ROOT}/manifest.yaml" > "${TMP_ROOT}/manifest-missing.yaml"
: > "$CALLS"
run_lock --config "${TMP_ROOT}/config.yaml" --environment MPROD-01 --manifest-file "${TMP_ROOT}/manifest-missing.yaml" --work-dir "${TMP_ROOT}/w6"; RC=$?
check_equals "a tag missing from the registry gives exit 2" "2" "$RC"
check_equals "the other image is still locked" "1" "$(grep -c '^PATCH tag routemax/ui' "$CALLS")"

if run_lock --config "${TMP_ROOT}/config.yaml" --environment MPROD-01 --work-dir "${TMP_ROOT}/w7"; then
  fail_test "missing manifest source is a usage error"
else
  pass "missing manifest source is a usage error"
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
