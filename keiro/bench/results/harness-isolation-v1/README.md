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
command lookup is prepared. Every command scenario has a fresh counter and a hard
100,000-unit budget (an event for eventful scenarios; an operation for silent ones).
Twelve eventful scenarios plus the seed bound the command store at 1,205,000 events.
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
