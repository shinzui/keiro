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
    generatedNominalModule,
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
  Right graph ->
    not (null (serviceMappedInventory (semanticImpact graph)))
      || not (null (conformanceNominalLeaves graph))

-- | Emit no module for an empty mapped inventory and exactly one generated
-- module otherwise.
structuralConformanceModule :: Context -> CheckedService -> Either [StructuralConformanceFailure] (Maybe ScaffoldModule)
structuralConformanceModule ctx service = do
  graph <- case checkedTypeGraph service of
    Left failures -> Left [StructuralConformanceGraphFailure (T.pack (show failures))]
    Right resolved -> Right resolved
  let inventory = serviceMappedInventory (semanticImpact graph)
      nominalLeaves = conformanceNominalLeaves graph
      missing = [key | key <- inventory, Map.notMember key ((.declarations) graph)]
  case missing of
    key : keys -> Left (map StructuralConformanceInventoryMissing (key : keys))
    [] -> case (inventory, nominalLeaves) of
      ([], []) -> Right Nothing
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
    nominals :: ![NominalLeaf],
    projections :: ![StructuralProjection],
    importPlan :: !HaskellImportPlan
  }

conformanceRendering :: Context -> TypeGraph -> [MappedKey] -> ConformanceRendering
conformanceRendering ctx graph inventory = rendering
  where
    declarations = [declaration | key <- inventory, Just declaration <- [Map.lookup key ((.declarations) graph)]]
    nominals = conformanceNominalLeaves graph
    projections = map (resolveProjectionModules ctx) (projectionSpecs graph)
    rendering =
      ConformanceRendering
        { context = ctx,
          graph = graph,
          declarations = declarations,
          nominals = nominals,
          projections = projections,
          importPlan = conformanceImportPlan ctx graph declarations nominals projections
        }

conformanceNominalLeaves :: TypeGraph -> [NominalLeaf]
conformanceNominalLeaves graph =
  [ leaf
  | name <- Set.toAscList names,
    Just leaf <- [Map.lookup name ((.nominalLeaves) graph)]
  ]
  where
    names =
      Set.unions (Map.elems ((.nominalReachability) graph))
        <> Set.fromList
          [ (.nominal) site
          | site <- (.nominalRootSites) graph,
            case (.root) site of
              RootWorkqueueField {} -> True
              RootReadModelQueryInput {} -> True
              RootReadModelQueryResult {} -> True
              RootContractField {} -> True
              RootCommandField {} -> False
              RootEventField {} -> False
              RootRegister {} -> False
          ]

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
           "structuralConformanceAssertions ="
         ]
      <> case assertionLists of
        [] -> ["  []"]
        _ ->
          [ "  concat",
            "    [ " <> T.intercalate "\n    , " assertionLists,
            "    ]"
          ]
      <> ( if not (null structural) || not (null opaque)
             then
               [ "",
                 "validFixtureLabels :: NonEmpty.NonEmpty (T.Text, value) -> Bool",
                 "validFixtureLabels cases =",
                 "  all (not . T.null) labels && length labels == length (nub labels)",
                 "  where",
                 "    labels = map fst (NonEmpty.toList cases)"
               ]
             else []
         )
      <> concatMap (bindingAssertionDecl rendering) structural
      <> concatMap (nominalAssertionDecl rendering) consumerNominals
      <> concatMap (opaqueAssertionDecl rendering) opaque
      <> concatMap (coverageDecl rendering) structural
      <> projectionAssertionDecls rendering structural
  where
    structural = [(declaration, shape) | ResolvedStructural declaration shape <- (.declarations) rendering]
    opaque = [declaration | ResolvedOpaque declaration <- (.declarations) rendering]
    consumerNominals = [leaf | leaf@NominalLeaf {ownership = ConsumerLeaf {}} <- (.nominals) rendering]
    generatedIdAssertions = structuralGeneratedIdAssertions rendering structural
    assertionLists =
      [lowerFirst ((.name) declaration) <> "BindingAssertions" | (declaration, _) <- structural]
        <> [lowerFirst ((.name) declaration) <> "OpaqueAssertions" | declaration <- opaque]
        <> [lowerFirst ((.name) leaf) <> "NominalAssertions" | leaf <- consumerNominals]
        <> map (generatedIdAssertionList rendering) generatedIdAssertions
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
  ["import Data.Aeson qualified as Aeson" | not (null opaque) || not (null generatedIdAssertions)]
    <> ["import Data.Aeson.Types qualified as AesonTypes" | not (null generatedIdAssertions)]
    <> ["import Data.List (nub)" | not (null structural) || not (null opaque)]
    <> ["import Data.List.NonEmpty qualified as NonEmpty" | not (null structural) || not (null opaque) || not (null consumerNominals)]
    <> ["import Data.Maybe (isJust, isNothing)" | any shapeUsesMaybe structural]
    <> ["import Data.Proxy (Proxy (..))" | not (null structural) || not (null consumerNominals)]
    <> ["import Data.Text qualified as T" | not (null structural) || not (null opaque)]
    <> ["import Keiki.Core (fieldWitnessAgrees)" | not (null projections)]
    <> ["import Keiki.Shape (CanonicalTypeName (..))" | not (null structural) || not (null consumerNominals)]
    <> ["import Keiro.Codec.Nominal (nominalDomainRoundTrip, nominalFixtureCases, nominalFixtureDomain, nominalRepresentationRoundTrip, nominalToRepresentation)" | not (null consumerNominals)]
    <> ["import Keiro.Codec.Structural (" <> T.intercalate ", " structuralCodecImports <> ")" | not (null structural) || not (null opaque)]
    <> [ "import " <> structuralProjectionModuleName ((.context) rendering) <> " qualified as StructuralProjections"
       | not (null projections)
       ]
    <> fieldScopeImports
    <> T.lines (renderPlannedImports ((.importPlan) rendering))
  where
    declarations = (.declarations) rendering
    structural = [(declaration, shape) | ResolvedStructural declaration shape <- declarations]
    opaque = [declaration | ResolvedOpaque declaration <- declarations]
    consumerNominals = [leaf | leaf@NominalLeaf {ownership = ConsumerLeaf {}} <- (.nominals) rendering]
    generatedIdAssertions = structuralGeneratedIdAssertions rendering structural
    projections = (.projections) rendering
    fieldScopeImports =
      [ "import " <> shapeModule <> " (" <> lastSegment shapeModule <> "Shape(" <> T.intercalate ", " (Set.toAscList selectors) <> "))"
      | (shapeModule, selectors) <- Map.toAscList selectorsByModule
      ]
    selectorsByModule =
      Map.fromListWith
        Set.union
        [ (structuralShapeModuleName ((.context) rendering) ((.name) declaration), Set.singleton ((.haskell) field))
        | (declaration, RRecord _ _ fields) <- structural,
          field <- fields,
          isOptional ((.valueType) field)
        ]
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

