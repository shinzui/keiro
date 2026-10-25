# Harness isolation evidence

Work in progress for [plan 321](../../../../docs/plans/321-isolate-the-keiro-bench-harness-so-each-guard-measures-only-its-own-fixture.md).
No baseline or producer threshold is changed here. Exploratory logs below precede
acceptance and must not be represented as passing baseline measurements.

`list-tests.log` lists every name in all five committed CSVs and contains no
`BENCH_SETUP` events. `rebuild-probe.log` reports six successive rebuilds of exactly
600 source events. `command-smoke.*` used a one-second timeout and is inconclusive:
it omitted the two largest fan-outs and showed accepted-one order drift.

`command-growth-probe.log` is a failed first attempt at locating the actual prepared
statement; its query matched itself. `command-growth-probe-v2.log` fixes that probe
and observes the actual prepared stream-read statement on one connection. With an
empty fixture the plan uses a stream-table sequential scan. After 5,000 inserted
streams the cached generic plan still scans all 5,001 rows. An explicit ANALYZE
invalidates that plan and selects the existing name index. The subsequent 10,000-row
sample retains indexed lookup. No runtime or dependency code is changed. The stream
read belongs to `mori://shinzui/kiroku/packages/kiroku-store`.

The no-op probe means are 25.7 us empty, 171.7 us at 5,000 before ANALYZE, 27.6 us
after ANALYZE, and 21.2 us at 10,000. These explain the direction of the smoke drift;
final growth and paired-run evidence is still required.

The harness now seeds 5,000 unrelated singleton streams and ANALYZEs streams,
stream_events and events once in selected command-group setup, before any timed
command lookup is prepared. The initial version gave every scenario a 100,000-unit budget and bounded the
command store at 1,205,000 events. That budget was rejected by attempt 1 below;
the revised retained-event/operation budgets are the current protocol.
Counters include three warm-up invocations and fail on excess work. All rebuild
sources remain fixed; only supported rebuild bookkeeping grows. Outbox, ordinary
inbox and producer samples retain their TRUNCATE boundaries and fixed batch sizes.

Tracing is opt-in with `KEIRO_BENCH_SETUP_TRACE=1`; retain stderr separately from
benchmark stdout to avoid interleaved lines. `KEIRO_BENCH_REBUILD_PROBE=1` adds three
selected diagnostic rebuilds after warm-up. `KEIRO_BENCH_COMMAND_PROBE=1` runs a plain
IO growth/plan probe instead of benchmarks. Its SQL EXPLAIN uses the actual prepared
read installed by the library. Probe runs are never baseline samples.

The installed tasty-bench CSV header says picoseconds. Convert means/spreads to
milliseconds with 1e9; comparisons of raw rows remain unit independent.

`command-growth-probe-v3.log` extends the exploratory fast-fixture probe through
1,205,500 retained events (2,411,000 stream-event links, 455 MB for that relation).
Fresh/no-op means after ANALYZE are 144/31 us at 5k, 127/21 us at 10k, 144/23 us
at 100k and 140/24 us at the late population. The capped fresh workload remains
indexed across its growth envelope. Final evidence uses the durable fixture below.

The ordinary entry point now uses `withMigratedBenchmarkSuite`: fsync,
synchronous_commit and full_page_writes are enabled, with their actual values
included in the plan probe. Earlier exploratory logs used the old fast correctness
fixture and do not establish durable baseline values. `KEIRO_BENCH_RESET_PROBE=1`
compares five TRUNCATE and DELETE samples at fixed populated row counts for outbox
(2,000), ordinary inbox (2,000) and producer outbox (1,000), including before/after
counts and relation bytes. No timed command deletes have returned.

The first durable rebuild probe aborted at run 167 because fixed replay work was
charged as retained growth. It is retained as a failed probe. The corrected
harness limits rebuild bookkeeping to 10,000 runs independently of the fixed
600-event source; command fresh-event budgets remain unchanged.

The first filtered/full pair attempt at `c4901cd6` is invalid: 100,000-unit caps
aborted accepted-large and silent command rows, and delegated fresh rows drifted
or timed out. It was stopped, not used as acceptance. Those files remain in
`attempt-1/`. Normalized guard settings use `-j1`, wall time and `-N2` for every
CSV group (5% requested deviation, ten-second timeout); producer identity keeps
its 1%/120-second same-process comparison. A timeout is still inconclusive.

Revised budgets distinguish retained events from silent operations: one-event
and fan-out scenarios cap at 100,000 events each; each accepted-large scenario
caps at 10,000 batches / one million events; silent scenarios cap at one million
operations with no stream creation. The aggregate command growth bound is
3,005,000 events including the 5,000 seed. Rebuilds separately cap at 10,000 run
records with fixed 600-event source input. Delegated setup warms one batch,
ANALYZEs streams/stream_events/events/inbox once, then warms two more batches.
`KEIRO_BENCH_INBOX_PLAN_PROBE=1` retains the actual prepared existence lookup's
plans around that schedule without affecting normal timed runs.


