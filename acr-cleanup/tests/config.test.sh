#!/usr/bin/env bash
#
# Unit tests for lib/config.sh. Pure: no Azure, no network, no cluster access.
#
#   ./tests/config.test.sh

set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname -- "$TESTS_DIR")"

# shellcheck source=../lib/common.sh
source "${MODULE_DIR}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${MODULE_DIR}/lib/config.sh"

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

# Writes a config YAML built from a valid base plus an optional override block.
write_config() {
  local path="$1"
  cat > "$path" <<'YAML'
registry:
  name: testacr
  resource_group: test-rg
  subscription_id: 00000000-0000-0000-0000-000000000000
never_delete:
  tag_patterns:
    - { pattern: '^latest$', reason: "floating tag" }
image_cleanup_rules:
  - tag_group: legacy_inuse_markers
    tag_pattern: '-inUse$'
    delete_when_older_than_days: 0
    always_keep_newest: 0
    example_tags: [ '1.2.3-alpha.4-dev-01-inUse' ]
  - tag_group: pull_request_builds
    tag_pattern: '^[0-9]+\.[0-9]+\.[0-9]+-PullRequest[0-9]+\.'
    delete_when_older_than_days: 7
    always_keep_newest: 2
    example_tags: [ '1.2.3-PullRequest999.4' ]
  - tag_group: develop_builds
    tag_pattern: '^[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+'
    delete_when_older_than_days: 45
    always_keep_newest: 10
    example_tags: [ '1.2.3-alpha.4' ]
in_use_protection:
  clusters:
    - name: test-aks
      resource_group: test-rg
      service_connection: sc-test
YAML
  [[ $# -gt 1 ]] && printf '%s\n' "$2" >> "$path"
  return 0
}

# Runs config_init in a subshell so a validation failure does not kill the suite.
try_config() {
  local yaml="$1"; shift
  local work_dir
  work_dir="$(mktemp -d "${TMP_ROOT}/work.XXXXXX")"
  (
    config_init --file "$yaml" --work-dir "$work_dir" "$@" >/dev/null 2>&1
    jq -c '.' "${work_dir}/config.json"
  )
}

expect_invalid() {
  local label="$1" extra_yaml="$2"
  local yaml="${TMP_ROOT}/$(printf '%s' "$label" | tr -c 'a-zA-Z0-9' '_').yaml"
  write_config "$yaml" "$extra_yaml"
  if try_config "$yaml" >/dev/null 2>&1; then
    fail_test "$label (expected validation to fail, but it passed)"
  else
    pass "$label"
  fi
}

echo "config: loading and defaults"
BASE_YAML="${TMP_ROOT}/base.yaml"
write_config "$BASE_YAML"
BASE_JSON="$(try_config "$BASE_YAML")" || { echo "base config failed to load"; exit 1; }

check_equals "registry name is read from file" \
  "testacr" "$(jq -r '.registry.name' <<<"$BASE_JSON")"
check_equals "dry_run defaults to true" \
  "true" "$(jq -r '.run_settings.dry_run' <<<"$BASE_JSON")"
check_equals "min_untagged_manifest_age_days defaults to 14" \
  "14" "$(jq -r '.in_use_protection.min_untagged_manifest_age_days' <<<"$BASE_JSON")"
check_equals "cluster required defaults to true" \
  "true" "$(jq -r '.in_use_protection.clusters[0].required' <<<"$BASE_JSON")"
check_equals "string never_delete entries are normalized to objects" \
  "^latest$" "$(jq -r '.never_delete.tag_patterns[0].pattern' <<<"$BASE_JSON")"
check_equals "lock_at_deploy defaults to PROD only" \
  "PROD" "$(jq -r '.image_lock.lock_at_deploy.environments.include[0]' <<<"$BASE_JSON")"

echo "config: overrides"
OVERRIDDEN="$(try_config "$BASE_YAML" --set 'run_settings.dry_run=false')"
check_equals "--set coerces false to a boolean" \
  "false" "$(jq -r '.run_settings.dry_run | tostring + ":" + (type)' <<<"$OVERRIDDEN" | cut -d: -f1)"
check_equals "--set produces a real boolean, not a string" \
  "boolean" "$(jq -r '.run_settings.dry_run | type' <<<"$OVERRIDDEN")"

OVERRIDDEN="$(try_config "$BASE_YAML" --set 'run_settings.parallel_delete_workers=8')"
check_equals "--set coerces integers" \
  "number" "$(jq -r '.run_settings.parallel_delete_workers | type' <<<"$OVERRIDDEN")"
check_equals "--set applies the integer value" \
  "8" "$(jq -r '.run_settings.parallel_delete_workers' <<<"$OVERRIDDEN")"

OVERRIDDEN="$(try_config "$BASE_YAML" --set 'rule.pull_request_builds.delete_when_older_than_days=3')"
check_equals "rules are addressable by name, not index" \
  "3" "$(jq -r '.image_cleanup_rules[] | select(.tag_group=="pull_request_builds") | .delete_when_older_than_days' <<<"$OVERRIDDEN")"
check_equals "addressing one rule by name leaves the others alone" \
  "45" "$(jq -r '.image_cleanup_rules[] | select(.tag_group=="develop_builds") | .delete_when_older_than_days' <<<"$OVERRIDDEN")"

OVERRIDDEN="$(ACR_CLEANUP_SET='run_settings.parallel_repo_jobs=2' try_config "$BASE_YAML")"
check_equals "ACR_CLEANUP_SET env overrides the file" \
  "2" "$(jq -r '.run_settings.parallel_repo_jobs' <<<"$OVERRIDDEN")"

OVERRIDDEN="$(ACR_CLEANUP_SET='run_settings.parallel_repo_jobs=2' \
  try_config "$BASE_YAML" --set 'run_settings.parallel_repo_jobs=5')"
check_equals "--set wins over ACR_CLEANUP_SET" \
  "5" "$(jq -r '.run_settings.parallel_repo_jobs' <<<"$OVERRIDDEN")"

echo "config: validation rejects bad input"
expect_invalid "missing registry name" "$(printf 'registry:\n  name: ""\n')"
expect_invalid "empty cluster list" "$(printf 'in_use_protection:\n  clusters: []\n')"
expect_invalid "unknown cluster_access_mode" "$(printf 'in_use_protection:\n  cluster_access_mode: ssh\n')"
expect_invalid "cluster missing service_connection" \
  "$(printf 'in_use_protection:\n  clusters:\n    - { name: a, resource_group: b }\n')"
expect_invalid "parallel_delete_workers above the ceiling" \
  "$(printf 'run_settings:\n  parallel_delete_workers: 999\n')"
expect_invalid "parallel_reference_lookups above the ceiling" \
  "$(printf 'run_settings:\n  parallel_reference_lookups: 99\n')"
expect_invalid "parallel_reference_lookups of zero" \
  "$(printf 'run_settings:\n  parallel_reference_lookups: 0\n')"
expect_invalid "helm_parallelism of zero" \
  "$(printf 'in_use_protection:\n  helm_parallelism: 0\n')"
expect_invalid "helm_parallelism above the ceiling" \
  "$(printf 'in_use_protection:\n  helm_parallelism: 99\n')"
expect_invalid "max_deletions_per_run of zero disables the circuit breaker" \
  "$(printf 'run_settings:\n  max_deletions_per_run: 0\n')"
expect_invalid "min_untagged_manifest_age_days below the recovery floor" \
  "$(printf 'in_use_protection:\n  min_untagged_manifest_age_days: 1\n')"
expect_invalid "email enabled with no recipients" \
  "$(printf 'email_report:\n  enabled: true\n  from: a@b.c\n  to: []\n')"
expect_invalid "lock_at_deploy enabled with no environments" \
  "$(printf 'image_lock:\n  lock_at_deploy:\n    enabled: true\n    environments:\n      include: []\n')"

echo "config: cleanup rule linting"
expect_invalid "duplicate tag_group names" "$(cat <<'YAML'
image_cleanup_rules:
  - { tag_group: dup, tag_pattern: '^a', delete_when_older_than_days: 1, always_keep_newest: 1 }
  - { tag_group: dup, tag_pattern: '^b', delete_when_older_than_days: 1, always_keep_newest: 1 }
YAML
)"

expect_invalid "PCRE shorthand that silently matches nothing in ERE" "$(cat <<'YAML'
image_cleanup_rules:
  - { tag_group: pcre, tag_pattern: '^\d+\.\d+', delete_when_older_than_days: 1, always_keep_newest: 1 }
YAML
)"

