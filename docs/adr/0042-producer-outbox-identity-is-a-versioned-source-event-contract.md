---
type: Architecture Decision Record
title: Producer outbox identity is a versioned source-event contract
description: Canonical producers derive frozen source-event identities and reject differing retained content without rewriting publication history.
timestamp: 2026-09-15T18:00:00Z
docId: ADR-42
status: Accepted
date: 2026-09-15
originatingPlan: docs/plans/164-make-producer-outbox-identity-deterministic-and-replay-safe.md
---

# Producer outbox identity is a versioned source-event contract

## Context

A persisted message ID survives publication retries, but a fresh TypeID does not
survive remapping the same private event after rollback, restart, or redelivery.
A stable outbox primary key paired with a fresh message ID can also violate a
different unique constraint than the documented deduplication key. Suppressing
all conflicts silently would hide changed mapper output.

[ADR-24](0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md)
requires UTF-8, explicit tuple boundaries, and frozen persisted identity.
[ADR-37](0037-outbox-publication-rejection-is-terminal-audit-truth.md) requires
replay to preserve terminal rejection audit truth.

## Decision

Version 1 in `Keiro.Outbox.Identity` encodes six ordered fields. Each starts with
an unsigned 64-bit big-endian byte length: ASCII `keiro.producer.outbox`, version
1 as two big-endian bytes, producer source as UTF-8, producer name as UTF-8,
source event UUID as 16 network-order bytes, and emission index as four unsigned
big-endian bytes. No Unicode normalization is performed. Today's single-draft
mapper uses index zero. Future multi-emission mappings must assign stable indices.

SHA-256 hashes those bytes. The outbox UUID takes the first 16 digest bytes and
sets the version nibble to 8 and the RFC variant bits to binary `10`. The message
ID is the configured namespace, `_v1_`, and all 32 digest bytes as lowercase hex.
The namespace is non-empty and passes the existing TypeID prefix validator;
the result is opaque text, not a TypeID. Namespace is deliberately outside the
hash: changing it collides with the retained outbox ID and is reported as drift.
Source/name changes rename identity and therefore require deliberate cutover.

For source `ordering`, name `ordering-integration-producer`, source UUID
`00000000-0000-0000-0000-000000000001`, index 0, and namespace `msg`:

```text
SHA-256: 61dd62b4bbfef1ce56346ce6afd485172774bc060102e5cf455e39bd0edfa84b
outbox:  61dd62b4-bbfe-81ce-9634-6ce6afd48517
message: msg_v1_61dd62b4bbfef1ce56346ce6afd485172774bc060102e5cf455e39bd0edfa84b
```

This encoding is frozen independently of existing workflow/process-manager IDs.
A later change requires a new algorithm version and an adoption strategy.

The producer helper defaults missing source ID/global position from the supplied
recorded event and truncates occurrence time to microseconds before insertion.
Explicit provenance overrides are permitted and compared. Content uses RFC 8785
canonical JSON over an ordered list of identity, routing, schema, payload,
occurrence, causal, trace, attributes, and provenance classes. Header-backed
classes encode ordered `(header-name, optional-text)` pairs. Routing is the
`(destination, optional-key)` pair, payload is lowercase byte-exact hex, and
attributes encode absence as an empty array or presence as a singleton array
(including JSON null). Schema-reference absence and an all-absent reference have
the same wire meaning. SHA-256 of this canonical representation is available for
diagnostics; correctness compares canonical bytes, avoiding hash-collision-based
false duplicates. No payload or metadata values are returned in conflict outcomes.

No digest column is added: existing envelope columns are authoritative. Fresh
insertion executes one statement with `ON CONFLICT DO NOTHING` across either
unique key. A losing insertion uses a separate `SELECT ... FOR UPDATE` through
both identity indexes and compares all matching rows. This separate statement
sees the winner at READ COMMITTED even if it committed after the insert's snapshot.
Higher isolation levels use the transaction runner's serialization retry policy.
If successful-row GC deletes the winner before the read, enqueue retries insertion.
The comparison never updates timestamps, ordering, status, attempts, or rejection.

`ProducerIdentityConflict` is a typed outcome. Subscription integrations condemn
the surrounding checkpoint transaction on conflict and observe its result after
the transaction runner returns. `recordProducerEnqueueOutcome` then records the
unlabelled `keiro.outbox.identity.conflict` counter once, outside SQL retries.

## Consequences

No schema migration, redundant digest writes, or fresh-path content hashing is
needed. Duplicate replay pays for a locked read and canonical comparison; this
work is required to detect mapper drift. Benchmarks compare the old fresh-ID path
and deterministic writes with identical transaction sizes, plus old/new publisher
workloads. Performance measurements and machine-specific results live in plan 164.

Deduplication is bounded by row retention. After sent-row GC, replay can republish
with the same wire ID; downstream inbox retention determines consumer suppression.
Rejected rows remain retained. The explicit envelope escape hatch remains usable.

Historical random IDs cannot be recovered from the new deterministic tuple. A
rollout must drain old attempts and preserve committed checkpoints, or supply an
application-owned old/new mapping before replaying pre-cutover events. Renaming a
producer or changing index assignments is a new delivery identity, not a harmless
refactor. The fresh envelope helper is named `freshIntegrationEvent`; its former
name is deprecated and never describes producer replay safety.
