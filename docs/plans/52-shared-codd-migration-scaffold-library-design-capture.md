---
id: 52
slug: shared-codd-migration-scaffold-library-design-capture
title: "Shared codd migration scaffold library (design capture)"
kind: exec-plan
created_at: 2026-06-04T03:40:34Z
intention: "intention_01kt8bff84em99ykf0mz660yam"
---

# Shared codd migration scaffold library (design capture)

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

> **Status: DESIGN CAPTURE — PENDING REVIEW. Do not implement yet.** This plan
> exists to preserve a cross-project survey and a proposed design so that the
> next codd-based project can bootstrap a shared scaffolding library quickly.
> No code milestone below should begin until the user kicks off a review and
> the Decision Log records a "greenlit" decision. Until then the only "work" is
> keeping this document accurate.


## Purpose / Big Picture

Every new project in this ecosystem is moving to **codd** (the Haskell database
migration runner, `mzabani/codd`) for schema migrations. Four projects already
run codd migrations today — `keiro`, `kiroku`, `kizashi`, and `rei` (the last
only for its dependency layer) — and each one re-implements the same handful of
mechanics slightly differently: how a migration file is named, how the `.sql`
files get compiled into the binary, how the session `search_path` is set, and
whether there is any tool to create a new migration at all. Only `keiro` has a
generator, and it was added in the same session that produced this plan
(`keiro-migrations/src/Keiro/Migrations/New.hs`, the `keiro-migrate new`
subcommand). The other three hand-author file names, which is exactly where the
collision-and-ordering anxiety that motivated this work comes from: a human
typing `2026-06-03-00-00-00-...` by hand can pick a colliding or out-of-order
stamp, and nothing catches it.

After this work (when greenlit and implemented) a developer starting or
maintaining any codd project gains three things from one shared dependency:

1. `migrate new "<description>"` produces a correctly named migration file
   stamped with the **real current UTC time**, so two migrations authored at
   different moments can never collide and always sort in authoring order.
2. The "I added a `.sql` file and it silently did not get embedded" footgun
   disappears: a Template Haskell helper tracks the migrations directory so a
   newly added file forces a recompile, removing the hand-maintained "touch
   this comment to force a recompile" hack that every codd project currently
   copy-pastes.
3. A validator that any project can run in CI fails the build if two migrations
   share a timestamp, a file name does not parse, or lexicographic order would
   diverge from chronological order — turning today's *convention* into an
   enforced *guarantee*.

The library is **config-driven** so each project keeps its own naming prefix,
`search_path` schema, and directory, while sharing the mechanics. This plan
captures the survey and the proposed API; it does not build anything yet.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Survey the four codd-using projects and record how they diverge (see Context and Orientation + Surprises). — 2026-06-04
- [x] Draft the proposed config-driven design and API sketch (see Plan of Work + Interfaces and Dependencies). — 2026-06-04
- [x] Record the open questions that need a human decision before any code (see Decision Log "Open questions"). — 2026-06-04
- [ ] **Review gate:** user kicks off a review; record greenlit/deferred/rejected decision in the Decision Log. (Blocks everything below.)
- [ ] M1 — Bootstrap the standalone package skeleton with the core generator (`newMigrationFile`, `migrationSlug`, `migrationFileName`) lifted from `Keiro.Migrations.New`, parameterized by `MigrationConfig`.
- [ ] M2 — Prototype and validate the directory-tracking `embedMigrationsTracked` TH helper; confirm it removes the touch-comment hack.
- [ ] M3 — Add `validateMigrations` and the shared `migrateScaffoldMain` CLI (`new` / `validate`).
- [ ] M4 — Adopt the library in the next new project as the first real consumer.
- [ ] M5 — Backport: migrate `keiro` (and optionally `kiroku`, `kizashi`) onto the shared library; retire the per-project copies.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The divergence is worse than "four projects, one convention."** It is
  inconsistent *within* a project. `kizashi` mixes hand-assigned synthetic
  stamps with real wall-clock stamps in the same directory:

  ```text
  kizashi-migrations/sql-migrations/
    2026-06-02-00-00-00-kizashi-read-models.sql      <- synthetic 00-00-00 slot, kizashi- prefix
    2026-06-03-15-31-28-alert-queue.sql              <- real wall-clock stamp, NO prefix
    2026-06-03-18-15-16-kizashi-role-holders.sql     <- real wall-clock stamp, kizashi- prefix
  ```

  So the prefix policy and the timestamp policy already drift even where the
  same person authored the files.

