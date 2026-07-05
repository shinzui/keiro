# Changelog

All notable changes to `keiro-migrations` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the package follows the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## [Unreleased]

### Breaking Changes

- **Keiro's framework tables moved out of the `kiroku` schema into a new,
  dedicated `keiro` PostgreSQL schema that Keiro creates and owns.** The
  bootstrap migration now issues `CREATE SCHEMA IF NOT EXISTS keiro`, and every
  migration creates its objects schema-qualified as `keiro.<table>` with **no**
  `SET search_path` pin and no explanatory comment. The `keiro-migrate new`
  scaffolder emits that qualified, comment-free template.
- The codd expected-schema drift gate is now scoped to the `keiro` namespace
  (`CODD_SCHEMAS=keiro`), contains only `keiro_*` objects, and is **portable**:
  the captured database role and owner are a deterministic pinned `keiro`
  identity rather than the local operating-system user, so
  `cabal test keiro-migrations-test` passes on any machine and in CI.
- Read-model and projection tables now support a **configurable schema**: an
  application declares the schema its read-model/projection tables live in (a
  `schema` field on `ReadModel` plus the `Keiro.Connection` helpers), instead of
  implicitly inheriting the store connection's `search_path`. This is
  Haskell-level configuration only — no new database column and no new migration.

### Upgrade

- A database first migrated by `0.1.0.0` has its `keiro_*` tables in `kiroku`. It
  requires a **one-time remediation** before running these migrations: follow
  [Upgrading To The Keiro Schema](../docs/user/upgrading-to-the-keiro-schema.md),
  which wraps the tested script
  `keiro-migrations/remediation/2026-07-05-relocate-keiro-tables-to-keiro-schema.sql`.
  The script relocates the tables (`ALTER TABLE ... SET SCHEMA keiro`) in one
  transaction and needs no codd-ledger change (migration filenames are unchanged,
  so codd re-runs nothing). Fresh and ephemeral databases need no remediation.

### Recommended Version Bump

- Cut the next release as **`0.2.0.0`**. This is a breaking change; the package
  follows the Haskell PVP, where the leading `A.B` components form the "major"
  version and must increment on any breaking change, so `0.1` → `0.2` is the
  minimal PVP-correct major bump for a pre-1.0 package (the README already warns
  the API is unstable/alpha, so a pre-1.0 major bump is appropriate). The actual
  `version:` edit in `keiro-migrations/keiro-migrations.cabal` is a release action
  to perform when the release is cut, not part of these changes.

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
