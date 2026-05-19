module Main
  ( main
  )
where

import Codd (VerifySchemas (LaxCheck))
import Codd.Environment (getCoddSettings)
import Data.Time (secondsToDiffTime)
import Keiro.Migrations (runAllKeiroMigrations, runAllKeiroMigrationsNoCheck)
import System.Environment (lookupEnv)

main :: IO ()
main = do
  settings <- getCoddSettings
  noCheck <- lookupEnv "KEIRO_MIGRATE_NO_CHECK"
  case noCheck of
    Just _ ->
      runAllKeiroMigrationsNoCheck settings (secondsToDiffTime 5)
    Nothing -> do
      _ <- runAllKeiroMigrations settings (secondsToDiffTime 5) LaxCheck
      pure ()
