module Main (main) where

import Control.Concurrent.Async (mapConcurrently_)
import Control.Exception (bracket)
import Control.Monad (forM, void, when)
import Data.Aeson qualified as Aeson
import Data.Foldable (traverse_)
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int64)
import Data.List (groupBy, sort, sortOn)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import Data.UUID (UUID)
import Data.UUID.V4 qualified as UUID
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import EphemeralPg qualified as Pg
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Conn
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Kiroku.Store qualified as Kiroku
import MessageDb.Db.Migration qualified as MessageDbMigration
import MessageDb.Db.Sessions qualified as MessageDb
import MessageDb.Message qualified as MessageDb
import System.Environment (lookupEnv)

data BenchConfig = BenchConfig
    { iterations :: !Int
    , samples :: !Int
    , workers :: !Int
    , isolate :: !Bool
    }

data BenchResult = BenchResult
    { name :: !Text
    , iterations :: !Int
    , sample :: !Int
    , elapsed :: !NominalDiffTime
    }

main :: IO ()
main = do
    config <- getConfig
    putStrLn
        ( "[compare] iterations="
            <> show config.iterations
            <> " samples="
            <> show config.samples
            <> " workers="
            <> show config.workers
            <> " isolate="
            <> show config.isolate
        )
    results <- concat <$> forM [1 .. config.samples] (runSample config)
    putStrLn ""
    putStrLn "sample,name,iterations,elapsed_ms,writes_per_sec,us_per_write"
    traverse_ (putStrLn . renderCsv) results
    putStrLn ""
    putStrLn "name,samples,median_us_per_write,median_writes_per_sec"
    traverse_ (putStrLn . renderSummary) (summaries results)
    when (not config.isolate) $
        putStrLn "[compare] note: shared-db mode can include prior-case table-growth effects"

runInFreshDb :: (Text -> Connection.Connection -> Kiroku.KirokuStore -> IO a) -> IO a
runInFreshDb action = do
    result <- Pg.with $ \db -> do
        let connText = Pg.connectionString db
        withConnection connText $ \conn -> do
            initializeMessageDb conn
            initializeKiroku connText
            setSearchPath conn
            Kiroku.withStore (Kiroku.defaultConnectionSettings connText) \store ->
                action connText conn store
    case result of
        Left err -> fail ("failed to start ephemeral Postgres: " <> show err)
        Right value -> pure value

getConfig :: IO BenchConfig
getConfig = do
    configuredIterations <- lookupEnv "COMPARE_ITERATIONS"
    configuredSamples <- lookupEnv "COMPARE_SAMPLES"
    configuredWorkers <- lookupEnv "COMPARE_WORKERS"
    configuredIsolate <- lookupEnv "COMPARE_ISOLATE"
    pure
        BenchConfig
            { iterations = maybe 1000 read configuredIterations
            , samples = maybe 3 read configuredSamples
            , workers = maybe 8 read configuredWorkers
            , isolate = maybe True parseBool configuredIsolate
            }
  where
    parseBool value =
        case Text.toLower (Text.pack value) of
            "0" -> False
            "false" -> False
            "no" -> False
            "off" -> False
            _ -> True

withConnection :: Text -> (Connection.Connection -> IO a) -> IO a
withConnection connText =
    bracket acquire Connection.release
  where
    acquire = do
        outcome <- Connection.acquire (Conn.connectionString connText)
        case outcome of
            Left err -> fail ("failed to connect: " <> show err)
            Right conn -> pure conn

initializeMessageDb :: Connection.Connection -> IO ()
initializeMessageDb conn = do
    outcome <- Connection.use conn MessageDbMigration.migrate
    case outcome of
        Left err -> fail ("message-db migration session failed: " <> show err)
        Right (Left err) -> fail ("message-db migration failed: " <> show err)
        Right (Right ()) -> pure ()

initializeKiroku :: Text -> IO ()
initializeKiroku connText =
    Kiroku.withStore (Kiroku.defaultConnectionSettings connText) \_ -> pure ()

setSearchPath :: Connection.Connection -> IO ()
setSearchPath conn = do
    outcome <- Connection.use conn (Session.statement () setSearchPathStmt)
    case outcome of
        Left err -> fail ("failed to set search_path: " <> show err)
        Right () -> pure ()

setSearchPathStmt :: Statement () ()
setSearchPathStmt =
    preparable
        "SET search_path TO message_store, public"
        E.noParams
        D.noResult

