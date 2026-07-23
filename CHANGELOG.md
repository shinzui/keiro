# Changelog

All notable changes to the Keiro package set are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/), and the published
packages follow the [Haskell Package Versioning Policy](https://pvp.haskell.org/).

## [Unreleased]

### Breaking Changes

- `StateCodec` gains a `stateShapeHash` compatibility field, and aggregate
  snapshot lookup now requires codec version, register-layout hash, and
  control-state/fold hash to match. Migration
  `0019-keiro-snapshots-state-shape-hash.sql` adds the corresponding
  `state_shape_hash` column; existing rows receive the empty sentinel and are
  invalidated once on their next hydration. `keiro-core`, `keiro`, and
  snapshot-enabled generated code now require `keiki >=0.3.1`.
- Validated event-stream construction now rejects an event codec whose schema
  version, event tags, or upcaster chain fail `mkCodec`. Restore missing rungs
  or deduplicate conflicting sources before deployment; for emergency
  forensics only, `mkEventStreamUnchecked` remains the explicit bypass.

### Added

- `keiro-dsl` now lowers same-version event upcasters into one
  `EventType`-dispatching rung, so unrelated event kinds pass through
  unchanged, and supports `diff --emit-goldens DIR` plus
  `scaffold --goldens DIR` to capture and embed genuine old payload shapes in
  generated conformance harnesses.
- Scaffolded workqueues now include a `QueueCodec` module with a versioned
  `keiroJobCodec` envelope from schema version 1. Fresh queues need no migration;
  drain a queue before replacing an existing bare-payload codec (or use a
  transitional codec) so in-flight messages are not dead-lettered.
- `keiro-dsl check` now rejects duplicate and incomplete aggregate upcaster
  chains, supports a mutually exclusive `retiring event` marker, and warns
  when deprecated events lack the replay-only transition required to hydrate
  old payloads.
- `keiro-dsl diff` now reports vanished upcaster rungs as breaking and
  distinguishes hazardous event deprecation from the replay-safe
  deprecated-plus-replay-only cutover. Versioned old-payload JSON goldens now
  exercise `decodeRaw` in the v2 conformance suite.
- `defaultStateCodec` derives a control-state discriminator through Keiki's
  `CanonicalStateShape`; `withFoldFingerprint` composes an explicit fold token
  as `<state-hash>;fold=<fingerprint>`.
- `keiro-dsl` derives a deterministic fingerprint from aggregate states,
  register initials, transitions, and referenced rules, lowers it into
  generated snapshot codecs, and emits the non-breaking
  `AggFoldSurfaceChanged` advisory when that replay surface evolves.
- `keiro`: `Keiro.version` now reports the current package version. It had
  been left at `"0.1.0.0"` since the initial scaffold while the package
  shipped 0.2.0.0 and 0.3.0.0; keep it in lockstep with `keiro/keiro.cabal`
  when cutting a release.

### Fixed

- Workflows using journal snapshots no longer suspend forever when a child,
  awakeable, or sleep completion was journaled while a run was mid-flight but
  omitted from that run's snapshot. The `awaitStep` miss path now falls back to
  the authoritative workflow-step index before arming and suspending.

## 0.3.0.0 — 2026-07-14

A dependency-realignment release across the package set. `keiro-migrations` and
`keiro-pgmq` now sit on one `pg-migrate` 1.1 family together with Kiroku, so a
single ledger owns the kiroku, keiro, and pgmq migration components. `keiro-core`,
`keiro`, and `keiro-dsl` have no source changes and are released at 0.3.0.0 to
stay in lockstep with the set.

With this release every dependency in the default build plan resolves from
Hackage: `codd` and `codd-extras` remain the only non-Hackage packages, and they
are reachable only through the manual `legacy-codd-tools` flag, which is off by
default.

### Breaking Changes

- `keiro-migrate check` now takes the manifest as `--manifest PATH` instead of a
  positional argument, following the `pg-migrate-cli` 1.1.0.0 parser.
- `Keiro.Test.Postgres.withMigratedSuiteWith` now takes `[MigrationComponent]` —
  extra `pg-migrate` components appended to the framework plan — instead of a
  `Text -> IO ()` hook that ran its own migration against the template database.
  A `pg-migrate` ledger is shared by every component in it, so a second plan that
  omitted Kiroku's and Keiro's components failed strict verification with
  `UnknownStoredMigration`. Suites that installed extra schema (such as PGMQ) now
  pass the component itself: `withMigratedSuiteWith [pgmqMigrations]`.

### Changed

- Upgraded `kiroku-store` to 0.3.0.1, `kiroku-store-migrations` to 0.3.0.0, and the
  `pg-migrate` package family to 1.1.0.0 in `keiro-migrations` and
  `keiro-test-support`. This realigns Keiro's pg-migrate version with the one
  Kiroku's migration component requires — the previous `^>=1.0.0.0` bounds excluded
  pg-migrate 1.1 and so could not resolve alongside `kiroku-store-migrations` 0.3.
  From `kiroku-store` 0.3.0.1, a failure raised inside an opaque `runTransaction`
  body now preserves its SQLSTATE and server message instead of surfacing as
  `StreamNotFound (StreamName "<transaction>")`.
- Upgraded `keiro-pgmq` to `shibuya-pgmq-adapter` 0.12.0.0 and the `pgmq-*` 0.4
  package family, which is what aligns the PGMQ path with pg-migrate 1.1. The
  adapter's own API is unchanged; the notable fix is that idle streams now observe
  shutdown, so a processor with nothing to consume finishes on request instead of
  polling until it is forcibly cancelled. `shibuya-core` stays at 0.8.0.1 (already
  the latest).
- Dropped the `hasql-migration` `source-repository-package` pin from
  `cabal.project`. It existed only because `pgmq-migration` 0.3 depended on
  `hasql-migration`, whose Hackage release does not build against hasql 1.10;
  `pgmq-migration` 0.4 is a native `pg-migrate` component and nothing in the build
  plan depends on it now.

## 0.2.0.0 — 2026-07-13

A major release across the package set. The headline changes are the relocation
of Keiro's framework tables into a dedicated `keiro` PostgreSQL schema, stricter
replay-contract validation on the Keiki 0.2 core, durable dead letters for
rejected dispatches, and a substantially expanded `keiro-dsl` spec surface
(read models, routers, snapshots, queue ordering, and workflow evolution).

### Breaking Changes

- **Keiro's framework tables moved out of the `kiroku` schema into a new,
  dedicated `keiro` PostgreSQL schema that Keiro creates and owns.** Every
  runtime query is now schema-qualified (`keiro.keiro_snapshots`,
  `keiro.keiro_timers`, `keiro.keiro_outbox`, …) and no longer depends on
  `search_path`. `keiro-core` exports the new `Keiro.Schema.keiroSchema` as the
  single source of truth for the name. Existing databases must run the
  `keiro-migrations` bootstrap, which creates the schema and relocates the
  tables; application SQL that read bare `keiro_*` relations must be re-qualified.
- `runCommandWithSql`, `runCommandWithSqlEvents`,
  `runCommandWithProjections`, and the process-manager/router runners now
  require `KirokuStoreResource` so transactional appends can apply Kiroku's
  configured `enrichEvent` hook. Acquire the store with `withKirokuStore` and
  interpret `Store` with `runStoreResource`; plain `runCommand` is unchanged.
- Read-model queries no longer auto-register missing registry rows. Applications
  must call `registerReadModel` at projection startup; unknown models now return
  `ReadModelUnregistered` without mutating the registry.
- `ReadModel` now requires a `strongScope :: StrongScope` field. Use
  `EntireLog` for all-stream subscriptions or `CategoryHead category` for a
  category subscription so unrelated traffic cannot hold `Strong` reads behind.
- `ReadModel` now also requires a `schema :: Text` field naming the PostgreSQL
  schema its data table lives in. Keiro does not rewrite `query`; qualify the
  application's SQL with `qualifiedTableName` or `Keiro.Connection.qualifyTable`.
  The field is Haskell-level wiring only and is deliberately not persisted in the
  `keiro.keiro_read_models` registry.
- `AsyncProjection` now requires `readModelName`, naming the registry row that
  fences writes during a rebuild.
- `PMCommandResult.PMCommandFailed` now carries the target `StreamName` alongside
  its `CommandError`, so worker policy can identify the failing target.
- `WorkerOptions` gains a `rejectedCommandPolicy :: RejectedCommandPolicy` field,
  and `ShardedWorkerOptions` gains `handlerRetryDelay :: RetryDelay` and
  `retryPolicy :: RetryPolicy`. Record construction must supply them; the
  `defaultWorkerOptions` and `defaultShardedWorkerOptions` defaults are unchanged
  in behavior.
- `applyAsyncProjection` now returns `AsyncApplyOutcome` (`AsyncApplied`,
  `AsyncDuplicate`, or `AsyncFenced`) and live workers must not checkpoint a
  fenced event. Rebuild replayers use `applyAsyncProjectionUnfenced` between the
  new atomic `startRebuild` and guarded `finishRebuild` helpers.
- `keiro-migrations` now exports a native `pg-migrate` component and composes
  Kiroku through an explicit component dependency instead of a combined Codd
  migration-set API.
- Router deterministic command ids are now derived from the resolved target
  stream name and same-stream occurrence rather than the target's list position.
  A transition point-probe recognizes legacy positional ids for stable resolver
  output and may be removed in a later release. If both the deployment version
  and resolver output change between attempts, a target command may be
  dispatched at most one extra time across that one-time upgrade window.
- `runWorkflow`, `runWorkflowWith`, and the child-workflow runtime now require
  `Error StoreError` in their effect rows so post-commit workflow snapshot
  failures can be caught without leaving the typed error channel.
- `mkEventStream` now rejects snapshot codecs that cannot encode their initial
  state and register file. Snapshot-enabled streams built from
  `emptyRegFile` must initialize every slot before validation.
- Keiro now requires post-MP-16 Keiki 0.2. Stream validation runs the new
  head-recoverability, inversion-ambiguity, unguarded-input-read, and
  state-changing-silent-edge checks; any warning makes `mkEventStream` reject
  the stream at startup.
- `HydrationReplayFailed` now carries a typed `HydrationReplayReason` alongside
  the failing stream version. The reasons distinguish no inverting edge,
  ambiguous inversion, queue mismatch, and a truncated multi-event chain.
  `CommandError` also gains `CommandAmbiguous`, carrying matched edge indices.
- A command matching multiple transitions is now reported as
  `CommandAmbiguous` instead of `CommandRejected`. Process managers and routers
  halt on this aggregate-definition bug, while generated timer dispositions
  route it through their on-error arm rather than benign on-reject handling.
- The `hydration_replay_failed` telemetry class is replaced by four
  reason-specific `error.type` values, and `command_ambiguous` is new.
  Dashboards keyed on the old hydration class must be updated.
- `validateEventStreamWith` and `mkEventStreamWith` now force-enable Keiki's
  head-recoverability and state-changing-epsilon checks. Caller-supplied
  options may only strengthen validation at Keiro's durable boundary; use the
  explicitly unsafe `mkEventStreamUnchecked` only for tests and emergency
  forensics, never production streams.
- `keiro-dsl`: the process `saga` clause is now
  `saga <Aggregate> category "<camelCase>"`, replacing
  `saga <Aggregate> stream="<prefix>-" <> correlationId`; `process` nodes must
  declare node-level `rejected` and `poison` policies; every timer `fire`
  disposition must carry an `on-ambiguous` arm; identifiers are restricted to
  ASCII and checked for Haskell hygiene; and numeric literals exceeding
  `maxBound :: Int` are rejected instead of silently wrapping. Validation is
  substantially stricter overall, so specs that checked under 0.1.0.0 may now be
  rejected. See `keiro-dsl/CHANGELOG.md` for the full list.
- `keiro-dsl`: `scaffold` now plans the whole module set before writing any byte
  and refuses to overwrite a `Generated` path lacking the `@generated` banner
  (override with `--force-generated-overwrite`). `diff` gained a `WARNING:` tier
  and reformatted its change lines; only `BREAKING:` changes exit non-zero.

### New Features

- Durable dispatch dead letters. New `Keiro.DeadLetter`,
  `Keiro.DeadLetter.Schema`, and `Keiro.DeadLetter.Replay` modules let
  process-manager and router workers park a rejected dispatch instead of halting.
  `RejectedCommandPolicy` selects `RejectedHalt` (the default),
  `RejectedDeadLetter` (persist to the new `keiro.keiro_dead_letters` table and
  acknowledge), or `RejectedSkip`. `replaySubscriptionDeadLetters` re-runs a
  caller-supplied handler over the rows Kiroku parked in `kiroku.dead_letters`
  without deleting or mutating those Kiroku-owned rows.
- New `Keiro.Connection` module for application read-model and projection tables:
  `qualifyTable`, `quoteIdentifier`, `withProjectionSchema`,
  `keiroConnectionSettings`, and the opt-in `ensureProjectionSchema`. The store
  connection's `schema` stays `kiroku` because it drives the `LISTEN`/`NOTIFY`
  channel; a projection schema is reached by qualification and/or
  `extraSearchPath`.
- Acknowledgement-aware sharded subscriptions: `runShardedSubscriptionGroupAck`
  with `ShardAck`, `ShardDelivery`, and `ShardEventHandler`, plus per-event retry
  and dead-letter dispositions. `runShardedSubscriptionGroup` remains as the
  compatibility wrapper.
- New telemetry: `keiro.dispatch.deadlettered`, `keiro.subscription.deadlettered`,
  `keiro.snapshot.encode.failures`, `keiro.snapshot.decode.failures`,
  `keiro.snapshot.read.hits`, `keiro.snapshot.read.misses`, and
  `keiro.snapshot.apply.divergence`. `Keiro.Telemetry.kirokuEventBridge` installs
  on Kiroku's `eventHandler` to observe the terminal retry-exhaustion signal.
- `keiro-dsl` gained a first-class `readmodel` node (typed columns, shape-hash
  drift detection, consistency/scope/feed validation) and a `router` node for
  stateless content-based routing, both with generated runtime modules and typed
  holes. Query operations and PGMQ dispatch dedup references now genuinely resolve
  against declared read models — they were deferred no-ops in 0.1.0.0.
- `keiro-dsl` gained aggregate `snapshot` policies with a captured state-codec
  fixture, workqueue `ordering` and provisioning (FIFO, group keys, unlogged,
  partitioned), intake `persist` posture, and durable-workflow evolution via
  guarded `patch` blocks and terminal `continueAsNew`. `diff` was rebuilt on an
  exhaustive node-family registry, so a new node kind can no longer be silently
  classified as safe.
- `keiro-migrations` appended `0018`, creating `keiro.keiro_dead_letters`.

### Bug Fixes

- Sharded subscription readers now acknowledge each event only after its handler
  returns. A shed or rebalanced bucket's checkpoint can no longer cover an
  unprocessed event.
- `keiro-dsl` string literals now decode and re-render the closed DSL escape set,
  so topics, emit maps, and quoted field bindings survive a parse/pretty-print
  round trip. The scaffolder also escapes payload literal splices, closing a
  template-injection path where a quoted spec literal could break out of the
  generated Haskell string.

### Other Changes

- Command hydration now detects stream-version gaps caused by Kiroku
  per-stream truncation and returns `HydrationGapDetected` unless a snapshot
  covers the hidden prefix.
- Transactional command runners now apply Kiroku's configured `enrichEvent`
  hook before event preparation, so persisted events and the
  `runCommandWithSqlEvents` callback observe the same enriched metadata as
  plain `runCommand`.
- The shared PostgreSQL test fixture now provisions templates through the
  native Kiroku/Keiro migration plan. Codd transition and remediation tests are
  retained behind the manual `legacy-codd-tools` flag.
- Router and process-manager duplicate-event rejections are now confirmed
  against the intended target stream before being treated as benign.
  Unconfirmed cross-stream or id-less collisions surface as command failures,
  causing workers to halt instead of silently dropping a dispatch.
- Aggregate snapshot encoding is forced before the store write. An `ErrorCall`
  from a partial state encoder or uninitialized register is swallowed after the
  event append and counted instead of escaping a successful command.
- Workflow snapshot writes after steps, completion, and continue-as-new
  rotation are advisory: store failures are swallowed and counted after the
  journal append commits.
- Added `keiro.snapshot.encode.failures`,
  `keiro.snapshot.decode.failures`, `keiro.snapshot.read.hits`, and
  `keiro.snapshot.read.misses`; snapshot lookup APIs now retain miss and decode
  reasons while compatibility wrappers preserve the previous `Maybe` surface.
- Corrected snapshot documentation: version non-regression applies within one
  codec version and shape hash, while an incompatible codec can replace a newer
  row to permit rollback. Upgrade notes cover the full-replay miss caused by
  Keiki EP-78's stable shape hash.
- Kiroku 0.3/0.2, Keiki 0.2, and pg-migrate 1.0 now resolve from Hackage; their
  obsolete Git package overrides and local Cabal overlay are no longer needed.
- `RunCommandOptions.verifyReplayOnAppend` defaults on. Both command append
  paths replay each just-committed batch from the pre-command state, count an
  unreplayable batch through `keiro.snapshot.apply.divergence`, and attach a
  bounded typed reason to `keiro.replay.divergence` without turning an already
  committed command into a reported failure.
- No-op commands now report `CommandResult.globalPosition = Nothing` instead
  of exposing Kiroku's per-stream-read sentinel `GlobalPosition 0`. Appended
  commands continue to report the real store-assigned position.
- Exported additional runtime helpers so custom workers can reuse the framework's
  classification logic: `commandErrorClass`, `isRejectionClass`,
  `decideForFailures`, `DispatchFailure`, `confirmBenignDuplicate`,
  `deterministicRouterCommandId`, `ReadModel.categoryHeadPosition`,
  `ReadModel.qualifiedTableName`, `StrongScope`, and `RebuildError`.
- Documented previously implicit runtime contracts: the inbox deduplication window
  closes when `garbageCollectCompleted` removes a completed row; outbox
  `created_at` is transaction-start time, so `PerKeyHeadOfLine` and
  `PerSourceStream` ordering is best-effort unless the caller serializes same-key
  enqueues; the default timer worker has no attempt ceiling and requeues claims
  left `Firing` for five minutes; and process-manager `correlate` joins across
  streams must be order-insensitive.
- Added upper bounds alongside the move to Hackage: `keiki >=0.2 && <0.3`,
  `keiki-codec-json >=0.2 && <0.3`, and `kiroku-store >=0.3 && <0.4`.
- `keiro-dsl` added conformance suites that round-trip every node family, compile
  every `keiro-dsl new <kind>` starter, and cold-start the new read-model, router,
  snapshot, queue-ordering, and workflow-rotation surfaces against the live
  runtime.

## 0.1.0.0 — 2026-07-05

Initial Hackage release of the Keiro package set.

### Breaking Changes

- Established `ValidatedEventStream` as the command-boundary contract for the
  runtime packages. Existing pre-release git users should construct validated
  streams with `mkEventStream`, `mkEventStreamWith`, or `mkEventStreamOrThrow`.
- Finalized the `keiro-core` stream, codec, and event-stream contracts for the
  first public package set.
- Renamed the typed-spec file extension from `.kdsl` to `.keiro` before the first
  public `keiro-dsl` release.

### New Features

- `keiro-core`: shared typed contracts for streams, codecs, event streams,
  replay-safety validation, integration events, and snapshot policies.
- `keiro`: command runners, projections, read models, snapshots, process
  managers, routers, timers, outbox/inbox integrations, subscription workers,
  telemetry, and durable workflows.
- `keiro-pgmq`: typed PGMQ jobs, codecs, runtime workers, retry and DLQ
  policies, FIFO/message-group support, queue provisioning, metrics, and trace
  propagation.
- `keiro-migrations`: embedded codd migrations and the `keiro-migrate`
  executable for installing and upgrading Keiro database schema.
- `keiro-dsl`: parser, checker, diff engine, scaffold generator, harness emitter,
  configurable module placement, starter skeletons, and conformance suites for
  `.keiro` specifications.

### Bug Fixes

- Hardened runtime behavior across command retries, snapshots, projections,
  process-manager/router dispatch, timers, subscriptions, workflows, and
  inbox/outbox recovery.
- Fixed PGMQ job decode handling, retry tuning validation, queue-name
  disambiguation, and direct job draining without the shibuya runner.

### Other Changes

- Added release metadata, documentation, Haddocks, user guides, migration guides,
  operational references, and guide-backed examples across the package set.
