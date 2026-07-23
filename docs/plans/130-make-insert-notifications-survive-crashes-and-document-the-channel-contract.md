---
id: 130
slug: make-insert-notifications-survive-crashes-and-document-the-channel-contract
title: "Make insert notifications survive crashes and document the channel contract"
kind: exec-plan
created_at: 2026-07-23T04:18:42Z
master_plan: "docs/masterplans/21-harden-the-pgmq-hs-family-surfaced-by-the-2026-07-pgmq-hs-review.md"
---

# Make insert notifications survive crashes and document the channel contract

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

pgmq-hs (the Haskell client family for PGMQ, the PostgreSQL Message Queue, at
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`) can notify LISTENing
consumers when a message is inserted into a queue. Today that machinery has three defects.
First (PGH-6, demonstrated with a full live crash cycle on PostgreSQL 18.4): the
notification throttle state lives in an UNLOGGED table, which PostgreSQL truncates during
crash recovery; the insert trigger only notifies when it successfully updates a throttle
row, so after a crash (or an immediate-mode shutdown) the trigger fires, finds no row, and
**silently never notifies again** until an application re-enables notify — sends succeed,
messages accumulate, listeners starve. Second (PGH-9): the documented channel name is wrong
on every component — the haddock says `pgmq_<queue_name>` but the real channel is
`pgmq.q_<lowercased-queue-name>.INSERT`, so a consumer following the docs listens on a
channel that never receives anything. Third (PGH-8): enabling notify takes no lock and
`CREATE CONSTRAINT TRIGGER` has no IF-NOT-EXISTS, so two replicas reconciling the same
config concurrently can collide (duplicate-object 42710, failing one replica's whole
startup reconcile); partitioned queue creation has an analogous re-entry hazard in
pg_partman.

After this plan: a crash can no longer silence notifications (the trigger fails open —
loses throttling until the next reconcile, never delivery); the channel name is exported as
code (`Pgmq.Types.notifyChannelName`) and the haddock is corrected; concurrent reconciles
serialize on the existing per-queue advisory lock; and the whole story is pinned by tests,
including a real in-process crash-recovery cycle driven through ephemeral-pg's
immediate-shutdown restart.


## Progress

- [ ] M1 (repro): crash-cycle test written against a dedicated ephemeral-pg instance and
      confirmed red (send after immediate-shutdown recovery produces no notification);
      concurrent-enable race test written, repro attempt made and outcome recorded
      (42710 observed, or best-effort transcript recorded in Surprises & Discoveries);
      partitioned re-entry documented as code-verified (no pg_partman in the test
      environment — `pgmq-hasql/test/QueueSpec.hs` line 28).
- [ ] M2 (fix): new migration file (next free number after MasterPlan 17's claims —
      expected `0005-notify-crash-safety-and-locking.sql`) re-creating
      `pgmq.notify_queue_listeners` (fail-open fallback), `pgmq.enable_notify_insert`
      (advisory lock + COALESCE-250 guard, absorbing plan 129's server-side half), and
      `pgmq.create_partitioned` (pg_partman idempotence guard); manifest updated;
      migration + hasql + config suites green; M1 crash test green.
- [ ] M3 (channel contract): `notifyChannelName` exported from `Pgmq.Types`; the false
      haddock in `QueueManagement.hs` corrected; LISTEN round-trip test green
      (notification received on exactly the channel the helper computes); poll-fallback
      requirement documented on the enable API.
- [ ] CHANGELOG entry; living sections updated; ADR distillation pass (notify channel
      contract + crash semantics promoted to `docs/adr/` in the keiro repo).


## Surprises & Discoveries

Seeded from the 2026-07 pgmq-hs review verification (2026-07-23, PostgreSQL 18.4, repo's
own migration; full live crash cycle):

- `pg_ctl stop -m fast` (clean shutdown) preserves the UNLOGGED throttle row; `-m
  immediate` followed by recovery **truncates it** while the trigger and the queue's
  messages survive; a subsequent send succeeds with NO notification; re-running
  `enable_notify_insert` heals delivery. This is the precise stall: trigger installed +
  crash/immediate-recovery + no subsequent reconcile.
- The reconciler's self-heal only happens on application restart, and it reads the same
  truncated table (`Set.member` over `list_notify_insert_throttles` —
  `pgmq-config/src/Pgmq/Config.hs` lines 74 and 112;
  `pgmq-config/src/Pgmq/Config/Effectful.hs` lines 49 and 86), so it does correctly
  re-enable after a crash — but only if the application restarts too, and only with
  `throttleMs = Just`; with `Nothing` it hits plan 129's 23502 until that plan (or this
  plan's migration) lands.

(Add new discoveries below as work proceeds — in particular the M1 race-repro outcome and
the crash-test transcript.)


## Decision Log

- Decision: Fix PGH-6 in the trigger (fail-open NOTIFY when no throttle row exists), not
  by making `pgmq.notify_insert_throttle` a logged table.
  Rationale: The table is hot — the trigger UPDATEs `last_notified_at` on every
  successfully-throttled notification, and for `throttle_interval_ms = 0` queues that is
  every single insert; making it logged would WAL-log a row update per message, a
  permanent write-amplification cost to defend a rare crash path. The fallback costs one
  `NOT EXISTS` probe only on the already-failed branch, preserves delivery (the property
  that matters), and degrades only the throttle (bounded: until the next reconcile).
  Losing throttle state in a crash is acceptable; losing deliveries silently is not.
  Date: 2026-07-23

- Decision: This plan's migration re-creates `pgmq.enable_notify_insert` with BOTH the
  PGH-8 advisory lock and plan 129's server-side `COALESCE(throttle_interval_ms, 250)`
  guard, implementing the master plan's "combine the function's new definition in one
  migration" option. Plan 129's own fix for PGH-4 is client-side statement text and ships
  independently of this migration; there is no landing-order constraint between the two
  plans because this migration's definition is complete either way.
  Rationale: One function, one new definition, one migration file; avoids two migrations
  in one release train rewriting the same function.
  Date: 2026-07-23

- Decision: Fix the PGH-8 enable race with `PERFORM pgmq.acquire_queue_lock(queue_name)`
  as the first statement of `enable_notify_insert` (the function already exists at
  migration lines 110-116 and takes a transaction-scoped advisory lock,
  `pg_advisory_xact_lock`), rather than swallowing 42710 in the reconciler.
  Rationale: The function's internal sequence is disable-then-create; serializing the
  whole function call makes it convergent (the second caller drops and re-creates the
  first caller's identical trigger — an idempotent no-op in effect) with no error-code
  matching anywhere. `pgmq.create` and `pgmq.create_partitioned` already use the same
  lock for exactly this reason. Side effect accepted and documented: a concurrent second
  enable resets `last_notified_at` to the epoch, exactly as a sequential re-enable does.
  Date: 2026-07-23

- Decision: Fix the PGH-8 partitioned re-entry by making `pgmq.create_partitioned`
  skip `partman.create_parent` when the table is already registered in `part_config`
  (probe by `parent_table`), for both the queue table and the archive table.
  Rationale: The advisory lock already serializes concurrent creators, but the *second*
  replica still calls `create_parent` on a table the first replica just registered
  (its existence check ran before the first committed), and pg_partman rejects an
  already-managed parent (part_config uniqueness on parent_table). Idempotence, not
  locking, is the missing property. This is code-verified only: the test environment has
  no pg_partman (`pgmq-hasql/test/QueueSpec.hs` line 28 skips partitioned tests), so the
  guard ships with a partman-gated test that skips when the extension is unavailable.
  Note the divergence: `create_partitioned` is upstream-derived SQL and this guard is a
  deliberate, recorded divergence (the notify functions are pgmq-hs-local, so no parity
  concern there).
  Date: 2026-07-23

- Decision: `notifyChannelName` lives in `pgmq-core`'s `Pgmq.Types` (pure `Text`
  function, no new dependencies) rather than in pgmq-hasql.
  Rationale: The channel name is needed by LISTEN consumers that may not use pgmq-hasql
  at all; pgmq-core is the family's dependency floor and already owns `QueueName`.
  Date: 2026-07-23

- Decision: Migration numbering. MasterPlan 17's plan 116 claims
  `0003-order-read-grouped-returning.sql` and plan 118 claims
  `0004-fifo-group-btree-index.sql`. This plan claims the next number after all sibling
  claims present in `pgmq-migration/migrations/manifest` at implementation time —
  expected `0005-notify-crash-safety-and-locking.sql`. If 0003/0004 have not landed yet,
  do NOT take their numbers; leave gaps to the reserving plans only if the release is
  cut together (numbers must be sequential in the manifest at release time — coordinate
  and record the final name here). Plan 129 claims no migration; plan 131 claims none.
  Date: 2026-07-23

(Record further decisions as they are made, with dates.)


## Outcomes & Retrospective

(To be filled during and after implementation. Before completion, promote the channel
contract and the crash/fail-open semantics into `docs/adr/`.)


## Context and Orientation

Work happens in `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs` (a
cabal multi-package Haskell project; ignore `dist-newstyle/`). Run all commands from that
directory inside its nix dev shell (`nix develop`; it provides ghc 9.12.4, cabal, and
PostgreSQL binaries). The packages relevant here: `pgmq-core` (pure types, module
`Pgmq.Types`), `pgmq-hasql` (SQL statements/sessions), `pgmq-config` (the startup
reconciler `ensureQueues`), `pgmq-migration` (the SQL ledger:
`pgmq-migration/migrations/0001-install-v1.11.0.sql`, 2,075 lines, plus
`0002-schema-management-comment.sql`, listed in `pgmq-migration/migrations/manifest` and
embedded at compile time by `pgmq-migration/src/Pgmq/Migration/Internal/Definition.hs`
line 25). Changed SQL always ships as a NEW numbered migration file using
`CREATE OR REPLACE`, never as an edit to an applied file.

Relevant ADR: keiro's `docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` —
tangentially relevant; it pins the traced pgmq-effectful interpreter's span semantics.
This plan touches no interpreter code, so the constraint is simply: do not. No
pgmq-hs-repo ADR exists.

Terms. LISTEN/NOTIFY is PostgreSQL's built-in pub/sub: a session runs `LISTEN channel`
and later receives asynchronous notifications that other sessions raise with
`pg_notify(channel, payload)`. Notifications are fire-and-forget: they are not queued for
disconnected listeners, which is why every LISTEN consumer needs a poll fallback
regardless of this plan. An UNLOGGED table skips write-ahead logging; PostgreSQL
truncates unlogged tables during crash recovery (that is documented, intended behavior —
it is what makes them fast). A CONSTRAINT TRIGGER here is just a deferrable AFTER INSERT
row trigger. An advisory lock is an application-defined lock; `pg_advisory_xact_lock`
holds it until the surrounding transaction commits.

One PostgreSQL ground rule from the review to keep in mind: a plpgsql function call is
one statement, and an unhandled error rolls back ALL its effects atomically. (Two
others matter to sibling plan 129: parameter DEFAULTs apply only to omitted arguments,
never SQL NULL; and `LIMIT NULL` = `LIMIT ALL`.)

The machinery as it exists today, with exact locations in
`pgmq-migration/migrations/0001-install-v1.11.0.sql` (verify before editing; if a line
drifted, locate the construct by name and update this plan):

- The throttle table `pgmq.notify_insert_throttle` is created `CREATE UNLOGGED TABLE` at
  lines 25-32: `queue_name VARCHAR UNIQUE NOT NULL` (FK to `pgmq.meta` ON DELETE
  CASCADE), `throttle_interval_ms INTEGER NOT NULL DEFAULT 0` (line 30),
  `last_notified_at ... DEFAULT to_timestamp(0)`.
- The trigger function `pgmq.notify_queue_listeners()` at lines 1566-1592: extracts the
  queue name from the physical table name (`substring(TG_TABLE_NAME from 3)`, line 1572
  — physical names are `q_<lowercased-queue-name>`), then runs an UPDATE-only throttle
  check (lines 1574-1581: update `last_notified_at` where the interval elapsed or is 0)
  and raises `PG_NOTIFY('pgmq.' || TG_TABLE_NAME || '.' || TG_OP, NULL)` **only** when
  `updated_count > 0` (lines 1586-1588). There is no fallback when the row is absent —
  that is the PGH-6 stall. The real channel is therefore `pgmq.q_<name>.INSERT`.
- `pgmq.enable_notify_insert(queue_name TEXT, throttle_interval_ms INTEGER DEFAULT 250)`
  at lines 1594-1629: validates non-negative throttle (line 1602), validates the queue
  table exists, `PERFORM pgmq.disable_notify_insert` (line 1611), INSERT/upsert the
  throttle row (lines 1613-1617), then `CREATE CONSTRAINT TRIGGER
  trigger_notify_queue_insert_listeners` (lines 1619-1627). No advisory lock; CREATE
  TRIGGER has no IF-NOT-EXISTS — two concurrent callers can both pass the drop step and
  the loser of the create step gets SQLSTATE 42710 (duplicate_object). The whole notify
  family is pgmq-hs-local SQL (not upstream pgmq), so changing it has no upstream-parity
  cost.
- `pgmq.disable_notify_insert` at lines 1631-1646: `DROP TRIGGER IF EXISTS` + DELETE the
  throttle row; tolerant of absence.
- `pgmq.acquire_queue_lock(queue_name)` at lines 110-116:
  `pg_advisory_xact_lock(hashtext('pgmq.queue_' || queue_name))`.
- `pgmq.create_partitioned` at lines 1267-1419: takes the advisory lock (line 1283),
  creates the partitioned queue table, calls `partman.create_parent` for it (the EXECUTE
  around lines 1304-1320), later creates the archive table and calls `create_parent` for
  it too (second call around lines 1377-1395), then updates `part_config` retention. The
  second concurrent replica errors inside `create_parent` because the parent is already
  registered.
- The wrong haddock (PGH-9) is
  `pgmq-hasql/src/Pgmq/Hasql/Statements/QueueManagement.hs` lines 58-59: "Notifications
  are sent via PostgreSQL LISTEN/NOTIFY to channel pgmq_<queue_name>" — wrong separator,
  missing `q_` prefix, missing `.INSERT` suffix, and silent about lowercasing.

The reconciler self-heal path (why a crash stalls until an app restart): pgmq-config's
`ensureQueuesReport` reads `list_notify_insert_throttles` into a set
(`pgmq-config/src/Pgmq/Config.hs` line 74; effectful twin
`pgmq-config/src/Pgmq/Config/Effectful.hs` line 49) and only calls
`enableNotifyInsert` for queues missing from it (Config.hs lines 109-120; Effectful.hs
lines 83-94). After crash truncation the set is empty, so the next reconcile does heal —
but reconciles only run at application startup.

Test infrastructure. Each test suite self-provisions PostgreSQL through the
`ephemeral-pg` library (source:
`/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg`). The per-package
`test/EphemeralDb.hs` wraps `EphemeralPg.withCached` (cached initdb, temp data dir),
runs the full migration ledger via pg-migrate, and hands the suite a hasql-pool `Pool`.
Crucially for this plan, `EphemeralPg` also exports what a crash test needs
(`src/EphemeralPg.hs` export list): `start`, `stop`, `restart :: Database -> IO (Either
StartError Database)`, the `Database` record with public fields including
`shutdownMode :: ShutdownMode`, and `ShutdownMode (..)` where `ShutdownImmediate` sends
SIGQUIT — PostgreSQL's immediate shutdown, which forces crash recovery on the next
start. `restart` stops with the handle's `shutdownMode` and starts postgres again **on
the same data directory**, so `EphemeralPg.restart db { shutdownMode =
ShutdownImmediate }` is an in-process crash cycle. `connectionString ::
Database -> ...` provides a libpq conninfo string for raw connections. Do not crash the
suite-shared cached pool database; the crash test starts its own instance.

Receiving a NOTIFY in a test requires a libpq-level connection (hasql 1.10 exposes no
notification API). `postgresql-libpq` is already a transitive dependency (hasql depends
on it, bounds `>=0.10.1 && <0.12`); M3 adds it as a direct test dependency. The API
needed: `Database.PostgreSQL.LibPQ.connectdb`, `exec` (to run `LISTEN "channel"` — the
channel contains dots so the identifier MUST be double-quoted), `consumeInput`, and
`notifies` (returns `Maybe Notify`; `notifyRelname` is the channel).


## Plan of Work

### Milestone 1 — reproduce the stall and the race in tests (red)

Scope: prove PGH-6 end-to-end in this repo's test harness and make an honest attempt at
PGH-8's enable race, before changing any SQL. What exists at the end: two new test
modules that fail (or, for the race, either fail or carry a recorded repro attempt), plus
transcripts in Surprises & Discoveries.

Create `pgmq-config/test/NotifyCrashSpec.hs` (the crash + reconcile-heal story is a
pgmq-config behavior; that suite already depends on ephemeral-pg, pgmq-hasql,
pgmq-config, pg-migrate). The module manages its own database — do NOT use the shared
pool from `Main.hs`. Structure, in prose: start a dedicated instance with
`EphemeralPg.start EphemeralPg.defaultConfig` (or `startCached` with
`defaultCacheConfig` for speed — the data dir is a fresh cache copy either way, safe to
crash); run the migration exactly as `pgmq-config/test/EphemeralDb.hs` does (copy that
~10-line plan/run sequence); acquire a small `Pool` from
`EphemeralPg.connectionSettings`. Then:

1. Create a queue, `enableNotifyInsert` with `throttleIntervalMs = Just 0` (0 = no
   throttling, so every insert must notify; also avoids plan 129's 23502 which is fixed
   independently of this plan).
2. Open a raw libpq connection (`connectdb (connectionString db)` — M1 can defer the
   LISTEN half and assert on the throttle table instead if you want the smallest red
   test; the full LISTEN round-trip arrives in M3. Recommended M1 form asserts state,
   not delivery: it is deterministic and needs no new dependency).
3. Crash-cycle: `Right db' <- EphemeralPg.restart db { EphemeralPg.shutdownMode =
   EphemeralPg.ShutdownImmediate }`. Discard the old pool; acquire a fresh one against
   `db'` (the old pool's connections are dead).
