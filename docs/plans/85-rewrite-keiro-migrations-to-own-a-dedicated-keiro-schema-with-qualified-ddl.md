---
id: 85
slug: rewrite-keiro-migrations-to-own-a-dedicated-keiro-schema-with-qualified-ddl
title: "Rewrite keiro migrations to own a dedicated keiro schema with qualified DDL"
kind: exec-plan
created_at: 2026-07-05T18:39:12Z
intention: "intention_01kwsrmsbsedqb0rh0vb41x04m"
master_plan: "docs/masterplans/12-keiro-schema-separation-and-migration-architecture-rework.md"
---

# Rewrite keiro migrations to own a dedicated keiro schema with qualified DDL

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Keiro is a Haskell event-sourcing framework and durable-workflow engine. It stores its own
framework state — snapshots, read-model bookkeeping, timers, an outbox and inbox, workflow
journals and indexes, awakeables, subscription-shard leases, and a projection dedup table —
in PostgreSQL tables named `keiro_*`. Keiro sits on top of a separate event-store library
called **kiroku** (the dependency `shinzui/kiroku`). A PostgreSQL **schema** is a namespace
inside one database; a table can be addressed either bare (`keiro_timers`, resolved against
the connection's `search_path` list of schemas) or schema-qualified (`keiro.keiro_timers`,
resolved unambiguously). kiroku owns and creates a dedicated schema named `kiroku` for its
event-store tables (`streams`, `events`, `stream_events`, `subscriptions`, `dead_letters`)
and derives its `LISTEN`/`NOTIFY` channel name from that schema.

Today Keiro is a **squatter** inside kiroku's schema. Every file under
`keiro-migrations/sql-migrations/` opens with `SET search_path TO kiroku, pg_catalog;` (a
session-scoped instruction that makes bare names resolve into the `kiroku` schema) and then
issues **unqualified** `CREATE TABLE keiro_*`, so all of Keiro's framework tables are
created **inside kiroku's private `kiroku` schema**. Keiro's bootstrap migration never runs
`CREATE SCHEMA`; it owns no namespace of its own. This forces a noisy four-line explanatory
comment atop every migration and was already the source of a production incident (tables
landing in `public` on incremental upgrades).

After this plan, Keiro **owns a dedicated PostgreSQL schema named `keiro`**. The bootstrap
migration issues `CREATE SCHEMA IF NOT EXISTS keiro;` and every migration creates or alters
its tables **schema-qualified** as `keiro.<table>` with **no** `SET search_path` pin and no
noisy comment. The `keiro-migrate new` scaffolder generates that qualified, comment-free
template. A one-time, idempotent remediation script relocates the tables of an already-shipped
alpha database (`keiro-migrations 0.1.0.0`, released 2026-07-05 with tables in `kiroku`) into
the `keiro` schema without data loss.

You can see it working: after this plan, running `cabal test keiro-migrations-test` from the
repository root migrates a fresh ephemeral PostgreSQL database and observes that every
`keiro_*` table exists in the `keiro` schema and is **absent** from both `kiroku` and
`public`, while kiroku's own event-store tables remain in `kiroku`. Applying the remediation
script to a database seeded with the old 0.1.0.0 layout moves the `keiro_*` tables from
`kiroku` into `keiro` and leaves a subsequent `keiro-migrate` a no-op.

This is **EP-1**, the foundation plan of MasterPlan 12
(`docs/masterplans/12-keiro-schema-separation-and-migration-architecture-rework.md`). Four
sibling plans build on it: EP-2 (`docs/plans/86-...`) qualifies the runtime query strings in
the `keiro` package against the same schema name; EP-3 (`docs/plans/87-...`) rescopes codd's
drift-gate to the `keiro` namespace and removes a role/owner portability leak; EP-4
(`docs/plans/88-...`) adds configurable projection schemas; EP-5 (`docs/plans/89-...`) writes
the user-facing docs and upgrade runbook. This plan is the **single source of truth for the
schema name `keiro`** (see Interfaces and Dependencies).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-07-05): `Keiro.Schema` module added to `keiro-core` exporting `keiroSchema :: Text = "keiro"`.
- [x] M1 (2026-07-05): Bootstrap migration `2026-05-17-13-58-15-keiro-bootstrap.sql` rewritten to
  `CREATE SCHEMA IF NOT EXISTS keiro;` + qualified `keiro.<table>` DDL, no `SET search_path`.
  `cabal build keiro-core keiro-migrations` green.
- [x] M2 (2026-07-05): The remaining 15 migration files rewritten with fully-qualified `keiro.<table>`
  DDL (tables, indexes, alters, and the workflows-instances data-backfill), each stripped of
  its `SET search_path` line and its search_path explanatory comment. `keiro-migrations`
  compiles; `grep -rn 'search_path' keiro-migrations/sql-migrations/` returns nothing; one
  `CREATE SCHEMA` (bootstrap, `keiro`).
- [x] M2 (2026-07-05): Embed-comment in `keiro-migrations/src/Keiro/Migrations.hs` touched to force a
  Template Haskell recompile of the rewritten bodies.
- [x] M3 (2026-07-05): `keiro-migrate new` template in `keiro-migrations/src/Keiro/Migrations/New.hs`
  emits a qualified, comment-free `keiro.` example; Haddock updated. Smoke test: generated file
  shows `keiro.keiro_example` and no `SET search_path`.
- [ ] M4: `keiro-migrations/test/Main.hs` table-location assertions flipped to expect
  `keiro_*` in `keiro` and absent from `kiroku` + `public`; kiroku event tables still in
  `kiroku`.
- [ ] M4: Expected-schema snapshot regenerated (`cabal run keiro-write-expected-schema`) so
  the strict drift-gate test stays green under the still-`kiroku` scope; suite green.
- [ ] M5: Remediation script `keiro-migrations/remediation/2026-07-05-relocate-keiro-tables-to-keiro-schema.sql`
  written (create schema + guarded `ALTER TABLE ... SET SCHEMA` per table).
- [ ] M5: Remediation verified against a simulated 0.1.0.0 database (tables relocated, second
  run a no-op, `keiro-migrate` reports nothing to apply).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-05 (authoring): The `keiro_*` framework tables use **no** `SERIAL`/`BIGSERIAL`
  columns and **no** `REFERENCES` (cross-schema or otherwise). Evidence:
  `grep -niE 'serial|references' keiro-migrations/sql-migrations/*.sql` returns nothing.
  Consequence: `ALTER TABLE ... SET SCHEMA` in the remediation script has no dependent
  sequence to orphan and no foreign key to break — a clean move.
- 2026-07-05 (M2 implementation): the bootstrap header comment given verbatim in the M1 spec
  contained the literal token `search_path` ("no session search_path pin is used anywhere"),
  which tripped the M2/Validation acceptance `grep -rn 'search_path' keiro-migrations/sql-migrations/`
  returns nothing. Resolved by rewording that one comment to the hyphenated "search-path" so the
  grep gate catches only genuine `SET search_path` pins, preserving the acceptance's intent. No
  functional change.
