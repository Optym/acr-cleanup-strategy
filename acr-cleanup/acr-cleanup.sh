#!/usr/bin/env bash
#
# acr-cleanup - config-driven ACR cleanup with protection derived from what is
# actually running in Kubernetes. See README.md.
#
# Stages run strictly in sequence. Parallelism lives inside stages 1, 2 and 5,
# never between them.
#
#   #  stage             script                        writes                          mutates ACR
#   1  discover          lib/discover-k8s.sh           protection-set.json             no
#   2  inventory         lib/acr-api.sh                inventory.json                  no
#   3  classify          lib/classify.sh               plan.json                       no
#   4  reconcile locks   lib/lock-reconcile.sh         lock-result.json                yes, unlocks only
#   5  execute           lib/execute.sh                delete-result.json              yes, untag or manifests
#   6  validate (opt-in) tools/audit-running-images.sh validation-result.json          no
#   7  report            lib/report.sh                 result.json, report-*.html      no
#   8  notify (opt-in)   lib/notify-sendgrid.sh         -                              no
#
# Stages 1-3 are read-only and always safe to run ad hoc. lock-reconcile is the
# only writer of lock state; execute skips locked items rather than unlocking
# them. Stages 4 and 5 record their errors and the run continues to the report,
# so the diagnosis is never lost; the exit code is non-zero afterwards. Stage 6
# only runs with --validate-after, and reuses this run's own freshly-discovered
# protection-set.json (--skip-discover) rather than crawling the clusters again.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=lib/discover-k8s.sh
source "${SCRIPT_DIR}/lib/discover-k8s.sh"
# shellcheck source=lib/acr-api.sh
source "${SCRIPT_DIR}/lib/acr-api.sh"
# shellcheck source=lib/classify.sh
source "${SCRIPT_DIR}/lib/classify.sh"
# shellcheck source=lib/lock-reconcile.sh
source "${SCRIPT_DIR}/lib/lock-reconcile.sh"
# shellcheck source=lib/execute.sh
source "${SCRIPT_DIR}/lib/execute.sh"
# shellcheck source=lib/report.sh
source "${SCRIPT_DIR}/lib/report.sh"
# shellcheck source=lib/notify-sendgrid.sh
source "${SCRIPT_DIR}/lib/notify-sendgrid.sh"

