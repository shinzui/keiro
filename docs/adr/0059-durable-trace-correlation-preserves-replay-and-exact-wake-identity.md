---
type: Architecture Decision Record
title: Durable trace correlation preserves replay and exact wake identity
description: Trace adoption uses immutable producer cutovers, exact snapshot-independent wake attribution, and explicit span ownership evidence.
timestamp: 2026-11-14T19:05:00Z
docId: ADR-59
status: Accepted
date: 2026-11-14
originatingPlan: docs/masterplans/47-trace-context-propagation-and-span-correlation-across-keiro-durable-boundaries.md
---

# Durable trace correlation preserves replay and exact wake identity

## Context

[MasterPlan 47](../masterplans/47-trace-context-propagation-and-span-correlation-across-keiro-durable-boundaries.md)
adds correlation across durable boundaries. Implementation has not started. Its review found
that a deployment-wide switch cannot preserve historical producer content, that workflow
snapshot hydration cannot recover trace metadata, and that bounded live heap does not prove
that retained spans release payloads.

[ADR-42](0042-producer-outbox-identity-is-a-versioned-source-event-contract.md) includes trace
headers in strict producer content equality. [ADR-6](0006-workflow-wake-source-rows-govern-exposure-and-terminal-races.md)
keeps wake lifecycle and generation-specific delivery authoritative.
[ADR-48](0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md)
defines a heap regression gate, not closure ownership proof.

## Decision

Producer trace derivation is opt-in through a fixed source-event global-position cutoff per
producer source/name and store. Events at or below that cutoff retain draft-only trace behavior;
later events derive missing context from durable metadata. Explicit draft context always wins.
The existing trace field comparison and identity encoding remain unchanged. The cutoff is durable
application configuration, shared by all workers and preserved across restart, replay and rollback.
It is not a Boolean capability or a value recomputed at startup.

Establish the cutoff while producer workers and source writers are paused and their in-flight
transactions drained. Resume only policy-aware workers with identical configuration. A rollback
after activation must retain policy support and the same cutoff; pre-policy binaries must remain
stopped for that producer. Successful-row garbage collection does not change the derivation rule.
A new delivery identity or changed policy requires a separate deliberate adoption strategy.

Workflow trace links do not participate in replay or readiness. A nullable generation-scoped
trace-await hint on the instance captures the exact step at suspension in the existing locked
transaction, including wake-before-suspend races. Wake upserts preserve it within that generation;
rotation and terminal transitions clear it; an untraced suspension clears it. At traced run entry,
read the hint before interpretation changes it and fetch the corresponding deterministic journal
event by ID. Missing hints or events omit the wake link; the latest journal event is not a proxy.
Old binaries cannot maintain hints, so clear them with workers stopped before re-enabling traced
resumes after an old-code rollback.

Fetch the generation's first persisted event separately with a one-event read from version zero.
Call this link `origin`: it is a journal origin, not a claim about the first invocation. A workflow
that suspends before journaling may have its wake as its first event. Both lookups are independent
of snapshot hydration, bounded in result count, and performed only with a tracer. No full-history
scan, snapshot-format extension or retention of event payloads is permitted. Contexts remain in
journal metadata; the hint contains only the step key. Missing or malformed evidence produces
fewer links, never guessed causal attribution. Duplicate origin/wake contexts produce one wake link.

Steady-state heap gates and retained-span ownership probes are separate acceptance criteria.
The ownership probe keeps spans reachable while payload weak references clear after major GC,
and verifies a negative control that retains those payloads through span-owned data. An unrelated
global leak, a processor-free tracer or clearing the exporter before checking cannot establish
that property. Each boundary's actual link builder participates in this probe.

## Consequences

EP-3 owns producer policy plumbing, generated construction sites and adoption documentation.
EP-6 owns the additive timer columns, trace-await hint, race tests and snapshot-independent
lookups. Its `origin` terminology deliberately avoids promising a start span that was never
persisted. Additional schema and opt-in derivation costs must be measured explicitly; the
no-tracer span helpers remain pass-throughs.

EP-1 owns reusable ownership evidence. EP-4 and EP-6 each have independent acceptance; their
combined command/worker/timer/workflow demonstration is an initiative release gate. These
constraints are accepted architecture for pending work, not a claim that tracing is implemented.
