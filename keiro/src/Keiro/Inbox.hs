{- | Idempotent inbox for cross-bounded-context integration events.

The inbox lives in the consuming bounded context. When a Kafka consumer
receives an integration event, the inbox records the event's stable
external identity and runs the local handler in the same Postgres
transaction. Duplicate redeliveries (Kafka offset retry, rebalance,
producer republish) become observable as duplicates instead of
re-running the handler.

The wrapper is a single-transaction primitive: the completed inbox row
and the handler's local writes commit atomically. If the handler raises
or condemns the transaction, the inbox row never appears and the next
delivery starts fresh.

Completed-row retention defines the deduplication window. After
'garbageCollectCompleted' removes a row, a later delivery of the same key is
processed again. A concurrent GC can also delete a conflicting completed row
between the insert attempt and its lookup; the handler then commits without a
replacement deduplication row, so a later redelivery can run it again. These
cases preserve at-least-once delivery, not permanent exactly-once processing;
size retention beyond the maximum redelivery delay and keep handlers
idempotent.
-}
module Keiro.Inbox (
    -- * Re-exports
    module Keiro.Inbox.Types,

    -- * Storage primitives
    lookupInbox,
    listInbox,
    garbageCollectCompleted,
    countInboxBacklog,
    markFailedTx,

    -- * Transactional handler wrapper
    runInboxTransaction,
    runInboxTransactionWith,
    runInboxTransactionWithKey,
    runInboxTransactionWithRetries,
    runInboxTransactionWithRetriesWith,
    runInboxTransactionWithRetriesKey,
    runInboxTransactionBatch,
    sampleInboxBacklog,
)
where

import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Effectful.Exception (displayException, trySync)
import Keiro.Inbox.Schema
import Keiro.Inbox.Types
import Keiro.Integration.Event (IntegrationEvent)
import Keiro.Prelude
import Keiro.Telemetry (
    KeiroMetrics,
    recordInboxBacklog,
    recordInboxDuplicates,
    recordInboxFailed,
    recordInboxPoisoned,
    recordInboxProcessed,
 )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import "hasql-transaction" Hasql.Transaction qualified as Tx

data BatchPlan
    = BatchKeyError !InboxError
    | BatchDuplicate
    | BatchWork !Text !Text !IntegrationEvent !(Maybe KafkaDeliveryRef)

{- | Run @handler@ at most once for each @(source, dedupe_key)@.

Computes the dedupe key from @policy@ and @kafka@, then in one
transaction:

* Inserts the inbox row with status @completed@.
* If the row already exists, branches on its status: 'InboxCompleted'
  → 'InboxDuplicate'; 'InboxProcessing' → 'InboxInProgress';
  'InboxFailed' → 'InboxPreviouslyFailed'.
* Otherwise runs @handler@; the row commits only if the handler succeeds.

The handler is invoked with the decoded 'IntegrationEvent' so it does
not need to redecode bytes. On exception or 'Tx.condemn' the whole
transaction rolls back, including the inbox row insert — the next
delivery sees no row and can retry.
-}
runInboxTransaction ::
    forall a es.
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics ->
    InboxDedupePolicy ->
    IntegrationEvent ->
    Maybe KafkaDeliveryRef ->
    (IntegrationEvent -> Tx.Transaction a) ->
    Eff es (Either InboxError (InboxResult a))
runInboxTransaction mMetrics policy event kafka handler =
    runInboxTransactionWith mMetrics PersistFullEnvelope policy event kafka handler

{- | Variant of 'runInboxTransaction' that controls success-path
envelope persistence.

'PersistDedupeOnly' keeps enough columns for dedupe and operator
correlation but stores an empty payload and omits schema, trace, and
attribute columns for successfully processed rows.
-}
runInboxTransactionWith ::
    forall a es.
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics ->
    InboxPersistence ->
    InboxDedupePolicy ->
    IntegrationEvent ->
    Maybe KafkaDeliveryRef ->
    (IntegrationEvent -> Tx.Transaction a) ->
    Eff es (Either InboxError (InboxResult a))
