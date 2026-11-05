-- External load process: client allocation never enters runtime RTS counters.
module InspectionClients (runClients) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.MVar
import Control.Exception (bracket, onException, throwIO, try)
import Control.Monad (forM, forM_, forever, unless, void)
import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as Lazy
import Data.ByteString.Lazy.Char8 qualified as Char8
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (statusCode)
import Network.WebSockets qualified as WS
import System.Environment (lookupEnv)
import System.IO (hFlush, hPutStrLn, stderr, stdout)
import System.Timeout (timeout)

runClients :: [String] -> IO ()
runClients [portArg, clientsArg, _, secondsArg, mode]
  | mode `elem` ["wf-counts", "wf-counts-many"] =
      runCountClients (read portArg) (read clientsArg) (read secondsArg)
runClients [portArg, clientsArg, _, secondsArg, mode]
  | mode `elem` ["projection-poll", "projection-feed"] =
      runProjectionClients (read portArg) (read clientsArg) (read secondsArg) (mode == "projection-feed")
runClients [portArg, clientsArg, _, secondsArg, mode]
  | mode `elem` ["pm-types", "pm-types-many"] =
      runManagerClients (read portArg) (read clientsArg) (read secondsArg) (mode == "pm-types-many")
runClients [portArg, clientsArg, viewsArg, secondsArg, mode] = do
  let port = read portArg
      clients = read clientsArg
      views = read viewsArg
      seconds = read secondsArg
  go <- newEmptyMVar
  counters <- newIORef Map.empty
  let count code = atomicModifyIORef' counters (\counts -> (Map.insertWith (+) code (1 :: Int) counts, ()))
      subscribe index
        | views == 32 && index `mod` views == 31 = encode (object ["type" .= ("subscribe" :: Text), "feed" .= ("timers" :: Text)])
        | views == 32 && index `mod` views == 30 = encode (object ["type" .= ("subscribe" :: Text), "feed" .= ("projection_groups" :: Text)])
        | otherwise = encode (object ["type" .= ("subscribe" :: Text), "feed" .= ("workflows" :: Text), "workflow_name" .= (if index `mod` views == 0 then "index-evidence" else "seed-" <> show (index `mod` views - 1)), "limit" .= (100 :: Int)])
      frame connection = do
        raw <- WS.receiveData connection :: IO Lazy.ByteString
        case Aeson.eitherDecode raw of
          Right (Object fields) -> case KeyMap.lookup "type" fields of
            Just (String "snapshot") -> count "snapshot" >> pure "snapshot"
            Just (String "update") -> count "update" >> pure "update"
            Just (String "error") -> count ("feed_" <> show (KeyMap.lookup "code" fields)) >> pure "error"
            _ -> pure "control"
          _ -> fail "invalid feed JSON"
      worker index ready = WS.runClient "127.0.0.1" port "/keiro/ws" $ \connection -> do
        WS.sendTextData connection (subscribe index)
        initial <- frame connection
        unless (initial == ("snapshot" :: Text)) (fail "client did not receive a real initial snapshot")
        putMVar ready (Right ())
        readMVar go
        let consume = if mode == "slow-reader" then threadDelay (seconds * 1000000) else forever (frame connection)
            churn = forever $ do
              threadDelay 1000000
              WS.sendTextData connection (encode (object ["type" .= ("unsubscribe" :: Text), "feed" .= ("workflows" :: Text)]))
              WS.sendTextData connection (subscribe index)
        if mode == "churn" then race_ consume churn else consume
      start index = do
        ready <- newEmptyMVar
        task <- async (worker index ready `onException` void (tryPutMVar ready (Left (userError "feed client failed before readiness"))))
        status <- timeout 10000000 (takeMVar ready)
        case status of
          Just (Right ()) -> pure task
          Just (Left err) -> cancel task >> throwIO err
          Nothing -> cancel task >> fail "feed client readiness timeout"
  -- Sequential handshake avoids benchmarking a startup admission race. All
  -- sockets remain live together during the measured window.
  bracket (forM [0 .. clients - 1] start) (mapM_ cancel) $ \tasks -> do
    manager <- HTTP.newManager HTTP.defaultManagerSettings {HTTP.managerConnCount = clients}
    -- Match the established header-cache experiment: warm the exact 32 poll
    -- keys outside the timed writer window, without counting these requests.
    forM_ [1 .. 32 :: Int] $ \index -> do
      request <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> "/keiro/wf/inspect/header/index-evidence/warm-" <> show index)
      response <- HTTP.httpLbs request manager
      unless (statusCode (HTTP.responseStatus response) == 200) (fail "HTTP view warm-up refused")
    let poll index = do
          request <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> "/keiro/wf/inspect/header/index-evidence/warm-" <> show (1 + index `mod` 32))
          readMVar go
          threadDelay (index * 1000000 `div` clients)
          forever $ do
            result <- try (HTTP.httpLbs request manager) :: IO (Either HTTP.HttpException (HTTP.Response Lazy.ByteString))
            either (const (count "http_exception")) (count . ("http_" <>) . show . statusCode . HTTP.responseStatus) result
            threadDelay 1000000
    bracket (forM [0 .. clients - 1] (async . poll)) (mapM_ cancel) $ \pollers -> do
      putStrLn "ready"
      hFlush stdout
      instruction <- getLine
      if instruction /= "go" then fail "missing measurement control" else pure ()
      putMVar go ()
      -- Surface unexpected client failures instead of measuring a lost load.
      race_ (threadDelay (seconds * 1000000)) (mapConcurrently_ wait (tasks <> pollers))
    HTTP.closeManager manager
  counts <- readIORef counters
  hPutStrLn stderr ("inspection clients: " <> show counts)
  let good = sum [n | (key, n) <- Map.toList counts, key `elem` ["http_200", "snapshot", "update"]]
      bad = sum [n | (key, n) <- Map.toList counts, key `notElem` ["http_200", "snapshot", "update"]]
  Char8.putStrLn (encode (good, bad))
