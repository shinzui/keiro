{- | EP-4 runtime conformance: the scaffolded intake @Inbox@ module's disposition
wiring — the dedupe policy (a real @Keiro.Inbox.Types.InboxDedupePolicy@) and
the disposition over the real @InboxResult@ — compiled against the LIVE keiro
runtime. Running it pins the two dangerous inversions: a duplicate redelivery
is ackOk (success), and a previously-failed delivery dead-letters (not retry).
-}
module Main (main) where

import Control.Monad (unless)
import Generated.HospitalCapacity.IncidentInbox.Inbox (InboxAck (..), inboxDisposition, inboxPersistence)
import Keiro.Inbox.Types (InboxPersistence (..), InboxResult (..))
import System.Exit (exitFailure)

main :: IO ()
main = do
    let dupOk = inboxDisposition (InboxDuplicate :: InboxResult ()) == InboxAckOk
        pfOk = inboxDisposition (InboxPreviouslyFailed Nothing :: InboxResult ()) == InboxDeadLetter
        procOk = inboxDisposition (InboxProcessed () :: InboxResult ()) == InboxAckOk
        ipOk = inboxDisposition (InboxInProgress :: InboxResult ()) == InboxRetry
        persistenceOk = inboxPersistence == PersistDedupeOnly
    putStrLn ("duplicate => ackOk (inversion 1): " <> show dupOk)
    putStrLn ("previouslyFailed => deadLetter (inversion 2): " <> show pfOk)
    putStrLn ("processed => ackOk: " <> show procOk)
    putStrLn ("inProgress => retry: " <> show ipOk)
    putStrLn ("success persistence => dedupe-only: " <> show persistenceOk)
    unless (dupOk && pfOk && procOk && ipOk && persistenceOk) exitFailure
