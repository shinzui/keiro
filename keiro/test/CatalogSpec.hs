module CatalogSpec
  ( spec,
    CatalogEvent (..),
    validCatalog,
    additiveCatalog,
    validProjectionSet,
    catalogWithMissingSubscription,
    catalogAsyncProjection,
    inlineProjectionId,
    asyncProjectionId,
    counterTargetId,
    auditTargetId,
    mainGroupId,
  )
where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List qualified as List
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import Keiro.Prelude
import Keiro.Projection (AsyncProjection (..), InlineProjection (..))
import Keiro.Projection.Catalog
import Keiro.ReadModel (ConsistencyMode (..), ReadModel (..), StrongScope (..))
import Kiroku.Store.Subscription.Types (MissingCheckpointPolicy (..))
import Kiroku.Store.Types (CategoryName (..))
import Test.Hspec

data CatalogEvent = CatalogEvent
  deriving stock (Eq, Show)

spec :: Spec
spec = describe "Keiro.Projection.Catalog" $ do
  it "derives typed live handlers, registrations, inventory, and one stable fingerprint" $ do
    validated <- expectValid validCatalog
    map (^. #name) (typedInlineProjections validated validProjectionSet)
      `shouldBe` ["catalog-inline"]
    map (^. #projectionId) (catalogInventory validated ^. #inventoryProjections)
      `shouldBe` [asyncProjectionId, inlineProjectionId]
    catalogRegistrations validated
      `shouldSatisfy` ((== [auditQueryId, counterQueryId]) . map (^. #queryModelId))
    asyncProjectionRegistrations validated
      `shouldSatisfy` ((== [asyncProjectionId]) . map (^. #projectionId))
    map (^. #checkpointOnMissing) (asyncProjectionRegistrations validated)
      `shouldBe` [FromBeginning]

    reordered <- expectValid (reverseCatalog validCatalog)
    catalogInventory reordered `shouldBe` catalogInventory validated
    catalogFingerprint reordered `shouldBe` catalogFingerprint validated
    renderCatalogInventory reordered `shouldBe` renderCatalogInventory validated

  it "fingerprints and renders checkpoint policy without changing subscription identity" $ do
    fromBeginning <- expectValid validCatalog
    failIfMissing <- expectValid (catalogWithCheckpointPolicy FailIfMissing PreserveAndReconcile)
    catalogFingerprint fromBeginning `shouldNotBe` catalogFingerprint failIfMissing
    map (^. #subscriptionId) (catalogInventory fromBeginning ^. #inventorySubscriptions)
      `shouldBe` map (^. #subscriptionId) (catalogInventory failIfMissing ^. #inventorySubscriptions)
    renderCatalogInventory failIfMissing `shouldSatisfy` Text.isInfixOf "FailIfMissing"

  it "reports missing and independent duplicate owners with every claim site" $ do
    let missing = catalogWithDefinitions (inlineDefinition :| [])
        duplicateOwner = catalogWithDefinitions (inlineDefinition :| [duplicateInlineDefinition, asyncDefinition])
    diagnosticsFor missing
      `shouldSatisfy` hasDiagnostic TargetWithoutOwner (targetIdText auditTargetId)
    let duplicateDiagnostics =
          filter
            (\entry -> entry ^. #diagnosticCode == TargetWithMultipleOwners)
            (diagnosticsFor duplicateOwner)
    map (^. #diagnosticIdentity) duplicateDiagnostics
      `shouldBe` [targetIdText counterTargetId]
    map claimSiteText (duplicateDiagnostics ^?! ix 0 . #diagnosticSites)
      `shouldBe` ["catalog:inline", "catalog:inline-duplicate"]

  it "accumulates stable identity and reference diagnostics independent of input order" $ do
    let invalid =
          validCatalog
            { sources = validCatalog ^. #sources <> [headSource & #claimSite .~ site "catalog:source-duplicate"],
              targets =
                [ counterTarget & #dependsOn .~ [unknownTargetId],
                  auditTarget
                ],
              projectionSets =
                [ SomeProjectionSet
                    validProjectionSet
                      { projectionDefinitions =
                          (inlineDefinition & #rebuildGroup .~ unknownGroupId)
                            :| [ asyncDefinition
                                   & #handlers
                                   .~ ( AsyncHandler catalogAsyncProjection unknownSubscriptionId unknownDedupId (site "catalog:async")
                                          :| []
                                      )
                               ]
                      }
                ]
            }
        expectedCodes =
          [ DuplicateSourceId,
            UnknownTargetDependency,
            UnknownGroupReference,
            UnknownSubscriptionReference,
            UnknownDedupKeyReference
          ]
        diagnostics = diagnosticsFor invalid
        reordered = diagnosticsFor (reverseCatalog invalid)
    for_ expectedCodes $ \code ->
      diagnostics `shouldSatisfy` any ((== code) . (^. #diagnosticCode))
    reordered `shouldBe` diagnostics

  it "rejects duplicate physical tables and runtime registry names" $ do
    let secondSubscription =
          catalogSubscription
            & #subscriptionId
            .~ subscription "second-subscription"
            & #claimSite
            .~ site "catalog:second-subscription"
        secondDedup =
          catalogDedup
            & #dedupKeyId
            .~ dedup "second-dedup"
            & #claimSite
            .~ site "catalog:second-dedup"
        duplicateNames =
          validCatalog
            { targets =
                [ counterTarget,
                  auditTarget & #qualifiedTable .~ (counterTarget ^. #qualifiedTable)
                ],
              subscriptions = [catalogSubscription, secondSubscription],
              dedupKeys = [catalogDedup, secondDedup],
              queryModels =
                [ SomeQueryModelBinding counterBinding,
                  SomeQueryModelBinding
                    (auditBinding & #readModel . #name .~ (counterReadModel ^. #name))
                ]
            }
        codes = map (^. #diagnosticCode) (diagnosticsFor duplicateNames)
    codes `shouldSatisfy` List.elem DuplicateQualifiedTable
    codes `shouldSatisfy` List.elem DuplicateSubscriptionName
    codes `shouldSatisfy` List.elem DuplicateDedupName
    codes `shouldSatisfy` List.elem DuplicateQueryModelRegistryName

  it "rejects cross-group writes, dependency cycles, and unsafe replay combinations" $ do
    let cycleCatalog =
          validCatalog
            { targets =
                [ counterTarget & #dependsOn .~ [auditTargetId],
                  auditTarget & #dependsOn .~ [counterTargetId]
                ]
            }
        secondGroup =
          RebuildGroupDeclaration
            { rebuildGroupId = otherGroupId,
              orderedTargets = [auditTargetId],
              verificationHooks = [],
              claimSite = site "catalog:other-group"
            }
        crossGroupCatalog =
          validCatalog
            { rebuildGroups =
                [ validGroup & #orderedTargets .~ [counterTargetId],
                  secondGroup
                ]
            }
        liveOnlyClear =
          catalogWithDefinitions
            ( inlineDefinition
                { replayPolicy = LiveOnly (LiveOnlyReason "external side effect")
                }
                :| [asyncDefinition]
            )
    diagnosticsFor cycleCatalog
      `shouldSatisfy` any ((== TargetDependencyCycle) . (^. #diagnosticCode))
    diagnosticsFor crossGroupCatalog
      `shouldSatisfy` any ((== ProjectionCrossesRebuildGroups) . (^. #diagnosticCode))
    diagnosticsFor liveOnlyClear
      `shouldSatisfy` any ((== ClearTargetRequiresReplayableOwner) . (^. #diagnosticCode))

  it "accepts every explicit policy except current-head seeding after a replayable clear" $ do
    for_ [FromBeginning, FailIfMissing] $ \policy -> do
      _ <- expectValid (catalogWithCheckpointPolicy policy ClearBeforeReplay)
      pure ()
    for_ [FromBeginning, FromCurrentHead, FailIfMissing] $ \policy -> do
      _ <- expectValid (catalogWithCheckpointPolicy policy PreserveAndReconcile)
      pure ()
    let diagnostics = diagnosticsFor (catalogWithCheckpointPolicy FromCurrentHead ClearBeforeReplay)
    diagnostics
      `shouldSatisfy` hasDiagnostic
        ReplayableClearTargetStartsAtCurrentHead
        (subscriptionIdText asyncSubscriptionId <> "/" <> targetIdText auditTargetId)
    diagnostics
      `shouldSatisfy` any
        ( Text.isInfixOf "FromCurrentHead"
            . (^. #diagnosticMessage)
        )

  it "rejects all-stream/category overlap while accepting distinct category fan-in" $ do
    let secondSourceId = source "audit-source"
        categoryCatalog = twoSourceCatalog (CategorySource (CategoryName "counter")) (CategorySource (CategoryName "audit")) secondSourceId
        overlappingCatalog = twoSourceCatalog AllStreams (CategorySource (CategoryName "audit")) secondSourceId
    _ <- expectValid categoryCatalog
    diagnosticsFor overlappingCatalog
      `shouldSatisfy` any ((== AmbiguousSourceOrdering) . (^. #diagnosticCode))

  it "rejects duplicate and malformed rebuild verification identities" $ do
    let verification identity version =
          RebuildVerification
            { verificationId = identity,
              verificationVersion = version,
              verifyRebuild = pure (Right ())
            }
        withHooks hooks =
          validCatalog
            { rebuildGroups =
                [validGroup {verificationHooks = hooks}]
            }
        duplicate = diagnosticsFor (withHooks [verification "row-count" "v1", verification "row-count" "v2"])
        malformed = diagnosticsFor (withHooks [verification " row-count" ""])
    duplicate
      `shouldSatisfy` any ((== DuplicateRebuildVerificationId) . (^. #diagnosticCode))
    malformed
      `shouldSatisfy` any ((== InvalidRebuildVerificationIdentity) . (^. #diagnosticCode))

  it "keeps baseline removal comparison separate from single-catalog validity" $ do
    previous <- expectValid validCatalog
    current <- expectValid smallerCatalog
    compareCatalogBaseline (catalogInventory previous) (catalogInventory current)
      `shouldSatisfy` List.elem (TargetRemoved auditTargetId)

  it "does not invoke an effectful callback for an invalid catalog" $ do
    effects <- newIORef (0 :: Int)
    invalidResult <-
      useProjectionCatalogM
        (catalogWithDefinitions (inlineDefinition :| []))
        (\_ -> modifyIORef' effects (+ 1))
    invalidResult `shouldSatisfy` isFailure
    readIORef effects `shouldReturn` 0

    validResult <-
      useProjectionCatalogM
        validCatalog
        (\_ -> modifyIORef' effects (+ 1))
    validResult `shouldSatisfy` isSuccess
    readIORef effects `shouldReturn` 1

  it "labels legacy values as unmanaged without changing their behavior" $ do
    map (^. #name) (getUnmanagedInlineProjections (unmanagedInlineProjections [catalogInlineProjection]))
      `shouldBe` ["catalog-inline"]
    getUnmanagedAsyncProjection (unmanagedAsyncProjection catalogAsyncProjection) ^. #name
      `shouldBe` "catalog-async"
    getUnmanagedReadModel (unmanagedReadModel counterReadModel) ^. #name
      `shouldBe` "catalog-counter-query"

expectValid :: ProjectionCatalog -> IO ValidatedProjectionCatalog
expectValid catalog =
  case validateProjectionCatalog catalog of
    Success validated -> pure validated
    Failure diagnostics -> expectationFailure ("expected a valid catalog, got: " <> show diagnostics) >> error "unreachable"

diagnosticsFor :: ProjectionCatalog -> [CatalogDiagnostic]
diagnosticsFor catalog =
  case validateProjectionCatalog catalog of
    Failure diagnostics -> NonEmpty.toList diagnostics
    Success _ -> []

hasDiagnostic :: CatalogDiagnosticCode -> Text -> [CatalogDiagnostic] -> Bool
hasDiagnostic code identity =
  any
    ( \entry ->
        entry ^. #diagnosticCode == code
          && entry ^. #diagnosticIdentity == identity
    )

isFailure :: Validation error value -> Bool
isFailure (Failure _) = True
isFailure (Success _) = False

isSuccess :: Validation error value -> Bool
isSuccess (Success _) = True
isSuccess (Failure _) = False

validCatalog :: ProjectionCatalog
validCatalog =
  ProjectionCatalog
    { sources = [headSource],
      targets = [counterTarget, auditTarget],
      rebuildGroups = [validGroup],
      subscriptions = [catalogSubscription],
      dedupKeys = [catalogDedup],
      queryModels =
        [ SomeQueryModelBinding counterBinding,
          SomeQueryModelBinding auditBinding
        ],
      projectionSets = [SomeProjectionSet validProjectionSet]
    }

-- | A catalog extension that adds one completely independent read-side slice.
-- Existing declarations are byte-for-byte unchanged.
additiveCatalog :: ProjectionCatalog
additiveCatalog =
  validCatalog
    { sources = validCatalog ^. #sources <> [additiveSource],
      targets = validCatalog ^. #targets <> [additiveTarget],
      rebuildGroups = validCatalog ^. #rebuildGroups <> [additiveGroup],
      queryModels = validCatalog ^. #queryModels <> [SomeQueryModelBinding additiveBinding],
      projectionSets = validCatalog ^. #projectionSets <> [SomeProjectionSet additiveProjectionSet]
    }

additiveSource :: SourceDeclaration
additiveSource =
  SourceDeclaration
    { sourceId = additiveSourceId,
      sourceScope = CategorySource (CategoryName "catalog-additive"),
      codecFingerprint = "catalog-additive-codec-v1",
      claimSite = site "catalog:additive-source"
    }

additiveTarget :: TargetDeclaration
additiveTarget =
  TargetDeclaration
    { targetId = additiveTargetId,
      qualifiedTable = QualifiedTable "app" "catalog_additive",
      resetPolicy = ClearBeforeReplay,
      dependsOn = [],
      claimSite = site "catalog:additive-target"
    }

additiveGroup :: RebuildGroupDeclaration
additiveGroup =
  RebuildGroupDeclaration
    { rebuildGroupId = additiveGroupId,
      orderedTargets = [additiveTargetId],
      verificationHooks = [],
      claimSite = site "catalog:additive-group"
    }

additiveProjectionSet :: ProjectionSet CatalogEvent
additiveProjectionSet =
  ProjectionSet
    { projectionSource = additiveSourceId,
      projectionDefinitions =
        ProjectionDefinition
          { projectionId = additiveProjectionId,
            rebuildGroup = additiveGroupId,
            ownedTargets = additiveTargetId :| [],
            replayPolicy = replayablePolicy,
            handlers =
              InlineHandler
                InlineProjection
                  { name = "catalog-additive-inline",
                    apply = \_ _ -> pure ()
                  }
                (site "catalog:additive-handler")
                :| [],
            claimSite = site "catalog:additive-projection"
          }
          :| [],
      claimSite = site "catalog:additive-set"
    }

additiveBinding :: QueryModelBinding Text ()
additiveBinding =
  QueryModelBinding
    { queryModelId = additiveQueryId,
      readModel = readModelDefinition "catalog-additive-query" "catalog_additive",
      rebuildGroup = additiveGroupId,
      observedTargets = [additiveTargetId],
      claimSite = site "catalog:additive-query"
    }

validProjectionSet :: ProjectionSet CatalogEvent
validProjectionSet =
  ProjectionSet
    { projectionSource = headSourceId,
      projectionDefinitions = inlineDefinition :| [asyncDefinition],
      claimSite = site "catalog:set"
    }

catalogWithCheckpointPolicy :: MissingCheckpointPolicy -> TargetResetPolicy -> ProjectionCatalog
catalogWithCheckpointPolicy policy reset =
  validCatalog
    { subscriptions = [catalogSubscription & #checkpointOnMissing .~ policy],
      targets =
        [ if target ^. #targetId == auditTargetId
            then target & #resetPolicy .~ reset
            else target & #resetPolicy .~ PreserveAndReconcile
        | target <- validCatalog ^. #targets
        ]
    }

catalogWithMissingSubscription :: ProjectionCatalog
catalogWithMissingSubscription =
  validCatalog
    { subscriptions =
        validCatalog ^. #subscriptions
          <> [ SubscriptionDeclaration
                 { subscriptionId = missingSubscriptionId,
                   subscriptionName = "catalog-missing-subscription",
                   subscriptionSource = headSourceId,
                   checkpointOnMissing = FromBeginning,
                   claimSite = site "catalog:missing-subscription"
                 }
             ],
      dedupKeys =
        validCatalog ^. #dedupKeys
          <> [ DedupKeyDeclaration
                 { dedupKeyId = missingDedupId,
                   dedupName = "catalog-missing-async",
                   claimSite = site "catalog:missing-dedup"
                 }
             ],
      projectionSets =
        [ SomeProjectionSet
            validProjectionSet
              { projectionDefinitions =
                  inlineDefinition
                    :| [ asyncDefinition
                           & #handlers
                           .~ ( AsyncHandler catalogAsyncProjection asyncSubscriptionId asyncDedupId (site "catalog:async-handler")
                                  :| [ AsyncHandler
                                         catalogMissingAsyncProjection
                                         missingSubscriptionId
                                         missingDedupId
                                         (site "catalog:missing-async-handler")
                                     ]
                              )
                       ]
              }
        ]
    }

catalogWithDefinitions :: NonEmpty (ProjectionDefinition CatalogEvent) -> ProjectionCatalog
catalogWithDefinitions definitions =
  validCatalog
    { projectionSets =
        [ SomeProjectionSet
            validProjectionSet
              { projectionDefinitions = definitions
              }
        ]
    }

smallerCatalog :: ProjectionCatalog
smallerCatalog =
  validCatalog
    { targets = [counterTarget],
      rebuildGroups = [validGroup & #orderedTargets .~ [counterTargetId]],
      subscriptions = [],
      dedupKeys = [],
      queryModels = [SomeQueryModelBinding counterBinding],
      projectionSets =
        [ SomeProjectionSet
            validProjectionSet
              { projectionDefinitions = inlineDefinition :| []
              }
        ]
    }

twoSourceCatalog :: SourceScope -> SourceScope -> SourceId -> ProjectionCatalog
twoSourceCatalog firstScope secondScope secondSourceId =
  validCatalog
    { sources =
        [ headSource & #sourceScope .~ firstScope,
          SourceDeclaration
            { sourceId = secondSourceId,
              sourceScope = secondScope,
              codecFingerprint = "audit-codec-v1",
              claimSite = site "catalog:audit-source"
            }
        ],
      subscriptions =
        [catalogSubscription & #subscriptionSource .~ secondSourceId],
      projectionSets =
        [ SomeProjectionSet
            validProjectionSet
              { projectionDefinitions = inlineDefinition :| []
              },
          SomeProjectionSet
            ProjectionSet
              { projectionSource = secondSourceId,
                projectionDefinitions = asyncDefinition :| [],
                claimSite = site "catalog:audit-set"
              }
        ]
    }

reverseCatalog :: ProjectionCatalog -> ProjectionCatalog
reverseCatalog catalog =
  catalog
    { sources = reverse (catalog ^. #sources),
      targets = reverse (catalog ^. #targets),
      rebuildGroups = reverse (catalog ^. #rebuildGroups),
      subscriptions = reverse (catalog ^. #subscriptions),
      dedupKeys = reverse (catalog ^. #dedupKeys),
      queryModels = reverse (catalog ^. #queryModels),
      projectionSets = reverse (catalog ^. #projectionSets)
    }

headSource :: SourceDeclaration
headSource =
  SourceDeclaration
    { sourceId = headSourceId,
      sourceScope = CategorySource (CategoryName "counter"),
      codecFingerprint = "counter-codec-v1",
      claimSite = site "catalog:source"
    }

counterTarget :: TargetDeclaration
counterTarget =
  TargetDeclaration
    { targetId = counterTargetId,
      qualifiedTable = QualifiedTable "app" "counter",
      resetPolicy = ClearBeforeReplay,
      dependsOn = [],
      claimSite = site "catalog:counter-target"
    }

auditTarget :: TargetDeclaration
auditTarget =
  TargetDeclaration
    { targetId = auditTargetId,
      qualifiedTable = QualifiedTable "app" "counter_audit",
      resetPolicy = PreserveAndReconcile,
      dependsOn = [counterTargetId],
      claimSite = site "catalog:audit-target"
    }

validGroup :: RebuildGroupDeclaration
validGroup =
  RebuildGroupDeclaration
    { rebuildGroupId = mainGroupId,
      orderedTargets = [counterTargetId, auditTargetId],
      verificationHooks = [],
      claimSite = site "catalog:group"
    }

catalogSubscription :: SubscriptionDeclaration
catalogSubscription =
  SubscriptionDeclaration
    { subscriptionId = asyncSubscriptionId,
      subscriptionName = "catalog-async-subscription",
      subscriptionSource = headSourceId,
      checkpointOnMissing = FromBeginning,
      claimSite = site "catalog:subscription"
    }

catalogDedup :: DedupKeyDeclaration
catalogDedup =
  DedupKeyDeclaration
    { dedupKeyId = asyncDedupId,
      dedupName = "catalog-async",
      claimSite = site "catalog:dedup"
    }

inlineDefinition :: ProjectionDefinition CatalogEvent
inlineDefinition =
  ProjectionDefinition
    { projectionId = inlineProjectionId,
      rebuildGroup = mainGroupId,
      ownedTargets = counterTargetId :| [],
      replayPolicy = replayablePolicy,
      handlers = InlineHandler catalogInlineProjection (site "catalog:inline-handler") :| [],
      claimSite = site "catalog:inline"
    }

duplicateInlineDefinition :: ProjectionDefinition CatalogEvent
duplicateInlineDefinition =
  inlineDefinition
    { projectionId = projection "counter-owner-duplicate",
      claimSite = site "catalog:inline-duplicate"
    }

asyncDefinition :: ProjectionDefinition CatalogEvent
asyncDefinition =
  ProjectionDefinition
    { projectionId = asyncProjectionId,
      rebuildGroup = mainGroupId,
      ownedTargets = auditTargetId :| [],
      replayPolicy = replayablePolicy,
      handlers =
        AsyncHandler catalogAsyncProjection asyncSubscriptionId asyncDedupId (site "catalog:async-handler")
          :| [],
      claimSite = site "catalog:async"
    }

replayablePolicy :: ProjectionReplayPolicy CatalogEvent
replayablePolicy =
  Replayable
    ReplayAdapter
      { decodeForReplay = const ReplayIrrelevant,
        applyForReplay = \_ _ -> pure ()
      }

catalogInlineProjection :: InlineProjection CatalogEvent
catalogInlineProjection =
  InlineProjection
    { name = "catalog-inline",
      apply = \_ _ -> pure ()
    }

catalogAsyncProjection :: AsyncProjection
catalogAsyncProjection =
  AsyncProjection
    { name = "catalog-async",
      readModelName = "catalog-audit-query",
      subscriptionName = "catalog-async-subscription",
      applyRecorded = \_ -> pure (),
      idempotencyKey = (^. #eventId)
    }

catalogMissingAsyncProjection :: AsyncProjection
catalogMissingAsyncProjection =
  catalogAsyncProjection
    { name = "catalog-missing-async",
      subscriptionName = "catalog-missing-subscription"
    }

counterBinding :: QueryModelBinding Text ()
counterBinding =
  QueryModelBinding
    { queryModelId = counterQueryId,
      readModel = counterReadModel,
      rebuildGroup = mainGroupId,
      observedTargets = [counterTargetId],
      claimSite = site "catalog:counter-query"
    }

auditBinding :: QueryModelBinding Text ()
auditBinding =
  QueryModelBinding
    { queryModelId = auditQueryId,
      readModel = auditReadModel,
      rebuildGroup = mainGroupId,
      observedTargets = [auditTargetId],
      claimSite = site "catalog:audit-query"
    }

counterReadModel :: ReadModel Text ()
counterReadModel = readModelDefinition "catalog-counter-query" "counter"

auditReadModel :: ReadModel Text ()
auditReadModel = readModelDefinition "catalog-audit-query" "counter_audit"

readModelDefinition :: Text -> Text -> ReadModel Text ()
readModelDefinition registryName tableName =
  ReadModel
    { name = registryName,
      tableName = tableName,
      schema = "app",
      subscriptionName = "catalog-async-subscription",
      version = 1,
      shapeHash = registryName <> "-v1",
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \_ -> pure ()
    }

inlineProjectionId, asyncProjectionId, additiveProjectionId :: ProjectionId
inlineProjectionId = projection "counter-owner"
asyncProjectionId = projection "audit-owner"
additiveProjectionId = projection "catalog-additive-owner"

counterTargetId, auditTargetId, unknownTargetId, additiveTargetId :: TargetId
counterTargetId = target "counter-target"
auditTargetId = target "audit-target"
unknownTargetId = target "unknown-target"
additiveTargetId = target "catalog-additive-target"

mainGroupId, otherGroupId, unknownGroupId, additiveGroupId :: RebuildGroupId
mainGroupId = group "counter-group"
otherGroupId = group "other-group"
unknownGroupId = group "unknown-group"
additiveGroupId = group "catalog-additive-group"

headSourceId, additiveSourceId :: SourceId
headSourceId = source "counter-source"
additiveSourceId = source "catalog-additive-source"

counterQueryId, auditQueryId, additiveQueryId :: QueryModelId
counterQueryId = queryModel "counter-query"
auditQueryId = queryModel "audit-query"
additiveQueryId = queryModel "catalog-additive-query"

asyncSubscriptionId, unknownSubscriptionId :: SubscriptionId
asyncSubscriptionId = subscription "counter-subscription"
unknownSubscriptionId = subscription "unknown-subscription"

missingSubscriptionId :: SubscriptionId
missingSubscriptionId = subscription "missing-subscription"

asyncDedupId, unknownDedupId :: DedupKeyId
asyncDedupId = dedup "counter-dedup"
unknownDedupId = dedup "unknown-dedup"

missingDedupId :: DedupKeyId
missingDedupId = dedup "missing-dedup"

projection :: Text -> ProjectionId
projection = identityOrError mkProjectionId

target :: Text -> TargetId
target = identityOrError mkTargetId

group :: Text -> RebuildGroupId
group = identityOrError mkRebuildGroupId

source :: Text -> SourceId
source = identityOrError mkSourceId

queryModel :: Text -> QueryModelId
queryModel = identityOrError mkQueryModelId

subscription :: Text -> SubscriptionId
subscription = identityOrError mkSubscriptionId

dedup :: Text -> DedupKeyId
dedup = identityOrError mkDedupKeyId

site :: Text -> ClaimSite
site = identityOrError mkClaimSite

identityOrError :: (Text -> Either CatalogIdentityError identity) -> Text -> identity
identityOrError constructor value =
  case constructor value of
    Left err -> error (show err)
    Right identity -> identity