dropKirokuNotifyTrigger :: Connection.Connection -> IO ()
dropKirokuNotifyTrigger conn = do
    outcome <- Connection.use conn (Session.statement () dropKirokuNotifyTriggerStmt)
    case outcome of
        Left err -> fail ("failed to drop Kiroku notify trigger: " <> show err)
        Right () -> pure ()

dropKirokuNotifyTriggerStmt :: Statement () ()
dropKirokuNotifyTriggerStmt =
    preparable
        "DROP TRIGGER IF EXISTS stream_events_notify ON streams"
        E.noParams
        D.noResult

dropKirokuCategoryColumn :: Connection.Connection -> IO ()
dropKirokuCategoryColumn conn = do
    outcome <- Connection.use conn (Session.statement () dropKirokuCategoryColumnStmt)
    case outcome of
        Left err -> fail ("failed to drop Kiroku category column: " <> show err)
        Right () -> pure ()

dropKirokuCategoryColumnStmt :: Statement () ()
dropKirokuCategoryColumnStmt =
    preparable
        "ALTER TABLE streams DROP COLUMN IF EXISTS category CASCADE"
        E.noParams
        D.noResult

data Scenario = Scenario
    { scenarioName :: !Text
    , scenarioIterations :: !Int
    , scenarioSetup :: !(Connection.Connection -> IO ())
    , scenarioAction :: !(Text -> Connection.Connection -> Kiroku.KirokuStore -> IO ())
    }

scenario ::
    Text ->
    Int ->
    (Text -> Connection.Connection -> Kiroku.KirokuStore -> IO ()) ->
    Scenario
scenario scenarioName scenarioIterations scenarioAction =
    Scenario
        { scenarioName = scenarioName
        , scenarioIterations = scenarioIterations
        , scenarioSetup = \_ -> pure ()
        , scenarioAction = scenarioAction
        }

scenarioWithSetup ::
    Text ->
    Int ->
    (Connection.Connection -> IO ()) ->
    (Text -> Connection.Connection -> Kiroku.KirokuStore -> IO ()) ->
    Scenario
scenarioWithSetup scenarioName scenarioIterations scenarioSetup scenarioAction =
    Scenario
        { scenarioName = scenarioName
        , scenarioIterations = scenarioIterations
        , scenarioSetup = scenarioSetup
        , scenarioAction = scenarioAction
        }

runSample :: BenchConfig -> Int -> IO [BenchResult]
runSample config sample = do
    let samplePrefix label = label <> "-s" <> Text.pack (show sample)
        perWorker = max 1 (config.iterations `div` config.workers)
        concurrentIterations = perWorker * config.workers
        scenarios =
            [ scenario "raw-message-db-sql/write_message/new-streams" config.iterations \_ conn _ ->
                runRawMessageDbWrites conn config.iterations (\i -> samplePrefix "raw-message-db" <> "-" <> Text.pack (show i))
            , scenario "raw-kiroku-sql/append-any-version/new-streams" config.iterations \_ conn _ ->
                runRawKirokuWrites conn config.iterations (\i -> samplePrefix "raw-kiroku" <> "-" <> Text.pack (show i))
            , scenario "raw-kiroku-production-sql/append-any-version/new-streams" config.iterations \_ conn _ ->
                runRawKirokuProductionWrites conn config.iterations (\i -> samplePrefix "raw-kiroku-production" <> "-" <> Text.pack (show i))
            , scenarioWithSetup "raw-kiroku-sql/append-any-version/new-streams/no-notify" config.iterations dropKirokuNotifyTrigger \_ conn _ ->
                runRawKirokuWrites conn config.iterations (\i -> samplePrefix "raw-kiroku-no-notify" <> "-" <> Text.pack (show i))
            , scenarioWithSetup "raw-kiroku-sql/append-any-version/new-streams/no-category" config.iterations dropKirokuCategoryColumn \_ conn _ ->
                runRawKirokuWrites conn config.iterations (\i -> samplePrefix "raw-kiroku-no-category" <> "-" <> Text.pack (show i))
            , scenario "raw-message-db-sql/write_message/hot-stream" config.iterations \_ conn _ ->
                runRawMessageDbWrites conn config.iterations (const (samplePrefix "raw-message-db-hot"))
            , scenario "raw-kiroku-sql/append-any-version/hot-stream" config.iterations \_ conn _ ->
                runRawKirokuWrites conn config.iterations (const (samplePrefix "raw-kiroku-hot"))
            , scenario "raw-kiroku-production-sql/append-any-version/hot-stream" config.iterations \_ conn _ ->
                runRawKirokuProductionWrites conn config.iterations (const (samplePrefix "raw-kiroku-production-hot"))
            , scenarioWithSetup "raw-kiroku-sql/append-any-version/hot-stream/no-notify" config.iterations dropKirokuNotifyTrigger \_ conn _ ->
                runRawKirokuWrites conn config.iterations (const (samplePrefix "raw-kiroku-hot-no-notify"))
            , scenarioWithSetup "raw-kiroku-sql/append-any-version/hot-stream/no-category" config.iterations dropKirokuCategoryColumn \_ conn _ ->
                runRawKirokuWrites conn config.iterations (const (samplePrefix "raw-kiroku-hot-no-category"))
            , scenario "haskell-message-db-hs/writeStreamMessage/new-streams" config.iterations \_ conn _ ->
                runMessageDbHsWrites conn config.iterations (\i -> samplePrefix "haskell-message-db" <> "-" <> Text.pack (show i))
            , scenario "haskell-kiroku-store/appendToStream/new-streams" config.iterations \_ _ store ->
                runKirokuWrites store config.iterations (\i -> samplePrefix "haskell-kiroku" <> "-" <> Text.pack (show i))
            , scenario "haskell-kiroku-store/appendToStream/new-streams/single-runStoreIO" config.iterations \_ _ store ->
                runKirokuWritesSingleProgram store config.iterations (\i -> samplePrefix "haskell-kiroku-single-program" <> "-" <> Text.pack (show i))
            , scenarioWithSetup "haskell-kiroku-store/appendToStream/new-streams/no-notify" config.iterations dropKirokuNotifyTrigger \_ _ store ->
                runKirokuWrites store config.iterations (\i -> samplePrefix "haskell-kiroku-no-notify" <> "-" <> Text.pack (show i))
            , scenarioWithSetup "haskell-kiroku-store/appendToStream/new-streams/no-category" config.iterations dropKirokuCategoryColumn \_ _ store ->
                runKirokuWrites store config.iterations (\i -> samplePrefix "haskell-kiroku-no-category" <> "-" <> Text.pack (show i))
            , scenario "haskell-message-db-hs/writeStreamMessage/hot-stream" config.iterations \_ conn _ ->
                runMessageDbHsWrites conn config.iterations (const (samplePrefix "haskell-message-db-hot"))
            , scenario "haskell-kiroku-store/appendToStream/hot-stream" config.iterations \_ _ store ->
                runKirokuWrites store config.iterations (const (samplePrefix "haskell-kiroku-hot"))
            , scenario "haskell-kiroku-store/appendToStream/hot-stream/single-runStoreIO" config.iterations \_ _ store ->
                runKirokuWritesSingleProgram store config.iterations (const (samplePrefix "haskell-kiroku-hot-single-program"))
            , scenarioWithSetup "haskell-kiroku-store/appendToStream/hot-stream/no-notify" config.iterations dropKirokuNotifyTrigger \_ _ store ->
                runKirokuWrites store config.iterations (const (samplePrefix "haskell-kiroku-hot-no-notify"))
            , scenarioWithSetup "haskell-kiroku-store/appendToStream/hot-stream/no-category" config.iterations dropKirokuCategoryColumn \_ _ store ->
                runKirokuWrites store config.iterations (const (samplePrefix "haskell-kiroku-hot-no-category"))
            , scenario "raw-message-db-sql/write_message/concurrent-new-streams" concurrentIterations \connText _ _ ->
                runConcurrentConnections connText config.workers \workerConn worker ->
                    runRawMessageDbWrites workerConn perWorker (\i -> samplePrefix "raw-message-db-conc" <> "-w" <> Text.pack (show worker) <> "-" <> Text.pack (show i))
            , scenario "raw-kiroku-sql/append-any-version/concurrent-new-streams" concurrentIterations \connText _ _ ->
                runConcurrentConnections connText config.workers \workerConn worker ->
                    runRawKirokuWrites workerConn perWorker (\i -> samplePrefix "raw-kiroku-conc" <> "-w" <> Text.pack (show worker) <> "-" <> Text.pack (show i))
            , scenario "raw-kiroku-production-sql/append-any-version/concurrent-new-streams" concurrentIterations \connText _ _ ->
                runConcurrentConnections connText config.workers \workerConn worker ->
                    runRawKirokuProductionWrites workerConn perWorker (\i -> samplePrefix "raw-kiroku-production-conc" <> "-w" <> Text.pack (show worker) <> "-" <> Text.pack (show i))
            , scenarioWithSetup "raw-kiroku-sql/append-any-version/concurrent-new-streams/no-notify" concurrentIterations dropKirokuNotifyTrigger \connText _ _ ->
                runConcurrentConnections connText config.workers \workerConn worker ->
                    runRawKirokuWrites workerConn perWorker (\i -> samplePrefix "raw-kiroku-conc-no-notify" <> "-w" <> Text.pack (show worker) <> "-" <> Text.pack (show i))
            , scenarioWithSetup "raw-kiroku-sql/append-any-version/concurrent-new-streams/no-category" concurrentIterations dropKirokuCategoryColumn \connText _ _ ->
                runConcurrentConnections connText config.workers \workerConn worker ->
                    runRawKirokuWrites workerConn perWorker (\i -> samplePrefix "raw-kiroku-conc-no-category" <> "-w" <> Text.pack (show worker) <> "-" <> Text.pack (show i))
            , scenario "haskell-message-db-hs/writeStreamMessage/concurrent-new-streams" concurrentIterations \connText _ _ ->
                runConcurrentConnections connText config.workers \workerConn worker ->
                    runMessageDbHsWrites workerConn perWorker (\i -> samplePrefix "haskell-message-db-conc" <> "-w" <> Text.pack (show worker) <> "-" <> Text.pack (show i))
            , scenario "haskell-kiroku-store/appendToStream/concurrent-new-streams" concurrentIterations \_ _ store ->
                runConcurrentKirokuWrites store config.workers perWorker (\worker i -> samplePrefix "haskell-kiroku-conc" <> "-w" <> Text.pack (show worker) <> "-" <> Text.pack (show i))
            , scenario "haskell-kiroku-store/appendToStream/concurrent-new-streams/single-runStoreIO" concurrentIterations \_ _ store ->
                runConcurrentKirokuWritesSingleProgram store config.workers perWorker (\worker i -> samplePrefix "haskell-kiroku-conc-single-program" <> "-w" <> Text.pack (show worker) <> "-" <> Text.pack (show i))
            , scenarioWithSetup "haskell-kiroku-store/appendToStream/concurrent-new-streams/no-notify" concurrentIterations dropKirokuNotifyTrigger \_ _ store ->
                runConcurrentKirokuWrites store config.workers perWorker (\worker i -> samplePrefix "haskell-kiroku-conc-no-notify" <> "-w" <> Text.pack (show worker) <> "-" <> Text.pack (show i))
            , scenarioWithSetup "haskell-kiroku-store/appendToStream/concurrent-new-streams/no-category" concurrentIterations dropKirokuCategoryColumn \_ _ store ->
                runConcurrentKirokuWrites store config.workers perWorker (\worker i -> samplePrefix "haskell-kiroku-conc-no-category" <> "-w" <> Text.pack (show worker) <> "-" <> Text.pack (show i))
            , scenario "raw-message-db-sql/write_message/concurrent-hot-stream" concurrentIterations \connText _ _ ->
                runConcurrentConnections connText config.workers \workerConn _ ->
                    runRawMessageDbWrites workerConn perWorker (const (samplePrefix "raw-message-db-conc-hot"))
            , scenario "raw-kiroku-sql/append-any-version/concurrent-hot-stream" concurrentIterations \connText _ _ ->
                runConcurrentConnections connText config.workers \workerConn _ ->
                    runRawKirokuWrites workerConn perWorker (const (samplePrefix "raw-kiroku-conc-hot"))
            , scenario "raw-kiroku-production-sql/append-any-version/concurrent-hot-stream" concurrentIterations \connText _ _ ->
                runConcurrentConnections connText config.workers \workerConn _ ->
                    runRawKirokuProductionWrites workerConn perWorker (const (samplePrefix "raw-kiroku-production-conc-hot"))
            , scenarioWithSetup "raw-kiroku-sql/append-any-version/concurrent-hot-stream/no-notify" concurrentIterations dropKirokuNotifyTrigger \connText _ _ ->
                runConcurrentConnections connText config.workers \workerConn _ ->
                    runRawKirokuWrites workerConn perWorker (const (samplePrefix "raw-kiroku-conc-hot-no-notify"))
            , scenarioWithSetup "raw-kiroku-sql/append-any-version/concurrent-hot-stream/no-category" concurrentIterations dropKirokuCategoryColumn \connText _ _ ->
                runConcurrentConnections connText config.workers \workerConn _ ->
                    runRawKirokuWrites workerConn perWorker (const (samplePrefix "raw-kiroku-conc-hot-no-category"))
            , scenario "haskell-message-db-hs/writeStreamMessage/concurrent-hot-stream" concurrentIterations \connText _ _ ->
                runConcurrentConnections connText config.workers \workerConn _ ->
                    runMessageDbHsWrites workerConn perWorker (const (samplePrefix "haskell-message-db-conc-hot"))
            , scenario "haskell-kiroku-store/appendToStream/concurrent-hot-stream" concurrentIterations \_ _ store ->
                runConcurrentKirokuWrites store config.workers perWorker (\_ _ -> samplePrefix "haskell-kiroku-conc-hot")
            , scenario "haskell-kiroku-store/appendToStream/concurrent-hot-stream/single-runStoreIO" concurrentIterations \_ _ store ->
                runConcurrentKirokuWritesSingleProgram store config.workers perWorker (\_ _ -> samplePrefix "haskell-kiroku-conc-hot-single-program")
            , scenarioWithSetup "haskell-kiroku-store/appendToStream/concurrent-hot-stream/no-notify" concurrentIterations dropKirokuNotifyTrigger \_ _ store ->
                runConcurrentKirokuWrites store config.workers perWorker (\_ _ -> samplePrefix "haskell-kiroku-conc-hot-no-notify")
            , scenarioWithSetup "haskell-kiroku-store/appendToStream/concurrent-hot-stream/no-category" concurrentIterations dropKirokuCategoryColumn \_ _ store ->
                runConcurrentKirokuWrites store config.workers perWorker (\_ _ -> samplePrefix "haskell-kiroku-conc-hot-no-category")
            ]
    if config.isolate
        then traverse (runScenarioIsolated sample) scenarios
        else runInFreshDb \connText conn store ->
            traverse (runScenarioShared sample connText conn store) scenarios

