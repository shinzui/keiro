---
type: Improvement Request
title: Support atomic guarded dead timer resume
description: >-
  Let an authorized consumer claim one dead timer by ID and expected reason atomically,
  preserving its identity and retry history while excluding competing resume attempts.
timestamp: 2026-09-08T02:04:44Z
requestId: IR-36
status: proposed
origin: mori://shinzui/kioku
---

# Improvement Request: Support Atomic Guarded Dead Timer Resume

## Status

Proposed. Blocks foreground deferred-work resume and final host acceptance in
`mori://shinzui/kioku/plans/41-configure-all-kioku-ai-features-through-baikai-and-honor-host-execution-policy`.
Companion reads are requested by
`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-35`.

## Context

Kioku now parks interactive-only AI timers using `deadLetterTimer` when a background host
cannot launch an interactive session. Foreground resume must re-read the original work,
validate its deferred reason, obtain fresh memory-space authorization, establish interactive
availability, and then exclusively claim that timer. Creating a replacement timer or blindly
replaying every dead letter loses the original work identity or executes unintended work.

In `keiro/src/Keiro/Timer/Schema.hs` at commit
`c3c935c65d641c91867ab2d779ffe9559ba9abfc`, `claimDueTimer` claims scheduled timers,
while `requeueStuckTimer` and `requeueStuckTimers` operate only on firing rows. There is no
public guarded dead-to-firing transition. Plan 41 recorded this gap against released Keiro
0.15.0.0, verified against Hackage metadata and upstream tags on 2026-09-08. Implementation
must recheck the released baseline before choosing adoption bounds.

## Requested Change

1. Add a public operation that atomically claims a timer by ID only while its state is
   `Dead` and its stored reason exactly matches the caller's expected reason. Include a
   process-manager ownership guard, or provide an equivalent guarantee that the claim is for
   the inspected consumer's work. Return the claimed row on success and an explicit no-claim
   result on a stale expectation, wrong state, or missing timer.
2. Transition directly to `Firing` without making the work available to the ordinary due
   timer poller first. Concurrent resume attempts for the same parked state must have exactly
   one winner. Preserve timer ID, process-manager name, correlation, payload, original due
   time, and retry history; do not replace the timer or reset exhausted attempts silently.
3. Define attempt accounting explicitly. Failed claims and repeated session-unavailable
   preflights must consume no attempts. Document whether a successful foreground execution
   claim increments attempts and how it interacts with the retry ceiling and subsequent
   transient failures. Refresh recovery timestamps when claiming.
4. Document the full lifecycle after a successful claim: completion, transient failure,
   cancellation/session loss, and process crash. A claimed timer must not remain stranded
   indefinitely. Existing firing recovery may be reused with an explicit consumer contract;
   ensure a background host lacking interactive capability parks recovered work again.
   Guard against stale completion or recovery racing a newer claim, using the existing
   lifecycle guarantees or a claim token/version where needed.
5. Keep memory authorization and AI capabilities in the caller. Kioku must authorize and
   establish availability before mutation, and may never resume an ordinary dead letter
   merely because its ID exists. Keiro provides the storage transition and concurrency
   guarantee, not a Kioku-specific authorization model.

## Acceptance

1. PostgreSQL tests race two connections against one eligible dead timer: exactly one
   receives a claim, the other receives no claim, and the due poller cannot also claim it.
2. Wrong reason, wrong owner, absent ID, and scheduled/firing/fired/cancelled states remain
   unchanged. A repeated claim after success fails without incrementing attempts.
3. Successful claims preserve original identity, payload, correlation, due time, and retry
   history according to documented accounting. Existing dead-letter and retry behavior
   remains covered by regressions.
4. Simulated crashes and cancellation follow the documented recovery path. Stale workers
   cannot finalize a newer claim, and recovery does not permit overlapping valid owners.
   Claim exclusion alone must not be advertised as exactly-once external AI execution;
   callers still need their existing idempotent write and recovery guarantees.
5. A downstream Kioku fixture uses only public APIs to recheck authorization, refuse revoked
   access without mutation, leave unavailable sessions parked without attempt consumption,
   and resume valid work through the original timer. Concurrent resumes invoke at most one
   execution for the contested claim. Rei foreground acceptance follows release adoption.

## Requested Deliverables

Public guarded-claim API, concurrency and recovery integration tests, documented attempt and
ownership semantics, and a tagged Hackage release of `mori://shinzui/keiro/packages/keiro`.
Coordinate the release with IR-35 so Kioku can adopt both capabilities. Add a new migration
only if needed; never edit an applied migration. Record source compatibility and downstream
adoption evidence before marking this request complete.
