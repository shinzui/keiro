---
id: 71
slug: fix-process-manager-and-router-delivery-correctness
title: "Fix process manager and router delivery correctness"
kind: exec-plan
created_at: 2026-06-11T04:45:56Z
master_plan: "docs/masterplans/9-keiro-production-readiness-hardening.md"
---

# Fix process manager and router delivery correctness

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Keiro's process manager (a stateful "saga" that reacts to events by dispatching commands to other aggregates) and router (its stateless sibling that fans an event out to a data-dependent set of targets) are the components that move work between aggregates. Today their worker loops silently lose work: the process-manager worker acknowledges a source event as "done" even when every command it tried to dispatch failed, so the target aggregate never receives the command and nothing ever retries it; worse, the worker never actually invokes the acknowledgment handle the messaging adapter gave it, so under the production adapter no decision reaches the subscription at all. The router worker can die mid-stream when a database error is thrown rather than returned, leaving its in-flight message unacknowledged until a lease times out. And every dispatched command pays an O(stream-length) scan of the target stream just to ask "did I already send this?".

After this plan, a failed dispatch is never silently swallowed: transient failures (a database blip) cause the event to be redelivered and retried — which is safe, because every write uses a deterministic id and replaying is idempotent — while deterministic failures (a rejected command, a decode bug) stop the worker loudly so an operator can intervene, with an explicit opt-in escape hatch (skip or dead-letter) for poison messages. The duplicate-detection pre-check becomes a single primary-key probe instead of a full stream scan, and the "benign duplicate" handling is proven live end-to-end with a concurrent-duplicate test that fails on today's code. You can see all of it working by running the keiro test suite: the new tests in `keiro/test/Main.hs` fail before these changes and pass after.

This plan is part of the MasterPlan at `docs/masterplans/9-keiro-production-readiness-hardening.md` (EP-5 in its registry). It HARD-depends on the sibling plan `docs/plans/67-fix-upstream-crash-safety-gaps-in-kiroku-shibuya-and-ephemeral-pg.md` (EP-1): milestone 3 below cannot be implemented until EP-1's kiroku changes are published (see "Interfaces and Dependencies"). Milestones 1, 2, and 4 are implementable against the currently pinned kiroku.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — worker ack machinery and the process-manager worker contract (C2, M9):

- [ ] Add `WorkerOptions`, `PoisonPolicy`, and `defaultWorkerOptions` to `keiro/src/Keiro/ProcessManager.hs`
- [ ] Add the failure classifier (`isTransientStoreError`, `isTransientCommandError`, `ackForCommandError`) and export it for direct testing
- [ ] Rewrite `runProcessManagerWorker`'s `handleIngested`: finalize the `AckHandle` exactly once, wrap the reaction in `tryError @StoreError`, inspect `commandResults` for `PMCommandFailed`, apply the poison policy on decode failure
- [ ] Add `runProcessManagerWorkerWith`; keep `runProcessManagerWorker` as a default-options wrapper
- [ ] Test: PM worker finalizes `AckOk` through the ack handle on success (regression for the never-finalized bug)
- [ ] Test: PM worker with a rejecting target finalizes `AckHalt (HaltFatal …)`, not `AckOk`, and the target stream stays empty
- [ ] Test: classifier unit tests (transient store errors map to `AckRetry`, `CommandRejected` maps to `AckHalt`)
- [ ] Test: undecodable message — default policy halts; `PoisonSkip` finalizes `AckOk` and invokes the callback; `PoisonDeadLetter` finalizes `AckDeadLetter`
- [ ] `cabal test keiro-test` green

Milestone 2 — router worker thrown-error guard (M6):

- [ ] Add `runRouterWorkerWith` taking `WorkerOptions`; rework `handleIngested` in `keiro/src/Keiro/Router.hs` to wrap decode + dispatch in `tryError @StoreError` so the ack is always finalized exactly once
- [ ] Route the router's failed-dispatch ack decision through the shared classifier from milestone 1
- [ ] Apply the poison policy to router decode failures
- [ ] Test: a router whose `resolve` throws a transient `StoreError` finalizes `AckRetry` and the worker continues to the next message (stream does not die)
- [ ] Test: a thrown non-transient `StoreError` (`UnexpectedServerError`) finalizes `AckHalt`
- [ ] `cabal test keiro-test` green

Milestone 3 — consume EP-1 kiroku artifacts: point lookup and live duplicate fold (M1/M8, H2):

- [ ] Read the published kiroku event-id lookup name/signature from plan 67's "Interfaces and Dependencies" section; reconcile this plan if it differs from the assumed shape (log in Decision Log)
- [ ] Bump the kiroku tag in `cabal.project` (both `kiroku-store` and `kiroku-store-migrations` stanzas) to the EP-1 release
- [ ] Reimplement `eventAlreadyIn` in `keiro/src/Keiro/ProcessManager.hs` as a point lookup; keep its exported signature
- [ ] Test (H2, process manager): concurrent duplicate via the `beforeAppend` seam — OCC retry re-appends the same deterministic id and must fold to `PMCommandDuplicate`, not `PMCommandFailed`
- [ ] Test (H2, router): same concurrent-duplicate scenario through `runRouterOnce`
- [ ] Test (H2, manager state): concurrent duplicate of the manager-state append folds to `PMStateDuplicate`
- [ ] Confirm the existing sequential-redelivery tests still pass with the point-lookup pre-check
- [ ] `cabal test keiro-test` green

Milestone 4 — documentation reconciliation and dispatch telemetry:

- [ ] Fix the module header and function docs in `keiro/src/Keiro/ProcessManager.hs` (header crash-safety paragraph, `PMCommandResult` doc, `runProcessManagerWorker` doc, `eventAlreadyIn` doc)
- [ ] Fix the ack-policy doc on `runRouterWorker` in `keiro/src/Keiro/Router.hs`
- [ ] Audit `docs/user/process-managers-and-timers.md`, `docs/guides/routers-and-effectful-fan-out.md`, and `docs/user/api-reference.md` for the same contradictions; update where they describe worker ack behavior
- [ ] Add `keiro.dispatch.failed`, `keiro.dispatch.duplicates`, `keiro.dispatch.poison` counters to `KeiroMetrics` in `keiro/src/Keiro/Telemetry.hs` (additive fields, names, record helpers, `newKeiroMetrics` wiring) and record them from both workers via `WorkerOptions`
- [ ] Test: metrics counters observed through the in-memory exporter pattern already used in `keiro/test/Main.hs`
- [ ] Update `keiro/CHANGELOG.md`
- [ ] Tick the EP-5 rollup lines in `docs/masterplans/9-keiro-production-readiness-hardening.md`
- [ ] Final `cabal test keiro-test` and `just haskell-verify` green


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

Seeded during plan authoring (2026-06-10 research pass; each re-verified against the working tree at commit `9fa283b`):

