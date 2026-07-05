{- | A worked example of 'Keiro.Router.Router' modelled on the
agent-qualification decomposition in
@docs/research/13-agent-qualification-runtime-wiring.md@ (§3).

A single property-sale transaction must be routed to every "chapter" whose
geographic service areas overlap the transaction's areas. That target set is not
a pure function of the event — it is /looked up/ from a read model
('areaChaptersReadModel'). 'agentQualRouter' performs that effectful lookup in
its @resolve@ and dispatches one @RecordTransaction@ command per resolved
chapter stream, with the crash-safe, exactly-once-per-target idempotency the
router provides.

The chapter aggregate here is intentionally minimal: one command
('RecordTransaction') that emits one event ('TransactionRecorded'). The
demonstration is the effectful fan-out and idempotent replay, not the chapter's
internal domain.
-}
module Jitsurei.AgentQualRouter (
    -- * Identifiers
    AreaId (..),
    MemberId (..),
    ChapterId (..),
    TxnId (..),
    areaIdText,
    memberIdText,
    chapterIdText,
    txnIdText,

    -- * Routing input and resolved targets
    Transaction (..),
    ChapterTarget (..),

    -- * The chapter target aggregate
    ChapterCommand (..),
    RecordTransactionData (..),
    ChapterEvent (..),
    TransactionRecordedData (..),
    ChapterState (..),
    ChapterRegs,
    ChapterEventStream,
    chapterEventStream,
    chapterStream,
    chapterCodec,
    chapterTransducer,

    -- * The read model and the router
    areaChaptersReadModel,
    agentQualRouter,

    -- * Schema helpers (for tests / setup)
    initializeAreaChaptersTable,
    insertAreaChapterStmt,
    selectAreaChaptersStmt,
)
where

import Contravariant.Extras (contrazip3)
import Data.Aeson (Value, object, withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import GHC.Generics (Generic)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, RegFile (..), SymTransducer)
import Keiki.Generics.TH (deriveAggregate)
import Keiro.Codec (Codec (..))
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.EventStream.Validate (ValidatedEventStream, mkEventStreamOrThrow)
import Keiro.ProcessManager (PMCommand (..))
import Keiro.ReadModel (ConsistencyMode (..), ReadModel (..), runQuery)
import Keiro.Router (Router (..))
import Keiro.Stream (Stream)
import Keiro.Stream qualified as Stream
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Types (EventType (..))
import "hasql-transaction" Hasql.Transaction qualified as Tx

newtype AreaId = AreaId Text
    deriving stock (Generic, Eq, Ord, Show)

newtype MemberId = MemberId Text
    deriving stock (Generic, Eq, Ord, Show)

newtype ChapterId = ChapterId Text
    deriving stock (Generic, Eq, Ord, Show)

newtype TxnId = TxnId Text
    deriving stock (Generic, Eq, Ord, Show)

areaIdText :: AreaId -> Text
areaIdText (AreaId value) = value

memberIdText :: MemberId -> Text
memberIdText (MemberId value) = value

chapterIdText :: ChapterId -> Text
chapterIdText (ChapterId value) = value

txnIdText :: TxnId -> Text
txnIdText (TxnId value) = value

{- | The triggering event's routing-relevant projection: a transaction id and
the geographic areas it touches.
-}
data Transaction = Transaction
    { txnId :: !TxnId
    , areas :: ![AreaId]
    }
    deriving stock (Generic, Eq, Show)

{- | A chapter resolved from a transaction's areas: which member's chapter
stream should record the transaction.
-}
data ChapterTarget = ChapterTarget
    { member :: !MemberId
    , chapter :: !ChapterId
    }
    deriving stock (Generic, Eq, Ord, Show)

data ChapterCommand
    = RecordTransaction !RecordTransactionData
    deriving stock (Generic, Eq, Show)

data RecordTransactionData = RecordTransactionData
    { txnId :: !TxnId
    }
    deriving stock (Generic, Eq, Show)

data ChapterEvent
    = TransactionRecorded !TransactionRecordedData
    deriving stock (Generic, Eq, Show)

data TransactionRecordedData = TransactionRecordedData
    { txnId :: !TxnId
    }
    deriving stock (Generic, Eq, Show)

data ChapterState
    = ChapterOpen
    deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

type ChapterRegs = '[]

type ChapterEventStream =
    EventStream (HsPred ChapterRegs ChapterCommand) ChapterRegs ChapterState ChapterCommand ChapterEvent

type ValidatedChapterEventStream =
    ValidatedEventStream (HsPred ChapterRegs ChapterCommand) ChapterRegs ChapterState ChapterCommand ChapterEvent

$( deriveAggregate
    ''ChapterCommand
    ''ChapterRegs
    ''ChapterEvent
 )

chapterEventStreamDef :: ChapterEventStream
chapterEventStreamDef =
    EventStream
        { transducer = chapterTransducer
        , initialState = ChapterOpen
        , initialRegisters = RNil
        , eventCodec = chapterCodec
        , resolveStreamName = Stream.streamName
        , snapshotPolicy = Never
        , stateCodec = Nothing
        }

chapterEventStream :: ValidatedChapterEventStream
chapterEventStream =
    mkEventStreamOrThrow "jitsurei-chapter" chapterEventStreamDef

