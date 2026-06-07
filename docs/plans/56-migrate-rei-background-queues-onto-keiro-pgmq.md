---
id: 56
slug: migrate-rei-background-queues-onto-keiro-pgmq
title: "Migrate rei background queues onto keiro-pgmq"
kind: exec-plan
created_at: 2026-06-07T17:25:21Z
intention: "intention_01kthhpasxesx8hp84264cjhpx"
master_plan: "docs/masterplans/7-keiro-pgmq-reusable-postgres-job-queue.md"
---

# Migrate rei background queues onto keiro-pgmq

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The `rei` application runs four PostgreSQL-backed background-job queues for work that is a
side effect, not a domain event: committing a workspace to git, firing due reminders,
scheduling recurring reflections, and checking agent schedules. Today each queue duplicates
the same hand-written plumbing against `pgmq-effectful` and `shibuya-pgmq-adapter`: a
producer wrapping `sendMessage`, a queue-name enum, a handler of type
`Ingested es Value -> Eff es AckDecision` that decodes JSON and maps domain errors to ack
decisions, and adapter wiring in one worker runner.

This plan replaces that boilerplate with the `keiro-pgmq` package's typed `Job` abstraction
(built by `docs/plans/55-build-the-keiro-pgmq-package-with-typed-job-and-runtime-layers.md`,
which is a hard prerequisite). After this plan, each rei queue is a `Job p` declaration plus
a domain handler of type `p -> Eff es JobOutcome` (`JobOutcome = Done | Retry delay | Dead
reason`); producers call `enqueue`; the worker runner builds processors with `jobProcessor`
and runs them with `runJobWorkers`. The observable win: rei's queue modules shrink
substantially, no longer mention shibuya's `Ingested`/`AckDecision` or PGMQ's `SendMessage`,
and rei depends on `keiro-pgmq` instead of wiring the two lower libraries by hand — while
every background-work behavior stays identical.

This migration is the proving ground for the package's **continuous, multi-processor**
cadence: rei runs all four queues at once under one supervisor, with enqueues driven by
periodic `pg_cron` sweeps.


## Progress

- [x] Milestone 1: Add the `keiro-pgmq` pin to rei and confirm it resolves. (2026-06-07 — rei
  commit `7516fe61`; `cabal build rei-core` builds `keiro-pgmq-0.1.0.0` cleanly.)
- [x] Milestone 2: Port the workspace git-sync queue as the template (one queue, end to end).
  (2026-06-07 — handler now `NoteGitSyncPayload -> Eff es JobOutcome`, producer uses
  `enqueueWithDelay gitSyncJob`, both runners use `jobProcessor gitSyncJob`; dead legacy
  git-sync code removed; `cabal build rei-core rei-cli` + git-sync handler test pass.)
- [x] Milestone 3: Port reminders, reflections, and agent-work queues; rewire the runner.
  (2026-06-07 — rei commit `88b366ce`; three Job declarations + `payload -> JobOutcome`
  handlers + `enqueue`-based producers; runner now uses `runJobWorkers` over four
  `jobProcessor` actions; `cabal build` + full 932-test suite pass.)
- [x] Milestone 4: Delete the now-dead hand-rolled plumbing; verify parity end to end.
  (2026-06-07 — rei commit `6f179474`; legacy git-sync code already removed in M2, runner no
  longer constructs adapters, unused `shibuya-pgmq-adapter` direct dep dropped from rei-cli.
  Grep confirms no `pgmqAdapter`/`mkProcessor`/`SendMessage`/`AckDecision`/`Ingested` in any
  migrated queue module.)


## Surprises & Discoveries

