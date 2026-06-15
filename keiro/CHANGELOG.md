# Changelog

All notable changes to the `keiro` library are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
the [Haskell Package Versioning Policy](https://pvp.haskell.org/).

## [Unreleased]

_In-flight work is tracked under `docs/plans/`. Entries land here as features merge, so
consumers of `keiro` can see what changed and what they need to update._

### Added

- `Keiro.EventStream.Validate`: `validateEventStream` / `validateEventStreamWith` run keiki's
  pure `validateTransducer` over an `EventStream`'s transducer (replay-safety + determinism +
  dead-edge), returning labelled `EventStreamWarning`s; `mkEventStream` is a fail-fast smart
  constructor returning `Left [EventStreamWarning]` for an unsafe stream. The bare `EventStream`
  record literal remains available. Validation requires the control state to satisfy
  `(Bounded s, Enum s, Ord s, Show s)`.
- `Keiro.ProcessManager`: `WorkerOptions`, `PoisonPolicy`, `defaultWorkerOptions`,
  `runProcessManagerWorkerWith`, and the dispatch-error classifier helpers. Existing
  `runProcessManagerWorker` keeps its signature and delegates to the default options.
- `Keiro.Router`: `runRouterWorkerWith`, sharing the process-manager worker options.
- `Keiro.Telemetry`: dispatch counters `keiro.dispatch.failed`,
  `keiro.dispatch.duplicates`, and `keiro.dispatch.poison`, plus recording helpers.

### Changed

- Bumped the pinned `keiki` dependency to a commit that ships `validateTransducer` and the
  structured `TransducerValidationWarning` (keiki EP-56), which the new validation surface builds
  on. The previously pinned `keiki` predated that work.
- Process-manager and router workers now finalize every Shibuya `AckHandle` exactly once.
  Successful and duplicate dispatches ack `AckOk`, transient store failures `AckRetry`,
  deterministic failures `AckHalt`, and undecodable messages follow the configured
  `PoisonPolicy`.
- `eventAlreadyIn` now uses kiroku's `eventExistsInStream` point lookup instead of scanning a
  whole stream. Concurrent duplicate writes are folded to `PMCommandDuplicate` /
  `PMStateDuplicate` through kiroku's `DuplicateEvent` mapping.

## 0.1.0.0 — 2026-05-22

The initial release of `keiro`, an event-sourcing framework and workflow engine
that composes the kiroku event store, the keiki aggregate core, and the shibuya
worker substrate.

### New Features

