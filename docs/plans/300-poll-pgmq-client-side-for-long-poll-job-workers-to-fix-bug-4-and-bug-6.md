---
id: 300
slug: poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6
title: "Poll PGMQ client-side for long-poll job workers to fix BUG-4 and BUG-6"
kind: exec-plan
created_at: 2026-09-30T20:33:36Z
intention: "intention_01m3t0bf63emytzb6ct908drwy"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T20:33:36Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-30T20:54:50Z
      mode: "update"
      note: "Cross-linked the finding shared into shibuya-pgmq-adapter (its BUG-1 root cause and new BUG-4)"
---

# Poll PGMQ client-side for long-poll job workers to fix BUG-4 and BUG-6

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`keiro-pgmq` runs typed background jobs on PGMQ, the PostgreSQL-native message queue. A
continuous worker built with `runJobWorkers` polls a queue for work, hands each message to a
handler, and then acknowledges it. The tuning value `LongPoll maxPollSeconds pollIntervalMs`
was meant to be a cheaper way to wait for work than sleeping between empty reads: the
worker asks PostgreSQL to wait for a message on its behalf.

Two bug reports filed from the external verification harness Kenshou show that this
"wait inside the database" implementation is unsound in exactly the situations a work queue
exists for. [BUG-4](../bug-reports/4-long-poll-job-worker-consumes-read-attempt-without-handler.md):
when a long-polling worker process is killed, the wait it started keeps running on the
PostgreSQL server, reads the next message that becomes visible, and charges the message one
retry attempt that no handler ever sees. With three kills and `maxRetries 3` the job can
skip a handler attempt or reach the dead-letter queue at `read_count 5` instead of 4.
[BUG-6](../bug-reports/6-long-poll-processors-starve-the-job-runtime-pool.md): every
long-polling processor holds one of the runtime's three pool connections for up to
`maxPollSeconds` at a time, so a worker with six processors leaves its handlers and
acknowledgements queueing behind the polls, and an enqueued job sits unprocessed for
longer than thirty seconds.

After this plan, `LongPoll` polls from the worker process: one short read statement,
release the connection, sleep `pollIntervalMs` when nothing was there, repeat. Nothing runs
on the server after a worker dies, and no processor holds a connection between reads. The
job runtime's pool size and acquisition timeout also become configurable and documented,
with today's defaults preserved. Concretely, after implementation, running

```bash
cabal test keiro-pgmq-test --test-show-details=direct --test-options='--match "long poll"'
```

from the repository root passes three examples: one that shows the PostgreSQL mechanism
behind BUG-4 (a killed `psql` client's `pgmq.read_with_poll` call still consumes a read
attempt), one that fails on today's tree because six `LongPoll` processors on the default
runtime pool keep three `pgmq.read_with_poll` backends active and do not deliver a job
within ten seconds, and one that proves a configured pool size is honoured. Both bug
reports move to `fixed` with `fixedVersion: unreleased` until the next lockstep release.


## Progress

- [ ] Milestone 0: add the `process` test dependency and the `activeServerPolls` helper to `keiro-pgmq/test/Main.hs`.
- [ ] Milestone 0: add the BUG-4 mechanism example (orphaned `read_with_poll` from a killed `psql` client) and confirm it passes.
- [ ] Milestone 0: add the BUG-6 red example (six `LongPoll` processors on the default pool) and record its failing output in Surprises & Discoveries.
- [ ] Milestone 0: link this plan from the BUG-4 and BUG-6 report bodies with the root cause, set both reports to `confirmed`, advance `generated`, log the bundle, and validate it.
- [ ] Milestone 0: commit the red example and the report updates.
- [ ] Milestone 1: change `toPollingConfig` in `keiro-pgmq/src/Keiro/PGMQ/Job.hs` so `LongPoll` maps to client-side polling; rewrite the `JobPolling` and module-header haddocks.
- [ ] Milestone 1: extend the tuning-validation example for `LongPoll 5 0`; `cabal test keiro-pgmq-test` passes, including the Milestone 0 red example.
- [ ] Milestone 1: update `docs/user/work-queues.md` (Tuning), log the bundle, validate; write the `keiro-pgmq` and root changelog entries; commit.
- [ ] Milestone 2: add `JobRuntimeConfig`, `JobRuntimeConfigError`, `defaultJobRuntimeConfig`, `mkJobRuntimeConfig`, and `withJobRuntimeWith` to `keiro-pgmq/src/Keiro/PGMQ/Runtime.hs`; re-express `withJobRuntime`.
- [ ] Milestone 2: add the validation and pool-bound examples; `cabal build all` and `cabal test keiro-pgmq-test` pass.
- [ ] Milestone 2: update `docs/user/work-queues.md` (The runtime) and `docs/user/api-reference.md`, log and validate; add the changelog entries; commit.
- [ ] Milestone 3: move BUG-4 and BUG-6 to `fixed` with `fixedVersion: unreleased` and resolutions; log and validate.
- [ ] Milestone 3: distill the polling decision into a new ADR, log it, validate; commit.
- [ ] Milestone 3: run `just verify` to completion, reading the exit code from inside the log, and record the result.
- [ ] Milestone 3: fill in Outcomes & Retrospective and record the Kenshou and adapter follow-ups.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Fix both bugs in `keiro-pgmq` by mapping `LongPoll` to the adapter's client-side
  polling mode (`StandardPolling` at `pollIntervalMs`) instead of the adapter's `LongPolling`
  mode, so that a keiro worker never issues `pgmq.read_with_poll`.
  Rationale: Both defects are consequences of one mechanism, a server-side loop that holds
  a connection and outlives its client. Client-side polling at the same interval performs
  the same one `UPDATE` per interval on the server (the server-side loop does nothing
  cheaper; see Context), adds only a network round trip per empty poll, and releases the
  pool connection between reads. The alternatives were examined and rejected: setting
  PostgreSQL's `client_connection_check_interval` on pool connections would make the server
  notice a dead client during the loop, but it exists only on PostgreSQL 14 or later, works
  only on some operating systems, and does nothing about connection pinning; sizing the
  pool to one connection per processor plus handler and acknowledgement work would need a
  budget keiro cannot know; bounding `maxPollSeconds` below the visibility timeout narrows
  only BUG-4's self-redelivery case and leaves fresh messages and BUG-6 unfixed.
  Date: 2026-09-30

- Decision: Keep the `LongPoll` constructor, its arity, and its validation (`mkJobTuning`
  still rejects non-positive `maxPollSeconds` and `pollIntervalMs`) so the change is
  source-compatible; document that `maxPollSeconds` is accepted for compatibility and
  bounds nothing; recommend `PollEvery` for new code; add no `DEPRECATED` pragma.
  Rationale: The DSL scaffold (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, `jobTuningFor`)
  leaves polling to deployment code, so consumers may spell `LongPoll` in their own
  configuration; breaking or warning on that spelling buys nothing, because the meaningful
  argument (`pollIntervalMs`) keeps its meaning. A deprecation can be revisited if the
  adapter later grows a sound long-poll primitive.
  Date: 2026-09-30

