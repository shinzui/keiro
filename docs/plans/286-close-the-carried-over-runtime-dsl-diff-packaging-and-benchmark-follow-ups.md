---
id: 286
slug: close-the-carried-over-runtime-dsl-diff-packaging-and-benchmark-follow-ups
title: "Close the carried-over runtime, DSL diff, packaging, and benchmark follow-ups"
kind: exec-plan
created_at: 2026-09-16T18:25:28Z
intention: "intention_01m2nqd9hre9gbhw37aagtf066"
master_plan: "docs/masterplans/43-address-the-rev-17-keiro-0-17-0-0-release-readiness-findings.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-16T18:25:28Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-18T02:20:09Z
      mode: "implement"
      note: "Refreshed carried follow-ups against the post-release-readiness tree and began implementation"
---

# Close the carried-over runtime, DSL diff, packaging, and benchmark follow-ups

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The 0.17.0.0 release review (`docs/reviews/keiro-0-17-release-readiness.md`, REV-17)
approved the shipped code but left five follow-ups that do not block the tag. This plan
closes all five so that the next release cycle does not carry them again. After it is
complete: a reaction that dispatches commands but schedules no timers no longer opens an
empty database transaction on every delivery; `keiro-dsl diff` no longer reports a guard
hazard against a hand-written replay-only transition that is logically identical to the one
it would have computed; the twelve deprecated read-model APIs in `keiro` state an honest removal
window instead of one that expired four releases ago; the two non-conformance stanzas in
`keiro-dsl.cabal` that depend on internal packages without a version bound get one; and the
delegated-inbox benchmark's fresh-traffic guard stops failing on whichever scenario happens
to run first in a process. Each outcome is observable on its own: a probe count in the
reaction proof script, a `diff` transcript with no advisory, a compiler warning whose text
names a real window, a `cabal build` that solves with the new bounds, and a
scoped inbox benchmark-regression run that passes on a quiet machine.


## Progress

- [x] M1: `runTimerPhase` skips the transaction when no follow-up is a timer operation, the
      opt-in probe emits a `timer-phase` marker, and the reaction proof script asserts zero
      markers for the no-action conformance case.
- [x] M1: `keiro/CHANGELOG.md` records the change under `Unreleased`.
- [x] M2: `coversBody` in `keiro-dsl/src/Keiro/Dsl/Diff.hs` accepts an existing replay-only
      sibling whenever every old alternative implies the union of the new live guards and the
      sibling's guard.
- [x] M2: the partial-twin cases in `keiro-dsl/test/diff-test.sh` and `keiro-dsl/test/Main.hs`
      assert no advisory; every hazard-hiding case still fails as before.
- [x] M2: `keiro-dsl/CHANGELOG.md` states the coverage rule precisely.
- [x] M3: the twelve `DEPRECATED` pragmas in `keiro/src/Keiro/ReadModel.hs` name the Language 4
      read-model generator as their removal boundary; `keiro/CHANGELOG.md` records it.
- [x] M4: `keiro-dsl-runtime-vocabulary-test` and `keiro-dsl-codec-bench` carry bounds on
      `keiro` and `shibuya-core`; `cabal build all` solves; `keiro-dsl/CHANGELOG.md` records it.
- [x] M5: the first-run cost in `keiro/bench/InboxDelegatedBench.hs` is identified with
      evidence and removed from the timed action.
- [x] M5: the fresh downstream rows in `keiro/bench/baseline-inbox.csv` are re-recorded from
      five paired runs on a quiet machine; historical rows are byte-identical; the evidence
      README carries a dated addendum; the scoped inbox regression passes all 49 rows.
- [ ] Final: Outcomes & Retrospective written and the ADR distillation pass done; final clean-tree gate remains.


## Surprises & Discoveries

- The reviewed count of ten read-model deprecations omitted the `strongScope` field and
  `runQueryWith`; all twelve pragmas carried the same expired boundary and now name the
  Language 4 generator retirement.
- The nominal-ID work that landed after this plan changed the structural-nominal baseline
  fixture without updating its prefix, binding, and enum evolution variants. The full diff
  script exposed invalid guard and emitted-event references; the three variants now carry
  the same register, guard, and routing surface and the script passes end to end.
- Prebuilding 64 complete `DownstreamRun` values retained enough live heap to increase both
  mean and variance. The stable fix is one complete untimed warmup for every fresh scenario;
  steady-state input construction remains measured and no large pool remains live.
- The full `just bench-regression` recipe passed producer identity, outbox, and all 49 inbox
  rows, then exposed unrelated cold-start failures in the command group. The refreshed
  acceptance therefore uses the repository's exact inbox subcommand; command baselines were
  not changed by this plan.


## Decision Log

