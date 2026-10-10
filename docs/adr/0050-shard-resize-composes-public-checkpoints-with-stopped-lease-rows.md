---
type: Architecture Decision Record
title: Shard resize composes public checkpoints with stopped lease rows
description: Explicit stopped-worker resize atomically equalizes Kiroku checkpoints and replaces Keiro lease rows through the released transaction API.
timestamp: 2026-10-10T14:59:34Z
docId: ADR-50
status: Accepted
date: 2026-10-10
---

# Shard resize composes public checkpoints with stopped lease rows

## Context

Changing the number of consumer-group buckets changes stream assignment. Keeping
unequal member checkpoints can skip events. Keiro owns leases; checkpoint storage
and topology semantics belong to mori://shinzui/kiroku/packages/kiroku-store.
A mismatched startup formerly inserted new lease rows before reporting refusal.

## Decision

Require the published Kiroku 0.10 store, 0.7 migrations and 0.6 adapter cohort.
Construct sizes, members, batches and buffers through its validated public API.
`ensureShards` serializes creation by subscription name and checks existing counts
before inserting. `ShardCountMismatch` belongs to Kiroku's
`SomeSubscriptionStartupFailure` exception family; reader startup refusals are
reported separately from ordinary reader death.

`resizeShardCountTx` holds a Keiro namespace transaction advisory lock and locks
all lease rows. Any recorded owner refuses resize, even after lease expiry. The
operator must stop workers and relinquish all owners first. With that precondition,
compose public `resizeConsumerGroupTx` with replacement of Keiro lease rows in one
Hasql transaction. Every new member resumes at the old minimum, including when the
size is unchanged. The report preserves previous shard counts and Kiroku's public
resize evidence. Application SQL failure rolls back both sets of rows.

Keep checkpoint-table SQL inside Kiroku. New downstream resize tests use its public
inventory and real subscription workers. Decode failures are deterministic and do
not retry as transient store failures. Sharded subscriptions retain the default
stop-on-undecodable policy; silently skipping malformed events is not enabled.

## Consequences

Resize can replay acknowledged events, so handlers must retain their normal
at-least-once idempotence. This is an explicit maintenance operation, not dynamic
rebucketing or proof that a worker process has stopped. Unowned lease rows alone
cannot certify that an external Kiroku reader is stopped; operators own that
precondition. Claims and renewals keep their existing row-lock behavior.

## References

- mori://shinzui/kiroku/masterplans/12-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review
- mori://shinzui/kiroku/plans/85-release-the-subscription-hardening-cohort-and-coordinate-downstream-adoption
