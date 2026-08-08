{-# LANGUAGE MultilineStrings #-}

module CatalogOperationsSpec
  ( spec,
  )
where

import CatalogSpec qualified as Catalog
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Keiro.Prelude
import Keiro.Projection.Catalog
import Keiro.Projection.Catalog.Operations qualified as Operations
import Keiro.ReadModel.Rebuild
import Keiro.Test.Postgres (Fixture, withFreshStore)
import Kiroku.Store qualified as Store
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types (GlobalPosition (..))
import Test.Hspec
import "hasql-transaction" Hasql.Transaction qualified as Tx

spec :: Fixture -> Spec
spec fixture = do
  describe "projection catalog operations reports" $ do
    it "derives complete versioned inventory and destructive preview from one catalog" $ do
      validated <- expectValid (operationsCatalog passingVerification)
      let operations = Operations.projectionCatalogOperations validated
          inventory = Operations.catalogInventoryReport operations
          previewResult = Operations.previewGroupRebuild operations Catalog.mainGroupId
      inventory ^. #reportSchema `shouldBe` "keiro/catalog-inventory/v1"
      case Aeson.toJSON inventory of
        Aeson.Object fields ->
          KeyMap.lookup "catalogFingerprint" fields `shouldSatisfy` (/= Nothing)
        other -> expectationFailure ("expected inventory object, got " <> show other)
      report <- case previewResult of
        Left err -> expectationFailure ("expected preview, got " <> show err) >> error "unreachable"
        Right value -> pure value
      map (^. #resetPolicy) (report ^. #targets)
        `shouldBe` [PreserveAndReconcile, ClearBeforeReplay]
      map (^. #subscriptionName) (report ^. #subscriptionResets)
        `shouldBe` ["catalog-async-subscription"]
      map (^. #dedupName) (report ^. #dedupResets)
        `shouldBe` ["catalog-async"]
      report ^. #destructive `shouldBe` True
      report ^. #lockScope `shouldBe` [Catalog.mainGroupId]
      Operations.previewGroupRebuild operations (identityOrError mkRebuildGroupId "missing")
        `shouldSatisfy` isLeft

    it "does not construct operations or invoke a callback for an invalid catalog" $ do
      effects <- newIORef (0 :: Int)
      result <-
        useProjectionCatalogM
          (Catalog.validCatalog {projectionSets = []})
          ( \validated -> do
              modifyIORef' effects (+ 1)
              pure (Operations.projectionCatalogOperations validated)
          )
      case result of
        Failure _ -> pure ()
        Success _ -> expectationFailure "invalid catalog unexpectedly constructed operations"
      readIORef effects `shouldReturn` 0

  describe "projection catalog operations actions" $ around (withFreshStore fixture) $ do
    it "keeps registered preview read-only and starts a zero-event rebuild from catalog facts" $ \store -> do
      expectStore store (Store.runTransaction (Tx.sql operationsFixtureSql))
      validated <- expectValid (operationsCatalog passingVerification)
      let operations = Operations.projectionCatalogOperations validated
      beforePreview <- expectStore store (Operations.previewRegisteredGroupRebuild operations Catalog.mainGroupId) >>= shouldBeRight
      beforePreview ^. #registeredState `shouldBe` Nothing
      _ <- expectStore store (registerProjectionCatalog validated) >>= shouldBeRight
      registered <- expectStore store (Operations.previewRegisteredGroupRebuild operations Catalog.mainGroupId) >>= shouldBeRight
      registered ^? #registeredState . _Just . #status `shouldBe` Just GroupLive
      started <-
        expectStore
          store
          (Operations.startGroupRebuild operations Catalog.mainGroupId (options "operations-success"))
          >>= shouldBeRight
      started ^. #reportSchema `shouldBe` "keiro/catalog-rebuild-run/v1"
      started ^. #run . #runStatus `shouldBe` RebuildRunPromoted

    it "inspects and resumes a failed run without caller-supplied fleet lists" $ \store -> do
      expectStore store (Store.runTransaction (Tx.sql operationsFixtureSql))
      faulted <- expectValid (operationsCatalog failingVerification)
      _ <- expectStore store (registerProjectionCatalog faulted) >>= shouldBeRight
      let faultedOperations = Operations.projectionCatalogOperations faulted
      first <- expectStore store (Operations.startGroupRebuild faultedOperations Catalog.mainGroupId (options "operations-resume"))
      first `shouldSatisfy` \case
        Left (Operations.CatalogOpsRebuildError CatalogRebuildVerificationFailed {}) -> True
        _ -> False
      inspected <- expectStore store (Operations.inspectGroupRebuild faultedOperations (runId "operations-resume")) >>= shouldBeRight
      inspected ^. #run . #runStatus `shouldBe` RebuildRunFailed

      repaired <- expectValid (operationsCatalog passingVerification)
      resumed <-
        expectStore
          store
          (Operations.resumeGroupRebuild (Operations.projectionCatalogOperations repaired) (runId "operations-resume") (options "ignored"))
          >>= shouldBeRight
      resumed ^. #run . #runStatus `shouldBe` RebuildRunPromoted

    it "abandons a failed run with durable group and run evidence" $ \store -> do
      expectStore store (Store.runTransaction (Tx.sql operationsFixtureSql))
      faulted <- expectValid (operationsCatalog failingVerification)
      _ <- expectStore store (registerProjectionCatalog faulted) >>= shouldBeRight
      let operations = Operations.projectionCatalogOperations faulted
      _ <- expectStore store (Operations.startGroupRebuild operations Catalog.mainGroupId (options "operations-abandon"))
      abandoned <-
        expectStore
          store
          ( Operations.abandonGroupRebuild
              operations
              (runId "operations-abandon")
              RebuildFailure
                { failureCode = "operator.abandoned",
                  failureDetail = "operator chose rollback"
                }
          )
          >>= shouldBeRight
      abandoned ^. #run . #runStatus `shouldBe` RebuildRunFailed
      state <- expectStore store (lookupProjectionRebuildGroup Catalog.mainGroupId)
      state ^? _Just . #status `shouldBe` Just GroupFailed
      state ^? _Just . #failureCode `shouldBe` Just (Just "operator.abandoned")

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
failingVerification = verification (pure (Left "fault injected by operations spec"))

verification :: Tx.Transaction (Either Text ()) -> RebuildVerification
verification action =
  RebuildVerification
    { verificationId = "operations-row-check",
      verificationVersion = "v1",
      verifyRebuild = action
    }

options :: Text -> RebuildOptions
options identity =
  defaultRebuildOptions
    RebuildRequest
      { rebuildRunId = runId identity,
        requestedBy = "catalog-operations-spec",
        requestReason = "operator-neutral adapter proof",
        replayFrom = GlobalPosition 0
      }

runId :: Text -> RebuildRunId
runId identity =
  case mkRebuildRunId identity of
    Left err -> error (Text.unpack err)
    Right value -> value

identityOrError :: (Text -> Either CatalogIdentityError identity) -> Text -> identity
identityOrError constructor value =
  case constructor value of
    Left err -> error (show err)
    Right identity -> identity

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
  """
