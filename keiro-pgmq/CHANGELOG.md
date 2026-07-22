# Changelog

All notable changes to `keiro-pgmq` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the package follows the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## [Unreleased]

### Fixed

- One-shot job processing (`runJobOnce` and `runJobOnceWithContext`) now continues the
  producer's trace instead of leaving a hole between the enqueue and settlement spans.
  Each claimed message extracts the W3C `traceparent` that `enqueueTraced` stored in the
  PGMQ `headers` column, installs it as a remote parent, and runs the handler inside one
  Consumer-kind `<jobName> process` span. The span carries the same common surface as the
  continuous `runJobWorkers` path — `messaging.system`, `messaging.destination.name`,
  `messaging.operation.type`, `messaging.message.id`, `shibuya.partition` for FIFO
  deliveries, and `shibuya.ack.decision` recorded only after the finalizing PGMQ statement
  returns, with `OK` for `Done`/retry and `ERROR` for dead-lettering. A handler that throws
  is recorded as an exception with an `ERROR` status and no acknowledgement attribute.
  Deliveries carrying no usable trace header still get exactly one span.

  Deliberately absent: the `shibuya.inflight.*` gauges the continuous path reports. A
  bounded drain has no shibuya inbox and no concurrency meter to describe.

  No public API, function signature, delivery semantic, queue behavior, PGMQ header shape,
  or wire payload changed — downstream applications gain trace continuity by rebuilding.

## 0.3.0.0 — 2026-07-14

### Changed

- Upgraded to `shibuya-pgmq-adapter` 0.12.0.0 and the `pgmq-*` 0.4 package family
  (`pgmq-core`, `pgmq-config`, `pgmq-effectful`, `pgmq-hasql`, and `pgmq-migration`
  in the test suite). `keiro-pgmq`'s own API is unchanged. The adapter's 0.12 fix
  makes idle streams observe shutdown: a processor with nothing to consume now
  finishes on request instead of polling until it is forcibly cancelled.
- The test suite installs the PGMQ schema by appending `pgmq-migration`'s native
  `pgmqMigrations` component to the suite's framework plan, rather than calling the
  `migrate` runner that `pgmq-migration` 0.4 removed. One pg-migrate ledger now owns
  the kiroku, keiro, and pgmq components together.

## 0.2.0.0 — 2026-07-13

No user-facing changes. `keiro-pgmq` is released at 0.2.0.0 to stay in lockstep
with the rest of the Keiro package set, and is rebuilt against `keiro-core`
0.2.0.0. Consumers should note that the stricter event-stream validation and the
relocation of Keiro's framework tables into the dedicated `keiro` PostgreSQL
schema — both described in the `keiro-core` and `keiro` changelogs — apply to any
application that wires this package's workqueue and dispatch workers.

## 0.1.0.0 — 2026-07-05

Initial Hackage release.

### New Features

- Added typed PGMQ job definitions, payload codecs, runtime workers, job worker
  context, retry and dead-letter policies, and direct job draining.
- Added queue provisioning, FIFO ordered delivery via message groups, producer
  headers, batch enqueue support, queue metrics, archive/retention APIs, DLQ
  inspection, and redrive helpers.
- Added trace propagation through PGMQ job producer and worker paths.

### Bug Fixes

- Classified job decode failures, validated retry tuning, disambiguated long
  queue names, and isolated integration-test databases.

### Other Changes

- Tightened the internal `keiro-core` dependency bound to `^>=0.1.0.0`.
