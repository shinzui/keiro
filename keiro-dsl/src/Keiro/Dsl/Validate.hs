{- | The keiro DSL validator. A parsed 'Spec' is /valid/ only if it passes the
cross-cutting structural and hole-kind rules below. The point is to reject a
dangerous-by-omission spec — a deleted status-map, an undeclared command, a
guard atom that resolves to nothing, a wall-clock read inside a guard — /before
any Haskell is written/.

EP-1 defines the 'Diagnostic' framework and the cross-cutting rules; each later
vertical (EP-3…EP-6) appends its node-specific rules (e.g. EP-4's inbox
disposition inversions) reusing this same 'Diagnostic' type.
-}
module Keiro.Dsl.Validate (
    Severity (..),
    DiagnosticCode (..),
    Diagnostic (..),
    renderDiagnostic,
    validateSpec,
    derivedQueueTrio,
) where

import Data.Bits (xor)
import Data.Char (ord)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)
import Keiro.Dsl.Grammar
import Keiro.Dsl.ReadModelShape (deriveShapeHash)
import Numeric (showHex)

data Severity = Error | Warning
    deriving stock (Eq, Show)

-- | A machine-checkable code per rule, so tests match on the code, not prose.
data DiagnosticCode
    = UndeclaredCommand
    | UndeclaredEvent
    | UndeclaredState
    | UnreachableState
    | TerminalHasOutgoing
    | GuardAtomOutOfScope
    | StatusMapNotTotal
    | ClockSampled
    | -- EP-2 (evolution). The first three fire in single-spec @validateSpec@;
      -- the last two are emitted by the @diff@ path (they need a prior spec) and
      -- live here so the enum is the single registry of evolution rules.
      EvtVersionMissingUpcaster
    | DeprecatedEventStillEmitted
    | WireSchemaVersionMismatch
    | EvtFieldAddedWithoutBump
    | EvtRemovedNotDeprecated
    | -- EP-3 (process manager + durable timer).
      ProcessFireAtNotInjected
    | ProcessDispatchIdSupplied
    | ProcessUnresolvedRef
    | ProcessBenignInversion
    | -- EP-4 (integration intake / inbox disposition).
      DispositionIncomplete
    | DispositionDuplicateRetry
    | DispositionPreviouslyFailedRetry
    | DispositionDecodeUnboundedRetry
    | -- EP-4 (integration coupling).
      EmitSkipMissing
    | EmitUnresolvedContract
    | PublisherUnresolvedEmit
    | IntakeUnresolvedContract
    | -- EP-5 (pgmq workqueue/dispatch).
      WqPhysicalDivergence
    | WqStoreFailureNotRetry
    | WqDecodeFailureNotDeadLetter
    | WqDlqWithoutCeiling
    | DispatchEnqueueUnresolved
    | -- EP-6 (workflow/operation).
      AwaitSignalMismatch
    | RunWorkflowUnresolved
    | -- Diff-only (cross-spec) decode and identity evolution rules.
      EvtFieldTypeChanged
    | EvtFieldRemovedSameVersion
    | EvtVersionDecreased
    | EnumCtorRemoved
    | EnumWireSpellingChanged
    | WireSpecChanged
    | ContractEventRemoved
    | ContractFieldChanged
    | ContractDiscriminatorChanged
    | ContractTopicChanged
    | ContractSchemaVersionDecreased
    | WqPayloadFieldChanged
    | ProcessInputChanged
    | WorkflowShapeChanged
    | WorkflowBodyChanged
    | WorkflowStableNameChanged
    | IdPrefixChanged
    | DedupeIdentityChanged
    | DerivedIdentityChanged
    | QueueIdentityChanged
    | TimerWindowChanged
    | EmitMappingChanged
    | DecodePostureChanged
    | ProjectionChanged
    | PublisherPolicyChanged
    | DispatchRetargeted
    | ContractSchemaVersionBumped
    | EventUndeprecated
    | -- EP-104 (validator soundness).
      WorkflowDuplicateLabel
    | WorkflowSleepDelayUnresolved
    | WorkflowIdFieldUnresolved
    | RuleDomainUnresolved
    | RuleNotTotal
    | RuleCaseUnknownCtor
    | ProcessFieldBindingUnresolved
    | ProcessTimerCeilingInvalid
    | OperationUnresolvedRef
    | AwaitSignalValueMismatch
    | WqDispositionIncomplete
    | DispositionDuplicateOutcome
    | TopicAffinityMismatch
    | StatusMapDanglingKey
    | StatusMapDuplicateKey
    | WriteTargetNotRegister
    | RegisterInitialOutOfScope
    | DuplicateNodeName
    | DuplicateEnumCtor
    | DuplicateEnumWire
    | DuplicateIdPrefix
    | DuplicateCommandName
    | DuplicateEventName
    | WqDlqDivergence
    | WqTableDivergence
    | DispatchDedupQueueUnresolved
    | DispatchDedupFieldUnresolved
    | -- EP-105 (notation integrity and scaffold-safe names).
      IdentHaskellKeyword
    | IdentNotConstructorSafe
    | VertexCtorCollision
    | -- EP-107 (first-class read models).
      RmShapeHashDrift
    | RmStrongInlineOnly
    | RmScopeWithoutStrong
    | RmUnknownColumnType
    | RmInlineFeedUnreferenced
    | RmConsistencyConflict
    | RmProjectionWithoutNode
    | QueryUnresolvedReadModel
    | QueryConsistencyInvalid
    | DispatchReadModelUnresolved
    | DispatchReadModelFieldUnknown
    deriving stock (Eq, Show)

-- | A line-numbered, structured diagnostic.
data Diagnostic = Diagnostic
    { line :: !Int
    , severity :: !Severity
    , code :: !DiagnosticCode
    , message :: !Text
    }
    deriving stock (Eq, Show)

{- | Render a diagnostic in the conventional
@\<file\>:\<line\>: error[\<code\>]: \<message\>@ form.
-}
renderDiagnostic :: FilePath -> Diagnostic -> Text
renderDiagnostic file d =
    T.pack file
        <> ":"
        <> T.pack (show (line d))
        <> ": "
        <> sev
        <> "["
        <> T.pack (show (code d))
        <> "]: "
        <> message d
  where
    sev = case severity d of Error -> "error"; Warning -> "warning"

{- | Reserved wall-clock atom names. Sampling any of these inside a guard or
write breaks deterministic replay: TIME IS INJECTED, NOT SAMPLED.
-}
clockAtoms :: Set Name
clockAtoms = Set.fromList ["now", "currentTime", "wallClock", "today", "utcNow"]

{- | Validate a whole spec. An empty list means valid. Diagnostics are sorted by
line for stable, readable output.
-}
validateSpec :: Spec -> [Diagnostic]
validateSpec spec =
    sortOn line (validateNames spec ++ specLevelRules spec ++ concatMap (validateNode spec) (specNodes spec))

