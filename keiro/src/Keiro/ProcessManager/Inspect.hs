{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Application-owned descriptors and observations of persisted manager state.
-- Inspection uses the runtime hydration algorithm; raw history remains in Kiroku.
module Keiro.ProcessManager.Inspect
  ( ProcessManagerInspector (..),
    SomeProcessManagerInspector (..),
    ProcessManagerInspectors,
    processManagerInspector,
    domainProcessManagerInspector,
    reactiveProcessManagerInspector,
    ProcessManagerProvenanceMode (..),
    EnabledInput (..),
    ReactionProvenance (..),
    encodeReactionProvenance,
    decodeReactionProvenance,
    DispatchWitness (..),
    DispatchedCommandStatus (..),
    LastReaction (..),
    InstanceViewRequest (..),
    ProcessManagerInspectionError (..),
    ProcessManagerInstanceView (..),
    inspectProcessManagerInstance,
    processManagerViewJson,
    InstanceListRequest (..),
    InstanceListError (..),
    InstanceSummary (..),
    InstancePage (..),
    instanceListCursorKind,
    listProcessManagerInstances,
    instancePageJson,
  )
where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Maybe (mapMaybe)
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Keiki.Core (BoolAlg, HsPred, RegFile)
import Keiki.Core qualified as Keiki
import Keiki.Render.Mermaid (edgeInputName)
import Keiro.Command
import Keiro.EventStream (EventStream)
import Keiro.EventStream.Validate (ValidatedEventStream, unvalidated)
import Keiro.Inspection.Aggregate (hydrationSourceJson)
import Keiro.Inspection.Cursor
import Keiro.Prelude hiding ((.=))
import Keiro.ProcessManager (DomainProcessManager, ProcessManager, deterministicCommandIdProbes, firstExistingEventId)
import Keiro.ProcessManager.Provenance
import Keiro.ProcessManager.Reaction (ReactiveProcessManager)
import Keiro.Stream (Stream, StreamCategory, categoryName, categoryText)
import Keiro.Timer
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Read (getStream, listStreams, lookupStreamName, readStreamForward)
import Kiroku.Store.Types hiding (categoryName)

-- | Select the persisted evidence family explicitly; state inspection alone
-- does not authorize interpreting legacy metadata as modern reaction evidence.
data ProcessManagerProvenanceMode = ReadLegacyProvenance | NoReactionProvenance
  deriving stock (Generic, Eq, Show)

-- | Encoders and membership mappings belong to the application. A custom
-- mapping must round-trip through streamFor and resolveStreamName.
data ProcessManagerInspector phi rs s ci co = ProcessManagerInspector
  { name :: !Text,
    eventStream :: !(ValidatedEventStream phi rs s ci co),
    streamFor :: !(Text -> Stream (EventStream phi rs s ci co)),
    category :: !(StreamCategory (EventStream phi rs s ci co)),
    correlationOf :: !(StreamName -> Maybe Text),
    displayState :: !(s -> RegFile rs -> Value),
    stateLabel :: !(s -> Text),
    enabledInputs :: !(s -> [EnabledInput]),
    provenanceMode :: !ProcessManagerProvenanceMode
  }
  deriving stock (Generic)

data EnabledInput = EnabledInput {input :: !(Maybe Text), targetState :: !Text}
  deriving stock (Generic, Eq, Show)

mkInspector :: (Show s) => ProcessManagerProvenanceMode -> Text -> ValidatedEventStream (HsPred rs ci) rs s ci co -> (Text -> Stream (EventStream (HsPred rs ci) rs s ci co)) -> StreamCategory (EventStream (HsPred rs ci) rs s ci co) -> (s -> RegFile rs -> Value) -> ProcessManagerInspector (HsPred rs ci) rs s ci co
mkInspector provenanceMode name definition streamFor category displayState =
  ProcessManagerInspector
    name
    definition
    streamFor
    category
    (\(StreamName raw) -> Text.stripPrefix (categoryText category <> "-") raw)
    displayState
    (Text.pack . show)
    ( \state ->
        [ EnabledInput (edgeInputName edge) (Text.pack (show (Keiki.target edge)))
        | edge <- Keiki.edgesOut (unvalidated definition ^. #transducer) state,
          Keiki.mode edge == Keiki.Live
        ]
    )
    provenanceMode

processManagerInspector :: (Show s) => ProcessManager input (HsPred rs ci) rs s ci co tPhi tRs tS tCi tCo -> StreamCategory (EventStream (HsPred rs ci) rs s ci co) -> (s -> RegFile rs -> Value) -> ProcessManagerInspector (HsPred rs ci) rs s ci co
processManagerInspector manager = mkInspector ReadLegacyProvenance (manager ^. #name) (manager ^. #eventStream) (manager ^. #streamFor)

domainProcessManagerInspector :: (Show s) => DomainProcessManager input (HsPred rs ci) rs s ci co tPhi tRs tS tCi tCo rej noOp -> StreamCategory (EventStream (HsPred rs ci) rs s ci co) -> (s -> RegFile rs -> Value) -> ProcessManagerInspector (HsPred rs ci) rs s ci co
domainProcessManagerInspector manager = mkInspector ReadLegacyProvenance (manager ^. #name) (manager ^. #eventStream) (manager ^. #streamFor)

-- | State inspection for the surviving reaction API. Persisted events do not
-- retain enough input/source information to infer modern dispatch provenance.
reactiveProcessManagerInspector :: (Show s) => ReactiveProcessManager input (HsPred rs ci) rs s ci co tPhi tRs tS tCi tCo rej noOp -> StreamCategory (EventStream (HsPred rs ci) rs s ci co) -> (s -> RegFile rs -> Value) -> ProcessManagerInspector (HsPred rs ci) rs s ci co
reactiveProcessManagerInspector manager = mkInspector NoReactionProvenance (manager ^. #name) (manager ^. #sagaHandler . #eventStream) (manager ^. #streamFor)

data SomeProcessManagerInspector where
  SomeProcessManagerInspector :: (BoolAlg phi (RegFile rs, ci), Eq co) => ProcessManagerInspector phi rs s ci co -> SomeProcessManagerInspector

type ProcessManagerInspectors = Map Text SomeProcessManagerInspector

data DispatchWitness = EventPresent | NotObserved deriving stock (Generic, Eq, Show)

data DispatchedCommandStatus = DispatchedCommandStatus
  {emitIndex :: !Int, targetStreamName :: !StreamName, eventId :: !EventId, witness :: !DispatchWitness}
  deriving stock (Generic, Eq, Show)

data LastReaction = LastReaction
  { eventId :: !EventId,
    eventType :: !EventType,
    streamVersion :: !StreamVersion,
    globalPosition :: !GlobalPosition,
    recordedAt :: !UTCTime,
    provenance :: !(Maybe ReactionProvenance),
    sourceStreamName :: !(Maybe StreamName),
    dispatchedCommands :: ![DispatchedCommandStatus]
  }
  deriving stock (Generic, Eq, Show)

data InstanceViewRequest = InstanceViewRequest {timerPageSize :: !Int}
  deriving stock (Generic, Eq, Show)

data ProcessManagerInspectionError
  = ProcessManagerHydrationFailed !CommandError
  | InvalidInstanceViewRequest !Text
  | ProcessManagerTimerReadFailed !PendingTimerReadError
  deriving stock (Generic, Eq, Show)

data ProcessManagerInstanceView = ProcessManagerInstanceView
  { name :: !Text,
    correlationId :: !Text,
    journalStreamName :: !StreamName,
    streamVersion :: !StreamVersion,
    observedHeadVersion :: !StreamVersion,
    createdAt :: !UTCTime,
    deletedAt :: !(Maybe UTCTime),
    truncateBefore :: !StreamVersion,
    hydration :: !(Maybe HydrationSource),
    stateLabel :: !(Maybe Text),
    state :: !(Maybe Value),
    lastReaction :: !(Maybe LastReaction),
    waitingFor :: ![EnabledInput],
    pendingTimers :: !PendingTimerPage,
    observedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

physicalName :: ProcessManagerInspector phi rs s ci co -> Text -> StreamName
physicalName inspector correlation = (unvalidated inspector.eventStream ^. #resolveStreamName) (inspector.streamFor correlation)

inspectProcessManagerInstance :: (IOE :> es, Store :> es, BoolAlg phi (RegFile rs, ci), Eq co) => ProcessManagerInspector phi rs s ci co -> InstanceViewRequest -> Text -> Eff es (Either ProcessManagerInspectionError (Maybe ProcessManagerInstanceView))
inspectProcessManagerInstance inspector request correlation
  | Text.null (Text.strip correlation) = pure (Left (InvalidInstanceViewRequest "correlation id must not be blank"))
  | Left err <- validatePendingTimerRequest timerFilter timerRequest = pure (Left (ProcessManagerTimerReadFailed err))
  | otherwise = do
      metadata <- getStream streamName
      case metadata of
        Nothing -> pure (Right Nothing)
        Just info -> do
          result <-
            if isJust info.deletedAt
              then pure (Right Nothing)
              else fmap (fmap Just) (hydrateWithSource inspectionRunCommandOptions (unvalidated inspector.eventStream) (inspector.streamFor correlation))
          case result of
            Left err -> pure (Left (ProcessManagerHydrationFailed err))
            Right hydrated -> do
              let version = maybe info.version (\(value, _) -> value ^. #streamVersion) hydrated
              lastReaction <- case hydrated of
                Just _ | version > StreamVersion 0 -> do
                  let StreamVersion n = version
                  events <- readStreamForward streamName (StreamVersion (n - 1)) 1
                  case Vector.toList events of
                    event : _ | event.streamVersion == version -> Just <$> observeReaction event
                    _ -> pure Nothing
                _ -> pure Nothing
              timers <- findPendingTimers timerFilter timerRequest
              pure $ case timers of
                Left err -> Left (ProcessManagerTimerReadFailed err)
                Right page ->
                  Right
                    ( Just
                        ( ProcessManagerInstanceView
                            inspector.name
                            correlation
                            streamName
                            version
                            info.version
                            info.createdAt
                            info.deletedAt
                            info.truncateBefore
                            (snd <$> hydrated)
                            (fmap (\(value, _) -> inspector.stateLabel (value ^. #state)) hydrated)
                            (fmap (\(value, _) -> inspector.displayState (value ^. #state) (value ^. #registers)) hydrated)
                            lastReaction
                            (maybe [] (\(value, _) -> inspector.enabledInputs (value ^. #state)) hydrated)
                            page
                            page.observedAt
                        )
                    )
  where
    streamName = physicalName inspector correlation
    timerFilter = PendingTimerFilter (Just inspector.name) (Just correlation)
    timerRequest = PendingTimerPageRequest request.timerPageSize Nothing
    observeReaction event = case inspector.provenanceMode of
      NoReactionProvenance -> pure (LastReaction event.eventId event.eventType event.streamVersion event.globalPosition event.createdAt Nothing Nothing [])
      ReadLegacyProvenance -> observeLegacyReaction event
    observeLegacyReaction event = do
      let provenance = event.metadata >>= (\case Aeson.Object fields -> KeyMap.lookup "keiro.pm" fields; _ -> Nothing) >>= decodeReactionProvenance
      sourceName <- maybe (pure Nothing) (lookupStreamName . (.sourceStreamId)) provenance
      statuses <- maybe (pure []) (\record -> traverse (probe record) record.dispatched) provenance
      pure (LastReaction event.eventId event.eventType event.streamVersion event.globalPosition event.createdAt provenance sourceName statuses)
    probe record (index, target) = do
      let probes = deterministicCommandIdProbes inspector.name correlation record.sourceEventId index
      existing <- firstExistingEventId inspectionRunCommandOptions target probes
      pure (DispatchedCommandStatus index target (fromMaybe (NonEmpty.head probes) existing) (maybe NotObserved (const EventPresent) existing))

data InstanceListRequest = InstanceListRequest {pageSize :: !Int, after :: !(Maybe InspectionCursor)}
  deriving stock (Generic, Eq, Show)

data InstanceListError = InvalidInstancePageSize !Int | InvalidInstanceCursor !CursorError | InstanceResultTooLarge
  deriving stock (Generic, Eq, Show)

data InstanceSummary = InstanceSummary
  { correlationId :: !Text,
    streamName :: !StreamName,
    streamVersion :: !StreamVersion,
    createdAt :: !UTCTime,
    deletedAt :: !(Maybe UTCTime),
    truncateBefore :: !StreamVersion
  }
  deriving stock (Generic, Eq, Show)

data InstancePage = InstancePage {items :: ![InstanceSummary], skipped :: !Int, next :: !(Maybe InspectionCursor)}
  deriving stock (Generic, Eq, Show)

instanceListCursorKind :: Text
instanceListCursorKind = "pm-list"

-- | Exactly one raw store page. Rejected membership rows count as examined;
-- even an empty displayed page advances from the last examined raw row.
listProcessManagerInstances :: (Store :> es) => ProcessManagerInspector phi rs s ci co -> InstanceListRequest -> Eff es (Either InstanceListError InstancePage)
listProcessManagerInstances inspector request = case parameters of
  Left err -> pure (Left err)
  Right (after, limit) -> do
    raw <- listStreams (Just (categoryName inspector.category)) (Just (categoryText inspector.category <> "-")) after limit
    let examined = Vector.toList (Vector.take request.pageSize raw)
        items = mapMaybe summary examined
        continuation =
          if Vector.length raw > request.pageSize
            then case reverse examined of
              row : _ -> maybe (Left InstanceResultTooLarge) (Right . Just) (encodeCursorBounded instanceListCursorKind (inspector.name, categoryText inspector.category, nameText row.name))
              [] -> Right Nothing
            else Right Nothing
    pure (InstancePage items (length examined - length items) <$> continuation)
  where
    parameters
      | request.pageSize < 1 || request.pageSize > 500 = Left (InvalidInstancePageSize request.pageSize)
      | otherwise = do
          limit <- either (const (Left (InvalidInstancePageSize request.pageSize))) Right (mkBrowsePageSize (request.pageSize + 1))
          after <- traverse decodeAfter request.after
          pure (after, limit)
    decodeAfter cursor = do
      (name, category, lastName) <- either (Left . InvalidInstanceCursor) Right (decodeCursor instanceListCursorKind cursor)
      if name == inspector.name && category == categoryText inspector.category && Text.isPrefixOf (category <> "-") lastName
        then Right (StreamName lastName)
        else Left (InvalidInstanceCursor (MalformedCursor "cursor belongs to another process-manager inspector"))
    summary info = do
      correlation <- inspector.correlationOf info.name
      if Text.null (Text.strip correlation) || physicalName inspector correlation /= info.name
        then Nothing
        else Just (InstanceSummary correlation info.name info.version info.createdAt info.deletedAt info.truncateBefore)

-- | Library-owned representation shared by transport adapters.
processManagerViewJson :: ProcessManagerInstanceView -> Value
processManagerViewJson view =
  object
    [ "name" .= view.name,
      "correlation_id" .= view.correlationId,
      "journal_stream_name" .= nameText view.journalStreamName,
      "stream_version" .= versionNumber view.streamVersion,
      "state_version" .= fmap (const (versionNumber view.streamVersion)) view.state,
      "observed_head_version" .= versionNumber view.observedHeadVersion,
      "created_at" .= view.createdAt,
      "deleted_at" .= view.deletedAt,
      "truncate_before" .= versionNumber view.truncateBefore,
      "observed_at" .= view.observedAt,
      "hydration" .= fmap hydrationSourceJson view.hydration,
      "state_label" .= view.stateLabel,
      "state" .= view.state,
      "last_reaction" .= fmap reactionJson view.lastReaction,
      "pending_timers" .= pendingTimerPageJson view.pendingTimers,
      "waiting_for" .= [object ["input" .= candidate.input, "target_state" .= candidate.targetState] | candidate <- view.waitingFor]
    ]

reactionJson :: LastReaction -> Value
reactionJson reaction =
  object
    [ "event_id" .= eventText reaction.eventId,
      "event_type" .= eventTypeText reaction.eventType,
      "stream_version" .= versionNumber reaction.streamVersion,
      "global_position" .= positionNumber reaction.globalPosition,
      "recorded_at" .= reaction.recordedAt,
      "provenance_status" .= (case reaction.provenance of Nothing -> "unavailable"; Just p | p.truncated -> "truncated"; _ -> "available" :: Text),
      "provenance" .= fmap provenanceJson reaction.provenance
    ]
  where
    provenanceJson record =
      object
        [ "family" .= record.family,
          "truncated" .= record.truncated,
          "source_event_id" .= eventText record.sourceEventId,
          "source_global_position" .= positionNumber record.sourceGlobalPosition,
          "source_stream_id" .= streamNumber record.sourceStreamId,
          "source_stream_name" .= fmap nameText reaction.sourceStreamName,
          "dispatched_commands"
            .= [ object
                   [ "emit_index" .= status.emitIndex,
                     "target_stream_name" .= nameText status.targetStreamName,
                     "event_id" .= eventText status.eventId,
                     "witness" .= (case status.witness of EventPresent -> "event_present"; NotObserved -> "not_observed" :: Text)
                   ]
               | status <- reaction.dispatchedCommands
               ],
          "timer_ids" .= [UUID.toText uuid | TimerId uuid <- record.timerIds]
        ]

instancePageJson :: InstancePage -> Value
instancePageJson page =
  object
    ( [ "items"
          .= [ object
                 [ "correlation_id" .= item.correlationId,
                   "stream_name" .= nameText item.streamName,
                   "stream_version" .= versionNumber item.streamVersion,
                   "created_at" .= item.createdAt,
                   "deleted_at" .= item.deletedAt,
                   "truncate_before" .= versionNumber item.truncateBefore
                 ]
             | item <- page.items
             ],
        "skipped" .= page.skipped
      ]
        <> maybe [] (\cursor -> ["next_cursor" .= cursor.cursorText]) page.next
    )

nameText :: StreamName -> Text
nameText (StreamName value) = value

versionNumber :: StreamVersion -> Int64
versionNumber (StreamVersion value) = value

positionNumber :: GlobalPosition -> Int64
positionNumber (GlobalPosition value) = value

streamNumber :: StreamId -> Int64
streamNumber (StreamId value) = value

eventText :: EventId -> Text
eventText (EventId value) = UUID.toText value

eventTypeText :: EventType -> Text
eventTypeText (EventType value) = value
