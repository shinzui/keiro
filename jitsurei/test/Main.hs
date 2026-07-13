module Main (
    main,
)
where

import Control.Lens ((^.))
import Data.Aeson (object)
import Data.Aeson qualified as Aeson
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Time (UTCTime (..), addUTCTime, secondsToDiffTime)
import Data.Time.Calendar (Day (ModifiedJulianDay))
import Data.UUID (UUID, fromString)
import Data.Vector qualified as Vector
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Jitsurei
import Keiro
import Keiro.Connection (withProjectionSchema)
import Keiro.ProcessManager
import Keiro.Projection
import Keiro.ReadModel
import Keiro.Test.Postgres (StoreRunner (..), withFreshResourceStore, withFreshResourceStoreWith, withMigratedSuite)
import Keiro.Timer
import Kiroku.Store qualified as Store
import Kiroku.Store.Types (
    EventId (..),
    GlobalPosition (..),
    RecordedEvent (..),
    StreamId (..),
    StreamName (..),
    StreamVersion (..),
 )
import Test.Hspec
import "hasql-transaction" Hasql.Transaction qualified as Tx

main :: IO ()
main = withMigratedSuite $ \fixture -> hspec $ do
    describe "Jitsurei codec evolution" $ do
        it "upcasts a v1 OrderPlaced payload into the current event shape" $
            decodeRaw
                orderCodec
                (EventType "OrderPlaced")
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

    describe "Jitsurei command cycle" $ around (withFreshResourceStore fixture) $ do
        it "places and pays for an order in stream order" $ \(_store, StoreRunner runner) -> do
            let target = orderStream sampleOrderId
            Right (Right placed) <-
                runner $
                    runCommand defaultRunCommandOptions orderEventStream target samplePlaceOrder
            placed ^. #streamVersion `shouldBe` StreamVersion 1
            Right (Right paid) <-
                runner $
                    runCommand defaultRunCommandOptions orderEventStream target sampleApprovePayment
            paid ^. #streamVersion `shouldBe` StreamVersion 2
            Right recorded <-
                runner $
                    Store.readStreamForward (StreamName "order-order-100") (StreamVersion 0) 10
            traverse (decodeRecorded orderCodec) (Vector.toList recorded)
                `shouldBe` Right
                    [ OrderPlaced
                        OrderPlacedData
                            { orderId = sampleOrderId
                            , sku = sampleSku
                            , quantity = sampleQuantity
                            }
                    , PaymentApproved
                        PaymentApprovedData
                            { orderId = sampleOrderId
                            , paymentRef = samplePaymentRef
                            }
                    ]

        it "rejects shipping an unpaid order as a domain outcome" $ \(_store, StoreRunner runner) -> do
            result <-
                runner $
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

    describe "Jitsurei read model" $ around (withFreshResourceStoreWith fixture (withProjectionSchema jitsureiProjectionSchema)) $ do
        it "updates and queries the inline order summary in the append transaction" $ \(_store, StoreRunner runner) -> do
            Right () <- runner initializeJitsureiTables
            Right (Right _) <-
                runner $
                    runCommandWithProjections
                        defaultRunCommandOptions
                        orderEventStream
                        (orderStream sampleOrderId)
                        samplePlaceOrder
                        [orderSummaryInlineProjection]
            Right summaryResult <-
                runner $
                    runQuery Nothing orderSummaryReadModel (OrderSummaryQuery sampleOrderId)
            case summaryResult of
                Right (Just summary) -> do
                    summary ^. #orderId `shouldBe` sampleOrderId
                    summary ^. #sku `shouldBe` sampleSku
                    summary ^. #quantity `shouldBe` sampleQuantity
                    summary ^. #status `shouldBe` "placed"
                other -> expectationFailure ("expected live order summary, got " <> show other)

    describe "Jitsurei snapshots" $ around (withFreshResourceStore fixture) $ do
        it "writes a snapshot after the configured threshold" $ \(_store, StoreRunner runner) -> do
            let target = orderStream (OrderId "snapshot-100")
            Right (Right _) <-
                runner $
                    runCommand
                        defaultRunCommandOptions
                        snapshotOrderEventStream
                        target
                        ( PlaceOrder
                            PlaceOrderData
                                { orderId = OrderId "snapshot-100"
                                , sku = sampleSku
                                , quantity = sampleQuantity
                                }
                        )
            Right (Right _) <-
                runner $
                    runCommand
                        defaultRunCommandOptions
                        snapshotOrderEventStream
                        target
                        ( ApprovePayment
                            ApprovePaymentData
                                { orderId = OrderId "snapshot-100"
                                , paymentRef = samplePaymentRef
                                }
                        )
            Right snapshotVersion <-
                runner $
                    Store.runTransaction $
                        Tx.statement "order-snapshot-100" snapshotVersionForStreamStmt
            snapshotVersion `shouldBe` Just (StreamVersion 2)

    describe "Jitsurei process manager" $ around (withFreshResourceStoreWith fixture (withProjectionSchema jitsureiProjectionSchema)) $ do
        it "dispatches a packing command once for a payment event" $ \(_store, StoreRunner runner) -> do
            -- Dispatching the fulfillment process manager now runs the target's
            -- inline order-summary projection (see commit "run target inline
            -- projections on dispatch"), which writes to jitsurei_order_summary.
            -- That application table must exist before dispatch.
            Right () <- runner initializeJitsureiTables
            let target = orderStream sampleOrderId
            Right (Right _) <-
                runner $
                    runCommand defaultRunCommandOptions orderEventStream target samplePlaceOrder
            Right (Right _) <-
                runner $
                    runCommand defaultRunCommandOptions orderEventStream target sampleApprovePayment
            Right recorded <-
                runner $
                    Store.readStreamForward (StreamName "order-order-100") (StreamVersion 0) 10
            let paymentRecorded = Vector.toList recorded !! 1
            first <-
                runner $
                    runFulfillmentOnce
                        defaultRunCommandOptions
                        paymentRecorded
                        (PaymentApproved PaymentApprovedData{orderId = sampleOrderId, paymentRef = samplePaymentRef})
            first `shouldSatisfy` \case
                Right (Right result) ->
                    case result ^. #commandResults of
                        [PMCommandAppended{}] -> True
                        _ -> False
                _ -> False
            second <-
                runner $
                    runFulfillmentOnce
                        defaultRunCommandOptions
                        paymentRecorded
                        (PaymentApproved PaymentApprovedData{orderId = sampleOrderId, paymentRef = samplePaymentRef})
            second `shouldSatisfy` \case
                Right (Right result) ->
                    case (result ^. #managerResult, result ^. #commandResults) of
                        (PMStateDuplicate{}, [PMCommandDuplicate{}]) -> True
                        _ -> False
                _ -> False

        it "updates the target inline read model when fulfillment dispatches packing" $ \(_store, StoreRunner runner) -> do
            Right () <- runner initializeJitsureiTables
            let target = orderStream sampleOrderId
            Right (Right _) <-
                runner $
                    runCommandWithProjections
                        defaultRunCommandOptions
                        orderEventStream
                        target
                        samplePlaceOrder
                        [orderSummaryInlineProjection]
            Right (Right _) <-
                runner $
                    runCommandWithProjections
                        defaultRunCommandOptions
                        orderEventStream
                        target
                        sampleApprovePayment
                        [orderSummaryInlineProjection]
            Right paidSummary <-
                runner $
                    runQuery Nothing orderSummaryReadModel (OrderSummaryQuery sampleOrderId)
            case paidSummary of
                Right (Just summary) -> summary ^. #status `shouldBe` "paid"
                other -> expectationFailure ("expected paid order summary, got " <> show other)

            Right recorded <-
                runner $
                    Store.readStreamForward (StreamName "order-order-100") (StreamVersion 0) 10
            let paymentRecorded = Vector.toList recorded !! 1
            first <-
                runner $
                    runFulfillmentOnce
                        defaultRunCommandOptions
                        paymentRecorded
                        (PaymentApproved PaymentApprovedData{orderId = sampleOrderId, paymentRef = samplePaymentRef})
            first `shouldSatisfy` \case
                Right (Right result) ->
                    case result ^. #commandResults of
                        [PMCommandAppended{}] -> True
                        _ -> False
                _ -> False
            Right packedSummary <-
                runner $
                    runQuery Nothing orderSummaryReadModel (OrderSummaryQuery sampleOrderId)
            case packedSummary of
                Right (Just summary) -> summary ^. #status `shouldBe` "packed"
                other -> expectationFailure ("expected packed order summary, got " <> show other)

            second <-
                runner $
                    runFulfillmentOnce
                        defaultRunCommandOptions
                        paymentRecorded
                        (PaymentApproved PaymentApprovedData{orderId = sampleOrderId, paymentRef = samplePaymentRef})
            second `shouldSatisfy` \case
                Right (Right result) ->
                    case (result ^. #managerResult, result ^. #commandResults) of
                        (PMStateDuplicate{}, [PMCommandDuplicate{}]) -> True
                        _ -> False
                _ -> False
            Right replayedSummary <-
                runner $
                    runQuery Nothing orderSummaryReadModel (OrderSummaryQuery sampleOrderId)
            case replayedSummary of
                Right (Just summary) -> summary ^. #status `shouldBe` "packed"
                other -> expectationFailure ("expected packed order summary after replay, got " <> show other)

    describe "Jitsurei timers" $ around (withFreshResourceStore fixture) $ do
        it "claims a due timer and marks it fired" $ \(_store, StoreRunner runner) -> do
            Right () <-
                runner $
                    Store.runTransaction $
                        scheduleTimerTx (paymentTimeoutRequest sampleOrderId dueTime)
            Right claimed <-
                runner $
                    runPaymentTimeoutWorker Nothing dueTime
            claimed `shouldSatisfy` isJust

    describe "Jitsurei agent-qualification router" $ around (withFreshResourceStore fixture) $ do
        it "routes a transaction to every chapter resolved from its areas, idempotently" $ \(_store, StoreRunner runner) -> do
            Right () <-
                runner $
                    initializeAreaChapters
            Right () <- runner $
                Store.runTransaction $ do
                    -- area-north and area-south overlap on (m2, c2).
                    Tx.statement ("area-north", "m1", "c1") insertAreaChapterStmt
                    Tx.statement ("area-north", "m2", "c2") insertAreaChapterStmt
                    Tx.statement ("area-south", "m2", "c2") insertAreaChapterStmt
                    Tx.statement ("area-south", "m3", "c3") insertAreaChapterStmt
            let transaction =
                    Transaction
                        { txnId = TxnId "txn-1"
                        , areas = [AreaId "area-north", AreaId "area-south"]
                        }
            -- First pass: three distinct chapters resolved (m2/c2 de-duplicated
            -- across the two overlapping areas), one command appended to each.
            Right (RouterResult rs1) <-
                runner $
                    runRouterOnce defaultRunCommandOptions (agentQualRouter Nothing) sourceTransactionEvent transaction
            length rs1 `shouldBe` 3
            rs1 `shouldSatisfy` all isAppended
            Right c1 <-
                runner $
                    Store.readStreamForward (StreamName "chapter-m1-c1") (StreamVersion 0) 10
            Right c2 <-
                runner $
                    Store.readStreamForward (StreamName "chapter-m2-c2") (StreamVersion 0) 10
            Right c3 <-
                runner $
                    Store.readStreamForward (StreamName "chapter-m3-c3") (StreamVersion 0) 10
            Vector.length c1 `shouldBe` 1
            Vector.length c2 `shouldBe` 1
            Vector.length c3 `shouldBe` 1
            -- Data-dependence: a transaction whose areas are unseeded resolves to no
            -- chapters, so the count tracks the read model rather than a fixed list.
            Right (RouterResult rsEmpty) <-
                runner $
                    runRouterOnce
                        defaultRunCommandOptions
                        (agentQualRouter Nothing)
                        sourceTransactionEvent
                        (Transaction{txnId = TxnId "txn-1", areas = [AreaId "area-empty"]})
            length rsEmpty `shouldBe` 0
            -- Replay: the same source event re-dispatches as duplicates, no new events.
            Right (RouterResult rs2) <-
                runner $
                    runRouterOnce defaultRunCommandOptions (agentQualRouter Nothing) sourceTransactionEvent transaction
            length rs2 `shouldBe` 3
            rs2 `shouldSatisfy` all isDuplicate
            Right c1' <-
                runner $
                    Store.readStreamForward (StreamName "chapter-m1-c1") (StreamVersion 0) 10
            Right c2' <-
                runner $
                    Store.readStreamForward (StreamName "chapter-m2-c2") (StreamVersion 0) 10
            Right c3' <-
                runner $
                    Store.readStreamForward (StreamName "chapter-m3-c3") (StreamVersion 0) 10
            Vector.length c1' `shouldBe` 1
            Vector.length c2' `shouldBe` 1
            Vector.length c3' `shouldBe` 1

    describe "Jitsurei incident aggregate" $ around (withFreshResourceStore fixture) $ do
        it "raises, acknowledges, and rejects a post-acknowledgement escalation" $ \(_store, StoreRunner runner) -> do
            let incidentId = IncidentId "inc-1"
                target = incidentStream incidentId
            Right (Right _) <-
                runner $
                    runCommand defaultRunCommandOptions incidentEventStream target $
                        RaiseIncident
                            RaiseIncidentData
                                { incidentId = incidentId
                                , service = Service "checkout"
                                , severity = Sev1
                                , raisedAt = incidentRaisedAt
                                }
            Right (Right _) <-
                runner $
                    runCommand
                        defaultRunCommandOptions
                        incidentEventStream
                        target
                        (AcknowledgeIncident (AcknowledgeIncidentData incidentId))
            -- The aggregate's guards resolve the ack/escalate race: once acknowledged,
            -- EscalateIncident has no edge and is a benign domain rejection.
            escalateResult <-
                runner $
                    runCommand
                        defaultRunCommandOptions
                        incidentEventStream
                        target
                        (EscalateIncident (EscalateIncidentData incidentId))
            escalateResult `shouldBe` Right (Left CommandRejected)
            Right recorded <-
                runner $
                    Store.readStreamForward (StreamName "incident-inc-1") (StreamVersion 0) 10
            traverse (decodeRecorded incidentCodec) (Vector.toList recorded)
                `shouldBe` Right
                    [ IncidentRaised
                        IncidentRaisedData
                            { incidentId = incidentId
                            , service = Service "checkout"
                            , severity = Sev1
                            , raisedAt = incidentRaisedAt
                            }
                    , IncidentAcknowledged (IncidentAcknowledgedData incidentId)
                    ]

    describe "Jitsurei paging" $ around (withFreshResourceStore fixture) $ do
        it "sends then acknowledges a page" $ \(_store, StoreRunner runner) -> do
            let incidentId = IncidentId "inc-1"
                responderId = ResponderId "alice"
                target = pageStream incidentId responderId
            Right (Right _) <-
                runner $
                    runCommand
                        defaultRunCommandOptions
                        pageEventStream
                        target
                        (SendPage (SendPageData incidentId responderId))
            Right (Right _) <-
                runner $
                    runCommand
                        defaultRunCommandOptions
                        pageEventStream
                        target
                        (AcknowledgePage (AcknowledgePageData incidentId responderId))
            Right recorded <-
                runner $
                    Store.readStreamForward (StreamName "page-inc-1-alice") (StreamVersion 0) 10
            traverse (decodeRecorded pageCodec) (Vector.toList recorded)
                `shouldBe` Right
                    [ PageSent (PageSentData incidentId responderId)
                    , PageAcknowledged (PageAcknowledgedData incidentId responderId)
                    ]

        it "fans IncidentRaised out to one page per rostered responder, idempotently" $ \(_store, StoreRunner runner) -> do
            Right () <-
                runner $
                    initializeOncallRoster
            Right () <- runner $
                Store.runTransaction $ do
                    Tx.statement ("checkout", "alice", 1) insertOncallStmt
                    Tx.statement ("checkout", "bob", 1) insertOncallStmt
                    Tx.statement ("checkout", "carol", 2) insertOncallStmt
            let raised =
                    IncidentRaisedData
                        { incidentId = IncidentId "inc-1"
                        , service = Service "checkout"
                        , severity = Sev1
                        , raisedAt = incidentRaisedAt
                        }
            Right (RouterResult rs1) <-
                runner $
                    runRouterOnce defaultRunCommandOptions (pagingRouter Nothing) incidentRaisedSource raised
            length rs1 `shouldBe` 3
            rs1 `shouldSatisfy` all isAppended
            Right pa <-
                runner $
                    Store.readStreamForward (StreamName "page-inc-1-alice") (StreamVersion 0) 10
            Right pb <-
                runner $
                    Store.readStreamForward (StreamName "page-inc-1-bob") (StreamVersion 0) 10
            Right pc <-
                runner $
                    Store.readStreamForward (StreamName "page-inc-1-carol") (StreamVersion 0) 10
            Vector.length pa `shouldBe` 1
            Vector.length pb `shouldBe` 1
            Vector.length pc `shouldBe` 1
            -- Data-dependence: an unrostered service resolves to no pages.
            Right (RouterResult rsNone) <-
                runner $
                    runRouterOnce
                        defaultRunCommandOptions
                        (pagingRouter Nothing)
                        incidentRaisedSource
                        IncidentRaisedData
                            { incidentId = raised.incidentId
                            , service = Service "unstaffed"
                            , severity = raised.severity
                            , raisedAt = raised.raisedAt
                            }
            length rsNone `shouldBe` 0
            -- Replay the same source event: every dispatch is a duplicate, no new pages.
            Right (RouterResult rs2) <-
                runner $
                    runRouterOnce defaultRunCommandOptions (pagingRouter Nothing) incidentRaisedSource raised
            length rs2 `shouldBe` 3
            rs2 `shouldSatisfy` all isDuplicate
            Right paAgain <-
                runner $
                    Store.readStreamForward (StreamName "page-inc-1-alice") (StreamVersion 0) 10
            Vector.length paAgain `shouldBe` 1

    describe "Jitsurei escalation process manager" $ around (withFreshResourceStore fixture) $ do
        it "advances the saga and schedules an escalation timer on IncidentRaised" $ \(_store, StoreRunner runner) -> do
            let incidentId = IncidentId "inc-1"
                raised =
                    IncidentRaisedData
                        { incidentId = incidentId
                        , service = Service "checkout"
                        , severity = Sev1
                        , raisedAt = incidentRaisedAt
                        }
            result <-
                runner $
                    runEscalationOnce defaultRunCommandOptions incidentRaisedSource (IncidentReported raised)
            case result of
                Right (Right pmResult) -> do
                    pmResult ^. #managerResult `shouldSatisfy` \case
                        PMStateAppended{} -> True
                        _ -> False
                    pmResult ^. #timersScheduled `shouldBe` 1
                other -> expectationFailure ("expected process-manager success, got " <> show other)
            -- The Sev1 escalation window is 5 minutes; a timer due at +10m is claimable.
            claimed <- runner $ claimDueTimer (addUTCTime 600 incidentRaisedAt)
            claimed `shouldSatisfy` \case
                Right (Just _) -> True
                _ -> False

        it "dispatches AcknowledgeIncident on PageAcknowledged, idempotently" $ \(_store, StoreRunner runner) -> do
            let incidentId = IncidentId "inc-2"
            Right (Right _) <-
                runner $
                    runCommand
                        defaultRunCommandOptions
                        incidentEventStream
                        (incidentStream incidentId)
                        (RaiseIncident (sampleRaiseCmd incidentId Sev2))
            -- The saga must observe the incident before an acknowledgement, exactly as
            -- the live flow does (IncidentRaised reaches the PM before any PageAcknowledged).
            Right (Right _) <-
                runner $
                    runEscalationOnce defaultRunCommandOptions incidentRaisedSource (IncidentReported (sampleRaised incidentId Sev2))
            let acked = PageAcknowledgedData{incidentId = incidentId, responderId = ResponderId "alice"}
            firstResult <-
                runner $
                    runEscalationOnce defaultRunCommandOptions pageAckSource (ResponderAcked acked)
            firstResult `shouldSatisfy` \case
                Right (Right pmResult) ->
                    case pmResult ^. #commandResults of
                        [PMCommandAppended{}] -> True
                        _ -> False
                _ -> False
            Right managerSnapshotVersion <-
                runner $
                    Store.runTransaction $
                        Tx.statement "esc-inc-2" snapshotVersionForStreamStmt
            managerSnapshotVersion `shouldBe` Just (StreamVersion 2)
            Right recorded <-
                runner $
                    Store.readStreamForward (StreamName "incident-inc-2") (StreamVersion 0) 10
            fmap last (traverse (decodeRecorded incidentCodec) (Vector.toList recorded))
                `shouldBe` Right (IncidentAcknowledged (IncidentAcknowledgedData incidentId))
            secondResult <-
                runner $
                    runEscalationOnce defaultRunCommandOptions pageAckSource (ResponderAcked acked)
            secondResult `shouldSatisfy` \case
                Right (Right pmResult) ->
                    case (pmResult ^. #managerResult, pmResult ^. #commandResults) of
                        (PMStateDuplicate{}, [PMCommandDuplicate{}]) -> True
                        _ -> False
                _ -> False

        it "escalates an unacknowledged incident when the timer fires" $ \(_store, StoreRunner runner) -> do
            let incidentId = IncidentId "inc-3"
            Right (Right _) <-
                runner $
                    runCommand
                        defaultRunCommandOptions
                        incidentEventStream
                        (incidentStream incidentId)
                        (RaiseIncident (sampleRaiseCmd incidentId Sev1))
            Right (Right _) <-
                runner $
                    runEscalationOnce defaultRunCommandOptions incidentRaisedSource (IncidentReported (sampleRaised incidentId Sev1))
            _ <-
                runner $
                    runEscalationTimerWorker Nothing defaultRunCommandOptions (addUTCTime 600 incidentRaisedAt)
            Right recorded <-
                runner $
                    Store.readStreamForward (StreamName "incident-inc-3") (StreamVersion 0) 10
            fmap last (traverse (decodeRecorded incidentCodec) (Vector.toList recorded))
                `shouldBe` Right (IncidentEscalated (IncidentEscalatedData incidentId))

        it "is a benign no-op when the incident was already acknowledged" $ \(_store, StoreRunner runner) -> do
            let incidentId = IncidentId "inc-4"
                target = incidentStream incidentId
            Right (Right _) <-
                runner $
                    runCommand defaultRunCommandOptions incidentEventStream target (RaiseIncident (sampleRaiseCmd incidentId Sev1))
            Right (Right _) <-
                runner $
                    runCommand
                        defaultRunCommandOptions
                        incidentEventStream
                        target
                        (AcknowledgeIncident (AcknowledgeIncidentData incidentId))
            Right (Right _) <-
                runner $
                    runEscalationOnce defaultRunCommandOptions incidentRaisedSource (IncidentReported (sampleRaised incidentId Sev1))
            fired <-
                runner $
                    runEscalationTimerWorker Nothing defaultRunCommandOptions (addUTCTime 600 incidentRaisedAt)
            fired `shouldSatisfy` \case
                Right (Just _) -> True
                _ -> False
            Right recorded <-
                runner $
                    Store.readStreamForward (StreamName "incident-inc-4") (StreamVersion 0) 10
            let events = either (const []) id (traverse (decodeRecorded incidentCodec) (Vector.toList recorded))
            any isIncidentEscalated events `shouldBe` False

sampleOrderId :: OrderId
sampleOrderId = OrderId "order-100"

sampleSku :: Sku
sampleSku = Sku "SKU-RED-MUG"

sampleQuantity :: Quantity
sampleQuantity = Quantity 3

samplePaymentRef :: PaymentRef
samplePaymentRef = PaymentRef "pay_123"

samplePlaceOrder :: OrderCommand
samplePlaceOrder =
    PlaceOrder
        PlaceOrderData
            { orderId = sampleOrderId
            , sku = sampleSku
            , quantity = sampleQuantity
            }

sampleApprovePayment :: OrderCommand
sampleApprovePayment =
    ApprovePayment
        ApprovePaymentData
            { orderId = sampleOrderId
            , paymentRef = samplePaymentRef
            }

dueTime :: UTCTime
dueTime = UTCTime (ModifiedJulianDay 1) (secondsToDiffTime 0)

-- A minimal source event whose only load-bearing field is its id, which seeds
-- the router's deterministic command ids. Its payload is irrelevant to routing.
sourceTransactionEvent :: RecordedEvent
sourceTransactionEvent =
    RecordedEvent
        { eventId = EventId txnSourceUuid
        , eventType = EventType "TransactionSubmitted"
        , streamVersion = StreamVersion 1
        , globalPosition = GlobalPosition 1
        , originalStreamId = StreamId 1
        , originalVersion = StreamVersion 1
        , payload = Aeson.Null
        , metadata = Nothing
        , causationId = Nothing
        , correlationId = Nothing
        , createdAt = UTCTime (ModifiedJulianDay 0) (secondsToDiffTime 0)
        }

txnSourceUuid :: UUID
txnSourceUuid =
    case fromString "018f0f18-17aa-7000-8000-0000000000c1" of
        Just value -> value
        Nothing -> error "invalid transaction source UUID"

incidentRaisedAt :: UTCTime
incidentRaisedAt = UTCTime (ModifiedJulianDay 60000) (secondsToDiffTime 0)

-- The command and event payloads share fields but are distinct types; build each
-- from the same inputs.
sampleRaiseCmd :: IncidentId -> Severity -> RaiseIncidentData
sampleRaiseCmd incidentId severity =
    RaiseIncidentData
        { incidentId = incidentId
        , service = Service "checkout"
        , severity = severity
        , raisedAt = incidentRaisedAt
        }

sampleRaised :: IncidentId -> Severity -> IncidentRaisedData
sampleRaised incidentId severity =
    IncidentRaisedData
        { incidentId = incidentId
        , service = Service "checkout"
        , severity = severity
        , raisedAt = incidentRaisedAt
        }

-- A minimal source event standing in for a recorded IncidentRaised; only its id
-- is load-bearing (it seeds the paging router's deterministic command ids).
incidentRaisedSource :: RecordedEvent
incidentRaisedSource =
    RecordedEvent
        { eventId = EventId incidentSourceUuid
        , eventType = EventType "IncidentRaised"
        , streamVersion = StreamVersion 1
        , globalPosition = GlobalPosition 1
        , originalStreamId = StreamId 1
        , originalVersion = StreamVersion 1
        , payload = Aeson.Null
        , metadata = Nothing
        , causationId = Nothing
        , correlationId = Nothing
        , createdAt = incidentRaisedAt
        }

incidentSourceUuid :: UUID
incidentSourceUuid =
    case fromString "018f0f18-17aa-7000-8000-0000000000d1" of
        Just value -> value
        Nothing -> error "invalid incident source UUID"

-- A second source-event fixture, standing in for a recorded PageAcknowledged.
pageAckSource :: RecordedEvent
pageAckSource = incidentRaisedSource{eventId = EventId pageAckSourceUuid}

pageAckSourceUuid :: UUID
pageAckSourceUuid =
    case fromString "018f0f18-17aa-7000-8000-0000000000d2" of
        Just value -> value
        Nothing -> error "invalid page-ack source UUID"

isIncidentEscalated :: IncidentEvent -> Bool
isIncidentEscalated = \case
    IncidentEscalated{} -> True
    _ -> False

isAppended :: PMCommandResult target -> Bool
isAppended = \case
    PMCommandAppended{} -> True
    _ -> False

isDuplicate :: PMCommandResult target -> Bool
isDuplicate = \case
    PMCommandDuplicate{} -> True
    _ -> False

snapshotVersionForStreamStmt :: Statement Text (Maybe StreamVersion)
snapshotVersionForStreamStmt =
    preparable
        """
        SELECT ks.stream_version
        FROM keiro.keiro_snapshots ks
        JOIN streams s ON s.stream_id = ks.stream_id
        WHERE s.stream_name = $1
        """
        (E.param (E.nonNullable E.text))
        (D.rowMaybe (StreamVersion <$> D.column (D.nonNullable D.int8)))
