---
id: 15
slug: build-process-managers-and-timer-workflows
title: "Build process managers and timer workflows"
kind: exec-plan
created_at: 2026-05-15T15:00:30Z
intention: "intention_01krp2azwjessavsfva1he2gx1"
master_plan: "docs/masterplans/2-keiro-library-bootstrap-and-v1-implementation-start.md"
---

# Build process managers and timer workflows

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan ships keiro's v1 workflow substrate: event-sourced process managers plus durable timers. After completion, an application can define a process manager that consumes domain events, advances its own state stream, emits idempotent commands to other event streams, and schedules a timer that survives process restarts. This covers saga and choreography workflows without building the v2 deterministic replay runtime yet.

The behavior is visible in an integration test: an `OrderPlaced` event starts a process-manager stream, the manager emits a command to a payment stream with a deterministic command id, schedules a timeout row, and a timer worker later emits the timeout event exactly once across duplicate delivery.


## Progress

- [x] M1 — Add `Keiro.ProcessManager` pure API for event-sourced manager state and emitted commands. Completed 2026-05-15 with `ProcessManager`, `ProcessManagerAction`, `PMCommand`, `PMStateResult`, and `runProcessManagerOnce`.
- [x] M2 — Implement deterministic command ids for emitted commands and duplicate-safe command dispatch. Completed 2026-05-15 with UUIDv5 ids derived from process-manager name, correlation id, source event id, and emit index; duplicate delivery is detected by scanning the target stream for the deterministic event id before appending.
- [x] M3 — Add `keiro_timers` schema and `Keiro.Timer` scheduling/firing API. Completed 2026-05-15 with `keiro_timers`, `TimerId`, `TimerRequest`, `scheduleTimerTx`, `claimDueTimer`, `markTimerFired`, and `runTimerWorker`.
- [x] M4 — Add worker integration using Streamly/shibuya conventions for event consumption and timer polling. Completed 2026-05-15 with `runProcessManagerWorker` over `Shibuya.Adapter.Adapter` and a timer worker that claims due rows with `FOR UPDATE SKIP LOCKED`.
- [x] M5 — Add integration tests for process-manager state streams, emitted command idempotency, timer scheduling, timer firing, and restart/replay behavior. Completed 2026-05-15 with Postgres-backed tests in `test/Main.hs`.


## Surprises & Discoveries

- Kiroku's duplicate caller-supplied event id handling can surface as a `stream_events_pkey` SQL duplicate after the original event row already exists. Instead of relying only on `StoreError.DuplicateEvent`, `Keiro.ProcessManager` checks whether the deterministic event id already exists in the relevant stream before trying to append. Evidence: the first duplicate-delivery test failed with a PostgreSQL `23505` on `stream_events_pkey`; after the pre-check, `cabal test keiro-test` and `cabal test all` pass.


## Decision Log

- Decision: v1 workflows are process managers plus timers, not deterministic replay functions.
  Rationale: `docs/research/10-workflow-roadmap.md` records that this covers the near-term workflow needs while leaving named-step durable execution for v2.
  Date: 2026-05-15.

- Decision: Process managers are ordinary event streams under the same `EventStream` contract as domain aggregates.
  Rationale: Reusing EP-11 and EP-12 avoids a parallel persistence model and makes snapshots from EP-13 available to long-lived managers.
  Date: 2026-05-15.

- Decision: Keep Hasql packages resolved from Hackage rather than adding local filesystem Hasql packages to `cabal.project`.
  Rationale: Adding local Hasql packages fixed an intermediate unit-id mismatch but introduced duplicate-package risk and violated the package-bootstrap policy from EP-10. The final implementation leaves only `keiki`, `keiki-codec-json`, and `kiroku-store` as local project packages.
  Date: 2026-05-15.

- Decision: Detect process-manager duplicate delivery by scanning the manager and target streams for deterministic event ids before append.
  Rationale: EP-12 already supports caller-supplied event ids, but kiroku may report a repeated deterministic id as a lower-level unique conflict when stream links already exist. The pre-check makes replay/restart idempotency explicit and independent of exact store error mapping.
  Date: 2026-05-15.


## Outcomes & Retrospective

Completed 2026-05-15. Keiro now exposes process-manager and timer APIs for v1 workflow orchestration without implementing the v2 deterministic `Workflow es a` runtime. `Keiro.ProcessManager` stores manager state through ordinary `EventStream` command execution, emits target commands with deterministic event ids, and provides a shibuya-compatible worker entry point. `Keiro.Timer` creates and claims durable timer rows and marks fired timers complete after a worker callback returns an event id. The validation suite proves state persistence, duplicate input idempotency, timer scheduling, and timer firing against real Postgres.

Validation evidence:

```text
cabal build all
Build completed successfully.

cabal test keiro-test
28 examples, 0 failures

cabal test all
keiki-codec-json-test: PASS
keiki-test: PASS
keiro-test: PASS
kiroku-store-test: PASS
```


