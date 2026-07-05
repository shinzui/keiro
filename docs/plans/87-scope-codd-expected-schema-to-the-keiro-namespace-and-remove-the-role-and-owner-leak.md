---
id: 87
slug: scope-codd-expected-schema-to-the-keiro-namespace-and-remove-the-role-and-owner-leak
title: "Scope codd expected-schema to the keiro namespace and remove the role and owner leak"
kind: exec-plan
created_at: 2026-07-05T18:39:12Z
intention: "intention_01kwsrmsbsedqb0rh0vb41x04m"
master_plan: "docs/masterplans/12-keiro-schema-separation-and-migration-architecture-rework.md"
---

# Scope codd expected-schema to the keiro namespace and remove the role and owner leak

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Keiro is an event-sourcing framework written in Haskell. It stores its state in PostgreSQL
and uses a tool called **codd** (the Haskell library `mzabani/codd`) to apply SQL
migrations and to guard against *schema drift* — the situation where the SQL migration
files and the actual database shape fall out of sync. codd does this by keeping a
checked-in **expected-schema snapshot**: a tree of small JSON files under
`keiro-migrations/expected-schema/` that describes every table, column, constraint, index,
trigger, sequence, routine, role, and database setting. A dedicated test,
`cabal test keiro-migrations-test`, applies all migrations to a throwaway PostgreSQL
database and asserts (with codd's `StrictCheck`) that the resulting live schema is
**byte-for-byte equal** to the checked-in snapshot. If they differ, the test fails.

Today that drift gate has two defects that this plan fixes.

First, the snapshot is scoped to the wrong PostgreSQL **schema**. A PostgreSQL *schema* is
a namespace inside one database (not the whole database); unqualified table names resolve
against a session's `search_path`. codd's setting `namespacesToCheck = IncludeSchemas
[SqlSchema "kiroku"]` tells it to capture the `kiroku` schema. But `kiroku` is the private
namespace of the separate event-store library Keiro depends on (the package
`shinzui/kiroku`). Historically Keiro squatted its own framework tables (`keiro_snapshots`,
`keiro_timers`, `keiro_outbox`, and so on) inside that `kiroku` schema, so the snapshot
captured **both** libraries' tables interleaved and coupled Keiro's drift gate to kiroku's
internal layout. After the sibling plan EP-1
(`docs/plans/85-rewrite-keiro-migrations-to-own-a-dedicated-keiro-schema-with-qualified-ddl.md`)
moves Keiro's tables into a dedicated `keiro` schema, this plan re-scopes the snapshot to
the `keiro` namespace so it contains **only** `keiro_*` objects and never gates kiroku's
tables.

Second, and more seriously, the snapshot is **not portable across machines**. It captured
the snapshot author's *local database role* and *database owner*. Concretely, the file
`keiro-migrations/expected-schema/v18/roles/shinzui` is a full PostgreSQL role definition
named `shinzui`, and `keiro-migrations/expected-schema/v18/db-settings` records
`"owner": "shinzui"` and `"public_privileges": "[[\"cT\", \"shinzui\"]]"`. Every per-object
JSON file (for example `.../tables/keiro_timers/objrep`) also records `"owner": "shinzui"`.
The name `shinzui` is the snapshot author's operating-system username. It leaked because the
test harness `ephemeral-pg` (the package `shinzui/ephemeral-pg`, used to spin up throwaway
PostgreSQL servers) initialises its cluster with the **local OS user** as the PostgreSQL
superuser and object owner. On any other developer's machine — or in CI — the OS username is
different (say `alice` or `runner`), so the live database returns roles and owners named
`alice`, which cannot equal the checked-in `shinzui`, and the strict drift gate
**false-fails** even though nothing is actually wrong. This plan makes the snapshot portable
by pinning the throwaway server's user to a fixed, machine-independent name so the captured
identity is deterministic everywhere.

**What you can do after this change that you could not before.** After this plan, a
developer whose OS username is *not* `shinzui` (or a CI runner named `runner`) can check out
the repository and run `cabal test keiro-migrations-test` and it passes. Running
`cabal run keiro-write-expected-schema` regenerates the snapshot into
`keiro-migrations/expected-schema/v18/schemas/keiro/` containing only `keiro_*` objects, with
no interleaved `kiroku` tables and no OS-username-derived identifiers anywhere in the tree.
The drift gate remains meaningful: perturbing a single column in the snapshot still makes the
strict test fail. You can see the portability directly by grepping the regenerated tree for
your own or the author's username and finding nothing:
`grep -R shinzui keiro-migrations/expected-schema` returns no matches.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0 (2026-07-05): EP-1 has landed — `keiro-migrations/test/Main.hs` asserts `keiroTables`
      present in `keiro`, absent from `kiroku`/`public`; migrations `CREATE SCHEMA keiro` and
      qualify `keiro.<table>`.
- [x] M1 (2026-07-05, prototyping): Confirmed against this tree's pinned codd
      (`Codd/Representations/Database.hs`): `rolesToCheck = (SqlRole . Text.pack . user $
      migsConnString) : extraRolesToCheck` — the connecting user's role is always captured;
      `namespacesToCheck` scopes only schemas, not roles/db-settings. Confirmed ephemeral-pg
      exports `Config(..)`/`user`/`defaultConfig`/`startCached`/`stop` and `getUsername` honors
      a non-empty `config.user` (passed to `initdb --username=`). Fix confirmed feasible.
- [x] M2 (2026-07-05): `namespacesToCheck` changed `kiroku` → `keiro` in all three builders
      (`WriteExpectedSchema.coddSettings`, `test/Main.testCoddSettings`,
      `Keiro/Test/Postgres.templateCoddSettings`); reworded the `templateCoddSettings` doc
      comment. `cabal build keiro-migrations keiro-test-support` green.
- [x] M3 (2026-07-05): Added `keiroPgConfig = defaultConfig{user="keiro"}` to the write exe and
      the test; write exe switched to `startCached ... \`finally\` stop`; test added
      `withKeiroPg` helper and both examples now use it. `cabal build keiro-migrations-test`
      green (one harmless `-Wambiguous-fields` warning). Left `templateCoddSettings` on the
      default user (never strict-checks).
- [x] M4 (2026-07-05): Regenerated. `git status` = 115 deletions + 2 new dirs + 1 modified;
      `schemas/` now holds only `keiro` (all 11 `keiro_*` tables), `roles/` only `keiro`,
      `db-settings` `owner: keiro`/`public_privileges [["cT","keiro"]]`; no kiroku event tables;
      `grep -R shinzui keiro-migrations/expected-schema` → nothing (exit 1).
- [x] M5 (2026-07-05): `cabal test keiro-migrations-test` → 4 examples, 0 failures.
      `USER=notshinzui cabal test keiro-migrations-test` also passes (identity is machine-
      independent). Negative test: flipping `keiro_timers/cols/last_error` `notnull` false→true
      made the strict example fail with `different-schemas` on
      `schemas/keiro/tables/keiro_timers/cols/last_error`; restoring passed again (not
      committed). Fixture suites `keiro-test` and `keiro-pgmq-test` both PASS.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-05: Milestone 1 confirmed (a)–(d) from the plan. The pinned codd
  (`Codd/Representations/Database.hs:13`) computes
  `rolesToCheck = (SqlRole . Text.pack . user $ migsConnString) : extraRolesToCheck`, so the
  connecting user is captured unconditionally; `namespacesToCheck` scopes only schemas.
  ephemeral-pg's `getUsername config = case config.user of "" -> getCurrentUser; u -> pure u`
  and `startCached :: Config -> CacheConfig -> IO (Either StartError Database)` is exported.
  No cleaner codd suppression option was found, so the fixed-user approach stands (Decision Log
  re-affirmed). No experiment against a scratch dir was needed — the source reads were
  conclusive and the production regeneration under the pinned user directly proved the result
  (`grep -R shinzui` empty, `owner: keiro`).
- 2026-07-05: `Pg.defaultConfig{Pg.user = "keiro"}` compiles but emits a GHC
  `-Wambiguous-fields` warning (multiple record types expose a `user` field under
  `DuplicateRecordFields`). It is a warning only (the build links); left as-is to match the
  plan's specified form and avoid churn. If a future `-Werror` build objects, disambiguate with
  an explicit `Pg.Config{...}` record-construction form.


## Decision Log

Record every decision made while working on the plan.

- Decision: Scope codd's `namespacesToCheck` to `IncludeSchemas [SqlSchema "keiro"]` and do
  **not** also include `kiroku`.
  Rationale: The snapshot is Keiro's drift gate for Keiro's own tables. kiroku owns and
  drift-gates its own `kiroku` schema in its own package (`kiroku-store-migrations`), so
  including `kiroku` here would re-couple Keiro's gate to kiroku's internal layout — exactly
  the defect this plan removes. After EP-1 all `keiro_*` tables live in the `keiro` schema,
  so scoping to `keiro` captures precisely Keiro's objects and nothing else.
  Date: 2026-07-05

- Decision: Make the snapshot portable by pinning the ephemeral-pg PostgreSQL user to a
  fixed, machine-independent name (proposed: `keiro`) via `EphemeralPg.Config { user = ... }`,
  rather than by stripping the role/db-settings files or forking codd.
  Rationale: codd always captures the connecting user's role and the database owner (see
  Context and Orientation for the exact source line), and its `StrictCheck` compares the full
  `DbRep` including `db-settings` and `roles`. Stripping those files from disk cannot work
  because the live database side still returns them, so the comparison would mismatch. A
  fixed user makes the captured role name and every `owner` field deterministic on every
  machine, which is the minimal, dependency-free fix. This is confirmed feasible: ephemeral-pg
  passes `Config.user` to `initdb --username=` and includes it in the initdb cache key.
  Date: 2026-07-05

- Decision: Accept a single deterministic `roles/keiro` file (and `owner: keiro` on every
  object) in the regenerated snapshot, treating "remove the leak" as "remove
  machine-specific identifiers", not "produce zero role files".
  Rationale: codd's `readRepresentationsFromDbWithSettings` unconditionally prepends the
  connecting user to the roles it captures and always captures the single `pg_database` row,
  so a *strict on-disk* drift gate necessarily contains one role file and one db-settings
  file. Producing literally zero role files would require either abandoning the on-disk strict
  gate (reverting to kiroku's empty in-memory `DbRep Null Map.empty Map.empty` + no-check,
  which regresses `docs/plans/79-version-keiro-database-schema-and-enforce-migration-checks.md`)
  or patching the pinned upstream codd. A deterministic `keiro` identity satisfies the real
  requirement — portability — without either cost. See Milestone 1 for the confirmation steps;
  this decision is the plan's primary open question and must be re-affirmed there.
  Date: 2026-07-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- 2026-07-05 (completion): Both defects fixed. The codd expected-schema snapshot is now scoped
  to the `keiro` namespace (`schemas/keiro/` holds only the 11 `keiro_*` tables; no kiroku
  tables interleaved), and it is portable: the ephemeral-pg superuser is pinned to `keiro`, so
  `roles/keiro`, `db-settings owner: keiro`, and every per-object owner are deterministic on any
  machine — `grep -R shinzui keiro-migrations/expected-schema` returns nothing. `cabal test
  keiro-migrations-test` passes, including under `USER=notshinzui`, and the negative test proves
  the gate is still meaningful. The fixture suites (`keiro-test`, `keiro-pgmq-test`) are
  unaffected by the `templateCoddSettings` namespace change (they use the no-check runner). The
  `keiro-test-support` fixture was deliberately left on the default OS user (it never
  strict-checks), keeping the change's blast radius minimal. Matches the original purpose
  exactly.
- Handoff to EP-4/EP-5: this plan's Milestone-4 regeneration + Milestone-5 validation procedure
  is the reusable recipe if EP-4 ever adds a shape-changing migration (it does not — EP-4 is
  Haskell-level config with no DB column, per MasterPlan). EP-5 documents the portable drift
  gate and the `keiro` namespace.


