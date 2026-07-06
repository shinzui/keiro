---
id: 92
slug: harden-the-migration-apply-path-strict-cli-drift-exit-codes-single-try-retries-and-advisory-lock-serialization
title: "Harden the migration apply path: strict CLI, drift exit codes, single-try retries, and advisory-lock serialization"
kind: exec-plan
created_at: 2026-07-06T18:39:48Z
intention: "intention_01kwwbahspe0tazeaa1gk5w65b"
master_plan: "docs/masterplans/13-migration-hardening-integrity-gates-safe-apply-path-operator-tooling-and-the-migration-ownership-guide.md"
---

# Harden the migration apply path: strict CLI, drift exit codes, single-try retries, and advisory-lock serialization

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan spans **both repositories**: the kiroku repository at
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` (its
`kiroku-store-migrations/` package goes first) and this repository
(`/Users/shinzui/Keikaku/bokuno/keiro`, the `keiro-migrations/` package plus one
`cabal.project` pin bump). Every commit in either repository carries:

```text
MasterPlan: docs/masterplans/13-migration-hardening-integrity-gates-safe-apply-path-operator-tooling-and-the-migration-ownership-guide.md
ExecPlan: docs/plans/92-harden-the-migration-apply-path-strict-cli-drift-exit-codes-single-try-retries-and-advisory-lock-serialization.md
Intention: intention_01kwwbahspe0tazeaa1gk5w65b
```

Soft dependencies: plans 90 and 91 (the integrity gates) edit the same runner modules
and executables; implement this plan after them, or coordinate carefully on
`src/Kiroku/Store/Migrations.hs`, `src/Keiro/Migrations.hs`, and both `app/Main.hs`
files. This plan does not *require* their artifacts except where noted (the
concurrent-apply test is nicer with plan 90's `embeddedMigrationNames`, but can count
ledger rows instead).


## Purpose / Big Picture

The `kiroku-store-migrate` and `keiro-migrate` executables are what every framework
user runs against their production database, and today they have four sharp edges,
all verified against the pinned codd `v0.1.8` source (checkout
`/Users/shinzui/Keikaku/hub/haskell/codd-project`, tag `v0.1.8`):

1. **A typo applies migrations.** Both dispatchers are `("new" : rest) -> generate; _
   -> migrate` — `keiro-migrate nwe "add index"` (or any unknown argument) silently
   applies migrations to whatever database `CODD_CONNECTION` names.
2. **Drift exits 0.** `keiro-migrate` runs codd's `LaxCheck` and discards the result
   (`_ <- runAllKeiroMigrations …` in `keiro-migrations/app/Main.hs`). `LaxCheck`
   returns `SchemasDiffer` without throwing (`src/Codd.hs:73-90`), so a production
   database whose schema has drifted from the expected snapshot still gets exit code 0.
   Also, `KEIRO_MIGRATE_NO_CHECK` is tested for *presence* — `KEIRO_MIGRATE_NO_CHECK=false`
   disables checking.
3. **Retries crash with a masking error.** codd re-reads each migration on retry, and
   for in-memory (embedded) migrations that path is
   `error "Re-reading in-memory streams is not yet implemented"`
   (`src/Codd/Internal.hs:1218,1232`). The executables inherit
   `defaultRetryPolicy = RetryPolicy 2 (ExponentialBackoff 1s)` (`src/Codd/Types.hs:95`)
   via `getCoddSettings` unless `CODD_RETRY_POLICY` says otherwise, so any transient
   failure (deadlock, dropped connection) in production surfaces as that unrelated
   crash instead of the real error. Test suites never see this — they pass
   `singleTryPolicy` explicitly.
4. **Concurrent applies race.** codd has no advisory locking anywhere in its apply
   path. Framework users run migrate-before-startup on multi-replica deployments; two
   concurrent applies both compute the same pending set, the loser hits the ledger's
   `UNIQUE (name)` violation, rolls back, and then hits edge 3's retry crash.

After this plan: unknown arguments print usage and exit 2 without touching the
database; `keiro-migrate` exits nonzero when `LaxCheck` reports drift (and
`KEIRO_MIGRATE_NO_CHECK` parses its value); both packages' embedded-migration runners
force `singleTryPolicy` so the real error always surfaces once, loudly; and both
executables take a session-level PostgreSQL advisory lock (one shared key, since
`keiro-migrate` applies kiroku's migrations too) so concurrent applies serialize — a
test proves two simultaneous applies against one fresh database both succeed.


## Progress

- [ ] M1 (kiroku): strict CLI dispatcher (`new`, `lock`, `up`, bare = apply; anything
      else = usage + exit 2).
- [ ] M2 (kiroku): `withMigrationLock` + `migrationAdvisoryLockKey` exported;
      `runKirokuMigrations*` take the lock and force `singleTryPolicy`;
      concurrent-apply test green.
- [ ] M3 (kiroku): README notes (lock semantics, single-try rationale); CHANGELOG.
- [ ] M4 (keiro): pin bumped; strict CLI dispatcher; drift exits nonzero;
      `KEIRO_MIGRATE_NO_CHECK` value parsing.
- [ ] M5 (keiro): `runKeiroMigrations*`/`runAllKeiroMigrations*` wrapped with the
      shared lock and `singleTryPolicy`; concurrent-apply test green.
- [ ] M6 (keiro): README/docs notes; CHANGELOG; upstream codd issue for the in-memory
      re-read error filed or noted.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Force `singleTryPolicy` inside the embedded runners regardless of
  `CODD_RETRY_POLICY`, logging a note when the environment asked for retries.
  Rationale: codd `v0.1.8` cannot retry in-memory migrations (the re-read is a hard
  `error`), so honoring a retry policy converts every transient failure into a
  misleading crash. Fail once with the real error. Revisit when upstream implements
  in-memory re-reads.
  Date: 2026-07-06

- Decision: One advisory-lock key for both executables, defined in
  `kiroku-store-migrations` and imported by keiro; session-level
  (`pg_advisory_lock`) on a dedicated connection that is closed after the apply.
  Rationale: `keiro-migrate` applies kiroku's migrations, so the two executables must
  serialize against *each other* on the same database. PostgreSQL advisory locks are
  scoped per database within a cluster, so parallel test databases on one ephemeral
  cluster do not contend. Session-level (not transaction-level) because codd manages
  its own transactions across multiple connections; holding the lock on a separate
  bracket-managed connection is simplest and releases even on crash (connection close
  releases session locks).
  Date: 2026-07-06

- Decision: Keep bare invocation (`keiro-migrate` with no arguments) meaning "apply",
  and add `up` as an explicit synonym.
  Rationale: bare invocation is the documented interface in both READMEs and every
  deployment script; breaking it buys nothing. `up` gives scripts an explicit verb and
  matches codd's own CLI vocabulary.
  Date: 2026-07-06


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Current code, kiroku side
(`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store-migrations/`):
`app/Main.hs` dispatches `("new" : rest)` to the scaffolder and everything else to
`migrate`, which calls `getCoddSettings` (codd's environment parser — reads
`CODD_CONNECTION`, `CODD_RETRY_POLICY`, etc.) and then
`runKirokuMigrationsNoCheck settings (secondsToDiffTime 5)`.
`src/Kiroku/Store/Migrations.hs` defines `runKirokuMigrations` /
`runKirokuMigrationsNoCheck` as thin wrappers over codd's `applyMigrations` /
`applyMigrationsNoCheck` with the embedded migration list. If plan 90 has landed, the
dispatcher also has a `("lock" : _)` case — preserve it.

Current code, keiro side (`keiro-migrations/`): `app/Main.hs` has the same dispatch
shape; `migrate` honors `KEIRO_MIGRATE_NO_CHECK` by `lookupEnv` presence, otherwise
runs `runAllKeiroMigrations settings (secondsToDiffTime 5) LaxCheck` and discards the
result. `src/Keiro/Migrations.hs` has four runners (`runKeiroMigrations[NoCheck]`,
`runAllKeiroMigrations[NoCheck]`).

Relevant codd `v0.1.8` API surface: `CoddSettings` is a record with a `retryPolicy`
field; `Codd.Types` exports `singleTryPolicy`, `ConnectionString`, and
`libpqConnString :: ConnectionString -> ByteString`; `Codd.ApplyResult` is
`SchemasDiffer SchemasPair | SchemasMatch DbRep | SchemasNotVerified`. For the lock
connection use `postgresql-simple` (already in both packages' transitive closure via
codd; add it to `build-depends` explicitly): `Database.PostgreSQL.Simple.connectPostgreSQL
(libpqConnString cs)`, `query_ conn "SELECT pg_advisory_lock(<key>)"`, and `close`.
Session-level advisory locks release automatically when the connection closes.

Both test suites use ephemeral PostgreSQL via `withKirokuPg`/`withKeiroPg`; use
`UnliftIO.Async.concurrently` (or `Control.Concurrent.Async`) for the concurrency
test — check which async facility each test suite already has in scope before adding a
dependency.


## Plan of Work

**Milestone 1 — kiroku strict CLI.** Rewrite `app/Main.hs`'s dispatcher:

```haskell
main = getArgs >>= \case
  []             -> migrate
  ["up"]         -> migrate
  ("new" : rest) -> generate (unwords rest)
  ("lock" : _)   -> writeLock          -- if plan 90 landed; otherwise omit
  other          -> usage other        -- prints usage to stderr, exitWith (ExitFailure 2)
