module Main
  ( main
  )
where

import Keiro (version)
import Keiro.Prelude
import Test.Hspec

main :: IO ()
main = hspec $ do
  describe "Keiro" $ do
    it "exposes the scaffold version" $
      version `shouldBe` ("0.1.0.0" :: Text)
