---
id: 53
slug: audit-release-blocking-runtime-idempotency
title: "Audit release-blocking runtime idempotency"
kind: exec-plan
created_at: 2026-06-05T15:16:49Z
---

# Audit release-blocking runtime idempotency

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan records the first-release runtime audit work for Keiro's durability and idempotency paths. After the work is complete, workflow wake completions, process-manager timer reactions, and outbox publishing order should behave consistently under retries, stale derived indexes, and repeated worker passes. A maintainer can see the behavior working by running the focused regression tests named in this plan and the full `cabal test all` suite from the repository root.

The work matters because Keiro promises at-least-once worker delivery with deterministic write identifiers. "At least once" means a worker may see the same input more than once after a crash, retry, or rebalance. "Deterministic write identifier" means the same logical write uses the same event id or row id on every retry, so duplicate delivery can be recognized instead of creating a second effect. A first release should not report success for work that was not durably written, and should not fail a benign retry that the public API describes as idempotent.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-06-05: Audited workflow external journal append idempotency and committed `efaafde fix(workflow): make external journal appends idempotent`.
- [x] 2026-06-05: Added a workflow regression test that deletes the derived step index row, re-appends the same deterministic journal event, and verifies the index is repaired rather than failing as a duplicate.
- [x] 2026-06-05: Ran `cabal build all`, `KEIRO_MIGRATE_NO_CHECK=1 cabal test all`, and a focused workflow regression test before committing the workflow fix.
- [x] 2026-06-05: Audited process-manager timer scheduling and found that no-op manager commands skipped the `runCommandWithSql` callback, so timer-only reactions were reported as scheduled without writing timer rows.
- [x] 2026-06-05: Patched `keiro/src/Keiro/ProcessManager.hs` so no-op manager commands schedule action timers explicitly in a SQL transaction.
- [x] 2026-06-05: Added a process-manager regression test and a no-op counter transducer fixture in `keiro/test/Main.hs`; the focused `ProcessManager` test group passes.
- [x] 2026-06-05: Audited outbox claim ordering and found `UPDATE ... RETURNING` did not guarantee the ordered CTE's row order, and equal `created_at` values could bypass head-of-line blocking.
- [x] 2026-06-05: Finished and validated the outbox claim-order patch in `keiro/src/Keiro/Outbox/Schema.hs`; `KEIRO_MIGRATE_NO_CHECK=1 cabal test keiro:keiro-test --test-options="--match=Outbox"` passed with 14 examples and 0 failures.
- [x] 2026-06-05: Ran `nix fmt`; treefmt processed the repo and reported `formatted 3 files (0 changed)`.
- [x] 2026-06-05: Ran focused outbox tests, `cabal build all`, and `KEIRO_MIGRATE_NO_CHECK=1 cabal test all`; all exited successfully.
- [x] 2026-06-05: Committed the process-manager/outbox audit fixes as `0b35a17 fix(runtime): harden idempotent release paths` with an `ExecPlan: docs/plans/53-audit-release-blocking-runtime-idempotency.md` trailer.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The workflow journal append helpers had documentation saying duplicate deterministic journal events should be idempotent, but the implementation trusted the derived `keiro_workflow_steps` table as the only pre-check. If that index row was missing while the physical journal stream still contained the event, a duplicate append could surface as `WorkflowJournalAppendError`. The committed fix checks the journal stream as the source of truth and repairs the derived index.

- Kiroku's event store documents that caller-supplied duplicate event ids normally surface as `DuplicateEvent`; the workflow fix still checks the physical stream after an append failure because a stale index or racing completion should converge to success when the event exists. The relevant dependency files read during the audit were `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Transaction.hs`, `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Append.hs`, and `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Error.hs`.

- `runCommandWithSql` only invokes its SQL callback when events are appended. A process-manager action with a manager command that emits no events and `timers = [...]` therefore returned `timersScheduled = 1` while no row existed in `keiro_timers`. The focused regression test now verifies `countDueTimers dueTimerTime == 1` for that scenario.

- The outbox claim query selected rows with `ORDER BY r.created_at`, but then used `UPDATE ... RETURNING`. PostgreSQL does not promise that `RETURNING` rows preserve the order of a source CTE. The policy predicates also used only `earlier.created_at < r.created_at`, so rows created at the same timestamp could be treated as unordered. The in-progress patch adds `outbox_id` as a deterministic tie-breaker and orders the final selected rows after the update.


## Decision Log

Record every decision made while working on the plan.

