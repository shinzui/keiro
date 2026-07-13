{- | The escalation process manager for the on-call worked example.

This is the *stateful* half of the example (the router in "Jitsurei.Paging" is
the stateless half). The process manager correlates on the incident id, keeps a
small saga state stream (@esc-<incident>@), and reacts to two signals:

  * @IncidentReported@ (from the incident's @IncidentRaised@): advance the saga
    to /awaiting acknowledgement/ and schedule an escalation timer whose deadline
    is derived from the severity.
  * @ResponderAcked@ (from a page's @PageAcknowledged@): advance the saga to
    /settled/ and dispatch @AcknowledgeIncident@ to the incident aggregate.

If the escalation timer fires before any acknowledgement,
'runEscalationTimerWorker' dispatches @EscalateIncident@ to the incident. The
incident aggregate's own guards make this safe: if it was already acknowledged,
@EscalateIncident@ is a benign 'Keiro.Command.CommandRejected', so the timer
firing is idempotent and race-free without the worker needing to inspect state.
-}
module Jitsurei.EscalationProcess (
    -- * The saga aggregate (the process manager's own state)
    EscalationCommand (..),
    NoteRaisedData (..),
    NoteAcknowledgedData (..),
    EscalationEvent (..),
    RaiseNotedData (..),
    AcknowledgeNotedData (..),
    EscalationState (..),
    EscalationRegs,
    EscalationEventStream,
    escalationEventStream,
    escalationStream,
    escalationTransducer,
    escalationCodec,

    -- * The process manager
    EscalationInput (..),
    EscalationProcessManager,
    escalationProcessManager,
    escalationInputIncidentId,
    runEscalationOnce,

    -- * Escalation timer and worker
    escalationDeadline,
    escalationWindow,
    escalationTimerRequest,
    runEscalationTimerWorker,
)
where

import Control.Lens ((^.))
import Data.Aeson (Value, object, withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, UTCTime, addUTCTime)
import Data.UUID (UUID)
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import GHC.Generics (Generic)
import GHC.Stack (HasCallStack)
import Jitsurei.Incident (
    AcknowledgeIncidentData (..),
    EscalateIncidentData (..),
    IncidentCommand (..),
    IncidentEvent,
    IncidentEventStream,
    IncidentId (..),
    IncidentRaisedData (..),
    IncidentState,
    Severity (..),
    incidentCommandStream,
    incidentEventStream,
    incidentIdText,
    incidentStream,
 )
import Jitsurei.Paging (PageAcknowledgedData (..))
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, RegFile (..), SymTransducer)
import Keiki.Generics.TH (deriveAggregate)
import Keiro.Codec (Codec (..))
import Keiro.Command (CommandError, RunCommandOptions, runCommand)
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.EventStream.Validate (ValidatedEventStream, mkEventStreamOrThrow)
import Keiro.ProcessManager (
    PMCommand (..),
    ProcessManager (..),
    ProcessManagerAction (..),
    ProcessManagerResult,
    runProcessManagerOnce,
 )
import Keiro.Stream (Stream)
import Keiro.Stream qualified as Stream
import Keiro.Timer (TimerId (..), TimerRequest (..), TimerRow, runTimerWorker)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types (EventId (..), EventType (..), RecordedEvent)

data EscalationCommand
    = NoteRaised !NoteRaisedData
    | NoteAcknowledged !NoteAcknowledgedData
    deriving stock (Generic, Eq, Show)

newtype NoteRaisedData = NoteRaisedData
    { incidentId :: IncidentId
    }
    deriving stock (Generic, Eq, Show)

newtype NoteAcknowledgedData = NoteAcknowledgedData
    { incidentId :: IncidentId
    }
    deriving stock (Generic, Eq, Show)

data EscalationEvent
    = RaiseNoted !RaiseNotedData
    | AcknowledgeNoted !AcknowledgeNotedData
    deriving stock (Generic, Eq, Show)

newtype RaiseNotedData = RaiseNotedData
    { incidentId :: IncidentId
    }
    deriving stock (Generic, Eq, Show)

newtype AcknowledgeNotedData = AcknowledgeNotedData
    { incidentId :: IncidentId
    }
    deriving stock (Generic, Eq, Show)

data EscalationState
    = EscalationIdle
    | Awaiting
    | Settled
    deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

type EscalationRegs = '[]

type EscalationEventStream =
    EventStream (HsPred EscalationRegs EscalationCommand) EscalationRegs EscalationState EscalationCommand EscalationEvent

type ValidatedEscalationEventStream =
    ValidatedEventStream (HsPred EscalationRegs EscalationCommand) EscalationRegs EscalationState EscalationCommand EscalationEvent

$( deriveAggregate
    ''EscalationCommand
    ''EscalationRegs
    ''EscalationEvent
 )

escalationEventStreamDef :: EscalationEventStream
escalationEventStreamDef =
    EventStream
        { transducer = escalationTransducer
        , initialState = EscalationIdle
        , initialRegisters = RNil
        , eventCodec = escalationCodec
        , resolveStreamName = Stream.streamName
        , snapshotPolicy = Never
        , stateCodec = Nothing
        }

escalationEventStream :: ValidatedEscalationEventStream
escalationEventStream =
    mkEventStreamOrThrow "jitsurei-escalation" escalationEventStreamDef

escalationCategory :: Stream.StreamCategory a
escalationCategory = Stream.categoryUnsafe "esc"

escalationStream :: IncidentId -> Stream EscalationEventStream
escalationStream = Stream.entityStream escalationCategory . incidentIdText

escalationTransducer ::
    SymTransducer (HsPred EscalationRegs EscalationCommand) EscalationRegs EscalationState EscalationCommand EscalationEvent
escalationTransducer =
    B.buildTransducer EscalationIdle RNil (const False) do
        B.from EscalationIdle do
            B.onCmd inCtorNoteRaised $ \d -> B.do
                B.emit
                    wireRaiseNoted
                    RaiseNotedTermFields
                        { incidentId = d.incidentId
                        }
                B.goto Awaiting

        B.from Awaiting do
            B.onCmd inCtorNoteAcknowledged $ \d -> B.do
                B.emit
                    wireAcknowledgeNoted
                    AcknowledgeNotedTermFields
                        { incidentId = d.incidentId
                        }
                B.goto Settled

escalationCodec :: Codec EscalationEvent
escalationCodec =
    Codec
        { eventTypes = EventType "RaiseNoted" :| [EventType "AcknowledgeNoted"]
        , eventType = \case
            RaiseNoted{} -> EventType "RaiseNoted"
            AcknowledgeNoted{} -> EventType "AcknowledgeNoted"
        , schemaVersion = 1
        , encode = \case
            RaiseNoted payload ->
                object
                    [ "kind" Aeson..= ("RaiseNoted" :: Text)
                    , "incidentId" Aeson..= incidentIdText payload.incidentId
                    ]
            AcknowledgeNoted payload ->
                object
                    [ "kind" Aeson..= ("AcknowledgeNoted" :: Text)
                    , "incidentId" Aeson..= incidentIdText payload.incidentId
                    ]
        , decode = parseEscalationEvent
        , upcasters = []
        }

parseEscalationEvent :: EventType -> Value -> Either Text EscalationEvent
parseEscalationEvent (EventType tag) value =
    case parseEither parser value of
        Right event -> Right event
        Left message -> Left (Text.pack message)
  where
    parser = withObject "EscalationEvent" $ \objectValue -> do
        incidentId <- IncidentId <$> objectValue .: "incidentId"
        case tag of
            "RaiseNoted" -> pure (RaiseNoted (RaiseNotedData{incidentId}))
            "AcknowledgeNoted" -> pure (AcknowledgeNoted (AcknowledgeNotedData{incidentId}))
            _ -> fail "unknown escalation event type"

{- | The two signals the process manager reacts to, each carrying the incident
it correlates on. In a live worker these come from two subscriptions — the
incident stream (@IncidentRaised@) and the page streams (@PageAcknowledged@).
-}
data EscalationInput
    = IncidentReported !IncidentRaisedData
    | ResponderAcked !PageAcknowledgedData
    deriving stock (Generic, Eq, Show)

escalationInputIncidentId :: EscalationInput -> IncidentId
escalationInputIncidentId = \case
    IncidentReported raised -> raised.incidentId
    ResponderAcked acked -> acked.incidentId

type EscalationProcessManager =
    ProcessManager
        EscalationInput
        (HsPred EscalationRegs EscalationCommand)
        EscalationRegs
        EscalationState
        EscalationCommand
        EscalationEvent
        (HsPred '[] IncidentCommand)
        '[]
        IncidentState
        IncidentCommand
        IncidentEvent

escalationProcessManager :: EscalationProcessManager
escalationProcessManager =
    ProcessManager
        { name = "jitsurei-escalation"
        , correlate = incidentIdText . escalationInputIncidentId
        , eventStream = escalationEventStream
        , streamFor = escalationStream . IncidentId
        , targetEventStream = incidentEventStream
        , targetProjections = const []
        , handle = \case
            IncidentReported raised ->
                ProcessManagerAction
                    { command = NoteRaised (NoteRaisedData{incidentId = raised.incidentId})
                    , commands = []
                    , timers = [escalationTimerRequest raised.incidentId (escalationDeadline raised.raisedAt raised.severity)]
                    }
            ResponderAcked acked ->
                ProcessManagerAction
                    { command = NoteAcknowledged (NoteAcknowledgedData{incidentId = acked.incidentId})
                    , commands =
                        [ PMCommand
                            { target = incidentCommandStream acked.incidentId
                            , command = AcknowledgeIncident (AcknowledgeIncidentData{incidentId = acked.incidentId})
                            }
                        ]
                    , timers = []
                    }
        }

runEscalationOnce ::
    ( HasCallStack
    , IOE :> es
    , Store :> es
    , Error StoreError :> es
    , KirokuStoreResource :> es
    ) =>
    RunCommandOptions ->
    RecordedEvent ->
    EscalationInput ->
    Eff es (Either CommandError (ProcessManagerResult EscalationEventStream IncidentEventStream))
runEscalationOnce options recorded input =
    runProcessManagerOnce options escalationProcessManager recorded input

-- | The escalation deadline: @raisedAt@ plus a severity-derived window.
escalationDeadline :: UTCTime -> Severity -> UTCTime
escalationDeadline raisedAt severity = addUTCTime (escalationWindow severity) raisedAt

escalationWindow :: Severity -> NominalDiffTime
escalationWindow = \case
    Sev1 -> 5 * 60
    Sev2 -> 15 * 60
    Sev3 -> 60 * 60

{- | A deterministic escalation timer for an incident. The @timerId@ is a UUIDv5
of the incident id, so re-scheduling (e.g. on a redelivered @IncidentRaised@)
upserts the same row rather than creating a duplicate.
-}
escalationTimerRequest :: IncidentId -> UTCTime -> TimerRequest
escalationTimerRequest incidentId fireAt =
    TimerRequest
        { timerId = TimerId (namedUuid ("jitsurei-escalation-timer:" <> incidentIdText incidentId))
        , processManagerName = "jitsurei-escalation"
        , correlationId = incidentIdText incidentId
        , fireAt = fireAt
        , payload =
            object
                [ "kind" Aeson..= ("escalation" :: Text)
                , "incidentId" Aeson..= incidentIdText incidentId
                ]
        }

{- | Claim a due escalation timer and dispatch @EscalateIncident@ to its
incident. The command is a benign no-op if the incident was already
acknowledged (the aggregate rejects it), so the timer firing is safe regardless
of the ack/escalate race; the timer is marked fired either way.
-}
runEscalationTimerWorker ::
    ( HasCallStack
    , IOE :> es
    , Store :> es
    , Error StoreError :> es
    ) =>
    RunCommandOptions ->
    UTCTime ->
    Eff es (Maybe TimerRow)
runEscalationTimerWorker options now =
    runTimerWorker Nothing now $ \timer ->
        case incidentIdFromTimer timer of
            Nothing -> pure Nothing
            Just incidentId -> do
                _ <-
                    runCommand
                        options
                        incidentEventStream
                        (incidentStream incidentId)
                        (EscalateIncident (EscalateIncidentData{incidentId = incidentId}))
                pure (Just (EventId (namedUuid ("jitsurei-escalation-fired:" <> incidentIdText incidentId))))

incidentIdFromTimer :: TimerRow -> Maybe IncidentId
incidentIdFromTimer timer
    | (timer ^. #processManagerName) == ("jitsurei-escalation" :: Text) =
        Just (IncidentId (timer ^. #correlationId))
    | otherwise = Nothing

namedUuid :: Text -> UUID
namedUuid value =
    UUID.V5.generateNamed UUID.V5.namespaceURL (fmap (fromIntegral . fromEnum) (Text.unpack value))
