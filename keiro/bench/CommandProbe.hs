{-# LANGUAGE OverloadedStrings #-}

-- | Inspect the actual stream-read prepared plan on a disposable benchmark store.
module CommandProbe (commandPlanProbe) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.Text qualified as Text
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Keiro.Prelude
import Kiroku.Store qualified as Store
import Kiroku.Store.SQL qualified as SQL
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
          "SELECT jsonb_build_object('streams',(SELECT count(*) FROM streams),'events',(SELECT count(*) FROM events),'stream_events',(SELECT count(*) FROM stream_events),'relation_bytes',pg_total_relation_size('stream_events'))"
          E.noParams
          (D.singleRow (D.column (D.nonNullable D.jsonb)))
    pure (Aeson.object ["label" Aeson..= label, "counts" Aeson..= (counts :: Aeson.Value), "plan" Aeson..= (plan :: Aeson.Value)])
  either (fail . show) (Lazy.putStrLn . Aeson.encode) outcome
