---
id: 76
slug: add-partitioned-and-unlogged-queue-provisioning-with-fifo-indexes-to-keiro-pgmq
title: "Add partitioned and unlogged queue provisioning with FIFO indexes to keiro-pgmq"
kind: exec-plan
created_at: 2026-06-13T14:29:36Z
intention: "intention_01kv0jvq2qe70reyz4f6dpfxnk"
master_plan: "docs/masterplans/10-keiro-pgmq-queue-feature-expansion-fifo-ordering-headers-provisioning-observability.md"
---

# Add partitioned and unlogged queue provisioning with FIFO indexes to keiro-pgmq

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today a `keiro-pgmq` application can only create one kind of queue: a plain "standard"
PostgreSQL-backed queue. The function `ensureJobQueue` in
`keiro-pgmq/src/Keiro/PGMQ/Job.hs` calls `Pgmq.createQueue` for the main queue and (when the
retry policy enables a dead-letter queue) `Pgmq.createQueue` again for the DLQ. That is the
whole provisioning story. There is no way to ask for a faster crash-truncated queue, a
time/count-partitioned queue for high-volume retention, or the special database index that
makes ordered ("FIFO") reads perform.

After this change, a keiro application can provision the *right kind* of queue declaratively
and can create the FIFO index that strict-ordering reads need. Concretely, the application
will be able to write one of:

- `ensureJobQueueWith standardProvision job` — exactly today's behavior (standard main queue
  plus DLQ), unchanged.
- `ensureJobQueueWith unloggedProvision job` — the main queue is created as an *unlogged*
  table. "Unlogged" is a PostgreSQL table property: writes skip the write-ahead log, so they
  are faster, but the table is truncated to empty if the database server crashes. Suitable
  for transient, regenerable work.
- `ensureJobQueueWith (partitionedProvision pc) job` — the main queue is created as a
  *partitioned* queue. "Partitioned" means the queue's storage is split into many child
  tables by time or by message-id range, managed by the PostgreSQL extension `pg_partman`,
  so old data can be dropped cheaply in bulk. This path requires a `pg_partman`-enabled
  PostgreSQL server (see the partman caveat below).
- `ensureJobQueueWith (withFifoIndexProvision standardProvision) job`, or the standalone
  `ensureFifoIndex job` — create PGMQ's *FIFO index*. This is a GIN (Generalized Inverted
  Index) database index on the queue table's `headers` JSONB column. PGMQ's grouped-read
  functions (`read_grouped`/`read_grouped_rr`) filter messages by a value stored in that
  `headers` column (the reserved `x-pgmq-group` key), and the GIN index is what lets that
  filter run as an index lookup instead of a full sequential table scan.

You can see each capability working through the `keiro-pgmq-test` suite. After this plan, the
suite contains tests that create an unlogged queue and assert (via PGMQ's own
`listQueues`, whose `Queue` record carries an `isUnlogged` boolean) that the queue really is
unlogged; that create the FIFO index twice and assert it is idempotent and the queue still
accepts work; and that assert the partitioned-queue provisioning constructs the correct
request (because the test database has no `pg_partman`, a *live* partitioned-queue creation
is documented as an operator step rather than asserted in CI). Run the whole suite from the
repository root `/Users/shinzui/Keikaku/bokuno/keiro` with:

```bash
cabal test keiro-pgmq-test
```


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Add `pgmq-config >=0.3 && <0.4` to the `library` `build-depends` in
  `keiro-pgmq/keiro-pgmq.cabal`. (2026-06-13)
- [x] M1: Define `QueueProvision`, `QueueKind`, the smart constructors
  (`standardProvision`, `unloggedProvision`, `partitionedProvision`,
  `withFifoIndexProvision`) and `ensureJobQueueWith` in
  `keiro-pgmq/src/Keiro/PGMQ/Job.hs`; re-express `ensureJobQueue` through it. (2026-06-13)
- [x] M1: Export the new surface from `Keiro.PGMQ.Job`'s module export list. (2026-06-13)
- [x] M1: Test — `ensureJobQueueWith unloggedProvision` creates a queue `listQueues` marks
  `isUnlogged = True`; standard path still marks `isUnlogged = False`. `cabal test
  keiro-pgmq-test` passes. (2026-06-13)
- [x] M2: Implement the partitioned path (map `partitionedProvision` to a
  `PartitionedQueue PartitionConfig` `QueueConfig`). Handle the `pg_partman` test caveat
  (pure assertion on the constructed `QueueConfig` plus a `pendingWith` live test). (2026-06-13)
- [x] M2: Test — partitioned provisioning builds the expected `QueueConfig` (unit/pure
  assertion); a live partitioned-creation test is `pendingWith` an operator-provided
  partman-enabled Postgres. `cabal test keiro-pgmq-test` passes. (2026-06-13)
- [x] M3: Implement `ensureFifoIndex job` (standalone, routed through `pgmq-config`'s
  reconciler) and the `withFifoIndexProvision` modifier; export both. (2026-06-13)
- [x] M3: Test — `ensureFifoIndex` run twice is idempotent and the queue still accepts a
  grouped/normal read afterward. `cabal test keiro-pgmq-test` passes. (2026-06-13)
- [x] Update Surprises, Decision Log, Outcomes, and the MasterPlan EP-2 Progress rows. (2026-06-13)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-13 — **`pgmq-config`'s `QueueType`/`PartitionConfig` derive `Show` (and
  `PartitionConfig` derives `Generic`) but not `Eq`** (verified in
  `pgmq-config/src/Pgmq/Config/Types.hs`: `QueueType` has `deriving stock (Show)`,
  `PartitionConfig` has `deriving stock (Generic, Show)`). The M2 pure test therefore
  pattern-matches on `mainCfg.queueType` and asserts the `PartitionConfig` *fields*
  (`partitionInterval`/`retentionInterval` via record-dot, both `Text` so `==`-comparable)
  rather than comparing the whole `QueueType` with `==`. The plan anticipated this.