conformanceImportPlan :: Context -> TypeGraph -> [ResolvedMappedDecl] -> [NominalLeaf] -> [StructuralProjection] -> HaskellImportPlan
conformanceImportPlan ctx graph declarations nominals _projections =
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
    generatedShapeReferences =
      Set.fromList
        [ HaskellReference (structuralShapeModuleName ctx ((.name) declaration)) constructor ConstructorNamespace RequireQualified
        | ResolvedStructural declaration (RRecord constructor _ _) <- declarations,
          not . Set.null $
            Set.intersection
              generatedIdNames
              (Map.findWithDefault Set.empty (MappedKey ((.name) declaration)) ((.nominalReachability) graph))
        ]
    nominalReferences =
      Set.fromList
        [ reference
        | NominalLeaf {ownership = ConsumerLeaf binding} <- nominals,
          reference <-
            conformanceTypeReference ((.haskell) binding)
              : map conformanceQualifiedValueReference [(.binding) binding, (.fixtures) binding]
        ]
    generatedNominalReferences =
      Set.fromList
        [ reference
        | leaf@NominalLeaf {kind = NominalIdLeaf {}, ownership = GeneratedLeaf} <- nominals,
          Set.member ((.name) leaf) structuralNominalNames,
          occurrence <- ["encode" <> (.name) leaf <> "Leaf", "parse" <> (.name) leaf <> "Leaf"],
          let reference = HaskellReference (contextStructuralPrefix ctx <> ".Structural.NominalLeaves") occurrence ValueNamespace RequireQualified
        ]
        <> Set.fromList
          [ HaskellReference (generatedNominalModule ctx) (lowerFirst ((.name) leaf) <> "Text") ValueNamespace RequireQualified
          | leaf@NominalLeaf {kind = NominalIdLeaf {}, ownership = GeneratedLeaf} <- nominals,
            Set.member ((.name) leaf) structuralNominalNames
          ]
    structuralNominalNames =
      Set.unions
        [ Map.findWithDefault Set.empty (MappedKey ((.name) declaration)) ((.nominalReachability) graph)
        | ResolvedStructural declaration _ <- declarations
        ]
    generatedIdNames =
      Set.fromList
        [ (.name) leaf
        | leaf@NominalLeaf {kind = NominalIdLeaf {}, ownership = GeneratedLeaf} <- nominals
        ]
    references = declarationReferences <> shapeReferences <> generatedShapeReferences <> nominalReferences <> generatedNominalReferences

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

