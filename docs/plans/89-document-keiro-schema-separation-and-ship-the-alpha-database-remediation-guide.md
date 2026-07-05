---
id: 89
slug: document-keiro-schema-separation-and-ship-the-alpha-database-remediation-guide
title: "Document keiro schema separation and ship the alpha database remediation guide"
kind: exec-plan
created_at: 2026-07-05T18:39:13Z
intention: "intention_01kwsrmsbsedqb0rh0vb41x04m"
master_plan: "docs/masterplans/12-keiro-schema-separation-and-migration-architecture-rework.md"
---

# Document keiro schema separation and ship the alpha database remediation guide

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Keiro is an event-sourcing and durable-workflow framework written in Haskell. It stores its
own bookkeeping in PostgreSQL tables whose names all begin with `keiro_` (for example
`keiro_snapshots`, `keiro_read_models`, `keiro_timers`, `keiro_outbox`, `keiro_inbox`,
`keiro_workflow_steps`). Historically those tables were created **inside the `kiroku`
PostgreSQL schema** — a *schema* being a named table namespace inside one database — which
is the private namespace of the separate event-store library **kiroku** that Keiro depends
on. The sibling ExecPlans of this initiative move Keiro's framework tables out of `kiroku`
and into a **dedicated `keiro` schema** that Keiro creates and owns, qualify every runtime
query and every migration statement as `keiro.<table>`, make the drift-detection snapshot
portable, and add a first-class way for an application to choose the schema its
projection/read-model tables live in.

This ExecPlan (EP-5, the last of five) owns the **prose and the release**: it rewrites every
user-facing document, the `keiro-migrations` package README, and the `keiro-migrations`
CHANGELOG so they describe the new `keiro`-schema world instead of the old `kiroku`-squatting
world, and it publishes a **human-facing upgrade runbook** for operators who already run an
alpha database created by `keiro-migrations 0.1.0.0` (whose tables are still in `kiroku`).
That runbook walks an operator, step by step, through the one-time remediation that EP-1
ships as an executable SQL script — relocating each `keiro_*` table from `kiroku` to `keiro`
and realigning the migration ledger — with verification and backup guidance so no data is
lost.

You can see this work is done when: (1) a full-text search for stale claims — for example
`grep -rn "kiroku" docs/user` combined with the checks in *Validation and Acceptance* —
returns no statement that Keiro's framework tables live in `kiroku`; (2) the migrations
README and `docs/user/migrations.md` show `CODD_SCHEMAS=keiro` and the qualified,
no-`search_path` migration convention; (3) a new page `docs/user/upgrading-to-the-keiro-schema.md`
exists and describes a complete, safe operator procedure that references EP-1's remediation
script by path; and (4) `keiro-migrations/CHANGELOG.md` carries an `[Unreleased]` entry that
names the breaking schema move and recommends the next version number.

This is a documentation-and-release plan. It changes Markdown and one CHANGELOG; it writes no
Haskell and ships no SQL of its own. It **references** EP-1's remediation script but does not
author it — that boundary is deliberate and is restated throughout.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-07-05): `docs/user/migrations.md` and `keiro-migrations/README.md` rewritten for the `keiro` schema, `CODD_SCHEMAS=keiro`, and the qualified/no-`search_path` convention; both link the upgrade runbook. `grep CODD_SCHEMAS=kiroku` in user docs/README → none; `=keiro` present in both.
- [x] M2 (2026-07-05): `docs/user/read-models-and-projections.md` updated with EP-4's **actual** API: `ReadModel.schema` field, `qualifiedTableName`, and the `Keiro.Connection` helpers (`qualifyTable`, `quoteIdentifier`, `withProjectionSchema`, `keiroConnectionSettings`, `ensureProjectionSchema`). Added a "Choosing Your Projection Schema" section with a worked example. The stale "Keiro does not create your application read-model tables" sentence reworded.
- [x] M3 (2026-07-05): Swept `docs/user`/`docs/guides`. Fixed `docs/user/durable-workflows.md` (workflow tables now say `keiro`); aligned `docs/guides/run-and-operate-jitsurei.md` and `docs/guides/project-read-models.md` with the `jitsurei` projection schema + `keiro` framework schema. Scoped drift check on user-facing docs is clean (the two remaining pattern hits are correct new prose).
- [x] M4 (2026-07-05): `docs/user/upgrading-to-the-keiro-schema.md` authored, wrapping the shipped script `keiro-migrations/remediation/2026-07-05-relocate-keiro-tables-to-keiro-schema.sql` with backup/verify/rollback steps; linked from `migrations.md`, `README.md`, and the CHANGELOG. **Corrected EP-5's authoring assumption**: the script lives under `remediation/` (not `ledger-fixups/`) and does **no** ledger realignment (filenames unchanged → codd re-runs nothing) — the runbook reflects the true CREATE SCHEMA + ALTER TABLE SET SCHEMA behavior.
- [x] M5 (2026-07-05): `keiro-migrations/CHANGELOG.md` `[Unreleased]` entry added — Breaking Changes (schema move, qualified DDL, portable `keiro`-scoped drift gate, configurable projection schema), an Upgrade note linking the runbook, and a `0.2.0.0` recommendation with PVP rationale.
- [x] M6 (2026-07-05): Consistency gate passed. User-facing drift check clean; `CODD_SCHEMAS=keiro` everywhere (no `=kiroku`); runbook exists and is linked from three places; no `TODO(EP-4)` markers in user docs; documented commands match the shipped EP-1/EP-2/EP-3/EP-4 invocations.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-05: EP-5's authoring-time assumption that the remediation script would
  live under `keiro-migrations/ledger-fixups/` and perform a codd-ledger
  realignment (`UPDATE codd_schema.sql_migrations …`) was **wrong**. As shipped by
  EP-1, the script is `keiro-migrations/remediation/2026-07-05-relocate-keiro-tables-to-keiro-schema.sql`
  and does only `CREATE SCHEMA IF NOT EXISTS keiro` + guarded
  `ALTER TABLE kiroku.<table> SET SCHEMA keiro`, wrapped in one transaction. codd
  keys applied status by filename and EP-1 kept every migration filename unchanged,
  so codd re-runs nothing and there is no ledger row to realign. The runbook
  (Milestone 4) documents the true behavior — no ledger step.
