{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Application-owned aggregate descriptions and read-only inspection.
-- Raw history belongs to Kiroku; these reads return folded state and references.
module Keiro.Inspection.Aggregate
  ( AggregateInspector (..),
    SomeAggregateInspector (..),
    AggregateInspectors,
    aggregateInspector,
    inspectorFromAuditTarget,
    displayViaStateCodec,
    aggregateInspectors,
    inspectorName,
    AggregateTypeSummary (..),
    listAggregateTypes,
    AggregateInspectionError (..),
    aggregateStream,
    aggregateIdOf,
    SnapshotCompatibility (..),
    SnapshotConfig (..),
    StoredSnapshot (..),
    SnapshotStatus (..),
    HistoryReference (..),
    AggregateView (..),
    inspectAggregate,
    snapshotStatusFor,
    AggregateListRequest (..),
    AggregateSummary (..),
    AggregateListPage (..),
    maxAggregatePageSize,
    aggregateListCursorKind,
    listAggregates,
    aggregateTypeJson,
    hydrationSourceJson,
    snapshotStatusJson,
    aggregateViewJson,
    aggregateSummaryJson,
    aggregateListPageJson,
    inspectionErrorText,
  )
where

import Data.Aeson (object, (.=))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text qualified as Text
import Data.Time (diffUTCTime)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Keiki.Core (BoolAlg, RegFile)
import Keiro.Command
import Keiro.EventStream (EventStream, SnapshotPolicy (..), StateCodec)
import Keiro.EventStream.Validate (ValidatedEventStream, unvalidated)
import Keiro.Inspection.Cursor
import Keiro.Prelude hiding ((.=))
import Keiro.ReplayAudit (AuditTarget, streamInCategory)
import Keiro.Snapshot (SnapshotMissReason (..))
import Keiro.Snapshot.Schema qualified as Snapshot
import Keiro.Stream (CategoryError, Stream, StreamCategory, categoryName, categoryText, entityStream)
import Keiro.Stream qualified as Stream
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Read (getStream, listStreams)
import Kiroku.Store.Types (StreamInfo (..), StreamName (..), StreamVersion (..), mkBrowsePageSize)

data AggregateInspector phi rs s ci co = AggregateInspector
  { name :: !Text,
    eventStream :: !(ValidatedEventStream phi rs s ci co),
    category :: !(StreamCategory (EventStream phi rs s ci co)),
    mkStream :: !(StreamName -> Maybe (Stream (EventStream phi rs s ci co))),
    displayState :: !(s -> RegFile rs -> Value),
    stateLabel :: !(s -> Text)
  }
  deriving stock (Generic)

aggregateInspector :: (Show s) => Text -> ValidatedEventStream phi rs s ci co -> StreamCategory (EventStream phi rs s ci co) -> (s -> RegFile rs -> Value) -> AggregateInspector phi rs s ci co
aggregateInspector name eventStream cat displayState =
  AggregateInspector name eventStream cat (streamInCategory (categoryText cat)) displayState (Text.pack . show)

inspectorFromAuditTarget :: (Show s) => Text -> AuditTarget phi rs s ci co -> (s -> RegFile rs -> Value) -> Either CategoryError (AggregateInspector phi rs s ci co)
inspectorFromAuditTarget name target display = do
  cat <- Stream.category (target ^. #category)
  pure ((aggregateInspector name (target ^. #eventStream) cat display) {mkStream = target ^. #mkStream})

displayViaStateCodec :: StateCodec (s, RegFile rs) -> s -> RegFile rs -> Value
displayViaStateCodec codec state registers = (codec ^. #encode) (state, registers)

data SomeAggregateInspector where
  SomeAggregateInspector :: (BoolAlg phi (RegFile rs, ci), Eq co) => AggregateInspector phi rs s ci co -> SomeAggregateInspector

type AggregateInspectors = Map Text SomeAggregateInspector

inspectorName :: SomeAggregateInspector -> Text
inspectorName (SomeAggregateInspector inspector) = inspector.name

aggregateInspectors :: [SomeAggregateInspector] -> Either Text AggregateInspectors
aggregateInspectors = go Map.empty
  where
    go acc [] = Right acc
    go acc (inspector : rest)
      | Map.member (inspectorName inspector) acc = Left ("duplicate aggregate inspector: " <> inspectorName inspector)
      | otherwise = go (Map.insert (inspectorName inspector) inspector acc) rest

data AggregateTypeSummary = AggregateTypeSummary
  {name :: !Text, category :: !Text, snapshotsConfigured :: !Bool, snapshotPolicy :: !Text}
  deriving stock (Eq, Show, Generic)

policyLabel :: SnapshotPolicy s -> Text
policyLabel = \case Never -> "never"; Every n -> "every:" <> Text.pack (show n); OnTerminal -> "on_terminal"; Custom _ -> "custom"

listAggregateTypes :: AggregateInspectors -> [AggregateTypeSummary]
listAggregateTypes = map describe . Map.elems
  where
    describe :: SomeAggregateInspector -> AggregateTypeSummary
    describe (SomeAggregateInspector inspector) =
      let definition = unvalidated inspector.eventStream
       in AggregateTypeSummary inspector.name (categoryText inspector.category) (isJust (definition ^. #stateCodec)) (policyLabel (definition ^. #snapshotPolicy))

data AggregateInspectionError
  = AggregateNotFound !StreamName
  | AggregateIdRejected !Text
  | AggregateHydrationFailed !StreamName !CommandError
  | InvalidPageSize !Int
  | InvalidCursor !CursorError
  | ResultTooLarge
  deriving stock (Eq, Show, Generic)

aggregateStream :: AggregateInspector phi rs s ci co -> Text -> Either AggregateInspectionError (Stream (EventStream phi rs s ci co))
aggregateStream inspector aggregateId
  | Text.null (Text.strip aggregateId) = Left (AggregateIdRejected aggregateId)
  | otherwise =
      let target = entityStream inspector.category aggregateId
       in case inspector.mkStream (Stream.streamName target) of
            Nothing -> Left (AggregateIdRejected aggregateId)
            Just accepted | inspectorStreamName inspector accepted == Stream.streamName target -> Right accepted
            _ -> Left (AggregateIdRejected aggregateId)

-- Metadata, membership and hydration must name the same physical stream even
-- when an audit target maps a physical name to a different typed handle.
inspectorStreamName :: AggregateInspector phi rs s ci co -> Stream (EventStream phi rs s ci co) -> StreamName
inspectorStreamName inspector target = (unvalidated inspector.eventStream ^. #resolveStreamName) target

aggregateIdOf :: AggregateInspector phi rs s ci co -> StreamName -> Maybe Text
aggregateIdOf inspector name@(StreamName raw) = do
  accepted <- inspector.mkStream name
  if inspectorStreamName inspector accepted /= name
    then Nothing
    else do
      suffix <- Text.stripPrefix (categoryText inspector.category <> "-") raw
      if Text.null (Text.strip suffix) then Nothing else Just suffix

data SnapshotCompatibility = Compatible | Incompatible ![Text] | Unused
  deriving stock (Eq, Show, Generic)

data SnapshotConfig = SnapshotConfig
  {policy :: !Text, stateCodecVersion :: !Int, regfileShapeHash :: !Text, stateShapeHash :: !Text}
  deriving stock (Eq, Show, Generic)

data StoredSnapshot = StoredSnapshot
  { aheadOfObservedHead :: !Bool,
    streamVersion :: !StreamVersion,
    createdAt :: !UTCTime,
    updatedAt :: !UTCTime,
    ageSeconds :: !Double,
    eventsSince :: !Int64,
    stateCodecVersion :: !Int,
    regfileShapeHash :: !Text,
    stateShapeHash :: !Text,
    compatibility :: !SnapshotCompatibility
  }
  deriving stock (Eq, Show, Generic)

data SnapshotStatus = SnapshotStatus
  {observedAt :: !UTCTime, configured :: !(Maybe SnapshotConfig), stored :: !(Maybe StoredSnapshot)}
  deriving stock (Eq, Show, Generic)

data HistoryReference = HistoryReference
  {owner :: !Text, streamName :: !StreamName, headVersion :: !StreamVersion}
  deriving stock (Eq, Show, Generic)

data AggregateView = AggregateView
  { name :: !Text,
    category :: !Text,
    aggregateId :: !Text,
    streamName :: !StreamName,
    streamVersion :: !StreamVersion,
    createdAt :: !UTCTime,
    deletedAt :: !(Maybe UTCTime),
    truncateBefore :: !StreamVersion,
    hydration :: !(Maybe HydrationSource),
    stateLabel :: !(Maybe Text),
    state :: !(Maybe Value),
    snapshot :: !SnapshotStatus,
    history :: !HistoryReference
  }
  deriving stock (Eq, Show, Generic)

snapshotStatusOf :: (Store :> es) => AggregateInspector phi rs s ci co -> StreamInfo -> Eff es SnapshotStatus
snapshotStatusOf inspector info = do
  observation <- Snapshot.observeSnapshotRow info.id
  let definition = unvalidated inspector.eventStream
      configured = fmap (\codec -> SnapshotConfig (policyLabel (definition ^. #snapshotPolicy)) (codec ^. #stateCodecVersion) (codec ^. #shapeHash) (codec ^. #stateShapeHash)) (definition ^. #stateCodec)
      stored =
        fmap
          ( \row ->
              StoredSnapshot
                (row.streamVersion > info.version)
                row.streamVersion
                row.createdAt
                row.updatedAt
                (realToFrac (diffUTCTime observation.observedAt row.updatedAt))
                (max 0 (versionInt info.version - versionInt row.streamVersion))
                row.stateCodecVersion
                row.regfileShapeHash
                row.stateShapeHash
                (compatibilityOf configured row)
          )
          observation.row
  pure SnapshotStatus {observedAt = observation.observedAt, configured, stored}
  where
    compatibilityOf :: Maybe SnapshotConfig -> Snapshot.SnapshotRow -> SnapshotCompatibility
    compatibilityOf Nothing _ = Unused
    compatibilityOf (Just config) row =
      case [key | (key, differs) <- [("state_codec_version", config.stateCodecVersion /= row.stateCodecVersion), ("regfile_shape_hash", config.regfileShapeHash /= row.regfileShapeHash), ("state_shape_hash", config.stateShapeHash /= row.stateShapeHash)], differs] of
        [] -> Compatible
        keys -> Incompatible keys

snapshotStatusFor :: (Store :> es) => AggregateInspector phi rs s ci co -> Text -> Eff es (Either AggregateInspectionError (StreamName, StreamVersion, SnapshotStatus))
snapshotStatusFor inspector aggregateId =
  case aggregateStream inspector aggregateId of
    Left err -> pure (Left err)
    Right target -> do
      info <- getStream (inspectorStreamName inspector target)
      case info of
        Nothing -> pure (Left (AggregateNotFound (inspectorStreamName inspector target)))
        Just found -> do
          status <- snapshotStatusOf inspector found
          pure (Right (found.name, found.version, status))

inspectAggregate :: (IOE :> es, Store :> es, BoolAlg phi (RegFile rs, ci), Eq co) => AggregateInspector phi rs s ci co -> Text -> Eff es (Either AggregateInspectionError AggregateView)
inspectAggregate inspector aggregateId =
  case aggregateStream inspector aggregateId of
    Left err -> pure (Left err)
    Right target ->
      getStream (inspectorStreamName inspector target) >>= \case
        Nothing -> pure (Left (AggregateNotFound (inspectorStreamName inspector target)))
        Just info -> do
          folded <- if isJust info.deletedAt then pure (Right Nothing) else fmap (fmap Just) (hydrateWithSource inspectionRunCommandOptions (unvalidated inspector.eventStream) target)
          case folded of
            Left err -> pure (Left (AggregateHydrationFailed info.name err))
            Right result -> do
              snapshot <- snapshotStatusOf inspector info
              pure
                ( Right
                    AggregateView
                      { name = inspector.name,
                        category = categoryText inspector.category,
                        aggregateId,
                        streamName = info.name,
                        streamVersion = maybe info.version (\(hydrated, _) -> hydrated ^. #streamVersion) result,
                        createdAt = info.createdAt,
                        deletedAt = info.deletedAt,
                        truncateBefore = info.truncateBefore,
                        hydration = fmap snd result,
                        stateLabel = fmap (\(hydrated, _) -> inspector.stateLabel (hydrated ^. #state)) result,
                        state = fmap (\(hydrated, _) -> inspector.displayState (hydrated ^. #state) (hydrated ^. #registers)) result,
                        snapshot,
                        history = HistoryReference "kiroku" info.name info.version
                      }
                )

data AggregateListRequest = AggregateListRequest {pageSize :: !Int, after :: !(Maybe InspectionCursor)}
  deriving stock (Eq, Show, Generic)

data AggregateSummary = AggregateSummary
  { aggregateId :: !Text,
    streamName :: !StreamName,
    streamVersion :: !StreamVersion,
    createdAt :: !UTCTime,
    deletedAt :: !(Maybe UTCTime),
    truncateBefore :: !StreamVersion
  }
  deriving stock (Eq, Show, Generic)

data AggregateListPage = AggregateListPage
  {name :: !Text, category :: !Text, items :: ![AggregateSummary], skipped :: !Int, next :: !(Maybe InspectionCursor)}
  deriving stock (Eq, Show, Generic)

maxAggregatePageSize :: Int
maxAggregatePageSize = 500

aggregateListCursorKind :: Text
aggregateListCursorKind = "aggregate-list"

listAggregates :: (Store :> es) => AggregateInspector phi rs s ci co -> AggregateListRequest -> Eff es (Either AggregateInspectionError AggregateListPage)
listAggregates inspector request =
  case parameters of
    Left err -> pure (Left err)
    Right (after, limit) -> do
      raw <- listStreams (Just (categoryName inspector.category)) (Just (categoryText inspector.category <> "-")) after limit
      let examined = Vector.toList (Vector.take request.pageSize raw)
          items = mapMaybe summary examined
          continuation =
            if Vector.length raw > request.pageSize
              then case reverse examined of
                lastRow : _ -> case lastRow.name of StreamName lastName -> maybe (Left ResultTooLarge) (Right . Just) (encodeCursorBounded aggregateListCursorKind (inspector.name, categoryText inspector.category, lastName))
                [] -> Right Nothing
              else Right Nothing
      pure $ fmap (\next -> AggregateListPage inspector.name (categoryText inspector.category) items (length examined - length items) next) continuation
  where
    parameters
      | request.pageSize < 1 || request.pageSize > maxAggregatePageSize = Left (InvalidPageSize request.pageSize)
      | otherwise = do
          limit <- either (const (Left (InvalidPageSize request.pageSize))) Right (mkBrowsePageSize (request.pageSize + 1))
          after <- traverse decodeAfter request.after
          pure (after, limit)
    decodeAfter :: InspectionCursor -> Either AggregateInspectionError StreamName
    decodeAfter cursor = do
      (name, cat, lastName) <- either (Left . InvalidCursor) Right (decodeCursor aggregateListCursorKind cursor)
      if name == inspector.name && cat == categoryText inspector.category && Text.isPrefixOf (cat <> "-") lastName
        then Right (StreamName lastName)
        else Left (InvalidCursor (MalformedCursor "cursor belongs to another aggregate inspector"))
    summary :: StreamInfo -> Maybe AggregateSummary
    summary info = do
      aggregateId <- aggregateIdOf inspector info.name
      pure (AggregateSummary aggregateId info.name info.version info.createdAt info.deletedAt info.truncateBefore)

versionInt :: StreamVersion -> Int64
versionInt (StreamVersion n) = n

nameText :: StreamName -> Text
nameText (StreamName name) = name

aggregateTypeJson :: AggregateTypeSummary -> Value
aggregateTypeJson summary = object ["name" .= summary.name, "category" .= summary.category, "snapshots_configured" .= summary.snapshotsConfigured, "snapshot_policy" .= summary.snapshotPolicy]

hydrationSourceJson :: HydrationSource -> Value
hydrationSourceJson = \case
  FromSnapshot version -> object ["source" .= ("snapshot" :: Text), "snapshot_version" .= versionInt version]
  FullReplay reason ->
    object
      ( ["source" .= ("full_replay" :: Text)] <> case reason of
          NoStateCodec -> ["reason" .= ("no_state_codec" :: Text)]
          SnapshotMissed miss ->
            ["reason" .= ("snapshot_missed" :: Text)] <> case miss of
              SnapshotNoStream -> ["miss" .= ("no_stream" :: Text)]
              SnapshotNotFound -> ["miss" .= ("not_found" :: Text)]
              SnapshotDecodeFailed detail -> ["miss" .= ("decode_failed" :: Text), "detail" .= detail]
          SeededReplayFailed err -> ["reason" .= ("seeded_replay_failed" :: Text), "error" .= commandErrorClass err, "detail" .= Text.pack (show err)]
      )

snapshotStatusJson :: SnapshotStatus -> Value
snapshotStatusJson status =
  object
    [ "status" .= (if isJust status.stored then "present" else "absent" :: Text),
      "observed_at" .= status.observedAt,
      "configured" .= fmap configJson status.configured,
      "stored" .= fmap storedJson status.stored
    ]
  where
    configJson :: SnapshotConfig -> Value
    configJson config = object ["policy" .= config.policy, "state_codec_version" .= config.stateCodecVersion, "regfile_shape_hash" .= config.regfileShapeHash, "state_shape_hash" .= config.stateShapeHash]
    storedJson :: StoredSnapshot -> Value
    storedJson stored =
      object
        [ "stream_version" .= versionInt stored.streamVersion,
          "created_at" .= stored.createdAt,
          "updated_at" .= stored.updatedAt,
          "age_seconds" .= stored.ageSeconds,
          "events_since" .= stored.eventsSince,
          "ahead_of_observed_head" .= stored.aheadOfObservedHead,
          "state_codec_version" .= stored.stateCodecVersion,
          "regfile_shape_hash" .= stored.regfileShapeHash,
          "state_shape_hash" .= stored.stateShapeHash,
          "compatibility" .= (case stored.compatibility of Compatible -> "compatible"; Incompatible _ -> "incompatible"; Unused -> "unused" :: Text),
          "mismatched" .= (case stored.compatibility of Incompatible fields -> fields; _ -> [])
        ]

aggregateViewJson :: AggregateView -> Value
aggregateViewJson view =
  object
    [ "name" .= view.name,
      "category" .= view.category,
      "aggregate_id" .= view.aggregateId,
      "stream_name" .= nameText view.streamName,
      "stream_version" .= versionInt view.streamVersion,
      "state_version" .= (if isJust view.state then Just (versionInt view.streamVersion) else Nothing),
      "created_at" .= view.createdAt,
      "deleted_at" .= view.deletedAt,
      "truncate_before" .= versionInt view.truncateBefore,
      "hydration" .= fmap hydrationSourceJson view.hydration,
      "state_label" .= view.stateLabel,
      "state" .= view.state,
      "snapshot" .= snapshotStatusJson view.snapshot,
      "history" .= object ["owner" .= view.history.owner, "stream_name" .= nameText view.history.streamName, "head_version" .= versionInt view.history.headVersion]
    ]

aggregateSummaryJson :: AggregateSummary -> Value
aggregateSummaryJson summary =
  object
    [ "aggregate_id" .= summary.aggregateId,
      "stream_name" .= nameText summary.streamName,
      "stream_version" .= versionInt summary.streamVersion,
      "created_at" .= summary.createdAt,
      "deleted_at" .= summary.deletedAt,
      "truncate_before" .= versionInt summary.truncateBefore
    ]

aggregateListPageJson :: AggregateListPage -> Value
aggregateListPageJson page =
  object
    ( ["name" .= page.name, "category" .= page.category, "items" .= map aggregateSummaryJson page.items, "skipped" .= page.skipped]
        <> maybe [] (\cursor -> ["next_cursor" .= cursor.cursorText]) page.next
    )

inspectionErrorText :: AggregateInspectionError -> Text
inspectionErrorText = \case
  AggregateNotFound name -> "aggregate not found: " <> nameText name
  AggregateIdRejected aggregateId -> "aggregate id rejected: " <> aggregateId
  AggregateHydrationFailed name err -> "aggregate hydration failed: " <> nameText name <> ": " <> Text.pack (show err)
  InvalidPageSize n -> "page size must be 1..500: " <> Text.pack (show n)
  InvalidCursor err -> "invalid aggregate cursor: " <> Text.pack (show err)
  ResultTooLarge -> "aggregate continuation exceeds the cursor byte limit"
