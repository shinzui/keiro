module Main
  ( main
  )
where

import Data.Aeson (object, withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Contravariant.Extras (contrazip2, contrazip3, contrazip4)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Effectful (Eff, IOE, (:>))
import Kiroku.Store.Effect (Store)
import Data.Vector qualified as Vector
import Data.UUID (UUID, fromString)
import Data.Time (UTCTime (..), secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import EphemeralPg qualified as Pg
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Keiki.Core
  ( Edge (..)
  , HsPred (..)
  , InCtor (..)
  , IndexN
  , RegFile (..)
  , SymTransducer (..)
  , Update (..)
  , WireCtor (..)
  , inpCtor
  , matchInCtor
  , oNil
  , pack
  , proj
  , (*:)
  , (.==)
  )
import Keiki.Core qualified as Keiki
import Keiro
import Keiro qualified as KeiroRoot
import Keiro.Integration.Event
  ( IntegrationContentType (..)
  , IntegrationEvent (..)
  , SchemaReference (..)
  , TraceContext (..)
  , decodeJsonIntegrationEvent
  , encodeJsonIntegrationEvent
  , headerContentType
  , headerMessageId
  , headerSchemaSubject
  , headerSchemaVersion
  , headerSourceEventId
  , headerSourceGlobalPosition
  , headerTraceParent
  , integrationHeaders
  , integrationPayload
  , parseContentType
  )
import Keiro.Integration.Event qualified as IntegrationEvent
import Keiro.Outbox
  ( IntegrationEventDraft (..)
  , IntegrationProducer (..)
  , OutboxStatus (..)
  , PublishOutcome (..)
  , OrderingPolicy (..)
  , BackoffSchedule (..)
  , OutboxId (..)
  , OutboxRow (..)
  , claimOutboxBatch
  , defaultPublishOptions
  , draftToEvent
  , enqueueIntegrationEventTx
  , freshOutboxId
  , initializeOutboxSchema
  , lookupOutbox
  , markOutboxSent
  , mintIntegrationEvent
  , publishClaimedOutbox
  )
import Keiro.Outbox.Kafka qualified as OutboxKafka
import Keiro.Inbox
  ( InboxDedupePolicy (..)
  , InboxError (..)
  , InboxResult (..)
  , InboxStatus (..)
  , KafkaDeliveryRef (..)
  , garbageCollectCompleted
  , initializeInboxSchema
  , listInbox
  , lookupInbox
  , runInboxTransaction
  )
import Keiro.Inbox.Kafka qualified as InboxKafka
import Data.Time (NominalDiffTime)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, readMVar)
import Keiro.Prelude
import Keiro.Projection
import Keiro.ProcessManager
import Keiro.ReadModel
import Keiro.ReadModel.Rebuild qualified as Rebuild
import Keiro.Stream qualified as Stream
import Keiro.Telemetry qualified as Telemetry
import Keiro.Timer
import Kiroku.Store qualified as Store
import Kiroku.Store.Types
  ( EventId (..)
  , EventData (..)
  , EventType (..)
  , ExpectedVersion (..)
  , GlobalPosition (..)
  , CategoryName (..)
  , RecordedEvent (..)
  , StreamId (..)
  , StreamName (..)
  , StreamVersion (..)
  )
import OpenTelemetry.Attributes (Attribute (..), Attributes, PrimitiveAttribute (..), lookupAttribute)
import OpenTelemetry.Attributes.Key (AttributeKey, unkey)
import OpenTelemetry.Exporter.InMemory.Span (inMemoryListExporter)
import OpenTelemetry.Trace
  ( SpanStatus (..)
  , createTracerProvider
  , emptyTracerProviderOptions
  , makeTracer
  , shutdownTracerProvider
  , tracerOptions
  )
import OpenTelemetry.Trace.Core (ImmutableSpan (..), SpanContext (..), getSpanContext)
import Test.Hspec

main :: IO ()
main = hspec $ do
  describe "Keiro" $ do
    it "exposes the scaffold version" $
      KeiroRoot.version `shouldBe` ("0.1.0.0" :: Text)

  describe "Keiro.Stream" $ do
    it "wraps and unwraps kiroku stream names" $ do
      let orderStream = stream "order-123" :: Stream OrderStream
      Stream.streamName orderStream `shouldBe` StreamName "order-123"
      Stream.streamName (mapStreamName (\(StreamName name) -> StreamName (name <> "-archived")) orderStream)
        `shouldBe` StreamName "order-123-archived"

  describe "Keiro.Codec" $ do
    it "encodes current events with type tags and schema-version metadata" $ do
      encoded <- shouldBeRight (encodeForAppend orderCodec (OrderPlaced "order-123" 5))
      encoded ^. #eventType `shouldBe` EventType "OrderPlaced"
      encoded ^. #payload `shouldBe` object ["orderId" Aeson..= ("order-123" :: Text), "quantity" Aeson..= (5 :: Int)]
      extractSchemaVersion (recordedFrom encoded) `shouldBe` 2

    it "round-trips current events" $ do
      encoded <- shouldBeRight (encodeForAppend orderCodec (OrderPlaced "order-123" 5))
      decodeRecorded orderCodec (recordedFrom encoded) `shouldBe` Right (OrderPlaced "order-123" 5)

    it "runs upcasters in source-version order" $
      decodeRaw orderCodec 1 (object ["orderId" Aeson..= ("order-123" :: Text), "qty" Aeson..= (5 :: Int)])
        `shouldBe` Right (OrderPlaced "order-123" 5)

    it "rejects gaps in upcaster chains" $
      decodeRaw gappyCodec 1 (object ["orderId" Aeson..= ("order-123" :: Text), "qty" Aeson..= (5 :: Int)])
        `shouldBe` Left (GapInUpcasterChain 2 3)

    it "rejects recorded events with unknown type tags" $ do
      let encoded = recordedFrom EventData
            { eventId = Nothing
            , eventType = EventType "OrderCancelled"
            , payload = object ["orderId" Aeson..= ("order-123" :: Text)]
            , metadata = Just (metadataFor 2 Nothing)
            , causationId = Nothing
            , correlationId = Nothing
            }
      decodeRecorded orderCodec encoded
        `shouldBe` Left (UnknownEventType (EventType "OrderCancelled") ["OrderPlaced"])

  describe "Keiro.EventStream" $ do
    it "constructs an author-facing EventStream contract" $ do
      let contract = EventStream
            { transducer = emptyTransducer
            , initialState = Idle
            , initialRegisters = RNil
            , eventCodec = orderCodec
            , resolveStreamName = \s -> Stream.streamName s
            , snapshotPolicy = Never
            , stateCodec = Nothing
            }
          typedStream = stream "order-123" :: Stream (EventStream () '[] OrderState OrderCommand OrderEvent)
      contract ^. #initialState `shouldBe` Idle
      (contract ^. #resolveStreamName) typedStream `shouldBe` StreamName "order-123"

  describe "Keiro.Command" $ around withTestStore $ do
    it "creates a stream and appends the first command event" $ \storeHandle -> do
      let target = stream "counter-command-create" :: Stream CounterEventStream
      result <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions counterEventStream target (Add 2)
      case result of
        Right (Right commandResult) -> do
          commandResult ^. #streamVersion `shouldBe` StreamVersion 1
          commandResult ^. #eventsAppended `shouldBe` 1
          commandResult ^. #globalPosition `shouldSatisfy` isJust
        other -> expectationFailure ("expected successful command, got " <> show other)
      Right recorded <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "counter-command-create") (StreamVersion 0) 10
      Vector.length recorded `shouldBe` 1
      traverse (decodeRecorded counterCodec) (Vector.toList recorded)
        `shouldBe` Right [CounterAdded 2]

    it "rehydrates prior events before appending a second command event" $ \storeHandle -> do
      let target = stream "counter-command-update" :: Stream CounterEventStream
      Right (Right _) <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions counterEventStream target (Add 2)
      result <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions counterEventStream target (Add 3)
      case result of
        Right (Right commandResult) ->
          commandResult ^. #streamVersion `shouldBe` StreamVersion 2
        other -> expectationFailure ("expected successful second command, got " <> show other)
      Right recorded <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "counter-command-update") (StreamVersion 0) 10
      traverse (decodeRecorded counterCodec) (Vector.toList recorded)
        `shouldBe` Right [CounterAdded 2, CounterAdded 3]

    it "uses caller-supplied event ids for idempotent command batches" $ \storeHandle -> do
      let target = stream "counter-command-event-id" :: Stream CounterEventStream
          supplied = EventId sampleUuid2
          options = defaultRunCommandOptions & #eventIds .~ [supplied]
      result <- Store.runStoreIO storeHandle $
        runCommand options counterEventStream target (Add 7)
      case result of
        Right (Right commandResult) ->
          commandResult ^. #streamVersion `shouldBe` StreamVersion 1
        other -> expectationFailure ("expected successful command, got " <> show other)
      Right recorded <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "counter-command-event-id") (StreamVersion 0) 10
      fmap (^. #eventId) (Vector.toList recorded) `shouldBe` [supplied]

    it "retries an optimistic conflict after rehydrating the winning event" $ \storeHandle -> do
      conflictInserted <- newIORef False
      let target = stream "counter-command-conflict" :: Stream CounterEventStream
          conflictStreamName = StreamName "counter-command-conflict"
          insertConflict = do
            shouldInsert <- atomicModifyIORef' conflictInserted $ \alreadyInserted ->
              if alreadyInserted
                then (True, False)
                else (True, True)
            when shouldInsert $ do
              encoded <- shouldBeRight (encodeForAppend counterCodec (CounterAdded 10))
              outcome <- Store.runStoreIO storeHandle $
                Store.appendToStream conflictStreamName NoStream [encoded]
              case outcome of
                Right _ -> pure ()
                Left err -> expectationFailure ("failed to insert conflict event: " <> show err)
          options = defaultRunCommandOptions & #beforeAppend .~ insertConflict
      result <- Store.runStoreIO storeHandle $
        runCommand options counterEventStream target (Add 2)
      case result of
        Right (Right commandResult) -> do
          commandResult ^. #streamVersion `shouldBe` StreamVersion 2
          commandResult ^. #eventsAppended `shouldBe` 1
        other -> expectationFailure ("expected retry to succeed, got " <> show other)
      Right recorded <- Store.runStoreIO storeHandle $
        Store.readStreamForward conflictStreamName (StreamVersion 0) 10
      traverse (decodeRecorded counterCodec) (Vector.toList recorded)
        `shouldBe` Right [CounterAdded 10, CounterAdded 2]

    it "surfaces decode failure during hydration" $ \storeHandle -> do
      Right _ <- Store.runStoreIO storeHandle $
        Store.appendToStream
          (StreamName "counter-command-decode-failure")
          NoStream
          [ EventData
              { eventId = Nothing
              , eventType = EventType "OtherEvent"
              , payload = object []
              , metadata = Just (metadataFor 1 Nothing)
              , causationId = Nothing
              , correlationId = Nothing
              }
          ]
      let target = stream "counter-command-decode-failure" :: Stream CounterEventStream
      result <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions counterEventStream target (Add 1)
      result
        `shouldBe` Right
          (Left (HydrationDecodeFailed (UnknownEventType (EventType "OtherEvent") ["CounterAdded", "CounterAudited"])))

    it "rolls back the append when inline SQL condemns the transaction" $ \storeHandle -> do
      let target = stream "counter-command-rollback" :: Stream CounterEventStream
      result <- Store.runStoreIO storeHandle $
        runCommandWithSql
          defaultRunCommandOptions
          counterEventStream
          target
          (Add 1)
          (\_ -> Tx.condemn >> pure ("rolled-back" :: Text))
      case result of
        Right (Right (_, Just "rolled-back")) -> pure ()
        other -> expectationFailure ("expected condemned transaction result, got " <> show other)
      Right recorded <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "counter-command-rollback") (StreamVersion 0) 10
      recorded `shouldBe` Vector.empty

    it "appends all events emitted by one accepted command" $ \storeHandle -> do
      let target = stream "counter-command-multi-create" :: Stream CounterEventStream
      result <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions multiCounterEventStream target (Add 5)
      case result of
        Right (Right commandResult) -> do
          commandResult ^. #streamVersion `shouldBe` StreamVersion 2
          commandResult ^. #eventsAppended `shouldBe` 2
          commandResult ^. #globalPosition `shouldSatisfy` isJust
        other -> expectationFailure ("expected successful multi-event command, got " <> show other)
      Right recorded <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "counter-command-multi-create") (StreamVersion 0) 10
      traverse (decodeRecorded counterCodec) (Vector.toList recorded)
        `shouldBe` Right [CounterAdded 5, CounterAudited 5]

    it "replays a prior multi-event command before appending the next batch" $ \storeHandle -> do
      let target = stream "counter-command-multi-replay" :: Stream CounterEventStream
      Right (Right _) <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions multiCounterEventStream target (Add 2)
      result <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions multiCounterEventStream target (Add 3)
      case result of
        Right (Right commandResult) -> do
          commandResult ^. #streamVersion `shouldBe` StreamVersion 4
          commandResult ^. #eventsAppended `shouldBe` 2
        other -> expectationFailure ("expected successful second multi-event command, got " <> show other)
      Right recorded <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "counter-command-multi-replay") (StreamVersion 0) 10
      traverse (decodeRecorded counterCodec) (Vector.toList recorded)
        `shouldBe` Right [CounterAdded 2, CounterAudited 2, CounterAdded 3, CounterAudited 3]

    it "passes the complete multi-event batch to inline SQL in append order" $ \storeHandle -> do
      let target = stream "counter-command-multi-sql-events" :: Stream CounterEventStream
      result <- Store.runStoreIO storeHandle $
        runCommandWithSqlEvents
          defaultRunCommandOptions
          multiCounterEventStream
          target
          (Add 8)
          (\events _ -> pure events)
      case result of
        Right (Right (commandResult, Just observed)) -> do
          commandResult ^. #streamVersion `shouldBe` StreamVersion 2
          commandResult ^. #eventsAppended `shouldBe` 2
          observed `shouldBe` [CounterAdded 8, CounterAudited 8]
        other -> expectationFailure ("expected successful SQL multi-event command, got " <> show other)

  describe "Keiro.Snapshot" $ around withTestStore $ do
    it "writes a snapshot after policy threshold" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeSnapshotSchema
      let target = stream "snapshot-write-threshold" :: Stream SnapshotCounterEventStream
      Right (Right _) <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 2)
      Right (Right _) <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 3)
      Right snapshotVersion <- Store.runStoreIO storeHandle $
        Store.runTransaction $
          Tx.statement "snapshot-write-threshold" snapshotVersionForStreamStmt
      snapshotVersion `shouldBe` Just (StreamVersion 2)

    it "hydrates from snapshot and replays only the tail" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeSnapshotSchema
      let target = stream "snapshot-tail-hydration" :: Stream SnapshotCounterEventStream
      Right (Right _) <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 2)
      Right (Right _) <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 3)
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction $
          Tx.statement
            ( "snapshot-tail-hydration"
            , (defaultStateCodec @SnapshotCounterRegs @CounterState 1 ^. #encode)
                (Counting, RCons (Proxy @"lastAmount") 4 RNil)
            )
            corruptSnapshotStateStmt
      result <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions guardedSnapshotCounterEventStream target (Add 4)
      case result of
        Right (Right commandResult) ->
          commandResult ^. #streamVersion `shouldBe` StreamVersion 3
        other -> expectationFailure ("expected snapshot-assisted command, got " <> show other)

    it "falls back when snapshot JSON is corrupt" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeSnapshotSchema
      let target = stream "snapshot-corrupt-json" :: Stream SnapshotCounterEventStream
      Right (Right _) <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 2)
      Right (Right _) <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 3)
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction $
          Tx.statement ("snapshot-corrupt-json", Aeson.String "bad") corruptSnapshotStateStmt
      result <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 4)
      case result of
        Right (Right commandResult) ->
          commandResult ^. #streamVersion `shouldBe` StreamVersion 3
        other -> expectationFailure ("expected corrupt snapshot fallback, got " <> show other)

    it "falls back when shape hash mismatches" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeSnapshotSchema
      let target = stream "snapshot-shape-mismatch" :: Stream SnapshotCounterEventStream
      Right (Right _) <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 2)
      Right (Right _) <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 3)
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction $
          Tx.statement ("snapshot-shape-mismatch", "stale-shape") corruptSnapshotShapeStmt
      result <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 4)
      case result of
        Right (Right commandResult) ->
          commandResult ^. #streamVersion `shouldBe` StreamVersion 3
        other -> expectationFailure ("expected stale shape fallback, got " <> show other)

    it "falls back after operator truncation" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeSnapshotSchema
      let target = stream "snapshot-operator-truncate" :: Stream SnapshotCounterEventStream
      Right (Right _) <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 2)
      Right (Right _) <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 3)
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction $
          Tx.sql "TRUNCATE keiro_snapshots"
      result <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions snapshotCounterEventStream target (Add 4)
      case result of
        Right (Right commandResult) ->
          commandResult ^. #streamVersion `shouldBe` StreamVersion 3
        other -> expectationFailure ("expected truncation fallback, got " <> show other)

    it "writes snapshots after applying a complete multi-event command batch" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeSnapshotSchema
      let target = stream "snapshot-multi-event-batch" :: Stream SnapshotCounterEventStream
      result <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions multiSnapshotCounterEventStream target (Add 9)
      case result of
        Right (Right commandResult) -> do
          commandResult ^. #streamVersion `shouldBe` StreamVersion 2
          commandResult ^. #eventsAppended `shouldBe` 2
        other -> expectationFailure ("expected multi-event snapshot command, got " <> show other)
      Right snapshotVersion <- Store.runStoreIO storeHandle $
        Store.runTransaction $
          Tx.statement "snapshot-multi-event-batch" snapshotVersionForStreamStmt
      snapshotVersion `shouldBe` Just (StreamVersion 2)

  describe "Keiro.ReadModel" $ around withTestStore $ do
    it "queries inline projection with Strong consistency" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeReadModelSchema
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction initializeCounterReadModelTable
      let target = stream "read-model-inline" :: Stream CounterEventStream
      result <- Store.runStoreIO storeHandle $
        runCommandWithProjections
          defaultRunCommandOptions
          counterEventStream
          target
          (Add 5)
          [counterInlineProjection]
      case result of
        Right (Right commandResult) ->
          commandResult ^. #globalPosition `shouldSatisfy` isJust
        other -> expectationFailure ("expected inline projection command, got " <> show other)
      queryResult <- Store.runStoreIO storeHandle $
        runQuery counterReadModel "inline"
      queryResult `shouldBe` Right (Right 5)

    it "waits for async projection cursor with PositionWait" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeReadModelSchema
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction initializeCounterReadModelTable
      let target = stream "read-model-position-wait" :: Stream CounterEventStream
      Right (Right commandResult) <- Store.runStoreIO storeHandle $
        runCommandWithProjections
          defaultRunCommandOptions
          counterEventStream
          target
          (Add 3)
          [counterInlineProjection]
      globalPosition <- case commandResult ^. #globalPosition of
        Just position -> pure position
        Nothing -> expectationFailure "expected command global position" *> error "unreachable"
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction $
          Tx.statement ("counter-read-model-sub", globalPositionToInt globalPosition) upsertSubscriptionCursorStmt
      queryResult <- Store.runStoreIO storeHandle $
        runQueryWith
          (PositionWait (fastWaitOptions & #target .~ Just globalPosition))
          counterReadModel
          "inline"
      queryResult `shouldBe` Right (Right 3)

    it "times out when PositionWait target is not reached" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeReadModelSchema
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction initializeCounterReadModelTable
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction $
          Tx.statement ("counter-read-model-sub", 1) upsertSubscriptionCursorStmt
      queryResult <- Store.runStoreIO storeHandle $
        runQueryWith
          (PositionWait (fastWaitOptions & #target .~ Just (GlobalPosition 5)))
          counterReadModel
          "timeout"
      queryResult
        `shouldBe` Right
          (Left (ReadModelWaitTimeout "counter-read-model" (GlobalPosition 5) (GlobalPosition 1)))

    it "rejects stale read-model schema" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeReadModelSchema
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction initializeCounterReadModelTable
      Right (Right 0) <- Store.runStoreIO storeHandle $
        runQuery counterReadModel "stale"
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction $
          Tx.statement ("counter-read-model", 99) updateReadModelVersionStmt
      queryResult <- Store.runStoreIO storeHandle $
        runQuery counterReadModel "stale"
      queryResult
        `shouldBe` Right
          (Left (ReadModelStaleSchema "counter-read-model" 1 99 "counter-read-model-v1" "counter-read-model-v1"))

    it "ignores duplicate async event by source_event_id" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeReadModelSchema
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction initializeCounterReadModelTable
      let target = stream "read-model-async-idempotent" :: Stream CounterEventStream
      Right (Right _) <- Store.runStoreIO storeHandle $
        runCommand defaultRunCommandOptions counterEventStream target (Add 7)
      Right recorded <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "read-model-async-idempotent") (StreamVersion 0) 10
      event <- case Vector.toList recorded of
        [onlyEvent] -> pure onlyEvent
        other -> expectationFailure ("expected one event, got " <> show other) *> error "unreachable"
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction $ do
          applyAsyncProjection counterAsyncProjection event
          applyAsyncProjection counterAsyncProjection event
      queryResult <- Store.runStoreIO storeHandle $
        runQuery counterReadModel "async-idempotent"
      queryResult `shouldBe` Right (Right 7)

    it "tracks rebuild state transitions" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeReadModelSchema
      Right rebuilding <- Store.runStoreIO storeHandle $
        Rebuild.rebuild counterReadModel
      rebuilding ^. #status `shouldBe` Rebuilding
      Right live <- Store.runStoreIO storeHandle $
        Rebuild.promote counterReadModel
      live ^. #status `shouldBe` Live
      Right abandoned <- Store.runStoreIO storeHandle $
        Rebuild.abandonRebuild counterReadModel
      abandoned ^. #status `shouldBe` Abandoned

  describe "Keiro.ProcessManager" $ around withTestStore $ do
    it "advances manager state, emits a deterministic target command once, and schedules a timer" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeTimerSchema
      let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 9)
      result <- Store.runStoreIO storeHandle $
        runProcessManagerOnce defaultRunCommandOptions counterProcessManager sourceEvent (CounterAdded 9)
      case result of
        Right (Right pmResult) -> do
          case pmResult ^. #managerResult of
            PMStateAppended managerResult ->
              managerResult ^. #streamVersion `shouldBe` StreamVersion 1
            other -> expectationFailure ("expected appended manager state, got " <> show other)
          case pmResult ^. #commandResults of
            [PMCommandAppended commandResult] ->
              commandResult ^. #eventsAppended `shouldBe` 1
            other -> expectationFailure ("expected one emitted command, got " <> show other)
          pmResult ^. #timersScheduled `shouldBe` 1
        other -> expectationFailure ("expected process-manager success, got " <> show other)
      Right managerEvents <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "pm:counter-order-1") (StreamVersion 0) 10
      Right targetEvents <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "counter-target-order-1") (StreamVersion 0) 10
      Vector.length managerEvents `shouldBe` 1
      Vector.length targetEvents `shouldBe` 1
      timer <- Store.runStoreIO storeHandle $
        claimDueTimer dueTimerTime
      case timer of
        Right (Just row) -> do
          row ^. #processManagerName `shouldBe` "counter-pm"
          row ^. #correlationId `shouldBe` "order-1"
        other -> expectationFailure ("expected scheduled timer row, got " <> show other)

    it "treats duplicate input delivery as idempotent state and command dispatch" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeTimerSchema
      let sourceEvent = recordedFromEventId (EventId sampleUuid2) (CounterAdded 4)
      Right (Right _) <- Store.runStoreIO storeHandle $
        runProcessManagerOnce defaultRunCommandOptions counterProcessManager sourceEvent (CounterAdded 4)
      duplicate <- Store.runStoreIO storeHandle $
        runProcessManagerOnce defaultRunCommandOptions counterProcessManager sourceEvent (CounterAdded 4)
      case duplicate of
        Right (Right pmResult) -> do
          pmResult ^. #managerResult `shouldSatisfy` \case
            PMStateDuplicate{} -> True
            _ -> False
          pmResult ^. #commandResults `shouldSatisfy` \case
            [PMCommandDuplicate{}] -> True
            _ -> False
        other -> expectationFailure ("expected idempotent duplicate handling, got " <> show other)
      Right managerEvents <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "pm:counter-order-1") (StreamVersion 0) 10
      Right targetEvents <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "counter-target-order-1") (StreamVersion 0) 10
      Vector.length managerEvents `shouldBe` 1
      Vector.length targetEvents `shouldBe` 1

    it "keeps multiple workflow process managers isolated by configured streams and categories" $ \storeHandle -> do
      let sourceEvent = recordedFromEventId (EventId sampleUuid) (CounterAdded 6)
          fulfillmentManager =
            workflowProcessManager
              "fulfillment-pm"
              "pm:fulfillment"
              "fulfillment-target-order-1"
          billingManager =
            workflowProcessManager
              "billing-pm"
              "pm:billing"
              "billing-target-order-1"
      fulfillmentResult <- Store.runStoreIO storeHandle $
        runProcessManagerOnce defaultRunCommandOptions fulfillmentManager sourceEvent (CounterAdded 6)
      billingResult <- Store.runStoreIO storeHandle $
        runProcessManagerOnce defaultRunCommandOptions billingManager sourceEvent (CounterAdded 6)
      assertWorkflowProcessManagerAppended fulfillmentResult
      assertWorkflowProcessManagerAppended billingResult

      Right fulfillmentManagerEvents <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "pm:fulfillment-order-1") (StreamVersion 0) 10
      Right billingManagerEvents <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "pm:billing-order-1") (StreamVersion 0) 10
      Right fulfillmentTargetEvents <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "fulfillment-target-order-1") (StreamVersion 0) 10
      Right billingTargetEvents <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "billing-target-order-1") (StreamVersion 0) 10
      Vector.length fulfillmentManagerEvents `shouldBe` 1
      Vector.length billingManagerEvents `shouldBe` 1
      Vector.length fulfillmentTargetEvents `shouldBe` 1
      Vector.length billingTargetEvents `shouldBe` 1

      Right fulfillmentCategoryEvents <- Store.runStoreIO storeHandle $
        Store.readCategory (CategoryName "pm:fulfillment") (GlobalPosition 0) 10
      Right billingCategoryEvents <- Store.runStoreIO storeHandle $
        Store.readCategory (CategoryName "pm:billing") (GlobalPosition 0) 10
      Right sharedPmCategoryEvents <- Store.runStoreIO storeHandle $
        Store.readCategory (CategoryName "pm") (GlobalPosition 0) 10
      Right sharedPmNamespaceEvents <- Store.runStoreIO storeHandle $
        Store.readCategory (CategoryName "pm:") (GlobalPosition 0) 10
      Vector.length fulfillmentCategoryEvents `shouldBe` 1
      Vector.length billingCategoryEvents `shouldBe` 1
      sharedPmCategoryEvents `shouldBe` Vector.empty
      sharedPmNamespaceEvents `shouldBe` Vector.empty

  describe "Keiro.Timer" $ around withTestStore $ do
    it "claims a due timer, fires a command, and marks it complete once" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeTimerSchema
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction $
          scheduleTimerTx counterTimerRequest
      let firedEventId = EventId sampleUuid2
      workerResult <- Store.runStoreIO storeHandle $
        runTimerWorker dueTimerTime $ \_ -> do
          fired <-
            runCommand
              (defaultRunCommandOptions & #eventIds .~ [firedEventId])
              counterEventStream
              (stream "timer-target")
              (Add 11)
          case fired of
            Right _ -> pure (Just firedEventId)
            Left err -> liftIO (expectationFailure ("expected timer command to fire, got " <> show err)) *> pure Nothing
      case workerResult of
        Right (Just timer) ->
          timer ^. #status `shouldBe` Firing
        other -> expectationFailure ("expected fired timer, got " <> show other)
      secondWorkerResult <- Store.runStoreIO storeHandle $
        runTimerWorker dueTimerTime (\_ -> pure (Just firedEventId))
      secondWorkerResult `shouldBe` Right Nothing
      Right targetEvents <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "timer-target") (StreamVersion 0) 10
      fmap (^. #eventId) (Vector.toList targetEvents) `shouldBe` [firedEventId]

  describe "Keiro.Outbox.Kafka" $ do
    it "converts an outbox row to a Kafka producer record" $ do
      let envelope = sampleIntegrationEnvelope
          row = sampleOutboxRow envelope
          record = OutboxKafka.outboxRowToKafkaRecord row
      record ^. #topic `shouldBe` envelope ^. #destination
      record ^. #key `shouldBe` Just "order-123"
      record ^. #payload `shouldBe` envelope ^. #payloadBytes
      -- Headers include identity fields and content type.
      let headers = record ^. #headers
          messageIdHeader = Prelude.lookup "keiro-message-id" headers
      messageIdHeader `shouldBe` Just "018f0f18-17aa-7000-8000-0000000000aa"

    it "drops the partition key when the envelope has no key" $ do
      let envelope = sampleIntegrationEnvelope & #key .~ Nothing
          record = OutboxKafka.integrationEventToKafkaRecord envelope
      record ^. #key `shouldBe` Nothing

  describe "Keiro.Outbox" $ around withTestStore $ do
    it "enqueues and looks up an outbox row" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeOutboxSchema
      let envelope = sampleIntegrationEnvelope
          oid = OutboxId outboxUuid1
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction (enqueueIntegrationEventTx oid envelope)
      lookedUp <- Store.runStoreIO storeHandle (lookupOutbox oid)
      case lookedUp of
        Right (Just row) -> do
          row ^. #outboxId `shouldBe` oid
          row ^. #status `shouldBe` OutboxPending
          row ^. #attemptCount `shouldBe` 0
          row ^. #event . #messageId `shouldBe` envelope ^. #messageId
          row ^. #event . #destination `shouldBe` envelope ^. #destination
          row ^. #event . #payloadBytes `shouldBe` envelope ^. #payloadBytes
        other -> expectationFailure ("expected enqueued row, got " <> show other)

    it "claims a pending row, transitions it to publishing, and increments attempt count" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeOutboxSchema
      let oid = OutboxId outboxUuid1
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction (enqueueIntegrationEventTx oid sampleIntegrationEnvelope)
      now <- getCurrentTime
      Right rows <- Store.runStoreIO storeHandle (claimOutboxBatch PerKeyHeadOfLine 10 now)
      case rows of
        [row] -> do
          row ^. #outboxId `shouldBe` oid
          row ^. #status `shouldBe` OutboxPublishing
          row ^. #attemptCount `shouldBe` 1
        other -> expectationFailure ("expected one claimed row, got " <> show other)

    it "marks a claimed row as sent with published_at set" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeOutboxSchema
      let oid = OutboxId outboxUuid1
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction (enqueueIntegrationEventTx oid sampleIntegrationEnvelope)
      now <- getCurrentTime
      Right [_] <- Store.runStoreIO storeHandle (claimOutboxBatch PerKeyHeadOfLine 10 now)
      Right () <- Store.runStoreIO storeHandle (markOutboxSent oid now)
      Right (Just row) <- Store.runStoreIO storeHandle (lookupOutbox oid)
      row ^. #status `shouldBe` OutboxSent
      row ^. #publishedAt `shouldSatisfy` isJust
      row ^. #lastError `shouldBe` Nothing

    it "publishClaimedOutbox marks success and records failures with last_error" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeOutboxSchema
      let okId = OutboxId outboxUuid1
          failId = OutboxId outboxUuid2
          okEvent = sampleIntegrationEnvelope
          failEvent = sampleIntegrationEnvelope
            & #messageId .~ "msg-fail-1"
            & #key .~ Just "order-789"
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction (enqueueIntegrationEventTx okId okEvent)
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction (enqueueIntegrationEventTx failId failEvent)
      let publish row
            | row ^. #outboxId == okId = pure PublishSucceeded
            | otherwise = pure (PublishFailed "broker unreachable")
      Right summary <-
        Store.runStoreIO storeHandle (publishClaimedOutbox publish defaultPublishOptions)
      summary ^. #claimed `shouldBe` 2
      summary ^. #published `shouldBe` 1
      summary ^. #retried `shouldBe` 1
      summary ^. #dead `shouldBe` 0
      Right (Just okRow) <- Store.runStoreIO storeHandle (lookupOutbox okId)
      okRow ^. #status `shouldBe` OutboxSent
      Right (Just failRow) <- Store.runStoreIO storeHandle (lookupOutbox failId)
      failRow ^. #status `shouldBe` OutboxFailed
      failRow ^. #lastError `shouldBe` Just "broker unreachable"

    it "auto-dead-letters a row after maxAttempts consecutive failures" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeOutboxSchema
      let oid = OutboxId outboxUuid1
          event = sampleIntegrationEnvelope & #key .~ Nothing
          opts =
            defaultPublishOptions
              & #batchSize .~ 10
              & #maxAttempts .~ 3
              & #backoff .~ ConstantBackoff 0
              & #orderingPolicy .~ BestEffort
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction (enqueueIntegrationEventTx oid event)
      let publish _ = pure (PublishFailed "broker exploded")
      -- First two failures retain Failed status.
      Right s1 <- Store.runStoreIO storeHandle (publishClaimedOutbox publish opts)
      s1 ^. #retried `shouldBe` 1
      s1 ^. #dead `shouldBe` 0
      Right s2 <- Store.runStoreIO storeHandle (publishClaimedOutbox publish opts)
      s2 ^. #retried `shouldBe` 1
      s2 ^. #dead `shouldBe` 0
      -- Third failure crosses the threshold.
      Right s3 <- Store.runStoreIO storeHandle (publishClaimedOutbox publish opts)
      s3 ^. #dead `shouldBe` 1
      Right (Just row) <- Store.runStoreIO storeHandle (lookupOutbox oid)
      row ^. #status `shouldBe` OutboxDead
      -- A dead row is not claimable.
      now <- getCurrentTime
      Right reclaimed <- Store.runStoreIO storeHandle (claimOutboxBatch BestEffort 10 now)
      reclaimed `shouldBe` []

    it "enforces per-key head-of-line blocking and unblocks once the predecessor reaches a terminal state" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeOutboxSchema
      let a1Id = OutboxId outboxUuid1
          a2Id = OutboxId outboxUuid2
          b1Id = OutboxId outboxUuid3
          a1 = sampleIntegrationEnvelope & #messageId .~ "a1" & #key .~ Just "k1"
          a2 = sampleIntegrationEnvelope & #messageId .~ "a2" & #key .~ Just "k1"
          b1 = sampleIntegrationEnvelope & #messageId .~ "b1" & #key .~ Just "k2"
      -- Insert in created_at order (a1 first, then a2, then b1).
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction (enqueueIntegrationEventTx a1Id a1)
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction (enqueueIntegrationEventTx a2Id a2)
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction (enqueueIntegrationEventTx b1Id b1)
      claimed <- newIORef []
      let publish row = do
            liftIO (atomicModifyIORef' claimed (\xs -> ((row ^. #outboxId) : xs, ())))
            if row ^. #outboxId == a1Id
              then pure (PublishFailed "broker hiccup")
              else pure PublishSucceeded
      -- First pass: a1 fails, b1 publishes, a2 is blocked behind a1.
      let firstPassOpts =
            defaultPublishOptions
              & #batchSize .~ 10
              & #backoff .~ ConstantBackoff 0
      Right summary1 <-
        Store.runStoreIO storeHandle (publishClaimedOutbox publish firstPassOpts)
      summary1 ^. #claimed `shouldBe` 2
      claimedIds <- readIORef claimed
      claimedIds `shouldSatisfy` (a2Id `notElem`)
      claimedIds `shouldSatisfy` (a1Id `elem`)
      claimedIds `shouldSatisfy` (b1Id `elem`)
      Right (Just a1Row) <- Store.runStoreIO storeHandle (lookupOutbox a1Id)
      a1Row ^. #status `shouldBe` OutboxFailed
      Right (Just b1Row) <- Store.runStoreIO storeHandle (lookupOutbox b1Id)
      b1Row ^. #status `shouldBe` OutboxSent
      Right (Just a2Row) <- Store.runStoreIO storeHandle (lookupOutbox a2Id)
      a2Row ^. #status `shouldBe` OutboxPending
      -- Drive a1 to terminal sent state so a2 can move. One pass claims a1
      -- (now that next_attempt_at has passed). A second pass claims a2,
      -- which becomes head-of-line once a1 reaches `sent`.
      writeIORef claimed []
      let publishOk row = do
            liftIO (atomicModifyIORef' claimed (\xs -> ((row ^. #outboxId) : xs, ())))
            pure PublishSucceeded
          retryOpts =
            defaultPublishOptions
              & #batchSize .~ 10
              & #backoff .~ ConstantBackoff 0
      Right _ <- Store.runStoreIO storeHandle (publishClaimedOutbox publishOk retryOpts)
      Right _ <- Store.runStoreIO storeHandle (publishClaimedOutbox publishOk retryOpts)
      claimedIds2 <- readIORef claimed
      claimedIds2 `shouldSatisfy` (a1Id `elem`)
      claimedIds2 `shouldSatisfy` (a2Id `elem`)
      Right (Just a2Row') <- Store.runStoreIO storeHandle (lookupOutbox a2Id)
      a2Row' ^. #status `shouldBe` OutboxSent

    it "allows null-keyed rows to publish independently" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeOutboxSchema
      let n1 = OutboxId outboxUuid1
          n2 = OutboxId outboxUuid2
          e = sampleIntegrationEnvelope & #key .~ Nothing
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction (enqueueIntegrationEventTx n1 (e & #messageId .~ "n1"))
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction (enqueueIntegrationEventTx n2 (e & #messageId .~ "n2"))
      let publish row
            | row ^. #outboxId == n1 = pure (PublishFailed "transient")
            | otherwise = pure PublishSucceeded
      Right summary <- Store.runStoreIO storeHandle $
        publishClaimedOutbox publish (defaultPublishOptions & #backoff .~ ConstantBackoff 0)
      summary ^. #claimed `shouldBe` 2
      summary ^. #published `shouldBe` 1
      summary ^. #retried `shouldBe` 1

    it "mints message ids with the configured TypeID prefix" $ \storeHandle -> do
      Right minted <-
        Store.runStoreIO storeHandle (mintIntegrationEvent sampleProducer sampleDraft)
      minted ^. #source `shouldBe` "ordering"
      minted ^. #destination `shouldBe` "billing.orders.v1"
      Text.isPrefixOf "msg_" (minted ^. #messageId) `shouldBe` True

    it "draftToEvent stamps source and messageId without minting" $ \_storeHandle -> do
      let event = draftToEvent "ordering" "msg-fixed-1" sampleDraft
      event ^. #messageId `shouldBe` "msg-fixed-1"
      event ^. #source `shouldBe` "ordering"
      event ^. #destination `shouldBe` "billing.orders.v1"

    it "freshOutboxId returns distinct UUIDv7 ids" $ \storeHandle -> do
      Right ids <-
        Store.runStoreIO storeHandle (traverse (\_ -> freshOutboxId) [1 .. 4 :: Int])
      length ids `shouldBe` 4
      length (uniqueIds ids) `shouldBe` 4

    it "publishClaimedOutbox emits a Producer span with messaging semconv attributes" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeOutboxSchema
      (processor, spansRef) <- inMemoryListExporter
      provider <- createTracerProvider [processor] emptyTracerProviderOptions
      let tracer = makeTracer provider "keiro-test" tracerOptions
          okId = OutboxId outboxUuid1
          failId = OutboxId outboxUuid2
          okEvent = sampleIntegrationEnvelope
          failEvent = sampleIntegrationEnvelope
            & #messageId .~ "msg-fail-otel-1"
            & #key .~ Just "order-otel-fail"
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction (enqueueIntegrationEventTx okId okEvent)
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction (enqueueIntegrationEventTx failId failEvent)
      let publish row
            | row ^. #outboxId == okId = pure PublishSucceeded
            | otherwise = pure (PublishFailed "broker unreachable")
          opts = defaultPublishOptions & #tracer ?~ tracer
      Right _ <- Store.runStoreIO storeHandle (publishClaimedOutbox publish opts)
      _ <- shutdownTracerProvider provider
      spans <- readIORef spansRef
      length spans `shouldBe` 2
      let findSpan needle = case [sp | sp <- spans, textAttr (spanAttributes sp) "messaging.message.id" == Just needle] of
            (sp : _) -> sp
            [] -> error ("no span captured for message.id=" <> Text.unpack needle)
          okSpan = findSpan (okEvent ^. #messageId)
          failSpan = findSpan (failEvent ^. #messageId)
      -- Successful publish: producer-kind, all messaging attrs, Unset/Ok
      -- status (the helper does not explicitly set Ok; default is Unset).
      spanName okSpan `shouldBe` ("send " <> (okEvent ^. #destination))
      show (spanKind okSpan) `shouldBe` "Producer"
      textAttr (spanAttributes okSpan) "messaging.system" `shouldBe` Just "kafka"
      textAttr (spanAttributes okSpan) "messaging.operation.type" `shouldBe` Just "publish"
      textAttr (spanAttributes okSpan) "messaging.operation.name" `shouldBe` Just "send"
      textAttr (spanAttributes okSpan) "messaging.destination.name"
        `shouldBe` Just (okEvent ^. #destination)
      textAttr (spanAttributes okSpan) "messaging.kafka.message.key"
        `shouldBe` (okEvent ^. #key)
      case spanStatus okSpan of
        Unset -> pure ()
        Ok -> pure ()
        other -> expectationFailure ("expected Unset/Ok, got " <> show other)
      -- Failed publish: same attrs, plus error.type and Error status with
      -- the publisher's error message.
      textAttr (spanAttributes failSpan) "error.type" `shouldBe` Just "publish_failed"
      case spanStatus failSpan of
        Error msg -> msg `shouldBe` "broker unreachable"
        other -> expectationFailure ("expected Error \"broker unreachable\", got " <> show other)

  describe "Keiro.Inbox" $ around withTestStore $ do
    it "runs the handler once and records the row as completed" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeInboxSchema
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS inbox_test_counter (message_id TEXT PRIMARY KEY)")
      let event = sampleIntegrationEnvelope
            & #messageId .~ "inbox-msg-1"
            & #source .~ "ordering"
          handler ev =
            Tx.statement (ev ^. #messageId) inboxTestCounterInsertStmt
      Right result1 <- Store.runStoreIO storeHandle $
        runInboxTransaction PreferIntegrationMessageId event Nothing handler
      case result1 of
        Right (InboxProcessed ()) -> pure ()
        other -> expectationFailure ("expected InboxProcessed, got " <> show other)
      Right rowCount1 <- Store.runStoreIO storeHandle $
        Store.runTransaction (Tx.statement () inboxTestCounterCountStmt)
      rowCount1 `shouldBe` 1
      Right (Just inboxRow) <- Store.runStoreIO storeHandle (lookupInbox "ordering" "inbox-msg-1")
      inboxRow ^. #status `shouldBe` InboxCompleted
      inboxRow ^. #completedAt `shouldSatisfy` isJust

    it "treats a redelivery with the same messageId as a duplicate" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeInboxSchema
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS inbox_test_counter (message_id TEXT PRIMARY KEY)")
      let event = sampleIntegrationEnvelope
            & #messageId .~ "inbox-msg-dup"
            & #source .~ "ordering"
          handler ev = Tx.statement (ev ^. #messageId) inboxTestCounterInsertStmt
      Right (Right (InboxProcessed ())) <- Store.runStoreIO storeHandle $
        runInboxTransaction PreferIntegrationMessageId event Nothing handler
      Right result2 <- Store.runStoreIO storeHandle $
        runInboxTransaction PreferIntegrationMessageId event Nothing handler
      result2 `shouldBe` Right InboxDuplicate
      Right rowCount <- Store.runStoreIO storeHandle $
        Store.runTransaction (Tx.statement () inboxTestCounterCountStmt)
      rowCount `shouldBe` 1

    it "deduplicates via PreferSourceEventIdentity even when messageId differs" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeInboxSchema
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS inbox_test_counter (message_id TEXT PRIMARY KEY)")
      let shared = sampleIntegrationEnvelope & #source .~ "ordering"
          first = shared & #messageId .~ "republish-1"
          second = shared & #messageId .~ "republish-2"
          handler ev = Tx.statement (ev ^. #messageId) inboxTestCounterInsertStmt
      Right (Right (InboxProcessed ())) <- Store.runStoreIO storeHandle $
        runInboxTransaction PreferSourceEventIdentity first Nothing handler
      Right result2 <- Store.runStoreIO storeHandle $
        runInboxTransaction PreferSourceEventIdentity second Nothing handler
      result2 `shouldBe` Right InboxDuplicate

    it "uses KafkaDeliveryIdentity when supplied" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeInboxSchema
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS inbox_test_counter (message_id TEXT PRIMARY KEY)")
      let event = sampleIntegrationEnvelope & #source .~ "ordering"
          kafka = KafkaDeliveryRef "billing.orders.v1" 0 17
          handler ev = Tx.statement (ev ^. #messageId) inboxTestCounterInsertStmt
      Right (Right (InboxProcessed ())) <- Store.runStoreIO storeHandle $
        runInboxTransaction KafkaDeliveryIdentity event (Just kafka) handler
      Right (Right InboxDuplicate) <- Store.runStoreIO storeHandle $
        runInboxTransaction KafkaDeliveryIdentity event (Just kafka) handler
      Right (Just row) <- Store.runStoreIO storeHandle $
        lookupInbox "ordering" "billing.orders.v1:0:17"
      row ^. #status `shouldBe` InboxCompleted

    it "reports DedupePolicyUnsatisfied when the envelope lacks the required field" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeInboxSchema
      let event = sampleIntegrationEnvelope
            & #source .~ "ordering"
            & #sourceEventId .~ Nothing
            & #sourceGlobalPosition .~ Nothing
      Right result <- Store.runStoreIO storeHandle $
        runInboxTransaction PreferSourceEventIdentity event Nothing (\_ -> pure ())
      result `shouldBe` Left (DedupePolicyUnsatisfied PreferSourceEventIdentity)

    it "leaves no inbox row when the handler condemns the transaction" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeInboxSchema
      let event = sampleIntegrationEnvelope
            & #messageId .~ "inbox-msg-rollback"
            & #source .~ "ordering"
          handler _ = do
            Tx.condemn
            pure ()
      _ <- Store.runStoreIO storeHandle $
        runInboxTransaction PreferIntegrationMessageId event Nothing handler
      Right row <- Store.runStoreIO storeHandle (lookupInbox "ordering" "inbox-msg-rollback")
      row `shouldBe` Nothing

    it "garbage-collects completed rows older than the retention window" $ \storeHandle -> do
      Right () <- Store.runStoreIO storeHandle initializeInboxSchema
      let event = sampleIntegrationEnvelope
            & #messageId .~ "inbox-msg-gc"
            & #source .~ "ordering"
          handler _ = pure ()
      Right (Right (InboxProcessed ())) <- Store.runStoreIO storeHandle $
        runInboxTransaction PreferIntegrationMessageId event Nothing handler
      -- Backdate the row so it falls outside the retention window.
      Right () <- Store.runStoreIO storeHandle $
        Store.runTransaction $
          Tx.sql
            "UPDATE keiro_inbox SET completed_at = now() - interval '40 days' WHERE message_id = 'inbox-msg-gc'"
      now <- getCurrentTime
      Right deleted <- Store.runStoreIO storeHandle (garbageCollectCompleted (nominalDays 30) now)
      deleted `shouldBe` 1
      Right rows <- Store.runStoreIO storeHandle (listInbox "ordering")
      rows `shouldBe` []

  describe "Keiro.Inbox.Kafka" $ do
    it "reconstructs an integration event from headers and payload" $ do
      let envelope = sampleIntegrationEnvelope
          headers = integrationHeaders envelope
          record = InboxKafka.KafkaInboundRecord
            { topic = "billing.orders.v1"
            , partition = 2
            , offset = 113
            , key = Just "order-123"
            , payload = envelope ^. #payloadBytes
            , headers
            , receivedAt = envelope ^. #occurredAt
            }
      case InboxKafka.integrationEventFromKafka record of
        Right (rebuilt, kafkaRef) -> do
          rebuilt ^. #messageId `shouldBe` envelope ^. #messageId
          rebuilt ^. #source `shouldBe` envelope ^. #source
          rebuilt ^. #destination `shouldBe` envelope ^. #destination
          rebuilt ^. #eventType `shouldBe` envelope ^. #eventType
          rebuilt ^. #schemaVersion `shouldBe` envelope ^. #schemaVersion
          rebuilt ^. #sourceEventId `shouldBe` envelope ^. #sourceEventId
          rebuilt ^. #sourceGlobalPosition `shouldBe` envelope ^. #sourceGlobalPosition
          rebuilt ^. #payloadBytes `shouldBe` envelope ^. #payloadBytes
          kafkaRef ^. #topic `shouldBe` "billing.orders.v1"
          kafkaRef ^. #partition `shouldBe` 2
          kafkaRef ^. #offset `shouldBe` 113
        Left err -> expectationFailure ("expected Right, got Left " <> show err)

    it "reports MissingHeader for an essential header" $ do
      let envelope = sampleIntegrationEnvelope
          headers = filter ((/= "keiro-message-id") . Prelude.fst) (integrationHeaders envelope)
          record = InboxKafka.KafkaInboundRecord
            { topic = "billing.orders.v1"
            , partition = 0
            , offset = 0
            , key = Nothing
            , payload = envelope ^. #payloadBytes
            , headers
            , receivedAt = envelope ^. #occurredAt
            }
      InboxKafka.integrationEventFromKafka record
        `shouldBe` Left (InboxKafka.MissingHeader "keiro-message-id")

    it "withConsumerSpan parents the consumer span under an upstream producer span via W3C headers" $ do
      (processor, spansRef) <- inMemoryListExporter
      provider <- createTracerProvider [processor] emptyTracerProviderOptions
      let tracer = makeTracer provider "keiro-test" tracerOptions
          -- Clear the baked-in TraceContext on the sample so the only
          -- `traceparent` on the wire comes from the active producer
          -- span (via `injectTraceContext`).
          envelope = sampleIntegrationEnvelope & #traceContext .~ Nothing
          producerRecord = OutboxKafka.integrationEventToKafkaRecord envelope
      producerHeadersText <-
        Telemetry.withProducerSpan (Just tracer) envelope producerRecord $ \_ -> do
          let baseHeaders =
                [(TE.decodeUtf8 n, TE.decodeUtf8 v) | (n, v) <- producerRecord ^. #headers]
          Telemetry.injectTraceContext baseHeaders
      -- Build the inbound record the consumer would receive and open the
      -- consumer span around a no-op body.
      now <- getCurrentTime
      let inbound =
            InboxKafka.KafkaInboundRecord
              { topic = envelope ^. #destination
              , partition = 7
              , offset = 42
              , key = envelope ^. #key
              , payload = envelope ^. #payloadBytes
              , headers = producerHeadersText
              , receivedAt = now
              }
      Telemetry.withConsumerSpan (Just tracer) (Just "billing-cg") inbound (Just envelope) $ \_ ->
        pure ()
      _ <- shutdownTracerProvider provider
      spans <- readIORef spansRef
      length spans `shouldBe` 2
      let findByName needle = case [s | s <- spans, spanName s == needle] of
            (s : _) -> s
            [] -> error ("no span captured with name=" <> Text.unpack needle)
          producerSp = findByName ("send " <> envelope ^. #destination)
          consumerSp = findByName ("process " <> envelope ^. #destination)
      -- Same trace id end-to-end (cross-process parenting).
      traceId (spanContext producerSp) `shouldBe` traceId (spanContext consumerSp)
      -- Consumer's parent is the producer span.
      case spanParent consumerSp of
        Nothing -> expectationFailure "consumer span has no parent"
        Just parent -> do
          parentCtx <- getSpanContext parent
          spanId parentCtx `shouldBe` spanId (spanContext producerSp)
      -- Consumer span carries the expected attributes.
      show (spanKind consumerSp) `shouldBe` "Consumer"
      textAttr (spanAttributes consumerSp) "messaging.system" `shouldBe` Just "kafka"
      textAttr (spanAttributes consumerSp) "messaging.operation.type" `shouldBe` Just "process"
      textAttr (spanAttributes consumerSp) "messaging.destination.name"
        `shouldBe` Just (envelope ^. #destination)
      textAttr (spanAttributes consumerSp) "messaging.destination.partition.id"
        `shouldBe` Just "7"
      textAttr (spanAttributes consumerSp) "messaging.consumer.group.name"
        `shouldBe` Just "billing-cg"
      textAttr (spanAttributes consumerSp) "messaging.message.id"
        `shouldBe` Just (envelope ^. #messageId)

  describe "Keiro cross-context Kafka integration" $ around withTwoContexts $ do
    it "publishes an Ordering integration event and runs the Billing handler exactly once across duplicate deliveries" $ \(ordering, billing) -> do
      Right () <- Store.runStoreIO ordering initializeOutboxSchema
      Right () <- Store.runStoreIO billing initializeInboxSchema
      Right () <- Store.runStoreIO billing $
        Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS billing_received_orders (order_id TEXT PRIMARY KEY, quantity BIGINT NOT NULL)")
      topic <- newKafkaTopic
      -- Ordering side: enqueue an outbox row representing a published event.
      let orderingEvent = orderSubmittedEnvelope "order-aaa" 7 "msg-aaa"
          oid = OutboxId outboxUuid1
      Right () <- Store.runStoreIO ordering $
        Store.runTransaction (enqueueIntegrationEventTx oid orderingEvent)
      -- Run the publisher worker: push records to the in-process topic.
      Right pubSummary1 <- Store.runStoreIO ordering $
        publishClaimedOutbox (kafkaTopicPublish topic) defaultPublishOptions
      pubSummary1 ^. #published `shouldBe` 1
      -- Billing side: consume from the topic.
      records1 <- drainKafkaTopic topic
      record1 <- case records1 of
        [r] -> pure r
        other -> expectationFailure ("expected 1 record, got " <> show (length other)) *> error "unreachable"
      Right consumed1 <- Store.runStoreIO billing $
        consumeAndApply record1 billingReactionHandler
      consumed1 `shouldBe` ConsumeApplied (InboxProcessed ())
      Right rowCount1 <- Store.runStoreIO billing $
        Store.runTransaction (Tx.statement () billingReceivedOrdersCountStmt)
      rowCount1 `shouldBe` 1

      -- Simulate Kafka redelivery: pretend the same Kafka record was
      -- delivered again at a different offset. The producer also retries
      -- (the outbox flips back to pending and the worker republishes).
      let redelivered = redeliverWithDifferentOffset record1
      Right consumed2 <- Store.runStoreIO billing $
        consumeAndApply redelivered billingReactionHandler
      consumed2 `shouldBe` ConsumeApplied InboxDuplicate
      Right rowCount2 <- Store.runStoreIO billing $
        Store.runTransaction (Tx.statement () billingReceivedOrdersCountStmt)
      rowCount2 `shouldBe` 1

    it "preserves per-partition ordering for two events sharing a Kafka key" $ \(ordering, billing) -> do
      Right () <- Store.runStoreIO ordering initializeOutboxSchema
      Right () <- Store.runStoreIO billing initializeInboxSchema
      Right () <- Store.runStoreIO billing $
        Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS billing_received_orders (order_id TEXT PRIMARY KEY, quantity BIGINT NOT NULL)")
      Right () <- Store.runStoreIO billing $
        Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS billing_event_log (seq BIGSERIAL PRIMARY KEY, source TEXT NOT NULL, event_type TEXT NOT NULL, order_id TEXT NOT NULL)")
      topic <- newKafkaTopic
      -- Two events for the same order key.
      let submittedEnv = orderSubmittedEnvelope "order-bbb" 4 "msg-bbb-1"
          cancelledEnv = orderCancelledEnvelope "order-bbb" "msg-bbb-2"
          submittedId = OutboxId outboxUuid1
          cancelledId = OutboxId outboxUuid2
      Right () <- Store.runStoreIO ordering $
        Store.runTransaction (enqueueIntegrationEventTx submittedId submittedEnv)
      Right () <- Store.runStoreIO ordering $
        Store.runTransaction (enqueueIntegrationEventTx cancelledId cancelledEnv)
      -- Per-key head-of-line means the worker drains at most one row per
      -- @(source, message_key)@ per pass. Call it twice so the
      -- successor (cancelled) clears after the predecessor (submitted)
      -- reaches the terminal @sent@ status.
      let drainOnce =
            publishClaimedOutbox
              (kafkaTopicPublish topic)
              (defaultPublishOptions & #backoff .~ ConstantBackoff 0)
      Right s1 <- Store.runStoreIO ordering drainOnce
      Right s2 <- Store.runStoreIO ordering drainOnce
      (s1 ^. #published) + (s2 ^. #published) `shouldBe` 2
      records <- drainKafkaTopic topic
      length records `shouldBe` 2
      -- Apply both records to billing in delivery order.
      for_ records $ \record -> do
        Right consumed <- Store.runStoreIO billing $
          consumeAndApply record (loggingReactionHandler "billing")
        case consumed of
          ConsumeApplied (InboxProcessed ()) -> pure ()
          other -> expectationFailure ("expected processed, got " <> show other)
      Right events <- Store.runStoreIO billing $
        Store.runTransaction (Tx.statement () billingEventLogStmt)
      events `shouldBe` [("OrderSubmitted", "order-bbb"), ("OrderCancelled", "order-bbb")]

    it "head-of-line blocks a same-key successor when the first send fails repeatedly until the first row reaches dead status" $ \(ordering, billing) -> do
      Right () <- Store.runStoreIO ordering initializeOutboxSchema
      Right () <- Store.runStoreIO billing initializeInboxSchema
      Right () <- Store.runStoreIO billing $
        Store.runTransaction (Tx.sql "CREATE TABLE IF NOT EXISTS billing_received_orders (order_id TEXT PRIMARY KEY, quantity BIGINT NOT NULL)")
      topic <- newKafkaTopic
      let submittedEnv = orderSubmittedEnvelope "order-ccc" 1 "msg-ccc-1"
          cancelledEnv = orderCancelledEnvelope "order-ccc" "msg-ccc-2"
          firstId = OutboxId outboxUuid1
          secondId = OutboxId outboxUuid2
      Right () <- Store.runStoreIO ordering $
        Store.runTransaction (enqueueIntegrationEventTx firstId submittedEnv)
      Right () <- Store.runStoreIO ordering $
        Store.runTransaction (enqueueIntegrationEventTx secondId cancelledEnv)
      -- Failing publish for the first row, success for any other.
      let publish row
            | row ^. #outboxId == firstId =
                pure (PublishFailed "simulated broker reject")
            | otherwise = do
                kafkaTopicAccept topic row
                pure PublishSucceeded
          deadOpts =
            defaultPublishOptions
              & #batchSize .~ 10
              & #backoff .~ ConstantBackoff 0
              & #maxAttempts .~ 2
      -- First pass: the first row attempts once and fails, the second is
      -- blocked behind it.
      Right pass1 <- Store.runStoreIO ordering (publishClaimedOutbox publish deadOpts)
      pass1 ^. #retried `shouldBe` 1
      pass1 ^. #published `shouldBe` 0
      -- Second pass crosses maxAttempts and dead-letters the first row.
      Right pass2 <- Store.runStoreIO ordering (publishClaimedOutbox publish deadOpts)
      pass2 ^. #dead `shouldBe` 1
      Right (Just firstRow) <- Store.runStoreIO ordering (lookupOutbox firstId)
      firstRow ^. #status `shouldBe` OutboxDead
      -- With the first row dead, the second becomes claimable and publishes.
      Right pass3 <- Store.runStoreIO ordering (publishClaimedOutbox publish deadOpts)
      pass3 ^. #published `shouldBe` 1
      Right (Just secondRow) <- Store.runStoreIO ordering (lookupOutbox secondId)
      secondRow ^. #status `shouldBe` OutboxSent
      -- Billing only sees the second event.
      records <- drainKafkaTopic topic
      record <- case records of
        [r] -> pure r
        other -> expectationFailure ("expected 1 record, got " <> show (length other)) *> error "unreachable"
      Right consumed <- Store.runStoreIO billing $
        consumeAndApply record billingReactionHandler
      consumed `shouldBe` ConsumeApplied (InboxProcessed ())

  describe "Keiro.Integration.Event" $ do
    it "round-trips a JSON envelope through encode and decode" $ do
      let envelope = sampleIntegrationEnvelope
          payload = OrderSubmittedPayload "order-123" 5
          encoded = encodeJsonIntegrationEvent envelope payload
      decodeJsonIntegrationEvent encoded `shouldBe` Right payload

    it "preserves identity and routing through encode" $ do
      let envelope = sampleIntegrationEnvelope
          encoded = encodeJsonIntegrationEvent envelope (OrderSubmittedPayload "order-123" 5)
      encoded ^. #messageId `shouldBe` envelope ^. #messageId
      encoded ^. #source `shouldBe` "ordering"
      encoded ^. #destination `shouldBe` "billing.orders.v1"
      encoded ^. #key `shouldBe` Just "order-123"
      encoded ^. #eventType `shouldBe` "OrderSubmitted"
      encoded ^. #schemaVersion `shouldBe` 1
      encoded ^. #contentType `shouldBe` ApplicationJson

    it "emits the canonical wire headers" $ do
      let envelope = sampleIntegrationEnvelope
          headers = integrationHeaders envelope
      Prelude.lookup headerMessageId headers `shouldBe` Just (envelope ^. #messageId)
      Prelude.lookup headerSchemaVersion headers `shouldBe` Just "1"
      Prelude.lookup headerContentType headers `shouldBe` Just "application/json"
      Prelude.lookup headerSchemaSubject headers `shouldBe` Just "billing.orders.v1.OrderSubmitted"
      Prelude.lookup headerSourceEventId headers `shouldBe` Just "018f0f18-17aa-7000-8000-000000000003"
      Prelude.lookup headerSourceGlobalPosition headers `shouldBe` Just "42"
      Prelude.lookup headerTraceParent headers
        `shouldBe` Just "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

    it "preserves a different content type without claiming JSON" $ do
      let envelope = sampleIntegrationEnvelope
            & #contentType .~ OtherContentType "application/vnd.apache.avro.binary"
            & #payloadBytes .~ "\x00\x01\x02"
          headers = integrationHeaders envelope
      Prelude.lookup headerContentType headers
        `shouldBe` Just "application/vnd.apache.avro.binary"
      decodeJsonIntegrationEvent envelope
        `shouldBe` (Left (IntegrationEvent.UnsupportedContentType "application/vnd.apache.avro.binary")
                     :: Either IntegrationEvent.IntegrationEventError OrderSubmittedPayload)

    it "reports malformed JSON payloads as decode errors instead of throwing" $ do
      let envelope = sampleIntegrationEnvelope
            & #payloadBytes .~ "{not-json"
      case decodeJsonIntegrationEvent envelope :: Either IntegrationEvent.IntegrationEventError OrderSubmittedPayload of
        Left (IntegrationEvent.MalformedPayload _) -> pure ()
        other -> expectationFailure ("expected MalformedPayload, got " <> show other)

    it "reports a JSON value that does not satisfy the target type as DecodeFailed" $ do
      let envelope = sampleIntegrationEnvelope
            & #payloadBytes .~ "{\"orderId\":\"order-123\"}"
      case decodeJsonIntegrationEvent envelope :: Either IntegrationEvent.IntegrationEventError OrderSubmittedPayload of
        Left (IntegrationEvent.DecodeFailed _) -> pure ()
        other -> expectationFailure ("expected DecodeFailed, got " <> show other)

    it "parses content-type headers back to the canonical type" $ do
      parseContentType "application/json" `shouldBe` ApplicationJson
      parseContentType "Application/JSON" `shouldBe` ApplicationJson
      parseContentType "application/vnd.apache.avro.binary"
        `shouldBe` OtherContentType "application/vnd.apache.avro.binary"

    it "preserves the payload bytes through integrationPayload" $ do
      let envelope = sampleIntegrationEnvelope
          encoded = encodeJsonIntegrationEvent envelope (OrderSubmittedPayload "order-123" 5)
      integrationPayload encoded `shouldBe` (encoded ^. #payloadBytes)

  describe "Keiro.Telemetry" $ do
    it "is a pass-through under a noop (Nothing) tracer" $ do
      counter <- newIORef (0 :: Int)
      let envelope = sampleIntegrationEnvelope
          record = OutboxKafka.integrationEventToKafkaRecord envelope
      result <-
        Telemetry.withProducerSpan Nothing envelope record $ \mSpan -> do
          atomicModifyIORef' counter (\n -> (n + 1, ()))
          pure (mSpan, "ok" :: Text)
      callsAfter <- readIORef counter
      callsAfter `shouldBe` (1 :: Int)
      snd result `shouldBe` "ok"
      fst result `shouldSatisfy` isNothing

    it "vendors AttributeKeys whose textual payload matches the spec name" $ do
      attrKeyText Telemetry.messaging_operation_type `shouldBe` "messaging.operation.type"
      attrKeyText Telemetry.messaging_operation_name `shouldBe` "messaging.operation.name"
      attrKeyText Telemetry.messaging_destination_partition_id `shouldBe` "messaging.destination.partition.id"
      attrKeyText Telemetry.messaging_consumer_group_name `shouldBe` "messaging.consumer.group.name"
      attrKeyText Telemetry.messaging_client_id `shouldBe` "messaging.client.id"
      attrKeyTextInt64 Telemetry.messaging_kafka_offset `shouldBe` "messaging.kafka.offset"
      attrKeyText Telemetry.db_system_name `shouldBe` "db.system.name"
      attrKeyText Telemetry.db_namespace `shouldBe` "db.namespace"
      attrKeyText Telemetry.db_collection_name `shouldBe` "db.collection.name"
      attrKeyText Telemetry.db_operation_name `shouldBe` "db.operation.name"
      attrKeyText Telemetry.keiro_stream_name `shouldBe` "keiro.stream.name"
      attrKeyTextInt64 Telemetry.keiro_retry_attempt `shouldBe` "keiro.retry.attempt"
      attrKeyTextInt64 Telemetry.keiro_events_appended `shouldBe` "keiro.events.appended"

    it "extracts a TraceContext from a W3C traceparent header pair" $ do
      let traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
          tracestate = "vendor1=value1"
          hs = [(headerTraceParent, traceparent), ("tracestate", tracestate)]
      Telemetry.traceContextFromHeaders hs
        `shouldBe` Just (TraceContext traceparent (Just tracestate))

    it "returns Nothing when the traceparent header is missing" $ do
      Telemetry.traceContextFromHeaders [("content-type", "application/json")]
        `shouldBe` Nothing

    it "injectTraceContext is a no-op when no span is active on the thread" $ do
      let baseline = [("content-type", "application/json")]
      injected <- Telemetry.injectTraceContext baseline
      injected `shouldBe` baseline

    it "traceContextFromCurrentSpan returns Nothing outside any span" $ do
      tc <- Telemetry.traceContextFromCurrentSpan
      tc `shouldBe` Nothing

nominalDays :: Int -> NominalDiffTime
nominalDays n = fromIntegral n * 86400

attrKeyText :: AttributeKey Text -> Text
attrKeyText = unkey

attrKeyTextInt64 :: AttributeKey Int64 -> Text
attrKeyTextInt64 = unkey

textAttr :: Attributes -> Text -> Maybe Text
textAttr attrs name = case lookupAttribute attrs name of
  Just (AttributeValue (TextAttribute t)) -> Just t
  _ -> Nothing

-- ---------------------------------------------------------------------------
-- Cross-context integration fixtures
-- ---------------------------------------------------------------------------

withTwoContexts ::
  ((Store.KirokuStore, Store.KirokuStore) -> IO ()) ->
  IO ()
withTwoContexts action = do
  result <- Pg.withCached $ \dbA ->
    Pg.withCached $ \dbB ->
      Store.withStore (Store.defaultConnectionSettings (Pg.connectionString dbA)) $ \ordering ->
        Store.withStore (Store.defaultConnectionSettings (Pg.connectionString dbB)) $ \billing ->
          action (ordering, billing)
  case result of
    Left err -> error ("Failed to start ordering ephemeral PostgreSQL: " <> show err)
    Right (Left err) -> error ("Failed to start billing ephemeral PostgreSQL: " <> show err)
    Right (Right ()) -> pure ()

-- | Tiny in-process \"Kafka topic\": an MVar of consumed records plus an
-- incrementing offset. The publisher pushes records here; the consumer
-- drains the MVar. There is no real broker — the goal of the fixture is
-- to validate that the keiro envelope and outbox/inbox semantics
-- compose correctly across two isolated PostgreSQL contexts.
newtype KafkaTopic = KafkaTopic (MVar (Int64, [InboxKafka.KafkaInboundRecord]))

newKafkaTopic :: IO KafkaTopic
newKafkaTopic = KafkaTopic <$> newMVar (0, [])

kafkaTopicAccept :: (MonadIO m) => KafkaTopic -> OutboxRow -> m ()
kafkaTopicAccept (KafkaTopic ref) row = liftIO $ do
  let record = OutboxKafka.outboxRowToKafkaRecord row
      headersText =
        [ (TE.decodeUtf8 name, TE.decodeUtf8 value)
        | (name, value) <- record ^. #headers
        ]
  now <- getCurrentTime
  modifyMVar ref $ \(nextOffset, acc) ->
    let inbound =
          InboxKafka.KafkaInboundRecord
            { topic = record ^. #topic
            , partition = 0
            , offset = nextOffset
            , key = fmap TE.decodeUtf8 (record ^. #key)
            , payload = record ^. #payload
            , headers = headersText
            , receivedAt = now
            }
     in pure ((nextOffset + 1, inbound : acc), ())

kafkaTopicPublish ::
  forall es.
  (IOE :> es) =>
  KafkaTopic ->
  OutboxRow ->
  Eff es PublishOutcome
kafkaTopicPublish topic row = do
  kafkaTopicAccept topic row
  pure PublishSucceeded

drainKafkaTopic :: KafkaTopic -> IO [InboxKafka.KafkaInboundRecord]
drainKafkaTopic (KafkaTopic ref) = do
  (_, acc) <- readMVar ref
  pure (reverse acc)

redeliverWithDifferentOffset ::
  InboxKafka.KafkaInboundRecord ->
  InboxKafka.KafkaInboundRecord
redeliverWithDifferentOffset record = record & #offset .~ (record ^. #offset) + 1000

data ConsumeResult a
  = ConsumeDecodeFailed !InboxKafka.KafkaDecodeError
  | ConsumePolicyUnsatisfied !InboxError
  | ConsumeApplied !(InboxResult a)
  deriving stock (Eq, Show)

-- | A worker-shaped consumer: decode the Kafka record into an
-- IntegrationEvent and run it through the inbox.
consumeAndApply ::
  forall es.
  (IOE :> es, Store :> es) =>
  InboxKafka.KafkaInboundRecord ->
  (IntegrationEvent -> Tx.Transaction ()) ->
  Eff es (ConsumeResult ())
consumeAndApply record handler =
  case InboxKafka.integrationEventFromKafka record of
    Left err -> pure (ConsumeDecodeFailed err)
    Right (event, kafkaRef) -> do
      result <-
        runInboxTransaction PreferIntegrationMessageId event (Just kafkaRef) handler
      case result of
        Left err -> pure (ConsumePolicyUnsatisfied err)
        Right applied -> pure (ConsumeApplied applied)

billingReactionHandler :: IntegrationEvent -> Tx.Transaction ()
billingReactionHandler event = case decodeJsonIntegrationEvent event of
  Left _ -> Tx.condemn
  Right (OrderSubmittedPayload orderId quantity) ->
    Tx.statement (orderId, fromIntegral quantity :: Int64) insertReceivedOrderStmt

loggingReactionHandler :: Text -> IntegrationEvent -> Tx.Transaction ()
loggingReactionHandler _ event = do
  -- The cross-context test only needs the (eventType, key) pair, not
  -- the decoded payload.
  let key = fromMaybe "" (event ^. #key)
  Tx.statement (event ^. #source, event ^. #eventType, key) appendBillingEventLogStmt

insertReceivedOrderStmt :: Statement (Text, Int64) ()
insertReceivedOrderStmt =
  preparable
    """
    INSERT INTO billing_received_orders (order_id, quantity) VALUES ($1, $2)
    ON CONFLICT (order_id) DO NOTHING
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
    )
    D.noResult

billingReceivedOrdersCountStmt :: Statement () Int
billingReceivedOrdersCountStmt =
  preparable
    "SELECT COUNT(*)::bigint FROM billing_received_orders"
    E.noParams
    (D.singleRow (fromIntegral <$> D.column (D.nonNullable D.int8)))

appendBillingEventLogStmt :: Statement (Text, Text, Text) ()
appendBillingEventLogStmt =
  preparable
    "INSERT INTO billing_event_log (source, event_type, order_id) VALUES ($1, $2, $3)"
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    D.noResult

billingEventLogStmt :: Statement () [(Text, Text)]
billingEventLogStmt =
  preparable
    "SELECT event_type, order_id FROM billing_event_log ORDER BY seq"
    E.noParams
    (D.rowList
        ( (,)
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
        )
    )

orderSubmittedEnvelope :: Text -> Int -> Text -> IntegrationEvent
orderSubmittedEnvelope orderId quantity messageId =
  encodeJsonIntegrationEvent
    ( sampleIntegrationEnvelope
        & #messageId .~ messageId
        & #eventType .~ "OrderSubmitted"
        & #key .~ Just orderId
    )
    (OrderSubmittedPayload orderId quantity)

orderCancelledEnvelope :: Text -> Text -> IntegrationEvent
orderCancelledEnvelope orderId messageId =
  sampleIntegrationEnvelope
    & #messageId .~ messageId
    & #eventType .~ "OrderCancelled"
    & #key .~ Just orderId
    & #payloadBytes .~ ("{\"orderId\":\"" <> TE.encodeUtf8 orderId <> "\"}")
    & #contentType .~ ApplicationJson

inboxTestCounterInsertStmt :: Statement Text ()
inboxTestCounterInsertStmt =
  preparable
    "INSERT INTO inbox_test_counter (message_id) VALUES ($1)"
    (E.param (E.nonNullable E.text))
    D.noResult

inboxTestCounterCountStmt :: Statement () Int
inboxTestCounterCountStmt =
  preparable
    "SELECT COUNT(*)::bigint FROM inbox_test_counter"
    E.noParams
    (D.singleRow (fromIntegral <$> D.column (D.nonNullable D.int8)))

sampleProducer :: IntegrationProducer ()
sampleProducer = IntegrationProducer
  { name = "ordering-integration-producer"
  , source = "ordering"
  , messageIdPrefix = "msg"
  , mapEvent = \_recorded () -> Just sampleDraft
  }

sampleDraft :: IntegrationEventDraft
sampleDraft = IntegrationEventDraft
  { destination = "billing.orders.v1"
  , key = Just "order-123"
  , eventType = "OrderSubmitted"
  , schemaVersion = 1
  , contentType = ApplicationJson
  , schemaReference = Nothing
  , sourceEventId = Nothing
  , sourceGlobalPosition = Nothing
  , payloadBytes = "{\"orderId\":\"order-123\",\"quantity\":5}"
  , occurredAt = UTCTime (ModifiedJulianDay 60000) (secondsToDiffTime 0)
  , causationId = Nothing
  , correlationId = Nothing
  , traceContext = Nothing
  , attributes = Nothing
  }

sampleOutboxRow :: IntegrationEvent -> OutboxRow
sampleOutboxRow event = OutboxRow
  { outboxId = OutboxId outboxUuid1
  , event
  , status = OutboxPending
  , attemptCount = 0
  , nextAttemptAt = UTCTime (ModifiedJulianDay 60000) (secondsToDiffTime 0)
  , lastError = Nothing
  , publishedAt = Nothing
  , createdAt = UTCTime (ModifiedJulianDay 60000) (secondsToDiffTime 0)
  , updatedAt = UTCTime (ModifiedJulianDay 60000) (secondsToDiffTime 0)
  }

outboxUuid1, outboxUuid2, outboxUuid3 :: UUID
outboxUuid1 = case fromString "018f0f18-0000-7000-8000-000000000a01" of
  Just uuid -> uuid
  Nothing -> error "invalid outbox uuid 1"
outboxUuid2 = case fromString "018f0f18-0000-7000-8000-000000000a02" of
  Just uuid -> uuid
  Nothing -> error "invalid outbox uuid 2"
outboxUuid3 = case fromString "018f0f18-0000-7000-8000-000000000a03" of
  Just uuid -> uuid
  Nothing -> error "invalid outbox uuid 3"

uniqueIds :: Eq a => [a] -> [a]
uniqueIds = foldr (\x xs -> if x `elem` xs then xs else x : xs) []

data OrderSubmittedPayload = OrderSubmittedPayload
  { orderId :: !Text
  , quantity :: !Int
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON OrderSubmittedPayload where
  toJSON = genericToJSON (aesonPrefix camelCase)
  toEncoding = genericToEncoding (aesonPrefix camelCase)

instance FromJSON OrderSubmittedPayload where
  parseJSON = genericParseJSON (aesonPrefix camelCase)

sampleIntegrationEnvelope :: IntegrationEvent
sampleIntegrationEnvelope =
  IntegrationEvent
    { messageId = "018f0f18-17aa-7000-8000-0000000000aa"
    , source = "ordering"
    , destination = "billing.orders.v1"
    , key = Just "order-123"
    , eventType = "OrderSubmitted"
    , schemaVersion = 1
    , contentType = ApplicationJson
    , schemaReference = Just SchemaReference
        { registry = Just "https://schemas.example/registry"
        , subject = Just "billing.orders.v1.OrderSubmitted"
        , version = Just 1
        , schemaId = Just 42
        , fingerprint = Just "sha256:abc123"
        }
    , sourceEventId = Just (EventId integrationSourceEventUuid)
    , sourceGlobalPosition = Just (GlobalPosition 42)
    , payloadBytes = "{\"orderId\":\"order-123\",\"quantity\":5}"
    , occurredAt = UTCTime (ModifiedJulianDay 60000) (secondsToDiffTime 0)
    , causationId = Just (EventId integrationCausationUuid)
    , correlationId = Just (EventId integrationCorrelationUuid)
    , traceContext = Just TraceContext
        { traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
        , tracestate = Just "rojo=00f067aa0ba902b7"
        }
    , attributes = Nothing
    }

integrationSourceEventUuid :: UUID
integrationSourceEventUuid =
  case fromString "018f0f18-17aa-7000-8000-000000000003" of
    Just uuid -> uuid
    Nothing -> error "invalid integration source event UUID"

integrationCausationUuid :: UUID
integrationCausationUuid =
  case fromString "018f0f18-17aa-7000-8000-000000000004" of
    Just uuid -> uuid
    Nothing -> error "invalid integration causation UUID"

integrationCorrelationUuid :: UUID
integrationCorrelationUuid =
  case fromString "018f0f18-17aa-7000-8000-000000000005" of
    Just uuid -> uuid
    Nothing -> error "invalid integration correlation UUID"

data OrderStream

data OrderEvent
  = OrderPlaced !Text !Int
  deriving stock (Generic, Eq, Show)

data OrderState
  = Idle
  deriving stock (Generic, Eq, Show)

data OrderCommand
  = PlaceOrder
  deriving stock (Generic, Eq, Show)

orderCodec :: Codec OrderEvent
orderCodec = Codec
  { eventTypes = "OrderPlaced" :| []
  , eventType = \case
      OrderPlaced{} -> "OrderPlaced"
  , schemaVersion = 2
  , encode = \case
      OrderPlaced orderId quantity ->
        object ["orderId" Aeson..= orderId, "quantity" Aeson..= quantity]
  , decode = parseOrderPlaced
  , upcasters = [(1, upcastOrderPlacedV1)]
  }

gappyCodec :: Codec OrderEvent
gappyCodec = Codec
  { eventTypes = orderCodec ^. #eventTypes
  , eventType = orderCodec ^. #eventType
  , schemaVersion = 4
  , encode = orderCodec ^. #encode
  , decode = orderCodec ^. #decode
  , upcasters = [(1, upcastOrderPlacedV1), (3, Right)]
  }

parseOrderPlaced :: Value -> Either Text OrderEvent
parseOrderPlaced value =
  case parseEither parser value of
    Right event -> Right event
    Left message -> Left (fromStringLiteral message)
  where
    parser = withObject "OrderPlaced" $ \objectValue ->
      OrderPlaced
        <$> objectValue .: "orderId"
        <*> objectValue .: "quantity"

upcastOrderPlacedV1 :: Value -> Either Text Value
upcastOrderPlacedV1 value =
  case parseEither parser value of
    Right migrated -> Right migrated
    Left message -> Left (fromStringLiteral message)
  where
    parser = withObject "OrderPlacedV1" $ \objectValue -> do
      orderId <- objectValue .: "orderId"
      quantity <- objectValue .: "qty"
      pure (object ["orderId" Aeson..= (orderId :: Text), "quantity" Aeson..= (quantity :: Int)])

emptyTransducer :: SymTransducer () '[] OrderState OrderCommand OrderEvent
emptyTransducer = SymTransducer
  { edgesOut = \_ -> []
  , initial = Idle
  , initialRegs = RNil
  , isFinal = \_ -> True
  }

type CounterEventStream = EventStream (HsPred '[] CounterCommand) '[] CounterState CounterCommand CounterEvent

type SnapshotCounterRegs = '[ '("lastAmount", Int)]

type SnapshotCounterEventStream = EventStream (HsPred SnapshotCounterRegs CounterCommand) SnapshotCounterRegs CounterState CounterCommand CounterEvent

data CounterCommand
  = Add !Int
  deriving stock (Generic, Eq, Show)

data CounterEvent
  = CounterAdded !Int
  | CounterAudited !Int
  deriving stock (Generic, Eq, Show)

data CounterState
  = Counting
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

counterEventStream :: CounterEventStream
counterEventStream = EventStream
  { transducer = counterTransducer
  , initialState = Counting
  , initialRegisters = RNil
  , eventCodec = counterCodec
  , resolveStreamName = Stream.streamName
  , snapshotPolicy = Never
  , stateCodec = Nothing
  }

counterTransducer :: SymTransducer (HsPred '[] CounterCommand) '[] CounterState CounterCommand CounterEvent
counterTransducer = SymTransducer
  { edgesOut = \case
      Counting ->
        [ Edge
            { guard = matchInCtor addCtor
            , update = UKeep
            , output = [pack addCtor counterAddedCtor (inpCtor addCtor #amount *: oNil)]
            , target = Counting
            }
        ]
  , initial = Counting
  , initialRegs = RNil
  , isFinal = \_ -> False
  }

multiCounterEventStream :: CounterEventStream
multiCounterEventStream =
  counterEventStream & #transducer .~ multiCounterTransducer

multiCounterTransducer :: SymTransducer (HsPred '[] CounterCommand) '[] CounterState CounterCommand CounterEvent
multiCounterTransducer = SymTransducer
  { edgesOut = \case
      Counting ->
        [ Edge
            { guard = matchInCtor addCtor
            , update = UKeep
            , output =
                [ pack addCtor counterAddedCtor (inpCtor addCtor #amount *: oNil)
                , pack addCtor counterAuditedCtor (inpCtor addCtor #amount *: oNil)
                ]
            , target = Counting
            }
        ]
  , initial = Counting
  , initialRegs = RNil
  , isFinal = \_ -> False
  }

snapshotCounterEventStream :: SnapshotCounterEventStream
snapshotCounterEventStream = EventStream
  { transducer = snapshotCounterTransducer
  , initialState = Counting
  , initialRegisters = RCons (Proxy @"lastAmount") 0 RNil
  , eventCodec = counterCodec
  , resolveStreamName = Stream.streamName
  , snapshotPolicy = Every 2
  , stateCodec = Just (defaultStateCodec @SnapshotCounterRegs @CounterState 1)
  }

snapshotCounterTransducer :: SymTransducer (HsPred SnapshotCounterRegs CounterCommand) SnapshotCounterRegs CounterState CounterCommand CounterEvent
snapshotCounterTransducer = SymTransducer
  { edgesOut = \case
      Counting ->
        [ Edge
            { guard = matchInCtor addCtor
            , update =
                USet
                  (#lastAmount :: IndexN "lastAmount" SnapshotCounterRegs Int)
                  (inpCtor addCtor #amount)
            , output = [pack addCtor counterAddedCtor (inpCtor addCtor #amount *: oNil)]
            , target = Counting
            }
        ]
  , initial = Counting
  , initialRegs = RCons (Proxy @"lastAmount") 0 RNil
  , isFinal = \_ -> False
  }

multiSnapshotCounterEventStream :: SnapshotCounterEventStream
multiSnapshotCounterEventStream =
  snapshotCounterEventStream
    & #transducer .~ multiSnapshotCounterTransducer
    & #snapshotPolicy .~ Every 1

multiSnapshotCounterTransducer :: SymTransducer (HsPred SnapshotCounterRegs CounterCommand) SnapshotCounterRegs CounterState CounterCommand CounterEvent
multiSnapshotCounterTransducer = SymTransducer
  { edgesOut = \case
      Counting ->
        [ Edge
            { guard = matchInCtor addCtor
            , update =
                USet
                  (#lastAmount :: IndexN "lastAmount" SnapshotCounterRegs Int)
                  (inpCtor addCtor #amount)
            , output =
                [ pack addCtor counterAddedCtor (inpCtor addCtor #amount *: oNil)
                , pack addCtor counterAuditedCtor (inpCtor addCtor #amount *: oNil)
                ]
            , target = Counting
            }
        ]
  , initial = Counting
  , initialRegs = RCons (Proxy @"lastAmount") 0 RNil
  , isFinal = \_ -> False
  }

guardedSnapshotCounterEventStream :: SnapshotCounterEventStream
guardedSnapshotCounterEventStream =
  snapshotCounterEventStream & #transducer .~ guardedSnapshotCounterTransducer

guardedSnapshotCounterTransducer :: SymTransducer (HsPred SnapshotCounterRegs CounterCommand) SnapshotCounterRegs CounterState CounterCommand CounterEvent
guardedSnapshotCounterTransducer = SymTransducer
  { edgesOut = \case
      Counting ->
        [ Edge
            { guard =
                PAnd
                  (matchInCtor addCtor)
                  (inpCtor addCtor #amount .== proj (#lastAmount :: Keiki.Index SnapshotCounterRegs Int))
            , update =
                USet
                  (#lastAmount :: IndexN "lastAmount" SnapshotCounterRegs Int)
                  (inpCtor addCtor #amount)
            , output = [pack addCtor counterAddedCtor (inpCtor addCtor #amount *: oNil)]
            , target = Counting
            }
        ]
  , initial = Counting
  , initialRegs = RCons (Proxy @"lastAmount") 0 RNil
  , isFinal = \_ -> False
  }

type AddFields = '[ '("amount", Int)]

addCtor :: InCtor CounterCommand AddFields
addCtor = InCtor
  { icName = "Add"
  , icMatch = \case
      Add amount -> Just (RCons Proxy amount RNil)
  , icBuild = \case
      RCons _ amount RNil -> Add amount
  }

counterAddedCtor :: WireCtor CounterEvent (Int, ())
counterAddedCtor = WireCtor
  { wcName = "CounterAdded"
  , wcMatch = \case
      CounterAdded amount -> Just (amount, ())
      CounterAudited{} -> Nothing
  , wcBuild = \case
      (amount, ()) -> CounterAdded amount
  }

counterAuditedCtor :: WireCtor CounterEvent (Int, ())
counterAuditedCtor = WireCtor
  { wcName = "CounterAudited"
  , wcMatch = \case
      CounterAudited amount -> Just (amount, ())
      CounterAdded{} -> Nothing
  , wcBuild = \case
      (amount, ()) -> CounterAudited amount
  }

counterCodec :: Codec CounterEvent
counterCodec = Codec
  { eventTypes = "CounterAdded" :| ["CounterAudited"]
  , eventType = \case
      CounterAdded{} -> "CounterAdded"
      CounterAudited{} -> "CounterAudited"
  , schemaVersion = 1
  , encode = \case
      CounterAdded amount -> object ["amount" Aeson..= amount]
      CounterAudited amount -> object ["amount" Aeson..= amount, "audited" Aeson..= True]
  , decode = parseCounterEvent
  , upcasters = []
  }

parseCounterEvent :: Value -> Either Text CounterEvent
parseCounterEvent value =
  case parseEither parser value of
    Right event -> Right event
    Left message -> Left (fromStringLiteral message)
  where
    parser = withObject "CounterEvent" $ \objectValue -> do
      amount <- objectValue .: "amount"
      audited <- objectValue .:? "audited"
      pure $
        if audited == Just True
          then CounterAudited amount
          else CounterAdded amount

counterProcessManager ::
  ProcessManager
    CounterEvent
    (HsPred '[] CounterCommand)
    '[]
    CounterState
    CounterCommand
    CounterEvent
    (HsPred '[] CounterCommand)
    '[]
    CounterState
    CounterCommand
    CounterEvent
counterProcessManager = ProcessManager
  { name = "counter-pm"
  , correlate = \_ -> "order-1"
  , eventStream = counterEventStream
  , streamFor = \correlationId -> stream ("pm:counter-" <> correlationId)
  , targetEventStream = counterEventStream
  , handle = \case
      CounterAdded amount ->
        ProcessManagerAction
          { command = Add amount
          , commands =
              [ PMCommand
                  { target = stream "counter-target-order-1"
                  , command = Add amount
                  }
              ]
          , timers = [counterTimerRequest]
          }
      CounterAudited amount ->
        ProcessManagerAction
          { command = Add amount
          , commands = []
          , timers = []
          }
  }

workflowProcessManager ::
  Text ->
  Text ->
  Text ->
  ProcessManager
    CounterEvent
    (HsPred '[] CounterCommand)
    '[]
    CounterState
    CounterCommand
    CounterEvent
    (HsPred '[] CounterCommand)
    '[]
    CounterState
    CounterCommand
    CounterEvent
workflowProcessManager managerName managerCategory targetStreamName =
  counterProcessManager
    { name = managerName
    , streamFor = \correlationId -> stream (managerCategory <> "-" <> correlationId)
    , handle = \case
        CounterAdded amount ->
          ProcessManagerAction
            { command = Add amount
            , commands =
                [ PMCommand
                    { target = stream targetStreamName
                    , command = Add amount
                    }
                ]
            , timers = []
            }
        CounterAudited amount ->
          ProcessManagerAction
            { command = Add amount
            , commands = []
            , timers = []
            }
    }

assertWorkflowProcessManagerAppended ::
  Either
    Store.StoreError
    ( Either
        CommandError
        (ProcessManagerResult CounterEventStream CounterEventStream)
    ) ->
  Expectation
assertWorkflowProcessManagerAppended = \case
  Right (Right pmResult) -> do
    pmResult ^. #managerResult `shouldSatisfy` \case
      PMStateAppended{} -> True
      _ -> False
    pmResult ^. #commandResults `shouldSatisfy` \case
      [PMCommandAppended{}] -> True
      _ -> False
  other -> expectationFailure ("expected workflow process-manager success, got " <> show other)

counterTimerRequest :: TimerRequest
counterTimerRequest = TimerRequest
  { timerId = TimerId sampleUuid
  , processManagerName = "counter-pm"
  , correlationId = "order-1"
  , fireAt = dueTimerTime
  , payload = object ["kind" Aeson..= ("counter-timeout" :: Text)]
  }

dueTimerTime :: UTCTime
dueTimerTime = UTCTime (ModifiedJulianDay 1) (secondsToDiffTime 0)

withTestStore :: (Store.KirokuStore -> IO ()) -> IO ()
withTestStore action = do
  result <- Pg.withCached $ \db ->
    Store.withStore (Store.defaultConnectionSettings (Pg.connectionString db)) action
  case result of
    Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
    Right () -> pure ()

recordedFrom :: EventData -> RecordedEvent
recordedFrom event = RecordedEvent
  { eventId = EventId sampleUuid
  , eventType = event ^. #eventType
  , streamVersion = StreamVersion 1
  , globalPosition = GlobalPosition 1
  , originalStreamId = StreamId 1
  , originalVersion = StreamVersion 1
  , payload = event ^. #payload
  , metadata = event ^. #metadata
  , causationId = Nothing
  , correlationId = Nothing
  , createdAt = UTCTime (ModifiedJulianDay 0) (secondsToDiffTime 0)
  }

recordedFromEventId :: EventId -> CounterEvent -> RecordedEvent
recordedFromEventId eventId event =
  case encodeForAppend counterCodec event of
    Right encoded -> recordedFrom encoded & #eventId .~ eventId
    Left err -> error ("test fixture failed to encode counter event: " <> show err)

sampleUuid :: UUID
sampleUuid =
  case fromString "018f0f18-17aa-7000-8000-000000000001" of
    Just uuid -> uuid
    Nothing -> error "invalid test UUID"

sampleUuid2 :: UUID
sampleUuid2 =
  case fromString "018f0f18-17aa-7000-8000-000000000002" of
    Just uuid -> uuid
    Nothing -> error "invalid test UUID"

shouldBeRight :: (HasCallStack, Show e) => Either e a -> IO a
shouldBeRight = \case
  Right value -> pure value
  Left err -> expectationFailure ("expected Right, got Left " <> show err) *> error "unreachable"

fromStringLiteral :: String -> Text
fromStringLiteral = Text.pack

snapshotVersionForStreamStmt :: Statement Text (Maybe StreamVersion)
snapshotVersionForStreamStmt =
  preparable
    """
    SELECT ks.stream_version
    FROM keiro_snapshots ks
    JOIN streams s ON s.stream_id = ks.stream_id
    WHERE s.stream_name = $1
    """
    (E.param (E.nonNullable E.text))
    (D.rowMaybe (StreamVersion <$> D.column (D.nonNullable D.int8)))

corruptSnapshotStateStmt :: Statement (Text, Value) ()
corruptSnapshotStateStmt =
  preparable
    """
    UPDATE keiro_snapshots ks
    SET state = $2
    FROM streams s
    WHERE s.stream_id = ks.stream_id
      AND s.stream_name = $1
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.jsonb))
    )
    D.noResult

corruptSnapshotShapeStmt :: Statement (Text, Text) ()
corruptSnapshotShapeStmt =
  preparable
    """
    UPDATE keiro_snapshots ks
    SET regfile_shape_hash = $2
    FROM streams s
    WHERE s.stream_id = ks.stream_id
      AND s.stream_name = $1
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    D.noResult

counterReadModel :: ReadModel Text Int
counterReadModel = ReadModel
  { name = "counter-read-model"
  , tableName = "counter_read_model"
  , subscriptionName = "counter-read-model-sub"
  , version = 1
  , shapeHash = "counter-read-model-v1"
  , defaultConsistency = Strong
  , query = \modelId -> Tx.statement modelId selectCounterReadModelStmt
  }

counterInlineProjection :: InlineProjection CounterEvent
counterInlineProjection = InlineProjection
  { name = "counter-inline-projection"
  , apply = \event appendResult ->
      case event of
        CounterAdded amount ->
          Tx.statement
            ( "inline"
            , Prelude.fromIntegral amount
            , globalPositionToInt (appendResult ^. #globalPosition)
            , Nothing
            )
            upsertCounterReadModelStmt
        CounterAudited{} -> pure ()
  }

counterAsyncProjection :: AsyncProjection
counterAsyncProjection = AsyncProjection
  { name = "counter-async-projection"
  , subscriptionName = "counter-read-model-sub"
  , applyRecorded = \recorded ->
      case decodeRecorded counterCodec recorded of
        Right (CounterAdded amount) ->
          Tx.statement
            ( "async-idempotent"
            , Prelude.fromIntegral amount
            , globalPositionToInt (recorded ^. #globalPosition)
            , Just (eventIdToUuid (recorded ^. #eventId))
            )
            upsertCounterReadModelStmt
        Right CounterAudited{} -> pure ()
        Left _ -> pure ()
  , idempotencyKey = \recorded -> recorded ^. #eventId
  }

fastWaitOptions :: PositionWaitOptions
fastWaitOptions = PositionWaitOptions
  { target = Nothing
  , timeoutMicros = 50000
  , pollMicros = 5000
  }

initializeCounterReadModelTable :: Tx.Transaction ()
initializeCounterReadModelTable =
  Tx.sql
    """
    CREATE TABLE IF NOT EXISTS counter_read_model (
      model_id TEXT PRIMARY KEY,
      amount BIGINT NOT NULL,
      last_seen BIGINT NOT NULL,
      source_event_id UUID UNIQUE
    )
    """

upsertCounterReadModelStmt :: Statement (Text, Int64, Int64, Maybe UUID) ()
upsertCounterReadModelStmt =
  preparable
    """
    INSERT INTO counter_read_model (model_id, amount, last_seen, source_event_id)
    VALUES ($1, $2, $3, $4)
    ON CONFLICT (source_event_id) DO NOTHING
    """
    ( contrazip4
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nullable E.uuid))
    )
    D.noResult

selectCounterReadModelStmt :: Statement Text Int
selectCounterReadModelStmt =
  preparable
    """
    SELECT COALESCE((SELECT amount FROM counter_read_model WHERE model_id = $1), 0)
    """
    (E.param (E.nonNullable E.text))
    (D.singleRow (Prelude.fromIntegral <$> D.column (D.nonNullable D.int8)))

upsertSubscriptionCursorStmt :: Statement (Text, Int64) ()
upsertSubscriptionCursorStmt =
  preparable
    """
    INSERT INTO subscriptions (subscription_name, stream_name, last_seen)
    VALUES ($1, '$all', $2)
    ON CONFLICT (subscription_name) DO UPDATE
      SET last_seen = EXCLUDED.last_seen,
          updated_at = now()
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
    )
    D.noResult

updateReadModelVersionStmt :: Statement (Text, Int64) ()
updateReadModelVersionStmt =
  preparable
    """
    UPDATE keiro_read_models
    SET version = $2
    WHERE name = $1
    """
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
    )
    D.noResult

globalPositionToInt :: GlobalPosition -> Int64
globalPositionToInt (GlobalPosition value) = value

eventIdToUuid :: EventId -> UUID
eventIdToUuid (EventId value) = value
