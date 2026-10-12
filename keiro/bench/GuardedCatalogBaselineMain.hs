{-# LANGUAGE BlockArguments #-}

module Main (main) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import GuardedCatalogWorkload
import Keiro.Test.Postgres
import System.Environment (getArgs)
import Prelude

-- Build this same harness against the recorded original library source. The
-- parent invokes it once per paired sample on an equivalent fresh database.
main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    [input, output] -> do
      config <- Lazy.readFile input >>= either fail pure . Aeson.eitherDecode
      withMigratedSuite \fixture -> withFreshResourceStore fixture \(_, runner) -> do
        prepareDatabase runner config
        result <- measureWorkload runner config (ordinaryAction runner (batchSize config))
        Lazy.writeFile output (Aeson.encode result)
    _ -> fail "usage: ordinary-baseline WORKLOAD.json RESULT.json"
