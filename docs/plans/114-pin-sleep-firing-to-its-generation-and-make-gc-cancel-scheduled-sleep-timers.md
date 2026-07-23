---
id: 114
slug: pin-sleep-firing-to-its-generation-and-make-gc-cancel-scheduled-sleep-timers
title: "Pin sleep firing to its generation and make GC cancel scheduled sleep timers"
kind: exec-plan
created_at: 2026-07-23T03:02:27Z
intention: intention_01ky88vm7tew7akz5pgfq0fbqg
master_plan: "docs/masterplans/16-harden-the-durable-execution-engine-surfaced-by-the-2026-07-durable-execution-review.md"
---

# Pin sleep firing to its generation and make GC cancel scheduled sleep timers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Parent: `docs/masterplans/16-harden-the-durable-execution-engine-surfaced-by-the-2026-07-durable-execution-review.md` (EP-3 of that master plan). No hard or soft dependencies. Sibling plans: `docs/plans/112-make-workflow-journal-snapshots-wake-safe-with-a-step-index-fallback-on-await.md`, `docs/plans/113-deliver-child-failure-and-awakeable-signals-across-generations-and-races.md`, `docs/plans/115-record-patch-sets-at-rotation-and-add-workflow-failure-recovery-and-lease-renewal.md` (complementary to 115's patch-recording fix — see Context).


## Purpose / Big Picture

A durable *sleep* pauses a keiro workflow with nothing in memory: the only durable state is one row in `keiro_timers`, and a timer worker later fires it by appending the sleep's completion to the workflow's journal. The July 2026 durable-execution review confirmed three lifecycle defects around that row:

1. WFX-3: a sleep timer's fire action resolves the target *generation at fire time*, so a stale re-fire (crash between the journal append and marking the timer fired, then a requeue after `continueAsNew`) lands on the **next** generation and resolves a same-named sleep there almost immediately — a 24-hour sleep can complete after about 5 minutes.
2. WFX-1: every resume pass that re-enters a not-yet-resolved sleep unconditionally overwrites the instance's `wake_after` wake hint with `now + delta`, even when the timer row already exists. At the wake boundary this *postpones discovery* of an already-fired sleeper by up to a full extra sleep duration — a 24-hour sleep takes about 48 hours to wake.
3. WFX-6: garbage collection deletes a terminal workflow's streams, steps, awakeables, children, and instance row, but only *terminal-status* timer rows — a still-`scheduled` sleep timer survives, later fires against nothing, **re-creates** the journal stream and a fresh `running` instance row, and the resume worker then re-executes every side effect before the sleep. A cancelled, GC'd workflow can fully re-execute weeks later.

After this plan: a sleep fire is pinned to the generation that armed it (a stale re-fire collapses to an idempotent no-op); an already-fired sleeper is discovered promptly (the re-arm no longer postpones `wake_after`, and firing clears it); and GC removes *all* of an instance's sleep timers while the fire action refuses to append for a terminal instance. All three fixes are code-only — no migration (the master plan expects this plan to claim no number in `keiro-migrations/migrations/`).

To see it working: run `cabal test keiro-test` from the repository root and observe the new tests — most notably one in which a deliberately staged stale re-fire no longer resolves the next generation's sleep, and one in which a GC'd cancelled workflow stays deleted instead of resurrecting.


## Progress

This is the plan-authoring-time checklist of the work. Update it at every stopping point.

