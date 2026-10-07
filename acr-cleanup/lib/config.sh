#!/usr/bin/env bash
# Config loading, override handling and validation.
#
# Everything downstream of this file works on JSON, never YAML: the config is
# converted once here so the rest of the module only needs jq.
#
# Precedence, lowest to highest:
#   built-in defaults -> config file -> ACR_CLEANUP_SET env var -> --set on the CLI
#
# Object keys are merged recursively; arrays are REPLACED, not concatenated.
# Setting image_cleanup_rules in your file therefore replaces the whole list.
#
# Public API:
#   config_init --file F --work-dir D [--set path=value]...
#   config_get <jq-filter>        scalar, raw output
#   config_get_json <jq-filter>   raw JSON
#   config_hash                   sha256 of the effective config, for the report
#   config_path                   path to the effective config JSON

CONFIG_JSON=""

# Patterns are matched with grep -E (POSIX ERE) everywhere in this module.
# These PCRE shorthands look right but silently match nothing in ERE.
readonly _CONFIG_PCRE_ISMS='\\d|\\w|\\s|\\b|\(\?'

config_path() { printf '%s' "$CONFIG_JSON"; }

config_get() { jq -r "$1" "$CONFIG_JSON"; }

config_get_json() { jq -c "$1" "$CONFIG_JSON"; }

config_hash() { sha256_stdin < "$CONFIG_JSON"; }

_config_defaults() {
  cat <<'JSON'
{
  "registry": {
    "name": "",
    "resource_group": "",
    "subscription_id": "",
    "service_connection": "",
    "host_aliases": []
  },
  "never_delete": {
    "repositories": [],
    "tag_patterns": []
  },
  "image_cleanup_rules": [],
  "in_use_protection": {
    "keep_helm_revisions": 3,
    "min_untagged_manifest_age_days": 14,
    "cluster_access_mode": "kubectl",
    "report_unlisted_clusters": true,
    "helm_parallelism": 6,
    "protect_tag_across_repositories": false,
    "clusters": []
  },
  "image_lock": {
    "lock_at_deploy": {
      "enabled": true,
      "environments": { "include": ["PROD"], "exclude": ["SEC"] }
    },
    "unlock_when_unused": {
      "enabled": true,
      "wait_days_before_unlocking": 14,
      "never_unlock": { "repositories": [], "tag_patterns": [] }
    }
  },
  "run_settings": {
    "dry_run": true,
    "parallel_delete_workers": 24,
    "parallel_repo_jobs": 6,
    "parallel_reference_lookups": 8,
    "max_deletions_per_run": 20000
  },
  "email_report": {
    "enabled": false,
    "api_key_variable": "SENDGRID_API_KEY",
    "from": "",
    "to": [],
    "attach_json": true
  }
}
JSON
}

_config_yaml_to_json() {
  local yaml_file="$1"
  if command -v yq >/dev/null 2>&1; then
    yq -o=json '.' "$yaml_file"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys, yaml
with open(sys.argv[1]) as handle:
    print(json.dumps(yaml.safe_load(handle) or {}))
' "$yaml_file"
  else
    fail "need yq or python3 with PyYAML to read $yaml_file"
  fi
}

# "a.b.c" -> ["a","b","c"]; all-digit segments become array indices.
_config_to_jq_path() {
  jq -cn --arg p "$1" '
    $p | split(".") | map(if test("^[0-9]+$") then tonumber else . end)
  '
}

_config_coerce_value() {
  local value="$1"
  case "$value" in
    true|false|null) printf '%s' "$value" ;;
    \[*|\{*)        printf '%s' "$value" ;;
    *)
      if [[ "$value" =~ ^-?[0-9]+$ || "$value" =~ ^-?[0-9]*\.[0-9]+$ ]]; then
        printf '%s' "$value"
      else
        jq -Rn --arg s "$value" '$s'
      fi
      ;;
  esac
}

