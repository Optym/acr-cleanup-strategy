#!/usr/bin/env bash
#
# Stage 4 - reconcile image locks against the protection set.
#
#   reads   <work-dir>/plan.json (.locks), config image_lock.unlock_when_unused,
#           <previous-dir>/lock-ledger.json from the last run (optional)
#   writes  <work-dir>/lock-result.json, <work-dir>/lock-ledger.json,
#           <work-dir>/unlock-events.jsonl (one line per unlock attempt, in the
#           order it happened - the terminal log has the same information but
#           is not grep|jq-able and is lost once the pipeline's console output
#           rotates out)
#   mutates lock state only: PATCH writeEnabled/deleteEnabled to true
#
# This is the ONLY writer of lock state in the weekly run. Locks are added at
# deploy time by deploy/lock-deployed-images.sh; this stage only ever removes
# them, and only when all of these hold:
#
#   - the item is locked and NOT in the protection set (no running pod, no
#     workload template, no retained Helm revision, in any cluster) - an
#     orphan, in this module's vocabulary
#   - it is not covered by never_unlock (or never_delete)
#   - AND EITHER:
#       - it is already old enough that the normal age/count rules would delete
#         it on their own (plan.json's would_delete / would_sweep, computed by
#         classify.sh ignoring both protection and the lock) - unlocked
#         immediately, no waiting. Most locked orphans reach this within a few
#         weeks of going idle, because deploy-time locks are applied to already
#         real, in-service builds, not to fresh-off-the-press ones
#       - or it is younger than that, but has been continuously unprotected for
#         at least wait_days_before_unlocking, measured from the first run that
#         saw it unprotected. That first-seen time is the ledger, carried from
#         run to run (the orchestrator copies it into --previous-dir at the end
#         of every run; the pipeline additionally republishes it as an
#         artifact). Without the ledger every freshly-orphaned-but-still-young
#         image looks newly orphaned on every run and never crosses the wait
#
# execute.sh (stage 5) reads plan.json, which was classified BEFORE this stage
# ran, so a tag unlocked here is still "locked" there and is skipped. That is
# the two-run gap: every unlock appears in a report before deletion is possible.

# shellcheck shell=bash