- Decision: Also expose the job runtime pool's size and acquisition timeout through a new
  `JobRuntimeConfig` and `withJobRuntimeWith`, with `withJobRuntime` keeping hasql-pool's
  defaults of three connections and ten seconds.
  Rationale: BUG-6's title names "the three-connection runtime pool", which today is an
  undocumented library default hidden inside `withJobRuntime`. After Milestone 1 a processor
  no longer pins a connection between reads, so the pool is shared only by short reads,
  finalizations, and whatever database work handlers do; operators still need to size it
  for their handler concurrency, and they cannot do that without a knob. The default stays
  unchanged so existing deployments behave identically.
  Date: 2026-09-30

- Decision: Acceptance is in-repository: a deterministic mechanism example for BUG-4 that
  kills a real `psql` client mid-`read_with_poll`, and a worker-path example for BUG-6 that
  observes `pg_stat_activity` while six `LongPoll` processors run on the default pool.
  Re-running Kenshou's `crash-redelivery-cadence` and `runtime-pool-isolation` scenarios is
  a post-release follow-up in that repository, not part of this plan's acceptance.
  Rationale: A worker process cannot kill itself inside `hspec`, and the orphaned-server-loop
  behaviour belongs to PostgreSQL and PGMQ, not to keiro, so the faithful in-process witness
  is a separate client process. Kenshou's cohorts pin released keiro versions from Hackage;
  running it against an unreleased keiro means authoring a new cohort there, which is its
  own work (the same reasoning as [plan 299](299-fence-outbox-finalization-by-claim-generation-to-fix-bug-5.md)).
  Date: 2026-09-30

- Decision: Do not wait for, and do not depend on, an upstream change to
  `shibuya-pgmq-adapter`'s `LongPolling` mode. Record the adapter's own open report
  (`mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-1`, "Long polls can
  starve acknowledgements on a shared pool", present in that repository's checkout and not
  yet pushed) as a related follow-up. On 2026-09-30 this analysis was shared back into that
  bundle: its BUG-1 now carries the root cause and the client-side remedy, and a new report,
  `mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-4`, records the orphaned
  server-side poll with the same Kenshou evidence; the adapter's own plan for the switch is
  being written in that repository.
  Rationale: keiro's mapping is correct regardless of what the adapter does with
  `LongPolling`, keiro pins `shibuya-pgmq-adapter ^>=0.16.1.0`, and this repository's
  practice is to block only on released upstream fixes. If the adapter later implements
  `LongPolling` client-side, keiro may pass it through again, but nothing forces that.
  Date: 2026-09-30

- Decision: Mark BUG-4 and BUG-6 `confirmed` in Milestone 0 once the in-repository examples
  reproduce the mechanism and the stall, and `fixed` with `fixedVersion: unreleased` at the
  end of Milestone 3; the release process replaces `unreleased` with the shipped version.
  Rationale: The bug-report profile reserves `confirmed` for the owning repository after
  reproduction and requires `fixedVersion` on `fixed`; `unreleased` is the bundle's
  convention for fixes on master.
  Date: 2026-09-30


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This is a multi-package Haskell repository built with `cabal`. The package that matters
here is `keiro-pgmq/` (cabal package `keiro-pgmq`, library modules under
`keiro-pgmq/src/Keiro/PGMQ/`, test suite `keiro-pgmq-test` in `keiro-pgmq/test/Main.hs`).
Its tests use `keiro-test-support/` (`Keiro.Test.Postgres`), which starts one throwaway
PostgreSQL server for the whole suite through the `ephemeral-pg` library, installs the
PGMQ schema into a template database, and gives every example a fresh cloned database
whose libpq connection string is the example's argument. Documentation lives under
`docs/`; several `docs/` directories are OKF bundles, directories of Markdown records with
YAML frontmatter that the `okf` command validates and whose `log.md` you append to with
`okf log add`. All commands in this plan run from the repository root unless stated
otherwise. Tests that touch the database need `initdb`, `postgres`, and (for one new
example) `psql` on the `PATH`; the repository's `nix develop` shell provides PostgreSQL 18.

### The pieces, in the words this plan uses

A *job* is a `Job p` value from `keiro-pgmq/src/Keiro/PGMQ/Job.hs`: a queue name, a
payload codec, an ordering contract, and a `RetryPolicy` whose `maxRetries` is the number
of deliveries PGMQ allows before the message is dead-lettered. PGMQ counts deliveries in
the message row's `read_ct` column; every read of a row increments `read_ct` and pushes the
row's visibility time `vt` into the future by the *visibility timeout*, so no other reader
sees it until then. A read that is never followed by a handler call still counts.

A *continuous worker* is what `runJobWorkers` (same module) starts: it hands one
*processor* per job to `Shibuya.App.runApp` from the `shibuya-core` package (a
Broadway-style worker framework). Each processor is built by `jobProcessorWithContext`,
which calls `adapterConfigFor tuning job` to derive a `PgmqAdapterConfig` and then
`pgmqAdapter` from the `shibuya-pgmq-adapter` package. The adapter owns the read loop; keiro
only chooses its mode. The relevant keiro code is small:

```haskell
-- keiro-pgmq/src/Keiro/PGMQ/Job.hs
data JobPolling
  = PollEvery !NominalDiffTime     -- sleep this long between empty polls
  | LongPoll !Int32 !Int32         -- max seconds to wait, check interval in milliseconds

toPollingConfig :: JobPolling -> PollingConfig
toPollingConfig (PollEvery interval) = StandardPolling interval
toPollingConfig (LongPoll maxPollSeconds pollIntervalMs) = LongPolling maxPollSeconds pollIntervalMs
```

`JobPolling` is defined near line 291, `validPolling` (used by `mkJobTuning`) near line 363,
`toPollingConfig` near line 399, and `adapterConfigFor` near line 797 of that file.
`defaultJobTuning` is `PollEvery 1`.

Inside the adapter (registry project `shinzui/shibuya-pgmq-adapter`, canonical URI
`mori://shinzui/shibuya-pgmq-adapter`, version 0.16.1.0, module
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`, function `pgmqChunks`), the two
modes differ in one place. `StandardPolling interval` issues one `pgmq.read` statement
through the `Pgmq` effect and, if the result is empty, sleeps `interval` in the worker
process with `threadDelay`. `LongPolling maxSec intervalMs` issues one
`pgmq.read_with_poll` statement instead. Every `Pgmq` effect operation is interpreted by
`runPgmq pool` from `pgmq-effectful` (registry project `shinzui/pgmq-hs`, canonical URI
`mori://shinzui/pgmq-hs`, module `pgmq-effectful/src/Pgmq/Effectful/Interpreter.hs`), which
runs each operation as its own `Hasql.Pool.use`, so a connection is held exactly for the
duration of one statement.

`pgmq.read_with_poll` is a PL/pgSQL function shipped by PGMQ (registry project `pgmq/pgmq`,
canonical URI `mori://pgmq/pgmq`, file `pgmq-extension/sql/pgmq.sql` near line 514; an
artifact-level URI is pending). It loops until `max_poll_seconds` have elapsed: each
iteration runs the same `UPDATE ... SET vt = now + vt, read_ct = read_ct + 1 ... FOR UPDATE
SKIP LOCKED ... RETURNING` that `pgmq.read` runs, returns immediately if it found rows, and
otherwise calls `pg_sleep(poll_interval_ms / 1000)`. The whole call is one statement on one
connection. Note what this means for cost: a server-side loop with a 100-millisecond
interval does one `UPDATE` per 100 milliseconds, exactly as a client that reads every 100
milliseconds does. The server-side loop saves network round trips and nothing else.

The *job runtime* is `JobRuntime` from `keiro-pgmq/src/Keiro/PGMQ/Runtime.hs`: a
`Hasql.Pool.Pool` plus an optional tracer. `withJobRuntime connStr tracer action` (near line
188) builds the pool with `Pool.Config.settings [staticConnectionSettings ...]` and nothing
else, so every other setting is hasql-pool's default. In hasql-pool 1.4.2 (registry project
`hasql/hasql`, canonical URI `mori://hasql/hasql`, file
`hasql-pool/src/library/exposed/Hasql/Pool/Config/Defaults.hs`) those defaults are a pool
`size` of 3 and an `acquisitionTimeout` of 10 seconds. `Hasql.Pool.use` (file
`hasql-pool/src/library/exposed/Hasql/Pool.hs`) waits for a connection in an STM
transaction over a `TQueue`; a caller that waits longer than the acquisition timeout gets
`AcquisitionTimeoutUsageError`, which `pgmq-effectful` maps to `PgmqAcquisitionTimeout` and
classifies as transient. The STM queue has no first-come-first-served guarantee: when a
connection is returned, every blocked waiter is woken and races, and the thread that just
returned the connection can take it again before any waiter runs. The same pool also
serves the adapter's acknowledgement path (`mkAckHandle` and `deadLetterTransactionally` in
the adapter's `Internal.hs`, through `PgmqAdapterEnv.pool` and the `Pgmq` effect) and any
database work a handler does through the `Pgmq` effect or `JobRuntime.runtimePool`.

