---
id: 72
slug: workflow-engine-failure-handling-instance-leasing-and-crash-window-atomicity
title: "Workflow engine failure handling, instance leasing, and crash-window atomicity"
kind: exec-plan
created_at: 2026-06-11T04:45:56Z
master_plan: "docs/masterplans/9-keiro-production-readiness-hardening.md"
---

# Workflow engine failure handling, instance leasing, and crash-window atomicity

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Keiro's durable workflow engine (the `keiro` package's `Keiro.Workflow*` modules) journals each named step of a long-running computation so a crashed or suspended workflow can be re-invoked and replayed without re-running completed side effects. A background "resume worker" discovers unfinished workflows and re-invokes them. The happy path works; the failure paths do not. Today, one workflow whose handler throws an exception permanently kills the entire resume worker — and because nothing ever marks that workflow as failed, the worker rediscovers it after every restart and crash-loops forever, stalling every workflow in the system. Two resume workers running at once (a normal multi-replica deploy) re-run side effects concurrently and then crash on the resulting duplicate journal append. And three external completion paths (signalling an awakeable, propagating a child's result to its parent, cancelling a child) commit their bookkeeping row in one transaction and append the corresponding journal entry in a second — a process crash between the two wedges the workflow permanently, in two of the three cases with no healing path at all.

After this plan is implemented, an operator can run multiple resume-worker replicas safely: a poison workflow is retried with backoff a bounded number of times, then marked terminally `failed` (visible in a new `keiro_workflows` instance table and as a `WorkflowFailed` journal marker) while every other workflow keeps making progress; a transient database blip is logged and retried, never killing the worker loop; per-instance leases ensure only one worker advances a given workflow instance at a time, and even a lease violation converges without duplicated effects or crashes; and every row-update-plus-journal-append pair commits atomically in one transaction, with crash-window tests that run the first statement alone and prove recovery heals the gap. The `keiro_workflows` table this plan introduces is also the foundation that docs/plans/73-workflow-sleep-generation-and-patch-semantics-plus-journal-scale-hygiene.md builds discovery and pruning on.

You can see it working by running the test suite (`cabal test keiro-test` from the repository root): new tests inject a poison workflow next to a healthy one and assert the healthy one completes while the poison one ends `failed` and drops out of discovery; simulate each crash window by running the row statement directly and skipping the journal append, then assert one resume pass heals it; and race two appenders for one step and assert both observe the single journaled value.


## Progress

- [x] M1: add migration `keiro-migrations/sql-migrations/2026-06-11-00-00-04-keiro-workflows-instances.sql` (table, indexes, backfill, children-status constraint widening) (completed 2026-06-15)
- [x] M1: create `keiro/src/Keiro/Workflow/Instance.hs` (`WorkflowStatus`, `WorkflowInstanceRow`, `upsertInstanceTx`, `markInstanceSuspended`, `lookupInstance`) and register it in `keiro/keiro.cabal` (completed 2026-06-15)
- [x] M1: wire `upsertInstanceTx` into the `appendJournalTx` continuation in `keiro/src/Keiro/Workflow.hs` (event-to-status mapping) (completed 2026-06-15)
- [x] M1: write the child's `keiro_workflows` row inside `spawnChild`'s register transaction in `keiro/src/Keiro/Workflow/Child.hs` (completed 2026-06-15)
- [x] M1: best-effort `suspended` status write on the `Suspended` outcome in `runWorkflowWith` (completed 2026-06-15)
- [x] M1: add `ChildFailed` to `ChildStatus` in `keiro/src/Keiro/Workflow/Child/Schema.hs` (constructor, `statusToText`/`statusFromText`) (completed 2026-06-15)
- [x] M1: instance-lifecycle tests in `keiro/test/Main.hs` (row appears on first step; flips to completed/cancelled; generation bumps on continue-as-new; terminal rows frozen) (completed 2026-06-15)
- [x] M2: add `Failed` to `WorkflowOutcome` in `keiro/src/Keiro/Workflow/Types.hs`; short-circuit on the `failed` marker in `runWorkflowWith`; update all `WorkflowOutcome` matches (completed 2026-06-15)
- [x] M2: add `__workflow_failed__` to the terminal set in `findUnfinishedWorkflowIdsStmt` in `keiro/src/Keiro/Workflow/Schema.hs` (completed 2026-06-15)
- [x] M2: add `recordCrashTx` / attempt bookkeeping statements to `Keiro.Workflow.Instance` (completed 2026-06-15)
- [x] M2: rework `WorkflowResumeOptions` (drop `useAdvisoryLock`; add `maxAttempts`, `leaseTtl`, `logEvent`) and add `ResumeLogEvent` (completed 2026-06-15)
- [x] M2: per-instance exception/transient classification in `resumeWorkflowsOnce` (`Error StoreError :> es` constraint on the worker functions; `catchError` innermost, sync-exception catch outermost) (completed 2026-06-15)
- [x] M2: terminal-failure marking (append `WorkflowFailed` once attempts reach `maxAttempts`; flip a child instance's `keiro_workflow_children` row to `failed`) (completed 2026-06-15)
- [x] M2: pass-level catch-and-continue in `runWorkflowResumeWorkerWith` and `runWorkflowResumeWorkerPush` (completed 2026-06-15)
- [x] M2: extend `ResumeSummary` (`failed`, `transientErrors`, `leaseSkipped`) and `KeiroMetrics` (`workflowFailed`, `workflowResumeErrors`, `workflowLeaseSkipped`) (completed 2026-06-15)
- [x] M2: tests — poison + healthy isolation, max-attempts terminal failure, transient store error survives, fixed-poll and push loop drivers survive a throwing pass (completed 2026-06-15)
- [ ] M3: lease claim/release statements in `Keiro.Workflow.Instance` (`claimInstance`, `releaseInstance`) and worker integration (claim before advance, release after)
- [ ] M3: rebuild the journal append as a single composable transaction (`prepareJournalAppend` builder: advisory xact lock, index existence check, in-transaction append via `appendToStreamTx`, `recordStepTx`, `upsertInstanceTx`); route `recordStep`, `appendCompletion`, `appendJournalEntry(ReturningId)`, and `rotateGeneration` through it; on an already-journaled step return the journaled value, not the locally computed one; delete the now-dead `journalEntryExists` scan
- [ ] M3: fix the `useAdvisoryLock` / "at most once" haddock lies in `keiro/src/Keiro/Workflow/Resume.hs`
- [ ] M3: tests — claim conflict, expired-lease takeover, attempt-reset on release, mid-flight duplicate-append race returns the journaled value
- [ ] M4: make `signalAwakeable` commit the row transition and the journal append in one transaction; add the `Completed`-row repair to `awaitCancellable`'s arm
- [ ] M4: make `childCompletionHook` commit `markChildResultTx` and the parent journal append in one transaction, branching on the child row's actual status (skip on cancelled — finding M3 part 2); add the `ChildCompleted`-row repair to `awaitChild`'s arm
- [ ] M4: crash-window tests — completed awakeable row without journal entry heals on resume; completed child row without parent entry heals on resume
- [ ] M5: make `cancelChild` atomic (row flip + child `WorkflowCancelled` marker + parent sentinel in one transaction) and make `runChildWorkflow` heal a cancelled-but-unmarked child
- [ ] M5: tagged child-result envelope (`{"ok": …}` / `{"cancelled": true}` / `{"failed": …}`) with legacy fallback decode; replace `awaitChild`'s partial `error` with `WorkflowStepDecodeError`; add `WorkflowChildFailed` and parent propagation of a failed child
- [ ] M5: re-check the cancellation marker on every step/await/patch miss in the `runWorkflowWith` handler (new internal `WorkflowCancelPending` unwind)
- [ ] M5: tests — crash-after-flip cancel heals, retried cancel appends, honest `{"cancelled": true}` child result is delivered not thrown, decode failure is typed, failed child wakes parent with `WorkflowChildFailed`, mid-run cancel stops remaining steps
- [ ] M6: haddock truth pass (`signalAwakeable`, `cancelChild`, `childCompletionHook`, `Awakeable.hs` and `Child.hs` "resume worker treats it as a failure" claims, module headers)
- [ ] M6: run `cabal build all`, `cabal test keiro-test`, `cabal test keiro-migrations-test`, `cabal test jitsurei-test`; fix any compile fallout (e.g. `WorkflowOutcome` matches in jitsurei)
- [ ] M6: tick the three EP-6 checkboxes in `docs/masterplans/9-keiro-production-readiness-hardening.md` and write the Outcomes & Retrospective entry here


## Surprises & Discoveries

- Research discovery (pre-implementation, 2026-06-10): the duplicate-event repair path that already exists in `appendJournalEntryReturningId` (`keiro/src/Keiro/Workflow.hs:649-657`, the `Left err -> racedIntoJournal …` branch) is unreachable for a real duplicate race. kiroku's transaction runner (`runTxOnPool`, `kiroku-store/src/Kiroku/Store/Effect.hs:335-348`) maps *every* `UsageError` — including the `events_pkey` 23505 unique violation that means "duplicate deterministic event id" — to `ConnectionError` and raises it through the `Error StoreError` *effect* (`throwError`), not through the `Either StoreError` that `runTransactionAppending` returns. The `Left` branch only ever carries semantic append conflicts (`WrongExpectedVersion` etc.). This refines audit finding H1 and motivates the advisory-lock append design in Milestone 3 (see Decision Log).
- Research discovery (2026-06-10): `findUnfinishedWorkflowIdsStmt` (`keiro/src/Keiro/Workflow/Schema.hs:198-218`) treats only `__workflow_completed__` and `__workflow_cancelled__` as terminal. Writing a `WorkflowFailed` journal marker alone would therefore *not* stop rediscovery — the failed workflow would be re-invoked forever. The fix must add `__workflow_failed__` to that SQL literal set (Milestone 2).
- Implementation discovery (2026-06-15): codd keys migration application by parsed timestamp, and the originally planned `2026-06-11-00-00-00-keiro-workflows-instances.sql` collided with the existing `2026-06-11-00-00-00-notify-trigger-append-guard.sql`. The migration was renamed to `2026-06-11-00-00-04-keiro-workflows-instances.sql`, after the existing 2026-06-11 migrations; the first filtered test run failed with `duplicate key value violates unique constraint "sql_migrations_migration_timestamp_key"`, and the rerun after renaming applied all migrations and passed 5 examples.
- Implementation discovery (2026-06-15): the worker can use effectful's built-in `catchSync` rather than a custom `SomeAsyncException` filter in `Eff`; local source under `/Users/shinzui/Keikaku/hub/haskell/effectful-project/effectful/effectful-core/src/Effectful/Exception.hs` confirms `catchSync` catches only synchronous exceptions. The push-aware `IO` loop still needs an explicit `SomeAsyncException` rethrow because it runs outside `Eff`.
- Implementation discovery (2026-06-15): the push-loop failure path can be tested without adding a test seam by temporarily renaming `keiro_workflow_steps` in a fresh test database. That makes the worker's first discovery pass return `Left StoreError` through `runStoreIO`; after restoring the table, the same worker drains a suspended workflow, proving the pass-level error was logged rather than fatal.


## Decision Log

- Decision: This plan does NOT depend on docs/plans/67-fix-upstream-crash-safety-gaps-in-kiroku-shibuya-and-ephemeral-pg.md. The duplicate-append race is closed *preemptively* with a transaction-scoped PostgreSQL advisory lock plus an in-transaction existence check, instead of *reactively* by classifying the error after the fact.
  Rationale: Today a duplicate caller-supplied event id inside `RunTransaction` surfaces as `ConnectionError` thrown through the `Error StoreError` effect (see Surprises & Discoveries), so a reactive repair would require either text-matching `ConnectionError` payloads (a liability the MasterPlan explicitly rejected) or waiting for plan 67's kiroku change that maps it to `DuplicateEvent`. Serializing same-step appends with `pg_advisory_xact_lock` inside the append transaction means the loser's existence re-check (run after the winner commits, visible under ReadCommitted) sees the row and skips the insert — no 23505 is ever raised, no error classification is needed, and the loser can read back and return the journaled value. Once plan 67 lands, kiroku's typed `DuplicateEvent` becomes available as an additional belt-and-braces, but nothing here requires it. The MasterPlan's dependency table (EP-6: no hard deps) stays correct.
  Date: 2026-06-10

- Decision: The per-instance lease is expiry-based lease columns (`leased_by`, `lease_expires_at`) on the new `keiro_workflows` table, claimed by a single guarded `UPDATE … WHERE lease free or expired` — not `FOR UPDATE SKIP LOCKED` row locks and not session advisory locks.
  Rationale: A resume re-invocation spans many transactions (one per step append), so any lock scoped to a transaction cannot cover a whole advance; and kiroku's `Store` is connection-pooled, so a session-scoped advisory lock has no connection affinity (exactly the analysis in the existing `useAdvisoryLock` haddock, `keiro/src/Keiro/Workflow/Resume.hs:139-152`). Time-boxed lease columns mirror how every production workflow engine solves this and reuse the shape `Keiro.Timer.Schema`'s claim established. The Milestone 3 append hardening makes even a lease violation (a worker outliving its TTL) converge safely, so the lease is a duplication *preventer*, not a correctness requirement.
  Date: 2026-06-10

- Decision: `keiro_workflows` rows are maintained inside the same transaction as the journal append they summarize (a new statement in `appendJournalTx`'s continuation, next to `recordStepTx`); only the advisory `suspended` status is written best-effort outside a journal transaction.
  Rationale: The MasterPlan integration point requires the instance table to be "written in the same transaction as the journal markers it summarizes" so plan 73 can trust it for discovery. Suspension appends no journal event, so its status write cannot ride a journal transaction; it is advisory only (a `running` row is equally discovery-eligible), so best-effort is sound.
  Date: 2026-06-10

- Decision: `WorkflowOutcome` gains a `Failed` constructor, `runWorkflowWith` short-circuits on the `__workflow_failed__` marker, and `__workflow_failed__` joins the discovery terminal set.
  Rationale: "Make `WorkflowFailed` real" has three halves: writing it, *not rediscovering* the instance (otherwise the crash loop continues, just slower), and not silently re-executing a terminally failed instance when a caller re-invokes it directly. The constructor is additive; exhaustive matches in this repository (and jitsurei) are updated in this plan.
  Date: 2026-06-10

- Decision: Uniform max-attempts policy for all workflow-level exceptions (including `WorkflowStepDecodeError`), with exponential backoff via a `next_attempt_at` column; transient `StoreError`s are classified separately and never count as attempts.
  Rationale: Even "deterministic" failures like a decode error can be fixed by deploying corrected code, so retrying with backoff until `maxAttempts` (default 5) is both simple and forgiving; special-casing exception types would add policy surface without removing the need for the terminal marker. Store errors are infrastructure weather, not workflow defects — counting them would fail healthy workflows during a database hiccup.
  Date: 2026-06-10

- Decision: A terminally failed child propagates to its parent: the child's `keiro_workflow_children` row flips to a new `failed` status, and a `{"failed": <reason>}` envelope is appended as the parent's await-step result, making `awaitChild` throw a new typed `WorkflowChildFailed`.
  Rationale: Without propagation, a failed child leaves its parent suspended forever — a fresh permanent-stall variant of exactly the class of bug this plan exists to remove. The `failed` child status keeps `findRunningChildIds` from re-driving the corpse, and the envelope (introduced for finding M4 anyway) carries the distinction to the parent so compensation code can tell "cancelled by me" from "died on its own".
  Date: 2026-06-10

- Decision: Child results are journaled in a tagged envelope — `{"ok": <result>}` for success, `{"cancelled": true}` for cancellation, `{"failed": <reason>}` for terminal failure — and `awaitChild` decodes with a legacy fallback (any value that is none of the three envelope shapes is decoded as a bare legacy result).
  Rationale: Fixes finding M4's forgeability (an honest child result equal to `{"cancelled": true}` currently makes the parent throw). The fallback keeps in-flight rows journaled before this change readable; the residual ambiguity (a *legacy* result that happens to be an object with an `"ok"`/`"cancelled"`/`"failed"` key) is confined to pre-existing rows and strictly smaller than today's bug.
  Date: 2026-06-10

- Decision: Add the `Error StoreError :> es` constraint to the resume-worker functions only (`resumeWorkflowsOnce`, `runWorkflowResumeWorkerWith`, `runWorkflowResumeWorker`); the core run path (`runWorkflowWith`, the journal append helpers) keeps `(IOE :> es, Store :> es)`.
  Rationale: The worker needs `catchError` to classify transient store failures separately from workflow crashes; every real interpretation of `Store` (`runStorePool`) already requires `Error StoreError` beneath it, so the constraint is satisfiable everywhere (the push worker's row is already concretely `'[Store, Error StoreError, IOE]`). The core path avoids the constraint entirely because the advisory-lock append design (first decision) removes its need to observe store errors.
  Date: 2026-06-10

- Decision: Remove the `useAdvisoryLock` field from `WorkflowResumeOptions` (replaced by `maxAttempts`, `leaseTtl`, `logEvent`).
  Rationale: It was documented as "reserved, setting it has no effect" and its haddock contains the false "each side effect run at most once" claim. Carrying a dead field alongside a real lease would be actively misleading. This is a breaking record change inside one initiative-owned options type; all construction sites are in this repository.
  Date: 2026-06-10


## Outcomes & Retrospective

Milestone 2 is complete as of 2026-06-15. The resume worker isolates poison workflows, records bounded attempts, appends a terminal `WorkflowFailed` marker, keeps healthy workflows moving in the same pass, classifies thrown `StoreError`s as transient without consuming attempts, and both fixed-poll and push loop drivers survive pass-level failures.


## Context and Orientation

This section is self-contained: it names every file, defines every term, and states every current-code fact this plan relies on (all verified 2026-06-10 against the working tree).

### The workflow engine in one page

A *durable workflow* is an ordinary Haskell computation (an `effectful` program) whose side effects run inside named checkpoints called *steps*. Running a workflow with `runWorkflowWith` (in `keiro/src/Keiro/Workflow.hs`) journals each step's JSON-encoded result as a `StepRecorded` event on a kiroku event stream named `wf:<name>-<id>` (generation 0) or `wf:<name>-<id>#<g>` (after a `continueAsNew` rotation; see `workflowGenerationStreamName` in `keiro/src/Keiro/Workflow/Types.hs`). Re-running the same workflow pre-loads that journal into a `Map Text Value` and *replays*: a step whose name is in the map returns the recorded value without re-running its action. The journal stream is mirrored, inside the same transaction as each append, into a SQL index table `keiro_workflow_steps` (`keiro/src/Keiro/Workflow/Schema.hs`, `recordStepTx`) used for fast existence checks and discovery.

A workflow can *suspend*: `awaitStep name arm` (the suspension primitive) returns the journaled result if present, otherwise runs the idempotent *arming* action (schedule a timer, register an awakeable row, register a child link) and unwinds the run with the internal `WorkflowSuspend` sentinel, making `runWorkflowWith` return `Suspended`. A *wake source* later appends a `StepRecorded` under the awaited name from outside the workflow — `signalAwakeable` (`keiro/src/Keiro/Workflow/Awakeable.hs`), the timer fire action (`keiro/src/Keiro/Workflow/Sleep.hs`), or `childCompletionHook` (`keiro/src/Keiro/Workflow/Child.hs`) — and the next run replays past the await.

The *resume worker* (`keiro/src/Keiro/Workflow/Resume.hs`) is what notices unfinished workflows. Each `resumeWorkflowsOnce` pass unions two discovery queries — `findUnfinishedWorkflowIds` (instances with step rows but no terminal marker row on their newest generation, `keiro/src/Keiro/Workflow/Schema.hs:198-218`) and `findRunningChildIds` (spawned children with no steps yet, `keiro/src/Keiro/Workflow/Child/Schema.hs`) — and re-invokes each through an application-supplied `WorkflowRegistry` (name → body). Two loop drivers exist: the fixed-poll `runWorkflowResumeWorkerWith` (`forever` + `threadDelay`, Resume.hs:291-293) and the push-aware `runWorkflowResumeWorkerPush` (Resume.hs:348-357), which runs each pass through `runStoreIO` and discards its `Either StoreError` result with `void`.

Terminal journal markers are reserved step names: `__workflow_completed__`, `__workflow_cancelled__`, `__workflow_failed__`, `__workflow_continued_as_new__` (`keiro/src/Keiro/Workflow/Types.hs`). The `WorkflowFailed` journal event, `failedStepName`, and its `journalRow`/`journalKey` plumbing all exist — but **nothing in the codebase ever writes them**; they are dead code today.

Two auxiliary tables support suspension: `keiro_awakeables` (one row per externally resolvable promise; `keiro/src/Keiro/Workflow/Awakeable/Schema.hs`) and `keiro_workflow_children` (one row per parent→child link, carrying the parent-journal step name the parent awaits; `keiro/src/Keiro/Workflow/Child/Schema.hs`). Migrations live in `keiro-migrations/sql-migrations/` as timestamped SQL files embedded via Template Haskell (`keiro-migrations/src/Keiro/Migrations.hs`).

### How journal appends and store errors actually flow

`recordStep` (Workflow.hs:609-612) calls `appendJournalTx` (Workflow.hs:727-734), which calls kiroku's `runTransactionAppending` with a continuation that runs `recordStepTx` (Workflow.hs:745-749) — one ACID transaction for "append event + upsert index row". Crucially, `runTransactionAppending`'s returned `Either StoreError` carries only *semantic append conflicts* (wrong expected version, etc.). Anything PostgreSQL raises as a server error inside the transaction — including the 23505 `events_pkey` unique violation that means "this deterministic event id already exists" — travels a different channel: kiroku's `runTxOnPool` (`kiroku-store/src/Kiroku/Store/Effect.hs:335-348`) maps every `UsageError` to `ConnectionError` and raises it with `throwError` through the `Error StoreError` *effect*. (Only kiroku's non-transactional append path maps 23505+`events_pkey` to the typed `DuplicateEvent` — see `mapUniqueViolation` at `kiroku-store/src/Kiroku/Store/Error.hs:160-166`; routing the transactional path through that mapper is docs/plans/67's job, which this plan deliberately does not wait for.) Consequences:

- `appendJournalTx` throws `WorkflowJournalAppendError` on any `Left` — but a real duplicate race never even produces a `Left`; it aborts the calling computation through the `Error StoreError` effect.
- The "raced into journal" repair in `appendJournalEntryReturningId` (Workflow.hs:649-657) is therefore unreachable for the race it was written for.
- A workflow code path constrained only by `(IOE :> es, Store :> es)` cannot catch this abort at all; catching it requires `Error StoreError :> es` (which every real stack has, because `runStorePool` installs `Store` above `Error StoreError`).

### The findings this plan fixes

**C1 (critical) — the resume worker has zero failure handling.** `resumeWorkflowsOnce` (Resume.hs:209-261) folds `advance` over discovered instances with no `try`/`catch` of any kind; `advance` calls `runWorkflowWith`/`runChildWorkflow` bare. Any exception — a user handler exception, `WorkflowStepDecodeError`, `WorkflowAwakeableCancelled`, `WorkflowChildCancelled` (the existing test at `keiro/test/Main.hs:3705-3709` proves re-invoking a parent of a cancelled child *throws*), `WorkflowJournalAppendError` — escapes the fold, escapes the `forever` loop (Resume.hs:291-293), and kills the worker. The failing workflow gets no terminal marker, so it is rediscovered after every restart: a permanent crash loop that stalls *all* workflow processing. The haddocks at Awakeable.hs:148 and Child.hs:139 claim "the resume worker treats it as a failure" — false today; this plan makes it true.

**H1 (high) — no lease, and the step miss path crashes on a duplicate append.** The `useAdvisoryLock` option (Resume.hs:139-152) is a documented no-op whose haddock falsely claims two racing workers converge "with each side effect run at most once". In truth two workers that both discover the same instance both re-run every un-journaled step's side effect (at-least-once is inherent — that documentation fix belongs to plan 73 — but here it is *unbounded* duplication), and then the loser of the journal append race aborts with `ConnectionError` as described above, feeding C1's crash loop. Unlike `appendJournalEntryReturningId`, the `Step`/`Patch`/`appendCompletion` paths have no repair attempt at all.

**H2 (high) — crash windows between row-completion and journal append wedge workflows.** (a) `signalAwakeable` (Awakeable.hs:240-268) commits `completeAwakeableTx` in one transaction, then appends the journal entry separately; a crash between leaves the row `completed` and the journal silent. Healing requires a *second* signal that may never come, and `awaitCancellable`'s arm (Awakeable.hs:203-215) checks only `Cancelled`, never repairing from a `Completed` row. (b) `childCompletionHook` (Child.hs:292-306) commits `markChildResultTx`, then appends to the parent journal separately; a crash between leaves the child terminal in `keiro_workflow_children` (so it drops out of `findRunningChildIds`) and complete in its own journal (so it drops out of `findUnfinishedWorkflowIds`), while the parent's awaited step is never journaled and its arm (Child.hs:200-207) checks only `ChildCancelled` — the parent is stuck forever with **no** healing path.

**H3 (high) — `cancelChild` is non-atomic and a retry does not repair.** Child.hs:232-251: the row flip (`markChildCancelledTx`) commits first; the child-journal `WorkflowCancelled` marker and the parent sentinel are separate appends guarded by `when cancelled`. A crash after the flip means a retry returns `False` and *skips both appends* (the haddock's "a retried cancel is safe" is false). Result: a zombie child keeps executing real side effects (its journal has no cancel marker) while the parent's hit path throws — feeding C1.

**M3 (medium) — cancellation observed only at run start.** `runWorkflowWith` checks `stepExists … cancelledStepName` once before the body (Workflow.hs:389-397); a long run started before the cancel executes every remaining step. Also `childCompletionHook` ignores `markChildResultTx`'s `False` (Child.hs:294-296), appending a result to the parent even when the child was concurrently cancelled.

**M4 (medium) — `awaitChild`'s decode failure calls partial `error`** (Child.hs:211-214), and the cancellation sentinel is forgeable: an honest child result equal to `{"cancelled": true}` (Child.hs:315-320) makes the parent throw `WorkflowChildCancelled`.

**M8 (medium) — the workers die on transient store errors.** The fixed-poll loop aborts on the first `throwError` from any discovery query (Resume.hs:291-293); the push variant swallows `Left`s silently via `void (runStoreIO …)` (Resume.hs:357) but still dies on IO exceptions.

### Sibling-plan boundaries

Owned by docs/plans/73-workflow-sleep-generation-and-patch-semantics-plus-journal-scale-hygiene.md and **out of scope here**: sleep re-arm semantics, generation-namespacing of wake-source ids, the `patch` mechanism's semantics, the switch of discovery queries to the `keiro_workflows` table, pruning, and the documentation of inherent at-least-once step side effects. This plan *defines and maintains* `keiro_workflows` (rows, statuses, leases, terminal failure) and continues to use the existing discovery queries; plan 73 consumes the table per the Interfaces and Dependencies section below. docs/plans/67-… (kiroku upstream) is referenced only as a future precision improvement (see Decision Log). The crash-window test pattern and the `KeiroMetrics` additive-field convention are shared with docs/plans/70-… and docs/plans/71-… per the MasterPlan's Integration Points.

### Terms used below

*Instance*: one logical workflow execution, identified by `(WorkflowName, WorkflowId)`. *Lease*: a time-boxed exclusive claim on an instance (`leased_by` + `lease_expires_at`); only the holder advances the instance, and an expired lease is claimable by anyone. *Crash window*: the gap between two database commits that a guarantee spans, where a process crash leaves visible partial state. *Poison workflow*: an instance whose re-invocation deterministically throws. *Advisory xact lock*: PostgreSQL `pg_advisory_xact_lock(key)`, an application-defined exclusive lock held until the surrounding transaction commits or rolls back — unrelated to the rejected *session* advisory lock idea, which would have had to span many transactions.


## Plan of Work

The work is six milestones. Each is independently verifiable with `cabal test keiro-test` (run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`); milestone-specific hspec match patterns are given in Validation and Acceptance. New SQL goes in `keiro-migrations/`. All workflow tests live in `keiro/test/Main.hs` and use the suite-level template-database fixture (`withMigratedSuite` / `withFreshStore` from `keiro-test-support/src/Keiro/Test/Postgres.hs`) — never per-example migrations.

### Milestone 1 — the `keiro_workflows` instance table and its lifecycle

Scope: create the table this whole plan (and plan 73) stands on, and keep it correct on every journal write. At the end, every workflow instance that has ever journaled anything has exactly one row carrying its name, id, current generation, and status, updated transactionally with the journal.

Add the migration `keiro-migrations/sql-migrations/2026-06-11-00-00-04-keiro-workflows-instances.sql` with the exact DDL recorded in Interfaces and Dependencies: the `keiro_workflows` table (primary key `(workflow_id, workflow_name)`; `generation`; `status` checked against `running|suspended|completed|cancelled|failed`; failure bookkeeping `attempts`/`last_error`/`next_attempt_at`; lease columns `leased_by`/`lease_expires_at`; timestamps), a partial index on active statuses, a backfill that derives one row per existing logical instance from `keiro_workflow_steps` (status from the newest generation's terminal markers) plus `running` rows for zero-step children from `keiro_workflow_children`, and a widening of `keiro_workflow_children`'s status check constraint to admit `failed` (used by Milestones 2 and 5). Start the file with `SET search_path TO kiroku, pg_catalog;` like `2026-06-05-00-00-00-keiro-workflow-generation.sql` does. Remember the build gotcha documented in `keiro/src/Keiro/Workflow.hs`'s module header: `embedDir` is a TH directory read, so after adding the SQL file touch a comment in `keiro-migrations/src/Keiro/Migrations.hs` (or `cabal clean`) so the embed re-runs.

Create `keiro/src/Keiro/Workflow/Instance.hs` (add it to `exposed-modules` in `keiro/keiro.cabal`), mirroring the `Keiro.Timer.Schema` style: a `WorkflowStatus` sum (`WfRunning | WfSuspended | WfCompleted | WfCancelled | WfFailed` with `statusToText`/`statusFromText`; decode fallback `WfFailed`, the conservative choice — an unknown status must never look resumable), a `WorkflowInstanceRow` record mirroring the columns, and for this milestone three operations: `upsertInstanceTx :: Text -> Text -> Int32 -> WorkflowStatus -> Maybe Text -> Tx.Transaction ()` (the maybe is `last_error`, set only for `WfFailed`), `markInstanceSuspended :: (Store :> es) => WorkflowName -> WorkflowId -> Eff es ()`, and `lookupInstance :: (Store :> es) => WorkflowName -> WorkflowId -> Eff es (Maybe WorkflowInstanceRow)`. The upsert is one statement: insert with the given status, `ON CONFLICT (workflow_id, workflow_name) DO UPDATE` setting `generation = GREATEST(old, new)`, the new status, `completed_at = now()` for terminal statuses, `updated_at = now()` — guarded by `WHERE keiro_workflows.status NOT IN ('completed','cancelled','failed')` so a terminal row is frozen (a late append from a zombie can never resurrect a finished instance).

Wire it in. In `keiro/src/Keiro/Workflow.hs`, extend `appendJournalTxResult`'s continuation (currently `appendResult <$ recordStepTx row`) to also run `upsertInstanceTx` with a status derived from the event: `StepRecorded → WfRunning`, `WorkflowCompleted → WfCompleted`, `WorkflowCancelled → WfCancelled`, `WorkflowFailed reason → WfFailed` (passing the reason as `last_error`), `WorkflowContinuedAsNew → WfRunning`. Because the rotation's seed-step append carries generation `g+1`, the `GREATEST` clause bumps the row's generation transactionally with the rotation. In `runWorkflowWith`, after the interpreted body returns `Suspended`, call `markInstanceSuspended` (an upsert too, with the same non-terminal guard, so a first-run instance that suspends before journaling anything still gets a row — required for plan 73's discovery). In `keiro/src/Keiro/Workflow/Child.hs`'s `spawnChild`, extend the `runTransaction` that runs `registerChildTx` to also `upsertInstanceTx` a `WfRunning` row for the *child*, so a spawned-but-never-driven child is in the table from birth. Finally add `ChildFailed` to `ChildStatus` in `keiro/src/Keiro/Workflow/Child/Schema.hs` (`statusToText` → `"failed"`, `statusFromText "failed"` → `ChildFailed`; keep the unknown-value fallback `ChildCancelled`) so the constraint widening has a Haskell mirror ready for Milestones 2 and 5 — nothing writes it yet.

What exists at the end: `cabal test keiro-test` and `cabal test keiro-migrations-test` pass; new tests under a `describe "Keiro.Workflow instance table"` block assert the lifecycle (see Validation and Acceptance).

### Milestone 2 — the resume worker survives anything; `WorkflowFailed` becomes real (C1, M8)

Scope: no exception thrown by one instance's advance may affect any other instance or the loop; bounded retries end in a real, discoverable terminal failure.

First the failure marker's three halves. In `keiro/src/Keiro/Workflow/Types.hs` add `Failed` to `WorkflowOutcome` (no payload; the reason is queryable from `keiro_workflows.last_error` and the journal marker's `reason` — keeping the constructor bare avoids threading a read into every short-circuit). In `keiro/src/Keiro/Workflow.hs` extend the run-start short-circuit (Workflow.hs:389-397) to also check `failedStepName` and return `Failed` (one extra indexed `stepExists`, or fold both markers into a single statement). In `keiro/src/Keiro/Workflow/Schema.hs` add `'__workflow_failed__'` to the `IN (…)` terminal set of `findUnfinishedWorkflowIdsStmt` and to the haddock above it. Update every `WorkflowOutcome` match: `bumpForOutcome` in Resume.hs (count `Failed` like `Cancelled`: re-invoked, neither completed nor suspended), `runChildWorkflow` in Child.hs (`Failed` propagates nothing), and any matches in `keiro/test/Main.hs` and `jitsurei/`.

Then the worker. Rework `WorkflowResumeOptions` in `keiro/src/Keiro/Workflow/Resume.hs`: delete `useAdvisoryLock` (see Decision Log); add `maxAttempts :: !Int` (default 5), `leaseTtl :: !NominalDiffTime` (default 60 — consumed in Milestone 3 but added now so the options type changes once), and `logEvent :: !(ResumeLogEvent -> IO ())` (default: render to stderr, preserving today's unknown-name line). Define

```haskell
data ResumeLogEvent
    = ResumeUnknownName !Text !Text
    | ResumeTransientError !Text !Text !Text          -- name, id, rendered StoreError
    | ResumeWorkflowCrashed !Text !Text !Int !Int !Text -- name, id, attempt, maxAttempts, rendered exception
    | ResumeWorkflowMarkedFailed !Text !Text !Text
    | ResumePassFailed !Text                           -- loop-driver level
```

Add `Error StoreError :> es` to the constraints of `resumeWorkflowsOnce`, `runWorkflowResumeWorkerWith`, and `runWorkflowResumeWorker` (every real stack satisfies it; the push worker's row is already concrete). Restructure `advance` so each instance is isolated:

```haskell
-- innermost: convert store-effect aborts into a value, so the outer
-- sync-exception catch can never misclassify them
attempt <-
    (AdvOk <$> driveInstance)
        `catchError` (\_ e -> pure (AdvTransient e))
        `catchSyncException` (\e -> pure (AdvCrashed e))
```

where `catchSyncException` is `Effectful.Exception.catch @SomeException` that re-throws anything matching `fromException @SomeAsyncException` (so worker cancellation still works). On `AdvOk`: reset the instance's failure bookkeeping (folded into Milestone 3's release; in this milestone, an `UPDATE … SET attempts = 0, last_error = NULL, next_attempt_at = NULL`). On `AdvTransient e`: log `ResumeTransientError`, bump a new `transientErrors` summary field and the `keiro.workflow.resume.errors` counter, and continue — no attempt is recorded. On `AdvCrashed e`: run a new `recordCrashTx` in `Keiro.Workflow.Instance` — `UPDATE keiro_workflows SET attempts = attempts + 1, last_error = $err, next_attempt_at = now() + make_interval(secs => LEAST(power(2, attempts + 1), 64)), updated_at = now() WHERE …` returning the new attempt count — log `ResumeWorkflowCrashed`, and if the count has reached `maxAttempts`, append the terminal marker with `appendJournalTx name wid gen (WorkflowFailed reason now)` (Milestone 1's continuation flips the instance row to `failed` in the same transaction), log `ResumeWorkflowMarkedFailed`, bump the `failed` summary field and the `keiro.workflow.failed` counter, and — if `lookupChild` shows this instance is some parent's child — flip its `keiro_workflow_children` row to the new `failed` status via a new `markChildFailedTx` (guarded `status = 'running'`, mirroring `markChildCancelledTx`) so `findRunningChildIds` stops re-seeding it. (The parent is *woken* by this in Milestone 5; until then it simply stays suspended, which is no worse than today.) The discovery skip: instances whose row has `next_attempt_at > now()` are not advanced this pass — implemented as a cheap per-instance check in this milestone and folded into the lease claim's `WHERE` in Milestone 3. Replace the inline `hPutStrLn` for unknown names with `logEvent (ResumeUnknownName …)`.

Harden both loop drivers (M8). Fixed-poll: wrap the pass in the same two-layer catch; on any failure log `ResumePassFailed` and sleep the poll interval (the interval itself is the backoff). Push: wrap `onePass` so a `Left` from `runStoreIO` is logged via `logEvent` instead of `void`-swallowed, and a synchronous IO exception is caught and logged — the `runPollLoopWith` loop then continues.

Extend `ResumeSummary` with `failed`, `transientErrors`, and `leaseSkipped :: Int` (zero until Milestone 3) and update `emptyResumeSummary`. Extend `KeiroMetrics` in `keiro/src/Keiro/Telemetry.hs` additively, following the existing dot-naming pattern: `workflowFailed` (`Counter Int64`, name `keiro.workflow.failed`, unit `{workflow}`), `workflowResumeErrors` (`keiro.workflow.resume.errors`, `{error}`), `workflowLeaseSkipped` (`keiro.workflow.lease.skipped`, `{workflow}`), each with a `record*` helper and construction in `newKeiroMetrics`.

### Milestone 3 — per-instance leasing and the atomic, race-proof journal append (H1)

Scope: two workers can run concurrently against one database without duplicating side effects in the steady state, and even a lease violation converges without an exception.

Leasing. In `Keiro.Workflow.Instance` add `claimInstance :: (IOE :> es, Store :> es) => Text -> NominalDiffTime -> WorkflowName -> WorkflowId -> Eff es Bool` and `releaseInstance :: (Store :> es) => Text -> Bool -> WorkflowName -> WorkflowId -> Eff es ()`. `claimInstance` runs one transaction: an ensure-row insert (`ON CONFLICT DO NOTHING`, status `running` — heals any instance predating the table) followed by the guarded claim recorded in Interfaces and Dependencies (`status IN ('running','suspended')`, lease absent or expired, `next_attempt_at` absent or due); `rowsAffected > 0` means claimed. `releaseInstance owner progressed` clears `leased_by`/`lease_expires_at` only `WHERE leased_by = $owner`, and when `progressed` also resets `attempts`/`last_error`/`next_attempt_at` (absorbing Milestone 2's interim reset). In `resumeWorkflowsOnce`, generate one fresh UUID *worker owner id* per pass, claim before each advance, skip (bumping `leaseSkipped` and `keiro.workflow.lease.skipped`) when the claim loses, and release in a `finally` so a crashed advance still releases (its `recordCrashTx` bookkeeping having already committed). A worker that dies mid-advance leaves its lease to expire after `leaseTtl` — the takeover path tests cover this. Direct `runWorkflowWith` callers (application code starting a workflow at a call site) intentionally do not take the lease; the append hardening below is what makes that safe.

The append hardening. Replace the core of the journal-append path in `keiro/src/Keiro/Workflow.hs` with a composable transaction builder:

```haskell
data JournalAppendOutcome
    = JournalAppended !AppendResult       -- this call wrote the entry
    | JournalAlreadyPresent !Aeson.Value  -- someone else did; here is the journaled value
    | JournalAppendConflict !AppendConflict

prepareJournalAppend ::
    (IOE :> es) =>
    WorkflowName -> WorkflowId -> Int -> WorkflowJournalEvent ->
    Eff es (Tx.Transaction JournalAppendOutcome)
```

The IO phase encodes the event (throwing `WorkflowJournalEncodeError` as today), sets the deterministic id from `deterministicJournalId`, runs `prepareEventsIO`, and captures `now`. The returned transaction body: (1) `SELECT pg_advisory_xact_lock(hashtextextended($key, 0))` where `$key` is `workflow_id || '/' || workflow_name || '/' || generation || '/' || step_name` — all same-step writers now serialize until commit; (2) re-check the index (`SELECT result FROM keiro_workflow_steps WHERE …` — under ReadCommitted this sees the winner's committed row even though our transaction started earlier); if present, return `JournalAlreadyPresent` with the stored value; (3) otherwise `appendToStreamTx` (kiroku's in-transaction single-stream append from `Kiroku.Store.Transaction`) with `AnyVersion`, then `recordStepTx` and `upsertInstanceTx` exactly as Milestone 1 wired them; a `Left` conflict condemns and returns `JournalAppendConflict`. Because the existence check is serialized behind the lock, the 23505 duplicate-id violation is unreachable from keiro code paths and no error classification is ever needed — this is what removes the plan-67 dependency (see Decision Log and Surprises & Discoveries).

Route everything through it: `recordStep` (the `Step` and `Patch` miss paths) runs the builder via `runTransaction`; on `JournalAlreadyPresent stored` it **decodes and returns the journaled value, not the locally computed one** (the handler must also overwrite its in-memory map with the stored value), so two racers observe one history; on `JournalAppendConflict` it throws `WorkflowJournalAppendError` as today. `appendCompletion`, `rotateGeneration`'s two appends, and `appendJournalEntryReturningId` become thin wrappers (the latter keeps its `stepExists` fast path, drops the now-redundant `journalEntryExists` stream scan and the unreachable `Left`-repair, and composes nothing else). The wake-source composition surface — `prepareJournalAppend` returning a `Tx.Transaction` that callers can sequence with their own row statements in *one* `runTransaction` — is exactly what Milestones 4 and 5 consume. Lock ordering note for reviewers and the haddock: a transaction composing several appends must take them in a stable order (Milestone 5's cancel takes child-marker before parent-sentinel; the completion hook takes only the parent step; no cycle exists).

Finally fix the lying documentation in `Resume.hs`: the module docs and the spot where `useAdvisoryLock` lived now describe the real lease (claim/expiry/skip) and state plainly that step side effects are at-least-once across crashes (pointing at plan 73's documentation milestone for the full treatment), with the *journal* being exactly-once.

### Milestone 4 — closing the signal and child-completion crash windows (H2, and finding M3's second half)

Scope: the two external completion paths each become one transaction, and both await arms learn to repair pre-existing wedged state.

`signalAwakeable` (`keiro/src/Keiro/Workflow/Awakeable.hs`): after the existing row lookup, resolve the owner's generation, build `prepareJournalAppend` for the `awk:<id>` `StepRecorded`, and run **one** transaction sequencing `completeAwakeableTx` and the append body. Branch on the looked-up status exactly as today (pending → transition + append, returning the transition's `Bool`; completed → re-run the same transaction, where `completeAwakeableTx` no-ops and the append heals from the stored payload if missing; cancelled/unknown → `False`, no append). The haddock's "crash between the row update and the journal append" paragraph is rewritten: that window no longer exists for new signals; the re-append branch remains as the healer for state wedged before this change.

`awaitCancellable`'s arm (same file): on the miss path, before the register, if `lookupAwakeable` returns a `Completed` row, append the journal entry from `row ^. #payload` via the builder and fall through to suspend — the *next* resume pass takes the hit path. This is the no-second-signal healing path the audit found missing.

`childCompletionHook` (`keiro/src/Keiro/Workflow/Child.hs`): look up the child row *first* and branch on its status (this also fixes finding M3's ignored `False`): `Running` → one transaction sequencing `markChildResultTx` and the parent-journal append of the enveloped result (envelope per Milestone 5; until that lands in the same PR series, the raw value — the milestones are implemented in order, so wire the envelope here if M5 is merged first, otherwise adjust in M5); `ChildCompleted` → re-run the append-only transaction (heal a wedged parent); `ChildCancelled`/`ChildFailed`/absent → do nothing (never fabricate a result for a resolved-by-cancellation child). `awaitChild`'s arm gains the symmetric repair: a `ChildCompleted` row with a stored result re-appends the parent entry and suspends; `ChildCancelled` keeps throwing as today.

The crash-window tests follow the MasterPlan's shared pattern — run the first statement directly via the schema module, skip the journal append, then exercise recovery — and are spelled out in Validation and Acceptance.

### Milestone 5 — atomic cancel, honest child results, and mid-run cancellation (H3, M4, M3 first half)

Scope: cancelling a child can no longer mint zombies; child results are unforgeable and decode failures are typed; a cancelled workflow stops at the next step boundary.

`cancelChild` becomes one transaction: look up the child row first; in a single `runTransaction`, run `markChildCancelledTx`, bind its `Bool`, and when it transitioned *or* the pre-read status was already `ChildCancelled` (the crash-after-flip legacy), sequence both append bodies — the `WorkflowCancelled` marker on the child journal, then the `{"cancelled": true}` sentinel on the parent's await step (stable lock order: child first). Deterministic ids keep it idempotent; the return value stays "did *this* call transition", but the haddock now truthfully says the markers are ensured whenever the row is cancelled, so a retry repairs. Belt-and-braces for the case where nobody retries: `runChildWorkflow` (which the resume worker selects for every child) checks the child row before driving and, on `ChildCancelled`, runs the same ensure-markers transaction and returns `Cancelled` — so the *next* resume pass after any historical wedge kills the zombie and wakes the parent.

The result envelope and typed errors (M4): `childCompletionHook` journals `{"ok": <result>}` (the `keiro_workflow_children.result` column keeps storing the raw value; the arm-repair and heal paths wrap when appending). `awaitChild` decodes the journaled value as: `{"cancelled": true}` → throw `WorkflowChildCancelled`; an object with a `"failed"` key → throw the new `WorkflowChildFailed name id reason` (declared next to `WorkflowChildCancelled`, with the same haddock contract); an object with an `"ok"` key → `fromJSON` the inner value; anything else → legacy fallback, `fromJSON` the raw value. A decode failure on any branch throws `WorkflowStepDecodeError (childResultStepName …) msg` instead of `error`. Milestone 2's child-failure marking now gains its second half: when the worker marks a child instance `failed`, it also appends `{"failed": <reason>}` to the parent's await step (one transaction with the `WorkflowFailed` journal append, via two sequenced builder bodies), so a failed child *wakes* its parent into `WorkflowChildFailed` — which the parent author catches for compensation, or which feeds the parent's own attempt counting. The Milestone 2 code is refactored to call this combined transaction.

Mid-run cancellation (M3 first half): in `runWorkflowWith`'s handler, on every miss path (`Step`, `Await`, and `Patch` before journaling), run `stepExists name wid gen cancelledStepName` (one indexed point query; hit paths — pure map lookups — stay query-free) and, when true, throw a new internal `WorkflowCancelPending` sentinel mirroring `WorkflowSuspend`; `interpreted` catches it and returns `Cancelled`. A cancel landing between the check and the action still lets that one action run — the inherent at-least-once boundary, noted in the haddock.

### Milestone 6 — documentation truth pass and full verification

Scope: every haddock that promised behavior the code now actually delivers (or never will) is reconciled, and the whole repository is green. Sweep the claims called out in the findings: `Resume.hs` module docs and options (done in M3 — verify), `Awakeable.hs:148` and `Child.hs:139` "the resume worker treats it as a failure" (now true — make the wording precise: attempts, backoff, terminal `failed`), `signalAwakeable`'s and `cancelChild`'s atomicity stories, `childCompletionHook`'s "self-heals on the next drive" (now true via the arm and status-branch repairs), and `Keiro.Workflow`'s module header contract recap (add the instance table and `Failed` outcome). Do not duplicate plan 73's at-least-once step documentation; reference it. Run the full set: `cabal build all`, `cabal test keiro-test`, `cabal test keiro-migrations-test`, `cabal test jitsurei-test` (jitsurei's registry and any `WorkflowOutcome` matches must compile against the new constructor and options fields). Tick the three EP-6 lines in the MasterPlan's Progress rollup and write this plan's Outcomes & Retrospective.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`.

Build and test cycle used throughout:

```bash
cabal build keiro                 # fast inner loop for the library
cabal test keiro-test             # the workflow suite (keiro/test/Main.hs, hspec)
cabal test keiro-migrations-test  # migration application checks
cabal build all && cabal test jitsurei-test   # full repo + example service (Milestone 6)
```

To run only the workflow-relevant specs while iterating (hspec `--match` selects by `describe`/`it` substring):

```bash
cabal test keiro-test --test-options='--match "Keiro.Workflow"'
cabal test keiro-test --test-options='--match "instance table"'
cabal test keiro-test --test-options='--match "Keiro.Workflow.Resume"'
```

After adding the migration file, force the Template Haskell embed to refresh (the `embedDir` gotcha documented in `keiro/src/Keiro/Workflow.hs`'s header):

```bash
touch keiro-migrations/src/Keiro/Migrations.hs   # or: edit a comment in it; or: cabal clean
cabal build keiro-migrations
```

A successful `cabal test keiro-test` run ends like:

```text
Finished in 312.4 seconds
640 examples, 0 failures
Test suite keiro-test: PASS
```

(the example count grows with this plan; what matters is `0 failures`).

Commit per milestone with conventional-commit messages on the current branch, e.g.:

```text
feat(keiro): add keiro_workflows instance table with transactional lifecycle (EP-6 M1)
feat(keiro): resume worker failure isolation, attempts, and terminal WorkflowFailed (EP-6 M2)
feat(keiro): per-instance leases and race-proof journal appends (EP-6 M3)
fix(keiro): make awakeable signal and child completion crash-atomic (EP-6 M4)
fix(keiro): atomic cancelChild, child-result envelope, mid-run cancellation (EP-6 M5)
docs(keiro): reconcile workflow haddocks with delivered failure semantics (EP-6 M6)
```

Milestone-by-milestone edit order (file paths; details in Plan of Work):

1. `keiro-migrations/sql-migrations/2026-06-11-00-00-04-keiro-workflows-instances.sql` (new) → `keiro/src/Keiro/Workflow/Instance.hs` (new) + `keiro/keiro.cabal` → `keiro/src/Keiro/Workflow.hs` (`appendJournalTxResult` continuation, `Suspended` write) → `keiro/src/Keiro/Workflow/Child.hs` (`spawnChild`) → `keiro/src/Keiro/Workflow/Child/Schema.hs` (`ChildFailed`) → tests.
2. `keiro/src/Keiro/Workflow/Types.hs` (`Failed`) → `keiro/src/Keiro/Workflow.hs` (short-circuit) → `keiro/src/Keiro/Workflow/Schema.hs` (terminal set) → `keiro/src/Keiro/Workflow/Instance.hs` (`recordCrashTx`, reset) → `keiro/src/Keiro/Workflow/Resume.hs` (options, classification, drivers) → `keiro/src/Keiro/Workflow/Child/Schema.hs` (`markChildFailedTx`) → `keiro/src/Keiro/Telemetry.hs` → tests.
3. `keiro/src/Keiro/Workflow/Instance.hs` (`claimInstance`/`releaseInstance`) → `keiro/src/Keiro/Workflow.hs` (`prepareJournalAppend`, rewire `recordStep`/`appendCompletion`/`appendJournalEntryReturningId`/`rotateGeneration`, delete `journalEntryExists`) → `keiro/src/Keiro/Workflow/Resume.hs` (claim/release, docs) → tests.
4. `keiro/src/Keiro/Workflow/Awakeable.hs` (`signalAwakeable`, `awaitCancellable`) → `keiro/src/Keiro/Workflow/Child.hs` (`childCompletionHook`, `awaitChild` arm) → crash-window tests.
5. `keiro/src/Keiro/Workflow/Child.hs` (`cancelChild`, `runChildWorkflow` heal, envelope, `WorkflowChildFailed`, decode) → `keiro/src/Keiro/Workflow/Resume.hs` (failed-child parent wake) → `keiro/src/Keiro/Workflow.hs` (`WorkflowCancelPending`, miss-path check) → tests.
6. Haddock sweep across the touched modules → full builds/tests → `docs/masterplans/9-keiro-production-readiness-hardening.md` rollup → this file's living sections.

If a step reveals a wrong assumption in this plan (a statement that does not behave as described, a constraint that does not hold), stop, correct the plan text, and record why in the Decision Log before continuing.


## Validation and Acceptance

Each milestone is accepted by behavior, not by code shape. All tests go in `keiro/test/Main.hs` under the existing `withMigratedSuite`/`withFreshStore` fixture, alongside the current `Keiro.Workflow*` describes; run them with the commands in Concrete Steps. The crash-window tests deliberately follow the MasterPlan's shared pattern: run the first statement of a two-statement guarantee directly via the schema module, skip the second, then assert recovery heals.

Milestone 1 — `describe "Keiro.Workflow instance table"`: running a two-step workflow to completion leaves exactly one `keiro_workflows` row with `status = 'completed'`, `generation = 0`, and a `completed_at`; a workflow that suspends on an awakeable has a row with `status = 'suspended'`; cancelling a child flips its row to `cancelled`; a `continueAsNew` rotation leaves one row with `generation = 1` and a non-terminal status; after a row is terminal, appending to the old journal directly (via `appendJournalEntry`) does not change its status (the frozen-terminal guard). `cabal test keiro-migrations-test` proves the migration applies cleanly; the backfill is additionally exercised by an in-suite test that inserts legacy-style step rows for an id with no instance row, deletes the instance row, runs a resume pass, and asserts the ensure-row insert (Milestone 3) or completion path recreates it.

Milestone 2 — `describe "Keiro.Workflow.Resume failure handling"`: (a) **poison isolation** — a registry with a healthy workflow and a poison one (its step throws a bespoke exception); repeated `resumeWorkflowsOnce` passes complete the healthy workflow (its journal carries `WorkflowCompleted`) while each pass returns a summary instead of throwing; (b) **terminal failure** — with `maxAttempts = 2` and `next_attempt_at` backoff bypassed by direct UPDATEs (or a 0-backoff test hook), after two crashing passes the poison instance's journal carries `WorkflowFailed` with the exception text, its `keiro_workflows` row reads `failed` with `attempts = 2`, and the *next* pass's `discovered` count no longer includes it (the new terminal-set literal at work); re-invoking it directly via `runWorkflowWith` returns `Failed` without executing any step (a counter proves it); (c) **transient classification** — a registry entry whose body runs `throwError (ConnectionError "boom")` is counted in `transientErrors`, records no attempt, and is retried next pass; (d) **loop survival** — `runWorkflowResumeWorkerWith` driven in a separate thread over the poison+healthy registry completes the healthy workflow within a bounded time and the thread is still alive; the push driver survives a pass whose `runStoreIO` returns `Left` (assert via the `logEvent` hook collecting events in an `IORef`).

Milestone 3 — `describe "Keiro.Workflow instance leases"` and additions to the resume describes: `claimInstance "a" …` returns `True` then `claimInstance "b" …` returns `False` while the lease is live; after a `releaseInstance "a"` (or an expiry simulated by `UPDATE keiro_workflows SET lease_expires_at = now() - interval '1 second'`), `"b"` claims successfully; a pass over an instance freshly claimed by a foreign owner skips it and bumps `leaseSkipped`. **Duplicate-race convergence**: a workflow whose step action *itself* appends that same step's journal entry (same deterministic id, value `X`) before returning a different value `Y` — simulating the other worker winning mid-flight — must observe the step result `X` (the journaled value), complete successfully, and leave exactly one `StepRecorded` for the step; before this milestone the same scenario aborts with a store error.

Milestone 4 — `describe "Keiro.Workflow crash windows"`: (a) **awakeable** — run the workflow to `Suspended`, then execute `runTransaction (completeAwakeableTx aid payload now)` directly (the crash: row completed, journal silent); assert the journal has no `awk:` entry; run one resume pass (arm repair appends) and a second (hit path); the workflow completes with the signalled payload, and a *new* `signalAwakeable` on a fresh awakeable leaves row + journal consistent even when inspected between no statements (it is one transaction — assert by checking that the journal entry and the `completed` row are both present immediately after the call, and add a transaction-composition unit test that condemns the continuation and asserts *neither* write is visible); (b) **child completion** — parent suspended on `awaitChild`; execute `runTransaction (markChildResultTx cid cname raw now)` directly (the crash: child row terminal, parent journal silent); assert the parent is absent from both discovery queries' *child* seed yet two resume passes complete the parent with the child's result (the `awaitChild` arm repair); (c) **concurrent cancel** — `childCompletionHook` on a row already `cancelled` appends nothing to the parent (finding M3 second half).

Milestone 5 — additions to `describe "Keiro.Workflow.Child"`: (a) **crash-after-flip cancel** — run `runTransaction (markChildCancelledTx cid cname)` directly, then either a retried `cancelChild` (returns `False`) or a single resume pass; in both cases the child journal gains `WorkflowCancelled` (a subsequent drive returns `Cancelled` and runs no step) and the parent's await step carries the sentinel (re-invoking the parent throws `WorkflowChildCancelled`); (b) **honest sentinel** — a child whose result is literally the JSON object `{"cancelled": true}` completes, and the parent *receives* that value (no throw) because it travels as `{"ok": {"cancelled": true}}`; (c) **typed decode** — a parent awaiting `Text` from a child that returned a number gets `WorkflowStepDecodeError`, not an `ErrorCall`; (d) **failed child wakes parent** — a poison child driven past `maxAttempts` leaves the child row `failed` and the parent's next re-invocation throws `WorkflowChildFailed` carrying the reason; (e) **mid-run cancel** — a three-step workflow whose second step appends `WorkflowCancelled` to its own journal returns `Cancelled` from that same run and never executes step three (an `IORef` counter proves it).

Milestone 6 — `cabal build all` and all three test suites pass; `grep -rn "at most once" keiro/src/Keiro/Workflow*` returns no surviving false claim; the MasterPlan rollup shows the three EP-6 items checked.


## Idempotence and Recovery

The migration is re-runnable by construction (`CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, backfill via `INSERT … ON CONFLICT DO NOTHING`; the children-constraint widening uses `DROP CONSTRAINT IF EXISTS` + `ADD CONSTRAINT`), and codd applies each migration exactly once anyway. It is purely additive: no existing table loses a column, and generation-0 behavior is untouched, so rolling back the Haskell changes while leaving the table in place is safe (the table simply goes stale; the backfill-on-demand ensure-row in `claimInstance` and the upserts repair it on re-deploy).

Every new write path is idempotent by the same mechanisms the engine already uses: deterministic v5 event ids, `ON CONFLICT DO NOTHING` index upserts, status-guarded transitions, and the advisory-lock existence re-check. Re-running any milestone's code against a database produced by a partial earlier run converges (that is what the crash-window tests prove). The lease is self-recovering: a worker that dies mid-advance leaves a lease that expires after `leaseTtl` with no operator action.

Implementation checkpoints are the milestones — each leaves `cabal test keiro-test` green and is committed separately, so recovery from a bad step is `git revert` of one commit. If the Milestone 3 rewiring of `recordStep` misbehaves, the prior `runTransactionAppending`-based path is one commit back and the table/worker changes (M1/M2) stand alone without it.

Test runs are idempotent: each example clones a fresh database from the suite template (`withFreshStore`), so no example can poison another.


## Interfaces and Dependencies

This section is the contract surface other plans read. docs/plans/73-workflow-sleep-generation-and-patch-semantics-plus-journal-scale-hygiene.md consumes the table below verbatim for its discovery switch and pruning; if anything here changes during implementation, update this section and notify that plan via the MasterPlan.

### The `keiro_workflows` table (defined here, consumed by plan 73)

One row per logical workflow instance. Exact DDL (file `keiro-migrations/sql-migrations/2026-06-11-00-00-04-keiro-workflows-instances.sql`):

```sql
SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS keiro_workflows (
  workflow_id      TEXT        NOT NULL,
  workflow_name    TEXT        NOT NULL,
  generation       INTEGER     NOT NULL DEFAULT 0,
  status           TEXT        NOT NULL DEFAULT 'running',
  attempts         INTEGER     NOT NULL DEFAULT 0,
  last_error       TEXT,
  next_attempt_at  TIMESTAMPTZ,
  leased_by        TEXT,
  lease_expires_at TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at     TIMESTAMPTZ,
  PRIMARY KEY (workflow_id, workflow_name),
  CONSTRAINT keiro_workflows_status_chk
    CHECK (status IN ('running', 'suspended', 'completed', 'cancelled', 'failed'))
);

CREATE INDEX IF NOT EXISTS keiro_workflows_active_idx
  ON keiro_workflows (status)
  WHERE status IN ('running', 'suspended');
```

followed by the backfill (one row per existing logical instance from `keiro_workflow_steps`, status derived from the newest generation's terminal-marker rows — `'completed'` / `'cancelled'` / `'failed'` / else `'running'` — plus `'running'` rows for `keiro_workflow_children.status = 'running'` ids; both `ON CONFLICT DO NOTHING`) and the children-constraint widening:

```sql
ALTER TABLE keiro_workflow_children DROP CONSTRAINT IF EXISTS keiro_workflow_children_status_chk;
ALTER TABLE keiro_workflow_children ADD CONSTRAINT keiro_workflow_children_status_chk
  CHECK (status IN ('running', 'completed', 'cancelled', 'failed'));
```

Status semantics (plan 73's discovery contract): **non-terminal** = `running` (advancing or claimable) and `suspended` (advisory refinement of running; both are resume-eligible — discovery must select `status IN ('running','suspended')` and respect `next_attempt_at`); **terminal** = `completed`, `cancelled`, `failed` (frozen by the upsert guard; prune candidates for plan 73). `generation` is the current (highest) generation, bumped transactionally by the rotation's seed-step append. Row maintenance: every journal append's transaction upserts the row (event→status: `StepRecorded`→`running`, `WorkflowCompleted`→`completed`, `WorkflowCancelled`→`cancelled`, `WorkflowFailed`→`failed` + `last_error`, `WorkflowContinuedAsNew`→`running`); `spawnChild` inserts the child's row in its register transaction; suspension writes `suspended` best-effort; the lease claim's ensure-row insert heals any missing row on demand. This plan does **not** change the discovery queries beyond adding `'__workflow_failed__'` to `findUnfinishedWorkflowIdsStmt`'s terminal set — the switch to reading `keiro_workflows` is plan 73's.

### The lease (mechanism of record)

Expiry-based lease columns claimed by one guarded statement (no `FOR UPDATE SKIP LOCKED` hold, no session advisory locks — see Decision Log):

```sql
UPDATE keiro_workflows
SET leased_by = $3, lease_expires_at = now() + $4, updated_at = now()
WHERE workflow_id = $1 AND workflow_name = $2
  AND status IN ('running', 'suspended')
  AND (lease_expires_at IS NULL OR lease_expires_at < now())
  AND (next_attempt_at  IS NULL OR next_attempt_at  <= now())
```

`rowsAffected > 0` = claimed. Release clears the lease only `WHERE leased_by = $owner` and resets `attempts`/`last_error`/`next_attempt_at` when the advance made progress. Owner ids are fresh UUIDs per worker pass; `leaseTtl` (default 60 s) bounds how long a dead worker stalls one instance.

### Haskell surface added or changed (end state, full module paths)

- `Keiro.Workflow.Instance` (new): `WorkflowStatus(..)`, `WorkflowInstanceRow(..)`, `upsertInstanceTx :: Text -> Text -> Int32 -> WorkflowStatus -> Maybe Text -> Tx.Transaction ()`, `markInstanceSuspended`, `lookupInstance`, `claimInstance :: (IOE :> es, Store :> es) => Text -> NominalDiffTime -> WorkflowName -> WorkflowId -> Eff es Bool`, `releaseInstance :: (Store :> es) => Text -> Bool -> WorkflowName -> WorkflowId -> Eff es ()`, `recordCrashTx`.
- `Keiro.Workflow.Types`: `WorkflowOutcome` gains `Failed`.
- `Keiro.Workflow`: `prepareJournalAppend :: (IOE :> es) => WorkflowName -> WorkflowId -> Int -> WorkflowJournalEvent -> Eff es (Tx.Transaction JournalAppendOutcome)` with `JournalAppendOutcome(..)` (the wake-source composition seam); `journalEntryExists` removed; run-start short-circuit covers `failed`.
- `Keiro.Workflow.Resume`: `WorkflowResumeOptions` loses `useAdvisoryLock`, gains `maxAttempts :: Int` (default 5), `leaseTtl :: NominalDiffTime` (default 60), `logEvent :: ResumeLogEvent -> IO ()`; `ResumeLogEvent(..)` (new); `ResumeSummary` gains `failed`, `transientErrors`, `leaseSkipped`; `resumeWorkflowsOnce` / `runWorkflowResumeWorkerWith` / `runWorkflowResumeWorker` gain an `Error StoreError :> es` constraint.
- `Keiro.Workflow.Child`: `WorkflowChildFailed` (new exception); child results journaled as `{"ok": …}` / `{"cancelled": true}` / `{"failed": <reason>}` with legacy raw fallback on read; `awaitChild` decode failures throw `WorkflowStepDecodeError`.
- `Keiro.Workflow.Child.Schema`: `ChildStatus` gains `ChildFailed`; `markChildFailedTx` (new).
- `Keiro.Telemetry`: `KeiroMetrics` gains `workflowFailed`, `workflowResumeErrors`, `workflowLeaseSkipped` (counters `keiro.workflow.failed`, `keiro.workflow.resume.errors`, `keiro.workflow.lease.skipped`) with `record*` helpers — additive, following the existing naming pattern per the MasterPlan integration point.

### External dependencies and the plan-67 question

kiroku (read at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`) is used as-is: `runTransaction`, `runTransactionAppending`, `appendToStreamTx`, `prepareEventsIO` (`kiroku-store/src/Kiroku/Store/Transaction.hs`). **No hard dependency on docs/plans/67-fix-upstream-crash-safety-gaps-in-kiroku-shibuya-and-ephemeral-pg.md**: the advisory-lock append design makes the duplicate-id 23505 unreachable from keiro paths, so this plan never needs kiroku's transactional error mapping fixed (today `runTxOnPool` maps it to `ConnectionError` via `throwError`; see Surprises & Discoveries). When plan 67 lands, an optional follow-up may narrow the worker's transient classification to treat `DuplicateEvent` distinctly — noted here so the MasterPlan's "EP-6: no hard deps" row stays accurate. PostgreSQL ≥ 13 is assumed for `hashtextextended` and `make_interval` (the repo targets PostgreSQL 18+ per `Keiro.Workflow.Schema`'s comments). Test infrastructure: `keiro-test-support` (`withMigratedSuite`, `withFreshStore`); hspec; the existing `SimulatedCrash` helper pattern in `keiro/test/Main.hs`.


---

Revision note (2026-06-15): Milestone 1 was implemented and the migration filename was corrected from `2026-06-11-00-00-00-keiro-workflows-instances.sql` to `2026-06-11-00-00-04-keiro-workflows-instances.sql` because codd rejected the original timestamp as a duplicate of an existing migration. The progress checklist, plan-of-work references, and interface contract now name the actual migration file.

Revision note (2026-06-15): Initial Milestone 2 implementation made `Failed` a real outcome, failed markers drop out of discovery, extended resume options/logging/summary/metrics, separated per-instance store errors from synchronous workflow exceptions, appended terminal `WorkflowFailed`, and made fixed/push loop drivers log pass-level failures. At that checkpoint, explicit loop-driver survival tests still remained.

Revision note (2026-06-15): Milestone 2 is now complete. Added fixed-poll and push loop-driver survival tests; validation passed with `cabal test keiro-test --test-options='--match "Keiro.Workflow.Resume"'` (8 examples, 0 failures), `cabal test keiro-test --test-options='--match "Keiro.Workflow push latency"'` (2 examples, 0 failures), and full `cabal test keiro-test` (225 examples, 0 failures).
