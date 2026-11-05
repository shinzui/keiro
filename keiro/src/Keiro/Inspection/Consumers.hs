{-# LANGUAGE OverloadedRecordDot #-}

-- | Data-only declarations of durable inputs. Hosts should construct these from
-- the same configuration used by their workers; opaque adapters cannot be
-- inferred from a process manager's journal category.
module Keiro.Inspection.Consumers
  ( ConsumerSource (..),
    consumerSourceMatches,
    DurableConsumerKind (..),
    DurableConsumerDescription (..),
    DurableConsumerRegistry,
    DurableConsumerError (..),
    durableConsumerRegistry,
    durableConsumerInventoryIdentity,
    durableConsumersForCategory,
  )
where

import Data.List (foldl')
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.Projection.Catalog.Preimage
import Kiroku.Store.Types (CategoryName (..))

data ConsumerSource = AllCategories | ExactCategory !Text | CategoryNamespace !Text
  deriving stock (Eq, Ord, Show)

consumerSourceMatches :: CategoryName -> ConsumerSource -> Bool
consumerSourceMatches (CategoryName category) = \case
  AllCategories -> True
  ExactCategory declared -> category == declared
  CategoryNamespace namespace -> category == namespace || Text.isPrefixOf (namespace <> ":") category

-- | Constructor order is the public discovery order.
data DurableConsumerKind = DurableSubscriber | ProcessManagerConsumer
  deriving stock (Eq, Ord, Show)

data DurableConsumerDescription = DurableConsumerDescription
  { kind :: !DurableConsumerKind,
    name :: !Text,
    subscriptionName :: !Text,
    source :: !ConsumerSource
  }
  deriving stock (Eq, Ord, Show)

data DurableConsumerError
  = InvalidConsumerDeclaration !Text
  | ConflictingSubscriptionScope !Text
  deriving stock (Eq, Show)

-- Descriptions are deduplicated and ordered once, and the digest is forced at
-- construction. Neither requests nor response bytes are retained here.
data DurableConsumerRegistry = DurableConsumerRegistry !Text ![DurableConsumerDescription]
  deriving stock (Eq, Show)

durableConsumerRegistry :: [DurableConsumerDescription] -> Either DurableConsumerError DurableConsumerRegistry
durableConsumerRegistry descriptions = do
  mapM_ validate descriptions
  _ <- foldl' addScope (Right Map.empty) descriptions
  let ordered = Set.toAscList (Set.fromList descriptions)
      digest = hashPreimage "keiro/durable-consumers/v1" (PList (map descriptionPreimage ordered))
  pure (DurableConsumerRegistry digest ordered)
  where
    validText text = not (Text.null text) && Text.strip text == text
    require label text
      | validText text = Right ()
      | otherwise = Left (InvalidConsumerDeclaration label)
    validate description = do
      require "consumer name" description.name
      require "subscription name" description.subscriptionName
      case description.source of
        AllCategories -> Right ()
        ExactCategory category -> require "category" category
        CategoryNamespace namespace -> require "namespace" namespace
    addScope result description = do
      scopes <- result
      case Map.lookup description.subscriptionName scopes of
        Just scope | scope /= description.source -> Left (ConflictingSubscriptionScope description.subscriptionName)
        _ -> Right (Map.insert description.subscriptionName description.source scopes)
    descriptionPreimage description =
      PRecord
        "consumer"
        [ PText (case description.kind of DurableSubscriber -> "durable_subscriber"; ProcessManagerConsumer -> "process_manager"),
          PText description.name,
          PText description.subscriptionName,
          case description.source of
            AllCategories -> PRecord "all" []
            ExactCategory category -> PRecord "category" [PText category]
            CategoryNamespace namespace -> PRecord "namespace" [PText namespace]
        ]

durableConsumerInventoryIdentity :: DurableConsumerRegistry -> Text
durableConsumerInventoryIdentity (DurableConsumerRegistry digest _) = digest

durableConsumersForCategory :: DurableConsumerRegistry -> CategoryName -> [DurableConsumerDescription]
durableConsumersForCategory (DurableConsumerRegistry _ descriptions) category =
  filter (consumerSourceMatches category . (.source)) descriptions
