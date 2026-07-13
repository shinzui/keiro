{- | Durable records for process-manager and router dispatches rejected by a
target state machine.

Use 'recordDispatchDeadLetter' from a worker before acknowledging its source
event, and 'listDispatchDeadLetters' to inspect the durable witnesses for one
dispatcher. Inserts are idempotent under source-event redelivery.
-}
module Keiro.DeadLetter (
    DispatcherKind (..),
    DispatchDeadLetter (..),
    DispatchDeadLetterRecord (..),
    recordDispatchDeadLetter,
    listDispatchDeadLetters,
)
where

import Effectful (Eff, (:>))
import Keiro.DeadLetter.Schema (
    DispatchDeadLetter (..),
    DispatchDeadLetterRecord (..),
    DispatcherKind (..),
    listDispatchDeadLettersTx,
    recordDispatchDeadLetterTx,
 )
import Keiro.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)

-- | Idempotently persist one rejected dispatch.
recordDispatchDeadLetter :: (Store :> es) => DispatchDeadLetter -> Eff es ()
recordDispatchDeadLetter = runTransaction . recordDispatchDeadLetterTx

-- | List one dispatcher's rejected dispatches, newest first.
listDispatchDeadLetters :: (Store :> es) => Text -> Eff es [DispatchDeadLetterRecord]
listDispatchDeadLetters = runTransaction . listDispatchDeadLettersTx
