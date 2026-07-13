{- | Operator replay for source events parked in Kiroku's
@kiroku.dead_letters@ table.

The rows remain Kiroku-owned: replay neither deletes nor marks them. Instead it
re-runs a caller-supplied handler and relies on that handler's idempotency. This
is safe for "Keiro.ProcessManager" and "Keiro.Router" handlers because their
writes use deterministic event identifiers derived from the source event;
already-applied writes collapse to duplicate outcomes on every later replay.

Kiroku exposes dead-letter rows by event id and global position, but does not
currently expose an exact point-read by either value. Global positions are
opaque cursors and must never be decremented. 'replaySubscriptionDeadLetters'
therefore scans the global stream backward using only @0@ and cursors returned
by Kiroku, matches both event id and position, and scans once for the whole
batch. A source event removed by hard deletion is reported as
'ReplaySourceMissing' and is not handed to the caller.

A process-manager handler normally decodes the recorded event, calls
@runProcessManagerOnce@, and classifies a result whose manager state and every
target command are duplicates as 'ReplayedDuplicate'; any append makes it
'ReplayedFresh'. Return @Left detail@ for a decode or command failure. For
example, the classification has this shape:

> case result of
>   Left err -> Left (showText err)
>   Right pmResult
>     | managerAndEveryCommandAreDuplicates pmResult -> Right ReplayedDuplicate
>     | otherwise -> Right ReplayedFresh

Because rows are retained, an operator may safely run the same replay command
again after a partial failure or uncertain client disconnect.
-}
module Keiro.DeadLetter.Replay (
    ReplayOutcome (..),
    ReplayResult (..),
    DeadLetterRecord (..),
    listSubscriptionDeadLetters,
    replaySubscriptionDeadLetters,
)
where

import Data.Int (Int32)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Effectful (Eff, (:>))
import Keiro.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Read (readAllBackward)
import Kiroku.Store.SQL (DeadLetterRecord (..), readDeadLettersStmt)
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..), GlobalPosition (..), RecordedEvent)
import "hasql-transaction" Hasql.Transaction qualified as Tx

data ReplayOutcome = ReplayOutcome
    { replayGlobalPosition :: !GlobalPosition
    , replayEventId :: !EventId
    , replayResult :: !ReplayResult
    }
    deriving stock (Generic, Eq, Show)

data ReplayResult
    = ReplayedFresh
    | ReplayedDuplicate
    | ReplayFailed !Text
    | ReplaySourceMissing
    deriving stock (Generic, Eq, Show)

-- | List one Kiroku subscription member's dead letters, newest first.
listSubscriptionDeadLetters ::
    (Store :> es) => SubscriptionName -> Int32 -> Eff es (Vector DeadLetterRecord)
listSubscriptionDeadLetters (SubscriptionName name) member =
    runTransaction (Tx.statement (name, member) readDeadLettersStmt)

{- | Replay every dead letter currently listed for one subscription member.

The handler controls domain-specific decoding and decides whether its writes
were fresh or duplicates. A @Left detail@ is recorded in the corresponding
'ReplayOutcome' as 'ReplayFailed'; replay continues with later rows. Store
errors still surface through the surrounding Kiroku 'Store' interpreter.
-}
replaySubscriptionDeadLetters ::
    (Store :> es) =>
    SubscriptionName ->
    Int32 ->
    (RecordedEvent -> Eff es (Either Text ReplayResult)) ->
    Eff es [ReplayOutcome]
replaySubscriptionDeadLetters subscriptionName member handler = do
    rows <- listSubscriptionDeadLetters subscriptionName member
    sources <- findSources rows
    traverse (replayOne sources) (Vector.toList rows)
  where
    replayOne sources row = do
        let position = deadLetterPosition row
            eventId = deadLetterEventIdValue row
        result <- case Map.lookup eventId sources of
            Just event
                | event ^. #globalPosition == position -> do
                    handled <- handler event
                    pure (either ReplayFailed id handled)
            _ -> pure ReplaySourceMissing
        pure
            ReplayOutcome
                { replayGlobalPosition = position
                , replayEventId = eventId
                , replayResult = result
                }

-- Scan once for the complete replay batch. Pages are descending, and the next
-- cursor is always a position Kiroku returned; no global-position arithmetic.
findSources ::
    (Store :> es) => Vector DeadLetterRecord -> Eff es (Map EventId RecordedEvent)
findSources rows = go (GlobalPosition 0) Map.empty
  where
    wanted =
        Map.fromList
            [ (deadLetterEventIdValue row, deadLetterPosition row)
            | row <- Vector.toList rows
            ]

    go cursor found
        | Map.size found == Map.size wanted = pure found
        | otherwise = do
            page <- readAllBackward cursor replayReadPageSize
            if Vector.null page
                then pure found
                else do
                    let found' = Vector.foldl' remember found page
                        nextCursor = Vector.last page ^. #globalPosition
                    go nextCursor found'

    remember found event =
        case Map.lookup (event ^. #eventId) wanted of
            Just expectedPosition
                | event ^. #globalPosition == expectedPosition ->
                    Map.insert (event ^. #eventId) event found
            _ -> found

replayReadPageSize :: Int32
replayReadPageSize = 256

deadLetterPosition :: DeadLetterRecord -> GlobalPosition
deadLetterPosition row = GlobalPosition (row ^. #deadLetterGlobalPosition)

deadLetterEventIdValue :: DeadLetterRecord -> EventId
deadLetterEventIdValue row = EventId (row ^. #deadLetterEventId)
