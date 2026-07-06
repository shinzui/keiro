---
id: 90
slug: integrity-gates-for-kiroku-store-migrations-checksum-manifest-embed-parity-body-lint-and-ledger-canary
title: "Integrity gates for kiroku-store-migrations: checksum manifest, embed parity, body lint, and ledger canary"
kind: exec-plan
created_at: 2026-07-06T18:39:48Z
intention: "intention_01kwwbahspe0tazeaa1gk5w65b"
master_plan: "docs/masterplans/13-migration-hardening-integrity-gates-safe-apply-path-operator-tooling-and-the-migration-ownership-guide.md"
---

# Integrity gates for kiroku-store-migrations: checksum manifest, embed parity, body lint, and ledger canary

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

**Repository note:** all code in this plan lives in the **kiroku repository** at
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`, in its
`kiroku-store-migrations/` package. Commits are made in that repository, on its
`master` branch, with Conventional Commits messages and these trailers (the paths point
at the keiro repository, where the coordination documents live):

```text
MasterPlan: docs/masterplans/13-migration-hardening-integrity-gates-safe-apply-path-operator-tooling-and-the-migration-ownership-guide.md
ExecPlan: docs/plans/90-integrity-gates-for-kiroku-store-migrations-checksum-manifest-embed-parity-body-lint-and-ledger-canary.md
Intention: intention_01kwwbahspe0tazeaa1gk5w65b
```


## Purpose / Big Picture

kiroku's schema migrations are applied by codd (the Haskell migration runner
`mzabani/codd`, pinned at tag `v0.1.8`), which decides whether a migration already ran
by looking up its **filename** in a ledger table — it never hashes the file body. Three
corruption vectors follow, and today all three are guarded only by README prose: an
accidental edit to a shipped `.sql` body is undetectable; a newly added `.sql` file that
Template Haskell did not re-embed makes the compiled binary silently apply a stale
migration set; and nothing checks that the ledger actually ends up where our fixup
scripts and docs say it is (codd `v0.1.8` moved it from `codd_schema.sql_migrations` to
`codd.sql_migrations`).

After this plan, each vector is a failing test. Changing one byte of any file under
`kiroku-store-migrations/sql-migrations/` makes `cabal test kiroku-store-migrations-test`
fail with a checksum message naming the file, unless `migrations.lock` is deliberately
regenerated and committed alongside. Adding a `.sql` file without forcing the
Template-Haskell re-embed fails a parity test instead of shipping a stale binary. A lint
rejects future migrations that pin `search_path`, write unqualified DDL, or use `CREATE
INDEX CONCURRENTLY` without codd's `-- codd: no-txn` directive. A post-apply canary
asserts the ledger's location and full contents, and a regression test freezes the
ledger-fixup upgrade path (sentinel-named ledger → fixup → migrate is a no-op). All
validator logic lands in a new exposed library module, `Kiroku.Store.Migrations.Guards`,
so keiro (and any framework consumer) can reuse it instead of forking a third copy.


## Progress

- [x] M1: `Kiroku.Store.Migrations.Guards` module written and exported; existing test
      guards (`migrationFileNameSpec` helpers) rewired through it.
- [x] M2: `embeddedMigrationNames`/`embeddedMigrationSources` exported from
      `Kiroku.Store.Migrations`; embed-parity test added.
- [x] M3: `migrations.lock` generated and checked in; `kiroku-store-migrate lock`
      subcommand added; checksum test added; tamper drill performed and reverted.
- [x] M4: Body lint wired (`kiroku.` qualifier, bootstrap grandfathered,
      `search_path` ban, `CONCURRENTLY` ⇒ `-- codd: no-txn`).
- [x] M5: Ledger canary test (dual `codd`/`codd_schema` detection) added; ledger-fixup
      rewritten to be dual-schema aware; fixup regression test added.
- [x] M6: README and CHANGELOG updated (lock discipline, parity, ledger location).


## Surprises & Discoveries

- 2026-07-06: The plan text said the package had eight SQL migrations, but the
  working tree has seven real files under `kiroku-store-migrations/sql-migrations/`.
  The generated `migrations.lock` and test evidence therefore report seven
  migrations. The mismatch was in the plan prose, not the implementation.

  ```text
  Wrote migrations.lock (7 migrations)
  ```

- 2026-07-06: The planned fixup regression mentioned `Session.sql`, but this
  hasql version exposes `Session.script :: Text -> Session ()` for multi-statement
  scripts. The test uses `Session.script`, confirmed against the local hasql source
  located through mori.

- 2026-07-06: The linter initially misparsed `DROP INDEX IF EXISTS` as target `IF`.
  The implementation now skips both `IF NOT EXISTS` and `IF EXISTS` optional clauses
  before checking the target qualifier.


## Decision Log

- Decision: Guards are pure functions returning `[Text]` violations, with no hspec or
  codd dependency.
  Rationale: keiro's test suite and framework consumers must be able to reuse them from
  any test framework; the module must not drag test-only dependencies into the library.
  Date: 2026-07-06

- Decision: The checksum test verifies the **embedded** bytes (not the on-disk files)
  against `migrations.lock`, while `lock` regenerates the manifest from the on-disk
  directory.
  Rationale: verifying embedded bytes catches both body edits and stale embeds in one
  place; generating from disk is what an author editing files expects. The parity test
  (M2) makes the two views provably identical.
  Date: 2026-07-06

- Decision: Shipped migration bodies are never edited to satisfy the lint; pre-existing
  violations are grandfathered via the lint's exemption list.
  Rationale: codd keys applied-status by filename; editing shipped bodies is exactly the
  corruption vector this plan closes. The lint exists for future migrations.
  Date: 2026-07-06

- Decision: Rewrite `ledger-fixups/2026-07-05-realign-kiroku-migration-timestamps.sql`
  to resolve the ledger schema at runtime (a `DO` block that targets
  `codd.sql_migrations` when it exists, else `codd_schema.sql_migrations`).
  Rationale: codd `v0.1.8` (the current pin) stores fresh ledgers at
  `codd.sql_migrations` and auto-renames `codd_schema` → `codd` during any apply. The
  fixup as written targets only `codd_schema` and would fail on any database that has
  run a `v0.1.8` migrate. The fixup has already been applied to the known long-lived
  databases, so the file's remaining value is as a template — which must model the
  dual-schema reality.
  Date: 2026-07-06

- Decision: Use `crypton` for SHA-256 and `show (Digest SHA256)` for lowercase hex
  instead of adding `cryptohash-sha256` and `base16-bytestring`.
  Rationale: `mori registry search` found no registered local projects for
  `cryptohash-sha256` or `base16-bytestring`, while `kazu-yamamoto/crypton` was
  registered with local docs and source examples for `hashWith SHA256`. Keeping the
  manifest code on a registered dependency avoids guessing APIs and avoids an extra
  base16 dependency.
  Date: 2026-07-06

- Decision: Keep `kiroku-store-migrate lock` as an explicit case before the existing
  migration fall-through, but do not make the dispatcher strict in this plan.
  Rationale: EP-3 owns strict CLI dispatch. This plan only needs the new lock
  subcommand and must preserve the current apply behavior for every other argument.
  Date: 2026-07-06


## Outcomes & Retrospective

Completed on 2026-07-06. The kiroku repository now exposes
`Kiroku.Store.Migrations.Guards`, exports embedded migration names and sources, checks
the embedded migration set against a generated SHA-256 `migrations.lock`, lints future
DDL, asserts the codd v5 ledger contains exactly the embedded migrations, and proves the
historical sentinel-name fixup is safe before a repeat migrate. The README and CHANGELOG
document the lock discipline, embed parity, body lint, and dual ledger location.

Validation evidence:

```text
cabal build kiroku-store-migrations
Exit: 0

