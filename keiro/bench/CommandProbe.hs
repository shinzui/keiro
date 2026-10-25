{-# LANGUAGE OverloadedStrings #-}

-- | Inspect the actual stream-read prepared plan on a disposable benchmark store.
module CommandProbe (commandPlanProbe, delegatedPlanProbe, tableResetProbe) where

import Control.Monad (replicateM)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.UUID qualified as UUID
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Keiro.Prelude
import Kiroku.Store qualified as Store
import Kiroku.Store.SQL qualified as SQL
import System.IO (stderr)
import "hasql-transaction" Hasql.Transaction qualified as Tx

commandPlanProbe :: Store.KirokuStore -> Text -> IO ()
commandPlanProbe store label = do
  outcome <- Store.runStoreIO store $ Store.runTransaction $ do
    _ <- Tx.statement ("bench-probe-absent", 0, 100) SQL.readStreamForwardStmt
    entries <-
      Tx.statement () $
        preparable
          "SELECT name FROM pg_prepared_statements WHERE statement LIKE 'SELECT e.event_id,%' AND statement LIKE '%FROM stream_events se%' AND statement LIKE '%s.stream_name = $1%' AND statement LIKE '%se.stream_version > $2%'"
          E.noParams
          (D.rowList (D.column (D.nonNullable D.text)))
    name <- case entries of
      [name] -> pure name
      _ -> error ("expected actual stream read statement: " <> show entries)
    plan <-
      Tx.statement () $
        preparable
          ("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) EXECUTE \"" <> Text.replace "\"" "\"\"" name <> "\"('bench-probe-absent',0,100)")
          E.noParams
          (D.singleRow (D.column (D.nonNullable D.json)))
    counts <-
      Tx.statement () $
        preparable
          "SELECT jsonb_build_object('streams',(SELECT count(*) FROM streams),'events',(SELECT count(*) FROM events),'stream_events',(SELECT count(*) FROM stream_events),'relation_bytes',pg_total_relation_size('stream_events'),'server_version',current_setting('server_version'),'fsync',current_setting('fsync'),'synchronous_commit',current_setting('synchronous_commit'),'full_page_writes',current_setting('full_page_writes'),'autovacuum',current_setting('autovacuum'))"
          E.noParams
          (D.singleRow (D.column (D.nonNullable D.jsonb)))
    pure (Aeson.object ["label" Aeson..= label, "counts" Aeson..= (counts :: Aeson.Value), "plan" Aeson..= (plan :: Aeson.Value)])
  either (fail . show) (Lazy.putStrLn . Aeson.encode) outcome

-- Reset alternatives use the same populated row count on isolated group stores.
tableResetProbe :: Store.KirokuStore -> Text -> Int -> IO () -> IO ()
tableResetProbe store table expected seed = do
  for_ ["TRUNCATE", "DELETE FROM"] $ \verb -> do
    samples <- replicateM 5 $ do
      seed
      before <- info
      unless (fst before == fromIntegral expected) (fail "reset probe seed count differs")
      started <- getMonotonicTimeNSec
      checked (Tx.sql (Text.encodeUtf8 (verb <> " " <> table)))
      ended <- getMonotonicTimeNSec
      after <- info
      unless (fst after == 0) (fail "reset probe retained rows")
      pure (Aeson.object ["elapsed_ns" Aeson..= (ended - started), "rows_before" Aeson..= fst before, "bytes_before" Aeson..= snd before, "rows_after" Aeson..= fst after, "bytes_after" Aeson..= snd after])
    Lazy.putStrLn (Aeson.encode (Aeson.object ["table" Aeson..= table, "reset" Aeson..= verb, "samples" Aeson..= samples]))
  where
    checked :: Tx.Transaction a -> IO a
    checked action = Store.runStoreIO store (Store.runTransaction action) >>= either (fail . show) pure
    info =
      checked
        ( Tx.statement
            ()
            ( preparable
                ("SELECT count(*), pg_total_relation_size('" <> table <> "') FROM " <> table)
                E.noParams
                (D.singleRow ((,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8)))
            )
        )

delegatedPlanProbe :: Store.KirokuStore -> Text -> IO ()
delegatedPlanProbe store label = do
  result <- Store.runStoreIO store $ Store.runTransaction $ do
    _ <- Tx.statement ("bench-probe-absent", UUID.nil) SQL.eventExistsInStreamStmt
    names <-
      Tx.statement () $
        preparable
          "SELECT name FROM pg_prepared_statements WHERE statement LIKE 'SELECT EXISTS (%' AND statement LIKE '%FROM stream_events se%' AND statement LIKE '%stream_name = $1%'"
          E.noParams
          (D.rowList (D.column (D.nonNullable D.text)))
    name <- case names of [name] -> pure name; _ -> error ("expected delegated prepared statement: " <> show names)
    plan <-
      Tx.statement () $
        preparable
          ("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) EXECUTE \"" <> Text.replace "\"" "\"\"" name <> "\"('bench-probe-absent','00000000-0000-0000-0000-000000000000'::uuid)")
          E.noParams
          (D.singleRow (D.column (D.nonNullable D.json)))
    pure (Aeson.object ["label" Aeson..= label, "plan" Aeson..= (plan :: Aeson.Value)])
  either (fail . show) (Lazy.hPutStrLn stderr . Aeson.encode) result