- 2026-06-13 — **`pgmq-config-0.3.0.0` resolved cleanly from the package repository with no
  `cabal.project` edit.** `cabal build keiro-pgmq` downloaded and built it as a normal
  dependency, exactly like the sibling `pgmq-core`/`pgmq-effectful`/`pgmq-migration`
  packages; no `source-repository-package` stanza was needed.
- 2026-06-13 — **Full suite green: 42 examples, 0 failures, 2 pending.** The two pending are
  the pre-existing crash-safety test (blocked on `docs/plans/67-…`) and this plan's
  intentional `ensureJobQueueWith partitioned creates a partitioned queue (live)`
  `pendingWith` (no `pg_partman` in the ephemeral test DB). The `ensureFifoIndex`-twice test
  confirms idempotence and a working post-index round-trip in one example.


## Decision Log

Record every decision made while working on the plan.

- Decision: Use the `pgmq-config` package's declarative reconciler (`Pgmq.Config.Effectful.ensureQueuesEff`)
  as the PRIMARY implementation path for all queue creation in this plan, not a fallback.
  Rationale: The repository owner confirmed adding `pgmq-config` as a dependency. Its
  `QueueConfig`/`QueueType` model already expresses exactly the three queue kinds this plan
  needs (standard, unlogged, partitioned) plus the FIFO-index flag, and its reconciler is
  additive and idempotent — it lists existing queues first and only creates what is missing
  (read `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-config/src/Pgmq/Config/Effectful.hs`,
  `reconcileQueueEff`). Reusing it avoids hand-rolling create-if-missing logic and keeps
  keiro-pgmq's provisioning semantics identical to the wider pgmq-hs ecosystem.
  Date: 2026-06-13

- Decision: Pass the provisioning choice as an explicit *parameter* (`QueueProvision`) to a
  new `ensureJobQueueWith` function, NOT as a new field on `Job` or `QueueRef`.
  Rationale: MasterPlan Integration Point 4 freezes the `Job` and `QueueRef` record shapes;
  all four child plans of MasterPlan #10 read those records and a strict-field change is a
  cross-cutting breaking change touching every plan and the keiro-dsl fixtures. Provisioning
  is a one-time lifecycle/admin decision made at startup, not a per-`Job` property carried at
  the value level, so a parameter is the natural home. The existing `ensureJobQueue` is kept
  and re-expressed as `ensureJobQueueWith standardProvision`, so no current call site changes.
  Date: 2026-06-13

- Decision: For partitioned queues, do not attempt a live integration test in CI; instead
  unit-assert that the provisioning code constructs the correct partitioned `QueueConfig`,
  and mark the live-creation test `pendingWith` an operator note.
  Rationale: PGMQ's `create_partitioned` delegates to the PostgreSQL extension `pg_partman`,
  which requires `shared_preload_libraries = 'pg_partman_bgw'` plus configuration and a
  server restart (read `/Users/shinzui/Keikaku/hub/postgresql/pgmq-project/pgmq/docs/partitioned-queues.md`).
  The test suite provisions its database with `pgmq-migration`'s `Pgmq.Migration.migrate`
  against an ephemeral PostgreSQL; that migration installs only the PGMQ schema and never
  `CREATE EXTENSION pg_partman` (verified: grepping `pgmq-migration/src` for `partman`/`CREATE
  EXTENSION` finds nothing; partman appears only in the vendored Docker image scripts). So a
  live `create_partitioned` call would fail in CI. We assert the *intent* (the `QueueConfig`
  we hand to the reconciler) rather than claim a passing integration test we cannot honestly
  run. Captured in Validation and Acceptance and Surprises.
  Date: 2026-06-13

- Decision: Expose a standalone `ensureFifoIndex :: (Pgmq :> es) => Job p -> Eff es ()`
  helper in addition to the `withFifoIndexProvision` reconciler path.
  Rationale: MasterPlan Integration Point 3 makes the FIFO index the single artifact that
  EP-3 (FIFO ordered delivery, `docs/plans/77-add-fifo-ordered-delivery-via-message-groups-to-keiro-pgmq.md`)
  must invoke when a job is ordered. EP-3 needs to add the index for an *already-provisioned*
  job's main queue without re-running the whole provisioning decision, so a one-argument
  helper keyed on `Job` is the clean seam. We route it through `pgmq-config`'s reconciler
  (a single-element `[QueueConfig]` with `fifoIndex = True`) so keiro-pgmq does not import the
  hidden raw effect op `createFifoIndex` (which is exported from `Pgmq.Effectful.Effect` but
  deliberately omitted from the `Pgmq.Effectful` umbrella). EP-2 owns this function; EP-3
  consumes it.
  Date: 2026-06-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.

- 2026-06-13 — **Complete.** All three milestones landed in one pass, no deviations from the
  Plan of Work. `keiro-pgmq` now exposes `QueueKind`, `PartitionSpec`, `QueueProvision`, the
  smart constructors (`standardProvision`/`unloggedProvision`/`partitionedProvision`/
  `withFifoIndexProvision`), the pure `queueProvisionConfigs`, `ensureJobQueueWith`, and the
  standalone `ensureFifoIndex` — all from `Keiro.PGMQ.Job` and therefore through the
  `Keiro.PGMQ` umbrella with no umbrella edit. `ensureJobQueue` is re-expressed as
  `ensureJobQueueWith standardProvision`, so every existing call site is behavior-identical
  (the `ensureJobQueue (standard) creates a logged queue` test pins `isUnlogged = False`).
- Gap (known, documented): no live partitioned-queue test runs in CI because the ephemeral
  test PostgreSQL has no `pg_partman` (see the pg_partman caveat). The partitioned path is
  verified by the pure `queueProvisionConfigs` assertion; the live test is `pendingWith` an
  operator note.
