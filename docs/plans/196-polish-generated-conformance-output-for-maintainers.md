---
id: 196
slug: polish-generated-conformance-output-for-maintainers
title: "Polish generated conformance output for maintainers"
kind: exec-plan
created_at: 2026-08-05T04:54:27Z
intention: "intention_01kz84b5jre3187dmmyjmd02fc"
master_plan: "docs/masterplans/29-stabilize-keiro-dsl-for-wide-adoption.md"
---

# Polish generated conformance output for maintainers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

When a behavior witness fails today, the failure message names an opaque hash: `FAIL
behavior-v1-2e1fd6b9580e1a3d [event-value-mismatch] runtime event values differ from the exact
witness expectation`. The maintainer must open the generated contract, find the hash in a
positionally applied constructor row, and mentally decode ten unnamed fields to learn which state
and command broke — and even then the message shows neither the actual nor the expected value.
After this plan, the same failure tells the maintainer which state × command cell broke, at which
spec line, with actual versus expected values — and the two generated modules a maintainer opens
when a check fails (`BehaviorContract.hs` and `Harness.hs`) read like reviewed code: every
top-level binding carries a type signature, every opaque behavior key carries a comment naming its
state × command cell, sample values are named constants instead of repeated 300-character
expressions, read-model facts compare notation against the live runtime value instead of a literal
against itself, and the whole committed conformance corpus compiles with zero `-Wall` warnings.

This is a presentation and evidence-richness change only. BehaviorKey bytes, fold fingerprints,
wire bytes, read-model shape hashes, and behavior-conformance pass/fail semantics are all frozen;
the plan proves this with the existing fold baseline golden and a key-set extraction before and
after regeneration.


## Progress

- [x] (2026-08-04) Verified every 2026-08-04 audit anchor against the committed fixtures and the
  emitters (evidence recorded in Context and Orientation and Surprises & Discoveries); authored
  this plan as EP-196, Phase 3 of MasterPlan 29.
- [x] (2026-08-05T18:09:58Z) Milestone 1: BehaviorContract now emits a curated public surface,
  complete top-level signatures without warning suppressions, annotated record-syntax
  requirements and Pending rows, and subject/actual/expected failure evidence. The focused
  behavior suite passed 11 examples; a disposable public-CLI scaffold confirmed every required
  signature and annotation while leaving committed corpus bytes untouched for Milestone 4.
- [x] (2026-08-05T19:14:30Z) Milestone 2: Harness output now uses one named constant per
  generated ID/time sample, minimal constructor parentheses, honest clock-free comments,
  runtime-backed read-model facts, a shared optional-field decoder, node-named facade aliases,
  and an explanatory empty-Projection comment. Focused aggregate, structural, read-model, and
  facade assertions pass.
- [x] (2026-08-05T19:14:30Z) Milestone 3: static and planned imports now follow emitted use,
  workqueue provisioning imports follow the selected policy, generated Hole implementations
  carry explicit signatures, all conformance package surfaces use `-Wall`, and the structural
  BehaviorContract is compiled. A 37-component `cabal test keiro-dsl` compile emitted zero
  compiler warnings.
- [x] (2026-08-05T19:33:19Z) Milestone 4: EP-195's 41-invocation driver performed the single
  corpus refresh, deliberate create-once updates were reviewed, and the clean-tree policy was
  activated. The falsification/restoration proof, frozen-identity checks, ADR/doc/changelog
  closure, strict ADR validation, and the complete 37-component test battery all pass.


## Surprises & Discoveries

- Observation: `runReadModelFacts` is not fully orphaned. The generated service conformance
  package never calls it (its `Main.hs` renders `readModelFactResults` through the facade), but
  two hand-owned suite drivers do call it:
  `keiro-dsl/test/conformance-newsurface/Main.hs:24` and
  `keiro-dsl/test/conformance-readmodel-runtime/Main.hs:18`, and `keiro-dsl/test/Main.hs:3569`
  pins its presence. The fix is therefore to keep the runner and repair the vacuous fact rows,
  not to delete the export.
  Date: 2026-08-04

- Observation: the repository's ~36 conformance test components already compile under `-Wall`
  through the `common warnings` stanza (`keiro-dsl/keiro-dsl.cabal` lines 20–21, imported by
  every `test-suite keiro-dsl-conformance-*`), so the systematic unused imports are visible
  warning spam in every full build log today. The deterministic import planner
  (`keiro-dsl/src/Keiro/Dsl/HaskellImport.hs`, `planHaskellImports`) is already consumed for
  consumer-supplied references (`domainImportPlan`, `codecImportPlan`, the harness and binding
  planners), but the fixed static import blocks — for example `Scaffold.hs` lines 4082–4106 in
  `emitCodec` — are emitted unconditionally and bypass it.
  Date: 2026-08-04

- Observation: no hand-owned module uses any BehaviorContract internal helper. Filled witness
  modules use only the exported data constructors, and suite `Main.hs` drivers use only
  `behaviorCoverageReport`, `behaviorConformancePassed(With)`, and
  `renderBehaviorConformanceText`. The only textual reference to an internal helper outside
  generated code is a test pin (`keiro-dsl/test/Main.hs:1453` asserts the contract contains
  `commandKind command == requirementCommandName requirement`). A curated export list is
  therefore safe.
  Date: 2026-08-04

- Observation: Milestone 2's `sampleRequestId :: RequestId` constant makes the Harness module's
  currently-unused `RequestId` type import (`Generated/BehaviorComplete/Journey/Harness.hs:10`)
  used, so the milestones interlock: constants land before import pruning.
  Date: 2026-08-04

- Observation: EP-195's first honest 41-invocation replay found 387 files of existing generator
  drift (944 insertions, 417 deletions) and restored them, confirming that a clean-tree gate
  cannot pass before this plan's already-batched corpus refresh. Its Cabal closure checker also
  records 108 explicit uncompiled paths: 107 intentional non-target surfaces in narrow suites
  and the one unexpected structural BehaviorContract this plan already owns.
  Date: 2026-08-05

- Observation: adding the spec line to each human-readable behavior-row comment exposed the same
  intentional single-file/workspace source-line relocation that EP-191 already normalized for
  the positional requirement row. The byte-parity test now normalizes both the record field and
  its adjacent comment while continuing to compare every behavior key, cell, kind, edge, target,
  and event byte exactly.
  Evidence: the first focused behavior run differed only by the workspace composition's uniform
  two-line offset; the rerun passed 11 examples after extending that existing normalization.
  Date: 2026-08-05

- Observation: the compiler sweep exposed a second kind of over-planning beyond fixed static
  imports. Codec and Harness import plans included consumer type references merely because the
  types were reachable from commands, events, or registers, even when rendered code used only
  their binding and fixture values. Planning the exact rendered reference removed the remaining
  collision-fixture imports without weakening the deterministic alias planner.
  Date: 2026-08-05

- Observation: `Generated.TransferRouting.Conformance` is the corpus manifest's one explicit
  `legacy-generated` path. Its source invocation has no runtime-package setting, so the general
  41-invocation replay correctly preserves it but cannot plan or overwrite it. A disposable
  public-CLI scaffold with `--runtime-package transfer-routing-runtime` produced the current
  facade bytes, which were then applied as the deliberate legacy fixture update.
  Date: 2026-08-05


## Decision Log

