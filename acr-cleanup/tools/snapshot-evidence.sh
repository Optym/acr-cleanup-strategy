#!/usr/bin/env bash
#
# Captures the evidence of one run as a small, git-friendly folder: a Markdown
# summary with the numbers a reviewer or a demo needs, plus the report files.
# Run it after every phase so before/after can be shown side by side.
#
#   tools/snapshot-evidence.sh <work-dir> <out-dir> [label]
#
# Copies result.json, report.html, timings.json and config.json. Does NOT copy
# inventory.json, plan.json or decisions.jsonl (hundreds of MB); those stay in
# the pipeline artifact.

set -euo pipefail

work_dir="${1:?work dir}"
out_dir="${2:?output dir}"
label="${3:-$(date -u +%Y-%m-%d)}"

for f in result.json report.html; do
  [[ -s "${work_dir}/${f}" ]] || { printf 'missing or empty: %s\n' "${work_dir}/${f}" >&2; exit 1; }
done

mkdir -p "$out_dir"
cp "${work_dir}/result.json" "${work_dir}/report.html" "$out_dir/"
[[ -f "${work_dir}/timings.json" ]] && cp "${work_dir}/timings.json" "$out_dir/"
[[ -f "${work_dir}/config.json" ]] && cp "${work_dir}/config.json" "$out_dir/"

R="${out_dir}/result.json"
P="${work_dir}/plan.json"

gib() { awk -v b="${1:-0}" 'BEGIN { printf "%.1f GiB", b / 1073741824 }'; }
n() { printf '%s' "$1" | awk '{ printf "%\047d", $1 }'; }