- 2026-06-07 (M1) — **rei capped shibuya at `^>=0.6` but keiro-pgmq requires `>=0.7`.** The
  pin was not a trivial add: keiro-pgmq needs `shibuya-* >=0.7 && <0.8` and
  `pgmq-* >=0.3 && <0.4`, while rei's `rei-core`/`rei-cli` pinned `shibuya-core ^>=0.6`
  (< 0.7) and `shibuya-pgmq-adapter ^>=0.6`. The user upgraded rei's whole eventing stack
  first (rei commits `f26c6a7e`, `df1f4a86`, rei-side "ExecPlan 122"): shibuya-core 0.7,
  shibuya-pgmq-adapter 0.7, shibuya-kiroku-adapter 0.3 (taken from the kiroku git pin because
  Hackage only carries 0.2), and bumped the keiro pin to `cb252e2` (which contains
  keiro-pgmq) + keiki to `bc987f4`. After that, adding `keiro-pgmq` to the keiro
  `source-repository-package` subdir list and to `build-depends` resolved cleanly. **This is
  the cross-repo precondition EP-3 should expect too** — keiro-runtime-jitsurei must already
  be on shibuya 0.7 before pinning keiro-pgmq.

- 2026-06-07 (M2) — **The pre-migration adapters had NO dead-letter queue and 3 retries.**
  shibuya's `defaultConfig` sets `deadLetterConfig = Nothing` and `maxRetries = 3`. rei's
  runner built every queue with `defaultConfig`, so for parity the shared `reiQueuePolicy`
  uses `useDeadLetter = False, maxRetries = 3` (NOT keiro-pgmq's `defaultRetryPolicy`, which
  is 5 retries + DLQ). EP-3 (hospital-capacity) genuinely uses a DLQ, so it will differ here.

- 2026-06-07 (M2) — **The live git-sync producer is a transactional projection, not the
  `enqueue` producer.** `enqueueNoteGitSync` (in `Rei/Workspace/Queue/Producer.hs`) has no
  callers anywhere in the rei tree. The real enqueue path is
  `Rei/Modules/Note/Projection/GitSyncEnqueueProjection.hs`, which builds the
  `NoteGitSyncPayload` JSON and calls `pgmq.send` via a **raw Hasql `Statement` in the same
  transaction** as a `note_git_sync_enqueue_dedup` claim insert, for exactly-once enqueue.
  keiro-pgmq's `enqueue` uses the `Pgmq` effect in a separate transaction and therefore
  CANNOT replace this without losing the transactional exactly-once guarantee — so the
  migration deliberately covers only the consumer side (handler + runner) for git-sync and
  leaves the projection's transactional enqueue untouched. The wire JSON is unchanged
  (same `NoteGitSyncPayload` `ToJSON`), so the migrated consumer (`aesonJobCodec`) decodes it
  identically. The same pattern likely holds for the other queues' enqueue side (the periodic
  `pg_cron`/projection paths), so M3 will likewise migrate only the consumer side.


## Decision Log

- Decision: Port the workspace git-sync queue first as a complete template before the others.
  Rationale: Git sync is the most distinctive (it carries a content-hash dedup), so proving
  it end to end de-risks the mechanical ports of the three near-identical periodic queues.
  Date: 2026-06-07

- Decision: Keep rei's existing payload types and their `ToJSON`/`FromJSON` instances; use
  `aesonJobCodec` rather than `keiroJobCodec`.
  Rationale: Drop-in behavioral parity is the goal of this migration; adopting versioned
  `keiroJobCodec` is a separate, optional follow-up.
  Date: 2026-06-07

- Decision: All four rei queues share one `reiQueuePolicy = RetryPolicy { maxRetries = 3,
  defaultRetryDelay = RetryDelay 60, useDeadLetter = False }`, NOT keiro-pgmq's
  `defaultRetryPolicy`.
  Rationale: rei's pre-migration runner built every adapter with shibuya's
  `defaultConfig`, whose defaults are `maxRetries = 3` and `deadLetterConfig = Nothing` (no
  DLQ). keiro-pgmq's `defaultRetryPolicy` differs (5 retries, DLQ on). To preserve exact
  behaviour the shared policy reproduces `defaultConfig`. `reiQueuePolicy` and a
  `reiQueueRef :: ReiQueue -> QueueRef` helper live in `Rei/Workspace/Queue/Types.hs`, the
  existing central queue registry, so `reiQueueName` stays the single source of name strings.
  Date: 2026-06-07

- Decision: Remove the dead legacy git-sync code (`WorkspaceGitSyncPayload`,
  `enqueueWorkspaceGitSync`, `gitSyncHandler`, `processLegacyGitSync`) during Milestone 2
  rather than Milestone 4.
  Rationale: It is verified-dead (no callers anywhere in the rei tree) and lives in the exact
  three files Milestone 2 rewrites. Leaving it would keep `SendMessage`/`AckDecision` imports
  in files the migration is supposed to clean, so removing it now keeps each commit coherent.
  Date: 2026-06-07

