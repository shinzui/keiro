---
type: Improvement Request
title: Support explicit legacy ID admission domains
description: >-
  Support explicit legacy ID admission domains while preserving explicit codec ownership and historical compatibility.
timestamp: 2026-09-19T22:13:18Z
requestId: IR-46
status: in-progress
origin: mori://shinzui/rei
plan: docs/plans/294-add-explicit-versioned-uuid-admission-domains-with-sound-keiki-evidence.md
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

# Support explicit legacy ID admission domains

## Problem and evidence

Rei keeps ActionId, TaskId, and LinkId opaque because stored identifiers include UUIDv5,
while Keiro's declared ID domain admits TypeID-v7 only. Some producers still derive
UUIDv5 identifiers, so this is not solely a decode-old-history issue.

IR-14 established enforceable, versioned ID admission. This request extends that work
with explicit alternative domains; it does not relax existing declarations globally.

## Requested behavior

Allow a declaration to select an explicit versioned admission domain covering its actual
identifier population, such as canonical prefixed UUIDv5 and UUIDv7 values. Preserve
prefix checks, canonical representation, nominal identity, and total consumer bindings.
Separate admitted historical values from generation policy where needed.

## Acceptance criteria

- Specify supported UUID versions, variant checks, canonical text, prefix, domain identity,
  and generation policy. Existing declarations retain their current v7 default and behavior.
- Reject malformed, wrong-prefix, wrong-variant, and undeclared-version identifiers.
- Define equality and structural/map-key behavior from canonical identity, with conformance
  for generated and consumer-bound values.
- Track admission-domain changes through codec identity, fingerprints, snapshots, nested
  use paths, and compatibility reports. Widening can still break old readers of new writes.
- Verify historical and newly produced UUIDv5/v7 examples for Rei before replacing opaque
  declarations; never rewrite stored identifiers as an implicit migration.
- Ensure structural leaves and public contract uses preserve the selected domain or
  explicitly reject unsupported uses; avoid silently applying the v7 codec.
- Test mixed-version fixtures, language gating, workspace generation, and runtime decoding.

## Related work

[IR-14](make-id-prefix-declarations-enforceable-and-evolution-safe.md) owns the original
enforceable ID contract; [IR-40](support-nominal-ids-inside-structural-mapped-types.md)
owns structural nominal composition. This request preserves both contracts.

## Consumer evidence

Source: mori://shinzui/rei, project-relative files domain/shared.keiro and
rei-core/src/Rei/Domain/KeiroShapes.hs (artifact-level URIs pending).
Review basis: local Keiro source at b284379c and the consumer declarations inspected
on 2026-09-19.

## Implementation and adoption status

Plan 294 implements explicit TypeID UUIDv5-or-v7 admission with one runtime and
symbolic character authority, structural and keyed-map propagation, exact owner
reconstruction, public contracts, and mixed-history replay. Plan 295's integrated
repository replay suite is also green. Adoption by `mori://shinzui/rei` remains
pending an authorized read-only export or isolated restored copy and independent
baseline/candidate capture; repository fixtures are not consumer history.
