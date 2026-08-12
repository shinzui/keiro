{-# OPTIONS_GHC -Wno-deprecations #-}

module ReadModelSpec
  ( spec,
  )
where

import Keiro.Prelude
import Keiro.ReadModel
import Kiroku.Store.Types (GlobalPosition (..))
import Test.Hspec

spec :: Spec
spec = describe "truthful read-model construction" $ do
  it "builds an immediate inline model without exposing a durable cursor" $ do
    let readModel = immediateReadModel (blueprint NoQueryCursor)
    readModelCursorAuthority readModel `shouldBe` NoQueryCursor
    readModelDefaultFreshness readModel `shouldBe` Immediate

  it "allows an immediate model to retain a cursor for per-call waits" $ do
    let readModel = immediateReadModel (blueprint (DurableQueryCursor "query-cursor"))
    readModelCursorAuthority readModel
      `shouldBe` DurableQueryCursor "query-cursor"
    readModelDefaultFreshness readModel `shouldBe` Immediate

  it "rejects waiting defaults without a durable cursor" $ do
    case headWaitingReadModel EntireVisibleLog (blueprint NoQueryCursor) of
      Left err ->
        err
          `shouldBe` ReadModelDefinitionMissingCursor "truthful-model" (WaitForHead EntireVisibleLog)
      Right _ -> expectationFailure "expected missing-cursor failure"
    case positionWaitingReadModel concretePositionOptions (blueprint NoQueryCursor) of
      Left err ->
        err
          `shouldBe` ReadModelDefinitionMissingCursor "truthful-model" (WaitForPosition concretePositionOptions)
      Right _ -> expectationFailure "expected missing-cursor failure"

  it "rejects a position-waiting default without a concrete target" $ do
    case positionWaitingReadModel defaultHeadWaitOptions (blueprint (DurableQueryCursor "query-cursor")) of
      Left err -> err `shouldBe` ReadModelDefinitionMissingPosition "truthful-model"
      Right _ -> expectationFailure "expected missing-position failure"

  it "round-trips honest waiting defaults through the compatibility record" $ do
    case headWaitingReadModel
      (CategoryVisibleHead "orders")
      (blueprint (DurableQueryCursor "query-cursor")) of
      Right readModel ->
        readModelDefaultFreshness readModel
          `shouldBe` WaitForHead (CategoryVisibleHead "orders")
      Left err -> expectationFailure (show err)
    case positionWaitingReadModel
      concretePositionOptions
      (blueprint (DurableQueryCursor "query-cursor")) of
      Right readModel ->
        readModelDefaultFreshness readModel
          `shouldBe` WaitForPosition concretePositionOptions
      Left err -> expectationFailure (show err)

  it "normalizes the historical no-target position wait to immediate" $ do
    let legacy =
          (immediateReadModel (blueprint (DurableQueryCursor "query-cursor")))
            { defaultConsistency = PositionWait defaultHeadWaitOptions
            }
    readModelDefaultFreshness legacy `shouldBe` Immediate

blueprint :: QueryCursorAuthority -> ReadModelBlueprint () ()
blueprint authority =
  ReadModelBlueprint
    { name = "truthful-model",
      tableName = "truthful_model",
      schema = "public",
      version = 1,
      shapeHash = "truthful-model-v1",
      cursorAuthority = authority,
      query = \() -> pure ()
    }

concretePositionOptions :: PositionWaitOptions
concretePositionOptions =
  PositionWaitOptions
    { target = Just (GlobalPosition 42),
      timeoutMicros = 5000000,
      pollMicros = 10000
    }
