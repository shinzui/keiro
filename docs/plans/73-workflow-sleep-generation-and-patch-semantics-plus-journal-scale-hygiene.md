---
id: 73
slug: workflow-sleep-generation-and-patch-semantics-plus-journal-scale-hygiene
title: "Workflow sleep, generation, and patch semantics plus journal scale hygiene"
kind: exec-plan
created_at: 2026-06-11T04:45:56Z
intention: intention_01kv40hzwaenftzem0gxypz4mj
master_plan: "docs/masterplans/9-keiro-production-readiness-hardening.md"
---

# Workflow sleep, generation, and patch semantics plus journal scale hygiene

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Keiro's durable workflow engine (the `keiro` package in this repository) lets an application author write a long-running business process as ordinary Haskell, with each side effect journaled so the process survives crashes, sleeps for days without a thread, waits on external signals, and rotates its history with `continueAsNew` so it can run forever. A June 2026 production-readiness audit found that several of those promises are false today, in ways an author cannot see until production:

- **A sleep longer than the resume worker's poll interval never fires.** Every resume pass re-arms the timer with a freshly computed `fire_at`, perpetually pushing the deadline into the future — a livelock. With the default 1-second poll, *any* sleep over ~1 second is silently eternal the moment a resume worker (the standard deployment) is running. (Audit finding C2, critical.)
- **A sleep, awakeable, or child wait placed after `continueAsNew` never resolves.** The identifiers of these wake sources are derived without the journal *generation*, so the second generation collides with the first generation's already-terminal rows and the workflow suspends forever. The flagship "rolling poller" pattern (`restoreSeed` → work → `sleep` → `continueAsNew`) wedges at generation 1. (C3, critical.)
- **The `patch` API misclassifies instances in both directions**: any `patch` call placed after a suspension point routes *all* instances — including genuinely fresh ones — down the old branch forever, and a pre-patch instance suspended on a wake source before its first ordinary step takes the new branch despite being in flight. (H4, high.)
- **Awakeable ids are forgeable** (a deterministic UUID over guessable coordinates — M5), **step results silently change representation after a crash** (first run returns the original value, replay returns the JSON round-trip — M2), **discovery scans the entire step-index table every second and nothing is ever pruned** (M6), and **a 30-day sleeper is fully replayed every second** (M7).

After this plan is implemented: a workflow can sleep for an hour, a day, or a month under an actively polling resume worker and wake on time; the rolling-poller pattern works across an unbounded number of `continueAsNew` rotations with sleeps, awakeables, and children in every generation; `patch` decisions are journaled from a declared active-patch set and are correct for instances that suspend before or around the patch point; awakeable ids carry journaled entropy and cannot be forged from coordinates; a step's first-run return value is bit-identical to every replay's; discovery reads a small instance table instead of GROUP-BY-ing all history; terminal workflows' journals, step rows, awakeable rows, child links, timers, and snapshots are garbage-collected after a configurable retention; and a workflow parked on a future timer is skipped by the resume worker until its wake time. Every fix lands with a test that fails on the current code.

This plan is a child of the MasterPlan at `docs/masterplans/9-keiro-production-readiness-hardening.md` (EP-7 in its registry). It HARD-depends on `docs/plans/72-workflow-engine-failure-handling-instance-leasing-and-crash-window-atomicity.md` (EP-6), which defines the `keiro_workflows` instance table this plan's discovery and pruning milestones consume, and SOFT-depends on `docs/plans/70-make-outbox-inbox-timer-and-shard-workers-crash-recoverable.md` (EP-4), which owns the claim/requeue/mark statements on the same `keiro_timers` table whose *arm* path this plan changes. Milestones 1–4 and 7 have no dependency on either sibling and can start immediately; milestones 5 and 6 are gated on EP-6.


## Progress

- [x] Milestone 1: add `scheduleTimerOnceTx` (insert-only arm) to `keiro/src/Keiro/Timer/Schema.hs` (completed 2026-06-15)
- [x] Milestone 1: switch `sleepNamed` in `keiro/src/Keiro/Workflow/Sleep.hs` to `scheduleTimerOnceTx`; correct the false "collapses to a no-op" module/function docs (completed 2026-06-15)
- [x] Milestone 1: test — arm a sleep, run a resume pass, assert `fire_at` unchanged (completed 2026-06-15)
- [x] Milestone 1: test — a sleep longer than the poll interval fires under an actively polling resume worker (completed 2026-06-15)
- [x] Milestone 2: capture golden gen-0 id values (sleep timer id, awakeable id) from the pre-change code before editing (completed 2026-06-15)
- [x] Milestone 2: add `CurrentRunGeneration` operation + `currentRunGeneration` to the `Workflow` effect in `keiro/src/Keiro/Workflow.hs` (completed 2026-06-15)
- [x] Milestone 2: generation-namespace `sleepTimerId` (legacy derivation preserved at generation 0) (completed 2026-06-15)
- [x] Milestone 2: journaled random awakeable-id allocation with gen-0 legacy adoption in `keiro/src/Keiro/Workflow/Awakeable.hs`; add `awakeableAllocStepPrefix` to `keiro/src/Keiro/Workflow/Types.hs` (completed 2026-06-15)
- [x] Milestone 2: child attach semantics — `awaitChild` arm re-delivers a completed child's stored result onto the current generation in `keiro/src/Keiro/Workflow/Child.hs` (completed 2026-06-15)
- [x] Milestone 2: tests — sleep, awakeable, and child each across a `continueAsNew` rotation; gen-0 golden-id stability; awakeable forgeability test (completed 2026-06-15)
- [x] Milestone 2: update existing awakeable DB tests that predict ids from coordinates (completed 2026-06-15)
- [ ] Milestone 3: add `activePatches :: Set PatchId` to `WorkflowRunOptions`; add `patchSetStepName` to Types.hs
- [ ] Milestone 3: record the active patch set on an instance's first run (journal empty or seed-only) in `runWorkflowWith`
- [ ] Milestone 3: rewrite the `Patch` handler to decide from the recorded set; delete `startedInFlight` / `isOrdinaryStepKey`
- [ ] Milestone 3: tests — both adverse cases (fresh-but-suspended → new branch; in-flight-on-wake-source-only → old branch) plus the updated favorable test
- [ ] Milestone 4: `Step` miss path returns the JSON round-trip of the result (decode failure throws `WorkflowStepDecodeError` on the first run)
- [ ] Milestone 4: tests — lossy codec returns identical values on first run and replay; undecodable round-trip fails on the first run
- [ ] Milestone 4: docs — at-least-once step side effects (module header + `step` haddock, M1), name-keyed-replay trade-off (L4), every-n snapshot cost note (L6)
- [ ] Milestone 5 (gated on plan 72): reconcile the `keiro_workflows` DDL against plan 72's Interfaces and Dependencies section
- [ ] Milestone 5: switch `findUnfinishedWorkflowIds` to the `keiro_workflows` instance table (signature gains `UTCTime`)
- [ ] Milestone 5: new module `Keiro.Workflow.Gc` — `WorkflowGcPolicy`, `gcWorkflowsOnce`, `runWorkflowGcWorker`; migration adding the GC index
- [ ] Milestone 5: tests — discovery equivalence (unfinished / finished / rotated / cancelled), GC deletes all per-instance data past retention, retains recent, idempotent under re-run mid-crash
- [ ] Milestone 6 (gated on plan 72): migration adding `wake_after` to `keiro_workflows`; sleep arm sets it in the same transaction as the timer insert
- [ ] Milestone 6: discovery skips instances with a future `wake_after`; tests (skipped before fire time, discovered after, no re-invocation between)
- [ ] Milestone 7: `journalEntryExists` short-circuits via `Fold.any`
- [ ] Milestone 7: `nub` → `Set` dedup in `resumeWorkflowsOnce`
- [ ] Milestone 7: `mkWorkflowName` / `mkWorkflowId` smart constructors + separator documentation in Types.hs
- [ ] Final: full `cabal test keiro` and `cabal test keiro-migrations-test` green; Outcomes & Retrospective written


## Surprises & Discoveries

- **Both sibling plans this plan depends on are unauthored skeletons as of 2026-06-10.** `docs/plans/72-...` (which will define the `keiro_workflows` table) and `docs/plans/70-...` (which owns the timer claim/requeue/mark statements) contain only skeleton headings. Milestones 5 and 6 below are therefore written against the table shape described in the MasterPlan's Integration Points section, with an explicit reconcile step; milestone 1 is written to be statement-compatible with plan 70's described changes by construction (see Decision Log).
- **kiroku already exposes stream deletion.** `hardDeleteStream :: (HasCallStack, Store :> es) => StreamName -> Eff es (Maybe StreamId)` exists in `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Lifecycle.hs` (lines 92–97), so pruning journal streams (milestone 5) needs no upstream kiroku work and no reach-around SQL into kiroku's tables.
- **The C2 livelock is confirmed and the in-tree documentation actively asserts the opposite.** `keiro/src/Keiro/Workflow/Sleep.hs` lines 57–60 and 205–208 claim re-arms "collapse to a no-op"; the SQL at `keiro/src/Keiro/Timer/Schema.hs` lines 207–214 (`ON CONFLICT (timer_id) DO UPDATE SET ... fire_at = EXCLUDED.fire_at ... WHERE keiro_timers.status = 'scheduled'`) updates `fire_at` on every re-arm of a still-scheduled row, and the arm at `Sleep.hs` lines 218–228 recomputes `fireAt = addUTCTime delta now` from a fresh clock read on every resume. The existing sleep tests (`keiro/test/Main.hs` ~3278–3391) never run a resume pass between arm and fire, which is why this was never caught.
- **The C3 generation omission is confirmed by contrast within the same codebase.** `deterministicJournalId` (`keiro/src/Keiro/Workflow.hs` lines 829–835) deliberately includes the generation in its UUID-v5 input and documents why; `sleepTimerId` (`Sleep.hs` 165–178) and `deterministicAwakeableId` (`Awakeable.hs` 131–137) hash the same kind of coordinates *without* it.
- **Milestone 1 implementation discovery (2026-06-15): EP-4 and EP-6 have landed since this plan was authored.** EP-4's final `Keiro.Timer.Schema` already has stale-`firing` requeue, status-guarded mark/cancel/dead-letter statements, and additive timer worker validation; `scheduleTimerOnceTx` inserts the same row shape and leaves those claim/recovery paths untouched. EP-6's instance table and resume lease are also live, which let the active-resume sleep regression exercise the real production worker path rather than a stubbed rediscovery loop.
- **Milestone 2 implementation discovery (2026-06-15): child attach semantics were already present from EP-6's crash-window repair.** `awaitChild` already re-appended a completed child's stored result onto the parent's current generation; this milestone added documentation and a `continueAsNew` regression proving the same repair path is the intended attach behavior. Golden compatibility values captured before the arity/signature changes are `sleepTimerId (WorkflowName "wf") (WorkflowId "w-1") 0 "sleep:cool" == a95d5e7f-a43d-5ee2-9243-8206f0d8734a` and `deterministicAwakeableId (WorkflowName "w") (WorkflowId "1") "approval" == ccaeaf74-3ffe-5ea5-a118-a3441a95c279`.


## Decision Log

- Decision: Fix C2 with a new insert-only arming statement `scheduleTimerOnceTx` (`ON CONFLICT (timer_id) DO NOTHING`) used by the workflow sleep arm, leaving `scheduleTimerTx` untouched.
  Rationale: Process managers legitimately use the existing upsert to push back a deadline (re-arm-with-new-`fire_at` is a feature there); changing `scheduleTimerTx` globally would silently change PM semantics. An insert-only statement gives the sleep arm first-arm-wins `fire_at` with no journaling change and no schema change. It also satisfies the MasterPlan integration constraint with plan 70 by construction: the new statement inserts rows with exactly the same column set and `status = 'scheduled'` lifecycle as the old one, so plan 70's stale-`firing` requeue and status-guarded mark logic sees identical rows. The third audit option (journaling the absolute `fireAt`) was rejected as strictly more machinery for the same outcome — with insert-only arming the first `fire_at` already persists in the timer row.
  Date: 2026-06-10

- Decision: Generation-namespace wake-source ids only for generation ≥ 1; generation 0 keeps the exact legacy derivation.
  Rationale: This is the migration/compat story for C3. It mirrors `workflowGenerationStreamName` (`keiro/src/Keiro/Workflow/Types.hs` 117–122), where generation 0 keeps the legacy stream name precisely so never-rotated workflows need zero data migration. Every *working* in-flight pre-change wake source is necessarily at generation 0 (anything past generation 0 was already wedged by the bug — its sleep never fired, its awakeable never resolved), so preserving gen-0 derivation strands nothing, and gen-≥1 instances are actively *un-wedged*: their next resume derives a fresh, never-used id and arms a working wake source. No legacy-id fallback lookup is needed for sleeps. A golden-value test pins the gen-0 derivations so the compat property is machine-checked.
  Date: 2026-06-10

- Decision: Fix M5 (forgeable awakeable ids) and C3-for-awakeables together with one mechanism: the awakeable id becomes a random V4 UUID generated at first allocation and journaled under a dedicated allocation step (`awkid:<label>`), with a gen-0-only adoption fallback to the legacy deterministic id.
  Rationale: A journaled random id is unguessable (fixes M5), automatically fresh per generation because each generation's journal is fresh (fixes C3 for awakeables, including the previous-generation payload-bleed in `signalAwakeable`), and deterministic across resumes because replay reads it from the journal. HMAC-with-server-secret was rejected: it adds secret management and rotation problems, and anyone holding the secret can still derive ids. The cost — losing offline derivability (an external caller can no longer compute the id from `(name, wid, label)`) — is accepted: the documented flow has always been "the workflow hands the id to the external system", and offline derivation is exactly the forgeability being removed. The gen-0 adoption fallback (on allocation miss at generation 0, adopt an existing `keiro_awakeables` row under the legacy deterministic id) keeps every in-flight pre-change awakeable working; it is restricted to generation 0 so a completed legacy row can never bleed a stale payload into a later generation.
  Date: 2026-06-10