runScenarioIsolated :: Int -> Scenario -> IO BenchResult
runScenarioIsolated sample candidate =
    runInFreshDb \connText conn store ->
        runScenarioShared sample connText conn store candidate

runScenarioShared ::
    Int ->
    Text ->
    Connection.Connection ->
    Kiroku.KirokuStore ->
    Scenario ->
    IO BenchResult
runScenarioShared sample connText conn store candidate =
    bench sample candidate.scenarioName candidate.scenarioIterations $
        candidate.scenarioSetup conn *> candidate.scenarioAction connText conn store

bench :: Int -> Text -> Int -> IO () -> IO BenchResult
bench sample name iterations action = do
    putStrLn ("[compare] sample " <> show sample <> " running " <> Text.unpack name)
    start <- getCurrentTime
    action
    end <- getCurrentTime
    let elapsed = diffUTCTime end start
    putStrLn ("[compare] sample " <> show sample <> " finished " <> Text.unpack name <> " in " <> show elapsed)
    pure BenchResult{name, iterations, sample, elapsed}

renderCsv :: BenchResult -> String
renderCsv result =
    show result.sample
        <> ","
        <> Text.unpack result.name
        <> ","
        <> show result.iterations
        <> ","
        <> show elapsedMs
        <> ","
        <> show writesPerSec
        <> ","
        <> show usPerWrite
  where
    seconds = realToFrac result.elapsed :: Double
    elapsedMs = seconds * 1000
    writesPerSec = fromIntegral result.iterations / seconds
    usPerWrite = seconds * 1000000 / fromIntegral result.iterations

