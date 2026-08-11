---
type: Improvement Request
title: Make declarative dynamic router fan-out first-class in keiro-dsl
description: >-
  Let checked specs describe common data-dependent recipient selection and dispatch policy instead
  of leaving every dynamic router as an unconstrained effectful resolver hole.
timestamp: 2026-07-31T15:03:57Z
requestId: IR-9
status: completed
origin: mori://shinzui/keiro
plan: docs/plans/230-make-declarative-dynamic-router-fan-out-first-class-in-keiro-dsl.md
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-07-31T15:03:57Z
    document_timestamp: 2026-07-31T15:03:57Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      In-repository review of RouterNode grammar and generated resolver holes. Keiro runtime has
      effectful stable-union routing, but the DSL cannot validate the recipient-set computation.
---

# Improvement Request: Make Declarative Dynamic Router Fan-Out First-Class in `keiro-dsl`

## Status

**Implemented.**
[Plan 230](../plans/230-make-declarative-dynamic-router-fan-out-first-class-in-keiro-dsl.md)
delivers the candidate Language 5 checked selection grammar, bounded runtime,
generated router and harness, PostgreSQL conformance, mapped semantic and
coordination impact, durable selection ledgers, and authoring/evolution
guidance. Existing typed resolver holes remain the explicit
`custom-unverified` escape hatch.

[ADR 30](../adr/0030-declarative-router-selection-is-bounded-target-normalized-and-coordination-versioned.md)
records the durable normalization, stable-union, frozen dispatch-identity, and
selection-version decisions.

## Context

The runtime supports data-dependent effectful fan-out and protects retry with stable target
identities. The DSL can scaffold a router and name a read-model or typed resolver source, but the
actual recipient calculation remains consumer-owned code. Consequently `check`, diff, generated
conformance, and replay-impact reporting cannot describe changes to common selection predicates,
ordering, caps, empty-recipient policy, or target identity projection.

## Requested Change

Add a bounded declarative router-selection sublanguage for common read-model queries and typed
filter/map recipient construction. Specify stable ordering/deduplication, recipient caps, empty and
partial failure policy, versioned resolver identity, diff/replay impact, and a generated fallback
hole for operations outside the safe sublanguage.

## Acceptance

1. A spec can declare a finite data-dependent recipient set and scaffold a working router without
   hand-writing the selection body.
2. Check rejects unstable identity, unbounded fan-out, ambiguous ordering, and unsupported query
   behavior before scaffolding.
3. Redelivery under changed query results follows a documented stable-union/version policy and
   never silently double-dispatches a target.
4. Diff reports selection/identity/policy changes with coordination replay impact.
5. Effectful custom holes remain explicit and are never reported as declaratively verified.

## Requested Deliverables

- Selection grammar, checked model, and compatibility semantics.
- Runtime/generated router integration and conformance harness.
- Boundedness, drift, redelivery, and negative tests.
- Router authoring/evolution documentation.
