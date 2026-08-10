---
id: 220
slug: generate-one-stable-behavior-source-map-from-semantic-anchors
title: "Generate one stable behavior source map from semantic anchors"
kind: exec-plan
created_at: 2026-08-09T19:29:29Z
intention: "intention_01kzkzswbae5dan7x42gx8fv1c"
master_plan: "docs/masterplans/34-make-keiro-dsl-regeneration-semantically-local-and-source-stable-before-wide-adoption.md"
---

# Generate one stable behavior source map from semantic anchors

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, every generated behavior contract uses its existing `BehaviorKey` as the only
durable requirement identity. Current source positions live in one generated context
`BehaviorSourceMap` and are resolved by key when diagnostics render. Adding comments, blank lines,
or unrelated declarations before an unchanged aggregate rewrites the source map but leaves that
aggregate's `BehaviorContract.hs` and create-once witness bytes unchanged. Failures still name the
current file, line, and column.

Generation checks the complete behavior-key/source-index join before planning any writes. Missing,
inexact, duplicate, or colliding anchors produce stable diagnostics; no contract silently keeps an
old line.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1: give each derived behavior requirement a non-positional source subject and join
  all requirements to EP-3's exact source index with stable pre-write diagnostics.
- [x] Milestone 2: emit one deterministic context `BehaviorSourceMap` for single-file and workspace
  services and include it in scaffold ownership/build history.
- [x] Milestone 3: remove volatile lines from generated behavior contracts and initial witness
  comments while resolving runtime diagnostics through the map.
- [x] Milestone 4: prove source movement changes only the map, update behavior reports/ADRs/docs,
  and pass focused mutation and conformance gates.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The first full-suite run produced 43 failures because many unit tests deliberately construct a
  bare semantic `Spec`. The product refusal was correct: those values have only
  `CompatibilityLineOnly` provenance. Test-only helpers now promote their synthetic spans through
  `exactSemanticSourceIndex`; the dedicated compatibility test still proves production never
  fabricates exact columns.
- Exact source-map planning initially hid older path/fold refusal categories behind an inexact or
  missing anchor. Running the established semantic module-plan gate before the exact-source
  completion gate preserves the public refusal precedence while still producing no writes.
- Workspace source movement changes exact source-map bytes and the existing workspace ledger's
  compatibility role-origin lines. Generated module dispositions contain only the context source
  map; semantic-impact/history interpretation remains EP-5's scope.
- The repository has no `check-adr` recipe despite the plan's concrete-step example. The
  authoritative strict command is `okf validate docs/adr --strict --profile
  docs/adr/profile.dhall --profile-enforce --log-enforce`; it passed all 28 concepts.


## Decision Log

Record every decision made while working on the plan.

- Decision: Use the frozen `BehaviorKey` text as the generated source-map key.
  Rationale: It already identifies the full semantic obligation and has collision preflight. A new
  file/line-derived anchor would create another identity and would move when source moves.
  Date: 2026-08-09

- Decision: Emit one generated Haskell map per context, not a sidecar per aggregate.
  Rationale: Aggregate maps would still rewrite every moved aggregate contract or import closure;
  a single context module isolates positional churn and remains available to offline compiled
  diagnostics without inventing another ledger format.
  Date: 2026-08-09

- Decision: Remove positions from create-once pending witness comments as well as generated
  contracts.
  Rationale: Witness identity is the behavior key. A comment copied at first scaffold should not
  become stale positional documentation, and fresh equivalent scaffolds should not differ only by
  earlier source layout.
  Date: 2026-08-09

- Decision: Keep the semantic-only planner adapters as explicit inexact-anchor refusals and create
  exact synthetic indices only inside unit-test helpers.
  Rationale: Treating a line-only `Loc` as column 1 would make generated diagnostics look exact and
  would let library callers bypass the checked source-aware parse boundary.
  Date: 2026-08-09

- Decision: Evaluate established semantic/path/import gates before completing the behavior-source
  map join.
  Rationale: Exact provenance is required for a successful plan, but it must not mask an earlier
  stable refusal that is already decidable from the semantic graph.
  Date: 2026-08-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Completed on 2026-08-10. Derived requirements now retain stable transition/state origins and join
through `SemanticSourceIndex` to exact file, line, and column before a successful scaffold plan can
exist. Missing, compatibility-only, duplicate, and colliding anchors produce stable refusals with
the behavior key and semantic subject. The compatibility bare-`Spec` APIs refuse behavior-bearing
generation rather than inventing an exact column.

Single-file and workspace scaffolds emit at most one context `BehaviorSourceMap`; services without
behavior obligations omit it. Contracts and newly created witness comments no longer contain
source positions, and runtime failure subjects resolve the frozen behavior key through the map.
Behavior text and JSON reports expose the current exact location and label line-only compatibility
output explicitly. Focused byte-tree tests prove that comment/declaration movement and aggregate
ownership movement rewrite only the context source-map module among generated modules. Workspace
ledger compatibility locations still move and are deliberately left for EP-5's history model.

