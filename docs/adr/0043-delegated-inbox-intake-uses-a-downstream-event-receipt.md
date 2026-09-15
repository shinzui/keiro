---
type: Architecture Decision Record
title: Delegated inbox intake uses a downstream event receipt
description: A consumer may omit its inbox row only when one deterministic downstream event receipt covers the complete atomic operation.
timestamp: 2026-09-15T20:23:47Z
docId: ADR-43
status: Accepted
date: 2026-09-15
originatingPlan: docs/plans/83-delegated-idempotence-inbox-intake-bypass-the-keiro-inbox-table-when-the-downstream-state-machine-already-dedupes.md
---

# Delegated inbox intake uses a downstream event receipt

## Context

Table-backed intake records `(source, dedupe_key)` in `keiro_inbox` and
commits the handler's database work with that row. Some consumers immediately
dispatch an event-sourced command that already needs a permanent deterministic
event ID for replay safety. Writing a second receipt can add storage and
duplicate-path work, but removing it also removes the inbox's retry, backlog,
retention, and failure history.

[ADR-24](0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md)
requires frozen, unambiguous UTF-8 identity recipes. A command may reject after
hydrating newer state before attempting its append, and event IDs are globally
unique, so an arbitrary duplicate error does not prove that this command
previously completed in its target stream.

## Decision

Table-backed inbox intake remains the default. A consumer may select delegated
intake only when one downstream event receipt covers the complete atomic
operation. The delegated wrapper computes the ordinary inbox dedupe key and
invokes the downstream handler without reading or writing `keiro_inbox`.

Version 1 of `delegatedEventId` hashes six ordered UTF-8 fields with UUIDv5
namespace URL: `keiro/inbox-delegated/1`, consumer, integration source, dedupe
key, resolved target stream, and stable operation name. Each field is prefixed
by its decimal UTF-8 byte length and a colon. This recipe and every identity
input remain stable for the delivery and replay horizon.

The aggregate-command adapter probes the marker in the resolved target stream
before dispatch. A hit is a confirmed duplicate and avoids command hydration.
On a miss, the adapter assigns the marker to the first event of exactly one
atomic append. It accepts a positive append as fresh and confirms a concurrent
duplicate error by target-stream membership. It rejects command failures,
unrelated global collisions, and successful commands with no appended event.
All protected SQL, projection, and outbox work must commit in the same append
transaction.

Delegated batches run sequentially and cache only successful fresh or confirmed
duplicate identities within the caller's bounded chunk. Each unsuppressed item
may use a separate downstream transaction. Retry attempt counts and durable
dead-letter publication belong to the caller. A terminal delivery is
acknowledged only after the caller durably records its DLQ outcome.

Switching modes is a persisted-identity change. Existing inbox rows do not prove
that downstream markers exist, and downstream markers do not populate inbox
history. A deployment must drain in-flight work and define an explicit
cutover/replay boundary before switching in either direction.

## Consequences

Confirmed duplicates use one indexed existence probe and do not hydrate or
append a command. The probe cost is independent of target stream length as long
as the event-store index contract remains intact. Delegated intake creates no
inbox storage or inbox-table privilege requirement, and the wrapper itself has
no `Store` constraint.

Operators cannot use inbox backlog, failed rows, retention, or dead-letter
queries for delegated consumers. Removing or renaming the marker event, target,
consumer, source, or operation can make a replay appear fresh. Silent commands,
separately committed side effects, general workflow bodies, and arbitrary
multi-command process-manager reactions do not satisfy this receipt contract.

Performance depends on traffic and chunk shape. Delegation reduces allocation
and makes confirmed duplicate traffic substantially cheaper in the recorded
benchmark, while table batching may win through a shared commit. Services must
measure their workload rather than infer a universal latency improvement from
the missing inbox row.

## Alternatives considered

Treating every duplicate-event error as success was rejected because the same
ID may belong to another stream. Treating workflow-instance existence or a
zero-event command as completion was rejected because neither records the
complete protected effect. A mode flag on the table transaction API was
rejected because table handlers and delegated effectful handlers have different
transaction ownership and constraints.