{
  echo "# Evidence: ${label}"
  echo
  echo "Registry \`$(jq -r .run.registry "$R")\`, operation \`$(jq -r .run.operation "$R")\`, dry run \`$(jq -r .run.dry_run "$R")\`, status \`$(jq -r .run.status "$R")\`, generated $(jq -r .run.generated_at "$R")."
  echo "Config hash \`$(jq -r .run.config_hash "$R" | cut -c1-12)\`. Pipeline: $(jq -r '.run.pipeline.url // "local run"' "$R" | sed 's/^$/local run/')."
  echo
  echo "## Registry"
  echo
  echo "| | Tags | Manifests | Untagged manifests | Locked tags | Storage |"
  echo "| --- | ---: | ---: | ---: | ---: | ---: |"
  echo "| before | $(n "$(jq .registry.before.tags "$R")") | $(n "$(jq .registry.before.manifests "$R")") | $(n "$(jq .registry.before.untagged_manifests "$R")") | $(n "$(jq .registry.before.locked_tags "$R")") | $(jq -r '.registry.before.bytes // "n/a"' "$R" | { read -r b; [[ "$b" == "n/a" ]] && echo n/a || gib "$b"; }) |"
  echo "| after | $(n "$(jq .registry.after.tags "$R")") | $(n "$(jq .registry.after.manifests "$R")") | | | $(jq -r '.registry.after.bytes // "n/a"' "$R" | { read -r b; [[ "$b" == "n/a" ]] && echo n/a || gib "$b"; }) |"
  if [[ "$(jq '.registry.delta_vs_previous' "$R")" != "null" ]]; then
    echo "| delta vs previous run | $(jq .registry.delta_vs_previous.tags "$R") | $(jq .registry.delta_vs_previous.manifests "$R") | | | |"
  fi
  echo
  echo "## Protection set (what is running or one rollback away)"
  echo
  echo "$(n "$(jq .protection.tags "$R")") protected tags and $(n "$(jq .protection.digests "$R")") protected digests across $(jq '.protection.clusters | length' "$R") clusters, keeping $(jq .protection.keep_helm_revisions "$R") Helm revisions per release."
  echo
  echo "| Cluster | Status | Required | Protected references |"
  echo "| --- | --- | --- | ---: |"
  jq -r '.protection.clusters[] | "| \(.cluster) | \(.status) | \(.required) | \(.entry_count) |"' "$R"
  echo
  echo "## What the classifier decided"
  echo
  echo "| Reason | Tags |"
  echo "| --- | ---: |"
  jq -r '.skipped.tags_by_reason | to_entries | map(select(.key != "candidate")) | sort_by(-.value)[] | "| \(.key) | \(.value) |"' "$R"
  echo "| **candidate (untag)** | $(n "$(jq .candidates.untag "$R")") |"
  echo
  echo "| Tag group | Tags | Untag candidates |"
  echo "| --- | ---: | ---: |"
  jq -r '.skipped.tags_by_group as $g | .candidates.untag_by_group as $c | $g | to_entries | sort_by(-.value)[] | "| \(.key) | \(.value) | \($c[.key] // 0) |"' "$R"
  echo
  echo "Untagged manifests: $(n "$(jq .candidates.manifests "$R")") sweep candidates, $(gib "$(jq .candidates.manifest_bytes "$R")") of manifest size."
  echo
  echo "| Manifest reason | Count |"
  echo "| --- | ---: |"
  jq -r '.skipped.manifests_by_reason | to_entries | sort_by(-.value)[] | "| \(.key) | \(.value) |"' "$R"
  echo
  echo "## Deployed images are protected, not deleted"
  echo
  echo "Oldest protected tags (these are old enough to be candidates by age, and are kept because a cluster runs them):"
  echo
  echo "| Repository | Tag | Age (days) | Protected by |"
  echo "| --- | --- | ---: | --- |"
  jq -r '.skipped.samples.protected[0:15][] | "| \(.repository) | \(.tag) | \(.age_days) | \(.detail) |"' "$R"
  echo
  echo "## What would be deleted: oldest candidates"
  echo
  echo "| Repository | Tag | Group | Age (days) |"
  echo "| --- | --- | --- | ---: |"
  if [[ -f "$P" ]]; then
    jq -r '.untag[0:15][] | "| \(.repository) | \(.tag) | \(.tag_group) | \(.age_days) |"' "$P"
  fi
  echo
  echo "## Never-deleted repositories (reported, not cleaned)"
  echo
  echo "| Repository | Reason | Tags | Manifests |"
  echo "| --- | --- | ---: | ---: |"
  jq -r '.repositories[] | select(.never_delete) | "| \(.repository) | \(.never_delete_reason) | \(.tags_before) | \(.manifests_before) |"' "$R"
  echo
  echo "## Per repository"
  echo
  echo "| Repository | Tags | Protected | Locked | Untag candidates | Sweep candidates |"
  echo "| --- | ---: | ---: | ---: | ---: | ---: |"
  jq -r '.repositories[] | select(.never_delete | not) | "| \(.repository) | \(.tags_before) | \(.protected_tags) | \(.locked_tags) | \(.untag_candidates) | \(.manifest_candidates) |"' "$R"
  echo
  echo "## Locks"
  echo
  if [[ "$(jq .locks.ran "$R")" == "true" ]]; then
    jq -r '.locks.totals | "held (protected) \(.held // 0), pinned \(.pinned // 0), waiting \(.waiting // 0), orphan \(.orphan // 0), unlocked \((.unlocked // 0) + (."unlock-dry-run" // 0)), failed \(."unlock-failed" // 0)"' "$R"
  else
    echo "Lock reconciliation did not run in this operation. Locked tags in the inventory: $(n "$(jq .registry.before.locked_tags "$R")")."
  fi
  echo
  echo "## Stage timings"
  echo
  echo "| Stage | Status | Seconds | Detail |"
  echo "| --- | --- | ---: | --- |"
  jq -r '.run.stages[] | "| \(.stage) | \(.status) | \(.seconds) | \(.detail) |"' "$R"
  echo
  if [[ "$(jq '.warnings | length' "$R")" != "0" ]]; then
    echo "## Warnings"
    echo
    jq -r '.warnings[] | "- \(.)"' "$R"
    echo
  fi
  echo "Files: [report.html](./report.html), [result.json](./result.json)."
} > "${out_dir}/summary.md"

printf 'evidence written to %s\n' "$out_dir" >&2
