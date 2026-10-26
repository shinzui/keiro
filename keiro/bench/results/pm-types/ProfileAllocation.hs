{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Diagnostic only: attribute discovery allocation without touching a store.
import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (forM_, void)
import Data.Aeson (encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Encoding qualified as Encoding
import Data.ByteString.Lazy qualified as Lazy
import Data.List (foldl')
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import GHC.Conc (getAllocationCounter)
import Jitsurei.Inspection (jitsureiProcessManagerInspectors)
import Keiro.ProcessManager.Inspect qualified as PM
import System.Mem (performMajorGC)

main :: IO ()
main = forM_ [1, 1000 :: Int] $ \count -> do
  let descriptor = snd (Map.findMin jitsureiProcessManagerInspectors)
      catalog = Map.fromList [(Text.pack ("alias-" <> show n), descriptor) | n <- [1 .. count]]
  forM_ (Map.elems catalog) $ \(PM.SomeProcessManagerInspector inspector) -> void (evaluate inspector.eventStream)
  let summaries = PM.listProcessManagerTypes catalog
  _ <- measure count "summaries" (evaluate (foldl' (\n s -> n + Text.length s.name + Text.length s.category + Text.length s.snapshotPolicy + if s.snapshotsConfigured then 1 else 0) 0 summaries))
  value <- measure count "json_value" (evaluate (force (object ["items" .= map PM.processManagerTypeJson summaries])))
  bytes <- measure count "encoding" (evaluate (Lazy.length (encode value)))
  putStrLn ("catalog=" <> show count <> " encoded_bytes=" <> show bytes)
  let direct = Encoding.encodingToLazyByteString (Encoding.pairs (Encoding.pair "items" (Aeson.toEncoding summaries)))
  directBytes <- measure count "direct_encoding" (evaluate (Lazy.length direct))
  if Aeson.eitherDecode direct == Right value && directBytes == bytes
    then putStrLn "direct_encoding_matches_canonical=true"
    else fail "direct encoding differs from canonical JSON"

measure :: Int -> String -> IO a -> IO a
measure count phase action = do
  performMajorGC
  before <- getAllocationCounter
  value <- action
  after <- getAllocationCounter
  putStrLn ("catalog=" <> show count <> " phase=" <> phase <> " allocated_bytes=" <> show (before - after))
  pure value
