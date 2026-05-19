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
  , listInboxByStatus
  , garbageCollectCompleted

    -- * Transactional handler wrapper (EP-21 inline path)
  , runInboxTransaction
  , runInboxTransactionWithKey

    -- * Two-stage drain (EP-23 worker path)
  , enqueueInbox
  , enqueueInboxTx
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
        InboxPending -> pure InboxInProgress
        InboxFailed -> pure (InboxPreviouslyFailed (row ^. #lastError))
        InboxDead -> pure (InboxPreviouslyFailed (row ^. #lastError))

{- | Enqueue an integration event as a 'pending' inbox row.

This is the two-stage drain entry point: the caller writes the durable
receipt now, and a worker (typically
'Keiro.Inbox.Adapter.inboxAdapter') runs the handler later. Returns
'EnqueuedNew' on a fresh insert and 'EnqueueDuplicateOf' when
@(source, dedupe_key)@ already exists, so duplicate Kafka redeliveries
become observable to the caller.

This action runs its own transaction. Use 'enqueueInboxTx' when the
caller needs to compose the enqueue with other writes (a saga that
emits a private event and an integration receipt in one transaction).
-}
enqueueInbox ::
  (IOE :> es, Store :> es) =>
  InboxDedupePolicy ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  Eff es (Either InboxError InboxEnqueueOutcome)
enqueueInbox policy event kafka = do
  now <- liftIO getCurrentTime
  case dedupeKeyFor policy event kafka of
    Left err -> pure (Left err)
    Right dedupe ->
      Right <$> runTransaction (enqueuePendingTx (event ^. #source) dedupe event kafka now)

{- | 'enqueueInbox' as a 'Tx.Transaction' fragment so the caller can
weave it into a larger transaction.

The caller must supply the dedupe-key resolution outcome. Failure to
satisfy the policy stays in 'Either' so the enclosing transaction
decides whether to condemn or carry on. The caller also supplies the
"now" timestamp; pick one timestamp for the whole transaction so all
co-written rows share it.
-}
enqueueInboxTx ::
  InboxDedupePolicy ->
  IntegrationEvent ->
  Maybe KafkaDeliveryRef ->
  UTCTime ->
  Tx.Transaction (Either InboxError InboxEnqueueOutcome)
enqueueInboxTx policy event kafka now =
  case dedupeKeyFor policy event kafka of
    Left err -> pure (Left err)
    Right dedupe ->
      Right <$> enqueuePendingTx (event ^. #source) dedupe event kafka now
