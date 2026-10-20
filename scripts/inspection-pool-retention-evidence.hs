{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Attribution probe, not the domain retention acceptance gate. Run each mode
-- in a fresh process: OUTPUT MODE SECONDS RATE, +RTS -N2 -T -RTS.
-- Pool.use's released implementation registers an acquisition timer even when
-- a connection is immediately available. Keep that default policy unchanged.
import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (unless, void, when)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stats (GCDetails (..), RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.Test.Postgres
import Kiroku.Store.Connection
import System.Environment (getArgs)
import System.IO (IOMode (WriteMode), hFlush, withFile)
import System.Mem (performMajorGC)
import Text.Read (readMaybe)

main :: IO ()
main = do
  (output, mode, seconds, rate) <-
    getArgs >>= \case
      [output, mode, rawSeconds, rawRate]
        | Just seconds <- readMaybe rawSeconds,
          Just rate <- readMaybe rawRate,
          seconds >= 30,
          mod seconds 5 == 0,
          rate > 0,
          rate <= 1000,
          elem mode ["pooled", "direct"] ->
            pure (output, mode, seconds, rate)
      _ -> fail "expected OUTPUT pooled|direct SECONDS_MULTIPLE_OF_5_AT_LEAST_30 RATE_1_TO_1000"
  getRTSStatsEnabled >>= \enabled -> unless enabled (fail "requires +RTS -T")
  withMigratedBenchmarkSuite $ \fixture -> withFreshDatabase fixture $ \url ->
    withStore (defaultConnectionSettings url) {poolSize = 1} $ \store ->
      bracket (Connection.acquire (Settings.connectionString url) >>= right) Connection.release $ \connection ->
        withFile output WriteMode $ \handle -> do
          let operation = void $ if mode == "pooled" then Pool.use store.pool probe >>= right else Connection.use connection probe >>= right
              emit value = Lazy.hPutStrLn handle (encode value) >> hFlush handle
              sample phase count = do
                performMajorGC
                stats <- getRTSStats
                emit (object ["phase" .= phase, "operations" .= count, "live_bytes" .= stats.gc.gcdetails_live_bytes, "large_object_bytes" .= stats.gc.gcdetails_large_objects_bytes, "allocated_bytes" .= stats.allocated_bytes])
          settings <- Connection.use connection (Session.statement () settingsStatement) >>= right
          emit (object ["mode" .= mode, "seconds" .= seconds, "rate" .= rate, "settings" .= settings])
          sample ("initial" :: Text.Text) (0 :: Int)
          started <- getMonotonicTimeNSec
          let loop n
                | n > seconds * rate = pure ()
                | otherwise = do
                    now <- getMonotonicTimeNSec
                    let due = started + fromIntegral (n - 1) * div 1000000000 (fromIntegral rate)
                    when (due > now) (threadDelay (fromIntegral (div (due - now) 1000)))
                    operation
                    when (mod n (5 * rate) == 0) (sample "running" n)
                    loop (n + 1)
          loop 1
          -- Default acquisition timeout is ten seconds in released 1.4.2.3.
          -- This drain diagnoses temporary timer roots without changing them.
          threadDelay 12000000
          sample "drained" (seconds * rate)

probe :: Session.Session Int
probe = Session.statement () (Statement.preparable "SELECT 1::bigint" E.noParams (D.singleRow (fromIntegral <$> D.column (D.nonNullable D.int8))))
{-# NOINLINE probe #-}

settingsStatement :: Statement.Statement () Value
settingsStatement = Statement.preparable "SELECT jsonb_build_object('server_version',current_setting('server_version'),'fsync',current_setting('fsync'),'synchronous_commit',current_setting('synchronous_commit'),'full_page_writes',current_setting('full_page_writes'),'autovacuum',current_setting('autovacuum'))" E.noParams (D.singleRow (D.column (D.nonNullable D.jsonb)))

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure
