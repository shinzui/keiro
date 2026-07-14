{- | The spec evolution differ. 'diffSpecs' compares an /old/ and a /new/ 'Spec'
and classifies changes over the persisted decode and identity surfaces.

Changes are __ADDITIVE__ when they preserve stored data, __WARNING__ when they
change forward behaviour without invalidating persisted data, and __BREAKING__
when stored payloads may stop decoding or persisted identities may be re-keyed.
The @diff --since@ CLI exits non-zero only when a breaking change is present.

Every 'Node' constructor maps to a 'NodeFamily', and 'familyRegistry' contains
exactly one entry for each family.  A family is either handled by an explicit
differ or carries a non-empty out-of-scope rationale.  This makes omissions
visible when the grammar grows instead of silently treating new node kinds as
safe.
-}
module Keiro.Dsl.Diff (
    Change (..),
    ChangeKind (..),
    isBreaking,
    isAdvisory,
    diffSpecs,
    DiffEnv (..),
    NodeFamily (..),
    familyOf,
    FamilyDiff (..),
    familyRegistry,
    Paired (..),
    pairByName,
    readModelDiff,
    classifyWorkflowBody,
) where

import Data.List (find, (\\))
import Data.Maybe (isJust, isNothing, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar
import Keiro.Dsl.ReadModelShape (registryNameFor, subscriptionNameFor)
import Keiro.Dsl.Validate (DiagnosticCode (..))

-- | A classified spec change.
data Change
    = Additive ChangeKind
    | Advisory ChangeKind
    | Breaking ChangeKind
    deriving stock (Eq, Show)

data ChangeKind = ChangeKind
    { ckNode :: !Name
    , ckFacet :: !Text
    , ckSubject :: !Text
    , ckCode :: !(Maybe DiagnosticCode)
    , ckDetail :: !Text
    }
    deriving stock (Eq, Show)

isBreaking :: Change -> Bool
isBreaking (Breaking _) = True
isBreaking (Additive _) = False
isBreaking (Advisory _) = False

isAdvisory :: Change -> Bool
isAdvisory (Advisory _) = True
isAdvisory (Additive _) = False
isAdvisory (Breaking _) = False

-- | Both specs supplied to a node-family differ, always old then new.
data DiffEnv = DiffEnv
    { deOld :: !Spec
    , deNew :: !Spec
    }
    deriving stock (Eq, Show)

-- | The closed set of node families currently present in 'Node'.
data NodeFamily
    = FamAggregate
    | FamProcess
    | FamRouter
    | FamContract
    | FamIntake
    | FamEmit
    | FamPublisher
    | FamWorkqueue
    | FamPgmqDispatch
    | FamReadModel
    | FamWorkflow
    | FamOperation
    deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Total by construction: one explicit arm per 'Node' constructor.
familyOf :: Node -> NodeFamily
familyOf (NAggregate _) = FamAggregate
familyOf (NProcess _) = FamProcess
familyOf (NRouter _) = FamRouter
familyOf (NContract _) = FamContract
familyOf (NIntake _) = FamIntake
familyOf (NEmit _) = FamEmit
familyOf (NPublisher _) = FamPublisher
familyOf (NWorkqueue _) = FamWorkqueue
familyOf (NPgmqDispatch _) = FamPgmqDispatch
familyOf (NReadModel _) = FamReadModel
familyOf (NWorkflow _) = FamWorkflow
familyOf (NOperation _) = FamOperation

-- | A family either has a differ or an explicit reason it is not compared.
data FamilyDiff
    = DiffFamily (DiffEnv -> [Change])
    | OutOfDiffScope Text

-- | Pair the old and new declarations of one node family by stable name.
data Paired n = Paired
    { prMatched :: ![(n, n)]
    , prAdded :: ![n]
    , prRemoved :: ![n]
    }
    deriving stock (Eq, Show)

pairByName :: (Node -> Maybe n) -> (n -> Name) -> DiffEnv -> Paired n
pairByName project nameOf env =
    Paired
        { prMatched =
            [ (oldNode, newNode)
            | newNode <- newNodes
            , Just oldNode <- [find ((== nameOf newNode) . nameOf) oldNodes]
            ]
        , prAdded =
            [ newNode
            | newNode <- newNodes
            , isNothing (find ((== nameOf newNode) . nameOf) oldNodes)
            ]
        , prRemoved =
            [ oldNode
            | oldNode <- oldNodes
            , isNothing (find ((== nameOf oldNode) . nameOf) newNodes)
            ]
        }
  where
    oldNodes = mapMaybe project (specNodes (deOld env))
    newNodes = mapMaybe project (specNodes (deNew env))

{- | Registry invariant: every 'Node' constructor maps to a family via the
total 'familyOf' case, and every family occurs exactly once here.  The unit
suite enforces registry coverage and non-empty out-of-scope rationales.
-}
familyRegistry :: [(NodeFamily, FamilyDiff)]
familyRegistry =
    [ (FamAggregate, DiffFamily aggregateDiff)
    , (FamProcess, DiffFamily processDiff)
    , (FamRouter, DiffFamily routerDiff)
    , (FamContract, DiffFamily contractDiff)
    , (FamIntake, DiffFamily intakeDiff)
    , (FamEmit, DiffFamily emitDiff)
    , (FamPublisher, DiffFamily publisherDiff)
    , (FamWorkqueue, DiffFamily workqueueDiff)
    , (FamPgmqDispatch, DiffFamily pgmqDispatchDiff)
    , (FamReadModel, DiffFamily readModelDiff)
    , (FamWorkflow, DiffFamily workflowDiff)
    , (FamOperation, OutOfDiffScope "operations own no persisted decode or identity surface; their references and workflow signal/await pairing are single-spec validation concerns")
    ]

diffSpecs :: Spec -> Spec -> [Change]
diffSpecs old new =
    sharedDeclarationDiff env
        ++ concatMap (runFamily env . snd) familyRegistry
  where
    env = DiffEnv old new

runFamily :: DiffEnv -> FamilyDiff -> [Change]
runFamily env (DiffFamily f) = f env
runFamily _ (OutOfDiffScope _) = []

-- Rules are intentionally outside the decode/identity axes: they alter guard
-- behaviour but neither interpret stored bytes nor derive persisted keys.
-- Shared id and enum declarations become diffed in Milestones 2 and 4.
sharedDeclarationDiff :: DiffEnv -> [Change]
sharedDeclarationDiff env = enumDiff env ++ idDiff env

nodeAggregate :: Node -> Maybe Aggregate
nodeAggregate (NAggregate a) = Just a
nodeAggregate _ = Nothing

nodeProcess :: Node -> Maybe ProcessNode
nodeProcess (NProcess process) = Just process
nodeProcess _ = Nothing

nodeRouter :: Node -> Maybe RouterNode
nodeRouter (NRouter router) = Just router
nodeRouter _ = Nothing

nodeContract :: Node -> Maybe ContractNode
nodeContract (NContract contract) = Just contract
nodeContract _ = Nothing

nodeIntake :: Node -> Maybe IntakeNode
nodeIntake (NIntake intake) = Just intake
nodeIntake _ = Nothing

nodeEmit :: Node -> Maybe EmitNode
nodeEmit (NEmit emit) = Just emit
nodeEmit _ = Nothing

nodePublisher :: Node -> Maybe PublisherNode
nodePublisher (NPublisher publisher) = Just publisher
nodePublisher _ = Nothing

nodeWorkqueue :: Node -> Maybe WorkqueueNode
nodeWorkqueue (NWorkqueue workqueue) = Just workqueue
nodeWorkqueue _ = Nothing

nodePgmqDispatch :: Node -> Maybe PgmqDispatchNode
nodePgmqDispatch (NPgmqDispatch dispatch) = Just dispatch
nodePgmqDispatch _ = Nothing

nodeReadModel :: Node -> Maybe ReadModelNode
nodeReadModel (NReadModel readModel) = Just readModel
nodeReadModel _ = Nothing

nodeWorkflow :: Node -> Maybe WorkflowNode
nodeWorkflow (NWorkflow workflow) = Just workflow
nodeWorkflow _ = Nothing

{- | Router identity is replay-sensitive: the stable name and key feed every
target-keyed dispatch id, and the target selects the persisted stream family.
-}
routerDiff :: DiffEnv -> [Change]
routerDiff env =
    concatMap (uncurry routerPairDiff) (prMatched paired)
        ++ [additive (rtId router) "router" (rtId router) "new router declaration" | router <- prAdded paired]
        ++ [breaking (rtId router) "router-identity" (rtId router) RouterStableNameChanged "router removed while replayable source events may still derive target-keyed dispatch ids from its stable identity" | router <- prRemoved paired]
  where
    paired = pairByName nodeRouter rtId env

routerPairDiff :: RouterNode -> RouterNode -> [Change]
routerPairDiff oldRouter newRouter = stableName ++ keyDerivation ++ target
  where
    nodeName = rtId newRouter
    stableName =
        [ breaking nodeName "router-stable-name" nodeName RouterStableNameChanged $
            "router stable name changed from '" <> rtName oldRouter <> "' to '" <> rtName newRouter <> "'; every deterministicRouterCommandId is re-keyed, so redelivery can duplicate the full resolved fan-out"
        | rtName oldRouter /= rtName newRouter
        ]
    keyDerivation =
        [ breaking nodeName "router-key" (corrField (rtKey newRouter)) DerivedIdentityChanged "router key field or derivation changed; replay derives different target dispatch ids"
        | rtKey oldRouter /= rtKey newRouter
        ]
    target =
        [ breaking nodeName "router-target" (rtTarget newRouter) DerivedIdentityChanged "router target aggregate changed; replay addresses a different persisted stream family"
        | rtTarget oldRouter /= rtTarget newRouter
        ]

readModelDiff :: DiffEnv -> [Change]
readModelDiff env =
    concatMap (uncurry (readModelPairDiff env)) (prMatched paired)
        ++ concatMap addedReadModelDiff (prAdded paired)
        ++ concatMap removedReadModelDiff (prRemoved paired)
  where
    paired = pairByName nodeReadModel rmName env

readModelPairDiff :: DiffEnv -> ReadModelNode -> ReadModelNode -> [Change]
readModelPairDiff env oldReadModel newReadModel =
    versionChanges
        ++ shapeChanges
        ++ identityChanges
        ++ feedChanges
        ++ consistencyChanges
        ++ scopeChanges
  where
    nodeName = rmName newReadModel
    versionChanges
        | rmVersion newReadModel < rmVersion oldReadModel =
            [ breaking nodeName "read-model-version" nodeName ReadModelVersionDecreased ("version decreased from " <> tInt (rmVersion oldReadModel) <> " to " <> tInt (rmVersion newReadModel))
            ]
        | rmVersion newReadModel > rmVersion oldReadModel =
            [ additive nodeName "read-model-version" nodeName ("version increased from " <> tInt (rmVersion oldReadModel) <> " to " <> tInt (rmVersion newReadModel) <> "; register and rebuild the new shape before serving it")
            ]
        | otherwise = []
    oldShape = (rmColumns oldReadModel, rmShape oldReadModel)
    newShape = (rmColumns newReadModel, rmShape newReadModel)
    shapeChanges =
        [ breaking nodeName "read-model-shape" nodeName ReadModelShapeChangedWithoutBump ("declared columns or captured shape hash changed at version " <> tInt (rmVersion newReadModel) <> "; bump version and rebuild")
        | oldShape /= newShape
        , rmVersion oldReadModel == rmVersion newReadModel
        ]
    oldRegistry = registryNameFor (specContext (deOld env)) oldReadModel
    newRegistry = registryNameFor (specContext (deNew env)) newReadModel
    oldSubscription = subscriptionNameFor (specContext (deOld env)) oldReadModel
    newSubscription = subscriptionNameFor (specContext (deNew env)) newReadModel
    identityChanges =
        [ breaking nodeName "read-model-identity" nodeName DerivedIdentityChanged ("registry name changed '" <> oldRegistry <> "' -> '" <> newRegistry <> "'; the old registration row is orphaned")
        | oldRegistry /= newRegistry
        ]
            ++ [ breaking nodeName "read-model-table" nodeName DerivedIdentityChanged ("qualified table changed '" <> qualifiedIdentity oldReadModel <> "' -> '" <> qualifiedIdentity newReadModel <> "'; existing data remains under the old identity")
               | (rmSchema oldReadModel, rmTable oldReadModel) /= (rmSchema newReadModel, rmTable newReadModel)
               ]
            ++ [ breaking nodeName "read-model-subscription" nodeName DerivedIdentityChanged ("subscription changed '" <> oldSubscription <> "' -> '" <> newSubscription <> "'; the worker cursor remains under the old identity")
               | oldSubscription /= newSubscription
               ]
    feedChanges =
        [ breaking nodeName "read-model-feed" nodeName ReadModelFeedChanged ("feed changed " <> renderFeed (rmFeed oldReadModel) <> " -> " <> renderFeed (rmFeed newReadModel) <> "; projection wiring and rebuild identities changed")
        | rmFeed oldReadModel /= rmFeed newReadModel
        ]
    consistencyChanges = case (rmConsistency oldReadModel, rmConsistency newReadModel) of
        (Strong, Eventual) ->
            [breaking nodeName "read-model-consistency" nodeName ReadModelConsistencyWeakened "default consistency changed Strong -> Eventual; callers lose the cursor-wait guarantee"]
        (Eventual, Strong) ->
            [additive nodeName "read-model-consistency" nodeName "default consistency changed Eventual -> Strong; callers gain a cursor-wait guarantee"]
        _ -> []
    oldScope = effectiveScope (rmScope oldReadModel)
    newScope = effectiveScope (rmScope newReadModel)
    scopeChanges
        | oldScope == newScope = []
        | scopeStrengthened oldScope newScope =
            [additive nodeName "read-model-scope" nodeName ("Strong scope widened " <> renderScope oldScope <> " -> " <> renderScope newScope)]
        | otherwise =
            [breaking nodeName "read-model-scope" nodeName ReadModelConsistencyWeakened ("Strong scope changed " <> renderScope oldScope <> " -> " <> renderScope newScope <> "; callers no longer wait on the same event surface")]

addedReadModelDiff :: ReadModelNode -> [Change]
addedReadModelDiff readModel =
    [additive (rmName readModel) "read-model" (rmName readModel) "new read model"]

removedReadModelDiff :: ReadModelNode -> [Change]
removedReadModelDiff readModel =
    [breaking (rmName readModel) "read-model-identity" (rmName readModel) DerivedIdentityChanged "read model removed while registered metadata, data, subscription cursors, and callers may remain"]

qualifiedIdentity :: ReadModelNode -> Text
qualifiedIdentity readModel = rmSchema readModel <> "." <> rmTable readModel

renderFeed :: RmFeed -> Text
renderFeed RmInline = "inline"
renderFeed RmSubscription = "subscription"

effectiveScope :: Maybe RmScope -> RmScope
effectiveScope Nothing = RmEntireLog
effectiveScope (Just scope) = scope

scopeStrengthened :: RmScope -> RmScope -> Bool
scopeStrengthened (RmCategory _) RmEntireLog = True
scopeStrengthened _ _ = False

renderScope :: RmScope -> Text
renderScope RmEntireLog = "entire-log"
renderScope (RmCategory categoryName) = "category '" <> categoryName <> "'"

aggregateDiff :: DiffEnv -> [Change]
aggregateDiff env =
    concatMap (uncurry aggregatePairDiff) (prMatched paired)
        ++ concatMap addedAggregateDiff (prAdded paired)
        ++ concatMap removedAggregateDiff (prRemoved paired)
  where
    paired = pairByName nodeAggregate aggName env

aggregatePairDiff :: Aggregate -> Aggregate -> [Change]
aggregatePairDiff oldAgg newAgg =
    concatMap (eventDiff oldAgg newAgg) (aggEvents newAgg)
        ++ removedEvents oldAgg newAgg
        ++ wireDiff oldAgg newAgg
        ++ projectionDiff oldAgg newAgg

addedAggregateDiff :: Aggregate -> [Change]
addedAggregateDiff newAgg =
    [ additive (aggName newAgg) "event" (evName e) "new event type (new aggregate)"
    | e <- aggEvents newAgg
    ]

removedAggregateDiff :: Aggregate -> [Change]
removedAggregateDiff oldAgg =
    [ breaking (aggName oldAgg) "event" (evName e) EvtRemovedNotDeprecated "aggregate removed; its event tags are no longer decodable"
    | e <- aggEvents oldAgg
    ]

-- | Per-event classification for an event present in the new aggregate.
eventDiff :: Aggregate -> Aggregate -> Event -> [Change]
eventDiff oldAgg newAgg e =
    case find ((== evName e) . evName) (aggEvents oldAgg) of
        Nothing ->
            [additive (aggName newAgg) "event" (evName e) "new event type"]
        Just oldE
            | evVersion e > evVersion oldE ->
                if evVersion e == evVersion oldE + 1 && evUpcastFrom e `hasSource` evVersion oldE
                    then [additive (aggName newAgg) "event" (evName e) ("new version v" <> tInt (evVersion e) <> " with upcaster from v" <> tInt (evVersion oldE))]
                    else
                        [ breaking
                            (aggName newAgg)
                            "event"
                            (evName e)
                            EvtVersionMissingUpcaster
                            ( "version changed from v"
                                <> tInt (evVersion oldE)
                                <> " to v"
                                <> tInt (evVersion e)
                                <> " without the required contiguous upcaster from v"
                                <> tInt (evVersion oldE)
                            )
                        ]
            | evVersion e < evVersion oldE ->
                [breaking (aggName newAgg) "event" (evName e) EvtVersionDecreased ("version decreased from v" <> tInt (evVersion oldE) <> " to v" <> tInt (evVersion e))]
            | otherwise ->
                sameVersionEventDiff oldAgg newAgg oldE e

{- | Events present in the old aggregate but absent in the new one. Removing a
tag entirely is breaking; keeping it as a deprecated event is safe.
-}
removedEvents :: Aggregate -> Aggregate -> [Change]
removedEvents oldAgg newAgg =
    [ breaking (aggName newAgg) "event" (evName oldE) EvtRemovedNotDeprecated "event removed entirely; keep it as a 'deprecated event' so old payloads still decode"
    | oldE <- aggEvents oldAgg
    , isNothing (find ((== evName oldE) . evName) (aggEvents newAgg))
    ]

hasSource :: Maybe (Int, Hole) -> Int -> Bool
hasSource (Just (m, _)) n = m == n
hasSource Nothing _ = False

eventFieldSigs :: Aggregate -> Event -> [(Name, Maybe Name)]
eventFieldSigs agg e = case evBody e of
    EventFields fs -> map fieldSig fs
    EventFromCommand cn ->
        maybe [] (map fieldSig . cmdFields) (find ((== cn) . cmdName) (aggCommands agg))
  where
    fieldSig f = (fieldName f, fieldType f)

sameVersionEventDiff :: Aggregate -> Aggregate -> Event -> Event -> [Change]
sameVersionEventDiff oldAgg newAgg oldE newE =
    addedChanges
        ++ removedChanges
        ++ typeChanges
        ++ deprecationChanges
  where
    oldFields = eventFieldSigs oldAgg oldE
    newFields = eventFieldSigs newAgg newE
    oldNames = map fst oldFields
    newNames = map fst newFields
    added = newNames \\ oldNames
    removed = oldNames \\ newNames
    changed =
        [ (field, oldType, newType)
        | (field, oldType) <- oldFields
        , Just newType <- [lookup field newFields]
        , oldType /= newType
        ]
    addedChanges =
        [ breaking (aggName newAgg) "event" (evName newE) EvtFieldAddedWithoutBump ("field(s) " <> commas added <> " added at the same version v" <> tInt (evVersion newE) <> " without a version bump or upcaster")
        | not (null added)
        ]
    removedChanges =
        [ breaking (aggName newAgg) "event" (evName newE) EvtFieldRemovedSameVersion ("field(s) " <> commas removed <> " removed at the same version v" <> tInt (evVersion newE))
        | not (null removed)
        ]
    typeChanges =
        [ breaking
            (aggName newAgg)
            "event-field"
            (evName newE <> "." <> field)
            EvtFieldTypeChanged
            ("type changed " <> renderFieldType oldType <> " -> " <> renderFieldType newType <> " at the same version v" <> tInt (evVersion newE))
        | (field, oldType, newType) <- changed
        ]
    deprecationChanges
        | not (evDeprecated oldE) && evDeprecated newE =
            [additive (aggName newAgg) "event" (evName newE) "event deprecated (still decodable)"]
        | evDeprecated oldE && not (evDeprecated newE) =
            [advisory (aggName newAgg) "event" (evName newE) EventUndeprecated "event returned to the write surface; old payloads remain decodable but new writes resume"]
        | otherwise = []

renderFieldType :: Maybe Name -> Text
renderFieldType Nothing = "(declared)"
renderFieldType (Just name) = name

wireDiff :: Aggregate -> Aggregate -> [Change]
wireDiff oldAgg newAgg
    | effectiveWire (aggWire oldAgg) == effectiveWire (aggWire newAgg) = []
    | otherwise =
        [ breaking
            (aggName newAgg)
            "wire"
            (aggName newAgg)
            WireSpecChanged
            ("effective wire convention changed " <> renderWire (effectiveWire (aggWire oldAgg)) <> " -> " <> renderWire (effectiveWire (aggWire newAgg)))
        ]

effectiveWire :: Maybe WireSpec -> (Text, Text)
effectiveWire Nothing = ("ctorName", "camelCase")
effectiveWire (Just w) = (wireKind w, wireFields w)

renderWire :: (Text, Text) -> Text
renderWire (kindName, fieldNames) = "kind=" <> kindName <> ", fields=" <> fieldNames

projectionDiff :: Aggregate -> Aggregate -> [Change]
projectionDiff oldAggregate newAggregate
    | projectionSurface (aggProjection oldAggregate) == projectionSurface (aggProjection newAggregate) = []
    | otherwise =
        [ advisory
            (aggName newAggregate)
            "projection"
            (aggName newAggregate)
            ProjectionChanged
            "projection table, consistency, key, or status mapping changed; coordinate the read-model migration"
        ]

projectionSurface :: Maybe ProjectionSpec -> Maybe (Name, Maybe Consistency, Name, Maybe Mapping)
projectionSurface projection = do
    value <- projection
    pure (projTable value, projConsistency value, projKey value, projStatusMap value)

idDiff :: DiffEnv -> [Change]
idDiff env =
    concatMap (uncurry idPairDiff) (prMatched paired)
        ++ concatMap addedIdDiff (prAdded paired)
        ++ concatMap removedIdDiff (prRemoved paired)
  where
    paired = pairDeclarations idName (specIds (deOld env)) (specIds (deNew env))

idPairDiff :: IdDecl -> IdDecl -> [Change]
idPairDiff oldId newId =
    [ breaking (idName newId) "id-prefix" (idName newId) IdPrefixChanged ("prefix changed '" <> idPrefix oldId <> "' -> '" <> idPrefix newId <> "'; stored and newly minted ids no longer share an identity domain")
    | idPrefix oldId /= idPrefix newId
    ]

addedIdDiff :: IdDecl -> [Change]
addedIdDiff declaration = [additive (idName declaration) "id-prefix" (idName declaration) "new id declaration"]

removedIdDiff :: IdDecl -> [Change]
removedIdDiff declaration = [breaking (idName declaration) "id-prefix" (idName declaration) IdPrefixChanged "id declaration removed; persisted ids still use its prefix"]

enumDiff :: DiffEnv -> [Change]
enumDiff env =
    concatMap (uncurry (enumPairDiff (deOld env))) (prMatched paired)
        ++ concatMap addedEnumDiff (prAdded paired)
        ++ concatMap (removedEnumDiff (deOld env)) (prRemoved paired)
  where
    paired = pairDeclarations enumName (specEnums (deOld env)) (specEnums (deNew env))

enumPairDiff :: Spec -> EnumDecl -> EnumDecl -> [Change]
enumPairDiff oldSpec oldEnum newEnum =
    [ breaking (enumName newEnum) "enum-constructor" ctor EnumCtorRemoved ("constructor removed; stored wire value '" <> wire <> "' no longer decodes" <> enumUsageSuffix oldSpec (enumName oldEnum))
    | (ctor, wire) <- enumCtors oldEnum
    , isNothing (lookup ctor (enumCtors newEnum))
    ]
        ++ [ breaking (enumName newEnum) "enum-constructor" ctor EnumWireSpellingChanged ("wire spelling changed '" <> oldWire <> "' -> '" <> newWire <> "'; stored values using the old spelling no longer decode" <> enumUsageSuffix oldSpec (enumName oldEnum))
           | (ctor, oldWire) <- enumCtors oldEnum
           , Just newWire <- [lookup ctor (enumCtors newEnum)]
           , oldWire /= newWire
           ]
        ++ [ additive (enumName newEnum) "enum-constructor" ctor ("new constructor with wire spelling '" <> wire <> "'")
           | (ctor, wire) <- enumCtors newEnum
           , isNothing (lookup ctor (enumCtors oldEnum))
           ]

addedEnumDiff :: EnumDecl -> [Change]
addedEnumDiff enumDecl =
    [additive (enumName enumDecl) "enum-constructor" ctor ("new enum constructor with wire spelling '" <> wire <> "'") | (ctor, wire) <- enumCtors enumDecl]

removedEnumDiff :: Spec -> EnumDecl -> [Change]
removedEnumDiff oldSpec enumDecl =
    [ breaking (enumName enumDecl) "enum-constructor" ctor EnumCtorRemoved ("enum removed; stored wire value '" <> wire <> "' no longer decodes" <> enumUsageSuffix oldSpec (enumName enumDecl))
    | (ctor, wire) <- enumCtors enumDecl
    ]

enumUsageSuffix :: Spec -> Name -> Text
enumUsageSuffix spec enumType = case enumUsages spec enumType of
    [] -> ""
    usages -> "; used by " <> commas usages

enumUsages :: Spec -> Name -> [Text]
enumUsages spec enumType =
    [aggName agg <> ".reg." <> regName reg | agg <- aggregates, reg <- aggRegs agg, regType reg == enumType]
        ++ [ aggName agg <> ".event." <> evName event <> "." <> field
           | agg <- aggregates
           , event <- aggEvents agg
           , (field, Just fieldTypeName) <- eventFieldSigs agg event
           , fieldTypeName == enumType
           ]
  where
    aggregates = [agg | NAggregate agg <- specNodes spec]

pairDeclarations :: (n -> Name) -> [n] -> [n] -> Paired n
pairDeclarations nameOf oldNodes newNodes =
    Paired
        { prMatched =
            [ (oldNode, newNode)
            | newNode <- newNodes
            , Just oldNode <- [find ((== nameOf newNode) . nameOf) oldNodes]
            ]
        , prAdded = [newNode | newNode <- newNodes, isNothing (find ((== nameOf newNode) . nameOf) oldNodes)]
        , prRemoved = [oldNode | oldNode <- oldNodes, isNothing (find ((== nameOf oldNode) . nameOf) newNodes)]
        }

contractDiff :: DiffEnv -> [Change]
contractDiff env =
    concatMap (uncurry contractPairDiff) (prMatched paired)
        ++ concatMap addedContractDiff (prAdded paired)
        ++ concatMap removedContractDiff (prRemoved paired)
  where
    paired = pairByName nodeContract ctrName env

contractPairDiff :: ContractNode -> ContractNode -> [Change]
contractPairDiff oldContract newContract =
    schemaChanges
        ++ discriminatorChanges
        ++ topicChanges
        ++ concatMap eventPairChanges matchedEvents
        ++ concatMap addedEventChanges addedEvents
        ++ concatMap removedEventChanges removedEvents'
  where
    schemaChanges =
        [ breaking
            (ctrName newContract)
            "schema-version"
            (ctrName newContract)
            ContractSchemaVersionDecreased
            ("schemaVersion decreased from " <> tInt (ctrSchemaVersion oldContract) <> " to " <> tInt (ctrSchemaVersion newContract))
        | ctrSchemaVersion newContract < ctrSchemaVersion oldContract
        ]
    discriminatorChanges =
        [ breaking
            (ctrName newContract)
            "discriminator"
            (ctrName newContract)
            ContractDiscriminatorChanged
            ("discriminator changed " <> ctrDiscriminator oldContract <> " -> " <> ctrDiscriminator newContract)
        | ctrDiscriminator oldContract /= ctrDiscriminator newContract
        ]
    topicChanges = contractTopicDiff oldContract newContract
    eventPairs = pairDeclarations ceName (ctrEvents oldContract) (ctrEvents newContract)
    matchedEvents = prMatched eventPairs
    addedEvents = prAdded eventPairs
    removedEvents' = prRemoved eventPairs
    eventPairChanges (oldEvent, newEvent) = contractEventDiff oldContract newContract oldEvent newEvent
    addedEventChanges event =
        [additive (ctrName newContract) "contract-event" (ceName event) "new contract event"]
    removedEventChanges event =
        [breaking (ctrName newContract) "contract-event" (ceName event) ContractEventRemoved "contract event removed; existing cross-service payloads no longer have a declared decoder"]

addedContractDiff :: ContractNode -> [Change]
addedContractDiff contract =
    [additive (ctrName contract) "contract-event" (ceName event) "new event in a new contract" | event <- ctrEvents contract]

removedContractDiff :: ContractNode -> [Change]
removedContractDiff contract =
    [breaking (ctrName contract) "contract-event" (ceName event) ContractEventRemoved "contract removed; its cross-service event decoder is no longer declared" | event <- ctrEvents contract]

contractTopicDiff :: ContractNode -> ContractNode -> [Change]
contractTopicDiff oldContract newContract =
    [ breaking
        (ctrName newContract)
        "contract-topic"
        alias
        ContractTopicChanged
        ("topic alias removed; previous topic was '" <> oldTopic <> "'")
    | (alias, oldTopic) <- ctrTopics oldContract
    , isNothing (lookup alias (ctrTopics newContract))
    ]
        ++ [ breaking
                (ctrName newContract)
                "contract-topic"
                alias
                ContractTopicChanged
                ("real topic changed '" <> oldTopic <> "' -> '" <> newTopic <> "'")
           | (alias, oldTopic) <- ctrTopics oldContract
           , Just newTopic <- [lookup alias (ctrTopics newContract)]
           , oldTopic /= newTopic
           ]
        ++ [ additive (ctrName newContract) "contract-topic" alias ("new topic alias for '" <> topic <> "'")
           | (alias, topic) <- ctrTopics newContract
           , isNothing (lookup alias (ctrTopics oldContract))
           ]

contractEventDiff :: ContractNode -> ContractNode -> ContractEvent -> ContractEvent -> [Change]
contractEventDiff oldContract newContract oldEvent newEvent =
    topicAliasChange
        ++ removedFieldChanges
        ++ changedFieldChanges
        ++ addedFieldChanges
  where
    fieldPairs = pairDeclarations cfName (ceFields oldEvent) (ceFields newEvent)
    topicAliasChange =
        [ breaking
            (ctrName newContract)
            "contract-topic"
            (ceName newEvent)
            ContractTopicChanged
            ("event topic alias changed " <> ceTopic oldEvent <> " -> " <> ceTopic newEvent)
        | ceTopic oldEvent /= ceTopic newEvent
        ]
    removedFieldChanges =
        [ breaking (ctrName newContract) "contract-field" (ceName newEvent <> "." <> cfName field) ContractFieldChanged "field removed; existing messages still carry the old contract shape"
        | field <- prRemoved fieldPairs
        ]
    changedFieldChanges =
        [ breaking
            (ctrName newContract)
            "contract-field"
            (ceName newEvent <> "." <> cfName newField)
            ContractFieldChanged
            ("field type changed " <> renderContractType (cfType oldField) <> " -> " <> renderContractType (cfType newField))
        | (oldField, newField) <- prMatched fieldPairs
        , cfType oldField /= cfType newField
        ]
    addedFieldChanges =
        [ if ctrSchemaVersion newContract > ctrSchemaVersion oldContract
            then advisory (ctrName newContract) "contract-field" subject ContractSchemaVersionBumped ("field added with schemaVersion bump " <> tInt (ctrSchemaVersion oldContract) <> " -> " <> tInt (ctrSchemaVersion newContract) <> "; coordinate the cross-service rollout")
            else breaking (ctrName newContract) "contract-field" subject ContractFieldChanged "field added without a schemaVersion bump; older in-flight messages do not contain it"
        | field <- prAdded fieldPairs
        , let subject = ceName newEvent <> "." <> cfName field
        ]

renderContractType :: ContractType -> Text
renderContractType (CTypeId prefix) = "typeid '" <> prefix <> "'"
renderContractType CText = "text"
renderContractType CInt = "int"

workqueueDiff :: DiffEnv -> [Change]
workqueueDiff env =
    concatMap (uncurry workqueuePairDiff) (prMatched paired)
        ++ concatMap addedWorkqueueDiff (prAdded paired)
        ++ concatMap removedWorkqueueDiff (prRemoved paired)
  where
    paired = pairByName nodeWorkqueue wqName env

workqueuePairDiff :: WorkqueueNode -> WorkqueueNode -> [Change]
workqueuePairDiff oldQueue newQueue =
    concatMap pairedFieldDiff (prMatched fields)
        ++ concatMap addedFieldDiff (prAdded fields)
        ++ concatMap removedFieldDiff (prRemoved fields)
        ++ queueIdentityDiff oldQueue newQueue
        ++ queuePolicyDiff oldQueue newQueue
  where
    -- wqPayloadName is a generated Haskell type name, not a wire-visible name.
    fields = pairDeclarations wqfName (wqPayload oldQueue) (wqPayload newQueue)
    pairedFieldDiff (oldField, newField)
        | wqfWire oldField /= wqfWire newField = [payloadBreaking newField ("wire name changed '" <> wqfWire oldField <> "' -> '" <> wqfWire newField <> "'")]
        | wqfType oldField /= wqfType newField = [payloadBreaking newField ("type changed " <> wqfType oldField <> " -> " <> wqfType newField)]
        | not (wqfRequired oldField) && wqfRequired newField = [payloadBreaking newField "field changed from optional to required; queued jobs may omit it"]
        | wqfRequired oldField && not (wqfRequired newField) = [additive (wqName newQueue) "payload-field" (wqfName newField) "field changed from required to optional"]
        | otherwise = []
    addedFieldDiff field
        | wqfRequired field = [payloadBreaking field "new required field; queued jobs do not contain it"]
        | otherwise = [additive (wqName newQueue) "payload-field" (wqfName field) "new optional field"]
    removedFieldDiff field = [payloadBreaking field "field removed; queued jobs still contain the old payload shape"]
    payloadBreaking field detail = breaking (wqName newQueue) "payload-field" (wqfName field) WqPayloadFieldChanged detail

addedWorkqueueDiff :: WorkqueueNode -> [Change]
addedWorkqueueDiff queue =
    [additive (wqName queue) "payload-field" (wqfName field) "field belongs to a new workqueue payload" | field <- wqPayload queue]

removedWorkqueueDiff :: WorkqueueNode -> [Change]
removedWorkqueueDiff queue =
    [breaking (wqName queue) "payload-field" (wqfName field) WqPayloadFieldChanged "workqueue removed while persisted jobs may still carry this payload" | field <- wqPayload queue]
        ++ [breaking (wqName queue) "queue-identity" (wqName queue) QueueIdentityChanged "workqueue removed; its physical queue, DLQ, and pgmq table may still hold state"]

queueIdentityDiff :: WorkqueueNode -> WorkqueueNode -> [Change]
queueIdentityDiff oldQueue newQueue =
    [ breaking
        (wqName newQueue)
        "queue-identity"
        (wqName newQueue)
        QueueIdentityChanged
        "logical, physical, DLQ, or table name changed; queued jobs and dispatch dedupe records remain under the old identity"
    | queueIdentity oldQueue /= queueIdentity newQueue
    ]

queueIdentity :: WorkqueueNode -> (Text, Text, Text, Text)
queueIdentity queue = (wqLogical queue, wqPhysical queue, wqDlq queue, wqTable queue)

queuePolicyDiff :: WorkqueueNode -> WorkqueueNode -> [Change]
queuePolicyDiff oldQueue newQueue = ordering ++ provision ++ groupKey
  where
    nodeName = wqName newQueue
    ordering =
        [ breaking nodeName "queue-ordering" nodeName WqOrderingChanged $
            "ordering changed " <> renderWqOrdering (wqOrdering oldQueue) <> " -> " <> renderWqOrdering (wqOrdering newQueue) <> "; consumers were written against the old delivery-order contract"
        | wqOrdering oldQueue /= wqOrdering newQueue
        ]
    provision =
        [ breaking nodeName "queue-provision" nodeName WqProvisionChanged $
            "provision changed " <> renderWqProvision (wqProvision oldQueue) <> " -> " <> renderWqProvision (wqProvision newQueue) <> "; provisioning is create-time only, so migrate the existing queue operationally before changing the spec"
        | wqProvision oldQueue /= wqProvision newQueue
        ]
    groupKey =
        [ breaking nodeName "queue-group-key" nodeName WqGroupKeyChanged $
            "group key derivation changed " <> renderWqGroupKey (wqGroupKey oldQueue) <> " -> " <> renderWqGroupKey (wqGroupKey newQueue) <> "; FIFO messages are re-partitioned across durable ordering groups"
        | wqGroupKey oldQueue /= wqGroupKey newQueue
        ]

renderWqOrdering :: WqOrdering -> Text
renderWqOrdering WqUnordered = "unordered"
renderWqOrdering WqFifoThroughput = "fifo-throughput"
renderWqOrdering WqFifoRoundRobin = "fifo-roundrobin"

renderWqProvision :: WqProvision -> Text
renderWqProvision WqStandard = "standard"
renderWqProvision WqUnlogged = "unlogged"
renderWqProvision (WqPartitioned interval duration) = "partitioned(interval=" <> interval <> ", retention=" <> duration <> ")"

renderWqGroupKey :: Maybe WqGroupKey -> Text
renderWqGroupKey Nothing = "none"
renderWqGroupKey (Just groupKey) =
    gkField groupKey
        <> " via "
        <> gkVia groupKey
        <> maybe "" (" fixture " <>) (gkFixture groupKey)

processDiff :: DiffEnv -> [Change]
processDiff env =
    concatMap (uncurry processPairDiff) (prMatched paired)
        ++ concatMap addedProcessDiff (prAdded paired)
        ++ concatMap removedProcessDiff (prRemoved paired)
  where
    paired = pairByName nodeProcess procId env

processPairDiff :: ProcessNode -> ProcessNode -> [Change]
processPairDiff oldProcess newProcess =
    concatMap pairedFieldDiff (prMatched fields)
        ++ map (fieldChange "field added; source events at the old shape cannot populate it") (prAdded fields)
        ++ map (fieldChange "field removed; the generated process input decoder changed") (prRemoved fields)
        ++ processIdentityDiff oldProcess newProcess
        ++ processTimerWindowDiff oldProcess newProcess
  where
    -- inName is a generated Haskell type name; the wire shape is inFields.
    fields = pairDeclarations fieldName (inFields (procInput oldProcess)) (inFields (procInput newProcess))
    pairedFieldDiff (oldField, newField)
        | fieldType oldField /= fieldType newField = [fieldChange ("type changed " <> renderFieldType (fieldType oldField) <> " -> " <> renderFieldType (fieldType newField)) newField]
        | otherwise = []
    fieldChange detail field = breaking (procId newProcess) "input-field" (fieldName field) ProcessInputChanged (detail <> "; version the source event before changing process input")

addedProcessDiff :: ProcessNode -> [Change]
addedProcessDiff process =
    [additive (procId process) "input-field" (fieldName field) "field belongs to a new process input" | field <- inFields (procInput process)]

removedProcessDiff :: ProcessNode -> [Change]
removedProcessDiff process =
    [breaking (procId process) "input-field" (fieldName field) ProcessInputChanged "process removed while persisted source events may still require this input decoder" | field <- inFields (procInput process)]
        ++ [breaking (procId process) "derived-identity" (procId process) DerivedIdentityChanged "process removed while persisted saga, dispatch, and timer identities may still exist"]

processIdentityDiff :: ProcessNode -> ProcessNode -> [Change]
processIdentityDiff oldProcess newProcess =
    [ breaking
        (procId newProcess)
        "derived-identity"
        (procId newProcess)
        DerivedIdentityChanged
        "process name, correlation derivation, saga stream prefix, timer id prefix, or fired-event-id prefix changed; replays and retries no longer derive the persisted identity"
    | processIdentity oldProcess /= processIdentity newProcess
    ]

processIdentity :: ProcessNode -> (Text, Name, Name, Text, Text, Text)
processIdentity process =
    ( procName process
    , corrField (procCorrelate process)
    , corrVia (procCorrelate process)
    , sagaStreamPrefix (procSaga process)
    , idePrefix (tmId (procTimer process))
    , idePrefix (fireFiredEventId (tmFire (procTimer process)))
    )

processTimerWindowDiff :: ProcessNode -> ProcessNode -> [Change]
processTimerWindowDiff oldProcess newProcess =
    [ advisory
        (procId newProcess)
        "timer"
        (tmName (procTimer newProcess))
        TimerWindowChanged
        ( "fireAt source/window changed "
            <> renderFireAt (tmFireAt (procTimer oldProcess))
            <> " -> "
            <> renderFireAt (tmFireAt (procTimer newProcess))
            <> "; already-scheduled timers keep their persisted deadline"
        )
    | tmFireAt (procTimer oldProcess) /= tmFireAt (procTimer newProcess)
    ]

renderFireAt :: FireAtExpr -> Text
renderFireAt expression = "input." <> faField expression <> " + " <> faWindow expression

workflowDiff :: DiffEnv -> [Change]
workflowDiff env =
    concatMap (uncurry workflowPairDiff) (prMatched paired)
        ++ concatMap addedWorkflowDiff (prAdded paired)
        ++ concatMap removedWorkflowDiff (prRemoved paired)
  where
    paired = pairByName nodeWorkflow wfId env

workflowPairDiff :: WorkflowNode -> WorkflowNode -> [Change]
workflowPairDiff oldWorkflow newWorkflow =
    inputChanges
        ++ outputChanges
        ++ classifyWorkflowBody oldWorkflow newWorkflow
        ++ workflowIdentityDiff oldWorkflow newWorkflow
  where
    fields = pairDeclarations fieldName (wfInputFields oldWorkflow) (wfInputFields newWorkflow)
    inputChanges =
        [workflowShape field "input field added; journaled inputs at the old shape do not contain it" | field <- prAdded fields]
            ++ [workflowShape field "input field removed; journaled inputs still contain the old shape" | field <- prRemoved fields]
            ++ [ workflowShape newField ("input field type changed " <> renderFieldType (fieldType oldField) <> " -> " <> renderFieldType (fieldType newField))
               | (oldField, newField) <- prMatched fields
               , fieldType oldField /= fieldType newField
               ]
    outputChanges =
        [ breaking (wfId newWorkflow) "workflow-output" (wfOutput newWorkflow) WorkflowShapeChanged ("output type changed " <> wfOutput oldWorkflow <> " -> " <> wfOutput newWorkflow <> "; persisted outcomes may no longer decode")
        | wfOutput oldWorkflow /= wfOutput newWorkflow
        ]
    workflowShape field detail = breaking (wfId newWorkflow) "workflow-input" (fieldName field) WorkflowShapeChanged detail

addedWorkflowDiff :: WorkflowNode -> [Change]
addedWorkflowDiff workflow = [additive (wfId workflow) "workflow" (wfId workflow) "new workflow"]

removedWorkflowDiff :: WorkflowNode -> [Change]
removedWorkflowDiff workflow = [breaking (wfId workflow) "workflow" (wfId workflow) WorkflowShapeChanged "workflow removed while in-flight journals and outcomes may still require its decoder"]

workflowIdentityDiff :: WorkflowNode -> WorkflowNode -> [Change]
workflowIdentityDiff oldWorkflow newWorkflow =
    [ breaking
        (wfId newWorkflow)
        "workflow-name"
        (wfId newWorkflow)
        WorkflowStableNameChanged
        ("stable name changed '" <> wfStable oldWorkflow <> "' -> '" <> wfStable newWorkflow <> "'; in-flight journals remain under the old stream name")
    | wfStable oldWorkflow /= wfStable newWorkflow
    ]
        ++ [ breaking
                (wfId newWorkflow)
                "derived-identity"
                (wfId newWorkflow)
                DerivedIdentityChanged
                "workflow id source field or derivation changed; journal and deterministic child/step identities no longer coalesce with persisted executions"
           | (wfIdField oldWorkflow, wfIdVia oldWorkflow) /= (wfIdField newWorkflow, wfIdVia newWorkflow)
           ]

intakeDiff :: DiffEnv -> [Change]
intakeDiff env =
    concatMap (uncurry intakePairDiff) (prMatched paired)
        ++ concatMap addedIntakeDiff (prAdded paired)
        ++ concatMap removedIntakeDiff (prRemoved paired)
  where
    paired = pairByName nodeIntake inkName env

intakePairDiff :: IntakeNode -> IntakeNode -> [Change]
intakePairDiff oldIntake newIntake =
    [ breaking
        (inkName newIntake)
        "dedupe-identity"
        (inkName newIntake)
        DedupeIdentityChanged
        "dedupe key or policy changed; redelivered messages no longer match their persisted dedupe record"
    | (inkDedupeKey oldIntake, inkDedupePolicy oldIntake) /= (inkDedupeKey newIntake, inkDedupePolicy newIntake)
    ]
        ++ [ advisory
                (inkName newIntake)
                "decode-posture"
                (inkName newIntake)
                DecodePostureChanged
                "envelope/body decode posture changed; future messages are accepted or rejected differently"
           | inkDecode oldIntake /= inkDecode newIntake
           ]
        ++ [ advisory
                (inkName newIntake)
                "inbox-persistence"
                (inkName newIntake)
                IntakePersistenceChanged
                ("success-path envelope persistence changed " <> renderInkPersist (inkPersist oldIntake) <> " -> " <> renderInkPersist (inkPersist newIntake) <> "; existing rows are unchanged while future successful rows retain a different envelope shape")
           | inkPersist oldIntake /= inkPersist newIntake
           ]

renderInkPersist :: InkPersist -> Text
renderInkPersist InkPersistFull = "full-envelope"
renderInkPersist InkPersistDedupeOnly = "dedupe-only"

addedIntakeDiff :: IntakeNode -> [Change]
addedIntakeDiff intake = [additive (inkName intake) "intake" (inkName intake) "new intake"]

removedIntakeDiff :: IntakeNode -> [Change]
removedIntakeDiff intake = [breaking (inkName intake) "dedupe-identity" (inkName intake) DedupeIdentityChanged "intake removed while persisted dedupe records and redeliveries may remain"]

emitDiff :: DiffEnv -> [Change]
emitDiff env =
    concatMap (uncurry emitPairDiff) (prMatched paired)
        ++ concatMap addedEmitDiff (prAdded paired)
        ++ concatMap removedEmitDiff (prRemoved paired)
  where
    paired = pairByName nodeEmit emName env

emitPairDiff :: EmitNode -> EmitNode -> [Change]
emitPairDiff oldEmit newEmit =
    [ breaking
        (emName newEmit)
        "derived-identity"
        "messageId"
        DerivedIdentityChanged
        "messageId derive prefix changed; outbox retries no longer coalesce with persisted messages"
    | emMessageId oldEmit /= emMessageId newEmit
    ]
        ++ [ breaking
                (emName newEmit)
                "derived-identity"
                "idempotencyKey"
                DerivedIdentityChanged
                "idempotencyKey derive prefix changed; downstream dedupe no longer matches persisted messages"
           | emIdempotencyKey oldEmit /= emIdempotencyKey newEmit
           ]
        ++ [ advisory
                (emName newEmit)
                "emit-mapping"
                (emName newEmit)
                EmitMappingChanged
                "emit key, status discriminant, mapping rows, or explicit skip posture changed"
           | emitMapping oldEmit /= emitMapping newEmit
           ]

emitMapping :: EmitNode -> (Name, Name, [EmitMapRow], Bool)
emitMapping emit = (emKey emit, emDiscriminant emit, emMap emit, emSkip emit)

addedEmitDiff :: EmitNode -> [Change]
addedEmitDiff emit = [additive (emName emit) "emit" (emName emit) "new emit mapping"]

removedEmitDiff :: EmitNode -> [Change]
removedEmitDiff emit = [breaking (emName emit) "derived-identity" (emName emit) DerivedIdentityChanged "emit removed while persisted outbox identities may still retry"]

publisherDiff :: DiffEnv -> [Change]
publisherDiff env =
    concatMap (uncurry publisherPairDiff) (prMatched paired)
        ++ concatMap addedPublisherDiff (prAdded paired)
        ++ concatMap removedPublisherDiff (prRemoved paired)
  where
    paired = pairByName nodePublisher pubName env

publisherPairDiff :: PublisherNode -> PublisherNode -> [Change]
publisherPairDiff oldPublisher newPublisher =
    -- maxAttempts/backoff are retry tuning, not persisted decode or identity.
    [ breaking
        (pubName newPublisher)
        "derived-identity"
        "outboxId"
        DerivedIdentityChanged
        "stable outbox-id source field changed; retries no longer coalesce with persisted outbox rows"
    | pubOutboxField oldPublisher /= pubOutboxField newPublisher
    ]
        ++ [ advisory
                (pubName newPublisher)
                "publisher-policy"
                (pubName newPublisher)
                PublisherPolicyChanged
                ("ordering changed " <> pubOrdering oldPublisher <> " -> " <> pubOrdering newPublisher)
           | pubOrdering oldPublisher /= pubOrdering newPublisher
           ]

addedPublisherDiff :: PublisherNode -> [Change]
addedPublisherDiff publisher = [additive (pubName publisher) "publisher" (pubName publisher) "new publisher"]

removedPublisherDiff :: PublisherNode -> [Change]
removedPublisherDiff publisher = [breaking (pubName publisher) "derived-identity" (pubName publisher) DerivedIdentityChanged "publisher removed while persisted outbox rows may still require its stable identity"]

pgmqDispatchDiff :: DiffEnv -> [Change]
pgmqDispatchDiff env =
    concatMap (uncurry pgmqDispatchPairDiff) (prMatched paired)
        ++ concatMap addedPgmqDispatchDiff (prAdded paired)
        ++ concatMap removedPgmqDispatchDiff (prRemoved paired)
  where
    paired = pairByName nodePgmqDispatch pdName env

pgmqDispatchPairDiff :: PgmqDispatchNode -> PgmqDispatchNode -> [Change]
pgmqDispatchPairDiff oldDispatch newDispatch =
    [ breaking
        (pdName newDispatch)
        "dedupe-identity"
        (pdName newDispatch)
        DedupeIdentityChanged
        "dispatch dedupe key/read-model/queue surface changed; prior enqueue records no longer match"
    | dispatchDedupe oldDispatch /= dispatchDedupe newDispatch
    ]
        ++ [ advisory
                (pdName newDispatch)
                "retarget"
                (pdName newDispatch)
                DispatchRetargeted
                "source read model or target queue changed; future fan-out is routed differently"
           | dispatchTargets oldDispatch /= dispatchTargets newDispatch
           ]

dispatchDedupe :: PgmqDispatchNode -> (Name, Name, Text, Name, Text)
dispatchDedupe dispatch =
    ( pdDedupKey dispatch
    , pdDedupReadModel dispatch
    , pdDedupReadModelField dispatch
    , pdDedupQueue dispatch
    , pdDedupQueueField dispatch
    )

dispatchTargets :: PgmqDispatchNode -> (Name, Name)
dispatchTargets dispatch = (pdSourceReadModel dispatch, pdEnqueueTo dispatch)

addedPgmqDispatchDiff :: PgmqDispatchNode -> [Change]
addedPgmqDispatchDiff dispatch = [additive (pdName dispatch) "dispatch" (pdName dispatch) "new pgmq dispatch"]

removedPgmqDispatchDiff :: PgmqDispatchNode -> [Change]
removedPgmqDispatchDiff dispatch = [breaking (pdName dispatch) "dedupe-identity" (pdName dispatch) DedupeIdentityChanged "dispatch removed while persisted queue and read-model dedupe records may remain"]

{- | Classify the runtime's sanctioned workflow-evolution mechanisms before
falling back to the conservative unguarded-body rule.
-}
classifyWorkflowBody :: WorkflowNode -> WorkflowNode -> [Change]
classifyWorkflowBody oldWorkflow newWorkflow
    | oldBody == newBody = []
    | not (null removedPatchIds) = map removedPatch removedPatchIds
    | Just (oldSeedType, newSeedType) <- changedSeed =
        [ breaking nodeName "workflow-continue-as-new" nodeName WorkflowContinueSeedChanged $
            "continueAsNew seed type changed " <> oldSeedType <> " -> " <> newSeedType <> "; the next generation's restoreSeed must decode the seed written by the previous generation"
        ]
    | safeAdditions =
        map addedPatch newPatchIds
            ++ [ additive nodeName "workflow-continue-as-new" seedType "terminal continueAsNew is additive; old generations carry no rotation marker"
               | Just seedType <- [appendedSeed]
               ]
    | otherwise =
        [ breaking
            nodeName
            "workflow-body"
            nodeName
            WorkflowBodyChanged
            "workflow body labels, kinds, result types, or order changed without a new patch guard; wrap a cross-cutting change in patch, or rename the replay label for one changed step"
        ]
  where
    nodeName = wfId newWorkflow
    oldBody = normaliseWorkflowBody (wfBody oldWorkflow)
    newBody = normaliseWorkflowBody (wfBody newWorkflow)
    oldPatchIds = workflowBodyPatchIds oldBody
    newPatchIdsAll = workflowBodyPatchIds newBody
    newPatchIds = newPatchIdsAll \\ oldPatchIds
    removedPatchIds = oldPatchIds \\ newPatchIdsAll
    oldSeed = terminalContinueSeed oldBody
    newSeed = terminalContinueSeed newBody
    changedSeed = case (oldSeed, newSeed) of
        (Just oldSeedType, Just newSeedType)
            | oldSeedType /= newSeedType -> Just (oldSeedType, newSeedType)
        _ -> Nothing
    appendedSeed = case (oldSeed, newSeed) of
        (Nothing, Just seedType) -> Just seedType
        _ -> Nothing
    strippedNewBody = stripNewPatches newPatchIds newBody
    comparableNewBody = case appendedSeed of
        Just _ -> dropTerminalContinue strippedNewBody
        Nothing -> strippedNewBody
    safeAdditions =
        (not (null newPatchIds) || isJust appendedSeed)
            && comparableNewBody == oldBody
    removedPatch patchId =
        breaking nodeName "workflow-patch" patchId WorkflowPatchRemoved "patch id existed in the old spec but was removed; the differ cannot prove that no workflow generation still replays its journaled branch"
    addedPatch patchId =
        additive nodeName "workflow-patch" patchId "new patch guard contains the entire body change, so in-flight generations retain their journaled branch"

normaliseWorkflowBody :: [WfBodyItem] -> [WfBodyItem]
normaliseWorkflowBody = map go
  where
    go (WfStep label result _) = WfStep label result noLoc
    go (WfAwait label result _) = WfAwait label result noLoc
    go (WfSleep label delay _) = WfSleep label delay noLoc
    go (WfChild label via result _) = WfChild label via result noLoc
    go (WfPatch patchId items _) = WfPatch patchId (normaliseWorkflowBody items) noLoc
    go (WfContinueAsNew seedType _) = WfContinueAsNew seedType noLoc

workflowBodyPatchIds :: [WfBodyItem] -> [Name]
workflowBodyPatchIds = concatMap go
  where
    go (WfPatch patchId items _) = patchId : workflowBodyPatchIds items
    go _ = []

stripNewPatches :: [Name] -> [WfBodyItem] -> [WfBodyItem]
stripNewPatches newPatchIds = concatMap go
  where
    go (WfPatch patchId _ _) | patchId `elem` newPatchIds = []
    go (WfPatch patchId items loc) = [WfPatch patchId (stripNewPatches newPatchIds items) loc]
    go item = [item]

terminalContinueSeed :: [WfBodyItem] -> Maybe Name
terminalContinueSeed items = case reverse items of
    WfContinueAsNew seedType _ : _ -> Just seedType
    _ -> Nothing

dropTerminalContinue :: [WfBodyItem] -> [WfBodyItem]
dropTerminalContinue items = case reverse items of
    WfContinueAsNew{} : rest -> reverse rest
    _ -> items

additive :: Name -> Text -> Text -> Text -> Change
additive n facet subj detail = Additive (ChangeKind n facet subj Nothing detail)

breaking :: Name -> Text -> Text -> DiagnosticCode -> Text -> Change
breaking n facet subj c detail = Breaking (ChangeKind n facet subj (Just c) detail)

advisory :: Name -> Text -> Text -> DiagnosticCode -> Text -> Change
advisory n facet subj c detail = Advisory (ChangeKind n facet subj (Just c) detail)

commas :: [Text] -> Text
commas = T.intercalate ", "

tInt :: Int -> Text
tInt = T.pack . show
