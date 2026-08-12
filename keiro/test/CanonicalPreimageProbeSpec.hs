module CanonicalPreimageProbeSpec
  ( spec,
  )
where

import CatalogSpec qualified as Catalog
import Data.ByteString qualified as ByteString
import Data.List qualified as List
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Keiro.Prelude
import Keiro.Projection.Catalog
import Keiro.Projection.Catalog qualified as CatalogApi
import Keiro.Projection.Catalog.Preimage
import Keiro.ReadModel.Rebuild
import Keiro.Test.Postgres (Fixture, withFreshStore)
import Kiroku.Store qualified as Store
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types (GlobalPosition (..))
import Test.Hspec

spec :: Fixture -> Spec
spec fixture = do
  describe "catalog fingerprint preimage (probe)" $ do
    it "reproduces the boundary-shift source collision" $ do
      left <- expectValid (sourceOnlyCatalog "a" "$all|c")
      right <- expectValid (sourceOnlyCatalog "a|$all" "c")
      CatalogApi.catalogFingerprint left `shouldBe` CatalogApi.catalogFingerprint right

    it "reproduces newline line forgery through dedup names" $ do
      left <- expectValid (dedupOnlyCatalog [("d", "x\ndedup|d2|y")])
      right <- expectValid (dedupOnlyCatalog [("d", "x"), ("d2", "y")])
      CatalogApi.catalogFingerprint left `shouldBe` CatalogApi.catalogFingerprint right

    it "renders adversarial canonical trees injectively" $ do
      let renderings = renderPreimage <$> adversarialPreimages
      length renderings `shouldBe` length (List.nub renderings)
      traverse_ (`shouldSatisfy` (not . ByteString.null)) renderings

  describe "catalog evolution (probe)" $ around (withFreshStore fixture) $ do
    it "reproduces additive registration and rebuild lockout" $ \store -> do
      current <- expectValid Catalog.validCatalog
      additive <- expectValid Catalog.additiveCatalog
      _ <- expectStore store (registerProjectionCatalog current) >>= shouldBeRight

      registration <- expectStore store (registerProjectionCatalog additive)
      registration `shouldSatisfy` \case
        Left RegisteredGroupFingerprintDrift {} -> True
        _ -> False

      begin <-
        expectStore
          store
          ( beginGroupRebuild
              additive
              Catalog.mainGroupId
              RebuildRequest
                { rebuildRunId = identityOrError mkRebuildRunId "additive-lockout-probe",
                  requestedBy = "canonical-preimage-probe",
                  requestReason = "reproduce whole-catalog lockout",
                  replayFrom = GlobalPosition 0
                }
          )
      begin `shouldSatisfy` \case
        Left RebuildCatalogFingerprintDrift {} -> True
        _ -> False

sourceOnlyCatalog :: Text -> Text -> ProjectionCatalog
sourceOnlyCatalog identity codec =
  emptyProjectionCatalog
    { sources =
        [ SourceDeclaration
            { sourceId = identityOrError mkSourceId identity,
              sourceScope = AllStreams,
              codecFingerprint = codec,
              claimSite = identityOrError mkClaimSite ("probe:source:" <> identity)
            }
        ]
    }

dedupOnlyCatalog :: [(Text, Text)] -> ProjectionCatalog
dedupOnlyCatalog entries =
  emptyProjectionCatalog
    { dedupKeys =
        [ DedupKeyDeclaration
            { dedupKeyId = identityOrError mkDedupKeyId identity,
              dedupName = name,
              claimSite = identityOrError mkClaimSite ("probe:dedup:" <> identity)
            }
        | (identity, name) <- entries
        ]
    }

adversarialPreimages :: [Preimage]
adversarialPreimages =
  [ PText "",
    PText "a",
    PText "a|b",
    PText "3:abc",
    PText "a\nb",
    PText "ab",
    PList [],
    PList [PText "a", PText "b"],
    PList [PText "ab"],
    PRecord "t" [],
    PRecord "t" [PText ""],
    PRecord "t|n1:" [PText "payload"]
  ]

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

identityOrError :: (Text -> Either err value) -> Text -> value
identityOrError constructor identity =
  case constructor identity of
    Left _ -> error ("invalid test identity: " <> show identity)
    Right value -> value
