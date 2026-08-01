---
id: 173
slug: introduce-located-keiro-surface-syntax-and-explicit-lowering
title: "Introduce located Keiro surface syntax and explicit lowering"
kind: exec-plan
created_at: 2026-08-01T19:49:09Z
intention: "intention_01kyzdr07ge299bk2axrgwssht"
master_plan: "docs/masterplans/28-build-a-modular-source-aware-keiro-dsl-language-frontend.md"
---

# Introduce located Keiro surface syntax and explicit lowering

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, Keiro has an explicit boundary between what was written and the normalized
service graph consumed by checking and generation. Megaparsec produces a non-lossless
`SurfaceSource` whose syntax-bearing elements carry exact file, offset, line, and column spans.
`lowerSurfaceSource` deliberately converts that value into the existing `ParsedSource` and
`Grammar.Spec`. Existing callers continue using `parseSource`, `parseSpec`, and `parseSpecText`
with their 0.7 signatures and behavior.

A library test can parse a multi-line construct, inspect the exact start and end of its declaration,
lower it, and prove that the resulting semantic graph and canonical rendering equal the 0.7
baseline. The surface layer does not retain comments or whitespace and is not a formatter tree; it
provides ownership and diagnostic evidence for the modular grammar and version profiles that follow.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: define source points, spans, located values, and their invariants with focused tests.
- [ ] Milestone 2: define the surface source/spec representation and total lowering contract.
- [ ] Milestone 3: make the existing Megaparsec document parser produce and lower surface syntax.
- [ ] Milestone 4: preserve the EP-172 oracle and record the frontend boundary in the relevant ADR.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Use a separate located surface representation and keep `Grammar.Spec` as the normalized
  semantic graph.
  Rationale: ADR 16, workspace composition, fingerprints, diff, and replay all rely on source
  provenance and formatting not inhabiting `Spec`.
  Date: 2026-08-01

- Decision: Record half-open spans with exact source name, UTF-16-independent `Text` token offsets,
  and one-based line and column points; the end point is the position immediately after the final
  token owned by the construct.
  Rationale: Half-open intervals compose without ambiguity, and Megaparsec already exposes token
  offsets and source positions. `Text` offsets match the parser stream and must not be described as
  byte offsets.
  Date: 2026-08-01

- Decision: Exclude trailing whitespace/comments from syntax spans and exclude trivia from the
  surface representation.
  Rationale: Diagnostics should highlight owned syntax, while lossless edit preservation belongs to
  the later rewrite-tooling decision.
  Date: 2026-08-01

- Decision: Reuse existing `Grammar` leaf types where their parsed and semantic forms are identical,
  but give syntax distinctions that are currently erased an explicit surface type.
  Rationale: Mirroring all 1,200 lines of `Grammar.hs` would add maintenance without evidence;
  directly returning `Spec` would leave no lowering boundary. The surface tree must be only as rich
  as version gating, locations, duplicate detection, and lowering require.
  Date: 2026-08-01

- Decision: Define every new frontend-owned product record with strict, concise semantic fields,
  explicit deriving strategies, and `Generic` where appropriate.
  Rationale: `sourceOffset`, `spanStart`, and `locatedValue` would immediately recreate the record
  prefixes this frontend does not need. `DuplicateRecordFields` lets the public types share `span`,
  `value`, `source`, `start`, and `end` safely without renaming existing production records.
  Date: 2026-08-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

`keiro-dsl/src/Keiro/Dsl/Parser.hs` currently defines the complete Megaparsec frontend. Its parser
type is `Parsec ContextualParseFailure Text`; lexer helpers consume trailing whitespace and comments,
and productions call `getLoc`, which keeps only the current one-based line in `Grammar.Loc`.
`Parser.parseSource` selects a language definition, invokes `pSpec`, and returns a `ParsedSource`
whose `parsedSpec` is already `Grammar.Spec`.

