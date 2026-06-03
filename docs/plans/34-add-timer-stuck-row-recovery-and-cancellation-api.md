---
id: 34
slug: add-timer-stuck-row-recovery-and-cancellation-api
title: "Add timer stuck-row recovery and cancellation API"
kind: exec-plan
created_at: 2026-06-03T04:20:10Z
intention: "intention_01kt5v38ztez0tt5b63nr7gbnx"
master_plan: "docs/masterplans/4-close-out-phase-2-worker-metrics-and-process-manager-hardening.md"
---

# Add timer stuck-row recovery and cancellation API

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Keiro is a Haskell event-sourcing framework backed by PostgreSQL. One of its
background workers is the *durable timer*: a process manager (a long-running
saga that reacts to events) schedules a timer to wake itself at a future time
(a timeout, a retry delay, a deadline). The timer rows live in a PostgreSQL
table named `keiro_timers`, and a worker loop claims due rows one at a time and
"fires" them by dispatching a command back into the saga.

Today this subsystem has a hole. When a worker claims a timer it moves the row
from the `scheduled` state to the `firing` state and runs the caller's fire
action. If the worker process crashes after the claim but before the timer is
marked `fired`, the row is left stranded in `firing` forever: the only function
that selects rows for work, `claimDueTimer`, looks **only** for rows in
`scheduled`, so a `firing` row is never picked up again. There is no supported
way to discover such stranded rows, to push them back to `scheduled` so a
worker retries them, to cancel a timer that should no longer fire, or to give
up on a timer that has failed too many times. Operators are told in
`docs/user/operations.md` only that the v1 API "does not expose automatic retry
or cancellation helpers for stuck rows" and that deciding a "timer stuck-row
repair procedure" is an open production-checklist item.

After this change, an operator (or an automated repair job) can do four new
things, all backed by tested library functions:

1. **List the stranded rows.** Call `findStuckTimers` to get every timer that
   has been sitting in `firing` longer than a chosen age, or that has been
   claimed more than a chosen number of times, so they can be inspected.
2. **Requeue them.** Call `requeueStuckTimer` to move a `firing` row back to
   `scheduled`, after which the ordinary `claimDueTimer` / `runTimerWorker` loop
   re-claims and re-fires it. This is the supported "kick a stuck timer" action.
3. **Cancel them.** Call `cancelTimer` to move a `scheduled` or `firing` row to
   the terminal `cancelled` state so it never fires again. A cancelled row is
   never selected by `claimDueTimer`.
4. **Auto-dead-letter on an attempt ceiling.** A timer that keeps failing
   (claimed, never marked `fired`, requeued, claimed again...) eventually
   exceeds a configurable attempt ceiling. Rather than ping-ponging forever, it
   is moved to a **new terminal `dead` state** so an operator can see it with a
   single query — `SELECT * FROM keiro_timers WHERE status = 'dead'` — exactly
   the way the outbox already surfaces permanently failed messages with its own
   `dead` status. A helper `deadLetterTimer` performs the transition, and the
   timer worker gains an opt-in policy that auto-dead-letters once
   `attempts` exceeds the ceiling.

You can see this working by running the test suite: new tests prove that a row
stuck in `firing` is found by `findStuckTimers`, requeued, then successfully
re-claimed and fired; that a cancelled row is never claimed; and that a timer
exceeding the attempt ceiling lands in `dead` and is never claimed again. A
second test suite (`keiro-migrations-test`) proves the new `last_error` column
exists on the migrated schema.

This is child plan **EP-34** of MasterPlan
`docs/masterplans/4-close-out-phase-2-worker-metrics-and-process-manager-hardening.md`.
It is pure library code with tests and one schema migration; it carries **no**
user-documentation obligation. The operator runbook that *uses* these functions
is written by **EP-37**, and the timer "stuck count" metric that reuses this
plan's definition of "stuck" and the new `dead` status is added by **EP-36**.
Both of those plans depend on the names and behavior fixed here, so this plan's
Interfaces and Dependencies section is the contract they consume.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Add `findStuckTimers` (query `firing` rows by age and/or attempt threshold) to `Keiro.Timer.Schema`, re-export from `Keiro.Timer`.
- [ ] M1: Add `requeueStuckTimer` (move `firing` -> `scheduled`, idempotent) to `Keiro.Timer.Schema`, re-export from `Keiro.Timer`.
- [ ] M1: Add `cancelTimer` (move `scheduled`/`firing` -> `cancelled`, idempotent) to `Keiro.Timer.Schema`, re-export from `Keiro.Timer`.
- [ ] M1: Add the `StuckTimerFilter` parameter type and document the formal definition of "stuck".
- [ ] M1: Write the M1 tests in `keiro/test/Main.hs` (find, requeue+re-fire, cancel-not-claimed).
- [ ] M1: `cabal test keiro:keiro-test` green; record transcript in Concrete Steps.
- [ ] M2: Add the `Dead` constructor to `TimerStatus`; extend `statusToText` / `statusFromText`.
- [ ] M2: Write the codd migration `keiro-migrations/sql-migrations/2026-05-17-03-00-00-keiro-timer-recovery.sql` adding `last_error TEXT` and the `dead`-aware index.
- [ ] M2: Add `deadLetterTimer` to `Keiro.Timer.Schema`, re-export from `Keiro.Timer`.
- [ ] M2: Add the attempt-ceiling worker policy to `runTimerWorker` (new `TimerWorkerOptions` / `runTimerWorkerWith`).
- [ ] M2: Update `keiro-migrations/test/Main.hs` to assert the `last_error` column exists on `keiro_timers`.
- [ ] M2: Write the M2 tests in `keiro/test/Main.hs` (attempt-ceiling -> `dead`, dead-not-claimed).
- [ ] M2: `cabal test keiro:keiro-test` and `cabal test keiro-migrations:keiro-migrations-test` green; record transcripts.
- [ ] Record the new `TimerStatus` value, the `last_error` column, and the migration filename in the MasterPlan Surprises & Discoveries (for EP-36 / EP-37 to pick up).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Define "stuck" formally as: a row whose `status = 'firing'` **and**
  that satisfies at least one caller-supplied threshold — its `updated_at` is
  older than a given age (it has been `firing` at least that long), and/or its
  `attempts` is at least a given count. The caller passes a `StuckTimerFilter`
  carrying an optional minimum age and an optional minimum attempts; both
  unset means "every `firing` row".
  Rationale: A crashed worker leaves a row `firing`; the only signals available
  on the row are how long it has been `firing` (captured by `updated_at`, which
  `claimDueTimer` bumps to `now()` on each claim) and how many times it has been
  claimed (`attempts`). Making both thresholds optional lets an operator say
  "anything firing more than 5 minutes" or "anything claimed at least 10 times"
  or both. Fixing this definition here lets EP-36's "stuck count" gauge and
  EP-37's runbook reuse exactly the same notion. Using `updated_at` (not
  `fire_at`) for the age is deliberate: `fire_at` is when the timer became due,
  which can be arbitrarily far in the past for a backlogged timer that is fine;
  `updated_at` reflects when it was last claimed, which is the right "how long
  stuck" clock.
  Date: 2026-06-03.

