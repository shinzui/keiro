-- | Canonical identities for the aggregate fold surface used while hydrating
-- event streams. The fingerprint deliberately excludes payload codecs,
-- projections, snapshot policy, and source locations: those inputs do not change
-- how an existing event log becomes aggregate state.
module Keiro.Dsl.FoldFingerprint
  ( FoldSurfaceError (..),
    renderFoldSurfaceError,
    aggregateFoldFingerprintForService,
    aggregateFoldSurfaceForService,
  )
where

import Data.List (find)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.AggregateType
import Keiro.Dsl.CanonicalEncoding (canonicalExpr, foldFingerprint128)
import Keiro.Dsl.EventOutput
import Keiro.Dsl.Expression
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion (RuntimeCapability (NominalEqualityV2), runtimeProfileHasCapability)
import Keiro.Dsl.NominalType
import Keiro.Dsl.SemanticContract (CheckedService, EffectiveLanguageContract (..), checkedLanguageContract, checkedSpec, checkedTypeGraph, runtimeSemanticsFingerprintSegments)
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
aggregateFoldSurfaceForService service aggregate = do
  graph <- mapLeft (FoldTypeGraphResolutionFailed . showText) (checkedTypeGraph service)
  let symbols = aggregateSymbolsFromGraph graph spec
  nominalRegistry <- mapLeft (FoldNominalResolutionFailed . showText) (resolveNominalTypes spec)
  registerSegments <- traverse (registerSegment symbols) ((.regs) aggregate)
  equalityUses <- nominalEqualityUses graph service aggregate
  transitionSegments <- traverse (transitionSegment graph spec aggregate) ((.transitions) aggregate)
  pure
    ( T.intercalate
        "\n"
        ( runtimeSemanticsFingerprintSegments (checkedLanguageContract service)
            ++ map stateSegment ((.states) aggregate)
            ++ registerSegments
            ++ mappedRegisterSegments graph
            ++ nominalSegments nominalRegistry
            ++ ["nominal-equality-use:" <> identity | identity <- Set.toAscList equalityUses]
            ++ transitionSegments
            ++ map ruleSegment referencedRules
        )
    )
  where
    spec = checkedSpec service
    referencedRules =
      [ rule
      | rule <- (.rules) spec,
        (.name) rule `Set.member` referencedRuleNames spec aggregate
      ]
    mappedRegisterSegments graph =
      [ mappedRegisterSegment graph declaration
      | register <- (.regs) aggregate,
        TRef typeName <- [(.valueType) register],
        Just declaration <- [Map.lookup (MappedKey typeName) ((.declarations) graph)]
      ]
    nominalSegments registry =
      [ nominalUseSegment useSite nominal binding
      | (useSite, typeName) <- nominalUseNames aggregate,
        Just nominal <- [lookupNominalType typeName registry],
        ConsumerNominal binding <- [(.ownership) nominal]
      ]

-- | Equality representation belongs in the fold identity only when a guard
-- actually compares that declaration. This keeps unrelated binding metadata out
-- of replay compatibility while ensuring a witness/domain change cannot silently
-- retain the old fold fingerprint.
nominalEqualityUses :: TypeGraph -> CheckedService -> Aggregate -> Either FoldSurfaceError (Set Text)
nominalEqualityUses graph service aggregate =
  if runtimeProfileHasCapability ((.runtimeProfile) (checkedLanguageContract service)) NominalEqualityV2
    then fmap (Set.fromList . concat) (traverse transitionIdentities ((.transitions) aggregate))
    else
      Right
        ( Set.fromList
            [ identity
            | transition <- (.transitions) aggregate,
              guardSyntax <- maybeToList ((.guard) transition),
              Right guardExpression <- [resolveGuardExpr (expressionEnvironmentFromGraph graph spec aggregate transition) guardSyntax],
              identity <- equalityIdentities (checkedLanguageContract service) guardExpression
            ]
        )
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

equalityIdentities :: EffectiveLanguageContract -> TypedScalarExpr -> [Text]
equalityIdentities languageContract expression =
  current <> children
  where
    current = case (.node) expression of
      TypedEqual left _ -> equalityIdentity left
      TypedNotEqual left _ -> equalityIdentity left
      _ -> []
    equalityIdentity operand = case (.valueType) operand of
      AggregateNominal nominal -> maybeToList (nominalEqualityIdentityForService languageContract nominal)
      _ -> []
    children = case (.node) expression of
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

nominalUseNames :: Aggregate -> [(Text, Name)]
nominalUseNames aggregate =
  [ ("register:" <> (.name) register, typeName)
  | register <- (.regs) aggregate,
    TRef typeName <- [(.valueType) register]
  ]
    <> [ ("event:" <> (.name) event <> "." <> (.name) field, typeName)
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

nominalRepresentationSegment :: NominalRepresentation -> Text
nominalRepresentationSegment representation = case representation of
  IdRepresentation prefix -> "id:" <> prefix
  EnumRepresentation constructors -> "enum:" <> T.intercalate "," [constructor <> "=" <> wire | (constructor, wire) <- NE.toList constructors]
  ScalarRepresentation scalar -> case scalar of
    NominalText -> "Text"
    NominalInt -> "Int"
    NominalNatural -> "Natural"
    NominalBool -> "Bool"
    NominalTime -> "Time"

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
  outputOwnershipSegment <- case (.implementation) transition of
    LegacyHoleImplementation -> Right []
    GeneratedImplementation -> fmap (pure . ("outputs=" <>) . T.intercalate ",") outputSegments
    HoleImplementation -> fmap (pure . ("outputs=" <>) . T.intercalate ",") outputSegments
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
        )
    )
  where
    renderWrite (registerName, expression) = registerName <> ":=" <> canonicalExpr expression
    outputSegments = traverse (uncurry outputSegment) (zip [1 ..] ((.emits) transition))
    outputSegment emitIndex eventName = do
      mapping <-
        mapLeft
          (FoldEventOutputResolutionFailed ((.name) aggregate) ((.command) transition) eventName . showText)
          (eventOutputMappingFromGraph graph spec aggregate transition emitIndex eventName)
      pure (eventName <> "=" <> eventOutputCanonical mapping)
    implementationSegment = case (.implementation) transition of
      LegacyHoleImplementation -> []
      GeneratedImplementation -> ["implementation=generated"]
      HoleImplementation -> ["implementation=hole"]

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

referencedRuleNames :: Spec -> Aggregate -> Set Name
referencedRuleNames spec aggregate = close directNames
  where
    rules = (.rules) spec
    directNames =
      Set.unions
        [ exprNames expression
        | transition <- (.transitions) aggregate,
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
