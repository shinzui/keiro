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
import Keiro.Dsl.SemanticContract (CheckedService (..))
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
hasStructuralConformance service = case resolveTypeGraph (checkedSpec service) of
  Left _ -> False
  Right graph -> not (null (serviceMappedInventory (semanticImpact graph)))

-- | Emit no module for an empty mapped inventory and exactly one generated
-- module otherwise.
structuralConformanceModule :: Context -> CheckedService -> Either [StructuralConformanceFailure] (Maybe ScaffoldModule)
structuralConformanceModule ctx service = do
  graph <- case resolveTypeGraph (checkedSpec service) of
    Left failures -> Left [StructuralConformanceGraphFailure (T.pack (show failures))]
    Right resolved -> Right resolved
  let inventory = serviceMappedInventory (semanticImpact graph)
      missing = [key | key <- inventory, Map.notMember key (tgDeclarations graph)]
  case missing of
    key : keys -> Left (map StructuralConformanceInventoryMissing (key : keys))
    [] -> case inventory of
      [] -> Right Nothing
      _ ->
        let rendering = conformanceRendering ctx graph inventory
            moduleName = structuralConformanceModuleName ctx
         in Right . Just $
              ScaffoldModule
                { modulePath = T.unpack (T.replace "." "/" moduleName <> ".hs"),
                  moduleText = renderStructuralConformance rendering,
                  kind = Generated,
                  origin = "context " <> specContext (checkedSpec service) <> " structural conformance"
                }

data ConformanceRendering = ConformanceRendering
  { renderingContext :: !Context,
    renderingGraph :: !TypeGraph,
    renderingDeclarations :: ![ResolvedMappedDecl],
    renderingProjections :: ![StructuralProjection],
    renderingImportPlan :: !HaskellImportPlan
  }

conformanceRendering :: Context -> TypeGraph -> [MappedKey] -> ConformanceRendering
conformanceRendering ctx graph inventory = rendering
  where
    declarations = [declaration | key <- inventory, Just declaration <- [Map.lookup key (tgDeclarations graph)]]
    projections = map (resolveProjectionModules ctx) (projectionSpecs graph)
    rendering =
      ConformanceRendering
        { renderingContext = ctx,
          renderingGraph = graph,
          renderingDeclarations = declarations,
          renderingProjections = projections,
          renderingImportPlan = conformanceImportPlan ctx declarations projections
        }

renderStructuralConformance :: ConformanceRendering -> Text
renderStructuralConformance rendering =
  T.unlines $
    [ generatedBanner,
      "module " <> structuralConformanceModuleName (renderingContext rendering),
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
    structural = [(declaration, shape) | ResolvedStructural declaration shape <- renderingDeclarations rendering]
    opaque = [declaration | ResolvedOpaque declaration <- renderingDeclarations rendering]
    assertionLists =
      [lowerFirst (sdName declaration) <> "BindingAssertions" | (declaration, _) <- structural]
        <> [lowerFirst (odName declaration) <> "OpaqueAssertions" | declaration <- opaque]
        <> [ "[(\"fixture coverage: "
               <> unCanonicalTypeId (sdCanonical declaration)
               <> "\", coverage"
               <> sdName declaration
               <> ")]"
           | (declaration, _) <- structural
           ]
        <> ["structuralProjectionAssertions" | not (null (renderingProjections rendering))]

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
    <> [ "import " <> structuralProjectionModuleName (renderingContext rendering) <> " qualified as StructuralProjections"
       | not (null projections)
       ]
    <> T.lines (renderPlannedImports (renderingImportPlan rendering))
  where
    declarations = renderingDeclarations rendering
    structural = [(declaration, shape) | ResolvedStructural declaration shape <- declarations]
    opaque = [declaration | ResolvedOpaque declaration <- declarations]
    projections = renderingProjections rendering
    structuralCodecImports =
      ["FixtureCases (..)"]
        <> if null structural then [] else ["bindingDomainRoundTrip", "bindingShapeRoundTrip", "bindingToShape"]
    shapeUsesMaybe (_, shape) = case shape of
      RRecord _ _ fields -> any (isOptional . rwfType) fields
      RUnion _ arms -> any (maybe False isOptional . rwaPayload) arms
      REnum {} -> False
    isOptional ROptional {} = True
    isOptional _ = False

conformanceImportPlan :: Context -> [ResolvedMappedDecl] -> [StructuralProjection] -> HaskellImportPlan
conformanceImportPlan ctx declarations projections =
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
              conformanceTypeReference (sdHaskell structural)
                : map conformanceQualifiedValueReference [sdBinding structural, sdFixtures structural]
            ResolvedOpaque opaque -> [conformanceQualifiedValueReference (odFixtures opaque)]
        ]
    shapeReferences =
      Set.fromList
        [ reference
        | ResolvedStructural declaration shape <- declarations,
          reference <- structuralShapeReferences ctx declaration shape
        ]
    projectionReferences =
      Set.fromList
        [ HaskellReference shapeModule selector ValueNamespace RequireQualified
        | projection <- projections,
          (shapeModule, selector) <- spSelectors projection
        ]
    references = declarationReferences <> shapeReferences <> projectionReferences

