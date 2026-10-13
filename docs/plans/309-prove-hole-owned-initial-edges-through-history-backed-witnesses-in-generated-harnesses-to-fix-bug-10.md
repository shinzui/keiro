---
id: 309
slug: prove-hole-owned-initial-edges-through-history-backed-witnesses-in-generated-harnesses-to-fix-bug-10
title: "Prove hole-owned initial edges through history-backed witnesses in generated harnesses to fix BUG-10"
kind: exec-plan
created_at: 2026-10-13T13:54:49Z
intention: "intention_01m4trpbfhe64banxqfdh3va7w"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-13T13:54:49Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-13T23:24:11Z
      mode: "implement"
      note: "Implement BUG-10 history-backed initial-hole harness evidence and conformance proofs"
---

# Prove hole-owned initial edges through history-backed witnesses in generated harnesses to fix BUG-10

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


`keiro-dsl` turns a `.keiro` specification into Haskell. For every aggregate it emits a
generated test module, `Generated/<Context>/<Aggregate>/Harness.hs`, exposing
`harnessAssertions :: [(String, Bool)]`. A driver prints one `PASS`/`FAIL` line per row and
exits non-zero on any `False`. Two of those rows exist for every live transition that leaves
the aggregate's initial vertex: `accepts <Command> from <Vertex>` and a group of
`forward/replay equality: <Command> from <Vertex> -- …` rows. Today both rows build a
synthetic sample command and step the transducer from the initial vertex with the
*initial register values*. That is sound when the generator owns the transition's guard,
because it chose the sample. It is wrong when the transition is an `implementation hole`,
because the consumer wrote the guard in a create-once `Holes.hs` module and the guard may
legitimately depend on earlier history. Being at the initial control vertex says nothing
about the registers: a self-loop on that vertex may already have replayed events.

Bug report [BUG-10](../bug-reports/10-initial-hole-harness-requires-acceptance-from-empty-registers.md)
records exactly that shape in the Rei consumer (`mori://shinzui/rei`). Its `PropertyAssignment`
aggregate has one vertex, a map register that starts empty, and a live `ClearProperty` hole
whose guard requires the key to be present. The consumer's typed `LiveWitness` seeds a
`PropertySet` event and then clears, and the generated behavior contract accepts it. The
generic harness probes ignore that witness, step from the empty map, and fail. The
consumer's whole-service gate is therefore red for a correct implementation. This plan's
author reproduced the generated shape in this repository on 2026-10-13 by scaffolding a
minimal spec with a hole-owned initial self-loop (see Context and Orientation).

After this plan, the generator treats the two kinds of initial edge differently. A
generated-owned edge keeps its synthetic probe unchanged. A hole-owned edge's `accepts …`
and `forward/replay equality …` rows are instead derived from the consumer's history-backed
`LiveWitness` for that exact edge, executed through the generated behavior contract, which
already attributes the exact Keiki edge, decodes the emitted events through the persisted
codec, replays them, and compares the final vertex and every register. A missing,
pending, duplicate, stale, wrong-edge, under-seeded, or lying witness turns those rows
`False` with the failure code visible in the behavior conformance report. Concretely, after
implementation, from the repository root:

```bash
nix develop -c cabal test keiro-dsl-conformance-history-dependent-holes --test-show-details=direct
```

passes a new compiled fixture whose live clear requires a prior set, and the same aggregate,
added as a member of the committed service-package workspace, passes the generated
whole-service conformance package:

```bash
nix develop -c cabal test keiro-workspace-proof-conformance --test-show-details=direct
```

Both commands fail on today's tree for the same two rows Rei reports. BUG-10 moves to
`confirmed` when that failing fixture exists, and to `fixed` with `fixedVersion: unreleased`
when the full gate is green. Releasing the repair and adopting it in Rei are separate,
later steps that this plan names but does not perform.


## Progress


- [x] (2026-10-13) Milestone 0: validate BUG-10 from source, reproduce the generated probe shape with the public scaffolder, create this plan with its intention, link it from the bug report body, log, and index, and run `just bug-reports-validate`.
- [x] (2026-10-13) Milestone 1: add `keiro-dsl/test/fixtures/history-dependent-holes.keiro`, its consumer `Domain` and `Bindings` modules, scaffold it with the public CLI into `keiro-dsl/test/conformance-history-dependent-holes/`, and force-add the scaffold ledger and Cabal fragment.
- [x] (2026-10-13) Milestone 1: fill `HistoryDependentHoles/Assignment/Holes.hs` (set inserts, live clear requires membership, replay-only clear deletes unconditionally) and `BehaviorHoles.hs` (history-backed live clear witness, replay-only empty clear witness).
- [x] (2026-10-13) Milestone 1: add the suite driver `Main.hs` and the `keiro-dsl-conformance-history-dependent-holes` test-suite stanza; run it before the repair and record the two `FAIL` rows beside the passing behavior report in Surprises & Discoveries.
- [x] (2026-10-13) Milestone 1: set BUG-10 `status: confirmed`, advance `generated`, and log the confirmation.
- [x] (2026-10-13) Milestone 2: export `behaviorRequirementsFor` from `Keiro.Dsl.Scaffold`; add `behaviorObligationReport` to every generated `BehaviorContract` by sharing the coverage-report body.
- [x] (2026-10-13) Milestone 2: split initial live entries in `Keiro.Dsl.Harness` by ownership; emit witness-backed `accept<Command>`/`forwardReplay<Command>` helpers for hole-owned edges; gate the `step`/`applyEventsEither`/`(!)` imports and the `OverloadedLabels` pragma on the synthetic bucket; import `BehaviorHoles` and `BehaviorContract` only when a hole-owned initial edge exists.
- [x] (2026-10-13) Milestone 2: validate the added focused generator tests to `keiro-dsl/test/Main.hs` (witness rows for hole-owned edges, unchanged synthetic rows for generated edges, replay-only still excluded, import gating when every initial edge is hole-owned, repeat scaffold byte stability).
- [x] (2026-10-13) Milestone 2: regenerate the corpus, review the contract-only changes outside the new fixture/workspace, verify the ordinary Journey Harness is byte-identical, and pass `scripts/check-conformance-corpus.sh` from the committed baseline.
- [x] (2026-10-13) Milestone 2: register the Language 6 suite and fixture in both explicit inventories; targeted reruns pass all three inventory examples. All five new generator tests and CLI workspace idempotency pass.
- [ ] Milestone 2: confirm all 56 DSL suites pass after inventory registration through `just verify` (its `cabal test keiro-dsl:tests` runs the same complete target).
- [x] (2026-10-13) Milestone 3: add `domain/assignment.keiro` to the service-package workspace with its consumer modules and fills, extend the runtime library's module list and the CLI idempotency test's source list, regenerate, and pass `keiro-workspace-proof-conformance`.
- [x] (2026-10-13) Milestone 4: add `keiro-dsl/test/history-dependent-holes-mutation-test.sh` proving named failures for every mutation BUG-10 lists, and wire it into `just verify` through a new `initial-hole-proof` recipe.
- [x] (2026-10-13) Milestone 5: update `docs/user/replay-safety.md`, `docs/user/keiro-dsl-workspaces-and-generated-code.md`, and `docs/guides/choosing-keiro-dsl.md`; add Unreleased changelog entries; amend ADR-17; validate every bundle.
- [ ] Milestone 5: run `nix develop -c just verify` and read the exit marker inside the log; set BUG-10 to `fixed` with `fixedVersion: unreleased` and a `resolution`; update the bug-report index table; write Outcomes & Retrospective and the ADR distillation pass.


## Surprises & Discoveries


- The generated Hole stub has write indices `writes writes`, which only fits a
  guard-only fill. Keiki's slot assignment extends the write list. The three
  fixture signatures therefore use `'[] '["values"]` and import `(=:)` so the
  map writes type-check. This is a consumer fill, with the generated envelope
  and first-fold tokens preserved.


- The pre-repair fixture exits 1 with exactly these two harness failures while
  the behavior report passes:

  ```text
  FAIL  accepts ClearProperty from AssignmentActive
  FAIL  forward/replay equality: ClearProperty from AssignmentActive -- forward step accepted
  failed: 0
  PASS  behavior conformance passes
  ```

  The initial compile hit unused imports for a register-only opaque mapping.
  The reproduction command adds `--ghc-options=-Wno-unused-imports` solely to
  reach these assertions before the narrow import fix. The repaired fixture
  must compile under the repository's ordinary strict warning policy.

