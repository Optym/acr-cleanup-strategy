#!/usr/bin/env bash
#
# Stage 2 - ACR data-plane client.
#
#   reads   the registry over REST
#   writes  <work-dir>/inventory.json
#   mutates nothing by itself; the untag/delete/lock helpers are called by
#           lib/execute.sh (stage 5) and lib/lock-reconcile.sh (stage 4)
#
# Everything goes over the ACR REST API rather than `az acr`, because `az` is a
# ~1.5 s Python process per call and parallel invocations serialize on the shared
# MSAL token-cache lock. At ~386k tags that difference is the whole run.
#
# Auth flow:
#   1. az acr login --expose-token  ->  ACR refresh token (once per run)
#   2. POST /oauth2/token           ->  scope-limited access token (cached, renewed)
#   3. Bearer that token against /acr/v1/... and /v2/...
#
# The transport is injected via ACR_TRANSPORT_FN so retry, pagination and
# fail-closed behaviour can be unit-tested without a registry.

# shellcheck shell=bash

ACR_LOGIN_SERVER=""
ACR_REFRESH_TOKEN=""
ACR_REFRESH_TOKEN_AT=0

# ACR refresh tokens last 3 h; renew well before that so a long delete phase
# cannot expire mid-run.
ACR_REFRESH_TOKEN_TTL="${ACR_REFRESH_TOKEN_TTL:-7200}"
ACR_ACCESS_TOKEN_TTL="${ACR_ACCESS_TOKEN_TTL:-1800}"

ACR_MAX_RETRIES="${ACR_MAX_RETRIES:-5}"
ACR_PAGE_SIZE="${ACR_PAGE_SIZE:-500}"
ACR_CURL_BIN="${ACR_CURL_BIN:-curl}"
ACR_TRANSPORT_FN="${ACR_TRANSPORT_FN:-_acr_http}"

# Last response, set by acr_request.
ACR_HTTP_STATUS=""
ACR_HTTP_BODY=""
ACR_NEXT_LINK=""

# Human-readable reason for the last acr_manifest_references failure.
ACR_LAST_ERROR_DETAIL=""

# Token helpers assign to this rather than printing. Returning a token on stdout
# would force callers into $( ), and a command substitution runs in a subshell
# where every cache write is discarded - which silently turns one token exchange
# per run into one per request.
ACR_ACCESS_TOKEN=""

declare -A _ACR_ACCESS_TOKENS=()
declare -A _ACR_ACCESS_TOKEN_AT=()

_acr_now() { printf '%s' "$SECONDS"; }

# Scope actions differ by intent so a read-only run never holds a delete-capable
# token. ACR actions: pull, push, delete, metadata_read, metadata_write.
_acr_scope_for() {
  local repository="$1" intent="$2"
  case "$intent" in
    catalog) printf 'registry:catalog:*' ;;
    read)    printf 'repository:%s:metadata_read,pull' "$repository" ;;
    write)   printf 'repository:%s:metadata_read,metadata_write,delete,pull' "$repository" ;;
    *) fail "unknown token intent '$intent'" ;;
  esac
}

# Real transport. Prints the HTTP status; body and headers land in files.
_acr_http() {
  local method="$1" url="$2" token="$3" body="$4" out_body="$5" out_headers="$6"

  local args=(
    -sS -X "$method"
    -o "$out_body" -D "$out_headers" -w '%{http_code}'
    -H "Authorization: Bearer ${token}"
    -H "Accept: application/json"
    --connect-timeout 15 --max-time 120
  )
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data "$body")

  # curl prints %{http_code} even when the transfer itself failed (a reset
  # after the headers arrived, a timeout), so the exit code has to decide.
  # Appending '000' to that output instead would yield "200000", which
  # matches neither the 2xx check nor the retry list and fails the run on a
  # single network blip.
  local status
  status="$("$ACR_CURL_BIN" "${args[@]}" "$url" 2>/dev/null)" || status='000'
  printf '%s' "${status:-000}"
}

