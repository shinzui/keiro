module Keiro.Ops.Http.Server
  ( OpsHttpServer (..),
    startOpsHttpServer,
    stopOpsHttpServer,
    withOpsHttpServer,
  )
where

import Control.Concurrent.Async (Async, async, asyncThreadId, asyncWithUnmask, cancel, link)
import Control.Concurrent.MVar
import Control.Exception (bracket, bracketOnError, finally, mask, onException)
import Data.IORef (atomicModifyIORef', newIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Keiro.Ops.Http.Config
import Network.Socket qualified as Socket
import Network.Wai (Application)
import Network.Wai.Handler.Warp qualified as Warp

data OpsHttpServer = OpsHttpServer
  { serverThread :: !(Async ()),
    serverPort :: !Int
  }

startOpsHttpServer :: OpsHttpServerConfig -> Application -> IO OpsHttpServer
startOpsHttpServer config app
  | config.port < 0 || config.port > 65535 || config.requestTimeoutSeconds <= 0 = ioError (userError "invalid inspection server port or timeout")
  | otherwise = mask $ \restore -> do
      -- The runner owns the listener and every connection worker. Closing only
      -- the accept loop leaves keep-alive clients and their handlers alive.
      socket <- openSocket config
      actualPort <- fromIntegral <$> Socket.socketPort socket
      ready <- newEmptyMVar
      clients <- newMVar Map.empty
      -- The accept loop hands one socket at a time to spawn. Retain ownership
      -- even before Warp has constructed and started its connection action.
      pending <- newIORef Nothing
      let takePending = atomicModifyIORef' pending (\accepted -> (Nothing, accepted))
          accept listener = mask $ \_ -> do
            accepted@(connection, _) <- Socket.accept listener
            writeIORef pending (Just connection)
            pure accepted
      let spawn :: ((forall a. IO a -> IO a) -> IO ()) -> IO ()
          spawn action = mask $ \_ -> do
            connection <- takePending
            registered <- newEmptyMVar
            client <- asyncWithUnmask $ \unmask ->
              -- Warp's thread manager may skip the action when shutdown wins
              -- the startup race. Close our socket even if its cleanup never
              -- gets installed. Socket.close is safe after Warp has closed it.
              action (\io -> readMVar registered >> unmask io)
                `finally` ( mapM_ Socket.close connection `finally` do
                              tid <- readMVar registered
                              modifyMVar_ clients (\connections -> pure $! Map.delete tid connections)
                          )
            let tid = asyncThreadId client
            (modifyMVar_ clients (\connections -> pure $! Map.insert tid client connections) >> putMVar registered tid)
              `onException` (tryPutMVar registered tid >> cancel client)
          stopClients = do
            live <- modifyMVar clients (\connections -> pure (Map.empty, Map.elems connections))
            mapM_ cancel live
            takePending >>= mapM_ Socket.close
          settings = Warp.setAccept accept $ Warp.setFork spawn (Warp.setBeforeMainLoop (putMVar ready ()) (Warp.setTimeout config.requestTimeoutSeconds Warp.defaultSettings))
      worker <- async (restore (Warp.runSettingsSocket settings socket app) `finally` (Socket.close socket >> stopClients)) `onException` Socket.close socket
      (link worker >> restore (takeMVar ready)) `onException` (cancel worker >> Socket.close socket)
      pure (OpsHttpServer worker actualPort)

stopOpsHttpServer :: OpsHttpServer -> IO ()
stopOpsHttpServer server = cancel server.serverThread

withOpsHttpServer :: OpsHttpServerConfig -> Application -> (OpsHttpServer -> IO a) -> IO a
withOpsHttpServer config app = bracket (startOpsHttpServer config app) stopOpsHttpServer

openSocket :: OpsHttpServerConfig -> IO Socket.Socket
openSocket config = do
  let hints = Socket.defaultHints {Socket.addrSocketType = Socket.Stream, Socket.addrFlags = [Socket.AI_PASSIVE]}
      host = if config.bindHost == "*" then Nothing else Just (Text.unpack config.bindHost)
  addresses <- Socket.getAddrInfo (Just hints) host (Just (show config.port))
  case addresses of
    [] -> ioError (userError "inspection bind host has no addresses")
    address : _ -> bracketOnError (Socket.socket (Socket.addrFamily address) Socket.Stream Socket.defaultProtocol) Socket.close $ \socket -> do
      Socket.setSocketOption socket Socket.ReuseAddr 1
      Socket.bind socket (Socket.addrAddress address)
      Socket.listen socket Socket.maxListenQueue
      pure socket