expect_invalid "invalid regex" "$(cat <<'YAML'
image_cleanup_rules:
  - { tag_group: broken, tag_pattern: '^[0-9', delete_when_older_than_days: 1, always_keep_newest: 1 }
YAML
)"

expect_invalid "missing delete_when_older_than_days" "$(cat <<'YAML'
image_cleanup_rules:
  - { tag_group: incomplete, tag_pattern: '^a', always_keep_newest: 1 }
YAML
)"

expect_invalid "example tag does not match its own rule" "$(cat <<'YAML'
image_cleanup_rules:
  - tag_group: mismatched
    tag_pattern: '^[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+'
    delete_when_older_than_days: 1
    always_keep_newest: 1
    example_tags: [ '1.2.3-beta.1-4' ]
YAML
)"

# The bug this whole mechanism exists for: an inUse marker is a suffix, so a
# broader rule placed above it claims the tag first and it is never cleaned.
expect_invalid "rule shadowed by an earlier rule" "$(cat <<'YAML'
image_cleanup_rules:
  - tag_group: devops_builds
    tag_pattern: '^[0-9]+\.[0-9]+\.[0-9]+-devops-'
    delete_when_older_than_days: 21
    always_keep_newest: 3
  - tag_group: legacy_inuse_markers
    tag_pattern: '-inUse$'
    delete_when_older_than_days: 0
    always_keep_newest: 0
    example_tags: [ '5.6.0-devops-280892.1-105-dev-03-inUse' ]
YAML
)"

echo "config: the shipped RouteMAX config"
if try_config "${MODULE_DIR}/config/routemax.yaml" >/dev/null 2>&1; then
  pass "config/routemax.yaml is valid"
else
  fail_test "config/routemax.yaml failed validation"
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