- **`rei` is not purely codd.** It uses codd *only* for the keiro/kiroku
  dependency bootstrap, and runs its own application migrations through
  `hasql-migration` (the other migration runner the user owns,
  `shinzui/hasql-migration`) with a completely different naming scheme:
  `20260101_add_actor_column.sql` — compact `YYYYMMDDhhmmss`, underscore
  separator, snake_case, no prefix. Its runner `rei-migrations` layers four
  systems in order: TypeID → PGMQ → Keiro/Kiroku (codd) → Rei app
  (hasql-migration). A codd-only scaffold helps the codd layer but not rei's
  app layer.

- **`shiki` is hasql-migration too**, not codd. So "all new projects move to
  codd" describes intent going forward; the existing fleet still straddles two
  runners, and the scaffold should not pretend otherwise.

- **The two pieces of boilerplate everyone copy-pastes are exactly the two the
  library should own.** First, the `embedDir` recompile hack — `keiro` carries
  this verbatim in `keiro-migrations/src/Keiro/Migrations.hs` (the comment
  literally says "touch this comment to force a TH recompile when adding a new
  .sql file; embedDir is not tracked per-file by GHC's recompilation checker").
  Second, the `SET search_path TO kiroku, pg_catalog;` header, hand-copied into
  migration files across `keiro`, `kiroku`, and `kizashi`. Both are mechanical
  and identical except for the schema name — ideal library surface.

- **Only `keiro` has a generator, and it is brand new.** It already encodes the
  right core (real-UTC stamp, slug normalization, `keiro-` prefix enforcement,
  refuse-overwrite). The shared library is largely a *generalization* of
  `Keiro.Migrations.New`, not a green-field design — that lowers the
  implementation risk considerably.


## Decision Log

Record every decision made while working on the plan.

- Decision: Author this as a DESIGN-CAPTURE ExecPlan, not an implementation plan,
  and block all code milestones behind an explicit review gate.
  Rationale: The user asked to "start a document and kick start a review later,"
  and the rule-of-three says do not extract a shared package until a second real
  consumer needs it. Capturing now prevents losing the survey; deferring code
  avoids premature abstraction.
  Date: 2026-06-04

- Decision: The library will be a STANDALONE package (working name
  `codd-scaffold`), not a module inside `keiro-migrations`.
  Rationale: A non-keiro codd app must not drag in keiro's and kiroku's embedded
  SQL just to scaffold a file. This mirrors how the user already ships
  `shinzui/ephemeral-pg` and `shinzui/hasql-migration` as standalone DB
  libraries. Final name/home is an open question below.
  Date: 2026-06-04

- Decision: The API is CONFIG-DRIVEN via a `MigrationConfig` record (directory,
  optional name prefix, optional `search_path` schema, template builder).
  Rationale: The survey shows the only real per-project variation is prefix,
  schema, directory, and template body; everything else (UTC stamping, slug
  normalization, ordering, embedding, validation) is identical and should be
  shared.
  Date: 2026-06-04

- Decision: The first real consumer will be the NEXT new project (M4), and the
  existing `Keiro.Migrations.New` generator stays in place as-is until then.
  Rationale: Avoids churn on a working generator; lets the abstraction be shaped
  by a second consumer rather than over-fit to keiro.
  Date: 2026-06-04

- Open questions (must be resolved during the review before M1):
  1. **Package name and home.** `codd-scaffold`? `codd-migrate`? Standalone repo
     under `bokuno/` like `ephemeral-pg`, or a package inside an existing repo?
  2. **codd vs hasql-migration split.** Scope to codd only (cleanest), or also
     offer a hasql-migration-flavored generator so `rei`/`shiki` benefit? The
     filename/validator logic is runner-agnostic; only the embed + search_path
     bits are codd-shaped.
  3. **Prefix policy.** Enforce a per-project prefix (like keiro's `keiro-`),
     make it optional (`Maybe String`), or drop prefixes entirely and rely on
     timestamps for ordering and on the description for readability?
  4. **search_path defaults.** Default to emitting `SET search_path TO <schema>,
     pg_catalog;` when a schema is configured, and omit the line entirely when
     not (matching rei's app migrations that run against `public`)?
  5. **Timestamp granularity / collision policy.** Second-resolution UTC is what
     keiro uses. Is that enough, or should the generator detect an existing file
     with the same second and bump (or refuse)? The validator covers detection;
     the question is whether the generator should also auto-resolve.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation. As of 2026-06-04 the plan is
design-capture only: the survey and proposed API are recorded; no library code
exists. The retrospective will compare the eventual shared library against the
four divergent implementations catalogued here.)


## Context and Orientation

This section assumes no prior knowledge. Terms used throughout:

- **codd** — a Haskell library (`mzabani/codd`, registered locally as
  `mzabani/codd`) that applies SQL migration files to a PostgreSQL database and
  records which have been applied in its own ledger table. It applies migrations
  in the order they appear in the list it is given. The projects here feed it a
  list built from `.sql` files embedded into the binary at compile time.
- **embedDir / Template Haskell embedding** — `Data.FileEmbed.embedDir "dir"`
  is a compile-time splice (Template Haskell, abbreviated TH: Haskell code that
  runs during compilation and generates more Haskell) that reads every file in
  `dir` and bakes its bytes into the executable as a `[(FilePath, ByteString)]`.
  The catch: GHC's recompilation checker does not know a *new* file appeared in
  the directory, so adding a migration does not by itself trigger re-running the
  splice. Today projects work around this by editing ("touching") a nearby
  comment to force recompilation.
- **search_path** — a PostgreSQL session setting that controls which schemas
  unqualified table names resolve against. These projects keep their event-store
  tables in a schema named `kiroku`, so migrations begin with
  `SET search_path TO kiroku, pg_catalog;` to land objects in the right schema
  when applied incrementally to an existing database.
- **slug** — the human-readable tail of a migration file name (e.g.
  `keiro-bootstrap`), derived from a free-text description.

### The four codd consumers as they stand today

The survey below names exact paths so a future implementer can re-read the
sources. Narrative first, then a compact divergence matrix because the per-axis
comparison is genuinely clearer in a grid.

`keiro` keeps its migrations in
`keiro-migrations/sql-migrations/`, named `YYYY-MM-DD-HH-MM-SS-keiro-<slug>.sql`
(e.g. `2026-05-17-00-00-00-keiro-bootstrap.sql`). They are embedded by
`embedDir "sql-migrations"` in
`keiro-migrations/src/Keiro/Migrations.hs` (the touch-comment hack lives just
above that line). The runner executable is `keiro-migrate`
(`keiro-migrations/app/Main.hs`), which composes kiroku's event-store migrations
with keiro's own. As of this session it also has a generator
(`keiro-migrations/src/Keiro/Migrations/New.hs`) reachable as
`keiro-migrate new "<description>"`, which stamps real UTC time, normalizes the
slug, enforces the `keiro-` prefix, and refuses to overwrite.

`kiroku` keeps its migrations in
`kiroku-project/kiroku/kiroku-store-migrations/sql-migrations/`, named
`YYYY-MM-DD-HH-MM-SS-<description>.sql` with no enforced prefix (e.g.
`2026-05-16-00-00-00-kiroku-bootstrap.sql` next to
`2026-05-26-00-00-00-add-subscription-dead-letters.sql`). Embedded by `embedDir`
in `.../src/Kiroku/Store/Migrations.hs`. Runner executable `kiroku-store-migrate`.
No generator. It exposes `kirokuMigrations` for downstream projects to compose.

`kizashi` keeps its migrations in `kizashi/kizashi-migrations/sql-migrations/`,
named inconsistently (see Surprises). Embedded by `embedDir` in
`.../src/Kizashi/Migrations.hs`. Runner executable `kizashi-migrate`. No
generator. Notably it composes `keiroFrameworkMigrations` (keiro's own SQL only,
*not* `allKeiroMigrations`) so it does not double-apply kiroku's migrations.

`rei` keeps codd only for the dependency bootstrap; its application migrations
live in `rei-project/rei/rei-core/migrations/scripts/` named
`YYYYMMDDhhmmss_<snake_case>.sql` (e.g. `20260101_add_actor_column.sql`) and are
run by `hasql-migration`, not codd. Runner executable `rei-migrations` layers
TypeID → PGMQ → Keiro/Kiroku (codd) → Rei app (hasql-migration). No generator.

Divergence matrix (the axes a shared library would unify):

| Axis | keiro | kiroku | kizashi | rei (app layer) |
| --- | --- | --- | --- | --- |
| Runner | codd | codd | codd | hasql-migration |
| Name format | `YYYY-MM-DD-HH-MM-SS-` | `YYYY-MM-DD-HH-MM-SS-` | mixed | `YYYYMMDDhhmmss_` |
| Separator | `-` | `-` | `-` | `_` |
| Prefix policy | enforced `keiro-` | none | inconsistent | none |
| Generator | yes (new) | no | no | no |
| search_path | `kiroku` | `kiroku` | `kiroku` | none (public) |
| Embed | embedDir + hack | embedDir | embedDir | embedDir |

`nagare`, `nihongo`, `seihou`, `reiko`, and `kizamu` were checked and currently
have no codd migrations; `shiki` uses hasql-migration. They are out of scope for
a codd scaffold today but are candidate future consumers as they adopt codd.


## Plan of Work

All milestones below are gated on the review (see Progress "Review gate"). They
are written so a novice can execute them once greenlit. The working package name
`codd-scaffold` is used throughout; substitute the name chosen during review.

**M1 — Core generator package.** Create a standalone Cabal package
`codd-scaffold` exposing a library with the generator logic generalized from
`keiro-migrations/src/Keiro/Migrations/New.hs`. Replace keiro's hardcoded
`sql-migrations` directory and `keiro-` prefix and `kiroku` schema with fields on
a `MigrationConfig` record. At the end of M1, a tiny test program that calls
`newMigrationFile someConfig "add foo index"` writes a correctly named file into
the configured directory, stamped with the real UTC time, refusing to overwrite.
This milestone is a near-mechanical lift; the existing keiro code already
compiles and runs, so the risk is low.

**M2 — Directory-tracking embed helper (prototype first).** This is the only
genuinely uncertain piece, so treat it as a prototype. Provide
`embedMigrationsTracked :: FilePath -> Q Exp` that behaves like `embedDir` but
*also* makes GHC recompile when a file is added to the directory, eliminating the
touch-comment hack. The proposed mechanism is to call `addDependentFile` on the
directory path itself (a directory's mtime changes when an entry is added or
removed, which should trigger recompilation) in addition to each file. Because
directory-mtime behavior is filesystem-dependent, the milestone must include a
proof: add a `.sql` file without touching any Haskell source, rebuild, and show
the new migration appears in the embedded list. If the directory-mtime approach
proves unreliable, fall back to a documented `cabal build`-time codegen step and
record that in the Decision Log. Acceptance is behavioral, not "the function
exists."

**M3 — Validator and shared CLI.** Add `validateMigrations` (a pure function over
the embedded list that returns a list of defects: duplicate timestamps,
unparseable names, lexicographic-vs-chronological mismatch) and
`migrateScaffoldMain :: MigrationConfig -> IO ()` so each project's `app/Main.hs`
becomes a three-line dispatch over `new <description>` and `validate`. At the end
of M3, running the validate command against a directory with a deliberately
duplicated timestamp exits non-zero and prints the offending pair; against a
clean directory it exits zero. This is what a project wires into CI.

**M4 — First real consumer.** Adopt `codd-scaffold` in the next new codd project
from day one: depend on it, define that project's `MigrationConfig`, and use its
`migrate new` and `validate`. This is the rule-of-three trigger that justifies
the package existing. Capture any rough edges in Surprises.

**M5 — Backport and converge.** Migrate `keiro` onto `codd-scaffold` (replacing
`Keiro.Migrations.New` and the touch-comment hack), and optionally `kiroku` and
`kizashi`. Each backport is independently shippable and must keep that project's
existing migration runner working (validate against the existing
`keiro-migrations-test` suite). Decide during review whether `kiroku`/`kizashi`
backports are in scope now or deferred.


## Concrete Steps

These are the commands to run **once the review greenlights M1**. They are
recorded now so the next project can bootstrap immediately; do not run them
before the review decision is logged.

Bootstrap the package skeleton (working name; adjust to the chosen home):

```bash
# from the chosen repo root, e.g. /Users/shinzui/Keikaku/bokuno/codd-scaffold
cabal init --non-interactive --lib --package-name codd-scaffold
```

Lift the generator. The starting point already exists and is known-good — copy
the pure logic from these files and parameterize it:

```text
source generator : keiro-migrations/src/Keiro/Migrations/New.hs
source CLI wiring : keiro-migrations/app/Main.hs   (the `new` subcommand dispatch)
source embed hack : keiro-migrations/src/Keiro/Migrations.hs  (the touch-comment to delete)
```

Smoke-test the generator (expected transcript, mirroring the keiro generator
verified in this session):

```text
$ KEIRO_MIGRATIONS_DIR=/tmp/scaffold-test cabal run codd-scaffold-demo -- new "Add Foo Index!!"
Created /tmp/scaffold-test/2026-06-04-02-42-12-<prefix>add-foo-index.sql
```

The exact prefix and search_path header depend on the demo's `MigrationConfig`.
Update this section with the real transcript as M1 proceeds.


## Validation and Acceptance

Phrased as observable behavior a human can check once implemented:

- **Generator:** `migrate new "add foo index"` creates a file whose name is
  `<current-UTC, YYYY-MM-DD-HH-MM-SS>-<configured-prefix>add-foo-index.sql` in the
  configured directory, contains the configured `SET search_path` header (or none
  when no schema is configured) and a body placeholder, and a second invocation
  in the same second against the same description either bumps or refuses rather
  than silently overwriting. Prove it by running it twice and listing the dir.
- **Embed tracking (M2):** drop a new `.sql` file into the migrations directory,
  run the project's build with no other edits, and confirm the new migration is
  applied by the runner. Before this work that required touching a comment; after
  it must not. This is the headline acceptance for the footgun fix.
- **Validator (M3):** create two files that share a timestamp; the validate
  command exits non-zero and names both. Remove the duplicate; it exits zero.
  Wire this into a project's CI and show a failing build turning green.
- **Backport (M5):** `keiro`'s existing migration test suite
  (`cabal test keiro-migrations-test` from `keiro-migrations/`) still passes
  after keiro is switched onto `codd-scaffold`, proving the shared library is a
  behavior-preserving replacement for `Keiro.Migrations.New` and the hack.


## Idempotence and Recovery

This plan, as design capture, is safe to revisit repeatedly; it changes no code.
The proposed generator is idempotent-by-refusal: it never overwrites an existing
migration (the keiro version already errors on collision), so re-running it is
safe. codd migrations themselves are forward-only and the survey'd projects use
`IF NOT EXISTS` DDL, so re-applying is safe; recovery from a bad migration is a
new forward migration, never an edit to a shared one. If the M2 directory-mtime
mechanism proves unreliable on some filesystem, the recovery path is the
documented codegen fallback noted in M2, with the touch-comment hack remaining as
a last resort until codegen lands.


## Interfaces and Dependencies

Proposed library surface (subject to the review; names indicative). Module
`Codd.Scaffold` in package `codd-scaffold`:

```haskell
-- Per-project configuration; the only thing that varies across consumers.
data MigrationConfig = MigrationConfig
  { mcDir        :: FilePath            -- migrations dir, relative to package root
  , mcNamePrefix :: Maybe String        -- e.g. Just "keiro-"; Nothing = no prefix
  , mcSchema     :: Maybe Text          -- e.g. Just "kiroku"; Nothing = no SET search_path
  , mcTemplate   :: String -> String    -- body builder, given the description
  }

-- Generator: stamps real UTC, normalizes the slug, applies prefix, refuses overwrite.
newMigrationFile  :: MigrationConfig -> String -> IO FilePath

-- Pure helpers (testable without IO), generalized from Keiro.Migrations.New:
migrationFileName :: UTCTime -> Maybe String -> String -> FilePath
migrationSlug     :: Maybe String -> String -> String

-- TH embed that ALSO tracks the directory so adding a file forces recompile.
-- Produces a [(FilePath, ByteString)] just like Data.FileEmbed.embedDir.
embedMigrationsTracked :: FilePath -> Q Exp

-- CI validator over the embedded list.
data MigrationDefect
  = DuplicateTimestamp FilePath FilePath
  | UnparseableName FilePath
  | OrderMismatch FilePath FilePath      -- lexicographic order != chronological order
validateMigrations :: [(FilePath, a)] -> [MigrationDefect]

-- Shared CLI so each project's Main.hs is a 3-liner: dispatch new/validate.
migrateScaffoldMain :: MigrationConfig -> IO ()
```

Dependencies: `base`, `time` (UTC stamping), `directory` + `filepath` (file IO),
`bytestring` + `template-haskell` + `file-embed` (the embed helper), and `text`
(schema name). The generator and validator deliberately do **not** depend on
`codd` itself — only the embed helper is codd-shaped — which keeps the door open
to the hasql-migration question in the Decision Log. The existing
`keiro-migrations` package is the reference implementation to lift from, and
keiro's `keiro-migrations-test` suite is the backport acceptance harness.


---

### Revision note — 2026-06-04 (creation)

Created as design-capture from the keiro repo after surveying the four codd
consumers (`keiro`, `kiroku`, `kizashi`, `rei`). The plan deliberately stops at
design + open questions and gates all code behind a review, per the user's
request to "start a document and kick start a review later" and the rule-of-three
(extract on the second real consumer). The survey, divergence matrix, proposed
`MigrationConfig`-driven API, and five-milestone path are recorded so the next
project can bootstrap the library quickly once greenlit.