- Decision: Fix C3 for children with **attach semantics**, not a generation-extended link-table key. The audit suggested including the generation in the child link key; this plan deliberately deviates.
  Rationale: A child workflow's identity `(child_name, child_id)` names its own journal stream (`wf:<childName>-<childId>`). Generation-keying only the *link row* would let a rotated parent create a fresh `running` link to a child whose journal is already complete — the resume worker would "drive" it, the replay would instantly report `Completed` with the stale result, and the parent would silently receive old data: worse than the current wedge. The honest semantics is that a child id names one execution globally; re-spawning the same id after `continueAsNew` *attaches* to that execution, and the `awaitChild` arm re-delivers the stored result onto the parent's current generation journal (a self-heal append, idempotent by deterministic id). A parent that wants a fresh child per generation must use a fresh child id (derived from the rotation seed) — documented loudly on `spawnChild`. No migration, no key change, and the same arm-side self-heal also repairs the same-generation crash window where the link row says `completed` but the parent journal append was lost (the closing of that window's *origin* belongs to plan 72; the re-delivery here is complementary).
  Date: 2026-06-10

- Decision: Fix H4 by journaling the instance's effective patch set at the start of its first run, driven by a new `activePatches :: Set PatchId` field on `WorkflowRunOptions`. `patch pid` then answers `pid ∈ recorded set`, journaled per patch as today. The `startedInFlight` / `isOrdinaryStepKey` heuristic is deleted.
  Rationale: Any heuristic over "what the journal happens to contain at run start" is wrong in both directions, because suspension points journal nothing for the suspended step (a fresh instance that suspends looks in-flight on resume) and wake-source completions are non-"ordinary" keys (an in-flight instance can look fresh). The only stable signal is *what code shipped when the instance started*, and only the application knows that — hence the declared set, recorded exactly once when the loaded journal is empty or seed-only (a freshly rotated generation runs the current code from its start, so it re-records — consistent with the existing seed-step carve-out). Instances with no recorded set (anything in flight before this mechanism, or started while the set was empty) get `False` — the old branch — which is the conservative, safe direction. The recording is skipped when `activePatches` is empty, so workflows that never use `patch` pay nothing. This changes `patch`'s contract: a fresh instance gets `True` only if the patch id was declared active when the instance started; the existing favorable-case test must be updated to thread the option.
  Date: 2026-06-10

- Decision: Fix M2 by returning the JSON round-trip of the step result on the miss path, decoding **after** the journal append.
  Rationale: Decoding before the append would leave the (already-executed) side effect un-journaled, so every subsequent resume would re-run the side effect and fail again — a poison loop that multiplies effects. Decoding after the append fails exactly once per replay with the same typed `WorkflowStepDecodeError` the replay path already throws, the side effect is journaled exactly once, and plan 72's failure handling can surface it.
  Date: 2026-06-10

- Decision: M7's skip mechanism is a nullable, self-expiring `wake_after timestamptz` column on `keiro_workflows`, set to the timer's `fire_at` by the sleep arm in the same transaction as the timer insert, and *never cleared*.
  Rationale: A workflow run is sequential: while it is parked on an unresolved sleep, the only event that can resolve that step is the timer firing, so nothing is lost by not waking it earlier. Because the skip predicate is `wake_after <= now`, the column self-expires the moment the fire time passes — no clear-on-fire, clear-on-signal, or crash-window bookkeeping at all. A stale past value never suppresses anything. If the instance row does not exist yet when the arm runs (possible orderings inside plan 72's row maintenance), the `UPDATE` touches zero rows and the workflow merely keeps today's behavior (re-invoked every pass) — degraded performance, never lost wake-ups. The column lives on plan 72's table via this plan's own `ALTER TABLE` migration; see the reconcile step.
  Date: 2026-06-10

- Decision: `findUnfinishedWorkflowIds` changes signature to take an explicit `UTCTime` when it moves to the instance table.
  Rationale: The `wake_after` predicate needs a clock; an explicit parameter mirrors `claimDueTimer`'s style, avoids DB/app clock-skew surprises in tests, and makes the skip behavior deterministically testable.
  Date: 2026-06-10

- Decision: Pruning (milestone 5) deletes a terminal instance's dependent data first and the `keiro_workflows` row last; journal streams are removed with kiroku's `hardDeleteStream`; an instance is GC-eligible only if no *non-terminal* parent still links to it as a child.
  Rationale: Deleting the instance row last makes a crash mid-GC self-healing — the next pass rediscovers the instance and re-runs the (idempotent) deletes. `hardDeleteStream` is the supported kiroku surface (verified present), so no raw SQL against kiroku's tables. The child-link guard exists because attach semantics (above) may still need a completed child's stored result to re-deliver to a live parent.
  Date: 2026-06-10

- Decision: L1 is fixed with a short-circuiting `Fold.any` over the existing stream read, not with kiroku's planned event-id point lookup.
  Rationale: The point lookup is plan 67's artifact (consumed by plan 71); taking a dependency on it for a one-line fold change would gate this plan on an unrelated upstream release. `Fold.any` terminates the stream on first match (stops pulling pages), which removes the O(stream) full fold. A follow-up swap to the point lookup once plan 67 lands is noted in the code comment, not required here.
  Date: 2026-06-10

- Decision: L3 ships additive smart constructors (`mkWorkflowName`, `mkWorkflowId`) plus documentation; the raw newtype constructors stay exported and unvalidated.
  Rationale: Validating the raw constructors would break existing callers (the test suite and docs use hyphenated names like `"crash-demo"` today). The smart constructors reject the genuinely ambiguous shapes — names containing `-`, `:` or `#`; ids containing `:` or `#` (ids keep `-` so UUID ids work; with hyphen-free names the `wf:<name>-<id>` boundary is the first `-` and is unambiguous) — mirroring `keiro-core`'s `category` / `categoryUnsafe` convention (`keiro-core/src/Keiro/Stream.hs`), including its camelCase recommendation for compound names. Whether to *enforce* validation at `runWorkflowWith` is left to a future breaking-change window; documented as such.
  Date: 2026-06-10


## Outcomes & Retrospective

Milestone 1 is complete as of 2026-06-15. Workflow sleep arming now uses insert-only timer scheduling, so the first `fire_at` persists across repeated resume passes. The module documentation no longer claims the old `scheduleTimerTx` upsert makes re-arms harmless. Focused validation passed with `cabal test keiro --test-options='--match "Keiro.Workflow.Sleep"'` (7 examples, 0 failures), and full validation passed with `cabal test keiro` (239 examples, 0 failures).

Milestone 2 is complete as of 2026-06-15. Sleep timer ids are generation-namespaced after generation 0, awakeable ids are journaled random ids with legacy generation-0 adoption, forged coordinate-derived awakeable ids no longer resolve fresh promises, and completed child rows attach cleanly after `continueAsNew`. Focused validation passed with `cabal test keiro --test-options='--match "Keiro.Workflow.Sleep" --match "Keiro.Workflow.Awakeable" --match "Keiro.Workflow.Child"'` (34 examples, 0 failures), and full validation passed with `cabal test keiro` (244 examples, 0 failures). Milestone 3 remains next for patch classification.


## Context and Orientation

Everything below assumes no prior knowledge of this repository. Work happens in the `keiro` package (`keiro/` subdirectory) and the migrations package (`keiro-migrations/`) of the repository rooted at `/Users/shinzui/Keikaku/bokuno/keiro`. All paths in this document are repository-relative unless they start with `/`.

**What a durable workflow is here.** A *durable workflow* is an ordinary `effectful` computation run through `runWorkflow` / `runWorkflowWith` (`keiro/src/Keiro/Workflow.hs`). Each `step name action` either runs `action` and *journals* its JSON-encoded result, or — on a later run — returns the previously recorded result without re-running the action ("replay"). The journal is a stream of events in the kiroku event store (kiroku is the PostgreSQL event-store library this repo composes; its source is at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`). The journal stream is named `wf:<name>-<id>` (`workflowStreamName`, `keiro/src/Keiro/Workflow/Types.hs` 101–103). Alongside the stream, every journal append upserts a row into the `keiro_workflow_steps` index table (`keiro/src/Keiro/Workflow/Schema.hs`) in the same transaction; the index is what fast lookups and discovery use, the stream is the replay source of truth.

**Suspension and wake sources.** A workflow pauses with `awaitStep name arm` (`Workflow.hs` 191–192, handler at 498–510): if `name` is journaled, return its result; otherwise run the *arming* action and throw an internal suspend sentinel so `runWorkflow` returns `Suspended`. The arm must be idempotent because **every resume re-runs it** until the step resolves (documented contract, `Workflow.hs` 25–29). A *wake source* is whatever resolves the awaited step from outside by appending a `StepRecorded` with the awaited step name via `appendJournalEntry` / `appendJournalEntryReturningId` (`Workflow.hs` 623–657). There are three wake sources:

- *Sleep* (`keiro/src/Keiro/Workflow/Sleep.hs`): the arm inserts a row into the `keiro_timers` table (shared with process-manager timers; DDL in `keiro-migrations/sql-migrations/2026-05-17-00-00-00-keiro-bootstrap.sql`) via `scheduleTimerOnceTx` (`keiro/src/Keiro/Timer/Schema.hs`). A timer worker (`Keiro.Timer.runTimerWorker`, driven here through `runWorkflowTimerWorker`, `Sleep.hs`) claims due rows and calls `workflowSleepFireAction`, which appends the `sleep:<name>` completion to the journal.
- *Awakeable* (`keiro/src/Keiro/Workflow/Awakeable.hs`): a durable promise. The workflow allocates an `AwakeableId`, hands it to an external system, and awaits `awk:<uuid>`; the external system calls `signalAwakeable`, which flips a `keiro_awakeables` row (`keiro-migrations/sql-migrations/2026-06-03-01-00-00-keiro-awakeables.sql`) to `completed` and appends the journal entry.
- *Child workflow* (`keiro/src/Keiro/Workflow/Child.hs` and `Child/Schema.hs`): `spawnChild` journals a spawn step and inserts a link row in `keiro_workflow_children` (PK `(child_id, child_name)`); the resume worker drives the child; on child completion `childCompletionHook` appends `child:<id>:result` to the parent journal.

**The resume worker.** `keiro/src/Keiro/Workflow/Resume.hs` discovers unfinished workflows each pass via `findUnfinishedWorkflowIds` (`Schema.hs` 114–116, SQL at 198–218: a CTE that `GROUP BY`s the **entire** `keiro_workflow_steps` table to find each logical workflow's `MAX(generation)`, then keeps those without a terminal marker row) and re-invokes each through `runWorkflowWith` from an application-supplied `WorkflowRegistry`. The fixed-poll driver sleeps `pollInterval` (default **1 second**, `Resume.hs` 156–163) between passes; the push-aware driver (`runWorkflowResumeWorkerPush`, `Resume.hs` 348–357) additionally wakes on **any** event-store append. Either way, every unfinished workflow is re-invoked — journal preload, full replay, and re-run of every pending arm — roughly every second.

**Generations and `continueAsNew`.** A workflow that would otherwise journal unboundedly calls `continueAsNew seed`: the runtime journals the seed as the first step of generation *g+1* on a fresh physical stream `wf:<name>-<id>#<g+1>` and a terminal rotation marker on generation *g* (`rotateGeneration`, `Workflow.hs` 696–720). `currentGeneration` (`Schema.hs` 103–105) is `MAX(generation)` from the step index. Generation 0 keeps the un-suffixed legacy stream name. Crucially, `deterministicJournalId` (`Workflow.hs` 829–835) includes the generation in every journal event id and documents why; the wake-source id derivations do **not** (the C3 bug).

**Patches.** `patch (PatchId "...")` (`Workflow.hs` 234–252, handler 523–541) journals a Bool branch decision under `patch:<id>`: `True` = new branch (fresh instance), `False` = old branch (in flight when the patch shipped). Today the decision on first encounter is `not startedInFlight`, where `startedInFlight = any isOrdinaryStepKey (Map.keys initial)` (`Workflow.hs` 425) — i.e. "did the journal contain any non-reserved step key when this run began". That heuristic is the H4 bug.

**Snapshots.** The accumulated step map can be snapshotted into the `keiro_snapshots` table (PK `stream_id`; bootstrap migration) via `keiro/src/Keiro/Workflow/Snapshot.hs`, advisory only.

**The instance table (consumed, not defined, by this plan).** Plan 72 (`docs/plans/72-workflow-engine-failure-handling-instance-leasing-and-crash-window-atomicity.md`) introduces a `keiro_workflows` table with one row per workflow instance — per the MasterPlan's Integration Points section: workflow name, id, current generation, a status whose terminal values include `completed`, `cancelled`, and `failed`, and lease owner/expiry columns, maintained in the same transaction as the journal markers it summarizes. **As of this writing plan 72 is an unauthored skeleton**, so milestones 5 and 6 below state their assumed DDL explicitly and begin with a mandatory reconcile step against plan 72's Interfaces and Dependencies section. If plan 72 has not landed (the table does not exist in `keiro-migrations/sql-migrations/`), milestones 5 and 6 are blocked; everything else proceeds.

**Migrations.** SQL migrations live in `keiro-migrations/sql-migrations/` as timestamped files (e.g. `2026-06-05-00-00-00-keiro-workflow-generation.sql`), applied by codd via the `keiro-migrations` package and embedded with Template Haskell. Build gotcha (documented at `Workflow.hs` 46–52): adding a `.sql` file does **not** trigger recompilation of `Keiro.Migrations` — touch a comment in `keiro-migrations/src/Keiro/Migrations.hs` or run `cabal clean` after adding one. Each migration starts with `SET search_path TO kiroku, pg_catalog;` (see `2026-06-05-00-00-00-keiro-workflow-generation.sql` for the pattern).

**Tests.** The keiro suite is `keiro/test/Main.hs` (hspec, test-suite name `keiro-test`), run as `cabal test keiro` from the repository root. Its `main` is `withMigratedSuite $ \fixture -> hspec $ ...` — the suite-level template-database fixture from `keiro-test-support/src/Keiro/Test/Postgres.hs` (`withMigratedSuite` at line 74 starts one cached PostgreSQL server via ephemeral-pg, migrates a template database once; `withFreshStore fixture` at line 99 clones a fresh migrated database per example). **Never add per-example migrations** — always `around (withFreshStore fixture)` inside a `describe`, exactly like the existing `describe "Keiro.Workflow.Sleep"` block (`test/Main.hs` ~3260). The migrations package has its own suite, `cabal test keiro-migrations-test`. Per the MasterPlan's crash-window test pattern, a "crash between two statements" is simulated by running the first statement directly through the schema module and then exercising recovery; if plan 70, 71, or 72 has already landed a shared crash-window helper, reuse its shape rather than inventing a parallel one.

**The verified bugs, precisely.**

- *C2*: `sleepNamed` (`Sleep.hs` 209–228) computes `fireAt = addUTCTime delta now` with a **fresh** `now` inside the arm, and the arm re-runs on every resume (by design). `scheduleTimerStmt` (`Timer/Schema.hs` 199–224) is an upsert whose `DO UPDATE SET fire_at = EXCLUDED.fire_at ... WHERE keiro_timers.status = 'scheduled'` overwrites `fire_at` on every re-arm of a still-scheduled row. With a resume pass every ~1 s, any sleep longer than ~1 s has its deadline perpetually postponed: a livelock. The module docs (57–60) and `sleepNamed` haddock (205–208) claim the re-arm "collapses to a no-op" — false.
- *C3*: `sleepTimerId` (`Sleep.hs` 165–178) is a v5 UUID over `("keiro","workflow-sleep",name,wid,fullStep)` — no generation. After `continueAsNew`, generation 1's arm derives the *same* timer id; the row is terminal (`fired`), the `WHERE status = 'scheduled'` guard silently refuses, no timer exists, and the workflow suspends forever. `deterministicAwakeableId` (`Awakeable.hs` 131–137) likewise omits the generation: a re-used label finds the old row; if that row is `completed`, a re-signal journals the **previous generation's stored payload** onto the new generation (`signalAwakeable`'s `row ^. #payload` branch, `Awakeable.hs` 253–256), and without a re-signal it wedges. Children: the link PK `(child_id, child_name)` (`Child/Schema.hs` registerChildStmt, 154–170) means a re-spawned child id after rotation no-ops into the old (possibly `completed`) row, whose `markChildResultTx` is guarded `status = 'running'`, so the parent's await on the new generation never resolves.
- *H4*: `Workflow.hs` 425 + 523–541. Adverse case (a): a fresh post-patch instance that journals one step (or just suspends on a wake source whose completion is later journaled... any journaled ordinary key) before the patch call resumes with `startedInFlight = True` → old branch forever — i.e. **any patch call after a suspension point routes all instances down the old branch**. Adverse case (b): a pre-patch instance whose journal holds only wake-source completions (`sleep:`/`awk:`/`child:` keys are excluded by `isOrdinaryStepKey`, 559–564) resumes as `False` → new branch despite being in flight. The only existing test (`test/Main.hs` 2898–2947) covers only the favorable case.
- *M1/M2*: the `Step` miss path (`Workflow.hs` 476–497) runs `act` (line 477), then `recordStep` (line 479) — a crash between them re-runs the side effect on resume (at-least-once; inherent, but the docs say "not run again"); and it returns `a` itself while journaling `toJSON a`, so a lossy `ToJSON`/`FromJSON` pair diverges only after a crash.
- *M5*: anyone who can guess `(workflow name, workflow id, label)` can compute the awakeable UUID and `signalAwakeable` arbitrary payloads into the journal.
- *M6/M7*: discovery SQL (`Schema.hs` 198–218) aggregates the whole step table every pass; nothing is ever deleted; and every unfinished workflow — including a 30-day sleeper — is fully re-invoked every pass (`Resume.hs` 209–261), which is also the trigger that arms C2.
- *Lows*: `journalEntryExists` (`Workflow.hs` 751–758) folds the entire stream with `seen || ...` — no short-circuit, every page read. `nub` in `resumeWorkflowsOnce` (`Resume.hs` 228) is O(n²). `WorkflowName`/`WorkflowId` separators are documented-but-unvalidated (`Types.hs` 94–122): `name1 <> "-" <> id1 == name2 <> "-" <> id2` collides two logical instances on one journal stream. Every-n snapshots rewrite the full map each time (accepted; `continueAsNew` bounds the map — documented in milestone 4).


## Plan of Work

Seven milestones. 1–4 and 7 are independent of the sibling plans and of each other except where noted (do milestone 2 after 1, since both edit `Sleep.hs`); 5 and 6 require plan 72's `keiro_workflows` table to exist and must reconcile against its final DDL. Each milestone ends with `cabal build keiro` clean and the named tests green.


### Milestone 1 — Stop the sleep re-arm livelock (C2)

*Scope.* After this milestone, re-arming a sleep is a true no-op: the first arm's `fire_at` persists no matter how many resume passes run, and a sleep longer than the resume poll interval fires. This is the single highest-value fix in the plan and is deliberately minimal: one new SQL statement, one call-site switch, two tests, and honest documentation.

In `keiro/src/Keiro/Timer/Schema.hs`, add `scheduleTimerOnceTx :: TimerRequest -> Tx.Transaction ()` and its statement `scheduleTimerOnceStmt`, identical to `scheduleTimerStmt` except the conflict clause:

```sql
INSERT INTO keiro_timers
  (timer_id, process_manager_name, correlation_id, fire_at, payload, status)
VALUES
  ($1, $2, $3, $4, $5, $6)
ON CONFLICT (timer_id) DO NOTHING
```

Reuse the existing `contrazip6` encoder shape from `scheduleTimerStmt` (lines 216–224). Export `scheduleTimerOnceTx` from the module and from `Keiro.Timer` (which re-exports the schema surface — mirror how `scheduleTimerTx` is exported there). Haddock it as: *insert-only arming for callers whose re-arm must preserve the original `fire_at` — the durable-workflow sleep arm; process managers that intend to push back a deadline keep `scheduleTimerTx`*. Do not touch `claimDueTimer`, `requeueStuckTimer`, `markTimerFired`, or any other statement — those belong to `docs/plans/70-make-outbox-inbox-timer-and-shard-workers-crash-recoverable.md`. Compatibility with plan 70 is by construction: the inserted row has the same columns and `scheduled` status as before, so any requeue/claim logic over `status` sees nothing new. If plan 70 has landed by the time this is implemented, re-read its final statements and confirm none of them key on how a row was *inserted* (they should not); note the check in this plan's Surprises section.

In `keiro/src/Keiro/Workflow/Sleep.hs`, change `sleepNamed`'s arm (line 228) from `runTransaction (scheduleTimerTx request)` to `runTransaction (scheduleTimerOnceTx request)` and update the import. Rewrite the false documentation: the module-header "Deterministic timer id" bullet (54–60) and the `sleepNamed` haddock (205–208) currently justify idempotence via "`scheduleTimerTx` re-arms only a still-`Scheduled` row"; replace with the truth — *arming is insert-only (`scheduleTimerOnceTx`), so the first arm's `fire_at` wins and every later re-arm (each resume pass re-runs the arm) is a no-op; the sleep duration is measured from the first arm, not from the latest resume.*

*Tests* (in `keiro/test/Main.hs`, inside the existing `describe "Keiro.Workflow.Sleep" $ around (withFreshStore fixture)` block, reusing its `sleepDemoNamed` helper workflow and `sleepTimerStatusStmt`-style direct row reads — add a `fire_at`-reading statement next to it):

1. **THE regression test — "a resume pass does not postpone fire_at."** Run `sleepDemoNamed counter (StepName "cool") 300` (a 300-second sleep) once → `Suspended`. Read the timer row's `fire_at` directly (add a small `Statement UUID (Maybe UTCTime)` over `SELECT fire_at FROM keiro_timers WHERE timer_id = $1`). Run `resumeWorkflowsOnce defaultWorkflowResumeOptions registry` with the workflow registered (this re-invokes the workflow, which replays, re-enters the arm, and re-arms). Read `fire_at` again and assert **exact equality** with the first read. On current code this fails: the second value is later by the inter-pass wall time.
2. **End-to-end — "a sleep longer than the poll interval still fires."** A workflow with a 1-second sleep. Drive it with an interleaved loop that simulates a production deployment: repeat up to ~16 times { `resumeWorkflowsOnce ...`; `now <- getCurrentTime`; `runWorkflowTimerWorker Nothing now (\_ -> pure Nothing)`; `threadDelay 250_000` } until the workflow's `Completed` is observed (check via a final `runWorkflow` returning `Completed` or by `findUnfinishedWorkflowIds` going empty). Assert the side-effect counter ran each step exactly once. On current code the resume pass every 250 ms re-arms a 1 s sleep forever and the loop budget is exhausted.

*Acceptance.* `cabal test keiro` green including the two new examples; the first test fails before the code change and passes after (verify by running it once before switching the call site — this is cheap and proves the test bites).


### Milestone 2 — Generation-correct, unforgeable wake-source identity (C3 + M5)

*Scope.* After this milestone the rolling-poller pattern works forever: sleeps, awakeables, and child waits resolve in every generation, awakeable ids are unguessable for new allocations, and no pre-change in-flight generation-0 instance is stranded. Do this after milestone 1 (both touch `Sleep.hs`).

**Step 2.0 — capture golden values first.** Before editing anything, pin the current gen-0 derivations so compat is machine-checked. From the repository root:

```bash
cabal repl keiro
```

```haskell
ghci> import Keiro.Workflow.Sleep
ghci> import Keiro.Workflow.Awakeable
ghci> import Keiro.Workflow.Types
ghci> sleepTimerId (WorkflowName "wf") (WorkflowId "w-1") "sleep:cool"
ghci> deterministicAwakeableId (WorkflowName "w") (WorkflowId "1") "approval"
```

Record both UUIDs as literal constants in the new golden tests below.

**Step 2.1 — expose the run's generation through the effect.** In `keiro/src/Keiro/Workflow.hs`, add an operation to the `Workflow` effect (the GADT at lines 144–168) and its smart constructor:

```haskell
-- | The journal generation this run is operating on (0 before any
-- continueAsNew). Wake sources include it in their id derivations so a
-- rotated generation never collides with a prior generation's rows.
CurrentRunGeneration :: Workflow m Int
```

```haskell
currentRunGeneration :: (Workflow :> es) => Eff es Int
currentRunGeneration = send CurrentRunGeneration
```

The handler clause is `CurrentRunGeneration -> pure gen` (`gen` is already a parameter of `handler`). Export `currentRunGeneration`. This is additive; nothing existing changes.

**Step 2.2 — generation-namespace the sleep timer id.** In `Sleep.hs`, change `sleepTimerId` to take the generation, preserving the legacy derivation at generation 0 (the compat story — see Decision Log):

```haskell
sleepTimerId :: WorkflowName -> WorkflowId -> Int -> Text -> TimerId
sleepTimerId name wid gen fullStep =
    TimerId $ UUID.V5.generateNamed UUID.V5.namespaceURL $
        fmap (fromIntegral . fromEnum) $ Text.unpack $
            Text.intercalate ":" components
  where
    components
        | gen <= 0 = ["keiro", "workflow-sleep", unWorkflowName name, unWorkflowId wid, fullStep]
        | otherwise = ["keiro", "workflow-sleep", unWorkflowName name, unWorkflowId wid, Text.pack (show gen), fullStep]
```

In `sleepNamed`, fetch `gen <- currentRunGeneration` next to `currentWorkflow` and pass it. Document on `sleepTimerId` *why* generation 0 omits the component (in-flight pre-change timers keep working; every gen ≥ 1 pre-change instance was already wedged and is un-wedged by deriving a fresh id). Update the pure `sleepTimerId` tests at `test/Main.hs` ~3264 to the new arity, and add: the gen-0 derivation equals the pinned golden UUID; gen 1 differs from gen 0; two different generations differ from each other.

**Step 2.3 — journaled random awakeable ids with gen-0 legacy adoption.** In `keiro/src/Keiro/Workflow/Types.hs`, add a reserved prefix for the allocation step and export it:

```haskell
-- | Reserved step-name prefix under which an awakeable's id is allocated and
-- journaled (the id itself is random; the journal makes it replay-stable).
awakeableAllocStepPrefix :: Text
awakeableAllocStepPrefix = "awkid:"
```

In `keiro/src/Keiro/Workflow/Awakeable.hs`, rework `awakeableNamed` (signature gains `IOE :> es`):

```haskell
awakeableNamed ::
    (Workflow :> es, Store :> es, IOE :> es, FromJSON a) =>
    StepName ->
    Eff es (AwakeableId, Eff es a)
awakeableNamed (StepName label) = do
    (name, wid) <- currentWorkflow
    gen <- currentRunGeneration
    aid <-
        step (StepName (awakeableAllocStepPrefix <> label)) $
            allocateAwakeableId name wid gen label
    let stepNm = StepName (awakeableStepPrefix <> awakeableIdText aid)
    pure (aid, awaitCancellable name wid aid stepNm)
```

with the allocation action (private):

```haskell
-- Generation 0 adopts an existing legacy-derived row (compat for in-flight,
-- pre-change instances whose id was already handed out); otherwise the id is
-- fresh randomness, journaled by the surrounding 'step' so replay is stable
-- and the id is unguessable from coordinates.
allocateAwakeableId ::
    (Store :> es, IOE :> es) =>
    WorkflowName -> WorkflowId -> Int -> Text -> Eff es AwakeableId
allocateAwakeableId name wid gen label
    | gen <= 0 = do
        let legacy = deterministicAwakeableId name wid label
        existing <- lookupAwakeable (awakeableIdToUuid legacy)
        case existing of
            Just _ -> pure legacy
            Nothing -> AwakeableId <$> liftIO UUID.V4.nextRandom
    | otherwise = AwakeableId <$> liftIO UUID.V4.nextRandom
```

Add `import Data.UUID.V4 qualified as UUID.V4` (the `uuid` package is already a dependency — `Data.UUID.V5` is imported today). `awakeable` (the ordinal form) inherits the change via `awakeableNamed`. Keep `deterministicAwakeableId` exported but re-haddock it: *legacy derivation, predictable from coordinates; used only for generation-0 adoption of pre-change rows; do not hand-derive ids — take the id `awakeableNamed` returns.* Update the module-header contract recap (lines 25–48): the id is journaled randomness; offline derivation is no longer supported and was the forgeability hole. Document on `awakeableNamed` that a label names one promise per generation (re-using a label in the same generation returns the same resolved promise — unchanged behavior), and that after `continueAsNew` the same label is a *fresh* promise.

Why this closes the C3 awakeable wedge **and** the payload bleed: each generation's journal lacks the `awkid:<label>` step, so a rotated generation allocates a fresh row; the old completed row is never consulted (adoption is gen-0-only); and `signalAwakeable` on the old id appends a step name (`awk:<old-uuid>`) the new generation never awaits — a harmless orphan entry, noted in the haddock.

**Step 2.4 — child attach semantics.** In `keiro/src/Keiro/Workflow/Child.hs`, extend `awaitChild`'s arm (lines 200–207): when the link row exists with `status == ChildCompleted` and a stored result, re-deliver it onto the parent's *current* generation before suspending:

```haskell
arm = do
    mrow <- lookupChild (unWorkflowId childWid) (unWorkflowName childNm)
    case mrow of
        Just row
            | (row ^. #status) == ChildCancelled ->
                throwIO (WorkflowChildCancelled childNm childWid)
            | (row ^. #status) == ChildCompleted
            , Just storedResult <- row ^. #result -> do
                -- Attach semantics: the child execution already finished
                -- (e.g. the parent rotated via continueAsNew and re-spawned
                -- the same child id, or the original result append was lost
                -- to a crash). Re-deliver the stored result onto the
                -- parent's CURRENT generation journal; idempotent by
                -- deterministic journal id. The next resume replays past.
                now <- liftIO getCurrentTime
                appendJournalEntry parentNm parentWid
                    StepRecorded
                        { stepName = row ^. #awaitStep
                        , result = storedResult
                        , recordedAt = now
                        }
        _ -> pure ()
```

`awaitChild` must therefore learn the parent identity: fetch `(parentNm, parentWid) <- currentWorkflow` at the top (it is a `Workflow :> es` function already), and the signature gains `IOE :> es` (for `getCurrentTime` and `appendJournalEntry`). Note `appendJournalEntry` resolves the current generation internally (`Workflow.hs` 629–657), which is exactly the attach target. Document on `spawnChild` (and the module header): *a child id names one execution globally; spawning an id that already completed attaches to it and `awaitChild` returns its recorded result — to run a fresh child per `continueAsNew` generation, derive a fresh child id from the rotation seed.* This deliberately deviates from the audit's "generation in the link key" suggestion — rationale in the Decision Log. No schema change.

*Tests* (new `describe` blocks with `around (withFreshStore fixture)`):

1. **Sleep across rotation.** A rolling workflow: `restoreSeed (0 :: Int)`; a counted `step`; if seed < 2 then `sleepNamed (StepName "cool") 0` then `continueAsNew (seed + 1)` else `pure seed`. Drive it with the interleaved resume + timer-worker loop from milestone 1 test 2, with a bounded budget. Assert it `Completed` and the counter shows one work step per generation (3 total). On current code generation 1's arm hits the gen-0 `fired` row and the loop budget exhausts.
2. **Awakeable across rotation.** Generation 0 allocates label `"gate"` (capture the returned `AwakeableId` into an `IORef` inside a `step` — the workflow body is a closure over test refs, as existing tests do with counters), suspends; signal it with payload `"first"`; resume → `continueAsNew`; generation 1 allocates `"gate"` again (capture id #2), suspends. Assert id #2 ≠ id #1; assert the workflow is still suspended after re-signalling id #1 (stale id resolves nothing on the new generation); signal id #2 with `"second"`; resume; assert the workflow completes observing `"second"` — never `"first"` (the payload-bleed regression).
3. **Child across rotation (attach).** Parent gen 0 spawns child id `c1`, awaits, child completes with result `R` (drive via `resumeWorkflowsOnce` with both registered); parent rotates; gen 1 spawns the *same* `c1` and awaits → after one resume pass the parent proceeds with `R` (attach), no wedge. Then a variant where gen 1 spawns a *fresh* id `c2` → the fresh child executes and the parent gets the fresh result.
4. **Forgeability.** A fresh workflow allocates label `"approval"` (random id, no legacy row). Compute `deterministicAwakeableId` from the public coordinates and `signalAwakeable` it → returns `False` and the workflow remains `Suspended` on the next pass. Signal the real id (from the IORef) → `True`, workflow completes.
5. **Golden gen-0 stability.** `sleepTimerId (WorkflowName "wf") (WorkflowId "w-1") 0 "sleep:cool"` equals the pinned pre-change UUID literal; `deterministicAwakeableId (WorkflowName "w") (WorkflowId "1") "approval"` equals its pinned literal. **Legacy adoption:** insert a pending `keiro_awakeables` row under the legacy id directly via `registerAwakeableTx`, then run a gen-0 workflow using the same label → the id it hands out (IORef) *is* the legacy id, and signalling the legacy id completes it.

Also update the existing awakeable DB tests (following `test/Main.hs` ~3391) that predict the id via `deterministicAwakeableId`: have the workflow expose its id through an IORef (or read the `awkid:<label>` entry from `loadStepIndex`) instead of deriving it.

*Acceptance.* `cabal test keiro` green; tests 1–4 each fail on pre-milestone code (1–3 by suspension-forever, 4 by the forged signal returning `True`).


### Milestone 3 — Honest patch classification (H4)

*Scope.* After this milestone, `patch` decisions derive from a journaled record of which patches were active when the instance (or rotated generation) started — correct across suspension points in both adverse directions.

In `keiro/src/Keiro/Workflow/Types.hs`, add and export:

```haskell
-- | Reserved step name under which an instance's effective patch set (the
-- 'PatchId's declared active when its first run began) is journaled. Absent
-- entry == empty set == every 'patch' answers False (old branch).
patchSetStepName :: Text
patchSetStepName = "__workflow_patches__"
```

In `keiro/src/Keiro/Workflow.hs`:

1. Add `activePatches :: !(Set PatchId)` to `WorkflowRunOptions` (with `import Data.Set (Set)` / `qualified Data.Set as Set`), default `Set.empty` in `defaultWorkflowRunOptions`. Haddock: *the patch ids currently shipped in this code; recorded into each fresh instance's journal on its first run and consulted by every 'patch' call. Add a PatchId here in the same deploy that introduces its `patch` call; remove it only after the `patch` call itself has been deleted from the workflow body.* This follows the established additive-options pattern (EP-41/EP-44 fields).
2. In `interpreted` (inside `runActive`), after `initial <- loadJournal ...` and before creating `journalRef`: when the loaded journal is empty or seed-only **and** the declared set is non-empty, record the patch set and extend the in-memory map:

```haskell
let freshStart = Map.keysSet initial `Set.isSubsetOf` Set.singleton continueSeedStepName
initial' <-
    if freshStart && not (Set.null (options ^. #activePatches))
        then do
            now <- liftIO getCurrentTime
            let encodedSet = Aeson.toJSON (map unPatchId (Set.toList (options ^. #activePatches)))
            appendJournalEntry name wid
                StepRecorded{stepName = patchSetStepName, result = encodedSet, recordedAt = now}
            pure (Map.insert patchSetStepName encodedSet initial)
        else pure initial
journalRef <- liftIO (newIORef initial')
```

`appendJournalEntry` is the idempotent helper (existence pre-check, deterministic id, duplicate-tolerant), so two racing first runs converge. The seed-only carve-out means a freshly rotated generation re-records the *current* set — a rotated generation runs the current code from its start, the same reasoning the deleted heuristic applied to seed steps. Note the safe edge case in a code comment: a pre-change instance that armed a wake source and suspended with a literally empty journal is indistinguishable from fresh and will record the current set — harmless, because nothing of its old-code execution was journaled, so replaying under the new branch from the top is coherent.

3. Rewrite the `Patch` handler clause: on hit, replay as today; on miss, decide from the recorded set:

```haskell
Patch pid -> do
    let key = patchStepName pid
    journal <- liftIO (readIORef journalRef)
    case Map.lookup key journal of
        Just stored -> decodeStored key stored
        Nothing -> do
            recordedSet <- case Map.lookup patchSetStepName journal of
                Nothing -> pure []
                Just v -> decodeStored patchSetStepName v :: Eff es [Text]
            let decision = unPatchId pid `elem` recordedSet
                encoded = Aeson.toJSON decision
            _ <- recordStep name wid gen (StepName key) encoded
            liftIO (atomicModifyIORef' journalRef (\m -> (Map.insert key encoded m, ())))
            pure decision
```

(Adapt the `decodeStored` use to the handler's actual monad as needed.) Delete `startedInFlight` (line 425), the `Bool` parameter threaded into `handler`, and `isOrdinaryStepKey` (549–564) — it has no other callers (it is not exported; verify with a grep before deleting). Update `patch`'s haddock (234–252): the decision is now *"True iff this patch id was in `activePatches` when the instance's first run began"*; spell out the operational protocol (declare on ship; retire by deleting the `patch` call first, then the declaration) and that an undeclared patch makes **all** instances — including fresh ones — take the old branch (the safe direction, and immediately visible in behavior).

*Tests* (extend the existing `describe "Keiro.Workflow patch API"` block; its `postPatchWorkflow` runs must switch from `runWorkflow` to `runWorkflowWith defaultWorkflowRunOptions{activePatches = Set.fromList [fraudPatchId]}` — the favorable-case test is *expected to need this update*; that is the contract change, not a regression):

1. **Adverse (a): a fresh instance that suspends before its patch call takes the new branch.** Post-patch workflow shape: `step "reserve"` → `awaitStep "awk:gate" (pure ())` → `patch` → branch. Run a fresh instance with `activePatches = [pid]` → `Suspended` (the patch-set entry and `reserve` are journaled). Resolve the gate by appending `StepRecorded "awk:gate" ...` directly (the existing resume tests at `test/Main.hs` 2718–2726 show the pattern). Resume → must complete on the **new** branch. Current code: `startedInFlight = True` → old branch — fails.
2. **Adverse (b): a pre-patch instance journaled only wake-source completions stays on the old branch.** Run workflow v1 (no `patch`, `activePatches = ∅`): `awaitStep "awk:gate"` then a step → `Suspended` ; append the `awk:gate` completion (journal now holds only an `awk:` key). "Redeploy": resume the same id under v2 (a `patch` call after the await, `activePatches = [pid]`) → must complete on the **old** branch. Current code: `isOrdinaryStepKey` excludes `awk:` → fresh → new branch — fails.
3. **Favorable + stability (updated existing test):** in-flight instance old branch forever; fresh instance new branch forever; exactly one `patch:<id>` journal entry per instance with the expected Bool; additionally assert the fresh instance's journal contains exactly one `__workflow_patches__` entry listing the pid.
4. **Rotation:** an instance started pre-patch rotates via `continueAsNew` while `activePatches = [pid]` is shipped → the rotated generation records the set and its `patch` returns `True`. (One assertion appended to an existing rotation test or a small dedicated one.)

*Acceptance.* `cabal test keiro` green; tests 1 and 2 fail before the change.


### Milestone 4 — Replay fidelity and honest effect semantics (M2 + M1 + L4 + L6)

*Scope.* After this milestone, a step's first-run return value is exactly what every replay will return (representation mismatches fail on the *first* run, with the existing typed error), and the documentation tells the truth about side-effect semantics.

**Code (M2).** In the `Step` miss path (`Workflow.hs` 476–497), after the append and the journal-map insert, return the round-trip instead of `a`:

```haskell
-- Return the JSON round-trip, not the in-memory value: every replay will
-- decode the journaled JSON, so the first run must observe the identical
-- value — a lossy ToJSON/FromJSON pair fails HERE, on the first run, as a
-- WorkflowStepDecodeError, not days later after a crash-and-replay.
decodeStored key encoded
```

(i.e. replace the final `pure a` with `decodeStored key encoded`; the decode is *after* the append on purpose — see Decision Log.) `restoreSeed` and `awaitValue`-style callers inherit the guarantee since they go through `Step`/`Await` (`Await`'s hit path already decodes; its miss path returns nothing).

**Docs (M1, L4, L6).** In `Workflow.hs`:

- Module header: add a prominent **"Side effects are at-least-once"** paragraph — a crash between executing the step action and committing its journal append (the window between handler lines ~477 and ~479) re-runs the action on resume; this is inherent to durable execution; step bodies must therefore be idempotent. Show the recommended pattern: derive a deterministic id inside the step from the workflow identity and step name (e.g. a v5 UUID over `(name, wid, stepName)`, exactly how `deterministicJournalId` works) and make the external call idempotent on it.
- `step` haddock (171–178): replace "the recorded result is returned and @action@ is __not__ run again" with the precise claim — *on a replay where the step is journaled, the action is not run; if the process crashed after the action but before the journal commit, the action runs again on resume: at-least-once.* Also state the new M2 guarantee: *the returned value is the JSON round-trip of the result on every run including the first.*
- Module header (L4): document the name-keyed-replay trade-off — replay matches on step *names*, so renaming a step orphans its journaled entry (the renamed step re-runs fresh; the orphan is inert), and the runtime performs **no nondeterminism detection** (it cannot tell that a body changed under an existing name; the author owns name stability, which is also exactly the lever `patch` documents for single-step changes).
- `keiro/src/Keiro/Workflow/Snapshot.hs` module header (L6): note that an every-n snapshot policy rewrites the full accumulated map each time; accepted because `continueAsNew` is the documented tool for bounding the map, so the write stays O(bounded journal); revisit only if a profile shows otherwise.

*Tests.*

1. **Lossy pair is consistent from run one.** Define a test type whose round-trip normalizes, e.g. `newtype Approx = Approx Double` with `ToJSON` emitting `fromIntegral (round d :: Int)` and a plain derived `FromJSON` — first-run in-memory value `Approx 1.7`, journaled/decoded value `Approx 2.0`. A workflow `step "approx" (pure (Approx 1.7))` must return `Approx 2.0` on the **first** run (current code returns `1.7`), and an immediate re-run (replay) returns the same `2.0`.
2. **Undecodable round-trip fails on the first run.** A type whose `ToJSON` emits a shape its `FromJSON` rejects (e.g. encodes to a bare string, decoder demands an object). The first `runWorkflow` throws `WorkflowStepDecodeError` (catch with `try` as the crash tests do); assert the step *is* journaled (the index row exists via `stepExists`), so the failure is stable rather than effect-multiplying.

*Acceptance.* `cabal test keiro` green; test 1's first-run assertion fails before the change.


### Milestone 5 — Discovery on the instance table, and pruning (M6) — gated on plan 72

*Scope.* After this milestone, discovery is an indexed read of one row per instance instead of a full-history aggregation, and a `gcWorkflows` pass (plus an optional worker) deletes a terminal instance's journal streams, step rows, awakeable rows, child links, terminal sleep timers, snapshots, and finally its instance row, once it has been terminal longer than a configurable retention.

**Step 5.0 — mandatory reconcile.** Open `docs/plans/72-workflow-engine-failure-handling-instance-leasing-and-crash-window-atomicity.md` and read its **Interfaces and Dependencies** section for the final `keiro_workflows` DDL (column names, status values, timestamp columns) and for how/when rows are written. Everything below is written against this **assumed** shape, derived from the MasterPlan's Integration Points entry ("workflow name, id, current generation, status including a terminal `failed`, lease owner/expiry, written in the same transaction as the journal markers"):

```sql
-- ASSUMED shape (defined by docs/plans/72-...): reconcile before implementing.
CREATE TABLE keiro_workflows (
  workflow_id      text        NOT NULL,
  workflow_name    text        NOT NULL,
  generation       integer     NOT NULL DEFAULT 0,
  status           text        NOT NULL,  -- 'running' | 'completed' | 'cancelled' | 'failed' (assumed)
  lease_owner      text,
  lease_expires_at timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workflow_id, workflow_name)
);
```

If plan 72's final shape differs (different terminal-status spelling, a `completed_at` instead of `updated_at`, an extra suspended status, etc.), adapt the SQL below mechanically and record the delta in this plan's Surprises & Discoveries. If plan 72 has not landed at all, **stop here** — milestones 5 and 6 are blocked; everything else in this plan is not.

**Step 5.1 — switch discovery.** In `keiro/src/Keiro/Workflow/Schema.hs`, replace `findUnfinishedWorkflowIdsStmt` (198–218) with a read of the instance table, and change the function signature to `findUnfinishedWorkflowIds :: (Store :> es) => UTCTime -> Eff es [(Text, Text)]` (the `UTCTime` is unused until milestone 6 adds the `wake_after` predicate; taking it now avoids changing the signature twice):

```sql
SELECT workflow_id, workflow_name
FROM keiro_workflows
WHERE status NOT IN ('completed', 'cancelled', 'failed')
```

Update the two callers: `resumeWorkflowsOnce` (`Resume.hs` 226) fetches `now <- liftIO getCurrentTime` and passes it; the rotation/discovery tests in `test/Main.hs` (search for `findUnfinishedWorkflowIds`) pass a fresh `getCurrentTime`. The `findRunningChildIds` union in `resumeWorkflowsOnce` stays — a freshly spawned child may have no instance row yet. The semantics must be preserved exactly: unfinished reported once; completed/cancelled/failed not reported; a rotated (`ContinuedAsNew`) workflow still reported (its instance row is non-terminal). Keep the haddock's literals-must-match warning, now pointing at the status values.

**Step 5.2 — pruning.** New module `keiro/src/Keiro/Workflow/Gc.hs` (add to `keiro.cabal`'s `exposed-modules`), exporting:

```haskell
data WorkflowGcPolicy = WorkflowGcPolicy
    { retention :: !NominalDiffTime  -- ^ minimum age past terminal before deletion
    , batchSize :: !Int              -- ^ max instances per pass
    }

data WorkflowGcSummary = WorkflowGcSummary
    { scanned :: !Int   -- ^ eligible instances found this pass
    , deleted :: !Int   -- ^ instances fully deleted this pass
    }

gcWorkflowsOnce ::
    (IOE :> es, Store :> es) => UTCTime -> WorkflowGcPolicy -> Eff es WorkflowGcSummary

runWorkflowGcWorker ::
    (IOE :> es, Store :> es) => WorkflowGcPolicy -> Int {- poll µs -} -> Eff es ()
```

`gcWorkflowsOnce now policy` does, per pass:

1. *Eligibility query* (a statement local to `Gc.hs`): terminal instances older than the retention cutoff that no live parent still depends on:

```sql
SELECT w.workflow_id, w.workflow_name
FROM keiro_workflows w
WHERE w.status IN ('completed', 'cancelled', 'failed')
  AND w.updated_at <= $1            -- cutoff = now - retention
  AND NOT EXISTS (                  -- a non-terminal parent may still attach
    SELECT 1
    FROM keiro_workflow_children c
    JOIN keiro_workflows p
      ON p.workflow_id = c.parent_id AND p.workflow_name = c.parent_name
    WHERE c.child_id = w.workflow_id
      AND c.child_name = w.workflow_name
      AND p.status NOT IN ('completed', 'cancelled', 'failed')
  )
ORDER BY w.updated_at
LIMIT $2
```

2. Per instance, in this order (dependents first, instance row **last**, so a crash anywhere is healed by the next pass re-running idempotent deletes):
   a. `gen <- currentGeneration name wid`; for each `g` in `[0 .. gen]`: `let s = workflowGenerationStreamName name wid g`; `lookupStreamId s` and, when present, delete the `keiro_snapshots` row for that stream id (`DELETE FROM keiro_snapshots WHERE stream_id = $1` — snapshot delete *before* the stream delete, or the id becomes unresolvable), then `hardDeleteStream s` (from `Kiroku.Store.Lifecycle`; returns `Maybe StreamId`, `Nothing` for an already-gone stream — fine).
   b. `DELETE FROM keiro_workflow_steps WHERE workflow_id = $1 AND workflow_name = $2` (all generations).
   c. `DELETE FROM keiro_awakeables WHERE owner_workflow_name = $1 AND owner_workflow_id = $2` (index-supported by `keiro_awakeables_owner_idx`).
   d. `DELETE FROM keiro_workflow_children WHERE (parent_id = $1 AND parent_name = $2) OR (child_id = $1 AND child_name = $2)` — the child-side rows are safe to drop because eligibility already guaranteed no live parent.
   e. `DELETE FROM keiro_timers WHERE process_manager_name = $2 AND correlation_id = $1 AND payload->>'kind' = 'keiro.workflow.sleep' AND status IN ('fired', 'cancelled', 'dead')` — terminal workflow-sleep rows only; never touches `scheduled`/`firing` rows, so no interaction with plan 70's recovery logic. (`workflowSleepKind` is the `'keiro.workflow.sleep'` literal — keep them in sync, noted in a comment.)
   f. `DELETE FROM keiro_workflows WHERE workflow_id = $1 AND workflow_name = $2`.

Keep each statement in `Gc.hs` (they are GC-only; the schema modules keep their hot-path statements — note the choice in the module header). `runWorkflowGcWorker` is a trivial `forever (gcWorkflowsOnce =<< getCurrentTime; threadDelay poll)` loop mirroring `runWorkflowResumeWorkerWith`; GC is optional machinery an operator schedules (document a suggested retention of days, poll of minutes).

**Step 5.3 — migration.** New file `keiro-migrations/sql-migrations/<timestamp>-keiro-workflow-gc-index.sql` with a timestamp strictly later than plan 72's `keiro_workflows` migration (check the directory listing at implementation time):

```sql
-- Resolve unqualified names into the Kiroku schema (see plan 46's convention).
SET search_path TO kiroku, pg_catalog;

-- GC eligibility scan: terminal instances ordered by terminal age.
CREATE INDEX IF NOT EXISTS keiro_workflows_gc_idx
  ON keiro_workflows (status, updated_at);
```

Remember the Template Haskell gotcha: touch `keiro-migrations/src/Keiro/Migrations.hs` (a comment suffices) so `embedDir` re-runs; then `cabal test keiro-migrations-test` proves the migration applies.

*Tests* (new `describe "Keiro.Workflow.Gc"` plus assertions in the discovery tests; all `around (withFreshStore fixture)`):

1. **Discovery equivalence.** Build four instances — unfinished (crashed mid-run), completed, cancelled, rotated-and-still-running — and assert `findUnfinishedWorkflowIds now` reports exactly the unfinished and rotated ones, once each. (This re-proves, against the new SQL, what the existing tests at `test/Main.hs` 2670–2897 prove against the old; those existing tests, updated for the new arity, are the bulk of the proof.)
2. **GC deletes everything, respects retention.** Complete a workflow that used a sleep, an awakeable, and a child; run `gcWorkflowsOnce` with a 1-hour retention → `deleted = 0` and all rows intact; run with retention 0 → `deleted = 1` and: journal stream reads return empty/absent, zero `keiro_workflow_steps` / `keiro_awakeables` / `keiro_workflow_children` / terminal sleep-timer / `keiro_snapshots` rows for it, no `keiro_workflows` row, and discovery reports nothing.
3. **Live-parent guard.** A completed child of a still-running parent is *not* eligible even past retention; after the parent completes (and ages past retention) both collect.
4. **Idempotence / crash mid-GC.** Run the per-instance deletes partially by hand (e.g. delete the step rows directly), then `gcWorkflowsOnce` → still converges to fully deleted, `deleted` counts it once.

*Acceptance.* `cabal test keiro` and `cabal test keiro-migrations-test` green; the discovery describe-block passes against the instance table with the old statement deleted.


### Milestone 6 — Skip future sleepers (M7) — gated on plan 72 (and milestone 5)

*Scope.* After this milestone, a workflow parked on a sleep is not re-invoked at all until its fire time arrives: no journal preload, no replay, no arm re-run, every poll. Combined with milestone 1 this is belt *and* suspenders for C2; independently it removes the dominant steady-state cost for sleeper-heavy deployments.

**Migration** `keiro-migrations/sql-migrations/<timestamp>-keiro-workflows-wake-after.sql` (later than milestone 5's file; may be merged into one file with it if implemented together — keep one concern per statement either way):

```sql
SET search_path TO kiroku, pg_catalog;

-- A self-expiring resume hint: when set, the instance's only pending wake
-- source is a timer firing at this instant, so discovery skips the instance
-- until then. Written by the workflow sleep arm in the same transaction as
-- the timer insert; never cleared (a past value suppresses nothing).
ALTER TABLE keiro_workflows
  ADD COLUMN IF NOT EXISTS wake_after timestamptz;
```

**Arm writes it.** In `keiro/src/Keiro/Workflow/Schema.hs`, add `setWorkflowWakeAfterTx :: WorkflowName -> WorkflowId -> UTCTime -> Tx.Transaction ()` over `UPDATE keiro_workflows SET wake_after = $3 WHERE workflow_id = $1 AND workflow_name = $2` (zero rows affected is fine — see Decision Log). In `Sleep.hs`'s `sleepNamed` arm, extend the transaction:

```haskell
runTransaction (scheduleTimerOnceTx request >> setWorkflowWakeAfterTx name wid (request ^. #fireAt))
```

Note the value written is the *request's* `fireAt`; on a re-arm (insert no-ops) the same first-arm-anchored time is recomputed only approximately — but a re-arm only happens on a resume pass, which only happens once `wake_after` has already expired, at which point the timer is due or near-due; any later overwrite is bounded by `delta` and self-expires identically. State this reasoning in a comment.

**Discovery honors it.** Extend milestone 5's discovery statement:

```sql
SELECT workflow_id, workflow_name
FROM keiro_workflows
WHERE status NOT IN ('completed', 'cancelled', 'failed')
  AND (wake_after IS NULL OR wake_after <= $1)
```

The `UTCTime` parameter added in milestone 5 now does its job. Both the fixed-poll and push workers go through `resumeWorkflowsOnce` → this one query, so the push worker honors it with no further change (an unrelated store append no longer drags every sleeper through a replay).

*Tests.*

1. **Skipped while future, discovered after.** Arm a 60-second sleep (workflow suspends; instance row's `wake_after` set — read it directly to assert). `findUnfinishedWorkflowIds now` → not reported; `findUnfinishedWorkflowIds (addUTCTime 61 now)` → reported. Deterministic, no real waiting.
2. **No re-invocation while parked.** With a 60-second sleeper and its registry, run `resumeWorkflowsOnce` three times → `discovered = 0` each pass and the workflow's step counter unchanged (the body never re-entered). On pre-milestone code `discovered = 1` and the arm re-runs every pass.
3. **End-to-end unchanged.** Re-run milestone 1's "longer than the poll interval" loop test — still completes (the skip must never delay an actually-due sleeper beyond one pass).
4. **Missing-row degradation.** Simulate the arm racing ahead of instance-row creation by deleting the instance row, running an arm-bearing pass, and asserting nothing throws (the `UPDATE` no-ops) — then restore and proceed. (If plan 72's row maintenance makes this state unreachable, replace with a comment and drop the test; record in Surprises.)

*Acceptance.* `cabal test keiro` green; test 2 fails before the change.


### Milestone 7 — Low-severity hygiene (L1, L2, L3)

*Scope.* Three small, verified inefficiency/robustness fixes that touch code already in this plan's blast radius.

- **L1.** `journalEntryExists` (`Workflow.hs` 751–758): replace the non-terminating accumulate fold with `Streamly.fold (Fold.any (\recorded -> recorded ^. #eventId == entryId)) (readStreamForwardStream journalName (StreamVersion 0) 256)`. `Fold.any` is a terminating fold — the stream stops pulling pages at the first match. Add a comment: *once plan 67's kiroku event-id point lookup ships, this becomes a single SELECT; not gated on it.*
- **L2.** `Resume.hs` 228: replace `nub (unfinished <> runningChildren)` with `Set.toList (Set.fromList (unfinished <> runningChildren))` (`import Data.Set qualified as Set`; drop the `Data.List (nub)` import). Resume order is not contractual (it changes to sorted); the existing resume tests assert summaries and journals, not ordering — confirm none break.
- **L3.** In `Types.hs`, add (and export) additive smart constructors and an error type, mirroring `keiro-core`'s `category` (`keiro-core/src/Keiro/Stream.hs` 130–137):

```haskell
data WorkflowIdentityError
    = WorkflowNameEmpty
    | WorkflowNameInvalidChar !Char !Text
    | WorkflowIdEmpty
    | WorkflowIdInvalidChar !Char !Text
    deriving stock (Eq, Show, Generic)

-- | Validated constructor: rejects empty and the structural separators
-- ':' (stream prefix), '-' (name/id boundary), '#' (generation suffix).
-- Prefer camelCase compound names ("orderFulfillment"), matching the
-- keiro-core StreamCategory convention.
mkWorkflowName :: Text -> Either WorkflowIdentityError WorkflowName

-- | Validated constructor: rejects empty, ':' and '#'. '-' is permitted
-- (UUID ids) — with a hyphen-free name, the wf:<name>-<id> boundary is
-- the first '-', unambiguously.
mkWorkflowId :: Text -> Either WorkflowIdentityError WorkflowId
```

  Keep the raw constructors exported; extend their haddocks (and the `workflowStreamName` caveat at 94–99) to state plainly that *unvalidated names containing `-` can make two distinct `(name, id)` pairs share one journal stream* and to point at the smart constructors. Update the `Types.hs` line-64 example from `"order-fulfillment"` to `"orderFulfillment"`. Enforcement at `runWorkflowWith` is explicitly deferred (Decision Log). Pure tests: each rejection case; round-trip of valid inputs; `mkWorkflowId` accepts a UUID string.

*Acceptance.* `cabal build keiro` warning-clean; `cabal test keiro` green including the new pure examples.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro` (enter the dev shell first if the toolchain is not on PATH: `nix develop`).

Build and test loop used throughout:

```bash
cabal build keiro
cabal test keiro
```

Expected tail of a passing suite run (counts will grow as milestones land; the suite was ~136 examples after plan 48):

```text
Finished in ...s
1XX examples, 0 failures
```

Run one describe block while iterating (hspec match syntax):

```bash
cabal test keiro --test-options='--match "Keiro.Workflow.Sleep"'
```

Milestone 2 golden-value capture was completed before editing `Sleep.hs` / `Awakeable.hs`. The captured values now live in `keiro/test/Main.hs`:

```bash
cabal repl keiro
```

```haskell
ghci> import Keiro.Workflow.Sleep
ghci> import Keiro.Workflow.Awakeable
ghci> import Keiro.Workflow.Types
ghci> sleepTimerId (WorkflowName "wf") (WorkflowId "w-1") 0 "sleep:cool"
ghci> deterministicAwakeableId (WorkflowName "w") (WorkflowId "1") "approval"
```

Expected captured values:

```text
TimerId a95d5e7f-a43d-5ee2-9243-8206f0d8734a
AwakeableId ccaeaf74-3ffe-5ea5-a118-a3441a95c279
```

After adding any migration file (milestones 5 and 6):

```bash
touch keiro-migrations/src/Keiro/Migrations.hs   # or edit a comment; TH embedDir gotcha
cabal test keiro-migrations-test
cabal test keiro
```

Before starting milestone 5: confirm plan 72 has landed —

```bash
ls keiro-migrations/sql-migrations/ | grep -i workflow
grep -n "keiro_workflows" docs/plans/72-workflow-engine-failure-handling-instance-leasing-and-crash-window-atomicity.md | head
```

If the table's migration is absent or plan 72's Interfaces section is still skeleton text, stop milestones 5–6 and continue with 7.

Commit per milestone with conventional-commit messages, e.g.:

```text
fix(workflow): insert-only sleep arming so resume passes never postpone fire_at
fix(workflow): generation-namespaced wake-source ids; journaled random awakeable ids
fix(workflow): journal instance-start patch set; decide patch from it
fix(workflow): step returns JSON round-trip on first run; at-least-once docs
feat(workflow): discovery via keiro_workflows; gcWorkflows retention pruning
feat(workflow): wake_after resume skip for future sleepers
refactor(workflow): short-circuit journalEntryExists, Set dedup, identity smart constructors
```


## Validation and Acceptance

The plan is done when all of the following hold, each demonstrable by a command and an observation:

1. `cabal test keiro` and `cabal test keiro-migrations-test` are green from a clean checkout (`cabal clean` first if migrations changed).
2. **Sleep livelock closed:** the milestone 1 `fire_at`-equality test passes, and the end-to-end test shows a 1-second sleep completing under a 250 ms resume cadence. Reverting only the `scheduleTimerOnceTx` call-site switch makes both fail (spot-check once).
3. **Rolling poller works:** the milestone 2 rotation tests show a workflow doing sleep → `continueAsNew` → sleep across three generations to completion, an awakeable re-labeled across a rotation resolving with the new payload (never the old), and a re-spawned child id attaching with its recorded result.
4. **Forgery refused:** signalling the coordinate-derived UUID of a fresh awakeable returns `False` and resolves nothing; only the id the workflow handed out resolves it.
5. **Patch honesty:** both adverse-case tests pass — a fresh instance suspended before its patch call completes on the new branch; an in-flight instance whose journal holds only wake-source completions stays on the old branch — and decisions remain journaled exactly once per instance.
6. **Replay fidelity:** the lossy-codec test observes identical values on first run and replay; the undecodable-round-trip test observes `WorkflowStepDecodeError` on the first run with the step journaled.
7. **Scale (post-72):** discovery reads `keiro_workflows` (the old CTE statement is gone from `Schema.hs`); the GC test shows a completed workflow's entire footprint (journal streams across generations, step rows, awakeable rows, child links, terminal sleep timers, snapshot rows, instance row) deleted past retention and retained inside it; a 60-second sleeper produces `discovered = 0` resume passes until its fire time and completes on schedule afterwards.
8. **Docs tell the truth:** `Sleep.hs` no longer claims upsert re-arms are no-ops via `scheduleTimerTx`; `Workflow.hs` documents at-least-once side effects, the idempotency pattern, and the name-keyed-replay trade-off; `spawnChild`/`awakeableNamed` document attach semantics and per-generation promise freshness respectively.


## Idempotence and Recovery

Every implementation step is re-runnable. Code edits are plain-text and re-applicable; each milestone compiles and tests independently, so partial progress is always a working tree. The test fixture clones a fresh database per example (`withFreshStore`), so failed test runs leave no state.

Migrations are written with `IF NOT EXISTS` / `ADD COLUMN IF NOT EXISTS`, so re-applying against a database that already has them is safe; `cabal test keiro-migrations-test` verifies a fresh apply. If a migration file must be renamed (timestamp ordering against plan 72's), do it before it ever lands on a shared database; codd identifies migrations by filename.

Runtime idempotence is itself a deliverable and is argued per design: insert-only arming makes re-arms no-ops; the patch-set record goes through the duplicate-tolerant `appendJournalEntry`; the attach re-delivery uses the deterministic journal id; GC deletes dependents first and the instance row last so a crash mid-GC is healed by the next pass (proven by the milestone 5 idempotence test); `wake_after` is never cleared and self-expires, so there is no crash window to recover.

Riskiest change: GC's `hardDeleteStream` is irreversible. Safety comes from (1) the retention cutoff, (2) the terminal-status predicate, (3) the live-parent guard, and (4) GC being opt-in machinery (`gcWorkflowsOnce` / `runWorkflowGcWorker` are never started implicitly). If an operator needs a dry run, the eligibility statement is exposed by the summary's `scanned` count with `batchSize` honored — document running with `retention` set very high first.

If plan 72's final DDL differs from the assumed shape, only milestone 5/6 SQL changes; record the reconciliation in Surprises & Discoveries and adjust the statements — the Haskell surfaces (`findUnfinishedWorkflowIds`, `gcWorkflowsOnce`, `setWorkflowWakeAfterTx`) are shaped to survive column renames.


## Interfaces and Dependencies

**Packages and modules touched** (all in this repository unless noted):

- `keiro/src/Keiro/Timer/Schema.hs` — adds `scheduleTimerOnceTx :: TimerRequest -> Tx.Transaction ()` (+ statement). Arm path only; claim/requeue/mark statements are owned by `docs/plans/70-...` and must not be edited here.
- `keiro/src/Keiro/Workflow.hs` — `Workflow` effect gains `CurrentRunGeneration` and `currentRunGeneration :: (Workflow :> es) => Eff es Int`; `WorkflowRunOptions` gains `activePatches :: !(Set PatchId)`; the `Step` miss path returns the decoded round-trip; the `Patch` handler decides from the journaled patch set; `startedInFlight` / `isOrdinaryStepKey` deleted; `journalEntryExists` short-circuits.
- `keiro/src/Keiro/Workflow/Types.hs` — adds `patchSetStepName :: Text` (`"__workflow_patches__"`), `awakeableAllocStepPrefix :: Text` (`"awkid:"`), `WorkflowIdentityError`, `mkWorkflowName`, `mkWorkflowId`.
- `keiro/src/Keiro/Workflow/Sleep.hs` — `sleepTimerId :: WorkflowName -> WorkflowId -> Int -> Text -> TimerId` (generation ≥ 1 namespaced; 0 legacy); arm uses `scheduleTimerOnceTx` and (milestone 6) `setWorkflowWakeAfterTx`; docs corrected.
- `keiro/src/Keiro/Workflow/Awakeable.hs` — `awakeableNamed` gains `IOE :> es` and allocates a journaled random id with gen-0 legacy adoption; `deterministicAwakeableId` retained as documented-legacy.
- `keiro/src/Keiro/Workflow/Child.hs` — `awaitChild` gains `IOE :> es` and the attach-semantics arm; `spawnChild` docs. `Child/Schema.hs` unchanged (no key change — Decision Log).
- `keiro/src/Keiro/Workflow/Schema.hs` — `findUnfinishedWorkflowIds :: (Store :> es) => UTCTime -> Eff es [(Text, Text)]` over `keiro_workflows`; adds `setWorkflowWakeAfterTx :: WorkflowName -> WorkflowId -> UTCTime -> Tx.Transaction ()`.
- `keiro/src/Keiro/Workflow/Gc.hs` — **new**: `WorkflowGcPolicy`, `WorkflowGcSummary`, `gcWorkflowsOnce :: (IOE :> es, Store :> es) => UTCTime -> WorkflowGcPolicy -> Eff es WorkflowGcSummary`, `runWorkflowGcWorker`. Added to `keiro.cabal` exposed-modules.
- `keiro/src/Keiro/Workflow/Resume.hs` — passes `now` to discovery; `Set`-based dedup.
- `keiro/test/Main.hs` — all new tests; updated arities and the patch favorable-case option threading.
- `keiro-migrations/sql-migrations/` — two new files (GC index; `wake_after` column), timestamped after plan 72's instance-table migration.

**Consumed external interfaces:**

- kiroku (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`, located via `mori registry show kiroku --full`): `Kiroku.Store.Lifecycle.hardDeleteStream :: (HasCallStack, Store :> es) => StreamName -> Eff es (Maybe StreamId)` and `Kiroku.Store.Read.lookupStreamId` — both exist today; no upstream change required by this plan.
- `uuid` package: `Data.UUID.V4.nextRandom :: IO UUID` (already a transitive dependency via the existing `Data.UUID.V5` use; confirm it is in `keiro.cabal`'s build-depends — `uuid` is listed).
- `keiro-test-support`: `withMigratedSuite` / `withFreshStore` (`keiro-test-support/src/Keiro/Test/Postgres.hs` lines 74 / 99) — suite-level template database, per-example clones; never per-example migrations.
- `streamly-core`: `Streamly.Data.Fold.any :: Monad m => (a -> Bool) -> Fold m a Bool` (terminating fold) for L1.

**Sibling-plan interfaces (by file path, per the MasterPlan's Integration Points):**

- `docs/plans/72-workflow-engine-failure-handling-instance-leasing-and-crash-window-atomicity.md` — **defines** the `keiro_workflows` table (columns, status values, write discipline) in its Interfaces and Dependencies section; this plan **consumes** it in milestones 5–6 and **extends** it with the `wake_after` column and GC index via its own migrations. Hard dependency; reconcile step 5.0 is mandatory because plan 72 was an unauthored skeleton when this plan was written.
- `docs/plans/70-make-outbox-inbox-timer-and-shard-workers-crash-recoverable.md` — owns `keiro_timers` claim/requeue/mark. This plan adds only the insert-only arm statement and a GC delete restricted to terminal sleep rows; both are invisible to plan 70's recovery predicates (which key on `status = 'firing'` / `'scheduled'`). If plan 70 has landed first, rebase `Timer/Schema.hs` edits on its statements; if not, this plan's additions cannot conflict by construction.
- `docs/plans/67-fix-upstream-crash-safety-gaps-in-kiroku-shibuya-and-ephemeral-pg.md` — will add a kiroku event-id point lookup; noted as the future replacement for the L1 fold, not a dependency.

**Signatures that must exist at the end of each milestone** are listed inline in the milestone steps above; the externally visible additions are `scheduleTimerOnceTx`, `currentRunGeneration`, the widened `sleepTimerId`, the `IOE`-constrained `awakeableNamed`/`awaitChild`, `activePatches`, `patchSetStepName`, `awakeableAllocStepPrefix`, the `UTCTime`-taking `findUnfinishedWorkflowIds`, `setWorkflowWakeAfterTx`, the `Keiro.Workflow.Gc` module, and `mkWorkflowName`/`mkWorkflowId`/`WorkflowIdentityError`.

---

Revision note (2026-06-15): Milestone 1 was implemented and validated. The plan now records `scheduleTimerOnceTx`, the workflow sleep call-site switch, two regression tests for re-arm livelock, full `keiro` test evidence, and the fact that EP-4/EP-6 had landed before implementation.

Revision note (2026-06-15): Milestone 2 was implemented and validated. The plan now records generation-aware sleep ids, `currentRunGeneration`, journaled random awakeable ids with legacy adoption, child attach documentation/tests, golden UUID evidence, and full `keiro` validation.
