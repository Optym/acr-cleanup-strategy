#!/usr/bin/env bash
#
# Post-cleanup integrity check: is every image that is ACTUALLY RUNNING (or one
# rollback away, via Helm history) still fully pullable in the registry?
#
# This is narrower and cheaper than tools/audit-multiarch-references.sh, which
# checks every currently-tagged multi-arch image registry-wide. This tool only
# checks what discovery (stage 1, lib/discover-k8s.sh) actually found in use -
# exactly the set a cleanup run promises never to break - so it is the right
# thing to run right after a real untag-stale-tags / sweep-untagged-manifests /
# untag-and-sweep run, on the whole registry or on the repositories you just
# touched.
#
# For each protected tag or digest:
#   1. If it is a tag, confirm the tag itself still resolves (GET _tags/<tag>).
#   2. Resolve its manifest's real reference graph with a per-digest GET
#      (lib/acr-api.sh's acr_manifest_references - the same call the inventory
#      fix uses, and the one the bulk _manifests listing cannot substitute
#      for: see RUNBOOK.md section 6).
#   3. If it is a multi-arch index / manifest list, confirm every child in
#      that graph still resolves too.
#
# A tag gone, or a manifest gone, or an index child gone, is exactly the
# failure mode that put myproduct/keycloak into ImagePullBackOff: the pod is
# running an image that would no longer pull fresh. Anything reported BROKEN
# here needs the same response as that incident - the image cannot be trusted
# to survive a node replacement or a pod reschedule, whether or not the pod
# happens to be running fine right now.
#
# Read-only: GET requests only, never mutates anything.
#
# Usage:
#   tools/audit-running-images.sh --config <file> [options]
#
# Options:
#   --config <file>        Config YAML. Required.
#   --work-dir <dir>       Where discover_all writes/reads protection-set.json.
#                          Default: a fresh temp directory each run.
#   --skip-discover        Reuse <work-dir>/protection-set.json instead of
#                          discovering live. Faster, but only as current as
#                          that file - see the note below.
#   --repository <repo>    Check only this repository.
#   --repositories <a,b>   Check only these repositories, comma separated.
#   --cluster <name>       Discover (or check sources from) only this cluster.
#   --parallel <n>         Repositories checked concurrently. Default 8.
#   --out-json <file>      Also write a structured summary (totals + the
#                          non-ok items) to this file. Used by
#                          acr-cleanup.sh --validate-after so lib/report.sh
#                          can fold this check into the Protected report.
#
# Discovery reflects the moment it ran, not the moment you run this tool. By
# default this tool discovers fresh, because "is what is running RIGHT NOW
# still intact" is the actual question after a cleanup run - a pod that
# started after an old discovery snapshot was taken would otherwise not be
# checked at all. Pass --skip-discover only when you deliberately want to
# reuse an existing snapshot (for example, the one a just-finished
# acr-cleanup.sh run already left in the same --work-dir) or when the
# clusters are temporarily unreachable and a slightly stale check is better
# than none.
#
# Examples:
#   # whole fleet, fresh discovery
#   tools/audit-running-images.sh --config config/myproduct.yaml
#
#   # just the repositories affected by the last incident
#   tools/audit-running-images.sh --config config/myproduct.yaml \
#     --repositories myproduct/keycloak,myproduct/api,myproduct/calculate-pse
#
#   # reuse the discovery a cleanup run just did, same work-dir
#   tools/audit-running-images.sh --config config/myproduct.yaml \
#     --work-dir .acr-cleanup-work --skip-discover

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname -- "$SCRIPT_DIR")"

# shellcheck source=../lib/common.sh
source "${MODULE_DIR}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${MODULE_DIR}/lib/config.sh"
# shellcheck source=../lib/discover-k8s.sh
source "${MODULE_DIR}/lib/discover-k8s.sh"
# shellcheck source=../lib/acr-api.sh
source "${MODULE_DIR}/lib/acr-api.sh"

usage() {
  cat <<'USAGE'
Usage: audit-running-images.sh --config <file> [options]

  --config <file>        Config YAML. Required.
  --work-dir <dir>       Where protection-set.json is read from / written to.
                         Default: a fresh temp directory.
  --skip-discover        Reuse <work-dir>/protection-set.json instead of
                         discovering the clusters live (faster, may be stale).
  --repository <repo>    Check only this repository.
  --repositories <a,b>   Check only these repositories, comma separated.
  --cluster <name>       Limit discovery (and so the check) to one cluster.
  --parallel <n>         Repositories checked concurrently. Default 8.
  --out-json <file>      Also write a structured summary (totals + the
                         non-ok items) to this file, for lib/report.sh to
                         fold into the Protected report - this is what
                         acr-cleanup.sh --validate-after uses. Plain stdout
                         lines are unaffected.
  -h, --help             This message.
USAGE
}

