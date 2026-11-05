{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Run inside nix develop, after cabal build keiro keiro-test-support:
-- cabal exec -- runghc -XGHC2024 -package=keiro -package=keiro-test-support scripts/workflow-counts-query-evidence.hs OUTPUT_DIRECTORY [SIZE...]
-- A bounded feasibility experiment, not a runtime interference benchmark.
import Control.Monad (forM, forM_, replicateM, unless, void)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as Lazy
import Data.Functor.Contravariant ((>$<))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List (foldl')
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.Test.Postgres
import Keiro.Workflow.Inspection
import Keiro.Workflow.Instance qualified as Instance
import Kiroku.Store.Connection
import Kiroku.Store.Effect (runStoreIO)
import System.Directory (createDirectory, doesPathExist)
import System.Environment (getArgs)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  (output, sizes) <-
    getArgs >>= \case
      path : rest -> pure (path, if null rest then [10000, 100000, 1000000] else map read rest)
      _ -> fail "expected OUTPUT_DIRECTORY [SIZE...]"
  exists <- doesPathExist output
  unless (not exists) (fail "refusing to overwrite evidence")
  createDirectory output
  indexFailures <- newIORef (Map.empty :: Map.Map Text [Text])
  withMigratedBenchmarkSuite $ \fixture -> forM_ sizes $ \size ->
    forM_ ["balanced", "terminal99", "active99"] $ \distribution ->
      withFreshDatabase fixture $ \url ->
        withStore (defaultConnectionSettings url) {poolSize = 1} $ \store -> do
          execute store (seed size distribution)
          execute store "VACUUM (ANALYZE) keiro.keiro_workflows"
          settings <- json store "SELECT json_build_object('version',version(),'fsync',current_setting('fsync'),'synchronous_commit',current_setting('synchronous_commit'),'full_page_writes',current_setting('full_page_writes'),'autovacuum',current_setting('autovacuum'),'max_parallel_workers_per_gather',current_setting('max_parallel_workers_per_gather'),'shared_buffers',current_setting('shared_buffers'),'work_mem',current_setting('work_mem'),'jit',current_setting('jit'),'standard_conforming_strings',current_setting('standard_conforming_strings'))"
          durable <- use store (Session.statement () (Statement.preparable "SELECT current_setting('fsync')='on' AND current_setting('synchronous_commit')='on' AND current_setting('full_page_writes')='on' AND current_setting('autovacuum')='on' AND current_setting('standard_conforming_strings')='on'" E.noParams (D.singleRow (D.column (D.nonNullable D.bool)))))
          unless durable (fail "requires normal durability, autovacuum and standard strings")
          indexes <- json store "SELECT json_agg(indexdef ORDER BY indexname) FROM pg_indexes WHERE schemaname='keiro' AND tablename='keiro_workflows'"
          forM_ ["maintained", "recent-update"] $ \state -> do
            whenRecent state $ execute store "UPDATE keiro.keiro_workflows SET attempts=CASE WHEN attempts=0 THEN -1 ELSE 0 END, wake_after=CASE WHEN wake_after IS NULL THEN now()+interval '1 day' ELSE NULL END, updated_at=now() WHERE right(workflow_id,2) IN ('00','01','02','03','04','05','06','07','08','09')"
            -- Do not drain the list before timing: that would warm every heap page.
            observations <- forM ["auto", "force_custom_plan", "force_generic_plan"] $ \mode -> do
              execute store ("SET plan_cache_mode='" <> mode <> "'; SET statement_timeout='2000ms'")
              forM ["single", "selective"] $ \shape -> do
                samples <- forM filters $ \(label, name) -> do
                  let query = WorkflowCountsQuery name
                      candidate = runStoreIO store (Instance.inspectionInstanceCounts query) >>= right
                  -- Install and discover the actual owner statement, never a copy.
                  (firstMs, first) <- timed candidate
                  (preparedName, sql) <- ownerStatement store name
                  let alternative = selective sql name
                      readCounts = if shape == "single" then candidate else use store (Session.statement () alternative)
                  (initialMs, initial) <- if shape == "single" then pure (firstMs, first) else timed readCounts
                  repetitions <- replicateM 5 (timed readCounts)
                  let values = totals initial.counts
                  unless (all ((== values) . totals . (.counts) . snd) repetitions) (fail "counts changed on stable fixture")
                  (actualName, actualSql) <- if shape == "single" then pure (preparedName, sql) else findPrepared store "/* keiro-inspection-counts-selective-prototype-v1 */" name
                  let arguments = maybe "" (\n -> "(" <> literal n <> ")") name
                  plan <- json store ("EXPLAIN (ANALYZE,BUFFERS,SETTINGS,FORMAT JSON) EXECUTE \"" <> Text.replace "\"" "\"\"" actualName <> "\"" <> arguments)
                  if size == 1000000 && hasSequentialScan plan
                    then modifyIORef' indexFailures (Map.insertWith (<>) shape [Text.intercalate "/" [distribution, state, mode, label]])
                    else pure ()
                  cache <- json store ("SELECT json_build_object('generic_plans',generic_plans,'custom_plans',custom_plans) FROM pg_prepared_statements WHERE name=" <> literal actualName)
                  pure (label, name, values, object ["case" .= label, "workflow_name" .= name, "counts" .= values, "first_ms" .= initialMs, "warm_ms" .= map fst repetitions, "sql" .= actualSql, "plan_cache" .= cache, "plan" .= plan])
                pure (mode, shape, samples)
            -- Independent Haskell classification over every page, once per fixture
            -- state; no COUNT query is used as its own correctness oracle.
            classified <- drain store
            forM_ (concat observations) $ \(mode, shape, samples) -> do
              forM_ samples $ \(_, name, values, _) ->
                unless (values == expected classified name) (fail "aggregate differs from complete list drain")
              let artifact = object ["rows" .= size, "distribution" .= distribution, "state" .= state, "mode" .= mode, "shape" .= shape, "statement_timeout_ms" .= (2000 :: Int), "settings" .= settings, "indexes" .= indexes, "list_drain_total" .= sum (Map.elems classified), "cases" .= [value | (_, _, _, value) <- samples]]
                  path = output </> Text.unpack (Text.intercalate "-" [number size, distribution, state, mode, shape]) <> ".json"
              Lazy.writeFile path (Aeson.encode artifact)
              putStrLn path
  failures <- readIORef indexFailures
  Lazy.writeFile (output </> "index-failures.json") (Aeson.encode failures)
  putStrLn "PASS: counts equal the complete list drain; all measured reads finished inside 2000 ms."
  if all (`Map.member` failures) ["single", "selective"]
    then putStrLn "NOTE: both shapes contain planner-selected sequential scans; these are authorized with no schema changes. See index-failures.json for the original index diagnostic."
    else unless (1000000 `elem` sizes) (putStrLn "SMOKE ONLY: the required million-row population was not measured.")

hasSequentialScan :: Value -> Bool
hasSequentialScan = \case
  Aeson.Object value -> KeyMap.lookup "Node Type" value == Just (Aeson.String "Seq Scan") || any hasSequentialScan (KeyMap.elems value)
  Aeson.Array values -> any hasSequentialScan values
  _ -> False

filters :: [(Text, Maybe Text)]
filters = [("all", Nothing), ("dominant", Just "hot"), ("rare", Just "rare"), ("absent", Just "absent"), ("literal-unicode", Just specialName), ("wide", Just wideName)]

specialName, wideName :: Text
specialName = "支払_%'\\ λ"
wideName = Text.replicate 2700 "x"

seed :: Int -> Text -> Text
seed size distribution =
  "INSERT INTO keiro.keiro_workflows(workflow_id,workflow_name,status,attempts,wake_after,completed_at,created_at,updated_at) SELECT CASE WHEN n="
    <> number (size - 1)
    <> " THEN (SELECT left(string_agg(md5(g::text),''),2600) FROM generate_series(1,90) g) ELSE 'w-'||lpad(n::text,8,'0') END,CASE WHEN n="
    <> number size
    <> " THEN "
    <> literal wideName
    <> " WHEN n%997=0 THEN 'rare' WHEN n%1000=0 THEN "
    <> literal specialName
    <> " WHEN n%10<>0 THEN 'hot' ELSE 'small' END,CASE c WHEN 0 THEN 'running' WHEN 1 THEN 'running' WHEN 2 THEN 'suspended' WHEN 3 THEN 'suspended' WHEN 4 THEN 'completed' WHEN 5 THEN 'cancelled' ELSE 'failed' END,CASE WHEN c=1 THEN CASE WHEN n%2=0 THEN -1 ELSE 3 END ELSE 0 END,CASE WHEN c=2 THEN '2026-01-01+00'::timestamptz END,CASE WHEN c>=4 THEN '2026-01-01+00'::timestamptz END,'2026-01-01+00'::timestamptz,'2026-01-01+00'::timestamptz FROM (SELECT n,"
    <> classification
    <> " c FROM generate_series(1,"
    <> number size
    <> ") n) fixture"
  where
    classification = case distribution of
      "terminal99" -> "CASE WHEN n%100<>0 THEN 4+n%3 ELSE (n/100)%4 END"
      "active99" -> "CASE WHEN n%100<>0 THEN n%4 ELSE 4+(n/100)%3 END"
      _ -> "n%7"

-- Compare the second proposed shape using the candidate's exact FILTER
-- expressions. Running/retrying and sleeping/awaiting each share one scan.
selective :: Text -> Maybe Text -> Statement.Statement () WorkflowCounts
selective owner name = Statement.preparable sql params (D.singleRow decoder)
  where
    expressions = Text.splitOn ", " (fst (Text.breakOn " FROM keiro.keiro_workflows" (Text.drop (Text.length "/* keiro-inspection-counts-v1 */ SELECT now(), ") owner)))
    groups = [(take 2 expressions, "running", "r"), (take 2 (drop 2 expressions), "suspended", "s"), ([expressions !! 4], "completed", "c"), ([expressions !! 5], "cancelled", "x"), ([expressions !! 6], "failed", "f")]
    sql =
      "/* keiro-inspection-counts-selective-prototype-v1 */ SELECT now(),r.*,s.*,c.*,x.*,f.* FROM "
        <> Text.intercalate " CROSS JOIN " ["(SELECT " <> Text.intercalate ", " es <> " FROM keiro.keiro_workflows WHERE status=" <> literal status <> maybe "" (const " AND workflow_name=$1") name <> ") " <> alias | (es, status, alias) <- groups]
    params = maybe E.noParams (\n -> const n >$< E.param (E.nonNullable E.text)) name
    total = D.column (D.nonNullable D.int8)
    decoder = WorkflowCounts <$> D.column (D.nonNullable D.timestamptz) <*> (WorkflowStatusCounts <$> total <*> total <*> total <*> total <*> total <*> total <*> total)

ownerStatement :: KirokuStore -> Maybe Text -> IO (Text, Text)
ownerStatement store = findPrepared store "/* keiro-inspection-counts-v1 */"

findPrepared :: KirokuStore -> Text -> Maybe Text -> IO (Text, Text)
findPrepared store marker name = do
  statements <- use store (Session.statement () (Statement.preparable "SELECT name,statement FROM pg_prepared_statements" E.noParams (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text)))))
  case [(n, sql) | (n, sql) <- statements, marker `Text.isPrefixOf` sql, ("$1" `Text.isInfixOf` sql) == maybe False (const True) name] of
    [entry] -> pure entry
    other -> fail ("expected one actual prepared statement: " <> show other)

type Classified = Map.Map (Text, WorkflowStatusClass) Int64

drain :: KirokuStore -> IO Classified
drain store = loop Nothing Map.empty
  where
    loop cursor counts = do
      page <- runStoreIO store (listWorkflowInstancesPage defaultWorkflowListQuery {pageSize = 500, cursor}) >>= right >>= right
      let next = foldl' (\m row -> Map.insertWith (+) (row.workflowName, statusClassOf row) 1 m) counts page.items
      case page.nextCursor of Nothing -> pure next; Just token -> loop (Just token) next

expected :: Classified -> Maybe Text -> [Int64]
expected classified name = [sum [n | ((owner, cls), n) <- Map.toList classified, cls == c, maybe True (== owner) name] | c <- [minBound .. maxBound]]

totals :: WorkflowStatusCounts -> [Int64]
totals c = [c.running, c.retrying, c.sleeping, c.awaiting, c.completed, c.cancelled, c.failed]

timed :: IO a -> IO (Double, a)
timed action = do
  before <- getMonotonicTimeNSec
  result <- action
  after <- getMonotonicTimeNSec
  pure (fromIntegral (after - before) / 1000000, result)

whenRecent :: Text -> IO () -> IO ()
whenRecent state action = if state == "recent-update" then action else pure ()

literal :: Text -> Text
literal value = "'" <> Text.replace "'" "''" value <> "'"

number :: Int -> Text
number = Text.pack . show

use :: KirokuStore -> Session.Session a -> IO a
use store session = Pool.use store.pool session >>= right

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

execute :: KirokuStore -> Text -> IO ()
execute store sql = void (use store (Session.script sql))

json :: KirokuStore -> Text -> IO Value
json store sql = use store (Session.statement () (Statement.preparable sql E.noParams (D.singleRow (D.column (D.nonNullable D.json)))))