- 2026-07-05 (authoring): codd identifies an already-applied migration purely by its
  **filename** (`SELECT ... FROM codd_schema.sql_migrations WHERE name = ?`), with no body
  checksum. Evidence: the header of the sibling artifact
  `keiro-migrations/ledger-fixups/2026-07-05-realign-keiro-migration-timestamps.sql` states
  this explicitly, and that fixup was needed only because it *renamed* files. Consequence:
  because EP-1 **keeps every migration filename** and only rewrites file bodies, an alpha
  database that already applied those filenames will not re-run anything and needs no ledger
  rename — the remediation script only creates the schema and moves the tables.


## Decision Log

Record every decision made while working on the plan.

- Decision: Relocate Keiro's framework tables into a dedicated `keiro` schema via a **clean
  rewrite** of the shipped migration bodies — keeping every existing filename/timestamp and
  rewriting only the SQL inside — rather than layering additive `ALTER TABLE ... SET SCHEMA`
  forward migrations onto the shipped history.
  Rationale: Inherited from MasterPlan 12's scoping decision (the release is a pre-1.0 alpha
  shipped the same day with an explicit "API unstable" warning). Keeping filenames preserves
  codd's forward-only, filename-keyed ledger semantics for fresh installs (codd re-runs
  nothing that is already applied by name) while yielding the cleanest long-term history: a
  brand-new database gets the `keiro` layout directly from the rewritten bodies.
  Date: 2026-07-05

- Decision: The schema name is the literal string `keiro`, and its Haskell source of truth is
  a new constant `keiroSchema :: Text = "keiro"` exported from a new module `Keiro.Schema` in
  the `keiro-core` package (`keiro-core/src/Keiro/Schema.hs`).
  Rationale: MasterPlan 12's Integration Points assign EP-1 the responsibility of defining the
  schema-name constant if any plan needs one. EP-2 and EP-4 (both in the `keiro` runtime
  package, which already depends on `keiro-core`) will import it instead of re-typing the
  string. `keiro-core` is the lowest shared package, so the constant is importable everywhere
  the runtime needs it without introducing a new dependency edge. The `keiro-migrations`
  package deliberately does **not** import it — its SQL is raw embedded text and its codd
  `CoddSettings` use the bare literal `"keiro"` (adding a `keiro-core` dependency to the
  migrations package solely for a string is unwarranted).
  Date: 2026-07-05

- Decision: The remediation script does **not** rename any row in codd's ledger; it performs
  only `CREATE SCHEMA IF NOT EXISTS keiro;` and a guarded `ALTER TABLE ... SET SCHEMA keiro`
  per `keiro_*` table, and ends with a verification query asserting the ledger is already
  consistent.
  Rationale: Because the clean rewrite keeps every migration filename unchanged (see above),
  codd already records those filenames as applied on a 0.1.0.0 database and re-runs nothing.
  The MasterPlan's phrase "realign codd's ledger" is therefore satisfied trivially: there is
  nothing to realign for a schema move that leaves filenames intact. This is the material
  difference from the existing `ledger-fixups/2026-07-05-realign-keiro-migration-timestamps.sql`,
  which *did* rename files and therefore *did* need row renames.
  Date: 2026-07-05

- Decision: EP-1 regenerates the checked-in expected-schema snapshot under `keiro-migrations/expected-schema/`
  (via `cabal run keiro-write-expected-schema`) as part of milestone M4, but does **not**
  change codd's `namespacesToCheck` (that, and the role/owner-leak fix, belong to EP-3).
  Rationale: Moving the `keiro_*` tables out of the `kiroku` schema changes the shape of the
  `kiroku` namespace that the strict drift-gate test compares against. Since EP-1 leaves the
  drift gate scoped to `kiroku`, the regenerated snapshot simply loses the `keiro_*` table
  representations from the `kiroku/tables/` tree, and the strict test stays green. EP-3 then
  rescopes to `keiro` and re-captures those tables under a `keiro/` tree. Regenerating the
  snapshot data is distinct from editing `testCoddSettings`; EP-1 does the former to keep its
  own suite green, EP-3 does the latter.
  Date: 2026-07-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Everything in this plan lives in one repository (root `/Users/shinzui/Keikaku/bokuno/keiro`,
default branch `master`). You need no knowledge outside this file and the working tree.

**The migrations package.** `keiro-migrations/` (declared by
`keiro-migrations/keiro-migrations.cabal`) ships the framework's SQL and the tooling around
it. Its layout:

- `keiro-migrations/sql-migrations/` holds 16 `.sql` files named
  `YYYY-MM-DD-HH-MM-SS-keiro-<slug>.sql`. The filename's timestamp prefix is how the files
  are ordered (lexicographic order equals chronological order because every field is
  fixed-width and zero-padded). These files are embedded into the library at compile time.
- `keiro-migrations/src/Keiro/Migrations.hs` embeds every file in that directory with
  `embeddedMigrationFiles = $(embedDir "sql-migrations")` (a Template Haskell splice — code
  that runs at compile time). It parses them into codd migrations
  (`keiroFrameworkMigrations`) and, combined with kiroku's own migrations
  (`Kiroku.kirokuMigrations`), exposes `allKeiroMigrations`, `runAllKeiroMigrations`, and
  `runAllKeiroMigrationsNoCheck`. **Important quirk:** GHC does not track the *contents* of
  the embedded directory for recompilation, so after you add, remove, or **edit** any `.sql`
  file you must "touch" the comment block just above `embeddedMigrationFiles` (lines ~93–109)
  to force a recompile, or run `cabal clean`. This applies to EP-1 because you rewrite file
  **bodies**.
- `keiro-migrations/src/Keiro/Migrations/New.hs` is the `keiro-migrate new` scaffolder. Its
  `migrationTemplate` currently emits the four-line search_path explanatory comment, a
  `SET search_path TO kiroku, pg_catalog;` line, and a body placeholder. `migrationFileName`
  stamps the real current UTC time to the second; `migrationSlug` forces a `keiro-` prefix.
