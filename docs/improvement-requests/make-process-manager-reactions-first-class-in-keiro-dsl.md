---
type: Improvement Request
title: Make process-manager reactions first-class in keiro-dsl
description: >-
  Support multiple typed and conditional process reactions, optional and multiple
  timers, and executable generated coordination behavior with explicit custom holes.
timestamp: 2026-09-11T14:30:01Z
requestId: IR-39
status: accepted
origin: mori://shinzui/keiro
plan: docs/plans/273-make-process-manager-reactions-first-class-in-keiro-dsl.md
relatedPlans:
  - docs/plans/279-harden-process-manager-reaction-apis-before-dsl-generation.md
---

# Improvement Request: Make Process-Manager Reactions First-Class in keiro-dsl

## Status

Accepted and planned, not yet implemented.
[Plan 273](../plans/273-make-process-manager-reactions-first-class-in-keiro-dsl.md) delivers
the DSL surface. It depends on
[Plan 279](../plans/279-harden-process-manager-reaction-apis-before-dsl-generation.md), which
hardens the runtime process-manager reaction APIs before any generation work begins.

## Context

The current process syntax describes a narrow coordination shape. In
`keiro-dsl/src/Keiro/Dsl/Parser/Coordination.hs`, `pProcess` accepts one input
record, one `on` reaction, one target aggregate type, and one timer declaration.
`pHandle` requires a self-advance command, permits zero or more dispatches, and
requires exactly one named schedule. Consequently a timer-free reaction, multiple
input event variants, conditional dispatch, or independently scheduled follow-ups
cannot be expressed directly in the process block. Field bindings are literals
or references rather than a general typed reaction expression surface.

The working fixture `keiro-dsl/test/fixtures/hospital-surge.keiro` demonstrates
this shape. `scaffoldProcess` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` generates
process identity, category, worker policy, a timer-request helper, and a firing
outcome helper. It creates a hand-owned `ProcessHoles.hs` for the action builder,
stream wiring, deadline, and firing command. The generated timer payload helper
only emits literal bindings; input-derived payload fields require handwritten
completion. A checked process declaration therefore does not yet generate the
complete reaction it describes.

There is also a runtime boundary to resolve explicitly: `ProcessManager.handle`
currently takes only input, not hydrated saga state. The saga is event-sourced,
but this does not make state-dependent dispatch available to the action builder.

## Requested Change

Extend the checked process model and generation so common event-driven
coordination can be authored completely in the DSL:

- Multiple typed input variants and reactions, with typed field mappings and
  conditional branches for self-advance, dispatch, and scheduling. Define
  unmatched-input, overlapping-guard, and intentional no-action semantics.
- Timer-free processes and reactions, plus multiple named timers with typed
  input-dependent payloads, injected-time deadlines, and firing behavior.
  Define repeated scheduling, timer identity, and cancellation/rescheduling
  semantics explicitly; do not accidentally collapse distinct follow-ups onto
  one correlation-keyed timer ID.
- Generated executable process and timer wiring for the supported declarative
  subset. Keep custom behavior as explicit, typed, versioned holes, with accurate
  coverage reporting and one owner for each behavior body.
- A documented design for state-dependent reactions. Establish whether the
  existing command path can supply the required semantics; if runtime support
  is needed, specify hydration, optimistic retry, and the authority for deciding
  which actions execute. Do not implement a separate unguarded state read that
  can dispatch from stale state.

Choose syntax and language-version gates during design. Preserve existing
language behavior and hand-owned implementations through an explicit migration
path. This request does not prescribe arbitrary effectful selection, an imperative
workflow language, or heterogeneous target aggregate dispatch. Effectful recipient
selection remains the router capability unless a separate need is demonstrated.

## Correctness and Evolution

Preserve the manager-state/timer transaction boundary and the separate target
dispatch transactions. Generated code must not imply atomic cross-stream fan-out.
Define duplicate, rejection, no-op, retry, and partial-dispatch behavior for each
new reaction form.

The existing process dispatch identity uses manager name, correlation ID, source
event ID, and positional emit index. Conditional branches, reordered reactions,
and changed dispatch lists must not silently reuse an identity for a different
action. Specify compatible identity and rollout rules before generating the new
forms; retain legacy identities where required. Apply equivalent scrutiny to
timer and fired-event identities and old payload decoding.

Carry reaction, guard, mapping, identity, timer, and policy changes through
checking, canonical identity, diff/coordination impact, source maps, and generated
conformance. Custom holes must never be reported as declaratively verified.

## Acceptance

1. A compiled example consumes at least two typed input variants and selects
   guarded reactions without handwritten action construction. It includes a
   deliberate no-action case and a process with no timers.
2. A compiled example schedules two independent named timers, preserves dynamic
   payload fields, and exercises their firing and declared lifecycle behavior.
3. Checking rejects invalid input/command/payload mappings, unknown timer names,
   unsupported state access, and ambiguous reactions according to documented
   guard rules, with source-local diagnostics.
4. A state-dependent example proves the selected actions correspond to the
   authoritative saga decision under concurrent delivery and optimistic retry.
   Any unsupported cases receive explicit diagnostics and documented boundaries.
5. Generated runtime conformance covers duplicate delivery, partial target
   success followed by retry, timer/state rollback, and timer redelivery. Mutation
   tests detect changed guards, dropped dynamic payload fields, wrong commands,
   and wrong timer or dispatch identities.
6. Diff and migration tests exercise reaction reordering, conditional dispatch
   changes, and timer payload/identity changes. Existing language fixtures and
   hand-owned holes remain compatible or receive an explicit versioned upgrade.
7. Authoring guidance distinguishes generated behavior from custom holes and
   demonstrates both a timer-free process and a multi-reaction process with timers.

## Requested Deliverables

- Checked grammar/model and language compatibility design.
- Generated process/timer behavior and any justified runtime integration.
- Evolution diagnostics, conformance and mutation coverage, and bounded scaling
  evidence for reaction/dispatch counts without unnecessary repeated hydration.
- Process authoring, custom-hole, and deployment/migration documentation.

## Related Requests

- [IR-9](make-declarative-dynamic-router-fan-out-first-class-in-keiro-dsl.md)
  delivers declarative router selection; it does not generalize process reactions.
- [IR-7](return-typed-domain-command-outcomes-and-rejection-details.md)
  supplies typed command outcomes that generated coordination should preserve.
