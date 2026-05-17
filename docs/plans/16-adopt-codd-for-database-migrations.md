---
id: 16
slug: adopt-codd-for-database-migrations
title: "Adopt codd for database migrations"
kind: exec-plan
created_at: 2026-05-17T13:35:34Z
intention: "intention_01krv2b0yeej5b2ej2wdt02dgh"
---

# Adopt codd for database migrations

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Keiro currently creates its own database tables at runtime with `CREATE TABLE IF NOT EXISTS` statements embedded in Haskell modules. That is convenient for tests, but it is not a production migration story: there is no applied-migration ledger, no ordered forward migration history, and no database schema verification step. Kiroku now has a first-class codd migration package, so Keiro should follow the same pattern and expose one migration entry point that applies Kiroku's event-store migrations and Keiro's framework tables before an application starts.

After this plan is implemented, a service using Keiro can run a migration executable before opening `Kiroku.Store.withStore`. The executable applies Kiroku's embedded codd migrations first, then Keiro's embedded codd migrations for snapshots, read-model metadata, and timers. A human can see it working by starting a fresh PostgreSQL database, running `keiro-migrate`, and observing that the Kiroku tables (`streams`, `events`, `stream_events`, `subscriptions`), Keiro tables (`keiro_snapshots`, `keiro_read_models`, `keiro_timers`), and codd's own migration ledger exist without relying on runtime schema initialization.


## Progress

- [x] Milestone 1: Add a `keiro-migrations` subpackage and embed Keiro-owned SQL migrations. Completed 2026-05-17T13:55:08Z; `cabal build keiro-migrations` compiled `Keiro.Migrations` after adding a scoped `allow-newer: haxl:time` solver override for local codd.
- [x] Milestone 2: Compose Kiroku and Keiro migrations in one codd migration executable. Completed 2026-05-17T13:55:08Z; `cabal build keiro-migrate` compiled the executable that runs Kiroku plus Keiro migrations through one codd ledger.
- [x] Milestone 3: Move runtime initialization toward explicit migration use while preserving development and test ergonomics. Completed 2026-05-17T13:56:57Z; `keiro-migrations/README.md` documents the `keiro-migrate` workflow and the runtime initializer functions now state that they are compatibility helpers for development and tests.
- [ ] Milestone 4: Add integration tests and documentation for the migration workflow. The migration package test was added and `cabal test keiro-migrations-test` passed on 2026-05-17T13:56:57Z. Remaining validation is blocked by the existing `keiro-test` compile failure in `src/Keiro/Command.hs`, which is unrelated to migration adoption and appears to be the Keiki multi-event command output change tracked by `docs/plans/17-adopt-keiki-multi-event-command-output.md`.


## Surprises & Discoveries

- 2026-05-17: `mori show --full` reports Keiro as `shinzui/keiro`, a Haskell framework depending on `shinzui/kiroku`, `shinzui/keiki`, `shinzui/shibuya`, `hasql/hasql`, and `effectful/effectful`. This means Kiroku's migration package is not optional background context; Keiro's migration runner must either depend on it directly or document an ordering requirement that every downstream service must satisfy.
- 2026-05-17: `mori registry show mzabani/codd --full` reports the local codd source at `/Users/shinzui/Keikaku/hub/haskell/codd-project`, and `mori registry docs mzabani/codd` exposes the adoption note at `/Users/shinzui/Keikaku/hub/haskell/codd-project/docs/adoption-for-haskell-services.md`. That note confirms the library-subpackage pattern: `Codd.applyMigrations` accepts `Maybe [AddedSqlMigration m]`, so a library can ship migrations as embedded Haskell values.
- 2026-05-17: Kiroku already implements the target pattern in `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store-migrations/src/Kiroku/Store/Migrations.hs`. It embeds `sql-migrations/*.sql` with `Data.FileEmbed.embedDir`, parses them with `Codd.Parsing.parseAddedSqlMigration`, and calls `applyMigrations settings (Just migrations) connectTimeout verifySchemas`.
- 2026-05-17: Keiro currently owns three schema initializers: `src/Keiro/Snapshot/Schema.hs` creates `keiro_snapshots`; `src/Keiro/ReadModel/Schema.hs` creates `keiro_read_models`; `src/Keiro/Timer/Schema.hs` creates `keiro_timers`. These statements are the initial Keiro migration payload.
- 2026-05-17: Building codd under this workspace with GHC 9.12.2 initially failed because `haxl-2.5.1.1` declares `time <1.13` while the compiler environment has `time-1.14`. Evidence from `cabal build keiro-migrations`: `conflict: time==1.14/installed-656e, haxl => time>=1.4 && <1.13`. The workspace now carries `allow-newer: haxl:time`, which lets the local codd library compile.
- 2026-05-17: `runAllKeiroMigrations` with `LaxCheck` prints a schema-difference report when the test uses an empty expected representation, but still returns successfully and applies migrations. Evidence from `cabal test keiro-migrations-test`: codd logs `Error: DB and expected schemas do not match`, then `Successfully applied all migrations to postgres`, and Hspec reports `1 example, 0 failures`.
- 2026-05-17: `information_schema.tables.table_name` is exposed through Hasql as PostgreSQL's `name` type, not `text`. The migration test now casts `table_name::text` before decoding with `D.text`.
- 2026-05-17: `cabal test keiro-test` does not reach runtime migration compatibility checks in this worktree. It fails while compiling `src/Keiro/Command.hs` because the pattern `Just (_, _, Nothing)` expects a `Maybe` command output while the current `Keiki.Core` dependency returns a list-shaped command output.


## Decision Log

- Decision: Create a separate `keiro-migrations` package instead of adding codd and file embedding to the main `keiro` library.
  Rationale: Kiroku uses a dedicated `kiroku-store-migrations` subpackage, and copying that boundary keeps the runtime library free of migration-tool dependencies. Applications that only compile Keiro do not need to link codd unless they run migrations.
  Date: 2026-05-17
- Decision: Compose Kiroku migrations and Keiro migrations in the Keiro migration executable, with Kiroku first.
  Rationale: Keiro builds on Kiroku's event-store schema. A downstream service should not have to remember to run two independent executables in the right order when a single executable can apply both embedded migration lists through codd.
  Date: 2026-05-17
- Decision: Start with codd `LaxCheck`, matching Kiroku's first migration implementation, and leave strict expected-schema snapshots as an explicit follow-up inside this plan.
  Rationale: Kiroku's `kiroku-store-migrations/README.md` says its first implementation uses lax schema checking because it does not yet ship a checked-in expected-schema snapshot. Keiro should not promise stricter verification than its upstream schema dependency can currently support.
  Date: 2026-05-17
- Decision: Keep the existing `initializeSnapshotSchema`, `initializeReadModelSchema`, and `initializeTimerSchema` functions during the first implementation, but document them as development/test compatibility paths once codd migrations exist.
  Rationale: Existing tests and examples likely call these functions or exercise code paths that assume runtime initialization. Removing them in the same change would increase blast radius without improving the migration executable's observable behavior.
  Date: 2026-05-17
- Decision: Add a scoped Cabal `allow-newer: haxl:time` override to `cabal.project` rather than editing codd or haxl sources.
  Rationale: The incompatibility is an upstream dependency bound problem surfaced by the local compiler's `time-1.14`, and the plan requires using the local codd checkout as a dependency rather than forking or patching it in this repository.
  Date: 2026-05-17


## Outcomes & Retrospective

Implemented the codd migration package, embedded Keiro's current framework schema as a bootstrap SQL migration, and added a `keiro-migrate` executable that applies Kiroku and Keiro migrations through one codd ledger. The migration package has an ephemeral PostgreSQL test that verifies the expected Kiroku and Keiro tables exist after the first run and still exist after a second run.

