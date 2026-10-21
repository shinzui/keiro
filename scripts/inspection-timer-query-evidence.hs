{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- M0 query prototypes on disposable durable fixtures, not a unit-test fixture.
-- Final acceptance also runs the chosen owning API's actual prepared query.
import Control.Exception (bracket)
import Control.Monad (forM_, unless, void)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString.Lazy qualified as Lazy
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Keiro.Test.Postgres
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.FilePath ((</>))

main :: IO ()
main = do
  [output] <- getArgs
  createDirectoryIfMissing True output
  withMigratedBenchmarkSuite $ \fixture -> forM_ [10000, 100000 :: Int] $ \count ->
    withFreshDatabase fixture $ \url ->
      bracket (Connection.acquire (Settings.connectionString url) >>= right) Connection.release $ \connection -> do
        let execute sql = void (Connection.use connection (Session.script sql) >>= right)
            query sql = Connection.use connection (Session.statement () (Statement.preparable sql E.noParams (D.singleRow (D.column (D.nonNullable D.jsonb))))) >>= right
        settings <- query "SELECT jsonb_build_object('server_version',current_setting('server_version'),'fsync',current_setting('fsync'),'synchronous_commit',current_setting('synchronous_commit'),'full_page_writes',current_setting('full_page_writes'),'autovacuum',current_setting('autovacuum'))"
        durable <- Connection.use connection (Session.statement () (Statement.preparable "SELECT current_setting('fsync')='on' AND current_setting('synchronous_commit')='on' AND current_setting('full_page_writes')='on' AND current_setting('autovacuum')='on'" E.noParams (D.singleRow (D.column (D.nonNullable D.bool))))) >>= right
        unless durable (fail "requires durable PostgreSQL and normal autovacuum")
        execute ("INSERT INTO keiro.keiro_timers(timer_id,process_manager_name,correlation_id,fire_at,payload,status) SELECT ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,CASE WHEN n<=" <> number (count * 9 `div` 10) <> " THEN 'hot' ELSE 'pm-'||lpad((n%100)::text,2,'0') END,'corr-'||lpad((n%100)::text,2,'0'),'2026-10-01'::timestamptz+(n/1000)*interval '1 minute',jsonb_build_object('n',n),CASE WHEN n%4=0 THEN 'fired' WHEN n%8=1 THEN 'firing' ELSE 'scheduled' END FROM generate_series(1," <> number count <> ") n")
        forM_ (zip [0 :: Int ..] indexStages) $ \(stage, (indexLabel, ddl)) -> do
          execute ddl
          execute "ANALYZE keiro.keiro_timers"
          forM_ ["force_custom_plan", "force_generic_plan"] $ \mode -> do
            execute ("SET plan_cache_mode='" <> mode <> "'")
            forM_ (zip [0 :: Int ..] cases) $ \(caseNumber, (label, predicate, manager, correlation)) ->
              forM_ [False, True] $ \deep -> do
                let name = "timer_probe_" <> number stage <> "_" <> mode <> "_" <> number caseNumber <> if deep then "_deep" else "_first"
                    cursor = if deep then " AND (fire_at,timer_id)>($3,$4)" else ""
                    sql = "SELECT timer_id,process_manager_name,correlation_id,fire_at,payload,status,attempts,fired_event_id,last_error FROM keiro.keiro_timers WHERE status IN ('scheduled','firing')" <> predicate <> cursor <> " ORDER BY fire_at,timer_id LIMIT $5"
                    arguments = quote manager <> "," <> quote correlation <> ",'2026-10-01'::timestamptz+interval '" <> number (count * 8 `div` 10000) <> " minute','00000000-0000-0000-0000-000000000000'::uuid,101"
                execute ("PREPARE " <> name <> "(text,text,timestamptz,uuid,bigint) AS " <> sql)
                plan <- Connection.use connection (Session.statement () (Statement.preparable ("EXPLAIN (ANALYZE,BUFFERS,SETTINGS,FORMAT JSON) EXECUTE " <> name <> "(" <> arguments <> ")") E.noParams (D.singleRow (D.column (D.nonNullable D.json))))) >>= right
                let filename = Text.unpack (number count <> "-" <> indexLabel <> "-" <> mode <> "-" <> label <> if deep then "-deep" else "-first") <> ".json"
                Lazy.writeFile (output </> filename) (encode (object ["rows" .= count, "indexes" .= indexLabel, "mode" .= mode, "case" .= label, "deep" .= deep, "settings" .= (settings :: Value), "sql" .= sql, "arguments" .= arguments, "plan" .= (plan :: Value)]))
          putStrLn (show count <> " " <> Text.unpack indexLabel)
          -- A faster index is unusable if it rejects values the old writer accepts.
          domain <- mapM (domainProbe connection execute) [(field, width) | field <- (["manager", "correlation"] :: [Text]), width <- [2600, 2640, 2660, 2670, 2680, 2700, 10000]]
          Lazy.writeFile (output </> Text.unpack (number count <> "-" <> indexLabel <> "-key-domain.json")) (encode domain)

domainProbe connection execute (field, width) = do
  let value = "left(bytes.value," <> number width <> ")"
      manager = if field == "manager" then value else "'probe'"
      correlation = if field == "correlation" then value else "'probe'"
      sql = "INSERT INTO keiro.keiro_timers(timer_id,process_manager_name,correlation_id,fire_at,payload,status) SELECT 'ffffffff-ffff-ffff-ffff-ffffffffffff'," <> manager <> "," <> correlation <> ",'2026-10-01','{}','scheduled' FROM (SELECT string_agg(md5(n::text),'') value FROM generate_series(1,400) n) bytes"
  result <- Connection.use connection (Session.script sql)
  execute "DELETE FROM keiro.keiro_timers WHERE timer_id='ffffffff-ffff-ffff-ffff-ffffffffffff'"
  pure (object ["field" .= field, "width" .= width, "accepted" .= either (const False) (const True) result, "error" .= either (Just . show) (const Nothing) result])

indexStages :: [(Text, Text)]
indexStages =
  [ ("existing", "SELECT 1"),
    ("global", "CREATE INDEX inspection_timer_global ON keiro.keiro_timers(fire_at,timer_id) WHERE status IN ('scheduled','firing')"),
    ("all-four", "CREATE INDEX inspection_timer_manager ON keiro.keiro_timers(process_manager_name,fire_at,timer_id) WHERE status IN ('scheduled','firing'); CREATE INDEX inspection_timer_correlation ON keiro.keiro_timers(correlation_id,fire_at,timer_id) WHERE status IN ('scheduled','firing'); CREATE INDEX inspection_timer_combined ON keiro.keiro_timers(process_manager_name,correlation_id,fire_at,timer_id) WHERE status IN ('scheduled','firing')")
  ]

cases :: [(Text, Text, Text, Text)]
cases =
  [ ("all", "", "hot", "corr-07"),
    ("manager-hot", " AND process_manager_name=$1", "hot", "corr-07"),
    ("manager-rare", " AND process_manager_name=$1", "pm-07", "corr-07"),
    ("manager-absent", " AND process_manager_name=$1", "absent", "corr-07"),
    ("correlation", " AND correlation_id=$2", "hot", "corr-07"),
    ("correlation-absent", " AND correlation_id=$2", "hot", "absent"),
    ("combined-hot", " AND process_manager_name=$1 AND correlation_id=$2", "hot", "corr-07"),
    ("combined-rare", " AND process_manager_name=$1 AND correlation_id=$2", "pm-07", "corr-07"),
    ("combined-absent", " AND process_manager_name=$1 AND correlation_id=$2", "hot", "absent")
  ]

quote :: Text -> Text
quote value = "'" <> Text.replace "'" "''" value <> "'"

number :: Int -> Text
number = Text.pack . show

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure
