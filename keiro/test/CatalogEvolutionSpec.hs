{-# LANGUAGE MultilineStrings #-}

module CatalogEvolutionSpec
  ( spec,
  )
where

import CatalogSpec qualified as Catalog
import Contravariant.Extras (contrazip2)
import Data.ByteString (ByteString)
import Data.Either (isRight)
import Data.Text qualified as Text
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Keiro.Prelude
import Keiro.Projection.Catalog
import Keiro.Projection.Catalog qualified as CatalogApi
import Keiro.Projection.Catalog.Operations qualified as Operations
import Keiro.ReadModel (lookupReadModel)
import Keiro.ReadModel.Rebuild
import Keiro.Test.Postgres (Fixture, withFreshStore)
import Kiroku.Store qualified as Store
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types (GlobalPosition (..))
import Test.Hspec
import "hasql-transaction" Hasql.Transaction qualified as Tx

spec :: Fixture -> Spec
spec fixture = describe "catalog evolution adoption" $ around (withFreshStore fixture) $ do
  it "previews and transactionally adopts a changed slice and query schema" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql catalogFixtureSql))
    current <- expectValid (rebuildableCatalog Catalog.validCatalog)
    changed <- expectValid changedCatalog
    _ <- expectStore store (registerProjectionCatalog current) >>= shouldBeRight
    let oldSlice = sliceText current Catalog.mainGroupId
        newSlice = sliceText changed Catalog.mainGroupId

    expectStore store (registerProjectionCatalog changed)
      `shouldReturn` Left (RegisteredGroupSliceDrift Catalog.mainGroupId oldSlice newSlice)
    expectStore store (beginGroupRebuild changed Catalog.mainGroupId (request "before-adoption"))
      `shouldReturn` Left (RebuildGroupSliceDrift Catalog.mainGroupId oldSlice newSlice)

    plan <- expectStore store (previewCatalogAdoption changed)
    plan ^. #groupStates
      `shouldBe` [(Catalog.mainGroupId, AdoptionSliceChanged oldSlice newSlice)]
    plan ^. #removedGroups `shouldBe` []
    report <-
      expectStore
        store
        (Operations.previewCatalogAdoption (Operations.projectionCatalogOperations changed))
    report ^. #reportSchema `shouldBe` "keiro/catalog-adoption-preview/v1"
    map (^. #classification) (report ^. #groups)
      `shouldBe` [AdoptionSliceChanged oldSlice newSlice]
    map (^. #currentSlice) (report ^. #groups) `shouldBe` [newSlice]
    report ^. #removedGroups `shouldBe` []

    outcome <-
      expectStore
        store
        ( Operations.adoptCatalogGroups
            (Operations.projectionCatalogOperations changed)
            (Catalog.mainGroupId :| [])
        )
        >>= shouldBeRight
    outcome ^. #reportSchema `shouldBe` "keiro/catalog-adoption-outcome/v1"
    let adopted = outcome ^. #adoptedGroups
    map (^. #sliceFingerprint) adopted `shouldBe` [newSlice]
    metadata <- expectStore store (lookupReadModel "catalog-counter-query")
    metadata ^? _Just . #version `shouldBe` Just 2
    metadata ^? _Just . #shapeHash
      `shouldBe` Just "catalog-counter-query-v1-adopted"
    registered <- expectStore store (registerProjectionCatalog changed)
    registered `shouldSatisfy` isRight

    promoted <-
      expectStore
        store
        (startCatalogRebuild changed Catalog.mainGroupId (options "after-adoption"))
        >>= shouldBeRight
    promoted ^. #runStatus `shouldBe` RebuildRunPromoted

  it "refuses unregistered and non-live groups without partially adopting" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql catalogFixtureSql))
    current <- expectValid (rebuildableCatalog Catalog.additiveCatalog)
    changed <- expectValid (changeCatalog (rebuildableCatalog Catalog.additiveCatalog))
    base <- expectValid (rebuildableCatalog Catalog.validCatalog)
    _ <- expectStore store (registerProjectionCatalog base) >>= shouldBeRight
    expectStore store (adoptCatalogGroups current (Catalog.additiveGroupId :| []))
      `shouldReturn` Left (AdoptGroupUnregistered Catalog.additiveGroupId)

    _ <- expectStore store (registerProjectionCatalog current) >>= shouldBeRight
    _ <-
      expectStore store (beginGroupRebuild current Catalog.mainGroupId (request "non-live"))
        >>= shouldBeRight
    let mainBefore = sliceText current Catalog.mainGroupId
        additiveBefore = sliceText current Catalog.additiveGroupId
    expectStore
      store
      (adoptCatalogGroups changed (Catalog.additiveGroupId :| [Catalog.mainGroupId]))
      `shouldReturn` Left (AdoptGroupNotLive Catalog.mainGroupId GroupRebuilding (Just (runId "non-live")))
    main <- expectStore store (lookupProjectionRebuildGroup Catalog.mainGroupId)
    main ^? _Just . #sliceFingerprint `shouldBe` Just mainBefore
    main ^? _Just . #status `shouldBe` Just GroupRebuilding
    additive <- expectStore store (lookupProjectionRebuildGroup Catalog.additiveGroupId)
    additive ^? _Just . #sliceFingerprint `shouldBe` Just additiveBefore

  it "classifies and adopts a pre-canonical stored fingerprint" $ \store -> do
    current <- expectValid Catalog.validCatalog
    _ <- expectStore store (registerProjectionCatalog current) >>= shouldBeRight
    let stale = Text.replicate 64 "a"
    expectStore
      store
      (Store.runTransaction (Tx.statement (rebuildGroupIdText Catalog.mainGroupId, stale) setStoredSliceStmt))
    expectStore store (registerProjectionCatalog current)
      `shouldReturn` Left (RegisteredGroupStaleFingerprint Catalog.mainGroupId stale)
    plan <- expectStore store (previewCatalogAdoption current)
    plan ^. #groupStates
      `shouldBe` [(Catalog.mainGroupId, AdoptionStaleFormat stale)]
    _ <-
      expectStore store (adoptCatalogGroups current (Catalog.mainGroupId :| []))
        >>= shouldBeRight
    registered <- expectStore store (registerProjectionCatalog current)
    registered `shouldSatisfy` isRight

changedCatalog :: ProjectionCatalog
changedCatalog = changeCatalog (rebuildableCatalog Catalog.validCatalog)

rebuildableCatalog :: ProjectionCatalog -> ProjectionCatalog
rebuildableCatalog catalog =
  catalog
    { targets =
        [ target & #resetPolicy .~ ClearBeforeReplay
        | target <- catalog ^. #targets
        ]
    }

changeCatalog :: ProjectionCatalog -> ProjectionCatalog
changeCatalog catalog =
  catalog
    { sources =
        [ source & #codecFingerprint .~ (source ^. #codecFingerprint <> "-adopted")
        | source <- catalog ^. #sources
        ],
      queryModels = bumpQueryModel <$> catalog ^. #queryModels
    }

bumpQueryModel :: SomeQueryModelBinding -> SomeQueryModelBinding
bumpQueryModel (SomeQueryModelBinding binding) =
  SomeQueryModelBinding
    ( binding
        & #readModel
        . #version
        %~ (+ 1)
        & #readModel
        . #shapeHash
        %~ (<> "-adopted")
    )

sliceText :: ValidatedProjectionCatalog -> RebuildGroupId -> Text
sliceText catalog groupId =
  maybe
    (error "test catalog group has no slice")
    groupSliceFingerprintText
    (CatalogApi.groupSliceFingerprint catalog groupId)

request :: Text -> RebuildRequest
request identity =
  RebuildRequest
    { rebuildRunId = runId identity,
      requestedBy = "catalog-evolution-spec",
      requestReason = "exercise explicit catalog adoption",
      replayFrom = GlobalPosition 0
    }

options :: Text -> RebuildOptions
options = defaultRebuildOptions . request

runId :: Text -> RebuildRunId
runId identity =
  case mkRebuildRunId identity of
    Left err -> error (Text.unpack err)
    Right value -> value

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

catalogFixtureSql :: ByteString
catalogFixtureSql =
  """
  CREATE SCHEMA app;
  CREATE TABLE app.counter (id bigint PRIMARY KEY);
  CREATE TABLE app.counter_audit (
    id bigint PRIMARY KEY,
    counter_id bigint REFERENCES app.counter(id)
  );
  CREATE TABLE app.catalog_additive (id bigint PRIMARY KEY);
  INSERT INTO subscriptions (subscription_name, last_seen)
  VALUES ('catalog-async-subscription', 0);
  """

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
