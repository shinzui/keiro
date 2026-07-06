---
id: 94
slug: write-the-migration-ownership-guide-framework-owned-vs-application-owned-migrations
title: "Write the migration ownership guide: framework-owned vs application-owned migrations"
kind: exec-plan
created_at: 2026-07-06T18:39:48Z
intention: "intention_01kwwbahspe0tazeaa1gk5w65b"
master_plan: "docs/masterplans/13-migration-hardening-integrity-gates-safe-apply-path-operator-tooling-and-the-migration-ownership-guide.md"
---

# Write the migration ownership guide: framework-owned vs application-owned migrations

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

All work is in **this repository** (`/Users/shinzui/Keikaku/bokuno/keiro`), in
`docs/user/` plus small cross-link edits. Commit trailers:

```text
MasterPlan: docs/masterplans/13-migration-hardening-integrity-gates-safe-apply-path-operator-tooling-and-the-migration-ownership-guide.md
ExecPlan: docs/plans/94-write-the-migration-ownership-guide-framework-owned-vs-application-owned-migrations.md
Intention: intention_01kwwbahspe0tazeaa1gk5w65b
```

**Hard dependency:** plan 93 (`docs/plans/93-…`) — the guide documents `verify`,
`status`, `missingMigrations`, and the grants convention that plan ships. Soft
dependencies: plans 90/91 (the guard specs and `migrations.lock` discipline the guide
tells consumers about). Draft structure may be written earlier; publish only after
plan 93 is Complete.


## Purpose / Big Picture

Keiro is a framework: its users each operate a PostgreSQL database that contains
**three kinds of tables with three different owners** — kiroku's event-store tables in
the `kiroku` schema, keiro's framework tables in the `keiro` schema (both evolved
exclusively by embedded, forward-only codd migrations shipped in the framework
packages), and the application's own tables (projections, read models, reporting) in
schemas the application chooses. Today that ownership story is scattered across two
READMEs, `docs/user/migrations.md`, and `docs/user/read-models-and-projections.md`,
and nothing tells a developer how to author *their own* migrations so they compose
safely with the framework's combined codd ledger — the sharpest gap being that the
combined ledger enforces `UNIQUE (name)` and `UNIQUE (migration_timestamp)` across
*everything* in it, framework and application files alike.

