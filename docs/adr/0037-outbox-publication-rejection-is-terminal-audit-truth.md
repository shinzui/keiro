---
type: Architecture Decision Record
title: Outbox publication rejection is terminal audit truth
description: A publisher may durably reject an outbox message without retry; rejection releases ordered successors, retains bounded audit data, and preserves an at-least-once pre-commit callback boundary.
timestamp: 2026-08-21T15:26:23Z
docId: ADR-37
status: Accepted
date: 2026-08-21
originatingPlan: docs/plans/165-add-terminal-outbox-publication-rejection-outcomes.md
---

# 37. Outbox publication rejection is terminal audit truth

Date: 2026-08-21

Status: Accepted


## Context

An outbox transport can permanently refuse a message because its destination is
invalid, authorization is denied, or the sink cannot represent the event. Treating
that decision as `sent` falsely claims delivery. Treating it as transient failure
spends retry budget on work that cannot succeed and can block every ordered successor.
Treating it as `dead` loses the distinction between an intentional transport decision
and retry exhaustion.

The transport call and PostgreSQL finalization are not one atomic resource. A process
can call the transport and fail before its database transaction commits. Keiro must
retain its existing at-least-once callback boundary while making the durable transition
idempotent and its reported progress truthful under races with stale-claim recovery.


## Decision

`PublishRejected` is a third publication outcome, distinct from success and transient
failure. It carries an opaque, validated rejection with a stable code and optional
human detail. Codes contain 1–64 lowercase ASCII characters matching
`[a-z][a-z0-9._-]*`. Present detail is non-empty and at most 1024 UTF-8 bytes. Invalid
data is refused before any database statement; values are never silently normalized,
truncated, or copied into metric attributes.

A committed rejection changes a row from `publishing` to terminal `rejected`, records
its timestamp, code, and optional detail, clears stale transient error text, and
retains the row for audit. It does not schedule another attempt or consume additional
retry budget. Rejected rows are excluded from claims, stale-publisher recovery,
backlog counts, and sent-row garbage collection.

Rejection releases ordered successors. Per-key and per-source policies treat it as a
terminal head. `StopTheLine` continues after rejection and stops only on transient
`PublishFailed`. This makes a handled permanent disposition complete work rather than
turning it into a permanent queue barrier.

One claimed batch finalizes sent, rejected, failed, and skipped rows in one database
transaction. Every transition is conditional on the row still being `publishing`.
Pass summaries and the unlabelled rejection counter count affected rows that committed,
not callback outcomes that merely occurred. A stale-publisher reclaimer may win the
race; that produces a visible gap between claimed and completed counts instead of
restating the callback decision as durable success.

Keiro guarantees exactly one committed terminal row transition, not exactly-once
external delivery. If the process or finalization transaction fails after the callback,
the row remains recoverable and the callback may run again. Transport adapters must
therefore make both delivery and terminal-rejection decisions idempotent by message
identity.


## Consequences

- Durable rows distinguish transport acknowledgement, intentional refusal, transient
  failure, and retry exhaustion without overloading one state.
- Permanent refusal cannot wedge later messages in an ordered stream.
- Operators can inspect bounded rejection evidence, while metrics remain safe from
  free-form or unbounded label cardinality.
- `PublishOutcome`, `OutboxStatus`, `OutboxRow`, and `OutboxPublishSummary` gain public
  constructors or fields, so the change requires a shared PVP-major package release.
- A callback can be observed more than once before finalization commits. Adapters that
  cannot tolerate redelivery remain incompatible with the outbox contract.


## References

- [ADR 0025](0025-worker-loops-isolate-failures-per-pass-and-per-item-and-report-partial-progress.md)
  defines why summaries count committed work rather than selected or attempted work.
- [ExecPlan 165](../plans/165-add-terminal-outbox-publication-rejection-outcomes.md)
  records implementation and release evidence.
- `mori://shinzui/shikigami/plans/19-sink-delivery-truth-and-downstream-idempotency`
  is the downstream plan that requires truthful terminal rejection semantics.
