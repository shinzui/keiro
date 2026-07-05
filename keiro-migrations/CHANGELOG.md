# Changelog

All notable changes to `keiro-migrations` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the package follows the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## [Unreleased]

_No unreleased changes._

## 0.1.0.0 — 2026-07-05

Initial Hackage release.

### New Features

- Added embedded codd migrations and the `keiro-migrate` executable for Keiro
  schema installation and upgrades.
- Added framework schema for read models, snapshots, timers, outbox, inbox,
  subscriptions, projections, durable workflows, workflow children, awakeables,
  workflow instances, recovery indexes, and maintenance helpers.
- Added expected-schema drift checks and a local-development no-check migration
  runner.

### Bug Fixes

- Aligned with kiroku schema dependencies and added messaging crash-recovery
  schema updates.
