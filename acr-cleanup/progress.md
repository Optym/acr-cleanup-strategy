# ACR Cleanup — Progress Tracker

Live tracker for [US 281954](https://dev.azure.com/optym/PlatformEngineering/_workitems/edit/281954).
Keep this file current until the story closes; it is the record of what was enabled, when, and
what it reclaimed.

Status values: `Not started` · `In progress` · `Blocked` · `Done`

---

## ⚠ Production incident — 2026-09-06 (multi-arch manifests swept while their tag survived)

**Summary:** the 2026-09-05 real run of the manifest sweep deleted the platform-image and
attestation-manifest children of every still-tagged, multi-architecture image in the registry,
while leaving the tags themselves untouched. `routemax/keycloak` pods across all environments went
into `ImagePullBackOff` on 2026-09-06 as a result — the tag looked fine in the portal, but the
manifest it resolves to had a piece missing underneath it.

**Root cause:** Azure Container Registry's bulk `_manifests` listing API — the one call the tool
uses to inventory a whole repository — never returns the `references` field for an OCI image index
or a Docker manifest list; it comes back `[]` even when the index genuinely has children. Only a
per-manifest `GET` returns the real list. `classify.sh`'s protection for a multi-arch parent's
children (`kept_children`, added 2026-09-05 on the assumption that the bulk field was reliable — see
the now-corrected decision below) relied entirely on that empty field, so every untagged child of a
tagged multi-arch image was judged on its own age alone and swept once old enough — which every
image in the registry already was, since this was the tool's first live run.

**Confirmed three ways:** the missing digests return HTTP 404 directly against the registry; the
saved decision log (`decisions.jsonl`) from that run recorded each child as `reason: candidate` with
no parent-protection reason; the bulk listing's `references` field was inspected live and is empty
for every index checked.

**Blast radius**, from a registry-wide read-only audit on 2026-09-06 (see
`tools/audit-multiarch-references.sh`, and `docs/evidence/2026-09-06-multiarch-incident/` for the
full report and the per-image list):

| | Count |
| --- | --- |
| Tagged multi-arch images checked | 112 |
| Broken (child manifest missing) | **109**, across 34 repositories |
| Intact | 3 — all in `never_delete.repositories` (`tools/kubectl`, `workload-patcher`), independent confirmation of the mechanism |
| Currently deployed (confirmed outage) | 2 — both `routemax/keycloak` tags |
| Dormant (not yet redeployed, will fail on next pull) | 107 |

**Fix:** `lib/acr-api.sh`'s `acr_inventory_repository` now resolves every index/manifest-list
entry's real children with the per-manifest lookup (`acr_manifest_references`, which already existed
for exactly this but was never wired into inventory), and **fails the whole inventory** if that
lookup is unreadable, rather than silently recording an empty list. 8 new tests in
`tests/acr-api.test.sh` cover the exact scenario, the replace-not-merge behaviour, the already-gone
case, and the new fail-closed path. All 344 module tests pass.

**Recovery:** the 2 confirmed-broken keycloak tags were already redeployed to a working version by
the user before this was diagnosed. There is no soft delete on this registry, so none of the 109
broken images can be recovered — every one must be untagged (so nothing can accidentally redeploy to
it) or rebuilt fresh under a new tag. The 107 dormant ones are tracked as an open item below.

