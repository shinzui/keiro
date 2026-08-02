-- | Canonical identities for the aggregate fold surface used while hydrating
-- event streams. The fingerprint deliberately excludes payload codecs,
-- projections, snapshot policy, and source locations: those inputs do not change
-- how an existing event log becomes aggregate state.
module Keiro.Dsl.FoldFingerprint
  ( aggregateFoldFingerprintForService,
    aggregateFoldSurfaceForService,
    aggregateFoldFingerprint,
    aggregateFoldSurface,
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
import Keiro.Dsl.EventOutput
import Keiro.Dsl.Expression
import Keiro.Dsl.Grammar
import Keiro.Dsl.NominalType
import Keiro.Dsl.PrettyPrint (renderExpr)
import Keiro.Dsl.ReadModelShape (fnv1a64)
import Keiro.Dsl.SemanticContract (CheckedService (..), EffectiveLanguageContract, legacyCheckedService, runtimeSemanticsFingerprintSegments)
import Keiro.Dsl.TypeGraph

-- | The sixteen-hex-digit identity of an aggregate's replay fold under the
-- service's effective runtime semantics.
aggregateFoldFingerprintForService :: CheckedService -> Aggregate -> Text
aggregateFoldFingerprintForService service = fnv1a64 . aggregateFoldSurfaceForService service

-- | The sixteen-hex-digit identity of an aggregate's replay fold.
-- This compatibility wrapper selects legacy/version-1 runtime semantics.
aggregateFoldFingerprint :: Spec -> Aggregate -> Text
aggregateFoldFingerprint spec = aggregateFoldFingerprintForService (legacyCheckedService spec)

-- | Canonical pre-hash text for an aggregate's replay fold.
--
-- Rules are declarations on 'Spec', not children of 'Aggregate', so the complete
-- spec is required. Only rules reached from transition guards and writes are
-- included, transitively, in declaration order.
aggregateFoldSurface :: Spec -> Aggregate -> Text
aggregateFoldSurface spec = aggregateFoldSurfaceForService (legacyCheckedService spec)

-- | Canonical pre-hash text under a checked semantic contract. A runtime
-- discriminator is included only for a contract that can change fold behavior;
-- source declaration provenance and grammar-only versions never enter it.
aggregateFoldSurfaceForService :: CheckedService -> Aggregate -> Text
aggregateFoldSurfaceForService service aggregate =
  T.intercalate
    "\n"
    ( runtimeSemanticsFingerprintSegments (checkedLanguageContract service)
        ++ map stateSegment (aggStates aggregate)
        ++ map (registerSegment symbols) (aggRegs aggregate)
        ++ mappedRegisterSegments
        ++ nominalSegments
        ++ nominalEqualitySegments
        ++ map (transitionSegment spec aggregate) (aggTransitions aggregate)
        ++ map ruleSegment referencedRules
    )
  where
    spec = checkedSpec service
    symbols = aggregateSymbols spec
    referencedRules =
      [ rule
      | rule <- specRules spec,
        ruleName rule `Set.member` referencedRuleNames spec aggregate
      ]
    mappedRegisterSegments = case resolveTypeGraph spec of
      Left _ -> []
      Right graph ->
        [ mappedRegisterSegment graph declaration
        | register <- aggRegs aggregate,
          TRef typeName <- [regType register],
          Just declaration <- [Map.lookup (MappedKey typeName) (tgDeclarations graph)]
        ]
    nominalSegments = case resolveNominalTypes spec of
      Left _ -> []
      Right registry ->
        [ nominalUseSegment useSite nominal binding
        | (useSite, typeName) <- nominalUseNames aggregate,
          Just nominal <- [lookupNominalType typeName registry],
          ConsumerNominal binding <- [resolvedNominalOwnership nominal]
        ]
    nominalEqualitySegments =
      [ "nominal-equality-use:" <> identity
      | identity <- Set.toAscList (nominalEqualityUses service aggregate)
      ]

-- | Equality representation belongs in the fold identity only when a guard
-- actually compares that declaration. This keeps unrelated binding metadata out
-- of replay compatibility while ensuring a witness/domain change cannot silently
-- retain the old fold fingerprint.
nominalEqualityUses :: CheckedService -> Aggregate -> Set Text
nominalEqualityUses service aggregate =
  Set.fromList
    [ identity
    | transition <- aggTransitions aggregate,
      guardSyntax <- maybeToList (tGuard transition),
      Right guardExpression <- [resolveGuardExpr (expressionEnvironment spec aggregate transition) guardSyntax],
      identity <- equalityIdentities (checkedLanguageContract service) guardExpression
    ]
  where
    spec = checkedSpec service

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

registerSegment :: AggregateSymbols -> RegDecl -> Text
registerSegment symbols register =
  "reg:"
    <> regName register
    <> ":"
    <> typeExprCanonicalName (regType register)
    <> "="
    <> canonicalInitial
  where
    canonicalInitial = case resolveAggregateType symbols (regLoc register) RegisterUse (regType register) of
      Left _ -> renderInitial (regInitial register)
      Right resolvedType -> case resolveRegisterInitial symbols (regLoc register) resolvedType (regInitial register) of
        Left _ -> renderInitial (regInitial register)
        Right resolvedInitial -> registerInitialCanonicalName resolvedInitial

renderInitial :: RegInitial -> Text
renderInitial (RegInitBare value) = value
renderInitial (RegInitText value) = "\"" <> escapeText value <> "\""

escapeText :: Text -> Text
escapeText = T.concatMap $ \case
  '"' -> "\\\""
  '\\' -> "\\\\"
  '\n' -> "\\n"
  '\t' -> "\\t"
  '\r' -> "\\r"
  character -> T.singleton character

transitionSegment :: Spec -> Aggregate -> Transition -> Text
transitionSegment spec aggregate transition =
  T.intercalate
    "|"
    ( [ "transition:" <> renderMode (tMode transition),
        tSource transition,
        tCommand transition
      ]
        ++ implementationSegment
        ++ [ "guard=" <> maybe "" renderExpr (tGuard transition),
             "writes=" <> T.intercalate ";" (map renderWrite (tWrites transition)),
             "emits=" <> T.intercalate "," (tEmits transition)
           ]
        ++ outputOwnershipSegment
        ++ ["goto=" <> tGoto transition]
    )
  where
    renderWrite (registerName, expression) = registerName <> ":=" <> renderExpr expression
    outputSegment emitIndex eventName = case eventOutputMapping spec aggregate transition emitIndex eventName of
      Right mapping -> eventName <> "=" <> eventOutputCanonical mapping
      Left problem -> eventName <> "=invalid:" <> T.pack (show problem)
    outputOwnershipSegment = case tImplementation transition of
      LegacyHoleImplementation -> []
      GeneratedImplementation -> ["outputs=" <> T.intercalate "," [outputSegment emitIndex eventName | (emitIndex, eventName) <- zip [1 ..] (tEmits transition)]]
      HoleImplementation -> ["outputs=" <> T.intercalate "," [outputSegment emitIndex eventName | (emitIndex, eventName) <- zip [1 ..] (tEmits transition)]]
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
    renderCase (constructorName, expression) = constructorName <> "=>" <> renderExpr expression

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
