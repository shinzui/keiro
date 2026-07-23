---
id: 112
slug: make-workflow-journal-snapshots-wake-safe-with-a-step-index-fallback-on-await
title: "Make workflow journal snapshots wake-safe with a step-index fallback on await"
kind: exec-plan
created_at: 2026-07-23T03:02:27Z
master_plan: "docs/masterplans/16-harden-the-durable-execution-engine-surfaced-by-the-2026-07-durable-execution-review.md"
---

# Make workflow journal snapshots wake-safe with a step-index fallback on await

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Parent: `docs/masterplans/16-harden-the-durable-execution-engine-surfaced-by-the-2026-07-durable-execution-review.md` (EP-1 of that master plan). No hard or soft dependencies; this plan can land in any order relative to its siblings (`docs/plans/113-deliver-child-failure-and-awakeable-signals-across-generations-and-races.md`, `docs/plans/114-pin-sleep-firing-to-its-generation-and-make-gc-cancel-scheduled-sleep-timers.md`, `docs/plans/115-record-patch-sets-at-rotation-and-add-workflow-failure-recovery-and-lease-renewal.md`).


## Purpose / Big Picture

Keiro's durable workflows journal every step result to a per-workflow event stream, and a *snapshot* is a performance optimization that saves the folded step map at a known stream version so the next run can replay only the tail. The July 2026 durable-execution review found (finding WFC-1, the initiative's only CRITICAL, adversarially verified) that a snapshot can permanently hide a *wake completion* — an awakeable signal or a child result — that another writer journaled while the snapshotting run was mid-flight. The hidden entry is at a stream version at or below the snapshot's version, so the tail read never returns it, the in-memory map never contains it, and the `Await` handler suspends the run forever. The stall is silent: a suspended workflow never trips the crash-attempt ceiling, so nothing ever escalates.

