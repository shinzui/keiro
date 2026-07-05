module Main (
    main,
)
where

import Data.Aeson qualified as Aeson
import Data.Foldable (traverse_)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.UUID (UUID)
import Data.UUID.V5 qualified as UUID.V5
import Data.Vector qualified as Vector
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Jitsurei
import Keiro
import Keiro.Connection (keiroConnectionSettings)
import Keiro.ProcessManager (runProcessManagerWorker)
import Keiro.Projection (runCommandWithProjections)
import Keiro.ReadModel (runQuery)
import Keiro.Workflow (
    WorkflowId (..),
    WorkflowJournalEvent (StepRecorded),
    WorkflowName,
    findUnfinishedWorkflowIds,
    runWorkflow,
    workflowJournalCodec,
    workflowStreamName,
 )
import Keiro.Workflow.Awakeable (signalAwakeable)
import Keiro.Workflow.Resume (defaultWorkflowResumeOptions, resumeWorkflowsOnce)
import Keiro.Workflow.Sleep (runWorkflowTimerWorker)
import Kiroku.Store qualified as Store
import Kiroku.Store.Types (
    EventId (..),
    EventType (..),
    GlobalPosition (..),
    RecordedEvent (..),
    StreamId (..),
    StreamName (..),
    StreamVersion (..),
 )
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Streamly.Data.Stream qualified as Streamly
import System.Environment (getArgs, lookupEnv)
import "hasql-transaction" Hasql.Transaction qualified as Tx

main :: IO ()
main = do
    args <- getArgs
    case args of
        [] -> runFulfillmentDemo
        ["fulfillment"] -> runFulfillmentDemo
        ["snapshots"] -> runSnapshotsDemo
        ["escalation"] -> runEscalationDemo
        ["paging"] -> runPagingDemo
        ["agent-qual"] -> runAgentQualDemo
        ["workflow"] -> runDurableWorkflowDemo
        ["all"] -> do
            runFulfillmentDemo
            runSnapshotsDemo
            runPagingDemo
            runEscalationDemo
            runAgentQualDemo
            runDurableWorkflowDemo
        _ -> fail "usage: jitsurei-demo [fulfillment|snapshots|paging|escalation|agent-qual|workflow|all]"

runFulfillmentDemo :: IO ()
runFulfillmentDemo = withJitsureiStore $ \store -> do
    orderId <- freshOrderId "demo"
    putStrLn ("[jitsurei:fulfillment] running order fulfillment demo for " <> Text.unpack (orderIdText orderId))
    requireEither =<< Store.runStoreIO store initializeJitsureiTables

    putStrLn "[jitsurei:fulfillment] appending PlaceOrder with the order-summary inline projection"
    placed <-
        requireEither
            =<< requireEither
            =<< Store.runStoreIO
                store
                ( runCommandWithProjections
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
                    [orderSummaryInlineProjection]
                )
    print placed

    putStrLn "[jitsurei:fulfillment] appending ApprovePayment with the same projection"
    paid <-
        requireEither
            =<< requireEither
            =<< Store.runStoreIO
                store
                ( runCommandWithProjections
                    defaultRunCommandOptions
                    orderEventStream
                    (orderStream orderId)
                    ( ApprovePayment
                        ApprovePaymentData
                            { orderId = orderId
                            , paymentRef = PaymentRef "pay_demo"
                            }
                    )
                    [orderSummaryInlineProjection]
                )
    print paid

    orderEventsBefore <- readEvents store ("order-" <> orderIdText orderId)
    putStrLn "[jitsurei:fulfillment] order stream after payment"
    printDecoded orderCodec orderEventsBefore

    summary <- requireEither =<< Store.runStoreIO store (runQuery Nothing orderSummaryReadModel (OrderSummaryQuery orderId))
    putStrLn "[jitsurei:fulfillment] jitsurei_order_summary row"
    print summary

    paymentRecorded <- requirePaymentEvent orderEventsBefore
    let paymentApproved =
            PaymentApproved
                PaymentApprovedData
                    { orderId = orderId
                    , paymentRef = PaymentRef "pay_demo"
                    }
    putStrLn "[jitsurei:fulfillment] running fulfillment process-manager worker for PaymentApproved"
    requireEither
        =<< Store.runStoreIO
            store
            ( runProcessManagerWorker
                defaultRunCommandOptions
                fulfillmentProcessManager
                (processManagerAdapter paymentRecorded paymentApproved)
                Just
            )
    putStrLn "[jitsurei:fulfillment] fulfillment process-manager worker drained one adapter message"

    orderEventsAfter <- readEvents store ("order-" <> orderIdText orderId)
    putStrLn "[jitsurei:fulfillment] order stream after process manager dispatch"
    printDecoded orderCodec orderEventsAfter

    fulfillmentEvents <- readEvents store ("fulfillment-" <> orderIdText orderId)
    putStrLn "[jitsurei:fulfillment] fulfillment process-manager stream"
    printDecoded fulfillmentCodec fulfillmentEvents

