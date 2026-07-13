# Changelog

All notable changes to the Keiro package set are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/), and the published
packages follow the [Haskell Package Versioning Policy](https://pvp.haskell.org/).

## [Unreleased]

### Breaking Changes

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

### Other Changes

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
