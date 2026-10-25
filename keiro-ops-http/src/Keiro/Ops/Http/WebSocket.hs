-- | One socket writer and a multiplexed, bounded connection queue. Notifications
-- remain hints; all frames are produced by supported inspection reads.
module Keiro.Ops.Http.WebSocket (feedServerApp, feedsMiddleware, opsApplicationWithFeeds) where

import Control.Concurrent.Async (race_)
import Control.Concurrent.STM
import Control.Exception (bracket, catch, finally, mask, onException, throwIO)
import Control.Monad (forM_, void, when)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as Text
import Keiro.Ops (AppHooks)
import Keiro.Ops.Http.Application (opsApplicationWithBudget)
import Keiro.Ops.Http.Budget qualified as Budget
import Keiro.Ops.Http.Config
import Keiro.Ops.Http.Cors qualified as Cors
import Keiro.Ops.Http.Feed qualified as Feed
import Keiro.Ops.Http.Feed.Driver qualified as Driver
import Keiro.Ops.Http.Feed.Queue qualified as Queue
import Keiro.Ops.Http.Protocol qualified as P
import Keiro.Ops.Http.Views
import Kiroku.Store.Connection (KirokuStore)
import Network.Wai (Application, Middleware, pathInfo)
import Network.Wai.Handler.WebSockets qualified as WaiWS
import Network.WebSockets qualified as WS
import System.Timeout (timeout)

opsApplicationWithFeeds :: OpsHttpConfig -> Feed.FeedHandle -> AppHooks -> KirokuStore -> IO Application
opsApplicationWithFeeds config handle hooks store
  | config /= Feed.handleHttpConfig handle = ioError (userError "HTTP and feeds must share the same inspection policy and budget")
  | otherwise = feedsMiddleware config handle <$> opsApplicationWithBudget config (Feed.handleBudget handle) hooks store

feedsMiddleware :: OpsHttpConfig -> Feed.FeedHandle -> Middleware
feedsMiddleware config handle application request respond
  | pathInfo request == ["ws"] = WaiWS.websocketsOr options (feedServerApp config handle) application request respond
  | otherwise = application request respond
  where
    maximum = fromIntegral config.inspectionLimits.maxRequestBytes
    options = WS.defaultConnectionOptions {WS.connectionFramePayloadSizeLimit = WS.SizeLimit maximum, WS.connectionMessageDataSizeLimit = WS.SizeLimit maximum}

feedServerApp :: OpsHttpConfig -> Feed.FeedHandle -> WS.ServerApp
feedServerApp config handle pending
  | config /= Feed.handleHttpConfig handle = reject 500 "invalid_feed_policy" "HTTP and feeds have different host policies"
  | Char8.takeWhile (/= '?') request.requestPath /= "/ws" = reject 404 "not_found" "no inspection socket at this path"
  | Bytes.length request.requestPath > config.inspectionLimits.maxRequestBytes = reject 413 "inspection_request_too_large" "socket path exceeds the host limit"
  | not (originAllowed config request) = reject 403 "origin_not_allowed" "socket origin is not allowed"
  | otherwise = do
      admitted <- Feed.withFeedConnection handle $ do
        checked <- Budget.withInspectionBudget (Feed.handleBudget handle) config.inspectionLimits.readDeadlineSeconds (Feed.checkFeedSchema handle)
        case checked of
          Left Budget.InspectionBusy -> reject 503 "inspection_busy" "inspection read capacity is busy"
          Left Budget.InspectionTimedOut -> reject 504 "inspection_timeout" "schema verification exceeded the read deadline"
          Right Feed.FeedSchemaReadFailed -> reject 500 "schema_check_failed" "schema verification failed"
          Right Feed.FeedSchemaDrift | config.schemaDrift == RefuseOnDrift -> reject 409 "schema_drift" "database schema does not match this binary"
          Right _ -> do
            closed <- atomically (Feed.handleClosed handle)
            if closed
              then reject 503 "feed_closed" "inspection feeds are closed"
              else WS.acceptRequest pending >>= runConnection handle
      case admitted of
        Just () -> pure ()
        Nothing -> reject 503 "too_many_connections" "socket connection capacity is full"
  where
    request = WS.pendingRequest pending
    reject code reason message =
      WS.rejectRequestWith
        pending
        WS.defaultRejectRequest
          { WS.rejectCode = code,
            WS.rejectMessage = "Inspection request refused",
            WS.rejectHeaders = [("Content-Type", "application/json")],
            WS.rejectBody = Lazy.toStrict (Aeson.encode (object ["error" .= object ["code" .= (reason :: Text), "message" .= (message :: Text)]]))
          }

originAllowed :: OpsHttpConfig -> WS.RequestHead -> Bool
originAllowed config request =
  all (\(key, value) -> key /= "Origin" || Bytes.length value <= config.inspectionLimits.maxRequestBytes) request.requestHeaders
    && Cors.originAllowed config.allowedOrigins request.requestSecure request.requestHeaders

type Subscription = (View, Feed.Driver, Feed.Subscriber)

