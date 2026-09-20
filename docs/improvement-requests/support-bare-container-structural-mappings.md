---
type: Improvement Request
title: Support bare container structural mappings
description: >-
  Support bare container structural mappings while preserving explicit codec ownership and historical compatibility.
timestamp: 2026-09-19T22:13:18Z
requestId: IR-42
status: in-progress
origin: mori://shinzui/rei
plan: docs/plans/290-support-named-bare-container-structural-mappings-with-transitive-nullability.md
relatedPlans:
  - docs/plans/289-gate-mapping-evolution-with-serialized-and-cross-version-replay-evidence.md
  - docs/plans/295-rehearse-checked-mapping-adoption-against-historical-streams-and-workflow-journals.md
reviews:
  - kind: model
    reviewer: codex-author
    reviewed_at: 2026-09-19T21:32:21Z
    document_timestamp: 2026-09-19T21:32:21Z
    scope: technical-accuracy
    outcome: commented
    provider: openai
    model: unspecified
    effort: unspecified
    context: >-
      Author self-review against local Keiro b284379c: Grammar, Parser/Mapped,
      TypeGraph, AggregateType, ConsumerTypePlan, ADR 0012, and consumer declarations
      in mori://shinzui/rei. Proposed acceptance criteria, not independent review,
      implementation verification, or proof of historical codec parity.
---

# Support bare container structural mappings

## Problem and evidence

Rei's shared declarations use opaque mappings for Maybe Text, Maybe Int, Maybe Bool,
Maybe UTCTime, lists of Text and Int, and Map Text Text. Their wire values are bare
nullable values, arrays, and objects. An extra structural record would change those bytes.

At Keiro b284379c, keiro-dsl/src/Keiro/Dsl/Grammar.hs defines MappedShape with only
ShapeRecord, ShapeEnum, and ShapeUnion; Parser/Mapped.hs and TypeGraph.hs preserve
that restriction. TypeExpr and ConsumerTypePlan already support recursive Optional,
List, and Map expressions. The original structural work scoped declarations to records,
enums, and unions; no explicit rejection of bare container mappings was found.

## Requested behavior

Add a named structural mapping whose entire wire shape is a checked type expression,
initially Optional T, List T, and text-keyed Map T. Preserve the consumer Haskell type
through the existing total StructuralBinding contract. Concrete syntax is a design
decision; examples here describe semantics, not accepted syntax.

A mapping from MaybeText to Optional Text must write null or the bare string; TextList
to List Text must write an array; TextMap to Map Text must write an object with string
keys. Retain named mappings at aggregate use sites and the existing restrictions on
collection operations.

## Acceptance criteria

- Parse, print, resolve, and generate each bare container shape, including nested
  admissible expressions and references to existing structural and nominal declarations.
- Generate the authoritative codec and typed binding, with fixtures proving both binding
  laws and expected JSON. Ordered lists retain duplicates; maps retain text keys.
- Apply nullability checks through references: reject nullable inner shapes where null
  collapses alternatives, including Optional (Optional Text) and nullable opaque leaves.
  Distinguish a present null from an absent enclosing event field; do not invent field
  presence semantics or claim to repair Rei's historical MaybeMaybeText ambiguity.
- Integrate fingerprints, recursive dependency paths, usage-aware diff, snapshot
  invalidation, coverage, scaffold ledgers, and compiled workspace conformance.
- Compare old consumer codecs with generated codecs over Rei fixtures and historical
  events before adoption. Switching an opaque declaration to structural must retain
  explicit compatibility review; do not assume matching type names prove parity.
- Gate new syntax by language capability and keep published older-language behavior stable.

## Related work

ADR 0012 defines codec ownership and total bindings. Plans 149 and 288 establish
the current declaration surface and retain the direct-container restriction.
This request adds a structural declaration shape, not direct aggregate containers.

## Consumer evidence

Source: mori://shinzui/rei, project-relative files domain/shared.keiro and
rei-core/src/Rei/Domain/KeiroShapes.hs (artifact-level URIs pending).
Review basis: local Keiro source at b284379c and the consumer declarations inspected
on 2026-09-19.

## Implementation and adoption status

Plan 290 implements and compiles named bare Optional, List, and text-keyed Map
mappings with recursive nullability, total bindings, diff/replay consequences,
and historical codec fixtures. Plan 295's integrated repository replay suite is
also green. Adoption by `mori://shinzui/rei` remains pending an authorized
read-only export or isolated restored copy and independent baseline/candidate
capture; repository fixtures are not consumer history.
