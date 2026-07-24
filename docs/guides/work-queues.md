# Work Queues

An order ships. Somewhere, a customer needs to hear about it. That work does not
belong in the command transaction — it is slow, it talks to a third party, and
retrying it must not retry the append. It belongs on a **work queue**.

This guide walks the `jitsurei` shipment-notice queue end to end: the payload and
its versioned codec, the job declaration, the producer, the handler, and the
drain that runs it — then the three properties the tests actually prove. The
source is real and compiles as part of this workspace:
[`../../jitsurei/src/Jitsurei/ShipmentNotices.hs`](../../jitsurei/src/Jitsurei/ShipmentNotices.hs),
proven by the `Jitsurei shipment notices` block in
[`../../jitsurei/test/Main.hs`](../../jitsurei/test/Main.hs).

The API reference for everything used here is
[Work Queues](../user/work-queues.md); this guide is the worked example.

## Before anything else: is this a queue or an outbox?

Keiro has two durable handoffs, and picking the wrong one is the expensive
mistake.

A [transactional outbox](../user/outbox.md) row is written **in the same
transaction as the event append**. If the command commits, the row exists. That
is what you need when the downstream effect is part of the promise the command
made — publishing an integration event another bounded context is waiting for.

A work-queue enqueue is **not** atomic with the append. `enqueue` runs on the
job runtime's own connection pool, so a process that dies between the committed
append and the enqueue loses the job. That is a real gap, and the honest question
is whether it matters:

> Can this work be re-derived from state you already committed?

For a shipment notice the answer is yes — the order stream records that the order
shipped, so a reconciliation pass can find un-notified orders. The queue is
moving *work*, not *truth*. If the answer is no, use the outbox.

The module says so out loud, because a reader who skips this section will
otherwise assume the wrong guarantee:

```haskell
-- Note what is /not/ claimed: the enqueue is not atomic with the order append.
-- If losing a notice when the process dies between the two is unacceptable, the
-- transactional outbox is the right primitive, not a queue.
```

## The payload, and why it is versioned

A job payload outlives the binary that enqueued it. A notice sitting on the queue
during a deploy is decoded by the *new* worker, so the payload has the same
evolution problem an event does — and the same solution:

```haskell
data ShipmentNotice = ShipmentNotice
  { orderId    :: !OrderId
  , carrier    :: !Carrier
  , trackingId :: !TrackingId
  }

shipmentNoticeCodec :: Codec ShipmentNotice
shipmentNoticeCodec =
  Codec
    { eventTypes    = EventType "ShipmentNotice" :| []
    , eventType     = \_ -> EventType "ShipmentNotice"
    , schemaVersion = 1
    , encode        = ...
    , decode        = ...
    , upcasters     = []
    }
```

That is an ordinary keiro `Codec`, wrapped by `keiroJobCodec` in the job below.
It puts the payload inside a `{v,t,data}` envelope, so a version bump adds an
upcaster rung here exactly as it would for an aggregate event, and a worker that
meets a *future* version retries instead of dead-lettering. The alternative,
`aesonJobCodec`, is a bare `ToJSON`/`FromJSON` pair with no version stamp — fine
for a queue you will never evolve, and one migration you cannot perform on a
non-empty queue if you are wrong about that.