{- | Reject names that would make the scaffolder emit illegal Haskell. The
parser enforces the ASCII alphabet; this pass applies the category-specific
uppercase/lowercase and keyword rules that require AST context.
-}
validateNames :: Spec -> [Diagnostic]
validateNames spec =
    concat
        [ concatMap idNames (specIds spec)
        , concatMap enumNames (specEnums spec)
        , concatMap nodeNames (specNodes spec)
        ]
  where
    idNames declaration =
        constructorName "id name" (idName declaration) (idLoc declaration)

    enumNames declaration =
        constructorName "enum name" (enumName declaration) (enumLoc declaration)
            ++ concatMap
                (\(ctor, _) -> constructorName ("constructor of enum '" <> enumName declaration <> "'") ctor (enumLoc declaration))
                (enumCtors declaration)

    nodeNames = \case
        NAggregate aggregate -> aggregateNames aggregate
        NProcess process -> processNames process
        NContract contract ->
            pascalizedNodeName "contract" (ctrName contract) (ctrLoc contract)
                ++ concatMap
                    (\event -> constructorName "contract event name" (ceName event) (ctrLoc contract) ++ concatMap (contractFieldName contract) (ceFields event))
                    (ctrEvents contract)
        NIntake intake -> pascalizedNodeName "intake" (inkName intake) (inkLoc intake)
        NEmit emitNode -> pascalizedNodeName "emit" (emName emitNode) (emLoc emitNode)
        NPublisher publisher -> pascalizedNodeName "publisher" (pubName publisher) (pubLoc publisher)
        NWorkqueue workqueue ->
            pascalizedNodeName "workqueue" (wqName workqueue) (wqLoc workqueue)
                ++ constructorName "workqueue payload name" (wqPayloadName workqueue) (wqLoc workqueue)
                ++ concatMap (\field -> fieldNameRule "workqueue payload field" (wqfName field) (wqLoc workqueue)) (wqPayload workqueue)
        NPgmqDispatch dispatch -> pascalizedNodeName "dispatch" (pdName dispatch) (pdLoc dispatch)
        NReadModel readModel -> pascalizedNodeName "readmodel" (rmName readModel) (rmLoc readModel)
        NWorkflow workflow -> constructorName "workflow name" (wfId workflow) (wfLoc workflow)
        NOperation _ -> []

    aggregateNames aggregate =
        constructorName "aggregate name" (aggName aggregate) (aggLoc aggregate)
            ++ concatMap
                (\register -> fieldNameRule "register name" (regName register) (regLoc register))
                (aggRegs aggregate)
            ++ concatMap commandNames (aggCommands aggregate)
            ++ concatMap eventNames (aggEvents aggregate)
            ++ maybe [] (\projection -> fieldNameRule "projection key" (projKey projection) (projLoc projection)) (aggProjection aggregate)
            ++ vertexCollisions aggregate
      where
        commandNames command =
            constructorName "command name" (cmdName command) (cmdLoc command)
                ++ concatMap (\field -> fieldNameRule "command field" (fieldName field) (cmdLoc command)) (cmdFields command)
        eventNames event =
            constructorName "event name" (evName event) (evLoc event)
                ++ case evBody event of
                    EventFields fields -> concatMap (\field -> fieldNameRule "event field" (fieldName field) (evLoc event)) fields
                    EventFromCommand _ -> []

    processNames process =
        constructorName "process name" (procId process) (procLoc process)
            ++ constructorName "process input name" (inName input) (procLoc process)
            ++ concatMap (\field -> fieldNameRule "process input field" (fieldName field) (procLoc process)) (inFields input)
            ++ concatMap (bindingName "advance field binding" (procLoc process)) (advFields (hAdvance handle))
            ++ concatMap dispatchBindings (hDispatch handle)
            ++ concatMap (bindingName "timer payload field binding" (tmLoc timer)) (tmPayload timer)
            ++ concatMap (bindingName "timer fire field binding" (tmLoc timer)) (fireFields (tmFire timer))
      where
        input = procInput process
        handle = procHandle process
        timer = procTimer process
        dispatchBindings dispatch = concatMap (bindingName "dispatch field binding" (dispLoc dispatch)) (dispFields dispatch)

    bindingName category anchor binding = fieldNameRule category (fbName binding) anchor
    contractFieldName contract field = fieldNameRule "contract field" (cfName field) (ctrLoc contract)

    constructorName category name anchor
        | constructorSafe name = []
        | otherwise =
            [ mkErr (locLine anchor) IdentNotConstructorSafe $
                category <> " '" <> name <> "' must be PascalCase: it becomes a Haskell constructor, type name, or module segment in scaffolded code"
            ]

    pascalizedNodeName category name anchor
        | "_" `T.isPrefixOf` name =
            [ mkErr (locLine anchor) IdentNotConstructorSafe $
                category <> " name '" <> name <> "' cannot begin with '_': title-casing leaves an invalid Haskell module segment"
            ]
        | otherwise = []

    fieldNameRule category name anchor
        | name `Set.member` haskellKeywords =
            [ mkErr (locLine anchor) IdentHaskellKeyword $
                category <> " '" <> name <> "' is a Haskell keyword and cannot become a record field in generated code"
            ]
        | fieldSafe name = []
        | otherwise =
            [ mkErr (locLine anchor) IdentNotConstructorSafe $
                category <> " '" <> name <> "' must begin with a lowercase ASCII letter or underscore to become a Haskell record field"
            ]

    vertexCollisions aggregate =
        [ mkErr (locLine (aggLoc aggregate)) VertexCtorCollision $
            "aggregate '"
                <> aggName aggregate
                <> "' state '"
                <> stName state
                <> "' generates vertex constructor '"
                <> vertex
                <> "', which collides with "
                <> declarationKind
                <> " '"
                <> vertex
                <> "' in the generated Domain constructor namespace"
        | state <- aggStates aggregate
        , let vertex = aggName aggregate <> stName state
        , declarationKind <- collisionKinds aggregate vertex
        ]

    collisionKinds aggregate vertex =
        ["event" | vertex `elem` map evName (aggEvents aggregate)]
            ++ ["command" | vertex `elem` map cmdName (aggCommands aggregate)]
            ++ ["enum constructor" | vertex `elem` [ctor | enum <- specEnums spec, (ctor, _) <- enumCtors enum]]

-- Haskell 2010 reserved identifiers plus commonly enabled extension keywords.
haskellKeywords :: Set Name
haskellKeywords =
    Set.fromList
        [ "case"
        , "class"
        , "data"
        , "default"
        , "deriving"
        , "do"
        , "else"
        , "foreign"
        , "if"
        , "import"
        , "in"
        , "infix"
        , "infixl"
        , "infixr"
        , "instance"
        , "let"
        , "module"
        , "newtype"
        , "of"
        , "then"
        , "type"
        , "where"
        , "mdo"
        , "rec"
        , "proc"
        ]

constructorSafe :: Name -> Bool
constructorSafe name = case T.uncons name of
    Just (first, rest) -> asciiUpper first && T.all asciiAlphaNumOrUnderscore rest
    Nothing -> False

fieldSafe :: Name -> Bool
fieldSafe name = case T.uncons name of
    Just (first, rest) -> (asciiLower first || first == '_') && T.all asciiAlphaNumOrUnderscore rest
    Nothing -> False

asciiUpper :: Char -> Bool
asciiUpper c = c >= 'A' && c <= 'Z'

asciiLower :: Char -> Bool
asciiLower c = c >= 'a' && c <= 'z'

asciiAlphaNumOrUnderscore :: Char -> Bool
asciiAlphaNumOrUnderscore c = asciiUpper c || asciiLower c || (c >= '0' && c <= '9') || c == '_'

