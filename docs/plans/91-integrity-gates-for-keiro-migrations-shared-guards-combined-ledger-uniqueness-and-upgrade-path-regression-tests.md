---
id: 91
slug: integrity-gates-for-keiro-migrations-shared-guards-combined-ledger-uniqueness-and-upgrade-path-regression-tests
title: "Integrity gates for keiro-migrations: shared guards, combined-ledger uniqueness, and upgrade-path regression tests"
kind: exec-plan
created_at: 2026-07-06T18:39:48Z
intention: "intention_01kwwbahspe0tazeaa1gk5w65b"
master_plan: "docs/masterplans/13-migration-hardening-integrity-gates-safe-apply-path-operator-tooling-and-the-migration-ownership-guide.md"
---

# Integrity gates for keiro-migrations: shared guards, combined-ledger uniqueness, and upgrade-path regression tests

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

All code in this plan lives in **this repository** (`/Users/shinzui/Keikaku/bokuno/keiro`),
in the `keiro-migrations/` package, except the one-line kiroku pin bump in
`cabal.project`. Commit trailers for every commit:

```text
MasterPlan: docs/masterplans/13-migration-hardening-integrity-gates-safe-apply-path-operator-tooling-and-the-migration-ownership-guide.md
ExecPlan: docs/plans/91-integrity-gates-for-keiro-migrations-shared-guards-combined-ledger-uniqueness-and-upgrade-path-regression-tests.md
Intention: intention_01kwwbahspe0tazeaa1gk5w65b
```

**Hard dependency:** `docs/plans/90-integrity-gates-for-kiroku-store-migrations-checksum-manifest-embed-parity-body-lint-and-ledger-canary.md`
must be Complete in the kiroku repository first — this plan imports the
`Kiroku.Store.Migrations.Guards` module and the `embeddedMigrationNames` accessor that
plan publishes.


## Purpose / Big Picture

`keiro-migrations` embeds keiro's framework migrations and applies them **together with
kiroku's** through one codd ledger (`Keiro.Migrations.allKeiroMigrations` concatenates
`Kiroku.kirokuMigrations <> keiroFrameworkMigrations`; codd sorts the union by
timestamp). That combined ledger has `UNIQUE (name)` and `UNIQUE (migration_timestamp)`
constraints, so a timestamp collision **between a kiroku migration and a keiro
migration** — something no current test checks — would break every framework user's
migrate at apply time. Separately, keiro has the same three unguarded corruption
vectors kiroku had (editable shipped bodies, stale Template-Haskell embeds, unverified
ledger location), no round-trip test for its scaffolder, and two shipped upgrade-path
artifacts — the ledger fixup and the MasterPlan-12 alpha remediation script — that are
proven only by the manual runbook, not by CI.

After this plan: a one-byte edit to any `keiro-migrations/sql-migrations/*.sql` fails
`cabal test keiro-migrations-test` against a checked-in `migrations.lock`; a stale
embed fails a parity test; a body lint enforces `keiro.`-qualified DDL; a uniqueness
test covers the **kiroku ∪ keiro** timestamp union; a post-apply canary asserts the
combined ledger's location and exact contents; the scaffolder has kiroku's round-trip
test; and two regression tests freeze the upgrade paths — sentinel-ledger → fixup →
no-op migrate, and 0.1.0.0-layout → remediation → no-op migrate with zero row loss.


## Progress

- [ ] M1: kiroku pin bumped in `cabal.project` to the SHA containing plan 90's work;
      keiro test guards rewired through `Kiroku.Store.Migrations.Guards`;
      `scaffolderSpec` ported.
- [ ] M2: `embeddedMigrationNames`/`embeddedMigrationSources` exported from
      `Keiro.Migrations`; embed-parity test added.
- [ ] M3: `keiro-migrations/migrations.lock` checked in; `keiro-migrate lock`
      subcommand; checksum test; tamper drill performed and reverted.
- [ ] M4: Body lint (`keiro.` qualifier, no exemptions expected) and the
      combined-ledger timestamp-uniqueness test added.
- [ ] M5: Combined-ledger canary; keiro ledger fixup rewritten dual-schema; fixup
      regression test added.