## Context and Orientation

This section assumes no prior knowledge of the repository. Every file is named by its full
repository-relative path from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

### The migration and drift-gate machinery

Keiro's SQL migrations live in `keiro-migrations/sql-migrations/`. The module
`keiro-migrations/src/Keiro/Migrations.hs` embeds those files at compile time and exposes
runners built on codd:

```haskell
runAllKeiroMigrations       :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
runAllKeiroMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ()
```

`runAllKeiroMigrations` applies kiroku's event-store migrations followed by Keiro's own
framework migrations, then compares the result to an expected schema according to the
`VerifySchemas` argument. `runAllKeiroMigrationsNoCheck` applies the same migrations but
skips the comparison entirely (it still uses codd's migration ledger and locking).

codd's public types (from the `codd` package, source at
`/Users/shinzui/Keikaku/hub/haskell/codd-project/codd`) that matter here:

```haskell
data VerifySchemas = LaxCheck | StrictCheck
data ApplyResult   = SchemasDiffer SchemasPair | SchemasMatch DbRep | SchemasNotVerified
data CoddSettings  = CoddSettings
  { migsConnString    :: ConnectionString
  , sqlMigrations     :: [FilePath]
  , onDiskReps        :: Either FilePath DbRep   -- Left dir = read snapshot from disk
  , namespacesToCheck :: SchemaSelection
  , extraRolesToCheck :: [SqlRole]
  , retryPolicy       :: RetryPolicy
  , txnIsolationLvl   :: TxnIsolationLvl
  , schemaAlgoOpts    :: SchemaAlgo
  }
data SchemaSelection = IncludeSchemas [SqlSchema] | AllNonInternalSchemas
```

`StrictCheck` throws on a mismatch; `LaxCheck` returns `SchemasDiffer` without throwing.
`onDiskReps = Left "keiro-migrations/expected-schema"` means "read the expected snapshot
from that directory". codd writes and reads the snapshot under a subdirectory named for the
PostgreSQL **major version** — here `v18` — so the on-disk tree root is
`keiro-migrations/expected-schema/v18/`. The local and CI PostgreSQL major version is 18.

### The three call sites that build `CoddSettings`

All three currently set `namespacesToCheck = IncludeSchemas [SqlSchema "kiroku"]`,
`extraRolesToCheck = []`, `onDiskReps = Left "keiro-migrations/expected-schema"`, and
`schemaAlgoOpts = SchemaAlgo False False False`.

1. `keiro-migrations/app/WriteExpectedSchema.hs` — the executable
   `keiro-write-expected-schema`. Its `main` starts a throwaway server with
   `Pg.withCached $ \db -> ...`, builds `settings = coddSettings connStr outputDir`, runs
   `runAllKeiroMigrationsNoCheck settings (secondsToDiffTime 5)`, then calls
   `writeSchema settings (WriteToDisk (Just outputDir))`. `writeSchema` reads the live
   database representation and calls `persistRepsToDisk`, which wipes and rewrites
   `keiro-migrations/expected-schema/v18/`. This exe is how the snapshot is regenerated.

2. `keiro-migrations/test/Main.hs` — the `keiro-migrations-test` suite. It has two relevant
   examples. One ("applies Kiroku and Keiro migrations ... and is repeatable") applies
   migrations with `runAllKeiroMigrationsNoCheck` and asserts table locations via the helpers
   `assertTablesExist`/`assertTablesAbsent`/`assertColumnExists` against the list
   `expectedTables`. **Those table-location helpers and `expectedTables` belong to EP-1, not
   this plan** (see Interfaces and Dependencies for the shared-file coordination). The other
   example ("matches the checked-in expected schema") is **this plan's**: it runs
   `runAllKeiroMigrations coddSettings (secondsToDiffTime 5) StrictCheck` against
   `findExpectedSchemaDir` and expects `SchemasMatch`. Both examples currently obtain their
   server with `Pg.withCached`. The settings are built by `testCoddSettings`, which this plan
   edits.

3. `keiro-test-support/src/Keiro/Test/Postgres.hs` — the shared suite fixture used by
   `keiro-test`, `keiro-pgmq-test`, and others. Its `templateCoddSettings` builds
   `CoddSettings` for the template database and is consumed by `migrateTemplate`, which calls
   `runAllKeiroMigrationsNoCheck`. Because it uses the **no-check** runner it never performs
   a strict comparison, so its `namespacesToCheck` is not load-bearing for correctness — but
   this plan makes it consistent (`keiro`) so the fixture, the exe, and the strict test all
   read the same. This fixture starts its server with
   `Pg.startCached Pg.defaultConfig Pg.defaultCacheConfig` and a `bracket ... Pg.stop`.

### Why the role and owner leak — the exact mechanism

This is the crux of the portability bug. In codd,
`/Users/shinzui/Keikaku/hub/haskell/codd-project/codd/src/Codd/Representations/Database.hs`,
`readRepresentationsFromDbWithSettings` computes which roles to capture as:

```haskell
let rolesToCheck =
      (SqlRole . Text.pack . user $ migsConnString) : extraRolesToCheck
```

That is, codd **always** captures the *connecting user's* role, regardless of
`extraRolesToCheck` (which is `[]` here). The connecting user is whatever ephemeral-pg used
as the PostgreSQL superuser — the local OS username. That is why
`keiro-migrations/expected-schema/v18/roles/shinzui` exists even though `extraRolesToCheck`
is empty. In the same function, codd unconditionally captures the single `pg_database` row
as `db-settings` (its `owner` and `public_privileges` are the OS user), and every object's
JSON representation carries an `owner` field set to the object's owner — again the OS user,
because migrations run as that superuser. You can see all three leak surfaces today:

```json
// keiro-migrations/expected-schema/v18/db-settings
{ "collate": "c", "ctype": "c", "encoding": "utf8",
  "owner": "shinzui", "public_privileges": "[[\"cT\", \"shinzui\"]]", "settings": null }
```

