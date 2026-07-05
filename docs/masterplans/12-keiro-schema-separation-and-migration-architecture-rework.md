---
id: 12
slug: keiro-schema-separation-and-migration-architecture-rework
title: "Keiro schema separation and migration architecture rework"
kind: master-plan
created_at: 2026-07-05T18:38:56Z
intention: "intention_01kwsrmsbsedqb0rh0vb41x04m"
---

# Keiro schema separation and migration architecture rework

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Keiro is an event-sourcing framework and durable-workflow engine written in Haskell. It
sits on top of a separate event-store library called **kiroku** (the dependency
`shinzui/kiroku`). kiroku keeps all of its own PostgreSQL objects — the `streams`,
`events`, `stream_events`, `subscriptions`, and `dead_letters` tables, plus the
`kiroku.events` `LISTEN`/`NOTIFY` channel — inside a dedicated PostgreSQL schema it
creates and owns, named `kiroku` by default. A PostgreSQL *schema* is a namespace inside
one database; unqualified table names resolve against a session's `search_path` list of
schemas.

Keiro copied kiroku's migration approach without questioning it, and copied only the
fragile half. Every Keiro migration under `keiro-migrations/sql-migrations/` begins with
`SET search_path TO kiroku, pg_catalog;` and then issues **unqualified** `CREATE TABLE
keiro_*` statements, so all of Keiro's framework tables — `keiro_snapshots`,
`keiro_read_models`, `keiro_timers`, `keiro_outbox`, `keiro_inbox`,
`keiro_projection_dedup`, `keiro_workflows`, `keiro_workflow_steps`,
`keiro_workflow_children`, `keiro_awakeables`, `keiro_subscription_shards` — are created
**inside kiroku's private `kiroku` schema**. Keiro is a squatter: it owns no schema of
its own, its bootstrap migration never runs `CREATE SCHEMA`, and it pollutes the event
store's namespace. Because `SET search_path` is session-scoped and codd (the migration
runner) applies each migration file in its own session, this pattern also forces a noisy
five-line explanatory comment at the top of every migration and was already the source of
a production incident (tables landing in `public` on incremental upgrades; see
`docs/plans/46-keiro-framework-migrations-self-set-search-path-for-incremental-upgrades.md`).

Two further defects compound the problem. First, Keiro's checked-in codd
expected-schema snapshot (`keiro-migrations/expected-schema/`) is scoped to the `kiroku`
namespace, so it captures **both** libraries' tables interleaved and couples Keiro's
drift gate to kiroku's internal table layout; worse, it captured the author's **local
database role** (`expected-schema/v18/roles/shinzui`) and the local database owner
(`db-settings` `owner: shinzui`, `public_privileges: [["cT","shinzui"]]`), because
ephemeral-pg's superuser is the local operating-system user. On any other developer's
machine or in CI the role name differs, so the strict drift gate `cabal test
keiro-migrations-test` false-fails. (Research during planning established that codd
*always* captures the connecting user's role and the single database-owner row — it
computes `rolesToCheck = SqlRole(connecting-user) : extraRolesToCheck` — so the fix is not
"emit zero role files" but "make the captured identity deterministic": pin ephemeral-pg's
superuser to a fixed name so the snapshot records a stable `keiro` role/owner instead of
the local OS user.) Second, Keiro has **no architecture for projections**:
the read-model and projection APIs (`Keiro.ReadModel`, `Keiro.Projection`) carry no
schema field, Keiro creates none of the application's read-model tables, and where those
tables land is decided solely by the store connection's `search_path` (default `kiroku`).
An application that naively runs unqualified projection DDL therefore co-mingles its
read-model tables into the `kiroku` schema alongside the event store — there is no
first-class way for a user to say "put my projections in this schema."

**After this initiative**, Keiro owns a dedicated PostgreSQL schema named `keiro`
(distinct from `kiroku`). Every Keiro migration creates its tables **schema-qualified**
as `keiro.<table>` with no `SET search_path` pin and no noisy comment; the migration
scaffolder (`keiro-migrate new`) generates that qualified, comment-free template. Every
Keiro **runtime** query is qualified `keiro.<table>` so the runtime no longer depends on
`search_path` at all for its own tables. The codd expected-schema snapshot is scoped to
the `keiro` namespace, contains only `keiro_*` objects, and is fully portable — the
captured role and owner are a deterministic pinned `keiro` identity, not the local OS
user — so `cabal test keiro-migrations-test` passes on any machine and in CI. Applications gain a **first-class, configurable projection/read-model
schema**: a user can declare (via a new `schema` field on `ReadModel` and a
`Keiro.Connection` helper set) the schema their read-model and projection tables live in,
and Keiro targets it directly. Finally, because the alpha release `keiro-migrations
0.1.0.0` already shipped to Hackage with tables in `kiroku`, the initiative ships a
one-time, tested remediation runbook (relocate the tables with `ALTER TABLE ... SET
SCHEMA keiro`) plus updated user documentation, so an existing alpha database can move to
the new layout without data loss. (Because codd keys a migration's applied-status by
filename with no body checksum, and the clean rewrite keeps every migration's filename
unchanged, the remediation needs no codd-ledger rename — unlike the earlier
timestamp-realignment fixup — only the table relocation.)

**How you can see it working when the initiative is complete.** Running `cabal run
keiro-write-expected-schema` followed by `git status` shows the snapshot under
`keiro-migrations/expected-schema/v18/schemas/keiro/` with a deterministic `roles/keiro`
and `owner: keiro` — no machine-specific `shinzui` identifier anywhere in the tree;
`cabal test keiro-migrations-test` passes on a machine whose OS user is not `shinzui`; a fresh migrated database has every `keiro_*` table in the `keiro` schema
and none in `kiroku` or `public`; the jitsurei worked example runs end to end with its
`jitsurei_order_summary` read-model table in a user-configured schema (not `kiroku`); and
the remediation runbook, applied to a database seeded with the 0.1.0.0 layout, moves the
tables and leaves codd's ledger consistent (a subsequent `keiro-migrate` is a no-op).

**In scope:** the `keiro-migrations` package (SQL, scaffolder, expected-schema tooling,
tests, remediation script), the runtime query modules in the `keiro` package, the
projection/read-model schema API, the `keiro-test-support` fixture, the jitsurei example,
and all affected user docs. **Out of scope:** any change to the kiroku dependency itself
(kiroku already supports configurable schemas and needs no patch); the `keiro-pgmq`
package (it opens its own pool, touches only `pgmq_*` objects, and references no `keiro_*`
tables); and renaming or restructuring kiroku's own event-store tables.


## Decomposition Strategy

The initiative was split by **functional concern**, following the principle that each
work stream must produce an independently verifiable behavior and that cross-plan coupling
should be minimized. Five concerns emerged naturally:

1. **The schema itself and the migration DDL that creates it** (EP-1). This is the
   foundation: nothing else can be verified against a migrated database until a `keiro`
   schema exists and the tables live in it. It owns the migration rewrite, the scaffolder
   template, and the alpha-database remediation script (a migrations-package artifact
   tightly bound to the rewrite).

2. **Runtime query qualification** (EP-2). A purely code-level concern in the `keiro`
   package: rewrite every framework statement to `keiro.<table>`. It is large but
   mechanical, one functional concern, and independently verifiable by running Keiro's
   own test suites against the new schema. It is separated from EP-1 because migration
   DDL and Haskell query strings are different artifacts with different review and test
   surfaces, and because EP-3 can proceed against EP-1 without waiting for EP-2.

3. **codd expected-schema hygiene** (EP-3). The drift-gate configuration and the
   portability bug (role/owner leak) are a distinct concern from both the DDL and the
   runtime queries: they live in codd `CoddSettings` (`namespacesToCheck`,
   `SchemaSelection`, role capture) and the regenerated snapshot tree. It depends only on
   EP-1 (the tables must be in `keiro` before the snapshot is regenerated), so it can run
   in parallel with EP-2.

4. **First-class projection/read-model schema configuration** (EP-4). This is the
   architectural feature the user explicitly asked for. It is a design-and-API stream
   touching `Keiro.ReadModel`, `Keiro.Projection`, the store connection wiring, and the
   jitsurei example. It reuses the qualification idiom EP-2 establishes, so it soft-depends
   on EP-2, and it needs the `keiro` schema from EP-1.

5. **Documentation and the release/remediation runbook** (EP-5). All user-facing docs,
   the CHANGELOG breaking-change note, and the narrative upgrade guide that wraps EP-1's
   remediation script. It reflects the final state of every other stream, so it is last.

**Alternatives considered.** Merging EP-1 and EP-3 (both touch the migrations package) was
rejected because the expected-schema portability investigation (why codd captured a role)
is a self-contained research task that would bloat EP-1 and block it on an unrelated
unknown; keeping them separate lets EP-3 fail-fast on the codd investigation while EP-1
ships the DDL. Merging EP-2 into EP-1 was rejected because it would make one plan do the
large majority of the work (the ~150 query sites) while starving the others, violating
the balance principle. Folding the remediation script into EP-5 (docs) was rejected
because the script is executable, tested code — a sibling of the existing
`keiro-migrations/ledger-fixups/` artifact — not prose; EP-5 owns only its human-facing
runbook and references EP-1's script.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Rewrite keiro migrations to own a dedicated keiro schema with qualified DDL | docs/plans/85-rewrite-keiro-migrations-to-own-a-dedicated-keiro-schema-with-qualified-ddl.md | None | None | Complete |
| 2 | Qualify all keiro framework runtime queries with the keiro schema | docs/plans/86-qualify-all-keiro-framework-runtime-queries-with-the-keiro-schema.md | EP-1 | None | Complete |
| 3 | Scope codd expected-schema to the keiro namespace and remove the role and owner leak | docs/plans/87-scope-codd-expected-schema-to-the-keiro-namespace-and-remove-the-role-and-owner-leak.md | EP-1 | EP-2 | Complete |
| 4 | Add first-class configurable projection and read-model schema support | docs/plans/88-add-first-class-configurable-projection-and-read-model-schema-support.md | EP-1 | EP-2 | Complete |
| 5 | Document keiro schema separation and ship the alpha database remediation guide | docs/plans/89-document-keiro-schema-separation-and-ship-the-alpha-database-remediation-guide.md | EP-1 | EP-2, EP-3, EP-4 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 is the root of the initiative and has no dependencies. It creates the `keiro` schema
and relocates the framework tables into it via rewritten, schema-qualified migrations, and
it ships the alpha-database remediation script. Every other plan needs a migrated database
whose `keiro_*` tables live in the `keiro` schema in order to verify its own behavior, so
every other plan hard-depends on EP-1.

EP-2 (qualify runtime queries) hard-depends on EP-1 because a query rewritten to
`keiro.keiro_inbox` can only be tested against a database where that schema and table
exist. It has no other dependency and can begin as soon as EP-1 is complete.

EP-3 (expected-schema hygiene) hard-depends on EP-1 because the codd snapshot is
regenerated from the migrated database; the snapshot cannot be scoped to a `keiro`
namespace that does not yet exist. EP-3 does **not** depend on EP-2 for correctness — the
expected schema reflects the *database shape* produced by migrations, not the Haskell query
strings — so EP-2 and EP-3 can proceed **in parallel** after EP-1. EP-3 carries a soft
dependency on EP-2 only for convenience of running the full Keiro suite green at the end;
if EP-2 is not yet done, EP-3 still verifies via the dedicated `keiro-migrations-test`.

EP-4 (projection schema config) hard-depends on EP-1 (it needs the `keiro` schema to exist
and needs the migration story settled before adding any projection-related schema/table)
and soft-depends on EP-2 because it should reuse the exact schema-qualification idiom and
any connection-settings helper EP-2 establishes, rather than inventing a second style.

EP-5 (docs + remediation guide) hard-depends on EP-1 (its runbook wraps EP-1's remediation
script and describes the new schema) and soft-depends on EP-2, EP-3, and EP-4 because the
documentation must describe their final states (qualified runtime, portable drift gate,
configurable projection schema). EP-5 is the last plan; it can begin drafting once EP-1 is
done but should be finalized only after EP-2–EP-4 land.

Parallelism summary: after EP-1 completes, EP-2 and EP-3 can run concurrently. EP-4 can
start once EP-1 is done and is best sequenced after EP-2. EP-5 finalizes last.


## Integration Points

**The `keiro` schema name.** EP-1 is the single source of truth for the schema name
`keiro`. Its bootstrap migration issues `CREATE SCHEMA IF NOT EXISTS keiro;` and every
migration qualifies `keiro.<table>`. EP-2 must qualify runtime queries against the **same**
literal schema name; EP-3 must set codd `namespacesToCheck = IncludeSchemas [SqlSchema
"keiro"]` using the same name; EP-4's default projection schema and EP-5's docs must refer
to it identically. **Resolved during authoring:** EP-1 defines the Haskell constant
`keiroSchema :: Text = "keiro"` in a **new `Keiro.Schema` module in the `keiro-core`
package** (chosen over `keiro-migrations`, which stays raw SQL). Haskell code that needs
the schema name (connection settings, `Keiro.Connection` helpers in EP-4) imports
`keiroSchema` from `keiro-core` rather than re-declaring the literal. Note a deliberate
exception: EP-2's runtime SQL is written as static multiline string literals, and codd/the
query bodies embed the `keiro.` prefix **inline** as text — a Haskell `Text` constant
cannot be spliced into a static SQL literal, so EP-2 hardcodes the `keiro.` prefix in the
SQL strings (kept in lockstep with `keiroSchema` by review, not by the compiler). This is
expected and not a drift risk because the schema name is a stable, one-time choice.

**Runtime references to kiroku's own tables.** Keiro runtime queries touch not only
`keiro_*` tables but also kiroku-owned tables such as `subscriptions` (read by
`Keiro.ReadModel`'s position-wait logic) and the `kiroku.events` notification channel.
EP-2 owns the decision of whether those cross-library references are left unqualified
(resolved via the store's `schema = "kiroku"` search_path) or qualified `kiroku.<table>`.
**Resolved during authoring:** the only cross-library table reference in Keiro's runtime is
`FROM subscriptions` in `keiro/src/Keiro/ReadModel.hs` (~line 279); EP-2 leaves it **bare**
(convention (a)), since the store pool's `search_path` starts at `kiroku` and kiroku owns
that name. EP-4 (which also reads subscription/store state) follows the same convention.
EP-2 also verified 12 modules (not the ~10 first estimated — `Keiro/Workflow/Instance.hs`
and `Keiro/Workflow/Schema.hs` were found by an exhaustive sweep) and flagged a Postgres
constraint: in `INSERT ... ON CONFLICT DO UPDATE`, the excluded/target self-references of
the form `<table>.<column>` (in the Snapshot, Timer, Inbox, ReadModel, and Instance
upserts) **must remain unqualified** — Postgres forbids schema-qualifying the target
relation there. Only the `INSERT INTO`/`FROM`/`UPDATE`/`DELETE` table positions are
qualified `keiro.<table>`. Note the hard constraint discovered in research: the store's `schema`
field drives both kiroku's event tables and the `<schema>.events` NOTIFY channel, so it
**cannot** be repointed away from `kiroku`; a dedicated `keiro` schema must be reached by
qualification (EP-2/EP-4) or by adding it to `extraSearchPath`, never by changing `schema`.

**The store connection settings / `search_path` wiring.** The `keiro-test-support`
fixture (`keiro-test-support/src/Keiro/Test/Postgres.hs`) and the jitsurei entrypoint
(`jitsurei/app/Main.hs`) open the store via kiroku's `defaultConnectionSettings`
(`schema = "kiroku"`, `extraSearchPath = []`). Once EP-2 qualifies Keiro's own tables,
those tables no longer need `search_path` help. But EP-4's application projection tables
**do** need to be resolvable/creatable in a user-chosen schema; EP-4 owns any
connection-settings helper or `extraSearchPath` wiring and must reconcile it with EP-2's
qualification convention. **Resolved during authoring:** EP-4 introduces a new
`Keiro.Connection` module exposing `qualifyTable`, `qualifiedTableName`,
`keiroConnectionSettings`, `withProjectionSchema`, and an opt-in `ensureProjectionSchema`;
the app's projection DDL/DML is fully qualified with its configured schema (mirroring
EP-2's idiom), with `extraSearchPath` wiring offered as a convenience. Crucially, EP-4
keeps `keiroConnectionSettings` from baking `keiro` into `extraSearchPath`, so EP-2's goal
of a search_path-independent runtime is preserved. EP-5 documents `Keiro.Connection`, and
the `keiro-test-support`/jitsurei call sites are updated once, consistently. Because keiro
runs its own unqualified metadata queries on the store pool only until EP-2 lands, EP-4 is
sequenced **after** EP-2 (see soft dependency), which also removes the window where those
queries would fail against the relocated schema.

**The codd expected-schema snapshot.** EP-1's migrations produce the database shape; EP-3
owns the final authoritative on-disk snapshot under `keiro-migrations/expected-schema/`.
There is a two-step sequencing between EP-1 and EP-3 that both plans must honor to avoid a
red `keiro-migrations-test` window. EP-1 moves the `keiro_*` tables out of the `kiroku`
namespace; with codd still scoped to `kiroku`, the pre-existing snapshot (which lists
`keiro_*` tables under `kiroku`) would then mismatch the live database, so **EP-1
regenerates an interim snapshot** that keeps the strict gate green (the `kiroku` namespace
now contains only kiroku's own tables). **EP-3 then re-scopes** `namespacesToCheck` to
`keiro`, pins the ephemeral-pg superuser to a deterministic `keiro` identity, and
regenerates the **authoritative** snapshot under `schemas/keiro/`, deleting the stale
`kiroku`-scoped `keiro_*` entries. EP-3 hard-depends on EP-1, so this ordering is
guaranteed. **Resolved during authoring:** EP-4 stores the projection schema **purely as a
Haskell-level `ReadModel` field — no new column and no new migration** — so EP-4 triggers
**no** snapshot regeneration. Should any future change to EP-4 persist the schema in the
database, it would become an EP-1-format forward migration requiring an EP-3 regeneration;
that path is explicitly not taken.

**The migration test's table-location assertions.** `keiro-migrations/test/Main.hs`
asserts tables exist in `kiroku` and are absent from `public`. EP-1 flips these to assert
presence in `keiro` and absence from `kiroku` and `public`. EP-3 owns the strict
schema-match test in the same file. Both plans edit `keiro-migrations/test/Main.hs`; EP-1
lands first (it hard-precedes EP-3), so EP-3 builds on EP-1's version. Keep the two edits
in distinct functions (`assertTablesExist`/`assertTablesAbsent` for EP-1; the
`testCoddSettings` namespace + strict-check example for EP-3) to avoid conflicts.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section is populated with each child plan's actual milestones as
they are authored and refined; the entries below are the initial expected milestones and
will be reconciled against the child plans' Progress sections during implementation.

- [x] EP-1 (2026-07-05): `keiroSchema` constant added to a new `Keiro.Schema` module in `keiro-core`
- [x] EP-1 (2026-07-05): New `keiro` schema created and owned by a rewritten bootstrap migration
- [x] EP-1 (2026-07-05): All framework migrations rewritten to qualified `keiro.<table>` DDL, no `SET search_path`
- [x] EP-1 (2026-07-05): `keiro-migrate new` scaffolder emits qualified, comment-free templates
- [x] EP-1 (2026-07-05): Table-location assertions flipped; interim expected-schema snapshot regenerated to keep the strict gate green (`keiro-migrations-test`: 4 examples, 0 failures)
- [x] EP-1 (2026-07-05): Alpha-database remediation script written and tested (`CREATE SCHEMA` + `ALTER TABLE ... SET SCHEMA`; no ledger rename needed)
- [x] EP-2 (2026-07-05): Every `keiro_*` runtime query qualified `keiro.<table>`; cross-library reference convention documented (subscriptions stays bare)
- [x] EP-2 (2026-07-05): Keiro test suites pass against the `keiro`-schema database (279 examples, 0 failures)
- [x] EP-3 (2026-07-05): codd `namespacesToCheck` scoped to `keiro`; authoritative snapshot contains only `keiro_*` objects under `schemas/keiro/`
- [x] EP-3 (2026-07-05): Captured identity made deterministic (pinned `keiro` role/owner, no local OS user); snapshot portable; drift gate passes on a non-`shinzui` machine (`USER=notshinzui`) with a negative-drift check
- [x] EP-4 (2026-07-05): `schema` field added to `ReadModel`; `Keiro.Connection` helper module added and wired (Haskell-level config, no DB column; `keiro-migrations-test` unchanged, snapshot clean)
- [x] EP-4 (2026-07-05): jitsurei read-model table lives in a user-configured `jitsurei` schema, example runs end to end (`jitsurei-test` 16/16); keiro-test proves placement + separation from `keiro` metadata
- [ ] EP-5: All user docs, README, and CHANGELOG updated for the `keiro` schema
- [ ] EP-5: Alpha-to-new upgrade runbook published and validated against a 0.1.0.0-seeded database


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- 2026-07-05: The `keiro` runtime is already schema-clean — every framework query uses
  bare `keiro_*` names and `rg 'kiroku\.keiro_'` returns nothing across all `.hs`/`.sql`.
  Resolution depends entirely on kiroku-store's pool `initSession`
  (`SET search_path TO "<schema>"[, extraSearchPath...], pg_catalog`). This means EP-2 is a
  mechanical qualification pass with no logic changes, and moving tables to `keiro` breaks
  nothing at compile time — only at query resolution time until EP-2 (qualification) or an
  `extraSearchPath` addition lands.
- 2026-07-05: kiroku-store's `schema` connection field drives both the event-store tables
  **and** the `<schema>.events` `LISTEN`/`NOTIFY` channel, so it cannot be repointed to a
  `keiro`-only schema. This is why the initiative reaches the `keiro` schema by
  qualification (user's choice) rather than by changing `schema`. Recorded as a hard
  constraint in Integration Points.
- 2026-07-05: The expected-schema role leak is a real portability bug, not cosmetic:
  `expected-schema/v18/roles/shinzui` and `db-settings` `owner: shinzui` come from
  ephemeral-pg using the local OS user as PostgreSQL superuser. The strict drift gate
  would false-fail for any developer whose username is not `shinzui`, and in CI. EP-3 owns
  the fix and must prove it by regenerating on / reasoning about a non-`shinzui` identity.
- 2026-07-05: kiroku itself models the target pattern and needs no changes — it
  `CREATE SCHEMA`s and owns its schema in bootstrap, hard-qualifies `kiroku.<table>` in
  every incremental migration, sets `search_path` once at the pool, scopes codd to its own
  namespace (`IncludeSchemas [SqlSchema "kiroku"]`), and captures no roles
  (`extraRolesToCheck = []`). EP-1/EP-2/EP-3 are essentially "adopt kiroku's proven
  pattern for keiro."
- 2026-07-05 (from EP-3 authoring): codd's role capture is not optional — it computes
  `rolesToCheck = SqlRole(connecting-user) : extraRolesToCheck`, so a strict on-disk gate
  **always** records the connecting user's role plus the single `pg_database` owner row.
  "Remove the leak" therefore means "make the identity deterministic" (pin ephemeral-pg's
  superuser to `keiro`), not "produce zero role files." This narrowed EP-3's fix and
  corrected the Vision wording. Also: `ephemeral-pg`'s `withCachedConfig` is not exported,
  so EP-3 must switch from `Pg.withCached` to `Pg.startCached` + `finally` to set a fixed
  `Config.user`.
- 2026-07-05 (from EP-1 authoring): codd decides a migration's applied-status purely by
  **filename** (`codd_schema.sql_migrations.name`) with no body checksum. Because the clean
  rewrite keeps every migration filename unchanged and only edits bodies, fresh installs get
  the new qualified DDL and the alpha remediation needs **no** ledger rename — only the
  `CREATE SCHEMA` + `ALTER TABLE ... SET SCHEMA` table relocation. The schema-name constant
  lives in a new `Keiro.Schema` module in `keiro-core`.
- 2026-07-05 (from EP-4 authoring): the configurable projection schema is a `schema :: Text`
  field on `ReadModel` **only**, not on `InlineProjection`/`AsyncProjection` — those are
  opaque table-less apply closures, and adding a required field there would break every
  keiro-dsl-generated `Projection.hs` and drag the keiro-dsl scaffolder into scope. The
  feature is Haskell-level config with **no database column**, so it needs no migration and
  no expected-schema regeneration. A new `Keiro.Connection` helper module carries the
  qualification/`extraSearchPath` wiring.
- 2026-07-05 (EP-1 implementation, complete): EP-1 landed all five milestones. Confirmations
  for downstream plans: (1) `Keiro.Schema.keiroSchema :: Text = "keiro"` is exported from
  `keiro-core` and available for EP-2/EP-4 to import (no new dependency edge — the `keiro`
  runtime package already depends on `keiro-core`). (2) The interim expected-schema snapshot is
  regenerated and **still scoped to `kiroku`**; the regeneration was purely 263 deletions of
  `keiro_*` entries under `schemas/kiroku/tables/`, with kiroku's event tables (incl.
  `dead_letters`) intact and **no** `schemas/keiro/` directory yet — that is EP-3's to add. The
  `roles/shinzui` + `owner: shinzui` portability leak is **still present** as expected, for EP-3
  to fix. (3) `keiro-migrations/test/Main.hs` now exposes `kirokuTables`/`keiroTables` and the
  `assertColumnExists` for `keiro_timers.last_error` targets `keiro`; `testCoddSettings` was
  left untouched for EP-3. (4) The M1 bootstrap comment's literal `search_path` token was
  reworded to `search-path` to keep the M2 grep gate meaningful — a one-line non-functional
  deviation from the verbatim spec text, recorded in EP-1's Surprises/Decision Log.
- 2026-07-05 (EP-2 implementation, complete): The qualification pass had to extend beyond the
  plan's `keiro/src`-only inventory to `keiro/test/Main.hs`, which issues its own direct SQL
  against the framework tables (26 DML refs + 5 DDL fault-injection refs). Missing them first
  produced `279 examples, 38 failures`; qualifying the test DML → 3 failures; qualifying the
  test's `ALTER TABLE`/`TRUNCATE` DDL → 0 failures. **Relevance to EP-4/EP-5:** the full
  relation-introducing keyword set is `INSERT INTO | UPDATE | DELETE FROM | FROM | JOIN | ALTER
  TABLE | TRUNCATE`, and any test or example that touches keiro tables directly must qualify
  them too. The cross-library convention is confirmed working end to end: `FROM subscriptions`
  (kiroku-owned) resolves bare via the store pool's `search_path = kiroku`; EP-4 must follow it.
  EP-2's mechanical qualification idiom (qualify only the relation position; leave
  `<table>.<column>` self-refs, constraint names, and `RENAME TO` targets bare) is the pattern
  EP-4 reuses.
- 2026-07-05 (EP-3 implementation, complete): The two-step snapshot sequencing worked exactly as
  designed — EP-1's interim `kiroku`-scoped snapshot kept the gate green, and EP-3 re-scoped to
  `keiro` and pinned the ephemeral-pg superuser to `keiro`, producing the authoritative portable
  snapshot. The regenerated tree has `schemas/keiro/` (11 `keiro_*` tables only), `roles/keiro`,
  and `db-settings owner: keiro`; `grep -R shinzui keiro-migrations/expected-schema` is empty.
  **For EP-4/EP-5:** the drift gate is now portable and `keiro`-scoped; because EP-4 adds no DB
  column, no snapshot regeneration is triggered by it. Should any future change persist state in
  the database, re-run EP-3's Milestone-4 regeneration + Milestone-5 validation. The
  `keiro-test-support` fixture keeps the default OS user (it never strict-checks); only the write
  exe and the strict test pin `keiro`.
- 2026-07-05 (EP-4 implementation, complete): Delivered the configurable projection schema as
  Haskell-level config only — a `ReadModel.schema` field plus a new `Keiro.Connection` helper
  module (`qualifyTable`, `quoteIdentifier`, `withProjectionSchema`, `keiroConnectionSettings`,
  `ensureProjectionSchema`), `qualifiedTableName` on `ReadModel`, and `withFreshStoreWith` in
  `keiro-test-support`. **No migration and no expected-schema regeneration** were triggered
  (confirmed: `keiro-migrations/expected-schema` is git-clean, `keiro-migrations-test` still
  passes), exactly as the Integration Points anticipated. Two discoveries worth flagging for
  EP-5: (1) the jitsurei example (both app and test) had **bare** `keiro_snapshots`/`keiro_timers`
  inspection queries that EP-1 broke and EP-2 didn't cover (it scoped to the `keiro` package);
  EP-4 qualified them `keiro.<table>`. Any EP-5 doc/example touching Keiro framework tables must
  qualify them. (2) Only `jitsurei_order_summary` was migrated to the `jitsurei` schema (matching
  the vision's explicit callout); the two other jitsurei read models stay unqualified in `kiroku`
  by a recorded scope decision. **Stable public names for EP-5 to document:** `Keiro.Connection`'s
  five helpers, `ReadModel.schema`/`qualifiedTableName`, and `withFreshStoreWith`.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Give Keiro its own dedicated `keiro` PostgreSQL schema rather than continuing
  to place framework tables in kiroku's `kiroku` schema.
  Rationale: The user's framing is explicit — kiroku is for the event store and Keiro
  polluted it. kiroku's schema is its private namespace (and its NOTIFY channel is derived
  from it). A dedicated `keiro` schema mirrors kiroku's own ownership model and decouples
  Keiro's drift gate from kiroku's internal table layout.
  Date: 2026-07-05

- Decision: Relocate via a **clean rewrite** of the migration history (reset the bootstrap
  to create `keiro` and all tables qualified there) plus a one-time remediation script for
  existing alpha databases, rather than additive `ALTER TABLE ... SET SCHEMA` forward
  migrations layered on the shipped history.
  Rationale: User selection. `keiro-migrations 0.1.0.0` is a pre-1.0 alpha released today
  with an explicit "API unstable, under active development" warning; a clean rewrite yields
  the cleanest long-term migration history, and the remediation script (a sibling of the
  existing `ledger-fixups/` artifact) covers the few existing adopters without data loss.
  Date: 2026-07-05

- Decision: Fully **qualify all runtime queries** with `keiro.<table>` rather than relying
  on an `extraSearchPath` connection helper for Keiro's own tables.
  Rationale: User selection. It fully decouples the runtime from `search_path`, removes a
  user connection-config footgun, and makes each query self-describing. The cost (~150
  statement sites across ~12 modules) is mechanical and one-time; EP-2 absorbs it.
  Date: 2026-07-05

- Decision: Deliver **first-class configurable projection/read-model schema support**
  (schema-aware projection/read-model API) rather than only documenting a
  connection-settings convention.
  Rationale: User selection. The user asked directly whether users can create and configure
  a schema for projections; the answer today is "no." A first-class API closes the
  architecture gap the user identified instead of pushing the burden onto every application.
  Date: 2026-07-05

- Decision: Decompose into five child plans — schema/DDL rewrite (EP-1), runtime
  qualification (EP-2), expected-schema hygiene (EP-3), projection schema API (EP-4), docs
  and remediation runbook (EP-5) — with EP-1 as the sole root and EP-2/EP-3 parallelizable
  after it.
  Rationale: Functional-concern separation, dependency minimization, balanced scope, and
  independent verifiability, per the decomposition principles. See Decomposition Strategy
  for the alternatives rejected.
  Date: 2026-07-05

- Decision (coordination, surfaced during child-plan authoring): EP-1 regenerates an
  interim `kiroku`-scoped expected-schema snapshot when it relocates the tables, and EP-3
  produces the authoritative `keiro`-scoped snapshot with the deterministic pinned identity.
  Rationale: Moving `keiro_*` tables out of the `kiroku` namespace makes the pre-existing
  snapshot mismatch the live database. Without EP-1 regenerating, `keiro-migrations-test`
  goes red in the window between EP-1 and EP-3. Since EP-3 hard-depends on EP-1, the
  two-step (interim → authoritative) keeps the strict gate green throughout. Recorded in
  Integration Points → "The codd expected-schema snapshot."
  Date: 2026-07-05

- Decision (surfaced during authoring): The role/owner "leak" fix is to make the captured
  identity deterministic (pin ephemeral-pg's superuser to `keiro`), not to emit zero role
  files.
  Rationale: codd's strict on-disk gate always captures `SqlRole(connecting-user)` and the
  database owner; a snapshot with no roles is impossible while keeping the gate. Pinning the
  identity makes the snapshot machine-independent, which is the actual goal. This corrected
  the initial Vision wording ("no roles/ directory").
  Date: 2026-07-05

- Decision (surfaced during authoring): The configurable projection schema is a `schema`
  field on `ReadModel` only, delivered as Haskell-level config with no database column.
  Rationale: `InlineProjection`/`AsyncProjection` are opaque apply closures; a required
  schema field there would break keiro-dsl-generated code. Keeping it out of the database
  avoids a new migration and an EP-3 snapshot regeneration, minimizing cross-plan coupling.
  Date: 2026-07-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
