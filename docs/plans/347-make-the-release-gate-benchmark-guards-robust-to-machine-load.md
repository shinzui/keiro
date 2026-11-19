---
id: 347
slug: make-the-release-gate-benchmark-guards-robust-to-machine-load
title: "Make the release-gate benchmark guards robust to machine load"
kind: exec-plan
created_at: 2026-11-19T02:33:04Z
intention: "intention_01m7rtcw81er3tbbtynme19c5r"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-19T02:33:04Z
---

# Make the release-gate benchmark guards robust to machine load

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Keiro releases are gated by `nix develop -c just release-gate`. It runs about 30 minutes
of correctness checks and then about 28 minutes of benchmark guards. A benchmark guard
compares the release candidate's timings with a fixed reference build on the same
machine. Today the guards are trustworthy only on a quiet machine. The developer's
machine is rarely quiet: dozens of agent sessions, a virtual machine and other tools run
beside the release. As a result, an unchanged code path can read as more than 25% slower
and block a release. A person then re-runs the gate and gets a pass. At 0.26.0.0 this
cost about an hour. The release notes in
`keiro/bench/results/release-gates/0.26.0.0-release-status.md` record the case.

After this plan, ordinary background load on this machine no longer turns an unchanged
path into a failed or inconclusive guard. Real regressions are still caught. Concretely:
with a reproducible synthetic load running, five consecutive guard runs against an
unchanged candidate end `PASSED`, while a deliberately injected slowdown still ends
`REGRESSION`. Where the machine is too busy to measure reliably, the guard detects this
within minutes, before spending its measurement budget. It waits for capacity a bounded
number of times and, failing that, stops with a distinct `ENVIRONMENT_BUSY` status that
names the cause. It no longer reports `INCONCLUSIVE` after the full run.

This is the third piece of guard work, so this plan states what makes it different.
[Plan 315](315-attribute-the-command-path-append-slowdown-and-restore-trustworthy-benchmark-guards.md),
[plan 321](321-isolate-the-keiro-bench-harness-so-each-guard-measures-only-its-own-fixture.md)
and [plan 330](330-establish-tracing-enabled-performance-and-retention-baselines.md)
fixed what is measured: fixture isolation, reproducible baselines, a same-machine
reference build and bounded confirmations. Each scoped its acceptance to "a quiet
machine". None of them measured or controlled machine load. `scripts/bench_guard.py`
records `os.getloadavg()` and never uses it. This plan's acceptance is defined under
load, so it cannot be met by quiet-machine evidence.

The plan is honest about its limit. If the diagnosis in Milestone 1 finds no measurement
control that removes the load sensitivity, the fallback deliverable is fast, explicit
environment refusal. That stops wasting the correctness half of a run, but a saturated
machine cannot then produce a pass. The plan never raises the 1.25 ceiling, re-records a
baseline, drops a case or treats `ENVIRONMENT_BUSY` as acceptance.


## Progress


- [ ] Milestone 1: The load sensitivity is reproduced on demand and attributed. A load
  generator reproduces the 0.26.0.0 failure on unchanged source. Each candidate
  mechanism (macOS core scheduling, RTS parallel GC, PostgreSQL server contention) is
  confirmed or refuted by a recorded experiment, and the control to adopt, or the
  conclusion that none works, is in the Decision Log.
- [ ] Milestone 2: The guard measures under the adopted control and detects
  contention. `scripts/bench_guard.py` applies the control identically to reference and
  candidate, checks machine capacity before and during each family, and waits or
  reports `ENVIRONMENT_BUSY` instead of `INCONCLUSIVE` for a busy machine. Unit tests
  cover every new status path.
- [ ] Milestone 3: Load robustness is accepted. Under the Milestone 1 load, five
  consecutive inbox-guard runs on unchanged source pass. The injected slowdown is caught
  quietly and under load. A full `just release-gate` passes. ADR-58 records the rule.


## Surprises & Discoveries


- Observation: the 0.26.0.0 failure was a consistent, load-dependent difference between
  the two binaries, not random noise.
  Evidence: `keiro/bench/results/release-gates/20261119T003957Z-ce6252c6-inbox/`. For
  `All.inbox.downstream.delegated-single.fresh.metrics-on`, the means (milliseconds,
  with 2σ) were: initial reference 467 ±18, candidate 585 ±86. In the first
  confirmation (candidate first), candidate 820 ±68 and reference 613 ±341. In the
  second (reference first), reference 452 ±22 and candidate 601 ±57. That is roughly
  1.3× in all three, including a tight pair measured about 15 seconds apart. Load
  averages were 6–8.5. The candidate's `delegatedCommand` source and the benchmark were
  unchanged since 0.25.1.0. The metrics-off twin measured 0.928×. On the re-run at load
  4–5.5 the case measured 1.043× (`20261119T021204Z-2efe668c-inbox/result.json`).
  Earlier gates passed it at 0.89–1.00×. Consequence: re-ordering or interleaving the
  reference and candidate cannot fix this alone. Under contention the candidate's
  metrics-on path genuinely slows more than the reference's, so the fix has to remove
  the contention effect, not average over it.

- Observation: a load average of about 7 is far from CPU saturation on this machine.
  Evidence: `sysctl -n hw.ncpu` reports 36 logical CPUs and
  `sysctl -n hw.perflevel0.physicalcpu` reports 12 performance cores. The guards run
  each benchmark with `+RTS -N2 -RTS` (`measure` in `scripts/bench_guard.py`). That
  makes plain CPU starvation unlikely. It points instead at macOS placing benchmark or
  PostgreSQL threads on efficiency cores when performance cores are busy, or at RTS
  parallel garbage collection being descheduled. Milestone 1 must test these
  hypotheses rather than assume them.


## Decision Log


- Decision: acceptance is measured under a reproducible synthetic load, plus a
  deliberately injected regression. Quiet-machine passes are necessary but not
  sufficient.
  Rationale: the user asked for this work only if it would finally fix the problem.
  Prior plans were accepted on quiet-machine evidence, and the failure persisted on the
  machine releases actually run on. An acceptance test that cannot be passed without
  solving load sensitivity is the only way to avoid a third partial fix.
  Date: 2026-11-18.

- Decision: diagnose before changing the guard. No timing logic changes until
  Milestone 1 has attributed the effect.
  Rationale: the 0.26.0.0 evidence rules out the cheapest guesses (ordering, drift)
  and leaves several mechanisms that need different fixes. Changing statistics first
  would repeat the pattern of fixing a symptom.
  Date: 2026-11-18.

- Decision: `ENVIRONMENT_BUSY` remains blocking. It never counts as acceptance.
  Rationale: ADR-58 makes a failed or inconclusive comparison non-acceptance. A busy
  machine proves nothing about the candidate. The improvement is that the result is
  fast and names its cause, not that it is looser.
  Date: 2026-11-18.


## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


The release gate is `just release-gate` in `Justfile`. It runs
`scripts/release_workflow.py gate`, which executes stages and writes one JSON receipt per
stage plus a manifest under `keiro/bench/results/release-gates/`. The stages are, in
order: preflight, correctness (`just _verify`, about 30 minutes), and six benchmark
guards. A guard is one family of timed benchmarks with a pass/fail rule. The six guards
are `producer-identity`, `outbox`, `inbox`, `command`, `projection` and `read-model`, run
by `scripts/bench-regression.sh`. Re-running the gate reuses any stage receipt whose
inputs are unchanged and less than 24 hours old, so re-running after a guard failure
re-measures only that guard.

Five of the guards (`outbox`, `inbox`, `command`, `projection`, `read-model`) go through
`scripts/bench_guard.py`. For a family, that script builds the immutable reference
source `b8695a0d050c5b0db2f251887d43182da2b47eed` (the constant `REFERENCE`) into a
cache under `dist-newstyle/benchmark-reference/`. In `measure`, it runs the reference
and candidate `keiro-bench` executables one after the other over the family's
benchmarks:

```text
<binary> -p <pattern> -j1 --time-mode wall --hide-progress --stdev 5 --timeout 10s --csv <file> +RTS -N2 -RTS
```

