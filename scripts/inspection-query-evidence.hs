{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Run in nix develop after building the libraries:
-- cabal exec -- runghc -XGHC2024 -package=keiro -package=keiro-test-support scripts/inspection-query-evidence.hs OUTPUT_DIRECTORY
-- Uses only uniquely cloned, durable PostgreSQL fixtures. EXPLAIN executes the
-- actual prepared statement installed by the supported inspection read.
import Control.Exception (bracket)
import Control.Monad (forM_, unless, void)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.Inspection.Cursor
import Keiro.Test.Postgres
import Keiro.Workflow.Inspection
import Kiroku.Store.Connection
import Kiroku.Store.Effect (runStoreIO)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.FilePath ((</>))

main :: IO ()
main = do
  [output] <- getArgs
  createDirectoryIfMissing True output
  withMigratedBenchmarkSuite $ \fixture -> forM_ [10000, 100000] $ \count ->
    withFreshDatabase fixture $ \url -> do
      execute url ("INSERT INTO keiro.keiro_workflows(workflow_id,workflow_name,status,created_at,updated_at) SELECT 'w-'||lpad(n::text,8,'0'),CASE WHEN n<=" <> number (count * 9 `div` 10) <> " THEN 'hot' ELSE 'small' END,CASE WHEN n%1000=0 THEN 'failed' ELSE 'running' END,'2026-10-01 00:00:00+00'::timestamptz+(n/1000)*interval '1 minute','2026-10-01 00:00:00+00'::timestamptz FROM generate_series(1," <> number count <> ") n; ANALYZE keiro.keiro_workflows")
      forM_ ["force_custom_plan", "force_generic_plan"] $ \mode ->
        forM_ (cases count) $ \(label, query, arguments) ->
          withStore (defaultConnectionSettings url) {poolSize = 1} $ \store -> do
            use store (Session.script ("SET plan_cache_mode='" <> mode <> "'"))
            durable <- use store (Session.statement () (Statement.preparable "SELECT current_setting('fsync')='on' AND current_setting('synchronous_commit')='on' AND current_setting('full_page_writes')='on' AND current_setting('autovacuum')='on'" E.noParams (D.singleRow (D.column (D.nonNullable D.bool)))))
            unless durable (fail "inspection evidence requires normal durable settings")
            _ <- runStoreIO store (listWorkflowInstancesPage query) >>= right >>= right
            prepared <- use store (Session.statement () (Statement.preparable "SELECT name,statement FROM pg_prepared_statements WHERE statement LIKE 'WITH inspection_page%'" E.noParams (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text)))))
            (name, sql) <- case prepared of [entry] -> pure entry; _ -> fail ("expected one actual inspection statement, got " <> show prepared)
            let explain = "EXPLAIN (ANALYZE,BUFFERS,SETTINGS,FORMAT JSON) EXECUTE \"" <> Text.replace "\"" "\"\"" name <> "\"(" <> arguments <> ")"
            plan <- use store (Session.statement () (Statement.preparable explain E.noParams (D.singleRow (D.column (D.nonNullable D.json)))))
            let artifact = object ["rows" .= count, "mode" .= mode, "case" .= label, "sql" .= sql, "arguments" .= arguments, "plan" .= (plan :: Value)]
                path = output </> Text.unpack (number count <> "-" <> mode <> "-" <> label) <> ".json"
            Lazy.writeFile path (Aeson.encode artifact)
            putStrLn path

number :: Int -> Text
number = Text.pack . show

cases :: Int -> [(Text, WorkflowListQuery, Text)]
cases count =
  [ ("key-first", base, "21"),
    ("key-deep", base {cursor = Just (encodeCursor "wf-key" ("hot" :: Text, deepId))}, "'hot','" <> deepId <> "',21"),
    ("created-first", base {ordering = ByCreatedDesc}, "21"),
    ("created-deep", base {ordering = ByCreatedDesc, cursor = Just (encodeCursor "wf-created" (deepTime, "hot" :: Text, deepId))}, "'" <> Text.pack (show deepTime) <> "'::timestamptz,'hot','" <> deepId <> "',21"),
    ("rare-status", base {classes = Just (ClassFailed :| [])}, "ARRAY['failed']::text[],ARRAY['failed']::text[],21"),
    ("absent-name", base {workflowName = Just "absent"}, "'absent',21"),
    ("small-name", base {workflowName = Just "small"}, "'small',21"),
    ("update-window", base {updatedSince = Just (read "2026-10-02 00:00:00 UTC")}, "'2026-10-02'::timestamptz,21")
  ]
  where
    base :: WorkflowListQuery
    base = defaultWorkflowListQuery {pageSize = 20}
    deep = count * 8 `div` 10
    deepId = "w-" <> Text.justifyRight 8 '0' (number deep)
    deepTime = addUTCTime (fromIntegral (deep `div` 1000 * 60)) (read "2026-10-01 00:00:00 UTC" :: UTCTime)

use :: KirokuStore -> Session.Session a -> IO a
use store session = Pool.use store.pool session >>= right

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

execute :: Text -> Text -> IO ()
execute url sql = bracket (Connection.acquire (Settings.connectionString url) >>= right) Connection.release $ \connection ->
  void (Connection.use connection (Session.script sql) >>= right)
