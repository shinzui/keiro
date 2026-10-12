{-# LANGUAGE OverloadedStrings #-}

-- Build in the Nix shell of mori://shinzui/keiro-runtime-kenshou with
-- cabal exec -- ghc -XImportQualifiedPost -package kenshou-remote SCRIPT -o EXECUTABLE.
-- This adapter uses that project's existing health replay implementation.

import Control.Monad (forM)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text qualified as Text
import Kenshou.Core.Id (parseRunId)
import Kenshou.Remote.Perf.Conditions (validateCellConditions, validateCellObservations)
import System.Environment (getArgs)
import System.FilePath ((</>))

field key (Object value) = maybe (fail "missing field") pure (KeyMap.lookup key value)
field _ _ = fail "expected object"

textField key value = field key value >>= \v -> case v of String t -> pure t; _ -> fail "expected string"

readJson path = either fail pure =<< eitherDecodeFileStrict' path

require = either (fail . Text.unpack) pure

main = do
  [tree, descriptorFile, policyFile] <- getArgs
  descriptor <- readJson descriptorFile
  policy <- readJson policyFile
  manifest <- readJson (tree </> "manifest.json")
  runId <- require . parseRunId =<< textField "runId" manifest
  cell <- textField "cell" manifest
  expectedCell <- textField "name" descriptor
  if cell == expectedCell then pure () else fail "descriptor and manifest cells differ"
  version <- textField "agentVersion" manifest
  instances <- field "instances" descriptor
  images <- field "images" descriptor
  drivers <- field "drivers" instances
  driver <- case drivers of
    Array values -> case foldr (:) [] values of
      [String t] -> pure t
      _ -> fail "expected one driver"
    _ -> fail "expected one driver"
  postgres <- textField "postgres" instances
  monitoring <- textField "monitoring" instances
  health <- readJson (tree </> "cell/health.json")
  reset <- readJson (tree </> "cell/reset-evidence.json")
  interval <- readJson (tree </> "cell/execution-window.json")
  windows <- forM [("driver", driver), ("postgres", postgres), ("monitoring", monitoring)] $ \(role, machine) -> do
    image <- textField (fromStringKey role) images
    raw <- readJson (tree </> "cell/observations" </> role <> ".json")
    pure (Text.pack role, machine, image, raw)
  require (validateCellConditions runId cell [driver, postgres, monitoring] health reset)
  require (validateCellObservations runId version policy health interval windows)
  putStrLn "Sealed cold reset, health gates and continuous raw role observations independently pass Kenshou validation."

fromStringKey = Key.fromString
