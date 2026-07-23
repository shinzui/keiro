---
id: 122
slug: restore-live-schema-verification-body-lint-and-the-startup-handshake-under-pg-migrate
title: "Restore live schema verification, body lint, and the startup handshake under pg-migrate"
kind: exec-plan
created_at: 2026-07-23T03:02:27Z
intention: intention_01ky8hzdgxe7etqkgzfma64nj5
master_plan: "docs/masterplans/19-restore-the-migration-integrity-gates-under-pg-migrate-surfaced-by-the-2026-07-migration-review.md"
---

# Restore live schema verification, body lint, and the startup handshake under pg-migrate

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

In mid-July 2026 the keiro project replaced its migration runner, codd, with the in-house
pg-migrate library family. pg-migrate's core is verified sound — it applies each migration
and its ledger row in one atomic transaction, keys applied history by SHA-256 checksum, and
fails closed on edits, reorders, and gaps — but three continuous-verification gates that the
codd era enforced were silently lost in the swap, because they now exist only behind the
opt-in `legacy-codd-tools` cabal flag that nobody builds by default:

1. **Live schema-drift verification (finding MIG-1).** `keiro-migrate verify` today compares
   the declared plan against the *ledger* only — its own help text says "not live schema
   snapshots". A hand-altered `keiro.keiro_outbox` (a dropped index, a widened column) or a
   partial restore passes `verify`, and `up` proceeds. This also removed the only
   post-cutover proof that an imported alpha database's actual schema matches what the
   migrations would have built.
2. **The migration body lint (finding MIG-2).** The check that every migration body is
   schema-qualified and never touches `search_path` runs only in the flag-gated legacy test
   suite, over the frozen legacy files. The four native migrations added since
   (`0017-schema-management-comment.sql` through
   `0020-keiro-workflow-children-failure-reason.sql`) have never been linted; a future
   unqualified migration would reach production unchallenged.
3. **The `missingMigrations` startup handshake (finding MIG-3).** Services used to ask, at
   boot, "does the database carry every migration this binary expects?" and refuse to start
   otherwise. The only surviving implementation queries the retired codd ledger; the default
   `Keiro.Migrations` module exports no status API at all.

After this plan, all three gates are live in the **default** build: `cabal test
keiro-migrations-test` fails when a migration body is unqualified, when the checked-in
expected-schema snapshot no longer matches what the migrations build, or when the handshake
misbehaves; a new `keiro-migrate verify-schema` subcommand exits nonzero against a drifted
database and prints the drifted objects by name; and `Keiro.Migrations` exports
`missingMigrations` so every service can restore the boot-time handshake, with the pattern
documented in `docs/user/migrations.md`.


## Progress

- [x] (2026-07-23T22:42:00Z) Milestone 1: pure lint module ported into the default test suite; unqualified fixture fails; all 20 embedded bodies pass; `embeddedMigrationEntries` exported from the library. Validation: `cabal build keiro-migrations` and `cabal test keiro-migrations-test --test-show-details=direct` passed (14 examples, 0 failures).
- [ ] Milestone 2: `missingMigrations` and `StartupHandshake` exported from `Keiro.Migrations`; fresh/fully-migrated/half-applied tests green; `docs/user/migrations.md` Application startup section documents the handshake.
- [ ] Milestone 3: `Keiro.Migrations.SchemaCheck` library module with canonical snapshot, comparison, and embedded expected snapshot; checked-in `expected-schema/native/keiro-v18.txt` generated and validated by a suite test with a regeneration mode.
- [ ] Milestone 4: `keiro-migrate verify-schema` subcommand wired; drifted-database integration test exits with named drifted objects; `docs/user/migrations.md` documents `verify-schema`; suite green end to end.


## Surprises & Discoveries

- Discovery: The current branch contains migrations
  `0019-keiro-snapshots-state-shape-hash.sql` and
  `0020-keiro-workflow-children-failure-reason.sql`, added after this plan was authored.
  The native manifest therefore contains 20 Keiro migrations and the composed plan contains
  28 migrations (8 Kiroku plus 20 Keiro), not 18 and 26.
  Evidence: `keiro-migrations/test/Main.hs` already asserts 20 Keiro entries and 28 composed
  outcomes, and both files are present in `keiro-migrations/migrations/manifest`.
  Date: 2026-07-23


## Decision Log

- Decision: Copy the pure lint validators into the default test suite instead of depending
  on `codd-extras`.
  Rationale: The finding pointed at `Kiroku.Store.Migrations.Guards`, but that module was
  reduced to a re-export shim of `Codd.Extras.Guards` (kiroku commit 47df1f7) and then
  deleted outright when kiroku adopted pg-migrate (kiroku commit 15e6fe2, 2026-07-10). The
  real validators live in `/Users/shinzui/Keikaku/bokuno/codd-extras/src/Codd/Extras/Guards.hs`,
  and the `codd-extras` library depends on `codd` — adding it to the default test suite
  would drag the retired codd family back into the default build closure, which the
  master plan explicitly excludes. The functions are ~120 lines of pure `Data.Text`
  scanning; copying them with a provenance comment is cheaper and keeps the closure clean.
  Date: 2026-07-23

