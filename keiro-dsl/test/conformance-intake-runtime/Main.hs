-- | EP-4 runtime conformance: the scaffolded intake @Inbox@ module's disposition
-- wiring — the dedupe policy (a real @Keiro.Inbox.Types.InboxDedupePolicy@) and
-- the disposition over the real @InboxResult@ — compiled against the LIVE keiro
-- runtime. Running it pins the two dangerous inversions: a duplicate redelivery
-- is ackOk (success), and a previously-failed delivery dead-letters (not retry).
module Main (main) where

import Control.Monad (unless)
import Generated.HospitalCapacity.IncidentInbox.Inbox (InboxFailure (..), IncidentInboxDisposition (..), IncidentInboxOutcome (..), inboxDisposition, inboxDispositionFor, inboxPersistence)
import Keiro.Inbox.Types (InboxPersistence (..), InboxResult (..), RetryDelay (..))
import System.Exit (exitFailure)

main :: IO ()
main = do
  let dupOk = inboxDisposition (InboxDuplicate :: InboxResult ()) == InboxAccept
      pfOk = inboxDisposition (InboxPreviouslyFailed Nothing :: InboxResult ()) == InboxDeadLetter (Just "previous inbox failure") Nothing
      previousFailureDetailOk =
        inboxDisposition (InboxPreviouslyFailed (Just "poison detail") :: InboxResult ())
          == InboxDeadLetter (Just "previous inbox failure") (Just (InboxFailure "poison detail" Nothing))
      procOk = inboxDisposition (InboxProcessed () :: InboxResult ()) == InboxAccept
      ipOk = inboxDisposition (InboxInProgress :: InboxResult ()) == InboxRetryAfter (RetryDelay 5) Nothing
      handlerFailureOk =
        inboxDisposition (InboxHandlerFailed "database unavailable" 2 :: InboxResult ())
          == InboxRetryAfter (RetryDelay 5) (Just (InboxFailure "database unavailable" (Just 2)))
      completeTableOk =
        inboxDispositionFor IncidentInboxDecodeFailed == InboxDeadLetter Nothing Nothing
          && inboxDispositionFor IncidentInboxDedupeFailed == InboxDeadLetter Nothing Nothing
          && inboxDispositionFor IncidentInboxStoreFailed == InboxRetryAfter (RetryDelay 5) Nothing
      persistenceOk = inboxPersistence == PersistDedupeOnly
  putStrLn ("duplicate => ackOk (inversion 1): " <> show dupOk)
  putStrLn ("previouslyFailed => deadLetter (inversion 2): " <> show pfOk)
  putStrLn ("previouslyFailed retains declared and runtime reasons: " <> show previousFailureDetailOk)
  putStrLn ("processed => ackOk: " <> show procOk)
  putStrLn ("inProgress => retry: " <> show ipOk)
  putStrLn ("handler failure retains reason and attempt: " <> show handlerFailureOk)
  putStrLn ("handler-level table is exhaustive and detailed: " <> show completeTableOk)
  putStrLn ("success persistence => dedupe-only: " <> show persistenceOk)
  unless (dupOk && pfOk && previousFailureDetailOk && procOk && ipOk && handlerFailureOk && completeTableOk && persistenceOk) exitFailure
