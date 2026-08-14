-- | A runnable, end-to-end durable workflow worked example.
--
-- This module defines an order-fulfillment durable workflow that exercises every
-- primitive of the v2 runtime (@Keiro.Workflow@): a named 'step', a durable
-- 'sleepNamed', an 'awakeableNamed' resolved by an external 'signalAwakeable', a
-- second 'step', and a @ship-order@ child workflow spawned with 'spawnChild' and
-- awaited with 'awaitChild'. The 'jitsurei.app.Main' @workflow@ subcommand drives
-- it to completion across a simulated process restart, proving durability.
--
-- The narrative mirrors @MasterPlan 5@'s vision sketch: reserve inventory, wait
-- out a short cooling-off period, wait for a payment webhook, charge the card,
-- then ship via a child workflow and return the tracking number. Every checkpoint
-- is journaled to @wf:order-fulfillment-\<id\>@, so a re-invocation short-circuits
-- work whose result is already durable. A step action can run again when a
-- process crashes after performing the action but before its result is
-- journaled, so externally visible actions must be idempotent.
module Jitsurei.DurableWorkflow
  ( -- * Workflow names
    orderFulfillmentWorkflowName,
    shipOrderWorkflowName,

    -- * The workflows
    PublishPaymentAwakeable,
    orderFulfillmentWorkflow,
    shipOrderWorkflow,

    -- * Payload type
    PaymentConfirmation (..),

    -- * Publication and the resume registry
    jitsureiWorkflowRegistryWith,
    jitsureiWorkflowRegistry,
    coolingOffDelay,
    workflowIdFor,
    orderIdFromWf,
    shipChildId,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime)
import Effectful (Eff, IOE, liftIO, raise, (:>))
import GHC.Generics (Generic)
import Jitsurei.Domain (OrderId (..), orderIdText)
import Keiro.Workflow
  ( StepName (..),
    Workflow,
    WorkflowId (..),
    step,
  )
import Keiro.Workflow.Awakeable
  ( AwakeableId,
    awakeableIdText,
    awakeableNamed,
  )
import Keiro.Workflow.Child (awaitChild, spawnChild)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Keiro.Workflow.Sleep (sleepNamed)
import Keiro.Workflow.Types (WorkflowName (..))
import Kiroku.Store.Effect (Store)
import System.IO (hFlush, stdout)

-- ---------------------------------------------------------------------------
-- Names and constants
-- ---------------------------------------------------------------------------

-- | The stable name of the parent order-fulfillment workflow definition.
orderFulfillmentWorkflowName :: WorkflowName
orderFulfillmentWorkflowName = WorkflowName "order-fulfillment"

-- | The stable name of the @ship-order@ child workflow definition.
shipOrderWorkflowName :: WorkflowName
shipOrderWorkflowName = WorkflowName "ship-order"

-- | A short, demo-friendly cooling-off period. A real workflow would sleep for
-- minutes or hours; two seconds keeps the worked example snappy while still
-- exercising the durable timer end to end.
coolingOffDelay :: NominalDiffTime
coolingOffDelay = 2

-- ---------------------------------------------------------------------------
-- Identity round-trip
-- ---------------------------------------------------------------------------

-- | Derive the parent's 'WorkflowId' from an 'OrderId'. The order id text /is/
-- the parent workflow instance id, so the journal stream is
-- @wf:order-fulfillment-\<order\>@ and the resume worker can reconstruct the
-- original 'OrderId' from the id alone (see 'orderIdFromWf').
workflowIdFor :: OrderId -> WorkflowId
workflowIdFor = WorkflowId . orderIdText

-- | The @ship-order@ child's 'WorkflowId'. It must be /distinct/ from the
-- parent's id ('workflowIdFor'): the @keiro_workflow_steps@ index is keyed by
-- @(workflow_id, step_name)@ and the unfinished-workflow discovery query groups by
-- @workflow_id@ alone, so a parent and child sharing an id would let the child's
-- terminal marker mask the parent's incompleteness. Suffixing the order id keeps
-- the child's journal (@wf:ship-order-\<order\>-ship@) independent.
shipChildId :: OrderId -> WorkflowId
shipChildId orderId = WorkflowId (orderIdText orderId <> "-ship")

-- | The inverse of 'workflowIdFor': recover the 'OrderId' a workflow instance
-- belongs to from its 'WorkflowId'. Total and obvious, so the
-- 'jitsureiWorkflowRegistry' can rebuild a workflow body from its id alone.
-- (The @ship-order@ child reconstructs an order id carrying the @-ship@ suffix,
-- which only flavours its display tracking number — the child's correctness
-- does not depend on the exact order id.)
orderIdFromWf :: WorkflowId -> OrderId
orderIdFromWf = OrderId . unWorkflowId

-- ---------------------------------------------------------------------------
-- The payment webhook payload
-- ---------------------------------------------------------------------------