data BenchSummary = BenchSummary
    { summaryName :: !Text
    , summarySamples :: !Int
    , medianUsPerWrite :: !Double
    , medianWritesPerSec :: !Double
    }

summaries :: [BenchResult] -> [BenchSummary]
summaries results =
    map summarize grouped
  where
    grouped =
        groupBy (\a b -> a.name == b.name) $
            sortOn (.name) results

    summarize rows@(firstRow : _) =
        let usValues = sort (map usPerWriteOf rows)
            medianUs = median usValues
         in BenchSummary
                { summaryName = firstRow.name
                , summarySamples = length rows
                , medianUsPerWrite = medianUs
                , medianWritesPerSec = 1000000 / medianUs
                }
    summarize [] = error "summaries: impossible empty group"

    usPerWriteOf row =
        let seconds = realToFrac row.elapsed :: Double
         in seconds * 1000000 / fromIntegral row.iterations

    median values =
        case values of
            [] -> error "median: empty"
            _ ->
                let len = length values
                    mid = len `div` 2
                 in if odd len
                        then values !! mid
                        else ((values !! (mid - 1)) + (values !! mid)) / 2

renderSummary :: BenchSummary -> String
renderSummary summary =
    Text.unpack summary.summaryName
        <> ","
        <> show summary.summarySamples
        <> ","
        <> show summary.medianUsPerWrite
        <> ","
        <> show summary.medianWritesPerSec

