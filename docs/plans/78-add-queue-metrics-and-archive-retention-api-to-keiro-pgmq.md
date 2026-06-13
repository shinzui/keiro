---
id: 78
slug: add-queue-metrics-and-archive-retention-api-to-keiro-pgmq
title: "Add queue metrics and archive retention API to keiro-pgmq"
kind: exec-plan
created_at: 2026-06-13T14:29:36Z
intention: "intention_01kv0jvq2qe70reyz4f6dpfxnk"
master_plan: "docs/masterplans/10-keiro-pgmq-queue-feature-expansion-fifo-ordering-headers-provisioning-observability.md"
---

# Add queue metrics and archive retention API to keiro-pgmq

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`keiro-pgmq` (the directory `keiro-pgmq/` in this repository) is a typed background-job
queue for Keiro applications. An application declares a `Job` value (bundling a queue, a
payload codec, and a retry/dead-letter policy), writes a plain handler of type
`p -> Eff es JobOutcome`, and the package runs that handler against PGMQ. "PGMQ" is a
PostgreSQL-native message queue: every queue named `foo` is, under the hood, a plain table
`pgmq.q_foo`, with a sibling archive table `pgmq.a_foo` and a registry row in `pgmq.meta`.
"DLQ" means dead-letter queue: a second PGMQ queue (named `<physical>_dlq`) where the
package parks messages that exhausted their retries or that the codec could not decode.

Today an operator who runs keiro-pgmq has no first-class way to answer two operational
questions from Haskell. First, "how deep is this queue, and how old is its oldest message?"
— the information needed to alert when consumers fall behind. The only path is to reach
past the `Job` abstraction and call `pgmq-effectful`'s `queueMetrics` with a raw
`QueueName`, which means re-deriving the physical and DLQ names by hand. Second, "keep this
dead-lettered message for audit instead of deleting it" — the existing
`Keiro.PGMQ.Dlq.purgeDlq` only *deletes* DLQ rows permanently (it calls
`deleteAllMessagesFromQueue`, which `TRUNCATE`s the table), so retaining a poison message
for a compliance review or a post-mortem is not possible through the package.

After this change, a keiro application gains a small, typed observability-and-archival
surface keyed on its own `Job` value:

- It can read the queue depth, the visible (immediately-readable) depth, the oldest and
  newest message ages, and the cumulative throughput for both the main queue and the DLQ —
  by passing a `Job p`, never a raw `QueueName`. This is exactly the data the existing
  `Keiro.PGMQ.Dlq` module's haddock already tells operators to "alert on" but gives them no
  typed way to fetch.
- It can *archive* dead-letter rows for audit retention — moving them out of the active DLQ
  into PGMQ's archive table `pgmq.a_<dlq>` (which keeps `enqueued_at`, `read_ct`, and stamps
  an `archived_at`) — rather than only deleting them with `purgeDlq` or only dead-lettering
  them. This makes first-class the "archive entries before purging when audit retention
  matters" recommendation that the `Keiro.PGMQ.Dlq` haddock already states but the package
  never implemented.

You can see it working by running the package's behavioral test suite from the repository
root and watching the new examples pass:

```bash
cabal test keiro-pgmq-test
```

The new examples prove observable behavior: after enqueuing three messages,
`jobQueueMetrics` reports `queueLength == 3`; after a `Dead` outcome routes one message to
the DLQ, `jobDlqMetrics` reports `queueLength == 1`; and after `archiveDlq` runs, the DLQ's
active depth drops to `0` while a direct SQL count of the archive table `pgmq.a_<dlq>` shows
the row was retained, not deleted.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Create `keiro-pgmq/src/Keiro/PGMQ/Metrics.hs` with `jobQueueMetrics`, `jobDlqMetrics`, `queueDepth`, and `allJobMetrics`.
- [ ] M1: Add `Keiro.PGMQ.Metrics` to `exposed-modules` in `keiro-pgmq/keiro-pgmq.cabal`.
- [ ] M1: Re-export `Keiro.PGMQ.Metrics` from the umbrella `keiro-pgmq/src/Keiro/PGMQ.hs` (Integration Point 5).
- [ ] M1: Add metrics tests to `keiro-pgmq/test/Main.hs` (main-queue depth, DLQ depth after a `Dead` outcome).
- [ ] M1: `cabal test keiro-pgmq-test` passes with the new metrics examples.
- [ ] M2: Add the archive/retention API (`archiveDlq`, `archiveDlqEntry`) to `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs` and its export list.
- [ ] M2: Add archive-retention tests to `keiro-pgmq/test/Main.hs`, asserting active-DLQ depth drops AND the row is present in `pgmq.a_<dlq>`.
- [ ] M2: `cabal test keiro-pgmq-test` passes with the new archive examples.
- [ ] M3 (optional): Author module haddock documenting the archive-then-purge / depth-alert retention model; add an end-to-end retention scenario test (enqueue → dead-letter → archiveDlq → purgeDlq, archive still populated).
- [ ] Update this plan's Progress, Decision Log, Surprises, and Outcomes sections as work lands; update the MasterPlan registry row for EP-4.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Put the read-only metrics surface in a brand-new module
  `keiro-pgmq/src/Keiro/PGMQ/Metrics.hs`, and put the archive/retention helpers in the
  existing `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs` rather than a separate `Keiro.PGMQ.Archive`
  module.
  Rationale: Metrics is a cohesive read-only concern with no DLQ-specific logic — it deserves
  its own small module (mirroring how `#74` added `Keiro.PGMQ.Dlq` as its own module). The
  archive/retention helper, by contrast, is *about dead-letter rows*: `archiveDlq` reads the
  DLQ, archives each row, and is the direct counterpart of the existing `purgeDlq`
  (delete-all) and `redriveDlq` (move-back) that already live in `Keiro.PGMQ.Dlq`. Co-locating
  it there lets the three DLQ disposition verbs — redrive, archive, purge — sit side by side
  and share the `Job`-keyed `dlqName` plumbing, instead of fragmenting the retention story
  across two modules. A separate `Keiro.PGMQ.Archive` module was rejected because it would
  duplicate the DLQ-read boilerplate and split a single conceptual surface; a general
  "archive any message" helper, if added, also lives in `Keiro.PGMQ.Dlq` next to `archiveDlq`.
  Date: 2026-06-13

