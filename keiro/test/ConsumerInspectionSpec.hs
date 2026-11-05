module ConsumerInspectionSpec (spec) where

import Data.Either (isLeft)
import Keiro.Inspection.Consumers
import Kiroku.Store.Types (CategoryName (..))
import Test.Hspec

spec :: Spec
spec = describe "category consumers durable metadata" $ do
  it "uses declared inputs rather than the manager's fulfillment journal" $ do
    let manager = DurableConsumerDescription ProcessManagerConsumer "fulfillment" "order-input" (ExactCategory "order")
    Right registry <- pure (durableConsumerRegistry [manager])
    durableConsumersForCategory registry (CategoryName "order") `shouldBe` [manager]
    durableConsumersForCategory registry (CategoryName "fulfillment") `shouldBe` []
    durableConsumersForCategory registry (CategoryName "Order") `shouldBe` []
  it "matches literal namespaces at colon boundaries and all categories" $ do
    let namespace = DurableConsumerDescription DurableSubscriber "namespace" "ns" (CategoryNamespace "pm")
        all = DurableConsumerDescription DurableSubscriber "all" "all" AllCategories
    Right registry <- pure (durableConsumerRegistry [namespace, all])
    mapM_ (\category -> durableConsumersForCategory registry (CategoryName category) `shouldBe` [all, namespace]) ["pm", "pm:orders", "pm:orders:child"]
    mapM_ (\category -> durableConsumersForCategory registry (CategoryName category) `shouldBe` [all]) ["pmm", "PM", "orders"]
  it "coalesces duplicates, permits shared subscriptions, and orders independent of declarations" $ do
    let first = DurableConsumerDescription DurableSubscriber "a" "shared" (ExactCategory "order")
        second = DurableConsumerDescription ProcessManagerConsumer "b" "shared" (ExactCategory "order")
        third = DurableConsumerDescription DurableSubscriber "a" "second" AllCategories
    Right registry <- pure (durableConsumerRegistry [second, first, third, first])
    durableConsumerRegistry [third, second, first] `shouldBe` Right registry
    durableConsumersForCategory registry (CategoryName "order") `shouldBe` [third, first, second]
    durableConsumerRegistry [first, second {source = ExactCategory "invoice"}]
      `shouldBe` Left (ConflictingSubscriptionScope "shared")
    Right changed <- pure (durableConsumerRegistry [first {name = "changed"}])
    durableConsumerInventoryIdentity changed `shouldNotBe` durableConsumerInventoryIdentity registry
  it "rejects blank identities and invalid scopes and permits explicitly empty registries" $ do
    let valid = DurableConsumerDescription DurableSubscriber "consumer" "subscription" AllCategories
    mapM_
      (\description -> durableConsumerRegistry [description] `shouldSatisfy` isLeft)
      [valid {name = ""}, valid {name = " c"}, valid {subscriptionName = " "}, valid {source = ExactCategory ""}, valid {source = ExactCategory "order "}, valid {source = CategoryNamespace " pm"}]
    Right empty <- pure (durableConsumerRegistry [])
    durableConsumersForCategory empty (CategoryName "order") `shouldBe` []
