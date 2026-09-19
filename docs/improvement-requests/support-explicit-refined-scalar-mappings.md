---
type: Improvement Request
title: Support explicit refined scalar mappings
description: >-
  Support explicit refined scalar mappings while preserving explicit codec ownership and historical compatibility.
timestamp: 2026-09-19T21:32:21Z
requestId: IR-45
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

# Support explicit refined scalar mappings

## Problem and evidence

Rei's TaskContentHash and EmbedHash are byte-backed values with base16 JSON encodings.
They cannot use nominal Text bindings honestly: decoding arbitrary Text may fail, and
normalization can prevent a reverse round trip.

ADR 0012 explicitly excludes rejecting, normalizing, or quotienting constructors from
total nominal bindings and calls for a separately designed, diff-visible refined mode.

## Requested behavior

Design a separate refined scalar contract for validated representations. Start with a
bounded declarative refinement, such as base16-encoded bytes, if arbitrary consumer
predicates cannot yield truthful compatibility evidence. Keep existing nominal and
structural total-binding laws unchanged.

## Acceptance criteria

- Specify the admitted representation domain, canonical encoder, decoder failures,
  normalization policy, and laws over admitted/canonical values.
- Declare which rules Keiro owns and can compare structurally. If arbitrary validation
  callbacks are allowed, version them and report their compatibility as unverified;
  do not certify them from finite fixtures alone.
- Make domain narrowing, widening, normalization, and encoding changes visible to
  compatibility analysis with historical-read and rolling-writer consequences.
- Generate typed failures, codecs, samples/fixtures, provenance, coverage, and snapshot
  identity consistently across all admitted use sites.
- Exercise empty values, malformed base16, case policy, and any declared length constraints.
  Do not impose a digest length absent from the consumer's actual contract.
- Prove historical codec parity for Rei's hashes before replacing opaque mappings.
- Define non-null evidence before allowing Optional refinement composition.
- Preserve older language behavior and avoid granting symbolic operations from the
  representation alone.

## Related work

ADR 0012's refined-mode deferral is the basis for this request.
[IR-42](support-bare-container-structural-mappings.md) is complementary for optional values.

## Consumer evidence

Source: mori://shinzui/rei, project-relative files domain/shared.keiro and
rei-core/src/Rei/Domain/KeiroShapes.hs (artifact-level URIs pending).
Review basis: local Keiro source at b284379c and the consumer declarations inspected
on 2026-09-19. This request is proposed work, not independent review or implementation evidence.