- [x] (2026-07-23 20:47Z) M1: `sleepTimerPayload` carries the arming generation; `parseSleepPayload` returns it.
- [x] (2026-07-23 20:47Z) M1: `deterministicJournalId` exported from `Keiro.Workflow`; `workflowSleepFireAction` appends pinned to the resolved generation.
- [x] (2026-07-23 20:47Z) M1: legacy-payload generation resolution via timer-id matching implemented and unit-tested.
- [x] (2026-07-23 20:47Z) M1: staged stale-re-fire-across-rotation test passes; full suite green (`cabal test keiro-test`: 362 examples, 0 failures).
- [x] (2026-07-23 20:51Z) M2: `scheduleTimerOnceTx` reports whether it inserted; the sleep arm writes `wake_after` only on actual insert.
- [x] (2026-07-23 20:51Z) M2: firing clears `wake_after` in the same transaction as the journal append; wrong in-code comment corrected.
- [x] (2026-07-23 20:51Z) M2: deterministic no-postponement test passes; existing "fires a sleep longer than the resume cadence" test tightened; full suite green (363 examples, 0 failures).
- [ ] M3: GC deletes all workflow-sleep timer rows for the instance regardless of status.
- [ ] M3: fire action refuses (and cancels the timer) when the instance row is terminal.
- [ ] M3: orphan-fire resurrection test passes; GC tests (deletion, mid-crash convergence) green; full suite green.
- [ ] `CHANGELOG.md` entry written; master plan 16 Progress boxes for EP-3 ticked and registry status updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Milestone 1 validation (2026-07-23): the current suite contains 362
  examples rather than the authoring-time 335 because sibling plans and
  intervening work landed first. The focused crash-window test passed, and the
  full 362-example suite passed with zero failures.
- Milestone 2 validation (2026-07-23): a zero-delay timer provides a
  deterministic wake-boundary test without wall-clock tolerance. The resume
  pass re-entered the arm, preserved the exact original `wake_after`, the fire
  transaction cleared it, and the next resume pass completed. The focused
  sleep group passed 13 examples and the full suite passed 363 examples.


## Decision Log

Record every decision made while working on the plan.

- Decision: Legacy sleep-timer payloads (no `gen` field) resolve their target generation by *matching the row's timer id* against `sleepTimerId name wid g fullStep` for g from the current generation down to 0, falling back to current-generation behavior (with the fire proceeding) only if nothing matches.
  Rationale: The timer id is a deterministic v5 UUID over components that include the generation (`keiro/src/Keiro/Workflow/Sleep.hs:169-194`), so although the hash cannot be inverted, candidate generations can be tested exactly, and the scan is a handful of pure UUID computations bounded by the current generation. This closes the WFX-3 crash window for rows armed *before* this change too, instead of only for newly armed sleeps. The no-match fallback covers operator-crafted rows and keeps them firing as today.
  Date: 2026-07-23

