---
id: 79
slug: version-keiro-database-schema-and-enforce-migration-checks
title: "Version Keiro database schema and enforce migration checks"
kind: exec-plan
created_at: 2026-06-13T14:55:26Z
intention: intention_01kv0syad5ekzsrcr2qkpq3nfm
---

# Version Keiro database schema and enforce migration checks

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Keiro's migration tests should distinguish between two different jobs: quickly preparing a clean PostgreSQL schema for ordinary integration tests, and deliberately checking that the migrated database still matches a checked-in schema representation. Today those jobs are mixed together. The shared test fixture applies migrations with codd's lax schema check against an empty in-memory expected schema, so successful test runs can print a scary `Error: DB and expected schemas do not match` diff even when nothing failed.

After this change, ordinary test suites still get fresh migrated PostgreSQL databases, but they do so without schema comparison noise. A dedicated migration test owns schema verification against a versioned `keiro-migrations/expected-schema/` tree and fails when migrations or expected schema files drift apart. A developer can see the behavior by running `cabal test keiro-migrations-test`: it should pass quietly when the expected schema is current, and a stale `keiro-migrations/expected-schema/` diff should produce a real failing test rather than incidental log noise.


## Progress

- [x] Confirm the exact codd commands/API for writing expected schema files from a migrated ephemeral database. (2026-06-13)
- [x] Add a deterministic `keiro-migrations/expected-schema/` representation for the current Kiroku plus Keiro schema. (2026-06-13)
- [x] Change fixture-only migration paths to skip schema comparison by using the existing no-check migration runner. (2026-06-13)
- [x] Update `keiro-migrations-test` so one test proves migrations apply and are repeatable, and a separate test strictly compares the migrated database to the checked-in expected schema. (2026-06-13)
- [x] Document how to regenerate the expected schema when a legitimate migration changes the framework schema. (2026-06-13)
- [x] Run and record the validation commands. (2026-06-13)


## Surprises & Discoveries

- 2026-06-13: The current noisy output is caused by passing an empty expected representation, not by a failed migration. `keiro-test-support/src/Keiro/Test/Postgres.hs` builds `CoddSettings` with `onDiskReps = Right (DbRep Null Map.empty Map.empty)` and then calls `runAllKeiroMigrations ... LaxCheck`. codd's `LaxCheck` compares the live database to that empty representation, logs the difference, and still returns success.

- 2026-06-13: codd already has the primitives this plan needs. In `/Users/shinzui/Keikaku/hub/haskell/codd-project/codd/src/Codd.hs`, `VerifySchemas` has both `LaxCheck` and `StrictCheck`. `StrictCheck` throws on a mismatch, while `LaxCheck` returns `SchemasDiffer`. In `/Users/shinzui/Keikaku/hub/haskell/codd-project/codd/src/Codd/Environment.hs`, `CODD_EXPECTED_SCHEMA_DIR` becomes `onDiskReps = Left <dir>`, which tells codd to read expected schema files from disk. In `/Users/shinzui/Keikaku/hub/haskell/codd-project/codd/src/Codd/Representations/Disk.hs`, `persistRepsToDisk` writes the representation under a PostgreSQL-major-version subdirectory.

- 2026-06-13: Keiro already exposes no-check runners. `keiro-migrations/src/Keiro/Migrations.hs` exports `runAllKeiroMigrationsNoCheck`, which still uses codd's migration ledger and locking but skips expected-schema comparison.

- 2026-06-13: The local ephemeral PostgreSQL server is major version 18, so codd wrote files under `keiro-migrations/expected-schema/v18/` and printed `Warn: Not all features of PostgreSQL version v18 may be supported by codd.` The generated representation still completed successfully, and validation should run against the same PostgreSQL major version unless another representation is added.

- 2026-06-13: The first `cabal test keiro-migrations-test` build failed because `keiro-migrations/test/Main.hs` imported `System.Directory` but the test suite did not list `directory` in `build-depends`. Adding the explicit dependency fixed the package boundary issue.

- 2026-06-13: The negative drift check proves the strict test is meaningful. Temporarily changing `keiro-migrations/expected-schema/v18/schemas/kiroku/tables/keiro_timers/cols/last_error` from `"notnull": false` to `"notnull": true` made only the strict schema example fail with:

```text
Error: DB and expected schemas do not match. Differing objects and their current DB schemas are: {"schemas/kiroku/tables/keiro_timers/cols/last_error":["different-schemas",{"collation":"default","collation_nsp":"pg_catalog","default":null,"generated":"","hasdefault":false,"identity":"","inhcount":0,"local":true,"notnull":false,"privileges":null,"type":"text"}]}
user error (Exiting. Database's schema differ from expected.)
```

The file was restored and `cabal test keiro-migrations-test` passed again.


## Decision Log

Record every decision made while working on the plan.

- Decision: Treat schema preparation and schema verification as separate test concerns.
  Rationale: Fixture setup only needs a migrated database; comparing it to an empty expected schema creates noisy logs that look like failures. A dedicated verification test can use the stricter codd mode and fail only when there is real drift.
  Date: 2026-06-13

- Decision: Use codd's on-disk expected-schema representation rather than hand-written SQL introspection assertions as the primary drift gate.
  Rationale: codd already models database objects, roles, schemas, tables, routines, triggers, and sequences in its `DbRep` format and knows how to compare PostgreSQL-major-version-specific representations. The existing table-presence assertions are still useful as a simple smoke test, but they are too shallow to replace codd's schema comparison.
  Date: 2026-06-13

- Decision: Version the schema under `keiro-migrations/expected-schema/`.
  Rationale: `keiro-migrations/README.md` and `docs/user/migrations.md` already document `CODD_EXPECTED_SCHEMA_DIR=keiro-migrations/expected-schema`, but that directory is not currently present in the package. Placing the files there matches the documented path and keeps migrations and their expected result together.
  Date: 2026-06-13

- Decision: Add a `keiro-write-expected-schema` executable instead of requiring developers to manually coordinate an ephemeral PostgreSQL connection, `keiro-migrate`, and `codd write-schema`.
  Rationale: The helper applies embedded Kiroku plus Keiro migrations with `runAllKeiroMigrationsNoCheck` to a clean ephemeral database and then calls codd's exposed `writeSchema` API with `WriteToDisk`. This keeps regeneration deterministic and matches the path used by the strict test.
  Date: 2026-06-13

- Decision: Make the strict schema test locate either `keiro-migrations/expected-schema` or `expected-schema`.
  Rationale: Cabal usually runs the test from the repository root, but accepting the package-local path makes the test robust if invoked from the package directory.
  Date: 2026-06-13


## Outcomes & Retrospective

2026-06-13: Implementation completed. Keiro now checks in codd's expected schema representation under `keiro-migrations/expected-schema/v18/`, generated from a clean ephemeral PostgreSQL database by the new `keiro-write-expected-schema` executable. Ordinary fixture setup in `keiro-test-support/src/Keiro/Test/Postgres.hs` now uses `runAllKeiroMigrationsNoCheck`, so fixture-based suites apply migrations without comparing against an empty expected schema. `keiro-migrations/test/Main.hs` now has separate tests for migration repeatability and strict checked-in schema matching.

Validation passed with:

```text
cabal test keiro-migrations-test
2 examples, 0 failures

cabal test keiro-test
158 examples, 0 failures

cabal test keiro-pgmq-test
31 examples, 0 failures, 1 pending

just haskell-test
keiro-test: 158 examples, 0 failures
keiro-pgmq-test: 31 examples, 0 failures, 1 pending
jitsurei-test: 16 examples, 0 failures
All generated jitsurei diagrams are up to date.
```

The deliberate negative check also failed as expected when a single expected-schema column file was temporarily edited. The only residual caveat is that the local ephemeral PostgreSQL is version 18 and codd warns that v18 is newer than its fully supported version list; the strict comparison still reads and matches the generated `v18` representation.


## Context and Orientation

Keiro uses PostgreSQL as the durable event-store and workflow database. SQL migrations live in `keiro-migrations/sql-migrations/`. The Haskell module `keiro-migrations/src/Keiro/Migrations.hs` embeds those SQL files at compile time and exposes helper functions that run them through codd. codd is the Haskell migration tool used here; it applies SQL migrations, records which migrations ran, and can compare the live PostgreSQL schema against expected schema files checked into the repository.

`Keiro.Migrations.runAllKeiroMigrations` applies Kiroku's event-store migrations followed by Keiro's framework migrations. Kiroku is the event-store package Keiro depends on; its tables and Keiro's framework tables are created in the PostgreSQL schema named `kiroku`. A PostgreSQL schema is a namespace inside a database, not the whole database. The relevant codd setting is `namespacesToCheck = IncludeSchemas [SqlSchema "kiroku"]`, which tells codd to compare only that schema.