- Decision: Do not call `ensureJobQueue` at worker startup.
  Rationale: rei already creates every queue via SQL migrations under
  `rei-core/migrations/scripts/` (`pgmq.create('workspace_git_sync')` etc.), and the policy
  disables the DLQ, so there is nothing extra to create. Skipping it keeps startup side
  effects identical to today. (It is idempotent, so adding it later is harmless.)
  Date: 2026-06-07


## Outcomes & Retrospective

Completed 2026-06-07. All four rei background queues (workspace git-sync, reminder trigger,
reflection scheduler, agent work) now run through `keiro-pgmq`'s typed `Job` API. Each queue
is a `Job p` declaration plus a `p -> Eff es JobOutcome` handler; the worker runner builds all
four processors with `jobProcessor` and supervises them with `runJobWorkers IgnoreFailures
100`. rei no longer wires `shibuya-pgmq-adapter` by hand — its only direct uses of that
package are gone, and the direct dep was dropped from `rei-cli`. Behaviour is preserved: the
shared `reiQueuePolicy` reproduces the old shibuya `defaultConfig` (3 retries, no DLQ), the
wire JSON is unchanged, and the full 932-test rei-core suite (including the git-sync handler
integration test) passes.

What went differently from the plan:

- **The pin was not free.** rei capped shibuya at `<0.7` but keiro-pgmq needs `>=0.7`, so the
  whole eventing stack had to be upgraded first (done by the user: rei commits `f26c6a7e` /
  `df1f4a86`). Milestone 1's "just add the pin" assumed version compatibility that did not hold.

- **The producer side was mostly not the `enqueue` path.** The real git-sync and agent-task
  enqueues are transactional raw-SQL projections (`GitSyncEnqueueProjection`,
  `AgentTaskEnqueueProjection`) for exactly-once delivery, which keiro-pgmq's `enqueue`
  (separate `Pgmq`-effect transaction) cannot replace. The migration therefore centres on the
  consumer side (handlers + runner), which is where the shibuya `Ingested`/`AckDecision`
  coupling actually lived. The periodic reminder/reflection/agent-check producers (which DO
  use the `Pgmq` effect) were migrated to `enqueue`.

- **No DLQ today.** The pre-migration adapters used `defaultConfig` (no dead-letter queue, 3
  retries), so parity required a custom `reiQueuePolicy` rather than keiro-pgmq's
  DLQ-enabled `defaultRetryPolicy`. Adopting versioned `keiroJobCodec` and a real DLQ are
  available follow-ups, deliberately out of scope for this behaviour-preserving migration.

Cross-plan note for EP-3 (hospital-capacity): expect the same shibuya-0.7 precondition, and
note that hospital-capacity genuinely uses a DLQ, so it will use a DLQ-enabled policy (unlike
rei) and the one-shot `runJobOnce` cadence rather than `runJobWorkers`.

Net result: each queue module shrank to a `Job` + domain handler, the per-queue
adapter/`mkProcessor`/`runApp` boilerplate is gone, and rei depends on `keiro-pgmq` instead of
hand-wiring `pgmq-effectful` + `shibuya-pgmq-adapter`.


## Context and Orientation

You are migrating the `rei` application at `/Users/shinzui/Keikaku/bokuno/rei-project/rei`.
It is a separate repository from keiro. The `keiro-pgmq` package this plan depends on lives
in the keiro repository at `/Users/shinzui/Keikaku/bokuno/keiro/keiro-pgmq` and must already
be built and committed (see `docs/plans/55-...` in the keiro repo). Its public API — the
contract you will program against — is reproduced in "Interfaces and Dependencies" below so
you do not need the keiro repo open.

rei's relevant code (all under `rei-core/src/Rei/` unless noted), discovered by reading the
current tree:

- Queue-name registry: `Rei/Workspace/Queue/Types.hs` defines
  `data ReiQueue = WorkspaceGitSyncQueue | ReminderTriggerQueue | ReflectionSchedulerQueue |
  AgentWorkQueue` and `reiQueueName :: ReiQueue -> QueueName` mapping each to a PGMQ name.
