{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedRecordDot #-}

module InboxDelegatedBench
  ( prepareInboxDelegatedBenchmarks,
    runInboxDelegatedExplainIfRequested,
  )
where

import Control.DeepSeq (NFData (..))
import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Data.Time (UTCTime (..), secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement (preparable)
import Hasql.Statement qualified
import Keiro.Command (CommandError (..), CommandResult (..), defaultRunCommandOptions)
import Keiro.Inbox
  ( DelegatedOutcome,
    InboxDedupePolicy (PreferIntegrationMessageId),
    InboxResult (..),
    KafkaDeliveryRef (..),
    runInboxDelegated,
    runInboxDelegatedBatch,
    runInboxTransactionBatch,
    runInboxTransactionWith,
  )
import Keiro.Inbox.Delegated (delegatedCommand, delegatedEventId)
import Keiro.Inbox.Types (InboxPersistence (PersistFullEnvelope))
import Keiro.Integration.Event (IntegrationContentType (ApplicationJson), IntegrationEvent (..))
import Keiro.Prelude
import Keiro.Stream (Stream, stream)
import Keiro.Telemetry (KeiroMetrics)
import Kiroku.Store qualified as Store
import Kiroku.Store.Effect (PreparedEvent, Store)
import Kiroku.Store.SQL qualified as StoreSQL
import Kiroku.Store.Transaction qualified as StoreTransaction
import Kiroku.Store.Types
  ( AppendResult,
    EventData (..),
    EventId (..),
    EventType (..),
    ExpectedVersion (NoStream),
    StreamName (..),
  )
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory)
import Test.Tasty.Bench (Benchmark, bench, bgroup, env, nfIO)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Prelude

deliveryCount :: Int
deliveryCount = 2000

payloadSize :: Int
payloadSize = 1024

fixedOccurredAt :: UTCTime
fixedOccurredAt = UTCTime (ModifiedJulianDay 61000) (secondsToDiffTime 0)

data IntakeMode = TableMode | DelegatedMode | DirectDelegatedMode
  deriving stock (Eq, Show)

data Traffic = FreshTraffic | RepeatedTraffic | DuplicateTraffic
  deriving stock (Eq, Show)

data Scenario = Scenario
  { name :: !Text,
    mode :: !IntakeMode,
    chunkSize :: !Int,
    traffic :: !Traffic,
    metrics :: !(Maybe KeiroMetrics),
    runNumber :: !(IORef Int),
    duplicateRun :: !(Maybe DownstreamRun)
  }

data DownstreamReceipt

data DownstreamWork = DownstreamWork
  { event :: !IntegrationEvent,
    kafka :: !KafkaDeliveryRef,
    targetName :: !StreamName,
    target :: !(Stream DownstreamReceipt),
    marker :: !EventId,
    eventData :: !EventData,
    prepared :: ![PreparedEvent]
  }

data DownstreamRun = DownstreamRun
  { deliveries :: ![(IntegrationEvent, Maybe KafkaDeliveryRef)],
    workByMessageId :: !(Map Text DownstreamWork)
  }

instance NFData DownstreamRun where
  rnf downstreamRun =
    length downstreamRun.deliveries `seq`
      Map.size downstreamRun.workByMessageId `seq`
        ()

prepareInboxDelegatedBenchmarks :: Store.KirokuStore -> KeiroMetrics -> IO [Benchmark]
prepareInboxDelegatedBenchmarks store metrics = do
  runStoreChecked store $ Store.runTransaction (Tx.sql businessTableSql)
  scenarios <- concat <$> traverse (prepareScenario store metrics) scenarioInputs
  pure
    ( [ bgroup
          (Text.unpack scenario.name)
          [ bgroup
              (trafficName scenario.traffic)
              [bench (metricsName scenario.metrics) (nfIO (runScenario store scenario))]
          ]
      | scenario <- scenarios
      ]
        <> [bgroup "delegated-history-duplicate" (historyBenchmark store <$> [10, 1000, 100000])]
    )

runInboxDelegatedExplainIfRequested :: Store.KirokuStore -> IO ()
runInboxDelegatedExplainIfRequested store =
  lookupEnv "KEIRO_INBOX_DELEGATED_EXPLAIN" >>= \case
    Nothing -> pure ()
    Just outputPath -> do
      downstreamRun <- prepareHistoryRun store 100000
      work <- case Map.elems downstreamRun.workByMessageId of
        [] -> fail "explain benchmark run has no work"
        item : _ -> pure item
      let EventId markerUuid = work.marker
          StreamName targetText = work.targetName
          sql =
            "EXPLAIN (ANALYZE, BUFFERS) SELECT EXISTS (SELECT 1 FROM stream_events se WHERE se.event_id = '"
              <> UUID.toText markerUuid
              <> "'::uuid AND se.stream_id = (SELECT stream_id FROM streams WHERE stream_name = '"
              <> targetText
              <> "' AND deleted_at IS NULL))"
          statement =
            preparable
              sql
              Encoders.noParams
              (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))
      planLines <- runStoreChecked store (Store.runTransaction (Tx.statement () statement))
      settings <-
        runStoreChecked store $
          Store.runTransaction $
            traverse
              ( \settingName -> do
                  value <- Tx.statement () (settingStatement settingName)
                  pure (settingName <> " = " <> value)
              )
              ["server_version", "fsync", "synchronous_commit", "full_page_writes"]
      createDirectoryIfMissing True (takeDirectory outputPath)
      Text.IO.writeFile outputPath (Text.unlines (settings <> [""] <> planLines))

