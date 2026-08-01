---
type: Improvement Request
title: Make nominal ID and enum equality first-class in aggregate expressions
description: >-
  Let generated and consumer-bound IDs and enums participate in type-safe equality guards without
  forcing Text shadow registers or hand-owned behavior holes.
timestamp: 2026-08-01T18:05:45Z
requestId: IR-12
status: implemented
origin: mori://shinzui/mori
plan: docs/plans/170-make-nominal-id-and-enum-equality-exact-in-aggregate-expressions.md
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-07-31T23:44:22Z
    document_timestamp: 2026-07-31T23:44:22Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      In-repository review of AggregateType capabilities, expression validation, version-2
      transducers, nominal bindings, Keiki symbolic domains, and Mori's aggregate identity model.
---

# Improvement Request: Make Nominal ID and Enum Equality First-Class in Aggregate Expressions

## Status

**Implemented.**
[Plan 170](../plans/170-make-nominal-id-and-enum-equality-exact-in-aggregate-expressions.md)
under [MasterPlan 27](../masterplans/27-repair-the-keiro-dsl-0-6-language-nominal-generation-and-workspace-regressions.md)
adds declaration-scoped ID/enum equality through Keiki `0.7.0.0`. Consumer `KindID` IDs and all
enums have exact domains and reconstructible symbolic models; legacy generated IDs gain type-safe
concrete equality while remaining conservatively one-way until Plan 171 restricts their public
construction domain. Checked metadata drives capabilities, generated witnesses, fingerprints,
scaffold/workspace records, binding explanations, and conformance. Type-confusion, solver-domain,
replay, workspace, and dishonest-exact-projection mutations cover the boundary.

## Context

Keiro 0.6 classifies ID and enum representations as `OpaqueOnly`. Version-2 aggregate guards can
compare solver-visible scalar values, but cannot express the most basic nominal checks:

- a command's `ProjectId` equals the aggregate's `ProjectId`;
- a requested artifact kind equals a stored `ProjectArtifactKind`; or
- an optional nominal value equals a constructor or another value of the same type.

Consumers consequently model identity-bearing values as `Text`, maintain a parallel textual
register, or move an otherwise declarative transition into a hand-owned hole. Mori's current
ProjectArtifact model uses a textual artifact identity for this reason. That weakens the schema at
exactly the boundary where nominal types should prevent cross-identity mistakes.

Consumer-owned nominal bindings make generic symbolic execution harder, but that implementation
constraint should be represented by an explicit equality witness or symbolic isomorphism—not by
silently making ordinary typed equality unavailable.

## Requested Change

Define equality capabilities for generated and consumer-bound IDs and enums. Generated nominal
types should have canonical symbolic representations. A consumer binding should be able to supply
a total symbolic equality witness, projection, finite-constructor mapping, or equivalent contract
that Keiro and Keiki can verify and use consistently in checking, harness generation, replay, and
generated transducers.

Equality must remain type-safe: values from different ID or enum declarations cannot compare even
if their runtime representation is the same. Ordering and arithmetic are outside this request.

## Acceptance

1. A guard can compare two values of the same generated ID type and two values of the same enum.
2. Enum literals in expressions are qualified and checked against the expected enum declaration.
3. Cross-ID, cross-enum, ID-to-Text, and enum-to-Text comparisons fail at the expression site.
4. Consumer-bound IDs and enums can opt into equality through one explicit, total binding contract.
5. The generated behavior harness verifies both equal and unequal paths and attributes failures to
   the declaring guard.
6. Fingerprints and compatibility reports include the nominal equality representation or witness
   where changing it can alter accepted commands.
7. A fleet fixture removes a Text shadow register from a real multi-state aggregate without adding
   a behavior hole.

## Requested Deliverables

- A nominal equality capability and checked expression representation.
- Released Keiki 0.7 integration for exact symbolic equality and reconstructible counterexample
  attribution, using `>=0.7 && <0.8` after repeating Hackage/tag verification.
- Binding/scaffold support for consumer-owned equality witnesses.
- Positive, type-confusion, replay, mutation, and fleet-adoption tests.
- Authoring guidance for generated and consumer-owned nominal types.
