{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Consumer-facing Haskell type requirements for one checked mapped
-- expression. This module deliberately plans no JSON, SQL, or runtime codec;
-- queue and read-model emitters add their own surface authority around it.
module Keiro.Dsl.ConsumerTypePlan
  ( HaskellTypeOccurrence (..),
    ImportRequirement (..),
    ConsumerTypePlan (..),
    ConsumerTypePlanError (..),
    planConsumerType,
  )
where

import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Keiro.Dsl.Grammar (HaskellSource (..))
import Keiro.Dsl.TypeGraph

newtype HaskellTypeOccurrence = HaskellTypeOccurrence
  { unHaskellTypeOccurrence :: Text
  }
  deriving stock (Eq, Ord, Show)

-- | One deterministic import needed to render the planned type. Consumer
-- package provenance is retained so later Cabal planning does not need to
-- rediscover it from the raw specification.
data ImportRequirement = ImportRequirement
  { package :: !Text,
    moduleName :: !Text,
    occurrence :: !Text
  }
  deriving stock (Eq, Ord, Show)

data ConsumerTypePlan = ConsumerTypePlan
  { haskellType :: !HaskellTypeOccurrence,
    imports :: ![ImportRequirement],
    dependencies :: !(Set MappedKey)
  }
  deriving stock (Eq, Show)

data ConsumerTypePlanError
  = ConsumerTypePlanUnknownDeclaration !MappedKey
  deriving stock (Eq, Show)

planConsumerType :: TypeGraph -> ResolvedTypeExpr -> Either ConsumerTypePlanError ConsumerTypePlan
planConsumerType graph expression = do
  RenderedType {rendered, requirements, mappedDependencies} <- plan expression
  pure
    ConsumerTypePlan
      { haskellType = HaskellTypeOccurrence rendered,
        imports = Set.toAscList requirements,
        dependencies = mappedDependencies
      }
  where
    plan = \case
      RText -> atom "Text" [ImportRequirement "text" "Data.Text" "Text"]
      RInt -> atom "Int" []
      RInteger -> atom "Integer" []
      RBool -> atom "Bool" []
      RNatural -> atom "Natural" [ImportRequirement "base" "Numeric.Natural" "Natural"]
      RTime -> atom "UTCTime" [ImportRequirement "time" "Data.Time" "UTCTime"]
      RJson -> atom "Value" [ImportRequirement "aeson" "Data.Aeson" "Value"]
      ROptional value -> application "Maybe" [ImportRequirement "base" "Data.Maybe" "Maybe"] <$> plan value
      RList value -> listType <$> plan value
      RMap value -> mapType <$> plan value
      RRef key -> case Map.lookup key (tgDeclarations graph) of
        Nothing -> Left (ConsumerTypePlanUnknownDeclaration key)
        Just declaration ->
          let source = mappedSource declaration
           in Right
                RenderedType
                  { rendered = hsType source,
                    precedence = AtomicType,
                    requirements = Set.singleton (ImportRequirement (hsPackage source) (hsModule source) (hsType source)),
                    mappedDependencies = Set.insert key (Map.findWithDefault Set.empty key (tgReachability graph))
                  }

    atom rendered requiredImports =
      Right
        RenderedType
          { rendered,
            precedence = AtomicType,
            requirements = Set.fromList requiredImports,
            mappedDependencies = Set.empty
          }

    application constructor requiredImports value =
      value
        { rendered = constructor <> " " <> argument value,
          precedence = ApplicationType,
          requirements = Set.fromList requiredImports <> requirements value
        }

    listType value =
      value
        { rendered = "[" <> rendered value <> "]",
          precedence = AtomicType
        }

    mapType value =
      value
        { rendered = "Map Text " <> argument value,
          precedence = ApplicationType,
          requirements =
            Set.fromList
              [ ImportRequirement "containers" "Data.Map.Strict" "Map",
                ImportRequirement "text" "Data.Text" "Text"
              ]
              <> requirements value
        }

    argument value = case precedence value of
      AtomicType -> rendered value
      ApplicationType -> "(" <> rendered value <> ")"

data TypePrecedence = AtomicType | ApplicationType

data RenderedType = RenderedType
  { rendered :: !Text,
    precedence :: !TypePrecedence,
    requirements :: !(Set ImportRequirement),
    mappedDependencies :: !(Set MappedKey)
  }

mappedSource :: ResolvedMappedDecl -> HaskellSource
mappedSource (ResolvedStructural declaration _) = sdHaskell declaration
mappedSource (ResolvedOpaque declaration) = odHaskell declaration