- Hand-off to EP-3: `ensureFifoIndex :: (Pgmq :> es) => Job p -> Eff es ()` is the artifact
  EP-3 (`docs/plans/77-…`) invokes for ordered jobs — Integration Point 3 is satisfied. EP-3
  no longer needs the reconcile-note fallback to import the raw `createFifoIndex`; it can call
  `ensureFifoIndex job` (or provision with `withFifoIndexProvision`) directly.


## Context and Orientation

This section assumes no prior knowledge of the repository. Read it before editing anything.

`keiro-pgmq` (directory `keiro-pgmq/` at the repository root
`/Users/shinzui/Keikaku/bokuno/keiro`) is a typed background-job queue. An application
declares a `Job p` value — a queue, a payload codec, a retry/dead-letter policy — and writes a
plain handler `p -> Eff es JobOutcome`. The package runs that handler against **PGMQ**, the
PostgreSQL-native message queue, through **shibuya**, a Broadway-style worker framework. The
package is layered:

- `keiro-pgmq/src/Keiro/PGMQ/Runtime.hs` (Layer 1) owns queue-name derivation. The type
  `QueueRef` has three fields — `logicalName :: Text` (caller-facing), `physicalName ::
  QueueName` (the PGMQ-legal main-queue name), and `dlqName :: QueueName` (the derived
  dead-letter-queue name). `QueueName` is a validated newtype over `Text` from the package
  `pgmq-core`, module `Pgmq.Types`.
- `keiro-pgmq/src/Keiro/PGMQ/Job.hs` (Layer 2) owns the `Job` ergonomics. The record is:

  ```haskell
  data Job p = Job
      { jobName   :: !Text
      , jobQueue  :: !QueueRef
      , jobCodec  :: !(JobCodec p)
      , jobPolicy :: !RetryPolicy
      }
  ```

  `RetryPolicy` has a `useDeadLetter :: Bool` field that decides whether a DLQ is created and
  routed to. The current queue-creation function is:

  ```haskell
  ensureJobQueue :: (Pgmq :> es) => Job p -> Eff es ()
  ensureJobQueue job = do
      Pgmq.createQueue job.jobQueue.physicalName
      when job.jobPolicy.useDeadLetter $
          Pgmq.createQueue job.jobQueue.dlqName
  ```

  `Pgmq.createQueue` creates a *standard* queue and is idempotent in PGMQ (calling it twice is
  safe), which is why `ensureJobQueue` is called at every worker startup.

- `keiro-pgmq/src/Keiro/PGMQ.hs` is the umbrella module: it re-exports
  `Keiro.PGMQ.Runtime`, `Keiro.PGMQ.Codec`, `Keiro.PGMQ.Job`, and `Keiro.PGMQ.Dlq` whole, so
  consumers write `import Keiro.PGMQ` and get everything. Because it re-exports the *whole*
  `Keiro.PGMQ.Job` module, any new public name we add to `Keiro.PGMQ.Job`'s export list is
  automatically available through the umbrella with no umbrella edit.

Terms of art used in this plan, defined once:

- **PGMQ** ("Postgres Message Queue"): a PostgreSQL extension that stores a message queue in
  ordinary PostgreSQL tables and exposes SQL functions (`pgmq.create`, `pgmq.send`,
  `pgmq.read`, …) to operate on it. In Haskell it is wrapped by the `pgmq-effectful` package
  as an `effectful` effect named `Pgmq`.
- **`effectful`**: a Haskell effect-system library. `Eff es a` is a computation in the effect
  list `es`; `(Pgmq :> es)` means "the `Pgmq` effect is available in `es`". You call PGMQ
  operations like `Pgmq.createQueue someName` inside an `Eff es` block.
- **Standard / unlogged / partitioned queue**: three PostgreSQL storage shapes for the queue
  table. *Standard* is a normal logged table. *Unlogged* skips the write-ahead log (faster
  writes, emptied on crash). *Partitioned* splits storage across child tables by time or
  message-id range and is managed by the `pg_partman` extension.
- **`pg_partman`**: a PostgreSQL extension that automates partition creation and retention.
  It must be loaded via `shared_preload_libraries` and configured in `postgresql.conf`, which
  requires a server restart. The keiro test database does not have it (see the partman caveat
  in Validation and Acceptance).
- **FIFO index**: a GIN (Generalized Inverted Index) database index on the queue table's
  `headers` JSONB column. PGMQ's grouped/ordered reads filter on a value in that column; the
  index turns that filter into an index lookup. "FIFO" = First-In-First-Out, i.e. strict
  delivery order within a message group. This plan only *creates the index*; the ordered-read
  semantics that use it are delivered by the sibling plan
  `docs/plans/77-add-fifo-ordered-delivery-via-message-groups-to-keiro-pgmq.md` (EP-3).
- **DLQ** (dead-letter queue): a secondary queue where messages that exhaust their retries
  are parked for inspection. keiro-pgmq derives its name as `QueueRef.dlqName`.