-- | Rules over namespaces shared by the whole specification.
specLevelRules :: Spec -> [Diagnostic]
specLevelRules spec = duplicateNodes ++ duplicateEnumMembers ++ duplicateIdPrefixes ++ ruleDiagnostics
  where
    duplicateNodes =
        [ mkErr (locLine loc) DuplicateNodeName $
            "duplicate " <> kind <> " node name '" <> name <> "'"
        | node <- duplicatesBy nodeKey (specNodes spec)
        , let (kind, name, loc) = nodeIdentity node
        ]
    nodeKey node = let (kind, name, _) = nodeIdentity node in (kind, name)
    duplicateEnumMembers = concatMap enumDuplicates (specEnums spec)
    enumDuplicates e =
        [ mkErr (locLine (enumLoc e)) DuplicateEnumCtor $
            "enum '" <> enumName e <> "' declares constructor '" <> ctor <> "' more than once"
        | (ctor, _) <- duplicatesBy fst (enumCtors e)
        ]
            ++ [ mkErr (locLine (enumLoc e)) DuplicateEnumWire $
                    "enum '" <> enumName e <> "' declares wire spelling '" <> wire <> "' more than once"
               | (_, wire) <- duplicatesBy snd (enumCtors e)
               ]
    duplicateIdPrefixes =
        [ mkErr (locLine (idLoc d)) DuplicateIdPrefix $
            "id '" <> idName d <> "' reuses prefix '" <> idPrefix d <> "'"
        | d <- duplicatesBy idPrefix (specIds spec)
        ]
    ruleDiagnostics = concatMap (validateRule spec) (specRules spec)

nodeIdentity :: Node -> (Text, Name, Loc)
nodeIdentity (NAggregate a) = ("aggregate", aggName a, aggLoc a)
nodeIdentity (NProcess p) = ("process", procId p, procLoc p)
nodeIdentity (NContract c) = ("contract", ctrName c, ctrLoc c)
nodeIdentity (NIntake i) = ("intake", inkName i, inkLoc i)
nodeIdentity (NEmit e) = ("emit", emName e, emLoc e)
nodeIdentity (NPublisher p) = ("publisher", pubName p, pubLoc p)
nodeIdentity (NWorkqueue w) = ("workqueue", wqName w, wqLoc w)
nodeIdentity (NPgmqDispatch d) = ("dispatch", pdName d, pdLoc d)
nodeIdentity (NReadModel r) = ("readmodel", rmName r, rmLoc r)
nodeIdentity (NWorkflow w) = ("workflow", wfId w, wfLoc w)
nodeIdentity (NOperation o) = ("operation", opName o, opLoc o)

validateNode :: Spec -> Node -> [Diagnostic]
validateNode spec (NAggregate agg) = validateAggregate spec agg
validateNode spec (NProcess p) = validateProcess spec p
validateNode _spec (NContract _) = [] -- a contract is a declaration; coupling is checked at the referrers
validateNode spec (NIntake i) = validateIntake i ++ intakeCoupling spec i
validateNode spec (NEmit e) = validateEmit spec e
validateNode spec (NPublisher p) = validatePublisher spec p
validateNode _spec (NWorkqueue w) = validateWorkqueue w
validateNode spec (NPgmqDispatch d) = validatePgmqDispatch spec d
validateNode spec (NReadModel readModel) = validateReadModel spec readModel
validateNode _spec (NWorkflow w) = validateWorkflow w
validateNode spec (NOperation o) = validateOperation spec o

-- | Workflow replay keys and injected input references must be unambiguous.
validateWorkflow :: WorkflowNode -> [Diagnostic]
validateWorkflow w = duplicateLabels ++ sleepFields ++ idField
  where
    inputFields = map fieldName (wfInputFields w)
    duplicateLabels =
        [ mkErr (locLine (wfBodyLoc item)) WorkflowDuplicateLabel $
            "workflow '" <> wfId w <> "' declares label '" <> wfBodyLabel item <> "' more than once; labels key deterministic replay, so a duplicate label replays the first occurrence's journaled result"
        | item <- duplicatesBy wfBodyLabel (wfBody w)
        ]
    sleepFields =
        [ mkErr (locLine loc) WorkflowSleepDelayUnresolved $
            "workflow '" <> wfId w <> "' sleep '" <> label <> "' references undeclared input field '" <> delay <> "'"
        | WfSleep label delay loc <- wfBody w
        , delay `notElem` inputFields
        ]
    idField = case wfIdField w of
        Just field
            | field `notElem` inputFields ->
                [ mkErr (locLine (wfLoc w)) WorkflowIdFieldUnresolved $
                    "workflow '" <> wfId w <> "' derives its id from undeclared input field '" <> field <> "'"
                ]
        _ -> []

wfBodyLabel :: WfBodyItem -> Name
wfBodyLabel (WfStep label _ _) = label
wfBodyLabel (WfAwait label _ _) = label
wfBodyLabel (WfSleep label _ _) = label
wfBodyLabel (WfChild label _ _ _) = label

wfBodyLoc :: WfBodyItem -> Loc
wfBodyLoc (WfStep _ _ loc) = loc
wfBodyLoc (WfAwait _ _ loc) = loc
wfBodyLoc (WfSleep _ _ loc) = loc
wfBodyLoc (WfChild _ _ _ loc) = loc

-- | A top-level rule is a total, clock-free function over one declared enum.
validateRule :: Spec -> RuleDecl -> [Diagnostic]
validateRule spec rule = case [e | e <- specEnums spec, enumName e == ruleDomain rule] of
    [] ->
        [ mkErr rl RuleDomainUnresolved $
            "rule '" <> ruleName rule <> "' has undeclared enum domain '" <> ruleDomain rule <> "'"
        ]
    (domain : _) -> totality domain ++ unknownCases domain ++ bodyDiagnostics
  where
    rl = locLine (ruleLoc rule)
    caseNames = map fst (ruleCases rule)
    allEnumCtors = Set.fromList [ctor | e <- specEnums spec, (ctor, _) <- enumCtors e]
    totality domain =
        let missing = [ctor | (ctor, _) <- enumCtors domain, ctor `notElem` caseNames]
         in [ mkErr rl RuleNotTotal $
                "rule '" <> ruleName rule <> "' is not total over enum '" <> enumName domain <> "'; missing cases {" <> T.intercalate ", " missing <> "}"
            | not (null missing)
            ]
    unknownCases domain =
        [ mkErr rl RuleCaseUnknownCtor $
            "rule '" <> ruleName rule <> "' has case '" <> ctor <> "' which is not a constructor of enum '" <> enumName domain <> "'"
        | (ctor, _) <- ruleCases rule
        , ctor `notElem` map fst (enumCtors domain)
        ]
    bodyDiagnostics = concatMap validateBody (ruleCases rule)
    validateBody (ctor, expr) =
        [ mkErr rl ClockSampled $
            "rule '" <> ruleName rule <> "' case '" <> ctor <> "' samples the wall clock via '" <> atom <> "'; rules must be deterministic"
        | atom <- dedup (exprNames expr)
        , atom `Set.member` clockAtoms
        ]
            ++ [ mkErr rl GuardAtomOutOfScope $
                    "atom '" <> atom <> "' in rule '" <> ruleName rule <> "' resolves to no enum constructor or boolean literal"
               | atom <- dedup (exprNames expr)
               , atom `Set.notMember` clockAtoms
               , atom `Set.notMember` allEnumCtors
               ]