- Decision: `requeueStuckTimer` moves a `firing` row back to `scheduled` and
  **leaves `fire_at` unchanged** (it does not bump it to `now()`). It is
  idempotent: it only matches rows currently in `firing`, so re-running it on an
  already-requeued (now `scheduled`) row is a no-op affecting zero rows.
  Rationale: The timer was already due when it was first claimed, so it should
  become immediately re-claimable; leaving `fire_at` in the past means the next
  `claimDueTimer now` (with `fire_at <= now`) picks it up at once, which is the
  desired "retry it now" behavior. Restricting the `WHERE` to `status = 'firing'`
  makes the operation safe to run repeatedly and prevents resurrecting a
  `fired`, `cancelled`, or `dead` row.
  Date: 2026-06-03.

- Decision: `cancelTimer` moves a row to `cancelled` only from `scheduled` or
  `firing` (the two non-terminal states); it never touches `fired`, `cancelled`,
  or `dead` rows. It is idempotent and reports whether it changed a row.
  Rationale: Cancelling an already-fired timer would be misleading, and
  cancelling an already-cancelled/dead row is a no-op. The existing
  `claimDueTimer` only selects `scheduled`, so a cancelled row is automatically
  excluded from work — no change to the claim query is needed for cancellation.
  Date: 2026-06-03.

- Decision: Add an explicit terminal `Dead` `TimerStatus` constructor (stored as
  the text `'dead'`) plus a nullable `last_error TEXT` column, rather than
  reusing `Cancelled` with a reason payload.
  Rationale: The MasterPlan asks for this and gives the precedent: EP-20 gave the
  outbox a `dead` status precisely so operators can run
  `SELECT * FROM keiro_outbox WHERE status = 'dead'`. The outbox table already
  carries a `last_error TEXT` column (see
  `keiro-migrations/sql-migrations/2026-05-17-01-00-00-keiro-outbox.sql`), so a
  matching `keiro_timers.last_error` keeps the two failure surfaces consistent
  and gives operators the reason a timer was abandoned. Reusing `cancelled`
  would conflate operator-initiated withdrawal with automatic give-up and would
  be invisible to a status-only query. `status` is a free-text `TEXT` column, so
  introducing the `'dead'` value is purely additive; only the new `last_error`
  column requires a migration.
  Date: 2026-06-03.

- Decision: The attempt-ceiling auto-dead-letter is an **opt-in worker policy**,
  not automatic in `claimDueTimer`. Add a `TimerWorkerOptions` record with a
  `maxAttempts :: Maybe Int` field (default `Nothing` = never auto-dead-letter)
  and a new `runTimerWorkerWith :: TimerWorkerOptions -> ...` entry point; keep
  the existing `runTimerWorker` as `runTimerWorkerWith defaultTimerWorkerOptions`
  so no existing call site changes.
  Rationale: The MasterPlan says this initiative "does not distinguish transient
  from permanent timer errors automatically", so the ceiling must be opt-in. The
  worker is the place that already increments and observes `attempts`, so it is
  the natural place to enforce the ceiling. Keeping the old name unchanged keeps
  the existing test and the jitsurei demo working without edits; the new options
  record matches the established `RunCommandOptions` / `OutboxPublishOptions`
  pattern in the codebase.
  Date: 2026-06-03.

- Decision: Place the schema migration in the `keiro-migrations` package as a new
  timestamped file `2026-05-17-03-00-00-keiro-timer-recovery.sql`, and prove the
  new column with the existing `keiro-migrations-test`.
  Rationale: All Keiro framework SQL lives in
  `keiro-migrations/sql-migrations/*.sql` and is embedded via `file-embed`
  (`embedDir "sql-migrations"` in `keiro-migrations/src/Keiro/Migrations.hs`);
  files are ordered by their timestamp filename, so a `03-00-00` file runs after
  the bootstrap (`00-00-00`), outbox (`01-00-00`), and inbox (`02-00-00`)
  migrations. The migrations test already asserts table existence after applying
  all migrations twice (idempotence); extending it to assert a column is the
  smallest proof that the migration shipped.
  Date: 2026-06-03.

- Decision: Split into two milestones — M1 (find + requeue + cancel, no schema
  change) and M2 (attempt-ceiling terminal `dead` state + migration).
  Rationale: M1 needs no migration and is independently shippable and verifiable
  (it only adds query/mutation functions over existing columns and statuses).
  M2 is the only part that touches the schema and the migrations test, so
  isolating it keeps M1's blast radius small and lets the recovery query/requeue
  land even if the dead-letter design needs revision.
  Date: 2026-06-03.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you have never seen this repository. Read it fully before editing.

