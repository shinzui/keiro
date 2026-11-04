# Projection feeding-subscription evidence

Acceptance remains open. Final code is `00fafcd47798e87d0b9c03a71a0eb385ce058471`;
comparison baseline is `d64849f19d2d922a5373b121d13d0fac5bc9132f`.
Full Nix verification and the read-model guard pass, and every final workload
completed. No final writer metric shows a statistically supported regression.
Latency precision and quiet-machine conditions do not meet the fixed protocol.
IR-57 therefore remains accepted, with plan 327 milestones 3 and 4 open.

## Results

All eight numerical page-read gates pass in `loaded-sql-v4/`. Other builds were
observed, so these are qualified results, not a quiet-machine acceptance pass.
Each candidate plan returns 101 SQL rows and performs 10 added keyed probes for
the checkpoint stripe. The private-table constraint proves append/unmanaged
arrays empty; CASE skips their probes. The frozen view lookup retains OFFSET 0.

| Groups | Plan | Page | Baseline median ms | Candidate median ms | Paired median ratio |
| --- | --- | --- | ---: | ---: | ---: |
| 10000 | custom_plan | first | 2.779 | 2.783 | 1.0043 |
| 10000 | custom_plan | deep | 0.530 | 0.563 | 1.0552 |
| 10000 | generic_plan | first | 2.738 | 2.790 | 1.0084 |
| 10000 | generic_plan | deep | 0.547 | 0.558 | 1.0207 |
| 100000 | custom_plan | first | 2.747 | 2.785 | 1.0025 |
| 100000 | custom_plan | deep | 0.554 | 0.598 | 1.0814 |
| 100000 | generic_plan | first | 2.873 | 2.842 | 0.9807 |
| 100000 | generic_plan | deep | 0.581 | 0.580 | 0.9982 |

The final writer cohort in `interference/` contains forty 20-second trials,
five alternating pairs per mode plus same-source controls: 80,000 writer
operations in total. Every trial sustained at least 99% of the offered
100 operations/second. All HTTP trials completed 80 scheduled requests with no
errors. Feed trials received snapshots and updates, validated non-empty
subscription arrays, and returned views, connections and the wake pump to idle.

Throughput and writer-thread allocation intervals pass. Latency results are:

| Mode | p95 ratio (95% bootstrap interval) | p99 ratio (95% bootstrap interval) |
| --- | --- | --- |
| idle | 0.9833 (0.8991–1.4676) | 0.9910 (0.8983–1.0668) |
| poll | 1.0129 (0.9428–1.3426) | 1.0042 (0.5868–1.1414) |
| feed | 0.9607 (0.6567–1.3060) | 0.9309 (0.6329–1.1246) |

Every final latency interval includes equality, but does not exclude a 1% loss.
The identical-binary p99 control interval is 0.5553–42.5745. One such control's
p99 was 4.590 ms and its partner's was 195.417 ms; 188.604 ms of the latter's
p99 operation was offered-load scheduling delay. This occurred around operations
1688–1733, rather than during warm-up. It cannot be caused by the new field:
both controls run the same baseline binary with no active inspection clients.
The exact cause of the transient stall is not established.

The monitor recorded builds/tests in 133 of 446 observations. It distinguishes
Cabal `list-bin`/`path` metadata queries from builds; arbitrary process arguments
are not retained. `evaluation.json`, `control-tail-diagnostic.json` and
`interference/summary.json` retain the complete qualification and all ratios.
The strict runtime analyzer still exits nonzero. No outliers were removed and
no baseline or numerical threshold was changed.

The original review required matched writer evidence but supplied no runtime
precision ceiling. The implementer fixed the 1% confidence-resolution rule
before sampling. It is an implementation interpretation, not an explicit
number from the original user plan. Completing acceptance with the current
data would require an explicit scope decision about this precision rule and
the recorded background activity.

## Behavior and compatibility

`jitsurei-cli.json` and `jitsurei-http.json` are final executable responses from
the same disposable jitsurei database. Items match exactly: reporting names
`jitsurei-order-audit-subscription`, while the legacy area-chapters group has `[]`.
The CLI passes `--database-url` explicitly. The final HTTP server binds port zero
and its OS-assigned loopback port is discovered before the request.

`verify.log` is the passing full `nix develop -c just verify` run on final code;
`verify-before-optimization.log` preserves the earlier pass. `read-model-guard.log`
records all ten cases passing with `GUARD(read-model)=0` and
`BENCH_REGRESSION=PASSED`. The committed CSV is unchanged. `compatibility.txt`
records byte-identical frozen types, decoder, complete-list/lookup definitions
and SQL; all 18 old JSON pair expressions are unchanged. Migrations, expected
schema, catalog registration and writer files are untouched.