- Decision: Use the physical workflow journal stream as the source of truth when deciding whether an external workflow step was already recorded.
  Rationale: The derived `keiro_workflow_steps` table is an index maintained for fast lookup. If it is stale or absent, retrying a deterministic append should repair it rather than fail a workflow wake completion.
  Date: 2026-06-05

- Decision: For process-manager timer-only reactions, schedule timers in a separate `runTransaction` only when `runCommandWithSql` returns `Nothing` for the callback result.
  Rationale: A `Nothing` callback result means the manager command was a no-op and no append transaction existed to host `scheduleTimerTx`. The timer insert itself is idempotent by `timer_id`, so this preserves retry safety while making the reported `timersScheduled` count truthful.
  Date: 2026-06-05

- Decision: Keep existing append-path timer scheduling unchanged.
  Rationale: When the manager command appends events, timers should remain in the same transaction as the manager-state append so a crash cannot split state advancement from timer creation.
  Date: 2026-06-05

- Decision: Make outbox ordering deterministic with `(created_at, outbox_id)` and explicitly order the rows returned after claiming.
  Rationale: Ordered publishing policies need a total order. `created_at` alone is not total, and `UPDATE ... RETURNING` order is not an interface guarantee.
  Date: 2026-06-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

The workflow audit milestone is complete and committed. It produced a code change, a regression test, and passing build/test evidence. The process-manager timer-only milestone is complete and committed. The outbox claim-order milestone is complete and committed. All validation commands in this plan have passed.

The main gap at this point is that this ExecPlan was created after some changes were already made. The earlier commits `43ba027`, `efaafde`, and `c379705` therefore do not carry an ExecPlan trailer. Future commits for this plan must include:

```text
ExecPlan: docs/plans/53-audit-release-blocking-runtime-idempotency.md
```


## Context and Orientation

Describe the current state relevant to this task as if the reader knows nothing. Name the
key files and modules by full path. Define any non-obvious term you will use. Do not refer
to prior plans unless they are checked into the repository, in which case reference them by
path.

The repository root is `/Users/shinzui/Keikaku/bokuno/keiro`. The main library package is `keiro`, with production Haskell modules under `keiro/src/Keiro` and integration-style tests under `keiro/test/Main.hs`. Database migrations live in `keiro-migrations/sql-migrations`.

The workflow runtime is implemented in `keiro/src/Keiro/Workflow.hs` and supporting modules under `keiro/src/Keiro/Workflow`. A workflow is a durable computation: it records completed named steps in an event stream so a resumed run can skip already-finished work. The table `keiro_workflow_steps` is a derived index of those journal events, not the authoritative journal itself.

The process manager is implemented in `keiro/src/Keiro/ProcessManager.hs`. A process manager reacts to an input event by advancing its own state stream, dispatching target commands, and scheduling durable timers. A timer is a row in `keiro_timers` that a worker can later claim and fire. The `scheduleTimerTx` function from `keiro/src/Keiro/Timer/Schema.hs` writes those timer rows inside a SQL transaction.

The outbox is implemented in `keiro/src/Keiro/Outbox.hs` and `keiro/src/Keiro/Outbox/Schema.hs`. An outbox row is a durable request to publish an integration event to a transport such as Kafka. `claimOutboxBatch` selects rows that are ready to publish, marks them `publishing`, and returns them to the publisher worker. Ordered policies such as `PerKeyHeadOfLine`, `PerSourceStream`, and `StopTheLine` depend on returning rows in a deterministic order.

The test file `keiro/test/Main.hs` contains shared fixtures for counter commands, process managers, timers, workflows, and outbox behavior. New regression tests should stay near the existing `describe "Keiro.ProcessManager"` and `describe "Keiro.Outbox"` groups unless they require a new section.


## Plan of Work

Describe, in prose, the sequence of edits and additions. For each edit, name the file and
location (function, module) and what to insert or change. Keep it concrete and minimal.

Break into milestones if the work spans multiple independent phases. Each milestone must be
independently verifiable. Introduce each milestone with a brief paragraph: scope, what will
exist at the end, commands to run, acceptance criteria.

Milestone 1, already completed, repaired workflow journal append idempotency. In `keiro/src/Keiro/Workflow.hs`, `appendJournalEntryReturningId` now computes the deterministic journal event id and stream name, checks the physical journal stream when the derived step index is missing, repairs the step index with `recordStepTx`, and repeats that source-of-truth check after append failure to handle concurrent duplicate completion. The regression test in `keiro/test/Main.hs` deletes the derived `keiro_workflow_steps` row and confirms the second append returns the same event id, restores the index, and leaves only one physical journal event.

