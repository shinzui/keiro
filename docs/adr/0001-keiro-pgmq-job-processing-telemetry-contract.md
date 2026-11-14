---
type: Architecture Decision Record
title: keiro-pgmq job processing emits one process span per delivery on both execution paths
description: Both keiro-pgmq job-execution paths emit exactly one process span per delivery under a shared processing-span implementation and observable contract.
timestamp: 2026-11-14T23:33:52Z
docId: ADR-1
status: Accepted
date: 2026-07-22
---

# 1. keiro-pgmq job processing emits one process span per delivery on both execution paths

Date: 2026-07-22

Status: Accepted


## Context

`keiro-pgmq` executes typed PostgreSQL Message Queue (PGMQ) jobs two ways, and they are
different runtimes rather than two entry points onto one runtime.

`runJobWorkers` is the continuous path. It builds a shibuya processor and hands it to
`Shibuya.App.runApp`, which owns a supervised lifecycle: background ingestion into an inbox,
a concurrency limit, graceful shutdown, halt state, and finalization retries. Shibuya's
private `processOne` runner drives each message and is the thing that opens a span.

`runJobOnceWithContext` (and its wrapper `runJobOnce`) is the bounded path. It reads PGMQ
rows directly, stops when the queue is empty or after `n` messages, performs batch and FIFO
reads itself, leaves a thrown-handler delivery invisible for visibility-timeout redelivery,
and returns a handled count. It has no inbox, no concurrency, and no supervisor.

Because only the continuous path went through shibuya, only the continuous path produced a
span for the domain handler. The bounded path preserved the enqueued W3C `traceparent` in
`JobContext.headers` but never extracted it as a parent and never opened a span, so a trace
showed enqueue, receive, and settlement spans with a hole where the job actually ran.

The obvious unification — route the one-shot API through `runApp` and stop it immediately —
would have changed real behavior (promptness, batch and FIFO read shape, handler-exception
finalization, the handled count) purely to obtain telemetry.


## Decision

Keep the bounded drain's execution semantics and open both paths' spans through
`Shibuya.Telemetry.Process.withProcessSpan`. The supervised runner already uses this
public helper; the bounded drain supplies its name, policy, headers and common attributes.

Every delivery on either path runs inside exactly one Consumer-kind span named
`process <jobName>`. Both paths extract the W3C creation context that `enqueueTraced`
stored in PGMQ's JSONB `headers` column and link to it. `JobTuning.telemetry` carries
Shibuya's `AdapterTelemetry`; its default `ParentAndLink` also installs that context as
a remote parent. `LinkOnly` opens an independent root when headers decode. Absent or
malformed headers preserve the ambient-parent fallback without links under either policy.
The previous context is restored on exit. Delayed and retried deliveries can therefore
be sampled independently while retaining their relation to the enqueuer.

Both paths carry the same common attributes: `messaging.system=shibuya`,
`messaging.destination.name=<jobName>`, `messaging.operation.type=process`,
`messaging.operation.name=process`,
`messaging.message.id`, and `shibuya.partition` when the delivery has a FIFO group.

Both paths use the same acknowledgement vocabulary and status mapping: `shibuya.ack.decision`
is one of `ack_ok`, `ack_retry`, `ack_dead_letter`, `ack_halt`; `AckOk` and `AckRetry` end
the span `OK`; `AckDeadLetter` and `AckHalt` end it `ERROR` with the reason text.

Two differences are deliberate and are part of the contract, not drift:

The bounded path does not emit `shibuya.inflight.count` or `shibuya.inflight.max`. Those
describe shibuya's inbox and concurrency meter, neither of which exists behind a bounded
drain. Emitting a fabricated value would be worse than emitting nothing.

The bounded path records no `shibuya.ack.decision` when a handler throws. The continuous
runner substitutes `AckRetry` so the adapter always observes a finalization; the bounded
drain deliberately makes no finalizer call and leaves the row invisible until its visibility
timeout expires. It therefore records the exception and an `ERROR` status, and claims no
acknowledgement that did not happen.

`shibuya.ack.decision` is written only after the finalizing PGMQ statement has returned. If
that statement throws, the exception propagates out of a span carrying no acknowledgement
attribute, which is the truthful reading.

Implementation constraints that follow: the bounded path reuses shibuya's public telemetry
helpers (`Shibuya.Telemetry.Process`, `.Effect`, `.Semantic`) and
`Shibuya.Adapter.Pgmq.Convert.pgmqMessageToEnvelope`, and imports nothing from
`Shibuya.Internal.*`. Lower-level PGMQ operation spans (`publish <queue>`,
`receive <queue>`, deletes, visibility changes, DLQ sends) remain the traced
`pgmq-effectful` interpreter's business; the process span wraps domain processing and
settlement and neither replaces nor renames them.


## Consequences

The two execution shapes share span naming, creation-link and parent-policy implementation.
The common attribute set and acknowledgement mapping remain explicit in the bounded path
and are kept in step by tests against the continuous path. `JobTuning` retains its `Eq`
and `Show` instances because the released `AdapterTelemetry` supports them.

Queries matching `<jobName> process` must switch to `process <jobName>`. `JobTuning`'s
exported raw record gains a required telemetry field; use `mkJobTuning` and record updates.
Source-compatible PGMQ and Kiroku adapters accompany the repository's Shibuya 0.13 bump.
Consumer extraction remains W3C-only even though enqueue uses the provider's configured
propagator; a non-W3C-only provider cannot yield these consumer creation links.
Retained-span tests exercise actual decoded job payloads on both paths under both policies.

Anyone tempted to "simplify" by routing `runJobOnceWithContext` through `runApp` should read
the Context section first: that change trades documented drain semantics for implementation
convenience, and it is rejected here.

Adding `shibuya.inflight.*` to the bounded path is likewise rejected. If a future bounded
drain grows real concurrency, the values become meaningful and this ADR should be revised
rather than quietly worked around.


## References

- [docs/plans/111-trace-one-shot-pgmq-job-processing-with-remote-parent-continuation.md](../plans/111-trace-one-shot-pgmq-job-processing-with-remote-parent-continuation.md)
  — the ExecPlan that introduced this, including the branch-coverage evidence.
- [docs/plans/74-expose-keiro-pgmq-tuning-surface-and-make-job-workers-resilient.md](../plans/74-expose-keiro-pgmq-tuning-surface-and-make-job-workers-resilient.md)
  — replaced the old one-shot adapter stream with the current direct drain.
- [docs/plans/75-add-message-headers-trace-propagation-and-batch-enqueue-to-keiro-pgmq-producers.md](../plans/75-add-message-headers-trace-propagation-and-batch-enqueue-to-keiro-pgmq-producers.md)
  — added the header propagation this ADR consumes.