```json
// keiro-migrations/expected-schema/v18/schemas/kiroku/objrep
{ "owner": "shinzui", "privileges": { "shinzui": [ ["CU", "shinzui"] ] } }
```

```json
// keiro-migrations/expected-schema/v18/schemas/kiroku/tables/keiro_timers/objrep (excerpt)
{ "kind": "r", "owner": "shinzui",
  "privileges": { "shinzui": [ ["damxrtDw", "shinzui"] ] }, "...": "..." }
```

Crucially, `namespacesToCheck` only scopes which **schemas** are captured; it has **no
effect** on `db-settings` or `roles`, which are captured globally. So re-scoping to `keiro`
alone does *not* remove the leak — the fix for the leak is separate.

codd's `StrictCheck` comparison is a full structural equality of the on-disk `DbRep` against
the live `DbRep`. In
`/Users/shinzui/Keikaku/hub/haskell/codd-project/codd/src/Codd/Representations.hs`,
`logSchemasComparison` triggers on `dbSchema /= expectedSchemas`, and `toFiles` (in
`Codd/Representations/Disk.hs`) serialises `db-settings`, every `roles/<name>`, and every
`schemas/<schema>/...` file. Therefore the `owner`, `db-settings`, and `roles/` values all
participate in the comparison. This is why you cannot fix portability by deleting the
`roles/shinzui` file from disk: the live database still returns a role, and the comparison
would report `ExpectedButNotFound`/`NotExpectedButFound`. The only way to make `StrictCheck`
pass on every machine is to make the captured identity deterministic.

### How a fixed user makes the identity deterministic

ephemeral-pg (source at
`/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg`) chooses the PostgreSQL
superuser from its `Config`:

```haskell
-- EphemeralPg.hs
getUsername config = case config.user of
  "" -> getCurrentUser   -- getEffectiveUserName: the local OS user, e.g. "shinzui"
  u  -> pure u
```

`Config` has a `user :: Text` field (default `""` in `defaultConfig`). When non-empty, that
name is passed straight to `initdb --username=<user>` (see
`EphemeralPg/Process/InitDb.hs`, `buildInitDbArgs` emitting `"--username=" <> username`) and
becomes the cluster superuser and default owner. The initdb cache key includes `config.user`
(see `EphemeralPg/Internal/Cache.hs`, `getCacheKey` hashing `config.user`), so a pinned user
gets its own cache namespace and does not collide with the default OS-user cache. Setting
`Config { user = "keiro" }` therefore makes the PostgreSQL superuser, the database owner, and
every object owner equal to the literal `keiro` on every machine — which makes codd's captured
`roles/keiro`, `db-settings owner: keiro`, and per-object `owner: keiro` byte-identical across
machines and CI.

One API caveat to embed here so the implementer does not stumble: the convenient wrapper
`withCachedConfig` is **not exported** by `EphemeralPg`. The exported cached entry point that
accepts a `Config` is `startCached :: Config -> CacheConfig -> IO (Either StartError
Database)`. So to use a pinned user with initdb caching, the code must call `Pg.startCached`
and manage teardown with `bracket`/`finally` and `Pg.stop` — exactly the pattern already used
in `keiro-test-support/src/Keiro/Test/Postgres.hs`. The plain `Pg.withCached` used today wires
`defaultConfig` (empty user) and cannot be given a user, so the write exe and the strict test
must switch off it.

### The model to follow: kiroku

