-- | Transactional workflow journal appends shared by workflow execution and
-- operator control APIs.
module Keiro.Workflow.Journal
  ( JournalAppendOutcome (..),
    prepareJournalAppend,
    prepareJournalAppendWithMetadata,
    appendJournalWithMetadata,
    appendJournalTraced,
    appendJournalEntryTraced,
    appendJournalEntryReturningIdTraced,
    journalTraceMetadata,
    readWorkflowTraceResume,
    appendJournal,
    appendJournalEntry,
    appendJournalEntryReturningId,
    deterministicJournalId,
  )
where

import Contravariant.Extras (contrazip4)
import Data.Aeson qualified as Aeson
import Data.Int (Int32)
import Data.Maybe (listToMaybe)
import Data.Text qualified as Text
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, (:>))
import Effectful.Exception (throwIO)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Keiro.Codec (encodeForAppendWithMetadata)
import Keiro.DeterministicId (identitySeedBytes)
import Keiro.Prelude
import Keiro.Telemetry (Tracer, stampTraceContext)
import Keiro.Workflow.Instance.Schema (WorkflowStatus (..), upsertInstanceTx)
import Keiro.Workflow.Schema
  ( WorkflowStepRow (..),
    currentGeneration,
    currentGenerationTx,
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
import Kiroku.Store.Types (AppendResult, EventData, EventId (..), ExpectedVersion (..), StreamId (..), StreamName (..), StreamVersion (..))
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
prepareJournalAppend = prepareJournalAppendWithMetadata Nothing

-- | Metadata is captured in the effect layer, before constructing SQL.
prepareJournalAppendWithMetadata :: (IOE :> es) => Maybe Aeson.Value -> WorkflowName -> WorkflowId -> Int -> WorkflowJournalEvent -> Eff es (Tx.Transaction JournalAppendOutcome)
prepareJournalAppendWithMetadata metadata name wid gen event = do
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
  base <- case encodeForAppendWithMetadata workflowJournalCodec metadata event of
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
appendJournal = appendJournalWithMetadata Nothing

appendJournalWithMetadata :: (IOE :> es, Store :> es) => Maybe Aeson.Value -> WorkflowName -> WorkflowId -> Int -> WorkflowJournalEvent -> Eff es JournalAppendOutcome
appendJournalWithMetadata metadata name wid gen event =
  prepareJournalAppendWithMetadata metadata name wid gen event >>= runTransaction

-- | Explicit enablement; ambient context alone never enables journal tracing.
journalTraceMetadata :: (MonadIO m) => Maybe Tracer -> m (Maybe Aeson.Value)
journalTraceMetadata Nothing = pure Nothing
journalTraceMetadata (Just _) = stampTraceContext Nothing

appendJournalTraced :: (IOE :> es, Store :> es) => Maybe Tracer -> WorkflowName -> WorkflowId -> Int -> WorkflowJournalEvent -> Eff es JournalAppendOutcome
appendJournalTraced tracer name wid gen event = do
  metadata <- journalTraceMetadata tracer
  appendJournalWithMetadata metadata name wid gen event

appendJournalEntryTraced :: (IOE :> es, Store :> es) => Maybe Tracer -> WorkflowName -> WorkflowId -> WorkflowJournalEvent -> Eff es ()
appendJournalEntryTraced tracer name wid event =
  void (appendJournalEntryReturningIdTraced tracer name wid event)

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
appendJournalEntryReturningId = appendJournalEntryReturningIdTraced Nothing

appendJournalEntryReturningIdTraced :: (IOE :> es, Store :> es) => Maybe Tracer -> WorkflowName -> WorkflowId -> WorkflowJournalEvent -> Eff es EventId
appendJournalEntryReturningIdTraced tracer name wid event = do
  gen <- currentGeneration name wid
  let key = journalKey event
      entryId = deterministicJournalId name wid gen key
  appendJournalTraced tracer name wid gen event >>= \case
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

-- | The attribution hint and an indexed first-event reference. Select the
-- reference before joining payloads: the generic forward read can otherwise
-- sort an entire journal before applying LIMIT. Payloads still go through
-- Store.getEvent so configured read decoders remain authoritative.
readWorkflowTraceResume :: (Store :> es) => WorkflowName -> WorkflowId -> Eff es (Int, Maybe (Text, Maybe (EventId, StreamId, StreamVersion)))
readWorkflowTraceResume name wid =
  runTransaction $ do
    gen <- currentGenerationTx name wid
    let StreamName journalName = workflowGenerationStreamName name wid gen
    hint <- Tx.statement (unWorkflowId wid, unWorkflowName name, fromIntegral gen :: Int32, journalName) statement
    pure (gen, hint)
  where
    statement =
      preparable
        """
        SELECT w.trace_awaited_step, first.event_id, s.stream_id, first.stream_version
        FROM keiro.keiro_workflows w
        LEFT JOIN streams s ON s.stream_name = $4 AND s.deleted_at IS NULL
        LEFT JOIN LATERAL (
          SELECT se.event_id, se.stream_version FROM stream_events se
          WHERE se.stream_id = s.stream_id AND se.stream_version > 0
            AND se.stream_version >= s.truncate_before
          ORDER BY se.stream_version ASC LIMIT 1
        ) first ON true
        WHERE w.workflow_id = $1 AND w.workflow_name = $2 AND w.generation = $3
          AND w.trace_awaited_step IS NOT NULL
        """
        (contrazip4 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.int4)) (E.param (E.nonNullable E.text)))
        (D.rowMaybe ((,) <$> D.column (D.nonNullable D.text) <*> origin))
    origin =
      (\eid sid version -> (,,) <$> (EventId <$> eid) <*> (StreamId <$> sid) <*> (StreamVersion <$> version))
        <$> D.column (D.nullable D.uuid)
        <*> D.column (D.nullable D.int8)
        <*> D.column (D.nullable D.int8)
