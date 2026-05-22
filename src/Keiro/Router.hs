module Keiro.Router
  ( Router (..)
  , RouterResult (..)
  , runRouterOnce
  , runRouterWorker
  )
where

import Data.Coerce (coerce)
import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import GHC.Stack (HasCallStack)
import Keiki.Core (BoolAlg, RegFile)
import Keiro.Command (CommandError (..), RunCommandOptions, runCommand)
import Keiro.EventStream (EventStream)
import Keiro.Prelude
import Keiro.ProcessManager (PMCommand (..), PMCommandResult (..), deterministicCommandId, eventAlreadyIn)
import Keiro.Stream (Stream)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError (..))
import Kiroku.Store.Types (RecordedEvent)
import Prelude (zip)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..))
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Streamly

{- | A stateless, content-based router (in the Enterprise Integration Patterns
sense): for each incoming event it resolves a data-dependent set of target
streams /effectfully/ and dispatches one command to each.

This is the stateless counterpart of 'Keiro.ProcessManager.ProcessManager'. It
has no manager state stream, no @correlate@, and no self-directed command. Its
sole new capability over the process manager is that target resolution runs in
@Eff es@ — typically a read-model query via 'Keiro.ReadModel.runQuery' — so the
fan-out set can be /looked up/ rather than computed purely from the event.

Dispatch is idempotent by construction: each target command is appended under a
deterministic identifier derived from @(name, key input, source event id, emit
index)@ (see 'deterministicCommandId'), pre-checked with 'eventAlreadyIn', and
the store's @DuplicateEvent@ rejection is treated as a benign duplicate. Replay
of the same source event therefore writes no new events.
-}
data Router input targetPhi targetRs targetState targetCi targetCo es = Router
  { name :: !Text
  -- ^ Stable identifier; part of every dispatched command's deterministic id.
  , key :: !(input -> Text)
  -- ^ Correlation string for the source event (e.g. the transaction id).
  , resolve :: !(input -> Eff es [PMCommand targetCi])
  -- ^ The effectful seam: compute the data-dependent target set, typically
  --   @runQuery readModel q@.
  , targetEventStream :: !(EventStream targetPhi targetRs targetState targetCi targetCo)
  -- ^ The aggregate every resolved command is dispatched to.
  }
  deriving stock (Generic)

{- | The outcome of a single 'runRouterOnce' invocation: one
'PMCommandResult' per resolved target, in resolution order.

Unlike 'Keiro.ProcessManager.ProcessManagerResult' there is no manager-state
result, because a router has no state stream. A failed dispatch surfaces as a
'PMCommandFailed' element rather than an outer 'Either'.
-}
newtype RouterResult target = RouterResult
  { commandResults :: [PMCommandResult target]
  }
  deriving stock (Generic, Eq, Show)

{- | Resolve the targets for one source event, then dispatch one command per
target with the same crash-safe, exactly-once-per-target idempotency the
process manager provides.

The dispatch logic per target is identical to
'Keiro.ProcessManager.runProcessManagerOnce''s @dispatchCommand@: derive a
deterministic command id, skip if 'eventAlreadyIn' the target stream, otherwise
'runCommand' and fold a @DuplicateEvent@ rejection into 'PMCommandDuplicate'.

Returns 'RouterResult' directly (no outer @Either CommandError@) because — unlike
the process manager — there is no manager-state append that can fail before
dispatch.
-}
runRouterOnce ::
  forall input targetPhi targetRs targetState targetCi targetCo es.
  ( HasCallStack
  , IOE :> es
  , Store :> es
  , Error StoreError :> es
  , BoolAlg targetPhi (RegFile targetRs, targetCi)
  , Eq targetCo
  ) =>
  RunCommandOptions ->
  Router input targetPhi targetRs targetState targetCi targetCo es ->
  RecordedEvent ->
  input ->
  Eff es (RouterResult (EventStream targetPhi targetRs targetState targetCi targetCo))