- The pre-repair generated workspace package also exits 1 with exactly:

  ```text
  FAIL  aggregate/Assignment/accepts ClearProperty from AssignmentActive
  FAIL  aggregate/Assignment/forward/replay equality: ClearProperty from AssignmentActive -- forward step accepted
  ```

  Adding an opaque mapping emits a workspace `StructuralConformance` module;
  the runtime Cabal inventory must include it as well as the Assignment modules.
  Omitting it produced a missing-home-module warning and an undefined symbol at
  link time. Including the regenerated fragment's full inventory resolves that.

- After regeneration, both compiled fixture packages pass under the ordinary
  repository configuration. `accepts ClearProperty` and both witness rows pass
  in the aggregate and whole-service reports, while empty live clear still
  refuses and historical empty clear still attributes to replay-only edge 3.
  The corpus diff outside the service addition contains only BehaviorContracts
  and the single-spec Assignment Harness; the ordinary Journey Harness is
  byte-identical to pre-plan revision `2508e81a4dc1dedd91ec76317cce8c5a7d9c5f08`.

- The focused ownership/import/collision run passes all three examples. The
  fixture also passes with `--ghc-options=-Werror`. All eight mutation cases
  fail through the expected clear rows, with `witness-kind`,
  `unexpected-rejection`, `event-value-mismatch`, and `command-mismatch` for
  the executed false witnesses. The final restored baseline passes and
  `git diff --check` is clean.

- The clean-baseline corpus check passes all 54 plan entries, record/disk
  consistency, Cabal inventory consistency, and regeneration freshness. The
  new workspace member and both create-once fills survive regeneration.

- The first broad DSL run passed all 55 conformance/runtime suites and 794 of
  796 main-suite examples. Two inventory tests require new fixture registration:
  `test/conformance-baseline.json` must list the compiled Language 6 component,
  and `test/Main.hs` must include `history-dependent-holes.keiro` in its
  explicit list of fixtures outside Language 4. Both inventories now include
  the new fixture; the workspace mutation and all five new generator examples
  passed in that run.

## Decision Log


- Decision: For a hole-owned live initial edge, the generated harness derives its
  acceptance and forward/replay rows from the consumer's `LiveWitness`, executed through the
  generated behavior contract's existing runner, rather than re-implementing history
  settlement and stepping inside the harness.
  Rationale: the contract's `runAcceptance` already performs every check BUG-10 demands
  (live mode, exact `EdgeRef` attribution, target vertex, exact emitted values, persisted
  codec decode, replay, final vertex and every register, single attribution). Duplicating
  that logic in the harness would create a second semantics that could drift, and a
  harness-native version that ignored `witnessExpected` would let a lying witness pass the
  whole-service gate, which BUG-10 acceptance item 4 forbids.
  Date: 2026-10-13

- Decision: Generated-owned initial edges keep today's synthetic probes byte for byte.
  Rationale: the generator chose those samples from guards it can see, the probes need no
  consumer input, and the report requires that ordinary generated-edge probes remain
  meaningful. Legacy version-1 aggregates (`LegacyHoleImplementation`) also keep today's
  text because they have no behavior contract and are scheduled for retirement under
  ADR-49.
  Date: 2026-10-13

- Decision: Add `behaviorObligationReport` to every generated `BehaviorContract`
  unconditionally, sharing the body of `behaviorCoverageReport`, instead of emitting it
  only for aggregates that need it.
  Rationale: a uniform contract API is easier to document and test than one whose exports
  depend on the spec; the corpus regeneration churn this causes is routine (every release
  already rewrites every generated banner) and is verified by the corpus policy check.
  Date: 2026-10-13

- Decision: The generated harness may import the create-once `BehaviorHoles` module.
  Rationale: the generated `Transducer` already imports the create-once `Holes` module for
  hole bodies, so generated-to-hand-owned imports within the same package are an
  established boundary, and the generated Cabal fragment already lists `BehaviorHoles` in
  the same stanza. The harness remains free of effects and of any dependency outside the
  generated layer, Keiki, and Keiro codecs.
  Date: 2026-10-13

- Decision: A `Pending` witness for a hole-owned initial edge now fails the harness rows,
  and the forward/replay rows for such an edge are labelled `-- hole witness filled` and
  `-- hole witness verified` instead of `-- final vertex` and `-- register <name>`.
  Rationale: the guide already states that pending witnesses fail completeness; a hole
  whose acceptance cannot be established without consumer evidence must not be reported
  accepted on the strength of a stub. The row labels change only for hole-owned initial
  edges and are listed in the changelog as a behavior change.
  Date: 2026-10-13

- Decision: Build two fixtures: a Language 6 single-spec fixture that mirrors Rei (opaque
  map register, set and guarded clear holes, replay-only empty clear, one generated-owned
  self-loop), and a Language 4 member of the existing `conformance-service-package`
  workspace with the same aggregate.
  Rationale: BUG-10 acceptance requires both aggregate-level and generated whole-service
  conformance. Workspace members must share one effective language version
  (`Keiro.Dsl.Workspace` refuses mixed versions), the committed proof workspace is
  Language 4, and `implementation hole` plus `mapped opaque … initial = …` are available in
  Language 4, so the member needs no new workspace. The single-spec fixture uses Language 6
  per ADR-49 and to match the reporter's environment.
  Date: 2026-10-13

- Decision: Keep BUG-10 at `reported` until Milestone 1's compiled fixture fails in this
  repository; set `confirmed` then; set `fixed`/`unreleased` only after `just verify`.
  Rationale: the bug-report index states that `confirmed` requires reproduction by the
  owning repository. Today's scaffold-level reproduction shows the defective generated
  text but did not execute a failing assertion.
  Date: 2026-10-13


- Decision: Capture the workspace reproduction before repairing the generator,
  avoiding a stash/regenerate round trip. Also omit register-only opaque fixture
  imports from harness planning: Domain owns those initials and the harness
  does not sample their fixture values.
  Rationale: the new fixture exposed unused imports promoted to errors by the
  conformance warning policy; narrowing imports preserves every executed probe.
  Date: 2026-10-13

- Decision: Test legacy probes with a small inline Language 1 aggregate.
  Rationale: `conformance-coldstart` now uses Language 4, so it cannot prove
  `LegacyHoleImplementation` preservation as the original plan suggested.
  Date: 2026-10-13

- Decision: Inventory both per-command `holeWitness<Command>` helpers and the
  shared `holeWitnessFilled` helper in generated-name validation.
  Rationale: a Hole command named `Filled` would otherwise emit two declarations
  named `holeWitnessFilled`. A focused negative case verifies early refusal.
  Date: 2026-10-13

## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


### Vocabulary used in this plan

An *aggregate* is a state machine declared in a `.keiro` file: named *vertices* (its
`states`), typed *registers* (its `regs`, each with an initial value), *commands*, *events*,
and *transitions* of the form `Source -- Command --> … goto Target`. The first state listed
is the *initial vertex*. A transition is *live* unless prefixed `replay-only`; a replay-only
transition is never taken by a new command and exists so historical events keep an
inverting edge (see ADR-2 below). Keiki is the pure state-machine library the generated
code runs on; a *transducer* is Keiki's compiled machine, `step` executes one command, and
`applyEventsEither` replays events. The *harness* is the generated `Harness.hs` described in
Purpose. An *implementation hole* is a transition declared with `implementation hole`: the
generator still owns the command match, mode, emitted event kinds and target, but the
guard and register writes live in a create-once consumer module `<HolePrefix>/Holes.hs`.
The *behavior contract* is the generated `BehaviorContract.hs` for a version-2 aggregate: it
lists every finite *behavior requirement* (live transition, required rejection, or
replay-only transition) under a stable *behavior key* such as
`BehaviorKey "behavior-v1-9ac263e3d7b0f7e1"`, and runs consumer-supplied *witnesses* from
the create-once `BehaviorHoles.hs`. A `LiveWitness` carries a history (events replayed from
the initial state), a command, and an expectation (`Emits`, `NoOp`, or `Rejects`); a
`ReplayWitness` carries a history prefix and the observed chunk. The *whole-service
conformance package* is the `keiro-dsl-conformance.workspace.<service>/` package the
workspace scaffolder generates; its `Main.hs` runs `runServiceConformanceChecks` from
`<Module>.<Service>.Generated.Conformance`. The *conformance corpus* is the set of committed
scaffold outputs under `keiro-dsl/test/conformance-*`, documented in
`keiro-dsl/test/README.md`, regenerated by `cabal run -v0 keiro-dsl-corpus-regen -- regenerate`
and checked byte-for-byte by `scripts/check-conformance-corpus.sh`.

