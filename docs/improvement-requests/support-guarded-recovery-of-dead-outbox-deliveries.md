---
type: Improvement Request
title: Support guarded recovery of dead outbox deliveries
description: >-
  Define a supported operator recovery path for one exhausted outbox delivery,
  preserving identity and retry history while preventing stale or competing
  recovery requests from authorizing unintended additional attempts.
timestamp: 2026-09-16T04:45:00Z
requestId: IR-38
status: proposed
origin: mori://shinzui/koyomi
reviews:
  - kind: model
    reviewer: claude-code
    reviewed_at: 2026-09-16T04:45:00Z
    document_timestamp: 2026-09-16T04:45:00Z
    scope: technical-accuracy
    outcome: approved
    provider: anthropic
    model: claude-opus-5
    effort: high
    context: >-
      Bundle refresh at Keiro `708aa215`; the document was corrected in this pass. `proposed`
      with no implementing plan is correct, and the requested capability is still absent: no
      dead-row recovery export exists in `keiro/src` or `keiro-ops/src`. The source anchor had
      gone stale — unlike IR-37's, the outbox modules did change after commit `250d3007`, in
      `3cdbe90a` (replay-safe producer identities, adding `Keiro.Outbox.Identity`) and
      `844d3062` (replay allocation and enqueue cost work). Those commits were inspected: they
      leave `lookupOutbox`, `listOutbox`, `claimOutboxBatch`, `requeueStuckOutbox`,
      `OutboxDead`, and `OutboxRejected` untouched, so the described behavior and the reported
      gap are unchanged. A re-confirmation anchor and a note naming the two commits were added
      so the next reader is not misled.
---

# Improvement Request: Support Guarded Recovery of Dead Outbox Deliveries

## Status

Proposed for library-owner investigation. Establish whether existing public APIs
or a supported operational procedure already satisfy this lifecycle before adding
an operation. No particular compare-and-set field or state transition is mandated.

## Existing library behavior

Source inspected at commit `250d30079a7f4a40ff86610008b08f69f91f7bb6` and re-confirmed at
`708aa215` on 2026-09-16:

- `lookupOutbox`/`listOutbox` expose delivery state for inspection.
- `claimOutboxBatch` selects eligible `pending`/`failed` rows, transitions them to
  `publishing` and increments their attempt counts.
- Failure handling can move an exhausted delivery to `dead`.
- `requeueStuckOutbox` handles stale `publishing` claims: it dead-letters exhausted
  claims and returns others to `failed`. It does not requeue existing `dead` rows.
- `rejected` records intentional permanent refusal and is distinct from exhaustion.

See `keiro/src/Keiro/Outbox.hs`, `keiro/src/Keiro/Outbox/Schema.hs` and
`keiro/src/Keiro/Outbox/Types.hs`. The inspected facade has no dedicated dead-row
recovery export; that does not rule out another supported procedure.

The outbox modules have changed since the originally inspected commit — `3cdbe90a`
(replay-safe producer identities and content-drift rejection, adding
`keiro/src/Keiro/Outbox/Identity.hs`) and `844d3062` (replay allocation and producer
enqueue cost work). Neither touches the claim, failure, dead-letter or stuck-requeue
transitions enumerated above, and no dead-row recovery export was added, so the behavior
this request describes and the gap it reports are unchanged.

## Requested library capability

After repairing a delivery failure, an operator must be able to select an
inspected exhausted delivery for a further ordinary publication attempt without
creating a replacement integration event or losing its stable message identity.

The supported procedure should:

1. Address one exact delivery and reject stale inspection or competing recovery
   requests that would unintentionally grant additional attempts. Specify what
   constitutes an identical retry and when fresh inspection is required.
2. Preserve outbox/message/source identity, payload and audit history. Define
   attempt accounting explicitly, including another failure after recovery;
   do not silently reset an exhausted budget.
3. Exclude successful and permanently rejected deliveries, missing records and
   states already eligible for or undergoing publication. Do not replay unrelated
   rows as a side effect of recovering one delivery.
4. Continue through normal publication, ordering, transport checks and crash
   recovery. State how recovering an older delivery interacts with later events
   already delivered under the supported ordering policies. Recipients retain
   deduplication and source-revision responsibilities; exactly-once external
   delivery is not requested.

Application authorization and recipient policy remain outside Keiro. The library
owns the durable lifecycle and concurrency guarantees, not a domain-specific
operator workflow.

## Acceptance and deliverables

First document and exercise any existing public-API composition or supported
procedure. If it suffices, guidance can resolve this request without runtime code.
If a gap remains, supply a focused reproducer and an owner-reviewed proposal.

PostgreSQL acceptance should cover competing requests, retries of stale
inspection after a subsequent attempt, wrong-state/missing-row refusal, preserved
identity and history, rollback, and interruption around publication/finalization.
Verify ordinary retry, permanent rejection and ordering behavior remains intact.
Measure recovery contention and any changes to claim/publication throughput; a
rare operator action must not introduce unreviewed overhead on ordinary delivery.

An earlier unauthorized implementation was reverted by the owner for serious
performance problems. It is not a requested design or release candidate. Any
change requires correctness and performance evidence before adoption; no new
API, migration, version bound or publication is prescribed here.

## Origin

The motivating consumer is
`mori://shinzui/koyomi/plans/6-deliver-durable-calendar-changes-and-recoverable-workers`.
This request was separated from IR-37 because outbox recovery and read-model
rebuild consistency are independent Keiro contracts.
