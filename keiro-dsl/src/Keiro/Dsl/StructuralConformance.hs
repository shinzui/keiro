-- | Generate the single context-owned conformance module for mapped
-- declarations. Declaration laws live here so aggregate harnesses need only
-- import evidence for declarations in their checked semantic closure.
module Keiro.Dsl.StructuralConformance
  ( StructuralConformanceFailure (..),
    structuralConformanceModuleName,
    hasStructuralConformance,
    structuralConformanceModule,
  )
where

import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar (HaskellSource (..), Name, Spec (..), WireEnum (..))
import Keiro.Dsl.HaskellImport
import Keiro.Dsl.Scaffold
  ( Context (..),
    ModuleKind (Generated),
    Placement (..),
    ScaffoldModule (..),
    StructuralProjection (..),
    generatedBanner,
    lowerFirst,
    pascalFromKebab,
    projectionSpecs,
    resolveProjectionModules,
  )
import Keiro.Dsl.SemanticContract (CheckedService, checkedSpec, checkedTypeGraph)
import Keiro.Dsl.SemanticImpact (semanticImpact, serviceMappedInventory)
import Keiro.Dsl.TypeGraph

-- | An inconsistency between a checked service and the resolved inventory used
-- to render its structural evidence. Source-authored mapping errors are normal
-- checker diagnostics and never use this type.
data StructuralConformanceFailure
  = StructuralConformanceGraphFailure !Text
  | StructuralConformanceInventoryMissing !MappedKey
  deriving stock (Eq, Show)

-- | The stable context-level module imported once by the service facade.
structuralConformanceModuleName :: Context -> Text
structuralConformanceModuleName ctx = contextStructuralPrefix ctx <> ".StructuralConformance"

-- | Whether the checked service owns any mapped declaration evidence.
hasStructuralConformance :: CheckedService -> Bool
hasStructuralConformance service = case checkedTypeGraph service of
  Left _ -> False
  Right graph -> not (null (serviceMappedInventory (semanticImpact graph)))

-- | Emit no module for an empty mapped inventory and exactly one generated
-- module otherwise.
structuralConformanceModule :: Context -> CheckedService -> Either [StructuralConformanceFailure] (Maybe ScaffoldModule)
structuralConformanceModule ctx service = do
  graph <- case checkedTypeGraph service of
    Left failures -> Left [StructuralConformanceGraphFailure (T.pack (show failures))]
    Right resolved -> Right resolved
  let inventory = serviceMappedInventory (semanticImpact graph)
      missing = [key | key <- inventory, Map.notMember key ((.declarations) graph)]
  case missing of
    key : keys -> Left (map StructuralConformanceInventoryMissing (key : keys))
    [] -> case inventory of
      [] -> Right Nothing
      _ ->
        let rendering = conformanceRendering ctx graph inventory
            moduleName = structuralConformanceModuleName ctx
         in Right . Just $
              ScaffoldModule
                { path = T.unpack (T.replace "." "/" moduleName <> ".hs"),
                  text = renderStructuralConformance rendering,
                  kind = Generated,
                  origin = "context " <> (.context) (checkedSpec service) <> " structural conformance"
                }

data ConformanceRendering = ConformanceRendering
  { context :: !Context,
    graph :: !TypeGraph,
    declarations :: ![ResolvedMappedDecl],
    projections :: ![StructuralProjection],
    importPlan :: !HaskellImportPlan
  }

conformanceRendering :: Context -> TypeGraph -> [MappedKey] -> ConformanceRendering
conformanceRendering ctx graph inventory = rendering
  where
    declarations = [declaration | key <- inventory, Just declaration <- [Map.lookup key ((.declarations) graph)]]
    projections = map (resolveProjectionModules ctx) (projectionSpecs graph)
    rendering =
      ConformanceRendering
        { context = ctx,
          graph = graph,
          declarations = declarations,
          projections = projections,
          importPlan = conformanceImportPlan ctx declarations projections
        }

renderStructuralConformance :: ConformanceRendering -> Text
renderStructuralConformance rendering =
  T.unlines $
    [ generatedBanner,
      "module " <> structuralConformanceModuleName ((.context) rendering),
      "  ( structuralConformanceAssertions",
      "  ) where",
      ""
    ]
      <> conformanceImports rendering
      <> [ "",
           "structuralConformanceAssertions :: [(String, Bool)]",
           "structuralConformanceAssertions =",
           "  concat",
           "    [ " <> T.intercalate "\n    , " assertionLists,
           "    ]",
           "",
           "validFixtureLabels :: NonEmpty.NonEmpty (T.Text, value) -> Bool",
           "validFixtureLabels cases =",
           "  all (not . T.null) labels && length labels == length (nub labels)",
           "  where",
           "    labels = map fst (NonEmpty.toList cases)"
         ]
      <> concatMap (bindingAssertionDecl rendering) structural
      <> concatMap (opaqueAssertionDecl rendering) opaque
      <> concatMap (coverageDecl rendering) structural
      <> projectionAssertionDecls rendering structural
  where
    structural = [(declaration, shape) | ResolvedStructural declaration shape <- (.declarations) rendering]
    opaque = [declaration | ResolvedOpaque declaration <- (.declarations) rendering]
    assertionLists =
      [lowerFirst ((.name) declaration) <> "BindingAssertions" | (declaration, _) <- structural]
        <> [lowerFirst ((.name) declaration) <> "OpaqueAssertions" | declaration <- opaque]
        <> [ "[(\"fixture coverage: "
               <> unCanonicalTypeId ((.canonical) declaration)
               <> "\", coverage"
               <> (.name) declaration
               <> ")]"
           | (declaration, _) <- structural
           ]
        <> ["structuralProjectionAssertions" | not (null ((.projections) rendering))]

conformanceImports :: ConformanceRendering -> [Text]
conformanceImports rendering =
  ["import Data.Aeson qualified as Aeson" | not (null opaque)]
    <> ["import Data.List (nub)", "import Data.List.NonEmpty qualified as NonEmpty"]
    <> ["import Data.Maybe (isJust, isNothing)" | any shapeUsesMaybe structural]
    <> ["import Data.Proxy (Proxy (..))" | not (null structural)]
    <> ["import Data.Text qualified as T"]
    <> ["import Keiki.Core (fieldWitnessAgrees)" | not (null projections)]
    <> ["import Keiki.Shape (CanonicalTypeName (..))" | not (null structural)]
    <> ["import Keiro.Codec.Structural (" <> T.intercalate ", " structuralCodecImports <> ")"]
    <> [ "import " <> structuralProjectionModuleName ((.context) rendering) <> " qualified as StructuralProjections"
       | not (null projections)
       ]
    <> fieldScopeImports
    <> T.lines (renderPlannedImports ((.importPlan) rendering))
  where
    declarations = (.declarations) rendering
    structural = [(declaration, shape) | ResolvedStructural declaration shape <- declarations]
    opaque = [declaration | ResolvedOpaque declaration <- declarations]
    projections = (.projections) rendering
    fieldScopeImports =
      [ "import " <> shapeModule <> " (" <> lastSegment shapeModule <> "Shape(" <> T.intercalate ", " (Set.toAscList selectors) <> "))"
      | (shapeModule, selectors) <- Map.toAscList selectorsByModule
      ]
    selectorsByModule =
      Map.fromListWith
        Set.union
        ( [ (structuralShapeModuleName ((.context) rendering) ((.name) declaration), Set.singleton ((.haskell) field))
          | (declaration, RRecord _ _ fields) <- structural,
            field <- fields,
            isOptional ((.valueType) field)
          ]
            <> [ (shapeModule, Set.singleton selector)
               | projection <- projections,
                 (shapeModule, selector) <- (.selectors) projection
               ]
        )
    structuralCodecImports =
      ["FixtureCases (..)"]
        <> if null structural then [] else ["bindingDomainRoundTrip", "bindingShapeRoundTrip", "bindingToShape"]
    shapeUsesMaybe (_, shape) = case shape of
      RRecord _ _ fields -> any (isOptional . (.valueType)) fields
      RUnion _ arms -> any (maybe False isOptional . (.payload)) arms
      REnum {} -> False
    isOptional ROptional {} = True
    isOptional _ = False

lastSegment :: Text -> Text
lastSegment = last . T.splitOn "."

conformanceImportPlan :: Context -> [ResolvedMappedDecl] -> [StructuralProjection] -> HaskellImportPlan
conformanceImportPlan ctx declarations _projections =
  either
    (error . ("validated structural conformance import planning failed: " <>) . show)
    id
    ( planHaskellImports
        ImportEnvironment
          { targetModule = structuralConformanceModuleName ctx,
            localNames = Set.fromList ["structuralConformanceAssertions", "validFixtureLabels"],
            reservedQualifiers = Set.fromList ["Aeson", "NonEmpty", "StructuralProjections", "T"]
          }
        references
    )
  where
    declarationReferences =
      Set.fromList
        [ reference
        | declaration <- declarations,
          reference <- case declaration of
            ResolvedStructural structural _ ->
              conformanceTypeReference ((.haskell) structural)
                : map conformanceQualifiedValueReference [(.binding) structural, (.fixtures) structural]
            ResolvedOpaque opaque -> [conformanceQualifiedValueReference ((.fixtures) opaque)]
        ]
    shapeReferences =
      Set.fromList
        [ reference
        | ResolvedStructural declaration shape <- declarations,
          reference <- structuralShapeReferences ctx declaration shape
        ]
    references = declarationReferences <> shapeReferences

