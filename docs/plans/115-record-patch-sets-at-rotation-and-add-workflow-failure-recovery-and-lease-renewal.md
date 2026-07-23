---
id: 115
slug: record-patch-sets-at-rotation-and-add-workflow-failure-recovery-and-lease-renewal
title: "Record patch sets at rotation and add workflow failure recovery and lease renewal"
kind: exec-plan
created_at: 2026-07-23T03:02:27Z
intention: intention_01ky88vm7tew7akz5pgfq0fbqg
master_plan: "docs/masterplans/16-harden-the-durable-execution-engine-surfaced-by-the-2026-07-durable-execution-review.md"
---

# Record patch sets at rotation and add workflow failure recovery and lease renewal

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Parent: `docs/masterplans/16-harden-the-durable-execution-engine-surfaced-by-the-2026-07-durable-execution-review.md` (EP-4 of that master plan). Soft dependency on `docs/plans/113-deliver-child-failure-and-awakeable-signals-across-generations-and-races.md` (EP-2) — see the Decision Log entry on resurrection and child failure. Other siblings: `docs/plans/112-make-workflow-journal-snapshots-wake-safe-with-a-step-index-fallback-on-await.md`, `docs/plans/114-pin-sleep-firing-to-its-generation-and-make-gc-cancel-scheduled-sleep-timers.md` (complementary to this plan's patch fix — see Context).


## Purpose / Big Picture

This plan owns the *lifecycle policy* findings of the July 2026 durable-execution review — the places where the workflow engine's policies (patch recording, terminal failure, instance leasing) silently do the wrong thing for long-lived production workflows:

1. WFX-4: the `patch` API's decision set is recorded only when a generation's loaded journal looks "fresh" (seed-only). Any asynchronous append landing on a freshly rotated generation before its first run — a duplicate awakeable signal taking the repair path, a child completion racing the rotation — defeats that check, and then **every** `patch` call in that instance decides `False` for the rest of its lifetime, silently diverging from every other instance. This is the continue-as-new × patch interaction the master plan flags as MP-6-adjacent.
2. WFC-3: any non-store synchronous exception consumes a retry attempt, the backoff tops out fast, and the default ceiling of 5 terminally fails an in-flight workflow after a transient outage of a minute or two. That is a defensible policy **only** with a recovery path — and none exists: no resurrect API anywhere in `keiro/src` (grep-verified; the exported `resetInstanceAttempts` explicitly refuses terminal instances). Recovery today is undocumented manual SQL.
3. WFC-4: the instance lease is claimed once per advance and never renewed, so a *healthy* worker whose advance exceeds `leaseTtl` (default 60 s — one slow LLM call or batch job) loses exclusivity mid-flight, and a second replica re-executes every un-journaled step's side effects concurrently. The journal converges (verified), but duplicate side effects are *systematic* for slow workflows, and `leaseTtl`'s documentation frames the lease purely as dead-worker recovery, so operators will not think to size it.

After this plan: a rotated generation records its patch set atomically at rotation, so `patch` decides correctly no matter what lands before the first run; operators get `resurrectFailedWorkflow` — a supported, transactional way to return a terminally failed workflow to the running pool — plus documentation for sizing `maxAttempts`/backoff; and a running advance heartbeats its lease at every step boundary, stopping cleanly (without a spurious crash record) if the lease is lost.

To see it working: run `cabal test keiro-test` from the repository root and observe the new tests — a rotation followed by a pre-first-run wake append where `patch` still decides `True`; a failed workflow resurrected and driven to completion; and a slow step during which a second worker cannot steal the lease.


## Progress

This is the plan-authoring-time checklist of the work. Update it at every stopping point.

- [x] (2026-07-23 21:04Z) M1: `rotateGeneration` appends the seed and the patch-set record in one transaction; `runWorkflowWith` passes `activePatches` through.
- [x] (2026-07-23 21:04Z) M1: generation-0 path (`recordPatchSetIfFresh`) retained and its interplay documented.
- [x] (2026-07-23 21:04Z) M1: rotation + pre-first-run wake-append test passes (`patch` decides `True`); full suite green (`cabal test keiro-test`: 367 examples, 0 failures).
- [ ] M2: `resurrectFailedWorkflow` implemented (index-row delete + instance revive + child-link revive, one transaction) with a `ResurrectOutcome` result.
- [ ] M2: the `WorkflowFailed` marker append switched to a store-generated event id (re-failure after resurrection hazard — see Decision Log).
- [ ] M2: resurrect-then-complete and resurrect-then-refail tests pass; full suite green.
- [ ] M2: `docs/guides/durable-workflows.md` gains the failure/retry/resurrection section (backoff math, `maxAttempts` sizing, API usage).
- [ ] M3: `LeaseHeartbeat` option + `renewInstanceLeaseTx` + step-boundary renewal + `WorkflowLeaseLost` implemented.
- [ ] M3: resume worker threads its owner/ttl into run options and treats a lost lease as a skip, not a crash.
- [ ] M3: heartbeat-keeps-exclusivity and lost-lease-stops tests pass; `leaseTtl` haddock and guide updated; full suite green.
- [ ] `CHANGELOG.md` entry written; master plan 16 Progress boxes for EP-4 ticked and registry status updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Milestone 1 validation (2026-07-23): the focused test proved that the patch
  set exists on generation 1 immediately after rotation, before the injected
  wake append. The first generation-1 run and its replay both took the active
  branch. The full suite passed 367 examples.


## Decision Log

Record every decision made while working on the plan.

- Decision: Record the patch set inside `rotateGeneration`, atomically (one transaction) with the next generation's seed append; keep `recordPatchSetIfFresh` for generation 0.
  Rationale: Master-plan direction. Rotation runs the *current* code, so the currently declared `activePatches` is exactly the set the fresh generation's first run would have recorded — the same argument `docs/plans/73-workflow-sleep-generation-and-patch-semantics-plus-journal-scale-hygiene.md` made for carrying the seed at rotation. Recording at rotation removes the load-time freshness heuristic from the rotated path entirely, so no pre-first-run append can defeat it. Generation 0 has no rotation moment, so the existing empty-journal path remains its recording point.
  Date: 2026-07-23

- Decision: `resurrectFailedWorkflow` appends no journal audit event.
  Rationale: The journal codec's event set is an integration contract (reserved step names, no new event types — `keiro/src/Keiro/Workflow.hs:48-52`), and an audit `StepRecorded` would sit inertly in every future replay map. The history is already reconstructible: the journal retains the `WorkflowFailed` event(s), and a running instance whose journal contains one but whose step index lacks the failed-marker row is, by construction, a resurrected instance. Operational audit ("who, when") belongs in the operator's own logs around the API call.
  Date: 2026-07-23

- Decision: The `WorkflowFailed` marker append stops overriding the kiroku event id (uses a store-generated id); all other journal events keep their deterministic ids.
  Rationale: Verified hazard: kiroku rejects a duplicate event id with a `DuplicateEvent` store error (unique violation mapping in `kiroku-store/src/Kiroku/Store/Error.hs` around lines 101-105 and the mapping table near 162) — it is not an idempotent no-op. The failure marker's deterministic id is derived from `(name, id, generation, "__workflow_failed__")` (`keiro/src/Keiro/Workflow.hs:942-948`), so after resurrection deletes the failed-marker *index* row, a second terminal failure at the same generation would re-append with the same event id and blow up the marking path (the journal event itself cannot be deleted — journals are append-only). Dedupe of concurrent same-generation failure marking does not need the deterministic id: the advisory lock plus the in-transaction index check in `prepareJournalAppend` (`Workflow.hs:731-746`) already serialize same-key writers, and the append and index row commit atomically. No caller consumes the failure marker's event id (grep: `appendJournalEntryReturningId` is used only by the sleep path for `StepRecorded`).
  Date: 2026-07-23

- Decision: Resurrecting a failed *child* also revives its `keiro_workflow_children` link row (`failed -> running`), and an already-delivered parent failure sentinel is *not* retracted.
  Rationale: Without the row revive, the child is undrivable — `runChildWorkflow` short-circuits `Just ChildFailed -> pure Failed` (`keiro/src/Keiro/Workflow/Child.hs:316`) and a failed row is invisible to `findRunningChildIds`. The parent sentinel is journaled history and immutable; a parent that already consumed `{"failed": reason}` stays failed unless resurrected itself. Soft-dependency assumption recorded per the master plan: this is designed against EP-2's (`docs/plans/113-...`) end state, where a parent's await arm detects failure from the *row* — reviving the row therefore also stops future arm-side failure throws, which is coherent (the child is running again). If this plan lands before 113, the pre-113 arm behavior (failed row falls to `pure ()`) means a parent awaiting a resurrected child simply remains suspended until the child completes — also coherent; note it in Surprises at landing time if the order matters in practice.
  Date: 2026-07-23

- Decision: Keep `maxAttempts = 5` and the existing backoff cap as defaults; ship documentation and the resurrection API instead of retuning.
  Rationale: `docs/plans/72-workflow-engine-failure-handling-instance-leasing-and-crash-window-atomicity.md` chose "retry with backoff to a terminal marker" deliberately; its gap was the missing recovery path, not the numbers. Changing defaults silently changes failure behavior for every deployed consumer; documenting the sizing math (see M2) plus a supported resurrect API addresses the review's actual concern (unrecoverable terminal failure) without a behavior change.
  Date: 2026-07-23

- Decision: Lease renewal is a step-boundary heartbeat configured via a new optional `WorkflowRunOptions` field, not an unconditional UPDATE inside every journal-append transaction.
  Rationale: `prepareJournalAppend` is also the append path for *external* wake sources (`signalAwakeable`, `childCompletionHook`, timer fires) that hold no lease, so renewal cannot live unconditionally in the append transaction; and `runWorkflowWith` does not know the lease owner — only the resume worker does. An options field (`WorkflowRunOptions` is explicitly the additive per-run options record, `keiro/src/Keiro/Workflow.hs:303-330`) lets the worker pass its owner/ttl down without new plumbing, keeps direct `runWorkflow` calls zero-cost (`Nothing` default), and a guarded one-row UPDATE per *fresh* step boundary is negligible next to the append transaction's existing statements. On a failed renewal the run must stop executing (the new owner is already driving), which a dedicated `WorkflowLeaseLost` exception expresses; the resume worker catches it before its generic crash handling so a lost lease is never counted as a workflow crash.
  Date: 2026-07-23

- Decision: A lost lease is counted under the existing `leaseSkipped` summary field, not a new field.
  Rationale: Semantically it is the same fact — another worker owns the instance — observed mid-advance instead of at claim time. Avoids widening `ResumeSummary` (a public record with positional construction in `emptyResumeSummary` and tests).
  Date: 2026-07-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/ (the master plan names the resurrection/terminal-status
contract as a candidate ADR). Keep task-local execution details here.

- Milestone 1 (2026-07-23): rotation now commits the next generation's seed
  and non-empty active patch set together, condemning the transaction on either
  append conflict. Generation 0 and pre-change rotated generations retain the
  fresh-journal compatibility path. A pre-first-run wake append can no longer
  suppress patch recording.


## Context and Orientation

This section is self-contained.

ADR context: `docs/adr/` contains only `0001-keiro-pgmq-job-processing-telemetry-contract.md` (pgmq job-processing telemetry) — no relevant ADR exists for this work. The master plan lists "the resurrection/terminal-status contract" as an ADR to distill from this plan at completion.

### The moving parts

A *durable workflow* (`keiro/src/Keiro/Workflow.hs`) journals named step results to a kiroku event stream (kiroku is this repository's append-only Postgres event store) and replays them on re-runs. Every journal append transaction also writes a row to the `keiro_workflow_steps` *step index* and upserts the `keiro_workflows` *instance row* (status, attempts, lease fields) in the same transaction (`prepareJournalAppend`, `Workflow.hs:708-746`). A *generation* is a journal epoch: `continueAsNew` unwinds the run and `rotateGeneration` (`Workflow.hs:817-844`) appends the next generation's seed step first (this atomically advances `MAX(generation)`), then a rotation marker on the old generation.

The *patch API* (`patch`, `Workflow.hs:277-297`): a deploy declares its active patch ids in `WorkflowRunOptions.activePatches`; a generation records that set once as JSON under the reserved step name `__workflow_patches__`; each `patch pid` call journals and replays a `Bool` — `True` iff `pid` was in the recorded set. The recording happens in `recordPatchSetIfFresh` (`Workflow.hs:523-534`): the set is appended only when the loaded journal's key set is a subset of `{__workflow_seed__}` (a "fresh start"). On a `Patch` miss with **no** recorded set, the decision silently computes from an empty list (`Nothing -> pure []`, `Workflow.hs:620-622`) — every patch decides `False`, forever, because each decision is itself journaled and replayed verbatim.

The *resume worker* (`keiro/src/Keiro/Workflow/Resume.hs`) discovers unfinished workflows and advances each under an expiry-based *lease* on the instance row: `claimInstance` (`keiro/src/Keiro/Workflow/Instance.hs:75-84`, statement 177-199) takes the lease when it is absent **or expired**, and `releaseInstance` clears it in a `finally` (`Resume.hs:332-347`). `leaseTtl` defaults to 60 s (`Resume.hs:186-194`); nothing renews it mid-advance. A synchronous non-store exception is `AdvCrashed`: `recordCrashTx` bumps `attempts` and sets the next-attempt backoff to `LEAST(power(2, attempts + 1), 64)` seconds (`Instance.hs:224-243`; the SQL reads the pre-increment value, so crashes back off 2, 4, 8, 16 s before the fifth crash hits the default `maxAttempts = 5` ceiling, `Resume.hs:363-379`). At the ceiling the worker appends the terminal `WorkflowFailed` marker (or, for a child, `appendFailedChildAndWakeParent`, `Resume.hs:386-419`): status becomes `failed`, the instance leaves discovery, direct runs short-circuit to `Failed` via a step-index existence check on `__workflow_failed__` (`Workflow.hs:457-461`), and failure cascades to parents as `WorkflowChildFailed`.

### Finding 1 — WFX-4: one stray append permanently disables patching for an instance

`recordPatchSetIfFresh`'s freshness heuristic is *load-time*: it asks whether the journal, as loaded at run start, contains only the seed. A freshly rotated generation is supposed to look exactly like that on its first run — but three asynchronous writers can append to it *before* that first run: (a) a duplicate `signalAwakeable` for a prior-generation id takes the repair path and appends the orphan `awk:<uuid>` entry at the *current* generation (the existing rotation test performs precisely this append — `keiro/test/Main.hs:7841-7864`, the stale signal at 7857 — albeit just *after* the first run); (b) `childCompletionHook` or attach re-delivery racing the rotation; (c) a stale sleep re-fire — fixed at its source by `docs/plans/114-pin-sleep-firing-to-its-generation-and-make-gc-cancel-scheduled-sleep-timers.md`, but the fragility here remains for (a) and (b). Result: `freshStart = False`, the set is never recorded for that generation, the `Patch` miss path reads `[]`, and every `patch` in the instance decides `False` for its remaining lifetime — journaled, so permanent — silently diverging from every other instance of the same workflow.

### Finding 2 — WFC-3: terminal failure with no supported way back

The failure policy is intentional (see `docs/plans/72-workflow-engine-failure-handling-instance-leasing-and-crash-window-atomicity.md`, whose Decision Log argues "even 'deterministic' failures … can be fixed by deploying corrected code"). But that argument assumes a recovery path that does not exist: grep confirms no resurrect API anywhere in `keiro/src`; the one adjacent helper, `resetInstanceAttempts` (`Instance.hs:95-97`, statement 245-262), guards `status NOT IN ('completed','cancelled','failed')` and so *cannot* touch a failed instance. Recovery today is undocumented manual SQL: delete the `__workflow_failed__` row from `keiro_workflow_steps` and reset the instance row — the journal's `WorkflowFailed` *event* is benign (`loadJournal` ignores it, `Workflow.hs:694`, and the short-circuit is index-based). With the backoff math above, an outage where each attempt fails after a slow timeout can exhaust the default ceiling within a couple of minutes.

One verified hazard shapes the API (details in the Decision Log): kiroku treats a duplicate event id as an *error* (`DuplicateEvent`), and the failure marker's event id is deterministic per generation — so after resurrection, a second failure at the same generation would collide. M2 therefore also switches the `WorkflowFailed` marker to a store-generated id.

### Finding 3 — WFC-4: the lease silently expires under a slow advance

`claimInstance` is called once per advance; a foreign live lease skips the candidate, but an *expired* lease is claimable (statement predicate `lease_expires_at IS NULL OR lease_expires_at < now`, `Instance.hs:188`). A healthy worker mid-advance holds nothing that stops a second replica from claiming after `leaseTtl` elapses; both then execute the workflow body concurrently. The journal converges — the append path's advisory lock serializes same-step writers and the loser adopts the stored value (verified sound) — but every un-journaled step's *side effects* run twice, systematically, for any workflow whose steps are slower than the ttl (LLM calls, batch jobs). `leaseTtl`'s haddock (`Resume.hs:170-171`) frames the lease purely as "if the worker dies mid-advance", so operators won't size it against step duration.

The test suite: `keiro-test` (335 examples, 0 failures at authoring time) self-provisions PostgreSQL via `withMigratedSuite` (`keiro/test/Main.hs:353`). No migration is expected from this plan (the revive statements are UPDATEs/DELETEs on existing tables); if implementation proves otherwise, follow the master plan's numbering rule — claim the next free number in `keiro-migrations/migrations/` at landing time (0019 at authoring time, expected to be claimed by `docs/plans/113-...`), never a number an unlanded sibling claimed.


## Plan of Work

Three milestones, one per finding. Each ends with the full suite green.

### Milestone 1 — record the patch set atomically at rotation

Scope: move the rotated-generation recording into `rotateGeneration`; prove a pre-first-run append can no longer disable patching.

In `keiro/src/Keiro/Workflow.hs`:

- Give `rotateGeneration` the declared set: add a `Set PatchId` parameter and pass `options ^. #activePatches` at the call site (the `WorkflowRotate` catch, line 491).
- Inside `rotateGeneration`, build *both* next-generation appends and run them in **one** transaction: the seed step (`continueSeedStepName`) and — when the set is non-empty — the patch-set record (`patchSetStepName`, encoded exactly as `recordPatchSetIfFresh` does: `Aeson.toJSON (map unPatchId (Set.toList patches))`). Concretely, obtain both prepared transactions via `prepareJournalAppend name wid nextGen ...` and execute `runTransaction (seedTx >>= \seedOutcome -> patchTx >>= \patchOutcome -> pure (seedOutcome, patchOutcome))`, condemning on any `JournalAppendConflict` (both appends are guarded by the in-transaction index check, so a re-run of an interrupted rotation collapses each to `JournalAlreadyPresent` — the rotation stays idempotent, and atomicity means no state exists in which the seed is present without the patch set).
- Write the advisory rotation snapshot from the map containing *both* entries at the later append's stream version (when the patch append actually appended; otherwise keep today's seed-only snapshot). This preserves the O(1) hydration property documented at `Workflow.hs:809-815`.
- Leave `recordPatchSetIfFresh` in place: generation 0 still records on its first fresh run, and for rotated generations the loaded journal now already contains `__workflow_patches__`, so its subset check is simply never true there (no double append; `appendJournal` is idempotent regardless). Update its comment to say the rotated-generation case is handled at rotation.

Test (new group `"Keiro.Workflow patch recording at rotation"` in `keiro/test/Main.hs`; all four sibling plans append distinct groups): a rolling body that calls `restoreSeed`, then `patch (PatchId "p1")`, journaling the decision into its result; run options declare `activePatches = Set.singleton (PatchId "p1")`. (1) Run generation 0 to its `continueAsNew`. (2) **Before** generation 1's first run, inject a wake-shaped append onto generation 1 — `appendJournalEntry name wid (StepRecorded "awk:11111111-1111-1111-1111-111111111111" (toJSON True) now)` resolves the current generation and reproduces writer (a)/(b). (3) Run generation 1 and assert the body observes `patch -> True`. Before the fix, step 3 records `False` permanently; after, the set was journaled at rotation and the decision is `True`. Also re-run generation 1 and assert the decision replays `True` (journaled decision stability), and keep the existing patch tests and the rotation-adjacent awakeable test (7841) green.

Acceptance: new test passes; full suite green.

### Milestone 2 — a supported resurrection API, and documentation for the failure policy

Scope: `resurrectFailedWorkflow`, the duplicate-id hazard fix, tests, and the guide section.

Schema pieces:

- `keiro/src/Keiro/Workflow/Schema.hs`: add and export `deleteStepRowTx :: Text -> Text -> Int -> Text -> Tx.Transaction ()` (DELETE from `keiro.keiro_workflow_steps` by the four-column key) — used to remove the `__workflow_failed__` marker row for the current generation.
- `keiro/src/Keiro/Workflow/Instance.hs`: add and export `reviveFailedInstanceTx :: Text -> Text -> Tx.Transaction Bool` — `UPDATE keiro.keiro_workflows SET status = 'running', attempts = 0, last_error = NULL, next_attempt_at = NULL, leased_by = NULL, lease_expires_at = NULL, completed_at = NULL, updated_at = now() WHERE workflow_id = $1 AND workflow_name = $2 AND status = 'failed'`, decoded as rows-affected > 0. (Contrast `resetInstanceAttempts`, which deliberately refuses terminal rows and stays as-is.)
- `keiro/src/Keiro/Workflow/Child/Schema.hs`: add and export `reviveFailedChildTx :: Text -> Text -> Tx.Transaction Bool` (`SET status = 'running' ... WHERE ... AND status = 'failed'`).

The API, in `keiro/src/Keiro/Workflow/Instance.hs` (it already imports `currentGeneration`; add the child-schema import):

```haskell
data ResurrectOutcome = WorkflowResurrected | WorkflowNotFailed | WorkflowNotFound
    deriving stock (Generic, Eq, Show)

resurrectFailedWorkflow ::
    (Store :> es) => WorkflowName -> WorkflowId -> Eff es ResurrectOutcome
```

Behavior: look up the instance; `Nothing -> WorkflowNotFound`; status other than `WfFailed -> WorkflowNotFailed`; otherwise resolve `gen <- currentGeneration` and run one transaction that deletes the failed-marker index row (`deleteStepRowTx wid name gen failedStepName`), revives the instance (`reviveFailedInstanceTx`), and revives the child link when one exists (`reviveFailedChildTx` — a no-op `False` for non-children). Return `WorkflowResurrected` when the instance revive reported `True`. The journal's `WorkflowFailed` *event* is deliberately left in place (append-only journal; `loadJournal` ignores it; the run-start short-circuit is the index check that the delete just cleared). Export `ResurrectOutcome` and `resurrectFailedWorkflow` from the module head; mention them in `Keiro.Workflow.Resume`'s module documentation as the operator counterpart to the failure ceiling.

The duplicate-id hazard fix, in `keiro/src/Keiro/Workflow.hs` (`prepareJournalAppend`, around lines 725-729): set the deterministic event id for every event *except* `WorkflowFailed`, which keeps `eventId = Nothing` so kiroku generates a fresh UUIDv7 — see the Decision Log for why this is required (re-failure after resurrection would otherwise raise `DuplicateEvent`) and why dedupe does not regress (advisory lock + in-transaction index check). Add a comment at the site citing the hazard.

Tests (group `"Keiro.Workflow resurrection"`):

1. Resurrect-then-complete: drive a registered workflow to the ceiling with `maxAttempts = 1` and a body that throws while an IORef flag is set (the established ceiling pattern, cf. `keiro/test/Main.hs:8147`); assert status `failed` and that both `resumeWorkflowsOnce` skips it and a direct run short-circuits to `Failed`. Clear the flag (the "deploy the fix" moment), call `resurrectFailedWorkflow` → `WorkflowResurrected`; assert `lookupInstance` shows `running` with `attempts = 0`; drive it → `Completed`, with previously journaled steps replayed, not re-executed (assert via the side-effect counter).
2. Resurrect-then-refail: same setup, but leave the flag set after resurrection and drive to the ceiling again — the second `WorkflowFailed` append must succeed (this fails with a store error before the event-id change), status is `failed` again, and a second `resurrectFailedWorkflow` works.
3. Guard rails: `resurrectFailedWorkflow` on a running instance → `WorkflowNotFailed` with nothing changed; on an unknown id → `WorkflowNotFound`.

Documentation: add a "Failure, retries, and resurrection" subsection to `docs/guides/durable-workflows.md` (under "The resume worker" or "Operational notes"): what counts as a crash vs. a transient store error; the backoff schedule (2, 4, 8, 16 s, capped at 64) with the worked default — five attempts can be consumed within roughly a minute of backoff plus per-attempt time, so a multi-minute dependency outage with fast-failing calls *will* terminally fail in-flight workflows at defaults; how to size `maxAttempts`/`leaseTtl` for a target outage tolerance; and `resurrectFailedWorkflow` usage with its semantics (index-row clear, journal event retained, child-link revive, parent sentinel not retracted).

Acceptance: the three tests pass; full suite green.

### Milestone 3 — lease renewal during long advances

Scope: the heartbeat option, renewal at fresh step boundaries, lost-lease stop semantics, worker integration, docs.

In `keiro/src/Keiro/Workflow/Instance.hs`: add and export `renewInstanceLeaseTx :: Text -> NominalDiffTime -> UTCTime -> Text -> Text -> Tx.Transaction Bool` — `UPDATE keiro.keiro_workflows SET lease_expires_at = <now + ttl>, updated_at = <now> WHERE workflow_id = ... AND workflow_name = ... AND leased_by = <owner>`, rows-affected > 0 — plus an `Eff`-level wrapper `renewInstanceLease`.

In `keiro/src/Keiro/Workflow.hs`:

- New public types: `data LeaseHeartbeat = LeaseHeartbeat { owner :: Text, ttl :: NominalDiffTime }` and a `WorkflowLeaseLost` exception (mirroring the existing sentinel style, but *exported* — it is part of the operator surface). New `WorkflowRunOptions` field `leaseHeartbeat :: !(Maybe LeaseHeartbeat)`, default `Nothing` in `defaultWorkflowRunOptions` (`Workflow.hs:337-345`) — direct `runWorkflow` users are untouched.
- In the handler, before running each *fresh* step action (the `Step` miss path, before line 551's unlift) and before each `Await` miss arm: when the heartbeat is set, renew; if renewal returns `False` the lease is gone — `throwIO WorkflowLeaseLost` so no further side effects run (the new owner is already driving; the journal-append advisory path keeps whatever both wrote convergent). Replay hit paths never renew (they touch no side effects and must stay read-only fast).

In `keiro/src/Keiro/Workflow/Resume.hs`:

- The advance passes heartbeat-carrying options: in `driveInstance`, derive `opts' = (runOptions opts) { leaseHeartbeat = Just (LeaseHeartbeat owner (leaseTtl opts)) }` (thread `owner` into `driveInstance`; it is in scope at the call site, `Resume.hs:326-347`).
- Catch `WorkflowLeaseLost` *before* the generic `catchSync` (a new `AdvanceResult` alternative or a targeted `catch`): count it as `leaseSkipped` (Decision Log), record **no** crash, and leave `progressed = False` so the `finally` release (owner-guarded, `Instance.hs:201-222`) is a harmless no-op when the lease was stolen.
- Update `leaseTtl`'s haddock (`Resume.hs:170-171`): with the heartbeat, the ttl bounds the *step*-level stall a dead worker can leave behind, and must exceed the longest single step action, not the whole advance; without it (direct runs), it is unchanged.

Tests (group `"Keiro.Workflow lease renewal"`), both single-threaded and deterministic:

1. Heartbeat keeps exclusivity: claim the instance as owner "A" (`claimInstance "A" ttl name wid` with a small ttl, e.g. 0.2 s); run the workflow with `leaseHeartbeat = Just (LeaseHeartbeat "A" 60)` and a body whose fresh step *action* itself attempts `claimInstance "B" ...` after a `threadDelay` longer than the original ttl — assert that claim returns `False` (the boundary renewal already extended the lease) and the run completes. Without the fix the "B" claim succeeds — the WFC-4 signature.
2. Lost lease stops the run: claim as "A", then steal the lease by SQL (set `leased_by = 'B'`, `lease_expires_at` in the future — the test file already uses raw `Tx.statement` helpers for such setup); run with heartbeat "A" and a two-step body with side-effect counters — assert the run throws `WorkflowLeaseLost` at the first fresh boundary, the second step's effect never ran, and (via the resume-worker path) the summary counts a `leaseSkipped` while `lookupInstance` shows `attempts = 0` (no crash recorded).

Acceptance: both tests pass; existing lease tests in the "Keiro.Workflow instance table" and resume groups stay green; full suite green. Write the `CHANGELOG.md` entry (all three features; note the new `WorkflowRunOptions` field is additive), tick EP-4's three boxes in master plan 16, and update its registry row.


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

Iterate per group:

```bash
cabal test keiro-test --test-options='--match "patch recording at rotation"'
cabal test keiro-test --test-options='--match "resurrection"'
cabal test keiro-test --test-options='--match "lease renewal"'
```

Suggested commits:

```text
fix(workflow): record the active patch set atomically inside rotateGeneration (WFX-4)
feat(workflow): resurrectFailedWorkflow operator API and failure-policy docs (WFC-3)
feat(workflow): step-boundary lease heartbeat with lost-lease stop (WFC-4)
```


## Validation and Acceptance

Acceptance is behavioral:

1. Patch survival: rotate, inject a wake append before the new generation's first run, run — `patch` decides `True` and keeps deciding `True` on replay. Before this plan the same sequence silently locks the instance to `False` forever.
2. Resurrection: a workflow failed at the ceiling is skipped by discovery and short-circuits to `Failed`; after `resurrectFailedWorkflow` returns `WorkflowResurrected` it is discovered, driven, and completes without re-executing journaled steps. A resurrected workflow that fails again reaches `failed` cleanly (no store error) and can be resurrected again. Before this plan, none of this exists — recovery is manual SQL, and the naive marker-row delete alone would break on re-failure.
3. Lease: a step action slower than the original ttl no longer allows a second owner to claim mid-advance; a genuinely stolen lease stops the run at the next fresh boundary with `WorkflowLeaseLost`, counted as a skip (no crash attempt consumed).
4. `cabal test keiro-test` prints `0 failures`, including the pre-existing patch tests (`docs/plans/73-...`'s), ceiling test (8147), rotation-awakeable test (7841), and all lease/claim tests.

Failure signatures: test 1 deciding `False` means the rotation transaction is not writing the patch set (or the catch site is not passing `activePatches`); test 2's re-failure raising a `DuplicateEvent`-shaped store error means the `WorkflowFailed` event-id change is missing; test 3's "B" claim succeeding means the heartbeat is not renewing at the fresh-step boundary.


## Idempotence and Recovery

All changes are code-only (no migration expected — see Context for the fallback numbering rule). `rotateGeneration` remains idempotent: both next-generation appends are index-guarded, so a re-run of an interrupted rotation converges, and single-transaction atomicity removes the seed-without-patch-set intermediate state entirely. `resurrectFailedWorkflow` is idempotent in effect: a second call on an already-revived instance returns `WorkflowNotFailed` and changes nothing; the transaction is all-or-nothing, so a crash mid-call leaves the workflow either fully failed or fully revived. Lease renewal is a guarded UPDATE; re-running it is harmless, and the `Nothing` default means any rollback of the worker integration restores exact current behavior.


## Interfaces and Dependencies

No new packages. End-state interfaces per milestone (full module paths):

- M1 — `keiro/src/Keiro/Workflow.hs`: `rotateGeneration` gains a `Set PatchId` parameter (internal function; call-site updated); no exported-surface change.
- M2 — `Keiro.Workflow.Instance`: `data ResurrectOutcome = WorkflowResurrected | WorkflowNotFailed | WorkflowNotFound`; `resurrectFailedWorkflow :: (Store :> es) => WorkflowName -> WorkflowId -> Eff es ResurrectOutcome`; `reviveFailedInstanceTx :: Text -> Text -> Tx.Transaction Bool`. `Keiro.Workflow.Schema`: `deleteStepRowTx :: Text -> Text -> Int -> Text -> Tx.Transaction ()`. `Keiro.Workflow.Child.Schema`: `reviveFailedChildTx :: Text -> Text -> Tx.Transaction Bool`. `Keiro.Workflow`: `prepareJournalAppend` internal change (store-generated id for `WorkflowFailed`).
- M3 — `Keiro.Workflow`: `data LeaseHeartbeat = LeaseHeartbeat { owner :: Text, ttl :: NominalDiffTime }`, exported `WorkflowLeaseLost` exception, `WorkflowRunOptions.leaseHeartbeat :: Maybe LeaseHeartbeat` (additive field). `Keiro.Workflow.Instance`: `renewInstanceLeaseTx` / `renewInstanceLease`. `Keiro.Workflow.Resume`: heartbeat threading plus lost-lease handling (no signature changes).

Cross-plan coordination (master plan Integration Points): this plan edits `rotateGeneration`/`recordPatchSetIfFresh` in `keiro/src/Keiro/Workflow.hs` while `docs/plans/112-...` edits the `Await` handler and `loadJournal` docs in the same module — different functions, coordinate only on merge order. Soft dependency: implement M2's resurrection semantics against `docs/plans/113-...`'s `ChildFailed` end state when it has landed; otherwise proceed with the recorded pre-113 assumption (Decision Log). `docs/plans/114-...`'s generation-pinned sleep fire removes writer (c) from Finding 1; both plans must land for the combined rotation/patch property to hold. All four sibling plans append distinct test groups to `keiro/test/Main.hs`.
