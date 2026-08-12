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
  { consumerPackages :: ![Text],
    consumerModules :: ![Text],
    consumerMappings :: ![MappingIdentity]
  }
  deriving stock (Eq, Show)

data MappingIdentity
  = StructuralMapping
      { mappingSpecName :: !Text,
        mappingCanonicalType :: !Text,
        mappingPackage :: !Text,
        mappingModule :: !Text,
        mappingType :: !Text,
        mappingBindingSymbol :: !Text,
        mappingBindingVersion :: !Text
      }
  | OpaqueMapping
      { mappingSpecName :: !Text,
        mappingPackage :: !Text,
        mappingModule :: !Text,
        mappingType :: !Text,
        mappingCodecIdentity :: !Text,
        mappingCodecVersion :: !Text
      }
  | NominalMapping
      { mappingSpecName :: !Text,
        mappingNominalCategory :: !Text,
        mappingNominalRepresentation :: !Text,
        mappingCanonicalType :: !Text,
        mappingPackage :: !Text,
        mappingModule :: !Text,
        mappingType :: !Text,
        mappingBindingSymbol :: !Text,
        mappingBindingVersion :: !Text,
        mappingFixtureSymbol :: !Text,
        mappingInitialSymbol :: !(Maybe Text)
      }
  deriving stock (Eq, Show)

