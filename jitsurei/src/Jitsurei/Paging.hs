{- | The page aggregate and the paging router for the escalation worked example.

A page is the per-responder artifact: it is /Sent/ when the router pages a
responder and /Acknowledged/ when that responder responds. 'pagingRouter' is the
EIP content-based router / dynamic recipient list: for each @IncidentRaised@ it
looks up the on-call roster ('Jitsurei.OncallRoster.serviceOncallReadModel') and
dispatches one @SendPage@ per responder, idempotently. It keeps no state of its
own — the stateful side of the example is the escalation process manager in
"Jitsurei.EscalationProcess".
-}
module Jitsurei.Paging (
    PageCommand (..),
    SendPageData (..),
    AcknowledgePageData (..),
    PageEvent (..),
    PageSentData (..),
    PageAcknowledgedData (..),
    PageState (..),
    PageRegs,
    PageEventStream,
    pageEventStream,
    pageStream,
    pageCommandStream,
    pageTransducer,
    pageCodec,
    parsePageEvent,
    pagingRouter,
)
where

import Data.Aeson (Value, object, withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (IOE, liftIO, (:>))
import GHC.Generics (Generic)
import Jitsurei.Incident (IncidentId (..), IncidentRaisedData (..), incidentIdText)
import Jitsurei.OncallRoster (Responder (..), ResponderId (..), responderIdText, serviceOncallReadModel)
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, RegFile (..), SymTransducer)
import Keiki.Generics.TH (deriveAggregate)
import Keiro.Codec (Codec (..))
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.EventStream.Validate (ValidatedEventStream, mkEventStreamOrThrow)
import Keiro.ProcessManager (PMCommand (..))
import Keiro.ReadModel (runQuery)
import Keiro.Router (Router (..))
import Keiro.Stream (Stream)
import Keiro.Stream qualified as Stream
import Keiro.Telemetry (KeiroMetrics)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Types (EventType (..))

data PageCommand
    = SendPage !SendPageData
    | AcknowledgePage !AcknowledgePageData
    deriving stock (Generic, Eq, Show)

data SendPageData = SendPageData
    { incidentId :: !IncidentId
    , responderId :: !ResponderId
    }
    deriving stock (Generic, Eq, Show)

data AcknowledgePageData = AcknowledgePageData
    { incidentId :: !IncidentId
    , responderId :: !ResponderId
    }
    deriving stock (Generic, Eq, Show)

data PageEvent
    = PageSent !PageSentData
    | PageAcknowledged !PageAcknowledgedData
    deriving stock (Generic, Eq, Show)

data PageSentData = PageSentData
    { incidentId :: !IncidentId
    , responderId :: !ResponderId
    }
    deriving stock (Generic, Eq, Show)

data PageAcknowledgedData = PageAcknowledgedData
    { incidentId :: !IncidentId
    , responderId :: !ResponderId
    }
    deriving stock (Generic, Eq, Show)

data PageState
    = AwaitingSend
    | Pending
    | Acked
    deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

type PageRegs = '[]

type PageEventStream =
    EventStream (HsPred PageRegs PageCommand) PageRegs PageState PageCommand PageEvent

type ValidatedPageEventStream =
    ValidatedEventStream (HsPred PageRegs PageCommand) PageRegs PageState PageCommand PageEvent

$( deriveAggregate
    ''PageCommand
    ''PageRegs
    ''PageEvent
 )

pageEventStreamDef :: PageEventStream
pageEventStreamDef =
    EventStream
        { transducer = pageTransducer
        , initialState = AwaitingSend
        , initialRegisters = RNil
        , eventCodec = pageCodec
        , resolveStreamName = Stream.streamName
        , snapshotPolicy = Never
        , stateCodec = Nothing
        }

pageEventStream :: ValidatedPageEventStream
pageEventStream =
    mkEventStreamOrThrow "jitsurei-page" pageEventStreamDef

{- | A page stream is keyed by @(incident, responder)@: category @page@ with a
composite id segment @\<incident\>-\<responder\>@ (the @-@ after the category
boundary is part of the id and does not change the @page@ category).
-}
pageCategory :: Stream.StreamCategory a
pageCategory = Stream.categoryUnsafe "page"