After this plan, the `Await` miss path consults the authoritative `keiro_workflow_steps` index (a point query) before arming and suspending. If the awaited step is already journaled — no matter how the in-memory map became stale — the run adopts the recorded result and proceeds instead of suspending. This closes the entire stale-visibility class in one place, which is why the master plan chose it over snapshot invalidation (see the master plan's Decision Log). It also masks the same-generation variant of the missing-`ChildFailed`-delivery gap fixed properly in `docs/plans/113-deliver-child-failure-and-awakeable-signals-across-generations-and-races.md`, because a parent whose stale map hides an already-journaled `{"failed": reason}` sentinel will now find it in the index and throw `WorkflowChildFailed` instead of suspending.

To see it working: run `cabal test keiro-test` from the repository root and observe the new "Keiro.Workflow snapshot wake-safety" tests, most notably one in which a workflow whose step action signals its own awakeable mid-run — under `snapshotPolicy = Every 1` — completes on that same run instead of suspending forever.


## Progress

This is the plan-authoring-time checklist of the work. Update it at every stopping point.

- [ ] M1: `lookupStepResult` (Eff-level point query) added to `keiro/src/Keiro/Workflow/Schema.hs` and exported.
- [ ] M1: `Await` miss path in `keiro/src/Keiro/Workflow.hs` consults `lookupStepResult` before arming; on a hit it adopts the stored value into the in-memory map and delivers it.
- [ ] M1: no-spurious-delivery regression test (a genuinely unresolved await under `Every 1` still suspends and fabricates nothing).
- [ ] M1: full suite green (`cabal test keiro-test`).
- [ ] M2: mid-run staleness test — awakeable signalled from within a step action under `Every 1`; run completes instead of suspending.
- [ ] M2: snapshot staleness test — two-phase awakeable body; resume from a stale snapshot delivers instead of stalling.
- [ ] M2: child-completion variant — child driven to completion inside a parent step action; parent's `awaitChild` delivers.
- [ ] M2: full suite green.
- [ ] M3: `loadJournal` haddock corrected (the "byte-for-byte" claim removed and replaced with the true contract).
- [ ] M3: `docs/guides/durable-workflows.md` Snapshots section notes the index fallback; `CHANGELOG.md` entry written.
- [ ] M3: full suite green; master plan 16 Progress boxes for EP-1 ticked and registry status updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Fix the staleness at the `Await` miss path with a step-index point query, not by invalidating or rewriting snapshots.
  Rationale: Inherited from the master plan's Decision Log — the fallback closes the whole stale-visibility class regardless of which writer made the snapshot stale, reuses an existing indexed statement, and needs no write-path changes. Invalidation would only repair the writer that noticed the staleness and would leave every other cause (including plain in-memory staleness during the very first run that races a signal) open.
  Date: 2026-07-23

- Decision: The fallback applies to `Await` only, not to `Step` or `Patch` misses.
  Rationale: A `Step` miss with a stale map re-runs the user action (at-least-once side effects, the documented step contract) and then converges through `prepareJournalAppend`'s in-transaction index re-check (`keiro/src/Keiro/Workflow.hs:731-746` returns `JournalAlreadyPresent` with the stored value), so correctness self-heals; adding a pre-query would put a round trip on the hot path for no correctness gain. `Patch` misses append and converge the same way. `Await` is the only miss path that appends nothing and unconditionally suspends.
  Date: 2026-07-23

- Decision: The fallback query runs before the cancellation-pending check on the miss path.
  Rationale: It mirrors the hit path, which delivers a journaled result without checking cancellation; a journaled wake result is settled history and must replay identically forever. A cancellation marker is still honored at the next step/await boundary, exactly as it is when the result is found in the in-memory map.
  Date: 2026-07-23

- Decision: The fallback is generation-scoped (it queries the run's current generation only).
  Rationale: Journal replay is defined per generation; delivering a prior generation's entry onto a later generation would violate the rotation contract. Cross-generation delivery of child failure is `docs/plans/113-deliver-child-failure-and-awakeable-signals-across-generations-and-races.md`'s scope.
  Date: 2026-07-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This section is self-contained; read it even if you know the repository.

ADR context: `docs/adr/` contains only `0001-keiro-pgmq-job-processing-telemetry-contract.md`, which covers pgmq job-processing telemetry and does not touch the workflow engine — no relevant ADR exists for this work. The master plan proposes an ADR at initiative completion for the invariant this plan implements ("the step index is the authoritative record of journaled steps; every replay-visibility mechanism must fall back to it").

### The moving parts

A *durable workflow* is an ordinary `effectful` computation run by `runWorkflow` / `runWorkflowWith` in `keiro/src/Keiro/Workflow.hs`. Each `step name action` either runs `action` and *journals* (durably records) its JSON result, or — on a later run — returns the recorded result without re-running the action ("replay"). The journal is a kiroku event stream (kiroku is the append-only Postgres event store this repository builds on; its sources live in the sibling `kiroku` project). Each journal append transaction also upserts a row into the `keiro_workflow_steps` table — the *step index* — inside the same transaction, so index and journal never diverge (`keiro/src/Keiro/Workflow.hs:731-746`: advisory lock at 732 via `lockWorkflowStepTx`, in-transaction index re-check at 733-734 via `lookupStepResultTx`, append plus `recordStepTx` plus instance upsert at 735-746).

`awaitStep name arm` (the `Await` operation) is the suspension primitive: if `name` is journaled, its result is returned; otherwise the idempotent `arm` action runs (schedule a timer, register an awakeable row, assert a child link) and the run unwinds with the `Suspended` outcome. A *wake source* — `signalAwakeable` in `keiro/src/Keiro/Workflow/Awakeable.hs`, `childCompletionHook` in `keiro/src/Keiro/Workflow/Child.hs`, or a fired sleep timer — later appends a `StepRecorded` under the awaited name from *outside* the run, and the next run replays past the await.

A *generation* is a journal epoch: `continueAsNew` rotates a workflow onto a fresh stream (generation g+1) so its journal stays bounded. All appends, index rows, and replay are generation-scoped (`keiro/src/Keiro/Workflow/Schema.hs:132-149` — the index's conflict key is `(workflow_id, workflow_name, generation, step_name)`).

A *snapshot* (`keiro/src/Keiro/Workflow/Snapshot.hs`) stores the folded `step name -> result` map in `keiro_snapshots` at a stream version. `loadJournal` (`keiro/src/Keiro/Workflow.hs:654-696`) seeds from the snapshot when one matches and reads only the journal tail after the snapshot version. The tail read uses kiroku's *exclusive* cursor: `readStreamForwardStream journalName fromVersion` returns only events with `streamVersion > fromVersion` (documented in the kiroku sources, `kiroku-store/src/Kiroku/Store/Read.hs:30-37` and the streaming sibling below it) — correct behavior this plan must respect, not change. Snapshot lookup keys are constants: codec version 1 and shape hash `"keiro.workflow.stepmap.v1"` (`keiro/src/Keiro/Workflow/Snapshot.hs:68-78`), so nothing about a snapshot row ever "expires". The snapshot upsert only requires the new version to be `>=` the stored one (`keiro/src/Keiro/Snapshot/Schema.hs:130-138`), which admits the stale write described below. Snapshots are off by default: `defaultWorkflowRunOptions` sets `snapshotPolicy = Never` (`keiro/src/Keiro/Workflow.hs:337-345`); the defect requires `Every n` (or a mid-run-firing `Custom`; `OnTerminal` is harmless because a completing run has no pending await).

The *resume worker* (`keiro/src/Keiro/Workflow/Resume.hs`) re-invokes unfinished workflows. A run that returns `Suspended` is counted as `stillSuspended` (`Resume.hs:356-357` routes the `AdvOk` outcome to `bumpForOutcome`, which increments `stillSuspended` at 437); only a thrown exception (`AdvCrashed`, 363-379) increments the crash counter toward the `maxAttempts` ceiling. This is why the defect is a *silent* stall: a permanently suspended workflow never escalates.

### The defect (WFC-1), step by step

1. A run starts and loads the journal once into an in-memory `IORef` map (`keiro/src/Keiro/Workflow.hs:481-486`). From then on, the map grows only by the run's *own* appends (`Step` miss inserts at 560-564).
2. While the run is mid-flight, a wake source appends a completion to the same generation — for example `signalAwakeable` or `childCompletionHook`. Appends to one stream are commit-ordered because every kiroku append updates the global `$all` stream row inside the append CTE (the `all_update` clause of `appendAnyVersionSQL`, `kiroku-store/src/Kiroku/Store/SQL.hs:322-372`, updates `stream_id = 0`), so concurrent appends serialize; the per-step advisory lock (`Workflow.hs:720-724` builds the lock key from the *step name*) does not exclude a differently-named wake append. Say the wake commits at version V+1.
3. The run's next fresh step commits at V+2 and the snapshot policy fires. The snapshot is written with the *post-append stream version* (V+2, from `AppendResult.streamVersion` — "the position of the last event in the batch", `kiroku-store/src/Kiroku/Store/Types.hs` around 247-260) but with the *in-memory map* as its state (`Workflow.hs:566-574`), which does not contain the V+1 wake entry. The snapshot now claims to cover V+1 while omitting it.
4. Every later `loadJournal` seeds from that snapshot and tail-reads strictly after V+2 — the V+1 entry is invisible forever.
5. The run (and every resume) reaches the await. The `Await` handler (`Workflow.hs:584-597`) consults only the in-memory map; on a miss it runs the arm and then *unconditionally* throws `WorkflowSuspend` (596-597). The arms cannot repair the map: the awakeable arm's repair (`keiro/src/Keiro/Workflow/Awakeable.hs:244-254`) and the child arm's re-delivery (`keiro/src/Keiro/Workflow/Child.hs:246-255`) call `appendJournalEntry`, whose transaction finds the existing `keiro_workflow_steps` row (`Workflow.hs:733-734`) and returns `JournalAlreadyPresent` *without appending* — and `appendJournalEntry` returns `()`, which the arm discards. The arm never touches the in-memory map. The workflow suspends forever, silently.

The adversarial verification pass confirmed all five refutation avenues are absent: nothing re-reads the stream inside the run, nothing invalidates snapshots, the arm repair cannot append, the snapshot guard admits the stale write, and suspension never escalates. A mainstream trigger with `Every n`: `spawnChild`, then fresh steps, then `awaitChild` racing the child's completion; or an external `signalAwakeable` arriving during earlier steps; timer-fired sleep entries ride the same append path.

Two adjacent facts matter for the fix. First, the point-query statement already exists — `lookupStepResultStmt` (`keiro/src/Keiro/Workflow/Schema.hs:151-165`) with its transaction wrapper `lookupStepResultTx` (81-83), whose only production call site is inside `prepareJournalAppend`; there is no `Eff`-level wrapper yet (the map-level `loadStepIndex` at 98-100 is exported but has no production call site at all). Second, the `loadJournal` haddock (`Workflow.hs:656-663`) currently promises the seeded map is "byte-for-byte the one a full version-0 replay would produce" — false under this defect, and to be corrected in M3.

### Existing test coverage and the gap

The suite (`keiro/test/Main.hs`, run as the `keiro-test` cabal test-suite; 335 examples, 0 failures at authoring time) covers snapshots under `Every 2`/`OnTerminal` in the "Keiro.Workflow snapshots" describe block (starting at line 5991) and covers awakeables/children extensively under default options — but no existing test combines `snapshotPolicy /= Never` with any wake source. That is exactly the interaction this plan tests. The suite provisions its own PostgreSQL: `main = withMigratedSuite ...` (line 353) builds a migrated template database once and `around (withFreshStore fixture)` gives each example a fresh store, so no manual database setup is needed.


## Plan of Work

Three milestones. Each ends with the full suite green.

### Milestone 1 — the step-index fallback on the `Await` miss path

Scope: the code fix plus the guard-rail test proving it does not fire spuriously. At the end of this milestone the engine consults the authoritative index before suspending, and a genuinely unresolved await behaves exactly as before.

First add an `Eff`-level point query to `keiro/src/Keiro/Workflow/Schema.hs`, right next to `loadStepIndex` (after line 100), and add `lookupStepResult` to the module export list under "Read-only lookups":

```haskell
{- | Point-lookup one recorded step result for a workflow instance and
generation, directly from the authoritative @keiro_workflow_steps@ index.
Used by the replay handler's @Await@ miss path as the safety net for a stale
in-memory map (snapshot shadowing, WFC-1): the index is written in the same
transaction as every journal append, so it is complete even when the
snapshot-seeded map is not.
-}
lookupStepResult :: (Store :> es) => WorkflowName -> WorkflowId -> Int -> Text -> Eff es (Maybe Value)
lookupStepResult (WorkflowName name) (WorkflowId wid) gen key =
    runTransaction (Tx.statement (wid, name, fromIntegral gen :: Int32, key) lookupStepResultStmt)
```

Then edit the `Await` case of the handler in `keiro/src/Keiro/Workflow.hs` (currently lines 584-597; add `lookupStepResult` to the import from `Keiro.Workflow.Schema` at line 152). The miss branch changes from "check cancellation, arm, suspend" to "consult the index; on a hit adopt and deliver; on a miss check cancellation, arm, suspend":

```haskell
Await (StepName key) arm -> do
    journal <- liftIO (readIORef journalRef)
    case Map.lookup key journal of
        Just stored -> do
            recordWorkflowStepReplayed mMetrics 1
            decodeStored key stored
        Nothing ->
            -- WFC-1 fallback: the in-memory map (snapshot seed + exclusive
            -- tail read + this run's own inserts) can omit a wake completion
            -- journaled while a snapshotting run was mid-flight. The step
            -- index is written in the same transaction as every append, so
            -- it is authoritative: consult it before arming, and deliver
            -- instead of suspending when the step is already recorded.
            lookupStepResult name wid gen key >>= \case
                Just stored -> do
                    liftIO
                        ( atomicModifyIORef' journalRef $ \m ->
                            (Map.insert key stored m, ())
                        )
                    recordWorkflowStepReplayed mMetrics 1
                    decodeStored key stored
                Nothing -> do
                    checkCancellationPending name wid gen
                    localSeqUnlift env (\unlift -> unlift arm)
                    throwIO WorkflowSuspend
```

Inserting into `journalRef` matters: if the same awaited name is consulted again in this run (or a later step re-reads the map), the value must replay from memory, and the terminal snapshot written on completion must contain it.

Cost note (record in the plan if measured): the query runs only on an await *miss* — a path that is otherwise about to run the arm (itself several statements) and suspend the run — so it adds one indexed point read per parked-await resume pass, never to the step hot path.

Add the guard-rail test to a new describe block `"Keiro.Workflow snapshot wake-safety"` in `keiro/test/Main.hs` (append after the existing workflow test groups, using the same `around (withFreshStore fixture)` pattern; keep the group name distinct — all four sibling plans add groups to this file, additive appends only, per the master plan's Integration Points): under `snapshotPolicy = Every 1`, a workflow that allocates an awakeable and awaits it *without any signal* must return `Suspended` on the first run and again on a second run, and the `keiro_awakeables` row must still be `pending` — proving the fallback finds nothing for a genuinely fresh await and fabricates no result.

Acceptance: `cabal test keiro-test` green, including the new test and the entire pre-existing awakeable/child/sleep groups (the fallback must not perturb them).

### Milestone 2 — crash-window regression tests for the three staleness shapes

Scope: deterministic tests that fail before M1's fix (stall) and pass after it. Write them in the `"Keiro.Workflow snapshot wake-safety"` group. All three use the trick of performing the wake append *inside a step action of the same run*, which reproduces "a wake lands while the owning run is mid-flight" without racing threads.

Test A — mid-run staleness, awakeable variant. Body (all under `defaultWorkflowRunOptions & #snapshotPolicy .~ Every 1`):

```haskell
shadowedAwakeable :: (Workflow :> es, Store :> es, IOE :> es) => Eff es Text
shadowedAwakeable = do
    (aid, await) <- awakeableNamed (StepName "gate")
    _ <- step (StepName "mid") (void (signalAwakeable aid ("payload" :: Text)))
    await
```

Sequence on the first run: the allocation step journals `awkid:gate` (snapshot fires), then the `mid` action runs and `signalAwakeable` appends `awk:<uuid>` from outside the run's map, then `mid`'s own append lands one version later and the `Every 1` snapshot captures a map *missing* the `awk` entry — the exact WFC-1 shape. Before the fix the run's `await` misses, the arm's repair collapses to `JournalAlreadyPresent`, and the run returns `Suspended` — forever, on every re-run. After the fix, assert the *first* run returns `Completed "payload"`, and a second `runWorkflowWith` replays to `Completed "payload"` again.

Test B — snapshot staleness across runs (the resume path). Replay is keyed by step name, so a test may run different bodies against the same journal (an established pattern in this suite). Phase 1 body: allocate `gate`, journal `mid` whose action signals `gate` (as in Test A), then park on an unrelated never-resolving await — `awaitStep (StepName "hold") (pure ())` — so the run suspends *after* writing the stale snapshot. Phase 2 body: allocate `gate`, `mid` (replays), then `await` the awakeable. Run phase 1 (expect `Suspended`), then run phase 2: before the fix, `loadJournal` seeds the stale snapshot, the tail read returns nothing, and the run suspends forever; after the fix it returns `Completed "payload"`. This is the variant that specifically exercises the snapshot-seeded `loadJournal` path rather than same-run map staleness.

Test C — child-completion variant. Phase 1 body: `h <- spawnChild childNm childWid childBody`; a step `"drive"` whose action drives the child to completion inline via `runChildWorkflow defaultWorkflowRunOptions childNm childWid childBody` (this fires `childCompletionHook`, which appends the parent's `child:<id>:result` step from outside the parent's map — `keiro/src/Keiro/Workflow/Child.hs:334-367`); then park on `awaitStep (StepName "hold") (pure ())`. Phase 2 body: spawn, `"drive"` (replays), `awaitChild h`. Under `Every 1`, phase 1 writes a snapshot shadowing the child-result entry; phase 2 before the fix suspends forever, after the fix returns the child's result. (`runChildWorkflow` needs `Error StoreError :> es`, which `Store.runStoreIO` already provides in this suite.)

Acceptance: all three tests pass; to convince yourself they test the defect, temporarily revert the M1 handler edit and observe A/B/C fail by returning `Suspended` where `Completed` is asserted (do not commit the revert). Full suite green.

### Milestone 3 — make the documentation tell the truth

Scope: the `loadJournal` haddock, the user guide, and the changelog.

Replace the false claim in `keiro/src/Keiro/Workflow.hs:656-663`. The current text says the seeded map "is byte-for-byte the one a full version-0 replay would produce, because every 'StepRecorded' at or before the snapshot version is already captured in the seed." Rewrite along these lines: the snapshot seed plus exclusive tail read reconstructs the map *as the snapshotting run saw it*; a wake completion journaled concurrently with the snapshotting run can be at or below the snapshot version yet absent from the seed, so the map can under-approximate the journal. The `Await` handler compensates by falling back to the authoritative `keiro_workflow_steps` index (see the handler) — the index, written transactionally with every append, is the source of truth for step presence.

Update `docs/guides/durable-workflows.md` (the "Snapshots" section, around line 278): one short paragraph stating that snapshots are safe to combine with awakeables, children, and sleeps because the runtime falls back to the step index when a snapshot shadows a concurrently journaled wake completion.

Add a `CHANGELOG.md` entry under Unreleased describing the fix (bug-fix wording: workflows using journal snapshots can no longer be permanently stalled by a wake completion journaled while a run was mid-flight).

Acceptance: `cabal test keiro-test` green; `cabal haddock keiro` renders the edited module without new warnings attributable to the edit. Tick the two EP-1 boxes in the master plan's Progress section and set the registry row status.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`.

Build and test cycle (the suite provisions its own ephemeral PostgreSQL via `withMigratedSuite`; no manual database setup):

```bash
cabal build keiro
cabal test keiro-test
```

`just haskell-test` is an equivalent alias for the test command. At authoring time the baseline is:

```text
335 examples, 0 failures
```

After this plan the example count grows by the four new tests (expect `339 examples, 0 failures`; adjust if you add more).

To run only the new group while iterating:

```bash
cabal test keiro-test --test-options='--match "snapshot wake-safety"'
```

Order of edits: Schema.hs export + function, Workflow.hs import + handler, tests (M1 guard-rail, then M2 A/B/C), then M3 docs. Commit per milestone with conventional-commit messages, e.g. `fix(workflow): fall back to the step index on the Await miss path (WFC-1)`.


## Validation and Acceptance

Acceptance is behavioral:

1. With `snapshotPolicy = Every 1`, running `shadowedAwakeable` (Test A) returns `Completed "payload"` on its first invocation. Before this plan the same run returns `Suspended`, and re-running it returns `Suspended` indefinitely.
2. The two-phase variants (Tests B and C) return `Completed ...` on the phase-2 run that seeds from the stale snapshot. Before this plan they return `Suspended` indefinitely.
3. A genuinely unsignalled awakeable under `Every 1` still returns `Suspended` on every run, with its `keiro_awakeables` row `pending` — the fallback delivers only what the index actually records.
4. The full suite passes: `cabal test keiro-test` prints `0 failures`. Existing groups that exercise the await paths without snapshots ("Keiro.Workflow.Awakeable", "Keiro.Workflow.Child", the sleep tests) are unchanged and green, demonstrating no behavioral drift on the default `Never` policy.

Interpreting failures: a stalled assertion in A/B/C manifests as `expected: Completed ... but got: Suspended` — that is the pre-fix defect signature, meaning the handler edit is missing or the index query is mis-keyed (check the generation argument).


## Idempotence and Recovery

Every step here is additive and repeatable. The handler edit is a pure code change; re-running the suite is always safe (each example gets a fresh database from the template). If M2 tests are written before M1's fix (a legitimate order for demonstrating the defect), they will fail with the stall signature — that is expected; land them together with the fix in one commit, or mark the interim state clearly in Progress. No migration, no data movement, no rollback concerns: reverting the commit restores prior behavior exactly.


## Interfaces and Dependencies

No new packages. Changes are confined to:

- `keiro/src/Keiro/Workflow/Schema.hs` — new export:

```haskell
lookupStepResult :: (Store :> es) => WorkflowName -> WorkflowId -> Int -> Text -> Eff es (Maybe Value)
```

  (wraps the existing `lookupStepResultStmt` via `runTransaction`; `Store` is `Kiroku.Store.Effect.Store`.)

- `keiro/src/Keiro/Workflow.hs` — `Await` handler edit inside `runWorkflowWith`'s `handler`; new import of `lookupStepResult`; `loadJournal` haddock rewrite. No exported signature changes.
- `keiro/test/Main.hs` — new describe group `"Keiro.Workflow snapshot wake-safety"` (four tests), using existing exports only: `runWorkflowWith`, `WorkflowRunOptions` (`snapshotPolicy`), `awakeableNamed`, `signalAwakeable`, `awaitStep`, `step`, `spawnChild`, `awaitChild`, `runChildWorkflow`.
- `docs/guides/durable-workflows.md`, `CHANGELOG.md` — documentation.

Coordination with siblings (from the master plan's Integration Points): `docs/plans/115-record-patch-sets-at-rotation-and-add-workflow-failure-recovery-and-lease-renewal.md` also edits `keiro/src/Keiro/Workflow.hs` but different functions (`rotateGeneration`, `recordPatchSetIfFresh`); merge order is free, no shared types change. All four plans append distinct test groups to `keiro/test/Main.hs`.