- Decision: Drop the CONCURRENTLY half of the legacy lint and document why.
  Rationale: pg-migrate wraps every transactional migration's SQL and its ledger insert in
  one transaction (`transactionalAction`, pg-migrate `Runner.hs`). PostgreSQL rejects
  `CREATE INDEX CONCURRENTLY` inside a transaction block outright, so the mistake the codd
  lint guarded against can no longer reach production silently — it fails the very first
  fresh-database application, which the default suite performs on every run. Authors who
  genuinely need CONCURRENTLY must use pg-migrate's `-- pg-migrate: no-transaction` leading
  comment (recognized by pg-migrate's SQL scanner), which is a reviewable, explicit opt-out.
  Date: 2026-07-23

- Decision: Implement live schema verification as a new keiro-owned canonical snapshot
  format (tables, columns, constraints, indexes of the `keiro` schema rendered as sorted
  text lines from `pg_catalog`), not a port of codd's JSON object-representation files.
  Rationale: The legacy `expected-schema/v18/` tree is codd's own representation format
  (per-object JSON files hashed by codd's algorithm); reimplementing it faithfully means
  reimplementing a large slice of codd. The master-plan deliverable is behavioral — "verify
  against a drifted database exits nonzero and prints the differing objects" — and a
  four-object-class canonical text snapshot satisfies it while staying diffable in review.
  Roles and database settings, which the legacy snapshot also covered and which forced the
  suite to pin the PostgreSQL superuser name, are deliberately out of scope: they made the
  legacy gate machine-sensitive and protect nothing the master plan asks for.
  Date: 2026-07-23

- Decision: Expose the live check as a new `verify-schema` subcommand rather than extending
  `verify`.
  Rationale: `verify` is parsed and handled entirely inside pg-migrate-cli
  (`migrationCommandParser`); changing its semantics would require an upstream release,
  which the master plan forbids for this plan ("EP-1 consumes existing public API and must
  not require an upstream release"). A keiro-side subcommand is additive and leaves the
  upstream ledger-verify contract untouched.
  Date: 2026-07-23

- Decision: The new expected-schema snapshot covers PostgreSQL 18 only, matching the
  existing `v18` naming.
  Rationale: The master plan keeps the pre-existing PG-17-snapshot exclusion excluded.
  Date: 2026-07-23

- Decision: Implement the restored gates against the current 20-file Keiro manifest and
  28-entry composed plan.
  Rationale: Integrity gates must cover every migration shipped by the current branch.
  Freezing the tests at the plan-authoring count would leave the two newest schema changes
  outside the lint and startup-handshake acceptance.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Everything in this plan happens in the keiro repository (working directory
`/Users/shinzui/Keikaku/bokuno/keiro`, paths below are repository-relative), with read-only
reference to two sibling checkouts: the pg-migrate repository at
`/Users/shinzui/Keikaku/bokuno/pg-migrate` (local source of the `pg-migrate` 1.1.0.0
family the cabal file pins) and the kiroku repository at
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` (the sibling event-store ledger whose
migration component runs before keiro's).

`docs/adr/` contains exactly one ADR, `0001-keiro-pgmq-job-processing-telemetry-contract.md`
(pgmq telemetry). It is not relevant to migrations; no relevant ADR exists for this work.

**The package.** `keiro-migrations/` ships keiro's schema migrations. Its library
(`keiro-migrations/keiro-migrations.cabal`) depends on `pg-migrate ^>=1.1.0.0`,
`pg-migrate-embed ^>=1.1.0.0`, and `pg-migrate-import-codd ^>=1.1.0.0` (cabal lines
331-333). The old codd toolchain survives only behind the manual, default-False cabal flag
`legacy-codd-tools` (declared at cabal lines 298-304): with the flag on, the library gains
`Keiro.Migrations.ExpectedSchema`, `Keiro.Migrations.LegacyCodd`, and
`Keiro.Migrations.New` plus codd dependencies (lines 337-349), the
`keiro-write-expected-schema` executable becomes buildable (lines 368-381), and the
`keiro-migrations-legacy-test` suite (source `keiro-migrations/test-legacy/Main.hs`)
becomes buildable (lines 406-439). The **default** test suite is named
`keiro-migrations-test` (cabal line 383, source `keiro-migrations/test/Main.hs`), and it is
what CI runs: the repository has no `.github/` workflows — verification is `just verify`
from the repo root, whose final step is `cabal test keiro-migrations-test`.

**The migrations.** `keiro-migrations/migrations/` holds 20 immutable SQL files
(`0001-keiro-bootstrap.sql` … `0016-keiro-inbox-drop-received-idx.sql` are byte-identical
ports of the 16 codd-era files; `0017-schema-management-comment.sql`, `0018.sql`,
`0019-keiro-snapshots-state-shape-hash.sql`, and
`0020-keiro-workflow-children-failure-reason.sql` are native-era additions) plus the ordered
`manifest` file. The library embeds them at compile time:
`keiro-migrations/src/Keiro/Migrations/Internal/Definition.hs` calls pg-migrate-embed's
`embedMigrationManifest "migrations/manifest"` producing `embeddedMigrationEntries ::
NonEmpty (FilePath, ByteString)`, and builds the `keiro` component with a declared
dependency on `kiroku`. `keiro-migrations/src/Keiro/Migrations.hs` currently exports only
`DefinitionError`, `MigrationComponent`, `MigrationPlan`, `PlanError`,
`frameworkMigrationPlan`, and `keiroMigrations` — no status API of any kind (this is
finding MIG-3's evidence). `frameworkMigrationPlan kiroku keiro` composes the two concrete
components in dependency order (kiroku first).

**The CLI.** `keiro-migrations/app/Main.hs` (executable `keiro-migrate`) is a thin shell
around pg-migrate-cli: it builds the framework plan, parses with pg-migrate-cli's
`migrationCommandParser` (subcommands `plan`, `status`, `verify`, `list`, `check`, `up`,
`repair`, `new`), dispatches with `runMigrationCommand`, and renders text or `--json`.
Note there is no keiro-side subcommand today; this plan introduces the first one. The
sibling plan `docs/plans/124-guard-up-against-codd-ledgered-databases-and-mount-the-codd-import-in-the-cli.md`
also adds keiro-side subcommands to this same parser; the master plan's integration rule is
that both plans are strictly additive and coordinate only on merge order — whichever lands
second adds its constructors to the wrapper type the first one created.

**What pg-migrate's verify actually checks.** In
`/Users/shinzui/Keikaku/bokuno/pg-migrate/pg-migrate/src/Database/PostgreSQL/Migrate/Inspection.hs`
(lines 56-63), `verifyMigrationPlanWith` is a read-only session running `loadVerification`,
which loads the `pgmigrate.migrations` ledger table and compares it to the declared plan
(checksums, positions, kinds, transaction modes, gaps, unknown rows). It never inspects
`pg_catalog`. The CLI help text is explicit
(`pg-migrate-cli/src/Database/PostgreSQL/Migrate/CLI/Parser.hs` line 45): "Strictly compare
the declared plan with the migration ledger (not live schema snapshots)". That is exactly
the MIG-1 gap: ledger-consistent but schema-drifted databases pass.

**The legacy mechanisms being replaced** (read them for orientation; none of their code is
reused directly):

- Drift: `Keiro.Migrations.ExpectedSchema` (flag-gated) embeds the codd-format
  `keiro-migrations/expected-schema/v18/` snapshot tree and materializes it to a temp dir;
  `Keiro.Migrations.LegacyCodd.verifySchema` hands it to codd, which re-derives per-object
  JSON representations from `pg_catalog` and diffs. The legacy suite proves drift detection
  by `ALTER TABLE keiro.keiro_timers ALTER COLUMN last_error SET NOT NULL` and expecting
  `SchemasDiffer`. Note the `v18` tree is **stale relative to the native plan**: it predates
  `0018.sql` and has no `keiro_dead_letters` table — correct for the 16-file legacy world it
  documents, wrong as a native gate. It stays frozen as transition evidence; this plan adds
  a new snapshot rather than touching it.
- Lint: legacy suite `test-legacy/Main.hs` line 162 ("keeps future migration bodies
  schema-qualified and codd-safe") calls `lintViolations` from `Codd.Extras.Guards` over the
  16 legacy sources with `requiredQualifier = "keiro."`. The validator source is
  `/Users/shinzui/Keikaku/bokuno/codd-extras/src/Codd/Extras/Guards.hs`: it strips comment
  lines, splits on `;`, recognizes `CREATE/ALTER TABLE`, `DROP INDEX`, `CREATE [UNIQUE]
  INDEX … ON`, `CREATE [OR REPLACE] FUNCTION`, `CREATE TRIGGER … ON`, extracts the target
  identifier (skipping `IF [NOT] EXISTS`), and requires the `keiro.` prefix; it separately
  flags any non-comment mention of `search_path`, and (obsolete here) any `CONCURRENTLY`
  without codd's no-txn marker.
- Handshake: `Keiro.Migrations.LegacyCodd.missingMigrations` (lines 59-61) delegates to a
  codd-extras query over the codd ledger — the wrong ledger after cutover. The pg-migrate
  replacement primitive already exists and is public: `migrationStatusWith :: RunOptions ->
  ConnectionProvider -> MigrationPlan -> IO (Either MigrationError StatusReport)` in
  `Database.PostgreSQL.Migrate` (implemented in `Inspection.hs`), where `StatusReport`
  carries `issues`, `appliedMigrations`, `pendingMigrations`, `unknownMigrations`. This plan
  must not require any pg-migrate change; if the public API proves insufficient, record the
  gap here and escalate to the master plan instead of patching upstream.

**How the default suite provisions databases.** `keiro-migrations/test/Main.hs` uses two
patterns, both of which the new tests must follow. For a database with the full plan
applied: `withMigratedDatabase plan callback` from `Database.PostgreSQL.Migrate.Test`
(package `pg-migrate-test-support`), which starts an ephemeral-pg server, runs the plan,
and brackets a connection around the callback. For a database the test controls itself:
`withKeiroPg` (defined in the same file), which calls `EphemeralPg.startCached` with
`Pg.defaultConfig{Pg.user = "keiro"}` and `Pg.defaultCacheConfig`, then `Pg.stop`. Do not
reach for `keiro-test-support` (`Keiro.Test.Postgres.withMigratedSuite`): that fixture is
for consumer suites that want an already-migrated template database, and the migration
suite must control migration application itself.

**Documentation ownership.** Per the master plan, this plan owns the "Application startup"
section and the verify-related prose of `docs/user/migrations.md`. Sibling plans own
`docs/user/migration-ownership.md`'s manifest statement (`docs/plans/123-add-the-embed-recompile-plugin-and-native-manifest-coverage.md`)
and `docs/user/upgrading-to-the-keiro-schema.md`'s cutover sequence (`docs/plans/124-…`).
Do not touch those sections here.


## Plan of Work

The work is four milestones ordered smallest-first so the suite is demonstrably green after
each: the lint (pure code, no database), the handshake (one query, three tests), the schema
snapshot library (the substantial new design), and finally the CLI subcommand with the
drifted-database proof and documentation.

### Milestone 1 — the body lint runs in the default suite (MIG-2)

Scope: port the pure lint validators into the default test suite and run them over all 20
embedded migration bodies. At the end, an unqualified fixture body fails the lint, all real
bodies pass, and the check runs on every `cabal test keiro-migrations-test`.

First make the embedded entries reachable from tests. Edit
`keiro-migrations/src/Keiro/Migrations.hs`: add `embeddedMigrationEntries` to the export
list and import it from `Keiro.Migrations.Internal.Definition` (which already exports it
module-locally). This is additive; the library's other consumers are unaffected.

Create `keiro-migrations/test/Lint.hs`, module `Lint`, containing the ported validators.
Port from `/Users/shinzui/Keikaku/bokuno/codd-extras/src/Codd/Extras/Guards.hs` exactly
these definitions, keeping their behavior: `LintConfig` (fields `requiredQualifier :: Text`,
`exemptFiles :: [FilePath]`), `lintViolations`, `statementTarget`, `startsWithWords`,
`targetAfter`, `targetAfterToken`, `skipIfNotExists`, `stripCommentLines`, `cleanTarget`,
`oneLine`, and the `search_path` check. Omit `concurrentlyViolation` and delete its call
site. Add a header comment recording provenance and the reason for the omission, in this
spirit:

```haskell
{- | Pure migration-body lint, ported from codd-extras (Codd.Extras.Guards) when the
codd toolchain moved behind the legacy-codd-tools flag. The codd-era CONCURRENTLY
check is deliberately dropped: pg-migrate runs transactional migrations inside a
single transaction, and PostgreSQL rejects CREATE INDEX CONCURRENTLY in a
transaction block, so the mistake fails the first fresh-database test run instead
of needing a lint. Genuinely non-transactional migrations must carry pg-migrate's
"-- pg-migrate: no-transaction" leading comment, which review gates.
-}
```

Register the module: in `keiro-migrations/keiro-migrations.cabal`, add `other-modules:
Lint` to the `keiro-migrations-test` stanza. The suite already depends on `text` and
`bytestring`; no new dependencies are needed.

Add a spec to `keiro-migrations/test/Main.hs` (import `Lint`):

- "flags an unqualified DDL target": `lintViolations (LintConfig "keiro." []) [("9999-fixture.sql", "CREATE TABLE widgets (id int);")]` yields exactly one violation whose text names `9999-fixture.sql`.
- "flags a search_path mention": a fixture body containing `SET search_path TO keiro;` yields a violation.
- "ignores comment-only mentions": a body whose only `search_path` occurrence is on a `--` comment line yields no violations.
- "passes all 20 embedded native bodies": `lintViolations (LintConfig "keiro." []) (toList embeddedMigrationEntries)` is `[]`. (Expected to hold: 0001-0016 are byte-identical to the legacy files the legacy lint already passed, 0017 is a `COMMENT ON SCHEMA` the lint does not target, 0018 qualifies both its `CREATE TABLE` and `CREATE INDEX`, and 0019-0020 qualify their `ALTER TABLE` targets. If a body unexpectedly fails, do not add it to `exemptFiles` without recording why in the Decision Log.)

Acceptance: `cabal test keiro-migrations-test` green; temporarily un-qualifying a target in
a scratch copy of the fixture demonstrates the failure output.

### Milestone 2 — native missingMigrations and the documented handshake (MIG-3)

Scope: a small status API in the default library, three behavioral tests, and the
documentation of the startup-handshake pattern.

Edit `keiro-migrations/src/Keiro/Migrations.hs` to add and export:

```haskell
-- | Boot-time answer to "does this database carry every migration this binary expects?".
data StartupHandshake = StartupHandshake
    { pendingMigrations :: [MigrationId]
      -- ^ Declared migrations with no applied ledger row, in plan order.
    , ledgerIssues :: [VerificationIssue]
      -- ^ Checksum/position/kind/gap/unknown-row problems; nonempty means refuse startup.
    }

handshakePassed :: StartupHandshake -> Bool
handshakePassed handshake =
    null (pendingMigrations handshake) && null (ledgerIssues handshake)

-- | Read-only; safe to call from every replica at boot.
missingMigrations ::
    RunOptions ->
    ConnectionProvider ->
    MigrationPlan ->
    IO (Either MigrationError StartupHandshake)
```

Implement `missingMigrations` on `migrationStatusWith` alone: call it, and map the
resulting `StatusReport{issues, pendingMigrations}` into `StartupHandshake`. Re-export the
types callers need to consume the result without importing pg-migrate directly:
`MigrationId`, `VerificationIssue (..)`, `RunOptions`, `defaultRunOptions`,
`ConnectionProvider`, `connectionProviderFromSettings`, `MigrationError` (all already
public from `Database.PostgreSQL.Migrate`). Under `defaultRunOptions` the unknown-rows
policy is `RejectUnknownMigrations`, so ledger rows outside the plan surface as
`UnknownStoredMigration` issues — the strict default a startup gate wants; callers with an
application component in the same ledger pass their full composed plan instead.

Tests in `keiro-migrations/test/Main.hs` (a new `describe "startup handshake"`):

- Fresh database: inside `withKeiroPg`, with no migrations applied, `missingMigrations
  defaultRunOptions provider plan` returns `pendingMigrations` equal to all 28 plan ids
  (8 Kiroku plus 20 Keiro, in plan order) and `ledgerIssues = []`. (An absent `pgmigrate`
  schema is a defined state: `loadLedger` returns an empty snapshot, so everything is
  pending and nothing errors.)
- Fully migrated: inside `withMigratedDatabase plan`, the handshake returns `[]` pending,
  `[]` issues, `handshakePassed` True.
- Half-applied returns the tail: inside `withKeiroPg`, first apply only the kiroku
  component (`kirokuOnly <- requireRight (migrationPlan (kiroku :| []))` then
  `runMigrationPlan defaultRunOptions settings kirokuOnly`), then call
  `missingMigrations` with the full framework plan; `pendingMigrations` must be exactly the
  20 Keiro ids in order and `ledgerIssues` must be `[]`.

Documentation: rewrite the "Application startup" section of `docs/user/migrations.md`
(currently lines 65-78; this plan owns that section). Keep the deployment-job guidance and
`SkipSchemaInitialization` snippet, and add the restored handshake: run migrations as a
deployment job, and *also* have every service replica call `missingMigrations` at boot and
refuse to serve until it passes, closing the gap where a replica starts against a database
the job has not reached yet. Include a compilable sketch:

```haskell
import Keiro.Migrations

guardMigrations :: ConnectionProvider -> MigrationPlan -> IO ()
guardMigrations provider plan = do
    result <- missingMigrations defaultRunOptions provider plan
    case result of
        Right handshake | handshakePassed handshake -> pure ()
        Right handshake -> fail ("refusing startup: " <> show handshake)
        Left err -> fail ("migration handshake failed: " <> show err)
```

Acceptance: suite green; the three new tests pass; the docs section reads as a complete
pattern without referencing legacy modules.

### Milestone 3 — the SchemaCheck library and the checked-in native snapshot (MIG-1, part 1)

Scope: a default-build library module that renders a canonical text snapshot of the live
`keiro` schema, compares two snapshots into named drift, and embeds a checked-in expected
snapshot; plus the suite test that keeps the checked-in snapshot honest, with a
regeneration mode.

Create `keiro-migrations/src/Keiro/Migrations/SchemaCheck.hs` (add to the library's
`exposed-modules`; also add `hasql >=1.10 && <1.11` to the library's `build-depends` — the
library does not currently depend on hasql, only the executable and tests do). The module:

```haskell
module Keiro.Migrations.SchemaCheck (
    SchemaDrift (..),
    compareSchemaSnapshot,
    expectedSchemaSnapshot,
    renderSchemaDrift,
    snapshotSchema,
    verifyExpectedSchema,
) where
```

`snapshotSchema :: Text -> Hasql.Session.Session Text` runs one read-only query and
returns the canonical snapshot: one line per object, tab-separated
`kind<TAB>name<TAB>definition`, sorted bytewise, covering exactly four object classes in
the named schema — tables (`pg_class` relkind `r`), columns (`pg_attribute` with
`format_type`, not-null marker, and `pg_get_expr` of the default), constraints
(`pg_constraint` with `pg_get_constraintdef`), and indexes (`pg_index` with
`pg_get_indexdef`). One statement suffices:

```sql
SELECT line FROM (
  SELECT 'table' || E'\t' || c.relname || E'\t' || 'kind=r' AS line
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = $1 AND c.relkind = 'r'
  UNION ALL
  SELECT 'column' || E'\t' || c.relname || '.' || a.attname || E'\t'
         || format_type(a.atttypid, a.atttypmod)
         || CASE WHEN a.attnotnull THEN ' not null' ELSE '' END
         || coalesce(' default ' || pg_get_expr(d.adbin, d.adrelid), '')
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    WHERE n.nspname = $1 AND c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped
  UNION ALL
  SELECT 'constraint' || E'\t' || rel.relname || '.' || con.conname || E'\t'
         || pg_get_constraintdef(con.oid)
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = rel.relnamespace
    WHERE n.nspname = $1
  UNION ALL
  SELECT 'index' || E'\t' || ci.relname || E'\t' || pg_get_indexdef(i.indexrelid)
    FROM pg_index i
    JOIN pg_class ci ON ci.oid = i.indexrelid
    JOIN pg_class ct ON ct.oid = i.indrelid
    JOIN pg_namespace n ON n.oid = ct.relnamespace
    WHERE n.nspname = $1
) snapshot ORDER BY line
```

Sequences are covered indirectly: `0018.sql`'s `BIGSERIAL` shows up as the
`keiro_dead_letters.dead_letter_id` column default (`nextval(...)`) and its `pkey`
constraint and index, which is the drift signal that matters. Ownership, grants, roles, and
database settings are deliberately not snapshotted (see Decision Log).

`SchemaDrift` names each difference:

```haskell
data SchemaDrift
    = MissingObject Text      -- ^ Expected line absent from the live database.
    | UnexpectedObject Text   -- ^ Live line absent from the expected snapshot.
    | ChangedObject
        { driftKey :: Text      -- ^ "kind<TAB>name"
        , expectedDefinition :: Text
        , actualDefinition :: Text
        }
```

`compareSchemaSnapshot :: Text -> Text -> [SchemaDrift]` splits both snapshots into lines,
keys each line by its first two tab-separated fields, and classifies: key only in expected
is `MissingObject`, key only in actual is `UnexpectedObject`, same key different definition
is `ChangedObject`. `renderSchemaDrift :: SchemaDrift -> Text` produces one human line, for
example `schema drift: missing index keiro_outbox_pending_idx (expected: CREATE INDEX …)`.

`expectedSchemaSnapshot :: Text` embeds the checked-in file with the existing helper
`Keiro.Migrations.Internal.EmbedFile.embedTextFile "expected-schema/native/keiro-v18.txt"`
(that helper calls `addDependentFile`, so *content* changes to an existing snapshot file
retrigger compilation; only wholly new sibling files have the recompilation caveat that
`docs/plans/123-add-the-embed-recompile-plugin-and-native-manifest-coverage.md` addresses).
`verifyExpectedSchema :: ConnectionProvider -> IO (Either MigrationError [SchemaDrift])`
brackets a connection (mirror how `Inspection.hs` uses `useDedicatedConnection`, mapping
connection errors to `ConnectionAcquisitionFailed` and session errors to
`DatabaseSessionFailed`), snapshots schema `keiro`, and compares against the embedded
expectation. Register the new snapshot path under `extra-source-files` in the cabal file.

Bootstrapping the snapshot (chicken-and-egg: the library embeds a file the suite
generates): create `keiro-migrations/expected-schema/native/keiro-v18.txt` as an empty file
first so the library compiles, then generate it with the suite's regeneration mode below,
then rebuild so the embedded copy refreshes.

Suite test, in `keiro-migrations/test/Main.hs` (`describe "native expected schema"`),
"checked-in snapshot matches what the migrations build": inside `withMigratedDatabase
plan`, compute `snapshotSchema "keiro"` on the live connection, locate the checked-in file
on disk with the existing `findFile` helper (candidates
`keiro-migrations/expected-schema/native/keiro-v18.txt` and
`expected-schema/native/keiro-v18.txt`), and compare disk content to the live snapshot.
When the environment variable `KEIRO_REGENERATE_EXPECTED_SCHEMA` is set (any value), write
the live snapshot to the disk file and pass, printing the path; otherwise a mismatch fails
with the first differing lines and the regeneration instruction. Comparing against the
*disk* file (not the embedded copy) is what makes regeneration a one-command loop and makes
a stale embed a build-ordering problem rather than a silent pass. Add a second, pure test
for the comparator: two synthetic snapshots exercising each `SchemaDrift` constructor.

Acceptance: after regeneration and rebuild, the suite is green; `git diff` shows a
readable, sorted snapshot including `keiro_dead_letters` lines (proof the new gate covers
the object the frozen legacy snapshot misses); deleting one line from the checked-in file
makes the suite test fail naming that line.

### Milestone 4 — the verify-schema subcommand, the drifted-database proof, and docs (MIG-1, part 2)

Scope: the operator-facing entry point, the end-to-end drift test, and the documentation.

Rework `keiro-migrations/app/Main.hs` to a wrapper command type. If the sibling plan
`docs/plans/124-…` has already landed its wrapper, add a constructor; otherwise create:

```haskell
data KeiroCommand
    = Framework MigrationCommand
    | VerifySchema VerifySchemaOptions

newtype VerifySchemaOptions = VerifySchemaOptions
    { databaseSettings :: Maybe Settings.Settings
    }

keiroCommandParser :: MigrationPlan -> Parser KeiroCommand
keiroCommandParser plan =
    (Framework <$> migrationCommandParser plan)
        <|> subparser
            ( commandGroup "Keiro"
                <> command
                    "verify-schema"
                    ( info
                        (VerifySchema <$> verifySchemaOptionsParser <**> helper)
                        (progDesc "Compare live keiro schema objects against the embedded expected snapshot")
                    )
            )
```

with `verifySchemaOptionsParser` offering the same `--database-url URL` option the upstream
commands use (falling back to `DATABASE_URL`, exactly as `main` already does for the
default settings). Dispatch: `Framework cmd` goes through the existing
`runMigrationCommand` path unchanged; `VerifySchema opts` builds a `ConnectionProvider`
from the selected settings, calls `verifyExpectedSchema`, prints `schema verification
succeeded` and exits 0 on `Right []`, prints each `renderSchemaDrift` line and exits 1 on
`Right drifts`, prints the error and exits 1 on `Left`. Output is text-only for now (record
any future `--json` need in the Decision Log rather than speculating).

Integration test in `keiro-migrations/test/Main.hs`, "verify-schema detects a hand-altered
database": inside `withMigratedDatabase plan`, first assert `verifyExpectedSchema` (via a
provider over the callback connection, using the existing `providerFor` helper) returns
`Right []`; then mutate the schema the way the finding describes —

```sql
DROP INDEX keiro.keiro_outbox_pending_idx;
ALTER TABLE keiro.keiro_outbox ALTER COLUMN correlation_id TYPE character varying(64);
```

— and assert the result is `Right drifts` where the rendered drift lines include
`keiro_outbox_pending_idx` (a `MissingObject` for the index) and
`keiro_outbox.correlation_id` (a `ChangedObject` for the column type). This is the same
predicate the CLI exits nonzero on, so the library test plus the manual CLI transcript in
Validation covers the master-plan deliverable.

Documentation, in `docs/user/migrations.md` (sections this plan owns): in "Inspect and
apply", extend the command list and bullets — `verify` checks plan-versus-ledger; the new
`verify-schema` checks ledger-era truth against the *live* `pg_catalog` state of the
`keiro` schema and is the post-restore / post-cutover drift gate; recommend running both in
deployment. In "Repository verification", mention that the default suite regenerates
nothing by itself and that `KEIRO_REGENERATE_EXPECTED_SCHEMA=1 cabal test
keiro-migrations-test` refreshes the snapshot after an intentional schema change (always
review the diff). Do not edit the cutover runbook or the ownership guide (sibling-owned).

Acceptance: suite green; manual CLI transcript against an ephemeral database shows exit 0
clean and exit 1 with named objects after the mutation.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

Milestone 1:

```bash
# after editing src/Keiro/Migrations.hs, adding test/Lint.hs, and the cabal other-modules line
cabal build keiro-migrations
cabal test keiro-migrations-test
```

Expect the new lint specs listed in the hspec output, all green, e.g.:

```text
migration body lint
  flags an unqualified DDL target [✔]
  flags a search_path mention [✔]
  ignores comment-only mentions [✔]
  passes all 20 embedded native bodies [✔]
```

Milestone 2:

```bash
cabal build keiro-migrations
cabal test keiro-migrations-test
```

The three handshake examples must appear and pass; the half-applied one proves the tail
shape (20 Keiro ids).

Milestone 3 (note the bootstrap ordering):

```bash
mkdir -p keiro-migrations/expected-schema/native
touch keiro-migrations/expected-schema/native/keiro-v18.txt
cabal build keiro-migrations
KEIRO_REGENERATE_EXPECTED_SCHEMA=1 cabal test keiro-migrations-test \
  --test-options='--match "checked-in snapshot"'
cabal build keiro-migrations   # refresh the embedded copy from the regenerated file
cabal test keiro-migrations-test
git add keiro-migrations/expected-schema/native/keiro-v18.txt
```

Spot-check the generated snapshot:

```bash
grep -c $'\t' keiro-migrations/expected-schema/native/keiro-v18.txt
grep keiro_dead_letters keiro-migrations/expected-schema/native/keiro-v18.txt | head -3
```

Expect several hundred lines and `keiro_dead_letters` table/column/constraint/index lines
present.

Milestone 4 manual CLI check (needs a scratch PostgreSQL; any database you can create and
drop works — the transcript below assumes the dev cluster from `just db-start` or an
ephemeral one):

```bash
export DATABASE_URL='host=/tmp port=5432 dbname=verify_drill user=keiro'
cabal run keiro-migrate -- up
cabal run keiro-migrate -- verify-schema
psql "$DATABASE_URL" -c 'DROP INDEX keiro.keiro_outbox_pending_idx;'
cabal run keiro-migrate -- verify-schema; echo "exit=$?"
```

Expected tail of the transcript:

```text
schema verification succeeded
...
schema drift: missing index keiro_outbox_pending_idx (expected: CREATE INDEX keiro_outbox_pending_idx ON keiro.keiro_outbox ...)
exit=1
```

Finally:

```bash
just verify
```

must end green (it finishes with `cabal test keiro-migrations-test`).


## Validation and Acceptance

The plan is complete when all of the following hold, each observable by running the stated
command from the repository root:

1. `cabal test keiro-migrations-test` passes, and its output lists the lint, handshake, and
   native-expected-schema example groups.
2. Lint gate: adding a scratch fixture body `CREATE TABLE widgets (id int);` to the lint's
   fixture list (or, equivalently, un-qualifying a target in a copy) produces a failing
   example whose message names the offending file and statement; reverting restores green.
3. Handshake: the fresh-database example asserts 28 pending ids, the migrated example
   asserts zero, the half-applied example asserts exactly the 20 Keiro ids — these encode
   the master-plan acceptance "fresh DB returns the full embedded list, fully-migrated DB
   returns empty, half-applied returns the tail".
4. Drift gate, library level: the "verify-schema detects a hand-altered database" example
   passes, proving a dropped index and a changed column type are reported by name against a
   database that pg-migrate's ledger `verify` would call clean.
5. Drift gate, operator level: the Milestone 4 CLI transcript shows exit 0 on a freshly
   migrated database and exit 1 with the drifted object named after the manual `DROP
   INDEX`.
6. Snapshot honesty: deleting any line from
   `keiro-migrations/expected-schema/native/keiro-v18.txt` makes the suite fail naming that
   line; `KEIRO_REGENERATE_EXPECTED_SCHEMA=1` regenerates it byte-identically on an
   unchanged schema (run twice; `git diff` must be empty the second time).
7. No pg-migrate source change: `git -C /Users/shinzui/Keikaku/bokuno/pg-migrate status`
   is untouched by this plan.


## Idempotence and Recovery

Every step is safe to repeat. The lint and comparator are pure; the tests create only
ephemeral databases (ephemeral-pg tears them down, and `startCached` reuses a cached
server). Snapshot regeneration overwrites one checked-in text file and is deterministic for
a given PostgreSQL major version — if a regeneration diff looks wrong, `git checkout --
keiro-migrations/expected-schema/native/keiro-v18.txt` restores the prior snapshot. The
Milestone 4 manual drill mutates only the scratch database you created; drop it afterwards
(`dropdb verify_drill`) or rerun `keiro-migrate up` plus a manual index recreate — nothing
in the repository depends on that database's state. If Milestone 3's bootstrap ordering is
done out of order (suite run before the empty snapshot file exists), the library simply
fails to compile with a missing-file TH error; create the file and rebuild. All cabal edits
are additive (new module, new export, one new dependency), so `git checkout` of the touched
files is a complete rollback at any point.


## Interfaces and Dependencies

Libraries used, all already released and pinned: `pg-migrate ^>=1.1.0.0`
(`Database.PostgreSQL.Migrate`: `migrationStatusWith`, `StatusReport (..)`,
`VerificationIssue (..)`, `MigrationId`, `RunOptions`, `defaultRunOptions`,
`ConnectionProvider`, `connectionProviderFromSettings`, `MigrationError (..)`),
`pg-migrate-test-support ^>=1.1.0.0` (`Database.PostgreSQL.Migrate.Test.withMigratedDatabase`),
`ephemeral-pg` (suite database lifecycle), `hasql >=1.10 && <1.11` (newly added to the
*library* for `SchemaCheck`'s session; already a dependency of the executable and tests),
and `optparse-applicative` (already an executable dependency) for the new subcommand. No
pg-migrate upstream change is permitted; `migrationStatusWith` and the exported ledger
types are sufficient for everything here — if an insufficiency is discovered, stop, record
it in this plan's Decision Log, and escalate to the master plan.

Signatures that must exist at the end of each milestone:

- Milestone 1: `Keiro.Migrations.embeddedMigrationEntries :: NonEmpty (FilePath, ByteString)`
  (re-export); `Lint.lintViolations :: LintConfig -> [(FilePath, ByteString)] -> [Text]`
  and `Lint.LintConfig` with `requiredQualifier :: Text`, `exemptFiles :: [FilePath]`
  (test-suite module).
- Milestone 2: `Keiro.Migrations.missingMigrations :: RunOptions -> ConnectionProvider ->
  MigrationPlan -> IO (Either MigrationError StartupHandshake)`;
  `Keiro.Migrations.StartupHandshake` with `pendingMigrations :: [MigrationId]` and
  `ledgerIssues :: [VerificationIssue]`; `Keiro.Migrations.handshakePassed ::
  StartupHandshake -> Bool`.
- Milestone 3: `Keiro.Migrations.SchemaCheck.snapshotSchema :: Text -> Session Text`;
  `compareSchemaSnapshot :: Text -> Text -> [SchemaDrift]`; `SchemaDrift (..)`;
  `renderSchemaDrift :: SchemaDrift -> Text`; `expectedSchemaSnapshot :: Text`;
  `verifyExpectedSchema :: ConnectionProvider -> IO (Either MigrationError [SchemaDrift])`.
- Milestone 4: `keiro-migrate verify-schema [--database-url URL]` exiting 0 on a clean
  database and 1 on drift or error, printing one `renderSchemaDrift` line per drift.

Cross-plan interface: the `KeiroCommand` wrapper in `keiro-migrations/app/Main.hs` is
shared with `docs/plans/124-guard-up-against-codd-ledgered-databases-and-mount-the-codd-import-in-the-cli.md`;
both plans add constructors additively and coordinate only on merge order.


Revision note (2026-07-23): Updated the plan from the 18-file/26-entry authoring snapshot to
the current 20-file/28-entry migration plan after discovering migrations 0019 and 0020 on
the active branch. The implementation and all acceptance counts now cover every shipped
migration.
