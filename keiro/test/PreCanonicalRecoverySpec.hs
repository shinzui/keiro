{-# LANGUAGE MultilineStrings #-}

module PreCanonicalRecoverySpec
  ( spec,
  )
where

import CatalogSpec qualified as Catalog
import Contravariant.Extras (contrazip2)
import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import Keiro.Projection.Catalog
import Keiro.Projection.Catalog qualified as CatalogApi
import Keiro.ReadModel (ReadModelStatus (Live), lookupReadModel)
import Keiro.ReadModel.Rebuild
import Keiro.Test.Postgres (Fixture, withFreshStore)
import Kiroku.Store qualified as Store
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types (GlobalPosition (..))
import Test.Hspec
import "hasql-transaction" Hasql.Transaction qualified as Tx

spec :: Fixture -> Spec
spec fixture = describe "pre-canonical rebuild recovery" $ around (withFreshStore fixture) $ do
  it "recovers a group stranded mid-rebuild by migration 0024" $ \store -> do
    healthy <- strandPreCanonicalRun store "recovery-run"
    let strandedRun = runId "recovery-run"
        legacySlice = Text.replicate 64 "a"

    expectStore store (registerProjectionCatalog healthy)
      `shouldReturn` Left (RegisteredGroupStaleFingerprint Catalog.mainGroupId legacySlice)
    expectStore store (resumeCatalogRebuild healthy strandedRun (options "ignored"))
      `shouldReturn` Left (CatalogRebuildRunPreCanonical strandedRun Catalog.mainGroupId)
    expectStore store (adoptCatalogGroups healthy (Catalog.mainGroupId :| []))
      `shouldReturn` Left (AdoptGroupNotLive Catalog.mainGroupId GroupRebuilding (Just strandedRun))
    beforeRecovery <-
      expectStore store (startCatalogRebuild healthy Catalog.mainGroupId (options "before-recovery"))
    beforeRecovery `shouldSatisfy` \case
      Left (CatalogRebuildStartFailed RebuildGroupSliceDrift {}) -> True
      _ -> False

    abandoned <-
      expectStore
        store
        ( abandonCatalogRebuild
            healthy
            strandedRun
            (RebuildFailure "operator.pre-canonical" "discard run stranded by the 0024 upgrade")
        )
        >>= shouldBeRight
    abandoned ^. #runStatus `shouldBe` RebuildRunFailed
    groupAfterAbandon <- expectStore store (lookupProjectionRebuildGroup Catalog.mainGroupId)
    groupAfterAbandon ^? _Just . #status `shouldBe` Just GroupFailed
    groupAfterAbandon ^? _Just . #failureCode `shouldBe` Just (Just "operator.pre-canonical")

    _ <-
      expectStore
        store
        (abandonCatalogRebuild healthy strandedRun (RebuildFailure "again" "must not replace group evidence"))
        >>= shouldBeRight
    groupAfterSecondAbandon <- expectStore store (lookupProjectionRebuildGroup Catalog.mainGroupId)
    groupAfterSecondAbandon ^? _Just . #failureCode `shouldBe` Just (Just "operator.pre-canonical")

    adopted <-
      expectStore store (adoptCatalogGroups healthy (Catalog.mainGroupId :| []))
        >>= shouldBeRight
    map (^. #status) (adopted ^. #adoptedGroups) `shouldBe` [GroupFailed]
    map (^. #sliceFingerprint) (adopted ^. #adoptedGroups)
      `shouldBe` [currentSlice healthy]
    _ <- expectStore store (registerProjectionCatalog healthy) >>= shouldBeRight

    promoted <-
      expectStore store (startCatalogRebuild healthy Catalog.mainGroupId (options "recovery-fresh"))
        >>= shouldBeRight
    promoted ^. #runStatus `shouldBe` RebuildRunPromoted
    recoveredGroup <- expectStore store (lookupProjectionRebuildGroup Catalog.mainGroupId)
    recoveredGroup ^? _Just . #status `shouldBe` Just GroupLive
    counter <- expectStore store (lookupReadModel "catalog-counter-query")
    counter ^? _Just . #status `shouldBe` Just Live

  it "abandons a pre-canonical run whose process died while running" $ \store -> do
    healthy <- strandPreCanonicalRun store "running-recovery"
    expectStore store (Store.runTransaction (Tx.statement (rebuildRunIdText (runId "running-recovery")) markRunRunningStmt))
    abandoned <-
      expectStore
        store
        ( abandonCatalogRebuild
            healthy
            (runId "running-recovery")
            (RebuildFailure "operator.pre-canonical" "discard interrupted run")
        )
        >>= shouldBeRight
    abandoned ^. #runStatus `shouldBe` RebuildRunFailed

  it "never abandons a pre-canonical run that is no longer the group's active run" $ \store -> do
    healthy <- strandPreCanonicalRun store "inactive-recovery"
    expectStore
      store
      ( Store.runTransaction
          ( Tx.statement
              (rebuildGroupIdText Catalog.mainGroupId, "replacement-run")
              setActiveRunStmt
          )
      )
    expectStore
      store
      ( abandonCatalogRebuild
          healthy
          (runId "inactive-recovery")
          (RebuildFailure "operator.pre-canonical" "must not abandon a replaced run")
      )
      `shouldReturn` Left
        ( CatalogRebuildAbandonFailed
            (RebuildHandleNoLongerActive Catalog.mainGroupId (runId "inactive-recovery"))
        )

  it "never abandons a terminal pre-canonical run" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql operationsFixtureSql))
    healthy <- expectValid (operationsCatalog passingVerification)
    _ <- expectStore store (registerProjectionCatalog healthy) >>= shouldBeRight
    promoted <-
      expectStore store (startCatalogRebuild healthy Catalog.mainGroupId (options "terminal-recovery"))
        >>= shouldBeRight
    promoted ^. #runStatus `shouldBe` RebuildRunPromoted
    expectStore
      store
      (Store.runTransaction (Tx.statement (rebuildRunIdText (runId "terminal-recovery")) markRunPreCanonicalStmt))
    expectStore
      store
      ( abandonCatalogRebuild
          healthy
          (runId "terminal-recovery")
          (RebuildFailure "operator.pre-canonical" "must not abandon a promoted run")
      )
      `shouldReturn` Left (CatalogRebuildRunNotActive (runId "terminal-recovery"))

strandPreCanonicalRun :: Store.KirokuStore -> Text -> IO ValidatedProjectionCatalog
strandPreCanonicalRun store runIdentity = do
  expectStore store (Store.runTransaction (Tx.sql operationsFixtureSql))
  faulted <- expectValid (operationsCatalog failingVerification)
  healthy <- expectValid (operationsCatalog passingVerification)
  _ <- expectStore store (registerProjectionCatalog faulted) >>= shouldBeRight
  first <- expectStore store (startCatalogRebuild faulted Catalog.mainGroupId (options runIdentity))
  first `shouldSatisfy` \case
    Left CatalogRebuildVerificationFailed {} -> True
    _ -> False
  expectStore
    store
    ( Store.runTransaction $ do
        Tx.statement (rebuildRunIdText (runId runIdentity)) markRunPreCanonicalStmt
        Tx.statement
          (rebuildGroupIdText Catalog.mainGroupId, Text.replicate 64 "a")
          setStoredSliceStmt
    )
  pure healthy

operationsCatalog :: RebuildVerification -> ProjectionCatalog
operationsCatalog verificationHook =
  Catalog.validCatalog
    { targets =
        [ if target ^. #targetId == Catalog.counterTargetId
            then target & #resetPolicy .~ PreserveAndReconcile
            else target & #resetPolicy .~ ClearBeforeReplay
        | target <- Catalog.validCatalog ^. #targets
        ],
      rebuildGroups =
        [ group & #verificationHooks .~ [verificationHook]
        | group <- Catalog.validCatalog ^. #rebuildGroups
        ]
    }

passingVerification :: RebuildVerification
passingVerification = verification (pure (Right ()))

failingVerification :: RebuildVerification
failingVerification = verification (pure (Left "fault injected by pre-canonical recovery spec"))

verification :: Tx.Transaction (Either Text ()) -> RebuildVerification
verification action =
  RebuildVerification
    { verificationId = "pre-canonical-row-check",
      verificationVersion = "v1",
      verifyRebuild = action
    }

options :: Text -> RebuildOptions
options identity =
  defaultRebuildOptions
    RebuildRequest
      { rebuildRunId = runId identity,
        requestedBy = "pre-canonical-recovery-spec",
        requestReason = "exercise migration 0024 recovery",
        replayFrom = GlobalPosition 0
      }

runId :: Text -> RebuildRunId
runId identity =
  case mkRebuildRunId identity of
    Left err -> error (Text.unpack err)
    Right value -> value

currentSlice :: ValidatedProjectionCatalog -> Text
currentSlice catalog =
  maybe
    (error "pre-canonical recovery catalog has no main-group slice")
    groupSliceFingerprintText
    (CatalogApi.groupSliceFingerprint catalog Catalog.mainGroupId)

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

operationsFixtureSql :: ByteString
operationsFixtureSql =
  """
  CREATE SCHEMA app;
  CREATE TABLE app.counter (id bigint PRIMARY KEY);
  CREATE TABLE app.counter_audit (
    id bigint PRIMARY KEY,
    counter_id bigint REFERENCES app.counter(id)
  );
  INSERT INTO subscriptions (subscription_name, last_seen)
  VALUES ('catalog-async-subscription', 0);
  """

markRunPreCanonicalStmt :: Statement Text ()
markRunPreCanonicalStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_runs
    SET group_slice_fingerprint = '$pre-canonical',
        contract_fingerprint = 'contract-v2:' || repeat('c', 64),
        runner_format = 'keiro/projection-replay/v2'
    WHERE run_id = $1
    """
    (E.param (E.nonNullable E.text))
    D.noResult

setStoredSliceStmt :: Statement (Text, Text) ()
setStoredSliceStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_groups
    SET slice_fingerprint = $2
    WHERE group_id = $1
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    D.noResult

markRunRunningStmt :: Statement Text ()
markRunRunningStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_runs
    SET status = 'running', failed_at = NULL, failure_code = NULL,
        failure_detail = NULL, failure_source_id = NULL,
        failure_projection_id = NULL, failure_position = NULL
    WHERE run_id = $1
    """
    (E.param (E.nonNullable E.text))
    D.noResult

setActiveRunStmt :: Statement (Text, Text) ()
setActiveRunStmt =
  preparable
    """
    UPDATE keiro.keiro_projection_rebuild_groups
    SET active_run_id = $2
    WHERE group_id = $1
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    D.noResult
