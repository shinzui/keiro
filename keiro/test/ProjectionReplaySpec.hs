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
import Keiro.Projection
  ( AsyncProjection (..),
    CatalogAsyncApplyOutcome (..),
    InlineProjection (..),
    applyAsyncProjectionFromCatalog,
  )
import Keiro.Projection.Catalog
import Keiro.Projection.Catalog qualified as CatalogApi
import Keiro.ReadModel (ConsistencyMode (..), ReadModel (..), StrongScope (..))
import Keiro.ReadModel.Rebuild
import Keiro.Test.Postgres (Fixture, withFreshStore)
import Kiroku.Store qualified as Store
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect qualified as StoreEffect
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Subscription.Types (MissingCheckpointPolicy (..), SubscriptionName (..))
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
spec fixture = do
  catalogReplaySpec fixture
  redeliverySpec fixture

catalogReplaySpec :: Fixture -> Spec
catalogReplaySpec fixture = describe "catalog replay runner" $ around (withFreshStore fixture) $ do
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

  it "refuses to resume after replay-adapter declaration order changes" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql pairFixtureSql))
    appendPairEvents store
    interrupted <- expectValid (pairCatalog False failAtThirdPosition)
    _ <- expectStore store (registerProjectionCatalog interrupted) >>= shouldBeRight
    first <- expectStore store (startCatalogRebuild interrupted pairGroupId (options "order-swap-run" 2))
    first `shouldSatisfy` \case
      Left CatalogRebuildDecodeFailed {} -> True
      _ -> False
    expectStore store (Store.runTransaction (Tx.statement () pairTraceStmt))
      `shouldReturn` [(1, "first"), (1, "second"), (2, "first"), (2, "second")]

    reordered <- expectValid (pairCatalog True goodDecoder)
    CatalogApi.groupSliceFingerprint reordered pairGroupId
      `shouldBe` CatalogApi.groupSliceFingerprint interrupted pairGroupId
    resumeResult <-
      expectStore store (resumeCatalogRebuild reordered (runId "order-swap-run") (options "ignored" 2))
    resumeResult `shouldSatisfy` \case
      Left (CatalogRebuildContractMismatch mismatchedRun expected actual) ->
        mismatchedRun
          == runId "order-swap-run"
          && Text.isPrefixOf "contract-v4:" expected
          && Text.isPrefixOf "contract-v4:" actual
          && expected /= actual
      _ -> False

  it "resumes an interrupted two-adapter rebuild when declaration order is unchanged" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql pairFixtureSql))
    appendPairEvents store
    interrupted <- expectValid (pairCatalog False failAtThirdPosition)
    _ <- expectStore store (registerProjectionCatalog interrupted) >>= shouldBeRight
    _ <- expectStore store (startCatalogRebuild interrupted pairGroupId (options "order-keep-run" 2))
    repaired <- expectValid (pairCatalog False goodDecoder)
    resumed <-
      expectStore store (resumeCatalogRebuild repaired (runId "order-keep-run") (options "ignored" 2))
        >>= shouldBeRight
    resumed ^. #runStatus `shouldBe` RebuildRunPromoted
    expectStore store (Store.runTransaction (Tx.statement () pairTraceStmt))
      `shouldReturn` [ (position, label)
                     | position <- [1 .. 4],
                       label <- ["first", "second"]
                     ]

  it "keeps an order swap registration-compatible and abandonable but refuses drifted abandon" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql pairFixtureSql))
    appendPairEvents store
    interrupted <- expectValid (pairCatalog False failAtThirdPosition)
    _ <- expectStore store (registerProjectionCatalog interrupted) >>= shouldBeRight
    _ <- expectStore store (startCatalogRebuild interrupted pairGroupId (options "order-abandon-run" 2))

    drifted <-
      expectValid
        ((pairCatalog True goodDecoder) & #sources . ix 0 . #codecFingerprint .~ "pair-v2")
    driftedAbandon <-
      expectStore
        store
        (abandonCatalogRebuild drifted (runId "order-abandon-run") (RebuildFailure "operator.abandoned" "drift probe"))
    driftedAbandon `shouldSatisfy` \case
      Left CatalogRebuildSliceMismatch {} -> True
      _ -> False

    reordered <- expectValid (pairCatalog True goodDecoder)
    _ <- expectStore store (registerProjectionCatalog reordered) >>= shouldBeRight
    abandoned <-
      expectStore
        store
        (abandonCatalogRebuild reordered (runId "order-abandon-run") (RebuildFailure "operator.abandoned" "declaration order changed"))
        >>= shouldBeRight
    abandoned ^. #runStatus `shouldBe` RebuildRunFailed
    group <- expectStore store (lookupProjectionRebuildGroup pairGroupId)
    group ^? _Just . #status `shouldBe` Just GroupFailed

  it "applies replay-adapter effects in declaration order" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql pairFixtureSql))
    appendPairEvents store
    reordered <- expectValid (pairCatalog True goodDecoder)
    _ <- expectStore store (registerProjectionCatalog reordered) >>= shouldBeRight
    report <-
      expectStore store (startCatalogRebuild reordered pairGroupId (options "order-scratch-run" 2))
        >>= shouldBeRight
    report ^. #runStatus `shouldBe` RebuildRunPromoted
    expectStore store (Store.runTransaction (Tx.statement () pairTraceStmt))
      `shouldReturn` [ (position, label)
                     | position <- [1 .. 4],
                       label <- ["second", "first"]
                     ]

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

  it "refuses to resume a stale replay contract under the v4 runner" $ \store -> do
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
          && Text.isPrefixOf "contract-v4:" actual
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

