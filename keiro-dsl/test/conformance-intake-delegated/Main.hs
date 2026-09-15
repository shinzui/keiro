module Main (main) where

import Control.Monad (unless)
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (runEff)
import Generated.HospitalCapacity.IncidentInbox.Inbox (inboxIdempotence)
import HospitalCapacity.IncidentInbox.DelegatedIntegration (runIncidentInbox)
import Keiro.Inbox.Types (DelegatedOutcome (..), InboxIdempotence (..), InboxResult (..))
import Keiro.Integration.Event (IntegrationContentType (..), IntegrationEvent (..))
import System.Exit (exitFailure)

main :: IO ()
main = do
  fresh <- runEff $ runIncidentInbox event Nothing (\key _ -> pure (DelegatedFresh key))
  duplicate <- runEff $ runIncidentInbox event Nothing (\_ _ -> pure (DelegatedDuplicate :: DelegatedOutcome Text))
  let modeOk = inboxIdempotence == IdempotenceDelegated
      freshOk = fresh == Right (InboxProcessed "delegated-message")
      duplicateOk = duplicate == Right InboxDuplicate
  putStrLn ("delegated idempotence mode: " <> show modeOk)
  putStrLn ("generated runner returns fresh: " <> show freshOk)
  putStrLn ("generated runner returns duplicate: " <> show duplicateOk)
  unless (modeOk && freshOk && duplicateOk) exitFailure
  where
    event =
      IntegrationEvent
        { messageId = "delegated-message",
          source = "hospital-capacity",
          destination = "billing",
          key = Nothing,
          eventType = "IncidentTransferNeedDeclared",
          schemaVersion = 1,
          contentType = ApplicationJson,
          schemaReference = Nothing,
          sourceEventId = Nothing,
          sourceGlobalPosition = Nothing,
          payloadBytes = "{}",
          occurredAt = UTCTime (fromGregorian 2026 9 15) 0,
          causationId = Nothing,
          correlationId = Nothing,
          traceContext = Nothing,
          attributes = Nothing
        }