settingStatement :: Text -> Hasql.Statement.Statement () Text
settingStatement settingName =
  preparable
    ("SHOW " <> settingName)
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.text)))

scenarioInputs :: [(Text, IntakeMode, Int)]
scenarioInputs =
  [ ("table-downstream-single", TableMode, 1),
    ("delegated-single", DelegatedMode, 1),
    ("delegated-direct-single", DirectDelegatedMode, 1),
    ("table-downstream-batch-100", TableMode, 100),
    ("delegated-batch-100", DelegatedMode, 100),
    ("table-downstream-batch-1000", TableMode, 1000),
    ("delegated-batch-1000", DelegatedMode, 1000)
  ]

prepareScenario :: Store.KirokuStore -> KeiroMetrics -> (Text, IntakeMode, Int) -> IO [Scenario]
prepareScenario store metrics (name, mode, chunkSize) =
  traverse make [(traffic, mMetrics) | traffic <- [FreshTraffic, RepeatedTraffic, DuplicateTraffic], mMetrics <- [Nothing, Just metrics]]
  where
    make (traffic, mMetrics) = do
      runNumber <- newIORef 0
      duplicateRun <-
        case traffic of
          DuplicateTraffic -> do
            prepared <- prepareDownstreamRun (scenarioPrefix name traffic mMetrics <> "-seed") RepeatedTraffic
            seedDuplicateRun store mode prepared
            pure (Just prepared)
          _ -> pure Nothing
      pure Scenario {name, mode, chunkSize, traffic, metrics = mMetrics, runNumber, duplicateRun}

runScenario :: Store.KirokuStore -> Scenario -> IO ()
runScenario store scenario = do
  downstreamRun <- case scenario.duplicateRun of
    Just prepared -> pure prepared
    Nothing -> do
      invocation <- atomicModifyIORef' scenario.runNumber (\current -> let next = current + 1 in (next, next))
      prepareDownstreamRun (scenarioPrefix scenario.name scenario.traffic scenario.metrics <> "-" <> Text.pack (show invocation)) scenario.traffic
  runStoreChecked store (runDownstream scenario downstreamRun)

runDownstream :: (IOE :> es, Store :> es) => Scenario -> DownstreamRun -> Eff es ()
runDownstream scenario downstreamRun =
  case scenario.mode of
    TableMode ->
      if scenario.chunkSize == 1
        then traverse_ (runTableSingle scenario.metrics downstreamRun.workByMessageId) downstreamRun.deliveries
        else traverse_ (runTableBatch scenario.metrics downstreamRun.workByMessageId) (chunksOf scenario.chunkSize downstreamRun.deliveries)
    DelegatedMode ->
      if scenario.chunkSize == 1
        then traverse_ (runDelegatedSingle scenario.metrics downstreamRun.workByMessageId) downstreamRun.deliveries
        else traverse_ (runDelegatedBatch scenario.metrics downstreamRun.workByMessageId) (chunksOf scenario.chunkSize downstreamRun.deliveries)
    DirectDelegatedMode ->
      traverse_ (runDelegatedDirect downstreamRun.workByMessageId) downstreamRun.deliveries

