---
id: 113
slug: deliver-child-failure-and-awakeable-signals-across-generations-and-races
title: "Deliver child failure and awakeable signals across generations and races"
kind: exec-plan
created_at: 2026-07-23T03:02:27Z
intention: intention_01ky88vm7tew7akz5pgfq0fbqg
master_plan: "docs/masterplans/16-harden-the-durable-execution-engine-surfaced-by-the-2026-07-durable-execution-review.md"
---

# Deliver child failure and awakeable signals across generations and races

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Parent: `docs/masterplans/16-harden-the-durable-execution-engine-surfaced-by-the-2026-07-durable-execution-review.md` (EP-2 of that master plan). No hard dependencies. Sibling plans: `docs/plans/112-make-workflow-journal-snapshots-wake-safe-with-a-step-index-fallback-on-await.md`, `docs/plans/114-pin-sleep-firing-to-its-generation-and-make-gc-cancel-scheduled-sleep-timers.md`, `docs/plans/115-record-patch-sets-at-rotation-and-add-workflow-failure-recovery-and-lease-renewal.md` (115 soft-depends on this plan).


## Purpose / Big Picture

Keiro's durable workflows can wait on two kinds of external resolution: a *child workflow* (spawned by a parent, driven to completion by the resume worker, its result delivered back into the parent's journal) and an *awakeable* (a durable promise whose id is handed to an external system, which later signals it with a payload). The July 2026 durable-execution review confirmed three defects at the row level of these wake sources, all in `keiro/src/Keiro/Workflow/Child.hs` and `keiro/src/Keiro/Workflow/Awakeable.hs`:

1. WFC-2/WFX-5 (found independently by both review passes): a parent awaiting a child that *failed terminally* suspends forever whenever the one-shot failure delivery missed its generation — the await arm has no `ChildFailed` case. Silent stall, because a suspended run never escalates.
2. WFX-2: an awakeable id escapes the workflow (via the documented hand-off step) *before* its `keiro_awakeables` row exists, so a signal arriving in the gap is indistinguishable from an unknown id: `signalAwakeable` returns `False`, and a non-retrying signaler loses the completion forever.
3. WFX-7: `signalAwakeable` decides what to append from a row snapshot read *outside* its transaction, so a cancel that wins the race inside the transaction still gets the result appended — the canceller was told `True` (and may run compensation) *and* the workflow resumes with the value.

After this plan: a parent awaiting a failed child is woken with a typed `WorkflowChildFailed` (carrying the persisted failure reason) on *any* generation; an awakeable id can be signalled the moment it escapes the workflow; and a signal racing a cancel can no longer produce both compensation and completion. This plan carries the initiative's one schema migration (a failure-reason column on `keiro_workflow_children`).

To see it working: run `cabal test keiro-test` from the repository root and observe the new tests — most notably one in which a parent that rotated past its spawn generation catches `WorkflowChildFailed` with the child's recorded reason, where before this plan it suspends forever.


## Progress

This is the plan-authoring-time checklist of the work. Update it at every stopping point.

- [x] (2026-07-23T20:21:49Z) M1: migration `keiro-migrations/migrations/0020-keiro-workflow-children-failure-reason.sql` created and appended to `keiro-migrations/migrations/manifest`; authoring-time slot 0019 was already occupied.
- [x] (2026-07-23T20:29:48Z) M1: `keiro-migrations/test/Main.hs` count/list expectations reconciled; `cabal test keiro-migrations-test` green (10 examples).
- [x] (2026-07-23T20:21:49Z) M1: `ChildRow` gains `failureReason`; `markChildFailedTx` takes and stores the reason; `Resume.hs` passes it.
- [x] (2026-07-23T20:21:49Z) M1: `awaitChild` arm throws `WorkflowChildFailed` on a `ChildFailed` row (with reason fallback chain).
- [x] (2026-07-23T20:34:26Z) M1: cross-generation failed-child test passes; full suite green (`cabal test keiro-test`).
- [x] (2026-07-23T20:29:48Z) M2: `awakeableNamed` registers the pending row inside the allocation step's action, before the id can escape.
- [x] (2026-07-23T20:34:26Z) M2: signal-in-gap test passes (signal after hand-off, before first await, returns `True` and later completes the workflow); full suite green.
- [x] (2026-07-23T20:29:48Z) M3: `signalAwakeable` decides append-vs-refuse from in-transaction state; `lookupAwakeableStatusTx` added to the schema module.
- [x] (2026-07-23T20:34:26Z) M3: cancelled-then-signalled race test passes (no journal entry, workflow throws `WorkflowAwakeableCancelled`); full suite green.
- [x] (2026-07-23T20:34:26Z) Master plan 16 Progress boxes for EP-2 ticked and registry status updated; `CHANGELOG.md` entry written.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery: The authoring-time migration claim `0019` was stale when implementation began: `keiro-migrations/migrations/manifest` already ended with `0019-keiro-snapshots-state-shape-hash.sql`.
  Evidence: the manifest and `keiro-migrations/test/Main.hs` both pinned 19 Keiro migrations before this plan's changes.
  Impact: this plan uses `0020-keiro-workflow-children-failure-reason.sql`; exact migration assertions are 20 Keiro migrations and 28 composed migrations (8 Kiroku + 20 Keiro).


## Decision Log

Record every decision made while working on the plan.

- Decision: Persist the child failure reason in a new `failure_reason` column on `keiro.keiro_workflow_children` (migration), rather than recovering it from `keiro_workflows.last_error` at throw time.
  Rationale: The verification pass established that `ChildRow` stores no failure reason today (`markChildFailedTx` takes only id+name, `keiro/src/Keiro/Workflow/Child/Schema.hs:126-128`; `result` stays NULL for failed children). The column is durable — it survives instance-row GC and later `last_error` overwrites — and it rides the exact row the await arm already reads. `last_error` is kept only as a *fallback* for rows failed before this change (see M1).
  Date: 2026-07-23

- Decision: Claim migration number `0020`, replacing the plan's authoring-time `0019` placeholder.
  Rationale: EP-1 already landed `0019-keiro-snapshots-state-shape-hash.sql`. The native manifest is ordered and file names identify migration ids, so reusing 0019 would be ambiguous and would violate the landing-order rule recorded by this plan.
  Date: 2026-07-23

- Decision: The arm throws `WorkflowChildFailed` directly on a `ChildFailed` row; it does not append a `{"failed": reason}` sentinel onto the current generation, and `childCompletionHook`'s `ChildFailed -> pure ()` case stays.
  Rationale: This mirrors the existing `ChildCancelled` arm case (`keiro/src/Keiro/Workflow/Child.hs:243-245`), which also throws without appending. The arm runs on every resume of every generation (arms re-run until the awaited step journals), so row-based detection is inherently generation-proof; an arm-side append would duplicate the ceiling path's one-shot sentinel without adding safety. `childCompletionHook` is a *completion* propagator invoked only after a `Completed` outcome (`Child.hs:318-322`); a failed child never reaches it through `runChildWorkflow`, so its `ChildFailed` case is dead-in-practice defensive code and changing it buys nothing.
  Date: 2026-07-23

- Decision: WFX-2 is fixed by registering the pending row inside the allocation step's *action* (its own committed transaction, immediately before the step's journal append), not literally inside the append transaction.
  Rationale: The finding's requirement is the invariant "the row durably exists before the id can escape the workflow". The id escapes only via the journaled allocation step (replay hands it back from the journal), and the step's append commits strictly after its action returns — so action-time registration establishes the invariant. A literal same-transaction merge would require widening the `Workflow` effect's `Step` operation (the append transaction is assembled generically in `prepareJournalAppend`, `keiro/src/Keiro/Workflow.hs:708-746`, with no seam for caller transactions) for no additional safety. The residual crash window (registered row, append never committed) leaves an *unreachable* orphan `pending` row — the id was never journaled nor returned — which GC already deletes by owner coordinates (`keiro/src/Keiro/Workflow/Gc.hs:136-147`).
  Date: 2026-07-23

- Decision: WFX-7 needs no `SELECT ... FOR UPDATE`; the in-transaction re-read after the guarded UPDATE is sufficient.
  Rationale: `completeAwakeableTx`'s UPDATE (`... WHERE status = 'pending'`, `keiro/src/Keiro/Workflow/Awakeable/Schema.hs:136-153`) serializes against a concurrent cancel on the row lock: if the cancel committed first, our UPDATE re-evaluates its predicate and matches zero rows, and a plain same-transaction SELECT then observes the committed `cancelled` status; if our UPDATE succeeded, a concurrent cancel blocks and then matches zero rows. Either interleaving yields a consistent in-transaction view, so an explicit lock adds nothing.
  Date: 2026-07-23