The rollout rule that follows: **deploy workers before producers**. See
[Deploy Ordering](../user/deploy-ordering.md#3-upgrade-versioned-job-workers-before-producers).

## The producer side is a pure function

Mapping a domain event to a job payload is the kind of code that quietly grows
decisions. Keeping it total and pure means the subscription feeding the queue has
none of its own to get wrong:

```haskell
shipmentNoticeFor :: OrderEvent -> Maybe ShipmentNotice
shipmentNoticeFor = \case
  OrderShipped payload ->
    Just ShipmentNotice
      { orderId    = payload.orderId
      , carrier    = payload.carrier
      , trackingId = payload.trackingId
      }
  _ -> Nothing
```

It is also the one part of this guide testable without a database, which is why
the first example in the suite is:

```haskell
it "maps OrderShipped to a notice and ignores every other order event" $ do
  shipmentNoticeFor (OrderShipped sampleShipped) `shouldBe` Just sampleNotice
  shipmentNoticeFor (OrderPacked ...)            `shouldBe` Nothing
```

## The job declaration

```haskell
shipmentNoticeJob :: Job ShipmentNotice
shipmentNoticeJob =
  Job
    { jobName   = "jitsurei-shipment-notices"
    , jobQueue  = queueRef "jitsurei.shipment_notices"
    , jobCodec  = keiroJobCodec shipmentNoticeCodec
    , jobPolicy =
        RetryPolicy
          { maxRetries        = 3
          , defaultRetryDelay = RetryDelay 5
          , useDeadLetter     = True
          }
    }
```

Four fields, and each is load-bearing.

`queueRef` turns the logical name into PGMQ-legal physical names —
`jitsurei_shipment_notices` and `jitsurei_shipment_notices_dlq`. PGMQ caps names
at 47 characters and rejects anything outside `[a-z0-9_]`, so this derivation
exists precisely so you never hand-write a physical name and never discover the
cap in production.

`maxRetries = 3` is a **delivery** count, not a handler-failure count. Every
visibility-timeout expiry burns one, and a message whose read count exceeds it is
dead-lettered *before the handler ever sees it*. Three attempts with a five-second
delay says: a notice that fails three times is an operator's problem, not an
infinite loop.

## Per-order FIFO

Two notices for the same order must not be reordered by a retry. PGMQ message
groups give exactly that, and the queue opts in on both sides:

```haskell
shipmentNoticeTuning :: JobTuning
shipmentNoticeTuning = withOrdering FifoThroughput defaultJobTuning

enqueueShipmentNotice :: (Pgmq :> es, IOE :> es) => ShipmentNotice -> Eff es MessageId
enqueueShipmentNotice notice =
  enqueueToGroup shipmentNoticeJob (orderIdText notice.orderId) notice
```

Within one group, messages are delivered in send order; distinct groups proceed
in parallel. Ordering is not deduplication — delivery is still at-least-once.

Grouped reads match against a GIN index on the queue's `headers` column, so
ordered queues must be provisioned with it. That is what `ensureOrderedJobQueue`
adds over plain `ensureJobQueue`.

## The handler, and the effect-stack boundary

Here is the fact that surprises people, and the reason this example exists rather
than a toy:

**The job effect stack does not carry Kiroku's `Store`.** `runJobEff` interprets
`Reader PgmqAdapterEnv : Pgmq : Tracing : Error PgmqRuntimeError : IOE` — there
is no `Store` in it. A handler that needs to touch application tables is given
its own repository access, partially applied at wiring time:

```haskell
handleShipmentNotice :: (IOE :> es) => Pool -> ShipmentNotice -> Eff es JobOutcome
handleShipmentNotice pool notice
  | Text.null (Text.strip (trackingIdText notice.trackingId)) =
      pure (Dead "shipment notice has no tracking id")
  | otherwise = do
      result <- liftIO (Pool.use pool (Session.statement row insertShipmentNoticeStmt))
      pure $ case result of
        Left _err -> RetryDefault
        Right ()  -> Done
```

Three outcomes, three different meanings:

- **`Done`** — the notice was recorded; delete the message.
- **`RetryDefault`** — the database was momentarily unavailable. The message stays
  queued and comes back after the policy's five seconds. This is worth retrying
  because the *next* attempt might succeed.
- **`Dead reason`** — a notice with a blank tracking id can never succeed. Burning
  three attempts on it would delay every other notice in its group and tell the
  operator nothing new, so it goes straight to the dead-letter queue.

That last distinction is the one worth internalizing. `Retry` is for *transient*
failure; `Dead` is for *poison*. Getting it backwards produces either a queue
that never drains or a dead-letter queue full of messages that would have
succeeded.

### Idempotency is not optional

Delivery is at-least-once, so the write is:

```sql
INSERT INTO "jitsurei"."jitsurei_shipment_notices" (order_id, carrier, tracking_id)
VALUES ($1, $2, $3)
ON CONFLICT (order_id) DO NOTHING
```

A redelivered notice is a no-op, not a second email. The suite proves it by
enqueuing the same notice twice:

```haskell
redelivered <- runQueue runtime $ do
  _ <- enqueueShipmentNotice sampleNotice
  drainShipmentNotices pool 10
redelivered  `shouldBe` 1     -- it was delivered and handled again
noticeCount pool `shouldReturn` 1  -- and still only one row exists
```

If your handler cannot be made idempotent by a unique key, it needs an
idempotency key of its own — the queue will not supply one.

## Startup: provision everything, every time

```haskell
ensureShipmentNoticeQueue :: (Pgmq :> es, IOE :> es) => Pool -> Eff es ()
ensureShipmentNoticeQueue pool = do
  Job.ensureOrderedJobQueue shipmentNoticeJob
  _ <- liftIO . Pool.use pool
         . TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write
         $ initializeShipmentNoticesTable
  pure ()
```

Main queue, dead-letter queue, FIFO index, and the application table the handler
writes to. Every step is idempotent — `ensureOrderedJobQueue` routes through
`pgmq-config`'s additive reconciler, which lists existing queues first and creates
only what is missing — so a worker calls this at every startup rather than
guarding it with a flag.

The notices table is created here because it is application-owned. A production
service puts it in its own migration set instead; see
[Read Models And Projections](../user/read-models-and-projections.md#choosing-your-projection-schema)
on choosing a projection schema. What is *not* application-owned is PGMQ's own
schema — see [Migrations](#migrations) below.

## Draining

```haskell
drainShipmentNotices :: (Pgmq :> es, IOE :> es, Tracing :> es) => Pool -> Int -> Eff es Int
drainShipmentNotices pool n =
  runJobOnceWithContext shipmentNoticeTuning n shipmentNoticeJob $
    \_context notice -> handleShipmentNotice pool notice
```

This is the **bounded** shape: it returns as soon as the queue is empty or `n`
messages have been settled. It suits a test, a cron flush, or a demo.

A long-running deployment uses the **continuous** shape instead — build a
processor with `jobProcessorWithContext` and supervise it with `runJobWorkers`,
which owns an inbox, a concurrency limit, and graceful shutdown. The handler is
identical either way; only the runner changes. The two paths differ in one
behaviour worth knowing: if a handler *throws*, the bounded drain issues no
finalizer call and leaves the message invisible until its visibility timeout
expires, while the continuous runner substitutes an `AckRetry`.

## What the tests prove

```bash
cabal test jitsurei-test
```

Four examples under `Jitsurei shipment notices`:

| Example | What it pins down |
|---|---|
| maps `OrderShipped` to a notice and ignores every other order event | the producer mapping is total and selective |
| drains an enqueued notice into the notices table, idempotently | the happy path, then a redelivery that leaves one row |
| dead-letters a notice that can never be sent | `Dead` writes nothing, empties the main queue, and parks one row in the DLQ |
| preserves per-order order and drains every grouped notice | two notices in one FIFO group both drain, and the first delivered wins the insert |

The dead-letter example is the one that checks all three places state can hide:

```haskell
noticeCount pool      `shouldReturn` 0   -- nothing was written
mainQueueDepth runtime `shouldReturn` 0  -- the message left the main queue
dlqDepth runtime       `shouldReturn` 1  -- and landed in the DLQ
```

## Migrations

PGMQ's schema is not installed by `keiro-migrate`, which composes only the Kiroku
and Keiro components. An application that uses work queues appends PGMQ's own
native component to its plan, so one `pgmigrate` ledger owns all three. The test
suite does exactly that:

```haskell
withJitsureiSuite :: (Fixture -> IO a) -> IO a
withJitsureiSuite action = do
  pgmq <- either (fail . show) pure PgmqMigration.pgmqMigrations
  withMigratedSuiteWith [pgmq] action
```

This is not optional bookkeeping. A pg-migrate ledger is shared by every
component in it, so a plan that *omits* a component already recorded in the
ledger fails strict verification with `UnknownStoredMigration`. Add PGMQ to your
plan and keep it there.

That constraint is also why `jitsurei-demo` has no work-queue subcommand: the
demo database is migrated by `keiro-migrate`, whose plan has no PGMQ component,
and installing PGMQ into it would break the next `keiro-migrate verify`. The
tests own this example.

## Where to go next

- [Work Queues](../user/work-queues.md) — the full reference: every producer
  variant, tuning, provisioning kinds, DLQ operations, metrics, tracing, and the
  DSL `workqueue` path.
- [Durable Outbox](../user/outbox.md) — the transactional alternative, for work
  that must not be lost if the command commits.
- [Deploy Ordering](../user/deploy-ordering.md#3-upgrade-versioned-job-workers-before-producers)
  — the workers-before-producers rule for versioned payloads.