- Decision: Fix WFX-1 with both recommended halves — write `wake_after` only when the timer insert actually inserted, *and* clear `wake_after` inside the fire's append transaction.
  Rationale: The guard removes the writer that postpones an already-armed sleeper; the clear makes an already-fired sleeper immediately discoverable even if some future writer reintroduces a postponement. Both are one cheap statement each (belt and braces, per the review's recommendation). `scheduleTimerOnceTx`'s only production caller is the sleep arm (grep-verified: `keiro/src/Keiro/Workflow/Sleep.hs:249` plus the re-export in `keiro/src/Keiro/Timer.hs:25`), so changing its return type to `Bool` is a contained breaking change, noted in the changelog.
  Date: 2026-07-23

- Decision: Export `deterministicJournalId` from `Keiro.Workflow` so the sleep fire action can compose its pinned append and the `wake_after` clear in one transaction via `prepareJournalAppend`.
  Rationale: The fire action must return the appended `EventId` (the timer worker marks the row fired with it) while running extra statements in the same transaction; `appendJournalEntryReturningId` owns its own transaction and resolves the generation itself (`keiro/src/Keiro/Workflow.hs:767-780`). The id derivation is already a documented stable contract (haddock at `Workflow.hs:931-941`); exporting it is narrower than adding a parallel gen-pinned append-with-extras helper.
  Date: 2026-07-23

- Decision: The fire action's orphan guard refuses only when the instance row *exists and is terminal* (completed/cancelled/failed), cancelling the timer row via `cancelTimer`; a *missing* instance row still fires.
  Rationale: A missing row is also the legitimate crash-recovery shape — a workflow whose first operation is a sleep journals nothing before suspending, and if the process dies before `markInstanceSuspended` (`keiro/src/Keiro/Workflow.hs:516`), the timer fire's append-and-upsert is the only path that makes the instance discoverable again. Refusing on missing rows would orphan that workflow. The GC hole is closed primarily by deleting the timer rows (the instance row is deleted in the same transaction as the timers, `keiro/src/Keiro/Workflow/Gc.hs:74-80`, so post-fix GC leaves no timer to fire); the terminal-row guard covers the mid-GC-crash window in which streams are already deleted but the instance row survives, preventing stream re-creation. `cancelTimer` (not `deadLetterTimer`) because an abandoned timer of a terminal workflow is the *designed* meaning of `cancelled`, and the row transitions `firing -> cancelled` are permitted (`keiro/src/Keiro/Timer/Schema.hs`, `cancelTimerStmt` matches `scheduled` and `firing`).
  Date: 2026-07-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

- Milestone 1 (2026-07-23): workflow-sleep payloads now record the arming
  generation, legacy payloads recover it from the deterministic timer id, and
  the fire action appends directly to that generation. The staged
  append-committed/mark-lost crash window now leaves generation 1 suspended
  while retiring the stale generation-0 timer as fired.
- Milestone 2 (2026-07-23): the first arm now owns both `fire_at` and
  `wake_after`; replay arms cannot postpone either value. A successful fire
  clears the hint atomically with its journal append, so the resume worker can
  discover the completion immediately.


## Context and Orientation

This section is self-contained.

ADR context: `docs/adr/` contains only `0001-keiro-pgmq-job-processing-telemetry-contract.md` (pgmq job-processing telemetry) — no relevant ADR exists for this work.

### The moving parts

A *durable workflow* (`keiro/src/Keiro/Workflow.hs`) journals named step results to a kiroku event stream (kiroku is the append-only Postgres event store this repository builds on) and replays them on re-runs. `sleepNamed` (`keiro/src/Keiro/Workflow/Sleep.hs:225-249`) is `awaitStep` on the reserved name `sleep:<suffix>`: on the miss path its *arm* inserts one `keiro_timers` row with a deterministic id and suspends the run. The row's JSON payload today is only `{"kind":"keiro.workflow.sleep","step":"sleep:<suffix>"}` (`Sleep.hs:142-144`). The timer id is generation-namespaced — a v5 UUID over `("keiro":"workflow-sleep":name:id:<gen>:step)` for generation ≥ 1, with a legacy no-generation shape for generation 0 (`Sleep.hs:169-194`) — but the namespacing only makes *rows* distinct; it does not pin where a fire *appends*.

A *generation* is a journal epoch: `continueAsNew` rotates the workflow onto a fresh stream, and `currentGeneration` is `MAX(generation)` over the step index, 0 when no rows exist (`keiro/src/Keiro/Workflow/Schema.hs:210-222`). `rotateGeneration` (`keiro/src/Keiro/Workflow.hs:817-844`) touches no timers. The advertised rolling-poller idiom re-arms the *same sleep name* every generation (test helper `rollingSleepWorkflow`, `keiro/test/Main.hs:8537-8545`).

The *timer worker* (`keiro/src/Keiro/Timer.hs`) claims a due row (flipping it `scheduled -> firing` and bumping attempts, `keiro/src/Keiro/Timer/Schema.hs:280-303`), runs the caller's fire action, and — only if the action returns an `EventId` — marks the row `fired` (`Timer.hs:163-164`). A crash between those two steps leaves the row `firing`; each worker pass first requeues `firing` rows older than `requeueStuckAfter` back to `scheduled` *preserving their payload* (`Timer/Schema.hs:368-379`), default 300 seconds (`Timer.hs:89-91`). Re-claiming has zero dedupe against the journal. The workflow fire action is `workflowSleepFireAction` (`Sleep.hs:278-292`): it reconstructs the workflow identity from the row and appends the completion via `appendJournalEntryReturningId` — which resolves `gen <- currentGeneration` **at fire time** (`keiro/src/Keiro/Workflow.hs:774`).

*Discovery and `wake_after`*: the resume worker (`keiro/src/Keiro/Workflow/Resume.hs`) discovers top-level workflows via `findUnfinishedWorkflowIds`, which skips rows whose `wake_after` is in the future (`keiro/src/Keiro/Workflow/Schema.hs:228-239`) — a self-expiring "don't bother before this time" hint for sleepers. The **only** writer of `wake_after` in the entire codebase is the sleep arm's `setWorkflowWakeAfterTx` call (`Sleep.hs:249`; the statement is an unconditional UPDATE, `Schema.hs:241-255`) — grep-verified; nothing ever clears it. The push-aware worker uses the same filtered discovery (`Resume.hs:524-537`), so a NOTIFY cannot rescue a postponed sleeper. Children are immune: they are discovered via `findRunningChildIds`, which has no `wake_after` filter (`keiro/src/Keiro/Workflow/Child/Schema.hs:277-286`; unioned at `Resume.hs:300-303`).

*GC* (`keiro/src/Keiro/Workflow/Gc.hs`): `deleteWorkflow` (63-80) hard-deletes every generation's stream (snapshots first), then in one transaction deletes step rows, awakeables, child links, **terminal-status sleep timers only** (`deleteTerminalSleepTimersStmt`, 165-180: `status IN ('fired','cancelled','dead')`), and the instance row. Eligibility requires a terminal instance older than retention (85-111).

### Finding 1 — WFX-3: a stale re-fire resolves the next generation's sleep early

Crash window: generation g's fire appends `sleep:<name>` to the journal, the process dies before `markTimerFired`, and the row is left `firing`. The workflow wakes (the append resolved its sleep), runs to `continueAsNew`, and generation g+1 arms the *same-named* sleep (rolling-poller idiom). At `requeueStuckAfter` (default 300 s) the stale row is requeued with its original payload, re-claimed, and re-fired: `appendJournalEntryReturningId` resolves the *current* generation — now g+1 — where the in-transaction index check (`Workflow.hs:733-734`) finds no `sleep:<name>` row (g+1's sleep is pending), so the append lands and g+1's 24-hour sleep resolves after ~5 minutes. Secondary effect: a stale fire landing on a freshly rotated generation before its first run also defeats `recordPatchSetIfFresh`'s fresh-start check (`Workflow.hs:523-534`) — `docs/plans/115-record-patch-sets-at-rotation-and-add-workflow-failure-recovery-and-lease-renewal.md` fixes that fragility at the rotation site; this plan removes this particular stale writer. The two fixes are complementary, not ordered.

