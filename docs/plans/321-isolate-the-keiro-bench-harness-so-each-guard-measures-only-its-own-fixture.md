---
id: 321
slug: isolate-the-keiro-bench-harness-so-each-guard-measures-only-its-own-fixture
title: "Isolate the keiro-bench harness so each guard measures only its own fixture"
kind: exec-plan
created_at: 2026-10-21T13:07:00Z
intention: "intention_01m5f6g7yje5csts3eztsgvnws"
master_plan: "docs/masterplans/46-address-the-rev-20-review-findings-and-the-command-path-performance-regression.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-21T13:07:00Z
---

# Isolate the keiro-bench harness so each guard measures only its own fixture

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this plan, a benchmark guard in `keiro-bench` measures only the work its own scenario
does, on a database that only its own group has touched, in a process whose other groups
cannot change its numbers. Today that is not true: since 0.17.0.0 the benchmark's `main`
prepares the delegated-inbox fixture (a 100,000-event history, inbox tables, and one warm-up
run of every fresh scenario) in the same store the command group uses, before any benchmark
runs and whether or not the `-p` filter selects that group. Plan 315
(`docs/plans/315-attribute-the-command-path-append-slowdown-and-restore-trustworthy-benchmark-guards.md`)
showed the effect: with that preparation skipped, HEAD runs the command fan-out scenarios
three times faster and the single-command scenarios eight to nine times faster, and the
numbers return to what the harness measured at 0.16.0.0. The command scenarios also hard-delete
their target streams inside the timed action, so they pay Kiroku's replay-history guards on
every iteration although no serving path does, and the first scenario of several groups
absorbs a one-time cost that the committed baselines cannot see.

When this plan is complete, running `cabal bench keiro-bench --benchmark-options='-p command'`
alone and running the whole benchmark give the same command numbers within run-to-run noise,
no group's preparation runs unless a benchmark of that group is selected, no scenario deletes
or truncates inside its timed action unless the plan records why it must, and every group
starts with a throwaway warm-up benchmark whose row no baseline matches. Plan 315 then
re-records the baselines on the isolated harness.


## Progress

