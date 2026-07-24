# Work Queues

The `keiro-pgmq` package gives an application a typed background-job queue on
top of [PGMQ](https://github.com/pgmq/pgmq) (the PostgreSQL-native message
queue) and Shibuya's worker framework. You declare a `Job` value bundling a
queue, a payload codec, and a retry policy, then write a plain domain handler of
type `p -> Eff es JobOutcome`. The package absorbs the boilerplate: PGMQ wire
types, Shibuya's `Ingested`/`AckDecision` vocabulary, dead-letter routing, and
queue-name derivation never reach your handler.

This is a separate package from `keiro`. Add `keiro-pgmq` to `build-depends` and
import `Keiro.PGMQ` for the whole surface, or the individual modules
(`Keiro.PGMQ.Runtime`, `.Codec`, `.Job`, `.Dlq`, `.Metrics`).

## Work queue or outbox?

Keiro has two durable handoffs and they solve different problems.

| | `keiro-pgmq` work queue | [Transactional outbox](outbox.md) |
|---|---|---|
| Atomic with a command append | **No** — the enqueue runs on its own connection pool | **Yes** — the row is written in the append transaction |
| What it carries | a job payload for *this* service to process | an integration event for *another* bounded context |
| Delivery | at-least-once, in-database | at-least-once, drained to Kafka |
| Ordering | none by default; per-group FIFO available | per-key head-of-line by default |

The distinction that matters: `enqueue` is **not** transactional with a Kiroku
event append. The `Pgmq` effect is interpreted over its own `hasql` pool, so a
crash between a committed append and an `enqueue` loses the job. When the work
must not be lost if the command commits, write an outbox row (or, for
read-model-driven fan-out, use the DSL's `dispatch` node, which dedupes against
a read model and the queue itself) rather than enqueuing inline.

Use a work queue for work the service owes *itself* and can re-derive or
tolerate re-running: thumbnail generation, notification sends, periodic
reconciliation, fan-out of already-durable facts.

## The Job declaration

```haskell
import Keiro.PGMQ

data ThumbnailRequest = ThumbnailRequest
  { assetId :: Text
  , width   :: Int
  }
  deriving stock (Generic)
  deriving anyclass (ToJSON, FromJSON)

thumbnailJob :: Job ThumbnailRequest
thumbnailJob = Job
  { jobName   = "thumbnails"          -- ProcessorId and telemetry label
  , jobQueue  = queueRef "media.thumbnails"
  , jobCodec  = aesonJobCodec
  , jobPolicy = defaultRetryPolicy
  }
```

`queueRef` derives PGMQ-legal physical names from a logical one. PGMQ caps queue
names at 47 characters and rejects anything outside `[a-z0-9_]`, so the helper
lower-cases, replaces illegal characters with `_`, collapses repeated
underscores, and guarantees a leading letter. `queueRef "media.thumbnails"`
yields `physicalName = "media_thumbnails"` and
`dlqName = "media_thumbnails_dlq"`; the queue's table is `pgmq.q_<physical>`.

Two rules follow from that derivation:

- **Sanitization equivalence is intentional.** `"a.b"` and `"a_b"` name the same
  queue. Distinct logical queues must differ after lower-casing and replacing
  illegal characters.
- **Long or `_dlq`-suffixed names are hashed.** When the sanitized base exceeds
  43 characters, or ends in `_dlq`, the physical name becomes
  `<first 26 chars>_<16 hex chars>` where the suffix is FNV-1a-64 over the full
  logical name. This keeps the derived DLQ name under the 47-character ceiling
  and guarantees main-queue names never end in `_dlq`. A deployment whose
  sanitized name was previously over-long derives a *different* physical queue
  after upgrading: drain the old queue first, or run a worker against the old
  physical name until it empties. Messages are not lost, but new workers will
  not see them.

## The runtime

`withJobRuntime` owns a Hasql pool and an optional OpenTelemetry tracer;
`runJobEff` interprets the effect stack against it and surfaces PGMQ failures as
a `Left`.

```haskell
withJobRuntime connectionString (Just tracer) $ \runtime -> do
  result <- runJobEff runtime $ do
    ensureJobQueue thumbnailJob
    _ <- enqueue thumbnailJob (ThumbnailRequest "asset-1" 320)
    pure ()
  either (fail . show) pure result
```

