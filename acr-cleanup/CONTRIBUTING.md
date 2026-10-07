# Contributing: how the module is put together

Written so that a person, or a small model, can make a targeted change without reading everything.
Read the section for the file you need to touch, run its test suite, done.

## 1. The shape of the code

```
acr-cleanup.sh          orchestrator: parses flags, loads config, calls the stages in order
lib/common.sh           log/warn/fail (stderr), require_tool, stage_begin/stage_end, human_bytes
lib/config.sh           YAML -> JSON, defaults, overrides, validation. Exposes config_get / config_get_json
lib/discover-k8s.sh     stage 1: clusters -> protection/<cluster>.json -> protection-set.json
lib/acr-api.sh          stage 2 + the ACR HTTP client used by stages 4, 5 and the deploy lock
lib/classify.sh         stage 3: inventory + protection set -> plan.json + decisions.jsonl
lib/lock-reconcile.sh   stage 4: plan.locks + previous lock-ledger.json -> unlocks, lock-result.json
lib/execute.sh          stage 5: plan.untag / plan.manifests -> delete-result.json
tools/audit-running-images.sh  stage 6, opt-in (--validate-after): protection-set.json -> validation-result.json
lib/report.sh           stage 7: everything -> result.json, report-summary.html,
                        report-deleted.html, report-protected.html
lib/notify-sendgrid.sh  stage 7: result + html -> email
deploy/lock-deployed-images.sh   standalone; sources lib/ and locks what a Helm release deployed
tests/<name>.test.sh    one suite per lib file, same name
```

Rules that hold everywhere:

- **stdout is data, stderr is logs.** Never `echo` progress to stdout inside a function whose output
  is captured.
- **Every stage reads and writes JSON files in the work dir** and nothing else. A stage can be
  re-run alone against the files of the previous one.
- **jq does the data work, bash does the plumbing.** Loops over hundreds of thousands of items belong
  in one jq program, not in a bash `while read`.
- **Large data goes through files** (`--slurpfile`, `--rawfile`), never `--argjson` or `<<<`; both hit
  `ARG_MAX` at a few hundred KB.
- **No `$( )` around a function that caches state** (token cache, counters): command substitution
  runs in a subshell and the cache write is lost. Such functions set a global instead.
- **Fail closed.** Anything that cannot be read is treated as "do not delete", never as "nothing
  to protect".
- **Reason strings are an API.** The report, the tests and the docs use them; add new ones, do not
  rename old ones.

## 2. Where to change what