runSnapshotsDemo :: IO ()
runSnapshotsDemo = withJitsureiStore $ \store -> do
    orderId <- freshOrderId "snapshot"
    putStrLn ("[jitsurei:snapshots] running snapshot demo for " <> Text.unpack (orderIdText orderId))
    requireEither =<< Store.runStoreIO store initializeJitsureiTables

    putStrLn "[jitsurei:snapshots] appending PlaceOrder through snapshotOrderEventStream"
    _ <-
        requireEither
            =<< requireEither
            =<< Store.runStoreIO
                store
                ( runCommand
                    defaultRunCommandOptions
                    snapshotOrderEventStream
                    (orderStream orderId)
                    ( PlaceOrder
                        PlaceOrderData
                            { orderId = orderId
                            , sku = Sku "SKU-SNAPSHOT"
                            , quantity = Quantity 2
                            }
                    )
                )

    putStrLn "[jitsurei:snapshots] appending ApprovePayment; Every 2 writes keiro_snapshots at stream version 2"
    _ <-
        requireEither
            =<< requireEither
            =<< Store.runStoreIO
                store
                ( runCommand
                    defaultRunCommandOptions
                    snapshotOrderEventStream
                    (orderStream orderId)
                    ( ApprovePayment
                        ApprovePaymentData
                            { orderId = orderId
                            , paymentRef = PaymentRef "pay_snapshot"
                            }
                    )
                )

    orderEvents <- readEvents store ("order-" <> orderIdText orderId)
    putStrLn "[jitsurei:snapshots] order stream"
    printDecoded orderCodec orderEvents
    printSnapshotRows store orderId

runPagingDemo :: IO ()
runPagingDemo = withJitsureiStore $ \store -> do
    runId <- freshTextId "paging"
    let service = Service ("checkout-" <> runId)
        incidentId = IncidentId ("inc-" <> runId)
        raised =
            IncidentRaisedData
                { incidentId = incidentId
                , service = service
                , severity = Sev1
                , raisedAt = stableRaisedAt
                }
        source = sourceEvent "IncidentRaised" ("paging:" <> incidentIdText incidentId) stableRaisedAt
    putStrLn ("[jitsurei:paging] seeding jitsurei_service_oncall for " <> Text.unpack (serviceText service))
    requireEither =<< Store.runStoreIO store initializeJitsureiTables
    requireEither =<< Store.runStoreIO store (Store.runTransaction initializeOncallRosterTable)
    requireEither
        =<< Store.runStoreIO
            store
            ( Store.runTransaction do
                Tx.statement (serviceText service, "alice", 1) insertOncallStmt
                Tx.statement (serviceText service, "bob", 1) insertOncallStmt
                Tx.statement (serviceText service, "carol", 2) insertOncallStmt
            )
    roster <- requireEither =<< Store.runStoreIO store (runQuery Nothing serviceOncallReadModel service)
    putStrLn "[jitsurei:paging] resolved roster read-model rows"
    print roster

    putStrLn "[jitsurei:paging] routing IncidentRaised to page streams"
    routerResult <-
        requireEither
            =<< Store.runStoreIO
                store
                (runRouterOnce defaultRunCommandOptions pagingRouter source raised)
    print routerResult
    traverse_
        ( \responderId -> do
            events <- readEvents store ("page-" <> incidentIdText incidentId <> "-" <> responderIdText responderId)
            putStrLn ("[jitsurei:paging] page stream for " <> Text.unpack (responderIdText responderId))
            printDecoded pageCodec events
        )
        [ResponderId "alice", ResponderId "bob", ResponderId "carol"]

runEscalationDemo :: IO ()
runEscalationDemo = withJitsureiStore $ \store -> do
    runId <- freshTextId "esc"
    let incidentId = IncidentId ("inc-" <> runId)
        service = Service ("checkout-" <> runId)
        raisedAt = stableRaisedAt
        raisedData =
            RaiseIncidentData
                { incidentId = incidentId
                , service = service
                , severity = Sev1
                , raisedAt = raisedAt
                }
        raisedEvent =
            IncidentRaisedData
                { incidentId = incidentId
                , service = service
                , severity = Sev1
                , raisedAt = raisedAt
                }
        alice = ResponderId "alice"
    putStrLn ("[jitsurei:escalation] running incident escalation demo for " <> Text.unpack (incidentIdText incidentId))
    requireEither =<< Store.runStoreIO store initializeJitsureiTables
    requireEither =<< Store.runStoreIO store (Store.runTransaction initializeOncallRosterTable)
    requireEither
        =<< Store.runStoreIO
            store
            ( Store.runTransaction do
                Tx.statement (serviceText service, responderIdText alice, 1) insertOncallStmt
                Tx.statement (serviceText service, "bob", 2) insertOncallStmt
            )

    putStrLn "[jitsurei:escalation] raising the incident aggregate"
    _ <-
        requireEither
            =<< requireEither
            =<< Store.runStoreIO
                store
                (runCommand defaultRunCommandOptions incidentEventStream (incidentStream incidentId) (RaiseIncident raisedData))
    incidentEventsAfterRaise <- readEvents store ("incident-" <> incidentIdText incidentId)
    raisedRecorded <- requireLast "IncidentRaised" incidentEventsAfterRaise

    putStrLn "[jitsurei:escalation] running the paging router from the persisted IncidentRaised"
    pagingResult <-
        requireEither
            =<< Store.runStoreIO
                store
                (runRouterOnce defaultRunCommandOptions pagingRouter raisedRecorded raisedEvent)
    print pagingResult

    putStrLn "[jitsurei:escalation] running EscalationProcess for IncidentRaised; this persists esc-* saga data and a timer"
    escalationRaised <-
        requireEither
            =<< requireEither
            =<< Store.runStoreIO
                store
                (runEscalationOnce defaultRunCommandOptions raisedRecorded (IncidentReported raisedEvent))
    print escalationRaised
    printTimerRows store incidentId

    putStrLn "[jitsurei:escalation] acknowledging Alice's page and feeding PageAcknowledged to EscalationProcess"
    _ <-
        requireEither
            =<< requireEither
            =<< Store.runStoreIO
                store
                (runCommand defaultRunCommandOptions pageEventStream (pageStream incidentId alice) (AcknowledgePage (AcknowledgePageData incidentId alice)))
    alicePageEvents <- readEvents store ("page-" <> incidentIdText incidentId <> "-" <> responderIdText alice)
    ackRecorded <- requireLast "PageAcknowledged" alicePageEvents
    escalationAcked <-
        requireEither
            =<< requireEither
            =<< Store.runStoreIO
                store
                (runEscalationOnce defaultRunCommandOptions ackRecorded (ResponderAcked (PageAcknowledgedData incidentId alice)))
    print escalationAcked

    putStrLn "[jitsurei:escalation] firing the due timer after acknowledgement; the incident aggregate rejects escalation benignly"
    fired <-
        requireEither
            =<< Store.runStoreIO
                store
                (runEscalationTimerWorker defaultRunCommandOptions (addUTCTime 600 raisedAt))
    print fired

    incidentEvents <- readEvents store ("incident-" <> incidentIdText incidentId)
    putStrLn "[jitsurei:escalation] incident stream"
    printDecoded incidentCodec incidentEvents
    escalationEvents <- readEvents store ("esc-" <> incidentIdText incidentId)
    putStrLn "[jitsurei:escalation] escalation saga stream"
    printDecoded escalationCodec escalationEvents
    putStrLn "[jitsurei:escalation] Alice page stream"
    printDecoded pageCodec alicePageEvents
    bobPageEvents <- readEvents store ("page-" <> incidentIdText incidentId <> "-bob")
    putStrLn "[jitsurei:escalation] Bob page stream"
    printDecoded pageCodec bobPageEvents
    printTimerRows store incidentId

runAgentQualDemo :: IO ()
runAgentQualDemo = withJitsureiStore $ \store -> do
    runId <- freshTextId "agent"
    let north = AreaId ("north-" <> runId)
        south = AreaId ("south-" <> runId)
        txn =
            Transaction
                { txnId = TxnId ("txn-" <> runId)
                , areas = [north, south]
                }
        source = sourceEvent "TransactionSubmitted" ("agent-qual:" <> txnIdText txn.txnId) stableRaisedAt
    putStrLn "[jitsurei:agent-qual] seeding jitsurei_area_chapters"
    requireEither =<< Store.runStoreIO store initializeJitsureiTables
    requireEither =<< Store.runStoreIO store (Store.runTransaction initializeAreaChaptersTable)
    requireEither
        =<< Store.runStoreIO
            store
            ( Store.runTransaction do
                Tx.statement (areaIdText north, "m1", "c1") insertAreaChapterStmt
                Tx.statement (areaIdText north, "m2", "c2") insertAreaChapterStmt
                Tx.statement (areaIdText south, "m2", "c2") insertAreaChapterStmt
                Tx.statement (areaIdText south, "m3", "c3") insertAreaChapterStmt
            )
    northTargets <- requireEither =<< Store.runStoreIO store (runQuery Nothing areaChaptersReadModel north)
    southTargets <- requireEither =<< Store.runStoreIO store (runQuery Nothing areaChaptersReadModel south)
    putStrLn "[jitsurei:agent-qual] area read-model rows"
    print (northTargets, southTargets)

    putStrLn "[jitsurei:agent-qual] routing the transaction to de-duplicated chapter streams"
    routerResult <-
        requireEither
            =<< Store.runStoreIO
                store
                (runRouterOnce defaultRunCommandOptions agentQualRouter source txn)
    print routerResult
    traverse_
        ( \(member, chapter) -> do
            let chapterStreamName = "chapter-" <> memberIdText member <> "-" <> chapterIdText chapter
            events <- readEvents store chapterStreamName
            putStrLn ("[jitsurei:agent-qual] " <> Text.unpack chapterStreamName)
            printDecoded chapterCodec events
        )
        [(MemberId "m1", ChapterId "c1"), (MemberId "m2", ChapterId "c2"), (MemberId "m3", ChapterId "c3")]