`Keiro.Migrations.runAllKeiroMigrationsNoCheck` applies the same migrations but skips the expected-schema comparison. It still goes through codd, so the migration ledger and codd locking behavior remain in place.

The shared test fixture is `keiro-test-support/src/Keiro/Test/Postgres.hs`. It uses `ephemeral-pg` to start one temporary PostgreSQL server per test suite, migrates a template database once, and clones a fresh database from that template for each test example. This fixture currently imports `VerifySchemas (LaxCheck)`, constructs `onDiskReps = Right (DbRep Null Map.empty Map.empty)`, and calls `runAllKeiroMigrations settings (secondsToDiffTime 5) LaxCheck`. `Right (DbRep ...)` means "use this in-memory expected schema"; the empty maps mean "expect no schemas and no roles." That is why codd logs a large diff after migrations create real database objects.

The migration test is `keiro-migrations/test/Main.hs`. It starts an ephemeral PostgreSQL instance, calls `runAllKeiroMigrations` twice with `LaxCheck`, and asserts that a small list of expected tables exists in schema `kiroku` and is absent from `public`. It uses the same empty in-memory `DbRep`, so it also emits the same drift log. This test currently proves migrations apply and are repeatable, but it does not prove the checked-in expected schema is current because there is no checked-in expected schema directory.

The command-line runner is `keiro-migrations/app/Main.hs`. Its default mode reads codd settings from environment variables via `Codd.Environment.getCoddSettings`. That parser requires `CODD_CONNECTION`, `CODD_MIGRATION_DIRS`, and `CODD_EXPECTED_SCHEMA_DIR`; `CODD_SCHEMAS=kiroku` scopes comparison to the framework schema. Setting `KEIRO_MIGRATE_NO_CHECK` switches the executable to `runAllKeiroMigrationsNoCheck`. The existing `keiro-migrations/README.md` already documents `CODD_EXPECTED_SCHEMA_DIR=keiro-migrations/expected-schema`, so this plan should make that documented path real.

codd's on-disk representation is PostgreSQL-major-version-specific. `persistRepsToDisk` writes inside a subdirectory named for the server major version, such as `keiro-migrations/expected-schema/v18/`. `readRepsFromDisk` reads from the matching major-version subdirectory for the server running the test. This is important because CI and local development must use a PostgreSQL major version for which expected-schema files exist.


## Plan of Work

Milestone 1 establishes the expected schema artifact and the exact regeneration workflow. Start by proving how to write codd schema files from a migrated ephemeral database. Prefer codd's application command if it is reachable in this repo: apply all Keiro migrations to an ephemeral database, then run the equivalent of codd `write-schema` with `CODD_EXPECTED_SCHEMA_DIR=keiro-migrations/expected-schema` and `CODD_SCHEMAS=kiroku`. If the `codd` executable is not conveniently available in the developer shell, add a small test-only or app-only Haskell helper that imports codd's `writeSchema` command or lower-level `persistRepsToDisk` and writes the same directory. At the end of this milestone, `keiro-migrations/expected-schema/<pg-major>/...` exists, is checked into the working tree, and can be regenerated deterministically.

Milestone 2 removes schema-comparison noise from fixture setup. Edit `keiro-test-support/src/Keiro/Test/Postgres.hs`: replace the import of `runAllKeiroMigrations` with `runAllKeiroMigrationsNoCheck`, remove the `VerifySchemas (LaxCheck)`, `DbRep`, `Data.Aeson`, and `Data.Map` imports if they are no longer used, and change `migrateTemplate` to call `runAllKeiroMigrationsNoCheck settings (secondsToDiffTime 5)`. Keep `templateCoddSettings` because codd still needs the connection string, schema selection, retry policy, and transaction settings. Update the comment above `templateCoddSettings` so it says template setup intentionally skips schema verification; it should no longer claim that `LaxCheck` is used. At the end of this milestone, suites that use `withMigratedSuite` still receive migrated template databases but do not print expected-schema mismatch logs during fixture setup.

