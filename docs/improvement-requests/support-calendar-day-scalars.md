---
type: Improvement Request
title: Support calendar-day scalars
description: >-
  Support calendar-day scalars while preserving explicit codec ownership and historical compatibility.
timestamp: 2026-09-19T21:32:21Z
requestId: IR-43
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

# Support calendar-day scalars

## Problem and evidence

Rei's LocalDay is Data.Time.Calendar.Day, encoded by its existing Aeson instance as
a bare date string. MaybeLocalDay carries optional due dates. Time means UTCTime,
so it cannot replace a date without inventing an instant and timezone.

Keiro's direct scalar registry and structural TypeExpr have no calendar-day constructor.
The current nominal scalar representations cannot express Day through a total Text
isomorphism: arbitrary text is not a valid calendar date.

## Requested behavior

Add a checked calendar-day scalar with a precisely documented date representation.
Support it in structural mappings and bare optional mappings; determine explicitly
whether direct aggregate fields and nominal wrappers are included in the same release.
Preserve whole-value transport without requiring new symbolic date operations.

## Acceptance criteria

- Specify canonical output, accepted input, calendar system, year range, extended-year
  behavior, and rejection of invalid dates. Verify against the actual Day codec used
  by consumers before claiming byte or decode parity.
- Keep calendar dates distinct from instants: no timezone conversion or midnight coercion.
- Implement type checking, Haskell lowering, deterministic samples and register initials,
  generated codecs, fingerprints, coverage, diff, and conformance for every admitted use.
- Test leap days, invalid dates, boundary years, and optional nulls.
- Demonstrate LocalDay and MaybeLocalDay migration against Rei fixtures and stored data.
- Version the language capability and classify changes to date admission/encoding.
  Do not silently add equality, ordering, or arithmetic beyond proven capabilities.

## Dependencies

Bare optional date mappings depend on
[IR-42](support-bare-container-structural-mappings.md).

## Consumer evidence

Source: mori://shinzui/rei, project-relative files domain/shared.keiro and
rei-core/src/Rei/Domain/KeiroShapes.hs (artifact-level URIs pending).
Review basis: local Keiro source at b284379c and the consumer declarations inspected
on 2026-09-19. This request is proposed work, not independent review or implementation evidence.