- Producers (each ~10–15 lines wrapping `sendMessage`):
  - `Rei/Workspace/Queue/` (git sync producer; payload `NoteGitSyncPayload` with a
    `contentHash :: Maybe Text` for dedup).
  - `Rei/Modules/AgentSchedule/Queue/Producer.hs` —
    `enqueueScheduleCheck :: (Pgmq :> es, IOE :> es) => ScheduleSource -> Eff es ()`; payload
    `AgentWorkPayload = ScheduleCheckMsg ... | AgentTaskMsg ...`.
  - `Rei/Modules/Reminder/Queue/Trigger/Producer.hs` — `enqueueReminderTrigger`; payload
    `ReminderTriggerPayload`.
  - `Rei/Modules/Reflection/Queue/Scheduler/Producer.hs` — `enqueueReflectionScheduler`;
    payload `ReflectionSchedulerPayload`.
- Handlers (each ~30–50 lines; all of type `... -> Ingested es Value -> Eff es AckDecision`):
  - `Rei/Workspace/Queue/GitSyncHandler.hs` — `noteGitSyncHandler`; compares
    `payload.contentHash` to the note's current hash to skip stale updates; processes
    add/update/delete; returns `AckOk` / `AckRetry (RetryDelay 60)` / `AckDeadLetter
    (InvalidPayload ...)`.
  - `Rei/Modules/Reminder/Queue/Trigger/Handler.hs` — `reminderTriggerHandler`; on disabled
    config returns `AckOk`; on domain error returns `AckRetry (RetryDelay 60)`; logs to a
    `periodic_check_history` table.
  - `Rei/Modules/Reflection/Queue/Scheduler/Handler.hs` — `reflectionSchedulerHandler`;
    same shape.
  - `Rei/Modules/AgentSchedule/Queue/Handler.hs` — `agentWorkHandler`; dispatches on the
    payload constructor (`ScheduleCheckMsg` vs `AgentTaskMsg`).
- Worker runner: `rei-cli/src/Rei/Cli/Commands/Worker/Runner.hs`,
  `runWorkersWithGracefulShutdown`. It currently does, in an effect block under
  `runPgmq pool` / `runHasqlWithPool pool` / `runStorePool store`:
  `gitSyncAdapter <- pgmqAdapter (defaultConfig (reiQueueName WorkspaceGitSyncQueue))` (and
  similarly for the other three), then `runApp IgnoreFailures 100 [ (ProcessorId
  "workspace-git-sync", mkProcessor gitSyncAdapter noteGitSyncHandler), ... ]`.
- Periodic enqueue: `rei-cli/src/Rei/Cli/Commands/Worker/PeriodicScheduler.hs` plus
  `pg_cron` jobs created in SQL migrations under `rei-core/migrations/scripts/` (e.g.
  `..._create_workspace_sync_queue.sql` runs `SELECT pgmq.create('workspace_git_sync')` and
  schedules periodic enqueues). The cron-driven enqueue stays as-is functionally; only the
  Haskell producer it ultimately calls (if any) changes. Where queues are created by SQL
  migration, you may keep that or move creation to `ensureJobQueue` at worker startup —
  either is fine; see Idempotence and Recovery.
- Dependencies: `rei-core.cabal` and `rei-cli.cabal` depend on `pgmq-core`,
  `pgmq-effectful`, `shibuya-core`, and `shibuya-pgmq-adapter`. rei's `cabal.project` pins
  these via `source-repository-package`.

Confirm these file paths and signatures by reading the files before editing; the tree is the
source of truth and line numbers may have drifted.

Terms: a **Job** is a `keiro-pgmq` value bundling a queue, a payload codec, and a retry/DLQ
policy. A **JobOutcome** is what a handler returns: `Done` (delete the message), `Retry
delay` (redeliver later), or `Dead reason` (park in the dead-letter queue). These replace
the shibuya `AckDecision` that rei handlers return today.


## Plan of Work

### Milestone 1 — Pin keiro-pgmq in rei

