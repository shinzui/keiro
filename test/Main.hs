module Main
  ( main
  )
where

import Data.Aeson (object, withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.Functor.Contravariant ((>$<))
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
import Hasql.Transaction qualified as Tx
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
import Keiro.Prelude
import Keiro.Stream qualified as Stream
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
      version `shouldBe` ("0.1.0.0" :: Text)

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
          (Left (HydrationDecodeFailed (UnknownEventType (EventType "OtherEvent") ["CounterAdded"])))

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
          Tx.statement (StreamName "snapshot-write-threshold") snapshotVersionForStreamStmt
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
            ( StreamName "snapshot-tail-hydration"
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
          Tx.statement (StreamName "snapshot-corrupt-json", Aeson.String "bad") corruptSnapshotStateStmt
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
          Tx.statement (StreamName "snapshot-shape-mismatch", "stale-shape") corruptSnapshotShapeStmt
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
            , output = Just (pack addCtor counterAddedCtor (inpCtor addCtor #amount *: oNil))
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
            , output = Just (pack addCtor counterAddedCtor (inpCtor addCtor #amount *: oNil))
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
            , output = Just (pack addCtor counterAddedCtor (inpCtor addCtor #amount *: oNil))
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
  , wcBuild = \case
      (amount, ()) -> CounterAdded amount
  }

counterCodec :: Codec CounterEvent
counterCodec = Codec
  { eventTypes = "CounterAdded" :| []
  , eventType = \case
      CounterAdded{} -> "CounterAdded"
  , schemaVersion = 1
  , encode = \case
      CounterAdded amount -> object ["amount" Aeson..= amount]
  , decode = parseCounterAdded
  , upcasters = []
  }

parseCounterAdded :: Value -> Either Text CounterEvent
parseCounterAdded value =
  case parseEither parser value of
    Right event -> Right event
    Left message -> Left (fromStringLiteral message)
  where
    parser = withObject "CounterAdded" $ \objectValue ->
      CounterAdded <$> objectValue .: "amount"

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

snapshotVersionForStreamStmt :: Statement StreamName (Maybe StreamVersion)
snapshotVersionForStreamStmt =
  preparable
    "SELECT ks.stream_version \
    \FROM keiro_snapshots ks \
    \JOIN streams s ON s.stream_id = ks.stream_id \
    \WHERE s.stream_name = $1"
    ((\(StreamName name) -> name) >$< E.param (E.nonNullable E.text))
    (D.rowMaybe (StreamVersion <$> D.column (D.nonNullable D.int8)))

corruptSnapshotStateStmt :: Statement (StreamName, Value) ()
corruptSnapshotStateStmt =
  preparable
    "UPDATE keiro_snapshots ks \
    \SET state = $2 \
    \FROM streams s \
    \WHERE s.stream_id = ks.stream_id \
    \  AND s.stream_name = $1"
    ( ((\(StreamName name, _) -> name) >$< E.param (E.nonNullable E.text))
        <> ((\(_, payload) -> payload) >$< E.param (E.nonNullable E.jsonb))
    )
    D.noResult

corruptSnapshotShapeStmt :: Statement (StreamName, Text) ()
corruptSnapshotShapeStmt =
  preparable
    "UPDATE keiro_snapshots ks \
    \SET regfile_shape_hash = $2 \
    \FROM streams s \
    \WHERE s.stream_id = ks.stream_id \
    \  AND s.stream_name = $1"
    ( ((\(StreamName name, _) -> name) >$< E.param (E.nonNullable E.text))
        <> ((\(_, shapeHash) -> shapeHash) >$< E.param (E.nonNullable E.text))
    )
    D.noResult
