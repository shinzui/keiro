module ReactionExample
  ( ExampleInput (..),
    Severity (..),
    ExampleSagaCommand (..),
    ExampleSagaEvent (..),
    ExampleTargetCommand (..),
    ExampleTargetEvent (..),
    ExampleSagaStream,
    ExampleTargetStream,
    exampleReactionManager,
    exampleTargetEventStream,
    exampleReminderTimerId,
    exampleEscalationTimerId,
  )
where

import Data.Aeson (FromJSON, ToJSON, object, withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime)
import Data.UUID qualified as UUID
import GHC.Generics (Generic)
import Keiki.Core
  ( Edge (..),
    HsPred,
    InCtor,
    RegFile (..),
    SymTransducer (..),
    Update (..),
    WireCtor,
    inpCtor,
    matchInCtor,
    oNil,
    pack,
    (*:),
  )
import Keiki.Core qualified as Keiki
import Keiki.Shape (CanonicalStateShape)
import Keiro.Codec (Codec (..))
import Keiro.Command (DomainCommandHandler (..), SilentDomainDecision (..))
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.EventStream.Validate (ValidatedEventStream, mkEventStreamOrThrow)
import Keiro.ProcessManager (PMCommand (..))
import Keiro.ProcessManager.Reaction qualified as Reaction
import Keiro.Stream (stream, streamName)
import Keiro.Timer (TimerId (..), TimerRequest (..))
import Kiroku.Store.Types (EventType (..))

data Severity = Routine | Urgent
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data ExampleInput
  = IncidentReported !Text !Severity
  | IncidentAcknowledged !Text
  deriving stock (Generic, Eq, Show)

data ExampleSagaCommand
  = RecordIncident !Severity
  | RecordAcknowledgement
  deriving stock (Generic, Eq, Show)

data ExampleSagaEvent
  = IncidentRecorded !Severity
  | AcknowledgementRecorded
  deriving stock (Generic, Eq, Show)

data ExampleSagaState = Tracking
  deriving stock (Generic, Eq, Show, Enum, Bounded, Ord)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalStateShape ExampleSagaState

data ExampleTargetCommand
  = SendAlert !Text
  | ApplyLateTimeout
  deriving stock (Generic, Eq, Show)

data ExampleTargetEvent
  = AlertSent !Text
  | LateTimeoutApplied
  deriving stock (Generic, Eq, Show)

data ExampleTargetState = AwaitingAlert | AlertComplete
  deriving stock (Generic, Eq, Show, Enum, Bounded, Ord)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalStateShape ExampleTargetState

type SeverityFields = '[ '("severity", Severity)]

type CorrelationFields = '[ '("correlationId", Text)]

