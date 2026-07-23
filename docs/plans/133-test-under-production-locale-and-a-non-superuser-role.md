---
id: 133
slug: test-under-production-locale-and-a-non-superuser-role
title: "Test under production locale and a non-superuser role"
kind: exec-plan
created_at: 2026-07-23T04:18:42Z
master_plan: "docs/masterplans/22-make-the-test-infrastructure-exercise-real-crash-and-production-semantics.md"
---

# Test under production locale and a non-superuser role

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Every keiro test suite today runs against a PostgreSQL cluster initialized with `--no-locale` (byte-order "C" collation) and connects as the trust-authenticated superuser that ran `initdb`. Two whole classes of production failure are therefore invisible: text ordering that differs between C collation and a real locale (a read model's `ORDER BY name` can pass in tests and order differently in production), and privilege failures (a superuser bypasses all ACLs, so a production deployment that runs the application as a restricted role can fail on a missing `GRANT` in ways no test can catch — and keiro's migrations contain no `GRANT` at all, so the required privilege set has never been executable anywhere).

After this plan, the suite fixture can be started under a production-like locale, at least one read-model ordering test runs under it and asserts locale-sensitive order, the production role model (owner role migrates; service role runs the runtime) is written down as a canonical, executable GRANT script, and a smoke test provisions that role, applies that exact script, and runs a representative command/subscription/outbox/timer cycle as the non-superuser — plus a negative test proving a missing grant fails loudly, naming the object. You can see it working by running `cabal test keiro-test` from `/Users/shinzui/Keikaku/bokuno/keiro` and finding the new "production locale" and "service role" describe blocks passing — and by deleting one line from the GRANT script and watching the negative path's expected error become a real suite failure.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `productionLocaleConfig` exported from keiro-test-support; ICU-locale fixture starts; read-model ordering test passes under ICU and demonstrates divergence from C.
- [ ] M2: canonical GRANT script exists at `keiro-migrations/sql/keiro-runtime-grants.sql`; `docs/user/migration-ownership.md` references it as the source of truth.
- [ ] M3: service-role fixture helper added; positive smoke cycle (command, subscription read, outbox, timer) passes as the service role; negative missing-grant test passes; suite green in `just verify`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Authoring (2026-07-23): the claim "the production GRANT set exists nowhere" needed refinement — `docs/user/migration-ownership.md` lines 136–144 already contain a documentation-first GRANT snippet (USAGE on schemas `kiroku, keiro`; SELECT/INSERT/UPDATE/DELETE on all tables; USAGE, SELECT on sequences). It has never been executed by any test, and it is likely incomplete (no `ALTER DEFAULT PRIVILEGES` for tables added by future migrations, no function `EXECUTE`, nothing for the pgmq schema). This plan turns that prose into the executable, tested artifact.


## Decision Log

Record every decision made while working on the plan.

- Decision: The production-like locale fixture uses the ICU provider (`initdb --locale-provider=icu --icu-locale=en-US`), not libc `en_US.UTF-8`.
  Rationale: macOS libc collation is unreliable (BSD `strcoll` for UTF-8 effectively degenerates to byte order), so a libc locale would order differently between the macOS dev machine and Linux CI, making assertions non-portable. ICU gives one deterministic collation everywhere PostgreSQL is built with ICU; verified working with this environment's `initdb` (PostgreSQL 18.4): `initdb --locale-provider=icu --icu-locale=en-US` succeeds. Production deployments on glibc `en_US.UTF-8` are close to, but not bit-identical with, ICU; the plan documents this residual gap rather than pretending it away.
  Date: 2026-07-23

- Decision: On the "production parity vs mandating explicit `COLLATE`" question: keiro provides fixture parity (this plan's locale-parameterized fixture) and does *not* mandate `COLLATE` clauses in framework queries; application queries whose ordering is a user-facing contract are *recommended* (in docs) to state `COLLATE` explicitly.
  Rationale: Framework tables sort by ids, sequence numbers, and timestamps — not locale-sensitive text — so a blanket `COLLATE` mandate would churn SQL for no framework-level gain. The real risk sits in application read models, which keiro cannot rewrite; a fixture that reproduces production collation plus a documented recommendation is the enforceable part. Recorded here per the master plan's requirement to decide and record.
  Date: 2026-07-23

- Decision: The canonical GRANT script lives at `keiro-migrations/sql/keiro-runtime-grants.sql` (a plain SQL file, not a migration), and `docs/user/migration-ownership.md`'s inline snippet is replaced by a pointer to it.
  Rationale: It must not be a migration: grants reference a deployment-specific role name and re-running `GRANT` is idempotent anyway, while keiro's migration ledger is append-only and deployment-agnostic. It must be a checked-in executable file (not prose) so the M3 smoke test can execute *the artifact users are told to run*, making the docs incapable of drifting from what is tested. Placing it in keiro-migrations keeps it next to the schema it grants on. The script takes the role name via `psql`-style substitution (documented in its header) and the test applies it with the role name interpolated.
  Date: 2026-07-23

- Decision: The service role is created once per suite at fixture setup (roles are cluster-level in PostgreSQL), with `CREATE ROLE … LOGIN` guarded by an existence check; grants are applied per cloned database inside the helper.
  Rationale: `CREATE DATABASE … TEMPLATE` copies database-level ACLs on objects but roles live outside databases; creating the role idempotently at setup and granting per clone keeps every example isolated while avoiding role-name collisions across parallel examples.
  Date: 2026-07-23

- Decision: This plan reuses `withMigratedSuiteWithConfig` from ExecPlan 132 (docs/plans/132-add-real-crash-window-tests-on-a-durability-enabled-fixture.md) if it has landed; otherwise this plan adds the identical function itself (same name, same signature) and 132 adopts it.
  Rationale: MasterPlan 22's Integration Points say EP-1 lands the helper-naming convention first *if concurrent*; the convention is fixed here so either landing order converges on one function.
  Date: 2026-07-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

The keiro repository is at `/Users/shinzui/Keikaku/bokuno/keiro`; all repository-relative paths mean this repo. The test fixture library is `keiro-test-support/src/Keiro/Test/Postgres.hs`: `withMigratedSuiteWith` (line 94) starts one cached temporary PostgreSQL server per suite via `Pg.startCached Pg.defaultConfig Pg.defaultCacheConfig` (line 96, from the ephemeral-pg library), creates a template database, applies the kiroku + keiro migrations to it once, and clones an isolated database per example with `CREATE DATABASE … TEMPLATE …` (`withFreshDatabase`). That template-freshness and clone-isolation machinery is verified sound; everything this plan adds is additive around it.

ADR context: keiro's `docs/adr/` contains only `docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` (pgmq telemetry), irrelevant here. No relevant ADR exists. At completion this plan feeds two durable artifacts: the production GRANT set (also referenced by `docs/user/migration-ownership.md`) and, jointly with the sibling plans, MasterPlan 22's candidate testing-contract ADR.

Terms in plain language. *Collation* is the rule PostgreSQL uses to compare and sort text; it is fixed per database at creation (inherited from `initdb` unless overridden) and drives `ORDER BY`, comparison operators, and `LIKE` prefix optimizations. The *"C" collation* compares raw bytes: all uppercase letters sort before all lowercase (`Z` < `a`), and accented characters sort by their UTF-8 byte encoding (after all ASCII). A *real locale* (glibc `en_US.UTF-8` or an ICU locale like `en-US`) sorts case-insensitively-ish and interleaves accents (`apple` < `Banana` < `Éclair` < `zebra`). *ICU* is a portable collation library PostgreSQL can use instead of the OS's libc (`initdb --locale-provider=icu --icu-locale=en-US`). A *superuser* bypasses every privilege check; `initdb --auth=trust` means any local connection is accepted as any existing role without a password. *RLS* is row-level security — policies filtering rows per role; superusers bypass it too.

### TIN-3: everything runs on C collation

`EphemeralPg/Config.hs` (in the ephemeral-pg repo at `/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg`) `defaultInitDbArgs`, lines 191–197: `["--no-sync", "--encoding=UTF8", "--no-locale", "--auth=trust"]`. `--no-locale` pins every `lc_*` to C. `withMigratedSuite` inherits this (Postgres.hs line 96), and every clone inherits its template's collation. Consequence: any text `ORDER BY`, case/accent comparison, or `LIKE`-prefix assertion in the suites can pass under C and behave differently in a production database initialized with a real locale. Today no keiro test actually asserts locale-sensitive text order (the `ORDER BY`s in `keiro/test/Main.hs` are on integers — `ORDER BY seq` at line 8799, `ORDER BY target_id` at line 10620), which means the exposure is entirely in *application* read models — and there is zero infrastructure to test them honestly. The fix is parameterization plus one demonstrative test: `Config.initDbArgs` is an ordinary record field, and the initdb cache key already includes `initDbArgs` (`EphemeralPg/Internal/Cache.hs`, `getCacheKey`, lines 143–158), so a locale-parameterized fixture caches separately with no ephemeral-pg changes required. One caveat: `Config`'s `Semigroup` *appends* `initDbArgs`, so the locale config must be built by record update (replacing the list), not by `<>`, or `--no-locale` and `--icu-locale` would both be passed.

### TIN-4: everything runs as a trust-authenticated superuser

`initdb` makes its `--username` a superuser; ephemeral-pg uses the current OS user (`EphemeralPg.hs`, `getUsername`, lines 253–256) with `--auth=trust` (Config.hs line 196), and every clone connection string reuses the same user (`keiro-test-support/src/Keiro/Test/Postgres.hs`, `connectionStringFor`, lines 219–226). Superusers bypass ACLs and RLS, so no privilege failure can ever surface in a test. Meanwhile `keiro-migrations/migrations/` contains zero `GRANT`, `CREATE ROLE`, or `POLICY` statements (grep-verified), so a production owner-role/service-role split fails at runtime on missing `USAGE`/`SELECT`/… in ways the suite cannot reproduce. The intended model is already documented in prose: `docs/user/migration-ownership.md` — the "Operating" section (lines 111–144) says migrations run as an owner/administrator role, the runtime opens kiroku with `SkipSchemaInitialization`, and lines 136–144 give a starting GRANT snippet (USAGE on schemas `kiroku, keiro`; table DML; sequence usage). That snippet resolved the grants question documentation-first; it has never been executed anywhere, and its completeness is unknown. This plan makes it executable and proves it.

What the runtime actually needs, structurally: keiro's framework objects live in the `keiro` schema; kiroku's event store lives in `kiroku` (each pooled connection runs `SET search_path TO <schema>, pg_catalog` — see kiroku's `ConnectionSettings.schema` haddock). The store must be opened with runtime schema initialization disabled (`#schemaInitialization .~ SkipSchemaInitialization`, exactly as `docs/user/migration-ownership.md` lines 127–134 shows) because a service role must not (and cannot) create schema. The keiro-pgmq suite additionally installs the `pgmq` schema; the smoke cycle in this plan covers command/subscription/outbox/timer (per MasterPlan 22) and leaves pgmq grants as a documented extension point in the script's header, not a tested path.

### Relationship to the sibling plans

ExecPlan 132 (docs/plans/132-add-real-crash-window-tests-on-a-durability-enabled-fixture.md) introduces `withMigratedSuiteWithConfig` in keiro-test-support and a shared ephemeral-pg 0.3.0.0 release; ExecPlan 134 hardens ephemeral-pg startup. This plan needs *no* ephemeral-pg source change (`initDbArgs` is already parameterizable) — it only consumes whatever ephemeral-pg version keiro-test-support pins when the release train lands (MasterPlan 22, Integration Points: one release; the last-landing plan bumps the bound). There is no hard dependency between the plans; only the helper-name convention is shared (see Decision Log).


## Plan of Work

### Milestone 1 — locale-parameterized fixture and a production-locale ordering test

Scope: keiro-test-support plus one new test block in `keiro/test/Main.hs`. At the end, a suite can start its cached server under ICU `en-US`, and a read-model ordering test passes there while demonstrably diverging from C order.

In `keiro-test-support/src/Keiro/Test/Postgres.hs`, add and export `productionLocaleConfig :: Pg.Config`, built by record update so the argument list is *replaced*:

```haskell
productionLocaleConfig :: Pg.Config
productionLocaleConfig =
    Pg.defaultConfig
        { Pg.initDbArgs =
            [ "--no-sync"
            , "--encoding=UTF8"
            , "--locale-provider=icu"
            , "--icu-locale=en-US"
            , "--auth=trust"
            ]
        }
```

Document in its haddock: why record update and not `<>` (Semigroup appends `initDbArgs`; appending would pass both `--no-locale` and the ICU flags); that the cache key includes `initDbArgs` so this config gets its own cached cluster; and the ICU-vs-glibc residual gap from the Decision Log. If `withMigratedSuiteWithConfig` (ExecPlan 132) has not landed yet, add it here with the exact signature `withMigratedSuiteWithConfig :: Pg.Config -> [MigrationComponent] -> (Fixture -> IO a) -> IO a`, implemented like `withMigratedSuiteWith` but passing the config to `Pg.startCached`, and rebase `withMigratedSuiteWith` on it.

In `keiro/test/Main.hs`, start a second suite fixture under the production locale — `main` becomes `withMigratedSuite $ \fixture -> withMigratedSuiteWithConfig productionLocaleConfig [] $ \icuFixture -> hspec… ` (compose with whatever `main` already wraps when 132 has landed) — and add a `describe "production locale (ICU en-US)"` block that runs `around (withFreshStore icuFixture)`. The test: create a small read-model table through the production projection path the existing read-model tests use (find the nearest existing read-model test in `keiro/test/Main.hs` — the billing read-model tests around line 8799 show the house pattern: create the table with `Tx.sql`, feed events through the projection, query it); insert rows whose text names are `["apple", "Banana", "zebra", "Éclair"]`; query them `ORDER BY name`; assert ICU order `["apple", "Banana", "Éclair", "zebra"]`. Add the mirror-image example on the *default* (C) fixture asserting the C order `["Banana", "apple", "zebra", "Éclair"]` with a comment stating its purpose: it documents the divergence and fails loudly if someone ever silently changes the default fixture's collation. The pair is the honest demonstration: same data, same query, two orders.

Acceptance: `cabal test keiro-test` passes; deliberately swapping the two expected lists makes each example fail with a clear list mismatch, proving the collations really differ.

### Milestone 2 — the canonical GRANT script

Scope: keiro-migrations and the user docs. At the end, the production privilege set is one executable artifact.

Create `keiro-migrations/sql/keiro-runtime-grants.sql`. Header comment: what it is (the canonical runtime-role privilege set for a keiro application), who runs it (the owner/administrator role, after `keiro-migrate up`, and again after any future migration that adds objects — or once combined with the `ALTER DEFAULT PRIVILEGES` statements it contains), the placeholder convention (the role name appears as `:"app_role"` for `psql -v app_role=…` usage; the smoke test interpolates it textually), and the explicitly-out-of-scope extension point (pgmq: deployments using keiro-pgmq must additionally grant on the `pgmq` schema — list the statement shape in the comment). Body, derived from the `docs/user/migration-ownership.md` lines 136–144 snippet and completed:

```sql
GRANT USAGE ON SCHEMA kiroku, keiro TO :"app_role";
GRANT SELECT, INSERT, UPDATE, DELETE
  ON ALL TABLES IN SCHEMA kiroku, keiro TO :"app_role";
GRANT USAGE, SELECT
  ON ALL SEQUENCES IN SCHEMA kiroku, keiro TO :"app_role";
ALTER DEFAULT PRIVILEGES IN SCHEMA kiroku, keiro
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_role";
ALTER DEFAULT PRIVILEGES IN SCHEMA kiroku, keiro
  GRANT USAGE, SELECT ON SEQUENCES TO :"app_role";
```

Treat this body as the *starting* set: Milestone 3's smoke test is the completeness oracle — if the cycle fails with `permission denied for <object>`, the missing statement is added here (and only here). Note that `ALTER DEFAULT PRIVILEGES` as written applies to objects later created *by the role running the script* (the owner), which is exactly the migration-append case. If keiro's tables use functions the role must call (none known today — the `notify_events()` trigger runs with the table owner's rights), the oracle will say so.

Update `docs/user/migration-ownership.md`: replace the inline SQL at lines 136–144 with a short paragraph pointing at `keiro-migrations/sql/keiro-runtime-grants.sql` as the canonical, test-executed script, keeping the surrounding "Operating" prose (owner migrates; runtime opens with `SkipSchemaInitialization`) intact — coordinate the wording so the section still reads as the single narrative it is today.

Acceptance: the file exists, `git grep -n "GRANT USAGE ON SCHEMA kiroku" docs/user keiro-migrations` shows exactly one SQL source of truth (the docs hit is a reference, not a copy), and Milestone 3 executes the file.

### Milestone 3 — the non-superuser smoke suite

Scope: keiro-test-support helper plus a new describe block in `keiro/test/Main.hs`. At the end, a representative runtime cycle provably works with only the granted privileges, and a missing grant fails loudly.

In `keiro-test-support/src/Keiro/Test/Postgres.hs` add `withServiceRoleStore :: Fixture -> ((Store.KirokuStore, Text) -> IO ()) -> IO ()` (the `Text` is the service-role connection string, for tests needing raw sessions). Implementation: at first use, idempotently create the role on the fixture's server — `runSql fixture.server "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'keiro_service') THEN CREATE ROLE keiro_service LOGIN; END IF; END $$"` (trust auth means no password is needed); clone a fresh database with the existing `withFreshDatabase`; apply the GRANT script to the clone: read `keiro-migrations/sql/keiro-runtime-grants.sql` from disk (locate it relative to the repo root; the suite runs from the package directory, so resolve via the `keiro-migrations` path — embed with `data-files` or a relative `../keiro-migrations/sql/…` read; choose `data-files` of keiro-migrations if the relative read proves brittle and record the choice), substitute `:"app_role"` with `"keiro_service"`, and execute it as the *owner* on the clone; then build a connection string with `user=keiro_service` and open the store with `Store.defaultConnectionSettings … & #schemaInitialization .~ SkipSchemaInitialization`, passing it to the action. Add the negative-path variant `withServiceRoleStoreLackingTableGrants` that applies the script with the `ON ALL TABLES` statement filtered out.

In `keiro/test/Main.hs`, add `describe "service role (non-superuser)"` on the default fixture. Positive example — one representative cycle, all through production APIs as `keiro_service`: run a command that appends an event (any existing minimal aggregate command from the suite); read it back through a subscription/read path; enqueue an integration event to the outbox (`enqueueIntegrationEventTx`), claim and mark it sent (`claimOutboxBatch`, `markOutboxSent`); schedule and fire a timer (`scheduleTimerTx`, `claimDueTimer`, `markTimerFired`). Assert each step succeeds — the assertion is that *none* of them throws a privilege error. Negative example — using `withServiceRoleStoreLackingTableGrants`, attempt the same first command and assert it fails with a `StoreError` whose rendered text contains `permission denied for table` and the specific table name (capture whichever framework table the append path touches first — record it in the test as the expected object name). The point is loudness: a missing grant must name the object, not manifest as a vague retry loop.

Acceptance: `cabal test keiro-test` passes both examples; deleting the `ON ALL TABLES` grant line from `keiro-runtime-grants.sql` makes the *positive* example fail with the same `permission denied` error the negative example expects — run that experiment once, then restore the file. `just verify` passes from the repo root.


## Concrete Steps

Working directory for everything: `/Users/shinzui/Keikaku/bokuno/keiro`.

```bash
cabal build all
cabal test keiro-test
just verify
```

A passing `keiro-test` ends with:

```text
N examples, 0 failures
Test suite keiro-test: PASS
```

To eyeball the ICU fixture manually (optional sanity check; this is what the fixture automates):

```bash
initdb --pgdata=/tmp/icu-probe --encoding=UTF8 --locale-provider=icu --icu-locale=en-US --auth=trust --no-sync
# expect: "Success. You can now start the database server using: …" — verified working on this
# environment's PostgreSQL 18.4. Clean up with: rm -rf /tmp/icu-probe
```

To verify the negative grant path bites (one-off experiment, then revert):

```bash
# comment out the "ON ALL TABLES" GRANT in keiro-migrations/sql/keiro-runtime-grants.sql
cabal test keiro-test
# expect: the positive service-role example FAILS with "permission denied for table …"
git checkout -- keiro-migrations/sql/keiro-runtime-grants.sql
```

Commits: Conventional Commits with the trailer `ExecPlan: docs/plans/133-test-under-production-locale-and-a-non-superuser-role.md`. Suggested slicing: M1 (fixture config + locale tests), M2 (script + docs), M3 (role helper + smoke tests).


## Validation and Acceptance

After implementation, all of the following hold, observable from `/Users/shinzui/Keikaku/bokuno/keiro`:

`cabal test keiro-test` output contains a passing `production locale (ICU en-US)` example asserting the order `apple, Banana, Éclair, zebra` and a passing companion on the default fixture asserting `Banana, apple, zebra, Éclair` — same rows, same query, two collations. It also contains passing `service role (non-superuser)` examples: the four-step cycle as `keiro_service`, and the negative example expecting `permission denied for table <name>`. `keiro-migrations/sql/keiro-runtime-grants.sql` exists and is the file the tests execute (verify by breaking it as shown above and watching the suite fail). `docs/user/migration-ownership.md` points to the script instead of embedding SQL. `just verify` passes. Suite-time impact: the ICU fixture adds one more cached server start (~1–2s after first cache warm; the first run pays one extra `initdb`) — record the measured before/after of `time cabal test keiro-test` in Outcomes & Retrospective.


## Idempotence and Recovery

All steps are re-runnable. The ICU cluster is cached under ephemeral-pg's content-keyed initdb cache (`initDbArgs` is in the key), so repeated runs reuse it; deleting `~/.cache/ephemeral-pg` merely re-pays one `initdb`. `CREATE ROLE` is guarded by an existence check and roles on the ephemeral server die with the server. Grants are applied per throwaway clone, so a failed example leaves nothing behind beyond the clone the fixture already drops. The docs edit and the SQL file are ordinary reviewed changes; if the smoke test reveals missing grants after M2 "completed", extend the script and re-run — the script is the single place to fix (that is its job), and note the addition in Surprises & Discoveries.


## Interfaces and Dependencies

keiro-test-support (module `Keiro.Test.Postgres`, all additive):

```haskell
productionLocaleConfig      :: Pg.Config
withMigratedSuiteWithConfig :: Pg.Config -> [MigrationComponent] -> (Fixture -> IO a) -> IO a  -- shared with ExecPlan 132
withServiceRoleStore                  :: Fixture -> ((Store.KirokuStore, Text) -> IO ()) -> IO ()
withServiceRoleStoreLackingTableGrants :: Fixture -> ((Store.KirokuStore, Text) -> IO ()) -> IO ()
```

New artifact: `keiro-migrations/sql/keiro-runtime-grants.sql` (canonical runtime GRANT set; role placeholder `:"app_role"`). Doc change: `docs/user/migration-ownership.md` "Operating" section references the script. Dependencies used, unchanged: ephemeral-pg (`Config.initDbArgs` record update; cache keyed on it — `EphemeralPg/Internal/Cache.hs` `getCacheKey`), kiroku (`ConnectionSettings.schemaInitialization = SkipSchemaInitialization`, `poolSize` untouched), PostgreSQL ≥ 15 built with ICU (this environment: 18.4, ICU verified). Production APIs exercised by the smoke cycle: the suite's existing minimal command path, `Keiro.Outbox.enqueueIntegrationEventTx` with `Keiro.Outbox.Schema.claimOutboxBatch`/`markOutboxSent`, and `Keiro.Timer.Schema.scheduleTimerTx` with `Keiro.Timer.claimDueTimer`/`markTimerFired`. No production interface changes.
