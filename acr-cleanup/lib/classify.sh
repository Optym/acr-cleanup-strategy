#!/usr/bin/env bash
#
# Stage 3 - classify every tag and manifest in the inventory.
#
#   reads   <work-dir>/inventory.json, <work-dir>/protection-set.json, config
#   writes  <work-dir>/plan.json
#   mutates nothing
#
# Selection order for a tag: never_delete -> cleanup rule -> protection set ->
# lock -> always_keep_newest -> delete_when_older_than_days. The first check
# that keeps the tag is recorded as its reason, so the report can answer "why
# was my image (not) deleted" with the most useful answer: a deployed image is
# reported as protected even if it is also young.
#
# Every tag also carries would_delete: whether the age/count rules ALONE (never
# mind protection or lock) already call it a candidate. This is what lets the
# lock reconciler unlock an orphaned, already-stale image immediately instead
# of waiting out wait_days_before_unlocking from scratch - see
# lib/lock-reconcile.sh. Manifests carry the equivalent would_sweep.
#
# A tag matching no rule is never a candidate. That is the safe default for
# unknown, legacy or hand-pushed tags.
#
# Manifests are classified for the sweep (--operation manifests): only untagged
# manifests that are not protected by digest, not locked, not referenced by a
# retained manifest list, and untagged for at least
# in_use_protection.min_untagged_manifest_age_days are candidates.
#
# Classification runs one repository at a time. A single jq program over 386k
# tags would work, but per-repository runs keep memory bounded at the size of
# the largest repository (~10k tags) instead of the whole registry.

# shellcheck shell=bash

