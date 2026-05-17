module Jitsurei.OrderStream
  ( OrderEventStream
  , OrderCommandFields
  , orderEventStream
  , snapshotOrderEventStream
  , orderStream
  , orderCommandStream
  , orderCodec
  , orderTransducer
  , parseOrderEvent
  , upcastOrderPlacedV1
  )
where

import Data.Aeson (Value, object, withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Keiki.Core
  ( Edge (..)
  , HsPred
  , InCtor (..)
  , RegFile (..)
  , SymTransducer (..)
  , Update (..)
  , WireCtor (..)
  , inpCtor
  , matchInCtor
  , oNil
  , pack
  , (*:)
  )
import Keiro.Codec (Codec (..))
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.Snapshot (defaultStateCodec)
import Keiro.Stream (Stream, stream)
import Keiro.Stream qualified as Stream
import Jitsurei.Domain

type OrderEventStream = EventStream (HsPred '[] OrderCommand) '[] OrderState OrderCommand OrderEvent

type OrderCommandFields = '[ '("orderId", OrderId)]

type PlaceOrderFields = '[ '("orderId", OrderId), '("sku", Sku), '("quantity", Quantity)]

type ApprovePaymentFields = '[ '("orderId", OrderId), '("paymentRef", PaymentRef)]

type ShipOrderFields = '[ '("orderId", OrderId), '("carrier", Carrier), '("trackingId", TrackingId)]

type CancelOrderFields = '[ '("orderId", OrderId), '("reason", Text)]

orderEventStream :: OrderEventStream
orderEventStream = EventStream
  { transducer = orderTransducer
  , initialState = NotStarted
  , initialRegisters = RNil
  , eventCodec = orderCodec
  , streamName = Stream.streamName
  , snapshotPolicy = Never
  , stateCodec = Nothing
  }

snapshotOrderEventStream :: OrderEventStream
snapshotOrderEventStream =
  orderEventStream
    { snapshotPolicy = Every 2
    , stateCodec = Just (defaultStateCodec @'[] @OrderState 1)
    }

orderStream :: OrderId -> Stream OrderEventStream
orderStream orderId = stream ("order-" <> orderIdText orderId)

orderCommandStream :: OrderId -> Stream OrderCommand
orderCommandStream orderId = stream ("order-" <> orderIdText orderId)

orderTransducer :: SymTransducer (HsPred '[] OrderCommand) '[] OrderState OrderCommand OrderEvent
orderTransducer = SymTransducer
  { edgesOut = \case
      NotStarted ->
        [ Edge
            { guard = matchInCtor placeOrderCtor
            , update = UKeep
            , output =
                [ pack
                    placeOrderCtor
                    orderPlacedCtor
                    ( inpCtor placeOrderCtor #orderId
                        *: inpCtor placeOrderCtor #sku
                        *: inpCtor placeOrderCtor #quantity
                        *: oNil
                    )
                ]
            , target = Placed
            }
        ]
      Placed ->
        [ Edge
            { guard = matchInCtor approvePaymentCtor
            , update = UKeep
            , output =
                [ pack
                    approvePaymentCtor
                    paymentApprovedCtor
                    ( inpCtor approvePaymentCtor #orderId
                        *: inpCtor approvePaymentCtor #paymentRef
                        *: oNil
                    )
                ]
            , target = Paid
            }
        , Edge
            { guard = matchInCtor cancelOrderCtor
            , update = UKeep
            , output =
                [ pack
                    cancelOrderCtor
                    orderCancelledCtor
                    ( inpCtor cancelOrderCtor #orderId
                        *: inpCtor cancelOrderCtor #reason
                        *: oNil
                    )
                ]
            , target = Cancelled
            }
        ]
      Paid ->
        [ Edge
            { guard = matchInCtor markPackedCtor
            , update = UKeep
            , output =
                [ pack
                    markPackedCtor
                    orderPackedCtor
                    (inpCtor markPackedCtor #orderId *: oNil)
                ]
            , target = Packed
            }
        ]
      Packed ->
        [ Edge
            { guard = matchInCtor shipOrderCtor
            , update = UKeep
            , output =
                [ pack
                    shipOrderCtor
                    orderShippedCtor
                    ( inpCtor shipOrderCtor #orderId
                        *: inpCtor shipOrderCtor #carrier
                        *: inpCtor shipOrderCtor #trackingId
                        *: oNil
                    )
                ]
            , target = Shipped
            }
        ]
      Shipped -> []
      Cancelled -> []
  , initial = NotStarted
  , initialRegs = RNil
  , isFinal = \case
      Shipped -> True
      Cancelled -> True
      _ -> False
  }

placeOrderCtor :: InCtor OrderCommand PlaceOrderFields
placeOrderCtor = InCtor
  { icName = "PlaceOrder"
  , icMatch = \case
      PlaceOrder orderId sku quantity -> Just (RCons (Proxy @"orderId") orderId (RCons (Proxy @"sku") sku (RCons (Proxy @"quantity") quantity RNil)))
      _ -> Nothing
  , icBuild = \case
      RCons _ orderId (RCons _ sku (RCons _ quantity RNil)) -> PlaceOrder orderId sku quantity
  }

approvePaymentCtor :: InCtor OrderCommand ApprovePaymentFields
approvePaymentCtor = InCtor
  { icName = "ApprovePayment"
  , icMatch = \case
      ApprovePayment orderId paymentRef -> Just (RCons (Proxy @"orderId") orderId (RCons (Proxy @"paymentRef") paymentRef RNil))
      _ -> Nothing
  , icBuild = \case
      RCons _ orderId (RCons _ paymentRef RNil) -> ApprovePayment orderId paymentRef
  }

markPackedCtor :: InCtor OrderCommand OrderCommandFields
markPackedCtor = InCtor
  { icName = "MarkPacked"
  , icMatch = \case
      MarkPacked orderId -> Just (RCons (Proxy @"orderId") orderId RNil)
      _ -> Nothing
  , icBuild = \case
      RCons _ orderId RNil -> MarkPacked orderId
  }

shipOrderCtor :: InCtor OrderCommand ShipOrderFields
shipOrderCtor = InCtor
  { icName = "ShipOrder"
  , icMatch = \case
      ShipOrder orderId carrier trackingId -> Just (RCons (Proxy @"orderId") orderId (RCons (Proxy @"carrier") carrier (RCons (Proxy @"trackingId") trackingId RNil)))
      _ -> Nothing
  , icBuild = \case
      RCons _ orderId (RCons _ carrier (RCons _ trackingId RNil)) -> ShipOrder orderId carrier trackingId
  }

cancelOrderCtor :: InCtor OrderCommand CancelOrderFields
cancelOrderCtor = InCtor
  { icName = "CancelOrder"
  , icMatch = \case
      CancelOrder orderId reason -> Just (RCons (Proxy @"orderId") orderId (RCons (Proxy @"reason") reason RNil))
      _ -> Nothing
  , icBuild = \case
      RCons _ orderId (RCons _ reason RNil) -> CancelOrder orderId reason
  }

orderPlacedCtor :: WireCtor OrderEvent (OrderId, (Sku, (Quantity, ())))
orderPlacedCtor = WireCtor
  { wcName = "OrderPlaced"
  , wcMatch = \case
      OrderPlaced orderId sku quantity -> Just (orderId, (sku, (quantity, ())))
      _ -> Nothing
  , wcBuild = \(orderId, (sku, (quantity, ()))) -> OrderPlaced orderId sku quantity
  }

paymentApprovedCtor :: WireCtor OrderEvent (OrderId, (PaymentRef, ()))
paymentApprovedCtor = WireCtor
  { wcName = "PaymentApproved"
  , wcMatch = \case
      PaymentApproved orderId paymentRef -> Just (orderId, (paymentRef, ()))
      _ -> Nothing
  , wcBuild = \(orderId, (paymentRef, ())) -> PaymentApproved orderId paymentRef
  }

orderPackedCtor :: WireCtor OrderEvent (OrderId, ())
orderPackedCtor = WireCtor
  { wcName = "OrderPacked"
  , wcMatch = \case
      OrderPacked orderId -> Just (orderId, ())
      _ -> Nothing
  , wcBuild = \(orderId, ()) -> OrderPacked orderId
  }

orderShippedCtor :: WireCtor OrderEvent (OrderId, (Carrier, (TrackingId, ())))
orderShippedCtor = WireCtor
  { wcName = "OrderShipped"
  , wcMatch = \case
      OrderShipped orderId carrier trackingId -> Just (orderId, (carrier, (trackingId, ())))
      _ -> Nothing
  , wcBuild = \(orderId, (carrier, (trackingId, ()))) -> OrderShipped orderId carrier trackingId
  }

orderCancelledCtor :: WireCtor OrderEvent (OrderId, (Text, ()))
orderCancelledCtor = WireCtor
  { wcName = "OrderCancelled"
  , wcMatch = \case
      OrderCancelled orderId reason -> Just (orderId, (reason, ()))
      _ -> Nothing
  , wcBuild = \(orderId, (reason, ())) -> OrderCancelled orderId reason
  }

orderCodec :: Codec OrderEvent
orderCodec = Codec
  { eventTypes = "OrderPlaced" :| ["PaymentApproved", "OrderPacked", "OrderShipped", "OrderCancelled"]
  , eventType = \case
      OrderPlaced{} -> "OrderPlaced"
      PaymentApproved{} -> "PaymentApproved"
      OrderPacked{} -> "OrderPacked"
      OrderShipped{} -> "OrderShipped"
      OrderCancelled{} -> "OrderCancelled"
  , schemaVersion = 2
  , encode = \case
      OrderPlaced orderId sku quantity ->
        object
          [ "kind" Aeson..= ("OrderPlaced" :: Text)
          , "orderId" Aeson..= orderIdText orderId
          , "sku" Aeson..= skuText sku
          , "quantity" Aeson..= quantityInt quantity
          ]
      PaymentApproved orderId paymentRef ->
        object
          [ "kind" Aeson..= ("PaymentApproved" :: Text)
          , "orderId" Aeson..= orderIdText orderId
          , "paymentRef" Aeson..= paymentRefText paymentRef
          ]
      OrderPacked orderId ->
        object
          [ "kind" Aeson..= ("OrderPacked" :: Text)
          , "orderId" Aeson..= orderIdText orderId
          ]
      OrderShipped orderId carrier trackingId ->
        object
          [ "kind" Aeson..= ("OrderShipped" :: Text)
          , "orderId" Aeson..= orderIdText orderId
          , "carrier" Aeson..= carrierText carrier
          , "trackingId" Aeson..= trackingIdText trackingId
          ]
      OrderCancelled orderId reason ->
        object
          [ "kind" Aeson..= ("OrderCancelled" :: Text)
          , "orderId" Aeson..= orderIdText orderId
          , "reason" Aeson..= reason
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
            <$> (OrderId <$> objectValue .: "orderId")
            <*> (Sku <$> objectValue .: "sku")
            <*> (Quantity <$> objectValue .: "quantity")
        Just "PaymentApproved" ->
          PaymentApproved
            <$> (OrderId <$> objectValue .: "orderId")
            <*> (PaymentRef <$> objectValue .: "paymentRef")
        Just "OrderPacked" ->
          OrderPacked
            <$> (OrderId <$> objectValue .: "orderId")
        Just "OrderShipped" ->
          OrderShipped
            <$> (OrderId <$> objectValue .: "orderId")
            <*> (Carrier <$> objectValue .: "carrier")
            <*> (TrackingId <$> objectValue .: "trackingId")
        Just "OrderCancelled" ->
          OrderCancelled
            <$> (OrderId <$> objectValue .: "orderId")
            <*> objectValue .: "reason"
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
