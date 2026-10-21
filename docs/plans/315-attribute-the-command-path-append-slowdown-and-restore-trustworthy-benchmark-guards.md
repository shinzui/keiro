---
id: 315
slug: attribute-the-command-path-append-slowdown-and-restore-trustworthy-benchmark-guards
title: "Attribute the command-path append slowdown and restore trustworthy benchmark guards"
kind: exec-plan
created_at: 2026-10-21T12:21:07Z
intention: "intention_01m5f6g7yje5csts3eztsgvnws"
master_plan: "docs/masterplans/46-address-the-rev-20-review-findings-and-the-command-path-performance-regression.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-21T12:21:07Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-21T13:02:16Z
      mode: "implement"
      note: "M1 and M2: tag sweep and no-preparation experiment attribute the fan-out slowdown to the benchmark harness"
---

# Attribute the command-path append slowdown and restore trustworthy benchmark guards

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this plan, a maintainer who runs `nix develop -c just bench-regression` on a quiet
machine sees all six benchmark guards pass, and the committed baselines each carry evidence of
what they measure and why their numbers are what they are. The owner knows which release and
which change in the event-store substrate made every append-heavy command scenario 25% to 239%
slower than its August 2026 baseline, and has either removed that cost or accepted it in a
retained evidence directory that a later reader can audit. The two other red guards, the
producer-identity ratio ceiling and the first fresh inbox scenario, pass for a reason that is
written down rather than because their numbers were re-recorded.

The user-visible behaviour is the gate itself: `just bench-regression` prints
`BENCH_REGRESSION=PASSED`, and `just release-gate` (see
`docs/plans/316-run-the-benchmark-regression-guards-in-the-release-gate.md`) can therefore go
green for the next release.


## Progress

- [x] M1 (2026-10-21): The attribution curve is recorded in Surprises & Discoveries. The
      control at the baseline commit `2477a5aa` failed (ten of fifteen rows outside the
      ceiling against its own CSV), so the August rows are not reproducible on this machine
      and the plan records that. The first release carrying the fan-out step is
      `keiro-0.17.0.0`: 0.16.0.0 measures 670 ms and 804 ms at 1,000 targets, 0.17.0.0 and
      every later point measure about 1.9 s. The tags 0.13.0.0 to 0.15.0.0 were deliberately
      not measured once the step was located above 0.16.0.0.
- [x] M2 (2026-10-21): The mechanism is isolated without the three-way micro-measurement:
      the two commits that changed the benchmark's startup in the 0.17.0.0 window seed the
      delegated-inbox fixture into the store the command group uses, and HEAD with that
      preparation skipped returns to the 0.16.0.0 level (662 ms and 777 ms at 1,000 targets)
      and runs the single-command scenarios eight to nine times faster. No Kiroku change
      needs naming; Kiroku 0.7's hard-delete guards add a bounded per-delete cost that only the
      harness's fixture reset pays. Two systematic anomalies in the no-preparation run
      (`no-op` at 21 ms, router fan-out slower at 10 and 100 targets than at 1,000) are
      recorded for M3.
- [ ] M3: The command baseline is re-recorded on the isolated harness. After plan 321
      (`docs/plans/321-isolate-the-keiro-bench-harness-so-each-guard-measures-only-its-own-fixture.md`)
      is Complete, `keiro/bench/baseline-command.csv` is recorded from five serial runs on
      this environment with a README under `keiro/bench/results/command-v2/` that states the
      attribution, the control protocol (the recording commit must reproduce its own rows
      within the ceiling) and the machine, GHC, PostgreSQL and commit. No Keiro serving path
      and no Kiroku change is involved.
