{-# LANGUAGE MultilineStrings #-}

module GroupRebuildSpec
  ( spec,
  )
where

import CatalogSpec qualified as Catalog
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Either (isLeft, isRight)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), diffUTCTime, secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID (fromWords64)
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import Keiro.Projection
  ( CatalogAsyncApplyOutcome (..),
    applyAsyncProjectionFromCatalog,
  )
import Keiro.Projection.Catalog
import Keiro.Projection.Catalog qualified as ProjectionCatalog
import Keiro.ReadModel (lookupReadModel)
import Keiro.ReadModel.Rebuild
import Keiro.Test.Postgres (Fixture, withFreshStore)
import Kiroku.Store qualified as Store
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types
  ( EventId (..),
    EventType (..),
    GlobalPosition (..),
    RecordedEvent (..),
    StreamId (..),
    StreamVersion (..),
  )
import Test.Hspec
import "hasql-transaction" Hasql.Transaction qualified as Tx

spec :: Fixture -> Spec
spec fixture = describe "catalog rebuild groups" $ around (withFreshStore fixture) $ do
  it "registers a validated fleet atomically and refuses fingerprint drift" $ \store -> do
    validated <- expectValid Catalog.validCatalog
    groups <- expectStore store (registerProjectionCatalog validated) >>= shouldBeRight
    map (^. #rebuildGroupId) groups `shouldBe` [Catalog.mainGroupId]
    counter <- expectStore store (lookupReadModel "catalog-counter-query")
    counter ^? _Just . #rebuildGroupId
      `shouldBe` Just (rebuildGroupIdText Catalog.mainGroupId)

    registeredAgain <- expectStore store (registerProjectionCatalog validated)
    registeredAgain `shouldSatisfy` isRight

    drifted <- expectValid (catalogWithCodecFingerprint "counter-codec-v2")
    drift <- expectStore store (registerProjectionCatalog drifted)
    drift `shouldSatisfy` \case
      Left RegisteredGroupFingerprintDrift {} -> True
      _ -> False
    stored <- expectStore store (lookupProjectionRebuildGroup Catalog.mainGroupId)
    stored ^? _Just . #catalogFingerprint
      `shouldBe` Just (catalogFingerprintText (ProjectionCatalog.catalogFingerprint validated))

  it "prepares a mixed preserve-parent/clear-child group and derives reset state" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql mixedFixtureSql))
    validated <- expectValid mixedPolicyCatalog
    _ <- expectStore store (registerProjectionCatalog validated) >>= shouldBeRight
    started <-
      expectStore
        store
        (beginGroupRebuild validated Catalog.mainGroupId (request "mixed-run" (GlobalPosition 3)))
        >>= shouldBeRight

    groupRebuildHandlePreparation started
      `shouldBe` GroupPreparation
        { clearTargets = [QualifiedTable "app" "counter_audit"],
          preservedTargets = [QualifiedTable "app" "counter"],
          resetDedupNames = ["catalog-async"],
          resetSubscriptionNames = ["catalog-async-subscription"]
        }
    facts <- expectStore store (Store.runTransaction (Tx.statement () preparationFactsStmt))
    facts `shouldBe` (1, 0, 0, 3)

    fenced <-
      expectStore
        store
        ( Store.runTransaction
            (applyAsyncProjectionFromCatalog validated Catalog.asyncProjectionId Catalog.catalogAsyncProjection sampleRecorded)
        )
    fenced
      `shouldBe` CatalogAsyncFenced Catalog.mainGroupId (runId "mixed-run")
    expectStore store (Store.runTransaction (Tx.statement () preparationFactsStmt))
      `shouldReturn` (1, 0, 0, 3)

    abandoned <-
      expectStore
        store
        (abandonGroupRebuild started (RebuildFailure "verification-failed" "row count mismatch"))
        >>= shouldBeRight
    abandoned ^. #status `shouldBe` GroupFailed
    abandoned ^. #failureCode `shouldBe` Just "verification-failed"
    secondAbandon <-
      expectStore
        store
        (abandonGroupRebuild started (RebuildFailure "again" "must not replace evidence"))
    secondAbandon
      `shouldBe` Left (RebuildHandleNoLongerActive Catalog.mainGroupId (runId "mixed-run"))

  it "clears a foreign-key parent and child through one multi-table truncate" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql clearFixtureSql))
    validated <- expectValid allClearCatalog
    _ <- expectStore store (registerProjectionCatalog validated) >>= shouldBeRight
    _ <-
      expectStore
        store
        (beginGroupRebuild validated Catalog.mainGroupId (request "clear-run" (GlobalPosition 0)))
        >>= shouldBeRight
    expectStore store (Store.runTransaction (Tx.statement () targetCountsStmt))
      `shouldReturn` (0, 0)

  it "rolls preparation back when an undeclared foreign key blocks truncate" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql blockedFixtureSql))
    validated <- expectValid allClearCatalog
    _ <- expectStore store (registerProjectionCatalog validated) >>= shouldBeRight
    started <-
      Store.runStoreIO
        store
        (beginGroupRebuild validated Catalog.mainGroupId (request "blocked-run" (GlobalPosition 0)))
    started `shouldSatisfy` isLeft
    expectStore store (Store.runTransaction (Tx.statement () blockedFactsStmt))
      `shouldReturn` (1, 1, 1, "live")

  it "waits for an in-flight async apply before preparing the group" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql clearFixtureSql))
    validated <- expectValid allClearCatalog
    _ <- expectStore store (registerProjectionCatalog validated) >>= shouldBeRight
    let slowProjection =
          Catalog.catalogAsyncProjection
            & #applyRecorded
            .~ (\_ -> Tx.sql "SELECT pg_sleep(1)")
    writerDone <- newEmptyMVar
    _ <-
      forkIO $
        Store.runStoreIO
          store
          ( Store.runTransaction
              (applyAsyncProjectionFromCatalog validated Catalog.asyncProjectionId slowProjection sampleRecorded)
          )
          >>= putMVar writerDone
    threadDelay 200_000
    startedAt <- getCurrentTime
    _ <-
      expectStore
        store
        (beginGroupRebuild validated Catalog.mainGroupId (request "async-lock-run" (GlobalPosition 0)))
        >>= shouldBeRight
    finishedAt <- getCurrentTime

    takeMVar writerDone `shouldReturn` Right CatalogAsyncApplied
    diffUTCTime finishedAt startedAt `shouldSatisfy` (> 0.5)
    expectStore store (Store.runTransaction (Tx.statement () targetCountsStmt))
      `shouldReturn` (0, 0)

