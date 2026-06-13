---
id: 77
slug: add-fifo-ordered-delivery-via-message-groups-to-keiro-pgmq
title: "Add FIFO ordered delivery via message groups to keiro-pgmq"
kind: exec-plan
created_at: 2026-06-13T14:29:36Z
intention: "intention_01kv0jvq2qe70reyz4f6dpfxnk"
master_plan: "docs/masterplans/10-keiro-pgmq-queue-feature-expansion-fifo-ordering-headers-provisioning-observability.md"
---

# Add FIFO ordered delivery via message groups to keiro-pgmq

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`keiro-pgmq` (the Haskell package whose source lives under `keiro-pgmq/` in the repository
rooted at `/Users/shinzui/Keikaku/bokuno/keiro`) is a typed background-job queue. An
application declares a `Job p` value — a queue, a way to encode and decode the payload `p`,
and a retry/dead-letter policy — and writes a plain handler `p -> Eff es JobOutcome`. The
package puts that work onto PGMQ (the PostgreSQL-native message queue: a Postgres extension
that stores each queue as a table and hands out messages with a per-message visibility
timeout) and runs the handler against it through shibuya, a Broadway-style worker framework.

Today keiro-pgmq processes work with **no ordering guarantee**. A worker reads the oldest
unclaimed message, processes it, and moves on; under concurrent workers, retries, and
visibility-timeout expiry the order in which two messages are actually *handled* is not the
order they were enqueued. For many jobs that is fine. But some work must be processed strictly
in order *per key*: all events for one bank account, one user, one document, one aggregate must
run one-after-another, even though events for different keys may run in parallel.

After this change, a keiro application can get exactly that. A developer declares an ordered
`Job`, enqueues a message with a **group key** (a text label such as an account id), and
consumes with a **FIFO read strategy**. The package then guarantees that, within one group key,
messages are handled strictly in send order, while distinct group keys proceed concurrently.
Concretely, the developer will be able to write:

```haskell
-- Enqueue work tagged with a group key (here, an account id):
enqueueToGroup job "account-42" (Transfer 100)

-- Provision the ordered queue (creates the FIFO index ordered reads need):
ensureOrderedJobQueue job

-- Consume with strict per-key ordering (throughput-optimized batch filling):
runJobOnceWithContext (withOrdering FifoThroughput defaultJobTuning) 100 job handler
-- or, on the continuous worker path:
jobProcessorWithContext (withOrdering FifoThroughput defaultJobTuning) job handler
```

You can see it working by running the package's behavioral test suite from the repository root
`/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
cabal test keiro-pgmq-test
```

The suite gains an end-to-end ordering test: it enqueues messages `a1, a2, a3` to group `"a"`
and `b1, b2` to group `"b"` on one queue, drains them with `FifoThroughput`, and asserts that
the handler observed `a1` before `a2` before `a3` (and `b1` before `b2`), recording each
observed payload into an ordered log, and that the queue fully drains. When that test passes,
the ordering capability is demonstrably real rather than merely compiled.

This plan is **EP-3** of the MasterPlan
`docs/masterplans/10-keiro-pgmq-queue-feature-expansion-fifo-ordering-headers-provisioning-observability.md`.
It is the headline plan of that initiative and the only one with hard dependencies. It builds
on two sibling plans that must land first:

- **EP-1** (`docs/plans/75-add-message-headers-trace-propagation-and-batch-enqueue-to-keiro-pgmq-producers.md`)
  ships the header-carrying producer `enqueueWithHeaders`, on which EP-3's group-keyed
  producer is a thin specialization (a group is just the reserved `x-pgmq-group` header).
- **EP-2** (`docs/plans/76-add-partitioned-and-unlogged-queue-provisioning-with-fifo-indexes-to-keiro-pgmq.md`)
  ships `ensureFifoIndex` and `ensureJobQueueWith`, which create the GIN index that grouped
  reads use; EP-3's ordered queue-setup path invokes them.

The exact interfaces EP-3 consumes from EP-1 and EP-2, and the reconcile path if either has
not yet landed, are stated in Interfaces and Dependencies.


## Progress

- [ ] M1: Add `JobOrdering` and an `ordering` field to `JobTuning` in
  `keiro-pgmq/src/Keiro/PGMQ/Job.hs`; add `withOrdering`; default `defaultJobTuning` to
  `Unordered`; keep `mkJobTuning`'s arity (defaulting `ordering = Unordered`).
- [ ] M1: Map `ordering` to the shibuya adapter's `fifoConfig` in `adapterConfigFor` (the
  worker path); import `FifoConfig`/`FifoReadStrategy` from `Shibuya.Adapter.Pgmq`.
- [ ] M1: Export `JobOrdering (..)` and `withOrdering` from `Keiro.PGMQ.Job`; fix every
  in-repo `JobTuning`/`mkJobTuning` site that the new strict field forces (grep first).
- [ ] M1: `cabal build keiro-pgmq` is clean and `cabal test keiro-pgmq-test` is green (no new
  behavioral test yet; this milestone is a compile-and-no-regression checkpoint).
- [ ] M2: Generalize the `runJobOnceWithContext` drain so an ordered tuning issues grouped
  reads (`readGrouped`/`readGroupedRoundRobin` from `Pgmq.Effectful.Effect`) instead of the
  plain `readMessage`, reusing the existing ack/decode mechanics unchanged.
- [ ] M2: `cabal test keiro-pgmq-test` is green; the existing `Unordered` drain tests still
  pass (ordered path exercised end-to-end in M4).
- [ ] M3: Add `enqueueToGroup` and `enqueueToGroupWithDelay` over EP-1's `enqueueWithHeaders`
  / `enqueueWithHeadersAndDelay`; add `ensureOrderedJobQueue` (ensure queue + FIFO index);
  export all three.
- [ ] M3: `cabal test keiro-pgmq-test` is green; a small test proves `enqueueToGroup` puts
  the literal `x-pgmq-group` header on the wire and `ensureOrderedJobQueue` is idempotent.
- [ ] M4: Add the end-to-end ordering test (drain path, deterministic within-group ordering
  + full drainage) and a worker-path ordering smoke test.
- [ ] M4: `cabal test keiro-pgmq-test` is green with the M3 and M4 examples present.
- [ ] Final: Fill Outcomes & Retrospective; tick MasterPlan #10 Progress rows for EP-3 and set
  the Exec-Plan Registry row `#3` status from `Not Started` to `Complete`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Fold the FIFO read strategy into `#74`'s `JobTuning` by adding an
  `ordering :: JobOrdering` field, rather than introducing a separate ordering-config record.
  Rationale: This is **Integration Point 1** of MasterPlan #10. `JobTuning` (in
  `keiro-pgmq/src/Keiro/PGMQ/Job.hs`) is already "how a consumer reads the queue" — visibility
  timeout, batch size, polling cadence — and a FIFO read strategy is exactly a read concern.
  A competing record would fragment the tuning surface and force consumers to thread two
  configs through `jobProcessorWithContext`, `runJobOnceWithContext`, and `adapterConfigFor`.
  The cost is that `JobTuning`'s constructor is strict, so the new field forces every in-repo
  construction site to be updated. EP-3 absorbs that mechanical fix, mirroring the `#74`
  convention of one well-justified breaking change owned by the plan that needs it.
  Date: 2026-06-13