Inside shibuya-core 0.10.0.0 (registry project `shinzui/shibuya`, canonical URI
`mori://shinzui/shibuya`, module `shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`,
function `runIngesterAndProcessor`), every processor runs two threads: an *ingester* that
pulls from the adapter's source stream into a bounded inbox, and the processor loop that
takes messages from the inbox and runs the handler. The ingester does not wait for the
handler: as soon as it has handed a message to the inbox it issues the next read. With
`LongPolling` that next read is another `read_with_poll`, so a processor whose handler is
running still holds a connection in a server-side loop. The same module's `processOne`
turns a handler exception into an `AckRetry (RetryDelay 0)` finalization (a visibility
reset to zero, so the message is immediately visible again), and
`shibuya-core/src/Shibuya/Internal/Runner/Finalize.hs` retries a failing finalizer three
times with delays of 10, 50, and 250 milliseconds.

### The defect behind BUG-4, exactly

A worker process reads message M (attempt 0, `read_ct 1`, `vt` three seconds out with
Kenshou's tuning of a 3-second visibility timeout and `LongPoll 5 100`), the handler starts,
and the ingester immediately begins a five-second `read_with_poll` on a second pool
connection. Kenshou then kills the process with SIGKILL. The handler's connection and the
ingester's connection are both closed by the operating system, but PostgreSQL only notices a
closed client socket when it tries to read from or write to it, and a backend executing
`read_with_poll` does neither until the function returns. The orphaned backend keeps
looping. Three seconds after the original read, M's visibility timeout expires; the
orphaned loop's next iteration reads M (`read_ct 2`, `vt` pushed out another three seconds),
returns, and the backend commits the implicit transaction before it tries to flush the
result to the dead client. The flush fails, the backend logs `could not send data to client:
Broken pipe` and `FATAL: connection to client lost`, and M has consumed attempt 1 with no
handler call. The next live worker reads M at `read_ct 3` and reports attempt 2. If two
orphans race with a live worker the counts shift, which is why the two failing runs differ.

The PostgreSQL log in Kenshou's run artifacts makes the timing unambiguous. Kenshou is
registry project `shinzui/keiro-runtime-kenshou`, canonical URI
`mori://shinzui/keiro-runtime-kenshou`; run directories are project-relative
`runs/<run-id>/` and artifact-level URIs are pending. In run
`01a0d1b4-5232-707b-abed-404ce0d0db3e`, worker 0 reported attempt 0 at
`04:37:31.823 UTC`; its backend (pid 77243) logged the broken pipe at `21:37:34.889 PDT`
(the same instant as `04:37:34.889 UTC`), 3.07 seconds later, which is the visibility
timeout plus one poll interval and well short of the five-second poll budget, so the loop
ended because it found a row. Worker 1 then reported attempt 2 (not 1) at `04:37:37.986
UTC`, 6.16 seconds after attempt 0. In run `01a0d1b3-8a6c-7624-aa6f-7fff066f8787` the first
two orphans lost the race to live workers and died at the full 5.02-second budget, but the
third (pid 76149) died 3.07 seconds after attempt 2 was reported; the DLQ wrapper then
recorded `read_count 5` after three handler calls. With `PollEvery`, the only statement a
killed process can leave behind is a millisecond-long `pgmq.read`, which is why the
poll-every control passes.

### The defect behind BUG-6, exactly

Kenshou's `runtime-pool-isolation` scenario (project-relative path
`kenshou-keiro/src/Kenshou/Suite/Keiro/Queue/Concurrency.hs`, function
`runRuntimePoolIsolation`; worker role in `kenshou-keiro/src/Kenshou/Suite/Keiro/Queue/Roles.hs`)
starts one worker process built with `withJobRuntime` (pool size 3) and `runJobWorkers
StopAllOnFailure 16` over N processors that all read the same queue with `defaultJobTuning
{polling = LongPoll 5 100}`. Its handler records a "delivery" mark and then inserts a row
through `runtime.runtimePool`. With N = 6, six ingesters each want a connection for a
five-second loop; three get one and three wait, timing out after ten seconds and retrying
under the adapter's transient-retry policy. When a loop returns (with the message or empty)
the connection is contended by the three blocked ingesters, the returning ingester's own
immediate next poll, and, once the handler is running, the handler's insert and later the
acknowledgement. The worker control log for run `01a0d52d-8a1e-7070-be94-b20e771f6650`
shows the six-processor arm delivering attempt 0 at `20:49:38.028 UTC` and never producing
an effect within the thirty-second window: the handler's insert waited past the
acquisition timeout, failed, and the message was never acknowledged. The three-processor
arm in the same run needed three attempts (`20:49:07.486`, `20:49:22.694`, `20:49:32.895`
UTC, gaps of 15.2 and 10.2 seconds that are one acquisition timeout plus retry delays)
before its insert won a connection. The one-processor arm, with two connections to spare,
completed at once. This is the same pathology the adapter's own report BUG-1 describes for
two processors on a two-connection pool.

### What must not change

The `JobPolling` type, `mkJobTuning`'s validation, `defaultJobTuning` (`PollEvery 1`), the
adapter's retry policies, the drain path (`runJobOnceWithContext`, which never used polling),
FIFO ordering behaviour, at-least-once delivery, and `withJobRuntime`'s observable defaults
(three connections, ten-second acquisition timeout) all stay as they are. The fix changes
only which adapter polling mode `LongPoll` selects, and adds a configuration surface with
the old defaults.

### Relevant ADRs

[ADR-1](../adr/0001-keiro-pgmq-job-processing-telemetry-contract.md) fixes the telemetry
contract for both job execution paths, including that lower-level PGMQ operation spans such
as `receive <queue>` come from the traced `pgmq-effectful` interpreter. After this plan a
`LongPoll` worker emits one `receive` span per read instead of one per server-side wait;
the process-span contract is untouched.