## Context and Orientation

This plan depends on EP-12's command cycle and uses EP-14's subscription/idempotency conventions when worker loops consume domain events. It consumes `docs/research/08-subscription-and-process-manager-design.md` and `docs/research/10-workflow-roadmap.md`.

A process manager is a small event-sourced coordinator. It observes events from one or more streams, stores its own state in a kiroku stream named with a convention such as `pm-OrderFulfillment-<correlationId>`, and emits commands to other event streams. Because delivery is at-least-once, emitted commands need deterministic ids so replaying the same input event does not append duplicate command-caused events.

A durable timer is a row in a keiro-owned table representing work to do after a timestamp. Timers are used for timeouts and delayed workflow steps. The timer row must commit atomically with the process-manager state that depends on it; otherwise a crash can lose the timeout.


## Plan of Work

Milestone 1 creates the pure process-manager API. Add `src/Keiro/ProcessManager.hs`, import `Keiro.Prelude`, and define a strict unprefixed record that names the manager, maps input domain events to a correlation id, defines the manager's `EventStream`, and defines a handler from manager state plus input event to manager events, emitted commands, and timer requests. Keep this pure where possible. Do not use `pm` field prefixes; use fields such as `name`, `correlate`, `eventStream`, and `handle`.

Milestone 2 implements emitted-command idempotency. For each emitted command, derive a deterministic UUID from `(processManagerName, correlationId, sourceEventId, emitIndex)` or an equivalent stable tuple. Thread that id into the target command path so retries either append once or recognize that the intended command-caused event already exists. If EP-12's command API does not yet accept a caller-supplied event id or command id, add the smallest extension there and record the cross-plan change in the MasterPlan.

Milestone 3 creates timers. Add `src/Keiro/Timer.hs` and `src/Keiro/Timer/Schema.hs`. The table should include timer id, process-manager name, correlation id, fire-at timestamp, payload JSON, status, attempts, created/updated timestamps, and optional fired event id. Provide a scheduling function designed to run inside the same `Hasql.Transaction.Transaction` used by `runCommandWithSql`.

Milestone 4 adds workers. Implement a process-manager runner that consumes events from a Streamly stream or shibuya adapter, loads/advances the manager state with EP-12 `runCommand`, emits target commands idempotently, and a timer worker that polls due timers with row locking, fires them, and marks them complete. Keep the worker API compatible with shibuya's `Adapter es msg` and `Handler es msg` types, but do not require the still-open transactional handler shape.

Milestone 5 tests end-to-end. Use real Postgres and fixture streams. Test duplicate input event delivery, crash/restart by reconstructing state from kiroku rather than memory, timer firing after a short delay, and idempotent command emission after timer retry.


## Concrete Steps

Re-check worker and store APIs:

```bash
sed -n '1,220p' /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/src/Shibuya/Adapter.hs
sed -n '1,220p' /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/src/Shibuya/Handler.hs
sed -n '1,220p' /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Causation.hs
sed -n '1,280p' /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Transaction.hs
```

Run:

```bash
cabal build all
cabal test all
```

Expected focused output:

```text
keiro-process-manager-integration
  advances manager state stream from a source event
  emits deterministic target command once under duplicate delivery
  schedules timer atomically with manager state
  fires due timer after restart
```


## Validation and Acceptance

Acceptance requires a process-manager API, timer schema/API, and integration tests proving state persistence, idempotent emitted commands, and durable timer firing. The process-manager state must be stored in kiroku streams through the same command-cycle machinery used by ordinary domain streams. Any new modules must import `Keiro.Prelude`; records, including timer request and worker option records, must follow the jitsurei record guide: strict fields, no prefixes, explicit deriving strategies, and generic-lens access/update.

The plan must not implement v2 `Workflow es a`, named steps, awakeables, child workflows, or deterministic function replay. It may leave module names or data shapes that make those features natural later.


## Idempotence and Recovery

Every worker handler must tolerate duplicate input. Timer polling should use a status transition or row lock so two workers do not fire the same timer concurrently. If a process dies after firing a target command but before marking a timer complete, deterministic command ids let the retry detect the existing target event and then mark the timer complete.


## Interfaces and Dependencies

This plan must expose:

```haskell
module Keiro.ProcessManager
  ( ProcessManager(..)
  , PMCommand(..)
  , runProcessManagerOnce
  , runProcessManagerWorker
  )

module Keiro.Timer
  ( TimerId(..)
  , TimerRequest(..)
  , scheduleTimerTx
  , runTimerWorker
  )
```

Dependencies include EP-12 command execution, EP-14 worker/idempotency conventions, `Kiroku.Store.Causation` for optional trace/correlation helpers, hasql transactions for timer rows, shibuya `Adapter`/`Handler` shapes, Streamly streams, and UUID generation for deterministic ids.
