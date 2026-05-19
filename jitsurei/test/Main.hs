module Main
  ( main
  )
where

import Control.Lens ((^.))
import Data.Aeson (object)
import Data.Aeson qualified as Aeson
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Vector qualified as Vector
import Data.Time (UTCTime (..), secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import "hasql-transaction" Hasql.Transaction qualified as Tx
import Keiro
import Keiro.Projection
import Keiro.ProcessManager
import Keiro.ReadModel
import Keiro.Timer
import Kiroku.Store qualified as Store
import Kiroku.Store.Types
  ( StreamName (..)
  , StreamVersion (..)
  )
import EphemeralPg qualified as Pg
import Test.Hspec
import Jitsurei

main :: IO ()
main = hspec $ do
  describe "Jitsurei codec evolution" $ do
    it "upcasts a v1 OrderPlaced payload into the current event shape" $
      decodeRaw
        orderCodec
        1
        ( object
            [ "orderId" Aeson..= ("order-100" :: Text)
            , "qty" Aeson..= (3 :: Int)
            ]
        )
        `shouldBe` Right
          ( OrderPlaced
              OrderPlacedData
                { orderId = sampleOrderId
                , sku = Sku "UNKNOWN"
                , quantity = Quantity 3
                }
          )

  describe "Jitsurei command cycle" $ around withTestStore $ do
    it "places and pays for an order in stream order" $ \store -> do
      let target = orderStream sampleOrderId
      Right (Right placed) <- Store.runStoreIO store $
        runCommand defaultRunCommandOptions orderEventStream target samplePlaceOrder
      placed ^. #streamVersion `shouldBe` StreamVersion 1
      Right (Right paid) <- Store.runStoreIO store $
        runCommand defaultRunCommandOptions orderEventStream target sampleApprovePayment
      paid ^. #streamVersion `shouldBe` StreamVersion 2
      Right recorded <- Store.runStoreIO store $
        Store.readStreamForward (StreamName "order-order-100") (StreamVersion 0) 10
      traverse (decodeRecorded orderCodec) (Vector.toList recorded)
        `shouldBe` Right
          [ OrderPlaced OrderPlacedData
              { orderId = sampleOrderId
              , sku = sampleSku
              , quantity = sampleQuantity
              }
          , PaymentApproved PaymentApprovedData
              { orderId = sampleOrderId
              , paymentRef = samplePaymentRef
              }
          ]

    it "rejects shipping an unpaid order as a domain outcome" $ \store -> do
      result <- Store.runStoreIO store $
        runCommand
          defaultRunCommandOptions
          orderEventStream
          (orderStream (OrderId "order-unpaid"))
          ( ShipOrder
              ShipOrderData
                { orderId = OrderId "order-unpaid"
                , carrier = Carrier "UPS"
                , trackingId = TrackingId "TRACK-1"
                }
          )
      result `shouldBe` Right (Left CommandRejected)

  describe "Jitsurei read model" $ around withTestStore $ do
    it "updates and queries the inline order summary in the append transaction" $ \store -> do
      Right () <- Store.runStoreIO store initializeJitsureiTables
      Right (Right _) <- Store.runStoreIO store $
        runCommandWithProjections
          defaultRunCommandOptions
          orderEventStream
          (orderStream sampleOrderId)
          samplePlaceOrder
          [orderSummaryInlineProjection]
      Right summaryResult <- Store.runStoreIO store $
        runQuery orderSummaryReadModel (OrderSummaryQuery sampleOrderId)
      case summaryResult of
        Right (Just summary) -> do
          summary ^. #orderId `shouldBe` sampleOrderId
          summary ^. #sku `shouldBe` sampleSku
          summary ^. #quantity `shouldBe` sampleQuantity
          summary ^. #status `shouldBe` "placed"
        other -> expectationFailure ("expected live order summary, got " <> show other)

  describe "Jitsurei snapshots" $ around withTestStore $ do
    it "writes a snapshot after the configured threshold" $ \store -> do
      Right () <- Store.runStoreIO store initializeSnapshotSchema
      let target = orderStream (OrderId "snapshot-100")
      Right (Right _) <- Store.runStoreIO store $
        runCommand defaultRunCommandOptions snapshotOrderEventStream target
          ( PlaceOrder
              PlaceOrderData
                { orderId = OrderId "snapshot-100"
                , sku = sampleSku
                , quantity = sampleQuantity
                }
          )
      Right (Right _) <- Store.runStoreIO store $
        runCommand defaultRunCommandOptions snapshotOrderEventStream target
          ( ApprovePayment
              ApprovePaymentData
                { orderId = OrderId "snapshot-100"
                , paymentRef = samplePaymentRef
                }
          )
      Right snapshotVersion <- Store.runStoreIO store $
        Store.runTransaction $
          Tx.statement "order-snapshot-100" snapshotVersionForStreamStmt
      snapshotVersion `shouldBe` Just (StreamVersion 2)

  describe "Jitsurei process manager" $ around withTestStore $ do
    it "dispatches a packing command once for a payment event" $ \store -> do
      let target = orderStream sampleOrderId
      Right (Right _) <- Store.runStoreIO store $
        runCommand defaultRunCommandOptions orderEventStream target samplePlaceOrder
      Right (Right _) <- Store.runStoreIO store $
        runCommand defaultRunCommandOptions orderEventStream target sampleApprovePayment
      Right recorded <- Store.runStoreIO store $
        Store.readStreamForward (StreamName "order-order-100") (StreamVersion 0) 10
      let paymentRecorded = Vector.toList recorded !! 1
      first <- Store.runStoreIO store $
        runFulfillmentOnce defaultRunCommandOptions paymentRecorded
          (PaymentApproved PaymentApprovedData{orderId = sampleOrderId, paymentRef = samplePaymentRef})
      first `shouldSatisfy` \case
        Right (Right result) ->
          case result ^. #commandResults of
            [PMCommandAppended{}] -> True
            _ -> False
        _ -> False
      second <- Store.runStoreIO store $
        runFulfillmentOnce defaultRunCommandOptions paymentRecorded
          (PaymentApproved PaymentApprovedData{orderId = sampleOrderId, paymentRef = samplePaymentRef})
      second `shouldSatisfy` \case
        Right (Right result) ->
          case (result ^. #managerResult, result ^. #commandResults) of
            (PMStateDuplicate{}, [PMCommandDuplicate{}]) -> True
            _ -> False
        _ -> False

  describe "Jitsurei timers" $ around withTestStore $ do
    it "claims a due timer and marks it fired" $ \store -> do
      Right () <- Store.runStoreIO store initializeTimerSchema
      Right () <- Store.runStoreIO store $
        Store.runTransaction $
          scheduleTimerTx (paymentTimeoutRequest sampleOrderId dueTime)
      Right claimed <- Store.runStoreIO store $
        runPaymentTimeoutWorker dueTime
      claimed `shouldSatisfy` isJust

sampleOrderId :: OrderId
sampleOrderId = OrderId "order-100"

sampleSku :: Sku
sampleSku = Sku "SKU-RED-MUG"

sampleQuantity :: Quantity
sampleQuantity = Quantity 3

samplePaymentRef :: PaymentRef
samplePaymentRef = PaymentRef "pay_123"

samplePlaceOrder :: OrderCommand
samplePlaceOrder = PlaceOrder PlaceOrderData
  { orderId = sampleOrderId
  , sku = sampleSku
  , quantity = sampleQuantity
  }

sampleApprovePayment :: OrderCommand
sampleApprovePayment = ApprovePayment ApprovePaymentData
  { orderId = sampleOrderId
  , paymentRef = samplePaymentRef
  }

dueTime :: UTCTime
dueTime = UTCTime (ModifiedJulianDay 1) (secondsToDiffTime 0)

withTestStore :: (Store.KirokuStore -> IO ()) -> IO ()
withTestStore action = do
  result <- Pg.withCached $ \db ->
    Store.withStore (Store.defaultConnectionSettings (Pg.connectionString db)) action
  case result of
    Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
    Right () -> pure ()

snapshotVersionForStreamStmt :: Statement Text (Maybe StreamVersion)
snapshotVersionForStreamStmt =
  preparable
    """
    SELECT ks.stream_version
    FROM keiro_snapshots ks
    JOIN streams s ON s.stream_id = ks.stream_id
    WHERE s.stream_name = $1
    """
    (E.param (E.nonNullable E.text))
    (D.rowMaybe (StreamVersion <$> D.column (D.nonNullable D.int8)))
