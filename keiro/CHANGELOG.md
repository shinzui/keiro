# Changelog

All notable changes to the `keiro` library are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
the [Haskell Package Versioning Policy](https://pvp.haskell.org/).

## [Unreleased]

### Changed

- Adopts keiki 0.3 (`EdgeMode`, plan 143): a `ReplayOnly` edge is excluded
  from forward stepping and serves two-phase inversion, so a tightened guard
  can retain its removed region (`old ∧ ¬new`) as a replay-only twin and
  keep stored history hydratable while new removed-region commands are
  rejected with `CommandRejected`. No keiro API change — machines built with
  `Keiki.Builder.replayOnly` (or `mode = ReplayOnly`) pass the existing
  `mkEventStream` boundary checks; the black-acuity regression is pinned in
  `keiro-test`. Rolling back a deployed replay-only twin re-creates exactly
  the hydration break it fixed (stored events in the removed region lose
  their inverting edge): delete a twin only when every affected stream is
  terminal or truncated.

## 0.3.0.0 — 2026-07-14

No user-facing changes to the `keiro` library. It is released at 0.3.0.0 to stay
in lockstep with the rest of the Keiro package set, and is rebuilt against
`keiro-core` 0.3.0.0. Applications that provision their test databases through
`keiro-test-support` should note the `withMigratedSuiteWith` change described in
the root changelog.

## 0.2.0.0 — 2026-07-13

### Breaking Changes

- **Keiro's framework tables moved out of the `kiroku` schema into a dedicated
  `keiro` PostgreSQL schema.** Every runtime query is now fully qualified
  (`keiro.keiro_snapshots`, `keiro.keiro_timers`, `keiro.keiro_outbox`, …) and no
  longer depends on `search_path`. Existing databases must run the
  `keiro-migrations` bootstrap that creates the schema and relocates the tables;
  application SQL reading bare `keiro_*` relations must be re-qualified.
- `runCommandWithSql`, `runCommandWithSqlEvents`, `runCommandWithProjections`,
  and the process-manager/router runners now require `KirokuStoreResource` so
  transactional appends can apply Kiroku's configured `enrichEvent` hook. Acquire
  the store with `withKirokuStore` and interpret `Store` with `runStoreResource`;
  plain `runCommand` is unchanged.
- Read-model queries no longer auto-register missing registry rows. Applications
  must call `registerReadModel` at projection startup; unknown models now return
  `ReadModelUnregistered` without mutating the registry.
- `ReadModel` now requires a `strongScope :: StrongScope` field. Use `EntireLog`
  for all-stream subscriptions or `CategoryHead category` for a category
  subscription, so that unrelated traffic cannot hold `Strong` reads behind.
- `ReadModel` now also requires a `schema :: Text` field naming the PostgreSQL
  schema its data table lives in. Keiro does not rewrite `query`; qualify the
  application's SQL with `qualifiedTableName` or `Keiro.Connection.qualifyTable`.
  The field is Haskell-level wiring only and is deliberately not persisted in the
  `keiro.keiro_read_models` registry.
- `AsyncProjection` now requires `readModelName`, naming the registry row that
  fences writes during a rebuild.
- `applyAsyncProjection` now returns `AsyncApplyOutcome` (`AsyncApplied`,
  `AsyncDuplicate`, or `AsyncFenced`) and live workers must not checkpoint a
  fenced event. Rebuild replayers use `applyAsyncProjectionUnfenced` between the
  new atomic `startRebuild` and guarded `finishRebuild` helpers.
- Router deterministic command ids are now derived from the resolved target
  stream name and same-stream occurrence rather than the target's list position
  (`deterministicRouterCommandId`). A transition point-probe recognizes legacy
  positional ids for stable resolver output and may be removed in a later
  release. If both the deployment version and resolver output change between
  attempts, a target command may be dispatched at most one extra time across that
  one-time upgrade window.
- `runWorkflow`, `runWorkflowWith`, and the child-workflow runtime now require
  `Error StoreError` in their effect rows, so post-commit workflow snapshot
  failures can be caught without leaving the typed error channel.
- `HydrationReplayFailed` now carries a typed `HydrationReplayReason` alongside
  the failing stream version. The reasons distinguish no inverting edge, ambiguous
  inversion, queue mismatch, and a truncated multi-event chain. `CommandError`
  also gains `CommandAmbiguous` (matched edge indices) and `HydrationGapDetected`
  (expected and observed stream versions).
- A command matching multiple transitions is now reported as `CommandAmbiguous`
  instead of `CommandRejected`. Process managers and routers halt on this
  aggregate-definition bug, while generated timer dispositions route it through
  their on-error arm rather than benign on-reject handling.
- `PMCommandResult.PMCommandFailed` now carries the target `StreamName` alongside
  its `CommandError`, so worker policy can identify the failing target.
- `WorkerOptions` gains a `rejectedCommandPolicy :: RejectedCommandPolicy` field,
  and `ShardedWorkerOptions` gains `handlerRetryDelay :: RetryDelay` and
  `retryPolicy :: RetryPolicy`. Record construction must supply them; the
  `defaultWorkerOptions` and `defaultShardedWorkerOptions` defaults are unchanged
  in behavior except as noted below.
- The `hydration_replay_failed` telemetry class is replaced by four
  reason-specific `error.type` values, and `command_ambiguous` is new. Dashboards
  keyed on the old hydration class must be updated.
- Stream validation is stricter through the re-exported `keiro-core` contracts.
  Keiki 0.2's head-recoverability, inversion-ambiguity, unguarded-input-read, and
  state-changing-silent-edge checks now reject a stream at `mkEventStream`, and
  `mkEventStreamWith` can no longer disable the head-recoverability or
  state-changing-epsilon checks. Snapshot-enabled streams whose codec cannot
  encode their initial state and registers are rejected at startup. `keiro` now
  requires `keiki >=0.2`, `keiki-codec-json >=0.2`, and `kiroku-store >=0.3`.

### New Features

- New `Keiro.DeadLetter`, `Keiro.DeadLetter.Schema`, and `Keiro.DeadLetter.Replay`
  modules. Process-manager and router workers can now park a rejected dispatch
  instead of halting: `RejectedCommandPolicy` selects `RejectedHalt` (the
  default), `RejectedDeadLetter` (persist a `DispatchDeadLetter` in
  `keiro.keiro_dead_letters` and acknowledge), or `RejectedSkip` (acknowledge and
  count). `recordDispatchDeadLetter` is idempotent under source-event redelivery,
  and `listDispatchDeadLetters` reads one dispatcher's witnesses newest-first.
  `replaySubscriptionDeadLetters` re-runs a caller-supplied handler over the rows
  Kiroku parked in `kiroku.dead_letters`, reporting `ReplayedFresh`,
  `ReplayedDuplicate`, `ReplayFailed`, or `ReplaySourceMissing` without deleting
  or mutating the Kiroku-owned rows.
- New `Keiro.Connection` module for application read-model and projection tables:
  `qualifyTable`, `quoteIdentifier`, `withProjectionSchema`,
  `keiroConnectionSettings`, and the opt-in `ensureProjectionSchema`. The store
  connection's `schema` stays `kiroku` because it drives the `LISTEN`/`NOTIFY`
  channel; a projection schema is reached by qualification and/or
  `extraSearchPath`. `ReadModel.qualifiedTableName` builds the model's
  `"schema"."table"` reference.
- `Keiro.Subscription.Shard.Worker` gains an acknowledgement-aware surface:
  `runShardedSubscriptionGroupAck` with `ShardAck`, `ShardDelivery`, and
  `ShardEventHandler`, plus per-event retry and dead-letter dispositions.
  `runShardedSubscriptionGroup` remains as the `RecordedEvent -> IO ()`
  compatibility wrapper.
- Added `keiro.dispatch.deadlettered` and `keiro.subscription.deadlettered`
  counters. `Keiro.Telemetry.kirokuEventBridge` installs on Kiroku's
  `eventHandler` to observe `KirokuEventSubscriptionDeadLettered`, the terminal
  retry-exhaustion signal, and delegates every event to the application's handler.
- Added `keiro.snapshot.encode.failures`, `keiro.snapshot.decode.failures`,
  `keiro.snapshot.read.hits`, `keiro.snapshot.read.misses`, and
  `keiro.snapshot.apply.divergence`. Snapshot lookup APIs (`lookupSnapshotSeed`,
  `SnapshotLookup`, `SnapshotMissReason`, `encodeSnapshotStrict`,
  `writeSnapshotEncoded`) now retain miss and decode reasons, while compatibility
  wrappers preserve the previous `Maybe` surface.
- `commandErrorClass` exposes a stable error-class string for a `CommandError`.
  `isRejectionClass`, `decideForFailures`, `DispatchFailure`, and
  `confirmBenignDuplicate` are exported from `Keiro.ProcessManager` and
  `Keiro.Router` so that custom workers can reuse the runtime's acknowledgement
  classification. `ReadModel.categoryHeadPosition` reads the latest global
  position originating in a Kiroku category.

### Bug Fixes

- Command hydration now detects stream-version gaps caused by Kiroku per-stream
  truncation, and returns `HydrationGapDetected` unless a snapshot covers the
  hidden prefix.
- Transactional command runners now apply Kiroku's configured `enrichEvent` hook
  before event preparation, so persisted events and the `runCommandWithSqlEvents`
  callback observe the same enriched metadata as plain `runCommand`.
- Router and process-manager duplicate-event rejections are now confirmed against
  the intended target stream before being treated as benign. Unconfirmed
  cross-stream or id-less collisions surface as command failures, causing workers
  to halt instead of silently dropping a dispatch.
- Sharded subscription readers now acknowledge each event only after its handler
  returns, using Kiroku's acknowledgement bridge. A shed or rebalanced bucket's
  checkpoint can no longer cover an unprocessed event, and a synchronous handler
  exception is retried in place under `retryPolicy` before Kiroku dead-letters the
  event; asynchronous exceptions write no acknowledgement, and the event is
  redelivered by the next owner.
- No-op commands now report `CommandResult.globalPosition = Nothing` instead of
  exposing Kiroku's per-stream-read sentinel `GlobalPosition 0`. Appended commands
  continue to report the real store-assigned position.

### Other Changes

- `RunCommandOptions.verifyReplayOnAppend` defaults on. Both command append paths
  replay each just-committed batch from the pre-command state, count an
  unreplayable batch through `keiro.snapshot.apply.divergence`, and attach a
  bounded typed reason to `keiro.replay.divergence` without turning an
  already-committed command into a reported failure.
- Aggregate snapshot encoding is forced before the store write. An `ErrorCall`
  from a partial state encoder or an uninitialized register is swallowed after the
  event append and counted, instead of escaping a successful command.
- Workflow snapshot writes after steps, completion, and continue-as-new rotation
  are advisory: store failures are swallowed and counted after the journal append
  commits.
- Corrected snapshot documentation: version non-regression applies within one
  codec version and shape hash, while an incompatible codec can replace a newer
  row to permit rollback. Upgrade notes cover the full-replay miss caused by
  Keiki EP-78's stable shape hash.
- Documented previously implicit runtime contracts: the inbox deduplication window
  closes when `garbageCollectCompleted` removes a completed row; outbox
  `created_at` is transaction-start time, so `PerKeyHeadOfLine` and
  `PerSourceStream` ordering is best-effort unless the caller serializes same-key
  enqueues; the default timer worker has no attempt ceiling and requeues claims
  left `Firing` for five minutes; and process-manager `correlate` joins across
  streams must be order-insensitive.
- The shared PostgreSQL test fixture now provisions templates through the native
  Kiroku/Keiro migration plan. Codd transition and remediation tests are retained
  behind the manual `legacy-codd-tools` flag.
- Kiroku 0.3, Keiki 0.2, and pg-migrate 1.0 now resolve from Hackage; their
  obsolete Git package overrides and the local Cabal overlay are no longer needed.

## 0.1.0.0 — 2026-07-05

The initial Hackage release of `keiro`, an event-sourcing framework and workflow
engine that composes the kiroku event store, the keiki aggregate core, and the
shibuya worker substrate.

### Breaking Changes

- Command-boundary APIs require `ValidatedEventStream` instead of bare
  `EventStream`: `runCommand`, `runCommandWithSql`, `runCommandWithSqlEvents`,
  `runCommandWithProjections`, `Router.targetEventStream`, and
  `ProcessManager.eventStream` / `targetEventStream`. Build stream definitions
  with `mkEventStream` or `mkEventStreamOrThrow` before wiring them into runners.
  This is source-level only; persisted events, snapshots, stream names, and wire
  formats are unchanged.

### New Features

- Command-side write APIs with optimistic concurrency, idempotent event ids,
  transactional SQL hooks, inline projections, command metadata, and OpenTelemetry
  spans.
- Typed event codecs, schema-version metadata, ordered upcasters, advisory
  snapshots, and replay-safe event-stream validation via `Keiro.EventStream.Validate`.
- Read models with consistency modes, rebuild lifecycle support, async projection
  deduplication, and strong consistency checks.
- Process managers, routers, database-backed timers, shard workers, and worker
  options for retry, halt, duplicate, and poison-message handling.
- Durable integration outbox and idempotent inbox support, including Kafka
  adapters, trace propagation, retry accounting, dead-lettering, and maintenance
  helpers.
- Durable workflow primitives: journaled named steps, sleep, await/signal,
  child workflows, continue-as-new, patching, push wake signals, resume workers,
  instance leasing, garbage collection, snapshots, and workflow telemetry.
- Metrics surfaces for command dispatch, projections, timers, outbox/inbox
  workers, and workflow execution.

### Bug Fixes

- Hardened command retry, snapshot boundary handling, workflow crash windows,
  process-manager/router ack finalization, timer requeueing, shard reader
  recovery, async projection deduplication, and inbox/outbox recovery paths.
- Fixed duplicate-event classification, outbox publish grouping, no-op late
  failure marks, and idempotent runtime release paths.

### Other Changes

- Re-exported the shared contracts from `keiro-core`, including codecs, streams,
  event streams, validation, integration events, and snapshot policies.
- Added user guides, migration notes, Haddock coverage, API references, and
  guide-backed examples for command-side usage, event evolution, snapshots,
  read models, process managers, routers, integration events, and durable
  workflows.