- [ ] M6: Alpha-remediation regression test (0.1.0.0 layout, seeded rows, zero loss,
      strict check) added.
- [ ] M7: README, `docs/user/migrations.md`, and
      `docs/user/upgrading-to-the-keiro-schema.md` ledger-location corrections;
      CHANGELOG entry.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Import guards from `Kiroku.Store.Migrations.Guards` rather than duplicating
  them in keiro.
  Rationale: keiro already depends on `kiroku-store-migrations`; a third fork of the
  validator logic is exactly what this initiative exists to prevent. The cross-project
  shared library idea remains parked in
  `docs/plans/52-shared-codd-migration-scaffold-library-design-capture.md`.
  Date: 2026-07-06

- Decision: The uniqueness test runs over the union of both packages' embedded names,
  not just keiro's directory.
  Rationale: only keiro maintains the combined ledger, so the union invariant is
  keiro's to enforce; kiroku's own suite cannot see keiro's filenames.
  Date: 2026-07-06

- Decision: The remediation regression test constructs the 0.1.0.0 layout by applying
  the current migrations and then moving the `keiro_*` tables back into the `kiroku`
  schema, rather than by replaying archived 0.1.0.0 SQL bodies.
  Rationale: MasterPlan 12 kept every migration filename and the remediation script is
  guarded per-table by `to_regclass`, so "tables in `kiroku`, ledger already naming the
  current files" is exactly the state a real 0.1.0.0 database is in before the runbook.
  Reverse-moving reproduces that state from current code with no archived-DDL
  maintenance burden.
  Date: 2026-07-06


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The `keiro-migrations/` package contains: `sql-migrations/*.sql` (sixteen
`keiro`-schema-qualified migrations, bootstrap
`2026-05-17-13-58-15-keiro-bootstrap.sql` first — none set `search_path`);
`src/Keiro/Migrations.hs` (embeds the directory via `$(embedDir "sql-migrations")` into
the non-exported `embeddedMigrationFiles`, and exposes `keiroFrameworkMigrations`,
`allKeiroMigrations`, and the `run*` helpers — `runAllKeiroMigrations*` apply
kiroku-then-keiro through one ledger); `src/Keiro/Migrations/New.hs` (the `keiro-migrate
new` scaffolder); `app/Main.hs` (dispatch `("new":rest) -> generate; _ -> migrate` —
leave the fall-through alone; plan 92 makes it strict);
`ledger-fixups/2026-07-05-realign-keiro-migration-timestamps.sql` (fourteen `UPDATE`s
mapping old sentinel names → real names, currently hardcoding
`codd_schema.sql_migrations`); `remediation/2026-07-05-relocate-keiro-tables-to-keiro-schema.sql`
(a `DO` block that `ALTER TABLE kiroku.<t> SET SCHEMA keiro` for the eleven `keiro_*`
tables, each guarded by `to_regclass` — it never touches the ledger); and `test/Main.hs`
(hspec: `migrationFileNameSpec` with local timestamp helpers, an apply/repeatability
test asserting table placement across the `kiroku`/`keiro`/`public` schemas, and a
`StrictCheck` drift-gate test scoped to the `keiro` namespace, all against ephemeral
PostgreSQL with the superuser pinned to `keiro` via `withKeiroPg`). Unlike kiroku's
suite, there is **no** `scaffolderSpec` here — port it.

The kiroku dependency is pinned in `cabal.project` by two `source-repository-package`
stanzas (`location: https://github.com/shinzui/kiroku.git`, subdirs `kiroku-store` and
`kiroku-store-migrations`) sharing one `tag:` SHA. Plan 90 added, in the kiroku repo:
`Kiroku.Store.Migrations.Guards` (pure validators: `sentinelViolations`,
`duplicateTimestampViolations`, `LintConfig`/`lintViolations`,
`renderChecksumManifest`/`parseChecksumManifest`/`checksumViolations`, `sha256Hex`) and
exported `embeddedMigrationNames`/`embeddedMigrationSources` from
`Kiroku.Store.Migrations`. This plan mirrors plan 90's milestones for keiro, so read
that plan's Context and Plan of Work sections first
(`docs/plans/90-integrity-gates-for-kiroku-store-migrations-checksum-manifest-embed-parity-body-lint-and-ledger-canary.md`);
only the deltas are spelled out below. codd facts (v0.1.8): filename-keyed ledger, dual
`codd`/`codd_schema` ledger location with auto-rename on apply, `UNIQUE(name)` +
`UNIQUE(migration_timestamp)`.


