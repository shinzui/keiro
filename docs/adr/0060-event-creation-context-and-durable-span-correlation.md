---
type: Architecture Decision Record
title: Event creation context and durable span correlation
description: Commands stamp W3C creation context once per run and durable consumers correlate through evaluated span identities without changing replay.
timestamp: 2026-11-14T22:59:20Z
docId: ADR-60
status: Accepted
date: 2026-11-14
originatingPlan: docs/plans/331-stamp-trace-context-on-appended-events-and-name-command-spans-by-category.md
---

# Event creation context and durable span correlation

## Context

Durable event consumers can execute long after the command that caused their work.
A business identifier does not identify the execution that created an event, and making
all delayed work a child of an old trace is often inappropriate. The Kiroku adapter already
reads top-level W3C keys from event metadata. Domain replay and deterministic identifiers
are frozen by [ADR-18](0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md)
and [ADR-24](0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md).

## Decision

With an explicitly configured command tracer, capture the active command span once before
its optimistic retry loop. Store its W3C `traceparent` and optional `tracestate` at the top
level of every appended event's metadata. The shared `Keiro.Telemetry` helpers own these keys,
metadata stamping and link decoding. Preserve a caller's existing `traceparent` unchanged.
Otherwise replace an orphaned caller `tracestate` with the captured context's matching state.
Leave non-object metadata unchanged so the codec's existing validation still applies.

Without a configured tracer, commands pass their original options through without context
capture, decoding or metadata construction, even inside an ambient span. Metadata is advisory:
it changes neither domain replay, duplicate detection, deterministic identifiers nor snapshots.
Producer outbox equality already includes trace headers and remains strict under
[ADR-42](0042-producer-outbox-identity-is-a-versioned-source-event-contract.md); downstream
adoption must use [ADR-59](0059-durable-trace-correlation-preserves-replay-and-exact-wake-identity.md).

Links are the correlation mechanism across durable boundaries. A single-message consumer
can additionally use the source adapter's parent policy. Later boundary implementations
extend this record; their stored creation contexts must come from durable evidence rather
than guessed ambient context. Decode links to evaluated span identities before opening the
span. Span-owned values must not capture metadata objects, event payloads or deferred row
lookups. Force scalar outcome projections before handing them to the SDK: even a constant
classification can otherwise be a thunk over a typed business payload. Render error descriptions
into a bounded, independently owned text buffer. A retained-span no-op probe confirmed this
failure mode before the fix and collection afterward without inspecting attributes.
Retained-span ownership evidence complements the steady-state gate in
[ADR-48](0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md).

Command span names are `command <category>`, using Kiroku's canonical prefix-before-dash
category rule. Keep the complete stream identifier in `keiro.stream.name`.

## Consequences

Existing event readers continue to work. Queries matching full stream names as span names
must switch to the category name and stream attribute. Explicit caller context remains an
application choice. Invalid or absent stored context omits a link rather than changing the
primary work's result. Baggage, business correlation identifiers and exporters are separate
concerns.