{- | Operation rules resolve command aggregates, stream fields, projections,
read models, workflow signal labels and value types, and run targets.
-}
validateOperation :: Spec -> OperationNode -> [Diagnostic]
validateOperation spec o = case opShape o of
    CommandOp aggregate streamField _ projections ->
        aggregateRef aggregate streamField ++ projectionRefs projections
    QueryOp readModel _ _ consistency ->
        resolveReadModelRef QueryUnresolvedReadModel spec (opLoc o) ("query operation '" <> opName o <> "'") readModel
            ++ [ mkErr ol QueryConsistencyInvalid $
                    "query operation '" <> opName o <> "' has unknown consistency '" <> consistency <> "'; expected Strong, Eventual, or PositionWait"
               | consistency `notElem` (["Strong", "Eventual", "PositionWait"] :: [Name])
               ]
    SignalOp lbl wf _ _ valueType ->
        case lookupWorkflow wf of
            Nothing ->
                [mkErr ol AwaitSignalMismatch ("signal operation '" <> opName o <> "' targets undeclared workflow '" <> wf <> "'")]
            Just w -> case [(resultType, loc) | WfAwait label resultType loc <- wfBody w, label == lbl] of
                [] ->
                    [ mkErr ol AwaitSignalMismatch $
                        "signal '" <> lbl <> "' of " <> wf <> " has no matching 'await' (workflow declares awaits {" <> T.intercalate ", " (awaitLabels w) <> "}); the deterministic awakeable id will not match and the workflow will wait forever"
                    ]
                ((resultType, _) : _)
                    | valueType == resultType -> []
                    | otherwise ->
                        [ mkErr ol AwaitSignalValueMismatch $
                            "signal '" <> lbl <> "' of " <> wf <> " carries value type '" <> valueType <> "' but the await expects '" <> resultType <> "'"
                        ]
    RunOp wf _ _ ->
        [ mkErr ol RunWorkflowUnresolved ("run operation '" <> opName o <> "' targets undeclared workflow '" <> wf <> "'")
        | wf `notElem` map wfId workflows
        ]
  where
    ol = locLine (opLoc o)
    workflows = [w | NWorkflow w <- specNodes spec]
    aggregates = [a | NAggregate a <- specNodes spec]
    projectionTables = [projTable p | a <- aggregates, Just p <- [aggProjection a]]
    lookupWorkflow n = case [w | w <- workflows, wfId w == n] of (w : _) -> Just w; [] -> Nothing
    awaitLabels w = [l | WfAwait l _ _ <- wfBody w]
    aggregateRef name streamField = case [a | a <- aggregates, aggName a == name] of
        [] ->
            [ mkErr ol OperationUnresolvedRef $
                "command operation '" <> opName o <> "' targets undeclared aggregate '" <> name <> "'"
            ]
        (aggregate : _) ->
            [ mkErr ol OperationUnresolvedRef $
                "command operation '" <> opName o <> "' stream field '" <> streamField <> "' is not declared by any command of aggregate '" <> name <> "'"
            | streamField `notElem` [fieldName field | command <- aggCommands aggregate, field <- cmdFields command]
            ]
    projectionRefs projections =
        [ mkErr ol OperationUnresolvedRef $
            "command operation '" <> opName o <> "' references undeclared projection table '" <> projection <> "'"
        | projection <- projections
        , projection `notElem` projectionTables
        ]

-- | Resolve a named read-model node using the caller's diagnostic code.
resolveReadModelRef :: DiagnosticCode -> Spec -> Loc -> Text -> Name -> [Diagnostic]
resolveReadModelRef diagnosticCode spec diagnosticLoc context name =
    [ mkErr (locLine diagnosticLoc) diagnosticCode $
        context <> " references undeclared readmodel '" <> name <> "'"
    | name `notElem` [rmName readModel | NReadModel readModel <- specNodes spec]
    ]

-- | Validate captured identity, feed semantics, and the declared column surface.
validateReadModel :: Spec -> ReadModelNode -> [Diagnostic]
validateReadModel spec readModel =
    shapeFixture ++ columnTypes ++ strongFeed ++ scopeMode ++ inlineReference
  where
    readModelLine = locLine (rmLoc readModel)
    expectedShape = deriveShapeHash readModel
    shapeFixture =
        [ mkErr readModelLine RmShapeHashDrift $
            "readmodel '"
                <> rmName readModel
                <> "': captured shape \""
                <> rmShape readModel
                <> "\" does not match the declared columns (expected \""
                <> expectedShape
                <> "\"); update the fixture AND bump version if the table shape really changed"
        | rmShape readModel /= expectedShape
        ]
    allowedColumnTypes = Set.fromList ["text", "int", "bigint", "bool", "timestamptz", "jsonb", "numeric"]
    columnTypes =
        [ mkErr readModelLine RmUnknownColumnType $
            "readmodel '" <> rmName readModel <> "' column '" <> rmcName columnDecl <> "' has unknown type '" <> rmcType columnDecl <> "'"
        | columnDecl <- rmColumns readModel
        , rmcType columnDecl `Set.notMember` allowedColumnTypes
        ]
    strongFeed =
        [ mkErr readModelLine RmStrongInlineOnly $
            "readmodel '"
                <> rmName readModel
                <> "': consistency = Strong with feed = inline; an inline-only model has no subscription worker to advance the cursor a Strong read waits on. Use consistency = Eventual, or feed = subscription"
        | rmFeed readModel == RmInline
        , rmConsistency readModel == Strong
        ]
    scopeMode =
        [ mkErr readModelLine RmScopeWithoutStrong $
            "readmodel '" <> rmName readModel <> "': scope is meaningful only with consistency = Strong"
        | rmScope readModel /= Nothing
        , rmConsistency readModel /= Strong
        ]
    inlineReference =
        [ mkErr readModelLine RmInlineFeedUnreferenced $
            "readmodel '" <> rmName readModel <> "' declares feed = inline but no aggregate projection references it"
        | rmFeed readModel == RmInline
        , rmName readModel `notElem` [projTable projection | NAggregate aggregate <- specNodes spec, Just projection <- [aggProjection aggregate]]
        ]

{- | EP-5 workqueue rules: the captured physical name must match the queueRef
derivation; the disposition inversions (storeFailure transient => must retry;
decodeFailure poison => must dead-letter); and dlq=on requires a retry ceiling.
-}
validateWorkqueue :: WorkqueueNode -> [Diagnostic]
validateWorkqueue w = concat [divergence, completeness, duplicateRows, inversions, retryCeiling]
  where
    wl = locLine (wqLoc w)
    rows = wqDisposition w
    (derivedPhysical, derivedDlq, derivedTable) = derivedQueueTrio (wqLogical w)
    divergence =
        [ mkErr wl WqPhysicalDivergence $
            "workqueue '" <> wqName w <> "': captured physical \"" <> wqPhysical w <> "\" diverges from queueRef(\"" <> wqLogical w <> "\") = \"" <> derivedPhysical <> "\""
        | wqPhysical w /= derivedPhysical
        ]
            ++ [ mkErr wl WqDlqDivergence $
                    "workqueue '" <> wqName w <> "': captured dlq \"" <> wqDlq w <> "\" diverges from queueRef = \"" <> derivedDlq <> "\""
               | wqDlq w /= derivedDlq
               ]
            ++ [ mkErr wl WqTableDivergence $
                    "workqueue '" <> wqName w <> "': captured table \"" <> wqTable w <> "\" diverges from queueRef table = \"" <> derivedTable <> "\""
               | wqTable w /= derivedTable
               ]
    requiredOutcomes = ["storeFailure", "commandRejected", "decodeFailure", "onCodecReject"]
    completeness =
        [ mkErr wl WqDispositionIncomplete $
            "workqueue '" <> wqName w <> "' disposition table is missing outcome '" <> outcome <> "'"
        | outcome <- requiredOutcomes
        , outcome `notElem` map wqdOutcome rows
        ]
    duplicateRows =
        [ mkErr (locLine (wqdLoc row)) DispositionDuplicateOutcome $
            "workqueue '" <> wqName w <> "' repeats disposition outcome '" <> wqdOutcome row <> "'; the first row would shadow this row"
        | row <- duplicatesBy wqdOutcome rows
        ]
    firstRow outcome = case [row | row <- rows, wqdOutcome row == outcome] of
        (row : _) -> Just row
        [] -> Nothing
    isRetry row = case wqdAction row of IRetry _ -> True; _ -> False
    isDeadLetter row = case wqdAction row of IDeadLetter _ -> True; _ -> False
    inversions =
        [ mkErr (locLine (wqdLoc row)) WqStoreFailureNotRetry ("workqueue '" <> wqName w <> "': 'storeFailure' is transient and MUST retry, not dead-letter")
        | Just row <- [firstRow "storeFailure"]
        , isDeadLetter row
        ]
            ++ [ mkErr (locLine (wqdLoc row)) WqDecodeFailureNotDeadLetter ("workqueue '" <> wqName w <> "': 'decodeFailure' is poison and MUST dead-letter, not retry")
               | Just row <- [firstRow "decodeFailure"]
               , isRetry row
               ]
    retryCeiling =
        [ mkErr wl WqDlqWithoutCeiling ("workqueue '" <> wqName w <> "': dlq=on requires maxRetries >= 1 (an absent ceiling never dead-letters)")
        | wqDlqOn w && wqMaxRetries w < 1
        ]

