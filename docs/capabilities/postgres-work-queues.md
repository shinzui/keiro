---
title: "PostgreSQL work queues (keiro-pgmq)"
type: Capability
description: "Run typed background jobs on a Postgres-native message queue with retries, a dead-letter policy, FIFO message groups, queue provisioning, metrics, and trace propagation — no separate broker."
generated:
  by: claude-code/sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-12
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - keiro-pgmq
interface:
  - Keiro.PGMQ
  - Keiro.PGMQ.Job
  - Keiro.PGMQ.Dlq
  - Keiro.PGMQ.Runtime
  - Keiro.PGMQ.Metrics
evidence:
  - kind: test
    resource: keiro-pgmq/test/Main.hs
    proves: "Typed job encode/decode, retry and DLQ policy, FIFO/message-group ordering, queue provisioning, one-shot draining without the shibuya runner, and W3C trace propagation across enqueue and settlement."
  - kind: guide
    resource: docs/user/work-queues.md
    proves: "How to define a typed job, run continuous workers or a one-shot drain, and configure retries and the DLQ."
  - kind: example
    resource: jitsurei/src/Jitsurei/ShipmentNotices.hs
    proves: "A runnable background work queue over the order domain, including the fact that the job effect stack does not carry Kiroku's Store."
---

# PostgreSQL work queues (keiro-pgmq)

A separately depended-on package (`keiro-pgmq`) that gives a consumer a
Postgres-native background job queue built on `pgmq-hs` and shibuya's pgmq
adapter — no separate broker to run. Jobs are typed with their own codec; the
runtime supports continuous workers and a one-shot drain, configurable retries, a
dead-letter policy, FIFO message groups, queue provisioning, metrics, and W3C
trace propagation from enqueue through settlement.

This is its own capability because it is a distinct package a consumer adds to
its build, adopted independently of the event-sourcing runtime — a service can
use keiro-pgmq for background work without touching aggregates, projections, or
workflows.

## Shape

```haskell
import Keiro.PGMQ

enqueueTraced queue job
runJobWorkers queue handler   -- or runJobOnce for a one-shot drain
```

## Limits

- The job effect stack deliberately does **not** carry Kiroku's `Store`; a job
  handler that needs to run keiro commands must interpret its own store — a
  structural fact worked examples call out because it trips people up.
- The queue is Postgres-native and inherits pgmq's semantics: at-least-once
  delivery with visibility timeouts, so handlers must be idempotent, and a queue
  under heavy fan-out is bounded by the database, not an external broker.