- The process-manager worker is worse than finding C2's framing. C2 says it "acks events whose dispatched commands failed". In fact `runProcessManagerWorker` (`keiro/src/Keiro/ProcessManager.hs:307-319`) computes an `AckDecision` and then *discards it*: the handler is run via `Streamly.mapM handleIngested` into `Fold.drain`, and the `Ingested` record's `AckHandle` is never invoked. The router worker's own documentation admits this ("Unlike 'runProcessManagerWorker' — which computes an 'AckDecision' per message and discards it", `keiro/src/Keiro/Router.hs:184-187`). Under the production adapter (`shibuya-kiroku-adapter`), a never-finalized handle means the subscription never receives a reply for the event. The C2 fix therefore has two parts: finalize the handle at all, and finalize the *correct* decision.
- Finding C2 does **not** apply to the router worker. `runRouterWorker` already finalizes its `AckHandle` and already maps any `PMCommandFailed` in the results to `AckHalt` (`keiro/src/Keiro/Router.hs:207-221`), with a green test at `keiro/test/Main.hs:1314-1325`. Only M6 (thrown errors escaping before `finalizeAck`) applies to the router.
- The thrown-error leak paths are narrower than "any store error". `runCommandWithSqlEvents` already catches thrown `StoreError` around its transaction (`tryError` at `keiro/src/Keiro/Command.hs:461`) and returns it as `Left (StoreFailed …)`. What still *throws* out of `runRouterOnce` / `runProcessManagerOnce` is: (a) the `resolve` read-model query (`Keiro.ReadModel.runQuery` calls the `Store` effect's `RunTransaction`, whose interpreter `throwError`s on pool errors — `kiroku-store/src/Kiroku/Store/Effect.hs:335-348`), (b) every stream read in `eventAlreadyIn` and in hydration (`usePool` throws at `kiroku-store/src/Kiroku/Store/Effect.hs:324-328`), and (c) the timer-only `runTransaction` at `keiro/src/Keiro/ProcessManager.hs:239`. Both workers need the `tryError` guard.
- The production adapter gives `AckRetry` exactly the semantics this plan needs: `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs:110-115` documents `AckRetry delay` as "the worker redelivers the same event after delay" with no checkpoint advance, and `AckHalt` as cancelling the subscription. This grounds the transient-vs-fatal classification decision below.
- The MasterPlan's KeiroMetrics integration point says "snake_case metric names prefixed `keiro_`", but the shipped convention in `keiro/src/Keiro/Telemetry.hs` is dot-separated (`"keiro.outbox.published"`, etc.). This plan follows the shipped code.


## Decision Log

Record every decision made while working on the plan.

- Decision: Failed-dispatch ack classification (C2/M6): classify `CommandError` into *transient* and *deterministic*. Transient — `StoreFailed`/`RetryExhausted` carrying `ConnectionLost`, `PoolAcquisitionTimeout`, `ConnectionError`, `WrongExpectedVersion`, or `StreamAlreadyExists` — finalizes `AckRetry` with a configurable delay (default 5 seconds). Deterministic — `CommandRejected`, `HydrationDecodeFailed`, `HydrationReplayFailed`, `EncodeFailed`, and `StoreFailed` carrying `UnexpectedServerError`, `StreamNotFound`, `ReservedStreamName`, or `DuplicateEvent` (the latter should have been folded earlier; reaching the classifier with it is a bug worth halting on) — finalizes `AckHalt (HaltFatal …)`. The same classifier handles errors *thrown* as `StoreError` (M6), mapped through the same transient/deterministic split.
  Rationale: the production adapter (`shibuya-kiroku-adapter`) redelivers the same event in place on `AckRetry` (ordering preserved, no checkpoint advance) and cancels the subscription on `AckHalt`. Deterministic write ids make redelivery idempotent, so retrying transient failures is safe and loses nothing; hot-looping forever on a deterministic failure would burn the database and hide the bug, so those stop the line. A blanket `AckHalt` for everything was rejected because a 2-second database blip would then take down the worker and page an operator for nothing.
  Date: 2026-06-10

- Decision: Poison-message default (M9) stays *halt*. `PoisonPolicy` is a three-way sum: `PoisonHalt` (default — finalize `AckHalt (HaltFatal …)`), `PoisonSkip callback` (finalize `AckOk` after invoking the callback with the message id and reason), `PoisonDeadLetter callback` (finalize `AckDeadLetter (InvalidPayload …)` after the callback).
  Rationale: a message that cannot be decoded means the deployment is wrong (codec drift, topic misconfiguration); silently skipping by default would lose events invisibly. Skip and dead-letter are explicit opt-ins and carry a mandatory callback so they can never be silent. `AckDeadLetter` already exists in shibuya's `AckDecision` and the kiroku adapter records it durably, so no new mechanism is needed.
  Date: 2026-06-10

- Decision: The `eventAlreadyIn` pre-check is *retained* after the duplicate fold goes live, reimplemented as a kiroku point lookup.
  Rationale: once it is a single primary-key probe it is nearly free, and on the common sequential-redelivery path it avoids the full hydrate-transduce-append cycle (a stream read plus a transaction) per dispatched command. The store-level `DuplicateEvent` fold remains the correctness backstop for the concurrent race the pre-check cannot see.
  Date: 2026-06-10

- Decision: API evolution is additive. New entry points `runProcessManagerWorkerWith` / `runRouterWorkerWith` take a `WorkerOptions` record (poison policy, transient retry delay, optional `KeiroMetrics`); the existing `runProcessManagerWorker` / `runRouterWorker` keep their signatures and delegate with `defaultWorkerOptions`. Their *behavior* changes (that is the fix), but no caller breaks at compile time — the MasterPlan reserves the initiative's one breaking API change for EP-2.
  Rationale: three call sites exist outside this module pair (`jitsurei/app/Main.hs:140`, `keiro/test/Main.hs:1298` and `1321`); keeping them compiling honors the MasterPlan's additive promise and keeps EP-5 mergeable independently of the example service.
  Date: 2026-06-10

- Decision: `WorkerOptions`, `PoisonPolicy`, and the classifier live in `Keiro.ProcessManager`, and `Keiro.Router` imports them.
  Rationale: `Keiro.Router` already imports `PMCommand`, `PMCommandResult`, `deterministicCommandId`, and `eventAlreadyIn` from `Keiro.ProcessManager` (`keiro/src/Keiro/Router.hs:35`); following the existing dependency direction avoids a new module for three definitions.
  Date: 2026-06-10

- Decision: `eventAlreadyIn` keeps its exported signature (`RunCommandOptions -> StreamName -> EventId -> Eff es Bool`) even though the new implementation is a by-id existence probe that may not need the stream name or page size.
  Rationale: it is exported as a public "idempotency primitive"; keeping the shape is additive. Semantically the check widens from "id present in this stream" to "id present in the store", which is equivalent for keiro's usage because every probed id is a v5 UUID deterministically derived from `(manager/router name, correlation, source event id, emit index)` and is only ever written to the one target stream that derivation names. If plan 67's lookup returns stream attribution, the implementation may additionally compare it; reconcile at implementation time.
  Date: 2026-06-10

- Decision: The worker guard catches only the typed `Error StoreError` channel (`tryError @StoreError`), not arbitrary IO exceptions.
  Rationale: `StoreError` is the only error these code paths throw besides programmer errors; async/IO exception supervision is the shibuya runner's and EP-1's concern (the supervised ingester). Widening the catch here would mask genuine crashes.
  Date: 2026-06-10

- Decision: This plan is written against an *assumed* kiroku point-lookup shape (`eventExists :: EventId -> Eff es Bool` in `Kiroku.Store.Read`, backed by a new `Store` effect constructor doing a `SELECT` against the events primary key). The authoritative name and signature are whatever plan 67 records in its "Interfaces and Dependencies" section; the implementer of milestone 3 must read it from there first and update this plan if it differs.
  Rationale: plan 67 had not been authored beyond its skeleton when this plan was written; the MasterPlan's integration point ("kiroku store error mapping and event-id lookup") fixes the semantics but not the spelling.
  Date: 2026-06-10

- Decision: New metric names are `keiro.dispatch.failed`, `keiro.dispatch.duplicates`, `keiro.dispatch.poison` (dot-separated, matching the shipped `Keiro.Telemetry` convention rather than the MasterPlan's "snake_case" phrasing), covering both the process manager and the router since they share the dispatch machinery and result types.
  Rationale: consistency with the twenty existing instrument names in `keiro/src/Keiro/Telemetry.hs`; a per-component split (`keiro.pm.*` vs `keiro.router.*`) was rejected because the workers share `PMCommandResult` and dashboards want one "commands lost?" signal.
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This repository (`/Users/shinzui/Keikaku/bokuno/keiro`; all paths below are relative to it unless absolute) hosts keiro, an event-sourcing framework in Haskell built on the `effectful` effect system, PostgreSQL via `hasql`, and three sibling libraries: **kiroku** (the PostgreSQL event store; pinned by git tag in `cabal.project`, sources readable at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`), **keiki** (typed state-machine transducers that decide which events a command emits), and **shibuya** (a message-processing framework providing the `Adapter`/`Ingested`/`AckHandle` types; consumed from Hackage as `shibuya-core`).

Plain-language definitions of the terms this plan uses:

- An **aggregate** is a state machine whose history lives in one event *stream* (an ordered list of events in PostgreSQL). Running a *command* against it means: replay the stream to recover current state ("hydrate"), ask the transducer what events the command emits ("transduce"), and append those events. This pipeline is `keiro/src/Keiro/Command.hs` (`runCommand`, `runCommandWithSql`, `runCommandWithSqlEvents`).
- A **process manager** (`keiro/src/Keiro/ProcessManager.hs`) reacts to an incoming event by appending to its *own* manager stream (recording saga progress) and dispatching commands to *target* aggregates, plus scheduling timers. `runProcessManagerOnce` does one reaction; `runProcessManagerWorker` runs reactions in a loop over a shibuya adapter.
- A **router** (`keiro/src/Keiro/Router.hs`) is the stateless variant: it resolves a set of targets effectfully (typically a read-model SQL query via `Keiro.ReadModel.runQuery`) and dispatches one command per target. `runRouterOnce` / `runRouterWorker` mirror the process-manager pair.
- A **deterministic command id** (`deterministicCommandId`, `keiro/src/Keiro/ProcessManager.hs:166-180`) is a v5 UUID derived from `(name, correlation id, source event id, emit index)`. Every write a reaction performs is keyed by one, so re-processing the same source event produces byte-identical ids and the store's primary key collapses the duplicate. This is what makes **at-least-once delivery** (the same message may arrive more than once) safe.
- The store rejects a duplicate id with `DuplicateEvent` (`kiroku-store/src/Kiroku/Store/Error.hs:72`, raised from the PostgreSQL `events_pkey` unique violation, SQLSTATE 23505). Both dispatch sites *fold* that rejection into a benign `PMCommandDuplicate` result (`keiro/src/Keiro/Router.hs:157-158`, `keiro/src/Keiro/ProcessManager.hs:229-233` for the manager state and `:276-277` for target commands).
- A **shibuya adapter** (`Shibuya.Adapter.Adapter`) exposes a stream of `Ingested` messages. Each `Ingested` carries an **`AckHandle`** — a callback the consumer must invoke *exactly once* with an `AckDecision`: `AckOk` (done, checkpoint past it), `AckRetry delay` (redeliver the same message after the delay), `AckDeadLetter reason` (park it durably), or `AckHalt reason` (stop the subscription; no checkpoint advance). The decision constructors live in `Shibuya.Core.Ack`; the handle in `Shibuya.Core.AckHandle`. Until the handle is finalized, the message is "in flight" and, depending on the adapter, holds a lease.
- **OCC (optimistic concurrency control)**: appends state an expected stream version; if another writer got there first the append fails with `WrongExpectedVersion` and `Keiro.Command` rehydrates and retries up to `retryLimit` times (`retryOrFail`, `keiro/src/Keiro/Command.hs:558-571`).
- A **poison message** is one the worker can never process — here, a message the worker's decode function returns `Nothing` for.

The defects this plan fixes, with current evidence (line numbers verified against commit `9fa283b`; re-verify before editing, they will drift):

**C2 (critical) — the process-manager worker loses failed commands.** `runProcessManagerWorker`'s handler (`keiro/src/Keiro/ProcessManager.hs:311-319`) maps any `Right _` from `runProcessManagerOnce` to `AckOk`. But a failed target command does not produce `Left`: `runProcessManagerOnce` returns `Left` only when the *manager-state* append fails for a non-duplicate reason; per-command failures are reported *inside* `Right` as `PMCommandFailed` elements of `commandResults` (see its doc at `:188-192` and the dispatch fold at `:274-278`). So when the manager-state append commits and a target dispatch then fails, the worker declares the source event done. The saga's own history says "command dispatched"; the target aggregate never received it; nothing retries. Compounding this, the handler's returned decision is *discarded* — `Streamly.fold Fold.drain $ Streamly.mapM handleIngested adapterSource` (`:307-309`) never touches `Ingested.ack`, violating the "called exactly once" `AckHandle` contract outright. The module's own docs contradict the code twice: the header (`:21-23`) warns that benign rejections must be modeled as total transitions "so they never surface as `PMCommandFailed` and wedge the worker" (implying a failure halts), and the `PMCommandFailed` doc (`:132-135`) says "the worker treats this as fatal so the source event is retried". Neither is true.

**M6 (medium) — the router worker leaks its in-flight message on thrown store errors.** `runRouterWorker`'s handler (`keiro/src/Keiro/Router.hs:207-215`) destructures the `AckHandle` and calls `finalizeAck decision` *after* `runRouterOnce`. `runRouterOnce` runs with `Error StoreError` in scope and several of its callees `throwError` rather than return `Left`: the `resolve` read-model query (via the `Store` effect's `RunTransaction`, whose pool-error path throws at `kiroku-store/src/Kiroku/Store/Effect.hs:341-348`), and every paged read inside `eventAlreadyIn` and hydration (`usePool` throws at `:324-328`). A thrown `StoreError` unwinds past `finalizeAck`, the ack is never finalized, the streamly fold rethrows, and the whole worker returns — one transient database blip kills the subscription and strands the in-flight message until lease expiry. The process-manager worker has the same exposure once it starts finalizing (its `runTransaction` for timer-only reactions at `keiro/src/Keiro/ProcessManager.hs:239` and its `eventAlreadyIn` calls at `:217` and `:263` can throw), so the guard must land in both workers.

**H2 (consumption of EP-1) — the duplicate fold is dead code on the transactional path.** Both dispatch sites and the manager-state append run through `runCommandWithSqlEvents`, which appends via `appendToStreamTx` inside the `Store` effect's `RunTransaction`. That interpreter branch, `runTxOnPool` (`kiroku-store/src/Kiroku/Store/Effect.hs:335-348`), maps *every* pool usage error to `ConnectionError (show usageErr)` instead of routing it through `mapUsageError` (which is what the non-transactional `AppendToStream` branch does at `:147-149`, and which correctly produces `DuplicateEvent` from an `events_pkey` 23505 — `kiroku-store/src/Kiroku/Store/Error.hs:160-173`). Consequence: the benign-duplicate folds listed above can never fire on the transactional path; a true concurrent duplicate (two workers handling the same source event; one commits; the other's OCC retry re-appends the same deterministic id) surfaces as `StoreFailed (ConnectionError …)` — today misclassified entirely, and after milestones 1-2 it would classify as *transient retry*, which at least converges (the retry's pre-check then sees the committed event) but is wasteful and wrongly logged. EP-1 fixes the mapping upstream; milestone 3 proves the fold live with a test that fails against the old pin. The existing duplicate tests (`keiro/test/Main.hs:1078` for the PM, `:1246` for the router) only exercise *sequential* redelivery, where the `eventAlreadyIn` pre-check short-circuits before any append happens — they never reach the store-level rejection.

**M1/M8 (medium) — `eventAlreadyIn` is an O(stream-length) scan.** `keiro/src/Keiro/ProcessManager.hs:329-338` answers "does event id X exist?" by reading the *entire* target stream forward from version 0, page by page (`readStreamForwardStream`), on *every* dispatch of *every* source event — once for the manager stream and once per target command (call sites: `:217`, `:263`, and `keiro/src/Keiro/Router.hs:144`). A 10,000-event target stream costs ~40 round trips per dispatch. EP-1 adds a primary-key point lookup to kiroku; milestone 3 swaps it in.

**M9 (medium) — no poison-message policy.** An undecodable message makes the PM worker emit `AckHalt (HaltFatal …)` (`keiro/src/Keiro/ProcessManager.hs:313-314`; router: `keiro/src/Keiro/Router.hs:210`). Stop-the-line is a defensible *default* (see Decision Log) but there is no escape hatch: after a halt the subscription replays the same message forever across restarts. Milestone 1 adds the configurable policy.

Existing test infrastructure you will reuse: the suite entry point `keiro/test/Main.hs` runs `withMigratedSuite` from `keiro-test-support/src/Keiro/Test/Postgres.hs` (one cached ephemeral PostgreSQL server, migrations applied once to a template database, each example cloning a fresh database via `around (withFreshStore fixture)` — never migrate per example). The router worker tests already define an `inMemoryAdapter :: IORef [AckDecision] -> [msg] -> Adapter es msg` whose `AckHandle` records every finalized decision into the `IORef` (`keiro/test/Main.hs:5186-5203`) — it is polymorphic in `msg` and works for the PM worker unchanged. A `rejectingEventStream` whose transducer rejects every command (so dispatch yields `PMCommandFailed CommandRejected`) is at `:5223-5235`, used by `failingRouter` (`:5237`). The `beforeAppend` hook on `RunCommandOptions` (`keiro/src/Keiro/Command.hs:138`, exercised at `keiro/test/Main.hs:487-517`) is the seam for deterministically injecting a concurrent write between hydration and append — this is how milestone 3 simulates the two-worker race without threads, and it doubles as this plan's instance of the MasterPlan's "crash-window test pattern" integration point (no new shared helper is needed; if a sibling plan has landed a generalized crash-window helper by then, prefer it).

Out of scope for this plan: the shibuya ingester supervision and the kiroku/ephemeral-pg fixes themselves (EP-1, `docs/plans/67-fix-upstream-crash-safety-gaps-in-kiroku-shibuya-and-ephemeral-pg.md`); outbox/inbox/timer/shard workers (`docs/plans/70-make-outbox-inbox-timer-and-shard-workers-crash-recoverable.md`); workflow engine (`docs/plans/72-...` and `73-...`); any change to `runProcessManagerOnce` / `runRouterOnce` result types.


## Plan of Work

The work is four milestones. Milestones 1 and 2 fix the ack contract against the currently pinned kiroku and can start immediately (the plan's hard dependency on EP-1 gates only milestone 3 and final completion). Milestone 3 consumes EP-1's kiroku release. Milestone 4 reconciles documentation and adds telemetry. Commit at every green step.

### Milestone 1 — worker ack machinery and the process-manager worker contract (fixes C2 and M9)

Scope: `keiro/src/Keiro/ProcessManager.hs` plus tests. At the end of this milestone the PM worker finalizes its `AckHandle` exactly once per message with a classified decision, and undecodable messages follow a configurable policy. A novice can verify it by running the new worker tests, which fail on today's code (today no decision is ever recorded by the test adapter's `IORef`, and a failing dispatch produces `AckOk` if you only patch the finalize call).

First, define the policy and options types in `keiro/src/Keiro/ProcessManager.hs` (near the other definition types, before the runners) and export them, along with the classifier, from the module header's export list under a new "Worker policy" section:

```haskell
-- | What a worker does with a message its decoder cannot parse.
data PoisonPolicy es msg
    = -- | Default: finalize @AckHalt (HaltFatal …)@; the subscription stops.
      PoisonHalt
    | -- | Invoke the callback, then finalize 'AckOk' (the message is skipped).
      PoisonSkip !(Envelope msg -> Eff es ())
    | -- | Invoke the callback, then finalize @AckDeadLetter (InvalidPayload …)@.
      PoisonDeadLetter !(Envelope msg -> Eff es ())

-- | Worker-level knobs shared by the process-manager and router workers.
data WorkerOptions es msg = WorkerOptions
    { poisonPolicy :: !(PoisonPolicy es msg)
    , transientRetryDelay :: !RetryDelay  -- delay for AckRetry on transient failures
    , metrics :: !(Maybe KeiroMetrics)    -- wired in milestone 4
    }

defaultWorkerOptions :: WorkerOptions es msg
defaultWorkerOptions =
    WorkerOptions
        { poisonPolicy = PoisonHalt
        , transientRetryDelay = RetryDelay 5
        , metrics = Nothing
        }
```

`RetryDelay` and `DeadLetterReason (InvalidPayload)` are imported from `Shibuya.Core.Ack` (already a dependency; extend the existing import at `keiro/src/Keiro/ProcessManager.hs:67`). `Envelope` is already imported. `KeiroMetrics` comes from `Keiro.Telemetry` — check for an import cycle: `Keiro.Telemetry` imports `Keiro.Inbox.Kafka` and `Keiro.Outbox.Kafka`, neither of which imports `Keiro.ProcessManager`, so the import is safe; verify with a clean build.

Second, add the failure classifier alongside, exported (it must be unit-testable):

```haskell
-- | Store errors a redelivery can plausibly outrun.
isTransientStoreError :: StoreError -> Bool
isTransientStoreError = \case
    ConnectionLost{} -> True
    PoolAcquisitionTimeout -> True
    ConnectionError{} -> True
    WrongExpectedVersion{} -> True   -- contention; the command runner's budget ran out
    StreamAlreadyExists{} -> True
    StreamNotFound{} -> False
    ReservedStreamName{} -> False
    DuplicateEvent{} -> False        -- should have been folded; reaching here is a bug
    UnexpectedServerError{} -> False

-- | Map a dispatch failure to the worker's ack decision.
ackForCommandError :: RetryDelay -> CommandError -> AckDecision
ackForCommandError delay err
    | isTransientCommandError err = AckRetry delay
    | otherwise = AckHalt (HaltFatal (Text.pack (show err)))

isTransientCommandError :: CommandError -> Bool
isTransientCommandError = \case
    StoreFailed e -> isTransientStoreError e
    RetryExhausted _ e -> isTransientStoreError e
    _ -> False
```

(Exact names are a suggestion; keep them descriptive and exported. The `StoreError` constructor set is closed and `-Wincomplete-patterns` will police future additions.)

Third, rewrite the worker. Add `runProcessManagerWorkerWith` with the same constraints as today's `runProcessManagerWorker` plus the leading `WorkerOptions es msg` parameter, and reduce `runProcessManagerWorker` to `runProcessManagerWorkerWith defaultWorkerOptions`. The new handler must: destructure `ack = AckHandle finalizeAck` from the `Ingested` (mirroring `keiro/src/Keiro/Router.hs:208`), compute the decision, then `finalizeAck decision` — exactly once on every path. Shape:

```haskell
handleIngested Ingested{envelope = env@Envelope{payload = message}, ack = AckHandle finalizeAck} = do
    decision <- case decodeMessage message of
        Nothing -> decideForPoison workerOptions env
        Just (recorded, input) -> do
            outcome <- tryError @StoreError (runProcessManagerOnce options manager recorded input)
            pure $ case outcome of
                Left (_, storeErr) -> ackForThrownStoreError (workerOptions ^. #transientRetryDelay) storeErr
                Right (Left err) -> ackForCommandError (workerOptions ^. #transientRetryDelay) err
                Right (Right result) -> ackForResults (workerOptions ^. #transientRetryDelay) (result ^. #commandResults)
    finalizeAck decision
    pure decision
```

where `ackForResults` scans the `commandResults` for `PMCommandFailed` payloads: no failures means `AckOk`; any deterministic failure means `AckHalt` (worst wins); otherwise transient failures mean `AckRetry`. `ackForThrownStoreError` wraps the thrown error as `StoreFailed` and reuses `ackForCommandError`. `decideForPoison` implements the `PoisonPolicy` mapping from the Decision Log. `tryError` comes from `Effectful.Error.Static` (already how `Keiro.Command` catches store errors at `keiro/src/Keiro/Command.hs:461`); note its `Left` carries a `(CallStack, StoreError)` pair. Crash-recovery semantics to preserve and document: when the manager-state append succeeded but a dispatch failed transiently, `AckRetry` redelivers the event; on replay the manager append folds to `PMStateDuplicate` and the dispatch loop re-runs — partial progress plus retry is exactly the designed recovery path (`runProcessManagerOnce` doc at `:186-192`).

Fourth, tests, in a new `describe "Keiro.ProcessManager worker" $ around (withFreshStore fixture)` block in `keiro/test/Main.hs` next to the existing PM block (`:1015`):

- Success path: drive `counterProcessManager` (fixture at `:4615`) through `runProcessManagerWorker` with `inMemoryAdapter` and one decodable message; assert the recorded decisions equal `[AckOk]` and the manager/target streams each hold one event. This is the regression test for the never-finalized handle: it fails on today's code with an empty decision list.
- Failing dispatch (the C2 test the findings call for): build a PM fixture like `counterProcessManager` but with `targetEventStream = rejectingEventStream` (the no-edges transducer at `:5223`), so the manager append succeeds and the target dispatch yields `PMCommandFailed CommandRejected`. Run it through the worker; assert the decision list matches `[AckHalt (HaltFatal _)]`, the target stream is empty, and the manager stream holds the state event (partial progress is expected and safe — the assertion documents it).
- Classifier unit tests (no database): `ackForCommandError d (StoreFailed (ConnectionLost "boom"))` is `AckRetry d`; `… CommandRejected` is `AckHalt (HaltFatal _)`; `… (RetryExhausted 3 (WrongExpectedVersion …))` is `AckRetry d`.
- Poison policy: feed the worker one undecodable message (`decodeMessage = const Nothing`). Default options: decisions `[AckHalt (HaltFatal _)]`. `PoisonSkip` with a callback writing to an `IORef`: decisions `[AckOk]` and the ref was written. `PoisonDeadLetter`: decisions `[AckDeadLetter (InvalidPayload _)]`.

Acceptance: `cabal test keiro-test` passes; the new tests fail when run against the pre-milestone worker (verify once by stashing the source change, running the worker tests, and unstashing — record the failing transcript in Surprises & Discoveries).

### Milestone 2 — router worker thrown-error guard (fixes M6)

Scope: `keiro/src/Keiro/Router.hs` plus tests. At the end, no path through the router worker's handler can skip `finalizeAck`, and a transient thrown error no longer kills the worker stream.

Add `runRouterWorkerWith :: WorkerOptions es msg -> RunCommandOptions -> Router … -> Adapter es msg -> (msg -> Maybe (RecordedEvent, input)) -> Eff es ()` (importing `WorkerOptions`, `PoisonPolicy`, and the classifier from `Keiro.ProcessManager`, extending the import at `keiro/src/Keiro/Router.hs:35`), and make `runRouterWorker` delegate with `defaultWorkerOptions`. Rework `handleIngested` (`:207-215`): wrap the decode-and-dispatch block in `tryError @StoreError` so that a thrown error becomes a decision instead of an unwind; route the existing `ackDecisionFor` failed-dispatch logic (`:217-221`) through the shared classifier so the router and PM make identical transient-vs-fatal calls; apply the poison policy to the decode-failure branch. The post-conditions: `finalizeAck` is reached on every path, exactly once; a transient failure yields `AckRetry` and the worker proceeds to the next message; a deterministic failure yields `AckHalt`.

One design point to respect: `resolve` runs user SQL and may throw; it runs *inside* the guarded region deliberately, because a read-model blip is precisely the transient case M6 is about.

Tests, added to the existing `describe "Keiro.Router"` block:

- Thrown transient error: a router whose `resolve = \_ -> throwError (ConnectionLost "injected")` (with `Error StoreError` in `es`; `throwError` from `Effectful.Error.Static`), driven with *two* messages where only the first throws (e.g. the resolver consults an `IORef` or branches on the input group). Assert decisions are `[AckRetry _, AckOk]` and the worker returns `Right ()` (the stream survived). On today's code this test fails: `runStoreIO` returns `Left (ConnectionLost "injected")` and the decision list contains only nothing for the first message.
- Thrown deterministic error: `resolve = \_ -> throwError (UnexpectedServerError "XX000" "boom")`; assert `[AckHalt (HaltFatal _)]` and that the ack was finalized (non-empty list is the load-bearing assertion).
- Keep the existing `failingRouter` test (`:1314`) green — it pins the already-correct `PMCommandFailed` path, now flowing through the classifier (note `CommandRejected` is deterministic, so it still asserts `AckHalt`).

Acceptance: `cabal test keiro-test` passes; the two new tests fail before the change.

### Milestone 3 — kiroku point lookup and the live duplicate fold (fixes M1/M8; proves H2)

Scope: `cabal.project`, `keiro/src/Keiro/ProcessManager.hs`, tests. This milestone is gated on EP-1 (`docs/plans/67-fix-upstream-crash-safety-gaps-in-kiroku-shibuya-and-ephemeral-pg.md`) having landed and published: (a) `runTxOnPool` routing usage errors through the duplicate-aware mapping so transactional appends surface `DuplicateEvent`, and (b) the event-id point lookup. **First step: open plan 67's "Interfaces and Dependencies" section and read the exact exported function name and signature for the point lookup.** This plan assumes the shape `eventExists :: (HasCallStack, Store :> es) => EventId -> Eff es Bool` in `Kiroku.Store.Read`; if the published shape differs (different name, returns `Maybe RecordedEvent` or stream attribution, takes a `StreamName`), adapt the `eventAlreadyIn` body accordingly and record the reconciliation in this plan's Decision Log.

Bump the kiroku pin: edit `cabal.project`, replacing tag `ffcf3a143ee58c09f17dc8d5746bad7d8ed4525a` with EP-1's release commit in *both* `source-repository-package` stanzas (`kiroku-store` and `kiroku-store-migrations` — they must stay in lockstep). Run `cabal build all` and fix any fallout (none is expected; EP-1 is additive).

Reimplement `eventAlreadyIn` (`keiro/src/Keiro/ProcessManager.hs:329-338`): keep the exported signature, replace the body's full-stream `Streamly` scan with the point lookup, and rewrite its doc comment (it currently says "by scanning it forward"). Per the Decision Log, the pre-check stays as a fast path; the duplicate fold is the backstop.

Add the concurrent-duplicate tests (H2). The race being simulated: two workers receive the same source event; both pass the `eventAlreadyIn` pre-check (nothing committed yet); worker A commits the target append; worker B's append fails `WrongExpectedVersion`, the command runner's OCC retry rehydrates (now seeing A's event) and re-appends the *same deterministic event id*, which trips the `events_pkey` unique violation inside the transaction — exactly the path that today yields `ConnectionError` and post-EP-1 yields `DuplicateEvent`. Simulate worker A with the `beforeAppend` hook so the test is deterministic and single-threaded:

- PM target-command variant: compute the expected id with `deterministicCommandId "counter-pm" "order-1" sourceEventId 0` (matching `counterProcessManager`'s derivation at `:259`), set `options = defaultRunCommandOptions & #beforeAppend .~ injectOnce`, where `injectOnce` (guarded by an `IORef` so only the first append attempt triggers it, copying the pattern at `keiro/test/Main.hs:488-504`) appends a `CounterAdded` event *with that same event id* (via the `EventData` `eventId` field, as the `:5158`-area fixtures do) to the target stream. Run `runProcessManagerOnce`; assert `commandResults` matches `[PMCommandDuplicate _]` — not `PMCommandFailed` — and the target stream holds exactly one event. Against the pre-EP-1 pin this asserts red (`PMCommandFailed (StoreFailed (ConnectionError _))`), which is the proof the fold was dead; note the red run in Surprises & Discoveries.
- Router variant: same construction through `runRouterOnce` with `demoRouter` (id derivation `deterministicCommandId "demo-router" key sourceEventId emitIndex`), asserting all results fold to duplicates.
- Manager-state variant: inject a competing append carrying the manager-state id (`emit index -1`, see `:214`) into the *manager* stream; assert `managerResult` is `PMStateDuplicate _` and `runProcessManagerOnce` still returns `Right` and still dispatches the target commands (the `finish` path at `:219`).

Re-run the sequential-redelivery tests (`:1078`, `:1246`) — they must stay green with the point-lookup pre-check.

Acceptance: `cabal test keiro-test` passes on the new pin; the three H2 tests demonstrably fail on the old pin.

### Milestone 4 — documentation reconciliation and dispatch telemetry

Scope: doc comments in both modules, the user-facing guides, `keiro/src/Keiro/Telemetry.hs`, changelog, MasterPlan rollup.

Documentation. In `keiro/src/Keiro/ProcessManager.hs`: rewrite the module-header paragraph (`:10-23`) to describe the pre-check as a point lookup and to state the *actual* worker policy (failed dispatch → retry or halt by classification, never silently acked; poison → policy); fix the `PMCommandFailed` doc (`:132-135`) to say the worker classifies it (transient → redelivery, deterministic → halt); rewrite the `runProcessManagerWorker` doc (`:283-289`) to document the finalize-exactly-once behavior, the classification, and `runProcessManagerWorkerWith`; update the `eventAlreadyIn` doc (done in milestone 3). In `keiro/src/Keiro/Router.hs`: update the ack-policy list in the `runRouterWorker` doc (`:170-187`) — the `PMCommandFailed` bullet now reads "classified: transient → `AckRetry`, deterministic → `AckHalt`", the decode bullet references the poison policy, and the closing paragraph contrasting it with the PM worker's discarded decision is deleted (it becomes false). Then sweep `docs/user/process-managers-and-timers.md`, `docs/guides/routers-and-effectful-fan-out.md`, and `docs/user/api-reference.md` for sentences describing worker ack behavior or the `eventAlreadyIn` scan and align them.

Telemetry (cheap, per the MasterPlan's `KeiroMetrics` integration point — all additions are new record fields, so this is additive and ordering-free with respect to EP-3/EP-4/EP-6; whichever lands first sets the pattern, and the pattern here copies the existing one exactly). In `keiro/src/Keiro/Telemetry.hs`: add name constants `keiroDispatchFailedName = "keiro.dispatch.failed"`, `keiroDispatchDuplicatesName = "keiro.dispatch.duplicates"`, `keiroDispatchPoisonName = "keiro.dispatch.poison"`; add three `Counter Int64` fields to `KeiroMetrics`; wire them in `newKeiroMetrics` (units `"{command}"`, `"{command}"`, `"{message}"`); add `recordDispatchFailed` / `recordDispatchDuplicate` / `recordDispatchPoison` helpers following `recordInboxFailed`; export everything. In both workers, record from the decision point using `WorkerOptions.metrics`: each `PMCommandFailed` increments failed, each `PMCommandDuplicate`/`PMStateDuplicate` increments duplicates, each poison message increments poison. Test with the in-memory metric exporter pattern at `keiro/test/Main.hs:280-310`: run the failing-dispatch worker scenario with `Just metrics`, force-flush, assert `keiro.dispatch.failed` is `1`.

Finish: add a `keiro/CHANGELOG.md` entry (behavioral fix to worker acking, new `*WorkerWith` APIs, point-lookup pre-check, new metrics); tick the two EP-5 lines in the MasterPlan's Progress rollup; write this plan's Outcomes & Retrospective.

Acceptance: `cabal test keiro-test` and the full `just haskell-verify` (which builds everything and runs the jitsurei test + diagrams check, proving the example service still compiles against the unchanged public signatures).


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`, inside the project dev shell (the repo is nix-based; if `cabal` is not on PATH, enter it with `nix develop`). The test suite needs no external PostgreSQL — `withMigratedSuite` starts its own cached ephemeral server.

Build and full test baseline (run before touching anything, to confirm a green start):

```bash
cabal build keiro
cabal test keiro-test
```

Expected tail of a green test run:

```text
Finished in ...s
... examples, 0 failures
Test suite keiro-test: PASS
```

Run only the process-manager and router specs while iterating (hspec `--match` filters by `describe` string):

```bash
cabal test keiro-test --test-options='--match "Keiro.ProcessManager"'
cabal test keiro-test --test-options='--match "Keiro.Router"'
```

Demonstrate a new test failing against the pre-fix code (example for milestone 1; do this once per milestone and capture the transcript into Surprises & Discoveries):

```bash
git stash push -- keiro/src/Keiro/ProcessManager.hs
cabal test keiro-test --test-options='--match "Keiro.ProcessManager worker"'
git stash pop
```

Expected failing output shape (decision list empty because the handle is never finalized):

```text
Keiro.ProcessManager worker
  finalizes AckOk through the ack handle on success FAILED [1]
  ...
  expected: [AckOk]
   but got: []
```

Milestone 3 pin bump (after reading plan 67's Interfaces and Dependencies for the real tag and API name):

```bash
# edit cabal.project: replace ffcf3a143ee58c09f17dc8d5746bad7d8ed4525a in BOTH kiroku stanzas
cabal update
cabal build all
cabal test keiro-test
```

Final verification (matches the Justfile's `haskell-verify` recipe — builds all packages, runs keiro and jitsurei suites, checks the jitsurei diagrams):

```bash
just haskell-build
just haskell-test
```

Commit after each green milestone with conventional-commit messages, e.g.:

```text
fix(keiro): finalize PM worker acks; classify failed dispatch as retry/halt
fix(keiro): guard router worker against thrown StoreError before finalize
perf(keiro): eventAlreadyIn via kiroku event-id point lookup; live duplicate fold tests
docs(keiro): reconcile PM/router worker docs; add keiro.dispatch.* counters
```


## Validation and Acceptance

The change is accepted when each of the following observable behaviors holds, each backed by a named test in `keiro/test/Main.hs` that fails before the corresponding milestone and passes after.

Process-manager worker (milestone 1). Feeding one message whose reaction fully succeeds through `runProcessManagerWorker` over the recording `inMemoryAdapter` leaves exactly `[AckOk]` in the adapter's decision ref — proving the `AckHandle` is now finalized. Feeding one message whose target dispatch is rejected (rejecting transducer) leaves `[AckHalt (HaltFatal …)]` and an *empty* target stream — proving a lost command can no longer be acknowledged away; the manager stream holding its state event is asserted too, documenting that partial progress plus redelivery is the designed recovery. The classifier unit tests pin the transient/deterministic table from the Decision Log. The three poison tests pin halt-by-default and the two opt-in escapes.

Router worker (milestone 2). A resolver that throws `ConnectionLost` on the first of two messages yields decisions `[AckRetry _, AckOk]` and the worker returns normally — proving a transient blip neither kills the subscription nor strands the in-flight message. A resolver throwing `UnexpectedServerError` yields `[AckHalt (HaltFatal …)]` — proving thrown errors are classified, and the ack is finalized on the throwing path.

Duplicate fold and point lookup (milestone 3). With the EP-1 kiroku pin, the `beforeAppend`-injected concurrent duplicate folds to `PMCommandDuplicate` (and `PMStateDuplicate` for the manager append) with the target stream containing exactly one event; the same tests against the old pin fail with `PMCommandFailed (StoreFailed (ConnectionError …))`, which is the documented proof that the fold was dead code before. The pre-existing sequential-redelivery tests (`treats duplicate input delivery as idempotent…` at `:1078`, `reports every dispatch as a duplicate on replay…` at `:1246`) stay green, proving the point-lookup pre-check preserves behavior.

Telemetry and docs (milestone 4). The metrics test exports `keiro.dispatch.failed = 1` after one failing dispatch through a worker constructed with `Just metrics`. Documentation acceptance is a manual read: the module headers and worker docs in both files describe the implemented behavior (classification, finalize-exactly-once, poison policy, point lookup), and no sentence in the two modules or the three user docs claims a failed dispatch halts-or-retries-implicitly or that the duplicate pre-check scans the stream.

Whole-plan acceptance: `cabal test keiro-test` green; `just haskell-build && just haskell-test` green (includes jitsurei, proving the public API stayed additive); every Progress box ticked; Outcomes & Retrospective written.


## Idempotence and Recovery

Every step is safe to repeat. Source edits are idempotent by construction (re-running a milestone means re-applying edits to the same functions); tests create and drop their own cloned databases per example via `keiro-test-support`, so reruns never collide; `cabal build`/`cabal test` are incremental and harmless to repeat. The kiroku pin bump in milestone 3 is a two-line `cabal.project` edit — to roll back, restore tag `ffcf3a143ee58c09f17dc8d5746bad7d8ed4525a` in both stanzas and `cabal build all` (milestones 1, 2, and 4 compile and pass against the old pin; only the H2 tests and the `eventAlreadyIn` body require the new one, so if EP-1 slips after milestone 3 started, stash that milestone's commits and the branch remains releasable). No schema migrations, no data migrations, no destructive operations are involved anywhere in this plan. If a partially applied milestone leaves the suite red, `git stash` or `git checkout -- <file>` restores green; committed milestones are independently revertable because each is a self-contained behavioral unit with its own tests.

One behavioral-rollout note for operators consuming a release containing milestone 1: workers that previously "succeeded" past failing dispatches will now halt (deterministic failures) or retry (transient). A backlog of genuinely poisoned messages will surface as halts on first deploy. That is the intended correctness fix; the `PoisonSkip` / `PoisonDeadLetter` policies and the `AckRetry` classification are the relief valves, and `keiro.dispatch.failed` makes the backlog visible.


## Interfaces and Dependencies

Upstream artifacts consumed (hard dependency on EP-1, `docs/plans/67-fix-upstream-crash-safety-gaps-in-kiroku-shibuya-and-ephemeral-pg.md`):

- Duplicate surfacing on the transactional path: after EP-1, the `Store` effect's `RunTransaction` interpreter (`runTxOnPool`, `kiroku-store/src/Kiroku/Store/Effect.hs:335-348`) must map an `events_pkey` unique violation to `DuplicateEvent (Maybe EventId)` instead of `ConnectionError`. This plan consumes the behavior only — no keiro code change is needed for it beyond the milestone-3 tests, because the folds in `keiro/src/Keiro/Router.hs:157-158` and `keiro/src/Keiro/ProcessManager.hs:229-233,276-277` already pattern-match `DuplicateEvent`.
- Event-id point lookup: **the authoritative name and signature must be read from plan 67's "Interfaces and Dependencies" section before implementing milestone 3.** Assumed shape until then (per the MasterPlan's integration point "kiroku store error mapping and event-id lookup"): a new `Store` effect operation surfaced as `Kiroku.Store.Read.eventExists :: (HasCallStack, Store :> es) => EventId -> Eff es Bool`, implemented as a single `SELECT` against the events primary key. Reconcile any difference at implementation time and log it in this plan's Decision Log.
- Pin mechanics: kiroku enters this repo via two `source-repository-package` git stanzas in `cabal.project` (subdirs `kiroku-store` and `kiroku-store-migrations`, currently tag `ffcf3a143ee58c09f17dc8d5746bad7d8ed4525a`); both must move to EP-1's release commit together. `shibuya-core` (>= 0.5, currently resolving to 0.7.0.0) comes from Hackage and needs no change — `AckRetry`, `AckDeadLetter`, `RetryDelay`, and `DeadLetterReason (InvalidPayload)` all exist in it today (`Shibuya.Core.Ack`).

Modules edited and the interfaces that must exist at each milestone's end:

- `keiro/src/Keiro/ProcessManager.hs` (milestones 1, 3, 4). New exports after milestone 1: `PoisonPolicy (..)`, `WorkerOptions (..)`, `defaultWorkerOptions`, `runProcessManagerWorkerWith`, `isTransientStoreError`, `isTransientCommandError`, `ackForCommandError`. Signatures: `runProcessManagerWorkerWith :: (same constraint set as runProcessManagerWorker) => WorkerOptions es msg -> RunCommandOptions -> ProcessManager input phi rs s ci co targetPhi targetRs targetState targetCi targetCo -> Adapter es msg -> (msg -> Maybe (RecordedEvent, input)) -> Eff es ()`; `runProcessManagerWorker` unchanged in type, delegating with defaults. After milestone 3, `eventAlreadyIn :: (Store :> es) => RunCommandOptions -> StreamName -> EventId -> Eff es Bool` keeps its type with a point-lookup body.
- `keiro/src/Keiro/Router.hs` (milestones 2, 4). New export: `runRouterWorkerWith :: (same constraints as runRouterWorker) => WorkerOptions es msg -> RunCommandOptions -> Router input targetPhi targetRs targetState targetCi targetCo es -> Adapter es msg -> (msg -> Maybe (RecordedEvent, input)) -> Eff es ()`; `runRouterWorker` unchanged in type.
- `keiro/src/Keiro/Telemetry.hs` (milestone 4). New exports: `keiroDispatchFailedName`, `keiroDispatchDuplicatesName`, `keiroDispatchPoisonName :: Text`; three new `Counter Int64` fields on `KeiroMetrics`; `recordDispatchFailed`, `recordDispatchDuplicate`, `recordDispatchPoison :: (MonadIO m) => Maybe KeiroMetrics -> Int64 -> m ()`. Additive only — coordinate with the sibling plans extending `KeiroMetrics` (EP-3/EP-4/EP-6 per the MasterPlan's integration point) by rebasing field additions, never renaming existing ones.
- `keiro/test/Main.hs` (all milestones): reuses `inMemoryAdapter` (`:5186`), `rejectingEventStream` (`:5223`), the `beforeAppend` injection pattern (`:488`), and the in-memory metric exporter pattern (`:280`); all new database-touching specs use `around (withFreshStore fixture)` under the suite-level `withMigratedSuite` from `keiro-test-support/src/Keiro/Test/Postgres.hs` — never per-example migrations (MasterPlan crash-window-test integration point).
- `cabal.project` (milestone 3): kiroku tag bump, both stanzas.
- Unchanged but relied upon: `keiro/src/Keiro/Command.hs` (`RunCommandOptions.beforeAppend` test seam, `tryError` precedent, `retryOrFail` OCC semantics), `Effectful.Error.Static` (`tryError`, `throwError`), `Shibuya.Core.Ack` / `Shibuya.Core.AckHandle` / `Shibuya.Core.Ingested` / `Shibuya.Adapter` (ack contract: finalize exactly once), `kiroku-store`'s `Kiroku.Store.Error.StoreError` constructor set (classifier input).

Sibling plans referenced by path only (no artifacts consumed): `docs/plans/70-make-outbox-inbox-timer-and-shard-workers-crash-recoverable.md` (shares the crash-window test pattern and the `KeiroMetrics` convention), `docs/plans/68-harden-keiro-core-codec-and-stream-contracts.md` (its `Codec.decode` break does not touch these modules' call sites, but if it lands first, rebase mechanically).