- Decision: Prove the empty-transaction fix through the existing opt-in probe flag and the
  reaction proof script rather than a new store-level transaction counter.
  Rationale: the repository already proves reaction store activity by counting stderr
  markers emitted under the manual `reaction-hydration-probe` Cabal flag
  (`keiro-dsl/test/process-hydration-test.sh`), and the no-action conformance case already
  asserts zero markers. Adding one marker to the timer phase makes that existing assertion
  fail before the fix and pass after it, with no new test infrastructure.
  Date: 2026-09-16
- Decision: Relax existing-twin coverage to semantic implication rather than reverting to the
  0.16 rule that accepted any replay-only sibling.
  Rationale: the 0.16 rule hid hazards (a stale or partial sibling suppressed a real
  finding); the 0.17 rule is sound but emits a false advisory for a hand-simplified twin.
  Accepting a sibling when every old alternative implies "new live union or sibling guard"
  keeps every hazard-hiding test red and removes the false positive.
  Date: 2026-09-16
- Decision: Restate the read-model deprecation window instead of removing the names.
  Rationale: the Language 4 read-model generator still emits `ConsistencyMode`,
  `StrongScope`, `defaultConsistency`, `EntireLog`, and `CategoryHead`, and twelve frozen
  conformance corpora import them. Published-language output is frozen byte for byte, so the
  names cannot leave `keiro` until that generator is retired.
  Date: 2026-09-16
- Decision: Re-record only the fresh downstream baseline rows, and only after the first-run
  cost has been removed and demonstrated on a quiet machine.
  Rationale: those rows were added this cycle with standard deviations equal to their means,
  so they cannot detect a regression either way. Historical rows stay untouched; the plan 83
  rule that a baseline refresh never excuses a regression still holds because the refreshed
  rows are re-measured against the same code path with the noise source removed.
  Date: 2026-09-16
- Decision: Warm every fresh scenario once outside timing instead of retaining a prepared
  input pool.
  Rationale: five-process evidence showed stable 0.5–0.9 second measurements after complete
  warmups, while the proposed pool raised live-heap pressure and produced multi-second
  estimates. A complete warmup also covers the PostgreSQL and intake path that caused the
  cold-position effect.
  Date: 2026-09-18


## Outcomes & Retrospective

All five follow-ups are implemented. Dispatch-only reactions skip the empty timer transaction
and the opt-in proof reports `no-advance timer-phase entries=0`. Semantic replay-twin coverage
accepts the hand-simplified equivalent while the new disjoint case still reports
`AggGuardTightened`. Twelve read-model compatibility deprecations now share the Language 4
generator retirement boundary, recorded in ADR-26. Both non-conformance Cabal components build
with bounded internal dependencies.

Five serial fresh benchmark matrices produced stable evidence in `fresh-warmup-1.csv` through
`fresh-warmup-5.csv`. The nine previously tracked fresh baseline rows use their median means
and median spreads; every non-fresh row is byte-identical. The exact inbox regression command
passed all 49 rows. The full umbrella recipe later failed in unrelated command cold-start rows,
so this plan neither relaxed nor refreshed those baselines.


## Context and Orientation

Keiro is a Haskell event-sourcing framework built as a Cabal multi-package workspace. The
packages that matter here are `keiro/` (the runtime library, including process-manager
reactions and read models), `keiro-dsl/` (the `.keiro` specification toolchain whose
`check`, `scaffold`, and `diff` commands generate and evolve Haskell services), and the
benchmark stanza `keiro-bench` inside `keiro/`. The task runner is `just`; `just verify`
is the repository gate and `just bench-regression` is the manual benchmark guard. Tests need
a local PostgreSQL, which `just verify` provisions through process-compose; the individual
`cabal test` commands below assume that PostgreSQL is already running (start it once with
`just postgres-start` from the repository root if `pg_isready` reports it down).

A *process-manager reaction* is the runtime API in
`keiro/src/Keiro/ProcessManager/Reaction.hs`. A pure function `react` maps a decoded input to
a `ReactionPlan`, which is either `NoAdvance [FollowUp]` (no saga state change) or
`AdvanceReaction { command, followUps, onAccepted }`. A `FollowUp` is one of
`FollowDispatch` (send a command to a target stream), `FollowSchedule` (insert or re-arm a
timer row), or `FollowCancel` (cancel a timer row). The engine in
`runReactiveProcessManagerEngine` runs the timer follow-ups in one database transaction and
then dispatches each command in its own transaction. `runTimerPhase` (around line 488 at the
reviewed commit fa6b66b2) is `runTransaction (runTimerPhaseTx followUps)`, and
`runTimerPhaseTx` folds over the follow-ups, ignoring `FollowDispatch`. It is called on the
`NoAdvance` branch (around line 283) and on the silent-decision branch (around line 312).
When the follow-ups contain no timer operation the fold does nothing, but `runTransaction`
still issues `BEGIN` and `COMMIT`.