| I want to… | Edit | Then run |
| --- | --- | --- |
| Add or change a cleanup rule, retention, never-delete entry, cluster | `config/myproduct.yaml` only | `./acr-cleanup.sh --config … --operation validate-config` |
| Add a config option | `_config_defaults` + `_config_validate` in `lib/config.sh`; `CONFIGURATION.md`; read it with `config_get` where used | `tests/config.test.sh` |
| Change how a tag is judged (order of checks, a new skip reason) | the `if/elif` chain in `_CLASSIFY_JQ` in `lib/classify.sh`; add the reason to the README §9 list | `tests/classify.test.sh` |
| Change which manifests are swept | the `base_reason` block in `_CLASSIFY_JQ` | `tests/classify.test.sh` |
| Read another Kubernetes kind | `_dk8s_kinds_to_read` in `lib/discover-k8s.sh` | `tests/discover-k8s.test.sh` |
| Handle a changed ACR response field | the jq in `acr_inventory_repository` (`lib/acr-api.sh`) | `tests/acr-api.test.sh` |
| Change retry / backoff / page size | `_acr_should_retry`, `_acr_backoff_seconds`, `ACR_PAGE_SIZE` | `tests/acr-api.test.sh` |
| Change the HTTP call itself (curl flags, timeouts) | `_acr_http` in `lib/acr-api.sh`; keep the exit code deciding the status, never append to curl's output | `tests/acr-api.test.sh` ("real transport" cases, fake curl) |
| Change how index / manifest-list children are resolved | `_acr_backfill_index_references` (the fan-out) and `_acr_resolve_index_references` (one lookup) in `lib/acr-api.sh`; concurrency is `run_settings.parallel_reference_lookups` | `tests/acr-api.test.sh` ("parallel index resolution" cases) |
| Change what happens on Ctrl+C / pipeline cancel | `_on_interrupt` in `lib/common.sh`; it signals descendants only, never the process group | `tests/acr-cleanup.test.sh` (interrupt case) |
| Change what execute does per item | `_execute_worker` in `lib/execute.sh` | `tests/execute.test.sh` |
| Change unlock criteria | the `status:` expression in `lock_reconcile_run` | `tests/lock-reconcile.test.sh` |
| Add a report section or column | `report_run` (JSON) then the right one of `_report_html_summary` / `_report_html_deleted` / `_report_html_protected` (HTML, sharing `_REPORT_JQ_DEFS` / `_REPORT_CSS`) in `lib/report.sh` | `tests/report.test.sh`, then `KEEP_REPORT=<dir> bash tests/report.test.sh` and open `<dir>/report-{summary,deleted,protected}.html` |
| Change what the opt-in post-cleanup validation checks | `tools/audit-running-images.sh` (the check itself, and its `--out-json` shape); the "4. Post-cleanup validation" section in `_report_html_protected` renders whatever `--out-json` writes | manual: `tools/audit-running-images.sh --config … --out-json /tmp/v.json` then `acr-cleanup.sh … --validate-after` |
| Change the email | `notify_sendgrid_run` | `tests/report.test.sh` (notify cases are there) |
| Change the pipeline | `build/Maintenance/acr-cleanup-template.yaml`; keep the wrapper thin | `python3 -c 'import yaml; yaml.safe_load(open(f))'`, then a manual `plan` run |
| Add a stage | a new `lib/<stage>.sh` exposing `<stage>_run <work-dir> …`, sourced and called from `acr-cleanup.sh` between `stage_begin` / `stage_end`; a test suite; a row in README §3 | all suites |

## 3. Data contracts between stages

Only these fields are relied on downstream. Anything else in a file is informational.

**protection-set.json** (stage 1 → 3, 6)
`protected_tags[] {repository, tag}`, `protected_digests[] {repository, digest}`,
`sources[] {repository, tag|digest, cluster, namespace, source: pod|workload|helm-history, detail}`
(`namespace` is `""` only for a cluster-scoped reference that has no owning namespace; every pod,
workload and Helm release entry carries its real one),
`clusters[] {cluster, status, required, entry_count, error}`, `suspect_hosts[]`, `unlisted_clusters[]`.

**inventory.json** (stage 2 → 3)
`repositories[] {repository, tags[] {name, digest, created, modified, write_enabled, delete_enabled},
manifests[] {digest, tags[], created, modified, size, media_type, references[], write_enabled,
delete_enabled}}`, `totals`.

**plan.json** (stage 3 → 4, 5, 6)
`totals`, `protection {tags, digests, clusters}`, `repositories[]`, `untag[] {repository, tag,
digest, tag_group, age_days, size}`, `manifests[] {repository, digest, age_days, size}`,
`skipped_samples {reason: []}`, `skipped_manifest_samples`, `locked_stale {tags, manifests}` (how
much of the lock backlog is already past retention),
`locks {tags[] {repository, tag, digest, protected, protection[], never_unlock, would_delete},
manifests[] {…, would_sweep}}`, `dry_run`, `max_deletions_per_run`. `would_delete` / `would_sweep`
are computed ignoring both protection and the lock — "would the age/count rules alone call this a
candidate" — and are what let `lock-reconcile.sh` unlock a stale orphan without waiting.
**decisions.jsonl**: one `{kind, repository, tag|digest, tag_group, reason, detail, would_delete}`
(tags) or `{kind, repository, digest, tags, reason, would_sweep}` (manifests) per line.

