# Recording the accepted harness baselines

Plan 315 records five serial samples for each affected CSV after plan 321 acceptance.
`record.sh` copies the runner's selection, wall-time, `-j1`, 5% requested deviation,
ten-second timeout and `-N2` options. Projection alone enables `KEIRO_READ_MODEL_P95=1`.
Every timed cohort disables diagnostic probes and separates setup stderr from stdout.
Source must be committed; existing recording output is protected from overwrite.

`aggregate.py` validates every selected row and process status, preserves existing CSV
names/order/header, and derives each row's median mean and median two-standard-deviation
spread independently. It first emits candidates, original CSVs and range summaries;
`--apply` writes those validated candidates. No threshold is changed.

All five existing CSVs are affected. Command drops timed hard deletes and uses fresh bounded
identities, established statistics and settled selected setup. Inbox moves table/duplicate
preparation into its isolated selected fixture and warms representative work. Outbox gains
an isolated durable fixture and selected warm-up. Projection/read-model use the isolated
durable read-model fixture, representative stream cardinality and settled setup; projection
controls are adjacent and its P95 sampler is selection-specific. Thus even an old green
row must be re-recorded. These changes and the new machine prevent interpreting CSV movement
as a production before/after speedup.

All 25 processes completed at source `b8695a0d` between 08:56 and 09:16 UTC on
2026-10-25. `environment.txt` records the Apple M5 Ultra (36 logical CPUs, 256 GiB),
GHC 9.12.4, Cabal 3.16.1.0, PostgreSQL 18.6, binary/lock hashes and initial load.
`record.sh` is the exact invocation. The durable fixture has `fsync`,
`synchronous_commit` and `full_page_writes` enabled, with default checkpoint and
autovacuum behavior; selected setup checkpoints precede final warm-up. Seven migrated
clones separate logical workloads while sharing the disposable PostgreSQL server.

The accepted [harness evidence](../harness-isolation-v1/README.md) specifies the bounds
and retained growth/count probes. Command seeds 5,000 singleton streams; each fresh
single-event case allows 100,000 calls, each 100-event case 10,000, each fan-out case
100,000 emitted events and each silent case 1,000,000 calls. Rebuild uses the same
600 source events on every call, with 10,000 bookkeeping runs allowed. Read-model
setup seeds 25,000 events across 5,000 streams, with shared limits of 500,000 inline
commands, 1,000,000 async deliveries and 10,000 promotions. Reset-based outbox/inbox
actions retain their fixed per-call workload. Bound failures invalidate a sample.

Aggregation validated all selected names (15 command, 3 outbox, 49 inbox, 12 projection,
10 read-model) and preserved the existing baseline inventories (15/3/38/12/10).
`candidate-baseline.csv` and `summary.md` retain the resulting 78 medians and ranges;
`original-baseline.csv` retains every replaced row. No failed recording was discarded.
`controls.sh` runs the named command/inbox subset and then three serial complete guards
on the same benchmark source, recording binary/baseline hashes and process statuses.
The subset passes with exactly command/inbox statuses. All five CSV guards pass in each
of `control-full-1.txt`, `control-full-2.txt` and `control-full-3.txt`, establishing
same-source CSV reproduction and four consecutive inbox passes. Full-1/full-2 pass all
six guards; full-3 refuses producer fresh batch at 46.6/42.2 ms (>1.10×), with every
other guard zero and process exit 1. Preserve that failed cohort. Producer resolution and
three consecutive all-green summaries remain open; no CSV changes follow from that failure.

Build with `nix develop -c cabal build keiro:bench:keiro-bench`, then run `record.sh` inside
`nix develop`. After all 25 processes complete, run `aggregate.py` there to inspect the
candidates and then `aggregate.py --apply`. The recording revision must reproduce the new
rows under the unchanged 25% guard. Raw samples and source/environment evidence remain
beside each group. Failed or incomplete recordings must be retained and investigated.

## Accepted complete series

`accepted-controls.sh` retains a fresh three-run series at `4f2b4b69` after the producer
estimator correction and its added-cost refusal control. `accepted-full-1.txt` through
`accepted-full-3.txt` finish at 10:00:00, 10:08:06 and 10:15:56 UTC on 2026-10-25.
Each contains all six zero guard statuses, `BENCH_REGRESSION=PASSED` and `PROCESS_EXIT=0`.
The wrapper independently recomputes every paired median from the emitted 15 raw pairs.
Source, binary and all five baseline hashes are identical across the series. Batch paired
medians are 1.0568, 1.0618 and 1.0593; per-event medians are below 1.0, with 1.10 retained
for both. The older failed third control remains separate above. All CSVs remain the
same five-sample medians; no row or threshold moved in response to that producer failure.
This accepts plan 315, while plan 316's full release-gate red/green proof remains separate.
