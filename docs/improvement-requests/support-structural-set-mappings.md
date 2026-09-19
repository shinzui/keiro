---
type: Improvement Request
title: Support structural set mappings
description: >-
  Support structural set mappings while preserving explicit codec ownership and historical compatibility.
timestamp: 2026-09-19T21:32:21Z
requestId: IR-44
status: proposed
origin: mori://shinzui/rei
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

# Support structural set mappings

## Problem and evidence

Rei's TextSet is Set Text, and MaybeTextSet is its optional form. Existing codecs
write arrays in element order. Mapping a Set through List is not a total isomorphism:
duplicates and order in the list disappear when converted to a set.

Keiro's TypeExpr supports List and Map but has no Set constructor. This is a stored
shape request; it does not request collection guards or mutation.

## Requested behavior

Provide a checked set shape with explicit element identity, ordering, encoding, and
duplicate-input policy. Begin with Text elements if necessary. The generated shape must
represent a set, rather than claim a bijection between arbitrary lists and sets.

## Acceptance criteria

- Define canonical array order and whether decoding duplicate or unordered input rejects
  or normalizes it. Make this codec policy explicit and compatibility-visible.
- Require sound element equality/ordering evidence; do not generalize to arbitrary mapped
  values whose consumer ordering can disagree with the declared representation.
- Preserve the total binding laws at the set shape boundary.
- Support empty and optional sets and test permutations, duplicates, and encoding stability.
- Integrate language gating, codec generation, imports, fixtures, coverage, recursive
  fingerprints, usage-aware diff, snapshot invalidation, and compiled conformance.
- Compare with Rei's actual Aeson Set behavior, including historical input acceptance.
  A stricter decoder must be reported as a migration consequence.
- Keep whole-value storage and replay separate from unsupported symbolic collection operations.

## Dependencies

[IR-42](support-bare-container-structural-mappings.md) provides the named bare-shape
mechanism; set semantics need their own checked constructor.

## Consumer evidence

Source: mori://shinzui/rei, project-relative files domain/shared.keiro and
rei-core/src/Rei/Domain/KeiroShapes.hs (artifact-level URIs pending).
Review basis: local Keiro source at b284379c and the consumer declarations inspected
on 2026-09-19. This request is proposed work, not independent review or implementation evidence.
