# Instructions for AI coding agents

This folder is a self-contained bash + jq module. Before changing anything:

1. Read [CONTRIBUTING.md](./CONTRIBUTING.md) section 2 ("Where to change what") and open only the
   file it names and the matching `tests/<name>.test.sh`.
2. Keep stdout for data and stderr for logs; pass large JSON through files, never `--argjson`.
3. Add or adapt a test case, then run `bash tests/<name>.test.sh`. All suites: `for t in tests/*.test.sh; do bash "$t"; done`.
4. Never rename skip-reason strings, work-dir file names or config keys.
5. Update the document that owns the change (table at the end of CONTRIBUTING.md).

Nothing in the tests touches Azure. A live check is `./acr-cleanup.sh --config config/myproduct.yaml --operation plan --skip-discover --skip-inventory`, which is read-only.
