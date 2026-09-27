---
type: Improvement Request
title: Make a timer fire outcome explicit and let a fire finish without an event
description: >-
  A timer fire action returns Maybe EventId, and Nothing means "leave the row firing and requeue it
  when stale", so a handler that finished its work but wrote no event retries forever. Replace the
  Maybe with an explicit outcome and add a terminal state for a fire that completed with nothing to
  record.
timestamp: 2026-09-27T20:30:00Z
requestId: IR-51
status: proposed
origin: mori://shinzui/rei
acceptanceCriteria:
  - id: AC-1
    statement: The timer worker accepts a fire action that returns an explicit outcome distinguishing at least completed-with-event, completed-without-event, retry-after-delay, and permanently-failed, and each outcome moves the claimed row to exactly one documented state in the same pass.
    verification: A worker test per outcome that claims one timer, fires it, and asserts the row's status, attempts, fired_event_id, last_error, and fire_at afterwards.
  - id: AC-2
    statement: A fire that completed without an event reaches a terminal state that is distinct from cancelled and dead, is never requeued, and records a caller-supplied reason.
    verification: The completed-without-event test from AC-1 runs a later worker pass past requeueStuckAfter and asserts that the row is not reclaimed; lookupTimerInspection and keiro-ops timer inspection show the state and reason.
  - id: AC-3
    statement: A timer row cannot stay in firing indefinitely without an operator-visible signal, either through a finite default attempt ceiling or a worker diagnostic when a row's attempts keep growing without an error.
    verification: A worker test with the default options that fires a timer returning a non-terminal outcome repeatedly and asserts that the row is dead-lettered or that the diagnostic is emitted, depending on the chosen design.
  - id: AC-4
    statement: Existing Maybe EventId fire actions keep compiling and keep their current behaviour through a documented adapter, so consumers can migrate one fire leg at a time.
    verification: The existing timer, drain, workflow-sleep, and keiro-ops timer tests pass unchanged through the adapter.
reviews:
  - kind: model
    reviewer: claude-code
    reviewed_at: 2026-09-27T20:30:00Z
    document_timestamp: 2026-09-27T20:30:00Z
    scope: technical-accuracy
    outcome: approved
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      The authoring model's own verification, not an independent review. It read
      keiro/src/Keiro/Timer.hs (runTimerWorkerWith, claimAndFireOne, drainDueTimersWith,
      defaultTimerWorkerOptions) and keiro/src/Keiro/Timer/Schema.hs (markTimerFired,
      cancelTimerStmt, deadLetterTimerStmt, TimerStatus) at tag keiro-0.19.0.0 (648c18d4), and
      measured the failure on the global database of mori://shinzui/rei.
---

# Make a timer fire outcome explicit and let a fire finish without an event

## Status

Proposed. No plan implements this request.

## Problem and evidence

`runTimerWorkerWith`, `drainDueTimersWith`, the workflow-sleep fire path, and `keiro-ops`'
`TimerFire` all take a fire action of type `TimerRow -> Eff es (Maybe EventId)`. In
`claimAndFireOne`, `Just eventId` calls `markTimerFired` and moves the row to `fired`. `Nothing`
does nothing, so the row stays `firing`. The worker documentation states this precisely: a fire
that returns `Nothing` "leaves the timer `Firing` until it becomes stale and is requeued on a later
worker pass". `defaultTimerWorkerOptions` sets `requeueStuckAfter = Just 300` and
`maxAttempts = Nothing`.

That leaves a consumer three gaps.

1. **`Nothing` means three things.** It is the only answer for "this row is not mine", "I failed and
   should be retried", and "I finished and there was nothing to record". The worker treats all three
   as the second one.
2. **There is no way to finish without an event.** `markTimerFired` requires an `EventId`. The only
   other terminal transitions a fire leg can reach are `cancelTimer`, which says the work was
   withdrawn, and `deadLetterTimer`, which says it failed. A sweep that evaluated every candidate
   and found nothing to change has no honest state to end in.
