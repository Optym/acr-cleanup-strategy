#!/usr/bin/env bash
#
# Deploy-time lock: after `helm upgrade`, lock every image this release deploys
# so the weekly cleanup cannot remove it before the next run sees it running.
#
# Reads image_lock.lock_at_deploy from the config: whether to lock at all, and
# which release environments qualify (case-insensitive substring match against
# --environment; exclude wins over include). The environment list lives in the
# config so adding one is a reviewed PR, not an edit in the release UI.
#
# The image list comes from the rendered Helm manifest, never from a hardcoded
# list, so it cannot drift from what was deployed. Pass either:
#   --manifest-file <path>          a file produced by `helm template` / `helm get manifest`
#   --release <name> --namespace <ns>   to run `helm get manifest` here
#
# What is locked: deleteEnabled=false on the tag AND on its manifest. Write
# stays enabled so a digest can still be re-tagged. Unlocking is the job of
# lib/lock-reconcile.sh in the weekly run; this script never unlocks.
#
# Exit codes: 0 locked or skipped by policy; 1 usage or config error;
# 2 one or more images could not be locked (the deploy itself succeeded, and the
# running pod protects the image until the next cleanup run, so treat 2 as a
# warning: continueOnError in the release step).
#
# Usage:
#   deploy/lock-deployed-images.sh --config config/myproduct.yaml \
#     --environment "$(Release.EnvironmentName)" --manifest-file helm_template.yaml
#
# The file can also be sourced for tests; main runs only when executed.

set -euo pipefail

LOCK_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCK_MODULE_DIR="$(dirname -- "$LOCK_SCRIPT_DIR")"

# shellcheck source=../lib/common.sh
source "${LOCK_MODULE_DIR}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${LOCK_MODULE_DIR}/lib/config.sh"
# shellcheck source=../lib/discover-k8s.sh
source "${LOCK_MODULE_DIR}/lib/discover-k8s.sh"
# shellcheck source=../lib/acr-api.sh
source "${LOCK_MODULE_DIR}/lib/acr-api.sh"

# shellcheck disable=SC2034  # read by lib/common.sh log helpers
ACR_CLEANUP_LOG_SCOPE="lock-deployed-images"

lock_usage() {
  cat <<'USAGE'
Usage: lock-deployed-images.sh --config <file> --environment <name>
                               (--manifest-file <path> | --release <name> --namespace <ns>)
                               [--kubeconfig <path>] [--work-dir <dir>] [--dry-run]
USAGE
}

# Returns 0 when the environment qualifies for a lock under lock_at_deploy.
lock_environment_qualifies() {
  local environment="$1"
  local lowered="${environment,,}"
  local pattern

  while IFS= read -r pattern; do
    [[ -n "$pattern" ]] || continue
    if [[ "$lowered" == *"${pattern,,}"* ]]; then
      log "environment '${environment}' matches exclude '${pattern}' -> skipping lock"
      return 1
    fi
  done < <(config_get '.image_lock.lock_at_deploy.environments.exclude[]?')

  while IFS= read -r pattern; do
    [[ -n "$pattern" ]] || continue
    if [[ "$lowered" == *"${pattern,,}"* ]]; then
      return 0
    fi
  done < <(config_get '.image_lock.lock_at_deploy.environments.include[]?')

  log "environment '${environment}' not in lock_at_deploy.environments -> skipping lock"
  return 1
}

# Manifest text on stdin -> JSON array of { repository, tag } for this registry.
lock_images_from_manifest() {
  _dk8s_refs_from_helm_manifest \
    | awk '{ print "\t" $0 }' \
    | _dk8s_refs_to_entries deploy helm-manifest release \
    | jq -c '[ .[] | select(.match == "registry" and has("tag")) | { repository, tag } ] | unique'
}

