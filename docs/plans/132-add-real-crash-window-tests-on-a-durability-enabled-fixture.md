---
id: 132
slug: add-real-crash-window-tests-on-a-durability-enabled-fixture
title: "Add real crash-window tests on a durability-enabled fixture"
kind: exec-plan
created_at: 2026-07-23T04:18:42Z
master_plan: "docs/masterplans/22-make-the-test-infrastructure-exercise-real-crash-and-production-semantics.md"
---

# Add real crash-window tests on a durability-enabled fixture

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Every recovery guarantee keiro documents — "no message is lost when a worker crashes between claiming an outbox row and publishing it", "a timer stranded by a crashed worker re-fires", and so on — is today tested only by *simulations*: hand-built stranded state written with test-only raw `UPDATE`s, a thrown `SimulatedCrash` exception, or `killThread` (which delivers a polite asynchronous exception and runs the very cleanup code a real crash skips). No test in this repository kills a PostgreSQL backend, the postmaster, or a process. The simulations are valuable — they drive the production SQL API for the pre-crash step and they are fast and window-precise — but nothing pins them to reality, and the equivalence will silently drift as claim protocols evolve.

After this plan is implemented, each recovery-guarantee class (outbox publish, durable timer, workflow sleep journaling, transactional inbox, sharded-subscription lease) has at least one test that performs a *genuine* kill: `pg_terminate_backend` of the dedicated connection that executed the first half of the guarantee, issued from a second connection, on a PostgreSQL fixture with durability settings enabled. A further test kills the store's real `LISTEN` connection and proves push-wake recovery. The `pendingWith` placeholder that today keeps the "survives a transient database blip" guarantee green in CI becomes a real test, and pending examples fail the keiro, keiro-pgmq, and keiro-migrations suites from now on. You can see it working by running `cabal test keiro-test` and `cabal test keiro-pgmq-test` from the repository root and watching the new "real crash" examples pass — and by temporarily marking any example `pending` and watching the suite fail.

A prerequisite lives outside this repository: the ephemeral-pg library (the temporary-PostgreSQL fixture every suite uses) has a latent stale-process-handle trap in exactly the APIs a crash-test author would reach for (`createSnapshot`, `restoreSnapshot`, `restart`). This plan fixes that first, in the ephemeral-pg repo, and ships it as a release the keiro fixture then depends on.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: ephemeral-pg — thread the original `Config` through `Database`; `restart`, `createSnapshot`, `restoreSnapshot` return live handles; regression tests added; version 0.3.0.0 released.
- [ ] M2: keiro-test-support — `durableConfig` and `withMigratedSuiteWithConfig` exported; dedicated-connection and backend-kill helpers added; `configFailOnPending` wired into the keiro, keiro-pgmq, and keiro-migrations suite mains.
- [ ] M3: five real backend-kill tests (outbox, timer, workflow sleep, inbox, shard lease) pass on the durable fixture; LISTEN-death test passes; keiro-pgmq `pendingWith` example replaced with a real connection-death test.
- [ ] Suite-time impact measured and recorded; ADR distillation pass done (crash-window testing contract).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Authoring (2026-07-23): kiroku's `Notifier` (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Notification.hs`) already implements reconnect-with-backoff and re-`LISTEN` (capped 1s→30s schedule) and tags its connection `application_name = 'kiroku-listener'`. The TIN-5 risk statement "the push worker's LISTEN connection dying and never re-LISTENing" describes what *would* happen if that loop were broken — the gap is that no test anywhere exercises it against a real terminated backend. The M3 LISTEN-death test is therefore a fidelity pin on existing upstream code, not a fix.


## Decision Log

Record every decision made while working on the plan.

- Decision: `createSnapshot` and `restoreSnapshot` return the updated `Database` (new process handle) rather than mutating in place; `restart` and the snapshot-internal restart reuse the caller's original `Config` threaded through the `Database` record.
  Rationale: `Database` is an immutable record by design; returning the replacement handle is explicit and keeps `stop`/`cleanup` correct. Mutation via an `IORef` field was rejected because every existing call site pattern-matches the record and a hidden mutable cell would make `Show` and equality misleading. This is a breaking API change, hence ephemeral-pg 0.3.0.0.
  Date: 2026-07-23