- Decision: Expose the transaction-decision core of `signalAwakeable` as an exported function taking the pre-read row (working name `signalAwakeableFrom`), documented as existing for the race contract and its tests.
  Rationale: The cancelled-then-signalled race lives between `signalAwakeable`'s initial `lookupAwakeable` and its transaction; a deterministic test must be able to interpose there (pre-read the row, cancel, then run the remainder). Without the seam the only test is a timing race, which this suite avoids.
  Date: 2026-07-23


## Outcomes & Retrospective

All three confirmed findings are closed.

The child failure test proves the generation boundary explicitly: its failure
sentinel exists only on generation 0, generation 1 has no matching step-index
entry, and the parent still catches the persisted `WorkflowChildFailed` reason.
The allocation-gap test signals after a journaled hand-off but before the first
real await. The deterministic stale-row race test cancels after the signal's
pre-read and verifies both that no result was indexed and that the workflow
surfaces `WorkflowAwakeableCancelled`.

Validation completed with `keiro-migrations-test` at 10 examples and
`keiro-test` at 360 examples, both with zero failures. The existing double
signal, completed-row repair, await-arm repair, legacy-id adoption,
per-generation allocation, child completion, child cancellation, and attach
tests all remained green.

The only implementation-time plan correction was migration numbering: 0019
was already occupied, so this plan owns 0020 and later sibling migrations begin
at 0021. ADR 6 captures the durable rule distilled from the work: wake-source
rows govern exposure and terminal lifecycle, while generation-scoped journal
entries deliver results to a particular run.


## Context and Orientation

This section is self-contained.

ADR context: `docs/adr/` contains only `0001-keiro-pgmq-job-processing-telemetry-contract.md` (pgmq job-processing telemetry) — no relevant ADR exists for this work.

### The moving parts

A *durable workflow* (`keiro/src/Keiro/Workflow.hs`) journals each named step's JSON result to a kiroku event stream (kiroku is the append-only Postgres event store this repo builds on) and replays recorded results on re-runs. `awaitStep name arm` suspends the run until an external *wake source* appends a `StepRecorded` under `name`; the `arm` action is idempotent and re-runs on every resume until then. A *generation* is a journal epoch — `continueAsNew` rotates onto a fresh stream — and journal entries plus their `keiro_workflow_steps` index rows are generation-scoped (the index conflict key is `(workflow_id, workflow_name, generation, step_name)`, `keiro/src/Keiro/Workflow/Schema.hs:132-149`; point lookups filter on `generation = $3`, lines 151-165). The *resume worker* (`keiro/src/Keiro/Workflow/Resume.hs`) discovers and re-invokes unfinished workflows; a run returning `Suspended` never increments the crash counter (`Resume.hs:356-357` and `bumpForOutcome` at 434-448), so a wedged await is a *silent* stall.

*Child workflows* (`keiro/src/Keiro/Workflow/Child.hs`): `spawnChild` journals a spawn step in the parent and inserts a `running` link row in `keiro.keiro_workflow_children`; `awaitChild` is `awaitStep` on the reserved name `child:<childId>:result`. Delivery into the parent journal is a tagged envelope: `{"ok": result}` on completion, `{"cancelled": true}` on cancel, `{"failed": reason}` on terminal failure; the hit path decodes all three (`decodeChildResult`, `Child.hs:441-462`). The link row's shape is `ChildRow` (`keiro/src/Keiro/Workflow/Child/Schema.hs:82-94`): child/parent identities, the awaited step name, `status` (`Running | ChildCompleted | ChildCancelled | ChildFailed`), `result` (set only on completion), timestamps — and, today, *no failure reason*.

*Awakeables* (`keiro/src/Keiro/Workflow/Awakeable.hs`): `awakeableNamed label` allocates a random `AwakeableId`, journaling it under `awkid:<label>` (so replay re-hands the same id), and returns an `await` that suspends on `awk:<uuid>`. The row lives in `keiro.keiro_awakeables` with status `pending | completed | cancelled` (`keiro/src/Keiro/Workflow/Awakeable/Schema.hs`). `signalAwakeable` (external) flips the row and appends the journal entry in one transaction; `cancelAwakeable` flips a pending row to cancelled with no journal write.

The migration package: `keiro-migrations/migrations/` holds numbered SQL files (`0001-...` through `0018.sql` at authoring time) listed in `keiro-migrations/migrations/manifest`; the Haskell definition embeds the manifest at compile time via Template Haskell (`embedMigrationManifest "migrations/manifest"`, `keiro-migrations/src/Keiro/Migrations/Internal/Definition.hs:18-21`). The package's test suite (`keiro-migrations/test/Main.hs`, cabal target `keiro-migrations-test`) pins the file list and counts.

### Finding 1 — WFC-2/WFX-5: `ChildFailed` never reaches a parent across generations

When a child crashes repeatedly, the resume worker's ceiling path fails it terminally and delivers failure to the parent **exactly once**: `appendFailedChildAndWakeParent` (`keiro/src/Keiro/Workflow/Resume.hs:386-419`) appends the child's `WorkflowFailed` marker, flips the child row to `failed`, and appends `{"failed": reason}` under the parent's await step — at the parent generation read *at that instant* (line 398, `parentGen <- currentGeneration parentNm parentWid`). After that moment the child is terminally outside every delivery path: `runChildWorkflow` short-circuits `Just ChildFailed -> pure Failed` with no parent append (`Child.hs:316`), `childCompletionHook` has `ChildFailed -> pure ()` (`Child.hs:379`), and a failed child leaves resume discovery.

Because journal and index are generation-scoped, a parent generation created *after* (or racing) that single delivery never sees the sentinel. It reaches `awaitChild`'s miss path and runs the arm (`Child.hs:240-257`) — which handles `ChildCancelled` (throw, 243-245) and `ChildCompleted` with a stored result (re-deliver onto the current generation, 246-255), but lets `ChildFailed` fall through to `_ -> pure ()` (257). The run suspends; nothing ever escalates. Reachable via the documented attach-after-`continueAsNew` pattern (`Child.hs:186-189` — "Spawning an id whose child row already completed attaches to that execution"; the same attach applies to a failed row, which today attaches to *nothing*), via the rotation race at `Resume.hs:398`, or via the snapshot shadowing fixed in `docs/plans/112-make-workflow-journal-snapshots-wake-safe-with-a-step-index-fallback-on-await.md` (whose fix masks only the *same-generation* variant — the cross-generation gap is this plan's to close).

The schema fact that shapes the fix: `markChildFailedTx` takes only id+name (`Child/Schema.hs:126-128`; statement at 216-231 sets only `status`/`updated_at`), so the reason exists nowhere on the row. The chosen fix (Decision Log) adds a `failure_reason` column.

### Finding 2 — WFX-2: the registration gap for awakeable ids

`awakeableNamed` journals the id under `awkid:<label>` (`Awakeable.hs:179-192`; allocation at 194-208) but does **not** create the `keiro_awakeables` row. Registration happens only inside `awaitCancellable`'s arm on the suspend path (`Awakeable.hs:234-257`; the `registerAwakeableTx` call at 255-257 is the sole production call site — grep-verified). The module's own documented flow hands the id to an external system in a step *before* the await (module header example, `Awakeable.hs:10-17`). A signal in that gap runs `lookupAwakeable -> Nothing -> pure False` (`Awakeable.hs:283-285`) — the same answer a forged/unknown id gets — so a non-retrying signaler loses the completion, and the workflow later suspends forever on an awakeable nobody will signal again. The window is unbounded if the process crashes after the hand-off step commits and before any resume reaches the await.

### Finding 3 — WFX-7: cancelled-then-signalled appends anyway

`signalAwakeable` (`Awakeable.hs:281-320`) reads the row *outside* the transaction and computes the append payload from that stale snapshot (`payload = if row^.#status == Completed then row^.#payload else Just (toJSON result)`, lines 290-293). Inside the transaction, `completeAwakeableTx` is correctly guarded (`WHERE status = 'pending'`; returns `False` if a cancel won the race) — but the journal append transaction runs **unconditionally** (line 316). Net effect when a cancel commits between the read and the transaction: `cancelAwakeable` returned `True` (its caller may run compensation) *and* the result is journaled, so the workflow resumes with the value — both branches of the race "win". Contrast `childCompletionHook`, which appends only when its row transition succeeds (`Child.hs:358-366`).

### Verified-sound behavior the fixes must not regress

