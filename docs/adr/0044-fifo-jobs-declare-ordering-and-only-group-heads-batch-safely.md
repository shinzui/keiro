---
type: Architecture Decision Record
title: FIFO jobs declare ordering and only group heads batch safely
description: Every PGMQ job declares its ordering contract; strict FIFO batching uses absolute group heads, while legacy grouped strategies are restricted to batch size one.
timestamp: 2026-09-16T14:01:31Z
docId: ADR-44
status: Accepted
date: 2026-09-16
originatingPlan: docs/plans/116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md
---

# FIFO jobs declare ordering and only group heads batch safely

## Context

PGMQ's legacy grouped reads can lease several messages from the same group in a
single batch. A successor may therefore reach a handler before its predecessor
has settled. If that predecessor fails, retries, or remains invisible after a
worker crash, the later message has already crossed the intended FIFO barrier.
Round-robin batch filling changes fairness but not this failure mode.

Keiro previously stored ordering only in optional runtime tuning. The job value
did not state the durable delivery contract, default wrappers silently selected
unordered reads, and a raw `JobTuning` could bypass the smart constructor. A
configuration error could consequently change delivery semantics instead of
failing before consumption.

The adapter release owned by
`mori://shinzui/shibuya-pgmq-adapter/plans/7-add-grouped-head-fifo-polling-to-the-pgmq-adapter`
exposes PGMQ's absolute grouped-head read. That operation returns at most the
oldest message in each group. An invisible or delayed head blocks successors in
its group while other group heads remain eligible.

## Decision

Every `Job` has a required `jobOrdering`. Explicit `JobTuning.ordering` must
match it exactly. The default worker and one-shot wrappers derive tuning
ordering from the job rather than imposing `Unordered`.

`FifoHeads` is the strict per-group failure barrier and the only FIFO mode that
may use a batch size greater than one. Its batch size counts independently
eligible groups, because each group contributes at most one absolute head.
`FifoThroughput` and `FifoRoundRobin` remain available for compatibility, but
Keiro rejects either mode when `batchSize > 1`. `Unordered` remains freely
batchable.

Client-side sorting is not a correctness mechanism. Once one database read has
leased both a head and its successor, sorting their returned rows cannot make
the successor unavailable again when handling the head fails. Grouped-head
selection prevents that unsafe lease instead; cross-group result order is not
part of Keiro's contract.

Both consumption entry points run one pure validation before constructing an
adapter or issuing a PGMQ read. Validation rejects invalid raw tuning first,
then a job/tuning ordering mismatch, then an unsafe legacy FIFO batch. These are
programmer configuration errors surfaced as `JobConsumptionConfigError`; they
are never converted into empty reads or worker success.

The Keiro DSL spells the new contract `ordering fifo-heads`. Scaffolding lowers
it to `FifoHeads` and provisions the existing FIFO index. Changing any queue's
ordering remains a breaking delivery-contract change in `keiro-dsl diff`.

## Consequences

Failures, retries, visibility-timeout expiry, and delayed heads cannot allow a
later message from the same `FifoHeads` group to run. One batch can still make
progress across many independent groups, so strict ordering no longer forces a
global quantity-one read. This is database-read batching, not handler
parallelism: Keiro's current drain and worker handlers remain serial.

Adding `jobOrdering` breaks source compatibility for every hand-written `Job`
record. Applications must choose explicitly. Existing legacy FIFO applications
with batch size one can retain their strategy; applications that batch must
move to `FifoHeads` or knowingly select `Unordered`.

The guarantee remains at-least-once, not exactly-once. A head may be delivered
again after a crash or visibility timeout, so handlers must remain idempotent.
The FIFO index and PGMQ 1.12-or-later grouped-head function are deployment
requirements.

## References

- [ExecPlan 116](../plans/116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md)
  — implementation, mutation, performance, and release evidence.
- `mori://shinzui/shibuya-pgmq-adapter/plans/7-add-grouped-head-fifo-polling-to-the-pgmq-adapter`
  — adapter strategy and release boundary.
- [Work Queues](../user/work-queues.md) — application-facing configuration and
  rollout guidance.
