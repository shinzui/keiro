module Main
  ( main
  )
where

import Data.Aeson (object, withObject, (.:))
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (parseEither)
import qualified Data.Text as Text
import Data.UUID (UUID, fromString)
import Data.Time (UTCTime (..), secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Keiki.Core (RegFile (..), SymTransducer (..))
import Keiro
import Keiro.Prelude
import qualified Keiro.Stream as Stream
import Kiroku.Store.Types
  ( EventId (..)
  , EventData (..)
  , EventType (..)
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

shouldBeRight :: (HasCallStack, Show e) => Either e a -> IO a
shouldBeRight = \case
  Right value -> pure value
  Left err -> expectationFailure ("expected Right, got Left " <> show err) *> error "unreachable"

fromStringLiteral :: String -> Text
fromStringLiteral = Text.pack