Milestone 2, currently implemented but uncommitted, fixes process-manager timer-only reactions. In `keiro/src/Keiro/ProcessManager.hs`, keep the current `runCommandWithSql` callback for the append path. When the result is `Right (managerResult, Nothing)`, run `runTransaction (traverse_ scheduleTimerTx timers)` before finishing. In `keiro/test/Main.hs`, add `noOpCounterEventStream`, `noOpCounterTransducer`, and `timerOnlyProcessManager`, then add a test that verifies a manager command with zero appended events still schedules one due timer.

Milestone 3, currently in progress, fixes outbox claim ordering. In `keiro/src/Keiro/Outbox/Schema.hs`, change the policy predicates to compare `(created_at, outbox_id)` so equal timestamps still have a stable predecessor. Change `claimSql` so `ready` carries `claim_created_at`, the `UPDATE` joins through `ready`, and the final result selects from an `updated` CTE ordered by `claim_created_at, outbox_id`. Add or update a focused outbox test if validation reveals the existing tests do not exercise the ordering guarantee.

Milestone 4 validates and commits the current audit fixes. Run the focused process-manager and outbox tests first, then `cabal build all`, then `KEIRO_MIGRATE_NO_CHECK=1 cabal test all`. Run formatting before commit if the tree is not already formatted. Commit only the files belonging to this plan and leave unrelated worktree changes, especially the pre-existing `Justfile` modification, unstaged.


## Concrete Steps

State the exact commands to run and where to run them (working directory). When a command
generates output, show a short expected transcript so the reader can compare. This section
must be updated as work proceeds.

All commands run from `/Users/shinzui/Keikaku/bokuno/keiro`.

Inspect the repository and declared dependencies before changing code:

```bash
mori show --full
mori registry show shinzui/kiroku --full
```

The expected `mori show --full` output identifies this repository as `shinzui/keiro` and lists dependencies including `shinzui/kiroku`, `shinzui/keiki`, `shinzui/shibuya`, `hasql/hasql`, and `effectful/effectful`.

Run the focused process-manager tests after editing `keiro/src/Keiro/ProcessManager.hs` and `keiro/test/Main.hs`:

```bash
KEIRO_MIGRATE_NO_CHECK=1 cabal test keiro:keiro-test --test-options="--match=ProcessManager"
```

The focused run has already passed once with this summary:

```text
Keiro.ProcessManager
  advances manager state, emits a deterministic target command once, and schedules a timer [✔]
  schedules timers when the manager command emits no events [✔]
  treats duplicate input delivery as idempotent state and command dispatch [✔]
  keeps multiple workflow process managers isolated by configured streams and categories [✔]
Keiro.ProcessManager snapshots
  writes a snapshot of the manager state stream after the policy threshold [✔]
  hydrates the manager from its snapshot and replays only the tail [✔]

6 examples, 0 failures
```

Run focused outbox tests after editing `keiro/src/Keiro/Outbox/Schema.hs`:

```bash
KEIRO_MIGRATE_NO_CHECK=1 cabal test keiro:keiro-test --test-options="--match=Outbox"
```

This has passed once after the outbox SQL patch with:

```text
Keiro.Outbox
  enqueues and looks up an outbox row [✔]
  claims a pending row, transitions it to publishing, and increments attempt count [✔]
  marks a claimed row as sent with published_at set [✔]
  publishClaimedOutbox marks success and records failures with last_error [✔]
  auto-dead-letters a row after maxAttempts consecutive failures [✔]
  enforces per-key head-of-line blocking and unblocks once the predecessor reaches a terminal state [✔]
  allows null-keyed rows to publish independently [✔]

14 examples, 0 failures
```

Run the full verification sequence before committing:

```bash
cabal build all
KEIRO_MIGRATE_NO_CHECK=1 cabal test all
```

The test suite prints noisy codd schema-diff diagnostics while creating the test database template on this local setup. Treat the Cabal exit code and final test-suite summaries as the acceptance signal.

This full verification has passed once after the process-manager and outbox patches:

```text
cabal build all
exit code 0

KEIRO_MIGRATE_NO_CHECK=1 cabal test all
...
Test suite jitsurei-test: PASS
16 examples, 0 failures
Test suite keiro-test: PASS
152 examples, 0 failures
exit code 0
```


## Validation and Acceptance

Describe how to exercise the system and what to observe. Phrase acceptance as behavior with
specific inputs and outputs. If tests are involved, name the exact test commands and expected
results. Show that the change is effective beyond compilation.

Workflow acceptance is already satisfied by the committed regression: if a deterministic external workflow journal event exists in the physical journal stream but its derived `keiro_workflow_steps` row is missing, a second call to `appendJournalEntryReturningId` returns the existing event id, repairs the index row, and does not append a duplicate event.

