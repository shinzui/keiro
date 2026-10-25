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
  (output, wideFixture) <-
    getArgs >>= \case
      [path] -> pure (path, False)
      [path, "wide"] -> pure (path, True)
      _ -> fail "expected OUTPUT_DIRECTORY [wide]"
  createDirectoryIfMissing True output
  withMigratedBenchmarkSuite $ \fixture -> forM_ [10000, 100000] $ \count ->
    withFreshDatabase fixture $ \url -> do
      let keyColumns =
            if wideFixture
              then "repeat('x',2700)||lpad(n::text,8,'0'),'wide'"
              else "'w-'||lpad(n::text,8,'0'),CASE WHEN n<=" <> number (count * 9 `div` 10) <> " THEN 'hot' ELSE 'small' END"
      execute url ("INSERT INTO keiro.keiro_workflows(workflow_id,workflow_name,status,created_at,updated_at) SELECT " <> keyColumns <> ",CASE WHEN n%1000=0 THEN 'failed' ELSE 'running' END,'2026-10-01 00:00:00+00'::timestamptz+(n/1000)*interval '1 minute','2026-10-01 00:00:00+00'::timestamptz FROM generate_series(1," <> number count <> ") n")
      unless wideFixture $ execute url "WITH bytes AS (SELECT string_agg(md5(n::text),'') value FROM generate_series(1,120) n) INSERT INTO keiro.keiro_workflows(workflow_id,workflow_name,status) SELECT left(value,2668)||lpad(n::text,2,'0'),'wide',CASE n WHEN 1 THEN 'running' ELSE 'failed' END FROM bytes CROSS JOIN generate_series(1,2) n"
      execute url "ANALYZE keiro.keiro_workflows"
      forM_ ["force_custom_plan", "force_generic_plan"] $ \mode ->
        forM_ (cases count wideFixture) $ \(label, query, arguments) ->
          withStore (defaultConnectionSettings url) {poolSize = 1} $ \store -> do
            use store (Session.script ("SET plan_cache_mode='" <> mode <> "'"))
            durable <- use store (Session.statement () (Statement.preparable "SELECT current_setting('fsync')='on' AND current_setting('synchronous_commit')='on' AND current_setting('full_page_writes')='on' AND current_setting('autovacuum')='on'" E.noParams (D.singleRow (D.column (D.nonNullable D.bool)))))
            unless durable (fail "inspection evidence requires normal durable settings")
            settings <- use store (Session.statement () (Statement.preparable "SELECT jsonb_build_object('fsync',current_setting('fsync'),'synchronous_commit',current_setting('synchronous_commit'),'full_page_writes',current_setting('full_page_writes'),'autovacuum',current_setting('autovacuum'),'server_version',current_setting('server_version'))" E.noParams (D.singleRow (D.column (D.nonNullable D.jsonb)))))
            result <- runStoreIO store (listWorkflowInstancesPage query) >>= right
            case result of
              Left CursorResultTooLarge -> pure ()
              Left err -> fail (show err)
              Right _ -> pure ()
            prepared <- use store (Session.statement () (Statement.preparable "SELECT name,statement FROM pg_prepared_statements WHERE statement LIKE '/* keiro-inspection-page-v2 */%'" E.noParams (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text)))))
            (name, sql) <- case prepared of [entry] -> pure entry; _ -> fail ("expected one actual inspection statement, got " <> show prepared)
            let explain = "EXPLAIN (ANALYZE,BUFFERS,SETTINGS,FORMAT JSON) EXECUTE \"" <> Text.replace "\"" "\"\"" name <> "\"(" <> arguments <> ")"
            plan <- use store (Session.statement () (Statement.preparable explain E.noParams (D.singleRow (D.column (D.nonNullable D.json)))))
            let artifact = object ["rows" .= count, "wide_fixture" .= wideFixture, "settings" .= (settings :: Value), "rows_returned" .= (case result of Left _ -> 0; Right page -> length page.items), "result" .= (case result of Left _ -> "cursor_result_too_large" :: Text; Right _ -> "ok"), "mode" .= mode, "indexes" .= ("current migrations" :: Text), "case" .= label, "sql" .= sql, "arguments" .= arguments, "plan" .= (plan :: Value)]
                path = output </> Text.unpack (number count <> "-" <> mode <> "-" <> label) <> ".json"
            Lazy.writeFile path (Aeson.encode artifact)
            putStrLn path

number :: Int -> Text
number = Text.pack . show

cases :: Int -> Bool -> [(Text, WorkflowListQuery, Text)]
cases count wideFixture =
  [ ("key-first", base, "21"),
    ("key-past-wide", base {cursor = Just (encodeCursor "wf-key2" ("zzzz" :: Text, "zzzz" :: Text))}, "'zzzz','zzzz',21"),
    ("key-deep", base {cursor = Just (encodeCursor "wf-key2" (deepId, deepName))}, "'" <> deepId <> "','" <> deepName <> "',21"),
    ("created-first", base {ordering = ByCreatedDesc}, "21"),
    ("created-deep", base {ordering = ByCreatedDesc, cursor = Just (encodeCursor "wf-created" (deepTime, deepName, deepId))}, "'" <> Text.pack (show deepTime) <> "'::timestamptz,'" <> deepName <> "','" <> deepId <> "',21"),
    ("rare-status", base {classes = Just (ClassFailed :| [])}, "21"),
    ("absent-class", base {classes = Just (ClassRetrying :| [])}, "21"),
    ("absent-name", base {workflowName = Just "absent"}, "'absent',21"),
    ("small-name", base {workflowName = Just "small"}, "'small',21"),
    ("running-class", base {classes = Just (ClassRunning :| [])}, "21"),
    ("mixed-class", base {classes = Just (ClassFailed :| [ClassRunning, ClassFailed])}, "21"),
    ("rare-status-deep", base {classes = Just (ClassFailed :| []), cursor = Just (encodeCursor "wf-key2" (deepId, deepName))}, "'" <> deepId <> "','" <> deepName <> "',21"),
    ("small-name-rare", base {workflowName = Just "small", classes = Just (ClassFailed :| [])}, "'small',21"),
    ("created-window", base {ordering = ByCreatedDesc, createdSince = Just deepTime}, "'" <> Text.pack (show deepTime) <> "'::timestamptz,21"),
    ("created-rare-status", base {ordering = ByCreatedDesc, classes = Just (ClassFailed :| [])}, "21"),
    ("wide-name", base {workflowName = Just "wide"}, "'wide',21"),
    ("update-window", base {updatedSince = Just (read "2026-10-02 00:00:00 UTC")}, "'2026-10-02'::timestamptz,21")
  ]
  where
    base :: WorkflowListQuery
    base = defaultWorkflowListQuery {pageSize = 20}
    deep = count * 8 `div` 10
    deepName = if wideFixture then "wide" else "hot"
    deepId = (if wideFixture then Text.replicate 2700 "x" else "w-") <> Text.justifyRight 8 '0' (number deep)
    deepTime = addUTCTime (fromIntegral (deep `div` 1000 * 60)) (read "2026-10-01 00:00:00 UTC" :: UTCTime)

use :: KirokuStore -> Session.Session a -> IO a
use store session = Pool.use store.pool session >>= right

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

execute :: Text -> Text -> IO ()
execute url sql = bracket (Connection.acquire (Settings.connectionString url) >>= right) Connection.release $ \connection ->
  void (Connection.use connection (Session.script sql) >>= right)