The remaining acceptance gap is the existing `keiro-test` compile failure in `src/Keiro/Command.hs`. That failure is outside the migration surface and aligns with the separate Keiki multi-event command output adoption plan, so this plan stops short of marking Milestone 4 complete until that dependency/API migration is handled.


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/keiro`. This is a Haskell Cabal project. The main package is declared in `keiro.cabal`, and the workspace is declared in `cabal.project`. The current `cabal.project` includes the local Keiki packages and `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store`, but it does not include Kiroku's new `kiroku-store-migrations` package or the local codd checkout.

Keiro depends on Kiroku, the PostgreSQL event store. Kiroku owns the base event-store tables: `streams`, `events`, `stream_events`, and `subscriptions`. Keiro owns framework-level tables layered on top of that event store. Snapshots are cached aggregate states used to speed up hydration; their table is `keiro_snapshots`. Read models are query-facing tables derived from events; Keiro tracks their lifecycle in `keiro_read_models`. Timers are durable delayed commands for process managers; their table is `keiro_timers`.

The Keiro schema is currently created by Haskell functions:

- `src/Keiro/Snapshot/Schema.hs` exports `initializeSnapshotSchema`, which runs `Kiroku.Store.Transaction.runTransaction` and a `Hasql.Transaction.sql` block creating `keiro_snapshots` plus `keiro_snapshots_compat_idx`.
- `src/Keiro/ReadModel/Schema.hs` exports `initializeReadModelSchema`, which creates `keiro_read_models`.
- `src/Keiro/Timer/Schema.hs` exports `initializeTimerSchema`, which creates `keiro_timers` plus `keiro_timers_due_idx`.

These functions are idempotent because they use `CREATE TABLE IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS`, but idempotence is not the same as migrations. A migration is an ordered, recorded database change. codd records applied migrations in its own internal schema, parses timestamped `.sql` files, applies pending migrations, and can compare the database's schema against a checked-in schema snapshot. codd is forward-only: if a bad migration reaches production, the recovery path is a new forward migration or database restore, not an automatic rollback.

Kiroku's first-class migration package is the local reference implementation. The package `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store-migrations` exposes `Kiroku.Store.Migrations.kirokuMigrations` and `Kiroku.Store.Migrations.runKirokuMigrations`. The source file embeds SQL with Template Haskell `$(embedDir "sql-migrations")`, converts each `(FilePath, ByteString)` to a codd `AddedSqlMigration`, and calls:

```haskell
applyMigrations settings (Just migrations) connectTimeout verifySchemas
```

codd's settings come from environment variables through `Codd.Environment.getCoddSettings`. The mandatory environment variables are `CODD_CONNECTION`, `CODD_MIGRATION_DIRS`, and `CODD_EXPECTED_SCHEMA_DIR`. For embedded migrations, `CODD_MIGRATION_DIRS` is still required by codd's settings parser but is not used to collect migration files because the code passes `Just migrations` to `applyMigrations`.

The local codd adoption note at `/Users/shinzui/Keikaku/hub/haskell/codd-project/docs/adoption-for-haskell-services.md` recommends this exact library-subpackage pattern for Haskell services whose libraries contribute migrations. It also records the tradeoffs that matter here: codd is production-viable but pre-1.0, has no rollback, and uses one unified schema snapshot per service.


## Plan of Work

### Milestone 1 - Add `keiro-migrations` with embedded Keiro SQL

Create a new subdirectory `keiro-migrations/` containing a Cabal package named `keiro-migrations`. At the end of this milestone, `cabal build keiro-migrations` compiles a library that exposes Keiro's own migrations as `[AddedSqlMigration m]`, but no executable composes Kiroku yet.

Add `keiro-migrations/keiro-migrations.cabal` modeled on Kiroku's `kiroku-store-migrations/kiroku-store-migrations.cabal`. The library exposes `Keiro.Migrations`, uses `hs-source-dirs: src`, and includes `extra-source-files: README.md` and `sql-migrations/*.sql`. Its build dependencies should include at least `base`, `bytestring`, `codd >=0.1.8`, `file-embed >=0.0.15`, `streaming`, `text`, and `time`. Add an executable stanza named `keiro-migrate` in Milestone 2, not necessarily in the first commit.

Create `keiro-migrations/sql-migrations/2026-05-17-00-00-00-keiro-bootstrap.sql`. This migration should contain the DDL currently embedded in the three initializer functions. Keep the statements semantically identical at first: create `keiro_snapshots`, `keiro_snapshots_compat_idx`, `keiro_read_models`, `keiro_timers`, and `keiro_timers_due_idx`. Do not add unrelated columns, constraints, schemas, or status values in this migration. The purpose of the bootstrap migration is to capture the current Keiro schema as-is.

Create `keiro-migrations/src/Keiro/Migrations.hs`. The module should export:

```haskell
module Keiro.Migrations
  ( keiroMigrations
  , runKeiroMigrations
  )
where
```

The implementation should copy Kiroku's pattern closely. Use `Data.FileEmbed.embedDir` to embed `sql-migrations`, `Codd.Parsing.PureStream` plus `Streaming.Prelude.yield` to stream each embedded SQL file, `Codd.Parsing.parseAddedSqlMigration` to parse codd migration metadata, and `Codd.applyMigrations` to run the list. The expected signatures are:

```haskell
keiroMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
runKeiroMigrations :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
```

Update `cabal.project` to include `keiro-migrations`, `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store-migrations`, and the local codd checkout `/Users/shinzui/Keikaku/hub/haskell/codd-project/codd/codd.cabal` as an `optional-packages` entry if needed. Do not reference `/nix/store`.

Acceptance for this milestone is that this command from the repository root succeeds:

```bash
cabal build keiro-migrations
```

The expected successful output includes Cabal building `Keiro.Migrations` without parse errors. Exact package hashes and build directory paths are not stable, so do not hard-code them into validation.

### Milestone 2 - Compose Kiroku and Keiro migrations in `keiro-migrate`

Add an executable named `keiro-migrate` to `keiro-migrations/keiro-migrations.cabal`, with `main-is: Main.hs`, `hs-source-dirs: app`, and dependencies on `base`, `codd`, `keiro-migrations`, `kiroku-store-migrations`, and `time`.

Create `keiro-migrations/app/Main.hs`. The executable should read codd settings using `Codd.Environment.getCoddSettings`, build the full embedded migration list by concatenating `Kiroku.Store.Migrations.kirokuMigrations` and `Keiro.Migrations.keiroMigrations`, and call `Codd.applyMigrations` once with `Just allMigrations`. Running codd once is important because it gives codd a single ordered set of migrations and one ledger, rather than two independent migration runs whose schema checks may disagree. Kiroku's bootstrap migration is currently named `2026-05-16-00-00-00-kiroku-bootstrap.sql`, and Keiro's bootstrap migration should be `2026-05-17-00-00-00-keiro-bootstrap.sql`, so timestamp ordering applies Kiroku first.

Expose a reusable library function as well, so downstream service migration executables can compose Keiro migrations with service-owned migrations. Add to `Keiro.Migrations`:

```haskell
keiroFrameworkMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
allKeiroMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
runAllKeiroMigrations :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
```

Use `keiroFrameworkMigrations` for Keiro-owned SQL only. Use `allKeiroMigrations` for Kiroku plus Keiro, in that order. Keep `keiroMigrations` as a compatibility alias for `keiroFrameworkMigrations` if that is clearer to callers; document the distinction in the module header and README.

The executable should use `LaxCheck` initially:

```haskell
main :: IO ()
main = do
  settings <- getCoddSettings
  _ <- runAllKeiroMigrations settings (secondsToDiffTime 5) LaxCheck
  pure ()
```

Acceptance for this milestone is that `cabal build keiro-migrate` succeeds and `cabal run keiro-migrate` can apply all migrations against a fresh PostgreSQL database when the required `CODD_*` variables point at that database.

### Milestone 3 - Preserve runtime compatibility and add explicit migration guidance

After the migration executable works, update runtime-facing documentation and, only where necessary, function names or comments so users understand the new intended production path. Keep `initializeSnapshotSchema`, `initializeReadModelSchema`, and `initializeTimerSchema` available for tests and local development unless a compile-time search proves there are no callers and removing them does not break public API promises. If comments are added to these functions, they should say that production deployments should run `keiro-migrate` before starting the application, while these initializers remain compatibility helpers for development and tests.

Update `README.md` if present. If the repository does not yet have one with operational instructions, create or extend `keiro-migrations/README.md` instead. The documentation must show a complete command:

```bash
CODD_CONNECTION='host=/tmp port=5432 dbname=keiro user=keiro_admin' \
CODD_MIGRATION_DIRS=unused-for-embedded-migrations \
CODD_EXPECTED_SCHEMA_DIR=keiro-migrations/expected-schema \
CODD_SCHEMAS=public \
cabal run keiro-migrate
```

Also document that applications should start Kiroku with schema initialization disabled after migrations have run. Kiroku's README shows the intended shape:

```haskell
withStore
  (defaultConnectionSettings connString
    & #schemaInitialization .~ SkipSchemaInitialization)
  app
```

Acceptance for this milestone is that a reader can open `keiro-migrations/README.md` and understand what environment variables to set, what command to run, and why codd is forward-only.

### Milestone 4 - Test the migration workflow end-to-end

Add tests for the migration package. Create a `test-suite keiro-migrations-test` in `keiro-migrations/keiro-migrations.cabal` with `main-is: Main.hs`, `hs-source-dirs: test`, and dependencies on `base`, `codd`, `ephemeral-pg`, `hasql`, `hasql-pool`, `hspec`, `keiro-migrations`, `kiroku-store`, `kiroku-store-migrations`, `text`, and `time` as needed. Use the existing Keiro tests in `test/Main.hs` and Kiroku migration tests as references for local patterns, but keep the migration test focused.

The test should start a fresh ephemeral PostgreSQL instance, set the codd environment variables for that instance, run `runAllKeiroMigrations` with `LaxCheck`, and then query for the expected tables. At minimum, assert that these tables exist: `streams`, `events`, `stream_events`, `subscriptions`, `keiro_snapshots`, `keiro_read_models`, and `keiro_timers`. Also assert that a second `runAllKeiroMigrations` call succeeds without applying duplicate user-visible DDL, proving the migration path is repeatable on an already-migrated database.

If codd's settings reader requires real directories for `CODD_MIGRATION_DIRS` or `CODD_EXPECTED_SCHEMA_DIR`, create temporary directories in the test and point the variables there. Do not write test fixtures into `/tmp` with hard-coded names; use the test framework or a temporary-directory helper so parallel test runs do not collide.

Acceptance for this milestone is that both commands pass from the repository root:

```bash
cabal test keiro-migrations-test
cabal test keiro-test
```

The existing `keiro-test` suite matters because retaining runtime compatibility is part of this plan. If `keiro-test` fails because runtime initializer behavior changed, restore compatibility or update the tests only if the new behavior is intentionally documented in this plan's Decision Log.


## Concrete Steps

1. From `/Users/shinzui/Keikaku/bokuno/keiro`, confirm dependency locations and current schema ownership:

```bash
mori show --full
mori registry show mzabani/codd --full
mori registry docs mzabani/codd
mori registry show shinzui/kiroku --full
rg -n "initialize.*Schema|CREATE TABLE|CREATE INDEX|codd|migrations" src test keiro.cabal cabal.project
```

Expected findings are that codd is at `/Users/shinzui/Keikaku/hub/haskell/codd-project`, Kiroku is at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`, and Keiro's current schema creation lives in the three `src/Keiro/*/Schema.hs` modules named above.

2. Add `keiro-migrations/keiro-migrations.cabal`, `keiro-migrations/src/Keiro/Migrations.hs`, `keiro-migrations/sql-migrations/2026-05-17-00-00-00-keiro-bootstrap.sql`, and `keiro-migrations/README.md`.

3. Update `cabal.project` so the workspace includes `keiro-migrations`, Kiroku's migration package, and codd's local package source when needed:

```text
packages:
  .
  keiro-migrations
  /Users/shinzui/Keikaku/bokuno/keiki
  /Users/shinzui/Keikaku/bokuno/keiki/keiki-codec-json
  /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store
  /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store-migrations

