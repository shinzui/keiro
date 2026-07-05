---
id: 88
slug: add-first-class-configurable-projection-and-read-model-schema-support
title: "Add first-class configurable projection and read-model schema support"
kind: exec-plan
created_at: 2026-07-05T18:39:13Z
intention: "intention_01kwsrmsbsedqb0rh0vb41x04m"
master_plan: "docs/masterplans/12-keiro-schema-separation-and-migration-architecture-rework.md"
---

# Add first-class configurable projection and read-model schema support

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Keiro is an event-sourcing framework written in Haskell. It sits on top of a separate
event-store library called **kiroku**. A *read model* is a query-optimized table that
Keiro (via the application's code) keeps up to date from the event log; a *projection* is
the code that folds each event into that read-model table. Today an application that wants
a read-model table has **no first-class way to say which PostgreSQL schema that table lives
in**. (A PostgreSQL *schema* is a namespace inside one database — like a folder for tables;
an unqualified name such as `orders_summary` is resolved against the connection's
*search_path*, an ordered list of schemas the server tries in turn.) Because Keiro opens
its database pool through kiroku's connection settings, whose `search_path` starts with the
event store's private schema (named `kiroku` by default), an application that naively runs
`CREATE TABLE jitsurei_order_summary (...)` unqualified **lands its read-model table inside
the `kiroku` event-store schema**, co-mingling application data with the event store's own
tables. The user asked directly: "where should projections live? does it support users
creating a schema for projections and configuring that?" The answer today is *no*.

After this change the answer is *yes*. An application declares the schema its read-model
tables live in as a first-class field on its `ReadModel` value, Keiro gives it a small,
well-defined helper set to qualify its projection SQL against that schema and to wire the
database connection so the schema resolves, and Keiro's own framework metadata continues to
live in Keiro's dedicated `keiro` schema — cleanly separated from both the application's
projection data and from kiroku's event store. You can see it working by running the
jitsurei worked example (`cabal test jitsurei-test` and `cabal run jitsurei-demo`) and
observing that its `jitsurei_order_summary` table is created in a user-chosen `jitsurei`
schema, not in `kiroku`, while reads and writes still succeed end to end; and by a new Keiro
test that places a read-model table in an arbitrary configured schema, reads and writes it,
and asserts with a catalog query that the table is in that schema while `keiro_read_models`
(Keiro's own metadata) is in `keiro`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-07-05): New module `Keiro.Connection` exports `qualifyTable`, `quoteIdentifier`,
      `withProjectionSchema`, `keiroConnectionSettings`, and `ensureProjectionSchema`; wired into
      `keiro.cabal`. (`quoteIdentifier` added to exports so applications can build a
      `CREATE SCHEMA "<name>"` cleanly.)
- [x] M1 (2026-07-05): `ReadModel` gained `schema :: !Text`; `qualifiedTableName` added to and
      exported from `Keiro.ReadModel` (imports `qualifyTable` from `Keiro.Connection`);
      `ensureReadModel` annotated that `schema` is deliberately not persisted. All five
      `ReadModel` constructions repo-wide updated (2 in `keiro/test`, `jitsurei` OncallRoster /
      AgentQualRouter set to `"kiroku"` = status quo, orderSummary migrated in M3).
- [x] M2 (2026-07-05): `keiro-test-support` gained `withFreshStoreWith fixture modify action`;
      `withFreshStore = \fixture -> withFreshStoreWith fixture id`. Builds clean.
- [x] M3 (2026-07-05): jitsurei order-summary moved to the user-configured `jitsurei` schema —
      `jitsureiProjectionSchema`/`orderSummaryTable` added, all DDL/DML qualified
      (`jitsurei.jitsurei_order_summary`), `schema` field set, `withJitsureiStore` wired via
      `keiroConnectionSettings`, two order-summary test blocks switched to
      `withFreshStoreWith … (withProjectionSchema jitsureiProjectionSchema)`. Also qualified 3
      bare Keiro-framework-table inspection queries in the jitsurei app/test
      (`keiro.keiro_snapshots`/`keiro.keiro_timers`) that EP-1 broke. `cabal test jitsurei-test`
      → 16 examples, 0 failures.
- [x] M4 (2026-07-05): New keiro-test example "places a read-model table in a configured schema,
      separate from keiro metadata" — `app_reads.placed_counter` created via
      `ensureProjectionSchema` + qualified DDL, written by an inline projection, read via
      `runQuery`, with `pg_tables` assertions: table in `app_reads` (1), absent from `kiroku`
      (0), `keiro_read_models` in `keiro` (1). Full `keiro-test` PASS; `keiro-migrations-test`
      unchanged/PASS (no migration introduced; expected-schema snapshot untouched).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-05: `preparable` takes SQL as `Text` (hasql 1.10), but `Hasql.Transaction.sql` takes
  `ByteString`. So statement SQL can interpolate a `Text` qualified-table name directly (via
  `<>`, replacing the `MultilineStrings` literals), while `Tx.sql` DDL must be wrapped in
  `Data.Text.Encoding.encodeUtf8`. Both patterns are used (statements interpolate directly;
  `initializeOrderSummaryTable`/`initializePlacedTable` encode).
- 2026-07-05: Adding a required `schema` field to `ReadModel` forced updating **all five**
  `ReadModel` constructions repo-wide, not just the two `keiro/test` ones the plan named:
  jitsurei's `serviceOncallReadModel` (OncallRoster) and `areaChaptersReadModel`
  (AgentQualRouter) also construct `ReadModel`. Their `schema` field is inert (their SQL is
  bare and nothing calls `qualifiedTableName` on them), so they were set to `"kiroku"` to
  reflect where their unqualified tables actually land — see Decision Log. Only the
  order-summary read model was fully migrated to the `jitsurei` schema, matching the plan's and
  the MasterPlan vision's explicit scope (`jitsurei_order_summary`).
- 2026-07-05: The jitsurei example (both `jitsurei/app/Main.hs` and `jitsurei/test/Main.hs`)
  runs its own inspection queries against Keiro framework tables (`FROM keiro_snapshots`,
  `FROM keiro_timers`) with **bare** names. EP-1 moved those tables into the `keiro` schema, so
  these broke (`jitsurei-test`: "Jitsurei snapshots" example failed with a pattern-match on a
  `does-not-exist` error). EP-2 scoped its qualification to the `keiro` package + its test, not
  the separate `jitsurei` package, so EP-4 (which owns the jitsurei example) qualified them to
  `keiro.keiro_snapshots`/`keiro.keiro_timers` using EP-2's convention. Evidence: after
  qualifying, `jitsurei-test` went 16/16. **For EP-5:** any docs/example touching Keiro
  framework tables directly must qualify them `keiro.<table>`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Declare the projection schema as a new `schema :: !Text` field on `ReadModel`
  **only**, not on `InlineProjection` or `AsyncProjection`.
  Rationale: `ReadModel` is the only one of the three types that already names a single
  target table (`tableName`), so pairing a schema with it is natural and lets Keiro offer a
  `qualifiedTableName` helper. `InlineProjection`/`AsyncProjection` are opaque `apply`
  closures with no `tableName` field and may touch several tables, so a single `schema`
  field there would be ambiguous and unused by Keiro. Decisively: adding a *required* record
  field to `InlineProjection`/`AsyncProjection` would break every keiro-dsl generated
  `Projection.hs` (for example
  `keiro-dsl/test/conformance/Generated/HospitalCapacity/Reservation/Projection.hs`) **and**
  force a change to the code generator at `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (around line
  1135), pulling the whole keiro-dsl package into this plan's blast radius for no functional
  gain. Projections qualify their SQL through the same application-level schema value plus
  Keiro's `qualifyTable` helper. Considered adding the field to all three for symmetry;
  rejected on scope and meaninglessness grounds.
  Date: 2026-07-05

- Decision: Reach the application's projection schema by **fully qualifying** the
  application's projection DDL/DML (`schema.table`) as the primary mechanism, with a
  connection helper that appends the schema to kiroku's `extraSearchPath` as an optional
  convenience.
  Rationale: This mirrors the qualification idiom EP-2 (docs/plans/86) establishes for
  Keiro's own framework tables, so applications and the framework share one style rather than
  two. Full qualification makes the read/write correct regardless of `search_path`, which is
  the robust default; the `extraSearchPath` helper additionally lets applications that prefer
  unqualified data-manipulation SQL keep working on the store pool. Keiro provides
  `qualifyTable`, `qualifiedTableName`, `keiroConnectionSettings`, and `withProjectionSchema`
  so there is exactly one convention.
  Date: 2026-07-05

- Decision: Keiro does **not** auto-create the application's projection schema in
  production; it ships an opt-in `ensureProjectionSchema` helper for development, tests, and
  worked examples.
  Rationale: In production, database DDL is owned by the application's migrations, not
  silently issued by a framework at runtime. An opt-in `CREATE SCHEMA IF NOT EXISTS` helper
  covers the ergonomic dev/test/example path without making Keiro a hidden schema author.
  Date: 2026-07-05

- Decision: Store the projection schema as **Haskell-level configuration only** — a field on
  `ReadModel` and a connection setting — and do **not** persist it as a column on the
  `keiro_read_models` metadata table.
  Rationale: The schema is a deployment/wiring concern, not part of a read model's *schema
  identity* (which is `version` and `shapeHash`, used for drift detection). Keiro's metadata
  queries key on `name` and never need to know where the application's data table lives.
  Persisting it would require a new forward migration in EP-1's (docs/plans/85) format plus a
  regeneration of EP-3's (docs/plans/87) codd expected-schema snapshot — coupling this plan
  to two others for no benefit. If schema drift detection on the projection location is ever
  wanted, that is the point to add a column, and it must then be flagged to EP-1 and EP-3.
  Date: 2026-07-05

- Decision (surfaced during implementation): Only the jitsurei order-summary read model is
  migrated to the `jitsurei` projection schema; the other two jitsurei read models
  (`serviceOncallReadModel`, `areaChaptersReadModel`) keep their unqualified DDL/DML and are
  given `schema = "kiroku"` to reflect where they actually land.
  Rationale: The plan's M3 and the MasterPlan vision both scope the migration to
  `jitsurei_order_summary`. Those two read models power separate paging/routing demos with
  their own init/test paths; their `schema` field is inert (SQL is bare; `qualifiedTableName`
  is never called on them). Fully migrating them would expand scope for no functional gain.
  Setting `schema = "kiroku"` is the honest status quo (an unqualified `CREATE TABLE` lands in
  the store search_path's first schema, `kiroku`) and mirrors what the two keiro-test read
  models do. Recorded so EP-5 documents the order-summary migration as the worked example.
  Date: 2026-07-05

- Decision (surfaced during implementation): Export `quoteIdentifier` from `Keiro.Connection`
  alongside `qualifyTable`.
  Rationale: Applications building an opt-in `CREATE SCHEMA "<name>"` (as the jitsurei
  `initializeOrderSummaryTable` does) need to quote a single identifier, not a `schema.table`
  pair. Exposing the same quoting helper Keiro uses internally keeps one convention and avoids
  every app re-implementing identifier quoting. `ensureProjectionSchema` remains the preferred
  Eff-level path; `quoteIdentifier` covers the `Tx.Transaction`-level DDL case.
  Date: 2026-07-05

- Decision: The kiroku store connection's `schema` field stays `kiroku` and is never
  repointed to reach the projection schema.
  Rationale: kiroku's `schema` field drives both the event-store tables *and* the
  `<schema>.events` `LISTEN`/`NOTIFY` channel (a PostgreSQL publish/subscribe channel used to
  wake subscription workers), so changing it would silently break notifications. The
  projection schema is reached by qualification and/or `extraSearchPath`, never by changing
  `schema`. This is a hard constraint recorded in the MasterPlan's Integration Points.
  Date: 2026-07-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- 2026-07-05 (completion): The feature is delivered. An application now declares its read-model
  data schema as a first-class `ReadModel.schema` field, qualifies its SQL through
  `Keiro.Connection.qualifyTable`/`qualifiedTableName`, wires the store via
  `keiroConnectionSettings`/`withProjectionSchema`, and can opt into schema creation with
  `ensureProjectionSchema`. The jitsurei worked example places `jitsurei.jitsurei_order_summary`
  in a user-chosen `jitsurei` schema (not `kiroku`) and runs end to end (`jitsurei-test` 16/16).
  A dedicated keiro-test proves an arbitrary configured schema (`app_reads`) holds the app table
  while `kiroku` does not and Keiro's `keiro_read_models` metadata stays in `keiro`. No database
  migration was introduced — the schema is Haskell-level config only — so `keiro-migrations-test`
  is unchanged and EP-3's codd snapshot needed no regeneration (confirmed: `git status` on
  `keiro-migrations/expected-schema` is clean).
- Gaps/notes: two secondary jitsurei read models remain unqualified in `kiroku` by design
  (scope decision above); if a future change wants the whole example off `kiroku`, migrate them
  the same way. **For EP-5:** the stable public names to document are `Keiro.Connection`'s
  `qualifyTable`, `quoteIdentifier`, `withProjectionSchema`, `keiroConnectionSettings`,
  `ensureProjectionSchema`, plus `ReadModel.schema`/`qualifiedTableName` and
  `keiro-test-support`'s `withFreshStoreWith`.


## Context and Orientation

This section assumes no prior knowledge of the repository. The repository root is the
directory that contains `keiro/`, `jitsurei/`, `keiro-test-support/`, `keiro-migrations/`,
`keiro-dsl/`, and `docs/`. All paths below are relative to that root.

**The libraries and how they layer.** kiroku is the event store; it owns a private
PostgreSQL schema named `kiroku` (holding tables `streams`, `events`, `stream_events`,
`subscriptions`, `dead_letters`) and a `kiroku.events` `LISTEN`/`NOTIFY` channel. Keiro is
the framework built on top; the sibling ExecPlans in this MasterPlan give Keiro its own
dedicated schema named `keiro` for its framework tables (`keiro_read_models`,
`keiro_projection_dedup`, `keiro_snapshots`, `keiro_timers`, and so on). The application
(the worked example is `jitsurei`) sits on top of Keiro and owns its read-model tables.
This plan concerns **the third layer**: where the application's read-model/projection tables
live, and how the application declares and reaches that location.

**Key terms in plain language.**

- *Schema* (PostgreSQL): a namespace of tables inside one database. `a.t` names table `t`
  in schema `a`. This is unrelated to a Haskell type "schema."
- *search_path*: an ordered list of schemas the server consults when a table name is written
  *unqualified* (no `schema.` prefix). An unqualified `CREATE TABLE` always creates the table
  in the **first** schema on the search_path (never a later one). An unqualified `SELECT`
  resolves against the first schema that contains a matching table.
- *Qualified* name: `schema.table`, which ignores search_path entirely.
- *Read model*: a query-optimized table derived from the event log, plus the query that
  reads it. In Keiro it is the `ReadModel` record.
- *Projection*: the code that folds each event into a read-model table. Keiro has two
  flavors — an `InlineProjection` runs in the same database transaction as the command that
  produced the event (strongly consistent), and an `AsyncProjection` runs later from a
  subscription worker draining the log (eventually consistent).

**The types as they exist today (before this plan).** In
`keiro/src/Keiro/ReadModel.hs`:

```haskell
data ReadModel q r = ReadModel
    { name :: !Text
    , tableName :: !Text
    , subscriptionName :: !Text
    , version :: !Int
    , shapeHash :: !Text
    , defaultConsistency :: !ConsistencyMode
    , query :: !(q -> Tx.Transaction r)
    }
```

There is **no `schema` field**. Note that `query` is an application-supplied
`Hasql.Transaction.Transaction` action: the application writes its own SQL against whatever
table name it chooses. Keiro never generates SQL from `tableName`; the field is purely
documentary today. This matters: Keiro cannot rewrite the application's SQL to inject a
schema — the application must qualify its own SQL. Keiro's job is therefore to (i) give the
application a single, first-class place to *declare* the schema, (ii) give it a shared helper
to *qualify* its SQL, and (iii) make the schema *resolvable* on the store's connection pool.

In `keiro/src/Keiro/Projection.hs`:

```haskell
data InlineProjection co = InlineProjection
    { name :: !Text
    , apply :: !(co -> RecordedEvent -> Tx.Transaction ())
    }

data AsyncProjection = AsyncProjection
    { name :: !Text
    , subscriptionName :: !Text
    , applyRecorded :: !(RecordedEvent -> Tx.Transaction ())
    , idempotencyKey :: !(RecordedEvent -> EventId)
    }
```

Both `apply`/`applyRecorded` are again application-supplied `Transaction` actions. Keiro's
`runCommandWithProjections` (same file) runs a command and applies the inline projections in
the append transaction; `applyAsyncProjection` inserts the event's idempotency key into
`keiro_projection_dedup` and, if newly inserted, runs `applyRecorded`. **Neither type names a
table, and neither is used by Keiro to build application SQL.**

**Keiro's own metadata is separate.** `keiro/src/Keiro/ReadModel/Schema.hs` holds the
`keiro_read_models` registry (columns `name`, `version`, `shape_hash`, `last_built_at`,
`status`, `updated_at`) via `registerReadModel`/`lookupReadModel`/`markLive`/etc.
`keiro/src/Keiro/Projection.hs` writes `keiro_projection_dedup`. Those tables are Keiro
framework tables: EP-1 (docs/plans/85) places them in the `keiro` schema and EP-2
(docs/plans/86) qualifies their runtime queries as `keiro.keiro_read_models` and
`keiro.keiro_projection_dedup`. **The configurable schema this plan adds is for the
application's read-model *data* tables only, never for these framework metadata tables.**
Keep that distinction crystal clear: `registerReadModel` and friends never read the new
`schema` field.

**The store connection.** kiroku's
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Connection.hs`
defines:

```haskell
data ConnectionSettingsM m = ConnectionSettings
    { connString :: !Text
    , poolSize :: !Int
    , schema :: !Text            -- default "kiroku"; ALSO drives the <schema>.events NOTIFY channel
    , extraSearchPath :: ![Text] -- default []; appended AFTER schema, before pg_catalog
    , ...
    }

defaultConnectionSettings :: Text -> ConnectionSettings   -- schema = "kiroku", extraSearchPath = []
```

Every pooled connection runs, once, `SET search_path TO "<schema>"[, "<extra>"...], pg_catalog`.
Two facts from that file drive this plan's design:

1. The `schema` field cannot be repointed away from `kiroku`: its Haddock states it is
   authoritative for both table resolution **and** the `LISTEN <schema>.events` notification
   channel. Changing it would break notifications. (Confirmed in the file's comments and in
   the MasterPlan Surprises log.)
2. `extraSearchPath` lets a pool *resolve* (read/write) application tables that live in
   another schema, but — because an unqualified `CREATE TABLE` lands in the **first**
   search_path entry (always `kiroku`) — it does **not** make an unqualified `CREATE TABLE`
   land in an `extraSearchPath` schema. Its own Haddock says exactly this: it is "for
   consumers whose application objects — typically inline projections' read-model tables,
   queried on the same pool as the event store — live in another schema."

The consequence: to place a read-model table in schema `X`, the application must qualify at
least its `CREATE TABLE` as `X.table` (an unqualified create would land in `kiroku`).
Qualifying the read/write SQL too makes everything correct independent of `search_path`,
which is why full qualification is this plan's primary mechanism.

**The worked example today.** `jitsurei/src/Jitsurei/ReadModels.hs` defines
`orderSummaryReadModel` with `tableName = "jitsurei_order_summary"`,
`orderSummaryInlineProjection`, and `initializeOrderSummaryTable`, which runs an
**unqualified** `CREATE TABLE IF NOT EXISTS jitsurei_order_summary (...)`. All its statements
(`upsertOrderSummaryStmt`, `updateOrderSummaryStatusStmt`, `selectOrderSummaryStmt`) name
`jitsurei_order_summary` unqualified. `jitsurei/src/Jitsurei/Database.hs`
(`initializeJitsureiTables`) runs `initializeOrderSummaryTable` in a transaction.
`jitsurei/app/Main.hs` opens the store at `withJitsureiStore` (around line 537) with
`Store.withStore (Store.defaultConnectionSettings connString) action`.
`jitsurei/src/Jitsurei/FulfillmentProcess.hs` (around line 130) wires
`targetProjections = const [orderSummaryInlineProjection]`. Because the store's search_path
starts at `kiroku`, `jitsurei_order_summary` is created **in `kiroku`** today — the exact
co-mingling this plan fixes.

**The test fixture.** `keiro-test-support/src/Keiro/Test/Postgres.hs` provides
`withMigratedSuite`/`withMigratedSuiteWith` (start one PostgreSQL server, migrate a template
database once) and `withFreshStore`/`withFreshDatabase` (clone a fresh database per example,
open a store). `withFreshStore` hardcodes `Store.defaultConnectionSettings connStr`; there is
no variant that customizes connection settings, so there is currently no way for a test to
add a projection schema to `extraSearchPath`. `withMigratedSuiteWith` accepts an extra
template-migration hook; `withFreshDatabase` exposes the raw connection string.

**Sibling plans (checked in) and how this plan depends on them.** This plan is EP-4 of the
MasterPlan at `docs/masterplans/12-keiro-schema-separation-and-migration-architecture-rework.md`.

- EP-1 (`docs/plans/85-rewrite-keiro-migrations-to-own-a-dedicated-keiro-schema-with-qualified-ddl.md`):
  creates the `keiro` schema and puts `keiro_read_models`, `keiro_projection_dedup`, etc.
  into it via qualified migrations. **Hard dependency**: this plan needs the `keiro` schema
  and those tables to exist to run its tests. EP-1 also decides where a `keiroSchema :: Text`
  constant lives, if any; this plan does not need that constant (the *application's* schema is
  independent of Keiro's own `keiro` schema).
- EP-2 (`docs/plans/86-qualify-all-keiro-framework-runtime-queries-with-the-keiro-schema.md`):
  qualifies Keiro's framework runtime queries as `keiro.<table>` and documents the convention
  for cross-library references (kiroku-owned tables such as `subscriptions`). **Soft
  dependency**: this plan reuses EP-2's qualification idiom rather than inventing a second
  style, and assumes EP-2 has qualified `keiro_read_models`/`keiro_projection_dedup` so those
  resolve without `search_path` help. See "Idempotence and Recovery" for the EP-1-done /
  EP-2-not-yet window.

At the time this plan is authored, EP-1 and EP-2 are skeletons (not yet fleshed out). This
plan therefore states its assumptions about them explicitly and does not rely on any of their
internal details beyond the two facts above: the `keiro` schema exists (EP-1) and Keiro's own
queries are qualified `keiro.<table>` (EP-2).


## Plan of Work

The work is four milestones. M1 adds the Keiro API surface (the `schema` field and the helper
module). M2 adds the one test-support affordance needed to open a store against a projection
schema. M3 moves the jitsurei worked example onto a user-configured schema and proves it end
to end. M4 adds a focused Keiro test that proves the placement and the separation from Keiro's
own metadata. Each milestone builds and its tests pass before the next begins.


### Milestone 1 — Keiro API: the `schema` field and the qualification/connection helpers

Goal: a Keiro user can declare "my read model's table lives in schema `X`" as a first-class
field, qualify their projection SQL through a shared helper, wire the store connection so `X`
resolves, and optionally have Keiro create `X` in dev/test. At the end of this milestone the
`keiro` library compiles with the new field and module, and its own test suite compiles
(updated to set the new field).

Work, concretely:

1. Create a new module `keiro/src/Keiro/Connection.hs` (module `Keiro.Connection`). It holds
   the schema-resolution helpers so applications have exactly one place to look. It exports:

   - `qualifyTable :: Text -> Text -> Text` — given a schema and a table, produce a
     double-quoted, schema-qualified reference `"schema"."table"`, doubling any embedded
     double quotes (the same quoting kiroku uses for identifiers in
     `Kiroku.Store.Connection.quoteIdentifier`). This is the one canonical way to build a
     qualified table reference for projection SQL; applications interpolate its result into
     their SQL strings.
   - `withProjectionSchema :: Text -> ConnectionSettings -> ConnectionSettings` — append the
     given projection schema to a settings value's `extraSearchPath` (idempotent-friendly:
     append only if not already present). `ConnectionSettings` is
     `Kiroku.Store.Connection.ConnectionSettings`.
   - `keiroConnectionSettings :: Text -> Text -> ConnectionSettings` — convenience:
     `keiroConnectionSettings connString projectionSchema = withProjectionSchema
     projectionSchema (defaultConnectionSettings connString)`. This yields kiroku's defaults
     (`schema = "kiroku"`) with the projection schema on `extraSearchPath`, so unqualified
     application data-manipulation SQL resolves on the store pool while `schema` stays
     `kiroku` (honoring the NOTIFY-channel constraint).
   - `ensureProjectionSchema :: (Store :> es) => Text -> Eff es ()` — run
     `CREATE SCHEMA IF NOT EXISTS "<schema>"` in a transaction (schema name double-quoted via
     the same quoting as `qualifyTable`). This is **opt-in**: Keiro never calls it
     automatically. It exists for development, tests, and worked examples where the
     application, not a production migration tool, owns schema creation. Uses
     `Kiroku.Store.Transaction.runTransaction` and `Hasql.Transaction.sql`.

   Imports needed: `Data.Text` (as the module already will via `Keiro.Prelude`),
   `Kiroku.Store.Connection (ConnectionSettings, defaultConnectionSettings)`,
   `Kiroku.Store.Effect (Store)`, `Kiroku.Store.Transaction (runTransaction)`, and
   `Hasql.Transaction` for `sql`. Keep the module free of any dependency on `Keiro.ReadModel`
   so there is no import cycle.

2. In `keiro/keiro.cabal`, add `Keiro.Connection` to the library's `exposed-modules`.

3. In `keiro/src/Keiro/ReadModel.hs`:

   - Add a field `schema :: !Text` to `ReadModel`, documented as: "the PostgreSQL schema the
     read-model table lives in. The application qualifies its `query` SQL against this schema
     (typically via `Keiro.Connection.qualifyTable`); Keiro does not rewrite `query`. This is
     the application's *data* schema and is entirely separate from Keiro's own `keiro` schema,
     where the `keiro_read_models` registry lives." Place it next to `tableName`.
   - Add and export `qualifiedTableName :: ReadModel q r -> Text`, defined as
     `qualifyTable (readModel ^. #schema) (readModel ^. #tableName)`, importing `qualifyTable`
     from `Keiro.Connection`. This gives applications a one-liner for the read model's
     qualified table reference and keeps the qualification convention in one place. (The
     dependency direction is `Keiro.ReadModel` → `Keiro.Connection`, never the reverse.)
   - Confirm `registerReadModel`/`ensureReadModel`/`validateMetadata` are **not** changed:
     Keiro's metadata path keys on `name`/`version`/`shapeHash`/`status` and never reads the
     new `schema` field. Add a one-line code comment at `ensureReadModel` stating that the
     `schema` field is deliberately not persisted (see Decision Log).

4. Update the two existing `ReadModel` constructions inside `keiro/test/Main.hs`
   (`counterReadModel` at approximately line 8140, and the second `ReadModel` at
   approximately line 8385) to add the new `schema` field. Set it to the schema those tests
   already implicitly target so behavior is unchanged. Those tests create their
   `counter_read_model` table unqualified today (so it lands wherever the store search_path's
   first schema is — `kiroku`); set `schema = "kiroku"` on those constructions to reflect the
   status quo without touching their SQL. (M4 adds a *new* read model in a *non-default*
   schema; these two are left functionally as-is.)

Commands to run at the repository root:

```bash
cabal build keiro
cabal test keiro-test
```

Acceptance: `keiro` builds with the new module and field; `keiro-test` passes exactly as
before (no behavior change — the new field is set to `"kiroku"` in those two tests, matching
where their tables already live). The new helpers are exercised by M4, not here.


### Milestone 2 — Test support: open a store against a projection schema

Goal: a test can open a `KirokuStore` whose connection puts a chosen projection schema on
`extraSearchPath`, so a fresh test database can resolve application read-model tables in that
schema on the store pool. At the end of this milestone `keiro-test-support` exposes a
`withFreshStoreWith` that takes a connection-settings modifier.

Work, concretely, in `keiro-test-support/src/Keiro/Test/Postgres.hs`:

- Add and export

  ```haskell
  withFreshStoreWith ::
      Fixture ->
      (Store.ConnectionSettings -> Store.ConnectionSettings) ->
      (Store.KirokuStore -> IO ()) ->
      IO ()
  withFreshStoreWith fixture modify action =
      withFreshDatabase fixture \connStr ->
          Store.withStore (modify (Store.defaultConnectionSettings connStr)) action
  ```

  Define `withFreshStore fixture = withFreshStoreWith fixture id` so the existing helper is a
  trivial specialization (keeping one code path). Add `Store.ConnectionSettings` and
  `Store.withStore`/`Store.defaultConnectionSettings` to the existing `Kiroku.Store` import as
  needed; `Store` is already imported qualified in this module.

This is purely additive — no existing caller changes. It is the single connection affordance
the MasterPlan Integration Points anticipates ("EP-4 owns any connection-settings helper or
`extraSearchPath` wiring").

Commands to run at the repository root:

```bash
cabal build keiro-test-support
```

Acceptance: `keiro-test-support` builds; `withFreshStore` still behaves identically (it is now
`withFreshStoreWith … id`).


### Milestone 3 — Move the jitsurei worked example onto a user-configured schema

Goal: the jitsurei example's `jitsurei_order_summary` read-model table lives in a
user-chosen `jitsurei` schema (never `kiroku`), its DDL and DML are schema-qualified, its
store connection resolves the schema, and the example runs end to end. At the end of this
milestone `cabal test jitsurei-test` passes with the table demonstrably in `jitsurei`.

Work, concretely:

1. In `jitsurei/src/Jitsurei/ReadModels.hs`:

   - Define and export a constant `jitsureiProjectionSchema :: Text = "jitsurei"`. This is the
     user's explicit choice of where projections live — deliberately not `kiroku`.
   - Define a local `orderSummaryTable :: Text = qualifyTable jitsureiProjectionSchema
     "jitsurei_order_summary"` (importing `qualifyTable` from `Keiro.Connection`). Use it
     everywhere the SQL currently writes the bare name `jitsurei_order_summary`.
   - Add `schema = jitsureiProjectionSchema` to `orderSummaryReadModel`.
   - Rewrite `initializeOrderSummaryTable` to create the schema (opt-in, app-owned) and the
     qualified table:

     ```haskell
     initializeOrderSummaryTable :: Tx.Transaction ()
     initializeOrderSummaryTable =
         Tx.sql $
             "CREATE SCHEMA IF NOT EXISTS \"jitsurei\";\n"
                 <> "CREATE TABLE IF NOT EXISTS " <> orderSummaryTable <> " (\n"
                 <> "  order_id TEXT PRIMARY KEY,\n"
                 <> "  sku TEXT NOT NULL,\n"
                 <> "  quantity BIGINT NOT NULL,\n"
                 <> "  status TEXT NOT NULL,\n"
                 <> "  last_seen BIGINT NOT NULL\n"
                 <> ")"
     ```

     (`Hasql.Transaction.sql` runs a multi-statement script with no parameters, so the
     `CREATE SCHEMA` and `CREATE TABLE` can share one call. Encode the SQL as `Text`; because
     `orderSummaryTable` is interpolated at runtime the block can no longer be a single
     `MultilineStrings` literal — build it with `<>` as shown, or hoist a small helper.)
   - Change `upsertOrderSummaryStmt`, `updateOrderSummaryStatusStmt`, and
     `selectOrderSummaryStmt` to reference `orderSummaryTable` instead of the bare name.
     Because `preparable`/`Statement` SQL is a compile-time `MultilineStrings` literal today,
     switch each to build its SQL `Text` with `<>` around `orderSummaryTable` (the parameter
     encoders and row decoders are unchanged). Every occurrence of `jitsurei_order_summary`
     becomes `jitsurei.jitsurei_order_summary` (via `orderSummaryTable`), so all reads and
     writes are fully qualified and correct independent of `search_path`.

2. `jitsurei/src/Jitsurei/Database.hs` needs no change: `initializeJitsureiTables` still calls
   `initializeOrderSummaryTable`, which now creates the schema and the qualified table.

3. In `jitsurei/app/Main.hs`, change `withJitsureiStore` (around line 537) to open the store
   with the projection schema wired onto the connection:

   ```haskell
   Store.withStore (keiroConnectionSettings connString jitsureiProjectionSchema) action
   ```

   importing `keiroConnectionSettings` from `Keiro.Connection` and `jitsureiProjectionSchema`
   from `Jitsurei.ReadModels`. This demonstrates the connection-wiring half of the feature
   even though full qualification already makes the SQL correct; it keeps unqualified
   application SQL (should any be added later) resolvable on the store pool.

4. In `jitsurei/test/Main.hs`, the read-model and process-manager `describe` blocks currently
   use `around (withFreshStore fixture)`. Switch the blocks that touch the order-summary read
   model to
   `around (withFreshStoreWith fixture (withProjectionSchema jitsureiProjectionSchema))` so the
   store pool carries the `jitsurei` schema on `extraSearchPath` (importing `withFreshStoreWith`
   from `Keiro.Test.Postgres` and `withProjectionSchema`/`jitsureiProjectionSchema`). The
   existing assertions (`initializeJitsureiTables`, `runCommandWithProjections … [orderSummary
   InlineProjection]`, `runQuery … orderSummaryReadModel …`) are unchanged and must still pass,
   now against the `jitsurei`-schema table.

Commands to run at the repository root:

```bash
cabal build jitsurei
cabal test jitsurei-test
cabal run jitsurei-demo
```

Acceptance: `jitsurei-test` passes; the read-model tests place and read
`jitsurei.jitsurei_order_summary` successfully. `jitsurei-demo` runs end to end (it opens the
store via `keiroConnectionSettings`, creates the schema and table, and drives the fulfillment
process that writes the order summary). See "Validation and Acceptance" for a catalog query
proving the table is in `jitsurei` and not in `kiroku`.


### Milestone 4 — Keiro test: prove placement and separation from framework metadata

Goal: an independent Keiro-level test proves that a read-model table can be placed in an
arbitrary configured schema, written by an inline projection and read back by `runQuery`,
while Keiro's own `keiro_read_models` metadata stays in the `keiro` schema. At the end of this
milestone `cabal test keiro-test` includes this new example and passes.

Work, concretely, add one `describe`/`it` to `keiro/test/Main.hs` (near the existing read-model
tests). The test:

1. Opens a fresh store with a chosen application schema on `extraSearchPath`, using
   `withFreshStoreWith fixture (withProjectionSchema "app_reads")` (the schema name `app_reads`
   is arbitrary and deliberately neither `kiroku` nor `keiro`).
2. Defines a small read model `placedReadModel :: ReadModel Text Int` with
   `schema = "app_reads"`, `tableName = "placed_counter"`, and a `query` whose SQL is qualified
   with `qualifiedTableName placedReadModel` (i.e. `app_reads.placed_counter`), plus a matching
   inline projection whose upsert SQL is qualified the same way.
3. Calls `ensureProjectionSchema "app_reads"` and creates `app_reads.placed_counter` (qualified
   `CREATE TABLE`), then runs a command with the inline projection via
   `runCommandWithProjections` and reads the value back with `runQuery`. Asserts the read value
   equals what was written.
4. Asserts placement with catalog queries run on the same store transaction:
   - `SELECT count(*) FROM pg_tables WHERE schemaname = 'app_reads' AND tablename =
     'placed_counter'` returns `1`.
   - `SELECT count(*) FROM pg_tables WHERE schemaname = 'kiroku' AND tablename =
     'placed_counter'` returns `0` (the application table is **not** in the event-store schema).
   - `SELECT count(*) FROM pg_tables WHERE schemaname = 'keiro' AND tablename =
     'keiro_read_models'` returns `1` (Keiro's own metadata is in `keiro`, unaffected by the
     application's configured schema). This last assertion is what makes the framework/application
     separation observable.

Commands to run at the repository root:

```bash
cabal test keiro-test
```

Acceptance: `keiro-test` passes including the new example; the catalog assertions demonstrate
the application table in `app_reads`, its absence from `kiroku`, and `keiro_read_models` in
`keiro`.


## Concrete Steps

Run everything from the repository root
(`/Users/shinzui/Keikaku/bokuno/keiro`). The toolchain is GHC 9.12 with Cabal; database tests
use ephemeral-pg against PostgreSQL 18 (started automatically by the `keiro-test-support`
fixture — no external database required). Test-suite names come from the cabal files:
`keiro-test` (in `keiro/keiro.cabal`), `jitsurei-test` (in `jitsurei/jitsurei.cabal`), and
`keiro-migrations-test` (in `keiro-migrations/keiro-migrations.cabal`).

Milestone 1:

```bash
cabal build keiro
cabal test keiro-test
```

Expected: build succeeds; `keiro-test` reports all examples passing, e.g.

```text
Finished in N.NNNN seconds
NN examples, 0 failures
```

Milestone 2:

```bash
cabal build keiro-test-support
```

Expected: build succeeds with no warnings introduced (`withFreshStore` now delegates to
`withFreshStoreWith … id`).

Milestone 3:

```bash
cabal build jitsurei
cabal test jitsurei-test
cabal run jitsurei-demo
```

Expected: build succeeds; `jitsurei-test` reports all examples passing; `jitsurei-demo` prints
its normal end-to-end transcript (it connects, creates the `jitsurei` schema and table, and
drives orders through). To prove placement, connect to the demo's database and run the catalog
query from "Validation and Acceptance"; expect the table in schema `jitsurei`.

Milestone 4:

```bash
cabal test keiro-test
```

Expected: `keiro-test` passing, now including the new "read-model in a configured schema"
example.

Full sweep before declaring the plan complete:

```bash
cabal build all
cabal test keiro-test jitsurei-test keiro-migrations-test
```

Expected: all three suites pass. `keiro-migrations-test` is included to confirm this plan
introduced **no** migration change (it must still pass unchanged, since the projection schema
is Haskell-level config only — see the Decision Log).


## Validation and Acceptance

Acceptance is behavioral, not "the field exists." The following observations prove the
feature works.

1. **The jitsurei read-model table is in a user-configured schema, not `kiroku`.** After
   `cabal run jitsurei-demo` (or inside `jitsurei-test`), the table
   `jitsurei.jitsurei_order_summary` exists and `kiroku.jitsurei_order_summary` does not. Prove
   it with:

   ```sql
   SELECT schemaname, tablename
   FROM pg_tables
   WHERE tablename = 'jitsurei_order_summary';
   ```

   Expected single row: `schemaname = jitsurei`, `tablename = jitsurei_order_summary`. Before
   this plan the same query would have shown `schemaname = kiroku`.

2. **Reads and writes still succeed against the configured schema.** `jitsurei-test`'s
   "updates and queries the inline order summary in the append transaction" example runs a
   command with `orderSummaryInlineProjection` and then `runQuery … orderSummaryReadModel`,
   asserting the queried `OrderSummary` matches what was written. It passes with the table in
   `jitsurei`. This proves the qualified DDL/DML round-trips.

3. **Keiro's own metadata is untouched and stays in `keiro`.** The M4 Keiro test asserts, via
   `pg_tables`, that `placed_counter` is in the configured `app_reads` schema, absent from
   `kiroku`, and that `keiro_read_models` is in `keiro`. This is the concrete demonstration
   that the configurable schema is for *application* data only and does not move or affect
   Keiro's framework metadata.

4. **No migration was introduced.** `cabal test keiro-migrations-test` passes unchanged. This
   confirms the projection schema is Haskell-level configuration and did not require a new
   forward migration or a codd expected-schema snapshot regeneration (which would have coupled
   this plan to EP-1 and EP-3).

A run is a failure if any of: the jitsurei table appears in `kiroku`; `runQuery` returns a
`ReadModelError` or a stale/missing row; the M4 catalog assertions do not hold;
`keiro-migrations-test` fails (would indicate an accidental schema/migration change).


## Idempotence and Recovery

All steps are additive and safe to repeat. The `keiro` API changes (a new module, a new
record field, a new helper) are pure source edits; rebuild to re-apply. `CREATE SCHEMA IF NOT
EXISTS` and `CREATE TABLE IF NOT EXISTS` are idempotent, so re-running the jitsurei
initialization or the demo against an existing database is harmless. The test suites clone a
fresh database per example (`withFreshDatabase`), so repeated runs never accumulate state.

There is no destructive migration in this plan: nothing is dropped, renamed, or moved on
disk, and no data is relocated. If any milestone fails to compile, the fix is local to the
files that milestone names; revert those files to recover.

**The EP-1-done / EP-2-not-yet window.** This plan hard-depends on EP-1 (docs/plans/85), which
moves Keiro's framework tables (including `keiro_read_models` and `keiro_projection_dedup`)
into the `keiro` schema, and soft-depends on EP-2 (docs/plans/86), which qualifies Keiro's
runtime queries as `keiro.<table>`. If this plan is exercised after EP-1 but **before** EP-2,
Keiro's own unqualified `keiro_read_models`/`keiro_projection_dedup` queries will not resolve
on the store pool (search_path is `kiroku, [projection schema], pg_catalog`, and the tables now
live in `keiro`). Two safe options: (a) sequence this plan after EP-2 (the MasterPlan's
recommended order — "EP-4 can start once EP-1 is done and is best sequenced after EP-2"); or
(b) temporarily add `"keiro"` to the store's `extraSearchPath` for the duration of the window
(for example `withProjectionSchema "keiro" . withProjectionSchema jitsureiProjectionSchema`),
removing it once EP-2 qualifies the queries. Option (a) is preferred; option (b) is a
documented fallback that does not change any production behavior once EP-2 lands. This plan's
`keiroConnectionSettings` deliberately does **not** bake `keiro` into `extraSearchPath`,
because EP-2's whole point is to remove Keiro's dependence on `search_path`.


## Interfaces and Dependencies

Libraries and modules used, and why:

- `Kiroku.Store.Connection` (from kiroku-store, at
  `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Connection.hs`):
  provides `ConnectionSettings`, `defaultConnectionSettings`, `withStore`, and the `schema` /
  `extraSearchPath` fields this plan wires. Not modified (out of scope per the MasterPlan;
  kiroku already supports configurable schemas). Reached via the existing `Kiroku.Store`
  re-export used by `keiro-test-support`.
- `Kiroku.Store.Effect (Store)`, `Kiroku.Store.Transaction (runTransaction)`, and
  `Hasql.Transaction` (`sql`): used by `ensureProjectionSchema` to run `CREATE SCHEMA IF NOT
  EXISTS` in a transaction.
- `Keiro.ReadModel`, `Keiro.Projection`, `Keiro.ReadModel.Schema`: the read-model/projection
  API. Only `Keiro.ReadModel` changes type-wise (new `schema` field + `qualifiedTableName`);
  `Keiro.Projection` and `Keiro.ReadModel.Schema` are unchanged, and their framework-metadata
  writes stay in the `keiro` schema (EP-1/EP-2), unaffected by the new field.

Types, interfaces, and signatures that must exist at the end of each milestone:

- End of M1, in `keiro/src/Keiro/Connection.hs` (module `Keiro.Connection`, added to
  `keiro.cabal` `exposed-modules`):

  ```haskell
  qualifyTable          :: Text -> Text -> Text
  withProjectionSchema  :: Text -> ConnectionSettings -> ConnectionSettings
  keiroConnectionSettings :: Text -> Text -> ConnectionSettings
  ensureProjectionSchema :: (Store :> es) => Text -> Eff es ()
  ```

  and in `keiro/src/Keiro/ReadModel.hs`:

  ```haskell
  data ReadModel q r = ReadModel
      { name :: !Text
      , tableName :: !Text
      , schema :: !Text          -- NEW: the application data schema for this read model
      , subscriptionName :: !Text
      , version :: !Int
      , shapeHash :: !Text
      , defaultConsistency :: !ConsistencyMode
      , query :: !(q -> Tx.Transaction r)
      }

  qualifiedTableName :: ReadModel q r -> Text   -- = qualifyTable (schema rm) (tableName rm)
  ```

- End of M2, in `keiro-test-support/src/Keiro/Test/Postgres.hs`:

  ```haskell
  withFreshStoreWith ::
      Fixture ->
      (Store.ConnectionSettings -> Store.ConnectionSettings) ->
      (Store.KirokuStore -> IO ()) ->
      IO ()
  ```

  with `withFreshStore = \fixture -> withFreshStoreWith fixture id`.

- End of M3, in `jitsurei/src/Jitsurei/ReadModels.hs`:

  ```haskell
  jitsureiProjectionSchema :: Text          -- "jitsurei"
  orderSummaryReadModel    :: ReadModel OrderSummaryQuery (Maybe OrderSummary)  -- schema = jitsureiProjectionSchema
  ```

  with `orderSummaryReadModel.schema = "jitsurei"`, all order-summary SQL qualified to
  `jitsurei.jitsurei_order_summary`, and `jitsurei/app/Main.hs` opening the store via
  `keiroConnectionSettings connString jitsureiProjectionSchema`.

Dependencies on sibling plans (both checked in at their paths):

- **Hard**: EP-1 at `docs/plans/85-rewrite-keiro-migrations-to-own-a-dedicated-keiro-schema-with-qualified-ddl.md`
  must have created the `keiro` schema and placed `keiro_read_models` /
  `keiro_projection_dedup` in it. This plan's tests assert `keiro_read_models` lives in
  `keiro`.
- **Soft**: EP-2 at `docs/plans/86-qualify-all-keiro-framework-runtime-queries-with-the-keiro-schema.md`
  qualifies Keiro's runtime queries. This plan reuses EP-2's qualification idiom for the
  application layer and assumes EP-2's qualification so Keiro's own tables resolve without
  `search_path` help; see "Idempotence and Recovery" for the interim window.

Integration points this plan owns or must report to siblings:

- This plan **introduces no database migration**: the projection schema is Haskell-level
  configuration only, not a column on `keiro_read_models`. Therefore EP-3 (docs/plans/87)
  needs **no** codd expected-schema snapshot regeneration on this plan's account, and EP-1
  needs no new forward migration on this plan's account. This is the "record that here so no
  snapshot change is needed" case in the MasterPlan Integration Points.
- This plan **owns the connection helper**. It introduces `keiroConnectionSettings`,
  `withProjectionSchema`, `qualifyTable`, `qualifiedTableName`, and `ensureProjectionSchema`
  in `Keiro.Connection`, plus `withFreshStoreWith` in `keiro-test-support`. **These names must
  stay stable for EP-5** (docs/plans/89), which documents the projection-schema feature and
  the connection helper. If any name changes during implementation, update this section and
  notify EP-5.
- The store `schema` field stays `kiroku`; the projection schema is reached only by
  qualification and/or `extraSearchPath`, per the hard constraint in the Decision Log and the
  MasterPlan Integration Points.