- Decision: Behavior-key annotation is trailing comments and record syntax only; the
  `BehaviorKey` byte strings, their `behavior-v1-<fnv1a64>` derivation
  (`keiro-dsl/src/Keiro/Dsl/BehaviorCoverage.hs:361`), and their sorted-by-key row order are
  untouched.
  Rationale: keys are frozen create-once identities pinned outside the fold digest; hand-owned
  witness modules and scaffold records reference them by exact bytes. Changing row order would
  churn diffs for no benefit; comments give the human mapping without moving anything.
  Date: 2026-08-04

- Decision: enrich failures by adding a `failureSubject :: !Text` field to `BehaviorFailure`,
  built by the `failure` helper from the requirement (source vertex, command, obligation kind,
  spec line), rendered in both the text output and the JSON object as a new `subject` key, and
  by interpolating `show`-rendered actual and expected values into `failureDetail` at every
  comparison of two showable values.
  Rationale: the requirement is already in scope at every failure site, so no plumbing changes;
  the JSON report schema `keiro/behavior-conformance/1` is append-only for readers that ignore
  unknown keys, so adding `subject` needs no schema bump.
  Date: 2026-08-04

- Decision: do not add `-Werror` to generated cabal output. Unify on `ghc-options: -Wall` in the
  generated conformance-package cabal (`renderCabal` in
  `keiro-dsl/src/Keiro/Dsl/ConformancePackage.hs`) and in the committed corpus package cabals;
  prove zero warnings with a filtered build-log transcript in Milestone 4.
  Rationale: GHC grows new `-Wall` warnings across releases; `-Werror` in shipped consumer-facing
  output would make a scaffolded package fail to build on a newer GHC for reasons the spec author
  cannot control, which is exactly the adoption churn MasterPlan 29 exists to remove. The
  repository already compiles the corpus with `-Wall` via the `warnings` stanza, so a clean log
  is a durable, re-checkable proof.
  Date: 2026-08-04

- Decision: keep `runReadModelFacts` and repair the fact rows so the actual column comes from the
  runtime `ReadModel` record value (and `AsyncProjection` value) instead of re-emitting the
  expected literal.
  Rationale: hand-owned drivers call the runner (see Surprises & Discoveries), and every Cabal
  component that compiles a `ReadModelHarness` already compiles the sibling generated `ReadModel`
  module and its create-once `ReadModelHoles` (verified for `conformance-skeletons` SkelQueue,
  `conformance-readmodel-runtime`, `conformance-newsurface`, and the service-package runtime), so
  the new import cannot break any component.
  Date: 2026-08-04

- Decision: the baked clock-free row becomes a comment when the scaffold-time result is `True`
  and remains a failing assertion when it is `False`.
  Rationale: a constant-`True` assertion can never fail and misleads a reader scanning assertion
  labels; removing only the `True` case provably cannot change any suite's pass/fail result,
  while the `False` case keeps its existing gate semantics.
  Date: 2026-08-04

- Decision: facade import aliases derive from the node identity (`Alpha`, `Beta`, `AlphaView`,
  `BetaView`, `WorkspaceProofWorkflow`) with a deterministic numeric-suffix fallback only when
  two nodes normalize to the same alias.
  Rationale: `Harness0`–`Harness4` forces the reader to count import lines; node-named aliases
  make the facade self-describing while the fallback keeps generation total.
  Date: 2026-08-04