The *hydration probe* is a manual Cabal flag `reaction-hydration-probe` declared in
`keiro/keiro.cabal`; when it is on, `cpp-options: -DKEIRO_REACTION_HYDRATION_PROBE` makes
`keiro/src/Keiro/Command.hs` (`hydrate`) and `keiro/src/Keiro/ProcessManager/Reaction.hs`
(`recoverWitness`, around line 524) print one JSON line to stderr per operation, of the form
`{"marker":"reaction-probe","operation":"hydrate","stream":"..."}`. The script
`keiro-dsl/test/process-hydration-test.sh` builds the reactions conformance suite with that
flag in a temporary `--builddir`, runs it with `--test-options='--hydration-probe'`, and
counts markers between `reaction-case-start <label>` and `reaction-case-end <label>` lines
that the suite prints (`keiro-dsl/test/conformance-process-reactions/Main.hs`, around line
122). One of its cases is labelled `no-advance` and runs the generated `AuditOnly` process
from `keiro-dsl/test/fixtures/process-reactions.keiro` (lines 32 to 43), whose only reaction
is `on IncidentNoted no-action`, that is, a `NoAdvance []` plan with no follow-ups at all.
The script asserts `no-advance probe entries` equals 0. `just process-reaction-proof` runs
this script and `keiro-dsl/test/process-reaction-mutation-test.sh`, and `just verify`
includes it.

A *transition family* in the DSL is the set of aggregate transitions that share a source
state and command. When a live guard is tightened, events appended under the old guard may no
longer invert on replay, and the sanctioned remedy is a *replay-only twin*: a transition in
`replay-only` mode whose guard is exactly the region the live guard no longer covers. This is
recorded in `docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md`.
`keiro-dsl diff` computes that twin and prints it as the advisory `AggGuardTightened`, unless
the candidate already contains a replay-only sibling that covers the removed region. That
coverage decision is `coversBody` inside `proposalForBody` in
`keiro-dsl/src/Keiro/Dsl/Diff.hs` (around lines 1813 to 1828):

```haskell
coversBody transition =
  guardsCanonicalEqual ((.guard) transition) ((.guard) twin)
    || all (\oldGuard -> guardImplies oldGuard ((.guard) transition)) oldAlternatives
```

`twin` is the computed remedy, whose guard is `oldUnion && !(newUnion)`, and
`oldAlternatives` are the disjuncts of the old live guards. `guardImplies` lives in
`keiro-dsl/src/Keiro/Dsl/TransitionFamily.hs` (around line 206); it is a deliberately small
implication fragment that returns true when the guards are equal, when the left side is
literally false, when the right side is literally true, when either conjunct of a left `EAnd`
implies the right, or when the left implies either disjunct of a right `EOr`; unknown shapes
return false so analysis stays conservative. The false advisory arises because a human can
write the twin as `(A||B) && Red` while the computed twin is
`(A||B) && ((!A && !B) || Red)`: the two are logically identical (the first conjunct
falsifies the extra disjunct) but neither canonically equal nor implied alternative by
alternative. The fixtures are `keiro-dsl/test/fixtures/reservation.keiro` (old guard
`cmd.divertStatus != DivertStatus.TotalDivert || cmd.lifeCriticalOverride`),
`reservation-guard-tightened.keiro` (live guard additionally `&& cmd.patientAcuity !=
PatientAcuity.RedTag`), `reservation-guard-tightened-twin.keiro` (the exact computed twin),
and `reservation-guard-tightened-partial-twin.keiro` (the hand-simplified twin). Section 19
of `keiro-dsl/test/diff-test.sh` (starting around line 371) asserts that the partial twin
still yields `[AggGuardTightened]`, and the `keiro-dsl-test` example "classifies whole unions
and requires complete replay-only coverage" (around line 7763 of `keiro-dsl/test/Main.hs`)
asserts `[AggGuardTightened]` for `withFamily [edge a, replayEdge b]` where `b` is
`complementExpr a`, which is likewise the exact removed region of `aOrB` written without the
redundant conjunct. `docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md`
explains why `diff` codes rather than prose are the contract tooling depends on; the code
`AggGuardTightened` itself does not change here, only when it is emitted.

The *read-model deprecations* are twelve `{-# DEPRECATED ... #-}` pragmas in
`keiro/src/Keiro/ReadModel.hs` (`ConsistencyMode`, `Strong`, `Eventual`, `PositionWait`,
`StrongScope`, `EntireLog`, `CategoryHead`, `defaultStrongWaitOptions`, `subscriptionName`,
`defaultConsistency`, `strongScope`, and `runQueryWith`), each promising removal "in 0.13".
The package is at 0.16.0.0 and about
to become 0.17.0.0. They cannot be removed: the Language 4 read-model generator in
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (around lines 4941 to 5037) still emits imports of
`ConsistencyMode (..)`, `StrongScope (..)`, the record field `defaultConsistency`, and the
expressions `Strong`, `Eventual`, `EntireLog`, and `CategoryHead`; the frozen corpora under
`keiro-dsl/test/conformance-dispatch-full`, `conformance-newsurface`, `conformance-queue`,
and `conformance-queue-runtime` import them; and published-language output is frozen byte for
byte (`docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md`).
Those corpora therefore emit 22 `-Wdeprecations` warnings under `cabal build all`, which is
expected and was recorded in REV-15.

