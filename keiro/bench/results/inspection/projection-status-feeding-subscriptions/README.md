# Projection feeding-subscription evidence

Implementation baseline is `d64849f19d2d922a5373b121d13d0fac5bc9132f`;
the runtime candidate is `3e9fbacd84d811271b6f0a268169594b929c731e`.
`identity.json` records the machine, compiler, PostgreSQL version, binary paths,
SHA-256 hashes and compiler flags. Both builds use the repository Nix shell;
all 311 external package/version pairs and installed unit identities match in the two retained Cabal plans.
Library optimization is O1. Compiled binaries and object files stay in
`.dev/plan327/`, outside version control.

## Behavioral and structural checks

`jitsurei-cli.json` and `jitsurei-http.json` are complete responses from the
embedded CLI and actual database-only HTTP server against `jitsurei_plan327`.
Their item arrays are equal. The checkpoint-backed reporting group names
`jitsurei-order-audit-subscription`; the legacy area-chapters group reports `[]`.
The CLI uses an explicit `--database-url` because its ops parser does not read
`PG_CONNECTION_STRING`. HTTP used port 19327 because 9092 was occupied.

`compatibility.txt` records comparisons against the baseline: the v1 record,
complete-list/lookup API definitions, shared SQL, and frozen decoder are
byte-identical. Migrations, expected schema, catalog registration, writer
files and the CSV benchmark baseline are unchanged. Focused core, ops,
jitsurei and HTTP suites pass (9, 56, 28 and 55 examples), as do all 41 migration
examples including the isolated external-reader privilege and ordered view shape.

## SQL protocol

`driver.hs.txt` is the exact driver source separately compiled against both
package sets, using `ghc -O2 -threaded -XGHC2024 -package keiro
-package keiro-test-support`, separate `-outputdir` values, and no RTS overrides.
It invokes the actual page API, verifies 100 returned items, discovers its Hasql
prepared statement, and records five EXPLAIN ANALYZE/BUFFERS/SETTINGS samples
per shape. Fixtures contain 10k/100k groups with three models per group and
10,000 extra models in the first group. Every tenth group has a checkpoint basis
and one subscription name; other groups use append authority. No upstream
checkpoint is fabricated. Each run uses fresh disposable durable databases.

Run the compiled binaries serially as baseline/candidate, candidate/baseline,
baseline/candidate. Retain every sample and every outlier. `summarize.py` verifies
all identities, row counts, durable settings and plan-cache modes, then computes
15 ordinal-paired ratios per fleet size, first/deep page and custom/generic mode.
The paired median must be <=1.10 in every shape. Each candidate must use the
added lateral private-table alias for 101 parameterized primary-key probes driven
by the materialized page, including look-ahead. The unfenced ordinary left join
was rejected during prototyping because generic first pages used an
unparameterized merge join. `sql-negative-controls.json` records rejection of
missing/duplicate samples, wrong row counts, nonpositive timings and bad plans.
Historical all-append measurements (~2.8 ms first, ~0.6 ms deep at 100k) describe
a different fixture and are context, not a recalibrated baseline.

Reproduce from the repository root after separately building baseline dependencies
in `../keiro-feeding-subscriptions-baseline` and candidate dependencies here:

```bash
nix develop -c cabal build all --enable-tests --enable-benchmarks
nix develop -c bash -c 'cabal exec -- ghc -O2 -threaded -XGHC2024 -package keiro -package keiro-test-support -outputdir .dev/plan327/build-candidate scripts/inspection-projection-feeding-subscriptions-evidence.hs -o .dev/plan327/candidate-driver'
# Use the same driver source and flags inside the baseline checkout, with
# absolute source/output paths and a separate output directory.
nix develop -c python3 keiro/bench/results/inspection/projection-status-feeding-subscriptions/summarize.py keiro/bench/results/inspection/projection-status-feeding-subscriptions
```

## Writer interference protocol

The retained `InspectionInterference.hs.txt` and `InspectionClients.hs.txt`
are identical sources compiled against both package sets, with the flags in
`identity.json`. The baseline checkout stays unchanged. Ordinary benchmark
workflow schedule/claim/resume/timer operations and 100k workflow/timer ledgers
are retained. Projection modes additionally seed 10,000 groups, three models
each, and one non-empty subscription array for every tenth group. The existing
benchmark's final CHECKPOINT, writer warm-up and settle precede measurement;
fsync, synchronous_commit, full_page_writes and autovacuum must all remain on.

Each of five alternating trial pairs offers 100 writer operations/second for
20 seconds (`+RTS -N2 -T`), with a separate inspection pool. Compare mounted idle,
four staggered HTTP status pollers (four requests/second, limit 100), and four
subscribers sharing one projection_groups view (limit 100). Polling validates
all candidate subscription arrays. Feed clients validate the same arrays in
initial snapshots and any changed items, and consume head-only updates while
the writer runs. External clients allocate in a separate process. Their only
baseline/candidate input difference is the expected additive response field.
Two additional baseline idle trials per pair provide same-source controls,
with their order alternating too.

Missing writer samples, achieved throughput below 99% of offered load, a failed
request/feed, missing snapshots, lost polling cadence, changed durable settings
or abandoned feed resources invalidate a trial. Keep all raw writer timings,
writer-thread allocations, process CPU/GC/allocation diagnostics and client
counts. Analyze trial pairs as independent units, never individual correlated
operations. For throughput (inverted), writer p95/p99 including schedule delay,
and writer-thread bytes/operation, retain all ratios, absolute medians and a
fixed-seed (327) 95% percentile-bootstrap interval from 20,000 resamples.
An interval wholly above equality rejects degradation; an upper endpoint >=1.01
is inconclusive. Same-source controls must also resolve changes within 1% in
either direction. Compare each candidate mode to its baseline mode and compare
the active/idle effects between builds. SQL's 1.10 ceiling does not permit a
10% writer regression. Prior manager-discovery evidence or waivers are unused.

```bash
nix develop -c bash scripts/measure-projection-feeding-subscriptions.sh \
  "$PWD/.dev/plan327/baseline-interference" \
  "$PWD/.dev/plan327/candidate-interference" \
  keiro/bench/results/inspection/projection-status-feeding-subscriptions/interference
```

Timing evidence must be collected serially on a quiet machine, without builds,
tests or other benchmarks alongside it. These observations concern this bounded
fixture and offered workload; they cannot prove equality for every production
fleet or subscription/model cardinality. Per-request deadlines and response caps
remain required.

## Acceptance results

`nix develop -c just verify` passed; the full log is retained as `verify.log`.
Paired measurements and the read-model guard remain pending while other
repositories run tests on this machine. No runtime performance acceptance is
claimed by behavioral tests or query-plan prototypes alone.
