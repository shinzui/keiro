module Jitsurei.Domain
  ( OrderId (..)
  , Sku (..)
  , Quantity (..)
  , PaymentRef (..)
  , Carrier (..)
  , TrackingId (..)
  , OrderCommand (..)
  , OrderEvent (..)
  , OrderState (..)
  , orderIdText
  , skuText
  , quantityInt
  , paymentRefText
  , carrierText
  , trackingIdText
  , commandOrderId
  , eventOrderId
  , stateText
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
  = PlaceOrder !OrderId !Sku !Quantity
  | ApprovePayment !OrderId !PaymentRef
  | MarkPacked !OrderId
  | ShipOrder !OrderId !Carrier !TrackingId
  | CancelOrder !OrderId !Text
  deriving stock (Generic, Eq, Show)

data OrderEvent
  = OrderPlaced !OrderId !Sku !Quantity
  | PaymentApproved !OrderId !PaymentRef
  | OrderPacked !OrderId
  | OrderShipped !OrderId !Carrier !TrackingId
  | OrderCancelled !OrderId !Text
  deriving stock (Generic, Eq, Show)

data OrderState
  = NotStarted
  | Placed
  | Paid
  | Packed
  | Shipped
  | Cancelled
  deriving stock (Generic, Eq, Show)
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
  PlaceOrder orderId _ _ -> orderId
  ApprovePayment orderId _ -> orderId
  MarkPacked orderId -> orderId
  ShipOrder orderId _ _ -> orderId
  CancelOrder orderId _ -> orderId

eventOrderId :: OrderEvent -> OrderId
eventOrderId = \case
  OrderPlaced orderId _ _ -> orderId
  PaymentApproved orderId _ -> orderId
  OrderPacked orderId -> orderId
  OrderShipped orderId _ _ -> orderId
  OrderCancelled orderId _ -> orderId

stateText :: OrderState -> Text
stateText = \case
  NotStarted -> "not-started"
  Placed -> "placed"
  Paid -> "paid"
  Packed -> "packed"
  Shipped -> "shipped"
  Cancelled -> "cancelled"