- Decision: Re-expose `pgmq-effectful`'s `QueueMetrics` record *directly* (re-exported through
  the umbrella) rather than wrapping it in a keiro-specific record.
  Rationale: `QueueMetrics` is already an ergonomic, field-named record
  (`queueLength`, `queueVisibleLength`, `oldestMsgAgeSec`, `newestMsgAgeSec`, `totalMessages`,
  `scrapeTime`, `queueName`) that exactly matches PGMQ's `metrics()` output and is what the
  existing test suite and the `Keiro.PGMQ.Dlq` haddock already reference by name. Wrapping it
  would add a field-for-field copy plus a conversion function with zero added meaning, and
  would force callers to learn a second vocabulary for the same data. We instead return
  `QueueMetrics` unchanged and re-export the type (with its field accessors) from the
  `Keiro.PGMQ` umbrella so callers get it via `import Keiro.PGMQ`. If a future need arises to
  combine main + DLQ into one value, a thin `JobMetrics { mainMetrics, dlqMetrics }` record can
  be added without disturbing the per-queue functions.
  Date: 2026-06-13

- Decision: Model retention as "archive-then-purge", with `archiveDlq` as the archive verb and
  the existing `purgeDlq` as the (unchanged) delete verb; do not change `purgeDlq` to archive.
  Rationale: PGMQ never expires rows on its own. The two disposition primitives PGMQ offers are
  `archive` (move the row to `pgmq.a_<queue>`, preserving it with an `archived_at` stamp) and
  `delete`/`purge` (remove it permanently). Keiro should expose both as distinct, composable
  verbs: an operator who needs an audit trail runs `archiveDlq` (retain) and may then run
  `purgeDlq` (clear the active table) or simply alerts on depth; an operator who does not need
  retention keeps using `purgeDlq` alone. Quietly changing `purgeDlq` to archive would break its
  documented delete semantics and surprise existing callers. Keeping them separate matches the
  upstream PGMQ "Delete vs. Archive" guidance and the `Keiro.PGMQ.Dlq` haddock's existing
  "archive entries before purging" recommendation.
  Date: 2026-06-13

- Decision: Key every new function on `Job p` (reading `job.jobQueue.physicalName` and
  `job.jobQueue.dlqName`), never on a raw `QueueName`.
  Rationale: Integration Point 4 of MasterPlan #10 freezes `Job` and `QueueRef` as shared
  read-only context for all four child plans, and the whole point of the `Job` layer is that
  callers never hand-derive physical or DLQ names. Keying metrics and archive on `Job p`
  matches `enqueue`, `ensureJobQueue`, `readDlq`, `redriveDlq`, and `purgeDlq`, all of which
  already take a `Job p`. Where a passthrough over *all* queues is useful (`allJobMetrics`),
  it takes no `Job` and simply forwards `pgmq-effectful`'s `allQueueMetrics`.
  Date: 2026-06-13


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of this repository. Read it before touching any file.

`keiro-pgmq` is a Haskell library package under `keiro-pgmq/` whose Cabal file is
`keiro-pgmq/keiro-pgmq.cabal`. Its public modules live under `keiro-pgmq/src/Keiro/PGMQ/`:

- `keiro-pgmq/src/Keiro/PGMQ/Runtime.hs` — "Layer 1": transport-agnostic plumbing. It defines
  the record `QueueRef`, which holds a `logicalName :: Text`, a `physicalName :: QueueName`
  (the sanitized, PGMQ-legal name of the main queue), and a `dlqName :: QueueName` (the derived
  `<physical>_dlq` dead-letter queue name). It also defines the runtime handle `JobRuntime`,
  `withJobRuntime` (acquire a connection pool), and `runJobEff` (run an effect action against
  the runtime). "Effect" here means the `effectful` library's typed effect stack; the stack
  this package runs is `'[Pgmq, Tracing, Error PgmqRuntimeError, IOE]`.
- `keiro-pgmq/src/Keiro/PGMQ/Codec.hs` — payload codecs (`JobCodec`, `encodeJob`, `decodeJob`).
- `keiro-pgmq/src/Keiro/PGMQ/Job.hs` — "Layer 2": the typed `Job` ergonomics. It defines the
  frozen record `Job p = Job { jobName :: Text, jobQueue :: QueueRef, jobCodec :: JobCodec p,
  jobPolicy :: RetryPolicy }`, the producers `enqueue`/`enqueueWithDelay`, the queue-lifecycle
  helper `ensureJobQueue`, and the consumers (`jobProcessor`, `runJobWorkers`, `runJobOnce`,
  and their context-aware variants). It also defines `JobOutcome` (a handler returns `Done`,
  `Retry`, `RetryDefault`, or `Dead reason`).
