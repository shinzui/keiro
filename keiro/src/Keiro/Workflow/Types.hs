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
  , workflowGenerationStreamName

    -- * Journal events and codec
  , WorkflowJournalEvent (..)
  , workflowJournalCodec

    -- * Accumulated state and run outcome
  , WorkflowState
  , WorkflowOutcome (..)

    -- * Reserved step names
  , completedStepName
  , cancelledStepName
  , failedStepName
  , continuedAsNewStepName
  , continueSeedStepName
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

{- | The PHYSICAL journal stream for a given /generation/ of a logical
workflow (EP-48 continue-as-new).

Generation 0 keeps the legacy name @wf:\<name\>-\<id\>@ — so already-running,
never-rotated workflows are byte-for-byte unchanged and need zero data
migration — while generation @g > 0@ appends a @#\<g\>@ suffix. The @#@ is a
new structural separator, distinct from the @:@ and @-@ that
'workflowStreamName' already reserves, so it cannot collide with an existing
boundary. The /logical/ identity @('WorkflowName', 'WorkflowId')@ the author
and the resume registry see is stable across rotations; only the physical
stream the journal lives on rotates underneath it.
-}
workflowGenerationStreamName :: WorkflowName -> WorkflowId -> Int -> StreamName
workflowGenerationStreamName name wid gen
  | gen <= 0 = workflowStreamName name wid
  | otherwise =
      let StreamName base = workflowStreamName name wid
       in StreamName (base <> "#" <> Text.pack (show gen))

