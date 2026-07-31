---
type: Improvement Request
title: Support atomic async projection apply and checkpoint advancement
description: >-
  Close the async projection crash window by applying projection SQL and advancing its Kiroku
  subscription checkpoint in one transaction when the selected adapter supports that boundary.
timestamp: 2026-07-31T15:03:58Z
requestId: IR-10
status: proposed
origin: mori://shinzui/keiro
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-07-31T15:03:58Z
    document_timestamp: 2026-07-31T15:03:58Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      In-repository review of async projection application, Kiroku subscription checkpoints,
      shibuya adapter ownership, deduplication, rebuild fencing, and the explicitly documented
      future-facing exactly-once checkpoint/user-SQL transaction gap.
---

# Improvement Request: Support Atomic Async Projection Apply and Checkpoint Advancement

## Status

Proposed for later cross-repository work. Keiro's current supported contract remains at-least-once
application with idempotent projection SQL and deduplication.

## Context

Async projection user SQL and subscription checkpoint advancement do not currently share one
database transaction at the adapter boundary. A crash can therefore re-deliver an already applied
event, requiring idempotent SQL/dedup rows. Those defenses are valid, but they add storage and
retention obligations and do not provide a first-class atomic projection mode.

The prerequisite spans `mori://shinzui/kiroku/packages/kiroku-store` and the registered Shibuya
Kiroku adapter; Keiro must consume released APIs rather than reaching into subscription tables with
an uncoordinated second connection.

## Requested Change

Expose a handler-in-transaction/checkpoint transaction boundary from Kiroku and its Shibuya
adapter, then add a Keiro async projection runner that applies projection SQL, dedup/fence checks,
and checkpoint advancement atomically. Define cancellation, rebalance, retry, poison-event,
rebuild-fence, and telemetry semantics plus a migration path from existing at-least-once workers.

## Acceptance

1. Fault injection before commit leaves neither projection write nor checkpoint; after commit it
   leaves both, across process crash and rebalance.
2. A zombie worker cannot commit after losing ownership/fence, and no later event checkpoints past
   an unprocessed predecessor.
3. Rebuild fencing and Strong/PositionWait reads observe the same committed checkpoint boundary.
4. At-least-once mode remains documented and supported; selecting atomic mode is explicit and
   rejected when the adapter/store cannot provide the required transaction resource.
5. Released dependency versions and upstream tags are verified before Keiro bounds change.

## Requested Deliverables

- Released Kiroku/adapter transaction-boundary prerequisites.
- Keiro atomic async projection runner and typed outcomes.
- Crash, cancellation, rebalance, fencing, ordering, and migration tests.
- Operations/compatibility guide, metrics, and changelog.