- Decision: sample constants are named `sample<NominalTypeName>` for generated ID nominals (for
  example `sampleRequestId`) and `sampleObservedAt :: UTCTime` for the shared `Time` sample
  (falling back to `sampleTime` if a future module's `Time` fields are not named `observedAt`);
  the parse-failure arm becomes `Left problem -> error (show problem)`.
  Rationale: the constants replace one identical repeated expression per type, so type-keyed
  names are unambiguous; every `Time` sample field in the current corpus is `observedAt`, and
  surfacing the parse problem replaces a silent `Left _` swallow with actionable output.
  Date: 2026-08-04

- Decision: Milestones 1–3 validate through focused emitter tests and disposable-directory
  scaffolds only; the committed corpus is refreshed exactly once, in Milestone 4, through the
  EP-195 regeneration tool (`docs/plans/195-build-conformance-corpus-regeneration-tooling.md`).
  Rationale: the byte-identity conformance tests pin committed trees to fresh scaffold output, so
  every emitter milestone invalidates them; refreshing per milestone would spend the corpus churn
  three times, which is the tax EP-195 exists to remove. This is the MasterPlan 29 hard
  dependency.
  Date: 2026-08-04

- Decision: Activate EP-195's `check` mode and repository policy only after Milestone 4 commits
  this plan's single corpus refresh. Add the policy script and Justfile/`verify` wiring in the
  same milestone.
  Rationale: EP-195 proved the current baseline is 387 files behind the current generator. A
  gate landed before this refresh is necessarily red; refreshing in EP-195 and again here would
  spend the whole-corpus churn twice. This sequencing keeps the hard-dependency tooling usable,
  preserves one reviewed churn event, and makes the new gate green from its first commit.
  Date: 2026-08-05

- Decision: explicitly excluded from this plan — (a) printer style unification (leading versus
  trailing commas and similar layout differences between module families) and (b) moving the
  duplicated private helpers (`mapLeftText`, `tshow`, and the object-surgery trio
  `deleteObjectField`/`insertObjectField`/`objectField`) into the keiro runtime library. Both are
  recorded as deferred follow-ups. EP-191 owns all transition-layout and acceptance-helper
  structural changes in `Harness.hs`; this plan changes how surviving declarations read, not
  which declarations exist.
  Rationale: (a) is cosmetic churn with no maintainer-evidence payoff; (b) changes the generated
  output's dependency surface, which is a separate decision with its own compatibility story.
  Date: 2026-08-04

- Decision: generated Hole-owned transition functions receive their full polymorphic
  `B.EdgeBuilder ... writes writes ()` signatures rather than suppressing
  `-Wmissing-signatures`; deliberately obsolete hand-owned migration sentinels remain
  compiler-visible through their module export rather than a warning-suppression pragma.
  Rationale: the advertised warning contract applies at the generated boundary, and a stable
  signature documents the exact capability a Hole owns while keeping the corpus genuinely
  warning-clean.
  Date: 2026-08-05

- Decision: amend ADR 0017 with one paragraph (behavior evidence is rendered human-attributable:
  annotated keys, record-syntax requirements, failures carrying cell/spec-line/actual/expected)
  and ADR 0019 with one sentence (generated modules carry complete top-level signatures and no
  warning-suppression pragmas; the corpus compiles warning-free under the advertised profile).
  No new ADR.
  Rationale: both decisions complete existing accepted decisions rather than choosing a new
  architecture; ADR 0017 already owns behavior-evidence shape and ADR 0019 already owns the
  generated compilation contract.
  Date: 2026-08-04


## Outcomes & Retrospective

EP-196 is complete. The first full EP-195 replay after the emitter changes reported 421 changed
files; deliberate updates to preserved create-once/legacy fixtures plus generator, policy, tests,
and plan bookkeeping produced the 442-file implementation commit. A second direct replay and the
`just conformance-corpus-policy` entry point each ran all 41 invocations and finished with
`conformance corpus: ok`; the golden updater ran 582 examples with zero failures and reported no
Git changes. A pre-dirtied corpus was refused before scaffolding with `conformance corpus check
requires clean corpus paths before scaffolding`, proving the gate's destructive-work guard.

The clean `bb79ed8e` baseline build emitted 58 GHC warnings, including 19 from generated modules.
The final 37-component `cabal test keiro-dsl` compile emitted zero GHC warnings, all 37 suites
passed, and the main suite passed all 582 examples. The named behavior-complete and generated
workspace-proof targets also passed independently. Generated sources contain no `-Wno-*`
suppression, while generated and committed package surfaces advertise `-Wall` without `-Werror`.

The deliberate Journey witness mutation produced the intended evidence-rich failure:

```text
behavior conformance: Journey
schema: keiro/behavior-conformance/1
required: 19
filled: 19
pending: 0
missing: 0
duplicate: 0
stale: 0
failed: 1
verified: 16
unverified: 2
FAIL behavior-v1-2f3ebf37a55781db JourneyActive x Decide: live transition (spec line 44) [event-value-mismatch] runtime event values differ from the exact witness expectation; actual=[DecisionRecorded (DecisionRecordedData {amount = 5})] expected=[DecisionRecorded (DecisionRecordedData {amount = 6})]
```

Restoring the witness exactly returned the report to `failed: 0`, `verified: 17`, and
`unverified: 2`. The corpus-diff key extraction returned `0` unmatched behavior keys; the fold
identity baseline had no diff; inspection found no changed wire tag, payload key, shape hash, or
snapshot discriminator. There is therefore no wire, fold, replay, snapshot, behavior-key, or
witness-value compatibility drift. ADRs 0017 and 0019, their OKF-generated log entries, the user
guide, and both changelogs publish the resulting presentation and regeneration contract; strict
validation reports `OK: 21 concepts`.


## Context and Orientation

This plan is EP-196 in `docs/masterplans/29-stabilize-keiro-dsl-for-wide-adoption.md` (Phase 3,
the one deliberate churn event). It has a hard dependency on EP-195
(`docs/plans/195-build-conformance-corpus-regeneration-tooling.md`), whose tool drives the public
`keiro-dsl` CLI over every committed fixture spec, overwrites only banner-recognized generated
files, never touches create-once modules, and keeps `keiro-dsl/keiro-dsl.cabal` test-component
module inventories consistent. It has soft dependencies on EP-191
(`docs/plans/191-unify-generated-transition-layout-for-replay-only-conformance.md`) and EP-192
(`docs/plans/192-decouple-wire-keys-from-generated-haskell-selectors-with-field-aliases.md`):
this plan starts from their merged state of `keiro-dsl/src/Keiro/Dsl/Harness.hs` and the codec
emitters — EP-191 decides which harness declarations exist (mode-aware layout consumption),
EP-192 makes codec output alias-aware, and this plan restyles what survives — and it refreshes
the corpus once, after both, through EP-195's tool. If either soft dependency has not merged when
implementation begins, coordinate per the MasterPlan's phase ordering; do not restructure
`emitHarness` here. Line numbers below were verified against the working tree at commit
`ba9ffefd` (2026-08-04) and will drift as EP-191/192 land; every anchor also names its declaring
function so it can be relocated with `rg`.

Vocabulary, defined once. A _spec_ is a typed `.keiro` file checked by the `keiro-dsl` CLI.
_Scaffolding_ generates Haskell from it: _overwriteable generated modules_ carry a provenance
banner (`-- @generated by keiro-dsl ...; do not edit.`) and are rewritten on every scaffold,
while _create-once modules_ (`HoleStub` kind — hole fills, behavior witnesses, expectations) are
written once and become hand-owned (ADR 0015). The _behavior contract_ is the generated
`BehaviorContract.hs` module of an aggregate: a finite list of _behavior requirements_ (one per
live transition, reachable rejection cell, and replay-only transition), each identified by a
_behavior key_ — `behavior-v1-` plus an FNV-1a 64-bit hash of the requirement's canonical text
(`keiro-dsl/src/Keiro/Dsl/BehaviorCoverage.hs:361`). The application fills the create-once
`BehaviorHoles.hs` with one _witness_ per key; the contract executes each witness against the
generated transducer and codec and reports failures. The _harness_ (`Harness.hs`) is a generated
list of `(String, Bool)` assertions per aggregate; the _service conformance facade_
(`Conformance.hs`, ADR 0020) aggregates node harnesses for the generated per-service conformance
package. The _conformance corpus_ is the ~36 committed suite directories under `keiro-dsl/test/`
(36 `conformance*` trees, 37 test-suite stanzas) plus two standalone packages listed in
`cabal.project`: `keiro-dsl/test/conformance-behavior-complete` (executable package
`keiro-dsl-behavior-complete-report`) and `keiro-dsl/test/conformance-service-package/runtime`
with its generated package
`.../runtime/src/keiro-dsl-conformance.workspace.workspace-proof`. Byte-identity tests in
`keiro-dsl/test/Main.hs` pin committed trees to fresh scaffold output, which is why emitter
changes require a corpus refresh. `-Wall` is GHC's standard warning set (it includes
missing-signature, name-shadowing, and unused-import warnings).

The 2026-08-04 audit findings, each re-verified in the current tree:

1. **BehaviorContract suppresses warnings instead of carrying signatures.**
   `keiro-dsl/test/conformance-behavior-complete/Generated/BehaviorComplete/Journey/BehaviorContract.hs:2`
   is `{-# OPTIONS_GHC -Wno-missing-signatures -Wno-name-shadowing #-}`, emitted at
   `keiro-dsl/src/Keiro/Dsl/Scaffold.hs:2295` in `emitBehaviorContract`. Fifteen top-level
   bindings are unsigned (fixture lines 195–293): `runRejection`, `runAcceptance`,
   `checkAcceptedEnvelope`, `checkSingleAttribution`, `settleHistory`, `commandKind`,
   `eventKind`, `proofStrength`, `behaviorWitnessKey`, `isPending`, `ensure`, `failure`,
   `sortedKeys`, `keyTexts`, `countLine`. The shadowing suppression exists only because binders
   named `failure` (the `toJSON failure` instance argument at fixture line 77 and the
   comprehension binders at lines 150 and 177) shadow the `failure` helper. The module also
   exports everything via `module ... where` (emitter line 2297).

2. **Behavior keys are opaque hashes with no human annotation.** Scaffolded stubs read
   `Pending (BehaviorKey "behavior-v1-e2c1eef1cb7848f5")` with no comment naming the state ×
   command cell
   (`keiro-dsl/test/conformance-service-package/runtime/src/Proof/WorkspaceProof/Alpha/BehaviorHoles.hs:8`,
   likewise the committed skeleton stubs under `keiro-dsl/test/conformance-skeletons/`), emitted
   by `emitBehaviorHoles` (`Scaffold.hs:2673–2693`). The requirement table applies the 10-field
   `BehaviorRequirement` constructor positionally, sorted by hash (fixture
   `BehaviorContract.hs:112–125`; renderer `renderBehaviorRequirementList`,
   `Scaffold.hs:2586–2617`). The state/command mapping today exists only in the scaffold-record
   sidecar. The renderer has everything needed for annotation:
   `Behavior.BehaviorRequirement` carries `requirementSource`, `requirementCommand`,
   `requirementKind`, and `requirementLocation`.

3. **Failure output identifies the hash, not the construct.** `BehaviorFailure` carries
   key + code + prose only (fixture lines 69–81); text rendering (lines 164–177) prints
   `FAIL <key> [<code>] <detail>`; `requirementLine` (line 41) is stored but never rendered; the
   `event-value-mismatch` branch (line 219) shows neither actual nor expected although both are
   `Show`-able (`deriving stock (Eq, Show)` on all event types).

