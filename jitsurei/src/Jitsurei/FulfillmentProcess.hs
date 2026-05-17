module Jitsurei.FulfillmentProcess
  ( FulfillmentCommand (..)
  , FulfillmentEvent (..)
  , FulfillmentState (..)
  , FulfillmentEventStream
  , FulfillmentProcessManager
  , fulfillmentEventStream
  , fulfillmentProcessManager
  , fulfillmentStream
  , runFulfillmentOnce
  )
where

import Data.Aeson (Value, object, withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import GHC.Generics (Generic)
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
import Keiro.Command (CommandError, RunCommandOptions)
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.ProcessManager
  ( PMCommand (..)
  , ProcessManager (..)
  , ProcessManagerAction (..)
  , ProcessManagerResult
  , runProcessManagerOnce
  )
import Keiro.Stream (Stream, stream)
import Keiro.Stream qualified as Stream
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types (RecordedEvent)
import Jitsurei.Domain
import Jitsurei.OrderStream

data FulfillmentCommand
  = ObserveFulfillmentEvent !OrderId !Text
  deriving stock (Generic, Eq, Show)

data FulfillmentEvent
  = FulfillmentObserved !OrderId !Text
  deriving stock (Generic, Eq, Show)

data FulfillmentState
  = FulfillmentIdle
  deriving stock (Generic, Eq, Show)

type FulfillmentEventStream = EventStream (HsPred '[] FulfillmentCommand) '[] FulfillmentState FulfillmentCommand FulfillmentEvent

type FulfillmentProcessManager =
  ProcessManager
    OrderEvent
    (HsPred '[] FulfillmentCommand)
    '[]
    FulfillmentState
    FulfillmentCommand
    FulfillmentEvent
    (HsPred '[] OrderCommand)
    '[]
    OrderState
    OrderCommand
    OrderEvent

type ObserveFields = '[ '("orderId", OrderId), '("status", Text)]

fulfillmentEventStream :: FulfillmentEventStream
fulfillmentEventStream = EventStream
  { transducer = fulfillmentTransducer
  , initialState = FulfillmentIdle
  , initialRegisters = RNil
  , eventCodec = fulfillmentCodec
  , streamName = Stream.streamName
  , snapshotPolicy = Never
  , stateCodec = Nothing
  }

fulfillmentStream :: OrderId -> Stream FulfillmentEventStream
fulfillmentStream orderId = stream ("fulfillment-" <> orderIdText orderId)

fulfillmentProcessManager :: FulfillmentProcessManager
fulfillmentProcessManager = ProcessManager
  { name = "jitsurei-fulfillment"
  , correlate = orderIdText . eventOrderId
  , eventStream = fulfillmentEventStream
  , streamFor = fulfillmentStream . OrderId
  , targetEventStream = orderEventStream
  , handle = \event ->
      let orderId = eventOrderId event
          status = fulfillmentStatus event
       in ProcessManagerAction
            { command = ObserveFulfillmentEvent orderId status
            , commands =
                case event of
                  PaymentApproved{} ->
                    [ PMCommand
                        { target = orderCommandStream orderId
                        , command = MarkPacked (MarkPackedData orderId)
                        }
                    ]
                  _ -> []
            , timers = []
            }
  }

runFulfillmentOnce ::
  ( IOE :> es
  , Store :> es
  , Error StoreError :> es
  ) =>
  RunCommandOptions ->
  RecordedEvent ->
  OrderEvent ->
  Eff es (Either CommandError (ProcessManagerResult FulfillmentEventStream OrderEventStream))
runFulfillmentOnce options recorded event =
  runProcessManagerOnce options fulfillmentProcessManager recorded event

fulfillmentStatus :: OrderEvent -> Text
fulfillmentStatus = \case
  OrderPlaced{} -> "placed"
  PaymentApproved{} -> "payment-approved"
  OrderPacked{} -> "packed"
  OrderShipped{} -> "shipped"
  OrderCancelled{} -> "cancelled"

fulfillmentTransducer :: SymTransducer (HsPred '[] FulfillmentCommand) '[] FulfillmentState FulfillmentCommand FulfillmentEvent
fulfillmentTransducer = SymTransducer
  { edgesOut = \case
      FulfillmentIdle ->
        [ Edge
            { guard = matchInCtor observeCtor
            , update = UKeep
            , output =
                [ pack
                    observeCtor
                    fulfillmentObservedCtor
                    ( inpCtor observeCtor #orderId
                        *: inpCtor observeCtor #status
                        *: oNil
                    )
                ]
            , target = FulfillmentIdle
            }
        ]
  , initial = FulfillmentIdle
  , initialRegs = RNil
  , isFinal = \_ -> False
  }

observeCtor :: InCtor FulfillmentCommand ObserveFields
observeCtor = InCtor
  { icName = "ObserveFulfillmentEvent"
  , icMatch = \case
      ObserveFulfillmentEvent orderId status -> Just (RCons (Proxy @"orderId") orderId (RCons (Proxy @"status") status RNil))
  , icBuild = \case
      RCons _ orderId (RCons _ status RNil) -> ObserveFulfillmentEvent orderId status
  }

fulfillmentObservedCtor :: WireCtor FulfillmentEvent (OrderId, (Text, ()))
fulfillmentObservedCtor = WireCtor
  { wcName = "FulfillmentObserved"
  , wcMatch = \case
      FulfillmentObserved orderId status -> Just (orderId, (status, ()))
  , wcBuild = \(orderId, (status, ())) -> FulfillmentObserved orderId status
  }

fulfillmentCodec :: Codec FulfillmentEvent
fulfillmentCodec = Codec
  { eventTypes = "FulfillmentObserved" :| []
  , eventType = \case
      FulfillmentObserved{} -> "FulfillmentObserved"
  , schemaVersion = 1
  , encode = \case
      FulfillmentObserved orderId status ->
        object
          [ "kind" Aeson..= ("FulfillmentObserved" :: Text)
          , "orderId" Aeson..= orderIdText orderId
          , "status" Aeson..= status
          ]
  , decode = parseFulfillmentEvent
  , upcasters = []
  }

parseFulfillmentEvent :: Value -> Either Text FulfillmentEvent
parseFulfillmentEvent value =
  case parseEither parser value of
    Right event -> Right event
    Left message -> Left (Text.pack message)
  where
    parser = withObject "FulfillmentEvent" $ \objectValue -> do
      kind <- objectValue .: "kind"
      case kind :: Text of
        "FulfillmentObserved" ->
          FulfillmentObserved
            <$> (OrderId <$> objectValue .: "orderId")
            <*> objectValue .: "status"
        _ -> fail "unknown fulfillment event kind"