`keiro-bench` is the Tasty benchmark program in `keiro/bench/` (inbox cases are in
`keiro/bench/InboxDelegatedBench.hs`). `--time-mode wall` measures elapsed time,
including time the process spends waiting for PostgreSQL. `compare` divides the
candidate mean by the reference mean for each case. A ratio at or below `CEILING = 1.25`
passes. A ratio whose lower bound exceeds the ceiling is a regression, and anything else
is inconclusive. Failing cases get two adjacent confirmation pairs in opposite orders
within `CONFIRM_SECONDS = 240`, and `confirmation_status` requires both to agree. The
result is written to `<run>-<family>/result.json`, which today includes `load_average`
but nothing acts on it. Unit tests for this script are in
`scripts/tests/test_bench_guard.py`, run with
`python3 -m unittest discover -s scripts/tests -p test_bench_guard.py`. The
`producer-identity` guard is a same-process ratio and is out of scope unless Milestone 1
shows it has the same sensitivity.

PostgreSQL for the benchmarks is the development-shell cluster (`PGDATA`, `PGHOST` from
`nix develop`). The benchmark's database work therefore runs in separate `postgres`
processes whose scheduling the guard does not control today.

The relevant ADR is
[ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md).
It requires the correctness gate plus all six guards for every release. It treats a
failed or inconclusive comparison as non-acceptance and fixes the historical rows,
measured quantities, RTS settings and in-run assertions. It forbids re-recording a
baseline merely to pass. It allows stage reuse only for identical inputs. Changing the
RTS settings is therefore an ADR-58 change. It is allowed only when applied identically
to reference and candidate, and when the ADR is amended in the same change. No other ADR
is relevant.

Terms used here: *load* means other processes competing for CPU, memory bandwidth or
disk while a guard measures. *Performance cores* and *efficiency cores* are the two
kinds of CPU core on this Apple Silicon machine; macOS decides per thread which kind
runs it, guided by the thread's quality-of-service class. *Parallel GC* is the GHC
runtime's multi-threaded garbage collector, enabled by default with `-N2`.


## Plan of Work


Milestone 1 is a bounded diagnosis prototype. Add a load generator,
`scripts/bench_load.py`. It starts N CPU-busy worker processes and optionally one
memory-bandwidth worker, records their PIDs to a file, and stops only those PIDs on exit
or on `--stop`. It never kills by name. Calibrate N so that the inbox guard, run alone on
the accepted 0.26.0.0 source, reproduces a ratio of 1.2 or more for
`delegated-single.fresh.metrics-on` in at least three of five runs. With no load, the
same case should stay under 1.10. Record the chosen load profile, which is the
*reference load*. Then, under the reference load, measure that case and its family with
each candidate control applied identically to both binaries, five runs each:

1. Raise quality of service so macOS prefers performance cores. Run the benchmark
   executables, and if needed the `postgres` server, under `taskpolicy` with a higher
   QoS, and record the exact invocation.
2. Disable parallel GC (`+RTS -N2 -qg -RTS`), or keep parallel GC but stop idle GC
   threads from spinning (`-qn1`).
3. Isolate the PostgreSQL server by giving the benchmark run its own cluster started
   under the same QoS as the benchmark.

A control is adopted only if, under the reference load, every case of the inbox family
stays within 1.10× of its no-load ratio across five runs. It must also leave the no-load
ratios of all five families unchanged within their existing spreads. If several
controls qualify, adopt the smallest. If none does, record that, together with the load
level at which measurements stay trustworthy. Milestone 2 then implements detection and
waiting only. Discard the experimental runs' code once the conclusion is in the Decision
Log; keep the load generator and the evidence under
`keiro/bench/results/load-sensitivity/`.

Milestone 2 changes `scripts/bench_guard.py`. Apply the adopted control in `measure` to
reference, candidate and confirmation runs alike, and record it in each command JSON.
Add a capacity check before each family's reference measurement and before each
confirmation. Its signal is chosen in Milestone 1. The default is the one-minute load
average relative to `hw.perflevel0.physicalcpu`, plus a short calibration loop whose
timing is compared with a quiet-machine value cached per machine. When capacity is
insufficient, wait 60 seconds and recheck, up to 10 minutes per family. If capacity
returns, proceed. If not, end the family with status `environment-busy` and a message
naming the measured signal and threshold. If capacity drops during a family's
measurement, the affected comparison is re-measured once capacity returns, within the
same bounds. It is never reported as `inconclusive`. Thread the new status through
`scripts/bench-regression.sh` (`BENCH_REGRESSION=ENVIRONMENT_BUSY`) and
`scripts/release_workflow.py`, where it is a non-accepting stage result exactly like
`inconclusive`. Extend `scripts/tests/test_bench_guard.py` with tests for the
capacity wait, the eventual `environment-busy`, re-measurement after a mid-run drop, and
the control appearing identically in reference and candidate commands. Fake the capacity
signal in tests; do not sleep for real.