runDelegatedDirect ::
  (IOE :> es, Store :> es) =>
  Map Text DownstreamWork ->
  (IntegrationEvent, Maybe KafkaDeliveryRef) ->
  Eff es ()
runDelegatedDirect workById (event, _) =
  void (delegatedDownstream (lookupWorkPure workById event))

runTableSingle ::
  (IOE :> es, Store :> es) =>
  Maybe KeiroMetrics ->
  Map Text DownstreamWork ->
  (IntegrationEvent, Maybe KafkaDeliveryRef) ->
  Eff es ()
runTableSingle mMetrics workById (event, kafka) = do
  work <- lookupWork workById event
  outcome <-
    runInboxTransactionWith
      mMetrics
      PersistFullEnvelope
      PreferIntegrationMessageId
      event
      kafka
      (\_ -> tableDownstream work)
  expectInboxResult outcome

runTableBatch ::
  (IOE :> es, Store :> es) =>
  Maybe KeiroMetrics ->
  Map Text DownstreamWork ->
  [(IntegrationEvent, Maybe KafkaDeliveryRef)] ->
  Eff es ()
runTableBatch mMetrics workById deliveries = do
  outcomes <-
    runInboxTransactionBatch
      mMetrics
      3
      PreferIntegrationMessageId
      PersistFullEnvelope
      deliveries
      (\event -> tableDownstream (lookupWorkPure workById event))
  traverse_ expectInboxResult outcomes

runDelegatedSingle ::
  (IOE :> es, Store :> es) =>
  Maybe KeiroMetrics ->
  Map Text DownstreamWork ->
  (IntegrationEvent, Maybe KafkaDeliveryRef) ->
  Eff es ()
runDelegatedSingle mMetrics workById (event, kafka) = do
  outcome <-
    runInboxDelegated
      mMetrics
      PreferIntegrationMessageId
      event
      kafka
      (\_ delivered -> delegatedDownstream (lookupWorkPure workById delivered))
  expectInboxResult outcome

runDelegatedBatch ::
  (IOE :> es, Store :> es) =>
  Maybe KeiroMetrics ->
  Map Text DownstreamWork ->
  [(IntegrationEvent, Maybe KafkaDeliveryRef)] ->
  Eff es ()
runDelegatedBatch mMetrics workById deliveries = do
  outcomes <-
    runInboxDelegatedBatch
      mMetrics
      PreferIntegrationMessageId
      deliveries
      (\_ delivered -> delegatedDownstream (lookupWorkPure workById delivered))
  traverse_ expectInboxResult outcomes

tableDownstream :: DownstreamWork -> Tx.Transaction Bool
tableDownstream work = do
  let EventId markerUuid = work.marker
      StreamName targetText = work.targetName
  duplicate <- Tx.statement (targetText, markerUuid) StoreSQL.eventExistsInStreamStmt
  if duplicate
    then pure False
    else do
      StoreTransaction.appendToStreamTx work.targetName NoStream work.prepared fixedOccurredAt >>= \case
        Left _ -> Tx.condemn >> pure False
        Right _ -> Tx.sql businessEffectSql >> pure True

delegatedDownstream ::
  (IOE :> es, Store :> es) =>
  DownstreamWork ->
  Eff es (DelegatedOutcome (CommandResult DownstreamReceipt))
delegatedDownstream work = do
  outcome <-
    delegatedCommand
      defaultRunCommandOptions
      work.targetName
      work.marker
      (\_ -> first StoreFailed <$> appendDownstream work)
  case outcome of
    Left err -> liftIO (fail ("unexpected delegated benchmark command result: " <> show err))
    Right result -> pure result

