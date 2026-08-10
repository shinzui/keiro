{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Durable identity for the two compile-time query positions of a read model.
-- These rows deliberately exclude SQL columns, codecs, and projection runtime
-- identity: they describe only the generated Haskell API and its mapped closure.
module Keiro.Dsl.ReadModelQueryContract
  ( QueryContractPosition (..),
    QueryContractIdentity (..),
    QueryContractDrift (..),
    queryContractIdentities,
    queryContractIdentityKey,
    queryContractDrift,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Keiro.Dsl.Grammar
import Keiro.Dsl.PrettyPrint (renderTypeExpr)
import Keiro.Dsl.TypeGraph

data QueryContractPosition
  = QueryInputConsumer
  | QueryResultConsumer
  deriving stock (Eq, Ord, Show)

data QueryContractIdentity = QueryContractIdentity
  { qciReadModel :: !Name,
    qciPosition :: !QueryContractPosition,
    qciTypeExpression :: !Text,
    qciMappedDependencies :: ![Name]
  }
  deriving stock (Eq, Ord, Show)

data QueryContractDrift = QueryContractDrift
  { qcdKey :: !(Name, QueryContractPosition),
    qcdPrevious :: !(Maybe QueryContractIdentity),
    qcdCurrent :: !(Maybe QueryContractIdentity)
  }
  deriving stock (Eq, Show)

instance ToJSON QueryContractPosition where
  toJSON QueryInputConsumer = toJSON ("input" :: Text)
  toJSON QueryResultConsumer = toJSON ("result" :: Text)

instance FromJSON QueryContractPosition where
  parseJSON value = do
    label <- parseJSON value
    case (label :: Text) of
      "input" -> pure QueryInputConsumer
      "result" -> pure QueryResultConsumer
      other -> fail ("unknown read-model query contract position: " <> show other)

instance ToJSON QueryContractIdentity where
  toJSON identity =
    object
      [ "readModel" .= qciReadModel identity,
        "position" .= qciPosition identity,
        "typeExpression" .= qciTypeExpression identity,
        "mappedDependencies" .= qciMappedDependencies identity
      ]

instance FromJSON QueryContractIdentity where
  parseJSON = withObject "QueryContractIdentity" $ \fields ->
    QueryContractIdentity
      <$> fields .: "readModel"
      <*> fields .: "position"
      <*> fields .: "typeExpression"
      <*> fields .: "mappedDependencies"

queryContractIdentityKey :: QueryContractIdentity -> (Name, QueryContractPosition)
queryContractIdentityKey identity = (qciReadModel identity, qciPosition identity)

queryContractDrift :: [QueryContractIdentity] -> [QueryContractIdentity] -> [QueryContractDrift]
queryContractDrift current previous =
  [ QueryContractDrift key oldValue newValue
  | key <- Set.toAscList (Map.keysSet oldByKey <> Map.keysSet newByKey),
    let oldValue = Map.lookup key oldByKey,
    let newValue = Map.lookup key newByKey,
    oldValue /= newValue
  ]
  where
    oldByKey = Map.fromList [(queryContractIdentityKey identity, identity) | identity <- previous]
    newByKey = Map.fromList [(queryContractIdentityKey identity, identity) | identity <- current]

queryContractIdentities :: Spec -> Either (NonEmpty TypeGraphError) [QueryContractIdentity]
queryContractIdentities spec = do
  graph <- resolveTypeGraph spec
  fmap (sortOn queryContractIdentityKey . concat) (traverse (identitiesFor graph) readModels)
  where
    readModels = [readModel | NReadModel readModel <- specNodes spec]

identitiesFor :: TypeGraph -> ReadModelNode -> Either (NonEmpty TypeGraphError) [QueryContractIdentity]
identitiesFor _ ReadModelNode {queryTypes = Nothing} = Right []
identitiesFor graph readModel@ReadModelNode {queryTypes = Just queryPair} = do
  inputExpression <- resolve QueryInputConsumer (inputLoc queryPair) (input queryPair)
  resultExpression <- resolve QueryResultConsumer (resultLoc queryPair) (result queryPair)
  pure
    [ identity QueryInputConsumer (input queryPair) inputExpression,
      identity QueryResultConsumer (result queryPair) resultExpression
    ]
  where
    resolve position location expression =
      case resolveTypeExpression graph owner location expression of
        Left failure -> Left (failure :| [])
        Right resolved -> Right resolved
      where
        owner = "readmodel '" <> rmName readModel <> "' query " <> positionLabel position
    identity position sourceExpression resolved =
      QueryContractIdentity
        { qciReadModel = rmName readModel,
          qciPosition = position,
          qciTypeExpression = renderTypeExpr sourceExpression,
          qciMappedDependencies = Set.toAscList (Set.map unMappedKey (mappedClosure graph resolved))
        }

mappedClosure :: TypeGraph -> ResolvedTypeExpr -> Set MappedKey
mappedClosure graph =
  foldTypeExpr
    TypeExprAlgebra
      { onText = Set.empty,
        onInt = Set.empty,
        onInteger = Set.empty,
        onBool = Set.empty,
        onNatural = Set.empty,
        onTime = Set.empty,
        onJson = Set.empty,
        onOptional = id,
        onList = id,
        onMap = id,
        onRef = \key -> Set.insert key (Map.findWithDefault Set.empty key (tgReachability graph))
      }

positionLabel :: QueryContractPosition -> Text
positionLabel QueryInputConsumer = "input"
positionLabel QueryResultConsumer = "result"
