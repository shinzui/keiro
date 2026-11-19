-- | Live conformance for a generated delegated intake whose downstream command
-- has a typed no-op edge. The generated 'runInboxIntake' drives the
-- hand-written handler against PostgreSQL: an accepted outcome is
-- acknowledged by its marker event, a typed no-op by one completed inbox row,
-- a redelivered no-op is a duplicate without dispatching, and the historical
-- untyped adapter still refuses the same silent edge.
module Main (main) where

import Control.Monad (unless)
import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Data.Vector qualified as Vector
import DeliveryOutcomes.DeliveryOutcomeInbox.DelegatedIntegration
import Effectful (liftIO)
import Effectful.Error.Static (runErrorNoCallStack)
import Generated.DeliveryOutcomes.Courier.Contract (CourierPayload (..), DeliveryOutcomeReportedData (..), encodeCourierPayload)
import Generated.DeliveryOutcomes.DeliveryOutcomeInbox.Inbox (inboxIdempotence)
import Generated.DeliveryOutcomes.Nominals (DeliveryNoOp (..))
import Keiro.Inbox.Delegated (DelegatedCommandError (..), DelegatedDomainResult (..), delegatedEventId, delegatedNoOpReceiptKey)
import Keiro.Inbox.Schema (listInbox, lookupInbox)
import Keiro.Command (CommandResult (..))
import Keiro.Inbox.Types (InboxIdempotence (..), InboxResult (..), InboxRow (..), InboxStatus (..))
import Keiro.Integration.Event (IntegrationContentType (..), IntegrationEvent (..))
import Keiro.Stream (streamName)
import Keiro.Test.Postgres (StoreRunner (..), withFreshResourceStore, withMigratedSuite)
import Kiroku.Store qualified as Store
import Kiroku.Store.Types (RecordedEvent (..), StreamVersion (..))
import System.Exit (exitFailure)

main :: IO ()
main =
  withMigratedSuite $ \fixture ->
    withFreshResourceStore fixture $ \(_storeHandle, StoreRunner runStore) -> do
      dispatches <- newIORef (0 :: Int)
      let countDispatch = liftIO (modifyIORef' dispatches (+ 1))
          typed event =
            runStore (runErrorNoCallStack @DeliveryIntakeFailure (runDeliveryOutcomeInbox event Nothing (typedDeliveryHandler countDispatch Nothing)))
          untyped event =
            runStore (runErrorNoCallStack @DeliveryIntakeFailure (runDeliveryOutcomeInbox event Nothing untypedDeliveryHandler))
          target = streamName (deliveryTarget "delivery-1")
          markerFor event = delegatedEventId consumerName event.source event.messageId target recordOutcomeOperation
          storedIds = do
            stored <- runStore (Store.readStreamForward target (StreamVersion 0) 10)
            pure (fmap (fmap (.eventId) . Vector.toList) stored)
          inboxRows = runStore (listInbox courierSource)

      let delivered = report "outcome-1" "delivered"
      accepted <- typed delivered
      idsAfterAccepted <- storedIds
      rowsAfterAccepted <- inboxRows
      let acceptedOk =
            ( case accepted of
                Right (Right (Right (InboxProcessed (DelegatedDomainAccepted _ result)))) -> result.eventsAppended == 1
                _ -> False
            )
              && idsAfterAccepted == Right [markerFor delivered]
              && rowsAfterAccepted == Right []

      let lateFailure = report "outcome-2" "failed"
      noOp <- typed lateFailure
      idsAfterNoOp <- storedIds
      rowsAfterNoOp <- inboxRows
      let noOpOk =
            ( case noOp of
                Right (Right (Right (InboxProcessed (DelegatedDomainNoOp AlreadyFinal result)))) -> result.eventsAppended == 0
                _ -> False
            )
              && idsAfterNoOp == Right [markerFor delivered]
              && fmap (fmap (\row -> (row.dedupeKey, row.status))) rowsAfterNoOp
                == Right [(delegatedNoOpReceiptKey (markerFor lateFailure), InboxCompleted)]

      dispatchesBeforeReplay <- readIORef dispatches
      replay <- typed lateFailure
      dispatchesAfterReplay <- readIORef dispatches
      let replayOk =
            replay == Right (Right (Right InboxDuplicate))
              && dispatchesBeforeReplay == 2
              && dispatchesAfterReplay == 2

      let untypedLateFailure = report "outcome-3" "failed"
      refused <- untyped untypedLateFailure
      idsAfterRefused <- storedIds
      rowsAfterRefused <- inboxRows
      rawRow <- runStore (lookupInbox courierSource untypedLateFailure.messageId)
      scopedRow <- runStore (lookupInbox courierSource (delegatedNoOpReceiptKey (markerFor untypedLateFailure)))
      let untypedOk =
            refused == Right (Left (UntypedAdapterFailed (DelegatedCommandWithoutReceipt target)))
              && idsAfterRefused == Right [markerFor delivered]
              && fmap length rowsAfterRefused == Right 1
              && rawRow == Right Nothing
              && scopedRow == Right Nothing

      let modeOk = inboxIdempotence == IdempotenceDelegated
      check "generated intake uses delegated idempotence" modeOk
      check "accepted delivery appends the marker event and writes no inbox row" acceptedOk
      check "typed no-op delivery is processed and records one completed inbox row" noOpOk
      check "redelivered no-op is a duplicate without dispatching the command" replayOk
      check "untyped silent success returns DelegatedCommandWithoutReceipt and leaves no receipt" untypedOk
      unless (and [modeOk, acceptedOk, noOpOk, replayOk, untypedOk]) exitFailure

check :: String -> Bool -> IO ()
check label ok = putStrLn (label <> ": " <> show ok)

courierSource :: Text
courierSource = "courier"

report :: Text -> Text -> IntegrationEvent
report messageId outcome =
  IntegrationEvent
    { messageId,
      source = courierSource,
      destination = "reputation",
      key = Just "delivery-1",
      eventType = "DeliveryOutcomeReported",
      schemaVersion = 1,
      contentType = ApplicationJson,
      schemaReference = Nothing,
      sourceEventId = Nothing,
      sourceGlobalPosition = Nothing,
      payloadBytes =
        LazyByteString.toStrict
          (encode (encodeCourierPayload (DeliveryOutcomeReported (DeliveryOutcomeReportedData "delivery-1" outcome)))),
      occurredAt = UTCTime (fromGregorian 2026 11 18) 0,
      causationId = Nothing,
      correlationId = Nothing,
      traceContext = Nothing,
      attributes = Nothing
    }