### Finding 2 — WFX-1: the re-arm postpones an already-fired sleeper

The sleep arm re-runs on every resume pass (that is the arm contract). Each re-arm recomputes `fireAt = addUTCTime delta now` (`Sleep.hs:242`) and runs `scheduleTimerOnceTx request >> setWorkflowWakeAfterTx name wid fireAt` (`Sleep.hs:249`). `scheduleTimerOnceTx` is insert-only (`ON CONFLICT DO NOTHING`, `Timer/Schema.hs:260-278`) so the *timer* keeps its first `fire_at` — but the `wake_after` write is unconditional. At the wake boundary (`wake_after = fire_at`), if a resume pass re-arms before/while the fire commits, `wake_after := now + delta` pushes discovery a full delta into the future; nothing clears it, so an already-fired sleeper sits invisible until the hint self-expires — one extra delta per postponement (repeated postponement requires a timer-worker outage at each successive boundary; otherwise exactly one extra delta). Scope correction from verification: top-level workflows only (children immune, as above). The in-code comment at `Sleep.hs:245-248` claims the overwrite is benign — wrong for the post-fire case; it must be corrected. The existing test "fires a sleep longer than the resume cadence under an active resume worker" (`keiro/test/Main.hs:7577-7598`) actually *exhibits* the bug — it completes only after roughly twice the sleep duration inside a generous retry budget — and must be tightened.