kiroku (source at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`) demonstrates the
schema-ownership pattern this initiative adopts, but note one difference relevant here: its
test (`kiroku-store-migrations/test/Main.hs`) does **not** use an on-disk strict gate. It sets
`onDiskReps = Right (DbRep Null Map.empty Map.empty)` (an empty *in-memory* representation)
and runs `runKirokuMigrationsNoCheck`, so it never compares against captured roles or
db-settings and therefore never hits the leak. Keiro deliberately chose the stronger on-disk
`StrictCheck` gate in
`docs/plans/79-version-keiro-database-schema-and-enforce-migration-checks.md`, which is why
Keiro must solve the portability problem head-on rather than side-stepping it. The empty
in-memory `DbRep Null Map.empty Map.empty` is a useful hint about codd's structure — the
`Null` is the db-settings slot, the two empty maps are schemas and roles — confirming those
are explicit, comparable slots.

### Relationship to the other plans in this initiative

This plan is EP-3 of the MasterPlan
`docs/masterplans/12-keiro-schema-separation-and-migration-architecture-rework.md`.

- **Hard dependency on EP-1**
  (`docs/plans/85-rewrite-keiro-migrations-to-own-a-dedicated-keiro-schema-with-qualified-ddl.md`):
  EP-1 creates the `keiro` schema and relocates every `keiro_*` table into it with
  schema-qualified DDL. The snapshot is regenerated *from* the migrated database, so the
  `keiro` schema must exist before this plan can scope to it or regenerate. Do not start the
  regeneration milestone until EP-1 has landed.
- **Soft dependency on EP-2**
  (`docs/plans/86-qualify-all-keiro-framework-runtime-queries-with-the-keiro-schema.md`):
  EP-2 rewrites Keiro's *Haskell runtime queries* to `keiro.<table>`. The expected schema
  reflects the *database shape produced by migrations*, not query strings, so EP-3 does **not**
  need EP-2 for correctness and can run **in parallel** with EP-2 after EP-1. The soft link is
  only convenience: running the full Keiro suite green end-to-end is nicer once EP-2 lands, but
  EP-3 verifies independently via `keiro-migrations-test`.
- **Shared file with EP-1**: both plans edit `keiro-migrations/test/Main.hs`. EP-1 owns the
  table-location assertions (`assertTablesExist`, `assertTablesAbsent`, `assertColumnExists`,
  `expectedTables`); EP-3 owns `testCoddSettings` and the strict-check example (plus the shared
  ephemeral-pg helper this plan introduces). EP-1 lands first, so EP-3 edits EP-1's version.
  Keeping the edits in distinct functions avoids conflicts.
- **Downstream trigger from EP-4**
  (`docs/plans/88-add-first-class-configurable-projection-and-read-model-schema-support.md`):
  if EP-4 adds any migration that changes database shape (for example a new column on
  `keiro_read_models`), the snapshot must be regenerated afterward using this plan's
  procedure. This plan's regeneration procedure (Milestone 4) is reusable for that.


## Plan of Work

The work is five milestones. Milestone 1 is a **prototyping** milestone: it resolves the one
genuine unknown — the exact mechanism codd uses to capture the role/owner, and whether a fixed
ephemeral-pg user truly makes the identity deterministic — by reading codd source and running a
quick experiment before committing to the fix. Milestones 2–3 are the code edits, Milestone 4
regenerates and prunes the snapshot, and Milestone 5 validates portability and the meaningfulness
of the gate.

### Milestone 0 (precondition): confirm EP-1 has landed

Before anything else, confirm the `keiro` schema exists and holds the framework tables. This
plan is meaningless against the pre-EP-1 layout (tables in `kiroku`). Verify by reading
`keiro-migrations/test/Main.hs`: after EP-1 its repeatability example asserts the `keiro_*`
tables are present in schema `keiro` and absent from `kiroku` and `public`. If that assertion
still says `kiroku`, EP-1 has not landed; stop and coordinate. Acceptance: EP-1's migration
DDL under `keiro-migrations/sql-migrations/` issues `CREATE SCHEMA ... keiro` and qualifies
`keiro.<table>`, and `cabal test keiro-migrations-test` builds against that layout (its strict
example may still fail here — that is what this plan fixes).

### Milestone 1 (prototyping): confirm the capture mechanism and the fix

Goal: eliminate the risk that the leak has a cause other than "codd captures the connecting
user", and confirm that pinning the ephemeral-pg user removes the leak, *before* editing the
production call sites.

Work. First, re-read the two codd functions quoted in Context and Orientation to confirm the
claim in this tree's actual pinned codd version:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
sed -n '289,300p' /Users/shinzui/Keikaku/hub/haskell/codd-project/codd/src/Codd/Representations/Database.hs
```

You should see `rolesToCheck = (SqlRole . Text.pack . user $ migsConnString) : extraRolesToCheck`.
That single line is the whole reason the role leaks: the connecting user is always captured.
Confirm the same function captures `db-settings` from the single `pg_database` row and that
`Codd/Representations.hs` compares the full `DbRep` (so `roles` and `db-settings` participate
in `StrictCheck`).

Second, confirm ephemeral-pg honours a fixed user. Read
`/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg/src/EphemeralPg.hs`
(`getUsername`) and `.../src/EphemeralPg/Process/InitDb.hs` (`buildInitDbArgs`) to confirm
`Config.user`, when non-empty, is passed to `initdb --username=`. Confirm `Config(..)`,
`defaultConfig`, and `startCached` are exported by `EphemeralPg` and that `withCachedConfig`
is **not** (so the code must use `startCached` + `bracket`).

Third, run a throwaway experiment to *see* the deterministic identity without touching the
production snapshot. Regenerate into a scratch directory with the current code to capture the
`shinzui` baseline, then repeat conceptually with a pinned user by temporarily editing the exe
in your working tree (do not commit this experiment):

```bash
# Baseline: current behaviour writes owner: <your-os-user> into a scratch tree.
cabal run keiro-write-expected-schema -- /tmp/keiro-schema-baseline
grep -R --line-number '"owner"' /tmp/keiro-schema-baseline/v18/db-settings
```

Expected: the scratch `db-settings` shows `"owner": "<your OS username>"`, proving the leak is
the OS user (not literally `shinzui` on a non-author machine — which is itself the bug).

Result and acceptance. At the end of Milestone 1 you have written, in Surprises & Discoveries,
a short confirmation that (a) codd captures the connecting user's role and the database owner
unconditionally, (b) `namespacesToCheck` does not affect them, (c) `StrictCheck` compares them,
and (d) a fixed ephemeral-pg user makes them deterministic. If any of these turns out false —
for example if the pinned codd version already offers an option to suppress role/db-settings
capture — record it and adapt Milestones 3–4 accordingly. **Promotion criterion:** proceed to
the fixed-user fix only after (a)–(d) are confirmed. **Discard criterion:** if a cleaner codd
option exists in this pinned version, prefer it and revise the Decision Log.

### Milestone 2: re-scope the namespace to `keiro` in all three call sites

Goal: the snapshot and both codd-settings builders target the `keiro` schema.

Work. In each of the three files, change the single field

```haskell
, namespacesToCheck = IncludeSchemas [SqlSchema "kiroku"]
```

to

```haskell
, namespacesToCheck = IncludeSchemas [SqlSchema "keiro"]
```

The files and functions: `keiro-migrations/app/WriteExpectedSchema.hs` (`coddSettings`);
`keiro-migrations/test/Main.hs` (`testCoddSettings`);
`keiro-test-support/src/Keiro/Test/Postgres.hs` (`templateCoddSettings`). In
`Keiro/Test/Postgres.hs` also update the doc-comment above `templateCoddSettings`, which
currently says "Kiroku and Keiro migrations both target the `kiroku` schema"; after EP-1 that
is false — Keiro's tables target `keiro`. Reword it to state that keiro framework tables live
in the `keiro` schema and that `namespacesToCheck` is set to `keiro` for consistency with the
drift gate, while template setup still intentionally skips verification.

Do **not** add `kiroku` to the selection. See the Decision Log: kiroku drift-gates its own
schema in its own package; Keiro must not.

Acceptance: the three files compile (`cabal build keiro-migrations keiro-test-support`). No
snapshot regeneration yet.

### Milestone 3: pin the ephemeral-pg user for portability

Goal: the write executable and the strict test run against a PostgreSQL server whose superuser
is the fixed name `keiro`, so the captured identity is deterministic.

Work. Introduce a shared, fixed configuration and switch the two strict-relevant call sites off
`Pg.withCached` (which cannot carry a user) and onto `Pg.startCached` + teardown.

In `keiro-migrations/app/WriteExpectedSchema.hs`, add near the top-level:

```haskell
import Control.Exception (finally)

keiroPgConfig :: Pg.Config
keiroPgConfig = Pg.defaultConfig { Pg.user = "keiro" }
```

and rewrite `main`'s server acquisition from `Pg.withCached` to `Pg.startCached`:

```haskell
main :: IO ()
main = do
    outputDir <- parseArgs =<< getArgs
    started <- Pg.startCached keiroPgConfig Pg.defaultCacheConfig
    case started of
        Left err -> fail ("Failed to start ephemeral PostgreSQL: " <> show err)
        Right db ->
            ( do
                let connStr = Pg.connectionString db
                    settings = coddSettings connStr outputDir
                runAllKeiroMigrationsNoCheck settings (secondsToDiffTime 5)
                writeSchema settings (WriteToDisk (Just outputDir))
                putStrLn ("Wrote expected schema to " <> outputDir)
            )
                `finally` Pg.stop db
```

In `keiro-migrations/test/Main.hs`, add the same fixed config plus a small helper that
preserves the `Either StartError a` shape the existing `case result of Left ... Right ...`
branches expect, so the strict example changes minimally:

```haskell
import Control.Exception (finally)

keiroPgConfig :: Pg.Config
keiroPgConfig = Pg.defaultConfig { Pg.user = "keiro" }

-- | Start a cached ephemeral server whose PostgreSQL superuser is the fixed
-- name "keiro", so the captured snapshot identity (roles, owners, db-settings)
-- is deterministic across machines and CI. Mirrors 'Pg.withCached' but pins the
-- user; 'Pg.withCachedConfig' is not exported so we use 'Pg.startCached'.
withKeiroPg :: (Pg.Database -> IO a) -> IO (Either Pg.StartError a)
withKeiroPg action = do
    started <- Pg.startCached keiroPgConfig Pg.defaultCacheConfig
    case started of
        Left err -> pure (Left err)
        Right db -> Right <$> (action db `finally` Pg.stop db)
```

Then replace `Pg.withCached` with `withKeiroPg` in **both** examples of
`keiro-migrations/test/Main.hs`. The strict "matches the checked-in expected schema" example
*requires* the pinned user (that is the portability fix). The repeatability example does not
strictly need it, but using the same helper keeps the file consistent and its table-location
assertions are unaffected by the username. (The repeatability example and its helpers are
EP-1's; switching its server-acquisition call is a one-line, behaviour-preserving change — keep
EP-1's assertion logic untouched.)

Leave `keiro-test-support/src/Keiro/Test/Postgres.hs` on its current
`Pg.startCached Pg.defaultConfig Pg.defaultCacheConfig`: that fixture never strict-checks, so it
does not need the pinned user, and changing its superuser would widen this plan's blast radius
across `keiro-test`/`keiro-pgmq-test` for no benefit. (Only its `namespacesToCheck` changed, in
Milestone 2.)

Acceptance: `cabal build keiro-migrations` and `cabal build keiro-migrations-test` succeed.

### Milestone 4: regenerate and prune the snapshot

Goal: the on-disk tree under `keiro-migrations/expected-schema/v18/` contains only `keiro`-schema
`keiro_*` objects with a deterministic `keiro` identity, and the stale `kiroku`-scoped,
`shinzui`-owned content is gone.

Work. Regenerate from a fresh migrated database:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal run keiro-write-expected-schema
```

`writeSchema`/`persistRepsToDisk` wipes and rewrites `keiro-migrations/expected-schema/v18/`
atomically, so the old `schemas/kiroku/` subtree and `roles/shinzui` are replaced, not merged.
If for any reason a stale path lingers (for example because you regenerated into a different
directory during Milestone 1), remove the whole versioned tree and regenerate:

```bash
rm -rf keiro-migrations/expected-schema/v18
cabal run keiro-write-expected-schema
```

Inspect the shape of the change:

```bash
git status --short keiro-migrations/expected-schema
git diff --stat keiro-migrations/expected-schema | tail -5
```

Expected shape: the `schemas/kiroku/` subtree is deleted in its entirety; a new `schemas/keiro/`
subtree appears containing only `keiro_*` tables (`keiro_awakeables`, `keiro_inbox`,
`keiro_outbox`, `keiro_projection_dedup`, `keiro_read_models`, `keiro_snapshots`,
`keiro_subscription_shards`, `keiro_timers`, `keiro_workflow_children`, `keiro_workflow_steps`,
`keiro_workflows`, and any others EP-1 defines) plus their sequences/objrep; `roles/shinzui` is
deleted and `roles/keiro` appears; and `db-settings` changes `owner`/`public_privileges` from
`shinzui` to `keiro`. The kiroku event-store tables (`events`, `streams`, `stream_events`,
`subscriptions`, `dead_letters`) no longer appear anywhere in the tree — they belong to kiroku's
own gate.

Acceptance: `git status` shows exactly the deletions and additions above and nothing under
`schemas/kiroku/`. Confirm no username leak remains:

```bash
grep -R shinzui keiro-migrations/expected-schema ; echo "exit=$?"
```

Expected: no output and `exit=1` (grep found nothing).

### Milestone 5: validate portability and the meaningfulness of the gate

Goal: the strict drift gate passes, passes on a non-`shinzui` identity, and still fails on real
drift.

Work. Run the gate:

```bash
cabal test keiro-migrations-test
```

Expected: all examples pass, including "matches the checked-in expected schema".

Prove portability. The pinned user makes this machine-independent by construction: the captured
identity is the literal `keiro`, never the OS user, on any machine. Demonstrate it two ways.
(1) Grep the regenerated tree for any username-derived identifier and confirm only the intended
`keiro` appears (Milestone 4's `grep -R shinzui` returns nothing; additionally
`grep -R '"owner": "keiro"' keiro-migrations/expected-schema/v18 | head` shows the deterministic
owner). (2) If your development environment lets you, simulate a different identity to prove the
test does not read the OS user: because the server user is pinned in `keiro-migrations/test/Main.hs`
(`keiroPgConfig`), the OS user is irrelevant, but you can still sanity-check by running the suite
under a different login/`USER` and observing it passes:

```bash
USER=notshinzui cabal test keiro-migrations-test
```

Expected: passes (the pinned `keiro` user overrides any OS-user influence on the captured
snapshot). If instead you observe a failure whose diff mentions a username, the pin did not take
effect — re-check that both examples call `withKeiroPg`, not `Pg.withCached`.

Prove the gate is meaningful with a negative test, mirroring the technique recorded in
`docs/plans/79-version-keiro-database-schema-and-enforce-migration-checks.md`. Temporarily
perturb one column in the snapshot, run the strict test, and confirm it fails, then restore:

```bash
# Pick any keiro_* column objrep, e.g. keiro_timers/cols/last_error, and flip notnull.
cp keiro-migrations/expected-schema/v18/schemas/keiro/tables/keiro_timers/cols/last_error /tmp/last_error.bak
# edit the file: change "notnull": false to "notnull": true
cabal test keiro-migrations-test   # expect: the strict example FAILS with a "different-schemas" diff
cp /tmp/last_error.bak keiro-migrations/expected-schema/v18/schemas/keiro/tables/keiro_timers/cols/last_error
cabal test keiro-migrations-test   # expect: passes again
```

Expected failing output shape (from plan 79's recorded run, adapted to the `keiro` schema):

```text
Error: DB and expected schemas do not match. Differing objects and their current DB schemas are: {"schemas/keiro/tables/keiro_timers/cols/last_error":["different-schemas",{...,"notnull":false,...}]}
user error (Exiting. Database's schema differ from expected.)
```

Do **not** commit the intentional break. Finally, run the broader fixture suites to confirm the
namespace change in `templateCoddSettings` did not disturb them (they use the no-check runner, so
they should be unaffected):

```bash
cabal test keiro-test
cabal test keiro-pgmq-test
```

Acceptance: `keiro-migrations-test` passes clean, the negative test fails then passes on restore,
`grep -R shinzui keiro-migrations/expected-schema` is empty, and the fixture suites pass.


## Concrete Steps

Run everything from the repository root unless stated otherwise:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
```

1. Confirm EP-1 has landed (Milestone 0):

```bash
grep -n 'assertTablesExist\|assertTablesAbsent\|"keiro"\|"kiroku"' keiro-migrations/test/Main.hs
```

Expected after EP-1: the assertions reference schema `keiro` (present) and `kiroku`/`public`
(absent). If they still reference `kiroku` as the presence schema, stop — EP-1 is not done.

2. Re-scope the three call sites (Milestone 2). Edit each `namespacesToCheck` from
`IncludeSchemas [SqlSchema "kiroku"]` to `IncludeSchemas [SqlSchema "keiro"]` in
`keiro-migrations/app/WriteExpectedSchema.hs`, `keiro-migrations/test/Main.hs`
(`testCoddSettings`), and `keiro-test-support/src/Keiro/Test/Postgres.hs`
(`templateCoddSettings`); reword the `templateCoddSettings` doc-comment. Build:

```bash
cabal build keiro-migrations keiro-test-support
```

3. Pin the user (Milestone 3). Apply the `keiroPgConfig` + `startCached`/`finally` edits to
`keiro-migrations/app/WriteExpectedSchema.hs` and the `keiroPgConfig` + `withKeiroPg` helper to
`keiro-migrations/test/Main.hs`, replacing `Pg.withCached` with `withKeiroPg` in both examples.
Build:

```bash
cabal build keiro-migrations keiro-migrations-test
```

4. Regenerate and prune (Milestone 4):

```bash
cabal run keiro-write-expected-schema
git status --short keiro-migrations/expected-schema
grep -R shinzui keiro-migrations/expected-schema ; echo "exit=$?"
```

Expected transcript tail:

```text
Wrote expected schema to keiro-migrations/expected-schema
```

and the `grep` prints nothing with `exit=1`.

5. Validate (Milestone 5):

```bash
cabal test keiro-migrations-test
USER=notshinzui cabal test keiro-migrations-test
cabal test keiro-test
cabal test keiro-pgmq-test
```

Then perform the negative test from Milestone 5 and restore the file.

6. Commit. Use Conventional Commits with the required trailers. Suggested message:

```text
fix(migrations): scope codd expected-schema to the keiro namespace and pin the snapshot identity

Re-scope codd namespacesToCheck to the keiro schema in the write exe, the
strict migration test, and the shared fixture, and pin the ephemeral-pg
superuser to a fixed "keiro" so the regenerated snapshot carries no
OS-username-derived role or owner. Regenerate expected-schema/v18 to contain
only keiro_* objects under schemas/keiro with a portable identity.

MasterPlan: docs/masterplans/12-keiro-schema-separation-and-migration-architecture-rework.md
ExecPlan: docs/plans/87-scope-codd-expected-schema-to-the-keiro-namespace-and-remove-the-role-and-owner-leak.md
Intention: intention_01kwsrmsbsedqb0rh0vb41x04m
```

Commit the code edits and the regenerated `keiro-migrations/expected-schema/v18` tree together
so the migrations and their expected result stay in lockstep.


## Validation and Acceptance

The behavioral acceptance criteria, phrased as observable outcomes:

- `cabal test keiro-migrations-test` reports all examples passing, including the strict example
  "matches the checked-in expected schema".
- `USER=notshinzui cabal test keiro-migrations-test` also passes, demonstrating the gate does not
  depend on the OS username (the server user is pinned to `keiro`).
- `grep -R shinzui keiro-migrations/expected-schema` prints nothing (exit status 1): no
  machine-specific username remains anywhere in the snapshot.
- `git status --short keiro-migrations/expected-schema` shows the entire `schemas/kiroku/` subtree
  deleted, a new `schemas/keiro/` subtree with only `keiro_*` objects, `roles/shinzui` deleted,
  `roles/keiro` added, and `db-settings` changed to `owner: keiro`.
- The negative test: perturbing one `keiro_*` column objrep and running
  `cabal test keiro-migrations-test` makes the strict example fail with a `different-schemas`
  diff; restoring the file makes it pass again. This proves the gate is meaningful, not vacuous.
- `cabal test keiro-test` and `cabal test keiro-pgmq-test` pass, confirming the fixture namespace
  change did not disturb the no-check fixture suites.

If the strict test fails immediately after regeneration, first check the PostgreSQL major version
of the generated directory: codd reads `keiro-migrations/expected-schema/<server-major>/`, so a
test server on a major version other than 18 will not find the `v18` files. Align the environment
to PostgreSQL 18 or generate the matching major-version representation.


## Idempotence and Recovery

Regenerating the snapshot is safe to repeat. `cabal run keiro-write-expected-schema` starts a
fresh throwaway database, applies migrations, and has codd atomically wipe and rewrite
`keiro-migrations/expected-schema/v18/`. Running it twice against the same code yields an
identical tree (the pinned `keiro` user makes it deterministic), so re-running to recover from a
partial or confused state is always safe. Always inspect `git diff -- keiro-migrations/expected-schema`
after regeneration: a legitimate change produces a focused diff matching the migrations; a broad
or noisy diff means the generating database was not clean, the namespace selection was wrong, or
the PostgreSQL major version differs.

The code edits are low-risk and reversible. The namespace field is a one-token change per file.
The user pin is additive (`keiroPgConfig`/`withKeiroPg`) and switches server acquisition to the
already-proven `startCached` + `finally` pattern; reverting is a matter of restoring
`Pg.withCached`. The fixture in `keiro-test-support` is left on its default user by design, so it
cannot regress other suites.

If a regeneration partially writes files and then fails, remove only this plan's tree
(`rm -rf keiro-migrations/expected-schema/v18`) and regenerate from a fresh database. Do not run
destructive commands against the repository root or unrelated files. The negative-test edit must
always be restored (keep a `/tmp` backup as shown) and must never be committed.


## Interfaces and Dependencies

Libraries and modules used, and why:

- `Keiro.Migrations` (`keiro-migrations/src/Keiro/Migrations.hs`): `runAllKeiroMigrationsNoCheck`
  for the write exe and the repeatability example; `runAllKeiroMigrations ... StrictCheck` for the
  strict drift gate. Signatures:

  ```haskell
  runAllKeiroMigrations       :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
  runAllKeiroMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ()
  ```

- codd (`codd` package): `CoddSettings`, `VerifySchemas (StrictCheck)`,
  `Codd.AppCommands.WriteSchema.writeSchema` with `WriteSchemaOpts (WriteToDisk)`, and the types
  `SchemaSelection (IncludeSchemas)`, `SqlSchema`, `SchemaAlgo`, `TxnIsolationLvl`,
  `singleTryPolicy` from `Codd.Types`. This plan changes only the `namespacesToCheck` field value
  (`kiroku` → `keiro`) in the three `CoddSettings` builders; it does not change `extraRolesToCheck`
  (which stays `[]` — it does not help, per Context and Orientation) or `schemaAlgoOpts`.

- ephemeral-pg (`EphemeralPg`, imported qualified as `Pg`): `Pg.Config(..)`, `Pg.defaultConfig`,
  `Pg.defaultCacheConfig`, `Pg.startCached`, `Pg.stop`, `Pg.connectionString`. The fixed identity
  is expressed as:

  ```haskell
  keiroPgConfig :: Pg.Config
  keiroPgConfig = Pg.defaultConfig { Pg.user = "keiro" }
  ```

  and consumed via `Pg.startCached keiroPgConfig Pg.defaultCacheConfig`. Note again that
  `withCachedConfig` is not exported, so `startCached` + `bracket`/`finally` is the required
  pattern. `Control.Exception.finally` is used for teardown.

Function signatures that must exist at the end of the milestones:

- End of Milestone 2: the three builders `coddSettings`, `testCoddSettings`,
  `templateCoddSettings` continue to have their existing types and now set
  `namespacesToCheck = IncludeSchemas [SqlSchema "keiro"]`.
- End of Milestone 3: `keiroPgConfig :: Pg.Config` exists in both
  `keiro-migrations/app/WriteExpectedSchema.hs` and `keiro-migrations/test/Main.hs`, and
  `withKeiroPg :: (Pg.Database -> IO a) -> IO (Either Pg.StartError a)` exists in the test.
- End of Milestone 4: the on-disk artifact `keiro-migrations/expected-schema/v18/schemas/keiro/`
  exists and holds only `keiro_*` objects; `roles/keiro` and `db-settings` (owner `keiro`) exist;
  no `schemas/kiroku/` and no `roles/shinzui`.

Shared-file coordination. `keiro-migrations/test/Main.hs` is edited by both EP-1 and this plan.
EP-1 owns `assertTablesExist`, `assertTablesAbsent`, `assertColumnExists`, and `expectedTables`;
this plan owns `testCoddSettings`, the strict-check example, and the new `keiroPgConfig` /
`withKeiroPg` helper. EP-1 lands first (this plan hard-depends on it), so build on EP-1's version
and keep edits in distinct functions to avoid conflicts; the only overlap is switching the
repeatability example's server acquisition from `Pg.withCached` to `withKeiroPg`, which is a
behaviour-preserving one-line change that leaves EP-1's assertions untouched.

Downstream trigger. If EP-4 adds a migration that changes database shape (for example a column on
`keiro_read_models`), the snapshot must be regenerated with this plan's Milestone 4 procedure and
re-validated with Milestone 5. This plan's regeneration and validation steps are reusable for that
purpose; EP-4 must flag any such migration so this gate is re-run.