optional-packages:
  /Users/shinzui/Keikaku/hub/haskell/codd-project/codd/codd.cabal
```

Preserve any existing local package entries and formatting unless Cabal requires a different shape.

4. Build the migration library:

```bash
cabal build keiro-migrations
```

5. Add `keiro-migrations/app/Main.hs` and the executable stanza for `keiro-migrate`. Build it:

```bash
cabal build keiro-migrate
```

6. Add the migration integration test and run:

```bash
cabal test keiro-migrations-test
cabal test keiro-test
```

7. Manually test the executable against a fresh PostgreSQL database if an existing local database or ephemeral helper is available:

```bash
CODD_CONNECTION='host=/tmp port=5432 dbname=keiro user=keiro_admin' \
CODD_MIGRATION_DIRS=unused-for-embedded-migrations \
CODD_EXPECTED_SCHEMA_DIR=keiro-migrations/expected-schema \
CODD_SCHEMAS=public \
cabal run keiro-migrate
```

The command should exit successfully. A follow-up `psql` inspection should show codd's internal migration schema, Kiroku's tables, and Keiro's tables.


## Validation and Acceptance

The implementation is accepted when a fresh database can be migrated without calling Keiro's runtime initializer functions and the existing test suite still passes. The minimum automated validation is:

```bash
cabal build all
cabal test keiro-migrations-test
cabal test keiro-test
```

The migration test must prove observable database state, not just compilation. It should fail before the migration runner exists because the expected tables are absent, and pass after `runAllKeiroMigrations` has applied Kiroku and Keiro migrations. The second migration run in the same test must pass as well, showing that codd sees already-applied migrations and does not break on repeated startup checks.

Manual acceptance is a clean run of `cabal run keiro-migrate` with `CODD_CONNECTION`, `CODD_MIGRATION_DIRS`, `CODD_EXPECTED_SCHEMA_DIR`, and `CODD_SCHEMAS` set. Inspecting the database should show these application tables:

```text
streams
events
stream_events
subscriptions
keiro_snapshots
keiro_read_models
keiro_timers
```

Documentation acceptance is that `keiro-migrations/README.md` states that codd is forward-only, shows the environment variables, and tells operators to run migrations before starting an application with Kiroku schema initialization disabled.


## Idempotence and Recovery

Creating files and editing Cabal metadata is safe to repeat by reapplying the same patch. The SQL bootstrap migration should keep `CREATE TABLE IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS` so applying it to a fresh or partially initialized development database is forgiving, but codd's migration ledger remains the source of truth after adoption.

Do not rename a migration file after it has been applied to any shared database. codd derives migration identity from the timestamped file name. If a migration file is wrong before it is shared, fix it in place and rerun tests against a fresh database. If it is wrong after it reaches a shared database, add a new timestamped forward migration that repairs the schema, and record the decision in this plan.

Because codd has no rollback, production recovery is either restoring from backup or shipping a new forward migration. This plan's initial migration only captures tables that Keiro already creates today; it should not include destructive DDL. Future destructive migrations must have their own ExecPlan or a Decision Log entry explaining the backup and rollout strategy.

The runtime initializer functions remain available during the first migration adoption. If a developer's local database was already initialized by those functions, running `keiro-migrate` should still work because the bootstrap SQL is idempotent. codd will record the migration as applied once its SQL succeeds.


## Interfaces and Dependencies

`mori` is the source of dependency discovery for this repository. Use `mori show --full` for Keiro's declared dependencies and `mori registry show <project> --full` plus `mori registry docs <project>` before guessing at dependency APIs. Do not search, read, or traverse `/nix/store`.

The codd API used by this plan is:

```haskell
applyMigrations ::
  (MonadUnliftIO m, CoddLogger m, MonadThrow m, EnvVars m, NotInTxn m) =>
  CoddSettings ->
  Maybe [AddedSqlMigration m] ->
  DiffTime ->
  VerifySchemas ->
  m ApplyResult
```

`Maybe [AddedSqlMigration m]` is the key interface. Passing `Just allMigrations` bypasses codd's disk migration collection and uses the embedded migration list supplied by Kiroku and Keiro.

The Keiro migration package must expose these interfaces:

```haskell
keiroFrameworkMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
keiroMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
allKeiroMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
runKeiroMigrations :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
runAllKeiroMigrations :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
```

The names may be adjusted during implementation if Cabal or module naming makes a clearer surface obvious, but the final module must distinguish Keiro-owned migrations from Kiroku-plus-Keiro migrations.

The Kiroku migration interface consumed by Keiro is:

```haskell
Kiroku.Store.Migrations.kirokuMigrations ::
  (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
```

The executable uses:

```haskell
Codd.Environment.getCoddSettings :: IO CoddSettings
Data.Time.secondsToDiffTime :: Pico -> DiffTime
Codd.VerifySchemas.LaxCheck
```

The runtime Keiro modules that must remain compatible unless this plan is explicitly revised are `src/Keiro/Snapshot/Schema.hs`, `src/Keiro/ReadModel/Schema.hs`, and `src/Keiro/Timer/Schema.hs`.
