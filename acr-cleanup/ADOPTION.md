# Adoption Guide

How to use this ACR cleanup approach for another product (DockAi, ODP, LiveHaul, Ocomo, …).

Nothing in `lib/` or `deploy/` is product-specific. Adopting the module means: copy the folder,
write one config file, add one pipeline wrapper, wire one deploy-time step.

Start by reading [README.md](./README.md) for the architecture and [USER_GUIDE.md](./USER_GUIDE.md)
for running it stage by stage; every option is in [CONFIGURATION.md](./CONFIGURATION.md). This
guide is the checklist.

---

## 1. Is this for you?

You want this if you have:

- an Azure Container Registry shared by several environments
- workloads running on AKS
- image tags produced per build (PR builds, branch builds), so tag count grows without bound
- no reliable answer today to *"is it safe to delete this image?"*

You do **not** need it if a plain `acr purge --ago <n>d` is already safe for you — i.e. nothing is
ever pinned and every environment redeploys frequently.

---

## 2. Prerequisites

| Item | Detail |
| --- | --- |
| Tools on the agent | bash 4.4+, `az`, `jq`, `curl`, `kubectl`, `helm`, and either `yq` or `python3` with PyYAML |
| ACR | Any tier. Premium if you want geo-replication |
| Soft delete | Enable it **if your registry supports it**: `az acr config soft-delete update -r <acr> --status enabled --days 7`. It is **not compatible with geo-replicated or zone-redundant registries** (MyProduct cannot use it) — see [the recovery window](#41-recovery-window-when-soft-delete-is-unavailable) |
| Service connections | One Azure service connection **per subscription** that hosts a consuming cluster |
| Agent pool | Prefer a pool with network line of sight to your API servers. MyProduct uses `Onprem-Linux-Agents` |

### Permissions

| Scope | Role / action | Why |
| --- | --- | --- |
| ACR | `AcrPull` | read tag and manifest metadata |
| ACR | `AcrDelete` | untag, delete manifests, lock/unlock |
| ACR | `Reader` | `az acr show-usage` for the report |
| AKS | `Azure Kubernetes Service Cluster User` | connect |
| AKS | AKS RBAC Reader, or an equivalent read-only ClusterRole | read pods and workloads |
| Subscription | `Microsoft.ContainerService/managedClusters/read` | `az aks list` for the unlisted-cluster warning |
| AKS | `Microsoft.ContainerService/managedClusters/runcommand/action` | **only** if `cluster_access_mode: aks_run_command` |

No Kubernetes **write** permission is needed.

### Choosing `cluster_access_mode`

| Mode | Use when | Trade-off |
| --- | --- | --- |
| `kubectl` | Your agents can reach the API server (on-prem agents, peered VNet, or public API server) | **Preferred.** Fast, and read-only |
| `aks_run_command` | Private API server and no agent with line of sight | Requires `runcommand/action`, which permits **arbitrary command execution inside any cluster in scope**. Also spins up a pod per invocation (~20–40 s) |

If you must use `aks_run_command`, scope the role assignment to individual clusters rather than the
subscription.

---

## 3. Install

```bash
# from your repo root
cp -r <path-to>/acr-cleanup devops/acr-cleanup
cp devops/acr-cleanup/config/example.yaml devops/acr-cleanup/config/<product>.yaml
```

Delete `config/myproduct.yaml` if you do not need it as a reference.

Overrides use a dotted path, and rules are addressable by name rather than index (index-based
overrides break when somebody reorders the list):

```bash
--set rule.pull_request_builds.delete_when_older_than_days=3
--set run_settings.parallel_delete_workers=8

# or from a pipeline variable, comma separated
ACR_CLEANUP_SET='run_settings.dry_run=false,rule.develop_builds.always_keep_newest=20'
```

Precedence: built-in defaults → config file → `ACR_CLEANUP_SET` → `--set`. Object keys merge
recursively; arrays are replaced, not concatenated.

---

## 4. Write your config

### 4.1 Recovery window when soft delete is unavailable

Check first:

```bash
az acr replication list -r <acr> -o table    # any rows other than the home region => soft delete is blocked
az acr config soft-delete show -r <acr>
```

[Soft delete does not support geo-replicated registries](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-soft-delete-policy),
and the portal also rejects zone-redundant ones. If either applies, do **not** try to work around it
by removing replicas — you would trade a recovery net for production pull latency and egress cost.

The module does not depend on soft delete. Deletion is already split into two phases:

| Phase | Operation | Reversible? |
| --- | --- | --- |
| 1 | untag stale tags | **Yes** — manifest and layers still exist; re-tag from the digest |
| 2 | delete manifests untagged for `min_untagged_manifest_age_days` | No |

Set `min_untagged_manifest_age_days` to at least two run intervals (14 for a weekly schedule) so
every item appears in at least two published reports before it can be destroyed. Set your pipeline
artifact retention long (365 days) — the report's `repo` / `tag` / `digest` records are your recovery
catalogue.

Restore:

```bash
az acr import -n <acr> --source <acr>.azurecr.io/<repo>@<digest> -t <repo>:<tag>
```

**Do not enable ACR's built-in untagged retention policy.** It deletes untagged manifests on its own
schedule, which destroys this recovery window, and it is not protection-aware.

### 4.2 Registry and clusters

```yaml
registry:
  name: <acr-name>
  resource_group: <rg>
  subscription_id: <sub-guid>
  service_connection: $(azureServiceConnection)
  host_aliases: []          # other hostnames meaning this same registry, e.g. a data endpoint

in_use_protection:
  keep_helm_revisions: 3
  min_untagged_manifest_age_days: 14
  cluster_access_mode: kubectl
  report_unlisted_clusters: true
  clusters:
    - { name: <aks-1>, resource_group: <rg-1>, service_connection: sc-<sub-a>, required: true }
    - { name: <aks-2>, resource_group: <rg-2>, service_connection: sc-<sub-b>, required: true }
    - { name: <test>,  resource_group: <rg-b>, service_connection: sc-<sub-b>, required: false }
```

List **every** cluster that pulls from the registry. A missing cluster means its running images are
invisible to the protection set. Confirm the list with:

```bash
az role assignment list --scope <acr-resource-id> --include-inherited \
  --query "[?roleDefinitionName=='AcrPull'].principalId" -o tsv
```

**`required`** controls what happens when a cluster cannot be read:

| Value | Behaviour | Use for |
| --- | --- | --- |
| `true` (default) | Abort the run before any mutation | Real environments |
| `false` | Warn in the report, continue | Test clusters that may be stopped for cost saving |

The list is explicit on purpose. Auto-discovering clusters sounds attractive, but a parked test
cluster would then fail discovery and silently disable cleanup until someone noticed.
`report_unlisted_clusters: true` gives you the visibility without the ability to block a run: it
lists clusters found in your subscriptions that are missing from this config.

If anything other than AKS pulls from the registry (ACI, App Service, VMs, developer laptops in CI),
either add a protection rule for it or add those repositories to `never_delete`. The module only
knows about Kubernetes.

Images from third-party registries running in your clusters (KEDA, Envoy, AGIC, upstream charts) are
filtered out by hostname and ignored. If you **mirror** upstream images into your ACR, they are
protected automatically by the no-matching-rule default.

### 4.3 Derive your tag groups

This is the only step that genuinely requires thought. Sample your real tags:

```bash
az acr repository show-tags -n <acr> --repository <busiest-repo> \
  --detail --orderby time_desc --top 50 --query "[].name" -o tsv
```

Group them by how they are produced, then write one rule per group. Rules are **ordered, first
match wins**, so put the most specific first.

```yaml
image_cleanup_rules:
  - tag_group: pull_request_builds
    tag_pattern: '^[0-9]+\.[0-9]+\.[0-9]+-PullRequest[0-9]+\.'
    delete_when_older_than_days: 7
    always_keep_newest: 2

  - tag_group: develop_builds
    tag_pattern: '^[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+'
    delete_when_older_than_days: 45
    always_keep_newest: 10

  - tag_group: release_builds
    tag_pattern: '^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+'
    delete_when_older_than_days: 180
    always_keep_newest: 10
```

Rules:

- **anchor your regexes.** `^` / `$` / explicit separators. Unanchored patterns match substrings and
  will silently classify `1.2.3-4` the same as `1.2.3-45`
- **patterns are POSIX ERE, not PCRE.** `\d`, `\w`, `\s`, `\b` and `(?...)` match nothing here and
  are rejected at config load. Use `[0-9]`, `[A-Za-z0-9_]` and so on
- **order matters, and suffix-style tags must come first.** A marker suffix such as `-inUse` sits on
  the end of an otherwise normal tag, so a broader rule earlier in the list will claim it
- **verify your assumptions against real builds.** With GitVersion defaults `alpha` is `develop` and
  `beta` is `release` — easy to get backwards. Check the pipeline's build numbers per branch before
  trusting a pattern
- **`always_keep_newest` is a floor, not a target.** A tag survives if it is inside
  `always_keep_newest` **or** inside `delete_when_older_than_days`. The two are OR'd. The floor is
  what stops a repository that has not been built in months from being emptied by the age rule
- **a tag matching no rule is never deleted.** Do not write a catch-all rule until you have run in
  dry-run mode long enough to trust the others

### Use `example_tags` — they turn the rule list into its own test suite

Add a few real tags to each rule. At config load every example must match its own pattern **and must
not be claimed by an earlier rule**:

```yaml
  - tag_group: legacy_inuse_markers
    tag_pattern: '-inUse$'
    delete_when_older_than_days: 0
    always_keep_newest: 0
    example_tags: [ '1.2.3-devops-99.1-5-dev-01-inUse' ]
```

The second check is the valuable one: it detects a shadowed rule before a single registry call is
made. Both real bugs found while designing this — swapped alpha/beta and an `inUse` suffix swallowed
by a broader rule — would have been caught here.

Validate without touching Azure:

```bash
./acr-cleanup.sh --config config/<product>.yaml --operation validate-config
./acr-cleanup.sh --config config/<product>.yaml --print-config | jq .
./tests/config.test.sh
```

### 4.4 Never-delete list

```yaml
never_delete:
  repositories:
    - { name: tools/<something>, reason: "shared tooling image" }
  tag_patterns:
    - { pattern: '^latest$',        reason: "floating tag" }
    - { pattern: '.*-donotdelete$', reason: "manual pin by engineers" }
```

Entries here are **never cleaned but always reported**, so you keep visibility of bloat you have
chosen not to manage. `-donotdelete` is the human escape hatch — document it for your engineers.

### 4.5 Locking

```yaml
image_lock:
  # Read ONLY by deploy/lock-deployed-images.sh, at release time
  lock_at_deploy:
    enabled: true
    environments:
      include: [ "PROD" ]
      exclude: [ "SEC" ]

  # Read ONLY by lib/lock-reconcile.sh, during the weekly cleanup
  unlock_when_unused:
    enabled: true
    wait_days_before_unlocking: 14
    never_unlock:
      repositories: []
      tag_patterns: [ '.*-donotdelete$' ]
```

The config is split by **which script reads it**. The cleanup never reads `environments` — "not
running anywhere and not a retained Helm revision" is the same question regardless of which
environment locked the image. The environment list lives in the repo rather than in a pipeline
condition so that adding an environment is a reviewed change, not an untracked edit in the release
UI.

The two flags are independent:

| `lock_at_deploy` | `unlock_when_unused` | Behaviour |
| --- | --- | --- |
| `true` | `true` | **Default.** Self-healing; locks converge to what is deployed |
| `true` | `false` | Lock-only — the anti-pattern that caused the MyProduct bloat. Observation during migration only |
| `false` | `true` | Unlock-only — useful for draining a historical lock backlog without adding new locks |
| `false` | `false` | No lock layer; L1, L2 and the floors still apply. Existing locks are still reported |

If you already have permanently locked images from a previous strategy, enable
`unlock_when_unused` and the ones no longer deployed are released, subject to
`wait_days_before_unlocking`. Because `execute.sh` never touches locks, an unlock always appears in
one report before the image becomes deletable in a later run.

### 4.6 Run settings and report

```yaml
run_settings:
  dry_run: true
  parallel_delete_workers: 24     # in-flight ACR calls; lower if you see HTTP 429
  parallel_repo_jobs: 6           # pipeline jobs for the read phase; bounded by agent pool size
  max_deletions_per_run: 20000    # circuit breaker — the ceiling on a bad rule's blast radius

email_report:
  enabled: false
  api_key_variable: SENDGRID_API_KEY
  from: <from-address>
  to: [ <stakeholders> ]
  attach_json: true
```

Keep `dry_run: true` until you have validated at least two reports.

---

## 5. Wire the pipeline

Copy and adapt:

- `build/Maintenance/acr-cleanup-template.yaml` — reusable, no changes needed
- `build/Maintenance/acr-cleanup-<product>.yaml` — set the config path, pool and schedule

```yaml
extends:
  template: acr-cleanup-template.yaml
  parameters:
    configPath: devops/acr-cleanup/config/<product>.yaml
    agentPool: <your-pool-with-cluster-connectivity>
    registryServiceConnection: <service-connection-for-the-registry>
    clusters:                       # names must match in_use_protection.clusters
      - { name: <aks-1>, serviceConnection: sc-<sub-a> }
      - { name: <aks-2>, serviceConnection: sc-<sub-b> }
```

Service connections are compile-time in Azure Pipelines, which is why the cluster list appears
both in the config (what to protect, `required` flag) and in the wrapper (which connection each
discovery job runs under). Add two schedules whose display names contain **"untag"** and
**"manifest"**; the template maps the name to the operation.

Stages run strictly in sequence: **Discover** → **Inventory** → **Classify** → **Reconcile locks** →
**Execute** → **Report**. Parallelism lives *inside* stages, never between them.

**Do not add a manual approval gate to the Execute stage.** On a weekly scheduled run it will sit
pending until it times out, so the cleanup silently never happens — a worse failure mode than the
risk it was meant to control. Rely on `dry_run`, the age and count rules, live-image protection, the
lock layer, the two-phase delete recovery window, and `max_deletions_per_run` instead.

For the same reason, schedule `--operation untag-stale-tags` and `--operation sweep-untagged-manifests` as
**separate runs** rather than `--operation untag-and-sweep`, so the reversible and irreversible phases never share a run.

---

## 6. Wire the deploy-time lock

Skip this if `image_lock.lock_at_deploy.enabled` is `false`.

1. Publish `devops/acr-cleanup/` as a build artifact so release stages can consume it.
2. In your deployment task group / stage, add an `AzureCLI@2` step **after** `helm upgrade`, using
   `scriptLocation: scriptPath` — not an inline script:

```
deploy/lock-deployed-images.sh \
  --config <artifact>/acr-cleanup/config/<product>.yaml \
  --environment "$(Release.EnvironmentName)" \
  --manifest-file <rendered-helm-manifest.yaml>      # or: --release <name> --namespace <ns>
```

   Set `continueOnError: true`: exit code 2 means some images could not be locked, and the running
   pods protect them until the next cleanup run anyway.

3. Leave the step condition as `succeeded()`. The environment gate lives in
   `image_lock.lock_at_deploy.environments`, so adding an environment later is a config PR
   rather than a task-group edit.

The script reads its image list from `helm get manifest`, so it cannot drift from what was actually
deployed.

---

## 7. Roll out in phases

Do not skip ahead. Each phase is gated on a clean report from the previous one.

| Phase | Change | What to check |
| --- | --- | --- |
| 0 | Enable soft delete if your registry supports it; otherwise confirm `min_untagged_manifest_age_days` spans at least two runs and set long artifact retention | A recovery path exists before anything destructive |
| 1 | Dry run, 2 cycles | Protection set matches live clusters; no false positives in the candidate list |
| 2 | Enable your highest-volume tag group (usually PR builds) | Lowest risk; watch for any environment breakage |
| 3 | Enable the remaining branch-build groups | |
| 4 | Retire any legacy marker/pin mechanism you had | Tag count drops |
| 5 | Enable lock reconciliation | Review the unlock list — those images become deletable from the *next* run, not this one |
| 6 | Enable untagged-manifest sweep | This is where storage actually drops |
| 7 | Decommission the old ACR tasks / scripts | Keep them disabled for one cycle before deleting |

---

## 8. Reading a dry-run report

Work through it in this order:

1. **Protection-set size per cluster.** Zero or implausibly small means discovery is broken — stop.
2. **Cluster warnings.** Check for unreachable non-required clusters, unlisted clusters found in
   your subscriptions, and images referencing a hostname that resembles your registry but is not in
   `registry.host_aliases`.
3. **Skipped-with-reason.** Confirm your currently deployed tags appear as
   `protected:cluster=<name>` or `protected:helm-history`.
4. **`no-matching-rule` count.** A very large number means your rules are too narrow and you will
   reclaim less than expected. A very small number in a registry with legacy tags means they may be
   too broad — check what they match.
5. **Candidate list.** Spot-check the newest candidate in your busiest repository. If you recognise
   it as something in use, do not proceed.
6. **Never-deleted repositories.** Confirm they never appear as candidates.
7. **Orphan locks.** Locked images not running anywhere — expect a large number on the first run if
   you are migrating from a lock-forever strategy. This is your backlog.

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Run aborts with "cluster unreachable" | Agent has no line of sight to a private API server, or wrong service connection | Run on an agent pool with connectivity, or switch that cluster to `cluster_access_mode: aks_run_command`. The abort is intentional — the run will not delete on partial visibility |
| A parked test cluster aborts every run | It is marked `required: true` | Set `required: false` on it |
| Protection set is empty | Wrong namespace/release names, or the registry hostname in the manifest does not match `registry.name` | Check the normalization log lines and `registry.host_aliases` |
| Nothing is ever a candidate | Your `tag_pattern` values do not match real tags | Sample real tags and re-derive; check for missing anchors |
| Untag skipped with reason `locked` | Expected — `execute.sh` never unlocks | `lock-reconcile.sh` will unlock it once `wait_days_before_unlocking` has passed; it becomes deletable the run after that |
| Manifest sweep deletes nothing | Manifests are younger than `min_untagged_manifest_age_days`, or still referenced | Expected; check the skip reasons |
| Cannot enable soft delete | Registry is geo-replicated or zone-redundant | Expected — not a permissions problem. Rely on the two-phase delete window instead; do not remove replicas to work around it |
| Storage does not drop after a big untag run | Untagging does not reclaim storage; the manifests and layers persist until the sweep | Expected. Storage drops after `--operation sweep-untagged-manifests` runs |
| Run is slow or times out | Too few shards, or serial calls | Increase `parallel_repo_jobs` and `parallel_delete_workers` |
| HTTP 429 in the log | ACR throttling | Lower `parallel_delete_workers` |
| Email not sent | `email_report.enabled` false, or the key is not injected | Check the pipeline variable is marked secret and mapped to `SENDGRID_API_KEY` |
| Orphan locks never get unlocked | The previous run's `report` artifact (with `lock-ledger.json`) is not being downloaded, so every run is a "first sighting" | Check the Execute job's download step and that the pipeline keeps at least one prior run |
| Sweep skips items with `changed-since-plan` | A tag or lock was added between inventory and delete | Expected; re-evaluated next run |

---

## 10. Anti-patterns

These are all real failures from the previous MyProduct implementations. Do not reintroduce them.

| Anti-pattern | Why it fails |
| --- | --- |
| **Duplicate marker tags in the registry** (e.g. `az acr import` to `<tag>-<env>-inUse`) | Doubles the tag count you are trying to reduce, and the marker needs its own lifecycle that inevitably rots. Store deployment state outside the registry |
| **One-way locking** (`lock_only` left on) | Locking on deploy without ever unlocking makes every deploy a permanent pin. It also blocks the untagged-manifest sweep behind those digests, so the storage is never reclaimed |
| **`az acr repository delete --image repo:tag`** | Deletes the manifest and *every* tag pointing at it, not just the one tag. Untag first, sweep manifests separately |
| **Unanchored substring matching** | `grep "$tag"` and `[[ $list =~ $tag ]]` match `1.2.3-13` inside `1.2.3-136`. Silently wrong, and worse: silently protects and deletes the wrong things |
| **One `az` process per item** | `az` is a ~1.5 s Python process and parallel invocations serialize on the shared MSAL token-cache lock. Use the ACR REST API with a reused token |
| **Hardcoded image lists in an inline pipeline script** | Drifts the moment a service is added. Read the list from the Helm manifest, and keep the script in the repo |
| **Deleting on partial cluster visibility** | If a cluster cannot be read, its running images look deletable. Always fail closed for `required: true` clusters |
| **A single retention value for every kind of tag** | PR builds and release builds have nothing in common. One value is either unsafe or useless |
| **A manual approval gate on a scheduled run** | It sits pending until timeout, so the cleanup silently never happens. Put the safety in the rules, not in a human who is not there on a Saturday |
| **Auto-discovering clusters and aborting when one is unreadable** | A test cluster parked in a stopped state then disables cleanup indefinitely. Keep the list explicit, mark optional clusters `required: false`, and surface unlisted clusters as a warning |

---

## 11. Getting help

Open an issue or pull request upstream so improvements flow back into the shared module.