`work-counts.*` checks actual retained work, with timing probes enabled and a deliberately
loose 100% requested deviation; these are count/plan diagnostics, not timing acceptance.
The tested source is parent `847b395c` plus `work-counts-source.patch`.
All 96 benchmark cases completed with process exit zero. Cleanup probes check each command
and fan-out prefix against its counter, each delegated prefix against fresh/repeated/duplicate
semantics, each history population, fixed rebuild events and persisted run/source rows,
and the read-model command prefix. Relation sizes are included. Opt in with
`KEIRO_BENCH_WORK_COUNTS=1`; timed acceptance must leave it unset.
The full diagnostic also sets `KEIRO_BENCH_SETUP_TRACE=1`,
`KEIRO_BENCH_REBUILD_PROBE=1`, `KEIRO_BENCH_INBOX_PLAN_PROBE=1` and
`KEIRO_BENCH_READ_MODEL_PLAN_PROBE=1`, with `-j1 --time-mode wall --hide-progress
--timeout 10s --stdev 100 +RTS -N2 -RTS`. Stdout and stderr are separate.

The first release-gate run on `847b395c` passed correctness and reported all six guards,
then refused producer and projection. Its log is retained under
[release-gates](../release-gates/README.md). The projection sequential diagnostic diverged
2.43x while its alternating three-target sampler measured 1.026x median p95 and 0.975x
throughput. Its old seed was 25,000 events in one stream. The revised read-model seed keeps
25,000 events across 5,000 streams, ANALYZEs the disposable fixture once before selected
three-invocation warm-up, and bounds command events at 100,000, async invocations at 100,000
and promotion runs at 10,000. Plan probes record the actual lookup around ANALYZE.
No serving SQL, baseline, or ratio ceiling changes in this step.

`record-pairs.sh` runs the three alternating serial pairs inside `nix develop`, refuses to
overwrite existing CSVs, and separates setup traces. `analyze-pairs.py` checks complete
command names, median absolute paired differences, no-op/rejected latency, monotone fan-out
and fresh inbox metrics twins. The replacement pairs and extended growth probe remain open.


`command-growth-durable-3m.*` runs the unchanged growth driver at `3eca8197` through
3,005,000 seed events (diagnostic events are additional). The late fresh/no-op means are
172.6/24.8 us with indexed lookup. These are single 100-operation blocks; the next driver
records five blocks at each checkpoint to retain spread rather than infer stationarity
from one point.

`projection-warmed-attempt-1.txt` retains the tighter rejected follow-up on `3eca8197`.
Its alternating sampler passed at p95 1.026x / throughput 0.981x, but legacy-first then
versioned-last sequential controls diverged. It reached 84,942 command and 65,540 async
operations. Current hard caps are 500,000 command events, one million async invocations
and 10,000 promotion runs. Projection controls are now adjacent, with names and the 2x
sequential tripwire unchanged. `projection-adjacent.*` retains the instrumented run and
`projection-adjacent-source.patch` identifies its exact source against `3eca8197`.
All 12 cases pass, with actual prepared group/stream plans after each case. A separate
`projection-adjacent-timed.*` run disables plan/count probes. No CSV baseline or producer
ceiling has changed. Final alternating command pairs remain required.


The three alternating pairs at `cfc57046` are preserved in `attempt-2/`. Every command
median difference is below 10% (maximum 6.66%), and all six processes pass their cases.
The third full run nevertheless has a 59.30% late delegated-batch-1000 fresh metrics-twin
outlier and slower small command appends; that cohort is not final acceptance.

`maintenance-full-1.*`, source `cfc57046` plus `maintenance-source.patch`, captures cluster
checkpoint/WAL/activity/table statistics outside timed actions. A checkpoint is active from
first delegated setup through multiple command cases. Defaults are `max_wal_size=1GB`,
`checkpoint_timeout=5min`. PostgreSQL describes the I/O and triggers in its
[WAL guide](https://www.postgresql.org/docs/18/wal-configuration.html), and the cluster-wide
counters in its [statistics reference](https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-PG-STAT-CHECKPOINTER-VIEW).
This identifies remaining cross-scenario coupling, rather than proving the exact server
state of the older uninstrumented outlier.

The candidate adds `checkpointBenchmarkStore` to test support. It uses the existing pool's
session API outside a transaction to wait for a cluster checkpoint. Selected setup then
warms the measured path; delegated intake uses one warm-up, ANALYZE, checkpoint, then two
more warm-ups. Command/ordinary inbox/outbox/producer/rebuild/read-model paths settle prior
checkpoint work before their final warm-up. Business rows and timed supported operations
are unchanged; durable settings and autovacuum stay enabled. `checkpoint-full-1.*`, exact
source `checkpoint-source.patch` against `cfc57046`, passes all 96 cases. Its 114 snapshots
have no busy/outstanding checkpoint and fresh twins differ by at most 4.41%. The subsequent
explicit handle-forcing/reset-probe adjustment is in `checkpoint-final-source.patch`.
`checkpoint-work-counts.*` then completes all 96 diagnostic cases and all 64 actual
count reports, including 13 persisted rebuild runs / 39 source rows / exactly 600 events.
`checkpoint-reset.*` repeats five alternatives per reset from a settled checkpoint;
TRUNCATE medians are 1.515 ms outbox/2,000, 0.937 ms inbox/2,000 and 1.400 ms
producer/1,000; DELETE medians are 0.323/0.324/0.213 ms. Both leave zero live rows;
TRUNCATE supplies a fresh physical fixture boundary, while DELETE retains allocated pages.
The common additive reset is reported separately and does not cancel from a ratio.
`checkpoint-list-tests.*` lists the same 96 names with no workload setup. Final unprobed
pairs remain open. No baseline or ceiling has moved.