# Every distinct (repository, ref) this cluster fleet currently depends on,
# tag and digest protections both, tagged with which kind it is so the checker
# knows whether to look the tag up first.
_ari_wanted_items() {
  local protection_file="$1" repo_filter="$2"
  jq -c --argjson only "$repo_filter" '
    [ (.protected_tags[]    | { repository, ref: .tag,    kind: "tag" }),
      (.protected_digests[] | { repository, ref: .digest, kind: "digest" }) ]
    | map(select(. as $item | ($only | length) == 0 or (($only | index($item.repository)) != null)))
  ' "$protection_file"
}

# Which cluster(s)/source(s) an item comes from, for the report when it breaks.
_ari_sources_for() {
  local protection_file="$1" repository="$2" ref="$3" kind="$4"
  local field
  [[ "$kind" == "tag" ]] && field="tag" || field="digest"
  jq -r --arg r "$repository" --arg ref "$ref" --arg f "$field" '
    [ .sources[] | select(.repository == $r and .[$f] == $ref) | .cluster ] | unique | join(",")
  ' "$protection_file"
}

# audit_one_repository <protection-set-file> <out-file> <repository> <items-json>
_ari_audit_one_repository() {
  local protection_file="$1" out_file="$2" repository="$3" items="$4"
  local count
  count="$(jq 'length' <<<"$items")"
  ((count > 0)) || return 0
  log "${repository}: ${count} deployed image(s) to check"

  local item kind ref digest refs child broken clusters
  while IFS= read -r item; do
    kind="$(jq -r .kind <<<"$item")"
    ref="$(jq -r .ref <<<"$item")"
    clusters="$(_ari_sources_for "$protection_file" "$repository" "$ref" "$kind")"

    local tag_display="-"
    [[ "$kind" == "tag" ]] && tag_display="$ref"

    if [[ "$kind" == "tag" ]]; then
      if ! acr_request GET "/acr/v1/${repository}/_tags/${ref}" read "$repository"; then
        printf 'BROKEN\trepository=%s\ttag=%s\tclusters=%s\treason=tag-not-found\n' \
          "$repository" "$ref" "$clusters" >> "$out_file"
        continue
      fi
      digest="$(jq -r '.tag.digest' <<<"$ACR_HTTP_BODY")"
    else
      digest="$ref"
    fi

    # Capture the real exit status right away: `if ! cmd; then` makes `$?`
    # inside the block reflect the negation (always 0 there), not cmd's own
    # 1-vs-2 distinction that acr_manifest_references relies on.
    local ref_status
    refs="$(acr_manifest_references "$repository" "$digest")"
    ref_status=$?
    if ((ref_status != 0)); then
      if ((ref_status == 2)); then
        printf 'BROKEN\trepository=%s\ttag=%s\tdigest=%s\tclusters=%s\treason=manifest-not-found\n' \
          "$repository" "$tag_display" "$digest" "$clusters" >> "$out_file"
      else
        printf 'UNREADABLE\trepository=%s\ttag=%s\tdigest=%s\tclusters=%s\n' \
          "$repository" "$tag_display" "$digest" "$clusters" >> "$out_file"
      fi
      continue
    fi

    broken=""
    for child in $(jq -r '.[]' <<<"$refs"); do
      if ! acr_request GET "/acr/v1/${repository}/_manifests/${child}" read "$repository" >/dev/null 2>&1; then
        [[ "$ACR_HTTP_STATUS" == "404" ]] && broken="${broken}${child} "
      fi
    done

    if [[ -n "$broken" ]]; then
      printf 'BROKEN\trepository=%s\ttag=%s\tdigest=%s\tclusters=%s\treason=index-child-missing\tmissing_children=%s\n' \
        "$repository" "$tag_display" "$digest" "$clusters" "${broken% }" >> "$out_file"
    else
      printf 'ok\trepository=%s\ttag=%s\tdigest=%s\tclusters=%s\n' \
        "$repository" "$tag_display" "$digest" "$clusters" >> "$out_file"
    fi
  done < <(jq -c '.[]' <<<"$items")
}

