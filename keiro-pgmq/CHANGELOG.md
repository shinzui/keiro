# Changelog

All notable changes to `keiro-pgmq` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the package follows the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## [Unreleased]

_No unreleased changes._

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