Add `keiro-pgmq` so rei can import it. In rei's `cabal.project`, add a
`source-repository-package` stanza matching rei's existing convention for the keiro family
(rei already pins keiro/keiki/kiroku — copy that exact form), pointing at the keiro repo
with `subdir: keiro-pgmq` and the SHA produced by `docs/plans/55-...`:

```text
source-repository-package
  type: git
  location: <same location rei uses for the keiro repo>
  tag: <keiro SHA with keiro-pgmq merged>
  subdir: keiro-pgmq
```

Add `keiro-pgmq` to the `build-depends` of `rei-core.cabal` (for the Job declarations,
producers, and handlers) and `rei-cli.cabal` (for the runner). Acceptance: from
`/Users/shinzui/Keikaku/bokuno/rei-project/rei`, `cabal build rei-core` resolves and builds
(no rei code changed yet — this just proves the dependency is reachable).

### Milestone 2 — Port the workspace git-sync queue (template)

Define the job and rewrite its producer and handler, end to end, for the git-sync queue
only. At the end, git sync runs through `keiro-pgmq` and the others are untouched.

Create a job declaration (e.g. in `Rei/Workspace/Queue/Job.hs` or alongside the existing
types):

```haskell
gitSyncJob :: Job NoteGitSyncPayload
gitSyncJob = Job
  { jobName   = "workspace-git-sync"
  , jobQueue  = queueRef "workspace_git_sync"        -- derives physical + DLQ names
  , jobCodec  = aesonJobCodec                         -- reuse existing ToJSON/FromJSON
  , jobPolicy = defaultRetryPolicy                    -- 60s retry, DLQ on
  }
```

If git sync currently has no DLQ and you want to preserve that exactly, set
`jobPolicy = defaultRetryPolicy { useDeadLetter = False }`. Match the current behavior; do
not silently add a DLQ unless the current code already had one.

Rewrite the producer to call `enqueue gitSyncJob payload` instead of constructing
`SendMessage`. Keep the producer's name and its `ScheduleSource`/input arguments so callers
(including `pg_cron`-driven paths) are unaffected.

Rewrite `noteGitSyncHandler` to the new shape:

```haskell
noteGitSyncHandler :: (GitSyncEff es) => NoteGitSyncPayload -> Eff es JobOutcome
```

Move the body unchanged except for the outer wrapping: delete the `case fromJSON msg`
decode (the package now decodes before calling you), receive the typed `NoteGitSyncPayload`
directly, and translate the three return points — the old `AckOk` becomes `Done`, the old
`AckRetry (RetryDelay 60)` becomes `Retry (RetryDelay 60)`, and any old `AckDeadLetter
(InvalidPayload e)` from a *domain* (not decode) reason becomes `Dead e`. Decode failures
no longer need handling here — the package routes an undecodable payload to the DLQ for you.
Preserve the content-hash dedup logic exactly (compare `payload.contentHash` to the note's
current hash and short-circuit to `Done` when stale).

Rewire just the git-sync processor in
`rei-cli/src/Rei/Cli/Commands/Worker/Runner.hs`. Replace:

```haskell
gitSyncAdapter <- pgmqAdapter (defaultConfig (reiQueueName WorkspaceGitSyncQueue))
-- ...
(ProcessorId "workspace-git-sync", mkProcessor gitSyncAdapter noteGitSyncHandler)
```

with a `jobProcessor` call:

```haskell
gitSyncProc <- jobProcessor gitSyncJob noteGitSyncHandler
-- ... include gitSyncProc in the list passed to the runner
```

Note `jobProcessor` already returns `(ProcessorId, QueueProcessor es)`, so it slots directly
into the list `runApp` consumes. The effect stack already has `Pgmq`, `Tracing`, and `IOE`
in scope in this runner (it runs under `runPgmq pool`), which is exactly what `jobProcessor`
requires. Leave the other three adapters as they are for this milestone.

At worker startup (once, before running), call `ensureJobQueue gitSyncJob` so the queue and
its DLQ exist, unless rei already guarantees creation via SQL migration — in which case you
may skip it (creation is idempotent either way).

Acceptance: `cabal build rei-core rei-cli` from rei's root. Then run rei's worker and
exercise a workspace change to confirm a git commit still happens (rei's existing
integration/e2e for git sync, or a manual scenario: edit a note, observe the commit). The
git-sync queue now flows through `keiro-pgmq`; the other three are unchanged.

