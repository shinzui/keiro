---
type: Improvement Request
title: Handle initial-state replay-only transitions correctly in generated harnesses
description: >-
  Make Keiro DSL distinguish live from replay-only transitions at the initial vertex when
  generating acceptance probes, transition blocks, predicate edge indices, behavior witnesses,
  and service conformance.
timestamp: 2026-08-05T14:23:30Z
requestId: IR-18
status: implemented
origin: mori://shinzui/mori
plan: docs/plans/191-unify-generated-transition-layout-for-replay-only-conformance.md
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-08-04T16:24:05Z
    document_timestamp: 2026-08-04T16:24:05Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Reviewed against Keiro DSL 0.10.0.0 harness, transducer, predicate-verification, and behavior
      requirement generation using Mori's legacy zero-target WorkflowStarted reproducer.
---

# Improvement Request: Handle Initial-State Replay-Only Transitions Correctly in Generated Harnesses

## Status

**Implemented.**
[Plan 191](../plans/191-unify-generated-transition-layout-for-replay-only-conformance.md)
under [MasterPlan 29](../masterplans/29-stabilize-keiro-dsl-for-wide-adoption.md) gives generated
transducer rendering, predicate verification, behavior attribution, Hole grouping, and initial
live probes one source-wide transition layout. The compiled fixture proves a live/replay initial
pair and a replay-only-only legacy command with one live acceptance helper, replay edge indices 1
and 2, all 19 behavior obligations filled, byte-stable single/workspace scaffolds apart from
deliberately relocated source-line evidence, and a passing generated whole-service conformance
package. Semantic and lexical declaration collisions are both refused before writes. Mori may
remove its runtime-only composition after adopting a Keiro release containing this repair and
passing its historical replay proof.

## Context

Language 4 permits `replay-only` transitions, including transitions from an aggregate's initial
vertex. That placement is necessary when a historical first event was accepted under a rule that
new live commands must reject.

Keiro DSL 0.10.0.0 does not generate that shape coherently. In
`keiro-dsl/src/Keiro/Dsl/Harness.hs`, `initialTransitions` returns every transition whose source is
the first state, regardless of mode. The harness emits a live `accept<Command>` assertion and
declaration for each entry. A live and replay-only sibling for the same command therefore produce
duplicate Haskell declarations; a replay-only transition with a distinct command instead produces
a live acceptance assertion that must fail because Keiki correctly excludes `ReplayOnly` edges
from forward stepping.

A second defect appears when transitions from one source are non-contiguous in the specification.
`groupTransitionEntriesBySource` groups adjacent runs rather than all transitions with the same
source. Predicate-verification edge indices restart at zero for each later run, even though the
built transducer appends those edges to the existing source. The generated behavior contract uses
the correct index, so the two generated conformance surfaces can disagree.

The reproducer came from
`mori://shinzui/mori/plans/176-rewrite-the-workflow-aggregate-with-real-step-completion-and-causation`.
One stored Workflow stream begins with `WorkflowStarted { targetProjects = [] }`. Mori must retain
a replay-only initial edge for that exact history while its live `StartWorkflow` guard rejects the
shape. Declaring the edge in the DSL generated a duplicate `acceptStartWorkflow`; Mori temporarily
composes the edge only in runtime assembly.

## Requested Change

Make mode part of every generated initial-transition decision and compute outgoing-edge positions
from the complete ordered transition list for each source.

Specifically:

- live acceptance probes and forward/replay harness properties must include only `Live`
  transitions;
- replay-only initial transitions must be covered by generated replay behavior requirements and
  `ReplayWitness` conformance, never by `step`-based acceptance;
- duplicate generated declaration names must be detected before rendering rather than left for
  GHC to reject;
- transducer generation must consolidate every transition for one source while preserving their
  declaration order, or otherwise carry cumulative edge indices across repeated source blocks;
- predicate-verification `EdgeRef`, behavior-contract `EdgeRef`, and runtime detailed attribution
  must name the same concrete edge; and
- single-spec and workspace scaffolding must produce identical results.

## Acceptance

1. A fixture declares a live `Initial -- Start` edge, later transitions from another source, and
   a replay-only `Initial -- Start` sibling with the same head event. Generated Haskell compiles
   and contains exactly one live `acceptStart` declaration.
2. The replay-only sibling has a generated replay behavior requirement whose witness proves
   `ReplayOnly` attribution and whose expected edge is index 1.
3. Predicate verification also inspects initial edge index 1 rather than restarting at index 0.
4. A replay-only initial transition with no live sibling generates no forward acceptance probe;
   its replay witness still compiles and passes.
5. Forward stepping cannot select either replay-only fixture edge, while replay falls through to
   it only when no live inverse candidate matches.
6. A fixture with three non-contiguous blocks for one source preserves declaration order and gives
   every generated verification and behavior requirement the same unique outgoing-edge index.
7. Renderer-level duplicate Haskell declarations fail an earlier checked naming/planning gate
   with source locations if any other construction can still produce them.
8. Repeated single-spec and workspace scaffolds are byte-stable, and the generated whole-service
   conformance package passes without hand edits or runtime-only transducer composition.

## Out of Scope

- Changing Keiki's live-first replay semantics.
- Allowing replay-only edges to execute live.
- Retiring the event constructor itself; this request retains historical inversion only.
- Aggregate validation-warning policy syntax, tracked separately by
  `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-17`.
- Proving same-mode inverse candidates disjoint, tracked by
  `mori://shinzui/keiki/okf/improvement-requests/concepts/IR-5`.

## Compatibility Baseline

The request was verified against Hackage Keiro DSL 0.10.0.0 and the matching public release tags.
The repair changes only generated source and conformance for replay-only initial transitions and
non-contiguous repeated source blocks. Specs without those shapes should scaffold byte-identically;
runtime Keiki semantics and persisted wire formats do not change.

## References

- Requesting initiative:
  `mori://shinzui/mori/masterplans/23-extend-functional-keiki-aggregates-to-every-mori-domain`.
- Reproducer and consumer acceptance:
  `mori://shinzui/mori/plans/176-rewrite-the-workflow-aggregate-with-real-step-completion-and-causation`.
- Keiro DSL package: `mori://shinzui/keiro/packages/keiro-dsl`.
- Related reviewed-policy request:
  `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-17`.
- Implementation surfaces: `keiro-dsl/src/Keiro/Dsl/Harness.hs`,
  `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (`groupTransitionEntriesBySource`, transducer rendering,
  predicate verification, and behavior edge indices), and workspace service conformance.