-- | EP-5 dispatch rule: the @enqueue to@ target must resolve to a declared workqueue.
validatePgmqDispatch :: Spec -> PgmqDispatchNode -> [Diagnostic]
validatePgmqDispatch spec d = enqueueRef ++ dedupQueueRef ++ sourceReadModelRef ++ dedupReadModelRef ++ dedupReadModelField
  where
    dl = locLine (pdLoc d)
    workqueues = [w | NWorkqueue w <- specNodes spec]
    enqueueRef =
        [ mkErr dl DispatchEnqueueUnresolved ("dispatch '" <> pdName d <> "' enqueues to undeclared workqueue '" <> pdEnqueueTo d <> "'")
        | pdEnqueueTo d `notElem` map wqName workqueues
        ]
    dedupQueueRef = case [w | w <- workqueues, wqName w == pdDedupQueue d] of
        [] ->
            [ mkErr dl DispatchDedupQueueUnresolved $
                "dispatch '" <> pdName d <> "' checks an undeclared dedup queue '" <> pdDedupQueue d <> "'"
            ]
        (queue : _) ->
            [ mkErr dl DispatchDedupFieldUnresolved $
                "dispatch '" <> pdName d <> "' dedup field '" <> pdDedupQueueField d <> "' is not a payload wire field of queue '" <> pdDedupQueue d <> "'"
            | pdDedupQueueField d `notElem` map wqfWire (wqPayload queue)
            ]
    sourceReadModelRef =
        resolveReadModelRef DispatchReadModelUnresolved spec (pdLoc d) ("dispatch '" <> pdName d <> "' source") (pdSourceReadModel d)
    dedupReadModelRef =
        resolveReadModelRef DispatchReadModelUnresolved spec (pdLoc d) ("dispatch '" <> pdName d <> "' dedup") (pdDedupReadModel d)
    dedupReadModelField = case [readModel | NReadModel readModel <- specNodes spec, rmName readModel == pdDedupReadModel d] of
        [] -> []
        (readModel : _) ->
            [ mkErr dl DispatchReadModelFieldUnknown $
                "dispatch '" <> pdName d <> "' dedup field '" <> pdDedupReadModelField d <> "' is not a declared column of readmodel '" <> pdDedupReadModel d <> "'"
            | pdDedupReadModelField d `notElem` map rmcName (rmColumns readModel)
            ]

-- | The declared contracts in a spec, by name.
specContracts :: Spec -> [ContractNode]
specContracts spec = [c | NContract c <- specNodes spec]

-- | EP-4 cross-node coupling: an intake's contract/topic/accepted-events resolve.
intakeCoupling :: Spec -> IntakeNode -> [Diagnostic]
intakeCoupling spec i = case lookupContract (inkContract i) of
    Nothing ->
        [mkErr (locLine (inkLoc i)) IntakeUnresolvedContract ("intake '" <> inkName i <> "' references undeclared contract '" <> inkContract i <> "'")]
    Just c ->
        [ mkErr (locLine (inkLoc i)) IntakeUnresolvedContract ("intake '" <> inkName i <> "' topic '" <> inkTopic i <> "' is not a topic of contract '" <> inkContract i <> "'")
        | inkTopic i `notElem` map fst (ctrTopics c)
        ]
            ++ [ mkErr (locLine (inkLoc i)) IntakeUnresolvedContract ("intake '" <> inkName i <> "' accepts event '" <> ev <> "' not declared in contract '" <> inkContract i <> "'")
               | ev <- inkAccept i
               , ev `notElem` map ceName (ctrEvents c)
               ]
            ++ [ mkErr (locLine (inkLoc i)) TopicAffinityMismatch $
                    "intake '" <> inkName i <> "' subscribes to topic '" <> inkTopic i <> "' but accepted event '" <> ceName event <> "' is declared on topic '" <> ceTopic event <> "'"
               | event <- ctrEvents c
               , ceName event `elem` inkAccept i
               , ceTopic event /= inkTopic i
               ]
  where
    lookupContract n = case [c | c <- specContracts spec, ctrName c == n] of (c : _) -> Just c; [] -> Nothing

validateEmit :: Spec -> EmitNode -> [Diagnostic]
validateEmit spec e = skipRule ++ coupling
  where
    el = locLine (emLoc e)
    skipRule =
        [ mkErr el EmitSkipMissing ("emit '" <> emName e <> "' map must end with an explicit '_ => skip' catch-all (hole-kind 7 optionality)")
        | not (emSkip e)
        ]
    coupling = case [c | c <- specContracts spec, ctrName c == emContract e] of
        [] -> [mkErr el EmitUnresolvedContract ("emit '" <> emName e <> "' references undeclared contract '" <> emContract e <> "'")]
        (c : _) ->
            [ mkErr el EmitUnresolvedContract ("emit '" <> emName e <> "' topic '" <> emTopic e <> "' is not a topic of contract '" <> emContract e <> "'")
            | emTopic e `notElem` map fst (ctrTopics c)
            ]
                ++ [ mkErr (locLine (emrLoc r)) EmitUnresolvedContract ("emit '" <> emName e <> "' maps to event '" <> emrEvent r <> "' not declared in contract '" <> emContract e <> "'")
                   | r <- emMap e
                   , emrEvent r `notElem` map ceName (ctrEvents c)
                   ]
                ++ [ mkErr (locLine (emrLoc row)) TopicAffinityMismatch $
                        "emit '" <> emName e <> "' publishes on topic '" <> emTopic e <> "' but mapped event '" <> emrEvent row <> "' is declared on topic '" <> ceTopic event <> "'"
                   | row <- emMap e
                   , event <- ctrEvents c
                   , ceName event == emrEvent row
                   , ceTopic event /= emTopic e
                   ]

validatePublisher :: Spec -> PublisherNode -> [Diagnostic]
validatePublisher spec p =
    [ mkErr (locLine (pubLoc p)) PublisherUnresolvedEmit ("publisher '" <> pubName p <> "' references undeclared emit '" <> pubEmit p <> "'")
    | pubEmit p `notElem` [emName e | NEmit e <- specNodes spec]
    ]