- [ ] M1: Each benchmark group owns its store and its preparation. `ordinaryMain` in
      `keiro/bench/Main.hs` opens one fresh migrated clone per group (`command`, `outbox`,
      `inbox`, the delegated-inbox `downstream` group, `producer-identity`, `projection`;
      `read-model` already has its own), every preparation runs on its own group's store
      inside `tasty-bench`'s `env` so it is evaluated only when a benchmark of that group is
      selected, and the acceptance below holds: the command rows from a filtered run and from
      a full run agree within noise, and a filtered `-p command` run prepares no inbox fixture
      (visible as the absence of the 100,000-event history build in the run's wall time).
- [ ] M2: No timed action resets state that a serving path never resets. The command and
      fan-out scenarios use a fresh target name per iteration (an `IORef` counter folded into
      the stream name) instead of `hardDeleteStream`; the fan-out scenarios likewise mint
      fresh target names per iteration instead of `resetFanoutTargets`; the outbox and inbox
      `TRUNCATE` resets stay only if the Decision Log records that a growing table would
      change the drain cost more than the truncate does, with a measurement. The growth bound
      per benchmark (iterations times streams) is stated in the evidence README.
- [ ] M3: First-run and order effects are outside the guarded rows. Every group begins with a
      throwaway warm-up benchmark named so that no baseline row matches it (for example
      `warm-up` under each group), the inbox group's first fresh downstream scenario no
      longer measures a multi-second first-run cost, the router fan-out rows at 10 and 100
      targets are no longer slower than at 1,000, and the `no-op` and `rejected` rows measure
      under 200 µs on an isolated store; whatever explained the 21 ms observed in plan 315's
      experiment is recorded in Surprises & Discoveries.
- [ ] M4: The evidence is recorded and the old READMEs corrected. A README under
      `keiro/bench/results/harness-isolation-v1/` holds the before and after numbers (shared
      store versus isolated, filtered versus full run, deletes versus fresh names), the
      machine, GHC, PostgreSQL and commit; `keiro/bench/results/delegated-inbox-v1/README.md`
      and `keiro/bench/results/producer-identity-v1/README.md` say that their fixtures now
      live in their own stores. Plan 315 is told it can re-record.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Isolate by database clone per group, not by schema or by running groups in
  separate processes.
  Rationale: `keiro-test-support` already clones a migrated template database in well under a
  second (`withFreshResourceStore`), the read-model group has used a second clone since it was
  written, and one process keeps `tasty-bench`'s `--baseline` comparison and CSV output in
  one place for the release gate.
  Date: 2026-10-21
- Decision: Replace per-iteration hard deletes with fresh names rather than keeping deletes
  and excluding them from timing.
  Rationale: `tasty-bench` has no per-run setup hook (its `env` runs once per benchmark, not
  once per sample), so a reset inside the action is always timed. A serving path never hard
  deletes, so the guard should not pay for it; a bounded growth of distinct streams across
  iterations is the smaller distortion, and its bound is recorded.
  Date: 2026-10-21


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

`keiro-bench` is the benchmark component of the `keiro` package (`cabal build
keiro:bench:keiro-bench`; stanza `benchmark keiro-bench` in `keiro/keiro.cabal`). It is a
`tasty-bench` program: `defaultMain` runs a tree of `bench` nodes, each timing an `IO` action
with `nfIO`, and the `--baseline <csv> --fail-if-slower 25` options compare each row with a
committed CSV by its full name (`All.command.domain.accepted-1`). A "guard" is one such
invocation of a group against its baseline; `scripts/bench-regression.sh` (owned by plan 316,
`docs/plans/316-run-the-benchmark-regression-guards-in-the-release-gate.md`) runs six of them.
`tasty-bench` exports `env`, which attaches a lazily evaluated setup value to a subtree so
the setup runs only if a benchmark in that subtree is selected by the `-p` pattern; it has no
per-sample hook, so anything inside the `nfIO` action is timed on every sample.

The program's entry point is `ordinaryMain` in `keiro/bench/Main.hs`. It calls
`withMigratedSuite` from `keiro-test-support` (`keiro-test-support/src/Keiro/Test/Postgres.hs`),
which starts one ephemeral PostgreSQL server with a migrated template database, then opens
two clones with `withFreshResourceStore`: `store`, used by the outbox, inbox, delegated-inbox,
command, projection and producer-identity groups, and `readModelStore`, used by the read-model
group. Before `defaultMain` it runs, unconditionally: `rebuildBenchSql` on `store`,
`setupReadModelBench` on `readModelStore`, and `prepareInboxDelegatedBenchmarks store metrics`
(`keiro/bench/InboxDelegatedBench.hs`), which creates the business table, prepares every
delegated-inbox scenario including `prepareHistoryRun store 100000`, and runs every fresh
scenario once. `producerIdentityBenchmarks store rebuildRunCounter`
(`keiro/bench/ProducerIdentityBench.hs`) truncates `keiro.keiro_outbox` inside its timed
action, as do the outbox scenarios (`runScenario`, `TRUNCATE keiro.keiro_outbox`) and the inbox
scenarios (`runInboxScenario`, `TRUNCATE keiro.keiro_inbox`). The command scenarios
(`commandScenarioBench`, `domainCommandScenarioBench`, around line 618) call
`Lifecycle.hardDeleteStream` on their target inside the timed action; the fan-out scenarios
(`domainRouterFanoutBench`, `domainProcessManagerFanoutBench`, around line 914) call
`resetFanoutTargets`, one hard delete per target, and the process-manager variant also deletes
its saga stream. The rebuild scenario deletes and reseeds three streams per iteration. A hard
delete in Kiroku 0.7 and later is a transaction of about eleven statements with a coordinator
lock and per-stream locks (`mori://shinzui/kiroku`, `kiroku-store/src/Kiroku/Store/Effect.hs`,
the `HardDeleteStream` branch), which is why a thousand of them dominate the fan-out rows.

The measurements that motivate this plan are in plan 315's Surprises & Discoveries: at HEAD
`03161924`, `router-fanout.1000` measures 2.01 s with the shared store and 662 ms with the
delegated-inbox preparation replaced by `pure []`; `domain.accepted-large` 44.2 ms versus
4.69 ms; and on the isolated run two rows were anomalous and systematic, `no-op` at about
21 ms (every other configuration measures it under 130 µs) and `router-fanout` slower at 10
and 100 targets (229 ms, 3.5 s) than at 1,000 (662 ms). The inbox group's first fresh
downstream scenario, `table-downstream-single.fresh.metrics-off`, measures 5.8 s ± 1.7 s in
a full run while its twin run second measures 418 ms (REV-20,
`docs/reviews/keiro-0-20-0-21-unreleased-review.md`, and REV-17 before it); the warm-up added
by `af37b955` runs once per scenario outside the action but did not remove the effect.

Relevant local ADRs: ADR-48
(`docs/adr/0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md`)
gives every retention leg a fresh migrated database and discards the first block as warm-up,
which is the pattern this plan brings to the benchmarks. No ADR covers benchmark baselines;
plans 315 and 316 produce one, and this plan's isolation rule (each group owns its store)
belongs in it. No cross-repository ADR applies.


## Plan of Work

Milestone 1 restructures `ordinaryMain`. Replace the two clones with one clone per group,
opened lazily: wrap each group's `bgroup` in `env` whose setup opens the group's
`withFreshResourceStore` clone and runs that group's preparation (the rebuild SQL for the
projection group, `prepareInboxDelegatedBenchmarks` for the delegated-inbox group, the
read-model fixture for its group), and whose value is the store and whatever the group needs.
`withFreshResourceStore` is bracket-shaped; `tasty-bench` 0.5.1 exports `envWithCleanup ::
NFData env => IO env -> (env -> IO a) -> (env -> Benchmark) -> Benchmark` for exactly that
shape, so a group's clone can be created in the acquire action and dropped in the cleanup
action, with `keiro-test-support`'s `withFreshDatabase` split into its create and drop halves
or wrapped through an `MVar` hand-off. The simpler form, opening all clones eagerly at the top
of `ordinaryMain` (cloning is cheap) and putting only the preparation inside `env`, is also
acceptable; the acceptance is behavioural. Keep `runGuardedCatalogEvidence` and the
explain-evidence hooks where they are.

