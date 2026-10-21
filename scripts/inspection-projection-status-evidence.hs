{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Actual bounded status API on durable fixtures, outside the unit suite.
import Control.Monad (forM, unless)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString.Lazy qualified as Lazy
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.Inspection.Cursor
import Keiro.ReadModel.Rebuild
import Keiro.Test.Postgres
import Kiroku.Store.Connection
import Kiroku.Store.Effect (runStoreIO)
import System.Environment (getArgs)

main :: IO ()
main = do
  [output] <- getArgs
  samples <- withMigratedBenchmarkSuite $ \fixture -> forM [10000, 100000 :: Int] $ \count ->
    withFreshDatabase fixture $ \url -> withStore (defaultConnectionSettings url) {poolSize = 1} $ \store -> do
      settings <-
        use
          store
          ( Session.statement
              ()
              ( Statement.preparable
                  "SELECT jsonb_build_object('server_version',current_setting('server_version'),'fsync',current_setting('fsync'),'synchronous_commit',current_setting('synchronous_commit'),'full_page_writes',current_setting('full_page_writes'),'autovacuum',current_setting('autovacuum'))"
                  E.noParams
                  (D.singleRow (D.column (D.nonNullable D.jsonb)))
              )
          )
      durable <-
        use
          store
          ( Session.statement
              ()
              ( Statement.preparable
                  "SELECT current_setting('fsync')='on' AND current_setting('synchronous_commit')='on' AND current_setting('full_page_writes')='on' AND current_setting('autovacuum')='on'"
                  E.noParams
                  (D.singleRow (D.column (D.nonNullable D.bool)))
              )
          )
      unless durable (fail "requires durable settings and normal autovacuum")
      use store (Session.script ("INSERT INTO keiro.keiro_projection_rebuild_groups(group_id,slice_fingerprint,status) SELECT 'group-'||lpad(n::text,8,'0'),'fixture','live' FROM generate_series(1," <> number count <> ") n"))
      use store (Session.script "INSERT INTO keiro.keiro_projection_group_cursors(group_id,position_basis) SELECT group_id,'append' FROM keiro.keiro_projection_rebuild_groups")
      use store (Session.script "INSERT INTO keiro.keiro_read_models(name,version,shape_hash,status,rebuild_group_id) SELECT group_id||'-model-'||n,1,'shape','live',group_id FROM keiro.keiro_projection_rebuild_groups CROSS JOIN generate_series(1,3) n")
      use store (Session.script "INSERT INTO keiro.keiro_read_models(name,version,shape_hash,status,rebuild_group_id) SELECT 'hot-model-'||n,1,'shape','live','group-00000001' FROM generate_series(1,10000) n")
      use store (Session.script "ANALYZE keiro.keiro_projection_rebuild_groups; ANALYZE keiro.keiro_projection_group_cursors; ANALYZE keiro.keiro_read_models")
      forM ["force_custom_plan", "force_generic_plan"] $ \mode -> forM [False, True] $ \deep ->
        withStore (defaultConnectionSettings url) {poolSize = 1} $ \reader -> do
          use reader (Session.script ("SET plan_cache_mode='" <> mode <> "'"))
          let after = "group-" <> Text.justifyRight 8 '0' (number (count * 8 `div` 10))
              cursor = if deep then Just (encodeCursor projectionGroupsCursorKind ("projection_group_status_v1" :: Text, after)) else Nothing
              arguments = (if deep then "'" <> after <> "'" else "NULL") <> ",101"
          Right page <- runStoreIO reader (listProjectionGroupStatusesPage (ProjectionStatusPageRequest 100 cursor)) >>= right
          prepared <-
            use
              reader
              ( Session.statement
                  ()
                  ( Statement.preparable
                      "SELECT name,statement FROM pg_prepared_statements WHERE statement LIKE 'WITH inspection_groups AS MATERIALIZED%'"
                      E.noParams
                      (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text)))
                  )
              )
          (name, sql) <- case prepared of [entry] -> pure entry; _ -> fail ("expected status page statement: " <> show prepared)
          plan <-
            use
              reader
              ( Session.statement
                  ()
                  ( Statement.preparable
                      ("EXPLAIN (ANALYZE,BUFFERS,SETTINGS,FORMAT JSON) EXECUTE \"" <> Text.replace "\"" "\"\"" name <> "\"(" <> arguments <> ")")
                      E.noParams
                      (D.singleRow (D.column (D.nonNullable D.json)))
                  )
              )
          pure
            ( object
                [ "groups" .= count,
                  "models" .= (count * 3 + 10000),
                  "mode" .= mode,
                  "deep" .= deep,
                  "settings" .= (settings :: Value),
                  "sql" .= sql,
                  "arguments" .= arguments,
                  "returned" .= length page.items,
                  "plan" .= (plan :: Value)
                ]
            )
  Lazy.writeFile output (encode samples)

number :: Int -> Text
number = Text.pack . show

use :: KirokuStore -> Session.Session a -> IO a
use store session = Pool.use store.pool session >>= right

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure
