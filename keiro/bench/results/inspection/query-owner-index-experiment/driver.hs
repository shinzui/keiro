{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Actual supported detail-page statements on durable disposable clones. The
-- optional page indexes are experimental until their write cost is measured.
import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
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
import Keiro.Workflow.Types (WorkflowId (..), WorkflowName (..))
import Kiroku.Store.Connection
import Kiroku.Store.Effect (runStoreIO)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.FilePath ((</>))

main :: IO ()
main = do
  [output] <- getArgs
  createDirectoryIfMissing True output
  withMigratedBenchmarkSuite $ \fixture -> forM_ [10000, 100000 :: Int] $ \count ->
    withFreshDatabase fixture $ \url -> do
      let owner = "CASE WHEN n<=" <> number count <> " THEN 'hot' ELSE 'small' END"
          created = "'2026-10-01 00:00:00+00'::timestamptz+(n/1000)*interval '1 minute'"
      execute url ("INSERT INTO keiro.keiro_workflow_children(child_id,child_name,parent_id,parent_name,await_step,created_at) SELECT 'c-'||lpad(n::text,8,'0'),'child'," <> owner <> ",'owner','await-'||n," <> created <> " FROM generate_series(1," <> number (count + count `div` 10) <> ") n")
      execute url ("INSERT INTO keiro.keiro_awakeables(awakeable_id,owner_workflow_name,owner_workflow_id,created_at) SELECT ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'owner'," <> owner <> "," <> created <> " FROM generate_series(1," <> number (count + count `div` 10) <> ") n")
      execute url "ANALYZE keiro.keiro_workflow_children; ANALYZE keiro.keiro_awakeables"
      forM_ [False, True] $ \indexed -> do
        if indexed
          then execute url "CREATE INDEX inspection_experiment_child_page ON keiro.keiro_workflow_children(parent_id,parent_name,created_at,child_id,child_name); CREATE INDEX inspection_experiment_awakeable_page ON keiro.keiro_awakeables(owner_workflow_name,owner_workflow_id,created_at,awakeable_id)"
          else pure ()
        forM_ ["force_custom_plan", "force_generic_plan"] $ \mode ->
          forM_ ["children", "awakeables"] $ \domain ->
            forM_ ["first", "deep", "absent"] $ \label ->
              withStore (defaultConnectionSettings url) {poolSize = 1} $ \store -> do
                use store (Session.script ("SET plan_cache_mode='" <> mode <> "'"))
                let ownerId = if label == "absent" then "absent" else "hot"
                    deep = count * 8 `div` 10
                    deepTime = addUTCTime (fromIntegral (deep `div` 1000 * 60)) (read "2026-10-01 00:00:00 UTC" :: UTCTime)
                    child = "c-" <> Text.justifyRight 8 '0' (number deep)
                    awakeable = "00000000-0000-0000-0000-" <> Text.justifyRight 12 '0' (number deep)
                    token =
                      if label /= "deep"
                        then Nothing
                        else
                          Just $
                            if domain == "children"
                              then encodeCursor "wf-children" ("owner" :: Text, ownerId, (deepTime, child, "child" :: Text))
                              else encodeCursor "wf-awakeables" ("owner" :: Text, ownerId, (deepTime, awakeable))
                    query = OwnerPageQuery 20 token
                    baseArguments = if domain == "children" then "'" <> ownerId <> "','owner'" else "'owner','" <> ownerId <> "'"
                    cursorArguments = if label /= "deep" then "" else ",'" <> Text.pack (show deepTime) <> "'::timestamptz,'" <> (if domain == "children" then child <> "','child'" else awakeable <> "'::uuid")
                    arguments = baseArguments <> cursorArguments <> ",21"
                if domain == "children"
                  then runStoreIO store (listWorkflowChildrenPage (WorkflowName "owner") (WorkflowId ownerId) query) >>= right >>= right >> pure ()
                  else runStoreIO store (listWorkflowAwakeablesPage (WorkflowName "owner") (WorkflowId ownerId) query) >>= right >>= right >> pure ()
                let prefix = if domain == "children" then "SELECT child_id,%" else "SELECT awakeable_id,%"
                prepared <- use store (Session.statement prefix (Statement.preparable "SELECT name,statement FROM pg_prepared_statements WHERE statement LIKE $1" (E.param (E.nonNullable E.text)) (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text)))))
                (name, sql) <- case prepared of [entry] -> pure entry; _ -> fail ("expected one detail statement: " <> show prepared)
                plan <- use store (Session.statement () (Statement.preparable ("EXPLAIN (ANALYZE,BUFFERS,SETTINGS,FORMAT JSON) EXECUTE \"" <> Text.replace "\"" "\"\"" name <> "\"(" <> arguments <> ")") E.noParams (D.singleRow (D.column (D.nonNullable D.json)))))
                let artifact = object ["rows" .= (count + count `div` 10), "owner_rows" .= count, "mode" .= mode, "experimental_indexes" .= indexed, "domain" .= domain, "case" .= label, "sql" .= sql, "arguments" .= arguments, "plan" .= (plan :: Value)]
                    path = output </> Text.unpack (Text.intercalate "-" [number count, if indexed then "indexed" else "baseline", mode, domain, label]) <> ".json"
                Lazy.writeFile path (Aeson.encode artifact)
                putStrLn path

number :: Int -> Text
number = Text.pack . show

use :: KirokuStore -> Session.Session a -> IO a
use store session = Pool.use store.pool session >>= right

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

execute :: Text -> Text -> IO ()
execute url sql = bracket (Connection.acquire (Settings.connectionString url) >>= right) Connection.release $ \connection ->
  Connection.use connection (Session.script sql) >>= right
