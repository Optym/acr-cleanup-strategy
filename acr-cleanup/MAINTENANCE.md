# Maintenance: dependencies, and what to do when one breaks

This module glues together a handful of external interfaces. Each one is listed here with where it is
used, how a break shows up, and how to update it. Check this file first when a run starts failing
after nothing in the repo changed.

## 1. External interfaces

### 1.1 ACR data-plane REST API

Used by [lib/acr-api.sh](./lib/acr-api.sh) for everything the registry does, deliberately instead of
`az acr` (one `az` process per call is ~1.5 s and serialises on the token cache).

| Endpoint | Used for | Function |
| --- | --- | --- |
| `POST /oauth2/token` (`grant_type=refresh_token`, `scope=repository:<repo>:<actions>`) | scope-limited access token from the `az acr login --expose-token` refresh token | `_acr_ensure_access_token` |
| `GET /acr/v1/_catalog?n=` | repository list | `acr_list_repositories` |
| `GET /acr/v1/<repo>/_tags?n=&orderby=timedesc` | tags with `digest`, `createdTime`, `lastUpdateTime`, `changeableAttributes` | `acr_list_tags` |
| `GET /acr/v1/<repo>/_manifests?n=&orderby=timedesc` | manifests with `tags`, `imageSize`, `mediaType`, `references`, `changeableAttributes` | `acr_list_manifests` |
| `GET /acr/v1/<repo>/_manifests/<digest>` | one manifest's attributes; pre-delete re-check; children | `acr_manifest_references`, `_execute_manifest_still_deletable` |
| `GET /acr/v1/<repo>/_tags/<tag>` | tag attributes and digest (deploy lock) | `lock_one` |
| `DELETE /acr/v1/<repo>/_tags/<tag>` | untag | `acr_untag` |
| `DELETE /v2/<repo>/manifests/<digest>` | delete manifest (OCI distribution API) | `acr_delete_manifest` |
| `PATCH /acr/v1/<repo>/_tags/<tag>` body `{writeEnabled, deleteEnabled}` | lock / unlock tag | `acr_set_tag_attributes` |
| `PATCH /acr/v1/<repo>/_manifests/<digest>` | lock / unlock manifest | `acr_set_manifest_attributes` |
| `Link: <…>; rel="next"` response header | pagination | `_acr_parse_next_link` |

Reference: [Azure Container Registry REST API](https://learn.microsoft.com/en-us/rest/api/containerregistry/)
(the `/acr/v1/` surface is documented under "Container Registry" data plane; `/v2/` is the OCI
distribution spec).

Symptoms of a change: HTTP 404 or 400 on every call of one kind; a field arriving `null` in
`inventory.json` (for example every `created` null makes every tag `no-timestamp` and nothing is
deleted, which is the safe direction). Where to look: the field mapping in `acr_inventory_repository`
and the JSON paths in the two `_still_deletable` / `lock_one` readers.

Behaviours we rely on and should re-verify after an ACR platform change:

- a manifest's `lastUpdateTime` moves when its tags change, so it measures time since the last untag
- `_manifests` entries carry `references` for manifest lists / OCI indexes
- deleting a tag (`/acr/v1/…/_tags/<tag>`) does not delete the manifest
- `changeableAttributes.deleteEnabled=false` makes `DELETE` return 405/403, which the module treats
  as failure rather than success

### 1.2 Azure CLI commands

| Command | Used by | Notes |
| --- | --- | --- |
| `az acr login --name <acr> --expose-token -o json` | `acr_init` | Returns `{loginServer, accessToken}`; the token is an ACR refresh token valid 3 h. If the JSON shape changes, only `acr_init` needs updating |
| `az acr show-usage -n -g --query "value[?name=='Size'].currentValue"` | `acr_usage_bytes` | ARM call for the storage figure. Failure only blanks the storage numbers in the report |
| `az account set --subscription` | discover | Only when a cluster entry has `subscription_id` |
| `az aks get-credentials --file --overwrite-existing` | discover | Writes a kubeconfig per cluster into `<work-dir>/kubeconfig/` |
| `az aks list -o json` | discover | Reporting only (`report_unlisted_clusters`); failure yields an empty list |
| `az aks command invoke --command` | discover, `aks_run_command` mode only | Output is wrapped in `{ logs }` and may be truncated |
| `az aks install-cli` | pipeline template | Installs `kubectl` and `kubelogin` on agents that lack them |
| `az acr import` | RUNBOOK only | Recovery of an untagged image |

Pin or upgrade the CLI on the agents deliberately: `az version`. The module needs `az` ≥ 2.40 for
`--expose-token`.

### 1.3 Kubernetes tooling

Every cluster command runs through `_dk8s_retry` (`DK8S_RETRIES`, `DK8S_RETRY_DELAY`) and a hard
wall-clock cap (`DK8S_COMMAND_TIMEOUT`). A `helm history` that still fails after retries fails the
cluster (fail closed); a release that disappeared between `helm list` and `helm history` is skipped.

| Tool | Used by | Depends on |
| --- | --- | --- |
| `kubectl get pods -A -o json`, `kubectl get <kinds> -A -o json`, `kubectl get crd scaledjobs.keda.sh` | discover | Only the presence of `image` / `imageID` keys anywhere in the JSON; the whole document is walked, so new workload kinds need no code change, only an addition to `_dk8s_kinds_to_read` if you want their templates included |
| `kubelogin convert-kubeconfig -l azurecli` | discover | Needed for Azure RBAC clusters; without it kubectl prompts for device login |
| `helm list -A -o json`, `helm history -o json`, `helm get manifest --revision` | discover | The manifest is scanned for `image:` lines with a regex (`_dk8s_refs_from_helm_manifest`). A chart that builds the image string from several YAML keys would be missed; the pod-level scan still catches it once running |
| `helm get manifest` / a `helm template` file | deploy lock | Same regex |

### 1.4 Azure DevOps

| Interface | Used by | Notes |
| --- | --- | --- |
| Tasks `AzureCLI@2`, `HelmInstaller@1`, `PublishPipelineArtifact@1`, `DownloadPipelineArtifact@2`, `CopyFiles@2`, `Bash@3` | template | Bump the `@N` when a task is deprecated; inputs are the documented ones |
| `Build.CronSchedule.DisplayName` | template | Chooses `untag-stale-tags` vs `sweep-untagged-manifests` for scheduled runs. If it ever arrives empty, the run falls back to `plan` and warns |
| `System.JobPositionInPhase`, `System.TotalJobsInPhase` | template | Inventory sharding under `strategy: parallel` |
| `POST …/_apis/build/retention/leases?api-version=7.1` | template | 365-day lease on the run. Needs the build service to have "Manage build queue" or "Update build information"; failure is `continueOnError` |
| Template expression `replace()` | template | Job names from cluster names |

### 1.5 SendGrid

`POST https://api.sendgrid.com/v3/mail/send` with a bearer key, `personalizations`, `content`
(`text/html`), and base64 `attachments`. Used by [lib/notify-sendgrid.sh](./lib/notify-sendgrid.sh).
Failure only warns. Override the URL with `SENDGRID_URL` for tests or a proxy.

### 1.6 Local tools

| Tool | Minimum | Why |
| --- | --- | --- |
| bash | 4.4 | `local -n`, empty-array expansion under `set -u`; checked at start |
| jq | 1.6 | `fromdateiso8601`, `@html`, `--slurpfile`, `--rawfile`. `test()` is Oniguruma, hence the ERE subset rule |
| awk, grep, sed, date | POSIX / GNU / BSD | `date -u +%s`; timestamps are parsed by jq, not `date` |
| curl | any | `--fail-with-body` only in the pipeline lease step (curl ≥ 7.76) |
| yq or python3 + PyYAML | | YAML to JSON once at load |

## 2. Updating safely

1. Reproduce with the tests first. Every suite stubs the external call at the function boundary
   (`ACR_TRANSPORT_FN`, `acr_request`, `acr_untag`, `az` on `PATH`), so a changed response shape can
   be pasted into a fixture and the fix verified without a registry.
2. Change the single function that owns the interface (table above). Field mappings for the
   inventory live in one jq program in `acr_inventory_repository`.
3. Run all suites, then a live `--operation plan --skip-discover` (read-only) and compare
   `result.json` totals with the previous run's.
4. Record the change in [progress.md](./progress.md)'s change log and, if a dependency version
   moved, in this file.

## 3. Deprecation watch

| Item | Status 2026-09 | Where it matters |
| --- | --- | --- |
| ACR soft delete | preview; incompatible with geo-replication | If it becomes GA and supports replicas, enable it and shorten `min_untagged_manifest_age_days`; the two-phase design stays valid |
| `az acr login --expose-token` | stable | `acr_init` |
| Helm 3 `helm get manifest --revision` | stable | discover, deploy lock |
| KEDA `scaledjobs.keda.sh` CRD | present on RouteMAX clusters | discover adds the kind only when the CRD exists |
| ADO `DownloadPipelineArtifact@2` `buildVersionToDownload: latestFromBranch` | stable | previous report / lock ledger |
