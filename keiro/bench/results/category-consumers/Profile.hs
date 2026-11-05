{-# LANGUAGE OverloadedStrings #-}

-- Store-free, single-response cost probe. This is not a writer interference test.
-- Run from the repository root using the command in README.md.
module Main (main) where

import Control.Exception (evaluate)
import Control.Monad (unless)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import GHC.Conc (getAllocationCounter)
import Keiro.Inspection.Consumers
import Keiro.Ops.Http.Budget (encodeBoundedEncoding)
import Keiro.Ops.Projection
import Keiro.Ops.Render (OpsResult (..))
import System.Mem (performMajorGC)

main :: IO ()
main = do
  (registry, mountBytes) <- allocated $ do
    let descriptions =
          [ DurableConsumerDescription
              DurableSubscriber
              ("consumer-" <> Text.justifyRight 4 '0' (Text.pack (show n)))
              ("subscription-" <> Text.pack (show n) <> suffix)
              (ExactCategory "order")
          | n <- [1 .. 1000 :: Int],
            suffix <- ["-a", "-b"]
          ]
    registry <- either (fail . show) pure (durableConsumerRegistry descriptions)
    _ <- evaluate (Text.length (durableConsumerInventoryIdentity registry))
    pure registry
  putStrLn ("registry: 1000 consumers, 2000 bindings; construction_allocated=" <> show mountBytes)
  ((result, bytes), directBytes) <- allocated $ do
    (result, encoding) <- either (fail . show) pure (prepareConsumers Nothing (Just registry) (ConsumersOptions "order" 500 Nothing))
    _ <- evaluate result
    body <- encodeBoundedEncoding 1048576 encoding >>= maybe (fail "maximum page refused") pure
    _ <- evaluate (Lazy.length body)
    pure (result, body)
  putStrLn ("maximum_page: 500 items, 1000 bindings; encoded_bytes=" <> show (Lazy.length bytes) <> "; direct_path_allocated=" <> show directBytes)
  (_, canonicalBytes) <- allocated $ evaluate (Lazy.length (Aeson.encode (jsonValue result)))
  putStrLn ("canonical_value_and_generic_encoding_allocated=" <> show canonicalBytes)
  unless (Aeson.eitherDecode bytes == Right (jsonValue result)) (fail "direct/canonical mismatch")
  putStrLn "direct/canonical parity: passed"

allocated :: IO a -> IO (a, Integer)
allocated action = do
  performMajorGC
  before <- getAllocationCounter
  value <- action
  after <- getAllocationCounter
  pure (value, toInteger before - toInteger after)
