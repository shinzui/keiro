-- | A background work queue over the order domain: when an order ships, a
-- @keiro-pgmq@ job sends the customer's shipment notice.
--
-- This is deliberately the shape a real service has, and it shows the one
-- structural fact that trips people up: __the job effect stack does not carry
-- Kiroku's @Store@__. 'Keiro.PGMQ.Runtime.runJobEff' interprets
-- @Reader PgmqAdapterEnv : Pgmq : Tracing : Error PgmqRuntimeError : IOE@, so a
-- handler that must touch application tables is given its own repository access —
-- here a @hasql@ 'Pool' partially applied into 'handleShipmentNotice'.
--
-- The producer side is equally deliberate. 'shipmentNoticeFor' maps a recorded
-- 'OrderShipped' event to a job payload, and 'enqueueShipmentNotice' sends it into
-- a FIFO group keyed by the order id, so two notices for the same order are
-- delivered in send order while different orders proceed in parallel.
--
-- Note what is /not/ claimed: the enqueue is not atomic with the order append. If
-- losing a notice when the process dies between the two is unacceptable, the
-- transactional outbox is the right primitive, not a queue. A shipment notice is
-- re-derivable from the order stream, so at-least-once with an idempotent write is
-- the honest trade here.
module Jitsurei.ShipmentNotices
  ( -- * The payload and its versioned codec
    ShipmentNotice (..),
    shipmentNoticeCodec,
    shipmentNoticeFor,

    -- * The job
    shipmentNoticeJob,
    shipmentNoticeTuning,

    -- * Producing
    enqueueShipmentNotice,

    -- * Consuming
    handleShipmentNotice,
    drainShipmentNotices,

    -- * Startup
    ensureShipmentNoticeQueue,

    -- * Application table
    shipmentNoticesTable,
    initializeShipmentNoticesTable,
    countShipmentNotices,
    lookupShipmentNotice,
  )
where

import Contravariant.Extras (contrazip3)
import Data.Aeson (object, withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Effectful (Eff, IOE, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Jitsurei.Domain
import Jitsurei.ReadModels (jitsureiProjectionSchema)
import Keiro.Codec (Codec (..), EventType (..))
import Keiro.Connection (qualifyTable, quoteIdentifier)
import Keiro.PGMQ.Codec (keiroJobCodec)
import Keiro.PGMQ.Job
  ( Job (..),
    JobOrdering (..),
    JobOutcome (..),
    JobTuning,
    RetryDelay (..),
    RetryPolicy (..),
    defaultJobTuning,
    enqueueToGroup,
    runJobOnceWithContext,
    withOrdering,
  )
import Keiro.PGMQ.Job qualified as Job
import Keiro.PGMQ.Runtime (queueRef)
import Keiro.Prelude
import Pgmq.Effectful (MessageId, Pgmq)
import Shibuya.Telemetry.Effect (Tracing)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import "hasql-transaction" Hasql.Transaction.Sessions qualified as TxSessions

-- ---------------------------------------------------------------------------
-- Payload
-- ---------------------------------------------------------------------------

-- | What the notice worker needs to send one shipment notification. Derived
-- from the order stream rather than carried through it: the queue moves work, not
-- truth.
data ShipmentNotice = ShipmentNotice
  { orderId :: !OrderId,
    carrier :: !Carrier,
    trackingId :: !TrackingId
  }
  deriving stock (Generic, Eq, Show)

-- | The payload's versioned codec.
--
-- Job payloads outlive the binary that enqueued them, so this queue uses the
-- versioned @{v,t,data}@ envelope ('keiroJobCodec') rather than a bare
-- @aesonJobCodec@. A future field change bumps 'schemaVersion' and adds an
-- upcaster rung here, exactly as an aggregate event codec would — and workers must
-- then be deployed before producers, because a worker reading a future envelope
-- retries rather than decodes.
shipmentNoticeCodec :: Codec ShipmentNotice
shipmentNoticeCodec =
  Codec
    { eventTypes = EventType "ShipmentNotice" :| [],
      eventType = \_ -> EventType "ShipmentNotice",
      schemaVersion = 1,
      encode = \notice ->
        object
          [ "orderId" Aeson..= orderIdText notice.orderId,
            "carrier" Aeson..= carrierText notice.carrier,
            "trackingId" Aeson..= trackingIdText notice.trackingId
          ],
      decode = \_ value ->
        case parseEither parser value of
          Left err -> Left (Text.pack err)
          Right notice -> Right notice,
      upcasters = []
    }
  where
    parser = withObject "ShipmentNotice" $ \o ->
      ShipmentNotice
        <$> (OrderId <$> o .: "orderId")
        <*> (Carrier <$> o .: "carrier")
        <*> (TrackingId <$> o .: "trackingId")

-- | The producer's mapping: an 'OrderShipped' event becomes one notice, every
-- other order event becomes nothing. Keeping this total and pure means the
-- subscription that feeds the queue has no decisions of its own to get wrong.
shipmentNoticeFor :: OrderEvent -> Maybe ShipmentNotice
shipmentNoticeFor = \case
  OrderShipped payload ->
    Just
      ShipmentNotice
        { orderId = payload.orderId,
          carrier = payload.carrier,
          trackingId = payload.trackingId
        }
  _ -> Nothing

-- ---------------------------------------------------------------------------
-- The job
-- ---------------------------------------------------------------------------

-- | The job declaration: a queue, a codec, and a retry policy.
--
-- @queueRef@ sanitizes the logical name into PGMQ-legal physical names —
-- @jitsurei_shipment_notices@ for the main queue and
-- @jitsurei_shipment_notices_dlq@ for the dead-letter queue.
--
-- Three delivery attempts with a 5-second retry delay and a DLQ enabled: a notice
-- that cannot be sent after three tries is an operator's problem, not an infinite
-- retry loop.
shipmentNoticeJob :: Job ShipmentNotice
shipmentNoticeJob =
  Job
    { jobName = "jitsurei-shipment-notices",
      jobQueue = queueRef "jitsurei.shipment_notices",
      jobCodec = keiroJobCodec shipmentNoticeCodec,
      jobPolicy =
        RetryPolicy
          { maxRetries = 3,
            defaultRetryDelay = RetryDelay 5,
            useDeadLetter = True
          }
    }

-- | Per-order FIFO delivery. Notices for one order are handled in send order;
-- distinct orders proceed in parallel. Requires the queue's FIFO index, which
-- 'Keiro.PGMQ.Job.ensureOrderedJobQueue' creates.
shipmentNoticeTuning :: JobTuning
shipmentNoticeTuning = withOrdering FifoThroughput defaultJobTuning

-- | Enqueue one notice into its order's FIFO group. The group key is the order
-- id, so redelivery and concurrent workers cannot reorder two notices for the same
-- order.
enqueueShipmentNotice ::
  (Pgmq :> es, IOE :> es) => ShipmentNotice -> Eff es MessageId
enqueueShipmentNotice notice =
  enqueueToGroup shipmentNoticeJob (orderIdText notice.orderId) notice

-- ---------------------------------------------------------------------------
-- The handler
-- ---------------------------------------------------------------------------

-- | Send one shipment notice.
--
-- Two properties the guide leans on:
--
-- * __Idempotent.__ Delivery is at-least-once, so the write is
--   @ON CONFLICT DO NOTHING@ keyed by order id. A redelivered notice is a no-op,
--   not a second email.
-- * __Poison is explicit.__ A notice with a blank tracking id can never succeed,
--   so it returns 'Dead' and goes straight to the DLQ instead of burning three
--   attempts on a failure that will never resolve.
--
-- The 'Pool' is the handler's own repository access, partially applied at wiring
-- time: the job stack has no Kiroku @Store@ to borrow.
handleShipmentNotice ::
  (IOE :> es) => Pool -> ShipmentNotice -> Eff es JobOutcome
handleShipmentNotice pool notice
  | Text.null (Text.strip (trackingIdText notice.trackingId)) =
      pure (Dead "shipment notice has no tracking id")
  | otherwise = do
      result <- liftIO (Pool.use pool (Session.statement row insertShipmentNoticeStmt))
      pure $ case result of
        -- A transient database failure is worth retrying; the row is still
        -- on the queue and the write above is idempotent.
        Left _err -> RetryDefault
        Right () -> Done
  where
    row =
      ( orderIdText notice.orderId,
        carrierText notice.carrier,
        trackingIdText notice.trackingId
      )

-- | Drain up to @n@ pending notices and return how many were settled.
--
-- This is the bounded shape: it returns as soon as the queue is empty, which suits
-- a demo, a test, or a cron-driven flush. A long-running deployment would build a
-- processor with 'Keiro.PGMQ.Job.jobProcessorWithContext' and supervise it with
-- 'Keiro.PGMQ.Job.runJobWorkers' instead; the handler is the same either way.
drainShipmentNotices ::
  (Pgmq :> es, IOE :> es, Tracing :> es) => Pool -> Int -> Eff es Int
drainShipmentNotices pool n =
  runJobOnceWithContext shipmentNoticeTuning n shipmentNoticeJob $
    \_context notice -> handleShipmentNotice pool notice

-- ---------------------------------------------------------------------------
-- Startup
-- ---------------------------------------------------------------------------

-- | Everything this queue needs before a worker or producer runs: the main
-- queue, its dead-letter queue, the FIFO index that grouped reads match against,
-- and the application table the handler writes to.
--
-- Every step is idempotent, so a worker calls this at every startup.
-- 'Keiro.PGMQ.Job.ensureOrderedJobQueue' routes through @pgmq-config@'s additive
-- reconciler, which lists existing queues first and creates only what is missing.
--
-- The notices table is created here rather than in a @keiro-migrate@ migration
-- because it is application-owned; a production service would put it in its own
-- migration set instead. See
-- @docs/user/read-models-and-projections.md@ on choosing a projection schema.
ensureShipmentNoticeQueue :: (Pgmq :> es, IOE :> es) => Pool -> Eff es ()
ensureShipmentNoticeQueue pool = do
  Job.ensureOrderedJobQueue shipmentNoticeJob
  _ <-
    liftIO
      . Pool.use pool
      . TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write
      $ initializeShipmentNoticesTable
  pure ()

-- ---------------------------------------------------------------------------
-- The application table
-- ---------------------------------------------------------------------------

-- | The notices table lives in jitsurei's own schema, not in @kiroku@ or
-- @keiro@ — the same ownership rule the read-model tables follow.
shipmentNoticesTable :: Text
shipmentNoticesTable = qualifyTable jitsureiProjectionSchema "jitsurei_shipment_notices"

-- | Create the application schema and the notices table. Idempotent.
initializeShipmentNoticesTable :: Tx.Transaction ()
initializeShipmentNoticesTable =
  Tx.sql $
    TE.encodeUtf8 $
      "CREATE SCHEMA IF NOT EXISTS "
        <> quoteIdentifier jitsureiProjectionSchema
        <> ";\n"
        <> "CREATE TABLE IF NOT EXISTS "
        <> shipmentNoticesTable
        <> " (\n"
        <> "  order_id TEXT PRIMARY KEY,\n"
        <> "  carrier TEXT NOT NULL,\n"
        <> "  tracking_id TEXT NOT NULL,\n"
        <> "  notified_at TIMESTAMPTZ NOT NULL DEFAULT now()\n"
        <> ")"

insertShipmentNoticeStmt :: Statement (Text, Text, Text) ()
insertShipmentNoticeStmt =
  preparable
    ( "INSERT INTO "
        <> shipmentNoticesTable
        <> " (order_id, carrier, tracking_id)\n"
        <> "VALUES ($1, $2, $3)\n"
        <> "ON CONFLICT (order_id) DO NOTHING"
    )
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    D.noResult

-- | How many notices have been sent. Used by the tests and the demo.
countShipmentNotices :: Statement () Int64
countShipmentNotices =
  preparable
    ("SELECT count(*) FROM " <> shipmentNoticesTable)
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.int8)))

-- | The carrier and tracking id recorded for one order, if it was notified.
lookupShipmentNotice :: Statement Text (Maybe (Text, Text))
lookupShipmentNotice =
  preparable
    ( "SELECT carrier, tracking_id FROM "
        <> shipmentNoticesTable
        <> "\nWHERE order_id = $1"
    )
    (E.param (E.nonNullable E.text))
    ( D.rowMaybe
        ( (,)
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
        )
    )