{- | A durable order-fulfillment workflow demo. It runs the workflow to its
first suspension, fires the cooling-off sleep timer, resumes it past the
sleep, signals the payment-webhook awakeable, drives the resume worker until
the parent and its ship-order child both complete, dumps both journals, and
finally re-opens the store and re-runs discovery to prove the completed
workflow lives in the journal — not in the process.
-}
runDurableWorkflowDemo :: IO ()
runDurableWorkflowDemo = do
    orderId <- freshOrderId "workflow"
    let wfId = workflowIdFor orderId
        childWfId = shipChildId orderId
        idText = unWorkflowId wfId
        childIdText = unWorkflowId childWfId
        parentStream = workflowStreamNameText orderFulfillmentWorkflowName wfId
        childStream = workflowStreamNameText shipOrderWorkflowName childWfId

    withJitsureiStore $ \store -> do
        putStrLn ("[jitsurei:workflow] running durable order-fulfillment workflow for " <> Text.unpack idText)
        requireEither =<< Store.runStoreIO store initializeJitsureiTables

        -- 1) First run: reserve inventory runs, the cooling-off sleep arms, the
        --    run suspends.
        putStrLn "[jitsurei:workflow] first run: invoking the workflow"
        outcome1 <-
            requireEither
                =<< Store.runStoreIO store (runWorkflow orderFulfillmentWorkflowName wfId (orderFulfillmentWorkflow orderId))
        putStrLn ("[jitsurei:workflow] first run outcome: " <> show outcome1 <> " (armed the cooling-off sleep)")

        -- 2) Fire the durable sleep timer (advance the clock well past the delay).
        putStrLn "[jitsurei:workflow] firing the cooling-off sleep timer"
        fireSleepTimerUntilJournaled store parentStream

        -- 3) Resume pass 1: replays reserve-inventory + sleep:cooling-off, arms
        --    the payment-webhook awakeable, and parks again.
        summary1 <-
            requireEither
                =<< Store.runStoreIO store (resumeWorkflowsOnce defaultWorkflowResumeOptions jitsureiWorkflowRegistry)
        putStrLn ("[jitsurei:workflow] resume pass 1: " <> show summary1)
        putStrLn "  (replayed reserve-inventory + sleep:cooling-off, parked on the payment-webhook awakeable)"

        -- 4) Signal the awakeable (simulate the payment webhook callback).
        putStrLn "[jitsurei:workflow] signalling the payment-webhook awakeable (simulated webhook)"
        signalled <-
            requireEither
                =<< Store.runStoreIO
                    store
                    (signalAwakeable (paymentWebhookAwakeableId orderId) (PaymentConfirmation "pay_demo" 4200))
        putStrLn ("  signalAwakeable payment-webhook -> " <> show signalled)

        -- 5) Drive the resume worker until both the parent and its child finish.
        driveResumeUntilDone store [idText, childIdText] 2

        -- 6) Read the final outcome by replaying the now-complete journal.
        finalOutcome <-
            requireEither
                =<< Store.runStoreIO store (runWorkflow orderFulfillmentWorkflowName wfId (orderFulfillmentWorkflow orderId))
        putStrLn ("[jitsurei:workflow] final outcome: " <> show finalOutcome)

        -- 7) Dump both journals.
        parentJournal <- readEvents store parentStream
        putStrLn ("[jitsurei:workflow] order-fulfillment journal (" <> Text.unpack parentStream <> ")")
        printDecoded workflowJournalCodec parentJournal
        childJournal <- readEvents store childStream
        putStrLn ("[jitsurei:workflow] ship-order child journal (" <> Text.unpack childStream <> ")")
        printDecoded workflowJournalCodec childJournal

    -- 8) Simulated restart: a fresh store connection (a new "process") re-runs
    --    the resume worker's discovery and finds nothing to do for our workflow,
    --    proving the completed state lives in the journal, not in the process.
    putStrLn "[jitsurei:workflow] --- simulated restart: re-opening the store ---"
    withJitsureiStore $ \store -> do
        remaining <- ourUnfinishedWorkflows store [idText, childIdText]
        if null remaining
            then do
                putStrLn ("  restart: resume worker discovery found no unfinished work for order-fulfillment-" <> Text.unpack idText)
                putStrLn "[jitsurei:workflow] durability proven: the completed workflow was NOT re-executed from scratch"
            else
                putStrLn ("  restart: UNEXPECTED — workflow still unfinished: " <> show remaining)

{- | The journal stream name for a workflow instance, as the 'Text' 'readEvents'
expects (unwrapping the 'StreamName' 'workflowStreamName' returns).
-}
workflowStreamNameText :: WorkflowName -> WorkflowId -> Text
workflowStreamNameText name wid =
    let StreamName s = workflowStreamName name wid in s