usage() {
  cat <<'USAGE'
Usage: acr-cleanup.sh --config <file> [options]

Options:
  --config <file>        Config YAML. Required.
  --operation <op>       What to run. Default: plan
                           validate-config           load and validate the config, nothing else
                           discover                  stage 1 only: protection set from the clusters
                           inventory                 stage 2 only: registry inventory
                           plan                      stages 1-3 + report. Read-only: what WOULD happen
                           untag-stale-tags          stages 1-7; execute untags stale tags (reversible)
                           sweep-untagged-manifests  stages 1-7; execute deletes manifests that have
                                                     been untagged for min_untagged_manifest_age_days
                                                     (irreversible)
                           untag-and-sweep           both execute steps in one run; prefer two runs
                         Old names untag / manifests / full are accepted with a warning.
  --work-dir <dir>       Where stage JSON is written. Default: ./.acr-cleanup-work
  --previous-dir <dir>   Last run's result.json and lock-ledger.json, for the delta and the
                         unlock wait. Default: <work-dir>/previous
  --cluster <name>       Discover only this cluster and skip the merge. Used by the
                         pipeline, which runs one job per cluster.
  --repositories <list>  Comma-separated repositories. Targeted cleanup: only these are
                         inventoried, classified, executed and reported. Discovery still
                         reads every cluster, so protection is never partial.
  --repository <name>    Inventory only this repository and skip the merge (pipeline use).
                         With any other operation it is treated as --repositories <name>.
  --shard <i>/<n>        Inventory only repositories with index % n == i - 1 (1-based),
                         skip the merge. Used by the pipeline's parallel inventory jobs.
  --merge                Merge existing per-cluster (or, with --operation inventory,
                         per-repository) output and stop.
  --skip-discover        Reuse <work-dir>/protection-set.json instead of running stage 1.
  --skip-inventory       Reuse <work-dir>/inventory.json instead of running stage 2.
  --validate-after       After execute, run tools/audit-running-images.sh (--skip-discover,
                         against this run's own protection set) to confirm every running
                         image is still pullable. A broken image does not stop the report
                         from being produced, but does make the run's exit code non-zero.
                         The result shows up in report-protected.html and as a status card
                         in report-summary.html.
  --tag-groups <list>    Comma-separated tag_group names to limit the run to.
  --dry-run              Force run_settings.dry_run true.
  --no-dry-run           Force run_settings.dry_run false.
  --set <path=value>     Override any config value. Repeatable.
                         Dotted path, e.g. run_settings.parallel_delete_workers=8
                         Rules are addressable by name rather than index:
                         rule.pull_request_builds.delete_when_older_than_days=3
  --print-config         Print the effective config JSON and exit.
  -h, --help             This message.

Config precedence, lowest to highest:
  built-in defaults -> config file -> ACR_CLEANUP_SET env -> --set on the CLI

Examples:
  # validate config only, touches no Azure resources
  ./acr-cleanup.sh --config config/routemax.yaml --operation validate-config

  # build the protection set from every cluster (read-only)
  ./acr-cleanup.sh --config config/routemax.yaml --operation discover

  # one cluster only, as the pipeline runs it
  ./acr-cleanup.sh --config config/routemax.yaml --operation discover \
    --cluster rmx-aks-np-eus-c1

  # read the registry inventory (read-only)
  ./acr-cleanup.sh --config config/routemax.yaml --operation inventory

  # plan a run and inspect the candidates and the report
  ./acr-cleanup.sh --config config/routemax.yaml --operation plan

  # real run, PR builds only, capped
  ./acr-cleanup.sh --config config/routemax.yaml --operation untag-stale-tags --no-dry-run \
    --tag-groups pull_request_builds --set run_settings.max_deletions_per_run=5000

  # targeted: two repositories only, plan first, then untag
  ./acr-cleanup.sh --config config/routemax.yaml --operation plan \
    --repositories routemax/ui,routemax/tsp
  ./acr-cleanup.sh --config config/routemax.yaml --operation untag-stale-tags --no-dry-run \
    --repositories routemax/ui,routemax/tsp --skip-discover
USAGE
}

main() {
  local config_file="" operation="plan" work_dir="./.acr-cleanup-work" previous_dir=""
  local tag_groups="" print_config=false only_cluster="" only_repository="" repositories="" shard="" merge_only=false
  local skip_discover=false skip_inventory=false validate_after=false
  local overrides=()

  while (($# > 0)); do
    case "$1" in
      --config)         config_file="$2"; shift 2 ;;
      --operation)      operation="$2";   shift 2 ;;
      --work-dir)       work_dir="$2";    shift 2 ;;
      --previous-dir)   previous_dir="$2"; shift 2 ;;
      --cluster)        only_cluster="$2"; shift 2 ;;
      --repository)     only_repository="$2"; shift 2 ;;
      --repositories)   repositories="$2"; shift 2 ;;
      --shard)          shard="$2";       shift 2 ;;
      --merge)          merge_only=true;  shift ;;
      --skip-discover)  skip_discover=true; shift ;;
      --skip-inventory) skip_inventory=true; shift ;;
      --validate-after) validate_after=true; shift ;;
      --tag-groups)     tag_groups="$2";  shift 2 ;;
      --set)            overrides+=(--set "$2"); shift 2 ;;
      --dry-run)        overrides+=(--set "run_settings.dry_run=true");  shift ;;
      --no-dry-run)     overrides+=(--set "run_settings.dry_run=false"); shift ;;
      --print-config)   print_config=true; shift ;;
      -h|--help)        usage; exit 0 ;;
      *) usage >&2; fail "unknown argument '$1'" ;;
    esac
  done

  [[ -n "$config_file" ]] || { usage >&2; fail "--config is required"; }
  [[ -n "$previous_dir" ]] || previous_dir="${work_dir}/previous"

  # Old names stay accepted so existing pipelines and notes keep working.
  case "$operation" in
    untag)     warn "--operation untag is now untag-stale-tags";              operation=untag-stale-tags ;;
    manifests) warn "--operation manifests is now sweep-untagged-manifests";  operation=sweep-untagged-manifests ;;
    full)      warn "--operation full is now untag-and-sweep";                operation=untag-and-sweep ;;
  esac
  case "$operation" in
    validate-config|discover|inventory|plan|untag-stale-tags|sweep-untagged-manifests|untag-and-sweep) ;;
    *) fail "unknown --operation '$operation' (expected validate-config, discover, inventory, plan, untag-stale-tags, sweep-untagged-manifests or untag-and-sweep)" ;;
  esac

  [[ -z "$repositories" || -z "$only_repository" ]] || fail "--repositories and --repository are mutually exclusive"

  # --repository shards the inventory operation for the pipeline. For any other
  # operation it used to be silently ignored, and the run inventoried the whole
  # registry; a single repository is what the caller meant, so honour that.
  if [[ -n "$only_repository" && "$operation" != "inventory" ]]; then
    warn "--repository only shards --operation inventory; treating it as --repositories ${only_repository}"
    repositories="$only_repository"
    only_repository=""
  fi

  install_interrupt_handler
  [[ -z "$repositories" || -z "$shard" ]] || fail "--repositories cannot be combined with --shard"

  if [[ -n "$shard" ]]; then
    [[ "$shard" =~ ^[0-9]+/[0-9]+$ ]] || fail "--shard expects <i>/<n>, got '$shard'"
    (( ${shard%%/*} >= 1 && ${shard%%/*} <= ${shard##*/} )) || fail "--shard: index out of range in '$shard'"
  fi

  require_tool jq grep date awk
  command -v yq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 \
    || fail "need yq, or python3 with PyYAML, to read the config YAML"

  config_init --file "$config_file" --work-dir "$work_dir" \
    ${overrides[@]+"${overrides[@]}"}

  if [[ -n "$tag_groups" ]]; then
    local group
    for group in ${tag_groups//,/ }; do
      jq -e --arg g "$group" 'any(.image_cleanup_rules[]; .tag_group == $g)' \
        "$(config_path)" >/dev/null \
        || fail "--tag-groups: no rule named '$group'"
    done
    log "restricted to tag groups: $tag_groups"
  fi

  if [[ "$print_config" == true ]]; then
    jq '.' "$(config_path)"
    exit 0
  fi

  if [[ "$operation" == "validate-config" ]]; then
    log "config is valid"
    log "registry:      $(config_get '.registry.name')"
    log "clusters:      $(config_get '[.in_use_protection.clusters[].name] | join(", ")')"
    log "cleanup rules: $(config_get '[.image_cleanup_rules[].tag_group] | join(", ")')"
    log "dry run:       $(config_get '.run_settings.dry_run')"
    log "image lock:    lock_at_deploy=$(config_get '.image_lock.lock_at_deploy.enabled') unlock_when_unused=$(config_get '.image_lock.unlock_when_unused.enabled')"
    exit 0
  fi

  if [[ "$merge_only" == true ]]; then
    [[ "$operation" == "inventory" ]] && { acr_inventory_merge "$work_dir"; exit 0; }
    discover_merge "$work_dir"
    exit 0
  fi

  require_tool az curl

  # ---- stage 2 alone -------------------------------------------------------
  if [[ "$operation" == "inventory" ]]; then
    stage_begin "$work_dir" "2/8 inventory"
    acr_init
    if [[ -n "$shard" ]]; then
      acr_inventory_shard "$work_dir" "${shard%%/*}" "${shard##*/}"
      stage_end ok "shard ${shard}"
    elif [[ -n "$only_repository" ]]; then
      acr_inventory_all "$work_dir" "$only_repository" true
      stage_end ok "repository ${only_repository}, not merged"
    else
      acr_inventory_all "$work_dir" "$repositories"
      stage_end ok "$(jq -r '.totals | "\(.repositories) repo(s), \(.tags) tag(s), \(.manifests) manifest(s)"' "${work_dir}/inventory.json" 2>/dev/null || printf 'single repository')"
    fi
    exit 0
  fi

  rm -f "${work_dir}/errors.jsonl" "${work_dir}/timings.json"

  # ---- stage 1 -------------------------------------------------------------
  stage_begin "$work_dir" "1/8 discover"
  if [[ "$skip_discover" == true ]]; then
    [[ -f "${work_dir}/protection-set.json" ]] \
      || fail "--skip-discover: ${work_dir}/protection-set.json not found"
    log "reusing ${work_dir}/protection-set.json"
    stage_end skipped "reused protection-set.json ($(jq -r '"\(.protected_tags | length) tag(s), \(.protected_digests | length) digest(s)"' "${work_dir}/protection-set.json"))"
  else
    if [[ "$(config_get '.in_use_protection.cluster_access_mode')" == "kubectl" ]]; then
      require_tool kubectl helm
      command -v kubelogin >/dev/null 2>&1 \
        || warn "kubelogin not found; clusters with Azure RBAC will fail to authenticate non-interactively"
    fi

    if [[ -n "$only_cluster" ]]; then
      jq -e --arg c "$only_cluster" 'any(.in_use_protection.clusters[]; .name == $c)' \
        "$(config_path)" >/dev/null \
        || fail "--cluster: '$only_cluster' is not in in_use_protection.clusters"
    fi

    discover_all "$work_dir" "$only_cluster"
    if [[ -n "$only_cluster" ]]; then
      stage_end ok "cluster ${only_cluster}: $(jq '.entries | length' "${work_dir}/protection/${only_cluster}.json") reference(s)"
    else
      stage_end ok "$(jq -r '"\(.protected_tags | length) tag(s), \(.protected_digests | length) digest(s) across \(.clusters | length) cluster(s)"' "${work_dir}/protection-set.json")"
    fi
  fi

  if [[ "$operation" == "discover" ]]; then
    exit 0
  fi

  # ---- stage 2 -------------------------------------------------------------
  local started usage_before="" usage_after=""
  started="$(date -u +%s)"

  stage_begin "$work_dir" "2/8 inventory"
  if [[ "$skip_inventory" == true ]]; then
    [[ -f "${work_dir}/inventory.json" ]] \
      || fail "--skip-inventory: ${work_dir}/inventory.json not found"
    log "reusing ${work_dir}/inventory.json"
    acr_init
    stage_end skipped "reused inventory.json ($(jq -r '.totals | "\(.repositories) repo(s), \(.tags) tag(s), \(.manifests) manifest(s)"' "${work_dir}/inventory.json"))"
  else
    acr_init
    acr_inventory_all "$work_dir" "$repositories"
    stage_end ok "$(jq -r '.totals | "\(.repositories) repo(s), \(.tags) tag(s), \(.manifests) manifest(s), \(.locked_tags) locked"' "${work_dir}/inventory.json")"
  fi
  usage_before="$(acr_usage_bytes)"
  log "registry storage before: $(human_bytes "$usage_before")"

  # ---- stage 3 -------------------------------------------------------------
  stage_begin "$work_dir" "3/8 classify"
  classify_run "$work_dir" "$tag_groups" "$repositories"
  stage_end ok "$(jq -r '.totals | "\(.untag_candidates) untag candidate(s), \(.manifest_candidates) sweep candidate(s), \(.locked_tags) locked tag(s)"' "${work_dir}/plan.json")"

  local exit_code=0
  if [[ "$operation" == "plan" ]]; then
    usage_after="$usage_before"
    stage_begin "$work_dir" "4/8 lock-reconcile"; stage_end skipped "plan only"
    stage_begin "$work_dir" "5/8 execute";        stage_end skipped "plan only"
  else
    # ---- stage 4: the only writer of lock state --------------------------
    stage_begin "$work_dir" "4/8 lock-reconcile"
    if lock_reconcile_run "$work_dir" "$previous_dir"; then
      stage_end ok "$(jq -r '.totals | "held=\(.held // 0) waiting=\(.waiting // 0) unlocked=\((.unlocked // 0) + (."unlock-dry-run" // 0))"' "${work_dir}/lock-result.json")"
    else
      report_record_error "$work_dir" "lock-reconcile" "one or more unlocks failed; see lock-result.json"
      stage_end failed "see lock-result.json"
      exit_code=1
    fi

    # ---- stage 5 -------------------------------------------------------------
    local mode modes=()
    case "$operation" in
      untag-stale-tags)         modes=(untag) ;;
      sweep-untagged-manifests) modes=(manifests) ;;
      untag-and-sweep)          modes=(untag manifests) ;;
    esac
    for mode in "${modes[@]}"; do
      stage_begin "$work_dir" "5/8 execute ${mode}"
      if execute_run "$work_dir" "$mode"; then
        stage_end ok "$(jq -r '.totals | "succeeded=\(.succeeded) dry_run=\(.dry_run) over_cap=\(.over_cap)"' "${work_dir}/delete-result.json")"
      else
        report_record_error "$work_dir" "execute" "one or more ${mode} operations failed; see delete-result.json"
        stage_end failed "$(jq -r '.totals | "succeeded=\(.succeeded) failed=\(.failed)"' "${work_dir}/delete-result.json" 2>/dev/null || printf 'see delete-result.json')"
        exit_code=1
      fi
      # `full` keeps both results: the untag one is renamed so the report can find the sweep.
      [[ "$operation" == "untag-and-sweep" && "$mode" == "untag" ]] \
        && cp "${work_dir}/delete-result.json" "${work_dir}/delete-result.untag.json"
    done
    usage_after="$(acr_usage_bytes)"
    log "registry storage after: $(human_bytes "$usage_after")"
  fi

  # ---- stage 6: opt-in post-run validation ---------------------------------
  # Must run before the report (stage 7), so its result is already sitting in
  # validation-result.json for report.sh to pick up. Reuses this run's own
  # protection-set.json (--skip-discover) rather than crawling the clusters a
  # second time - a broken image found here is never allowed to suppress the
  # report that goes on to show it.
  stage_begin "$work_dir" "6/8 validate"
  if [[ "$validate_after" == true ]]; then
    if "${SCRIPT_DIR}/tools/audit-running-images.sh" --config "$config_file" \
         --work-dir "$work_dir" --skip-discover \
         --out-json "${work_dir}/validation-result.json"; then
      stage_end ok "$(jq -r '.totals | "\(.ok) intact, \(.broken) broken, \(.unreadable) unreadable"' "${work_dir}/validation-result.json")"
    else
      report_record_error "$work_dir" "validate" "one or more running images are broken or unreadable after cleanup; see validation-result.json"
      stage_end failed "see validation-result.json"
      exit_code=1
    fi
  else
    stage_end skipped "not requested (--validate-after)"
  fi

  # ---- stage 7: always ---------------------------------------------------------
  stage_begin "$work_dir" "7/8 report"
  report_run "$work_dir" "$operation" "$previous_dir" "$started" "$usage_before" "$usage_after"
  stage_end ok "$(jq -r '.run.status' "${work_dir}/result.json")"

  # Carry this run's result and lock ledger forward so the NEXT invocation
  # against this work-dir (the normal local pattern) sees them as "previous"
  # without any extra flag. The pipeline does the equivalent by downloading the
  # prior run's report artifact into --previous-dir before this script starts;
  # this rotation only matters when nothing already did that.
  carry_forward_to_previous "$work_dir" "$previous_dir"

  # ---- stage 8: opt-in, warn only ---------------------------------------------
  stage_begin "$work_dir" "8/8 notify"
  if notify_sendgrid_run "$work_dir"; then stage_end ok; else stage_end skipped "not sent"; fi

  log "run summary: $(jq -r '[.stages[] | "\(.stage | sub("^[0-9]/8 "; "")) \(.seconds)s"] | join(", ")' "${work_dir}/timings.json")"
  if ((exit_code != 0)); then
    fail "run finished with errors; the report at ${work_dir}/report-summary.html has the details"
  fi
  log "done: ${work_dir}/report-summary.html, ${work_dir}/report-deleted.html, ${work_dir}/report-protected.html"
}

main "$@"
