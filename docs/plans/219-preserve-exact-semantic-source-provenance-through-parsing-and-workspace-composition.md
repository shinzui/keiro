---
id: 219
slug: preserve-exact-semantic-source-provenance-through-parsing-and-workspace-composition
title: "Preserve exact semantic source provenance through parsing and workspace composition"
kind: exec-plan
created_at: 2026-08-09T19:29:29Z
intention: "intention_01kzkzswbae5dan7x42gx8fv1c"
master_plan: "docs/masterplans/34-make-keiro-dsl-regeneration-semantically-local-and-source-stable-before-wide-adoption.md"
---

# Preserve exact semantic source provenance through parsing and workspace composition

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, the source-aware Keiro frontend retains exact file, line, and column spans for
aggregate states and transitions all the way through workspace loading. The normalized `Spec`
remains location-insensitive semantic data, while a separate checked `SemanticSourceIndex` can
answer where a particular state or transition is written in the current source. Reordering
workspace members or adding lines to an earlier member never changes another member's exact
source point.

This plan changes no generated output and no language syntax. It supplies the provenance boundary
that the behavior source-map generator needs without putting layout into fold, diff, replay, or
semantic equality.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-09T23:18:29Z) Milestone 1: extend aggregate surface syntax to capture exact state
  and transition spans.
- [x] (2026-08-09T23:26:01Z) Milestone 2: build a checked, file-qualified
  `SemanticSourceIndex` beside `ParsedSource` while preserving compatibility parser and `Spec`
  behavior.
- [ ] Milestone 3: compose exact member indices beside `WorkspaceSpec` without relocating points or
  changing merged semantic validation.
- [ ] Milestone 4: audit every CLI/workspace source path, update ADRs and API tests, and prove no
  generated, fold, diff, or replay drift.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- `withOwnedSpan` already trims trailing trivia around a whole parser production, so wrapping the
  complete transition parser captured live, replay-only, generated, and Hole-owned forms without
  changing clause parsing. The focused span test passed with all four adjacent transitions and a
  trailing comment excluded from the final span.


## Decision Log

Record every decision made while working on the plan.

- Decision: Keep exact spans in a separate source index and keep `Grammar.Spec` unchanged.
  Rationale: Source movement is provenance, not behavior. Putting spans into semantic values would
  contaminate equality, fingerprints, workspace composition, and every downstream fold.
  Date: 2026-08-09

- Decision: Key the preserved index by aggregate plus source-order state/transition subjects; join
  those subjects to stable behavior keys only in EP-4.
  Rationale: Parsing owns syntax positions but does not own behavior-obligation derivation. Keeping
  the join at the behavior boundary prevents the parser from duplicating behavior identity.
  Date: 2026-08-09

- Decision: Preserve relocated `Loc` and `LineMap` as compatibility projections while exact spans
  remain member-local.
  Rationale: Existing validation and diagnostic rendering depend on merged line numbers. Replacing
  them in the same step would widen risk; exact source consumers can use the new index directly.
  Date: 2026-08-09

- Decision: Make `parseSource` and `lowerSurfaceSource` projections of the new document-returning
  entry points instead of maintaining a second parse/lower route.
  Rationale: One checked parse must be the authority for both semantic data and exact provenance;
  a compatibility caller may discard the index but may not reconstruct or bypass it.
  Date: 2026-08-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

`keiro-dsl/src/Keiro/Dsl/Source.hs` defines exact half-open `SourceSpan` values with source path,
offset, and one-based line/column points. `keiro-dsl/src/Keiro/Dsl/Syntax.hs` defines the located,
non-lossless surface tree. Top-level items have spans, while nested `SurfaceElement` currently
records only fields and expressions.

`keiro-dsl/src/Keiro/Dsl/Parser/Aggregate.hs` creates `StateDecl` and `Transition` values with a
line-only `Loc`. Fields and expressions are wrapped with `withOwnedSpan`, but states and complete
transitions are not. `pTransition` already records its start offset and parses through the final
`goto`/implementation clause, so it can own an exact complete span without changing tokens.
`pStatesLine` similarly needs to wrap each complete state name plus optional terminal marker.