3. **The failure is silent and unbounded.** With the defaults, a fire leg that returns `Nothing`
   after doing its work is reclaimed every five minutes forever. `attempts` grows, `last_error` stays
   empty, and nothing fails. The stuck-timer gauge exists only when the host passes a
   `KeiroMetrics` handle.

### Consumer evidence

`mori://shinzui/rei` hit all three. Its reminder fire leg and its daily dormancy sweep return
`Nothing` on every path, because their authors read `Nothing` as "one-shot, done". The reminder leg
triggers or completes the reminder through ordinary commands whose helpers return `()`. The dormancy
sweep evaluates every active intention and may append nothing at all. On Rei's global database on
2026-09-27:

- 134 timers were `firing`. Attempt counts ranged from 146 to 5,902, and every `last_error` was empty.
- No dormancy timer created in the previous ten days had reached `fired`. Each stuck one re-ran the
  complete dormancy sweep on every requeue.
- The reminders behind the stuck reminder timers were already `triggered`, `completed`, or
  `cancelled`. The work had been done once, and the reclaims were pure waste.
- An earlier Rei release classified the growing count as "operational debt" for three weeks before
  the cause was found.

Rei's Kioku integration had already met the same trap and worked around it locally. `Kioku`'s
`FireOutcome` (`FireCompleted`, `FireRetryLater`, `FireFailedPermanently`, `FireDeferred`,
`FireNotMine`) and its `applyFireOutcome` reschedule or dead-letter the claimed row before
collapsing to `Maybe EventId`. A second consumer rebuilding the same adapter is evidence that the
outcome belongs in Keiro. Kioku's adapter also has no completed-without-event case, because Kioku
always appends one.

The interim fix Rei will ship retires a completed row with `cancelTimer`. That ends the loop but
records the wrong meaning: an operator cannot tell a fire that did its work from one that was
withdrawn.

## Requested behavior

Introduce an explicit fire outcome and make the worker apply it. The names below are illustrative.

```haskell
data TimerFireOutcome
  = TimerCompleted EventId          -- today's Just: mark fired with the event
  | TimerCompletedWithoutEvent Text -- new: terminal, not requeued, reason recorded
  | TimerRetryAfter NominalDiffTime Text -- reschedule the claimed row with a delay and a note
  | TimerFailed Text                -- dead-letter with the reason
```

- Add a terminal `TimerStatus` for a fire that completed without an event (for example `Completed`),
  or record completion without an event under `fired` with a nullable `fired_event_id` and a reason.
  Either way, a caller must be able to tell it apart from `cancelled` and `dead`.
- Keep a transactional form, so a fire leg can append its effect and record the outcome atomically,
  in the same spirit as `cancelTimerTx`.
- Make the silent-forever case visible by default. Options include a finite default `maxAttempts`,
  a worker log line when a row is reclaimed after returning a non-terminal outcome N times, or both.
- Keep `Maybe EventId` fire actions working through an adapter
  (`Just e -> TimerCompleted e`; `Nothing -> ` today's requeue behaviour), and document that the
  adapter preserves the retry-forever semantics.

## Acceptance criteria

See the frontmatter.

## Requested deliverables

- The outcome type, the worker change in `claimAndFireOne` and `drainDueTimersWith`, and the
  compatibility adapter.
- The terminal state, its migration if the status is new, and support in `lookupTimerInspection` and
  the `keiro-ops` timer commands.
- A changelog entry and a guide section that state the fire contract in one table: outcome → row
  state → will it run again.

## Consumer references

- `mori://shinzui/rei`, project-relative paths `rei-core/src/Rei/Infrastructure/ReiTimers.hs`,
  `rei-core/src/Rei/Modules/Reminder/Reactor/FireTimer.hs`, and
  `rei-core/src/Rei/Modules/Intention/Reactor/DormancyTimer.hs` (artifact-level URIs pending).
- `mori://shinzui/kioku`, project-relative path `kioku-core/src/Kioku/Distill/Timer/Worker.hs`
  (`FireOutcome`, `applyFireOutcome`; artifact-level URI pending).
