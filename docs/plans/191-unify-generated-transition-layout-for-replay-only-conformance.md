---
id: 191
slug: unify-generated-transition-layout-for-replay-only-conformance
title: "Unify generated transition layout for replay-only conformance"
kind: exec-plan
created_at: 2026-08-05T04:18:27Z
intention: "intention_01kz84b5jre3187dmmyjmd02fc"
master_plan: "docs/masterplans/29-stabilize-keiro-dsl-for-wide-adoption.md"
---

# Unify generated transition layout for replay-only conformance

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro DSL currently accepts a historical first-event edge in `ReplayOnly` mode, but its generated
aggregate harness mistakes that edge for a live command path. A live and replay-only initial edge
for the same command therefore generate the same top-level `acceptStart` declaration twice, while
a replay-only-only command receives an acceptance probe that must fail. Separately, generated
predicate verification restarts edge numbering when transitions from one source appear in later,
non-contiguous source blocks even though Keiki appends those edges to the source's existing edge
list.

After this work, one checked transition layout determines declaration identity, source-wide edge
identity, runtime rendering, predicate verification, behavior requirements, and initial-state
harness probes. Only `Live` initial transitions receive `step`-based acceptance and forward/replay
probes. Every replay-only transition remains present in the generated transducer and receives its
finite `ReplayWitness` requirement with the same `EdgeRef` that Keiki reports at runtime.

The result is visible in the behavior-complete fixture and its workspace twin. They will contain a
live initial `Start`, an intervening transition from another source, a replay-only initial `Start`
sibling, and a replay-only initial legacy command without a live sibling. Generated Haskell will
compile with exactly one `acceptStart`, no live acceptance helper for the legacy-only command, one
source block for the initial vertex, and replay requirements attributed to cumulative initial-edge
indices 1 and 2. The committed whole-service conformance package will also carry the shape and
pass without a runtime-only transducer composition.


## Progress

- [x] (2026-08-04 21:18 PDT) Validate IR-18 against the Keiro DSL generator, behavior coverage,
  workspace/service conformance, Keiki builder semantics, and Mori's legacy empty-start
  reproducer; create this plan under Intention
  `intention_01kz823p0keghtca7kdkm13k1r`.
- [x] (2026-08-05 00:42 PDT) Add one source-wide transition layout and route transducer rendering,
  predicate edge verification, behavior edge lookup, legacy Hole grouping, declaration-index
  consumers, and live initial probes through it. Focused source-wide layout test: 1 example,
  0 failures; `cabal build keiro-dsl` passes.
- [x] (2026-08-05 00:48 PDT) Extend generated-name planning and the final lexical audit so
  duplicate generated declarations are refused before writes with useful source evidence.
  Focused semantic-collision and repeated-signature tests: 2 examples, 0 failures.
- [x] (2026-08-05 07:23 PDT) Add and fill initial replay-only single-spec, workspace, and
  whole-service conformance evidence, including same-command and replay-only-only initial edges.
  The behavior contract is 19/19 filled (17 executed, 2 intentionally unverified rejection
  cells); the 9-example behavior suite, generated behavior component, 29-fact workspace package,
  fold-identity suite, public-CLI idempotence proof, and all mutation cases pass.
- [ ] Publish the invariant in the relevant ADRs and user documentation, update changelogs, and
  pass focused, package-wide, repository-wide, policy, and strict documentation validation.


## Surprises & Discoveries

- Observation: Keiki intentionally accepts repeated `from` blocks and merges every block for the
  same vertex in declaration order before assigning zero-based outgoing-edge indices. Keiro's
  generated runtime is therefore semantically ordered source-wide even when its renderer emits
  multiple source blocks.
  Evidence: `Keiki.Builder.buildTransducerEither` in
  `mori://shinzui/keiki/packages/keiki` folds `mergeEntry` over declaration-ordered entries and
  appends duplicate-source edges before `zipWith` assigns indices.

- Observation: Generated behavior requirements already include every replay-only transition and
  `behaviorEdgeIndex` already computes its index from the complete source-filtered transition
  list. The mismatch is localized: `groupTransitionEntriesBySource` groups adjacent runs and
  `renderVerificationList` numbers each run from zero, while `Harness.initialTransitions` ignores
  mode for acceptance helpers.
  Evidence: `keiro-dsl/src/Keiro/Dsl/BehaviorCoverage.hs`,
  `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, and `keiro-dsl/src/Keiro/Dsl/Harness.hs`.

- Observation: Mori has two independent temporary adaptations. Keiki 0.9.0.0 makes the narrowed
  inversion-validation policy obsolete, but Mori's separately composed replay-only initial edge
  remains necessary until Keiro can generate this layout correctly.
  Evidence: `Mori.Modules.Workflow.Domain.Transducer` in
  `mori://shinzui/mori/packages/mori-core` defines both `workflowValidationOptions` and
  `legacyEmptyStartTransducer`; only the former is superseded by
  `mori://shinzui/keiki/okf/improvement-requests/concepts/IR-5`.

- Observation: Generated harness samples are deterministic type defaults, not values solved from
  transition guards. The initial live guard therefore has to admit `Natural` zero (and the Alpha
  service proof has to admit `Bool` false) for its compiled live acceptance probe to be meaningful.
  Evidence: Orienting the complementary guards the other way made the generated `acceptStart` and
  `acceptPingAlpha` probes fail even though the layout itself was correct; reversing the guards
  around the generated defaults makes the live and replay witnesses select distinct edges.

- Observation: A workspace member's source line is relocated during composition, so the single
  and workspace `BehaviorContract.hs` files differ only in requirement source-line evidence.
  Every other aggregate module is byte-identical, and the contracts are byte-identical after
  normalizing only that diagnostic line number; behavior keys, declaration indices, and
  `EdgeRef` identities remain exact.
  Evidence: Disposable public-CLI scaffolds of the single fixture and its workspace twin produced
  exact Journey module trees except for the final `BehaviorRequirement` source-line field.


## Decision Log

- Decision: Introduce one internal aggregate-generation layout whose entries retain the one-based
  declaration index and carry the zero-based source-wide outgoing-edge index.
  Rationale: Declaration indices keep existing transition helper and Hole names stable, while
  outgoing indices are the runtime identity used by `EdgeRef`. Conflating the two or recomputing
  either in a renderer caused the current disagreement.
  Date: 2026-08-04

- Decision: Consolidate all entries for one source into a single generated `B.from` block, ordered
  by first source occurrence and then original transition declaration order.
  Rationale: This produces readable source with the same edge list Keiki already constructs when
  duplicate `from` blocks are merged. It removes the opportunity for a local index reset without
  changing runtime order.
  Date: 2026-08-04

- Decision: Generate legacy initial acceptance and forward/replay helpers only for `Live` entries;
  replay-only coverage remains exclusively in generated replay behavior requirements.
  Rationale: `ReplayOnly` is not eligible for `step`, and ADR 0002 requires live-first replay
  fallback. A step-based probe is both semantically false and redundant with the stronger compiled
  `ReplayWitness` contract.
  Date: 2026-08-04

- Decision: Preserve existing helper names for valid unique live probes and reject any remaining
  value-space collision during semantic name planning. Add a repeated-declaration check to the
  final lexical audit as defense in depth.
  Rationale: Filtering by mode fixes the motivating live/replay duplicate without changing output
  for unaffected specs. A shape such as two live initial transitions for the same command still
  cannot render the legacy helper scheme safely; it should fail before writes with both transition
  locations instead of reaching GHC. The lexical audit catches literal template mistakes that do
  not pass through the semantic inventory.
  Date: 2026-08-04

- Decision: Do not change Keiki semantics or Keiro's Keiki dependency bound in this plan.
  Rationale: Keiki already supplies the required `Live`/`ReplayOnly` execution and source-wide
  builder ordering. Mori's Keiki 0.9 adoption removes a separate validation workaround, but IR-18
  is a Keiro generation defect and works against the existing runtime semantics.
  Date: 2026-08-04

- Decision: Widen Milestone 1 so the layout module becomes the only producer of transition-derived
  indices and groupings, covering three sibling sites the 2026-08-04 pre-adoption audit found
  outside the original refactor list: the second adjacency-based grouping `groupBySource` used by
  the legacy Holes skeleton (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, `emitLegacyHoles` path), the
  independent `zip [1 ..]` declaration-index recomputations in `resolveAgg`'s
  `(transitionIndex, emitIndex)` output-mapping key and in `obsoleteGeneratedOutputHooks`, and the
  initial-state identity derived separately in `Harness.initialTransitions`, `initialVertex`, and
  the transducer builder call.
  Rationale: The plan's purpose is that one checked layout determines every transition identity.
  Leaving a duplicate grouping implementation and two index recomputation sites alive would keep
  the drift class open; routing them through `AggregateGenerationPlan` (grouping, declaration
  indices) and one shared initial-state accessor closes it structurally instead of only fixing the
  four consumers that currently disagree.
  Date: 2026-08-04

