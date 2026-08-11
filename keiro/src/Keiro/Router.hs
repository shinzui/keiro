-- | Stateless, content-based routing of events to commands.
--
-- A 'Router' is the stateless sibling of
-- 'Keiro.ProcessManager.ProcessManager': for each incoming event it resolves
-- a data-dependent set of target streams /effectfully/ (typically via a
-- read-model query) and dispatches one command to each. Dispatch is
-- idempotent per resolved target identity: every command is appended under a
-- target-name-keyed deterministic id, and store-level duplicate rejections are
-- confirmed against that target before becoming a benign
-- 'PMCommandDuplicate'. Redelivery therefore deduplicates every target resolved
-- again, regardless of target order. Because resolution is effectful, the target
-- set may drift between attempts; dispatches accumulate as the union of those
-- attempts, so callers that require one exact set must keep resolution stable for
-- a source event.
--
-- Use 'runRouterOnce' to dispatch a single event, or 'runRouterWorker' to run
-- the router as a live subscription draining a Shibuya adapter. Its retry and
-- source-event dead-letter contract is the same bounded Kiroku contract described
-- by "Keiro.ProcessManager": five total deliveries by default, followed by a
-- @kiroku.dead_letters@ write and atomic checkpoint advance.
--
-- A router's 'key' can join events from different source streams just as a
-- process manager's @correlate@ function can. The same ordering rule applies:
-- same-stream order is preserved, but different streams have no relative
-- business-order guarantee and may run concurrently under sharding. Keep routed
-- logic order-insensitive; see "Keiro.ProcessManager" for the worked example.
-- Each resolved target command (with its inline projections) commits in its own
-- transaction, so fan-out is idempotent rather than all-target atomic.
module Keiro.Router
  ( -- * Definition
    Router (..),
    RouterResult (..),
    DeclarativeRouter (..),
    DeclarativeRouterResult (..),
    DomainRouter (..),
    DomainRouterResult (..),
    module Keiro.Router.Selection,

    -- * Idempotency
    deterministicRouterCommandId,

    -- * Running
    runRouterOnce,
    runRouterWorkerWith,
    runRouterWorker,
    runDeclarativeRouterOnce,
    runDeclarativeRouterWorkerWith,
    runDeclarativeRouterWorker,
    runDomainRouterOnce,
    runDomainRouterWorkerWith,
    runDomainRouterWorker,
  )
where

import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.Coerce (coerce)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Traversable (mapAccumL)
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, tryError)
import GHC.Stack (HasCallStack)
import Keiki.Core (BoolAlg, RegFile)
import Keiro.Command (CommandError (..), DomainCommandHandler, RunCommandOptions)
import Keiro.DeadLetter (DispatcherKind (..))
import Keiro.EventStream (EventStream)
import Keiro.EventStream.Validate (ValidatedEventStream, unvalidated)
import Keiro.Prelude
import Keiro.ProcessManager
  ( DispatchFailure (..),
    DomainDispatchSummary (..),
    DomainPMCommandResult (..),
    PMCommand (..),
    PMCommandResult (..),
    PoisonPolicy (..),
    WorkerOptions (..),
    ackForCommandError,
    ackForDomainSummary,
    confirmBenignDuplicate,
    decideForFailures,
    defaultWorkerOptions,
    deterministicCommandId,
    eventAlreadyIn,
    summarizeDomainCommandResult,
  )
import Keiro.Projection (InlineProjection, runCommandWithProjections, runDomainCommandWithProjections)
import Keiro.Router.Selection
import Keiro.Stream (Stream)
import Keiro.Telemetry (recordDispatchDuplicate, recordDispatchFailed, recordDispatchPoison)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError (..))
import Kiroku.Store.Types (EventId (..), RecordedEvent, StreamName (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), HaltReason (..), renderDeadLetterReason)
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Attempt (..), Envelope (..))
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Streamly
import Prelude (fromIntegral, length, reverse, seq, snd, zip, (+))