runRawMessageDbWrites :: Connection.Connection -> Int -> (Int -> Text) -> IO ()
runRawMessageDbWrites conn n streamFor =
    mapM_ go [1 .. n]
  where
    go i = do
        outcome <- Connection.use conn (Session.statement (streamFor i) rawMessageDbWriteStmt)
        case outcome of
            Left err -> fail ("raw message-db write failed: " <> show err)
            Right _ -> pure ()

rawMessageDbWriteStmt :: Statement Text Int64
rawMessageDbWriteStmt =
    preparable
        """
        SELECT message_store.write_message(
          gen_random_uuid()::varchar,
          $1::varchar,
          'BenchEvent'::varchar,
          '{"benchmark": true}'::jsonb,
          '{"correlationStreamName": "raw-message-db"}'::jsonb,
          NULL::bigint
        )
        """
        (E.param (E.nonNullable E.text))
        (D.singleRow (D.column (D.nonNullable D.int8)))

runRawKirokuWrites :: Connection.Connection -> Int -> (Int -> Text) -> IO ()
runRawKirokuWrites conn n streamFor =
    mapM_ go [1 .. n]
  where
    go i = do
        outcome <- Connection.use conn (Session.statement (streamFor i) rawKirokuAppendAnyVersionStmt)
        case outcome of
            Left err -> fail ("raw kiroku write failed: " <> show err)
            Right _ -> pure ()

rawKirokuAppendAnyVersionStmt :: Statement Text Int64
rawKirokuAppendAnyVersionStmt =
    preparable
        """
        WITH
          new_event AS (
            SELECT
              uuidv7() AS event_id,
              'BenchEvent'::text AS event_type,
              NULL::uuid AS causation_id,
              NULL::uuid AS correlation_id,
              '{"benchmark": true}'::jsonb AS data,
              NULL::jsonb AS metadata,
              now() AS created_at
          ),
          stream_upsert AS (
            INSERT INTO streams (stream_name, stream_version)
            VALUES ($1, 1)
            ON CONFLICT (stream_name)
            DO UPDATE SET stream_version = streams.stream_version + 1
              WHERE streams.deleted_at IS NULL
            RETURNING stream_id, stream_version - 1 AS initial_version
          ),
          inserted_event AS (
            INSERT INTO events (event_id, event_type, causation_id, correlation_id, data, metadata, created_at)
            SELECT event_id, event_type, causation_id, correlation_id, data, metadata, created_at
            FROM new_event
            WHERE EXISTS (SELECT 1 FROM stream_upsert)
            RETURNING event_id
          ),
          source_link AS (
            INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
            SELECT ne.event_id, su.stream_id, su.initial_version + 1, su.stream_id, su.initial_version + 1
            FROM new_event ne
            CROSS JOIN stream_upsert su
          ),
          all_update AS (
            UPDATE streams
            SET stream_version = stream_version + 1
            WHERE stream_id = 0
              AND EXISTS (SELECT 1 FROM stream_upsert)
            RETURNING stream_version AS global_position
          ),
          all_link AS (
            INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
            SELECT ne.event_id, 0, au.global_position, su.stream_id, su.initial_version + 1
            FROM new_event ne
            CROSS JOIN all_update au
            CROSS JOIN stream_upsert su
          )
        SELECT global_position FROM all_update
        """
        (E.param (E.nonNullable E.text))
        (D.singleRow (D.column (D.nonNullable D.int8)))