- Decision: Extend the existing behavior-complete and service-package proofs instead of creating a
  parallel test architecture.
  Rationale: Those fixtures already prove compiled detailed edge attribution, create-once replay
  witnesses, single/workspace generation, public CLI idempotence, and a runnable generated
  whole-service package. Adding the missing shape there proves the repair through the released
  paths and keeps `cabal test keiro-dsl` authoritative.
  Date: 2026-08-04

- Decision: Orient the new complementary guards around the generator's deterministic sample
  values and preserve those exact values in the filled behavior witnesses.
  Rationale: The generated harness is a concrete executable proof, not a constraint solver. The
  fixture must exercise the intended live path with its generated sample while a separate retired
  value proves replay-only fallback and exact edge attribution.
  Date: 2026-08-05

- Decision: Compare single/workspace aggregate modules byte-for-byte except for source-line
  evidence in `BehaviorContract.hs`, where the test normalizes only the relocated line number.
  Rationale: Member attribution deliberately relocates workspace source spans. Erasing that
  provenance or padding fixtures to force coincidental line equality would weaken diagnostics;
  normalizing just the location preserves the stronger semantic parity claim.
  Date: 2026-08-05


## Outcomes & Retrospective

Milestones 1 through 3 are complete. The enriched Journey proof emits one initial source block,
one live `acceptStart`, no `acceptLegacyStart`, and exact replay `EdgeRef`s 1 and 2. All 19 behavior
obligations are filled; 17 execute and the two unverified rows are the intentional closed-state
rejection cells. The mutation script proves wrong history, witness kind, replay edge, replay chunk,
codec, selector, and source-wide predicate index changes all turn the suite red and restores every
file afterward. The single/workspace proof is byte-exact apart from deliberately relocated source
line evidence, and the generated whole-service package passes with 29 facts. No generator wire
semantics or Keiki behavior changed; the enriched fixture intentionally adds its legacy event and
receives a new fold fingerprint and behavior keys. ADR, user-documentation, release-note, and IR
closure remain for Milestone 4. Mori can remove
`legacyEmptyStartTransducer` only after adopting a Keiro release containing this work and passing
its historical replay proof.


## Context and Orientation

The source request is
[`docs/improvement-requests/handle-initial-state-replay-only-transitions-in-generated-harnesses.md`](../improvement-requests/handle-initial-state-replay-only-transitions-in-generated-harnesses.md)
(`IR-18`). Its Mori reproducer is
`mori://shinzui/mori/plans/176-rewrite-the-workflow-aggregate-with-real-step-completion-and-causation`.
Mori has a historical `WorkflowStarted` event with an empty target set. New `StartWorkflow`
commands reject that set, so the old event needs an initial `ReplayOnly` edge even though no new
command may select it.

A transition has two relevant identities. Its _declaration index_ is its one-based position in the
aggregate's complete transition list; generated names such as
`transition3EmptyStartGuard` use it and must stay stable. Its _outgoing-edge index_ is its
zero-based position among all transitions from one source vertex; Keiki's `EdgeRef` and detailed
step/replay attribution use this identity. A _source block_ is a rendered `B.from Vertex do` group.
Source blocks are presentation; they must not create a third edge identity.

`keiro-dsl/src/Keiro/Dsl/Grammar.hs` defines `Transition`, including `tSource`, `tCommand`, `tMode`,
`tEmits`, `tGoto`, `tImplementation`, and `tLoc`. `TmLive` edges participate in forward stepping.
`TmReplayOnly` edges participate only in inversion after no live candidate matches. The parser
already admits `replay-only` from any source, including the first state, and
`keiro-dsl/src/Keiro/Dsl/Validate.hs` permits a replay-only edge without a live sibling as a
warning rather than an error.

