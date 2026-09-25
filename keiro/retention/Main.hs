{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import Control.Monad (forM_, unless)
import Data.Text qualified as Text
import Keiro.Test.Postgres (withFreshResourceStore, withMigratedSuite)
import Retention.Legs (Leg (..), allLegs)
import Retention.Measure
import System.Environment (lookupEnv)
import Test.Hspec

main :: IO ()
main = do
  config <- gateConfigFromEnvironment
  selected <- selectLegs
  withMigratedSuite \fixture ->
    hspec $
      describe "Retention legs" $
        forM_ selected \leg ->
          it (Text.unpack leg.legName) $
            withFreshResourceStore fixture \handle -> do
              (verdict, samples) <- leg.run config handle
              unless (config.reportOnly || leg.legName == "command-long-history-verify-every") $ do
                verdict `shouldBe` Bounded
                whenBaseline leg.legName config samples

selectLegs :: IO [Leg]
selectLegs = do
  selected <- lookupEnv "KEIRO_RETENTION_LEGS"
  case selected of
    Nothing -> pure (filter ((/= "command-long-history-verify-every") . (.legName)) allLegs)
    Just raw -> do
      let names = fmap Text.strip (Text.splitOn "," (Text.pack raw))
          unknown = filter (`notElem` fmap (.legName) allLegs) names
      unless (not (null names) && all (not . Text.null) names && null unknown) $
        fail ("KEIRO_RETENTION_LEGS contains an unknown or empty leg: " <> show unknown)
      pure (filter (\leg -> leg.legName `elem` names) allLegs)

whenBaseline :: Text.Text -> GateConfig -> [HeapSample] -> Expectation
whenBaseline name config samples =
  if name == "baseline-no-store"
    then let (_, _, growth) = judge config samples in growth `shouldSatisfy` (< 512 * 1024)
    else pure ()
