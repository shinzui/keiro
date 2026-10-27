module Main (main) where

import Control.Concurrent.Async (wait)
import Data.Text qualified as Text
import Keiro.Ops (emptyAppHooks)
import Keiro.Ops.Http
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import System.Environment (getEnv)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  database <- Text.pack <$> getEnv "DATABASE_URL"
  withStore (defaultConnectionSettings database) $ \store -> do
    child <- opsApplication defaultOpsHttpConfig emptyAppHooks store
    app <-
      either (fail . show) pure $
        composeSurfaces defaultComposeConfig [MountedSurface keiroPrefix child]
    withOpsHttpServer defaultOpsHttpServerConfig {port = 0} app $ \server -> do
      print server.serverPort
      wait server.serverThread