data RawKirokuProductionParams = RawKirokuProductionParams
    { eventIds :: !(Vector UUID)
    , eventTypes :: !(Vector Text)
    , causationIds :: !(Vector (Maybe UUID))
    , correlationIds :: !(Vector (Maybe UUID))
    , payloads :: !(Vector Aeson.Value)
    , metadatas :: !(Vector (Maybe Aeson.Value))
    , createdAts :: !(Vector UTCTime)
    , streamName :: !Text
    }

runRawKirokuProductionWrites :: Connection.Connection -> Int -> (Int -> Text) -> IO ()
runRawKirokuProductionWrites conn n streamFor =
    mapM_ go [1 .. n]
  where
    go i = do
        eventId <- UUID.nextRandom
        createdAt <- getCurrentTime
        let params =
                RawKirokuProductionParams
                    { eventIds = Vector.singleton eventId
                    , eventTypes = Vector.singleton "BenchEvent"
                    , causationIds = Vector.singleton Nothing
                    , correlationIds = Vector.singleton Nothing
                    , payloads = Vector.singleton (Aeson.object ["benchmark" Aeson..= True])
                    , metadatas = Vector.singleton Nothing
                    , createdAts = Vector.singleton createdAt
                    , streamName = streamFor i
                    }
        outcome <- Connection.use conn (Session.statement params rawKirokuProductionAppendAnyVersionStmt)
        case outcome of
            Left err -> fail ("raw kiroku production-shape write failed: " <> show err)
            Right Nothing -> fail "raw kiroku production-shape write returned no rows"
            Right (Just _) -> pure ()

rawKirokuProductionParamsEncoder :: E.Params RawKirokuProductionParams
rawKirokuProductionParamsEncoder =
    ((\params -> params.eventIds) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))
        <> ((\params -> params.eventTypes) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
        <> ((\params -> params.causationIds) >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.uuid))))
        <> ((\params -> params.correlationIds) >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.uuid))))
        <> ((\params -> params.payloads) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.jsonb))))
        <> ((\params -> params.metadatas) >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.jsonb))))
        <> ((\params -> params.createdAts) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.timestamptz))))
        <> ((\params -> params.streamName) >$< E.param (E.nonNullable E.text))

rawKirokuProductionAppendAnyVersionStmt :: Statement RawKirokuProductionParams (Maybe Int64)
rawKirokuProductionAppendAnyVersionStmt =
    preparable
        """
        WITH
          new_events AS (
            SELECT *
            FROM unnest($1::uuid[], $2::text[], $3::uuid[], $4::uuid[], $5::jsonb[], $6::jsonb[], $7::timestamptz[])
            WITH ORDINALITY AS t(event_id, event_type, causation_id, correlation_id, data, metadata, created_at, idx)
          ),
          stream_upsert AS (
            INSERT INTO streams (stream_name, stream_version)
            VALUES ($8, (SELECT count(*) FROM new_events))
            ON CONFLICT (stream_name)
            DO UPDATE SET stream_version = streams.stream_version + (SELECT count(*) FROM new_events)
              WHERE streams.deleted_at IS NULL
            RETURNING stream_id, stream_version - (SELECT count(*) FROM new_events) AS initial_version
          ),
          inserted_events AS (
            INSERT INTO events (event_id, event_type, causation_id, correlation_id, data, metadata, created_at)
            SELECT event_id, event_type, causation_id, correlation_id, data, metadata, created_at
            FROM new_events
            WHERE EXISTS (SELECT 1 FROM stream_upsert)
            ORDER BY idx
          ),
          source_links AS (
            INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
            SELECT ne.event_id, su.stream_id, su.initial_version + ne.idx, su.stream_id, su.initial_version + ne.idx
            FROM new_events ne
            CROSS JOIN stream_upsert su
          ),
          all_update AS (
            UPDATE streams
            SET stream_version = stream_version + (SELECT count(*) FROM new_events)
            WHERE stream_id = 0
              AND EXISTS (SELECT 1 FROM stream_upsert)
            RETURNING stream_version - (SELECT count(*) FROM new_events) AS initial_global_version
          ),
          all_links AS (
            INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
            SELECT ne.event_id, 0, au.initial_global_version + ne.idx, su.stream_id, su.initial_version + ne.idx
            FROM new_events ne
            CROSS JOIN all_update au
            CROSS JOIN stream_upsert su
          )
        SELECT au.initial_global_version + (SELECT count(*) FROM new_events)
        FROM stream_upsert su
        CROSS JOIN all_update au
        """
        rawKirokuProductionParamsEncoder
        (D.rowMaybe (D.column (D.nonNullable D.int8)))