-- | A stateless, content-based router (in the Enterprise Integration Patterns
-- sense): for each incoming event it resolves a data-dependent set of target
-- streams /effectfully/ and dispatches one command to each.
--
-- This is the stateless counterpart of 'Keiro.ProcessManager.ProcessManager'. It
-- has no manager state stream, no @correlate@, and no self-directed command. Its
-- sole new capability over the process manager is that target resolution runs in
-- @Eff es@ — typically a read-model query via 'Keiro.ReadModel.runQuery' — so the
-- fan-out set can be /looked up/ rather than computed purely from the event.
--
-- Dispatch is idempotent by construction: each target command is appended under a
-- deterministic identifier derived from @(name, key input, source event id,
-- resolved target stream name, occurrence)@ (see
-- 'deterministicRouterCommandId'), pre-checked with 'eventAlreadyIn', and the
-- store's @DuplicateEvent@ rejection is confirmed against the target stream
-- before it is treated as benign. A redelivery deduplicates every target it
-- resolves again even if target order or membership changed. A target resolved
-- only on an earlier attempt keeps its immutable dispatch, and a newly resolved
-- target is dispatched on the later attempt; the cumulative set is therefore the
-- union of attempt outputs. Keep 'resolve' stable for a source event when the
-- exact recipient set matters.
--
-- Each dispatch also runs 'targetProjections' for the target aggregate in the same
-- append transaction. The function receives the concrete target stream so callers can
-- build projections closed over stream-local keys. Return @[]@ to preserve
-- append-only dispatch.
data Router input targetPhi targetRs targetState targetCi targetCo es = Router
  { -- | Stable identifier; part of every dispatched command's deterministic id.
    name :: !Text,
    -- | Correlation string for the source event (e.g. the transaction id).
    key :: !(input -> Text),
    -- | The effectful seam: compute the data-dependent target set, typically
    --     @runQuery readModel q@.
    resolve :: !(input -> Eff es [PMCommand targetCi]),
    -- | The aggregate every resolved command is dispatched to.
    targetEventStream :: !(ValidatedEventStream targetPhi targetRs targetState targetCi targetCo),
    -- | Inline projections for the target aggregate, run in the same transaction
    --     as each dispatched command's append. Return @[]@ for append-only dispatch.
    targetProjections :: !(Stream targetCi -> [InlineProjection targetCo])
  }
  deriving stock (Generic)

-- | A checked, bounded router whose application-owned query seam returns
-- commands under a closed declarative selection contract.
data DeclarativeRouter input targetPhi targetRs targetState targetCi targetCo es = DeclarativeRouter
  { name :: !Text,
    key :: !(input -> Text),
    selectionContract :: !RouterSelectionContract,
    select :: !(input -> Eff es (Either RouterSelectionFailure [PMCommand targetCi])),
    targetEventStream :: !(ValidatedEventStream targetPhi targetRs targetState targetCi targetCo),
    targetProjections :: !(Stream targetCi -> [InlineProjection targetCo])
  }
  deriving stock (Generic)

-- | Stateless router whose target aggregate returns typed domain decisions.
data DomainRouter input targetPhi targetRs targetState targetCi targetCo rejection noOp es = DomainRouter
  { name :: !Text,
    key :: !(input -> Text),
    resolve :: !(input -> Eff es [PMCommand targetCi]),
    targetHandler :: !(DomainCommandHandler targetPhi targetRs targetState targetCi targetCo rejection noOp),
    targetProjections :: !(Stream targetCi -> [InlineProjection targetCo])
  }
  deriving stock (Generic)

-- | The outcome of a single 'runRouterOnce' invocation: one
-- 'PMCommandResult' per resolved target, in resolution order.
--
-- Unlike 'Keiro.ProcessManager.ProcessManagerResult' there is no manager-state
-- result, because a router has no state stream. A failed dispatch surfaces as a
-- 'PMCommandFailed' element rather than an outer 'Either'.
newtype RouterResult target = RouterResult
  { commandResults :: [PMCommandResult target]
  }
  deriving stock (Generic, Eq, Show)

-- | Pre-dispatch selection outcomes stay distinct from target dispatch
-- outcomes so worker policy cannot accidentally acknowledge a failed query or
-- evaluation as an empty successful query.
data DeclarativeRouterResult target
  = DeclarativeSelectionFailed !RouterSelectionFailure
  | DeclarativeSelectionEmpty
  | DeclarativeSelectionDispatched !(RouterResult target)
  deriving stock (Generic, Eq, Show)

-- | Detailed result of one domain router invocation. Accepted handled entries
-- retain their event batches. Worker entry points use a strict payload-free
-- summary instead of constructing this list.
newtype DomainRouterResult target co rejection noOp = DomainRouterResult
  { commandResults :: [DomainPMCommandResult target co rejection noOp]
  }
  deriving stock (Generic, Eq, Show)