cabal test kiroku-store-migrations-test
11 examples, 0 failures
```

Acceptance drills were run and reverted:

```text
Tamper drill:
migrations.lock checksum mismatch for 2026-06-24-09-42-22-stream-truncate-before.sql

Embed-parity drill:
expected disk names included 2026-07-06-21-53-28-junk-parity-check.sql, but the embedded names did not.

Body-lint drill:
migration uses CONCURRENTLY without -- codd: no-txn: 2026-07-06-21-54-01-concurrent-index-drill.sql
```


## Context and Orientation

Work in `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. The package
`kiroku-store-migrations/` contains:

- `sql-migrations/*.sql` — seven timestamped migration files (a bootstrap,
  `2026-05-16-12-17-14-kiroku-bootstrap.sql`, plus six incrementals). Filenames are
  `YYYY-MM-DD-HH-MM-SS-<slug>.sql`; codd orders them lexicographically and records each
  in its ledger by filename.
- `src/Kiroku/Store/Migrations.hs` — embeds the directory at compile time with
  `$(embedDir "sql-migrations")` (Template Haskell from the `file-embed` package) into
  `embeddedMigrationFiles :: [(FilePath, ByteString)]` (currently **not exported**), and
  exposes `kirokuMigrations`, `runKirokuMigrations`, `runKirokuMigrationsNoCheck`.
  GHC does not track `embedDir`'s directory contents, so adding a `.sql` file does not
  recompile this module — the README calls this out as a hand-maintained hazard.