{- | EP-4 inbox disposition rules: the table must be complete over the seven
outcomes, and the three dangerous inversions must be stated the safe way.
-}
validateIntake :: IntakeNode -> [Diagnostic]
validateIntake i = concat [completeness, duplicateRows, inversions]
  where
    il = locLine (inkLoc i)
    rows = inkDisposition i
    requiredOutcomes =
        ["processed", "duplicate", "inProgress", "previouslyFailed", "decodeFailed", "dedupeFailed", "storeFailed"]
    completeness =
        [ mkErr il DispositionIncomplete $
            "intake '" <> inkName i <> "' disposition table is missing outcome '" <> o <> "'"
        | o <- requiredOutcomes
        , o `notElem` map drOutcome rows
        ]
    duplicateRows =
        [ mkErr (locLine (drLoc row)) DispositionDuplicateOutcome $
            "intake '" <> inkName i <> "' repeats disposition outcome '" <> drOutcome row <> "'; the first row would shadow this row"
        | row <- duplicatesBy drOutcome rows
        ]
    firstRow outcome = case [row | row <- rows, drOutcome row == outcome] of
        (row : _) -> Just row
        [] -> Nothing
    isRetry row = case drAction row of IRetry _ -> True; _ -> False
    inversions =
        [ mkErr (locLine (drLoc row)) DispositionDuplicateRetry $
            "intake '" <> inkName i <> "': a 'duplicate' redelivery must be ackOk (success), not retry"
        | Just row <- [firstRow "duplicate"]
        , isRetry row
        ]
            ++ [ mkErr (locLine (drLoc row)) DispositionPreviouslyFailedRetry $
                    "intake '" <> inkName i <> "': 'previouslyFailed' must dead-letter, not retry (a prior failure won't succeed on replay)"
               | Just row <- [firstRow "previouslyFailed"]
               , isRetry row
               ]
            ++ [ mkErr (locLine (drLoc row)) DispositionDecodeUnboundedRetry $
                    "intake '" <> inkName i <> "': 'decodeFailed' must dead-letter (terminal), not retry unboundedly"
               | Just row <- [firstRow "decodeFailed"]
               , isRetry row
               ]

-- | EP-3 rules for a process manager + its nested timer.
validateProcess :: Spec -> ProcessNode -> [Diagnostic]
validateProcess spec p =
    concat [noWallClock, runtimeOwnedDispatchId, crossNodeCoupling, timerCeiling, benignInversions]
  where
    aggregates = [a | NAggregate a <- specNodes spec]
    aggNames = map aggName aggregates
    projectionTables = [projTable projection | aggregate <- aggregates, Just projection <- [aggProjection aggregate]]
    inputFields = map fieldName (inFields (procInput p))
    timeFields = [fieldName f | f <- inFields (procInput p), fieldType f == Just "Time"]
    timer = procTimer p
    pl = locLine (procLoc p)

    -- TIME IS INJECTED, NOT SAMPLED: fireAt's field must be a declared :Time
    -- input field. (FireAtExpr has no clock-sampling constructor, so this is a
    -- field-resolution + typed-as-Time check.)
    noWallClock =
        let f = faField (tmFireAt timer)
         in if f `notElem` inputFields
                then
                    [ mkErr (locLine (tmLoc timer)) ProcessFireAtNotInjected $
                        "timer '" <> tmName timer <> "' fireAt field '" <> f <> "' is not a field of input '" <> inName (procInput p) <> "'"
                    ]
                else
                    [ mkErr (locLine (tmLoc timer)) ProcessFireAtNotInjected $
                        "timer '" <> tmName timer <> "' fireAt references '" <> f <> "', which is not a declared :Time field of input '" <> inName (procInput p) <> "'"
                    | f `notElem` timeFields
                    ]

    -- Dispatched (and fired) command ids are runtime-owned; no field binding may
    -- supply a commandId/id.
    runtimeOwnedDispatchId =
        [ mkErr pl ProcessDispatchIdSupplied $
            "advance command '" <> advCommand advance <> "' supplies a runtime-owned id field '" <> fbName binding <> "'; remove it"
        | let advance = hAdvance (procHandle p)
        , binding <- advFields advance
        , fbName binding `elem` (["commandId", "id"] :: [Name])
        ]
            ++ [ mkErr (locLine (dispLoc d)) ProcessDispatchIdSupplied $
                    "dispatch to '" <> dispTarget d <> "' supplies a runtime-owned id field '" <> fbName b <> "'; remove it"
               | d <- hDispatch (procHandle p)
               , b <- dispFields d
               , fbName b `elem` (["commandId", "id"] :: [Name])
               ]
            ++ [ mkErr (locLine (tmLoc timer)) ProcessDispatchIdSupplied $
                    "timer fire supplies a runtime-owned id field '" <> fbName b <> "'; remove it"
               | b <- fireFields (tmFire timer)
               , fbName b `elem` (["commandId", "id"] :: [Name])
               ]

    -- Aggregate, command, field, timer, and projection references must resolve.
    crossNodeCoupling =
        [ mkErr pl ProcessUnresolvedRef ("saga '" <> sagaAgg (procSaga p) <> "' does not resolve to a declared aggregate")
        | sagaAgg (procSaga p) `notElem` aggNames
        ]
            ++ [ mkErr pl ProcessUnresolvedRef ("target '" <> procTarget p <> "' does not resolve to a declared aggregate")
               | procTarget p `notElem` aggNames
               ]
            ++ [ mkErr (locLine (tmLoc timer)) ProcessUnresolvedRef ("timer fire target '" <> fireTarget (tmFire timer) <> "' must be the saga or the target aggregate")
               | fireTarget (tmFire timer) `notElem` [sagaAgg (procSaga p), procTarget p]
               ]
            ++ resolveCommand pl "advance" (sagaAgg (procSaga p)) (advCommand advance) (advFields advance)
            ++ concatMap resolveDispatch (hDispatch (procHandle p))
            ++ resolveCommand (locLine (tmLoc timer)) "timer fire" (fireTarget fire) (fireCommand fire) (fireFields fire)
            ++ [ mkErr pl ProcessUnresolvedRef $
                    "process '" <> procId p <> "' schedules undeclared timer '" <> hSchedule (procHandle p) <> "'; declared timer is '" <> tmName timer <> "'"
               | hSchedule (procHandle p) /= tmName timer
               ]
            ++ [ mkErr pl ProcessUnresolvedRef $
                    "process '" <> procId p <> "' references undeclared projection table '" <> projection <> "'"
               | projection <- procProjections p
               , projection `notElem` projectionTables
               ]
      where
        advance = hAdvance (procHandle p)
        fire = tmFire timer
        resolveDispatch dispatch =
            resolveCommand
                (locLine (dispLoc dispatch))
                "dispatch"
                (dispTarget dispatch)
                (dispCommand dispatch)
                (dispFields dispatch)
        resolveCommand diagnosticLine context target command bindings = case lookupAggregate target of
            Nothing -> []
            Just aggregate -> case [decl | decl <- aggCommands aggregate, cmdName decl == command] of
                [] ->
                    [ mkErr diagnosticLine ProcessUnresolvedRef $
                        context <> " command '" <> command <> "' is not declared by aggregate '" <> target <> "'"
                    ]
                (declaration : _) ->
                    [ mkErr diagnosticLine ProcessFieldBindingUnresolved $
                        context <> " command '" <> command <> "' binds undeclared target field '" <> fbName binding <> "'"
                    | binding <- bindings
                    , fbName binding `notElem` map fieldName (cmdFields declaration)
                    ]
        lookupAggregate name = case [aggregate | aggregate <- aggregates, aggName aggregate == name] of
            (aggregate : _) -> Just aggregate
            [] -> Nothing

    timerCeiling =
        [ mkErr (locLine (tmLoc timer)) ProcessTimerCeilingInvalid $
            "timer '" <> tmName timer <> "' max-attempts must be at least 1"
        | tmMaxAttempts timer < 1
        ]

    -- Surface the dangerous benign inversions the author confirmed (warnings).
    benignInversions =
        [ Diagnostic (locLine (tmLoc timer)) Warning ProcessBenignInversion $
            "timer '" <> tmName timer <> "' maps on-reject => Fired (a CommandRejected is treated as benign success)"
        | onReject (fireDisposition (tmFire timer)) == OFired
        ]
            ++ [ Diagnostic (locLine (dispLoc d)) Warning ProcessBenignInversion $
                    "dispatch to '" <> dispTarget d <> "' maps on-duplicate => AckOk (a duplicate is treated as benign success)"
               | d <- hDispatch (procHandle p)
               , onDuplicate (dispDisposition d) == DAckOk
               ]

