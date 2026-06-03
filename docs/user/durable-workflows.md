# Durable Workflows

Durable workflows let you write a long-running, multi-step process as an ordinary
imperative function whose **named** checkpoints are journaled, so it can pause —
across a crash, a redeployment, or an idle wait — and resume by re-invoking it
from the top while short-circuiting the steps it already completed. The runtime
lives in the `Keiro.Workflow` module family. For a worked, runnable example see
the [Durable Workflows guide](../guides/durable-workflows.md) and the `jitsurei`
demo (`cabal run jitsurei:exe:jitsurei-demo -- workflow`).

## Import surface

```haskell
import Keiro.Workflow              -- the effect, step, runWorkflow, runWorkflowWith, the journal codec
import Keiro.Workflow.Sleep        -- sleepNamed / sleep, runWorkflowTimerWorker
import Keiro.Workflow.Awakeable    -- awakeableNamed / awakeable, signalAwakeable, cancelAwakeable
import Keiro.Workflow.Child        -- spawnChild, awaitChild, cancelChild
import Keiro.Workflow.Resume       -- resumeWorkflowsOnce, the registry, the resume worker
import Keiro.Workflow.Snapshot     -- workflowStateCodec (snapshot discriminant)
```

The umbrella `Keiro` module does **not** re-export the workflow surface; import
`Keiro.Workflow*` directly, the same way you import `Keiro.Timer` or
`Keiro.Outbox`.

## The effect, the type, and running

```haskell
data Workflow :: Effect
data WorkflowOutcome a = Completed a | Suspended | Cancelled

runWorkflow     :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)
runWorkflowWith :: (IOE :> es, Store :> es) => WorkflowRunOptions -> WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)

data WorkflowRunOptions = WorkflowRunOptions
  { snapshotPolicy :: SnapshotPolicy WorkflowState
  , pageSize       :: Int32
  , metrics        :: Maybe KeiroMetrics
  , tracer         :: Maybe Tracer
  }
defaultWorkflowRunOptions :: WorkflowRunOptions
```

`runWorkflowWith` is the single canonical entry point; `runWorkflow` is it with
`defaultWorkflowRunOptions`. The resume worker re-invokes through `runWorkflowWith`
so a resumed run honours the same options. Set option fields with the generic-lens
label (`opts & #snapshotPolicy .~ p`, `opts & #metrics .~ Just m`) — a bare record
update is ambiguous because `snapshotPolicy` collides with keiki's `EventStream`
field of the same name.

## The four primitives

```haskell
step            :: (Workflow :> es, ToJSON a, FromJSON a) => StepName -> Eff es a -> Eff es a
sleepNamed      :: (Workflow :> es, Store :> es, IOE :> es) => StepName -> NominalDiffTime -> Eff es ()
awakeableNamed  :: (Workflow :> es, Store :> es, FromJSON a) => StepName -> Eff es (AwakeableId, Eff es a)
signalAwakeable :: (IOE :> es, Store :> es, ToJSON r) => AwakeableId -> r -> Eff es Bool
cancelAwakeable :: (Store :> es) => AwakeableId -> Eff es Bool
spawnChild      :: (Workflow :> es, Store :> es) => WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (ChildHandle a)
awaitChild      :: (Workflow :> es, Store :> es, FromJSON a) => ChildHandle a -> Eff es a
cancelChild     :: (IOE :> es, Store :> es) => ChildHandle a -> Eff es Bool
```

- `step name action` runs `action` once and journals its result; a replay returns
  the recorded result without re-running the action.
- `sleepNamed name delta` arms a `keiro_timers` row and suspends; the timer
  worker's fire appends a `sleep:<name>` completion. `sleep delta` is the ordinal
  convenience form. Drain workflow-sleep timers with `runWorkflowTimerWorker`.
- `awakeableNamed name` returns a deterministic `AwakeableId` and an `await`
  action; the workflow suspends until `signalAwakeable` records the payload.
  `deterministicAwakeableId name wid label` computes the id externally.
- `spawnChild` records a child handle in the parent journal; `awaitChild` blocks
  the parent until the child completes. **Use a `WorkflowId` for the child that is
  distinct from the parent's** (discovery groups by `workflow_id`).

## Journal stream and tables

```haskell
workflowStreamName   :: WorkflowName -> WorkflowId -> StreamName        -- "wf:<name>-<id>"
workflowJournalCodec :: Codec WorkflowJournalEvent
data WorkflowJournalEvent
  = StepRecorded { stepName :: Text, result :: Value, recordedAt :: UTCTime }
  | WorkflowCompleted { recordedAt :: UTCTime }
  | WorkflowCancelled { recordedAt :: UTCTime }
  | WorkflowFailed    { reason :: Text, recordedAt :: UTCTime }
```

Each instance journals to `wf:<name>-<id>`. The suspension primitives journal
their completions as `StepRecorded` under reserved prefixes — `sleep:`, `awk:`,
`child:` — never as new event types. The runtime keeps two tables in the `kiroku`
schema: `keiro_workflow_steps` (the step-lookup index that backs replay and
unfinished-workflow discovery) and `keiro_awakeables` (pending external
completions); child links live in `keiro_workflow_children`.

## The resume worker

```haskell
data WorkflowDef es = forall a. (ToJSON a) => WorkflowDef { runDef :: WorkflowId -> Eff (Workflow : es) a }
type WorkflowRegistry es = Map WorkflowName (WorkflowDef es)

resumeWorkflowsOnce       :: (IOE :> es, Store :> es) => WorkflowResumeOptions -> WorkflowRegistry es -> Eff es ResumeSummary
runWorkflowResumeWorker   :: (IOE :> es, Store :> es) => WorkflowRegistry es -> Eff es ()
defaultWorkflowResumeOptions :: WorkflowResumeOptions
```

`resumeWorkflowsOnce` discovers workflows whose journal lacks a terminal marker
(via the `keiro_workflow_steps` index, unioned with running children) and
re-invokes each through its registered `WorkflowDef`, short-circuiting journaled
steps. It returns a `ResumeSummary`
(`discovered`/`resumed`/`completed`/`stillSuspended`/`unknownName`).
`runWorkflowResumeWorker` loops it on a poll interval. No `wf:` prefix
subscription is used, so there is no upstream dependency.

## Snapshots

```haskell
workflowStateCodec :: StateCodec WorkflowState   -- fixed shape hash "keiro.workflow.stepmap.v1"
```

Set `WorkflowRunOptions.snapshotPolicy` (e.g. `Every 2`, `OnTerminal`) to
snapshot the accumulated step-result map so a resume hydrates from the snapshot
plus the journal tail instead of replaying every step. The shape hash is a fixed
sentinel — distinct from the `regFileShapeHash` used by aggregate snapshots,
because step names are dynamic.

## See also

- [Durable Workflows guide](../guides/durable-workflows.md) — the full worked
  example, prose-first, with the demo transcript.
- [Operations](operations.md) — running the resume worker, awakeable repair, and
  journal snapshot policy.
- The runnable source:
  [`../../jitsurei/src/Jitsurei/DurableWorkflow.hs`](../../jitsurei/src/Jitsurei/DurableWorkflow.hs).
