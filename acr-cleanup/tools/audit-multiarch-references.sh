#!/usr/bin/env bash
#
# Read-only audit for the incident documented in RUNBOOK.md section 6 and
# progress.md's 2026-09-06 change log entry: find every currently-tagged
# multi-architecture image (an OCI image index or Docker manifest list) whose
# child manifest is missing, which is invisible in the portal - the tag and
# the index both still look completely normal - but breaks the pull the next
# time a node needs a fresh copy.
#
# Root cause this exists to catch: Azure Container Registry's bulk
# `_manifests` listing never returns the `references` field for an index, only
# a per-manifest GET does. lib/acr-api.sh's inventory now resolves that
# correctly (see the incident writeup), but this script exists independently
# to spot-check the registry itself, or to audit a registry that has not
# picked up the fix yet.
#
# Mutates nothing - GET requests only.
#
#   tools/audit-multiarch-references.sh --config <file> [--repository <repo>] [--parallel N]
#
# Without --repository, every repository in the registry is checked. Prints
# one line per tagged multi-arch manifest found: "ok" or "BROKEN", with the
# missing child digests. Exit code is non-zero if any BROKEN line was printed.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname -- "$SCRIPT_DIR")"

# shellcheck source=../lib/common.sh
source "${MODULE_DIR}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${MODULE_DIR}/lib/config.sh"
# shellcheck source=../lib/acr-api.sh
source "${MODULE_DIR}/lib/acr-api.sh"

usage() {
  cat <<'USAGE'
Usage: audit-multiarch-references.sh --config <file> [--repository <repo>] [--parallel N] [--work-dir <dir>]

  --config <file>      Config YAML (for registry name/subscription only; no cluster access needed)
  --repository <repo>  Check only this repository. Default: every repository in the registry
  --parallel <n>       Repositories checked concurrently when auditing the whole registry. Default: 6
  --work-dir <dir>     Scratch directory for config_init. Default: a temp directory
USAGE
}

audit_one_repo() {
  local repository="$1"
  local manifests_json multi n
  manifests_json="$(acr_list_manifests "$repository")" \
    || { log "${repository}: could not list manifests, skipping"; return 0; }

  multi="$(jq -c '
    [ .[] | select((.tags // []) | length > 0)
      | select(.mediaType == "application/vnd.oci.image.index.v1+json"
               or .mediaType == "application/vnd.docker.distribution.manifest.list.v2+json") ]
  ' <<<"$manifests_json")"
  n="$(jq 'length' <<<"$multi")"
  ((n > 0)) || return 0
  log "${repository}: ${n} tagged multi-arch/manifest-list entr$([[ "$n" == "1" ]] && printf 'y' || printf 'ies')"

  local entry digest tags refs child broken
  while IFS= read -r entry; do
    digest="$(jq -r .digest <<<"$entry")"
    tags="$(jq -r '.tags | join(",")' <<<"$entry")"

    if ! refs="$(acr_manifest_references "$repository" "$digest")"; then
      printf 'UNREADABLE\trepository=%s\ttags=%s\tindex=%s\n' "$repository" "$tags" "$digest"
      continue
    fi

    broken=""
    for child in $(jq -r '.[]' <<<"$refs"); do
      if ! acr_request GET "/acr/v1/${repository}/_manifests/${child}" read "$repository" >/dev/null 2>&1; then
        [[ "$ACR_HTTP_STATUS" == "404" ]] && broken="${broken}${child} "
      fi
    done

    if [[ -n "$broken" ]]; then
      printf 'BROKEN\trepository=%s\ttags=%s\tindex=%s\tmissing_children=%s\n' \
        "$repository" "$tags" "$digest" "${broken% }"
    else
      printf 'ok\trepository=%s\ttags=%s\tindex=%s\n' "$repository" "$tags" "$digest"
    fi
  done < <(jq -c '.[]' <<<"$multi")
}

main() {
  local config_file="" only_repository="" parallel=6 work_dir=""

  while (($# > 0)); do
    case "$1" in
      --config)     config_file="$2";    shift 2 ;;
      --repository) only_repository="$2"; shift 2 ;;
      --parallel)   parallel="$2";       shift 2 ;;
      --work-dir)   work_dir="$2";       shift 2 ;;
      -h|--help)    usage; exit 0 ;;
      *) usage >&2; fail "unknown argument '$1'" ;;
    esac
  done

  [[ -n "$config_file" ]] || { usage >&2; fail "--config is required"; }
  [[ -n "$work_dir" ]] || work_dir="$(mktemp -d)"
  require_tool az curl jq

  config_init --file "$config_file" --work-dir "$work_dir" >/dev/null
  acr_init

  local results_file
  results_file="$(mktemp)"

  if [[ -n "$only_repository" ]]; then
    audit_one_repo "$only_repository" | tee "$results_file"
  else
    local repos_json count index repository running=0
    repos_json="$(acr_list_repositories)" || fail "could not list repositories"
    count="$(jq 'length' <<<"$repos_json")"
    log "registry has ${count} repositories, ${parallel} at a time"

    for ((index = 0; index < count; index++)); do
      repository="$(jq -r ".[$index]" <<<"$repos_json")"
      ( audit_one_repo "$repository" >> "$results_file" ) &
      running=$((running + 1))
      if ((running >= parallel)); then
        wait -n || true
        running=$((running - 1))
      fi
    done
    wait
    cat "$results_file"
  fi

  local broken_count
  broken_count="$(grep -c '^BROKEN' "$results_file" || true)"
  local unreadable_count
  unreadable_count="$(grep -c '^UNREADABLE' "$results_file" || true)"
  rm -f "$results_file"

  log "audit complete: ${broken_count} broken, ${unreadable_count} unreadable"
  ((broken_count == 0 && unreadable_count == 0))
}

main "$@"