# lock_reconcile_run <work-dir> [previous-dir]
lock_reconcile_run() {
  local work_dir="$1" previous_dir="${2:-${1}/previous}"
  local plan_file="${work_dir}/plan.json"
  local ledger_in="${previous_dir}/lock-ledger.json"
  local ledger_out="${work_dir}/lock-ledger.json"
  local out_file="${work_dir}/lock-result.json"

  [[ -f "$plan_file" ]] || fail "lock-reconcile: ${plan_file} not found; classify first"

  local enabled dry_run wait_days now
  enabled="$(config_get '.image_lock.unlock_when_unused.enabled')"
  dry_run="$(config_get '.run_settings.dry_run')"
  wait_days="$(config_get '.image_lock.unlock_when_unused.wait_days_before_unlocking')"
  now="$(date -u +%s)"

  local ledger='{"entries":[]}'
  if [[ -f "$ledger_in" ]]; then
    ledger="$(jq -c '{ entries: (.entries // []) }' "$ledger_in" 2>/dev/null)" \
      || { warn "lock-reconcile: previous ledger is unreadable, starting a new one"; ledger='{"entries":[]}'; }
    log "lock-reconcile: previous ledger has $(jq '.entries | length' <<<"$ledger") entr$([[ "$(jq '.entries | length' <<<"$ledger")" == "1" ]] && printf 'y' || printf 'ies')"
  else
    log "lock-reconcile: no previous ledger at ${ledger_in}; every orphan lock starts its wait now"
  fi

  # Decide per locked item. The decision list drives both the API calls and
  # the report, and the surviving wait entries become the next ledger.
  # The ledger can hold tens of thousands of entries; pass it as a file.
  local decisions_file ledger_file
  decisions_file="$(mktemp)"
  ledger_file="$(mktemp)"
  printf '%s' "$ledger" > "$ledger_file"
  jq -c \
    --argjson now "$now" \
    --argjson wait_days "$wait_days" \
    --argjson enabled "$enabled" \
    --slurpfile ledger_in "$ledger_file" \
    '
      ($ledger_in[0]) as $ledger
      | ($ledger.entries
       | map({ key: (.kind + "\t" + .repository + "\t" + .ref), value: .first_unprotected_at })
       | from_entries) as $seen

      | [ (.locks.tags[]      | . + { kind: "tag",      ref: .tag,      stale: .would_delete }),
          (.locks.manifests[] | . + { kind: "manifest", ref: .digest, stale: .would_sweep }) ]
      | map(
          . as $item
          | ($item.kind + "\t" + $item.repository + "\t" + $item.ref) as $key
          | ($seen[$key] // $now) as $first
          | ((($now - $first) / 86400) | floor) as $days_unprotected
          | {
              kind: $item.kind,
              repository: $item.repository,
              ref: $item.ref,
              tag: ($item.tag // null),
              digest: ($item.digest // null),
              age_days: $item.age_days,
              protection: $item.protection,
              stale: $item.stale,
              first_unprotected_at: $first,
              days_unprotected: $days_unprotected,
              status: (
                if $item.protected then "held"
                elif $item.never_unlock then "pinned"
                elif ($enabled | not) then "orphan"
                elif $item.stale then "unlock"
                elif $days_unprotected >= $wait_days then "unlock"
                else "waiting"
                end
              ),
              # Why it unlocked, for the report: an already-stale orphan needs no
              # wait at all; a young one earns it by outlasting the wait window.
              unlock_basis: (
                if $item.protected or $item.never_unlock or ($enabled | not) then null
                elif $item.stale then "already_past_retention"
                elif $days_unprotected >= $wait_days then "wait_elapsed"
                else null
                end
              )
            }
        )
    ' "$plan_file" > "$decisions_file"

  local total
  total="$(jq 'length' "$decisions_file")"
  log "lock-reconcile: ${total} locked item(s): $(jq -r 'group_by(.status) | map("\(.[0].status)=\(length)") | join(" ")' "$decisions_file")"

  # Apply the unlocks.
  local results_file errors_file events_file
  results_file="$(mktemp)"
  errors_file="$(mktemp)"
  events_file="${work_dir}/unlock-events.jsonl"
  : > "$results_file"
  : > "$errors_file"
  : > "$events_file"

  local item kind repository ref
  while IFS= read -r item; do
    kind="$(jq -r '.kind' <<<"$item")"
    repository="$(jq -r '.repository' <<<"$item")"
    ref="$(jq -r '.ref' <<<"$item")"

    if [[ "$dry_run" == "true" ]]; then
      jq -c '. + { status: "unlock-dry-run" }' <<<"$item" >> "$results_file"
      jq -nc --arg t "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --argjson item "$item" \
        '{ timestamp: $t, status: "unlock-dry-run" } + ($item | { kind, repository, ref, unlock_basis })' >> "$events_file"
      continue
    fi

    local ok=true
    if [[ "$kind" == "tag" ]]; then
      acr_set_tag_attributes "$repository" "$ref" true true || ok=false
    else
      acr_set_manifest_attributes "$repository" "$ref" true true || ok=false
    fi

    if [[ "$ok" == true ]]; then
      log "unlocked ${kind} ${repository}:${ref}"
      jq -c '. + { status: "unlocked" }' <<<"$item" >> "$results_file"
      jq -nc --arg t "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --argjson item "$item" \
        '{ timestamp: $t, status: "unlocked" } + ($item | { kind, repository, ref, unlock_basis })' >> "$events_file"
    else
      warn "could not unlock ${kind} ${repository}:${ref} (HTTP ${ACR_HTTP_STATUS})"
      jq -c --arg s "$ACR_HTTP_STATUS" '. + { status: "unlock-failed", http_status: $s }' <<<"$item" >> "$results_file"
      printf 'unlock %s %s:%s failed with HTTP %s\n' "$kind" "$repository" "$ref" "$ACR_HTTP_STATUS" >> "$errors_file"
      jq -nc --arg t "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg s "$ACR_HTTP_STATUS" --argjson item "$item" \
        '{ timestamp: $t, status: "unlock-failed", http_status: $s } + ($item | { kind, repository, ref, unlock_basis })' >> "$events_file"
    fi
  done < <(jq -c '.[] | select(.status == "unlock")' "$decisions_file")

  jq -s \
    --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson now "$now" \
    --argjson enabled "$enabled" \
    --argjson dry_run "$dry_run" \
    --argjson wait_days "$wait_days" \
    --rawfile errors "$errors_file" \
    --slurpfile decisions "$decisions_file" \
    '
      . as $applied
      | ($applied | map({ key: (.kind + "\t" + .repository + "\t" + .ref), value: . }) | from_entries) as $by_key
      | ($decisions[0]
         | map(($by_key[.kind + "\t" + .repository + "\t" + .ref] // .))) as $final
      | {
          generated_at: $generated_at,
          enabled: $enabled,
          dry_run: $dry_run,
          wait_days_before_unlocking: $wait_days,
          totals: (
            ($final | group_by(.status) | map({ key: .[0].status, value: length }) | from_entries)
            + { locked: ($final | length),
                # Locked, but running nowhere and not a retained Helm revision -
                # the broad backlog, whatever its resolution this run. Distinct
                # from the "orphan" status above, which only ever fires when
                # unlock_when_unused.enabled is false.
                not_protected: ([ $final[] | select(.status != "held" and .status != "pinned") ] | length),
                unlocked_immediately: ([ $final[] | select(.unlock_basis == "already_past_retention") ] | length),
                unlocked_after_wait: ([ $final[] | select(.unlock_basis == "wait_elapsed") ] | length) }
          ),
          held:     [ $final[] | select(.status == "held") ],
          pinned:   [ $final[] | select(.status == "pinned") ],
          waiting:  [ $final[] | select(.status == "waiting") ],
          orphan:   [ $final[] | select(.status == "orphan") ],
          unlocked: [ $final[] | select(.status == "unlocked" or .status == "unlock-dry-run") ],
          failed:   [ $final[] | select(.status == "unlock-failed") ],
          errors:   ($errors | split("\n") | map(select(. != "")))
        }
    ' "$results_file" > "$out_file"

  # Next ledger: everything still locked and unprotected keeps its first-seen
  # time. Held and pinned items drop out so a re-deployed image restarts its
  # wait from zero the next time it is undeployed. Dry-run unlocks stay in the
  # ledger, otherwise a dry run would reset the clock on what it did not do.
  jq -c \
    --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{
       generated_at: $generated_at,
       entries: [
         (.waiting[], .orphan[], .failed[], (.unlocked[] | select(.status == "unlock-dry-run")))
         | { kind, repository, ref, first_unprotected_at }
       ]
     }' "$out_file" > "$ledger_out"

  rm -f "$decisions_file" "$results_file" "$errors_file" "$ledger_file"

  log "lock-reconcile: $(jq -r '.totals | "held=\(.held // 0) pinned=\(.pinned // 0) waiting=\(.waiting // 0) orphan=\(.orphan // 0) unlocked=\((.unlocked // 0) + (."unlock-dry-run" // 0)) (\(.unlocked_immediately // 0) already past retention, \(.unlocked_after_wait // 0) after the wait) failed=\(."unlock-failed" // 0)"' "$out_file") -> ${out_file}"

  [[ "$(jq '.errors | length' "$out_file")" == "0" ]]
}