The final encoder prepends its extra pair instead of appending to the old pair
list. The earlier all-row cursor probe, guarded lateral form and original
encoder cohort remain in `loaded-diagnostic-v1/`, `loaded-diagnostic-v2/`,
`loaded-interference-v1/`, `loaded-sql-v3/` and `loaded-sql-v4/`, each attributed
to its own source/binary identities. These observations are never substituted
for a passing final acceptance gate.

## Environment and protocol

Apple M5 Ultra, 36 cores, 256 GiB RAM; Darwin 27.2.0; GHC 9.12.4;
PostgreSQL 18.6; Python 3.14.7; Z3 4.16.0. `machine.txt` and `identity.json`
record exact details, binary paths, SHA-256 and flags. All 311 external package
unit identities match. Keiro's reaction-hydration probe flag is disabled.

Benchmarks use private durable ephemeral PostgreSQL clusters through
`Keiro.Test.Postgres.withMigratedBenchmarkSuite`, not the shell's `db/` cluster.
No remote admin connection is configured. fsync, synchronous_commit,
full_page_writes and autovacuum stay on. The manual jitsurei executable proof
uses the shell cluster separately. Fixtures and both binary sets use the same
settings, and benchmark setup is outside timing.

The identical `driver.hs.txt` source compiles separately against each package
set, library O1, driver `-O2 -threaded -XGHC2024`, exposing `keiro` and
`keiro-test-support`. It calls the real page API and then takes five EXPLAIN
ANALYZE/BUFFERS/SETTINGS samples for each 10k/100k, first/deep, custom/generic
shape. There are three models per group and 10,000 extra models in the first
group; every tenth group has one checkpoint subscription. Run three pairs in
B/C, C/B, B/C order. `summarize.py` checks all sample identities, settings,
row counts and keyed probes, and computes fifteen ordinal-paired ratios per
shape with the unchanged 1.10 median ceiling. Historical all-append ~2.8/0.6 ms
figures are context for a different fixture, not a recalibrated baseline.

The identical retained interference harness sources compile at O1 with the
packages/flags in `identity.json`, without the pre-inspection CPP macro. Each
trial seeds 100k workflows/timers plus 10k projection groups (three models each,
ten-percent checkpoint stripe). The existing benchmark also registers one
legacy read-model group. It finishes CHECKPOINT, warms the writer and settles
before timing. Parent RTS flags are `-N2 -T`; clients allocate in a separate
process. Idle, four staggered HTTP pollers and four subscribers sharing one
projection view use separate inspection pool capacity. A fixed-seed (327),
20,000-resample trial-level percentile bootstrap retains every observation.
Intervals wholly above one reject degradation; upper endpoints >=1.01 remain
inconclusive, including the same-source controls. SQL's 1.10 ceiling does not
permit a 10% writer regression. Prior manager-discovery evidence or waivers
are not used.

## Reproduction

Keep the baseline detached worktree until acceptance is resolved. Build both
package sets in their Nix shells, then compile the retained identical sources
in each checkout using separate output directories and the flags/packages in
`identity.json`. Pass current-source absolute paths when compiling in the
baseline checkout. Compiled executables stay in `.dev/plan327/`; only their
identities, exact sources and raw observations are committed.

Use a new output directory for each cohort:

```bash
nix develop -c python3 keiro/bench/results/inspection/projection-status-feeding-subscriptions/run-quiet.py   .dev/new-process-observations.jsonl   bash scripts/measure-projection-feeding-subscriptions.sh   "$PWD/.dev/plan327/baseline-interference"   "$PWD/.dev/plan327/candidate-interference-final"   .dev/new-projection-cohort
nix develop -c just bench-regression read-model
```

`--diagnostic` permits collection through observed background work but still
returns nonzero for it. The current writer cohort used that mode to retain
useful observations while other work continued. `sql-negative-controls.json`
shows refusal of malformed/incomplete SQL evidence and fleet/unbound probes;
`runtime-negative-controls.json` shows refusal of a synthetic reproducible 2%
p99 loss and missing poll load. `analysis-replay.txt` records a byte-identical
replay of the fixed final analysis. `manifest.json` checksums every retained
artifact except itself. These finite measurements concern the stated workload;
per-request deadlines and response caps remain required.