- [ ] M4: The producer-identity guard passes for a stated reason. The same-process 1.10
      ceiling in `keiro/bench/ProducerIdentityBench.hs` is either met after a measured change
      or replaced by a guard whose rationale is recorded (for example an absolute per-row budget
      for the deterministic path's second statement), with the evidence directory
      `keiro/bench/results/producer-identity-v1/` extended rather than rewritten.
- [ ] M5: The inbox baseline is re-recorded on the isolated harness once plan 321's warm-up
      rows have removed the first-run cost from `table-downstream-single.fresh.metrics-off`
      (the harness change itself is plan 321's M3); acceptance is three consecutive passes of
      `just bench-regression inbox` on a quiet machine against the new rows.
- [ ] M6: `nix develop -c just bench-regression` prints `BENCH_REGRESSION=PASSED` three times
      in a row on a quiet machine, and the three logs are retained under
      `keiro/bench/results/release-gates/` or a plan-named directory.


## Surprises & Discoveries

The control point fails. Built and run at the baseline commit `2477a5aa` on 2026-10-21
(load average 2.3, no other compiler or benchmark), the guard reports ten of fifteen
scenarios outside the 25% ceiling against the CSV that this very commit recorded:
`accepted-1` 6.01 / 6.43 / 6.62 ms (+96% to +111%), `accepted-large` 76.3 / 98.8 ms (+196% /
+230%), `no-op` and `rejected` 1.23 to 1.28 ms (+57% to +61%), `router-fanout.10` 66.6 ms
(+104%). The same commit measures `router-fanout` 100 / 1000 at 40.2 ms / 400 ms and
`process-manager-fanout` 10 / 100 / 1000 at 3.97 / 37.9 / 416 ms, all faster than the CSV.
So the August rows are not reproducible on this machine for the single-command scenarios,
and the comparison that REV-20 reported for `accepted-1` and `accepted-large` (HEAD at 3.7 to
3.9 ms and 41.6 to 44.2 ms) is not a regression: on the same machine, HEAD is faster than the
baseline commit on every single-command scenario, and sixteen times faster on `no-op`.

The fan-out scenarios are a different story. On the same machine the baseline commit runs
`router-fanout.1000` in 400 ms and `process-manager-fanout.1000` in 416 ms, while HEAD runs
them in 2.01 s and 1.96 s and `keiro-0.19.0.1` in 1.86 s and 2.04 s. That five-fold slowdown
per dispatched target is real and lies between `2477a5aa` and `keiro-0.19.0.1`; the sweep
continues through the release tags to find the first one that carries it.

```text
scenario                        CSV (Aug)   2477a5aa today   0.19.0.1   HEAD
domain.accepted-1               3.13 ms     6.62 ms          3.88 ms    3.92 ms
domain.accepted-large           29.9 ms     98.8 ms          39.4 ms    44.2 ms
domain.no-op                    0.80 ms     1.26 ms          73 µs      75 µs
router-fanout.1000              629 ms      400 ms           1.86 s     2.01 s
process-manager-fanout.1000     579 ms      416 ms           2.04 s     1.96 s
```

A hypothesis for M2, formed before the remaining sweep points arrived. Both fan-out scenarios
call `resetFanoutTargets` inside the timed action (`keiro/bench/Main.hs`), which issues one
`Lifecycle.hardDeleteStream` per target before the router or manager dispatches to it, so a
1,000-target iteration performs 1,000 hard deletes. `keiro-0.19.0.0` (sweep point, 12:32Z)
measures `router-fanout.1000` at 1.945 s and `process-manager-fanout.1000` at 1.885 s, the
same as 0.19.0.1 and HEAD, so the slowdown entered at or before 0.19.0.0. Between the baseline
commit (`kiroku-store >=0.4 && <0.5`) and `keiro-0.13.0.0`, commit `33c557ab` (2026-08-16)
adopted `kiroku-store` 0.8.0.0, and Kiroku's 0.7.0.0 release notes (2026-08-13,
`kiroku-store/CHANGELOG.md` in `mori://shinzui/kiroku`) say: "Supported hard delete checks
retention before mutation and locks every affected stream in ascending ID order, including
streams containing links to target-originated events", and that append, link, lifecycle
mutation and every supported hard delete serialize behind a transaction-scoped stream guard.
If the follow-up points `33c557ab~1` and `33c557ab` differ by the fan-out cost, the slowdown
is the price of Kiroku's replay-history protection paid by the benchmark's fixture reset, not
by any serving path, and M3's answer is to move the reset outside the timed action and
re-record, not to change Keiro or Kiroku. The dispatch path itself issues one identity probe
per target for an ASCII seed (`Keiro.DeterministicId.deterministicIdProbes` adds the legacy
probe only when the seed moved across encodings) and then one command run, at the baseline
commit and at HEAD alike.

The `keiro-0.16.0.0` point (12:39Z) weakens that hypothesis: `router-fanout.1000` 670 ms and
`process-manager-fanout.1000` 804 ms, near the baseline commit rather than the 1.9 s of
0.19.0.0, so the step lies between 0.16.0.0 and 0.19.0.0, after the Kiroku 0.7 guards were
adopted. The strongest candidate in that window is the benchmark process itself: since
0.17.0.0, `keiro/bench/Main.hs` calls `prepareInboxDelegatedBenchmarks store metrics` before
`defaultMain`, on the same `store` the command group uses and regardless of the `-p`
filter. `keiro/bench/InboxDelegatedBench.hs` shows what that does: it creates the business
table, prepares every delegated-inbox scenario including a 100,000-event history
(`prepareHistoryRun store 100000`), and runs every fresh scenario once as a warm-up. Every
command scenario since 0.17.0.0 therefore appends to and hard-deletes from a store that
already holds that fixture's events, junction rows and inbox tables, while the August
baseline was recorded against a store holding only the rebuild fixture. An experiment is
queued behind the follow-up points: HEAD with that preparation replaced by `pure []`, same
guard, same baseline. If the fan-out rows return to the 0.16.0.0 range, the slowdown is the
harness, not any serving path, and M3 isolates the command group's store before
re-recording.

The remaining points settled it. `keiro-0.18.0.0` (12:46Z) measures the fan-out rows at
1.80 s and 2.03 s, the same level as 0.19.0.0, 0.19.0.1 and HEAD. `keiro-0.17.0.0` (12:53Z)
measures them at 21.7 s ± 48 s and 21.6 s ± 48 s, a spread larger than the mean, which
`tasty-bench` reports as "same as baseline" because it cannot compare; that run is an outlier
of the same harness, not a different code state. Both commits that changed the benchmark's
startup, `73231189` (the delegated-inbox evidence and its preparation on the shared store)
and `af37b955` (the fresh-scenario warm-up inside that preparation), are first contained in
`keiro-0.17.0.0`; nothing in `keiro/bench/InboxDelegatedBench.hs` changed between 0.17.0.0 and
0.18.0.0. The sweep was stopped after 0.17.0.0 and the August-window points were not run,
because the step is above 0.16.0.0 and the August changes cannot be its cause.

The experiment then ran at HEAD (`03161924`) with `prepareInboxDelegatedBenchmarks store
metrics` replaced by `pure []` and nothing else changed (12:55Z to 13:00Z, load average 1.5):

```text
scenario                        HEAD with preparation   HEAD without preparation   0.16.0.0
domain.accepted-1               3.92 ms                 0.467 ms                   (n/a)
domain.accepted-large           44.2 ms                 4.69 ms                    25.6 ms
router-fanout.1000              2.01 s                  662 ms                     670 ms
process-manager-fanout.1000     1.96 s                  777 ms                     804 ms
domain.no-op                    75 µs                   21.4 ms                    121 µs
router-fanout.10 / 100          108 ms / 678 ms         229 ms / 3.50 s            54 ms / 555 ms
```

The 1,000-target rows return exactly to the 0.16.0.0 level and the single-command rows become
eight to nine times faster than with the preparation (and four to six times faster than the
committed August rows). The command guard has therefore measured, since 0.17.0.0, a store that
another group's fixture had already filled with a 100,000-event history, inbox tables and the
warm-up traffic of every fresh delegated-inbox scenario; no serving path of Keiro or Kiroku
got slower. Two rows in the no-preparation run are anomalous and systematic (tight spreads):
`no-op` and `rejected` at about 21 ms where every other configuration measures them under
130 µs, and `router-fanout` at 10 and 100 targets slower than at 1,000. They show that the
command group's cost also depends on store state and on run order within the process, which
is M3's problem to remove before any row is re-recorded; they do not change the attribution,
which rests on the 1,000-target and single-command rows.


## Decision Log

- Decision: The baseline commit `2477a5aa` is the control for the sweep and must pass before
  any later point is interpreted.
  Rationale: The August baseline was recorded on a machine and PostgreSQL version that may not
  match today's; a sweep that cannot reproduce the baseline at its own commit says nothing
  about later commits.
  Date: 2026-10-21
- Decision: Because the control failed, M3 re-records the single-command rows of
  `keiro/bench/baseline-command.csv` on the current environment regardless of the fan-out
  outcome, and the fan-out rows only after M2 attributes their five-fold slowdown.
  Rationale: A baseline that its own commit cannot reproduce guards nothing. The
  single-command rows moved with the environment, not the code (HEAD beats the baseline
  commit on the same machine); the fan-out rows moved with the code and must not be
  re-recorded until the cause is known and either fixed or accepted.
  Date: 2026-10-21
- Decision: Attribute the fan-out slowdown to the benchmark harness (the delegated-inbox
  preparation seeding the shared store since 0.17.0.0), fix the harness, and file no
  improvement request against Kiroku.
  Rationale: The no-preparation experiment at HEAD reproduces the 0.16.0.0 numbers exactly;
  the serving paths did not change cost. Kiroku 0.7's hard-delete guards are real but are paid
  only by the fixture reset, which M3 moves out of the timed action. This replaces the M2
  micro-measurement and the M3 "fix or accept" fork that the plan originally described.
  Date: 2026-10-21

- Decision: Split the harness work out of this plan into plan 321 and make M3 to M6 depend on
  it.
  Rationale: Fixing the harness (per-group stores, resets outside timed actions, warm-ups)
  changes every group's numbers and is verified by its own isolation test, while this plan's
  remaining work is recording baselines and proving the gate green; keeping them apart lets
  the harness be reviewed on its own and prevents a baseline from being recorded on a
  half-isolated harness.
  Date: 2026-10-21

Revision note (2026-10-21): M1 and M2 were completed by a tag sweep (control, 0.16.0.0,
0.17.0.0, 0.18.0.0, 0.19.0.0, 0.19.0.1, HEAD) and one controlled experiment rather than by the
three-way micro-measurement first planned, because the sweep placed the step in the 0.17.0.0
window where only the benchmark's own startup changed. M3 now means isolating the command
group's store and re-recording; the "improvement request in Kiroku" branch is withdrawn.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Keiro is an event-sourcing framework over the Kiroku PostgreSQL event store. A command runner
(`keiro/src/Keiro/Command.hs`) loads a stream's events, decides, and appends new events; the
benchmark `keiro-bench` (`keiro/bench/Main.hs`, built by `cabal build keiro:bench:keiro-bench`)
measures that cycle in a `command` group and compares each scenario with a committed baseline
row using `tasty-bench`'s `--baseline` and `--fail-if-slower 25` options. A "guard" in this
plan means one such comparison; `just bench-regression` runs six of them (see
`scripts/bench-regression.sh`), and `keiro/bench/baseline-command.csv` holds the fifteen
command rows, recorded on 2026-08-11 at commit `2477a5aa` (`git log -1 2477a5aa`).

Each command scenario's timed action is in `keiro/bench/Main.hs`, functions
`commandScenarioBench` and `domainCommandScenarioBench` (around line 618): it hard-deletes the
target stream with `Lifecycle.hardDeleteStream`, then runs `runCommand` or `runDomainCommand`,
which creates the stream again and appends. The `router-fanout` and `process-manager-fanout`
scenarios dispatch to 10, 100, or 1,000 target streams per iteration. The `no-op` and
`rejected` scenarios hydrate and decide without appending.

REV-20 (`docs/reviews/keiro-0-20-0-21-unreleased-review.md`, section "Hot-path performance")
ran the guard twice at commit `a62850d3` and once from a worktree at `keiro-0.19.0.1`. At HEAD,
ten of fifteen scenarios fail: `control.accepted-1` +27%, `domain.accepted-1` +25%,
`legacy.accepted-large` +61%, `domain.accepted-large` +48%, `router-fanout` 10/100/1000
+231%/+99%/+219%, `process-manager-fanout` 10/100/1000 +192%/+194%/+239%; the no-append
scenarios are 90% faster. At `keiro-0.19.0.1`, nine of fifteen fail with the same shape. So the
regression against the August baseline predates the 0.20.0.0 window, and a paired comparison
between 0.19.0.1 and HEAD found at most a small, order-sensitive difference on router fan-out.
The releases between the baseline and 0.19.0.1 are `keiro-0.13.0.0` (the baseline commit is
contained in 0.12.0.0 and 0.13.0.0), 0.14.0.0 (2026-08-21), 0.15.0.0 (08-30), 0.16.0.0
(09-07), 0.17.0.0 (09-17), 0.18.0.0 (09-20), and 0.19.0.0 (09-25). Of these, 0.19.0.0 adopted
Kiroku 0.9 with migration `0012`, which backfilled the category on every `$all` junction row
and added the index category reads use (see the root `CHANGELOG.md`, section 0.19.0.0), and
0.17.0.0 adopted the pgmq 0.6 family and shibuya-pgmq-adapter 0.16. The Kiroku checkout is
registered in Mori as `mori://shinzui/kiroku` at
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`; its store changelog is
`kiroku-store/CHANGELOG.md` and its migrations are under `kiroku-store-migrations/migrations/`.

The other two red guards are documented in the same review section. The producer-identity
guard (`keiro/bench/ProducerIdentityBench.hs`) compares `deterministic-fresh-1000` with
`legacy-fresh-1000` in the same process under `bcompareWithin 0 1.10`; it measured 1.11x and
1.12x where the retained evidence (`keiro/bench/results/producer-identity-v1/precision.csv`)
recorded +3.22%, with both absolute times halved since then. The deterministic path issues two
statements per row, an `ON CONFLICT DO NOTHING` insert and a locked read through both unique
keys (ADR-42, `docs/adr/0042-producer-outbox-identity-is-a-versioned-source-event-contract.md`),
so a substrate whose per-transaction cost fell faster than its per-statement cost moves the
ratio without any code change. The inbox guard's `table-downstream-single.fresh.metrics-off`
scenario, the first fresh downstream scenario the process executes, measured 5.82 s ± 1.72 s
against a 719 ms baseline while its `metrics-on` twin, run second, measured 418 ms; REV-17
recorded the same position effect, and commit `af37b955` added a warm-up outside the timed
action and re-recorded the baseline from five serial runs (`keiro/bench/results/delegated-inbox-v1/README.md`,
"fresh-warmup" paragraphs) without removing it.

Relevant local ADRs: ADR-48
(`docs/adr/0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md`)
describes the retention suite's gate thresholds and warm-up discard; its "regression gates,
not proof" stance applies here. ADR-42 explains the producer path. No ADR records how benchmark
baselines are recorded or when they may move; M3 and the companion plan 316 should produce one.
No cross-repository ADR was found relevant beyond Kiroku's own release notes.


## Plan of Work

Milestone 1 completes the attribution curve. The sweep script below creates a detached worktree
per reference, builds `keiro-bench` from the normal Cabal store, runs the command guard against
HEAD's baseline file, and removes the worktree. Run it on a quiet machine (no other compiler,
test, or benchmark) and record the per-scenario numbers for every point in Surprises &
Discoveries as a table in prose or a short `text` block. The control point `2477a5aa` must pass
within the 25% ceiling on every scenario except the known-noisy `legacy.accepted-1` row (its
baseline spread is 1.8 ms on a 2.0 ms mean); if it does not, stop and record that the baseline
is not reproducible on this machine, which changes M3's options.

Milestone 2 isolates the mechanism at the first failing tag. Write a small driver next to the
retained inspection drivers (`scripts/inspection-*.hs` are the precedent) or extend
`keiro/bench/Main.hs` behind a new `-p` group that times, separately and on a fresh stream each
iteration, (a) `Lifecycle.hardDeleteStream` of a 1-event stream, (b) `appendToStream` with
`NoStream` creating a new stream with one event, and (c) `appendToStream` of one event to an
existing 1,000-event stream. Run it at the last passing tag and the first failing tag from the
same worktree procedure. The one whose ratio moves is the mechanism; then read that tag's
Kiroku migration or store change (`git -C /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku log`
between the two kiroku-store versions the Keiro tags bound) and name it. Also check whether the
slowdown exists in production terms, that is, whether (b) or (c) moved and not only (a), because
a hard delete never happens on a serving path.

Milestone 3 decides. If (b) or (c) moved and the cause is a Kiroku index or statement, file an
improvement request in the Kiroku repository with the two-tag measurement attached, and record
the request's `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-N` handle here; the
Keiro bound moves when a fix ships. If only (a) moved, the benchmark measures a lifecycle cost
no serving path pays: move the hard delete outside the timed action (tasty-bench has no
per-sample setup hook, so use the pattern `keiro/bench/InboxDelegatedBench.hs` uses for fresh
scenarios, pre-creating a pool of distinct target names and consuming one per iteration) and
re-record the baseline from five serial runs with a README that explains the change. If the
cost is accepted as the price of the substrate, re-record the baseline the same way and say so
in the README. In every case the README lives under `keiro/bench/results/command-v2/` (or a
later version) and names the machine, GHC, PostgreSQL version, and the commit.

Milestone 4 settles the producer guard. Measure the absolute per-row cost of the deterministic
path's second statement at HEAD and at `keiro-0.19.0.1` with the same filter
(`-p '/producer-identity/'`). If the absolute overhead per 1,000 rows is unchanged while the
ratio moved, replace `bcompareWithin 0 1.10` with a guard on the quantity the plan actually
promised (ADR-42's rationale was "about 3% on a 1,000-row enqueue", which is an absolute
budget of a few milliseconds, not a ratio) and record the change in the evidence README. If the
overhead itself grew, treat it like M2 and M3.

Milestone 5 makes the first fresh inbox scenario robust. The warm-up added by `af37b955` runs
once per scenario outside the timed action, yet the first fresh scenario still absorbs a
multi-second cost with a standard deviation near its mean. Add a throwaway fresh scenario that
runs first and is excluded from the baseline comparison (tasty-bench matches baseline rows by
name, so an unmatched row is reported but never fails), or move the cold cost into an explicit
setup phase, and prove it with three consecutive passes.

Milestone 6 is the acceptance run: three consecutive `just bench-regression` passes on a quiet
machine, logs retained.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` inside
`nix develop`. The sweep script, written to a scratch location of your choice:

```bash
#!/usr/bin/env bash
# Sweep the command guard across references; each is built in a detached worktree.
set -u
H=/Users/shinzui/Keikaku/bokuno/keiro
S=/tmp/keiro-command-sweep           # any scratch directory
LOG=$S/bisect.log
BASELINE=$H/keiro/bench/baseline-command.csv
mkdir -p "$S/bisect"
for ref in 2477a5aa keiro-0.19.0.0 keiro-0.16.0.0 keiro-0.18.0.0 keiro-0.17.0.0 keiro-0.14.0.0 keiro-0.15.0.0 keiro-0.13.0.0; do
  W="$S/bisect/$ref"
  echo "##### $ref $(date -u +%FT%TZ)" >> "$LOG"
  git -C "$H" worktree add --detach "$W" "$ref" >> "$LOG" 2>&1 || continue
  ( cd "$W" && nix develop -c cabal build keiro:bench:keiro-bench ) >> "$LOG" 2>&1
  echo "EXIT($ref:build)=$?" >> "$LOG"
  ( cd "$W" && nix develop -c cabal bench keiro-bench --benchmark-options="-p command --time-mode wall --hide-progress --baseline $BASELINE --fail-if-slower 25" ) >> "$LOG" 2>&1
  echo "EXIT($ref:bench)=$?" >> "$LOG"
  git -C "$H" worktree remove --force "$W"; git -C "$H" worktree prune
done
echo "SWEEP_DONE" >> "$LOG"
```

Entering `nix develop` from a worktree initializes a PostgreSQL cluster under `<worktree>/db`
through the dev-shell hook (`nix/haskell.nix`, lines 124 to 136); the worktree removal deletes
it. Expect each reference to take three to eight minutes once the store has the dependency
cohort. Read the per-scenario lines with:

```bash
awk '/^##### /{ref=$2} /: *(OK|FAIL)/{name=$1} /ms ±|s ±|μs ±/{print ref, name, $0}' /tmp/keiro-command-sweep/bisect.log
```

For a single guard rerun at HEAD:

```bash
nix develop -c just bench-regression command
```

Expected tail of a passing run:

```text
##### guard summary 2026-10-21T13:00:00Z
GUARD(command)=0
BENCH_REGRESSION=PASSED
```

To re-record a baseline after M3 approves it, run the guard five times serially without
`--baseline`, writing each to a CSV with `--csv`, take the median mean and median two-standard-
deviation per row, and write them to `keiro/bench/baseline-command.csv` in the same column
order; `keiro/bench/results/delegated-inbox-v1/README.md` describes the identical procedure for
the inbox rows.


## Validation and Acceptance

M1 is accepted when Surprises & Discoveries holds the sweep table and names the first failing
tag, and the control point passed. M2 is accepted when the three-way micro-measurement at the
two adjacent tags is recorded with its driver source checked in and the Kiroku change is named.
M3 is accepted when either the improvement request handle is recorded or the new baseline and
README are committed, and `just bench-regression command` passes. M4 is accepted when
`just bench-regression producer-identity` passes and the evidence README explains the guard.
M5 is accepted by three consecutive passes of `just bench-regression inbox`. M6 is accepted by
three consecutive passes of the full `just bench-regression`, each log ending in
`BENCH_REGRESSION=PASSED` and retained in the repository.

Re-recording a baseline because it fails, without an attributed cause, is explicitly not
acceptance.


## Idempotence and Recovery

The sweep is idempotent: worktrees are created and removed per reference, and a failed build
leaves its `EXIT(ref:build)` line and moves on. If a worktree is left behind (`git worktree
list`), remove it with `git worktree remove --force <path>` and `git worktree prune`. Baseline
files are only replaced under M3 or M4 with a committed README; `git checkout --
keiro/bench/baseline-command.csv` restores the August rows. The micro-measurement driver must
use a fresh database clone per run (`withMigratedSuite` from `keiro-test-support`) so repeated
runs do not accumulate state.


## Interfaces and Dependencies

`keiro/bench/Main.hs`, `keiro/bench/ProducerIdentityBench.hs`, and
`keiro/bench/InboxDelegatedBench.hs` define the scenarios; `tasty-bench` supplies `--baseline`,
`--fail-if-slower`, `--csv`, `bcompareWithin`. `scripts/bench-regression.sh` and the
`bench-regression` recipe are owned by plan 316 and must keep printing `GUARD(name)=status` and
`BENCH_REGRESSION=PASSED|FAILED`. `Keiro.Workflow.Lifecycle.hardDeleteStream` and Kiroku's
`appendToStream` are the operations M2 separates. The Kiroku checkout at
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` is read-only for this plan; changes
there go through an improvement request. M1 and M2 needed no prerequisite; M3 to M6 require
plan 321 (`docs/plans/321-isolate-the-keiro-bench-harness-so-each-guard-measures-only-its-own-fixture.md`)
to be Complete, because a baseline recorded on the shared-store harness would freeze the
distortion this plan found.
