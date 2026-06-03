{- | Idempotent inbox for cross-bounded-context integration events.

The inbox lives in the consuming bounded context. When a Kafka consumer
receives an integration event, the inbox records the event's stable
external identity and runs the local handler in the same Postgres
transaction. Duplicate redeliveries (Kafka offset retry, rebalance,
producer republish) become observable as duplicates instead of
re-running the handler.

The wrapper is a single-transaction primitive: the inbox insert, the
handler's local writes, and the @status = 'completed'@ update all
commit atomically. If the handler raises or condemns the transaction,
the inbox row never appears and the next delivery starts fresh.
-}
module Keiro.Inbox
  ( -- * Re-exports
    module Keiro.Inbox.Types

    -- * Storage primitives
  , lookupInbox
  , listInbox
  , garbageCollectCompleted
  , countInboxBacklog

    -- * Transactional handler wrapper
  , runInboxTransaction
  , runInboxTransactionWithKey
  )
where

import Effectful (Eff, IOE, (:>))
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Keiro.Inbox.Schema
import Keiro.Inbox.Types
import Keiro.Integration.Event (IntegrationEvent)
import Keiro.Prelude
import Keiro.Telemetry
  ( KeiroMetrics
  , recordInboxBacklog
  , recordInboxDuplicates
  , recordInboxFailed
  , recordInboxProcessed
  )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)

{- | Run @handler@ at most once for each @(source, dedupe_key)@.

Computes the dedupe key from @policy@ and @kafka@, then in one
transaction:

* Inserts the inbox row with status @processing@.
* If the row already exists, branches on its status: 'InboxCompleted'
  → 'InboxDuplicate'; 'InboxProcessing' → 'InboxInProgress';
  'InboxFailed' → 'InboxPreviouslyFailed'.
* Otherwise runs @handler@ and updates the row to @completed@.

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
  case dedupeKeyFor policy event kafka of
    Left err -> pure (Left err)
    Right dedupe ->
      Right <$> runInboxTransactionWithKey mMetrics (event ^. #source) dedupe event kafka handler

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
runInboxTransactionWithKey mMetrics src dedupe event kafka handler = do
  now <- liftIO getCurrentTime
  result <- runTransaction $ do
    inserted <- tryInsertProcessingTx src dedupe event kafka now
    case inserted of
      Right () -> do
        handled <- handler event
        markCompletedTx src dedupe now
        pure (InboxProcessed handled)
      Left row -> case row ^. #status of
        InboxCompleted -> pure InboxDuplicate
        InboxProcessing -> pure InboxInProgress
        InboxFailed -> pure (InboxPreviouslyFailed (row ^. #lastError))
  -- Record the classification counter and the backlog gauge outside the
  -- handler transaction (each a no-op under a 'Nothing' handle).
  case result of
    InboxProcessed _ -> recordInboxProcessed mMetrics 1
    InboxDuplicate -> recordInboxDuplicates mMetrics 1
    InboxPreviouslyFailed _ -> recordInboxFailed mMetrics 1
    InboxInProgress -> pure ()
  backlog <- countInboxBacklog
  recordInboxBacklog mMetrics (fromIntegral backlog)
  pure result