Milestone 2 removes the in-action resets. Give `commandScenarioBench`,
`domainCommandScenarioBench`, `domainRouterFanoutBench` and `domainProcessManagerFanoutBench`
an `IORef Int` from the group's `env` value and fold its next value into the target stream
names (and the saga stream name) each iteration; delete the `hardDeleteStream` and
`resetFanoutTargets` calls from the actions. For the rebuild scenario, mint a fresh set of
three stream names and a fresh group id per iteration the same way. For the outbox and inbox
scenarios, measure both forms (truncate inside the action, versus fresh message ids and no
truncate) on the isolated store and keep the one the Decision Log justifies; the drain reads
the whole table, so a growing table changes the measured cost and the truncate may be the
right call. The producer-identity scenarios truncate the outbox and then enqueue 1,000 rows;
the truncate is one statement against 1,000 inserts and the same-process ratio cancels it,
so leave it and say so.

Milestone 3 adds warm-ups and explains the anomalies. Put a `warm-up` benchmark first in every
group that runs the group's cheapest scenario once; because no baseline row matches the name,
`tasty-bench` reports it without comparing. Then run the command group alone on the isolated
store and look at the `no-op` row: compare `EXPLAIN (ANALYZE)` of the statements the path
issues on the fresh clone with and without `ANALYZE` having run on `kiroku.streams` and
`kiroku.stream_events` (an unanalyzed empty table can draw a plan that is fine at ten rows and
not at ten thousand), and look at whether the first hard-delete-free iteration pays Kiroku's
coordinator lock. Record the cause; if it is planner statistics, run `ANALYZE` at the end of
each group's preparation and record that in the README.

