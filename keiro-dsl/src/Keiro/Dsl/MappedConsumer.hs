-- | One checked projection of mapped declarations for every scaffold
-- integration surface. Keeping dependency requirements and persisted identities
-- together prevents the manifest, preflight report, and scaffold record from
-- silently disagreeing.
module Keiro.Dsl.MappedConsumer
  ( ConsumerPlan (..),
    MappingIdentity (..),
    consumerPlan,
    consumerPlanForService,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.List (nub, sort)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar (HaskellSource (..), Spec)
import Keiro.Dsl.NominalType
import Keiro.Dsl.SemanticContract (CheckedService, checkedSpec, checkedTypeGraph, legacyCheckedService)
import Keiro.Dsl.TypeGraph

data ConsumerPlan = ConsumerPlan
  { packages :: ![Text],
    modules :: ![Text],
    mappings :: ![MappingIdentity]
  }
  deriving stock (Eq, Show)

data MappingIdentity
  = StructuralMapping
      { specName :: !Text,
        canonicalType :: !Text,
        package :: !Text,
        moduleName :: !Text,
        valueType :: !Text,
        bindingSymbol :: !Text,
        bindingVersion :: !Text
      }
  | OpaqueMapping
      { specName :: !Text,
        package :: !Text,
        moduleName :: !Text,
        valueType :: !Text,
        codecIdentity :: !Text,
        codecVersion :: !Text
      }
  | NominalMapping
      { specName :: !Text,
        nominalCategory :: !Text,
        nominalRepresentation :: !Text,
        canonicalType :: !Text,
        package :: !Text,
        moduleName :: !Text,
        valueType :: !Text,
        bindingSymbol :: !Text,
        bindingVersion :: !Text,
        fixtureSymbol :: !Text,
        initialSymbol :: !(Maybe Text)
      }
  deriving stock (Eq, Show)

instance ToJSON MappingIdentity where
  toJSON StructuralMapping {specName, canonicalType, package, moduleName, valueType, bindingSymbol, bindingVersion} =
    object
      [ "schema" .= (1 :: Int),
        "mode" .= ("structural" :: Text),
        "specName" .= specName,
        "canonicalType" .= canonicalType,
        "package" .= package,
        "module" .= moduleName,
        "type" .= valueType,
        "bindingSymbol" .= bindingSymbol,
        "bindingVersion" .= bindingVersion
      ]
  toJSON OpaqueMapping {specName, package, moduleName, valueType, codecIdentity, codecVersion} =
    object
      [ "schema" .= (1 :: Int),
        "mode" .= ("opaque" :: Text),
        "specName" .= specName,
        "package" .= package,
        "module" .= moduleName,
        "type" .= valueType,
        "codecIdentity" .= codecIdentity,
        "codecVersion" .= codecVersion
      ]
  toJSON NominalMapping {specName, nominalCategory, nominalRepresentation, canonicalType, package, moduleName, valueType, bindingSymbol, bindingVersion, fixtureSymbol, initialSymbol} =
    object
      [ "schema" .= (1 :: Int),
        "mode" .= ("nominal" :: Text),
        "specName" .= specName,
        "category" .= nominalCategory,
        "representation" .= nominalRepresentation,
        "canonicalType" .= canonicalType,
        "package" .= package,
        "module" .= moduleName,
        "type" .= valueType,
        "bindingSymbol" .= bindingSymbol,
        "bindingVersion" .= bindingVersion,
        "fixtureSymbol" .= fixtureSymbol,
        "initialSymbol" .= initialSymbol
      ]

instance FromJSON MappingIdentity where
  parseJSON = withObject "keiro-dsl mapping identity" $ \value -> do
    schema <- value .: "schema"
    if schema /= (1 :: Int)
      then fail "unsupported mapping identity schema"
      else do
        mode <- value .: "mode"
        case (mode :: Text) of
          "structural" ->
            StructuralMapping
              <$> value .: "specName"
              <*> value .: "canonicalType"
              <*> value .: "package"
              <*> value .: "module"
              <*> value .: "type"
              <*> value .: "bindingSymbol"
              <*> value .: "bindingVersion"
          "opaque" ->
            OpaqueMapping
              <$> value .: "specName"
              <*> value .: "package"
              <*> value .: "module"
              <*> value .: "type"
              <*> value .: "codecIdentity"
              <*> value .: "codecVersion"
          "nominal" ->
            NominalMapping
              <$> value .: "specName"
              <*> value .: "category"
              <*> value .: "representation"
              <*> value .: "canonicalType"
              <*> value .: "package"
              <*> value .: "module"
              <*> value .: "type"
              <*> value .: "bindingSymbol"
              <*> value .: "bindingVersion"
              <*> value .: "fixtureSymbol"
              <*> value .: "initialSymbol"
          _ -> fail "unknown mapping identity mode"

consumerPlan :: Spec -> ConsumerPlan
consumerPlan = consumerPlanForService . legacyCheckedService

consumerPlanForService :: CheckedService -> ConsumerPlan
consumerPlanForService service = case (checkedTypeGraph service, resolveNominalTypes spec) of
  (Right graph, Right nominalRegistry) ->
    ConsumerPlan
      { packages = uniqueSorted ([(.package) (mappedSource declaration) | declaration <- declarations] <> map nominalPackage nominalBindings),
        modules = uniqueSorted (concatMap mappedModules declarations <> concatMap nominalModules nominalBindings),
        mappings = sortMappings (map mappingIdentity declarations <> map nominalMappingIdentity nominalBindings)
      }
    where
      declarations = Map.elems ((.declarations) graph)
      nominalBindings =
        [ (nominal, binding)
        | nominal <- Map.elems ((.nominalTypes) nominalRegistry),
          ConsumerNominal binding <- [(.ownership) nominal]
        ]
  _ -> ConsumerPlan [] [] []
  where
    spec = checkedSpec service

mappedSource :: ResolvedMappedDecl -> HaskellSource
mappedSource (ResolvedStructural declaration _) = (.haskell) declaration
mappedSource (ResolvedOpaque declaration) = (.haskell) declaration

mappedModules :: ResolvedMappedDecl -> [Text]
mappedModules (ResolvedStructural declaration _) =
  (.moduleName) ((.haskell) declaration)
    : qualifiedModule ((.binding) declaration)
    : qualifiedModule ((.fixtures) declaration)
    : maybe [] (pure . qualifiedModule) ((.initial) declaration)
mappedModules (ResolvedOpaque declaration) =
  (.moduleName) ((.haskell) declaration)
    : qualifiedModule ((.fixtures) declaration)
    : maybe [] (pure . qualifiedModule) ((.initial) declaration)

mappingIdentity :: ResolvedMappedDecl -> MappingIdentity
mappingIdentity (ResolvedStructural declaration _) =
  StructuralMapping
    { specName = (.name) declaration,
      canonicalType = unCanonicalTypeId ((.canonical) declaration),
      package = (.package) ((.haskell) declaration),
      moduleName = (.moduleName) ((.haskell) declaration),
      valueType = (.valueType) ((.haskell) declaration),
      bindingSymbol = unQualifiedValueName ((.binding) declaration),
      bindingVersion = unBindingVersion ((.bindingVersion) declaration)
    }
mappingIdentity (ResolvedOpaque declaration) =
  OpaqueMapping
    { specName = (.name) declaration,
      package = (.package) ((.haskell) declaration),
      moduleName = (.moduleName) ((.haskell) declaration),
      valueType = (.valueType) ((.haskell) declaration),
      codecIdentity = unCodecIdentity ((.codecIdentity) declaration),
      codecVersion = unCodecVersion ((.codecVersion) declaration)
    }

nominalMappingIdentity :: (ResolvedNominalType, ConsumerNominalBinding) -> MappingIdentity
nominalMappingIdentity (nominal, binding) =
  NominalMapping
    { specName = (.name) nominal,
      nominalCategory = nominalCategory nominal,
      nominalRepresentation = nominalRepresentationIdentity nominal,
      canonicalType = unCanonicalTypeId ((.canonical) binding),
      package = (.package) source,
      moduleName = (.moduleName) source,
      valueType = (.valueType) source,
      bindingSymbol = unQualifiedValueName ((.binding) binding),
      bindingVersion = unBindingVersion ((.bindingVersion) binding),
      fixtureSymbol = unQualifiedValueName ((.fixtures) binding),
      initialSymbol = unQualifiedValueName <$> (.initial) binding
    }
  where
    source = (.haskell) binding

nominalPackage :: (ResolvedNominalType, ConsumerNominalBinding) -> Text
nominalPackage (_, binding) = (.package) ((.haskell) binding)

nominalModules :: (ResolvedNominalType, ConsumerNominalBinding) -> [Text]
nominalModules (_, binding) =
  (.moduleName) ((.haskell) binding)
    : qualifiedModule ((.binding) binding)
    : qualifiedModule ((.fixtures) binding)
    : maybe [] (pure . qualifiedModule) ((.initial) binding)

nominalCategory :: ResolvedNominalType -> Text
nominalCategory nominal = case (.representation) nominal of
  IdRepresentation {} -> "id"
  EnumRepresentation {} -> "enum"
  ScalarRepresentation {} -> "scalar"

nominalRepresentationIdentity :: ResolvedNominalType -> Text
nominalRepresentationIdentity nominal = case (.representation) nominal of
  IdRepresentation prefix -> "KindID:" <> prefix
  EnumRepresentation constructors ->
    "enum:" <> T.intercalate "," [constructor <> "=" <> wire | (constructor, wire) <- NE.toList constructors]
  ScalarRepresentation representation -> case representation of
    NominalText -> "Text"
    NominalInt -> "Int"
    NominalNatural -> "Natural"
    NominalBool -> "Bool"
    NominalTime -> "Time"

qualifiedModule :: QualifiedValueName -> Text
qualifiedModule qualified = T.dropEnd 1 (fst (T.breakOnEnd "." (unQualifiedValueName qualified)))

sortMappings :: [MappingIdentity] -> [MappingIdentity]
sortMappings = sortOnName
  where
    sortOnName [] = []
    sortOnName mappings =
      [ mapping
      | name <- sort (map (.specName) mappings),
        mapping <- mappings,
        (.specName) mapping == name
      ]

uniqueSorted :: [Text] -> [Text]
uniqueSorted = sort . nub
