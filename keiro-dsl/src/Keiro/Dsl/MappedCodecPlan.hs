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
import Data.Text qualified as T
import Keiro.Dsl.ConsumerTypePlan
import Keiro.Dsl.TypeGraph

data MappedAuthorityMode
  = PrimitiveAuthority
  | ExplicitJsonAuthority
  | StructuralAuthority !MappedKey
  | OpaqueAuthority !MappedKey
  | NominalAuthority !Text
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
          onDay = Set.singleton PrimitiveAuthority,
          onTextSet = Set.singleton PrimitiveAuthority,
          onJson = Set.singleton ExplicitJsonAuthority,
          onOptional = id,
          onList = id,
          onMap = id,
          onKeyedMap = \key value -> Set.insert (NominalAuthority ((.name) key)) value,
          onRef = \key -> case Map.lookup key ((.declarations) graph) of
            Just ResolvedStructural {} -> Set.singleton (StructuralAuthority key)
            Just ResolvedOpaque {} -> Set.singleton (OpaqueAuthority key)
            Nothing -> error ("keiro-dsl internal invariant: mapped codec plan references missing declaration " <> show key),
          onNominal = Set.singleton . NominalAuthority . (.name)
        }

renderMappedEncode :: TypeGraph -> MappedReferenceBoundary -> MappedCodecPlan -> Text -> Text
renderMappedEncode graph boundary plan = render (0 :: Int) ((.resolvedExpression) plan)
  where
    render depth expression candidate = case expression of
      RText -> primitive candidate
      RInt -> primitive candidate
      RInteger -> primitive candidate
      RBool -> primitive candidate
      RNatural -> primitive candidate
      RTime -> primitive candidate
      RDay -> "encodeCalendarDay (" <> candidate <> ")"
      RTextSet -> "encodeTextSet (" <> candidate <> ")"
      RJson -> candidate
      ROptional nested ->
        "maybe Null (\\" <> item depth <> " -> " <> render (depth + 1) nested (item depth) <> ") (" <> candidate <> ")"
      RList nested ->
        "toJSON (map (\\" <> item depth <> " -> " <> render (depth + 1) nested (item depth) <> ") (" <> candidate <> "))"
      RMap nested ->
        "toJSON (Map.map (\\" <> item depth <> " -> " <> render (depth + 1) nested (item depth) <> ") (" <> candidate <> "))"
      RKeyedMap keyLeaf nested ->
        "Object (KeyMap.fromList [(Key.fromText (render"
          <> (.name) keyLeaf
          <> "LeafKey "
          <> key depth
          <> "), "
          <> render (depth + 1) nested (item depth)
          <> ") | ("
          <> key depth
          <> ", "
          <> item depth
          <> ") <- Map.toList ("
          <> candidate
          <> ")])"
      RRef referenceKey -> encodeReference referenceKey candidate
      RNominal leaf -> "encode" <> (.name) leaf <> "Leaf " <> candidate
    primitive candidate = "toJSON (" <> candidate <> ")"
    encodeReference referenceKey candidate = case Map.lookup referenceKey ((.declarations) graph) of
      Just (ResolvedStructural declaration _) ->
        "encode" <> (.name) declaration <> suffix <> argument candidate
      Just ResolvedOpaque {} -> case boundary of
        ConsumerValueBoundary -> "toJSON " <> candidate
        StructuralShapeBoundary -> primitive candidate
      Nothing -> error ("keiro-dsl internal invariant: mapped encoder references missing declaration " <> show referenceKey)
    argument candidate = case boundary of
      ConsumerValueBoundary -> " " <> candidate
      StructuralShapeBoundary -> " (" <> candidate <> ")"
    suffix = case boundary of
      ConsumerValueBoundary -> "Mapped"
      StructuralShapeBoundary -> "Shape"
    item depth = "item" <> tshow depth
    key depth = "key" <> tshow depth

renderMappedParse :: TypeGraph -> MappedReferenceBoundary -> MappedCodecPlan -> Text
renderMappedParse graph boundary plan = render (0 :: Int) ((.resolvedExpression) plan)
  where
    render depth = \case
      RText -> "parseJSON"
      RInt -> "parseJSON"
      RInteger -> "parseJSON"
      RBool -> "parseJSON"
      RNatural -> "parseJSON"
      RTime -> "parseJSON"
      RDay -> "parseCalendarDay"
      RTextSet -> "parseTextSet"
      RJson -> "pure"
      ROptional nested ->
        "\\" <> value depth <> " -> case " <> value depth <> " of Null -> pure Nothing; " <> other depth <> " -> Just <$> (" <> render (depth + 1) nested <> ") " <> other depth
      RList nested ->
        "\\" <> value depth <> " -> do " <> items depth <> " <- (parseJSON " <> value depth <> " :: Parser [Value]); traverse (\\(" <> index depth <> ", " <> item depth <> ") -> (" <> render (depth + 1) nested <> ") " <> item depth <> " <?> Index " <> index depth <> ") (zip [0..] " <> items depth <> ")"
      RMap nested ->
        "\\" <> value depth <> " -> do " <> items depth <> " <- (parseJSON " <> value depth <> " :: Parser (Map Text Value)); Map.traverseWithKey (\\" <> key depth <> " " <> item depth <> " -> (" <> render (depth + 1) nested <> ") " <> item depth <> " <?> Key (Key.fromText " <> key depth <> ")) " <> items depth
      RKeyedMap keyLeaf nested ->
        "\\"
          <> value depth
          <> " -> withObject "
          <> tshow ("Map[" <> (.name) keyLeaf <> "]")
          <> " (\\"
          <> object depth
          <> " -> Map.fromList <$> traverse (\\("
          <> rawKey depth
          <> ", "
          <> item depth
          <> ") -> do "
          <> key depth
          <> " <- parse"
          <> (.name) keyLeaf
          <> "LeafKey (Key.toText "
          <> rawKey depth
          <> ") <?> Key "
          <> rawKey depth
          <> "; "
          <> parsedItem depth
          <> " <- ("
          <> render (depth + 1) nested
          <> ") "
          <> item depth
          <> " <?> Key "
          <> rawKey depth
          <> "; pure ("
          <> key depth
          <> ", "
          <> parsedItem depth
          <> ")) (KeyMap.toList "
          <> object depth
          <> ")) "
          <> value depth
      RRef keyValue -> parseReference keyValue
      RNominal leaf -> "parse" <> (.name) leaf <> "Leaf"
    parseReference mappedKey = case Map.lookup mappedKey ((.declarations) graph) of
      Just (ResolvedStructural declaration _) -> "parse" <> (.name) declaration <> suffix
      Just ResolvedOpaque {} -> "parseJSON"
      Nothing -> error ("keiro-dsl internal invariant: mapped parser references missing declaration " <> show mappedKey)
    suffix = case boundary of
      ConsumerValueBoundary -> "Mapped"
      StructuralShapeBoundary -> "Shape"
    value depth = "value" <> tshow depth
    other depth = "other" <> tshow depth
    items depth = "items" <> tshow depth
    index depth = "index" <> tshow depth
    item depth = "item" <> tshow depth
    key depth = "key" <> tshow depth
    rawKey depth = "rawKey" <> tshow depth
    parsedItem depth = "parsedItem" <> tshow depth
    object depth = "object" <> tshow depth

tshow :: (Show value) => value -> Text
tshow = T.pack . show
