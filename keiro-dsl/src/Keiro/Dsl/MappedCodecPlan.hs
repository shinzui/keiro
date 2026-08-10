{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Pure lowering plan shared by persisted mapped consumers. The graph is the
-- only schema authority; this module merely plans a consumer type and renders
-- Aeson expressions for either consumer values or generated structural shapes.
module Keiro.Dsl.MappedCodecPlan
  ( MappedAuthorityMode (..),
    MappedReferenceBoundary (..),
    MappedCodecPlan (..),
    MappedCodecPlanError (..),
    planMappedCodec,
    renderMappedEncode,
    renderMappedParse,
  )
where

import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Keiro.Dsl.ConsumerTypePlan
import Keiro.Dsl.TypeGraph

data MappedAuthorityMode
  = PrimitiveAuthority
  | ExplicitJsonAuthority
  | StructuralAuthority !MappedKey
  | OpaqueAuthority !MappedKey
  deriving stock (Eq, Ord, Show)

-- | A consumer root crosses a declared total binding for structural
-- references. A structural-shape field is already on the generated side of
-- that binding and therefore calls the nested shape codec directly.
data MappedReferenceBoundary
  = ConsumerValueBoundary
  | StructuralShapeBoundary
  deriving stock (Eq, Ord, Show)

data MappedCodecPlan = MappedCodecPlan
  { consumerType :: !ConsumerTypePlan,
    resolvedExpression :: !ResolvedTypeExpr,
    authority :: !(Set MappedAuthorityMode)
  }
  deriving stock (Eq, Show)

newtype MappedCodecPlanError
  = MappedCodecConsumerTypeError ConsumerTypePlanError
  deriving stock (Eq, Show)

planMappedCodec :: TypeGraph -> ResolvedTypeExpr -> Either MappedCodecPlanError MappedCodecPlan
planMappedCodec graph expression = do
  plannedType <- either (Left . MappedCodecConsumerTypeError) Right (planConsumerType graph expression)
  pure
    MappedCodecPlan
      { consumerType = plannedType,
        resolvedExpression = expression,
        authority = foldTypeExpr authorityAlgebra expression
      }
  where
    authorityAlgebra =
      TypeExprAlgebra
        { onText = Set.singleton PrimitiveAuthority,
          onInt = Set.singleton PrimitiveAuthority,
          onInteger = Set.singleton PrimitiveAuthority,
          onBool = Set.singleton PrimitiveAuthority,
          onNatural = Set.singleton PrimitiveAuthority,
          onTime = Set.singleton PrimitiveAuthority,
          onJson = Set.singleton ExplicitJsonAuthority,
          onOptional = id,
          onList = id,
          onMap = id,
          onRef = \key -> case Map.lookup key (tgDeclarations graph) of
            Just ResolvedStructural {} -> Set.singleton (StructuralAuthority key)
            Just ResolvedOpaque {} -> Set.singleton (OpaqueAuthority key)
            Nothing -> Set.empty
        }

renderMappedEncode :: TypeGraph -> MappedReferenceBoundary -> MappedCodecPlan -> Text -> Text
renderMappedEncode graph boundary plan value =
  foldTypeExpr
    TypeExprAlgebra
      { onText = primitive,
        onInt = primitive,
        onInteger = primitive,
        onBool = primitive,
        onNatural = primitive,
        onTime = primitive,
        onJson = id,
        onOptional = \encode candidate -> "maybe Null (\\item -> " <> encode "item" <> ") (" <> candidate <> ")",
        onList = \encode candidate -> "toJSON (map (\\item -> " <> encode "item" <> ") (" <> candidate <> "))",
        onMap = \encode candidate -> "toJSON (Map.map (\\item -> " <> encode "item" <> ") (" <> candidate <> "))",
        onRef = encodeReference
      }
    (resolvedExpression plan)
    value
  where
    primitive candidate = "toJSON (" <> candidate <> ")"
    encodeReference key candidate = case Map.lookup key (tgDeclarations graph) of
      Just (ResolvedStructural declaration _) ->
        "encode" <> sdName declaration <> suffix <> argument candidate
      Just ResolvedOpaque {} -> case boundary of
        ConsumerValueBoundary -> "toJSON " <> candidate
        StructuralShapeBoundary -> primitive candidate
      Nothing -> primitive candidate
    argument candidate = case boundary of
      ConsumerValueBoundary -> " " <> candidate
      StructuralShapeBoundary -> " (" <> candidate <> ")"
    suffix = case boundary of
      ConsumerValueBoundary -> "Mapped"
      StructuralShapeBoundary -> "Shape"

renderMappedParse :: TypeGraph -> MappedReferenceBoundary -> MappedCodecPlan -> Text
renderMappedParse graph boundary plan =
  foldTypeExpr
    TypeExprAlgebra
      { onText = "parseJSON",
        onInt = "parseJSON",
        onInteger = "parseJSON",
        onBool = "parseJSON",
        onNatural = "parseJSON",
        onTime = "parseJSON",
        onJson = "pure",
        onOptional = \decode -> "\\value -> case value of Null -> pure Nothing; other -> Just <$> " <> decode <> " other",
        onList = \decode -> "\\value -> (parseJSON value :: Parser [Value]) >>= traverse (" <> decode <> ")",
        onMap = \decode -> "\\value -> (parseJSON value :: Parser (Map Text Value)) >>= traverse (" <> decode <> ")",
        onRef = parseReference
      }
    (resolvedExpression plan)
  where
    parseReference key = case Map.lookup key (tgDeclarations graph) of
      Just (ResolvedStructural declaration _) -> "parse" <> sdName declaration <> suffix
      Just ResolvedOpaque {} -> "parseJSON"
      Nothing -> "parseJSON"
    suffix = case boundary of
      ConsumerValueBoundary -> "Mapped"
      StructuralShapeBoundary -> "Shape"