runMessageDbHsWrites :: Connection.Connection -> Int -> (Int -> Text) -> IO ()
runMessageDbHsWrites conn n streamFor =
    mapM_ go [1 .. n]
  where
    go i = do
        messageId <- MessageDb.MessageId <$> UUID.nextRandom
        streamName <- requireMessageDbStream (streamFor i)
        let message =
                MessageDb.NewMessage
                    { messageId = messageId
                    , stream = streamName
                    , messageType = MessageDb.MessageType "BenchEvent"
                    , messageData = MessageDb.MessageData (Aeson.object ["benchmark" Aeson..= True])
                    , messageMetadata = MessageDb.MessageMetadata (Aeson.object ["correlationStreamName" Aeson..= ("haskell-message-db" :: Text)])
                    , expectedPosition = Nothing
                    }
        outcome <- Connection.use conn (MessageDb.writeStreamMessage message)
        case outcome of
            Left err -> fail ("message-db-hs write failed: " <> show err)
            Right _ -> pure ()

requireMessageDbStream :: Text -> IO MessageDb.Stream
requireMessageDbStream value =
    case MessageDb.parseMaybe value of
        Just streamName -> pure streamName
        Nothing -> fail ("invalid message-db stream name: " <> Text.unpack value)

runKirokuWrites :: Kiroku.KirokuStore -> Int -> (Int -> Text) -> IO ()
runKirokuWrites store n streamFor =
    mapM_ go [1 .. n]
  where
    go i = do
        outcome <-
            Kiroku.runStoreIO store $
                Kiroku.appendToStream
                    (Kiroku.StreamName (streamFor i))
                    Kiroku.AnyVersion
                    [ Kiroku.EventData
                        { eventId = Nothing
                        , eventType = Kiroku.EventType "BenchEvent"
                        , payload = Aeson.object ["benchmark" Aeson..= True]
                        , metadata = Nothing
                        , causationId = Nothing
                        , correlationId = Nothing
                        }
                    ]
        case outcome of
            Left err -> fail ("kiroku-store write failed: " <> show err)
            Right _ -> pure ()

runKirokuWritesSingleProgram :: Kiroku.KirokuStore -> Int -> (Int -> Text) -> IO ()
runKirokuWritesSingleProgram store n streamFor = do
    outcome <-
        Kiroku.runStoreIO store $
            mapM_
                ( \i ->
                    void $
                        Kiroku.appendToStream
                            (Kiroku.StreamName (streamFor i))
                            Kiroku.AnyVersion
                            [ Kiroku.EventData
                                { eventId = Nothing
                                , eventType = Kiroku.EventType "BenchEvent"
                                , payload = Aeson.object ["benchmark" Aeson..= True]
                                , metadata = Nothing
                                , causationId = Nothing
                                , correlationId = Nothing
                                }
                            ]
                )
                [1 .. n]
    case outcome of
        Left err -> fail ("kiroku-store single-program write failed: " <> show err)
        Right () -> pure ()

runConcurrentConnections ::
    Text ->
    Int ->
    (Connection.Connection -> Int -> IO ()) ->
    IO ()
runConcurrentConnections connText workers action =
    mapConcurrently_
        ( \worker ->
            withConnection connText \conn -> do
                setSearchPath conn
                action conn worker
        )
        [1 .. workers]

runConcurrentKirokuWrites ::
    Kiroku.KirokuStore ->
    Int ->
    Int ->
    (Int -> Int -> Text) ->
    IO ()
runConcurrentKirokuWrites store workers opsPerWorker streamFor =
    mapConcurrently_
        ( \worker ->
            runKirokuWrites store opsPerWorker (streamFor worker)
        )
        [1 .. workers]

runConcurrentKirokuWritesSingleProgram ::
    Kiroku.KirokuStore ->
    Int ->
    Int ->
    (Int -> Int -> Text) ->
    IO ()
runConcurrentKirokuWritesSingleProgram store workers opsPerWorker streamFor =
    mapConcurrently_
        ( \worker ->
            runKirokuWritesSingleProgram store opsPerWorker (streamFor worker)
        )
        [1 .. workers]