- 2026-07-05: EP-4's final API names (the largest open flag at authoring) resolved
  to a `schema :: Text` field on `ReadModel`, `qualifiedTableName` on
  `Keiro.ReadModel`, and the `Keiro.Connection` module exporting `qualifyTable`,
  `quoteIdentifier`, `withProjectionSchema`, `keiroConnectionSettings`, and
  `ensureProjectionSchema`. No database column and no migration — so no EP-3
  snapshot regeneration was triggered. Documented these exact names; no invented
  identifiers and no surviving `TODO(EP-4)` markers.
- 2026-07-05: The Validation drift-check regex over-matches when run against the
  whole `docs/` tree: it flags (a) the planning docs under `docs/plans/` and
  `docs/masterplans/`, which legitimately narrate the old `kiroku` state and the
  plan, and (b) two lines of correct *new* prose in `migrations.md`/`README.md`
  that mention both schemas in one sentence ("framework tables … distinct from
  kiroku's `kiroku` schema"). Scoping the check to the user-facing surfaces
  (`docs/user`, `docs/guides`, `keiro-migrations/README.md`) and reading the two
  hits confirmed no stale claim remains.


## Decision Log

Record every decision made while working on the plan.

- Decision: Publish the alpha-to-`keiro` upgrade procedure as a **dedicated page**,
  `docs/user/upgrading-to-the-keiro-schema.md`, linked prominently from
  `docs/user/migrations.md` and from the CHANGELOG, rather than inlining it as a section of
  `docs/user/migrations.md`.
  Rationale: The upgrade is a one-time, operationally sensitive procedure (it relocates
  tables and rewrites the migration ledger on a live database) that only existing alpha
  adopters run. Folding it into `migrations.md` — a page every new reader consults — would
  bury the day-to-day migration instructions under a scary one-time runbook and make the
  procedure harder to link to from the CHANGELOG's breaking-change note. A standalone page
  is discoverable, linkable, and self-contained, and it keeps `migrations.md` focused on the
  steady state.
  Date: 2026-07-05

- Decision: Recommend bumping `keiro-migrations` from `0.1.0.0` to **`0.2.0.0`** for the next
  release, and state the recommendation (with reasoning) in the CHANGELOG's `[Unreleased]`
  entry, without editing the `version:` field of `keiro-migrations/keiro-migrations.cabal` in
  this plan.
  Rationale: The change is breaking — a database created by `0.1.0.0` will not match the new
  migration history until the operator runs the remediation. The package declares it follows
  the Haskell Package Versioning Policy (PVP), where the first two components `A.B` form the
  "major" version and any breaking change must increment them. Bumping the second component
  (`0.1` → `0.2`) is the smallest PVP-correct major bump for a pre-1.0 package. The README
  already warns the API is unstable and under active development, so a pre-1.0 major bump is
  consistent with the project's stated maturity. The actual `.cabal` version edit belongs to
  whoever cuts the release (it is a release action, not a documentation action), so this plan
  records the recommendation rather than performing the bump.
  Date: 2026-07-05

- Decision: EP-5 may begin drafting once EP-1 (docs/plans/85) is finalized, but must be
  **finalized only after EP-2 (86), EP-3 (87), and EP-4 (88) land**, so that the documented
  API names, commands, and schema statements match the code as shipped.
  Rationale: EP-1 fixes the schema name (`keiro`), the migration convention, and the
  remediation script — the load-bearing facts EP-5's core prose and runbook depend on, so
  drafting can start there. But EP-2 finalizes the runtime-query convention and any
  cross-library qualification note, EP-3 finalizes the expected-schema/drift-gate commands
  and portability guarantee, and EP-4 finalizes the *exact* projection/read-model schema API
  names. Publishing EP-5's prose before those land risks documenting names that later change.
  Sequencing EP-5 last (as the MasterPlan's dependency graph requires) removes that risk.
  Date: 2026-07-05

- Decision: EP-5 references EP-1's remediation SQL script **by repository path** and does not
  reproduce or author its SQL body.
  Rationale: The MasterPlan assigns the executable, tested remediation script to EP-1 (a
  sibling of the existing `keiro-migrations/ledger-fixups/` artifacts) and assigns only the
  human-facing runbook narrative to EP-5. Keeping the SQL in one place prevents the runbook
  and the script from drifting apart; the runbook's job is to explain *when*, *why*, and
  *how to verify*, pointing at the single source of truth for *what* runs.
  Date: 2026-07-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- 2026-07-05 (completion): The prose and release story now describe the
  `keiro`-schema world. `docs/user/migrations.md` and `keiro-migrations/README.md`
  document the dedicated `keiro` schema, `CODD_SCHEMAS=keiro`, the
  qualified/no-`search_path` convention, and the portable drift gate;
  `docs/user/read-models-and-projections.md` documents EP-4's configurable
  projection schema with real API names; `docs/user/durable-workflows.md` and the
  jitsurei/read-model guides no longer claim framework tables live in `kiroku`; the
  new `docs/user/upgrading-to-the-keiro-schema.md` runbook gives a complete, safe
  operator procedure wrapping the shipped remediation script; and
  `keiro-migrations/CHANGELOG.md` records the breaking change and recommends
  `0.2.0.0`. All acceptance greps pass on the user-facing surfaces. This closes
  MasterPlan 12. The one substantive correction from the plan-as-authored — the
  remediation does no ledger realignment — is recorded above and reflected in the
  runbook and CHANGELOG.
- Scope note (matches EP-4's decision): the jitsurei example migrates only
  `jitsurei_order_summary` to the `jitsurei` schema; the docs describe that as the
  worked example and do not imply the two secondary jitsurei read models moved.


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

**What Keiro is.** Keiro is an event-sourcing framework and durable-workflow engine written
in Haskell. Its packages live under the repository root `/Users/shinzui/Keikaku/bokuno/keiro`
(referred to below by repository-relative paths). The `keiro` package holds the runtime; the
`keiro-migrations` package holds the database migrations and the `keiro-migrate` command-line
tool; `jitsurei` is a worked-example application used by the guides.

**What a PostgreSQL schema is.** A *schema* is a named namespace for tables inside a single
PostgreSQL database. A table can be addressed *unqualified* (`keiro_inbox`) or *qualified*
with its schema (`keiro.keiro_inbox`). An unqualified name is resolved against the
connection's `search_path`, an ordered list of schemas PostgreSQL searches. If two schemas
both could contain the name, `search_path` order decides which one wins — which is why
unqualified DDL is fragile.

**The two libraries and their schemas.** Keiro depends on a separate event-store library
called **kiroku** (the dependency `shinzui/kiroku`). kiroku creates and owns a schema named
`kiroku` and puts its own tables there (`streams`, `events`, `stream_events`,
`subscriptions`, `dead_letters`) plus a `kiroku.events` `LISTEN`/`NOTIFY` channel used for
push notifications. Historically, Keiro created *its* tables in kiroku's `kiroku` schema too —
it had no schema of its own. Every Keiro migration under
`keiro-migrations/sql-migrations/` opened with `SET search_path TO kiroku, pg_catalog;` and
then ran *unqualified* `CREATE TABLE keiro_*` statements, so the tables landed in `kiroku`.
This "squatting" is what the whole initiative removes.

**codd, the migration runner.** Keiro uses a migration tool called **codd**. codd applies
ordered SQL migration files and records which have run in a ledger table
(`codd_schema.sql_migrations`, keyed by file `name`). It can also compare the live database
against a checked-in *expected-schema* snapshot (a directory tree under
`keiro-migrations/expected-schema/`) to detect drift. The strict drift check runs as
`cabal test keiro-migrations-test`. codd is configured through environment variables,
notably `CODD_SCHEMAS`, which lists the schema(s) codd inspects. Today the docs pass
`CODD_SCHEMAS=kiroku`; after this initiative it becomes `CODD_SCHEMAS=keiro`.

**The `keiro-migrate` executable.** `keiro-migrations/app/Main.hs` builds a tool named
`keiro-migrate`. Run without arguments (with the `CODD_*` environment variables set) it
applies the embedded migrations. Run as `keiro-migrate new <description>` it scaffolds a new
timestamped migration file via `keiro-migrations/src/Keiro/Migrations/New.hs`. Today that
scaffolder emits a template containing the `SET search_path TO kiroku, pg_catalog;` pin and a
five-line explanatory comment; EP-1 rewrites the template to emit a qualified, comment-free
body. (EP-5 does not touch that Haskell; it only documents the resulting convention.)

**The sibling ExecPlans (the initiative this plan closes).** This plan is EP-5 of MasterPlan
`docs/masterplans/12-keiro-schema-separation-and-migration-architecture-rework.md`. The other
four, all under `docs/plans/`, are:

- **EP-1** — `docs/plans/85-rewrite-keiro-migrations-to-own-a-dedicated-keiro-schema-with-qualified-ddl.md`.
  Gives Keiro a dedicated `keiro` schema. Its bootstrap migration issues
  `CREATE SCHEMA IF NOT EXISTS keiro;`; every migration creates tables qualified
  `keiro.<table>` with no `SET search_path` and no explanatory comment; the
  `keiro-migrate new` scaffolder emits that qualified, comment-free template; and it ships a
  one-time remediation SQL script (a sibling of
  `keiro-migrations/ledger-fixups/2026-07-05-realign-keiro-migration-timestamps.sql`) that
  relocates an existing alpha database's tables from `kiroku` to `keiro` and realigns codd's
  ledger. **This plan hard-depends on EP-1** for the schema name, the migration convention,
  and the remediation-script path.

- **EP-2** — `docs/plans/86-qualify-all-keiro-framework-runtime-queries-with-the-keiro-schema.md`.
  Rewrites every Keiro runtime SQL query to `keiro.<table>` so the runtime no longer relies
  on `search_path` for its own tables. It also fixes the convention for cross-library
  references to kiroku-owned tables (for example `subscriptions`) — a fact EP-5 may need to
  mention. **Soft dependency.**

- **EP-3** — `docs/plans/87-scope-codd-expected-schema-to-the-keiro-namespace-and-remove-the-role-and-owner-leak.md`.
  Scopes the codd expected-schema to the `keiro` namespace so the snapshot contains only
  `keiro_*` objects and leaks no local database role or owner, making
  `cabal test keiro-migrations-test` pass on any machine. **Soft dependency** — EP-5's
  "Updating the expected schema" prose reflects its final state.

- **EP-4** — `docs/plans/88-add-first-class-configurable-projection-and-read-model-schema-support.md`.
  Adds a first-class, configurable projection/read-model schema: applications declare which
  schema their read-model/projection tables live in, and Keiro targets it directly (possibly
  via a new field on the `ReadModel`/projection records and/or a connection-settings helper).
  **Soft dependency** — EP-5's `docs/user/read-models-and-projections.md` rewrite depends on
  EP-4's *final API names*.

**Status of the sibling plans at the time this plan was authored.** EP-1 through EP-4 are all
still skeletons (their bodies are the unfilled template). This plan therefore describes their
*intended final state* from the MasterPlan's Vision & Scope and Integration Points, and it
flags every place where a concrete name or command must be confirmed against the sibling plan
once that plan is fleshed out. The single most important such flag: **EP-4's exact API names
for the configurable projection schema are not yet decided; Milestone 2 must pull the final
names from EP-4 and must not invent them.**

**The files this plan edits.** All are documentation or the changelog:

- `docs/user/migrations.md` — currently says "Kiroku owns the event-store tables in the
  `kiroku` PostgreSQL schema" and "Keiro owns framework metadata tables in the same `kiroku`
  schema", and shows `CODD_SCHEMAS=kiroku`. Must move Keiro's tables to `keiro`, change
  `CODD_SCHEMAS`, describe the qualified/no-`search_path` convention, and link the new
  upgrade runbook.
- `keiro-migrations/README.md` — currently shows `CODD_SCHEMAS=kiroku` and explains that
  Keiro's framework tables share kiroku's schema. Must match `migrations.md`'s new story.
- `docs/user/read-models-and-projections.md` — currently shows the `ReadModel` record with no
  schema field and states "Keiro does not create your application read-model tables. Your
  migrations own those tables." Must document EP-4's configurable projection schema.
- `docs/user/durable-workflows.md` — line ~120 says the runtime "keeps two tables in the
  `kiroku` schema: `keiro_workflow_steps` … and `keiro_awakeables`". Must say `keiro`.
- `docs/guides/run-and-operate-jitsurei.md` — describes Keiro framework tables versus
  application query tables; align its projection/read-model schema wording with EP-4.
- `docs/guides/project-read-models.md` — shows the `ReadModel` example; align with EP-4 if the
  record shape changes.
- `keiro-migrations/CHANGELOG.md` — add the `[Unreleased]` breaking-change entry and the
  version-bump recommendation.
- **New file** `docs/user/upgrading-to-the-keiro-schema.md` — the runbook.

**Docs that mention `kiroku` but need NO edit (verified).** A repository grep for `kiroku`
returns many hits; most are about the *event store*, not Keiro's framework tables, and are
correct as-is. Confirmed benign: `docs/user/getting-started.md` line 12 ("Kiroku's schema
uses `uuidv7()`") and line 13 ("Kiroku and Keiro schemas applied in the target database" —
this is now *more* accurate, since there truly are two schemas); `docs/user/operations.md`
line 9 ("Kiroku's schema requires PostgreSQL 18"); `docs/user/production-status.md` and
`docs/user/roadmap.md` (kiroku consumer-group/subscription references);
`docs/guides/integration-events-with-kafka.md` and `docs/guides/durable-workflows.md`
(kiroku *streams*, not schema-location claims). These are enumerated so the sweep in
Milestone 3 does not accidentally "fix" correct prose. If any of them is edited, it is only
to add clarity, never to change a true statement.


## Plan of Work

The work is six milestones. Milestones 1 and 3–5 depend only on EP-1's finalized facts (the
`keiro` schema name, the qualified/no-`search_path` migration convention, the remediation
script's path and behavior) and can be drafted as soon as EP-1 is fleshed out. Milestone 2
depends on EP-4's final API names and must be completed (or reconciled) after EP-4 lands.
Milestone 6 is the final consistency gate and runs last.


### Milestone 1 — Rewrite the migration docs for the `keiro` schema

**Scope and outcome.** After this milestone, `docs/user/migrations.md` and
`keiro-migrations/README.md` describe the new world: Keiro owns a dedicated `keiro` schema,
migrations are schema-qualified `keiro.<table>` with no `SET search_path` pin and no
explanatory comment, the drift-check environment uses `CODD_SCHEMAS=keiro`, and readers are
pointed to the upgrade runbook (created in Milestone 4).

**Edits to `docs/user/migrations.md`.** In the opening two bullets (currently lines 5–9),
change the second bullet so Keiro's framework tables live in a dedicated `keiro` schema, not
in `kiroku`. Concretely the prose should read to the effect of: "Kiroku owns the event-store
tables (`streams`, `events`, `stream_events`, `subscriptions`) in the `kiroku` PostgreSQL
schema. Keiro owns its framework metadata tables (`keiro_snapshots`, `keiro_read_models`,
`keiro_timers`, `keiro_outbox`, `keiro_inbox`, and the workflow tables) in a **dedicated
`keiro` PostgreSQL schema that Keiro's bootstrap migration creates and owns**. The two
schemas are separate namespaces in the same database." Add a sentence explaining that every
Keiro migration now creates its tables schema-qualified as `keiro.<table>` and does **not**
set `search_path`, so tables can never accidentally land in `public` or `kiroku` on an
incremental upgrade.

In the "Run The Migration" code block (currently lines 41–47), change `CODD_SCHEMAS=kiroku`
to `CODD_SCHEMAS=keiro`. In the following paragraph (currently lines 49–53), change the
explanation of `CODD_SCHEMAS` so it reads that `CODD_SCHEMAS=keiro` tells codd to check the
dedicated `keiro` schema that Keiro's framework tables live in. Note that codd applies
Kiroku's embedded migrations first (which create the `kiroku` schema and event-store tables)
and then Keiro's embedded migrations (which create the `keiro` schema and framework tables)
in one ordered ledger. If EP-3's final drift-gate story requires codd to inspect both `kiroku`
and `keiro` (for example if the check must still see kiroku's tables), confirm the exact
`CODD_SCHEMAS` value against EP-3 (`docs/plans/87`) before finalizing — see the flag in
*Interfaces and Dependencies*. The default assumption, from the MasterPlan Integration Points
("EP-3 must set codd `namespacesToCheck = IncludeSchemas [SqlSchema "keiro"]`"), is that the
drift gate is scoped to `keiro` alone.

In the "Application Tables" section (currently lines 76–88), keep the message that Keiro
migrations cover only Keiro-owned framework tables, and add a forward reference to the new
configurable projection schema (Milestone 2 / EP-4): applications can now declare the schema
their read-model and projection tables live in, so they need not co-mingle with either
`kiroku` or `keiro`.

At the end of `docs/user/migrations.md`, add a short "Upgrading an existing alpha database"
section that links to `docs/user/upgrading-to-the-keiro-schema.md` (created in Milestone 4)
and states in one or two sentences: databases first migrated by `keiro-migrations 0.1.0.0`
have their `keiro_*` tables in `kiroku`; before running the new migrations against such a
database, follow the upgrade runbook once to relocate the tables and realign the ledger.

**Edits to `keiro-migrations/README.md`.** Mirror the same three changes: (1) change
`CODD_SCHEMAS=kiroku` to `CODD_SCHEMAS=keiro` in the code block (currently lines 15–21); (2)
rewrite the paragraph that currently says `CODD_SCHEMAS=kiroku` "matches the dedicated schema
that latest Kiroku uses for its event-store tables and that Keiro uses for framework tables"
(currently lines 23–28) so it says `CODD_SCHEMAS=keiro` matches the dedicated `keiro` schema
Keiro creates and owns for its framework tables, distinct from kiroku's `kiroku` event-store
schema; (3) add a sentence to the intro that Keiro migrations create their tables qualified
`keiro.<table>` and do not pin `search_path`. Add a one-line pointer to the upgrade runbook
for existing `0.1.0.0` databases.

**Commands to run (verification for this milestone).** From the repository root
`/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
grep -n "CODD_SCHEMAS" docs/user/migrations.md keiro-migrations/README.md
grep -rn "kiroku" docs/user/migrations.md keiro-migrations/README.md
```

**Acceptance.** The first grep shows `CODD_SCHEMAS=keiro` in both files and no
`CODD_SCHEMAS=kiroku`. The second grep's only remaining `kiroku` hits are statements about
kiroku's *event-store* tables/schema (e.g. "Kiroku owns the event-store tables in the
`kiroku` schema"), never a claim that a `keiro_*` table lives in `kiroku`.


### Milestone 2 — Document EP-4's configurable projection/read-model schema

**Scope and outcome.** After this milestone, `docs/user/read-models-and-projections.md`
explains that an application can choose the PostgreSQL schema its read-model and projection
tables live in, using EP-4's first-class API, instead of implicitly inheriting the store
connection's `search_path`. This milestone is **blocked on EP-4's final API names** and must
not invent them.

**What EP-4 delivers (from the MasterPlan, to be confirmed against `docs/plans/88`).** The
read-model and projection APIs today (`Keiro.ReadModel`, `Keiro.Projection`) carry **no
schema field**; Keiro creates none of the application's read-model tables; and where those
tables land is decided solely by the store connection's `search_path` (default `kiroku`). The
MasterPlan's Vision & Scope states the end state: "Applications gain a first-class,
configurable projection/read-model schema: a user can declare the schema their read-model and
projection tables live in, and Keiro targets it directly." The Integration Points section
notes EP-4 may introduce a connection-settings helper (the MasterPlan uses the placeholder
name `keiroConnectionSettings`) and may or may not add a database column (for example a schema
column on `keiro_read_models`); if it adds a column it becomes an EP-1 migration plus an EP-3
snapshot regeneration.

**Edits to `docs/user/read-models-and-projections.md`.** Update the `ReadModel` record code
block (currently lines 16–26) to include EP-4's schema field **if EP-4 adds one to the
record**, using EP-4's exact field name and type. Replace the sentence "Keiro does not create
your application read-model tables. Your migrations own those tables, indexes, and row codecs."
(currently lines 30–32) with prose describing the new capability: you declare the schema your
read-model/projection tables live in (name the exact API — a record field, a
connection-settings helper, or both, per EP-4), Keiro targets that schema, and your migrations
still own the table *definitions* within it. Add a short subsection, near "Initialize
Metadata", titled to the effect of "Choosing your projection schema" that names the concrete
knob and shows a minimal example using EP-4's real identifiers. In the "Async Projections"
and "Inline Projections" sections, ensure any example SQL or narrative that assumes an
implicit schema is reconciled with the configurable one.

**Placeholder handling until EP-4 lands.** Because EP-4 is a skeleton at authoring time, this
milestone's edit must either wait for EP-4 or be drafted with the exact identifiers left as an
explicit, greppable TODO marker (for example `TODO(EP-4): confirm field name`) so the
finalization pass cannot forget to substitute them. Do **not** publish invented names. Record
in the Decision Log and Surprises & Discoveries which names were pulled from EP-4 and when.

**Commands to run (verification).** From the repository root:

```bash
grep -n "does not create your application read-model" docs/user/read-models-and-projections.md
grep -rn "TODO(EP-4)" docs/user docs/guides
```

**Acceptance.** The first grep returns nothing (the stale sentence is gone). The second grep
returns nothing at finalization time (every EP-4 placeholder has been replaced with the real
API name). The page shows, with EP-4's exact identifiers, how to place read-model/projection
tables in a chosen schema.


### Milestone 3 — Sweep the remaining docs for stale `kiroku`-schema claims

**Scope and outcome.** After this milestone, no page in `docs/` claims that a Keiro framework
table lives in the `kiroku` schema. The known offenders are fixed and the benign `kiroku`
mentions (enumerated in *Context and Orientation*) are left intact.

**Edits.** In `docs/user/durable-workflows.md`, change the sentence at line ~120 that reads
"The runtime keeps two tables in the `kiroku` schema: `keiro_workflow_steps` … and
`keiro_awakeables`" so it names the `keiro` schema instead. In
`docs/guides/run-and-operate-jitsurei.md` (the operations guide for the worked example),
review the section (currently ~lines 30–46) that contrasts Keiro-owned framework tables with
the application's own query tables; ensure it does not imply the framework tables live in
`kiroku`, and, where it discusses the example's `jitsurei_order_summary` read-model table,
align it with EP-4's configurable projection schema (the MasterPlan requires the jitsurei
read-model table to live in a user-configured schema, not `kiroku`). In
`docs/guides/project-read-models.md`, if EP-4 changes the `ReadModel` record shape shown in
the example (currently ~line 19), update the example to match; otherwise leave it.

**Verify no other offenders exist.** Run the enumerating grep below and inspect every hit.
Any hit that asserts a `keiro_*` table (or "framework tables", "read-model tables",
"projections") lives in `kiroku` must be fixed; any hit about kiroku's own event store,
streams, or NOTIFY channel is correct and left alone.

**Commands to run (verification).** From the repository root:

```bash
grep -rn "kiroku" docs/user docs/guides
grep -rniE "keiro[_a-z]* (table|tables).*kiroku|kiroku (schema|namespace).*keiro" docs/user docs/guides
```

**Acceptance.** The second grep (which targets the specific "keiro-table-in-kiroku" pattern)
returns nothing. The first grep's remaining hits are all, on inspection, about kiroku's event
store — verified against the benign list in *Context and Orientation*.


### Milestone 4 — Author the alpha-database upgrade runbook

**Scope and outcome.** After this milestone, `docs/user/upgrading-to-the-keiro-schema.md`
exists and gives an operator of an existing `keiro-migrations 0.1.0.0` database a complete,
safe, step-by-step procedure to move their `keiro_*` tables from `kiroku` to `keiro` without
data loss, wrapping EP-1's remediation script, with pre-flight backup guidance, verification
steps, and a rollback note. The page is linked from `docs/user/migrations.md` (Milestone 1)
and from the CHANGELOG (Milestone 5).

**Why the runbook exists.** `keiro-migrations 0.1.0.0` shipped on 2026-07-05 with tables in
`kiroku`. The new migration history (EP-1) creates tables in `keiro`. A database created by
`0.1.0.0` therefore has its `keiro_*` tables in the wrong schema *and* a codd ledger recorded
against the old migration history. Running the new migrations against such a database without
remediation would misbehave (codd would see the new bootstrap as pending, or the app's
qualified `keiro.<table>` queries would find no table). The remediation script (EP-1) fixes
both problems in one transaction: it creates the `keiro` schema, moves each `keiro_*` table
with `ALTER TABLE kiroku.<table> SET SCHEMA keiro`, and realigns codd's ledger so codd treats
the relocated history as already applied. The runbook explains *when*, *why*, and *how to
verify* — it does not restate the SQL.

**Runbook contents.** Write the page as prose with fenced command blocks. It must cover, in
order:

1. **Who needs this.** Only operators of a *persistent* database first migrated by
   `keiro-migrations 0.1.0.0` (staging, production, or a long-lived local database). State
   explicitly that **ephemeral or template-per-suite test databases do not need it** — they
   are created from scratch by the new migrations and already land in `keiro`. This mirrors
   the "WHEN TO RUN" note in the existing ledger-fixup at
   `keiro-migrations/ledger-fixups/2026-07-05-realign-keiro-migration-timestamps.sql`.

2. **What it does.** In one transaction: `CREATE SCHEMA IF NOT EXISTS keiro`; for each
   `keiro_*` table currently in `kiroku`, `ALTER TABLE kiroku.<table> SET SCHEMA keiro`
   (which moves the table and its data, indexes, and constraints as a metadata-only operation
   — no rows are copied); and an `UPDATE codd_schema.sql_migrations …` realignment so codd's
   ledger reflects the relocated history. State plainly: this relocates tables and rewrites
   codd bookkeeping only; it never drops, truncates, or copies row data, so it cannot lose
   data.

3. **Pre-flight: back up first.** Instruct the operator to take a backup (or a database
   snapshot) before running anything, and to run during a maintenance window with application
   writers stopped, because the `SET SCHEMA` operations take brief locks. Give the exact
   backup command shape:

   ```bash
   pg_dump --format=custom --file=keiro-pre-upgrade.dump \
     "host=/tmp port=5432 dbname=keiro user=keiro_admin"
   ```

4. **Run the remediation script.** Point at EP-1's script by its repository path (confirm the
   exact filename against EP-1 / `docs/plans/85` when finalizing — see the flag in
   *Interfaces and Dependencies*; the expected location is
   `keiro-migrations/ledger-fixups/<date>-relocate-keiro-tables-to-keiro-schema.sql` or a
   similarly named sibling of the existing ledger-fixup). Show the exact `psql` invocation to
   apply it inside a transaction:

   ```bash
   psql "host=/tmp port=5432 dbname=keiro user=keiro_admin" \
     --single-transaction \
     --file=keiro-migrations/ledger-fixups/<the-remediation-script>.sql
   ```

   Explain that the script is itself wrapped in `BEGIN`/`COMMIT` and is idempotent, so a
   second run is a safe no-op (it matches no rows), exactly like the existing
   timestamp-realignment fixup.

5. **Run the new migrations.** After remediation, apply the current migrations the normal way
   (the `keiro-migrate` invocation from `docs/user/migrations.md`, with
   `CODD_SCHEMAS=keiro`). State the expected result: because the tables are already in `keiro`
   and the ledger is realigned, this run makes no schema changes — it is effectively a no-op
   that simply confirms the ledger is consistent.

6. **Verify success.** Give the operator concrete checks and their expected output:

   ```sql
   -- Every keiro_* table now lives in `keiro`, none remain in `kiroku`.
   SELECT table_schema, table_name
   FROM information_schema.tables
   WHERE table_name LIKE 'keiro\_%'
   ORDER BY table_schema, table_name;
   ```

   The expected result is that every `keiro_*` row shows `table_schema = keiro` and none show
   `kiroku`. Then confirm a subsequent `keiro-migrate` is a no-op and that the application
   starts and reads/writes its `keiro.<table>` tables normally. State that "the app starts and
   serves traffic against the relocated tables" is the ultimate acceptance signal.

7. **Rollback / recovery.** If verification fails, restore from the pre-flight backup:

   ```bash
   pg_restore --clean --if-exists --dbname=keiro keiro-pre-upgrade.dump
   ```

   Note that because the remediation is a single transaction, a failure mid-script leaves the
   database unchanged (all-or-nothing); the backup covers the case where a *later* step (the
   migration run or app start) reveals a problem.

**Link the page.** Add the link from `docs/user/migrations.md` (done in Milestone 1) and from
the CHANGELOG entry (Milestone 5). Optionally cross-link from
`keiro-migrations/README.md`'s upgrade pointer.

**Commands to run (verification).** From the repository root:

```bash
test -f docs/user/upgrading-to-the-keiro-schema.md && echo "runbook present"
grep -n "upgrading-to-the-keiro-schema" docs/user/migrations.md keiro-migrations/CHANGELOG.md
```

**Acceptance.** The file exists; both linking files reference it. A reader following the page
can, against a `0.1.0.0`-seeded database, relocate the tables, run the migrations to a no-op,
verify with the SQL above that no `keiro_*` table remains in `kiroku`, and start the app.


### Milestone 5 — CHANGELOG breaking-change entry and version-bump recommendation

**Scope and outcome.** After this milestone, `keiro-migrations/CHANGELOG.md` has an
`[Unreleased]` entry documenting the breaking schema move and recommending the next version
number, replacing the current placeholder `_No unreleased changes._`.

**Edits to `keiro-migrations/CHANGELOG.md`.** Replace the `[Unreleased]` body (currently
line 9, `_No unreleased changes._`) with an entry that follows the file's existing
Keep-a-Changelog style (the file already declares Keep a Changelog and PVP). The entry must:

- Under a `### Breaking Changes` heading, state that Keiro's framework tables moved from the
  `kiroku` schema into a new dedicated `keiro` schema; that all migrations are now
  schema-qualified `keiro.<table>` and no longer set `search_path`; that the codd
  expected-schema/drift gate is scoped to the `keiro` namespace and is now portable (no local
  role/owner leak); and that read-model/projection tables now support a configurable schema
  (EP-4). Note that an existing `0.1.0.0` database requires a one-time remediation and link
  the runbook `docs/user/upgrading-to-the-keiro-schema.md`.
- Under a short `### Upgrade` note (or within the breaking-changes text), point operators to
  the runbook by path.
- Recommend the next release be **`0.2.0.0`**, and state the reasoning inline: this is a
  breaking change; the package follows the Haskell PVP where the leading `A.B` components form
  the major version and must increment on a breaking change; `0.1` → `0.2` is the minimal
  PVP-correct major bump for a pre-1.0 package; and the README already warns the API is
  unstable/alpha, so a pre-1.0 major bump is appropriate. Note that the actual `version:` edit
  in `keiro-migrations/keiro-migrations.cabal` is a release action to be performed when the
  release is cut, not part of this documentation change.

**Commands to run (verification).** From the repository root:

```bash
sed -n '/## \[Unreleased\]/,/## 0.1.0.0/p' keiro-migrations/CHANGELOG.md
grep -n "0.2.0.0\|Breaking\|upgrading-to-the-keiro-schema" keiro-migrations/CHANGELOG.md
```

**Acceptance.** The `[Unreleased]` section names the breaking schema move, recommends
`0.2.0.0` with reasoning, and links the runbook.


### Milestone 6 — Final consistency gate

**Scope and outcome.** A single pass that proves the documentation is internally consistent
and that every command shown matches the final sibling-plan invocations. This milestone runs
after EP-2, EP-3, and EP-4 have landed (per the Decision Log sequencing) so the confirmed
names and commands are final.

**Checks.** Run the grep-based drift check (see *Validation and Acceptance*) and confirm it is
clean. Cross-check every command shown in the docs against the sibling plans as fleshed out:
the migration/drift commands (`cabal run keiro-write-expected-schema`,
`cabal test keiro-migrations-test`, the `keiro-migrate` invocation with `CODD_SCHEMAS=keiro`)
against EP-1/EP-3; the runtime qualification note against EP-2; and the projection-schema API
identifiers against EP-4. Remove any lingering `TODO(EP-4)` marker.

**Acceptance.** The drift check is clean, no `TODO(EP-*)` markers remain, and every documented
command matches its owning sibling plan.


## Concrete Steps

Run all commands from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless stated
otherwise. This plan edits Markdown and one CHANGELOG only; there is nothing to compile.

1. **Survey the current state** (before editing), so you can compare afterward:

   ```bash
   grep -rn "CODD_SCHEMAS" docs/user/migrations.md keiro-migrations/README.md
   grep -rn "kiroku" docs/user docs/guides
   ```

   Expected before editing: `CODD_SCHEMAS=kiroku` appears in both files;
   `docs/user/migrations.md`, `docs/user/durable-workflows.md`, and
   `docs/guides/run-and-operate-jitsurei.md` contain the stale schema claims described above.

2. **Milestone 1** — edit `docs/user/migrations.md` and `keiro-migrations/README.md` as
   described. Re-run:

   ```bash
   grep -n "CODD_SCHEMAS" docs/user/migrations.md keiro-migrations/README.md
   ```

   Expected after: `CODD_SCHEMAS=keiro` in both; no `CODD_SCHEMAS=kiroku` anywhere.

3. **Milestone 2** — edit `docs/user/read-models-and-projections.md` using EP-4's final API
   names (or leave `TODO(EP-4)` markers if EP-4 has not landed yet). Re-run the Milestone 2
   verification greps.

4. **Milestone 3** — edit `docs/user/durable-workflows.md`,
   `docs/guides/run-and-operate-jitsurei.md`, and (if needed) `docs/guides/project-read-models.md`.
   Run the Milestone 3 verification greps and inspect every remaining `kiroku` hit.

5. **Milestone 4** — create `docs/user/upgrading-to-the-keiro-schema.md` with the full runbook
   and add its link to `docs/user/migrations.md`. Confirm the remediation-script filename
   against EP-1 (`docs/plans/85`).

6. **Milestone 5** — edit `keiro-migrations/CHANGELOG.md`'s `[Unreleased]` section.

7. **Milestone 6** — run the full drift check from *Validation and Acceptance* and reconcile
   every command against the finalized sibling plans.

8. **Commit.** Use Conventional Commits and the required trailers. Example:

   ```text
   docs(schema-separation): document the keiro schema and ship the alpha upgrade runbook

   Update migrations, read-model, and workflow docs plus the migrations README for
   the dedicated `keiro` schema; add the alpha-database upgrade runbook; record the
   breaking change and recommended version bump in the CHANGELOG.

   MasterPlan: docs/masterplans/12-keiro-schema-separation-and-migration-architecture-rework.md
   ExecPlan: docs/plans/89-document-keiro-schema-separation-and-ship-the-alpha-database-remediation-guide.md
   Intention: intention_01kwsrmsbsedqb0rh0vb41x04m
   ```

   Commit directly to the current branch (do not create a feature branch unless asked).


## Validation and Acceptance

Validation for a documentation plan is a set of greps that prove no stale claim remains, plus
a manual read-through that proves the runbook is followable. All commands run from the
repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

**The drift check.** This is the single command a reader runs to confirm no stale schema
reference remains:

```bash
grep -rniE "keiro[_a-z]* (table|tables|metadata).*kiroku|kiroku (schema|namespace)[^.]*keiro_|framework (table|tables).*kiroku" docs keiro-migrations/README.md
```

Expected output: nothing. Any hit is a place still claiming Keiro's tables live in `kiroku`
and must be fixed.

**The `CODD_SCHEMAS` check.**

```bash
grep -rn "CODD_SCHEMAS=kiroku" docs keiro-migrations/README.md
grep -rn "CODD_SCHEMAS=keiro"  docs/user/migrations.md keiro-migrations/README.md
```

Expected: the first returns nothing; the second returns a hit in each file.

**The runbook-exists and linkage check.**

```bash
test -f docs/user/upgrading-to-the-keiro-schema.md && echo OK
grep -n "upgrading-to-the-keiro-schema" docs/user/migrations.md keiro-migrations/CHANGELOG.md
```

Expected: prints `OK`, and both files reference the runbook.

**The CHANGELOG check.**

```bash
grep -n "Breaking\|0.2.0.0\|keiro schema\|upgrading-to-the-keiro-schema" keiro-migrations/CHANGELOG.md
```

Expected: the `[Unreleased]` entry names the breaking change, recommends `0.2.0.0`, and links
the runbook.

**The command-parity check (manual, at finalization).** Read the fleshed-out EP-1
(`docs/plans/85`), EP-2 (`docs/plans/86`), EP-3 (`docs/plans/87`), and EP-4 (`docs/plans/88`)
and confirm that every command and identifier this plan's docs show matches them: the
`keiro-migrate` invocation and `CODD_SCHEMAS=keiro`; `cabal run keiro-write-expected-schema`
and `cabal test keiro-migrations-test`; the remediation-script filename and path; and EP-4's
projection-schema API names. Confirm no `TODO(EP-4)` marker survives:

```bash
grep -rn "TODO(EP-4)" docs
```

Expected: nothing at finalization.

**Manual read-through.** A reviewer reads `docs/user/upgrading-to-the-keiro-schema.md`
end-to-end and confirms it is a complete operator procedure: who needs it, backup first, run
the (referenced) script, run the migrations to a no-op, verify with the SQL query that no
`keiro_*` table remains in `kiroku`, and roll back from backup if needed. Acceptance is that
an operator could follow it against a `0.1.0.0`-seeded database and end with every `keiro_*`
table in `keiro`, a no-op `keiro-migrate`, and a running application.


## Idempotence and Recovery

Every step in this plan is idempotent because it edits text. Re-running an edit that has
already been made is a no-op (the target string is already changed); re-running a grep is
always safe. Creating `docs/user/upgrading-to-the-keiro-schema.md` a second time simply
overwrites it with the same content. If a sibling plan's final names change after this plan is
finalized, re-open the affected milestone, re-apply the greps, and update the identifiers —
the plan's checks will surface the drift.

The *procedure this plan documents* (the runbook) is itself designed to be idempotent and
recoverable, and the runbook says so explicitly: EP-1's remediation script is wrapped in a
single transaction (all-or-nothing) and is idempotent (a second run matches no rows), exactly
like the existing `keiro-migrations/ledger-fixups/2026-07-05-realign-keiro-migration-timestamps.sql`;
the runbook mandates a `pg_dump` backup before any change and gives a `pg_restore` rollback
path. No step in this documentation plan touches a database.


## Interfaces and Dependencies

This plan produces documentation, so its "interfaces" are the files it must leave in a
consistent state and the sibling-plan facts it must quote correctly.

**Files that must exist / be updated at the end.**

- `docs/user/migrations.md` — `keiro` schema, `CODD_SCHEMAS=keiro`, qualified/no-`search_path`
  convention, link to the upgrade runbook.
- `keiro-migrations/README.md` — same `CODD_SCHEMAS=keiro` and convention story.
- `docs/user/read-models-and-projections.md` — EP-4's configurable projection/read-model
  schema, with EP-4's exact API names.
- `docs/user/durable-workflows.md` — workflow tables described as living in `keiro`.
- `docs/guides/run-and-operate-jitsurei.md`, `docs/guides/project-read-models.md` — read-model
  wording aligned with EP-4.
- `docs/user/upgrading-to-the-keiro-schema.md` — the new runbook (created by this plan).
- `keiro-migrations/CHANGELOG.md` — `[Unreleased]` breaking-change entry and `0.2.0.0`
  recommendation.

**Hard dependency: EP-1 (`docs/plans/85`).** This plan cannot be finalized until EP-1 fixes
three load-bearing facts and they are read from the fleshed-out EP-1: (1) the schema name is
literally `keiro`; (2) the migration convention is qualified `keiro.<table>` with no
`SET search_path` and no explanatory comment, emitted by the `keiro-migrate new` scaffolder;
and (3) the remediation script's exact filename and path under
`keiro-migrations/ledger-fixups/`. The runbook (Milestone 4) references that script by path;
**the exact filename is a flagged TODO** until EP-1 is fleshed out — confirm it before
publishing the runbook. This plan does not author or reproduce the script's SQL.

**Soft dependency: EP-2 (`docs/plans/86`).** EP-2 finalizes the runtime-query qualification
and the convention for cross-library references to kiroku-owned tables (for example
`subscriptions` and the `kiroku.events` NOTIFY channel, which per the MasterPlan cannot be
repointed away from `kiroku`). If any doc describes how the runtime resolves its tables, that
description must match EP-2's final convention. Confirm at finalization.

**Soft dependency: EP-3 (`docs/plans/87`).** EP-3 finalizes the expected-schema/drift-gate
scope and portability. The `CODD_SCHEMAS` value and the "Updating the expected schema" prose
in `docs/user/migrations.md` and `keiro-migrations/README.md` must match EP-3. The default
assumption is `CODD_SCHEMAS=keiro` and a `keiro`-scoped drift gate; **confirm against EP-3**
whether the gate must also inspect `kiroku` (this is the one place where the exact
`CODD_SCHEMAS` value could differ from the assumption in Milestone 1).

**Soft dependency: EP-4 (`docs/plans/88`).** EP-4 finalizes the projection/read-model schema
API. **This is the largest open flag in the plan:** at authoring time EP-4 is a skeleton, so
the exact names (a `ReadModel` record field? a `keiroConnectionSettings`-style helper? a new
`keiro_read_models` column?) are unknown. Milestone 2 must pull the final names from EP-4 and
must not invent them; until then it uses greppable `TODO(EP-4)` markers. If EP-4 adds a
database column, that is an EP-1 migration plus an EP-3 snapshot regeneration, not an EP-5
change — flag it to those plans rather than documenting a column this plan cannot see.

**Sequencing.** Per the MasterPlan dependency graph and this plan's Decision Log, EP-5 may be
drafted once EP-1 is fleshed out but is finalized only after EP-2, EP-3, and EP-4 land, so the
documented names and commands are correct. Milestone 6 is the finalization gate.