runConnection :: Feed.FeedHandle -> WS.Connection -> IO ()
runConnection handle connection = do
  let config = Feed.handleFeedConfig handle
  queue <- Queue.newOutboundQueue config.queueCapacity config.maxQueuedBytes config.maxFrameBytes
  subscriptions <- newIORef Map.empty
  let cleanup = do
        atomically (Queue.closeQueue queue)
        current <- atomicModifyIORef' subscriptions (\values -> (Map.empty, values))
        forM_ (Map.elems current) $ \(view, driver, subscriber) -> do
          Feed.unsubscribe driver subscriber
          Feed.releaseDriver handle view
      sendControl frame = do
        prepared <- Queue.prepareOutgoing (min config.maxFrameBytes config.maxQueuedBytes) frame
        case prepared of
          Nothing -> throwIO (userError "socket control frame exceeds host limits")
          Just outgoing -> void (atomically (Queue.enqueueOutgoing queue outgoing))
      failure code message feed = sendControl (P.ErrorFrame code message feed)
      receive = do
        bytes <- WS.receiveData connection :: IO Lazy.ByteString
        case Aeson.eitherDecode bytes of
          Left _ -> failure P.InvalidFrame "invalid socket frame" Nothing
          Right P.Ping -> sendControl P.Pong
          Right (P.UnknownSubscription _) -> failure P.UnknownFeed "unknown feed" Nothing
          Right (P.Unsubscribe name) -> mask $ \_ -> do
            current <- readIORef subscriptions
            forM_ (Map.lookup name current) $ \(view, driver, subscriber) -> do
              atomically (Driver.unsubscribeSTM driver subscriber)
              writeIORef subscriptions (Map.delete name current)
              Feed.releaseDriver handle view
            sendControl (P.Unsubscribed name)
          Right (P.Subscribe name filters) -> case makeView name filters of
            Left message -> failure P.InvalidSubscription message (Just name)
            Right view -> replaceSubscription handle queue subscriptions name view failure
        receive
      send = do
        again <-
          bracket
            ( timeout
                (config.idlePingSeconds * 1000000)
                ( atomically $ do
                    closed <- Feed.handleClosed handle
                    if closed then Queue.closeQueue queue >> pure Nothing else Queue.nextOutgoing queue
                )
            )
            (\case Just (Just outgoing) -> atomically (Queue.finishOutgoing queue outgoing); _ -> pure ())
            ( \case
                Nothing -> boundedSend (WS.sendPing connection ("" :: Bytes.ByteString)) >> pure True
                Just Nothing -> do
                  boundedSend (WS.sendTextData connection (Aeson.encode P.Goodbye))
                  boundedSend (WS.sendClose connection ("inspection feeds closed" :: Text))
                  pure False
                Just (Just outgoing) -> boundedSend (WS.sendTextData connection outgoing.bytes) >> pure True
            )
        when again send
      boundedSend action =
        timeout (ceiling (config.readTimeout * 1000000)) action
          >>= maybe
            (throwIO (userError "socket send deadline exceeded"))
            pure
      makeView = \case P.Workflows -> workflowsView config.maxItems; P.Timers -> timersView config.maxItems; P.ProjectionGroups -> projectionGroupsView config.maxItems
  (race_ receive send `catch` (\(_ :: WS.ConnectionException) -> pure ())) `finally` cleanup

-- Acquiring a replacement does not disturb the old subscription on refusal.
-- The queue purge, detach and attach commit atomically so old-view deltas cannot
-- arrive after the new snapshot. Balanced registry releases cannot be cancelled.
replaceSubscription :: Feed.FeedHandle -> Queue.OutboundQueue -> IORef (Map.Map P.FeedName Subscription) -> P.FeedName -> View -> (P.SocketErrorCode -> Text -> Maybe P.FeedName -> IO ()) -> IO ()
replaceSubscription handle queue subscriptions name view failure = mask $ \restore -> do
  current <- readIORef subscriptions
  case Map.lookup name current of
    Just (old, driver, _) | old.viewId == view.viewId -> atomically $ do
      Queue.purgeFeed queue name
      Driver.enqueueSnapshot driver queue
    previous -> do
      acquired <- Feed.acquireDriver handle view
      case acquired of
        Left problem ->
          restore
            ( failure
                ( case problem of
                    Feed.TooManyViews -> P.TooManyViews
                    Feed.FeedBusy -> P.InspectionBusy
                    Feed.FeedRetiring -> P.ViewRetiring
                    Feed.InitialResultTooLarge -> P.InspectionResultTooLarge
                    _ -> P.ReadFailed
                )
                "subscription could not be initialized"
                (Just name)
            )
        Right driver -> do
          subscriber <-
            ( atomically $ do
                forM_ previous (\(_, old, subscriber) -> Driver.unsubscribeSTM old subscriber)
                Driver.subscribeOnQueue driver queue
            )
              `onException` Feed.releaseDriver handle view
          writeIORef subscriptions (Map.insert name (view, driver, subscriber) current)
          forM_ previous (\(old, _, _) -> Feed.releaseDriver handle old)
