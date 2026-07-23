---
id: 124
slug: guard-up-against-codd-ledgered-databases-and-mount-the-codd-import-in-the-cli
title: "Guard up against codd-ledgered databases and mount the codd import in the CLI"
kind: exec-plan
created_at: 2026-07-23T03:02:27Z
intention: intention_01ky8hzdgxe7etqkgzfma64nj5
master_plan: "docs/masterplans/19-restore-the-migration-integrity-gates-under-pg-migrate-surfaced-by-the-2026-07-migration-review.md"
---

# Guard up against codd-ledgered databases and mount the codd import in the CLI

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Between now and the end of the keiro rewrite, ten to fifteen services will each perform a
one-time production cutover from the retired codd migration runner to pg-migrate. The July
2026 migration review adversarially verified that the sharpest operator trap in that
cutover is unguarded today: **nothing stops `keiro-migrate up` from running against an
existing codd-ledgered production database.** pg-migrate's runner unconditionally
initializes an absent native ledger and treats every migration as pending; the CLI's `up`
handler goes straight to the runner; and the only warning is one sentence of prose in the
cutover runbook.

The verified consequences (embedded in full in Context and Orientation — the corrected
mechanics, not the review's original claim) are: on a current codd database the run aborts
partway by accident, poisoning the native ledger so the subsequent codd-history import is
cleanly refused until a manual, undocumented cleanup; on a codd database whose history
predates 2026-06-14, the run instead *succeeds silently*, building a complete empty
parallel `keiro` schema that a subsequently deployed service reads while the real
workflow/timer/outbox rows sit invisible in the `kiroku` schema — a silent operational
outage. No data is destroyed in either variant, but the recovery is undocumented and each
service cutover today requires bespoke Haskell because the CLI does not even mount the
shipped codd-import machinery.

After this plan: `keiro-migrate up` refuses to initialize a fresh native ledger over a
codd-ledgered database, exiting nonzero and naming the codd ledger it found, unless the
operator passes an explicit `--allow-fresh-ledger-over-codd` override; the codd-history
import is a first-class `keiro-migrate import-codd-history` subcommand so every cutover
follows one tested path; the cutover runbook gains the missing sentinel-ledger fixup step
and a verified recovery procedure for both trap variants; and the fixup script's misleading
header comment is corrected. The dominant trap and its recovery are proven end to end by an
integration test in the default suite.


## Progress

- [x] Milestone 1: `preflightFreshLedgerOverCodd` in the library; `up` path refuses codd-ledgered databases without the override; preflight behavior covered by integration tests (blocked on `codd` and `codd_schema` fixtures, clear on empty and imported databases). Completed 2026-07-23: all 25 default migration examples pass; the scratch CLI drill exited 1 naming `codd.sql_migrations`, rejected override use with `status`, and the override reached and completed the 28-migration runner.
- [ ] Milestone 2: `keiro-migrate import-codd-history` subcommand mounted over `frameworkCoddSourceConfig`/`frameworkCoddHistoryMappings`; manual transcript recorded.
- [ ] Milestone 3: end-to-end recovery test for the dominant trap (up → poisoned ledger → recovery → import succeeds → verify green → up green).
- [ ] Milestone 4: cutover runbook rewritten (preflight, sentinel fixup step, import subcommand, recovery procedure for both variants, post-cutover validation reference); fixup header comment corrected; suite green.


## Surprises & Discoveries

- pg-migrate deliberately keeps `ConnectionProvider` opaque. A Keiro-defined Hasql
  session cannot be run through it without importing runner internals, so the planned
  preflight signature cannot accept a provider. The sibling live-schema API already
  establishes the supported application boundary: accept `Hasql.Connection.Settings`
  and bracket a dedicated connection.

- pg-migrate's safe facade keeps `MigrationId` opaque, while the separately exposed
  `Database.PostgreSQL.Migrate.Internal` module supplies the text accessors used by
  pg-migrate-cli's own renderers. The Keiro executable may use those accessors only for
  human rendering; JSON continues through the stable `renderHistoryImportJson` boundary.


## Decision Log

- Decision: Implement the preflight keiro-side (in `keiro-migrations`), not as an upstream
  pg-migrate pre-apply hook, and accept the check-before-lock TOCTOU with documented
  rationale.
  Rationale: The master plan left this open. Reading pg-migrate's runner surface settles
  it: the advisory lock is taken inside `runLocked` (`Runner.hs`), the runner module is not
  an exposed package module, and the only public in-lock extension point is the
  `RunOptions` event handler (`LockAcquired`), which receives no connection and would turn
  an exception into control flow — workable but contorted. A keiro-side check therefore
  runs before the lock, opening a window between check and apply. That window is
  acceptable because the guarded hazard is *operator error against pre-existing state* — a
  codd ledger is not something a concurrent process creates during the window; concurrent
  `keiro-migrate up` invocations all observe the same pre-existing ledger state, and a
  concurrently *running* legacy codd writer is already forbidden by the runbook's
  quiescence requirement. The upstream alternative (a `preApplyCheck` hook inside the
  lock) would serve kiroku-store-migrate too but costs a coordinated release of all three
  family packages (`pg-migrate`, `pg-migrate-embed`, `pg-migrate-import-codd`, all pinned
  `^>=1.1.0.0`) for a race that does not exist in practice. kiroku-store-migrate has the
  same trap; that parity fix is recorded here as a follow-up for the kiroku repository
  (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`, its `kiroku-store-migrations/app/Main.hs`
  is the same thin shell) and is deliberately NOT done in this plan.
  Date: 2026-07-23

- Decision: The preflight blocks exactly when a codd ledger table exists AND the native
  ledger is absent or empty; it does not block when the native ledger already has rows.
  Rationale: The master plan's wording is "refuses to initialize an empty native ledger
  when a codd ledger exists". A database that already imported its history has both a codd
  ledger (retired, read-only) and a populated native ledger — `up` must proceed there. A
  *poisoned* ledger (rows but no import audit) also has rows; rerunning `up` there fails
  on its own at the same tripwire and the documented recovery is the remedy — widening the
  preflight to inspect audit rows would complicate the rule for no additional safety.
  Date: 2026-07-23

- Decision: The override is a global `--allow-fresh-ledger-over-codd` switch on
  `keiro-migrate` (usable as `keiro-migrate --allow-fresh-ledger-over-codd up`), rejected
  with a usage error when combined with any command other than `up`.
  Rationale: The `up` option parser lives inside pg-migrate-cli's `migrationCommandParser`
  and its sub-parsers are not exported; duplicating them keiro-side to attach one flag
  invites drift, and adding the flag upstream is an upstream release. A validated global
  switch is additive and honest about scope.
  Date: 2026-07-23

- Decision: Mount a keiro-shaped `import-codd-history` subcommand (source URL, lock key,
  reason, confirm, JSON) dispatching to `importCoddHistory` with the compiled-in
  `frameworkCoddSourceConfig` and `frameworkCoddHistoryMappings`, instead of mounting
  pg-migrate-import-codd's `coddImportCommandParser` verbatim.
  Rationale: The shipped parser was read and verified: it exists
  (`Database.PostgreSQL.Migrate.History.Codd.coddImportCommandParser :: MigrationPlan ->
  Parser CoddImportCommand`), but its `CoddImportCommand` requires `--mapping PATH`, an
  application-interpreted "mapping artifact" for which no parser ships anywhere in the
  family, plus optional `--manifest`/`--source-directory` paths. keiro's mappings,
  manifest, and exact source payloads are compiled into the library and already verified
  against the plan by the default suite (`validateHistoryMappingTargets` at
  `keiro-migrations/test/Main.hs:79`); inventing an on-disk mapping format that must agree
  with the compiled-in truth would add a divergence surface, not remove one. The keiro
  parser reuses the shipped command's option vocabulary (`--source-database-url`,
  `--source-lock-key`, `--confirm`, `--json`) so a future move to the generic parser stays
  cheap. Strict source mode is always on (no flag): every documented cutover uses it, and
  a lax escape hatch is exactly the kind of bespoke variance this subcommand exists to
  eliminate.
  Date: 2026-07-23

- Decision: CLI glue stays in `keiro-migrations/app/Main.hs`; preflight and import logic
  live in the library and are integration-tested there; process-level exit codes are
  proven by recorded transcripts.
  Rationale: Moving dispatch into the library would drag `optparse-applicative`,
  `pg-migrate-cli`, and `aeson` into a library consumed by every service. The observable
  contract (nonzero exit naming the codd ledger) is a one-line mapping from the tested
  library result.
  Date: 2026-07-23

- Decision: `preflightFreshLedgerOverCodd` accepts `Hasql.Connection.Settings.Settings`,
  not `ConnectionProvider`.
  Rationale: The provider's constructor is intentionally hidden from the safe facade and
  there is no public operation for running an application-defined session through it.
  Importing runner internals would couple this integrity gate to an unsupported
  implementation detail. Settings preserve the CLI's exact `--database-url` over
  `DATABASE_URL` precedence and match `verifyExpectedSchema`, the existing Keiro-owned
  read-only integrity API.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Work happens in the keiro repository (working directory
`/Users/shinzui/Keikaku/bokuno/keiro`; paths below are repository-relative unless
absolute). Read-only references: the pg-migrate repository at
`/Users/shinzui/Keikaku/bokuno/pg-migrate` (local source of the pinned 1.1.0.0 family) and
the kiroku repository at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

`docs/adr/0002-keiro-owns-live-schema-verification-under-pg-migrate.md` is relevant
background: it records that Keiro owns the default-build integrity gates pg-migrate does
not provide. This plan adds the distinct operator-safety policy for one-time codd
cutovers; that policy is an ADR candidate at completion. ADR 0001 concerns PGMQ telemetry
and is unrelated.

**Vocabulary.** "codd" is the retired migration runner; a *codd ledger* is its
applied-history table, `codd.sql_migrations` in current databases or
`codd_schema.sql_migrations` in older ones (codd renamed the schema mid-life; both shapes
occur in the fleet). The *native ledger* is pg-migrate's, in schema `pgmigrate` with
tables `ledger_metadata`, `migrations`, `history_imports`, and `repairs`
(pg-migrate `Ledger/Sql.hs`; schema name from `defaultLedgerConfig`, `Ledger/Types.hs`,
which also fixes the advisory lock key `0x70675F6D69677261`). The *codd import* is
pg-migrate-import-codd's verified transfer of codd history into the native ledger without
re-executing SQL. The *framework plan* is the two-component pg-migrate plan — kiroku's 8
migrations then keiro's 20 — built by `Keiro.Migrations.frameworkMigrationPlan` with
kiroku first (`keiro-migrations/src/Keiro/Migrations.hs`).

**The unguarded path, verified.** `keiro-migrations/app/Main.hs` parses with
pg-migrate-cli's `migrationCommandParser` and dispatches `up` via `runMigrationCommand`,
whose `runUp` (pg-migrate-cli `Handler.hs`, lines 150-159) calls `runMigrationPlanWith`
directly. Inside the runner, `runLocked` (pg-migrate `Runner.hs`) unconditionally runs
`initializeOrUpgradeLedger` and then treats everything not in the (new, empty) ledger as
pending. Greps for `codd`, `codd_schema`, and `sql_migrations` across `pg-migrate/src`,
`pg-migrate-cli/src`, and `keiro-migrations/src` confirm no preflight exists anywhere on
the up path; the only guard is prose at `docs/user/upgrading-to-the-keiro-schema.md`
lines 80-81 ("Do not run `up` first…").

**Dominant trap variant (codd-current database), verified mechanics.** The kiroku
component runs first. Its migrations 0001-0005 are effectively idempotent against a
codd-built schema (guarded `CREATE … IF NOT EXISTS` / `DROP … IF EXISTS` bodies), so each
applies as a net no-op and — because pg-migrate commits a transactional migration and its
ledger row atomically — commits a native ledger row. Migration
`kiroku/0006-stream-name-length-check` (kiroku repo,
`kiroku-store-migrations/migrations/0006-stream-name-length-check.sql`, lines 7-9) is an
**unguarded** `ALTER TABLE kiroku.streams ADD CONSTRAINT chk_streams_stream_name_length…`;
the constraint already exists in any codd database whose history includes the legacy file
`2026-06-14-14-01-17-stream-name-length-check.sql`, so the run aborts there with a
duplicate-object error — an *accidental* tripwire, not a designed guard. Committed damage:
five audit-less kiroku rows in `pgmigrate.migrations` (each committed atomically with its
no-op body), plus seconds of `ACCESS EXCLUSIVE` lock churn on live kiroku tables. No data
loss is possible in either component: there is no `TRUNCATE`, `DELETE FROM`, or `DROP
TABLE` in any of the 28 bodies; all `CREATE`s are `IF NOT EXISTS`; keiro 0008's unguarded
`DROP CONSTRAINT keiro_workflow_steps_pkey` is self-healing because the preceding `CREATE
TABLE IF NOT EXISTS` names its primary key deterministically. The current composed plan
contains 28 bodies after migrations 0019 and 0020 landed; neither new body changes this
analysis.

The poisoned ledger then cleanly blocks the import: pg-migrate's `classifyImport`
(`History.hs`, the `(Just migration, Nothing audit)` case falling through to
`HistoryImportConflict`) requires the ledger-row/audit-row *pair*, classification runs
before `persistImports`, so the failed import writes nothing; and `repair` cannot help —
it rejects transactional targets (`Repair.hs` lines 123-125) and Applied status (lines
136-137). Recovery requires the manual procedure this plan documents and tests.

**Worse trap variant (pre-2026-06-14 codd history), verified.** A codd database whose
history predates the stream-name-length migration sails past 0006. Against a
pre-remediation 0.1.0.0 layout (the `keiro_*` tables still living in the `kiroku` schema),
keiro's component then builds a complete parallel **empty** `keiro.*` schema and the whole
plan SUCCEEDS silently: a full 28-row audit-less native ledger, an import conflicted on
every id, and a subsequently deployed service reads the empty `keiro.*` tables while the
real workflow/timer/outbox rows sit invisible in `kiroku.keiro_*` — a silent operational
outage. Everything is recoverable; nothing is destroyed.

**Verified recovery (this becomes the documented procedure).** Confirm
`pgmigrate.migrations` contains only the erroneous rows and `pgmigrate.history_imports` is
empty; then `DROP SCHEMA pgmigrate CASCADE` — safe *only* under that precondition (no
prior legitimate native ledger), and sufficient because the importer re-initializes the
ledger itself (`History.hs` `importLocked` runs `initializeOrUpgradeLedger` first). Then
resume the documented runbook order: backup → remediation script if on the 0.1.0.0 layout
→ sentinel-ledger fixup if needed → codd history import → `verify` → `up`. Worst-variant
extra step, load-bearing: first verify the parallel `keiro.*` tables are all EMPTY and
drop them (`DROP SCHEMA keiro CASCADE` after row-count checks) *before* the remediation
script — the remediation script skips any table that already exists in `keiro`, so leaving
the empty parallels in place would strand the real rows in `kiroku` forever.

**The import machinery that exists but is unmounted.** The library side is complete and
tested: `Keiro.Migrations.History.Codd` (default build) exports
`frameworkCoddSourceConfig :: ConnectionProvider -> Bool -> Text -> Confirmation -> Either
CoddDefinitionError CoddSourceConfig` (compiled-in legacy filenames, exact payloads, and
the embedded `migrations.lock` manifest for both components) and
`frameworkCoddHistoryMappings :: NonEmpty HistoryMapping` (7 kiroku + 16 keiro
`SamePayload` mappings). pg-migrate-import-codd exposes `importCoddHistory ::
ImportOptions -> CoddSourceConfig -> ConnectionProvider -> MigrationPlan -> NonEmpty
HistoryMapping -> IO (Either CoddImportError HistoryImportReport)` plus
`coddImportCommandParser`/`CoddImportCommand (..)` and `defaultCoddLockKey =
0x6B69726F6B754D67`. The default suite's `importFixture` (`keiro-migrations/test/Main.hs`)
already exercises the full library path against both ledger schema shapes. What is missing
is only the CLI mounting — `app/Main.hs` handles exactly `Plan/List/Check/Status/Verify/
Up/Repair/New` (its `commandOutputFormat` case at lines 38-48 is exhaustive), so today
each service cutover writes bespoke Haskell. pg-migrate-cli additionally exports
`renderHistoryImportJson :: Text -> HistoryImportReport -> Value` for `--json` output.

**Sentinel-ledger fixup (finding MIG-6).** Alpha-era databases applied keiro migrations
under hand-assigned "sentinel" timestamps (for example `2026-05-17-00-00-00-…`); the files
were later renamed to real UTC timestamps. The codd import selects rows by the *new*
filenames, so an unfixed alpha ledger fails fail-safe with `CoddSelectedFilenameMissing`
(and, in strict mode, `CoddStrictSourceHasUnselected`) — correct but unexplained anywhere.
The shipped fixup script
`keiro-migrations/ledger-fixups/2026-07-05-realign-keiro-migration-timestamps.sql` rewrites
the 14 sentinel-named rows (two of the 16 legacy files never had sentinel names) to the
new identities, and the runbook never mentions it. Its header comment (lines 10-13) also
overstates itself: it claims the script "rewrites the `name` and `migration_timestamp`
columns … from the old identity to the new one", but the `UPDATE` at lines 63-64 sets
`migration_timestamp = remap.old_timestamp` — the value the row already has — so only
`name` actually changes. The comment gets corrected in Milestone 4 (a comment-only edit;
the file is transition evidence, not checksum-pinned, and the legacy suite test that
executes it is unaffected).

**How the suite provisions databases.** Follow `keiro-migrations/test/Main.hs`'s own
patterns: `withKeiroPg` (ephemeral-pg `startCached` with user `keiro`, `Pg.stop` teardown)
for databases the test controls, and its existing fixture helpers `applyLegacyPayloads`
(executes the compiled-in legacy SQL payloads, producing a faithful codd-built schema) and
`installCoddLedger connection sourceSchema partial includeExtra` (creates
`<schema>.sql_migrations` and inserts the 23 legacy rows). The default suite is
`keiro-migrations-test` (cabal line 383); the repository's CI gate is `just verify`, which
ends with `cabal test keiro-migrations-test`. Do not use `keiro-test-support` here — its
template-database fixture presupposes an already-migrated database, which these tests must
not start from.

**Cross-plan boundaries.** The sibling plan
`docs/plans/122-restore-live-schema-verification-body-lint-and-the-startup-handshake-under-pg-migrate.md`
adds a `verify-schema` subcommand to the same `app/Main.hs` and owns
`docs/user/migrations.md`; `docs/plans/123-add-the-embed-recompile-plugin-and-native-manifest-coverage.md`
owns `docs/user/migration-ownership.md`. This plan owns the `up`-path changes exclusively,
the new import subcommand, and the cutover-sequence section of
`docs/user/upgrading-to-the-keiro-schema.md`. Both CLI-extending plans are additive over a
shared `KeiroCommand` wrapper: whichever lands first creates it, the second adds
constructors; coordinate only on merge order. The master plan gives this plan a soft
dependency on plan 122 solely for the runbook's post-cutover validation reference: cite
`keiro-migrate verify-schema` by plan path and mark it forthcoming if 122 has not landed.


## Plan of Work

Four milestones; the suite is green after each.

### Milestone 1 — the preflight guard (MIG-5, fix 1)

Scope: a library preflight plus its CLI wiring and integration tests. At the end,
`keiro-migrate up` against a codd-ledgered database with no native history exits nonzero
naming the codd ledger, and the override proceeds.

Library, in `keiro-migrations/src/Keiro/Migrations.hs` (this keeps the API next to
`frameworkMigrationPlan`, which every consumer already imports; it needs `hasql` in the
library's `build-depends` — if plan 122's SchemaCheck milestone already added it, skip
that cabal edit):

```haskell
-- | Why 'up' must not proceed: which codd ledger exists, and the native state.
data CoddLedgerPreflight
    = CoddPreflightClear
    | CoddPreflightBlocked
        { coddLedgerTable :: Text
          -- ^ "codd.sql_migrations" or "codd_schema.sql_migrations".
        , nativeLedgerAbsent :: Bool
          -- ^ True when schema pgmigrate has no migrations table; False when the
          --   table exists but holds zero rows.
        }

-- | Refuse to initialize a fresh native ledger over a live codd ledger.
preflightFreshLedgerOverCodd ::
    Settings.Settings ->
    IO (Either MigrationError CoddLedgerPreflight)

renderCoddPreflight :: CoddLedgerPreflight -> Text
```

Implementation: one read-only session (bracket the connection the way pg-migrate's
`Inspection.hs` does, mapping errors to `ConnectionAcquisitionFailed` /
`DatabaseSessionFailed`). First statement:

```sql
SELECT to_regclass('codd.sql_migrations') IS NOT NULL,
       to_regclass('codd_schema.sql_migrations') IS NOT NULL,
       to_regclass('pgmigrate.migrations') IS NOT NULL
```

If neither codd table exists, return `CoddPreflightClear`. If a codd table exists and the
native table does not, return `CoddPreflightBlocked` with `nativeLedgerAbsent = True`. If
both exist, run `SELECT count(*) FROM pgmigrate.migrations` (safe now that existence is
known): zero rows blocks with `nativeLedgerAbsent = False`; any rows returns
`CoddPreflightClear` (see Decision Log for the boundary rationale — a populated ledger
means either a completed import, where `up` must work, or a poisoned one, where `up` fails
on its own and the documented recovery applies). `renderCoddPreflight` produces the
operator message, e.g.:

```text
refusing to run up: this database has a codd migration ledger (codd.sql_migrations)
and no native pg-migrate history. Running up here would initialize a fresh ledger
over the codd one and re-plan every migration. Follow
docs/user/upgrading-to-the-keiro-schema.md (import the codd history first), or pass
--allow-fresh-ledger-over-codd if a fresh native ledger over the retired codd
ledger is genuinely intended.
```

CLI, in `keiro-migrations/app/Main.hs`: introduce the wrapper (or extend it if plan 122
landed first):

```haskell
data KeiroInvocation = KeiroInvocation
    { allowFreshLedgerOverCodd :: Bool
    , keiroCommand :: KeiroCommand
    }

data KeiroCommand
    = Framework MigrationCommand
    -- plan 122 adds: | VerifySchema …
    -- Milestone 2 adds: | ImportCoddHistory …
```

Parse as `KeiroInvocation <$> switch (long "allow-fresh-ledger-over-codd" <> help …) <*>
keiroCommandParser plan`. Dispatch rules: if the switch is set and the command is not
`Framework (Up _)`, exit with a usage error ("--allow-fresh-ledger-over-codd applies only
to up"). For `Framework (Up upOptions)` without the switch: resolve the connection
settings exactly as the command itself will (the `--database-url` inside `upOptions`'s
`ConnectionOptions` takes precedence over `DATABASE_URL` — mirror `selectProvider`'s
precedence from pg-migrate-cli's Handler), run `preflightFreshLedgerOverCodd`, and on
`CoddPreflightBlocked` print `renderCoddPreflight` to stderr and exit 1 without invoking
the runner; on `Clear` (or with the switch set) fall through to the unchanged
`runMigrationCommand` path. All other commands are untouched. This is the exclusive
`up`-path ownership the master plan assigns to this plan.

Integration tests in `keiro-migrations/test/Main.hs` (`describe "codd-ledger preflight"`),
using the existing helpers:

- Blocked on `codd`: `withKeiroPg` → `applyLegacyPayloads` + `installCoddLedger connection
  "codd" False False` → preflight returns `CoddPreflightBlocked{coddLedgerTable =
  "codd.sql_migrations", nativeLedgerAbsent = True}`, and `renderCoddPreflight` mentions
  `codd.sql_migrations`.
- Blocked on `codd_schema`: same with `"codd_schema"`; blocked naming
  `codd_schema.sql_migrations`.
- Clear on a fresh empty database (no codd fixture).
- Clear after a completed import: fixture as in the first case, then run the library
  import (`frameworkCoddSourceConfig` + `importCoddHistory`, exactly as the existing
  `importFixture` does) and assert the preflight is now `CoddPreflightClear`.

Acceptance: suite green; the manual CLI transcript in Concrete Steps shows exit 1 with the
naming message and exit 0 behavior restored by the override / by import.

### Milestone 2 — mount the codd import subcommand

Scope: `keiro-migrate import-codd-history`, wired over the compiled-in configuration.

Extend `KeiroCommand` with `ImportCoddHistory ImportCoddOptions` and add the subcommand to
the "Keiro" command group:

```haskell
data ImportCoddOptions = ImportCoddOptions
    { targetSettings :: Maybe Settings.Settings   -- --database-url (target; DATABASE_URL fallback)
    , sourceSettings :: Maybe Settings.Settings   -- --source-database-url (default: target)
    , sourceLockKey :: Int64                      -- --source-lock-key, default 0x6B69726F6B754D67
    , reason :: Text                              -- --reason (required, audited)
    , confirmation :: Confirmation                -- --confirm flag (NotConfirmed default)
    , jsonOutput :: Bool                          -- --json
    }
```

(Reuse the shipped vocabulary: `--source-database-url`, `--source-lock-key` with the
decimal-or-0x reader, `--confirm`, `--json` match `coddImportCommandParser`'s options; see
the Decision Log for why the parser itself is not mounted verbatim.) Dispatch: build the
target provider from `targetSettings`/`DATABASE_URL` and the source provider from
`sourceSettings` (defaulting to the target — the fleet's codd ledger lives in the same
database); `config <- frameworkCoddSourceConfig sourceProvider True reason confirmation`
(strict source always on), apply `withCoddLockKey` when the flag differs from the default;
run `importCoddHistory defaultImportOptions config targetProvider plan
frameworkCoddHistoryMappings`. Render: on success, one line per result (`imported
kiroku/0001-kiroku-bootstrap` / `already imported …`) and exit 0 — or, with `--json`,
`renderHistoryImportJson "codd" report`; on `Left`, show the `CoddImportError` and exit 1.
Two error cases deserve dedicated hints in the rendering, because Milestone 4's runbook
points at them: `CoddSelectedFilenameMissing` and `CoddStrictSourceHasUnselected` append
"if this ledger predates the 2026-07-05 filename realignment, run
keiro-migrations/ledger-fixups/2026-07-05-realign-keiro-migration-timestamps.sql first";
`CoddTargetImportFailed (HistoryImportConflict _)` appends "the native ledger already has
rows without import evidence — see the recovery procedure in
docs/user/upgrading-to-the-keiro-schema.md".

The library import path is already integration-tested (`importFixture` covers both ledger
shapes, partial-row rejection, and strict-mode extras); Milestone 3 adds the
recovery-shaped flow. For the CLI layer itself, record the manual transcript in Concrete
Steps (import against a scratch database prepared with the suite's fixture SQL), showing
`--confirm` required (`CoddConfirmationRequired` without it) and the success rendering.

Acceptance: `cabal run keiro-migrate -- import-codd-history --help` shows the options;
the manual transcript demonstrates a full import with exit 0 and idempotent re-run
(`already imported` × 23).

### Milestone 3 — the recovery procedure, proven end to end (dominant trap)

Scope: one integration test that walks the exact incident and the exact documented
recovery, in `keiro-migrations/test/Main.hs` (`describe "poisoned-ledger recovery"`, "up
before import poisons the ledger and the documented recovery restores the cutover"):

1. Fixture: `withKeiroPg` → `applyLegacyPayloads` + `installCoddLedger connection "codd"
   False False` — a faithful codd-current production stand-in.
2. Reproduce the incident (what an operator with the override, or yesterday's binary,
   would hit): `runMigrationPlan defaultRunOptions settings plan` must return `Left` (the
   kiroku/0006 duplicate-constraint abort). Assert the poisoned state precisely:
   `pgmigrate.migrations` holds exactly 5 rows, all with `component = 'kiroku'`, and
   `pgmigrate.history_imports` holds 0 rows (one SQL statement mirroring the suite's
   existing `importFactsStatement` style).
3. Assert the import is blocked as analyzed: running the library import now returns
   `Left (CoddTargetImportFailed (HistoryImportConflict _))` (pattern-match with a
   wildcard on the id).
4. Recovery step 1 — precondition check *as the runbook words it*: re-assert step 2's
   facts (only erroneous rows; no import audit).
5. Recovery step 2: `Session.script "DROP SCHEMA pgmigrate CASCADE;"`.
6. Recovery step 3: the import now succeeds — 23 `Imported` outcomes (the importer
   re-initialized the ledger itself).
7. Post-recovery proof: `verifyMigrationPlan` reports exactly five `PendingMigration`
   issues (`kiroku/0008-schema-management-comment` and Keiro migrations 0017 through 0020)
   and nothing else; `runMigrationPlan` applies exactly those five
   (`AlreadyApplied` × 7, `AppliedNow`, `AlreadyApplied` × 16, `AppliedNow` × 4); a final
   `verifyMigrationPlan` has no issues; the existing `assertSchema` helper passes.

The worse variant (pre-2026-06-14 history on a 0.1.0.0 layout) is covered by runbook text
only, per the master plan ("both trap variants at least covered by the runbook text; the
dominant one by test") — reproducing it would require synthesizing a pre-remediation
schema layout and a truncated codd history, which buys little beyond what steps 5-7
already prove about the recovery machinery.

Acceptance: the test passes in `cabal test keiro-migrations-test`; temporarily skipping
step 5 (the DROP) makes step 6 fail with the conflict — run once locally to confirm the
test can fail, then restore.

### Milestone 4 — runbook corrections and the fixup header (MIG-6)

Scope: documentation that turns the verified analysis into the operator path. This plan
owns the cutover sequence of `docs/user/upgrading-to-the-keiro-schema.md` (its sections
"3. Import Legacy History" and "4. Run And Verify The Native Plan", plus new subsections);
leave sections 1, 2, 5, 6 intact except where noted.

Rewrite section 3 as the guarded, CLI-driven sequence:

- State the preflight up front: `keiro-migrate up` now refuses a codd-ledgered database
  with no native history, naming the ledger; the refusal is the guard rail for the trap
  this section prevents, and `--allow-fresh-ledger-over-codd` exists only for the rare
  deliberate fresh-start (never during a cutover).
- New subsection "3a. Realign sentinel-named ledger rows (alpha-era databases only)": if
  the codd ledger contains sentinel-named keiro rows (give the check query from the fixup
  script's own sanity-check comment), run
  `keiro-migrations/ledger-fixups/2026-07-05-realign-keiro-migration-timestamps.sql` via
  `psql --single-transaction` first; explain that skipping it makes the import fail
  fail-safe with `CoddSelectedFilenameMissing` / `CoddStrictSourceHasUnselected` and
  nothing is written.
- Replace the bespoke-Haskell import instruction with the subcommand:

```bash
export DATABASE_URL='host=/tmp port=5432 dbname=keiro user=keiro_admin'
cabal run keiro-migrate -- import-codd-history \
  --reason "service cutover to pg-migrate" \
  --confirm
```

- New subsection "Recovery: `up` ran before the import" with the verified procedure,
  verbatim from the analysis: the precondition check (SQL snippets listing
  `pgmigrate.migrations` rows and asserting `pgmigrate.history_imports` is empty; name
  all four ledger tables so the operator recognizes the schema), the `DROP SCHEMA
  pgmigrate CASCADE` with its precondition stated as a warning (never with a prior
  legitimate native ledger), the note that the importer re-initializes the schema, and
  the instruction to resume at the top of the runbook order (backup → remediation if
  0.1.0.0 layout → 3a fixup if needed → import → verify → up). Include the worse-variant
  paragraph: how to recognize it (a *successful* `up` on a codd database; `keiro.*`
  tables all empty while `kiroku.keiro_*` holds the real rows — give the comparison
  query), and its extra step: verify every parallel `keiro.*` table is empty, then drop
  the parallel schema *before* running the remediation script, because the remediation
  skips tables that already exist in `keiro` and would otherwise strand the real rows.

In section 4, add the post-cutover state-equivalence check: after `verify` and `up`, run
`keiro-migrate verify-schema` (restored by
`docs/plans/122-restore-live-schema-verification-body-lint-and-the-startup-handshake-under-pg-migrate.md`;
if that plan has not landed when this section is written, phrase it as forthcoming and
name the plan path — the master plan's soft-dependency rule).

Finally correct the fixup header: edit lines 10-13 of
`keiro-migrations/ledger-fixups/2026-07-05-realign-keiro-migration-timestamps.sql` so the
comment says the script rewrites the `name` column only, re-asserting
`migration_timestamp` at its originally recorded value (a deliberate no-op that keeps the
statement idempotent), and therefore changes only codd's row *identity*, never a
timestamp and never schema. Comment-only change; the legacy suite test that executes this
script is unaffected.

Acceptance: the runbook reads as one linear operator path with no bespoke-Haskell step;
every SQL/CLI snippet in it is copy-pasteable; the fixup header no longer contradicts its
own `UPDATE`.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

Per-milestone build-and-test loop:

```bash
cabal build keiro-migrations
cabal test keiro-migrations-test
```

Milestone 1 manual CLI drill (uses a scratch database; the fixture SQL is exactly what the
suite's `installCoddLedger` generates — for the manual drill it is enough to create the
table and one row):

```bash
createdb preflight_drill
psql -d preflight_drill -c "CREATE SCHEMA codd;
  CREATE TABLE codd.sql_migrations (id serial, migration_timestamp timestamptz NOT NULL,
    applied_at timestamptz, name text NOT NULL, application_duration interval,
    num_applied_statements int, no_txn_failed_at timestamptz, txnid bigint, connid int);
  INSERT INTO codd.sql_migrations (migration_timestamp, applied_at, name)
    VALUES (now(), now(), '2026-05-16-12-17-14-kiroku-bootstrap.sql');"
export DATABASE_URL="host=/tmp port=5432 dbname=preflight_drill user=$(whoami)"
cabal run keiro-migrate -- up; echo "exit=$?"
```

Expected:

```text
refusing to run up: this database has a codd migration ledger (codd.sql_migrations)
and no native pg-migrate history. ...
exit=1
```

Then confirm the override reaches the runner (it will proceed into the plan — fine on a
scratch database) and that non-up usage of the flag is rejected:

```bash
cabal run keiro-migrate -- --allow-fresh-ledger-over-codd status; echo "exit=$?"   # usage error, exit != 0
cabal run keiro-migrate -- --allow-fresh-ledger-over-codd up; echo "exit=$?"       # runner invoked
dropdb preflight_drill
```

Milestone 2 manual import drill (scratch database prepared with the full fixture; easiest
is to let the new recovery test's fixture SQL guide you, or run the drill against an
ephemeral server):

```bash
cabal run keiro-migrate -- import-codd-history --reason "drill" ; echo "exit=$?"
# expect CoddConfirmationRequired and exit=1
cabal run keiro-migrate -- import-codd-history --reason "drill" --confirm
```

Expected success tail:

```text
imported kiroku/0001-kiroku-bootstrap
...
imported keiro/0016-keiro-inbox-drop-received-idx
exit=0
```

and an immediate re-run printing `already imported …` for all 23.

Milestone 3:

```bash
cabal test keiro-migrations-test
```

The new example group must appear:

```text
poisoned-ledger recovery
  up before import poisons the ledger and the documented recovery restores the cutover [✔]
```

Milestone 4 is documentation; validate the snippets by pasting each into the Milestone 1/2
drills, then finish with:

```bash
just verify
```


## Validation and Acceptance

1. Preflight, library level: the four preflight examples pass — blocked (with table name)
   on `codd` and `codd_schema` fixtures, clear on empty, clear after import.
2. Preflight, operator level: the Milestone 1 transcript shows `up` exiting 1 with a
   message naming `codd.sql_migrations`, the override proceeding, and the flag rejected
   with any other command.
3. Import subcommand: `import-codd-history --help` lists
   `--database-url`, `--source-database-url`, `--source-lock-key` (showing the default),
   `--reason`, `--confirm`, `--json`; without `--confirm` it fails with
   `CoddConfirmationRequired`; with it, a fixture database imports 23 entries and a
   re-run reports all 23 already imported.
4. Recovery: the Milestone 3 test passes, encoding the master-plan sequence "run up →
   poisoned ledger → recovery → import succeeds → verify green"; skipping its DROP step
   makes it fail (spot-checked once, then restored).
5. Runbook: `docs/user/upgrading-to-the-keiro-schema.md` contains the preflight
   explanation, the 3a sentinel-fixup step with its failure-mode names, the
   import-subcommand invocation, the recovery subsection covering both variants (with the
   empty-parallel-`keiro.*` drop ordered before the remediation script), and the
   post-cutover `verify-schema` reference (or its "forthcoming" phrasing citing plan 122's
   path).
6. Fixup header: lines around 10-13 of the fixup script no longer claim a
   `migration_timestamp` rewrite; `git diff` for that file shows comment-only changes.
7. No file in `/Users/shinzui/Keikaku/bokuno/pg-migrate` changed; `git -C
   /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku status` unchanged (kiroku parity is
   a recorded follow-up, not work here).
8. `just verify` green.


## Idempotence and Recovery

Suite tests run on ephemeral databases and are re-runnable. The manual drills use scratch
databases you create and drop; nothing touches a persistent database. The preflight itself
is read-only. The riskiest documented operation — `DROP SCHEMA pgmigrate CASCADE` — is
guarded twice: in the runbook by its stated precondition (only erroneous audit-less rows,
empty `history_imports`, checked immediately before), and in this plan's test, which
executes it only inside an ephemeral fixture. The codd import is idempotent by
construction (re-import classifies to `AlreadyImported` and writes nothing new), which the
Milestone 2 drill demonstrates. All code changes are additive (new library API, new
subcommand, a pre-dispatch check); `git checkout` of the touched files is a complete
rollback at any point. If the Milestone 3 incident reproduction ever stops aborting at
kiroku/0006 (for example, a future kiroku migration guards the constraint), that is a
material change to the trap analysis: record it in Surprises & Discoveries and update both
the test and the runbook — the preflight (which does not depend on the tripwire) remains
the guard either way.


## Interfaces and Dependencies

Packages, all already pinned in `keiro-migrations/keiro-migrations.cabal` — no version
changes and no pg-migrate upstream edits (the upstream-hook alternative was considered and
rejected; see Decision Log): `pg-migrate ^>=1.1.0.0` (`runMigrationPlanWith`,
`MigrationError (..)`, `ConnectionProvider`, `connectionProviderFromSettings`,
`Confirmation (..)`, `defaultImportOptions`, verification API), `pg-migrate-cli
^>=1.1.0.0` (`migrationCommandParser`, `runMigrationCommand`, `MigrationCommand (..)`,
`renderHistoryImportJson`), `pg-migrate-import-codd ^>=1.1.0.0`
(`importCoddHistory`, `CoddImportError (..)`, `defaultCoddLockKey`, `withCoddLockKey`),
`hasql` (library preflight session — dependency added by this plan or already present via
plan 122), `optparse-applicative` (executable, already present). Library-internal:
`Keiro.Migrations.History.Codd.frameworkCoddSourceConfig` and
`frameworkCoddHistoryMappings` as described in Context.

Signatures that must exist at the end of each milestone:

- Milestone 1: `Keiro.Migrations.preflightFreshLedgerOverCodd ::
  Hasql.Connection.Settings.Settings -> IO (Either MigrationError
  CoddLedgerPreflight)`; `CoddLedgerPreflight (..)` with
  `coddLedgerTable :: Text` and `nativeLedgerAbsent :: Bool`; `renderCoddPreflight ::
  CoddLedgerPreflight -> Text`; `keiro-migrate` accepting
  `--allow-fresh-ledger-over-codd` and refusing blocked `up` with exit 1.
- Milestone 2: `keiro-migrate import-codd-history --reason TEXT [--confirm]
  [--database-url URL] [--source-database-url URL] [--source-lock-key INT64] [--json]`,
  exit 0 on success/idempotent re-run, 1 otherwise, with the two error hints wired.
- Milestone 3: the recovery test in `keiro-migrations/test/Main.hs` as specified.
- Milestone 4: the rewritten runbook sections and the corrected fixup header.

Cross-plan interface: the `KeiroCommand` wrapper in `keiro-migrations/app/Main.hs` is
shared with `docs/plans/122-restore-live-schema-verification-body-lint-and-the-startup-handshake-under-pg-migrate.md`
(additive constructors, merge-order coordination only). Recorded follow-up (not in this
plan): mirror the preflight in the kiroku repository's `kiroku-store-migrate` CLI, which
has the identical unguarded `up` path.


Revision note (2026-07-23): Inherited the MasterPlan intention, incorporated ADR 0002,
and revised the plan-authoring 18/26 counts and three-pending recovery expectation to the
current 20-file Keiro component, 28-entry composed plan, and five post-import pending
migrations after 0019 and 0020 landed. Reconciled the preflight signature with
pg-migrate's opaque provider boundary: it now accepts Hasql settings, as the existing
live-schema checker does.