Milestone 3 is acceptance. Run it on the machine releases use, at its normal background
load plus the reference load. Then amend ADR-58 with the adopted control and the
capacity rule, and update the release skill (`agents/skills/release/SKILL.md`, step 4)
so the gate's new status and its meaning are documented.


## Concrete Steps


All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`, inside
the development shell. Never run raw `cabal` against `dist-newstyle` while a
`just` release or verify recipe holds the workspace lock.

Milestone 1, reproducing the failure (one run, repeat five times):

```bash
nix develop -c python3 scripts/bench_load.py --workers 24 --pidfile /tmp/keiro-bench-load.pid &
nix develop -c bash scripts/bench-regression.sh inbox
nix develop -c python3 scripts/bench_load.py --stop --pidfile /tmp/keiro-bench-load.pid
```

Read the case's ratio from the newest `keiro/bench/results/*inbox*/result.json`. Adjust
`--workers` until the failure reproduces. 24 is a starting point, not a result. Repeat
with each candidate control applied through the environment variable Milestone 2 will
formalize (for example `KEIRO_BENCH_RTS="-N2 -qg"`), and record every run's ratios in
`keiro/bench/results/load-sensitivity/README.md`.

Milestone 2 tests:

```bash
nix develop -c python3 -m unittest discover -s scripts/tests -p test_bench_guard.py
```

Expect all tests, old and new, to pass.


## Validation and Acceptance


Required acceptance:

1. Load robustness. With the reference load running, five consecutive
   `scripts/bench-regression.sh inbox` runs on unchanged source each print
   `BENCH_REGRESSION=PASSED`. A run that waited for capacity is acceptable;
   `INCONCLUSIVE` or `REGRESSION` is not.
2. Regression sensitivity. Temporarily add a 2 ms `threadDelay` to the timed action of
   `delegated-single` in `keiro/bench/InboxDelegatedBench.hs`, or reuse plan 315's
   `+20 ms/action` control for the command family. Run once on a quiet machine and once
   under the reference load. Both runs must print `BENCH_REGRESSION=REGRESSION` for the
   affected cases. Revert the injection afterwards; it must never be committed.
3. Busy refusal. With the load raised well beyond the reference load, a guard run prints
   `BENCH_REGRESSION=ENVIRONMENT_BUSY` within its 10-minute wait budget. It names the
   signal, and the release workflow refuses acceptance.
4. The full gate. `nix develop -c just release-gate --fresh` passes on the final
   candidate at normal background load. Retain its manifest and receipts.
5. Unit tests. `python3 -m unittest discover -s scripts/tests -p test_bench_guard.py`
   passes, including the new status tests.

The ceiling (1.25), historical CSVs, benchmark inventory and in-run assertions must be
byte-identical before and after; verify with
`git diff <start>..HEAD -- keiro/bench/baseline-* keiro/bench/*.hs`, which must be
empty because the slowdown injection is reverted.


## Idempotence and Recovery


The load generator records its PIDs and stops only those. If a session is interrupted,
run `scripts/bench_load.py --stop --pidfile /tmp/keiro-bench-load.pid`, or `kill` the PIDs
in that file after checking them with `ps -p`. Never use `pkill` or `killall`. Guard and
gate runs are repeatable; stage receipts make re-runs cheap. The slowdown injection
lives only in the working tree. Check `git diff keiro/bench/` is empty before
committing. If an adopted control later misbehaves, reverting `scripts/bench_guard.py`
and the ADR-58 amendment restores the previous behavior exactly. No baseline or stored
evidence depends on the new code.


## Interfaces and Dependencies


`scripts/bench_guard.py` gains one new result status, `environment-busy`, alongside
`passed`, `regression`, `inconclusive` and `benchmark-error`. It also gains a recorded
measurement-control field in each `*-command.json`. `scripts/release_workflow.py` must
treat `environment-busy` as non-accepting. Release evidence readers, including
`release-ready`, must not mistake it for a pass. On macOS the control may rely on
`taskpolicy` (in `/usr/sbin`) and on `sysctl` for core counts. Both are part of the base
system, not Nix. The guard must degrade to the load-average signal alone where they are
unavailable. No Haskell package, dependency bound or published API changes.