**lock-result.json** (stage 4 → 6) `totals {…, not_protected, unlocked_immediately,
unlocked_after_wait}`, `held[]`, `pinned[]`, `waiting[]`, `orphan[]`, `unlocked[]` (each carrying
`unlock_basis: already_past_retention|wait_elapsed`), `failed[]`, `errors[]`.
`totals.orphan` is the per-status count (items only when `unlock_when_unused.enabled` is false);
`totals.not_protected` is the broader "not held, not pinned" count regardless of resolution — do
not conflate the two when adding a field that reads `.totals`.
**lock-ledger.json** (stage 4 → next run's stage 4) `entries[] {kind, repository, ref,
first_unprotected_at}` — only for items that are waiting on the ledger-tracked clock; an
immediately-unlocked item never enters it. Carried automatically into `--previous-dir` by the
orchestrator at the end of every run (`carry_forward_to_previous` in `lib/common.sh`), so a local
rerun of the same `--work-dir` needs no extra flag.

**delete-result.json** (stage 5 → 6) `operation`, `totals`, `items[] {…, status, http_status}`,
`failed[]`. Statuses: `untagged`, `deleted`, `already-gone`, `failed`, `dry-run`,
`skipped:over-cap`, `skipped:changed-since-plan`.

**validation-result.json** (stage 6, opt-in → 7) written only when `--validate-after` was passed;
absent otherwise. `{ generated_at, skip_discover, totals: {checked, ok, broken, unreadable},
items[] }` — `items` holds only the non-`ok` lines from `tools/audit-running-images.sh`'s stdout
(`{status: BROKEN|UNREADABLE, repository, tag?, digest?, clusters, reason?, missing_children?}`);
an `ok` item is only ever counted, never listed, since a clean run can have thousands.

**result.json** (stage 7 → 8, next run's stage 7) see `report_run`; the next run reads only
`run.generated_at`, `run.operation`, `registry.after`. Also carried automatically into
`--previous-dir` after every run, same as the lock ledger. `summary` is the flat set of headline
numbers the report's executive-summary cards are built from — extend it rather than re-deriving a
headline number from the detailed sections in a second place. `protection.deployments[]`
(`{cluster, namespace, repository, deployed[], protected_previous[]}`) is grouped from
protection-set.json's `sources[]` by `[cluster, namespace, repository]`: `deployed` comes from
`source: pod|workload`, `protected_previous` from `source: helm-history` minus whatever is already
`deployed`. `validation` is `null` unless `--validate-after` was used, in which case it is
validation-result.json verbatim.

An `untag-and-sweep` run executes twice (stage 5 runs once per mode) and the untag half's output is
saved as `delete-result.untag.json` before the sweep overwrites `delete-result.json` — `report.sh`
reads both. Every mutated item is a tag item (has a `tag` key) or a manifest item (never does); that
presence check is the discriminator used throughout `report.sh` instead of a single "which operation
is this" string, because the CLI operation name, the stage-5 mode token, and a combined run's
"which half produced this file" are three different things that must not be conflated.

## 4. How a test suite is built

Each suite is a plain bash script:

```bash
source lib/common.sh; source lib/config.sh; source lib/<file>.sh   # the code under test
pass / fail_test / check_equals                                     # three tiny helpers
config_init --file <fixture yaml> --work-dir <tmp>                  # a minimal valid config
acr_untag() { …record the call…; }                                  # stub the boundary
( <stage>_run "$WORK" ) >/dev/null 2>&1                              # subshell: a fail must not kill the suite
check_equals "label" "expected" "$(jq … output.json)"               # assert on the files it wrote
```

To add a case: copy the nearest `check_equals`, change the label, expected value and jq path. To
stub a new boundary: define a function with the same name after sourcing; the code calls the stub.
Stubs that must report back from a subshell write to a file (see `CALLS` in `execute.test.sh`).

Run one suite with `bash tests/<name>.test.sh`; a failing case prints `FAIL <label> (expected …, got …)`.

## 5. Conventions for AI-assisted changes

- Start from the table in section 2; open only the file it names and its test suite.
- Keep the change inside one function where possible; the stage boundaries are the seams.
- Add a test case for the new behaviour before changing the code, then make it pass.
- Do not rename reason strings, file names in the work dir, or config keys; they are referenced by
  the docs, the pipeline and the report.
- Update the matching document: option → `CONFIGURATION.md`, behaviour → `README.md`, operator
  action → `RUNBOOK.md`, dependency → `MAINTENANCE.md`.
