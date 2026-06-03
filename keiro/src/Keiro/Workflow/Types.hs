{-# OPTIONS_GHC -Wno-partial-fields #-}

{- | Core types and the journal codec for the durable workflow runtime.

A /durable workflow/ is an ordinary @effectful@ computation whose side
effects are recorded ("journaled") at named checkpoints so the computation
can be paused and resumed across crashes without re-running work that
already happened. The journal is a kiroku stream named
@wf:\<workflow-name\>-\<workflow-id\>@ ('workflowStreamName') holding one
'StepRecorded' event per executed step and a terminal 'WorkflowCompleted'
event.

This module owns the contracts every sibling plan of the v2 MasterPlan
builds on: the identity newtypes ('WorkflowName', 'WorkflowId',
'StepName'), the journal event sum ('WorkflowJournalEvent') and its
'Codec' ('workflowJournalCodec'), the accumulated-state alias
('WorkflowState'), the run outcome ('WorkflowOutcome'), and the
reserved step-name conventions ('completedStepName' plus the
@sleep:@\/@awk:@\/@child:@ prefixes).
-}
module Keiro.Workflow.Types
  ( -- * Identity
    WorkflowName (..)
  , WorkflowId (..)
  , StepName (..)

    -- * Stream naming
  , workflowStreamName

    -- * Journal events and codec
  , WorkflowJournalEvent (..)
  , workflowJournalCodec

    -- * Accumulated state and run outcome
  , WorkflowState
  , WorkflowOutcome (..)

    -- * Reserved step names
  , completedStepName
  , sleepStepPrefix
  , awakeableStepPrefix
  , childStepPrefix
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.Bifunctor (first)
import Data.Map.Strict (Map)
import Data.Text qualified as Text
import Keiro.Codec (Codec (..))
import Keiro.Prelude
import Kiroku.Store.Types (StreamName (..))

{- | The stable name of a workflow /definition/ (for example
@"order-fulfillment"@). Part of the journal stream name and of every
deterministic journal-event id, so it must not change for a given
definition across deploys.
-}
newtype WorkflowName = WorkflowName {unWorkflowName :: Text}
  deriving stock (Eq, Ord, Show, Generic)

{- | The id of a single workflow /instance/ (a UUID-as-text or any stable
caller-supplied string). Combined with the 'WorkflowName' it identifies
the instance's journal stream.
-}
newtype WorkflowId = WorkflowId {unWorkflowId :: Text}
  deriving stock (Eq, Ord, Show, Generic)

{- | The label identifying a step within a workflow. Replay matches on this
label, not on source position, so reordering code between deploys does not
corrupt an in-flight workflow.
-}
newtype StepName = StepName {unStepName :: Text}
  deriving stock (Eq, Ord, Show, Generic)

{- | The journal stream name for a workflow instance:
@wf:\<name\>-\<id\>@.

The @:@ and @-@ characters are structural. Names and ids must not contain
them in a way that makes the boundary ambiguous (the v1 process-manager
@pm:\<name\>-\<correlationId\>@ convention carries the same caveat).
-}
workflowStreamName :: WorkflowName -> WorkflowId -> StreamName
workflowStreamName (WorkflowName name) (WorkflowId wid) =
  StreamName ("wf:" <> name <> "-" <> wid)

{- | The events written to a workflow journal.

* 'StepRecorded' — a step (identified by 'stepName') ran and produced
  'result' (the step's value encoded as JSON) at 'recordedAt'. The
  suspension primitives journal their completions as ordinary
  'StepRecorded' events whose 'stepName' carries a reserved prefix
  ('sleepStepPrefix', 'awakeableStepPrefix', 'childStepPrefix'); the
  replay loop stays uniform because there is no separate event type.
* 'WorkflowCompleted' — the terminal marker appended once the whole
  computation has returned.

Sibling plans (EP-42 resume, EP-43 child workflows) will add
@WorkflowFailed@ and @WorkflowCancelled@ constructors here. Those are
purely additive within @schemaVersion = 1@: add the constructor, add its
tag to 'workflowJournalCodec''s 'eventTypes', and extend 'encode'\/'decode'.
The codec is deliberately the single place to extend.
-}
data WorkflowJournalEvent
  = StepRecorded {stepName :: !Text, result :: !Aeson.Value, recordedAt :: !UTCTime}
  | WorkflowCompleted {recordedAt :: !UTCTime}
  deriving stock (Eq, Show, Generic)

{- | The 'Codec' that serializes 'WorkflowJournalEvent' to and from the
JSON payloads stored on the journal stream. Schema version 1; no
upcasters. Each payload is self-describing (it carries a @"kind"@
discriminator) so 'decode' can reconstruct the constructor from the
payload alone.
-}
workflowJournalCodec :: Codec WorkflowJournalEvent
workflowJournalCodec =
  Codec
    { eventTypes = "StepRecorded" :| ["WorkflowCompleted"]
    , eventType = \case
        StepRecorded{} -> "StepRecorded"
        WorkflowCompleted{} -> "WorkflowCompleted"
    , schemaVersion = 1
    , encode = encodeJournalEvent
    , decode = decodeJournalEvent
    , upcasters = []
    }

encodeJournalEvent :: WorkflowJournalEvent -> Aeson.Value
encodeJournalEvent = \case
  StepRecorded name r t ->
    Aeson.object
      [ "kind" Aeson..= ("StepRecorded" :: Text)
      , "stepName" Aeson..= name
      , "result" Aeson..= r
      , "recordedAt" Aeson..= t
      ]
  WorkflowCompleted t ->
    Aeson.object
      [ "kind" Aeson..= ("WorkflowCompleted" :: Text)
      , "recordedAt" Aeson..= t
      ]

decodeJournalEvent :: Aeson.Value -> Either Text WorkflowJournalEvent
decodeJournalEvent value = first Text.pack (parseEither parser value)
  where
    parser = Aeson.withObject "WorkflowJournalEvent" $ \o -> do
      kind <- o Aeson..: "kind"
      case (kind :: Text) of
        "StepRecorded" ->
          StepRecorded <$> o Aeson..: "stepName" <*> o Aeson..: "result" <*> o Aeson..: "recordedAt"
        "WorkflowCompleted" ->
          WorkflowCompleted <$> o Aeson..: "recordedAt"
        other ->
          fail ("unknown workflow journal event kind: " <> Text.unpack other)

{- | The accumulated step state a running workflow holds in memory: a map
from step name to that step's recorded JSON result. This is exactly the
value the journal carries, folded into a map.

This alias is the integration contract EP-41 (snapshots) consumes; it must
remain a @Map Text Value@ whose keys are dynamic step-name strings.
-}
type WorkflowState = Map Text Aeson.Value

{- | The result of running a workflow.

* 'Completed' — the computation ran to its end and a 'WorkflowCompleted'
  event was journaled.
* 'Suspended' — the computation paused at an unresolved @awaitStep@; a
  wake source was armed and the run will be resumed later (by EP-42's
  resume worker) once the awaited result is journaled.

Sibling plan EP-43 (child workflows) will add a @Cancelled@ arm; the type
is kept open for that additive extension.
-}
data WorkflowOutcome a
  = Completed a
  | Suspended
  deriving stock (Eq, Show, Functor)

{- | The reserved step name written (as a 'WorkflowCompleted' journal event
and an index row) when a workflow finishes. The discovery query in
"Keiro.Workflow.Schema" ('Keiro.Workflow.Schema.findUnfinishedWorkflowIds')
treats a workflow lacking a row with this step name as unfinished, so the
literal here must match the literal in that SQL.
-}
completedStepName :: Text
completedStepName = "__workflow_completed__"

{- | Reserved step-name prefix EP-39 uses to journal a durable @sleep@'s
completion. Integration contract: EP-39 must use exactly this string. -}
sleepStepPrefix :: Text
sleepStepPrefix = "sleep:"

{- | Reserved step-name prefix EP-40 uses to journal an awakeable's
completion. Integration contract: EP-40 must use exactly this string. -}
awakeableStepPrefix :: Text
awakeableStepPrefix = "awk:"

{- | Reserved step-name prefix EP-43 uses to journal a child workflow's
completion. Integration contract: EP-43 must use exactly this string. -}
childStepPrefix :: Text
childStepPrefix = "child:"