### Milestone 3 — Port reminders, reflections, agent-work; rewire the runner

Repeat the milestone-2 pattern for the three remaining queues. They are nearly identical in
shape (periodic check → domain action → `Done`/`Retry 60`), so this is mechanical:

- `reminderTriggerJob :: Job ReminderTriggerPayload`, `reflectionSchedulerJob :: Job
  ReflectionSchedulerPayload`, `agentWorkJob :: Job AgentWorkPayload`, each with
  `queueRef` over the same names `reiQueueName` produced (`reminder_triggers`,
  `reflection_scheduler`, `agent_work` — verify the exact strings against
  `Rei/Workspace/Queue/Types.hs`).
- Rewrite each producer to `enqueue <job>`.
- Rewrite each handler to `payload -> Eff es JobOutcome`, dropping the `fromJSON` decode and
  translating returns (`AckOk`→`Done`, `AckRetry (RetryDelay 60)`→`Retry (RetryDelay 60)`,
  domain `AckDeadLetter`→`Dead`). Preserve the disabled-config early return (returns `Done`)
  and the `periodic_check_history` logging exactly. For `agentWorkHandler`, keep the inner
  dispatch on `ScheduleCheckMsg` vs `AgentTaskMsg`.
- In the runner, replace each `pgmqAdapter ... ; (ProcessorId ..., mkProcessor ...)` pair
  with `jobProcessor <job> <handler>` and collect all four into the list. The final runner
  call becomes `runJobWorkers IgnoreFailures 100 [gitSyncProc, reminderProc, reflectionProc,
  agentWorkProc]` where each `*Proc` is a `jobProcessor` action — or keep using `runApp`
  directly if you prefer; `runJobWorkers` is the thin wrapper that `sequence`s the processor
  actions and calls `runApp`. Either is acceptable; prefer `runJobWorkers` for consistency
  with the package's intended use.

Acceptance: `cabal build rei-core rei-cli`. Start the worker; all four queues are now served
through `keiro-pgmq`. Run rei's worker test suite (see Validation).

### Milestone 4 — Delete dead plumbing and verify parity

Remove what the package now owns: the per-queue `pgmqAdapter`/`defaultConfig`/`mkProcessor`
wiring in the runner (now replaced), and any `SendMessage` construction in the producers
(now replaced by `enqueue`). If `reiQueueName` / `ReiQueue` is no longer referenced after
the ports (the `queueRef` calls now hold the names), either delete it or keep it solely as
the single source of the name strings and have each `Job`'s `queueRef` consume it
(`queueRef (reiQueueNameText WorkspaceGitSyncQueue)`); pick one and apply it consistently.
Drop the now-unused `shibuya-pgmq-adapter` import lines from modules that no longer reference
it. If, after migration, neither `rei-core` nor `rei-cli` references `pgmq-effectful` or
`shibuya-pgmq-adapter` directly anymore, remove them from the respective `.cabal`
`build-depends` (keiro-pgmq pulls them in transitively). Verify the build still resolves
after pruning.

Acceptance: full parity. Run rei's existing test suite and worker e2e; all green. The four
background behaviors (git commit on workspace change, reminders firing, reflections
scheduling successors, agent schedule checks enqueuing tasks) work exactly as before, now on
`keiro-pgmq`.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/rei-project/rei`.

```bash
# Milestone 1
# (edit cabal.project: add keiro-pgmq source-repository-package pin)
# (edit rei-core.cabal and rei-cli.cabal: add keiro-pgmq to build-depends)
cabal build rei-core
```

```bash
# Milestones 2-4: after each set of edits
cabal build rei-core rei-cli
cabal test           # or the specific worker/integration suite rei defines
```

Commit after each milestone. Every commit (in the rei repo) must carry all three trailers;
the MasterPlan/ExecPlan paths are relative to the keiro repo:

```text
Port rei workspace git-sync queue to keiro-pgmq

