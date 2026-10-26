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
import System.IO (hFlush, hPutStrLn, stderr, stdout)
import System.Timeout (timeout)

runClients :: [String] -> IO ()
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
