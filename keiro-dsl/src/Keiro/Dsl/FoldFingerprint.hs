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
import Keiro.Dsl.CanonicalEncoding (canonicalExpr)
import Keiro.Dsl.EventOutput
import Keiro.Dsl.Expression
import Keiro.Dsl.Grammar
import Keiro.Dsl.LanguageVersion (RuntimeCapability (NominalEqualityV2), runtimeProfileHasCapability)
import Keiro.Dsl.NominalType
import Keiro.Dsl.ReadModelShape (fnv1a64)
import Keiro.Dsl.SemanticContract (CheckedService (..), EffectiveLanguageContract, effectiveRuntimeProfile, runtimeSemanticsFingerprintSegments)
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

-- | The sixteen-hex-digit identity of an aggregate's replay fold under the
-- service's effective runtime semantics.
aggregateFoldFingerprintForService :: CheckedService -> Aggregate -> Either FoldSurfaceError Text
aggregateFoldFingerprintForService service = fmap fnv1a64 . aggregateFoldSurfaceForService service

-- | Canonical pre-hash text under a checked semantic contract. A runtime
-- discriminator is included only for a contract that can change fold behavior;
-- source declaration provenance and grammar-only versions never enter it.
aggregateFoldSurfaceForService :: CheckedService -> Aggregate -> Either FoldSurfaceError Text
aggregateFoldSurfaceForService service aggregate = do
  graph <- mapLeft (FoldTypeGraphResolutionFailed . showText) (resolveTypeGraph spec)
  nominalRegistry <- mapLeft (FoldNominalResolutionFailed . showText) (resolveNominalTypes spec)
  registerSegments <- traverse (registerSegment symbols) (aggRegs aggregate)
  equalityUses <- nominalEqualityUses service aggregate
  transitionSegments <- traverse (transitionSegment spec aggregate) (aggTransitions aggregate)
  pure
    ( T.intercalate
        "\n"
        ( runtimeSemanticsFingerprintSegments (checkedLanguageContract service)
            ++ map stateSegment (aggStates aggregate)
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
    symbols = aggregateSymbols spec
    referencedRules =
      [ rule
      | rule <- specRules spec,
        ruleName rule `Set.member` referencedRuleNames spec aggregate
      ]
    mappedRegisterSegments graph =
      [ mappedRegisterSegment graph declaration
      | register <- aggRegs aggregate,
        TRef typeName <- [regType register],
        Just declaration <- [Map.lookup (MappedKey typeName) (tgDeclarations graph)]
      ]
    nominalSegments registry =
      [ nominalUseSegment useSite nominal binding
      | (useSite, typeName) <- nominalUseNames aggregate,
        Just nominal <- [lookupNominalType typeName registry],
        ConsumerNominal binding <- [resolvedNominalOwnership nominal]
      ]

-- | Equality representation belongs in the fold identity only when a guard
-- actually compares that declaration. This keeps unrelated binding metadata out
-- of replay compatibility while ensuring a witness/domain change cannot silently
-- retain the old fold fingerprint.
nominalEqualityUses :: CheckedService -> Aggregate -> Either FoldSurfaceError (Set Text)
nominalEqualityUses service aggregate =
  if runtimeProfileHasCapability (effectiveRuntimeProfile (checkedLanguageContract service)) NominalEqualityV2
    then fmap (Set.fromList . concat) (traverse transitionIdentities (aggTransitions aggregate))
    else
      Right
        ( Set.fromList
            [ identity
            | transition <- aggTransitions aggregate,
              guardSyntax <- maybeToList (tGuard transition),
              Right guardExpression <- [resolveGuardExpr (expressionEnvironment spec aggregate transition) guardSyntax],
              identity <- equalityIdentities (checkedLanguageContract service) guardExpression
            ]
        )
  where
    spec = checkedSpec service
    transitionIdentities transition = case tGuard transition of
      Nothing -> Right []
      Just guardSyntax -> do
        guardExpression <-
          mapLeft
            (FoldGuardResolutionFailed (aggName aggregate) (tCommand transition) . showText)
            (resolveGuardExpr (expressionEnvironment spec aggregate transition) guardSyntax)
        pure (equalityIdentities (checkedLanguageContract service) guardExpression)

equalityIdentities :: EffectiveLanguageContract -> TypedScalarExpr -> [Text]
equalityIdentities languageContract expression =
  current <> children
  where
    current = case typedScalarNode expression of
      TypedEqual left _ -> equalityIdentity left
      TypedNotEqual left _ -> equalityIdentity left
      _ -> []
    equalityIdentity operand = case typedScalarType operand of
      AggregateNominal nominal -> maybeToList (nominalEqualityIdentityForService languageContract nominal)
      _ -> []
    children = case typedScalarNode expression of
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
  [ ("register:" <> regName register, typeName)
  | register <- aggRegs aggregate,
    TRef typeName <- [regType register]
  ]
    <> [ ("event:" <> evName event <> "." <> aggregateFieldName field, typeName)
       | event <- aggEvents aggregate,
         field <- eventFields event,
         TRef typeName <- maybe [] pure (aggregateFieldType field)
       ]
  where
    eventFields event = case evBody event of
      EventFields fields -> fields
      EventFromCommand commandName -> concat [cmdFields command | command <- aggCommands aggregate, cmdName command == commandName]

nominalUseSegment :: Text -> ResolvedNominalType -> ConsumerNominalBinding -> Text
nominalUseSegment useSite nominal binding =
  T.intercalate
    "|"
    [ "nominal-use:" <> useSite,
      "name=" <> resolvedNominalName nominal,
      "representation=" <> nominalRepresentationSegment (resolvedNominalRepresentation nominal),
      "canonical=" <> unCanonicalTypeId (consumerNominalCanonical binding),
      "binding=" <> unQualifiedValueName (consumerNominalBinding binding),
      "binding-version=" <> unBindingVersion (consumerNominalBindingVersion binding),
      "initial=" <> maybe "(none)" unQualifiedValueName (consumerNominalInitial binding)
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
    [ "mapped-register:" <> sdName declaration,
      "wire=" <> wireFingerprint graph (sdName declaration),
      "canonical=" <> unCanonicalTypeId (sdCanonical declaration),
      "binding=" <> unQualifiedValueName (sdBinding declaration),
      "binding-version=" <> unBindingVersion (sdBindingVersion declaration),
      "initial=" <> maybe "(missing)" unQualifiedValueName (sdInitial declaration)
    ]
mappedRegisterSegment _ (ResolvedOpaque declaration) =
  T.intercalate
    "|"
    [ "mapped-register:" <> odName declaration,
      "codec=" <> unCodecIdentity (odCodecIdentity declaration),
      "codec-version=" <> unCodecVersion (odCodecVersion declaration),
      "initial=" <> maybe "(missing)" unQualifiedValueName (odInitial declaration)
    ]

stateSegment :: StateDecl -> Text
stateSegment state =
  "state:"
    <> stName state
    <> "|terminal="
    <> if stTerminal state then "true" else "false"

registerSegment :: AggregateSymbols -> RegDecl -> Either FoldSurfaceError Text
registerSegment symbols register = do
  resolvedType <-
    mapLeft
      (FoldRegisterTypeResolutionFailed (regName register) . showText)
      (resolveAggregateType symbols (regLoc register) RegisterUse (regType register))
  resolvedInitial <-
    mapLeft
      (FoldRegisterInitialResolutionFailed (regName register) . showText)
      (resolveRegisterInitial symbols (regLoc register) resolvedType (regInitial register))
  pure
    ( "reg:"
        <> regName register
        <> ":"
        <> typeExprCanonicalName (regType register)
        <> "="
        <> registerInitialCanonicalName resolvedInitial
    )

transitionSegment :: Spec -> Aggregate -> Transition -> Either FoldSurfaceError Text
transitionSegment spec aggregate transition = do
  outputOwnershipSegment <- case tImplementation transition of
    LegacyHoleImplementation -> Right []
    GeneratedImplementation -> fmap (pure . ("outputs=" <>) . T.intercalate ",") outputSegments
    HoleImplementation -> fmap (pure . ("outputs=" <>) . T.intercalate ",") outputSegments
  pure
    ( T.intercalate
        "|"
        ( [ "transition:" <> renderMode (tMode transition),
            tSource transition,
            tCommand transition
          ]
            ++ implementationSegment
            ++ [ "guard=" <> maybe "" canonicalExpr (tGuard transition),
                 "writes=" <> T.intercalate ";" (map renderWrite (tWrites transition)),
                 "emits=" <> T.intercalate "," (tEmits transition)
               ]
            ++ outputOwnershipSegment
            ++ ["goto=" <> tGoto transition]
        )
    )
  where
    renderWrite (registerName, expression) = registerName <> ":=" <> canonicalExpr expression
    outputSegments = traverse (uncurry outputSegment) (zip [1 ..] (tEmits transition))
    outputSegment emitIndex eventName = do
      mapping <-
        mapLeft
          (FoldEventOutputResolutionFailed (aggName aggregate) (tCommand transition) eventName . showText)
          (eventOutputMapping spec aggregate transition emitIndex eventName)
      pure (eventName <> "=" <> eventOutputCanonical mapping)
    implementationSegment = case tImplementation transition of
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
    [ "rule:" <> ruleName rule,
      ruleDomain rule,
      ruleCodomain rule,
      "cases=" <> T.intercalate ";" (map renderCase (ruleCases rule))
    ]
  where
    renderCase (constructorName, expression) = constructorName <> "=>" <> canonicalExpr expression

referencedRuleNames :: Spec -> Aggregate -> Set Name
referencedRuleNames spec aggregate = close directNames
  where
    rules = specRules spec
    directNames =
      Set.unions
        [ exprNames expression
        | transition <- aggTransitions aggregate,
          expression <- maybeToList (tGuard transition) ++ map snd (tWrites transition)
        ]
    close names =
      let expanded =
            Set.unions
              ( names
                  : [ Set.unions (map (exprNames . snd) (ruleCases rule))
                    | name <- Set.toList names,
                      Just rule <- [find ((== name) . ruleName) rules]
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
