{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Measure the ordinary hydration path only; no inspection requests run here.
-- Reuse the existing retention fixture rather than introducing another model.
import Control.Monad (replicateM, replicateM_, unless, void)
import Data.Aeson (Value (..), encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.List (sort)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stats (RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Keiro.Command qualified as Command
import Keiro.EventStream qualified as EventStream
import Keiro.EventStream.Validate (unvalidated)
import Keiro.Snapshot.Schema qualified as Snapshot
import Keiro.Stream qualified as Stream
import Keiro.Test.Postgres
import Kiroku.Store qualified as Store
import Kiroku.Store.Types (StreamVersion (..))
import Retention.Fixture
import System.Environment (getArgs)
import System.Mem (performMajorGC)

main :: IO ()
main = do
  [mode, output] <- getArgs
  unless (mode `elem` ["hit", "miss", "corrupt", "no-codec", "long"]) (fail "expected hit|miss|corrupt|no-codec|long OUTPUT")
  getRTSStatsEnabled >>= \enabled -> unless enabled (fail "requires +RTS -T")
  withMigratedBenchmarkSuite \fixture ->
    withFreshResourceStore fixture \(_, runner@(StoreRunner runStore)) -> do
      let count = if mode == "long" then 10000 else 100
          definition = unvalidated retentionLedger
          eventStream = if mode `elem` ["no-codec", "long"] then definition {EventStream.stateCodec = Nothing} else definition
          options = Command.defaultRunCommandOptions {Command.seedVerifySampleRate = 0}
          expected = StreamVersion (fromIntegral count)
          operation = do
            result <- runStore (Command.hydrate options eventStream ledgerTarget)
            case result of
              Right (Right hydrated) | hydrated.streamVersion == expected -> pure ()
              _ -> fail "ordinary hydration failed or returned the wrong version"
      if mode `elem` ["hit", "corrupt"] then seedLedger runner ledgerTarget count else seedLedgerRaw runner ledgerTarget count
      if mode == "corrupt"
        then do
          Right (Just sid) <- runStore (Store.lookupStreamId (Stream.streamName ledgerTarget))
          Right (Just row) <- runStore (Snapshot.lookupSnapshotRow sid)
          Right () <- runStore do
            Snapshot.writeSnapshotRow
              Snapshot.SnapshotWrite
                { streamId = sid,
                  streamVersion = row.streamVersion,
                  state = String "bad",
                  stateCodecVersion = row.stateCodecVersion,
                  regfileShapeHash = row.regfileShapeHash,
                  stateShapeHash = row.stateShapeHash
                }
          pure ()
        else pure ()
      replicateM_ 20 operation
      performMajorGC
      before <- getRTSStats
      let operations = 200 :: Int
      timings <- replicateM operations do
        start <- getMonotonicTimeNSec
        operation
        end <- getMonotonicTimeNSec
        pure (fromIntegral (end - start) / 1000 :: Double)
      performMajorGC
      after <- getRTSStats
      let ordered = sort timings
      Lazy.writeFile
        output
        ( encode
            ( object
                [ "mode" .= mode,
                  "operations" .= operations,
                  "allocated_bytes_per_operation" .= (fromIntegral (after.allocated_bytes - before.allocated_bytes) / fromIntegral operations :: Double),
                  "p50_us" .= (ordered !! 99),
                  "p95_us" .= (ordered !! 189)
                ]
            )
        )