conformanceTypeReference :: HaskellSource -> HaskellReference
conformanceTypeReference source =
  HaskellReference (hsModule source) (hsType source) TypeNamespace PreferUnqualified

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
      { onRecord = \constructor _ fields -> constructorRef constructor : map (valueRef . rwfHaskell) fields,
        onEnum = map (constructorRef . weCtor),
        onUnion = \_ -> map (constructorRef . rwaCtor)
      }
  where
    moduleName = structuralShapeModuleName ctx (sdName declaration)
    constructorRef constructor = HaskellReference moduleName constructor ConstructorNamespace RequireQualified
    valueRef value = HaskellReference moduleName value ValueNamespace RequireQualified

renderReference :: ConformanceRendering -> HaskellReference -> Text
renderReference rendering reference =
  either
    (error . ("validated structural conformance reference failed: " <>) . show)
    id
    (renderPlannedReference (renderingImportPlan rendering) reference)

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
    valueName = lowerFirst (sdName declaration) <> "BindingAssertions"
    canonical = unCanonicalTypeId (sdCanonical declaration)
    consumerType = renderReference rendering (conformanceTypeReference (sdHaskell declaration))
    binding = renderReference rendering (conformanceQualifiedValueReference (sdBinding declaration))
    fixtures = renderReference rendering (conformanceQualifiedValueReference (sdFixtures declaration))

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
    valueName = lowerFirst (odName declaration) <> "OpaqueAssertions"
    label = unCodecIdentity (odCodecIdentity declaration) <> "@" <> unCodecVersion (odCodecVersion declaration)
    fixtures = renderReference rendering (conformanceQualifiedValueReference (odFixtures declaration))

coverageDecl :: ConformanceRendering -> (StructuralDecl, ResolvedMappedShape) -> [Text]
coverageDecl rendering (declaration, shape) =
  [ "",
    "coverage" <> sdName declaration <> " :: Bool",
    "coverage" <> sdName declaration <> " = " <> coverageExpression rendering declaration shape
  ]

coverageExpression :: ConformanceRendering -> StructuralDecl -> ResolvedMappedShape -> Text
coverageExpression rendering declaration shape = case obligations of
  [] -> "True"
  _ -> T.intercalate " && " obligations <> "\n  where\n    shapes = map (bindingToShape " <> binding <> " . snd) (NonEmpty.toList (fixtureCases " <> fixtures <> "))"
  where
    shapeModule = structuralShapeModuleName (renderingContext rendering) (sdName declaration)
    binding = renderReference rendering (conformanceQualifiedValueReference (sdBinding declaration))
    fixtures = renderReference rendering (conformanceQualifiedValueReference (sdFixtures declaration))
    obligations = case shape of
      RRecord _ _ fields -> concatMap (recordFieldObligation rendering shapeModule) fields
      REnum entries ->
        [ "any (\\case " <> renderReference rendering (HaskellReference shapeModule (weCtor entry) ConstructorNamespace RequireQualified) <> " -> True; _ -> False) shapes"
        | entry <- entries
        ]
      RUnion _ arms -> concatMap (unionArmObligations rendering shapeModule) arms

