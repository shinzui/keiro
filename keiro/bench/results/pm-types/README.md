# Mounted process-manager discovery measurements

Implementation baseline: `d61aabcfdaa4af14aef59712f10deb4826f0e99b`, preserved
in the detached `../keiro-pm-types-baseline` worktree. The only initial dirty
file was unrelated plan 304; it is excluded from implementation commits.

Machine: Mac17,15, arm64 Darwin 27.0.0, 36 logical CPUs, 256 GiB RAM.
Nix development shell: GHC 9.12.4, Cabal 3.16.1.0, PostgreSQL 18.6,
Z3 4.16.0. Cabal's build profile is `-O1`; benchmarks use `+RTS -N2 -T -RTS`.
Each trial records the actual PostgreSQL server version and settings. The
benchmark refuses settings other than fsync, synchronous_commit,
full_page_writes and autovacuum all enabled. Each disposable database starts
with 100,000 workflow rows and 100,000 timers, finishes setup with CHECKPOINT,
and warms 50 complete writer operations. Timed operations perform real workflow
creation/claim/resume and timer schedule/claim/fire work. No production database
is used. Benchmarks run serially, after builds finish.

Pre-change protocol, from the repository root in `nix develop`:

```bash
cabal build all --enable-tests --enable-benchmarks
cabal bench inspection-interference --benchmark-options='--output ../keiro/bench/results/pm-types/baseline-capacity --rate saturation --trials 5 --mode disabled +RTS -N2 -T -RTS'
cabal bench inspection-interference --benchmark-options='--output ../keiro/bench/results/pm-types/baseline-idle --rate 50 --trials 5 --mode idle +RTS -N2 -T -RTS'
just bench-regression
```

The two benchmark output paths above are relative to `keiro-ops-http`.
Saturation measures 1,000 writer operations per trial. Paced trials default to
20 seconds; rate 50 is a probe pending the measured capacity. The six guards
include the command subset and retain their complete log separately.

Final matched protocol uses `scripts/measure-pm-types.sh` with executable paths
obtained independently from `cabal list-bin bench:inspection-interference` in
each checkout. It never searches binary directories. At least five pairs
alternate order, preserving every trial and executable hashes. Disabled and
empty-hook idle comparisons measure code-change effects. Successful new polling
is compared against candidate catalog-mounted idle and pre-change idle, never
against the old route's error response. Same-source idle pairs measure noise.
Disabled saturation pairs measure capacity independently of offered throughput.

`scripts/analyze-pm-types.py` uses seed 323 and 20,000 bootstrap resamples of
whole paired trial ratios; writer operations within a trial are not independent
samples. Ratios above one mean degradation, including inverted throughput
ratios. It reports paired medians and percentile 95% intervals for throughput,
p95, p99 and writer-thread allocation per operation. Missing measurements,
rejected/missing polling, lost offered writer load, detected degradation or
insufficient resolution fail acceptance. All observations are retained.
Intervals must exclude 1% degradation; 1% is a resolution requirement, never an
allowed slowdown budget. An adverse median is conservatively inconclusive
pending additional paired evidence. Combined-process allocation is diagnostic.

Retention runs use `KEIRO_INSPECTION_RETENTION_SECONDS=60` for both new active
catalog sizes. Post-major-GC heap and active threads are sampled every five
seconds with before/after cleanup observations. Raw timing/retention artifacts,
gate logs and acceptance conclusions will be recorded here as they become
available. No performance acceptance is claimed by this protocol alone.

## Pre-change observations

Five saturation trials measured 702.49, 705.10, 718.89, 719.35 and 752.53
operations/second (sorted; median 718.89). This fixes the offered rate at 50
operations/second, about 7% of median capacity. Five mounted-idle trials retained
all 1,000 samples each, with throughput 50.025–50.040 operations/second,
p95 7,428–8,792 microseconds and p99 8,192–9,904 microseconds. Their latency
spread establishes substantial pre-existing noise; paced throughput cannot prove
unchanged capacity. Actual server settings in every trial were PostgreSQL 18.6
with all four required durability/autovacuum settings enabled.

`baseline-guards.log` records the complete pre-change six-guard run. Producer,
outbox, inbox, command and projection pass. Read-model fails
`serving-binding/versioned-three` at 81.8 microseconds, just beyond its historical
25% ceiling. `baseline-read-model-retry.log` preserves the focused repeat, which
fails different cases: `legacy-three` at +30% and `repair/100` at +38%.
Production sources were still unchanged when these executables were built and
started. Concurrent documentation-only commits changed HEAD but no production
source relative to the detached baseline. These are red controls and do not
establish acceptance; no CSV or threshold has been changed.

The controller's seven positive/negative checks pass in the Nix shell, including
refusal of a supported 0.1% slowdown, intervals that lack resolution, missing
trials/raw samples and rejected/lost polls. Run them with:

```bash
nix develop -c python3 -m unittest discover -s scripts/tests -p test_pm_types_measurements.py
```

## Functional acceptance

`candidate-tests-final.log` records 919 passing examples: 786 core, 55 ops,
53 HTTP and 25 Jitsurei examples. The metadata handler succeeds with a store
observer armed to throw on any connection access; a negative control proves an
actual read throws. JSON and human rows are forced. All inspector families,
aliases and snapshot policy constructors are covered, including a configured
codec with `never` and null timer capability. HTTP uses only aggregate-types'
verifier work and preserves its schema/size/method policies.

The first run (`candidate-tests.log`) exposed an optimized custom-policy
mislabeling and a sentinel fixture that needed setup/cleanup outside its armed
window. Those failures are preserved. `custom-policy-corrected.log` and the final
full run establish the fixes. A private `OPAQUE policyLabel` keeps the constructor
match separate from the existential traversal on GHC 9.12.4. Interpreted probes
return `custom` without the boundary, while compiled probes and the original
optimized regression test require it. Optics/direct field reads, explicit record
patterns, an opaque callback and a `NOINLINE` traversal did not fix the compiled
result. No runtime command, reaction, timer, hydration or snapshot code changes.

Before retaining that scoped boundary, registry/upstream discovery verified
GHC 9.12.4 as released (tag `1b7c33460847bb8017142407b853811fd8d04bff`),
with 9.14.1 newer (tag `961b2ffcc02ea6c93df649fc8367458378fa7aa5`).
The compiler pin and dependency bounds remain unchanged. ADR-53/ADR-55 and the
HTTP guide document the lasting interface and verification constraints; their
strict profile checks are retained in `metadata-validation.log`.

The real-server smoke runs (`smoke-single` and `smoke-many`) each complete all 80
successful polls with zero refusals, validating every field for one and 1,000
descriptors respectively. Their feed resource observations return to zero views,
zero connections and no wake pump. These diagnostic trials verify the harness;
they are not the alternating paired performance acceptance cohort.