main() {
  local config_file="" work_dir="" skip_discover=false out_json=""
  local only_repository="" repositories="" only_cluster="" parallel=8

  while (($# > 0)); do
    case "$1" in
      --config)       config_file="$2";    shift 2 ;;
      --work-dir)     work_dir="$2";       shift 2 ;;
      --skip-discover) skip_discover=true; shift ;;
      --repository)   only_repository="$2"; shift 2 ;;
      --repositories) repositories="$2";   shift 2 ;;
      --cluster)      only_cluster="$2";   shift 2 ;;
      --parallel)     parallel="$2";       shift 2 ;;
      --out-json)     out_json="$2";       shift 2 ;;
      -h|--help)      usage; exit 0 ;;
      *) usage >&2; fail "unknown argument '$1'" ;;
    esac
  done

  [[ -n "$config_file" ]] || { usage >&2; fail "--config is required"; }
  [[ -z "$only_repository" || -z "$repositories" ]] \
    || fail "--repository and --repositories are mutually exclusive"
  [[ -n "$only_repository" ]] && repositories="$only_repository"

  [[ -n "$work_dir" ]] || work_dir="$(mktemp -d)"
  require_tool az curl jq

  config_init --file "$config_file" --work-dir "$work_dir" >/dev/null

  local protection_file="${work_dir}/protection-set.json"
  if [[ "$skip_discover" == true ]]; then
    [[ -f "$protection_file" ]] \
      || fail "--skip-discover: ${protection_file} not found; run without it once, or point --work-dir at a directory that already has one"
    log "reusing ${protection_file} (generated $(jq -r '.generated_at' "$protection_file"))"
  else
    if [[ "$(config_get '.in_use_protection.cluster_access_mode')" == "kubectl" ]]; then
      require_tool kubectl helm
      command -v kubelogin >/dev/null 2>&1 \
        || warn "kubelogin not found; clusters with Azure RBAC will fail to authenticate non-interactively"
    fi
    discover_all "$work_dir" "$only_cluster"
  fi

  acr_init

  local repo_filter
  repo_filter="$(jq -cn --arg r "$repositories" '$r | split(",") | map(select(. != ""))')"
  if [[ -n "$repositories" ]]; then
    local deployed_repos unknown not_deployed
    deployed_repos="$(jq -c '[ (.protected_tags[], .protected_digests[]) | .repository ] | unique' "$protection_file")"

    unknown="$(jq -rn --argjson want "$repo_filter" \
      --argjson have "$(acr_list_repositories || printf '[]')" \
      '[ $want[] | . as $w | select(($have | index($w)) == null) ] | join(", ")')"
    [[ -z "$unknown" ]] \
      || fail "--repository/--repositories: not found in the registry: ${unknown}"

    not_deployed="$(jq -rn --argjson want "$repo_filter" --argjson have "$deployed_repos" \
      '[ $want[] | . as $w | select(($have | index($w)) == null) ] | join(", ")')"
    [[ -z "$not_deployed" ]] \
      || warn "nothing is currently deployed from: ${not_deployed} (a real repository, just not running or in Helm history anywhere right now) - nothing to check for it"

    log "limited to repositories: ${repositories}"
  fi

  local items_by_repo out_dir results_file
  items_by_repo="$(_ari_wanted_items "$protection_file" "$repo_filter")"
  out_dir="$(mktemp -d)"
  results_file="$(mktemp)"

  local repos total repo_count
  repos="$(jq -r '[.[].repository] | unique | .[]' <<<"$items_by_repo")"
  total="$(jq 'length' <<<"$items_by_repo")"
  repo_count="$(jq -r '[.[].repository] | unique | length' <<<"$items_by_repo")"
  log "checking ${total} deployed image(s) across ${repo_count} repositor$([[ "$repo_count" == "1" ]] && printf 'y' || printf 'ies')"

  local running=0 repository repo_items safe
  while IFS= read -r repository; do
    [[ -n "$repository" ]] || continue
    repo_items="$(jq -c --arg r "$repository" '[.[] | select(.repository == $r)]' <<<"$items_by_repo")"
    safe="${repository//\//__}"
    ( _ari_audit_one_repository "$protection_file" "${out_dir}/${safe}.txt" "$repository" "$repo_items" ) &
    running=$((running + 1))
    if ((running >= parallel)); then
      wait -n || true
      running=$((running - 1))
    fi
  done <<< "$repos"
  wait

  cat "${out_dir}"/*.txt > "$results_file" 2>/dev/null || : > "$results_file"
  cat "$results_file"
  rm -rf "$out_dir"

  local ok_count broken_count unreadable_count
  ok_count="$(grep -c '^ok' "$results_file" || true)"
  broken_count="$(grep -c '^BROKEN' "$results_file" || true)"
  unreadable_count="$(grep -c '^UNREADABLE' "$results_file" || true)"

  # Written before any of the exit paths below, so a caller (acr-cleanup.sh
  # --validate-after) always gets the structured result even when this script
  # goes on to fail. Only non-ok lines become items; ok lines are just counted
  # - a clean run can have thousands of them.
  if [[ -n "$out_json" ]]; then
    jq -R -s -c \
      --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      --argjson skip_discover "$skip_discover" \
      --argjson checked "$total" --argjson ok "$ok_count" \
      --argjson broken "$broken_count" --argjson unreadable "$unreadable_count" \
      '
        (split("\n") | map(select(. != "" and (startswith("ok\t") | not)))
          | map(split("\t"))
          | map({ status: .[0] } + (.[1:] | map(split("=")) | map({ (.[0]): (.[1:] | join("=")) }) | add))
        ) as $items
        | { generated_at: $generated_at, skip_discover: $skip_discover,
            totals: { checked: $checked, ok: $ok, broken: $broken, unreadable: $unreadable },
            items: $items }
      ' "$results_file" > "$out_json"
  fi
  rm -f "$results_file"

  log "done: ${ok_count} intact, ${broken_count} BROKEN, ${unreadable_count} unreadable, of ${total} deployed image(s) checked"
  if ((broken_count > 0)); then
    fail "${broken_count} running image(s) would fail to pull fresh; see BROKEN lines above and RUNBOOK.md section 6"
  fi
  ((unreadable_count == 0)) \
    || { warn "${unreadable_count} image(s) could not be checked; treat as unverified, not as safe"; exit 1; }
  log "all deployed images are intact"
}

main "$@"