# Patterns are validated as POSIX ERE (grep -E) at config load, but classified
# here with jq's regex engine. Both accept the subset the config allows, and
# config load also asserts every example tag under jq, so the two cannot drift
# on the tags that matter.
readonly _CLASSIFY_JQ='
  def parse_time:
    if . == null or . == "" then null
    else (sub("\\.[0-9]+"; "") | sub("Z$"; "") + "Z" | try fromdateiso8601 catch null)
    end;

  def age_days($t):
    if $t == null then null else (($now - $t) / 86400 | floor) end;

  def is_locked:
    (.delete_enabled == false) or (.write_enabled == false);

  def first_rule($name):
    first($rules[] | select(. as $r | $name | test($r.tag_pattern))) // null;

  def never_delete_pattern($name):
    first($never_patterns[] | select(. as $p | $name | test($p.pattern))) // null;

  def never_unlock_pattern($name):
    first($never_unlock_patterns[] | select(. as $p | $name | test($p.pattern))) // null;

  # Sources are normalised into human-readable reasons once, then looked up by key.
  def protection_of($key; $index):
    $index[$key] // [];

  . as $repo
  | $repo.repository as $name
  | ($never_repos[$name] // null) as $nd_repo
  | ($never_unlock_repos[$name] // null) as $nu_repo
  | ($repo.manifests | map({ key: .digest, value: . }) | from_entries) as $by_digest

  # ---- tags ---------------------------------------------------------------
  | ($repo.tags
     | map(
         (.modified // .created | parse_time) as $t
         | first_rule(.name) as $rule
         | . + {
             modified_epoch: $t,
             age_days: age_days($t),
             tag_group: ($rule.tag_group // null),
             rule: $rule,
             locked: is_locked,
             size: ($by_digest[.digest].size // 0),
             tag_protection: protection_of($name + "\t" + .name; $ptags),
             digest_protection: protection_of($name + "\t" + .digest; $pdigests)
           }
       )
     # rank within (repository, tag group), newest first, for always_keep_newest
     | group_by(.tag_group)
     | map(sort_by(.modified_epoch // 0) | reverse | to_entries | map(.value + { rank: .key }))
     | add // []
     | map(
         . as $tag
         | never_delete_pattern($tag.name) as $ndp
         # Cross-repository protection (in_use_protection.protect_tag_across_repositories):
         # a shared monorepo build tag can be protected for the repos of one module
         # and completely absent from the repos of another module, purely because
         # the second module is not enabled for any currently-running or
         # Helm-tracked release. When enabled, a tag name protected ANYWHERE is
         # treated as protected in EVERY repository that has a tag of that name.
         | ($cross_protect and (($all_tag_names // []) | index($tag.name)) != null) as $has_cross_protection
         # Age/count alone, ignoring both protection and lock: the signal the
         # lock reconciler needs to unlock a stale orphan without waiting.
         | (
             $tag.rule != null
             and $nd_repo == null
             and $ndp == null
             and (($filter | length) == 0 or (($filter | index($tag.tag_group)) != null))
             and $tag.rank >= $tag.rule.always_keep_newest
             and $tag.age_days != null
             and $tag.age_days >= $tag.rule.delete_when_older_than_days
           ) as $would_delete
         | (
             if $nd_repo != null then
               { reason: "never-delete:repository", detail: $nd_repo.reason }
             elif $ndp != null then
               { reason: "never-delete:pattern", detail: $ndp.pattern }
             elif $tag.rule == null then
               { reason: "no-matching-rule", detail: "" }
             elif ($filter | length) > 0 and (($filter | index($tag.tag_group)) == null) then
               { reason: "not-in-scope", detail: ("run limited to " + ($filter | join(","))) }
             elif ($tag.tag_protection | length) > 0 then
               { reason: "protected", detail: ($tag.tag_protection | join(" ")) }
             elif ($tag.digest_protection | length) > 0 then
               { reason: "protected", detail: ("by digest: " + ($tag.digest_protection | join(" "))) }
             elif $has_cross_protection then
               { reason: "protected", detail: "protected:cross-module-tag" }
             elif $tag.locked then
               { reason: "locked", detail: "" }
             elif $tag.rank < $tag.rule.always_keep_newest then
               { reason: "always-keep-newest", detail: ("newest " + ($tag.rule.always_keep_newest | tostring)) }
             elif $tag.age_days == null then
               { reason: "no-timestamp", detail: "" }
             elif $tag.age_days < $tag.rule.delete_when_older_than_days then
               { reason: "within-retention", detail: (($tag.rule.delete_when_older_than_days | tostring) + " days") }
             else
               { reason: "candidate", detail: "" }
             end
           ) as $decision
         | {
             repository: $name,
             tag: $tag.name,
             digest: $tag.digest,
             tag_group: $tag.tag_group,
             age_days: $tag.age_days,
             modified: $tag.modified,
             size: $tag.size,
             locked: $tag.locked,
             protected: ((($tag.tag_protection + $tag.digest_protection) | length > 0) or $has_cross_protection),
             protection: (
               ($tag.tag_protection + $tag.digest_protection
                 + (if $has_cross_protection then ["protected:cross-module-tag"] else [] end))
               | unique
             ),
             never_unlock: (
               $nu_repo != null or (never_unlock_pattern($tag.name) != null)
               or $nd_repo != null or (never_delete_pattern($tag.name) != null)
             ),
             would_delete: $would_delete,
             reason: $decision.reason,
             detail: $decision.detail
           }
       )
    ) as $tags

  # ---- manifests ----------------------------------------------------------
  | ($repo.manifests
     | map(
         (.modified // .created | parse_time) as $t
         | . + {
             age_days: age_days($t),
             locked: is_locked,
             digest_protection: protection_of($name + "\t" + .digest; $pdigests),
             # tags protect their manifest, whatever the tag decision was - including
             # cross-repository protection, so a tagged manifest reports "protected"
             # consistently with what its own tags decided above.
             tag_protection: (
               [ .tags[] as $tg
                 | ( ($ptags[$name + "\t" + $tg] // [])[]
                     , (if ($cross_protect and (($all_tag_names // []) | index($tg)))
                        then "protected:cross-module-tag" else empty end)
                   )
               ] | unique
             )
           }
         | . + {
             # Independent of the lock: would this untagged manifest already be
             # swept on its own age, ignoring only whether it happens to be locked?
             would_sweep: (
               (.tags | length) == 0
               and $nd_repo == null
               and (.digest_protection | length) == 0
               and .age_days != null
               and .age_days >= $min_untagged_age
             ),
             base_reason: (
               if (.tags | length) > 0 then "tagged"
               elif $nd_repo != null then "never-delete:repository"
               elif (.digest_protection | length) > 0 then "protected"
               elif .locked then "locked"
               elif .age_days == null then "no-timestamp"
               elif .age_days < $min_untagged_age then "within-recovery-window"
               else "candidate"
               end
             )
           }
       )
    ) as $manifests_pass1

  # Children of any manifest that stays are protected too: a multi-arch index
  # lists its per-platform images as untagged manifests, and deleting one of
  # them corrupts the index.
  | ([ $manifests_pass1[] | select(.base_reason != "candidate") | .references[]? ] | unique) as $kept_children
  | ($manifests_pass1
     | map(
         . as $m
         | (
             if $m.base_reason == "candidate" and (($kept_children | index($m.digest)) != null)
             then "referenced-by-parent"
             else $m.base_reason
             end
           ) as $reason
         | {
             repository: $name,
             digest: $m.digest,
             tags: $m.tags,
             age_days: $m.age_days,
             modified: $m.modified,
             size: $m.size,
             media_type: $m.media_type,
             locked: $m.locked,
             protected: (($m.digest_protection + $m.tag_protection) | length > 0),
             protection: (($m.digest_protection + $m.tag_protection) | unique),
             never_unlock: ($nu_repo != null or $nd_repo != null),
             would_sweep: $m.would_sweep,
             reason: $reason
           }
       )
    ) as $manifests

  | {
      repository: $name,
      never_delete: ($nd_repo != null),
      never_delete_reason: ($nd_repo.reason // ""),
      tags: $tags,
      manifests: $manifests
    }
'

# Turns protection-set.json sources into two lookup objects keyed
# "repository<TAB>tag" and "repository<TAB>digest", each holding a unique list of
# human-readable protection reasons. Also emits the distinct set of protected tag
# NAMES (repository-independent), which feeds cross-repository tag protection -
# see in_use_protection.protect_tag_across_repositories in classify_run below.
_classify_protection_index() {
  local protection_file="$1"
  jq -c '
    def reason:
      if .source == "helm-history" then "protected:helm-history"
      else "protected:cluster=" + .cluster
      end;
    def index_by(f):
      map(select(f != null) | { key: (.repository + "\t" + f), value: reason })
      | group_by(.key)
      | map({ key: .[0].key, value: (map(.value) | unique) })
      | from_entries;
    {
      tags:    (.sources | index_by(.tag)),
      digests: (.sources | index_by(.digest)),
      tag_names: ([ .sources[] | select(.tag != null) | .tag ] | unique)
    }
  ' "$protection_file"
}

# classify_run <work-dir> [tag_groups_csv] [repositories_csv]
# With a repository list, only those repositories are classified; the others are
# left out of the plan entirely (a targeted cleanup, not a skip reason).
classify_run() {
  local work_dir="$1" tag_groups="${2:-}" repositories="${3:-}"
  local inventory_file="${work_dir}/inventory.json"
  local protection_file="${work_dir}/protection-set.json"
  local out_file="${work_dir}/plan.json"

  [[ -f "$inventory_file" ]]  || fail "classify: ${inventory_file} not found; run --operation inventory first"
  [[ -f "$protection_file" ]] || fail "classify: ${protection_file} not found; run --operation discover first"

  local protected_count
  protected_count="$(jq '(.protected_tags | length) + (.protected_digests | length)' "$protection_file")"
  ((protected_count > 0)) \
    || fail "classify: the protection set is empty, refusing to plan against it"

  local index_file per_repo_file filter_json now
  index_file="$(mktemp)"
  per_repo_file="$(mktemp)"
  now="$(date -u +%s)"
  filter_json="$(jq -cn --arg g "$tag_groups" '$g | split(",") | map(select(. != ""))')"

  _classify_protection_index "$protection_file" > "$index_file"

  # Split the inventory once into one line per repository. Indexing into the
  # 350 MB inventory.json per repository would re-parse it 61 times.
  local repos_file repo_filter
  repos_file="$(mktemp)"
  repo_filter="$(jq -cn --arg r "$repositories" '$r | split(",") | map(select(. != ""))')"
  jq -c --argjson only "$repo_filter" \
    '.repositories[] | .repository as $name | select(($only | length) == 0 or (($only | index($name)) != null))' \
    "$inventory_file" > "$repos_file"

  if [[ -n "$repositories" ]]; then
    local missing
    missing="$(jq -rn --argjson want "$repo_filter" \
      --argjson have "$(jq -c '[.repositories[].repository]' "$inventory_file")" \
      '[ $want[] | . as $w | select(($have | index($w)) == null) ] | join(", ")')"
    [[ -z "$missing" ]] || fail "classify: --repositories not present in the inventory: ${missing} (re-run inventory without --skip-inventory)"
    log "classify: limited to repositories: ${repositories}"
  fi

  local repo_count
  repo_count="$(wc -l < "$repos_file" | tr -d ' ')"
  log "classifying ${repo_count} repositor$([[ "$repo_count" == "1" ]] && printf 'y' || printf 'ies') against $(jq '.tags | length' "$index_file") protected tag(s) and $(jq '.digests | length' "$index_file") protected digest(s)"

  local index=0 repo_line
  while IFS= read -r repo_line; do
    index=$((index + 1))
    printf '%s' "$repo_line" \
      | jq -c \
          --argjson now "$now" \
          --argjson filter "$filter_json" \
          --argjson rules "$(config_get_json '.image_cleanup_rules')" \
          --argjson never_repos "$(config_get_json '.never_delete.repositories | map({ key: .name, value: . }) | from_entries')" \
          --argjson never_patterns "$(config_get_json '.never_delete.tag_patterns')" \
          --argjson never_unlock_repos "$(config_get_json '.image_lock.unlock_when_unused.never_unlock.repositories | map({ key: .name, value: . }) | from_entries')" \
          --argjson never_unlock_patterns "$(config_get_json '.image_lock.unlock_when_unused.never_unlock.tag_patterns')" \
          --argjson min_untagged_age "$(config_get '.in_use_protection.min_untagged_manifest_age_days')" \
          --argjson cross_protect "$(config_get '.in_use_protection.protect_tag_across_repositories')" \
          --slurpfile idx "$index_file" \
          '($idx[0].tags) as $ptags | ($idx[0].digests) as $pdigests | ($idx[0].tag_names // []) as $all_tag_names | '"$_CLASSIFY_JQ" \
      >> "$per_repo_file" \
      || { rm -f "$index_file" "$per_repo_file" "$repos_file"; fail "classify: repository $index failed"; }
    log "classified [${index}/${repo_count}] $(jq -r '.repository + ": " + (.tags | length | tostring) + " tag(s)"' <<<"$(tail -n1 "$per_repo_file" | jq -c '{repository, tags: (.tags | length)}')")"
  done < "$repos_file"
  rm -f "$repos_file"

  # Every tag and manifest decision, one line each. This is the audit trail behind
  # the report's samples: grep -F '"tag":"5.6.0-alpha.133"' decisions.jsonl
  jq -c '(.tags[] | { kind: "tag", repository, tag, digest, tag_group, age_days, would_delete, reason, detail }),
         (.manifests[] | { kind: "manifest", repository, digest, tags, age_days, would_sweep, reason })' \
    "$per_repo_file" > "${work_dir}/decisions.jsonl"

  jq -s \
    --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg registry "$(config_get '.registry.name')" \
    --arg config_hash "$(config_hash)" \
    --argjson now "$now" \
    --argjson filter "$filter_json" \
    --argjson dry_run "$(config_get '.run_settings.dry_run')" \
    --argjson max_deletions "$(config_get '.run_settings.max_deletions_per_run')" \
    --argjson min_untagged_age "$(config_get '.in_use_protection.min_untagged_manifest_age_days')" \
    --argjson sample "${CLASSIFY_SAMPLE_ROWS:-50}" \
    --argjson repo_filter "$repo_filter" \
    --slurpfile inventory "$inventory_file" \
    --slurpfile protection "$protection_file" \
    '
      def count_by(f): group_by(f) | map({ key: (.[0] | f), value: length }) | from_entries;

      . as $repos
      | ([ $repos[].tags[] ]) as $all_tags
      | ([ $repos[].manifests[] ]) as $all_manifests
      | ([ $all_tags[] | select(.reason == "candidate") ] | sort_by(-.age_days)) as $untag
      | ([ $all_manifests[] | select(.reason == "candidate") ] | sort_by(-.age_days)) as $sweep
      | {
          generated_at: $generated_at,
          registry: $registry,
          config_hash: $config_hash,
          now: $now,
          dry_run: $dry_run,
          max_deletions_per_run: $max_deletions,
          min_untagged_manifest_age_days: $min_untagged_age,
          tag_groups: $filter,
          repositories_filter: $repo_filter,
          inventory_generated_at: $inventory[0].generated_at,
          protection_generated_at: $protection[0].generated_at,
          protection: {
            tags: ($protection[0].protected_tags | length),
            digests: ($protection[0].protected_digests | length),
            clusters: $protection[0].clusters
          },
          totals: {
            repositories: ($repos | length),
            tags: ($all_tags | length),
            manifests: ($all_manifests | length),
            untagged_manifests: ([ $all_manifests[] | select((.tags | length) == 0) ] | length),
            locked_tags: ([ $all_tags[] | select(.locked) ] | length),
            locked_manifests: ([ $all_manifests[] | select(.locked) ] | length),
            untag_candidates: ($untag | length),
            # Several tags usually share one manifest; count each digest once.
            untag_candidate_bytes: ([ $untag[] | { digest, size } ] | unique_by(.digest) | map(.size) | add // 0),
            manifest_candidates: ($sweep | length),
            manifest_candidate_bytes: ([ $sweep[].size ] | add // 0),
            tags_by_reason: ($all_tags | count_by(.reason)),
            tags_by_group: ($all_tags | map(.tag_group // "no-matching-rule") | count_by(.)),
            candidates_by_group: ($untag | map(.tag_group) | count_by(.)),
            manifests_by_reason: ($all_manifests | count_by(.reason))
          },
          repositories: [
            $repos[]
            | {
                repository,
                never_delete,
                never_delete_reason,
                tags: (.tags | length),
                manifests: (.manifests | length),
                untagged_manifests: ([ .manifests[] | select((.tags | length) == 0) ] | length),
                locked_tags: ([ .tags[] | select(.locked) ] | length),
                protected_tags: ([ .tags[] | select(.protected) ] | length),
                untag_candidates: ([ .tags[] | select(.reason == "candidate") ] | length),
                manifest_candidates: ([ .manifests[] | select(.reason == "candidate") ] | length),
                manifest_candidate_bytes: ([ .manifests[] | select(.reason == "candidate") | .size ] | add // 0),
                tags_by_reason: (.tags | count_by(.reason)),
                tags_by_group: (.tags | map(.tag_group // "no-matching-rule") | count_by(.)),
                candidates_by_group: ([ .tags[] | select(.reason == "candidate") | .tag_group ] | count_by(.))
              }
          ],
          untag: [ $untag[] | { repository, tag, digest, tag_group, age_days, modified, size } ],
          manifests: [ $sweep[] | { repository, digest, age_days, modified, size, media_type } ],
          # Oldest N per reason. The full per-tag decision list is decisions.jsonl,
          # one JSON object per line, so it can be grepped and streamed without
          # loading 388k objects into jq.
          skipped_samples: (
            $all_tags | map(select(.reason != "candidate"))
            | group_by(.reason)
            | map({ key: .[0].reason, value: (sort_by(-(.age_days // 0)) | .[0:$sample] | map({ repository, tag, digest, tag_group, age_days, detail })) })
            | from_entries
          ),
          skipped_manifest_samples: (
            $all_manifests | map(select(.reason != "candidate" and .reason != "tagged"))
            | group_by(.reason)
            | map({ key: .[0].reason, value: (.[0:$sample] | map({ repository, digest, age_days, reason })) })
            | from_entries
          ),
          # Every locked item with its protection status. lock-reconcile.sh works from
          # this list; the report shows it as held / orphan / pinned.
          locks: {
            tags: [ $all_tags[] | select(.locked)
                    | { repository, tag, digest, age_days, protected, protection, never_unlock, would_delete } ],
            manifests: [ $all_manifests[] | select(.locked)
                         | { repository, digest, tags, age_days, protected, protection, never_unlock, would_sweep } ]
          },
          # How much of the current lock backlog is already stale (age/count says
          # delete) versus still young. Purely informational, for the report.
          locked_stale: {
            tags: ([ $all_tags[] | select(.locked and (.protected | not) and .would_delete) ] | length),
            manifests: ([ $all_manifests[] | select(.locked and (.protected | not) and .would_sweep) ] | length)
          }
        }
    ' "$per_repo_file" > "$out_file"

  rm -f "$index_file" "$per_repo_file"

  log "plan: full decision list -> ${work_dir}/decisions.jsonl ($(wc -l < "${work_dir}/decisions.jsonl" | tr -d ' ') lines)"
  log "plan: $(jq -r '.totals | "\(.tags) tag(s): \(.untag_candidates) untag candidate(s); \(.untagged_manifests) untagged manifest(s): \(.manifest_candidates) sweep candidate(s) (~\(.manifest_candidate_bytes / 1073741824 | floor) GiB); \(.locked_tags) locked tag(s)"' "$out_file") -> ${out_file}"
  log "plan: tags by reason: $(jq -c '.totals.tags_by_reason' "$out_file")"
}
