# Changelog

All notable changes to `keiro-migrations` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the package follows the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## [Unreleased]

## 0.10.0.0 — 2026-08-03

No changes this release. Released with the package set for the `keiro-dsl`
0.10.0.0 work.

## 0.9.0.0 — 2026-08-02

No changes this release. Released with the package set for the `keiro-dsl`
0.9.0.0 work.

## 0.8.0.0 — 2026-08-01

No changes this release. Version moves with the package set.

## 0.7.0.0 — 2026-08-01

No changes this release. Released with the package set for the `keiro-dsl`
0.7.0.0 work.

## 0.6.0.0 — 2026-07-31

No changes this release. Released with the package set for the `keiro-dsl`
0.6.0.0 work.

## 0.5.0.0 — 2026-07-31

No changes this release. Released with the package set for the `keiro-dsl`
0.5.0.0 whole-workspace work.

## 0.4.0.1 — 2026-07-28

### Other Changes

- Adds PVP upper bounds to every dependency that previously carried a lower
  bound only, so `cabal check` reports no packaging warnings. No API or
  behaviour change from 0.4.0.0, which was tagged but never published.


## 0.4.0.0 — 2026-07-28

### Breaking Changes

- `keiro-migrate up` now refuses to initialize an absent or empty native
  `pgmigrate` ledger over a detected Codd ledger. Import the verified Codd
  history first, or use `--allow-fresh-ledger-over-codd` only when deliberately
  abandoning that history.

### New Features

- Adds the read-only `missingMigrations` startup handshake so every application
  replica can reject pending, corrupt, or unknown migration history before
  serving traffic.
- Adds a canonical PostgreSQL 18 schema snapshot and `keiro-migrate
  verify-schema`, which reports missing, unexpected, or changed objects in the
  live `keiro` schema.
- Adds `keiro-migrate import-codd-history`, with exact Kiroku/Keiro payload
  mappings, advisory locking, confirmation, structured reports, and recovery
  coverage for interrupted or poisoned imports.

### Bug Fixes

- Embedded migration changes now force GHC recompilation through
  `pg-migrate-embed`, preventing an incremental build from retaining stale SQL
  or manifest bytes.
- Default conformance again lints every embedded migration for schema
  qualification and forbidden `search_path` dependence, and pins the native
  payload lock against accidental edits.

## 0.3.0.0 — 2026-07-14

### Breaking Changes

- `keiro-migrate check` now takes the manifest as `--manifest PATH` instead of a
  positional argument, matching `new --manifest`. This follows the `pg-migrate-cli`
  1.1.0.0 parser, and matches the same change in `kiroku-store-migrate check`.

### Changed

- Upgraded to `pg-migrate` 1.1.0.0 and `kiroku-store-migrations` 0.3.0.0, keeping
  the pg-migrate version aligned with the one Kiroku's migration component
  requires. `keiro-migrate up` and `repair` now accept `--wait` and
  `--no-statement-timeout` overrides; omitting an execution flag preserves the
  configured runner settings instead of discarding them. A durably successful
  migration, repair, or history-import run is now preserved with its cleanup
  observations attached, rather than replaced by an error, when advisory unlock or
  statement-timeout restoration fails.

## 0.2.0.0 — 2026-07-13

### Added

- Appended `0018`, creating `keiro.keiro_dead_letters`. It durably records
  process-manager and router dispatches that reached a target stream and were
  rejected. These rows are distinct from `kiroku.dead_letters`: the source
  subscription event is successfully handled and checkpointed only after every
  rejected dispatch has been recorded. The `keiro` package reads and replays them
  through `Keiro.DeadLetter`.
- Appended `0017-schema-management-comment`, an observable non-destructive
  native-runner canary. The combined-history fixture proves Kiroku `0008`
  completes before Keiro `0017`, then strict verification and reruns succeed.

### Breaking Changes

- Replaced the public Codd runner surface with native `pg-migrate` APIs.
  `keiroMigrations` now returns the `keiro` `MigrationComponent`, and
  `frameworkMigrationPlan` composes concrete Kiroku and Keiro components in
  dependency order. The standard `keiro-migrate` CLI now uses the `pgmigrate`
  ledger.
- Renamed the sixteen embedded migrations to stable component-local identifiers
  under `migrations/manifest` while preserving every legacy SQL payload byte.
  Timestamped filenames and `migrations.lock` remain import evidence only.
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

- Added atomic Codd history import for the shared Kiroku/Keiro ledger. Both
  components' exact payload maps, manifests, and 23 mappings are validated in
  one adapter call; strict verification succeeds without replaying target SQL.
- Moved Codd expected-schema, remediation, and ledger-fixup behavior behind the
  manual `legacy-codd-tools` flag. The normal library, executable, and shared
  test fixture no longer depend on `codd`, `codd-extras`, `file-embed`, or
  `postgresql-simple` for migration execution.
- Added integrity gates for shipped migrations: `migrations.lock`,
  `keiro-migrate lock`, embed-parity checks, body linting, combined
  Kiroku+Keiro ledger timestamp uniqueness, a codd v5 ledger canary, and
  regression tests for both the ledger realignment fixup and the alpha
  remediation runbook.
- Hardened the apply path: unknown `keiro-migrate` arguments now exit 2 with
  usage, `up` is an explicit apply synonym, `KEIRO_MIGRATE_NO_CHECK=false`
  remains checked, schema drift under the checked path exits nonzero, embedded
  migrations force codd's single-try retry policy, and concurrent applies
  serialize with the shared Kiroku advisory lock.
- Added operator tooling: `keiro-migrate verify` strict-checks a live database
  against the expected-schema snapshot embedded in the binary,
  `keiro-migrate status` reports applied and pending combined-ledger entries,
  and `Keiro.Migrations.missingMigrations` lets applications fail fast at
  startup when Kiroku or Keiro framework migrations have not been applied.
- Added `docs/user/migration-ownership.md`, the canonical guide for
  framework-owned vs application-owned migrations, combined-ledger composition,
  application migration guards, runtime grants, and operator checks.
- A database first migrated by `0.1.0.0` has its `keiro_*` tables in `kiroku`. It
  requires a **one-time remediation** before running these migrations: follow
  [Upgrading To The Keiro Schema](../docs/user/upgrading-to-the-keiro-schema.md),
  which wraps the tested script
  `keiro-migrations/remediation/2026-07-05-relocate-keiro-tables-to-keiro-schema.sql`.
  The script relocates the tables (`ALTER TABLE ... SET SCHEMA keiro`) in one
  transaction and needs no codd-ledger change (migration filenames are unchanged,
  so codd re-runs nothing). Fresh and ephemeral databases need no remediation.

### Recommended Version Bump

- The next release is **`0.2.0.0`**. This is a breaking change; the package
  follows the Haskell PVP, where the leading `A.B` components form the "major"
  version and must increment on any breaking change, so `0.1` → `0.2` is the
  minimal PVP-correct major bump for a pre-1.0 package.

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
