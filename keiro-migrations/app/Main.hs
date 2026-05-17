module Main
  ( main
  )
where

import Codd (VerifySchemas (LaxCheck))
import Codd.Environment (getCoddSettings)
import Data.Time (secondsToDiffTime)
import Keiro.Migrations (runAllKeiroMigrations)

main :: IO ()
main = do
  settings <- getCoddSettings
  _ <- runAllKeiroMigrations settings (secondsToDiffTime 5) LaxCheck
  pure ()
