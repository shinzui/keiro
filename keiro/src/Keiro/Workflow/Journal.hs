-- | Transactional workflow journal appends shared by workflow execution and
-- operator control APIs.
module Keiro.Workflow.Journal
  ( JournalAppendOutcome (..),
    prepareJournalAppend,
    appendJournal,
    appendJournalEntry,
    appendJournalEntryReturningId,
    deterministicJournalId,
  )
where

import Data.Aeson qualified as Aeson
import Data.Maybe (listToMaybe)
import Data.Text qualified as Text
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, (:>))
import Effectful.Exception (throwIO)
import Keiro.Codec (encodeForAppendWithMetadata)
import Keiro.DeterministicId (identitySeedBytes)
import Keiro.Prelude
import Keiro.Workflow.Instance.Schema (WorkflowStatus (..), upsertInstanceTx)
import Keiro.Workflow.Schema
  ( WorkflowStepRow (..),
    currentGeneration,
    lockWorkflowStepTx,
    lookupStepResultTx,
    recordStepTx,
    terminalMarkersTx,
    workflowLifecycleMarkersTx,
    workflowStepLockKey,
  )
import Keiro.Workflow.Types
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (AppendConflict, appendToStreamTx, prepareEventsIO, runTransaction)
import Kiroku.Store.Types (AppendResult, EventData, EventId (..), ExpectedVersion (..))
import "hasql-transaction" Hasql.Transaction qualified as Tx

-- | What a journal append did.
--
-- 'JournalAppended' means the event, step-index row, and workflow-instance row
-- committed together. 'JournalAlreadyPresent' is the idempotent retry outcome.
-- 'JournalRefusedTerminal' declines an ordinary step after cancellation or
-- failure, or a distinct lifecycle marker after another lifecycle marker won.
-- 'JournalAppendConflict' exposes an event-store append conflict.
data JournalAppendOutcome
  = JournalAppended !AppendResult
  | JournalAlreadyPresent !Aeson.Value
  | JournalRefusedTerminal !Text
  | JournalAppendConflict !AppendConflict
  deriving stock (Eq, Show)

-- | Build the transaction that journals one workflow event.
--
-- The returned transaction takes the per-step advisory lock, re-checks the
-- derived step index, appends to the kiroku stream, and updates both derived
-- tables atomically. Ordinary steps are refused after cancellation or failure.
-- Lifecycle events additionally share a generation lock: an exact retry is
-- idempotent, while a different completion/cancellation/failure/rotation marker
-- is refused.
prepareJournalAppend ::
  (IOE :> es) =>
  WorkflowName ->
  WorkflowId ->
  Int ->
  WorkflowJournalEvent ->
  Eff es (Tx.Transaction JournalAppendOutcome)
prepareJournalAppend name wid gen event = do
  let key = journalKey event
      entryId = deterministicJournalId name wid gen key
      requestedEntryId = case event of
        WorkflowFailed {} -> Nothing
        _ -> Just entryId
      row = journalRow name wid gen event
      (status, mLastError) = instanceStatusForEvent event
      journalName = workflowGenerationStreamName name wid gen
      lockKey = workflowStepLockKey (unWorkflowId wid) (unWorkflowName name) gen key
      lifecycleLockKey =
        workflowStepLockKey
          (unWorkflowId wid)
          (unWorkflowName name)
          gen
          "__keiro_lifecycle__"
      refusingMarker = case event of
        StepRecorded {} ->
          listToMaybe
            <$> terminalMarkersTx (unWorkflowId wid) (unWorkflowName name) gen
        _ ->
          listToMaybe
            <$> workflowLifecycleMarkersTx (unWorkflowId wid) (unWorkflowName name) gen
  base <- case encodeForAppendWithMetadata workflowJournalCodec Nothing event of
    Right encoded -> pure encoded
    Left err -> throwIO (WorkflowJournalEncodeError (Text.pack (show err)))
  let entry = base & #eventId .~ requestedEntryId :: EventData
  prepared <- prepareEventsIO [entry]
  now <- liftIO getCurrentTime
  pure $ do
    unless (isOrdinaryStep event) (lockWorkflowStepTx lifecycleLockKey)
    lockWorkflowStepTx lockKey
    lookupStepResultTx (unWorkflowId wid) (unWorkflowName name) gen key >>= \case
      Just stored -> pure (JournalAlreadyPresent stored)
      Nothing ->
        refusingMarker >>= \case
          Just marker -> pure (JournalRefusedTerminal marker)
          Nothing ->
            appendToStreamTx journalName AnyVersion prepared now >>= \case
              Left err -> pure (JournalAppendConflict err)
              Right appendResult ->
                JournalAppended appendResult
                  <$ recordStepTx row
                  <* upsertInstanceTx
                    (unWorkflowId wid)
                    (unWorkflowName name)
                    (fromIntegral gen)
                    status
                    mLastError