- `src/Kiroku/Store/Migrations/New.hs` — the `new` scaffolder (real-UTC filenames).
- `app/Main.hs` — the `kiroku-store-migrate` executable. Dispatch is currently
  `("new" : rest) -> generate …; _ -> migrate` (any other argument applies migrations —
  do not change that fall-through here; a later plan, keiro `docs/plans/92-…`, makes the
  dispatcher strict).
- `test/Main.hs` — hspec suite with `migrationFileNameSpec` (rejects sentinel
  timestamps), `scaffolderSpec`, apply/repeatability tests against an ephemeral
  PostgreSQL (the `ephemeral-pg` package, superuser pinned to `kiroku`), and a
  `StrictCheck` drift-gate test against `expected-schema/v18/`. Helper idioms to reuse:
  `withKirokuPg`, `findMigrationsDir` (candidate paths
  `["kiroku-store-migrations/sql-migrations", "sql-migrations"]` so the suite works from
  repo root or package dir), and hasql pools for assertions.
- `ledger-fixups/2026-07-05-realign-kiroku-migration-timestamps.sql` — a transactional,
  idempotent script that renames sentinel-timestamped ledger rows to the real authoring
  names. It currently hardcodes `codd_schema.sql_migrations`.

Facts about codd `v0.1.8` this plan relies on (verified in the checkout at
`/Users/shinzui/Keikaku/hub/haskell/codd-project`, tag `v0.1.8`): applied-status is a
filename lookup with no body hash; the ledger has `UNIQUE (name)` and
`UNIQUE (migration_timestamp)` (`src/Codd/InternalSchema/V1.hs:17`); internal-schema V5
renames `codd_schema` to `codd` (`src/Codd/Internal.hs:912-913`) and codd auto-upgrades
the internal schema during any apply, so a fresh database migrated under `v0.1.8` has
its ledger at `codd.sql_migrations`. "`-- codd: no-txn`" is codd's per-file directive
that applies a migration outside a transaction (required for `CREATE INDEX
CONCURRENTLY`, which PostgreSQL forbids inside a transaction).

A "sentinel timestamp" is a hand-assigned rounded filename time such as
`…-00-00-00-…` — the historical bug class the existing guard test rejects.


## Plan of Work

**Milestone 1 — the Guards module.** Create
`kiroku-store-migrations/src/Kiroku/Store/Migrations/Guards.hs`, exposed in the
library stanza of `kiroku-store-migrations.cabal`. Move (do not duplicate) the pure
helpers currently in `test/Main.hs` — `timestampWidth`, `isTimestampShaped`,
`timestampFields`, `handAssignedTimestamp` — and add:

```haskell
sentinelViolations           :: [FilePath] -> [Text]
duplicateTimestampViolations :: [FilePath] -> [Text]

data LintConfig = LintConfig
  { requiredQualifier :: Text     -- e.g. "kiroku."
  , exemptFiles       :: [FilePath]
  }
lintViolations :: LintConfig -> [(FilePath, ByteString)] -> [Text]

renderChecksumManifest :: [(FilePath, ByteString)] -> Text
parseChecksumManifest  :: Text -> Either Text [(FilePath, Text)]
checksumViolations     :: [(FilePath, Text)] -> [(FilePath, ByteString)] -> [Text]
sha256Hex              :: ByteString -> Text
```

Each violation is a human-readable sentence naming the offending file. Lint rules
(comment-stripped statement heuristics, documented as such in the Haddocks): (a) any occurrence of the
token `search_path` in a non-exempt file; (b) any `CREATE TABLE`, `CREATE [UNIQUE]
INDEX … ON`, `ALTER TABLE`, `DROP INDEX`, `CREATE [OR REPLACE] FUNCTION`, or `CREATE
TRIGGER … ON` whose target relation does not begin with `requiredQualifier` (skip
comment lines); (c) `CONCURRENTLY` anywhere in a file whose body lacks
`-- codd: no-txn`. The manifest format is one line per migration, sorted by filename:
`<sha256-hex><two spaces><filename>`, with a trailing newline. For SHA-256, use
`crypton`'s `hashWith SHA256` and the digest `Show` instance for lowercase hex, as
recorded in the Decision Log. Rewire `test/Main.hs`'s `migrationFileNameSpec` to call
`sentinelViolations`/`duplicateTimestampViolations` and delete the moved local helpers
(the `scaffolderSpec` imports move too). Acceptance: `cabal build` and the existing test
suite still pass, with the guards now imported from the library.

