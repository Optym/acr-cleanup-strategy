#!/usr/bin/env bash
#
# Stage 6 - the report.
#
#   reads   config, protection-set.json, inventory.json, plan.json, and when
#           present lock-result.json, delete-result.json,
#           delete-result.untag.json (the untag half of an untag-and-sweep
#           run), <previous-dir>/result.json
#   writes  <work-dir>/result.json, <work-dir>/report-summary.html,
#           report-deleted.html, report-protected.html
#   mutates nothing
#
# The report is always produced, even when a mutating stage failed: the
# orchestrator records stage errors in <work-dir>/errors.jsonl and this stage
# folds them in. result.json is the single machine-readable record and the
# recovery catalogue (every deleted item with its digest); the three HTML
# files are the same data for humans, split by audience: report-summary.html
# (stats, an executive summary, and the opt-in post-cleanup validation
# status), report-deleted.html (what was/would be deleted and why),
# report-protected.html (what is protected - cluster/namespace/deployed
# version detail, plus the full opt-in validation table when --validate-after
# was used).
#
# result.json is kept to a size that can be diffed and emailed. The full
# per-tag decision list lives in plan.json and decisions.jsonl, published
# alongside it.

# shellcheck shell=bash

REPORT_SAMPLE_ROWS="${REPORT_SAMPLE_ROWS:-50}"
REPORT_MAX_TABLE_ROWS="${REPORT_MAX_TABLE_ROWS:-2000}"

# Appends one stage error. Called by the orchestrator, so failures in stages 4
# and 5 reach the report instead of ending the run.
report_record_error() {
  local work_dir="$1" stage="$2" message="$3"
  jq -nc --arg stage "$stage" --arg message "$message" \
    --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{ stage: $stage, message: $message, at: $at }' >> "${work_dir}/errors.jsonl"
}

_report_optional_json() {
  # Prints the file's JSON, or null when absent / unreadable.
  local file="$1"
  if [[ -f "$file" ]] && jq -e '.' "$file" >/dev/null 2>&1; then
    cat "$file"
  else
    printf 'null'
  fi
}