**Repository layout.** The repository root is
`/Users/shinzui/Keikaku/bokuno/keiro`. It is a Haskell project built with
`cabal`. The framework library `keiro` lives under `keiro/`, with source in
`keiro/src/Keiro/...`, its cabal file at `keiro/keiro.cabal`, and its single
test suite at `keiro/test/Main.hs` (the suite is named `keiro-test`; see the
`test-suite keiro-test` stanza in `keiro/keiro.cabal`). A second package,
`keiro-migrations` (at `keiro-migrations/`), owns the SQL schema migrations;
its test suite is named `keiro-migrations-test` and lives at
`keiro-migrations/test/Main.hs`. A third package, `keiro-test-support` (at
`keiro-test-support/`), provides the shared PostgreSQL test fixture used by
`keiro-test`. The shared prelude module re-exported by most library modules is
`Keiro.Prelude` at `keiro-core/src/Keiro/Prelude.hs`.

**The timer subsystem today.** Three source files matter:

- `keiro/src/Keiro/Timer/Types.hs` defines the identity and request value
  types: `newtype TimerId = TimerId UUID` and the record `TimerRequest`
  (`timerId`, `processManagerName`, `correlationId`, `fireAt`, `payload`).
  These have no SQL dependency.
- `keiro/src/Keiro/Timer/Schema.hs` is the persistence layer for the
  `keiro_timers` table. It defines `data TimerStatus = Scheduled | Firing |
  Fired | Cancelled`, the `TimerRow` record (the request fields plus `status ::
  TimerStatus`, `attempts :: Int`, `firedEventId :: Maybe EventId`), and three
  operations: `scheduleTimerTx`, `claimDueTimer`, and `markTimerFired`. It also
  contains private helpers `statusToText` / `statusFromText` (the text mapping:
  `scheduled`, `firing`, `fired`, `cancelled`, with any unknown text decoding to
  `Cancelled`), the row decoder `timerRowDecoder`, and `timerIdToUuid` /
  `eventIdToUuid`.
- `keiro/src/Keiro/Timer.hs` is the public umbrella module. It re-exports the
  types and storage from the two modules above and defines the worker loop
  `runTimerWorker`. Most callers `import Keiro.Timer` only.

**How a timer flows through states.** `scheduleTimerTx` inserts a row with
`status = 'scheduled'` (or re-arms a still-`scheduled` row of the same id).
`claimDueTimer now` runs one SQL statement: a CTE selects the single earliest
`scheduled` row with `fire_at <= now` using `FOR UPDATE SKIP LOCKED` (so
concurrent workers never grab the same row), then `UPDATE`s it to
`status = 'firing'`, increments `attempts` by one, sets `updated_at = now()`,
and `RETURNING`s the full row. `runTimerWorker now fire` calls `claimDueTimer`,
runs the caller's `fire :: TimerRow -> Eff es (Maybe EventId)` action on the
claimed row, and — if `fire` returns `Just eventId` — calls `markTimerFired`,
which sets `status = 'fired'` and records `fired_event_id`. If `fire` returns
`Nothing` (or the worker crashes), the row stays `firing`.

**The bug this plan fixes.** `claimDueTimer`'s `WHERE status = 'scheduled'`
means a `firing` row is **never** re-selected. The Timer module's Haddock
optimistically says "A timer left `Firing` by a crash becomes claimable again,
giving at-least-once firing" — but that is not true for the SQL as written,
because nothing transitions a `firing` row back to `scheduled`. This plan adds
the missing transition (`requeueStuckTimer`) and the tooling around it.

**The `keiro_timers` table.** Defined in
`keiro-migrations/sql-migrations/2026-05-17-00-00-00-keiro-bootstrap.sql`:

```sql
CREATE TABLE IF NOT EXISTS keiro_timers (
  timer_id UUID PRIMARY KEY,
  process_manager_name TEXT NOT NULL,
  correlation_id TEXT NOT NULL,
  fire_at TIMESTAMPTZ NOT NULL,
  payload JSONB NOT NULL,
  status TEXT NOT NULL DEFAULT 'scheduled',
  attempts BIGINT NOT NULL DEFAULT 0,
  fired_event_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS keiro_timers_due_idx
  ON keiro_timers (status, fire_at, process_manager_name);
```

Because `status` is a free-text `TEXT` column, adding the new value `'dead'`
requires **no** schema change. Only the new `last_error TEXT` column requires a
migration.

**How database tests are structured (important, do not improvise).** Per
project convention, the `keiro-test` suite uses a *suite-level template-database
fixture* from `keiro-test-support`, not a per-example migration. The fixture is
`Keiro.Test.Postgres` (`keiro-test-support/src/Keiro/Test/Postgres.hs`). Its
`withMigratedSuite` starts one cached PostgreSQL server, creates a template
database, applies the Kiroku and Keiro migrations to it **once**, and hands back
a `Fixture`. Each example then calls `withFreshStore fixture` (used via hspec's
`around`), which clones a fresh empty database from the template with
`CREATE DATABASE ... TEMPLATE ...`, opens a `Kiroku.Store.KirokuStore` against
it, runs the example, and drops the clone. `keiro/test/Main.hs` wires this up in
`main` as `main = withMigratedSuite $ \fixture -> hspec $ do ...`, and the timer
tests are grouped under
`describe "Keiro.Timer" $ around (withFreshStore fixture) $ do ...`. New timer
tests go inside that same `describe`. Because the migration is applied to the
template, **a new migration file you add under
`keiro-migrations/sql-migrations/` is automatically applied to the test
template** — no fixture change is needed; the migration runs for both
`keiro-test` and `keiro-migrations-test`.

**Running a test example.** Inside an example you have a `storeHandle ::
Store.KirokuStore`. You run effectful storage code with
`Store.runStoreIO storeHandle action`, where `action :: Eff es a` and the `Store`
effect is in `es`. To run raw SQL transactions you use
`Store.runTransaction (Tx.statement input stmt)` inside such an action — exactly
how `claimDueTimer` is written. The existing timer test (lines 845–870 of
`keiro/test/Main.hs`) is the template to copy; it schedules
`counterTimerRequest` (a `TimerRequest` with `timerId = TimerId sampleUuid`,
`fireAt = dueTimerTime`), claims and fires it, asserts the claimed status is
`Firing`, and asserts a second `runTimerWorker` returns `Right Nothing`.