The review verified these properties and this suite pins them; keep every one green (`keiro/test/Main.hs` line numbers at authoring time): signal atomicity — row flip + journal append in one transaction with `Tx.condemn` on append conflict (`Awakeable.hs:310-318`); double-signal first-payload-wins (test at 7720); the two repair paths — re-append on re-signal (7756) and repair from the await arm (7786); forged coordinate-derived id refusal (7808); gen-0 legacy id adoption (7825); per-generation fresh allocation after rotation (7841); child completion/cancel transactional propagation and attach re-delivery (7969, 8210); spawn idempotence (8001); same-generation failure-ceiling atomicity — parent woken with `WorkflowChildFailed` when child hits the ceiling on the *same* generation (8147).

### Migration numbering (Integration Point from the master plan)

`keiro-migrations/migrations/` numbering: **0019 was already occupied at implementation time** by `0019-keiro-snapshots-state-shape-hash.sql`, so this plan claims the next free number, **0020**. A later sibling migration must begin at 0021.

The test suites: `keiro-test` self-provisions PostgreSQL via `withMigratedSuite`; the implementation baseline after EP-1 was 357 examples and this plan adds three, for an expected 360. `keiro-migrations-test` runs the migration-parity and fresh-database checks.


## Plan of Work

Three milestones, one per finding. Each ends with the full suite green.

### Milestone 1 — deliver child failure on any generation, with a durable reason

Scope: the migration, the schema plumbing, the arm case, and the cross-generation test.

Migration. Create `keiro-migrations/migrations/0020-keiro-workflow-children-failure-reason.sql`:

```sql
-- keiro workflow children: persist the terminal failure reason
--
-- The resume worker's failure ceiling flips a child link row to 'failed'
-- (Keiro.Workflow.Child.Schema.markChildFailedTx) but until now recorded the
-- reason nowhere on the row; the parent's awaitChild arm needs it to throw a
-- typed WorkflowChildFailed on any parent generation. NULL for rows failed
-- before this migration and for non-failed rows.

ALTER TABLE keiro.keiro_workflow_children
  ADD COLUMN IF NOT EXISTS failure_reason TEXT NULL;
```

Append the filename as the last line of `keiro-migrations/migrations/manifest`. Then reconcile `keiro-migrations/test/Main.hs`, which pins the file set: `nativeMigrationFiles` gains 0020, Keiro counts become 20, and composed counts become 28 (= 8 Kiroku + 20 Keiro). The Codd-import fixture's pending canaries gain `keiro "0020-keiro-workflow-children-failure-reason"`, its final apply segment gains one `AppliedNow`, and the facts tuple becomes `(28, 23, True)`. The legacy `migrations.lock` parity test zips legacy names against native files and truncates at the shorter list, so a new native file needs no lock entry. Run `cabal test keiro-migrations-test` and let each failing assertion guide the remaining count. Build gotcha (documented in `keiro/src/Keiro/Workflow.hs:63-69`): the Template Haskell embed may not notice the new file — if cabal reports "Up to date", touch `keiro-migrations/src/Keiro/Migrations/Internal/Definition.hs` or run `cabal clean`.

Schema plumbing in `keiro/src/Keiro/Workflow/Child/Schema.hs`: add `failureReason :: !(Maybe Text)` to `ChildRow` (place it after `result`); extend `childRowDecoder` and add `failure_reason` to the SELECT lists of `lookupChildStmt` and `lookupChildrenOfParentStmt`; change the signature to

```haskell
markChildFailedTx :: Text -> Text -> Text -> Tx.Transaction Bool
```

with the statement gaining `failure_reason = $3` in its SET clause (guard `status = 'running'` unchanged). Update the one caller: `appendFailedChildAndWakeParent` in `keiro/src/Keiro/Workflow/Resume.hs` (line 413) passes `reason`.

The arm case in `keiro/src/Keiro/Workflow/Child.hs`: in `awaitChild`'s arm (the `case` at 242-257), insert a `ChildFailed` guard between the `ChildCompleted` branch and the catch-all:

```haskell
| (row ^. #status) == ChildFailed -> do
    reason <- case row ^. #failureReason of
        Just r -> pure r
        Nothing -> do
            -- Row failed before the failure_reason column existed: fall
            -- back to the child's instance-row last_error, then to a
            -- generic message (the instance row may have been GC'd).
            mInstance <- lookupInstance childNm childWid
            pure
                ( fromMaybe
                    "child workflow failed (reason not recorded)"
                    (mInstance >>= (^. #lastError))
                )
    throwIO (WorkflowChildFailed childNm childWid reason)
```