{- | The events written to a workflow journal.

* 'StepRecorded' — a step (identified by 'stepName') ran and produced
  'result' (the step's value encoded as JSON) at 'recordedAt'. The
  suspension primitives journal their completions as ordinary
  'StepRecorded' events whose 'stepName' carries a reserved prefix
  ('sleepStepPrefix', 'awakeableStepPrefix', 'childStepPrefix'); the
  replay loop stays uniform because there is no separate event type.
* 'WorkflowCompleted' — the terminal marker appended once the whole
  computation has returned.
* 'WorkflowCancelled' — a terminal marker (EP-43) written to a /child/
  workflow's journal by @cancelChild@; a run whose journal carries it
  short-circuits without executing further steps and reports
  'Keiro.Workflow.Types.Cancelled'.
* 'WorkflowFailed' — a terminal failure marker (carries a 'reason'),
  available for a worker to record a permanently-failed run.

These last two are purely additive within @schemaVersion = 1@ (a new wire
tag added to 'workflowJournalCodec''s 'eventTypes'; old journals never carry
it, so no upcaster is needed). The codec is deliberately the single place to
extend.
-}
data WorkflowJournalEvent
  = StepRecorded {stepName :: !Text, result :: !Aeson.Value, recordedAt :: !UTCTime}
  | WorkflowCompleted {recordedAt :: !UTCTime}
  | WorkflowCancelled {recordedAt :: !UTCTime}
  | WorkflowFailed {reason :: !Text, recordedAt :: !UTCTime}
  | WorkflowContinuedAsNew {generation :: !Int, recordedAt :: !UTCTime}
  -- ^ Terminal-for-this-generation rotation marker (EP-48). 'generation'
  --   is the NEXT generation this rotation opens. Additive within
  --   @schemaVersion = 1@: old journals never carry the
  --   @"WorkflowContinuedAsNew"@ tag, so no upcaster is needed.
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
    { eventTypes = "StepRecorded" :| ["WorkflowCompleted", "WorkflowCancelled", "WorkflowFailed", "WorkflowContinuedAsNew"]
    , eventType = \case
        StepRecorded{} -> "StepRecorded"
        WorkflowCompleted{} -> "WorkflowCompleted"
        WorkflowCancelled{} -> "WorkflowCancelled"
        WorkflowFailed{} -> "WorkflowFailed"
        WorkflowContinuedAsNew{} -> "WorkflowContinuedAsNew"
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
  WorkflowCancelled t ->
    Aeson.object
      [ "kind" Aeson..= ("WorkflowCancelled" :: Text)
      , "recordedAt" Aeson..= t
      ]
  WorkflowFailed r t ->
    Aeson.object
      [ "kind" Aeson..= ("WorkflowFailed" :: Text)
      , "reason" Aeson..= r
      , "recordedAt" Aeson..= t
      ]
  WorkflowContinuedAsNew g t ->
    Aeson.object
      [ "kind" Aeson..= ("WorkflowContinuedAsNew" :: Text)
      , "generation" Aeson..= g
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
        "WorkflowCancelled" ->
          WorkflowCancelled <$> o Aeson..: "recordedAt"
        "WorkflowFailed" ->
          WorkflowFailed <$> o Aeson..: "reason" <*> o Aeson..: "recordedAt"
        "WorkflowContinuedAsNew" ->
          WorkflowContinuedAsNew <$> o Aeson..: "generation" <*> o Aeson..: "recordedAt"
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

* 'Cancelled' — the run's journal carried a 'WorkflowCancelled' marker (a
  child cancelled by its parent, EP-43), so the handler short-circuited and
  executed nothing further. Distinct from 'Suspended' (which will resume) and
  'Completed' (which finished its work).
-}
data WorkflowOutcome a
  = Completed a
  | Suspended
  | Cancelled
  | ContinuedAsNew
  -- ^ EP-48: the run rotated onto a fresh journal generation via
  --   @continueAsNew@; a subsequent run/resume of the same logical id
  --   continues from the carried seed. Distinct from 'Suspended' (a wake
  --   source is pending) and 'Completed' (the workflow is done): a rotated
  --   workflow is still unfinished, so the resume worker re-invokes it and it
  --   proceeds on the new generation.
  deriving stock (Eq, Show, Functor)

{- | The reserved step name written (as a 'WorkflowCompleted' journal event
and an index row) when a workflow finishes. The discovery query in
"Keiro.Workflow.Schema" ('Keiro.Workflow.Schema.findUnfinishedWorkflowIds')
treats a workflow lacking a row with this step name as unfinished, so the
literal here must match the literal in that SQL.
-}
completedStepName :: Text
completedStepName = "__workflow_completed__"

{- | The reserved step name written (as a 'WorkflowCancelled' journal event and
an index row) when a workflow is cancelled. The replay handler short-circuits a
run that has a row with this step name, and
'Keiro.Workflow.Schema.findUnfinishedWorkflowIds' treats it (like
'completedStepName') as a terminal marker, so a cancelled workflow drops out of
resume discovery. The literal must match the literal in that SQL. -}
cancelledStepName :: Text
cancelledStepName = "__workflow_cancelled__"

{- | The reserved step name written (as a 'WorkflowFailed' journal event and an
index row) when a workflow is recorded as permanently failed. -}
failedStepName :: Text
failedStepName = "__workflow_failed__"

{- | The reserved step name written (as a 'WorkflowContinuedAsNew' journal event
and an index row) when a workflow's generation rotates via @continueAsNew@
(EP-48). Its presence on a generation's index row makes that generation terminal
/for itself/ (a rotated-away generation drops out of any per-generation
"unfinished" check); the /current/ generation is the one with no terminal marker
row. Distinct from 'completedStepName'/'cancelledStepName': a rotated workflow is
NOT finished — its work continues on the next generation —
so 'Keiro.Workflow.Schema.findUnfinishedWorkflowIds' deliberately scopes its
terminal-marker check to the current (MAX) generation and does not treat
'continuedAsNewStepName' as terminal for the logical workflow. -}
continuedAsNewStepName :: Text
continuedAsNewStepName = "__workflow_continued_as_new__"

{- | The reserved step name under which @continueAsNew@ (EP-48) carries the
author's seed value into the next generation. On rotation the runtime appends a
single @StepRecorded continueSeedStepName seedJson@ to the next generation's
journal (and snapshots it); the next run's body reads it back via @restoreSeed@
— an ordinary journaled @step@ — so the carried state is restored without
re-running anything. The leading/trailing @__@ marks it reserved, like the
other @__workflow_*__@ names. -}
continueSeedStepName :: Text
continueSeedStepName = "__workflow_seed__"

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
