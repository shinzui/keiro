# Recording tracer baselines

Plan 330 adds eight cells in four adjacent no-tracer/tracer pairs. The tracer has a
processor that discards completed spans without export I/O; startup asserts `isRecording`.
The ownership probe separately keeps finished and live spans reachable during payload GC.

Run from a clean source checkpoint, in the Nix shell, with no competing build or benchmark:

```bash
nix develop -c cabal build keiro:bench:keiro-bench keiro:test:keiro-retention
nix develop -c python3 keiro/bench/results/tracing-baseline-v1/record.py
```

The recorder refuses to overwrite evidence. For a later comparison, copy it to a fresh result
directory at the same depth, preserving this original. Five serial samples use wall time,
`-j1`, `-N2`, 5% requested deviation and a ten-second per-cell timeout. Each row of `baseline.csv`
is the median mean and median spread; `pairs.md` compares those medians. Original CSVs and logs
are retained. Environment and source/binary identity are in `environment.json`.

Commands append exactly 100 events per invocation, either to 100 fresh streams or one fresh
stream, with at most 1,000 invocations (100,000 events) per cell, including three warm-ups.
Dispatch consumes 100 in-memory messages, each dispatching one eventful command, with the same
bound. Setup seeds 5,000 singleton streams and settles a checkpoint before warming each cell.
Cleanup verifies actual stream/event counts. Command and dispatch groups have separate stores.

Publishing uses its own durable migrated store and a no-latency callback. Each invocation resets,
enqueues and drains exactly 2,000 rows using default publisher batching. Reset and enqueue are
included in both members' measured cost, as in the existing publisher benchmark. The paired
measurement therefore describes this whole workload; it does not isolate span CPU time.
PostgreSQL benchmark fixtures retain durable commit settings; no global database is used.

Historical CSVs and thresholds are unchanged. These new rows have no enforced time ceiling yet;
their role is an attributed starting point for subsequent tracing changes. Small differences,
including negative measured overhead, must be interpreted against the raw sample spread.

Recorded on 2026-11-14 at source `7579be21`: all five samples passed all eight cells. See
[pair medians](pairs.md). The untraced/traced deltas (−0.4%, +1.8%, −1.0%, +2.1%) lie within
the observed spreads; they do not establish a performance improvement. `work-counts.log` is a
separate, untimed-count diagnostic invocation using `KEIRO_BENCH_WORK_COUNTS=1` and `--stdev 100`.
Count probes are disabled in the five timing samples. `ownership-negative.log` preserves the
controlled failed collection assertion; `retention.log` records the restored suite (22 examples, zero failures).
`dependency-versions.json` preserves the resolved package versions. `SHA256SUMS` covers the retained
measurements and logs.

EP-1 acceptance remains open because the required Mori terminology check cannot connect to its
registry database (`terminology-blocker.log`). The broad verification run was stopped after
its active fixture-mutating proof restored source (`verify-interrupted.log`); it is not a
passing repository gate. Restore Mori connectivity and rerun `nix develop -c just verify`
before accepting EP-1 or beginning its dependent plans.