Milestone 4 writes the evidence README and corrects the two older READMEs, then hands over to
plan 315 by recording in its Progress that the harness is isolated and re-recording may start.


## Concrete Steps

From the repository root inside `nix develop`:

```bash
cabal build keiro:bench:keiro-bench
# filtered run: the command group alone
cabal bench keiro-bench --benchmark-options='-p command --time-mode wall --hide-progress --csv /tmp/command-alone.csv'
# full run: every group, same baseline-free mode
cabal bench keiro-bench --benchmark-options='--time-mode wall --hide-progress --csv /tmp/all.csv'
# compare the command rows
join -t, <(grep '^All.command' /tmp/command-alone.csv | sort) <(grep '^All.command' /tmp/all.csv | sort) | awk -F, '{printf "%-55s %12.1f ms %12.1f ms\n", $1, $2/1e9, $4/1e9}'
```

Expected: every command row within run-to-run noise (about 10%) between the two columns, with
`router-fanout.1000` and `process-manager-fanout.1000` near 0.7 s and `no-op` under 0.2 ms.
The full run's wall time no longer includes a 100,000-event history build when the
delegated-inbox group is excluded:

```bash
time cabal bench keiro-bench --benchmark-options='-p command --time-mode wall --hide-progress'
```

For M3's anomaly, from `psql` against the clone the group used (the fixture prints its
connection string when `KEIRO_BENCH_KEEP=1` is set, or add that switch):

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT ... ;   -- the statements the no-op path issues, from pg_stat_statements or the log
ANALYZE kiroku.streams; ANALYZE kiroku.stream_events;
```


## Validation and Acceptance

M1: the `join` comparison above agrees within noise and the filtered run's wall time shows no
inbox preparation. M2: `grep -n "hardDeleteStream\|resetFanoutTargets" keiro/bench/Main.hs`
finds no call inside a `bench` action, and the README records the growth bound. M3: a full run
on the isolated harness shows the first fresh inbox scenario within 25% of its twin, the
fan-out rows monotone in target count, and `no-op` under 200 µs, with the cause of the 21 ms
written down. M4: the README exists with the before and after table and the two older READMEs
are corrected. The behavioural proof is plan 315's subsequent re-recording producing a
baseline that the control protocol reproduces.


## Idempotence and Recovery

Benchmark source edits only; `git checkout` restores them. Every run uses disposable clones
from the ephemeral template and never touches a persistent database. Scratch CSVs under
`/tmp` are not committed. If the fresh-name approach makes a scenario's store grow beyond
what the README's bound states, reduce the iteration budget with `--timeout` or `--stdev`
rather than reintroducing deletes.


## Interfaces and Dependencies

`keiro/bench/Main.hs`, `keiro/bench/InboxDelegatedBench.hs`, `keiro/bench/ProducerIdentityBench.hs`,
`keiro/bench/ReadModelBench.hs`; `keiro-test-support`'s `withMigratedSuite` and
`withFreshResourceStore`; `tasty-bench`'s `env`, `bench`, `nfIO`, `bcompareWithin`,
`--baseline`, `--csv`. The scenario names are an interface: plan 315's re-recorded baselines
and `scripts/bench-regression.sh`'s `-p` patterns depend on them, so keep every existing row
name and add only the `warm-up` rows. Plan 315's M3 to M6 hard-depend on this plan being
Complete. No parent milestone must be accepted before this plan begins.