validateAggregate :: Spec -> Aggregate -> [Diagnostic]
validateAggregate spec agg =
    concat
        [ duplicateMembers
        , declaredRefs
        , eventBodyRefs
        , registerInitialScope
        , reachability
        , terminalNoOutgoing
        , guardScope
        , clockFree
        , projectionSafety
        , statusMapTotality
        , evolutionRules
        ]
  where
    states = Set.fromList (map stName (aggStates agg))
    terminals = Set.fromList [stName s | s <- aggStates agg, stTerminal s]
    commandFields :: Map Name [Name]
    commandFields = Map.fromList [(cmdName c, map fieldName (cmdFields c)) | c <- aggCommands agg]
    commandNames = Map.keysSet commandFields
    eventNames = Set.fromList (map evName (aggEvents agg))
    enumCtorNames = Set.fromList [c | e <- specEnums spec, (c, _) <- enumCtors e]
    ruleNames = Set.fromList (map ruleName (specRules spec))
    registerNames = Set.fromList (map regName (aggRegs agg))

    duplicateMembers =
        [ mkErr (locLine (cmdLoc c)) DuplicateCommandName $
            "aggregate '" <> aggName agg <> "' declares command '" <> cmdName c <> "' more than once"
        | c <- duplicatesBy cmdName (aggCommands agg)
        ]
            ++ [ mkErr (locLine (evLoc e)) DuplicateEventName $
                    "aggregate '" <> aggName agg <> "' declares event '" <> evName e <> "' more than once"
               | e <- duplicatesBy evName (aggEvents agg)
               ]

    eventBodyRefs =
        [ mkErr (locLine (evLoc e)) UndeclaredCommand $
            "event '" <> evName e <> "' copies fields from undeclared command '" <> command <> "'"
        | e <- aggEvents agg
        , EventFromCommand command <- [evBody e]
        , command `Set.notMember` commandNames
        ]

    registerInitialScope = concatMap checkRegisterInitial (aggRegs agg)
    checkRegisterInitial r = case [e | e <- specEnums spec, enumName e == regType r] of
        (e : _) ->
            [ outOfScope r "constructor of enum" (enumName e)
            | regInitialBare r `notElem` map (Just . fst) (enumCtors e)
            ]
        []
            | regType r == aggName agg <> "Vertex" ->
                [ outOfScope r "state of aggregate" (aggName agg)
                | maybe True (`Set.notMember` states) (regInitialBare r)
                ]
            | regType r `elem` map idName (specIds spec) ->
                [ outOfScope r "literal" "placeholder"
                | regInitialBare r /= Just "placeholder"
                ]
            | otherwise -> []
    outOfScope r expected domain =
        mkErr (locLine (regLoc r)) RegisterInitialOutOfScope $
            "register '" <> regName r <> "' initial '" <> renderRegInitial (regInitial r) <> "' is not a " <> expected <> " '" <> domain <> "'"
    regInitialBare r = case regInitial r of
        RegInitBare value -> Just value
        RegInitText _ -> Nothing
    renderRegInitial = \case
        RegInitBare value -> value
        RegInitText value -> value

    -- Rule 1: declared-reference for command / emit / goto / source.
    declaredRefs =
        concatMap transitionRefs (aggTransitions agg)
    transitionRefs t =
        [ mkErr (locLine (tLoc t)) UndeclaredCommand $
            "transition references undeclared command '" <> tCommand t <> "'"
        | not (tCommand t `Set.member` commandNames)
        ]
            ++ [ mkErr (locLine (tLoc t)) UndeclaredState $
                    "transition source '" <> tSource t <> "' is not a declared state"
               | not (tSource t `Set.member` states)
               ]
            ++ [ mkErr (locLine (tLoc t)) UndeclaredState $
                    "transition goto '" <> tGoto t <> "' is not a declared state"
               | not (tGoto t `Set.member` states)
               ]
            ++ [ mkErr (locLine (tLoc t)) UndeclaredEvent $
                    "emit references undeclared event '" <> ev <> "'"
               | ev <- tEmits t
               , not (ev `Set.member` eventNames)
               ]

    -- Rule 2: reachability of every non-terminal state from the initial state
    -- (the first state in the list).
    reachability = case map stName (aggStates agg) of
        [] -> []
        (initial : _) ->
            let reached = bfs (Set.singleton initial) [initial]
             in [ mkErr (locLine (stLoc s)) UnreachableState $
                    "state '" <> stName s <> "' is not reachable from the initial state '" <> initial <> "'"
                | s <- aggStates agg
                , not (stTerminal s)
                , not (stName s `Set.member` reached)
                ]
    edgesFrom src = [tGoto t | t <- aggTransitions agg, tSource t == src]
    bfs seen [] = seen
    bfs seen (x : xs) =
        let nexts = [n | n <- edgesFrom x, not (n `Set.member` seen)]
         in bfs (foldr Set.insert seen nexts) (xs ++ nexts)

    -- Rule 3: a terminal state has no outgoing transition.
    terminalNoOutgoing =
        [ mkErr (locLine (tLoc t)) TerminalHasOutgoing $
            "terminal state '" <> tSource t <> "' has an outgoing transition"
        | t <- aggTransitions agg
        , tSource t `Set.member` terminals
        ]

    -- Rule 4: every atom in a guard or write Expr resolves to a register, a
    -- field of the transition's command, an enum constructor, a rule, or a bool.
    guardScope = concatMap transitionScope (aggTransitions agg)
    transitionScope t =
        let inScope =
                registerNames
                    `Set.union` Set.fromList (Map.findWithDefault [] (tCommand t) commandFields)
                    `Set.union` enumCtorNames
                    `Set.union` ruleNames
                    -- State names are constructors of the implicit vertex enum, so a
                    -- @write reservationState := Held@ references a state legitimately.
                    `Set.union` states
            exprs = maybe [] pure (tGuard t) ++ map snd (tWrites t)
            badAtoms =
                [ n
                | e <- exprs
                , n <- exprNames e
                , not (n `Set.member` clockAtoms) -- clock atoms reported separately
                , not (n `Set.member` inScope)
                ]
            badTargets = [target | (target, _) <- tWrites t, target `Set.notMember` registerNames]
         in [ mkErr (locLine (tLoc t)) WriteTargetNotRegister $
                "write target '" <> target <> "' is not a register of aggregate '" <> aggName agg <> "'"
            | target <- dedup badTargets
            ]
                ++ [ mkErr (locLine (tLoc t)) GuardAtomOutOfScope $
                        "atom '" <> n <> "' in transition '" <> tSource t <> " -- " <> tCommand t <> "' resolves to no register, command field, enum constructor, or rule"
                   | n <- dedup badAtoms
                   ]

    -- Rule 5 (cross-cutting): no guard or write Expr samples a wall clock.
    clockFree = concatMap transitionClock (aggTransitions agg)
    transitionClock t =
        let exprs = maybe [] pure (tGuard t) ++ map snd (tWrites t)
            sampled = [n | e <- exprs, n <- exprNames e, n `Set.member` clockAtoms]
         in [ mkErr (locLine (tLoc t)) ClockSampled $
                "transition '" <> tSource t <> " -- " <> tCommand t <> "' samples the wall clock via '" <> n <> "'; time must be an injected input field, not sampled"
            | n <- dedup sampled
            ]

    -- EP-107: a projection references a first-class read model when one exists.
    -- Legacy standalone projections remain legal, but are surfaced as warnings.
    projectionSafety = case aggProjection agg of
        Nothing -> []
        Just projection -> case [readModel | NReadModel readModel <- specNodes spec, rmName readModel == projTable projection] of
            [] ->
                [ mkErr (locLine (projLoc projection)) RmStrongInlineOnly $
                    "projection '" <> projTable projection <> "' declares consistency = Strong but has no readmodel node; a standalone projection is inline-only and has no subscription cursor"
                | projConsistency projection == Just Strong
                ]
                    ++ [ Diagnostic
                            { line = locLine (projLoc projection)
                            , severity = Warning
                            , code = RmProjectionWithoutNode
                            , message = "projection '" <> projTable projection <> "' has no readmodel node; registration, schema identity, consistency, and rebuild helpers are unavailable"
                            }
                       ]
            (readModel : _) ->
                [ mkErr (locLine (projLoc projection)) RmConsistencyConflict $
                    "projection '" <> projTable projection <> "' declares consistency " <> T.pack (show projectionConsistency) <> " but its readmodel node declares " <> T.pack (show (rmConsistency readModel))
                | Just projectionConsistency <- [projConsistency projection]
                , projectionConsistency /= rmConsistency readModel
                ]

    -- Rule 6 (hole-kind 3, mapping): keys are exact event names, never suffixes;
    -- duplicates and dangling keys are errors, and non-partial maps are total.
    statusMapTotality = case aggProjection agg of
        Nothing -> []
        Just p ->
            let evs = map evName (aggEvents agg)
                pairs = maybe [] mapPairs (projStatusMap p)
                keys = map fst pairs
                partial = maybe False mapPartial (projStatusMap p)
                uncovered = [event | event <- evs, event `notElem` keys]
                dangling = [key | key <- keys, key `notElem` evs]
                duplicateKeys = map fst (duplicatesBy fst pairs)
             in [ mkErr (locLine (projLoc p)) StatusMapDanglingKey $
                    "projection '" <> projTable p <> "' status-map key '" <> key <> "' is not an event name of aggregate '" <> aggName agg <> "'"
                | key <- dangling
                ]
                    ++ [ mkErr (locLine (projLoc p)) StatusMapDuplicateKey $
                            "projection '" <> projTable p <> "' repeats status-map key '" <> key <> "'"
                       | key <- duplicateKeys
                       ]
                    ++ [ mkErr (locLine (projLoc p)) StatusMapNotTotal $
                            "projection '" <> projTable p <> "' status-map is not total over events {" <> T.intercalate ", " uncovered <> "}"
                       | not partial
                       , not (null evs)
                       , not (null uncovered)
                       ]

    -- EP-2 evolution rules (single-spec; the diff path adds the cross-spec ones).
    evolutionRules = versionUpcasterRule ++ deprecatedEmitRule ++ wireVersionRule
    emittedNames = Set.fromList (concatMap tEmits (aggTransitions agg))
    maxEventVersion = maximum (1 : map evVersion (aggEvents agg))

    -- A non-initial event version must carry a contiguous upcaster (from v-1).
    versionUpcasterRule =
        [ mkErr (locLine (evLoc e)) EvtVersionMissingUpcaster $
            "event '" <> evName e <> "' version " <> tInt (evVersion e) <> " has no 'upcast from v" <> tInt (evVersion e - 1) <> "' clause"
        | e <- aggEvents agg
        , evVersion e > 1
        , maybe True ((/= evVersion e - 1) . fst) (evUpcastFrom e)
        ]

    -- A deprecated event must have left the write path.
    deprecatedEmitRule =
        [ mkErr (locLine (evLoc e)) DeprecatedEventStillEmitted $
            "deprecated event '" <> evName e <> "' is still emitted by a transition"
        | e <- aggEvents agg
        , evDeprecated e
        , evName e `Set.member` emittedNames
        ]

    -- The explicit `wire schemaVersion=` (if any) must equal the max event version.
    wireVersionRule = case aggWire agg of
        Just w
            | wireSchemaVersion w /= maxEventVersion ->
                [ Diagnostic
                    { line = locLine (aggLoc agg)
                    , severity = Warning
                    , code = WireSchemaVersionMismatch
                    , message =
                        "wire schemaVersion=" <> tInt (wireSchemaVersion w) <> " does not match the maximum event version " <> tInt maxEventVersion
                    }
                ]
        _ -> []