The *unbounded internal dependencies* are in `keiro-dsl/keiro-dsl.cabal`. The stanza
`test-suite keiro-dsl-runtime-vocabulary-test` (around line 285) lists `keiro` and
`shibuya-core` with no version, and `benchmark keiro-dsl-codec-bench` (around line 728) lists
`keiro` with no version. The release procedure in `agents/skills/release/SKILL.md` (step 3)
treats an unbounded internal dependency outside the conformance suites as a defect, because it
lets a consumer solve a new major `keiro` against an old `keiro-dsl`, and it deliberately
leaves the conformance suites unbounded because those stanzas are unbounded for every internal
package. Every other stanza in the workspace pins internal packages with a caret bound at the
shared version (`keiro-core ^>=0.16.0.0` and so on), and `shibuya-core ^>=0.9.0.0` elsewhere.
The release bump rewrites every internal caret bound in lockstep, so the bound added here must
use the shared version current at the time of the edit.

The *delegated inbox benchmark* is `keiro/bench/InboxDelegatedBench.hs`, wired into
`keiro/bench/Main.hs` as the `inbox.downstream` group. `prepareInboxDelegatedBenchmarks`
(around line 111) creates one `bgroup` per scenario from `scenarioInputs` (seven scenario
shapes times three traffic kinds times metrics on or off). `runScenario` (around line 196) is
the timed action: for fresh and repeated traffic it calls `prepareDownstreamRun` (around line
357), which builds 2,000 `DownstreamWork` records through `prepareWork`, each constructing an
integration event, a Kafka delivery reference, a target stream name, a deterministic marker
id, and a prepared event via `StoreTransaction.prepareEventsIO`, and only then runs the
deliveries against the store. Duplicate traffic reuses a run seeded once in `prepareScenario`.
The history benchmark (`historyBenchmark`, around line 398) is the one place that already uses
tasty-bench's `env` to prepare outside the timed action, and `DownstreamRun` already has an
`NFData` instance for that purpose. REV-17 measured the first fresh scenario a process runs
at 5.5 to 7.1 seconds with a standard deviation of 2.8 to 7.4 seconds, whichever scenario it
was, while the same scenario in second position measured 0.76 to 1.07 seconds; the committed
baseline row `All.inbox.downstream.table-downstream-single.fresh.metrics-off` in
`keiro/bench/baseline-inbox.csv` is `1844436999883,1682444380116` (mean and standard
deviation in picoseconds), which shows the same first-run spread was captured on
2026-09-15. The evidence and method for those rows are in
`keiro/bench/results/delegated-inbox-v1/README.md`. `just bench-regression` runs the inbox
group with `--baseline bench/baseline-inbox.csv --fail-if-slower 25`.

No cross-repository ADR applies. The local ADRs relevant here are ADR-2 (replay-only twins),
ADR-4 (diff codes as the tooling contract), and ADR-16 (published language output is frozen),
all cited above by path.


## Plan of Work

The five milestones are independent of one another and can be implemented in any order.
Each one ends with a commit that carries the `MasterPlan:`, `ExecPlan:`, and `Intention:`
trailers shown in Concrete Steps.

### Milestone 1: skip the empty timer transaction

Scope: the `NoAdvance` and silent-decision branches of `runReactiveProcessManagerEngine` in
`keiro/src/Keiro/ProcessManager/Reaction.hs` stop opening a transaction when nothing in the
follow-ups is a `FollowSchedule` or `FollowCancel`. At the end, a reaction whose plan is
`NoAdvance []` or `NoAdvance [FollowDispatch ...]` performs no store round trip before its
dispatches, the returned `ReactionTimerEffects` is still `zeroTimerEffects`, and the
accepted-append branch (which runs timer SQL inside the append transaction through
`runTimerPhaseTx`) is unchanged.

Change `runTimerPhase` to inspect its argument first: if `any isTimerFollowUp followUps` is
false, return `pure zeroTimerEffects` without calling `runTransaction`; otherwise behave as
today. Define `isTimerFollowUp` as a small local predicate that is true for `FollowSchedule`
and `FollowCancel` and false for `FollowDispatch`. Do not change `runTimerPhaseTx`, which the
accepted branch passes as the SQL callback of `runDomainCommandWithSqlEvents`; that callback
runs inside the append transaction and adding a timer statement there costs nothing extra.