**Test helpers already present in `keiro/test/Main.hs`.** `sampleUuid` and
`sampleUuid2` are fixed UUIDs (`...001` and `...002`); `dueTimerTime = UTCTime
(ModifiedJulianDay 1) (secondsToDiffTime 0)`; `counterTimerRequest` is the
sample request. The file already imports `Data.Time (UTCTime (..),
secondsToDiffTime)`, `Data.Time.Calendar (Day (ModifiedJulianDay))`,
`Data.UUID (UUID, fromString)`, `Data.Aeson (object, ...)`, `Keiro.Timer`,
`Kiroku.Store.Effect (Store)`, and `Kiroku.Store` qualified as `Store`. You
will add a couple more sample UUIDs and timer requests near the existing ones at
the bottom of the file.

**Effect vocabulary (define-the-terms).** The library uses the `effectful`
library. `Eff es a` is a computation in an effect set `es`. `(Store :> es)`
means the `Store` effect (the PostgreSQL event store / connection) is available
in `es`. `runTransaction :: (Store :> es) => Tx.Transaction a -> Eff es a` (from
`Kiroku.Store.Transaction`) runs a `hasql-transaction` `Transaction` against the
store's connection. `Tx.statement :: params -> Statement params result ->
Tx.Transaction result` runs one prepared statement. A `Statement params result`
is built with `Hasql.Statement.preparable sql encoder decoder`. These are
exactly the building blocks already used in `Keiro/Timer/Schema.hs`; you will
mirror them.


## Plan of Work

The work is two milestones. M1 adds the discovery, requeue, and cancel
functions — none of which needs a schema change, because they only read and
mutate columns and status values that already exist. M2 adds the terminal
`dead` state, the `last_error` column (a migration), the `deadLetterTimer`
helper, and the opt-in attempt-ceiling policy on the worker.

Throughout, follow the existing style in `keiro/src/Keiro/Timer/Schema.hs`:
each operation is a small wrapper that runs a `Statement` inside
`runTransaction`, with the SQL in a `preparable` multiline string and the
encoders/decoders built from `Hasql.Encoders` / `Hasql.Decoders`. Re-export
every new public function from `keiro/src/Keiro/Timer.hs` so callers keep
importing only `Keiro.Timer`.

### Milestone M1 — find, requeue, and cancel

**Scope.** Add three public functions and one parameter type to
`Keiro.Timer.Schema`, re-export them from `Keiro.Timer`, and add tests proving
each. No migration; no new `TimerStatus` value.

**What will exist at the end.** A novice can, from a `Store` action: call
`findStuckTimers` and receive the `firing` rows matching a threshold; call
`requeueStuckTimer` on a stuck row's id and watch the next `runTimerWorker`
re-claim and fire it; and call `cancelTimer` and observe that `claimDueTimer`
never returns the cancelled row.

**Edits.**

1. In `keiro/src/Keiro/Timer/Schema.hs`, add the filter type:

   ```haskell
   -- | Criteria selecting timers stranded in 'Firing'. A row is "stuck" when
   -- its 'status' is @firing@ and it matches every set bound: 'minAge' (it has
   -- been firing at least this long, measured from @updated_at@) and
   -- 'minAttempts' (it has been claimed at least this many times). Both unset
   -- selects every @firing@ row.
   data StuckTimerFilter = StuckTimerFilter
     { minAge :: !(Maybe NominalDiffTime)
     , minAttempts :: !(Maybe Int)
     }
     deriving stock (Generic, Eq, Show)

   -- | Select every @firing@ row regardless of age or attempts.
   anyStuckTimer :: StuckTimerFilter
   anyStuckTimer = StuckTimerFilter Nothing Nothing
   ```

   `NominalDiffTime` comes from `Data.Time`; add `import Data.Time
   (NominalDiffTime)` (the module already imports from `time` transitively via
   the prelude, but `NominalDiffTime` is not re-exported by `Keiro.Prelude`, so
   import it explicitly — `Keiro.Prelude` re-exports only `UTCTime` and
   `getCurrentTime` from `time`).

2. Add `findStuckTimers`:

   ```haskell
   findStuckTimers ::
     (Store :> es) => UTCTime -> StuckTimerFilter -> Eff es [TimerRow]
   ```

   It runs one statement that selects all rows with `status = 'firing'` and
   (when `minAge` is `Just d`) `updated_at <= $now - d`, and (when `minAttempts`
   is `Just n`) `attempts >= n`. Implement the optional bounds with SQL that is
   a no-op when the bound is absent, using two nullable parameters: pass the
   age as a cutoff timestamp (`now` minus `minAge`, computed in Haskell with
   `addUTCTime (negate d) now`, `Nothing` when `minAge` is unset) and pass
   `minAttempts` as a nullable `int8`. The `WHERE` becomes:

   ```sql
   WHERE status = 'firing'
     AND ($2::timestamptz IS NULL OR updated_at <= $2)
     AND ($3::bigint IS NULL OR attempts >= $3)
   ORDER BY updated_at, timer_id
   ```

   where `$1` is reserved for `now` if you prefer to compute the cutoff in SQL
   instead; computing the cutoff in Haskell keeps the statement to two
   parameters. Decode the rows with the existing `timerRowDecoder` via
   `D.rowList`.

3. Add `requeueStuckTimer`:

   ```haskell
   requeueStuckTimer :: (Store :> es) => TimerId -> Eff es Bool
   ```

   SQL: `UPDATE keiro_timers SET status = 'scheduled', updated_at = now()
   WHERE timer_id = $1 AND status = 'firing'`. Leave `fire_at` unchanged.
   Return whether a row changed by decoding the affected-row count
   (`D.rowsAffected` returns `Int64`; map `(> 0)` to `Bool`). This makes the
   call idempotent and observable.

4. Add `cancelTimer`:

   ```haskell
   cancelTimer :: (Store :> es) => TimerId -> Eff es Bool
   ```

   SQL: `UPDATE keiro_timers SET status = 'cancelled', updated_at = now()
   WHERE timer_id = $1 AND status IN ('scheduled', 'firing')`. Return whether a
   row changed, same as above.

5. Export `StuckTimerFilter (..)`, `anyStuckTimer`, `findStuckTimers`,
   `requeueStuckTimer`, and `cancelTimer` from `Keiro.Timer.Schema`'s export
   list, and re-export all five from `keiro/src/Keiro/Timer.hs` (add them to the
   `-- * Storage` group and add a new `-- * Recovery` group as you prefer; just
   ensure they are exported).

**Commands to run.** From the repository root:
`cabal build keiro` then `cabal test keiro:keiro-test`.

**Acceptance.** The three new M1 tests (described in Validation and Acceptance)
pass. Concretely: a row claimed into `firing` is returned by `findStuckTimers
now anyStuckTimer`; after `requeueStuckTimer` it is `scheduled` and a subsequent
`runTimerWorker now fire` claims and fires it; after `cancelTimer` the row is
`cancelled` and `claimDueTimer now` returns `Nothing`.

### Milestone M2 — attempt-ceiling terminal `dead` state

**Scope.** Add the terminal `Dead` status, the `last_error` column (a codd
migration), the `deadLetterTimer` helper, and the opt-in attempt-ceiling worker
policy. Update the migrations test to prove the column. Add tests proving the
ceiling path and that `dead` rows are never claimed.

**What will exist at the end.** A worker configured with
`maxAttempts = Just n` automatically moves a timer to `dead` (recording an
error string in `last_error`) once its `attempts` exceeds `n` instead of firing
it again, and the dead row is visible via `SELECT * FROM keiro_timers WHERE
status = 'dead'` and never re-claimed.

**Edits.**

1. In `keiro/src/Keiro/Timer/Schema.hs`, add the `Dead` constructor:

   ```haskell
   data TimerStatus
     = Scheduled
     | Firing
     | Fired
     | Cancelled
     | Dead
     deriving stock (Generic, Eq, Show)
   ```

   Extend `statusToText` with `Dead -> "dead"` and `statusFromText` with
   `"dead" -> Dead`. Update the Haddock on `TimerStatus` to document `Dead` as
   "abandoned after exceeding the attempt ceiling; terminal; carries an optional
   `last_error`." Keep `Cancelled` as the decode fallback for unknown text.

2. Add the migration file
   `keiro-migrations/sql-migrations/2026-05-17-03-00-00-keiro-timer-recovery.sql`
   with this exact content:

   ```sql
   ALTER TABLE keiro_timers
     ADD COLUMN IF NOT EXISTS last_error TEXT;

   DROP INDEX IF EXISTS keiro_timers_due_idx;

   CREATE INDEX IF NOT EXISTS keiro_timers_due_idx
     ON keiro_timers (status, fire_at, process_manager_name)
     WHERE status IN ('scheduled', 'firing');
   ```

   The `ADD COLUMN IF NOT EXISTS` is idempotent (safe to apply to a database
   that already has the column). The index rebuild is optional polish — it makes
   the due-timer / stuck-timer lookups skip terminal (`fired`, `cancelled`,
   `dead`) rows — and is also idempotent via `DROP INDEX IF EXISTS` +
   `CREATE INDEX IF NOT EXISTS`. The file is embedded automatically by
   `embedDir "sql-migrations"` in `keiro-migrations/src/Keiro/Migrations.hs`;
   its `03-00-00` timestamp orders it after the existing migrations. No code
   change to `Keiro/Migrations.hs` is needed.

3. Extend `TimerRow` decoding to read `last_error`. The simplest non-breaking
   approach: do **not** add `last_error` to the `TimerRow` record (EP-36/EP-37
   read it with a status query, not the row), and keep `timerRowDecoder`
   selecting the same eight columns it does now, so the existing
   `claimDueTimerStmt` / `findStuckTimers` `RETURNING`/`SELECT` lists are
   unchanged. If you decide to surface `last_error` on `TimerRow`, add a field
   `lastError :: !(Maybe Text)` and update `timerRowDecoder` and every
   `SELECT`/`RETURNING` column list together — record that choice in the
   Decision Log. The baseline plan keeps `TimerRow` unchanged to minimize churn.

4. Add `deadLetterTimer`:

   ```haskell
   deadLetterTimer :: (Store :> es) => TimerId -> Text -> Eff es Bool
   ```

   SQL: `UPDATE keiro_timers SET status = 'dead', last_error = $2,
   updated_at = now() WHERE timer_id = $1 AND status IN ('scheduled', 'firing')`.
   The second argument is the human-readable reason stored in `last_error`.
   Return whether a row changed.

5. In `keiro/src/Keiro/Timer.hs`, add the worker options record and the
   configurable entry point, keeping `runTimerWorker` as a thin alias:

   ```haskell
   -- | Options controlling 'runTimerWorkerWith'.
   newtype TimerWorkerOptions = TimerWorkerOptions
     { maxAttempts :: Maybe Int
     -- ^ When @Just n@, a claimed timer whose post-claim @attempts@ exceeds @n@
     -- is moved to 'Dead' instead of being fired. @Nothing@ never
     -- auto-dead-letters (the historical behavior).
     }
     deriving stock (Generic, Eq, Show)

   defaultTimerWorkerOptions :: TimerWorkerOptions
   defaultTimerWorkerOptions = TimerWorkerOptions { maxAttempts = Nothing }

   runTimerWorkerWith ::
     (Store :> es) =>
     TimerWorkerOptions ->
     UTCTime ->
     (TimerRow -> Eff es (Maybe EventId)) ->
     Eff es (Maybe TimerRow)
   runTimerWorkerWith options now fire = do
     due <- claimDueTimer now
     case due of
       Nothing -> pure Nothing
       Just timer ->
         case options ^. #maxAttempts of
           Just ceiling | (timer ^. #attempts) > ceiling -> do
             _ <- deadLetterTimer (timer ^. #timerId)
                    ("timer exceeded attempt ceiling of " <> tshow ceiling)
             pure (Just timer)
           _ -> do
             fired <- fire timer
             for_ fired (markTimerFired (timer ^. #timerId))
             pure (Just timer)

   runTimerWorker ::
     (Store :> es) =>
     UTCTime ->
     (TimerRow -> Eff es (Maybe EventId)) ->
     Eff es (Maybe TimerRow)
   runTimerWorker = runTimerWorkerWith defaultTimerWorkerOptions
   ```

   Note `claimDueTimer` increments `attempts` before this check, so the
   comparison sees the post-claim count. With `maxAttempts = Just 0`, the very
   first claim (which makes `attempts = 1 > 0`) dead-letters immediately; with
   `Just 2`, the third claim dead-letters. Use whatever small string builder the
   module already has for `tshow` (e.g. `Text.pack (show ceiling)` via
   `import Data.Text qualified as Text`); if no `tshow` exists, inline
   `Text.pack (show ceiling)`. Export `TimerWorkerOptions (..)`,
   `defaultTimerWorkerOptions`, `runTimerWorkerWith`, and `deadLetterTimer` from
   `Keiro.Timer`.

6. Update `keiro-migrations/test/Main.hs` to assert the `last_error` column
   exists. The existing test already verifies tables exist after applying all
   migrations twice. Add, inside the same example (after the second
   `runAllKeiroMigrations` call), a column-existence assertion. Add a helper
   mirroring `assertTablesExist`:

   ```haskell
   assertColumnExists :: Text -> Text -> Text -> Text -> IO ()
   assertColumnExists connStr schema table column = do
     pool <- Pool.acquire poolConfig
     result <- Pool.use pool (Session.statement (schema, table, column) columnExistsStmt)
     Pool.release pool
     case result of
       Left err -> expectationFailure ("column verification query failed: " <> show err)
       Right present -> present `shouldBe` True
    where
     poolConfig =
       Pool.Config.settings
         [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
         , Pool.Config.size 1
         ]

   columnExistsStmt :: Statement (Text, Text, Text) Bool
   columnExistsStmt =
     preparable
       """
       SELECT EXISTS (
         SELECT 1 FROM information_schema.columns
         WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
       )
       """
       ( contrazip3
           (E.param (E.nonNullable E.text))
           (E.param (E.nonNullable E.text))
           (E.param (E.nonNullable E.text))
       )
       (D.singleRow (D.column (D.nonNullable D.bool)))
   ```

   Call it with `assertColumnExists connStr "kiroku" "keiro_timers"
   "last_error"` after the second migration apply. Add the import
   `Contravariant.Extras (contrazip3)` to the migrations test (the cabal stanza
   already depends on `contravariant-extras` transitively through `hasql`; if
   the import is not resolvable, add `contravariant-extras` to the
   `keiro-migrations-test` `build-depends` in
   `keiro-migrations/keiro-migrations.cabal`). The migrations target the
   `kiroku` schema (matching `namespacesToCheck = IncludeSchemas [SqlSchema
   "kiroku"]` in the test), so the schema argument is `"kiroku"`.

**Commands to run.** From the repository root: `cabal build keiro
keiro-migrations` then `cabal test keiro:keiro-test` and `cabal test
keiro-migrations:keiro-migrations-test`.

**Acceptance.** The M2 tests pass: a worker with `maxAttempts = Just 0` moves a
claimed timer to `dead` and a subsequent `runTimerWorker now` returns `Right
Nothing` (proving the dead row is not re-claimed); and the migrations test's
new assertion confirms `keiro_timers.last_error` exists in the `kiroku` schema.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/keiro`. The toolchain is `cabal`. A PostgreSQL
binary is provided by the dev environment; the test fixture starts its own
ephemeral server, so you do not start a database yourself.

**Step 0 — establish the baseline.** Confirm the current suite builds and the
existing timer test passes before changing anything:

```bash
cabal build keiro
cabal test keiro:keiro-test
```

Expected (abbreviated) output includes the existing timer example:

```text
Keiro.Timer
  claims a due timer, fires a command, and marks it complete once [✔]
...
Finished in N.NNNN seconds
NN examples, 0 failures
```

**Step 1 — M1 code.** Edit `keiro/src/Keiro/Timer/Schema.hs` and
`keiro/src/Keiro/Timer.hs` per the M1 Plan of Work. Then:

```bash
cabal build keiro
```

Expect a clean compile (warnings about unused `now` parameter only if you
compute the cutoff in Haskell and do not pass `now` to SQL; silence by using
`_now` or by passing `now` as a third parameter).

**Step 2 — M1 tests.** Add the three M1 examples inside the existing
`describe "Keiro.Timer"` block in `keiro/test/Main.hs`, plus any new sample
UUIDs / `TimerRequest` values near `counterTimerRequest`. Then:

```bash
cabal test keiro:keiro-test
```

Expected new lines under `Keiro.Timer`:

```text
Keiro.Timer
  claims a due timer, fires a command, and marks it complete once [✔]
  finds a firing timer with findStuckTimers and requeues it for re-firing [✔]
  does not claim a cancelled timer [✔]
...
NN examples, 0 failures
```

**Step 3 — M2 code + migration.** Add the `Dead` constructor and the
`deadLetterTimer` helper to `Keiro.Timer.Schema`; add the migration file
`keiro-migrations/sql-migrations/2026-05-17-03-00-00-keiro-timer-recovery.sql`;
add `TimerWorkerOptions` / `runTimerWorkerWith` to `Keiro.Timer`. Then:

```bash
cabal build keiro keiro-migrations
```

**Step 4 — M2 tests.** Add the M2 example(s) to `keiro/test/Main.hs` and the
column assertion to `keiro-migrations/test/Main.hs`. Then:

```bash
cabal test keiro:keiro-test
cabal test keiro-migrations:keiro-migrations-test
```

Expected new line under `Keiro.Timer`:

```text
  dead-letters a timer that exceeds the attempt ceiling and never reclaims it [✔]
```

Expected migrations-test output:

```text
Keiro codd migrations
  applies Kiroku and Keiro migrations to a fresh database and is repeatable [✔]

Finished in N.NNNN seconds
1 example, 0 failures
```

(The single migrations example now additionally asserts the `last_error`
column; it stays one example.)

**Step 5 — record cross-plan facts.** Append to the MasterPlan
(`docs/masterplans/4-close-out-phase-2-worker-metrics-and-process-manager-hardening.md`)
Surprises & Discoveries: that EP-34 added `TimerStatus` constructor `Dead`
(stored `'dead'`), the `keiro_timers.last_error TEXT` column, and the migration
`2026-05-17-03-00-00-keiro-timer-recovery.sql`, and that "stuck" is defined by
`StuckTimerFilter` (status `firing` plus optional `minAge` on `updated_at` /
`minAttempts`). This is the note EP-36 and EP-37 consume.

**Commit.** Commit M1 and M2 separately (each leaving the tree green). Every
commit must carry these trailers:

```text
MasterPlan: docs/masterplans/4-close-out-phase-2-worker-metrics-and-process-manager-hardening.md
ExecPlan: docs/plans/34-add-timer-stuck-row-recovery-and-cancellation-api.md
Intention: intention_01kt5v38ztez0tt5b63nr7gbnx
```


## Validation and Acceptance

Acceptance is observable through the test suites. Below is what each new test
must establish; phrase them as hspec examples inside
`describe "Keiro.Timer" $ around (withFreshStore fixture)` (M1/M2 timer tests)
and inside the existing example in `keiro-migrations/test/Main.hs` (the column
check). Use the existing timer test (lines 845–870 of `keiro/test/Main.hs`) as
the structural template.

**M1 test A — `findStuckTimers` finds a firing row, requeue re-fires it.**

1. Schedule a timer (reuse `counterTimerRequest` or a fresh request) in a
   transaction: `Store.runStoreIO storeHandle $ Store.runTransaction $
   scheduleTimerTx req`.
2. Claim it without firing, to strand it in `firing`:
   `Store.runStoreIO storeHandle $ claimDueTimer dueTimerTime` — assert the
   returned row's `status` is `Firing`.
3. Find it: `stuck <- Store.runStoreIO storeHandle $ findStuckTimers
   dueTimerTime anyStuckTimer`. Assert `map (^. #timerId) stuck` contains the
   timer id (length 1). Also assert that a tighter filter excludes it when the
   bound is not met — e.g. `findStuckTimers dueTimerTime (StuckTimerFilter
   Nothing (Just 5))` returns `[]` because `attempts` is 1.
4. Requeue it: `changed <- Store.runStoreIO storeHandle $ requeueStuckTimer
   (req ^. #timerId)`; assert `changed == True`. Run it again; assert the second
   call returns `False` (idempotent — the row is now `scheduled`, not `firing`).
5. Re-fire it through the worker: `runTimerWorker dueTimerTime $ \_ -> ... pure
   (Just firedEventId)`, then a second `runTimerWorker dueTimerTime (\_ -> pure
   (Just firedEventId))` returns `Right Nothing`. Assert the target stream got
   exactly one event (same pattern as the existing test).

This proves the at-least-once recovery loop that was previously broken.

**M1 test B — a cancelled timer is never claimed.**

1. Schedule a timer.
2. `cancelled <- Store.runStoreIO storeHandle $ cancelTimer (req ^. #timerId)`;
   assert `cancelled == True`.
3. `claimed <- Store.runStoreIO storeHandle $ claimDueTimer dueTimerTime`;
   assert `claimed == Nothing`.
4. Cancel again; assert it returns `False` (idempotent — already `cancelled`).

**M2 test — attempt-ceiling dead-letters and never reclaims.**

1. Schedule a timer.
2. Run the worker with a zero ceiling so the first claim trips it:
   `result <- Store.runStoreIO storeHandle $ runTimerWorkerWith
   (defaultTimerWorkerOptions & #maxAttempts .~ Just 0) dueTimerTime
   (\_ -> pure (Just firedEventId))`. Because the claim sets `attempts = 1 > 0`,
   the worker dead-letters instead of firing. Assert `result` is `Right (Just
   timer)` with `timer ^. #status == Firing` (the row returned is the
   just-claimed row before the dead-letter UPDATE; the dead-letter changes the
   stored status afterward).
3. Confirm the firing function never ran: assert the target stream has zero
   events (the fire action above would have appended one had it run — to make
   the assertion sharp, use a fire action that appends to a stream and assert
   that stream is empty, or use an `IORef` flag the fire action would flip).
4. Confirm the row is `dead` and unclaimable: a follow-up
   `runTimerWorker dueTimerTime (\_ -> pure (Just firedEventId))` returns
   `Right Nothing`. To directly observe the `dead` status and `last_error`,
   run a small read statement (a `SELECT status, last_error FROM keiro_timers
   WHERE timer_id = $1`) inside `Store.runTransaction` and assert the status text
   is `"dead"` and `last_error` is the expected reason string. (You may inline a
   one-off `Statement` in the test, mirroring how other tests in the file build
   ad-hoc statements with `preparable`.)

**Migrations test — the `last_error` column exists.** After the second
`runAllKeiroMigrations` call in `keiro-migrations/test/Main.hs`, call
`assertColumnExists connStr "kiroku" "keiro_timers" "last_error"` (helper shown
in the Plan of Work). The example must remain green and still prove idempotence
(migrations applied twice without error).

A reader can tell success from failure by the hspec summary line: `0 failures`
for both `keiro-test` and `keiro-migrations-test`. Any failure prints the
expected-vs-actual `shouldBe` diff identifying which assertion broke.


## Idempotence and Recovery

Every step here is safe to repeat.

- **The SQL mutations are idempotent by construction.** `requeueStuckTimer`,
  `cancelTimer`, and `deadLetterTimer` each restrict their `WHERE` to the
  source state(s) they transition *from*, so re-running them on an
  already-transitioned row affects zero rows and returns `False`. This is why
  they return `Bool`.
- **The migration is idempotent.** `ADD COLUMN IF NOT EXISTS` and
  `DROP INDEX IF EXISTS` / `CREATE INDEX IF NOT EXISTS` can be applied to a
  database that already has the column/index without error. The
  `keiro-migrations-test` already applies all migrations twice to prove this,
  and codd's ledger prevents double-application in production anyway.
- **Tests are isolated.** Each example clones a fresh database from the migrated
  template (`withFreshStore`), so re-running `cabal test` from scratch is always
  safe and order-independent.
- **Retrying a half-done implementation.** If you stop after M1, the tree is
  green and shippable: `findStuckTimers` / `requeueStuckTimer` / `cancelTimer`
  exist and are tested, with no schema change. Resuming at M2 only adds
  additively. If the migration apply fails mid-way during local development, the
  `IF NOT EXISTS` clauses mean re-running it is safe; drop the ephemeral test
  databases by simply re-running `cabal test` (the fixture recreates them).
- **No destructive operations.** No data is deleted; the migration only adds a
  nullable column and rebuilds one index. There is no down-migration because
  codd is forward-only, matching the rest of the `keiro-migrations` package.


## Interfaces and Dependencies

This section is the contract that EP-36 (timer metrics) and EP-37 (operator
runbook) consume. Names and behavior here are authoritative; those plans must
use them verbatim.

**Libraries used (already dependencies of the affected packages):**
`effectful` (`Eff`, `(:>)`); `kiroku-store` (`Kiroku.Store.Effect.Store`,
`Kiroku.Store.Transaction.runTransaction`, `Kiroku.Store.Types.EventId`);
`hasql` (`Hasql.Statement.preparable`, `Hasql.Encoders`, `Hasql.Decoders`);
`hasql-transaction` (`Hasql.Transaction.statement`); `contravariant-extras`
(`contrazip*` for multi-parameter encoders); `time` (`NominalDiffTime`,
`addUTCTime`, `UTCTime`); `text` (`Text`). No new package dependency is required
for `keiro` (all already in `keiro/keiro.cabal`); the migrations test may need
`contravariant-extras` added to its `build-depends` for `contrazip3`.

**New / changed public surface after M1** (module `Keiro.Timer.Schema`,
re-exported from `Keiro.Timer`):

```haskell
-- "Stuck" = status 'firing' AND (minAge bound on updated_at, if set)
--           AND (minAttempts bound, if set). Both unset = every firing row.
data StuckTimerFilter = StuckTimerFilter
  { minAge :: !(Maybe NominalDiffTime)
  , minAttempts :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

anyStuckTimer :: StuckTimerFilter

findStuckTimers ::
  (Store :> es) => UTCTime -> StuckTimerFilter -> Eff es [TimerRow]

-- 'firing' -> 'scheduled'; fire_at unchanged; idempotent; True if a row changed.
requeueStuckTimer :: (Store :> es) => TimerId -> Eff es Bool

-- 'scheduled'|'firing' -> 'cancelled'; idempotent; True if a row changed.
cancelTimer :: (Store :> es) => TimerId -> Eff es Bool
```

**New / changed public surface after M2:**

```haskell
-- module Keiro.Timer.Schema (re-exported from Keiro.Timer)
data TimerStatus
  = Scheduled
  | Firing
  | Fired
  | Cancelled
  | Dead          -- NEW: stored as 'dead'; terminal; carries optional last_error
  deriving stock (Generic, Eq, Show)

-- 'scheduled'|'firing' -> 'dead'; sets last_error; idempotent; True if changed.
deadLetterTimer :: (Store :> es) => TimerId -> Text -> Eff es Bool

-- module Keiro.Timer
newtype TimerWorkerOptions = TimerWorkerOptions
  { maxAttempts :: Maybe Int }   -- Nothing = never auto-dead-letter
  deriving stock (Generic, Eq, Show)

defaultTimerWorkerOptions :: TimerWorkerOptions

runTimerWorkerWith ::
  (Store :> es) =>
  TimerWorkerOptions ->
  UTCTime ->
  (TimerRow -> Eff es (Maybe EventId)) ->
  Eff es (Maybe TimerRow)

-- unchanged signature; now = runTimerWorkerWith defaultTimerWorkerOptions
runTimerWorker ::
  (Store :> es) =>
  UTCTime ->
  (TimerRow -> Eff es (Maybe EventId)) ->
  Eff es (Maybe TimerRow)
```

**Schema change after M2:** column `keiro_timers.last_error TEXT` (nullable),
added by `keiro-migrations/sql-migrations/2026-05-17-03-00-00-keiro-timer-recovery.sql`,
which also narrows `keiro_timers_due_idx` to `WHERE status IN ('scheduled',
'firing')`.

**Definition of "stuck" for EP-36 / EP-37.** A timer is *stuck* when
`status = 'firing'` and it satisfies a `StuckTimerFilter`. EP-36's
`keiro.timer.stuck` gauge should count rows matching the application's chosen
filter (typically a `minAge` threshold), computed as
`SELECT count(*) FROM keiro_timers WHERE status = 'firing' AND updated_at <=
$cutoff`. EP-36 and EP-37 must treat `dead` as a distinct **terminal** state
(not counted as stuck, not counted as backlog) and may surface a separate
dead-letter count via `WHERE status = 'dead'`. EP-37's runbook documents the
operator flow: `findStuckTimers` to list, `requeueStuckTimer` to retry,
`cancelTimer` to withdraw, `deadLetterTimer` (or the `maxAttempts` worker
option) to abandon.

**Cross-plan flags (for MasterPlan Surprises & Discoveries):** new
`TimerStatus` constructor `Dead` (`'dead'`); new column
`keiro_timers.last_error TEXT`; new migration
`2026-05-17-03-00-00-keiro-timer-recovery.sql`; new worker entry point
`runTimerWorkerWith` with `TimerWorkerOptions { maxAttempts }`.
