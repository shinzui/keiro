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
import Keiro.ReadModel (ReadModel (..), ReadModelStatus (Abandoned), lookupReadModel)
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

  it "classifies and adopts a live slice-v1 stored fingerprint" $ \store -> do
    current <- expectValid Catalog.validCatalog
    _ <- expectStore store (registerProjectionCatalog current) >>= shouldBeRight
    let stale = "slice-v1:" <> Text.replicate 64 "a"
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

  it "adopts only stale-format failed groups while preserving their fence" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql catalogFixtureSql))
    current <- expectValid (rebuildableCatalog Catalog.validCatalog)
    _ <- expectStore store (registerProjectionCatalog current) >>= shouldBeRight
    handle <-
      expectStore store (beginGroupRebuild current Catalog.mainGroupId (request "failed-adoption"))
        >>= shouldBeRight
    _ <-
      expectStore
        store
        (abandonGroupRebuild handle (RebuildFailure "operator.abandoned" "prepare adoption boundary"))
        >>= shouldBeRight

    expectStore store (adoptCatalogGroups current (Catalog.mainGroupId :| []))
      `shouldReturn` Left
        (AdoptGroupNotLive Catalog.mainGroupId GroupFailed (Just (runId "failed-adoption")))

    let stale = "slice-v1:" <> Text.replicate 64 "a"
    expectStore
      store
      (Store.runTransaction (Tx.statement (rebuildGroupIdText Catalog.mainGroupId, stale) setStoredSliceStmt))
    adopted <-
      expectStore store (adoptCatalogGroups current (Catalog.mainGroupId :| []))
        >>= shouldBeRight
    map (^. #status) (adopted ^. #adoptedGroups) `shouldBe` [GroupFailed]
    map (^. #sliceFingerprint) (adopted ^. #adoptedGroups)
      `shouldBe` [sliceText current Catalog.mainGroupId]

  it "adopts a renamed query registration completely" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql catalogFixtureSql))
    current <- expectValid (rebuildableCatalog Catalog.validCatalog)
    renamed <- expectValid renamedCatalog
    _ <- expectStore store (registerProjectionCatalog current) >>= shouldBeRight
    let oldSlice = sliceText current Catalog.mainGroupId
        newSlice = sliceText renamed Catalog.mainGroupId
    expectStore store (registerProjectionCatalog renamed)
      `shouldReturn` Left (RegisteredGroupSliceDrift Catalog.mainGroupId oldSlice newSlice)
    plan <- expectStore store (previewCatalogAdoption renamed)
    plan ^. #registrations
      `shouldContain` [RegistrationAdoption "catalog-counter-query-renamed" Catalog.mainGroupId RegistrationInsert]
    plan ^. #orphanedRegistrations
      `shouldContain` [OrphanedRegistration "catalog-counter-query" Catalog.mainGroupId]
    result <-
      expectStore store (adoptCatalogGroups renamed (Catalog.mainGroupId :| []))
        >>= shouldBeRight
    result ^. #registrationOutcomes
      `shouldContain` [RegistrationAdoption "catalog-counter-query-renamed" Catalog.mainGroupId RegistrationInsert]
    result ^. #removedOrphans
      `shouldBe` [OrphanedRegistration "catalog-counter-query" Catalog.mainGroupId]
    renamedRow <- expectStore store (lookupReadModel "catalog-counter-query-renamed")
    renamedRow ^? _Just . #shapeHash
      `shouldBe` Just "catalog-counter-query-renamed-v1"
    oldRow <- expectStore store (lookupReadModel "catalog-counter-query")
    oldRow `shouldBe` Nothing
    registered <- expectStore store (registerProjectionCatalog renamed)
    registered `shouldSatisfy` isRight

  it "inserts an added query registration during adoption" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql catalogFixtureSql))
    current <- expectValid (rebuildableCatalog Catalog.validCatalog)
    added <- expectValid addedQueryCatalog
    _ <- expectStore store (registerProjectionCatalog current) >>= shouldBeRight
    plan <- expectStore store (previewCatalogAdoption added)
    plan ^. #registrations
      `shouldContain` [RegistrationAdoption "catalog-added-query" Catalog.mainGroupId RegistrationInsert]
    plan ^. #orphanedRegistrations `shouldBe` []
    result <-
      expectStore store (adoptCatalogGroups added (Catalog.mainGroupId :| []))
        >>= shouldBeRight
    result ^. #registrationOutcomes
      `shouldContain` [RegistrationAdoption "catalog-added-query" Catalog.mainGroupId RegistrationInsert]
    result ^. #removedOrphans `shouldBe` []
    addedRow <- expectStore store (lookupReadModel "catalog-added-query")
    addedRow ^? _Just . #rebuildGroupId
      `shouldBe` Just (rebuildGroupIdText Catalog.mainGroupId)

  it "does not orphan a query registration moved to an out-of-scope group" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql catalogFixtureSql))
    current <- expectValid (rebuildableCatalog Catalog.additiveCatalog)
    _ <- expectStore store (registerProjectionCatalog current) >>= shouldBeRight
    expectStore
      store
      ( Store.runTransaction
          ( Tx.statement
              ("catalog-additive-query", rebuildGroupIdText Catalog.mainGroupId)
              setQueryGroupStmt
          )
      )
    plan <- expectStore store (previewCatalogAdoption current)
    plan ^. #orphanedRegistrations `shouldBe` []
    result <-
      expectStore store (adoptCatalogGroups current (Catalog.mainGroupId :| []))
        >>= shouldBeRight
    result ^. #removedOrphans `shouldBe` []
    movedRow <- expectStore store (lookupReadModel "catalog-additive-query")
    movedRow ^? _Just . #rebuildGroupId
      `shouldBe` Just (rebuildGroupIdText Catalog.mainGroupId)

  it "keeps an inserted registration fenced when adopting a failed stale-format group" $ \store -> do
    expectStore store (Store.runTransaction (Tx.sql catalogFixtureSql))
    current <- expectValid (rebuildableCatalog Catalog.validCatalog)
    renamed <- expectValid renamedCatalog
    _ <- expectStore store (registerProjectionCatalog current) >>= shouldBeRight
    handle <-
      expectStore store (beginGroupRebuild current Catalog.mainGroupId (request "failed-insert"))
        >>= shouldBeRight
    _ <-
      expectStore store (abandonGroupRebuild handle (RebuildFailure "operator.abandoned" "fence insert"))
        >>= shouldBeRight
    let stale = "slice-v1:" <> Text.replicate 64 "b"
    expectStore
      store
      (Store.runTransaction (Tx.statement (rebuildGroupIdText Catalog.mainGroupId, stale) setStoredSliceStmt))
    _ <-
      expectStore store (adoptCatalogGroups renamed (Catalog.mainGroupId :| []))
        >>= shouldBeRight
    renamedRow <- expectStore store (lookupReadModel "catalog-counter-query-renamed")
    renamedRow ^? _Just . #status `shouldBe` Just Abandoned

