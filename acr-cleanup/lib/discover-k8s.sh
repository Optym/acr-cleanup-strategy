#!/usr/bin/env bash
#
# Stage 1 - build the protection set: every image that must not be deleted
# because it is running, or is one rollback away from running.
#
#   reads   config, Kubernetes clusters
#   writes  <work-dir>/protection/<cluster>.json, then <work-dir>/protection-set.json
#   mutates nothing in ACR or Kubernetes
#   on failure of a required cluster: ABORT THE RUN before any mutation
#
# Two independent sources:
#
#   L1  live cluster truth
#       - running pod images (containers, initContainers, ephemeralContainers)
#       - pod container statuses, which carry the resolved digest
#       - workload templates: deployments, statefulsets, daemonsets, cronjobs,
#         jobs and scaledjobs, so scaled-to-zero and suspended workloads survive
#
#   L2  Helm release history
#       - the last in_use_protection.keep_helm_revisions revisions of each release,
#         which is the rollback target that is not running right now
#
# Images from other registries (KEDA, Envoy, AGIC, upstream charts) are filtered
# out by hostname. An image whose host looks like the target registry but is not
# in registry.host_aliases is reported as a warning rather than silently dropped.
#
# In the pipeline this runs once per cluster (one job per service connection),
# then --merge combines the per-cluster files. Run without --cluster to walk every
# cluster in one process, which is what a local dry run does.

# shellcheck shell=bash

DK8S_KUBECONFIG=""

# kubectl --request-timeout does not cover a stalled TCP connect to a private
# endpoint, so every cluster command also gets a hard wall-clock cap. Without it a
# discovery job hangs until the pipeline times out instead of failing the cluster.
DK8S_REQUEST_TIMEOUT="${DK8S_REQUEST_TIMEOUT:-90s}"
DK8S_COMMAND_TIMEOUT="${DK8S_COMMAND_TIMEOUT:-180}"

# Transient failures (a dropped connection to a private endpoint, an API server
# restart, a throttled request) are retried before a cluster is declared
# unreachable. Every cluster command goes through _dk8s_retry.
DK8S_RETRIES="${DK8S_RETRIES:-3}"
DK8S_RETRY_DELAY="${DK8S_RETRY_DELAY:-10}"

# Runs "$@" up to DK8S_RETRIES times. stdout is buffered per attempt and only
# released on success, so a partial document from a failed attempt never
# reaches the caller. Returns the last exit status.
_dk8s_retry() {
  local attempt status out_file
  out_file="$(mktemp)"
  for ((attempt = 1; attempt <= DK8S_RETRIES; attempt++)); do
    if "$@" > "$out_file"; then
      cat "$out_file"
      rm -f "$out_file"
      return 0
    else
      status=$?
    fi
    if ((attempt < DK8S_RETRIES)); then
      warn "attempt ${attempt}/${DK8S_RETRIES} failed (exit ${status}): ${1} ${2:-} ${3:-}; retrying in $((DK8S_RETRY_DELAY * attempt))s"
      sleep $((DK8S_RETRY_DELAY * attempt))
    fi
  done
  rm -f "$out_file"
  return "$status"
}

_dk8s_timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then
    printf 'timeout'
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout'
  fi
}

