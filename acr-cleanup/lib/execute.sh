#!/usr/bin/env bash
#
# Stage 5 - execute the plan: untag stale tags, or sweep untagged manifests.
#
#   reads   <work-dir>/plan.json
#   writes  <work-dir>/delete-result.json
#   mutates untag: DELETE /acr/v1/<repo>/_tags/<tag>        (reversible)
#           manifests: DELETE /v2/<repo>/manifests/<digest>  (irreversible)
#
# Never touches lock state. A locked tag is already "locked" in the plan and is
# skipped; lock-reconcile.sh is the only writer of locks.
#
# The two modes are deliberately separate runs. Untagging keeps the manifest
# and its layers, so a mistake can be undone from the digest in the report;
# the manifest sweep is the point of no return and only touches manifests that
# have been untagged for min_untagged_manifest_age_days.
#
# Parallelism: candidates are split into run_settings.parallel_delete_workers
# chunks and each chunk is processed by a forked subshell. A fork inherits the
# refresh token and the per-scope access-token cache, so each worker performs
# at most one token exchange per repository instead of one per item.

# shellcheck shell=bash

# Re-read a manifest right before the irreversible delete: the inventory may be
# an hour old and a tag could have been pushed onto it since, or a lock added.
# Returns 0 when it is still untagged and unlocked, 2 when already gone.
_execute_manifest_still_deletable() {
  local repository="$1" digest="$2"
  if ! acr_request GET "/acr/v1/${repository}/_manifests/${digest}" read "$repository"; then
    [[ "$ACR_HTTP_STATUS" == "404" ]] && return 2
    return 1
  fi
  jq -e '
    ((.manifest.tags // []) | length) == 0
    and (.manifest.changeableAttributes.deleteEnabled != false)
    and (.manifest.changeableAttributes.writeEnabled != false)
  ' <<<"$ACR_HTTP_BODY" >/dev/null 2>&1
}

# _execute_worker <mode> <chunk-file> <out-file>
# Runs in a forked subshell; writes one JSON line per item and always exits 0.
_execute_worker() {
  local mode="$1" chunk_file="$2" out_file="$3"
  local item repository tag digest status http

  : > "$out_file"
  while IFS= read -r item; do
    repository="$(jq -r '.repository' <<<"$item")"
    tag="$(jq -r '.tag // ""' <<<"$item")"
    digest="$(jq -r '.digest // ""' <<<"$item")"

    if [[ "$mode" == "untag" ]]; then
      if acr_untag "$repository" "$tag"; then
        status="untagged"
      else
        status="failed"
      fi
    else
      _execute_manifest_still_deletable "$repository" "$digest"
      case $? in
        0)
          if acr_delete_manifest "$repository" "$digest"; then
            status="deleted"
          else
            status="failed"
          fi
          ;;
        2) status="already-gone" ;;
        *) status="skipped:changed-since-plan" ;;
      esac
    fi

    http="${ACR_HTTP_STATUS:-}"
    jq -c --arg s "$status" --arg h "$http" '. + { status: $s, http_status: $h }' <<<"$item" >> "$out_file"
  done < "$chunk_file"
  return 0
}

