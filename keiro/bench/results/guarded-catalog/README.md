# Guarded catalog command evidence

The production change is `0efa3d2a`; the original production library is
`ad78efae0d21d849c8106eac73df0f8bb5719e1f`. The compiled example, expanded
correctness matrix and shared performance harness landed in `22c6f696`.
All runs use the project Nix shell, GHC 9.12.4 at `-O1`, PostgreSQL 18.6,
Kiroku 0.11.0.0 and hasql-transaction 1.2.3.1. No bounds or versions changed.

`baseline/` preserves forty initial ordinary latency samples and the original
executable digest. These samples overlapped compilation and have no elapsed
throughput; they are provenance only. `sql-lock-audit.json` is explicitly a
source audit of statements and explicit locks, not a PostgreSQL statement trace.
`enhanced-environment.json` identifies the retained original-library executable
with the shared request/fixture/measurement source hashes. Its
`verifiedHarnessCommit` identifies the later commit containing those exact
bytes; `buildCheckoutHead` preserves the checkout head during its build.

Acceptance runs use `+RTS -N2 -RTS`, a pool of ten connections, initial
cardinalities including the hundred warm-up rows, exact 1 KiB creation data,
four tags, and deterministic request/key schedules. Both active and paused
worker states are required. Raw samples use gzip-compressed JSON; summaries,
budgets, workload inputs and paired reports remain plain JSON. Refused attempts
are reported separately from committed event throughput. Rebuild the original
binary with `scripts/build-guarded-catalog-baseline.py`; aggregate retained
results with `scripts/summarize-guarded-catalog-evidence.py`.

`diagnostic-20261012/` contains unsupported slow-guard positive controls,
index-plan evidence, PostgreSQL lock waits and transaction clocks. The 20 ms
guard reduces attempt throughput from 2,059.69 to 211.37 per second and increases
the ordinary cohort's p95/p99 by 9.21/15.04 times. A separate instrumented run
counts 1,001 global updates and 201 guard evaluations for 1,000 outer attempts
with one injected `40001`. Guard p50/p95/p99 are 21,384/22,634/24,071 microseconds.
Global-update-to-delivery clocks exclude pre-update wait and commit, so they
are lower bounds on lock lifetime. Instrumented samples do not establish
performance acceptance.

`diagnostic-boundaries-20261012/` repeats the positive controls and adds an
after-statement append clock plus raw transaction stages. Its measured
append-statement-end-to-identity-delivery interval includes admission and guard
work, ends before commit, and is affected by the diagnostic triggers. All
1,000 committed intervals are positive; their median/p95 are 243/21,900
microseconds. Guard median/p95 are 21,350/21,694 microseconds. The counters again
observe exactly one injected driver retry and no outer OCC churn.

`regression-20261012/` preserves the historical command CSV guard failures.
The full current run fails nine of fifteen cases. An identical four-case
selection on the retained pre-change binary fails three cases; the current
binary fails one. Selected means (original/current) are 4.02/3.42 ms for legacy
accepted-one, 44.3/38.9 ms for router fan-out ten, and 4.385/3.651 seconds for
fan-out one thousand. These are individual Tasty measurements, not five-pair
acceptance medians. Both binaries exceed historical fan-out baselines, while
the observed current selected means are lower. The full current run's observer
finds I/O wait in hard-delete affected-history lookup, with a 112 MB
`stream_events` relation in the shared growing benchmark fixture. No cleanup
or historical CSV change is made for this feature. Shared-host background
build/test activity was observed during the initial full command run; it is
another reason to preserve the raw failures and use fresh alternating controls.

The required complete matrix, fixed-arrival and ten-minute storage/latency
comparisons remain pending. No performance-ready conclusion is recorded here.
