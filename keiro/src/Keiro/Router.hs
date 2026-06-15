{- | Stateless, content-based routing of events to commands.

A 'Router' is the stateless sibling of
'Keiro.ProcessManager.ProcessManager': for each incoming event it resolves
a data-dependent set of target streams /effectfully/ (typically via a
read-model query) and dispatches one command to each. Dispatch is
exactly-once-per-target by construction — every command is appended under a
deterministic id and store-level duplicate rejections are folded into a
benign 'PMCommandDuplicate' — so replaying a source event writes nothing
new.

Use 'runRouterOnce' to dispatch a single event, or 'runRouterWorker' to run
the router as a live subscription draining a Shibuya adapter.
-}
module Keiro.Router (
    -- * Definition
    Router (..),
    RouterResult (..),

    -- * Running
    runRouterOnce,
    runRouterWorkerWith,
    runRouterWorker,
)
where

import Data.Coerce (coerce)
import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, tryError)
import GHC.Stack (HasCallStack)
import Keiki.Core (BoolAlg, RegFile)
import Keiro.Command (CommandError (..), RunCommandOptions)
import Keiro.EventStream (EventStream)
import Keiro.Prelude
import Keiro.ProcessManager (
    PMCommand (..),
    PMCommandResult (..),
    PoisonPolicy (..),
    WorkerOptions (..),
    ackForCommandError,
    defaultWorkerOptions,
    deterministicCommandId,
    eventAlreadyIn,
    isTransientCommandError,
 )
import Keiro.Projection (InlineProjection, runCommandWithProjections)
import Keiro.Stream (Stream)
import Keiro.Telemetry (recordDispatchDuplicate, recordDispatchFailed, recordDispatchPoison)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError (..))
import Kiroku.Store.Types (RecordedEvent)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), HaltReason (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..))
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Streamly
import Prelude (any, filter, fromIntegral, length, not, zip)

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

Each dispatch also runs 'targetProjections' for the target aggregate in the same
append transaction. The function receives the concrete target stream so callers can
build projections closed over stream-local keys. Return @[]@ to preserve
append-only dispatch.
-}
data Router input targetPhi targetRs targetState targetCi targetCo es = Router
    { name :: !Text
    -- ^ Stable identifier; part of every dispatched command's deterministic id.
    , key :: !(input -> Text)
    -- ^ Correlation string for the source event (e.g. the transaction id).
    , resolve :: !(input -> Eff es [PMCommand targetCi])
    {- ^ The effectful seam: compute the data-dependent target set, typically
    @runQuery readModel q@.
    -}
    , targetEventStream :: !(EventStream targetPhi targetRs targetState targetCi targetCo)
    -- ^ The aggregate every resolved command is dispatched to.
    , targetProjections :: !(Stream targetCi -> [InlineProjection targetCo])
    {- ^ Inline projections for the target aggregate, run in the same transaction
    as each dispatched command's append. Return @[]@ for append-only dispatch.
    -}
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
'Keiro.Projection.runCommandWithProjections' and fold a @DuplicateEvent@
rejection into 'PMCommandDuplicate'.

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
                outcome <-
                    runCommandWithProjections
                        targetOptions
                        targetEventStream
                        targetStream
                        (command ^. #command)
                        ((router ^. #targetProjections) (command ^. #target))
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

  * a message that fails to decode follows the configured 'PoisonPolicy'
    (default: 'AckHalt' @HaltFatal@);
  * otherwise, after dispatch, if every 'PMCommandResult' is
    'PMCommandAppended' or 'PMCommandDuplicate' the message finalizes 'AckOk';
  * if any dispatch is 'PMCommandFailed', transient failures finalize
    'AckRetry' and deterministic failures finalize @AckHalt (HaltFatal …)@.

Benign domain rejections (a target aggregate refusing a "check" command because
no edge matches) must be modeled as /total/ transitions in the keiki transducer
(an ε-complement self-loop) so they never surface as 'PMCommandFailed' and
therefore never wedge the worker.

The worker invokes each ingested message's 'Shibuya.Core.AckHandle.AckHandle'
@finalize@ exactly once with the decision, so the decision reaches the adapter.
Use 'runRouterWorkerWith' to override poison-message handling, transient retry
delay, or dispatch metrics.
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
runRouterWorker =
    runRouterWorkerWith defaultWorkerOptions

runRouterWorkerWith ::
    forall msg input targetPhi targetRs targetState targetCi targetCo es.
    ( HasCallStack
    , IOE :> es
    , Store :> es
    , Error StoreError :> es
    , BoolAlg targetPhi (RegFile targetRs, targetCi)
    , Eq targetCo
    ) =>
    WorkerOptions es msg ->
    RunCommandOptions ->
    Router input targetPhi targetRs targetState targetCi targetCo es ->
    Adapter es msg ->
    (msg -> Maybe (RecordedEvent, input)) ->
    Eff es ()
runRouterWorkerWith workerOptions options router Adapter{source = adapterSource} decodeMessage =
    Streamly.fold Fold.drain
        $ Streamly.mapM handleIngested adapterSource
  where
    handleIngested :: Ingested es msg -> Eff es AckDecision
    handleIngested Ingested{envelope = env@Envelope{payload = message}, ack = AckHandle finalizeAck} = do
        decision <- case decodeMessage message of
            Nothing -> decideForPoison "router worker could not decode message" env
            Just (recorded, input) -> do
                outcome <- tryError @StoreError (runRouterOnce options router recorded input)
                case outcome of
                    Left (_, storeErr) -> do
                        recordDispatchFailed (workerOptions ^. #metrics) 1
                        pure (ackForCommandError (workerOptions ^. #transientRetryDelay) (StoreFailed storeErr))
                    Right (RouterResult results) -> ackDecisionFor results
        finalizeAck decision
        pure decision

    ackDecisionFor :: [PMCommandResult target] -> Eff es AckDecision
    ackDecisionFor results = do
        let duplicateCount = commandDuplicateCount results
            failures = [err | PMCommandFailed err <- results]
        recordDispatchDuplicate (workerOptions ^. #metrics) duplicateCount
        recordDispatchFailed (workerOptions ^. #metrics) (fromIntegral (length failures))
        pure $ case failures of
            [] -> AckOk
            errs
                | any (not . isTransientCommandError) errs ->
                    AckHalt (HaltFatal (Text.pack (show (headDeterministic errs))))
                | otherwise ->
                    AckRetry (workerOptions ^. #transientRetryDelay)

    commandDuplicateCount :: [PMCommandResult target] -> Int64
    commandDuplicateCount =
        fromIntegral . length . filter isDuplicateResult
      where
        isDuplicateResult = \case
            PMCommandDuplicate{} -> True
            _ -> False

    headDeterministic :: [CommandError] -> CommandError
    headDeterministic errs =
        case filter (not . isTransientCommandError) errs of
            err : _ -> err
            [] -> case errs of
                err : _ -> err
                [] -> CommandRejected

    decideForPoison :: Text -> Envelope msg -> Eff es AckDecision
    decideForPoison reason env = do
        recordDispatchPoison (workerOptions ^. #metrics) 1
        case workerOptions ^. #poisonPolicy of
            PoisonHalt -> pure (AckHalt (HaltFatal reason))
            PoisonSkip callback -> do
                callback env
                pure AckOk
            PoisonDeadLetter callback -> do
                callback env
                pure (AckDeadLetter (InvalidPayload reason))