**Milestone 2 — embed parity.** In `src/Kiroku/Store/Migrations.hs`, export
`embeddedMigrationSources :: [(FilePath, ByteString)]` (equal to
`embeddedMigrationFiles`) and `embeddedMigrationNames :: [FilePath]` (its
`map fst`, sorted). Touch the embed comment per the module's own discipline. In
`test/Main.hs`, add a spec asserting `sort embeddedMigrationNames` equals the sorted
`.sql` listing of the on-disk directory found via `findMigrationsDir`. This is the test
that turns "I added a file but the binary is stale" from a silent hazard into a red
test: the test binary carries the stale embed, the disk has the new file, they differ.

**Milestone 3 — checksum manifest.** Add
`kiroku-store-migrations/migrations.lock` (generated, then checked in). Add a `lock`
subcommand to `app/Main.hs` as a new explicit case before the fall-through
(`("lock" : _) -> writeLock`): it reads the on-disk `sql-migrations/` directory
(honoring the existing `KIROKU_MIGRATIONS_DIR` override), renders the manifest with
`renderChecksumManifest`, writes `migrations.lock` in the current working directory,
and prints the path. Add a spec that parses the checked-in manifest (locate it with the
same two-candidate idiom as `findMigrationsDir`) and asserts
`checksumViolations manifest embeddedMigrationSources == []` — covering edited bodies,
missing entries, and extra entries. Perform the tamper drill (edit one byte of a
shipped migration, watch the test fail naming the file, revert) and record the failing
output in this plan.

**Milestone 4 — body lint.** Add a spec calling `lintViolations` over
`embeddedMigrationSources` with `requiredQualifier = "kiroku."` and `exemptFiles =
["2026-05-16-12-17-14-kiroku-bootstrap.sql"]` (the bootstrap legitimately sets
`search_path` once and writes unqualified DDL under it). Run it; if any *other* shipped
file trips a rule, add it to `exemptFiles` with a code comment explaining why — never
edit a shipped body — and note it in Surprises & Discoveries.

**Milestone 5 — ledger canary and fixup regression.** First rewrite the ledger fixup to
be dual-schema aware: wrap its `UPDATE`s in a `DO $$ … $$` block that sets a local
variable to `'codd'` when `to_regclass('codd.sql_migrations')` is non-null, else
`'codd_schema'`, and issues each update via `EXECUTE format(…)`; keep the
`BEGIN;`/`COMMIT;` wrapper, idempotence, and the header comments (updated to describe
the dual location). Then add two specs to `test/Main.hs`:

1. *Canary*: on a fresh ephemeral database, apply with `runKirokuMigrationsNoCheck`,
   detect the ledger schema (`SELECT to_regclass('codd.sql_migrations')`, falling back
   to `codd_schema`), assert it is `codd` (the `v0.1.8` behavior — if this ever fails
   after a codd bump, that is the canary firing), and assert `SELECT name FROM
   codd.sql_migrations ORDER BY name` equals `sort embeddedMigrationNames`.
2. *Fixup regression*: apply migrations, then rewrite the ledger rows **backwards** to
   their historical sentinel names using the (new → old) pairs read off the fixup's own
   `UPDATE` statements (hardcode the pairs in the test with a comment pointing at the
   fixup file), run the fixup script (read the file via a two-candidate path, execute
   with hasql `Session.script` — the simple query protocol accepts the multi-statement
   script), assert the ledger again equals the embedded names, then run
   `runKirokuMigrationsNoCheck` a second time and assert the ledger row count is
   unchanged (nothing re-applied, no duplicates).