conformanceTypeReference :: HaskellSource -> HaskellReference
conformanceTypeReference source =
  HaskellReference ((.moduleName) source) ((.valueType) source) TypeNamespace PreferUnqualified

conformanceQualifiedValueReference :: QualifiedValueName -> HaskellReference
conformanceQualifiedValueReference qualified =
  HaskellReference moduleName valueName ValueNamespace RequireQualified
  where
    (moduleName, valueName) = splitQualifiedValue (unQualifiedValueName qualified)

splitQualifiedValue :: Text -> (Text, Text)
splitQualifiedValue value =
  let (prefix, name) = T.breakOnEnd "." value
   in (T.dropEnd 1 prefix, name)

structuralShapeReferences :: Context -> StructuralDecl -> ResolvedMappedShape -> [HaskellReference]
structuralShapeReferences ctx declaration =
  foldMappedShape
    MappedShapeAlgebra
      { onRecord = \_constructor _ _fields -> [],
        onEnum = map (constructorRef . (.ctor)),
        onUnion = \_ -> map (constructorRef . (.ctor))
      }
  where
    moduleName = structuralShapeModuleName ctx ((.name) declaration)
    constructorRef constructor = HaskellReference moduleName constructor ConstructorNamespace RequireQualified

renderReference :: ConformanceRendering -> HaskellReference -> Text
renderReference rendering reference =
  either
    (error . ("validated structural conformance reference failed: " <>) . show)
    id
    (renderPlannedReference ((.importPlan) rendering) reference)

bindingAssertionDecl :: ConformanceRendering -> (StructuralDecl, ResolvedMappedShape) -> [Text]
bindingAssertionDecl rendering (declaration, _shape) =
  [ "",
    valueName <> " :: [(String, Bool)]",
    valueName <> " =",
    "  (\"fixture labels: " <> canonical <> "\", validFixtureLabels cases) :",
    "  (\"canonical identity: " <> canonical <> "\", canonicalTypeName (Proxy @" <> consumerType <> ") == " <> tshow canonical <> ") :",
    "  concat",
    "    [ [ (\"binding domain round-trip: " <> canonical <> "/\" <> T.unpack label, bindingDomainRoundTrip " <> binding <> " value)",
    "      , (\"binding shape round-trip: " <> canonical <> "/\" <> T.unpack label, bindingShapeRoundTrip " <> binding <> " (bindingToShape " <> binding <> " value))",
    "      ]",
    "    | (label, value) <- NonEmpty.toList cases",
    "    ]",
    "  where",
    "    cases = fixtureCases " <> fixtures
  ]
  where
    valueName = lowerFirst ((.name) declaration) <> "BindingAssertions"
    canonical = unCanonicalTypeId ((.canonical) declaration)
    consumerType = renderReference rendering (conformanceTypeReference ((.haskell) declaration))
    binding = renderReference rendering (conformanceQualifiedValueReference ((.binding) declaration))
    fixtures = renderReference rendering (conformanceQualifiedValueReference ((.fixtures) declaration))

opaqueAssertionDecl :: ConformanceRendering -> OpaqueDecl -> [Text]
opaqueAssertionDecl rendering declaration =
  [ "",
    valueName <> " :: [(String, Bool)]",
    valueName <> " =",
    "  (\"opaque boundary fixtures: " <> label <> "\", validFixtureLabels cases) :",
    "  [ (\"opaque codec round-trip: " <> label <> "/\" <> T.unpack caseLabel, case Aeson.fromJSON (Aeson.toJSON value) of Aeson.Success decoded -> decoded == value; Aeson.Error _ -> False)",
    "  | (caseLabel, value) <- NonEmpty.toList cases",
    "  ]",
    "  where",
    "    cases = fixtureCases " <> fixtures
  ]
  where
    valueName = lowerFirst ((.name) declaration) <> "OpaqueAssertions"
    label = unCodecIdentity ((.codecIdentity) declaration) <> "@" <> unCodecVersion ((.codecVersion) declaration)
    fixtures = renderReference rendering (conformanceQualifiedValueReference ((.fixtures) declaration))

coverageDecl :: ConformanceRendering -> (StructuralDecl, ResolvedMappedShape) -> [Text]
coverageDecl rendering (declaration, shape) =
  [ "",
    "coverage" <> (.name) declaration <> " :: Bool",
    "coverage" <> (.name) declaration <> " = " <> coverageExpression rendering declaration shape
  ]