isOrdinaryStep :: WorkflowJournalEvent -> Bool
isOrdinaryStep = \case
  StepRecorded {} -> True
  _ -> False

appendJournal ::
  (IOE :> es, Store :> es) =>
  WorkflowName ->
  WorkflowId ->
  Int ->
  WorkflowJournalEvent ->
  Eff es JournalAppendOutcome
appendJournal name wid gen event =
  prepareJournalAppend name wid gen event >>= runTransaction

-- | Append one event on the current generation, idempotently.
--
-- A late wake-source step aimed at a cancelled or failed workflow is a quiet
-- no-op so the wake source can still settle its own durable row.
appendJournalEntry ::
  (IOE :> es, Store :> es) =>
  WorkflowName ->
  WorkflowId ->
  WorkflowJournalEvent ->
  Eff es ()
appendJournalEntry name wid event =
  void (appendJournalEntryReturningId name wid event)

-- | Like 'appendJournalEntry', returning the deterministic event id even when
-- a terminal workflow refused the delivery.
appendJournalEntryReturningId ::
  (IOE :> es, Store :> es) =>
  WorkflowName ->
  WorkflowId ->
  WorkflowJournalEvent ->
  Eff es EventId
appendJournalEntryReturningId name wid event = do
  gen <- currentGeneration name wid
  let key = journalKey event
      entryId = deterministicJournalId name wid gen key
  appendJournal name wid gen event >>= \case
    JournalAppended {} -> pure entryId
    JournalAlreadyPresent {} -> pure entryId
    JournalRefusedTerminal {} -> pure entryId
    JournalAppendConflict err ->
      throwIO (WorkflowJournalAppendError (Text.pack (show err)))

instanceStatusForEvent :: WorkflowJournalEvent -> (WorkflowStatus, Maybe Text)
instanceStatusForEvent = \case
  StepRecorded {} -> (WfRunning, Nothing)
  WorkflowCompleted {} -> (WfCompleted, Nothing)
  WorkflowCancelled {} -> (WfCancelled, Nothing)
  WorkflowFailed reason _ -> (WfFailed, Just reason)
  WorkflowContinuedAsNew {} -> (WfRunning, Nothing)

journalKey :: WorkflowJournalEvent -> Text
journalKey = \case
  StepRecorded {stepName = key} -> key
  WorkflowCompleted {} -> completedStepName
  WorkflowCancelled {} -> cancelledStepName
  WorkflowFailed {} -> failedStepName
  WorkflowContinuedAsNew {} -> continuedAsNewStepName

journalRow :: WorkflowName -> WorkflowId -> Int -> WorkflowJournalEvent -> WorkflowStepRow
journalRow name wid gen = \case
  StepRecorded key value t -> mkRow key value t
  WorkflowCompleted t -> mkRow completedStepName Aeson.Null t
  WorkflowCancelled t -> mkRow cancelledStepName Aeson.Null t
  WorkflowFailed reason t -> mkRow failedStepName (Aeson.toJSON reason) t
  WorkflowContinuedAsNew nextGeneration t ->
    mkRow continuedAsNewStepName (Aeson.toJSON nextGeneration) t
  where
    mkRow key value t =
      WorkflowStepRow
        { workflowId = unWorkflowId wid,
          workflowName = unWorkflowName name,
          generation = gen,
          stepName = key,
          result = value,
          recordedAt = t
        }

-- | A stable journal-event id derived from the workflow identity, generation,
-- and reserved step key.
deterministicJournalId :: WorkflowName -> WorkflowId -> Int -> Text -> EventId
deterministicJournalId (WorkflowName name) (WorkflowId wid) gen key =
  EventId $
    UUID.V5.generateNamed UUID.V5.namespaceURL $
      identitySeedBytes $
        Text.intercalate ":" ["keiro", "workflow", name, wid, Text.pack (show gen), key]