Make the change observable through the probe. Under the existing `#ifdef
KEIRO_REACTION_HYDRATION_PROBE` guard, have `runTimerPhase` emit one stderr marker
`{"marker":"reaction-probe","operation":"timer-phase","statements":N}` immediately before it
calls `runTransaction`, where `N` is the number of timer follow-ups, reusing the same
`Aeson.encode`/`ByteString.Char8.hPutStrLn stderr` shape as `recoverWitness`. Because the
marker sits inside the branch that opens the transaction, a plan with no timer follow-ups
emits nothing. Then extend `keiro-dsl/test/process-hydration-test.sh`: the existing line
`assert_count "no-advance probe entries" 0 "$(case_count "$REACTION_LOG" no-advance '' '')"`
already counts every marker for the no-action case, so before the fix it now reports 1 and
after the fix 0; add a second explicit line
`assert_count "no-advance timer-phase entries" 0 "$(case_count "$REACTION_LOG" no-advance timer-phase '')"`
so the intent is named, and add
`assert_at_least "fan-out=8 shape=same first timer-phase entries" 0 ...` only if the scaling
cases schedule timers (check `keiro-dsl/test/fixtures/process-reactions.keiro` and the
`ScalingReaction` process before asserting a positive count; if none schedules a timer, assert
0 for one fan-out case instead, so a regression that emits the marker unconditionally is
caught). Keep the default build silent: the script's final step already fails if any marker
appears without the flag.

Add one unit-level assertion in `keiro/test/Main.hs` inside the existing
`describe "Keiro.ProcessManager.Reaction"` group: a `NoAdvance` plan containing only a
`FollowDispatch` returns `timerEffects` equal to `Reaction.ReactionTimerEffects 0 0 0` and
appends the dispatched event; model it on "runs no-advance and silent unconditional effects
without accepted-only effects" (around line 4508), which already builds `NoAdvance` plans
against `counterReactionManager`. This proves the fast path still dispatches.

Record the change in `keiro/CHANGELOG.md` under `## [Unreleased]`, `### Other Changes`, as
one bullet: reactions with no timer follow-ups no longer open a timer transaction. Append the
bullet; the section structure is owned by
`docs/plans/283-reconcile-the-0-17-0-0-changelogs-and-user-documentation-with-the-shipped-surfaces.md`.

Acceptance: `just process-reaction-proof` prints `PASS: reaction hydration and witness entry
counts are explicit; the default build is silent` with the new assertion lines echoed as
`no-advance timer-phase entries=0`, and the new `keiro-test` example passes.

### Milestone 2: accept semantically equivalent replay twins

Scope: `coversBody` accepts a pre-existing replay-only sibling when every old alternative
implies the disjunction of the new live union and the sibling's guard, in addition to the two
existing conditions. At the end, `keiro-dsl diff` prints no `AggGuardTightened` for the
partial-twin fixture, still prints it for a sibling whose guard covers only part of the
removed region in a way the implication fragment cannot prove, and still prints it for every
mismatched-dimension sibling (different writes, target, source, or ownership).

Edit `coveredByCandidate` in `keiro-dsl/src/Keiro/Dsl/Diff.hs` so that `coversBody` becomes:

```haskell
coversBody transition =
  guardsCanonicalEqual ((.guard) transition) ((.guard) twin)
    || all (\oldGuard -> guardImplies oldGuard ((.guard) transition)) oldAlternatives
    || all (\oldGuard -> guardImplies oldGuard (unionWith ((.guard) transition))) oldAlternatives
  where
    unionWith replayGuard =
      case (newUnion, replayGuard) of
        (Nothing, _) -> Nothing
        (_, Nothing) -> Nothing
        (Just live, Just replay) -> Just (EOr live replay)
```

`newUnion` is already computed in `proposalForBody` as `bodyGuardUnion ((.newBodyMembers)
bodyDelta)`; thread it into `coveredByCandidate` as an argument (it currently receives only
`bodyDelta` and `twin`). A `Nothing` guard means "always", so a `Nothing` on either side of
the disjunction makes the union `Nothing`, and `guardImplies _ Nothing` is already true. The
implication fragment splits a right-hand `EOr`, so for the partial twin each old alternative
(`A` and `B`) is checked against `((A||B) && !Red) || ((A||B) && Red)`, and `implies` finds
`A` implies neither disjunct directly. Extend the fragment in
`keiro-dsl/src/Keiro/Dsl/TransitionFamily.hs` with one more sound rule so this proves: when
the right side is `EOr (EAnd l1 r1) (EAnd l2 r2)` with `l1` canonically equal to `l2`, the
old guard implies it if it implies `l1` and implies `EOr r1 r2`; and when the right side is
`EOr r1 r2` where `r1` and `r2` are complementary literal boolean tests of the same
expression (`x == v` and `x != v`, or `x` and `!x`), treat the disjunction as true. Keep the
rule set small and add a unit test for each new rule in `keiro-dsl/test/Main.hs` next to the
existing `guardImplies` coverage (search for "guardImplies" or "unionPreserved" in that file
to find the group). If the fragment still cannot prove the fixture after those two rules,
record why in Surprises & Discoveries and stop at the rule that is provably sound rather than
adding a general SAT step; the plan's acceptance is then the unit tests plus whichever
fixture cases the fragment does prove, and the false-advisory fixture remains documented as a
known conservative case.