[ADR-25](../adr/0025-worker-loops-isolate-failures-per-pass-and-per-item-and-report-partial-progress.md)
requires a worker never to let one transient error end its loop. The adapter's poll retry
already honours this for the acquisition timeouts BUG-6 provokes; this plan removes the
cause rather than the symptom.

[ADR-44](../adr/0044-fifo-jobs-declare-ordering-and-only-group-heads-batch-safely.md)
governs FIFO consumption. The adapter applies the same polling-mode switch to grouped reads,
so `FifoHeads`, `FifoThroughput`, and `FifoRoundRobin` workers with `LongPoll` are fixed by
the same one-line change; their ordering guarantees are unaffected.

No cross-repository ADR is relevant. The adapter records its related finding as a bug
report, not an ADR.

### Prior plans that shaped this code

[Plan 74](74-expose-keiro-pgmq-tuning-surface-and-make-job-workers-resilient.md) introduced
`JobTuning`, `JobPolling`, and the `LongPoll s ms` to `LongPolling s ms` mapping.
[Plan 77](77-add-fifo-ordered-delivery-via-message-groups-to-keiro-pgmq.md) extended the
mapping to grouped reads. Neither considered client death during a server-side wait or the
pool budget of concurrent waits.

### Sibling report

[BUG-3](../bug-reports/3-job-worker-exits-after-polling-backend-termination.md) (a worker
exits after its polling backend is terminated) concerns the transient-error classifier and
is not addressed here; nothing in this plan makes it better or worse.


## Plan of Work

### Milestone 0: reproduce both mechanisms in `keiro-pgmq-test` and confirm the reports

This milestone adds two examples to `keiro-pgmq/test/Main.hs` and one helper, updates both
bug reports, and commits with the BUG-6 example failing. At the end, running the two new
examples shows the PostgreSQL mechanism behind BUG-4 (this example is green today and stays
green; it documents the premise) and a red BUG-6 example whose failure output is recorded
in Surprises & Discoveries.

First, the test suite needs the `process` package to spawn and kill a `psql` client. In
`keiro-pgmq/keiro-pgmq.cabal`, add `process >=1.6 && <1.7,` to the `test-suite
keiro-pgmq-test` `build-depends` list (the `keiro` package already depends on it with the
same bound, and `keiro/test/Main.hs` already uses `System.Process`). In
`keiro-pgmq/test/Main.hs` add `import System.Process (createProcess, proc, terminateProcess,
waitForProcess)` and `import Control.Monad (replicateM)` (check whether `Control.Monad` is
already imported and extend that line instead of duplicating it).

Add a helper next to `archiveCount` that counts the server-side long polls currently
executing in the example's database, using a separate throwaway pool so the observation
never competes with the pool under test:

```haskell
-- | Count backends currently executing @pgmq.read_with_poll@ in this database,
-- observed through a separate pool so the measurement never competes with the
-- runtime under test.
activeServerPolls :: Text -> IO Int64
activeServerPolls connStr =
  withPool connStr $ \pool -> do
    let sql =
          "SELECT count(*) FROM pg_stat_activity \
          \WHERE datname = current_database() AND state = 'active' \
          \AND query ILIKE '%read_with_poll%' AND pid <> pg_backend_pid()"
        session =
          Session.statement () $
            Statement.preparable
              sql
              Encoders.noParams
              (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
    result <- Pool.use pool session
    either (\e -> fail ("pg_stat_activity failed: " <> show e)) pure result
```

Add a second helper, `messageLease`, that reads one message row's `read_ct` and whether its
`vt` is still in the future from the queue table `pgmq.q_<physical>` (the physical name is
already sanitized to `[a-z0-9_]` by `queueRef`, so interpolating it is safe, exactly as
`archiveCount` does for the archive table):

```haskell
-- | The single message's @read_ct@ and whether it is still leased (@vt@ in the
-- future). Fails if the queue does not hold exactly one row.
messageLease :: Text -> Text -> IO (Int64, Bool)
messageLease connStr physical =
  withPool connStr $ \pool -> do
    let sql = "SELECT read_ct, vt > clock_timestamp() FROM pgmq.q_" <> physical
        session =
          Session.statement () $
            Statement.preparable
              sql
              Encoders.noParams
              ( Decoders.singleRow $
                  (,)
                    <$> Decoders.column (Decoders.nonNullable Decoders.int8)
                    <*> Decoders.column (Decoders.nonNullable Decoders.bool)
              )
    result <- Pool.use pool session
    either (\e -> fail ("message lease read failed: " <> show e)) pure result
```

The first example demonstrates the BUG-4 mechanism with a real client death. It enqueues one
message that stays invisible for two seconds, starts a `psql` process that calls
`pgmq.read_with_poll` with a ten-second budget, kills that process after 300 milliseconds,
observes that the server backend is still polling half a second after its client died, and
then, once the message has become visible, observes that the orphan consumed a read: the
row's `read_ct` is 1 and it is leased again, although no consumer in the test ever received
it. Place it in the `spec` next to the other worker-path examples:

```haskell
  it "long poll on the server outlives a killed client and consumes a read attempt" $ \connStr -> do
    let job = mkJob "keiro_pgmq_test.orphan_long_poll"
        physical = queueNameToText job.jobQueue.physicalName
        pollSql =
          "SELECT msg_id FROM pgmq.read_with_poll('" <> Text.unpack physical <> "', 30, 1, 10, 100)"
    runDb connStr $ do
      ensureJobQueue job
      _ <- enqueueWithDelay job 2 (Ping "orphan" 1)
      pure ()
    (_, _, _, orphan) <-
      createProcess (proc "psql" [Text.unpack connStr, "-X", "-q", "-At", "-c", pollSql])
    threadDelay 300_000
    terminateProcess orphan
    _ <- waitForProcess orphan
    threadDelay 500_000
    stillPolling <- activeServerPolls connStr
    stillPolling `shouldBe` 1
    threadDelay 2_200_000
    (readCt, leased) <- messageLease connStr physical
    readCt `shouldBe` 1
    leased `shouldBe` True
```

`terminateProcess` sends SIGTERM, which `psql` does not handle, so the client dies without
sending a cancel request (a SIGINT would cancel the query, which is precisely not the
situation under test). The message becomes visible two seconds after enqueue; the orphaned
loop reads it within its next 100-millisecond iteration and then dies trying to return it.
The final observation happens three seconds after enqueue, comfortably after the read and
before the thirty-second lease expires. This example passes on today's tree and after the
fix; it exists to pin the premise of the fix and to detect a future PostgreSQL or PGMQ
change that would make server-side waits client-death-aware.

The second example is the BUG-6 reproduction and is red today. It runs six `LongPoll 5 100`
processors over one queue on the default runtime (three connections), with a handler that
does one piece of database work through the runtime pool (`Pgmq.queueMetrics`) before
returning `Done`. Before enqueueing, it samples `pg_stat_activity` ten times over one second
and asserts that no backend is ever executing `read_with_poll`; today every sample sees
three. It then enqueues one message and asserts delivery, acknowledgement, and an empty
queue within `waitUntil`'s ten-second budget; today the handler's `queueMetrics` call queues
behind the long polls and the example either times out or, when the handler happens to win
a connection, still fails the first assertion. Processor identifiers must be unique inside
one `runApp`, so each processor gets its own `jobName` suffix, as Kenshou's worker role
does:

```haskell
  it "long poll workers never hold server-side polls and stay live with six processors" $ \connStr -> do
    handled <- newIORef (0 :: Int)
    let job = mkJob "keiro_pgmq_test.long_poll_pool"
        tuning =
          either (error . show) id $
            mkJobTuning 30 1 (LongPoll 5 100)
        processorFor index =
          jobProcessorWithContext
            tuning
            job {jobName = job.jobName <> "." <> Text.pack (show index)}
            \_ctx _payload -> do
              _ <- Pgmq.queueMetrics job.jobQueue.physicalName
              liftIO $ modifyIORef' handled (+ 1)
              pure Done
    (serverPolls, processed) <-
      runDb connStr $ do
        ensureJobQueue job
        result <- runJobWorkers IgnoreFailures 16 (map processorFor [0 .. 5 :: Int])
        case result of
          Left err -> liftIO $ fail ("runJobWorkers failed: " <> show err)
          Right app -> do
            liftIO $ threadDelay 1_000_000
            samples <- liftIO $ replicateM 10 (threadDelay 100_000 >> activeServerPolls connStr)
            _ <- enqueue job (Ping "pool" 6)
            ok <- liftIO $ waitUntil ((>= 1) <$> readIORef handled)
            stopAppQuickly app
            pure (maximum samples, ok)
    serverPolls `shouldBe` 0
    processed `shouldBe` True
    len <- runDb connStr (queueLen job.jobQueue.physicalName)
    len `shouldBe` 0
```

The first assertion (`serverPolls`) is the deterministic red: with today's mapping three
connections are always inside `read_with_poll`. The second assertion reproduces the
observable stall and is expected to fail as well, but its exact outcome depends on the STM
race described in Context, so the Surprises & Discoveries entry should record whichever
failure the tree produced. Both examples match the `--match "long poll"` filter used
throughout this plan because their descriptions start with those words.

Then update the two bug reports. In
`docs/bug-reports/4-long-poll-job-worker-consumes-read-attempt-without-handler.md` and
`docs/bug-reports/6-long-poll-processors-starve-the-job-runtime-pool.md`, set `status:
confirmed`, replace the `generated` block with `by: process:claude-code` and the current UTC
timestamp, and append to each body a "Tracked by [plan 300](../plans/300-poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6.md)"
paragraph followed by a short "Root cause" paragraph summarizing the relevant subsection of
this plan's Context in the report's own words (for BUG-4: the server-side
`pgmq.read_with_poll` loop outlives its killed client and commits a read before the failed
flush, with the backend FATAL timestamps as evidence; for BUG-6: each server-side loop pins
one of three pool connections, so handler database work and acknowledgements time out
behind the polls). Keep the existing `reviews` entries untouched. Log the change once for
both reports and validate:

```bash
okf log add docs/bug-reports --kind Update -m "BUG-4 and BUG-6 are confirmed: both trace to the server-side pgmq.read_with_poll loop selected by LongPoll, which outlives a killed worker and pins a runtime pool connection per processor; tracked by ExecPlan 300."
just bug-reports-validate
```

Commit the cabal change, the test file, and the two reports together. The BUG-6 example is
red at this commit by design; note that in the commit body.

### Milestone 1: map `LongPoll` to client-side polling

This milestone is the fix. At the end, the BUG-6 example passes, no keiro worker ever issues
`pgmq.read_with_poll`, and the documentation and changelogs say so.

In `keiro-pgmq/src/Keiro/PGMQ/Job.hs`, change `toPollingConfig` so that both constructors
select the adapter's client-side mode:

```haskell
toPollingConfig :: JobPolling -> PollingConfig
toPollingConfig (PollEvery interval) = StandardPolling interval
toPollingConfig (LongPoll _maxPollSeconds pollIntervalMs) =
  StandardPolling (fromIntegral pollIntervalMs / 1000)
```

`NominalDiffTime` is `Fractional`, so the division yields seconds; `pollIntervalMs` is at
least 1 after `mkJobTuning`, so the adapter's own `InvalidStandardPollInterval` check cannot
fire. The `LongPolling` import from `Shibuya.Adapter.Pgmq` becomes unused only if the
import list names constructors explicitly; it imports `PollingConfig (..)`, so nothing else
changes. Do not remove `maxPollSeconds` from `validPolling`.

Rewrite the `JobPolling` haddock so a reader learns what each constructor does now and why
`LongPoll` no longer waits on the server:

```haskell
-- | How a continuous worker waits for work. Both modes poll from the worker
-- process: the adapter issues one short @pgmq.read@ (or grouped read) statement,
-- releases its runtime-pool connection, and sleeps only when the read returned
-- nothing.
data JobPolling
  = -- | Sleep this long between empty polls.
    PollEvery !NominalDiffTime
  | -- | Poll every @pollIntervalMs@ milliseconds. The first field,
    -- @maxPollSeconds@, is accepted for source compatibility and bounds nothing:
    -- it was the budget of PGMQ's server-side @read_with_poll@ loop, which keiro
    -- no longer uses because a server-side wait outlives a killed worker and
    -- consumes a retry attempt without a handler call, and because it holds a
    -- pool connection for the whole wait (bug reports BUG-4 and BUG-6). Prefer
    -- 'PollEvery' in new code; @LongPoll s ms@ behaves as
    -- @PollEvery (ms / 1000)@.
    LongPoll !Int32 !Int32
  deriving stock (Eq, Show)
```

In the module header's "Delivery and crash semantics" section, add one sentence after the
paragraph about visibility-timeout expiry: "Workers poll from the client process; no wait
runs inside PostgreSQL, so a worker that dies leaves at most one millisecond-scale read in
flight and never holds a pool connection between reads." Also update the haddock of
`jobProcessorWithContext` if it mentions long polling (today it does not).

In `keiro-pgmq/test/Main.hs`, extend the "validates job tuning" example with one more
expectation so both `LongPoll` fields stay validated:

```haskell
    mkJobTuning 30 1 (LongPoll 5 0)
      `shouldBe` Left NonPositivePollInterval
```

Run the suite; the Milestone 0 BUG-6 example must now pass. Then update the documentation.
In `docs/user/work-queues.md`, in the "Tuning" subsection, replace the sentence that begins
"`JobPolling` is either `PollEvery interval` or `LongPoll maxPollSeconds pollIntervalMs`,
which waits inside the database instead of sleeping." with:

```markdown
`JobPolling` is either `PollEvery interval` or `LongPoll maxPollSeconds pollIntervalMs`.
Both poll from the worker process: the worker issues one short `pgmq.read` statement,
releases its runtime-pool connection, and sleeps (`interval` seconds, or `pollIntervalMs`
milliseconds) only when the read returned nothing. `LongPoll` no longer runs PGMQ's
server-side `read_with_poll` loop, and its `maxPollSeconds` argument is accepted for
compatibility and bounds nothing. A server-side wait keeps running after the worker
process dies and charges the next visible message a retry attempt that no handler sees,
and it holds one pool connection per processor for the whole wait; `LongPoll s ms` now
behaves as `PollEvery (ms / 1000)`.
```