recordFieldObligation :: ConformanceRendering -> Text -> ResolvedWireField -> [Text]
recordFieldObligation rendering shapeModule field = case rwfType field of
  ROptional _ ->
    [ "any (isNothing . " <> selector <> ") shapes",
      "any (isJust . " <> selector <> ") shapes"
    ]
  _ -> []
  where
    selector = renderReference rendering (HaskellReference shapeModule (rwfHaskell field) ValueNamespace RequireQualified)

unionArmObligations :: ConformanceRendering -> Text -> ResolvedWireArm -> [Text]
unionArmObligations rendering shapeModule arm =
  ["any (\\case " <> patternText <> " -> True; _ -> False) shapes"] <> optionalPayload
  where
    constructor = renderReference rendering (HaskellReference shapeModule (rwaCtor arm) ConstructorNamespace RequireQualified)
    patternText = constructor <> maybe "" (const "{}") (rwaPayload arm)
    optionalPayload = case rwaPayload arm of
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
    specs = renderingProjections rendering
    assertion spec =
      "(\"projection witness agreement: "
        <> unCanonicalTypeId (spCanonical spec)
        <> spPointer spec
        <> "\", all (\\(_, owner) -> fieldWitnessAgrees StructuralProjections."
        <> spWitness spec
        <> " (\\referenceOwner -> "
        <> projectionGetter rendering "referenceOwner" spec
        <> ") owner) (NonEmpty.toList (fixtureCases "
        <> ownerFixtures spec
        <> ")))"
    ownerFixtures spec = case find (\(declaration, _) -> sdCanonical declaration == spCanonical spec) structural of
      Just (declaration, _) -> renderReference rendering (conformanceQualifiedValueReference (sdFixtures declaration))
      Nothing -> "error \"projection owner fixtures missing\""

projectionGetter :: ConformanceRendering -> Text -> StructuralProjection -> Text
projectionGetter rendering owner spec =
  foldl
    ( \value (shapeModule, selector) ->
        renderReference rendering (HaskellReference shapeModule selector ValueNamespace RequireQualified)
          <> " ("
          <> value
          <> ")"
    )
    ("bindingToShape " <> renderReference rendering (conformanceQualifiedValueReference (spBinding spec)) <> " " <> owner)
    (spSelectors spec)

structuralShapeModuleName :: Context -> Name -> Text
structuralShapeModuleName ctx name = case placement ctx of
  GeneratedPrefix -> root <> "Generated." <> contextSegment <> ".Structural.Shape." <> name
  CollocatedLeaf -> root <> contextSegment <> ".Generated.Structural.Shape." <> name
  where
    root = if T.null (moduleRoot ctx) then "" else moduleRoot ctx <> "."
    contextSegment = pascalFromKebab (contextName ctx)

structuralProjectionModuleName :: Context -> Text
structuralProjectionModuleName ctx = contextStructuralPrefix ctx <> ".StructuralProjections"

contextStructuralPrefix :: Context -> Text
contextStructuralPrefix ctx = case placement ctx of
  GeneratedPrefix -> root <> "Generated." <> contextSegment
  CollocatedLeaf -> root <> contextSegment <> ".Generated"
  where
    root = if T.null (moduleRoot ctx) then "" else moduleRoot ctx <> "."
    contextSegment = pascalFromKebab (contextName ctx)

tshow :: (Show value) => value -> Text
tshow = T.pack . show