Flip the two assertions: in `keiro-dsl/test/diff-test.sh` section 19, the partial-twin block
must now expect no `[AggGuardTightened]` and no `[AggGuardRemedyUnavailable]` and echo
`ok: hand-simplified replay twin covers the removed region`; in `keiro-dsl/test/Main.hs` the
line `map (.code) (guardFindings oldUnion (withFamily [edge a, replayEdge b])) shouldBe
[AggGuardTightened]` becomes `shouldBe []`. Add one new negative case to the same `it` block:
a replay-only sibling whose guard is `EAnd a b` (a region disjoint from the removed one)
still produces `[AggGuardTightened]`. Leave the `mismatchedCoverage` loop untouched; it must
stay green.

Update `keiro-dsl/CHANGELOG.md` under `## [Unreleased]`: replace the sentence "Existing
replay-only coverage must match the same replay body and cover the exact removed region or
every old alternative" with wording that says coverage is accepted when the sibling's guard
is canonically the removed region, or when every old alternative implies the sibling alone or
the union of the new live guards and the sibling, and that shapes the implication fragment
cannot prove still produce the advisory. Append rather than restructure; plan 283 owns the
section layout.

Acceptance: `bash keiro-dsl/test/diff-test.sh` prints `ok:` for both blocks of section 19
and exits 0; `cabal test keiro-dsl-test --test-options='--match "/transition family/"'`
passes with the flipped and added assertions.

### Milestone 3: restate the read-model deprecation window

Scope: every one of the ten pragmas at `keiro/src/Keiro/ReadModel.hs` lines 334 to 352 gets
a message that is true today. At the end, a consumer who compiles against the deprecated
names sees a warning naming the real boundary, and nothing else changes.

Rewrite each message so that it keeps its "Use X" replacement advice and replaces the "removed
in 0.13" clause with: "It remains exported while keiro-dsl's Language 4 read-model generator
emits it and is removed with that generator in a later major release." Keep the pragmas on the
same declarations; do not remove any export. Add a short comment above the block explaining
that `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` still generates these names for published
languages and that the frozen corpora under `keiro-dsl/test/conformance-*` are expected to
warn. Record the restatement in `keiro/CHANGELOG.md` under `Unreleased`, `### Other Changes`.

Acceptance: `cabal build keiro` succeeds; `cabal build all 2>&1 | grep -c Wdeprecations`
still reports the same count as before the change (the corpora are untouched); and
`grep -c 'removed in 0.13' keiro/src/Keiro/ReadModel.hs` prints 0.

### Milestone 4: bound the non-conformance internal dependencies

Scope: the two stanzas gain caret bounds. At the end, `cabal build all` solves exactly as
before and the stanzas match the bound style used everywhere else.

In `keiro-dsl/keiro-dsl.cabal`, in `test-suite keiro-dsl-runtime-vocabulary-test`, change
`keiro,` to `keiro ^>=<shared version>,` and `shibuya-core,` to `shibuya-core ^>=0.9.0.0,`
where `<shared version>` is the value of `version:` at the top of the same file at the time
of the edit (0.16.0.0 before the release bump, 0.17.0.0 after it). In `benchmark
keiro-dsl-codec-bench`, change `keiro,` to `keiro ^>=<shared version>,`. Leave `keiro-dsl,`
unbounded where it appears; a package depending on its own library needs no bound. Do not
touch any `test-suite keiro-dsl-conformance-*` stanza. Run `nix fmt` afterwards so
cabal-gild reformats the stanza if it needs to. Record the change in `keiro-dsl/CHANGELOG.md`
under `Unreleased`, `### Other Changes`, and note in the release skill's step 3 text that the
two stanzas are now bounded so the next release's scan does not report them again.

Acceptance: `cabal build keiro-dsl:test:keiro-dsl-runtime-vocabulary-test
keiro-dsl:bench:keiro-dsl-codec-bench` succeeds and `git diff -- keiro-dsl/keiro-dsl.cabal`
shows only the two or three bound lines and any cabal-gild realignment.

### Milestone 5: remove the benchmark first-run cost and re-record the fresh rows

Scope: find out why the first fresh downstream scenario in a `keiro-bench` process is five
times slower than the same scenario in second position, move that cost out of the timed
action, and re-record the fresh downstream baseline rows. At the end, running
`cabal bench keiro-bench --benchmark-options="-p /table-downstream-single.fresh/ --time-mode
wall --hide-progress"` three times in a row reports a standard deviation under 15% of the
mean on every run, and the inbox benchmark regression passes.

First measure, then change. Run the single fresh scenario alone with `--csv` and `--stdev 5`
and compare its first sample to later ones; tasty-bench does not print per-sample times, so
temporarily wrap `runScenario` with a `getMonotonicTime` pair that prints the elapsed time
of each invocation to stderr, run the scenario alone, and read the first three durations.
Then test the two likely causes. Cause one is `prepareDownstreamRun` running inside the
timed action: it constructs 2,000 events and calls `StoreTransaction.prepareEventsIO` 2,000
times per sample, and the first sample also pays for allocating and warming that code path.
Cause two is database-side: the first sample creates 2,000 new streams in a database that
`prepareScenario` has just seeded, so PostgreSQL may extend `streams` and `stream_events`,
grow their indexes, or run an autovacuum; check `PGLOG` (the process-compose log for the
local server) for `automatic vacuum` or `checkpoint` lines during the run, and compare with
`log_min_duration_statement` set to a low value for the benchmark database. Record what you
find in Surprises & Discoveries with the numbers.