- `keiro-migrations/app/Main.hs` is the `keiro-migrate` executable (subcommand `new` for
  scaffolding, otherwise it applies migrations via codd's `getCoddSettings`).
  `keiro-migrations/app/WriteExpectedSchema.hs` is `keiro-write-expected-schema`: it spins up
  an ephemeral PostgreSQL, applies all migrations, and writes codd's on-disk expected-schema
  snapshot to `keiro-migrations/expected-schema/`.
- `keiro-migrations/test/Main.hs` is the test suite `keiro-migrations-test`. It has a
  migration-filename guard (rejects hand-assigned sentinel timestamps whose seconds field is
  `00` or which sit at exactly UTC midnight — see the "Migration timestamps" note below), a
  fresh-migration test that asserts table locations, and a strict drift-gate test.
- `keiro-migrations/expected-schema/v18/` is codd's checked-in on-disk snapshot of the
  migrated database shape (used by the strict drift gate). Today
  `expected-schema/v18/schemas/kiroku/tables/` contains **both** kiroku's event tables
  (`events`, `streams`, `stream_events`, `subscriptions`, `dead_letters`) **and** all
  `keiro_*` tables, because the `keiro_*` tables currently live in the `kiroku` schema.
- `keiro-migrations/ledger-fixups/2026-07-05-realign-keiro-migration-timestamps.sql` is an
  existing one-time SQL artifact that rewrote codd's ledger when the migration files were
  *renamed* from sentinel timestamps to real ones. Read it: it is the pattern reference for a
  transactional, idempotent ledger operation, and its header documents that codd keys applied
  status by filename.

**The tables created by the migrations.** Across the 16 files, the framework creates:
`keiro_snapshots`, `keiro_read_models`, `keiro_timers`, `keiro_outbox`, `keiro_inbox`,
`keiro_projection_dedup`, `keiro_workflows`, `keiro_workflow_steps`,
`keiro_workflow_children`, `keiro_awakeables`, and `keiro_subscription_shards` (11 tables).
Several later files **alter** earlier tables (for example
`2026-06-03-05-14-28-keiro-timer-recovery.sql` adds `keiro_timers.last_error` and rebuilds
its index; `2026-06-15-13-22-31-keiro-messaging-crash-recovery.sql` adds
`keiro_inbox.attempt_count` and three indexes) and one file runs a **data-backfill query**:
`2026-06-15-15-07-25-keiro-workflows-instances.sql` populates `keiro_workflows` with a large
`WITH ... INSERT INTO keiro_workflows SELECT ... FROM keiro_workflow_steps` / `... FROM
keiro_workflow_children` statement and re-adds a check constraint on `keiro_workflow_children`.
Every one of those references must be qualified `keiro.<table>` in the rewrite.

**The kiroku dependency's proven pattern (copy this style).** kiroku does schema ownership
correctly, and its source is on disk at
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. Its bootstrap
(`kiroku-store-migrations/sql-migrations/2026-05-16-12-17-14-kiroku-bootstrap.sql`) begins:

```sql
CREATE SCHEMA IF NOT EXISTS kiroku;
SET search_path TO kiroku, pg_catalog;
```

and then creates unqualified names inside that schema. But every **incremental** kiroku
migration **hard-qualifies** its objects and does not touch `search_path`. For example
`kiroku-store-migrations/sql-migrations/2026-05-29-15-26-04-add-subscription-dead-letters.sql`:

```sql
CREATE TABLE IF NOT EXISTS kiroku.dead_letters (
    dead_letter_id BIGSERIAL PRIMARY KEY,
    ...
    event_id UUID NOT NULL REFERENCES kiroku.events(event_id),
    ...
);

CREATE INDEX IF NOT EXISTS ix_dead_letters_subscription_created_at
    ON kiroku.dead_letters (subscription_name, consumer_group_member, created_at);
```

This is self-contained under codd's per-file sessions: the table name is qualified, the
index's `ON` target is qualified (the index name itself stays unqualified — an index is
automatically created in its table's schema), and any `REFERENCES` is qualified. EP-1 adopts
exactly this style for the `keiro` schema, with **one deliberate difference**: EP-1's
bootstrap uses `CREATE SCHEMA IF NOT EXISTS keiro;` **without** the following
`SET search_path` line, because every statement (bootstrap included) is fully qualified. We
never want a `search_path` pin in any keiro migration.

**Why we don't just repoint the store's schema.** A tempting shortcut is to change kiroku's
store connection `schema` field from `kiroku` to `keiro`. Do not. That field drives both
kiroku's event-store tables **and** the `<schema>.events` `LISTEN`/`NOTIFY` channel name (see
kiroku's `notify_events()` trigger, which builds the channel from `TG_TABLE_SCHEMA`).
Repointing it would move the event tables and break the notification channel. The `keiro`
schema is therefore reached by **qualification** (this plan's DDL, and EP-2's runtime
queries), never by changing the store `schema`. The remediation script must not touch the
store schema either.

**Migration timestamps (a hard test constraint).** The suite's `migrationFileNameSpec`
rejects any migration whose timestamp prefix looks hand-assigned: a `00` seconds field or
exactly UTC midnight (`HH-MM == 00-00`). Because EP-1 **keeps all existing filenames** (it
only rewrites bodies), you will not create any new migration file and this guard stays
satisfied. If a future step ever needs a genuinely new migration, create it with
`keiro-migrate new` (which stamps the real UTC time to the second) — never hand-type a
rounded slot.

**Toolchain.** The build tool is `cabal` (GHC 9.12). Ephemeral PostgreSQL for tests is
provided by the `ephemeral-pg` package (the test uses `Pg.withCached`), running PostgreSQL
major version 18. All commands below are run from the repository root
`/Users/shinzui/Keikaku/bokuno/keiro` unless stated otherwise.

**Commit discipline.** Follow Conventional Commits. Every commit made while implementing this
plan must carry these three git trailers:

```text
MasterPlan: docs/masterplans/12-keiro-schema-separation-and-migration-architecture-rework.md
ExecPlan: docs/plans/85-rewrite-keiro-migrations-to-own-a-dedicated-keiro-schema-with-qualified-ddl.md
Intention: intention_01kwsrmsbsedqb0rh0vb41x04m
```


## Plan of Work

The work is five milestones. M1 establishes the schema-name constant and rewrites the
bootstrap (the only file that creates the schema). M2 rewrites the remaining fifteen files.
M3 fixes the scaffolder so future migrations are born qualified. M4 flips the test's
table-location assertions and regenerates the drift-gate snapshot so the suite is green. M5
ships and verifies the alpha-database remediation script. Milestones M1–M4 are verifiable
together by one green `cabal test keiro-migrations-test`; M5 is verifiable by a documented
psql procedure. Each milestone below states its scope, what will exist at the end, the exact
commands, and the acceptance you should observe.


### Milestone M1 — Schema-name constant and rewritten bootstrap

**Scope.** Introduce the single Haskell source of truth for the schema name, then rewrite the
bootstrap migration so it creates the `keiro` schema and its initial three tables
(`keiro_snapshots`, `keiro_read_models`, `keiro_timers`) qualified into it, with no
`search_path` pin.

**What will exist at the end.** A new module `keiro-core/src/Keiro/Schema.hs` exporting
`keiroSchema :: Text`, listed in `keiro-core/keiro-core.cabal`'s `exposed-modules`. A
rewritten `keiro-migrations/sql-migrations/2026-05-17-13-58-15-keiro-bootstrap.sql` whose
first statement is `CREATE SCHEMA IF NOT EXISTS keiro;` and whose every `CREATE TABLE` /
`CREATE INDEX` names `keiro.<table>`.

First, create `keiro-core/src/Keiro/Schema.hs`:

```haskell
{- | The single source of truth for the name of the dedicated PostgreSQL schema
that owns all of Keiro's framework tables.

A PostgreSQL /schema/ is a namespace inside one database. Keiro's framework
tables (@keiro_snapshots@, @keiro_timers@, @keiro_outbox@, …) live in the schema
named by 'keiroSchema'. The migrations in @keiro-migrations@ create them
schema-qualified (@keiro.<table>@); runtime queries in the @keiro@ package
qualify against this same name. This is the literal string every part of the
system must agree on, so it is defined once here and imported elsewhere.
-}
module Keiro.Schema (keiroSchema) where

import Data.Text (Text)

-- | The schema that owns Keiro's framework tables: @"keiro"@.
keiroSchema :: Text
keiroSchema = "keiro"
```

Then add `Keiro.Schema` to the `exposed-modules` list in `keiro-core/keiro-core.cabal` (the
`text` dependency is already present, so no dependency change is needed).

Then rewrite `keiro-migrations/sql-migrations/2026-05-17-13-58-15-keiro-bootstrap.sql`
entirely. Delete the four-line search_path comment and the `SET search_path TO kiroku,
pg_catalog;` line. Insert `CREATE SCHEMA IF NOT EXISTS keiro;` as the first statement.
Qualify every object. The full new file:

```sql
-- Keiro framework bootstrap migration (codd).
--
-- Keiro owns the dedicated `keiro` schema. codd applies this file in its own
-- session, so the schema is created here and every object is written fully
-- qualified as keiro.<name> — no session search_path pin is used anywhere.
CREATE SCHEMA IF NOT EXISTS keiro;

CREATE TABLE IF NOT EXISTS keiro.keiro_snapshots (
  stream_id BIGINT PRIMARY KEY,
  stream_version BIGINT NOT NULL,
  state JSONB NOT NULL,
  state_codec_version BIGINT NOT NULL,
  regfile_shape_hash TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS keiro_snapshots_compat_idx
  ON keiro.keiro_snapshots (stream_id, state_codec_version, regfile_shape_hash, stream_version DESC);

CREATE TABLE IF NOT EXISTS keiro.keiro_read_models (
  name TEXT PRIMARY KEY,
  version BIGINT NOT NULL,
  shape_hash TEXT NOT NULL,
  last_built_at TIMESTAMPTZ,
  status TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS keiro.keiro_timers (
  timer_id UUID PRIMARY KEY,
  process_manager_name TEXT NOT NULL,
  correlation_id TEXT NOT NULL,
  fire_at TIMESTAMPTZ NOT NULL,
  payload JSONB NOT NULL,
  status TEXT NOT NULL DEFAULT 'scheduled',
  attempts BIGINT NOT NULL DEFAULT 0,
  fired_event_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS keiro_timers_due_idx
  ON keiro.keiro_timers (status, fire_at, process_manager_name);
```

Note two rules that recur through M1 and M2: (1) the **table** in `CREATE TABLE` and the
**`ON` target** of every `CREATE INDEX` are qualified `keiro.<table>`; (2) the **index name**
itself stays bare (`keiro_timers_due_idx`, not `keiro.keiro_timers_due_idx`) because an index
is automatically created in the schema of its table.

**Commands and acceptance.** M1 is not independently testable until M2 rewrites the rest
(the suite migrates all files together), so verify M1 by building:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal build keiro-core keiro-migrations
```

Acceptance: both packages compile. The `keiro-core` build proves `Keiro.Schema` is
well-formed and exposed. Commit M1 with a message such as `feat(migrations): create dedicated
keiro schema in bootstrap and add keiroSchema constant` plus the three trailers.


### Milestone M2 — Rewrite the remaining fifteen migrations, fully qualified

**Scope.** Rewrite the other fifteen `.sql` files so every `CREATE TABLE`, `CREATE INDEX`,
`ALTER TABLE`, `DROP INDEX`, and data-backfill statement is qualified `keiro.<table>`, and so
each file's `SET search_path TO kiroku, pg_catalog;` line and its search_path explanatory
comment are removed. Genuinely descriptive comments (the paragraphs explaining what a table
is *for*) are **kept** — only the search_path boilerplate goes.

**What will exist at the end.** Fifteen rewritten files with no `search_path` reference
anywhere and every `keiro_*` object qualified. The touch-comment in `Keiro.Migrations.hs`
nudged so Template Haskell re-embeds the new bodies.

Apply these edits file by file. In every file, delete the `SET search_path TO kiroku,
pg_catalog;` line and the immediately-adjacent search_path explanatory comment; keep any
table-semantics prose comment.

- `2026-05-19-12-55-02-keiro-outbox.sql`: `CREATE TABLE IF NOT EXISTS keiro.keiro_outbox`;
  both indexes' `ON keiro_outbox` → `ON keiro.keiro_outbox`
  (`keiro_outbox_pending_idx`, `keiro_outbox_head_of_line_idx`).
- `2026-05-19-13-05-23-keiro-inbox.sql`: `CREATE TABLE IF NOT EXISTS keiro.keiro_inbox`; both
  indexes' `ON keiro_inbox` → `ON keiro.keiro_inbox`
  (`keiro_inbox_received_idx`, `keiro_inbox_completed_idx`).
- `2026-06-03-05-14-28-keiro-timer-recovery.sql`: `ALTER TABLE keiro.keiro_timers`;
  `DROP INDEX IF EXISTS keiro.keiro_timers_due_idx`; the rebuilt
  `CREATE INDEX ... ON keiro.keiro_timers ...`.
- `2026-06-03-16-10-05-keiro-workflow-steps.sql`: keep the semantic comment (lines 1–10 about
  the journaled-steps index); `CREATE TABLE IF NOT EXISTS keiro.keiro_workflow_steps`;
  `CREATE INDEX ... ON keiro.keiro_workflow_steps ...`.
- `2026-06-03-18-19-41-keiro-awakeables.sql`: keep the semantic comment; `CREATE TABLE IF NOT
  EXISTS keiro.keiro_awakeables`; both indexes' `ON keiro.keiro_awakeables`.
- `2026-06-03-19-49-23-keiro-workflow-children.sql`: keep the semantic comment; `CREATE TABLE
  IF NOT EXISTS keiro.keiro_workflow_children`; both indexes' `ON keiro.keiro_workflow_children`.
- `2026-06-04-02-12-28-keiro-workflow-generation.sql`: this file's leading comment IS the
  search_path comment — remove the `SET search_path` line and the three comment lines that
  precede it (lines 1–4), keep the continue-as-new explanatory paragraph. Qualify all five
  statements: `ALTER TABLE keiro.keiro_workflow_steps ADD COLUMN ...`; `ALTER TABLE
  keiro.keiro_workflow_steps DROP CONSTRAINT keiro_workflow_steps_pkey`; `ALTER TABLE
  keiro.keiro_workflow_steps ADD PRIMARY KEY (...)`; `DROP INDEX IF EXISTS
  keiro.keiro_workflow_steps_workflow_idx`; `CREATE INDEX ... ON keiro.keiro_workflow_steps ...`.
  (The constraint name `keiro_workflow_steps_pkey` and index name stay bare — they are
  resolved within the table's schema.)
- `2026-06-04-03-53-34-keiro-subscription-shards.sql`: keep the long semantic comment (lines
  1–15); remove only the `SET search_path` line (line 16); `CREATE TABLE IF NOT EXISTS
  keiro.keiro_subscription_shards`; both indexes' `ON keiro.keiro_subscription_shards`.
- `2026-06-15-13-22-31-keiro-messaging-crash-recovery.sql`: keep the `-- messaging crash
  recovery` title and the per-statement `-- H5/H3/H4/L8` comments; remove the search_path
  comment + line. Qualify: `ALTER TABLE keiro.keiro_inbox ADD COLUMN ...`; `CREATE INDEX
  keiro_inbox_backlog_idx ON keiro.keiro_inbox ...`; `CREATE INDEX keiro_outbox_sent_gc_idx ON
  keiro.keiro_outbox ...`; `CREATE INDEX keiro_outbox_source_order_idx ON keiro.keiro_outbox ...`.
- `2026-06-15-15-07-25-keiro-workflows-instances.sql`: keep the semantic comment (lines 1–3);
  remove the `SET search_path` line (line 4). Qualify **every** table reference, including
  inside the CTE/backfill: `CREATE TABLE IF NOT EXISTS keiro.keiro_workflows`; `CREATE INDEX
  ... ON keiro.keiro_workflows ...`; in the `WITH current_gen AS (SELECT ... FROM
  keiro.keiro_workflow_steps ...)` and the `terminal` CTE's three `EXISTS (SELECT 1 FROM
  keiro.keiro_workflow_steps s ...)` subqueries; `INSERT INTO keiro.keiro_workflows (...)
  SELECT ... FROM terminal`; the second `INSERT INTO keiro.keiro_workflows (...) SELECT ...
  FROM keiro.keiro_workflow_children WHERE status = 'running'`; and the two `ALTER TABLE
  keiro.keiro_workflow_children ... CONSTRAINT keiro_workflow_children_status_chk ...`
  statements. The CTE names `current_gen` and `terminal` and the alias `s`/`cg` stay bare
  (they are query-local, not schema objects).
- `2026-06-15-17-53-48-keiro-workflow-gc-index.sql`: remove the two-line search_path comment +
  line; keep the `-- GC eligibility scan` comment; `CREATE INDEX keiro_workflows_gc_idx ON
  keiro.keiro_workflows (status, completed_at)`.
- `2026-06-15-18-01-33-keiro-workflows-wake-after.sql`: remove the search_path comment + line;
  keep the `-- Self-expiring resume hint` comment; `ALTER TABLE keiro.keiro_workflows ADD
  COLUMN IF NOT EXISTS wake_after TIMESTAMPTZ`.
- `2026-06-15-21-49-37-keiro-projection-dedup.sql`: remove the sole `SET search_path` line;
  `CREATE TABLE IF NOT EXISTS keiro.keiro_projection_dedup`; `CREATE INDEX
  keiro_projection_dedup_applied_at_idx ON keiro.keiro_projection_dedup (applied_at)`.
- `2026-07-02-00-15-48-keiro-outbox-claim-order-index.sql`: remove the search_path comment +
  line; keep the `-- Serves the outbox claim query` comment; `CREATE INDEX
  keiro_outbox_claim_order_idx ON keiro.keiro_outbox (created_at, outbox_id) WHERE ...`.
- `2026-07-02-00-58-54-keiro-inbox-drop-received-idx.sql`: remove the search_path comment +
  line; keep the `-- keiro_inbox_received_idx served only ...` comment; `DROP INDEX IF EXISTS
  keiro.keiro_inbox_received_idx`.

After editing the SQL, force the re-embed by touching the comment above
`embeddedMigrationFiles` in `keiro-migrations/src/Keiro/Migrations.hs` (lines ~93–109). Add or
adjust a line noting the EP-1 body rewrite, for example append a sentence like
`-- EP-1 (MasterPlan 12): bodies rewritten to create/qualify the keiro schema.` Any edit to
that comment block invalidates the module's recompilation hash so `embedDir` re-reads the new
files.

**Commands and acceptance.** M2 finishes the DDL, so the fresh-migration test can now run.
The full acceptance is folded into M4 (which flips the assertions), but you can smoke-test the
DDL immediately:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal build keiro-migrations
grep -rn 'search_path' keiro-migrations/sql-migrations/    # expect: no matches
```

Acceptance: `keiro-migrations` compiles and `grep` finds **zero** `search_path` occurrences in
the SQL directory. Commit M2, for example `refactor(migrations): qualify all keiro DDL into
the keiro schema and drop search_path pins`, with the three trailers.


### Milestone M3 — Scaffolder emits qualified, comment-free templates

**Scope.** Update `keiro-migrations/src/Keiro/Migrations/New.hs` so `keiro-migrate new`
generates a template that has no `SET search_path` line and shows a `keiro.`-qualified
example, and update the function's Haddock to match.

**What will exist at the end.** A `migrationTemplate` that produces a qualified example, and
Haddock that no longer references `search_path` or `docs/plans/46`.

Replace the `migrationTemplate` definition and its Haddock. New Haddock and body:

```haskell
{- | The skeleton body for a new migration. Keiro owns the dedicated @keiro@
schema (created by the bootstrap migration), and every migration writes its
objects fully qualified as @keiro.<name>@ with no session @search_path@ pin.
The template therefore emits a header comment and a qualified example only.
-}
migrationTemplate :: String -> String
migrationTemplate description =
    unlines
        [ "-- " <> description
        , "--"
        , "-- Create objects fully qualified in the keiro schema (no search_path pin)."
        , "-- Example:"
        , "--   CREATE TABLE IF NOT EXISTS keiro.keiro_example ("
        , "--     id UUID PRIMARY KEY"
        , "--   );"
        , ""
        , "-- TODO: write the migration body. Prefer idempotent DDL (IF NOT EXISTS)."
        ]
```

Leave `migrationFileName`, `migrationSlug` (which forces the `keiro-` filename prefix), and
`newMigrationFile` unchanged — the `keiro-` slug prefix is a filename convention independent
of the schema name.

**Commands and acceptance.**

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro/keiro-migrations
KEIRO_MIGRATIONS_DIR="$(mktemp -d)" cabal run keiro-migrate -- new "scaffold smoke test"
```

Acceptance: the command prints `Created <tmpdir>/<timestamp>-keiro-scaffold-smoke-test.sql`;
opening that file shows the qualified `keiro.keiro_example` example and **no** `SET
search_path` line. Delete the temp file afterward (it is outside the repo, so it will not be
embedded). Commit M3, for example `feat(migrations): scaffolder emits qualified comment-free
template`, with the three trailers.


### Milestone M4 — Flip the test assertions and regenerate the drift-gate snapshot

**Scope.** Update `keiro-migrations/test/Main.hs` so the fresh-migration test asserts the
`keiro_*` tables live in the `keiro` schema and are absent from **both** `kiroku` and
`public`, while kiroku's own event tables remain in `kiroku`. Then regenerate the checked-in
expected-schema snapshot so the strict drift-gate test stays green. Do **not** touch
`testCoddSettings` (its `namespacesToCheck` and the strict-check example belong to EP-3).

**What will exist at the end.** A `keiro-migrations-test` that passes and genuinely proves the
tables moved schemas, plus a regenerated `keiro-migrations/expected-schema/` tree with the
`keiro_*` table representations removed from the `kiroku/tables/` directory.

Split the single `expectedTables` list into two, because after the move the `keiro_*` tables
and the kiroku event tables live in different schemas and can no longer be asserted against
one schema. Replace the `expectedTables` binding (lines ~140–152) with:

```haskell
-- | kiroku's own event-store tables, which remain in the kiroku schema.
kirokuTables :: [Text]
kirokuTables =
    [ "events"
    , "stream_events"
    , "streams"
    , "subscriptions"
    ]

-- | Keiro's framework tables, which now live in the dedicated keiro schema.
keiroTables :: [Text]
keiroTables =
    [ "keiro_inbox"
    , "keiro_outbox"
    , "keiro_read_models"
    , "keiro_snapshots"
    , "keiro_timers"
    , "keiro_workflows"
    ]
```

(The list stays a representative subset — the same tables the original `expectedTables`
covered — rather than all eleven; the strict drift gate is what exhaustively pins every
table.) Then rewrite the body of the fresh-migration test (`it "applies Kiroku and Keiro
migrations to a fresh database and is repeatable"`) so its assertion block reads:

```haskell
runAllKeiroMigrationsNoCheck coddSettings (secondsToDiffTime 5)
assertTablesExist connStr "kiroku" kirokuTables
assertTablesExist connStr "keiro" keiroTables
assertTablesAbsent connStr "kiroku" keiroTables
assertTablesAbsent connStr "public" keiroTables
assertTablesAbsent connStr "public" kirokuTables

runAllKeiroMigrationsNoCheck coddSettings (secondsToDiffTime 5)
assertTablesExist connStr "kiroku" kirokuTables
assertTablesExist connStr "keiro" keiroTables
assertTablesAbsent connStr "kiroku" keiroTables
assertTablesAbsent connStr "public" keiroTables
assertColumnExists connStr "keiro" "keiro_timers" "last_error"
```

The key changes from today: `keiroTables` are asserted **present in `keiro`** and **absent
from `kiroku`** (proving the relocation), `kirokuTables` stay **present in `kiroku`**, and the
`assertColumnExists` for `keiro_timers.last_error` now targets the `keiro` schema (it was
`kiroku`). The helper functions `assertTablesExist`, `assertTablesAbsent`, and
`assertColumnExists` already take the schema as a parameter and need no change.

Leave `testCoddSettings` exactly as it is (`namespacesToCheck = IncludeSchemas [SqlSchema
"kiroku"]`). This is deliberate: EP-3 owns rescoping it to `keiro`. Under the still-`kiroku`
scope, the strict drift-gate test (`it "matches the checked-in expected schema"`) compares
only the `kiroku` namespace — which, after the move, contains only the event tables — against
the snapshot. So you must regenerate the snapshot so its `kiroku` namespace also contains only
the event tables:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal run keiro-write-expected-schema
git status keiro-migrations/expected-schema
```

Acceptance for the regeneration: `git status` shows deletions under
`keiro-migrations/expected-schema/v18/schemas/kiroku/tables/` for the `keiro_*` entries
(`keiro_awakeables`, `keiro_inbox`, `keiro_outbox`, `keiro_projection_dedup`,
`keiro_read_models`, `keiro_snapshots`, `keiro_subscription_shards`, `keiro_timers`,
`keiro_workflow_children`, `keiro_workflow_steps`, `keiro_workflows`) and leaves the kiroku
event-table entries (`events`, `streams`, `stream_events`, `subscriptions`, `dead_letters`)
in place. No new `schemas/keiro/` directory appears, because the generator is still scoped to
`kiroku` (EP-3 adds that). The `roles/shinzui` directory and the `owner: shinzui` db-settings
will still be present — that portability leak is EP-3's to fix and is expected to remain here.

Then run the suite:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal test keiro-migrations-test
```

Acceptance: all examples pass, including "applies Kiroku and Keiro migrations to a fresh
database and is repeatable" (now proving `keiro_*` in `keiro`, absent from `kiroku`/`public`)
and "matches the checked-in expected schema". Commit M4, for example `test(migrations): assert
keiro tables live in the keiro schema and regenerate drift snapshot`, with the three trailers.


### Milestone M5 — Alpha-database remediation script and its verification

**Scope.** Ship a one-time, idempotent, transactional SQL script that relocates the `keiro_*`
tables of an existing 0.1.0.0 database from the `kiroku` schema into a new `keiro` schema, and
document a verification that proves it works and leaves `keiro-migrate` a no-op.

**Why a script and not a migration.** A fresh database gets the new layout directly from the
rewritten migration bodies (M1/M2). But a database already seeded from `keiro-migrations
0.1.0.0` has its `keiro_*` tables physically in the `kiroku` schema **and** has already
recorded every migration filename as applied in codd's ledger. Because EP-1 keeps the
filenames unchanged, codd will re-run none of them — so the new `CREATE SCHEMA keiro` and
qualified DDL will never execute on that database via migration. The remediation script does
out-of-band what the (already-applied) migrations cannot: it creates the schema and moves the
existing tables, preserving their data, indexes, and constraints.

**What will exist at the end.** A new file
`keiro-migrations/remediation/2026-07-05-relocate-keiro-tables-to-keiro-schema.sql` with this
content:

```sql
-- One-time remediation: relocate keiro framework tables from the kiroku schema
-- into the dedicated keiro schema (MasterPlan 12 / EP-1).
--
-- Context: keiro-migrations 0.1.0.0 created every keiro_* table UNQUALIFIED
-- under `SET search_path TO kiroku`, so the framework tables physically landed
-- inside kiroku's private schema. From EP-1 forward the migrations create them
-- in a dedicated `keiro` schema. This script moves an already-migrated 0.1.0.0
-- database to the new layout WITHOUT re-running migrations and without data loss.
--
-- codd identifies applied migrations by FILENAME (the `name` column in
-- codd_schema.sql_migrations). EP-1 KEEPS every migration filename unchanged and
-- rewrote only the file bodies, so codd still sees all migrations as applied and
-- re-runs nothing. This script therefore does NOT rename any ledger row; it only
-- (1) creates the keiro schema and (2) moves each keiro_* table into it.
--
-- SAFETY / IDEMPOTENCE: each move is guarded by to_regclass, so a second run is a
-- no-op (the table is already in keiro and no longer visible as kiroku.<table>).
-- The keiro_* tables use no SERIAL columns and no foreign keys, so there is no
-- dependent sequence to orphan and no cross-schema reference to break. Wrapped in
-- one transaction: all-or-nothing.
--
-- WHEN TO RUN: once per long-lived database seeded from 0.1.0.0 (staging, prod,
-- persistent local), BEFORE the next keiro-migrate that carries the EP-1 file
-- bodies. Ephemeral / template-per-suite test databases apply the new bodies
-- from scratch and never need this.
--
-- NOTE: this codd builds its ledger as `codd_schema.sql_migrations`. If your codd
-- version uses the `codd` schema instead, adjust the verification query below.

BEGIN;

CREATE SCHEMA IF NOT EXISTS keiro;

DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'keiro_snapshots', 'keiro_read_models', 'keiro_timers', 'keiro_outbox',
    'keiro_inbox', 'keiro_projection_dedup', 'keiro_workflows',
    'keiro_workflow_steps', 'keiro_workflow_children', 'keiro_awakeables',
    'keiro_subscription_shards'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    IF to_regclass('kiroku.' || t) IS NOT NULL THEN
      EXECUTE format('ALTER TABLE kiroku.%I SET SCHEMA keiro', t);
    END IF;
  END LOOP;
END
$$;

COMMIT;

-- Verification (run after COMMIT; expects zero rows). Every current on-disk
-- migration filename must already be recorded as applied, so a subsequent
-- keiro-migrate is a no-op. Filenames are unchanged by EP-1, so there is nothing
-- to realign; this query simply confirms it.
--
--   SELECT f.name
--   FROM (VALUES
--     ('2026-05-17-13-58-15-keiro-bootstrap.sql'),
--     ('2026-05-19-12-55-02-keiro-outbox.sql'),
--     ('2026-05-19-13-05-23-keiro-inbox.sql'),
--     ('2026-06-03-05-14-28-keiro-timer-recovery.sql'),
--     ('2026-06-03-16-10-05-keiro-workflow-steps.sql'),
--     ('2026-06-03-18-19-41-keiro-awakeables.sql'),
--     ('2026-06-03-19-49-23-keiro-workflow-children.sql'),
--     ('2026-06-04-02-12-28-keiro-workflow-generation.sql'),
--     ('2026-06-04-03-53-34-keiro-subscription-shards.sql'),
--     ('2026-06-15-13-22-31-keiro-messaging-crash-recovery.sql'),
--     ('2026-06-15-15-07-25-keiro-workflows-instances.sql'),
--     ('2026-06-15-17-53-48-keiro-workflow-gc-index.sql'),
--     ('2026-06-15-18-01-33-keiro-workflows-wake-after.sql'),
--     ('2026-06-15-21-49-37-keiro-projection-dedup.sql'),
--     ('2026-07-02-00-15-48-keiro-outbox-claim-order-index.sql'),
--     ('2026-07-02-00-58-54-keiro-inbox-drop-received-idx.sql')
--   ) AS f(name)
--   WHERE NOT EXISTS (
--     SELECT 1 FROM codd_schema.sql_migrations m WHERE m.name = f.name
--   );
```

`ALTER TABLE ... SET SCHEMA` moves the table together with its indexes and constraints, so no
separate index moves are needed. The `to_regclass('kiroku.' || t)` guard returns `NULL` when
the table is not in `kiroku` (already moved, or never existed), making a re-run a no-op.

**Verification (documented procedure).** Prove the script relocates tables, is idempotent, and
leaves the ledger consistent by simulating a 0.1.0.0 database in an ephemeral PostgreSQL. Start
one and capture its connection string:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal run keiro-migrate -- --help >/dev/null 2>&1 || true   # ensures the build is warm
```

Then, in a scratch database (any local PostgreSQL 18, or an `ephemeral-pg` instance), reproduce
the old layout and run the script with `psql`:

```sql
-- Simulate a 0.1.0.0 database: kiroku schema owns the keiro_* tables, with data.
CREATE SCHEMA kiroku;
CREATE TABLE kiroku.keiro_snapshots (
  stream_id BIGINT PRIMARY KEY,
  stream_version BIGINT NOT NULL,
  state JSONB NOT NULL,
  state_codec_version BIGINT NOT NULL,
  regfile_shape_hash TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO kiroku.keiro_snapshots
  VALUES (1, 7, '{}'::jsonb, 1, 'abc', now(), now());
-- (create the other keiro_* tables the same way if you want a fuller check)
```

Now run the remediation body (the `BEGIN; ... COMMIT;` block above) via `psql -f`, then check
the outcome:

```sql
SELECT to_regclass('keiro.keiro_snapshots')  AS moved_in;   -- expect: keiro.keiro_snapshots
SELECT to_regclass('kiroku.keiro_snapshots') AS moved_out;  -- expect: NULL
SELECT stream_version FROM keiro.keiro_snapshots WHERE stream_id = 1;  -- expect: 7 (data intact)
```

Run the same remediation body a **second** time and re-check: `moved_in` is still
`keiro.keiro_snapshots`, `moved_out` is still `NULL`, no error is raised — proving idempotence.

Finally, the ledger no-op is proven by construction: the script does not modify
`codd_schema.sql_migrations`, and the migration filenames are unchanged, so the commented
verification query returns zero rows on a real 0.1.0.0 database, and a subsequent `keiro-migrate`
(with `CODD_*` env vars per `keiro-migrations/README.md`) reports no migrations to apply. Record
the observed transcript in Progress when you run it.

Commit M5, for example `feat(migrations): add alpha-database keiro-schema remediation script`,
with the three trailers.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless a `cd`
is shown. The steps mirror the milestones.

M1:

```bash
# Create keiro-core/src/Keiro/Schema.hs (content in Milestone M1),
# add `Keiro.Schema` to exposed-modules in keiro-core/keiro-core.cabal,
# and rewrite keiro-migrations/sql-migrations/2026-05-17-13-58-15-keiro-bootstrap.sql.
cabal build keiro-core keiro-migrations
```

Expected: both compile with no errors.

M2:

```bash
# Rewrite the other 15 files (Milestone M2) and touch the embed comment in
# keiro-migrations/src/Keiro/Migrations.hs.
cabal build keiro-migrations
grep -rn 'search_path' keiro-migrations/sql-migrations/
```

Expected: `keiro-migrations` compiles; the `grep` prints nothing (exit status 1).

M3:

```bash
cd keiro-migrations
KEIRO_MIGRATIONS_DIR="$(mktemp -d)" cabal run keiro-migrate -- new "scaffold smoke test"
```

Expected transcript:

```text
Created /var/folders/.../<timestamp>-keiro-scaffold-smoke-test.sql
Next: touch the embed comment in src/Keiro/Migrations.hs so embedDir picks it up (or run `cabal clean`).
```

Open the generated file and confirm it contains `keiro.keiro_example` and no `SET
search_path`. Then return to the root: `cd ..`.

M4:

```bash
# Edit keiro-migrations/test/Main.hs (Milestone M4).
cabal run keiro-write-expected-schema
git status keiro-migrations/expected-schema
cabal test keiro-migrations-test
```

Expected: `keiro-write-expected-schema` prints `Wrote expected schema to
keiro-migrations/expected-schema`; `git status` shows only deletions of `keiro_*` entries under
`schemas/kiroku/tables/`; `cabal test keiro-migrations-test` reports all examples passing.

M5:

```bash
# Create keiro-migrations/remediation/2026-07-05-relocate-keiro-tables-to-keiro-schema.sql
# (Milestone M5), then run the documented psql verification against a scratch database.
```

Expected: the verification queries return the values noted in M5; a second run is a no-op.


## Validation and Acceptance

The change is validated end to end by `cabal test keiro-migrations-test` from the repository
root. Interpret its two behavioral examples:

- "applies Kiroku and Keiro migrations to a fresh database and is repeatable" migrates a fresh
  ephemeral PostgreSQL 18 database twice and asserts, after each pass, that the representative
  `keiro_*` tables exist in the **`keiro`** schema, are **absent from `kiroku`** and
  **`public`**, that kiroku's `events`/`streams`/`stream_events`/`subscriptions` remain in
  **`kiroku`**, and that `keiro.keiro_timers.last_error` exists. This is the direct,
  human-meaningful proof that Keiro now owns its own schema and no longer squats in kiroku's.
  Running it twice proves the qualified DDL is idempotent under codd's re-apply.
- "matches the checked-in expected schema" runs a strict codd comparison of the migrated
  database against `keiro-migrations/expected-schema/`. After M4's regeneration it passes,
  proving the snapshot and the migrations agree.

Additional observable proof beyond the suite: `grep -rn 'search_path'
keiro-migrations/sql-migrations/` returns nothing (no file pins a search_path anymore);
`grep -rn 'CREATE SCHEMA' keiro-migrations/sql-migrations/` shows exactly one match, in the
bootstrap, creating `keiro`; and `keiro-migrate new` produces a qualified, comment-free
template. The remediation script is validated by the documented psql procedure in M5 (tables
move, data intact, second run a no-op).

A run "fails" if any table-location assertion reports a missing/present table (for example a
`keiro_*` table still found in `kiroku` means a `CREATE TABLE` was left unqualified), or if the
strict-check example returns `SchemasDiffer` (the snapshot was not regenerated after the DDL
change).


## Idempotence and Recovery

The migration DDL is idempotent: every statement uses `IF NOT EXISTS` / `IF EXISTS` guards and
codd records each filename as applied so it never re-runs it. Re-running `cabal test
keiro-migrations-test` is always safe (each run uses a fresh or cached ephemeral database).

Regenerating the expected-schema snapshot (`cabal run keiro-write-expected-schema`) is
repeatable and deterministic on a given machine; if a regeneration looks wrong, `git checkout
-- keiro-migrations/expected-schema` restores the committed tree and you can re-run.

The remediation script is idempotent and transactional: the `to_regclass` guard makes a second
run a no-op, and the `BEGIN; ... COMMIT;` wrapper makes each run all-or-nothing (a failure
mid-way rolls back, leaving the database in its prior state). It never drops or truncates data;
`ALTER TABLE ... SET SCHEMA` relocates the table with its rows, indexes, and constraints
intact. If a database is only partially moved (for example an interrupted manual run outside a
transaction), simply re-run the whole script — already-moved tables are skipped by the guard
and the remaining ones are moved. To reverse a move manually, `ALTER TABLE keiro.<table> SET
SCHEMA kiroku;` restores the old location, but this is only for emergency rollback and is not
part of the supported path.

Because EP-1 keeps every migration filename, there is no ledger row to repair; if you ever
suspect ledger drift, the commented verification query in the remediation script lists any
current filename missing from `codd_schema.sql_migrations` (expected: none on a 0.1.0.0
database).


## Interfaces and Dependencies

**Libraries and tools.** `cabal` (GHC 9.12) builds and tests. `codd` (the migration runner,
dependency `>=0.1.8`) applies the embedded migrations and drives the expected-schema drift
gate; it identifies applied migrations by filename in `codd_schema.sql_migrations`.
`file-embed`'s `embedDir` splices the SQL directory into `Keiro.Migrations` at compile time.
`ephemeral-pg` (`>=0.2`) provides the throwaway PostgreSQL 18 databases the tests and the
snapshot generator use (`Pg.withCached`). `hasql`/`hasql-pool` run the verification queries in
the test.

**The schema-name constant (this plan is its source of truth).** EP-1 defines
`keiroSchema :: Text` in the new module `Keiro.Schema`
(`keiro-core/src/Keiro/Schema.hs`), added to `keiro-core`'s `exposed-modules`. Its value is the
literal `"keiro"`. Later plans import it rather than re-declaring the string: EP-2
(`docs/plans/86-...`) qualifies every runtime query in the `keiro` package against it; EP-4
(`docs/plans/88-...`) uses it for the default projection schema. The `keiro` runtime package
already depends on `keiro-core`, so the import is available with no new dependency edge. The
`keiro-migrations` package does **not** import it — its migrations are raw embedded SQL and its
codd `CoddSettings` use the bare literal `"keiro"` (EP-3 sets `namespacesToCheck =
IncludeSchemas [SqlSchema "keiro"]` with that literal), because adding a `keiro-core`
dependency to the migrations package for a single string is unwarranted.

**Signatures and files that must exist at the end of each milestone.** After M1:
`Keiro.Schema.keiroSchema :: Text` compiles and is exported; the bootstrap file creates schema
`keiro` and qualified initial tables. After M2: none of the 16 SQL files contains
`search_path`, and every `keiro_*` object is qualified; the embed comment in
`Keiro.Migrations.hs` has been touched. After M3:
`Keiro.Migrations.New.migrationTemplate :: String -> String` emits a qualified, comment-free
template. After M4: `keiro-migrations/test/Main.hs` exposes `kirokuTables :: [Text]` and
`keiroTables :: [Text]` and asserts table locations against `keiro`/`kiroku`/`public`; the
snapshot under `keiro-migrations/expected-schema/` matches the migrated database under the
`kiroku` scope. After M5:
`keiro-migrations/remediation/2026-07-05-relocate-keiro-tables-to-keiro-schema.sql` exists and
passes the documented verification.

**Boundaries with sibling plans (do not cross).**

- EP-3 (`docs/plans/87-...`) owns `testCoddSettings` in `keiro-migrations/test/Main.hs`
  (its `namespacesToCheck` and the strict-check example) and the WriteExpectedSchema
  `namespacesToCheck`, plus the role/owner/db-settings portability-leak fix. EP-1 must not
  edit `testCoddSettings` or `keiro-migrations/app/WriteExpectedSchema.hs`; it only edits the
  `assertTablesExist`/`assertTablesAbsent`/`assertColumnExists` call sites and the
  `kirokuTables`/`keiroTables` lists, and regenerates the snapshot data under the existing
  `kiroku` scope. The `roles/shinzui` and `owner: shinzui` entries will still be present after
  EP-1's regeneration — that is EP-3's fix, not a defect in EP-1.
- EP-2 (`docs/plans/86-...`) qualifies runtime query strings against `keiroSchema`. EP-1 does
  not touch runtime modules in the `keiro` package.
- The store connection `schema` field (kiroku's `defaultConnectionSettings`, `schema =
  "kiroku"`) must **not** be repointed to `keiro`: it drives both kiroku's event tables and
  the `<schema>.events` NOTIFY channel. EP-1's remediation and DDL reach the `keiro` schema by
  qualification only.


## Revision History

- 2026-07-05: Initial authoring of the plan from the skeleton. Filled Purpose, Context, Plan
  of Work (five milestones), Concrete Steps, Validation, Idempotence, and Interfaces from a
  first-hand reading of the 16 migration files, `Keiro.Migrations`, `Keiro.Migrations.New`,
  the test suite, the existing `ledger-fixups` artifact, kiroku's bootstrap and an incremental
  migration, the expected-schema tree, and the package cabal files. Seeded the Decision Log
  with the clean-rewrite (keep filenames), schema-name-constant location (`Keiro.Schema` in
  `keiro-core`), no-ledger-rename remediation, and EP-1-regenerates-snapshot decisions.
  Rationale: establish a fully self-contained foundation plan for MasterPlan 12 that a novice
  can execute end to end.