redeliverySpec :: Fixture -> Spec
redeliverySpec fixture =
  describe "catalog rebuild promotion redelivery"
    $ around (withFreshStore fixture)
    $ do
      it "promotion leaves redelivery safe for a clear-before-replay async projection" $ \store -> do
        expectStore store (Store.runTransaction (Tx.sql redeliveryFixtureSql))
        events <- appendAuditEvents store
        validated <- expectValid (redeliveryCatalog ClearAuditTotals passingVerification)
        case catalogAsyncIdempotencyKeys validated auditGroupId of
          [dedupSpec] ->
            ( dedupSpec ^. #specSubscriptionName,
              dedupSpec ^. #specDedupName,
              dedupSpec ^. #specSourceId,
              dedupSpec ^. #specSourceScope
            )
              `shouldBe` ( "audit-subscription",
                           "audit-async",
                           auditSourceId,
                           CategorySource (CategoryName "audit")
                         )
          specs -> expectationFailure ("unexpected async dedup specs: " <> show (Prelude.length specs))
        liveOnly <-
          expectValid (redeliveryCatalogWithReplayability PreserveAuditEntries passingVerification False)
        Prelude.null (catalogAsyncIdempotencyKeys liveOnly auditGroupId) `shouldBe` True
        _ <- expectStore store (registerProjectionCatalog validated) >>= shouldBeRight
        liveApplyAuditEvents store validated auditTotalsProjection events
        expectStore store (Store.runTransaction (Tx.statement () auditTotalStmt))
          `shouldReturn` 60
        expectStore store (Store.runTransaction (Tx.statement "audit-async" auditDedupCountStmt))
          `shouldReturn` 3

        report <-
          expectStore
            store
            (startCatalogRebuild validated auditGroupId (options "redelivery-clear-run" 2))
            >>= shouldBeRight
        report ^. #runStatus `shouldBe` RebuildRunPromoted
        outcomes <- redeliverAuditEvents store validated auditTotalsProjection events
        total <- expectStore store (Store.runTransaction (Tx.statement () auditTotalStmt))
        checkpoints <- expectStore store (Store.runTransaction (Tx.statement () auditCheckpointsStmt))
        dedupCount <- expectStore store (Store.runTransaction (Tx.statement "audit-async" auditDedupCountStmt))
        let GlobalPosition capturedHead = report ^. #capturedHead
        (outcomes, total, checkpoints, dedupCount)
          `shouldBe` ( replicate 3 CatalogAsyncDuplicate,
                       60,
                       replicate 2 capturedHead,
                       3
                     )
        secondOutcomes <- redeliverAuditEvents store validated auditTotalsProjection events
        secondTotal <- expectStore store (Store.runTransaction (Tx.statement () auditTotalStmt))
        (secondOutcomes, secondTotal)
          `shouldBe` (replicate 3 CatalogAsyncDuplicate, 60)

      it "promotion leaves redelivery safe for a preserve-and-reconcile async projection" $ \store -> do
        expectStore store (Store.runTransaction (Tx.sql redeliveryFixtureSql))
        events <- appendAuditEvents store
        validated <- expectValid (redeliveryCatalog PreserveAuditEntries passingVerification)
        _ <- expectStore store (registerProjectionCatalog validated) >>= shouldBeRight
        liveApplyAuditEvents store validated auditEntriesProjection events

        report <-
          expectStore
            store
            (startCatalogRebuild validated auditGroupId (options "redelivery-preserve-run" 2))
            >>= shouldBeRight
        report ^. #runStatus `shouldBe` RebuildRunPromoted
        outcomes <- redeliverAuditEvents store validated auditEntriesProjection events
        liveApplies <- expectStore store (Store.runTransaction (Tx.statement () auditEntryAppliesStmt))
        (outcomes, liveApplies)
          `shouldBe` (replicate 3 CatalogAsyncDuplicate, replicate 3 1)

      it "resumes a verification failure with redelivery safety and an honest fence" $ \store -> do
        expectStore store (Store.runTransaction (Tx.sql redeliveryFixtureSql))
        events <- appendAuditEvents store
        faulted <- expectValid (redeliveryCatalog ClearAuditTotals failingVerification)
        _ <- expectStore store (registerProjectionCatalog faulted) >>= shouldBeRight
        liveApplyAuditEvents store faulted auditTotalsProjection events
        (firstEvent, lastEvent) <-
          case events of
            [first, _, last] -> pure (first, last)
            _ -> expectationFailure "expected exactly three audit events" >> error "unreachable"
        let GlobalPosition capturedHead = lastEvent ^. #globalPosition
            slowerFloor = GlobalPosition (capturedHead Prelude.- 1)
        expectStore
          store
          ( Store.runTransaction
              (Tx.statement ("audit-subscription", 1, capturedHead Prelude.- 1) setAuditMemberCheckpointStmt)
          )
        beforeRebuild <-
          expectStore store (collectAsyncDedupBackfill faulted auditGroupId 2 (GlobalPosition capturedHead))
            >>= shouldBeRight
        (beforeRebuild ^. #backfillFloors, Prelude.length (beforeRebuild ^. #backfillPairs))
          `shouldBe` ([("audit-subscription", slowerFloor)], 1)

        failed <-
          expectStore
            store
            (startCatalogRebuild faulted auditGroupId (options "redelivery-resume-run" 2))
        case failed of
          Left (CatalogRebuildVerificationFailed failedRun _ _) ->
            failedRun `shouldBe` runId "redelivery-resume-run"
          other -> expectationFailure ("expected verification failure, got " <> show other)
        failedReport <-
          expectStore store (inspectCatalogRebuild (runId "redelivery-resume-run"))
            >>= shouldBeRight
        failedReport ^. #runStatus `shouldBe` RebuildRunFailed
        group <- expectStore store (lookupProjectionRebuildGroup auditGroupId)
        fmap (^. #status) group `shouldBe` Just GroupRebuilding
        expectStore store (Store.runTransaction (Tx.statement () auditCheckpointsStmt))
          `shouldReturn` [0, 0]
        expectStore store (Store.runTransaction (Tx.statement "audit-async" auditDedupCountStmt))
          `shouldReturn` 0
        fenced <-
          expectStore
            store
            ( Store.runTransaction
                (applyAsyncProjectionFromCatalog faulted auditProjectionId auditTotalsProjection firstEvent)
            )
        fenced `shouldBe` CatalogAsyncFenced auditGroupId (runId "redelivery-resume-run")

        repaired <- expectValid (redeliveryCatalog ClearAuditTotals passingVerification)
        report <-
          expectStore
            store
            (resumeCatalogRebuild repaired (runId "redelivery-resume-run") (options "ignored" 2))
            >>= shouldBeRight
        report ^. #runStatus `shouldBe` RebuildRunPromoted
        firstOutcomes <- redeliverAuditEvents store repaired auditTotalsProjection events
        secondOutcomes <- redeliverAuditEvents store repaired auditTotalsProjection events
        total <- expectStore store (Store.runTransaction (Tx.statement () auditTotalStmt))
        checkpoints <- expectStore store (Store.runTransaction (Tx.statement () auditCheckpointsStmt))
        dedupCount <- expectStore store (Store.runTransaction (Tx.statement "audit-async" auditDedupCountStmt))
        (firstOutcomes, secondOutcomes, total, checkpoints, dedupCount)
          `shouldBe` ( replicate 3 CatalogAsyncDuplicate,
                       replicate 3 CatalogAsyncDuplicate,
                       60,
                       replicate 2 capturedHead,
                       3
                     )

      it "reports vanished checkpoint rows and resumes promotion after repair" $ \store -> do
        expectStore store (Store.runTransaction (Tx.sql redeliveryFixtureSql))
        events <- appendAuditEvents store
        deleting <- expectValid (redeliveryCatalog ClearAuditTotals deletingVerification)
        _ <- expectStore store (registerProjectionCatalog deleting) >>= shouldBeRight
        liveApplyAuditEvents store deleting auditTotalsProjection events

        failed <-
          expectStore
            store
            (startCatalogRebuild deleting auditGroupId (options "redelivery-missing-run" 2))
        case failed of
          Left (CatalogRebuildPromotionCheckpointsMissing failedRun missing) ->
            (failedRun, missing)
              `shouldBe` (runId "redelivery-missing-run", [SubscriptionName "audit-subscription"])
          other -> expectationFailure ("expected missing checkpoints, got " <> show other)
        failedReport <-
          expectStore store (inspectCatalogRebuild (runId "redelivery-missing-run"))
            >>= shouldBeRight
        (failedReport ^. #runStatus, failedReport ^. #failureEvidence . _Just . #failureCode)
          `shouldBe` (RebuildRunFailed, "promotion.checkpoints-missing")
        group <- expectStore store (lookupProjectionRebuildGroup auditGroupId)
        fmap (^. #status) group `shouldBe` Just GroupRebuilding

        expectStore store (Store.runTransaction (Tx.sql restoreAuditSubscriptionsSql))
        repaired <- expectValid (redeliveryCatalog ClearAuditTotals passingVerification)
        report <-
          expectStore
            store
            (resumeCatalogRebuild repaired (runId "redelivery-missing-run") (options "ignored" 2))
            >>= shouldBeRight
        outcomes <- redeliverAuditEvents store repaired auditTotalsProjection events
        total <- expectStore store (Store.runTransaction (Tx.statement () auditTotalStmt))
        checkpoints <- expectStore store (Store.runTransaction (Tx.statement () auditCheckpointsStmt))
        let GlobalPosition capturedHead = report ^. #capturedHead
        (report ^. #runStatus, outcomes, total, checkpoints)
          `shouldBe` (RebuildRunPromoted, replicate 3 CatalogAsyncDuplicate, 60, replicate 2 capturedHead)

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

deletingVerification :: RebuildVerification
deletingVerification =
  verificationWith
    (Tx.sql "DELETE FROM subscriptions WHERE subscription_name = 'audit-subscription'" >> pure (Right ()))

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

data AuditProjectionKind
  = ClearAuditTotals
  | PreserveAuditEntries

redeliveryCatalog :: AuditProjectionKind -> RebuildVerification -> ProjectionCatalog
redeliveryCatalog projectionKind verification =
  redeliveryCatalogWithReplayability projectionKind verification True

redeliveryCatalogWithReplayability :: AuditProjectionKind -> RebuildVerification -> Bool -> ProjectionCatalog
redeliveryCatalogWithReplayability projectionKind verification replayable =
  ProjectionCatalog
    { sources =
        [ SourceDeclaration
            { sourceId = auditSourceId,
              sourceScope = CategorySource (CategoryName "audit"),
              codecFingerprint = "audit-v1",
              claimSite = site "test:audit-source"
            }
        ],
      targets =
        [ TargetDeclaration
            { targetId = selectedTargetId,
              qualifiedTable = QualifiedTable "app" selectedTable,
              resetPolicy = selectedResetPolicy,
              dependsOn = [],
              claimSite = site "test:audit-target"
            }
        ],
      rebuildGroups =
        [ RebuildGroupDeclaration
            { rebuildGroupId = auditGroupId,
              orderedTargets = [selectedTargetId],
              verificationHooks = [verification],
              claimSite = site "test:audit-group"
            }
        ],
      subscriptions =
        [ SubscriptionDeclaration
            { subscriptionId = auditSubscriptionId,
              subscriptionName = "audit-subscription",
              subscriptionSource = auditSourceId,
              checkpointOnMissing = FromBeginning,
              claimSite = site "test:audit-subscription"
            }
        ],
      dedupKeys =
        [ DedupKeyDeclaration
            { dedupKeyId = auditDedupId,
              dedupName = "audit-async",
              claimSite = site "test:audit-dedup"
            }
        ],
      queryModels =
        [ SomeQueryModelBinding
            QueryModelBinding
              { queryModelId = auditQueryId,
                readModel = auditReadModel selectedTable,
                rebuildGroup = auditGroupId,
                observedTargets = [selectedTargetId],
                claimSite = site "test:audit-query"
              }
        ],
      projectionSets =
        [ SomeProjectionSet
            ProjectionSet
              { projectionSource = auditSourceId,
                projectionDefinitions =
                  ProjectionDefinition
                    { projectionId = auditProjectionId,
                      rebuildGroup = auditGroupId,
                      ownedTargets = selectedTargetId :| [],
                      replayPolicy =
                        if replayable
                          then Replayable (auditReplayAdapter projectionKind)
                          else LiveOnly (LiveOnlyReason "membership-test"),
                      handlers =
                        AsyncHandler selectedProjection auditSubscriptionId auditDedupId (site "test:audit-handler")
                          :| [],
                      claimSite = site "test:audit-projection"
                    }
                    :| [],
                claimSite = site "test:audit-set"
              }
        ]
    }
  where
    (selectedTargetId, selectedTable, selectedResetPolicy, selectedProjection) =
      case projectionKind of
        ClearAuditTotals ->
          (auditTotalsTargetId, "audit_totals", ClearBeforeReplay, auditTotalsProjection)
        PreserveAuditEntries ->
          (auditEntriesTargetId, "audit_entries", PreserveAndReconcile, auditEntriesProjection)

auditReplayAdapter :: AuditProjectionKind -> ReplayAdapter Int64
auditReplayAdapter projectionKind =
  ReplayAdapter
    { decodeForReplay = decodeAuditEvent,
      applyForReplay = \value recorded ->
        case projectionKind of
          ClearAuditTotals -> Tx.statement value addAuditTotalStmt
          PreserveAuditEntries ->
            let GlobalPosition position = recorded ^. #globalPosition
             in Tx.statement (position, value) reconcileAuditEntryStmt
    }

decodeAuditEvent :: RecordedEvent -> ReplayDecodeResult Int64
decodeAuditEvent recorded
  | recorded ^. #eventType /= EventType "AuditEvent" = ReplayIrrelevant
  | otherwise =
      case Aeson.fromJSON (recorded ^. #payload) of
        Aeson.Error detail -> ReplayDecodeFailure (ReplayDecodeError (Text.pack detail))
        Aeson.Success value -> ReplayRelevant value

auditTotalsProjection :: AsyncProjection
auditTotalsProjection =
  AsyncProjection
    { name = "audit-async",
      readModelName = "audit-query",
      subscriptionName = "audit-subscription",
      applyRecorded = \recorded -> Tx.statement (auditEventValue recorded) addAuditTotalStmt,
      idempotencyKey = (^. #eventId)
    }

auditEntriesProjection :: AsyncProjection
auditEntriesProjection =
  auditTotalsProjection
    { applyRecorded = \recorded ->
        let GlobalPosition position = recorded ^. #globalPosition
         in Tx.statement (position, auditEventValue recorded) applyAuditEntryStmt
    }

auditEventValue :: RecordedEvent -> Int64
auditEventValue recorded =
  case Aeson.fromJSON (recorded ^. #payload) of
    Aeson.Error detail -> error detail
    Aeson.Success value -> value

auditReadModel :: Text -> ReadModel Text ()
auditReadModel tableName =
  ReadModel
    { name = "audit-query",
      tableName,
      schema = "app",
      subscriptionName = "audit-subscription",
      version = 1,
      shapeHash = "audit-query-v1",
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \_ -> pure ()
    }

appendAuditEvents :: Store.KirokuStore -> IO [RecordedEvent]
appendAuditEvents store = do
  traverse_
    (appendRaw store)
    [ (StreamName "audit-1", NoStream, EventType "AuditEvent", Aeson.toJSON (10 :: Int64)),
      (StreamName "audit-1", AnyVersion, EventType "AuditEvent", Aeson.toJSON (20 :: Int64)),
      (StreamName "audit-1", AnyVersion, EventType "AuditEvent", Aeson.toJSON (30 :: Int64))
    ]
  Vector.toList
    <$> expectStore store (Store.readCategory (CategoryName "audit") (GlobalPosition 0) 100)

liveApplyAuditEvents ::
  Store.KirokuStore ->
  ValidatedProjectionCatalog ->
  AsyncProjection ->
  [RecordedEvent] ->
  IO ()
liveApplyAuditEvents store catalog projection events =
  for_ events $ \recorded -> do
    outcome <-
      expectStore
        store
        ( Store.runTransaction $ do
            applied <- applyAsyncProjectionFromCatalog catalog auditProjectionId projection recorded
            let GlobalPosition position = recorded ^. #globalPosition
            Tx.statement ("audit-subscription", position) setAuditCheckpointStmt
            pure applied
        )
    outcome `shouldBe` CatalogAsyncApplied

redeliverAuditEvents ::
  Store.KirokuStore ->
  ValidatedProjectionCatalog ->
  AsyncProjection ->
  [RecordedEvent] ->
  IO [CatalogAsyncApplyOutcome]
redeliverAuditEvents store catalog projection =
  traverse
    ( \recorded ->
        expectStore
          store
          ( Store.runTransaction
              (applyAsyncProjectionFromCatalog catalog auditProjectionId projection recorded)
          )
    )

pairCatalog :: Bool -> ReplayDecoder -> ProjectionCatalog
pairCatalog swapOrder decoder =
  ProjectionCatalog
    { sources =
        [ SourceDeclaration
            { sourceId = pairSourceId,
              sourceScope = CategorySource (CategoryName "pair"),
              codecFingerprint = "pair-v1",
              claimSite = site "test:source:pair"
            }
        ],
      targets =
        [ TargetDeclaration
            { targetId = pairTraceTargetId,
              qualifiedTable = QualifiedTable "app" "pair_trace",
              resetPolicy = ClearBeforeReplay,
              dependsOn = [],
              claimSite = site "test:target:pair-trace"
            },
          TargetDeclaration
            { targetId = pairSecondTargetId,
              qualifiedTable = QualifiedTable "app" "pair_second",
              resetPolicy = ClearBeforeReplay,
              dependsOn = [],
              claimSite = site "test:target:pair-second"
            }
        ],
      rebuildGroups =
        [ RebuildGroupDeclaration
            { rebuildGroupId = pairGroupId,
              orderedTargets = [pairTraceTargetId, pairSecondTargetId],
              verificationHooks = [],
              claimSite = site "test:pair-group"
            }
        ],
      subscriptions = [],
      dedupKeys = [],
      queryModels = [],
      projectionSets =
        [ SomeProjectionSet
            ProjectionSet
              { projectionSource = pairSourceId,
                projectionDefinitions =
                  if swapOrder
                    then secondDefinition :| [firstDefinition]
                    else firstDefinition :| [secondDefinition],
                claimSite = site "test:set:pair"
              }
        ]
    }
  where
    firstDefinition = pairDefinition "pair-first" pairTraceTargetId "first"
    secondDefinition = pairDefinition "pair-second" pairSecondTargetId "second"
    pairDefinition projectionName targetId label =
      ProjectionDefinition
        { projectionId = identity mkProjectionId projectionName,
          rebuildGroup = pairGroupId,
          ownedTargets = targetId :| [],
          replayPolicy =
            Replayable
              ReplayAdapter
                { decodeForReplay = decoder,
                  applyForReplay = applyPair label
                },
          handlers =
            InlineHandler
              InlineProjection {name = "live-" <> label, apply = \_ _ -> pure ()}
              (site ("test:handler:" <> label))
              :| [],
          claimSite = site ("test:projection:" <> label)
        }

applyPair :: Text -> ReplayEvent -> RecordedEvent -> Tx.Transaction ()
applyPair label (ReplayEvent value) recorded = do
  let GlobalPosition position = recorded ^. #globalPosition
  Tx.statement (position, label, value) insertPairTraceStmt

appendPairEvents :: Store.KirokuStore -> IO ()
appendPairEvents store =
  traverse_
    (appendRaw store)
    [ (StreamName "pair-1", NoStream, EventType "ReplayEvent", Aeson.toJSON (10 :: Int64)),
      (StreamName "pair-1", AnyVersion, EventType "ReplayEvent", Aeson.toJSON (20 :: Int64)),
      (StreamName "pair-1", AnyVersion, EventType "ReplayEvent", Aeson.toJSON (30 :: Int64)),
      (StreamName "pair-1", AnyVersion, EventType "ReplayEvent", Aeson.toJSON (40 :: Int64))
    ]

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

pairSourceId :: SourceId
pairSourceId = identity mkSourceId "pair-source"

pairTraceTargetId, pairSecondTargetId :: TargetId
pairTraceTargetId = identity mkTargetId "pair-trace"
pairSecondTargetId = identity mkTargetId "pair-second"

pairGroupId :: RebuildGroupId
pairGroupId = identity mkRebuildGroupId "pair-group"

auditSourceId :: SourceId
auditSourceId = identity mkSourceId "audit-source"

auditTotalsTargetId, auditEntriesTargetId :: TargetId
auditTotalsTargetId = identity mkTargetId "audit-totals-target"
auditEntriesTargetId = identity mkTargetId "audit-entries-target"

auditGroupId :: RebuildGroupId
auditGroupId = identity mkRebuildGroupId "audit-group"

auditProjectionId :: ProjectionId
auditProjectionId = identity mkProjectionId "audit-projection"

auditSubscriptionId :: SubscriptionId
auditSubscriptionId = identity mkSubscriptionId "audit-subscription-id"

auditDedupId :: DedupKeyId
auditDedupId = identity mkDedupKeyId "audit-dedup-id"

auditQueryId :: QueryModelId
auditQueryId = identity mkQueryModelId "audit-query-id"

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

pairFixtureSql :: ByteString
pairFixtureSql =
  """
  CREATE SCHEMA app;
  CREATE TABLE app.pair_trace (
    sequence bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    global_position bigint NOT NULL,
    projection text NOT NULL,
    value bigint NOT NULL
  );
  CREATE TABLE app.pair_second (global_position bigint PRIMARY KEY, value bigint NOT NULL);
  """

redeliveryFixtureSql :: ByteString
redeliveryFixtureSql =
  """
  CREATE SCHEMA app;
  CREATE TABLE app.audit_totals (
    id text PRIMARY KEY,
    total bigint NOT NULL
  );
  CREATE TABLE app.audit_entries (
    event_pos bigint PRIMARY KEY,
    value bigint NOT NULL,
    live_applies bigint NOT NULL
  );
  INSERT INTO subscriptions (
    subscription_name,
    consumer_group_member,
    consumer_group_size,
    last_seen
  ) VALUES
    ('audit-subscription', 0, 2, 0),
    ('audit-subscription', 1, 2, 0);
  """

restoreAuditSubscriptionsSql :: ByteString
restoreAuditSubscriptionsSql =
  """
  INSERT INTO subscriptions (
    subscription_name,
    consumer_group_member,
    consumer_group_size,
    last_seen
  ) VALUES
    ('audit-subscription', 0, 2, 0),
    ('audit-subscription', 1, 2, 0);
  """

insertTraceStmt :: Statement (Int64, Text, Int64) ()
insertTraceStmt =
  preparable
    "INSERT INTO app.replay_trace (global_position, source, value) VALUES ($1, $2, $3)"
    (contrazip3 (E.param (E.nonNullable E.int8)) (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.int8)))
    D.noResult

insertPairTraceStmt :: Statement (Int64, Text, Int64) ()
insertPairTraceStmt =
  preparable
    "INSERT INTO app.pair_trace (global_position, projection, value) VALUES ($1, $2, $3)"
    (contrazip3 (E.param (E.nonNullable E.int8)) (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.int8)))
    D.noResult

addAuditTotalStmt :: Statement Int64 ()
addAuditTotalStmt =
  preparable
    """
    INSERT INTO app.audit_totals (id, total) VALUES ('audit', $1)
    ON CONFLICT (id) DO UPDATE
      SET total = app.audit_totals.total + EXCLUDED.total
    """
    (E.param (E.nonNullable E.int8))
    D.noResult

applyAuditEntryStmt :: Statement (Int64, Int64) ()
applyAuditEntryStmt =
  preparable
    """
    INSERT INTO app.audit_entries (event_pos, value, live_applies)
    VALUES ($1, $2, 1)
    ON CONFLICT (event_pos) DO UPDATE
      SET live_applies = app.audit_entries.live_applies + 1
    """
    (contrazip2 (E.param (E.nonNullable E.int8)) (E.param (E.nonNullable E.int8)))
    D.noResult

reconcileAuditEntryStmt :: Statement (Int64, Int64) ()
reconcileAuditEntryStmt =
  preparable
    """
    INSERT INTO app.audit_entries (event_pos, value, live_applies)
    VALUES ($1, $2, 1)
    ON CONFLICT (event_pos) DO NOTHING
    """
    (contrazip2 (E.param (E.nonNullable E.int8)) (E.param (E.nonNullable E.int8)))
    D.noResult

setAuditCheckpointStmt :: Statement (Text, Int64) ()
setAuditCheckpointStmt =
  preparable
    """
    UPDATE subscriptions
    SET last_seen = $2,
        updated_at = now()
    WHERE subscription_name = $1
    """
    (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.int8)))
    D.noResult

setAuditMemberCheckpointStmt :: Statement (Text, Int32, Int64) ()
setAuditMemberCheckpointStmt =
  preparable
    """
    UPDATE subscriptions
    SET last_seen = $3,
        updated_at = now()
    WHERE subscription_name = $1
      AND consumer_group_member = $2
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int4))
        (E.param (E.nonNullable E.int8))
    )
    D.noResult

auditTotalStmt :: Statement () Int64
auditTotalStmt =
  preparable
    "SELECT COALESCE((SELECT total FROM app.audit_totals WHERE id = 'audit'), 0)"
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.int8)))

auditEntryAppliesStmt :: Statement () [Int64]
auditEntryAppliesStmt =
  preparable
    "SELECT live_applies FROM app.audit_entries ORDER BY event_pos"
    E.noParams
    (D.rowList (D.column (D.nonNullable D.int8)))

auditCheckpointsStmt :: Statement () [Int64]
auditCheckpointsStmt =
  preparable
    """
    SELECT last_seen
    FROM subscriptions
    WHERE subscription_name = 'audit-subscription'
    ORDER BY consumer_group_member
    """
    E.noParams
    (D.rowList (D.column (D.nonNullable D.int8)))

auditDedupCountStmt :: Statement Text Int64
auditDedupCountStmt =
  preparable
    """
    SELECT count(*)
    FROM keiro.keiro_projection_dedup
    WHERE projection_name = $1
    """
    (E.param (E.nonNullable E.text))
    (D.singleRow (D.column (D.nonNullable D.int8)))

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

pairTraceStmt :: Statement () [(Int64, Text)]
pairTraceStmt =
  preparable
    "SELECT global_position, projection FROM app.pair_trace ORDER BY sequence"
    E.noParams
    (D.rowList ((,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.text)))

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