The implementation experiment rejected the prepared-pool approach: keeping tens of thousands
of prepared events live increased garbage-collection pressure and made the measurements slower.
The evidence instead supports one complete untimed warmup for each fresh scenario in
`prepareInboxDelegatedBenchmarks`. The warmup covers input preparation, PostgreSQL statements,
the intake mode, chunk size, and metrics setting; its streams remain in the ephemeral database
exactly as seeded duplicate runs do. Measured invocations retain their normal preparation cost,
`deliveryCount` remains 2,000, and scenario names remain unchanged.

Prove the fix on a quiet machine (no other builds, tests, or agents running; the review of
2026-09-16 was taken under heavy load and its numbers are only evidence of the spread, not of
the fixed cost). Run the single fresh scenario alone three times and each fresh scenario in
first position once; every run must show a standard deviation under 15% of its mean and
means within 25% of one another. Then re-record only the rows whose names contain `.fresh.`
under `All.inbox.downstream.`: run the full inbox group five times with `--csv` to separate
files under `keiro/bench/results/delegated-inbox-v1/` named `fresh-rerecord-<n>.csv`, take
the median mean per row, and replace those rows in `keiro/bench/baseline-inbox.csv`. Do not
change any other row; `git diff -- keiro/bench/baseline-inbox.csv` must show exactly the
fresh downstream rows. Add a dated addendum section to
`keiro/bench/results/delegated-inbox-v1/README.md` that states the cause found, the change
made, the machine and toolchain, and the five-run medians, and that the historical rows and
the 2026-09-15 conclusions are unchanged. Then run the exact inbox command from
`just bench-regression` and confirm every inbox row reports `OK`.

Acceptance: the isolated and five-process evidence is summarized in Outcomes & Retrospective;
the scoped inbox transcript reports all 49 rows passing, and the baseline diff touches only
fresh downstream rows.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless a
`cd` is shown. Make sure PostgreSQL is up before any test:

```bash
just postgres-start
pg_isready -h "$PWD/db" || echo "postgres not ready"
```

Milestone 1:

```bash
cabal build keiro
cabal test keiro-test --test-options='--match "/Keiro.ProcessManager.Reaction/"'
just process-reaction-proof
```

Expected tail of the proof script:

```text
no-advance probe entries=0
no-advance timer-phase entries=0
PASS: reaction hydration and witness entry counts are explicit; the default build is silent
```

Milestone 2:

```bash
cabal build keiro-dsl
cabal test keiro-dsl-test --test-options='--match "/transition family/"'
bash keiro-dsl/test/diff-test.sh
```

Expected lines from the script:

```text
== 19) whole-body coverage distinguishes exact and partial replay twins ==
ok: exact computed twin covers the complete removed region
ok: hand-simplified replay twin covers the removed region
```

Milestone 3:

```bash
grep -c 'removed in 0.13' keiro/src/Keiro/ReadModel.hs
cabal build keiro
```

Expected: `0`, then a successful build.

Milestone 4:

```bash
nix fmt
cabal build keiro-dsl:test:keiro-dsl-runtime-vocabulary-test keiro-dsl:bench:keiro-dsl-codec-bench
git diff -- keiro-dsl/keiro-dsl.cabal
```

Milestone 5:

```bash
cabal bench keiro-bench --benchmark-options="-p /table-downstream-single.fresh/ --time-mode wall --hide-progress"
cabal bench keiro-bench --benchmark-options="-p /delegated-single.fresh/ --time-mode wall --hide-progress"
for n in 1 2 3 4 5; do
  cabal bench keiro-bench --benchmark-options="-p inbox -j1 --time-mode wall --hide-progress --csv keiro/bench/results/delegated-inbox-v1/fresh-rerecord-$n.csv"
done
cabal bench keiro-bench --benchmark-options="-p inbox --time-mode wall --baseline bench/baseline-inbox.csv --fail-if-slower 25"
```

The `-p /table-downstream-single.fresh/` filter is a tasty pattern that matches both the
`metrics-off` and `metrics-on` variants; the first printed variant is the one that ran first
in the process. Cabal runs the benchmark from `keiro/`, so relative CSV paths in
`--benchmark-options` are resolved against `keiro/`; pass repository-relative paths as
shown only if `cabal bench` is invoked from the root and confirm where the file landed with
`ls keiro/bench/results/delegated-inbox-v1/`.

Full gate after all milestones:

```bash
just verify > "$TMPDIR/verify.log" 2>&1; echo "EXIT=$?" | tee -a "$TMPDIR/verify.log"
grep -E '^EXIT=' "$TMPDIR/verify.log"
```

