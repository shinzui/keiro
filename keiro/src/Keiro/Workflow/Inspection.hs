{-# LANGUAGE OverloadedRecordDot #-}

-- | Bounded observations of workflow state. Cursors bind immutable ordering
-- keys, read kinds, owners, and (for journal/steps) generations. Each request
-- observes then-current rows; it does not hold a snapshot across pages.
module Keiro.Workflow.Inspection
  ( WorkflowStatusClass (..),
    statusClassToText,
    statusClassFromText,
    statusClassOf,
    classStatus,
    InspectionError (..),
    maxInspectionPageSize,
    WorkflowListOrdering (..),
    WorkflowListQuery (..),
    defaultWorkflowListQuery,
    WorkflowListPage (..),
    listWorkflowInstancesPage,
    DetailPageQuery (..),
    OwnerPageQuery (..),
    WorkflowJournalEntry (..),
    WorkflowJournalPage (..),
    WorkflowStepPage (..),
    WorkflowChildPage (..),
    WorkflowAwakeablePage (..),
    readWorkflowJournalPage,
    loadStepIndexPage,
    listWorkflowChildrenPage,
    listWorkflowAwakeablesPage,
    validateWorkflowListQuery,
    validateJournalQuery,
    validateStepQuery,
    validateChildQuery,
    validateAwakeableQuery,
    instanceToJson,
    childToJson,
    awakeableToJson,
    stepToJson,
    journalEntryToJson,
  )
where

import Data.Aeson (FromJSON, ToJSON (..), Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Pair)
import Data.Int (Int32, Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Effectful.Exception (throwIO)
import GHC.Generics (Generic)
import Keiro.Codec (decodeRecorded)
import Keiro.Inspection.Cursor
import Keiro.Workflow.Awakeable.Schema qualified as Awakeable
import Keiro.Workflow.Child.Schema qualified as Child
import Keiro.Workflow.Inspection.Query
import Keiro.Workflow.Instance (WorkflowInstanceRow, WorkflowStatus (..))
import Keiro.Workflow.Instance qualified as Instance
import Keiro.Workflow.Schema (WorkflowStepRow)
import Keiro.Workflow.Schema qualified as Schema
import Keiro.Workflow.Types
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Types

maxInspectionPageSize :: Int
maxInspectionPageSize = 500

data InspectionError = InvalidPageSize !Int | InvalidCursor !CursorError | CursorGenerationMismatch !Int !Int | CursorResultTooLarge
  deriving stock (Eq, Show, Generic)

statusClassOf :: WorkflowInstanceRow -> WorkflowStatusClass
statusClassOf row = case row.status of
  WfRunning | row.attempts == 0 -> ClassRunning
  WfRunning -> ClassRetrying
  WfSuspended | isJust row.wakeAfter -> ClassSleeping
  WfSuspended -> ClassAwaiting
  WfCompleted -> ClassCompleted
  WfCancelled -> ClassCancelled
  WfFailed -> ClassFailed

data WorkflowListPage = WorkflowListPage
  {items :: ![WorkflowInstanceRow], nextCursor :: !(Maybe InspectionCursor), observedAt :: !UTCTime}
  deriving stock (Eq, Show, Generic)

validateSize :: Int -> Either InspectionError ()
validateSize size
  | size < 1 || size > maxInspectionPageSize = Left (InvalidPageSize size)
  | otherwise = Right ()

decode :: (FromJSON a) => Text -> InspectionCursor -> Either InspectionError a
decode kind token = either (Left . InvalidCursor) Right (decodeCursor kind token)

invalid :: Text -> Either InspectionError a
invalid = Left . InvalidCursor . MalformedCursor

nextFor :: (ToJSON key) => Text -> Int -> [a] -> (a -> key) -> Either InspectionError (Maybe InspectionCursor)
nextFor kind count rows key
  | length rows <= count = Right Nothing
  | otherwise = case reverse (take count rows) of
      row : _ ->
        maybe (Left CursorResultTooLarge) (Right . Just) (encodeCursorBounded kind (key row))
      [] -> Right Nothing

listWorkflowInstancesPage :: (IOE :> es, Store :> es) => WorkflowListQuery -> Eff es (Either InspectionError WorkflowListPage)
listWorkflowInstancesPage query = case validated of
  Left err -> pure (Left err)
  Right position -> do
    (observedAt, rows) <- Instance.inspectionInstanceRows query position (query.pageSize + 1)
    pure $ do
      nextCursor <- case query.ordering of
        ByKey -> nextFor "wf-key" query.pageSize rows (\r -> (r.workflowName, r.workflowId))
        ByCreatedDesc -> nextFor "wf-created" query.pageSize rows (\r -> (r.createdAt, r.workflowName, r.workflowId))
      pure (WorkflowListPage (take query.pageSize rows) nextCursor observedAt)
  where
    validated = do
      validateSize query.pageSize
      traverse
        ( \token -> case query.ordering of
            ByKey -> uncurry AfterWorkflowKey <$> decode "wf-key" token
            ByCreatedDesc -> (\(created, name, wid) -> AfterWorkflowCreated created name wid) <$> decode "wf-created" token
        )
        query.cursor

-- | Pure validation for front ends before they admit work or verify schemas.
-- The reads repeat validation so direct library callers retain the same guard.
validateWorkflowListQuery :: WorkflowListQuery -> Either InspectionError ()
validateWorkflowListQuery query = do
  validateSize query.pageSize
  case query.cursor of
    Nothing -> Right ()
    Just token -> case query.ordering of
      ByKey -> () <$ (decode "wf-key" token :: Either InspectionError (Text, Text))
      ByCreatedDesc -> () <$ (decode "wf-created" token :: Either InspectionError (UTCTime, Text, Text))

data DetailPageQuery = DetailPageQuery
  {generation :: !(Maybe Int), pageSize :: !Int, cursor :: !(Maybe InspectionCursor)}
  deriving stock (Eq, Show, Generic)

data OwnerPageQuery = OwnerPageQuery
  {pageSize :: !Int, cursor :: !(Maybe InspectionCursor)}
  deriving stock (Eq, Show, Generic)

data WorkflowJournalEntry = WorkflowJournalEntry
  { eventId :: !UUID,
    eventType :: !Text,
    streamVersion :: !Int64,
    globalPosition :: !Int64,
    stepName :: !Text,
    recordedAt :: !UTCTime,
    payload :: !Value,
    event :: !WorkflowJournalEvent
  }
  deriving stock (Eq, Show, Generic)

data WorkflowJournalPage = WorkflowJournalPage
  {generation :: !Int, items :: ![WorkflowJournalEntry], nextCursor :: !(Maybe InspectionCursor), observedAt :: !UTCTime}
  deriving stock (Eq, Show, Generic)

data WorkflowStepPage = WorkflowStepPage
  {generation :: !Int, items :: ![WorkflowStepRow], nextCursor :: !(Maybe InspectionCursor), observedAt :: !UTCTime}
  deriving stock (Eq, Show, Generic)

data WorkflowChildPage = WorkflowChildPage
  {items :: ![Child.ChildRow], nextCursor :: !(Maybe InspectionCursor), observedAt :: !UTCTime}
  deriving stock (Eq, Show, Generic)

data WorkflowAwakeablePage = WorkflowAwakeablePage
  {items :: ![Awakeable.AwakeableRow], nextCursor :: !(Maybe InspectionCursor), observedAt :: !UTCTime}
  deriving stock (Eq, Show, Generic)

validGeneration :: Int -> Bool
validGeneration gen = gen >= 0 && toInteger gen <= toInteger (maxBound :: Int32)

prepareDetail :: forall key es. (FromJSON key, Store :> es) => Text -> WorkflowName -> WorkflowId -> DetailPageQuery -> (key -> Bool) -> Eff es (Either InspectionError (Int, Maybe key))
prepareDetail kind name@(WorkflowName ownerName) wid@(WorkflowId ownerId) query validKey =
  case validateDetail kind ownerName ownerId query validKey of
    Left err -> pure (Left err)
    Right position -> do
      gen <- maybe (Schema.currentGeneration name wid) pure query.generation
      pure $ case position of
        Just (cursorGen, _) | gen /= cursorGen -> Left (CursorGenerationMismatch gen cursorGen)
        _ -> Right (gen, snd <$> position)

validateDetail :: forall key. (FromJSON key) => Text -> Text -> Text -> DetailPageQuery -> (key -> Bool) -> Either InspectionError (Maybe (Int, key))
validateDetail kind ownerName ownerId query validKey = do
  validateSize query.pageSize
  case query.generation of Just gen | not (validGeneration gen) -> invalid "generation is outside the supported range"; _ -> Right ()
  traverse
    ( \token -> do
        (cursorOwner, cursorId, gen, key) <- decode kind token :: Either InspectionError (Text, Text, Int, key)
        if cursorOwner /= ownerName || cursorId /= ownerId
          then invalid "cursor belongs to another workflow"
          else
            if not (validGeneration gen) || not (validKey key)
              then invalid "cursor key is outside the supported range"
              else Right (gen, key)
    )
    query.cursor

validateJournalQuery :: WorkflowName -> WorkflowId -> DetailPageQuery -> Either InspectionError ()
validateJournalQuery (WorkflowName name) (WorkflowId wid) query = () <$ validateDetail "wf-journal" name wid query (> (0 :: Int64))

validateStepQuery :: WorkflowName -> WorkflowId -> DetailPageQuery -> Either InspectionError ()
validateStepQuery (WorkflowName name) (WorkflowId wid) query = () <$ validateDetail "wf-steps" name wid query (const True :: Text -> Bool)

validateChildQuery :: WorkflowName -> WorkflowId -> OwnerPageQuery -> Either InspectionError ()
validateChildQuery name wid query = () <$ (prepareOwner "wf-children" name wid query :: Either InspectionError (Maybe (UTCTime, Text, Text)))

validateAwakeableQuery :: WorkflowName -> WorkflowId -> OwnerPageQuery -> Either InspectionError ()
validateAwakeableQuery name wid query = () <$ (prepareOwner "wf-awakeables" name wid query :: Either InspectionError (Maybe (UTCTime, UUID)))

prepareOwner :: forall key. (FromJSON key) => Text -> WorkflowName -> WorkflowId -> OwnerPageQuery -> Either InspectionError (Maybe key)
prepareOwner kind (WorkflowName ownerName) (WorkflowId ownerId) query = do
  validateSize query.pageSize
  traverse
    ( \token -> do
        (cursorOwner, cursorId, key) <- decode kind token :: Either InspectionError (Text, Text, key)
        if cursorOwner == ownerName && cursorId == ownerId then Right key else invalid "cursor belongs to another workflow"
    )
    query.cursor

readWorkflowJournalPage :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> DetailPageQuery -> Eff es (Either InspectionError WorkflowJournalPage)
readWorkflowJournalPage name@(WorkflowName ownerName) wid@(WorkflowId ownerId) query = do
  prepared <- prepareDetail "wf-journal" name wid query (> (0 :: Int64))
  case prepared of
    Left err -> pure (Left err)
    Right (gen, after) -> do
      observedAt <- Schema.inspectionObservedAt
      recorded <- Vector.toList <$> readStreamForward (workflowGenerationStreamName name wid gen) (StreamVersion (maybe 0 (\value -> value) after)) (fromIntegral (query.pageSize + 1))
      entries <- either (throwIO . WorkflowJournalDecodeError) pure (traverse decodeJournalEntry (take query.pageSize recorded))
      pure $ (\nextCursor -> WorkflowJournalPage gen entries nextCursor observedAt) <$> nextFor "wf-journal" query.pageSize recorded (\r -> (ownerName, ownerId, gen, case r.streamVersion of StreamVersion v -> v))

loadStepIndexPage :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> DetailPageQuery -> Eff es (Either InspectionError WorkflowStepPage)
loadStepIndexPage name@(WorkflowName ownerName) wid@(WorkflowId ownerId) query = do
  prepared <- prepareDetail "wf-steps" name wid query (const True)
  case prepared of
    Left err -> pure (Left err)
    Right (gen, after) -> do
      observedAt <- Schema.inspectionObservedAt
      rows <- Schema.loadStepIndexPage name wid gen after (query.pageSize + 1)
      pure $ (\nextCursor -> WorkflowStepPage gen (take query.pageSize rows) nextCursor observedAt) <$> nextFor "wf-steps" query.pageSize rows (\r -> (ownerName, ownerId, gen, r.stepName))

listWorkflowChildrenPage :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> OwnerPageQuery -> Eff es (Either InspectionError WorkflowChildPage)
listWorkflowChildrenPage name@(WorkflowName ownerName) wid@(WorkflowId ownerId) query =
  case prepareOwner "wf-children" name wid query of
    Left err -> pure (Left err)
    Right after -> do
      observedAt <- Schema.inspectionObservedAt
      rows <- Child.lookupChildrenOfParentPage ownerId ownerName after (query.pageSize + 1)
      pure $ (\nextCursor -> WorkflowChildPage (take query.pageSize rows) nextCursor observedAt) <$> nextFor "wf-children" query.pageSize rows (\r -> (ownerName, ownerId, (r.createdAt, r.childId, r.childName)))

listWorkflowAwakeablesPage :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> OwnerPageQuery -> Eff es (Either InspectionError WorkflowAwakeablePage)
listWorkflowAwakeablesPage name@(WorkflowName ownerName) wid@(WorkflowId ownerId) query =
  case prepareOwner "wf-awakeables" name wid query of
    Left err -> pure (Left err)
    Right after -> do
      observedAt <- Schema.inspectionObservedAt
      rows <- Awakeable.lookupAwakeablesOfOwnerPage ownerName ownerId after (query.pageSize + 1)
      pure $ (\nextCursor -> WorkflowAwakeablePage (take query.pageSize rows) nextCursor observedAt) <$> nextFor "wf-awakeables" query.pageSize rows (\r -> (ownerName, ownerId, (r.createdAt, r.awakeableId)))

decodeJournalEntry :: RecordedEvent -> Either Text WorkflowJournalEntry
decodeJournalEntry recorded = do
  event <- either (Left . Text.pack . show) Right (decodeRecorded workflowJournalCodec recorded)
  let (stepName, recordedAt, payload) = case event of
        StepRecorded name value timestamp -> (name, timestamp, value)
        WorkflowCompleted timestamp -> (completedStepName, timestamp, Aeson.Null)
        WorkflowCancelled timestamp -> (cancelledStepName, timestamp, Aeson.Null)
        WorkflowFailed reason timestamp -> (failedStepName, timestamp, Aeson.toJSON reason)
        WorkflowContinuedAsNew gen timestamp -> (continuedAsNewStepName, timestamp, Aeson.toJSON gen)
  pure
    WorkflowJournalEntry
      { eventId = case recorded.eventId of EventId value -> value,
        eventType = case recorded.eventType of EventType value -> value,
        streamVersion = case recorded.streamVersion of StreamVersion value -> value,
        globalPosition = case recorded.globalPosition of GlobalPosition value -> value,
        stepName,
        recordedAt,
        payload,
        event
      }

stepToJson :: WorkflowStepRow -> Value
stepToJson row = object ["step" .= row.stepName, "result" .= row.result, "recorded_at" .= row.recordedAt]

journalEntryToJson :: WorkflowJournalEntry -> Value
journalEntryToJson row = object ["event_id" .= UUID.toText row.eventId, "event_type" .= row.eventType, "stream_version" .= row.streamVersion, "global_position" .= row.globalPosition, "step_name" .= row.stepName, "recorded_at" .= row.recordedAt, "payload" .= row.payload]

pageFields :: UTCTime -> Maybe InspectionCursor -> [Value] -> [Pair]
pageFields clock next items = ["observed_at" .= clock, "items" .= items] <> maybe [] (\token -> ["next_cursor" .= token.cursorText]) next

instance ToJSON WorkflowListPage where toJSON page = object (pageFields page.observedAt page.nextCursor (map instanceToJson page.items))

instance ToJSON WorkflowJournalPage where toJSON page = object ("generation" .= page.generation : pageFields page.observedAt page.nextCursor (map journalEntryToJson page.items))

instance ToJSON WorkflowStepPage where toJSON page = object ("generation" .= page.generation : pageFields page.observedAt page.nextCursor (map stepToJson page.items))

instance ToJSON WorkflowChildPage where toJSON page = object (pageFields page.observedAt page.nextCursor (map childToJson page.items))

instance ToJSON WorkflowAwakeablePage where toJSON page = object (pageFields page.observedAt page.nextCursor (map awakeableToJson page.items))

instanceToJson :: Instance.WorkflowInstanceRow -> Value
instanceToJson row =
  object
    [ "workflow_id" .= row.workflowId,
      "workflow_name" .= row.workflowName,
      "generation" .= row.generation,
      "status" .= Instance.statusToText row.status,
      "status_class" .= statusClassToText (statusClassOf row),
      "attempts" .= row.attempts,
      "last_error" .= row.lastError,
      "next_attempt_at" .= row.nextAttemptAt,
      "wake_after" .= row.wakeAfter,
      "leased_by" .= row.leasedBy,
      "lease_expires_at" .= row.leaseExpiresAt,
      "created_at" .= row.createdAt,
      "updated_at" .= row.updatedAt,
      "completed_at" .= row.completedAt
    ]

childToJson :: Child.ChildRow -> Value
childToJson row =
  object
    [ "child_id" .= row.childId,
      "child_name" .= row.childName,
      "parent_id" .= row.parentId,
      "parent_name" .= row.parentName,
      "await_step" .= row.awaitStep,
      "status" .= Child.statusToText row.status,
      "result" .= row.result,
      "failure_reason" .= row.failureReason,
      "created_at" .= row.createdAt,
      "updated_at" .= row.updatedAt,
      "completed_at" .= row.completedAt
    ]

awakeableToJson :: Awakeable.AwakeableRow -> Value
awakeableToJson row =
  object
    [ "awakeable_id" .= UUID.toText row.awakeableId,
      "owner_workflow_name" .= row.ownerWorkflowName,
      "owner_workflow_id" .= row.ownerWorkflowId,
      "status" .= Awakeable.statusToText row.status,
      "payload" .= row.payload,
      "created_at" .= row.createdAt,
      "updated_at" .= row.updatedAt,
      "completed_at" .= row.completedAt
    ]