{- | The validator's re-derivation of the live
'Keiro.PGMQ.Runtime.queueRef' trio: physical queue, dead-letter queue, and
PGMQ backing table. Parity is pinned by the queue-runtime conformance suite.
-}
derivedQueueTrio :: Text -> (Text, Text, Text)
derivedQueueTrio logical = (physical, physical <> "_dlq", "pgmq.q_" <> physical)
  where
    physical = physicalBase logical

physicalBase :: Text -> Text
physicalBase logical
    | T.length base <= 43 && not ("_dlq" `T.isSuffixOf` base) = base
    | otherwise = hashedBase logical base
  where
    base = sanitizeQueueName logical

sanitizeQueueName :: Text -> Text
sanitizeQueueName =
    ensureLeadingLetter
        . T.intercalate "_"
        . filter (not . T.null)
        . T.splitOn "_"
        . T.map toLegal
        . T.toLower
  where
    toLegal c
        | (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' = c
        | otherwise = '_'
    ensureLeadingLetter value = case T.uncons value of
        Nothing -> "q"
        Just (c, _)
            | c >= 'a' && c <= 'z' -> value
            | otherwise -> T.cons 'q' value

hashedBase :: Text -> Text -> Text
hashedBase logical base = prefix <> "_" <> fnv1a64Hex logical
  where
    trimmedPrefix = T.dropWhileEnd (== '_') (T.take 26 base)
    prefix
        | T.null trimmedPrefix = "q"
        | otherwise = trimmedPrefix

fnv1a64Hex :: Text -> Text
fnv1a64Hex logical = T.pack (replicate (16 - length rendered) '0' <> rendered)
  where
    rendered = showHex (T.foldl' step offset logical) ""
    offset :: Word64
    offset = 0xcbf29ce484222325
    prime :: Word64
    prime = 0x100000001b3
    step hash character = (hash `xor` fromIntegral (ord character)) * prime

tInt :: Int -> Text
tInt = T.pack . show

mkErr :: Int -> DiagnosticCode -> Text -> Diagnostic
mkErr l c m = Diagnostic{line = l, severity = Error, code = c, message = m}

locLine :: Loc -> Int
locLine = unLoc

-- | The 'AName' atom names occurring anywhere in an expression.
exprNames :: Expr -> [Name]
exprNames (EOr a b) = exprNames a ++ exprNames b
exprNames (EAnd a b) = exprNames a ++ exprNames b
exprNames (ECmp _ a b) = exprNames a ++ exprNames b
exprNames (EAtom (AName n)) = [n]
exprNames (EAtom (ABool _)) = []

dedup :: (Ord a) => [a] -> [a]
dedup = Set.toList . Set.fromList

{- | Keep each occurrence after the first for a chosen key. Diagnostics are
anchored on the shadowing declaration rather than the declaration it shadows.
-}
duplicatesBy :: (Eq key) => (a -> key) -> [a] -> [a]
duplicatesBy key xs =
    [ x
    | (index, x) <- zip [0 :: Int ..] xs
    , key x `elem` map key (take index xs)
    ]