**Milestone 6 — docs.** Update `kiroku-store-migrations/README.md`: document
`migrations.lock` and the `lock` subcommand (regenerate only for a deliberate,
reviewed change — normally the manifest changes only when a new migration is added);
state that embed parity and body lint are enforced by the test suite; and correct every
`codd_schema.sql_migrations` mention to describe the dual location ("codd ≥ 0.1.8
stores the ledger at `codd.sql_migrations` and renames `codd_schema` on first contact;
check `to_regclass` for both"). Add a CHANGELOG entry.


## Concrete Steps

Working directory `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` throughout.

```bash
cabal build kiroku-store-migrations            # after each milestone
cabal test kiroku-store-migrations-test        # full suite; needs local PostgreSQL tooling for ephemeral-pg
cd kiroku-store-migrations && cabal run kiroku-store-migrate -- lock   # M3: writes migrations.lock
```

Expected `lock` transcript:

```text
Wrote migrations.lock (7 migrations)
```

Tamper drill (M3), from the repo root:

```bash
printf ' ' >> kiroku-store-migrations/sql-migrations/2026-06-24-09-42-22-stream-truncate-before.sql
cabal test kiroku-store-migrations-test   # expect FAIL naming the file (embed must be refreshed first: touch the embed comment or `cabal clean`)
git checkout -- kiroku-store-migrations/sql-migrations
```

Note the Template-Haskell caveat cuts both ways during the drill: to see the checksum
test fail you must force the embed to pick up the tampered byte (touch the embed
comment in `src/Kiroku/Store/Migrations.hs`). If you skip that, the **parity/checksum
pair still catches it** — the embedded bytes match the manifest but the disk differs;
verify which test fires and record it in Surprises & Discoveries.

Commit after each milestone (Conventional Commits, e.g. `test(migrations): enforce a
sha256 manifest over embedded migration bodies`, with the three trailers from the
header of this plan).


## Validation and Acceptance

All of the following must hold at completion, run from the kiroku repo root:

1. `cabal test kiroku-store-migrations-test` passes.
2. The tamper drill fails the suite with a message naming the edited file, and passes
   again after revert.
3. Creating a junk migration (`cd kiroku-store-migrations && cabal run
   kiroku-store-migrate -- new "junk parity check"`) **without** touching the embed
   comment makes the parity test fail (stale embed detected); deleting the file
   restores green. (The checksum test also fails until `lock` is re-run — expected.)
4. A migration file containing `CREATE INDEX CONCURRENTLY` without `-- codd: no-txn`,
   temporarily added the same way, is rejected by the lint spec.
5. The canary spec proves the ledger is at `codd.sql_migrations` with exactly the
   embedded names; the fixup regression proves sentinel-ledger → fixup → re-migrate is
   a no-op.
6. `git grep -n "codd_schema" kiroku-store-migrations/README.md` shows only dual-aware
   wording (no unqualified claims that the ledger lives there).


## Idempotence and Recovery

Every milestone is additive test/tooling code plus doc edits; re-running any step is
safe. The only file with shipped-artifact semantics touched here is the ledger fixup —
its rewrite must preserve idempotence (each `UPDATE` maps 1:1 onto values that a second
run cannot match), which the regression test proves by running migrate after the fixup.
The tamper and junk-migration drills are deliberately reverted; do them on a clean
working tree so `git checkout --`/`rm` recovery is unambiguous. If `migrations.lock`
and the embedded set ever disagree unexpectedly, regenerate with the `lock` subcommand
only after confirming via `git diff -- kiroku-store-migrations/sql-migrations` that the
body change is intended and reviewed.


## Interfaces and Dependencies

At completion the following exist:

- `Kiroku.Store.Migrations.Guards` (exposed module,
  `kiroku-store-migrations/src/Kiroku/Store/Migrations/Guards.hs`) with the signatures
  listed in Milestone 1. Pure; depends only on `base`, `bytestring`, `text`,
  `filepath`, and `crypton`.
- `Kiroku.Store.Migrations.embeddedMigrationNames :: [FilePath]` and
  `Kiroku.Store.Migrations.embeddedMigrationSources :: [(FilePath, ByteString)]`.
- `kiroku-store-migrations/migrations.lock` checked in; `kiroku-store-migrate lock`
  regenerates it.
- The dual-schema ledger fixup at
  `kiroku-store-migrations/ledger-fixups/2026-07-05-realign-kiroku-migration-timestamps.sql`.

Downstream consumers: keiro's `docs/plans/91-…` imports `Guards` and the two accessors
after bumping the kiroku pin in keiro's `cabal.project`; keiro's `docs/plans/93-…`
reuses the dual-schema detection idiom. Keep all names above stable.


## Revision Notes

- 2026-07-06: Updated during implementation to mark all milestones complete, record
  the delivered `crypton` dependency choice, correct the migration count to seven,
  replace the stale `Session.sql` reference with `Session.script`, and capture
  validation evidence and drill outputs.
