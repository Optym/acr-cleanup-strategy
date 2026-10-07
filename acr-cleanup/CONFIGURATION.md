# Configuration reference

Every option in `config/<product>.yaml`, with its default, the values it accepts, and what it changes.
The shipped MyProduct config is [config/myproduct.yaml](./config/myproduct.yaml); the annotated template
for a new product is [config/example.yaml](./config/example.yaml).

How the config is loaded (all in [lib/config.sh](./lib/config.sh)):

1. Built-in defaults (`_config_defaults`)
2. Your YAML file, merged on top. **Objects merge recursively; arrays replace.** Setting
   `image_cleanup_rules` replaces the whole list, it does not append.
3. `ACR_CLEANUP_SET` environment variable: comma-separated `path=value` overrides
4. `--set path=value` on the command line, repeatable, highest precedence

The effective config is written to `<work-dir>/config.json`, validated, and its SHA-256 recorded in
every report so a run can always be reproduced.

```bash
./acr-cleanup.sh --config config/myproduct.yaml --operation validate-config   # validate only
./acr-cleanup.sh --config config/myproduct.yaml --print-config | jq .         # show the effective config
```

## Override syntax

| Form | Example |
| --- | --- |
| Dotted path | `--set run_settings.parallel_delete_workers=8` |
| Rule by name (never by index) | `--set rule.pull_request_builds.delete_when_older_than_days=3` |
| Booleans and numbers are typed | `--set run_settings.dry_run=false` yields a real `false` |
| JSON for lists and objects | `--set 'never_delete.repositories=[{"name":"x","reason":"y"}]'` |
| Environment variable, comma separated | `ACR_CLEANUP_SET='run_settings.dry_run=false,rule.develop_builds.always_keep_newest=20'` |

## Regex rules

Patterns are matched with `grep -E` (POSIX ERE) at validation time and with jq's engine at
classification time. Use the common subset: `^ $ . * + ? | ( ) [ ] { }` and character classes such as
`[0-9]`, `[A-Za-z]`. PCRE shorthands (`\d`, `\w`, `\s`, `\b`, `(?...)`) are **rejected at load**
because they silently match nothing under ERE. Unanchored patterns load with a warning.

---

## `registry`

| Key | Default | Required | Meaning |
| --- | --- | --- | --- |
| `name` | — | yes | ACR name, e.g. `myregistry`. The login server is `<name>.azurecr.io` |
| `resource_group` | — | yes | Resource group of the registry. Used by `az acr show-usage` for storage numbers |
| `subscription_id` | — | yes | Subscription of the registry |
| `service_connection` | `""` | no | Informational: the ADO service connection the pipeline uses for the registry. The pipeline wrapper is where it actually takes effect |
| `host_aliases` | `[]` | no | Other hostnames that mean this registry when seen in a pod spec, e.g. `myregistry.westus2.data.azurecr.io`. Images under an unlisted lookalike host are reported as `suspect_hosts` and are **not** protected |

## `never_delete`

Repositories and tag patterns that are never cleaned but always reported.

| Key | Default | Meaning |
| --- | --- | --- |
| `repositories[]` | `[]` | `{ name, reason }` or a plain string. Every tag and manifest in the repository is skipped with reason `never-delete:repository` |
| `tag_patterns[]` | `[]` | `{ pattern, reason }` or a plain string. A matching tag is skipped with `never-delete:pattern`. Checked before the cleanup rules |

