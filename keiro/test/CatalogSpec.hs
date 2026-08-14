module CatalogSpec
  ( spec,
    CatalogEvent (..),
    validCatalog,
    bridgeCatalog,
    bridgeRevisionV1,
    bridgeRevisionV2,
    additiveCatalog,
    validProjectionSet,
    catalogWithMissingSubscription,
    catalogAsyncProjection,
    inlineProjectionId,
    asyncProjectionId,
    counterTargetId,
    auditTargetId,
    mainGroupId,
    additiveGroupId,
    counterBinding,
    counterReadContract,
  )
where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List qualified as List
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Keiro.Prelude
import Keiro.Projection (AsyncProjection (..), InlineProjection (..))
import Keiro.Projection.Catalog
import Keiro.ReadModel (ConsistencyMode (..), HeadScope (..), ReadModel (..), StrongScope (..))
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

  it "resolves several query models to one multi-target owner without list-order dependence" $ do
    validated <- expectValid sharedOwnerCatalog
    let supplies = resolvedQuerySupplies validated
    map (^. #resolvedQueryModelId) supplies
      `shouldBe` [auditQueryId, counterQueryId]
    map (^. #resolvedProjectionId) supplies
      `shouldBe` [sharedProjectionId, sharedProjectionId]
    map (^. #resolvedRebuildGroupId) supplies
      `shouldBe` [mainGroupId, mainGroupId]
    map (NonEmpty.toList . (^. #resolvedObservedTargets)) supplies
      `shouldBe` [[auditTargetId, counterTargetId], [counterTargetId]]
    map (^. #resolvedQueryFreshness) supplies
      `shouldBe` [InventoryImmediate, InventoryImmediate]
    map (^. #resolvedQueryCursor) supplies
      `shouldBe` [ Just (InventoryQueryCursor asyncSubscriptionId "catalog-async-subscription"),
                   Just (InventoryQueryCursor asyncSubscriptionId "catalog-async-subscription")
                 ]
    for_ supplies $ \supply -> do
      supply ^. #resolvedSourceId `shouldBe` headSourceId
      case NonEmpty.toList (supply ^. #resolvedHandlerCapabilities) of
        [ InlineCapability inlineName,
          SubscriptionCapability asyncName subscriptionId subscriptionName sourceId policy dedupKeyId dedupName
          ] -> do
            inlineName `shouldBe` "catalog-inline"
            asyncName `shouldBe` "catalog-async"
            subscriptionId `shouldBe` asyncSubscriptionId
            subscriptionName `shouldBe` "catalog-async-subscription"
            sourceId `shouldBe` headSourceId
            policy `shouldBe` FromBeginning
            dedupKeyId `shouldBe` asyncDedupId
            dedupName `shouldBe` "catalog-async"
        capabilities -> expectationFailure ("unexpected capabilities: " <> show capabilities)

    outerReordered <- expectValid (reverseCatalog sharedOwnerCatalog)
    resolvedQuerySupplies outerReordered `shouldBe` supplies
    catalogInventory outerReordered `shouldBe` catalogInventory validated
    catalogFingerprint outerReordered `shouldBe` catalogFingerprint validated
    groupSliceFingerprint outerReordered mainGroupId
      `shouldBe` groupSliceFingerprint validated mainGroupId

    ownedTargetsReordered <- expectValid reorderedSharedOwnerCatalog
    resolvedQuerySupplies ownedTargetsReordered `shouldBe` supplies
    catalogFingerprint ownedTargetsReordered `shouldBe` catalogFingerprint validated
    groupSliceFingerprint ownedTargetsReordered mainGroupId
      `shouldBe` groupSliceFingerprint validated mainGroupId

  it "derives cursor authority from the owner and validates waiting scope" $ do
    immediate <- expectValid validCatalog
    let immediateQueries = catalogInventory immediate ^. #inventoryQueryModels
    map (^. #freshness) immediateQueries
      `shouldBe` [InventoryImmediate, InventoryImmediate]
    map (^. #cursor) immediateQueries
      `shouldBe` [ Just (InventoryQueryCursor asyncSubscriptionId "catalog-async-subscription"),
                   Nothing
                 ]

    waiting <- expectValid (setQueryWait auditQueryId Strong (CategoryHead "counter") validCatalog)
    map (^. #freshness) (catalogInventory waiting ^. #inventoryQueryModels)
      `shouldBe` [InventoryWaitForHead (CategoryVisibleHead "counter"), InventoryImmediate]
    map (^. #resolvedQueryCursor) (resolvedQuerySupplies waiting)
      `shouldBe` [Just (InventoryQueryCursor asyncSubscriptionId "catalog-async-subscription"), Nothing]

    diagnosticsFor (setQueryWait counterQueryId Strong EntireLog validCatalog)
      `shouldSatisfy` hasDiagnostic
        QueryWaitWithoutCompatibleCursor
        (queryModelIdText counterQueryId)
    diagnosticsFor (setQueryWait auditQueryId Strong (CategoryHead "counter") catalogWithMissingSubscription)
      `shouldSatisfy` hasDiagnostic
        QueryWaitWithAmbiguousCursor
        (queryModelIdText auditQueryId)

    let wrongCategory =
          setQueryWait auditQueryId Strong (CategoryHead "orders") $
            validCatalog
              { sources = [headSource & #sourceScope .~ CategorySource (CategoryName "payments")]
              }
    diagnosticsFor wrongCategory
      `shouldSatisfy` hasDiagnostic
        QueryWaitWithoutCompatibleCursor
        (queryModelIdText auditQueryId)

  it "fingerprints freshness and cursor policy only in the owning group slice" $ do
    immediate <- expectValid additiveCatalog
    waiting <- expectValid (setQueryWait auditQueryId Strong (CategoryHead "counter") additiveCatalog)
    catalogFingerprint waiting `shouldNotBe` catalogFingerprint immediate
    groupSliceFingerprint waiting mainGroupId
      `shouldNotBe` groupSliceFingerprint immediate mainGroupId
    groupSliceFingerprint waiting additiveGroupId
      `shouldBe` groupSliceFingerprint immediate additiveGroupId
    renderCatalogInventory waiting
      `shouldSatisfy` Text.isInfixOf "wait-for-head:category-visible-head:counter"

  it "rejects empty and split-owner query target sets with stable derived diagnostics" $ do
    let emptyObserved =
          sharedOwnerCatalog
            { queryModels =
                [ SomeQueryModelBinding (counterBinding & #observedTargets .~ []),
                  SomeQueryModelBinding (auditBinding & #observedTargets .~ [auditTargetId, counterTargetId])
                ]
            }
        splitOwners =
          validCatalog
            { queryModels =
                [ SomeQueryModelBinding counterBinding,
                  SomeQueryModelBinding (auditBinding & #observedTargets .~ [auditTargetId, counterTargetId])
                ]
            }
        emptyDiagnostics = diagnosticsFor emptyObserved
        splitDiagnostics = diagnosticsFor splitOwners
    emptyDiagnostics
      `shouldSatisfy` hasDiagnostic EmptyQueryObservedTargets (queryModelIdText counterQueryId)
    map (^. #diagnosticCode) splitDiagnostics
      `shouldSatisfy` (== [QueryModelWithMultipleSuppliers])
    map claimSiteText (splitDiagnostics ^?! ix 0 . #diagnosticSites)
      `shouldBe` ["catalog:async", "catalog:audit-query", "catalog:inline"]

    let missingOwnerDiagnostics = diagnosticsFor (catalogWithDefinitions (inlineDefinition :| []))
    missingOwnerDiagnostics
      `shouldSatisfy` hasDiagnostic TargetWithoutOwner (targetIdText auditTargetId)
    missingOwnerDiagnostics
      `shouldSatisfy` all ((/= QueryModelWithoutSupplier) . (^. #diagnosticCode))

  it "keeps supply derived from canonical owner and observed-target facts" $ do
    shared <- expectValid sharedOwnerCatalog
    split <- expectValid validCatalog
    observedSubset <-
      expectValid
        sharedOwnerCatalog
          { queryModels =
              [ SomeQueryModelBinding counterBinding,
                SomeQueryModelBinding auditBinding
              ]
          }
    catalogFingerprint shared `shouldNotBe` catalogFingerprint split
    groupSliceFingerprint shared mainGroupId
      `shouldNotBe` groupSliceFingerprint split mainGroupId
    catalogFingerprint shared `shouldNotBe` catalogFingerprint observedSubset
    groupSliceFingerprint shared mainGroupId
      `shouldNotBe` groupSliceFingerprint observedSubset mainGroupId
    let beforeAccessor = catalogFingerprint shared
    resolvedQuerySupplies shared `shouldSatisfy` (not . null)
    catalogFingerprint shared `shouldBe` beforeAccessor

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

  describe "projection revisions" $ do
    it "accepts a v1/v2 bridge and inventories every durable revision fact canonically" $ do
      validated <- expectValid bridgeCatalog
      let revisions = catalogInventory validated ^. #inventoryProjectionRevisions
      map (^. #revisionId) revisions `shouldBe` [revision "counter-v1", revision "counter-v2"]
      map (^. #schemaVersion) (revisions ^.. folded . #targetProvisioners . folded)
        `shouldBe` replicate 2 (TargetSchemaVersion "v1") <> replicate 2 (TargetSchemaVersion "v2")

      reordered <- expectValid (reverseCatalog bridgeCatalog)
      catalogInventory reordered `shouldBe` catalogInventory validated
      catalogFingerprint reordered `shouldBe` catalogFingerprint validated
      groupSliceFingerprint reordered mainGroupId
        `shouldBe` groupSliceFingerprint validated mainGroupId

    it "constructs physical target mappings only when they are closed-world total" $ do
      let supplied =
            Map.fromList
              [ (counterTargetId, QualifiedTable "generation" "counter"),
                (unknownTargetId, QualifiedTable "generation" "unexpected")
              ]
      mkPhysicalTargets [counterTargetId, auditTargetId] supplied
        `shouldBe` Left (MissingPhysicalTarget auditTargetId :| [UnexpectedPhysicalTarget unknownTargetId])
      mkPhysicalTargets
        [counterTargetId, auditTargetId]
        (Map.fromList [(counterTargetId, QualifiedTable "generation" "counter"), (auditTargetId, QualifiedTable "generation" "audit")])
        `shouldSatisfy` (\case Right _ -> True; Left _ -> False)

    it "accumulates stable bridge diagnostics for incomplete revisions and stale read contracts" $ do
      let malformedV1 =
            bridgeRevisionV1
              & #liveHandlers
              .~ []
              & #replayAdapters
              .~ []
              & #targetProvisioners
              .~ Map.insert
                unknownTargetId
                (targetProvisioner "unknown" (TargetSchemaVersion "v1") [] & #validateTarget .~ Nothing)
                (Map.delete auditTargetId (bridgeRevisionV1 ^. #targetProvisioners))
          partialV2 =
            bridgeRevisionV2
              & #liveHandlers
              .~ [ RevisionLiveHandler
                     "counter-v2-live"
                     1
                     [counterTargetId]
                     (\_ _ -> pure ())
                 ]
          invalid =
            bridgeCatalog
              { projectionRevisions = [malformedV1, partialV2, bridgeRevisionV2],
                externalReadContracts =
                  [ counterReadContract
                      & #compatibleRevisions
                      .~ (revision "counter-v3" :| [])
                  ]
              }
          diagnostics = diagnosticsFor invalid
      for_
        [ DuplicateProjectionRevisionId,
          UnknownRevisionReference,
          UnknownTargetProvisioner,
          ProjectionRevisionWithoutLiveHandler,
          ProjectionRevisionWithoutReplayAdapter,
          ProjectionRevisionTargetSetDrift,
          ProjectionRevisionMissingSchemaValidation,
          ProjectionRevisionPhysicalTargetsNotTotal
        ]
        (\code -> diagnostics `shouldSatisfy` any ((== code) . (^. #diagnosticCode)))
      diagnosticsFor (reverseCatalog invalid) `shouldBe` diagnostics

    it "fingerprints revision schema, provider, validator, handler, replay, verification, and promotion order" $ do
      baseline <- expectValid bridgeCatalog
      let mutateV2 update =
            bridgeCatalog
              { projectionRevisions = [bridgeRevisionV1, update bridgeRevisionV2]
              }
          variants =
            [ mutateV2 (adjustCounterProvisioner (#schemaVersion .~ TargetSchemaVersion "v2.1")),
              mutateV2 (adjustCounterProvisioner (#provisionerVersion .~ 2)),
              mutateV2 (adjustCounterProvisioner (#validatorVersion .~ 2)),
              mutateV2 (adjustCounterProvisioner (\p -> p & #promotionObjectNames %~ reverse)),
              mutateV2 (\value -> value & #liveHandlers %~ map (#handlerVersion .~ 3)),
              mutateV2 (\value -> value & #replayAdapters %~ map (#adapterVersion .~ 3)),
              mutateV2 (\value -> value & #revisionVerifications %~ map (#revisionVerificationVersion .~ 3))
            ]
      for_ (zip ["schema", "provisioner", "validator", "promotion-order", "live", "replay", "verification"] variants) $ \(label, variant) -> do
        changed <- expectValid variant
        when (catalogFingerprint changed == catalogFingerprint baseline) $
          expectationFailure ("catalog fingerprint ignored revision " <> label <> " identity")
        when (groupSliceFingerprint changed mainGroupId == groupSliceFingerprint baseline mainGroupId) $
          expectationFailure ("group slice fingerprint ignored revision " <> label <> " identity")

  describe "external read contracts" $ do
    it "validates and inventories a versioned all-row contract canonically" $ do
      validated <- expectValid bridgeCatalog
      catalogExternalReadContracts validated `shouldBe` [counterReadContract]
      case catalogInventory validated ^. #inventoryExternalReadContracts of
        [contract] -> do
          contract ^. #readContractId `shouldBe` identityOrError mkExternalReadContractId "counter_reader"
          contract ^. #contractVersion `shouldBe` ExternalReadContractVersion 1
          contract ^. #functionName `shouldBe` "counter_reader_v1"
          contract ^. #resultShapeHash `shouldBe` "catalog-counter-query-v1"
          NonEmpty.toList (contract ^. #compatibleRevisions)
            `shouldBe` [revision "counter-v1", revision "counter-v2"]
        contracts -> expectationFailure ("unexpected contracts: " <> show contracts)

      let reorderedContract = counterReadContract & #compatibleRevisions %~ NonEmpty.reverse
      reordered <- expectValid (bridgeCatalog {externalReadContracts = [reorderedContract]})
      catalogInventory reordered `shouldBe` catalogInventory validated
      catalogFingerprint reordered `shouldBe` catalogFingerprint validated
      groupSliceFingerprint reordered mainGroupId
        `shouldBe` groupSliceFingerprint validated mainGroupId

    it "accumulates query, shape, revision, SQL, collision, generation, and immutable-signature diagnostics" $ do
      let unknownQuery = counterReadContract & #queryModelId .~ queryModel "missing-query"
          wrongShape = counterReadContract & #resultShapeHash .~ "counter-v2-shape"
          unknownRevision = counterReadContract & #compatibleRevisions .~ (revision "missing" :| [])
          wrongOwnerCatalog =
            bridgeCatalog
              { projectionRevisions =
                  [ bridgeRevisionV1,
                    bridgeRevisionV2 & #rebuildGroup .~ otherGroupId
                  ],
                externalReadContracts =
                  [ counterReadContract
                      & #compatibleRevisions
                      .~ (revision "counter-v2" :| [])
                  ]
              }
          unsafeContract =
            keyedCounterContractWith
              "Unsafe-Reader"
              [SqlFunctionArgument "bad-name" (QualifiedSqlType "pg_catalog" "text[]")]
              (QualifiedSqlType "app_contract" "counter_row_v1")
              (QualifiedFunction "app_private" "lookup_counter")
              1
          duplicateAndDrift = [counterReadContract, keyedCounterContract]
          sharedImplementation = QualifiedFunction "app_private" "lookup_counter"
          implementationCollision =
            [ keyedCounterContract & #readContractId .~ identityOrError mkExternalReadContractId "counter_reader_one",
              keyedCounterContractWith
                "counter_reader_two"
                [SqlFunctionArgument "counter_id" (QualifiedSqlType "pg_catalog" "text")]
                (QualifiedSqlType "app_contract" "counter_row_v1")
                sharedImplementation
                1
            ]
          generationRegression =
            [ counterReadContract & #surfaceGeneration .~ 2,
              counterReadContract
                & #contractVersion
                .~ ExternalReadContractVersion 2
                & #surfaceGeneration
                .~ 1
            ]
          codesFor contracts = map (^. #diagnosticCode) (diagnosticsFor (bridgeCatalog {externalReadContracts = contracts}))
      codesFor [unknownQuery] `shouldSatisfy` List.elem UnknownExternalReadQueryModel
      codesFor [wrongShape] `shouldSatisfy` List.elem ExternalReadShapeMismatch
      codesFor [unknownRevision] `shouldSatisfy` List.elem UnknownRevisionReference
      map (^. #diagnosticCode) (diagnosticsFor wrongOwnerCatalog)
        `shouldSatisfy` List.elem ExternalReadRevisionOwnershipMismatch
      codesFor [unsafeContract] `shouldSatisfy` List.elem InvalidExternalReadSqlIdentifier
      codesFor [unsafeContract] `shouldSatisfy` List.elem InvalidExternalReadSqlType
      codesFor duplicateAndDrift `shouldSatisfy` List.elem DuplicateExternalReadContractVersion
      codesFor duplicateAndDrift `shouldSatisfy` List.elem DuplicateExternalReadFunctionName
      codesFor duplicateAndDrift `shouldSatisfy` List.elem ExternalReadImmutableSignatureDrift
      codesFor implementationCollision `shouldSatisfy` List.elem ExternalReadImplementationCollision
      codesFor generationRegression `shouldSatisfy` List.elem ExternalReadSurfaceGenerationRegression

    it "fingerprints every contract fact in only the owning group slice" $ do
      baseline <- expectValid bridgeCatalog
      let variants =
            [ counterReadContract & #readContractId .~ identityOrError mkExternalReadContractId "counter_reader_renamed",
              counterReadContract & #contractVersion .~ ExternalReadContractVersion 2,
              counterReadContract & #compatibleRevisions .~ (revision "counter-v2" :| []),
              counterReadContract & #surfaceGeneration .~ 2,
              keyedCounterContract,
              keyedCounterContractWith
                "counter_reader"
                [SqlFunctionArgument "counter_id" (QualifiedSqlType "pg_catalog" "text")]
                (QualifiedSqlType "app_contract" "counter_row_v1")
                (QualifiedFunction "app_private" "lookup_counter")
                2,
              keyedCounterContractWith
                "counter_reader"
                [SqlFunctionArgument "counter_id" (QualifiedSqlType "pg_catalog" "uuid")]
                (QualifiedSqlType "app_contract" "counter_row_v1")
                (QualifiedFunction "app_private" "lookup_counter")
                1,
              keyedCounterContractWith
                "counter_reader"
                [SqlFunctionArgument "counter_id" (QualifiedSqlType "pg_catalog" "text")]
                (QualifiedSqlType "app_contract" "counter_row_v2")
                (QualifiedFunction "app_private" "lookup_counter")
                1
            ]
      for_ variants $ \contract -> do
        changed <- expectValid (bridgeCatalog {externalReadContracts = [contract]})
        catalogFingerprint changed `shouldNotBe` catalogFingerprint baseline
        groupSliceFingerprint changed mainGroupId
          `shouldNotBe` groupSliceFingerprint baseline mainGroupId

  it "keeps baseline removal comparison separate from single-catalog validity" $ do
    previous <- expectValid validCatalog
    current <- expectValid smallerCatalog
    compareCatalogBaseline (catalogInventory previous) (catalogInventory current)
      `shouldSatisfy` List.elem (TargetRemoved auditTargetId)

    previousBridge <- expectValid bridgeCatalog
    currentWithoutBridge <- expectValid validCatalog
    compareCatalogBaseline (catalogInventory previousBridge) (catalogInventory currentWithoutBridge)
      `shouldSatisfy` List.elem (ProjectionRevisionRemoved (revision "counter-v1"))
    compareCatalogBaseline (catalogInventory previousBridge) (catalogInventory currentWithoutBridge)
      `shouldSatisfy` List.elem
        ( ExternalReadContractRemoved
            (identityOrError mkExternalReadContractId "counter_reader")
            (ExternalReadContractVersion 1)
        )

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
      projectionRevisions = [],
      externalReadContracts = [],
      subscriptions = [catalogSubscription],
      dedupKeys = [catalogDedup],
      queryModels =
        [ SomeQueryModelBinding counterBinding,
          SomeQueryModelBinding auditBinding
        ],
      projectionSets = [SomeProjectionSet validProjectionSet]
    }

bridgeCatalog :: ProjectionCatalog
bridgeCatalog =
  validCatalog
    { projectionRevisions = [bridgeRevisionV1, bridgeRevisionV2],
      externalReadContracts = [counterReadContract]
    }

counterReadContract :: ExternalReadContract
counterReadContract =
  AllRowsExternalRead
    { readContractId = identityOrError mkExternalReadContractId "counter_reader",
      contractVersion = ExternalReadContractVersion 1,
      queryModelId = counterQueryId,
      resultContractType = QualifiedSqlType "app_contract" "counter_row_v1",
      resultShapeHash = "catalog-counter-query-v1",
      compatibleRevisions = revision "counter-v1" :| [revision "counter-v2"],
      surfaceGeneration = 1,
      claimSite = site "catalog:counter-reader"
    }

keyedCounterContract :: ExternalReadContract
keyedCounterContract =
  keyedCounterContractWith
    "counter_reader"
    [SqlFunctionArgument "counter_id" (QualifiedSqlType "pg_catalog" "text")]
    (QualifiedSqlType "app_contract" "counter_row_v1")
    (QualifiedFunction "app_private" "lookup_counter")
    1

keyedCounterContractWith :: Text -> [SqlFunctionArgument] -> QualifiedSqlType -> QualifiedFunction -> Int -> ExternalReadContract
keyedCounterContractWith identity functionArguments resultType implementation implementationVersion =
  KeyedExternalRead
    { readContractId = identityOrError mkExternalReadContractId identity,
      contractVersion = ExternalReadContractVersion 1,
      queryModelId = counterQueryId,
      arguments = functionArguments,
      resultContractType = resultType,
      privateImplementation = implementation,
      privateImplementationVersion = implementationVersion,
      resultShapeHash = "catalog-counter-query-v1",
      compatibleRevisions = revision "counter-v1" :| [revision "counter-v2"],
      surfaceGeneration = 1,
      claimSite = site "catalog:counter-reader-keyed"
    }

bridgeRevisionV1 :: ProjectionRevision
bridgeRevisionV1 = bridgeRevision "counter-v1" "v1" 1

bridgeRevisionV2 :: ProjectionRevision
bridgeRevisionV2 = bridgeRevision "counter-v2" "v2" 2

bridgeRevision :: Text -> Text -> Int -> ProjectionRevision
bridgeRevision identity schema version =
  ProjectionRevision
    { revisionId = revision identity,
      rebuildGroup = mainGroupId,
      targetProvisioners =
        Map.fromList
          [ ( counterTargetId,
              targetProvisioner
                (identity <> "-counter")
                (TargetSchemaVersion schema)
                [ PromotionObjectName PromotionIndex ("counter_idx__" <> schema) "counter_idx",
                  PromotionObjectName PromotionOwnedSequence ("counter_id_seq__" <> schema) "counter_id_seq"
                ]
            ),
            ( auditTargetId,
              targetProvisioner
                (identity <> "-audit")
                (TargetSchemaVersion schema)
                [PromotionObjectName PromotionConstraint ("counter_audit_pkey__" <> schema) "counter_audit_pkey"]
            )
          ],
      liveHandlers =
        [ RevisionLiveHandler
            (identity <> "-live")
            version
            [counterTargetId, auditTargetId]
            (\_ _ -> pure ())
        ],
      replayAdapters =
        [ RevisionReplayAdapter
            (identity <> "-replay")
            version
            [counterTargetId, auditTargetId]
            (\_ _ -> pure (Right False))
        ],
      revisionVerifications =
        [ RevisionVerification
            (identity <> "-verification")
            version
            [counterTargetId, auditTargetId]
            (\_ -> pure (Right ()))
        ],
      claimSite = site ("catalog:" <> identity)
    }

targetProvisioner :: Text -> TargetSchemaVersion -> [PromotionObjectName] -> TargetProvisioner
targetProvisioner identity schema promotionObjects =
  TargetProvisioner
    { provisionerId = identity <> "-provisioner",
      provisionerVersion = 1,
      schemaVersion = schema,
      expectedShapeId = identity <> "-shape",
      provisionTarget = \_ -> pure (),
      validatorId = identity <> "-validator",
      validatorVersion = 1,
      validateTarget =
        Just
          ( \_ ->
              pure
                ( Right
                    TargetSchemaEvidence
                      { relationOid = 1,
                        observedShapeFingerprint = identity <> "-shape",
                        observedPromotionObjects = promotionObjects,
                        catalogSnapshot = "catalog-snapshot-v1"
                      }
                )
          ),
      promotionObjectNames = promotionObjects
    }

adjustCounterProvisioner :: (TargetProvisioner -> TargetProvisioner) -> ProjectionRevision -> ProjectionRevision
adjustCounterProvisioner update value =
  value & #targetProvisioners %~ Map.adjust update counterTargetId

sharedOwnerCatalog :: ProjectionCatalog
sharedOwnerCatalog = sharedOwnerCatalogWithOrders (counterTargetId :| [auditTargetId]) [auditTargetId, counterTargetId]

reorderedSharedOwnerCatalog :: ProjectionCatalog
reorderedSharedOwnerCatalog =
  reverseCatalog
    (sharedOwnerCatalogWithOrders (auditTargetId :| [counterTargetId]) [counterTargetId, auditTargetId])

sharedOwnerCatalogWithOrders :: NonEmpty TargetId -> [TargetId] -> ProjectionCatalog
sharedOwnerCatalogWithOrders owned observed =
  validCatalog
    { queryModels =
        [ SomeQueryModelBinding counterBinding,
          SomeQueryModelBinding (auditBinding & #observedTargets .~ observed)
        ],
      projectionSets =
        [ SomeProjectionSet
            validProjectionSet
              { projectionDefinitions =
                  inlineDefinition
                    { projectionId = sharedProjectionId,
                      ownedTargets = owned,
                      handlers =
                        InlineHandler catalogInlineProjection (site "catalog:inline-handler")
                          :| [AsyncHandler catalogAsyncProjection asyncSubscriptionId asyncDedupId (site "catalog:async-handler")],
                      claimSite = site "catalog:shared-owner"
                    }
                    :| []
              }
        ]
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
      projectionRevisions = reverse (catalog ^. #projectionRevisions),
      externalReadContracts = reverse (catalog ^. #externalReadContracts),
      subscriptions = reverse (catalog ^. #subscriptions),
      dedupKeys = reverse (catalog ^. #dedupKeys),
      queryModels = reverse (catalog ^. #queryModels),
      projectionSets = reverse (catalog ^. #projectionSets)
    }

setQueryWait :: QueryModelId -> ConsistencyMode -> StrongScope -> ProjectionCatalog -> ProjectionCatalog
setQueryWait wanted consistency scope catalog =
  catalog
    { queryModels = map updateBinding (catalog ^. #queryModels)
    }
  where
    updateBinding (SomeQueryModelBinding binding)
      | binding ^. #queryModelId == wanted =
          SomeQueryModelBinding
            ( binding
                & #readModel
                . #defaultConsistency
                .~ consistency
                & #readModel
                . #strongScope
                .~ scope
            )
      | otherwise = SomeQueryModelBinding binding

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

inlineProjectionId, asyncProjectionId, additiveProjectionId, sharedProjectionId :: ProjectionId
inlineProjectionId = projection "counter-owner"
asyncProjectionId = projection "audit-owner"
additiveProjectionId = projection "catalog-additive-owner"
sharedProjectionId = projection "shared-owner"

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

revision :: Text -> ProjectionRevisionId
revision = identityOrError mkProjectionRevisionId

site :: Text -> ClaimSite
site = identityOrError mkClaimSite

identityOrError :: (Text -> Either CatalogIdentityError identity) -> Text -> identity
identityOrError constructor value =
  case constructor value of
    Left err -> error (show err)
    Right identity -> identity
