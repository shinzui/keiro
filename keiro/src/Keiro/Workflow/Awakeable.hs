{- | Awakeables: durable promises an external system resolves.

== What this gives you

A workflow allocates an opaque 'AwakeableId', hands it to some external system
(a webhook handler, a human approver, an LLM tool call), and suspends until
that system /signals/ the id with a result — no polling, no bespoke
"wait for event X then react in a process manager" wiring.

@
approvalFlow :: ('Workflow' ':>' es, 'Store' ':>' es, 'IOE' ':>' es) => Eff es Text
approvalFlow = do
  (aid, await) <- 'awakeableNamed' (StepName \"approval\")  -- allocate the promise
  -- (hand @aid@ to a webhook handler / human / LLM tool here)
  decision <- await                                       -- SUSPEND until signalled
  'Keiro.Workflow.step' (StepName \"use\") (pure (decision <> \"!\"))
@

The @pending@ row is committed as part of the journaled allocation step,
before the id can be returned or handed to an external system. On the __first__
'Keiro.Workflow.runWorkflow' this returns 'Suspended' (the run parked on
@await@). An external caller later runs
@'signalAwakeable' aid \"ok\"@, which flips the row to @completed@ /and/
appends a @StepRecorded \"awk:\<uuid\>\"@ to the workflow's journal. The
__next__ run replays past the now-resolved @await@ and 'Completed's.

== Contract recap for downstream plans (the v2 MasterPlan)

* 'AwakeableId' is journaled randomness: new allocations generate an opaque v4
  UUID and record it under @awkid:\<label\>@ before awaiting @awk:\<uuid\>@.
  Replay reads the journaled id, so a resumed workflow allocates the same id it
  already handed out without making that id guessable from public coordinates.
* 'awakeableNamed' (caller-supplied label) is the __stable primitive__;
  'awakeable' is an ordinal convenience whose label is positional (a fragile
  derivation across code edits — see its Haddock).
* Awakeables journal their completion as ordinary 'StepRecorded' events under
  the reserved @awk:@ prefix ('Keiro.Workflow.awakeableStepPrefix'), never a
  new event type, so EP-38's replay loop stays uniform.
* 'signalAwakeable' is idempotent /and/ crash-safe: it commits the row update
  and journal append in one transaction for new signals, a double signal
  returns 'False' and does not change the recorded value, and a signal of an
  already-@completed@ awakeable re-appends the journal entry from the stored
  payload to repair historical wedges. A signal that loses a row race to
  cancellation returns 'False' without appending.
* 'cancelAwakeable' abandons a still-@pending@ promise; a workflow that
  re-enters its @await@ then throws 'WorkflowAwakeableCancelled', which the
  author can @catch@ for compensation. If uncaught, EP-42's resume worker
  records an attempt, backs off, and eventually appends 'WorkflowFailed' at the
  configured failure ceiling.
* @countPendingAwakeables@ (in "Keiro.Workflow.Awakeable.Schema") backs EP-44's
  @keiro.workflow.awakeables.pending@ gauge.
-}
module Keiro.Workflow.Awakeable (
    -- * Awakeable ids
    AwakeableId (..),
    awakeableIdToUuid,
    awakeableIdText,
    deterministicAwakeableId,

    -- * Authoring surface (inside a workflow)
    awakeableNamed,
    awakeable,

    -- * External completion (outside a workflow)
    signalAwakeable,
    signalAwakeableFrom,
    cancelAwakeable,

    -- * Errors
    WorkflowAwakeableCancelled (..),
)
where

import Control.Exception (Exception)
import Data.Text qualified as Text
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID.V4
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, (:>))
import Effectful.Exception (throwIO)
import Keiro.Prelude
import Keiro.Workflow (
    JournalAppendOutcome (..),
    StepName (..),
    Workflow,
    WorkflowError (..),
    WorkflowId (..),
    WorkflowJournalEvent (..),
    WorkflowName (..),
    appendJournalEntry,
    awaitStep,
    awakeableAllocStepPrefix,
    awakeableStepPrefix,
    currentGeneration,
    currentRunGeneration,
    currentWorkflow,
    freshOrdinal,
    prepareJournalAppend,
    step,
 )
import Keiro.Workflow.Awakeable.Schema (
    AwakeableRow,
    AwakeableStatus (..),
    cancelAwakeableTx,
    completeAwakeableTx,
    lookupAwakeable,
    lookupAwakeableStatusTx,
    registerAwakeableTx,
 )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import "hasql-transaction" Hasql.Transaction qualified as Tx

-- ---------------------------------------------------------------------------
-- Awakeable ids
-- ---------------------------------------------------------------------------

{- | The opaque id of an awakeable. New allocations are random and journaled by
'awakeableNamed'; 'deterministicAwakeableId' is retained only as a legacy
generation-0 adoption helper. The @ToJSON@\/@FromJSON@ instances are over the
inner UUID, so the workflow journal can replay the id and webhook payloads may
carry it.
-}
newtype AwakeableId = AwakeableId UUID
    deriving stock (Eq, Show, Generic)
    deriving newtype (ToJSON, FromJSON)

-- | The raw UUID inside an 'AwakeableId'.
awakeableIdToUuid :: AwakeableId -> UUID
awakeableIdToUuid (AwakeableId u) = u

{- | The 'AwakeableId' rendered as text — the suffix of the @awk:\<uuid\>@
journal step name an awakeable's completion is recorded under.
-}
awakeableIdText :: AwakeableId -> Text
awakeableIdText = UUID.toText . awakeableIdToUuid

{- | The legacy deterministic 'AwakeableId' for a @(workflow name, workflow id,
label)@: a v5 UUID over @(\"keiro\":\"awakeable\":name:id:label)@.

This is predictable from public coordinates, so new code must not hand-derive
ids with it. It remains exported for operators and for generation-0 adoption:
if a pre-change workflow already registered a row under this id, the first
post-change allocation adopts that row so the in-flight promise keeps working.
-}
deterministicAwakeableId :: WorkflowName -> WorkflowId -> Text -> AwakeableId
deterministicAwakeableId (WorkflowName name) (WorkflowId wid) label =
    AwakeableId $
        UUID.V5.generateNamed UUID.V5.namespaceURL $
            fmap (fromIntegral . fromEnum) $
                Text.unpack $
                    Text.intercalate ":" ["keiro", "awakeable", name, wid, label]

-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------

{- | Thrown out of 'Keiro.Workflow.runWorkflow' when a workflow re-enters the
@await@ of an awakeable that was 'cancelAwakeable'd. A cancelled awakeable will
never be signalled, so suspending forever would be wrong and silently
completing would fabricate a result; the workflow author can @catch@ this to
run compensation. If uncaught, the resume worker records the attempt and
eventually marks the workflow failed at its configured ceiling.
-}
newtype WorkflowAwakeableCancelled = WorkflowAwakeableCancelled AwakeableId
    deriving stock (Eq, Show)

instance Exception WorkflowAwakeableCancelled

-- ---------------------------------------------------------------------------
-- Authoring surface
-- ---------------------------------------------------------------------------

{- | Allocate an awakeable under the stable, caller-supplied @label@. Returns
the 'AwakeableId' (hand it to the external system) and an @await@ action that
'Suspended's the workflow until the awakeable is signalled, then yields the
decoded payload on a later run.

The @label@ is the only fully-deterministic option: it survives code edits that
insert or remove awakeables elsewhere in the workflow (the same robustness
argument EP-38 makes for named steps over positional history). Prefer this over
'awakeable' for anything that may outlive a code change mid-flight.
-}
awakeableNamed ::
    (Workflow :> es, Store :> es, IOE :> es, FromJSON a) =>
    StepName ->
    Eff es (AwakeableId, Eff es a)
awakeableNamed (StepName label) = do
    (name, wid) <- currentWorkflow
    gen <- currentRunGeneration
    aid <-
        step (StepName (awakeableAllocStepPrefix <> label)) $ do
            allocated <- allocateAwakeableId name wid gen label
            runTransaction $
                registerAwakeableTx
                    (awakeableIdToUuid allocated)
                    (unWorkflowName name)
                    (unWorkflowId wid)
            pure allocated
    let
        stepNm = StepName (awakeableStepPrefix <> awakeableIdText aid)
        await = awaitCancellable name wid aid stepNm
    pure (aid, await)

allocateAwakeableId ::
    (Store :> es, IOE :> es) =>
    WorkflowName ->
    WorkflowId ->
    Int ->
    Text ->
    Eff es AwakeableId
allocateAwakeableId name wid gen label
    | gen <= 0 = do
        let legacy = deterministicAwakeableId name wid label
        existing <- lookupAwakeable (awakeableIdToUuid legacy)
        case existing of
            Just _ -> pure legacy
            Nothing -> AwakeableId <$> liftIO UUID.V4.nextRandom
    | otherwise = AwakeableId <$> liftIO UUID.V4.nextRandom

{- | Allocate an awakeable under an ordinal label (the @N@th awakeable in a run
becomes @ord:N@). Convenient, but its determinism is __conditional__: adding or
removing an 'awakeable' call earlier in the workflow shifts every later ordinal
and so changes their derived ids, which corrupts an in-flight workflow exactly
the way EP-38 warns positional history does. Prefer 'awakeableNamed' for
anything that may outlive a code edit.
-}
awakeable ::
    (Workflow :> es, Store :> es, IOE :> es, FromJSON a) =>
    Eff es (AwakeableId, Eff es a)
awakeable = do
    n <- freshOrdinal awakeableStepPrefix
    awakeableNamed (StepName ("ord:" <> Text.pack (show n)))

{- | EP-38's 'awaitStep', wrapped so that a re-entered @await@ on a
'Cancelled' awakeable throws 'WorkflowAwakeableCancelled' instead of suspending
forever. The check lives /inside/ the arming action because 'awaitStep' runs
@arm@ only on the miss path (the awakeable not yet journaled) and re-runs it on
every resume until it resolves: on a miss we either notice the cancel and throw,
or (re-)register the idempotent @pending@ row and suspend. On the hit path
('signalAwakeable' already journaled the result) @arm@ is never run, so a
signalled-then-cancelled race still returns the signalled value (signal wins — a
resolved promise cannot be un-resolved).
-}
awaitCancellable ::
    (Workflow :> es, Store :> es, IOE :> es, FromJSON a) =>
    WorkflowName -> WorkflowId -> AwakeableId -> StepName -> Eff es a
awaitCancellable name wid aid stepNm =
    awaitStep stepNm $ do
        existing <- lookupAwakeable (awakeableIdToUuid aid)
        case existing of
            Just row
                | row ^. #status == Cancelled ->
                    throwIO (WorkflowAwakeableCancelled aid)
                | row ^. #status == Completed
                , Just payload <- row ^. #payload -> do
                    now <- liftIO getCurrentTime
                    appendJournalEntry
                        name
                        wid
                        StepRecorded
                            { stepName = unStepName stepNm
                            , result = payload
                            , recordedAt = now
                            }
            _ ->
                runTransaction $
                    registerAwakeableTx (awakeableIdToUuid aid) (unWorkflowName name) (unWorkflowId wid)

-- ---------------------------------------------------------------------------
-- External completion
-- ---------------------------------------------------------------------------

{- | Resolve an awakeable from outside the workflow: store @result@ in the
@keiro_awakeables@ row /and/ append a @StepRecorded@ to the owning workflow's
journal so the next run replays past the @await@.

Idempotent and crash-safe:

* Returns 'True' only when /this/ call transitioned the row @pending@ ->
  @completed@; a second signal (or a signal of a @cancelled@ row) returns
  'False' and leaves the stored payload unchanged.
* For a @pending@ row, the row transition and journal append happen in one
  transaction. For an already-@completed@ row, the journal entry is re-appended
  from the stored payload to repair rows wedged before that atomic path existed.
  The append path is idempotent (deterministic event id plus step-index check),
  so a re-append collapses to a no-op once the entry is present.
* If a cancellation wins after this function's initial row read but before its
  guarded completion, the transaction re-reads the status and appends nothing.
  The signal returns 'False', so cancellation cannot both trigger compensation
  and leak a completion value into the workflow journal.

A 'False' return therefore does not mean "nothing happened": the journal may
still have been repaired. Returns 'False' for an unknown id.
-}
signalAwakeable :: (IOE :> es, Store :> es, ToJSON r) => AwakeableId -> r -> Eff es Bool
signalAwakeable aid result =
    lookupAwakeable (awakeableIdToUuid aid) >>= \case
        Nothing -> pure False
        Just row -> signalAwakeableFrom row result

{- | The transaction-decision core of 'signalAwakeable', exposed so race
contracts can deterministically interpose between the initial row read and the
guarded completion. Normal callers should use 'signalAwakeable'.

The supplied row may be stale. This function therefore trusts it only for the
owner coordinates and candidate payload; when a pending-to-completed UPDATE
loses, it re-reads status inside the same transaction and appends only if
another signal completed the row. A winning cancellation gets no append.
-}
signalAwakeableFrom ::
    (IOE :> es, Store :> es, ToJSON r) =>
    AwakeableRow ->
    r ->
    Eff es Bool
signalAwakeableFrom row result
    | row ^. #status == Cancelled = pure False
    | otherwise = do
        now <- liftIO getCurrentTime
        let aid = AwakeableId (row ^. #awakeableId)
            payload =
                if row ^. #status == Completed
                    then row ^. #payload
                    else Just (toJSON result)
        case payload of
            Nothing -> pure False
            Just payloadValue -> do
                let ownerName = WorkflowName (row ^. #ownerWorkflowName)
                    ownerId = WorkflowId (row ^. #ownerWorkflowId)
                gen <- currentGeneration ownerName ownerId
                appendTx <-
                    prepareJournalAppend
                        ownerName
                        ownerId
                        gen
                        StepRecorded
                            { stepName = awakeableStepPrefix <> awakeableIdText aid
                            , result = payloadValue
                            , recordedAt = now
                            }
                (transitioned, appendOutcome) <-
                    runTransaction $ do
                        transitioned <-
                            if row ^. #status == Pending
                                then completeAwakeableTx (awakeableIdToUuid aid) (toJSON result) now
                                else pure False
                        if transitioned || row ^. #status == Completed
                            then do
                                outcome <- appendTx
                                condemnOnAppendConflict outcome
                                pure (transitioned, Just outcome)
                            else
                                lookupAwakeableStatusTx (awakeableIdToUuid aid) >>= \case
                                    Just Completed -> do
                                        outcome <- appendTx
                                        condemnOnAppendConflict outcome
                                        pure (False, Just outcome)
                                    _ -> pure (False, Nothing)
                for_ appendOutcome throwOnAppendConflict
                pure transitioned

condemnOnAppendConflict :: JournalAppendOutcome -> Tx.Transaction ()
condemnOnAppendConflict = \case
    JournalAppendConflict{} -> Tx.condemn
    _ -> pure ()

throwOnAppendConflict :: JournalAppendOutcome -> Eff es ()
throwOnAppendConflict = \case
    JournalAppendConflict err -> throwIO (WorkflowJournalAppendError (Text.pack (show err)))
    _ -> pure ()

{- | Abandon a still-@pending@ awakeable: flips its row to @cancelled@ and
writes __no__ journal entry (there is no result value to record). Returns 'True'
when it transitioned a @pending@ row, 'False' otherwise (already completed,
already cancelled, or unknown). A workflow that later re-enters the awakeable's
@await@ then throws 'WorkflowAwakeableCancelled'.
-}
cancelAwakeable :: (Store :> es) => AwakeableId -> Eff es Bool
cancelAwakeable aid =
    runTransaction $ cancelAwakeableTx (awakeableIdToUuid aid)