MyProduct keeps `^latest$`, plain `X.Y.Z`, `X.Y.Z-N` (setversion collision suffix) and `.*-donotdelete$`
(the engineers' escape hatch).

## `image_cleanup_rules[]`

The only tags that may ever be deleted. Ordered; **first match wins**; a tag matching no rule is never
deleted (`no-matching-rule`).

| Key | Required | Meaning |
| --- | --- | --- |
| `tag_group` | yes | Unique name. Used in reports, in `--tag-groups`, and in `--set rule.<tag_group>.<field>` |
| `tag_pattern` | yes | ERE matched against the tag name |
| `delete_when_older_than_days` | yes, `>= 0` | A tag younger than this (by its `lastUpdateTime`) is kept with `within-retention` |
| `always_keep_newest` | yes, `>= 0` | Within this repository and tag group, the newest N tags are kept with `always-keep-newest` regardless of age |
| `example_tags` | no | Real tags that must match this rule **and not** any earlier rule. Checked at load; this is the regression test for the rule order |

Age and count are **OR'd**: a tag survives if it is inside the newest N *or* younger than the age.
The count is a floor that stops a rarely built repository from being emptied by the age rule.

Ordering guidance: suffix-style markers (`-inUse$`) first, the broadest catch-all last.

## `in_use_protection`

| Key | Default | Range | Meaning |
| --- | --- | --- | --- |
| `keep_helm_revisions` | `3` | 1–50 | Helm revisions per release whose images are protected (rollback targets). MyProduct uses 5 |
| `min_untagged_manifest_age_days` | `14` | 7–365 | An untagged manifest is swept only after its `lastUpdateTime` is older than this. This is the recovery window; keep it at two run intervals or more. Below 14 warns |
| `cluster_access_mode` | `kubectl` | `kubectl`, `aks_run_command` | How clusters are read. `kubectl` needs network line of sight to the API server and is read-only. `aks_run_command` works through private endpoints but needs `runcommand/action`, which allows arbitrary in-cluster commands |
| `report_unlisted_clusters` | `true` | bool | Run `az aks list` per subscription and warn about clusters not in the list below. Reporting only; never blocks a run |
| `helm_parallelism` | `6` | 1–20 | Helm releases read concurrently during discovery. Lower it if the API server throttles |
| `protect_tag_across_repositories` | `false` | bool | When `true`, a tag name protected anywhere (by a live pod or Helm history, in any repository) is treated as protected in every repository that has a tag of the same name - see README.md, "Cross-repository tag protection". MyProduct sets this `true` because `dispatch` and `ibplanning` are separate Helm charts that share one build-pipeline tag stream; a tenant can enable a dormant module on its existing pinned version at any time |
| `clusters[]` | `[]`, at least one | | Every cluster that pulls from the registry, see below |

### `in_use_protection.clusters[]`

| Key | Required | Meaning |
| --- | --- | --- |
| `name` | yes | AKS cluster name |
| `resource_group` | yes | Its resource group |
| `service_connection` | yes | ADO service connection for its subscription. Informational in the script; the pipeline wrapper repeats it |
| `subscription_id` | no | Lets the script `az account set` before reading the cluster in a local multi-cluster run |
| `required` | `true` | `true`: an unreadable cluster aborts the run before any mutation. `false`: warn and continue (parked test clusters) |

## `image_lock`

### `image_lock.lock_at_deploy`

Read only by [deploy/lock-deployed-images.sh](./deploy/lock-deployed-images.sh) at release time.

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Lock deployed images at all |
| `environments.include[]` | `["PROD"]` | Case-insensitive substrings matched against the release environment name. Must be non-empty when enabled |
| `environments.exclude[]` | `["SEC"]` | Exclusions; exclude wins over include |

The lock sets `deleteEnabled: false` on the tag and on its manifest. `writeEnabled` is untouched.

### `image_lock.unlock_when_unused`

Read only by [lib/lock-reconcile.sh](./lib/lock-reconcile.sh) in the weekly run. The reconciler never
adds locks; it only removes locks from images that are no longer running anywhere and not in retained
Helm history, after a wait.

| Key | Default | Range | Meaning |
| --- | --- | --- | --- |
| `enabled` | `true` | bool | `false` reports orphan locks but unlocks nothing |
| `wait_days_before_unlocking` | `14` | 7–365 | Only applies to a locked item that is unprotected but still *young* by its own cleanup rule (inside `always_keep_newest` or `delete_when_older_than_days`). An item that is already old enough to be a delete candidate on its own unlocks immediately, no wait; see [README.md](./README.md#3-execution-flow). Tracked in `lock-ledger.json` |
| `never_unlock.repositories[]` | `[]` | | Same shape as `never_delete.repositories`; reported as `pinned` |
| `never_unlock.tag_patterns[]` | `[]` | | Same shape as `never_delete.tag_patterns` |

| `lock_at_deploy.enabled` | `unlock_when_unused.enabled` | Behaviour |
| --- | --- | --- |
| true | true | Default. Locks converge to what is deployed |
| true | false | Lock-only: locks accumulate forever (the old MyProduct failure). Warns at load |
| false | true | Unlock-only: drains a historical backlog without adding locks |
| false | false | No lock layer; existing locks are still reported |

## `run_settings`

| Key | Default | Range | Meaning |
| --- | --- | --- | --- |
| `dry_run` | `true` | bool | Plan and report, mutate nothing. Stages 4 and 5 log what they would do |
| `parallel_delete_workers` | `24` | 1–64 | Forked workers issuing untag / delete calls. Lower on HTTP 429 |
| `parallel_repo_jobs` | `6` | 1–20 | Repositories inventoried concurrently in a local run. In the pipeline the wrapper's `inventoryJobs` shards across jobs instead |
| `parallel_reference_lookups` | `8` | 1–32 | Per-digest lookups in flight per repository while inventory resolves the children of OCI indexes / manifest lists (the bulk listing never carries them). Total in-flight calls are this × `parallel_repo_jobs`. Lower on HTTP 429 |
| `max_deletions_per_run` | `20000` | 1–1,000,000 | Circuit breaker per execute stage. Candidates beyond it are reported as `skipped:over-cap`; oldest go first |

## `email_report`

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `false` | Send the report by email through SendGrid |
| `api_key_variable` | `SENDGRID_API_KEY` | Name of the environment variable holding the key. The key is never stored in config or logged |
| `from` | `""` | Sender. Required when enabled |
| `to[]` | `[]` | Recipients. Required when enabled |
| `attach_json` | `true` | Attach `result.json` (the recovery catalogue) to the email |

---

## Environment variables read by the scripts

| Variable | Default | Used by | Meaning |
| --- | --- | --- | --- |
| `ACR_CLEANUP_SET` | — | config | Comma-separated overrides, see above |
| `ACR_CLEANUP_LOG_SCOPE` | `acr-cleanup` | common | Log line prefix |
| `ACR_PAGE_SIZE` | `500` | acr-api | Page size for `_catalog`, `_tags`, `_manifests` |
| `ACR_MAX_RETRIES` | `5` | acr-api | Retries on 000/408/429/5xx |
| `ACR_REFRESH_TOKEN_TTL` | `7200` s | acr-api | Renew the ACR refresh token after this age (tokens live 3 h) |
| `ACR_ACCESS_TOKEN_TTL` | `1800` s | acr-api | Renew a per-scope access token after this age |
| `ACR_TRANSPORT_FN` | `_acr_http` | acr-api | Test hook: function that performs the HTTP call |
| `DK8S_REQUEST_TIMEOUT` | `90s` | discover | `kubectl --request-timeout` |
| `DK8S_COMMAND_TIMEOUT` | `180` s | discover | Hard wall-clock cap on every cluster command |
| `DK8S_RETRIES` | `3` | discover | Attempts per cluster command (`az aks get-credentials`, `kubectl`, `helm`) before it counts as failed |
| `DK8S_RETRY_DELAY` | `10` s | discover | Delay before retry, multiplied by the attempt number |
| `CLASSIFY_SAMPLE_ROWS` | `50` | classify | Oldest N skipped items kept per reason in `plan.json` |
| `REPORT_SAMPLE_ROWS` | `50` | report | Rows per skip reason in the report |
| `REPORT_MAX_TABLE_ROWS` | `2000` | report | Row cap per HTML table (the JSON keeps everything) |
| `SENDGRID_URL` | `https://api.sendgrid.com/v3/mail/send` | notify | Test hook |
| `<email_report.api_key_variable>` | — | notify | The SendGrid key |

## Command-line flags

See `./acr-cleanup.sh --help`. The ones that change what a run does:

| Flag | Effect |
| --- | --- |
| `--operation` | `validate-config`, `discover`, `inventory`, `plan` (default, read-only), `untag-stale-tags`, `sweep-untagged-manifests`, `untag-and-sweep`. Old names `untag`, `manifests`, `full` still work with a warning |
| `--repositories a,b` | Targeted run: only these repositories are inventoried, classified, executed and reported |
| `--tag-groups a,b` | Only these rules may produce candidates; other tags are `not-in-scope` |
| `--dry-run` / `--no-dry-run` | Shorthand for `--set run_settings.dry_run=…` |
| `--cluster`, `--repository`, `--shard i/n`, `--merge` | Pipeline sharding, see [USER_GUIDE.md](./USER_GUIDE.md) |
| `--skip-discover`, `--skip-inventory` | Reuse stage 1 / 2 output already in the work dir |
| `--work-dir`, `--previous-dir` | Where stage output goes; where the previous run's `result.json` and `lock-ledger.json` are. The orchestrator writes this run's copies of both there when it finishes, so a repeated local run against the same `--work-dir` gets continuity with no extra flag |