Advance the page's `generated.at` timestamp (the frontmatter shows `generated: by:
human:nadeem`; change `by` to `process:claude-code` and `at` to the current UTC time), then
log and validate:

```bash
okf log add docs/user --kind Update -m "Work Queues: LongPoll polls from the worker process at pollIntervalMs and never runs PGMQ's server-side read_with_poll loop (BUG-4, BUG-6)."
just user-documentation-validate
```

Add changelog entries under `## [Unreleased]` in `keiro-pgmq/CHANGELOG.md`:

```markdown
### Fixed

- `LongPoll maxPollSeconds pollIntervalMs` now polls from the worker process every
  `pollIntervalMs` milliseconds instead of running PGMQ's server-side `read_with_poll`
  loop. The server-side loop kept running after a worker process died and consumed a
  retry attempt on the next visible message without any handler call (BUG-4), and it
  held one runtime-pool connection per processor for the whole wait, so a worker with
  more long-polling processors than pool connections stalled its handlers and
  acknowledgements (BUG-6). `maxPollSeconds` is accepted for compatibility and no longer
  bounds anything; prefer `PollEvery`.
```

and a corresponding entry in the root `CHANGELOG.md` under `## [Unreleased]` in a `### Fixed`
section, naming the package. Commit.

### Milestone 2: make the job runtime pool configurable

This milestone adds a configuration record for the pool without changing defaults. At the
end, a caller can run `withJobRuntimeWith config connStr tracer action` with a chosen pool
size and acquisition timeout, an invalid configuration is rejected before any connection is
made, and a test proves the size is honoured.

In `keiro-pgmq/src/Keiro/PGMQ/Runtime.hs`, add the following, exporting every name from the
module's export list under a new "Runtime configuration" heading (the umbrella module
`keiro-pgmq/src/Keiro/PGMQ.hs` re-exports the whole module, so nothing else is needed):

```haskell
import "base" Control.Exception (Exception, bracket, throwIO)
import "time" Data.Time.Clock (DiffTime)

-- | Pool settings for a 'JobRuntime'. The raw constructor is exported but not
-- validated; prefer 'mkJobRuntimeConfig'. 'withJobRuntimeWith' rejects a
-- non-positive size or timeout before opening any connection.
--
-- A processor holds a connection only for the duration of one read, one
-- finalization, or the handler's own database work, so size the pool for the
-- handler concurrency you run plus a small margin for polling and
-- acknowledgement; three connections comfortably serve a few processors whose
-- handlers do little database work.
data JobRuntimeConfig = JobRuntimeConfig
  { -- | Connections the pool may hold open at once.
    poolSize :: !Int,
    -- | How long a caller waits for a free connection before the operation
    -- fails with an acquisition timeout (which the adapter retries as
    -- transient).
    acquisitionTimeout :: !DiffTime
  }
  deriving stock (Eq, Show)

data JobRuntimeConfigError
  = NonPositivePoolSize !Int
  | NonPositiveAcquisitionTimeout !DiffTime
  deriving stock (Eq, Show)
  deriving anyclass (Exception)

-- | hasql-pool's defaults: three connections and a ten-second acquisition timeout.
defaultJobRuntimeConfig :: JobRuntimeConfig
defaultJobRuntimeConfig = JobRuntimeConfig {poolSize = 3, acquisitionTimeout = 10}

mkJobRuntimeConfig :: Int -> DiffTime -> Either JobRuntimeConfigError JobRuntimeConfig
mkJobRuntimeConfig poolSize acquisitionTimeout
  | poolSize < 1 = Left (NonPositivePoolSize poolSize)
  | acquisitionTimeout <= 0 = Left (NonPositiveAcquisitionTimeout acquisitionTimeout)
  | otherwise = Right JobRuntimeConfig {poolSize, acquisitionTimeout}

-- | 'withJobRuntime' with explicit pool settings. Throws 'JobRuntimeConfigError'
-- for an invalid raw configuration before acquiring the pool.
withJobRuntimeWith :: JobRuntimeConfig -> Text -> Maybe Tracer -> (JobRuntime -> IO a) -> IO a
withJobRuntimeWith config connStr tracer action = do
  validated <- either throwIO pure (mkJobRuntimeConfig config.poolSize config.acquisitionTimeout)
  bracket (acquire validated) Pool.release $ \pool ->
    action JobRuntime {runtimePool = pool, runtimeTracer = tracer}
  where
    acquire validated =
      Pool.acquire $
        Pool.Config.settings
          [ Pool.Config.size validated.poolSize,
            Pool.Config.acquisitionTimeout validated.acquisitionTimeout,
            Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
          ]

withJobRuntime :: Text -> Maybe Tracer -> (JobRuntime -> IO a) -> IO a
withJobRuntime = withJobRuntimeWith defaultJobRuntimeConfig
```

`DeriveAnyClass` and `OverloadedRecordDot` are already default extensions in the cabal
`shared` stanza, so `config.poolSize` and the `Exception` derivation compile as written.
`Pool.Config.size` and `Pool.Config.acquisitionTimeout` exist across the package's
`hasql-pool >=1.2 && <1.5` bound (the settings DSL has been there since 1.0). Update the
`withJobRuntime` haddock to say it uses `defaultJobRuntimeConfig`.

In `keiro-pgmq/test/Main.hs`, add two examples. The first is pure:

```haskell
  it "validates job runtime configuration" $ \_connStr -> do
    mkJobRuntimeConfig 0 10 `shouldBe` Left (NonPositivePoolSize 0)
    mkJobRuntimeConfig 1 0 `shouldBe` Left (NonPositiveAcquisitionTimeout 0)
    mkJobRuntimeConfig 3 10 `shouldBe` Right defaultJobRuntimeConfig
```

The second proves the configured size and timeout reach the pool. With one connection and
a 200-millisecond acquisition timeout, a session that holds the only connection for a second
makes a concurrent session fail with `AcquisitionTimeoutUsageError`. Use `forkIO` from
`Control.Concurrent` (already imported for `threadDelay`; extend the import) and an `MVar` to
join the holder:

```haskell
  it "job runtime pool honours the configured size and timeout" $ \connStr -> do
    let config = either (error . show) id (mkJobRuntimeConfig 1 0.2)
    done <- newEmptyMVar
    outcome <-
      withJobRuntimeWith config connStr Nothing $ \rt -> do
        _ <- forkIO $ do
          _ <- Pool.use rt.runtimePool (Session.script "SELECT pg_sleep(1)")
          putMVar done ()
        threadDelay 100_000
        result <- Pool.use rt.runtimePool (Session.script "SELECT 1")
        takeMVar done
        pure result
    outcome `shouldSatisfy` \case
      Left Pool.AcquisitionTimeoutUsageError -> True
      _ -> False
```

`Session.script` (hasql 1.10's name for running a raw SQL string; `keiro-pgmq/test/Main.hs`
already uses it) takes the statement as `Text`; `Control.Concurrent.MVar` provides `newEmptyMVar`,
`putMVar`, and `takeMVar`. Run `cabal build all` and `cabal test keiro-pgmq-test`.

Update `docs/user/work-queues.md` "The runtime" subsection: after the sentence
"`withJobRuntime` owns a Hasql pool and an optional OpenTelemetry tracer; `runJobEff`
interprets the effect stack against it and surfaces PGMQ failures as a `Left`.", add:

```markdown
The pool holds three connections and waits ten seconds for a free one by default
(`defaultJobRuntimeConfig`). `withJobRuntimeWith` takes a `JobRuntimeConfig` built with
`mkJobRuntimeConfig poolSize acquisitionTimeout` when a worker needs more. A processor
holds a connection only while it reads, finalizes, or runs the handler's own database
work, so size the pool for the handler concurrency you run plus a small margin.
```

In `docs/user/api-reference.md`, find the `Keiro.PGMQ.Runtime` bullet in the keiro-pgmq
section (near the `Keiro.PGMQ.Job` bullet around line 1040; if the runtime has no bullet,
add one after the `Keiro.PGMQ.Job` bullet) and list `JobRuntimeConfig (..)`,
`defaultJobRuntimeConfig`, `mkJobRuntimeConfig`, and `withJobRuntimeWith` beside
`withJobRuntime`. Advance both pages' `generated` blocks, log once, validate:

```bash
okf log add docs/user --kind Update -m "Work Queues and API reference: document the job runtime pool defaults and the new JobRuntimeConfig / withJobRuntimeWith surface."
just user-documentation-validate
```

Add `### Added` entries to `keiro-pgmq/CHANGELOG.md` and the root `CHANGELOG.md` under
`## [Unreleased]`: "`JobRuntimeConfig`, `defaultJobRuntimeConfig`, `mkJobRuntimeConfig`, and
`withJobRuntimeWith` expose the job runtime pool's size and acquisition timeout;
`withJobRuntime` keeps the previous defaults of three connections and ten seconds." Commit.

### Milestone 3: close the reports, distill the decision, and verify

This milestone finishes the paperwork the repository requires and runs the release gate.

