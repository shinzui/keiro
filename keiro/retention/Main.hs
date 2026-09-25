{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import Control.Exception (evaluate)
import Control.Monad (unless, void)
import Retention.Measure
import Test.Hspec

main :: IO ()
main = do
  config <- gateConfigFromEnvironment
  hspec $ describe "Retention legs" $ do
    it "baseline-no-store" $ do
      (verdict, samples) <- measureLeg config "baseline-no-store" \index ->
        void (evaluate (sum (replicate 100 (index `mod` 17))))
      unless config.reportOnly $ do
        verdict `shouldBe` Bounded
        let (_, _, growth) = judge config samples
        growth `shouldSatisfy` (< 512 * 1024)