4. **Harness sample expressions are unreadable and duplicated.** A ~300-character partial
   expression `(case parseRequestId "req_01h455vb4pex5vsknk084sn02q" of Right parsed -> parsed;
   Left _ -> error "generated valid ID sample failed to parse")` plus a full `UTCTime` literal
   is duplicated at every use site
   (`Generated/BehaviorComplete/Journey/Harness.hs:49,62,70,121`;
   `Proof/WorkspaceProof/Alpha/Generated/Harness.hs:27,31,39`). Sources:
   `generatedIdSampleHaskell` (`Scaffold.hs:5254–5268`) and the `AggregateTime` sample literal
   (`keiro-dsl/src/Keiro/Dsl/AggregateType.hs:298`), spliced by `sampleValue`/`ctorExpr`/
   `commandCtorExpr` in `Harness.hs` (lines 648–776). `ctorExpr` wraps its whole result in
   parentheses, producing `sampleEventStarted = (Started (...))` at a binding position, and
   `acceptDecl`/`forwardReplayDecl` wrap `commandCtorExpr` (already parenthesized) again
   (`Harness.hs:665–667, 703–705`), producing `step ... ((Start (...)))`. `Left _` swallows the
   parse error.

5. **Read-model facts are vacuous.** Every triple in
   `.../AlphaView/Generated/ReadModelHarness.hs:5–13` compares a generated literal against the
   same generated literal (emitter `emitReadModelHarness`, `keiro-dsl/src/Keiro/Dsl/Harness.hs:
   180–219`, whose `consistency`/`strongScope`/`shapeHash` rows literally emit the same value
   twice), so drift between notation and the runtime value is undetectable. The runtime value
   exists and is in the same package: `alphaViewReadModel :: ReadModel ...` in the generated
   `ReadModel.hs` exposes `name`, `subscriptionName`, `shapeHash`, `defaultConsistency`,
   `strongScope` (all `Show`/`Text`; `Keiro.ReadModel` at `keiro/src/Keiro/ReadModel.hs:90–101`),
   and `alphaViewAsyncProjection` exposes the async projection name.

6. **Systematic unused imports break `-Wall`.** Fixed import blocks are emitted regardless of
   use. Verified: `Journey/Domain.hs` imports `fromGregorian`, `picosecondsToDiffTime`, and the
   `UTCTime(..)` constructors while using only the `UTCTime` type; `Journey/Codec.hs` imports
   both `Data.Map.Strict` lines and `withText` with zero uses (fixed block in `emitCodec`,
   `Scaffold.hs:4082–4106`); `Nominals.hs` imports `FromJSON`, `ToJSON`, `Text`, `Generic`,
   `idDomainTextPattern`, `typeIdV7Domain` while its body is one instance;
   `StructuralProjections.hs` imports `UTCTime` and `Natural` that appear only in a comment
   (emitter comment at `Scaffold.hs:2128`); Alpha `Domain.hs` imports `Proxy (..)`, `Text`, and
   `parseProofId` unused; Journey `Harness.hs` imports the `RequestId` type unused.
   `behavior-complete-report.cabal:30` sets `-Wall`, and every in-repo conformance suite imports
   the `-Wall` `warnings` stanza, so this is warning spam everywhere and blocks any consumer
   from adopting `-Werror`.

Batched minors, verified: the unreadable one-line optional-field parser repeated per field
(fixture `Codec.hs:56`; emitted via the `onOptional` algebra case at `Scaffold.hs:4725`);
numbered qualified aliases `Harness0`–`Harness4` in the facade
(`.../Generated/Conformance.hs:7–11`; `aliasFor` at
`keiro-dsl/src/Keiro/Dsl/ServiceHarness.hs:90–91`); the vacuous always-`True` assertion
`("clock-free: spec samples no wall clock", True)` (fixture `Harness.hs:35`; baked at
`keiro-dsl/src/Keiro/Dsl/Harness.hs:467,502`); the empty `Projection` module emitted with no
explanation (`module ....Projection () where`, `Scaffold.hs:5793`); the uncurated
BehaviorContract export; and cabal warning-flag disparity — `behavior-complete-report.cabal` has
`-Wall`, while `keiro-dsl-conformance-service-runtime.cabal` and the generated
`keiro-workspace-proof-conformance.cabal` (rendered by `renderCabal`,
`keiro-dsl/src/Keiro/Dsl/ConformancePackage.hs:197–217`) have none.

Hard constraints. BehaviorKey bytes, fold fingerprints (pinned by
`keiro-dsl/test/fixtures/fold-identity-baseline.golden`), wire bytes, read-model shape hashes,
and behavior-conformance semantics are frozen. Fold fingerprints derive from the checked semantic
graph, not module text, so emitter-presentation changes cannot move them — but the plan still
proves it. Existing filled witness modules must keep compiling: they consume only exported data
constructors (verified for
`keiro-dsl/test/conformance-behavior-complete/BehaviorComplete/Journey/BehaviorHoles.hs` and all
nine other committed `BehaviorHoles.hs` fills), so the curated export list must export all
contract data types with constructors and selectors plus the report API, and may hide only the
runner internals. Create-once discipline: emitter changes to `emitBehaviorHoles` affect only
newly scaffolded stubs; committed hand-owned files are updated deliberately by hand where this
plan says so, never overwritten by tooling. The committed skeleton `HoleStub` fixtures under
`keiro-dsl/test/conformance-skeletons/` exist precisely to pin stub output, so refreshing them is
a deliberate fixture update, not a create-once violation.

Relevant local ADRs, read for this plan:

- [ADR 0017](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
  defines the finite behavior inventory, `BehaviorHoles` as the create-once witness list, and
  exact detailed edge attribution. This plan changes its presentation, not its semantics, and
  amends it with the evidence-carrying rendering paragraph.
- [ADR 0019](../adr/0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md)
  fixes the compilation contract (GHC2024 + `OverloadedStrings`, a closed local extension set
  rendered through one typed renderer with semantic predicates). The `OverloadedRecordDot`
  addition to `ReadModelHarness` and all conditional-import predicates follow its pattern; the
  dropped `OPTIONS_GHC` warning suppression was never part of its closed set. Amended with the
  no-suppression/complete-signature sentence.
- [ADR 0020](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md)
  defines the single facade and create-once expectations. The alias rename changes only facade
  internals; the facade's exported API (`runServiceConformanceChecks`,
  `serviceConformanceFacts`) is unchanged.