appendDownstream ::
  (IOE :> es, Store :> es) =>
  DownstreamWork ->
  Eff es (Either Store.StoreError (CommandResult DownstreamReceipt))
appendDownstream work =
  StoreTransaction.runTransactionAppending work.targetName NoStream [work.eventData] $ \appendResult -> do
    Tx.sql businessEffectSql
    pure (commandResult work.target appendResult)

commandResult :: Stream DownstreamReceipt -> AppendResult -> CommandResult DownstreamReceipt
commandResult target appendResult =
  CommandResult
    { target,
      streamVersion = appendResult.streamVersion,
      globalPosition = Just appendResult.globalPosition,
      eventsAppended = 1
    }

expectInboxResult :: (IOE :> es) => Either err (InboxResult a) -> Eff es ()
expectInboxResult = \case
  Right (InboxProcessed _) -> pure ()
  Right InboxDuplicate -> pure ()
  Right _ -> liftIO (fail "unexpected inbox benchmark classification")
  Left _ -> liftIO (fail "unexpected inbox benchmark policy failure")

lookupWork :: (IOE :> es) => Map Text DownstreamWork -> IntegrationEvent -> Eff es DownstreamWork
lookupWork workById event =
  case Map.lookup event.messageId workById of
    Just work -> pure work
    Nothing -> liftIO (fail ("missing downstream benchmark work for " <> Text.unpack event.messageId))

lookupWorkPure :: Map Text DownstreamWork -> IntegrationEvent -> DownstreamWork
lookupWorkPure workById event =
  case Map.lookup event.messageId workById of
    Just work -> work
    Nothing -> error ("missing downstream benchmark work for " <> Text.unpack event.messageId)

prepareDownstreamRun :: Text -> Traffic -> IO DownstreamRun
prepareDownstreamRun prefix traffic = do
  uniqueWorks <- traverse (prepareWork prefix) uniqueIndexes
  let selected = case (traffic, uniqueWorks) of
        (FreshTraffic, _) -> uniqueWorks
        (RepeatedTraffic, work : _) -> Prelude.replicate deliveryCount work
        (DuplicateTraffic, work : _) -> Prelude.replicate deliveryCount work
        _ -> error "prepareDownstreamRun: traffic generated no work"
      deliveries = [(work.event, Just work.kafka) | work <- selected]
      workByMessageId = Map.fromList [(work.event.messageId, work) | work <- uniqueWorks]
  pure DownstreamRun {deliveries, workByMessageId}
  where
    uniqueIndexes = case traffic of
      FreshTraffic -> [1 .. deliveryCount]
      RepeatedTraffic -> [1]
      DuplicateTraffic -> [1]

prepareWork :: Text -> Int -> IO DownstreamWork
prepareWork prefix item = do
  let suffix = prefix <> "-" <> Text.pack (show item)
      messageId = "bench-delegated-" <> suffix
      event = integrationEvent messageId
      kafka = KafkaDeliveryRef "bench.inbox.delegated.v1" 0 (fromIntegral item)
      targetName = StreamName ("benchInbox-" <> suffix)
      target = stream ("benchInbox-" <> suffix)
      marker = delegatedEventId "keiro-bench" event.source messageId targetName "apply"
      eventData = receiptEvent marker
  prepared <- StoreTransaction.prepareEventsIO [eventData]
  pure DownstreamWork {event, kafka, targetName, target, marker, eventData, prepared}

seedDuplicateRun :: Store.KirokuStore -> IntakeMode -> DownstreamRun -> IO ()
seedDuplicateRun store mode downstreamRun =
  runStoreChecked store do
    case downstreamRun.deliveries of
      [] -> liftIO (fail "duplicate benchmark run has no delivery")
      delivery : _ ->
        case mode of
          TableMode -> runTableSingle Nothing downstreamRun.workByMessageId delivery
          DelegatedMode -> runDelegatedSingle Nothing downstreamRun.workByMessageId delivery
          DirectDelegatedMode -> runDelegatedDirect downstreamRun.workByMessageId delivery