- `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs` — dead-letter-queue inspection and disposition. It defines
  `DlqEntry p` (a decoded dead-letter row) and three verbs: `readDlq :: Job p -> Int32 -> Eff es
  [DlqEntry p]` (inspect up to n rows), `redriveDlq :: Job p -> Int -> Eff es Int` (move up to n
  rows back to the main queue), and `purgeDlq :: Job p -> Eff es ()` (delete *all* DLQ rows
  permanently via `deleteAllMessagesFromQueue`). Its module haddock already advises operators to
  "archive entries before purging when audit retention matters" and to "alert on the DLQ's
  `queueMetrics` depth" — two recommendations this plan turns into real functions.
- `keiro-pgmq/src/Keiro/PGMQ.hs` — the umbrella module. It re-exports the whole public surface
  with `module Keiro.PGMQ.Runtime`, `module Keiro.PGMQ.Codec`, `module Keiro.PGMQ.Job`, and
  `module Keiro.PGMQ.Dlq`, so a consumer writes a single `import Keiro.PGMQ` and gets everything.

The package depends on `pgmq-effectful` (Cabal dependency `pgmq-effectful >=0.3 && <0.4`), an
`effectful` wrapper over PGMQ. The functions and types this plan uses from it are all available
through the umbrella module `Pgmq.Effectful` (verified by reading
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-effectful/src/Pgmq/Effectful.hs`):

- `queueMetrics :: (Pgmq :> es) => QueueName -> Eff es QueueMetrics` — one queue's metrics.
- `allQueueMetrics :: (Pgmq :> es) => Eff es [QueueMetrics]` — every queue's metrics.
- `archiveMessage :: (Pgmq :> es) => MessageQuery -> Eff es Bool` — move one message from
  `pgmq.q_<queue>` to `pgmq.a_<queue>`; returns `True` if a row was moved.
- `readMessage :: (Pgmq :> es) => ReadMessage -> Eff es (Vector Message)` — read (and make
  invisible) up to a batch of messages.
- `MessageQuery { queueName :: QueueName, messageId :: MessageId }`, and
  `ReadMessage { queueName :: QueueName, delay :: Int32, batchSize :: Maybe Int32, conditional
  :: Maybe Value }` — both already used in `Keiro.PGMQ.Dlq`.

The `QueueMetrics` record is defined in `Pgmq.Hasql.Statements.Types` but is re-exported with
its field accessors (`QueueMetrics (..)`) from the `Pgmq.Effectful` umbrella. Its exact fields
(verified by reading
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-hasql/src/Pgmq/Hasql/Statements/Types.hs`):

```haskell
data QueueMetrics = QueueMetrics
  { queueName          :: !Text
  , queueLength        :: !Int64        -- total rows in q_<name> (visible + in-flight)
  , newestMsgAgeSec    :: !(Maybe Int32) -- now() - max(enqueued_at)
  , oldestMsgAgeSec    :: !(Maybe Int32) -- now() - min(enqueued_at)
  , totalMessages      :: !Int64        -- cumulative ever sent (from the identity sequence)
  , scrapeTime         :: !UTCTime
  , queueVisibleLength :: !Int64        -- rows where vt <= now(); immediately readable
  }
```

PGMQ archive semantics (verified against the upstream advanced guide at
`/Users/shinzui/Keikaku/hub/postgresql/pgmq-project/docs/advanced-guide.md`, sections "Delete
vs. Archive" and "The Archive Path", and the monitoring guide at
`/Users/shinzui/Keikaku/hub/postgresql/pgmq-project/docs/monitoring-and-inspection.md`, sections
"The Three Tables Behind Every Queue" and "Inspecting the Archive"): `pgmq.archive('foo', id)`
atomically `DELETE`s the row from the active table `pgmq.q_foo` and `INSERT`s it into the
archive table `pgmq.a_foo`, preserving `msg_id`, `enqueued_at`, `read_ct`, `last_read_at`,
`message`, and `headers`, and stamping an `archived_at` default of `now()`. It is *not*
deletion — the row is retained for audit and lives in `pgmq.a_<queue>` indefinitely until you
prune it. By contrast `pgmq.purge_queue('foo')` (what `deleteAllMessagesFromQueue` calls)
`TRUNCATE`s `pgmq.q_foo`, removing every active row permanently; it does not touch the archive.
PGMQ exposes no built-in "read the archive" function — the archive is inspected with plain SQL,
e.g. `SELECT count(*) FROM pgmq.a_<queue>`. This matters for the test: to *prove* retention
(not mere deletion) we count rows in `pgmq.a_<dlq>` directly.

The test harness is `keiro-pgmq/test/Main.hs`, a single Hspec spec compiled as the
`keiro-pgmq-test` component. It starts one suite-level PostgreSQL server with
`Keiro.Test.Postgres.withMigratedSuiteWith installPgmq` (which installs the PGMQ schema into a
template database once), then gives each example a fresh isolated database via
`around (Postgres.withFreshDatabase fixture)`. Each example receives a libpq connection string
(`connStr :: Text`); the helper `runDb connStr act` runs an `Eff Stack a` action against a fresh
`JobRuntime`, and `queueLen :: QueueName -> Eff Stack Int64` already reads a queue's
`queueMetrics` length. The suite builds a Hasql `Pool` directly in `withPool`/`installPgmq`,
which is how the archive-retention assertion will count rows in `pgmq.a_<dlq>` with a small
raw `hasql` session.