MasterPlan: docs/masterplans/7-keiro-pgmq-reusable-postgres-job-queue.md
ExecPlan: docs/plans/56-migrate-rei-background-queues-onto-keiro-pgmq.md
Intention: intention_01kthhpasxesx8hp84264cjhpx
```


## Validation and Acceptance

Acceptance is behavioral parity with today, with the plumbing now provided by `keiro-pgmq`.
Concretely:

- `cabal build rei-core rei-cli` succeeds.
- rei's existing test suite passes (`cabal test`; identify the worker/integration suite in
  `rei-core.cabal`/`rei-cli.cabal` and run it specifically if the full suite is slow).
- Manual or scripted end-to-end for each queue: editing a workspace note produces a git
  commit (git sync); a due reminder triggers (reminder); a recurring reflection past its
  cycle creates a successor (reflection); a due agent schedule enqueues an agent task
  (agent work). These are the same scenarios rei verifies today; they must still pass.
- Grep proves the cleanup: `rg 'pgmqAdapter|mkProcessor|SendMessage|AckDecision' rei-core
  rei-cli` returns no matches in the migrated queue modules (the package owns these now).


## Idempotence and Recovery

The migration is incremental and reversible per queue: each queue is ported independently,
so a half-finished migration still builds and runs (ported queues on `keiro-pgmq`,
un-ported queues on the old path) as long as you rewire the runner consistently with which
handlers have been converted. `ensureJobQueue` and PGMQ's `createQueue` are idempotent, so
calling them at startup alongside existing SQL-migration queue creation causes no harm
(creating an existing queue is a no-op). If a port breaks the build, revert that queue's
handler to its previous `Ingested -> AckDecision` form and its runner entry to `pgmqAdapter
+ mkProcessor` to return to green, then retry.


## Interfaces and Dependencies

This plan depends on the `keiro-pgmq` package from
`docs/plans/55-build-the-keiro-pgmq-package-with-typed-job-and-runtime-layers.md`. The
public API you program against (do not re-derive shibuya/pgmq types yourself):

```haskell
-- Keiro.PGMQ.Runtime
data QueueRef
queueRef :: Text -> QueueRef

-- Keiro.PGMQ.Codec
data JobCodec p
aesonJobCodec :: (ToJSON p, FromJSON p) => JobCodec p

-- Keiro.PGMQ.Job
data JobOutcome = Done | Retry !RetryDelay | Dead !Text          -- RetryDelay is RE-EXPORTED from Keiro.PGMQ
data RetryPolicy = RetryPolicy { maxRetries :: !Int64, defaultRetryDelay :: !RetryDelay, useDeadLetter :: !Bool }
defaultRetryPolicy :: RetryPolicy
data Job p = Job { jobName :: !Text, jobQueue :: !QueueRef, jobCodec :: !(JobCodec p), jobPolicy :: !RetryPolicy }
enqueue          :: (Pgmq :> es, IOE :> es) => Job p -> p -> Eff es Pgmq.MessageId
enqueueWithDelay :: (Pgmq :> es, IOE :> es) => Job p -> Int32 -> p -> Eff es Pgmq.MessageId  -- Int32 = PGMQ Delay
ensureJobQueue :: (Pgmq :> es) => Job p -> Eff es ()
jobProcessor   :: (Pgmq :> es, IOE :> es, Tracing :> es) => Job p -> (p -> Eff es JobOutcome) -> Eff es (ProcessorId, QueueProcessor es)
runJobWorkers  :: (Pgmq :> es, IOE :> es, Tracing :> es) => SupervisionStrategy -> Int -> [Eff es (ProcessorId, QueueProcessor es)] -> Eff es (Either AppError (AppHandle es))
```

Import these from `Keiro.PGMQ` (umbrella) or the specific submodules. **`RetryDelay` is
re-exported by `Keiro.PGMQ` (EP-1 outcome, 2026-06-07) — import it from there, not from
`Shibuya.Core.Ack`.** `SupervisionStrategy`, `ProcessorId`, `QueueProcessor`, and
`AppError`/`AppHandle` come from shibuya (`Shibuya.App`) and are referenced only via the
signatures above. Note `enqueueWithDelay` takes `Int32` (PGMQ's `Delay`).

If `docs/plans/55-...` changed any of these signatures during its implementation, the
MasterPlan's Integration Points section is the authority — reconcile against it before
starting, and update this section to match.