`keiro-dsl/src/Keiro/Dsl/Grammar.hs` defines `Loc` as a line number. `Loc` equality deliberately
ignores the number so `parse . pretty` comparisons and semantic fingerprints do not change with
layout. The file also defines `Spec` and the declaration/node types consumed by
`Validate.hs`, `Workspace.hs`, `Scaffold.hs`, `Diff.hs`, `FoldFingerprint.hs`, and
`ReplayImpact.hs`. A “surface representation” is a parser result that still identifies source
constructs and their spans. “Lowering” is a total or explicitly failing transformation from that
surface representation to the normalized `Spec` vocabulary used downstream.

Megaparsec, located through `mori://mrkkrp/megaparsec/packages/megaparsec`, provides `getOffset` and
`getSourcePos`. Its source documents that `getSourcePos` is appropriate for attaching positions to
parsed constructs but should not be called for every token. The existing lexer consumes trivia, so
a span helper must capture an end point before the enclosing production consumes following trivia;
wrapping an arbitrary `lexeme` result would incorrectly include the next line's indentation and
comments.

EP-172 at
[docs/plans/172-freeze-the-keiro-dsl-0-7-language-frontend-contract.md](172-freeze-the-keiro-dsl-0-7-language-frontend-contract.md)
is the direct hard dependency and supplies the compatibility oracle. EP-177 was cancelled; this
plan must leave existing record selectors unchanged and applies its record conventions only to new
frontend-owned types. [ADR 16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
requires source provenance to wrap `Spec` and is the record that must be amended with this new
surface/lowering layer. [ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
requires location evidence to be used at the first sound boundary. [ADR 14](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
requires member-local locations to remain attributable after composition.


## Plan of Work

Milestone 1 adds `keiro-dsl/src/Keiro/Dsl/Source.hs` and exposes it from the library. Define
`SourcePoint`, `SourceSpan`, and `Located a`. A point carries the Megaparsec stream offset plus
one-based line and column. A span carries the source name and half-open start/end points. Smart
constructors reject an end preceding its start. Provide `startLine` for the later compatibility
projection and `mapLocated` plus the record's `value` field without making Megaparsec types part of
the public API. All product fields are strict and all three records derive `Generic` with explicit
stock deriving.

Add focused tests for a single token, a multi-line declaration, escaped Unicode text, an empty
construct marker such as the end of a preamble, and comments/trailing whitespace. Assert exact
offsets and positions. Offsets are counts in the `Text` token stream, not encoded byte offsets.

Milestone 2 adds `keiro-dsl/src/Keiro/Dsl/Syntax.hs`. Define `SurfaceSource` with the selected
`SourceLanguage`, a located `SurfaceSpec`, and the source name. `SurfaceSpec` mirrors the top-level
document order rather than the grouped lists in `Spec`: it carries context, optional module/layout
clauses, and a source-ordered list of located top-level declarations/nodes. Define surface forms only
where the current parser erases evidence needed for lowering, including repeated optional clauses,
language-feature uses, and version-sensitive transition implementation selection. Existing
`Grammar` declaration/node values may be reused inside located wrappers when there is no erased
syntax distinction.

Add `keiro-dsl/src/Keiro/Dsl/Frontend.hs`. Its `lowerSurfaceSource` validates document cardinality,
projects each relevant surface span's start line into the existing `Loc`, groups top-level items into
the fields of `Spec`, preserves `SourceLanguage`, and returns `ParsedSource`. Define a structured
`LoweringFailure` carrying a stable local code, `SourceSpan`, and message. This plan should make all
currently legal 0.7 sources lower successfully; the failure type exists for duplicate/invalid
surface evidence and for future grammar evolution, not to move semantic validation out of
`Validate.hs`.

Milestone 3 refactors `Parser.hs` without splitting it yet. Add a private `withSpan` helper that
captures the start point before a production and the end point immediately after its owned final
token, before trailing space consumption. Change the document and top-level parser result to
`SurfaceSource`/surface items, then implement `parseSurfaceSource`. Route `parseSource` through
`parseSurfaceSource` and `lowerSurfaceSource`; leave `parseSpec` and `parseSpecText` as wrappers.
Preamble selection still occurs before the selected body grammar, and feature-gate failures still
originate at their grammar productions.

Do not add one `SourceSpan` field to every semantic `Grammar` constructor. Where a nested semantic
value already carries a `Loc`, construct it during lowering from the corresponding surface span.
Where a surface value reuses an existing semantic leaf that already contains `Loc`, create it with
the projected start line in one lowering helper rather than calling `getLoc` throughout parser
productions. The test should demonstrate that surface spans have ordinary equality while lowered
`Spec` retains location-insensitive equality.

Milestone 4 runs the EP-172 oracle after each production family is converted. Add property tests
that `lowerSurfaceSource <$> parseSurfaceSource` equals `parseSource` for every accepted manifest
row, and focused span tests for declarations, mapped fields, aggregate clauses, expressions,
coordination nodes, integration nodes, queues, read models, workflows, and operations. Amend ADR 16
to state that source parsing produces located non-lossless surface syntax and lowering removes
source layout before semantic composition. Update the ADR timestamp/log and run strict profile
validation.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='source spans'
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='surface lowering'
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='frontend 0.7 compatibility'
cabal build keiro-dsl
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

The focused span and lowering suites exit zero, the complete 0.7 oracle remains green, the library
builds, and strict ADR validation accepts every record. Then run:

```bash
cabal test keiro-dsl-test --test-show-details=direct
cabal build all
```

Record exact test counts and any deliberate compatibility-wrapper deprecation warnings in this
living plan during implementation.


## Validation and Acceptance

Acceptance requires a public surface parse of a representative source to return exact half-open
spans for the preamble, context, one declaration, one nested field, one expression, and one node.
Trailing whitespace and comments are outside the owned span. Lowering that surface source returns
the same `ParsedSource` as the released compatibility entry point. The full EP-172 manifest has no
accept/reject, semantic graph, canonical render, or curated diagnostic drift. A one-member workspace
still attributes failures to the member path and line, and `Spec`/fingerprint equality remains
location-insensitive.

The plan is not complete if the “surface” API merely wraps an already constructed `Spec`, if spans
include arbitrary following trivia, if source names are lost during workspace loading, or if
downstream semantic modules begin depending on `Syntax` or Megaparsec.


## Idempotence and Recovery

The refactor is source-only and repeatable. Convert one production family at a time, leaving the
compatibility oracle green after each commit. Do not regenerate oracle expectations. If a family
cannot lower without changing `Spec`, keep its existing semantic leaf temporarily inside the surface
wrapper and record the missing distinction in Surprises & Discoveries; do not widen this plan into a
semantic redesign. ADR log updates are append-only and should be rerun through `okf log add` using
the repository's established workflow if an ADR timestamp changes.


## Interfaces and Dependencies

The resulting interface must use strict semantic fields and explicit derivations for its new types,
while leaving existing records unchanged and expressing these directions without exposing
Megaparsec:

```haskell
data SourcePoint = SourcePoint
  { offset :: !Int
  , line :: !Int
  , column :: !Int
  }
  deriving stock (Eq, Show, Generic)

data SourceSpan = SourceSpan
  { source :: !FilePath
  , start :: !SourcePoint
  , end :: !SourcePoint
  }
  deriving stock (Eq, Show, Generic)

data Located a = Located
  { span :: !SourceSpan
  , value :: !a
  }
  deriving stock (Eq, Show, Generic)

parseSurfaceSource :: FilePath -> Text -> Either FrontendFailure SurfaceSource
lowerSurfaceSource :: SurfaceSource -> Either LoweringFailure ParsedSource
parseSource :: FilePath -> Text -> Either ParseFailure ParsedSource
```

`Keiro.Dsl.Source`, `Keiro.Dsl.Syntax`, and the advanced portion of `Keiro.Dsl.Frontend` are public
library modules. Parser implementation helpers remain internal. `Keiro.Dsl.Grammar.Spec`,
`LanguageVersion.ParsedSource`, and the three 0.7 parser functions retain their types and behavior;
their existing record selectors retain their 0.7 spellings.
Use only the already bounded Megaparsec and `parser-combinators` dependencies; do not change their
bounds or add a lexer package.


## Revision Note

2026-08-01: Rebased the hard dependency from cancelled EP-177 to completed EP-172. Limited the
semantic-field convention to new frontend-owned records and restored existing record selectors to
the compatibility contract.