### Where the defect lives

`keiro-dsl/src/Keiro/Dsl/Harness.hs` is the harness generator. `emitHarness` (line 820)
renders the module. `initialLiveTransitionEntries` (line 1012) selects every transition
whose source is the first state and whose mode is `TmLive`; it does not look at the
transition's `implementation` field. `acceptDecl` (line 1063) renders

```haskell
accept<Command> :: Bool
accept<Command> =
  case step <agg>Transducer (<InitialVertex>, initial<Agg>Regs) (<synthetic command>) of
    Just (v, _, _) -> v == <GotoVertex>
    Nothing -> False
```

and `forwardReplayDecl` (line 1077) renders the forward/replay helper from the same seed,
for every entry whose `emits` is non-empty (the `replayTransitions` binding inside
`emitHarness`, line 877). The synthetic command comes from `commandCtorExpr`, which picks
per-field sample values. Nothing in this path consults the consumer's witness. The
ownership model is `TransitionImplementation` in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`
(line 653): `LegacyHoleImplementation` (version-1 aggregates), `GeneratedImplementation`
(the default), and `HoleImplementation`.

`keiro-dsl/src/Keiro/Dsl/AggregateGenerationPlan.hs` defines `TransitionLayoutEntry`
(line 13) with `declarationIndex`, which is 1-based (`zip [1 ..]`), and `outgoingIndex`,
which is 0-based per source vertex. `keiro-dsl/src/Keiro/Dsl/BehaviorCoverage.hs` derives
requirements (`deriveAggregateBehaviorRequirements`, line 272); each `BehaviorRequirement`
(line 98) has `key`, `kind`, `evidence`, `origin`, `source`, `command`, and more. The
`origin` of a transition requirement is `TransitionRequirementOrigin <aggregateName>
(TransitionOrdinal n)` where `TransitionOrdinal` (`keiro-dsl/src/Keiro/Dsl/SourceIndex.hs`,
line 49) is 0-based (`zip (map TransitionOrdinal [0 ..])`, line 278). So the requirement for
layout entry `e` has ordinal `e.declarationIndex - 1`. `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`
owns the generated contract: `emitBehaviorContract` (line 3167) renders the module text,
including `behaviorCoverageReport` (around line 3305), `runWitness`/`runLive`/`runAcceptance`
(around lines 3356 to 3425), and the internal `behaviorWitnessKey` (around line 3461);
`behaviorRequirementsFor` (around line 3669) sorts the derived requirements by key and is
used by `renderBehaviorRequirementList` and `emitBehaviorHoles`; it is not in the module's
export list (lines 20 to 118). `Keiro.Dsl.Harness` already imports `Keiro.Dsl.Scaffold`
unqualified, so exporting one more name is enough.

`keiro-dsl/src/Keiro/Dsl/ServiceHarness.hs` composes the whole-service conformance checks.
`checkExpression` (line 141) includes, for every aggregate, only
`<Alias>.harnessAssertions`. No generated conformance package calls
`behaviorCoverageReport`; `grep -rln behaviorCoverageReport keiro-dsl/src` returns only
`Scaffold.hs`, where the contract text is rendered. Consumers run their witnesses in their
own tests (Rei: `rei-core/test/Rei/Modules/*/Generated/BehaviorConformanceSpec.hs`). This
is why Rei's behavior tests pass while its workspace gate fails: the gate never executes
the witness, and the harness rows that it does execute presume empty registers.

### The reporter's evidence, verified

At `mori://shinzui/rei` revision `eaa401e1e9ea21c4b7fdcfb445461b2891c5cb14` (the commit
"chore(deps): adopt the released Keiro 0.20 cohort"), `domain/property-assignment.keiro`
declares `aggregate PropertyAssignment` with `regs values CustomPropertyValueMap = initial`,
`states Active`, live hole-owned edges for `SetProperty`, `ClearProperty`,
`ClearPropertyByCategoryChange`, `ClearPropertyByConditionChange`, and
`AutoInitializeProperty`, two generated-owned task-link edges, and replay-only hole-owned
twins for `SetProperty`, `ClearProperty`, and `AutoInitializeProperty`. The map type is
`mapped opaque CustomPropertyValueMap { … initial = "…initialCustomPropertyValueMap" }`.
`rei-core/src/Rei/Modules/PropertyAssignment/Holes.hs` lines 78 to 80 are

```haskell
transition2ActiveClearPropertyHole d = B.do
  B.requireGuard (K.PEq (K.TApp2 Map.member d.propertyId (B.reg @"values")) (K.TLit True))
  B.slot @"values" =: K.TApp2 deleteValue (B.reg @"values") d.propertyId
```

while the replay-only twin at lines 115 to 117 guards on `K.PTop`.
`rei-core/src/Rei/Modules/PropertyAssignment/BehaviorHoles.hs` lines 54 to 56 seed the live
clear witness with one `PropertySet` and seed every other command from empty history. The
generated `Generated/Harness.hs` lines 87 to 91 and 144 to 153 step `ClearProperty` from
`initialPropertyAssignmentRegs`, and the generated `BehaviorContract.hs` lists the live
`ClearProperty` requirement with `expectedEdge = Just (K.EdgeRef PropertyAssignmentActive 1)`
and `evidence = HoleWitnessed`. The retained gate log in
`docs/bug-reports/evidence/BUG-10-rei-workspace-gate.txt` shows exactly the two failing
rows. The diagnosis in the report is correct and complete; the completed
[IR-18](../improvement-requests/handle-initial-state-replay-only-transitions-in-generated-harnesses.md)
(plan 191) handled transition *mode* and edge layout, not *ownership*, so this is not a
regression of that repair.

### Reproduction in this repository (2026-10-13)

Scaffolding the following spec with `nix develop -c cabal run -v0 keiro-dsl -- scaffold
<spec> --out <dir>` on the current tree (generator 0.20.0.0) reproduces the shape:

```text
language keiro-dsl 6
context history-holes

aggregate Assignment
  regs
    count Natural = 0
  states Active

  command SetProperty { key:Text }
  command ClearProperty { key:Text }
  command Touch { note:Text }

  event PropertySet = fields(SetProperty)
  event PropertyCleared = fields(ClearProperty)
  event Touched = fields(Touch)

  Active -- SetProperty -->
    implementation hole
    emit PropertySet
    goto Active

  Active -- ClearProperty -->
    implementation hole
    emit PropertyCleared
    goto Active

  Active -- Touch -->
    emit Touched
    goto Active

  replay-only Active -- ClearProperty -->
    implementation hole
    emit PropertyCleared
    goto Active

  wire kind=ctorName fields=camelCase schemaVersion=1
```

The generated `Generated/HistoryHoles/Assignment/Harness.hs` contains, for the hole-owned
edge, exactly the probe BUG-10 quotes, with no reference to the witness:

```haskell
acceptClearProperty :: Bool
acceptClearProperty =
  case step assignmentTransducer (AssignmentActive, initialAssignmentRegs) (ClearProperty (ClearPropertyData "sample-key")) of
    Just (v, _, _) -> v == AssignmentActive
    Nothing -> False
```

The scaffold also reported four pending obligations, including a live
`AssignmentActive x ClearProperty` key and a distinct replay-only `AssignmentActive x
ClearProperty` key, and generated `HistoryHoles/Assignment/Holes.hs` with stub bodies
`_d = B.requireGuard K.PTop`. The stub accepts from empty registers, which is why a freshly
scaffolded hole passes today's probe and a correctly guarded hole fails it.

### Relevant architecture decisions

[ADR-17](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
makes every version-2 transition exclusively generated-owned or Hole-owned and says
generated code may never override a Hole's predicate. This plan extends the same principle
to evidence: the generator may only assert acceptance of an edge whose guard it can see;
for a Hole it must rely on the consumer's witness. Milestone 5 amends ADR-17 with that
paragraph. [ADR-2](../adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md)
explains two-phase inversion: replay tries live edges first and falls through to
replay-only edges only when no live edge matches, which is why the fixture's historical
empty clear replays through the replay-only edge while forward stepping cannot select it.
[ADR-49](../adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md)
makes Language 6 the baseline for new positive coverage; the single-spec fixture follows
it. `docs/adr/` is an OKF bundle governed by `docs/adr/profile.dhall`, validated by
`just adr-validate`, with `log.md` maintained through `okf log add`. No ADR covers how
harness probes choose their evidence; that gap is what the ADR-17 amendment fills.

### Test infrastructure you will touch

`keiro-dsl/test/Main.hs` is the `keiro-dsl-test` suite (hspec). Helpers used below already
exist there: `parseInlineSpec`, `defaultContext`, `scaffoldAggregate`, `harnessFor`,
`generatedTextEndingIn`, `runKeiroDsl`, `treeSnapshot`, `withTempDirectory`. The test
"uses one source-wide layout and excludes replay-only initial edges from live harness
probes" (around line 4000) is the closest model for the new generator tests. The test
"scaffolds the multi-member proof idempotently through the public CLI" (around line 11215)
copies an explicit `sourcePaths` list for the service-package fixture and must learn the
new member. `keiro-dsl/keiro-dsl.cabal` declares one `test-suite` per compiled fixture
(for example `keiro-dsl-conformance-behavior-complete` at line 394, and
`keiro-dsl-conformance-checked-mapping-replay` at line 2068, which also enables
`OverloadedLabels`). `cabal.project` lists the service-package runtime library and its
generated conformance package, so `cabal build all` compiles them and
`cabal test keiro-workspace-proof-conformance` runs the generated package directly.
`keiro-dsl/test/behavior-complete-mutation-test.sh` is the model for Milestone 4's mutation
script. `just verify` runs `haskell-verify` (which includes `cabal test keiro-dsl:tests`),
`adr-validate`, `bug-reports-validate`, `user-documentation-validate`,
`conformance-corpus-policy`, and `process-reaction-proof` among others; it stops at the first
failure, so read each gate's result inside its log rather than trusting a summary line.


## Plan of Work


### Milestone 1: a compiled fixture that fails before the repair

At the end of this milestone the repository contains a Language 6 fixture whose aggregate
mirrors Rei's shape, a compiled conformance suite for it, and a recorded run showing the two
BUG-10 rows failing while the behavior contract passes. Nothing in `keiro-dsl/src` changes.

Create `keiro-dsl/test/fixtures/history-dependent-holes.keiro`:

```text
language keiro-dsl 6
context history-dependent-holes

mapped opaque PropertyValues {
  haskell package=keiro-dsl module=Conformance.HistoryDependentHoles.Domain type=PropertyValues
  codec = "conformance.history-dependent-holes.PropertyValues.json"
  version = "1"
  fixtures = "Conformance.HistoryDependentHoles.Bindings.propertyValuesCases"
  initial = "Conformance.HistoryDependentHoles.Bindings.emptyPropertyValues"
}

aggregate Assignment
  regs
    values PropertyValues = initial
  states Active

  command SetProperty { key:Text value:Text }
  command ClearProperty { key:Text }
  command Touch { note:Text }

  event PropertySet = fields(SetProperty)
  event PropertyCleared = fields(ClearProperty)
  event Touched = fields(Touch)

  # Hole-owned: insert key -> value.
  Active -- SetProperty -->
    implementation hole
    emit PropertySet
    goto Active

  # Hole-owned: the key must already be present; delete it.
  Active -- ClearProperty -->
    implementation hole
    emit PropertyCleared
    goto Active

  # Generated-owned: keeps the ordinary synthetic probe.
  Active -- Touch -->
    emit Touched
    goto Active

  # Retained history: clears of absent keys appended under a retired rule.
  replay-only Active -- ClearProperty -->
    implementation hole
    emit PropertyCleared
    goto Active

  wire kind=ctorName fields=camelCase schemaVersion=1
```

The declaration order fixes the outgoing-edge indices on `Active`: `SetProperty` is edge 0,
live `ClearProperty` is edge 1, `Touch` is edge 2, and the replay-only `ClearProperty` is
edge 3. The live and replay-only clears have distinct behavior keys because their canonical
descriptions differ in mode.

The opaque type is consumer-owned. Create
`keiro-dsl/test/conformance-history-dependent-holes/Conformance/HistoryDependentHoles/Domain.hs`
with a newtype over `Map Text Text` deriving `Eq`, `Show`, `Generic`, and newtype-derived
`FromJSON`/`ToJSON`, plus whatever instance the generated modules demand when you compile
(the model is `Geometry` in
`keiro-dsl/test/conformance-structural/Conformance/Structural/Domain.hs`, which also derives
`NFData`). Create `…/Bindings.hs` exporting `emptyPropertyValues` (an empty map) and
`propertyValuesCases :: FixtureCases PropertyValues` with at least the labelled cases
`"empty"` and `"one"` (the scaffolder creates a binding skeleton for these names on the
first run if the file is absent; filling the skeleton it writes is equally fine).

Scaffold with the public CLI from the repository root:

```bash
nix develop -c cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/history-dependent-holes.keiro --out keiro-dsl/test/conformance-history-dependent-holes
```

The run prints the generated modules, the create-once modules, and a "new behavior
obligations" block with four keys. Copy the keys from that block (or from the generated
`HistoryDependentHoles/Assignment/BehaviorHoles.hs` stub); do not reuse keys from this
plan's reproduction, which was a different context and register. Then force-add the two
sidecars the global ignore rule hides:

```bash
git add -f keiro-dsl/test/conformance-history-dependent-holes/keiro-dsl-ledger.context.history-dependent-holes.txt \
           keiro-dsl/test/conformance-history-dependent-holes/keiro-dsl-cabal-fragment.context.history-dependent-holes.txt
```

Fill `keiro-dsl/test/conformance-history-dependent-holes/HistoryDependentHoles/Assignment/Holes.hs`.
Keep the generated payload/envelope types and fold-version tokens; replace the
write indices `writes writes` with `'[] '["values"]`, import `Keiki.Builder ((=:))`,
and replace the three stub bodies:

```haskell
transition1ActiveSetPropertyHole d = B.do
  B.requireGuard K.PTop
  B.slot @"values" =: K.TApp2 insertValue (B.reg @"values") (K.TApp2 (,) d.key d.value)

transition2ActiveClearPropertyHole d = B.do
  B.requireGuard (K.PEq (K.TApp2 memberValue d.key (B.reg @"values")) (K.TLit True))
  B.slot @"values" =: K.TApp2 deleteValue (B.reg @"values") d.key

transition4ActiveClearPropertyHole d = B.do
  B.requireGuard K.PTop
  B.slot @"values" =: K.TApp2 deleteValue (B.reg @"values") d.key
```

with three plain helpers in the same module: `insertValue :: PropertyValues -> (Text, Text)
-> PropertyValues`, `memberValue :: Text -> PropertyValues -> Bool`, and `deleteValue ::
PropertyValues -> Text -> PropertyValues`, implemented with `Data.Map.Strict`. Keep the
`-fold-v1` tokens: the fixture has no persisted history, so the first filled body is its
first fold version. This mirrors Rei's `Holes.hs` exactly apart from the helper names.

Fill `…/HistoryDependentHoles/Assignment/BehaviorHoles.hs` with four witnesses, using the
keys from the scaffold output. The live `SetProperty` and `Touch` witnesses start from empty
history and expect their own event. The live `ClearProperty` witness has history
`[PropertySet (PropertySetData "colour" "blue")]`, command `ClearProperty (ClearPropertyData
"colour")`, and expectation `Emits (PropertyCleared (PropertyClearedData "colour") :| [])`.
The replay-only `ClearProperty` witness is `ReplayWitness <key> [] [PropertyCleared
(PropertyClearedData "colour")]`: an empty clear in history must replay through edge 3
because the live edge's guard rejects it. Model the module on
`keiro-dsl/test/conformance-behavior-complete/BehaviorComplete/Journey/BehaviorHoles.hs`.

Create the driver `keiro-dsl/test/conformance-history-dependent-holes/Main.hs`. It prints
every `harnessAssertions` row as `PASS  <label>` or `FAIL  <label>`, prints
`renderBehaviorConformanceText (behaviorCoverageReport behaviorWitnesses)`, then appends four
direct rows and exits non-zero if any row is `False`:

- `live clear from empty registers refuses`: `step assignmentTransducer (AssignmentActive,
  initialAssignmentRegs) (ClearProperty (ClearPropertyData "colour"))` is `Nothing`.
- `forward stepping never selects the replay-only clear`: `K.stepDetailedEither` on the same
  seed and command returns `Left K.NoMatchingEdge {}`.
- `historical empty clear replays through the replay-only edge`:
  `K.applyEventsDetailedEither assignmentTransducer (AssignmentActive, initialAssignmentRegs)
  [PropertyCleared (PropertyClearedData "colour")]` succeeds with a one-element trace whose
  attribution has mode `K.ReplayOnly` and edge `K.EdgeRef AssignmentActive 3`.
- `behavior conformance passes`: `behaviorConformancePassed (behaviorCoverageReport
  behaviorWitnesses)`.

Add the test-suite to `keiro-dsl/keiro-dsl.cabal` next to the other conformance suites,
copying `other-modules` from the generated Cabal fragment and adding the two consumer
modules:

```text
test-suite keiro-dsl-conformance-history-dependent-holes
  import: warnings, generated-output
  type: exitcode-stdio-1.0
  default-extensions: OverloadedLabels
  hs-source-dirs: test/conformance-history-dependent-holes
  main-is: Main.hs
  other-modules:
    Conformance.HistoryDependentHoles.Bindings
    Conformance.HistoryDependentHoles.Domain
    HistoryDependentHoles.Assignment.BehaviorHoles
    HistoryDependentHoles.Assignment.Holes
    <every Generated.HistoryDependentHoles.* module the fragment lists>
  build-depends:
    aeson >=2.2 && <2.3,
    base >=4.21 && <5,
    containers >=0.6 && <0.8,
    deepseq,
    keiki >=0.9 && <0.10,
    keiro,
    text >=2.1 && <2.2,
    time >=1.12 && <1.15,
```

Drop `deepseq` if `Domain.hs` ends up not deriving `NFData`. Run the suite. On today's
generator the expected transcript contains

```text
FAIL  accepts ClearProperty from AssignmentActive
FAIL  forward/replay equality: ClearProperty from AssignmentActive -- forward step accepted
PASS  accepts SetProperty from AssignmentActive
PASS  accepts Touch from AssignmentActive
behavior conformance: Assignment
schema: keiro/behavior-conformance/1
required: 4 …
failed: 0
PASS  live clear from empty registers refuses
PASS  forward stepping never selects the replay-only clear
PASS  historical empty clear replays through the replay-only edge
PASS  behavior conformance passes
```

and the suite exits non-zero. Copy the two `FAIL` lines and the `failed: 0` line into
Surprises & Discoveries as the confirmation evidence, then edit
`docs/bug-reports/10-initial-hole-harness-requires-acceptance-from-empty-registers.md`:
set `status: confirmed`, set `generated.by` to `process:claude-code` (or the agent that did
the work) and `generated.at` to the current UTC time, add one sentence to the body naming
the failing suite, and log it:

```bash
okf log add docs/bug-reports --kind Update -m "BUG-10 is confirmed by the owning repository: keiro-dsl-conformance-history-dependent-holes fails the two initial-hole rows before plan 309's repair while its behavior report passes."
nix develop -c just bug-reports-validate
```

`keiro-dsl/test/conformance-baseline.json` inventories compiled suites and their
language ownership. Register the new suite as `candidate-primary`, Language 6,
with its source/directory and BUG-10 proof purpose. Also add its filename to the
explicit outside-Language-4 fixture list in `keiro-dsl/test/Main.hs`.

### Milestone 2: the generator repair and its unit tests

At the end of this milestone the fixture suite passes, every other suite still passes, and
the corpus is regenerated and byte-checked.

First, in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, add `behaviorRequirementsFor` to the
export list, and change `emitBehaviorContract` so the generated contract exports one more
function. Add `  , behaviorObligationReport` to the rendered export list after
`behaviorCoverageReport`, and render the body as a refactoring of the existing report:

```haskell
behaviorCoverageReport :: [BehaviorWitness] -> BehaviorConformanceReport
behaviorCoverageReport = coverageReportFor behaviorRequirements

-- | 'behaviorCoverageReport' restricted to one required obligation and the
-- witnesses that carry its key. Generated harness rows for Hole-owned initial
-- edges consult it instead of stepping the Hole from initial registers.
behaviorObligationReport :: BehaviorKey -> [BehaviorWitness] -> BehaviorConformanceReport
behaviorObligationReport key witnesses =
  coverageReportFor
    [requirement | requirement <- behaviorRequirements, requirement.requirementKey == key]
    [witness | witness <- witnesses, behaviorWitnessKey witness == key]

coverageReportFor :: [BehaviorRequirement] -> [BehaviorWitness] -> BehaviorConformanceReport
coverageReportFor requirements witnesses = …
```

where `coverageReportFor` is today's `behaviorCoverageReport` body with `requiredByKey`
built from the `requirements` argument. Everything else in the contract is unchanged.

Second, in `keiro-dsl/src/Keiro/Dsl/Harness.hs`, keep `initialLiveTransitionEntries` as the
ordered list that decides row order, and add two views of it:

```haskell
-- | Live initial edges whose guard the generator rendered (or legacy
-- version-1 edges): synthetic samples from initial registers remain sound.
initialSyntheticProbeEntries :: Agg -> [TransitionLayoutEntry]
initialSyntheticProbeEntries =
  filter ((/= HoleImplementation) . (.implementation) . (.transition)) . initialLiveTransitionEntries

-- | Live initial edges owned by a consumer Hole: only the consumer's
-- history-backed witness can establish acceptance (BUG-10).
initialWitnessProbeEntries :: Agg -> [TransitionLayoutEntry]
initialWitnessProbeEntries =
  filter ((== HoleImplementation) . (.implementation) . (.transition)) . initialLiveTransitionEntries
```

Add a key lookup that uses the exported requirements:

```haskell
witnessKeyFor :: Agg -> TransitionLayoutEntry -> Text
witnessKeyFor a entry =
  case [ Behavior.unBehaviorKey ((.key) requirement)
       | requirement <- behaviorRequirementsFor a
       , (.origin) requirement
           == Behavior.TransitionRequirementOrigin ((.name) a) (SourceIndex.TransitionOrdinal ((.declarationIndex) entry - 1))
       ] of
    [key] -> key
    keys -> error ("hole-owned initial edge " <> show ((.declarationIndex) entry) <> " has " <> show (length keys) <> " behavior requirements")
```

with `import Keiro.Dsl.BehaviorCoverage qualified as Behavior` and
`import Keiro.Dsl.SourceIndex qualified as SourceIndex`. The `error` branch is unreachable
for a checked spec (every live transition from the initial vertex is reachable and
therefore has exactly one requirement); it documents the invariant rather than guarding
user input.

Change `emitHarness`. The `accepts …` row list and the `++ forwardReplay<Command>` lines
still iterate `initialLiveTransitionEntries` so row order is unchanged. The declarations
become `concatMap (acceptDecl a . (.transition)) (initialSyntheticProbeEntries a)
++ concatMap (witnessAcceptDecl a) (initialWitnessProbeEntries a)`, and likewise for
forward/replay, where the synthetic `replayTransitions` filter is now computed over
`initialSyntheticProbeEntries` and a parallel `witnessReplayEntries` filter over
`initialWitnessProbeEntries` (both keep the "has emits" condition). Gate the three
things that today assume a synthetic probe exists: the `OverloadedLabels` pragma is emitted
only when synthetic replay transitions exist and the aggregate has registers; `coreImports`
includes `applyEventsEither` and `(!)` only for synthetic replay transitions and `step`
only when `initialSyntheticProbeEntries` is non-empty (confirm with `grep -n '"step\|step '
keiro-dsl/src/Keiro/Dsl/Harness.hs` that no other rendered text uses `step`; the mapped and
nominal harness blocks do not). When `initialWitnessProbeEntries` is non-empty, append two
imports to `harnessImports`:

```haskell
"import " <> (.holePrefix) a <> ".BehaviorHoles (behaviorWitnesses)",
"import " <> (.genPrefix) a <> ".BehaviorContract (BehaviorConformanceReport (..), BehaviorKey (..), behaviorObligationReport)"
```

and one shared helper after `roundTrips`:

```haskell
-- | One required obligation carrying exactly one non-pending witness.
holeWitnessFilled :: BehaviorKey -> BehaviorConformanceReport -> Bool
holeWitnessFilled key report = report.reportRequired == [key] && report.reportFilled == [key]
```

Render, per hole-owned entry with command `C`, source vertex constructor `V`, and key `K`:

```haskell
-- Hole-owned initial edge (plan 309): the consumer's history-backed live
-- witness proves acceptance through the generated behavior contract. Stepping
-- from initial registers would presume a history the Hole may require.
holeWitnessC :: BehaviorConformanceReport
holeWitnessC = behaviorObligationReport (BehaviorKey "K") behaviorWitnesses

acceptC :: Bool
acceptC = holeWitnessFilled (BehaviorKey "K") holeWitnessC && null holeWitnessC.reportFailed
```

and, only when the transition emits:

```haskell
-- forward/replay equality for a Hole-owned initial edge: the behavior contract
-- decodes the witness's emitted chain through the persisted codec, replays it,
-- and compares the final vertex and every register (plan 309).
forwardReplayC :: [(String, Bool)]
forwardReplayC =
  [ (prefix <> "hole witness filled", holeWitnessFilled key holeWitnessC)
  , (prefix <> "hole witness verified", holeWitnessFilled key holeWitnessC && null holeWitnessC.reportFailed)
  ]
  where
    key = BehaviorKey "K"
    prefix = "forward/replay equality: C from V -- "
```

Generated modules compile with `NoFieldSelectors` and `OverloadedRecordDot`, so field access
must use record-dot syntax as the generated contract itself does. The `accept<Command>`
helper name collision check that already exists (`GeneratedOccurrenceCollision`) covers the
new helpers because they derive from the same command stem; add `holeWitness<Command>` to
the inventory that check reads if the implementation shows a second helper family needs
it (the existing test "refuses duplicate live initial harness helpers with both source
locations" tells you where that inventory lives).

Update the module header comment of `Harness.hs` (items 4 and 5 in the numbered list) to
state that a Hole-owned initial edge is proved by the consumer witness.

Third, add tests to `keiro-dsl/test/Main.hs` beside the layout test near line 4000:

- "proves hole-owned initial edges through the consumer witness": an inline Language 6 spec
  with one register, a hole-owned initial self-loop with emits, a generated-owned initial
  self-loop, and a replay-only hole-owned twin. Assert the harness text imports
  `.BehaviorHoles (behaviorWitnesses)`, contains `behaviorObligationReport (BehaviorKey
  "behavior-v1-` exactly once per hole-owned live initial edge, contains the generated edge's
  `accept<Command>` stepping from `initial<Agg>Regs`, does not contain `step … initial…Regs`
  for the hole-owned command, contains the two `hole witness` row labels, and still contains
  no `accept` helper for the replay-only twin. Assert the generated contract text contains
  `behaviorObligationReport ::`.
- "omits Keiki stepping imports when every initial edge is hole-owned": a spec whose only
  initial live edges are holes; assert `step` and `applyEventsEither` are absent from the
  `Keiki.Core` import line and the `OverloadedLabels` pragma is absent.
- "keeps legacy version-1 initial probes unchanged": use a small inline Language 1 aggregate and assert that its Hole transducer
  import, synthetic initial step, and forward/replay helper remain present,
  without a behavior-contract import. `conformance-coldstart` is Language 4.
- "keeps the history-dependent fixture byte-identical across repeat scaffolds": scaffold
  `test/fixtures/history-dependent-holes.keiro` twice into a temp directory with
  `runKeiroDsl` and compare `treeSnapshot`s, modelled on the behavior-complete test near
  line 4290.

Fourth, regenerate and check the corpus:

```bash
nix develop -c just corpus-regen
git status --short
nix develop -c scripts/check-conformance-corpus.sh
```

Expected: every version-2 `BehaviorContract.hs` in the corpus gains the new function (that
is the unconditional export decision), the new fixture's `Harness.hs` changes to the
witness-backed form, and no other generated file changes except banners. If any other
`Harness.hs` changes, a committed suite has a hole-owned initial edge you did not expect;
inspect it, confirm the change is the intended one, and if its `BehaviorHoles.hs` is still
`Pending` for that edge, fill the witness (a pending witness now fails the row by design).
Then run the fixture suite (expect every row `PASS`) and the whole DSL test set:

```bash
nix develop -c cabal test keiro-dsl-conformance-history-dependent-holes --test-show-details=direct
nix develop -c cabal test keiro-dsl:tests --keep-going
```

### Milestone 3: the whole-service conformance proof

At the end of this milestone the committed service-package workspace has a member with the
same aggregate, and the generated conformance package reports its rows green.

Create `keiro-dsl/test/conformance-service-package/domain/assignment.keiro` with
`language keiro-dsl 4` and `context workspace-proof` (both required to match the other
members), the same `mapped opaque PropertyValues` declaration but pointing at
`haskell package=keiro-dsl-conformance-service-runtime module=Proof.WorkspaceProof.AssignmentDomain type=PropertyValues`,
`fixtures = "Proof.WorkspaceProof.AssignmentSupport.propertyValuesCases"`, and
`initial = "Proof.WorkspaceProof.AssignmentSupport.emptyPropertyValues"`, and the same
`aggregate Assignment` body as Milestone 1. Add `spec domain/assignment.keiro` to
`keiro-dsl/test/conformance-service-package/service.keiro-workspace`. Create the two
consumer modules under `keiro-dsl/test/conformance-service-package/runtime/src/Proof/WorkspaceProof/`
(`AssignmentDomain.hs`, `AssignmentSupport.hs`) with the same content as the Milestone 1
`Domain`/`Bindings` modules. Regenerate the workspace:

```bash
nix develop -c cabal run -v0 keiro-dsl-corpus-regen -- regenerate --only keiro-dsl/test/conformance-service-package/runtime/src
```

The collocated layout places generated modules at
`Proof.WorkspaceProof.Assignment.Generated.*` and the create-once modules at
`Proof.WorkspaceProof.Assignment.Holes` and `Proof.WorkspaceProof.Assignment.BehaviorHoles`.
Fill both exactly as in Milestone 1 (keys again come from this scaffold's output; they
differ from the single-spec keys because the context differs). Add every new module, the two
consumer modules, and `deepseq` if needed to `other-modules`/`build-depends` of
`keiro-dsl/test/conformance-service-package/runtime/keiro-dsl-conformance-service-runtime.cabal`,
using the regenerated `keiro-dsl-cabal-fragment.workspace.workspace-proof.txt` as the
authority. Add `"domain/assignment.keiro"` to the `sourcePaths` list of the test "scaffolds
the multi-member proof idempotently through the public CLI" in `keiro-dsl/test/Main.hs`
(around line 11220). `KeiroConformance.Expectations` needs no change: aggregates contribute
checks, not facts. Then:

```bash
nix develop -c cabal build all
nix develop -c cabal test keiro-workspace-proof-conformance --test-show-details=direct
nix develop -c scripts/check-conformance-corpus.sh
```

Expected transcript lines include `PASS  aggregate/Assignment/accepts ClearProperty from
AssignmentActive`, `PASS  aggregate/Assignment/forward/replay equality: ClearProperty from
AssignmentActive -- hole witness verified`, and `PASS  aggregate/Assignment/accepts Touch
from AssignmentActive`, and the suite exits zero. To see the pre-repair failure on this
surface too, stash the Milestone 2 generator change, regenerate, and run the package once;
record the `FAIL` lines in Surprises & Discoveries, then restore and regenerate.

### Milestone 4: falsification evidence

At the end of this milestone a script proves that each dishonest witness BUG-10 lists turns a
named row red, and `just verify` runs that script.

Create `keiro-dsl/test/history-dependent-holes-mutation-test.sh`, modelled on
`keiro-dsl/test/behavior-complete-mutation-test.sh`: back up
`keiro-dsl/test/conformance-history-dependent-holes/HistoryDependentHoles/Assignment/BehaviorHoles.hs`,
apply one `sed` mutation at a time, run

```bash
cabal test -v0 keiro-dsl-conformance-history-dependent-holes --test-show-details=direct
```

capturing output, require a non-zero exit and the expected substrings, restore, and repeat.
First assert the unmutated baseline is green. Mutations and the substrings each must
produce:

1. Delete the live `ClearProperty` witness line: `FAIL  accepts ClearProperty from
   AssignmentActive` and `FAIL  forward/replay equality: ClearProperty from AssignmentActive
   -- hole witness filled`.
2. Duplicate that line: the same two labels (the restricted report lists the key as
   duplicate, so it is not filled).
3. Replace it with `Pending (BehaviorKey "<live clear key>")`: the same two labels.
4. Change one character of its key (a stale key): the same two labels, plus `stale: 1` in
   the behavior report text.
5. Swap the live and replay-only `ClearProperty` keys (a `ReplayWitness` now carries the
   live key and vice versa): `FAIL  … -- hole witness verified` and `[witness-kind]` in the
   report; this is the proof that a live obligation cannot be satisfied by its replay-only
   sibling.
6. Empty the live clear witness's history (inadequate history): `FAIL  … -- hole witness
   verified` and `[unexpected-rejection]`.
7. Change the expected emitted event's key to `"other"` (lying about emissions):
   `FAIL  … -- hole witness verified` and `[event-value-mismatch]`.
8. Swap the live `ClearProperty` key with the live `SetProperty` key (wrong edge): `FAIL  …
   -- hole witness verified` and `[command-mismatch]` or `[edge-attribution]`, whichever the
   contract reports first; record the actual code in the script's expectation.

Also assert, without mutation, that the generated harness text still contains
`acceptTouch` stepping from `initialAssignmentRegs` (a `grep` on the committed
`Generated/HistoryDependentHoles/Assignment/Harness.hs`), which is the "ordinary
generated-edge probes retained" check. Add a recipe to `Justfile` in the `meta` group:

```text
[group('meta')]
initial-hole-proof:
    bash keiro-dsl/test/history-dependent-holes-mutation-test.sh
```

and append `initial-hole-proof` to the `verify` dependency list on line 15.

### Milestone 5: documentation, changelog, ADR, gate, and lifecycle

At the end of this milestone the user documentation describes the new evidence rule, the
changelogs announce it, ADR-17 records it, `just verify` is green, and BUG-10 is `fixed`.

In `docs/user/replay-safety.md`, after the sentence "Scaffolding emits one live
`acceptStart` probe." (around line 236), add that a live initial edge declared
`implementation hole` is proved by the consumer's `LiveWitness` through the generated
behavior contract rather than by stepping from initial registers, and that its
forward/replay rows are labelled `hole witness filled` and `hole witness verified`. In
`docs/user/keiro-dsl-workspaces-and-generated-code.md` under "Aggregate behavior evidence"
(around line 229), add that the generated whole-service conformance package executes the
witnesses of hole-owned initial edges, so a `Pending` witness for such an edge fails the
gate. In `docs/guides/choosing-keiro-dsl.md` under "Behavior conformance is finite evidence,
not universal proof" (around line 294), add one sentence that hole-owned initial-edge
witnesses are also executed by the whole-service gate. Both documentation bundles are OKF
bundles; run `nix develop -c just user-documentation-validate` and satisfy whatever it
reports (advance the document `timestamp`, add a `log.md` entry with `okf log add`).

In `keiro-dsl/CHANGELOG.md` and the root `CHANGELOG.md`, under `## [Unreleased]`, add a
`### Bug Fixes` entry: generated aggregate harnesses no longer step a Hole-owned initial
transition from initial registers; the `accepts <Command>` and forward/replay rows for such
edges are proved by the consumer's history-backed `LiveWitness` through the generated
`BehaviorContract`, which gains `behaviorObligationReport`; the forward/replay row labels for
those edges change to `hole witness filled`/`hole witness verified`; a `Pending` witness for
such an edge now fails the whole-service conformance package; cite BUG-10 as
`mori://shinzui/keiro/okf/bug-reports/concepts/BUG-10` and this plan. Generated-owned probes,
replay semantics, wire shapes, fold fingerprints, and snapshot identity are unchanged, so no
`keiro-dsl diff` impact or data migration follows.

Amend ADR-17 (`docs/adr/0017-…`): add a short section "Harness evidence follows ownership"
stating that generated probes may assert acceptance only for edges whose guard the
generator rendered, that Hole-owned edges are evidenced by the consumer witness through the
behavior contract, and that the whole-service gate therefore executes those witnesses.
Advance the ADR's `timestamp`, add `okf log add docs/adr --kind Update -m "ADR-17: harness
evidence follows transition ownership (plan 309)"`, and run `nix develop -c just
adr-validate`.

Run the full gate and read the marker inside the log rather than the shell's exit code:

```bash
nix develop -c just verify > /tmp/keiro-verify-309.log 2>&1; echo "EXIT=$?" >> /tmp/keiro-verify-309.log
grep -n "EXIT=\|error\|FAIL" /tmp/keiro-verify-309.log | tail -20
```

`just verify` stops at the first failing recipe, so if it fails, fix that recipe and rerun
until `EXIT=0` appears. Then set BUG-10 `status: fixed`, add `fixedVersion: "unreleased"`
and a one-sentence `resolution`, advance `generated`, update the BUG-10 row of
`docs/bug-reports/index.md` (status, plan, "Completed; …"), log with `okf log add`, and run
`just bug-reports-validate`. Fill Outcomes & Retrospective and perform the ADR distillation
pass (ADR-17 is the only expected durable change). Releasing 0.20.0.1 or 0.21.0.0 and
adopting it in Rei (whose `nix develop -c just keiro-gate` must then pass) are follow-ups
outside this plan; say so in the retrospective.


## Concrete Steps


All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` inside the
Nix development shell (prefix each with `nix develop -c`, or enter the shell once with
`nix develop`). Every commit carries the trailers

```text
ExecPlan: docs/plans/309-prove-hole-owned-initial-edges-through-history-backed-witnesses-in-generated-harnesses-to-fix-bug-10.md
Intention: intention_01m4trpbfhe64banxqfdh3va7w
```

and a Conventional Commits subject (`test(dsl): …`, `fix(dsl): …`, `docs(dsl): …`).

Milestone 1 (fixture before repair):

```bash
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/history-dependent-holes.keiro
cabal run -v0 keiro-dsl -- behavior-obligations keiro-dsl/test/fixtures/history-dependent-holes.keiro --format=text
cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/history-dependent-holes.keiro --out keiro-dsl/test/conformance-history-dependent-holes
git add -f keiro-dsl/test/conformance-history-dependent-holes/keiro-dsl-ledger.context.history-dependent-holes.txt keiro-dsl/test/conformance-history-dependent-holes/keiro-dsl-cabal-fragment.context.history-dependent-holes.txt
cabal test keiro-dsl-conformance-history-dependent-holes --test-show-details=direct
```

The `check` command must print no errors; `behavior-obligations` lists four obligations
(three live, one replay-only); the final test run must exit non-zero with exactly the two
`FAIL` rows shown in Milestone 1. Commit as `test(dsl): add the history-dependent hole
fixture that reproduces BUG-10`.

Milestone 2 (repair):

```bash
cabal build keiro-dsl
cabal test keiro-dsl-test --test-show-details=direct --test-options='--match "hole-owned"'
just corpus-regen
git status --short
scripts/check-conformance-corpus.sh
cabal test keiro-dsl-conformance-history-dependent-holes --test-show-details=direct
cabal test keiro-dsl:tests --keep-going
```

Commit the generator change with its tests as `fix(dsl): prove hole-owned initial edges
through behavior witnesses`, and the corpus regeneration as `test(dsl): regenerate the
conformance corpus for behaviorObligationReport` (the two may be one commit if the diff
stays reviewable).

Milestone 3 (whole-service proof):

```bash
cabal run -v0 keiro-dsl-corpus-regen -- regenerate --only keiro-dsl/test/conformance-service-package/runtime/src
cabal build all
cabal test keiro-workspace-proof-conformance --test-show-details=direct
cabal test keiro-dsl-test --test-show-details=direct --test-options='--match "multi-member proof"'
scripts/check-conformance-corpus.sh
```

Commit as `test(dsl): add the history-dependent hole member to the service-package proof`.

Milestone 4 (falsification):

```bash
bash keiro-dsl/test/history-dependent-holes-mutation-test.sh
just initial-hole-proof
```

Expected: one `ok: <mutation> -> <expected>` line per mutation and a zero exit. Commit as
`test(dsl): add initial-hole witness mutation evidence`.

Milestone 5 (docs, ADR, gate, lifecycle):

```bash
just user-documentation-validate
just adr-validate
just bug-reports-validate
just verify > /tmp/keiro-verify-309.log 2>&1; echo "EXIT=$?" >> /tmp/keiro-verify-309.log
tail -3 /tmp/keiro-verify-309.log
```

Commit documentation and changelog as `docs(dsl): document witness-backed initial hole
probes`, the ADR amendment as `docs(adr): extend ADR-17 with harness evidence ownership`,
and the lifecycle change as `docs(bugs): mark BUG-10 fixed pending release`.


## Validation and Acceptance


The repair is accepted when all of the following hold on one tree:

1. `cabal test keiro-dsl-conformance-history-dependent-holes --test-show-details=direct`
   exits zero and prints `PASS` for `accepts SetProperty from AssignmentActive`,
   `accepts ClearProperty from AssignmentActive`, `accepts Touch from AssignmentActive`,
   both `hole witness` rows for `ClearProperty` and `SetProperty`, the synthetic
   `forward/replay equality: Touch … -- final vertex` and `-- register values` rows, the four
   direct rows, and `failed: 0` in the behavior report. Before Milestone 2 the same command
   exits non-zero with the two BUG-10 rows red; that transcript is recorded in Surprises &
   Discoveries.
2. `cabal test keiro-workspace-proof-conformance --test-show-details=direct` exits zero and
   prints `PASS  aggregate/Assignment/accepts ClearProperty from AssignmentActive`.
3. `bash keiro-dsl/test/history-dependent-holes-mutation-test.sh` exits zero after
   observing every named failure listed in Milestone 4, including the replay-only sibling
   under the live key failing with `witness-kind`.
4. `cabal test keiro-dsl-test` passes the four new generator tests, and the existing test
   "uses one source-wide layout and excludes replay-only initial edges from live harness
   probes" still passes unchanged.
5. `scripts/check-conformance-corpus.sh` passes from a clean tree, proving that both the
   single-spec and the workspace scaffolds are byte-stable under regeneration.
6. The committed `Generated/BehaviorComplete/Journey/Harness.hs` is byte-identical
   to its pre-plan content (its initial edges are generated-owned). The sibling
   `BehaviorContract.hs` intentionally gains the uniform report API; compare
   only `Harness.hs` to prove ordinary probes are untouched.
7. `just verify` writes `EXIT=0` into its log.
8. BUG-10 is `fixed` with `fixedVersion: "unreleased"`, the index table row says so, and
   `just bug-reports-validate` passes.

Acceptance items 1 to 5 of the bug report map onto these checks: item 1 is check 1's
pre-repair transcript, item 2 is checks 1 and 2, item 3 is the direct rows in check 1, item
4 is check 3, and item 5 is checks 2 and 5 plus the Rei follow-up after release.


## Idempotence and Recovery


Scaffolding is idempotent: rerunning `keiro-dsl scaffold` on the same inputs rewrites
generated modules with identical bytes and skips create-once modules that exist; the corpus
regeneration driver never passes the force-overwrite flag, so filled `Holes.hs` and
`BehaviorHoles.hs` are safe. If a scaffold run refuses because of a stale ledger, delete only
the generated files it names and rerun. The mutation script restores every file it touches
on exit, including on failure; if it is interrupted hard, `git checkout --
keiro-dsl/test/conformance-history-dependent-holes/HistoryDependentHoles/Assignment/BehaviorHoles.hs`
restores the witness file. The generator change is additive in the contract and a
reordering in the harness; reverting the two source commits and rerunning
`just corpus-regen` returns the corpus to its previous bytes. If
`check-conformance-corpus.sh` refuses because a corpus path is dirty, commit or stash first;
it is designed to run only from a clean baseline. `okf log add` appends; if you log twice by
mistake, remove the duplicate line from `log.md` by hand before validating.


## Interfaces and Dependencies


No new library dependencies. The repair uses what the generated layer already imports:
`keiki` (`Keiki.Core`: `step`, `applyEventsEither`, `stepDetailedEither`,
`applyEventsDetailedEither`, `EdgeRef`, `EdgeMode`), `keiro` codecs, `aeson`, `containers`,
and `text`.

In `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, after Milestone 2, the export list contains
`behaviorRequirementsFor :: Agg -> [Behavior.BehaviorRequirement]`, and every generated
version-2 `BehaviorContract` exports

```haskell
behaviorObligationReport :: BehaviorKey -> [BehaviorWitness] -> BehaviorConformanceReport
```

with the law that `behaviorObligationReport key witnesses` equals the full
`behaviorCoverageReport` projected onto `key`: its `reportRequired` is `[key]` when `key` is
a requirement and `[]` otherwise, and its `reportStale` is `[]` for a known requirement key; an unknown key
with a supplied matching witness is reported stale.

In `keiro-dsl/src/Keiro/Dsl/Harness.hs`, after Milestone 2:

```haskell
initialLiveTransitionEntries :: Agg -> [TransitionLayoutEntry]   -- unchanged, row order
initialSyntheticProbeEntries :: Agg -> [TransitionLayoutEntry]   -- not HoleImplementation
initialWitnessProbeEntries   :: Agg -> [TransitionLayoutEntry]   -- HoleImplementation only
witnessKeyFor                :: Agg -> TransitionLayoutEntry -> Text
witnessAcceptDecl            :: Agg -> TransitionLayoutEntry -> [Text]
witnessForwardReplayDecl     :: Agg -> TransitionLayoutEntry -> [Text]
```

Every generated aggregate harness with at least one hole-owned live initial edge imports
`<holePrefix>.BehaviorHoles (behaviorWitnesses)` and
`<genPrefix>.BehaviorContract (BehaviorConformanceReport (..), BehaviorKey (..), behaviorObligationReport)`,
defines `holeWitnessFilled :: BehaviorKey -> BehaviorConformanceReport -> Bool` once, and
defines `holeWitness<Command> :: BehaviorConformanceReport` per such edge. Harnesses without
such an edge are byte-identical to today's output apart from the generator banner.

New committed artifacts: `keiro-dsl/test/fixtures/history-dependent-holes.keiro`;
`keiro-dsl/test/conformance-history-dependent-holes/` (consumer `Domain`/`Bindings`, filled
`Holes`/`BehaviorHoles`, `Main.hs`, generated modules, ledger, Cabal fragment); the
`keiro-dsl-conformance-history-dependent-holes` test-suite in `keiro-dsl/keiro-dsl.cabal`;
`keiro-dsl/test/conformance-service-package/domain/assignment.keiro` with its runtime
modules and fills; `keiro-dsl/test/history-dependent-holes-mutation-test.sh`; the
`initial-hole-proof` recipe in `Justfile`.

Revision note (2026-10-13): implementation began with scaffolded single-spec and
workspace reproductions; filled Hole signatures explicitly account for their register write.

Revision note (2026-10-13): captured both compiled pre-repair failures, implemented
ownership-aware evidence and the shared contract runner, added import and helper
collision safeguards, and drafted the mutation gate, documentation, and ADR-17 amendment.

Revision note (2026-10-13): the broad run exposed two explicit fixture inventories
omitted by the original plan. Registered the new Language 6 proof in both; focused
inventory reruns pass. The repository gate will rerun the entire DSL target, avoiding
an additional duplicate run of its isolated workspace compilation test.