- Decision: Kill tests run on a *durability-enabled* fixture (`durableConfig`: `fsync=on`, `synchronous_commit=on`, `full_page_writes=on`) even though `pg_terminate_backend` does not restart the server.
  Rationale: MasterPlan 22's Decision Log fixes backend-kill-on-durable-config as the standard mechanism for anything claiming "crash-window tested". With the defaults (`fsync=off`, `synchronous_commit=off` — `EphemeralPg/Config.hs` lines 172–188) a future postmaster-level test would pass *because committed transactions were lost*, inverting at-least-once assertions; standardizing on the durable fixture now means the helper and the contract never have to change when postmaster kills are added. Durable settings produce a distinct initdb-cache key automatically because `postgresSettings` feeds the cache hash (`EphemeralPg/Internal/Cache.hs` lines 143–158), so the durable and fast fixtures coexist in the cache.
  Date: 2026-07-23

- Decision: The existing simulations are kept, unmodified. One real kill test per guarantee class is the pin; simulations remain the fast, precise coverage.
  Rationale: Inherited from MasterPlan 22's Decision Log ("Keep the existing simulations alongside the new kill tests", 2026-07-23). Deleting them would trade speed and window precision for nothing.
  Date: 2026-07-23

- Decision: Pending-fails-CI is enforced in each suite's `main` via `hspecWith defaultConfig { configFailOnPending = True }`, not via Justfile `--test-options`.
  Rationale: The policy must hold however the suite is invoked (raw `cabal test`, CI, editor test runners), not only through `just verify`. hspec 2.11.17 (the resolved version per `dist-newstyle/cache/plan.json`) exports `Config(..)` including `configFailOnPending` from `Test.Hspec.Runner`, and the equivalent documented CLI flag `--fail-on=pending` remains available to override or reproduce behavior ad hoc. The Justfile targets need no change.
  Date: 2026-07-23

- Decision: The keiro-pgmq `pendingWith` example ("runJobWorkers survives a transient database error during polling") is replaced by a real connection-death test in the same suite, killing the worker's pooled backends mid-run. If the test exposes a genuine defect in the worker's transient-error survival, the defect blocks this milestone and is fixed (upstream in shibuya/shibuya-pgmq-adapter if that is where the loop lives) rather than re-pending the example.
  Rationale: The whole point of this initiative is that a green `pendingWith` is a false guarantee. Re-pending would recreate the finding.
  Date: 2026-07-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This plan touches two repositories. The keiro repository is at `/Users/shinzui/Keikaku/bokuno/keiro` (all repository-relative paths below without an absolute prefix mean this repo). The ephemeral-pg repository is at `/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg`; keiro consumes it as a normal Hackage dependency (currently `ephemeral-pg-0.2.2.0` per `dist-newstyle/cache/plan.json`; `keiro-test-support/keiro-test-support.cabal` declares `ephemeral-pg >= 0.2`), so changes there reach keiro only through a Hackage release plus a bound bump.

ADR context: keiro's `docs/adr/` contains only `docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` (pgmq telemetry), which is irrelevant to this work. No relevant ADR exists. MasterPlan 22 names a candidate ADR to write at completion: the crash-window testing contract — what "crash-window tested" must mean (real kill on a durable config) for any future guarantee claim.

Terms used throughout, in plain language. A PostgreSQL *backend* is the server-side process serving one client connection; `SELECT pg_terminate_backend(pid)` executed on any other connection kills that process immediately, severing the session mid-statement or mid-transaction — the closest server-visible equivalent of the client process dying. The *postmaster* is the parent server process; killing it is a full server crash (out of scope here per MasterPlan 22's Decision Log — backend kill is the standard mechanism). `LISTEN`/`NOTIFY` is PostgreSQL's built-in pub-sub: a connection issues `LISTEN channel` and receives asynchronous notifications; notifications are best-effort and are lost while no one is listening. *Durability settings*: `fsync` (flush WAL to disk at commit), `synchronous_commit` (wait for that flush before reporting commit), `full_page_writes` (write whole pages after checkpoints so torn writes are repairable). With all three off — the ephemeral-pg defaults — a server crash loses committed transactions.

### The current state of "crash" testing (all claims grep-verified 2026-07-23)

No keiro suite performs any real kill. `pg_terminate_backend`, `stopPostgres`, `ShutdownImmediate`, and `Pg.restart` appear nowhere in `keiro/test`, `keiro-pgmq/test`, `keiro-migrations/test`, or `keiro-test-support`. What exists instead:

- *Hand-built stranded state* via test-only raw SQL: `backdateOutboxUpdatedAt` (`keiro/test/Main.hs:8891`, a raw `UPDATE keiro.keiro_outbox SET updated_at = …`), used by the stranded-outbox tests at `keiro/test/Main.hs:4101` and `:4205`; the stranded-timer test at `:3725` claims a timer through the production API and then pretends time passed.
- A thrown `SimulatedCrash` exception (defined `keiro/test/Main.hs:8348`; 10 uses) for workflow mid-step crashes.
- `killThread` (17 uses, e.g. `:6458`, `:7117`, `:7146`). `killThread` delivers an asynchronous exception, which runs `bracket` cleanup — the graceful path a real `kill -9` or backend death skips. In particular the shard-failover tests at `:7092` and `:7124` therefore exercise graceful lease release, not lease *expiry* takeover.
- The "transient database blip" guarantee is backed by `keiro-pgmq/test/Main.hs:644–645` — a `pendingWith` example, green in CI — plus a statement-error simulation at `keiro/test/Main.hs:6801–6846` that renames a table (`ALTER TABLE keiro.keiro_workflow_steps RENAME …`) on a healthy connection and renames it back. Real connection death is never exercised.

MasterPlan 9 (`docs/masterplans/9-keiro-production-readiness-hardening.md`) overstates this at line 20 ("every documented recovery guarantee is backed by a crash-window test that kills the process between the two statements the guarantee spans"); its own crash-window pattern note (line 85) describes the simulation accurately. The simulations drive the production SQL API for the pre-crash step and are kept; what is missing is one genuine kill per guarantee class pinning simulation fidelity.

### Why durability config matters (TIN-2)

`EphemeralPg/Config.hs` (in the ephemeral-pg repo) `defaultPostgresSettings` at lines 172–188 sets `fsync='off'`, `synchronous_commit='off'`, `full_page_writes='off'`, `wal_level='minimal'`. This is harmless today — no test restarts the server, and `synchronous_commit=off` does not change live visibility or locking — but it is decisive for the testing contract: a naive future kill test on the default config would pass *because committed transactions were lost*. `Config`'s `Semigroup` appends `postgresSettings` lists and the settings are written to `postgresql.conf` in order (`EphemeralPg/Process/InitDb.hs`, `writePostgresConf`), where PostgreSQL applies last-wins — so appending `fsync='on'` etc. after the defaults cleanly overrides them. Because the settings list feeds the initdb cache key (`EphemeralPg/Internal/Cache.hs` lines 143–158), a durable config gets its own cached cluster and never collides with the fast one.

### The ephemeral-pg stale-handle trap (TIN-6, prerequisite)

`EphemeralPg/Snapshot.hs` lines 88–92: `createSnapshot` stops postgres, copies the data directory, restarts postgres — and its comment says "We don't update the Database record with the new process since Database is immutable. The caller should handle this", but the function returns only `Snapshot`, so the caller *cannot* handle it. `restartPostgres` (Snapshot.hs lines 138–149) and `EphemeralPg.hs` `restart` (lines 302–319) both substitute `defaultConfig` when restarting (line 313 in `EphemeralPg.hs`), silently dropping any custom `postgresArgs` and connection timeout the caller started with. `EphemeralPg/Process/Postgres.hs` lines 198–202 swallow the failure of signalling an already-dead PID. Chain these and you get: after a snapshot/restore/restart, the caller's `Database.process` is a dead handle; `stop` signals the dead PID (no-op, swallowed), then `cleanup` deletes the data directory under the *live* replacement postmaster. These are exactly the APIs a kill-test author will reach for. Verified: nothing in keiro references `createSnapshot`, `restoreSnapshot`, or `Pg.restart` today, so the fix is purely a breaking-release matter for ephemeral-pg, with no keiro call sites to migrate.

### The fixture and the suites

`keiro-test-support/src/Keiro/Test/Postgres.hs` is the suite fixture: `withMigratedSuiteWith` (line 94) calls `Pg.startCached Pg.defaultConfig Pg.defaultCacheConfig` (line 96) — one cached server per suite, one migrated template database, per-example clones via `CREATE DATABASE … TEMPLATE …` (`withFreshDatabase`), torn down with `DROP DATABASE … WITH (FORCE)`. This template-freshness/clone-isolation machinery is verified sound and must not be regressed — the new fixture entry points extend it additively. Suite mains: `keiro/test/Main.hs:353` (`main = withMigratedSuite $ \fixture -> hspec $ do …`), `keiro-pgmq/test/Main.hs:90` (`withMigratedSuiteWith [pgmq]` then `hspec`), `keiro-migrations/test/Main.hs:49` (`main = hspec $ do`). CI runs them through the repo-root `Justfile`: `just verify` → `haskell-verify` → `haskell-test` (`cabal test keiro-test`, `cabal test keiro-pgmq-test`, `cabal test jitsurei-test`) plus `cabal test keiro-migrations-test` directly in `verify`.

### The push-wake path (TIN-5)

`keiro/src/Keiro/Wake.hs` documents the push mechanism: keiro workers wait on a `WakeSignal` fed by kiroku's single dedicated `LISTEN` connection (`Kiroku.Store.Notification.Notifier`, one per store, channel `<schema>.events`, `application_name = 'kiroku-listener'`), with a bounded fallback timeout so a missed notification only delays the next pass to the poll interval. Kiroku's listener loop already reconnects with capped backoff (1s, 2s, 4s, 8s, 16s, then 30s) and re-`LISTEN`s — but no test kills the listener backend, so nothing pins that recovery or the wake-latency bound from keiro's side.

### The five guarantee windows (module-verified)

1. *Outbox claim→publish*: `keiro/src/Keiro/Outbox/Schema.hs` `claimOutboxBatch` (line 134, sets status `publishing`) … publish … `markOutboxSent` (line 169). Recovery: `keiro/src/Keiro/Outbox.hs` `outboxMaintenancePass` (line 457) requeues rows stuck in `publishing` longer than `OutboxMaintenanceOptions.publishingTimeout` (`keiro/src/Keiro/Outbox/Types.hs` line 204).
2. *Timer claim→fire*: `keiro/src/Keiro/Timer.hs` `claimDueTimer` (marks `Firing`) … fire … `markTimerFired`. Recovery: `runTimerWorkerWith` (line 124) takes an explicit `now` and requeues stale `Firing` rows per `requeueStuckAfter` (default `Just 300` seconds) before claiming — the simulation at `keiro/test/Main.hs:3725` already drives this with a future `now`.
3. *Workflow sleep journal append→markTimerFired*: `keiro/src/Keiro/Workflow/Sleep.hs` `workflowSleepFireAction` appends a `StepRecorded` via `appendJournalEntryReturningId` (deterministic event id, idempotent on re-fire) and returns the id so the timer worker calls `markTimerFired`. Crash between the two: the timer re-fires later and the journal append deduplicates — at-least-once firing, exactly-once journaling.
4. *Inbox intake*: `keiro/src/Keiro/Inbox/Schema.hs` `tryInsertCompletedTx` inserts the completed row *inside* the handler transaction (`Keiro.Inbox.runInboxTransaction`); a crash mid-transaction rolls everything back and a redelivery reruns the handler (at-least-once).
5. *Shard lease renewal*: `keiro/src/Keiro/Subscription/Shard/Schema.hs` exposes `claimShardsTx`, `renewLeaseTx`, `releaseShardsTx`; a dead worker's lease is *not* released — it expires (`lease_expires_at < now`) and another worker claims it. The `killThread` failover tests exercise the graceful `releaseShardsTx` path; the expiry path is the real-crash path.

Dedicated-connection mechanics: kiroku's `ConnectionSettings` (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Connection.hs`) has a `poolSize` field (default 10). A store opened with `poolSize = 1` runs every statement on a single backend, whose PID is `SELECT pg_backend_pid()` — this is how a test executes the pre-window statement on a *known, killable* backend through the production API.


## Plan of Work

The work is three milestones, strictly ordered: the ephemeral-pg handle fix must ship before keiro-test-support can bump to it, and the helpers must exist before the kill tests.

### Milestone 1 — ephemeral-pg: live handles, threaded config, release 0.3.0.0

Scope: the ephemeral-pg repository only (`/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg`). At the end, `restart`, `createSnapshot`, and `restoreSnapshot` can no longer strand a caller with a dead process handle or silently swap the server's configuration, regression tests prove it, and version 0.3.0.0 is on Hackage.

In `src/EphemeralPg/Database.hs`, add a `config :: Config` field to `Database` (the exact `Config` the instance was started with, after any cached-path resolution). Populate it at both construction sites in `src/EphemeralPg.hs` (`start`, line ~225 record build, and `continueStartup`, line ~456 record build). In `src/EphemeralPg.hs` `restart` (lines 302–319), replace the `defaultConfig` argument to `startPostgres` (line 313) with `db.config`, and return `db { process = newProcess }` as now (the signature `restart :: Database -> IO (Either StartError Database)` already returns the new handle — the bug was only the config substitution). In `src/EphemeralPg/Snapshot.hs`, change `createSnapshot :: Database -> IO (Either Text Snapshot)` to return `(Snapshot, Database)` and `restoreSnapshot :: Snapshot -> Database -> IO (Either Text ())` to return `Database`, where the returned `Database` carries the replacement `PostgresProcess` from the internal restart; change the internal `restartPostgres` (lines 138–149) to pass `db.config` instead of `defaultConfig`. Delete the now-false comment at lines 88–92. Leave `Process/Postgres.hs` lines 198–202 (signal-to-dead-PID swallowed) as is — with live handles threaded, "already exited" is a legitimate idempotent-stop case — but add a code comment stating that assumption.

Add regression tests to `test/Main.hs` (hspec; suite `ephemeral-pg-test`): (a) start with a custom `postgresArgs = ["-c", "max_connections=43"]`, `restart`, connect and `SHOW max_connections` — must still be 43 (fails before this change because `defaultConfig` dropped the args); (b) `createSnapshot` then use the *returned* `Database` to run a query and then `stop` it — assert the data directory is removed and no postgres process with the new PID survives (before the change, `stop` signalled the old dead PID and deleted the datadir under the live server); (c) `restoreSnapshot` returns a usable handle the same way. Keep the existing caching tests green — the cache-write atomicity from commit `215e4ae` (tmp-dir-then-rename publish, `Internal/Cache.hs` lines 181–206) must not be touched.

Release: bump `ephemeral-pg.cabal` version to 0.3.0.0, write the CHANGELOG entry (breaking: snapshot signatures; fixed: restart config substitution), and publish with the repo's `just release` (which runs `cabal check`, `cabal test`, `cabal upload --publish`, docs upload). Coordinate with ExecPlans 133 and 134 per MasterPlan 22's Integration Points: all three plans' ephemeral-pg changes ride one release train — if the others are ready, land them in the same 0.3.0.0; if not, 0.3.0.0 ships now and later plans ship 0.3.x. The last-landing plan bumps keiro-test-support's bound; this plan bumps it to `>= 0.3` in Milestone 2 regardless, since M2 depends on 0.3.0.0 semantics.

Acceptance: from the ephemeral-pg repo, `cabal test ephemeral-pg-test` passes including the three new regression examples; the new examples fail if you revert the `src` changes.

### Milestone 2 — keiro-test-support: durable config, kill helpers, pending-fails-CI

Scope: the keiro repo. At the end, `Keiro.Test.Postgres` exports a durability-enabled fixture configuration and the primitives every kill test needs, and a `pending`/`pendingWith` example fails all three DB suites.

First bump `keiro-test-support/keiro-test-support.cabal` to `ephemeral-pg >= 0.3` and run `cabal update` so the solver sees the release.

In `keiro-test-support/src/Keiro/Test/Postgres.hs`, add and export:

- `durableConfig :: Pg.Config` — `Pg.defaultConfig` with `postgresSettings` extended by `[("fsync","'on'"), ("synchronous_commit","'on'"), ("full_page_writes","'on'")]`. Because `Config`'s `Semigroup` appends settings and `postgresql.conf` is last-wins, appending after the defaults overrides them; because settings feed the initdb cache key, this config caches separately. Document exactly that in the haddock.
- `withMigratedSuiteWithConfig :: Pg.Config -> [MigrationComponent] -> (Fixture -> IO a) -> IO a` — identical to `withMigratedSuiteWith` (line 94) but passing the given config to `Pg.startCached`. Reimplement `withMigratedSuiteWith` as `withMigratedSuiteWithConfig Pg.defaultConfig` so there is one code path. This is the helper-naming convention ExecPlan 133 reuses (MasterPlan 22 Integration Points: EP-1 lands the convention first).
- Kill helpers (new module `keiro-test-support/src/Keiro/Test/Crash.hs`, exported from the cabal file):
  - `withDedicatedStore :: Fixture -> Text -> ((Store.KirokuStore, BackendPid) -> IO ()) -> IO ()` — clones a fresh database (reusing `withFreshDatabase`), opens a kiroku store with `poolSize = 1` on it, queries `pg_backend_pid()` through that store, and hands both to the action. `BackendPid` is a `newtype BackendPid = BackendPid Int32`. Because the pool has exactly one connection, every production-API call the test makes runs on that backend.
  - `terminateBackend :: Fixture -> BackendPid -> IO Bool` — from the fixture server's admin database (`Pg.connectionString fixture.server`, the same path `runSql` uses), executes `SELECT pg_terminate_backend($1)` and returns PostgreSQL's boolean. Requires `Fixture`'s fields; the module lives in keiro-test-support precisely so it can see them.
  - `runStatementOnDedicatedConnection :: Text -> Session.Session a -> IO (Either Text (a, BackendPid))` — a raw single-`Hasql.Connection` variant for tests that need SQL outside a store (acquire connection to the given connection string, run `pg_backend_pid()`, run the session, leave the connection open for the caller to kill; return the pid). Used by the inbox mid-transaction test.
  - `listenerBackendPid :: Store.KirokuStore -> IO (Maybe BackendPid)` — queries `pg_stat_activity` for `application_name = 'kiroku-listener' AND datname = current_database()` through the store; used by the LISTEN-death test.

Wire pending-fails-CI: in `keiro/test/Main.hs:353`, `keiro-pgmq/test/Main.hs:90`, and `keiro-migrations/test/Main.hs:49`, replace `hspec` with `hspecWith defaultConfig { configFailOnPending = True }`, importing `Test.Hspec.Runner (hspecWith, defaultConfig, Config (..))`. hspec 2.11.17 resolves today; `keiro-migrations`'s test stanza allows `hspec >= 2.10 && < 2.12` — raise that lower bound to `>= 2.11` since `configFailOnPending` arrived in 2.11. Note this makes the still-present `pendingWith` at `keiro-pgmq/test/Main.hs:644–645` fail the suite — that is intended; it stays red until Milestone 3 replaces it, so land M2 and M3 in one PR or mark the ordering explicitly in Progress when stopping between them.

Acceptance: `cabal build all` succeeds against ephemeral-pg 0.3.0.0. Add a scratch `it "x" $ pending` to any suite, run it, observe the suite *fail* with the pending item reported as a failure, then delete the scratch example. `cabal test keiro-test` and `cabal test keiro-migrations-test` pass; `cabal test keiro-pgmq-test` fails only on the line-644 pending example (expected until M3).

### Milestone 3 — the real kill tests

Scope: the keiro repo test suites. At the end, each guarantee class has one test whose crash is a genuine `pg_terminate_backend`, the LISTEN-death path is exercised, and the keiro-pgmq pending example is a real test. All new tests run on the durable fixture.

Fixture selection: change `keiro/test/Main.hs` `main` to start a second suite fixture — `withMigratedSuite $ \fixture -> withMigratedSuiteWithConfig durableConfig [] $ \durableFixture -> hspecWith … $ do …` — and pass `durableFixture` only to the new "real crash windows" `describe` block. Two cached servers per suite run; the durable one serves only these tests. For keiro-pgmq, thread `durableConfig` the same way (its fixture call already takes the pgmq migration component: `withMigratedSuiteWithConfig durableConfig [pgmq]`) or keep the single fixture durable-only if suite time allows — measure and record.

Each kill test follows one shape: open a dedicated store/connection on a fresh clone, execute the pre-window statement through the production API on that backend, `terminateBackend` it from the fixture's admin connection, run recovery through the production API on a *healthy* store, and assert the guarantee. Concretely:

1. *Outbox*: through the dedicated store, `Store.runTransaction (enqueueIntegrationEventTx …)` then `claimOutboxBatch PerKeyHeadOfLine 10 now` (commits status `publishing`). Kill the backend. On a fresh store, run `outboxMaintenancePass` with `publishingTimeout` set to a small value (e.g. `0.1`) and `defaultMaintenanceOptions`'s `maxAttempts`; then run the publisher pass with a counting publish action. Assert the row was requeued and published exactly once and ends `sent` — no loss, no duplicate side effect. (Mirror of the simulation at `keiro/test/Main.hs:4101`, minus `backdateOutboxUpdatedAt`.)
2. *Timer*: through the dedicated store, `scheduleTimerTx` then `claimDueTimer` (status `Firing`). Kill the backend. On a fresh store, run `runTimerWorkerWith` with `now = addUTCTime 400 realNow` (past the default `requeueStuckAfter = 300`) and a fire action returning a fixed `EventId`. Assert the timer re-fired exactly once and the target stream holds exactly that event. (Mirror of `:3725`.)
3. *Workflow sleep*: through the dedicated store, start a workflow that `sleep`s (journal holds the sleep step; a timer row exists), run `claimDueTimer`, then call `workflowSleepFireAction` so `appendJournalEntryReturningId` commits the `StepRecorded` — and kill the backend *before* `markTimerFired`. On a fresh store, run `runWorkflowTimerWorker` with a future `now`: the timer re-fires, the journal append deduplicates via its deterministic event id, `markTimerFired` lands. Assert the journal holds exactly one `StepRecorded` for that step and the timer ends `Fired` — at-least-once firing, exactly-once journaling.
4. *Inbox*: with `runStatementOnDedicatedConnection`, begin the intake transaction the way `runInboxTransaction` composes it (`tryInsertCompletedTx` for a new source/dedupe-key, then, still inside the transaction, `SELECT pg_sleep(30)` as the stand-in for a slow handler). While it sleeps, kill the backend from the admin connection. Assert via `lookupInbox` on a healthy store that *no* row exists (the transaction rolled back — nothing half-intaken), then redeliver through the real `runInboxTransaction` and assert the handler ran and the row is `completed`. At-least-once, atomic intake.
5. *Shard lease*: through the dedicated store, run `ensureShardRows` and `claimShardsTx` for worker A with a short `leaseTtl` (e.g. 2s). Kill the backend — the lease row remains, unexpired. On a fresh store as worker B, assert `claimShardsTx` with `now` *before* expiry claims nothing (the dead worker still owns the bucket — no premature steal), and with `now` past `lease_expires_at` claims the bucket. This is the expiry-takeover path the `killThread` tests at `:7092`/`:7124` cannot reach, because `killThread` runs the bracket that calls `releaseShardsTx`.

LISTEN-death test (in the same durable block, using a normal `withFreshStore` store): build a `WakeSignal` with `wakeSignalFromStore`, find the listener backend with `listenerBackendPid`, terminate it, then poll `pg_stat_activity` until a *new* `kiroku-listener` backend appears (allow ~15s: first reconnect backoff is 1s, but grant slack for CI). Append an event to any stream and assert `waitForWake` returns `WokenByNotify` well inside a fallback timeout of, say, 60s — proving the re-`LISTEN` really re-arms push rather than silently degrading every wake to the poll interval. Also assert an append made *while* the listener was dead does not stall the worker: a `waitForWake` with a 3s fallback still returns (as `WokenByTimeout`) — the documented poll-fallback bound.

keiro-pgmq conversion: delete the `pendingWith` at `keiro-pgmq/test/Main.hs:644–645` and write the real test in its place: start `runJobWorkers` against a fresh database, let it process one job (proving liveness), then from the admin connection terminate *all* backends on that database except the terminator's own (`SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()`), enqueue another job, and assert the worker processes it within the poll interval bound — the pool re-acquires connections and the worker classifies the failure as transient instead of dying. If it does not, that is a real defect: record it in Surprises & Discoveries and fix it where it lives (the polling loop is in shibuya/shibuya-pgmq-adapter per the old pending note) before closing this milestone.

Suite-time impact: expect roughly +5–20 seconds on `keiro-test` (one extra cached server start ~1–2s; six kill tests dominated by their recovery waits; durable clones commit slower because `fsync=on`) and a few seconds on `keiro-pgmq-test`. Measure with `time cabal test keiro-test` before and after and record the numbers in this plan's Outcomes section; if the durable fixture's clone cost is noticeable across unrelated tests, keep the durable fixture scoped to the kill block only (the default fixture stays fast — that is why there are two).

Acceptance: `just verify` from the keiro repo root passes; the new examples appear in the output under a "real crash windows (pg_terminate_backend, durable fixture)" describe; temporarily commenting out a recovery call (e.g. the `outboxMaintenancePass`) makes the corresponding test fail, proving the assertions bite.


## Concrete Steps

All commands are exact; the working directory is stated for each.

Milestone 1 (working directory `/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg`):

```bash
cabal build
cabal test ephemeral-pg-test
```

Expected tail of a passing test run (counts will be higher once the three regression examples exist):

```text
Finished in 20.41 seconds
34 examples, 0 failures
Test suite ephemeral-pg-test: PASS
```

Then bump the version, update `CHANGELOG.md`, commit, and release:

```bash
just release
```

Milestone 2 and 3 (working directory `/Users/shinzui/Keikaku/bokuno/keiro`):

```bash
cabal update
cabal build all
cabal test keiro-test
cabal test keiro-pgmq-test
cabal test keiro-migrations-test
just verify
```

Interpreting results: `cabal test <suite>` prints the hspec summary; success ends with `N examples, 0 failures` and `Test suite <suite>: PASS`. With `configFailOnPending` wired, a pending example prints as a failure with the pending reason and the suite exits non-zero — verify once deliberately:

```bash
# temporarily add:  it "pending guard works" pending  — then:
cabal test keiro-migrations-test
# expect: 1 failure, suite FAIL; then remove the scratch example
```

Commits: follow Conventional Commits and include the trailer `ExecPlan: docs/plans/132-add-real-crash-window-tests-on-a-durability-enabled-fixture.md` on every commit. Suggested slicing: one commit for M1 (ephemeral-pg repo, its own history), one for the keiro-test-support helpers + fail-on-pending, one per guarantee-class test or one for the whole M3 block.


## Validation and Acceptance

The plan is done when all of the following observable behaviors hold.

From `/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg`: `cabal test ephemeral-pg-test` passes, including an example proving `restart` preserves custom `postgresArgs` (asserts `SHOW max_connections` returns the custom value after restart) and examples proving the `Database` returned by `createSnapshot`/`restoreSnapshot` is live (a query succeeds on it) and stoppable (after `stop`, the data directory is gone and the server process has exited). Hackage lists ephemeral-pg 0.3.0.0.

From `/Users/shinzui/Keikaku/bokuno/keiro`: `just verify` passes. `cabal test keiro-test` output contains the durable-fixture describe with six passing examples — five backend-kill guarantee tests and the LISTEN-death test. `cabal test keiro-pgmq-test` contains a passing example replacing the former pending one (grep the suite output: the string `pendingWith` no longer appears; `grep -rn pendingWith keiro-pgmq/test` returns nothing). Adding `it "x" pending` to any of the three suites makes that suite fail.

Fidelity spot-check (manual, once): in the outbox kill test, log the claimed row's status immediately after `terminateBackend` (query from the admin connection). It must read `publishing` with the claim-time `updated_at` — i.e. the state the simulation at `keiro/test/Main.hs:4101` fabricates with `backdateOutboxUpdatedAt` is the state a real kill leaves, minus the backdating. Record the observation in Surprises & Discoveries; that comparison is the "pin" this plan exists to provide.


## Idempotence and Recovery

Every step is re-runnable. The ephemeral-pg initdb cache is content-keyed and atomically published, so repeated suite runs are safe; `clearAllCaches`/deleting `~/.cache/ephemeral-pg` is always a safe reset. The kill tests operate only on per-example clone databases that are dropped afterwards; a test aborted mid-run leaves at worst an orphaned clone that the next `DROP DATABASE IF EXISTS … WITH (FORCE)` or server teardown removes. `pg_terminate_backend` targets a single backend PID inside the ephemeral server — it cannot affect anything outside the fixture. If the Hackage release (M1) is published but keiro work stalls, nothing breaks: 0.3.0.0 is backward-compatible for every API keiro currently uses (keiro uses none of the changed snapshot/restart functions — verified). If M2's fail-on-pending lands before M3's conversion, `keiro-pgmq-test` fails on the known pending example; either land them together or accept the red window knowingly (state it in Progress).


## Interfaces and Dependencies

ephemeral-pg 0.3.0.0 (module `EphemeralPg`, `EphemeralPg.Snapshot`, `EphemeralPg.Database`):

```haskell
data Database = Database { {- existing fields -} , config :: Config }
restart         :: Database -> IO (Either StartError Database)          -- now honors db.config
createSnapshot  :: Database -> IO (Either Text (Snapshot, Database))    -- breaking change
restoreSnapshot :: Snapshot -> Database -> IO (Either Text Database)    -- breaking change
```

keiro-test-support (module `Keiro.Test.Postgres`, extended; new module `Keiro.Test.Crash`):

```haskell
durableConfig               :: Pg.Config
withMigratedSuiteWithConfig :: Pg.Config -> [MigrationComponent] -> (Fixture -> IO a) -> IO a

newtype BackendPid = BackendPid Int32
withDedicatedStore                 :: Fixture -> Text -> ((Store.KirokuStore, BackendPid) -> IO ()) -> IO ()
terminateBackend                   :: Fixture -> BackendPid -> IO Bool
runStatementOnDedicatedConnection  :: Text -> Session.Session a -> IO (Either Text (a, BackendPid))
listenerBackendPid                 :: Store.KirokuStore -> IO (Maybe BackendPid)
```

Suite mains use `Test.Hspec.Runner` (`hspecWith`, `defaultConfig`, `Config (..)` with `configFailOnPending :: Bool`) from hspec ≥ 2.11 (2.11.17 resolved). Production APIs exercised by the tests: `Keiro.Outbox.Schema` (`claimOutboxBatch`, `markOutboxSent`), `Keiro.Outbox` (`enqueueIntegrationEventTx`, `outboxMaintenancePass`, `OutboxMaintenanceOptions`), `Keiro.Timer` (`claimDueTimer`, `runTimerWorkerWith`, `TimerWorkerOptions`), `Keiro.Workflow.Sleep` (`workflowSleepFireAction`, `runWorkflowTimerWorker`), `Keiro.Inbox` (`runInboxTransaction`) with `Keiro.Inbox.Schema` (`tryInsertCompletedTx`, `lookupInbox`), `Keiro.Subscription.Shard.Schema` (`ensureShardRows`, `claimShardsTx`, `releaseShardsTx`), `Keiro.Wake` (`wakeSignalFromStore`, `WakeReason`), and kiroku's `Kiroku.Store.Connection.ConnectionSettings.poolSize`. None of these interfaces change; only tests and test-support code are added on the keiro side.
