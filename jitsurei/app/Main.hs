module Main
  ( main
  )
where

import Data.Foldable (traverse_)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Vector qualified as Vector
import Jitsurei
import Keiro
import Keiro.ProcessManager (runProcessManagerWorker)
import Kiroku.Store qualified as Store
import Kiroku.Store.Types (RecordedEvent, StreamName (..), StreamVersion (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Streamly.Data.Stream qualified as Streamly
import System.Environment (lookupEnv)

main :: IO ()
main = do
  connString <- getConnectionString
  orderId <- freshOrderId
  putStrLn ("[jitsurei] connecting to " <> Text.unpack connString)
  putStrLn ("[jitsurei] running order fulfillment demo for " <> Text.unpack (orderIdText orderId))
  Store.withStore (Store.defaultConnectionSettings connString) $ \store -> do
    putStrLn "[jitsurei] appending PlaceOrder"
    placed <- requireEither =<< requireEither =<< Store.runStoreIO store
      ( runCommand
          defaultRunCommandOptions
          orderEventStream
          (orderStream orderId)
          ( PlaceOrder
              PlaceOrderData
                { orderId = orderId
                , sku = Sku "SKU-RED-MUG"
                , quantity = Quantity 3
                }
          )
      )
    print placed

    putStrLn "[jitsurei] appending ApprovePayment"
    paid <- requireEither =<< requireEither =<< Store.runStoreIO store
      ( runCommand
          defaultRunCommandOptions
          orderEventStream
          (orderStream orderId)
          ( ApprovePayment
              ApprovePaymentData
                { orderId = orderId
                , paymentRef = PaymentRef "pay_demo"
                }
          )
      )
    print paid

    orderEventsBefore <- readOrderEvents store orderId
    putStrLn "[jitsurei] order stream after payment"
    printDecoded orderCodec orderEventsBefore

    paymentRecorded <- requirePaymentEvent orderEventsBefore
    let paymentApproved =
          PaymentApproved
            PaymentApprovedData
              { orderId = orderId
              , paymentRef = PaymentRef "pay_demo"
              }
    putStrLn "[jitsurei] running fulfillment process-manager worker for PaymentApproved"
    requireEither =<< Store.runStoreIO store
      ( runProcessManagerWorker
          defaultRunCommandOptions
          fulfillmentProcessManager
          (processManagerAdapter paymentRecorded paymentApproved)
          Just
      )
    putStrLn "[jitsurei] fulfillment process-manager worker drained one adapter message"

    orderEventsAfter <- readOrderEvents store orderId
    putStrLn "[jitsurei] order stream after process manager dispatch"
    printDecoded orderCodec orderEventsAfter

    fulfillmentEvents <- readFulfillmentEvents store orderId
    putStrLn "[jitsurei] fulfillment process-manager stream"
    printDecoded fulfillmentCodec fulfillmentEvents

getConnectionString :: IO Text
getConnectionString = do
  configured <- lookupEnv "PG_CONNECTION_STRING"
  case configured of
    Just value -> pure (Text.pack value)
    Nothing -> pure "host=db dbname=jitsurei"

freshOrderId :: IO OrderId
freshOrderId = do
  now <- getCurrentTime
  pure (OrderId (Text.pack ("demo-" <> formatTime defaultTimeLocale "%Y%m%d%H%M%S%q" now)))

processManagerAdapter :: RecordedEvent -> OrderEvent -> Adapter es (RecordedEvent, OrderEvent)
processManagerAdapter recorded event =
  Adapter
    { adapterName = "jitsurei-fulfillment-demo"
    , source =
        Streamly.fromList
          [ Ingested
              { envelope =
                  Envelope
                    { messageId = MessageId "jitsurei-payment-approved"
                    , cursor = Nothing
                    , partition = Nothing
                    , enqueuedAt = Nothing
                    , traceContext = Nothing
                    , attempt = Nothing
                    , attributes = mempty
                    , payload = (recorded, event)
                    }
              , ack = AckHandle (\_ -> pure ())
              , lease = Nothing
              }
          ]
    , shutdown = pure ()
    }

readOrderEvents :: Store.KirokuStore -> OrderId -> IO [RecordedEvent]
readOrderEvents store orderId = do
  events <- requireEither =<< Store.runStoreIO store
    (Store.readStreamForward (StreamName ("order-" <> orderIdText orderId)) (StreamVersion 0) 100)
  pure (Vector.toList events)

readFulfillmentEvents :: Store.KirokuStore -> OrderId -> IO [RecordedEvent]
readFulfillmentEvents store orderId = do
  events <- requireEither =<< Store.runStoreIO store
    (Store.readStreamForward (StreamName ("fulfillment-" <> orderIdText orderId)) (StreamVersion 0) 100)
  pure (Vector.toList events)

requirePaymentEvent :: [RecordedEvent] -> IO RecordedEvent
requirePaymentEvent events =
  case filter isPaymentApproved events of
    payment : _ -> pure payment
    [] -> fail "PaymentApproved was not found in the order stream"
 where
  isPaymentApproved recorded =
    case decodeRecorded orderCodec recorded of
      Right PaymentApproved{} -> True
      _ -> False

printDecoded :: (Show event) => Codec event -> [RecordedEvent] -> IO ()
printDecoded codec events =
  traverse_ printOne events
 where
  printOne recorded =
    case decodeRecorded codec recorded of
      Left err -> putStrLn ("  decode failed: " <> show err)
      Right event ->
        putStrLn
          ( "  "
              <> show recorded.streamVersion
              <> " "
              <> show recorded.globalPosition
              <> " "
              <> show event
          )

requireEither :: (Show err) => Either err a -> IO a
requireEither = \case
  Left err -> fail (show err)
  Right value -> pure value