```

`usage` names every subcommand and the offending argument. Nothing else changes.
Acceptance: `kiroku-store-migrate nwe x` exits 2 with a usage message and performs no
database work (verifiable with an unset `CODD_CONNECTION` — it must *not* fail with a
connection error, but with usage).

**Milestone 2 — kiroku lock + single-try.** In `src/Kiroku/Store/Migrations.hs` add:

```haskell
migrationAdvisoryLockKey :: Int64
migrationAdvisoryLockKey = 0x6B69_726F_6B75_4D67   -- ASCII "kirokuMg"; shared by keiro

withMigrationLock :: ConnectionString -> DiffTime -> IO a -> IO a
```

`withMigrationLock` brackets: connect via `postgresql-simple` to the same database the
settings target (`libpqConnString`), run `SELECT pg_advisory_lock(?)` with the key,
run the action, and `close` the connection in the cleanup (releasing the lock even on
exception). Then change `runKirokuMigrations` and `runKirokuMigrationsNoCheck` to
(a) override `settings { retryPolicy = singleTryPolicy }`, logging one line if the
incoming policy differed, and (b) wrap the codd call in
`withMigrationLock (migsConnString settings) connectTimeout`. Add the concurrent-apply
spec to `test/Main.hs`: on one fresh ephemeral database, run two
`runKirokuMigrationsNoCheck` concurrently; both must return without exception, and the
ledger must contain each migration name exactly once (reuse plan 90's canary helper if
present, else `SELECT count(*), count(DISTINCT name)`). Run this spec a few times
locally to shake out flakiness; note that *before* this milestone the same spec fails
intermittently with the `UNIQUE`-violation/retry crash — capture that failure output
once for the record and paste it into Surprises & Discoveries.

**Milestone 3 — kiroku docs.** README: a "Concurrent applies" section (the executable
serializes on a per-database advisory lock; one migrator per deploy is still the
recommendation) and a "Retries" note (single-try enforced and why — the codd in-memory
re-read limitation, with the upstream reference). CHANGELOG entry.

**Milestone 4 — keiro strict CLI + drift exit.** Bump the kiroku pin in
`cabal.project` (both stanzas) to the SHA containing M1–M3. Mirror the strict
dispatcher in `keiro-migrations/app/Main.hs`. Rework `migrate`: parse
`KEIRO_MIGRATE_NO_CHECK` — values `1`, `true`, `yes` (case-insensitive) enable
no-check; unset means checked; any other non-empty value logs a warning naming the
accepted forms and means checked. In the checked path, inspect the `ApplyResult`:
`SchemasMatch _` → exit 0; `SchemasDiffer _` → print a clear message ("schema drift
detected; see the codd diff above" — plan 93 adds `keiro-migrate verify` for
apply-free diagnosis) and `exitWith (ExitFailure 1)`; `SchemasNotVerified` → exit 0
(LaxCheck cannot produce it, but keep the case total).

**Milestone 5 — keiro lock + single-try.** In `src/Keiro/Migrations.hs`, wrap all four
runners with `Kiroku.Store.Migrations.withMigrationLock` (imported — same key, so
`keiro-migrate` and `kiroku-store-migrate` serialize against each other) and apply the
same `singleTryPolicy` override. Concurrent-apply spec in
`keiro-migrations/test/Main.hs` mirroring kiroku's, using
`runAllKeiroMigrationsNoCheck`.

**Milestone 6 — keiro docs and upstream note.** README + `docs/user/migrations.md`
concurrency/retry notes; CHANGELOG. File (or record the intent to file, with the exact
reproduction) an upstream codd issue for the in-memory re-read `error`; link it from
the code comment on the `singleTryPolicy` override in both packages.


## Concrete Steps

kiroku side, from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`:

```bash
cabal build kiroku-store-migrations
cabal test kiroku-store-migrations-test
cabal run kiroku-store-migrate -- nwe "typo"; echo "exit=$?"   # expect usage on stderr, exit=2
```

keiro side, from `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
cabal build keiro-migrations
cabal test keiro-migrations-test
cabal run keiro-migrate -- frobnicate; echo "exit=$?"          # expect usage on stderr, exit=2
```

Drift-exit drill (keiro, against a scratch database only): apply migrations, then via
psql `ALTER TABLE keiro.keiro_timers ALTER COLUMN last_error SET NOT NULL`, run
`keiro-migrate` with the expected-schema environment set, observe exit 1 and the drift
message; revert the column (`DROP NOT NULL`) and observe exit 0. Record the transcript
here when done.


## Validation and Acceptance

1. Unknown arguments: both executables exit 2 with usage, no database contact (works
   with `CODD_CONNECTION` unset).
2. Bare invocation and `up` still apply migrations — the README examples keep working.
3. Concurrent-apply specs pass repeatedly in both suites; the pre-fix failure mode was
   captured once in Surprises & Discoveries.
4. Drift drill: `keiro-migrate` exits 1 on a drifted schema, 0 on a clean one;
   `KEIRO_MIGRATE_NO_CHECK=false` now means *checked*.
5. Both runner modules force `singleTryPolicy` with a comment linking the upstream
   limitation.
6. Full suites green in both repositories.


## Idempotence and Recovery

All changes are code + docs; re-running builds/tests is safe. The drift drill mutates
a scratch database — use a throwaway `dbname` and drop it afterward; never point the
drill at a real database. If an advisory lock is ever stuck in development (a killed
process whose connection lingers), the lock dies with the connection —
`SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE state = 'idle' AND
application_name = ''` after inspection is the escape hatch; document it in the README
section. If the pin bump breaks the keiro build, the failure is immediate at
`cabal build`; re-check the kiroku SHA and re-bump.


## Interfaces and Dependencies

Provides, kiroku (`Kiroku.Store.Migrations`): `migrationAdvisoryLockKey :: Int64`,
`withMigrationLock :: ConnectionString -> DiffTime -> IO a -> IO a`; runners now
single-try and locked. `postgresql-simple` added to `build-depends`.

Provides, keiro: strict dispatchers in both executables (plan 93 **extends** this
dispatcher with `verify`/`status` — keep the shape a simple total `case`); drift exit
codes; locked single-try runners.

Consumes: codd `v0.1.8` (`Codd.Types.singleTryPolicy`, `libpqConnString`,
`CoddSettings.retryPolicy`, `ApplyResult`); plan 90's `lock` dispatcher case and
canary helper where present.
