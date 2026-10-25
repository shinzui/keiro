# Workflow inspection query evidence v2

These 136 retained EXPLAIN (ANALYZE, BUFFERS, SETTINGS) captures execute the actual
library-prepared inspection statement at 10,000 and 100,000 rows, with forced
custom and generic plans and normal planner choices. The normal fixture adds two
valid wide-key rows; the wide fixture gives every row a 2,700-byte-plus ID.

Source: parent `85fbdce6` plus [the workflow source patch](source.patch), applied with `git apply --unidiff-zero`. The marker
`/* keiro-inspection-page-v2 */` identifies the real statement on the same one-connection
pool that prepared it. Every artifact includes SQL, EXECUTE arguments, row count,
PostgreSQL version, durable settings, buffers, scan/filter work and elapsed time.
No writer statement, schema, index or migration is changed.

First and deep unfiltered key pages use the primary key and return 21 candidates
for a 20-item page with zero residual-filter removals. The outer materialized page
may sort those 21 rows for response order; it never sorts the ledger in key order.
Creation order and sparse/absent filters retain their larger scan/search costs.
Name-only reads can use the primary key in a skip scan but still examine ledger
index ranges; a zero residual-filter count does not imply page-sized work.

The captures overlapped development verification. Times characterize these query
plans and are not a release writer-capacity gate or a universal latency bound.
Retain host SQL/read deadlines and measured workload/cadence limits for filtered
automatic views. The HTTP defaults are a 2-second SQL timeout and 5-second read
deadline; automatic timers retain a five-second minimum interval.

## 100,000-row execution times (milliseconds)

| Case | Normal custom | Normal generic | Wide custom | Wide generic |
|---|---:|---:|---:|---:|
| absent-class | 3.270 | 3.525 | 5.881 | 7.867 |
| absent-name | 1.625 | 1.517 | 2.338 | 2.244 |
| created-deep | 18.992 | 18.699 | 147.351 | 141.080 |
| created-first | 21.043 | 22.491 | 189.380 | 176.401 |
| created-rare-status | 0.080 | 0.048 | 0.067 | 0.062 |
| created-window | 13.219 | 9.472 | 79.402 | 58.877 |
| key-deep | 0.032 | 0.036 | 0.052 | 0.056 |
| key-first | 0.043 | 0.032 | 0.041 | 0.041 |
| key-past-wide | 0.022 | 0.020 | 0.015 | 0.016 |
| mixed-class | 0.039 | 0.045 | 0.040 | 0.036 |
| rare-status-deep | 0.072 | 0.077 | 0.102 | 0.090 |
| rare-status | 0.099 | 0.131 | 0.167 | 0.149 |
| running-class | 0.040 | 0.032 | 0.042 | 0.037 |
| small-name-rare | 0.079 | 0.050 | 0.036 | 0.036 |
| small-name | 1.467 | 1.207 | 2.293 | 2.272 |
| update-window | 4.553 | 7.349 | 12.295 | 8.276 |
| wide-name | 1.487 | 1.739 | 0.135 | 0.131 |

## Reproduce

```bash
nix develop -c cabal build keiro keiro-test-support
nix develop -c cabal exec -- runghc -XGHC2024 -package=keiro -package=keiro-test-support scripts/inspection-query-evidence.hs /tmp/keiro-query-v2
nix develop -c cabal exec -- runghc -XGHC2024 -package=keiro -package=keiro-test-support scripts/inspection-query-evidence.hs /tmp/keiro-query-v2-wide wide
```

The driver validates successful pages and supported continuation-size refusals.
Old `wf-key` default tokens fail closed; new key tuples are `(workflow_id,workflow_name)`.
Creation cursor kinds and the released legacy listing API retain their contracts.