Milestone 3 separates migration smoke testing from drift testing. Edit `keiro-migrations/test/Main.hs` so the existing "applies Kiroku and Keiro migrations to a fresh database and is repeatable" test uses `runAllKeiroMigrationsNoCheck`. Keep the table and column assertions as a human-readable smoke test. Add a second example, for example "matches the checked-in expected schema", that starts a fresh ephemeral database, applies migrations with codd schema verification enabled against `keiro-migrations/expected-schema`, and expects `SchemasMatch`. Use `VerifySchemas (StrictCheck)` for this second test so drift fails the test. Its `CoddSettings` should set `onDiskReps = Left "keiro-migrations/expected-schema"` and `namespacesToCheck = IncludeSchemas [SqlSchema "kiroku"]`. If the test is executed from a package-specific working directory and the relative path does not resolve, compute the path robustly or document that Cabal runs this test from the repository root after verifying the actual behavior.

Milestone 4 documents the workflow. Update `keiro-migrations/README.md` and, if needed, `docs/user/migrations.md` so developers know when and how to update expected schema files. The docs should say: add a forward SQL migration under `keiro-migrations/sql-migrations/`, run migrations on a fresh database, regenerate `keiro-migrations/expected-schema/`, inspect the expected-schema diff in git, and commit the SQL migration and representation together. Also document that fixture-only tests use no-check migrations by design and that `keiro-migrations-test` is the canonical schema drift gate.

Milestone 5 validates the full path. Run `cabal test keiro-migrations-test`, then at least one representative fixture-based suite such as `cabal test keiro-test` and `cabal test keiro-pgmq-test`. Finally run `just haskell-test` if time permits. Acceptance is that tests pass and ordinary fixture suites no longer print the codd mismatch line caused by the empty expected schema.


## Concrete Steps

