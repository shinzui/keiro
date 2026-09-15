# Producer identity performance evidence

Recorded 2026-09-15 for [plan 164](../../../../docs/plans/164-make-producer-outbox-identity-deterministic-and-replay-safe.md).

## Setup

Apple M1 Max, arm64 macOS; GHC 9.12.4, Cabal `-O1`; PostgreSQL from the existing
isolated migration fixture. Both compared builds resolved the same external dependency versions.
Benchmarks ran sequentially (`-j1`) using wall time and two RTS capabilities (`+RTS -N2`).
No build or test workloads were run alongside the measured cohorts. This is a shared development
machine, not an isolated performance lab. Payloads are 1 KiB; these results do not establish
latency at large retained-table sizes, large payloads, or production network distances.

The old publisher executable was built from detached commit `20f2f378`; the new publisher
cohort used implementation `3cdbe90a`. Subsequent changes optimize only producer identity and
comparison, preserve frozen bytes, and strengthen the benchmark/checkpoint test. Publisher SQL
and worker behavior remain the same as in the measured new cohort. Six publisher samples alternate
before/after; reported publisher values are medians of three independent benchmark runs.

Producer reference scenarios reproduce fresh UUIDv7 outbox IDs, fresh TypeID message IDs, and
the unchanged explicit insert statement. Both paths have the same payload and provenance fields.
Bulk scenarios prepare a batch and enqueue 1,000 rows in one transaction. Individual scenarios
prepare each event immediately before its transaction and consume each result before continuing.
They include truncation/setup equally. The pure benchmark forces both resulting identifiers.

## Results

| Workload | Legacy | Deterministic / new | Change |
| --- | ---: | ---: | ---: |
| Publisher hot-key, 2,000 rows | 784.01 ms | 809.79 ms | +3.29% |
| Publisher hot-key-nolatency, 2,000 rows | 636.54 ms | 642.21 ms | +0.89% |
| Publisher multi-key, 2,000 rows | 465.76 ms | 463.23 ms | -0.54% |
| Fresh enqueue, 1,000 rows / one transaction | 84.33 ms | 87.05 ms | +3.22% |
| Fresh enqueue, 1,000 individual transactions | 126.70 ms | 130.07 ms | +2.66% |

The final fresh-write precision run (`precision.csv`) passed all four cases and both built-in
10% comparison guards. The reported two-standard-deviation spreads were about 1.3/1.2 ms for
bulk writes and 19/9.2 ms for individual transactions, respectively. Thus the individual-transaction
means carry more uncertainty; these are measured small overheads, not a claim of exact zero cost.
Publisher changes were all within 3.4% across matched medians.

Pure derivation measured a median **1.03 microseconds** after allocation optimization,
versus about 1.46 microseconds initially, with unchanged version-1 vectors.
A fresh batch plus one prepared identical replay of 1,000 rows measured **436.95 ms**
(median of three corrected runs). Subtracting the matching fresh-batch median gives about
**0.350 ms per duplicate**; this subtraction is an estimate, not a separately
isolated duplicate benchmark. Replay necessarily performs an indexed locking read and retained
content comparison that the old silent suppression did not provide.

## Sampling and guard investigation

The first publisher attempt used a one-second Tasty timeout and produced no valid samples;
it is excluded. Successful publisher cohorts use `--stdev 10 --timeout 60s`.
`initial-producer-*.csv` records the first implementation. These measurements motivated one-buffer
identity encoding and an exact-envelope-equality shortcut before canonical encoding on replay.
Neither optimization changes the byte contract or skips drift detection.

`preparation-mismatch-*.csv` records an exploratory individual-transaction benchmark that
pre-generated every legacy ID before the transaction loop but prepared deterministic IDs per event.
It also accumulated deterministic results across the loop. Those results crossed the 10% guard
and exposed the mismatch; they are retained for audit and are not used as the final comparison.
The corrected scenario models per-event preparation and immediate result consumption on both sides.

`final-producer-*.csv` uses the corrected workload and a 5% target standard deviation. All three
individual-transaction comparisons passed, but two bulk comparisons crossed 10% (about 14% and
10%). Those failures are retained, not discarded. A tighter `--stdev 1 --timeout 120s` comparison
then measured about 3% overhead for both scenarios and passed both guards. `precision.csv` is that
final guard run. Small local differences near a guard should be investigated with matching
preparation boundaries and tighter sampling, not by increasing the allowed slowdown.

## Reproduce

From the repository root:

```bash
cabal bench keiro-bench --benchmark-options='-p producer-identity -j1 --time-mode wall --hide-progress --stdev 1 --timeout 120s +RTS -N2 -RTS'
```

`just bench-regression` now includes this command. The producer cases enforce a 10% ceiling
against their same-process legacy reference using `bcompareWithin`. They do not compare a new
machine to these committed timing files. Run with `-j1`: database benchmark scenarios share a
store and must not truncate each other's data concurrently.

To repeat the publisher comparison, build `keiro:bench:keiro-bench` from `20f2f378` in a detached
worktree and from the candidate, then invoke each built executable with:

```bash
-p outbox -j1 --time-mode wall --hide-progress --stdev 10 --timeout 60s --csv /tmp/publisher-sample.csv +RTS -N2 -RTS
```

Alternate three old/new pairs, use separate CSV filenames, and compare medians. Preserve failed
or timed-out attempts separately; do not report an incomplete sample as acceptance.