# Runs "$@" under a hard wall-clock cap. Uses coreutils timeout when present and
# falls back to a watchdog, because a host without it (stock macOS) would
# otherwise hang forever on a stalled connect.
_dk8s_capped() {
  local timeout_bin
  timeout_bin="$(_dk8s_timeout_bin)"

  if [[ -n "$timeout_bin" ]]; then
    "$timeout_bin" "$DK8S_COMMAND_TIMEOUT" "$@"
    return $?
  fi

  "$@" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if ((waited >= DK8S_COMMAND_TIMEOUT)); then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

# jq helpers shared by every parsing step below.
readonly _DK8S_JQ_PARSE='
  def clean_ref($ref):
    $ref | sub("^[a-z-]+://"; "");

  # "host/path/repo:tag" or "host/path/repo@sha256:..." -> { host, repository, tag/digest }
  # Anything without a host segment is a Docker Hub short name and can never be ours.
  def parse_image($ref):
    clean_ref($ref) as $r
    | ($r | split("/")) as $parts
    | if ($parts | length) < 2 then empty
      else
        $parts[0] as $host
        | ($parts[1:] | join("/")) as $path
        | if ($path | test("@")) then
            ($path | split("@")) as $split
            | { host: $host,
                repository: ($split[0] | sub(":[^:/]*$"; "")),
                digest: $split[1] }
          elif ($path | test(":[^:/]+$")) then
            { host: $host,
              repository: ($path | sub(":[^:/]*$"; "")),
              tag: ($path | capture(":(?<t>[^:/]+)$") | .t) }
          else
            { host: $host, repository: $path, tag: "latest" }
          end
      end;

  # Splits parsed refs into ours, and ones that merely look like ours.
  def select_registry($hosts; $registry_name):
    map(select(.host != null))
    | map(
        if (.host as $h | $hosts | index($h)) then . + { match: "registry" }
        elif (.host | startswith($registry_name + ".")) then . + { match: "suspect_host" }
        else . + { match: "foreign" }
        end
      );
'

_dk8s_registry_hosts() {
  config_get_json '
    [ (.registry.name + ".azurecr.io") ] + (.registry.host_aliases // []) | unique'
}

# Extracts every image reference from a kubectl JSON document, whatever the kind,
# tagged with the owning item's namespace. Walking each item's own subtree rather
# than naming paths means a new workload kind, or a sidecar injected under an
# unexpected key, is picked up without a code change. Output is one
# "namespace<TAB>ref" line per distinct (namespace, ref) pair - see
# _dk8s_refs_to_entries, which expects exactly this shape.
_dk8s_refs_from_kubectl_json() {
  jq -r '
    [ .items[] as $item
      | ($item.metadata.namespace // "") as $ns
      | ( [ $item | .. | objects
            | (select(has("image"))   | .image),
              (select(has("imageID")) | .imageID)
          ]
          | map(select(type == "string" and . != ""))
          | unique[])
      | [ $ns, . ]
    ]
    | unique
    | .[]
    | @tsv
  '
}

_dk8s_refs_from_helm_manifest() {
  grep -Eo '^[[:space:]]*-?[[:space:]]*image:[[:space:]]*.*' \
    | sed -E 's/.*image:[[:space:]]*//; s/^["'"'"']//; s/["'"'"']$//' \
    | grep -Ev '^[[:space:]]*$' \
    || true
}

# "namespace<TAB>ref" lines on stdin -> protection entries (each carrying
# namespace, cluster, source, detail) on stdout. Every caller - pods,
# workloads, helm - feeds this same shape, so namespace is never dropped
# silently again the way it was before.
_dk8s_refs_to_entries() {
  local cluster="$1" source_kind="$2" detail="$3"
  local hosts registry_name
  hosts="$(_dk8s_registry_hosts)"
  registry_name="$(config_get '.registry.name')"

  jq -R -s -c \
    --argjson hosts "$hosts" \
    --arg registry_name "$registry_name" \
    --arg cluster "$cluster" \
    --arg source_kind "$source_kind" \
    --arg detail "$detail" \
    "${_DK8S_JQ_PARSE}"'
    split("\n")
    | map(select(. != ""))
    | map(split("\t") | { namespace: .[0], ref: .[1] })
    | map(. + parse_image(.ref))
    | map(del(.ref))
    | select_registry($hosts; $registry_name)
    | map(. + { cluster: $cluster, source: $source_kind, detail: $detail })
  '
}

_dk8s_connect() {
  local cluster="$1" resource_group="$2" subscription_id="$3"

  if [[ -n "$subscription_id" && "$subscription_id" != "null" ]]; then
    _dk8s_retry _dk8s_capped az account set --subscription "$subscription_id" --only-show-errors \
      || return 1
  fi

  if [[ "$(config_get '.in_use_protection.cluster_access_mode')" != "kubectl" ]]; then
    return 0
  fi

  _dk8s_retry _dk8s_capped az aks get-credentials \
    --name "$cluster" --resource-group "$resource_group" \
    --file "$DK8S_KUBECONFIG" --overwrite-existing --only-show-errors \
    || return 1

  # Azure RBAC clusters need the exec credential plugin; without this kubectl
  # prompts for a device login and hangs a non-interactive agent.
  if command -v kubelogin >/dev/null 2>&1; then
    KUBECONFIG="$DK8S_KUBECONFIG" _dk8s_capped kubelogin convert-kubeconfig -l azurecli >/dev/null 2>&1 || true
  fi
}

# Runs a read-only command against the cluster and prints its stdout.
_dk8s_run() {
  local cluster="$1" resource_group="$2"; shift 2
  local mode
  mode="$(config_get '.in_use_protection.cluster_access_mode')"

  if [[ "$mode" == "kubectl" ]]; then
    KUBECONFIG="$DK8S_KUBECONFIG" _dk8s_retry _dk8s_capped "$@"
  else
    # `az aks command invoke` wraps everything in a JSON envelope and truncates
    # very large logs, which is why kubectl is the preferred mode.
    _dk8s_retry _dk8s_capped az aks command invoke \
      --name "$cluster" --resource-group "$resource_group" \
      --command "$*" --only-show-errors -o json \
      | jq -r '.logs // ""'
  fi
}

_dk8s_kinds_to_read() {
  local cluster="$1" resource_group="$2"
  local kinds="deployments,statefulsets,daemonsets,cronjobs,jobs"

  # KEDA ScaledJobs hold a pod template but exist only where KEDA is installed.
  if _dk8s_run "$cluster" "$resource_group" \
       kubectl get crd scaledjobs.keda.sh --ignore-not-found -o name \
       --request-timeout="$DK8S_REQUEST_TIMEOUT" 2>/dev/null \
       | grep -q .; then
    kinds="${kinds},scaledjobs.keda.sh"
  fi
  printf '%s' "$kinds"
}

# Collects one release's retained revisions into $out_file. Runs as a background
# worker, so it touches no shared state and always exits 0: a release that cannot
# be read contributes nothing rather than failing the cluster, which is the same
# behaviour as the serial version.
_dk8s_helm_release_entries() {
  local cluster="$1" resource_group="$2" keep_revisions="$3"
  local releases="$4" index="$5" total="$6" out_file="$7"

  local name namespace history revisions revision entries='[]' err_file
  name="$(jq -r ".[$index].name" <<<"$releases")"
  namespace="$(jq -r ".[$index].namespace" <<<"$releases")"
  err_file="$(mktemp)"

  # A release that vanished between `helm list` and here is not an error. Any
  # other failure (after retries) must fail the cluster: silently contributing
  # nothing would leave that release's rollback images unprotected.
  if ! history="$(_dk8s_run "$cluster" "$resource_group" \
        helm history "$name" -n "$namespace" -o json 2>"$err_file")"; then
    if grep -qi "not found" "$err_file"; then
      log "$cluster: helm [$((index + 1))/${total}] ${namespace}/${name} no longer exists, skipping"
      printf '[]' > "$out_file"
      rm -f "$err_file"
      return 0
    fi
    warn "$cluster: helm [$((index + 1))/${total}] ${namespace}/${name}: helm history failed: $(tr '\n' ' ' < "$err_file")"
    printf '[]' > "$out_file"
    : > "${out_file}.failed"
    rm -f "$err_file"
    return 0
  fi
  rm -f "$err_file"
  [[ -n "$history" ]] || history='[]'

  # Fewer revisions than requested is normal for a first deployment, not an error.
  revisions="$(jq -r --argjson keep "$keep_revisions" \
    'sort_by(.revision) | reverse | .[0:$keep] | .[].revision' <<<"$history" 2>/dev/null || true)"

  for revision in $revisions; do
    local manifest revision_entries
    if ! manifest="$(_dk8s_run "$cluster" "$resource_group" \
          helm get manifest "$name" -n "$namespace" --revision "$revision" 2>/dev/null)"; then
      warn "$cluster: helm ${namespace}/${name} revision ${revision}: helm get manifest failed"
      : > "${out_file}.failed"
      continue
    fi
    [[ -n "$manifest" ]] || continue

    revision_entries="$(printf '%s\n' "$manifest" \
      | _dk8s_refs_from_helm_manifest \
      | awk -v ns="$namespace" '{ print ns "\t" $0 }' \
      | _dk8s_refs_to_entries "$cluster" "helm-history" "${namespace}/${name}@rev${revision}")"

    entries="$(jq -c -s 'add' <<<"$entries"$'\n'"$revision_entries")"
  done

  printf '%s' "$entries" > "$out_file"
  log "$cluster: helm [$((index + 1))/${total}] ${namespace}/${name} revisions: $(tr '\n' ' ' <<<"$revisions")"
  return 0
}

# Releases are read in parallel because this phase dominates discovery: MyProduct
# runs a namespace per tenant, so a cluster is dozens of releases times up to
# keep_helm_revisions manifest reads. Every read is read-only and each worker owns
# its own output file, so ordering and correctness are unaffected; only the log
# line order interleaves.
# _dk8s_helm_entries <cluster> <rg> <keep> <out-file>
# Writes the entries JSON array to out-file. Returns 1 when helm list failed or
# any release could not be read after retries.
_dk8s_helm_entries() {
  local cluster="$1" resource_group="$2" keep_revisions="$3" out_file="$4"
  local releases

  if ! releases="$(_dk8s_run "$cluster" "$resource_group" helm list -A -o json 2>/dev/null)"; then
    warn "$cluster: helm list failed"
    printf '[]' > "$out_file"
    return 1
  fi
  [[ -n "$releases" ]] || releases='[]'

  local count
  count="$(jq 'length' <<<"$releases" 2>/dev/null || echo 0)"

  if ((count == 0)); then
    printf '[]' > "$out_file"
    return 0
  fi

  local parallelism
  parallelism="$(config_get '.in_use_protection.helm_parallelism')"
  log "$cluster: reading up to ${keep_revisions} revision(s) of ${count} Helm release(s), ${parallelism} at a time"

  local shard_dir
  shard_dir="$(mktemp -d)"

  local i running=0
  for ((i = 0; i < count; i++)); do
    _dk8s_helm_release_entries "$cluster" "$resource_group" "$keep_revisions" \
      "$releases" "$i" "$count" "${shard_dir}/${i}.json" &
    running=$((running + 1))
    if ((running >= parallelism)); then
      wait -n || true
      running=$((running - 1))
    fi
  done
  wait

  local failed
  failed="$(find "$shard_dir" -name '*.failed' | wc -l | tr -d ' ')"

  jq -c -s 'add // []' "${shard_dir}"/*.json > "$out_file" 2>/dev/null || printf '[]' > "$out_file"
  rm -rf "$shard_dir"

  if ((failed > 0)); then
    warn "$cluster: ${failed} Helm release(s) could not be read after ${DK8S_RETRIES} attempts"
    return 1
  fi
  return 0
}

_dk8s_unlisted_clusters() {
  local configured
  configured="$(config_get_json '[.in_use_protection.clusters[].name]')"

  _dk8s_capped az aks list --only-show-errors -o json 2>/dev/null \
    | jq -c --argjson configured "$configured" '
        [ .[] | { name: .name, resource_group: .resourceGroup, location: .location }
          | select((.name as $n | $configured | index($n)) | not) ]
      ' 2>/dev/null || printf '[]'
}

_dk8s_write_failure() {
  local out_file="$1" cluster="$2" resource_group="$3" required="$4" reason="$5"

  jq -n \
    --arg cluster "$cluster" --arg rg "$resource_group" \
    --argjson required "$required" --arg error "$reason" \
    '{ cluster: $cluster, resource_group: $rg, required: $required,
       status: "unreachable", error: $error,
       entries: [], suspect_hosts: [], foreign_count: 0, unlisted_clusters: [] }' > "$out_file"

  if [[ "$required" == "true" ]]; then
    warn "required cluster '$cluster' is unreachable: $reason"
    return 1
  fi
  warn "optional cluster '$cluster' is unreachable, continuing: $reason"
  return 0
}

# Discovers one cluster and writes <work-dir>/protection/<cluster>.json.
# Returns non-zero only when the cluster is required; an optional cluster that
# cannot be read records a warning so a parked test cluster never blocks cleanup.
discover_cluster() {
  local work_dir="$1" index="$2"
  local cluster resource_group subscription_id required
  cluster="$(config_get ".in_use_protection.clusters[$index].name")"
  resource_group="$(config_get ".in_use_protection.clusters[$index].resource_group")"
  subscription_id="$(config_get ".in_use_protection.clusters[$index].subscription_id // \"\"")"
  required="$(config_get ".in_use_protection.clusters[$index].required")"

  local out_dir="${work_dir}/protection"
  local out_file="${out_dir}/${cluster}.json"
  mkdir -p "$out_dir" "${work_dir}/kubeconfig"
  DK8S_KUBECONFIG="${work_dir}/kubeconfig/${cluster}.conf"

  log "discovering $cluster (${resource_group}, required=${required})"

  if ! _dk8s_connect "$cluster" "$resource_group" "$subscription_id"; then
    _dk8s_write_failure "$out_file" "$cluster" "$resource_group" "$required" \
      "could not obtain cluster credentials"
    return $?
  fi

  local pods
  if ! pods="$(_dk8s_run "$cluster" "$resource_group" \
        kubectl get pods -A -o json --request-timeout="$DK8S_REQUEST_TIMEOUT" 2>/dev/null)" \
     || ! jq -e 'has("items")' <<<"$pods" >/dev/null 2>&1; then
    _dk8s_write_failure "$out_file" "$cluster" "$resource_group" "$required" \
      "could not list pods"
    return $?
  fi

  local kinds workloads
  kinds="$(_dk8s_kinds_to_read "$cluster" "$resource_group")"
  if ! workloads="$(_dk8s_run "$cluster" "$resource_group" \
        kubectl get "$kinds" -A -o json --request-timeout="$DK8S_REQUEST_TIMEOUT" 2>/dev/null)" \
     || ! jq -e 'has("items")' <<<"$workloads" >/dev/null 2>&1; then
    _dk8s_write_failure "$out_file" "$cluster" "$resource_group" "$required" \
      "could not list workloads ($kinds)"
    return $?
  fi

  # Entries go through files from here on: a busy cluster produces thousands of
  # references, and passing that JSON as a command-line argument exceeds ARG_MAX.
  local entries_dir keep_revisions
  entries_dir="$(mktemp -d)"

  printf '%s' "$pods" | _dk8s_refs_from_kubectl_json \
    | _dk8s_refs_to_entries "$cluster" "pod" "running" > "${entries_dir}/pods.json"
  log "$cluster: $(jq '.items | length' <<<"$pods") pod(s), $(jq '[.[] | select(.match=="registry")] | length' "${entries_dir}/pods.json") of our image reference(s)"

  printf '%s' "$workloads" | _dk8s_refs_from_kubectl_json \
    | _dk8s_refs_to_entries "$cluster" "workload" "$kinds" > "${entries_dir}/workloads.json"
  log "$cluster: $(jq '.items | length' <<<"$workloads") workload(s), $(jq '[.[] | select(.match=="registry")] | length' "${entries_dir}/workloads.json") of our image reference(s)"

  keep_revisions="$(config_get '.in_use_protection.keep_helm_revisions')"
  if ! _dk8s_helm_entries "$cluster" "$resource_group" "$keep_revisions" "${entries_dir}/helm.json"; then
    rm -rf "$entries_dir"
    _dk8s_write_failure "$out_file" "$cluster" "$resource_group" "$required" \
      "could not read Helm history for every release"
    return $?
  fi

  local unlisted
  unlisted='[]'
  if [[ "$(config_get '.in_use_protection.report_unlisted_clusters')" == "true" ]]; then
    unlisted="$(_dk8s_unlisted_clusters)"
  fi
  printf '%s' "$unlisted" > "${entries_dir}/unlisted.json"

  jq -n \
    --arg cluster "$cluster" --arg rg "$resource_group" \
    --argjson required "$required" \
    --slurpfile pods "${entries_dir}/pods.json" \
    --slurpfile workloads "${entries_dir}/workloads.json" \
    --slurpfile helm "${entries_dir}/helm.json" \
    --slurpfile unlisted "${entries_dir}/unlisted.json" \
    '
     ($pods[0] + $workloads[0] + $helm[0]) as $entries
     | {
       cluster: $cluster,
       resource_group: $rg,
       required: $required,
       status: "ok",
       error: null,
       entries:       [ $entries[] | select(.match == "registry") ],
       suspect_hosts: [ $entries[] | select(.match == "suspect_host") ] | unique,
       foreign_count: [ $entries[] | select(.match == "foreign") ] | length,
       unlisted_clusters: $unlisted[0]
     }' > "$out_file"
  rm -rf "$entries_dir"

  local kept suspects
  kept="$(jq '.entries | length' "$out_file")"
  suspects="$(jq '.suspect_hosts | length' "$out_file")"
  log "$cluster: ${kept} protected image reference(s) for this registry"
  ((suspects == 0)) || warn "$cluster: ${suspects} image(s) reference a host resembling the registry but absent from registry.host_aliases; they are NOT protected"

  return 0
}

# Combines the per-cluster files into protection-set.json and enforces fail-closed.
discover_merge() {
  local work_dir="$1"
  local in_dir="${work_dir}/protection"
  local out_file="${work_dir}/protection-set.json"

  compgen -G "${in_dir}/*.json" >/dev/null \
    || fail "no per-cluster discovery output found in ${in_dir}"

  local configured_required
  configured_required="$(config_get_json \
    '[.in_use_protection.clusters[] | select(.required == true) | .name]')"

  jq -s \
    --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg registry "$(config_get '.registry.name')" \
    --argjson hosts "$(_dk8s_registry_hosts)" \
    '{
       generated_at: $generated_at,
       registry: $registry,
       registry_hosts: $hosts,
       clusters: [ .[] | { cluster, resource_group, required, status, error,
                           entry_count: (.entries | length) } ],
       protected_tags: [ .[].entries[] | select(has("tag"))
                         | { repository, tag } ] | unique,
       protected_digests: [ .[].entries[] | select(has("digest"))
                            | { repository, digest } ] | unique,
       sources: [ .[].entries[] ],
       suspect_hosts: [ .[].suspect_hosts[] ] | unique,
       unlisted_clusters: [ .[].unlisted_clusters[] ] | unique
     }' "${in_dir}"/*.json > "$out_file"

  local missing
  missing="$(jq -r --argjson required "$configured_required" '
      [ $required[] as $name
        | select([ .clusters[] | select(.cluster == $name and .status == "ok") ] | length == 0)
        | $name ] | join(", ")
    ' "$out_file")"
  [[ -z "$missing" ]] \
    || fail "aborting before any mutation: required cluster(s) not successfully discovered: $missing"

  local tag_count digest_count
  tag_count="$(jq '.protected_tags | length' "$out_file")"
  digest_count="$(jq '.protected_digests | length' "$out_file")"

  # An empty protection set means every image looks deletable. Never proceed.
  (((tag_count + digest_count) > 0)) \
    || fail "aborting before any mutation: the protection set is empty, which would make every image look deletable"

  local unlisted
  unlisted="$(jq -r '[.unlisted_clusters[].name] | join(", ")' "$out_file")"
  [[ -z "$unlisted" ]] \
    || warn "clusters present in Azure but missing from in_use_protection.clusters: ${unlisted}. Their running images are NOT protected"

  local suspects
  suspects="$(jq -r '[.suspect_hosts[].host] | unique | join(", ")' "$out_file")"
  [[ -z "$suspects" ]] \
    || warn "image hosts resembling the registry but absent from registry.host_aliases: ${suspects}"

  log "protection set: ${tag_count} tag(s), ${digest_count} digest(s) across $(jq '.clusters | length' "$out_file") cluster(s) -> $out_file"
}

# Walks every configured cluster in this process, then merges.
discover_all() {
  local work_dir="$1" only_cluster="${2:-}"
  local count index failed=0
  count="$(config_get '.in_use_protection.clusters | length')"

  for ((index = 0; index < count; index++)); do
    local name
    name="$(config_get ".in_use_protection.clusters[$index].name")"
    if [[ -n "$only_cluster" && "$name" != "$only_cluster" ]]; then
      continue
    fi
    discover_cluster "$work_dir" "$index" || failed=1
  done

  ((failed == 0)) || fail "aborting before any mutation: one or more required clusters could not be read"

  [[ -n "$only_cluster" ]] && return 0
  discover_merge "$work_dir"
}