- **Command side** (`Keiro.Command`, `Keiro.EventStream`, `Keiro.Stream`): the
  single-stream write path. `runCommand` hydrates a stream (snapshot + replay),
  runs the keiki transducer one step, and appends the emitted event(s) under
  optimistic concurrency with bounded retry. `RunCommandOptions` controls
  `retryLimit`, `pageSize`, forced `eventIds` (for deterministic, idempotent
  appends), `beforeAppend`, `tracer`, and `metadata` (ambient JSON merged into
  every event's metadata). Multi-event command output is supported, and
  `runCommandWithSql` / `runCommandWithSqlEvents` run a caller-supplied `hasql`
  action in the same transaction as the append. `EventStream` bundles a
  transducer with its initial state/registers, event codec, stream-name
  resolver, and snapshot policy; `Stream` is the typed stream-name newtype.
- **Event evolution** (`Keiro.Codec`): typed event codecs with event-type tags
  and a `schemaVersion` metadata marker, plus ordered `upcasters` that migrate
  older payloads forward on read.
- **Snapshots & hydration** (`Keiro.Snapshot`, `…Policy`, `…Codec`, `…Schema`):
  advisory snapshots. A `SnapshotPolicy` (`Never`, `Every n`, `OnTerminal`,
  `Custom`) decides when to persist; hydration seeds from the latest snapshot and
  replays only the tail. `defaultStateCodec` derives a JSON state codec.
- **Read models & projections** (`Keiro.ReadModel`, `…Rebuild`, `…Schema`,
  `Keiro.Projection`): inline projections updated in the append transaction
  (`runCommandWithProjections`; they receive the `RecordedEvent`, so they can
  read event metadata such as actor / source-event id) and async projections.
  `runQuery` supports consistency modes `Strong`, `Eventual`, and `PositionWait`
  (cursor wait). Read models are registered with schema-version / shape-hash
  guarding and have a rebuild lifecycle (`rebuild` → `promote` /
  `abandonRebuild`).
- **Process managers & timers** (`Keiro.ProcessManager`, `Keiro.Timer`): stateful
  event→command fan-out. A process manager keeps its own state stream and a
  correlation id, advances on each input, and dispatches commands to a target
  aggregate with crash-safe, exactly-once-per-target idempotency (deterministic
  command ids plus a duplicate pre-check). Database-backed timers
  (`scheduleTimerTx`, `runTimerWorker`) can be scheduled transactionally from a
  process manager.
- `Keiro.Router`: a new stateless, effectful fan-out primitive — the Enterprise
  Integration Patterns *content-based Router* / dynamic *Recipient List* paired
  with the existing `Keiro.ProcessManager`. Where a process manager computes its
  targets purely (`handle`), a router resolves them *effectfully*, so the target
  set can be looked up from a read model (`Keiro.ReadModel.runQuery`) rather than
  derived from the event alone. Exposed (and re-exported from `Keiro`):
    - `Router (..)` — a record carrying `resolve :: input -> Eff es [PMCommand targetCi]`,
      a `key` correlation function, and the `targetEventStream`. It has no state
      stream, no `correlate`, and no self-command.
    - `RouterResult (..)` — the per-target `PMCommandResult` list from one run.
    - `runRouterOnce` — resolve the targets for a source event, then dispatch one
      command per target with the same crash-safe, exactly-once-per-target
      idempotency the process manager provides (deterministic command ids via
      `deterministicCommandId` plus a duplicate pre-check), so replay writes
      nothing new.
    - `runRouterWorker` — drive a `Router` as a live subscription over a Shibuya
      `Adapter`, with a documented ack policy (decode failure or any
      `PMCommandFailed` → `AckHalt`; otherwise `AckOk`). Unlike
      `runProcessManagerWorker`, it invokes the ingested message's
      `AckHandle.finalize` with the decision, so the ack policy reaches the
      adapter.
- `Keiro.ProcessManager`: now exports `eventAlreadyIn`, the idempotency
  pre-check, so routers (and other callers) can reuse it. Its behavior is
  unchanged.
- **Transactional outbox** (`Keiro.Outbox`, `…Kafka`, `…Schema`, `…Types`): a
  durable integration-event outbox. Enqueue events in the same transaction as the
  domain write, then `claimOutboxBatch` / `publishClaimedOutbox` with per-key
  (head-of-line) ordering, backoff scheduling, and dead-lettering after a
  max-attempt count; ships a Kafka producer adapter.
- **Idempotent inbox** (`Keiro.Inbox`, `…Kafka`, `…Adapter`, `…Schema`,
  `…Types`): dedupes inbound integration events, with claim/retry/release/dead
  transitions, GC of completed rows (`garbageCollectCompleted`), transaction
  wrappers (`runInboxTransaction` / `…WithKey`), a Shibuya adapter, and a Kafka
  consumer adapter.
- **Integration events** (`Keiro.Integration.Event`): a canonical cross-context
  event envelope (message id, source / destination, schema reference, content
  type, W3C trace context, source-event id / global position) with JSON
  encode/decode and Kafka header helpers.
- **OpenTelemetry instrumentation** (`Keiro.Telemetry`): spans following the
  messaging / database semantic conventions — an Internal-kind span around
  `runCommand`, a Producer span around outbox publishing, and Consumer spans
  parented via W3C trace headers. Opt-in through `RunCommandOptions.tracer`;
  span helpers (`withCommandSpan`, `withProducerSpan`, `withConsumerSpan`) and
  trace-context propagation are exported for adapters.

### Other Changes

- **Schema migrations**: the `keiro-migrations` package embeds the framework DDL
  as codd SQL migrations and ships a `keiro-migrate` executable that runs the
  kiroku and keiro migrations together.
- **Documentation**: the `jitsurei` worked-examples package and the long-form
  guides under `docs/guides/` (command side, event evolution, read models,
  process managers & timers, snapshots, integration events with Kafka, routers,
  and a combined incident-response example pairing a router with a process
  manager).
