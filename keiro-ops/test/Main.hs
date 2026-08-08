module Main (main) where

import Test.Hspec

main :: IO ()
main = hspec do
  describe "keiro-ops" do
    it "has a test-suite scaffold" do
      True `shouldBe` True
