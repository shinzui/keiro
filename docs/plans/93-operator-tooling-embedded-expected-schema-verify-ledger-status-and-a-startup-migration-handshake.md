---
id: 93
slug: operator-tooling-embedded-expected-schema-verify-ledger-status-and-a-startup-migration-handshake
title: "Operator tooling: embedded expected-schema verify, ledger status, and a startup migration handshake"
kind: exec-plan
created_at: 2026-07-06T18:39:48Z
intention: "intention_01kwwbahspe0tazeaa1gk5w65b"
master_plan: "docs/masterplans/13-migration-hardening-integrity-gates-safe-apply-path-operator-tooling-and-the-migration-ownership-guide.md"
---

# Operator tooling: embedded expected-schema verify, ledger status, and a startup migration handshake

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan spans **both repositories** (kiroku first at
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`, then this repository with a pin
bump), like plan 92. Commit trailers for every commit in either repository:

```text
MasterPlan: docs/masterplans/13-migration-hardening-integrity-gates-safe-apply-path-operator-tooling-and-the-migration-ownership-guide.md
ExecPlan: docs/plans/93-operator-tooling-embedded-expected-schema-verify-ledger-status-and-a-startup-migration-handshake.md
Intention: intention_01kwwbahspe0tazeaa1gk5w65b
```

**Hard dependency:** plan 92 (`docs/plans/92-harden-the-migration-apply-path-strict-cli-drift-exit-codes-single-try-retries-and-advisory-lock-serialization.md`)
— `verify` and `status` are new cases of the strict dispatcher it introduces; adding
them to the old "anything-unknown-migrates" dispatcher would be dangerous. Soft
dependencies: plans 90/91 provide `embeddedMigrationNames` and the dual-schema ledger
detection idiom this plan reuses.


## Purpose / Big Picture

Today the only way to ask "is this database's schema what the framework expects?" or
"which migrations has this database applied?" is to have a repository checkout, the
right environment variables, and codd knowledge. Framework users operating their own
databases have neither. And an application started against an un-migrated database
fails with arbitrary `relation … does not exist` errors at some later moment instead
of a clear startup-time message.

After this plan, the shipped executables answer both questions anywhere:
`keiro-migrate verify` strict-compares a live database against the expected-schema
snapshot **embedded in the binary** (no checkout needed), exits 0 on match, 1 on
drift (printing the differing objects), and 2 when migrations are pending (verify
never applies anything); `keiro-migrate status` prints applied and pending migration
names read from codd's ledger (finding it at `codd.sql_migrations` or
`codd_schema.sql_migrations`); and both migration packages export a
`missingMigrations` function so an application can fail fast at startup — the
handshake for deployments that run `withStore … SkipSchemaInitialization`.
`kiroku-store-migrate` gains the same `verify`/`status`. The runtime-role grants gap
is closed documentation-first with copy-paste `GRANT` statements.


## Progress

- [ ] M0: API research spike — pin the exact codd `v0.1.8` names for reading live and
      on-disk schema representations; record findings here.
- [ ] M1 (kiroku): expected-schema tree embedded; `verify` subcommand; drift and
      pending-migrations drills recorded.
- [ ] M2 (kiroku): `status` subcommand (dual-schema ledger detection);
      `missingMigrations` exported; README/CHANGELOG.
- [ ] M3 (keiro): pin bumped; expected-schema embedded; `verify` + `status` on the
      combined ledger; `missingMigrations` (kiroku ∪ keiro) exported.
- [ ] M4: grants documentation in both READMEs; optional jitsurei handshake wiring;
      keiro CHANGELOG and doc updates.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: `verify` refuses to run when migrations are pending (exit 2 with the
  pending list) instead of applying them or comparing anyway.
  Rationale: verify must be side-effect-free to be trustworthy in production, and
  comparing a half-migrated database against the final snapshot would report
  meaningless drift. The pending check is cheap (ledger names vs embedded names).
  Date: 2026-07-06

- Decision: Materialize the embedded expected-schema tree to a temporary directory and
  point codd's on-disk reader at it, rather than re-implementing codd's representation
  parser over in-memory bytes.
  Rationale: codd's `v0.1.8` disk reader owns the directory-layout knowledge
  (per-PostgreSQL-major-version subdirectories, JSON object representations);
  duplicating it is pure liability. A temp dir costs milliseconds at verify time.
  Date: 2026-07-06

- Decision: `status` always exits 0 when it can reach the database (pending
  migrations are reported, not failed on); `verify` is the gating command.
  Rationale: status is for humans and dashboards; overloading its exit code invites
  scripts to use the wrong tool. One command gates (`verify`), one informs (`status`).
  Date: 2026-07-06

- Decision: Grants stay documentation-first (exact `GRANT` statements in the READMEs
  and the plan-94 guide), no DDL in migrations.
  Rationale: recorded in the MasterPlan Decision Log — a framework cannot invent the
  deployment's role names, and a wrong default silently over-grants.
  Date: 2026-07-06


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Both packages check in a codd expected-schema snapshot under
`<package>/expected-schema/v18/` — a directory tree of small JSON files describing
every table, column, index, constraint, function, and trigger the migrations should
produce (the `v18` segment is the PostgreSQL major version it was captured against).
Today the snapshot is consumed only by the test suites (strict drift gates) and
regenerated by the flag-gated `*-write-expected-schema` executables. The apply-path
executables never read it.

codd `v0.1.8` (checkout `/Users/shinzui/Keikaku/hub/haskell/codd-project`, tag
`v0.1.8`) exposes in `Codd.Representations` the machinery the tests already use
indirectly: reading representations from a live database
(`readRepresentationsFromDbWithSettings`), reading them from disk (`readRepsFromDisk`),
and logging a comparison (`logSchemasComparison`) — the exact names and signatures are
what Milestone 0 pins down. The ledger lives at `codd.sql_migrations` on fresh
`v0.1.8` databases and `codd_schema.sql_migrations` on not-yet-upgraded older ones
(dual detection via `to_regclass`, the idiom plans 90/91 established in their canary
tests). Ledger columns include `name` and `migration_timestamp`.

After plans 90–92 the packages export `embeddedMigrationNames :: [FilePath]`
(both), and the executables have strict dispatchers (`new`, `lock`, `up`, bare).
`postgresql-simple` is in both packages' `build-depends` (plan 92 added it for the
advisory lock); reuse it for the ledger queries here. The kiroku package has a cabal
flag `expected-schema-tool` gating its snapshot-writer executable off under nix
because `ephemeral-pg` does not build there — the **embedding of the snapshot into the
main executable must not touch that flag**; `file-embed` builds everywhere.

The jitsurei worked example (`jitsurei/app/Main.hs` in this repository) opens the
store with schema initialization disabled and is the natural demo site for the
startup handshake.


## Plan of Work

**Milestone 0 — API research spike.** In the codd checkout at tag `v0.1.8`, read
`src/Codd/Representations.hs` (and `Representations/Disk.hs`) and record here: the
function that reads a `DbRep` from a snapshot directory (name, signature, how it picks
the `v18` subdirectory), the function that reads the live database's `DbRep` given
`CoddSettings` and a connection, and how the strict test's mismatch output is produced
(`logSchemasComparison` or equivalent). Also confirm how `CoddSettings.onDiskReps =
Left <dir>` resolves the version subdirectory, since `verify` will reuse that path.
This spike gates the `verify` design; everything below assumes it succeeded. If codd
turns out not to expose enough (all three names appear in its public import lists, so
this is unlikely), the fallback design is: run `applyMigrations` with `StrictCheck`
*after* the pending-check guarantees there is nothing to apply — behaviorally
identical, and the pending gate keeps it side-effect-free; record the fallback in the
Decision Log if taken.

**Milestone 1 — kiroku verify.** New module
`kiroku-store-migrations/src/Kiroku/Store/Migrations/ExpectedSchema.hs`, exposed,
containing `expectedSchemaFiles :: [(FilePath, ByteString)]` via
`$(embedDir "expected-schema")` and
`withMaterializedExpectedSchema :: (FilePath -> IO a) -> IO a` (write the tree under a
`withSystemTempDirectory`, creating parent directories per file). Add `verify` to the
dispatcher: read codd settings from the environment as `migrate` does, connect with
`postgresql-simple`, detect the ledger schema, compute pending = embedded names minus
ledger names — if the ledger is absent treat every migration as pending; if pending is
non-empty print them and exit 2; otherwise materialize the snapshot, read expected and
live representations per Milestone 0, compare, print the comparison on mismatch, exit
1 on drift and 0 on match. Extend `test/Main.hs`: a spec that migrates a fresh
database and asserts the verify *logic* (factor the executable's core into an exported
`verifySchema :: CoddSettings -> IO VerifyOutcome` in the library so the test can call
it) returns the match outcome; a drift spec that alters one column and asserts the
drift outcome; a pending spec on an un-migrated database.

**Milestone 2 — kiroku status + handshake.** `status` subcommand: same ledger
detection; print applied names with their `migration_timestamp`, then pending embedded
names, then a summary line (`applied 8, pending 0`); exit 0 whenever the database was
reachable. Export from `Kiroku.Store.Migrations`:

```haskell
missingMigrations :: ConnectionString -> DiffTime -> IO [FilePath]
```

(connect, detect ledger — no ledger means everything is missing — return embedded
names not present; the startup handshake). Spec: fresh database → all names; migrated
database → `[]`. README documents `verify`, `status`, and calling `missingMigrations`
at application startup; CHANGELOG.

**Milestone 3 — keiro verify/status/handshake.** Bump the kiroku pin (both stanzas).
Mirror Milestones 1–2 in `keiro-migrations`: `Keiro.Migrations.ExpectedSchema`
(embedding keiro's snapshot, which covers the `keiro` namespace), `verify` and
`status` operating on the **combined** ledger (pending = kiroku ∪ keiro embedded names
minus ledger), and `Keiro.Migrations.missingMigrations` returning missing names across
the union. Reuse kiroku's exported pieces wherever they fit (the ledger-detection
query helper is worth exporting from kiroku in Milestone 2 rather than copying —
decide there and record it). Specs mirror kiroku's; the combined pending spec should
also cover the half-state "kiroku migrated, keiro not" by applying only
`runKirokuMigrationsNoCheck` first and asserting exactly the keiro names are missing.

**Milestone 4 — grants documentation and the demo handshake.** Both READMEs (and
`docs/user/migrations.md`) gain a "Runtime role privileges" section with copy-paste
statements and the upgrade caveat, for example for keiro:

```sql
GRANT USAGE ON SCHEMA kiroku, keiro TO your_app_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA kiroku, keiro TO your_app_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA kiroku TO your_app_role;
-- Re-run after any framework upgrade whose migrations add tables or sequences:
-- new objects are NOT covered by past GRANT … ON ALL TABLES statements.
```

Optionally (small, high-value demo): wire `missingMigrations` into
`jitsurei/app/Main.hs` before `withStore`, exiting with a "run keiro-migrate first"
message listing the missing names; note it in the jitsurei guide if done. keiro
CHANGELOG entry.


## Concrete Steps

kiroku side, from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`:

```bash
cabal build kiroku-store-migrations
cabal test kiroku-store-migrations-test
# manual drills against a scratch database (CODD_* env as in the README):
cabal run kiroku-store-migrate -- status
cabal run kiroku-store-migrate -- verify; echo "exit=$?"
```

Expected `status` transcript on a freshly migrated scratch database:

```text
Ledger: codd.sql_migrations
Applied (8):
  2026-05-16-12-17-14-kiroku-bootstrap.sql   2026-05-16 12:17:14+00
  ...
Pending (0)
```

keiro side, from `/Users/shinzui/Keikaku/bokuno/keiro`: same commands with
`keiro-migrate`; the drift drill from plan 92 (alter a column on a scratch database)
should now show `verify` exiting 1 with the differing object named, and `status`
still exiting 0. Record both transcripts here.


## Validation and Acceptance

1. `verify` on a freshly migrated scratch database exits 0; after a manual column
   alteration exits 1 printing the differing object; on an empty database exits 2
   listing every embedded migration as pending. Nothing is ever applied by `verify`
   (assert by checking the ledger row count before and after).
2. `status` output matches the ledger exactly on migrated, empty, and half-migrated
   (kiroku-only) databases; exit 0 in all reachable cases.
3. `missingMigrations` specs pass in both suites, including keiro's half-state case.
4. `nix build .#kiroku-store-migrations` (kiroku repo) still succeeds — the embedded
   snapshot must not disturb the `expected-schema-tool` flag gating.
5. Regenerating the expected schema (`cabal run <pkg>-write-expected-schema`) plus a
   rebuild updates what `verify` enforces — confirm by regenerating with no schema
   change and seeing `verify` still exit 0 (and note the Template-Haskell recompile
   caveat applies to the *snapshot* embed too: touch its embed comment).
6. Both suites green; READMEs document verify/status/handshake/grants.


## Idempotence and Recovery

All additive. `verify` and `status` are read-only by construction — the pending-gate
plus representation reads never write (the specs assert ledger row counts to prove
it). Drills use scratch databases only. The snapshot embed doubles the executable's
awareness of `expected-schema/`; if the tree and the binary desynchronize (stale
Template-Haskell embed), symptom is a spurious verify drift — the recovery is a
rebuild after touching the embed comment, and the plan-90/91 parity discipline keeps
this from reaching users.


## Interfaces and Dependencies

Provides, kiroku: `Kiroku.Store.Migrations.ExpectedSchema`
(`expectedSchemaFiles`, `withMaterializedExpectedSchema`),
`Kiroku.Store.Migrations.missingMigrations :: ConnectionString -> DiffTime -> IO
[FilePath]`, `verifySchema` (exact shape decided in M1), and the `verify`/`status`
subcommands.

Provides, keiro: `Keiro.Migrations.ExpectedSchema`,
`Keiro.Migrations.missingMigrations` (union semantics), `verify`/`status` on the
combined ledger.

Consumes: plan 92's strict dispatchers and `postgresql-simple` dependency; plans
90/91's `embeddedMigrationNames` and ledger-detection idiom; codd `v0.1.8`
`Codd.Representations` (exact names pinned in M0). Plan 94 documents everything this
plan ships — keep the exported names stable.
