# Keiro database migrations

`keiro-migrations` exports a native `pg-migrate` component named `keiro`. The
component owns sixteen embedded SQL migrations and declares one dependency,
`kiroku`. Applications compose Kiroku first and Keiro second; Keiro never embeds
or copies Kiroku's SQL.

```haskell
import Keiro.Migrations (frameworkMigrationPlan, keiroMigrations)
import Kiroku.Store.Migrations qualified as Kiroku

plan = do
  kiroku <- Kiroku.kirokuMigrations
  keiro <- keiroMigrations
  frameworkMigrationPlan kiroku keiro
```

The `keiro-migrate` executable builds that plan and exposes the standard
`pg-migrate` commands. Set `DATABASE_URL` or pass the connection option shown by
the command help:

```bash
cabal run keiro-migrate -- plan
cabal run keiro-migrate -- status
cabal run keiro-migrate -- verify
cabal run keiro-migrate -- up
```

`status` and `verify` are read-only. `up` serializes concurrent callers with the
`pg-migrate` advisory lock, applies all Kiroku migrations before Keiro, and
reports already-applied migrations without replaying them.

## Authoring native migrations

The ordered manifest is `keiro-migrations/migrations/manifest`. Migration names
are stable component-local identifiers such as `0016-keiro-inbox-drop-received-idx`;
the timestamped files under `sql-migrations/` and `migrations.lock` remain
immutable legacy evidence for old Codd databases.

Create new work through the standard CLI and review the manifest append together
with the new SQL file:

```bash
cabal run keiro-migrate -- new \
  --manifest keiro-migrations/migrations/manifest \
  --description "add order summary"
cabal run keiro-migrate -- check keiro-migrations/migrations/manifest
```

Never edit a migration that has shipped. Add a new forward migration for every
schema correction.

## Importing the shared Codd ledger

`Keiro.Migrations.History.Codd` combines Kiroku's seven mappings with Keiro's
sixteen mappings. `frameworkCoddSourceConfig` selects both histories from the
shared `codd.sql_migrations` or legacy `codd_schema.sql_migrations` ledger,
checks the original SHA-256 manifests and payload bytes, and produces one atomic
history import:

```haskell
config <-
  either (fail . show) pure $
    frameworkCoddSourceConfig provider True reason Confirmed

result <-
  importCoddHistory
    defaultImportOptions
    config
    provider
    plan
    frameworkCoddHistoryMappings
```

Run the import while legacy migration writers are quiescent, then run strict
`verify`. A partial row, missing payload, changed manifest, or unexpected row in
strict mode fails before either target component is imported.

Databases first migrated by `keiro-migrations 0.1.0.0` may have `keiro_*`
tables under `kiroku`. Follow
[Upgrading To The Keiro Schema](../docs/user/upgrading-to-the-keiro-schema.md)
before importing their history.

## Legacy transition tools

Codd expected-schema snapshots, remediation drills, and sentinel-ledger fixup
tests remain available only through the manual `legacy-codd-tools` flag. They do
not enter the normal library, executable, or test-support dependency closure:

```bash
cabal test -flegacy-codd-tools \
  keiro-migrations:keiro-migrations-legacy-test
cabal run -flegacy-codd-tools keiro-write-expected-schema
```

The normal migration suite is:

```bash
cabal test keiro-migrations:keiro-migrations-test
```