# Applies one "path=value" override to the config file in place.
#
# Rules can be addressed by name instead of index, because index-based
# overrides break the moment somebody reorders the list:
#   rule.pull_request_builds.delete_when_older_than_days=3
_config_apply_override() {
  local assignment="$1" work_file="$2"
  local path="${assignment%%=*}"
  local raw_value="${assignment#*=}"

  [[ "$assignment" == *=* ]] || fail "--set expects path=value, got: $assignment"

  if [[ "$path" == rule.* ]]; then
    local rest="${path#rule.}"
    local tag_group="${rest%%.*}"
    local field="${rest#*.}"
    [[ "$field" != "$rest" ]] || fail "--set rule.<tag_group>.<field> expected, got: $path"

    local index
    index=$(jq -r --arg g "$tag_group" \
      'first(.image_cleanup_rules | to_entries[] | select(.value.tag_group == $g) | .key) // "none"' \
      "$work_file")
    [[ "$index" != "none" ]] || fail "--set $path: no rule with tag_group '$tag_group'"
    path="image_cleanup_rules.${index}.${field}"
  fi

  local jq_path value tmp
  jq_path=$(_config_to_jq_path "$path")
  value=$(_config_coerce_value "$raw_value")
  tmp="${work_file}.tmp"

  jq --argjson path "$jq_path" --argjson value "$value" \
    'setpath($path; $value)' "$work_file" > "$tmp" || fail "invalid --set: $assignment"
  mv "$tmp" "$work_file"
}

