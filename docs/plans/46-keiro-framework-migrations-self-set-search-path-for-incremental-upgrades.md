---
id: 46
slug: keiro-framework-migrations-self-set-search-path-for-incremental-upgrades
title: "Keiro framework migrations self-set search_path for incremental upgrades"
intention: "intention_01kt7npxrzew99s8gxcfqbwa6x"
kind: exec-plan
created_at: 2026-06-03T21:22:04Z
---

# Keiro framework migrations self-set search_path for incremental upgrades

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Keiro stores all of its framework tables in a dedicated PostgreSQL schema named
`kiroku` (not the default `public` schema). The runtime always connects with the
session setting `search_path = kiroku`, so it looks for its tables there. The
database migrations that *create* those tables are plain SQL files that issue
**unqualified** `CREATE TABLE` statements (for example `CREATE TABLE
keiro_workflow_steps (...)`, with no `kiroku.` prefix). An unqualified `CREATE
TABLE` lands in whatever schema the *session* `search_path` points at when the
statement runs.

Today, only the very first migration — kiroku's bootstrap — sets the session
`search_path` to `kiroku`. Every later Keiro migration relies on that setting
still being in effect, which is true **only when all pending migrations are
applied together in one migration run** (a fresh database). When a migration is
applied to an *existing* database where the kiroku bootstrap already ran in an
earlier run, the bootstrap's `SET search_path` is not re-executed, so the new
migration runs with the default `search_path` (`public`) and creates its tables in
the **wrong schema**. The runtime, looking in `kiroku`, then fails with
`relation "keiro_workflow_steps" does not exist`.

This was hit for real while shipping the v2 durable-execution worked example
(MasterPlan 5 / ExecPlan `docs/plans/45-durable-workflow-worked-example-and-guide.md`,
Surprises entry dated 2026-06-03): the three v2 workflow migrations, applied
incrementally to an already-bootstrapped `jitsurei` database, landed in `public`
and the demo could not find them until the tables were moved by hand with
`ALTER TABLE ... SET SCHEMA kiroku`.

**What someone gains after this change:** applying the Keiro framework migrations
to an existing v1 database — at any later time, in a run that contains only the
new migrations — creates every Keiro table in the `kiroku` schema, so the runtime
finds them with no manual remediation. This restores the "a v1 deployment upgrades
to v2 in place" guarantee that `docs/research/10-workflow-roadmap.md` §7 makes.

**How you can see it working:** a new automated test applies a Keiro framework
migration in a database session whose `search_path` is the default (`public`, *not*
`kiroku`) and asserts the created table lands in `kiroku` anyway. Before this
change the table lands in `public` (test fails); after it, the table lands in
`kiroku` (test passes). The existing fresh-database migration test continues to
pass, and is extended to also assert the three v2 workflow tables land in `kiroku`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: prepend `SET search_path TO kiroku, pg_catalog;` (with an
  explanatory comment) as the first executable statement of every Keiro framework
  migration in `keiro-migrations/sql-migrations/`.
- [ ] Milestone 1: confirm a fresh full-batch apply still works — `cabal test
  keiro-migrations-test` green.
- [ ] Milestone 2: extend `keiro-migrations/test/Main.hs` so `expectedTables`
  includes the three v2 workflow tables (covered by the existing fresh-apply
  assertions), and add a new test that applies a v2 migration's SQL in a
  `search_path = public` session and asserts the table lands in `kiroku`.
- [ ] Milestone 2: confirm the new test fails before the Milestone 1 edits and
  passes after (the regression proof).
