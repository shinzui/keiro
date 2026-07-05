# Changelog

All notable changes to the `keiro` library are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
the [Haskell Package Versioning Policy](https://pvp.haskell.org/).

## [Unreleased]

_No unreleased changes._

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