# report_run <work-dir> <operation> [previous-dir] [started-epoch] [usage-before-bytes] [usage-after-bytes]
report_run() {
  local work_dir="$1" operation="$2" previous_dir="${3:-${1}/previous}"
  local started="${4:-$(date -u +%s)}" usage_before="${5:-}" usage_after="${6:-}"
  local out_json="${work_dir}/result.json"
  local out_html_summary="${work_dir}/report-summary.html"
  local out_html_deleted="${work_dir}/report-deleted.html"
  local out_html_protected="${work_dir}/report-protected.html"

  [[ -f "${work_dir}/plan.json" ]] || fail "report: ${work_dir}/plan.json not found"

  local errors_file="${work_dir}/errors.jsonl"
  [[ -f "$errors_file" ]] || : > "$errors_file"

  local config_file
  config_file="$(config_path)"

  # Every large or optional input goes through a file: --argjson puts the value
  # on the command line, and a 2 MB protection set already exceeds ARG_MAX.
  local tmp_dir protection_slim locks_file deletes_file deletes_untag_file previous_file timings_file errors_slim validation_file
  tmp_dir="$(mktemp -d)"
  protection_slim="${tmp_dir}/protection.json"
  locks_file="${tmp_dir}/locks.json"
  deletes_file="${tmp_dir}/deletes.json"
  deletes_untag_file="${tmp_dir}/deletes-untag.json"
  previous_file="${tmp_dir}/previous.json"
  timings_file="${tmp_dir}/timings.json"
  errors_slim="${tmp_dir}/errors.json"
  validation_file="${tmp_dir}/validation.json"

  _report_optional_json "${work_dir}/protection-set.json" \
    | jq -c 'if . == null then null else { unlisted_clusters, suspect_hosts, sources: (.sources // []) } end' > "$protection_slim"
  _report_optional_json "${work_dir}/lock-result.json" > "$locks_file"
  _report_optional_json "${work_dir}/delete-result.json" > "$deletes_file"
  # untag-and-sweep runs execute twice; the untag half is saved under this name
  # before the sweep overwrites delete-result.json (see acr-cleanup.sh). Reading
  # both here, rather than trusting a single "which operation is this" string,
  # is what makes the before/after numbers correct for that combined run.
  _report_optional_json "${work_dir}/delete-result.untag.json" > "$deletes_untag_file"
  _report_optional_json "${previous_dir}/result.json" \
    | jq -c 'if . == null then null else { generated_at: .run.generated_at, operation: .run.operation, registry: .registry.after } end' > "$previous_file"
  _report_optional_json "${work_dir}/timings.json" > "$timings_file"
  _report_optional_json "${work_dir}/validation-result.json" > "$validation_file"
  jq -c -s '.' "$errors_file" > "$errors_slim" 2>/dev/null || printf '[]' > "$errors_slim"

  if ! jq -n \
    --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg operation "$operation" \
    --argjson started "$started" \
    --argjson now "$(date -u +%s)" \
    --arg config_hash "$(config_hash)" \
    --arg usage_before "$usage_before" \
    --arg usage_after "$usage_after" \
    --arg build_id "${BUILD_BUILDID:-}" \
    --arg build_url "${SYSTEM_TEAMFOUNDATIONCOLLECTIONURI:-}${SYSTEM_TEAMPROJECT:-}${BUILD_BUILDID:+/_build/results?buildId=}${BUILD_BUILDID:-}" \
    --arg branch "${BUILD_SOURCEBRANCHNAME:-}" \
    --argjson sample "$REPORT_SAMPLE_ROWS" \
    --slurpfile config "$config_file" \
    --slurpfile plan "${work_dir}/plan.json" \
    --slurpfile protection_in "$protection_slim" \
    --slurpfile locks_in "$locks_file" \
    --slurpfile deletes_in "$deletes_file" \
    --slurpfile deletes_untag_in "$deletes_untag_file" \
    --slurpfile previous_in "$previous_file" \
    --slurpfile timings_in "$timings_file" \
    --slurpfile errors "$errors_slim" \
    --slurpfile validation_in "$validation_file" \
    '
      # Optional inputs arrive as one-element arrays holding null when absent.
      ($protection_in[0]) as $protection
      | ($locks_in[0]) as $locks
      | ($deletes_in[0]) as $deletes
      | ($deletes_untag_in[0]) as $deletes_untag
      | ($previous_in[0]) as $previous
      | ($timings_in[0]) as $timings
      | ($errors[0]) as $errors
      | ($validation_in[0]) as $validation
      |
      def num($s): if ($s | type) == "string" and ($s | test("^[0-9]+$")) then ($s | tonumber) else null end;
      def count_by(f): group_by(f) | map({ key: (.[0] | f), value: length }) | from_entries;
      def sample: .[0:$sample];

      $plan[0] as $plan
      | $config[0] as $cfg

      # Every mutated item, from whichever of the up-to-two execute passes ran
      # this invocation. An untag item always carries a "tag" key; a manifest
      # item never does - that is the discriminator used everywhere below
      # instead of trusting a single operation-name string, which is what let
      # a combined untag-and-sweep run silently under-report one half of
      # itself.
      | ([ (($deletes.items // [])[]), (($deletes_untag.items // [])[]) ]) as $items
      | ($items | map(select(.status == "untagged" or .status == "deleted"))) as $done
      | ($done | map(select(has("tag")))) as $done_tags
      | ($done | map(select(has("tag") | not))) as $done_manifests
      | ($done_tags | group_by(.repository) | map({ key: .[0].repository, value: length }) | from_entries) as $untag_count_by_repo
      | ($done_manifests | group_by(.repository) | map({ key: .[0].repository, value: length }) | from_entries) as $sweep_count_by_repo
      | ($done_tags | group_by(.repository) | map({ key: .[0].repository, value: (map(.size // 0) | add) }) | from_entries) as $untag_bytes_by_repo
      | ($done_manifests | group_by(.repository) | map({ key: .[0].repository, value: (map(.size // 0) | add) }) | from_entries) as $sweep_bytes_by_repo

      | ($errors | length > 0 or (($deletes.totals.failed // 0) > 0) or (($deletes_untag.totals.failed // 0) > 0) or (($locks.errors // []) | length > 0)) as $failed
      | (num($usage_before)) as $bytes_before
      | (num($usage_after)) as $bytes_after
      | ($plan.totals.tags) as $tags_before
      | ($plan.totals.manifests) as $manifests_before
      | ($tags_before - ($done_tags | length)) as $tags_after
      | ($manifests_before - ($done_manifests | length)) as $manifests_after

      # Warnings computed once, up front, so both the flat list and the
      # executive-summary count agree by construction instead of by upkeep.
      | (
          [ ($plan.protection.clusters // [])[] | select(.status != "ok") | "cluster \(.cluster) unreachable (required=\(.required)): \(.error // "")" ]
          + [ ($protection.unlisted_clusters // [])[] | "cluster \(.name) exists in Azure but is not in in_use_protection.clusters" ]
          + [ ($protection.suspect_hosts // [])[] | "host \(.host) resembles the registry but is not in registry.host_aliases" ]
          + [ ($locks.failed // [])[] | "could not unlock \(.kind) \(.repository):\(.ref)" ]
          + (if (($deletes.totals.over_cap // 0) + ($deletes_untag.totals.over_cap // 0)) > 0
             then [ "\((($deletes.totals.over_cap // 0) + ($deletes_untag.totals.over_cap // 0))) candidate(s) deferred by max_deletions_per_run" ]
             else [] end)
        ) as $warnings

      # Cluster/namespace/repository view of the protection set: for each
      # combination, what is currently deployed (a running pod or a workload
      # template) versus what is only retained as a Helm rollback target. A
      # version that is both (the latest revision matches the running one) is
      # "deployed", not double-counted as also "previous".
      | (($protection.sources // [])
          | group_by([.cluster, (.namespace // ""), .repository])
          | map(
              (map(select(.source == "pod" or .source == "workload") | (.tag // ("digest:" + (.digest // "")))) | unique) as $deployed
              | {
                  cluster: .[0].cluster,
                  namespace: (.[0].namespace // ""),
                  repository: .[0].repository,
                  deployed: ($deployed | sort),
                  protected_previous: (
                    (map(select(.source == "helm-history") | (.tag // ("digest:" + (.digest // "")))) | unique)
                    - $deployed
                    | sort
                  )
                }
            )
          | sort_by([.cluster, .namespace, .repository])
        ) as $deployments

      | {
          run: {
            generated_at: $generated_at,
            registry: $plan.registry,
            operation: $operation,
            dry_run: $plan.dry_run,
            status: (if $failed then "failed" else "ok" end),
            started_at: ($started | todate),
            duration_seconds: ($now - $started),
            config_hash: $plan.config_hash,
            tag_groups: $plan.tag_groups,
            repositories_filter: ($plan.repositories_filter // []),
            max_deletions_per_run: $plan.max_deletions_per_run,
            min_untagged_manifest_age_days: $plan.min_untagged_manifest_age_days,
            pipeline: { build_id: $build_id, url: (if $build_id == "" then "" else $build_url end), branch: $branch },
            inventory_generated_at: $plan.inventory_generated_at,
            protection_generated_at: $plan.protection_generated_at,
            stages: ($timings.stages // [])
          },

          protection: {
            tags: $plan.protection.tags,
            digests: $plan.protection.digests,
            clusters: ($plan.protection.clusters // []),
            keep_helm_revisions: $cfg.in_use_protection.keep_helm_revisions,
            deployments: $deployments
          },

          registry: {
            before: { tags: $tags_before, manifests: $manifests_before, bytes: $bytes_before,
                      untagged_manifests: $plan.totals.untagged_manifests, locked_tags: $plan.totals.locked_tags },
            after:  { tags: $tags_after, manifests: $manifests_after, bytes: $bytes_after },
            previous: $previous,
            delta_vs_previous: (
              if $previous == null then null
              else {
                tags: ($tags_after - ($previous.registry.tags // $tags_after)),
                manifests: ($manifests_after - ($previous.registry.manifests // $manifests_after)),
                bytes: (if $bytes_after == null or $previous.registry.bytes == null then null
                        else $bytes_after - $previous.registry.bytes end)
              }
              end
            )
          },

          repositories: [
            $plan.repositories[]
            | . as $r
            | {
                repository,
                never_delete,
                never_delete_reason,
                tags_before: .tags,
                tags_after: (.tags - ($untag_count_by_repo[.repository] // 0)),
                manifests_before: .manifests,
                manifests_after: (.manifests - ($sweep_count_by_repo[.repository] // 0)),
                untagged_manifests,
                locked_tags,
                protected_tags,
                untag_candidates,
                manifest_candidates,
                manifest_candidate_bytes,
                untagged: ($untag_count_by_repo[.repository] // 0),
                swept: ($sweep_count_by_repo[.repository] // 0),
                deleted: (($untag_count_by_repo[.repository] // 0) + ($sweep_count_by_repo[.repository] // 0)),
                deleted_bytes: (($untag_bytes_by_repo[.repository] // 0) + ($sweep_bytes_by_repo[.repository] // 0)),
                retained: (.tags - ($untag_count_by_repo[.repository] // 0)),
                tags_by_group,
                candidates_by_group,
                tags_by_reason
              }
          ],

          deleted: {
            count: ($done | length),
            untagged: ($done_tags | length),
            swept: ($done_manifests | length),
            bytes: ([ $done[].size // 0 ] | add // 0),
            items: [ $done[] | { repository, tag: (.tag // null), digest, tag_group: (.tag_group // null), age_days, size, status } ]
          },

          # Present only when at least one execute pass actually ran. Absent
          # for validate-config / discover / inventory / plan, which never
          # reach stage 5.
          execution: (
            if $deletes == null and $deletes_untag == null then null
            else {
              dry_run: ($deletes.dry_run // $deletes_untag.dry_run),
              duration_seconds: (($deletes.duration_seconds // 0) + ($deletes_untag.duration_seconds // 0)),
              failed: (($deletes.failed // []) + ($deletes_untag.failed // [])),
              over_cap: (($deletes.totals.over_cap // 0) + ($deletes_untag.totals.over_cap // 0)),
              totals: {
                planned: (($deletes.totals.planned // 0) + ($deletes_untag.totals.planned // 0)),
                succeeded: ($done | length),
                failed: (($deletes.totals.failed // 0) + ($deletes_untag.totals.failed // 0)),
                dry_run: (($deletes.totals.dry_run // 0) + ($deletes_untag.totals.dry_run // 0)),
                bytes: ([ $done[].size // 0 ] | add // 0)
              },
              dry_run_items: [ $items[] | select(.status == "dry-run") | { repository, tag: (.tag // null), digest, tag_group: (.tag_group // null), age_days, size } ]
            }
            end
          ),

          # A bare "plan" run never reaches stage 5, so there is no execution
          # snapshot of what would happen - it has to come straight from the
          # candidate lists classify.sh already computed. Without this, section
          # 6 of the report always read as empty on a plan-only run, which
          # defeated the point of running one.
          preview: (
            if $deletes == null and $deletes_untag == null then
              { untag: ($plan.untag // []), manifests: ($plan.manifests // []) }
            else null
            end
          ),

          candidates: {
            untag: $plan.totals.untag_candidates,
            untag_by_group: $plan.totals.candidates_by_group,
            untag_bytes: $plan.totals.untag_candidate_bytes,
            manifests: $plan.totals.manifest_candidates,
            manifest_bytes: $plan.totals.manifest_candidate_bytes
          },

          skipped: {
            tags_by_reason: $plan.totals.tags_by_reason,
            tags_by_group: $plan.totals.tags_by_group,
            manifests_by_reason: $plan.totals.manifests_by_reason,
            samples: ($plan.skipped_samples | with_entries(.value |= sample)),
            manifest_samples: ($plan.skipped_manifest_samples | with_entries(.value |= sample))
          },

          locks: (
            if $locks == null then
              { enabled: $cfg.image_lock.unlock_when_unused.enabled, ran: false,
                held: $plan.totals.locked_tags,
                stale_backlog: ($plan.locked_stale // { tags: 0, manifests: 0 }),
                unlocked: [], waiting: [], orphan: [], pinned: [], failed: [] }
            else
              { enabled: $locks.enabled, ran: true, dry_run: $locks.dry_run,
                wait_days_before_unlocking: $locks.wait_days_before_unlocking,
                totals: $locks.totals,
                stale_backlog: ($plan.locked_stale // { tags: 0, manifests: 0 }),
                unlocked: $locks.unlocked, waiting: $locks.waiting, orphan: $locks.orphan,
                pinned: $locks.pinned, failed: $locks.failed, errors: $locks.errors }
            end
          ),

          cluster_warnings: {
            unreachable: [ ($plan.protection.clusters // [])[] | select(.status != "ok") ],
            unlisted_clusters: ($protection.unlisted_clusters // []),
            suspect_hosts: ($protection.suspect_hosts // [])
          },

          errors: $errors,
          warnings: $warnings,

          # Opt-in: null unless the orchestrator ran --validate-after, which
          # writes validation-result.json from tools/audit-running-images.sh.
          validation: $validation,

          # Headline numbers for the executive summary panel, and for anything
          # that wants the gist without walking the rest of the file.
          summary: {
            status: (if $failed then "failed" else "ok" end),
            dry_run: $plan.dry_run,
            operation: $operation,
            registry_tags_before: $tags_before,
            registry_tags_after: $tags_after,
            registry_manifests_before: $manifests_before,
            registry_manifests_after: $manifests_after,
            storage_before_bytes: $bytes_before,
            storage_after_bytes: $bytes_after,
            protected_tags: $plan.protection.tags,
            protected_digests: $plan.protection.digests,
            untag_candidates: $plan.totals.untag_candidates,
            sweep_candidates: $plan.totals.manifest_candidates,
            sweep_candidate_bytes: $plan.totals.manifest_candidate_bytes,
            deleted_count: ($done | length),
            deleted_bytes: ([ $done[].size // 0 ] | add // 0),
            locked_tags: $plan.totals.locked_tags,
            locked_stale_tags: ($plan.locked_stale.tags // 0),
            locked_stale_manifests: ($plan.locked_stale.manifests // 0),
            unlocked_this_run: (if $locks == null then 0 else (($locks.totals.unlocked // 0) + ($locks.totals["unlock-dry-run"] // 0)) end),
            error_count: ($errors | length),
            warning_count: ($warnings | length)
          }
        }
    ' > "$out_json"; then
    rm -rf "$tmp_dir"
    rm -f "$out_json"
    fail "report: could not build ${out_json}"
  fi
  rm -rf "$tmp_dir"

  _report_html_summary   "$out_json" > "$out_html_summary"   || fail "report: could not render ${out_html_summary}"
  _report_html_deleted   "$out_json" > "$out_html_deleted"   || fail "report: could not render ${out_html_deleted}"
  _report_html_protected "$out_json" > "$out_html_protected" || fail "report: could not render ${out_html_protected}"

  log "report: $(jq -r '.run | "\(.registry) \(.operation) dry_run=\(.dry_run) status=\(.status)"' "$out_json"), $(jq -r '.deleted.count' "$out_json") item(s) deleted -> ${out_json}, ${out_html_summary}, ${out_html_deleted}, ${out_html_protected}"
}

# Shared across all three report pages: jq helper defs (table/card/badge/...)
# and the CSS block, so the three files share one visual language without
# tripling either. $css and $max_rows are bound via --arg/--argjson in each
# _report_html_* function below; jq's nested defs close over them regardless
# of where in the program they are declared.
_REPORT_CSS='
  :root{--ink:#1a1d21;--muted:#6b7280;--line:#e2e5e9;--bg:#f7f8fa;--card:#ffffff;--accent:#1565c0;--ok:#1b7f4d;--bad:#c1272d;--warn:#a15c00;}
  body{font:14px/1.5 -apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;margin:0;color:var(--ink);background:var(--bg)}
  .wrap{max-width:1280px;margin:0 auto;padding:28px 32px 64px}
  header.top{background:linear-gradient(135deg,#0f2942,#173a5e);color:#fff;padding:28px 32px}
  header.top .wrap{padding:0;max-width:1280px}
  h1{font-size:22px;margin:0 0 4px}
  h1 .sub{font-weight:400;color:#c9d6e4;font-size:14px;display:block;margin-top:4px}
  h2{font-size:17px;margin:0 0 12px;padding-bottom:8px;border-bottom:2px solid var(--line)}
  h3{font-size:14px;margin:20px 0 8px;color:var(--ink)}
  section{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:20px 24px;margin-top:20px}
  .tablewrap{overflow-x:auto}
  table{border-collapse:collapse;margin:8px 0;font-size:13px;width:100%}
  th,td{border:1px solid var(--line);padding:6px 10px;text-align:left;vertical-align:top}
  th{background:#f0f2f5;font-weight:600}
  td{white-space:nowrap}
  td:last-child{white-space:normal}
  table.kv{width:auto}
  table.kv th{width:260px;background:transparent;border:none;color:var(--muted);font-weight:500}
  table.kv td{border:none}
  .muted{color:var(--muted)}
  .badge{padding:3px 10px;border-radius:12px;font-size:12px;color:#fff;font-weight:600;letter-spacing:.02em}
  .badge.ok{background:var(--ok)}
  .badge.bad{background:var(--bad)}
  .pill{display:inline-block;padding:2px 9px;border-radius:10px;font-size:12px;background:#eef1f5;color:var(--muted)}
  .warn{background:#fff8ec;border:1px solid #f2d49b;padding:10px 14px;border-radius:6px;margin-top:12px}
  .err{background:#fdecec;border:1px solid #f3b8b8;padding:10px 14px;border-radius:6px;margin-top:12px}
  code{background:#eef0f3;padding:1px 5px;border-radius:3px;font-size:12.5px}
  nav.toc{display:flex;flex-wrap:wrap;gap:6px 14px;font-size:13px;margin-top:14px}
  nav.toc a{color:#cfe0f2;text-decoration:none}
  nav.toc a:hover{text-decoration:underline}
  nav.pages a{padding:3px 10px;border-radius:12px;background:rgba(255,255,255,.14)}
  nav.pages a.cur{background:#fff;color:#173a5e;font-weight:700}
  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:14px;margin-top:20px}
  .card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:14px 16px}
  .card-label{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
  .card-value{font-size:26px;font-weight:700;margin-top:4px;color:var(--ink)}
  .card-sub{font-size:12.5px;color:var(--muted);margin-top:4px}
  .card.accent .card-value{color:var(--accent)}
  .card.good .card-value{color:var(--ok)}
  .card.bad .card-value{color:var(--bad)}
'

_REPORT_JQ_DEFS='
  def esc: tostring | @html;
  def gib: if . == null then "n/a" else ((. / 1073741824 * 100 | round) / 100 | tostring) + " GiB" end;
  def n: if . == null then "n/a" else tostring end;
  # Thousands separator for readability in a report meant for humans, not jq.
  # jq has no reverse for plain strings (array-only), hence explode/implode
  # bracketing every reversal below.
  def commas:
    if . == null then "n/a"
    elif type != "number" then tostring
    else
      (if . < 0 then "-" else "" end) as $sign
      | (. | fabs | floor | tostring) as $whole
      | ($whole | explode | reverse) as $rev
      | ([ $rev | _nwise(3) | implode ] | map(explode | reverse | implode)) as $chunks
      | $sign + ($chunks | reverse | join(","))
    end;
  def signed: if . == null then "n/a" elif . > 0 then "+" + commas elif . == 0 then "0" else commas end;
  def th: map("<th>" + esc + "</th>") | join("");
  def td: map("<td>" + (if type == "number" then commas else esc end) + "</td>") | join("");
  def table($headers; $rows):
    if ($rows | length) == 0 then "<p class=\"muted\">none</p>"
    else
      "<div class=\"tablewrap\"><table><thead><tr>" + ($headers | th) + "</tr></thead><tbody>"
      + ([ $rows[0:$max_rows][] | "<tr>" + td + "</tr>" ] | join(""))
      + "</tbody></table></div>"
      + (if ($rows | length) > $max_rows then "<p class=\"muted\">showing \($max_rows | commas) of \($rows | length | commas) rows; the full list is in result.json</p>" else "" end)
    end;
  def kv($obj): "<table class=\"kv\">" + ([ $obj | to_entries[] | "<tr><th>\(.key | esc)</th><td>\(.value | esc)</td></tr>" ] | join("")) + "</table>";
  def badge($ok): if $ok then "<span class=\"badge ok\">ok</span>" else "<span class=\"badge bad\">failed</span>" end;
  def section($n; $title; $anchor; $body): "<section id=\"\($anchor)\"><h2>\($n). \($title | esc)</h2>" + $body + "</section>";
  # A stat card for the executive summary: a label, a big value, and an
  # optional smaller sub-line (a delta, a percentage, a breakdown).
  def card($label; $value; $sub):
    "<div class=\"card\"><div class=\"card-label\">\($label | esc)</div><div class=\"card-value\">\($value)</div>"
    + (if $sub == "" or $sub == null then "" else "<div class=\"card-sub\">\($sub)</div>" end)
    + "</div>";
  def page_head($title):
    "<!doctype html><html><head><meta charset=\"utf-8\"><title>" + ($title | esc) + "</title><style>" + $css + "</style></head><body>";
  # Cross-links the three report files, bolding whichever one is current.
  def pages_nav($active):
    "<nav class=\"toc pages\">"
    + ([ {id:"summary",   href:"report-summary.html",   label:"Summary"},
         {id:"deleted",   href:"report-deleted.html",   label:"Deleted"},
         {id:"protected", href:"report-protected.html", label:"Protected"} ]
       | map("<a class=\"" + (if .id == $active then "cur" else "" end) + "\" href=\"" + .href + "\">" + .label + "</a>")
       | join(""))
    + "</nav>";
  def page_banner($active):
    "<header class=\"top\"><div class=\"wrap\">"
    + "<h1>ACR cleanup: \(.run.registry | esc)"
    + "<span class=\"sub\">\(.run.operation | esc)"
    + (if .run.dry_run then " &middot; dry run" else "" end)
    + " &middot; \(.run.generated_at | esc)</span></h1>"
    + badge(.run.status == "ok")
    + " <span class=\"pill\">\(.run.duration_seconds)s</span>"
    + (if (.run.repositories_filter | length) > 0 then " <span class=\"pill\">targeted: \(.run.repositories_filter | join(", ") | esc)</span>" else "" end)
    + pages_nav($active);
'

# result.json -> self-contained "stats" HTML on stdout: executive summary, run
# details, registry before/after, skipped reasons, locks, and a flat
# warnings/errors list. Cluster-by-cluster detail lives in the Protected page.
_report_html_summary() {
  local result_file="$1"
  jq -r \
    --argjson max_rows "$REPORT_MAX_TABLE_ROWS" \
    --arg css "$_REPORT_CSS" \
    "${_REPORT_JQ_DEFS}"'
      . as $r
      | ($r.summary // {}) as $sum
      | ($r.registry.delta_vs_previous) as $delta

      | page_head("ACR cleanup summary: \($r.run.registry) \($r.run.operation) \($r.run.generated_at)")
      + ($r | page_banner("summary"))
      + "<nav class=\"toc\">"
      + "<a href=\"#summary\">Executive summary</a><a href=\"#run\">1. Run details</a><a href=\"#registry\">2. Registry</a>"
      + "<a href=\"#skipped\">3. Skipped</a><a href=\"#locks\">4. Locks</a><a href=\"#warnings\">5. Warnings &amp; errors</a>"
      + "</nav></div></header>"

      + "<div class=\"wrap\">"

      # ---- executive summary --------------------------------------------
      + "<section id=\"summary\"><h2 style=\"border:none\">Executive summary</h2>"
      + "<p class=\"muted\">\(if $r.run.dry_run then "Dry run - nothing below was actually changed in the registry." else "A real run. Deletions below already happened." end) Generated \($r.run.generated_at | esc) in \($r.run.duration_seconds)s. Full detail: <a href=\"report-deleted.html\">Deleted</a>, <a href=\"report-protected.html\">Protected</a>.</p>"
      + "<div class=\"cards\">"
      + card("Registry status"; badge($r.run.status == "ok"); (if ($r.errors|length) > 0 then "\($r.errors|length) stage error(s)" else "no stage errors" end))
      + card("Tags"; "\($sum.registry_tags_after | commas)"; "was \($sum.registry_tags_before | commas)" + (if $delta != null then ", \($delta.tags | signed) vs previous run" else "" end))
      + card("Manifests"; "\($sum.registry_manifests_after | commas)"; "was \($sum.registry_manifests_before | commas)" + (if $delta != null and $delta.manifests != null then ", \($delta.manifests | signed) vs previous run" else "" end))
      + card("Storage"; ($sum.storage_after_bytes | gib); "was \($sum.storage_before_bytes | gib)" + (if $delta != null and $delta.bytes != null then ", \($delta.bytes | signed | if . == "n/a" then . else . + " B" end)" else "" end))
      + "<div class=\"card accent\">" + card("Protected (in use)"; "\(($sum.protected_tags + $sum.protected_digests) | commas)"; "\($sum.protected_tags | commas) by tag, \($sum.protected_digests | commas) by digest - never touched, see the Protected report") + "</div>"
      + card("Untag candidates"; "\($sum.untag_candidates | commas)"; "stale tags matching a cleanup rule")
      + card("Sweep candidates"; "\($sum.sweep_candidates | commas)"; "\($sum.sweep_candidate_bytes | gib) of untagged manifests past the recovery window")
      + "<div class=\"card \(if $sum.deleted_count > 0 then "good" else "" end)\">" + card((if $r.run.dry_run then "Would delete" else "Deleted this run" end); "\($sum.deleted_count | commas)"; "\($sum.deleted_bytes | gib)") + "</div>"
      + card("Locked images"; "\($sum.locked_tags | commas)"; "\($sum.locked_stale_tags | commas) already past retention, \($sum.unlocked_this_run | commas) unlocked this run")
      + "<div class=\"card \(if $sum.warning_count > 0 or $sum.error_count > 0 then "bad" else "good" end)\">" + card("Warnings / errors"; "\($sum.warning_count | commas) / \($sum.error_count | commas)"; "see section 5 for detail") + "</div>"
      + (if $r.validation != null then
           "<div class=\"card \(if ($r.validation.totals.broken // 0) == 0 and ($r.validation.totals.unreadable // 0) == 0 then "good" else "bad" end)\">"
           + card("Post-cleanup validation"; badge(($r.validation.totals.broken // 0) == 0 and ($r.validation.totals.unreadable // 0) == 0);
                  "\($r.validation.totals.ok | commas) intact, \($r.validation.totals.broken | commas) broken, \($r.validation.totals.unreadable | commas) unreadable - see the Protected report")
           + "</div>"
         else "" end)
      + "</div></section>"

      + (if ($r.errors | length) > 0 then
           "<div class=\"err\"><b>Errors</b><ul>" + ([ $r.errors[] | "<li>[\(.stage | esc)] \(.message | esc)</li>" ] | join("")) + "</ul></div>"
         else "" end)

      # ---- 1. run details -------------------------------------------------
      + section(1; "Run details"; "run";
          kv({
            "generated at": $r.run.generated_at, "started at": $r.run.started_at,
            "duration": "\($r.run.duration_seconds)s",
            "operation": $r.run.operation, "dry run": $r.run.dry_run,
            "tag groups": (if ($r.run.tag_groups | length) == 0 then "all" else ($r.run.tag_groups | join(", ")) end),
            "repositories": (if ($r.run.repositories_filter | length) == 0 then "all" else ($r.run.repositories_filter | join(", ")) end),
            "max deletions per run": $r.run.max_deletions_per_run,
            "min untagged manifest age (days)": $r.run.min_untagged_manifest_age_days,
            "config hash": $r.run.config_hash,
            "pipeline": (if $r.run.pipeline.url == "" then "local" else $r.run.pipeline.url end)
          })
          + (if ($r.run.stages | length) > 0 then
               "<h3>Stage timings</h3>" + table(["stage", "status", "seconds", "detail"]; [ $r.run.stages[] | [ .stage, (.status // "ok"), .seconds, (.detail // "") ] ])
             else "" end))

      # ---- 2. registry -------------------------------------------------
      + section(2; "Registry: before and after"; "registry";
          table(["", "tags", "manifests", "storage"];
                [ [ "before", $r.registry.before.tags, $r.registry.before.manifests, ($r.registry.before.bytes | gib) ],
                  [ "after",  $r.registry.after.tags,  $r.registry.after.manifests,  ($r.registry.after.bytes | gib) ] ]
                + (if $r.registry.previous == null then []
                   else [ [ "previous run (\($r.registry.previous.generated_at) \($r.registry.previous.operation))",
                            ($r.registry.previous.registry.tags | n), ($r.registry.previous.registry.manifests | n), ($r.registry.previous.registry.bytes | gib) ],
                          [ "delta vs previous", ($r.registry.delta_vs_previous.tags | signed), ($r.registry.delta_vs_previous.manifests | signed),
                            (if $r.registry.delta_vs_previous.bytes == null then "n/a" else ($r.registry.delta_vs_previous.bytes | gib) end) ] ]
                   end))
          + "<p class=\"muted\">untagged manifests before: \($r.registry.before.untagged_manifests | commas); locked tags: \($r.registry.before.locked_tags | commas). Untagging does not reclaim storage; only the manifest sweep does.</p>")

      # ---- 3. skipped -------------------------------------------------
      + section(3; "Skipped tags, by reason"; "skipped";
          "<p class=\"muted\">Reasons a tag was NOT touched. Candidates (the \($r.candidates.untag | commas) tags that ARE stale) are in the Deleted report, not here.</p>"
          + table(["reason", "tags"]; [ $r.skipped.tags_by_reason | to_entries[] | select(.key != "candidate") | [ .key, .value ] ])
          + table(["tag group", "tags", "untag candidates"];
                  [ $r.skipped.tags_by_group | to_entries[] | [ .key, .value, ($r.candidates.untag_by_group[.key] // 0) ] ])
          + "<p>Untagged manifests by reason (\"candidate\" = would be swept, see the Deleted report):</p>"
          + table(["reason", "manifests"]; [ $r.skipped.manifests_by_reason | to_entries[] | [ .key, .value ] ])
          + ([ $r.skipped.samples | to_entries[] | select(.key != "candidate")
               | "<h3>\(.key | esc) (oldest \(.value | length) shown)</h3>"
                 + table(["repository", "tag", "group", "age (days)", "detail"]; [ .value[] | [ .repository, .tag, (.tag_group // ""), .age_days, .detail ] ]) ]
             | join("")))

      # ---- 4. locks -------------------------------------------------
      + section(4; "Image locks"; "locks";
          (if $r.locks.ran | not then
             "<p class=\"muted\">Lock reconciliation did not run in this operation (it only runs for untag-stale-tags, sweep-untagged-manifests and untag-and-sweep). \($r.locks.held | commas) locked tag(s) are in the inventory, of which \($r.locks.stale_backlog.tags | commas) are already past their retention rule and will unlock the next time reconciliation runs.</p>"
           else
             kv({ "unlock_when_unused.enabled": $r.locks.enabled, "wait days before unlocking (for images not yet past retention)": $r.locks.wait_days_before_unlocking,
                  "held (currently in use)": ($r.locks.totals.held // 0), "pinned (never_unlock)": ($r.locks.totals.pinned // 0),
                  "not in use (total)": ($r.locks.totals.not_protected // 0),
                  "  - already past retention": ($r.locks.totals.unlocked_immediately // 0),
                  "  - unlocked after the wait": ($r.locks.totals.unlocked_after_wait // 0),
                  "  - still waiting": ($r.locks.totals.waiting // 0),
                  "  - unlock disabled in config": ($r.locks.totals.orphan // 0),
                  "unlocked this run": (($r.locks.totals.unlocked // 0) + ($r.locks.totals["unlock-dry-run"] // 0)),
                  "failed to unlock": ($r.locks.totals["unlock-failed"] // 0) })
             + "<p class=\"muted\">An unlock only removes this extra safety net; the item still has to clear the normal age and count rules before it is ever deleted, and only from the run AFTER this one.</p>"
             + "<h3>Unlocked this run (deletable from the next run onward)</h3>"
             + table(["kind", "repository", "ref", "why", "days unprotected", "status"];
                     [ $r.locks.unlocked[] | [ .kind, .repository, .ref, (if .unlock_basis == "already_past_retention" then "past retention" elif .unlock_basis == "wait_elapsed" then "wait elapsed" else "-" end), .days_unprotected, .status ] ])
             + "<h3>Still waiting (not yet past retention, wait not yet elapsed)</h3>"
             + table(["kind", "repository", "ref", "days unprotected", "age (days)"]; [ $r.locks.waiting[] | [ .kind, .repository, .ref, .days_unprotected, .age_days ] ])
             + (if ($r.locks.orphan | length) > 0 then
                  "<h3>Not in use, but unlocking is disabled in config</h3>"
                  + table(["kind", "repository", "ref", "days unprotected", "age (days)"]; [ $r.locks.orphan[] | [ .kind, .repository, .ref, .days_unprotected, .age_days ] ])
                else "" end)
             + "<h3>Pinned by never_unlock (never considered)</h3>"
             + table(["kind", "repository", "ref"]; [ $r.locks.pinned[] | [ .kind, .repository, .ref ] ])
           end))

      # ---- 5. warnings and errors (flat list; structured cluster detail is in the Protected report) ---
      + section(5; "Warnings and errors"; "warnings";
          (if ($r.errors | length) == 0 and ($r.warnings | length) == 0 then
             "<p class=\"muted\">none</p>"
           else
             table(["stage", "message", "at"]; [ $r.errors[] | [ .stage, .message, .at ] ])
             + table(["warning"]; [ $r.warnings[] | [ . ] ])
           end)
          + "<p class=\"muted\">Cluster-by-cluster detail (unreachable, unlisted, suspect hosts) is in the <a href=\"report-protected.html#cluster-warnings\">Protected report</a>.</p>")

      + "</div></body></html>"
    ' "$result_file"
}

# result.json -> self-contained "what was/would be deleted" HTML on stdout.
_report_html_deleted() {
  local result_file="$1"
  jq -r \
    --argjson max_rows "$REPORT_MAX_TABLE_ROWS" \
    --arg css "$_REPORT_CSS" \
    "${_REPORT_JQ_DEFS}"'
      . as $r

      | page_head("ACR cleanup deleted: \($r.run.registry) \($r.run.operation) \($r.run.generated_at)")
      + ($r | page_banner("deleted"))
      + "<nav class=\"toc\">"
      + "<a href=\"#repositories\">1. Repositories</a><a href=\"#never-deleted\">2. Never deleted</a><a href=\"#deleted\">3. Deleted</a>"
      + "</nav></div></header>"

      + "<div class=\"wrap\">"

      # ---- 1. repositories -------------------------------------------------
      + section(1; "Repositories"; "repositories";
          table(["repository", "tags before", "tags after", "untagged", "swept", "retained", "manifests", "untagged mf.", "locked", "protected", "untag candidates", "sweep candidates", "sweep GiB", "by group"];
                [ $r.repositories[] | select(.never_delete | not)
                  | [ .repository, .tags_before, .tags_after, .untagged, .swept, .retained, .manifests_before, .untagged_manifests, .locked_tags, .protected_tags,
                      .untag_candidates, .manifest_candidates, (.manifest_candidate_bytes | gib),
                      (.tags_by_group | to_entries | map("\(.key)=\(.value)") | join(" ")) ] ]))

      # ---- 2. never-deleted -------------------------------------------------
      + section(2; "Never-deleted repositories"; "never-deleted";
          "<p class=\"muted\">Excluded by <code>never_delete.repositories</code>; reported so growth here stays visible.</p>"
          + table(["repository", "reason", "tags", "manifests", "untagged", "locked"];
                  [ $r.repositories[] | select(.never_delete)
                    | [ .repository, .never_delete_reason, .tags_before, .manifests_before, .untagged_manifests, .locked_tags ] ]))

      # ---- 3. deleted / would-be-deleted -------------------------------------
      + section(3;
          (if $r.execution == null then "Would be deleted (plan preview)"
           elif $r.run.dry_run then "Would be deleted (dry run)"
           else "Deleted" end);
          "deleted";
          (
            if $r.execution == null then
              # A bare plan never executed anything; this is the classify stage
              # candidate list, uncapped, so it shows everything that qualifies.
              "<p>\($r.preview.untag | length | commas) untag candidate(s), \($r.preview.manifests | length | commas) sweep candidate(s). Nothing has run yet; re-run with <code>--operation untag-stale-tags</code> or <code>sweep-untagged-manifests</code> to act on this.</p>"
              + "<h3>Untag candidates</h3>"
              + table(["repository", "tag", "digest", "group", "age (days)", "size"];
                      [ $r.preview.untag[] | [ .repository, .tag, .digest, .tag_group, .age_days, ((.size // 0) | gib) ] ])
              + "<h3>Manifest sweep candidates</h3>"
              + table(["repository", "digest", "age (days)", "size"];
                      [ $r.preview.manifests[] | [ .repository, .digest, .age_days, ((.size // 0) | gib) ] ])
            elif $r.run.dry_run then
              "<p>\($r.execution.dry_run_items | length | commas) item(s), \(($r.execution.dry_run_items | map(.size // 0) | add // 0) | gib)</p>"
              + table(["repository", "tag", "digest", "group", "age (days)", "size"];
                      [ $r.execution.dry_run_items[] | [ .repository, (.tag // ""), .digest, (.tag_group // ""), .age_days, ((.size // 0) | gib) ] ])
            else
              "<p>\($r.deleted.count | commas) item(s) - \($r.deleted.untagged | commas) untagged, \($r.deleted.swept | commas) manifest(s) swept - \($r.deleted.bytes | gib). "
              + "Recover an untagged image with <code>az acr import -n \($r.run.registry) --source \($r.run.registry).azurecr.io/&lt;repo&gt;@&lt;digest&gt; -t &lt;repo&gt;:&lt;tag&gt;</code> while the manifest still exists; a swept manifest cannot be recovered.</p>"
              + table(["repository", "tag", "digest", "group", "age (days)", "size", "status"];
                      [ $r.deleted.items[] | [ .repository, (.tag // ""), .digest, (.tag_group // ""), .age_days, ((.size // 0) | gib), .status ] ])
            end
          )
          + (if ($r.execution.failed // [] | length) > 0 then
               "<h3>Failed</h3>" + table(["repository", "tag", "digest", "http"]; [ $r.execution.failed[] | [ .repository, (.tag // ""), .digest, .http_status ] ])
             else "" end))

      + "</div></body></html>"
    ' "$result_file"
}

# result.json -> self-contained "what is protected" HTML on stdout: totals and
# cluster reachability, the cluster/namespace/deployed-version breakdown, the
# structured cluster-warning tables, and (opt-in) the post-cleanup validation
# detail from tools/audit-running-images.sh.
_report_html_protected() {
  local result_file="$1"
  jq -r \
    --argjson max_rows "$REPORT_MAX_TABLE_ROWS" \
    --arg css "$_REPORT_CSS" \
    "${_REPORT_JQ_DEFS}"'
      . as $r

      | page_head("ACR cleanup protected: \($r.run.registry) \($r.run.operation) \($r.run.generated_at)")
      + ($r | page_banner("protected"))
      + "<nav class=\"toc\">"
      + "<a href=\"#protection\">1. Protection set</a><a href=\"#deployments\">2. Deployed &amp; protected versions</a>"
      + "<a href=\"#cluster-warnings\">3. Cluster warnings</a>"
      + (if $r.validation != null then "<a href=\"#validation\">4. Post-cleanup validation</a>" else "" end)
      + "</nav></div></header>"

      + "<div class=\"wrap\">"

      # ---- 1. protection ---------------------------------------------------
      + section(1; "Protection set"; "protection";
          "<p>\($r.protection.tags | commas) protected tag(s) and \($r.protection.digests | commas) protected digest(s), keeping \($r.protection.keep_helm_revisions) Helm revision(s) per release. These are never touched, regardless of age.</p>"
          + table(["cluster", "status", "required", "protected references", "error"];
                  [ $r.protection.clusters[] | [ .cluster, .status, .required, .entry_count, (.error // "") ] ]))

      # ---- 2. deployed & protected previous versions -----------------------
      + section(2; "Deployed versions and protected previous versions"; "deployments";
          "<p class=\"muted\">Per cluster and namespace: what is currently deployed (a running pod or a workload template) and which older version(s) are still protected only because they are a Helm rollback target.</p>"
          + table(["cluster", "namespace", "repository", "deployed version(s)", "protected previous version(s)"];
                  [ $r.protection.deployments[]
                    | [ .cluster, (if .namespace == "" then "(none)" else .namespace end), .repository,
                        (if (.deployed | length) == 0 then "-" else (.deployed | join(", ")) end),
                        (if (.protected_previous | length) == 0 then "-" else (.protected_previous | join(", ")) end) ] ]))

      # ---- 3. cluster warnings -------------------------------------------------
      + section(3; "Cluster warnings"; "cluster-warnings";
          "<h3>Unreachable clusters</h3>" + table(["cluster", "required", "error"]; [ $r.cluster_warnings.unreachable[] | [ .cluster, .required, (.error // "") ] ])
          + "<h3>Clusters in Azure but not in the config</h3>" + table(["cluster", "resource group", "location"]; [ $r.cluster_warnings.unlisted_clusters[] | [ .name, .resource_group, .location ] ])
          + "<h3>Hosts resembling the registry but not in host_aliases</h3>" + table(["host", "repository", "cluster"]; [ $r.cluster_warnings.suspect_hosts[] | [ .host, .repository, .cluster ] ]))

      # ---- 4. post-cleanup validation (opt-in, --validate-after) -----------
      + (if $r.validation != null then
           section(4; "Post-cleanup validation"; "validation";
             "<p class=\"muted\">tools/audit-running-images.sh, run with --skip-discover against the protection set this run already discovered. Generated \($r.validation.generated_at | esc).</p>"
             + kv({ "checked": $r.validation.totals.checked, "intact (ok)": $r.validation.totals.ok,
                    "broken": $r.validation.totals.broken, "unreadable": $r.validation.totals.unreadable })
             + (if ($r.validation.items | length) == 0 then
                  "<p class=\"muted\">no broken or unreadable images</p>"
                else
                  table(["status", "repository", "tag", "digest", "clusters", "reason"];
                        [ $r.validation.items[] | [ .status, .repository, (.tag // ""), (.digest // ""), (.clusters // ""), (.reason // .missing_children // "") ] ])
                end))
         else "" end)

      + "</div></body></html>"
    ' "$result_file"
}