type ExampleSagaStream = EventStream (HsPred '[] ExampleSagaCommand) '[] ExampleSagaState ExampleSagaCommand ExampleSagaEvent

type ExampleTargetStream = EventStream (HsPred '[] ExampleTargetCommand) '[] ExampleTargetState ExampleTargetCommand ExampleTargetEvent

exampleReactionManager ::
  UTCTime ->
  Reaction.ReactiveProcessManager
    ExampleInput
    (HsPred '[] ExampleSagaCommand)
    '[]
    ExampleSagaState
    ExampleSagaCommand
    ExampleSagaEvent
    (HsPred '[] ExampleTargetCommand)
    '[]
    ExampleTargetState
    ExampleTargetCommand
    ExampleTargetEvent
    Text
    Text
exampleReactionManager injectedNow =
  Reaction.ReactiveProcessManager
    { name = "incident-reaction-example",
      correlate = \case
        IncidentReported correlationId _ -> correlationId
        IncidentAcknowledged correlationId -> correlationId,
      sagaHandler = exampleSagaHandler,
      streamFor = \correlationId -> stream ("incident-reaction-saga:" <> correlationId),
      targetEventStream = exampleTargetEventStream,
      targetProjections = const [],
      react = \case
        IncidentReported _ Routine -> Reaction.NoAdvance []
        IncidentReported correlationId Urgent ->
          Reaction.AdvanceReaction
            { command = RecordIncident Urgent,
              followUps =
                [ Reaction.FollowSchedule Reaction.Once (reminderTimer correlationId),
                  Reaction.FollowSchedule Reaction.Once (escalationTimer correlationId)
                ],
              onAccepted =
                [ Reaction.FollowDispatch
                    (PMCommand (stream ("incident-reaction-target:" <> correlationId)) (SendAlert correlationId))
                ]
            }
        IncidentAcknowledged _ ->
          Reaction.AdvanceReaction
            { command = RecordAcknowledgement,
              followUps =
                [ Reaction.FollowCancel exampleReminderTimerId,
                  Reaction.FollowCancel exampleEscalationTimerId
                ],
              onAccepted = []
            }
    }
  where
    reminderTimer correlationId =
      TimerRequest
        { timerId = exampleReminderTimerId,
          processManagerName = "incident-reaction-example-reminder",
          correlationId,
          fireAt = addUTCTime 300 injectedNow,
          payload = object ["kind" Aeson..= ("reminder" :: Text), "correlationId" Aeson..= correlationId]
        }
    escalationTimer correlationId =
      TimerRequest
        { timerId = exampleEscalationTimerId,
          processManagerName = "incident-reaction-example-escalation",
          correlationId,
          fireAt = addUTCTime 900 injectedNow,
          payload = object ["kind" Aeson..= ("escalation" :: Text), "correlationId" Aeson..= correlationId]
        }

exampleReminderTimerId :: TimerId
exampleReminderTimerId = TimerId (UUID.fromWords 0x27900001 0 0 1)

exampleEscalationTimerId :: TimerId
exampleEscalationTimerId = TimerId (UUID.fromWords 0x27900002 0 0 2)

exampleSagaHandler :: DomainCommandHandler (HsPred '[] ExampleSagaCommand) '[] ExampleSagaState ExampleSagaCommand ExampleSagaEvent Text Text
exampleSagaHandler =
  DomainCommandHandler
    { eventStream = exampleSagaEventStream,
      classifySilent = \_ -> SilentNoOp "already acknowledged"
    }

exampleSagaEventStream :: ValidatedEventStream (HsPred '[] ExampleSagaCommand) '[] ExampleSagaState ExampleSagaCommand ExampleSagaEvent
exampleSagaEventStream = mkEventStreamOrThrow "reaction-example-saga" exampleSagaEventStreamDef

exampleSagaEventStreamDef :: ExampleSagaStream
exampleSagaEventStreamDef =
  EventStream
    { transducer = exampleSagaTransducer,
      initialState = Tracking,
      initialRegisters = RNil,
      eventCodec = exampleSagaCodec,
      resolveStreamName = streamName,
      snapshotPolicy = Never,
      stateCodec = Nothing
    }

exampleSagaTransducer :: SymTransducer (HsPred '[] ExampleSagaCommand) '[] ExampleSagaState ExampleSagaCommand ExampleSagaEvent
exampleSagaTransducer =
  SymTransducer
    { edgesOut = \Tracking ->
        [ Edge
            { guard = matchInCtor recordIncidentCtor,
              update = UKeep,
              output = [pack recordIncidentCtor incidentRecordedCtor (inpCtor recordIncidentCtor #severity *: oNil)],
              target = Tracking,
              mode = Keiki.Live
            },
          Edge
            { guard = matchInCtor recordAcknowledgementCtor,
              update = UKeep,
              output = [pack recordAcknowledgementCtor acknowledgementRecordedCtor oNil],
              target = Tracking,
              mode = Keiki.Live
            }
        ],
      initial = Tracking,
      initialRegs = RNil,
      isFinal = const False
    }

exampleTargetEventStream :: ValidatedEventStream (HsPred '[] ExampleTargetCommand) '[] ExampleTargetState ExampleTargetCommand ExampleTargetEvent
exampleTargetEventStream = mkEventStreamOrThrow "reaction-example-target" exampleTargetEventStreamDef

exampleTargetEventStreamDef :: ExampleTargetStream
exampleTargetEventStreamDef =
  EventStream
    { transducer = exampleTargetTransducer,
      initialState = AwaitingAlert,
      initialRegisters = RNil,
      eventCodec = exampleTargetCodec,
      resolveStreamName = streamName,
      snapshotPolicy = Never,
      stateCodec = Nothing
    }

exampleTargetTransducer :: SymTransducer (HsPred '[] ExampleTargetCommand) '[] ExampleTargetState ExampleTargetCommand ExampleTargetEvent
exampleTargetTransducer =
  SymTransducer
    { edgesOut = \case
        AwaitingAlert ->
          [ Edge
              { guard = matchInCtor sendAlertCtor,
                update = UKeep,
                output = [pack sendAlertCtor alertSentCtor (inpCtor sendAlertCtor #correlationId *: oNil)],
                target = AlertComplete,
                mode = Keiki.Live
              },
            Edge
              { guard = matchInCtor applyLateTimeoutCtor,
                update = UKeep,
                output = [pack applyLateTimeoutCtor lateTimeoutAppliedCtor oNil],
                target = AlertComplete,
                mode = Keiki.Live
              }
          ]
        AlertComplete ->
          [ Edge
              { guard = matchInCtor applyLateTimeoutCtor,
                update = UKeep,
                output = [],
                target = AlertComplete,
                mode = Keiki.Live
              }
          ],
      initial = AwaitingAlert,
      initialRegs = RNil,
      isFinal = const False
    }

recordIncidentCtor :: InCtor ExampleSagaCommand SeverityFields
recordIncidentCtor =
  Keiki.unavailableInCtor
    "RecordIncident"
    (\case RecordIncident severity -> Just (RCons Proxy severity RNil); RecordAcknowledgement -> Nothing)
    (\case RCons _ severity RNil -> RecordIncident severity)

recordAcknowledgementCtor :: InCtor ExampleSagaCommand '[]
recordAcknowledgementCtor =
  Keiki.unavailableInCtor
    "RecordAcknowledgement"
    (\case RecordAcknowledgement -> Just RNil; RecordIncident {} -> Nothing)
    (\RNil -> RecordAcknowledgement)

incidentRecordedCtor :: WireCtor ExampleSagaEvent (Severity, ())
incidentRecordedCtor =
  Keiki.unavailableWireCtor
    "IncidentRecorded"
    (\case IncidentRecorded severity -> Just (severity, ()); AcknowledgementRecorded -> Nothing)
    (\(severity, ()) -> IncidentRecorded severity)

acknowledgementRecordedCtor :: WireCtor ExampleSagaEvent ()
acknowledgementRecordedCtor =
  Keiki.unavailableWireCtor
    "AcknowledgementRecorded"
    (\case AcknowledgementRecorded -> Just (); IncidentRecorded {} -> Nothing)
    (const AcknowledgementRecorded)

sendAlertCtor :: InCtor ExampleTargetCommand CorrelationFields
sendAlertCtor =
  Keiki.unavailableInCtor
    "SendAlert"
    (\case SendAlert correlationId -> Just (RCons Proxy correlationId RNil); ApplyLateTimeout -> Nothing)
    (\case RCons _ correlationId RNil -> SendAlert correlationId)

applyLateTimeoutCtor :: InCtor ExampleTargetCommand '[]
applyLateTimeoutCtor =
  Keiki.unavailableInCtor
    "ApplyLateTimeout"
    (\case ApplyLateTimeout -> Just RNil; SendAlert {} -> Nothing)
    (\RNil -> ApplyLateTimeout)

alertSentCtor :: WireCtor ExampleTargetEvent (Text, ())
alertSentCtor =
  Keiki.unavailableWireCtor
    "AlertSent"
    (\case AlertSent correlationId -> Just (correlationId, ()); LateTimeoutApplied -> Nothing)
    (\(correlationId, ()) -> AlertSent correlationId)

lateTimeoutAppliedCtor :: WireCtor ExampleTargetEvent ()
lateTimeoutAppliedCtor =
  Keiki.unavailableWireCtor
    "LateTimeoutApplied"
    (\case LateTimeoutApplied -> Just (); AlertSent {} -> Nothing)
    (const LateTimeoutApplied)

exampleSagaCodec :: Codec ExampleSagaEvent
exampleSagaCodec =
  Codec
    { eventTypes = EventType "IncidentRecorded" :| [EventType "AcknowledgementRecorded"],
      eventType = \case
        IncidentRecorded {} -> EventType "IncidentRecorded"
        AcknowledgementRecorded -> EventType "AcknowledgementRecorded",
      schemaVersion = 1,
      encode = \case
        IncidentRecorded severity -> object ["severity" Aeson..= severity]
        AcknowledgementRecorded -> object [],
      decode = \eventType value -> parseCodec eventType value $ \objectValue -> case eventType of
        EventType "IncidentRecorded" -> IncidentRecorded <$> objectValue .: "severity"
        EventType "AcknowledgementRecorded" -> pure AcknowledgementRecorded
        _ -> fail "unknown example saga event",
      upcasters = []
    }

exampleTargetCodec :: Codec ExampleTargetEvent
exampleTargetCodec =
  Codec
    { eventTypes = EventType "AlertSent" :| [EventType "LateTimeoutApplied"],
      eventType = \case
        AlertSent {} -> EventType "AlertSent"
        LateTimeoutApplied -> EventType "LateTimeoutApplied",
      schemaVersion = 1,
      encode = \case
        AlertSent correlationId -> object ["correlationId" Aeson..= correlationId]
        LateTimeoutApplied -> object [],
      decode = \eventType value -> parseCodec eventType value $ \objectValue -> case eventType of
        EventType "AlertSent" -> AlertSent <$> objectValue .: "correlationId"
        EventType "LateTimeoutApplied" -> pure LateTimeoutApplied
        _ -> fail "unknown example target event",
      upcasters = []
    }

parseCodec :: EventType -> Aeson.Value -> (Aeson.Object -> Parser event) -> Either Text event
parseCodec eventType value parser =
  case parseEither (withObject (Text.unpack (coerceEventType eventType)) parser) value of
    Left message -> Left (Text.pack message)
    Right decoded -> Right decoded

coerceEventType :: EventType -> Text
coerceEventType (EventType eventType) = eventType