Qualification passed `cabal build all`, the complete 631-example DSL suite, the compiled
behavior-complete fixture (19 required, 19 filled, 17 verified, 2 explicitly unverified), the
restoring behavior mutation script, extension and generated-name policies, strict ADR validation,
and diff hygiene. Only the behavior-complete fixture was regenerated; EP-6 still owns the single
coordinated full-corpus refresh.


## Context and Orientation

This plan hard-depends on
[Plan 219](219-preserve-exact-semantic-source-provenance-through-parsing-and-workspace-composition.md),
which supplies exact spans for aggregate states and source-order transitions. It may align module
ordering with [Plan 217](217-define-one-checked-semantic-impact-model-for-keiro-dsl-consumers.md)
but does not depend on mapped-type semantics.

`keiro-dsl/src/Keiro/Dsl/BehaviorCoverage.hs` derives every live-transition, replay-transition,
and required-rejection obligation. `transitionCanonical` includes context, aggregate, mode,
source, command, implementation, guard, writes, events, output mappings, and target. `canonicalKey`
hashes that text into the frozen `behavior-v1-<fnv1a64>` key and `rejectIdentityDefects` rejects
duplicate semantic identities or key collisions. `BehaviorRequirement` also carries line-only
`requirementLocation`, which is used for diagnostics but is not part of the key.

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` emits `BehaviorContract.hs`. The generated
`BehaviorRequirement` contains `requirementLine :: Int`; every contract row has a `(spec line N)`
comment; and failure subjects render the stored line. `behaviorRequirementLabel` also adds that
line to newly created `BehaviorHoles.hs` pending rows. These are the volatile bytes. Existing
create-once witness files are not overwritten, but their comments become stale and equivalent
fresh scaffolds differ.

`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs` already treats replay-audit and structural facades
as context-level modules, giving the new map an established ownership convention. Single and
workspace planners both derive requirements before writes and already reject behavior identity
defects. `BehaviorCoverage` JSON currently reports line and optional member but no exact column;
it can append exact source information without changing behavior-key identity.

[ADR 0017](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
freezes behavior ownership, key identity, source annotations, and finite evidence. The annotation
part must be amended while key/evidence semantics remain unchanged.
[ADR 0016](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) keeps
source provenance outside `Spec`. [ADR 0015](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
defines context-level provenance, recognized generated banners, and idempotence.
[ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) requires
stable pre-write diagnostics. No external package or cross-repository ADR is needed.


## Plan of Work

Milestone 1 makes the requirement-to-source join explicit. Extend `BehaviorCoverage.hs` with a
non-positional `RequirementOrigin`: a transition origin carries the aggregate and source-order
transition ordinal; a rejection origin carries the aggregate and state name. Populate it in the
same fold that derives the requirement; do not match requirements back to transitions by rendered
text or line. Add `Keiro.Dsl.BehaviorSourceMap` with a pure planner that takes the complete derived
requirements and EP-3 `SemanticSourceIndex`, looks up exact spans, and constructs sorted
`BehaviorSourceEntry` rows keyed by `BehaviorKey`.

Reject a missing source subject, a line-only compatibility position, duplicate key, or key
collision before any module plan exists. Append stable diagnostic codes such as
`BehaviorSourceAnchorMissing`, `BehaviorSourceAnchorInexact`, and
`BehaviorSourceAnchorCollision` through the existing validation/planning registry. Diagnostics
name the behavior key, aggregate, source state, command, and available source subject. Assert that
the entry key set equals the complete requirement key set.

Milestone 2 renders one context module named
`<context generated prefix>.BehaviorSourceMap`. It exports a small location record and a total
lookup returning `Maybe`; entries are sorted by unwrapped key text and contain normalized
file-qualified source, one-based line, and one-based column. Use direct pattern matching or a
deterministically built `Map Text` consistent with the generated-language/import policy. Add the
module to single and workspace plans before collision/import-cycle/write checks, mark it
context-level in workspace history, and include it in build fragments. A service with no behavior
requirements may omit the module only if no generated contract imports it; choose one rule and pin
it in tests.

Milestone 3 changes `Scaffold.emitBehaviorContract`. Remove `requirementLine` from the generated
record, remove all source-line comments from `behaviorRequirements`, and import the context map
under one stable alias. Failure rendering looks up `unBehaviorKey (requirementKey requirement)` and
prints `path:line:column`; the checked preflight makes `Nothing` an internal-invariant message that
still includes the key, never an old position. Keep semantic subject text for readability. Remove
line text from initial `BehaviorHoles` rows, retaining state, command, kind, and key. BehaviorHoles
reconciliation continues to compare keys only.

Update `BehaviorCoverage` text/JSON and CLI behavior-obligations output to resolve exact current
positions when a source index is available. Preserve the existing schema identifier and append
`file`/`column` keys; compatibility semantic-only APIs may retain line-only output but must mark the
quality explicitly.

Milestone 4 adds a two-member fixture and byte-tree comparison. Capture baseline contract,
witness, key, fold, and source-map bytes; insert comments, blank lines, an unrelated declaration,
and an optional field in the earlier member; re-scaffold. Only `BehaviorSourceMap.hs` and genuinely
semantic outputs may differ. Run a behavior mutation to prove failure text reports the new exact
position. Corrupt or remove one index row in a focused planner test and assert the stable refusal
and empty write set. Amend ADR 0017/0016 and update user/changelog documentation. Regenerate only
focused fixtures; EP-6 owns the final corpus sweep.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
```

