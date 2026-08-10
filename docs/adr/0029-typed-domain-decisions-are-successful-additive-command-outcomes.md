---
type: Architecture Decision Record
title: Typed domain decisions are successful additive command outcomes
description: Keiro preserves accepted event batches and typed rejection/no-op payloads as successful results while unmatched commands and infrastructure failures remain CommandError.
timestamp: 2026-08-10T18:56:01Z
docId: ADR-29
status: Accepted
date: 2026-08-10
---

# 29. Typed domain decisions are successful additive command outcomes

Date: 2026-08-10

Status: Accepted


## Context

The historical command API reports persistence metadata but erases the domain
values that produced it. An eventful command returns only `CommandResult`; a
selected edge that emits no events is visible only as zero appended events; and
a command for which no edge matches returns the nullary `CommandRejected`.
Applications that need an `AlreadyCancelled`, `InsufficientCapacity`, or
`DuplicateRequest` value would otherwise duplicate command evaluation or build
a parallel decision model that can disagree with Keiki.

Keiki already selects an exact live edge and returns its ordered output word
through `stepDetailedEither` in
`mori://shinzui/keiki/packages/keiki`. That selected edge is the only sound
classification authority. Re-evaluating guards to derive a result would create
a second command decision and could diverge from the events appended.

Business refusal is operationally different from failure. A deliberately
selected rejection or no-op may be expected and safe to acknowledge, while a
missing transition, ambiguous definition, decode/encode failure, store failure,
or exhausted concurrency retry needs existing failure policy. Application
payloads can also be sensitive or high-cardinality and do not belong in
telemetry dimensions or generic dead-letter reasons.


## Decision

Keiro exposes an additive `DomainCommandHandler` and domain-aware runner family.
A successful selected command returns `DomainCommandOutcome`, pairing ordinary
`CommandResult` metadata with exactly one strict `DomainDecision`:

- `DomainAccepted (NonEmpty event)` owns the exact ordered event values encoded
  and appended by the successful attempt;
- `DomainRejected rejection` is an application-defined refusal from an
  explicitly selected state-preserving live edge with no output;
- `DomainNoOp noOp` is an application-defined successful no-op from the same
  kind of selected silent edge.

The pure silent classifier receives the pre-command state/registers, command,
and exact selected `EdgeRef` only after Keiki has selected one live edge with an
empty output word. It does not select an edge, inspect failed guards, or perform
effects. Validated event streams continue to reject eventless durable state
changes. Replay-only edges never handle forward commands and cannot produce a
domain decision.

No outgoing edge and no matching edge remain `Left CommandRejected`.
Ambiguity, hydration, encoding, store, conflict-fixpoint, and retry-exhaustion
failures remain their existing `CommandError` values. Typed rejection and no-op
remain on the successful `Right` side. `forgetDomainDecision` erases a
successfully selected domain decision to its historical `CommandResult`; it
cannot erase an unmatched error because that error remains outside the outcome.

Optimistic conflicts discard the attempted decision and restart from hydration.
Only the final successful evaluation is returned. Transactional callbacks,
inline projections, snapshots attributable to an append, and catalog fencing
run only for accepted event batches. Rejection and no-op open no append
transaction and provide no durable side-effect boundary. A catalog fence that
rolls back an accepted append is represented separately and does not fabricate
a committed domain outcome.

Domain-aware routers and process managers are parallel public families rather
than changes to existing configurations and results. Accepted, rejected, and
no-op target decisions are handled. Typed rejection/no-op acknowledges normally
and bypasses generic rejected-command policy. A genuine `CommandError` retains
the existing retry, halt, skip, and dead-letter policy. Confirmed accepted
redelivery is a distinct duplicate: its deterministic event id proves the
append, but cannot reconstruct the original in-memory event values. Silent
decisions have no idempotency event and may be re-evaluated on redelivery.

Detailed one-shot outcomes own the accepted values they return. Coordinator
workers instead fold each target strictly into only acknowledgement/failure
information and release handled payloads before continuing. Telemetry exposes
only `keiro.command.decision = accepted | rejected | no_op` and the counter with
that same closed dimension. Application payload values are not error types,
span descriptions, labels, logs, or dead-letter reasons.

All historical `runCommand*`, projection, router, and process-manager entry
points retain their types and legacy result allocation path. The DSL consumes
this runtime contract in the follow-up
[ExecPlan 232](../plans/232-add-typed-domain-outcomes-to-the-dsl.md); it does not
define a second generated outcome type.


## Consequences

- Application boundaries can exhaustively pattern-match accepted, rejection,
  and no-op without encoding a reason as an event or exception.
- The accepted result extends the lifetime of its event values until the caller
  releases it. This ownership cost belongs only to outcome-aware callers; the
  legacy path does not manufacture wrappers or reason values.
- A selected silent edge is now observably different from an unmatched
  command. Aggregate authors must model intentional refusal/no-op transitions
  explicitly and keep their classifiers pure.
- Rejection/no-op cannot run durable callback or projection effects because
  there is no append transaction. If an effect is required, model an accepted
  event.
- Coordinator callers choosing detailed one-shot APIs accept memory
  proportional to returned batches. Worker APIs are the bounded-retention path
  when only acknowledgement policy is required.
- Exact accepted payload recovery is intentionally unavailable for duplicate
  dispatch. Adding a cache or schema solely to recreate it would introduce a
  second result authority.
- Existing applications remain source-compatible and may adopt the typed
  runner family one aggregate or coordinator at a time.


## References

- [ExecPlan 231](../plans/231-add-typed-domain-command-outcomes.md) implements
  and validates the runtime contract.
- [ExecPlan 232](../plans/232-add-typed-domain-outcomes-to-the-dsl.md) owns DSL
  syntax, generation, and exact-reason conformance.
- [ADR 2](0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md)
  keeps replay-only edges outside forward command handling.
- [ADR 4](0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
  keeps eventless state preservation enforced at the validated stream boundary.
- [ADR 17](0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
  establishes exact edge identity and rejects eventless state changes.
