module Jitsurei.OrderStream (
    OrderEventStream,
    OrderRegs,
    orderEventStream,
    snapshotOrderEventStream,
    orderStream,
    orderCommandStream,
    orderCodec,
    orderTransducer,
    parseOrderEvent,
    upcastOrderPlacedV1,
)
where

import Data.Aeson (Value, object, withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Jitsurei.Domain
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, RegFile (..), SymTransducer)
import Keiki.Generics.TH (deriveAggregate)
import Keiro.Codec (Codec (..))
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.Snapshot (defaultStateCodec)
import Keiro.Stream (Stream)
import Keiro.Stream qualified as Stream
import Kiroku.Store.Types (EventType (..))

type OrderRegs = '[]

type OrderEventStream = EventStream (HsPred OrderRegs OrderCommand) OrderRegs OrderState OrderCommand OrderEvent

$( deriveAggregate
    ''OrderCommand
    ''OrderRegs
    ''OrderEvent
 )

orderEventStream :: OrderEventStream
orderEventStream =
    EventStream
        { transducer = orderTransducer
        , initialState = NotStarted
        , initialRegisters = RNil
        , eventCodec = orderCodec
        , resolveStreamName = Stream.streamName
        , snapshotPolicy = Never
        , stateCodec = Nothing
        }

snapshotOrderEventStream :: OrderEventStream
snapshotOrderEventStream =
    orderEventStream
        { snapshotPolicy = Every 2
        , stateCodec = Just (defaultStateCodec @OrderRegs @OrderState 1)
        }

orderCategory :: Stream.StreamCategory a
orderCategory = Stream.categoryUnsafe "order"

orderStream :: OrderId -> Stream OrderEventStream
orderStream = Stream.entityStream orderCategory . orderIdText

orderCommandStream :: OrderId -> Stream OrderCommand
orderCommandStream = Stream.entityStream orderCategory . orderIdText

orderTransducer :: SymTransducer (HsPred OrderRegs OrderCommand) OrderRegs OrderState OrderCommand OrderEvent
orderTransducer =
    B.buildTransducer NotStarted RNil isTerminal do
        B.from NotStarted do
            B.onCmd inCtorPlaceOrder $ \d -> B.do
                B.emit
                    wireOrderPlaced
                    OrderPlacedTermFields
                        { orderId = d.orderId
                        , sku = d.sku
                        , quantity = d.quantity
                        }
                B.goto Placed

        B.from Placed do
            B.onCmd inCtorApprovePayment $ \d -> B.do
                B.emit
                    wirePaymentApproved
                    PaymentApprovedTermFields
                        { orderId = d.orderId
                        , paymentRef = d.paymentRef
                        }
                B.goto Paid

            B.onCmd inCtorCancelOrder $ \d -> B.do
                B.emit
                    wireOrderCancelled
                    OrderCancelledTermFields
                        { orderId = d.orderId
                        , reason = d.reason
                        }
                B.goto Cancelled

        B.from Paid do
            B.onCmd inCtorMarkPacked $ \d -> B.do
                B.emit
                    wireOrderPacked
                    OrderPackedTermFields
                        { orderId = d.orderId
                        }
                B.goto Packed

        B.from Packed do
            B.onCmd inCtorShipOrder $ \d -> B.do
                B.emit
                    wireOrderShipped
                    OrderShippedTermFields
                        { orderId = d.orderId
                        , carrier = d.carrier
                        , trackingId = d.trackingId
                        }
                B.goto Shipped
  where
    isTerminal = \case
        Shipped -> True
        Cancelled -> True
        _ -> False