runInboxTransactionWith mMetrics persistence policy event kafka handler =
    case dedupeKeyFor policy event kafka of
        Left err -> pure (Left err)
        Right dedupe ->
            Right
                <$> runInboxTransactionWithKeyPersist
                    mMetrics
                    persistence
                    (event ^. #source)
                    dedupe
                    event
                    kafka
                    handler

{- | Lower-level variant that takes the dedupe key directly.

Use when the policy is not enough to express the identity scheme — for
example, when the consumer joins fields from multiple headers or
derives the key from the payload itself.
-}
runInboxTransactionWithKey ::
    forall a es.
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics ->
    Text ->
    Text ->
    IntegrationEvent ->
    Maybe KafkaDeliveryRef ->
    (IntegrationEvent -> Tx.Transaction a) ->
    Eff es (InboxResult a)
runInboxTransactionWithKey mMetrics src dedupe event kafka handler =
    runInboxTransactionWithKeyPersist mMetrics PersistFullEnvelope src dedupe event kafka handler

runInboxTransactionWithKeyPersist ::
    forall a es.
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics ->
    InboxPersistence ->
    Text ->
    Text ->
    IntegrationEvent ->
    Maybe KafkaDeliveryRef ->
    (IntegrationEvent -> Tx.Transaction a) ->
    Eff es (InboxResult a)
runInboxTransactionWithKeyPersist mMetrics persistence src dedupe event kafka handler = do
    now <- liftIO getCurrentTime
    result <-
        runTransaction $
            attemptOneTx persistence Nothing src dedupe event kafka now handler
    -- Record the classification counter outside the handler transaction.
    -- Backlog gauge sampling is intentionally scheduled separately via
    -- 'sampleInboxBacklog'.
    recordInboxResult mMetrics Nothing result
    pure result

{- | Run @handler@ with opt-in poison-message accounting.

This wrapper behaves like 'runInboxTransaction' for fresh messages,
duplicates, and in-flight rows, but changes the behavior for handler
exceptions and previously failed rows:

* A synchronous exception from @handler@ rolls back the handler
  transaction, then records a failed attempt in a second transaction and
  returns 'InboxHandlerFailed' with the new attempt count.
* A previously failed row with @attempt_count < ceiling@ is retried.
* A previously failed row with @attempt_count >= ceiling@ returns
  'InboxPreviouslyFailed' without running the handler. The consumer can
  commit its offset and move on; the failed inbox row is the dead-letter
  record for operator review.

'Tx.condemn' is not treated as a handler failure by this wrapper. It
keeps the original rollback semantics from 'runInboxTransaction'.
-}
runInboxTransactionWithRetries ::
    forall a es.
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics ->
    Int ->
    InboxDedupePolicy ->
    IntegrationEvent ->
    Maybe KafkaDeliveryRef ->
    (IntegrationEvent -> Tx.Transaction a) ->
    Eff es (Either InboxError (InboxResult a))
runInboxTransactionWithRetries mMetrics attemptCeiling policy event kafka handler =
    runInboxTransactionWithRetriesWith mMetrics attemptCeiling PersistFullEnvelope policy event kafka handler

-- | Variant of 'runInboxTransactionWithRetries' that controls success-path persistence.
runInboxTransactionWithRetriesWith ::
    forall a es.
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics ->
    Int ->
    InboxPersistence ->
    InboxDedupePolicy ->
    IntegrationEvent ->
    Maybe KafkaDeliveryRef ->
    (IntegrationEvent -> Tx.Transaction a) ->
    Eff es (Either InboxError (InboxResult a))
runInboxTransactionWithRetriesWith mMetrics attemptCeiling persistence policy event kafka handler =
    case dedupeKeyFor policy event kafka of
        Left err -> pure (Left err)
        Right dedupe ->
            Right
                <$> runInboxTransactionWithRetriesKeyPersist
                    mMetrics
                    attemptCeiling
                    persistence
                    (event ^. #source)
                    dedupe
                    event
                    kafka
                    handler

-- | Lower-level retrying variant that takes the dedupe key directly.
runInboxTransactionWithRetriesKey ::
    forall a es.
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics ->
    Int ->
    Text ->
    Text ->
    IntegrationEvent ->
    Maybe KafkaDeliveryRef ->
    (IntegrationEvent -> Tx.Transaction a) ->
    Eff es (InboxResult a)
runInboxTransactionWithRetriesKey mMetrics attemptCeiling src dedupe event kafka handler =
    runInboxTransactionWithRetriesKeyPersist mMetrics attemptCeiling PersistFullEnvelope src dedupe event kafka handler

runInboxTransactionWithRetriesKeyPersist ::
    forall a es.
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics ->
    Int ->
    InboxPersistence ->
    Text ->
    Text ->
    IntegrationEvent ->
    Maybe KafkaDeliveryRef ->
    (IntegrationEvent -> Tx.Transaction a) ->
    Eff es (InboxResult a)
runInboxTransactionWithRetriesKeyPersist mMetrics attemptCeiling persistence src dedupe event kafka handler = do
    now <- liftIO getCurrentTime
    attempted <-
        trySync $
            runTransaction $
                attemptOneTx persistence (Just attemptCeiling) src dedupe event kafka now handler
    result <- case attempted of
        Right ok -> pure ok
        Left err -> do
            failedAt <- liftIO getCurrentTime
            let errMsg = Text.pack (displayException err)
            attempts <-
                runTransaction $
                    recordFailedAttemptTx src dedupe event kafka errMsg failedAt
            pure (InboxHandlerFailed errMsg attempts)
    recordInboxResult mMetrics (Just attemptCeiling) result
    pure result

{- | Process a batch of inbox deliveries with a single transactional fast path.

The fast path computes each @(source, dedupe_key)@, suppresses repeated
keys within the batch as duplicates, then runs all remaining deliveries
in one Postgres transaction. If any handler throws or condemns that
transaction, the whole batch rolls back and every original delivery is
retried through 'runInboxTransactionWithRetries'. That fallback preserves
per-message failure accounting and prevents one poison message from
discarding unrelated batch mates.

'Tx.condemn' rolls the transaction back at commit but returns normally,
so it cannot be observed from the transaction's return value alone.
The batch detects it by re-reading one row it should have committed:
every write in the fast path belongs to a delivery classified
'InboxProcessed' (fresh insert as @completed@ or retry promotion to
@completed@), so if the first such row is not @completed@ after the
transaction returns, the whole batch was condemned and the per-message
fallback runs. A batch with no 'InboxProcessed' rows performed no writes,
so a condemned transaction loses nothing.
-}
runInboxTransactionBatch ::
    forall a es.
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics ->
    Int ->
    InboxDedupePolicy ->
    InboxPersistence ->
    [(IntegrationEvent, Maybe KafkaDeliveryRef)] ->
    (IntegrationEvent -> Tx.Transaction a) ->
    Eff es [Either InboxError (InboxResult a)]
runInboxTransactionBatch mMetrics attemptCeiling policy persistence deliveries handler = do
    now <- liftIO getCurrentTime
    let plan = planInboxBatch policy deliveries
    attempted <-
        trySync $
            runTransaction $
                traverse
                    ( \case
                        BatchKeyError err -> pure (Left err)
                        BatchDuplicate -> pure (Right InboxDuplicate)
                        BatchWork src dedupe event kafka ->
                            Right <$> attemptOneTx persistence (Just attemptCeiling) src dedupe event kafka now handler
                    )
                    plan
    case attempted of
        Right results -> do
            committed <- verifyBatchCommitted plan results
            if committed
                then do
                    for_ results $ \case
                        Right result -> recordInboxResult mMetrics (Just attemptCeiling) result
                        Left _ -> pure ()
                    pure results
                else perMessageFallback
        Left _ -> perMessageFallback
  where
    perMessageFallback :: Eff es [Either InboxError (InboxResult a)]
    perMessageFallback =
        traverse
            ( \(event, kafka) ->
                runInboxTransactionWithRetriesWith mMetrics attemptCeiling persistence policy event kafka handler
            )
            deliveries

    -- A condemned transaction returns its results normally but commits
    -- nothing. Re-read the first row the batch claims to have completed;
    -- if it is not @completed@, the transaction rolled back at commit.
    verifyBatchCommitted ::
        [BatchPlan] ->
        [Either InboxError (InboxResult a)] ->
        Eff es Bool
    verifyBatchCommitted plan results =
        case listToMaybe (mapMaybe processedKey (zip plan results)) of
            Nothing -> pure True
            Just (src, dedupe) -> do
                row <- lookupInbox src dedupe
                pure (fmap (^. #status) row == Just InboxCompleted)

    processedKey :: (BatchPlan, Either InboxError (InboxResult a)) -> Maybe (Text, Text)
    processedKey = \case
        (BatchWork src dedupe _ _, Right (InboxProcessed _)) -> Just (src, dedupe)
        _ -> Nothing

attemptOneTx ::
    InboxPersistence ->
    Maybe Int ->
    Text ->
    Text ->
    IntegrationEvent ->
    Maybe KafkaDeliveryRef ->
    UTCTime ->
    (IntegrationEvent -> Tx.Transaction a) ->
    Tx.Transaction (InboxResult a)
attemptOneTx persistence attemptCeiling src dedupe event kafka now handler = do
    inserted <- tryInsertCompletedTx persistence src dedupe event kafka now
    case inserted of
        Right () -> do
            handled <- handler event
            pure (InboxProcessed handled)
        Left row -> case row ^. #status of
            InboxCompleted -> pure InboxDuplicate
            InboxProcessing -> pure InboxInProgress
            InboxFailed -> case attemptCeiling of
                Nothing -> pure (InboxPreviouslyFailed (row ^. #lastError))
                Just attemptLimit
                    | row ^. #attemptCount >= attemptLimit ->
                        pure (InboxPreviouslyFailed (row ^. #lastError))
                    | otherwise -> do
                        handled <- handler event
                        markCompletedTx src dedupe now
                        pure (InboxProcessed handled)

recordInboxResult :: (IOE :> es) => Maybe KeiroMetrics -> Maybe Int -> InboxResult a -> Eff es ()
recordInboxResult mMetrics attemptCeiling = \case
    InboxProcessed _ -> recordInboxProcessed mMetrics 1
    InboxDuplicate -> recordInboxDuplicates mMetrics 1
    InboxPreviouslyFailed _ -> recordInboxFailed mMetrics 1
    InboxHandlerFailed _ attempts -> do
        recordInboxFailed mMetrics 1
        case attemptCeiling of
            Just attemptLimit | attempts >= attemptLimit -> recordInboxPoisoned mMetrics 1
            _ -> pure ()
    InboxInProgress -> pure ()

planInboxBatch ::
    InboxDedupePolicy ->
    [(IntegrationEvent, Maybe KafkaDeliveryRef)] ->
    [BatchPlan]
planInboxBatch policy = go Map.empty
  where
    go _ [] = []
    go seen ((event, kafka) : rest) =
        case dedupeKeyFor policy event kafka of
            Left err -> BatchKeyError err : go seen rest
            Right dedupe ->
                let key = (event ^. #source, dedupe)
                 in if Map.member key seen
                        then BatchDuplicate : go seen rest
                        else BatchWork (event ^. #source) dedupe event kafka : go (Map.insert key () seen) rest

{- | Count the inbox backlog and record the gauge when metrics are enabled.

The backlog is non-terminal rows: legacy @processing@ rows plus failed rows.
Schedule this on its own interval; it is intentionally not part of the
per-message intake path.
-}
sampleInboxBacklog :: (IOE :> es, Store :> es) => Maybe KeiroMetrics -> Eff es ()
sampleInboxBacklog Nothing = pure ()
sampleInboxBacklog (Just metrics) = do
    backlog <- countInboxBacklog
    recordInboxBacklog (Just metrics) (fromIntegral backlog)