- Decision: `JobOrdering` has exactly three constructors: `Unordered`, `FifoThroughput`,
  `FifoRoundRobin`. `defaultJobTuning` sets `Unordered`, so all existing behavior is unchanged.
  Rationale: These map one-to-one onto the shibuya adapter's existing
  `Maybe FifoConfig`/`FifoReadStrategy` surface (read
  `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs`):
  `Unordered -> Nothing`, `FifoThroughput -> Just (FifoConfig ThroughputOptimized)`,
  `FifoRoundRobin -> Just (FifoConfig RoundRobin)`. PGMQ exposes a third strategy
  (`read_grouped_head`, one-per-group) but neither `pgmq-effectful` nor the shibuya adapter
  surfaces it, so EP-3 does not offer it. `ThroughputOptimized` fills a batch from the oldest
  eligible group first (SQS-style); `RoundRobin` interleaves fairly across groups (multi-tenant
  fairness). Both preserve strict within-group order.
  Date: 2026-06-13

- Decision: Keep `mkJobTuning`'s existing arity (`Int32 -> Int32 -> JobPolling -> Either …`)
  and default its `ordering` to `Unordered`; expose a separate record-update modifier
  `withOrdering :: JobOrdering -> JobTuning -> JobTuning` to set ordering on top of any tuning.
  Rationale: `mkJobTuning` already validates three positive integers; threading a fourth
  ordering argument through it adds nothing to validate (every `JobOrdering` value is valid)
  and would break the smart constructor's published arity, touching its test site. A separate
  `withOrdering` keeps `mkJobTuning` and `defaultJobTuning` source-compatible and reads
  naturally at call sites: `withOrdering FifoThroughput defaultJobTuning`. This means the only
  forced construction-site edits are inside the library itself (`defaultJobTuning`'s raw record
  literal and `mkJobTuning`'s body); the test suite's `mkJobTuning` calls keep compiling
  unchanged.
  Date: 2026-06-13

- Decision: The worker path gets ordering by **reusing the shibuya adapter's `fifoConfig`**;
  the drain path gets it by **issuing explicit grouped reads**.
  Rationale: These are two different read mechanisms in the codebase. The continuous worker
  path (`jobProcessorWithContext` → `adapterConfigFor` → `pgmqAdapter`) reads through the
  shibuya adapter, which *already* selects `read_grouped`/`read_grouped_rr` when its
  `PgmqAdapterConfig.fifoConfig` is set (read
  `Shibuya/Adapter/Pgmq/Internal.hs`, `poll = case config.fifoConfig of …`, and
  `Convert.extractPartition`, which keys the group on the literal `"x-pgmq-group"` header). So
  the worker path is pure config plumbing: map `ordering` to `fifoConfig` in `adapterConfigFor`
  and the adapter does the rest. The one-shot drain (`runJobOnceWithContext`) instead reads
  *directly* via `Pgmq.readMessage` (a plain, unordered read), so for an ordered tuning EP-3
  must call the grouped read effect (`readGrouped`/`readGroupedRoundRobin`) explicitly, reusing
  the existing decode/ack/dead-letter mechanics unchanged. The drain path is preferred for the
  deterministic ordering *test* because a single-threaded drain over grouped reads yields a
  reproducible observed order, whereas the worker path is concurrent.
  Date: 2026-06-13

- Decision: The FIFO group key is carried in the JSONB header under the literal key
  `x-pgmq-group`, set verbatim. EP-3 builds `enqueueToGroup job groupKey p = enqueueWithHeaders
  job (MessageHeaders (object ["x-pgmq-group" .= groupKey])) p`.
  Rationale: `x-pgmq-group` is the contract shared by PGMQ itself (read
  `/Users/shinzui/Keikaku/hub/postgresql/pgmq-project/pgmq/docs/fifo-queues.md`: "FIFO ordering
  is controlled by the `x-pgmq-group` header value") and the shibuya adapter
  (`Convert.extractPartition` looks up exactly `Key.fromText "x-pgmq-group"`). EP-1 guarantees
  it never reserves, injects, strips, or rewrites this key (its Decision Log records the
  no-reserve contract), so EP-3 can set it through `enqueueWithHeaders` and trust it reaches
  the wire intact.
  Date: 2026-06-13

- Decision: State the ordering guarantee honestly and narrowly: **strict ordering holds within
  a group; delivery is at-least-once; there is no deduplication and no exactly-once.**
  Rationale: PGMQ's grouped reads refuse to return a later message in a group while an earlier
  message in that same group is still in-flight (its visibility timeout is in the future), which
  gives strict per-key order. But the upstream doc's own comparison table marks both
  `read_grouped` and `read_grouped_rr` as ❌ for "Message deduplication" and ❌ for
  "Exactly-once delivery" (fifo-queues.md, lines 326 and 328). So a handler can still see the
  same message twice (after a crash, an exception, or a visibility-timeout expiry) and **must
  be idempotent**. Cross-group *interleaving* order is also not fixed. The end-to-end test
  therefore asserts only within-group order and full drainage, never a cross-group order.
  Date: 2026-06-13


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it before editing.

The package you change lives under `keiro-pgmq/` in the repository rooted at
`/Users/shinzui/Keikaku/bokuno/keiro`. Its Cabal file is `keiro-pgmq/keiro-pgmq.cabal`; it
declares one library and one test component, `keiro-pgmq-test` (test driver
`keiro-pgmq/test/Main.hs`). All commands in this plan run from the repository root
`/Users/shinzui/Keikaku/bokuno/keiro` unless stated otherwise.

The library has five modules. `keiro-pgmq/src/Keiro/PGMQ.hs` is the umbrella module: it
re-exports the whole `Keiro.PGMQ.Job` module (and the other three), so any new public name you
add to `Keiro.PGMQ.Job`'s export list is automatically available to a consumer who writes
`import Keiro.PGMQ`. You will **not** need to edit the umbrella in this plan because all new
surface lives in `Keiro.PGMQ.Job`. `keiro-pgmq/src/Keiro/PGMQ/Runtime.hs` holds the runtime
and `QueueRef`. `keiro-pgmq/src/Keiro/PGMQ/Codec.hs` holds the payload codecs.
`keiro-pgmq/src/Keiro/PGMQ/Dlq.hs` holds dead-letter inspection. `keiro-pgmq/src/Keiro/PGMQ/Job.hs`
is the file you edit the most: it defines `Job`, `JobTuning`, the producers, and the consumers.

A few terms of art, defined in plain language and tied to where they appear.

"PGMQ" is the PostgreSQL message-queue extension. A queue is a table; sending a message inserts
a row; reading takes the oldest unclaimed row (`msg_id` ascending) and hides it for a
visibility-timeout window. keiro talks to PGMQ through the `pgmq-effectful` library, whose
source is at `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-effectful`.

"The `Pgmq` effect" is an `effectful` capability (`effectful` is a Haskell effect-system
library; an effect `E :> es` is a capability available in the effect row `es`). The operations
keiro calls on it — `Pgmq.sendMessage`, `Pgmq.readMessage`, `Pgmq.deleteMessage`, and so on —
are defined in `Pgmq.Effectful.Effect` and re-exported from the `Pgmq.Effectful` umbrella.
keiro imports them as `import "pgmq-effectful" Pgmq.Effectful qualified as Pgmq` and the request
record types unqualified from `Pgmq.Effectful` (see the import block at the top of
`keiro-pgmq/src/Keiro/PGMQ/Job.hs`, lines 87–99).

"Message group / FIFO group." PGMQ's standard `read` is FIFO only in *selection* order
(`msg_id` ascending). Under concurrent workers it uses `FOR UPDATE SKIP LOCKED`, and combined
with retries and visibility-timeout expiry it gives **no delivery-order guarantee** — two
workers can pull adjacent messages and finish them in either order. To get strict per-key
order you must use *message groups*. A message carrying a value under the reserved JSONB header
key `x-pgmq-group` joins the group named by that value (messages with no such header join a
single default group). PGMQ's grouped-read functions `read_grouped` (throughput-optimized,
SQS-style batch filling) and `read_grouped_rr` (round-robin, fair interleaving across groups)
**refuse to return a later message in a group while an earlier message in that same group is
still in-flight** (its visibility timeout is in the future). Different groups proceed in
parallel. This is the entire ordering mechanism: a group is "a value under `x-pgmq-group`", and
ordering is "read with a grouped read instead of a plain read."

"The ordering guarantee, stated precisely." Within one group, messages are handled in strict
send order. Across groups, order is not fixed (the two strategies interleave differently).
Delivery is **at-least-once**: a handler may see the same message again after a crash, an
exception, or a visibility-timeout expiry. There is **no deduplication** and **no exactly-once**
delivery — the upstream PGMQ doc's comparison table
(`/Users/shinzui/Keikaku/hub/postgresql/pgmq-project/pgmq/docs/fifo-queues.md`, lines 326 and
328) marks both `read_grouped` and `read_grouped_rr` ❌ for deduplication and ❌ for
exactly-once. Handlers must therefore be idempotent. This is the same at-least-once contract
the unordered path already documents on `runJobOnceWithContext`; ordering does not change it.

"`JobTuning`" (in `keiro-pgmq/src/Keiro/PGMQ/Job.hs`, lines 198–212) is the consumption-side
config record `#74` introduced. Today:

```haskell
data JobPolling = PollEvery !NominalDiffTime | LongPoll !Int32 !Int32
  deriving stock (Eq, Show)

data JobTuning = JobTuning
  { visibilityTimeout :: !Int32
  , batchSize         :: !Int32
  , polling           :: !JobPolling
  }
  deriving stock (Eq, Show)

mkJobTuning      :: Int32 -> Int32 -> JobPolling -> Either JobTuningConfigError JobTuning
defaultJobTuning :: JobTuning   -- 30 s vt, batch 1, PollEvery 1
```

`JobTuning` is consumed at three sites in `Job.hs`: `jobProcessorWithContext :: JobTuning ->
Job p -> (JobContext es -> p -> Eff es JobOutcome) -> Eff es (ProcessorId, QueueProcessor es)`
(line 352), `runJobOnceWithContext :: JobTuning -> Int -> Job p -> (JobContext es -> p -> Eff
es JobOutcome) -> Eff es Int` (line 398), and `adapterConfigFor :: JobTuning -> Job p ->
PgmqAdapterConfig` (line 305). EP-3 adds an `ordering` field here and threads it to the adapter
(worker path) and to the drain read (drain path).

"The shibuya PGMQ adapter config." `adapterConfigFor` builds a `PgmqAdapterConfig` for the
worker path. Reading
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs`
confirms the relevant shape: `PgmqAdapterConfig` carries `fifoConfig :: Maybe FifoConfig`;
`data FifoConfig = FifoConfig { readStrategy :: FifoReadStrategy }`; `data FifoReadStrategy =
ThroughputOptimized | RoundRobin`. The adapter's read dispatch (`Internal.hs`,
`poll = case config.fifoConfig of …`) selects `read_grouped`/`read_grouped_rr` (and their
long-poll variants) when `fifoConfig` is `Just`, keying the group on the `x-pgmq-group` header
(`Convert.extractPartition`). `FifoConfig (..)` and `FifoReadStrategy (..)` are exported from
the umbrella module `Shibuya.Adapter.Pgmq` (confirmed by reading its export list). keiro-pgmq's
current `adapterConfigFor` never sets `fifoConfig`, so the worker path runs unordered today;
EP-3's only worker-path change is to map `ordering` onto `fifoConfig`.

"The drain path." `runJobOnceWithContext` (lines 398–536) is the one-shot drain. Its inner
`drain` loop reads directly with `Pgmq.readMessage ReadMessage { queueName, delay =
tuning.visibilityTimeout, batchSize = Just (nextBatchSize …), conditional = Nothing }` (lines
412–419), then folds each returned `Pgmq.Message` through `processMessage`, which decodes the
payload, runs the handler, and acknowledges the outcome (delete on `Done`, change-visibility on
`Retry`, send-to-DLQ-then-delete on dead-letter). For an ordered tuning EP-3 must replace just
the *read* call with a grouped read; everything downstream (`processMessage`, `ackMessage`,
`contextFor`) stays identical because all of it operates on a `Pgmq.Message`, and grouped reads
return the same `Vector Message`.

"Grouped reads in `pgmq-effectful`." Read
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-effectful/src/Pgmq/Effectful/Effect.hs`.
The grouped-read operations are `readGrouped :: (Pgmq :> es) => ReadGrouped -> Eff es (Vector
Message)` and `readGroupedRoundRobin :: (Pgmq :> es) => ReadGrouped -> Eff es (Vector Message)`
(lines 298 and 306). The request record is `data ReadGrouped = ReadGrouped { queueName ::
QueueName, visibilityTimeout :: Int32, qty :: Int32 }` (in
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-hasql/src/Pgmq/Hasql/Statements/Types.hs`,
lines 213–217). It has **no `conditional` field** (the upstream comment notes `conditional` was
removed in pgmq 1.9.0). **Important re-export fact:** `readGrouped`, `readGroupedRoundRobin`,
and `ReadGrouped` are exported from `Pgmq.Effectful.Effect` but **not** from the
`Pgmq.Effectful` umbrella, so the drain must import them from `Pgmq.Effectful.Effect` directly:
`import "pgmq-effectful" Pgmq.Effectful.Effect (readGrouped, readGroupedRoundRobin)` and
`import "pgmq-effectful" Pgmq.Effectful.Effect (ReadGrouped (..))` (a single import line can
list all three). Mapping from `JobTuning`: `visibilityTimeout` ← `tuning.visibilityTimeout`,
`qty` ← the remaining batch size (the same `nextBatchSize` the plain read uses).

"`Pgmq.Message`." The raw queue row (from `pgmq-core` `Pgmq.Types`) has the fields the drain
relies on: `messageId :: MessageId`, `readCount :: Int64`, and `headers :: Maybe Value`. The
drain's existing helpers already use all three, so an ordered read changes nothing here.

"EP-1's header producer (consumed by EP-3)." EP-1
(`docs/plans/75-add-message-headers-trace-propagation-and-batch-enqueue-to-keiro-pgmq-producers.md`)
ships, in this same `Keiro.PGMQ.Job`:

```haskell
enqueueWithHeaders ::
  (Pgmq :> es, IOE :> es) =>
  Job p -> MessageHeaders -> p -> Eff es MessageId

enqueueWithHeadersAndDelay ::
  (Pgmq :> es, IOE :> es) =>
  Job p -> Int32 -> MessageHeaders -> p -> Eff es MessageId
```

`MessageHeaders` is `newtype MessageHeaders { unMessageHeaders :: Value }` from `pgmq-core`,
re-exported by `pgmq-effectful` as `Pgmq.Effectful (MessageHeaders (..))` and re-exported again
by EP-1 from `Keiro.PGMQ.Job`. The header argument sits between the `Job` and the payload so the
payload stays last. EP-1's no-reserve contract guarantees `x-pgmq-group` passes through verbatim.

"EP-2's FIFO-index and provisioning helpers (consumed by EP-3)." EP-2
(`docs/plans/76-add-partitioned-and-unlogged-queue-provisioning-with-fifo-indexes-to-keiro-pgmq.md`)
ships, in the same module:

```haskell
ensureFifoIndex    :: (Pgmq :> es) => Job p -> Eff es ()
ensureJobQueueWith :: (Pgmq :> es) => QueueProvision -> Job p -> Eff es ()
ensureJobQueue     :: (Pgmq :> es) => Job p -> Eff es ()   -- = ensureJobQueueWith standardProvision
```

`ensureFifoIndex job` creates the GIN index on the job's main queue's `headers` column
(idempotent: the underlying SQL is `CREATE INDEX IF NOT EXISTS`). `ensureJobQueue` creates the
main queue (and DLQ when the policy uses one); it is the pre-existing function EP-3 composes
with `ensureFifoIndex`.

"The test harness." `keiro-pgmq/test/Main.hs` is an hspec suite. Its `main` starts one
suite-level PostgreSQL server, installs the PGMQ schema into a migrated template database
(`Postgres.withMigratedSuiteWith installPgmq`), then gives every example a fresh cloned database
(`around (Postgres.withFreshDatabase fixture)`); each example receives that database's
connection string. The helper `runDb connStr act` runs an `Eff Stack a` action against the fresh
database, where `type Stack = '[Pgmq, Tracing, Error PgmqRuntimeError, IOE]`. Existing examples
declare a job with `mkJob name` (queue, `aesonJobCodec`, `defaultRetryPolicy`), enqueue with
`enqueue`, drain with `runJobOnce`/`runJobOnceWithContext`, and inspect the queue with the
helper `queueLen` (which returns `metrics.queueLength`). The sample payload is `data Ping = Ping
{ message :: Text, count :: Int }`. New examples follow exactly this style.


## Plan of Work

The work is four milestones, each independently verifiable by a single `cabal test
keiro-pgmq-test` run from `/Users/shinzui/Keikaku/bokuno/keiro`. M1 wires the ordering knob and
the worker path; M2 wires the drain path; M3 adds the group-keyed producer and ordered queue
setup; M4 proves end-to-end ordering. The only breaking change is adding a strict field to
`JobTuning` (M1), which EP-3 fully absorbs at the in-repo construction sites it forces.

This plan has **hard dependencies on EP-1 and EP-2**, both of which extend the same file
(`keiro-pgmq/src/Keiro/PGMQ/Job.hs`). Before starting, confirm both have landed by checking that
`enqueueWithHeaders` (EP-1) and `ensureFifoIndex`/`ensureJobQueueWith` (EP-2) are present in the
module's export list. If either has not landed, follow the reconcile notes in Interfaces and
Dependencies (build EP-3's producer/setup against the documented signatures, and for the index
fall back to `createFifoIndex` from `Pgmq.Effectful.Effect` directly), and record the reconcile
in the Decision Log.

### Milestone M1 — the ordering knob and the worker path

Scope: add the `JobOrdering` type and an `ordering` field to `JobTuning`, default it to
`Unordered`, expose `withOrdering`, and map `ordering` onto the shibuya adapter's `fifoConfig`
in `adapterConfigFor`. At the end of M1 the package compiles with the new field, the worker
path runs ordered when asked, and every pre-existing test still passes. No new behavioral test
is added in M1 (the worker-path ordering is exercised by the M4 smoke test); M1's acceptance is
a clean build and no regression.

Work, in `keiro-pgmq/src/Keiro/PGMQ/Job.hs`:

1. After the `JobPolling` declaration (around line 191), add the ordering type:

   ```haskell
   -- | How a consumer orders deliveries.
   --
   -- 'Unordered' is the historical behavior: PGMQ's plain @read@, FIFO only in
   -- selection order (@msg_id@ ascending), with NO per-key delivery-order
   -- guarantee under concurrent workers, retries, or visibility-timeout expiry.
   --
   -- 'FifoThroughput' and 'FifoRoundRobin' enable strict per-group ordering via
   -- PGMQ message groups (the reserved @x-pgmq-group@ header). Within one group,
   -- messages are delivered in strict send order; distinct groups proceed in
   -- parallel. 'FifoThroughput' fills a batch from the oldest eligible group
   -- first (SQS-style, @read_grouped@); 'FifoRoundRobin' interleaves fairly
   -- across groups (@read_grouped_rr@). Delivery is still at-least-once and there
   -- is no deduplication, so handlers must be idempotent.
   data JobOrdering
       = Unordered
       | FifoThroughput
       | FifoRoundRobin
       deriving stock (Eq, Show)
   ```

2. Add the `ordering` field to `JobTuning` (the record currently at lines 198–203):

   ```haskell
   data JobTuning = JobTuning
       { visibilityTimeout :: !Int32
       , batchSize :: !Int32
       , polling :: !JobPolling
       , ordering :: !JobOrdering
       }
       deriving stock (Eq, Show)
   ```

3. Update `defaultJobTuning` (lines 206–212) to set `ordering = Unordered`:

   ```haskell
   defaultJobTuning :: JobTuning
   defaultJobTuning =
       JobTuning
           { visibilityTimeout = 30
           , batchSize = 1
           , polling = PollEvery 1
           , ordering = Unordered
           }
   ```

4. Update `mkJobTuning`'s body (line 225) to keep the same arity while defaulting `ordering`:

   ```haskell
   | otherwise = Right JobTuning{visibilityTimeout, batchSize, polling, ordering = Unordered}
   ```

5. Add the record-update modifier after `mkJobTuning`:

   ```haskell
   -- | Set the FIFO read strategy on an existing tuning, e.g.
   -- @withOrdering FifoThroughput defaultJobTuning@.
   withOrdering :: JobOrdering -> JobTuning -> JobTuning
   withOrdering o tuning = tuning{ordering = o}
   ```

6. Add a pure mapper and use it in `adapterConfigFor` (line 305). Place the mapper near the
   other small helpers (e.g. just below `toPollingConfig`):

   ```haskell
   toFifoConfig :: JobOrdering -> Maybe FifoConfig
   toFifoConfig Unordered      = Nothing
   toFifoConfig FifoThroughput = Just (FifoConfig ThroughputOptimized)
   toFifoConfig FifoRoundRobin = Just (FifoConfig RoundRobin)
   ```

   Then in `adapterConfigFor`'s record update (the block beginning at line 307), add the field
   `, fifoConfig = toFifoConfig tuning.ordering` alongside the existing `visibilityTimeout`,
   `batchSize`, `polling`, `maxRetries`, `deadLetterConfig` fields.

7. Imports: extend the existing `Shibuya.Adapter.Pgmq` import block (lines 114–120) to also
   bring in `FifoConfig (..)` and `FifoReadStrategy (..)`:

   ```haskell
   import "shibuya-pgmq-adapter" Shibuya.Adapter.Pgmq (
       FifoConfig (..),
       FifoReadStrategy (..),
       PgmqAdapterConfig (..),
       PollingConfig (..),
       defaultConfig,
       directDeadLetter,
       pgmqAdapter,
    )
   ```

8. Exports: in the `Job declaration` export section (around lines 56–61), add `JobOrdering (..)`
   and `withOrdering`:

   ```haskell
       JobPolling (..),
       JobOrdering (..),
       JobTuning (..),
       JobTuningConfigError (..),
       mkJobTuning,
       defaultJobTuning,
       withOrdering,
   ```

9. Fix forced construction sites. Because `JobTuning`'s constructor is strict, the new field
   forces every place that builds a `JobTuning` *by record literal* to be updated. Grep first
   (from the repo root):

   ```bash
   grep -rn "JobTuning\|mkJobTuning" --include='*.hs' . | grep -v dist-newstyle
   ```

   As of this writing the only record-literal sites are inside `Job.hs` itself
   (`defaultJobTuning` and `mkJobTuning`, both updated above). Every `mkJobTuning` *call* —
   including all calls in `keiro-pgmq/test/Main.hs` (lines 212–220, 312, 345, 399, 486) and the
   smart-constructor's round-trip test (`mkJobTuning 30 1 (PollEvery 1) \`shouldBe\` Right
   defaultJobTuning`, line 220–221) — keeps compiling unchanged because `mkJobTuning`'s arity is
   preserved and `defaultJobTuning` now carries `ordering = Unordered`. There is no keiro-dsl
   fixture that builds a `JobTuning` directly. If the grep ever shows a new record-literal site,
   add `ordering = Unordered` to it.

Commands (from `/Users/shinzui/Keikaku/bokuno/keiro`):

```bash
cabal build keiro-pgmq
cabal test keiro-pgmq-test
```

Acceptance: the build is clean and the suite is green with the same example count as before (no
new examples in M1). This proves the strict-field change was absorbed everywhere and the worker
path still compiles with `fifoConfig` wired.

### Milestone M2 — grouped reads in the drain path

Scope: make the one-shot drain (`runJobOnceWithContext`) issue a *grouped* read when the tuning
is ordered, instead of the plain `Pgmq.readMessage`. At the end of M2, draining an ordered job
respects per-group order; the unordered drain is byte-for-byte unchanged. The ordered drain is
exercised end-to-end in M4; M2's acceptance is a clean build and no regression of the existing
drain tests.

Work, in `keiro-pgmq/src/Keiro/PGMQ/Job.hs`:

1. Add the grouped-read imports (these are NOT in the `Pgmq.Effectful` umbrella; import from
   `Pgmq.Effectful.Effect` directly):

   ```haskell
   import "pgmq-effectful" Pgmq.Effectful.Effect (ReadGrouped (..), readGrouped, readGroupedRoundRobin)
   ```

2. In `runJobOnceWithContext`'s inner `drain` loop, replace the single read expression (lines
   412–419) with a read that dispatches on `tuning.ordering`. Keep the existing `nextBatchSize`
   helper and feed it to `qty`. The change is local to the read; the `if null messages …` branch
   and everything downstream is untouched:

   ```haskell
   drain handled
       | handled >= n = pure handled
       | otherwise = do
           let qty = nextBatchSize (n - handled)
           messages <- case tuning.ordering of
               Unordered ->
                   Pgmq.readMessage
                       ReadMessage
                           { queueName = job.jobQueue.physicalName
                           , delay = tuning.visibilityTimeout
                           , batchSize = Just qty
                           , conditional = Nothing
                           }
               FifoThroughput ->
                   readGrouped
                       ReadGrouped
                           { queueName = job.jobQueue.physicalName
                           , visibilityTimeout = tuning.visibilityTimeout
                           , qty = qty
                           }
               FifoRoundRobin ->
                   readGroupedRoundRobin
                       ReadGrouped
                           { queueName = job.jobQueue.physicalName
                           , visibilityTimeout = tuning.visibilityTimeout
                           , qty = qty
                           }
           if null messages
               then pure handled
               else do
                   handledInBatch <- foldM step 0 messages
                   drain (handled + handledInBatch)
   ```

   Note the `ReadMessage.delay` field is PGMQ's read visibility timeout (the existing code
   already passes `tuning.visibilityTimeout` there), and `ReadGrouped.visibilityTimeout` is the
   same concept under a different field name; both receive `tuning.visibilityTimeout`. The
   grouped read records have no `conditional` field, which is why the ordered branches omit it.

Commands and acceptance: from `/Users/shinzui/Keikaku/bokuno/keiro`, run `cabal test
keiro-pgmq-test`. The build is clean and every existing drain example (all of which use
`defaultJobTuning` or `mkJobTuning`, i.e. `Unordered`) still passes — proving the `Unordered`
branch is unchanged and the ordered branches compile.

### Milestone M3 — the group-keyed producer and ordered queue setup

Scope: give callers a typed way to enqueue into a group and to provision an ordered queue
(queue plus FIFO index). At the end of M3, `enqueueToGroup job "g1" payload` puts the literal
`x-pgmq-group` header on the wire, and `ensureOrderedJobQueue job` creates the queue and its
FIFO index idempotently.

Work, in `keiro-pgmq/src/Keiro/PGMQ/Job.hs`:

1. Add the group-keyed producers, just after EP-1's `enqueueWithHeaders`/`enqueueWithHeadersAndDelay`:

   ```haskell
   -- | Enqueue a payload into the FIFO group named by @groupKey@. The group key
   -- is written under the reserved @x-pgmq-group@ JSONB header, which PGMQ's
   -- grouped reads and the shibuya adapter use to order deliveries per group.
   -- Consume with an ordered 'JobTuning' (see 'withOrdering') to honor the order.
   enqueueToGroup ::
       (Pgmq :> es, IOE :> es) =>
       Job p -> Text -> p -> Eff es MessageId
   enqueueToGroup job groupKey p =
       enqueueWithHeaders job (groupHeader groupKey) p

   -- | 'enqueueToGroup' with an explicit first-delivery delay (seconds).
   enqueueToGroupWithDelay ::
       (Pgmq :> es, IOE :> es) =>
       Job p -> Int32 -> Text -> p -> Eff es MessageId
   enqueueToGroupWithDelay job d groupKey p =
       enqueueWithHeadersAndDelay job d (groupHeader groupKey) p

   -- | The reserved FIFO group header for a group key.
   groupHeader :: Text -> MessageHeaders
   groupHeader k = MessageHeaders (Data.Aeson.object ["x-pgmq-group" Data.Aeson..= k])
   ```

   `Data.Aeson` is already imported (the module imports `Data.Aeson (Value)` at line 81); add
   `object` and `(.=)` to that import, i.e. `import "aeson" Data.Aeson (Value, object, (.=))`,
   and then `groupHeader k = MessageHeaders (object ["x-pgmq-group" .= k])`. `Text` is already
   imported (line 125). The literal string is exactly `x-pgmq-group`.

2. Add the ordered queue-setup helper, just after EP-2's `ensureFifoIndex` (or after
   `ensureJobQueue` if EP-2's `ensureFifoIndex` is adjacent):

   ```haskell
   -- | Provision an ordered job's queue: create the main queue (and DLQ when the
   -- policy uses one) and the FIFO GIN index that grouped reads need. Idempotent;
   -- safe to call at every startup.
   ensureOrderedJobQueue :: (Pgmq :> es) => Job p -> Eff es ()
   ensureOrderedJobQueue job = do
       ensureJobQueue job
       ensureFifoIndex job
   ```

   This composes EP-2's `ensureJobQueue` and `ensureFifoIndex`. (Equivalently a caller can use
   EP-2's `ensureJobQueueWith (withFifoIndexProvision standardProvision) job`; `ensureOrderedJobQueue`
   is the one-call convenience EP-3 owns.)

3. Exports: add `enqueueToGroup` and `enqueueToGroupWithDelay` under the `Producing work`
   section, and `ensureOrderedJobQueue` under the `Queue lifecycle` section, of the module
   export list.

Tests (in `keiro-pgmq/test/Main.hs`): add two examples.

The first, `"enqueueToGroup writes the x-pgmq-group header"`, ensures the queue, calls
`enqueueToGroup job "g1" (Ping "grouped" 1)`, reads the raw message back with `Pgmq.readMessage`
(`batchSize = Just 1`, `conditional = Nothing`, the same shape as the existing `readOneIsEmpty`
helper but returning the vector), and asserts the returned `message.headers` is `Just v` where
`v` is an object whose `"x-pgmq-group"` key equals the string `"g1"`. This proves the literal
contract EP-3 relies on reaches the wire.

The second, `"ensureOrderedJobQueue is idempotent and the queue accepts grouped work"`, ensures
the ordered queue twice (`ensureOrderedJobQueue job` called twice; the second call must not
error), enqueues one grouped message, drains it with an ordered tuning, and asserts the queue is
empty afterward:

```haskell
    it "ensureOrderedJobQueue is idempotent and the queue accepts grouped work" $ \connStr -> do
        let job = mkJob "keiro_pgmq_test.ordered_setup"
        len <-
            runDb connStr $ do
                ensureOrderedJobQueue job
                ensureOrderedJobQueue job        -- second call must not error
                _ <- enqueueToGroup job "g1" (Ping "x" 1)
                _ <- runJobOnceWithContext (withOrdering FifoThroughput defaultJobTuning) 1 job
                        (\_ctx _p -> pure Done)
                queueLen job.jobQueue.physicalName
        len `shouldBe` 0
```

Commands and acceptance: `cabal test keiro-pgmq-test` from the repository root. Both new
examples pass; all earlier examples still pass.

### Milestone M4 — end-to-end ordering proof

Scope: prove the headline guarantee — strict within-group order and full drainage — on the
deterministic drain path, plus a worker-path ordering smoke test. At the end of M4 the suite
contains a test that fails on an unordered drain and passes on an ordered one.

The deterministic mechanics, chosen so the test is not flaky:

- One ordered queue. Enqueue, in send order, group `"a"` messages `a1, a2, a3` and group `"b"`
  messages `b1, b2`. Encode each payload so its identity is recoverable — reuse `Ping`, setting
  `message` to the label (`"a1"`, `"a2"`, …). Enqueue them interleaved or in any order across
  groups; what matters is the per-group send order (`a1` before `a2` before `a3`; `b1` before
  `b2`).
- Provision with `ensureOrderedJobQueue job` so the FIFO index exists.
- Drain single-threaded with `runJobOnceWithContext (withOrdering FifoThroughput
  defaultJobTuning) 5 job handler`. Use `defaultJobTuning`'s 30-second visibility timeout
  (ample: the handler does no I/O and finishes in microseconds, so no message's visibility ever
  expires mid-drain and no message is re-read). The drain reads up to `n = 5` messages and the
  queue holds exactly 5, so a single drain empties it; there is no second-poll race.
- The handler records each observed payload label into an ordered log:
  `liftIO (modifyIORef' observed (\xs -> xs ++ [payload.message]))` (or push-and-reverse), then
  returns `Done`.
- Assertions:
  - The drain return value equals 5 (every message handled exactly once in this single drain).
  - `queueLen job.jobQueue.physicalName` is 0 (full drainage).
  - The subsequence of the observed log restricted to `"a*"` labels is exactly `["a1","a2","a3"]`
    (strict within-group order for `"a"`), and restricted to `"b*"` labels is exactly
    `["b1","b2"]` (strict within-group order for `"b"`).
  - **Do not** assert any cross-group order: the relative position of `"a"` and `"b"` labels in
    the log is left unconstrained, because `FifoThroughput` fills from the oldest eligible group
    first and the cross-group interleaving is not a guaranteed property.

A concrete sketch:

```haskell
    it "FifoThroughput drain preserves strict within-group order and fully drains" $ \connStr -> do
        observed <- newIORef ([] :: [Text])
        let job = mkJob "keiro_pgmq_test.fifo_order"
        drained <-
            runDb connStr $ do
                ensureOrderedJobQueue job
                _ <- enqueueToGroup job "a" (Ping "a1" 1)
                _ <- enqueueToGroup job "b" (Ping "b1" 1)
                _ <- enqueueToGroup job "a" (Ping "a2" 2)
                _ <- enqueueToGroup job "a" (Ping "a3" 3)
                _ <- enqueueToGroup job "b" (Ping "b2" 2)
                runJobOnceWithContext (withOrdering FifoThroughput defaultJobTuning) 5 job
                    \_ctx payload -> do
                        liftIO $ modifyIORef' observed (<> [payload.message])
                        pure Done
        log' <- readIORef observed
        drained `shouldBe` 5
        len <- runDb connStr (queueLen job.jobQueue.physicalName)
        len `shouldBe` 0
        filter (Text.isPrefixOf "a") log' `shouldBe` ["a1", "a2", "a3"]
        filter (Text.isPrefixOf "b") log' `shouldBe` ["b1", "b2"]
```

`modifyIORef'`, `newIORef`, `readIORef`, `Text.isPrefixOf`, and `liftIO` are already imported in
`Main.hs`. To convince yourself the test is meaningful, temporarily change `FifoThroughput` to
`Unordered`: the within-group subsequence assertions may still pass by luck on a single-threaded
empty-queue drain (plain `read` is `msg_id`-ascending, which happens to preserve send order for
a single drainer), so to *prove* ordering you should instead rely on the worker-path smoke test
below for the concurrent contrast and treat the drain test as the deterministic regression lock
on the grouped-read wiring. The drain test's load-bearing assertion is that the grouped read
path returns every message and preserves per-group order; it would fail if the grouped read
dropped or reordered within a group.

Worker-path ordering smoke test: enqueue `a1, a2, a3` to group `"a"` only (a single group makes
the worker path deterministic for within-group order even under concurrency, because the group's
later messages cannot be returned while an earlier one is in-flight). Run
`jobProcessorWithContext (withOrdering FifoThroughput tuning) job handler` through
`runJobWorkers` (mirroring the existing `"runJobWorkers processes an enqueued message"` example:
`IgnoreFailures`, inbox 16, `waitUntil` on a completion flag, then `stopAppQuickly`). Use a
short polling cadence (`mkJobTuning 30 1 (PollEvery 0.1)`, then `withOrdering FifoThroughput`)
and a handler that appends the label to a shared `IORef` and signals done when it has seen three
labels. Assert the observed `"a*"` subsequence is `["a1","a2","a3"]` and the queue is empty.
Keep the visibility timeout (30 s) comfortably larger than the handler's runtime so no message
is redelivered mid-test.

Commands and acceptance: `cabal test keiro-pgmq-test` from the repository root; both M4 examples
pass alongside everything from M1–M3.


## Concrete Steps

Run everything from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

First, confirm EP-1 and EP-2 have landed and the starting state is green, so you can attribute
any later failure to your change:

```bash
grep -n "enqueueWithHeaders\|ensureFifoIndex\|ensureJobQueueWith" keiro-pgmq/src/Keiro/PGMQ/Job.hs
cabal build keiro-pgmq
cabal test keiro-pgmq-test
```

Expected: the grep prints the EP-1 and EP-2 names from the export list and their definitions;
the build succeeds; the existing suite is green. A typical test tail:

```text
Keiro.PGMQ
  ... (existing examples) ...
Finished in N.NNNN seconds
NN examples, 0 failures
```

If the grep finds neither EP-1 nor EP-2 names, those plans have not landed; consult the
reconcile notes in Interfaces and Dependencies before proceeding, and record the path you took
in the Decision Log.

Then implement M1 (the `JobOrdering` type, the `JobTuning` field, `withOrdering`, `toFifoConfig`,
the `adapterConfigFor` wiring, the imports and exports). Rebuild and test:

```bash
cabal build keiro-pgmq
cabal test keiro-pgmq-test
```

Expected: clean build, same example count as before, zero failures. If GHC reports a missing
field on a `JobTuning{...}` literal, you have an unfixed record-literal construction site — add
`ordering = Unordered` to it (re-run the grep from M1 step 9 to find it).

Implement M2 (the grouped-read imports and the `drain` read dispatch). Rebuild and test:

```bash
cabal test keiro-pgmq-test
```

Expected: clean build, no regression. If GHC says `readGrouped`/`ReadGrouped` are not in scope,
you imported them from the `Pgmq.Effectful` umbrella by mistake — they live only in
`Pgmq.Effectful.Effect`.

Implement M3 (the `enqueueToGroup` producers, `groupHeader`, `ensureOrderedJobQueue`, the aeson
import additions, the exports) and add the two M3 examples. Test:

```bash
cabal test keiro-pgmq-test
```

Expected (excerpt):

```text
  enqueueToGroup writes the x-pgmq-group header
  ensureOrderedJobQueue is idempotent and the queue accepts grouped work
```

both passing.

Implement M4 (the drain ordering test and the worker-path smoke test). Test:

```bash
cabal test keiro-pgmq-test
```

Expected final tail (example count illustrative; the point is zero failures):

```text
  enqueueToGroup writes the x-pgmq-group header
  ensureOrderedJobQueue is idempotent and the queue accepts grouped work
  FifoThroughput drain preserves strict within-group order and fully drains
  FifoThroughput worker path preserves within-group order
Finished in N.NNNN seconds
NN examples, 0 failures
```


## Validation and Acceptance

Acceptance is behavioral, phrased as observable input/output, and proven by the suite. After all
milestones, `cabal test keiro-pgmq-test` (run from `/Users/shinzui/Keikaku/bokuno/keiro`) must
report zero failures with the new examples present.

The headline proof is the M4 drain example `"FifoThroughput drain preserves strict within-group
order and fully drains"`: it enqueues `a1, a2, a3` to group `"a"` and `b1, b2` to group `"b"`,
drains once with `FifoThroughput`, and observes that the handler saw `["a1","a2","a3"]` for group
`"a"` and `["b1","b2"]` for group `"b"` (each as an ordered subsequence of the observed log) and
that the queue drained fully (`drained == 5`, `queueLen == 0`). The example asserts only the
within-group order and full drainage; it deliberately does not assert any cross-group order,
because cross-group interleaving is not a guaranteed property of either FIFO strategy. The
worker-path smoke example `"FifoThroughput worker path preserves within-group order"` confirms
the same within-group guarantee end-to-end through `runJobWorkers` for a single group, where
ordering is deterministic even under concurrency because a group's later message cannot be
returned while an earlier one is in-flight.

The M3 examples prove the plumbing the M4 proof depends on. `"enqueueToGroup writes the
x-pgmq-group header"` reads the raw message back and observes the literal `x-pgmq-group` key with
the group value — the exact wire contract PGMQ and the shibuya adapter key on.
`"ensureOrderedJobQueue is idempotent and the queue accepts grouped work"` calls the setup twice
without error and then round-trips a grouped message to length 0, proving the FIFO index creation
neither fails on re-apply nor breaks the queue.

Each new example would fail before the corresponding code exists — the function would not be in
scope, the ordered drain would not compile, or (for the ordering assertion) a broken grouped-read
wiring would drop or reorder messages — and passes after, which is the "effective beyond
compilation" evidence the specification requires. The pre-existing unordered examples (every
`runJobOnce`/`runJobOnceWithContext`/`jobProcessor` example, all of which use `defaultJobTuning`
or `mkJobTuning`, i.e. `Unordered`) continue to pass unchanged, confirming the new field and the
drain dispatch did not disturb the historical path.


## Idempotence and Recovery

Every step is additive Haskell-source editing and is safe to repeat: re-running `cabal build
keiro-pgmq` and `cabal test keiro-pgmq-test` after an edit simply rebuilds and re-tests. The
test harness gives each example a fresh, isolated database (`Postgres.withFreshDatabase`), so
re-running the suite never accumulates state and examples do not interfere.

The only breaking change is adding the strict `ordering` field to `JobTuning` (M1). If the build
fails after that edit, the cause is an un-updated `JobTuning{...}` record literal; re-run `grep
-rn "JobTuning\|mkJobTuning" --include='*.hs' . | grep -v dist-newstyle` and add `ordering =
Unordered` to any record-literal site (the `mkJobTuning` *calls* are unaffected because the
smart constructor's arity is preserved). To roll back any milestone, revert the corresponding
edits to `keiro-pgmq/src/Keiro/PGMQ/Job.hs` and `keiro-pgmq/test/Main.hs`; because every change
is additive except the single internal `JobTuning` field, reverting cannot leave a partially
broken public surface for downstream consumers.

`ensureOrderedJobQueue` is idempotent: it composes EP-2's `ensureJobQueue` (PGMQ's `createQueue`
is idempotent) and `ensureFifoIndex` (the FIFO-index SQL is `CREATE INDEX IF NOT EXISTS`,
re-applied harmlessly), so calling it at every startup is safe — the M3 test asserts exactly this
by calling it twice. `enqueueToGroup` is a pure specialization of EP-1's `enqueueWithHeaders` and
sends one message per call; it carries no extra state.

If `cabal test` cannot start a PostgreSQL server (the suite needs an ephemeral Postgres via
`keiro-test-support`), that is an environment issue, not a regression; the type-level changes
still validate via `cabal build keiro-pgmq`. The ordering, grouped-read, and FIFO-index
assertions require the database and must be run where the ephemeral Postgres is available.


## Interfaces and Dependencies

All new public surface lives in the module `Keiro.PGMQ.Job` (`keiro-pgmq/src/Keiro/PGMQ/Job.hs`)
and is re-exported automatically by the umbrella `Keiro.PGMQ` (`keiro-pgmq/src/Keiro/PGMQ.hs`),
which already re-exports `module Keiro.PGMQ.Job` in full. No edit to the umbrella module is
needed. No new Cabal build dependency is needed: `aeson` (for `Value`/`object`/`.=`),
`pgmq-effectful` (for `MessageHeaders`, the grouped-read ops and `ReadGrouped`), and
`shibuya-pgmq-adapter` (for `FifoConfig`/`FifoReadStrategy`) are already listed in
`keiro-pgmq/keiro-pgmq.cabal`'s library `build-depends`.

The exact final new public signatures EP-3 adds, all with module path `Keiro.PGMQ.Job` (and
re-exported from `Keiro.PGMQ`):

```haskell
-- The FIFO read strategy (Milestone M1).
data JobOrdering
    = Unordered       -- ^ Plain read; no per-key delivery-order guarantee.
    | FifoThroughput  -- ^ read_grouped: SQS-style batch filling, strict per-group order.
    | FifoRoundRobin  -- ^ read_grouped_rr: fair round-robin across groups, strict per-group order.
    deriving stock (Eq, Show)

-- JobTuning, extended with the ordering field (Milestone M1):
data JobTuning = JobTuning
    { visibilityTimeout :: !Int32
    , batchSize         :: !Int32
    , polling           :: !JobPolling
    , ordering          :: !JobOrdering
    }
    deriving stock (Eq, Show)

-- Set the ordering on an existing tuning (Milestone M1):
withOrdering :: JobOrdering -> JobTuning -> JobTuning

-- Group-keyed producers (Milestone M3), built on EP-1's enqueueWithHeaders family:
enqueueToGroup ::
    (Pgmq :> es, IOE :> es) =>
    Job p -> Text -> p -> Eff es MessageId

enqueueToGroupWithDelay ::
    (Pgmq :> es, IOE :> es) =>
    Job p -> Int32 -> Text -> p -> Eff es MessageId

-- Ordered queue setup (Milestone M3): create the queue (and DLQ) plus the FIFO index.
ensureOrderedJobQueue :: (Pgmq :> es) => Job p -> Eff es ()
```

`mkJobTuning` and `defaultJobTuning` keep their published shapes: `mkJobTuning :: Int32 -> Int32
-> JobPolling -> Either JobTuningConfigError JobTuning` (arity unchanged; the new field defaults
to `Unordered`), and `defaultJobTuning :: JobTuning` (now `Unordered`).

Internal (non-exported) changes:

- `toFifoConfig :: JobOrdering -> Maybe FifoConfig` — the worker-path mapper used in
  `adapterConfigFor`, which now sets `fifoConfig = toFifoConfig tuning.ordering` on the
  `PgmqAdapterConfig`. (`adapterConfigFor :: JobTuning -> Job p -> PgmqAdapterConfig`, signature
  unchanged.)
- `groupHeader :: Text -> MessageHeaders` — `MessageHeaders (object ["x-pgmq-group" .= k])`,
  the literal-key helper behind `enqueueToGroup`.
- `runJobOnceWithContext`'s inner `drain` loop now dispatches the read on `tuning.ordering`:
  `Unordered` keeps `Pgmq.readMessage`; `FifoThroughput` calls `readGrouped`; `FifoRoundRobin`
  calls `readGroupedRoundRobin`. The function's public signature is unchanged
  (`runJobOnceWithContext :: JobTuning -> Int -> Job p -> (JobContext es -> p -> Eff es
  JobOutcome) -> Eff es Int`).

The library symbols EP-3 depends on, with full module paths and why:

- `readGrouped :: (Pgmq :> es) => ReadGrouped -> Eff es (Vector Message)` and
  `readGroupedRoundRobin :: (Pgmq :> es) => ReadGrouped -> Eff es (Vector Message)`, with the
  request record `data ReadGrouped = ReadGrouped { queueName :: QueueName, visibilityTimeout ::
  Int32, qty :: Int32 }` — the grouped reads for the drain path. All three are exported from
  `Pgmq.Effectful.Effect` (package `pgmq-effectful`,
  `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-effectful/src/Pgmq/Effectful/Effect.hs`)
  and **NOT** from the `Pgmq.Effectful` umbrella; import them from
  `Pgmq.Effectful.Effect` directly. `ReadGrouped` has no `conditional` field.
- `FifoConfig (..)` and `FifoReadStrategy (..)` (`data FifoConfig = FifoConfig { readStrategy ::
  FifoReadStrategy }`; `data FifoReadStrategy = ThroughputOptimized | RoundRobin`) — the
  adapter's FIFO config for the worker path. Exported from `Shibuya.Adapter.Pgmq` (package
  `shibuya-pgmq-adapter`,
  `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs`,
  re-exported through `Shibuya.Adapter.Pgmq`). The adapter already selects
  `read_grouped`/`read_grouped_rr` from `PgmqAdapterConfig.fifoConfig` (`Internal.hs`) and keys
  the group on the literal `x-pgmq-group` header (`Convert.extractPartition`), so the worker path
  is config plumbing, not new read code.
