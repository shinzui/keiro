{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Query-shape prototype only. This is not the supported library read and
-- cannot establish acceptance until the owner integrates the shape and repeats
-- the actual-API experiment. Every index lives only in a disposable clone.
import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.Test.Postgres
import Keiro.Workflow.Inspection (WorkflowStatusClass (..), statusClassToText)
import Kiroku.Store.Connection
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.FilePath ((</>))

main :: IO ()
main = do
  [output] <- getArgs
  createDirectoryIfMissing True output
  withMigratedBenchmarkSuite $ \fixture -> forM_ [10000, 100000 :: Int] $ \count ->
    withFreshDatabase fixture $ \url -> do
      execute url ("INSERT INTO keiro.keiro_workflows(workflow_id,workflow_name,status) SELECT 'w-'||lpad(n::text,8,'0'),CASE WHEN n<=" <> number (count * 9 `div` 10) <> " THEN 'hot' ELSE 'small' END,CASE WHEN n%1000=0 THEN 'failed' ELSE 'running' END FROM generate_series(1," <> number count <> ") n")
      execute url ("CREATE INDEX inspection_experiment_class_key ON keiro.keiro_workflows ((" <> statusCase <> "),workflow_name,workflow_id); ANALYZE keiro.keiro_workflows")
      forM_ ["force_custom_plan", "force_generic_plan"] $ \mode ->
        withStore (defaultConnectionSettings url) {poolSize = 1} $ \store -> do
          use store (Session.script ("SET plan_cache_mode='" <> mode <> "'; PREPARE inspection_branch_probe(int4,int4) AS " <> querySql))
          forM_ [("all", 127), ("running", 1), ("rare-failed", 64), ("absent-retrying", 2)] $ \(label, mask) -> do
            plan <- use store (Session.statement () (Statement.preparable ("EXPLAIN (ANALYZE,BUFFERS,SETTINGS,FORMAT JSON) EXECUTE inspection_branch_probe(" <> number mask <> ",21)") E.noParams (D.singleRow (D.column (D.nonNullable D.json)))))
            let artifact = object ["prototype" .= True, "rows" .= count, "mode" .= mode, "case" .= label, "mask" .= mask, "sql" .= querySql, "plan" .= (plan :: Value)]
                path = output </> Text.unpack (number count <> "-" <> mode <> "-" <> label) <> ".json"
            Lazy.writeFile path (Aeson.encode artifact)
            putStrLn path

statusCase :: Text
statusCase = "CASE WHEN status='running' AND attempts=0 THEN 'running' WHEN status='running' THEN 'retrying' WHEN status='suspended' AND wake_after IS NOT NULL THEN 'sleeping' WHEN status='suspended' THEN 'awaiting' ELSE status END"

querySql :: Text
querySql =
  "WITH inspection_page AS MATERIALIZED (SELECT * FROM ("
    <> Text.intercalate " UNION ALL " branches
    <> ") AS candidates ORDER BY workflow_name,workflow_id LIMIT $2) SELECT now(),inspection_page.* FROM (VALUES(1)) AS clock(x) LEFT JOIN inspection_page ON true ORDER BY workflow_name,workflow_id"
  where
    columns = "workflow_id,workflow_name,generation,status,attempts,last_error,next_attempt_at,wake_after,leased_by,lease_expires_at,created_at,updated_at,completed_at"
    branches =
      [ "(SELECT " <> columns <> " FROM keiro.keiro_workflows WHERE ($1 & " <> number (2 ^ fromEnum status) <> ")<>0 AND (" <> statusCase <> ")='" <> statusClassToText status <> "' ORDER BY workflow_name,workflow_id LIMIT $2)"
      | status <- [minBound .. maxBound :: WorkflowStatusClass]
      ]

number :: Int -> Text
number = Text.pack . show

use :: KirokuStore -> Session.Session a -> IO a
use store action = Pool.use store.pool action >>= right

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

execute :: Text -> Text -> IO ()
execute url sql = bracket (Connection.acquire (Settings.connectionString url) >>= right) Connection.release $ \connection ->
  Connection.use connection (Session.script sql) >>= right