The dependency we add, **`pgmq-config`** (at
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-config`, version
`0.3.0.0`), is a small declarative reconciler over the `Pgmq` effect. Its key surface,
verified by reading its source:

- `Pgmq.Config.Types` (`pgmq-config/src/Pgmq/Config/Types.hs`):

  ```haskell
  data QueueConfig = QueueConfig
    { queueName     :: !QueueName
    , queueType     :: !QueueType
    , notifyInsert  :: !(Maybe NotifyConfig)
    , fifoIndex     :: !Bool
    , topicBindings :: ![TopicPattern]
    }

  data QueueType
    = StandardQueue
    | UnloggedQueue
    | PartitionedQueue !PartitionConfig

  data PartitionConfig = PartitionConfig
    { partitionInterval :: !Text
    , retentionInterval :: !Text
    }

  -- smart constructors / modifiers
  standardQueue    :: QueueName -> QueueConfig          -- all extras off, StandardQueue
  unloggedQueue    :: QueueName -> QueueConfig          -- StandardQueue → UnloggedQueue
  partitionedQueue :: QueueName -> PartitionConfig -> QueueConfig
  withFifoIndex    :: QueueConfig -> QueueConfig        -- sets fifoIndex = True
  withNotifyInsert :: Maybe Int32 -> QueueConfig -> QueueConfig
  withTopicBinding :: TopicPattern -> QueueConfig -> QueueConfig

  data ReconcileAction
    = CreatedQueue !QueueName !QueueType
    | EnabledNotify !QueueName !(Maybe Int32)
    | CreatedFifoIndex !QueueName
    | BoundTopic !QueueName !TopicPattern
    | SkippedQueue !QueueName
    | SkippedNotify !QueueName
    | SkippedFifoIndex !QueueName
    | SkippedTopicBinding !QueueName !TopicPattern
  ```

- `Pgmq.Config.Effectful` (`pgmq-config/src/Pgmq/Config/Effectful.hs`):

  ```haskell
  ensureQueuesEff       :: (Pgmq :> es) => [QueueConfig] -> Eff es ()
  ensureQueuesReportEff :: (Pgmq :> es) => [QueueConfig] -> Eff es [ReconcileAction]
  ```

  `ensureQueuesEff` lists existing queues, bindings, and notify-throttles once, then for each
  `QueueConfig` creates only what is missing. Crucially, the FIFO-index step is **always
  re-applied** when `fifoIndex = True`, because there is no way to query whether the index
  already exists; the underlying `createFifoIndex` SQL is itself idempotent (`CREATE INDEX IF
  NOT EXISTS`), so re-applying is safe. This is confirmed by the comment and code in
  `reconcileQueueEff`: the `fifoAction` branch has no "skip if exists" guard, unlike the queue
  and notify branches.

Two important facts about what is and is not re-exported, verified by reading
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-effectful/src/Pgmq/Effectful.hs`
and `…/Pgmq/Effectful/Effect.hs`:

- The `Pgmq.Effectful` umbrella *does* re-export `createUnloggedQueue`,
  `createPartitionedQueue`, `CreatePartitionedQueue (..)`, `listQueues`, `Queue (..)`, and
  `MessageHeaders (..)`.
- The `Pgmq.Effectful` umbrella *does NOT* re-export `createFifoIndex` (nor `readGrouped` and
  friends). The raw op is `createFifoIndex :: QueueName -> Pgmq m ()`, exported only from
  `Pgmq.Effectful.Effect`. If you ever need it directly, the import is
  `import "pgmq-effectful" Pgmq.Effectful.Effect (createFifoIndex)`. **This plan avoids that
  import entirely** by routing FIFO-index creation through `pgmq-config`'s `ensureQueuesEff`,
  which calls `createFifoIndex` internally. We document the direct import here only so EP-3
  knows it exists.

Finally, the test harness, `keiro-pgmq/test/Main.hs`, component `keiro-pgmq-test`. It uses
`keiro-test-support` (`Keiro.Test.Postgres`) to start one suite-level PostgreSQL server,
installs the PGMQ schema into a migrated *template* database via
`Postgres.withMigratedSuiteWith installPgmq`, and gives every example a fresh cloned database
via `around (Postgres.withFreshDatabase fixture)`. Each test receives the database connection
string as its argument and runs effectful PGMQ actions through `runDb connStr (act)`, which
threads the `Pgmq : Tracing : Error PgmqRuntimeError : IOE` stack against a fresh
`JobRuntime`. To verify queue properties, tests call `Pgmq.listQueues` and inspect the
returned `Queue` records, whose relevant fields are (from `pgmq-core` `Pgmq/Types.hs`):

```haskell
data Queue = Queue
  { name          :: !QueueName
  , createdAt     :: !UTCTime
  , isPartitioned :: !Bool
  , isUnlogged    :: !Bool
  }
```


## Plan of Work

This plan adds a small provisioning value type and a new provisioning function to
`keiro-pgmq/src/Keiro/PGMQ/Job.hs`, maps that value onto `pgmq-config`'s declarative
`QueueConfig` reconciler, and keeps the DLQ creation behavior intact. It is delivered in three
independently verifiable milestones, each ending with the same acceptance command run from
`/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
cabal test keiro-pgmq-test
```

The new public surface lives in `Keiro.PGMQ.Job` (so it flows through the `Keiro.PGMQ`
umbrella automatically). The shape we will add:

```haskell
-- The three queue storage shapes a job's main queue can take.
data QueueKind
    = StandardKind
    | UnloggedKind
    | PartitionedKind !PartitionSpec
    deriving stock (Eq, Show)

-- Partition interval + retention interval, both PostgreSQL/pg_partman duration or
-- integer strings (e.g. "daily" or "10000").
data PartitionSpec = PartitionSpec
    { partitionInterval :: !Text
    , retentionInterval :: !Text
    }
    deriving stock (Eq, Show)

-- The provisioning choice for a job's MAIN queue. The DLQ is always a standard queue.
data QueueProvision = QueueProvision
    { provisionKind :: !QueueKind
    , provisionFifoIndex :: !Bool
    }
    deriving stock (Eq, Show)

standardProvision        :: QueueProvision                       -- StandardKind, no fifo index
unloggedProvision        :: QueueProvision                       -- UnloggedKind, no fifo index
partitionedProvision     :: PartitionSpec -> QueueProvision      -- PartitionedKind p, no fifo index
withFifoIndexProvision   :: QueueProvision -> QueueProvision     -- sets provisionFifoIndex = True

ensureJobQueueWith :: (Pgmq :> es) => QueueProvision -> Job p -> Eff es ()
ensureFifoIndex    :: (Pgmq :> es) => Job p -> Eff es ()
```

We intentionally mirror `pgmq-config`'s names but keep keiro-pgmq's own types (a thin wrapper)
so the public API does not leak `pgmq-config` types into keiro consumers and so a future
swap of the reconciler does not change keiro's surface.

`ensureJobQueueWith` maps a `QueueProvision` to a list of `pgmq-config` `QueueConfig`s and
calls `Pgmq.Config.Effectful.ensureQueuesEff`:

- The main queue's `QueueConfig` is built from `provisionKind`
  (`standardQueue`/`unloggedQueue`/`partitionedQueue`) and gets `withFifoIndex` applied when
  `provisionFifoIndex` is `True`, using `job.jobQueue.physicalName`.
- When `job.jobPolicy.useDeadLetter` is `True`, a second `QueueConfig` is appended for
  `job.jobQueue.dlqName` built with `standardQueue` (the DLQ is always a plain standard queue,
  never unlogged/partitioned, and never gets a FIFO index). This preserves exactly the
  current DLQ behavior.

`ensureJobQueue` is re-expressed so that today's behavior is unchanged:

```haskell
ensureJobQueue :: (Pgmq :> es) => Job p -> Eff es ()
ensureJobQueue = ensureJobQueueWith standardProvision
```

Note the constraint change: the new code only needs `(Pgmq :> es)`, the same constraint the
old `ensureJobQueue` already had — `ensureQueuesEff` requires only `Pgmq`. No `IOE` is added.

`ensureFifoIndex job` is the standalone helper EP-3 consumes. It calls `ensureQueuesEff` with a
single `QueueConfig` for `job.jobQueue.physicalName` built as `withFifoIndex (standardQueue
physicalName)`. Because the reconciler lists existing queues first and skips creating a queue
that already exists, calling `ensureFifoIndex` on an already-provisioned queue does not
recreate the queue — it only (re-)creates the index, which is idempotent.

### Milestone M1 — dependency, provisioning surface, standard & unlogged paths

Scope: add `pgmq-config` to the cabal file; define `QueueKind`, `PartitionSpec`,
`QueueProvision`, the smart constructors, and `ensureJobQueueWith`; re-express
`ensureJobQueue`; export everything from `Keiro.PGMQ.Job`. Wire only the standard and unlogged
mappings end to end (partitioned is wired as the obvious `partitionedQueue` mapping but its
*live* behavior is exercised in M2). At the end of M1, an application can call
`ensureJobQueueWith unloggedProvision job` and get an unlogged main queue plus a standard DLQ.

Commands (from `/Users/shinzui/Keikaku/bokuno/keiro`):

```bash
cabal build keiro-pgmq
cabal test keiro-pgmq-test
```

Acceptance: a new test "ensureJobQueueWith unlogged creates a queue listQueues marks
isUnlogged=True" passes; a companion check confirms the standard path leaves `isUnlogged =
False`; all pre-existing tests still pass.

### Milestone M2 — partitioned path and the pg_partman caveat

Scope: finalize the partitioned mapping (`partitionedProvision spec` →
`partitionedQueue physicalName (PartitionConfig spec.partitionInterval spec.retentionInterval)`)
and handle the test-environment limitation honestly. Because the ephemeral test PostgreSQL has
no `pg_partman`, we do not create a partitioned queue live in CI. Instead M2 adds a *pure*
assertion that the provisioning code constructs the right request, and a `pendingWith` live
test documenting the operator prerequisite.

To make the pure assertion possible without a database, we expose a tiny pure helper that the
provisioning function and the test both use:

```haskell
-- Pure: map a QueueProvision + a Job to the list of pgmq-config QueueConfigs that
-- ensureJobQueueWith will reconcile. Exposed so tests can assert the request shape
-- without a database, and so the partitioned path is verifiable where a live partman
-- server is unavailable.
queueProvisionConfigs :: QueueProvision -> Job p -> [Pgmq.Config.Types.QueueConfig]
```

`ensureJobQueueWith provision job = ensureQueuesEff (queueProvisionConfigs provision job)`.
The M2 test inspects `queueProvisionConfigs (partitionedProvision (PartitionSpec "daily"
"7 days")) job` and asserts the head config has `queueType == PartitionedQueue (PartitionConfig
"daily" "7 days")` and that the queue name matches `job.jobQueue.physicalName`. (We pattern-
match on `QueueType`/`PartitionConfig` directly rather than comparing with `==` because
`pgmq-config`'s `QueueType`/`PartitionConfig` derive `Show` but not `Eq`; see Concrete Steps.)

Commands and acceptance: `cabal test keiro-pgmq-test` from the repository root; the new pure
partitioned-config test passes, and a `it "ensureJobQueueWith partitioned creates a
partitioned queue" $ \_ -> pendingWith "requires a pg_partman-enabled PostgreSQL; the keiro
test database installs only the PGMQ schema via pgmq-migration"` appears in the suite output
as pending.

### Milestone M3 — FIFO index provisioning (the artifact EP-3 consumes)

Scope: implement `withFifoIndexProvision` (already part of the M1 surface but now exercised)
and the standalone `ensureFifoIndex job`, both routed through `ensureQueuesEff`. Export
`ensureFifoIndex`. At the end of M3, EP-3 (`docs/plans/77-…`) can call `ensureFifoIndex job`
to create the GIN index on the main queue's `headers` column.

Commands and acceptance: `cabal test keiro-pgmq-test` from the repository root. A new test
"ensureFifoIndex run twice is idempotent and the queue still accepts reads" passes: it
provisions a standard queue, calls `ensureFifoIndex job` twice without error, then enqueues a
message and reads it back, proving the index creation neither failed on the second call nor
broke the queue.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless stated
otherwise.

### Step 1 — add the dependency (M1)

Edit `keiro-pgmq/keiro-pgmq.cabal`. In the `library` stanza's `build-depends` list, add a line
(keep the list alphabetically sorted, so it sits just before `pgmq-core`):

```cabal
    , pgmq-config           >=0.3  && <0.4
```

Confirm it resolves:

```bash
cabal build keiro-pgmq
```

Expected: the build proceeds (it will fail to *type-check* only once you start using the new
import in later steps; at this point it should still build because nothing imports it yet).

### Step 2 — define the provisioning surface (M1)

Edit `keiro-pgmq/src/Keiro/PGMQ/Job.hs`. Add imports near the other `pgmq` imports:

```haskell
import "pgmq-config" Pgmq.Config.Types qualified as Config
import "pgmq-config" Pgmq.Config.Effectful (ensureQueuesEff)
```

Add the types and smart constructors (placed after the `Job` declaration). Use the exact shapes
from Plan of Work. Then define the pure mapper and the two effectful functions:

```haskell
queueProvisionConfigs :: QueueProvision -> Job p -> [Config.QueueConfig]
queueProvisionConfigs provision job =
    mainConfig : dlqConfigs
  where
    mainBase =
        case provision.provisionKind of
            StandardKind         -> Config.standardQueue job.jobQueue.physicalName
            UnloggedKind         -> Config.unloggedQueue job.jobQueue.physicalName
            PartitionedKind spec ->
                Config.partitionedQueue
                    job.jobQueue.physicalName
                    Config.PartitionConfig
                        { Config.partitionInterval = spec.partitionInterval
                        , Config.retentionInterval = spec.retentionInterval
                        }
    mainConfig
        | provision.provisionFifoIndex = Config.withFifoIndex mainBase
        | otherwise                    = mainBase
    dlqConfigs
        | job.jobPolicy.useDeadLetter = [Config.standardQueue job.jobQueue.dlqName]
        | otherwise                   = []

ensureJobQueueWith :: (Pgmq :> es) => QueueProvision -> Job p -> Eff es ()
ensureJobQueueWith provision job =
    ensureQueuesEff (queueProvisionConfigs provision job)

ensureJobQueue :: (Pgmq :> es) => Job p -> Eff es ()
ensureJobQueue = ensureJobQueueWith standardProvision

ensureFifoIndex :: (Pgmq :> es) => Job p -> Eff es ()
ensureFifoIndex job =
    ensureQueuesEff
        [Config.withFifoIndex (Config.standardQueue job.jobQueue.physicalName)]
```

Remove the *old* body of `ensureJobQueue` (the two `Pgmq.createQueue` calls and its `when`
import use, if `when` is now unused elsewhere — check before deleting the import). Add the new
names to the module export list in the `Queue lifecycle` section:

```haskell
    -- * Queue lifecycle
    QueueKind (..),
    PartitionSpec (..),
    QueueProvision (..),
    standardProvision,
    unloggedProvision,
    partitionedProvision,
    withFifoIndexProvision,
    queueProvisionConfigs,
    ensureJobQueue,
    ensureJobQueueWith,
    ensureFifoIndex,
```

Build:

```bash
cabal build keiro-pgmq
```

Expected: clean compile. If GHC warns that `when` is now an unused import, remove `when` from
the `Control.Monad` import list (keep `foldM`/`void` which are still used).

### Step 3 — M1 test: unlogged vs standard (M1)

Edit `keiro-pgmq/test/Main.hs`. Add an import for `listQueues` and the `Queue` record if not
already in scope. The test file already imports `Pgmq.Effectful (… Pgmq …)` qualified as
`Pgmq`; `Pgmq.listQueues` and the `Queue` record fields are available through the umbrella, but
the `Queue` *type/fields* are accessed via record dot syntax on the values it returns, so no
extra import is needed beyond what `import Pgmq.Effectful qualified as Pgmq` already provides
for `listQueues`. Add a helper and two `it` blocks inside `spec`:

```haskell
    it "ensureJobQueueWith unlogged creates an unlogged queue" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.unlogged"
        unlogged <-
            runDb connStr $ do
                ensureJobQueueWith unloggedProvision job
                queues <- Pgmq.listQueues
                pure (queueIsUnlogged job.jobQueue.physicalName queues)
        unlogged `shouldBe` Just True

    it "ensureJobQueue (standard) creates a logged queue" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.standard_logged"
        unlogged <-
            runDb connStr $ do
                ensureJobQueue job
                queues <- Pgmq.listQueues
                pure (queueIsUnlogged job.jobQueue.physicalName queues)
        unlogged `shouldBe` Just False
```

Add the helper near the other test helpers (top-level, after `queueLen`):

```haskell
-- | Look up a queue by physical name in a listQueues result and report whether
-- it is unlogged. Nothing means the queue was not found.
queueIsUnlogged :: QueueName -> [Pgmq.Queue] -> Maybe Bool
queueIsUnlogged qn queues =
    fmap (.isUnlogged) (find (\q -> q.name == qn) queues)
```

Add `import Data.List (find)` to the test imports. The `Queue` type is referenced as
`Pgmq.Queue`; it is re-exported by `Pgmq.Effectful`, so the existing
`import Pgmq.Effectful qualified as Pgmq` covers it.

Run:

```bash
cabal test keiro-pgmq-test
```

Expected (excerpt):

```text
  ensureJobQueueWith unlogged creates an unlogged queue
  ensureJobQueue (standard) creates a logged queue
```

both reported as passing, alongside all pre-existing examples.

### Step 4 — M2 test: partitioned config shape + pending live test (M2)

The partitioned mapping is already implemented in `queueProvisionConfigs` (Step 2). Add a pure
test that asserts the constructed request, plus the pending live test. In
`keiro-pgmq/test/Main.hs`, inside `spec`:

```haskell
    it "ensureJobQueueWith partitioned builds a partitioned QueueConfig" $ \_connStr -> do
        let job = mkJob "keiro_pgmq_test.partitioned"
            spec = PartitionSpec{partitionInterval = "daily", retentionInterval = "7 days"}
        case queueProvisionConfigs (partitionedProvision spec) job of
            (mainCfg : _) ->
                case mainCfg.queueType of
                    Config.PartitionedQueue pc -> do
                        pc.partitionInterval `shouldBe` "daily"
                        pc.retentionInterval `shouldBe` "7 days"
                        mainCfg.queueName `shouldBe` job.jobQueue.physicalName
                    other ->
                        expectationFailure
                            ("expected PartitionedQueue, got " <> show other)
            [] -> expectationFailure "expected at least the main queue config"

    it "ensureJobQueueWith partitioned creates a partitioned queue (live)" $ \_connStr ->
        pendingWith
            "requires a pg_partman-enabled PostgreSQL; the keiro test database installs only \
            \the PGMQ schema via pgmq-migration, which does not load pg_partman"
```

Add to the test imports:

```haskell
import Pgmq.Config.Types qualified as Config
```

We pattern-match on `mainCfg.queueType` instead of `==` because `pgmq-config`'s `QueueType`
and `PartitionConfig` derive `Show` but not `Eq`. The `mainCfg.queueType` /
`mainCfg.queueName` field accesses use record-dot syntax against the `Config.QueueConfig`
value (`OverloadedRecordDot` is already on in this package's default extensions).

Run:

```bash
cabal test keiro-pgmq-test
```

Expected (excerpt):

```text
  ensureJobQueueWith partitioned builds a partitioned QueueConfig
  ensureJobQueueWith partitioned creates a partitioned queue (live)
    # PENDING: requires a pg_partman-enabled PostgreSQL; ...
```

### Step 5 — M3 test: FIFO index idempotence (M3)

`ensureFifoIndex` is implemented in Step 2. Add the idempotence-and-still-works test. In
`keiro-pgmq/test/Main.hs`, inside `spec`:

```haskell
    it "ensureFifoIndex is idempotent and the queue still accepts reads" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.fifo_index"
        roundTripped <-
            runDb connStr $ do
                ensureJobQueue job
                ensureFifoIndex job
                ensureFifoIndex job          -- second call must not error
                _ <- enqueue job (Ping "after-index" 1)
                runJobOnce 1 job (\_ -> pure Done)
                queueLen job.jobQueue.physicalName
        roundTripped `shouldBe` 0
```

This proves three things at once: the first `ensureFifoIndex` creates the index without error,
the second `ensureFifoIndex` is idempotent (no error on re-apply), and the queue still accepts
an enqueue and a drain afterward (final length 0 means the message was read and deleted).

Run:

```bash
cabal test keiro-pgmq-test
```

Expected (excerpt):

```text
  ensureFifoIndex is idempotent and the queue still accepts reads
```

reported passing.

### Step 6 — update living-document sections (all milestones)

After each milestone, tick the relevant Progress boxes, record any Surprises with evidence
(test transcript snippets), and at completion fill Outcomes & Retrospective. Also update the
MasterPlan `docs/masterplans/10-…` EP-2 Progress rows (the three `[ ] EP-2: …` lines) to
checked, and the Exec-Plan Registry row for `#2` status from `Not Started` to `Complete`.


## Validation and Acceptance

The single acceptance command, run from `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
cabal test keiro-pgmq-test
```

The suite must report all pre-existing examples still passing, plus the new examples:

- "ensureJobQueueWith unlogged creates an unlogged queue" — provisions with
  `unloggedProvision`, then `Pgmq.listQueues` shows the main queue with `isUnlogged = True`.
  This is observable behavior: the queue physically exists as an unlogged PostgreSQL table, and
  PGMQ's own catalog reports it as such.
- "ensureJobQueue (standard) creates a logged queue" — the default path still produces a
  logged queue (`isUnlogged = False`), proving we did not change the default.
- "ensureJobQueueWith partitioned builds a partitioned QueueConfig" — a pure assertion that the
  provisioning request constructed for `partitionedProvision` is a `PartitionedQueue` with the
  given interval/retention and the correct queue name.
- "ensureJobQueueWith partitioned creates a partitioned queue (live)" — appears as **PENDING**,
  not passing, with the operator note. See the partman caveat below.
- "ensureFifoIndex is idempotent and the queue still accepts reads" — calling `ensureFifoIndex`
  twice does not error and the queue round-trips a message afterward (drain leaves length 0).

### The pg_partman caveat (read before claiming partitioned support)

Partitioned-queue creation in PGMQ delegates to the PostgreSQL extension `pg_partman`. As
documented in `/Users/shinzui/Keikaku/hub/postgresql/pgmq-project/pgmq/docs/partitioned-queues.md`,
using partitioned queues requires installing `pg_partman` and setting
`shared_preload_libraries = 'pg_partman_bgw'` (plus `pg_partman_bgw.*` settings) in
`postgresql.conf`, which **requires a PostgreSQL restart**.

The keiro test suite (`keiro-pgmq/test/Main.hs`) provisions its database by running
`pgmq-migration`'s `Pgmq.Migration.migrate` (function `installPgmq`) against an ephemeral
PostgreSQL server managed by `keiro-test-support`. That migration installs only the PGMQ
schema; it does **not** run `CREATE EXTENSION pg_partman` and the ephemeral server does not
preload `pg_partman_bgw`. Verified by searching `pgmq-migration/src` for `partman` and
`CREATE EXTENSION` (no matches; `pg_partman` appears only in the vendored upstream Docker
image scripts, not in the Haskell migration). Therefore a live `create_partitioned` call would
fail in this environment.

Accordingly, this plan does **not** claim a passing live partitioned-queue integration test.
It asserts the partitioned path's *intent* via the pure `queueProvisionConfigs` test, and marks
the live test `pendingWith` an operator note. To run the live partitioned path, an operator
must point the suite at a PostgreSQL with `pg_partman` installed and preloaded, then replace the
`pendingWith` body with a real `ensureJobQueueWith (partitionedProvision …) job` call followed
by a `Pgmq.listQueues` assertion that the queue has `isPartitioned = True`. That is out of scope
for CI here and recorded as a known limitation.


## Idempotence and Recovery

Every step in this plan is safe to repeat.

- `ensureJobQueueWith` is idempotent by construction: it routes through `pgmq-config`'s
  `ensureQueuesEff`, which lists existing queues first and only creates queues that are
  missing. Running it at every worker startup (as the existing `ensureJobQueue` already is) is
  safe.
- `ensureFifoIndex` is idempotent: the underlying PGMQ FIFO-index SQL is `CREATE INDEX IF NOT
  EXISTS`, and `pgmq-config` always re-applies the index step (there is no way to query index
  existence), so a second call is a harmless no-op. The M3 test asserts exactly this by calling
  it twice.
- The cabal dependency edit (Step 1) is additive; if it fails to resolve, revert the single
  added `build-depends` line.
- The source edits in `Keiro.PGMQ.Job` are additive except for re-expressing `ensureJobQueue`
  through `ensureJobQueueWith standardProvision`, which is behavior-preserving (same standard
  main queue plus DLQ). If a regression appears, the old two-line body is recoverable from
  git history.
- There is no migration or destructive operation: no data is moved or dropped. Existing queues
  created before this change are unaffected; provisioning is additive.


## Interfaces and Dependencies

New dependency, declared in `keiro-pgmq/keiro-pgmq.cabal` `library` `build-depends`:

```cabal
, pgmq-config  >=0.3  && <0.4
```

`pgmq-config` symbols this plan uses, with full module paths:

- From `Pgmq.Config.Types` (package `pgmq-config`,
  `pgmq-config/src/Pgmq/Config/Types.hs`): the types `QueueConfig (..)`, `QueueType (..)`,
  `PartitionConfig (..)`; the smart constructors `standardQueue`, `unloggedQueue`,
  `partitionedQueue`; the modifier `withFifoIndex`. (We do not use `withNotifyInsert`,
  `withTopicBinding`, or `ReconcileAction` here.)
- From `Pgmq.Config.Effectful` (package `pgmq-config`,
  `pgmq-config/src/Pgmq/Config/Effectful.hs`): `ensureQueuesEff :: (Pgmq :> es) =>
  [QueueConfig] -> Eff es ()`.

We deliberately do **not** import `createFifoIndex` from `Pgmq.Effectful.Effect`. The FIFO
index is created entirely through `ensureQueuesEff`. For the record, the direct import — should
EP-3 ever want the raw op — is `import "pgmq-effectful" Pgmq.Effectful.Effect (createFifoIndex)`
(it is *not* in the `Pgmq.Effectful` umbrella).

New public surface added to `Keiro.PGMQ.Job` (package `keiro-pgmq`,
`keiro-pgmq/src/Keiro/PGMQ/Job.hs`), and therefore available through the `Keiro.PGMQ` umbrella
(`keiro-pgmq/src/Keiro/PGMQ.hs`) with no umbrella edit:

```haskell
data QueueKind
    = StandardKind
    | UnloggedKind
    | PartitionedKind !PartitionSpec
    deriving stock (Eq, Show)

data PartitionSpec = PartitionSpec
    { partitionInterval :: !Text   -- e.g. "daily" or "10000"
    , retentionInterval :: !Text   -- e.g. "7 days" or "100000"
    }
    deriving stock (Eq, Show)

data QueueProvision = QueueProvision
    { provisionKind      :: !QueueKind
    , provisionFifoIndex :: !Bool
    }
    deriving stock (Eq, Show)

standardProvision      :: QueueProvision
unloggedProvision      :: QueueProvision
partitionedProvision   :: PartitionSpec -> QueueProvision
withFifoIndexProvision :: QueueProvision -> QueueProvision

-- Pure: the list of pgmq-config QueueConfigs ensureJobQueueWith will reconcile
-- (main queue first, then the DLQ when the policy enables it). Exposed so the
-- partitioned path is testable without a pg_partman-enabled database.
queueProvisionConfigs :: QueueProvision -> Job p -> [Pgmq.Config.Types.QueueConfig]

-- Idempotent: create the main queue with the chosen kind/fifo-index, and the DLQ
-- (always a standard queue) when the policy uses one. Routes through pgmq-config's
-- additive reconciler.
ensureJobQueueWith :: (Pgmq :> es) => QueueProvision -> Job p -> Eff es ()

-- Unchanged behavior: ensureJobQueueWith standardProvision.
ensureJobQueue :: (Pgmq :> es) => Job p -> Eff es ()

-- Create the FIFO GIN index on the job's MAIN queue's headers column. Idempotent
-- (always re-applied; the underlying SQL is CREATE INDEX IF NOT EXISTS). This is
-- the artifact EP-3 consumes (Integration Point 3).
ensureFifoIndex :: (Pgmq :> es) => Job p -> Eff es ()
```

Existing keiro-pgmq types this plan reads but does not change (MasterPlan Integration Point 4
freezes them): `Job p` and `QueueRef` from `keiro-pgmq/src/Keiro/PGMQ/Job.hs` and
`keiro-pgmq/src/Keiro/PGMQ/Runtime.hs`. The provisioning choice is a *parameter*, never a field
on `Job`.

Integration Point 3 (MasterPlan #10): EP-3 — the sibling plan
`docs/plans/77-add-fifo-ordered-delivery-via-message-groups-to-keiro-pgmq.md` — consumes the
FIFO index this plan creates. EP-3 should call `ensureFifoIndex job` (or provision with
`withFifoIndexProvision`) for ordered jobs, rather than importing the raw `createFifoIndex`
op. EP-3's grouped reads (`read_grouped`/`read_grouped_rr`) match on the `x-pgmq-group` header
value, and the GIN index created here is what makes that match an index lookup instead of a
sequential scan. If EP-3 ever needs the raw op directly, the documented import is
`import "pgmq-effectful" Pgmq.Effectful.Effect (createFifoIndex)`.

Test-only dependency note: `keiro-pgmq/test/Main.hs` (component `keiro-pgmq-test`) gains an
import of `Pgmq.Config.Types qualified as Config` (for the pure partitioned-config assertion)
and `Data.List (find)` (for the unlogged-lookup helper). The test suite's `build-depends` in
`keiro-pgmq/keiro-pgmq.cabal` must therefore add `pgmq-config >=0.3 && <0.4` as well (the test
stanza is separate from the library stanza). The `Queue`/`listQueues` symbols the unlogged test
uses are already available through the suite's existing `import Pgmq.Effectful qualified as
Pgmq`.