### Finding 3 — WFX-6: GC leaves scheduled timers that resurrect the workflow

GC deletes everything about a terminal instance except non-terminal timer rows. The surviving `scheduled` sleep later fires: `workflowSleepFireAction` has no instance-existence or terminal guard; `currentGeneration` returns 0 (step rows gone); the journal append *re-creates the kiroku stream* (hard delete removes the `streams` row; the append upsert re-creates it — `appendAnyVersionSQL`'s `stream_upsert` CTE, `kiroku-store/src/Kiroku/Store/SQL.hs:322-372`; re-creation after hard delete is documented in kiroku's `Types.hs` around line 47); the same transaction's `upsertInstanceTx` INSERTs a fresh `running` row (the terminal-status guard applies only to the `ON CONFLICT` update path, `keiro/src/Keiro/Workflow/Instance.hs:116-135`); discovery finds it; a claim succeeds; and the journal now contains *only* `sleep:<name>` — so every step before the sleep re-executes its side effects. A cancelled, GC'd workflow fully re-executes weeks later. Realistic orphan source (verified): cancelling a child writes journal markers but cancels **no** timers (`keiro/src/Keiro/Workflow/Child.hs:274-286`, `ensureChildCancelled` 391-426), and `cancelTimer` has no caller in any lifecycle path (operator-only, per `Sleep.hs:70-74`). Pre-GC the fire is benign — the instance upsert's terminal guard holds and the appended entry is inert; deleting the row while keeping the timer is the hole. The existing GC test seeds only a `fired` timer (`keiro/test/Main.hs:8227-8264`, seeding at 8246), which is why this was never caught.

### Verified-sound behavior the fixes must not regress

Insert-only sleep arming with first-arm-wins `fire_at` (test "does not postpone fire_at when a resume pass re-arms the sleep", `keiro/test/Main.hs:7509-7531`); fire idempotence within a generation (deterministic id + advisory lock + in-transaction index pre-check); generation-namespaced timer ids with the gen-0 legacy derivation (test "uses generation-namespaced timer ids after continueAsNew", 7600-7621); GC ordering — dependents first, instance last, mid-crash converges (tests at 8227 and 8266); `wake_after` self-expiry semantics (tests "skips a sleeping workflow until wake_after expires" at 7533, "does not re-invoke a parked sleeper before wake_after" at 7550) and the missing-instance-row arm no-op (7565).

The test suite: `keiro-test` (335 examples, 0 failures at authoring time) self-provisions PostgreSQL via `withMigratedSuite` (`keiro/test/Main.hs:353`); each example gets a fresh store.


## Plan of Work

Three milestones, one per finding. Each ends with the full suite green.

### Milestone 1 — pin the fire to the generation that armed it

Scope: the payload gains the generation, the fire action appends to exactly that generation, and legacy rows resolve their generation by id-matching.

In `keiro/src/Keiro/Workflow/Sleep.hs`:

- `sleepTimerPayload` (142-144) takes the generation and writes it:

```haskell
sleepTimerPayload :: Int -> Text -> Value
sleepTimerPayload gen fullStep =
    object
        [ "kind" Aeson..= workflowSleepKind
        , "step" Aeson..= fullStep
        , "gen" Aeson..= gen
        ]
```

- `parseSleepPayload` (150-157) returns `Maybe (Text, Maybe Int)` — the step plus the generation when present (`Nothing` for legacy rows). Update its haddock and the module-header "Payload discriminator" bullet (`Sleep.hs:47-52`).
- `sleepNamed`'s arm passes `gen` (already in scope) to `sleepTimerPayload`.
- `workflowSleepFireAction` (278-292) resolves the target generation: the payload's `gen` when present; otherwise scan `g` from `currentGeneration name wid` down to 0 and pick the `g` for which `sleepTimerId name wid g full == row ^. #timerId` (pure UUID equality; covers both the ≥1 and the legacy gen-0 id shapes); otherwise fall back to the current generation (operator-crafted row — behave as today). Then append pinned to that generation instead of letting the helper resolve it. In `keiro/src/Keiro/Workflow.hs`, export `deterministicJournalId` (see Decision Log) and have the fire action build its own transaction:

```haskell
appendTx <- prepareJournalAppend name wid targetGen (StepRecorded full Null now)
outcome <- runTransaction appendTx   -- M2 composes the wake_after clear here
case outcome of
    JournalAppendConflict err -> throwIO (WorkflowJournalAppendError (Text.pack (show err)))
    _ -> pure (Just (deterministicJournalId name wid targetGen full))
```

An already-present generation-g entry now collapses to `JournalAlreadyPresent`, the action still returns the deterministic id, and the worker marks the stale row `fired` — the re-fire is a complete no-op for generation g+1.

Staged stale-re-fire test (new group `"Keiro.Workflow sleep generation pinning"` in `keiro/test/Main.hs`; all four sibling plans append distinct groups, additive only): using `rollingSleepWorkflow`-style bodies with a nonzero delta, (1) arm the gen-0 sleep and let the worker claim it (`claimDueTimer`), (2) simulate the crash by invoking `workflowSleepFireAction` on the claimed row directly and *not* marking it fired (this is exactly the append-committed/mark-lost state), (3) drive the workflow so it wakes and rotates, arming the same-named sleep on generation 1 with a long delta, (4) requeue the stale row (`requeueStuckTimers 0 now`) and run a timer-worker pass. Assert: before the fix, generation 1's sleep resolves (the workflow completes early); after the fix, generation 1 is still `Suspended`, the stale row is `fired`, and generation 1's own timer row still exists with its original `fire_at`. Add a pure unit test for the legacy-id generation scan (derive ids for gens 0..2 and assert the scan recovers each).

Acceptance: new tests pass; tests 7509, 7600, and the sleep group all green; full suite green.

### Milestone 2 — stop postponing, and clear, `wake_after`

Scope: the re-arm writes the hint only when it actually armed; firing clears the hint; the wrong comment is corrected; the exhibiting test is tightened.

In `keiro/src/Keiro/Timer/Schema.hs`: change `scheduleTimerOnceTx :: TimerRequest -> Tx.Transaction Bool`, returning whether the INSERT inserted (decode `(> 0) <$> D.rowsAffected` on the existing `ON CONFLICT DO NOTHING` statement). Update its haddock; note the breaking return-type change in `CHANGELOG.md` (sole production caller is the sleep arm).

In `keiro/src/Keiro/Workflow/Schema.hs`: add and export `clearWorkflowWakeAfterTx :: WorkflowName -> WorkflowId -> Tx.Transaction ()` (`UPDATE keiro.keiro_workflows SET wake_after = NULL, updated_at = now() WHERE workflow_id = $1 AND workflow_name = $2`). Re-export from `Keiro.Workflow` next to `setWorkflowWakeAfterTx` (`keiro/src/Keiro/Workflow.hs:106`).

In `keiro/src/Keiro/Workflow/Sleep.hs`: the arm becomes

```haskell
runTransaction $ do
    inserted <- scheduleTimerOnceTx request
    when inserted (setWorkflowWakeAfterTx name wid (request ^. #fireAt))
```

and the comment at 245-248 is replaced with the truth: the hint is written once, by the arm that actually created the timer row, so a re-arm can never postpone an armed (or already-fired) sleeper; firing clears the hint. In `workflowSleepFireAction`, compose the clear into M1's append transaction: `runTransaction (appendTx <* clearWorkflowWakeAfterTx name wid)`.