# Fills in per-item defaults so downstream stages never have to test for absent keys.
_config_normalize() {
  local work_file="$1"
  local tmp="${work_file}.tmp"
  jq '
    def as_entry: if type == "string" then { name: ., reason: "" } else . end;
    def as_pattern: if type == "string" then { pattern: ., reason: "" } else . end;

    .never_delete.repositories       |= map(as_entry)
    | .never_delete.tag_patterns     |= map(as_pattern)
    | .image_lock.unlock_when_unused.never_unlock.repositories  |= map(as_entry)
    | .image_lock.unlock_when_unused.never_unlock.tag_patterns  |= map(as_pattern)
    | .in_use_protection.clusters    |= map(. + { required: (.required // true) })
    | .image_cleanup_rules           |= map(. + { example_tags: (.example_tags // []) })
    | .registry.host_aliases         |= (. // [])
  ' "$work_file" > "$tmp"
  mv "$tmp" "$work_file"
}

# grep -E returns 0 (match), 1 (no match) or 2 (bad pattern).
_config_regex_is_valid() {
  printf '' | grep -Eq -- "$1" 2>/dev/null
  (($? != 2))
}

_config_validate() {
  local errors=() rules_count i

  local key
  for key in name resource_group subscription_id; do
    [[ -n "$(config_get ".registry.${key} // \"\"")" ]] \
      || errors+=("registry.${key} is required")
  done

  local access_mode
  access_mode=$(config_get '.in_use_protection.cluster_access_mode')
  [[ "$access_mode" == "kubectl" || "$access_mode" == "aks_run_command" ]] \
    || errors+=("in_use_protection.cluster_access_mode must be kubectl or aks_run_command, got '$access_mode'")

  local cluster_count
  cluster_count=$(config_get '.in_use_protection.clusters | length')
  ((cluster_count > 0)) || errors+=("in_use_protection.clusters must list at least one cluster")

  local missing_cluster_fields
  missing_cluster_fields=$(config_get '
    [ .in_use_protection.clusters[]
      | select((.name // "") == "" or (.resource_group // "") == "" or (.service_connection // "") == "")
      | (.name // "<unnamed>") ] | join(", ")')
  [[ -z "$missing_cluster_fields" ]] \
    || errors+=("clusters missing name/resource_group/service_connection: $missing_cluster_fields")

  rules_count=$(config_get '.image_cleanup_rules | length')
  ((rules_count > 0)) || errors+=("image_cleanup_rules must contain at least one rule")

  local duplicate_groups
  duplicate_groups=$(config_get '
    [ .image_cleanup_rules[].tag_group
      | select(. != null) ] | group_by(.) | map(select(length > 1) | .[0]) | join(", ")')
  [[ -z "$duplicate_groups" ]] || errors+=("duplicate tag_group names: $duplicate_groups")

  for ((i = 0; i < rules_count; i++)); do
    local group pattern days keep
    group=$(config_get ".image_cleanup_rules[$i].tag_group // \"\"")
    pattern=$(config_get ".image_cleanup_rules[$i].tag_pattern // \"\"")
    days=$(config_get ".image_cleanup_rules[$i].delete_when_older_than_days // \"missing\"")
    keep=$(config_get ".image_cleanup_rules[$i].always_keep_newest // \"missing\"")

    [[ -n "$group" ]] || { errors+=("image_cleanup_rules[$i].tag_group is required"); continue; }
    [[ -n "$pattern" ]] || { errors+=("$group: tag_pattern is required"); continue; }

    _config_regex_is_valid "$pattern" \
      || errors+=("$group: tag_pattern is not a valid POSIX ERE: $pattern")

    if grep -Eq -- "$_CONFIG_PCRE_ISMS" <<<"$pattern"; then
      errors+=("$group: tag_pattern uses PCRE shorthand that matches nothing in ERE, use [0-9] [A-Za-z0-9_] etc: $pattern")
    fi

    [[ "$days" =~ ^[0-9]+$ ]] \
      || errors+=("$group: delete_when_older_than_days must be a non-negative integer, got '$days'")
    [[ "$keep" =~ ^[0-9]+$ ]] \
      || errors+=("$group: always_keep_newest must be a non-negative integer, got '$keep'")

    if [[ "$pattern" != ^* && "$pattern" != *\$ ]]; then
      warn "$group: tag_pattern is unanchored and will match substrings: $pattern"
    fi
  done

  # example_tags turn the rule list into its own test suite. This is the check that
  # catches a swapped or shadowed rule before it ever touches the registry.
  for ((i = 0; i < rules_count; i++)); do
    local group example_count j
    group=$(config_get ".image_cleanup_rules[$i].tag_group // \"\"")
    example_count=$(config_get ".image_cleanup_rules[$i].example_tags | length")

    for ((j = 0; j < example_count; j++)); do
      local example own_pattern k
      example=$(config_get ".image_cleanup_rules[$i].example_tags[$j]")
      own_pattern=$(config_get ".image_cleanup_rules[$i].tag_pattern")

      grep -Eq -- "$own_pattern" <<<"$example" \
        || errors+=("$group: example tag '$example' does not match its own tag_pattern")

      # classify.sh matches with jq's regex engine, validation with grep -E. Assert
      # the two agree on every example so a pattern cannot pass here and then
      # silently match nothing (or something else) at classification time.
      jq -en --arg p "$own_pattern" --arg t "$example" '$t | test($p)' >/dev/null 2>&1 \
        || errors+=("$group: example tag '$example' matches under grep -E but not under jq; use the common ERE subset")

      for ((k = 0; k < i; k++)); do
        local earlier_group earlier_pattern
        earlier_pattern=$(config_get ".image_cleanup_rules[$k].tag_pattern")
        if grep -Eq -- "$earlier_pattern" <<<"$example"; then
          earlier_group=$(config_get ".image_cleanup_rules[$k].tag_group")
          errors+=("$group is shadowed: example tag '$example' is claimed first by earlier rule '$earlier_group'")
        fi
      done
    done
  done

  local never_delete_count
  never_delete_count=$(config_get '.never_delete.tag_patterns | length')
  for ((i = 0; i < never_delete_count; i++)); do
    local pattern
    pattern=$(config_get ".never_delete.tag_patterns[$i].pattern // \"\"")
    [[ -n "$pattern" ]] || { errors+=("never_delete.tag_patterns[$i].pattern is required"); continue; }
    _config_regex_is_valid "$pattern" \
      || errors+=("never_delete.tag_patterns[$i]: not a valid POSIX ERE: $pattern")
    if grep -Eq -- "$_CONFIG_PCRE_ISMS" <<<"$pattern"; then
      errors+=("never_delete.tag_patterns[$i]: PCRE shorthand does not work in ERE: $pattern")
    fi
  done

  _config_validate_int in_use_protection.keep_helm_revisions 1 50 errors
  _config_validate_int in_use_protection.helm_parallelism 1 20 errors
  _config_validate_int in_use_protection.min_untagged_manifest_age_days 7 365 errors
  _config_validate_int image_lock.unlock_when_unused.wait_days_before_unlocking 7 365 errors
  _config_validate_int run_settings.parallel_delete_workers 1 64 errors
  _config_validate_int run_settings.parallel_repo_jobs 1 20 errors
  _config_validate_int run_settings.parallel_reference_lookups 1 32 errors
  _config_validate_int run_settings.max_deletions_per_run 1 1000000 errors

  local manifest_age
  manifest_age=$(config_get '.in_use_protection.min_untagged_manifest_age_days')
  if [[ "$manifest_age" =~ ^[0-9]+$ ]] && ((manifest_age < 14)); then
    warn "min_untagged_manifest_age_days is $manifest_age; on a weekly schedule this gives fewer than two reports before a manifest becomes unrecoverable"
  fi

  if [[ "$(config_get '.email_report.enabled')" == "true" ]]; then
    (($(config_get '.email_report.to | length') > 0)) \
      || errors+=("email_report.enabled is true but email_report.to is empty")
    [[ -n "$(config_get '.email_report.from // ""')" ]] \
      || errors+=("email_report.enabled is true but email_report.from is empty")
  fi

  if [[ "$(config_get '.image_lock.lock_at_deploy.enabled')" == "true" ]]; then
    (($(config_get '.image_lock.lock_at_deploy.environments.include | length') > 0)) \
      || errors+=("image_lock.lock_at_deploy.enabled is true but environments.include is empty, so nothing would ever be locked")
  fi

  if [[ "$(config_get '.image_lock.lock_at_deploy.enabled')" == "true" \
     && "$(config_get '.image_lock.unlock_when_unused.enabled')" == "false" ]]; then
    warn "image_lock is lock-only: images are locked on deploy and never unlocked. This is the behaviour that caused the original ACR bloat; use it for migration or observation only"
  fi

  if ((${#errors[@]} > 0)); then
    local error
    for error in "${errors[@]}"; do
      printf 'ERROR: config: %s\n' "$error" >&2
    done
    fail "config validation failed with ${#errors[@]} error(s)"
  fi
}

_config_validate_int() {
  local path="$1" min="$2" max="$3" array_name="$4"
  local -n target="$array_name"
  local value
  value=$(config_get ".${path}")
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    target+=("$path must be an integer, got '$value'")
  elif ((value < min || value > max)); then
    target+=("$path must be between $min and $max, got $value")
  fi
}

config_init() {
  local config_file="" work_dir="" overrides=()

  while (($# > 0)); do
    case "$1" in
      --file)     config_file="$2"; shift 2 ;;
      --work-dir) work_dir="$2";    shift 2 ;;
      --set)      overrides+=("$2"); shift 2 ;;
      *) fail "config_init: unknown argument '$1'" ;;
    esac
  done

  [[ -n "$config_file" ]] || fail "config_init: --file is required"
  [[ -f "$config_file" ]] || fail "config file not found: $config_file"
  [[ -n "$work_dir" ]] || fail "config_init: --work-dir is required"
  mkdir -p "$work_dir"

  local work_file="${work_dir}/config.json"
  local defaults_file="${work_dir}/.config-defaults.json"
  local user_file="${work_dir}/.config-user.json"

  _config_defaults > "$defaults_file"
  _config_yaml_to_json "$config_file" > "$user_file" \
    || fail "could not parse YAML: $config_file"

  # jq's `*` merges objects recursively and replaces arrays, which is the
  # behaviour we want: a user's rule list overrides ours wholesale.
  jq -s '.[0] * .[1]' "$defaults_file" "$user_file" > "$work_file"

  local env_overrides=()
  if [[ -n "${ACR_CLEANUP_SET:-}" ]]; then
    IFS=',' read -r -a env_overrides <<< "$ACR_CLEANUP_SET"
  fi

  local assignment trimmed
  for assignment in ${env_overrides[@]+"${env_overrides[@]}"}; do
    trimmed="$(printf '%s' "$assignment" | tr -d '[:space:]')"
    [[ -n "$trimmed" ]] && _config_apply_override "$trimmed" "$work_file"
  done
  for assignment in ${overrides[@]+"${overrides[@]}"}; do
    [[ -n "$assignment" ]] && _config_apply_override "$assignment" "$work_file"
  done

  _config_normalize "$work_file"
  rm -f "$defaults_file" "$user_file"

  CONFIG_JSON="$work_file"
  _config_validate
  log "config loaded from $config_file (effective config: $work_file, hash $(config_hash | cut -c1-12))"
}
