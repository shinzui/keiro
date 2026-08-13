{-# LANGUAGE MultilineStrings #-}

module ProjectionReplaySpec
  ( spec,
  )
where

import Contravariant.Extras (contrazip2, contrazip3)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Either (isRight)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Int (Int32)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Data.Word (Word64)
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpose, passthrough)
import Effectful.Error.Static (Error)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import Keiro.Projection (InlineProjection (..))
import Keiro.Projection.Catalog
import Keiro.Projection.Catalog qualified as CatalogApi
import Keiro.ReadModel.Rebuild
import Keiro.Test.Postgres (Fixture, withFreshStore)
import Kiroku.Store qualified as Store
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect qualified as StoreEffect
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types
  ( CategoryName (..),
    EventData (..),
    EventType (..),
    ExpectedVersion (..),
    GlobalPosition (..),
    RecordedEvent,
    StreamName (..),
  )
import Test.Hspec
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude (map, replicate, (&&))
import Prelude qualified

spec :: Fixture -> Spec
spec fixture = describe "catalog replay runner" $ around (withFreshStore fixture) $ do
  it "merges interleaved categories in global order and promotes only complete evidence" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql replayFixtureSql))
    appendInterleaved store
    validated <- expectValid (replayCatalog goodDecoder passingVerification)
    _ <- expectStore store (registerProjectionCatalog validated) >>= shouldBeRight

    report <-
      expectStore
        store
        (startCatalogRebuild validated replayGroupId (options "ordered-run" 2))
        >>= shouldBeRight

    report ^. #runStatus `shouldBe` RebuildRunPromoted
    report ^. #capturedHead `shouldBe` GlobalPosition 6
    map (^. #exhaustedThrough) (report ^. #sources)
      `shouldBe` replicate 3 (Just (GlobalPosition 6))
    map (^. #evaluationCount) (report ^. #adapters) `shouldBe` [2, 2, 2]
    map (^. #applyCount) (report ^. #adapters) `shouldBe` [2, 2, 2]
    expectStore store (Store.runTransaction (Tx.statement () tracePositionsStmt))
      `shouldReturn` [1, 2, 3, 4, 5, 6]

  it "reads each source event once while draining a multi-source rebuild" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql replayFixtureSql))
    appendCountingFixture store
    validated <- expectValid (replayCatalog goodDecoder passingVerification)
    _ <- expectStore store (registerProjectionCatalog validated) >>= shouldBeRight
    reads <- newIORef emptyStoreReadCounts

    report <-
      expectStore
        store
        ( countStoreReads reads
            $ startCatalogRebuild validated replayGroupId (options "counted-run" 2)
        )
        >>= shouldBeRight
    counts <- readIORef reads

    report ^. #runStatus `shouldBe` RebuildRunPromoted
    Map.size (counts ^. #categoryPageReads) `shouldBe` 3
    Prelude.sum (Prelude.map Prelude.snd (Map.elems (counts ^. #categoryPageReads)))
      `shouldSatisfy` (<= 18 Prelude.+ 3 Prelude.* 2)
    Prelude.map Prelude.fst (Map.elems (counts ^. #categoryPageReads))
      `shouldSatisfy` Prelude.all (<= 6 `Prelude.div` 2 Prelude.+ 1)

  it "counts irrelevant adapter participation even when no event applies" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql replayFixtureSql))
    traverse_
      (appendRaw store)
      [ (StreamName "orders-1", NoStream, EventType "Unrelated", Aeson.Null),
        (StreamName "customers-1", NoStream, EventType "Unrelated", Aeson.Null),
        (StreamName "billing-1", NoStream, EventType "Unrelated", Aeson.Null)
      ]
    validated <- expectValid (replayCatalog goodDecoder passingVerification)
    _ <- expectStore store (registerProjectionCatalog validated) >>= shouldBeRight
    report <-
      expectStore store (startCatalogRebuild validated replayGroupId (options "irrelevant-run" 2))
        >>= shouldBeRight

    report ^. #runStatus `shouldBe` RebuildRunPromoted
    map (^. #evaluationCount) (report ^. #adapters) `shouldBe` [1, 1, 1]
    map (^. #applyCount) (report ^. #adapters) `shouldBe` [0, 0, 0]
    expectStore store (Store.runTransaction (Tx.statement () tracePositionsStmt))
      `shouldReturn` []

  it "never extends the captured head when matching events arrive during verification" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql replayFixtureSql))
    appendInterleaved store
    validated <- expectValid (replayCatalog goodDecoder delayedVerification)
    _ <- expectStore store (registerProjectionCatalog validated) >>= shouldBeRight
    finished <- newEmptyMVar
    _ <-
      forkIO
        $ Store.runStoreIO store (startCatalogRebuild validated replayGroupId (options "fixed-head-run" 2))
        >>= putMVar finished
    threadDelay 200_000
    appendRaw store (StreamName "orders-1", AnyVersion, EventType "ReplayEvent", Aeson.toJSON (70 :: Int64))
    outcome <- takeMVar finished
    report <-
      case outcome of
        Right (Right value) -> pure value
        other -> expectationFailure (show other) >> error "unreachable"
    report ^. #capturedHead `shouldBe` GlobalPosition 6
    expectStore store (Store.runTransaction (Tx.statement () tracePositionsStmt))
      `shouldReturn` [1, 2, 3, 4, 5, 6]

  it "reconciles a preserved target without deleting roots absent from history" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql replayFixtureSql))
    expectStore store (Store.runTransaction (Tx.statement (999, 999) ordersInsertStmt))
    appendInterleaved store
    let preserved =
          replayCatalog goodDecoder passingVerification
            & #targets
            . traversed
            . filtered ((== ordersTargetId) . (^. #targetId))
            . #resetPolicy
            .~ PreserveAndReconcile
    validated <- expectValid preserved
    _ <- expectStore store (registerProjectionCatalog validated) >>= shouldBeRight
    report <-
      expectStore store (startCatalogRebuild validated replayGroupId (options "preserve-run" 2))
        >>= shouldBeRight
    report ^. #runStatus `shouldBe` RebuildRunPromoted
    expectStore store (Store.runTransaction (Tx.statement () ordersPositionsStmt))
      `shouldReturn` [1, 4, 999]

  it "rolls a failed chunk back and resumes the exact contract without duplicate writes" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql replayFixtureSql))
    appendInterleaved store
    faultedCatalog <- expectValid (replayCatalog failAtThirdPosition passingVerification)
    _ <- expectStore store (registerProjectionCatalog faultedCatalog) >>= shouldBeRight
    first <- expectStore store (startCatalogRebuild faultedCatalog replayGroupId (options "decode-run" 4))
    first `shouldSatisfy` \case
      Left CatalogRebuildDecodeFailed {} -> True
      _ -> False
    expectStore store (Store.runTransaction (Tx.statement () tracePositionsStmt))
      `shouldReturn` []
    failedReport <- expectStore store (inspectCatalogRebuild (runId "decode-run")) >>= shouldBeRight
    map (^. #cursorPosition) (failedReport ^. #sources)
      `shouldBe` replicate 3 (GlobalPosition 0)

    repaired <- expectValid (replayCatalog goodDecoder passingVerification)
    resumed <-
      expectStore store (resumeCatalogRebuild repaired (runId "decode-run") (options "ignored" 2))
        >>= shouldBeRight
    resumed ^. #runStatus `shouldBe` RebuildRunPromoted
    expectStore store (Store.runTransaction (Tx.statement () tracePositionsStmt))
      `shouldReturn` [1, 2, 3, 4, 5, 6]

  it "retains committed pages across verification failure and rejects catalog drift on resume" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql replayFixtureSql))
    appendInterleaved store
    faultedCatalog <- expectValid (replayCatalog goodDecoder failingVerification)
    _ <- expectStore store (registerProjectionCatalog faultedCatalog) >>= shouldBeRight
    first <- expectStore store (startCatalogRebuild faultedCatalog replayGroupId (options "verify-run" 2))
    first `shouldSatisfy` \case
      Left CatalogRebuildVerificationFailed {} -> True
      _ -> False
    expectStore store (Store.runTransaction (Tx.statement () tracePositionsStmt))
      `shouldReturn` [1, 2, 3, 4, 5, 6]

    drifted <- expectValid ((replayCatalog goodDecoder passingVerification) & #sources . ix 0 . #codecFingerprint .~ "replay-v2")
    drift <- expectStore store (resumeCatalogRebuild drifted (runId "verify-run") (options "ignored" 3))
    drift `shouldSatisfy` \case
      Left CatalogRebuildContractMismatch {} -> True
      _ -> False

    repaired <- expectValid (replayCatalog goodDecoder passingVerification)
    additive <- expectValid (addUnrelatedReplaySource (replayCatalog goodDecoder passingVerification))
    CatalogApi.groupSliceFingerprint additive replayGroupId
      `shouldBe` CatalogApi.groupSliceFingerprint repaired replayGroupId
    resumed <-
      expectStore store (resumeCatalogRebuild additive (runId "verify-run") (options "ignored" 3))
        >>= shouldBeRight
    resumed ^. #runStatus `shouldBe` RebuildRunPromoted
    expectStore store (Store.runTransaction (Tx.statement () tracePositionsStmt))
      `shouldReturn` [1, 2, 3, 4, 5, 6]

  it "refuses to resume an active v2 replay contract under the v3 runner" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql replayFixtureSql))
    appendInterleaved store
    faulted <- expectValid (replayCatalog goodDecoder failingVerification)
    _ <- expectStore store (registerProjectionCatalog faulted) >>= shouldBeRight
    first <- expectStore store (startCatalogRebuild faulted replayGroupId (options "v2-contract-run" 2))
    first `shouldSatisfy` \case
      Left CatalogRebuildVerificationFailed {} -> True
      _ -> False
    let staleContract = "contract-v2:" <> Text.replicate 64 "a"
    expectStore
      store
      ( Store.runTransaction
          ( Tx.statement
              ("v2-contract-run", staleContract, "keiro/projection-replay/v2")
              setRunContractStmt
          )
      )
    inspected <- expectStore store (inspectCatalogRebuild (runId "v2-contract-run")) >>= shouldBeRight
    inspected ^. #contractFingerprint `shouldBe` staleContract
    inspected ^. #runnerFormatVersion `shouldBe` "keiro/projection-replay/v2"

    repaired <- expectValid (replayCatalog goodDecoder passingVerification)
    resumeResult <-
      expectStore store (resumeCatalogRebuild repaired (runId "v2-contract-run") (options "ignored" 2))
    resumeResult `shouldSatisfy` \case
      Left (CatalogRebuildContractMismatch mismatchedRun expected actual) ->
        mismatchedRun
          == runId "v2-contract-run"
          && expected
            == staleContract
          && Text.isPrefixOf "contract-v3:" actual
      _ -> False

  it "refuses promotion when a required adapter participation row is missing" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql replayFixtureSql))
    appendInterleaved store
    faultedCatalog <- expectValid (replayCatalog goodDecoder failingVerification)
    _ <- expectStore store (registerProjectionCatalog faultedCatalog) >>= shouldBeRight
    _ <- expectStore store (startCatalogRebuild faultedCatalog replayGroupId (options "omitted-run" 2))
    expectStore store (Store.runTransaction (Tx.statement "omitted-run" deleteAdapterStmt))

    repaired <- expectValid (replayCatalog goodDecoder passingVerification)
    result <- expectStore store (resumeCatalogRebuild repaired (runId "omitted-run") (options "ignored" 2))
    result `shouldSatisfy` \case
      Left CatalogRebuildInvariantFailed {} -> True
      _ -> False
    group <- expectStore store (lookupProjectionRebuildGroup replayGroupId)
    group ^? _Just . #status `shouldBe` Just GroupRebuilding

  it "applies merged multi-source chunks in ascending global order across buffer boundaries" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql replayFixtureSql))
    appendStaggered store
    validated <- expectValid (replayCatalog goodDecoder passingVerification)
    _ <- expectStore store (registerProjectionCatalog validated) >>= shouldBeRight
    report <-
      expectStore store (startCatalogRebuild validated replayGroupId (options "staggered-run" 2))
        >>= shouldBeRight
    report ^. #runStatus `shouldBe` RebuildRunPromoted
    expectStore store (Store.runTransaction (Tx.statement () tracePositionsStmt))
      `shouldReturn` [1, 2, 3, 4, 7, 8, 9]

  describe "cross-source ordering sweep"
    $ traverse_
      ( \(seed, pageSize) ->
          it ("preserves ascending order for seed " <> show seed <> " at page size " <> show pageSize) $ \store -> do
            expectStore store (Store.runTransaction (Tx.sql replayFixtureSql))
            expectedPositions <- appendSweep store seed 14
            validated <- expectValid (replayCatalog goodDecoder passingVerification)
            _ <- expectStore store (registerProjectionCatalog validated) >>= shouldBeRight
            report <-
              expectStore
                store
                ( startCatalogRebuild
                    validated
                    replayGroupId
                    (options ("sweep-" <> Text.pack (show seed) <> "-" <> Text.pack (show pageSize)) pageSize)
                )
                >>= shouldBeRight
            report ^. #runStatus `shouldBe` RebuildRunPromoted
            expectStore store (Store.runTransaction (Tx.statement () tracePositionsStmt))
              `shouldReturn` expectedPositions
            map (^. #exhaustedThrough) (report ^. #sources)
              `shouldBe` replicate 3 (Just (GlobalPosition 14))
      )
      [(seed, pageSize) | seed <- [1 .. 6], pageSize <- [1, 2, 3]]

data ReplayEvent = ReplayEvent !Int64
  deriving stock (Eq, Show)

type ReplayDecoder = RecordedEvent -> ReplayDecodeResult ReplayEvent

goodDecoder :: ReplayDecoder
goodDecoder recorded
  | recorded ^. #eventType /= EventType "ReplayEvent" = ReplayIrrelevant
  | otherwise =
      case Aeson.fromJSON (recorded ^. #payload) of
        Aeson.Error detail -> ReplayDecodeFailure (ReplayDecodeError (Text.pack detail))
        Aeson.Success value -> ReplayRelevant (ReplayEvent value)

failAtThirdPosition :: ReplayDecoder
failAtThirdPosition recorded
  | recorded ^. #globalPosition == GlobalPosition 3 =
      ReplayDecodeFailure (ReplayDecodeError "fault injected before chunk commit")
  | otherwise = goodDecoder recorded

passingVerification :: RebuildVerification
passingVerification = verificationWith (pure (Right ()))

failingVerification :: RebuildVerification
failingVerification = verificationWith (pure (Left "fault injected after committed pages"))

delayedVerification :: RebuildVerification
delayedVerification = verificationWith (Tx.sql "SELECT pg_sleep(1)" >> pure (Right ()))

verificationWith :: Tx.Transaction (Either Text ()) -> RebuildVerification
verificationWith action =
  RebuildVerification
    { verificationId = "trace-is-ordered",
      verificationVersion = "v1",
      verifyRebuild = action
    }

replayCatalog :: ReplayDecoder -> RebuildVerification -> ProjectionCatalog
replayCatalog decoder verification =
  ProjectionCatalog
    { sources =
        [ source "orders" ordersSourceId,
          source "customers" customersSourceId,
          source "billing" billingSourceId
        ],
      targets =
        [ target traceTargetId "replay_trace",
          target ordersTargetId "orders_projection",
          target customersTargetId "customers_projection",
          target billingTargetId "billing_projection"
        ],
      rebuildGroups =
        [ RebuildGroupDeclaration
            { rebuildGroupId = replayGroupId,
              orderedTargets = [traceTargetId, ordersTargetId, customersTargetId, billingTargetId],
              verificationHooks = [verification],
              claimSite = site "test:replay-group"
            }
        ],
      subscriptions = [],
      dedupKeys = [],
      queryModels = [],
      projectionSets =
        [ SomeProjectionSet (projectionSet ordersSourceId ordersProjectionId (traceTargetId :| [ordersTargetId]) "orders" ordersInsertStmt),
          SomeProjectionSet (projectionSet customersSourceId customersProjectionId (customersTargetId :| []) "customers" customersInsertStmt),
          SomeProjectionSet (projectionSet billingSourceId billingProjectionId (billingTargetId :| []) "billing" billingInsertStmt)
        ]
    }
  where
    source category sourceId =
      SourceDeclaration
        { sourceId,
          sourceScope = CategorySource (CategoryName category),
          codecFingerprint = "replay-v1",
          claimSite = site ("test:source:" <> category)
        }
    target targetId tableName =
      TargetDeclaration
        { targetId,
          qualifiedTable = QualifiedTable "app" tableName,
          resetPolicy = ClearBeforeReplay,
          dependsOn = [],
          claimSite = site ("test:target:" <> tableName)
        }
    projectionSet sourceId projectionId ownedTargets label insertStmt =
      ProjectionSet
        { projectionSource = sourceId,
          projectionDefinitions =
            ProjectionDefinition
              { projectionId,
                rebuildGroup = replayGroupId,
                ownedTargets,
                replayPolicy =
                  Replayable
                    ReplayAdapter
                      { decodeForReplay = decoder,
                        applyForReplay = applyReplay label insertStmt
                      },
                handlers =
                  InlineHandler
                    InlineProjection
                      { name = "live-" <> label,
                        apply = \_ _ -> pure ()
                      }
                    (site ("test:handler:" <> label))
                    :| [],
                claimSite = site ("test:projection:" <> label)
              }
              :| [],
          claimSite = site ("test:set:" <> label)
        }

addUnrelatedReplaySource :: ProjectionCatalog -> ProjectionCatalog
addUnrelatedReplaySource catalog =
  catalog
    { sources =
        catalog
          ^. #sources
          <> [ SourceDeclaration
                 { sourceId = identity mkSourceId "unrelated-source",
                   sourceScope = CategorySource (CategoryName "unrelated"),
                   codecFingerprint = "unrelated-v1",
                   claimSite = site "test:source:unrelated"
                 }
             ]
    }

applyReplay :: Text -> Statement (Int64, Int64) () -> ReplayEvent -> RecordedEvent -> Tx.Transaction ()
applyReplay sourceLabel insertTarget (ReplayEvent value) recorded = do
  let GlobalPosition position = recorded ^. #globalPosition
  Tx.statement (position, sourceLabel, value) insertTraceStmt
  Tx.statement (position, value) insertTarget

appendInterleaved :: Store.KirokuStore -> IO ()
appendInterleaved store =
  traverse_
    (appendRaw store)
    [ (StreamName "orders-1", NoStream, EventType "ReplayEvent", Aeson.toJSON (10 :: Int64)),
      (StreamName "customers-1", NoStream, EventType "ReplayEvent", Aeson.toJSON (20 :: Int64)),
      (StreamName "billing-1", NoStream, EventType "ReplayEvent", Aeson.toJSON (30 :: Int64)),
      (StreamName "orders-1", AnyVersion, EventType "ReplayEvent", Aeson.toJSON (40 :: Int64)),
      (StreamName "customers-1", AnyVersion, EventType "ReplayEvent", Aeson.toJSON (50 :: Int64)),
      (StreamName "billing-1", AnyVersion, EventType "ReplayEvent", Aeson.toJSON (60 :: Int64))
    ]

appendStaggered :: Store.KirokuStore -> IO ()
appendStaggered store =
  traverse_
    (appendRaw store)
    [ (StreamName "orders-1", NoStream, EventType "ReplayEvent", Aeson.toJSON (11 :: Int64)),
      (StreamName "customers-1", NoStream, EventType "ReplayEvent", Aeson.toJSON (21 :: Int64)),
      (StreamName "customers-1", AnyVersion, EventType "ReplayEvent", Aeson.toJSON (22 :: Int64)),
      (StreamName "customers-1", AnyVersion, EventType "ReplayEvent", Aeson.toJSON (23 :: Int64)),
      (StreamName "padding-1", NoStream, EventType "PaddingEvent", Aeson.Null),
      (StreamName "padding-1", AnyVersion, EventType "PaddingEvent", Aeson.Null),
      (StreamName "customers-1", AnyVersion, EventType "ReplayEvent", Aeson.toJSON (24 :: Int64)),
      (StreamName "orders-1", AnyVersion, EventType "ReplayEvent", Aeson.toJSON (12 :: Int64)),
      (StreamName "orders-1", AnyVersion, EventType "ReplayEvent", Aeson.toJSON (13 :: Int64))
    ]

sweepStep :: Word64 -> Word64
sweepStep seed = seed Prelude.* 6364136223846793005 Prelude.+ 1442695040888963407

sweepCategories :: Word64 -> Int -> [Text]
sweepCategories seed count =
  Prelude.take
    count
    [ ["orders", "customers", "billing", "padding"]
        Prelude.!! Prelude.fromIntegral ((state `Prelude.div` 7) `Prelude.mod` 4)
    | state <- Prelude.iterate sweepStep (sweepStep seed)
    ]

appendSweep :: Store.KirokuStore -> Word64 -> Int -> IO [Int64]
appendSweep store seed count = go Map.empty [] indexedCategories
  where
    indexedCategories = Prelude.zip ([1 ..] :: [Int64]) (sweepCategories seed count)

    go _ expected [] = pure (Prelude.reverse expected)
    go seen expected ((position, category) : remaining) = do
      appendRaw
        store
        ( StreamName (category <> "-sweep"),
          if Map.member category seen then AnyVersion else NoStream,
          if category == "padding" then EventType "PaddingEvent" else EventType "ReplayEvent",
          if category == "padding" then Aeson.Null else Aeson.toJSON position
        )
      go
        (Map.insert category () seen)
        (if category == "padding" then expected else position : expected)
        remaining

appendCountingFixture :: Store.KirokuStore -> IO ()
appendCountingFixture store =
  traverse_ (appendRaw store) (Prelude.concatMap eventsForRound ([1 .. 6] :: [Int]))
  where
    eventsForRound roundNo =
      [ event "orders" 10,
        event "customers" 20,
        event "billing" 30
      ]
      where
        event category offset =
          ( StreamName (category <> "-counted"),
            if roundNo == 1 then NoStream else AnyVersion,
            EventType "ReplayEvent",
            Aeson.toJSON (Prelude.fromIntegral (roundNo Prelude.* 100 Prelude.+ offset) :: Int64)
          )

data StoreReadCounts = StoreReadCounts
  { categoryPageReads :: !(Map CategoryName (Int, Int)),
    allPageReads :: !(Int, Int)
  }
  deriving stock (Eq, Show, Generic)

emptyStoreReadCounts :: StoreReadCounts
emptyStoreReadCounts = StoreReadCounts Map.empty (0, 0)

countStoreReads ::
  (Store :> es, IOE :> es) =>
  IORef StoreReadCounts ->
  Eff es value ->
  Eff es value
countStoreReads reads = interpose @Store $ \environment operation ->
  case operation of
    StoreEffect.ReadCategoryForward category _ _ -> do
      events <- passthrough environment operation
      liftIO
        $ modifyIORef' reads
        $ \counts ->
          counts
            { categoryPageReads =
                Map.insertWith addReads category (1, Vector.length events) (counts ^. #categoryPageReads)
            }
      pure events
    StoreEffect.ReadAllForward {} -> do
      events <- passthrough environment operation
      liftIO
        $ modifyIORef' reads
        $ \counts ->
          counts {allPageReads = addReads (1, Vector.length events) (counts ^. #allPageReads)}
      pure events
    _ -> passthrough environment operation
  where
    addReads (newCalls, newEvents) (oldCalls, oldEvents) =
      (newCalls Prelude.+ oldCalls, newEvents Prelude.+ oldEvents)

appendRaw :: Store.KirokuStore -> (StreamName, ExpectedVersion, EventType, Aeson.Value) -> IO ()
appendRaw store (streamName, expectedVersion, eventType, payload) = do
  result <-
    Store.runStoreIO store
      $ Store.appendToStream
        streamName
        expectedVersion
        [ EventData
            { eventId = Nothing,
              eventType,
              payload,
              metadata = Nothing,
              causationId = Nothing,
              correlationId = Nothing
            }
        ]
  result `shouldSatisfy` isRight

options :: Text -> Int32 -> RebuildOptions
options runName pageSize =
  (defaultRebuildOptions (request runName)) {replayPageSize = pageSize}

request :: Text -> RebuildRequest
request runName =
  RebuildRequest
    { rebuildRunId = runId runName,
      requestedBy = "projection-replay-spec",
      requestReason = "integration proof",
      replayFrom = GlobalPosition 0
    }

runId :: Text -> RebuildRunId
runId runName =
  either (error . Text.unpack) Prelude.id (mkRebuildRunId runName)

expectValid :: ProjectionCatalog -> IO ValidatedProjectionCatalog
expectValid catalog =
  case validateProjectionCatalog catalog of
    Success validated -> pure validated
    Failure diagnostics -> expectationFailure (show diagnostics) >> error "unreachable"

expectStore ::
  Store.KirokuStore ->
  Eff '[Store, Error StoreError, IOE] value ->
  IO value
expectStore store action =
  Store.runStoreIO store action >>= \case
    Left err -> expectationFailure ("store action failed: " <> show err) >> error "unreachable"
    Right value -> pure value

shouldBeRight :: (Show err) => Either err value -> IO value
shouldBeRight = \case
  Left err -> expectationFailure ("expected Right, got Left " <> show err) >> error "unreachable"
  Right value -> pure value

identity :: (Text -> Either CatalogIdentityError value) -> Text -> value
identity constructor raw = either (error . show) Prelude.id (constructor raw)

site :: Text -> ClaimSite
site = identity mkClaimSite

ordersSourceId, customersSourceId, billingSourceId :: SourceId
ordersSourceId = identity mkSourceId "orders-source"
customersSourceId = identity mkSourceId "customers-source"
billingSourceId = identity mkSourceId "billing-source"

traceTargetId, ordersTargetId, customersTargetId, billingTargetId :: TargetId
traceTargetId = identity mkTargetId "replay-trace"
ordersTargetId = identity mkTargetId "orders-projection"
customersTargetId = identity mkTargetId "customers-projection"
billingTargetId = identity mkTargetId "billing-projection"

ordersProjectionId, customersProjectionId, billingProjectionId :: ProjectionId
ordersProjectionId = identity mkProjectionId "orders-projection"
customersProjectionId = identity mkProjectionId "customers-projection"
billingProjectionId = identity mkProjectionId "billing-projection"

replayGroupId :: RebuildGroupId
replayGroupId = identity mkRebuildGroupId "replay-group"

replayFixtureSql :: ByteString
replayFixtureSql =
  """
  CREATE SCHEMA app;
  CREATE TABLE app.replay_trace (
    sequence bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    global_position bigint NOT NULL UNIQUE,
    source text NOT NULL,
    value bigint NOT NULL
  );
  CREATE TABLE app.orders_projection (global_position bigint PRIMARY KEY, value bigint NOT NULL);
  CREATE TABLE app.customers_projection (global_position bigint PRIMARY KEY, value bigint NOT NULL);
  CREATE TABLE app.billing_projection (global_position bigint PRIMARY KEY, value bigint NOT NULL);
  """

insertTraceStmt :: Statement (Int64, Text, Int64) ()
insertTraceStmt =
  preparable
    "INSERT INTO app.replay_trace (global_position, source, value) VALUES ($1, $2, $3)"
    (contrazip3 (E.param (E.nonNullable E.int8)) (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.int8)))
    D.noResult

ordersInsertStmt, customersInsertStmt, billingInsertStmt :: Statement (Int64, Int64) ()
ordersInsertStmt = targetInsertStmt "orders_projection"
customersInsertStmt = targetInsertStmt "customers_projection"
billingInsertStmt = targetInsertStmt "billing_projection"

targetInsertStmt :: Text -> Statement (Int64, Int64) ()
targetInsertStmt tableName =
  preparable
    ("INSERT INTO app." <> tableName <> " (global_position, value) VALUES ($1, $2)")
    (contrazip2 (E.param (E.nonNullable E.int8)) (E.param (E.nonNullable E.int8)))
    D.noResult

tracePositionsStmt :: Statement () [Int64]
tracePositionsStmt =
  preparable
    "SELECT global_position FROM app.replay_trace ORDER BY sequence"
    E.noParams
    (D.rowList (D.column (D.nonNullable D.int8)))

ordersPositionsStmt :: Statement () [Int64]
ordersPositionsStmt =
  preparable
    "SELECT global_position FROM app.orders_projection ORDER BY global_position"
    E.noParams
    (D.rowList (D.column (D.nonNullable D.int8)))

deleteAdapterStmt :: Statement Text ()
deleteAdapterStmt =
  preparable
    """
    DELETE FROM keiro.keiro_projection_rebuild_adapters
    WHERE run_id = $1 AND projection_id = 'billing-projection'
    """
    (E.param (E.nonNullable E.text))
    D.noResult

setRunContractStmt :: Statement (Text, Text, Text) ()
setRunContractStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_runs
    SET contract_fingerprint = $2,
        runner_format = $3
    WHERE run_id = $1
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    D.noResult
