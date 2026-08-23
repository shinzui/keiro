{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Consumer-owned Haskell obligations implied by checked structural mapped
-- declarations. The same values drive create-once skeletons, scaffold-record
-- diffs, and the @check --explain-bindings@ report.
module Keiro.Dsl.ExplainBindings
  ( BindingResolutionError (..),
    BindingObligationKind (..),
    BindingObligation (..),
    BindingHole (..),
    bindingObligations,
    bindingObligationsForService,
    bindingHoles,
    bindingHolesForService,
    renderBindingObligations,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import Data.Bifunctor (first)
import Data.List (groupBy, sortOn)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar
import Keiro.Dsl.HaskellName qualified as HaskellName
import Keiro.Dsl.IdDomain (idDomainContractFor, idDomainVersion)
import Keiro.Dsl.NominalType
import Keiro.Dsl.SemanticContract (CheckedService, checkedLanguageContract, checkedSpec, checkedTypeGraph, legacyCheckedService)
import Keiro.Dsl.TypeGraph

data BindingResolutionError
  = BindingTypeGraphError !TypeGraphError
  | BindingNominalTypeError !NominalTypeError
  deriving stock (Eq, Show)

data BindingObligationKind
  = BindingValue
  | FixtureValue
  | InitialValue
  deriving stock (Eq, Ord, Show)

data BindingObligation = BindingObligation
  { mappedName :: !Name,
    package :: !Text,
    moduleName :: !Text,
    symbol :: !Text,
    kind :: !BindingObligationKind,
    signature :: !Text,
    useSites :: ![Text],
    bindingVersion :: !(Maybe Text),
    canonicalType :: !(Maybe Text),
    equalityContract :: !(Maybe Text),
    idDomainContract :: !(Maybe Text),
    category :: !Text
  }
  deriving stock (Eq, Ord, Show)

data BindingHole = BindingHole
  { mappedName :: !Name,
    moduleName :: !Text,
    symbol :: !Text,
    kind :: !BindingObligationKind,
    path :: !(Maybe Text),
    signature :: !Text
  }
  deriving stock (Eq, Ord, Show)

instance ToJSON BindingObligation where
  toJSON obligation =
    object
      [ "schema" .= (1 :: Int),
        "mappedName" .= (.mappedName) obligation,
        "package" .= (.package) obligation,
        "module" .= (.moduleName) obligation,
        "symbol" .= (.symbol) obligation,
        "kind" .= renderKind ((.kind) obligation),
        "signature" .= (.signature) obligation,
        "useSites" .= (.useSites) obligation,
        "bindingVersion" .= (.bindingVersion) obligation,
        "canonicalType" .= (.canonicalType) obligation,
        "equalityContract" .= (.equalityContract) obligation,
        "idDomainContract" .= (.idDomainContract) obligation,
        "category" .= (.category) obligation
      ]

instance FromJSON BindingObligation where
  parseJSON = withObject "keiro-dsl binding obligation" $ \value -> do
    schema <- value .: "schema"
    if schema /= (1 :: Int)
      then fail "unsupported binding obligation schema"
      else do
        kindText <- value .: "kind"
        kindValue <- maybe (fail "unknown binding obligation kind") pure (parseKind kindText)
        BindingObligation
          <$> value .: "mappedName"
          <*> value .: "package"
          <*> value .: "module"
          <*> value .: "symbol"
          <*> pure kindValue
          <*> value .: "signature"
          <*> value .: "useSites"
          <*> value .:? "bindingVersion"
          <*> value .:? "canonicalType"
          <*> value .:? "equalityContract"
          <*> value .:? "idDomainContract"
          <*> (value .:? "category" >>= pure . maybe "structural" id)

instance ToJSON BindingHole where
  toJSON hole =
    object
      [ "schema" .= (1 :: Int),
        "mappedName" .= (.mappedName) hole,
        "module" .= (.moduleName) hole,
        "symbol" .= (.symbol) hole,
        "kind" .= renderKind ((.kind) hole),
        "path" .= (.path) hole,
        "signature" .= (.signature) hole
      ]

instance FromJSON BindingHole where
  parseJSON = withObject "keiro-dsl binding hole" $ \value -> do
    schema <- value .: "schema"
    if schema /= (1 :: Int)
      then fail "unsupported binding hole schema"
      else do
        kindText <- value .: "kind"
        kindValue <- maybe (fail "unknown binding hole kind") pure (parseKind kindText)
        BindingHole
          <$> value .: "mappedName"
          <*> value .: "module"
          <*> value .: "symbol"
          <*> pure kindValue
          <*> value .:? "path"
          <*> value .: "signature"

bindingObligations :: Spec -> Either (NonEmpty BindingResolutionError) [BindingObligation]
bindingObligations = bindingObligationsForService . legacyCheckedService

bindingObligationsForService :: CheckedService -> Either (NonEmpty BindingResolutionError) [BindingObligation]
bindingObligationsForService service = do
  graph <- first (fmap BindingTypeGraphError) (checkedTypeGraph service)
  nominalRegistry <- first (fmap BindingNominalTypeError) (resolveNominalTypes spec)
  pure . sortOn obligationSortKey $
    concat
      [ obligationsFor graph declaration
      | ResolvedStructural declaration _ <- Map.elems ((.declarations) graph)
      ]
      <> concatMap (nominalObligationsFor service) (Map.elems ((.nominalTypes) nominalRegistry))
  where
    spec = checkedSpec service

bindingHoles :: Spec -> Either (NonEmpty BindingResolutionError) [BindingHole]
bindingHoles = bindingHolesForService . legacyCheckedService

bindingHolesForService :: CheckedService -> Either (NonEmpty BindingResolutionError) [BindingHole]
bindingHolesForService service = do
  graph <- first (fmap BindingTypeGraphError) (checkedTypeGraph service)
  obligations <- bindingObligationsForService service
  pure . sortOn holeSortKey $
    concat
      [ holesFor graph declaration shape obligations
      | ResolvedStructural declaration shape <- Map.elems ((.declarations) graph)
      ]
      <> [ BindingHole
             { mappedName = (.mappedName) obligation,
               moduleName = (.moduleName) obligation,
               symbol = (.symbol) obligation,
               kind = (.kind) obligation,
               path = Nothing,
               signature = (.signature) obligation
             }
         | obligation <- obligations,
           (.category) obligation /= "structural"
         ]

holesFor :: TypeGraph -> StructuralDecl -> ResolvedMappedShape -> [BindingObligation] -> [BindingHole]
holesFor _graph declaration shape obligations = bindingEntries <> auxiliaryEntries
  where
    own = filter ((== (.name) declaration) . (.mappedName)) obligations
    binding = onlyKind BindingValue
    bindingEntries = case binding of
      Nothing -> []
      Just obligation -> map (bindingHole obligation) (shapeHolePaths shape)
    auxiliaryEntries =
      [ BindingHole
          { mappedName = (.mappedName) obligation,
            moduleName = (.moduleName) obligation,
            symbol = (.symbol) obligation,
            kind = (.kind) obligation,
            path = Nothing,
            signature = (.signature) obligation
          }
      | obligation <- own,
        (.kind) obligation /= BindingValue
      ]
    onlyKind wanted = case filter ((== wanted) . (.kind)) own of
      entry : _ -> Just entry
      [] -> Nothing
    bindingHole obligation (path, expectedType) =
      BindingHole
        { mappedName = (.mappedName) obligation,
          moduleName = (.moduleName) obligation,
          symbol = (.symbol) obligation,
          kind = BindingValue,
          path = Just path,
          signature = (.symbol) obligation <> "." <> path <> " :: " <> expectedType
        }

shapeHolePaths :: ResolvedMappedShape -> [(Text, Text)]
shapeHolePaths =
  foldMappedShape
    MappedShapeAlgebra
      { onRecord = \_ _ fields -> [((.haskell) field, renderExprType ((.valueType) field)) | field <- fields],
        onEnum = \entries -> [((.ctor) entry, "constructor case") | entry <- entries],
        onUnion = \_ arms ->
          [ ((.ctor) arm, maybe "constructor case" renderExprType ((.payload) arm))
          | arm <- arms
          ]
      }

renderExprType :: ResolvedTypeExpr -> Text
renderExprType =
  foldTypeExpr
    TypeExprAlgebra
      { onText = "Text",
        onInt = "Int",
        onInteger = "Integer",
        onBool = "Bool",
        onNatural = "Natural",
        onTime = "UTCTime",
        onJson = "Value",
        onOptional = \value -> "Maybe (" <> value <> ")",
        onList = \value -> "[" <> value <> "]",
        onMap = \value -> "Map Text (" <> value <> ")",
        onRef = unMappedKey
      }

obligationsFor :: TypeGraph -> StructuralDecl -> [BindingObligation]
obligationsFor graph declaration = bindingEntry : fixtureEntry : initialEntries
  where
    source = (.haskell) declaration
    consumerType = (.moduleName) source <> "." <> (.valueType) source
    shapeType = (.name) declaration <> "Shape"
    paths = map renderUsePath (usePaths graph ((.name) declaration))
    registerPaths =
      [ renderUsePath path
      | path@UsePath {root = RootRegister {}} <- usePaths graph ((.name) declaration)
      ]
    bindingEntry =
      obligationFor
        declaration
        ((.binding) declaration)
        BindingValue
        ("StructuralBinding " <> consumerType <> " " <> shapeType)
        paths
        (Just (unBindingVersion ((.bindingVersion) declaration)))
        (Just (unCanonicalTypeId ((.canonical) declaration)))
    fixtureEntry =
      obligationFor
        declaration
        ((.fixtures) declaration)
        FixtureValue
        ("FixtureCases " <> consumerType)
        paths
        Nothing
        (Just (unCanonicalTypeId ((.canonical) declaration)))
    initialEntries = case (registerPaths, (.initial) declaration) of
      ([], _) -> []
      (_, Nothing) -> []
      (_, Just initialValue) ->
        [ obligationFor declaration initialValue InitialValue consumerType registerPaths Nothing (Just (unCanonicalTypeId ((.canonical) declaration)))
        ]

obligationFor :: StructuralDecl -> QualifiedValueName -> BindingObligationKind -> Text -> [Text] -> Maybe Text -> Maybe Text -> BindingObligation
obligationFor declaration qualified kindValue signature paths version canonical =
  BindingObligation
    { mappedName = (.name) declaration,
      package = (.package) ((.haskell) declaration),
      moduleName = ownerModule,
      symbol = symbol,
      kind = kindValue,
      signature = symbol <> " :: " <> signature,
      useSites = paths,
      bindingVersion = version,
      canonicalType = canonical,
      equalityContract = Nothing,
      idDomainContract = Nothing,
      category = "structural"
    }
  where
    (ownerModule, symbol) = splitQualified (unQualifiedValueName qualified)

nominalObligationsFor :: CheckedService -> ResolvedNominalType -> [BindingObligation]
nominalObligationsFor service nominal = case (.ownership) nominal of
  GeneratedNominal -> []
  ConsumerNominal binding -> bindingEntry : fixtureEntry : initialEntries
    where
      name = (.name) nominal
      source = (.haskell) binding
      consumerType = (.moduleName) source <> "." <> (.valueType) source
      paths = useSites spec name
      registerPaths = [path | path <- paths, " register " `T.isInfixOf` path]
      category = case (.representation) nominal of
        IdRepresentation {} -> "nominal-id"
        EnumRepresentation {} -> "nominal-enum"
        ScalarRepresentation {} -> "nominal-scalar"
      representation = case (.representation) nominal of
        IdRepresentation prefix -> "(KindID " <> quoted prefix <> ")"
        EnumRepresentation {} -> nominalEnumRepresentationModule spec name <> "." <> name <> "Representation"
        ScalarRepresentation NominalText -> "Text"
        ScalarRepresentation NominalInt -> "Int"
        ScalarRepresentation NominalNatural -> "Natural"
        ScalarRepresentation NominalBool -> "Bool"
        ScalarRepresentation NominalTime -> "UTCTime"
      canonical = Just (unCanonicalTypeId ((.canonical) binding))
      equalityContract = nominalEqualityIdentityForService (checkedLanguageContract service) nominal
      idContract = case (.representation) nominal of
        IdRepresentation prefix -> idDomainVersion <$> idDomainContractFor (checkedLanguageContract service) prefix
        _ -> Nothing
      bindingEntry = nominalObligation name binding category ((.binding) binding) BindingValue ("NominalBinding " <> consumerType <> " " <> representation) paths (Just (unBindingVersion ((.bindingVersion) binding))) canonical equalityContract idContract
      fixtureEntry = nominalObligation name binding category ((.fixtures) binding) FixtureValue ("NominalFixtureCases " <> consumerType) paths Nothing canonical Nothing Nothing
      initialEntries = case (registerPaths, (.initial) binding) of
        ([], _) -> []
        (_, Nothing) -> []
        (_, Just initialValue) -> [nominalObligation name binding category initialValue InitialValue consumerType registerPaths Nothing canonical Nothing Nothing]
  where
    spec = checkedSpec service
    quoted value = T.pack (show value)

nominalObligation :: Name -> ConsumerNominalBinding -> Text -> QualifiedValueName -> BindingObligationKind -> Text -> [Text] -> Maybe Text -> Maybe Text -> Maybe Text -> Maybe Text -> BindingObligation
nominalObligation name binding category qualified kindValue signature paths version canonical equalityContract idDomainContract =
  BindingObligation
    { mappedName = name,
      package = (.package) ((.haskell) binding),
      moduleName = ownerModule,
      symbol = symbol,
      kind = kindValue,
      signature = symbol <> " :: " <> signature,
      useSites = paths,
      bindingVersion = version,
      canonicalType = canonical,
      equalityContract = equalityContract,
      idDomainContract = idDomainContract,
      category = category
    }
  where
    (ownerModule, symbol) = splitQualified (unQualifiedValueName qualified)

useSites :: Spec -> Name -> [Text]
useSites spec target = concatMap aggregatePaths [aggregate | NAggregate aggregate <- (.nodes) spec]
  where
    aggregatePaths aggregate =
      [ (.name) aggregate <> " command " <> (.name) command <> " ." <> (.name) field <> " : " <> target
      | command <- (.commands) aggregate,
        field <- (.fields) command,
        fieldUses field
      ]
        <> [ (.name) aggregate <> " event " <> (.name) event <> " ." <> (.name) field <> " : " <> target
           | event <- (.events) aggregate,
             field <- eventFields aggregate event,
             fieldUses field
           ]
        <> [ (.name) aggregate <> " register " <> (.name) register <> " : " <> target
           | register <- (.regs) aggregate,
             (.valueType) register == TRef target
           ]
    eventFields aggregate event = case (.body) event of
      EventFields fields -> fields
      EventFromCommand commandName -> concat [(.fields) command | command <- (.commands) aggregate, (.name) command == commandName]
    fieldUses field = (.valueType) field == Just (TRef target)

nominalEnumRepresentationModule :: Spec -> Name -> Text
nominalEnumRepresentationModule spec nominalName = case maybe GeneratedPrefix id ((.layout) spec) of
  GeneratedPrefix -> root <> "Generated." <> contextModuleName <> ".Nominal.Shape." <> nominalName
  CollocatedLeaf -> root <> contextModuleName <> ".Nominal.Shape." <> nominalName <> ".Generated"
  where
    root = maybe "" (<> ".") ((.moduleRoot) spec)
    contextModuleName =
      case HaskellName.deriveHaskellName HaskellName.LogicalWireWord site of
        Right derived -> HaskellName.renderUpperCamelName ((.upperCamel) derived)
        Left _ -> (.context) spec
    site =
      HaskellName.NameSite
        { HaskellName.kind = HaskellName.ContextModuleSite,
          HaskellName.logicalName = (.context) spec,
          HaskellName.owner = "binding-obligation-context",
          HaskellName.line = 0
        }

renderBindingObligations :: Text -> [BindingObligation] -> Text
renderBindingObligations context obligations = case obligations of
  [] -> "no binding obligations for context " <> context
  _ ->
    T.unlines $
      ["binding obligations for context " <> context]
        <> concatMap renderGroup grouped
  where
    grouped = groupBy sameOwner (sortOn obligationSortKey obligations)
    sameOwner left right = ownerKey left == ownerKey right
    renderGroup [] = []
    renderGroup entries@(firstEntry : _) =
      ("  " <> (.moduleName) firstEntry <> " (package " <> (.package) firstEntry <> ")")
        : concatMap renderEntry entries
    renderEntry obligation =
      [ "    " <> (.signature) obligation,
        "      reason: " <> renderKind ((.kind) obligation) <> " — " <> (.category) obligation <> " type " <> (.mappedName) obligation <> renderPaths ((.useSites) obligation)
      ]
        <> maybe [] (\version -> ["      provenance: binding-version " <> quoted version]) ((.bindingVersion) obligation)
        <> maybe [] (\canonical -> ["      canonical-type: " <> quoted canonical]) ((.canonicalType) obligation)
        <> maybe [] (\contract -> ["      equality-contract: " <> quoted contract]) ((.equalityContract) obligation)
        <> maybe [] (\contract -> ["      id-domain-contract: " <> quoted contract]) ((.idDomainContract) obligation)
    renderPaths [] = " (not currently used by an aggregate root)"
    renderPaths paths = " (" <> T.intercalate "; " paths <> ")"
    quoted value = T.pack (show value)

obligationSortKey :: BindingObligation -> (Text, Text, Text, BindingObligationKind, Text)
obligationSortKey obligation =
  ( (.package) obligation,
    (.moduleName) obligation,
    (.mappedName) obligation,
    (.kind) obligation,
    (.symbol) obligation
  )

ownerKey :: BindingObligation -> (Text, Text)
ownerKey obligation = ((.package) obligation, (.moduleName) obligation)

holeSortKey :: BindingHole -> (Text, Name, BindingObligationKind, Maybe Text, Text)
holeSortKey hole =
  ((.moduleName) hole, (.mappedName) hole, (.kind) hole, (.path) hole, (.symbol) hole)

renderKind :: BindingObligationKind -> Text
renderKind BindingValue = "binding"
renderKind FixtureValue = "fixtures"
renderKind InitialValue = "initial-value"

parseKind :: Text -> Maybe BindingObligationKind
parseKind "binding" = Just BindingValue
parseKind "fixtures" = Just FixtureValue
parseKind "initial-value" = Just InitialValue
parseKind _ = Nothing

splitQualified :: Text -> (Text, Text)
splitQualified value =
  let (prefix, name) = T.breakOnEnd "." value
   in (T.dropEnd 1 prefix, name)