instance ToJSON MappingIdentity where
  toJSON StructuralMapping {mappingSpecName, mappingCanonicalType, mappingPackage, mappingModule, mappingType, mappingBindingSymbol, mappingBindingVersion} =
    object
      [ "schema" .= (1 :: Int),
        "mode" .= ("structural" :: Text),
        "specName" .= mappingSpecName,
        "canonicalType" .= mappingCanonicalType,
        "package" .= mappingPackage,
        "module" .= mappingModule,
        "type" .= mappingType,
        "bindingSymbol" .= mappingBindingSymbol,
        "bindingVersion" .= mappingBindingVersion
      ]
  toJSON OpaqueMapping {mappingSpecName, mappingPackage, mappingModule, mappingType, mappingCodecIdentity, mappingCodecVersion} =
    object
      [ "schema" .= (1 :: Int),
        "mode" .= ("opaque" :: Text),
        "specName" .= mappingSpecName,
        "package" .= mappingPackage,
        "module" .= mappingModule,
        "type" .= mappingType,
        "codecIdentity" .= mappingCodecIdentity,
        "codecVersion" .= mappingCodecVersion
      ]
  toJSON NominalMapping {mappingSpecName, mappingNominalCategory, mappingNominalRepresentation, mappingCanonicalType, mappingPackage, mappingModule, mappingType, mappingBindingSymbol, mappingBindingVersion, mappingFixtureSymbol, mappingInitialSymbol} =
    object
      [ "schema" .= (1 :: Int),
        "mode" .= ("nominal" :: Text),
        "specName" .= mappingSpecName,
        "category" .= mappingNominalCategory,
        "representation" .= mappingNominalRepresentation,
        "canonicalType" .= mappingCanonicalType,
        "package" .= mappingPackage,
        "module" .= mappingModule,
        "type" .= mappingType,
        "bindingSymbol" .= mappingBindingSymbol,
        "bindingVersion" .= mappingBindingVersion,
        "fixtureSymbol" .= mappingFixtureSymbol,
        "initialSymbol" .= mappingInitialSymbol
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
      { consumerPackages = uniqueSorted ([hsPackage (mappedSource declaration) | declaration <- declarations] <> map nominalPackage nominalBindings),
        consumerModules = uniqueSorted (concatMap mappedModules declarations <> concatMap nominalModules nominalBindings),
        consumerMappings = sortMappings (map mappingIdentity declarations <> map nominalMappingIdentity nominalBindings)
      }
    where
      declarations = Map.elems (tgDeclarations graph)
      nominalBindings =
        [ (nominal, binding)
        | nominal <- Map.elems (nominalTypes nominalRegistry),
          ConsumerNominal binding <- [resolvedNominalOwnership nominal]
        ]
  _ -> ConsumerPlan [] [] []
  where
    spec = checkedSpec service

mappedSource :: ResolvedMappedDecl -> HaskellSource
mappedSource (ResolvedStructural declaration _) = sdHaskell declaration
mappedSource (ResolvedOpaque declaration) = odHaskell declaration

mappedModules :: ResolvedMappedDecl -> [Text]
mappedModules (ResolvedStructural declaration _) =
  hsModule (sdHaskell declaration)
    : qualifiedModule (sdBinding declaration)
    : qualifiedModule (sdFixtures declaration)
    : maybe [] (pure . qualifiedModule) (sdInitial declaration)
mappedModules (ResolvedOpaque declaration) =
  hsModule (odHaskell declaration)
    : qualifiedModule (odFixtures declaration)
    : maybe [] (pure . qualifiedModule) (odInitial declaration)

mappingIdentity :: ResolvedMappedDecl -> MappingIdentity
mappingIdentity (ResolvedStructural declaration _) =
  StructuralMapping
    { mappingSpecName = sdName declaration,
      mappingCanonicalType = unCanonicalTypeId (sdCanonical declaration),
      mappingPackage = hsPackage (sdHaskell declaration),
      mappingModule = hsModule (sdHaskell declaration),
      mappingType = hsType (sdHaskell declaration),
      mappingBindingSymbol = unQualifiedValueName (sdBinding declaration),
      mappingBindingVersion = unBindingVersion (sdBindingVersion declaration)
    }
mappingIdentity (ResolvedOpaque declaration) =
  OpaqueMapping
    { mappingSpecName = odName declaration,
      mappingPackage = hsPackage (odHaskell declaration),
      mappingModule = hsModule (odHaskell declaration),
      mappingType = hsType (odHaskell declaration),
      mappingCodecIdentity = unCodecIdentity (odCodecIdentity declaration),
      mappingCodecVersion = unCodecVersion (odCodecVersion declaration)
    }

nominalMappingIdentity :: (ResolvedNominalType, ConsumerNominalBinding) -> MappingIdentity
nominalMappingIdentity (nominal, binding) =
  NominalMapping
    { mappingSpecName = resolvedNominalName nominal,
      mappingNominalCategory = nominalCategory nominal,
      mappingNominalRepresentation = nominalRepresentationIdentity nominal,
      mappingCanonicalType = unCanonicalTypeId (consumerNominalCanonical binding),
      mappingPackage = hsPackage source,
      mappingModule = hsModule source,
      mappingType = hsType source,
      mappingBindingSymbol = unQualifiedValueName (consumerNominalBinding binding),
      mappingBindingVersion = unBindingVersion (consumerNominalBindingVersion binding),
      mappingFixtureSymbol = unQualifiedValueName (consumerNominalFixtures binding),
      mappingInitialSymbol = unQualifiedValueName <$> consumerNominalInitial binding
    }
  where
    source = consumerNominalHaskell binding

nominalPackage :: (ResolvedNominalType, ConsumerNominalBinding) -> Text
nominalPackage (_, binding) = hsPackage (consumerNominalHaskell binding)

nominalModules :: (ResolvedNominalType, ConsumerNominalBinding) -> [Text]
nominalModules (_, binding) =
  hsModule (consumerNominalHaskell binding)
    : qualifiedModule (consumerNominalBinding binding)
    : qualifiedModule (consumerNominalFixtures binding)
    : maybe [] (pure . qualifiedModule) (consumerNominalInitial binding)

nominalCategory :: ResolvedNominalType -> Text
nominalCategory nominal = case resolvedNominalRepresentation nominal of
  IdRepresentation {} -> "id"
  EnumRepresentation {} -> "enum"
  ScalarRepresentation {} -> "scalar"

nominalRepresentationIdentity :: ResolvedNominalType -> Text
nominalRepresentationIdentity nominal = case resolvedNominalRepresentation nominal of
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
      | name <- sort (map mappingSpecName mappings),
        mapping <- mappings,
        mappingSpecName mapping == name
      ]

uniqueSorted :: [Text] -> [Text]
uniqueSorted = sort . nub
