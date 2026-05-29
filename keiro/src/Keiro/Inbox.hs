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
  , initializeInboxSchema
  , lookupInbox
  , listInbox
  , garbageCollectCompleted

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
  InboxDedupePolicy ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  (IntegrationEvent -> Tx.Transaction a) ->
  Eff es (Either InboxError (InboxResult a))
runInboxTransaction policy event kafka handler =
  case dedupeKeyFor policy event kafka of
    Left err -> pure (Left err)
    Right dedupe ->
      Right <$> runInboxTransactionWithKey (event ^. #source) dedupe event kafka handler

{- | Lower-level variant that takes the dedupe key directly.

Use when the policy is not enough to express the identity scheme — for
example, when the consumer joins fields from multiple headers or
derives the key from the payload itself.
-}
runInboxTransactionWithKey ::
  forall a es.
  (IOE :> es, Store :> es) =>
  Text ->
  Text ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  (IntegrationEvent -> Tx.Transaction a) ->
  Eff es (InboxResult a)
runInboxTransactionWithKey src dedupe event kafka handler = do
  now <- liftIO getCurrentTime
  runTransaction $ do
    inserted <- tryInsertProcessingTx src dedupe event kafka now
    case inserted of
      Right () -> do
        result <- handler event
        markCompletedTx src dedupe now
        pure (InboxProcessed result)
      Left row -> case row ^. #status of
        InboxCompleted -> pure InboxDuplicate
        InboxProcessing -> pure InboxInProgress
        InboxFailed -> pure (InboxPreviouslyFailed (row ^. #lastError))
