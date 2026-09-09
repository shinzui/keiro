---
type: Improvement Request
title: Investigate Koyomi directory read and terminal delivery recovery contracts
description: >-
  Establish supported, performance-conscious ways for Koyomi to consume directory
  evidence during rebuilds and recover an inspected terminal delivery, first
  determining whether existing Keiro APIs and operating procedures suffice.
timestamp: 2026-09-09T02:57:38Z
requestId: IR-37
status: proposed
origin: mori://shinzui/koyomi
---

# Improvement Request: Investigate Koyomi Directory Read and Terminal Delivery Recovery Contracts

## Status

Proposed for owner investigation. This requests a supported consumer approach,
not approval of a particular runtime API, locking strategy or release.

The requesting agent previously modified Keiro without authorization and treated
its proposed implementations as prerequisites before establishing their necessity.
The owner reverted those changes, reporting serious performance problems. Those
implementations are not the proposed solution. No quantified performance result
is asserted here, and passing their tests did not prove a gap in released Keiro.

## Consumer context

The requester is
`mori://shinzui/koyomi/masterplans/1-bootstrap-koyomi-as-a-native-organizational-calendar-service`.
Two independently assessable needs remain:

1. `mori://shinzui/koyomi/plans/5-expose-authorized-calendar-http-apis-and-typed-clients`
   consumes identity, membership and profile-zone evidence through the directory
   owner's HTTP APIs. The relevant directory contract is
   `mori://shinzui/meibo/plans/20-expose-revision-consistent-organization-scope-snapshots`.
   An incomplete rebuild must not become an apparently complete empty membership
   snapshot or evidence assembled from incompatible revisions/generations.
2. `mori://shinzui/koyomi/plans/6-deliver-durable-calendar-changes-and-recoverable-workers`
   needs an operator recovery procedure for a selected delivery that exhausted
   automatic retries. Read-only inspection already uses `lookupOutbox`. Recovery
   must preserve delivery identity and ordinary publication/recipient checks.

Koyomi's current dependency cohort is 0.15.0.0. Investigation should compare the
consumer's actual usage with current supported/released behavior before choosing
any dependency update. This request specifies no new version or dependency bound.

## Observations and uncertainty

Source inspected at Keiro commit `250d30079a7f4a40ff86610008b08f69f91f7bb6`:

- `runValidatedQuery` in `keiro/src/Keiro/ReadModel.hs` checks the model, performs
  the freshness wait, then executes its query with `runTransaction`. This sequence
  alone does not prove a race: transaction isolation, rebuild protocols, model
  binding and the consumer's supported usage must be examined together.
- `Keiro.Outbox` exposes inspection, normal publishing and stale-claim recovery.
  `requeueStuckOutbox` in `keiro/src/Keiro/Outbox/Schema.hs` recovers stale
  `publishing` rows; its requeue statement is not a dead-row recovery operation.
  That observation does not rule out another supported recovery procedure.

There is no independently established minimal failing reproducer attached for
the directory concern. No production failure in another consumer is alleged.
Existing successful consumer patterns should be the first source of guidance.

[IR-22](make-read-models-safely-readable-by-out-of-process-consumers.md) concerns
external SQL readers and rebuild safety. This request's immediate directory
consumer uses owner HTTP APIs backed by native read models; it must not be assumed
to need the same solution. If IR-22 or existing guidance already covers the need,
link the applicable contract instead of introducing a duplicate capability.

## Requested investigation and outcomes

### Directory evidence during rebuilds

Identify the supported way to obtain revision-consistent membership/profile
evidence while native targets are rebuilt or promoted. A documented unavailable
result during an offline rebuild is acceptable; this request does not require
zero downtime. A supported coherent prior generation is also acceptable where
the consumer's freshness contract permits it. Never substitute incomplete data
for a complete result.

First demonstrate the existing recommended pattern in a small consumer fixture.
If a gap remains, produce a deterministic PostgreSQL reproducer with independent
reader/rebuilder connections and controlled interleavings around validation,
query execution and cutover. Include the consumer's compound-read case only where
its real implementation requires one. Explain why existing transaction, catalog
and generation APIs cannot satisfy the contract before proposing new APIs.

### Selected terminal delivery recovery

Identify a supported way to inspect one exhausted delivery and deliberately make
it eligible for another ordinary publication attempt after the cause is repaired.
Clarify whether this is an existing operator procedure, supported API composition,
or a missing capability.

The procedure should preserve message/source identity, payload and audit history;
define attempt accounting explicitly; exclude permanently rejected and already
successful deliveries; and avoid silently replaying unrelated rows. Concurrent
operators and retries of stale inspection must not unintentionally authorize
additional attempts. Ordinary transport authorization, deduplication and crash
recovery continue to apply. No exactly-once external-delivery guarantee is sought.
The owner may propose a different recovery contract and explain the consumer
changes it requires; an attempt-count compare-and-set is not mandated.

## Performance and validation

Any proposed runtime change must include before/after measurements against the
existing implementation under representative concurrent reads, projection writes
and rebuild/cutover activity. Record workload size, concurrency, query count,
latency distribution, throughput and lock wait/contention. Check scaling with
catalog/target size and the ordinary path when no rebuild is running. Agree an
acceptable performance budget with the owner; do not introduce per-read catalog
scans or broad synchronization without evidence and explicit review.

For terminal recovery, test competing requests, stale retries, wrong states,
preserved identity/history, rollback, publication interruption and normal recovery.
For directory reads, prove coherent results or explicit unavailability during
the exercised interleavings; a successful empty snapshot must represent actual
empty membership rather than rebuild progress. Existing query/rebuild and outbox
behavior must continue to pass its regressions.

## Requested deliverables

- An owner finding for each need: supported already, consumer misuse, confirmed
  runtime gap, or a contract change required in the consumer.
- Public-API usage guidance and a focused reproducer/acceptance fixture supporting
  that finding. Existing APIs plus documentation can resolve this request.
- Only if a runtime gap is confirmed: an owner-reviewed design with correctness
  and performance evidence, compatibility implications and release/adoption
  guidance. No implementation or publication is authorized by this request.

Koyomi adoption and its actual directory/replay acceptance remain consumer work.
This request must not be marked complete merely because a new API compiles or
the reverted implementation's tests pass.