{- | Unfinished workflows (per 'findUnfinishedWorkflowIds') whose id is one of
ours this run — the parent and the ship-order child carry distinct ids.
-}
ourUnfinishedWorkflows :: Store.KirokuStore -> [Text] -> IO [(Text, Text)]
ourUnfinishedWorkflows store ourIds = do
    now <- getCurrentTime
    pairs <- requireEither =<< Store.runStoreIO store (findUnfinishedWorkflowIds now)
    pure [pair | pair@(wid, _) <- pairs, wid `elem` ourIds]

{- | Fire workflow-sleep timers (with a clock well past the delay) until the
@sleep:cooling-off@ completion appears in the journal, bounded so a stray
non-sleep timer cannot hang the demo.
-}
fireSleepTimerUntilJournaled :: Store.KirokuStore -> Text -> IO ()
fireSleepTimerUntilJournaled store parentStream = do
    fireTime <- addUTCTime 3600 <$> getCurrentTime
    let loop :: Int -> IO ()
        loop n
            | n > 10 = putStrLn "  WARNING: sleep:cooling-off was not journaled after 10 timer passes"
            | otherwise = do
                done <- journalHasStep store parentStream "sleep:cooling-off"
                if done
                    then putStrLn "  timer worker fired sleep:cooling-off -> journal"
                    else do
                        _ <-
                            requireEither
                                =<< Store.runStoreIO store (runWorkflowTimerWorker Nothing fireTime (\_ -> pure Nothing))
                        loop (n + 1)
    loop 0

{- | Run the resume worker until no workflow of ours remains unfinished, bounded
so a non-converging journal cannot hang the demo. Prints each pass's summary.
-}
driveResumeUntilDone :: Store.KirokuStore -> [Text] -> Int -> IO ()
driveResumeUntilDone store ourIds = go
  where
    go :: Int -> IO ()
    go passNo
        | passNo > 7 = putStrLn "  reached the resume-pass bound (7) without completing"
        | otherwise = do
            remaining <- ourUnfinishedWorkflows store ourIds
            if null remaining
                then pure ()
                else do
                    summary <-
                        requireEither
                            =<< Store.runStoreIO store (resumeWorkflowsOnce defaultWorkflowResumeOptions jitsureiWorkflowRegistry)
                    putStrLn ("[jitsurei:workflow] resume pass " <> show passNo <> ": " <> show summary)
                    go (passNo + 1)

-- | Whether a workflow journal already records a 'StepRecorded' for @target@.
journalHasStep :: Store.KirokuStore -> Text -> Text -> IO Bool
journalHasStep store journalStream target = do
    events <- readEvents store journalStream
    let decoded = [event | Right event <- decodeRecorded workflowJournalCodec <$> events]
    pure (any matchesTarget decoded)
  where
    matchesTarget = \case
        StepRecorded name _ _ -> name == target
        _ -> False

withJitsureiStore :: (Store.KirokuStore -> IO ()) -> IO ()
withJitsureiStore action = do
    connString <- getConnectionString
    putStrLn ("[jitsurei] connecting to " <> Text.unpack connString)
    Store.withStore (keiroConnectionSettings connString jitsureiProjectionSchema) action

getConnectionString :: IO Text
getConnectionString = do
    configured <- lookupEnv "PG_CONNECTION_STRING"
    case configured of
        Just value -> pure (Text.pack value)
        Nothing -> pure "host=db dbname=jitsurei"

freshOrderId :: Text -> IO OrderId
freshOrderId prefix = OrderId <$> freshTextId prefix

freshTextId :: Text -> IO Text
freshTextId prefix = do
    now <- getCurrentTime
    pure (prefix <> "-" <> Text.pack (formatTime defaultTimeLocale "%Y%m%d%H%M%S%q" now))

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
                            , headers = Nothing
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

readEvents :: Store.KirokuStore -> Text -> IO [RecordedEvent]
readEvents store targetStreamName = do
    events <-
        requireEither
            =<< Store.runStoreIO
                store
                (Store.readStreamForward (StreamName targetStreamName) (StreamVersion 0) 100)
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

requireLast :: Text -> [RecordedEvent] -> IO RecordedEvent
requireLast label events =
    case reverse events of
        event : _ -> pure event
        [] -> fail (Text.unpack label <> " stream was empty")

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