- [ADR 0015](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
  defines overwriteable-versus-create-once and detection-before-write; the Milestone 4 refresh
  obeys it through EP-195's tool.
- [ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) is
  context for why no new diagnostics are added here: nothing in this plan changes what is
  accepted or refused.

No cross-repository ADR is relevant. The runtime dependency is
`mori://shinzui/keiki/packages/keiki` (unchanged: the contract module continues to use
`stepDetailedEither`, `applyEventsDetailedEither`, `EdgeRef`, and derived `Show` instances; no
Keiki bound or semantics change).


## Plan of Work

### Milestone 1: BehaviorContract reads like reviewed code and fails with evidence

Scope: `emitBehaviorContract`, `renderBehaviorRequirementList`, and `emitBehaviorHoles` in
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (region ~2270–2700). At the end, a freshly scaffolded
`BehaviorContract.hs` compiles warning-free under `-Wall` with no `OPTIONS_GHC` pragma, exports a
curated list, names every requirement's cell inline, and produces failures that identify the
construct and show values.

First, signatures and shadowing. Emit an explicit type signature for each of the fifteen
currently unsigned bindings (`runRejection`, `runAcceptance`, `checkAcceptedEnvelope`,
`checkSingleAttribution`, `settleHistory`, `commandKind`, `eventKind`, `proofStrength`,
`behaviorWitnessKey`, `isPending`, `ensure`, `failure`, `sortedKeys`, `keyTexts`, `countLine`;
exact types are in Interfaces and Dependencies). Rename every binder that shadows the `failure`
helper — the `ToJSON BehaviorFailure` instance argument and the two comprehension binders — to
`behaviorFailure`. Then delete the emitted line
`{-# OPTIONS_GHC -Wno-missing-signatures -Wno-name-shadowing #-}` (`Scaffold.hs:2295`) entirely.

Second, the curated export list. Replace `module <Prefix>.BehaviorContract where` with an
explicit export list containing exactly: `BehaviorKey (..)`, `ObligationKind (..)`,
`EvidenceLevel (..)`, `GuardCoverage (..)`, `BehaviorRequirement (..)`, `RejectionClass (..)`,
`LiveExpectation (..)`, `BehaviorWitness (..)`, `BehaviorFailure (..)`,
`BehaviorConformanceReport (..)`, `behaviorRequirements`, `behaviorCoverageReport`,
`behaviorConformancePassed`, `behaviorConformancePassedWith`, and
`renderBehaviorConformanceText`. This is the full surface consumed by filled witness modules and
suite drivers (verified — see Surprises & Discoveries); the runner internals become private,
which also lets GHC's `-Wall` report any future dead internal helper.

Third, annotated requirement rows in record syntax. Rewrite `render` inside
`renderBehaviorRequirementList` to emit record syntax with a trailing comment naming the cell.
Keep the hash-sorted order and exact key bytes. Target shape (one requirement, from the
behavior-complete fixture):

```haskell
  [ -- JourneyClosed x Ping: required rejection (spec line 21)
    BehaviorRequirement
      { requirementKey = BehaviorKey "behavior-v1-2e1fd6b9580e1a3d"
      , requirementKind = RequiredRejection
      , requirementEvidence = GeneratedAuthoritative
      , requirementGuardCoverage = GuardNotApplicable
      , requirementSource = JourneyClosed
      , requirementCommandName = "Ping"
      , requirementExpectedEdge = Nothing
      , requirementTarget = Nothing
      , requirementEventKinds = []
      , requirementLine = 21
      }
  , ...
  ]
```

The comment text is `<SourceVertexCtor> x <Command>: <kind phrase> (spec line <n>)` where the
kind phrase is `live transition`, `required rejection`, or `replay-only transition`, all derived
from the `Behavior.BehaviorRequirement` fields already in scope. The comment must not contain the
substrings `undefined` or `error` (a fixture test asserts their absence in the stub module).
Apply the same trailing comment to every `Pending` row in `emitBehaviorHoles`:

```haskell
  [ Pending (BehaviorKey "behavior-v1-e2c1eef1cb7848f5") -- AlphaActive x PingAlpha: live transition (spec line 12)
  ]
```

The `Pending (BehaviorKey "` prefix text is pinned by `T.count` in a test
(`keiro-dsl/test/Main.hs`, near line 1454, count 14); trailing comments keep that pin valid.

Fourth, evidence-carrying failures. Add `failureSubject :: !Text` to the emitted
`BehaviorFailure` record between `failureKey` and `failureCode`. The `failure` helper takes the
requirement (it already does) and builds the subject with the same cell phrase as the row
comment, for example `JourneyActive x Decide: live transition (spec line 41)`. Render it in
`renderBehaviorConformanceText` as `FAIL <key> <subject> [<code>] <detail>` and in the `ToJSON`
instance as an additional `"subject"` key. Then enrich `failureDetail` at every comparison of two
showable values so the message carries both sides, using the existing `tshow` helper:
`event-value-mismatch` shows `actual=<show actual> expected=<show expected>`;
`event-envelope-mismatch` shows both kind lists; `edge-attribution`, `target-mismatch`,
`forward-mode`, the four replay-attribution checks, and `replay-span-attribution` each show the
runtime value and the required value; `rejection-class` already names both sides in prose and
needs no change. Do not change any failure `code` string: codes are the stable machine surface.

Fifth, update the focused pins in `keiro-dsl/test/Main.hs` that assert emitted contract/stub text
(at minimum the `commandKind ...` infix pin near line 1453 if the line's rendering changed, and
add new pins: the contract contains no `OPTIONS_GHC`, contains `failureSubject`, contains a
record-syntax requirement row, and the stub contains an annotated `Pending` row).

Acceptance: `nix develop -c cabal test keiro-dsl-test --test-options='--match "behavior"'`
passes; scaffolding the behavior-complete fixture into a disposable directory produces a
`BehaviorContract.hs` with signatures on every top-level binding, no `OPTIONS_GHC` line, a
curated export list, and annotated record rows. Committed-corpus byte-identity tests are expected
to fail until Milestone 4 and are not part of this milestone's gate.

### Milestone 2: Harness constants, honest facts, and the batched minors

Scope: `keiro-dsl/src/Keiro/Dsl/Harness.hs` (sample synthesis and assertion list, `emitHarness`
region 451–545, declarations 648–776, `emitReadModelHarness` 180–219),
`generatedIdSampleHaskell` in `Scaffold.hs:5254`, the `AggregateTime` sample in
`AggregateType.hs:298`, the codec optional-field rendering near `Scaffold.hs:4725`, `aliasFor` in
`ServiceHarness.hs:90`, and the empty-Projection line at `Scaffold.hs:5793`.

Sample constants: in `emitHarness`, collect the distinct generated-ID nominal types and the
`Time` type used by any emitted sample site (event samples, acceptance probes, forward/replay
probes, mapped round-trip rows). Emit one constant per distinct type at the top of the
declarations region:

```haskell
sampleRequestId :: RequestId
sampleRequestId =
  case parseRequestId "req_01h455vb4pex5vsknk084sn02q" of
    Right parsed -> parsed
    Left problem -> error (show problem)

sampleObservedAt :: UTCTime
sampleObservedAt = UTCTime (fromGregorian 2026 1 2) (picosecondsToDiffTime 11045123456789012)
```

Change `generatedIdSampleHaskell` (or add a constant-aware variant used by the harness path) and
the `AggregateTime` case of `sampleValue` so every use site references the constant instead of
splicing the expression. The `Left _` swallow is replaced by `Left problem -> error (show
problem)` in the constant (this mirrors the hand-owned fill in
`BehaviorComplete/Journey/BehaviorHoles.hs:69–71`, which already does exactly this). Note the
non-harness use of `generatedIdSampleHaskell` at `Scaffold.hs:3982` (register initial values in
the Domain module) stays expression-based — Domain cannot import Harness — and is out of scope.
If EP-191's generated-helper occurrence inventory (its Milestone 2) has landed, register the new
constant names there so a spec-declared collision is refused before writes.

Parenthesis cleanup: `ctorExpr` and `commandCtorExpr` keep their inner data parentheses but stop
wrapping the entire constructor application, and `acceptDecl`/`forwardReplayDecl` stop adding a
second wrap, so output reads `sampleEventStarted = Started (StartedData sampleRequestId
sampleObservedAt 0 ...)` and `case step journeyTransducer (JourneyEmpty, initialJourneyRegs)
(Start (StartData ...)) of`. Preserve exactly one paren layer where the expression is an
argument.

Clock-free honesty: in the assertion list, when `specIsClockFree` is `True` emit a comment line
`-- clock-free: spec samples no wall clock (verified at scaffold time)` instead of the
constant-`True` row; when `False`, keep the failing assertion row unchanged.

Read-model facts: rewrite `emitReadModelHarness` so the actual column comes from the runtime
value. The module imports the sibling generated `ReadModel` module (same generated prefix) and
renders, with `{-# LANGUAGE OverloadedRecordDot #-}` (in ADR 0019's closed local set):

```haskell
readModelFacts :: [(String, String, String)]
readModelFacts =
  [ ("registryName", "workspace-proof-alpha-view", T.unpack alphaViewReadModel.name)
  , ("subscriptionName", "workspace-proof-alpha-view-sub", T.unpack alphaViewReadModel.subscriptionName)
  , ("shapeHash", "fnv1a:ebb780a44ff297c1", T.unpack alphaViewReadModel.shapeHash)
  , ("asyncProjectionName", "workspace-proof-alpha-view-async", T.unpack alphaViewAsyncProjection.name)
  , ("consistency", "Eventual", show alphaViewReadModel.defaultConsistency)
  , ("strongScope", "EntireLog", show alphaViewReadModel.strongScope)
  ]
```

The expected column stays notation-derived exactly as today; only the actual column changes, so
notation-versus-runtime drift becomes a failing fact. For an inline-feed read model (no async
projection value) keep the literal `"none"` on both sides and add a trailing comment that the row
is definitionally inert. Keep `runReadModelFacts` and `readModelFactResults` unchanged in shape
(consumers verified in Surprises & Discoveries). This adds imports of `Data.Text qualified as T`
and the generated `ReadModel` module; every compiling component already contains both
dependencies.

Codec optional-field helper: replace the per-field one-liner (fixture `Codec.hs:56`) with one
shared local helper emitted once per Codec module that has optional structural fields, and a
readable per-field call:

```haskell
    <*> parseOptionalField parseJSON objectValue "optional_note"

parseOptionalField :: (Value -> Parser fieldValue) -> KeyMap.KeyMap Value -> Key.Key -> Parser (Maybe fieldValue)
parseOptionalField parseItem objectValue key =
  case KeyMap.lookup key objectValue of
    Nothing -> pure Nothing
    Just _ -> explicitParseField (\value -> case value of Null -> pure Nothing; other -> Just <$> parseItem other) objectValue key
```

(The exact signature may follow local style; the requirement is one named helper, wire semantics
byte-identical: absent key decodes `Nothing`, explicit `Null` decodes `Nothing`, present value
decodes `Just`.)

Facade aliases: replace `aliasFor :: Int -> Text` in `ServiceHarness.hs` with an alias derived
from the node identity used by `harnessModuleName` (aggregate name, pascal read-model name,
process/router/workflow id) — producing `import ... qualified as Alpha`, `AlphaView`,
`WorkspaceProofWorkflow` — with a deterministic `<Alias><n>` suffix fallback only on
normalization collision. Update the facade text pin at `keiro-dsl/test/Main.hs:4816` and any
sibling pins.

Empty Projection module: append one comment to the `Nothing` branch at `Scaffold.hs:5793`, for
example `-- No projection declarations in the spec; this module exists so the manifest module
list is total.` (match the actual reason given by the surrounding emitter).

Acceptance: focused emitter tests pass
(`--match "harness"`, `--match "read-model"`, `--match "service conformance facade"` — use the
real Hspec descriptions and record them in Progress); a disposable scaffold of the
behavior-complete fixture and of the service workspace shows named constants used at every former
splice site, no doubled parens, the comment-form clock-free line, runtime-backed fact rows, the
shared optional-field helper, and node-named facade aliases.

### Milestone 3: usage-conditional imports and warning parity

Scope: the fixed import blocks in every generated module family — `emitCodec`
(`Scaffold.hs:4082–4106`), the Domain static/time imports (`domainStaticImports` and the
time-import emission near `domainImportPlan`), the Nominals module emitter (region
~`Scaffold.hs:1600–1800`), `emitNominalProjections`/StructuralProjections (region ~2100),
`emitHarness` imports (`Harness.hs:510–545`), and any other family the warning sweep implicates —
plus cabal warning parity.

Mechanism: follow ADR 0019's established pattern — a semantic predicate beside each emitter
decides each conditional import, exactly as `codecUsesRecordDot` already gates a pragma. The
`HaskellImport` planner already handles consumer-reference imports correctly; this milestone does
not migrate the static blocks onto the planner (that migration is the deferred "import-planner
adoption in integration emitters" item named out of scope by MasterPlan 29) — it makes the static
blocks honest. Concretely, from the verified findings: import `withText` and the two
`Data.Map.Strict` lines in Codec only when the emitted body uses them (in the current corpus,
never); split Domain's time import into `Data.Time.Clock (UTCTime)` for field types and add
`UTCTime (..)`/`fromGregorian`/`picosecondsToDiffTime` only when an emitted expression in that
module needs them; emit Nominals' `FromJSON`/`ToJSON`/`Text`/`Generic`/IdDomain imports only for
the representation cases that use them; derive StructuralProjections' scalar-type imports from
the witness result types actually emitted rather than the fixed five-type set (and keep the
explanatory comment, which is why `UTCTime`/`Natural` appeared unused); prune Alpha-style
Domain's `Proxy (..)`/`Text`/`parse<Id>` to actual use; prune Harness's nominal type imports to
referenced names (after Milestone 2, `RequestId` is referenced by `sampleRequestId`'s
signature).

The oracle is the compiler, not a hand list: iterate by scaffolding every fixture through the
ordinary generator tests and building the corpus until the build log carries zero warnings for
generated modules. Do not add `-Wno-*` anywhere; fix emission.

One committed module escapes that oracle today: EP-195's corpus inventory
(`docs/plans/195-build-conformance-corpus-regeneration-tooling.md`, Surprises & Discoveries)
found that the structural tree's generated
`Generated.StructuralConformance.ArtifactCatalog.BehaviorContract` is compiled by no cabal
component, so its warnings are invisible and its bytes are pinned only by the regeneration
tool. This milestone closes that hole: add the module to the `other-modules` of the cabal
component that compiles the rest of its tree (or, if a deliberate reason not to compile it
emerges, record that reason in the Decision Log and have EP-195's cabal-inventory checker carry
an explicit named exemption instead of a silent one). The compile-everything default is what
makes the zero-warning acceptance meaningful.

Warning parity: add `ghc-options: -Wall` to the test-suite stanza rendered by `renderCabal` in
`ConformancePackage.hs`, and by hand to the committed
`keiro-dsl/test/conformance-service-package/runtime/keiro-dsl-conformance-service-runtime.cabal`
(a consumer-side, hand-owned file — deliberate edit). `behavior-complete-report.cabal` already
has `-Wall`. Per the Decision Log, no `-Werror` in generated output.

Acceptance (final proof deferred to Milestone 4's regenerated corpus, but checkable now against
disposable scaffolds): compiling a freshly scaffolded behavior-complete tree and service-package
tree with `-Wall` produces zero warnings; the focused generator tests that pin import lines are
updated and pass.

### Milestone 4: one corpus regeneration, deliberate hand updates, and closure

Regenerate every committed conformance fixture exactly once through EP-195's regeneration tool
(`docs/plans/195-build-conformance-corpus-regeneration-tooling.md`; that plan's Interfaces
section defines the invocation — this plan intentionally does not restate a CLI that EP-195
owns). The tool overwrites only banner-recognized generated files, preserves create-once modules,
and reconciles `keiro-dsl/keiro-dsl.cabal` module inventories. Review the diff: it must contain
only presentation changes — signatures, comments, record syntax, constants, import lines, alias
names, cabal `ghc-options` — and no change to any `behavior-v1-` key string, wire tag, shape
hash, or fold baseline.

Deliberate hand updates, each an explicit edit reviewed on its own: the committed skeleton
`HoleStub` fixtures under `keiro-dsl/test/conformance-skeletons/` (they pin stub output and must
match the new annotated-`Pending` form); the runtime cabal `-Wall` addition from Milestone 3;
and, optionally and clearly labeled as such, trailing cell comments on the already-filled
committed `BehaviorHoles.hs` witness rows (hand-owned files; annotate only where it aids the
demonstration — this is not required for any test to pass). Do not let any tool rewrite a
create-once file.

Produce the demonstration failure transcript: deliberately break one filled witness in
`keiro-dsl/test/conformance-behavior-complete/BehaviorComplete/Journey/BehaviorHoles.hs` (for
example, change `live "behavior-v1-2f3ebf37a55781db" activeHistory (decideCommand 5) (Emits
(decisionEvent 5 :| []))` to expect `decisionEvent 6`), run the report, capture the failure line
showing subject and actual/expected, and restore the witness exactly. The transcript goes into
this plan's Outcomes & Retrospective and the user documentation.

Documentation and ADRs: amend ADR 0017 and ADR 0019 per the Decision Log (and `docs/adr/log.md`);
run strict OKF validation on the bundle. Update the behavior-conformance discussion in
`docs/user/typed-spec-toolchain.md` (the aggregate behavior/witness sections) to show the
annotated stub and an evidence-carrying failure line. Add entries to `CHANGELOG.md` and
`keiro-dsl/CHANGELOG.md` under Unreleased describing the presentation changes, the new
`failureSubject`/JSON `subject` field, and the regeneration note for consumers (re-scaffold and
recompile; no wire, key, or replay change). Close with the full validation battery in Concrete
Steps.

After the reviewed refresh is committed, finish EP-195's deferred policy surface: implement
`keiro-dsl-corpus-regen check` as a clean-tree preflight plus full regeneration and zero-diff
assertion; add `scripts/check-conformance-corpus.sh`; add `corpus-regen` and
`conformance-corpus-policy` Justfile recipes; append the policy recipe to `verify`. Prove the
gate refuses a pre-dirtied corpus before scaffolding and passes from the clean refreshed
baseline with `conformance corpus: ok`.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/keiro`. Baseline before edits:

```console
$ nix develop -c cabal test keiro-dsl-test --test-options='--match "behavior"'
...
0 failures

$ nix develop -c cabal build all 2>&1 | grep -c 'warning:'
<nonzero — record this count as the before-figure>
```

During Milestones 1–3, after each emitter change run the focused suites (substitute the final
Hspec descriptions and record them in Progress):

```console
$ nix develop -c cabal test keiro-dsl-test --test-options='--match "behavior"'
0 failures

$ nix develop -c cabal test keiro-dsl-test --test-options='--match "harness"'
0 failures
```

Inspect output with the public scaffolder in a disposable directory (never hand-edit committed
fixtures mid-milestone):

```console
$ proof_dir=$(mktemp -d)
$ nix develop -c cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/behavior-complete.keiro --out "$proof_dir"
$ rg -n 'OPTIONS_GHC|failureSubject|sampleRequestId|sampleObservedAt|-- Journey' "$proof_dir"/Generated/BehaviorComplete/Journey/BehaviorContract.hs "$proof_dir"/Generated/BehaviorComplete/Journey/Harness.hs
```

Expect: no `OPTIONS_GHC` match, `failureSubject` present, both constants declared once and
referenced at every former splice site, and cell comments on requirement rows. Remove only the
explicitly created disposable directory afterward.

In Milestone 4, regenerate the corpus once via EP-195's tool (invocation per that plan's
Interfaces section), then prove identity freezes before reviewing the rest of the diff:

```console
$ git diff -U0 -- 'keiro-dsl/test/conformance*' | grep -E '^[-+].*behavior-v1-' \
    | grep -oE 'behavior-v1-[0-9a-f]{16}' | sort | uniq -c | awk '$1 % 2 != 0' | wc -l
0

$ git diff --stat -- keiro-dsl/test/fixtures/fold-identity-baseline.golden
<no output — the fold baseline is untouched>

$ git diff -U0 -- 'keiro-dsl/test/conformance*' | grep -E '^[-+].*(fnv1a:|"kind" \.=|EventType ")' | head
<only context-free moves; no changed hash or tag values>
```

(The first command checks every added/removed line's key strings pair up — each key appears an
even number of times across `-`/`+` lines, meaning no key was introduced or retired.)

Demonstration failure transcript (Milestone 4): apply the deliberate witness mutation described
in Plan of Work, then:

```console
$ nix develop -c cabal run keiro-dsl-behavior-complete-report
behavior conformance: Journey
...
failed: 1
FAIL behavior-v1-2f3ebf37a55781db JourneyActive x Decide: live transition (spec line 41) [event-value-mismatch] runtime event values differ from the exact witness expectation; actual=[DecisionRecorded (DecisionRecordedData 5)] expected=[DecisionRecorded (DecisionRecordedData 6)]
$ git checkout -- keiro-dsl/test/conformance-behavior-complete/BehaviorComplete/Journey/BehaviorHoles.hs
```

(Exact wording will match the implemented renderer; the required content is key, subject with
state × command × kind × spec line, code, and both values.)

Full closure after documentation:

```console
$ nix develop -c cabal test keiro-dsl
All ... test suites passed

$ nix develop -c cabal build all 2>&1 | tee /tmp/keiro-build.log | grep -c 'warning:'
0

$ nix develop -c cabal test keiro-dsl-conformance-behavior-complete
Test suite keiro-dsl-conformance-behavior-complete: PASS

$ nix develop -c cabal test keiro-workspace-proof-conformance
Test suite conformance: PASS

$ scripts/check-extension-policy.sh
extension policy: ok

$ scripts/check-generated-name-policy.sh
generated Haskell naming policy: OK

$ scripts/check-conformance-corpus.sh
conformance corpus: ok

$ nix develop -c just conformance-corpus-policy
conformance corpus: ok

$ okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
validation succeeded

$ git diff --check
```

If the warning count is nonzero, every remaining `warning:` line must be shown to originate
outside generated conformance modules (for example GHC notes about the library itself); the
target for generated modules is exactly zero. Update the transcripts above with real output as
work proceeds.


## Validation and Acceptance

Acceptance is behavioral:

1. Breaking one filled behavior witness and running the report prints a failure line naming the
   state × command cell, the obligation kind, the spec line, and both the actual and expected
   values (transcript captured in this plan); restoring the witness returns the report to
   `failed: 0`. The JSON report (`--format=json`) carries the same evidence under a `subject`
   key while remaining schema `keiro/behavior-conformance/1`.
2. A freshly scaffolded `BehaviorContract.hs` has a type signature on every top-level binding,
   no `OPTIONS_GHC` pragma, a curated export list, record-syntax requirement rows each carrying
   a cell comment, and hash-sorted order with byte-identical `BehaviorKey` strings. A freshly
   scaffolded `BehaviorHoles.hs` stub annotates every `Pending` row; the stub still contains 14
   `Pending (BehaviorKey ` occurrences for the behavior-complete fixture and no `undefined` or
   `error` substring.
3. A freshly scaffolded `Harness.hs` declares each sample constant once, references it at every
   probe and round-trip site, contains no doubled parentheses around constructor applications,
   and renders the clock-free result as a comment (spec is clock-free) rather than a `True`
   assertion; the assertion count visible to drivers is otherwise unchanged.
4. Editing a generated read-model notation value (temporarily mutating the expected literal in a
   disposable scaffold) makes the corresponding fact row fail, proving the actual column now
   comes from the runtime record; the committed corpus's fact rows all pass.
5. `cabal build all` compiles the entire committed corpus with zero warnings attributable to
   generated modules, with `-Wall` in force in the repo suites (existing `warnings` stanza), in
   `behavior-complete-report.cabal`, in the committed runtime cabal, and in the regenerated
   conformance-package cabal — with no `-Wno-*` and no `-Werror` in generated output.
6. All committed conformance suites pass: `cabal test keiro-dsl` (37 components including the
   byte-identity pins against the regenerated trees), `keiro-dsl-conformance-behavior-complete`,
   and `keiro-workspace-proof-conformance`. Existing filled witness modules compile unmodified
   (except optionally annotated comments) against the curated export list.
7. Frozen identities: the fold baseline golden is byte-identical; the behavior-key extraction
   over the corpus diff shows no key added or removed; no wire tag, payload key, shape hash, or
   snapshot discriminator changes; behavior conformance passes with the same witness values as
   before.
8. All three generated-source/corpus policy scripts, strict OKF ADR validation (after the
   0017/0019 amendments), and `git diff --check` pass; changelogs and user docs updated.
   `just verify` includes the conformance-corpus policy, which refuses pre-dirty corpus paths
   before scaffolding and passes with `conformance corpus: ok` on the refreshed clean tree.


## Idempotence and Recovery

Every emitter change is a pure function of the checked spec, so disposable-directory scaffolds
and focused tests can be repeated freely. The Milestone 4 regeneration is idempotent by EP-195's
own acceptance (a second clean-tree run produces no diff); if it fails midway, the tool's
detection-before-write and provenance checks make a rerun safe, and `git checkout --` restores
any reviewed-and-rejected fixture. Never regenerate into the committed tree before Milestones
1–3 are complete — that would spend the corpus churn twice. Create-once files are only ever
edited by hand with explicit diffs; if one is accidentally overwritten, restore it from git
before continuing. The demonstration mutation is restored with a single `git checkout --` shown
in Concrete Steps. The plan touches no database, network, or persisted wire format; backing out
is reverting the changed source and fixture files by explicit patch, never a worktree reset.


## Interfaces and Dependencies

The emitted BehaviorContract gains one field and renders one new key; the module's emitted
signatures are (specialized per aggregate, shown for Journey):

```haskell
data BehaviorFailure = BehaviorFailure
  { failureKey :: !BehaviorKey
  , failureSubject :: !Text
  , failureCode :: !Text
  , failureDetail :: !Text
  }

runRejection :: BehaviorRequirement -> (JourneyVertex, K.RegFile JourneyRegs) -> JourneyCommand -> LiveExpectation -> Either BehaviorFailure ()
runAcceptance :: BehaviorRequirement -> (JourneyVertex, K.RegFile JourneyRegs) -> JourneyCommand -> LiveExpectation -> Either BehaviorFailure ()
checkAcceptedEnvelope :: BehaviorRequirement -> K.StepSuccess JourneyVertex JourneyRegs JourneyEvent -> Either BehaviorFailure ()
checkSingleAttribution :: BehaviorRequirement -> K.EdgeMode -> Int -> [K.ReplayAttribution JourneyVertex] -> Either BehaviorFailure ()
settleHistory :: BehaviorRequirement -> Text -> [JourneyEvent] -> Either BehaviorFailure (K.ReplaySuccess JourneyVertex JourneyRegs)
commandKind :: JourneyCommand -> Text
eventKind :: JourneyEvent -> Text
proofStrength :: BehaviorRequirement -> Bool
behaviorWitnessKey :: BehaviorWitness -> BehaviorKey
isPending :: BehaviorWitness -> Bool
ensure :: BehaviorRequirement -> Bool -> Text -> Text -> Either BehaviorFailure ()
failure :: BehaviorRequirement -> Text -> Text -> Either BehaviorFailure failed
sortedKeys :: [BehaviorKey] -> [BehaviorKey]
keyTexts :: [BehaviorKey] -> [Text]
countLine :: Text -> [BehaviorKey] -> Text
```

(Take the exact Keiki result types from the expressions already emitted — the signatures must
match what GHC infers today; derive them by compiling a disposable scaffold with
`-Wmissing-signatures` and copying the reported types. `failure`'s polymorphic result is what
allows its use in both `Either` positions.) The export list is the fifteen-entry curated surface
named in Milestone 1. Emitted Harness modules gain `sample<IdType> :: <IdType>` per generated ID
nominal in use and `sampleObservedAt :: UTCTime` when `Time` samples are used. Emitted
ReadModelHarness modules keep the exported triple
`readModelFacts :: [(String, String, String)]`,
`readModelFactResults :: [(String, Bool)]`, `runReadModelFacts :: IO Bool` and additionally
import the sibling generated `ReadModel` module with `OverloadedRecordDot`.

Inside keiro-dsl: `Keiro.Dsl.ServiceHarness.aliasFor` is replaced by an identity-derived
`aliasForNode :: Context -> Node -> Text` (or equivalent) with a deterministic collision suffix;
`Keiro.Dsl.ConformancePackage.renderCabal` adds `ghc-options: -Wall` to its test-suite stanza;
conditional-import predicates live beside their emitters in `Keiro.Dsl.Scaffold` and
`Keiro.Dsl.Harness` following the `codecUsesRecordDot` pattern. No public keiro-dsl library API
changes; no `DiagnosticCode` is added.

Dependencies: the generated code continues to target `mori://shinzui/keiki/packages/keiki`
(derived `Show` on step/replay types is the only capability the enriched failures rely on, and it
already exists) and the in-repo `keiro` runtime library (`Keiro.ReadModel` record fields and
`Show` instances for `ConsistencyMode`/`StrongScope`, verified at
`keiro/src/Keiro/ReadModel.hs:90–140`). Regeneration tooling comes from EP-195
(`docs/plans/195-build-conformance-corpus-regeneration-tooling.md`); the merged emitters this
plan starts from come from EP-191 and EP-192 as described in Context and Orientation. No
dependency bounds change.


---

Revision note (2026-08-04): Added the uncompiled structural `BehaviorContract` module to
Milestone 3's scope. EP-195's corpus inventory (drafted in parallel) discovered that
`Generated.StructuralConformance.ArtifactCatalog.BehaviorContract` is compiled by no cabal
component, which would let it escape this plan's zero-warning oracle; Milestone 3 now compiles it
or records a named exemption in EP-195's checker.

Revision note (2026-08-05): EP-195's complete replay exposed and restored 387 files of
pre-existing drift, so its clean-tree `check`/script/Justfile/`verify` activation moves into this
plan's Milestone 4 immediately after the already-planned single corpus refresh. EP-195's working
regeneration, provenance, Cabal-closure, and golden tooling is complete and satisfies this plan's
hard dependency without landing a knowingly red gate.
