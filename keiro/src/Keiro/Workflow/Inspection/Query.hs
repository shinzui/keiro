-- | Inspection-only query types. Kept separate to let the owning instance
-- schema consume them without depending on the rendering/page facade.
module Keiro.Workflow.Inspection.Query where

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Keiro.Inspection.Cursor
import Keiro.Workflow.Instance.Schema (WorkflowStatus (..))

data WorkflowStatusClass
  = ClassRunning
  | ClassRetrying
  | ClassSleeping
  | ClassAwaiting
  | ClassCompleted
  | ClassCancelled
  | ClassFailed
  deriving stock (Eq, Ord, Show, Bounded, Enum, Generic)

statusClassToText :: WorkflowStatusClass -> Text
statusClassToText = \case
  ClassRunning -> "running"
  ClassRetrying -> "retrying"
  ClassSleeping -> "sleeping"
  ClassAwaiting -> "awaiting"
  ClassCompleted -> "completed"
  ClassCancelled -> "cancelled"
  ClassFailed -> "failed"

statusClassFromText :: Text -> Maybe WorkflowStatusClass
statusClassFromText value = lookup value [(statusClassToText c, c) | c <- [minBound .. maxBound]]

classStatus :: WorkflowStatusClass -> WorkflowStatus
classStatus = \case
  ClassRunning -> WfRunning
  ClassRetrying -> WfRunning
  ClassSleeping -> WfSuspended
  ClassAwaiting -> WfSuspended
  ClassCompleted -> WfCompleted
  ClassCancelled -> WfCancelled
  ClassFailed -> WfFailed

data WorkflowListOrdering = ByKey | ByCreatedDesc
  deriving stock (Eq, Show, Generic)

data WorkflowListQuery = WorkflowListQuery
  { classes :: !(Maybe (NonEmpty WorkflowStatusClass)),
    workflowName :: !(Maybe Text),
    createdSince :: !(Maybe UTCTime),
    createdBefore :: !(Maybe UTCTime),
    updatedSince :: !(Maybe UTCTime),
    updatedBefore :: !(Maybe UTCTime),
    ordering :: !WorkflowListOrdering,
    pageSize :: !Int,
    cursor :: !(Maybe InspectionCursor)
  }
  deriving stock (Eq, Show, Generic)

defaultWorkflowListQuery :: WorkflowListQuery
defaultWorkflowListQuery = WorkflowListQuery Nothing Nothing Nothing Nothing Nothing Nothing ByKey 100 Nothing

-- | Validated exclusive database keys, decoded by the inspection facade.
-- The default key tuple is (workflow_id, workflow_name).
data WorkflowListPosition = AfterWorkflowKey !Text !Text | AfterWorkflowCreated !UTCTime !Text !Text
  deriving stock (Eq, Show)