acr_init() {
  local registry_name
  registry_name="$(config_get '.registry.name')"

  local response
  response="$(az acr login --name "$registry_name" --expose-token --only-show-errors -o json 2>/dev/null)" \
    || fail "could not obtain an ACR token for '$registry_name'; check AcrPull/AcrDelete and that you are logged in"

  ACR_LOGIN_SERVER="$(jq -r '.loginServer' <<<"$response")"
  ACR_REFRESH_TOKEN="$(jq -r '.accessToken' <<<"$response")"
  ACR_REFRESH_TOKEN_AT="$(_acr_now)"

  [[ -n "$ACR_LOGIN_SERVER" && "$ACR_LOGIN_SERVER" != "null" ]] \
    || fail "ACR login returned no loginServer for '$registry_name'"

  _ACR_ACCESS_TOKENS=()
  _ACR_ACCESS_TOKEN_AT=()
  log "authenticated against ${ACR_LOGIN_SERVER}"
}

_acr_refresh_token_if_stale() {
  local age=$(( $(_acr_now) - ACR_REFRESH_TOKEN_AT ))
  ((age < ACR_REFRESH_TOKEN_TTL)) && return 0
  log "ACR refresh token is ${age}s old, renewing"
  acr_init
}

# Exchanges the refresh token for a scope-limited access token, cached per scope.
# Sets ACR_ACCESS_TOKEN; never call this through a command substitution.
_acr_ensure_access_token() {
  local scope="$1"
  _acr_refresh_token_if_stale

  local cached_at="${_ACR_ACCESS_TOKEN_AT[$scope]:-0}"
  local age=$(( $(_acr_now) - cached_at ))
  if [[ -n "${_ACR_ACCESS_TOKENS[$scope]:-}" ]] && ((age < ACR_ACCESS_TOKEN_TTL)); then
    ACR_ACCESS_TOKEN="${_ACR_ACCESS_TOKENS[$scope]}"
    return 0
  fi

  local body_file status token
  body_file="$(mktemp)"
  status="$("$ACR_CURL_BIN" -sS -o "$body_file" -w '%{http_code}' \
    -X POST "https://${ACR_LOGIN_SERVER}/oauth2/token" \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "service=${ACR_LOGIN_SERVER}" \
    --data-urlencode "scope=${scope}" \
    --data-urlencode "refresh_token=${ACR_REFRESH_TOKEN}" \
    --connect-timeout 15 --max-time 60 2>/dev/null)" || status='000'

  if [[ "$status" != "200" ]]; then
    rm -f "$body_file"
    fail "could not exchange ACR token for scope '${scope}' (HTTP ${status})"
  fi

  token="$(jq -r '.access_token' < "$body_file")"
  rm -f "$body_file"

  _ACR_ACCESS_TOKENS["$scope"]="$token"
  _ACR_ACCESS_TOKEN_AT["$scope"]="$(_acr_now)"
  ACR_ACCESS_TOKEN="$token"
}

_acr_should_retry() {
  case "$1" in
    000|408|429|500|502|503|504) return 0 ;;
    *) return 1 ;;
  esac
}

# Honour Retry-After when ACR sends it, otherwise exponential backoff with jitter.
_acr_backoff_seconds() {
  local attempt="$1" header_file="$2"
  local retry_after
  retry_after="$(grep -i '^retry-after:' "$header_file" 2>/dev/null | head -1 \
    | sed -E 's/^[Rr]etry-[Aa]fter:[[:space:]]*//; s/[[:space:]]*$//')"
  if [[ "$retry_after" =~ ^[0-9]+$ ]]; then
    printf '%s' "$retry_after"
    return 0
  fi
  printf '%s' $(( (1 << (attempt - 1)) + RANDOM % 2 ))
}

_acr_parse_next_link() {
  # Link: </acr/v1/<repo>/_tags?last=x&n=500>; rel="next"
  grep -i '^link:' "$1" 2>/dev/null | head -1 \
    | sed -E 's/^[Ll]ink:[[:space:]]*<([^>]+)>.*/\1/' \
    | tr -d '\r'
}

