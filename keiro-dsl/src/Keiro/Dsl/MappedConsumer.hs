{- | One checked projection of mapped declarations for every scaffold
integration surface. Keeping dependency requirements and persisted identities
together prevents the manifest, preflight report, and scaffold record from
silently disagreeing.
-}
module Keiro.Dsl.MappedConsumer (
    ConsumerPlan (..),
    MappingIdentity (..),
    consumerPlan,
) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.Grammar (HaskellSource (..), Spec)
import Keiro.Dsl.TypeGraph

data ConsumerPlan = ConsumerPlan
    { consumerPackages :: ![Text]
    , consumerModules :: ![Text]
    , consumerMappings :: ![MappingIdentity]
    }
    deriving stock (Eq, Show)

data MappingIdentity
    = StructuralMapping
        { mappingSpecName :: !Text
        , mappingCanonicalType :: !Text
        , mappingPackage :: !Text
        , mappingModule :: !Text
        , mappingType :: !Text
        , mappingBindingSymbol :: !Text
        , mappingBindingVersion :: !Text
        }
    | OpaqueMapping
        { mappingSpecName :: !Text
        , mappingPackage :: !Text
        , mappingModule :: !Text
        , mappingType :: !Text
        , mappingCodecIdentity :: !Text
        , mappingCodecVersion :: !Text
        }
    deriving stock (Eq, Show)

instance ToJSON MappingIdentity where
    toJSON StructuralMapping{mappingSpecName, mappingCanonicalType, mappingPackage, mappingModule, mappingType, mappingBindingSymbol, mappingBindingVersion} =
        object
            [ "schema" .= (1 :: Int)
            , "mode" .= ("structural" :: Text)
            , "specName" .= mappingSpecName
            , "canonicalType" .= mappingCanonicalType
            , "package" .= mappingPackage
            , "module" .= mappingModule
            , "type" .= mappingType
            , "bindingSymbol" .= mappingBindingSymbol
            , "bindingVersion" .= mappingBindingVersion
            ]
    toJSON OpaqueMapping{mappingSpecName, mappingPackage, mappingModule, mappingType, mappingCodecIdentity, mappingCodecVersion} =
        object
            [ "schema" .= (1 :: Int)
            , "mode" .= ("opaque" :: Text)
            , "specName" .= mappingSpecName
            , "package" .= mappingPackage
            , "module" .= mappingModule
            , "type" .= mappingType
            , "codecIdentity" .= mappingCodecIdentity
            , "codecVersion" .= mappingCodecVersion
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
                    _ -> fail "unknown mapping identity mode"

consumerPlan :: Spec -> ConsumerPlan
consumerPlan spec = case resolveTypeGraph spec of
    Left _ -> ConsumerPlan [] [] []
    Right graph ->
        ConsumerPlan
            { consumerPackages = uniqueSorted [hsPackage (mappedSource declaration) | declaration <- declarations]
            , consumerModules = uniqueSorted (concatMap mappedModules declarations)
            , consumerMappings = sortMappings (map mappingIdentity declarations)
            }
      where
        declarations = Map.elems (tgDeclarations graph)

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
        { mappingSpecName = sdName declaration
        , mappingCanonicalType = unCanonicalTypeId (sdCanonical declaration)
        , mappingPackage = hsPackage (sdHaskell declaration)
        , mappingModule = hsModule (sdHaskell declaration)
        , mappingType = hsType (sdHaskell declaration)
        , mappingBindingSymbol = unQualifiedValueName (sdBinding declaration)
        , mappingBindingVersion = unBindingVersion (sdBindingVersion declaration)
        }
mappingIdentity (ResolvedOpaque declaration) =
    OpaqueMapping
        { mappingSpecName = odName declaration
        , mappingPackage = hsPackage (odHaskell declaration)
        , mappingModule = hsModule (odHaskell declaration)
        , mappingType = hsType (odHaskell declaration)
        , mappingCodecIdentity = unCodecIdentity (odCodecIdentity declaration)
        , mappingCodecVersion = unCodecVersion (odCodecVersion declaration)
        }

qualifiedModule :: QualifiedValueName -> Text
qualifiedModule qualified = T.dropEnd 1 (fst (T.breakOnEnd "." (unQualifiedValueName qualified)))

sortMappings :: [MappingIdentity] -> [MappingIdentity]
sortMappings = sortOnName
  where
    sortOnName [] = []
    sortOnName mappings =
        [ mapping
        | name <- sort (map mappingSpecName mappings)
        , mapping <- mappings
        , mappingSpecName mapping == name
        ]

uniqueSorted :: [Text] -> [Text]
uniqueSorted = sort . nub