# Locks one tag and its manifest. Prints the resulting status word.
lock_one() {
  local repository="$1" tag="$2" dry_run="$3"

  if ! acr_request GET "/acr/v1/${repository}/_tags/${tag}" read "$repository"; then
    printf 'missing'
    return 1
  fi

  local digest tag_locked write_enabled
  digest="$(jq -r '.tag.digest // ""' <<<"$ACR_HTTP_BODY")"
  tag_locked="$(jq -r '.tag.changeableAttributes.deleteEnabled == false' <<<"$ACR_HTTP_BODY")"
  write_enabled="$(jq -r 'if .tag.changeableAttributes.writeEnabled == false then false else true end' <<<"$ACR_HTTP_BODY")"
  [[ -n "$digest" ]] || { printf 'no-digest'; return 1; }

  if [[ "$dry_run" == "true" ]]; then
    printf 'dry-run'
    return 0
  fi

  if [[ "$tag_locked" != "true" ]]; then
    acr_set_tag_attributes "$repository" "$tag" "$write_enabled" false \
      || { printf 'tag-lock-failed'; return 1; }
  fi

  local manifest_locked manifest_write
  if acr_request GET "/acr/v1/${repository}/_manifests/${digest}" read "$repository"; then
    manifest_locked="$(jq -r '.manifest.changeableAttributes.deleteEnabled == false' <<<"$ACR_HTTP_BODY")"
    manifest_write="$(jq -r 'if .manifest.changeableAttributes.writeEnabled == false then false else true end' <<<"$ACR_HTTP_BODY")"
  else
    manifest_locked=false
    manifest_write=true
  fi
  if [[ "$manifest_locked" != "true" ]]; then
    acr_set_manifest_attributes "$repository" "$digest" "$manifest_write" false \
      || { printf 'manifest-lock-failed'; return 1; }
  fi

  if [[ "$tag_locked" == "true" && "$manifest_locked" == "true" ]]; then
    printf 'already-locked'
  else
    printf 'locked'
  fi
}

lock_main() {
  local config_file="" environment="" manifest_file="" release="" namespace=""
  local kubeconfig="${KUBECONFIG:-}" work_dir="" dry_run=false

  while (($# > 0)); do
    case "$1" in
      --config)        config_file="$2";   shift 2 ;;
      --environment)   environment="$2";   shift 2 ;;
      --manifest-file) manifest_file="$2"; shift 2 ;;
      --release)       release="$2";       shift 2 ;;
      --namespace)     namespace="$2";     shift 2 ;;
      --kubeconfig)    kubeconfig="$2";    shift 2 ;;
      --work-dir)      work_dir="$2";      shift 2 ;;
      --dry-run)       dry_run=true;       shift ;;
      -h|--help)       lock_usage; return 0 ;;
      *) lock_usage >&2; fail "unknown argument '$1'" ;;
    esac
  done

  [[ -n "$config_file" ]] || { lock_usage >&2; fail "--config is required"; }
  [[ -n "$environment" ]] || { lock_usage >&2; fail "--environment is required"; }
  [[ -n "$manifest_file" || ( -n "$release" && -n "$namespace" ) ]] \
    || { lock_usage >&2; fail "pass --manifest-file, or --release and --namespace"; }

  require_tool jq
  [[ -n "$work_dir" ]] || work_dir="$(mktemp -d)"
  config_init --file "$config_file" --work-dir "$work_dir"

  if [[ "$(config_get '.image_lock.lock_at_deploy.enabled')" != "true" ]]; then
    log "image_lock.lock_at_deploy.enabled is false -> skipping lock"
    return 0
  fi

  lock_environment_qualifies "$environment" || return 0

  local manifest
  if [[ -n "$manifest_file" ]]; then
    [[ -f "$manifest_file" ]] || fail "manifest file not found: $manifest_file"
    manifest="$(cat "$manifest_file")"
  else
    require_tool helm
    manifest="$(KUBECONFIG="$kubeconfig" helm get manifest "$release" -n "$namespace")" \
      || fail "helm get manifest ${namespace}/${release} failed"
  fi

  local images count
  images="$(printf '%s\n' "$manifest" | lock_images_from_manifest)"
  count="$(jq 'length' <<<"$images")"
  ((count > 0)) || { warn "no images for registry '$(config_get '.registry.name')' found in the manifest; nothing to lock"; return 0; }
  log "locking ${count} image(s) deployed to '${environment}' (dry_run=${dry_run})"

  require_tool az curl
  acr_init

  local failed=0 index repository tag status
  for ((index = 0; index < count; index++)); do
    repository="$(jq -r ".[$index].repository" <<<"$images")"
    tag="$(jq -r ".[$index].tag" <<<"$images")"
    status="$(lock_one "$repository" "$tag" "$dry_run")" || true
    case "$status" in
      locked|already-locked|dry-run) log "${status}: ${repository}:${tag}" ;;
      *) warn "${status}: ${repository}:${tag} (HTTP ${ACR_HTTP_STATUS})"; failed=$((failed + 1)) ;;
    esac
  done

  if ((failed > 0)); then
    warn "${failed} of ${count} image(s) could not be locked; running pods still protect them until the next cleanup run"
    return 2
  fi
  log "all ${count} image(s) locked"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  lock_main "$@"
fi