Inventory behavior identity and volatile position consumers:

```bash
mori registry show shinzui/keiro --full
rg -n 'BehaviorKey|requirementLine|requirementLocation|behaviorRequirementLabel|spec line' \
  keiro-dsl/src keiro-dsl/test
```

Run focused source-map, behavior, and workspace tests:

```bash
cabal test keiro-dsl:keiro-dsl-test --test-option=--match --test-option='behavior source map'
cabal test keiro-dsl:keiro-dsl-conformance-behavior-complete
bash keiro-dsl/test/behavior-complete-mutation-test.sh
```

Before closure, run:

```bash
cabal build all
cabal test keiro-dsl:tests
scripts/check-extension-policy.sh
scripts/check-generated-name-policy.sh
just check-adr
git diff --check
git status --short
```

The focused movement transcript must list only the context source-map path for positional churn,
and the mutation transcript must print the current member path, line, and column.


## Validation and Acceptance

For every derived requirement, the planned source map contains exactly one row whose key bytes
equal `unBehaviorKey requirementKey`. Live/replay rows point at their complete transition span;
rejection rows point at the relevant state declaration. The row contains the current normalized
source file and one-based start line/column. Single-file and one-member-workspace maps agree after
normalizing the member path.

Inserting comments, blank lines, unrelated declarations, or unrelated fields before a later
aggregate keeps all of that aggregate's `BehaviorContract.hs`, existing/fresh `BehaviorHoles.hs`,
behavior keys, fold fingerprint, codec, transducer, and harness bytes identical. The one source-map
module changes to the current positions. A semantic transition change still changes its behavior
key and relevant generated contract; the stability rule does not hide behavior changes.

A deliberately failing witness prints `file:line:column` from the current map. Missing, inexact,
duplicate, or colliding anchors fail `check`/planning with a stable code and no output writes.
No fallback prints a cached `requirementLine`. The generated contract compiles with `-Wall`, and
the source map has no dependency on aggregate domain modules.

The complete DSL/conformance tests, behavior restoring mutation, fold/behavior-key baselines, ADR
validation, generated source policies, and diff hygiene pass. EP-6 remains responsible for
accepting the full one-time fixture refresh.


## Idempotence and Recovery

Source-map planning and generation are deterministic. Re-scaffolding unchanged source produces
identical map and contract bytes; moving source and moving it back restores the exact prior map.
All key/source preflights run before the output directory is mutated.

Generated contracts and the source map may be regenerated from source. `BehaviorHoles` remains
create-once and must never be overwritten during migration; only newly created rows lose volatile
line comments. Mutation scripts back up and restore exact files with traps. If the join fails for a
compatibility bare-`Spec` API, return the explicit inexact-anchor diagnostic rather than fabricating
columns or bypassing the map.


## Interfaces and Dependencies

No new package dependency. Use EP-3 `SemanticSourceIndex`, existing `BehaviorKey`, `SourceSpan`,
`Text`, and `containers`. The generator-side interface must be equivalent to:

```haskell
data RequirementOrigin
  = TransitionRequirementOrigin Name TransitionOrdinal
  | RejectionRequirementOrigin Name Name
  deriving stock (Eq, Ord, Show)

data BehaviorSourceEntry = BehaviorSourceEntry
  { behaviorSourceKey :: !BehaviorKey
  , behaviorSourceFile :: !FilePath
  , behaviorSourceLine :: !Int
  , behaviorSourceColumn :: !Int
  }

planBehaviorSourceMap ::
  [BehaviorRequirement] ->
  SemanticSourceIndex ->
  Either (NonEmpty BehaviorSourceFailure) [BehaviorSourceEntry]

behaviorSourceMapModule ::
  Context ->
  [BehaviorSourceEntry] ->
  ScaffoldModule
```

The generated interface must be equivalent to:

```haskell
data BehaviorSourceLocation = BehaviorSourceLocation
  { sourceFile :: !FilePath
  , sourceLine :: !Int
  , sourceColumn :: !Int
  }

behaviorSourceLocation :: Text -> Maybe BehaviorSourceLocation
renderBehaviorSourceLocation :: Text -> Text
```

Exact field names may follow generated-code conventions. The key parameter remains `Text` so the
context map does not import every aggregate's locally generated `BehaviorKey` newtype. EP-5 depends
on the stable module role for impact reporting; EP-6 depends on byte locality and diagnostics.