`keiro-dsl/src/Keiro/Dsl/Frontend/Internal.hs` lowers `SurfaceSource` to `ParsedSource`. The
current comment accurately says it removes exact locations and projects each top-level start line
into compatibility `Loc`. `ParsedSource` in `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` contains
only `SourceLanguage` and `Spec`, so the exact nested evidence becomes unreachable after lowering.

`keiro-dsl/src/Keiro/Dsl/Workspace.hs` parses each member and relocates every `Loc` into disjoint
line ranges before constructing `wsMergedSpec`. `LineMap` resolves that artificial line back to a
member and original line. `WorkspaceMember` preserves an unrelocated `Spec` but no exact columns or
surface index. The relocation is useful for existing semantic diagnostics; it is the wrong
identity for durable source anchors because a line inserted in member A shifts all merged lines in
member B.

[MasterPlan 28](../masterplans/28-build-a-modular-source-aware-keiro-dsl-language-frontend.md) and
[ADR 0016](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) established
the surface/lowering seam and deliberately excluded spans from `Spec`. This plan extends that
design rather than reversing it. [ADR 0014](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
requires semantic, order-independent workspace composition and currently documents the relocated
line map. [ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
requires exact structured frontend errors. No cross-repository ADR applies.


## Plan of Work

Milestone 1 extends only the located surface. In `Syntax.hs`, add nested source subjects for an
aggregate state and aggregate transition. In `Parser/Aggregate.hs`, wrap each state declaration and
complete transition with `withOwnedSpan`, retaining the current `StateDecl`/`Transition` values in
the aggregate. Attach an aggregate name and zero-based source-order ordinal to each nested subject
after the aggregate body has been parsed. The transition span begins at optional `replay-only` and
ends after the final owned transition clause, excluding trailing whitespace/comment. Add parser
tests for live, replay-only, generated, Hole-owned, terminal-state, and adjacent-transition forms.

Milestone 2 adds `keiro-dsl/src/Keiro/Dsl/SourceIndex.hs` and a source-aware parsed wrapper. Define
`SourceSubject`, `SourcePositionQuality`, and `SemanticSourceIndex`, with constructors enforcing a
single exact span per subject and one source file per parsed document. Extend lowering with
`lowerSurfaceDocument`, which returns the unchanged `ParsedSource` plus the checked index. Keep
`lowerSurfaceSource`, `parseSource`, `parseSpec`, and `parseSpecText` as compatibility projections
that drop only the index, not by re-parsing. Add a `parseSourceDocument` entry point used by CLI
and workspace paths. Source-less `Spec` compatibility values may carry explicit
`CompatibilityLineOnly` positions, but must never be mislabeled exact.

Milestone 3 adds the index beside workspace semantics. Extend `WorkspaceMember` with its exact
member index and `WorkspaceSpec` with their checked union, or introduce a single wrapper if that
preserves the public API more cleanly. In either shape, `loadWorkspace`, `composeWorkspace`, and
`oneMemberParsedWorkspace` must take the source-aware parsed document. File-qualify subjects before
union, reject duplicate subjects or a span whose `source` disagrees with the normalized member
path, and preserve original member line/column. Continue to build `wsMergedSpec`, relocated `Loc`,
`LineMap`, and `OwnershipIndex` exactly as today. A compatibility helper constructed from a bare
`Spec` is explicitly line-only and later source-map planning may refuse it.

Milestone 4 routes `keiro-dsl/app/Main.hs` and every single/workspace check, scaffold, diff, replay,
coverage, and explain command through one parse result without a second scan. Audit `ParsedSource`
and `composeWorkspace` constructors in tests and library code. Add equality tests proving
`parsedSpec`, `checkedWorkspace`, canonical pretty output, validation diagnostics, fold
fingerprints, diff classifications, and replay impact are unchanged when the exact index is
ignored. Amend ADR 0016 and ADR 0014 with the exact-index wrapper and compatibility line-map role.
Update the Cabal module inventory and changelog for any public API addition.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
```

Inventory source-location construction and source consumers:

```bash
mori registry show shinzui/keiro --full
rg -n 'SourceSpan|SurfaceElement|lowerSurfaceSource|ParsedSource|composeWorkspace|relocateLocs|LineMap' \
  keiro-dsl/src keiro-dsl/app keiro-dsl/test
```

Run focused frontend and workspace tests while implementing:

```bash
cabal test keiro-dsl:keiro-dsl-test --test-option=--match --test-option='semantic source index'
cabal test keiro-dsl:keiro-dsl-test --test-option=--match --test-option='workspace source provenance'
```

Run the compatibility and full gates before closure:

```bash
cabal build keiro-dsl
cabal test keiro-dsl:keiro-dsl-test
scripts/check-conformance-corpus.sh
just check-adr
git diff --check
git status --short
```

The source-index tests should print exact member-local lines and columns before and after earlier
member insertions. The corpus policy must remain byte-clean because no emitter consumes the new
index in this plan.


## Validation and Acceptance

Parsing one aggregate with two states and multiple live/replay-only transitions yields one exact,
file-qualified span per state and transition ordinal. Each span owns exactly its syntax tokens and
reports the current one-based start column. Malformed or overlapping surface ownership fails in
the existing lowering phase with a stable structured frontend error.

Composing `a.keiro` and `b.keiro` preserves B's source paths, lines, and columns in the exact index.
Adding comments or declarations to A changes A's spans and the artificial bases in `wsLineMap`, but
does not change any B exact span. Reordering manifest member lines produces the same canonical
workspace semantics and the same file-qualified index after canonical member sorting.

The `Spec` produced through compatibility `parseSource` is equal to today's `Spec`; canonical
rendering, validation diagnostics, fold fingerprint, diff, replay impact, and generated corpus
bytes remain unchanged. Single-file and one-member-workspace exact indices agree after normalizing
the member path. A bare-`Spec` compatibility constructor exposes line-only quality rather than a
fabricated exact column.

All focused and full tests, ADR validation, corpus policy, and diff hygiene pass. No generated
fixture changes are accepted in this plan.


## Idempotence and Recovery

Parsing, lowering, and composition are pure and repeatable. The exact index is reconstructed from
source on every command; it is not cached in scaffold history. A failed index validation returns
before semantic checking or scaffold planning and writes nothing.

If a public compatibility wrapper cannot provide exact positions, preserve it as an explicitly
line-only semantic helper and route production CLI paths through the exact API. Do not silently
fill column 1 and call it exact. If parity tests expose a semantic change, stop and repair surface
lowering rather than updating frozen parser/generation goldens.


## Interfaces and Dependencies

No new dependency; use existing `containers`, `text`, and source/frontend types. The final
interface must be equivalent to:

```haskell
newtype TransitionOrdinal = TransitionOrdinal Int
  deriving stock (Eq, Ord, Show)

data SourceSubject
  = AggregateStateSubject Name Name
  | AggregateTransitionSubject Name TransitionOrdinal
  deriving stock (Eq, Ord, Show)

data SourcePositionQuality
  = ExactSourcePosition
  | CompatibilityLineOnly
  deriving stock (Eq, Ord, Show)

data SemanticSourceIndex

data ParsedSourceDocument = ParsedSourceDocument
  { documentParsedSource :: !ParsedSource
  , documentSourceIndex :: !SemanticSourceIndex
  }

parseSourceDocument ::
  FilePath ->
  Text ->
  Either ParseFailure ParsedSourceDocument

lookupSourceSpan ::
  SourceSubject ->
  SemanticSourceIndex ->
  Maybe (SourcePositionQuality, SourceSpan)
```

The exact storage representation may use maps nested by aggregate, but constructors must preserve
duplicate detection and deterministic ordering. EP-4 is the hard downstream consumer. Neither
`Spec` nor `CheckedService` gains source-location fields, and no source point enters a canonical
encoding or fingerprint.