coverageExpression :: ConformanceRendering -> StructuralDecl -> ResolvedMappedShape -> Text
coverageExpression rendering declaration shape = case obligations of
  [] -> "True"
  _ -> T.intercalate " && " obligations <> "\n  where\n    shapes = map (bindingToShape " <> binding <> " . snd) (NonEmpty.toList (fixtureCases " <> fixtures <> "))"
  where
    shapeModule = structuralShapeModuleName ((.context) rendering) ((.name) declaration)
    binding = renderReference rendering (conformanceQualifiedValueReference ((.binding) declaration))
    fixtures = renderReference rendering (conformanceQualifiedValueReference ((.fixtures) declaration))
    obligations = case shape of
      RRecord _ _ fields -> concatMap (recordFieldObligation rendering shapeModule) fields
      REnum entries ->
        [ "any (\\case " <> renderReference rendering (HaskellReference shapeModule ((.ctor) entry) ConstructorNamespace RequireQualified) <> " -> True; _ -> False) shapes"
        | entry <- entries
        ]
      RUnion _ arms -> concatMap (unionArmObligations rendering shapeModule) arms

recordFieldObligation :: ConformanceRendering -> Text -> ResolvedWireField -> [Text]
recordFieldObligation _rendering _shapeModule field = case (.valueType) field of
  ROptional _ ->
    [ "any (isNothing . " <> selector <> ") shapes",
      "any (isJust . " <> selector <> ") shapes"
    ]
  _ -> []
  where
    selector = "(." <> (.haskell) field <> ")"

unionArmObligations :: ConformanceRendering -> Text -> ResolvedWireArm -> [Text]
unionArmObligations rendering shapeModule arm =
  ["any (\\case " <> patternText <> " -> True; _ -> False) shapes"] <> optionalPayload
  where
    constructor = renderReference rendering (HaskellReference shapeModule ((.ctor) arm) ConstructorNamespace RequireQualified)
    patternText = constructor <> maybe "" (const "{}") ((.payload) arm)
    optionalPayload = case (.payload) arm of
      Just (ROptional _) ->
        [ "any (\\case " <> constructor <> " Nothing -> True; _ -> False) shapes",
          "any (\\case " <> constructor <> " (Just _) -> True; _ -> False) shapes"
        ]
      _ -> []

projectionAssertionDecls :: ConformanceRendering -> [(StructuralDecl, ResolvedMappedShape)] -> [Text]
projectionAssertionDecls rendering structural
  | null specs = []
  | otherwise =
      [ "",
        "structuralProjectionAssertions :: [(String, Bool)]",
        "structuralProjectionAssertions =",
        "  [ " <> T.intercalate "\n  , " (map assertion specs),
        "  ]"
      ]
  where
    specs = (.projections) rendering
    assertion spec =
      "(\"projection witness agreement: "
        <> unCanonicalTypeId ((.canonical) spec)
        <> (.pointer) spec
        <> "\", all (\\(_, owner) -> fieldWitnessAgrees StructuralProjections."
        <> (.witness) spec
        <> " (\\referenceOwner -> "
        <> projectionGetter rendering "referenceOwner" spec
        <> ") owner) (NonEmpty.toList (fixtureCases "
        <> ownerFixtures spec
        <> ")))"
    ownerFixtures spec = case find (\(declaration, _) -> (.canonical) declaration == (.canonical) spec) structural of
      Just (declaration, _) -> renderReference rendering (conformanceQualifiedValueReference ((.fixtures) declaration))
      Nothing -> "error \"projection owner fixtures missing\""

projectionGetter :: ConformanceRendering -> Text -> StructuralProjection -> Text
projectionGetter rendering owner spec =
  foldl
    ( \value (_shapeModule, selector) ->
        "("
          <> value
          <> ")."
          <> selector
    )
    ("bindingToShape " <> renderReference rendering (conformanceQualifiedValueReference ((.binding) spec)) <> " " <> owner)
    ((.selectors) spec)

structuralShapeModuleName :: Context -> Name -> Text
structuralShapeModuleName ctx name = case (.placement) ctx of
  GeneratedPrefix -> root <> "Generated." <> contextSegment <> ".Structural.Shape." <> name
  CollocatedLeaf -> root <> contextSegment <> ".Generated.Structural.Shape." <> name
  where
    root = if T.null ((.moduleRoot) ctx) then "" else (.moduleRoot) ctx <> "."
    contextSegment = pascalFromKebab ((.name) ctx)

structuralProjectionModuleName :: Context -> Text
structuralProjectionModuleName ctx = contextStructuralPrefix ctx <> ".StructuralProjections"

contextStructuralPrefix :: Context -> Text
contextStructuralPrefix ctx = case (.placement) ctx of
  GeneratedPrefix -> root <> "Generated." <> contextSegment
  CollocatedLeaf -> root <> contextSegment <> ".Generated"
  where
    root = if T.null ((.moduleRoot) ctx) then "" else (.moduleRoot) ctx <> "."
    contextSegment = pascalFromKebab ((.name) ctx)

tshow :: (Show value) => value -> Text
tshow = T.pack . show
