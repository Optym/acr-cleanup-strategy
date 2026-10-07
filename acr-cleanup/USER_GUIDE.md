# User guide: running the cleanup by hand

Read this before you schedule anything. The pipeline is the last step in maturity; the module is
designed to be run stage by stage on a laptop first, with every stage writing plain JSON you can
inspect. Nothing here mutates the registry unless you pass `--no-dry-run` (or set
`run_settings.dry_run: false`) **and** choose `--operation untag-stale-tags` or `sweep-untagged-manifests`.

Companion documents: [CONFIGURATION.md](./CONFIGURATION.md) for every option,
[RUNBOOK.md](./RUNBOOK.md) for recovery, [ADOPTION.md](./ADOPTION.md) to bring it to another
product.

## 1. Prerequisites on your machine

| Tool | Why | Check |
| --- | --- | --- |
| bash 4.4+ | `local -n`, associative arrays. macOS ships 3.2: `brew install bash` and run with `bash ./acr-cleanup.sh` or put Homebrew bash first on `PATH` | `bash --version` |
| `jq` | every stage | `jq --version` |
| `az` (Azure CLI), logged in | ACR token, `show-usage`, AKS credentials | `az account show` |
| `kubectl`, `helm`, `kubelogin` | discovery (stage 1) | `kubelogin --version` |
| `curl` | ACR REST, SendGrid | |
| `yq` **or** `python3` with PyYAML | reading the config | `python3 -c 'import yaml'` |
| Network line of sight to the AKS API servers | discovery in `kubectl` mode | `az aks get-credentials` + `kubectl get ns` |

Permissions: `AcrPull` on the registry for read-only stages, `AcrDelete` for `untag-stale-tags` / `sweep-untagged-manifests`
and for the deploy-time lock, `Reader` on the registry for the storage figure, and
`Azure Kubernetes Service Cluster User` plus a read-only Kubernetes role on each cluster.

## 2. First contact: validate the config

```bash
cd devops/acr-cleanup
./acr-cleanup.sh --config config/routemax.yaml --operation validate-config
./acr-cleanup.sh --config config/routemax.yaml --print-config | jq .run_settings
```

Touches nothing. Fails loudly on a bad regex, a shadowed rule (an example tag claimed by an earlier
rule), or an out-of-range number. Fix the config until it passes.

## 3. Run the stages one at a time

Every stage reads and writes `./.acr-cleanup-work/` (override with `--work-dir`). The log prints a
banner when a stage starts and ends, with its wall clock and headline numbers, and the same timings
land in `timings.json` and in the report.

### Stage 1: discover (read-only)

Builds the protection set: every image referenced by a running pod, a workload template, or one of
the last `keep_helm_revisions` Helm revisions, in every listed cluster.

```bash
# one cluster first
./acr-cleanup.sh --config config/routemax.yaml --operation discover --cluster rmx-aks-np-eus-c1
jq '{status, entries: (.entries | length), suspect_hosts, unlisted_clusters}' .acr-cleanup-work/protection/rmx-aks-np-eus-c1.json

# all clusters, then merged
./acr-cleanup.sh --config config/routemax.yaml --operation discover
jq '{clusters, tags: (.protected_tags | length), digests: (.protected_digests | length)}' .acr-cleanup-work/protection-set.json
```

What to check:

- every `required: true` cluster shows `status: ok`; otherwise the merge aborts on purpose
- the entry count per cluster is plausible (hundreds to thousands, not 0 or 5)
- `suspect_hosts` is empty; if not, add the host to `registry.host_aliases`
- spot-check a deployed image: `jq '.sources[] | select(.tag == "<a tag you know is running>")'`

Per cluster this takes 1 to 3 minutes; the Helm phase dominates.

### Stage 2: inventory (read-only)

Reads every repository's tags and manifests over the ACR REST API, with lock state.

```bash
# one repository first
./acr-cleanup.sh --config config/routemax.yaml --operation inventory --repository routemax/saiamockservice
jq '.tags[0], .manifests[0]' .acr-cleanup-work/inventory/routemax__saiamockservice.json

# the whole registry (386k tags: 10 to 20 minutes), then merged automatically
./acr-cleanup.sh --config config/routemax.yaml --operation inventory
jq '.totals' .acr-cleanup-work/inventory.json
```

