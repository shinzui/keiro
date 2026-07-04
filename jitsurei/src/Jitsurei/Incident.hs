{- | The incident aggregate for the on-call escalation worked example
(see @docs/guides/coordinating-incident-response-with-routers-and-process-managers.md@).

An incident is raised against a service at a severity, then either acknowledged
by a responder or escalated when the acknowledgement window lapses, and finally
resolved. The state machine deliberately makes @AcknowledgeIncident@ legal only
from @Triaging@ and @EscalateIncident@ legal only from @Triaging@: whichever
happens first wins, and the loser is a benign 'CommandRejected'. That guard is
what makes the escalation timer (driven from the process manager) safe to fire
even when an incident has already been acknowledged.
-}
module Jitsurei.Incident (
    -- * Identifiers
    IncidentId (..),
    Service (..),
    Severity (..),
    incidentIdText,
    serviceText,
    severityText,
    parseSeverity,

    -- * Commands and events
    IncidentCommand (..),
    RaiseIncidentData (..),
    AcknowledgeIncidentData (..),
    EscalateIncidentData (..),
    ResolveIncidentData (..),
    IncidentEvent (..),
    IncidentRaisedData (..),
    IncidentAcknowledgedData (..),
    IncidentEscalatedData (..),
    IncidentResolvedData (..),
    IncidentState (..),

    -- * The aggregate
    IncidentRegs,
    IncidentEventStream,
    incidentEventStream,
    incidentStream,
    incidentCommandStream,
    incidentTransducer,
    incidentCodec,
    parseIncidentEvent,
)
where

import Data.Aeson (Value, object, withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, RegFile (..), SymTransducer)
import Keiki.Generics.TH (deriveAggregate)
import Keiro.Codec (Codec (..))
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.EventStream.Validate (ValidatedEventStream, mkEventStreamOrThrow)
import Keiro.Stream (Stream)
import Keiro.Stream qualified as Stream
import Kiroku.Store.Types (EventType (..))

newtype IncidentId = IncidentId Text
    deriving stock (Generic, Eq, Ord, Show)

newtype Service = Service Text
    deriving stock (Generic, Eq, Ord, Show)

data Severity
    = Sev1
    | Sev2
    | Sev3
    deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

incidentIdText :: IncidentId -> Text
incidentIdText (IncidentId value) = value

serviceText :: Service -> Text
serviceText (Service value) = value

severityText :: Severity -> Text
severityText = \case
    Sev1 -> "SEV1"
    Sev2 -> "SEV2"
    Sev3 -> "SEV3"

parseSeverity :: Text -> Maybe Severity
parseSeverity = \case
    "SEV1" -> Just Sev1
    "SEV2" -> Just Sev2
    "SEV3" -> Just Sev3
    _ -> Nothing

data IncidentCommand
    = RaiseIncident !RaiseIncidentData
    | AcknowledgeIncident !AcknowledgeIncidentData
    | EscalateIncident !EscalateIncidentData
    | ResolveIncident !ResolveIncidentData
    deriving stock (Generic, Eq, Show)

data RaiseIncidentData = RaiseIncidentData
    { incidentId :: !IncidentId
    , service :: !Service
    , severity :: !Severity
    , raisedAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)

newtype AcknowledgeIncidentData = AcknowledgeIncidentData
    { incidentId :: IncidentId
    }
    deriving stock (Generic, Eq, Show)

newtype EscalateIncidentData = EscalateIncidentData
    { incidentId :: IncidentId
    }
    deriving stock (Generic, Eq, Show)

newtype ResolveIncidentData = ResolveIncidentData
    { incidentId :: IncidentId
    }
    deriving stock (Generic, Eq, Show)

data IncidentEvent
    = IncidentRaised !IncidentRaisedData
    | IncidentAcknowledged !IncidentAcknowledgedData
    | IncidentEscalated !IncidentEscalatedData
    | IncidentResolved !IncidentResolvedData
    deriving stock (Generic, Eq, Show)

data IncidentRaisedData = IncidentRaisedData
    { incidentId :: !IncidentId
    , service :: !Service
    , severity :: !Severity
    , raisedAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)

newtype IncidentAcknowledgedData = IncidentAcknowledgedData
    { incidentId :: IncidentId
    }
    deriving stock (Generic, Eq, Show)

newtype IncidentEscalatedData = IncidentEscalatedData
    { incidentId :: IncidentId
    }
    deriving stock (Generic, Eq, Show)

newtype IncidentResolvedData = IncidentResolvedData
    { incidentId :: IncidentId
    }
    deriving stock (Generic, Eq, Show)

data IncidentState
    = Unreported
    | Triaging
    | Acknowledged
    | Escalated
    | Resolved
    deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

type IncidentRegs = '[]

type IncidentEventStream =
    EventStream (HsPred IncidentRegs IncidentCommand) IncidentRegs IncidentState IncidentCommand IncidentEvent

type ValidatedIncidentEventStream =
    ValidatedEventStream (HsPred IncidentRegs IncidentCommand) IncidentRegs IncidentState IncidentCommand IncidentEvent

$( deriveAggregate
    ''IncidentCommand
    ''IncidentRegs
    ''IncidentEvent
 )

incidentEventStreamDef :: IncidentEventStream
incidentEventStreamDef =
    EventStream
        { transducer = incidentTransducer
        , initialState = Unreported
        , initialRegisters = RNil
        , eventCodec = incidentCodec
        , resolveStreamName = Stream.streamName
        , snapshotPolicy = Never
        , stateCodec = Nothing
        }

incidentEventStream :: ValidatedIncidentEventStream
incidentEventStream =
    mkEventStreamOrThrow "jitsurei-incident" incidentEventStreamDef

incidentCategory :: Stream.StreamCategory a
incidentCategory = Stream.categoryUnsafe "incident"

incidentStream :: IncidentId -> Stream IncidentEventStream
incidentStream = Stream.entityStream incidentCategory . incidentIdText

-- | Same stream, typed as a command target (for process-manager dispatch).
incidentCommandStream :: IncidentId -> Stream IncidentCommand
incidentCommandStream = Stream.entityStream incidentCategory . incidentIdText

incidentTransducer ::
    SymTransducer (HsPred IncidentRegs IncidentCommand) IncidentRegs IncidentState IncidentCommand IncidentEvent
incidentTransducer =
    B.buildTransducer Unreported RNil isTerminal do
        B.from Unreported do
            B.onCmd inCtorRaiseIncident $ \d -> B.do
                B.emit
                    wireIncidentRaised
                    IncidentRaisedTermFields
                        { incidentId = d.incidentId
                        , service = d.service
                        , severity = d.severity
                        , raisedAt = d.raisedAt
                        }
                B.goto Triaging

        B.from Triaging do
            B.onCmd inCtorAcknowledgeIncident $ \d -> B.do
                B.emit
                    wireIncidentAcknowledged
                    IncidentAcknowledgedTermFields
                        { incidentId = d.incidentId
                        }
                B.goto Acknowledged

            B.onCmd inCtorEscalateIncident $ \d -> B.do
                B.emit
                    wireIncidentEscalated
                    IncidentEscalatedTermFields
                        { incidentId = d.incidentId
                        }
                B.goto Escalated

        B.from Acknowledged do
            B.onCmd inCtorResolveIncident $ \d -> B.do
                B.emit
                    wireIncidentResolved
                    IncidentResolvedTermFields
                        { incidentId = d.incidentId
                        }
                B.goto Resolved

        B.from Escalated do
            B.onCmd inCtorResolveIncident $ \d -> B.do
                B.emit
                    wireIncidentResolved
                    IncidentResolvedTermFields
                        { incidentId = d.incidentId
                        }
                B.goto Resolved
  where
    isTerminal = \case
        Resolved -> True
        _ -> False

incidentCodec :: Codec IncidentEvent
incidentCodec =
    Codec
        { eventTypes = EventType "IncidentRaised" :| [EventType "IncidentAcknowledged", EventType "IncidentEscalated", EventType "IncidentResolved"]
        , eventType = \case
            IncidentRaised{} -> EventType "IncidentRaised"
            IncidentAcknowledged{} -> EventType "IncidentAcknowledged"
            IncidentEscalated{} -> EventType "IncidentEscalated"
            IncidentResolved{} -> EventType "IncidentResolved"
        , schemaVersion = 1
        , encode = \case
            IncidentRaised payload ->
                object
                    [ "kind" Aeson..= ("IncidentRaised" :: Text)
                    , "incidentId" Aeson..= incidentIdText payload.incidentId
                    , "service" Aeson..= serviceText payload.service
                    , "severity" Aeson..= severityText payload.severity
                    , "raisedAt" Aeson..= payload.raisedAt
                    ]
            IncidentAcknowledged payload ->
                object
                    [ "kind" Aeson..= ("IncidentAcknowledged" :: Text)
                    , "incidentId" Aeson..= incidentIdText payload.incidentId
                    ]
            IncidentEscalated payload ->
                object
                    [ "kind" Aeson..= ("IncidentEscalated" :: Text)
                    , "incidentId" Aeson..= incidentIdText payload.incidentId
                    ]
            IncidentResolved payload ->
                object
                    [ "kind" Aeson..= ("IncidentResolved" :: Text)
                    , "incidentId" Aeson..= incidentIdText payload.incidentId
                    ]
        , decode = parseIncidentEvent
        , upcasters = []
        }

parseIncidentEvent :: EventType -> Value -> Either Text IncidentEvent
parseIncidentEvent (EventType tag) value =
    case parseEither parser value of
        Right event -> Right event
        Left message -> Left (Text.pack message)
  where
    parser = withObject "IncidentEvent" $ \objectValue -> do
        case tag of
            "IncidentRaised" -> do
                incidentId <- objectValue .: "incidentId"
                service <- objectValue .: "service"
                sev <- objectValue .: "severity"
                severity <- maybe (fail "unknown severity") pure (parseSeverity sev)
                raisedAt <- objectValue .: "raisedAt"
                pure
                    ( IncidentRaised
                        IncidentRaisedData
                            { incidentId = IncidentId incidentId
                            , service = Service service
                            , severity = severity
                            , raisedAt = raisedAt
                            }
                    )
            "IncidentAcknowledged" ->
                IncidentAcknowledged . IncidentAcknowledgedData . IncidentId
                    <$> objectValue .: "incidentId"
            "IncidentEscalated" ->
                IncidentEscalated . IncidentEscalatedData . IncidentId
                    <$> objectValue .: "incidentId"
            "IncidentResolved" ->
                IncidentResolved . IncidentResolvedData . IncidentId
                    <$> objectValue .: "incidentId"
            _ -> fail "unknown incident event type"
