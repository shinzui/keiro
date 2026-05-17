{-# LANGUAGE MultilineStrings #-}

module Main
  ( main
  )
where

import Data.Aeson (object, withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Contravariant.Extras (contrazip2, contrazip4)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text qualified as Text
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
import Keiro.Prelude
import Keiro.Projection
import Keiro.ProcessManager
import Keiro.ReadModel
import Keiro.ReadModel.Rebuild qualified as Rebuild
import Keiro.Stream qualified as Stream
import Keiro.Timer
import Kiroku.Store qualified as Store
import Kiroku.Store.Types
  ( EventId (..)
  , EventData (..)
  , EventType (..)
  , ExpectedVersion (..)
  , GlobalPosition (..)
  , RecordedEvent (..)
  , StreamId (..)
  , StreamName (..)
  , StreamVersion (..)
  )
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
            , streamName = \s -> Stream.streamName s
            , snapshotPolicy = Never
            , stateCodec = Nothing
            }
          typedStream = stream "order-123" :: Stream (EventStream () '[] OrderState OrderCommand OrderEvent)
      contract ^. #initialState `shouldBe` Idle
      (contract ^. #streamName) typedStream `shouldBe` StreamName "order-123"

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
        Store.readStreamForward (StreamName "pm-counter-order-1") (StreamVersion 0) 10
      Right targetEvents <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "pm-target-order-1") (StreamVersion 0) 10
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
        Store.readStreamForward (StreamName "pm-counter-order-1") (StreamVersion 0) 10
      Right targetEvents <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "pm-target-order-1") (StreamVersion 0) 10
      Vector.length managerEvents `shouldBe` 1
      Vector.length targetEvents `shouldBe` 1

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
  , streamName = Stream.streamName
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
  , streamName = Stream.streamName
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
  , streamFor = \correlationId -> stream ("pm-counter-" <> correlationId)
  , targetEventStream = counterEventStream
  , handle = \case
      CounterAdded amount ->
        ProcessManagerAction
          { command = Add amount
          , commands =
              [ PMCommand
                  { target = stream "pm-target-order-1"
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