# acr_request <method> <path> <intent> [repository] [body]
# Sets ACR_HTTP_STATUS, ACR_HTTP_BODY, ACR_NEXT_LINK. Returns 0 on 2xx.
acr_request() {
  local method="$1" path="$2" intent="$3" repository="${4:-}" body="${5:-}"

  local scope url body_file header_file attempt status
  scope="$(_acr_scope_for "$repository" "$intent")"
  url="https://${ACR_LOGIN_SERVER}${path}"
  body_file="$(mktemp)"
  header_file="$(mktemp)"

  for ((attempt = 1; attempt <= ACR_MAX_RETRIES; attempt++)); do
    _acr_ensure_access_token "$scope"
    status="$("$ACR_TRANSPORT_FN" "$method" "$url" "$ACR_ACCESS_TOKEN" "$body" "$body_file" "$header_file")"

    # A rejected token is worth exactly one forced renewal before giving up.
    if [[ "$status" == "401" && $attempt -eq 1 ]]; then
      unset "_ACR_ACCESS_TOKENS[$scope]" "_ACR_ACCESS_TOKEN_AT[$scope]"
      continue
    fi

    if _acr_should_retry "$status" && ((attempt < ACR_MAX_RETRIES)); then
      local wait_for
      wait_for="$(_acr_backoff_seconds "$attempt" "$header_file")"
      warn "HTTP ${status} on ${method} ${path}, retry ${attempt}/${ACR_MAX_RETRIES} in ${wait_for}s"
      sleep "$wait_for"
      continue
    fi
    break
  done

  ACR_HTTP_STATUS="$status"
  ACR_HTTP_BODY="$(cat "$body_file" 2>/dev/null || true)"
  ACR_NEXT_LINK="$(_acr_parse_next_link "$header_file")"
  rm -f "$body_file" "$header_file"

  [[ "$status" =~ ^2[0-9][0-9]$ ]]
}

# Walks ACR's Link-header pagination and concatenates one JSON array field.
#
# Pages are appended to a file and combined once at the end. Accumulating in a
# shell variable would re-serialize the whole result on every page, which is
# O(n^2) and reaches tens of megabytes on a 10k-tag repository.
_acr_paged_collect() {
  local first_path="$1" intent="$2" repository="$3" json_field="$4"
  local path="$first_path" pages_file
  pages_file="$(mktemp)"

  while [[ -n "$path" ]]; do
    if ! acr_request GET "$path" "$intent" "$repository"; then
      rm -f "$pages_file"
      printf '[]'
      return 1
    fi

    if ! jq -c --arg f "$json_field" '.[$f] // []' <<<"$ACR_HTTP_BODY" >> "$pages_file" 2>/dev/null; then
      rm -f "$pages_file"
      printf '[]'
      return 1
    fi

    path="$ACR_NEXT_LINK"
  done

  jq -c -s 'add // []' "$pages_file"
  rm -f "$pages_file"
}

acr_list_repositories() {
  _acr_paged_collect "/acr/v1/_catalog?n=${ACR_PAGE_SIZE}" catalog "" "repositories"
}

# Tags with lock state and timestamps in one call, which /v2/_tags/list cannot do.
acr_list_tags() {
  local repository="$1"
  _acr_paged_collect \
    "/acr/v1/${repository}/_tags?n=${ACR_PAGE_SIZE}&orderby=timedesc" \
    read "$repository" "tags"
}

acr_list_manifests() {
  local repository="$1"
  _acr_paged_collect \
    "/acr/v1/${repository}/_manifests?n=${ACR_PAGE_SIZE}&orderby=timedesc" \
    read "$repository" "manifests"
}

# Child digests referenced by a manifest: attestations, signatures, referrers and
# manifest-list members.
#
# Returns 0 with a JSON array, 2 when the manifest is already gone (404), and 1
# when the graph cannot be read. Callers MUST treat 1 as "do not delete": a
# missing reference list would otherwise look like "no children to protect".
# On a 1, ACR_LAST_ERROR_DETAIL explains why, since the caller has no other way
# to see the HTTP status or malformed body that caused it.
acr_manifest_references() {
  local repository="$1" digest="$2"

  if ! acr_request GET "/acr/v1/${repository}/_manifests/${digest}" read "$repository"; then
    [[ "$ACR_HTTP_STATUS" == "404" ]] && return 2
    ACR_LAST_ERROR_DETAIL="HTTP ${ACR_HTTP_STATUS}"
    return 1
  fi

  local references
  if ! references="$(jq -c '[.manifest.references[]?.digest] // []' <<<"$ACR_HTTP_BODY" 2>/dev/null)"; then
    ACR_LAST_ERROR_DETAIL="HTTP 200 but the response body was not valid JSON"
    return 1
  fi
  if [[ -z "$references" ]]; then
    ACR_LAST_ERROR_DETAIL="HTTP 200 but .manifest.references could not be read from the body"
    return 1
  fi

  printf '%s' "$references"
}

