{-# OPTIONS_HADDOCK hide #-}

-- | Catalog-driven, fixed-head projection replay.
module Keiro.ReadModel.Rebuild.Runner
  ( RebuildOptions (..),
    defaultRebuildOptions,
    CatalogRebuildError (..),
    RebuildRunStatus (..),
    RebuildFailureEvidence (..),
    RebuildSourceProgress (..),
    RebuildAdapterProgress (..),
    RebuildVerificationProgress (..),
    RebuildRunReport (..),
    startCatalogRebuild,
    resumeCatalogRebuild,
    inspectCatalogRebuild,
    abandonCatalogRebuild,
  )
where

import Contravariant.Extras
  ( contrazip2,
    contrazip3,
    contrazip4,
    contrazip5,
    contrazip6,
    contrazip8,
  )
import Data.Int (Int32)
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text qualified as Text
import Data.Time (diffUTCTime)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import Keiro.Projection.Catalog
  ( CatalogReplayAdapter,
    RebuildGroupId,
    RebuildVerification (..),
    ReplayDecodeError (..),
    SourceId,
    SourceScope (..),
    ValidatedProjectionCatalog,
    catalogFingerprintText,
    catalogInventory,
    catalogRebuildVerifications,
    catalogReplayAdapterOrder,
    catalogReplayAdapterProjectionId,
    catalogReplayAdapterSourceId,
    catalogReplayAdapters,
    groupSliceFingerprintText,
    projectionIdText,
    rebuildGroupIdText,
    runCatalogReplayAdapter,
    sourceIdText,
  )
import Keiro.Projection.Catalog qualified as Catalog
import Keiro.Projection.Catalog.Preimage (Preimage (..), hashPreimage)
import Keiro.ReadModel.Rebuild.Group
  ( GroupTransitionError,
    RebuildFailure (..),
    RebuildRequest (..),
    RebuildRunId,
    RebuildStartError,
    abandonGroupRebuild,
    abandonPreCanonicalGroupRebuild,
    beginGroupRebuild,
    completionTokenForHandle,
    finishGroupRebuildTx,
    groupRebuildHandleFor,
    mkRebuildRunId,
    preCanonicalRunSliceSentinel,
    rebuildRunIdText,
  )
import Keiro.Telemetry (KeiroMetrics)
import Keiro.Telemetry qualified as Telemetry
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Read qualified as Store
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (CategoryName (..), GlobalPosition (..), RecordedEvent)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude (all, any, concatMap, const, filter, id, not, null, (&&), (*), (+), (||))
import Prelude qualified

runnerFormat :: Text
runnerFormat = "keiro/projection-replay/v4"

data RebuildOptions = RebuildOptions
  { rebuildRequest :: !RebuildRequest,
    replayPageSize :: !Int32,
    rebuildMetrics :: !(Maybe KeiroMetrics)
  }
  deriving stock (Generic)

defaultRebuildOptions :: RebuildRequest -> RebuildOptions
defaultRebuildOptions request =
  RebuildOptions
    { rebuildRequest = request,
      replayPageSize = 500,
      rebuildMetrics = Nothing
    }

data CatalogRebuildError
  = CatalogRebuildInvalidPageSize !Int32
  | CatalogRebuildRunAlreadyExists !RebuildRunId
  | CatalogRebuildRunNotFound !RebuildRunId
  | CatalogRebuildStartFailed !RebuildStartError
  | CatalogRebuildStartAfterCapturedHead !GlobalPosition !GlobalPosition
  | CatalogRebuildContractMismatch !RebuildRunId !Text !Text
  | CatalogRebuildSliceMismatch !RebuildRunId !Text !Text
  | -- | The run predates canonical slice identity and must be abandoned,
    -- adopted, and started fresh rather than resumed.
    CatalogRebuildRunPreCanonical !RebuildRunId !RebuildGroupId
  | CatalogRebuildGroupMissing !RebuildGroupId
  | CatalogRebuildRunNotActive !RebuildRunId
  | CatalogRebuildDecodeFailed !RebuildRunId !SourceId !Text !GlobalPosition !ReplayDecodeError
  | CatalogRebuildVerificationFailed !RebuildRunId !Text !Text
  | CatalogRebuildInvariantFailed !RebuildRunId !Text
  | CatalogRebuildPromotionFailed !GroupTransitionError
  | CatalogRebuildAbandonFailed !GroupTransitionError
  deriving stock (Eq, Show, Generic)

data RebuildRunStatus
  = RebuildRunRunning
  | RebuildRunFailed
  | RebuildRunVerified
  | RebuildRunPromoted
  | UnknownRebuildRunStatus !Text
  deriving stock (Eq, Ord, Show, Generic)

data RebuildFailureEvidence = RebuildFailureEvidence
  { failureCode :: !Text,
    failureDetail :: !Text,
    failureSourceId :: !(Maybe SourceId),
    failureProjectionId :: !(Maybe Text),
    failurePosition :: !(Maybe GlobalPosition)
  }
  deriving stock (Eq, Show, Generic)

data RebuildSourceProgress = RebuildSourceProgress
  { sourceId :: !SourceId,
    sourceScope :: !SourceScope,
    cursorPosition :: !GlobalPosition,
    targetPosition :: !GlobalPosition,
    exhaustedThrough :: !(Maybe GlobalPosition),
    eventCount :: !Int64
  }
  deriving stock (Eq, Show, Generic)

data RebuildAdapterProgress = RebuildAdapterProgress
  { sourceId :: !SourceId,
    projectionId :: !Text,
    adapterOrder :: !Int,
    evaluationCount :: !Int64,
    applyCount :: !Int64,
    completedThrough :: !(Maybe GlobalPosition)
  }
  deriving stock (Eq, Show, Generic)

data RebuildVerificationProgress = RebuildVerificationProgress
  { verificationId :: !Text,
    verificationVersion :: !Text,
    verificationStatus :: !Text,
    verificationDetail :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

data RebuildRunReport = RebuildRunReport
  { rebuildRunId :: !RebuildRunId,
    rebuildGroupId :: !RebuildGroupId,
    catalogFingerprint :: !Text,
    groupSliceFingerprint :: !Text,
    contractFingerprint :: !Text,
    runnerFormatVersion :: !Text,
    capturedHead :: !GlobalPosition,
    configuredPageSize :: !Int32,
    runStatus :: !RebuildRunStatus,
    failureEvidence :: !(Maybe RebuildFailureEvidence),
    sources :: ![RebuildSourceProgress],
    adapters :: ![RebuildAdapterProgress],
    verifications :: ![RebuildVerificationProgress]
  }
  deriving stock (Eq, Show, Generic)

data SourceSpec = SourceSpec
  { specSourceId :: !SourceId,
    specScope :: !SourceScope
  }
  deriving stock (Generic)

data SourcePage = SourcePage
  { pageSource :: !RebuildSourceProgress,
    pageEvents :: ![RecordedEvent],
    pageProvesExhaustion :: !Bool
  }
  deriving stock (Generic)

data RoutedEvent = RoutedEvent
  { routedSourceId :: !SourceId,
    routedEvent :: !RecordedEvent
  }
  deriving stock (Generic)

data AdapterCounts = AdapterCounts
  { evaluations :: !Int64,
    applications :: !Int64
  }
  deriving stock (Generic)

startCatalogRebuild ::
  (IOE :> es, Store :> es) =>
  ValidatedProjectionCatalog ->
  RebuildGroupId ->
  RebuildOptions ->
  Eff es (Either CatalogRebuildError RebuildRunReport)
startCatalogRebuild catalog groupId options
  | options ^. #replayPageSize <= 0 =
      pure (Left (CatalogRebuildInvalidPageSize (options ^. #replayPageSize)))
  | otherwise = do
      let request = options ^. #rebuildRequest
          runId = request ^. #rebuildRunId
      existing <- inspectCatalogRebuildMaybe runId
      case existing of
        Just _ -> pure (Left (CatalogRebuildRunAlreadyExists runId))
        Nothing -> case rebuildContract catalog groupId of
          Nothing -> pure (Left (CatalogRebuildGroupMissing groupId))
          Just contract -> do
            started <- beginGroupRebuild catalog groupId request
            case started of
              Left err -> pure (Left (CatalogRebuildStartFailed err))
              Right handle -> do
                headPosition <- captureHead
                if request ^. #replayFrom > headPosition
                  then do
                    _ <-
                      abandonGroupRebuild
                        handle
                        RebuildFailure
                          { failureCode = "replay.start-after-head",
                            failureDetail =
                              "requested replay cursor is beyond the captured store head"
                          }
                    pure
                      ( Left
                          ( CatalogRebuildStartAfterCapturedHead
                              (request ^. #replayFrom)
                              headPosition
                          )
                      )
                  else do
                    runTransaction
                      ( initializeRunTx
                          catalog
                          groupId
                          options
                          headPosition
                          contract
                      )
                    Telemetry.recordProjectionRebuildStarts (options ^. #rebuildMetrics) 1
                    driveCatalogRebuild catalog groupId runId (options ^. #replayPageSize) contract (options ^. #rebuildMetrics)

resumeCatalogRebuild ::
  (IOE :> es, Store :> es) =>
  ValidatedProjectionCatalog ->
  RebuildRunId ->
  RebuildOptions ->
  Eff es (Either CatalogRebuildError RebuildRunReport)
resumeCatalogRebuild catalog runId options
  | options ^. #replayPageSize <= 0 =
      pure (Left (CatalogRebuildInvalidPageSize (options ^. #replayPageSize)))
  | otherwise = do
      inspectCatalogRebuildMaybe runId >>= \case
        Nothing -> pure (Left (CatalogRebuildRunNotFound runId))
        Just report
          | report ^. #groupSliceFingerprint == preCanonicalRunSliceSentinel ->
              pure
                ( Left
                    ( CatalogRebuildRunPreCanonical
                        runId
                        (report ^. #rebuildGroupId)
                    )
                )
          | otherwise -> do
              let groupId = report ^. #rebuildGroupId
                  expected = report ^. #contractFingerprint
              case rebuildContract catalog groupId of
                Nothing -> pure (Left (CatalogRebuildGroupMissing groupId))
                Just actual ->
                  if expected /= actual
                    then pure (Left (CatalogRebuildContractMismatch runId expected actual))
                    else do
                      resumed <- runTransaction (resumeRunTx runId (options ^. #replayPageSize) actual)
                      if resumed
                        then do
                          Telemetry.recordProjectionRebuildResumes (options ^. #rebuildMetrics) 1
                          driveCatalogRebuild catalog groupId runId (options ^. #replayPageSize) actual (options ^. #rebuildMetrics)
                        else pure (Left (CatalogRebuildRunNotActive runId))

inspectCatalogRebuild ::
  (Store :> es) =>
  RebuildRunId ->
  Eff es (Either CatalogRebuildError RebuildRunReport)
inspectCatalogRebuild runId =
  maybe (Left (CatalogRebuildRunNotFound runId)) Right
    <$> inspectCatalogRebuildMaybe runId

inspectCatalogRebuildMaybe ::
  (Store :> es) =>
  RebuildRunId ->
  Eff es (Maybe RebuildRunReport)
inspectCatalogRebuildMaybe runId =
  runTransaction $ do
    maybeRun <- Tx.statement (rebuildRunIdText runId) inspectRunStmt
    traverse
      ( \report -> do
          sourceRows <- Tx.statement (rebuildRunIdText runId) inspectSourcesStmt
          adapterRows <- Tx.statement (rebuildRunIdText runId) inspectAdaptersStmt
          verificationRows <- Tx.statement (rebuildRunIdText runId) inspectVerificationsStmt
          pure
            report
              { sources = sourceRows,
                adapters = adapterRows,
                verifications = verificationRows
              }
      )
      maybeRun

abandonCatalogRebuild ::
  (Store :> es) =>
  ValidatedProjectionCatalog ->
  RebuildRunId ->
  RebuildFailure ->
  Eff es (Either CatalogRebuildError RebuildRunReport)
abandonCatalogRebuild catalog runId failure =
  inspectCatalogRebuildMaybe runId >>= \case
    Nothing -> pure (Left (CatalogRebuildRunNotFound runId))
    Just report
      | report ^. #groupSliceFingerprint == preCanonicalRunSliceSentinel ->
          case report ^. #runStatus of
            RebuildRunRunning -> abandonPreCanonical report
            RebuildRunFailed -> abandonPreCanonical report
            _ -> pure (Left (CatalogRebuildRunNotActive runId))
      | otherwise -> do
          let groupId = report ^. #rebuildGroupId
              stored = report ^. #groupSliceFingerprint
          case groupSliceFingerprintText <$> Catalog.groupSliceFingerprint catalog groupId of
            Nothing -> pure (Left (CatalogRebuildGroupMissing groupId))
            Just current ->
              if stored /= current
                then pure (Left (CatalogRebuildSliceMismatch runId stored current))
                else case groupRebuildHandleFor catalog groupId runId of
                  Nothing -> pure (Left (CatalogRebuildRunNotActive runId))
                  Just handle -> do
                    abandoned <- abandonGroupRebuild handle failure
                    recordAbandonment abandoned
  where
    abandonPreCanonical report = do
      abandoned <-
        abandonPreCanonicalGroupRebuild
          (report ^. #rebuildGroupId)
          runId
          failure
      recordAbandonment abandoned

    recordAbandonment = \case
      Left err -> pure (Left (CatalogRebuildAbandonFailed err))
      Right _ -> do
        recordFailure
          runId
          (failure ^. #failureCode)
          (failure ^. #failureDetail)
          Nothing
          Nothing
          Nothing
        inspectCatalogRebuild runId

captureHead :: (Store :> es) => Eff es GlobalPosition
captureHead = do
  events <- Store.readAllBackward (GlobalPosition 0) 1
  pure $ maybe (GlobalPosition 0) (^. #globalPosition) (events Vector.!? 0)

driveCatalogRebuild ::
  (IOE :> es, Store :> es) =>
  ValidatedProjectionCatalog ->
  RebuildGroupId ->
  RebuildRunId ->
  Int32 ->
  Text ->
  Maybe KeiroMetrics ->
  Eff es (Either CatalogRebuildError RebuildRunReport)
driveCatalogRebuild catalog groupId runId pageSize contract metrics =
  inspectCatalogRebuildMaybe runId >>= continueFromReport
  where
    fleet = catalogReplayAdapters catalog groupId

    continueFromReport = \case
      Nothing -> pure (Left (CatalogRebuildRunNotFound runId))
      Just report
        | report ^. #runStatus == RebuildRunPromoted -> pure (Right report)
        | report ^. #runStatus /= RebuildRunRunning ->
            pure (Left (CatalogRebuildRunNotActive runId))
        | all sourceComplete (report ^. #sources) ->
            verifyAndPromote catalog groupId runId contract metrics
        | otherwise ->
            go
              (appliedFloor report)
              [ emptySourcePage source
              | source <- report ^. #sources,
                not (sourceComplete source)
              ]

    appliedFloor report =
      List.foldl'
        Prelude.max
        (GlobalPosition 0)
        [source ^. #cursorPosition | source <- report ^. #sources]

    go appliedThrough buffers = do
      pages <- traverse refillSourcePage buffers
      let ordered = orderedCandidates pages
          horizon = mergeHorizon pages
          eligible =
            Prelude.takeWhile
              ((<= horizon) . (^. #globalPosition) . (^. #routedEvent))
              ordered
          chunk = Prelude.take (Prelude.fromIntegral pageSize) eligible
      case duplicatePosition ordered of
        Just duplicate -> do
          let detail = "duplicate global position in merged category history: " <> renderPosition duplicate
          recordFailure runId "replay.global-position-duplicate" detail Nothing Nothing (Just duplicate)
          Telemetry.recordProjectionRebuildFailures metrics 1
          pure (Left (CatalogRebuildInvariantFailed runId detail))
        Nothing
          | Just regressed <- chunkRegression appliedThrough chunk -> do
              let detail =
                    "merged chunk regressed to global position "
                      <> renderPosition regressed
                      <> " at or below applied floor "
                      <> renderPosition appliedThrough
              recordFailure runId "replay.global-position-regression" detail Nothing Nothing (Just regressed)
              Telemetry.recordProjectionRebuildFailures metrics 1
              pure (Left (CatalogRebuildInvariantFailed runId detail))
          | null chunk,
            not (null ordered) -> do
              let detail = "buffered merge stalled: candidates exist above the merge horizon " <> renderPosition horizon
              recordFailure runId "replay.buffer-horizon-stalled" detail Nothing Nothing Nothing
              Telemetry.recordProjectionRebuildFailures metrics 1
              pure (Left (CatalogRebuildInvariantFailed runId detail))
          | otherwise -> do
              startedAt <- liftIO getCurrentTime
              applied <- runTransaction (applyChunkTx runId contract fleet pages chunk)
              case applied of
                Left ChunkInactive ->
                  pure (Left (CatalogRebuildRunNotActive runId))
                Left ChunkInterfered ->
                  inspectCatalogRebuildMaybe runId >>= continueFromReport
                Left (ChunkDecode failure) -> do
                  recordFailure
                    runId
                    "replay.decode-failure"
                    (failure ^. #decodeDetail)
                    (Just (failure ^. #decodeSource))
                    (Just (failure ^. #decodeProjection))
                    (Just (failure ^. #decodePosition))
                  Telemetry.recordProjectionRebuildFailures metrics 1
                  pure
                    ( Left
                        ( CatalogRebuildDecodeFailed
                            runId
                            (failure ^. #decodeSource)
                            (failure ^. #decodeProjection)
                            (failure ^. #decodePosition)
                            (failure ^. #decodeError)
                        )
                    )
                Right () -> do
                  finishedAt <- liftIO getCurrentTime
                  Telemetry.recordProjectionRebuildPages metrics 1
                  Telemetry.recordProjectionRebuildEvents metrics (Prelude.fromIntegral (Prelude.length chunk))
                  Telemetry.recordProjectionRebuildPageDuration metrics (Prelude.realToFrac (diffUTCTime finishedAt startedAt) * 1000)
                  let advanced = advanceSourcePages pages chunk
                      incomplete = filter (not . sourceComplete . (^. #pageSource)) advanced
                  if null incomplete
                    then verifyAndPromote catalog groupId runId contract metrics
                    else go (chunkCeiling appliedThrough chunk) incomplete

    refillSourcePage page
      | null (page ^. #pageEvents) = readSourcePage pageSize (page ^. #pageSource)
      | otherwise = pure page

emptySourcePage :: RebuildSourceProgress -> SourcePage
emptySourcePage source =
  SourcePage
    { pageSource = source,
      pageEvents = [],
      pageProvesExhaustion = False
    }

advanceSourcePages :: [SourcePage] -> [RoutedEvent] -> [SourcePage]
advanceSourcePages pages chunk = Prelude.map advance pages
  where
    advances =
      Map.fromListWith
        combine
        [ ( routed ^. #routedSourceId,
            (routed ^. #routedEvent . #globalPosition, 1 :: Int)
          )
        | routed <- chunk
        ]

    combine (leftPosition, leftCount) (rightPosition, rightCount) =
      (Prelude.max leftPosition rightPosition, leftCount + rightCount)

    advance page =
      let source = page ^. #pageSource
          (cursor, consumed) =
            Map.findWithDefault
              (source ^. #cursorPosition, 0)
              (source ^. #sourceId)
              advances
          remaining = Prelude.drop consumed (page ^. #pageEvents)
          advancedSource =
            source
              { cursorPosition = cursor,
                eventCount = source ^. #eventCount + Prelude.fromIntegral consumed,
                exhaustedThrough =
                  if null remaining && page ^. #pageProvesExhaustion
                    then Just (source ^. #targetPosition)
                    else source ^. #exhaustedThrough
              }
       in page
            { pageSource = advancedSource,
              pageEvents = remaining
            }

sourceComplete :: RebuildSourceProgress -> Bool
sourceComplete source = source ^. #exhaustedThrough == Just (source ^. #targetPosition)

readSourcePage ::
  (Store :> es) =>
  Int32 ->
  RebuildSourceProgress ->
  Eff es SourcePage
readSourcePage pageSize source = do
  raw <-
    case source ^. #sourceScope of
      AllStreams -> Store.readAllForward cursor pageSize
      CategorySource category -> Store.readCategory category cursor pageSize
  let rawEvents = Vector.toList raw
      eligible = Prelude.takeWhile ((<= target) . (^. #globalPosition)) rawEvents
      beyondTarget = Prelude.any ((> target) . (^. #globalPosition)) rawEvents
      shortPage = Vector.length raw < Prelude.fromIntegral pageSize
      reachedTarget = not (null eligible) && (Prelude.last eligible ^. #globalPosition == target)
  pure
    SourcePage
      { pageSource = source,
        pageEvents = eligible,
        pageProvesExhaustion = beyondTarget || shortPage || reachedTarget
      }
  where
    cursor = source ^. #cursorPosition
    target = source ^. #targetPosition

orderedCandidates :: [SourcePage] -> [RoutedEvent]
orderedCandidates =
  List.sortOn ((^. #globalPosition) . (^. #routedEvent))
    . concatMap
      ( \page ->
          [ RoutedEvent (page ^. #pageSource . #sourceId) event
          | event <- page ^. #pageEvents
          ]
      )

pageHorizon :: SourcePage -> GlobalPosition
pageHorizon page
  | page ^. #pageProvesExhaustion = page ^. #pageSource . #targetPosition
  | otherwise =
      case page ^. #pageEvents of
        [] -> page ^. #pageSource . #cursorPosition
        events -> Prelude.last events ^. #globalPosition

mergeHorizon :: [SourcePage] -> GlobalPosition
mergeHorizon = Prelude.minimum . Prelude.map pageHorizon

duplicatePosition :: [RoutedEvent] -> Maybe GlobalPosition
duplicatePosition candidates =
  listToMaybe
    [ left ^. #routedEvent . #globalPosition
    | (left, right) <- List.zip candidates (Prelude.drop 1 candidates),
      left ^. #routedEvent . #globalPosition == right ^. #routedEvent . #globalPosition
    ]

chunkRegression :: GlobalPosition -> [RoutedEvent] -> Maybe GlobalPosition
chunkRegression appliedThrough = \case
  routed : _
    | routed ^. #routedEvent . #globalPosition <= appliedThrough ->
        Just (routed ^. #routedEvent . #globalPosition)
  _ -> Nothing

chunkCeiling :: GlobalPosition -> [RoutedEvent] -> GlobalPosition
chunkCeiling appliedThrough = \case
  [] -> appliedThrough
  chunk -> Prelude.last chunk ^. #routedEvent . #globalPosition

data DecodeFailure = DecodeFailure
  { decodeSource :: !SourceId,
    decodeProjection :: !Text,
    decodePosition :: !GlobalPosition,
    decodeError :: !ReplayDecodeError,
    decodeDetail :: !Text
  }
  deriving stock (Generic)

data ChunkFailure
  = ChunkInactive
  | ChunkInterfered
  | ChunkDecode !DecodeFailure

applyChunkTx ::
  RebuildRunId ->
  Text ->
  [CatalogReplayAdapter] ->
  [SourcePage] ->
  [RoutedEvent] ->
  Tx.Transaction (Either ChunkFailure ())
applyChunkTx runId contract fleet pages chunk = do
  active <- Tx.statement (rebuildRunIdText runId, contract) lockActiveRunStmt
  if not active
    then Tx.condemn >> pure (Left ChunkInactive)
    else
      applyEvents Map.empty chunk >>= \case
        Left failure -> Tx.condemn >> pure (Left (ChunkDecode failure))
        Right counts -> do
          advanced <- traverse updateSource (Map.toList sourceAdvances)
          if not (all id advanced)
            then Tx.condemn >> pure (Left ChunkInterfered)
            else do
              traverse_ updateAdapter (Map.toList counts)
              traverse_ completeSource completedSources
              pure (Right ())
  where
    applyEvents counts = \case
      [] -> pure (Right counts)
      routed : rest ->
        applyAdapters counts routed (adaptersFor routed) >>= \case
          Left failure -> pure (Left failure)
          Right updated -> applyEvents updated rest

    adaptersFor routed =
      [ adapter
      | adapter <- fleet,
        catalogReplayAdapterSourceId adapter == routed ^. #routedSourceId
      ]

    applyAdapters counts _ [] = pure (Right counts)
    applyAdapters counts routed (adapter : rest) = do
      result <- runCatalogReplayAdapter adapter (routed ^. #routedEvent)
      let key =
            ( sourceIdText (catalogReplayAdapterSourceId adapter),
              projectionIdText (catalogReplayAdapterProjectionId adapter)
            )
          previous = Map.findWithDefault (AdapterCounts 0 0) key counts
          evaluated = previous {evaluations = previous ^. #evaluations + 1}
      case result of
        Left decodeError@(ReplayDecodeError detail) ->
          pure
            ( Left
                DecodeFailure
                  { decodeSource = routed ^. #routedSourceId,
                    decodeProjection = projectionIdText (catalogReplayAdapterProjectionId adapter),
                    decodePosition = routed ^. #routedEvent . #globalPosition,
                    decodeError,
                    decodeDetail = detail
                  }
            )
        Right applied ->
          let counted =
                if applied
                  then evaluated {applications = evaluated ^. #applications + 1}
                  else evaluated
           in applyAdapters (Map.insert key counted counts) routed rest

    sourceAdvances =
      Map.fromListWith
        combineSourceAdvance
        [ ( sourceIdText (routed ^. #routedSourceId),
            (routed ^. #routedEvent . #globalPosition, 1 :: Int64)
          )
        | routed <- chunk
        ]

    combineSourceAdvance (leftPosition, leftCount) (rightPosition, rightCount) =
      (Prelude.max leftPosition rightPosition, leftCount + rightCount)

    updateSource (sourceId, (GlobalPosition cursor, count)) =
      case Map.lookup sourceId expectedSourceCursors of
        Nothing -> pure False
        Just (GlobalPosition expected) ->
          Tx.statement
            (rebuildRunIdText runId, sourceId, expected, cursor, count)
            advanceSourceStmt

    updateAdapter ((sourceId, projectionId), AdapterCounts evaluationDelta applyDelta) =
      Tx.statement
        (rebuildRunIdText runId, sourceId, projectionId, evaluationDelta, applyDelta)
        advanceAdapterStmt

    expectedSourceCursors =
      Map.fromList
        [ (sourceIdText (page ^. #pageSource . #sourceId), page ^. #pageSource . #cursorPosition)
        | page <- pages
        ]

    consumedCounts = fmap Prelude.snd sourceAdvances

    completedSources =
      [ page ^. #pageSource
      | page <- pages,
        page ^. #pageProvesExhaustion,
        Map.findWithDefault 0 (sourceIdText (page ^. #pageSource . #sourceId)) consumedCounts
          == Prelude.fromIntegral (Prelude.length (page ^. #pageEvents))
      ]

    completeSource source =
      let GlobalPosition target = source ^. #targetPosition
       in Tx.statement
            (rebuildRunIdText runId, sourceIdText (source ^. #sourceId), target)
            completeSourceStmt

verifyAndPromote ::
  (IOE :> es, Store :> es) =>
  ValidatedProjectionCatalog ->
  RebuildGroupId ->
  RebuildRunId ->
  Text ->
  Maybe KeiroMetrics ->
  Eff es (Either CatalogRebuildError RebuildRunReport)
verifyAndPromote catalog groupId runId contract metrics = do
  verification <- runTransaction (runVerificationsTx runId contract hooks)
  case verification of
    Left (verificationId, detail) -> do
      recordFailure runId "replay.verification-failure" detail Nothing (Just verificationId) Nothing
      Telemetry.recordProjectionRebuildFailures metrics 1
      pure (Left (CatalogRebuildVerificationFailed runId verificationId detail))
    Right () ->
      case groupRebuildHandleFor catalog groupId runId of
        Nothing -> pure (Left (CatalogRebuildGroupMissing groupId))
        Just handle -> do
          promoted <-
            runTransaction $ do
              complete <-
                Tx.statement
                  ( rebuildRunIdText runId,
                    contract,
                    Prelude.fromIntegral sourceCount,
                    Prelude.fromIntegral adapterCount,
                    Prelude.fromIntegral (Prelude.length hooks)
                  )
                  completionProofStmt
              if not complete
                then Tx.condemn >> pure (Left Nothing)
                else do
                  Tx.statement (rebuildRunIdText runId) markVerifiedStmt
                  transition <- finishGroupRebuildTx handle (completionTokenForHandle handle)
                  case transition of
                    Left err -> pure (Left (Just err))
                    Right _ -> do
                      Tx.statement (rebuildRunIdText runId) markPromotedStmt
                      pure (Right ())
          case promoted of
            Left Nothing -> do
              let detail = "source, adapter, or verification completion proof is incomplete"
              Telemetry.recordProjectionRebuildFailures metrics 1
              pure (Left (CatalogRebuildInvariantFailed runId detail))
            Left (Just err) -> pure (Left (CatalogRebuildPromotionFailed err))
            Right () -> do
              Telemetry.recordProjectionRebuildPromotions metrics 1
              inspectCatalogRebuild runId
  where
    hooks = catalogRebuildVerifications catalog groupId
    sourceCount = Prelude.length (sourceSpecs catalog groupId)
    adapterCount = Prelude.length (catalogReplayAdapters catalog groupId)

runVerificationsTx ::
  RebuildRunId ->
  Text ->
  [RebuildVerification] ->
  Tx.Transaction (Either (Text, Text) ())
runVerificationsTx runId contract hooks = do
  active <- Tx.statement (rebuildRunIdText runId, contract) lockActiveRunStmt
  if not active
    then pure (Left ("$runner", "rebuild run is no longer active"))
    else go hooks
  where
    go = \case
      [] -> pure (Right ())
      hook : rest -> do
        outcome <- hook ^. #verifyRebuild
        case outcome of
          Left detail -> do
            Tx.statement
              (rebuildRunIdText runId, hook ^. #verificationId, detail)
              failVerificationStmt
            pure (Left (hook ^. #verificationId, detail))
          Right () -> do
            Tx.statement
              (rebuildRunIdText runId, hook ^. #verificationId)
              passVerificationStmt
            go rest

recordFailure ::
  (Store :> es) =>
  RebuildRunId ->
  Text ->
  Text ->
  Maybe SourceId ->
  Maybe Text ->
  Maybe GlobalPosition ->
  Eff es ()
recordFailure runId code detail source projection position =
  runTransaction
    $ Tx.statement
      ( rebuildRunIdText runId,
        code,
        detail,
        sourceIdText <$> source,
        projection,
        globalPositionToInt <$> position
      )
      recordFailureStmt

initializeRunTx ::
  ValidatedProjectionCatalog ->
  RebuildGroupId ->
  RebuildOptions ->
  GlobalPosition ->
  Text ->
  Tx.Transaction ()
initializeRunTx catalog groupId options headPosition contract = do
  Tx.statement
    ( rebuildRunIdText runId,
      rebuildGroupIdText groupId,
      catalogFingerprintText (Catalog.catalogFingerprint catalog),
      groupSliceFingerprintText currentSlice,
      contract,
      runnerFormat,
      globalPositionToInt headPosition,
      options ^. #replayPageSize
    )
    insertRunStmt
  traverse_ insertSource (sourceSpecs catalog groupId)
  traverse_ insertAdapter (catalogReplayAdapters catalog groupId)
  traverse_ insertVerification (catalogRebuildVerifications catalog groupId)
  where
    request = options ^. #rebuildRequest
    runId = request ^. #rebuildRunId
    startCursor = globalPositionToInt (request ^. #replayFrom)
    target = globalPositionToInt headPosition
    currentSlice =
      fromMaybe
        (error "initializeRunTx: rebuild contract exists without a group slice")
        (Catalog.groupSliceFingerprint catalog groupId)

    insertSource source =
      let (scope, category) = encodeScope (source ^. #specScope)
       in Tx.statement
            (rebuildRunIdText runId, sourceIdText (source ^. #specSourceId), scope, category, startCursor, target)
            insertSourceStmt

    insertAdapter adapter =
      Tx.statement
        ( rebuildRunIdText runId,
          sourceIdText (catalogReplayAdapterSourceId adapter),
          projectionIdText (catalogReplayAdapterProjectionId adapter),
          Prelude.fromIntegral (catalogReplayAdapterOrder adapter)
        )
        insertAdapterStmt

    insertVerification hook =
      Tx.statement
        (rebuildRunIdText runId, hook ^. #verificationId, hook ^. #verificationVersion)
        insertVerificationStmt

sourceSpecs :: ValidatedProjectionCatalog -> RebuildGroupId -> [SourceSpec]
sourceSpecs catalog groupId =
  mapMaybe sourceFor orderedSourceIds
  where
    orderedSourceIds =
      List.nub
        [ catalogReplayAdapterSourceId adapter
        | adapter <- catalogReplayAdapters catalog groupId
        ]
    sourceFor wanted =
      listToMaybe
        [ SourceSpec
            { specSourceId = source ^. #sourceId,
              specScope = source ^. #sourceScope
            }
        | source <- catalogInventory catalog ^. #inventorySources,
          source ^. #sourceId == wanted
        ]

rebuildContract :: ValidatedProjectionCatalog -> RebuildGroupId -> Maybe Text
rebuildContract catalog groupId = do
  slice <- Catalog.groupSliceFingerprint catalog groupId
  pure
    ( hashPreimage
        "contract-v4"
        ( PRecord
            runnerFormat
            [ PText (groupSliceFingerprintText slice),
              PList
                [ PRecord
                    "adapter"
                    [ PText (sourceIdText (catalogReplayAdapterSourceId adapter)),
                      PText (projectionIdText (catalogReplayAdapterProjectionId adapter))
                    ]
                | adapter <- catalogReplayAdapters catalog groupId
                ]
            ]
        )
    )

encodeScope :: SourceScope -> (Text, Maybe Text)
encodeScope AllStreams = ("all", Nothing)
encodeScope (CategorySource (CategoryName category)) = ("category", Just category)

decodeScope :: Text -> Maybe Text -> SourceScope
decodeScope "all" _ = AllStreams
decodeScope "category" (Just category) = CategorySource (CategoryName category)
decodeScope raw _ = error ("invalid persisted rebuild source scope: " <> Text.unpack raw)

globalPositionToInt :: GlobalPosition -> Int64
globalPositionToInt (GlobalPosition position) = position

renderPosition :: GlobalPosition -> Text
renderPosition (GlobalPosition position) = Text.pack (show position)

runStatusFromText :: Text -> RebuildRunStatus
runStatusFromText = \case
  "running" -> RebuildRunRunning
  "failed" -> RebuildRunFailed
  "verified" -> RebuildRunVerified
  "promoted" -> RebuildRunPromoted
  raw -> UnknownRebuildRunStatus raw

decodeSourceId :: Text -> SourceId
decodeSourceId raw =
  either
    (const (error ("invalid persisted source id: " <> Text.unpack raw)))
    id
    (Catalog.mkSourceId raw)

decodeGroupId :: Text -> RebuildGroupId
decodeGroupId raw =
  either
    (const (error ("invalid persisted rebuild group id: " <> Text.unpack raw)))
    id
    (Catalog.mkRebuildGroupId raw)

decodeRunId :: Text -> RebuildRunId
decodeRunId raw =
  either
    (const (error ("invalid persisted rebuild run id: " <> Text.unpack raw)))
    id
    (mkRebuildRunId raw)

inspectRunStmt :: Statement Text (Maybe RebuildRunReport)
inspectRunStmt =
  preparable
    """
    SELECT run_id, group_id, catalog_fingerprint, group_slice_fingerprint,
           contract_fingerprint, runner_format, captured_head, page_size, status,
           failure_code, failure_detail, failure_source_id,
           failure_projection_id, failure_position
    FROM keiro.keiro_projection_rebuild_runs
    WHERE run_id = $1
    """
    (E.param (E.nonNullable E.text))
    (D.rowMaybe runReportDecoder)

runReportDecoder :: D.Row RebuildRunReport
runReportDecoder =
  makeReport
    <$> (decodeRunId <$> D.column (D.nonNullable D.text))
    <*> (decodeGroupId <$> D.column (D.nonNullable D.text))
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> (GlobalPosition <$> D.column (D.nonNullable D.int8))
    <*> D.column (D.nonNullable D.int4)
    <*> (runStatusFromText <$> D.column (D.nonNullable D.text))
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> (fmap decodeSourceId <$> D.column (D.nullable D.text))
    <*> D.column (D.nullable D.text)
    <*> (fmap GlobalPosition <$> D.column (D.nullable D.int8))
  where
    makeReport runId groupId fingerprint sliceFingerprint contract format headPosition pageSize status failureCode failureDetail failureSource failureProjection failurePosition =
      RebuildRunReport
        { rebuildRunId = runId,
          rebuildGroupId = groupId,
          catalogFingerprint = fingerprint,
          groupSliceFingerprint = sliceFingerprint,
          contractFingerprint = contract,
          runnerFormatVersion = format,
          capturedHead = headPosition,
          configuredPageSize = pageSize,
          runStatus = status,
          failureEvidence =
            RebuildFailureEvidence
              <$> failureCode
              <*> failureDetail
              <*> pure failureSource
              <*> pure failureProjection
              <*> pure failurePosition,
          sources = [],
          adapters = [],
          verifications = []
        }

inspectSourcesStmt :: Statement Text [RebuildSourceProgress]
inspectSourcesStmt =
  preparable
    """
    SELECT source_id, source_scope, category, cursor_position, target_position,
           exhausted_through, event_count
    FROM keiro.keiro_projection_rebuild_sources
    WHERE run_id = $1
    ORDER BY source_id
    """
    (E.param (E.nonNullable E.text))
    (D.rowList sourceProgressDecoder)

sourceProgressDecoder :: D.Row RebuildSourceProgress
sourceProgressDecoder =
  RebuildSourceProgress
    <$> (decodeSourceId <$> D.column (D.nonNullable D.text))
    <*> (decodeScope <$> D.column (D.nonNullable D.text) <*> D.column (D.nullable D.text))
    <*> (GlobalPosition <$> D.column (D.nonNullable D.int8))
    <*> (GlobalPosition <$> D.column (D.nonNullable D.int8))
    <*> (fmap GlobalPosition <$> D.column (D.nullable D.int8))
    <*> D.column (D.nonNullable D.int8)

inspectAdaptersStmt :: Statement Text [RebuildAdapterProgress]
inspectAdaptersStmt =
  preparable
    """
    SELECT source_id, projection_id, adapter_order, evaluation_count,
           apply_count, completed_through
    FROM keiro.keiro_projection_rebuild_adapters
    WHERE run_id = $1
    ORDER BY adapter_order
    """
    (E.param (E.nonNullable E.text))
    ( D.rowList
        ( RebuildAdapterProgress
            <$> (decodeSourceId <$> D.column (D.nonNullable D.text))
            <*> D.column (D.nonNullable D.text)
            <*> (Prelude.fromIntegral <$> D.column (D.nonNullable D.int4))
            <*> D.column (D.nonNullable D.int8)
            <*> D.column (D.nonNullable D.int8)
            <*> (fmap GlobalPosition <$> D.column (D.nullable D.int8))
        )
    )

inspectVerificationsStmt :: Statement Text [RebuildVerificationProgress]
inspectVerificationsStmt =
  preparable
    """
    SELECT verification_id, verification_version, status, detail
    FROM keiro.keiro_projection_rebuild_verifications
    WHERE run_id = $1
    ORDER BY verification_id
    """
    (E.param (E.nonNullable E.text))
    ( D.rowList
        ( RebuildVerificationProgress
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nullable D.text)
        )
    )

insertRunStmt :: Statement (Text, Text, Text, Text, Text, Text, Int64, Int32) ()
insertRunStmt =
  preparable
    """
    INSERT INTO keiro.keiro_projection_rebuild_runs
      (run_id, group_id, catalog_fingerprint, group_slice_fingerprint,
       contract_fingerprint, runner_format, captured_head, page_size, status)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'running')
    """
    ( contrazip8
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.int4))
    )
    D.noResult

insertSourceStmt :: Statement (Text, Text, Text, Maybe Text, Int64, Int64) ()
insertSourceStmt =
  preparable
    """
    INSERT INTO keiro.keiro_projection_rebuild_sources
      (run_id, source_id, source_scope, category, cursor_position, target_position)
    VALUES ($1, $2, $3, $4, $5, $6)
    """
    ( contrazip6
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nullable E.text))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.int8))
    )
    D.noResult

insertAdapterStmt :: Statement (Text, Text, Text, Int32) ()
insertAdapterStmt =
  preparable
    """
    INSERT INTO keiro.keiro_projection_rebuild_adapters
      (run_id, source_id, projection_id, adapter_order)
    VALUES ($1, $2, $3, $4)
    """
    ( contrazip4
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int4))
    )
    D.noResult

insertVerificationStmt :: Statement (Text, Text, Text) ()
insertVerificationStmt =
  preparable
    """
    INSERT INTO keiro.keiro_projection_rebuild_verifications
      (run_id, verification_id, verification_version)
    VALUES ($1, $2, $3)
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    D.noResult

resumeRunTx :: RebuildRunId -> Int32 -> Text -> Tx.Transaction Bool
resumeRunTx runId pageSize contract = do
  updated <- Tx.statement (rebuildRunIdText runId, contract, pageSize) resumeRunStmt
  pure (updated == Just contract)

resumeRunStmt :: Statement (Text, Text, Int32) (Maybe Text)
resumeRunStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_runs AS runs
    SET status = 'running', page_size = $3, failed_at = NULL,
        failure_code = NULL, failure_detail = NULL, failure_source_id = NULL,
        failure_projection_id = NULL, failure_position = NULL, updated_at = now()
    FROM keiro.keiro_projection_rebuild_groups AS groups
    WHERE runs.run_id = $1
      AND runs.contract_fingerprint = $2
      AND runs.status IN ('running', 'failed')
      AND groups.group_id = runs.group_id
      AND groups.status = 'rebuilding'
      AND groups.active_run_id = runs.run_id
      AND groups.slice_fingerprint = runs.group_slice_fingerprint
    RETURNING runs.contract_fingerprint
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int4))
    )
    (D.rowMaybe (D.column (D.nonNullable D.text)))

lockActiveRunStmt :: Statement (Text, Text) Bool
lockActiveRunStmt =
  preparable
    """
    SELECT runs.run_id
    FROM keiro.keiro_projection_rebuild_runs AS runs
    JOIN keiro.keiro_projection_rebuild_groups AS groups
      ON groups.group_id = runs.group_id
    WHERE runs.run_id = $1
      AND runs.contract_fingerprint = $2
      AND runs.status = 'running'
      AND groups.status = 'rebuilding'
      AND groups.active_run_id = runs.run_id
      AND groups.slice_fingerprint = runs.group_slice_fingerprint
    FOR UPDATE OF runs, groups
    """
    (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.text)))
    (isJust <$> D.rowMaybe (D.column (D.nonNullable D.text)))

advanceSourceStmt :: Statement (Text, Text, Int64, Int64, Int64) Bool
advanceSourceStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_sources
    SET cursor_position = $4,
        event_count = event_count + $5,
        updated_at = now()
    WHERE run_id = $1 AND source_id = $2 AND cursor_position = $3
    RETURNING source_id
    """
    ( contrazip5
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.int8))
    )
    (isJust <$> D.rowMaybe (D.column (D.nonNullable D.text)))

advanceAdapterStmt :: Statement (Text, Text, Text, Int64, Int64) ()
advanceAdapterStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_adapters
    SET evaluation_count = evaluation_count + $4,
        apply_count = apply_count + $5,
        updated_at = now()
    WHERE run_id = $1 AND source_id = $2 AND projection_id = $3
    """
    ( contrazip5
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.int8))
    )
    D.noResult

completeSourceStmt :: Statement (Text, Text, Int64) ()
completeSourceStmt =
  preparable
    """
    WITH completed_source AS (
      UPDATE keiro.keiro_projection_rebuild_sources
      SET exhausted_through = target_position, updated_at = now()
      WHERE run_id = $1 AND source_id = $2 AND target_position = $3
      RETURNING run_id, source_id, target_position
    )
    UPDATE keiro.keiro_projection_rebuild_adapters AS adapters
    SET completed_through = completed_source.target_position, updated_at = now()
    FROM completed_source
    WHERE adapters.run_id = completed_source.run_id
      AND adapters.source_id = completed_source.source_id
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
    )
    D.noResult

passVerificationStmt :: Statement (Text, Text) ()
passVerificationStmt =
  verificationResultStmt "passed"

failVerificationStmt :: Statement (Text, Text, Text) ()
failVerificationStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_verifications
    SET status = 'failed', detail = $3, completed_at = now()
    WHERE run_id = $1 AND verification_id = $2
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    D.noResult

verificationResultStmt :: Text -> Statement (Text, Text) ()
verificationResultStmt status =
  preparable
    ( "UPDATE keiro.keiro_projection_rebuild_verifications "
        <> "SET status = '"
        <> status
        <> "', detail = NULL, completed_at = now() "
        <> "WHERE run_id = $1 AND verification_id = $2"
    )
    (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.text)))
    D.noResult

recordFailureStmt :: Statement (Text, Text, Text, Maybe Text, Maybe Text, Maybe Int64) ()
recordFailureStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_runs
    SET status = 'failed', failed_at = now(), failure_code = $2,
        failure_detail = $3, failure_source_id = $4,
        failure_projection_id = $5, failure_position = $6, updated_at = now()
    WHERE run_id = $1 AND status IN ('running', 'failed')
    """
    ( contrazip6
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nullable E.text))
        (E.param (E.nullable E.text))
        (E.param (E.nullable E.int8))
    )
    D.noResult

completionProofStmt :: Statement (Text, Text, Int64, Int64, Int64) Bool
completionProofStmt =
  preparable
    """
    SELECT
      runs.status = 'running'
      AND groups.status = 'rebuilding'
      AND groups.active_run_id = runs.run_id
      AND groups.slice_fingerprint = runs.group_slice_fingerprint
      AND (SELECT count(*) FROM keiro.keiro_projection_rebuild_sources sources
           WHERE sources.run_id = runs.run_id) = $3
      AND NOT EXISTS (
        SELECT 1 FROM keiro.keiro_projection_rebuild_sources sources
        WHERE sources.run_id = runs.run_id
          AND sources.exhausted_through IS DISTINCT FROM runs.captured_head
      )
      AND (SELECT count(*) FROM keiro.keiro_projection_rebuild_adapters adapters
           WHERE adapters.run_id = runs.run_id) = $4
      AND NOT EXISTS (
        SELECT 1 FROM keiro.keiro_projection_rebuild_adapters adapters
        WHERE adapters.run_id = runs.run_id
          AND adapters.completed_through IS DISTINCT FROM runs.captured_head
      )
      AND (SELECT count(*) FROM keiro.keiro_projection_rebuild_verifications verifications
           WHERE verifications.run_id = runs.run_id) = $5
      AND NOT EXISTS (
        SELECT 1 FROM keiro.keiro_projection_rebuild_verifications verifications
        WHERE verifications.run_id = runs.run_id AND verifications.status <> 'passed'
      )
    FROM keiro.keiro_projection_rebuild_runs runs
    JOIN keiro.keiro_projection_rebuild_groups groups ON groups.group_id = runs.group_id
    WHERE runs.run_id = $1 AND runs.contract_fingerprint = $2
    FOR UPDATE OF runs, groups
    """
    ( contrazip5
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.int8))
    )
    (fromMaybe False <$> D.rowMaybe (D.column (D.nonNullable D.bool)))

markVerifiedStmt :: Statement Text ()
markVerifiedStmt =
  statusUpdateStmt "verified" "verified_at"

markPromotedStmt :: Statement Text ()
markPromotedStmt =
  statusUpdateStmt "promoted" "promoted_at"

statusUpdateStmt :: Text -> Text -> Statement Text ()
statusUpdateStmt status timestampColumn =
  preparable
    ( "UPDATE keiro.keiro_projection_rebuild_runs SET status = '"
        <> status
        <> "', "
        <> timestampColumn
        <> " = now(), updated_at = now() WHERE run_id = $1"
    )
    (E.param (E.nonNullable E.text))
    D.noResult
