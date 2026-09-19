---
type: Improvement Request
title: Support explicit legacy ID admission domains
description: >-
  Support explicit legacy ID admission domains while preserving explicit codec ownership and historical compatibility.
timestamp: 2026-09-19T21:32:21Z
requestId: IR-46
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
on 2026-09-19. This request is proposed work, not independent review or implementation evidence.
