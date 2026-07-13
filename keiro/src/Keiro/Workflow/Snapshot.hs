{- | Workflow journal snapshots: the workflow-specific 'StateCodec' and the
read\/write helpers the runtime uses to skip a full version-0 replay.

A durable workflow folds its journal stream into a 'WorkflowState' — a
@'Map' 'Text' 'Value'@ of step-name to encoded result. For a long-lived
workflow, re-reading the whole journal on every run and resume is ruinous.
This module supplies the EP-4 snapshot machinery the runtime reuses to
persist that folded map and, on the next run, seed from it and replay only
the tail.

== Why a workflow-specific codec

EP-4's 'Keiro.Snapshot.Codec.defaultStateCodec' derives its 'shapeHash' from
a /statically-known/ keiki register-file slot list
('Keiki.Shape.regFileShapeHash'). A workflow's step names are dynamic runtime
strings, so there is no static slot list. The accumulated state is instead a
self-describing JSON object, so it round-trips through Aeson trivially and its
/shape/ never varies with which steps ran. Hence the fixed sentinel
'workflowStateShapeHash'; per-step result-type evolution is each step's own
'Aeson.ToJSON'\/'Aeson.FromJSON' concern, surfaced at the @step@ decode in
"Keiro.Workflow", not here.

== Advisory semantics

A snapshot is an optimization, never a source of truth. 'loadWorkflowSnapshot'
returns 'Nothing' — meaning "replay from version 0" — when the stream has no
id yet, no matching snapshot, or an undecodable snapshot. So a stale or corrupt
snapshot degrades performance at worst, never correctness.

Runtime snapshot writes are advisory too. After a workflow journal append has
committed, "Keiro.Workflow" swallows any snapshot-store failure and increments
@keiro.snapshot.write.failures@; the committed step, completion, or rotation
therefore still determines a successful run. This low-level module continues
to expose the store primitive, while the runtime owns that error handling.

Snapshot writes store the full accumulated step map each time the selected
policy fires. With an every-n policy that means rewriting the complete map at
each boundary; the intended way to bound that cost for forever-running
workflows is 'Keiro.Workflow.continueAsNew', which starts a fresh generation
with a small carried seed.
-}
module Keiro.Workflow.Snapshot (
    workflowStateCodec,
    workflowStateCodecVersion,
    workflowStateShapeHash,
    lookupWorkflowSnapshot,
    loadWorkflowSnapshot,
    writeWorkflowSnapshot,
)
where

import Data.Aeson (Result (..))
import Data.Text qualified as Text
import Effectful (Eff, (:>))
import Keiro.EventStream (StateCodec (..))
import Keiro.Prelude
import Keiro.Snapshot (SnapshotMissReason (..), writeSnapshot)
import Keiro.Snapshot.Schema (lookupSnapshot)
import Keiro.Workflow.Types (WorkflowState)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Read (lookupStreamId)
import Kiroku.Store.Types (StreamId, StreamName, StreamVersion)

{- | The codec version of the workflow snapshot envelope. Bumped only if the
map /envelope/ encoding itself changes (e.g. a switch from a bare JSON
object to a tagged container), never for a per-step result-type change.
-}
workflowStateCodecVersion :: Int
workflowStateCodecVersion = 1

{- | A FIXED sentinel shape hash. The accumulated state is always "a JSON
object of step-name strings to self-describing JSON values"; its /shape/
never varies with which steps ran, so the shape hash is constant. Per-step
result-type evolution is the step's own 'Aeson.ToJSON'\/'Aeson.FromJSON'
concern, surfaced at the step decode in "Keiro.Workflow", not here.
-}
workflowStateShapeHash :: Text
workflowStateShapeHash = "keiro.workflow.stepmap.v1"

{- | The workflow-specific 'StateCodec'. Encodes the accumulated
'WorkflowState' map straight to JSON and decodes it back, with a fixed
discriminant ('workflowStateCodecVersion', 'workflowStateShapeHash').
-}
workflowStateCodec :: StateCodec WorkflowState
workflowStateCodec =
    StateCodec
        { stateCodecVersion = workflowStateCodecVersion
        , shapeHash = workflowStateShapeHash
        , encode = toJSON
        , decode = \value -> case fromJSON value of
            Success m -> Right m
            Error msg -> Left (Text.pack msg)
        }

{- | Encode the accumulated map and upsert @keiro_snapshots@ for the journal
stream. Called from the @step@ miss-path (and the completion site) with the
'Kiroku.Store.Types.AppendResult'\'s @streamId@ and post-append @streamVersion@.
The underlying upsert keeps only the highest version per stream, so a re-fire
at an already-snapshotted version is a harmless no-op.
-}
writeWorkflowSnapshot :: (Store :> es) => StreamId -> StreamVersion -> WorkflowState -> Eff es ()
writeWorkflowSnapshot streamId version state =
    writeSnapshot streamId version workflowStateCodec state

{- | Resolve the journal stream id, look up the latest matching snapshot row,
and decode it to a @('WorkflowState', 'StreamVersion')@ seed. Returns
'Nothing' — meaning "replay from 0" — when the stream has no id yet, no
matching snapshot, or an undecodable snapshot (advisory semantics). Mirrors
'Keiro.Snapshot.hydrateWithSnapshot''s miss-is-benign contract.
-}
loadWorkflowSnapshot :: (Store :> es) => StreamName -> Eff es (Maybe (WorkflowState, StreamVersion))
loadWorkflowSnapshot journalName =
    lookupWorkflowSnapshot journalName <&> either (const Nothing) Just

{- | Resolve and decode a workflow snapshot while retaining the reason a
usable seed was unavailable. This is the observable counterpart to
'loadWorkflowSnapshot'.
-}
lookupWorkflowSnapshot :: (Store :> es) => StreamName -> Eff es (Either SnapshotMissReason (WorkflowState, StreamVersion))
lookupWorkflowSnapshot journalName = do
    mStreamId <- lookupStreamId journalName
    case mStreamId of
        Nothing -> pure (Left SnapshotNoStream)
        Just streamId -> do
            mRow <- lookupSnapshot streamId workflowStateCodecVersion workflowStateShapeHash
            pure $ case mRow of
                Nothing -> Left SnapshotNotFound
                Just row ->
                    case (workflowStateCodec ^. #decode) (row ^. #state) of
                        Left message -> Left (SnapshotDecodeFailed message)
                        Right state -> Right (state, row ^. #streamVersion)
