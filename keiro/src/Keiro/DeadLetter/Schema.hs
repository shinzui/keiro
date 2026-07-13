{- | SQL storage for rejected process-manager and router dispatches.

The @keiro.keiro_dead_letters@ table records a dispatched command that a
target state machine rejected. It is deliberately separate from Kiroku's
subscription dead-letter table: a row here describes one failed dispatch,
while the source subscription event is considered handled and may advance its
checkpoint.
-}
module Keiro.DeadLetter.Schema (
    DispatcherKind (..),
    DispatchDeadLetter (..),
    DispatchDeadLetterRecord (..),
    recordDispatchDeadLetterTx,
    listDispatchDeadLettersTx,
)
where

import Contravariant.Extras (contrazip10)
import Data.Int (Int32)
import Data.Text qualified as Text
import Data.UUID (UUID)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import Kiroku.Store.Types (EventId (..), GlobalPosition (..), StreamName (..))
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude (fromIntegral)

-- | Which coordination primitive attempted the rejected dispatch.
data DispatcherKind
    = DispatcherProcessManager
    | DispatcherRouter
    deriving stock (Generic, Eq, Ord, Show)

-- | Fields persisted for one rejected dispatch.
data DispatchDeadLetter = DispatchDeadLetter
    { dispatcherKind :: !DispatcherKind
    , dispatcherName :: !Text
    , correlationId :: !Text
    , sourceEventId :: !EventId
    , sourceGlobalPosition :: !GlobalPosition
    , emitIndex :: !Int
    , targetStreamName :: !StreamName
    , errorClass :: !Text
    , errorDetail :: !Text
    , attemptCount :: !Int
    }
    deriving stock (Generic, Eq, Show)

-- | A persisted rejected dispatch, including database-managed identity and time.
data DispatchDeadLetterRecord = DispatchDeadLetterRecord
    { deadLetterId :: !Int64
    , dispatcherKind :: !DispatcherKind
    , dispatcherName :: !Text
    , correlationId :: !Text
    , sourceEventId :: !EventId
    , sourceGlobalPosition :: !GlobalPosition
    , emitIndex :: !Int
    , targetStreamName :: !StreamName
    , errorClass :: !Text
    , errorDetail :: !Text
    , attemptCount :: !Int
    , createdAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)

{- | Insert a rejected dispatch inside the caller's transaction. Redelivery is
idempotent: a duplicate @(dispatcher_name, source_event_id, emit_index)@ is a
no-op. Error detail is bounded here so every caller gets the same 1024-character
storage contract.
-}
recordDispatchDeadLetterTx :: DispatchDeadLetter -> Tx.Transaction ()
recordDispatchDeadLetterTx deadLetter =
    Tx.statement (dispatchDeadLetterParams deadLetter) insertDispatchDeadLetterStmt

-- | List one dispatcher's records, newest first.
listDispatchDeadLettersTx :: Text -> Tx.Transaction [DispatchDeadLetterRecord]
listDispatchDeadLettersTx dispatcher =
    Tx.statement dispatcher listDispatchDeadLettersStmt

insertDispatchDeadLetterStmt :: Statement (Text, Text, Text, UUID, Int64, Int32, Text, Text, Text, Int32) ()
insertDispatchDeadLetterStmt =
    preparable
        """
        INSERT INTO keiro.keiro_dead_letters
          (dispatcher_kind, dispatcher_name, correlation_id, source_event_id,
           source_global_position, emit_index, target_stream_name, error_class,
           error_detail, attempt_count)
        VALUES
          ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        ON CONFLICT (dispatcher_name, source_event_id, emit_index) DO NOTHING
        """
        ( contrazip10
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable E.int8))
            (E.param (E.nonNullable E.int4))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int4))
        )
        D.noResult

listDispatchDeadLettersStmt :: Statement Text [DispatchDeadLetterRecord]
listDispatchDeadLettersStmt =
    preparable
        """
        SELECT dead_letter_id, dispatcher_kind, dispatcher_name, correlation_id,
               source_event_id, source_global_position, emit_index,
               target_stream_name, error_class, error_detail, attempt_count,
               created_at
        FROM keiro.keiro_dead_letters
        WHERE dispatcher_name = $1
        ORDER BY created_at DESC, dead_letter_id DESC
        """
        (E.param (E.nonNullable E.text))
        (D.rowList dispatchDeadLetterRecordDecoder)

dispatchDeadLetterRecordDecoder :: D.Row DispatchDeadLetterRecord
dispatchDeadLetterRecordDecoder =
    DispatchDeadLetterRecord
        <$> D.column (D.nonNullable D.int8)
        <*> D.column (D.nonNullable (D.refine dispatcherKindFromText D.text))
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.text)
        <*> (EventId <$> D.column (D.nonNullable D.uuid))
        <*> (GlobalPosition <$> D.column (D.nonNullable D.int8))
        <*> (fromIntegral <$> D.column (D.nonNullable D.int4))
        <*> (StreamName <$> D.column (D.nonNullable D.text))
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.text)
        <*> (fromIntegral <$> D.column (D.nonNullable D.int4))
        <*> D.column (D.nonNullable D.timestamptz)

dispatchDeadLetterParams :: DispatchDeadLetter -> (Text, Text, Text, UUID, Int64, Int32, Text, Text, Text, Int32)
dispatchDeadLetterParams deadLetter =
    ( dispatcherKindToText (deadLetter ^. #dispatcherKind)
    , deadLetter ^. #dispatcherName
    , deadLetter ^. #correlationId
    , eventIdToUuid (deadLetter ^. #sourceEventId)
    , globalPositionToInt64 (deadLetter ^. #sourceGlobalPosition)
    , fromIntegral (deadLetter ^. #emitIndex)
    , streamNameToText (deadLetter ^. #targetStreamName)
    , deadLetter ^. #errorClass
    , Text.take 1024 (deadLetter ^. #errorDetail)
    , fromIntegral (deadLetter ^. #attemptCount)
    )

dispatcherKindToText :: DispatcherKind -> Text
dispatcherKindToText = \case
    DispatcherProcessManager -> "process-manager"
    DispatcherRouter -> "router"

dispatcherKindFromText :: Text -> Either Text DispatcherKind
dispatcherKindFromText = \case
    "process-manager" -> Right DispatcherProcessManager
    "router" -> Right DispatcherRouter
    other -> Left ("unknown keiro_dead_letters.dispatcher_kind: " <> other)

eventIdToUuid :: EventId -> UUID
eventIdToUuid (EventId uuid) = uuid

globalPositionToInt64 :: GlobalPosition -> Int64
globalPositionToInt64 (GlobalPosition position) = position

streamNameToText :: StreamName -> Text
streamNameToText (StreamName name) = name
