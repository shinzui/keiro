---
type: Improvement Request
title: Support atomic multi-stream command coordination
description: >-
  Provide a first-class command API that hydrates, decides, and conditionally appends across
  multiple streams in one PostgreSQL transaction with deterministic locking and retry semantics.
timestamp: 2026-07-31T15:03:56Z
requestId: IR-8
status: proposed
origin: mori://shinzui/keiro
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-07-31T15:03:56Z
    document_timestamp: 2026-07-31T15:03:56Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      In-repository review of the single-stream Keiro command runner, Kiroku transactional append
      substrate, and router/process-manager fan-out, whose target appends are deliberately separate.
---

# Improvement Request: Support Atomic Multi-Stream Command Coordination

## Status

Proposed for later runtime work. This is not a request to make ordinary router fan-out atomic.

## Context

Keiro's primary command runner hydrates and appends one event stream. Kiroku exposes lower-level
transactional/multi-stream building blocks, and routers/process managers coordinate multiple
targets idempotently, but Keiro has no first-class typed command surface for an invariant that must
read and update several streams atomically. Applications must either redesign the boundary or
assemble internal transaction primitives without the runner's validation, retry, replay, snapshot,
projection, and telemetry guarantees.

## Requested Change

Design a typed multi-stream command transaction with deterministic stream lock/order acquisition,
per-stream expected versions, one pure decision over hydrated inputs, one atomic append result,
inline SQL/projection hooks, bounded optimistic retry, and exact replay/telemetry errors. Define
limits so it is not used as an unbounded distributed transaction abstraction.

## Acceptance

1. A two-stream invariant appends both event batches or neither under concurrency and fault
   injection.
2. Lock ordering prevents deadlocks for callers naming the same stream set in different order.
3. Conflict retry rehydrates every input and never reuses a stale partial decision.
4. Snapshots, codecs, just-appended replay verification, and inline SQL preserve single-stream
   guarantees for each member.
5. Router/process-manager documentation still describes their non-atomic per-target model.

## Requested Deliverables

- API/design limits and typed multi-stream result/error model.
- Transaction, hydration, append, retry, replay, and projection implementation.
- Concurrency, rollback, deadlock, conflict, and parity tests.
- Operations/selection guide and release notes.