nominalAssertionDecl :: ConformanceRendering -> NominalLeaf -> [Text]
nominalAssertionDecl rendering leaf = case (.ownership) leaf of
  GeneratedLeaf -> []
  ConsumerLeaf binding ->
    [ "",
      valueName <> " :: [(String, Bool)]",
      valueName <> " =",
      "  [ (\"nominal domain law: " <> name <> "\", all (nominalDomainRoundTrip " <> bindingName <> " . nominalFixtureDomain) cases)",
      "  , (\"nominal representation law: " <> name <> "\", all (\\fixture -> let domainValue = nominalFixtureDomain fixture in nominalRepresentationRoundTrip " <> bindingName <> " (nominalToRepresentation " <> bindingName <> " domainValue)) cases)",
      "  , (\"nominal canonical identity: " <> name <> "\", canonicalTypeName (Proxy @" <> consumerType <> ") == " <> tshow canonical <> ")",
      "  ]",
      "  where",
      "    cases = NonEmpty.toList (nominalFixtureCases " <> fixtures <> ")"
    ]
    where
      name = (.name) leaf
      valueName = lowerFirst name <> "NominalAssertions"
      consumerType = renderReference rendering (conformanceTypeReference ((.haskell) binding))
      bindingName = renderReference rendering (conformanceQualifiedValueReference ((.binding) binding))
      fixtures = renderReference rendering (conformanceQualifiedValueReference ((.fixtures) binding))
      canonical = unCanonicalTypeId ((.canonical) binding)

structuralGeneratedIdAssertions :: ConformanceRendering -> [(StructuralDecl, ResolvedMappedShape)] -> [(StructuralDecl, ResolvedMappedShape, NominalLeaf)]
structuralGeneratedIdAssertions rendering structural =
  [ (declaration, shape, leaf)
  | (declaration, shape) <- structural,
    nominalName <- Set.toAscList (Map.findWithDefault Set.empty (MappedKey ((.name) declaration)) ((.nominalReachability) ((.graph) rendering))),
    Just leaf@NominalLeaf {kind = NominalIdLeaf {}, ownership = GeneratedLeaf} <- [Map.lookup nominalName ((.nominalLeaves) ((.graph) rendering))]
  ]

generatedIdAssertionList :: ConformanceRendering -> (StructuralDecl, ResolvedMappedShape, NominalLeaf) -> Text
generatedIdAssertionList rendering (declaration, shape, leaf) =
  "[(\"generated nominal canonical text: "
    <> unCanonicalTypeId ((.canonical) declaration)
    <> "/"
    <> (.name) leaf
    <> "\", all (\\(_, value) -> "
    <> generatedIdShapeExpression rendering leaf declaration shape ("bindingToShape " <> binding <> " value") 0
    <> ") (NonEmpty.toList (fixtureCases "
    <> fixtures
    <> ")))]"
  where
    binding = renderReference rendering (conformanceQualifiedValueReference ((.binding) declaration))
    fixtures = renderReference rendering (conformanceQualifiedValueReference ((.fixtures) declaration))

generatedIdShapeExpression :: ConformanceRendering -> NominalLeaf -> StructuralDecl -> ResolvedMappedShape -> Text -> Int -> Text
generatedIdShapeExpression rendering target declaration shape candidate depth = case shape of
  RRecord constructor _ fields ->
    "(case "
      <> candidate
      <> " of "
      <> shapeConstructor rendering ((.name) declaration) constructor
      <> (if null variables then "" else " " <> T.unwords variables)
      <> " -> "
      <> conjunction
        [ generatedIdTypeExpression rendering target ((.valueType) field) variable (depth + 1)
        | (field, variable) <- zip fields variables,
          nominalOccursIn rendering target ((.valueType) field)
        ]
      <> ")"
    where
      variables =
        [ if nominalOccursIn rendering target ((.valueType) field)
            then "field" <> tshow depth <> "_" <> tshow index
            else "_"
        | (index, field) <- zip [0 :: Int ..] fields
        ]
  REnum _ -> "True"
  RUnion _ arms ->
    "(case " <> candidate <> " of " <> T.intercalate "; " (map renderArm arms) <> ")"
    where
      renderArm arm =
        shapeConstructor rendering ((.name) declaration) ((.ctor) arm)
          <> case (.payload) arm of
            Nothing -> " -> True"
            Just payload
              | nominalOccursIn rendering target payload ->
                  " payload" <> tshow depth <> " -> " <> generatedIdTypeExpression rendering target payload ("payload" <> tshow depth) (depth + 1)
              | otherwise -> " _ -> True"

