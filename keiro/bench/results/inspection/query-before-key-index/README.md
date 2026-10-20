# Workflow inspection query-cost checkpoint

Captured from the actual prepared statements installed by the supported library reads. The probe uses durable ephemeral PostgreSQL, normal planner settings, and both forced prepared-plan modes. Each plan is one execution after the library read warmed/prepared it. These are rejection evidence; they do not satisfy the matched runtime interference or index-write gate.

| 100,000 rows, generic plan | Execution ms | Rows processed by data scan |
|---|---:|---:|
| key-first | 8.458 | 100000 |
| key-deep | 2.998 | 20000 |
| created-first | 0.017 | 21 |
| created-deep | 0.022 | 21 |
| rare-status | 4.208 | 100000 |
| update-window | 3.901 | 100000 |

The creation-order index supports first and deep pages with 21 scanned rows. The default key order and rare-status filter examine the full ledger. The physical primary key is `(workflow_id, workflow_name)`, whereas the page contract orders `(workflow_name, workflow_id)`. The creation index alone is insufficient. Updated windows are unindexed. Matching ordered/filter access and normal schedule/claim/resume write/WAL evidence are still required before EP-2 completion or automatic feed acceptance.

Reproduce from the repository root inside the Nix shell:

```bash
nix develop -c cabal exec -- runghc -XGHC2024 -package=keiro -package=keiro-test-support scripts/inspection-query-evidence.hs /tmp/keiro-inspection-query-evidence
```