After this plan there is one authoritative guide, `docs/user/migration-ownership.md`,
that a developer can read end to end and then answer: what the framework owns and what
I own; how framework migrations run and why I must never edit or imitate them in the
framework schemas; where my projection/read-model tables go and how to author, name,
and lint my own migrations; whether to run one combined ledger or a separate one, and
the exact composition code for each choice; what grants my runtime role needs; and how
to operate it all (verify, status, the startup handshake, backups, forward-only
recovery, and where codd's ledger actually lives).


## Progress

- [ ] M1: Guide outline agreed against the final shipped surface (re-read plans 90–93
      Outcomes and the merged code; list every name the guide will reference).
- [ ] M2: `docs/user/migration-ownership.md` written in full.
- [ ] M3: Existing docs reconciled — `docs/user/migrations.md` slimmed to running the
      framework migrations and linking out; `docs/user/read-models-and-projections.md`
      and `docs/user/README.md` cross-linked; both package READMEs link the guide.
- [ ] M4: Stale-reference sweep — `codd_schema` and "migrate is unchecked" claims
      across docs and the `.claude/skills/cohort-migrate` skill; CHANGELOG entry.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: One new guide document rather than growing `docs/user/migrations.md`.
  Rationale: `migrations.md` is a how-to-run reference; the ownership guide is a
  conceptual contract plus authoring rules for *application* developers. Mixing them
  buries the contract. `migrations.md` keeps the operational content and links out.
  Date: 2026-07-06

- Decision: The guide recommends the combined-ledger composition as the default for
  applications that use codd, with the separate-ledger option documented second.
  Rationale: `docs/user/migrations.md` already points this way ("a single codd run
  keeps all migration names in one ledger and one timestamp order"), and the framework
  now ships the guards that make the combined ledger safe (uniqueness across the
  union, scaffolded real-UTC names). A separate ledger remains legitimate for teams
  with existing migration tooling.
  Date: 2026-07-06


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Existing documents to build on (all in this repository): `docs/user/migrations.md`
(how to run `keiro-migrate`, expected-schema regeneration, forward-only recovery, an
"Application Tables" section that already gestures at the ownership split);
`docs/user/read-models-and-projections.md` (the `ReadModel` `schema` field and
`Keiro.Connection` helpers — `qualifyTable`, `quoteIdentifier`,
`withProjectionSchema`, `keiroConnectionSettings`, `ensureProjectionSchema` — from
MasterPlan 12 EP-4); `docs/user/upgrading-to-the-keiro-schema.md` (the alpha
remediation runbook); `keiro-migrations/README.md` and
`kiroku-store-migrations/README.md` (authoring discipline, drift gate, ledger-fixups,
forward-only recovery). The jitsurei worked example places its
`jitsurei_order_summary` read model in its own `jitsurei` schema — the guide's
canonical "application-owned" illustration.

Shipped by this initiative's earlier plans (verify each name against the merged code
during M1): `migrations.lock` + the `lock` subcommand and the never-edit-shipped-bodies
rule enforced by checksum (plans 90/91); `Kiroku.Store.Migrations.Guards` — pure
validators applications can run over *their own* migration directories
(`sentinelViolations`, `duplicateTimestampViolations`, `lintViolations`,
checksum helpers) (plan 90); combined-ledger uniqueness as a framework CI gate (plan
91); strict CLI, drift exit codes, single-try rationale, and the per-database advisory
lock both executables share (plan 92); `verify`, `status`,
`missingMigrations`, and the grants statements (plan 93).

Key facts the guide must state plainly (from the MasterPlan's verified codd `v0.1.8`
research): codd identifies applied migrations by filename with no body checksum, so a
migration file is immutable the moment it may have reached any shared database; the
ledger enforces `UNIQUE (name)` and `UNIQUE (migration_timestamp)` across the whole
combined ledger — application files included; codd sorts migrations by their filename
timestamp, so application files interleave chronologically with framework files; the
ledger lives at `codd.sql_migrations` (codd ≥ 0.1.8) or `codd_schema.sql_migrations`
(older databases not yet touched by 0.1.8 — first contact renames it); and codd is
forward-only (recovery = backup restore or a new forward migration, per the existing
runbooks).

Composition mechanics to document (verify signatures during M1):
`Keiro.Migrations.allKeiroMigrations` returns the framework's parsed embedded
migrations; an application composes its own by parsing its files with
`Codd.Parsing.parseAddedSqlMigration` (or by letting codd collect them from disk via
`CODD_MIGRATION_DIRS`… — pick whichever path the code actually supports best and show
that one) and calling `Codd.applyMigrations` once with the concatenated list, exactly
as `docs/user/migrations.md` already sketches. Scaffolding tip: `keiro-migrate new
"<description>"` honors `KEIRO_MIGRATIONS_DIR`, so applications can scaffold
correctly-named files into their own migration directory without writing any tooling.


## Plan of Work

**Milestone 1 — inventory.** Re-read plans 90–93's Outcomes sections and the merged
code; build the guide's reference inventory (exact module names, subcommands, exported
functions, file paths, environment variables). Any discrepancy between a plan's
promised name and the shipped name is recorded here and the *shipped* name wins.

**Milestone 2 — write the guide.** Create `docs/user/migration-ownership.md` with this
structure (prose, following the repository's user-doc voice; every code/SQL block
fenced with a language tag):

1. *The three owners* — one database, three namespaces: `kiroku` (event store),
   `keiro` (framework metadata), and your application schemas. A table-free prose
   contract: the framework schemas are written **only** by the shipped migration
   executables; applications never issue DDL against them, and the framework never
   touches application schemas. Point at jitsurei's `jitsurei` schema as the model.
2. *How framework migrations work and why they are immutable* — embedded, timestamped,
   filename-keyed, checksum-manifested, forward-only; the combined kiroku+keiro
   ledger; what `migrations.lock` means when reviewing a framework upgrade; never
   editing or hand-copying framework DDL.