## Plan of Work

**Milestone 1 — pin bump and guard rewiring.** In the kiroku repository confirm plan
90's work is on `master` and note the SHA (`git -C
/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku rev-parse HEAD`). Update both
kiroku `tag:` fields in `cabal.project` to that SHA (`chore(deps): bump kiroku pin …`).
In `keiro-migrations/test/Main.hs`, delete the local `timestampWidth`/
`isTimestampShaped`/`timestampFields`/`handAssignedTimestamp` helpers and rewire
`migrationFileNameSpec` through `Kiroku.Store.Migrations.Guards` (the test suite
already depends on `kiroku-store-migrations`; add the Guards import). Port
`scaffolderSpec` from kiroku's `test/Main.hs`, adapted to `Keiro.Migrations.New` (check
`Keiro/Migrations/New.hs` for the slug convention — if keiro slugs carry a prefix,
assert that; kiroku's are bare) and asserting the generated body is `keiro.`-qualified
and `search_path`-free.

**Milestone 2 — embed parity.** Export `embeddedMigrationNames` and
`embeddedMigrationSources` from `src/Keiro/Migrations.hs` (touch the embed comment).
Parity spec: embedded names == sorted on-disk `.sql` listing via the existing
`findMigrationsDir` idiom.

**Milestone 3 — checksum manifest.** `keiro-migrate lock` subcommand in `app/Main.hs`
(new explicit case before the fall-through; honors `KEIRO_MIGRATIONS_DIR`; writes
`migrations.lock` in the working directory using Guards' render function). Check in
`keiro-migrations/migrations.lock`. Checksum spec over the **embedded** sources
(locate the manifest with a two-candidate path like `findMigrationsDir`). Tamper drill
as in plan 90 (edit a byte, force the Template-Haskell re-embed by touching the embed
comment, watch the named failure, revert; record the output here).

**Milestone 4 — lint and combined uniqueness.** Lint spec with `requiredQualifier =
"keiro."` and `exemptFiles = []` — the MasterPlan-12 rewrite qualified every body, so
expect zero violations; if any shipped file trips a rule, grandfather it in
`exemptFiles` with a comment (never edit a shipped body) and record it in Surprises &
Discoveries. Uniqueness spec: `duplicateTimestampViolations
(Kiroku.Store.Migrations.embeddedMigrationNames <> Keiro.Migrations.embeddedMigrationNames)
== []` — the combined-ledger invariant. Keep the existing keiro-only strictly-increasing
check too.

**Milestone 5 — combined canary and fixup regression.** Rewrite
`ledger-fixups/2026-07-05-realign-keiro-migration-timestamps.sql` with the same
dual-schema `DO $$ … EXECUTE format(…) $$` pattern plan 90 established for kiroku's
fixup (target `codd.sql_migrations` when `to_regclass` finds it, else
`codd_schema.sql_migrations`; keep `BEGIN;`/`COMMIT;`, idempotence, updated header).
Canary spec: after `runAllKeiroMigrationsNoCheck`, assert the ledger is at
`codd.sql_migrations` and `SELECT name … ORDER BY name` equals the sorted **union** of
both packages' embedded names. Fixup regression: apply, reverse-rename the fourteen
keiro rows to their sentinel names (pairs hardcoded in the test from the fixup file,
with a comment pointing at it), execute the fixup file via hasql `Session.sql` (the
simple query protocol accepts the multi-statement script), assert the ledger equals the
union again, re-run `runAllKeiroMigrationsNoCheck`, assert the ledger row count is
unchanged (nothing re-applied, no duplicates).

**Milestone 6 — remediation regression.** New spec on a fresh ephemeral database:

1. Apply all migrations (`runAllKeiroMigrationsNoCheck`).
2. Recreate the 0.1.0.0 layout: for each of the eleven `keiro_*` tables named in the
   remediation script's array, execute `ALTER TABLE keiro.<t> SET SCHEMA kiroku`
   (guarded by `to_regclass` so the step is order-tolerant), then `DROP SCHEMA keiro`.
3. Seed data that must survive: one row into `kiroku.keiro_snapshots` (columns
   `stream_id, stream_version, state, state_codec_version, regfile_shape_hash`) and one
   into `kiroku.keiro_timers`.
4. Execute `remediation/2026-07-05-relocate-keiro-tables-to-keiro-schema.sql` verbatim
   via `Session.sql` (two-candidate path lookup).
5. Assert: every `keiro_*` table is back in `keiro` and absent from `kiroku` (reuse
   `assertTablesExist`/`assertTablesAbsent`); both seeded rows exist with their values
   intact; a further `runAllKeiroMigrationsNoCheck` leaves the ledger row count
   unchanged; and `runAllKeiroMigrations … StrictCheck` returns `SchemasMatch` (the
   remediated database passes the drift gate).
6. Run the remediation a second time and assert nothing changes (idempotence).

Update the remediation file's header comments and its commented verification query for
the dual ledger location (the script body never touches the ledger — no logic change).

**Milestone 7 — docs.** Correct `codd_schema.sql_migrations` claims to dual-aware
wording in `keiro-migrations/README.md`, `docs/user/migrations.md`, and
`docs/user/upgrading-to-the-keiro-schema.md`; document `migrations.lock` and the `lock`
subcommand in the README; CHANGELOG entry.


## Concrete Steps

Working directory `/Users/shinzui/Keikaku/bokuno/keiro` throughout.

```bash
git -C /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku rev-parse HEAD   # SHA for the pin bump
cabal build keiro-migrations
cabal test keiro-migrations-test
cd keiro-migrations && cabal run keiro-migrate -- lock && cd ..
```

Expected `lock` transcript:

```text
Wrote migrations.lock (16 migrations)
```

Tamper drill:

```bash
printf ' ' >> keiro-migrations/sql-migrations/2026-06-15-21-49-37-keiro-projection-dedup.sql
# touch the embed comment in src/Keiro/Migrations.hs to force the re-embed, then:
cabal test keiro-migrations-test        # expect a checksum failure naming the file
git checkout -- keiro-migrations
```

Commit per milestone with the trailers from the plan header.


## Validation and Acceptance

1. `cabal test keiro-migrations-test` passes at every milestone boundary.
2. The tamper drill fails with the file named; revert restores green.
3. A junk `keiro-migrate new` file without an embed refresh fails the parity test;
   deleting it restores green.
4. Temporarily feeding the uniqueness spec a colliding pair (e.g. append a copy of one
   kiroku name to the keiro list inside the test) makes it fail; remove the edit.
5. The fixup regression proves sentinel-ledger → fixup → migrate is a no-op on the
   combined ledger; the remediation regression proves 0.1.0.0-layout → remediation →
   migrate is a no-op with both seeded rows surviving and `StrictCheck` green, twice.
6. `git grep -n "codd_schema" keiro-migrations docs/user` shows only dual-aware wording.


## Idempotence and Recovery

All milestones are additive tests/tooling/docs plus two shipped-template rewrites (the
fixup's dual-schema `DO` block — idempotence proven by its regression test — and the
remediation's comments only). Drills are reverted via `git checkout --`. The pin bump
is a one-line change; if the pinned SHA lacks plan 90's exports, `cabal build` fails
immediately and the fix is to re-check plan 90's completion and re-bump. Regenerate
`migrations.lock` only via the `lock` subcommand after reviewing
`git diff -- keiro-migrations/sql-migrations`.


## Interfaces and Dependencies

Consumes (from plan 90, via the bumped pin): `Kiroku.Store.Migrations.Guards`
(everything) and `Kiroku.Store.Migrations.embeddedMigrationNames`.

Provides at completion: `Keiro.Migrations.embeddedMigrationNames :: [FilePath]` and
`Keiro.Migrations.embeddedMigrationSources :: [(FilePath, ByteString)]` (plan 93's
`status`/handshake and plan 94's guide depend on these names being stable);
`keiro-migrations/migrations.lock`; the `lock` subcommand; the dual-schema keiro ledger
fixup; and the two regression suites that plan 94 will cite as the tested upgrade
paths.