`inventory.json` for `rmxacrcommon` is about 350 MB. Keep it; stages 3 to 7 can be re-run against it
with `--skip-inventory` while you tune the rules.

### Stage 3: classify, and the report (read-only)

```bash
./acr-cleanup.sh --config config/routemax.yaml --operation plan --skip-discover --skip-inventory
open .acr-cleanup-work/report-summary.html
```

`plan` runs classify and the report and skips the mutating stages. `report-summary.html`,
`report-deleted.html` and `report-protected.html` are all written together; read them in this order:

1. **`report-protected.html`, "Protection set"**: protection set size per cluster. Zero or tiny
   means discovery is broken. Stop.
2. **`report-protected.html`, "Cluster warnings"**: unreachable optional clusters, unlisted
   clusters, suspect hosts.
3. **`report-summary.html`, "Skipped tags, by reason"**: `protected` should account for every
   deployed tag. Pick three images you know are running and confirm them:

   ```bash
   grep -F '"tag":"5.5.0-beta.1-136"' .acr-cleanup-work/decisions.jsonl
   ```

   Or check the same thing at a glance in `report-protected.html`, "Deployed versions and protected
   previous versions" — one row per cluster/namespace/repository.
4. **`no-matching-rule` count** (`report-summary.html`, "Skipped tags, by reason"): large means the
   rules are too narrow; check the samples.
5. **Candidates by group** (`report-summary.html`, "Skipped tags, by reason"): does the split look
   like the registry you know?
6. **`report-deleted.html`, "Never-deleted repositories"**: confirm they never appear as candidates.
7. **`report-summary.html`, "Image locks"**: on a first run expect a large orphan-lock backlog;
   that is the old lock-forever residue.

Tune, then re-run `plan` with `--skip-discover --skip-inventory` (seconds to a minute). Overrides
without editing the file:

```bash
./acr-cleanup.sh --config config/routemax.yaml --operation plan --skip-discover --skip-inventory \
  --set rule.pull_request_builds.delete_when_older_than_days=14 \
  --tag-groups pull_request_builds
```

### Stage 4 and 5: lock reconcile and execute, dry run

```bash
./acr-cleanup.sh --config config/routemax.yaml --operation untag-stale-tags --skip-discover --skip-inventory --dry-run
jq '.totals' .acr-cleanup-work/lock-result.json
jq '.totals' .acr-cleanup-work/delete-result.json
```

With `dry_run: true` (the shipped default) both stages log what they would do and mutate nothing.
`report-deleted.html`'s deleted section is titled "Would be deleted (dry run)" and lists every item.

### Stage 5 for real, one group, capped

Only after two clean dry runs. Start with the highest-volume, lowest-risk group and a low cap:

```bash
./acr-cleanup.sh --config config/routemax.yaml --operation untag-stale-tags \
  --skip-discover --skip-inventory \
  --no-dry-run --tag-groups pull_request_builds --set run_settings.max_deletions_per_run=500
```

Untagging is reversible for `min_untagged_manifest_age_days`; [RUNBOOK.md](./RUNBOOK.md) section 2
shows how. Do **not** run `--operation sweep-untagged-manifests` for real until the untag phase has run for at least
two cycles and every report looked right; the sweep is the point of no return.

### Targeted cleanup: one or a few repositories

When the registry is large, work one repository at a time. `--repositories` limits stages 2 to 6
to the named repositories; discovery still covers every cluster.

```bash
./acr-cleanup.sh --config config/routemax.yaml --operation plan --repositories routemax/ui
./acr-cleanup.sh --config config/routemax.yaml --operation untag-stale-tags --no-dry-run \
  --repositories routemax/ui --skip-discover --skip-inventory
```

The inventory then holds only those repositories (about a minute for a 10k-tag repository), and
the report header shows `repositories: routemax/ui`. A repository name that does not exist in the
registry fails the run rather than silently doing nothing. The pipeline exposes the same as the
`repositories` parameter. The singular `--repository <name>` is the pipeline's inventory-shard
flag; with any other operation it is treated as `--repositories <name>` (and says so), instead of
being ignored and inventorying the whole registry as it once did.