runClients _ = fail "expected PORT CLIENTS VIEWS SECONDS MODE"

-- HTTP-only discovery load: no WebSocket subscriptions or workflow header warmup.
-- Finite staggered schedules retain the intended four requests per second even
-- when request time varies; a failed request or late schedule fails the trial.
runManagerClients :: Int -> Int -> Int -> Bool -> IO ()
runManagerClients port clients seconds many = do
  unless (clients == 4 && seconds > 0) (fail "expected four manager discovery clients")
  let expectedNames = if many then ["alias-" <> Text.justifyRight 4 '0' (Text.pack (show n)) | n <- [1 .. 1000 :: Int]] else ["jitsurei-fulfillment"]
      expected = object ["items" .= [object ["name" .= name, "category" .= ("fulfillment" :: Text), "snapshots_configured" .= False, "snapshot_policy" .= ("never" :: Text), "timers_configured" .= Null] | name <- expectedNames]]
  bracket (HTTP.newManager HTTP.defaultManagerSettings {HTTP.managerConnCount = clients}) HTTP.closeManager $ \manager -> do
    request <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> "/keiro/pm/types")
    let fetch = do
          response <- HTTP.httpLbs request manager
          unless
            (statusCode (HTTP.responseStatus response) == 200 && Aeson.eitherDecode (HTTP.responseBody response) == Right expected)
            (fail "manager discovery poll was refused or returned incorrect metadata")
    fetch
    go <- newEmptyMVar
    successes <- newIORef (0 :: Int)
    let poll index = do
          readMVar go
          threadDelay (index * 1000000 `div` clients)
          forM_ [1 .. seconds] $ \second -> do
            -- Sleep until the next tick independently of request duration.
            withAsync (threadDelay 1000000) $ \tick -> do
              fetch
              atomicModifyIORef' successes (\n -> (n + 1, ()))
              unless (second == seconds) (wait tick)
    bracket (forM [0 .. clients - 1] (async . poll)) (mapM_ cancel) $ \tasks -> do
      putStrLn "ready"
      hFlush stdout
      instruction <- getLine
      unless (instruction == "go") (fail "missing measurement control")
      putMVar go ()
      finished <- timeout ((seconds + 5) * 1000000) (mapConcurrently_ wait tasks)
      unless (finished == Just ()) (fail "manager polling did not sustain the intended load")
    good <- readIORef successes
    unless (good == clients * seconds) (fail "manager polling load disappeared")
    hPutStrLn stderr ("manager discovery clients: successes=" <> show good <> " failures=0")
    Char8.putStrLn (encode (good, 0 :: Int))

