# ACR Cleanup

Safe, config-driven cleanup for Azure Container Registry. Tags and manifests are only removed
when nothing running in Kubernetes (pods, workloads, retained Helm revisions) still uses them.

- **Read-only by default**: `operation: plan` and `dry-run: true` unless you say otherwise.
- **Two-phase delete**: untag first (reversible), sweep untagged manifests later (irreversible), with a configurable gap.
- **Protection from reality**: images found in your clusters are never deleted, regardless of age rules.
- **Circuit breaker**: `max_deletions_per_run` caps the blast radius of a bad rule.
- **Reports**: HTML and JSON, published as a workflow artifact and a job summary.

## Usage

```yaml
permissions:
  id-token: write
  contents: read

jobs:
  cleanup:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
      - uses: Optym/acr-cleanup-strategy@v1
        with:
          config: config/acr-cleanup.yaml
          operation: plan
```

Full scheduled example: [examples/scheduled-cleanup.yml](./examples/scheduled-cleanup.yml).
Start from [acr-cleanup/config/example.yaml](./acr-cleanup/config/example.yaml).

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `config` | required | Config YAML path |
| `operation` | `plan` | `validate-config`, `discover`, `inventory`, `plan`, `untag-stale-tags`, `sweep-untagged-manifests`, `untag-and-sweep` |
| `dry-run` | `true` | `true`, `false`, or `config` (use `run_settings.dry_run` from the file) |
| `work-dir` | `.acr-cleanup-work` | Stage output and reports |
| `previous-dir` | | Previous run's `result.json` and `lock-ledger.json` |
| `repositories` | | Limit to these repositories (comma-separated) |
| `tag-groups` | | Limit to these tag groups (comma-separated) |
| `validate-after` | `false` | Confirm running images are still pullable afterwards |
| `set` | | Newline-separated `path=value` config overrides |
| `extra-args` | | Raw extra arguments for `acr-cleanup.sh` |
| `upload-report` | `true` | Upload reports as an artifact |
| `artifact-name` | `acr-cleanup-report` | Artifact name |
| `sendgrid-api-key` | | Secret for `email_report` |

## Outputs

`status`, `deleted-count`, `untag-candidates`, `manifest-candidates`, `work-dir`.

## Requirements

- Runner with `az`, `jq`, and `yq` or `python3` (all present on `ubuntu-latest`); `kubectl`, `helm` and `kubelogin` for cluster discovery.
- Azure login before the action. The identity needs `AcrPull` + `AcrDelete` on the registry and read access to each listed cluster.
- Every cluster that pulls from the registry must be listed in the config; a missing cluster means its images are not protected.

## Documentation

Design: [acr-cleanup/README.md](./acr-cleanup/README.md) · Options: [CONFIGURATION](./acr-cleanup/CONFIGURATION.md) ·
Recovery: [RUNBOOK](./acr-cleanup/RUNBOOK.md) · Adoption: [ADOPTION](./acr-cleanup/ADOPTION.md)
