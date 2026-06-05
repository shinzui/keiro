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
import Keiro.Stream (Stream, stream)
import Keiro.Stream qualified as Stream

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

orderStream :: OrderId -> Stream OrderEventStream
orderStream orderId = stream ("order-" <> orderIdText orderId)

orderCommandStream :: OrderId -> Stream OrderCommand
orderCommandStream orderId = stream ("order-" <> orderIdText orderId)

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
        { eventTypes = "OrderPlaced" :| ["PaymentApproved", "OrderPacked", "OrderShipped", "OrderCancelled"]
        , eventType = \case
            OrderPlaced{} -> "OrderPlaced"
            PaymentApproved{} -> "PaymentApproved"
            OrderPacked{} -> "OrderPacked"
            OrderShipped{} -> "OrderShipped"
            OrderCancelled{} -> "OrderCancelled"
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
        , upcasters = [(1, upcastOrderPlacedV1)]
        }

parseOrderEvent :: Value -> Either Text OrderEvent
parseOrderEvent value =
    case parseEither parser value of
        Right event -> Right event
        Left message -> Left (Text.pack message)
  where
    parser = withObject "OrderEvent" $ \objectValue -> do
        kind <- objectValue .:? "kind"
        case kind :: Maybe Text of
            Just "OrderPlaced" ->
                OrderPlaced
                    <$> ( OrderPlacedData
                            <$> (OrderId <$> objectValue .: "orderId")
                            <*> (Sku <$> objectValue .: "sku")
                            <*> (Quantity <$> objectValue .: "quantity")
                        )
            Just "PaymentApproved" ->
                PaymentApproved
                    <$> ( PaymentApprovedData
                            <$> (OrderId <$> objectValue .: "orderId")
                            <*> (PaymentRef <$> objectValue .: "paymentRef")
                        )
            Just "OrderPacked" ->
                OrderPacked
                    <$> (OrderPackedData . OrderId <$> objectValue .: "orderId")
            Just "OrderShipped" ->
                OrderShipped
                    <$> ( OrderShippedData
                            <$> (OrderId <$> objectValue .: "orderId")
                            <*> (Carrier <$> objectValue .: "carrier")
                            <*> (TrackingId <$> objectValue .: "trackingId")
                        )
            Just "OrderCancelled" ->
                OrderCancelled
                    <$> ( OrderCancelledData
                            <$> (OrderId <$> objectValue .: "orderId")
                            <*> objectValue .: "reason"
                        )
            _ -> fail "unknown order event kind"

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