runRouterOnce options router sourceEvent input = do
  let correlationId = (router ^. #key) input
  commands <- (router ^. #resolve) input
  results <-
    traverse
      (\(emitIndex, command) -> dispatchCommand correlationId (sourceEvent ^. #eventId) emitIndex command)
      (zip [0 ..] commands)
  pure (RouterResult results)
  where
    dispatchCommand correlationId sourceEventId emitIndex command = do
      let commandId = deterministicCommandId (router ^. #name) correlationId sourceEventId emitIndex
          targetOptions = options & #eventIds .~ [commandId]
          targetEventStream = router ^. #targetEventStream
          targetStream = retarget (command ^. #target)
          targetStreamName = (targetEventStream ^. #resolveStreamName) targetStream
      commandAlreadyProcessed <- eventAlreadyIn options targetStreamName commandId
      if commandAlreadyProcessed
        then pure (PMCommandDuplicate commandId)
        else do
          outcome <- runCommand targetOptions targetEventStream targetStream (command ^. #command)
          pure $ case outcome of
            Right result -> PMCommandAppended result
            Left (StoreFailed (DuplicateEvent (Just duplicateId))) | duplicateId == commandId -> PMCommandDuplicate commandId
            Left (StoreFailed (DuplicateEvent Nothing)) -> PMCommandDuplicate commandId
            Left err -> PMCommandFailed err

    retarget :: Stream targetCi -> Stream (EventStream targetPhi targetRs targetState targetCi targetCo)
    retarget = coerce

{- | Run a 'Router' as a live subscription over a Shibuya 'Adapter'.

Mirrors 'Keiro.ProcessManager.runProcessManagerWorker': it drains the adapter's
message stream, decoding each message to a @(RecordedEvent, input)@ pair and
dispatching it through 'runRouterOnce'.

Ack policy (see this plan's Decision Log):

  * a message that fails to decode finalizes 'AckHalt' (@HaltFatal@);
  * otherwise, after dispatch, if every 'PMCommandResult' is
    'PMCommandAppended' or 'PMCommandDuplicate' the message finalizes 'AckOk';
  * if any dispatch is 'PMCommandFailed' the message finalizes
    @AckHalt (HaltFatal …)@ so the source event is retried — idempotent replay
    (deterministic command ids) makes retry safe.

Benign domain rejections (a target aggregate refusing a "check" command because
no edge matches) must be modeled as /total/ transitions in the keiki transducer
(an ε-complement self-loop) so they never surface as 'PMCommandFailed' and
therefore never wedge the worker.

Unlike 'runProcessManagerWorker' — which computes an 'AckDecision' per message
and discards it — this worker invokes the ingested message's
'Shibuya.Core.AckHandle.AckHandle' @finalize@ with the decision, fulfilling the
"called exactly once" ack contract so the decision actually reaches the adapter.
-}
runRouterWorker ::
  forall msg input targetPhi targetRs targetState targetCi targetCo es.
  ( HasCallStack
  , IOE :> es
  , Store :> es
  , Error StoreError :> es
  , BoolAlg targetPhi (RegFile targetRs, targetCi)
  , Eq targetCo
  ) =>
  RunCommandOptions ->
  Router input targetPhi targetRs targetState targetCi targetCo es ->
  Adapter es msg ->
  (msg -> Maybe (RecordedEvent, input)) ->
  Eff es ()
runRouterWorker options router Adapter{source = adapterSource} decodeMessage =
  Streamly.fold Fold.drain $
    Streamly.mapM handleIngested adapterSource
  where
    handleIngested :: Ingested es msg -> Eff es AckDecision
    handleIngested Ingested{envelope = Envelope{payload = message}, ack = AckHandle finalizeAck} = do
      decision <- case decodeMessage message of
        Nothing -> pure (AckHalt (HaltFatal "router worker could not decode message"))
        Just (recorded, input) -> do
          RouterResult results <- runRouterOnce options router recorded input
          pure (ackDecisionFor results)
      finalizeAck decision
      pure decision

    ackDecisionFor :: [PMCommandResult target] -> AckDecision
    ackDecisionFor results =
      case [err | PMCommandFailed err <- results] of
        (err : _) -> AckHalt (HaltFatal (Text.pack (show err)))
        [] -> AckOk