The stack `runJobEff` interprets is
`'[Reader PgmqAdapterEnv, Pgmq, Tracing, Error PgmqRuntimeError, IOE]`. Passing
`Nothing` for the tracer selects the no-op tracing interpreter, and processing
behaviour is identical — tracing is opt-in exactly like `RunCommandOptions.tracer`
on the command path.

## Producing work

All producers encode with the job's codec and return the PGMQ `MessageId`.

- `enqueue job p` — send now.
- `enqueueWithDelay job seconds p` — invisible until the delay elapses.
- `enqueueBatch job ps` / `enqueueBatchWithDelay` — one database round-trip for
  many payloads, returning one id per payload in order. An empty list issues no
  statement.
- `enqueueWithHeaders job headers p` / `enqueueWithHeadersAndDelay` /
  `enqueueBatchWithHeaders` — attach an arbitrary JSON header object, passed
  through verbatim.
- `enqueueTraced provider job extraHeaders p` / `enqueueTracedWithDelay` —
  inject the current W3C trace context into the message headers so the handler's
  span continues the producer's trace across processes. Keys already present in
  `extraHeaders` win, so a caller-set group key survives. Pass
  `MessageHeaders (object [])` to inject only the trace.
- `enqueueToGroup job groupKey p` / `enqueueToGroupWithDelay` — FIFO group
  routing (see [FIFO groups](#fifo-groups-and-ordering)).

## Consuming work

There are two execution shapes. They are different runtimes, not two entry
points onto one runtime, and the choice is a real one.

### Continuous workers

`jobProcessor` (or `jobProcessorWithContext` for explicit tuning) builds a
Shibuya processor; `runJobWorkers` runs a supervised app over several of them.

```haskell
result <- runJobWorkers
  StopAllOnFailure
  16                                  -- inbox size, clamped to >= 1
  [ jobProcessor thumbnailJob handleThumbnail
  , jobProcessor emailJob     handleEmail
  ]

handleThumbnail :: ThumbnailRequest -> Eff es JobOutcome
handleThumbnail req = do
  renderThumbnail req
  pure Done
```

`runJobWorkers` returns an `Either AppError (AppHandle es)`; the caller decides
whether to block on the handle. `SupervisionStrategy` is `IgnoreFailures` (a
failed processor is marked failed but its siblings keep running) or
`StopAllOnFailure` (any failure shuts every processor down; graceful exits and
`AckHalt` do not).

This path owns an inbox, a concurrency limit, graceful shutdown, and
finalization retries. It is the shape for a long-running worker process.

### One-shot drain

`runJobOnce n job handler` reads directly from PGMQ and returns when the queue
is empty or `n` messages have been settled, whichever comes first.
`runJobOnceWithContext` adds explicit tuning, a context-aware handler, and
returns the number handled.

```haskell
handled <- runJobOnceWithContext tuning 100 thumbnailJob $ \ctx req -> do
  ctx.extendLease 60      -- this one will take a while
  renderThumbnail req
  pure Done
```

Use this shape for a cron-driven drain, a test, or a request-scoped flush. It
has no inbox, no concurrency, and no supervisor.

One behavioural difference worth internalizing: **if a handler throws on the
drain path, the drain issues no finalizer call.** The message stays invisible
until its visibility timeout expires, the drain continues with the rest of the
batch, and that message is not counted in the returned total. The continuous
path instead substitutes an `AckRetry` so the adapter always observes a
finalization.

### Tuning

```haskell
data JobTuning = JobTuning
  { visibilityTimeout :: Int32       -- seconds
  , batchSize         :: Int32
  , polling           :: JobPolling
  , ordering          :: JobOrdering
  }
```

`defaultJobTuning` is a 30-second visibility timeout, a batch of 1, `PollEvery 1`
(one-second sleeps between empty polls), and `Unordered` reads. `JobPolling` is
either `PollEvery interval` or `LongPoll maxPollSeconds pollIntervalMs`, which
waits inside the database instead of sleeping.

Prefer `mkJobTuning visibilityTimeout batchSize polling`, which rejects
non-positive values, then layer ordering on with
`withOrdering FifoThroughput`. The raw constructor is exported but unvalidated.

### The job context

`jobProcessorWithContext` and `runJobOnceWithContext` hand the handler a
`JobContext`:

- `extendLease :: NominalDiffTime -> Eff es ()` — push the visibility timeout
  further out. A handler that may exceed `visibilityTimeout` **must** call this
  or PGMQ can redeliver the message concurrently, and each redelivery consumes a
  retry attempt.
- `attempt :: Maybe Word` — zero-based delivery attempt; `Just 0` is the first
  delivery.
- `headers :: Maybe Value` — the raw PGMQ header object. **Drain path only.** On
  the worker path this is always `Nothing`, because Shibuya's `Envelope` surfaces
  only the trace context, not arbitrary headers. If a handler needs to read
  custom headers, use the drain path or put the data in the payload.

## Retry, dead-letter, and poison payloads

A handler returns a `JobOutcome`:

| Outcome | Effect |
|---|---|
| `Done` | delete the message |
| `Retry delay` | leave it queued; redeliver after `delay` |
| `RetryDefault` | leave it queued; redeliver after the policy's `defaultRetryDelay` |
| `Dead reason` | route to the DLQ with `reason` (or archive it when the policy has no DLQ) |

The policy controls the ceiling:

```haskell
data RetryPolicy = RetryPolicy
  { maxRetries        :: Int64
  , defaultRetryDelay :: RetryDelay
  , useDeadLetter     :: Bool
  }
```

`defaultRetryPolicy` is five deliveries, a 60-second default retry delay, and a
DLQ enabled. Prefer `mkRetryPolicy maxRetries delay useDeadLetter`: the raw
constructor is unvalidated, and `maxRetries <= 0` dead-letters **every** message
before the handler runs, because PGMQ's `read_ct` is already 1 on first delivery
and the adapter auto-dead-letters when `read_ct > maxRetries`. Negative delays
can create redelivery storms.

Three semantics are easy to conflate:

- **Delivery is at-least-once.** The same message can arrive again after a worker
  crash, a handler exception, or a visibility-timeout expiry. Handlers must be
  idempotent. There is no deduplication.
- **Crash redelivery is paced by the visibility timeout, not the retry delay.**
  `defaultRetryDelay` applies only to explicit `Retry` and `RetryDefault`
  outcomes.
- **Every visibility-timeout expiry consumes one attempt.** A message whose read
  count exceeds `maxRetries` is dead-lettered *before the handler sees it*, with
  reason `max_retries_exceeded`.

A payload the codec rejects as malformed is dead-lettered as
`invalid_payload: <error>` without running the handler. A payload from a newer
schema version is retried instead — see below.

Dead-lettering sends the DLQ row and then deletes the main-queue row, so a crash
between those two statements can leave the message in both places. `redriveDlq`
has the same at-least-once window in the other direction. This is another reason
handlers must be idempotent.

## Payload codecs and evolution

A `JobCodec p` is the adapter between the domain payload and PGMQ's JSON body.
Two ship with the package:

- `aesonJobCodec` — raw `ToJSON`/`FromJSON`. Use it when the payload type already
  has instances and you do not need versioned evolution.
- `keiroJobCodec codec` — the versioned upgrade. It wraps payloads as
  `{ "v": <schemaVersion>, "t": <event-type>, "data": <payload> }` and replays
  the [keiro `Codec`](codecs-and-event-evolution.md) upcaster chain on decode,
  giving job payloads the same schema-evolution story event streams have. Legacy
  envelopes without `"t"` still decode for single-event codecs.

`mkJobCodec encode decode` builds one from a hand-written pair.

When you raise a `keiroJobCodec` schema version, **deploy workers before
producers**. A worker reading an envelope from a future version gets
`JobPayloadFromFuture` and the runner retries it after the policy's default
delay so a rolling deploy can finish — but those retries still consume delivery
attempts, so size `maxRetries * defaultRetryDelay` to cover the rollout window.
See [Deploy Ordering](deploy-ordering.md#3-upgrade-versioned-job-workers-before-producers).

Never switch a **non-empty** queue directly between `aesonJobCodec` and
`keiroJobCodec`: the wire shape changes from a bare payload to the
`{v,t,data}` envelope, so old in-flight messages become malformed and are
dead-lettered. Drain the queue first, or run a transitional codec that accepts
both shapes.

## FIFO groups and ordering

`Unordered` (the default) is PGMQ's plain read: FIFO only in selection order, with
**no** per-key delivery-order guarantee under concurrent workers, retries, or
visibility-timeout expiry.

For strict per-key ordering, enqueue into a group and consume with an ordered
tuning:

```haskell
_ <- enqueueToGroup thumbnailJob (assetIdText assetId) request

let tuning = withOrdering FifoThroughput defaultJobTuning
```

The group key rides in PGMQ's reserved `x-pgmq-group` JSONB header. Within one
group messages are delivered in strict send order; distinct groups proceed in
parallel. `FifoThroughput` fills a batch from the oldest eligible group first
(SQS-style); `FifoRoundRobin` interleaves fairly across groups.

Delivery is still at-least-once and there is still no deduplication — ordering
is not exactly-once. Ordered reads also require the FIFO GIN index on the
queue's `headers` column; provision it (below) or grouped reads will not match.

## Queue provisioning and migrations

### The PGMQ schema

`keiro-migrate` composes the Kiroku and Keiro components only; it does **not**
install PGMQ. An application that uses work queues appends PGMQ's own native
component to its plan:

```haskell
import Pgmq.Migration qualified as Pgmq

plan = do
  kiroku <- Kiroku.kirokuMigrations
  keiro  <- keiroMigrations
  pgmq   <- Pgmq.pgmqMigrations
  migrationPlan (kiroku :| [keiro, pgmq])
```

That keeps one `pgmigrate` ledger over kiroku, keiro, and pgmq together. See
[Migration Ownership](migration-ownership.md#application-components). Test
suites get the same shape from `keiro-test-support`:
`withMigratedSuiteWith [pgmqMigrations] $ \fixture -> ...`.

### The queues themselves

Queue creation is a runtime concern, not a migration: `ensureJobQueue job`
creates the main queue and (when the policy enables one) the DLQ. It routes
through `pgmq-config`'s additive reconciler, which lists existing queues first
and creates only what is missing, so it is safe to call at every worker startup.

`ensureJobQueueWith provision job` chooses the storage shape:

| Provision | Storage |
|---|---|
| `standardProvision` | a normal write-ahead-logged queue table (the default) |
| `unloggedProvision` | an *unlogged* table: writes skip the WAL, but the table is **truncated on a database crash**. Only for transient, regenerable work. |
| `partitionedProvision (PartitionSpec interval retention)` | storage split across child tables by time or id range, managed by `pg_partman`. Requires a `pg_partman`-enabled server. |

`withFifoIndexProvision` turns on the FIFO GIN index for any of them. The DLQ is
always a plain standard queue with no FIFO index. `ensureOrderedJobQueue` is the
convenience composition for ordered jobs (queue + DLQ + index), and
`ensureFifoIndex` adds just the index to an already-provisioned queue.
`queueProvisionConfigs` exposes the resulting configuration list, so the
partitioned path is testable without a `pg_partman` server.

## Operating the dead-letter queue

PGMQ does not expire DLQ rows on its own. The retention model is
archive-then-purge.

```haskell
entries <- readDlq thumbnailJob 20        -- inspect, 30s visibility timeout
moved   <- redriveDlq thumbnailJob 20     -- send back to the main queue
kept    <- archiveDlq thumbnailJob 20     -- retain in pgmq.a_<dlq>
purgeDlq thumbnailJob                     -- delete everything, permanently
```

A `DlqEntry p` carries the DLQ row's own `dlqMessageId`, the `reason`
(`poison_pill: ...`, `invalid_payload: ...`, or `max_retries_exceeded`), the
preserved `originalPayload` decoded with the job's codec, the original message
id / enqueue time / read count when present, and `rawBody` for forensics. The
required wrapper keys are `original_message` and `dead_letter_reason`; the
metadata keys are treated as optional so legacy or hand-written rows still
inspect cleanly. A malformed wrapper is reported as
`malformed_dlq_payload: <error>` and left in place rather than redriven.

Redriven messages start a fresh PGMQ `read_ct` on the main queue. `archiveDlq`
moves rows into `pgmq.a_<dlq>`, preserving `enqueued_at`/`read_ct` and stamping
`archived_at`; `archiveDlqEntry` archives one row by id. Operators who need an
audit trail archive and then purge; operators who do not can purge alone.

Fix the cause before redriving. A redrive against unchanged code re-runs the
same failure and burns the attempt budget again.

## Metrics and tracing

`Keiro.PGMQ.Metrics` reads PGMQ's own `metrics()` function, keyed by job so no
caller derives a physical name:

- `jobQueueMetrics job` — the main queue's `QueueMetrics` (`queueLength`,
  `queueVisibleLength`, `oldestMsgAgeSec`, `newestMsgAgeSec`, `totalMessages`).
- `queueDepth job` — the main queue's `queueVisibleLength`: work waiting *now*.
- `jobDlqMetrics job` — the DLQ's metrics. **Alert on its `queueLength`**; that
  is the signal the DLQ helpers above are written for.
- `allJobMetrics` — every queue's metrics (not job-keyed).

These are Keiro-independent of the `keiro.*` OpenTelemetry instrument set in
[Operations](operations.md#metric-catalogue); a work queue reports through PGMQ's
own tables, not through `KeiroMetrics`.

Tracing follows one contract on both execution shapes: every delivery runs inside
exactly one Consumer-kind span named `<jobName> process`, carrying
`messaging.system=shibuya`, `messaging.destination.name=<jobName>`,
`messaging.operation.type=process`, `messaging.message.id`, `shibuya.partition`
for FIFO deliveries, and `shibuya.ack.decision` once the message is actually
finalized. A message enqueued with `enqueueTraced` continues the producer's trace
across processes.

Two differences are deliberate: the drain path emits no
`shibuya.inflight.count`/`shibuya.inflight.max` (it has no inbox or concurrency
meter to describe), and it records no `shibuya.ack.decision` when a handler
throws (it makes no finalizer call, so there is no acknowledgement to claim).
[ADR 0001](../adr/0001-keiro-pgmq-job-processing-telemetry-contract.md) owns this
contract.

## The DSL workqueue path

A `.keiro` spec can own the queue instead. A `workqueue` node declares the
logical/derived names, the payload shape, the retry policy, and a disposition
table; a `dispatch` node declares read-model-driven fan-out with dedup:

```text
workqueue reservation_work {
  queue logical = "my_service.reservation_work"
  derive physical = "my_service_reservation_work"
         dlq = "my_service_reservation_work_dlq"
         table = "pgmq.q_my_service_reservation_work"

  payload ReservationWorkItem {
    reservationId -> "reservation_id" text required
    hospitalId    -> "hospital_id" text required
  }

  retry maxRetries = 3 delay = 5s dlq = on

  disposition {
    storeFailure    -> retry 5s
    commandRejected -> deadLetter
    decodeFailure   -> deadLetter
    onCodecReject   -> deadLetter
  }
}
```

`keiro-dsl scaffold` emits three modules per queue: `Queue` (payload type,
encoder/parser, the derived names, and the group-key accessor), `QueueCodec` (a
schema-version-1 `QueueCodec` backed by `keiroJobCodec`), and `QueuePolicy`
(`retryPolicy`, `jobOrdering`, `jobTuningFor`, `queueProvision`, and
`jobOutcomeFor` lowering the spec's named outcomes to `JobOutcome`). Deployment
still owns visibility timeout, batch size, and polling — `jobTuningFor` layers
only the spec's ordering onto a tuning you supply.

`keiro-dsl check` enforces the contracts that are dangerous to reconstruct by
hand: FIFO queues require a group key and unordered queues reject one, and the
captured physical/DLQ/table names must match the logical-name derivation.
`keiro-dsl diff` classifies ordering, group-key, provisioning, and queue-identity
changes as BREAKING. See
[Typed Specifications](typed-spec-toolchain.md).

## Testing

`keiro-pgmq`'s own suite is the executable reference for everything above —
enqueue and drain, retry and delay, dead-lettering and redrive, FIFO groups,
provisioning kinds, context and lease extension, and the span contract:

```bash
cabal test keiro-pgmq-test
```

It runs against an ephemeral PostgreSQL database through the same
`keiro-test-support` fixture your own suites should use, with PGMQ's migration
component appended to the framework plan.