- `object`, `(.=)`, `Value` from `aeson` (`Data.Aeson`) — to build the `x-pgmq-group` header.

Hard dependency on EP-1 (MasterPlan #10, Integration Point 2). EP-3 consumes EP-1's
`enqueueWithHeaders :: (Pgmq :> es, IOE :> es) => Job p -> MessageHeaders -> p -> Eff es
MessageId` (and `enqueueWithHeadersAndDelay :: (Pgmq :> es, IOE :> es) => Job p -> Int32 ->
MessageHeaders -> p -> Eff es MessageId`), defined in `Keiro.PGMQ.Job`
(`docs/plans/75-add-message-headers-trace-propagation-and-batch-enqueue-to-keiro-pgmq-producers.md`).
`enqueueToGroup job groupKey p = enqueueWithHeaders job (groupHeader groupKey) p`, so the
argument order `Job -> MessageHeaders -> p` must hold and EP-1 must leave `x-pgmq-group`
untouched (its Decision Log records that no-reserve contract). **Reconcile note:** if EP-1 has
not landed when EP-3 starts, build `enqueueToGroup`/`enqueueToGroupWithDelay` against these
documented signatures; if EP-1's final `enqueueWithHeaders` shape differs, update this section,
the M3 step, and MasterPlan #10's Integration Point 2 before proceeding, and record it in the
Decision Log.

Hard dependency on EP-2 (MasterPlan #10, Integration Point 3). EP-3 consumes EP-2's
`ensureFifoIndex :: (Pgmq :> es) => Job p -> Eff es ()` and the pre-existing `ensureJobQueue ::
(Pgmq :> es) => Job p -> Eff es ()` (EP-2 re-expresses it as `ensureJobQueueWith
standardProvision`), both in `Keiro.PGMQ.Job`
(`docs/plans/76-add-partitioned-and-unlogged-queue-provisioning-with-fifo-indexes-to-keiro-pgmq.md`).
`ensureOrderedJobQueue job = ensureJobQueue job >> ensureFifoIndex job`. **Reconcile note:** if
EP-2 has not landed when EP-3 starts, EP-3 may, per Integration Point 3, call the raw op
`createFifoIndex :: (Pgmq :> es) => QueueName -> Eff es ()` directly (imported as `import
"pgmq-effectful" Pgmq.Effectful.Effect (createFifoIndex)`, since it is not in the `Pgmq.Effectful`
umbrella) on `job.jobQueue.physicalName` after the existing `ensureJobQueue`, and leave a
reconcile note to route through EP-2's `ensureFifoIndex` once it lands. Record the path taken in
the Decision Log.

Frozen shapes (MasterPlan #10, Integration Point 4). EP-3 reads but does not modify the fields
of `Job` (`jobName`, `jobQueue :: QueueRef`, `jobCodec :: JobCodec p`, `jobPolicy ::
RetryPolicy`) or `QueueRef` (`logicalName`, `physicalName :: QueueName`, `dlqName :: QueueName`)
from `keiro-pgmq/src/Keiro/PGMQ/Job.hs` and `keiro-pgmq/src/Keiro/PGMQ/Runtime.hs`. The only
record EP-3 changes is `JobTuning`, which is constructed solely inside keiro-pgmq and so is safe
to extend.

Soft dependency on EP-4 (MasterPlan #10). EP-4
(`docs/plans/78-add-queue-metrics-and-archive-retention-api-to-keiro-pgmq.md`) provides the
metrics surface that would let an operator observe a FIFO queue's per-group backlog. EP-3 does
not require EP-4 to compile or pass tests; if EP-4 has not landed, observe a FIFO queue's depth
with the raw `Pgmq.queueMetrics job.jobQueue.physicalName` call (already used by the suite's
`queueLen` helper).

Sibling plans referenced by path only:
`docs/plans/75-add-message-headers-trace-propagation-and-batch-enqueue-to-keiro-pgmq-producers.md`
(EP-1), `docs/plans/76-add-partitioned-and-unlogged-queue-provisioning-with-fifo-indexes-to-keiro-pgmq.md`
(EP-2), `docs/plans/78-add-queue-metrics-and-archive-retention-api-to-keiro-pgmq.md` (EP-4), and
the MasterPlan
`docs/masterplans/10-keiro-pgmq-queue-feature-expansion-fifo-ordering-headers-provisioning-observability.md`.
