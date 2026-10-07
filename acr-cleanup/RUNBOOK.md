# Runbook: operating the cleanup and recovering images

For people on call for `myregistry`. The architecture is in [README.md](./README.md); this file is
what to do when something needs doing.

## 1. Where the evidence is

Every pipeline run publishes a `report` artifact. Open it in this order:

| File | What it answers |
| --- | --- |
| `report-summary.html` | Stats and the executive summary, for humans. Start here |
| `report-deleted.html` | What was, or would be, deleted, and why |
| `report-protected.html` | What is protected — per cluster/namespace deployed and rollback versions — plus the opt-in post-cleanup validation result |
| `result.json` | Same data as the three HTML files, machine-readable. Section `deleted.items` is the **recovery catalogue** |
| `validation-result.json` | Only present when the run used `--validate-after`: broken/unreadable running images found after cleanup |
| `decisions.jsonl` | One line per tag and manifest with its reason. `grep -F '"tag":"<tag>"'` answers "why was my image (not) deleted" |
| `plan.json` | Candidates, samples per skip reason, every locked item with its protection status |
| `protection-set.json` | Every image reference found running or in Helm history, per cluster and namespace |
| `lock-result.json`, `lock-ledger.json` | What the reconciler did, and the first-seen-unprotected clock it carries to the next run |
| `delete-result.json` | Every attempted mutation with HTTP status |
| `config.json` | The effective config the run used (its hash is in the report header) |

Runs are leased for 365 days so the catalogue outlives the recovery window. A run's URL is in the
report header.

## 2. Recovering an image

### 2.1 A tag was untagged that should not have been

The manifest and its layers still exist until the manifest sweep reaches it, which cannot happen
before `min_untagged_manifest_age_days` (14) after the untag. Act inside that window.

1. Find the item in `result.json` of the untag run:

   ```bash
   jq -r '.deleted.items[] | select(.tag == "5.5.0-beta.1-136") | "\(.repository) \(.digest)"' result.json
   ```

   Or across all published runs, from `decisions.jsonl`:

   ```bash
   grep -F '"tag":"5.5.0-beta.1-136"' decisions.jsonl
   ```

2. Put the tag back from the digest (needs `AcrPush` on the registry):

   ```bash
   az acr import -n myregistry \
     --source myregistry.azurecr.io/myproduct/api@sha256:<digest> \
     -t myproduct/api:5.5.0-beta.1-136
   ```

   `az acr import` from the same registry is a metadata operation; no layers are copied.

3. Confirm:

   ```bash
   az acr repository show -n myregistry --image myproduct/api:5.5.0-beta.1-136
   ```

4. Stop it happening again: add the tag to `never_delete.tag_patterns`, tag it `…-donotdelete`, or
   fix the rule. Add the tag to that rule's `example_tags` if the rule was wrong, so the config
   refuses the mistake next time.

### 2.2 The manifest was already swept

**Not recoverable from the registry.** There is no soft delete on this registry (blocked by
geo-replication). Options:

- Rebuild from source: the tag encodes the build (`5.5.0-beta.1-136` is Full Build run 136 on
  `release/5.5.0`); re-run that pipeline or rebuild the commit.
- Check the West US replica is not a separate copy: it is not, geo-replication mirrors deletes.
- Then establish why two reports showed the item without anyone acting: was the tag in a group that
  should have had a longer retention, or missing from the protection set because a cluster was not
  listed?

### 2.3 Many tags, one repository

```bash
jq -r '.deleted.items[] | select(.repository == "myproduct/api") | "\(.digest) \(.tag)"' result.json \
| while read -r digest tag; do
    az acr import -n myregistry --source "myregistry.azurecr.io/myproduct/api@${digest}" -t "myproduct/api:${tag}"
  done
```

### 2.4 The whole run was wrong

Restore every untagged item from that run:

```bash
jq -r '.deleted.items[] | select(.status == "untagged") | "\(.repository) \(.digest) \(.tag)"' result.json \
| while read -r repo digest tag; do
    az acr import -n myregistry --source "myregistry.azurecr.io/${repo}@${digest}" -t "${repo}:${tag}" || echo "FAILED ${repo}:${tag}"
  done
```

Then set `run_settings.dry_run: true` (or disable the schedules) before the next Saturday.

## 3. Stopping the cleanup

| Need | Action |
| --- | --- |
| Stop everything now | Disable both schedules on the `acr-cleanup-myproduct` pipeline. Nothing else runs on its own |
| Keep running but mutate nothing | `run_settings.dry_run: true` in the config, merged to `develop` |
| Stop only the irreversible part | Disable the "Weekly manifest sweep" schedule; untag keeps running |
| Protect one image | Tag it `<tag>-donotdelete` (never deleted, never unlocked), or add it to `never_delete.tag_patterns` |
| Protect a repository | `never_delete.repositories` |

## 4. Symptoms and actions

| Situation | Action |
| --- | --- |
| Run aborted: required cluster unreachable | Intentional fail-closed. Check the agent's line of sight to the private API server and the service connection. Re-run; nothing was mutated |
| Run aborted: protection set empty | Discovery returned nothing. Check `registry.host_aliases` against the hosts in the pod specs and the `suspect_hosts` warning |
| Test cluster parked / stopped | Set `required: false` on it |
| New cluster in the report's unlisted-cluster warning | Add it to `in_use_protection.clusters` and to the pipeline wrapper's `clusters` |
| Deploy step exit code 2 (some images not locked) | The running pod protects them. Re-run the step or ignore; a lock is never required for safety |
| `skipped:changed-since-plan` in the sweep | A tag or lock landed on the manifest between inventory and delete. Re-evaluated next run |
| `skipped:over-cap` | `max_deletions_per_run` reached. Expected during backlog draining; raise it or run more often |
| HTTP 429 in the log | Lower `run_settings.parallel_delete_workers` |
| Discovery slow or throttled | Lower `in_use_protection.helm_parallelism` |
| Orphan locks never unlock | The previous run's `report` artifact is not being downloaded, so every run is a first sighting. Check the Execute job |
| Storage did not drop after untag | Expected. Only the manifest sweep reclaims storage |
| Email not received | `email_report.enabled`, recipients, and the `SENDGRID_API_KEY` secret mapping. The artifact is always there regardless |
| A tag still shows in the portal but the pod says `ImagePullBackOff` | The tag's manifest is a multi-arch index whose child was swept. See [section 6](#6-a-tag-exists-but-imagepullbackoff-anyway-multi-arch-children) |

## 5. Checking a specific image by hand

```bash
# is it running anywhere, according to the last run?
jq -r '.sources[] | select(.repository == "myproduct/api" and .tag == "5.5.0-beta.1-136")' protection-set.json

# what did the classifier decide?
grep -F '"repository":"myproduct/api"' decisions.jsonl | grep -F '"tag":"5.5.0-beta.1-136"'

# is it locked?
az acr repository show -n myregistry --image myproduct/api:5.5.0-beta.1-136 --query changeableAttributes
```

## 6. A tag exists but `ImagePullBackOff` anyway (multi-arch children)

**Symptom:** the tag is visible in the portal, its digest resolves, but pods fail to pull it with
`ImagePullBackOff`, on a tag that was working before.

**What is going on:** a multi-architecture image (built with `docker buildx build`, common for images
with provenance/SBOM attestations enabled) is not a single manifest. The tag points at an **OCI image
index**, a small document that lists the real, pullable platform manifest and an attestation manifest
as children, each its own object in the registry with its own digest. If a child is deleted, the tag
and the index both still exist and look fine, but the pull fails resolving the child.

**This happened for real** on 2026-09-05: the manifest sweep deleted the children of every
still-tagged multi-arch image in the registry (109 of 112, across 34 repositories) because Azure
Container Registry's bulk manifest-listing API does not return the parent/child relationship for an
index - it comes back empty even when the index genuinely has children, and the tool's classifier
trusted that field. Fixed in `lib/acr-api.sh` (inventory now resolves the real reference graph with a
per-manifest lookup, and aborts rather than proceeding if that lookup fails).

**Diagnose a specific tag by hand** (read-only, needs `AcrPull`):

```bash
REPO=myproduct/keycloak
TAG=5.2.0-alpha.57

RT=$(az acr login --name myregistry --expose-token --only-show-errors -o json | jq -r .accessToken)
AT=$(curl -sS -X POST "https://myregistry.azurecr.io/oauth2/token" \
  --data-urlencode "grant_type=refresh_token" --data-urlencode "service=myregistry.azurecr.io" \
  --data-urlencode "scope=repository:${REPO}:metadata_read,pull" --data-urlencode "refresh_token=$RT" \
  | jq -r .access_token)

# the tag's manifest (the index) - note its digest and mediaType
INDEX=$(curl -sS -H "Authorization: Bearer $AT" \
  "https://myregistry.azurecr.io/acr/v1/${REPO}/_tags/${TAG}" | jq -r '.tag.digest')

# the index's real children (only a per-digest GET returns these - the bulk
# listing does not, which is exactly the bug above)
curl -sS -H "Authorization: Bearer $AT" \
  "https://myregistry.azurecr.io/acr/v1/${REPO}/_manifests/${INDEX}" \
  | jq -r '.manifest.references[]?.digest' \
| while read -r child; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $AT" \
      "https://myregistry.azurecr.io/acr/v1/${REPO}/_manifests/${child}")
    echo "$child -> HTTP $code"
  done
```

A `404` on any child confirms this failure mode. There is no soft delete on this registry, so a
swept child is **not recoverable** - rebuild the image under a new tag and redeploy to that; then
untag the broken one so nothing can accidentally redeploy to it (`az acr repository untag -n
myregistry --image "${REPO}:${TAG}"`).

**Find every other tag in this state before it causes an outage.** Two read-only tools, both
covered in [USER_GUIDE.md §6](./USER_GUIDE.md#6-post-cleanup-validation):

- `tools/audit-running-images.sh` — checks only what is actually deployed right now (running pods,
  workload templates, retained Helm revisions). Fast; this is the one to run after every real
  cleanup, and the one to run first when chasing a live incident like this
- `tools/audit-multiarch-references.sh` — checks every currently tagged multi-arch image
  registry-wide, deployed or not. Slower; use it for a full health check or after a fix you want to
  validate broadly