changedCatalog :: ProjectionCatalog
changedCatalog = changeCatalog (rebuildableCatalog Catalog.validCatalog)

renamedCatalog :: ProjectionCatalog
renamedCatalog =
  let base = rebuildableCatalog Catalog.validCatalog
   in base {queryModels = renameCounterQuery <$> base ^. #queryModels}

renameCounterQuery :: SomeQueryModelBinding -> SomeQueryModelBinding
renameCounterQuery (SomeQueryModelBinding binding)
  | binding ^. #readModel . #name == "catalog-counter-query" =
      SomeQueryModelBinding
        binding
          { readModel =
              (binding ^. #readModel)
                { name = "catalog-counter-query-renamed",
                  shapeHash = "catalog-counter-query-renamed-v1"
                }
          }
  | otherwise = SomeQueryModelBinding binding

addedQueryCatalog :: ProjectionCatalog
addedQueryCatalog =
  let base = rebuildableCatalog Catalog.validCatalog
   in base
        { queryModels =
            base ^. #queryModels
              <> [SomeQueryModelBinding addedQueryBinding]
        }

addedQueryBinding :: QueryModelBinding Text ()
addedQueryBinding =
  Catalog.counterBinding
    { queryModelId = queryModelIdentity "added-query",
      readModel =
        (Catalog.counterBinding ^. #readModel)
          { name = "catalog-added-query",
            shapeHash = "catalog-added-query-v1"
          },
      rebuildGroup = Catalog.mainGroupId,
      observedTargets = [Catalog.counterTargetId],
      claimSite = claimSiteIdentity "catalog:added-query"
    }

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

queryModelIdentity :: Text -> QueryModelId
queryModelIdentity identity =
  case mkQueryModelId identity of
    Left err -> error (show err)
    Right value -> value

claimSiteIdentity :: Text -> ClaimSite
claimSiteIdentity identity =
  case mkClaimSite identity of
    Left err -> error (show err)
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

setQueryGroupStmt :: Statement (Text, Text) ()
setQueryGroupStmt =
  preparable
    """
    UPDATE keiro.keiro_read_models
    SET rebuild_group_id = $2
    WHERE name = $1
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    D.noResult