**Registries where every build is an OCI index** (DockAi: buildx with the docker-container driver
attaches an attestation manifest to every image) cost one extra lookup per tag at inventory time,
because ACR's bulk listing never returns an index's children. That phase runs
`run_settings.parallel_reference_lookups` (default 8) calls at a time per repository and logs
progress every 500; a repository with 4,000 indexes takes a few minutes rather than 20+. Lower it
on HTTP 429.

**Stopping a run**: Ctrl+C (or a pipeline cancel) stops the forked workers too and exits 130. A
run interrupted before stage 5 has changed nothing; one interrupted during stage 5 has applied
whatever untags or deletes had already succeeded, and the next `plan` shows the rest.

### Stage 6, 7 and 8

The report (stage 7) is produced by every operation except `discover` and `inventory`, even when a
stage failed. Stage 6 (post-cleanup validation) only runs with `--validate-after` — see
[§6](#6-post-cleanup-validation). Email (stage 8) is opt-in through `email_report`; locally, set the
key in the environment named by `email_report.api_key_variable`.

## 4. Reading the work directory

| File | Written by | Size on rmxacrcommon |
| --- | --- | --- |
| `config.json` | config load | 5 KB |
| `protection/<cluster>.json`, `protection-set.json` | stage 1 | 2.5 MB |
| `inventory/<repo>.json`, `inventory.json` | stage 2 | 350 MB |
| `plan.json` | stage 3 | candidates + samples, tens of MB |
| `decisions.jsonl` | stage 3 | one line per tag and manifest, ~100 MB, grep-able |
| `lock-result.json`, `lock-ledger.json`, `unlock-events.jsonl` | stage 4 | small |
| `delete-result.json`, `execute/` | stage 5 | proportional to candidates |
| `validation-result.json` | stage 6, opt-in (`--validate-after`) | small |
| `result.json`, `report-summary.html`, `report-deleted.html`, `report-protected.html` | stage 7 | a few MB |
| `timings.json`, `errors.jsonl` | orchestrator | small |

`.acr-cleanup-work/` is git-ignored.

### What each stage actually decides

Full detail (with a diagram) is in [README.md §3](./README.md#3-execution-flow) and
[§4](./README.md#4-protection-layers); this is the short version so the file table above makes sense:

- **Stage 1 (discover)** does not decide anything — it just lists every image that is running right
  now or is one Helm rollback away, per cluster, into `protection-set.json`. Nothing here is ever a
  candidate for deletion.
- **Stage 2 (inventory)** does not decide anything either — it is a full, truthful catalogue of every
  tag and manifest in the registry, into `inventory.json`. This is also where a multi-arch image's
  real child manifests get resolved (see [README.md §4](./README.md#4-protection-layers)); nothing
  downstream can protect a child it does not know about.
- **Stage 3 (classify)** is where every real decision is made, one tag/manifest at a time, checked in
  this order — the first check that *keeps* the item wins and becomes its `reason`:
  `never_delete` → cleanup rule match → protection set (stage 1's output) → lock → `always_keep_newest`
  → `delete_when_older_than_days`. The result for every single tag and manifest, not just the
  survivors, is written to `decisions.jsonl` — one JSON line each, so a specific image's fate is one
  grep away:
  ```bash
  grep '"tag":"5.2.0-alpha.57"' .acr-cleanup-work/decisions.jsonl
  ```
  `plan.json` is the same decisions grouped into what stage 5 will actually act on.
- **Stage 4 (lock-reconcile)** only ever unlocks, never locks (locks are added at deploy time by
  `deploy/lock-deployed-images.sh`). It writes its own per-attempt trail to `unlock-events.jsonl`
  in addition to the summary in `lock-result.json`.
- **Stage 5 (execute)** does not decide anything new — it just carries out what stage 3 already
  decided in `plan.json`, and skips anything still locked at that point even if stage 4 unlocked it
  moments earlier in the same run (a deliberate one-run lag, so every unlock shows up in a report
  before it can be acted on).
- **Stage 6 (validate, opt-in)** re-checks pullability of everything this run protected, against the
  registry, using `tools/audit-running-images.sh --skip-discover` — see [§6](#6-post-cleanup-validation).
- **Stage 7 (report)** turns all of the above into `result.json` and the three `report-*.html`
  files for humans; `report-summary.html`'s "Skipped tags, by reason" is the fastest way to see
  *why* a specific image was or was not touched without reading `decisions.jsonl` by hand.

## 5. The pipeline, when you are ready

[build/Maintenance/acr-cleanup-routemax.yaml](../../build/Maintenance/acr-cleanup-routemax.yaml)
runs exactly the sequence above: one Discover job per cluster, six Inventory shards, one Execute
job. Create the pipeline definition from that file, run it manually with `operation: plan` a couple of
times, then with `operation: untag-stale-tags` and `dryRun: false`, and only then enable the schedules. Each run
publishes the work-directory files above as the `report` artifact.

## 6. Post-cleanup validation

After any real `untag-stale-tags`, `sweep-untagged-manifests` or `untag-and-sweep` run, verify that
nothing actually running was broken. This is not optional colour: it is what would have caught the
2026-09-06 incident (see [progress.md](./progress.md)) same-day instead of the next morning, and it
takes minutes, not a production outage.

```bash
# the one to run after every real cleanup: is everything ACTUALLY RUNNING still
# fully pullable? Scoped to what is deployed, so it is fast.
tools/audit-running-images.sh --config config/routemax.yaml

# just the repositories a run touched, or that an incident already named
tools/audit-running-images.sh --config config/routemax.yaml   --repositories routemax/keycloak,routemax/api,routemax/calculate-pse

# reuse the discovery a cleanup run just finished, in the same work-dir, instead
# of discovering the clusters again (faster, but only as fresh as that run)
tools/audit-running-images.sh --config config/routemax.yaml   --work-dir .acr-cleanup-work --skip-discover
```

It checks every tag and digest the current cluster fleet depends on (running pods, workload
templates, and retained Helm revisions — the same set stage 1 protects) directly against the
registry: does the tag still resolve, does its manifest still exist, and if it is a multi-arch
image, do all of its child manifests still exist. A `BROKEN` line names the repository, tag,
cluster(s) affected, and exactly what is missing; the exit code is non-zero if anything is broken,
so it can gate a pipeline later if you want that. Read-only throughout.

**Or let the orchestrator do it for you**: pass `--validate-after` to `acr-cleanup.sh` itself. It
runs this same tool with `--skip-discover` right after execute, against the protection set this run
already discovered — no second live cluster crawl — and folds the result into
`report-protected.html`'s "Post-cleanup validation" section (plus a one-line status card on
`report-summary.html`). A broken image makes the run's exit code non-zero without suppressing the
report:

```bash
./acr-cleanup.sh --config config/routemax.yaml --operation untag-stale-tags --no-dry-run \
  --validate-after --tag-groups pull_request_builds
```

For a broader, registry-wide sweep — every currently tagged multi-arch image, not only what is
deployed right now — use `tools/audit-multiarch-references.sh` instead (slower, since it lists
every manifest in every repository rather than only the ones in use). Run it after a fix or a
config change you are not fully confident in, or periodically as a health check independent of any
one cleanup run.

## 7. The tests

Every `tests/*.test.sh` is pure: Azure, Kubernetes and SendGrid are stubbed with shell functions, so
they run anywhere with bash 4.4+ and `jq`, in about two minutes total.

```bash
for t in tests/*.test.sh; do bash "$t"; done      # all
bash tests/classify.test.sh                       # one suite
KEEP_REPORT=/tmp/r.html bash tests/report.test.sh # keep the rendered sample report
```

When to run them:

| Situation | Run |
| --- | --- |
| You changed a rule or a pattern in the config | Nothing to run: `validate-config` is the test, via `example_tags` |
| You changed any file under `lib/`, `deploy/` or `acr-cleanup.sh` | The suite for that file, then all of them |
| Something behaved unexpectedly in a live run | Reproduce it as a fixture in the matching suite first; the suites are the specification |

Each suite prints `ok`/`FAIL` per case and a final `N passed, M failed`; a non-zero exit means a
failure. [CONTRIBUTING.md](./CONTRIBUTING.md) explains how a suite is built and how to add a case.