**Runbook:** [RUNBOOK.md §6](./RUNBOOK.md#6-a-tag-exists-but-imagepullbackoff-anyway-multi-arch-children).

---

## Baseline — `rmxacrcommon`, captured 2026-09-03

| Metric | Value |
| --- | --- |
| Repositories | 61 |
| Tags | 385,992 |
| Manifests | 455,492 |
| Storage | 2,263,488,721,335 B (~2.06 TiB) |
| SKU / geo-replications | Premium / 2 |
| Soft delete | **not available** — blocked by geo-replication (`westus2` zone-redundant, `eastus`) |
| Untagged retention policy | disabled |

Largest repositories by tag count:

| Repository | Tags | Manifests |
| --- | ---: | ---: |
| routemax/ui | 10,037 | 9,572 |
| routemax/apidocs | 10,004 | 629 |
| routemax/tsp | 9,994 | 18,956 |
| routemax/nearby-routes | 9,994 | 18,953 |
| routemax/apiproxy | 9,993 | 608 |
| routemax/dynamic-routing | 9,990 | 18,932 |
| routemax/listener | 9,989 | 18,935 |
| routemax/notification | 9,988 | 18,925 |
| routemax/calculate-pse | 9,982 | 18,930 |
| routemax/engine-reporting | 9,679 | 18,516 |

The manifests-far-exceeding-tags pattern is the orphaned-manifest backlog that locking prevented
`acr purge --untagged` from reclaiming.

---

## Build tasks

| # | Task | ID | Status | Notes |
| --- | --- | --- | --- | --- |
| 01 | Prerequisites: service connections, RBAC, recovery window (soft delete **blocked**) | [281976](https://dev.azure.com/optym/PlatformEngineering/_workitems/edit/281976) | In progress | Soft delete rejected by Azure — incompatible with geo-replication. Replaced by two-phase delete |
| 02 | Scaffold module and config loader | [281977](https://dev.azure.com/optym/PlatformEngineering/_workitems/edit/281977) | Done | `acr-cleanup.sh`, `lib/common.sh`, `lib/config.sh`, both configs, `tests/config.test.sh` (30 tests). `--operation validate-config` and `--print-config` work today |
| 03 | `lib/discover-k8s.sh` — protection set (L1 + L2) | [281978](https://dev.azure.com/optym/PlatformEngineering/_workitems/edit/281978) | Done | Per-cluster + merge, fail-closed, hard command timeout, `tests/discover-k8s.test.sh` (26 tests). Verified live against `rmx-aks-np-eus-c1` |
| 04 | `lib/acr-api.sh` — ACR REST client | [281979](https://dev.azure.com/optym/PlatformEngineering/_workitems/edit/281979) | Done | Token exchange per scope, retry with `Retry-After`, Link-header pagination, inventory with lock state and index `references`, `--shard i/n`, `tests/acr-api.test.sh` (48 tests). Verified live against `routemax/saiamockservice` on 2026-09-04 |
| 05 | `lib/classify.sh` — never_delete, cleanup rules, age + count | [281980](https://dev.azure.com/optym/PlatformEngineering/_workitems/edit/281980) | Done | Per-repository jq pass; tag decisions with reason + detail; manifest sweep candidates incl. `referenced-by-parent`; `plan.json` carries every lock with its protection status; `tests/classify.test.sh` (46 tests). Needs a live `--operation plan` run once `az login` works again |
| 06 | `lib/execute.sh` — parallel untag + manifest sweep | [281981](https://dev.azure.com/optym/PlatformEngineering/_workitems/edit/281981) | Done | Forked workers sharing the token cache, oldest-first cap, pre-delete manifest re-check, never touches locks; `tests/execute.test.sh` (27 tests) |
| 07 | `lib/lock-reconcile.sh` — lock lifecycle | [281982](https://dev.azure.com/optym/PlatformEngineering/_workitems/edit/281982) | Done | Unlock-only; `wait_days_before_unlocking` measured from a `lock-ledger.json` carried run to run as an artifact; held / pinned / waiting / orphan / unlocked / failed; `tests/lock-reconcile.test.sh` (32 tests) |
| 08 | `deploy/lock-deployed-images.sh` — Helm-driven prod lock | [281983](https://dev.azure.com/optym/PlatformEngineering/_workitems/edit/281983) | Done | Reads `lock_at_deploy`, gates on environment, image list from the Helm manifest (`--manifest-file` or `helm get manifest`), locks delete on tag + manifest, idempotent, exit 2 on partial failure; `tests/lock-deployed-images.test.sh` (22 tests) |
| 09 | `lib/report.sh` — JSON + HTML report | [281984](https://dev.azure.com/optym/PlatformEngineering/_workitems/edit/281984) | Done | `result.json` (single) + three self-contained HTML files split by audience — `report-summary.html`, `report-deleted.html`, `report-protected.html` (cluster/namespace deployed-version detail, opt-in post-cleanup validation) — delta vs previous run, always produced; `tests/report.test.sh` (65 tests incl. notify) |
| 10 | `lib/notify-sendgrid.sh` — opt-in email | [281985](https://dev.azure.com/optym/PlatformEngineering/_workitems/edit/281985) | Done | HTML body + `result.json` attachment, key from `email_report.api_key_variable`, warn-only |
| 11 | ADO pipeline template + RouteMAX wrapper (`build/Maintenance/`, on-prem pool, no approval gate) | [281986](https://dev.azure.com/optym/PlatformEngineering/_workitems/edit/281986) | In progress | `build/Maintenance/acr-cleanup-template.yaml` + `acr-cleanup-routemax.yaml` written: Discover (job per cluster) → Inventory (6 shards) → Execute; previous-report download, 365-day retention lease, schedule-name → operation. **Pipeline definition not yet created in ADO and not yet run** |
| 12 | Publish artifact + rewire release task group | [281987](https://dev.azure.com/optym/PlatformEngineering/_workitems/edit/281987) | In progress | `build/components/helm.yaml` now publishes `devops/acr-cleanup/` inside the `Helm` artifact. **Release task group step not yet added** (see README §6 for the exact step); legacy `inUse` scripts still published until phase 7 |
| 13 | README.md and progress.md | [281988](https://dev.azure.com/optym/PlatformEngineering/_workitems/edit/281988) | Done | Document set split on 2026-09-05: README (design), USER_GUIDE (stage by stage + tests), CONFIGURATION (every option), RUNBOOK (recovery + symptoms), MAINTENANCE (dependencies, what to do when an API breaks), CONTRIBUTING + AGENTS (for people and small models), docs/evidence (captured runs) |
| 14 | ADOPTION.md | [281989](https://dev.azure.com/optym/PlatformEngineering/_workitems/edit/281989) | Done | |

## Rollout tasks

| # | Task | ID | Status |
| --- | --- | --- | --- |
| 15 | Phase 1 — dry-run validation | [281990](https://dev.azure.com/optym/PlatformEngineering/_workitems/edit/281990) | Not started |
| 16 | Phase 2–3 — enable `pr`, then `feature` + `beta` | [281991](https://dev.azure.com/optym/PlatformEngineering/_workitems/edit/281991) | Not started |
| 17 | Phase 4 — retire the `inUse` mechanism | [281992](https://dev.azure.com/optym/PlatformEngineering/_workitems/edit/281992) | Not started |
| 18 | Phase 5–6 — lock reconciliation + manifest sweep | [281993](https://dev.azure.com/optym/PlatformEngineering/_workitems/edit/281993) | Not started |
| 19 | Phase 7 — decommission legacy cleanup | [281994](https://dev.azure.com/optym/PlatformEngineering/_workitems/edit/281994) | Not started |

---

## Rollout phases

Each phase is gated on the previous one. Record the run link and the observed metrics before
moving on.

| Phase | Change | Status | Date | Run | Tags after | Manifests after | Storage after |
| --- | --- | --- | --- | --- | ---: | ---: | ---: |
| 0 | Recovery window: `min_untagged_manifest_age_days: 14` + 365-day report artifact retention (soft delete unavailable) | Not started | | | — | — | — |
| 1 | Dry-run validation, 2 cycles | Not started | | | — | — | — |
| 2 | Enable deletion: `pr` family | Not started | | | | | |
| 3 | Enable deletion: `feature` + `beta` | Not started | | | | | |
| 4 | Retire `inUse` (stop producing + untag sweep) | Not started | | | | | |
| 5 | Enable lock reconciliation (unlocks historical backlog) | Not started | | | | | |
| 6 | Enable untagged-manifest sweep | Not started | | | | | |
| 7 | Decommission `imagePurgeTask`, `PRpurgeTask`, pipeline 579 | Not started | | | | | |

> Untagging does not reclaim storage — manifests and layers persist until the sweep in phase 6. So
> tag count drops in phases 2–4, but the storage number only moves after phase 6.

---

## Decisions

| Decision | Rationale |
| --- | --- |
| Retire the `inUse` marker tags | Only untagged in non-prod and locked in prod, so they accumulated forever; they also doubled tag count. Live cluster discovery replaces them |
| Keep image locking, but reconcile it | Locking is a genuine extra layer and covers the week-long gap between a deploy and the next cleanup run. Making the weekly job the sole owner of *unlocking* removes the growth problem |
| Lock production only by default | `image_lock.lock_at_deploy.environments.include: [PROD]`, `exclude: [SEC]`. Other environments are added by config PR, not by editing the task group |
| Lock script lives in the repo | Replaces inline PowerShell in the release task group; version-controlled, reviewable, and its image list is read from the Helm manifest so it cannot drift |
| Defer the L3 deployment ledger | L1 + L2 already protect everything running or one rollback away; the ledger adds infrastructure for resilience we do not need on day one |
| Fail closed | If a `required: true` cluster is unreachable or the protection set is empty, abort before any mutation |
| Never-deleted repositories are still reported | Keeps bloat in `tools/kubectl`, `node-ts-tools`, `workload-patcher`, `routemax/osrm` visible |
| **No approval gate on the Execute stage** | A Saturday-scheduled run behind a manual approval would sit pending until timeout, i.e. cleanup silently never runs. Safety comes from `dry_run`, age and count rules, live-image protection, the lock layer, the two-phase delete window and `max_deletions_per_run` |
| **ACR soft delete cannot be used; two-phase delete replaces it** | Soft delete is incompatible with geo-replicated / zone-redundant registries, and `rmxacrcommon` replicates to `westus2` (zone-redundant) and `eastus`. Removing replicas would add cross-region latency and egress cost for the West US production clusters, and soft-deleted artifacts are billed at full storage price anyway. Instead: untag (reversible) and sweep manifests only after `min_untagged_manifest_age_days: 14`, with 365-day report retention as the restore catalogue |
| **ACR built-in untagged retention policy stays disabled** | It would delete untagged manifests on its own schedule, destroying the recovery window, and it is not protection-aware |
| **`untag` and `manifests` run as separate scheduled runs** | Keeps the reversible and irreversible phases in different runs, each with its own report |
| **Tag groups corrected against real builds** | GitVersion defaults mean `alpha` = `develop` and `beta` = `release/*` and `hotfix/*` — the opposite of the first draft. Added a `devops_builds` group for `devops/*` (`5.6.0-devops-280892.1-105`). Verified against pipeline 11 runs and registry tags |
| **`legacy_inuse_markers` is the first rule** | An `inUse` marker is a suffix on an otherwise normal tag, so with first-match-wins any later rule claims it first. `5.6.0-devops-280892.1-105-dev-03-inUse` would otherwise be classified as a devops build and never cleaned |
| **`image_lock` split by consuming script** | `lock_at_deploy` (read only by `deploy/lock-deployed-images.sh`) and `unlock_when_unused` (read only by `lib/lock-reconcile.sh`). The cleanup never needs environment names. Replaces the `mode` enum with two independent flags, which also enables an unlock-only state for draining the phase-5 backlog |
| **Run on `RouteMax-Agents-OnPrem-Linux`** | Has line of sight to the private API servers, so `kubectl` works directly. Removes the need for `runcommand/action`, which would otherwise permit arbitrary command execution in any cluster in scope |
| **Explicit cluster list, not auto-discovery** | A test cluster parked in a stopped state would fail discovery and silently disable cleanup. Gap closed by `required: false`, an unlisted-cluster warning in the report, and a `clusterOverride` pipeline variable |
| **`execute.sh` never touches lock state** | `lock-reconcile.sh` is the single writer of locks; `execute.sh` skips locked tags. Removes a race and guarantees an unlock is always visible in a report one run before deletion becomes possible |
| **Config renamed to plain `snake_case`** | `families` → `image_cleanup_rules`, `retentionDays` → `delete_when_older_than_days`, `keepLatest` → `always_keep_newest`, `exclusions` → `never_delete`, `locking` → `image_lock`, `execution` → `run_settings` |
| **Dropped `reportOrphanLocks`, `abortIfClusterUnreachable`, `notify.email.provider`** | Orphan-lock reporting is read-only insight and is always on; fail-closed is a safety invariant, not a preference; SendGrid is the only provider |

| **`example_tags` on every cleanup rule** | Config load asserts each example matches its own rule and is not claimed by an earlier one. This is a regression test for the rule list itself, and it would have caught both bugs found during design: swapped alpha/beta, and the `inUse` suffix shadowed by `devops_builds` |
| **Patterns are POSIX ERE and PCRE shorthand is rejected** | `\d`, `\w`, `\s`, `\b`, `(?...)` match nothing under `grep -E`. Silently matching nothing is worse than failing, so config load errors on them |
| **Reconciler is unlock-only** | Locking protected images weekly would lock non-prod images too (the reconciler knows nothing about environments) and blur what a lock means. Deploy time is the only lock writer; the weekly run only removes locks, subject to the ledger wait |
| **Cross-repository tag protection added, opt-in, enabled for RouteMAX** (2026-09-10) | `dispatch` and `ibplanning` are separate Helm charts that share one build-pipeline tag stream (`build/components/backend.yaml`, `engine.yaml` stamp one tag on every module's images). On 2026-09-10, `routemax/driver-eventprocessor:4.18.0-beta.1-143` and `routemax/driver-tsp:4.18.0-beta.1-143` (both `dispatch`-only) were correctly untagged as unreferenced - no tenant ran them - while the identical tag stayed protected for `routemax/api` (`ibplanning`). Not a bug: L1/L2 protection is scoped to what a chart actually renders, and no `dispatch` release anywhere was still on that tag. But it exposed a real forward risk: a tenant can enable a dormant module on its existing pinned version with no version bump, and that module's images for the tag may already be gone. `in_use_protection.protect_tag_across_repositories` (default `false`, `true` for RouteMAX) broadens protection from `(repository, tag)` to tag-name-only once any repository protects a tag - see README.md "Cross-repository tag protection" for the accepted tradeoff (dormant-module bloat shrinks slower). The durable fix is process-level: upgrade a tenant to the latest chart version as part of enabling a previously-dormant module, rather than flipping the module on for their current pinned version |
| **Unlock wait tracked in a ledger artifact** | "Out of the protection set for N days" needs memory across runs. `lock-ledger.json` (first-seen-unprotected per item) rides with the report artifact; absent ledger means every orphan restarts its wait, which fails safe |
| **Manifests are re-read right before deletion** | The inventory can be an hour old by the time the sweep reaches an item; a tag pushed or a lock added in between must win. One extra GET per irreversible delete is cheap insurance |
| ~~Index children protected via inventory `references`~~ **Corrected 2026-09-06**: the bulk `_manifests` listing does NOT carry `references` for an index — confirmed empty against the live API after this exact assumption let the sweep delete two live keycloak images (109 registry-wide). Index/manifest-list children are now resolved with a per-manifest `GET`, and inventory fails closed if that lookup is unreadable. See the incident section at the top of this file |
| **Protection is reported before age** | A deployed old image says `protected`, not `within-retention`, because "is my image safe and why" is the question the report exists to answer |
| **Rules are overridable by name, not index** | `--set rule.pull_request_builds.delete_when_older_than_days=3`. Index-based overrides break the moment the list is reordered |
| **All logging goes to stderr** | Keeps stdout clean for JSON, so `--print-config` and every stage's output can be piped straight into `jq` |
| **Discovery walks the whole kubectl JSON tree for `image` / `imageID`** | Naming specific paths means a new workload kind or an injected sidecar is silently missed. Also captures resolved digests from `status.containerStatuses[].imageID`, so images are protected by digest as well as by tag |
| **Hard wall-clock cap on every cluster command** | `kubectl --request-timeout` does not cover a stalled TCP connect to a private endpoint. Without the cap a discovery job hangs until the pipeline timeout instead of failing the cluster. Uses coreutils `timeout` when present, with a bash watchdog fallback |
| **Per-release progress logging in the Helm phase** | RouteMAX runs a namespace per tenant, so a non-prod cluster has dozens of releases and the phase runs for minutes. Without progress output a working run is indistinguishable from a hang |
| **Helm releases read in parallel** (`in_use_protection.helm_parallelism`, default 6) | The Helm phase dominates discovery. On `rmx-aks-np-eus-c1` (49 releases x up to 3 revisions) this took 6+ min serially and 2 min 17 s at 6 workers. Reads are read-only and each worker owns its output file, so only log ordering changes — verified by diffing the two protection sets in both directions |
| **An orphaned lock unlocks immediately when it is already past its own retention rule, not only after `wait_days_before_unlocking`** | The ledger-based wait exists for the borderline case — an item that *just* went unprotected and might come back — not as a blanket delay on every orphan. A deploy-time lock is applied to a real, already-shipped build, so by the time it is orphaned it is almost always already stale by its own rule. Waiting the full `wait_days_before_unlocking` on top of that for every item in a legacy lock-forever backlog (RouteMAX has ~50k) was indistinguishable from "orphans never unlock" locally, which is exactly what was reported. `classify.sh` now computes `would_delete` / `would_sweep` per item (age/count rules alone, ignoring protection and the lock), and `lock-reconcile.sh` unlocks on that signal immediately; the ledger wait still applies to anything not yet stale |
| **The orchestrator carries `result.json` and `lock-ledger.json` into `--previous-dir` itself, at the end of every run** | Previously only the pipeline's `DownloadPipelineArtifact` step ever populated `--previous-dir`; a local run reusing the same `--work-dir` never saw its own history, so the "delta vs previous run" report section and the lock wait clock were silently dead outside the pipeline. `carry_forward_to_previous` (`lib/common.sh`) fixes both by construction, for local and pipeline use alike |

---

## Open items

| Item | Owner | Status |
| --- | --- | --- |
| SendGrid API key placement (pipeline variable vs variable group) and from/to addresses | | Open |
| Re-estimate US 281954 (currently 16 h / 2 SP, breakdown totals ~48 h) or split rollout into a follow-up story | | Open |
| Confirm on-prem agent pool capacity for `parallel_repo_jobs` concurrent jobs | | Open |
| Confirm outbound HTTPS to `*.azurecr.io` from `RouteMax-Agents-OnPrem-Linux` | | Open |
| Confirm `RouteMax-Agents-OnPrem-Linux` has bash 4.4+, `jq`, `awk`, and either `yq` or `python3` with PyYAML | | Open |
| Create the `acr-cleanup-routemax` pipeline definition in ADO from `build/Maintenance/acr-cleanup-routemax.yaml`, grant the build service "Manage build queue" (retention lease) and read on the `Common` variable group | | Open |
| Add the `lock-deployed-images.sh` step to the release task group after `helm upgrade` (README §6), `continueOnError: true` | | Open |
| ~~Phase-1 check: confirm ACR bumps a manifest's `lastUpdateTime` on untag~~ **Resolved 2026-09-13**: it does not. See finding below | | Done |
| ~~Re-run `az login` on the dev machine~~ First live `--operation plan` ran 2026-09-05 against all six clusters and 61 repositories; evidence in `docs/evidence/2026-09-05-baseline-plan/` | | Done |
| ~~Phase-1 check refined: 227,117 of 227,135 untagged manifests already exceed `min_untagged_manifest_age_days`~~ **Resolved 2026-09-13**: confirmed by direct test against `dockacrnp` — untagged `dummy-outbox-ordering-check:2026.8.537-devops-264651-5.1` (`az acr repository untag`) and compared `az acr manifest list-metadata` before/after by digest: `lastUpdateTime` was `2026-08-04T08:51:07.1053356Z` both before and after, unchanged by the untag. **`age_days` in `lib/classify.sh` is age-since-last-push, not age-since-untagged.** `min_untagged_manifest_age_days` therefore does not give a freshly-orphaned image a grace period after it loses its tag — an image already older than the threshold at push time is sweep-eligible the moment it becomes untagged, on the very next run. It still protects a manifest whose *last push* was recent, which is the only protection it was ever actually providing. The 227,117/227,135 finding was the legacy backlog, not a live two-report window, as suspected | | Done |
| Confirm on real `rmxacrcommon` data whether the ~49k-strong orphan-locked backlog is now mostly `would_delete: true` (immediate unlock) as expected, or mostly still-young (falls back to the 14-day wait) — the fix landed 2026-09-05 but has only been checked against synthetic fixtures and unit tests so far | | Open |
| **Untag or rebuild the 107 dormant broken multi-arch images** found by the 2026-09-06 audit (full list in `docs/evidence/2026-09-06-multiarch-incident/broken-images-report.csv`), before anything redeploys onto one of them | | Open |
| Do not re-run `sweep-untagged-manifests` / `untag-and-sweep` against `rmxacrcommon` until the `lib/acr-api.sh` reference-resolution fix has been validated with a dry run on this registry | | Open |
| Notify teams owning the 34 affected repositories (list in the incident section above / evidence report) so they know not to redeploy the specific broken tags | | Open |
| Re-run `tools/audit-running-images.sh` with fresh discovery (no `--skip-discover`) against the whole fleet — the `--skip-discover` test run against a stale (13:25 UTC) snapshot found a 4th possibly-broken keycloak tag, `4.14.0-alpha.257` (`reason=tag-not-found`), not previously in the incident list. Could be a stale snapshot artifact (redeployed since) or a genuinely new finding; confirm before treating it either way | | Open |
| Wire `--validate-after` into the ADO pipeline (a `validateAfter` parameter on `acr-cleanup-routemax.yaml`, threaded to the orchestrator) — not done yet since the pipeline definition itself isn't created in ADO | | Open |
| `tools/audit-running-images.sh` still has no dedicated test suite (pre-existing gap, unchanged by the 2026-09-10 report-split work) — it has only ever been exercised live against real clusters | | Open |
| DockAi (`dockacrnp`, ~5 TB, 31 repositories, every tag an OCI index): after the 2026-09-11 fixes, `--operation inventory --repositories app-database-migration` completed live in 732 s (bulk listing 4.5 min for 4,082 tags / 16,582 manifests; 4,087 index lookups in 7 min at 8-wide, ~9.7/s vs ~2.8/s serial). A full 31-repository `plan` is still to be run end to end; expect ~1–1.5 h at `parallel_repo_jobs` 4. Cache resolved index children across runs (`digest -> children` is immutable; key on `lastUpdateTime` to stay safe against referrers) if that per-run cost is too high for a weekly job | | Open |
| DockAi `image_lock.lock_at_deploy.environments` still says `PROD`; the release pipeline only has `dev-01` / `qa-01` stages today, so the deploy-time lock never fires until a prod stage exists and its name is confirmed | | Open |

---

## Change log

| Date | Entry |
| --- | --- |
| 2026-09-03 | Baseline captured; legacy `inUse` + lock strategies reviewed; plan approved; 19 tasks created (281976–281994); README, ADOPTION and progress scaffolded |
| 2026-09-03 | Design review: approval gate removed; stages made strictly sequential with a single lock writer; on-prem agent pool adopted; explicit cluster list with `required` flag and unlisted-cluster warning; `registry.host_aliases` added; config renamed to plain `snake_case`; three options dropped |
| 2026-09-03 | Task 01 blocker: ACR soft delete rejected — incompatible with geo-replication. Replaced with two-phase delete (`min_untagged_manifest_age_days` 7 → 14), 365-day report artifact retention, separate `untag` / `manifests` runs, and a restore-from-digest runbook |
| 2026-09-03 | Tag groups corrected against pipeline 11 runs: `alpha` = develop, `beta` = release/hotfix, new `devops_builds` group, `legacy_inuse_markers` moved to first rule. `image_lock` restructured into `lock_at_deploy` / `unlock_when_unused` |
| 2026-09-03 | Task 02 done: module scaffolded, config loader with override precedence and validation, `config/routemax.yaml` + `config/example.yaml`, 30 passing config tests |
| 2026-09-03 | Task 03 done: `lib/discover-k8s.sh` (L1 pods/workloads incl. ephemeral containers and imageID digests, L2 Helm history, per-cluster + merge, fail-closed, hard command timeout, unlisted-cluster and lookalike-host warnings), 26 passing discovery tests, `--operation discover` wired up and verified live against `rmx-aks-np-eus-c1` |
| 2026-09-04 | Helm phase parallelised (`helm_parallelism`, default 6): `rmx-aks-np-eus-c1` 6+ min -> 2 min 17 s, 3,438 vs 3,439 references. Set difference of Helm-sourced entries empty in both directions; the single extra entry is a pod that started between runs, and pods are read serially in both |
| 2026-09-04 | Task 04 done (was already written but untracked here): `lib/acr-api.sh` verified against `routemax/saiamockservice`; the `acr-api.test.sh` large-repository case hung on quadratic `${var#*\|}` parsing of a 1.4 MB fixture, fixed with `IFS read`. Inventory now records manifest `references` |
| 2026-09-04 | Tasks 05–10 done: `classify.sh`, `lock-reconcile.sh` (ledger-based wait), `execute.sh`, `report.sh`, `notify-sendgrid.sh`, `deploy/lock-deployed-images.sh`, orchestrator wired for `plan` / `untag` / `manifests` / `full` with `--skip-discover`, `--skip-inventory`, `--shard`, `--previous-dir`. 279 unit tests across 8 suites, all pure |
| 2026-09-05 | First live `--operation plan` on all six clusters: 2,493 protected tags + 777 digests; 388,105 tags, 299,104 untag candidates (229k PR builds), 49,420 orphan-locked tags, 227,117 sweep candidates (~467 GiB). Report stage had failed silently on the first run (`--argjson` of the 2.4 MB protection set exceeded ARG_MAX): fixed, large inputs now go through files and a report failure aborts loudly. `plan.json` slimmed (203 MB → candidates + samples), full per-item decisions moved to `decisions.jsonl`. Classifier splits the inventory once instead of re-parsing 350 MB per repository. Candidate bytes deduplicated by digest. `az acr show-usage` now passes `--subscription`. Stage banners and per-stage timings (`timings.json`, report §1) added. `tools/snapshot-evidence.sh` + `docs/evidence/` for demo evidence |
| 2026-09-05 | Live `--operation discover` on `rmx-aks-np-eus-c1` failed with "Argument list too long": the cluster's 3.4k entries were passed to jq with `--argjson`. All large JSON in discover and lock-reconcile now goes through files. Added `_dk8s_retry` (3 attempts, growing delay) around every cluster command; Helm reads that still fail now fail the cluster instead of silently protecting nothing; a release deleted between `helm list` and `helm history` is skipped. Local inventory runs `parallel_repo_jobs` repositories concurrently. 12 new discover tests incl. a 30k-reference cluster fixture |
| 2026-09-05 | Operations renamed to say what they do: `untag-stale-tags`, `sweep-untagged-manifests`, `untag-and-sweep` (old names accepted with a warning). Targeted cleanup: `--repositories a,b` (CLI) / `repositories` (pipeline) scopes stages 2–6 to named repositories; discovery still covers every cluster |
| 2026-09-05 | Config tuned by Arun after the first plan: PR builds 30 d / keep 10, develop 90 d, release 90 d, keep 10 on devops/feature, `keep_helm_revisions` 5, three more `never_delete` repositories, `parallel_repo_jobs` 2 |
| 2026-09-05 | Arun reported no images unlocking locally. Root causes: (1) `wait_days_before_unlocking` gated every orphan regardless of how stale it already was, so a legacy lock-forever backlog needed the full wait on top of its existing age; (2) `--previous-dir` was only ever populated by the pipeline's artifact download, so a local rerun never saw its own `lock-ledger.json`. Fixed both: `classify.sh` computes `would_delete`/`would_sweep` (age/count rules alone, ignoring protection and the lock) and threads them onto `plan.locks.*`; `lock-reconcile.sh` unlocks a stale orphan immediately (`unlock_basis: already_past_retention`) and only waits out the ledger clock for a genuinely young one (`wait_elapsed`); the orchestrator's new `carry_forward_to_previous` (`lib/common.sh`) copies `result.json` and `lock-ledger.json` into `--previous-dir` at the end of every run, local or pipeline. `lock-result.json.totals` gained `not_protected`, `unlocked_immediately`, `unlocked_after_wait`, fixing a pre-existing conflation where `.totals.orphan` silently meant two different things depending on `unlock_when_unused.enabled` |
| 2026-09-05 | Report redesign + bug fixes, on request ("make it an executive summary, check for bugs"). Bugs found and fixed, all pre-existing: (1) a bare `--operation plan` never populated section 5 ("would be deleted"), because that section only ever read `execution.dry_run_items`, which only exists once stage 5 has run — `plan` never reaches it. Section now falls back to the uncapped `plan.untag`/`plan.manifests` candidate lists. (2) `untag-and-sweep` silently under-reported: the repositories table and the deleted count read only the last-executed `delete-result.json` (the sweep half), never `delete-result.untag.json`; on a real run this hid every untag from the report while still having executed it. `report.sh` now reads both files and discriminates tag vs manifest items by the presence of a `tag` key instead of comparing operation-name strings, which also removes the risk of the report silently going stale if an operation is renamed again. (3) `lock-result.json.totals.orphan` conflated "disabled-case" and "any unresolved orphan" under one key (see above). (4) the "Skipped, with reason" table included `candidate` — the tags that ARE about to be deleted — under a "skipped" heading. Redesign: `report.html` opens with an executive-summary card row (status, tags/manifests/storage before-after, protected, candidates, deleted, locks, warnings/errors) and a jump-link table of contents; sections renumbered 1-9, the old "Cluster warnings" and "Errors and warnings" sections merged into one; numbers get thousands separators. New `tests/acr-cleanup.test.sh` runs the orchestrator itself as a subprocess (fake `az` on `PATH`) to prove the `--previous-dir` continuity end to end, something no unit suite could reach. 336 tests total |
| 2026-09-06 | **Production incident**: `routemax/keycloak` pods failed with `ImagePullBackOff` on tags still visible in ACR. Diagnosed to the 2026-09-05 real sweep deleting the platform-manifest and attestation-manifest children of still-tagged multi-arch images, because ACR's bulk `_manifests` listing never returns `references` for an index — confirmed live (missing digests return 404; the run's own `decisions.jsonl` shows each child judged `candidate` on age alone with no parent-protection reason). Fixed in `lib/acr-api.sh`: inventory now resolves real children via a per-manifest `GET` and fails closed if that lookup is unreadable, instead of silently recording an empty list. 8 new tests in `tests/acr-api.test.sh`. New `tools/audit-multiarch-references.sh` (read-only, registry-wide) confirmed the same failure in 109 of 112 currently-tagged multi-arch images across 34 repositories — every one not excluded by `never_delete.repositories`. Only `routemax/keycloak`'s 2 tags were confirmed currently deployed (cross-checked against the discovery snapshot); the other 107 are dormant until something redeploys onto them. Full incident writeup added at the top of this file; runbook entry at [RUNBOOK.md §6](./RUNBOOK.md#6-a-tag-exists-but-imagepullbackoff-anyway-multi-arch-children); evidence and the per-image CSV in `docs/evidence/2026-09-06-multiarch-incident/`. 343 module tests total |
| 2026-09-06 | Added `tools/audit-running-images.sh`: a targeted post-cleanup check, distinct from the registry-wide `audit-multiarch-references.sh` above. Scoped to exactly what stage 1 protects (running pods, workload templates, retained Helm revisions) rather than every tagged manifest in the registry, so it is fast enough to run after every real cleanup, not only during an incident. Supports `--repository`, `--repositories` (comma list) and the whole fleet by default; `--skip-discover` reuses an existing `protection-set.json` (e.g. from the cleanup run that just finished in the same `--work-dir`), otherwise it discovers live so the check reflects what is running right now, not what was running when an earlier snapshot was taken. Rejects an unknown repository name outright, warns (not fails) on a real repository with nothing currently deployed. Exit code is non-zero if anything is broken. Documented in [USER_GUIDE.md §6](./USER_GUIDE.md#6-post-cleanup-validation) and [RUNBOOK.md §6](./RUNBOOK.md#6-a-tag-exists-but-imagepullbackoff-anyway-multi-arch-children). Live-tested against `routemax/keycloak` (correctly found all 3 known-broken tags plus a previously-unnoticed 4th, `4.14.0-alpha.257`, whose tag is gone entirely — likely a stale discovery snapshot rather than a new incident; worth a fresh-discovery re-check), `routemax/api` + `routemax/etl` (276 items, all intact), an unknown repository name (correctly rejected), and a deployed-but-clean repository (correctly passed). One bug fixed during testing: a jq `index()` call was evaluating `.repository` against the wrong input after a pipe — the same class of scoping mistake fixed twice earlier in this file; worth grepping for `| index(.` before trusting a new filter like it again |
| 2026-09-11 | Report split into three HTML files, on request ("break the report into 3: summary, deleted, protected; add per-cluster/namespace deployed-version detail; wire the validation tool into the report as opt-in"). `lib/discover-k8s.sh` gained a real fix along the way: `_dk8s_refs_from_kubectl_json` walked the whole `kubectl get -A` document in one `..` pass, so `metadata.namespace` was never attached to a pod or workload entry (only Helm history had it, embedded in `detail`) — every `sources[]` entry now carries an explicit `namespace` (pods/workloads via a new per-item `namespace<TAB>ref` contract into `_dk8s_refs_to_entries`; Helm history the same way, via an `awk` prefix in `_dk8s_helm_release_entries`). `result.json` stays one file; `report.sh` now writes `report-summary.html` (stats, executive summary, run details, registry before/after, skipped reasons, locks, a flat warnings/errors list), `report-deleted.html` (repositories, never-deleted, deleted/would-be-deleted) and `report-protected.html` (protection totals + cluster reachability, a new "Deployed versions and protected previous versions" table grouped from `sources[]` by cluster/namespace/repository, the structured cluster-warning tables moved out of the old combined section, and — opt-in — post-cleanup validation). The three pages share one `_REPORT_JQ_DEFS`/`_REPORT_CSS` and cross-link each other. New `acr-cleanup.sh --validate-after` flag adds stage 6 (renumbering report to 7 and notify to 8): runs `tools/audit-running-images.sh --skip-discover` against this run's own just-discovered `protection-set.json` (no second cluster crawl) right before the report, so a broken/unreadable running image surfaces in `report-protected.html` and as a status card in `report-summary.html`, and makes the run's exit code non-zero without suppressing the report. `audit-running-images.sh` gained `--out-json` (a structured `{totals, items}` summary — only non-`ok` items, since a clean run can have thousands — written alongside its unchanged stdout) for `report.sh` to read via `validation-result.json`. 42 discover-k8s tests (up from 38) and 65 report tests (up from ~55) pass; full suite otherwise unchanged. Not yet checked against real `rmxacrcommon` clusters — only the existing synthetic fixtures |
| 2026-09-11 | **Second product onboarded: DockAi** (`config/dockai.yaml`, registry `dockacrnp`). Tag rules derived from `generateSemanticVersion.py`: `<year>.<month>.<run>-<suffix>.<attempt>`, PR builds are literally `-pr.N` (no PR number in the tag), plus `alpha`/`rc`/`devops-*`/`bug-*`/`hotfix-*` and a plain `year.month.run` on main. Running it exposed four bugs in the module, all fixed: (1) `--repository` (singular) was only read by `--operation inventory`; with any other operation it was dropped and the "targeted" run inventoried all 31 repositories — now treated as `--repositories` with a warning. (2) Ctrl+C never stopped the forked inventory workers (async subshells in a non-interactive shell ignore SIGINT, as do the curls they exec); `install_interrupt_handler` in `lib/common.sh` now kills the descendant tree, deepest first, and exits 130 — descendants only, never the process group, so a pipeline agent sharing the group is safe. (3) `_acr_http` appended `000` to curl's own `%{http_code}` output on a transport failure, producing `200000` / `000000`: not 2xx, not in the retry list, so one reset mid-run failed the whole inventory with no retry and a message that did not say why — two 20-minute live runs on `config-api` died this way on different, individually healthy digests. The exit code now decides, and the failure message carries the real status plus how many lookups had succeeded. (4) Index-children resolution was one round trip at a time per repository and rewrote a growing JSON on every iteration (O(n²)); DockAi pushes every build as an index (platform + buildx attestation), ~4,000 per busy repository, i.e. 20+ minutes per repository. Now `run_settings.parallel_reference_lookups` (default 8, 1–32) forked lookups per repository, one result file each, assembled once. Test suites: acr-api 59 → 69, acr-cleanup 15 → 20, config +2. Also observed on DockAi: the access token exchanged from the refresh token lives 4,500 s (cached for 1,800 s), so token expiry was ruled out as the cause |

| 2026-09-04 | Tasks 11–12 in progress: pipeline template + RouteMAX wrapper written (not yet created in ADO); `helm.yaml` publishes the module for the release task group. Design change: the weekly reconciler is **unlock-only**; deploy time is the only lock writer, so a lock always means "deployed to a lock_at_deploy environment". Lock = `deleteEnabled:false` on tag and manifest, `writeEnabled` untouched |
| 2026-09-12 | DockAi `pull_request_builds.delete_when_older_than_days` lowered 30 → 7 by Arun after a size review found PR-build tags were 72–73% of `dockacrnp`'s footprint at 2.26 TB, almost all within the 30-day window. Cleanup run after the change: 2.26 TB → 1.40 TB |
| 2026-09-13 | `develop_builds` and `main_builds` `delete_when_older_than_days` lowered 90 → 30, after age-bucketing showed 192 GiB of `develop_builds` and 266 GiB of `main_builds` sitting in the 30–90 day range with no corresponding production environment yet to justify a 90-day rollback window. First run after the change untagged 3,382 tags (1,297 develop + 2,085 main, ~455 GiB) but swept almost nothing (`sweep_candidate_bytes` 22 KB) — see the resolved Phase-1 checks above for why: `min_untagged_manifest_age_days` gates on push-time age, not orphan age, so this batch won't sweep until it's *also* old enough by push time. Confirmed live against `dockacrnp` (`az acr repository untag` on `dummy-outbox-ordering-check:2026.8.537-devops-264651-5.1`, `lastUpdateTime` unchanged before/after by digest via `az acr manifest list-metadata`). `min_untagged_manifest_age_days` left at 7 for DockAi — no longer treated as a post-orphan grace period, just aligned with the weekly-ish run cadence and the `pull_request_builds` window |
| 2026-09-13 | DockAi `always_keep_newest` lowered across every `image_cleanup_rules` group (all were 10; legacy groups already 3): `develop_builds` → 0 (Arun: DockAi no longer uses the develop branch, so there is nothing left to protect there regardless of age), everything else (`pull_request_builds`, `release_builds`, `main_builds`, `devops_builds`, `bugfix_builds`, `hotfix_builds`, `feature_branch_builds`) → 3, matching the legacy groups. Driven by the 2026-09-13 age-bucket analysis showing every live `develop_builds` tag was already past its 30-day retention and being kept solely by the `always_keep_newest: 10` floor (37 GiB), plus a smaller equivalent floor (18 GiB) on already-expired `main_builds` tags |
| 2026-09-13 | Arun made three further DockAi config edits directly, same session: `release_builds` and `hotfix_builds` `delete_when_older_than_days` 90 → 30, matching `main_builds`/`develop_builds` under the same "no production environment yet" reasoning; and all six `legacy_*` groups' `always_keep_newest` 3 → 0, correcting the value set two entries above — those groups' own header comment already says the pre-`generateSemanticVersion.py` tag scheme is dead and nothing new is built with it, so there is no live scheme left to protect a keep-newest floor for. Config re-validated, loads clean |
| 2026-09-13 | **Bug found and fixed: `acr_inventory_all` could silently drop a repository from `inventory.json`.** Arun observed 3 separate runs where `classify` appeared to start before `inventory` had finished the last repository, and on the most recent one `webupdater-api` (the largest repository, 600 tags / 4,065 manifests) never appeared in `inventory.json` at all, so it was never cleaned that run — no error, no warning. Confirmed by comparing file mtimes: `inventory.json` (03:12:44) was written 78 seconds before `inventory/webupdater-api.json` (03:14:02) finished. Root cause in `lib/acr-api.sh`: the per-repository forking loop tracked outstanding jobs with a plain integer counter decremented via untargeted `wait -n` (no PID ever captured with `pids+=($!)`), and `acr_inventory_merge` only checked that *some* file existed in the inventory directory, not one per expected repository — it globbed whatever was on disk at the instant it ran. If the counter and reality ever drifted by one, the merge could run one repository early, and the straggler (naturally the biggest/slowest job) silently vanished. Same unguarded `count` + `wait -n` pattern also exists at `lib/acr-api.sh:341-360` (`_acr_backfill_index_references`, per-repo index-reference parallelism) — not touched by this fix, flagged as a follow-up since it runs inside each repository's own subshell rather than across repositories. Fixed both ends: (1) `acr_inventory_all` now tracks every fork's PID in an array and waits on each one by name — nothing can be miscounted since every PID that was launched is explicitly waited on before the merge runs; (2) `acr_inventory_merge` takes an optional expected-repositories list and fails closed, naming exactly which repository is missing, if the merge output doesn't cover all of them (existing no-argument call site, the sharded-pipeline merge, is unchanged). Caught one more bug writing the merge's own test: `select(($have | index(.)) == null)` is a classic jq trap — `.` inside `index(.)` rebinds to `$have` after the preceding pipe, not to the element being tested, so the check silently found nothing missing, ever; fixed to `. as $w | select(($have | index($w)) == null)`. 2 new tests added: a batch-boundary inventory (5 repositories, `parallel_repo_jobs` 2) proving nothing is dropped or duplicated across multiple wait batches, and the merge fail-closed check itself. 76 acr-api tests pass (up from 69) |