-- | The payload an external payment webhook delivers through
-- 'Keiro.Workflow.Awakeable.signalAwakeable'. It round-trips through JSON so the
-- awakeable can journal it and the workflow can decode it on a later run.
data PaymentConfirmation = PaymentConfirmation
  { paymentRef :: !Text,
    amountCents :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- ---------------------------------------------------------------------------
-- The workflows
-- ---------------------------------------------------------------------------

-- | Publish the opaque id allocated for the payment webhook.
--
-- The publisher must be idempotent on 'AwakeableId'. A workflow step records
-- its result only after its action returns, so a crash in that window can make
-- publication run again on replay. A real publisher should therefore upsert or
-- deduplicate using the id itself as its key.
type PublishPaymentAwakeable es = AwakeableId -> Eff es ()

-- | The parent order-fulfillment workflow. It runs six durable checkpoints in
-- order so the demo narrative and the journal line up:
--
-- 1. @reserve-inventory@ — a named 'step' whose result is journaled.
-- 2. @cooling-off@ — a durable 'sleepNamed' (a 'keiro_timers' row; the timer
--    worker wakes the workflow).
-- 3. @payment-webhook@ — an 'awakeableNamed' that allocates an opaque id.
-- 4. @publish-payment-webhook-id@ — publishes that actual id through the
--    application callback before the workflow waits. The callback must be
--    idempotent because its action has at-least-once execution across the
--    action-to-journal crash window.
-- 5. The awakeable suspends until an external
--    'Keiro.Workflow.Awakeable.signalAwakeable' delivers a 'PaymentConfirmation').
-- 6. @charge@ and @ship-order@ — a second named 'step', then a child workflow
--    ('spawnChild' followed by 'awaitChild'); its
--    tracking number is the parent's result.
--
-- On replay, a completed checkpoint short-circuits only after its result is
-- durable in the journal. This protects replay from re-running committed work;
-- it does not make an uncommitted external action at-most-once.
orderFulfillmentWorkflow ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  PublishPaymentAwakeable es ->
  OrderId ->
  Eff es Text
orderFulfillmentWorkflow publishPaymentAwakeable orderId = do
  _reservation <- step (StepName "reserve-inventory") (reserveInventory orderId)
  sleepNamed (StepName "cooling-off") coolingOffDelay
  (awakeableId, awaitPayment) <- awakeableNamed (StepName "payment-webhook")
  _publication <-
    step
      (StepName "publish-payment-webhook-id")
      (publishPaymentAwakeable awakeableId)
  payment <- awaitPayment
  _charge <- step (StepName "charge") (chargeCard orderId payment)
  childHandle <- spawnChild shipOrderWorkflowName (shipChildId orderId) (shipOrderWorkflow orderId)
  awaitChild childHandle

-- | The @ship-order@ child workflow: a one-step workflow that produces a
-- shipment tracking number. Spawned and awaited by 'orderFulfillmentWorkflow';
-- driven to completion by the resume worker from 'jitsureiWorkflowRegistry'.
shipOrderWorkflow ::
  (Workflow :> es, IOE :> es) =>
  OrderId ->
  Eff es Text
shipOrderWorkflow orderId =
  step (StepName "create-shipment") (createShipment orderId)

-- ---------------------------------------------------------------------------
-- The "side effects" (deterministic, but they print when they actually run)
-- ---------------------------------------------------------------------------

-- Each action prints a line so the transcript shows exactly /when a step ran/
-- versus /when it was replayed from the journal/ (a replayed step does not run,
-- so it prints nothing). The returned values are derived from the order id, so
-- they are stable across replays.

reserveInventory :: (IOE :> es) => OrderId -> Eff es Text
reserveInventory orderId = do
  let reservation = "RES-" <> orderIdText orderId
  say ("step reserve-inventory ran (reservation " <> reservation <> ")")
  pure reservation

chargeCard :: (IOE :> es) => OrderId -> PaymentConfirmation -> Eff es Text
chargeCard orderId payment = do
  let chargeId = "CHG-" <> orderIdText orderId
  say
    ( "step charge ran (charge "
        <> chargeId
        <> " for "
        <> paymentRef payment
        <> ")"
    )
  pure chargeId

createShipment :: (IOE :> es) => OrderId -> Eff es Text
createShipment orderId = do
  let tracking = "TRK-" <> orderIdText orderId
  say ("child step create-shipment ran (tracking " <> tracking <> ")")
  pure tracking

-- | Print an indented, flushed line from inside a workflow step, so the
-- interleaving with the demo driver's banners is faithful in the transcript.
say :: (IOE :> es) => Text -> Eff es ()
say msg = liftIO (putStrLn ("  " <> Text.unpack msg) >> hFlush stdout)

-- ---------------------------------------------------------------------------
-- The resume registry
-- ---------------------------------------------------------------------------

-- | Build the application-supplied registry the resume worker
-- ('Keiro.Workflow.Resume.resumeWorkflowsOnce') re-invokes through. It maps each
-- workflow /name/ to a 'WorkflowDef' that rebuilds the workflow body from its id
-- alone, using 'orderIdFromWf' to recover the 'OrderId'. Both the parent and the
-- @ship-order@ child must be registered: the worker discovers the freshly-spawned
-- zero-step child and drives it to completion, which wakes the awaiting parent.
jitsureiWorkflowRegistryWith ::
  (Store :> es, IOE :> es) =>
  PublishPaymentAwakeable es ->
  WorkflowRegistry es
jitsureiWorkflowRegistryWith publishPaymentAwakeable =
  Map.fromList
    [ ( orderFulfillmentWorkflowName,
        WorkflowDef
          ( \wid ->
              orderFulfillmentWorkflow
                (raise . publishPaymentAwakeable)
                (orderIdFromWf wid)
          )
      ),
      (shipOrderWorkflowName, WorkflowDef (\wid -> shipOrderWorkflow (orderIdFromWf wid)))
    ]

-- | A convenience registry for demos that do not install an application
-- publisher. It visibly logs the real allocated id; production applications
-- should use 'jitsureiWorkflowRegistryWith' and durably hand the id to the
-- external system that will later signal it.
jitsureiWorkflowRegistry :: (Store :> es, IOE :> es) => WorkflowRegistry es
jitsureiWorkflowRegistry =
  jitsureiWorkflowRegistryWith $ \awakeableId ->
    say ("published payment-webhook awakeable id: " <> awakeableIdText awakeableId)