generatedIdTypeExpression :: ConformanceRendering -> NominalLeaf -> ResolvedTypeExpr -> Text -> Int -> Text
generatedIdTypeExpression rendering target expression candidate depth = case expression of
  ROptional item -> "maybe True (\\item" <> tshow depth <> " -> " <> generatedIdTypeExpression rendering target item ("item" <> tshow depth) (depth + 1) <> ") " <> parenthesize candidate
  RList item -> "all (\\item" <> tshow depth <> " -> " <> generatedIdTypeExpression rendering target item ("item" <> tshow depth) (depth + 1) <> ") " <> parenthesize candidate
  RMap item -> "all (\\item" <> tshow depth <> " -> " <> generatedIdTypeExpression rendering target item ("item" <> tshow depth) (depth + 1) <> ") " <> parenthesize candidate
  RRef key -> case Map.lookup key ((.declarations) ((.graph) rendering)) of
    Just (ResolvedStructural declaration shape) -> generatedIdShapeExpression rendering target declaration shape candidate depth
    _ -> "True"
  RNominal leaf
    | (.name) leaf == (.name) target ->
        let encoded = nominalHelper rendering "encode" target <> " " <> parenthesize candidate
         in "("
              <> encoded
              <> " == Aeson.String ("
              <> generatedNominalText rendering target
              <> " "
              <> parenthesize candidate
              <> ") && AesonTypes.parseEither "
              <> nominalHelper rendering "parse" target
              <> " ("
              <> encoded
              <> ") == Right "
              <> parenthesize candidate
              <> ")"
  _ -> "True"

nominalOccursIn :: ConformanceRendering -> NominalLeaf -> ResolvedTypeExpr -> Bool
nominalOccursIn rendering target = \case
  ROptional item -> nominalOccursIn rendering target item
  RList item -> nominalOccursIn rendering target item
  RMap item -> nominalOccursIn rendering target item
  RRef key -> Set.member ((.name) target) (Map.findWithDefault Set.empty key ((.nominalReachability) ((.graph) rendering)))
  RNominal leaf -> (.name) leaf == (.name) target
  _ -> False

shapeConstructor :: ConformanceRendering -> Name -> Name -> Text
shapeConstructor rendering declarationName constructor =
  renderReference
    rendering
    (HaskellReference (structuralShapeModuleName ((.context) rendering) declarationName) constructor ConstructorNamespace RequireQualified)

nominalHelper :: ConformanceRendering -> Text -> NominalLeaf -> Text
nominalHelper rendering prefix leaf =
  renderReference
    rendering
    (HaskellReference (contextStructuralPrefix ((.context) rendering) <> ".Structural.NominalLeaves") (prefix <> (.name) leaf <> "Leaf") ValueNamespace RequireQualified)

generatedNominalText :: ConformanceRendering -> NominalLeaf -> Text
generatedNominalText rendering leaf =
  renderReference
    rendering
    (HaskellReference (generatedNominalModule ((.context) rendering)) (lowerFirst ((.name) leaf) <> "Text") ValueNamespace RequireQualified)

conjunction :: [Text] -> Text
conjunction [] = "True"
conjunction expressions = T.intercalate " && " (map parenthesize expressions)

parenthesize :: Text -> Text
parenthesize value = "(" <> value <> ")"

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
  -- A nominal enum's own NominalFixtureCases prove every representation arm.
  -- Requiring each enclosing structural fixture set to repeat those arms adds
  -- no new binding evidence and scales fixture burden with every embedding.
  RNominal NominalLeaf {kind = NominalEnumLeaf {}} -> []
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
projectionGetter _rendering owner spec =
  "StructuralProjections." <> (.getter) spec <> " " <> owner

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