orderCodec :: Codec OrderEvent
orderCodec =
    Codec
        { eventTypes = EventType "OrderPlaced" :| [EventType "PaymentApproved", EventType "OrderPacked", EventType "OrderShipped", EventType "OrderCancelled"]
        , eventType = \case
            OrderPlaced{} -> EventType "OrderPlaced"
            PaymentApproved{} -> EventType "PaymentApproved"
            OrderPacked{} -> EventType "OrderPacked"
            OrderShipped{} -> EventType "OrderShipped"
            OrderCancelled{} -> EventType "OrderCancelled"
        , schemaVersion = 2
        , encode = \case
            OrderPlaced payload ->
                object
                    [ "kind" Aeson..= ("OrderPlaced" :: Text)
                    , "orderId" Aeson..= orderIdText payload.orderId
                    , "sku" Aeson..= skuText payload.sku
                    , "quantity" Aeson..= quantityInt payload.quantity
                    ]
            PaymentApproved payload ->
                object
                    [ "kind" Aeson..= ("PaymentApproved" :: Text)
                    , "orderId" Aeson..= orderIdText payload.orderId
                    , "paymentRef" Aeson..= paymentRefText payload.paymentRef
                    ]
            OrderPacked payload ->
                object
                    [ "kind" Aeson..= ("OrderPacked" :: Text)
                    , "orderId" Aeson..= orderIdText payload.orderId
                    ]
            OrderShipped payload ->
                object
                    [ "kind" Aeson..= ("OrderShipped" :: Text)
                    , "orderId" Aeson..= orderIdText payload.orderId
                    , "carrier" Aeson..= carrierText payload.carrier
                    , "trackingId" Aeson..= trackingIdText payload.trackingId
                    ]
            OrderCancelled payload ->
                object
                    [ "kind" Aeson..= ("OrderCancelled" :: Text)
                    , "orderId" Aeson..= orderIdText payload.orderId
                    , "reason" Aeson..= payload.reason
                    ]
        , decode = parseOrderEvent
        , upcasters = [(1, const upcastOrderPlacedV1)]
        }

parseOrderEvent :: EventType -> Value -> Either Text OrderEvent
parseOrderEvent (EventType tag) value =
    case parseEither parser value of
        Right event -> Right event
        Left message -> Left (Text.pack message)
  where
    parser = withObject "OrderEvent" $ \objectValue -> do
        case tag of
            "OrderPlaced" ->
                OrderPlaced
                    <$> ( OrderPlacedData
                            <$> (OrderId <$> objectValue .: "orderId")
                            <*> (Sku <$> objectValue .: "sku")
                            <*> (Quantity <$> objectValue .: "quantity")
                        )
            "PaymentApproved" ->
                PaymentApproved
                    <$> ( PaymentApprovedData
                            <$> (OrderId <$> objectValue .: "orderId")
                            <*> (PaymentRef <$> objectValue .: "paymentRef")
                        )
            "OrderPacked" ->
                OrderPacked
                    <$> (OrderPackedData . OrderId <$> objectValue .: "orderId")
            "OrderShipped" ->
                OrderShipped
                    <$> ( OrderShippedData
                            <$> (OrderId <$> objectValue .: "orderId")
                            <*> (Carrier <$> objectValue .: "carrier")
                            <*> (TrackingId <$> objectValue .: "trackingId")
                        )
            "OrderCancelled" ->
                OrderCancelled
                    <$> ( OrderCancelledData
                            <$> (OrderId <$> objectValue .: "orderId")
                            <*> objectValue .: "reason"
                        )
            _ -> fail "unknown order event type"

upcastOrderPlacedV1 :: Value -> Either Text Value
upcastOrderPlacedV1 value =
    case parseEither parser value of
        Right migrated -> Right migrated
        Left message -> Left (Text.pack message)
  where
    parser = withObject "OrderPlacedV1" $ \objectValue -> do
        orderId <- objectValue .: "orderId"
        sku <- objectValue .:? "sku"
        quantity <- objectValue .: "qty"
        pure
            ( object
                [ "kind" Aeson..= ("OrderPlaced" :: Text)
                , "orderId" Aeson..= (orderId :: Text)
                , "sku" Aeson..= maybe "UNKNOWN" id (sku :: Maybe Text)
                , "quantity" Aeson..= (quantity :: Int)
                ]
            )
