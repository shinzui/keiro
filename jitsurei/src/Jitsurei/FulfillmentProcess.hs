module Jitsurei.FulfillmentProcess (
    FulfillmentCommand (..),
    ObserveFulfillmentEventData (..),
    FulfillmentEvent (..),
    FulfillmentObservedData (..),
    FulfillmentState (..),
    FulfillmentEventStream,
    FulfillmentProcessManager,
    fulfillmentTransducer,
    fulfillmentCodec,
    fulfillmentEventStream,
    fulfillmentProcessManager,
    fulfillmentStream,
    runFulfillmentOnce,
)
where

import Data.Aeson (Value, object, withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import GHC.Generics (Generic)
import Jitsurei.Domain
import Jitsurei.OrderStream
import Jitsurei.ReadModels (orderSummaryInlineProjection)
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, RegFile (..), SymTransducer)
import Keiki.Generics.TH (deriveAggregate)
import Keiro.Codec (Codec (..))
import Keiro.Command (CommandError, RunCommandOptions)
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.ProcessManager (
    PMCommand (..),
    ProcessManager (..),
    ProcessManagerAction (..),
    ProcessManagerResult,
    runProcessManagerOnce,
 )
import Keiro.Stream (Stream)
import Keiro.Stream qualified as Stream
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types (EventType (..), RecordedEvent)

data FulfillmentCommand
    = ObserveFulfillmentEvent !ObserveFulfillmentEventData
    deriving stock (Generic, Eq, Show)

data ObserveFulfillmentEventData = ObserveFulfillmentEventData
    { orderId :: !OrderId
    , status :: !Text
    }
    deriving stock (Generic, Eq, Show)

data FulfillmentEvent
    = FulfillmentObserved !FulfillmentObservedData
    deriving stock (Generic, Eq, Show)

data FulfillmentObservedData = FulfillmentObservedData
    { orderId :: !OrderId
    , status :: !Text
    }
    deriving stock (Generic, Eq, Show)

data FulfillmentState
    = FulfillmentIdle
    deriving stock (Generic, Eq, Show, Enum, Bounded)

type FulfillmentRegs = '[]

type FulfillmentEventStream = EventStream (HsPred FulfillmentRegs FulfillmentCommand) FulfillmentRegs FulfillmentState FulfillmentCommand FulfillmentEvent

type FulfillmentProcessManager =
    ProcessManager
        OrderEvent
        (HsPred FulfillmentRegs FulfillmentCommand)
        FulfillmentRegs
        FulfillmentState
        FulfillmentCommand
        FulfillmentEvent
        (HsPred '[] OrderCommand)
        '[]
        OrderState
        OrderCommand
        OrderEvent

$( deriveAggregate
    ''FulfillmentCommand
    ''FulfillmentRegs
    ''FulfillmentEvent
 )

fulfillmentEventStream :: FulfillmentEventStream
fulfillmentEventStream =
    EventStream
        { transducer = fulfillmentTransducer
        , initialState = FulfillmentIdle
        , initialRegisters = RNil
        , eventCodec = fulfillmentCodec
        , resolveStreamName = Stream.streamName
        , snapshotPolicy = Never
        , stateCodec = Nothing
        }

fulfillmentCategory :: Stream.StreamCategory a
fulfillmentCategory = Stream.categoryUnsafe "fulfillment"

fulfillmentStream :: OrderId -> Stream FulfillmentEventStream
fulfillmentStream = Stream.entityStream fulfillmentCategory . orderIdText

fulfillmentProcessManager :: FulfillmentProcessManager
fulfillmentProcessManager =
    ProcessManager
        { name = "jitsurei-fulfillment"
        , correlate = orderIdText . eventOrderId
        , eventStream = fulfillmentEventStream
        , streamFor = fulfillmentStream . OrderId
        , targetEventStream = orderEventStream
        , targetProjections = const [orderSummaryInlineProjection]
        , handle = \event ->
            let orderId = eventOrderId event
                status = fulfillmentStatus event
             in ProcessManagerAction
                    { command =
                        ObserveFulfillmentEvent
                            ObserveFulfillmentEventData
                                { orderId = orderId
                                , status = status
                                }
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
fulfillmentTransducer =
    B.buildTransducer FulfillmentIdle RNil (const False) do
        B.from FulfillmentIdle do
            B.onCmd inCtorObserveFulfillmentEvent $ \d -> B.do
                B.emit
                    wireFulfillmentObserved
                    FulfillmentObservedTermFields
                        { orderId = d.orderId
                        , status = d.status
                        }
                B.goto FulfillmentIdle

fulfillmentCodec :: Codec FulfillmentEvent
fulfillmentCodec =
    Codec
        { eventTypes = EventType "FulfillmentObserved" :| []
        , eventType = \case
            FulfillmentObserved{} -> EventType "FulfillmentObserved"
        , schemaVersion = 1
        , encode = \case
            FulfillmentObserved payload ->
                object
                    [ "kind" Aeson..= ("FulfillmentObserved" :: Text)
                    , "orderId" Aeson..= orderIdText payload.orderId
                    , "status" Aeson..= payload.status
                    ]
        , decode = parseFulfillmentEvent
        , upcasters = []
        }

parseFulfillmentEvent :: EventType -> Value -> Either Text FulfillmentEvent
parseFulfillmentEvent (EventType tag) value =
    case parseEither parser value of
        Right event -> Right event
        Left message -> Left (Text.pack message)
  where
    parser = withObject "FulfillmentEvent" $ \objectValue -> do
        case tag of
            "FulfillmentObserved" ->
                FulfillmentObserved
                    <$> ( FulfillmentObservedData
                            <$> (OrderId <$> objectValue .: "orderId")
                            <*> objectValue .: "status"
                        )
            _ -> fail "unknown fulfillment event type"