-- Matched projection-only load. Client encoding and validation live in a separate
-- process so writer RTS counters measure the mounted runtime, not its clients.
runProjectionClients :: Int -> Int -> Int -> Bool -> IO ()
runProjectionClients port clients seconds feed = do
  expectNames <- (== Just "1") <$> lookupEnv "KEIRO_PROJECTION_EXPECT_SUBSCRIPTIONS"
  let validateRow (Object fields) = case KeyMap.lookup "group_id" fields of
        Just (String group) -> do
          let expected = if "0" `Text.isSuffixOf` group then [group <> "-sub"] else []
          unless
            (not expectNames || KeyMap.lookup "feeding_subscriptions" fields == Just (Aeson.toJSON expected))
            (fail "incorrect feeding subscriptions")
        _ -> fail "missing projection group identity"
      validateRow _ = fail "invalid projection row"
      validateItems (Object fields) = case KeyMap.lookup "items" fields of
        Just (Array rows) | length rows == 100 -> mapM_ validateRow rows
        _ -> fail "expected 100 projection items"
      validateItems _ = fail "invalid projection page"
  go <- newEmptyMVar
  successes <- newIORef (0 :: Int)
  let count = atomicModifyIORef' successes (\n -> (n + 1, ()))
      ready =
        putStrLn "ready" >> hFlush stdout >> getLine >>= \line ->
          if line == "go" then putMVar go () else fail "missing measurement control"
  if feed
    then do
      let worker signal = WS.runClient "127.0.0.1" port "/keiro/ws" $ \connection -> do
            WS.sendTextData connection (encode (object ["type" .= ("subscribe" :: Text), "feed" .= ("projection_groups" :: Text), "limit" .= (100 :: Int)]))
            raw <- WS.receiveData connection :: IO Lazy.ByteString
            value <- either fail pure (Aeson.eitherDecode raw)
            validateItems value
            count
            putMVar signal ()
            readMVar go
            forever $ do
              frame <- WS.receiveData connection :: IO Lazy.ByteString
              case Aeson.eitherDecode frame of
                Right (Object fields) | KeyMap.lookup "type" fields == Just (String "update") ->
                  case KeyMap.lookup "changed" fields of
                    Just (Array rows) -> mapM_ validateRow rows >> count
                    _ -> fail "invalid projection update"
                _ -> fail "projection feed failed"
          start = do
            signal <- newEmptyMVar
            task <- async (worker signal)
            outcome <- race (wait task) (takeMVar signal)
            case outcome of Right () -> pure task; _ -> cancel task >> fail "projection feed startup failed"
      bracket (forM [1 .. clients] (const start)) (mapM_ cancel) $ \tasks -> do
        ready
        race_ (threadDelay (seconds * 1000000)) (mapConcurrently_ wait tasks)
    else bracket (HTTP.newManager HTTP.defaultManagerSettings {HTTP.managerConnCount = clients}) HTTP.closeManager $ \manager -> do
      request <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> "/keiro/projection/status?limit=100")
      let fetch = do
            response <- HTTP.httpLbs request manager
            unless (statusCode (HTTP.responseStatus response) == 200) (fail "projection polling refused")
            either fail validateItems (Aeson.eitherDecode (HTTP.responseBody response))
          worker index = do
            readMVar go
            threadDelay (index * 1000000 `div` clients)
            forM_ [1 .. seconds] $ \second -> withAsync (threadDelay 1000000) $ \tick -> do
              fetch
              count
              unless (second == seconds) (wait tick)
      fetch
      bracket (forM [0 .. clients - 1] (async . worker)) (mapM_ cancel) $ \tasks -> do
        ready
        outcome <- timeout ((seconds + 5) * 1000000) (mapConcurrently_ wait tasks)
        unless (outcome == Just ()) (fail "lost projection polling load")
  good <- readIORef successes
  unless (if feed then good >= clients else good == clients * seconds) (fail "lost projection clients")
  Char8.putStrLn (encode (good, 0 :: Int))

-- Fixed one-second ticks; all eight clients start aligned to exercise admission.
-- Keep raw outcomes on stderr in the controller's retained leg log.
runCountClients :: Int -> Int -> Int -> IO ()
runCountClients port clients seconds =
  bracket (HTTP.newManager HTTP.defaultManagerSettings {HTTP.managerConnCount = clients}) HTTP.closeManager $ \manager -> do
    counters <- newIORef Map.empty
    go <- newEmptyMVar
    let count key = atomicModifyIORef' counters (\m -> (Map.insertWith (+) key (1 :: Int) m, ()))
        names = ["", "?workflow_name=seed-common", "?workflow_name=seed-rare", "?workflow_name=absent"]
        fetch index = do
          request <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> "/keiro/wf/inspect/counts" <> if clients == 1 then "" else names !! (index `mod` 4))
          result <- try (HTTP.httpLbs request manager) :: IO (Either HTTP.HttpException (HTTP.Response Lazy.ByteString))
          case result of
            Left err -> count ("exception:" <> show err)
            Right response -> do
              let code = statusCode (HTTP.responseStatus response)
              count ("http_" <> show code)
              whenSuccess code (HTTP.responseBody response)
        whenSuccess code raw =
          if code /= 200
            then pure ()
            else case Aeson.eitherDecode raw of
              Right (Object fields)
                | Just (Object counts) <- KeyMap.lookup "counts" fields,
                  Just (String _) <- KeyMap.lookup "observed_at" fields,
                  KeyMap.size counts == 7,
                  all (\key -> case KeyMap.lookup key counts of Just (Number n) -> n >= 0 && fromInteger (round n) == n; _ -> False) ["running", "retrying", "sleeping", "awaiting", "completed", "cancelled", "failed"] ->
                    pure ()
              _ -> fail "invalid workflow counts response"
        worker index = do
          readMVar go
          forM_ [1 .. seconds] $ \second -> withAsync (threadDelay 1000000) $ \tick -> do
            fetch index
            unless (second == seconds) (wait tick)
    bracket (forM [0 .. clients - 1] (async . worker)) (mapM_ cancel) $ \tasks -> do
      putStrLn "ready"
      hFlush stdout
      instruction <- getLine
      unless (instruction == "go") (fail "missing measurement control")
      putMVar go ()
      finished <- timeout ((seconds + 5) * 1000000) (mapConcurrently_ wait tasks)
      unless (finished == Just ()) (fail "lost count polling schedule")
    recovery <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> "/keiro/wf/inspect/counts") >>= (\request -> HTTP.httpLbs request manager)
    unless (statusCode (HTTP.responseStatus recovery) == 200) (fail "count admission did not recover")
    outcomes <- readIORef counters
    hPutStrLn stderr ("workflow count outcomes: " <> show outcomes)
    let good = Map.findWithDefault 0 "http_200" outcomes
        bad = sum (Map.elems outcomes) - good
    unless (good > 0 && good + bad == clients * seconds) (fail "count workload disappeared")
    unless (clients /= 1 || bad == 0) (fail "single count client failed")
    unless (all (\key -> key `elem` ["http_200", "http_503"]) (Map.keys outcomes)) (fail "unexpected count failure")
    Char8.putStrLn (encode (good, bad))