historyBenchmark :: Store.KirokuStore -> Int -> Benchmark
historyBenchmark store historySize =
  env (prepareHistoryRun store historySize) $ \downstreamRun ->
    bench ("events-" <> show historySize) $
      nfIO $
        runStoreChecked store $
          traverse_ (runDelegatedSingle Nothing downstreamRun.workByMessageId) downstreamRun.deliveries

prepareHistoryRun :: Store.KirokuStore -> Int -> IO DownstreamRun
prepareHistoryRun store historySize = do
  downstreamRun <- prepareDownstreamRun ("history-" <> Text.pack (show historySize)) DuplicateTraffic
  seedDuplicateRun store DelegatedMode downstreamRun
  case Map.elems downstreamRun.workByMessageId of
    [] -> fail "history benchmark run has no work"
    work : _ ->
      runStoreChecked store $
        traverse_
          (\chunk -> void (Store.appendToStream work.targetName Store.AnyVersion chunk))
          (chunksOf 1000 (Prelude.replicate (max 0 (historySize - 1)) historyEvent))
  pure downstreamRun

historyEvent :: EventData
historyEvent =
  EventData
    { eventId = Nothing,
      eventType = EventType "BenchHistoricalEvent",
      payload = Aeson.toJSON (0 :: Int),
      metadata = Nothing,
      causationId = Nothing,
      correlationId = Nothing
    }

integrationEvent :: Text -> IntegrationEvent
integrationEvent messageId =
  IntegrationEvent
    { messageId,
      source = "bench.inbox.delegated",
      destination = "bench.inbox.delegated.v1",
      key = Just messageId,
      eventType = "BenchDelegatedIntake",
      schemaVersion = 1,
      contentType = ApplicationJson,
      schemaReference = Nothing,
      sourceEventId = Nothing,
      sourceGlobalPosition = Nothing,
      payloadBytes = ByteString.replicate payloadSize 65,
      occurredAt = fixedOccurredAt,
      causationId = Nothing,
      correlationId = Nothing,
      traceContext = Nothing,
      attributes = Nothing
    }

receiptEvent :: EventId -> EventData
receiptEvent marker =
  EventData
    { eventId = Just marker,
      eventType = EventType "BenchDelegatedApplied",
      payload = Aeson.toJSON ("applied" :: Text),
      metadata = Nothing,
      causationId = Nothing,
      correlationId = Nothing
    }

scenarioPrefix :: Text -> Traffic -> Maybe KeiroMetrics -> Text
scenarioPrefix name traffic mMetrics =
  Text.intercalate "-" [name, Text.pack (trafficName traffic), Text.pack (metricsName mMetrics)]

trafficName :: Traffic -> String
trafficName = \case
  FreshTraffic -> "fresh"
  RepeatedTraffic -> "repeated-key"
  DuplicateTraffic -> "all-duplicate"

metricsName :: Maybe KeiroMetrics -> String
metricsName = maybe "metrics-off" (const "metrics-on")

chunksOf :: Int -> [a] -> [[a]]
chunksOf n xs
  | n <= 0 = error "chunksOf: non-positive chunk size"
  | otherwise =
      case splitAt n xs of
        ([], _) -> []
        (chunk, rest) -> chunk : chunksOf n rest

businessTableSql :: ByteString.ByteString
businessTableSql =
  "CREATE TABLE IF NOT EXISTS keiro.keiro_inbox_delegated_bench_effect (singleton bool PRIMARY KEY DEFAULT true, applied bigint NOT NULL DEFAULT 0); INSERT INTO keiro.keiro_inbox_delegated_bench_effect (singleton, applied) VALUES (true, 0) ON CONFLICT (singleton) DO NOTHING"

businessEffectSql :: ByteString.ByteString
businessEffectSql =
  "UPDATE keiro.keiro_inbox_delegated_bench_effect SET applied = applied + 1 WHERE singleton = true"

runStoreChecked :: Store.KirokuStore -> Eff '[Store, Error Store.StoreError, IOE] a -> IO a
runStoreChecked store action = do
  result <- Store.runStoreIO store action
  case result of
    Left err -> fail (show err)
    Right value -> pure value
