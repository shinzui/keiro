# Changelog

All notable changes to `keiro-pgmq` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the package follows the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## [Unreleased]

_No unreleased changes._

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
