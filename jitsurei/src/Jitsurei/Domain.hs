module Jitsurei.Domain (
    OrderId (..),
    Sku (..),
    Quantity (..),
    PaymentRef (..),
    Carrier (..),
    TrackingId (..),
    PlaceOrderData (..),
    ApprovePaymentData (..),
    MarkPackedData (..),
    ShipOrderData (..),
    CancelOrderData (..),
    OrderPlacedData (..),
    PaymentApprovedData (..),
    OrderPackedData (..),
    OrderShippedData (..),
    OrderCancelledData (..),
    OrderCommand (..),
    OrderEvent (..),
    OrderState (..),
    orderIdText,
    skuText,
    quantityInt,
    paymentRefText,
    carrierText,
    trackingIdText,
    commandOrderId,
    eventOrderId,
    stateText,
)
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

newtype OrderId = OrderId Text
    deriving stock (Generic, Eq, Ord, Show)
    deriving newtype (FromJSON, ToJSON)

newtype Sku = Sku Text
    deriving stock (Generic, Eq, Ord, Show)
    deriving newtype (FromJSON, ToJSON)

newtype Quantity = Quantity Int
    deriving stock (Generic, Eq, Ord, Show)
    deriving newtype (FromJSON, ToJSON)

newtype PaymentRef = PaymentRef Text
    deriving stock (Generic, Eq, Ord, Show)
    deriving newtype (FromJSON, ToJSON)

newtype Carrier = Carrier Text
    deriving stock (Generic, Eq, Ord, Show)
    deriving newtype (FromJSON, ToJSON)

newtype TrackingId = TrackingId Text
    deriving stock (Generic, Eq, Ord, Show)
    deriving newtype (FromJSON, ToJSON)

data OrderCommand
    = PlaceOrder !PlaceOrderData
    | ApprovePayment !ApprovePaymentData
    | MarkPacked !MarkPackedData
    | ShipOrder !ShipOrderData
    | CancelOrder !CancelOrderData
    deriving stock (Generic, Eq, Show)

data OrderEvent
    = OrderPlaced !OrderPlacedData
    | PaymentApproved !PaymentApprovedData
    | OrderPacked !OrderPackedData
    | OrderShipped !OrderShippedData
    | OrderCancelled !OrderCancelledData
    deriving stock (Generic, Eq, Show)

data PlaceOrderData = PlaceOrderData
    { orderId :: !OrderId
    , sku :: !Sku
    , quantity :: !Quantity
    }
    deriving stock (Generic, Eq, Show)

data ApprovePaymentData = ApprovePaymentData
    { orderId :: !OrderId
    , paymentRef :: !PaymentRef
    }
    deriving stock (Generic, Eq, Show)

newtype MarkPackedData = MarkPackedData
    { orderId :: OrderId
    }
    deriving stock (Generic, Eq, Show)

data ShipOrderData = ShipOrderData
    { orderId :: !OrderId
    , carrier :: !Carrier
    , trackingId :: !TrackingId
    }
    deriving stock (Generic, Eq, Show)

data CancelOrderData = CancelOrderData
    { orderId :: !OrderId
    , reason :: !Text
    }
    deriving stock (Generic, Eq, Show)

data OrderPlacedData = OrderPlacedData
    { orderId :: !OrderId
    , sku :: !Sku
    , quantity :: !Quantity
    }
    deriving stock (Generic, Eq, Show)

data PaymentApprovedData = PaymentApprovedData
    { orderId :: !OrderId
    , paymentRef :: !PaymentRef
    }
    deriving stock (Generic, Eq, Show)

newtype OrderPackedData = OrderPackedData
    { orderId :: OrderId
    }
    deriving stock (Generic, Eq, Show)

data OrderShippedData = OrderShippedData
    { orderId :: !OrderId
    , carrier :: !Carrier
    , trackingId :: !TrackingId
    }
    deriving stock (Generic, Eq, Show)

data OrderCancelledData = OrderCancelledData
    { orderId :: !OrderId
    , reason :: !Text
    }
    deriving stock (Generic, Eq, Show)

data OrderState
    = NotStarted
    | Placed
    | Paid
    | Packed
    | Shipped
    | Cancelled
    deriving stock (Generic, Eq, Show, Enum, Bounded)
    deriving anyclass (FromJSON, ToJSON)

orderIdText :: OrderId -> Text
orderIdText (OrderId value) = value

skuText :: Sku -> Text
skuText (Sku value) = value

quantityInt :: Quantity -> Int
quantityInt (Quantity value) = value

paymentRefText :: PaymentRef -> Text
paymentRefText (PaymentRef value) = value

carrierText :: Carrier -> Text
carrierText (Carrier value) = value

trackingIdText :: TrackingId -> Text
trackingIdText (TrackingId value) = value

commandOrderId :: OrderCommand -> OrderId
commandOrderId = \case
    PlaceOrder payload -> payload.orderId
    ApprovePayment payload -> payload.orderId
    MarkPacked payload -> payload.orderId
    ShipOrder payload -> payload.orderId
    CancelOrder payload -> payload.orderId

eventOrderId :: OrderEvent -> OrderId
eventOrderId = \case
    OrderPlaced payload -> payload.orderId
    PaymentApproved payload -> payload.orderId
    OrderPacked payload -> payload.orderId
    OrderShipped payload -> payload.orderId
    OrderCancelled payload -> payload.orderId

stateText :: OrderState -> Text
stateText = \case
    NotStarted -> "not-started"
    Placed -> "placed"
    Paid -> "paid"
    Packed -> "packed"
    Shipped -> "shipped"
    Cancelled -> "cancelled"
