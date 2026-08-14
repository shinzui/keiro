{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}

module ReadModelBench
  ( ReadModelBenchFixture,
    readModelBenchmarks,
    runReadModelExplainEvidenceIfRequested,
    runReadModelLatencyEvidenceIfRequested,
    setupReadModelBench,
  )
where

import Control.Monad (forM, replicateM_)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.Foldable (toList)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Time (UTCTime (..), secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Data.Word (Word64)
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiki.Core
  ( Edge (..),
    HsPred,
    InCtor,
    RegFile (..),
    SymTransducer (..),
    Update (..),
    WireCtor,
    matchInCtor,
    oNil,
    pack,
    unavailableInCtor,
    unavailableWireCtor,
  )
import Keiki.Core qualified as Keiki
import Keiro
import Keiro.Connection (qualifyTable)
import Keiro.Prelude
import Keiro.Projection
  ( AsyncProjection (..),
    CatalogAsyncApplyOutcome (..),
    InlineProjection (..),
    ProjectionCommandOutcome (..),
    applyAsyncProjectionFromCatalog,
    runCommandWithCatalogProjections,
  )
import Keiro.ReadModel
  ( QueryCursorAuthority (NoQueryCursor),
    ReadModelBlueprint (..),
    immediateReadModel,
  )
import Keiro.ReadModel.External (reconcileExternalReadContracts)
import Keiro.ReadModel.Rebuild
  ( RebuildRunId,
    StreamReprojectionRequest (..),
    VersionedRebuildPhase (..),
    VersionedRebuildRequest (..),
    VersionedTargetMode (..),
    beginVersionedRebuild,
    listProjectionGroupStatuses,
    lookupProjectionGroupStatus,
    mkRebuildRunId,
    rebuildRunIdText,
    registerProjectionCatalog,
    reprojectStream,
    resumeVersionedRebuild,
  )
import Keiro.Stream qualified as Keiro.Stream
import Keiro.Test.Postgres (StoreRunner (..))
import Kiroku.Store qualified as Store
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.HistoryRetention
  ( HistoryRetentionLeaseRequest (..),
    mkHistoryRetentionLeaseDuration,
    mkHistoryRetentionLeaseOwner,
    mkHistoryRetentionLeaseReason,
  )
import Kiroku.Store.Subscription.Types (MissingCheckpointPolicy (FromBeginning))
import Kiroku.Store.Types
  ( CategoryName (..),
    EventData (..),
    EventId (..),
    ExpectedVersion (..),
    GlobalPosition (..),
    RecordedEvent (..),
    StreamId (..),
    StreamName (..),
    StreamVersion (..),
  )
import System.Environment (lookupEnv)
import Test.Tasty.Bench (Benchmark, bcompareWithin, bench, bgroup, nfIO)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude

data ProjectionBenchCommand = EmitProjection
  deriving stock (Eq, Show)

data ProjectionBenchEvent = ProjectionBenchEvent
  deriving stock (Eq, Show)

data ProjectionBenchState = ProjectionBenchReady
  deriving stock (Bounded, Enum, Eq, Ord, Show)

type ProjectionBenchEventStream = EventStream (HsPred '[] ProjectionBenchCommand) '[] ProjectionBenchState ProjectionBenchCommand ProjectionBenchEvent

type ValidatedProjectionBenchEventStream = ValidatedEventStream (HsPred '[] ProjectionBenchCommand) '[] ProjectionBenchState ProjectionBenchCommand ProjectionBenchEvent

data ScenarioGroup = ScenarioGroup
  { groupId :: !RebuildGroupId,
    targets :: ![(TargetId, QualifiedTable)],
    revisions :: ![ProjectionRevision]
  }

data ProjectionScenario = ProjectionScenario
  { key :: !Text,
    sourceDeclaration :: !SourceDeclaration,
    targetDeclarations :: ![TargetDeclaration],
    groupDeclarations :: ![RebuildGroupDeclaration],
    projectionSet :: !(ProjectionSet ProjectionBenchEvent),
    subscriptions :: ![SubscriptionDeclaration],
    dedupKeys :: ![DedupKeyDeclaration],
    scenarioGroups :: ![ScenarioGroup],
    asyncDelivery :: !(Maybe (ProjectionId, AsyncProjection)),
    versionManaged :: !Bool
  }

data ReadModelBenchFixture = ReadModelBenchFixture
  { store :: !Store.KirokuStore,
    runner :: !StoreRunner,
    catalog :: !ValidatedProjectionCatalog,
    scenarios :: !(Map.Map Text ProjectionScenario),
    commandCounter :: !(IORef Int64),
    asyncCounter :: !(IORef Int64),
    runCounter :: !(IORef Int64),
    promotionRevision :: !(IORef Bool)
  }

scenarioDefinitions :: [ProjectionScenario]
scenarioDefinitions =
  [ mkInlineScenario "bench-legacy-one" False [1] 0,
    mkInlineScenario "bench-versioned-one" True [1] 0,
    mkInlineScenario "bench-legacy-three" False [3] 0,
    mkInlineScenario "bench-versioned-three" True [3] 0,
    mkInlineScenario "bench-legacy-groups" False [1, 1, 1] 0,
    mkInlineScenario "bench-versioned-groups" True [1, 1, 1] 0,
    mkInlineScenario "bench-legacy-many-revisions" False [1] 0,
    mkInlineScenario "bench-versioned-many-revisions" True [1] 30,
    mkMixedScenario "bench-legacy-mixed" False,
    mkMixedScenario "bench-versioned-mixed" True,
    mkInlineScenario "bench-versioned-allrows" True [1] 0,
    mkInlineScenario "bench-versioned-keyed" True [1] 0,
    mkRepairScenario
  ]

setupReadModelBench :: Store.KirokuStore -> StoreRunner -> IO ReadModelBenchFixture
setupReadModelBench store runner = do
  runStoreChecked store (Store.runTransaction setupTables)
  catalog <-
    case validateProjectionCatalog projectionBenchCatalog of
      Failure diagnostics -> fail ("invalid read-model benchmark catalog: " <> show diagnostics)
      Success value -> pure value
  registration <- runStoreChecked store (registerProjectionCatalog catalog)
  case registration of
    Left err -> fail ("read-model benchmark catalog registration failed: " <> show err)
    Right _ -> pure ()
  runStoreChecked store (Store.runTransaction (bootstrapVersionedGroups scenarioDefinitions))
  reconciliation <- runStoreChecked store (reconcileExternalReadContracts catalog)
  case reconciliation of
    Left err -> fail ("read-model benchmark external contract reconciliation failed: " <> show err)
    Right () -> pure ()
  runStoreChecked store (Store.runTransaction seedStatusScale)
  seedStabilizingHistory store
  seedRepairStreams store
  commandCounter <- newIORef 0
  asyncCounter <- newIORef 0
  runCounter <- newIORef 0
  promotionRevision <- newIORef False
  pure
    ReadModelBenchFixture
      { store,
        runner,
        catalog,
        scenarios = Map.fromList [(scenario.key, scenario) | scenario <- scenarioDefinitions],
        commandCounter,
        asyncCounter,
        runCounter,
        promotionRevision
      }

readModelBenchmarks :: ReadModelBenchFixture -> [Benchmark]
readModelBenchmarks fixture =
  [ bgroup
      "projection"
      [ bgroup
          "inline"
          [ bgroup
              "legacy"
              [ inlineScenarioBench fixture "one-target" "bench-legacy-one",
                inlineScenarioBench fixture "three-target" "bench-legacy-three",
                inlineScenarioBench fixture "three-groups" "bench-legacy-groups",
                inlineScenarioBench fixture "many-revisions" "bench-legacy-many-revisions",
                inlineScenarioBench fixture "mixed-delivery" "bench-legacy-mixed"
              ],
            bgroup
              "versioned"
              [ comparedInline "one-target" "bench-versioned-one",
                comparedInline "three-target" "bench-versioned-three",
                comparedInline "three-groups" "bench-versioned-groups",
                comparedInline "many-revisions" "bench-versioned-many-revisions",
                comparedInline "mixed-delivery" "bench-versioned-mixed"
              ]
          ],
        bgroup
          "async"
          [ bgroup "legacy" [asyncScenarioBench fixture "mixed-delivery" "bench-legacy-mixed"],
            bgroup
              "versioned"
              [ bcompareWithin 0 projectionDiagnosticTimeBudget asyncLegacyPattern $
                  asyncScenarioBench fixture "mixed-delivery" "bench-versioned-mixed"
              ]
          ]
      ],
    bgroup
      "read-model-lifecycle"
      [ bgroup
          "serving-binding"
          [ bench "legacy-three" (nfIO (runServingBindingLookup fixture "bench-legacy-three")),
            bench "versioned-three" (nfIO (runServingBindingLookup fixture "bench-versioned-three"))
          ],
        bgroup
          "promotion"
          [bench "three-target-end-to-end" (nfIO (runPromotionScenario fixture))],
        bgroup
          "repair"
          [ repairScenarioBench fixture eventCount
          | eventCount <- repairEventCounts
          ]
      ],
    bgroup
      "read-model-reads"
      [ bgroup
          "status"
          [ bench "list-1000-synthetic-groups" (nfIO (runStatusList fixture)),
            bench "lookup-among-1000-synthetic-groups" (nfIO (runStatusLookup fixture))
          ],
        bgroup
          "guarded"
          [ bench "all-rows-100" (nfIO (runGuardedAllRows fixture)),
            bench "keyed-10000" (nfIO (runGuardedKeyed fixture))
          ]
      ]
  ]
  where
    comparedInline benchmarkName scenarioKey =
      bcompareWithin 0 projectionDiagnosticTimeBudget (inlineLegacyPattern benchmarkName) $
        inlineScenarioBench fixture benchmarkName scenarioKey

runServingBindingLookup :: ReadModelBenchFixture -> Text -> IO Int
runServingBindingLookup fixture scenarioKey = do
  scenario <- requireScenario fixture scenarioKey
  let groupId = (firstOrError "binding benchmark scenario group" scenario.scenarioGroups).groupId
  row <-
    runStoreChecked fixture.store $
      Store.runTransaction $
        Tx.statement (rebuildGroupIdText groupId) servingBindingStatement
  pure (maybe 0 (\(_, _, _, _, bindings) -> length bindings) row)

runStatusList :: ReadModelBenchFixture -> IO Int
runStatusList fixture =
  length <$> runStoreChecked fixture.store listProjectionGroupStatuses

runStatusLookup :: ReadModelBenchFixture -> IO Bool
runStatusLookup fixture =
  isJust
    <$> runStoreChecked
      fixture.store
      (lookupProjectionGroupStatus (identity mkRebuildGroupId "bench-status-1000"))

runGuardedAllRows :: ReadModelBenchFixture -> IO Int
runGuardedAllRows fixture = do
  rows <-
    runStoreChecked
      fixture.store
      (Store.runTransaction (Tx.statement () guardedAllRowsStatement))
  unless (length rows == 100) $
    fail ("guarded all-row benchmark fixture drifted: " <> show (length rows))
  pure (length rows)

runGuardedKeyed :: ReadModelBenchFixture -> IO Int
runGuardedKeyed fixture = do
  rows <-
    runStoreChecked
      fixture.store
      (Store.runTransaction (Tx.statement 5_000 guardedKeyedStatement))
  unless (rows == [(5_000, 50_000)]) $
    fail ("guarded keyed benchmark fixture drifted: " <> show rows)
  pure (length rows)

-- Sequential tasty-bench cases share and grow one event store, so this is a
-- broad diagnostic tripwire. The warmed, alternating sampler below owns the
-- release requirement: >=90% throughput and <=1.25x p95 for three targets.
projectionDiagnosticTimeBudget :: Double
projectionDiagnosticTimeBudget = 2

inlineLegacyPattern :: String -> String
inlineLegacyPattern benchmarkName =
  "$NF == \""
    <> benchmarkName
    <> "\" && $(NF-1) == \"legacy\" && $(NF-2) == \"inline\" && $(NF-3) == \"projection\""

asyncLegacyPattern :: String
asyncLegacyPattern =
  "$NF == \"mixed-delivery\" && $(NF-1) == \"legacy\" && $(NF-2) == \"async\" && $(NF-3) == \"projection\""

inlineScenarioBench :: ReadModelBenchFixture -> String -> Text -> Benchmark
inlineScenarioBench fixture benchmarkName scenarioKey =
  bench benchmarkName $ nfIO (runInlineScenario fixture scenarioKey)

runInlineScenario :: ReadModelBenchFixture -> Text -> IO ()
runInlineScenario fixture scenarioKey = do
  scenario <- requireScenario fixture scenarioKey
  invocation <- nextCounter fixture.commandCounter
  let target = stream ("bench-projection-command-" <> scenarioKey <> "-" <> Text.pack (show invocation))
  result <-
    runResourceStoreChecked fixture.runner $
      runCommandWithCatalogProjections
        defaultRunCommandOptions
        projectionBenchEventStream
        target
        EmitProjection
        fixture.catalog
        scenario.projectionSet
  case result of
    Right ProjectionCommandApplied {} -> pure ()
    other -> fail ("unexpected inline projection benchmark result: " <> show other)

asyncScenarioBench :: ReadModelBenchFixture -> String -> Text -> Benchmark
asyncScenarioBench fixture benchmarkName scenarioKey =
  bench benchmarkName $ nfIO (runAsyncScenario fixture scenarioKey)

runAsyncScenario :: ReadModelBenchFixture -> Text -> IO ()
runAsyncScenario fixture scenarioKey = do
  scenario <- requireScenario fixture scenarioKey
  (projectionId, projection) <-
    maybe (fail ("scenario has no async delivery: " <> Text.unpack scenarioKey)) pure scenario.asyncDelivery
  invocation <- nextCounter fixture.asyncCounter
  outcome <-
    runStoreChecked fixture.store $
      Store.runTransaction
        ( applyAsyncProjectionFromCatalog
            fixture.catalog
            projectionId
            projection
            (syntheticRecordedEvent invocation)
        )
  case outcome of
    CatalogAsyncApplied -> pure ()
    other -> fail ("unexpected async projection benchmark result: " <> show other)

repairEventCounts :: [Int]
repairEventCounts = [10, 100, 1000]

repairScenarioBench :: ReadModelBenchFixture -> Int -> Benchmark
repairScenarioBench fixture eventCount =
  bench (show eventCount) $ nfIO $ do
    scenario <- requireScenario fixture "benchrepair"
    let projectionId = identity mkProjectionId "benchrepair-g1-inline"
        request =
          StreamReprojectionRequest
            { rebuildGroupId = (firstOrError "repair scenario group" scenario.scenarioGroups).groupId,
              projectionId,
              streamName = repairStreamName eventCount,
              pageSize = 64
            }
    runStoreChecked fixture.store (reprojectStream fixture.catalog request) >>= \case
      Right report
        | report ^. #replayedEvents == fromIntegral eventCount -> pure ()
      other -> fail ("unexpected targeted repair benchmark result: " <> show other)

runPromotionScenario :: ReadModelBenchFixture -> IO ()
runPromotionScenario fixture = do
  scenario <- requireScenario fixture "bench-versioned-three"
  runNumber <- nextCounter fixture.runCounter
  promoteToV1 <- atomicModifyIORef' fixture.promotionRevision (\current -> (not current, current))
  let group = firstOrError "promotion scenario group" scenario.scenarioGroups
      revisionIds = map (^. #revisionId) group.revisions
      (servingRevisionId, candidateRevisionId) =
        if promoteToV1
          then (revisionIds !! 1, revisionIds !! 0)
          else (revisionIds !! 0, revisionIds !! 1)
      runId = identity mkRebuildRunId ("bench-promotion-" <> Text.pack (show runNumber))
      request =
        VersionedRebuildRequest
          { rebuildRunId = runId,
            rebuildGroupId = group.groupId,
            servingRevisionId,
            candidateRevisionId,
            servingTargets = physicalTargetsFor group.targets,
            targetMode = ApplicationProvisioned,
            replayPageSize = 128,
            cutoverThreshold = 0,
            cutoverLockTimeoutMs = 2_000,
            promotionDedupLimit = 10_000,
            retentionLeaseRequest = retentionRequest runId,
            requestedBy = "keiro-bench",
            requestReason = "measure schema-versioned promotion"
          }
  runStoreChecked fixture.store (beginVersionedRebuild fixture.catalog request) >>= \case
    Left err -> fail ("promotion benchmark begin failed: " <> show err)
    Right _ -> drivePromotion 20 runId
  where
    drivePromotion :: Int -> RebuildRunId -> IO ()
    drivePromotion 0 runId = fail ("promotion benchmark exceeded resume cap: " <> show runId)
    drivePromotion remaining runId = do
      runStoreChecked fixture.store (resumeVersionedRebuild fixture.catalog runId) >>= \case
        Left err -> fail ("promotion benchmark resume failed: " <> show err)
        Right report
          | report ^. #phase == VersionedPromoted -> pure ()
          | otherwise -> drivePromotion (remaining - 1) runId

runReadModelLatencyEvidenceIfRequested :: ReadModelBenchFixture -> IO ()
runReadModelLatencyEvidenceIfRequested fixture =
  lookupEnv "KEIRO_READ_MODEL_P95" >>= \case
    Nothing -> pure ()
    Just _ -> do
      replicateM_ latencyWarmupCount $ do
        runInlineScenario fixture "bench-legacy-three"
        runInlineScenario fixture "bench-versioned-three"
      runs <- forM [1 .. latencyRunCount] $ \runNumber -> do
        (legacy, versioned) <-
          samplePairedLatency
            latencySampleCount
            (runInlineScenario fixture "bench-legacy-three")
            (runInlineScenario fixture "bench-versioned-three")
        let legacyP95 = percentile95 legacy
            versionedP95 = percentile95 versioned
            p95Ratio = fromIntegral versionedP95 / fromIntegral legacyP95 :: Double
            timeRatio = fromIntegral (sum versioned) / fromIntegral (sum legacy) :: Double
            throughputRatio = 1 / timeRatio
        putStrLn
          ( "read-model-latency-run="
              <> show runNumber
              <> " samples="
              <> show latencySampleCount
              <> " legacy_p95_ns="
              <> show legacyP95
              <> " versioned_p95_ns="
              <> show versionedP95
              <> " p95_ratio="
              <> show p95Ratio
              <> " throughput_ratio="
              <> show throughputRatio
          )
        pure (p95Ratio, throughputRatio)
      let medianP95Ratio = median (map fst runs)
          medianThroughputRatio = median (map snd runs)
      putStrLn
        ( "read-model-latency-median runs="
            <> show latencyRunCount
            <> " samples_per_run="
            <> show latencySampleCount
            <> " p95_ratio="
            <> show medianP95Ratio
            <> " p95_budget=1.25 throughput_ratio="
            <> show medianThroughputRatio
            <> " throughput_budget=0.90"
        )
      when (medianP95Ratio > 1.25) $
        fail ("versioned three-target median p95 exceeded 1.25x legacy: " <> show medianP95Ratio)
      when (medianThroughputRatio < 0.90) $
        fail ("versioned three-target median throughput fell below 90% of legacy: " <> show medianThroughputRatio)

runReadModelExplainEvidenceIfRequested :: ReadModelBenchFixture -> IO ()
runReadModelExplainEvidenceIfRequested fixture =
  lookupEnv "KEIRO_READ_MODEL_EXPLAIN" >>= \case
    Nothing -> pure ()
    Just _ -> do
      for_ ["bench-legacy-three", "bench-versioned-three"] $ \scenarioKey -> do
        scenario <- requireScenario fixture scenarioKey
        let groupId = (firstOrError "explain scenario group" scenario.scenarioGroups).groupId
        plan <-
          runStoreChecked fixture.store $
            Store.runTransaction $
              Tx.statement (rebuildGroupIdText groupId) explainServingBindingStatement
        putStrLn ("read-model-serving-binding-plan-json scenario=" <> Text.unpack scenarioKey <> " groups=1")
        print plan
      statusListPlan <- runStoreChecked fixture.store (Store.runTransaction (Tx.statement () explainStatusListStatement))
      putStrLn "read-model-status-list-plan-json synthetic_groups=1000"
      print statusListPlan
      statusLookupPlan <- runStoreChecked fixture.store (Store.runTransaction (Tx.statement () explainStatusLookupStatement))
      putStrLn "read-model-status-lookup-plan-json synthetic_groups=1000"
      print statusLookupPlan
      allRowsPlan <- runStoreChecked fixture.store (Store.runTransaction (Tx.statement () explainGuardedAllRowsStatement))
      putStrLn "read-model-guarded-all-rows-plan-json rows=100"
      print allRowsPlan
      keyedPlan <- runStoreChecked fixture.store (Store.runTransaction (Tx.statement () explainGuardedKeyedStatement))
      putStrLn "read-model-guarded-keyed-wrapper-plan-json rows=10000 requested_id=5000"
      print keyedPlan
      keyedIndexPlan <- runStoreChecked fixture.store (Store.runTransaction (Tx.statement () explainKeyedIndexStatement))
      putStrLn "read-model-guarded-keyed-index-plan-json rows=10000 requested_id=5000"
      print keyedIndexPlan

latencySampleCount :: Int
latencySampleCount = 500

latencyRunCount :: Int
latencyRunCount = 5

latencyWarmupCount :: Int
latencyWarmupCount = 25

sampleOneLatency :: IO () -> IO Word64
sampleOneLatency action = do
  started <- getMonotonicTimeNSec
  action
  finished <- getMonotonicTimeNSec
  pure (finished - started)

samplePairedLatency :: Int -> IO () -> IO () -> IO ([Word64], [Word64])
samplePairedLatency count legacyAction versionedAction = do
  pairs <- forM [0 .. count - 1] $ \sampleIndex ->
    if even sampleIndex
      then do
        legacy <- sampleOneLatency legacyAction
        versioned <- sampleOneLatency versionedAction
        pure (legacy, versioned)
      else do
        versioned <- sampleOneLatency versionedAction
        legacy <- sampleOneLatency legacyAction
        pure (legacy, versioned)
  pure (map fst pairs, map snd pairs)

percentile95 :: [Word64] -> Word64
percentile95 samples =
  sorted !! max 0 (ceiling (0.95 * fromIntegral (length sorted) :: Double) - 1)
  where
    sorted = List.sort samples

median :: (Ord value) => [value] -> value
median values =
  sorted !! (length sorted `div` 2)
  where
    sorted = List.sort values

projectionBenchCatalog :: ProjectionCatalog
projectionBenchCatalog =
  ProjectionCatalog
    { sources = map (\scenario -> scenario.sourceDeclaration) scenarioDefinitions,
      targets = concatMap (\scenario -> scenario.targetDeclarations) scenarioDefinitions,
      rebuildGroups = concatMap (\scenario -> scenario.groupDeclarations) scenarioDefinitions,
      projectionRevisions = concatMap (concatMap (\group -> group.revisions) . (\scenario -> scenario.scenarioGroups)) scenarioDefinitions,
      externalReadContracts = benchmarkExternalReadContracts,
      subscriptions = concatMap (\scenario -> scenario.subscriptions) scenarioDefinitions,
      dedupKeys = concatMap (\scenario -> scenario.dedupKeys) scenarioDefinitions,
      queryModels = concatMap scenarioQueryModels scenarioDefinitions,
      projectionSets = SomeProjectionSet . (\scenario -> scenario.projectionSet) <$> scenarioDefinitions
    }

scenarioQueryModels :: ProjectionScenario -> [SomeQueryModelBinding]
scenarioQueryModels scenario =
  asyncModels <> externalModels
  where
    asyncModels = case scenario.asyncDelivery of
      Nothing -> []
      Just (_, projection) ->
        let group = firstOrError "async query-model group" scenario.scenarioGroups
            (targetId, table) = lastOrError "async query-model target" group.targets
         in [queryModelBinding scenario group targetId table (scenario.key <> "-async-query") (projection ^. #readModelName) (scenario.key <> "-async-query-v1")]
    externalModels
      | scenario.key == "bench-versioned-allrows" =
          [externalBinding "bench-all-rows-query" "bench-all-rows-model" "bench-all-rows-v1"]
      | scenario.key == "bench-versioned-keyed" =
          [externalBinding "bench-keyed-query" "bench-keyed-model" "bench-keyed-v1"]
      | otherwise = []
    externalBinding queryId registryName shapeHash =
      let group = firstOrError "external query-model group" scenario.scenarioGroups
          (targetId, table) = firstOrError "external query-model target" group.targets
       in queryModelBinding scenario group targetId table queryId registryName shapeHash

queryModelBinding :: ProjectionScenario -> ScenarioGroup -> TargetId -> QualifiedTable -> Text -> Text -> Text -> SomeQueryModelBinding
queryModelBinding scenario group targetId table queryId registryName shapeHash =
  SomeQueryModelBinding
    QueryModelBinding
      { queryModelId = identity mkQueryModelId queryId,
        readModel = model,
        rebuildGroup = group.groupId,
        observedTargets = [targetId],
        claimSite = claim (scenario.key <> ":query:" <> queryId)
      }
  where
    model =
      immediateReadModel
        ReadModelBlueprint
          { name = registryName,
            tableName = table ^. #tableName,
            schema = table ^. #schemaName,
            version = 1,
            shapeHash,
            cursorAuthority = NoQueryCursor,
            query = \() -> pure ()
          }

benchmarkExternalReadContracts :: [ExternalReadContract]
benchmarkExternalReadContracts =
  [ AllRowsExternalRead
      { readContractId = identity mkExternalReadContractId "bench_all_rows",
        contractVersion = ExternalReadContractVersion 1,
        queryModelId = identity mkQueryModelId "bench-all-rows-query",
        resultContractType = QualifiedSqlType "app_contract" "bench_all_row_v1",
        resultShapeHash = "bench-all-rows-v1",
        compatibleRevisions =
          identity mkProjectionRevisionId "bench-versioned-allrows-g1-r0"
            :| [identity mkProjectionRevisionId "bench-versioned-allrows-g1-r1"],
        surfaceGeneration = 1,
        claimSite = claim "bench:external:all-rows"
      },
    KeyedExternalRead
      { readContractId = identity mkExternalReadContractId "bench_keyed",
        contractVersion = ExternalReadContractVersion 1,
        queryModelId = identity mkQueryModelId "bench-keyed-query",
        arguments = [SqlFunctionArgument "requested_id" (QualifiedSqlType "pg_catalog" "int8")],
        resultContractType = QualifiedSqlType "app_contract" "bench_keyed_row_v1",
        privateImplementation = QualifiedFunction "app_private" "bench_keyed_lookup",
        privateImplementationVersion = 1,
        resultShapeHash = "bench-keyed-v1",
        compatibleRevisions =
          identity mkProjectionRevisionId "bench-versioned-keyed-g1-r0"
            :| [identity mkProjectionRevisionId "bench-versioned-keyed-g1-r1"],
        surfaceGeneration = 1,
        claimSite = claim "bench:external:keyed"
      }
  ]

mkInlineScenario :: Text -> Bool -> [Int] -> Int -> ProjectionScenario
mkInlineScenario key versionManaged targetCounts extraRevisions =
  scenarioFrom key versionManaged extraRevisions False targetCounts Nothing

mkMixedScenario :: Text -> Bool -> ProjectionScenario
mkMixedScenario key versionManaged =
  scenarioFrom key versionManaged 0 True [3] Nothing

mkRepairScenario :: ProjectionScenario
mkRepairScenario =
  scenarioFrom "benchrepair" True 0 False [1] (Just repairPolicy)

scenarioFrom :: Text -> Bool -> Int -> Bool -> [Int] -> Maybe (TargetId -> StreamScopedReplay) -> ProjectionScenario
scenarioFrom key versionManaged extraRevisions mixed targetCounts streamPolicy =
  ProjectionScenario
    { key,
      sourceDeclaration =
        SourceDeclaration
          { sourceId,
            sourceScope = CategorySource (CategoryName key),
            codecFingerprint = key <> "-codec-v1",
            claimSite = claim (key <> ":source")
          },
      targetDeclarations = targetDeclarations,
      groupDeclarations = groupDeclarations,
      projectionSet =
        ProjectionSet
          { projectionSource = sourceId,
            projectionDefinitions = nonEmptyOrError "scenario definitions" definitions,
            claimSite = claim (key <> ":set")
          },
      subscriptions = asyncSubscriptions,
      dedupKeys = asyncDedupKeys,
      scenarioGroups = groups,
      asyncDelivery = listToMaybe asyncDeliveries,
      versionManaged
    }
  where
    sourceId = identity mkSourceId (key <> "-source")
    groupFacts =
      [ let groupId = identity mkRebuildGroupId (key <> "-g" <> indexText groupIndex)
            targets =
              [ ( identity mkTargetId (key <> "-g" <> indexText groupIndex <> "-t" <> indexText targetIndex),
                  QualifiedTable "app" (sqlName key <> "_g" <> indexText groupIndex <> "_t" <> indexText targetIndex)
                )
              | targetIndex <- [1 .. targetCount]
              ]
         in (groupIndex, groupId, targets)
      | (groupIndex, targetCount) <- zip [1 ..] targetCounts
      ]
    targetDeclarations =
      [ TargetDeclaration
          { targetId,
            qualifiedTable = table,
            resetPolicy = PreserveAndReconcile,
            dependsOn = [],
            claimSite = claim (key <> ":target:" <> targetIdText targetId)
          }
      | (_, _, targets) <- groupFacts,
        (targetId, table) <- targets
      ]
    groupDeclarations =
      [ RebuildGroupDeclaration
          { rebuildGroupId = groupId,
            orderedTargets = map fst targets,
            verificationHooks = [],
            claimSite = claim (key <> ":group:" <> rebuildGroupIdText groupId)
          }
      | (_, groupId, targets) <- groupFacts
      ]
    groupDefinitions = concatMap definitionsForGroup groupFacts
    definitions = [definition | (definition, _, _, _) <- groupDefinitions]
    asyncSubscriptions = [subscription | (_, _, Just subscription, _) <- groupDefinitions]
    asyncDedupKeys = [dedupKey | (_, _, _, Just dedupKey) <- groupDefinitions]
    asyncDeliveries =
      [ (definition ^. #projectionId, projection)
      | (definition, Just projection, _, _) <- groupDefinitions
      ]
    groups =
      [ ScenarioGroup
          { groupId,
            targets,
            revisions =
              if versionManaged
                then
                  [ scenarioRevision key groupIndex groupId targets groupDefinitions revisionIndex streamPolicy
                  | revisionIndex <- [0 .. 1 + extraRevisions]
                  ]
                else []
          }
      | (groupIndex, groupId, targets) <- groupFacts
      ]

    definitionsForGroup (groupIndex, groupId, targets)
      | mixed =
          let (inlineTargets, asyncTargets) = splitAt (length targets - 1) targets
              inline = inlineDefinition key groupIndex groupId inlineTargets
              async = asyncDefinition key groupIndex groupId asyncTargets
           in [inline, async]
      | otherwise = [inlineDefinition key groupIndex groupId targets]

inlineDefinition :: Text -> Int -> RebuildGroupId -> [(TargetId, QualifiedTable)] -> (ProjectionDefinition ProjectionBenchEvent, Maybe AsyncProjection, Maybe SubscriptionDeclaration, Maybe DedupKeyDeclaration)
inlineDefinition key groupIndex groupId targets =
  ( ProjectionDefinition
      { projectionId,
        rebuildGroup = groupId,
        ownedTargets = nonEmptyOrError "inline targets" (map fst targets),
        replayPolicy = benchReplayPolicy,
        handlers = InlineHandler projection (claim (key <> ":inline-handler:" <> indexText groupIndex)) :| [],
        claimSite = claim (key <> ":inline:" <> indexText groupIndex)
      },
    Nothing,
    Nothing,
    Nothing
  )
  where
    projectionId = identity mkProjectionId (key <> "-g" <> indexText groupIndex <> "-inline")
    projection = logicalInlineProjection (key <> "-inline") targets

asyncDefinition :: Text -> Int -> RebuildGroupId -> [(TargetId, QualifiedTable)] -> (ProjectionDefinition ProjectionBenchEvent, Maybe AsyncProjection, Maybe SubscriptionDeclaration, Maybe DedupKeyDeclaration)
asyncDefinition key groupIndex groupId targets =
  ( ProjectionDefinition
      { projectionId,
        rebuildGroup = groupId,
        ownedTargets = nonEmptyOrError "async targets" (map fst targets),
        replayPolicy = benchReplayPolicy,
        handlers = AsyncHandler projection subscriptionId dedupKeyId (claim (key <> ":async-handler")) :| [],
        claimSite = claim (key <> ":async")
      },
    Just projection,
    Just subscriptionDeclaration,
    Just dedupDeclaration
  )
  where
    projectionId = identity mkProjectionId (key <> "-g" <> indexText groupIndex <> "-async")
    subscriptionId = identity mkSubscriptionId (key <> "-subscription")
    dedupKeyId = identity mkDedupKeyId (key <> "-dedup")
    subscriptionName = key <> "-subscription"
    projectionName = key <> "-async"
    projection =
      AsyncProjection
        { name = projectionName,
          readModelName = key <> "-async-model",
          subscriptionName,
          applyRecorded = \_ -> updateLogicalTargets targets,
          idempotencyKey = (^. #eventId)
        }
    subscriptionDeclaration =
      SubscriptionDeclaration
        { subscriptionId,
          subscriptionName,
          subscriptionSource = identity mkSourceId (key <> "-source"),
          checkpointOnMissing = FromBeginning,
          claimSite = claim (key <> ":subscription")
        }
    dedupDeclaration =
      DedupKeyDeclaration
        { dedupKeyId,
          dedupName = projectionName,
          claimSite = claim (key <> ":dedup")
        }

scenarioRevision :: Text -> Int -> RebuildGroupId -> [(TargetId, QualifiedTable)] -> [(ProjectionDefinition ProjectionBenchEvent, Maybe AsyncProjection, Maybe SubscriptionDeclaration, Maybe DedupKeyDeclaration)] -> Int -> Maybe (TargetId -> StreamScopedReplay) -> ProjectionRevision
scenarioRevision key groupIndex groupId targets allDefinitions revisionIndex streamPolicy =
  ProjectionRevision
    { revisionId = identity mkProjectionRevisionId revisionName,
      rebuildGroup = groupId,
      targetProvisioners = Map.fromList [(targetId, targetProvisioner key targetId revisionName) | (targetId, _) <- targets],
      liveHandlers = concatMap revisionHandlers relevantDefinitions,
      replayAdapters =
        [ RevisionReplayAdapter
            (revisionName <> "-replay")
            1
            (map fst targets)
            (\_ _ -> pure (Right False))
        ],
      revisionVerifications = [],
      streamScopedReplays = maybe [] (\makePolicy -> [makePolicy (fst (firstOrError "revision target" targets))]) streamPolicy,
      claimSite = claim (key <> ":revision:" <> revisionName)
    }
  where
    revisionName = key <> "-g" <> indexText groupIndex <> "-r" <> indexText revisionIndex
    relevantDefinitions =
      [ definition
      | entry@(definition, _, _, _) <- allDefinitions,
        definition ^. #rebuildGroup == groupId,
        let _ = entry
      ]
    revisionHandlers definition =
      [ case handler of
          InlineHandler projection _ ->
            RevisionLiveHandler
              (revisionName <> "-" <> projection ^. #name)
              1
              (RevisionInlineDelivery (definition ^. #projectionId) (projection ^. #name))
              (toList (definition ^. #ownedTargets))
              (\physicalTargets _ -> updatePhysicalTargets physicalTargets (toList (definition ^. #ownedTargets)))
          AsyncHandler projection subscriptionId dedupKeyId _ ->
            RevisionLiveHandler
              (revisionName <> "-" <> projection ^. #name)
              1
              (RevisionSubscriptionDelivery (definition ^. #projectionId) subscriptionId dedupKeyId)
              (toList (definition ^. #ownedTargets))
              (\physicalTargets _ -> updatePhysicalTargets physicalTargets (toList (definition ^. #ownedTargets)))
      | handler <- toList (definition ^. #handlers)
      ]

logicalInlineProjection :: Text -> [(TargetId, QualifiedTable)] -> InlineProjection ProjectionBenchEvent
logicalInlineProjection name targets =
  InlineProjection
    { name,
      apply = \_ _ -> updateLogicalTargets targets
    }

benchReplayPolicy :: ProjectionReplayPolicy ProjectionBenchEvent
benchReplayPolicy =
  Replayable
    ReplayAdapter
      { decodeForReplay = const ReplayIrrelevant,
        applyForReplay = \_ _ -> pure ()
      }

targetProvisioner :: Text -> TargetId -> Text -> TargetProvisioner
targetProvisioner key targetId revisionName =
  TargetProvisioner
    { provisionerId = revisionName <> "-" <> targetIdText targetId <> "-provisioner",
      provisionerVersion = 1,
      schemaVersion = TargetSchemaVersion "bench-v1",
      expectedShapeId = "bench-shape-v1",
      provisionTarget = \context -> do
        let table = context ^. #stagingTable
        createProjectionTable table
        seedProvisionedBenchmarkTable key targetId table,
      validatorId = revisionName <> "-" <> targetIdText targetId <> "-validator",
      validatorVersion = 1,
      validateTarget = Just validateProjectionTable,
      promotionObjectNames = []
    }
  where
    validateProjectionTable context = do
      relationOid <- Tx.statement () (relationOidStatement (context ^. #stagingTable))
      pure
        ( Right
            TargetSchemaEvidence
              { relationOid,
                observedShapeFingerprint = "bench-shape-v1",
                observedPromotionObjects = [],
                catalogSnapshot = "bench-catalog-v1"
              }
        )

seedProvisionedBenchmarkTable :: Text -> TargetId -> QualifiedTable -> Tx.Transaction ()
seedProvisionedBenchmarkTable key targetId table
  | key == "bench-versioned-allrows",
    targetIdText targetId == "bench-versioned-allrows-g1-t1" =
      insertGeneratedRows table 100
  | key == "bench-versioned-keyed",
    targetIdText targetId == "bench-versioned-keyed-g1-t1" =
      insertGeneratedRows table 10_000
  | otherwise = pure ()

insertGeneratedRows :: QualifiedTable -> Int -> Tx.Transaction ()
insertGeneratedRows table upperBound =
  Tx.sql
    ( Text.Encoding.encodeUtf8
        ( "INSERT INTO "
            <> qualified table
            <> " (id, value) SELECT id, id * 10 FROM generate_series(2, "
            <> Text.pack (show upperBound)
            <> ") AS ids(id)"
        )
    )

repairPolicy :: TargetId -> StreamScopedReplay
repairPolicy targetId =
  StreamScopedReplay
    { streamProjectionId = identity mkProjectionId "benchrepair-g1-inline",
      streamOwnedTargets = targetId :| [],
      clearerId = "benchrepair-clear",
      clearerVersion = 1,
      clearStreamRows = \physicalTargets _ -> do
        let table = requirePhysicalTarget physicalTargets targetId
        cleared <- Tx.statement () (deleteProjectionRowsStatement table)
        pure (Right [StreamClearCount targetId cleared]),
      streamReplayId = "benchrepair-replay",
      streamReplayVersion = 1,
      replayStreamEvent = \physicalTargets _ -> do
        updateProjectionTable (requirePhysicalTarget physicalTargets targetId)
        pure (Right True),
      streamVerificationId = "benchrepair-verify",
      streamVerificationVersion = 1,
      verifyStreamRows = \physicalTargets _ -> do
        rows <- Tx.statement () (countProjectionRowsStatement (requirePhysicalTarget physicalTargets targetId))
        pure (if rows == 1 then Right () else Left "repair target must contain one row"),
      affectedAsyncDedup = [],
      claimSite = claim "benchrepair:policy"
    }

setupTables :: Tx.Transaction ()
setupTables = do
  Tx.sql "CREATE SCHEMA IF NOT EXISTS app"
  Tx.sql "CREATE SCHEMA app_contract"
  Tx.sql "CREATE SCHEMA app_private"
  traverse_ (createProjectionTable . (^. #qualifiedTable)) allTargets
  Tx.sql "CREATE TYPE app_contract.bench_all_row_v1 AS (id bigint, value bigint)"
  Tx.sql "CREATE TYPE app_contract.bench_keyed_row_v1 AS (id bigint, value bigint)"
  Tx.sql
    """
    INSERT INTO app.bench_versioned_allrows_g1_t1 (id, value)
    SELECT id, id * 10 FROM generate_series(2, 100) AS ids(id)
    """
  Tx.sql
    """
    INSERT INTO app.bench_versioned_keyed_g1_t1 (id, value)
    SELECT id, id * 10 FROM generate_series(2, 10000) AS ids(id)
    """
  Tx.sql
    """
    CREATE FUNCTION app_private.bench_keyed_lookup(requested_id bigint)
    RETURNS SETOF app_contract.bench_keyed_row_v1
    LANGUAGE sql
    STABLE
    AS $lookup$
      SELECT ROW(model.id, model.value)::app_contract.bench_keyed_row_v1
      FROM app.bench_versioned_keyed_g1_t1 AS model
      WHERE model.id = requested_id
    $lookup$
    """
  where
    allTargets = concatMap (\scenario -> scenario.targetDeclarations) scenarioDefinitions

statusScaleGroupCount :: Int
statusScaleGroupCount = 1_000

seedStatusScale :: Tx.Transaction ()
seedStatusScale = do
  Tx.sql
    ( Text.Encoding.encodeUtf8
        ( "INSERT INTO keiro.keiro_projection_rebuild_groups (group_id, slice_fingerprint, status) "
            <> "SELECT 'bench-status-' || ordinal::text, 'slice-v6:bench-status', 'live' "
            <> "FROM generate_series(1, "
            <> Text.pack (show statusScaleGroupCount)
            <> ") AS ordinals(ordinal)"
        )
    )
  Tx.sql
    """
    INSERT INTO keiro.keiro_projection_group_cursors
      (group_id, position_basis, subscription_names)
    SELECT group_id, 'append', ARRAY[]::text[]
    FROM keiro.keiro_projection_rebuild_groups
    WHERE group_id LIKE 'bench-status-%'
    """

createProjectionTable :: QualifiedTable -> Tx.Transaction ()
createProjectionTable table =
  do
    Tx.sql
      ( Text.Encoding.encodeUtf8
          ( "CREATE TABLE "
              <> qualified table
              <> " (id bigint PRIMARY KEY, value bigint NOT NULL)"
          )
      )
    Tx.sql
      ( Text.Encoding.encodeUtf8
          ( "INSERT INTO "
              <> qualified table
              <> " (id, value) VALUES (1, 0)"
          )
      )

bootstrapVersionedGroups :: [ProjectionScenario] -> Tx.Transaction ()
bootstrapVersionedGroups scenarios =
  traverse_ bootstrapScenario [scenario | scenario <- scenarios, scenario.versionManaged]
  where
    bootstrapScenario scenario = traverse_ bootstrapGroup scenario.scenarioGroups
    bootstrapGroup group = do
      let servingRevision = group.revisions ^?! ix 0 . #revisionId
      traverse_ (insertGeneration group.groupId servingRevision) (zip [1 :: Int64 ..] group.targets)
      Tx.sql
        ( Text.Encoding.encodeUtf8
            ( "UPDATE keiro.keiro_projection_rebuild_groups SET status = 'serving-versioned', "
                <> "serving_revision_id = "
                <> literal (projectionRevisionIdText servingRevision)
                <> ", serving_epoch = 1, reads_allowed = TRUE, writes_allowed = TRUE "
                <> "WHERE group_id = "
                <> literal (rebuildGroupIdText group.groupId)
            )
        )
    insertGeneration groupId revisionId (ordinal, (targetId, table)) =
      let generationId = generationUuid groupId targetId ordinal
       in Tx.sql
            ( Text.Encoding.encodeUtf8
                ( "INSERT INTO keiro.keiro_projection_target_generations "
                    <> "(generation_id, group_id, target_id, revision_id, schema_name, relation_name, relation_oid, "
                    <> "schema_version, expected_shape_id, observed_shape_fingerprint, observed_catalog_snapshot, lifecycle, served_at) VALUES ("
                    <> literal (UUID.toText generationId)
                    <> "::uuid, "
                    <> literal (rebuildGroupIdText groupId)
                    <> ", "
                    <> literal (targetIdText targetId)
                    <> ", "
                    <> literal (projectionRevisionIdText revisionId)
                    <> ", "
                    <> literal (table ^. #schemaName)
                    <> ", "
                    <> literal (table ^. #tableName)
                    <> ", "
                    <> literal (table ^. #schemaName <> "." <> table ^. #tableName)
                    <> "::regclass::oid, 'bench-v1', 'bench-shape-v1', 'bench-shape-v1', 'bench-catalog-v1', 'serving', now())"
                )
            )

generationUuid :: RebuildGroupId -> TargetId -> Int64 -> UUID.UUID
generationUuid groupId targetId ordinal =
  UUID.V5.generateNamed
    UUID.V5.namespaceURL
    ( ByteString.unpack
        ( Text.Encoding.encodeUtf8
            (rebuildGroupIdText groupId <> ":" <> targetIdText targetId <> ":" <> Text.pack (show ordinal))
        )
    )

updateLogicalTargets :: [(TargetId, QualifiedTable)] -> Tx.Transaction ()
updateLogicalTargets = traverse_ (updateProjectionTable . snd)

updatePhysicalTargets :: PhysicalTargets -> [TargetId] -> Tx.Transaction ()
updatePhysicalTargets physicalTargets =
  traverse_ (updateProjectionTable . requirePhysicalTarget physicalTargets)

updateProjectionTable :: QualifiedTable -> Tx.Transaction ()
updateProjectionTable table =
  Tx.sql
    ( Text.Encoding.encodeUtf8
        ( "INSERT INTO "
            <> qualified table
            <> " (id, value) VALUES (1, 1) "
            <> "ON CONFLICT (id) DO UPDATE SET value = "
            <> quoteIdentifier (table ^. #tableName)
            <> ".value + 1"
        )
    )

requirePhysicalTarget :: PhysicalTargets -> TargetId -> QualifiedTable
requirePhysicalTarget targets targetId =
  fromMaybe
    (error ("missing benchmark physical target: " <> Text.unpack (targetIdText targetId)))
    (resolvePhysicalTarget targetId targets)

physicalTargetsFor :: [(TargetId, QualifiedTable)] -> PhysicalTargets
physicalTargetsFor targets =
  case mkPhysicalTargets (map fst targets) (Map.fromList targets) of
    Left errors -> error (show errors)
    Right value -> value

seedRepairStreams :: Store.KirokuStore -> IO ()
seedRepairStreams store =
  traverse_ seed repairEventCounts
  where
    seed count =
      runStoreChecked store $
        void $
          Store.appendToStream
            (repairStreamName count)
            NoStream
            [ EventData
                { eventId = Nothing,
                  eventType = EventType "BenchRepairEvent",
                  payload = Aeson.Null,
                  metadata = Nothing,
                  causationId = Nothing,
                  correlationId = Nothing
                }
            | _ <- [1 .. count]
            ]

stabilizingHistoryEventCount :: Int
stabilizingHistoryEventCount = 25_000

seedStabilizingHistory :: Store.KirokuStore -> IO ()
seedStabilizingHistory store =
  runStoreChecked store $
    void $
      Store.appendToStream
        (StreamName "benchseed-history")
        NoStream
        [ EventData
            { eventId = Nothing,
              eventType = EventType "BenchSeedEvent",
              payload = Aeson.Null,
              metadata = Nothing,
              causationId = Nothing,
              correlationId = Nothing
            }
        | _ <- [1 .. stabilizingHistoryEventCount]
        ]

repairStreamName :: Int -> StreamName
repairStreamName count = StreamName ("benchrepair-" <> Text.pack (show count))

retentionRequest :: RebuildRunId -> HistoryRetentionLeaseRequest
retentionRequest runId =
  HistoryRetentionLeaseRequest
    { owner = requireRight (mkHistoryRetentionLeaseOwner ("keiro-rebuild/" <> rebuildRunIdText runId)),
      reason = requireRight (mkHistoryRetentionLeaseReason "benchmark schema-versioned promotion"),
      duration = requireRight (mkHistoryRetentionLeaseDuration (secondsToDiffTime 600))
    }

syntheticRecordedEvent :: Int64 -> RecordedEvent
syntheticRecordedEvent value =
  RecordedEvent
    { eventId = EventId (UUID.fromWords64 0x018f0f1800007000 (0x8000000000000000 + fromIntegral value)),
      eventType = EventType "ProjectionBenchEvent",
      streamVersion = StreamVersion value,
      globalPosition = GlobalPosition value,
      originalStreamId = StreamId value,
      originalVersion = StreamVersion value,
      payload = Aeson.Null,
      metadata = Nothing,
      causationId = Nothing,
      correlationId = Nothing,
      createdAt = fixedOccurredAt
    }

projectionBenchEventStream :: ValidatedProjectionBenchEventStream
projectionBenchEventStream =
  case mkEventStream "read-model-benchmark" projectionBenchRawEventStream of
    Left errors -> error (show errors)
    Right value -> value

projectionBenchRawEventStream :: ProjectionBenchEventStream
projectionBenchRawEventStream =
  EventStream
    { transducer =
        SymTransducer
          { edgesOut = \ProjectionBenchReady ->
              [ Edge
                  { guard = matchInCtor projectionCommandCtor,
                    update = UKeep,
                    output = [pack projectionCommandCtor projectionEventCtor oNil],
                    target = ProjectionBenchReady,
                    mode = Keiki.Live
                  }
              ],
            initial = ProjectionBenchReady,
            initialRegs = RNil,
            isFinal = const False
          },
      initialState = ProjectionBenchReady,
      initialRegisters = RNil,
      eventCodec =
        Codec
          { eventTypes = EventType "ProjectionBenchEvent" :| [],
            eventType = const (EventType "ProjectionBenchEvent"),
            schemaVersion = 1,
            encode = const Aeson.Null,
            decode = \(EventType eventTypeName) _ ->
              if eventTypeName == "ProjectionBenchEvent"
                then Right ProjectionBenchEvent
                else Left ("unknown projection benchmark event: " <> eventTypeName),
            upcasters = []
          },
      resolveStreamName = Keiro.Stream.streamName,
      snapshotPolicy = Never,
      stateCodec = Nothing
    }

projectionCommandCtor :: InCtor ProjectionBenchCommand '[]
projectionCommandCtor =
  unavailableInCtor
    "EmitProjection"
    (\case EmitProjection -> Just RNil)
    (\RNil -> EmitProjection)

projectionEventCtor :: WireCtor ProjectionBenchEvent ()
projectionEventCtor =
  unavailableWireCtor
    "ProjectionBenchEvent"
    (const (Just ()))
    (const ProjectionBenchEvent)

deleteProjectionRowsStatement :: QualifiedTable -> Statement () Int64
deleteProjectionRowsStatement table =
  preparable
    ("DELETE FROM " <> qualified table)
    E.noParams
    D.rowsAffected

countProjectionRowsStatement :: QualifiedTable -> Statement () Int64
countProjectionRowsStatement table =
  preparable
    ("SELECT count(*) FROM " <> qualified table)
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.int8)))

relationOidStatement :: QualifiedTable -> Statement () Int64
relationOidStatement table =
  preparable
    ("SELECT " <> literal (table ^. #schemaName <> "." <> table ^. #tableName) <> "::regclass::oid::bigint")
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.int8)))

guardedAllRowsStatement :: Statement () [(Int64, Int64)]
guardedAllRowsStatement =
  preparable
    "SELECT id, value FROM keiro_read.bench_all_rows_v1() ORDER BY id"
    E.noParams
    (D.rowList ((,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8)))

guardedKeyedStatement :: Statement Int64 [(Int64, Int64)]
guardedKeyedStatement =
  preparable
    "SELECT id, value FROM keiro_read.bench_keyed_v1($1)"
    (E.param (E.nonNullable E.int8))
    (D.rowList ((,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8)))

explainServingBindingStatement :: Statement Text Aeson.Value
explainServingBindingStatement =
  preparable
    """
    EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
    SELECT locked_group.status,
           locked_group.active_run_id,
           locked_group.serving_revision_id,
           locked_group.writes_allowed,
           COALESCE(array_agg(generations.target_id ORDER BY generations.target_id)
             FILTER (WHERE generations.target_id IS NOT NULL), ARRAY[]::text[]),
           COALESCE(array_agg(generations.revision_id ORDER BY generations.target_id)
             FILTER (WHERE generations.target_id IS NOT NULL), ARRAY[]::text[]),
           COALESCE(array_agg(generations.schema_name ORDER BY generations.target_id)
             FILTER (WHERE generations.target_id IS NOT NULL), ARRAY[]::text[]),
           COALESCE(array_agg(generations.relation_name ORDER BY generations.target_id)
             FILTER (WHERE generations.target_id IS NOT NULL), ARRAY[]::text[])
    FROM (
      SELECT status, active_run_id, serving_revision_id, writes_allowed
      FROM keiro.keiro_projection_rebuild_groups
      WHERE group_id = $1
      FOR SHARE
    ) AS locked_group
    LEFT JOIN LATERAL (
      SELECT target_id, revision_id, schema_name, relation_name
      FROM keiro.keiro_projection_target_generations
      WHERE group_id = $1 AND lifecycle = 'serving'
    ) AS generations ON TRUE
    GROUP BY locked_group.status,
             locked_group.active_run_id,
             locked_group.serving_revision_id,
             locked_group.writes_allowed
    """
    (E.param (E.nonNullable E.text))
    (D.singleRow (D.column (D.nonNullable D.json)))

explainStatusListStatement :: Statement () Aeson.Value
explainStatusListStatement =
  explainJsonNoParams
    "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT * FROM keiro_read.projection_group_status_v1 ORDER BY group_id"

explainStatusLookupStatement :: Statement () Aeson.Value
explainStatusLookupStatement =
  explainJsonNoParams
    "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT * FROM keiro_read.projection_group_status_v1 WHERE group_id = 'bench-status-1000'"

explainGuardedAllRowsStatement :: Statement () Aeson.Value
explainGuardedAllRowsStatement =
  explainJsonNoParams
    "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT id, value FROM keiro_read.bench_all_rows_v1() ORDER BY id"

explainGuardedKeyedStatement :: Statement () Aeson.Value
explainGuardedKeyedStatement =
  explainJsonNoParams
    "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT id, value FROM keiro_read.bench_keyed_v1(5000)"

explainKeyedIndexStatement :: Statement () Aeson.Value
explainKeyedIndexStatement =
  explainJsonNoParams
    """
    EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
    SELECT ROW(model.id, model.value)::app_contract.bench_keyed_row_v1
    FROM app.bench_versioned_keyed_g1_t1 AS model
    WHERE model.id = 5000
    """

explainJsonNoParams :: Text -> Statement () Aeson.Value
explainJsonNoParams sql =
  preparable
    sql
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.json)))

servingBindingStatement :: Statement Text (Maybe (Text, Maybe Text, Maybe Text, Bool, [(Text, Text, Text, Text)]))
servingBindingStatement =
  preparable
    """
    SELECT locked_group.status,
           locked_group.active_run_id,
           locked_group.serving_revision_id,
           locked_group.writes_allowed,
           COALESCE(array_agg(generations.target_id ORDER BY generations.target_id)
             FILTER (WHERE generations.target_id IS NOT NULL), ARRAY[]::text[]),
           COALESCE(array_agg(generations.revision_id ORDER BY generations.target_id)
             FILTER (WHERE generations.target_id IS NOT NULL), ARRAY[]::text[]),
           COALESCE(array_agg(generations.schema_name ORDER BY generations.target_id)
             FILTER (WHERE generations.target_id IS NOT NULL), ARRAY[]::text[]),
           COALESCE(array_agg(generations.relation_name ORDER BY generations.target_id)
             FILTER (WHERE generations.target_id IS NOT NULL), ARRAY[]::text[])
    FROM (
      SELECT status, active_run_id, serving_revision_id, writes_allowed
      FROM keiro.keiro_projection_rebuild_groups
      WHERE group_id = $1
      FOR SHARE
    ) AS locked_group
    LEFT JOIN LATERAL (
      SELECT target_id, revision_id, schema_name, relation_name
      FROM keiro.keiro_projection_target_generations
      WHERE group_id = $1 AND lifecycle = 'serving'
    ) AS generations ON TRUE
    GROUP BY locked_group.status,
             locked_group.active_run_id,
             locked_group.serving_revision_id,
             locked_group.writes_allowed
    """
    (E.param (E.nonNullable E.text))
    ( D.rowMaybe
        ( (,,,,)
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nullable D.text)
            <*> D.column (D.nullable D.text)
            <*> D.column (D.nonNullable D.bool)
            <*> ( List.zip4
                    <$> D.column (D.nonNullable (D.listArray (D.nonNullable D.text)))
                    <*> D.column (D.nonNullable (D.listArray (D.nonNullable D.text)))
                    <*> D.column (D.nonNullable (D.listArray (D.nonNullable D.text)))
                    <*> D.column (D.nonNullable (D.listArray (D.nonNullable D.text)))
                )
        )
    )

qualified :: QualifiedTable -> Text
qualified table = qualifyTable (table ^. #schemaName) (table ^. #tableName)

quoteIdentifier :: Text -> Text
quoteIdentifier value = "\"" <> Text.replace "\"" "\"\"" value <> "\""

literal :: Text -> Text
literal value = "'" <> Text.replace "'" "''" value <> "'"

sqlName :: Text -> Text
sqlName = Text.map (\character -> if character == '-' then '_' else character)

indexText :: (Show value) => value -> Text
indexText = Text.pack . show

claim :: Text -> ClaimSite
claim = identity mkClaimSite

identity :: (Show error) => (Text -> Either error value) -> Text -> value
identity constructor value = requireRight (constructor value)

requireRight :: (Show error) => Either error value -> value
requireRight = either (error . show) id

nonEmptyOrError :: Text -> [value] -> NonEmpty value
nonEmptyOrError label = \case
  [] -> error (Text.unpack label <> " must not be empty")
  first : rest -> first :| rest

firstOrError :: Text -> [value] -> value
firstOrError label = \case
  [] -> error (Text.unpack label <> " must not be empty")
  first : _ -> first

lastOrError :: Text -> [value] -> value
lastOrError label = \case
  [] -> error (Text.unpack label <> " must not be empty")
  values -> List.last values

requireScenario :: ReadModelBenchFixture -> Text -> IO ProjectionScenario
requireScenario fixture scenarioKey =
  maybe (fail ("unknown read-model benchmark scenario: " <> Text.unpack scenarioKey)) pure (Map.lookup scenarioKey fixture.scenarios)

nextCounter :: IORef Int64 -> IO Int64
nextCounter counter = atomicModifyIORef' counter (\current -> let next = current + 1 in (next, next))

fixedOccurredAt :: UTCTime
fixedOccurredAt = UTCTime (ModifiedJulianDay 61000) (secondsToDiffTime 0)

runResourceStoreChecked :: StoreRunner -> Eff '[Store, Error Store.StoreError, KirokuStoreResource, IOE] value -> IO value
runResourceStoreChecked (StoreRunner runner) action =
  runner action >>= either (fail . show) pure

runStoreChecked :: Store.KirokuStore -> Eff '[Store, Error Store.StoreError, IOE] value -> IO value
runStoreChecked store action =
  Store.runStoreIO store action >>= either (fail . show) pure