Run all commands from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
```

First, confirm the working tree and avoid mixing unrelated changes into this plan:

```bash
git status --short
```

Unrelated untracked docs may already exist. Do not delete or rewrite them unless this plan explicitly needs them.

Inspect codd and Keiro migration APIs before editing:

```bash
mori show --full
mori registry show mzabani/codd --full
rg -n "runAllKeiroMigrations|runAllKeiroMigrationsNoCheck|LaxCheck|StrictCheck|onDiskReps|expected-schema" keiro-migrations keiro-test-support
```

Expected facts to confirm are that `keiro-migrations/src/Keiro/Migrations.hs` exports `runAllKeiroMigrationsNoCheck`, `Codd.VerifySchemas` includes `StrictCheck`, and codd settings can read expected schema files with `onDiskReps = Left <dir>`.

Generate or refresh the expected schema from a fresh migrated database. The exact command may be adjusted during Milestone 1 after confirming tool availability, but the target path must remain `keiro-migrations/expected-schema` and the schema selection must remain `kiroku`. If using the codd executable directly, the shape should be:

```bash
CODD_CONNECTION='<ephemeral database connection string>' \
CODD_MIGRATION_DIRS=unused-for-embedded-migrations \
CODD_EXPECTED_SCHEMA_DIR=keiro-migrations/expected-schema \
CODD_SCHEMAS=kiroku \
codd write-schema
```

If using a Keiro-specific helper instead, document its exact command in this section when it is added. The helper must first apply `runAllKeiroMigrationsNoCheck` to a fresh database and then write the codd representation of the resulting `kiroku` schema to `keiro-migrations/expected-schema`.

The implementation adds that helper as:

```bash
cabal run keiro-write-expected-schema
```

It starts an ephemeral PostgreSQL server, applies embedded Kiroku plus Keiro migrations with `runAllKeiroMigrationsNoCheck`, and writes the codd representation to `keiro-migrations/expected-schema`.

Edit `keiro-test-support/src/Keiro/Test/Postgres.hs`:

```text
Change migrateTemplate so it calls runAllKeiroMigrationsNoCheck.
Remove the empty DbRep expected-schema construction from fixture setup.
Keep CoddSettings fields that codd still needs to connect and apply migrations.
```

Edit `keiro-migrations/test/Main.hs`:

```text
Keep the existing repeatability/table smoke test, but use runAllKeiroMigrationsNoCheck.
Add a separate strict schema test that uses onDiskReps = Left "keiro-migrations/expected-schema" and StrictCheck.
Assert the strict result is SchemasMatch, or rely on StrictCheck throwing on mismatch and still pattern-match the result for clarity.
```

Update docs:

```text
In keiro-migrations/README.md, add a short "Updating expected schema" section.
In docs/user/migrations.md, make sure the documented local command and test behavior match the new checked-in expected-schema directory.
```

Run validation:

```bash
cabal test keiro-migrations-test
cabal test keiro-test
cabal test keiro-pgmq-test
just haskell-test
```

The first command should include the strict schema gate. The fixture-based suites should pass without the large `DB and expected schemas do not match` log caused by an empty expected schema.


## Validation and Acceptance

The primary acceptance check is:

```bash
cabal test keiro-migrations-test
```

Expected result: the test suite reports all examples passing. One example proves the migrations can be applied twice to a fresh database and that the expected framework tables exist in schema `kiroku`. A separate example proves the fully migrated database matches `keiro-migrations/expected-schema/<pg-major>/...` under codd `StrictCheck`.

To prove the fixture noise is gone, run:

```bash
cabal test keiro-test
cabal test keiro-pgmq-test
```

Expected result: both suites pass. Their setup may still print normal codd migration progress, but they must not print the large `Error: DB and expected schemas do not match` diff caused by comparing to `DbRep Null Map.empty Map.empty`.

To prove the schema gate is meaningful, do a local negative check before committing or record the result in Surprises & Discoveries. Temporarily edit or move one file under `keiro-migrations/expected-schema/<pg-major>/`, run `cabal test keiro-migrations-test`, and confirm the strict schema example fails. Restore the file before continuing. Do not commit the intentional break.

Full validation is:

```bash
just haskell-test
```

Expected result: all Haskell test suites pass. If Cabal/Nix produces a transient duplicate-rpath or build-cache error while tests run concurrently, rerun the failed test serially and record the exact output in Surprises & Discoveries rather than changing schema logic.


## Idempotence and Recovery

Regenerating `keiro-migrations/expected-schema/` is safe to repeat against a fresh migrated database. codd writes inside a PostgreSQL-major-version subdirectory and replaces that representation with the current live database representation. Always inspect `git diff -- keiro-migrations/expected-schema` after regeneration. A legitimate migration should produce a focused expected-schema diff that corresponds to the SQL migration. An unexpected broad diff means the database used for generation was not clean, the schema selection was wrong, or PostgreSQL major versions differ.

Changing fixture setup to `runAllKeiroMigrationsNoCheck` is safe because it only removes schema comparison from a path that never had a real expected schema. It still applies migrations through codd, so repeat runs continue to use codd's ledger and locking.

If the strict schema test fails immediately after generating expected schema, first check the PostgreSQL major version in the generated directory. codd reads `keiro-migrations/expected-schema/<server-major>/`, so a test server on PostgreSQL v16 will not use files generated only under `v15`. Either generate the missing major-version representation in a clean environment or align the test environment's PostgreSQL version.

If a helper command partially writes expected schema files and then fails, remove only the new or modified `keiro-migrations/expected-schema/` files from this plan's work and regenerate from a fresh database. Do not use destructive commands against the repository root or unrelated untracked files.


## Interfaces and Dependencies

Use `Keiro.Migrations` from `keiro-migrations/src/Keiro/Migrations.hs`:

```haskell
runAllKeiroMigrations :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
runAllKeiroMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ()
```

Use `runAllKeiroMigrationsNoCheck` for ordinary fixture setup and smoke tests that only need migrations applied. Use `runAllKeiroMigrations` with `StrictCheck` for the dedicated expected-schema comparison.

Use codd's public types from the `codd` package:

```haskell
data VerifySchemas = LaxCheck | StrictCheck
data ApplyResult = SchemasDiffer SchemasPair | SchemasMatch DbRep | SchemasNotVerified
data CoddSettings = CoddSettings
  { migsConnString :: ConnectionString
  , sqlMigrations :: [FilePath]
  , onDiskReps :: Either FilePath DbRep
  , namespacesToCheck :: SchemaSelection
  , extraRolesToCheck :: [SqlRole]
  , retryPolicy :: RetryPolicy
  , txnIsolationLvl :: TxnIsolationLvl
  , schemaAlgoOpts :: SchemaAlgo
  }
```

In test settings for schema verification, `onDiskReps` must be `Left "keiro-migrations/expected-schema"` so codd reads files from disk. In fixture setup, do not use `Right (DbRep Null Map.empty Map.empty)` because that is the source of the false-looking mismatch log.

Use `ephemeral-pg` only for throwaway PostgreSQL instances in tests. No production database is required for this plan. The generated expected-schema files should come from a fresh ephemeral database to avoid capturing application-owned objects or local development state.

The checked-in artifact at the end of the plan is:

```text
keiro-migrations/expected-schema/<postgres-major>/...
```

The exact subdirectories under `<postgres-major>` are owned by codd. Do not hand-edit individual representation files except for a temporary negative test that is restored before committing.
