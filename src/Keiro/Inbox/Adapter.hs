{-# LANGUAGE LambdaCase #-}

{- | Shibuya 'Adapter' that drains 'keiro_inbox' as a durable queue.

This is the work-side half of the two-stage receive pattern introduced
by EP-23. The write side — typically @shibuya-kafka-adapter@'s
@kafkaAdapter@ — turns each Kafka delivery into a 'InboxPending' row.
This adapter polls those rows under @FOR UPDATE SKIP LOCKED@, hands
each one to a user-supplied 'Handler' as an 'Ingested IntegrationEvent',
and reflects the returned 'AckDecision' as inbox state transitions.

The inline EP-21 path ('Keiro.Inbox.runInboxTransaction') is still
supported and is the right tool when a handler can fit inside a single
'Tx.Transaction'. Use this adapter when handler latency would block
Kafka, when multiple producers (Kafka, sagas, HTTP) write to the same
inbox, or when several Shibuya processors should share supervision and
metrics under one 'Shibuya.App.runApp'.

== Atomicity options

The framework's 'AckHandle.finalize' runs 'markCompletedTx' /
'markInboxFailedTx' / 'markInboxDeadTx' / 'releaseInboxClaimTx' in
their own transactions, separate from the user's handler. That is
fine for handlers whose writes touch non-Postgres systems (HTTP calls,
S3, other DBs). For Postgres-only handlers that want EP-21's atomic
@(handler + mark-completed)@ semantics, wrap the handler with
'mkTransactionalInboxHandler' — it runs the user's 'Tx.Transaction'
and 'markCompletedTx' in one Postgres transaction; the framework's
'markCompletedTx' on AckOk is then a no-op (idempotent on completed).
-}
module Keiro.Inbox.Adapter
  ( -- * Configuration
    InboxAdapterConfig (..)
  , defaultInboxAdapterConfig

    -- * Adapter
  , inboxAdapter

    -- * Transactional handler wrapper
  , mkTransactionalInboxHandler

    -- * Re-exports
  , InboxAckOutcome
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Data.Time.Clock (NominalDiffTime)
import Effectful (Eff, IOE, (:>))
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Keiro.Inbox.Schema
  ( claimInboxBatchTx
  , markCompletedTx
  , markInboxDeadTx
  , markInboxFailedTx
  , releaseInboxClaimTx
  )
import Keiro.Inbox.Types
import Keiro.Integration.Event (IntegrationEvent (..))
import Keiro.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (GlobalPosition (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack
  ( AckDecision (..)
  , DeadLetterReason (..)
  , HaltReason (..)
  , RetryDelay (..)
  )
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Attempt (..), Cursor (..), Envelope (..), MessageId (..))
import Shibuya.Handler (Handler)
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import Data.HashMap.Strict qualified as HashMap

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

{- | Configuration for one 'inboxAdapter' instance.

* @adapterName@ — observability label fed into the Shibuya
  'Adapter.adapterName' field. Use something distinctive per consumer
  context, e.g. @"keiro-inbox:billing"@.
* @pollInterval@ — wait between empty-poll cycles. Too small wastes
  Postgres CPU; too large adds latency. Default 100ms.
* @claimOptions@ — batch size, visibility timeout, max attempts, and
  retry backoff. See 'InboxClaimOptions'.
-}
data InboxAdapterConfig = InboxAdapterConfig
  { adapterName :: !Text
  , pollInterval :: !NominalDiffTime
  , claimOptions :: !InboxClaimOptions
  }
  deriving stock (Generic, Eq, Show)

-- | Sensible defaults plus the caller-supplied 'adapterName'.
defaultInboxAdapterConfig :: Text -> InboxAdapterConfig
defaultInboxAdapterConfig name =
  InboxAdapterConfig
    { adapterName = name
    , pollInterval = 0.1
    , claimOptions = defaultInboxClaimOptions
    }

-- ---------------------------------------------------------------------------
-- Adapter
-- ---------------------------------------------------------------------------

{- | Build an 'Adapter' that drains 'keiro_inbox' as a queue.

The returned adapter polls 'claimInboxBatchTx' in a loop, yielding one
'Ingested IntegrationEvent' per claimed row. Each ingestion carries an
'AckHandle' that translates the handler's 'AckDecision' into the
appropriate inbox state transition:

* 'AckOk' → 'markCompletedTx' (idempotent on rows already completed).
* 'AckRetry' → 'markInboxFailedTx' with the supplied retry delay; rows
  transition to 'InboxDead' after exhausting
  @claimOptions ^. #maxAttempts@.
* 'AckDeadLetter' → 'markInboxDeadTx' (terminal).
* 'AckHalt' → 'releaseInboxClaimTx' and the adapter's shutdown signal
  is flipped so the source stream terminates after the next poll.

The 'shutdown' field flips the same signal so 'Shibuya.App.stopApp' /
'stopAppGracefully' terminate the stream at the next poll boundary.
-}
inboxAdapter ::
  forall es.
  (IOE :> es, Store :> es) =>
  InboxAdapterConfig ->
  Eff es (Adapter es IntegrationEvent)
inboxAdapter config = do
  shutdownVar <- liftIO (newTVarIO False)
  pure
    Adapter
      { adapterName = config ^. #adapterName
      , source = ingestedStream shutdownVar config
      , shutdown = liftIO (atomically (writeTVar shutdownVar True))
      }

ingestedStream ::
  forall es.
  (IOE :> es, Store :> es) =>
  TVar Bool ->
  InboxAdapterConfig ->
  Stream (Eff es) (Ingested es IntegrationEvent)
ingestedStream shutdownVar config =
  Stream.takeWhileM (\_ -> liftIO (not <$> readTVarIO shutdownVar)) $
    Stream.concatMap Stream.fromList $
      Stream.repeatM pollBatch
 where
  pollBatch :: Eff es [Ingested es IntegrationEvent]
  pollBatch = do
    isShutdown <- liftIO (readTVarIO shutdownVar)
    if isShutdown
      then pure []
      else do
        now <- liftIO getCurrentTime
        rows <- runTransaction (claimInboxBatchTx (config ^. #claimOptions) now)
        case rows of
          [] -> do
            sleepFor (config ^. #pollInterval)
            pure []
          xs -> pure (map (rowToIngested shutdownVar config) xs)

-- | Convert a claimed 'InboxRow' into an 'Ingested IntegrationEvent'.
rowToIngested ::
  forall es.
  (IOE :> es, Store :> es) =>
  TVar Bool ->
  InboxAdapterConfig ->
  InboxRow ->
  Ingested es IntegrationEvent
rowToIngested shutdownVar config row =
  Ingested
    { envelope =
        Envelope
          { messageId = MessageId (row ^. #dedupeKey)
          , cursor =
              fmap (\(GlobalPosition p) -> CursorInt (fromIntegral p))
                (row ^. #event . #sourceGlobalPosition)
          , partition = Just (row ^. #source)
          , enqueuedAt = Just (row ^. #receivedAt)
          , traceContext = Nothing
          , attempt = Just (Attempt (fromIntegral (row ^. #attemptCount)))
          , attributes = HashMap.empty
          , payload = row ^. #event
          }
    , ack = inboxAckHandle shutdownVar config row
    , lease = Nothing
    }

-- | The per-row 'AckHandle' that reflects 'AckDecision' as inbox state.
inboxAckHandle ::
  forall es.
  (IOE :> es, Store :> es) =>
  TVar Bool ->
  InboxAdapterConfig ->
  InboxRow ->
  AckHandle es
inboxAckHandle shutdownVar config row = AckHandle $ \decision -> do
  now <- liftIO getCurrentTime
  let src = row ^. #source
      key = row ^. #dedupeKey
  case decision of
    AckOk ->
      runTransaction (markCompletedTx src key now)
    AckRetry (RetryDelay d) -> do
      _ <- runTransaction $
        markInboxFailedTx
          src
          key
          "retry"
          (config ^. #claimOptions . #maxAttempts)
          (ConstantBackoff d)
          now
      pure ()
    AckDeadLetter reason ->
      runTransaction (markInboxDeadTx src key (renderDeadLetterReason reason) now)
    AckHalt reason -> do
      runTransaction (releaseInboxClaimTx src key now)
      liftIO (atomically (writeTVar shutdownVar True))
      -- Future enhancement: surface the halt reason via metrics.
      _ <- pure (renderHaltReason reason)
      pure ()

renderDeadLetterReason :: DeadLetterReason -> Text
renderDeadLetterReason = \case
  PoisonPill msg -> "PoisonPill: " <> msg
  InvalidPayload msg -> "InvalidPayload: " <> msg
  MaxRetriesExceeded -> "MaxRetriesExceeded"

renderHaltReason :: HaltReason -> Text
renderHaltReason = \case
  HaltOrderedStream msg -> "HaltOrderedStream: " <> msg
  HaltFatal msg -> "HaltFatal: " <> msg

sleepFor :: (IOE :> es) => NominalDiffTime -> Eff es ()
sleepFor d
  | d <= 0 = pure ()
  | otherwise = liftIO (threadDelay (floor (d * 1_000_000)))

-- ---------------------------------------------------------------------------
-- Transactional handler wrapper
-- ---------------------------------------------------------------------------

{- | Adapt an inline-shaped handler to run atomically with the
@completed@ transition.

The user-supplied function returns @Tx.Transaction (Either Text a)@:

* @Right a@ — the work succeeded. The wrapper calls 'markCompletedTx'
  in the same transaction, so user writes and the completed marker
  commit together. The wrapper returns 'AckOk'; the framework's
  ack-side 'markCompletedTx' is a no-op (status already completed).
* @Left reason@ — the user signals a transient failure. The wrapper
  issues 'Tx.condemn' so the user's writes do not persist, and
  returns 'AckRetry (RetryDelay 1)'. The framework's
  'markInboxFailedTx' then bumps @attempt_count@; the row transitions
  to 'InboxDead' once it exhausts @maxAttempts@.

Why @Either@ instead of bare 'Tx.condemn': Hasql's transaction runner
does not surface @condemn@ status to the caller — a tx that the user
condemned looks indistinguishable from one that committed. Returning
'Left' makes the failure signal explicit so the wrapper can decide the
right ack outcome.

Synchronous exceptions thrown by the user's transaction propagate as
'AckRetry'; the visibility-timeout reclaim covers the case where the
exception escapes between transaction commit and ack.
-}
mkTransactionalInboxHandler ::
  forall a es.
  (IOE :> es, Store :> es) =>
  (IntegrationEvent -> Tx.Transaction (Either Text a)) ->
  Handler es IntegrationEvent
mkTransactionalInboxHandler userTx Ingested{envelope = env} = do
  let event = env ^. #payload
      src = event ^. #source
      MessageId key = env ^. #messageId
  now <- liftIO getCurrentTime
  txOutcome <- runTransaction $ do
    outcome <- userTx event
    case outcome of
      Right _ -> do
        markCompletedTx src key now
        pure (Right ())
      Left reason -> do
        Tx.condemn
        pure (Left reason)
  case txOutcome of
    Right () -> pure AckOk
    Left _ -> pure (AckRetry (RetryDelay 1))