-- | Derive a stable, collision-resistant 'EventId' for a router dispatch from
-- @(router name, key input, source event id, resolved target stream name,
-- occurrence)@ via a v5 UUID.
--
-- Unlike 'Keiro.ProcessManager.deterministicCommandId' (which the process manager
-- still uses, soundly, because its command list is a pure function of the input),
-- the router keys the id by the target's identity rather than its position in the
-- resolved list: 'resolve' is effectful, so a redelivery may see the same targets
-- in a different order or a drifted set, and a positional id would then point at
-- the wrong target. The @occurrence@ is the index among commands in the same
-- resolve batch that address the same target stream (0 for the first), so
-- resolving the same target twice in one batch still yields distinct ids.
--
-- The v5 name encodes every text field as length-prefixed UTF-8. This avoids both
-- delimiter ambiguity when names contain colons and character truncation for
-- non-ASCII names.
deterministicRouterCommandId :: Text -> Text -> EventId -> StreamName -> Int -> EventId
deterministicRouterCommandId routerName correlationId sourceEventId targetStreamName occurrence =
  EventId
    $ UUID.V5.generateNamed UUID.V5.namespaceURL
    $ ByteString.unpack
    $ ByteString.concat
    $ fmap
      encodeField
      [ "keiro",
        "router",
        routerName,
        correlationId,
        UUID.toText (coerce sourceEventId),
        coerce targetStreamName,
        Text.pack (show occurrence)
      ]
  where
    encodeField field =
      let bytes = Text.Encoding.encodeUtf8 field
       in ByteString.concat
            [ ByteString.Char8.pack (show (ByteString.length bytes)),
              ByteString.singleton 58,
              bytes
            ]

-- | Resolve the targets for one source event, then dispatch one command per
-- target with crash-safe, target-identity idempotency.
--
-- Unlike 'Keiro.ProcessManager.runProcessManagerOnce', whose pure command list
-- can safely use positional ids, a router derives each id from the resolved
-- target stream name and its same-stream occurrence. It skips ids already in the
-- target stream, otherwise runs 'Keiro.Projection.runCommandWithProjections', and
-- folds a @DuplicateEvent@ rejection only after confirming the attempted id is in
-- that target stream.
--
-- Returns 'RouterResult' directly (no outer @Either CommandError@) because — unlike
-- the process manager — there is no manager-state append that can fail before
-- dispatch.
runRouterOnce ::
  forall input targetPhi targetRs targetState targetCi targetCo es.
  ( HasCallStack,
    IOE :> es,
    Store :> es,
    Error StoreError :> es,
    KirokuStoreResource :> es,
    BoolAlg targetPhi (RegFile targetRs, targetCi),
    Eq targetCo
  ) =>
  RunCommandOptions ->
  Router input targetPhi targetRs targetState targetCi targetCo es ->
  RecordedEvent ->
  input ->
  Eff es (RouterResult (EventStream targetPhi targetRs targetState targetCi targetCo))