expectValid :: ProjectionCatalog -> IO ValidatedProjectionCatalog
expectValid catalog =
  case validateProjectionCatalog catalog of
    Success validated -> pure validated
    Failure diagnostics ->
      expectationFailure ("expected valid catalog, got " <> show diagnostics)
        >> error "unreachable"

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

catalogWithCodecFingerprint :: Text -> ProjectionCatalog
catalogWithCodecFingerprint fingerprint =
  Catalog.validCatalog
    { sources =
        [ source & #codecFingerprint .~ fingerprint
        | source <- Catalog.validCatalog ^. #sources
        ]
    }

mixedPolicyCatalog :: ProjectionCatalog
mixedPolicyCatalog =
  Catalog.validCatalog
    { targets =
        [ if target ^. #targetId == Catalog.counterTargetId
            then target & #resetPolicy .~ PreserveAndReconcile
            else target & #resetPolicy .~ ClearBeforeReplay
        | target <- Catalog.validCatalog ^. #targets
        ]
    }

allClearCatalog :: ProjectionCatalog
allClearCatalog =
  Catalog.validCatalog
    { targets =
        [ target & #resetPolicy .~ ClearBeforeReplay
        | target <- Catalog.validCatalog ^. #targets
        ]
    }

request :: Text -> GlobalPosition -> RebuildRequest
request identity position =
  RebuildRequest
    { rebuildRunId = runId identity,
      requestedBy = "group-rebuild-spec",
      requestReason = "integration proof",
      replayFrom = position
    }

runId :: Text -> RebuildRunId
runId identity =
  case mkRebuildRunId identity of
    Left err -> error (Text.unpack err)
    Right value -> value

