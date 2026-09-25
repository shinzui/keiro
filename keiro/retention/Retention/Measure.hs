{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Retention.Measure
  ( HeapSample (..),
    Verdict (..),
    GateConfig (..),
    gateConfigFromEnvironment,
    sampleHeap,
    judge,
    measureLeg,
    measureLegWithSampler,
    renderTable,
  )
where

import Control.Monad (forM_, unless)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (intercalate)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Data.Word (Word64)
import GHC.Conc (ThreadStatus (..), listThreads, threadStatus)
import GHC.Stats (GCDetails (..), RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Numeric (showFFloat)
import System.Environment (lookupEnv)
import System.Mem (performMajorGC)
import Text.Read (readMaybe)

data HeapSample = HeapSample
  { operations :: !Int,
    liveBytes :: !Word64,
    largeObjectBytes :: !Word64,
    threads :: !Int
  }
  deriving stock (Eq, Show)

data Verdict = Bounded | Retained
  deriving stock (Eq, Show)

data GateConfig = GateConfig
  { blocks :: !Int,
    blockSize :: !Int,
    warmupBlocks :: !Int,
    slopeFloorBytesPerOp :: !Double,
    growthFloorBytes :: !Word64,
    reportOnly :: !Bool
  }
  deriving stock (Eq, Show)

gateConfigFromEnvironment :: IO GateConfig
gateConfigFromEnvironment = do
  total <- positiveEnv "KEIRO_RETENTION_OPERATIONS" 1500
  requestedBlocks <- lookupEnv "KEIRO_RETENTION_BLOCKS"
  blockCount <- case requestedBlocks of
    Nothing ->
      case filter (\candidate -> total `mod` candidate == 0) [6 .. 12] of
        first : _ -> pure first
        [] -> fail "KEIRO_RETENTION_OPERATIONS needs a divisor from 6 to 12; set KEIRO_RETENTION_BLOCKS explicitly"
    Just _ -> positiveEnv "KEIRO_RETENTION_BLOCKS" 6
  unless (blockCount >= 6 && total `mod` blockCount == 0) $
    fail "retention probe requires at least 6 blocks and operations divisible by blocks"
  report <- maybe False (const True) <$> lookupEnv "KEIRO_RETENTION_REPORT_ONLY"
  pure
    GateConfig
      { blocks = blockCount,
        blockSize = total `div` blockCount,
        warmupBlocks = 1,
        slopeFloorBytesPerOp = 512,
        growthFloorBytes = 2 * 1024 * 1024,
        reportOnly = report
      }

positiveEnv :: String -> Int -> IO Int
positiveEnv name defaultValue = do
  raw <- lookupEnv name
  case raw of
    Nothing -> pure defaultValue
    Just value -> case readMaybe value of
      Just parsed | parsed > 0 -> pure parsed
      _ -> fail (name <> " must be a positive integer")

sampleHeap :: Int -> IO HeapSample
sampleHeap count = do
  enabled <- getRTSStatsEnabled
  unless enabled $ fail "keiro-retention requires RTS statistics; run with +RTS -T -RTS"
  performMajorGC
  stats <- getRTSStats
  statuses <- listThreads >>= traverse threadStatus
  let threadCount = length (filter isActive statuses)
  pure
    HeapSample
      { operations = count,
        liveBytes = gcdetails_live_bytes stats.gc,
        largeObjectBytes = gcdetails_large_objects_bytes stats.gc,
        threads = threadCount
      }
  where
    -- listThreads also returns finished Async handles that can remain
    -- reachable during a measurement loop. They are not running workers.
    isActive ThreadFinished = False
    isActive ThreadDied = False
    isActive _ = True

judge :: GateConfig -> [HeapSample] -> (Verdict, Double, Word64)
judge config allSamples =
  let kept = drop config.warmupBlocks allSamples
      xs = fmap (fromIntegral . (.operations)) kept :: [Double]
      ys = fmap (fromIntegral . (.liveBytes)) kept :: [Double]
      count = fromIntegral (length kept)
      xMean = sum xs / count
      yMean = sum ys / count
      numerator = sum (zipWith (\x y -> (x - xMean) * (y - yMean)) xs ys)
      denominator = sum (fmap (\x -> (x - xMean) ^ (2 :: Int)) xs)
      slope = if denominator == 0 then 0 else numerator / denominator
      growth = case kept of
        [] -> 0
        first : _ -> max 0 (toInteger (liveBytes (last kept)) - toInteger first.liveBytes)
      verdict = if slope > config.slopeFloorBytesPerOp && growth > toInteger config.growthFloorBytes then Retained else Bounded
   in (verdict, slope, fromInteger growth)

measureLeg :: GateConfig -> Text -> (Int -> IO ()) -> IO (Verdict, [HeapSample])
measureLeg config name operation =
  measureLegWithSampler config name \sample ->
    forM_ [1 .. config.blocks * config.blockSize] \index -> do
      operation index
      whenBlockEnd index sample
  where
    whenBlockEnd index sample =
      if index `mod` config.blockSize == 0 then sample index else pure ()

measureLegWithSampler :: GateConfig -> Text -> ((Int -> IO ()) -> IO ()) -> IO (Verdict, [HeapSample])
measureLegWithSampler config name drive = do
  samplesRef <- newIORef []
  drive \count -> do
    sample <- sampleHeap count
    modifyIORef' samplesRef (sample :)
  samples <- reverse <$> readIORef samplesRef
  let expected = fmap (* config.blockSize) [1 .. config.blocks]
  unless (fmap (.operations) samples == expected) $
    fail ("retention leg " <> Text.unpack name <> " sampled at unexpected operation counts: " <> show (fmap (.operations) samples))
  let result@(verdict, _, _) = judge config samples
  Text.IO.putStrLn (renderTable name config samples result)
  pure (verdict, samples)

renderTable :: Text -> GateConfig -> [HeapSample] -> (Verdict, Double, Word64) -> Text
renderTable name config samples (verdict, slope, growth) =
  Text.unlines $
    [ "leg=" <> name <> " operations=" <> decimal (config.blocks * config.blockSize) <> " blocks=" <> decimal config.blocks <> " block=" <> decimal config.blockSize,
      "block  ops  live_bytes  large_objects_bytes  threads"
    ]
      <> zipWith renderSample [1 :: Int ..] samples
      <> [ "slope=" <> Text.pack (show (round slope :: Int)) <> " B/op  growth=" <> Text.pack (showFFloat (Just 2) (fromIntegral growth / (1024 * 1024) :: Double) "") <> " MiB  verdict=" <> case verdict of
             Bounded -> "bounded"
             Retained -> "retained"
         ]
  where
    decimal = Text.pack . show
    renderSample block sample =
      Text.intercalate "  " [decimal block, decimal sample.operations, grouped sample.liveBytes, grouped sample.largeObjectBytes, decimal sample.threads]
    grouped number = Text.pack (reverse (intercalate "," (chunksOfThree (reverse (show number)))))
    chunksOfThree [] = []
    chunksOfThree digits = let (chunk, rest) = splitAt 3 digits in chunk : chunksOfThree rest