printTimerRows :: Store.KirokuStore -> IncidentId -> IO ()
printTimerRows store incidentId = do
    rows <-
        requireEither
            =<< Store.runStoreIO
                store
                (Store.runTransaction (Tx.statement (incidentIdText incidentId) selectTimerRowsStmt))
    putStrLn "[jitsurei:escalation] keiro_timers rows for incident"
    traverse_ print rows

printSnapshotRows :: Store.KirokuStore -> OrderId -> IO ()
printSnapshotRows store orderId = do
    rows <-
        requireEither
            =<< Store.runStoreIO
                store
                (Store.runTransaction (Tx.statement ("order-" <> orderIdText orderId) selectSnapshotRowsStmt))
    putStrLn "[jitsurei:snapshots] keiro_snapshots rows for order stream"
    traverse_ print rows

data TimerView = TimerView
    { processManagerName :: !Text
    , correlationId :: !Text
    , status :: !Text
    , attempts :: !Int
    , fired :: !Bool
    }
    deriving stock (Show)

data SnapshotView = SnapshotView
    { streamName :: !Text
    , streamVersion :: !StreamVersion
    , state :: !Aeson.Value
    , stateCodecVersion :: !Int
    , regfileShapeHash :: !Text
    }
    deriving stock (Show)

selectTimerRowsStmt :: Statement Text [TimerView]
selectTimerRowsStmt =
    preparable
        """
        SELECT process_manager_name, correlation_id, status, attempts, fired_event_id IS NOT NULL
        FROM keiro.keiro_timers
        WHERE correlation_id = $1
        ORDER BY fire_at, timer_id
        """
        (E.param (E.nonNullable E.text))
        ( D.rowList
            ( TimerView
                <$> D.column (D.nonNullable D.text)
                <*> D.column (D.nonNullable D.text)
                <*> D.column (D.nonNullable D.text)
                <*> (fromIntegral <$> D.column (D.nonNullable D.int8))
                <*> D.column (D.nonNullable D.bool)
            )
        )

selectSnapshotRowsStmt :: Statement Text [SnapshotView]
selectSnapshotRowsStmt =
    preparable
        """
        SELECT s.stream_name, ks.stream_version, ks.state, ks.state_codec_version, ks.regfile_shape_hash
        FROM keiro.keiro_snapshots ks
        JOIN streams s ON s.stream_id = ks.stream_id
        WHERE s.stream_name = $1
        ORDER BY ks.stream_version DESC
        """
        (E.param (E.nonNullable E.text))
        ( D.rowList
            ( SnapshotView
                <$> D.column (D.nonNullable D.text)
                <*> (StreamVersion <$> D.column (D.nonNullable D.int8))
                <*> D.column (D.nonNullable D.jsonb)
                <*> (fromIntegral <$> D.column (D.nonNullable D.int8))
                <*> D.column (D.nonNullable D.text)
            )
        )

sourceEvent :: Text -> Text -> UTCTime -> RecordedEvent
sourceEvent eventType seed createdAt =
    RecordedEvent
        { eventId = EventId (namedUuid ("jitsurei-source:" <> eventType <> ":" <> seed))
        , eventType = EventType eventType
        , streamVersion = StreamVersion 1
        , globalPosition = GlobalPosition 1
        , originalStreamId = StreamId 1
        , originalVersion = StreamVersion 1
        , payload = Aeson.Null
        , metadata = Nothing
        , causationId = Nothing
        , correlationId = Nothing
        , createdAt = createdAt
        }

stableRaisedAt :: UTCTime
stableRaisedAt = read "2026-05-23 12:00:00 UTC"

namedUuid :: Text -> UUID
namedUuid value =
    UUID.V5.generateNamed UUID.V5.namespaceURL (fmap (fromIntegral . fromEnum) (Text.unpack value))

requireEither :: (Show err) => Either err a -> IO a
requireEither = \case
    Left err -> fail (show err)
    Right value -> pure value
