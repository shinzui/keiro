{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Canonical identities for the aggregate fold surface used while hydrating
-- event streams. The fingerprint deliberately excludes payload codecs,
-- projections, snapshot policy, and source locations: those inputs do not change
-- how an existing event log becomes aggregate state.
module Keiro.Dsl.FoldEvidence
  ( FoldSurfaceError (..),
    renderFoldSurfaceError,
    aggregateFoldFingerprintForService,
    aggregateFoldSurfaceForService,
    FoldEvidence (..),
    BodyEvidence (..),
    aggregateFoldEvidenceForService,
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LazyBytes
import Data.List (find)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TextEncoding
import Keiro.Codec.IdDomain (v5OrV7IdDomainVersion)
import Keiro.Dsl.AggregateType
import Keiro.Dsl.CanonicalEncoding (canonicalExpr, foldFingerprint128)
import Keiro.Dsl.EventOutput
import Keiro.Dsl.Expression
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion (RuntimeCapability (NominalEqualityV2), runtimeProfileHasCapability)
import Keiro.Dsl.NominalType
import Keiro.Dsl.SemanticContract (CheckedService, EffectiveLanguageContract (..), checkedLanguageContract, checkedSpec, checkedTypeGraph, runtimeSemanticsFingerprintSegments)
import Keiro.Dsl.TransitionFamily (ReplayBodyKey, TransitionFamilyKey (..), replayBodyKey)
import Keiro.Dsl.TypeGraph

-- | A checked service can retain language provenance before semantic
-- validation succeeds. Fold identity therefore reports every resolution
-- failure instead of silently omitting or inventing canonical segments.
data FoldSurfaceError
  = FoldTypeGraphResolutionFailed !Text
  | FoldNominalResolutionFailed !Text
  | FoldRegisterTypeResolutionFailed !Name !Text
  | FoldRegisterInitialResolutionFailed !Name !Text
  | FoldGuardResolutionFailed !Name !Name !Text
  | FoldWriteResolutionFailed !Name !Name !Text
  | FoldEventOutputResolutionFailed !Name !Name !Name !Text
  deriving stock (Eq, Show)

renderFoldSurfaceError :: FoldSurfaceError -> Text
renderFoldSurfaceError = \case
  FoldTypeGraphResolutionFailed detail -> "aggregate fold type-graph resolution failed: " <> detail
  FoldNominalResolutionFailed detail -> "aggregate fold nominal resolution failed: " <> detail
  FoldRegisterTypeResolutionFailed registerName detail ->
    "aggregate fold register '" <> registerName <> "' type resolution failed: " <> detail
  FoldRegisterInitialResolutionFailed registerName detail ->
    "aggregate fold register '" <> registerName <> "' initial resolution failed: " <> detail
  FoldGuardResolutionFailed aggregateName commandName detail ->
    "aggregate fold guard resolution failed for '" <> aggregateName <> "." <> commandName <> "': " <> detail
  FoldWriteResolutionFailed aggregateName registerName detail -> "aggregate fold write resolution failed for " <> aggregateName <> "." <> registerName <> ": " <> detail
  FoldEventOutputResolutionFailed aggregateName commandName eventName detail ->
    "aggregate fold output resolution failed for '"
      <> aggregateName
      <> "."
      <> commandName
      <> "' emitting '"
      <> eventName
      <> "': "
      <> detail

-- | The thirty-two-hex-digit identity of an aggregate's replay fold under the
-- service's effective runtime semantics.
aggregateFoldFingerprintForService :: CheckedService -> Aggregate -> Either FoldSurfaceError Text
aggregateFoldFingerprintForService service = fmap foldFingerprint128 . aggregateFoldSurfaceForService service

-- | Canonical pre-hash text under a checked semantic contract. A runtime
-- discriminator is included only for a contract that can change fold behavior;
-- source declaration provenance and grammar-only versions never enter it.
aggregateFoldSurfaceForService :: CheckedService -> Aggregate -> Either FoldSurfaceError Text
aggregateFoldSurfaceForService service aggregate =
  fmap (T.intercalate "\n" . (.canonicalSegments)) (aggregateFoldEvidenceForService service aggregate)

-- | Comparison-only evidence; never serialized as persisted fold identity.
-- Every segment is resolved against the real aggregate's own checked service.
data FoldEvidence = FoldEvidence
  { canonicalSegments :: ![Text],
    aggregateSegments :: ![Text],
    eventSegments :: !(Map.Map Name (Set Text)),
    bodySegments :: !(Map.Map (TransitionFamilyKey, ReplayBodyKey) BodyEvidence)
  }

data BodyEvidence = BodyEvidence
  { outputSegments :: !(Set Text),
    ruleSegments :: !(Map.Map Name Text),
    equalitySegments :: !(Map.Map Name (Set Text)),
    guardEqualitySegments :: !(Map.Map Text (Set Text)),
    emittedEvents :: !(Set Name)
  }

aggregateFoldEvidenceForService :: CheckedService -> Aggregate -> Either FoldSurfaceError FoldEvidence
aggregateFoldEvidenceForService service aggregate = do
  graph <- mapLeft (FoldTypeGraphResolutionFailed . showText) (checkedTypeGraph service)
  let symbols = aggregateSymbolsFromGraph graph spec
  nominalRegistry <- mapLeft (FoldNominalResolutionFailed . showText) (resolveNominalTypes spec)
  registerSegments <- traverse (registerSegment symbols) ((.regs) aggregate)
  equalityUses <- nominalEqualityUses graph service aggregate ((.transitions) aggregate)
  transitionSegments <- traverse (transitionSegment graph spec aggregate) ((.transitions) aggregate)
  bodies <- traverse (bodyEvidence graph) ((.transitions) aggregate)
  let global =
        runtimeSemanticsFingerprintSegments (checkedLanguageContract service)
          ++ map stateSegment ((.states) aggregate)
          ++ registerSegments
          ++ mappedRegisterSegments graph
      directNominals =
        [ (eventName, segment)
        | (eventName, useSite, typeName) <- nominalUseNames aggregate,
          Just nominal <- [lookupNominalType typeName nominalRegistry],
          segment <- nominalUseSegments useSite nominal
        ]
      nestedNominals =
        [ (eventNameFor path, nestedNominalUseSegment path leaf)
        | leaf <- Map.elems ((.nominalLeaves) graph),
          path <- nominalUsePaths graph ((.name) leaf),
          isNestedAggregateFoldUse ((.name) aggregate) path
        ]
      nominals = directNominals ++ nestedNominals
  pure
    FoldEvidence
      { canonicalSegments =
          global
            ++ map snd directNominals
            ++ map snd nestedNominals
            ++ [(if "keiro-dsl/structural-enum-equality/" `T.isPrefixOf` identity then "structural-enum-equality-use:" else "nominal-equality-use:") <> identity | identity <- Set.toAscList (Set.fromList (map snd equalityUses))]
            ++ transitionSegments
            ++ map ruleSegment (referencedRules ((.transitions) aggregate)),
        aggregateSegments = global ++ [segment | (Nothing, segment) <- nominals],
        eventSegments =
          Map.union
            (Map.fromListWith Set.union [(name, Set.singleton segment) | (Just name, segment) <- nominals])
            (Map.fromList [((.name) event, Set.empty) | event <- (.events) aggregate]),
        bodySegments = Map.fromListWith mergeBodyEvidence bodies
      }
  where
    spec = checkedSpec service
    referencedRules transitions =
      [ rule
      | rule <- (.rules) spec,
        (.name) rule `Set.member` referencedRuleNames spec transitions
      ]
    bodyEvidence graph transition = do
      resolvedOutputs <- transitionOutputs graph spec aggregate transition
      let outputs =
            [ eventName <> "=" <> case mapping of
                HandOwnedEventOutput {} -> "hand-owned"
                GeneratedCommandIdentity {} -> eventOutputCanonical mapping
            | (eventName, mapping) <- resolvedOutputs
            ]
      equalities <- nominalEqualityUses graph service aggregate [transition]
      guardEvidence <- case transition.guard of
        Nothing -> Right Map.empty
        Just syntax -> case resolveGuardExpr (expressionEnvironmentFromGraph graph spec aggregate transition) syntax of
          Right expression -> Right (equalitySites (checkedLanguageContract service) syntax expression)
          Left detail
            | runtimeProfileHasCapability ((.runtimeProfile) (checkedLanguageContract service)) NominalEqualityV2 ->
                Left (FoldGuardResolutionFailed aggregate.name transition.command (showText detail))
            | otherwise -> Right Map.empty
      pure
        ( (TransitionFamilyKey transition.mode transition.source transition.command, replayBodyKey transition),
          BodyEvidence
            { outputSegments = Set.fromList outputs,
              ruleSegments = Map.fromList [((.name) rule, ruleSegment rule) | rule <- referencedRules [transition]],
              equalitySegments = Map.fromListWith Set.union [(name, Set.singleton identity) | (name, identity) <- equalities],
              guardEqualitySegments = guardEvidence,
              emittedEvents = Set.fromList transition.emits
            }
        )
    mappedRegisterSegments graph =
      [ mappedRegisterSegment graph declaration
      | register <- (.regs) aggregate,
        TRef typeName <- [(.valueType) register],
        Just declaration <- [Map.lookup (MappedKey typeName) ((.declarations) graph)]
      ]
    eventNameFor path = case (.root) path of
      RootEventField _ eventName _ -> Just eventName
      _ -> Nothing

mergeBodyEvidence :: BodyEvidence -> BodyEvidence -> BodyEvidence
mergeBodyEvidence left right =
  BodyEvidence
    { outputSegments = left.outputSegments <> right.outputSegments,
      ruleSegments = Map.union left.ruleSegments right.ruleSegments,
      equalitySegments = Map.unionWith Set.union left.equalitySegments right.equalitySegments,
      guardEqualitySegments = Map.unionWith Set.union left.guardEqualitySegments right.guardEqualitySegments,
      emittedEvents = left.emittedEvents <> right.emittedEvents
    }

-- | Nested nominal leaves participate in an aggregate fold wherever persisted
-- event payloads or snapshot registers contain their enclosing structural
-- declaration.  The structural register's own initial binding constructs the
-- whole value, so a nested nominal's @initial@ symbol is deliberately absent.
isNestedAggregateFoldUse :: Name -> UsePath -> Bool
isNestedAggregateFoldUse aggregateName UsePath {root, segments} =
  isNested segments && case root of
    RootEventField owner _ _ -> owner == aggregateName
    RootRegister owner _ -> owner == aggregateName
    RootCommandField {} -> False
    RootWorkqueueField {} -> False
    RootReadModelQueryInput {} -> False
    RootReadModelQueryResult {} -> False
    RootContractField {} -> False
  where
    isNested (SegDecl {} : _) = True
    isNested _ = False

nestedNominalUseSegment :: UsePath -> NominalLeaf -> Text
nestedNominalUseSegment path leaf =
  T.intercalate
    "|"
    ( [ "nested-nominal-use:" <> renderUsePath path,
        "name=" <> (.name) leaf,
        "representation=" <> nominalLeafRepresentationSegment ((.kind) leaf)
      ]
        <> ownershipSegments ((.ownership) leaf)
    )
  where
    ownershipSegments GeneratedLeaf = ["owner=generated"]
    ownershipSegments (ConsumerLeaf binding) =
      [ "owner=consumer",
        "canonical=" <> unCanonicalTypeId ((.canonical) binding),
        "binding=" <> unQualifiedValueName ((.binding) binding),
        "binding-version=" <> unBindingVersion ((.bindingVersion) binding)
      ]

nominalLeafRepresentationSegment :: NominalLeafKind -> Text
nominalLeafRepresentationSegment = \case
  NominalIdLeaf prefix admission -> idRepresentationSegment prefix admission
  NominalEnumLeaf constructors ->
    "enum:" <> T.intercalate "," [constructor <> "=" <> wire | (constructor, wire) <- NE.toList constructors]
  NominalScalarLeaf representation -> case representation of
    NominalText -> "Text"
    NominalInt -> "Int"
    NominalNatural -> "Natural"
    NominalBool -> "Bool"
    NominalTime -> "Time"

-- | Equality representation belongs in the fold identity only when a guard
-- actually compares that declaration. This keeps unrelated binding metadata out
-- of replay compatibility while ensuring a witness/domain change cannot silently
-- retain the old fold fingerprint.
nominalEqualityUses :: TypeGraph -> CheckedService -> Aggregate -> [Transition] -> Either FoldSurfaceError [(Name, Text)]
nominalEqualityUses graph service aggregate transitions =
  if runtimeProfileHasCapability ((.runtimeProfile) (checkedLanguageContract service)) NominalEqualityV2
    then fmap concat (traverse transitionIdentities transitions)
    else
      Right
        [ identity
        | transition <- transitions,
          guardSyntax <- maybeToList ((.guard) transition),
          Right guardExpression <- [resolveGuardExpr (expressionEnvironmentFromGraph graph spec aggregate transition) guardSyntax],
          identity <- equalityIdentities (checkedLanguageContract service) guardExpression
        ]
  where
    spec = checkedSpec service
    transitionIdentities transition = case (.guard) transition of
      Nothing -> Right []
      Just guardSyntax -> do
        guardExpression <-
          mapLeft
            (FoldGuardResolutionFailed ((.name) aggregate) ((.command) transition) . showText)
            (resolveGuardExpr (expressionEnvironmentFromGraph graph spec aggregate transition) guardSyntax)
        pure (equalityIdentities (checkedLanguageContract service) guardExpression)

equalityIdentities :: EffectiveLanguageContract -> TypedScalarExpr -> [(Name, Text)]
equalityIdentities languageContract expression =
  current <> children
  where
    current = case (.node) expression of
      TypedEqual left _ -> equalityIdentity left
      TypedNotEqual left _ -> equalityIdentity left
      _ -> []
    equalityIdentity operand = case (.valueType) operand of
      AggregateStructuralEnum evidence -> [(unMappedKey evidence.key, structuralEnumEqualityIdentity evidence)]
      AggregateNominal nominal -> [((.name) nominal, identity) | identity <- maybeToList (nominalEqualityIdentityForService languageContract nominal)]
      _ -> []
    children = case (.node) expression of
      TypedMappedLift _ _ child -> equalityIdentities languageContract child
      TypedMappedInitial {} -> []
      TypedLiteral {} -> []
      TypedRoot {} -> []
      TypedProject {} -> []
      TypedAdd _ left right -> recurse left right
      TypedSubtract _ left right -> recurse left right
      TypedMultiply _ left right -> recurse left right
      TypedEqual left right -> recurse left right
      TypedNotEqual left right -> recurse left right
      TypedCompare _ left right -> recurse left right
      TypedAnd left right -> recurse left right
      TypedOr left right -> recurse left right
    recurse left right = equalityIdentities languageContract left <> equalityIdentities languageContract right

-- Compare retained equality expressions even when a surrounding guard is
-- loosened or split. Empty evidence matters: a nominal-to-primitive edit must
-- not disappear just because the new expression no longer uses a nominal.
equalitySites :: EffectiveLanguageContract -> Expr -> TypedScalarExpr -> Map.Map Text (Set Text)
equalitySites contract syntax expression =
  Map.unionsWith Set.union (current : zipWith (equalitySites contract) syntaxChildren typedChildren)
  where
    current = case expression.node of
      TypedEqual {} -> site
      TypedNotEqual {} -> site
      _ -> Map.empty
    site = Map.singleton (canonicalExpr syntax) (Set.fromList (map snd (equalityIdentities contract expression)))
    syntaxChildren = case syntax of
      EWriteMapped _ child -> [child]
      EOr left right -> [left, right]
      EAnd left right -> [left, right]
      ECmp _ left right -> [left, right]
      EAdd _ left right -> [left, right]
      ESubtract _ left right -> [left, right]
      EMultiply _ left right -> [left, right]
      _ -> []
    typedChildren = case expression.node of
      TypedMappedLift _ _ child -> [child]
      TypedOr left right -> [left, right]
      TypedAnd left right -> [left, right]
      TypedEqual left right -> [left, right]
      TypedNotEqual left right -> [left, right]
      TypedCompare _ left right -> [left, right]
      TypedAdd _ left right -> [left, right]
      TypedSubtract _ left right -> [left, right]
      TypedMultiply _ left right -> [left, right]
      _ -> []

nominalUseNames :: Aggregate -> [(Maybe Name, Text, Name)]
nominalUseNames aggregate =
  [ (Nothing, "register:" <> (.name) register, typeName)
  | register <- (.regs) aggregate,
    TRef typeName <- [(.valueType) register]
  ]
    <> [ (Just ((.name) event), "event:" <> (.name) event <> "." <> (.name) field, typeName)
       | event <- (.events) aggregate,
         field <- eventFields event,
         TRef typeName <- maybe [] pure ((.valueType) field)
       ]
  where
    eventFields event = case (.body) event of
      EventFields fields -> fields
      EventFromCommand commandName -> concat [(.fields) command | command <- (.commands) aggregate, (.name) command == commandName]

nominalUseSegment :: Text -> ResolvedNominalType -> ConsumerNominalBinding -> Text
nominalUseSegment useSite nominal binding =
  T.intercalate
    "|"
    [ "nominal-use:" <> useSite,
      "name=" <> (.name) nominal,
      "representation=" <> nominalRepresentationSegment ((.representation) nominal),
      "canonical=" <> unCanonicalTypeId ((.canonical) binding),
      "binding=" <> unQualifiedValueName ((.binding) binding),
      "binding-version=" <> unBindingVersion ((.bindingVersion) binding),
      "initial=" <> maybe "(none)" unQualifiedValueName ((.initial) binding)
    ]

-- Released generated IDs contributed no direct-use segment. Preserve that
-- exact surface for implicit v7 while making the candidate wider domain visible
-- on direct registers and event fields. Consumer-owned nominal segments already
-- existed and now carry the selected domain through their representation.
nominalUseSegments :: Text -> ResolvedNominalType -> [Text]
nominalUseSegments useSite nominal = case (.ownership) nominal of
  ConsumerNominal binding -> [nominalUseSegment useSite nominal binding]
  GeneratedNominal -> case (.representation) nominal of
    IdRepresentation _ TypeIdV5OrV7 ->
      [ T.intercalate
          "|"
          [ "nominal-use:" <> useSite,
            "name=" <> (.name) nominal,
            "representation=" <> nominalRepresentationSegment ((.representation) nominal),
            "owner=generated"
          ]
      ]
    _ -> []

nominalRepresentationSegment :: NominalRepresentation -> Text
nominalRepresentationSegment representation = case representation of
  IdRepresentation prefix admission -> idRepresentationSegment prefix admission
  EnumRepresentation constructors -> "enum:" <> T.intercalate "," [constructor <> "=" <> wire | (constructor, wire) <- NE.toList constructors]
  ScalarRepresentation scalar -> case scalar of
    NominalText -> "Text"
    NominalInt -> "Int"
    NominalNatural -> "Natural"
    NominalBool -> "Bool"
    NominalTime -> "Time"

idRepresentationSegment :: Text -> IdAdmission -> Text
idRepresentationSegment prefix TypeIdV7 = "id:" <> prefix
idRepresentationSegment prefix TypeIdV5OrV7 = "id:" <> prefix <> ";domain=" <> v5OrV7IdDomainVersion

mappedRegisterSegment :: TypeGraph -> ResolvedMappedDecl -> Text
mappedRegisterSegment graph (ResolvedStructural declaration _) =
  T.intercalate
    "|"
    [ "mapped-register:" <> (.name) declaration,
      "wire=" <> wireFingerprint graph ((.name) declaration),
      "canonical=" <> unCanonicalTypeId ((.canonical) declaration),
      "binding=" <> unQualifiedValueName ((.binding) declaration),
      "binding-version=" <> unBindingVersion ((.bindingVersion) declaration),
      "initial=" <> maybe "(missing)" unQualifiedValueName ((.initial) declaration)
    ]
mappedRegisterSegment _ (ResolvedOpaque declaration) =
  T.intercalate
    "|"
    [ "mapped-register:" <> (.name) declaration,
      "codec=" <> unCodecIdentity ((.codecIdentity) declaration),
      "codec-version=" <> unCodecVersion ((.codecVersion) declaration),
      "initial=" <> maybe "(missing)" unQualifiedValueName ((.initial) declaration)
    ]

stateSegment :: StateDecl -> Text
stateSegment state =
  "state:"
    <> (.name) state
    <> "|terminal="
    <> if (.terminal) state then "true" else "false"

registerSegment :: AggregateSymbols -> RegDecl -> Either FoldSurfaceError Text
registerSegment symbols register = do
  resolvedType <-
    mapLeft
      (FoldRegisterTypeResolutionFailed ((.name) register) . showText)
      (resolveAggregateType symbols ((.loc) register) RegisterUse ((.valueType) register))
  resolvedInitial <-
    mapLeft
      (FoldRegisterInitialResolutionFailed ((.name) register) . showText)
      (resolveRegisterInitial symbols ((.loc) register) resolvedType ((.initial) register))
  pure
    ( "reg:"
        <> (.name) register
        <> ":"
        <> typeExprCanonicalName ((.valueType) register)
        <> "="
        <> registerInitialCanonicalName resolvedInitial
    )

transitionSegment :: TypeGraph -> Spec -> Aggregate -> Transition -> Either FoldSurfaceError Text
transitionSegment graph spec aggregate transition = do
  outputOwnershipSegment <- transitionOutputSegments graph spec aggregate transition
  resolvedWrites <-
    traverse
      ( \(register, expression) ->
          fmap
            (register,)
            ( mapLeft
                (FoldWriteResolutionFailed aggregate.name register . showText)
                (resolveWriteExpr (expressionEnvironmentFromGraph graph spec aggregate transition) register expression)
            )
      )
      [(register, expression) | (register, expression) <- transition.writes, case expression of EWriteInitial {} -> True; EWriteMapped {} -> True; _ -> False]
  let lifts =
        [ [register, name, liftSourceName lift.source, unQualifiedValueName lift.function, unLiftVersion lift.version]
        | (register, TypedScalarExpr {node = TypedMappedLift name lift _}) <- resolvedWrites
        ]
      liftSegment = ["mapped-write-lifts=" <> TextEncoding.decodeUtf8 (LazyBytes.toStrict (Aeson.encode lifts)) | not (null lifts)]
  pure
    ( T.intercalate
        "|"
        ( [ "transition:" <> renderMode ((.mode) transition),
            (.source) transition,
            (.command) transition
          ]
            ++ implementationSegment
            ++ [ "guard=" <> maybe "" canonicalExpr ((.guard) transition),
                 "writes=" <> T.intercalate ";" (map renderWrite ((.writes) transition)),
                 "emits=" <> T.intercalate "," ((.emits) transition)
               ]
            ++ outputOwnershipSegment
            ++ ["goto=" <> (.goto) transition]
            ++ liftSegment
        )
    )
  where
    renderWrite (registerName, expression) = registerName <> ":=" <> canonicalExpr expression
    implementationSegment = case (.implementation) transition of
      LegacyHoleImplementation -> []
      GeneratedImplementation -> ["implementation=generated"]
      HoleImplementation -> ["implementation=hole"]

-- Shared by the frozen renderer and comparison evidence. No second output resolver.
transitionOutputSegments :: TypeGraph -> Spec -> Aggregate -> Transition -> Either FoldSurfaceError [Text]
transitionOutputSegments graph spec aggregate transition = case (.implementation) transition of
  LegacyHoleImplementation -> Right []
  GeneratedImplementation -> renderOutputs
  HoleImplementation -> renderOutputs
  where
    renderOutputs = fmap (pure . ("outputs=" <>) . T.intercalate "," . map (\(name, mapping) -> name <> "=" <> eventOutputCanonical mapping)) (transitionOutputs graph spec aggregate transition)

-- Resolve against local declarations. The persisted renderer retains the
-- complete obligation key. Comparison uses ownership without its guard-derived
-- provenance: guard coverage is already compared by the replay-body analysis.
transitionOutputs :: TypeGraph -> Spec -> Aggregate -> Transition -> Either FoldSurfaceError [(Name, EventOutputMapping)]
transitionOutputs graph spec aggregate transition = case transition.implementation of
  LegacyHoleImplementation -> Right []
  _ -> traverse (uncurry output) (zip [1 ..] transition.emits)
  where
    output emitIndex eventName = do
      mapping <-
        mapLeft
          (FoldEventOutputResolutionFailed ((.name) aggregate) ((.command) transition) eventName . showText)
          (eventOutputMappingFromGraph graph spec aggregate transition emitIndex eventName)
      pure (eventName, mapping)

renderMode :: TransitionMode -> Text
renderMode TmLive = "live"
renderMode TmReplayOnly = "replay-only"

ruleSegment :: RuleDecl -> Text
ruleSegment rule =
  T.intercalate
    "|"
    [ "rule:" <> (.name) rule,
      (.domain) rule,
      (.codomain) rule,
      "cases=" <> T.intercalate ";" (map renderCase ((.cases) rule))
    ]
  where
    renderCase (constructorName, expression) = constructorName <> "=>" <> canonicalExpr expression

referencedRuleNames :: Spec -> [Transition] -> Set Name
referencedRuleNames spec transitions = close directNames
  where
    rules = (.rules) spec
    directNames =
      Set.unions
        [ exprNames expression
        | transition <- transitions,
          expression <- maybeToList ((.guard) transition) ++ map snd ((.writes) transition)
        ]
    close names =
      let expanded =
            Set.unions
              ( names
                  : [ Set.unions (map (exprNames . snd) ((.cases) rule))
                    | name <- Set.toList names,
                      Just rule <- [find ((== name) . (.name)) rules]
                    ]
              )
       in if expanded == names then names else close expanded

exprNames :: Expr -> Set Name
exprNames = \case
  EOr left right -> exprNames left <> exprNames right
  EAnd left right -> exprNames left <> exprNames right
  ECmp _ left right -> exprNames left <> exprNames right
  EAdd _ left right -> exprNames left <> exprNames right
  ESubtract _ left right -> exprNames left <> exprNames right
  EMultiply _ left right -> exprNames left <> exprNames right
  EPath _ _ (name : _) -> Set.singleton name
  EPath _ _ [] -> Set.empty
  EWriteMapped _ child -> exprNames child
  EWriteInitial {} -> Set.empty
  ELiteral {} -> Set.empty
  EAtom (AName name) -> Set.singleton name
  EAtom (ABool _) -> Set.empty

maybeToList :: Maybe a -> [a]
maybeToList Nothing = []
maybeToList (Just value) = [value]

mapLeft :: (errorValue -> otherError) -> Either errorValue value -> Either otherError value
mapLeft convert = either (Left . convert) Right

showText :: (Show value) => value -> Text
showText = T.pack . show