3. *Your migrations: projections, read models, and app tables* — choosing a schema
   (`ReadModel.schema`, `Keiro.Connection`, `ensureProjectionSchema`; link to
   read-models-and-projections.md); authoring rules that make files combinable:
   real-UTC filenames via `KEIRO_MIGRATIONS_DIR=<your dir> keiro-migrate new …`,
   idempotent statements, hard-qualified `<your_schema>.<table>`, never `search_path`,
   `CREATE INDEX CONCURRENTLY` only with `-- codd: no-txn`; running the
   `Kiroku.Store.Migrations.Guards` validators over your directory in your CI (a
   complete copy-paste hspec snippet, including the union-uniqueness check against
   `allKeiroMigrations`' names).
4. *Composing the ledgers* — the recommended single combined ledger (full code
   sample: parse your files, concatenate after `allKeiroMigrations`, one
   `applyMigrations` call; what the `UNIQUE` constraints mean for you), and the
   separate-ledger alternative (your tooling, your ledger; run `keiro-migrate` first;
   tradeoffs).
5. *Privileges* — the grants statements from plan 93, per schema, and the re-grant
   caveat after upgrades that add tables.
6. *Operating* — run migrate before app start (`SkipSchemaInitialization`);
   `verify` / `status` / `missingMigrations` with transcripts; concurrency semantics
   (the advisory lock; still prefer one migrator per deploy); where the ledger lives
   (`codd` vs `codd_schema`); backups before migrating persistent databases;
   forward-only recovery; links to `upgrading-to-the-keiro-schema.md` and the
   ledger-fixup discipline in the kiroku README.
7. *Version support* — state plainly what is tested: PostgreSQL 18 snapshots
   (`expected-schema/v18/`), bootstrap-level support claims for 17, and that the
   drift gates run on 18 (the honest framing the MasterPlan's out-of-scope decision
   requires).

**Milestone 3 — reconcile existing docs.** Trim `docs/user/migrations.md`'s
"Application Tables" section to a summary + link; add the guide to `docs/user/README.md`'s
index; cross-link from `docs/user/read-models-and-projections.md` ("where your
projection tables' migrations live"); link the guide from both package READMEs' intro
sections. Keep each edit minimal — the guide is the single source; other docs point
at it.

**Milestone 4 — stale-reference sweep and changelog.** `git grep -n "codd_schema"
docs .claude keiro-migrations` (and the kiroku repo docs if any remain) — every hit
must either be dual-aware wording or historical context inside fixup files; update the
`.claude/skills/cohort-migrate` skill's prose if it hardcodes the old ledger location.
Add a CHANGELOG entry announcing the guide.


## Concrete Steps

Working directory `/Users/shinzui/Keikaku/bokuno/keiro`.

```bash
# M1 inventory
git log --oneline -20                       # confirm plans 90-93 landed
git grep -n "missingMigrations\|verifySchema\|Guards" -- keiro-migrations
# M2-M4 are document edits; validate rendering and links:
git grep -n "migration-ownership" docs      # every cross-link resolves
git grep -n "codd_schema" docs .claude keiro-migrations
```

Every SQL/Haskell/bash snippet in the guide must be executed or compiled once against
a scratch database/project before it is committed — a guide with broken copy-paste
blocks is worse than no guide. Record each snippet's verification in Progress as it is
proven (split M2 into per-section checkboxes when writing begins).


## Validation and Acceptance

1. `docs/user/migration-ownership.md` exists, covers the seven sections, and every
   referenced module, function, subcommand, and file path exists in the merged code
   (spot-check with `git grep`).
2. The CI-guards hspec snippet from section 3 compiles and passes when dropped into a
   scratch consumer project (or, minimally, into a keiro test module temporarily);
   the combined-ledger composition sample compiles.
3. A developer-experience read-through: starting from `docs/user/README.md`, a reader
   can reach the guide, and from the guide reach migrations.md,
   read-models-and-projections.md, and the upgrade runbook without dead links.
4. The stale-reference sweep is clean.
5. `docs/user/migrations.md` no longer duplicates the ownership content it now links.


## Idempotence and Recovery

Documentation-only; every step is re-runnable and revertible with git. The only risk
is drift between the guide and the code it documents — mitigated by M1's inventory
discipline (shipped names win) and by the snippet-verification rule in Concrete
Steps. If a later initiative changes a documented surface, the guide is the first
place to update; note that expectation in the guide's own closing section.


## Interfaces and Dependencies

Documents (and therefore depends on the stability of): `keiro-migrate` /
`kiroku-store-migrate` subcommands `new`, `lock`, `up`, `verify`, `status` (plans
90–93); `Keiro.Migrations.allKeiroMigrations`, `embeddedMigrationNames`,
`missingMigrations`; `Kiroku.Store.Migrations.Guards`; `Keiro.Connection` and
`ReadModel.schema` (MasterPlan 12); codd `v0.1.8` behaviors as stated in the
MasterPlan's Vision. No code interfaces are created by this plan.
