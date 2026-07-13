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
    classifyWorkflowBody,
) where

import Data.List (find, (\\))
import Data.Maybe (isNothing, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar
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
    | FamContract
    | FamIntake
    | FamEmit
    | FamPublisher
    | FamWorkqueue
    | FamPgmqDispatch
    | FamWorkflow
    | FamOperation
    deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Total by construction: one explicit arm per 'Node' constructor.
familyOf :: Node -> NodeFamily
familyOf (NAggregate _) = FamAggregate
familyOf (NProcess _) = FamProcess
familyOf (NContract _) = FamContract
familyOf (NIntake _) = FamIntake
familyOf (NEmit _) = FamEmit
familyOf (NPublisher _) = FamPublisher
familyOf (NWorkqueue _) = FamWorkqueue
familyOf (NPgmqDispatch _) = FamPgmqDispatch
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
    , (FamContract, DiffFamily contractDiff)
    , (FamIntake, OutOfDiffScope "not yet diffed; Milestone 4 of docs/plans/103 covers intake dedupe identity and decode posture")
    , (FamEmit, OutOfDiffScope "not yet diffed; Milestone 4 of docs/plans/103 covers emit derivations and mappings")
    , (FamPublisher, OutOfDiffScope "not yet diffed; Milestone 4 of docs/plans/103 covers publisher identity and ordering")
    , (FamWorkqueue, DiffFamily workqueueDiff)
    , (FamPgmqDispatch, OutOfDiffScope "not yet diffed; Milestone 4 of docs/plans/103 covers dispatch dedupe identity and retargeting")
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
sharedDeclarationDiff = enumDiff

nodeAggregate :: Node -> Maybe Aggregate
nodeAggregate (NAggregate a) = Just a
nodeAggregate _ = Nothing

nodeProcess :: Node -> Maybe ProcessNode
nodeProcess (NProcess process) = Just process
nodeProcess _ = Nothing

nodeContract :: Node -> Maybe ContractNode
nodeContract (NContract contract) = Just contract
nodeContract _ = Nothing

nodeWorkqueue :: Node -> Maybe WorkqueueNode
nodeWorkqueue (NWorkqueue workqueue) = Just workqueue
nodeWorkqueue _ = Nothing

nodeWorkflow :: Node -> Maybe WorkflowNode
nodeWorkflow (NWorkflow workflow) = Just workflow
nodeWorkflow _ = Nothing

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

-- | Conservative extension seam used by the workflow-evolution plan.
classifyWorkflowBody :: WorkflowNode -> WorkflowNode -> [Change]
classifyWorkflowBody oldWorkflow newWorkflow
    | wfBody oldWorkflow == wfBody newWorkflow = []
    | otherwise =
        [ breaking
            (wfId newWorkflow)
            "workflow-body"
            (wfId newWorkflow)
            WorkflowBodyChanged
            "workflow body labels, kinds, result types, or order changed; existing journals require patch guards (added by docs/plans/109) before such evolution is safe"
        ]

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
