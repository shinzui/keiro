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

On the __first__ 'Keiro.Workflow.runWorkflow' this returns 'Suspended' (the run
parked on @await@) and a @pending@ row appears in @keiro_awakeables@. An
external caller later runs @'signalAwakeable' aid \"ok\"@, which flips the row
to @completed@ /and/ appends a @StepRecorded \"awk:\<uuid\>\"@ to the workflow's
journal. The __next__ run replays past the now-resolved @await@ and 'Completed's.

== Contract recap for downstream plans (the v2 MasterPlan)

* 'AwakeableId' is a __deterministic__ v5 UUID over
  @(\"keiro\":\"awakeable\":workflowName:workflowId:label)@
  ('deterministicAwakeableId'). Determinism is essential: a resumed workflow
  re-runs from the top and must allocate the /same/ id it already handed out
  and journaled, so the @await@ hit path matches.
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
  payload to repair historical wedges.
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
    cancelAwakeable,

    -- * Errors
    WorkflowAwakeableCancelled (..),
)
where

import Control.Exception (Exception)
import Data.Text qualified as Text
import Data.UUID (UUID)
import Data.UUID qualified as UUID
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
    awakeableStepPrefix,
    currentGeneration,
    currentWorkflow,
    freshOrdinal,
    prepareJournalAppend,
 )
import Keiro.Workflow.Awakeable.Schema (
    AwakeableStatus (..),
    cancelAwakeableTx,
    completeAwakeableTx,
    lookupAwakeable,
    registerAwakeableTx,
 )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import "hasql-transaction" Hasql.Transaction qualified as Tx

-- ---------------------------------------------------------------------------
-- Awakeable ids
-- ---------------------------------------------------------------------------

{- | The opaque id of an awakeable: a deterministic v5 UUID derived from the
owning workflow's name and id plus the awakeable's label (see
'deterministicAwakeableId'). The @ToJSON@\/@FromJSON@ instances are over the
inner UUID, so a workflow may journal the id with 'Keiro.Workflow.step' and a
webhook payload may carry it.
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

{- | The deterministic 'AwakeableId' for a @(workflow name, workflow id,
label)@: a v5 UUID over @(\"keiro\":\"awakeable\":name:id:label)@. Mirrors
'Keiro.ProcessManager.deterministicCommandId' and
'Keiro.Workflow.Sleep.sleepTimerId': the same inputs always yield the same id,
so a re-invoked (resumed) workflow allocates the /same/ id it already handed to
the external system and journaled.
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
    let aid = deterministicAwakeableId name wid label
        stepNm = StepName (awakeableStepPrefix <> awakeableIdText aid)
        await = awaitCancellable name wid aid stepNm
    pure (aid, await)

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

A 'False' return therefore does not mean "nothing happened": the journal may
still have been repaired. Returns 'False' for an unknown id.
-}
signalAwakeable :: (IOE :> es, Store :> es, ToJSON r) => AwakeableId -> r -> Eff es Bool
signalAwakeable aid result = do
    mrow <- lookupAwakeable (awakeableIdToUuid aid)
    case mrow of
        Nothing -> pure False
        Just row
            | row ^. #status == Cancelled -> pure False
            | otherwise -> do
                now <- liftIO getCurrentTime
                let payload =
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
                                appendOutcome <- appendTx
                                condemnOnAppendConflict appendOutcome
                                pure (transitioned, appendOutcome)
                        throwOnAppendConflict appendOutcome
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