Deterministic no-postponement test (same group): with delta = 1 s, (1) run → `Suspended` (hint set to t0+1), (2) wait ~1.2 s so both the timer and the hint are due, (3) run `resumeWorkflowsOnce` once — this re-enters the arm (the postponement moment), (4) run one timer-worker pass (fires the sleep), (5) immediately run `resumeWorkflowsOnce` again and assert `discovered >= 1` and `completed == 1`. Before the fix, step 3 pushed `wake_after` ~1 s into the future, so step 5 reports `discovered == 0` and the workflow stalls an extra delta. Also tighten the existing test at 7577-7598: replace its open-ended drive loop with the same wait-past-delta / one-resume-pass / one-timer-pass / one-resume-pass sequence asserting completion on that final pass, so a regression fails fast instead of merely consuming budget.

Acceptance: both tests pass; `wake_after` self-expiry tests (7533, 7550), the fire_at test (7509), and the missing-instance-row test (7565 — the arm's `when inserted` path must still no-op cleanly when the instance row is absent) all green; full suite green.

### Milestone 3 — GC removes every sleep timer; the fire action refuses terminal instances

Scope: close the resurrection hole at both ends.

In `keiro/src/Keiro/Workflow/Gc.hs`: rename `deleteTerminalSleepTimersStmt` to `deleteSleepTimersStmt` and drop the status filter (delete every row matching `correlation_id`, `process_manager_name`, and `payload->>'kind' = 'keiro.workflow.sleep'`, regardless of status — safe because eligibility already requires a terminal instance). Update the module header (1-8) and the call site comment (78-79).

In `keiro/src/Keiro/Workflow/Sleep.hs`: `workflowSleepFireAction` gains the terminal-instance guard before appending — `lookupInstance name wid` (import from `Keiro.Workflow.Instance`); if the row exists with status `WfCompleted`/`WfCancelled`/`WfFailed`, call `cancelTimer (row ^. #timerId)` and return `Nothing` (no append, no stream re-creation; the `firing -> cancelled` transition is permitted). A *missing* row still fires (Decision Log — that is the crash-recovery path). Update the fire action's haddock: `Nothing` now means "not a workflow sleep, or a sleep of a terminal workflow (timer cancelled)"; `runWorkflowTimerWorker`'s delegation to the PM fallback is harmless for the second case because the PM fire action will not recognize the sleep payload.

Orphan-fire resurrection test (new group `"Keiro.Workflow.Gc sleep timers"`): (1) run a workflow with a counted step then a long `sleepNamed` → `Suspended`, `scheduled` timer exists; (2) cancel the workflow (append its `WorkflowCancelled` marker via `appendJournalEntry name wid (WorkflowCancelled now)` — the operator-shaped cancellation for a top-level workflow); (3) GC with retention 0 and assert the instance is deleted **and the timer rows are gone** (before the fix the `scheduled` row survives); (4) run a timer-worker pass at a time past `fire_at` and assert: no `keiro_workflows` row reappears, no journal stream exists (`lookupStreamId` returns `Nothing`), and the side-effect counter is unchanged. Defense-in-depth variant for the mid-GC-crash window: craft the pre-fix leftover state directly (terminal instance row present, `scheduled` sleep timer present, streams deleted), run a timer-worker pass, and assert the timer ends `cancelled` with no append and no stream re-creation.

Acceptance: both tests pass; existing GC tests (8227, 8266) green — note 8227's row-count helper counts timer rows, and the fixed GC still deletes the `fired` row it seeds, so its expectations should hold unchanged; full suite green. Write the `CHANGELOG.md` entry (all three fixes plus the `scheduleTimerOnceTx` return-type change), tick EP-3's three boxes in master plan 16, and update its registry row.


## Concrete Steps

All commands from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`.

```bash
cabal build keiro
cabal test keiro-test
```

(`just haskell-test` aliases the test command; the suite provisions its own PostgreSQL.) Baseline at authoring time:

```text
335 examples, 0 failures
```

Iterate on the new groups with:

```bash
cabal test keiro-test --test-options='--match "sleep generation pinning"'
cabal test keiro-test --test-options='--match "Gc sleep timers"'
```

Suggested commits:

```text
fix(workflow): pin sleep firing to the generation that armed it (WFX-3)
fix(workflow)!: guard and clear wake_after around sleep arming and firing (WFX-1)
fix(workflow): GC deletes all sleep timers; sleep fire refuses terminal instances (WFX-6)
```


## Validation and Acceptance

Acceptance is behavioral:

1. Stale re-fire: after the staged crash-and-rotate sequence, generation g+1's long sleep remains `Suspended` and its timer row keeps its original `fire_at`; the stale generation-g row ends `fired`. Before this plan the same sequence completes g+1's sleep almost immediately.
2. Prompt wake: with a 1-second sleep, the resume pass immediately following the timer fire reports the workflow completed. Before this plan, a resume pass that re-armed at the boundary postpones discovery by a further full second (and, at production deltas, by hours).
3. No resurrection: a cancelled, GC'd workflow stays deleted after its old timer's due time passes — no instance row, no journal stream, no re-executed side effects. Before this plan, the surviving `scheduled` timer re-creates both and the workflow re-runs from the top.
4. `cabal test keiro-test` prints `0 failures`, including every pinned property in Context ("Verified-sound behavior…").

Failure signatures: test 1 failing with an early completion means the fire action still resolves the generation at fire time (check the payload plumbing and the pinned `prepareJournalAppend`); test 2 reporting `discovered == 0` on the final pass means the arm still writes `wake_after` unconditionally or the fire transaction does not clear it; test 3 finding a fresh `running` row means the GC statement still filters by status or the guard branch is not reached.


## Idempotence and Recovery

Code-only; no migration; every edit is revertible per-commit. The new payload field is additive JSON — old workers ignore it, and the new worker handles old payloads via the id-matching scan, so mixed-version deployments degrade to at-worst-current behavior, never worse. GC's broader delete is idempotent (DELETE by key), and re-running GC after a mid-transaction crash converges exactly as the existing convergence test (8266) requires. The fire action's guard is read-then-cancel; if the process dies between them the row stays `firing` and is requeued, and the next pass re-runs the same guard.


## Interfaces and Dependencies

No new packages. End-state interfaces per milestone:

- M1 — `keiro/src/Keiro/Workflow/Sleep.hs`: `sleepTimerPayload :: Int -> Text -> Value`; `parseSleepPayload :: Value -> Maybe (Text, Maybe Int)`; `keiro/src/Keiro/Workflow.hs`: `deterministicJournalId :: WorkflowName -> WorkflowId -> Int -> Text -> EventId` added to the export list (implementation unchanged).
- M2 — `keiro/src/Keiro/Timer/Schema.hs`: `scheduleTimerOnceTx :: TimerRequest -> Tx.Transaction Bool` (breaking return-type change; sole caller updated); `keiro/src/Keiro/Workflow/Schema.hs`: new export `clearWorkflowWakeAfterTx :: WorkflowName -> WorkflowId -> Tx.Transaction ()`, re-exported from `Keiro.Workflow`.
- M3 — `keiro/src/Keiro/Workflow/Gc.hs`: `deleteSleepTimersStmt` (all statuses); `keiro/src/Keiro/Workflow/Sleep.hs`: `workflowSleepFireAction` unchanged in type, new terminal-instance guard using `Keiro.Workflow.Instance.lookupInstance` and `Keiro.Timer.cancelTimer`.

Cross-plan coordination (master plan Integration Points): this plan is expected to claim **no** migration number. Its WFX-3 fix removes one of the async writers behind the patch-recording defect fixed in `docs/plans/115-record-patch-sets-at-rotation-and-add-workflow-failure-recovery-and-lease-renewal.md`; both must land for the combined property (a rotated generation always records its patch set, and a stale fire can never touch a later generation) to hold, but neither orders the other. All four sibling plans append distinct test groups to `keiro/test/Main.hs`.