`keiro-dsl/src/Keiro/Dsl/Harness.hs` emits the generated aggregate `Harness` module. `emitHarness`
uses `initialTransitions` for live acceptance assertions and `acceptDecl`, but
`initialTransitions` filters only on the aggregate's first state. Consequently a replay-only
initial `Start` emits `acceptStart`; a live/replay pair emits the declaration twice. The
forward/replay list has its own `TmLive` filter, so the two initial-probe paths can already drift.

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` owns the authoritative generated `Transducer`, predicate
verification, and behavior contract. `transitionEntries` pairs transitions with one-based
declaration indices. `groupTransitionEntriesBySource` uses `span`, so it groups only adjacent
runs. `renderVerificationList` then zips each run with `[0..]`, restarting outgoing indices.
`behaviorEdgeIndex`, by contrast, filters the complete transition list by source before
`findIndex`, so behavior requirements get the correct source-wide index. `generatedFromBlock`
renders every group as a separate `B.from` block. Keiki's builder merges those blocks, making the
runtime agree with the behavior contract and disagree with predicate verification.

`keiro-dsl/src/Keiro/Dsl/BehaviorCoverage.hs` derives a finite behavior inventory for every live
transition from a live-reachable state, every reachable state/command rejection cell, and every
replay-only transition. `emitBehaviorContract` in `Scaffold.hs` executes a `ReplayWitness` with
`applyEventsDetailedEither` and checks exact `ReplayOnly` mode, source, target, event span, and
`EdgeRef`. This mechanism is already correct and should consume the shared layout rather than be
replaced.

`keiro-dsl/src/Keiro/Dsl/HaskellName.hs` defines `PlannedOccurrence`, `ValueSpace`, `NameSite`, and
`detectNameCollisions`. `validateNames` in `Validate.hs` inventories node modules, shared types,
and aggregate record fields, but not transition-derived top-level harness helpers.
`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` runs semantic refusals and `auditGeneratedHaskell` before
writing. The audit masks comments and literals and checks declaration casing, but it does not yet
reject two emitted top-level signatures with the same name. These are the existing gates to
extend; no post-write GHC-only gate is acceptable.

The primary compiled fixture is `keiro-dsl/test/fixtures/behavior-complete.keiro`, mirrored by
`keiro-dsl/test/fixtures/behavior-complete-workspace/journey.keiro`. Its committed runtime and
witness tree is under `keiro-dsl/test/conformance-behavior-complete/`, and the component
`keiro-dsl-conformance-behavior-complete` runs every filled behavior witness. The runnable
whole-service proof is rooted at
`keiro-dsl/test/conformance-service-package/service.keiro-workspace`; its runtime tree and generated
conformance package are already listed in the repository `cabal.project`. Ordinary generator,
workspace, preflight, idempotence, and mutation tests live in `keiro-dsl/test/Main.hs`, while test
component inventories and the new private module list live in `keiro-dsl/keiro-dsl.cabal`.

Mori located the dependency source as `mori://shinzui/keiki/packages/keiki`. In `Keiki.Builder`,
each `from` call records one entry and `buildTransducerEither` merges duplicate vertices in
declaration order, appending edges before assigning their per-vertex indices. Keiki 0.9.0.0 retains
that contract. This plan neither replaces it nor depends on the new 0.9 inversion-warning proof.

The local ADR scan found six relevant accepted decisions:

- [ADR 0002](../adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md)
  defines `ReplayOnly` as inversion-only and mandates live-first replay fallback. Amend it to state
  that generated live probes are mode-aware and replay-only evidence uses replay attribution.