# execute_run <work-dir> <untag|manifests>
execute_run() {
  local work_dir="$1" mode="$2"
  local plan_file="${work_dir}/plan.json"
  local out_file="${work_dir}/delete-result.json"
  local run_dir="${work_dir}/execute"

  [[ "$mode" == "untag" || "$mode" == "manifests" ]] || fail "execute: mode must be untag or manifests, got '$mode'"
  [[ -f "$plan_file" ]] || fail "execute: ${plan_file} not found; classify first"

  local dry_run cap workers started
  dry_run="$(config_get '.run_settings.dry_run')"
  cap="$(config_get '.run_settings.max_deletions_per_run')"
  workers="$(config_get '.run_settings.parallel_delete_workers')"
  started="$(date -u +%s)"

  # The plan is refused, not trimmed, if its protection set is missing: that
  # would only happen if somebody edited plan.json by hand.
  (($(jq '.protection.tags + .protection.digests' "$plan_file") > 0)) \
    || fail "execute: plan has an empty protection set, refusing to run"

  rm -rf "$run_dir"
  mkdir -p "$run_dir"

  local list_key
  [[ "$mode" == "untag" ]] && list_key="untag" || list_key="manifests"

  local planned
  planned="$(jq --arg k "$list_key" '.[$k] | length' "$plan_file")"

  # Circuit breaker: the plan is oldest-first, so the cap drains the backlog
  # from the far end and the newest candidates wait for a later run.
  jq -c --arg k "$list_key" --argjson cap "$cap" '.[$k][0:$cap][]' "$plan_file" > "${run_dir}/selected.jsonl"
  jq -c --arg k "$list_key" --argjson cap "$cap" '.[$k][$cap:][] | . + { status: "skipped:over-cap" }' "$plan_file" > "${run_dir}/over-cap.jsonl"

  local selected over_cap
  selected="$(wc -l < "${run_dir}/selected.jsonl" | tr -d ' ')"
  over_cap="$(wc -l < "${run_dir}/over-cap.jsonl" | tr -d ' ')"

  log "execute[${mode}]: ${planned} candidate(s), ${selected} selected, ${over_cap} over the cap of ${cap}, dry_run=${dry_run}"

  if [[ "$dry_run" == "true" ]]; then
    jq -c '. + { status: "dry-run", http_status: "" }' "${run_dir}/selected.jsonl" > "${run_dir}/results.jsonl"
  elif ((selected == 0)); then
    : > "${run_dir}/results.jsonl"
  else
    ((selected < workers)) && workers="$selected"
    log "execute[${mode}]: ${workers} worker(s)"

    # Round-robin split keeps every worker busy even when candidates cluster
    # by repository at one end of the list.
    local i
    for ((i = 0; i < workers; i++)); do
      awk -v n="$workers" -v i="$i" 'NR % n == i' "${run_dir}/selected.jsonl" > "${run_dir}/chunk-${i}.jsonl"
    done

    for ((i = 0; i < workers; i++)); do
      ( ACR_CLEANUP_LOG_SCOPE="acr-cleanup/w${i}" \
          _execute_worker "$mode" "${run_dir}/chunk-${i}.jsonl" "${run_dir}/out-${i}.jsonl" ) &
    done
    wait

    cat "${run_dir}"/out-*.jsonl > "${run_dir}/results.jsonl"
  fi

  cat "${run_dir}/results.jsonl" "${run_dir}/over-cap.jsonl" > "${run_dir}/all.jsonl"

  jq -s \
    --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg mode "$mode" \
    --argjson dry_run "$dry_run" \
    --argjson cap "$cap" \
    --argjson planned "$planned" \
    --argjson duration "$(( $(date -u +%s) - started ))" \
    '
      . as $items
      | ($items | map(select(.status == "untagged" or .status == "deleted" or .status == "already-gone"))) as $done
      | {
          generated_at: $generated_at,
          operation: $mode,
          dry_run: $dry_run,
          max_deletions_per_run: $cap,
          duration_seconds: $duration,
          totals: (
            {
              planned: $planned,
              selected: ($items | map(select(.status != "skipped:over-cap")) | length),
              succeeded: ($done | length),
              failed: ($items | map(select(.status == "failed")) | length),
              dry_run: ($items | map(select(.status == "dry-run")) | length),
              over_cap: ($items | map(select(.status == "skipped:over-cap")) | length),
              bytes: ($done | map(.size // 0) | add // 0)
            }
            + ($items | group_by(.status) | map({ key: .[0].status, value: length }) | from_entries)
          ),
          # The recovery catalogue: every mutated item with its digest.
          items: $items,
          failed: ($items | map(select(.status == "failed")))
        }
    ' "${run_dir}/all.jsonl" > "$out_file"

  log "execute[${mode}]: $(jq -r '.totals | "succeeded=\(.succeeded) failed=\(.failed) dry_run=\(.dry_run) over_cap=\(.over_cap)"' "$out_file") in $(jq '.duration_seconds' "$out_file")s -> ${out_file}"

  [[ "$(jq '.totals.failed' "$out_file")" == "0" ]]
}
