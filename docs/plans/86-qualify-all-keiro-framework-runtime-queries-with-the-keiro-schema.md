---
id: 86
slug: qualify-all-keiro-framework-runtime-queries-with-the-keiro-schema
title: "Qualify all keiro framework runtime queries with the keiro schema"
kind: exec-plan
created_at: 2026-07-05T18:39:12Z
intention: "intention_01kwsrmsbsedqb0rh0vb41x04m"
master_plan: "docs/masterplans/12-keiro-schema-separation-and-migration-architecture-rework.md"
---

# Qualify all keiro framework runtime queries with the keiro schema

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Keiro is an event-sourcing framework and durable-workflow engine written in Haskell (the
`keiro` package under `keiro/`). It stores its own state — snapshots, timers, an outbox and
inbox, workflow bookkeeping, subscription shard leases, and a projection dedup ledger — in a
set of PostgreSQL tables whose names all begin with `keiro_`. Today every runtime query that
touches those tables names them **bare**, for example `INSERT INTO keiro_outbox ...` or
`FROM keiro_timers`. A bare (unqualified) table name is not enough on its own to tell
PostgreSQL where the table lives; PostgreSQL resolves it against the connection's
`search_path`, an ordered list of *schemas* (namespaces inside one database) it consults in
turn. Keiro's tables resolve today only because the store connection's `search_path` is set
to `kiroku` — the schema owned by keiro's event-store dependency, kiroku — and the
`keiro_*` tables currently squat inside that `kiroku` schema.

A sibling plan, **EP-1** (`docs/plans/85-rewrite-keiro-migrations-to-own-a-dedicated-keiro-schema-with-qualified-ddl.md`),
moves every `keiro_*` table **out** of `kiroku` and into a brand-new dedicated schema named
`keiro`. The instant EP-1 lands, every bare runtime query in this package breaks at
execution time with `relation "keiro_outbox" does not exist`, because the store connection's
`search_path` still points at `kiroku` (and — as recorded below — cannot be repointed) while
the table now lives in `keiro`.

After this change, every keiro framework runtime query names its tables **schema-qualified**
as `keiro.<table>` (for example `INSERT INTO keiro.keiro_outbox ...`). The runtime no longer
depends on `search_path` at all to find its own tables: each query is self-describing and
resolves correctly regardless of what the connection's `search_path` happens to be. You can
see it working by running keiro's own test suite against a database migrated by EP-1 (tables
in `keiro`): the full suite passes. You can see the *need* for it by reverting a single
query to its bare form against that same database and watching that flow fail with
`relation "..." does not exist`.

This is a purely mechanical, one-time text pass over SQL string literals. There is **no**
logic change: no query is added, removed, or reordered; only the schema prefix `keiro.` is
inserted before each `keiro_*` relation reference.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-07-05): Every `keiro_*` relation reference in the twelve `keiro/src` modules
  qualified `keiro.keiro_<table>` via a keyword-anchored substitution
  (`INSERT INTO|UPDATE|DELETE FROM|FROM|JOIN`). The one Haddock doc-comment occurrence
  (`Timer/Schema.hs:225`) left bare. All `ON CONFLICT` `<table>.<column>` self-references left
  bare. `cabal build keiro` green; fixpoint ripgrep for bare relation refs prints only the doc
  comment; `keiro.keiro_` present in all twelve modules.
- [x] M2 (2026-07-05): Audited cross-library convention — `FROM subscriptions` in
  `keiro/src/Keiro/ReadModel.hs:279` stays bare; no `kiroku.<table>` qualification leaked; the
  two `kiroku.events` mentions are NOTIFY-channel doc comments, not SQL relation refs.
- [x] M2 extension (2026-07-05, discovered): `keiro/test/Main.hs` also issues direct SQL against
  the framework tables (26 DML refs + 5 DDL fault-injection refs using `ALTER TABLE`/`TRUNCATE`).
  These were **not** in the plan's `keiro/src`-only inventory but must be qualified for the suite
  to resolve them post-EP-1. Qualified all of them (relation position only; constraint names and
  `RENAME TO` targets stay bare). Its `streams`/`subscriptions` (kiroku-owned) refs left bare.