4. Assert the post-crash facts that define the stall: `listNotifyInsertThrottles` is
   empty (row truncated); the trigger still exists (query
   `select count(*) from pg_trigger where tgname = 'trigger_notify_queue_insert_listeners'`
   via a raw `Hasql.Session.statement` or `sql`); a previously-sent message still exists
   (messages survive; the queue table is logged). These pass today — they are the
   preconditions.
5. The red assertion: send a message and assert a notification IS delivered to a
   listener on the correct channel. Today it is NOT (the trigger's UPDATE matches zero
   rows and the `updated_count > 0` gate suppresses the NOTIFY). If you deferred LISTEN
   to M3, the M1 red assertion is the M3 test marked as expected-fail; otherwise wire
   LISTEN now (add `postgresql-libpq` to `pgmq-config-test`'s build-depends) and let it
   fail red. Either way, capture the transcript.
6. Heal check (passes today, keep as regression guard): run
   `ensureQueues [withNotifyInsert (Just 0) (standardQueue qn)]` against the fresh pool
   and assert the throttle row is back.

Stop the instance with `EphemeralPg.stop` in a bracket.

Create `pgmq-hasql/test/NotifyRaceSpec.hs` for the enable race. Two concurrent
`Pool.use` calls (the shared suite pool has size 3, so two threads get distinct
connections) each running `Sessions.enableNotifyInsert` for the SAME queue with
`Just 0`, repeated over ~50 iterations with a fresh queue per iteration; collect the
`Left` results and count SQLSTATE 42710. The interleaving that fails is: both sessions
pass the internal DROP TRIGGER step before either CREATE commits; the second blocks on
the throttle-row upsert until the first commits, resumes, and its CREATE hits the
now-existing trigger — 42710. This window is timing-dependent: if 50 iterations show no
failure, raise to 500 and add a `threadDelay 0`/yield between the threads' starts; if it
still cannot be provoked, record the attempt (iterations, environment) in Surprises &
Discoveries and keep the test as the post-fix invariant (zero failures) — the fix is
correct regardless, and the master plan records PGH-8 as plausible-needs-verification.
Use `forkIO`+`MVar` from base (no new dependency). Register both modules in their
suites' `.cabal` `other-modules` and `Main.hs` trees.

Acceptance: `cabal test pgmq-config-test` shows the crash-cycle notification assertion
failing (or expected-fail marked) with the trigger-present/row-absent preconditions
passing; `cabal test pgmq-hasql-test` shows the race outcome, whichever it is, recorded.

### Milestone 2 — the migration: fail-open trigger, locked enable, idempotent partitioned create

Scope: one new migration file plus its manifest line; at the end the M1 crash test is
green and the race test shows zero failures.

Determine the filename: read `pgmq-migration/migrations/manifest`. Baseline content is
`0001-install-v1.11.0.sql` and `0002-schema-management-comment.sql`; MasterPlan 17's
plans reserve 0003 (`docs/plans/116-...md`) and 0004 (`docs/plans/118-...md`). Claim the
next free number — expected `0005-notify-crash-safety-and-locking.sql` — and record the
actual name in the Decision Log. Append the filename to
`pgmq-migration/migrations/manifest` (the TH embed in
`pgmq-migration/src/Pgmq/Migration/Internal/Definition.hs` picks it up at compile time).

The file contains three `CREATE OR REPLACE FUNCTION` statements.

First, the trigger function — the original body (install SQL lines 1566-1592) plus the
fail-open branch:

```sql
CREATE OR REPLACE FUNCTION pgmq.notify_queue_listeners()
RETURNS TRIGGER AS $$
DECLARE
  queue_name_extracted TEXT; -- Queue name extracted from trigger table name
  updated_count        INTEGER; -- Number of rows updated (0 or 1)
BEGIN
  queue_name_extracted := substring(TG_TABLE_NAME from 3);

  UPDATE pgmq.notify_insert_throttle
  SET last_notified_at = clock_timestamp()
  WHERE queue_name = queue_name_extracted
    AND (
      throttle_interval_ms = 0 -- No throttling configured
          OR clock_timestamp() - last_notified_at >=
             (throttle_interval_ms * INTERVAL '1 millisecond') -- Throttle interval has elapsed
    );

  GET DIAGNOSTICS updated_count = ROW_COUNT;

  IF updated_count > 0 THEN
    PERFORM PG_NOTIFY('pgmq.' || TG_TABLE_NAME || '.' || TG_OP, NULL);
  ELSIF NOT EXISTS (
    SELECT 1 FROM pgmq.notify_insert_throttle nit
    WHERE nit.queue_name = queue_name_extracted
  ) THEN
    -- Fail open: the trigger exists but its throttle row does not. The row lives
    -- in an UNLOGGED table, which crash recovery truncates; losing the throttle
    -- interval must not silently stop delivery. Notify unthrottled until a
    -- reconcile (pgmq.enable_notify_insert) restores the row.
    PERFORM PG_NOTIFY('pgmq.' || TG_TABLE_NAME || '.' || TG_OP, NULL);
  END IF;

RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

Note the disambiguation this branch depends on: "UPDATE matched zero rows" has two
causes — row present but throttled (suppress, correct) and row absent (crash-truncated:
notify). The `NOT EXISTS` probe distinguishes them and runs only on the zero-row branch,
so steady-state cost is unchanged. The trigger deliberately does NOT re-insert the row:
the configured interval is lost (that is the crash's data loss) and inventing one in the
hot path would silently change throttling; the reconciler restores the configured value.

Second, `enable_notify_insert` — the original body (lines 1594-1629) with two changes:
`PERFORM pgmq.acquire_queue_lock(queue_name);` as the first statement of the body, and
the DECLARE initializer becoming
`v_throttle_interval_ms INTEGER := COALESCE(throttle_interval_ms, 250);` (plan 129's
server-side guard — a bound SQL NULL never triggers the parameter DEFAULT, so the
function must coalesce internally to honor its documented 250). Copy the rest verbatim.

Third, `create_partitioned` — copy the whole original definition (lines 1267-1419) as
`CREATE OR REPLACE`, then guard BOTH `create_parent` EXECUTEs (queue table ~1304-1320,
archive table ~1377-1395) with an idempotence probe. Add `l_already_managed BOOLEAN;` to
the DECLARE block and, before each `create_parent` EXECUTE:

```sql
  EXECUTE FORMAT(
    'SELECT EXISTS (SELECT 1 FROM %I.part_config WHERE parent_table = %L)',
    pgmq._get_pg_partman_schema(),
    fq_qtable   -- fq_atable for the archive-table call
  ) INTO l_already_managed;

  IF NOT l_already_managed THEN
    -- original create_parent EXECUTE, verbatim
  END IF;
```

Validate the migration compiles and applies: `cabal test pgmq-migration-test` (the
migration suite applies the full ledger to an ephemeral database and verifies the plan),
then `cabal test pgmq-hasql-test pgmq-config-test` — the M1 crash test must now pass
(notification received post-crash) and the race loop must show zero 42710 across all
iterations. Add a partman-gated test for the partitioned guard: in
`pgmq-hasql/test/QueueSpec.hs`, a case that checks
`select count(*) from pg_available_extensions where name = 'pg_partman'` and calls
`Sessions.createPartitionedQueue` twice for the same name when available, asserting the
second call succeeds; when unavailable (the current environment), skip with the same
`pendingWith`-style note the suite already uses for partitioned coverage (line 28).

Acceptance: all named suites green; the M1 red transcript now has a green counterpart
pasted below it in Surprises & Discoveries.

### Milestone 3 — export the channel contract and prove it round-trip

Scope: make the channel name a single exported source of truth, fix the false docs, and
demonstrate a LISTEN round-trip through the helper.

In `pgmq-core/src/Pgmq/Types.hs`, add and export (the export list is at lines 3-25; add
under a "Notifications" heading near `NotifyInsertThrottle`):

```haskell
-- | The LISTEN/NOTIFY channel on which pgmq raises insert notifications for a
-- queue, once 'enable_notify_insert' has installed the trigger. The format is
-- @pgmq.q_<lowercased queue name>.INSERT@ — the physical table name
-- (@q_@ prefix, lowercased by pgmq's @format_table_name@) bracketed by the
-- @pgmq.@ schema tag and the trigger operation. Because the name contains
-- dots, LISTEN requires it double-quoted: @LISTEN \"pgmq.q_myqueue.INSERT\"@.
--
-- NOTIFY is fire-and-forget: notifications are not queued for disconnected
-- listeners, and (pre-crash-recovery reconcile) may be suppressed by
-- throttling. Consumers MUST keep a poll fallback regardless of LISTEN.
notifyChannelName :: QueueName -> Text
notifyChannelName q = "pgmq.q_" <> T.toLower (queueNameToText q) <> ".INSERT"
```

(`Data.Text` is already imported qualified as `T`. The `toLower` mirrors the SQL
`format_table_name` lowercasing at install SQL line 244; after sibling plan 131 rejects
uppercase names it is a no-op kept for defense.)

In `pgmq-hasql/src/Pgmq/Hasql/Statements/QueueManagement.hs` line 59, replace the false
channel claim with one that defers to the helper: notifications are sent on the channel
computed by `Pgmq.Types.notifyChannelName` (format `pgmq.q_<name>.INSERT`, quoted
LISTEN required), and consumers must keep a poll fallback. Make the same correction on
any other haddock repeating the old `pgmq_<queue_name>` claim (grep the repo for
`pgmq_<queue_name>`; the review found the wrong name "on every component" — fix each
occurrence, listing the files touched in Progress).

Add the round-trip test as `pgmq-hasql/test/NotifyChannelSpec.hs` (register in cabal +
`Main.hs`), with `postgresql-libpq >=0.10.1 && <0.12` added to `pgmq-hasql-test`'s
build-depends: create a queue on the shared suite pool, enable notify with `Just 0`,
open a raw libpq connection to the same database — the suite's `EphemeralDb.withPgmqDb`
does not expose the conninfo, so either extend `EphemeralDb` to also hand tests the
`EphemeralPg.Database` (preferred: change `withPgmqDb`'s callback to take both, adjust
`Main.hs`) or build the conninfo from the pool's settings — then `exec conn ("LISTEN " <>
quoted (notifyChannelName qn))` (double-quote the identifier), send a message through
`Sessions.sendMessage`, and poll `consumeInput`/`notifies` (a few 100 ms attempts)
asserting a `Notify` arrives whose `notifyRelname` equals the helper's output exactly.
Then LISTEN on the old, wrongly-documented channel name (`pgmq_<name>`) and assert
nothing arrives there for a second send — pinning that the helper, not the old doc, is
the contract. Finally, update `NotifyCrashSpec` (M1) to use `notifyChannelName` for its
post-crash delivery assertion if it hard-coded the format.

Acceptance: `cabal test pgmq-hasql-test` green including the round-trip; grep shows no
remaining `pgmq_<queue_name>` claim anywhere in the repo.


## Concrete Steps

All from `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`, inside
`nix develop`.

```bash
cd /Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs

# M1: add NotifyCrashSpec (pgmq-config) + NotifyRaceSpec (pgmq-hasql); register both
cabal test pgmq-config-test --test-show-details=direct   # crash-cycle red
cabal test pgmq-hasql-test  --test-show-details=direct   # race repro outcome

# M2: create the migration file (number per manifest; expected 0005-...), append to
#     pgmq-migration/migrations/manifest
cabal test pgmq-migration-test --test-show-details=direct
cabal test pgmq-hasql-test pgmq-config-test --test-show-details=direct

# M3: notifyChannelName in pgmq-core; haddock fixes; NotifyChannelSpec + libpq test dep
grep -rn "pgmq_<queue_name>" . --include="*.hs"          # must return nothing
cabal test all --test-show-details=direct
```

Expected transcript shapes:

```text
# M1, before the fix
NotifyCrashSpec
  post-crash: throttle row truncated, trigger intact:  OK
  post-crash: send delivers a notification:            FAIL
    expected a Notify on "pgmq.q_test_queue_NNNNN.INSERT" within 2s, got none

# M2, after the migration
  post-crash: send delivers a notification:            OK
NotifyRaceSpec
  concurrent enable_notify_insert never 42710 (n=50):  OK
```


## Validation and Acceptance

Behavioral acceptance, verifiable by a novice from the pgmq-hs root: (1) `cabal test
pgmq-config-test` runs a test that starts its own PostgreSQL, enables notify, kills the
server with an immediate shutdown, restarts it on the same data directory, proves the
throttle row was truncated while the trigger survived, sends a message, and receives a
notification — a sequence that demonstrably failed at the "receives" step before the
migration (M1 transcript). (2) `cabal test pgmq-hasql-test` includes a LISTEN round-trip
in which the channel a real notification arrives on is byte-equal to
`notifyChannelName qn`, and a listener on the old documented name `pgmq_<name>` receives
nothing. (3) The same suite runs N concurrent-enable iterations with zero
duplicate-object failures. (4) `cabal test pgmq-migration-test` applies the extended
ledger cleanly. (5) `grep -rn 'pgmq_<queue_name>' --include='*.hs' .` finds nothing.


## Idempotence and Recovery

The migration file is append-only and uses `CREATE OR REPLACE` throughout: re-applying
the ledger is a no-op, and the functions' new definitions are drop-in (no signature
changes, no data migration; the fail-open branch and the advisory lock change no
steady-state behavior). If the file needs correction BEFORE the family release is
consumed anywhere, edit it in place; after any consumer has applied it, correct via the
next numbered file instead. The crash test is self-contained: it creates and destroys
its own server; if it dies mid-run the leftover temp directory is inert. If
`EphemeralPg.restart` returns `Left` (rare start race), the test should retry once and
otherwise fail loudly — never fall back to skipping, since the crash cycle IS the test.
Re-running any suite is always safe; ephemeral databases are per-run.


## Interfaces and Dependencies

End-state interfaces (full module paths):

```haskell
-- pgmq-core, Pgmq.Types (new export)
notifyChannelName :: QueueName -> Text

-- ephemeral-pg (existing, consumed by the crash test)
EphemeralPg.restart :: Database -> IO (Either StartError Database)
-- Database.shutdownMode :: ShutdownMode   (record field, ShutdownImmediate = SIGQUIT)
```

SQL functions re-created by this plan's migration (same signatures as today):
`pgmq.notify_queue_listeners()`, `pgmq.enable_notify_insert(TEXT, INTEGER DEFAULT 250)`
(now advisory-locked and NULL-coalescing), `pgmq.create_partitioned(TEXT, TEXT, TEXT)`
(now create_parent-idempotent). New test dependency: `postgresql-libpq >=0.10.1 &&
<0.12` in `pgmq-hasql-test` (and `pgmq-config-test` if its crash test asserts delivery
directly) — already transitively present via hasql, so it costs nothing to the build
plan. Coordination: plan 129 owns all encoder/statement Haskell changes including the
client-side `coalesce($2, 250)` on enable (this plan's server-side COALESCE is
belt-and-braces for non-Haskell callers); plan 131 owns queue-name validation (after
which `notifyChannelName`'s `toLower` is defensive only) and carries the release-train
consumer bound bumps. The release carrying this plan is the shared family release —
expected 0.5.0.0 (plan 129's breaking change sets the version; this plan alone would
have been a minor bump).