Commit each milestone separately with trailers:

```text
perf(reaction): skip the timer transaction when a plan schedules no timers

MasterPlan: docs/masterplans/43-address-the-rev-17-keiro-0-17-0-0-release-readiness-findings.md
ExecPlan: docs/plans/286-close-the-carried-over-runtime-dsl-diff-packaging-and-benchmark-follow-ups.md
Intention: intention_01m2nqd9hre9gbhw37aagtf066
```


## Validation and Acceptance

Milestone 1 is accepted when `just process-reaction-proof` passes with the two `no-advance`
counts at 0 and at least one positive-path assertion still counting hydrations, and when the
new `keiro-test` example shows a dispatch-only `NoAdvance` returning zero timer effects with
the target event appended. Before the fix the proof script must fail with
`FAIL: no-advance probe entries expected=0 actual=1`; run it once before editing
`runTimerPhase` (with the marker already added) to see that failure, then apply the fix.

Milestone 2 is accepted when the partial-twin block in `diff-test.sh` prints `ok:` without an
advisory, the flipped `keiro-dsl-test` assertion passes, the new disjoint-sibling assertion
still yields `[AggGuardTightened]`, and the `mismatchedCoverage` loop is untouched and green.
Run `cabal test keiro-dsl:tests` once at the end to confirm no other suite depended on the old
advisory.

Milestone 3 is accepted when no pragma mentions 0.13 and the build's deprecation warning
count is unchanged.

Milestone 4 is accepted when both stanzas build and the diff is bounds only.

Milestone 5 is accepted when the first-position and five-process runs show under 15% relative
standard deviation, the scoped benchmark regression reports `OK` on every inbox row, and the
baseline diff is limited to fresh downstream rows. The umbrella recipe's unrelated command
baseline failures are recorded above and do not authorize changing command baselines here.

The full `just verify` gate must exit 0 after all milestones; capture the exit status inside
the log as shown, because `just verify > log; echo $?` reports the `echo`, not the gate.


## Idempotence and Recovery

Every milestone is a plain source or data edit and can be re-applied or reverted with `git
checkout -- <path>`. The proof script builds in a temporary directory and restores nothing
in the tree. The mutation script that `just process-reaction-proof` also runs rewrites two
committed conformance directories and re-scaffolds them on exit; if it is interrupted, run
`just corpus-regen` and confirm `git status` is clean before continuing. Benchmark reruns
truncate and reseed only benchmark-owned tables and streams inside the ephemeral benchmark
database; they never touch the persistent `jitsurei` database. If a baseline re-record is
run on a loaded machine by mistake, discard the CSVs and repeat; never commit a baseline row
whose standard deviation exceeds 15% of its mean.


## Interfaces and Dependencies

`keiro/src/Keiro/ProcessManager/Reaction.hs`: `runTimerPhase :: (IOE :> es, Store :> es) =>
[FollowUp targetCi] -> Eff es ReactionTimerEffects` returns `zeroTimerEffects`
without a transaction when no follow-up is `FollowSchedule` or `FollowCancel`. The probe
marker uses `Data.Aeson` and `Data.ByteString.Char8` already imported under the CPP guard.

`keiro-dsl/src/Keiro/Dsl/Diff.hs`: `coversBody` gains the union rule; `coveredByCandidate`
receives `newUnion :: Maybe Expr`. `keiro-dsl/src/Keiro/Dsl/TransitionFamily.hs`:
`guardImplies :: Maybe Expr -> Maybe Expr -> Bool` keeps its signature and gains the two
rules described in Milestone 2; every added rule must be sound (never return true for an
implication that does not hold) and covered by a unit test.

`keiro/src/Keiro/ReadModel.hs`: export list unchanged; only pragma text changes.

`keiro-dsl/keiro-dsl.cabal`: `keiro ^>=<shared version>` and `shibuya-core ^>=0.9.0.0` in
the two named stanzas.

`keiro/bench/InboxDelegatedBench.hs`: `prepareInboxDelegatedBenchmarks :: Store.KirokuStore
-> KeiroMetrics -> IO [Benchmark]` keeps its signature; fresh and repeated scenarios prepare
outside the timed action through `Test.Tasty.Bench.env` with an `NFData` resource, or the
group gains an untimed warm-up, per the evidence. `keiro/bench/baseline-inbox.csv` rows keep
their names; only the numbers of `All.inbox.downstream.*.fresh.*` rows change.

Dependencies on other plans: none are hard. The changelog bullets in Milestones 1 to 4 are
appended under the section structure that
`docs/plans/283-reconcile-the-0-17-0-0-changelogs-and-user-documentation-with-the-shipped-surfaces.md`
owns; if that plan has not run yet, append under the existing `### Other Changes` headings
and let it reconcile. If the 0.17.0.0 release bump lands first, Milestone 4 uses 0.17.0.0
as the shared version.