(`lookupInstance` comes from `Keiro.Workflow.Instance`, already imported by this module for `upsertInstanceTx`; extend the import list.) Update the module-header contract recap (`Child.hs:33-42`) to say the miss path also throws `WorkflowChildFailed` for a failed child.

Cross-generation test (new describe group `"Keiro.Workflow child failure delivery"` in `keiro/test/Main.hs`; distinct group name — all four sibling plans append groups, additive only). Reproduce the exact gap deterministically with the suite's established body-swap pattern (replay is keyed by step name, so different bodies may drive the same journal across runs):

1. Phase 1 body: `h <- spawnChild childNm childWid childBody; awaitStep (StepName "hold") (pure ())`. Run it: `Suspended` on generation 0, spawn journaled, link row `running`.
2. Fail the child at the ceiling: register a child definition that throws, and drive `resumeWorkflowsOnce` with `maxAttempts = 1` until the child is failed (the same mechanism as the existing test at 8147). The one-shot `{"failed": reason}` sentinel lands on parent generation 0.
3. Phase 2 body: `spawnChild ...; continueAsNew ()`. Run it: the parent rotates to generation 1 — whose journal has no sentinel.
4. Phase 3 body: `spawnChild ...; (awaitChild h >>= ...) \`catch\` (\(WorkflowChildFailed _ _ reason) -> step (StepName "compensate") (pure reason))`. Run it: before the fix this returns `Suspended` forever (the arm's catch-all); after the fix it returns `Completed reason` with `reason` equal to the recorded failure reason. Also assert `lookupChild` now returns the reason in `failureReason`.

Note this is orthogonal to plan 112's index fallback: the sentinel's index row is on generation 0, and the fallback queries the current generation only.

Acceptance: the new test passes; the existing same-generation ceiling test (8147) and attach test (8210) stay green; `cabal test keiro-migrations-test` and `cabal test keiro-test` both green.

### Milestone 2 — register the awakeable row before the id can escape

Scope: move registration into the allocation step's action; prove the gap is closed.

Edit `awakeableNamed` in `keiro/src/Keiro/Workflow/Awakeable.hs` (lines 183-192): the allocation step's action allocates *and registers* before returning, so the row commit strictly precedes the journal append that lets the id escape:

```haskell
aid <-
    step (StepName (awakeableAllocStepPrefix <> label)) $ do
        aid <- allocateAwakeableId name wid gen label
        runTransaction $
            registerAwakeableTx (awakeableIdToUuid aid) (unWorkflowName name) (unWorkflowId wid)
        pure aid
```

Keep the arm's idempotent re-register (`Awakeable.hs:255-257`) untouched — it remains the repair path for pre-change in-flight workflows whose allocation step is already journaled without a row, and `registerAwakeableTx` is `ON CONFLICT (awakeable_id) DO NOTHING` (`Awakeable/Schema.hs:120-134`) so the double registration is a no-op. Generation-0 legacy adoption is unaffected: `allocateAwakeableId` returns the legacy deterministic id when its row already exists (`Awakeable.hs:201-208`), and re-registering an existing row is a no-op (test 7825 must stay green). Update the module header's flow description (`Awakeable.hs:19-23`) — the pending row now appears when the id is allocated, not first at suspension.

Signal-in-gap test (group `"Keiro.Workflow awakeable registration"`), again with the body-swap pattern to stop *before* the await:

1. Phase 1 body: `(aid, _await) <- awakeableNamed (StepName "gate"); step "publish" (write aid to an IORef); awaitStep (StepName "hold") (pure ())`. Run: `Suspended`. The id has escaped (journaled and handed off) but no resume has reached the real await — the exact gap.
2. From outside: `signalAwakeable aid "ok"` must return `True` (before the fix: `False`, and the row does not exist). Assert also that the row is now `completed`.
3. Phase 2 body: allocation, `publish`, then the real `await`. Run: `Completed "ok"`.

Also assert the negative control stays: signalling a random unknown id still returns `False` (forged-id refusal, test 7808 pattern).

Acceptance: new tests pass; awakeable groups 7668-7867 all green; full suite green.

### Milestone 3 — decide the signal inside the transaction

Scope: close the cancelled-then-signalled race; keep every idempotence/repair property.

Add to `keiro/src/Keiro/Workflow/Awakeable/Schema.hs` an in-transaction status read and export it:

```haskell
lookupAwakeableStatusTx :: UUID -> Tx.Transaction (Maybe AwakeableStatus)
```

(a one-column `SELECT status FROM keiro.keiro_awakeables WHERE awakeable_id = $1` decoded through `statusFromText`).

Restructure `signalAwakeable` in `keiro/src/Keiro/Workflow/Awakeable.hs` (lines 281-320) into a thin wrapper plus an exported core that takes the pre-read row (see Decision Log on why the seam exists):

```haskell
signalAwakeable :: (IOE :> es, Store :> es, ToJSON r) => AwakeableId -> r -> Eff es Bool
signalAwakeable aid result =
    lookupAwakeable (awakeableIdToUuid aid) >>= \case
        Nothing -> pure False
        Just row -> signalAwakeableFrom row result
```

`signalAwakeableFrom` keeps the current pre-computation (fast-path `Cancelled -> pure False`; payload from the stored value when the pre-read says `Completed`, from `result` otherwise; `prepareJournalAppend` at the owner's current generation) but changes the transaction body to decide the append from in-transaction state:

```haskell
(transitioned, appendOutcome) <-
    runTransaction $ do
        transitioned <-
            if row ^. #status == Pending
                then completeAwakeableTx (awakeableIdToUuid aid) (toJSON result) now
                else pure False
        if transitioned || row ^. #status == Completed
            then do
                -- This call resolved the promise, or it is repairing an
                -- already-completed row from its STORED payload.
                appendOutcome <- appendTx
                condemnOnAppendConflict appendOutcome
                pure (transitioned, Just appendOutcome)
            else
                -- Pre-read said Pending but the flip did not happen: the row
                -- changed under us. Re-read INSIDE the transaction and append
                -- only if a racing signal completed it (its atomic append
                -- already wrote the index row, so ours collapses to
                -- JournalAlreadyPresent); a racing cancel gets NO append.
                lookupAwakeableStatusTx (awakeableIdToUuid aid) >>= \case
                    Just Completed -> do
                        appendOutcome <- appendTx
                        condemnOnAppendConflict appendOutcome
                        pure (False, Just appendOutcome)
                    _ -> pure (False, Nothing)
for_ appendOutcome throwOnAppendConflict
pure transitioned
```

Why the racing-signal append is payload-safe even though our prepared event carries *our* result: a competing signal that completed the row did so atomically with its own journal append (that is the verified atomic path), so its index row exists and our append's in-transaction index check returns `JournalAlreadyPresent` — the stored payload wins, byte-for-byte, preserving first-payload-wins (test 7720). The only genuinely fresh append with a `Completed` pre-read is the historical-wedge repair, whose payload was already taken from the stored row (unchanged behavior, tests 7756/7786). Update `signalAwakeable`'s haddock (`Awakeable.hs:263-280`) to state the new guarantee: a signal that loses to a cancel appends nothing and returns `False`.

Race test (group `"Keiro.Workflow awakeable signal race"`): suspend a workflow on `awakeableNamed "gate"` (row `pending`); `row <- lookupAwakeable ...` (the stale pre-read); `cancelAwakeable aid` returns `True`; `signalAwakeableFrom row "late"` must return `False`; assert the journal has **no** `awk:<uuid>` entry (`stepExists` on the step name is `False`); re-run the workflow and assert it surfaces `WorkflowAwakeableCancelled` (the pattern of the existing cancel test at 7738) — before the fix, the same sequence journals `"late"` and the re-run *completes with the value* while the canceller was told `True`.

Acceptance: race test passes; 7720/7738/7756/7786/7808 green; full suite green. Write the `CHANGELOG.md` entry covering all three fixes and the migration, tick EP-2's three boxes in master plan 16, and update its registry row.


## Concrete Steps

All commands from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`.

```bash
cabal build keiro keiro-migrations
cabal test keiro-migrations-test
cabal test keiro-test
```

(`just haskell-test` aliases `cabal test keiro-test`.) Implementation baseline after EP-1:

```text
357 examples, 0 failures
```

Iterate on a single group with, e.g.:

```bash
cabal test keiro-test --test-options='--match "child failure delivery"'
```

If cabal says "Up to date" after adding the migration file, run `cabal clean` or touch `keiro-migrations/src/Keiro/Migrations/Internal/Definition.hs` (Template Haskell manifest embed; see the gotcha note in `keiro/src/Keiro/Workflow.hs:63-69`).

Suggested commits (conventional commits; the migration is a schema addition, mark it clearly):

```text
feat(workflow)!: persist child failure reasons and deliver ChildFailed on any generation
fix(workflow): register awakeable rows at id allocation, closing the signal gap
fix(workflow): decide signalAwakeable's append from in-transaction row state
```


## Validation and Acceptance

Acceptance is behavioral:

1. Cross-generation child failure: a parent that spawned on generation 0, rotated, and awaits on generation 1 a child that failed at the ceiling catches `WorkflowChildFailed` whose reason equals the recorded failure reason, and completes its compensation step. Before this plan the same sequence returns `Suspended` on every run, forever.
2. Signal in the gap: after the hand-off step commits and before any await, `signalAwakeable` returns `True` and the workflow later completes with the signalled payload. Before this plan it returns `False` and the workflow suspends forever.
3. Cancel/signal race: with a `pending` pre-read followed by a committed cancel, the signal returns `False`, journals nothing, and the workflow surfaces `WorkflowAwakeableCancelled`. Before this plan the signal journals the value and the workflow resumes with it despite the canceller having been told `True`.
4. `cabal test keiro-migrations-test` passes with the reconciled counts (20 Keiro migrations, 28 composed).
5. `cabal test keiro-test` prints `0 failures`, including every pinned property listed in Context ("Verified-sound behavior…").

Failure signatures: `Suspended` where `Completed`/exception is expected means the arm case or registration move is missing; a migrations-test count mismatch names the exact assertion to reconcile; a `keiro-test` failure in 7720/7756/7786 means the M3 transaction restructure broke a repair path — re-check the `Completed`-pre-read branch.


## Idempotence and Recovery

The migration is additive (`ADD COLUMN IF NOT EXISTS ... NULL`) — re-running it is a no-op, no backfill, no rewrite; rows failed before it simply carry NULL, which the arm's fallback chain handles. Rolling back the code without rolling back the column is safe (the column is ignored). All code edits are pure and revertible per-commit. Tests are repeatable: each example runs against a fresh database cloned from the migrated template. If the milestone order is interrupted, each milestone is independently complete — M2 and M3 touch only `Awakeable*.hs` and neither depends on M1's migration.


## Interfaces and Dependencies

No new packages. End-state interfaces per milestone:

- M1 — `keiro-migrations/migrations/0020-keiro-workflow-children-failure-reason.sql`; `keiro/src/Keiro/Workflow/Child/Schema.hs`: `ChildRow` gains `failureReason :: !(Maybe Text)`; `markChildFailedTx :: Text -> Text -> Text -> Tx.Transaction Bool`; `keiro/src/Keiro/Workflow/Child.hs`: arm throws `WorkflowChildFailed` (existing type, `Child.hs:170-173`) on failed rows; `keiro/src/Keiro/Workflow/Resume.hs`: `markChildFailedTx` call carries the reason.
- M2 — `keiro/src/Keiro/Workflow/Awakeable.hs`: `awakeableNamed`'s allocation step registers the row; no signature changes.
- M3 — `keiro/src/Keiro/Workflow/Awakeable/Schema.hs`: new export `lookupAwakeableStatusTx :: UUID -> Tx.Transaction (Maybe AwakeableStatus)`; `keiro/src/Keiro/Workflow/Awakeable.hs`: new export `signalAwakeableFrom :: (IOE :> es, Store :> es, ToJSON r) => AwakeableRow -> r -> Eff es Bool` (documented as the race-contract seam), `signalAwakeable` unchanged in signature.

Cross-plan coordination (master plan Integration Points): this plan owns migration 0020; a later sibling migration begins at 0021. `docs/plans/115-...` soft-depends on this plan's `ChildFailed` semantics for its resurrection API; land this plan first when convenient, or 115 proceeds against pre-fix arm behavior and records the assumption. All four sibling plans append distinct test groups to `keiro/test/Main.hs`.


Revision note (2026-07-23): implementation inherited intention `intention_01ky88vm7tew7akz5pgfq0fbqg`, corrected the occupied migration slot from 0019 to 0020 and the exact migration totals to 20/28, completed all three milestones with 360 workflow examples green, and added ADR 0006 for the durable wake-source row contract.
