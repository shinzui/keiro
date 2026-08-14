module PreimageSpec
  ( spec,
  )
where

import CatalogSpec qualified as Catalog
import Data.ByteString qualified as ByteString
import Data.List qualified as List
import Data.Text qualified as Text
import Keiro.Prelude
import Keiro.Projection.Catalog
import Keiro.Projection.Catalog qualified as CatalogApi
import Keiro.Projection.Catalog.Preimage
import Test.Hspec

spec :: Spec
spec = describe "canonical catalog fingerprint preimages" $ do
  it "renders adversarial trees injectively" $ do
    let renderings = renderPreimage <$> adversarialPreimages
    length renderings `shouldBe` length (List.nub renderings)
    traverse_ (`shouldSatisfy` (not . ByteString.null)) renderings

  it "separates the boundary-shift source collision" $ do
    left <- expectValid (sourceOnlyCatalog "a" "$all|c")
    right <- expectValid (sourceOnlyCatalog "a|$all" "c")
    CatalogApi.catalogFingerprint left `shouldNotBe` CatalogApi.catalogFingerprint right

  it "separates newline line forgery through dedup names" $ do
    left <- expectValid (dedupOnlyCatalog [("d", "x\ndedup|d2|y")])
    right <- expectValid (dedupOnlyCatalog [("d", "x"), ("d2", "y")])
    CatalogApi.catalogFingerprint left `shouldNotBe` CatalogApi.catalogFingerprint right

  it "separates colliding sources inside one rebuild group slice" $ do
    left <- expectValid (fullSourceCollisionCatalog "a" "$all|c")
    right <- expectValid (fullSourceCollisionCatalog "a|$all" "c")
    groupSliceFingerprint left Catalog.mainGroupId
      `shouldNotBe` groupSliceFingerprint right Catalog.mainGroupId

  it "retains order-insensitive catalog and slice identities" $ do
    current <- expectValid Catalog.validCatalog
    reordered <- expectValid (reverseCatalog Catalog.validCatalog)
    CatalogApi.catalogFingerprint reordered `shouldBe` CatalogApi.catalogFingerprint current
    groupSliceFingerprint reordered Catalog.mainGroupId
      `shouldBe` groupSliceFingerprint current Catalog.mainGroupId

  it "keeps an existing group slice stable under an additive catalog change" $ do
    current <- expectValid Catalog.validCatalog
    additive <- expectValid Catalog.additiveCatalog
    CatalogApi.catalogFingerprint additive `shouldNotBe` CatalogApi.catalogFingerprint current
    groupSliceFingerprint additive Catalog.mainGroupId
      `shouldBe` groupSliceFingerprint current Catalog.mainGroupId

  it "spells canonical identities with explicit format prefixes" $ do
    validated <- expectValid Catalog.validCatalog
    catalogFingerprintText (CatalogApi.catalogFingerprint validated)
      `shouldSatisfy` Text.isPrefixOf "catalog-v6:"
    fmap groupSliceFingerprintText (groupSliceFingerprint validated Catalog.mainGroupId)
      `shouldSatisfy` maybe False (Text.isPrefixOf "slice-v5:")

sourceOnlyCatalog :: Text -> Text -> ProjectionCatalog
sourceOnlyCatalog identity codec =
  emptyProjectionCatalog
    { sources =
        [ SourceDeclaration
            { sourceId = identityOrError mkSourceId identity,
              sourceScope = AllStreams,
              codecFingerprint = codec,
              claimSite = identityOrError mkClaimSite ("preimage:source:" <> identity)
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
              claimSite = identityOrError mkClaimSite ("preimage:dedup:" <> identity)
            }
        | (identity, name) <- entries
        ]
    }

fullSourceCollisionCatalog :: Text -> Text -> ProjectionCatalog
fullSourceCollisionCatalog identity codec =
  Catalog.validCatalog
    { sources =
        [ SourceDeclaration
            { sourceId = collisionSourceId,
              sourceScope = AllStreams,
              codecFingerprint = codec,
              claimSite = identityOrError mkClaimSite ("preimage:full-source:" <> identity)
            }
        ],
      subscriptions =
        [ subscription & #subscriptionSource .~ collisionSourceId
        | subscription <- Catalog.validCatalog ^. #subscriptions
        ],
      projectionSets =
        [ SomeProjectionSet
            (Catalog.validProjectionSet & #projectionSource .~ collisionSourceId)
        ]
    }
  where
    collisionSourceId = identityOrError mkSourceId identity

reverseCatalog :: ProjectionCatalog -> ProjectionCatalog
reverseCatalog catalog =
  catalog
    { sources = reverse (catalog ^. #sources),
      targets = reverse (catalog ^. #targets),
      rebuildGroups = reverse (catalog ^. #rebuildGroups),
      projectionRevisions = reverse (catalog ^. #projectionRevisions),
      externalReadContracts = reverse (catalog ^. #externalReadContracts),
      subscriptions = reverse (catalog ^. #subscriptions),
      dedupKeys = reverse (catalog ^. #dedupKeys),
      queryModels = reverse (catalog ^. #queryModels),
      projectionSets = reverse (catalog ^. #projectionSets)
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

identityOrError :: (Text -> Either err value) -> Text -> value
identityOrError constructor identity =
  case constructor identity of
    Left _ -> error ("invalid test identity: " <> show identity)
    Right value -> value