pageStream :: IncidentId -> ResponderId -> Stream PageEventStream
pageStream incidentId responderId =
    Stream.entityStream pageCategory (incidentIdText incidentId <> "-" <> responderIdText responderId)

-- | Same stream, typed as a command target (for router dispatch).
pageCommandStream :: IncidentId -> ResponderId -> Stream PageCommand
pageCommandStream incidentId responderId =
    Stream.entityStream pageCategory (incidentIdText incidentId <> "-" <> responderIdText responderId)

pageTransducer ::
    SymTransducer (HsPred PageRegs PageCommand) PageRegs PageState PageCommand PageEvent
pageTransducer =
    B.buildTransducer AwaitingSend RNil (const False) do
        B.from AwaitingSend do
            B.onCmd inCtorSendPage $ \d -> B.do
                B.emit
                    wirePageSent
                    PageSentTermFields
                        { incidentId = d.incidentId
                        , responderId = d.responderId
                        }
                B.goto Pending

        B.from Pending do
            B.onCmd inCtorAcknowledgePage $ \d -> B.do
                B.emit
                    wirePageAcknowledged
                    PageAcknowledgedTermFields
                        { incidentId = d.incidentId
                        , responderId = d.responderId
                        }
                B.goto Acked

pageCodec :: Codec PageEvent
pageCodec =
    Codec
        { eventTypes = EventType "PageSent" :| [EventType "PageAcknowledged"]
        , eventType = \case
            PageSent{} -> EventType "PageSent"
            PageAcknowledged{} -> EventType "PageAcknowledged"
        , schemaVersion = 1
        , encode = \case
            PageSent payload ->
                object
                    [ "kind" Aeson..= ("PageSent" :: Text)
                    , "incidentId" Aeson..= incidentIdText payload.incidentId
                    , "responderId" Aeson..= responderIdText payload.responderId
                    ]
            PageAcknowledged payload ->
                object
                    [ "kind" Aeson..= ("PageAcknowledged" :: Text)
                    , "incidentId" Aeson..= incidentIdText payload.incidentId
                    , "responderId" Aeson..= responderIdText payload.responderId
                    ]
        , decode = parsePageEvent
        , upcasters = []
        }

parsePageEvent :: EventType -> Value -> Either Text PageEvent
parsePageEvent (EventType tag) value =
    case parseEither parser value of
        Right event -> Right event
        Left message -> Left (Text.pack message)
  where
    parser = withObject "PageEvent" $ \objectValue -> do
        incidentId <- IncidentId <$> objectValue .: "incidentId"
        responderId <- ResponderId <$> objectValue .: "responderId"
        case tag of
            "PageSent" ->
                pure (PageSent PageSentData{incidentId, responderId})
            "PageAcknowledged" ->
                pure (PageAcknowledged PageAcknowledgedData{incidentId, responderId})
            _ -> fail "unknown page event type"

{- | The paging router: for each raised incident, page every responder on call
for its service. The recipient set is resolved effectfully from the on-call
read model, and each dispatch is idempotent (deterministic command id).
-}
pagingRouter ::
    (IOE :> es, Store :> es) =>
    Maybe KeiroMetrics ->
    Router IncidentRaisedData (HsPred PageRegs PageCommand) PageRegs PageState PageCommand PageEvent es
pagingRouter metrics =
    Router
        { name = "jitsurei-paging"
        , key = \raised -> incidentIdText raised.incidentId
        , resolve = \raised -> do
            result <- runQuery metrics serviceOncallReadModel raised.service
            responders <-
                case result of
                    Left err ->
                        liftIO
                            ( ioError
                                (userError ("jitsurei paging read model is unavailable: " <> show err))
                            )
                    Right rows -> pure rows
            pure
                [ PMCommand
                    { target = pageCommandStream raised.incidentId responder.responderId
                    , command = SendPage (SendPageData{incidentId = raised.incidentId, responderId = responder.responderId})
                    }
                | responder <- responders
                ]
        , targetEventStream = pageEventStream
        , targetProjections = const []
        }