- [x] M3 (2026-07-05): `cabal test keiro:test:keiro-test` → 279 examples, 0 failures against the
  EP-1 `keiro`-schema database. Failing-before/passing-after contrast: reverting one
  `FROM keiro.keiro_outbox r` to bare produced 35 examples / 27 failures in the outbox subset;
  restoring qualification returned it to PASS. (The harness wraps the underlying Postgres
  UndefinedTable `relation "keiro_outbox" does not exist` into an `expectationFailure`, so the
  observable signal is the 27→0 failure swing.)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-05: The plan's inventory scoped only `keiro/src`, but `keiro/test/Main.hs` runs its
  own direct SQL against the framework tables — 26 DML references plus 5 DDL fault-injection
  references (`ALTER TABLE keiro_snapshots ADD CONSTRAINT ...`, `TRUNCATE keiro_snapshots`,
  `ALTER TABLE keiro_workflow_steps RENAME TO ...`). Evidence: the first full run after
  qualifying only `keiro/src` was `279 examples, 38 failures`; qualifying the test file's DML
  brought it to `3 failures`; those three were the `ALTER TABLE`/`TRUNCATE` sites (my keyword
  set had `INSERT INTO|UPDATE|DELETE FROM|FROM|JOIN` but not `ALTER TABLE`/`TRUNCATE`, since the
  runtime src has no such DDL). After qualifying those too: `279 examples, 0 failures`. Lesson
  for reviewers: the `keiro.` qualification pass must cover the test suite's own DDL/DML, and
  `ALTER TABLE`/`TRUNCATE` are additional relation-introducing keywords beyond the DML set.
- 2026-07-05: In `ALTER TABLE keiro.keiro_snapshots ADD CONSTRAINT keiro_snapshots_no_writes`
  and `ALTER TABLE keiro.keiro_workflow_steps RENAME TO keiro_workflow_steps_hidden`, only the
  altered relation is schema-qualified; the constraint name and the `RENAME TO` target stay
  bare (Postgres resolves/creates them within the table's own schema), mirroring the
  index/constraint-name rule EP-1 used in the migration DDL.


## Decision Log

Record every decision made while working on the plan.

- Decision: Fully **qualify all keiro runtime queries** as `keiro.<table>` rather than
  reaching the new `keiro` schema by adding it to the store connection's `extraSearchPath`.
  Rationale: Inherited from MasterPlan 12's decision (see
  `docs/masterplans/12-keiro-schema-separation-and-migration-architecture-rework.md`,
  Decision Log, 2026-07-05). Qualification fully decouples the runtime from `search_path`,
  removes a user connection-config footgun, and makes every query self-describing. The cost
  is mechanical and one-time (roughly 100 relation-reference sites across 12 modules) and is
  absorbed entirely by this plan.
  Date: 2026-07-05

- Decision: Leave keiro's references to **kiroku-owned** tables **unqualified** — convention
  (a). Concretely, the single such reference, `FROM subscriptions` in
  `keiro/src/Keiro/ReadModel.hs` (`lookupSubscriptionPositionStmt`), stays bare, and keiro's
  consumption of the `<schema>.events` NOTIFY channel in `keiro/src/Keiro/Wake.hs` is
  untouched.
  Rationale: The store connection's `schema` field stays `kiroku` and drives both kiroku's
  event-store tables and its `<schema>.events` NOTIFY channel, so `subscriptions` continues
  to resolve via the `kiroku` search_path. kiroku owns those names; qualifying them
  `kiroku.<table>` from inside keiro would couple keiro to kiroku's schema-name literal for
  no resolution benefit, whereas the bare name already resolves and keeps working. This is
  the lower-risk default. EP-4 (`docs/plans/88-add-first-class-configurable-projection-and-read-model-schema-support.md`),
  which also reads subscription/store state, must follow this convention.
  Date: 2026-07-05

- Decision: Hardcode the literal `keiro.` prefix inline in each SQL string literal rather
  than splicing a `keiroSchema :: Text` Haskell constant into the query text.
  Rationale: Keiro's runtime SQL is written as GHC 9.12 multiline string literals passed
  whole to a `preparable` helper (they are static compile-time text, not built by
  concatenation). Splicing a constant would force every query to become a `<>`-concatenated
  expression, obscuring the SQL and defeating the "self-describing literal" goal. The schema
  name `keiro` is owned by EP-1; if EP-1 exports a `keiroSchema` constant it remains the
  single source of truth for code that *builds* SQL dynamically (none in this package), but
  the static literals here carry the `keiro.` text directly. This plan hard-depends on EP-1
  for the schema and tables to exist to test against.
  Date: 2026-07-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- 2026-07-05 (completion): Every keiro framework runtime query now names its tables
  `keiro.keiro_<table>`; the runtime no longer relies on `search_path` to find its own tables.
  All twelve `keiro/src` modules were qualified, plus the test suite's direct DML/DDL (an
  in-scope-by-necessity extension the plan's `keiro/src`-only inventory missed). The full
  `keiro-test` suite passes (279 examples, 0 failures) against the EP-1 `keiro`-schema database,
  and the failing-before/passing-after contrast (27 outbox failures with one bare ref, 0 when
  qualified) proves resolution is now schema-directed, not `search_path`-directed. The
  cross-library convention holds: `FROM subscriptions` (kiroku-owned) stays bare, and EP-4 must
  follow it. No public interface changed — only SQL string literals. The change was purely
  mechanical with no logic edits, exactly as scoped.


## Context and Orientation

Read this section as if you know nothing about the repository. The repository root is the
directory containing `keiro/`, `keiro-test-support/`, `keiro-migrations/`, `jitsurei/`, and
`docs/`. All paths below are relative to that root.

**The packages that matter here.** The `keiro` package lives under `keiro/` (its Cabal file
is `keiro/keiro.cabal`, package name `keiro`, version `0.1.0.0`). Its library sources are
under `keiro/src/`, and its single test suite is `keiro-test` (Cabal stanza
`test-suite keiro-test`, `hs-source-dirs: test`, `main-is: Main.hs`, i.e.
`keiro/test/Main.hs`, an `exitcode-stdio-1.0` hspec suite). The `keiro-test-support` package
(`keiro-test-support/src/Keiro/Test/Postgres.hs`) provides the database fixtures the test
suite uses.

**How keiro talks to PostgreSQL.** Keiro runs SQL through the hasql library. Each query is a
`hasql`-`Statement` built by a small helper named `preparable`, which takes a SQL string, an
encoder for the parameters, and a decoder for the result. The SQL strings are written as GHC
9.12 *multiline string literals* — text delimited by triple double-quotes (`"""`). Statements
are executed inside a `hasql` `Tx.Transaction`/`Session` via keiro's `runTransaction`
against a `Kiroku.Store.KirokuStore` connection pool. You do not need to touch any of this
plumbing; you only edit the SQL text inside those `"""` literals.

**What a schema and search_path are.** A PostgreSQL *schema* is a namespace inside one
database; two schemas can each hold a table called `keiro_outbox` and they are distinct
objects. A table can be named two ways in SQL: *bare* (`keiro_outbox`) or *schema-qualified*
(`keiro.keiro_outbox`). A bare name is resolved by searching the connection's `search_path`,
an ordered list of schemas, and using the first schema that contains a matching table. A
qualified name ignores `search_path` and goes straight to the named schema. Keiro's store
connection sets `search_path` to `kiroku, pg_catalog` (this is done once, at pool startup,
by kiroku-store's `initSession`; keiro itself never runs `SET search_path`). Verified: a
sweep for `kiroku.keiro_` and for keiro setting `search_path` returns nothing across the
`.hs` sources — the runtime is already "schema-clean," which is exactly what makes this a
mechanical prefix pass.

**Where the tables live before and after.** Today all eleven framework tables —
`keiro_snapshots`, `keiro_read_models`, `keiro_timers`, `keiro_outbox`, `keiro_inbox`,
`keiro_projection_dedup`, `keiro_workflows`, `keiro_workflow_steps`,
`keiro_workflow_children`, `keiro_awakeables`, `keiro_subscription_shards` — are created by
keiro's migrations inside the `kiroku` schema, so bare runtime queries resolve there. EP-1
(`docs/plans/85-rewrite-keiro-migrations-to-own-a-dedicated-keiro-schema-with-qualified-ddl.md`)
creates a dedicated `keiro` schema and puts every one of these tables in it. This plan makes
the runtime follow the tables. This plan therefore **hard-depends on EP-1**: a query
rewritten to `keiro.keiro_inbox` can only be exercised against a database where the `keiro`
schema and that table exist, which is precisely what EP-1 delivers.

**A hard constraint you must not violate.** The store connection's `schema` field is
`kiroku` and cannot be changed to `keiro`. That field drives both kiroku's own event-store
tables and the `<schema>.events` `LISTEN`/`NOTIFY` channel (default `kiroku.events`) that
keiro's wake mechanism (`keiro/src/Keiro/Wake.hs`) rides via kiroku's dedicated listener
connection. Repointing `schema` to `keiro` would break kiroku's event tables and its NOTIFY
channel. This is exactly why we reach the `keiro` schema by *qualifying* keiro's own queries
(this plan) instead of touching connection settings. The store is opened via kiroku's
`Store.defaultConnectionSettings` at `keiro-test-support/src/Keiro/Test/Postgres.hs` (see
`withFreshStore`, roughly lines 108–123) and `jitsurei/app/Main.hs` (roughly line 541); once
this plan qualifies keiro's own tables, neither call site needs any `search_path` help for
them, and neither is edited by this plan.

**Out of scope.** The `keiro-pgmq` package opens its own connection pool and touches only
`pgmq_*` objects; it references no `keiro_*` table and is not touched here. So is anything
under `keiro-migrations/` (owned by EP-1) and the codd expected-schema snapshot (owned by
EP-3, `docs/plans/87-scope-codd-expected-schema-to-the-keiro-namespace-and-remove-the-role-and-owner-leak.md`).

**The complete inventory of relation references to qualify.** An exhaustive ripgrep sweep of
`keiro/src` for the eleven table tokens, filtered to lines that *reference the relation*
(after `INSERT INTO`, `UPDATE`, `DELETE FROM`, `FROM`, or `JOIN`) rather than lines that
name a *column* of the table or appear only in a doc comment, yields twelve modules. Note
that two of them — `keiro/src/Keiro/Workflow/Instance.hs` and
`keiro/src/Keiro/Workflow/Schema.hs` — were not in the initial hint list and were found only
by sweeping the whole tree; always re-run the sweep yourself rather than trusting any list.
The modules and their relation-reference sites (line numbers approximate; re-verify against
the working tree before editing) are:

- `keiro/src/Keiro/Outbox/Schema.hs` — `keiro_outbox` at 331 (INSERT INTO), 391/401/418/427
  (`SELECT 1 FROM keiro_outbox earlier` subqueries), 442 (`FROM keiro_outbox r`), 466
  (`UPDATE keiro_outbox kt`), 519 (FROM), 528 (DELETE FROM), 540 (FROM), 548/567/585/603/621/642
  (UPDATE), 682 (FROM).
- `keiro/src/Keiro/Inbox/Schema.hs` — `keiro_inbox` at 302 (INSERT INTO), 343/360 (UPDATE),
  378 (INSERT INTO), 441 (FROM), 450 (DELETE FROM), 468 (FROM). Note line 413,
  `attempt_count = keiro_inbox.attempt_count + 1`, is a self-reference inside `ON CONFLICT DO
  UPDATE` — see the gotcha below; it is **not** qualified.
- `keiro/src/Keiro/Snapshot/Schema.hs` — `keiro_snapshots` at 98 (FROM), 116 (INSERT INTO).
  Lines 126–128 (`WHERE keiro_snapshots.stream_version <= EXCLUDED...` etc.) are
  `ON CONFLICT` self-references — **not** qualified.
- `keiro/src/Keiro/ReadModel/Schema.hs` — `keiro_read_models` at 124 (INSERT INTO), 142
  (FROM), 152 (INSERT INTO). Line 160 (`ELSE keiro_read_models.last_built_at`) is an
  `ON CONFLICT` self-reference — **not** qualified.
- `keiro/src/Keiro/Timer/Schema.hs` — `keiro_timers` at 237 (INSERT INTO), 264 (INSERT
  INTO), 286 (FROM), 293 (`UPDATE keiro_timers kt`), 309 (UPDATE), 327/339/356 (FROM),
  372/385/398/411 (UPDATE). Line 248 (`WHERE keiro_timers.status = 'scheduled'`) is an
  `ON CONFLICT` self-reference — **not** qualified.
- `keiro/src/Keiro/Workflow/Gc.hs` — 90 (`FROM keiro_workflows w`), 96 (`FROM
  keiro_workflow_children c`), 97 (`JOIN keiro_workflows p`), 117 (DELETE FROM
  keiro_snapshots), 127 (DELETE FROM keiro_workflow_steps), 140 (DELETE FROM
  keiro_awakeables), 153 (DELETE FROM keiro_workflow_children), 169 (DELETE FROM
  keiro_timers), 186 (DELETE FROM keiro_workflows).
- `keiro/src/Keiro/Workflow/Child/Schema.hs` — `keiro_workflow_children` at 164 (INSERT
  INTO), 182/203/220 (UPDATE), 239/255/271/282 (FROM).
- `keiro/src/Keiro/Workflow/Awakeable/Schema.hs` — `keiro_awakeables` at 124 (INSERT INTO),
  140/159 (UPDATE), 174/185 (FROM).
- `keiro/src/Keiro/Subscription/Shard/Schema.hs` — `keiro_subscription_shards` at 116 (INSERT
  INTO), 133 (FROM), 140 (`UPDATE keiro_subscription_shards s`), 162/182 (UPDATE), 202/214
  (FROM).
- `keiro/src/Keiro/Projection.hs` — `keiro_projection_dedup` at 174 (INSERT INTO), 188
  (DELETE FROM).
- `keiro/src/Keiro/Workflow/Instance.hs` — `keiro_workflows` at 120 (INSERT INTO), 152
  (FROM), 165 (INSERT INTO), 181/205/228/249 (UPDATE). Lines 125/131/132/134
  (`GREATEST(keiro_workflows.generation, ...)`, `COALESCE(keiro_workflows.completed_at,...)`,
  `WHERE keiro_workflows.status NOT IN ...`) are `ON CONFLICT` self-references — **not**
  qualified.
- `keiro/src/Keiro/Workflow/Schema.hs` — 136 (INSERT INTO keiro_workflow_steps), 156/181
  (FROM keiro_workflow_steps), 196 (`SELECT 1 FROM keiro_workflow_steps`), 215 (FROM
  keiro_workflow_steps), 233 (FROM keiro_workflows), 245 (UPDATE keiro_workflows).

**The `ON CONFLICT` self-reference gotcha (critical).** In a statement of the form
`INSERT INTO <table> ... ON CONFLICT (...) DO UPDATE SET ... WHERE <table>.<column> ...`,
the `<table>.<column>` references inside the `SET`/`WHERE` of the `DO UPDATE` clause name
the *conflict target row* using the target table's relation name, and PostgreSQL requires
that name to be the table's own name (or an alias), **not** a schema-qualified name. After
you rewrite the target to `INSERT INTO keiro.keiro_snapshots`, the implicit alias for the
existing row is still the relation name `keiro_snapshots`, so
`WHERE keiro_snapshots.stream_version <= EXCLUDED.stream_version` remains correct and must be
left exactly as-is. Writing `keiro.keiro_snapshots.stream_version` there would be a syntax
error. This is why the inventory above marks those specific lines "not qualified." The rule
is simple: **qualify only the relation reference that immediately follows `INSERT INTO`,
`UPDATE`, `DELETE FROM`, `FROM`, or `JOIN`; never touch a `<table>.<column>` expression.**

**Non-table `keiro_*` tokens that must NOT be changed.** The sweep also surfaces tokens that
look table-ish but are not tables: `keiro_stream_name`, `keiro_retry_attempt`,
`keiro_events_appended`, and `keiro_outbox_batch_size` are OpenTelemetry `AttributeKey`
Haskell identifiers (in `keiro/src/Keiro/Telemetry.hs`, `keiro/src/Keiro/Command.hs`, and
`keiro/src/Keiro/Outbox.hs`); `keiro_workflow_steps_workflow_idx` is an index name mentioned
in a comment; `keiro_shard_rebalance` is a hypothetical NOTIFY channel mentioned in a
comment. None of these are relation references and none are touched.


## Plan of Work

The work is one mechanical concern split into three independently verifiable milestones: do
the qualification pass module by module (M1), pin down and audit the cross-library reference
convention (M2), and prove the qualified runtime works against an EP-1 `keiro`-schema
database with a failing-before/passing-after demonstration (M3).

Because this plan hard-depends on EP-1, do the editing on top of a working tree where EP-1
has landed (its migrations create the `keiro` schema and place the tables there). If you
must start before EP-1 merges, you can still perform all edits and confirm the package
compiles, but the `keiro-test` suite will fail at query-resolution time (the `keiro` schema
will not exist) until EP-1 is present; do not treat that as a defect of this plan.


### Milestone 1 — Qualify every keiro_* relation reference

Scope: rewrite every relation reference to the eleven framework tables, across the twelve
modules inventoried above, from bare `keiro_<table>` to qualified `keiro.keiro_<table>`,
leaving every `ON CONFLICT` self-reference (`<table>.<column>`) and every non-table
`keiro_*` token untouched. At the end of this milestone, a ripgrep for a bare relation
reference returns nothing, the package builds, and only `<table>.<column>` self-references
and comments still contain a bare `keiro_` token.

Work through the modules in this order (grouped for reviewability), editing each SQL literal
in place. The transformation is always the same shape. Below is one representative diff per
statement *shape* so a reader can recognize and apply the pattern everywhere.

A plain `INSERT INTO` with an `ON CONFLICT` self-reference — from
`keiro/src/Keiro/Snapshot/Schema.hs`, `writeSnapshotStmt`. Only the `INSERT INTO` line
changes; the three `WHERE keiro_snapshots.<col>` lines stay bare:

```diff
-        INSERT INTO keiro_snapshots
+        INSERT INTO keiro.keiro_snapshots
           (stream_id, stream_version, state, state_codec_version, regfile_shape_hash)
         VALUES
           ($1, $2, $3, $4, $5)
         ON CONFLICT (stream_id) DO UPDATE
           SET stream_version = EXCLUDED.stream_version,
               ...
           WHERE keiro_snapshots.stream_version <= EXCLUDED.stream_version
              OR keiro_snapshots.state_codec_version <> EXCLUDED.state_codec_version
              OR keiro_snapshots.regfile_shape_hash <> EXCLUDED.regfile_shape_hash
```

A `SELECT ... FROM` (with or without an alias) — from `keiro/src/Keiro/Snapshot/Schema.hs`,
`lookupSnapshotStmt`:

```diff
         SELECT stream_id, stream_version, state, ...
-        FROM keiro_snapshots
+        FROM keiro.keiro_snapshots
         WHERE stream_id = $1
```

A `DELETE FROM` — from `keiro/src/Keiro/Workflow/Gc.hs`, `deleteSnapshotStmt`:

```diff
-        DELETE FROM keiro_snapshots
+        DELETE FROM keiro.keiro_snapshots
         WHERE stream_id = $1
```

An aliased `UPDATE ... FROM` CTE (the alias stays on the qualified name; `kt.<col>`
references are unchanged) — from `keiro/src/Keiro/Timer/Schema.hs`, the claim statement:

```diff
         WITH due AS (
           SELECT timer_id
-          FROM keiro_timers
+          FROM keiro.keiro_timers
           WHERE status = 'scheduled'
             AND fire_at <= $1
           ORDER BY fire_at, timer_id
           LIMIT 1
           FOR UPDATE SKIP LOCKED
         )
-        UPDATE keiro_timers kt
+        UPDATE keiro.keiro_timers kt
         SET status = 'firing',
             attempts = kt.attempts + 1,
             updated_at = now()
         FROM due
         WHERE kt.timer_id = due.timer_id
```

A multi-table statement with a `JOIN` and a correlated subquery — from
`keiro/src/Keiro/Workflow/Gc.hs`, `eligibleWorkflowsStmt` (every relation reference is
qualified; aliases `w`, `c`, `p` and their `<alias>.<col>` uses are unchanged):

```diff
         SELECT w.workflow_id, w.workflow_name
-        FROM keiro_workflows w
+        FROM keiro.keiro_workflows w
         WHERE w.status IN ('completed', 'cancelled', 'failed')
           ...
           AND NOT EXISTS (
             SELECT 1
-            FROM keiro_workflow_children c
-            JOIN keiro_workflows p
+            FROM keiro.keiro_workflow_children c
+            JOIN keiro.keiro_workflows p
               ON p.workflow_id = c.parent_id
              ...
           )
```

Apply the same pattern to the remaining sites:
`keiro/src/Keiro/Outbox/Schema.hs` (including the four `SELECT 1 FROM keiro_outbox earlier`
self-join subqueries, which become `FROM keiro.keiro_outbox earlier`),
`keiro/src/Keiro/Inbox/Schema.hs`, `keiro/src/Keiro/ReadModel/Schema.hs`,
`keiro/src/Keiro/Workflow/Child/Schema.hs`, `keiro/src/Keiro/Workflow/Awakeable/Schema.hs`,
`keiro/src/Keiro/Subscription/Shard/Schema.hs` (the aliased
`UPDATE keiro.keiro_subscription_shards s` claim statement), `keiro/src/Keiro/Projection.hs`,
`keiro/src/Keiro/Workflow/Instance.hs`, and `keiro/src/Keiro/Workflow/Schema.hs`.

Acceptance for M1: `cabal build keiro` succeeds, and the verification ripgrep in Concrete
Steps shows zero bare relation references (only `<table>.<column>` self-references and
comments remain).


### Milestone 2 — Fix and audit the cross-library reference convention

Scope: state the convention for keiro's references to *kiroku-owned* tables and prove keiro
holds to it. There is exactly one such reference in runtime SQL — `FROM subscriptions` in
`keiro/src/Keiro/ReadModel.hs` (`lookupSubscriptionPositionStmt`, roughly line 279) — plus
keiro's use of the `<schema>.events` NOTIFY channel in `keiro/src/Keiro/Wake.hs`, which is
not a SQL relation reference at all (keiro consumes kiroku's channel through kiroku's
listener).

Work: leave `FROM subscriptions` **bare** (convention (a), recorded in the Decision Log).
The store connection's `schema` field stays `kiroku`, so `subscriptions` — a kiroku-owned
table — continues to resolve via the `kiroku` search_path. Do not qualify it `kiroku.
subscriptions`; kiroku owns that name and the bare form already resolves. This milestone is
mostly a guard: after M1, audit that no kiroku-owned table (`subscriptions`, `events`,
`streams`, `stream_events`, `dead_letters`) was accidentally schema-qualified, and that no
`keiro.` prefix leaked onto a non-`keiro_` name.

Acceptance for M2: the audit ripgrep in Concrete Steps finds no `kiroku.`-qualified or
`keiro.`-misqualified kiroku table, and `keiro/src/Keiro/ReadModel.hs` still reads
`FROM subscriptions`. The convention is documented in this plan's Decision Log for EP-4 to
follow.


### Milestone 3 — Prove the qualified runtime works against the keiro schema

Scope: demonstrate, against a database migrated by EP-1 (framework tables in the `keiro`
schema), that the qualified runtime works end to end, and that qualification is what makes
it work.

Work: run keiro's full test suite, `cabal test keiro:test:keiro-test`. That suite opens a
migrated store via `keiro-test-support`'s `withFreshStore`/`withMigratedSuite` fixtures and
exercises every table group through real transactions: `Keiro.Command` and
`Keiro.Snapshot` (snapshots), `Keiro.ReadModel` (read-model registry plus the kiroku
`subscriptions` read), `Keiro.Timer` (timers), `Keiro.Outbox` and `Keiro.Inbox`,
`Keiro.Workflow` and its instance/step/child/awakeable/GC paths, `Keiro.ProcessManager`,
the shard-lease and sharded-subscription suites (`keiro_subscription_shards`), and
`Keiro.Wake`. With EP-1 and M1 both in place, the suite passes.

Then show the failing-before/passing-after contrast on one flow. The cleanest demonstration
uses the EP-1 database (tables in `keiro`) and toggles a single query: temporarily revert
one qualified reference back to bare — for example change `FROM keiro.keiro_outbox` back to
`FROM keiro_outbox` in `keiro/src/Keiro/Outbox/Schema.hs` — and re-run the outbox portion of
the suite. Because the store's `search_path` is `kiroku` but the table now lives in `keiro`,
the bare query fails at execution with `relation "keiro_outbox" does not exist`. Restore the
`keiro.` prefix and the same flow passes. (An equivalent contrast: point the query at the
wrong schema, `FROM kiroku.keiro_outbox`, and observe the same `does not exist` error,
proving resolution is now schema-directed rather than `search_path`-directed.)

Acceptance for M3: `cabal test keiro:test:keiro-test` reports all examples passing against
the EP-1 schema; the temporary bare-revert produces `relation "keiro_outbox" does not exist`
and restoring qualification makes it pass again.


## Concrete Steps

Run all commands from the repository root (the directory containing `keiro/`). The toolchain
is `cabal` with GHC 9.12; the test suite uses ephemeral-pg (`Pg.withCached`) to spin up a
PostgreSQL 18 cluster automatically, so no external database is required.

Before editing, list every relation reference so you can check each one off. This is the
authoritative sweep; re-run it rather than trusting the inventory above:

```bash
rg -n --no-heading -w \
  'keiro_outbox|keiro_inbox|keiro_snapshots|keiro_read_models|keiro_timers|keiro_workflows|keiro_workflow_children|keiro_workflow_steps|keiro_awakeables|keiro_subscription_shards|keiro_projection_dedup' \
  keiro/src -g '*.hs'
```

Expected: roughly one hundred lines across the twelve modules named in Context and
Orientation, a mix of relation references (to qualify) and `<table>.<column>` self-references
and doc comments (to leave alone).

After completing the M1 edits, verify no bare relation reference remains. The following
ripgrep matches the SQL keywords that introduce a relation, followed by a bare `keiro_`
name; after M1 it must print nothing:

```bash
rg -n --no-heading -iP '\b(INSERT INTO|UPDATE|DELETE FROM|FROM|JOIN)\s+keiro_[a-z_]+' \
  keiro/src -g '*.hs'
```

Expected output after M1:

```text
```

(That is, empty — every such site now reads `... keiro.keiro_<table>`.) As a positive
check, confirm the qualified form is present:

```bash
rg -c 'keiro\.keiro_' keiro/src -g '*.hs'
```

Expected: each of the twelve modules reports a non-zero count.

For the M2 audit, confirm no kiroku-owned table was qualified and the subscriptions read is
still bare:

```bash
rg -n --no-heading -iP '\bkiroku\.(subscriptions|events|streams|stream_events|dead_letters)\b' keiro/src -g '*.hs'
rg -n --no-heading 'FROM subscriptions' keiro/src/Keiro/ReadModel.hs
```

Expected: the first command prints nothing; the second prints the single
`lookupSubscriptionPositionStmt` line.

Build and test (M1/M3). This requires EP-1 to have landed so the `keiro` schema exists:

```bash
cabal build keiro
cabal test keiro:test:keiro-test
```

Expected tail of the test transcript:

```text
Finished in N seconds
NNN examples, 0 failures
```

To perform the failing-before/passing-after demonstration for M3, temporarily edit one
reference in `keiro/src/Keiro/Outbox/Schema.hs` from `keiro.keiro_outbox` back to
`keiro_outbox`, then run only the outbox examples:

```bash
cabal test keiro:test:keiro-test --test-options='--match "Keiro.Outbox"'
```

Expected while reverted (tables live in `keiro`, search_path is `kiroku`):

```text
relation "keiro_outbox" does not exist
... (Keiro.Outbox examples fail)
```

Restore the `keiro.` prefix and re-run the same command; the outbox examples pass.


## Validation and Acceptance

The behavior to observe is that keiro's runtime finds its tables in the `keiro` schema with
no reliance on `search_path`, demonstrated by the full `keiro-test` suite passing against an
EP-1-migrated database and by the bare-revert of any single query failing with
`relation "<table>" does not exist` on that same database.

Acceptance is met when all of the following hold: (1) `cabal build keiro` succeeds; (2) the
M1 verification ripgrep for a bare relation reference prints nothing while `keiro.keiro_`
appears in all twelve modules; (3) the M2 audit shows no kiroku table qualified and
`keiro/src/Keiro/ReadModel.hs` still reads `FROM subscriptions`; (4)
`cabal test keiro:test:keiro-test` reports zero failures; and (5) the failing-before/
passing-after contrast on the outbox flow behaves as described (bare form errors with
`relation "keiro_outbox" does not exist`; qualified form passes).

This proves the change is effective beyond compilation: the suite executes real
transactions against real tables that, post-EP-1, exist only in the `keiro` schema, so a
passing run is only possible because the queries name that schema.


## Idempotence and Recovery

Every edit is a pure text substitution in a SQL string literal; nothing is stateful and no
migration or destructive database operation is involved. Re-running the qualification pass is
safe: applying `keiro.` to an already-qualified `keiro.keiro_<table>` is prevented by
matching only bare occurrences, and the verification ripgrep is the fixpoint check — when it
prints nothing, the pass is complete and further runs are no-ops. If a build fails after
editing, the likely cause is a mistakenly qualified `ON CONFLICT` self-reference
(`keiro.keiro_x.col`) or a qualified non-table token; grep for `keiro\.keiro_[a-z_]+\.`
(a schema-qualified name immediately followed by a column) to find and revert such mistakes,
since a correct relation reference is never immediately followed by `.<column>`.

The demonstration edit in M3 (reverting one reference to bare) is temporary; recover by
restoring the `keiro.` prefix, which the verification ripgrep will confirm. Because tests
run on ephemeral, per-example databases (`withFreshStore` clones a fresh migrated database
and drops it afterward), no test run leaves any residue to clean up.

Rollback of the whole plan is a `git revert` of its commit; there is no data or schema state
to unwind, because this plan changes only Haskell SQL string literals.


## Interfaces and Dependencies

This plan edits only SQL string literals inside `preparable` statements in the `keiro`
package library (`keiro/src/`). It introduces no new modules, types, or function signatures,
and changes no public interface: the exported statement builders keep their existing types
(for example `writeSnapshotStmt :: Statement (Int64, Int64, Value, Int64, Text) ()` in
`keiro/src/Keiro/Snapshot/Schema.hs`), and their behavior is unchanged except for which
schema resolves their tables.

Hard dependency: **EP-1**
(`docs/plans/85-rewrite-keiro-migrations-to-own-a-dedicated-keiro-schema-with-qualified-ddl.md`).
The `keiro` schema and the relocated `keiro_*` tables must exist for the qualified queries to
resolve and for the `keiro-test` suite to pass. EP-1 is the single source of truth for the
schema name `keiro`; this plan qualifies against that exact literal. If EP-1 exports a
`keiroSchema :: Text` constant, code that *builds* SQL dynamically should import it — but the
static multiline SQL literals in this package carry the `keiro.` text inline (see Decision
Log) and are not affected.

Downstream dependency: **EP-4**
(`docs/plans/88-add-first-class-configurable-projection-and-read-model-schema-support.md`)
must follow the cross-library reference convention this plan owns: keiro references to
kiroku-owned tables (notably `subscriptions`) stay **bare**, resolving via the store's
`schema = "kiroku"` search_path. EP-4 also reuses the qualification idiom established here for
keiro's own tables.

Fixed constraint (not changed by this plan): the store connection's `schema` field stays
`kiroku`. It drives kiroku's event-store tables and the `<schema>.events` NOTIFY channel and
cannot be repointed to `keiro`. The store is opened via `Store.defaultConnectionSettings` in
`keiro-test-support/src/Keiro/Test/Postgres.hs` and `jitsurei/app/Main.hs`; neither call site
is edited here, because qualifying keiro's own queries removes their dependence on
`search_path` entirely.

Libraries in play (all already dependencies of `keiro`): `hasql`, `hasql-transaction`, and
`hasql-pool` for statement execution; `kiroku-store` for the connection pool and its
`initSession`-set `search_path`; and, in the test suite, `keiro-test-support`, `hspec`, and
ephemeral-pg for the migrated-database fixtures.

Every implementation commit for this plan must carry these trailers (Conventional Commits
subject, then a blank line, then the trailers):

```text
MasterPlan: docs/masterplans/12-keiro-schema-separation-and-migration-architecture-rework.md
ExecPlan: docs/plans/86-qualify-all-keiro-framework-runtime-queries-with-the-keiro-schema.md
Intention: intention_01kwsrmsbsedqb0rh0vb41x04m
```
