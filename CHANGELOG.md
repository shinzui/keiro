# Changelog

All notable changes to the Keiro package set are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/), and the published
packages follow the [Haskell Package Versioning Policy](https://pvp.haskell.org/).

## [Unreleased]

_No unreleased changes._

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