sampleRecorded :: RecordedEvent
sampleRecorded =
  RecordedEvent
    { eventId = EventId (fromWords64 1 2),
      eventType = EventType "CatalogEvent",
      streamVersion = StreamVersion 1,
      globalPosition = GlobalPosition 1,
      originalStreamId = StreamId 1,
      originalVersion = StreamVersion 1,
      payload = Aeson.Null,
      metadata = Just (Aeson.object []),
      causationId = Nothing,
      correlationId = Nothing,
      createdAt = UTCTime (ModifiedJulianDay 0) (secondsToDiffTime 0)
    }

mixedFixtureSql :: ByteString
mixedFixtureSql =
  """
  CREATE SCHEMA app;
  CREATE TABLE app.counter (id bigint PRIMARY KEY);
  CREATE TABLE app.counter_audit (
    id bigint PRIMARY KEY,
    counter_id bigint NOT NULL REFERENCES app.counter(id)
  );
  INSERT INTO app.counter VALUES (1);
  INSERT INTO app.counter_audit VALUES (1, 1);
  INSERT INTO keiro.keiro_projection_dedup (projection_name, event_id)
  VALUES ('catalog-async', '00000000-0000-0000-0000-000000000001');
  INSERT INTO subscriptions (subscription_name, last_seen)
  VALUES ('catalog-async-subscription', 50);
  """

clearFixtureSql :: ByteString
clearFixtureSql =
  """
  CREATE SCHEMA app;
  CREATE TABLE app.counter (id bigint PRIMARY KEY);
  CREATE TABLE app.counter_audit (
    id bigint PRIMARY KEY,
    counter_id bigint NOT NULL REFERENCES app.counter(id)
  );
  INSERT INTO app.counter VALUES (1);
  INSERT INTO app.counter_audit VALUES (1, 1);
  """

blockedFixtureSql :: ByteString
blockedFixtureSql =
  """
  CREATE SCHEMA app;
  CREATE TABLE app.counter (id bigint PRIMARY KEY);
  CREATE TABLE app.counter_audit (
    id bigint PRIMARY KEY,
    counter_id bigint NOT NULL REFERENCES app.counter(id)
  );
  CREATE TABLE app.external_ref (
    id bigint PRIMARY KEY,
    counter_id bigint NOT NULL REFERENCES app.counter(id)
  );
  INSERT INTO app.counter VALUES (1);
  INSERT INTO app.counter_audit VALUES (1, 1);
  INSERT INTO app.external_ref VALUES (1, 1);
  """

preparationFactsStmt :: Statement () (Int64, Int64, Int64, Int64)
preparationFactsStmt =
  preparable
    """
    SELECT
      (SELECT count(*) FROM app.counter),
      (SELECT count(*) FROM app.counter_audit),
      (SELECT count(*) FROM keiro.keiro_projection_dedup WHERE projection_name = 'catalog-async'),
      (SELECT last_seen FROM subscriptions WHERE subscription_name = 'catalog-async-subscription')
    """
    E.noParams
    ( D.singleRow
        ( (,,,)
            <$> int8Column
            <*> int8Column
            <*> int8Column
            <*> int8Column
        )
    )

targetCountsStmt :: Statement () (Int64, Int64)
targetCountsStmt =
  preparable
    """
    SELECT
      (SELECT count(*) FROM app.counter),
      (SELECT count(*) FROM app.counter_audit)
    """
    E.noParams
    (D.singleRow ((,) <$> int8Column <*> int8Column))

blockedFactsStmt :: Statement () (Int64, Int64, Int64, Text)
blockedFactsStmt =
  preparable
    """
    SELECT
      (SELECT count(*) FROM app.counter),
      (SELECT count(*) FROM app.counter_audit),
      (SELECT count(*) FROM app.external_ref),
      (SELECT status FROM keiro.keiro_projection_rebuild_groups WHERE group_id = 'counter-group')
    """
    E.noParams
    ( D.singleRow
        ( (,,,)
            <$> int8Column
            <*> int8Column
            <*> int8Column
            <*> D.column (D.nonNullable D.text)
        )
    )

int8Column :: D.Row Int64
int8Column = D.column (D.nonNullable D.int8)