Set both bug reports to `fixed`. In each frontmatter change `status: fixed`, add
`fixedVersion: unreleased`, add a `resolution: >-` block (BUG-4: "`LongPoll` now polls from
the worker process; keiro workers never issue `pgmq.read_with_poll`, so a killed worker
leaves no server-side loop to consume a read. Plan 300 pins the PostgreSQL mechanism with a
killed-client example and re-runs of the Kenshou scenario are a post-release follow-up."
BUG-6: "`LongPoll` no longer pins a runtime-pool connection between reads, so six
processors on the default three-connection pool deliver and acknowledge within seconds;
the pool size and acquisition timeout are now configurable through
`withJobRuntimeWith`."), and advance `generated.at`. Log and validate:

```bash
okf log add docs/bug-reports --kind Update -m "BUG-4 and BUG-6 are fixed on master (fixedVersion unreleased): LongPoll polls client-side and the runtime pool is configurable; ExecPlan 300."
just bug-reports-validate
```

Distill the durable decision into a new ADR. Allocate the handle and create the file:

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
```

At the time of writing this prints `ADR-49`; use whatever it prints. Create
`docs/adr/00NN-job-workers-poll-pgmq-from-the-client-and-never-pin-a-pool-connection-between-reads.md`
with frontmatter matching the existing records (`type: Architecture Decision Record`,
`title`, one-sentence `description`, `timestamp`, `docId`, `status: Accepted`, `date`, and
`originatingPlan: docs/plans/300-poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6.md`).
The decision: keiro's continuous job workers wait for work in the client process and never
run a wait inside PostgreSQL; any future polling primitive must release its pool connection
between reads and must leave nothing running on the server after the worker process dies.
The context is the two-part mechanism from this plan's Context section; the consequences
are that `LongPoll` is a compatibility spelling of interval polling, that the adapter's
`LongPolling` mode is not selected by keiro even if a future adapter release changes it,
and that the runtime pool budget is reads plus finalizations plus handler work rather than
one connection per processor. Then:

```bash
okf log add docs/adr --kind Addition -m "ADR-NN: job workers poll PGMQ from the client process and never pin a runtime-pool connection between reads (plan 300)."
just adr-validate
```

Commit. Finally run the release gate and record the result in Progress:

```bash
just verify > /tmp/verify-300.log 2>&1; echo "exit=$?" >> /tmp/verify-300.log
tail -5 /tmp/verify-300.log
```

`just verify` stops at the first failing recipe, so read the `exit=` line from inside the
log rather than trusting the last lines of output, and if it fails, fix the failing recipe
and rerun until the log ends with `exit=0`. Then write Outcomes & Retrospective, including
the two follow-ups outside this repository: Kenshou should re-run
`keiro/queue/concurrency/crash-redelivery-cadence --set queue.polling=long-poll` and
`keiro/queue/concurrency/runtime-pool-isolation` on a cohort that includes the released
keiro and remove the `KnownDefect` scoping for BUG-4 in its `Concurrency.hs`; and the
adapter's own BUG-1 remains open in `mori://shinzui/shibuya-pgmq-adapter` for consumers
that select `LongPolling` directly.


## Concrete Steps

All commands run from the repository root, inside `nix develop` (or any shell with GHC
9.12, `cabal`, `bun`, `okf`, `just`, and PostgreSQL 18 binaries including `psql` on the
`PATH`).

Before starting, confirm the tree and the tools:

```bash
git status --short
which psql initdb postgres okf just
cabal build keiro-pgmq
```

Expect an empty status (or only files you already know about), five paths, and a
successful build.

Milestone 0. Edit `keiro-pgmq/keiro-pgmq.cabal` and `keiro-pgmq/test/Main.hs` as described,
then run only the new examples:

```bash
cabal test keiro-pgmq-test --test-show-details=direct --test-options='--match "long poll"'
```

Expected today:

```text
Keiro.PGMQ
  long poll on the server outlives a killed client and consumes a read attempt [✔]
  long poll workers never hold server-side polls and stay live with six processors [✘]

Failures:

  keiro-pgmq/test/Main.hs:NNN:
  1) Keiro.PGMQ long poll workers never hold server-side polls and stay live with six processors
       expected: 0
        but got: 3
```

The `but got` value is the number of backends inside `read_with_poll` at the busiest sample;
three is the pool size. Copy the failure block into Surprises & Discoveries. Update the two
bug reports, run the `okf log add` and `just bug-reports-validate` commands from the Plan of
Work, and commit:

```text
test(keiro-pgmq): reproduce long-poll orphan reads and pool starvation

Add a killed-psql example that shows pgmq.read_with_poll outliving its client and
consuming a read attempt (BUG-4), and a red six-processor LongPoll example on the
default runtime pool (BUG-6). Confirm both reports and link plan 300.

ExecPlan: docs/plans/300-poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6.md
Intention: intention_01m3t0bf63emytzb6ct908drwy
```

Milestone 1. Edit `toPollingConfig` and the haddocks in `keiro-pgmq/src/Keiro/PGMQ/Job.hs`,
extend the tuning example, then:

```bash
cabal build keiro-pgmq
cabal test keiro-pgmq-test --test-show-details=direct
```

Expected: the whole suite passes, including both `long poll` examples. Update
`docs/user/work-queues.md`, log, validate, add the changelog entries, and commit:

```text
fix(keiro-pgmq): poll PGMQ from the worker process for LongPoll tuning

Map LongPoll to the adapter's client-side polling mode at pollIntervalMs so a
keiro worker never runs pgmq.read_with_poll. The server-side loop outlived a
killed worker and consumed a retry attempt with no handler call (BUG-4) and
pinned one runtime-pool connection per processor (BUG-6).

ExecPlan: docs/plans/300-poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6.md
Intention: intention_01m3t0bf63emytzb6ct908drwy
```

Milestone 2. Edit `keiro-pgmq/src/Keiro/PGMQ/Runtime.hs`, add the two examples, then:

```bash
cabal build all
cabal test keiro-pgmq-test --test-show-details=direct --test-options='--match "job runtime"'
```

Expected: both new examples pass; `--match "job runtime"` selects "validates job runtime
configuration" and "job runtime pool honours the configured size and timeout". Update the two documentation pages, log, validate, add the changelog entries,
and commit:

```text
feat(keiro-pgmq): expose the job runtime pool size and acquisition timeout

Add JobRuntimeConfig, mkJobRuntimeConfig, defaultJobRuntimeConfig, and
withJobRuntimeWith; withJobRuntime keeps hasql-pool's defaults of three
connections and ten seconds.

ExecPlan: docs/plans/300-poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6.md
Intention: intention_01m3t0bf63emytzb6ct908drwy
```

Milestone 3. Update the bug reports to `fixed`, create the ADR, log both bundles, validate,
and commit:

```text
docs: close BUG-4 and BUG-6 and record the client-side polling decision

ExecPlan: docs/plans/300-poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6.md
Intention: intention_01m3t0bf63emytzb6ct908drwy
```

Then run `just verify` as shown in the Plan of Work, record the exit code in Progress, and
commit the plan's final Progress and Outcomes & Retrospective updates with a `docs(plans):`
commit carrying the same trailers.


## Validation and Acceptance

The change is accepted when all of the following hold on the final tree.

Running the focused examples passes:

```bash
cabal test keiro-pgmq-test --test-show-details=direct --test-options='--match "long poll"'
```

with both `long poll` examples marked `[✔]`. The six-processor example proves two things a
reader can check independently: while six `LongPoll 5 100` processors are running on a
three-connection runtime, `SELECT count(*) FROM pg_stat_activity WHERE query ILIKE
'%read_with_poll%' AND state = 'active'` is zero at every sample (before the fix it is
three), and a message enqueued afterwards is handled, acknowledged, and gone from the queue
within ten seconds (before the fix it is not).

Running the runtime examples passes:

```bash
cabal test keiro-pgmq-test --test-show-details=direct --test-options='--match "job runtime"'
```

with `mkJobRuntimeConfig` rejecting a zero size and a zero timeout, and a one-connection
runtime with a 200-millisecond timeout returning `Left AcquisitionTimeoutUsageError` to a
second concurrent session.

The full package suite passes:

```bash
cabal test keiro-pgmq-test
```

The three OKF bundles validate, each of these exiting 0:

```bash
just bug-reports-validate
just user-documentation-validate
just adr-validate
```

The release gate passes with `exit=0` recorded inside `/tmp/verify-300.log`.

The behaviour is visible outside the test suite too. Start any keiro worker with
`LongPoll 5 100` against a PostgreSQL 18 database and run, from `psql`, `SELECT query FROM
pg_stat_activity WHERE query ILIKE '%pgmq.read%'`; before this plan the worker's rows show
`pgmq.read_with_poll($1,$2,...)` and persist for seconds, after it they show
`pgmq.read($1,$2,...)` and are gone within milliseconds.


## Idempotence and Recovery

Every step is safe to repeat. The test suite creates a fresh database per example, so a
failed or interrupted run leaves nothing behind except a possibly orphaned `psql` process
from the killed-client example, which exits on its own when its ten-second poll budget
ends or when the suite's PostgreSQL server stops. `okf log add` appends a line; if you run
it twice, delete the duplicate line from the bundle's `log.md` before validating. Changing
`toPollingConfig` back to `LongPolling maxPollSeconds pollIntervalMs` restores the previous
behaviour exactly (the BUG-6 example then fails again, which is the intended signal).
Milestone 2 is purely additive: `withJobRuntime` keeps its signature and defaults, so a
consumer that never calls `withJobRuntimeWith` sees no difference. Bug-report and ADR
frontmatter edits are plain text; if `just bug-reports-validate` or `just adr-validate`
rejects a field, the validator names it, and the profiles require `fixedVersion` only when
`status` is `fixed` and `resolution` on any terminal status. If `just verify` fails in a
recipe unrelated to this plan, record the failing recipe and its exit code in Surprises &
Discoveries and fix or report it before rerunning; do not skip recipes.


## Interfaces and Dependencies

No new library dependencies for the `keiro-pgmq` library. The test suite gains `process
>=1.6 && <1.7` (already used by the `keiro` package's tests) to spawn and kill `psql`.
Existing dependencies used by name in this plan: `shibuya-pgmq-adapter ^>=0.16.1.0`
(`Shibuya.Adapter.Pgmq.PollingConfig` with constructors `StandardPolling` and
`LongPolling`), `hasql-pool >=1.2 && <1.5` (`Hasql.Pool.Config.settings`, `size`,
`acquisitionTimeout`, `staticConnectionSettings`; `Hasql.Pool.use`,
`AcquisitionTimeoutUsageError`), `time` (`Data.Time.Clock.DiffTime`,
`Data.Time.NominalDiffTime`), and `pgmq-effectful` (`Pgmq.queueMetrics` inside the BUG-6
example's handler).

At the end of Milestone 1, `Keiro.PGMQ.Job` exports the unchanged
`data JobPolling = PollEvery !NominalDiffTime | LongPoll !Int32 !Int32`, and its private
`toPollingConfig :: JobPolling -> PollingConfig` returns `StandardPolling` for both
constructors, with `LongPoll _ ms` mapped to `StandardPolling (fromIntegral ms / 1000)`.

At the end of Milestone 2, `Keiro.PGMQ.Runtime` (re-exported by `Keiro.PGMQ`) exports:

```haskell
data JobRuntimeConfig = JobRuntimeConfig {poolSize :: !Int, acquisitionTimeout :: !DiffTime}
data JobRuntimeConfigError = NonPositivePoolSize !Int | NonPositiveAcquisitionTimeout !DiffTime
defaultJobRuntimeConfig :: JobRuntimeConfig
mkJobRuntimeConfig :: Int -> DiffTime -> Either JobRuntimeConfigError JobRuntimeConfig
withJobRuntimeWith :: JobRuntimeConfig -> Text -> Maybe Tracer -> (JobRuntime -> IO a) -> IO a
withJobRuntime :: Text -> Maybe Tracer -> (JobRuntime -> IO a) -> IO a
```

with `withJobRuntime = withJobRuntimeWith defaultJobRuntimeConfig` and
`defaultJobRuntimeConfig = JobRuntimeConfig 3 10`.

At the end of Milestone 3, `docs/bug-reports/4-...md` and `docs/bug-reports/6-...md` carry
`status: fixed`, `fixedVersion: unreleased`, and a `resolution`; a new ADR under `docs/adr/`
records the client-side polling decision with `originatingPlan` pointing at this file; and
`keiro-pgmq/CHANGELOG.md` and `CHANGELOG.md` carry `Fixed` and `Added` entries under
`[Unreleased]`.


## Revision notes

- 2026-09-30: Added to the upstream-adapter decision that the finding was shared into the
  shibuya-pgmq-adapter bug-report bundle (root cause on its BUG-1, new BUG-4 for the orphaned
  server-side poll) and that the adapter is planning its own client-side switch. No change to
  this plan's scope or milestones: keiro's mapping fix stands regardless of the adapter's
  timeline.