Process-manager acceptance is satisfied when the test named `schedules timers when the manager command emits no events` passes. The test creates a process manager whose manager command uses a transducer with `output = []`. After `runProcessManagerOnce`, it expects the manager result to report `StreamVersion 0` and `eventsAppended = 0`, the command result list to be empty, `timersScheduled = 1`, `countDueTimers dueTimerTime` to return `1`, and `claimDueTimer dueTimerTime` to return a row with `processManagerName = "timer-only-pm"`.

Outbox acceptance is satisfied when focused outbox tests pass and ordered claim behavior remains deterministic. For `PerKeyHeadOfLine`, a row with the same `(source, message_key)` and earlier `(created_at, outbox_id)` must block later non-terminal rows. For `PerSourceStream`, any earlier non-terminal row in the same source must block later rows. `claimOutboxBatch` must return claimed rows ordered by `(created_at, outbox_id)` after marking them `publishing`.

Full release-audit acceptance requires:

```text
cabal build all
```

to exit successfully, and:

```text
KEIRO_MIGRATE_NO_CHECK=1 cabal test all
```

to exit successfully with all Cabal test suites passing.

As of 2026-06-05, both commands have exited successfully for this working tree.


## Idempotence and Recovery

If steps can be repeated safely, say so. If a step is risky, provide a safe retry or
rollback path.

The code changes are additive or local replacements and can be retried by re-running the same tests. `scheduleTimerTx` is idempotent on `timer_id`: scheduling the same timer again updates a still-scheduled row and does not resurrect fired or cancelled rows. The process-manager no-op timer branch is therefore safe under repeated delivery.

The workflow journal repair path is idempotent because `recordStepTx` uses an upsert that does nothing for an existing `(workflow_id, workflow_name, generation, step_name)` row. Re-running the external completion returns the same deterministic event id when the journal event is already present.

The outbox claim query uses `FOR UPDATE SKIP LOCKED`, so concurrent claimers should not claim the same row. The ordering patch does not make destructive data changes outside the ordinary status transition from `pending` or `failed` to `publishing`.

Do not revert unrelated worktree changes. At the time this plan was created, `git status --short` included an unrelated modified `Justfile`; leave it unstaged unless the user explicitly asks to include it.


## Interfaces and Dependencies

Name the libraries, modules, and services to use and why. Specify the types, interfaces, and
function signatures that must exist at the end of each milestone. Use full module paths.

This work depends on the current repository's registered Mori metadata. Use `mori show --full` from the repo root before relying on dependency APIs, and use `mori registry show shinzui/kiroku --full` to locate the Kiroku source tree. Do not search `/` or `/nix/store`.

The workflow milestone uses `Kiroku.Store.Read.readStreamForwardStream` to scan the physical stream and `Kiroku.Store.Transaction.runTransaction` to repair the derived workflow-step row. The public functions remain:

```haskell
appendJournalEntry :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> WorkflowJournalEvent -> Eff es ()
appendJournalEntryReturningId :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> WorkflowJournalEvent -> Eff es EventId
```

The process-manager milestone keeps the public `runProcessManagerOnce` signature unchanged:

```haskell
runProcessManagerOnce ::
    RunCommandOptions ->
    ProcessManager input phi rs s ci co targetPhi targetRs targetState targetCi targetCo ->
    RecordedEvent ->
    input ->
    Eff es (Either CommandError (ProcessManagerResult (EventStream phi rs s ci co) (EventStream targetPhi targetRs targetState targetCi targetCo)))
```

The implementation imports `Kiroku.Store.Transaction.runTransaction` and uses existing `Keiro.Timer.scheduleTimerTx`.

The outbox milestone keeps the public `claimOutboxBatch` interface unchanged:

```haskell
claimOutboxBatch ::
    (Store :> es) =>
    OrderingPolicy ->
    Int ->
    UTCTime ->
    Eff es [OutboxRow]
```

The SQL in `keiro/src/Keiro/Outbox/Schema.hs` must continue to decode rows with `outboxRowDecoder` and return the same `OutboxRow` fields as before.

## Revision Notes

2026-06-05: Created this ExecPlan after the release audit had already produced workflow and process-manager changes. The plan documents those major changes retroactively, records the in-progress outbox ordering patch, and establishes the validation and commit requirements for the remaining work.

2026-06-05: Updated progress and validation after focused outbox tests, formatting, `cabal build all`, and `KEIRO_MIGRATE_NO_CHECK=1 cabal test all` all completed successfully.

2026-06-05: Updated progress after committing `0b35a17 fix(runtime): harden idempotent release paths` with the required ExecPlan trailer.