- [ ] Milestone 3: full repo green — `cabal build all`, `cabal test
  keiro-migrations-test`, `cabal test keiro` — and a remediation note for any
  database that already mis-applied the v2 migrations into `public`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Fix the migrations by making each Keiro framework migration self-set
  `search_path TO kiroku, pg_catalog;` as its first statement, rather than (a)
  relying on the kiroku bootstrap's session setting, (b) schema-qualifying every
  object name (`kiroku.keiro_...`), or (c) setting a database-level default
  `search_path`.
  Rationale: Self-setting per migration is the same pattern the kiroku bootstrap
  already uses and documents (`CREATE SCHEMA IF NOT EXISTS kiroku; SET search_path
  TO kiroku, pg_catalog;`), so it is idiomatic and self-evidently correct in every
  apply order. Per-object qualification is noisier, easy to forget on a future
  migration, and does not help statements that reference unqualified names (for
  example a later `ALTER TABLE keiro_timers`). A database-level default
  (`ALTER DATABASE ... SET search_path`) would change behavior for application
  objects the deployer expects in `public` and is outside a migration's remit.
  Date: 2026-06-03.

- Decision: Edit the already-shipped migration files in place rather than adding a
  new "fix" migration.
  Rationale: codd (the migration tool, used via `Keiro.Migrations.runAllKeiroMigrations`)
  records which migrations have been applied by their timestamped filename and only
  applies *pending* (not-yet-recorded) ones; it does not re-run or re-checksum an
  already-applied file during the apply phase, and these migrations are verified
  with `LaxCheck` (no checked-in expected-schema representation to drift). So
  prepending a `SET search_path` line to an already-applied file is a no-op on
  databases that already ran it (it is not re-applied) and is correct on databases
  that have not (it applies with the line present). A separate "fix" migration could
  only *move* already-mis-placed tables and would run forever on the majority of
  databases that never mis-placed them; the in-place edit is both simpler and the
  permanent fix for all future applies. (The implementer must still verify codd's
  no-re-apply behavior — see Concrete Steps.)
  Date: 2026-06-03.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Read this fully before editing; it assumes no prior knowledge of the repository.

**The repository.** Keiro is a Haskell event-sourcing framework. Migrations live in
the `keiro-migrations` Cabal package. The SQL migration files are in
`keiro-migrations/sql-migrations/` and are embedded into the binary at compile time
by Template Haskell (`embedDir "sql-migrations"` in
`keiro-migrations/src/Keiro/Migrations.hs`). The migration tool is **codd** (a
Haskell library); `Keiro.Migrations.runAllKeiroMigrations` runs Kiroku's migrations
followed by Keiro's, in timestamp order. All Cabal commands in this plan run from
the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

**Schemas.** A PostgreSQL *schema* is a namespace for tables. Keiro keeps all of its
tables in a schema named `kiroku`, leaving `public` for application objects. The
runtime's database connection is configured (by `Store.defaultConnectionSettings` in
the kiroku-store package) with the session parameter `search_path = kiroku`, so
unqualified table references resolve to `kiroku`. The `search_path` is a
*session-scoped* setting: a `SET search_path TO ...` affects only the current
database connection/session and is forgotten when that session ends.

**Where the `kiroku` schema and search_path come from.** The first migration of all
is kiroku's bootstrap,
`kiroku-project/kiroku/kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql`.
Its first two statements are:

```sql
CREATE SCHEMA IF NOT EXISTS kiroku;
SET search_path TO kiroku, pg_catalog;
```

with a comment explaining: "Creating the schema and setting search_path first means
every unqualified object name in the rest of this file resolves into the Kiroku
schema." codd applies a run's pending migrations within one connection/session (by
default inside one transaction), so when *all* migrations are pending (a fresh
database) the bootstrap's `SET search_path` is in effect for every later migration
in the same run, and they all land in `kiroku`.

**The Keiro framework migrations** (the files this plan edits), in
`keiro-migrations/sql-migrations/`, are:

```text
2026-05-17-00-00-00-keiro-bootstrap.sql        -- keiro_snapshots, keiro_read_models, keiro_timers
2026-05-17-01-00-00-keiro-outbox.sql           -- keiro_outbox
2026-05-17-02-00-00-keiro-inbox.sql            -- keiro_inbox
2026-05-17-03-00-00-keiro-timer-recovery.sql   -- ALTER keiro_timers (add columns)
2026-06-03-00-00-00-keiro-workflow-steps.sql   -- keiro_workflow_steps
2026-06-03-01-00-00-keiro-awakeables.sql       -- keiro_awakeables
2026-06-03-02-00-00-keiro-workflow-children.sql -- keiro_workflow_children
```

Each of these issues unqualified DDL (for example `CREATE TABLE IF NOT EXISTS
keiro_workflow_steps (...)`) and **none of them sets `search_path`**. Confirm with:

```bash
grep -rL "search_path" keiro-migrations/sql-migrations/*.sql
```

(every file is listed, i.e. none contains `search_path`).

**The bug, precisely.** On a fresh database, all seven Keiro files plus the kiroku
files are pending and applied in one run; the bootstrap's `SET search_path TO
kiroku` governs the whole run, so every Keiro table lands in `kiroku`. On an
*existing* database where the kiroku and v1 Keiro migrations already ran in an
earlier codd run, a later run that contains only the three v2 workflow migrations
(`2026-06-03-*`) starts a fresh session whose `search_path` is the database default
(`public`); the bootstrap does not re-run; so `CREATE TABLE keiro_workflow_steps`
lands in `public`. The runtime then connects with `search_path = kiroku`, does not
find the table there, and fails. The same latent defect affects
`2026-05-17-03-00-00-keiro-timer-recovery.sql` (an `ALTER TABLE keiro_timers` that,
in a `public` session, would alter `public.keiro_timers` if one existed) — which is
why the fix is applied uniformly to all seven files, not just the v2 three.

**The existing test** is `keiro-migrations/test/Main.hs` (`cabal test
keiro-migrations-test`). It starts an ephemeral PostgreSQL with `ephemeral-pg`,
runs `runAllKeiroMigrations` against a *fresh* database, and asserts the expected
tables are present in `kiroku` and absent from `public`. It does **not** catch this
bug for two reasons: (1) it always applies the full batch to a fresh database (so
the bootstrap's `SET` is always in effect), and (2) its `expectedTables` list does
not even include the three v2 workflow tables. This plan fixes both: it adds the v2
tables to the fresh-apply assertions and adds a new test that reproduces the
incremental (`search_path = public`) condition directly.


## Plan of Work

### Milestone 1: make every Keiro migration self-set search_path

Edit each of the seven files in `keiro-migrations/sql-migrations/`. As the **first
executable statement** of each file (after the leading comment block, before the
first `CREATE`/`ALTER`), insert:

```sql
-- Resolve every unqualified object below into the Kiroku schema, regardless of
-- whether this migration is applied in the same run as the kiroku bootstrap (a
-- fresh database) or on its own against an already-bootstrapped database (an
-- incremental upgrade). search_path is session-scoped, so each migration must set
-- it for itself rather than rely on the bootstrap's setting still being in effect.
SET search_path TO kiroku, pg_catalog;
```

`SET search_path` is idempotent and harmless: on a fresh-batch apply it merely
re-asserts what the bootstrap already set; on an incremental apply it is the line
that makes the migration correct. The `kiroku` schema is guaranteed to exist by the
time any Keiro migration runs (the kiroku bootstrap created it and runs strictly
earlier), so no `CREATE SCHEMA` is needed here.

At the end of this milestone the fresh-database test still passes — confirm with
`cabal test keiro-migrations-test`. Nothing observable changes yet for the
incremental case (no test exercises it until Milestone 2).

### Milestone 2: a regression test for the incremental condition

This milestone proves the fix. Edit `keiro-migrations/test/Main.hs`:

1. **Cover the v2 tables in the fresh-apply assertions.** Add
   `"keiro_workflow_steps"`, `"keiro_awakeables"`, and `"keiro_workflow_children"`
   to the `expectedTables` list (lines ~49–60). The existing
   `assertTablesExist connStr "kiroku" expectedTables` and `assertTablesAbsent
   connStr "public" expectedTables` calls then also guard the v2 tables. (On a
   fresh batch these pass before *and* after Milestone 1; the point is to stop the
   v2 tables being silently unverified.)

2. **Add the incremental-condition test.** Add a second `it "..."` to the
   `describe "Keiro codd migrations"` block that proves a v2 migration self-qualifies
   even when the session `search_path` is `public`. The mechanism that reproduces the
   bug without standing up a second codd run is to execute the migration's own SQL in
   a session whose `search_path` is `public`:

   - Start an ephemeral database and run `runAllKeiroMigrations` once (so the
     `kiroku` schema and the v2 tables exist in `kiroku`).
   - Open a pool/connection and, in one `Hasql.Session.sql` script, run:
     `DROP TABLE IF EXISTS kiroku.keiro_workflow_steps, public.keiro_workflow_steps;`
     then `SET search_path TO public;` then the **verbatim body** of
     `2026-06-03-00-00-00-keiro-workflow-steps.sql` (read from disk at the
     repository-relative path, or embedded — see below), then a probe:
     `SELECT to_regclass('kiroku.keiro_workflow_steps') IS NOT NULL AND
     to_regclass('public.keiro_workflow_steps') IS NULL;`.
   - Assert the probe returns `True`. Before Milestone 1 the migration body has no
     `SET search_path`, so in a `public` session the table lands in `public` and the
     probe is `False` (test fails). After Milestone 1 the body sets `search_path TO
     kiroku` itself, so the table lands in `kiroku` and the probe is `True`.

   Read the migration body in the test by reading the file at
   `keiro-migrations/sql-migrations/2026-06-03-00-00-00-keiro-workflow-steps.sql`
   (the test process runs from the repository root, so this relative path resolves;
   add `directory`/`base` `readFile` — `Data.Text.IO.readFile` — to the test
   build-deps if not present). Keep the probe table (`keiro_workflow_steps`) and the
   migration file in sync.

At the end of this milestone, running the test against the tree *before* Milestone 1
fails on the new assertion and *after* Milestone 1 passes. Demonstrate both (stash
the Milestone 1 edits, run, restore — see Concrete Steps).

### Milestone 3: full green and the remediation note

Run `cabal build all`, `cabal test keiro-migrations-test`, and `cabal test keiro`.
All must pass. Then record, in this plan's Outcomes and in
`docs/user/operations.md` (the migrations/database section), a one-paragraph
remediation for any database that *already* mis-applied the v2 migrations into
`public` before this fix: move the tables with

```sql
ALTER TABLE public.keiro_workflow_steps    SET SCHEMA kiroku;
ALTER TABLE public.keiro_awakeables        SET SCHEMA kiroku;
ALTER TABLE public.keiro_workflow_children SET SCHEMA kiroku;
```

(only for tables that exist in `public`), noting that fresh databases and databases
upgraded after this fix never need it.


## Concrete Steps

Run all commands from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

**Step 0 — confirm the starting state (no migration sets search_path):**

```bash
grep -rL "search_path" keiro-migrations/sql-migrations/*.sql
```

Expected: all seven files are listed.

**Step 1 — edit the seven migration files (Milestone 1), then:**

```bash
cabal test keiro-migrations-test
```

Expected: the existing fresh-apply test still passes.

**Step 2 — edit the test (Milestone 2) and prove the regression both ways:**

```bash
# With Milestone 1 applied, the new test passes:
cabal test keiro-migrations-test

# Prove it would have failed before the fix: temporarily revert the migration edits
# (keep the test), run, then restore.
git stash push -- keiro-migrations/sql-migrations
cabal test keiro-migrations-test   # expect: the new incremental test FAILS
git stash pop
cabal test keiro-migrations-test   # expect: all green again
```

Record the failing-then-passing transcript in Surprises & Discoveries as evidence.

**Step 3 — verify codd does not re-apply edited files (the Decision Log assumption):**
on a database that has already applied the migrations once, run them again and
confirm it is a no-op (no error, no duplicate apply):

```bash
just postgres-start
just jitsurei-migrate     # if jitsurei db already migrated, this re-runs codd; expect "no pending migrations" or a clean no-op
```

Expected: codd reports nothing pending (the already-applied, now-edited files are
not re-run). If codd instead errors on a checksum mismatch, record that in Surprises
and switch to the alternative in the Decision Log (a new forward migration); the
in-place edit is the primary path precisely because codd keys on filename, not
content.

**Step 4 — full green (Milestone 3):**

```bash
cabal build all
cabal test keiro-migrations-test
cabal test keiro
```


## Validation and Acceptance

Acceptance is observable behavior:

**Check 1 — incremental apply lands in `kiroku`.** The new test in
`keiro-migrations/test/Main.hs` runs a v2 migration's SQL in a `search_path =
public` session and asserts `to_regclass('kiroku.keiro_workflow_steps') IS NOT NULL
AND to_regclass('public.keiro_workflow_steps') IS NULL` returns `True`. This fails
on the pre-fix tree and passes on the fixed tree (demonstrated in Concrete Steps,
Step 2).

**Check 2 — fresh apply still correct, now covering v2 tables.** `cabal test
keiro-migrations-test` passes with `keiro_workflow_steps`, `keiro_awakeables`, and
`keiro_workflow_children` added to `expectedTables`: present in `kiroku`, absent
from `public`.

**Check 3 — every Keiro migration self-sets search_path.**

```bash
grep -rL "search_path" keiro-migrations/sql-migrations/*.sql
```

Expected: no output (every file now contains `SET search_path`).

**Check 4 — whole repository green.** `cabal build all`, `cabal test
keiro-migrations-test`, and `cabal test keiro` all pass.


## Idempotence and Recovery

Every step is safe to repeat. `SET search_path` is idempotent. Editing the migration
files does not retrigger an apply on databases that already ran them (codd keys on
filename); re-running `runAllKeiroMigrations` against any database is a no-op once
all files are recorded as applied. The test starts a throwaway ephemeral database
each run. If the codd-no-re-apply assumption proves false (Step 3 errors), fall back
to the Decision Log's alternative — leave the v1 files untouched and add a new
forward migration that issues `SET search_path` then `ALTER TABLE ... SET SCHEMA
kiroku` guarded by `IF EXISTS` — and record the change in the Decision Log and a
revision note. The Milestone 3 remediation SQL is itself idempotent when guarded by
existence checks.


## Interfaces and Dependencies

This plan adds **no** new library code and **no** new migration file (the primary
path edits existing files in place). It touches:

- `keiro-migrations/sql-migrations/*.sql` — prepend `SET search_path TO kiroku,
  pg_catalog;` to all seven Keiro framework migrations.
- `keiro-migrations/test/Main.hs` — extend `expectedTables`; add the
  incremental-condition test. Uses the already-present test dependencies
  (`Codd`, `ephemeral-pg`, `hasql`, `hasql-pool`, `hspec`); add `text`'s
  `Data.Text.IO.readFile` if reading the migration body from disk (the `text`
  package is already a transitive dep; add it explicitly to the test stanza if the
  build complains).
- `docs/user/operations.md` — the one-paragraph remediation note (Milestone 3).

The relevant existing entry point is `Keiro.Migrations.runAllKeiroMigrations ::
CoddSettings -> DiffTime -> VerifySchemas -> IO ...` (`keiro-migrations/src/Keiro/Migrations.hs`),
unchanged by this plan. No runtime Haskell signatures change.

**Git trailers.** Every commit must carry, after a blank line:

```text
ExecPlan: docs/plans/46-keiro-framework-migrations-self-set-search-path-for-incremental-upgrades.md
Intention: intention_01kt7npxrzew99s8gxcfqbwa6x
```
