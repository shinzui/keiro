module Main (main) where

import Data.Aeson (object, (.=))
import Keiro.Ops.Env (selectConnectionString)
import Keiro.Ops.Render
import Test.Hspec

main :: IO ()
main = hspec do
  describe "selectConnectionString" do
    it "prefers the explicit option, then the Keiro variable, then DATABASE_URL" do
      selectConnectionString (Just "explicit") (Just "keiro") (Just "database")
        `shouldBe` "explicit"
      selectConnectionString Nothing (Just "keiro") (Just "database")
        `shouldBe` "keiro"
      selectConnectionString Nothing Nothing (Just "database")
        `shouldBe` "database"

    it "uses an empty libpq string for standard PG environment fallbacks" do
      selectConnectionString Nothing Nothing Nothing `shouldBe` ""

  describe "renderHuman" do
    it "aligns columns without changing the structured JSON value" do
      let result =
            OpsResult
              { headers = ["name", "status"],
                rows = [["short", "running"], ["longer", "failed"]],
                jsonValue = object ["items" .= (["unchanged"] :: [String])]
              }
      renderHuman result
        `shouldBe` "name    status \n------  -------\nshort   running\nlonger  failed \n"