{- | The chapter stream a @(member, chapter)@ pair records into: category
@chapter@ with a composite id segment @\<member\>-\<chapter\>@.
-}
chapterCategory :: Stream.StreamCategory a
chapterCategory = Stream.categoryUnsafe "chapter"

chapterStream :: MemberId -> ChapterId -> Stream ChapterCommand
chapterStream member chapter =
    Stream.entityStream chapterCategory (memberIdText member <> "-" <> chapterIdText chapter)

chapterTransducer ::
    SymTransducer (HsPred ChapterRegs ChapterCommand) ChapterRegs ChapterState ChapterCommand ChapterEvent
chapterTransducer =
    B.buildTransducer ChapterOpen RNil (const False) do
        B.from ChapterOpen do
            B.onCmd inCtorRecordTransaction $ \d -> B.do
                B.emit
                    wireTransactionRecorded
                    TransactionRecordedTermFields
                        { txnId = d.txnId
                        }
                B.goto ChapterOpen

chapterCodec :: Codec ChapterEvent
chapterCodec =
    Codec
        { eventTypes = EventType "TransactionRecorded" :| []
        , eventType = \case
            TransactionRecorded{} -> EventType "TransactionRecorded"
        , schemaVersion = 1
        , encode = \case
            TransactionRecorded payload ->
                object
                    [ "kind" Aeson..= ("TransactionRecorded" :: Text)
                    , "txnId" Aeson..= txnIdText payload.txnId
                    ]
        , decode = parseChapterEvent
        , upcasters = []
        }

parseChapterEvent :: EventType -> Value -> Either Text ChapterEvent
parseChapterEvent (EventType tag) value =
    case parseEither parser value of
        Right event -> Right event
        Left message -> Left (Text.pack message)
  where
    parser = withObject "ChapterEvent" $ \objectValue -> do
        case tag of
            "TransactionRecorded" ->
                TransactionRecorded . TransactionRecordedData . TxnId
                    <$> objectValue .: "txnId"
            _ -> fail "unknown chapter event type"

{- | Maps a geographic area to the @(member, chapter)@ pairs whose service areas
include it. The router queries this per area in 'agentQualRouter'.
-}
areaChaptersReadModel :: ReadModel AreaId [ChapterTarget]
areaChaptersReadModel =
    ReadModel
        { name = "jitsurei-area-chapters"
        , tableName = "jitsurei_area_chapters"
        , -- Unqualified DDL/DML, so this table resolves in the store search_path's
          -- first schema (kiroku). Only the order-summary read model is migrated to
          -- a user-configured schema (EP-4 / MasterPlan 12).
          schema = "kiroku"
        , subscriptionName = "jitsurei-area-chapters-sub"
        , version = 1
        , shapeHash = "jitsurei-area-chapters-v1"
        , defaultConsistency = Eventual
        , query = \(AreaId area) -> Tx.statement area selectAreaChaptersStmt
        }

{- | The router: for each incoming transaction, look up every chapter whose
service areas overlap the transaction's areas (de-duplicated across areas)
and dispatch one @RecordTransaction@ command per chapter stream.
-}
agentQualRouter ::
    (IOE :> es, Store :> es) =>
    Router
        Transaction
        (HsPred ChapterRegs ChapterCommand)
        ChapterRegs
        ChapterState
        ChapterCommand
        ChapterEvent
        es
agentQualRouter =
    Router
        { name = "agent-qual-router"
        , key = \transaction -> txnIdText transaction.txnId
        , resolve = \transaction -> do
            resolved <- traverse (runQuery Nothing areaChaptersReadModel) transaction.areas
            let targets = nub (concat [chapters | Right chapters <- resolved])
            pure
                [ PMCommand
                    { target = chapterStream target.member target.chapter
                    , command = RecordTransaction (RecordTransactionData{txnId = transaction.txnId})
                    }
                | target <- targets
                ]
        , targetEventStream = chapterEventStream
        , targetProjections = const []
        }

initializeAreaChaptersTable :: Tx.Transaction ()
initializeAreaChaptersTable =
    Tx.sql
        """
        CREATE TABLE IF NOT EXISTS jitsurei_area_chapters (
          area_id TEXT NOT NULL,
          member_id TEXT NOT NULL,
          chapter_id TEXT NOT NULL
        )
        """

insertAreaChapterStmt :: Statement (Text, Text, Text) ()
insertAreaChapterStmt =
    preparable
        """
        INSERT INTO jitsurei_area_chapters (area_id, member_id, chapter_id)
        VALUES ($1, $2, $3)
        """
        ( contrazip3
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
        )
        D.noResult

selectAreaChaptersStmt :: Statement Text [ChapterTarget]
selectAreaChaptersStmt =
    preparable
        """
        SELECT member_id, chapter_id
        FROM jitsurei_area_chapters
        WHERE area_id = $1
        ORDER BY member_id, chapter_id
        """
        (E.param (E.nonNullable E.text))
        ( D.rowList
            ( ChapterTarget
                <$> (MemberId <$> D.column (D.nonNullable D.text))
                <*> (ChapterId <$> D.column (D.nonNullable D.text))
            )
        )