- [ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
  assigns internally decidable failures to the earliest sound boundary. Reuse its check/pre-write
  rule for duplicate generated declarations.
- [ADR 0014](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
  makes a single spec a one-member workspace and requires identical semantic results from both
  paths. The new layout must be independent of member placement and order.
- [ADR 0015](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
  requires all whole-workspace preflights to finish before active output changes and makes
  idempotence observable. Collision refusal and repeat-scaffold evidence must preserve this.
- [ADR 0017](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
  requires every replay-only transition in the finite behavior inventory and exact detailed edge
  attribution. Amend it with the single source-wide layout invariant.
- [ADR 0019](../adr/0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md)
  establishes checked occurrence planning plus a final lexical declaration inventory. Amend it to
  include duplicate-declaration detection, not merely casing.


## Plan of Work

### Milestone 1: Make source-wide transition layout authoritative

Add the private module `keiro-dsl/src/Keiro/Dsl/AggregateGenerationPlan.hs` and list it in the
library `other-modules` in `keiro-dsl/keiro-dsl.cabal`. It owns a pure `TransitionLayoutEntry`
containing the original `Transition`, its one-based declaration index, and its zero-based
source-wide outgoing index. Build entries in declaration order while incrementing a counter per
source. Expose grouping that returns each source once, ordered by its first occurrence, with that
source's entries still in declaration order. Add unit examples proving the layouts
`A, B, A, B, A` and `A, A, B` produce source groups `A, B` and outgoing indices `A=[0,1,2]`,
`B=[0,1]` without changing declaration indices `[1..]`.

Refactor `transitionEntries`, `groupTransitionEntriesBySource`, `renderVerificationList`,
`generatedFromBlock`, and `behaviorEdgeIndex` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` to consume
that plan. In the same pass, route the remaining transition-identity sites through it so no
duplicate derivation survives: replace the legacy Holes skeleton's own adjacency grouping
(`groupBySource` and its `fromBlock`/`onCmdBlock` consumers on the `emitLegacyHoles` path) with the
layout's source groups; build `resolveAgg`'s `(transitionIndex, emitIndex)` output-mapping keys and
the `obsoleteGeneratedOutputHooks` inventory from layout declaration indices instead of local
`zip [1 ..]` recomputation; and introduce one initial-state accessor consumed by
`Harness.initialTransitions`'s replacement, `initialVertex`, and the generated
`B.buildTransducer` call, removing their independent head-of-`aStates` derivations. Preserve declaration indices for transition stems, Hole functions, output hooks, and
fold-version references. Render one `B.from` per source group. Pass each entry's stored outgoing
index to `verifyTransition`, and find behavior requirements by source, transition location, and
command within the layout before using the stored index. Treat a validated requirement missing
from the layout as the existing internal generation error.

Refactor `emitHarness` in `keiro-dsl/src/Keiro/Dsl/Harness.hs` to derive one
`initialLiveTransitionEntries` collection from the same layout. Use it for both acceptance
assertions/declarations and forward/replay assertions/declarations. Remove the mode-blind
`initialTransitions` path. An initial replay-only edge must be absent from all calls to `step` and
present only in the transducer and behavior contract.

Add focused pure tests in `keiro-dsl/test/Main.hs` before updating committed fixtures. Given an
inline aggregate whose transition sources are non-contiguous, assert that the rendered transducer
has one source block, predicate verification uses cumulative indices, and behavior contract
`EdgeRef` values match. Given a live/replay-only initial pair, assert exactly one live acceptance
declaration. Run the ordinary focused suite and the existing behavior-conformance component; the
milestone is complete when both pass and existing fixtures without the affected shape retain
normalized byte equality.

### Milestone 2: Refuse residual generated declaration collisions before writes

Extend aggregate occurrences in `validateNames` in `keiro-dsl/src/Keiro/Dsl/Validate.hs`. For each
aggregate, identify the initial state and inventory the exact top-level helper values that
`Harness.hs` will emit: `accept<Command>` for every live initial transition and
`forwardReplay<Command>` for every live, emitting initial transition. Use the generated Harness
module as the occurrence module, `ValueSpace` as the namespace, `GeneratedHelperSite` as the site
kind, and `tLoc` as source evidence. Replay-only entries contribute no live-helper occurrence.
Feed these rows through the existing `detectNameCollisions` path and reuse
`GeneratedOccurrenceCollision`, including the primary line and every related transition line.

Extend `auditGeneratedHaskell` in `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` so its masked
declaration inventory rejects repeated top-level type signatures and repeated type/data/newtype
declarations in one module. A normal signature plus its one value binding remains legal. This is
defense in depth for a literal renderer bypass; semantic helper collisions must normally fail
earlier with DSL source locations.

Add two ordinary regressions. The first gives a live and replay-only initial transition the same
command and proves no collision is reported after mode filtering. The second gives two live
initial transitions the same command and proves `check` or scaffold planning returns
`GeneratedOccurrenceCollision` with the later line primary, the earlier line related, and no write
set. Add a synthetic generated module with a repeated signature to prove the lexical fallback
also becomes a pre-write refusal. Complete the milestone with the focused name/preflight tests and
the private Haskell-name component green.

### Milestone 3: Compile the motivating shape in single, workspace, and service paths

Extend `keiro-dsl/test/fixtures/behavior-complete.keiro` and its exact workspace aggregate mirror
`keiro-dsl/test/fixtures/behavior-complete-workspace/journey.keiro`. Keep the live initial `Start`,
then interleave transitions from `Active`, a replay-only initial `Start` sibling that emits the
same `Started` event for the retired guard region, more `Active` transitions, and a replay-only
initial legacy command with no live sibling and its own event. The three initial-source runs must
be non-contiguous. Choose exact complementary scalar guards and witness values so live replay wins
for current history and falls through to the replay-only sibling only for the retired history.

Regenerate the overwriteable modules in
`keiro-dsl/test/conformance-behavior-complete/Generated/BehaviorComplete/` and update the
create-once `BehaviorComplete/Journey/BehaviorHoles.hs` deliberately. Fill both new
`ReplayWitness` rows and every newly introduced rejection row; do not leave `Pending`. Assert in
`keiro-dsl/test/Main.hs` that:

- `Harness.hs` contains one `acceptStart` and no acceptance helper for the legacy-only command;
- `Transducer.hs` contains one initial `B.from` block with all initial entries in declaration
  order;
- `BehaviorContract.hs` assigns the two replay-only requirements initial-edge indices 1 and 2;
- predicate-verification rows name the same indices and transition stems;
- live stepping never returns `ReplayOnly`, current replay attributes to the live edge, and retired
  replay attributes to the expected replay-only edge; and
- single-spec and workspace planning produce identical aggregate module bytes except for the
  workspace-relocated source-line evidence in `BehaviorContract.hs`; after normalizing only that
  diagnostic line, behavior rows and source-wide identities are exact, with a byte-stable second
  scaffold.

Update the expected behavior counts, stable fold baseline, scaffold-record assertions, and Cabal
module inventory only where the enriched fixture requires it. `cabal test
keiro-dsl-conformance-behavior-complete` must compile and execute the new witnesses.

Carry the same minimal initial live/replay and replay-only-only shape into the existing Alpha
aggregate under `keiro-dsl/test/conformance-service-package/domain/alpha.keiro`. Regenerate only
the recognized generated files in its runtime tree; preserve create-once modules. Re-run the
public CLI idempotence proof, `cabal test keiro-workspace-proof-conformance`, and the existing
workflow-fact restoring mutation. The generated whole-service package must pass without a
runtime-only transducer or hand edit to generated code.

### Milestone 4: Publish and close the repair

Amend ADRs 0002, 0017, and 0019 and `docs/adr/log.md` with the mode-aware live-probe,
source-wide-edge, and duplicate-inventory invariants. No new ADR is needed because the repair
completes those accepted decisions rather than selecting a new architecture. Update
`docs/user/replay-safety.md` and the aggregate behavior/conformance discussion in
`docs/user/typed-spec-toolchain.md` with an initial replay-only example and explain that it never
receives a live acceptance probe.

Add release notes to `CHANGELOG.md` and `keiro-dsl/CHANGELOG.md`. Update IR-18's Status section and
frontmatter to `implemented` with a repository-local link to this plan only after all acceptance
criteria pass; add the matching entry to `docs/improvement-requests/log.md`. Do not reopen IR-17
or add reviewed-warning policy syntax. Finish with the full Keiro DSL package, repository build,
generated-source policies, strict ADR and improvement-request bundle validation, and diff hygiene.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/keiro` unless stated otherwise. Before edits,
confirm the dependency and baseline without traversing `/nix/store`:

```console
$ mori registry show shinzui/keiki --full
Path: /Users/shinzui/Keikaku/bokuno/keiki
...
keiki  mori://shinzui/keiki/packages/keiki

$ nix develop -c cabal test keiro-dsl-test --test-options='--match "behavior obligations"'
...
0 failures

$ nix develop -c cabal test keiro-dsl-conformance-behavior-complete
...
Test suite keiro-dsl-conformance-behavior-complete: PASS
```

During Milestones 1 and 2, run the narrow ordinary tests after each layout or collision change.
Use the final Hspec descriptions chosen by the implementation in place of the indicative match
strings below, and record them in Progress:

```console
$ nix develop -c cabal test keiro-dsl-test --test-options='--match "transition layout"'
...
0 failures

$ nix develop -c cabal test keiro-dsl-test --test-options='--match "generated declaration collision"'
...
0 failures

$ nix develop -c cabal test keiro-dsl-haskell-name-test
...
Test suite keiro-dsl-haskell-name-test: PASS
```

Use the public scaffolder, not hand-written substitutions, to inspect fixture output in a
disposable directory before updating committed generated modules:

```console
$ proof_dir=$(mktemp -d)
$ nix develop -c cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/behavior-complete.keiro --out "$proof_dir"
...
Generated.BehaviorComplete.Journey.Transducer ...
Generated.BehaviorComplete.Journey.Harness ...

$ rg -n 'acceptStart|acceptLegacy|B.from .*Empty|verifyTransition|EdgeRef' "$proof_dir"
...
```

The inspection must show one live `acceptStart`, no `accept` declaration for the replay-only-only
command, one initial `B.from`, and cumulative replay edge indices. Remove only this explicitly
created disposable directory after inspection. Regenerate the checked-in behavior and service
fixtures through their existing scaffold commands, preserve create-once files, then review every
diff before filling new witnesses.

Run the compiled feature proofs:

```console
$ nix develop -c cabal test keiro-dsl-conformance-behavior-complete
...
Test suite keiro-dsl-conformance-behavior-complete: PASS

$ nix develop -c cabal test keiro-workspace-proof-conformance
...
Test suite conformance: PASS

$ nix develop -c cabal test keiro-dsl-test --test-options='--match "runnable service conformance package"'
...
0 failures
```

Run the complete closure after documentation and fixture updates:

```console
$ nix develop -c cabal test keiro-dsl
...
All ... test suites passed

$ nix develop -c cabal build all
...
Build profile: ...

$ scripts/check-extension-policy.sh
extension policy: ok

$ scripts/check-generated-name-policy.sh
generated Haskell naming policy: ok

$ okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
...
validation succeeded

$ okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
...
validation succeeded

$ git diff --check
```

Update the short expected transcripts and exact test counts in this plan as implementation
proceeds. A blank `git diff --check` result is success.


## Validation and Acceptance

Acceptance is behavioral, not merely a successful build:

1. Parsing and checking the enriched behavior-complete fixture succeeds. Scaffolding produces
   exactly one `acceptStart` declaration even though `Start` has live and replay-only initial
   edges, and produces no `accept<LegacyCommand>` for the replay-only-only edge.
2. The generated transducer contains one initial-source block. Its entries retain specification
   declaration order across three formerly non-contiguous runs, and Keiki reports outgoing
   indices 0, 1, and 2 for those entries.
3. Both predicate verification and behavior requirements identify the same replay-only sibling as
   `EdgeRef <InitialVertex> 1` and the replay-only-only edge as index 2. No renderer derives an
   edge index with a local `zip [0..]`.
4. `cabal test keiro-dsl-conformance-behavior-complete` executes filled `ReplayWitness` values.
   A current event selects the live edge; the retired event selects `ReplayOnly` only after live
   inversion fails; the detailed attribution reports the required source, target, span, mode, and
   edge. Forward stepping never selects either replay-only edge.
5. A mutation that gives the retired replay value to the live guard makes the replay witness fail
   with wrong mode or edge attribution. Restoring the guard makes it pass again. A mutation that
   resets the later predicate edge index to zero fails the predicate or exact source assertion.
6. A replay-only initial edge with no live sibling still receives a replay requirement and passing
   witness but no forward acceptance helper.
7. A residual semantic helper collision is reported as `GeneratedOccurrenceCollision` before any
   file changes, with primary and related DSL lines. A synthetic repeated generated signature is
   independently rejected by `auditGeneratedHaskell`.
8. The single-file fixture and its workspace twin emit identical aggregate generated bytes except
   for deliberately relocated source-line evidence, and exact source-wide edge identities. A
   second public scaffold changes no bytes. The existing runnable workspace service package
   compiles and passes with the same initial replay-only shape.
9. Existing specs without initial replay-only edges or non-contiguous repeated sources remain
   byte-identical after normalization. No wire tag, payload schema, persisted identity, fold
   meaning, or Keiki live-first replay behavior changes.
10. `cabal test keiro-dsl`, `cabal build all`, both generated-source policy scripts, both strict OKF
    bundle validations, and `git diff --check` pass.


## Idempotence and Recovery

The layout and name plans are pure functions of the checked aggregate, so tests and generation are
repeatable. The source-group algorithm must not depend on `Map` key ordering; it preserves the
first encounter of each source explicitly. A second single-file or workspace scaffold must report
generated files unchanged and skip every existing create-once file.

Always scaffold changed fixtures into a disposable directory first. When refreshing committed
trees, let the public scaffold command overwrite only files with recognized generated provenance.
Never replace `BehaviorHoles.hs`, other Hole modules, or service expectations from disposable
stubs; update those create-once files deliberately with `apply_patch`. If generation or a test
fails midway, leave the failed output for inspection, correct the planner or witness, and rerun;
the repository's generated provenance checks and detection-before-write preflight make the retry
safe.

The change has no database, network, or persisted-wire migration. To back out an incomplete
implementation, revert only the files changed for this plan using an explicit patch; do not reset
the worktree or delete unrelated user changes. Mori should remove its runtime-only replay edge only
after a released Keiro containing this plan is adopted and Mori's own historical replay proof
passes, so a Keiro rollback does not strand existing streams.


## Interfaces and Dependencies

Add the following private interface in
`keiro-dsl/src/Keiro/Dsl/AggregateGenerationPlan.hs`; exact field prefixes may follow local style,
but the information and index bases are fixed:

```haskell
data TransitionLayoutEntry = TransitionLayoutEntry
  { layoutDeclarationIndex :: !Int
  , layoutOutgoingIndex :: !Int
  , layoutTransition :: !Transition
  }

transitionLayout :: [Transition] -> [TransitionLayoutEntry]

groupTransitionLayoutBySource
  :: [TransitionLayoutEntry]
  -> [(Name, [TransitionLayoutEntry])]

transitionLayoutForSource
  :: Name
  -> [TransitionLayoutEntry]
  -> [TransitionLayoutEntry]
```

`layoutDeclarationIndex` is one-based and equals the transition's original list position.
`layoutOutgoingIndex` is zero-based within `tSource`. `transitionLayout` and every returned group
preserve declaration order; group order is source first-occurrence order. Add a small lookup helper
if needed for behavior requirements, but it must compare source plus stable transition evidence
(`tLoc` and command) and return the stored entry rather than recomputing an index.

`Keiro.Dsl.Harness` consumes layout entries through an internal function equivalent to:

```haskell
initialLiveTransitionEntries :: Agg -> [TransitionLayoutEntry]
```

Both acceptance and forward/replay declarations take these entries. No function named
`initialTransitions` may remain mode-blind.

`Keiro.Dsl.Validate.validateNames` adds planned value occurrences for the exact helper names that
the Harness renderer emits. Use the existing interfaces:

```haskell
HaskellName.plannedOccurrence
  :: Text
  -> HaskellOccurrenceSpace
  -> Text
  -> Text
  -> NameSite
  -> PlannedOccurrence

HaskellName.detectNameCollisions
  :: [PlannedOccurrence]
  -> [HaskellNameError]
```

Reuse `GeneratedOccurrenceCollision`; do not add a diagnostic code for the same name-space
failure. `auditGeneratedHaskell :: ScaffoldModule -> [Text]` remains the renderer-level fallback
and adds duplicate declaration messages containing generated module path and line numbers.

The runtime dependency is `mori://shinzui/keiki/packages/keiki`. Continue using its existing
`B.from`, `B.onCmd`, `B.replayOnly`, `stepDetailedEither`, and `applyEventsDetailedEither`
interfaces. Keiki's merge order and live-first replay semantics are the external contract; this
plan adds no dependency, changes no Cabal bound, and introduces no compatibility workaround for
Keiki 0.9.


---

Revision note (2026-08-04): Adopted into MasterPlan
`docs/masterplans/29-stabilize-keiro-dsl-for-wide-adoption.md` and widened Milestone 1 with three
sibling transition-identity sites found by the pre-adoption audit (legacy Holes grouping,
output-mapping/obsolete-hook declaration-index recomputation, and the triple-derived initial-state
identity), so the AggregateGenerationPlan layout becomes the sole producer of transition-derived
identity rather than only reconciling the four consumers that currently disagree. See the new
Decision Log entry dated 2026-08-04.

Revision note (2026-08-05): Milestone 3's byte-parity wording now excludes only the composed
workspace source-line relocation in `BehaviorContract.hs`. Implementation proved every other
Journey module byte-identical and preserved exact behavior keys and edge identities; the new
Decision Log records why retaining real member provenance is stronger than forcing artificial
line equality.