# ACR's bulk `_manifests` list (acr_list_manifests, above) never populates
# `references` for an OCI index or a Docker manifest list - confirmed against
# the live API on 2026-09-06, after it silently let the sweep delete the
# platform manifest and attestation manifest of two still-deployed, still-
# tagged keycloak images, because their listed `references` came back `[]`
# even though the index genuinely has two children. Real references are only
# ever returned by the per-digest GET (acr_manifest_references, above).
#
# This backfills the bulk listing in place: for every index/manifest-list
# entry, replaces its (always-empty) `references` with the real one, in the
# same `[{digest: ...}, ...]` shape the bulk API itself uses, so nothing
# downstream needs to know the data came from two different calls. A manifest
# that has disappeared between the list and this call (404) contributes no
# children, which is correct - there is nothing left to protect. Any other
# failure - and acr_manifest_references already retries transient ones via
# acr_request - aborts the whole inventory rather than silently recording an
# empty list, which is the exact silent failure this exists to close.
_ACR_INDEX_MEDIA_TYPES='application/vnd.oci.image.index.v1+json application/vnd.docker.distribution.manifest.list.v2+json'

#
# One per-digest GET per index, run run_settings.parallel_reference_lookups at
# a time in forked subshells: a registry that publishes every build as an OCI
# index (buildx with the docker-container driver does) has thousands of these
# per repository, and one round trip at a time took 20+ minutes per repository.
# Each fork writes <n>.json on success or <n>.err on failure, and the patch is
# assembled once at the end - not rewritten on every iteration, which was O(n^2).
_acr_backfill_index_references() {
  local repository="$1" manifests_file="$2"
  local digests
  digests="$(jq -r --arg t1 "${_ACR_INDEX_MEDIA_TYPES%% *}" --arg t2 "${_ACR_INDEX_MEDIA_TYPES#* }"     '.[] | select(.mediaType == $t1 or .mediaType == $t2) | .digest' "$manifests_file")"
  [[ -n "$digests" ]] || return 0

  local count parallel
  count="$(wc -l <<<"$digests" | tr -d ' ')"
  parallel="$(config_get '.run_settings.parallel_reference_lookups')"
  log "${repository}: resolving real references for ${count} index/manifest-list entr$([[ "$count" == "1" ]] && printf 'y' || printf 'ies'), ${parallel} at a time (bulk listing never carries them)"

  # Fetch the read token here so every fork inherits it rather than each one
  # exchanging its own.
  _acr_ensure_access_token "$(_acr_scope_for "$repository" read)"

  local results_dir digest index=0 running=0 failed=false
  results_dir="$(mktemp -d)"

  while IFS= read -r digest; do
    [[ -n "$digest" ]] || continue
    index=$((index + 1))
    ( _acr_resolve_index_references "$repository" "$digest" "${results_dir}/${index}" ) &
    running=$((running + 1))
    if ((running >= parallel)); then
      wait -n || failed=true
      running=$((running - 1))
    fi
    [[ "$failed" == false ]] || break
    if ((index % 500 == 0)); then
      log "${repository}: ${index}/${count} index references requested"
    fi
  done <<< "$digests"
  while ((running > 0)); do
    wait -n || failed=true
    running=$((running - 1))
  done

  if [[ "$failed" == true ]] || compgen -G "${results_dir}/*.err" >/dev/null; then
    local first_err resolved
    first_err="$(cat "$(ls "${results_dir}"/*.err 2>/dev/null | head -1)" 2>/dev/null || printf 'a worker exited without writing a result')"
    resolved="$(find "$results_dir" -name '*.json' | wc -l | tr -d ' ')"
    rm -rf "$results_dir"
    fail "could not read the reference graph for ${first_err} (an OCI index / manifest list) after resolving ${resolved}/${count}; refusing to inventory it blind, since that graph is what stops the sweep deleting a live image's platform manifests"
  fi

  local patch_file tmp
  patch_file="$(mktemp)"
  # find | cat, not a glob: thousands of result files would exceed ARG_MAX.
  find "$results_dir" -name '*.json' -exec cat {} + \
    | jq -s 'map({ (.digest): (.references | map({digest: .})) }) | add // {}' > "$patch_file"
  rm -rf "$results_dir"

  tmp="${manifests_file}.tmp"
  jq --arg t1 "${_ACR_INDEX_MEDIA_TYPES%% *}" --arg t2 "${_ACR_INDEX_MEDIA_TYPES#* }"     --slurpfile patch "$patch_file"     'map(if (.mediaType == $t1 or .mediaType == $t2)
         then . + { references: ($patch[0][.digest] // []) }
         else . end)'     "$manifests_file" > "$tmp" && mv "$tmp" "$manifests_file"
  rm -f "$patch_file"
  log "${repository}: resolved ${count}/${count} index references"
}

# Worker for the loop above. Writes <out_base>.json with the children, or
# <out_base>.err with a human-readable reason and returns 1.
_acr_resolve_index_references() {
  local repository="$1" digest="$2" out_base="$3"
  local refs_file="${out_base}.refs" rc=0
  # Not a command substitution: ACR_LAST_ERROR_DETAIL has to survive the call.
  acr_manifest_references "$repository" "$digest" > "$refs_file" || rc=$?
  case "$rc" in
    0) ;;
    2) printf '[]' > "$refs_file" ;;  # already gone; nothing left to protect
    *) rm -f "$refs_file"
       printf '%s@%s: %s' "$repository" "$digest" "${ACR_LAST_ERROR_DETAIL:-unknown error}" > "${out_base}.err"
       return 1 ;;
  esac
  jq -c --arg d "$digest" '{digest: $d, references: .}' "$refs_file" > "${out_base}.json"
  rm -f "$refs_file"
}

acr_untag() {
  local repository="$1" tag="$2"
  acr_request DELETE "/acr/v1/${repository}/_tags/${tag}" write "$repository" && return 0
  # Already untagged is the desired end state, not a failure.
  [[ "$ACR_HTTP_STATUS" == "404" ]]
}

acr_delete_manifest() {
  local repository="$1" digest="$2"
  acr_request DELETE "/v2/${repository}/manifests/${digest}" write "$repository" && return 0
  [[ "$ACR_HTTP_STATUS" == "404" ]]
}

acr_set_tag_attributes() {
  local repository="$1" tag="$2" write_enabled="$3" delete_enabled="$4"
  local body
  body="$(jq -nc --argjson w "$write_enabled" --argjson d "$delete_enabled" \
    '{writeEnabled: $w, deleteEnabled: $d}')"
  acr_request PATCH "/acr/v1/${repository}/_tags/${tag}" write "$repository" "$body"
}

acr_set_manifest_attributes() {
  local repository="$1" digest="$2" write_enabled="$3" delete_enabled="$4"
  local body
  body="$(jq -nc --argjson w "$write_enabled" --argjson d "$delete_enabled" \
    '{writeEnabled: $w, deleteEnabled: $d}')"
  acr_request PATCH "/acr/v1/${repository}/_manifests/${digest}" write "$repository" "$body"
}

# Registry-wide storage, for the before/after numbers in the report. This is the
# one ARM call in the module; there is no data-plane equivalent.
acr_usage_bytes() {
  # --subscription: the CLI's default subscription is often not the registry's.
  az acr show-usage \
    --name "$(config_get '.registry.name')" \
    --resource-group "$(config_get '.registry.resource_group')" \
    --subscription "$(config_get '.registry.subscription_id')" \
    --query "value[?name=='Size'].currentValue | [0]" -o tsv --only-show-errors 2>/dev/null \
    || printf ''
}

# Builds <work-dir>/inventory.json for one repository. Sharding across repositories
# happens in the pipeline, so this stays single-purpose.
acr_inventory_repository() {
  local repository="$1" out_file="$2"
  local tags_file manifests_file
  tags_file="$(mktemp)"
  manifests_file="$(mktemp)"

  acr_list_tags "$repository" > "$tags_file" \
    || { rm -f "$tags_file" "$manifests_file"; fail "could not list tags for ${repository} (HTTP ${ACR_HTTP_STATUS})"; }
  acr_list_manifests "$repository" > "$manifests_file" \
    || { rm -f "$tags_file" "$manifests_file"; fail "could not list manifests for ${repository} (HTTP ${ACR_HTTP_STATUS})"; }
  _acr_backfill_index_references "$repository" "$manifests_file" \
    || { rm -f "$tags_file" "$manifests_file"; fail "could not resolve index references for ${repository}"; }

  # --slurpfile, not --argjson: a 10k-tag repository exceeds ARG_MAX and jq dies
  # with "Argument list too long".
  jq -n \
    --arg repository "$repository" \
    --slurpfile tags "$tags_file" \
    --slurpfile manifests "$manifests_file" \
    '
      # NOT `// true`: jq treats false as empty, so `false // true` is true and
      # every locked item would be recorded as unlocked.
      def flag_or_true: if . == null then true else . end;

      {
        repository: $repository,
        tags: [ $tags[0][] | {
          name,
          digest,
          created: .createdTime,
          modified: .lastUpdateTime,
          write_enabled: (.changeableAttributes.writeEnabled | flag_or_true),
          delete_enabled: (.changeableAttributes.deleteEnabled | flag_or_true)
        } ],
        manifests: [ $manifests[0][] | {
          digest,
          tags: (.tags // []),
          created: .createdTime,
          modified: .lastUpdateTime,
          size: (.imageSize // 0),
          media_type: .mediaType,
          # Children of a manifest list / OCI index. They are listed as untagged
          # manifests in their own right, so the sweep must know their parent.
          references: [ .references[]?.digest ],
          write_enabled: (.changeableAttributes.writeEnabled | flag_or_true),
          delete_enabled: (.changeableAttributes.deleteEnabled | flag_or_true)
        } ]
      }' > "$out_file"

  rm -f "$tags_file" "$manifests_file"
  log "$repository: $(jq '.tags | length' "$out_file") tag(s), $(jq '.manifests | length' "$out_file") manifest(s)"
}

# Walks repositories in this process, then merges. The pipeline shards this across
# run_settings.parallel_repo_jobs jobs and calls --merge at the end instead.
# acr_inventory_all <work-dir> [repositories_csv] [skip_merge]
# With a repository list only those repositories are read (a targeted cleanup);
# the list is checked against the catalog so a typo fails instead of silently
# inventorying nothing.
acr_inventory_all() {
  local work_dir="$1" only_repositories="${2:-}" skip_merge="${3:-false}"
  local out_dir="${work_dir}/inventory"
  mkdir -p "$out_dir"

  local repositories catalog
  catalog="$(acr_list_repositories)" \
    || fail "could not list repositories (HTTP ${ACR_HTTP_STATUS})"

  if [[ -n "$only_repositories" ]]; then
    repositories="$(jq -nc --arg r "$only_repositories" '$r | split(",") | map(select(. != "")) | unique')"
    local unknown
    unknown="$(jq -rn --argjson want "$repositories" --argjson have "$catalog" \
      '[ $want[] | . as $w | select(($have | index($w)) == null) ] | join(", ")')"
    [[ -z "$unknown" ]] || fail "repositories not found in the registry: ${unknown}"
    # A targeted run must not pick up stale files from an earlier full inventory.
    rm -f "${out_dir}"/*.json
  else
    repositories="$catalog"
  fi

  local count index repository safe_name parallel
  local -a pids=()
  count="$(jq 'length' <<<"$repositories")"
  parallel="$(config_get '.run_settings.parallel_repo_jobs')"
  log "inventorying ${count} repositor$([[ "$count" == "1" ]] && printf 'y' || printf 'ies'), ${parallel} at a time"

  # Repositories are read in forked subshells, parallel_repo_jobs at a time.
  # A fork inherits the token cache, and each repository owns its output file,
  # so only the log order changes. The pipeline shards the same way across jobs.
  #
  # Each fork's PID is tracked explicitly and waited on by that exact PID, never
  # by an untargeted `wait -n` plus a counter. `wait -n` reaps whichever
  # background job finishes next without confirming which one - if that
  # bookkeeping ever drifts from reality the merge below can run while the
  # slowest (usually largest) repository is still being written, and that
  # repository silently drops out of the inventory with no error. Waiting on
  # specific PIDs cannot drift: every PID appended here is waited on by name
  # before the merge runs, so the merge cannot start until they all actually
  # have.
  for ((index = 0; index < count; index++)); do
    repository="$(jq -r ".[$index]" <<<"$repositories")"
    # Repository names contain slashes; flatten them for the filename.
    safe_name="${repository//\//__}"
    ( acr_inventory_repository "$repository" "${out_dir}/${safe_name}.json" ) &
    pids+=("$!")
    if ((${#pids[@]} >= parallel)); then
      wait "${pids[0]}" || fail "inventory: a repository could not be read; see the log above"
      pids=("${pids[@]:1}")
    fi
  done
  for ((index = 0; index < ${#pids[@]}; index++)); do
    wait "${pids[$index]}" || fail "inventory: a repository could not be read; see the log above"
  done

  [[ "$skip_merge" == "true" ]] && return 0
  acr_inventory_merge "$work_dir" "$repositories"
}
# Inventories every n-th repository, for the pipeline's parallel inventory jobs:
# job i of n takes repositories whose catalog index % n == i - 1. Each job then
# publishes its per-repository files and a single --merge combines them.
acr_inventory_shard() {
  local work_dir="$1" shard_index="$2" shard_count="$3"
  local out_dir="${work_dir}/inventory"
  mkdir -p "$out_dir"

  local repositories
  repositories="$(acr_list_repositories)" \
    || fail "could not list repositories (HTTP ${ACR_HTTP_STATUS})"

  local count index repository safe_name taken=0
  count="$(jq 'length' <<<"$repositories")"
  for ((index = 0; index < count; index++)); do
    (( index % shard_count == shard_index - 1 )) || continue
    repository="$(jq -r ".[$index]" <<<"$repositories")"
    safe_name="${repository//\//__}"
    acr_inventory_repository "$repository" "${out_dir}/${safe_name}.json"
    taken=$((taken + 1))
  done
  log "shard ${shard_index}/${shard_count}: ${taken} of ${count} repositories inventoried"
}

# acr_inventory_merge <work-dir> [expected_repositories_json]
# expected_repositories_json, when given, is the JSON array of repository names
# this run intended to inventory (acr_inventory_all's own $repositories, full
# catalog or a targeted subset). The merge then fails closed instead of
# silently publishing a partial inventory.json if any of them is absent from
# what actually got merged - the one case this cannot distinguish from "really
# is missing" is a repository job that failed open (wrote nothing, no error),
# which the caller's own per-PID `wait` already turns into a hard failure
# before this function is ever reached, so that case does not reach here.
acr_inventory_merge() {
  local work_dir="$1" expected_repositories="${2:-}"
  local in_dir="${work_dir}/inventory"
  local out_file="${work_dir}/inventory.json"

  compgen -G "${in_dir}/*.json" >/dev/null \
    || fail "no per-repository inventory found in ${in_dir}"

  jq -s \
    --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg registry "$(config_get '.registry.name')" \
    '{
       generated_at: $generated_at,
       registry: $registry,
       repositories: .,
       totals: {
         repositories: length,
         tags: ([ .[].tags[] ] | length),
         manifests: ([ .[].manifests[] ] | length),
         locked_tags: ([ .[].tags[] | select(.delete_enabled == false or .write_enabled == false) ] | length)
       }
     }' "${in_dir}"/*.json > "$out_file"

  if [[ -n "$expected_repositories" ]]; then
    local have missing
    have="$(jq -c '[ .repositories[].repository ]' "$out_file")"
    missing="$(jq -rn --argjson want "$expected_repositories" --argjson have "$have" \
      '[ $want[] | . as $w | select(($have | index($w)) == null) ] | join(", ")')"
    [[ -z "$missing" ]] \
      || fail "inventory: merge is missing repositories that should have been inventoried: ${missing} - a repository job had likely not finished writing its file when the merge ran"
  fi

  log "inventory: $(jq -r '.totals | "\(.repositories) repo(s), \(.tags) tag(s), \(.manifests) manifest(s), \(.locked_tags) locked tag(s)"' "$out_file")"
}