This plan, EP-4 of MasterPlan
`docs/masterplans/10-keiro-pgmq-queue-feature-expansion-fifo-ordering-headers-provisioning-observability.md`,
is **independent**: it has no hard dependency on the sibling plans
`docs/plans/75-add-message-headers-trace-propagation-and-batch-enqueue-to-keiro-pgmq-producers.md`
(EP-1), `docs/plans/76-add-partitioned-and-unlogged-queue-provisioning-with-fifo-indexes-to-keiro-pgmq.md`
(EP-2), or `docs/plans/77-add-fifo-ordered-delivery-via-message-groups-to-keiro-pgmq.md` (EP-3).
There is a **soft** relationship to EP-3 (plan 77): EP-3's operational documentation references
EP-4's metrics surface as the natural way to observe a FIFO queue's per-group backlog, but EP-3
does not require EP-4's code to compile or pass tests. This plan touches a disjoint slice of the
package (a new read-only metrics module plus an additive archive verb in `Keiro.PGMQ.Dlq`) and
modifies no function any other plan modifies. It does **not** change `Job`'s or `QueueRef`'s
fields (Integration Point 4).


## Plan of Work

The work is three milestones. M1 and M2 are mandatory and independently verifiable; M3 is
optional documentation plus an end-to-end scenario test. Every milestone's acceptance command
is `cabal test keiro-pgmq-test`, run from the repository root
`/Users/shinzui/Keikaku/bokuno/keiro`.

### Milestone M1 — Typed metrics surface (main + DLQ depth, age, throughput)

Scope: add a new module `keiro-pgmq/src/Keiro/PGMQ/Metrics.hs` that exposes the queue metrics
for a `Job`'s main queue and DLQ, keyed on `Job p`. At the end of this milestone, a caller can
`import Keiro.PGMQ` and call `jobQueueMetrics job` to get the main queue's `QueueMetrics`,
`jobDlqMetrics job` to get the DLQ's `QueueMetrics`, `queueDepth job` to get the main queue's
visible length as an `Int64`, and `allJobMetrics` to get every queue's metrics. The new module
is wired into both `keiro-pgmq.cabal`'s `exposed-modules` and the `Keiro.PGMQ` umbrella's
re-export list, so `QueueMetrics` and the new functions are reachable through `import Keiro.PGMQ`
(Integration Point 5). Tests prove the behavior against the isolated database.

Concrete edits:

1. Create `keiro-pgmq/src/Keiro/PGMQ/Metrics.hs`. The module imports the frozen `Job (..)` from
   `Keiro.PGMQ.Job` and `QueueRef (..)` from `Keiro.PGMQ.Runtime`, and `queueMetrics`,
   `allQueueMetrics`, and the type `QueueMetrics (..)` from the `Pgmq.Effectful` umbrella. It
   defines four functions (exact signatures in Interfaces and Dependencies). `jobQueueMetrics`
   calls `Pgmq.queueMetrics job.jobQueue.physicalName`; `jobDlqMetrics` calls
   `Pgmq.queueMetrics job.jobQueue.dlqName`; `queueDepth` calls `jobQueueMetrics` and returns the
   `.queueVisibleLength` field (the immediately-readable count — the right number for "how much
   work is waiting"); `allJobMetrics` forwards `Pgmq.allQueueMetrics`. The module re-exports
   `QueueMetrics (..)` so a caller importing only `Keiro.PGMQ.Metrics` still gets the field
   accessors. Use `PackageImports` (the package's shared default extension) on the
   `pgmq-effectful` import, matching the style of `Keiro.PGMQ.Dlq`.

2. In `keiro-pgmq/keiro-pgmq.cabal`, add `Keiro.PGMQ.Metrics` to the library's
   `exposed-modules` list (alphabetically after `Keiro.PGMQ.Job`).

3. In `keiro-pgmq/src/Keiro/PGMQ.hs`, add `module Keiro.PGMQ.Metrics,` to the export list and
   `import Keiro.PGMQ.Metrics` to the import list, and mention the new metrics surface in the
   umbrella's module haddock (one sentence).

4. In `keiro-pgmq/test/Main.hs`, add two examples (details in Validation and Acceptance): one
   asserting `jobQueueMetrics` reports the right length and visible length after enqueuing three
   messages and reads back the DLQ as empty; one asserting `jobDlqMetrics.queueLength == 1` after
   a `Dead` outcome routes a message to the DLQ.

Acceptance: `cabal test keiro-pgmq-test` passes, including the two new metrics examples.

### Milestone M2 — Archive/retention API (`archiveDlq`)

Scope: add the archive verb to `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs`, complementing the existing
delete-only `purgeDlq`. At the end of this milestone, a caller can `import Keiro.PGMQ` and call
`archiveDlq job n` to move up to `n` rows out of the active DLQ into the DLQ's archive table
`pgmq.a_<dlq>` for audit retention, returning the count archived. Optionally a caller can archive
one specific DLQ row by id with `archiveDlqEntry job msgId`. Tests prove that the active DLQ
depth drops AND the archived rows are retained in `pgmq.a_<dlq>` (not deleted).

Concrete edits:

1. In `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs`, add `archiveDlq` and `archiveDlqEntry` to the module
   export list, and implement them after `purgeDlq`. `archiveDlq job n` mirrors the structure of
   the existing `redriveDlq job n`: it reads up to `n` DLQ rows in batches with
   `Pgmq.readMessage` (30-second visibility delay, the same as `readDlq`/`redriveDlq`), then for
   each read row calls `Pgmq.archiveMessage (MessageQuery { queueName = job.jobQueue.dlqName,
   messageId = message.messageId })`, counting the successful archives (`archiveMessage` returns
   `True` when a row was moved). It loops until `n` rows are archived or a read returns no
   messages. `archiveDlqEntry job msgId` is the single-message variant: it calls
   `Pgmq.archiveMessage` for one explicit `MessageId` and returns the `Bool` result. Because the
   read makes rows invisible for 30 seconds, `archiveDlq` archives the rows it just read (it
   holds them via the read's visibility lock until it archives them), which is the same
   read-then-act pattern `redriveDlq` uses.

2. Extend the module haddock of `Keiro.PGMQ.Dlq` to document the retention model: PGMQ never
   expires rows; `archiveDlq` retains dead letters in `pgmq.a_<dlq>` for audit (preserving
   `enqueued_at`/`read_ct` and stamping `archived_at`), while `purgeDlq` deletes permanently; a
   retention policy is "archive-then-purge" or "alert on depth via `jobDlqMetrics`".

3. In `keiro-pgmq/test/Main.hs`, add the archive-retention example (details in Validation and
   Acceptance): enqueue one message, route it to the DLQ with a `Dead` outcome, run `archiveDlq
   job 10`, assert it returns `1`, assert the active DLQ length (`jobDlqMetrics` /
   `queueLen job.jobQueue.dlqName`) is `0`, and — to prove retention rather than deletion — run a
   raw `hasql` session counting `SELECT count(*) FROM pgmq.a_<dlqPhysicalName>` and assert it is
   `1`.

Acceptance: `cabal test keiro-pgmq-test` passes, including the archive-retention example which
proves both that the active DLQ drained and that the row survives in the archive table.

### Milestone M3 (optional) — Retention documentation + end-to-end scenario test

Scope: a documentation pass plus one end-to-end scenario test that exercises the full retention
lifecycle: enqueue → dead-letter → `archiveDlq` (retain) → `purgeDlq` (clear active table) and
assert the archive table is still populated after the purge, demonstrating that archived rows
survive a purge. This milestone is purely additive; if time is short it can be deferred without
affecting M1/M2's acceptance.

Acceptance: `cabal test keiro-pgmq-test` passes, including the lifecycle scenario example.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless stated
otherwise.

1. Create the metrics module. Write `keiro-pgmq/src/Keiro/PGMQ/Metrics.hs` (full source sketch
   in Interfaces and Dependencies).

2. Wire the module into Cabal. Edit `keiro-pgmq/keiro-pgmq.cabal`, `exposed-modules`:

   ```diff
   diff --git a/keiro-pgmq/keiro-pgmq.cabal b/keiro-pgmq/keiro-pgmq.cabal
   --- a/keiro-pgmq/keiro-pgmq.cabal
   +++ b/keiro-pgmq/keiro-pgmq.cabal
   @@ exposed-modules:
        Keiro.PGMQ
        Keiro.PGMQ.Codec
        Keiro.PGMQ.Dlq
        Keiro.PGMQ.Job
   +    Keiro.PGMQ.Metrics
        Keiro.PGMQ.Runtime
   ```

3. Re-export from the umbrella. Edit `keiro-pgmq/src/Keiro/PGMQ.hs`:

   ```diff
   diff --git a/keiro-pgmq/src/Keiro/PGMQ.hs b/keiro-pgmq/src/Keiro/PGMQ.hs
   --- a/keiro-pgmq/src/Keiro/PGMQ.hs
   +++ b/keiro-pgmq/src/Keiro/PGMQ.hs
   @@ module Keiro.PGMQ (
        module Keiro.PGMQ.Runtime,
        module Keiro.PGMQ.Codec,
        module Keiro.PGMQ.Job,
        module Keiro.PGMQ.Dlq,
   +    module Keiro.PGMQ.Metrics,
    ) where

    import Keiro.PGMQ.Codec
    import Keiro.PGMQ.Dlq
    import Keiro.PGMQ.Job
   +import Keiro.PGMQ.Metrics
    import Keiro.PGMQ.Runtime
   ```

4. Compile the library before touching tests, to catch type errors early:

   ```bash
   cabal build keiro-pgmq
   ```

   Expected: it builds. A typical first-attempt failure is an ambiguous `QueueMetrics` field
   selector if both `Keiro.PGMQ.Metrics` and `Pgmq.Effectful` re-export it into the same scope;
   the package already sets `DuplicateRecordFields` and `OverloadedRecordDot`, so prefer
   `metrics.queueLength` dot-access in code rather than the bare `queueLength` selector.

5. Add the archive verb. Edit `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs` per M2 (full sketch in
   Interfaces and Dependencies). `archiveMessage` is already exported from the `Pgmq.Effectful`
   umbrella that `Keiro.PGMQ.Dlq` already imports — confirm by checking the existing import list
   names `MessageQuery (..)` and `Pgmq` (it does); add `archiveMessage` to the qualified-or-named
   imports as needed (the module already imports `Pgmq.Effectful qualified as Pgmq`, so
   `Pgmq.archiveMessage` works with no import-list change).

6. Add tests. Edit `keiro-pgmq/test/Main.hs` to add the metrics and archive examples (see
   Validation and Acceptance for the exact example bodies). The archive-retention assertion needs
   a raw archive-table count; add a small helper that runs a `hasql` session against a fresh
   `Pool` built from the example's `connStr` (the suite already imports `Hasql.Pool`,
   `Hasql.Pool.Config`, and `Hasql.Connection.Settings`; you will additionally import
   `Hasql.Session`, `Hasql.Statement`, and `Hasql.Decoders`/`Hasql.Encoders` — add these to the
   test stanza's `build-depends` only if `hasql` is not already a test dependency; it is, as
   `hasql >=1.10`).

7. Run the suite:

   ```bash
   cabal test keiro-pgmq-test
   ```

   Expected tail of the transcript (example names will match those you add; counts illustrative):

   ```text
   Keiro.PGMQ
     ...
     jobQueueMetrics reports main-queue depth after enqueue [✔]
     jobDlqMetrics reports DLQ depth after a Dead outcome [✔]
     archiveDlq retains dead-lettered rows in the archive table [✔]

   Finished in 12.3456 seconds
   34 examples, 0 failures
   ```

8. Update this plan: tick the Progress checklist, append any Surprises, fill Outcomes for the
   completed milestones, and flip the MasterPlan registry row for EP-4 to In Progress/Complete in
   `docs/masterplans/10-keiro-pgmq-queue-feature-expansion-fifo-ordering-headers-provisioning-observability.md`.


## Validation and Acceptance

Acceptance is phrased as observable behavior verified by the `keiro-pgmq-test` suite. Run from
`/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
cabal test keiro-pgmq-test
```

The new examples and their asserted behavior:

### M1 — metrics examples

Example "jobQueueMetrics reports main-queue depth after enqueue": create a job
`mkJob "keiro_pgmq_test.metrics_depth"`, `ensureJobQueue`, `enqueue` three `Ping` payloads, then
fetch `jobQueueMetrics job`. Assert `metrics.queueLength == 3` (three rows on the table) and
`metrics.queueVisibleLength == 3` (all immediately readable, none in flight). Also fetch
`jobDlqMetrics job` and assert its `queueLength == 0` (nothing dead-lettered yet). This proves the
function returns real, per-`Job` metrics for both the main queue and the DLQ without the caller
deriving any queue name.

Example "jobDlqMetrics reports DLQ depth after a Dead outcome": create a job
`mkJob "keiro_pgmq_test.metrics_dlq"`, `ensureJobQueue`, `enqueue` one payload, run
`runJobOnce 1 job (\_ -> pure (Dead "bad"))` (which dead-letters the message), then assert
`jobQueueMetrics job` has `queueLength == 0` and `jobDlqMetrics job` has `queueLength == 1`. This
proves `jobDlqMetrics` observes the DLQ depth the `Keiro.PGMQ.Dlq` haddock tells operators to
alert on.

### M2 — archive-retention example

Example "archiveDlq retains dead-lettered rows in the archive table": create a job
`mkJob "keiro_pgmq_test.dlq_archive"`, `ensureJobQueue`, `enqueue` one payload, dead-letter it
with `runJobOnce 1 job (\_ -> pure (Dead "bad"))`, then run `archiveDlq job 10`. Assert:

- `archiveDlq` returns `1` (one row archived).
- The active DLQ length is `0` afterward — assert via `jobDlqMetrics job` (`queueLength == 0`) or
  the existing `queueLen job.jobQueue.dlqName`.
- The row was retained, not deleted — run a raw `hasql` session counting the archive table and
  assert it returns `1`. The archive table name is `pgmq.a_<dlqPhysicalName>` where
  `dlqPhysicalName = queueNameToText job.jobQueue.dlqName` (the helper `queueNameToText` is
  already imported in the test). The count session is, schematically:

  ```haskell
  archiveCount :: Text -> Text -> IO Int64
  archiveCount connStr dlqPhysical =
      withPool connStr $ \pool -> do
          let sql = "SELECT count(*) FROM pgmq.a_" <> dlqPhysical
              session =
                  Session.statement () $
                      Statement.Statement
                          (Text.encodeUtf8 sql)
                          Encoders.noParams
                          (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
                          True
          result <- Pool.use pool session
          either (\e -> fail ("archive count failed: " <> show e)) pure result
  ```

  Because the test owns the queue name and it is sanitized to `[a-z0-9_]` by `queueRef`, string
  interpolation of `dlqPhysical` into the table identifier is safe here (it cannot contain SQL
  metacharacters). This count is what distinguishes *retention* from *deletion*: a `purgeDlq`
  would leave this count at `0`; `archiveDlq` leaves it at `1`.

This example is the load-bearing proof of EP-4's archival deliverable: it shows the active DLQ
drained *and* the message preserved in `pgmq.a_<dlq>`.

### M3 (optional) — lifecycle scenario

Example "archived DLQ rows survive a purge": enqueue and dead-letter a message, run
`archiveDlq job 10` (assert returns `1`, active DLQ `0`), then run `purgeDlq job` (clears the
active DLQ table only), then assert the archive count for `pgmq.a_<dlq>` is still `1`. This proves
`purgeDlq` does not touch the archive and that archived rows are durable across a purge.

Interpreting results: each example prints `[✔]` on success and `[✘]` with the failing expectation
on failure (Hspec). A non-zero exit code from `cabal test keiro-pgmq-test` means at least one
example failed; read the printed expectation to see which assertion broke.


## Idempotence and Recovery

All edits are additive and safe to repeat. Re-running `cabal build keiro-pgmq` or
`cabal test keiro-pgmq-test` has no side effects beyond compilation and test execution against
ephemeral, per-example databases that are created fresh and discarded (the suite uses
`withFreshDatabase`, so no test state persists between runs).

The new runtime functions are safe to call repeatedly:

- `jobQueueMetrics`, `jobDlqMetrics`, `queueDepth`, and `allJobMetrics` are read-only (they call
  PGMQ's `metrics()`/`metrics_all()`); calling them any number of times changes nothing.
- `archiveDlq job n` is naturally bounded: it archives at most `n` rows and stops when the DLQ is
  empty. Running it twice simply archives the next batch (or no-ops when the DLQ is empty).
  Archiving is at-most-once per row per call because the 30-second read visibility lock prevents a
  concurrent `archiveDlq` from re-reading the same in-flight rows; a crash *after* reading but
  *before* archiving leaves the rows in the active DLQ (they become visible again when the lock
  expires) and a re-run archives them — no row is lost or double-archived (PGMQ's `archive`
  `DELETE`s from `q_<dlq>` before `INSERT`ing into `a_<dlq>`, so a second archive of an
  already-archived row finds nothing to move and returns `False`).

If a milestone's tests fail, the recovery path is to revert only the failing file's last edit
(the milestones are independent: M1 touches `Metrics.hs`, the cabal file, the umbrella, and the
two metrics examples; M2 touches `Dlq.hs` and the archive example; M3 adds one scenario example).
No migration or destructive operation is involved, so there is no backup to take.


## Interfaces and Dependencies

This section gives the exact final public signatures with full module paths, the new
exposed-module name, and the umbrella re-export edit.

### New module `Keiro.PGMQ.Metrics`

New exposed-module name: `Keiro.PGMQ.Metrics`, file `keiro-pgmq/src/Keiro/PGMQ/Metrics.hs`. It
re-exports the `QueueMetrics (..)` type (with field accessors) from `pgmq-effectful` and defines:

```haskell
-- | The metrics for a job's MAIN queue (depth, visible depth, oldest/newest age, throughput).
jobQueueMetrics :: (Pgmq :> es) => Job p -> Eff es QueueMetrics

-- | The metrics for a job's DEAD-LETTER queue. Use its 'queueLength' for depth alerting.
jobDlqMetrics :: (Pgmq :> es) => Job p -> Eff es QueueMetrics

-- | The main queue's immediately-readable depth (PGMQ 'queueVisibleLength'): "work waiting".
queueDepth :: (Pgmq :> es) => Job p -> Eff es Int64

-- | Every queue's metrics (passthrough over 'Pgmq.Effectful.allQueueMetrics'); not Job-keyed.
allJobMetrics :: (Pgmq :> es) => Eff es [QueueMetrics]
```

Full source sketch for `keiro-pgmq/src/Keiro/PGMQ/Metrics.hs` (the implementing agent should
mirror the file-header pragma/haddock style of `Keiro.PGMQ.Dlq`):

```haskell
{-# LANGUAGE DataKinds #-}

{- | Typed, 'Job'-keyed queue metrics for @keiro-pgmq@.

PGMQ stores each queue as a table @pgmq.q_<name>@; its @metrics()@ function reports
depth and message age. These helpers fetch that 'QueueMetrics' for a job's MAIN
queue and its DEAD-LETTER queue without the caller deriving any physical name.

Use 'jobDlqMetrics' (its 'queueLength') for the depth alerting that
'Keiro.PGMQ.Dlq' recommends; pair it with 'Keiro.PGMQ.Dlq.archiveDlq' /
'Keiro.PGMQ.Dlq.purgeDlq' for retention.
-}
module Keiro.PGMQ.Metrics (
    QueueMetrics (..),
    jobQueueMetrics,
    jobDlqMetrics,
    queueDepth,
    allJobMetrics,
) where

import Keiro.PGMQ.Job (Job (..))
import Keiro.PGMQ.Runtime (QueueRef (..))
import "base" Data.Int (Int64)
import "effectful-core" Effectful (Eff, (:>))
import "pgmq-effectful" Pgmq.Effectful (Pgmq, QueueMetrics (..))
import "pgmq-effectful" Pgmq.Effectful qualified as Pgmq

jobQueueMetrics :: (Pgmq :> es) => Job p -> Eff es QueueMetrics
jobQueueMetrics job = Pgmq.queueMetrics job.jobQueue.physicalName

jobDlqMetrics :: (Pgmq :> es) => Job p -> Eff es QueueMetrics
jobDlqMetrics job = Pgmq.queueMetrics job.jobQueue.dlqName

queueDepth :: (Pgmq :> es) => Job p -> Eff es Int64
queueDepth job = do
    metrics <- jobQueueMetrics job
    pure metrics.queueVisibleLength

allJobMetrics :: (Pgmq :> es) => Eff es [QueueMetrics]
allJobMetrics = Pgmq.allQueueMetrics
```

Note the constraint is `(Pgmq :> es)` only — `queueMetrics`/`allQueueMetrics` do not require
`IOE`, unlike the producer functions. (`Keiro.PGMQ.Job`'s `enqueue` carries a redundant
`IOE :> es` as a deliberate published-contract choice; the metrics functions are read-only and
do not need it, so they omit it.)

### Additions to `Keiro.PGMQ.Dlq`

File `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs`. Add to the module export list and define:

```haskell
{- | Archive (retain) up to @n@ DLQ rows: move each out of the active DLQ table
@pgmq.q_<dlq>@ into the archive table @pgmq.a_<dlq>@, preserving @enqueued_at@ /
@read_ct@ and stamping @archived_at@. Returns the number archived. This is the
audit-retention counterpart to the delete-only 'purgeDlq'. At-most-once per row
per call; a crash before archiving leaves the row in the active DLQ for a re-run.
-}
archiveDlq :: (Pgmq :> es, IOE :> es) => Job p -> Int -> Eff es Int

-- | Archive one specific DLQ row by message id. 'True' if a row was moved.
archiveDlqEntry :: (Pgmq :> es, IOE :> es) => Job p -> MessageId -> Eff es Bool
```

Implementation sketch (place after `purgeDlq`; `Pgmq`, `MessageQuery (..)`, `ReadMessage (..)`,
`Message (..)`, and `MessageId` are already imported by the module, and `archiveMessage` is
reachable as `Pgmq.archiveMessage`):

```haskell
archiveDlq :: (Pgmq :> es, IOE :> es) => Job p -> Int -> Eff es Int
archiveDlq job n
    | n <= 0 = pure 0
    | otherwise = loop 0
  where
    loop archived
        | archived >= n = pure archived
        | otherwise = do
            messages <-
                Pgmq.readMessage
                    ReadMessage
                        { queueName = job.jobQueue.dlqName
                        , delay = 30
                        , batchSize = Just (fromIntegral (min 100 (n - archived)))
                        , conditional = Nothing
                        }
            if null messages
                then pure archived
                else do
                    archivedInBatch <- foldM archiveOne 0 messages
                    if archivedInBatch == 0
                        then pure archived
                        else loop (archived + archivedInBatch)

    archiveOne count message = do
        moved <- archiveDlqEntry job message.messageId
        pure (if moved then count + 1 else count)

archiveDlqEntry :: (Pgmq :> es, IOE :> es) => Job p -> MessageId -> Eff es Bool
archiveDlqEntry job msgId =
    Pgmq.archiveMessage
        MessageQuery
            { queueName = job.jobQueue.dlqName
            , messageId = msgId
            }
```

The export-list edit adds `archiveDlq,` and `archiveDlqEntry,` to the existing
`module Keiro.PGMQ.Dlq ( DlqEntry (..), readDlq, redriveDlq, purgeDlq )` block. `MessageId` is
already a transitively-available type (the module imports `MessageId` from `Pgmq.Effectful`),
so `archiveDlqEntry`'s signature needs no new import. `foldM` is already imported from
`Control.Monad`.

### Umbrella re-export edit

File `keiro-pgmq/src/Keiro/PGMQ.hs`. Add `module Keiro.PGMQ.Metrics,` to the export list and
`import Keiro.PGMQ.Metrics` to the import list (diff shown in Concrete Steps step 3). No umbrella
edit is needed for the `Keiro.PGMQ.Dlq` additions, because the umbrella already re-exports the
whole `Keiro.PGMQ.Dlq` module — adding functions to that module's export list is enough.

### Cabal edit

File `keiro-pgmq/keiro-pgmq.cabal`. Add `Keiro.PGMQ.Metrics` to the library `exposed-modules`
(diff in Concrete Steps step 2). No new `build-depends` are required: `pgmq-effectful`,
`effectful-core`, `base`, and `time` are already library dependencies, and `hasql` is already a
test dependency (`hasql >=1.10`) so the archive-count session in the test needs no new dependency
either. (`time` is already present for `UTCTime`, which `QueueMetrics` carries via `scrapeTime`.)

### Library and dependency summary

- `pgmq-effectful` (`Pgmq.Effectful` umbrella) — supplies `queueMetrics`, `allQueueMetrics`,
  `archiveMessage`, `readMessage`, the `Pgmq` effect, and the `QueueMetrics`, `MessageQuery`,
  `ReadMessage`, `Message`, `MessageId` types. All used through the umbrella module (verified
  present there).
- `Keiro.PGMQ.Job` — supplies the frozen `Job (..)` record (read-only; Integration Point 4
  forbids changing its fields).
- `Keiro.PGMQ.Runtime` — supplies the frozen `QueueRef (..)` record (`physicalName`, `dlqName`).
- `effectful-core`, `base`, `time`, `hasql` — already-present dependencies; no version bumps.

### Relationship to sibling plans

This plan (EP-4) has no hard dependency on EP-1
(`docs/plans/75-add-message-headers-trace-propagation-and-batch-enqueue-to-keiro-pgmq-producers.md`),
EP-2
(`docs/plans/76-add-partitioned-and-unlogged-queue-provisioning-with-fifo-indexes-to-keiro-pgmq.md`),
or EP-3
(`docs/plans/77-add-fifo-ordered-delivery-via-message-groups-to-keiro-pgmq.md`). It has a SOFT
relationship to EP-3: EP-3's operational documentation references this plan's metrics surface
(`jobQueueMetrics`/`jobDlqMetrics`) as the way to observe a FIFO queue's per-group backlog, but
EP-3 compiles and passes its tests without EP-4. Nothing here blocks or is blocked by those plans;
all four extend `keiro-pgmq` in place over disjoint code paths.