runRouterOnce options router sourceEvent input = do
  commands <- (router ^. #resolve) input
  dispatchRouterCommands
    options
    (router ^. #name)
    (router ^. #targetEventStream)
    (router ^. #targetProjections)
    ((router ^. #key) input)
    (sourceEvent ^. #eventId)
    commands

dispatchRouterCommands ::
  forall targetPhi targetRs targetState targetCi targetCo es.
  ( HasCallStack,
    IOE :> es,
    Store :> es,
    Error StoreError :> es,
    KirokuStoreResource :> es,
    BoolAlg targetPhi (RegFile targetRs, targetCi),
    Eq targetCo
  ) =>
  RunCommandOptions ->
  Text ->
  ValidatedEventStream targetPhi targetRs targetState targetCi targetCo ->
  (Stream targetCi -> [InlineProjection targetCo]) ->
  Text ->
  EventId ->
  [PMCommand targetCi] ->
  Eff es (RouterResult (EventStream targetPhi targetRs targetState targetCi targetCo))
dispatchRouterCommands options routerName targetEventStream targetProjections correlationId sourceEventId commands = do
  let named =
        [ (streamNameOf command, command)
        | command <- commands
        ]
      annotated = snd (mapAccumL occurrenceStep Map.empty (zip [0 ..] named))
      occurrenceStep seen (legacyIndex, (targetStreamName, command)) =
        let occurrence = Map.findWithDefault 0 targetStreamName seen
         in ( Map.insert targetStreamName (occurrence + 1) seen,
              (legacyIndex, occurrence, targetStreamName, command)
            )
  results <-
    traverse
      dispatchCommand
      annotated
  pure (RouterResult results)
  where
    streamNameOf command =
      ((unvalidated targetEventStream) ^. #resolveStreamName)
        (retarget (command ^. #target))

    dispatchCommand (legacyIndex, occurrence, targetStreamName, command) = do
      let commandId =
            deterministicRouterCommandId
              routerName
              correlationId
              sourceEventId
              targetStreamName
              occurrence
          -- Transition: dispatches written by keiro versions that derived
          -- positional ids must still dedup across the upgrade. Remove in a
          -- later release after the compatibility window closes.
          legacyCommandId =
            deterministicCommandId
              routerName
              correlationId
              sourceEventId
              legacyIndex
          targetOptions = options & #eventIds .~ [commandId]
          targetStream = retarget (command ^. #target)
      commandAlreadyProcessed <- eventAlreadyIn options targetStreamName commandId
      legacyAlreadyProcessed <-
        if commandAlreadyProcessed
          then pure False
          else eventAlreadyIn options targetStreamName legacyCommandId
      if commandAlreadyProcessed
        then pure (PMCommandDuplicate commandId)
        else
          if legacyAlreadyProcessed
            then pure (PMCommandDuplicate legacyCommandId)
            else do
              outcome <-
                runCommandWithProjections
                  targetOptions
                  targetEventStream
                  targetStream
                  (command ^. #command)
                  (targetProjections (command ^. #target))
              case outcome of
                Right result -> pure (PMCommandAppended result)
                Left err -> do
                  benign <- confirmBenignDuplicate targetStreamName commandId err
                  pure $ if benign then PMCommandDuplicate commandId else PMCommandFailed targetStreamName err

    retarget :: Stream targetCi -> Stream (EventStream targetPhi targetRs targetState targetCi targetCo)
    retarget = coerce

-- | Evaluate and normalize one declarative selection before performing any
-- target write. Conflict and overflow therefore have an all-or-nothing
-- pre-dispatch boundary; target dispatch itself retains legacy per-target
-- idempotency and partial-success recovery.
runDeclarativeRouterOnce ::
  forall input targetPhi targetRs targetState targetCi targetCo es.
  ( HasCallStack,
    IOE :> es,
    Store :> es,
    Error StoreError :> es,
    KirokuStoreResource :> es,
    BoolAlg targetPhi (RegFile targetRs, targetCi),
    Eq targetCi,
    Eq targetCo
  ) =>
  RunCommandOptions ->
  DeclarativeRouter input targetPhi targetRs targetState targetCi targetCo es ->
  RecordedEvent ->
  input ->
  Eff es (DeclarativeRouterResult (EventStream targetPhi targetRs targetState targetCi targetCo))
runDeclarativeRouterOnce options router sourceEvent input = do
  selected <- (router ^. #select) input
  case selected >>= normalizeRecipients ((router ^. #selectionContract) ^. #limit) of
    Left failure -> pure (DeclarativeSelectionFailed failure)
    Right [] -> pure DeclarativeSelectionEmpty
    Right commands ->
      DeclarativeSelectionDispatched
        <$> dispatchRouterCommands
          options
          (router ^. #name)
          (router ^. #targetEventStream)
          (router ^. #targetProjections)
          ((router ^. #key) input)
          (sourceEvent ^. #eventId)
          commands

-- | Detailed domain-aware router invocation. Typed rejection/no-op is handled,
-- accepted carries the exact event batch, and deterministic accepted
-- redelivery is a distinct duplicate because the original batch cannot be
-- reconstructed from its event id.
runDomainRouterOnce ::
  forall input targetPhi targetRs targetState targetCi targetCo rejection noOp es.
  ( HasCallStack,
    IOE :> es,
    Store :> es,
    Error StoreError :> es,
    KirokuStoreResource :> es,
    BoolAlg targetPhi (RegFile targetRs, targetCi),
    Eq targetCo
  ) =>
  RunCommandOptions ->
  DomainRouter input targetPhi targetRs targetState targetCi targetCo rejection noOp es ->
  RecordedEvent ->
  input ->
  Eff es (DomainRouterResult (EventStream targetPhi targetRs targetState targetCi targetCo) targetCo rejection noOp)
runDomainRouterOnce options router sourceEvent input = do
  annotated <- resolveDomainRouterCommands router input
  results <-
    traverse
      (dispatchDomainRouterCommand options router ((router ^. #key) input) (sourceEvent ^. #eventId))
      annotated
  pure (DomainRouterResult results)

resolveDomainRouterCommands ::
  forall input targetPhi targetRs targetState targetCi targetCo rejection noOp es.
  DomainRouter input targetPhi targetRs targetState targetCi targetCo rejection noOp es ->
  input ->
  Eff es [(Int, Int, StreamName, PMCommand targetCi)]
resolveDomainRouterCommands router input = do
  commands <- (router ^. #resolve) input
  let named =
        [ (streamNameOf command, command)
        | command <- commands
        ]
  pure (snd (mapAccumL occurrenceStep Map.empty (zip [0 ..] named)))
  where
    occurrenceStep seen (legacyIndex, (targetStreamName, command)) =
      let occurrence = Map.findWithDefault 0 targetStreamName seen
       in ( Map.insert targetStreamName (occurrence + 1) seen,
            (legacyIndex, occurrence, targetStreamName, command)
          )

    streamNameOf command =
      let targetEventStream = (router ^. #targetHandler) ^. #eventStream
       in ((unvalidated targetEventStream) ^. #resolveStreamName)
            (retarget (command ^. #target))

    retarget :: Stream targetCi -> Stream (EventStream targetPhi targetRs targetState targetCi targetCo)
    retarget = coerce

dispatchDomainRouterCommand ::
  forall input targetPhi targetRs targetState targetCi targetCo rejection noOp es.
  ( HasCallStack,
    IOE :> es,
    Store :> es,
    Error StoreError :> es,
    KirokuStoreResource :> es,
    BoolAlg targetPhi (RegFile targetRs, targetCi),
    Eq targetCo
  ) =>
  RunCommandOptions ->
  DomainRouter input targetPhi targetRs targetState targetCi targetCo rejection noOp es ->
  Text ->
  EventId ->
  (Int, Int, StreamName, PMCommand targetCi) ->
  Eff es (DomainPMCommandResult (EventStream targetPhi targetRs targetState targetCi targetCo) targetCo rejection noOp)
dispatchDomainRouterCommand options router correlationId sourceEventId (legacyIndex, occurrence, targetStreamName, command) = do
  let commandId =
        deterministicRouterCommandId
          (router ^. #name)
          correlationId
          sourceEventId
          targetStreamName
          occurrence
      legacyCommandId =
        deterministicCommandId
          (router ^. #name)
          correlationId
          sourceEventId
          legacyIndex
      targetOptions = options & #eventIds .~ [commandId]
      handler = router ^. #targetHandler
      targetStream = retarget (command ^. #target)
  commandAlreadyProcessed <- eventAlreadyIn options targetStreamName commandId
  legacyAlreadyProcessed <-
    if commandAlreadyProcessed
      then pure False
      else eventAlreadyIn options targetStreamName legacyCommandId
  if commandAlreadyProcessed
    then pure (DomainPMCommandDuplicate commandId)
    else
      if legacyAlreadyProcessed
        then pure (DomainPMCommandDuplicate legacyCommandId)
        else do
          outcome <-
            runDomainCommandWithProjections
              targetOptions
              handler
              targetStream
              (command ^. #command)
              ((router ^. #targetProjections) (command ^. #target))
          case outcome of
            Right result -> pure (DomainPMCommandHandled result)
            Left err -> do
              benign <- confirmBenignDuplicate targetStreamName commandId err
              pure
                ( if benign
                    then DomainPMCommandDuplicate commandId
                    else DomainPMCommandFailed targetStreamName err
                )
  where
    retarget :: Stream targetCi -> Stream (EventStream targetPhi targetRs targetState targetCi targetCo)
    retarget = coerce

foldDomainRouterSummary ::
  forall input targetPhi targetRs targetState targetCi targetCo rejection noOp es.
  ( HasCallStack,
    IOE :> es,
    Store :> es,
    Error StoreError :> es,
    KirokuStoreResource :> es,
    BoolAlg targetPhi (RegFile targetRs, targetCi),
    Eq targetCo
  ) =>
  RunCommandOptions ->
  DomainRouter input targetPhi targetRs targetState targetCi targetCo rejection noOp es ->
  Text ->
  EventId ->
  [(Int, Int, StreamName, PMCommand targetCi)] ->
  Eff es DomainDispatchSummary
foldDomainRouterSummary options router correlationId sourceEventId = go (DomainDispatchSummary 0 [])
  where
    go summary = \case
      [] -> pure summary {failures = reverse (summary ^. #failures)}
      annotated@(emitIndex, _, _, _) : rest -> do
        result <- dispatchDomainRouterCommand options router correlationId sourceEventId annotated
        let next = summarizeDomainCommandResult emitIndex result summary
        next `seq` go next rest

-- | Domain-aware router worker with default policy. Handled payloads are
-- released target-by-target through a strict summary fold.
runDomainRouterWorker ::
  forall msg input targetPhi targetRs targetState targetCi targetCo rejection noOp es.
  ( HasCallStack,
    IOE :> es,
    Store :> es,
    Error StoreError :> es,
    KirokuStoreResource :> es,
    BoolAlg targetPhi (RegFile targetRs, targetCi),
    Eq targetCo
  ) =>
  RunCommandOptions ->
  DomainRouter input targetPhi targetRs targetState targetCi targetCo rejection noOp es ->
  Adapter es msg ->
  (msg -> Maybe (RecordedEvent, input)) ->
  Eff es ()
runDomainRouterWorker = runDomainRouterWorkerWith defaultWorkerOptions

-- | Configurable domain-aware router worker. Selected rejection/no-op maps to
-- normal handling and bypasses rejection policy; only 'CommandError' failures
-- are summarized for acknowledgement policy.
runDomainRouterWorkerWith ::
  forall msg input targetPhi targetRs targetState targetCi targetCo rejection noOp es.
  ( HasCallStack,
    IOE :> es,
    Store :> es,
    Error StoreError :> es,
    KirokuStoreResource :> es,
    BoolAlg targetPhi (RegFile targetRs, targetCi),
    Eq targetCo
  ) =>
  WorkerOptions es msg ->
  RunCommandOptions ->
  DomainRouter input targetPhi targetRs targetState targetCi targetCo rejection noOp es ->
  Adapter es msg ->
  (msg -> Maybe (RecordedEvent, input)) ->
  Eff es ()
runDomainRouterWorkerWith workerOptions options router Adapter {source = adapterSource} decodeMessage =
  Streamly.fold Fold.drain
    $ Streamly.mapM handleIngested adapterSource
  where
    handleIngested :: Ingested es msg -> Eff es AckDecision
    handleIngested Ingested {envelope = env@Envelope {payload = message}, ack = AckHandle finalizeAck} = do
      decision <- case decodeMessage message of
        Nothing -> decideForPoison "domain router worker could not decode message" env
        Just (recorded, input) -> do
          let correlationId = (router ^. #key) input
              attemptCount = envelopeAttemptCount env
          outcome <- tryError @StoreError $ do
            annotated <- resolveDomainRouterCommands router input
            foldDomainRouterSummary options router correlationId (recorded ^. #eventId) annotated
          case outcome of
            Left (_, storeError) -> do
              recordDispatchFailed (workerOptions ^. #metrics) 1
              pure (ackForCommandError (workerOptions ^. #transientRetryDelay) (StoreFailed storeError))
            Right summary ->
              ackForDomainSummary
                workerOptions
                DispatcherRouter
                (router ^. #name)
                correlationId
                recorded
                attemptCount
                0
                summary
      finalizeAck decision
      pure decision

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

    envelopeAttemptCount env =
      case env ^. #attempt of
        Nothing -> 1
        Just (Attempt attempt) -> fromIntegral attempt + 1

-- | Run a 'Router' as a live subscription over a Shibuya 'Adapter'.
--
-- Mirrors 'Keiro.ProcessManager.runProcessManagerWorker': it drains the adapter's
-- message stream, decoding each message to a @(RecordedEvent, input)@ pair and
-- dispatching it through 'runRouterOnce'.
--
-- Ack policy (see this plan's Decision Log):
--
--   * a message that fails to decode follows the configured 'PoisonPolicy'
--     (default: 'AckHalt' @HaltFatal@);
--   * otherwise, after dispatch, if every 'PMCommandResult' is
--     'PMCommandAppended' or 'PMCommandDuplicate' the message finalizes 'AckOk';
--   * if any dispatch is 'PMCommandFailed', transient failures finalize
--     'AckRetry', systemic deterministic failures finalize @AckHalt
--     (HaltFatal …)@, and rejection-class failures follow
--     'RejectedCommandPolicy'.
--
-- Benign domain rejections (a target aggregate refusing a "check" command because
-- no edge matches) must be modeled as /total/ transitions in the keiki transducer
-- (an ε-complement self-loop) so they never surface as 'PMCommandFailed' and
-- therefore never wedge the worker. When the rejection is genuinely
-- data-dependent, 'RejectedDeadLetter' persists a queryable
-- "Keiro.DeadLetter.DispatchDeadLetter" and acknowledges the source event;
-- 'RejectedSkip' acknowledges and records only the metric. 'RejectedHalt' remains
-- the default.
--
-- The worker invokes each ingested message's 'Shibuya.Core.AckHandle.AckHandle'
-- @finalize@ exactly once with the decision, so the decision reaches the adapter.
-- Use 'runRouterWorkerWith' to override poison-message handling, rejected-command
-- handling, transient retry delay, or dispatch metrics. On a Kiroku-backed
-- adapter, 'AckRetry' remains bounded by the subscription @RetryPolicy@ (five
-- total deliveries by default). Exhaustion records the source event in
-- @kiroku.dead_letters@ with reason kind @max_attempts_exceeded@ and advances the
-- checkpoint. @KirokuAdapterConfig@ does not currently expose @retryPolicy@;
-- install 'Keiro.Telemetry.kirokuEventBridge' on Kiroku's @eventHandler@ to observe
-- the terminal event. The configurable sharded path forwards
-- @ShardedWorkerOptions.retryPolicy@ through the same Kiroku ladder; see
-- "Keiro.Subscription.Shard.Worker".
runRouterWorker ::
  forall msg input targetPhi targetRs targetState targetCi targetCo es.
  ( HasCallStack,
    IOE :> es,
    Store :> es,
    Error StoreError :> es,
    KirokuStoreResource :> es,
    BoolAlg targetPhi (RegFile targetRs, targetCi),
    Eq targetCo
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
  ( HasCallStack,
    IOE :> es,
    Store :> es,
    Error StoreError :> es,
    KirokuStoreResource :> es,
    BoolAlg targetPhi (RegFile targetRs, targetCi),
    Eq targetCo
  ) =>
  WorkerOptions es msg ->
  RunCommandOptions ->
  Router input targetPhi targetRs targetState targetCi targetCo es ->
  Adapter es msg ->
  (msg -> Maybe (RecordedEvent, input)) ->
  Eff es ()
runRouterWorkerWith workerOptions options router Adapter {source = adapterSource} decodeMessage =
  Streamly.fold Fold.drain
    $ Streamly.mapM handleIngested adapterSource
  where
    handleIngested :: Ingested es msg -> Eff es AckDecision
    handleIngested Ingested {envelope = env@Envelope {payload = message}, ack = AckHandle finalizeAck} = do
      decision <- case decodeMessage message of
        Nothing -> decideForPoison "router worker could not decode message" env
        Just (recorded, input) -> do
          let correlationId = (router ^. #key) input
              attemptCount = envelopeAttemptCount env
          outcome <- tryError @StoreError (runRouterOnce options router recorded input)
          case outcome of
            Left (_, storeErr) -> do
              recordDispatchFailed (workerOptions ^. #metrics) 1
              pure (ackForCommandError (workerOptions ^. #transientRetryDelay) (StoreFailed storeErr))
            Right (RouterResult results) ->
              ackForRouterResults workerOptions (router ^. #name) recorded correlationId attemptCount results
      finalizeAck decision
      pure decision

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

    envelopeAttemptCount :: Envelope msg -> Int
    envelopeAttemptCount env =
      case env ^. #attempt of
        Nothing -> 1
        Just (Attempt attempt) -> fromIntegral attempt + 1

ackForRouterResults ::
  (IOE :> es, Store :> es) =>
  WorkerOptions es msg ->
  Text ->
  RecordedEvent ->
  Text ->
  Int ->
  [PMCommandResult target] ->
  Eff es AckDecision
ackForRouterResults workerOptions routerName sourceEvent correlationId attemptCount results = do
  let duplicateCount =
        fromIntegral
          ( length
              [ ()
              | PMCommandDuplicate {} <- results
              ]
          )
      failures =
        [ DispatchFailure emitIndex targetStreamName err
        | (emitIndex, PMCommandFailed targetStreamName err) <- zip [0 ..] results
        ]
  recordDispatchDuplicate (workerOptions ^. #metrics) duplicateCount
  recordDispatchFailed (workerOptions ^. #metrics) (fromIntegral (length failures))
  decideForFailures
    workerOptions
    DispatcherRouter
    routerName
    correlationId
    sourceEvent
    attemptCount
    failures

-- | Declarative router worker using 'defaultWorkerOptions'. Selection
-- empty/failure policies belong to the checked contract; target dispatch
-- failures continue through the ordinary router worker policy.
runDeclarativeRouterWorker ::
  forall msg input targetPhi targetRs targetState targetCi targetCo es.
  ( HasCallStack,
    IOE :> es,
    Store :> es,
    Error StoreError :> es,
    KirokuStoreResource :> es,
    BoolAlg targetPhi (RegFile targetRs, targetCi),
    Eq targetCi,
    Eq targetCo
  ) =>
  RunCommandOptions ->
  DeclarativeRouter input targetPhi targetRs targetState targetCi targetCo es ->
  Adapter es msg ->
  (msg -> Maybe (RecordedEvent, input)) ->
  Eff es ()
runDeclarativeRouterWorker = runDeclarativeRouterWorkerWith defaultWorkerOptions

runDeclarativeRouterWorkerWith ::
  forall msg input targetPhi targetRs targetState targetCi targetCo es.
  ( HasCallStack,
    IOE :> es,
    Store :> es,
    Error StoreError :> es,
    KirokuStoreResource :> es,
    BoolAlg targetPhi (RegFile targetRs, targetCi),
    Eq targetCi,
    Eq targetCo
  ) =>
  WorkerOptions es msg ->
  RunCommandOptions ->
  DeclarativeRouter input targetPhi targetRs targetState targetCi targetCo es ->
  Adapter es msg ->
  (msg -> Maybe (RecordedEvent, input)) ->
  Eff es ()
runDeclarativeRouterWorkerWith workerOptions options router Adapter {source = adapterSource} decodeMessage =
  Streamly.fold Fold.drain
    $ Streamly.mapM handleIngested adapterSource
  where
    contract = router ^. #selectionContract

    handleIngested :: Ingested es msg -> Eff es AckDecision
    handleIngested Ingested {envelope = env@Envelope {payload = message}, ack = AckHandle finalizeAck} = do
      decision <- case decodeMessage message of
        Nothing -> decideForPoison "declarative router worker could not decode message" env
        Just (recorded, input) -> do
          let correlationId = (router ^. #key) input
              attemptCount = envelopeAttemptCount env
          outcome <- tryError @StoreError (runDeclarativeRouterOnce options router recorded input)
          case outcome of
            Left (_, storeErr) -> do
              recordDispatchFailed (workerOptions ^. #metrics) 1
              pure (ackForCommandError (workerOptions ^. #transientRetryDelay) (StoreFailed storeErr))
            Right DeclarativeSelectionEmpty -> pure emptyDecision
            Right (DeclarativeSelectionFailed failure) -> do
              recordDispatchFailed (workerOptions ^. #metrics) 1
              pure (failureDecision failure)
            Right (DeclarativeSelectionDispatched (RouterResult results)) ->
              ackForRouterResults workerOptions (router ^. #name) recorded correlationId attemptCount results
      finalizeAck decision
      pure decision

    emptyDecision = case contract ^. #emptyPolicy of
      EmptyAck -> AckOk
      EmptyRetry -> AckRetry (workerOptions ^. #transientRetryDelay)
      EmptyDeadLetter -> AckDeadLetter (emptySelectionDeadLetterReason contract)
      EmptyHalt -> AckHalt (HaltFatal (renderDeadLetterReason (emptySelectionDeadLetterReason contract)))

    failureDecision failure = case contract ^. #failurePolicy of
      FailureRetry -> AckRetry (workerOptions ^. #transientRetryDelay)
      FailureDeadLetter -> AckDeadLetter (selectionFailureDeadLetterReason contract failure)
      FailureHalt -> AckHalt (HaltFatal (renderDeadLetterReason (selectionFailureDeadLetterReason contract failure)))

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

    envelopeAttemptCount env =
      case env ^. #attempt of
        Nothing -> 1
        Just (Attempt attempt) -> fromIntegral attempt + 1
