# Durable Workflows

This guide walks a **durable workflow** end to end: a named `reserve-inventory`
step, a durable `cooling-off` sleep, a `payment-webhook` awakeable resolved by an
external signal, a `charge` step, and a `ship-order` child workflow — then the
resume worker that drives the whole thing across a simulated process restart. The
source is real and compiles as part of this workspace:
[`../../jitsurei/src/Jitsurei/DurableWorkflow.hs`](../../jitsurei/src/Jitsurei/DurableWorkflow.hs),
driven by the `workflow` subcommand of the demo
([`../../jitsurei/app/Main.hs`](../../jitsurei/app/Main.hs)). Run it with:

```bash
cabal run jitsurei:exe:jitsurei-demo -- workflow
```

## What durable execution is, and when to use it

A *durable workflow* is an ordinary imperative Haskell function of type
`Workflow es a` whose side effects are recorded — "journaled" — at *named
checkpoints*, so the function can pause (across a crash, a redeployment, or an
idle wait) and resume by re-invoking it from the top while *short-circuiting* the
checkpoints it already completed. "Short-circuit" means: on a re-run, a `step
(StepName "charge") …` that already ran returns its recorded result instead of
charging the card a second time.

Reach for a durable workflow when you have **a single long-running function that
drives a multi-step process with in-line waits** — a sleep, an external callback,
or a child job. Contrast it with a process manager
([Process Managers And Timers](process-managers-and-timers.md)): a process manager
reacts to *one event at a time* and emits commands, holding all its memory in its
own event-sourced state between deliveries; a durable workflow is *one long-lived
function* you read top to bottom, with the waits written in line. When the
coordination reads naturally as "do this, then wait, then do that", a workflow is
the clearer tool; when it reads as "whenever X happens, react", a process manager
is.

The four primitives, the journal stream, the resume worker, awakeables, child
workflows, and snapshots follow.

## The four primitives

A workflow is a `do`-block in the `Workflow` effect. Here is the parent
order-fulfillment workflow verbatim from the source module:

```haskell
orderFulfillmentWorkflow ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  OrderId ->
  Eff es Text
orderFulfillmentWorkflow orderId = do
  _reservation <- step (StepName "reserve-inventory") (reserveInventory orderId)
  sleepNamed (StepName "cooling-off") coolingOffDelay
  (_awkId, awaitPayment) <- awakeableNamed (StepName "payment-webhook")
  payment <- awaitPayment
  _charge <- step (StepName "charge") (chargeCard orderId payment)
  childHandle <- spawnChild shipOrderWorkflowName (shipChildId orderId) (shipOrderWorkflow orderId)
  awaitChild childHandle
```

**`step` — a named, journaled, replay-skipping checkpoint.**

```haskell
step :: (Workflow :> es, ToJSON a, FromJSON a) => StepName -> Eff es a -> Eff es a
```

`step (StepName "reserve-inventory") action` runs `action` once and journals its
JSON-encoded result. On a replay it returns the recorded result without running
`action` again — so the side effect happens at most once. The name (not the
source position) is the identity, so reordering or inserting code elsewhere in
the workflow does not corrupt an in-flight instance.

**`sleepNamed` / `sleep` — a durable delay.**

```haskell
sleepNamed :: (Workflow :> es, Store :> es, IOE :> es) => StepName -> NominalDiffTime -> Eff es ()
```

`sleepNamed (StepName "cooling-off") delta` schedules a row in the existing
`keiro_timers` table and suspends the run. When a timer worker fires the row, it
appends a `sleep:cooling-off` completion to the journal, so the next run continues
past the sleep. The delay survives a process restart with no external scheduler.
`sleep delta` is the ordinal convenience form (`sleep:0`, `sleep:1`, …); prefer
the named form for anything that must survive a code edit mid-flight.

**`awakeableNamed` / `awakeable` + `signalAwakeable` / `cancelAwakeable` — an
external callback.**

```haskell
awakeableNamed  :: (Workflow :> es, Store :> es, FromJSON a) => StepName -> Eff es (AwakeableId, Eff es a)
signalAwakeable :: (IOE :> es, Store :> es, ToJSON r) => AwakeableId -> r -> Eff es Bool
cancelAwakeable :: (Store :> es) => AwakeableId -> Eff es Bool
```

`awakeableNamed (StepName "payment-webhook")` returns a deterministic
`AwakeableId` and an `await` action. The workflow blocks on `await` until an
external system calls `signalAwakeable awkId payload`, which records the payload in
the journal; the next run replays past the `await` and decodes the payload.
`cancelAwakeable awkId` abandons a stuck one — a workflow that re-enters a
cancelled awakeable throws `WorkflowAwakeableCancelled`.

**Child workflows — `spawnChild` / `awaitChild` / `cancelChild`.**

```haskell
spawnChild  :: (Workflow :> es, Store :> es) => WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (ChildHandle a)
awaitChild  :: (Workflow :> es, Store :> es, FromJSON a) => ChildHandle a -> Eff es a
cancelChild :: (IOE :> es, Store :> es) => ChildHandle a -> Eff es Bool
```

`spawnChild` records a child handle in the *parent's* journal (so a replay never
re-spawns) and registers the parent↔child link; `awaitChild` blocks the parent
like an awakeable until the child completes and propagates its result;
`cancelChild` cancels it. The child is an ordinary workflow — here a one-step
`ship-order`:

```haskell
shipOrderWorkflow ::
  (Workflow :> es, IOE :> es) =>
  OrderId ->
  Eff es Text
shipOrderWorkflow orderId =
  step (StepName "create-shipment") (createShipment orderId)
```

> **Parent and child must use distinct `WorkflowId`s.** The resume worker's
> unfinished-workflow discovery groups by `workflow_id` alone, so a parent and
> child that share an id would let the child's terminal marker hide the parent's
> incompleteness. The example gives the child a distinct id
> (`shipChildId orderId = WorkflowId (orderIdText orderId <> "-ship")`).

## Running a workflow

```haskell
data WorkflowOutcome a = Completed a | Suspended | Cancelled | Failed | ContinuedAsNew
runWorkflow :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)
```

`runWorkflow name wfId action` runs (or resumes) the workflow and returns
`Completed a` when it finishes, `Suspended` when it parks at an unresolved wait,
`Cancelled` when its journal carries a cancellation marker, or `ContinuedAsNew`
when the run rotated its journal via `continueAsNew` (see *Versioning a running
workflow* below). Running the same `(name, wfId)` again replays the journal and
short-circuits completed steps.

## Journaling and replay

Every workflow instance owns a kiroku stream named `wf:<name>-<id>`
(`workflowStreamName`). Each `step` appends a `StepRecorded` event; the terminal
`WorkflowCompleted` event closes the journal. The suspension primitives journal
their completions as the *same* `StepRecorded` event under reserved step-name
prefixes — `sleep:`, `awk:`, `child:` — so the replay loop stays uniform and the
codec never fragments. The journal from the demo run:

```text
[jitsurei:workflow] order-fulfillment journal (wf:order-fulfillment-workflow-20260603…)
  StreamVersion 1 … StepRecorded {stepName = "reserve-inventory", result = String "RES-workflow-…", …}
  StreamVersion 2 … StepRecorded {stepName = "sleep:cooling-off", result = Null, …}
  StreamVersion 3 … StepRecorded {stepName = "awk:<uuid>", result = Object […paymentRef…amountCents…], …}
  StreamVersion 4 … StepRecorded {stepName = "charge", result = String "CHG-workflow-…", …}
  StreamVersion 5 … StepRecorded {stepName = "child:workflow-…-ship", result = Array [], …}
  StreamVersion 6 … StepRecorded {stepName = "child:workflow-…-ship:result", result = String "TRK-…-ship", …}
  StreamVersion 7 … WorkflowCompleted {…}
```

Note the awakeable is journaled under `awk:<uuid>` (the deterministic awakeable
id), and a child contributes two entries: the `child:<id>` spawn record and the
`child:<id>:result` completion the parent awaits.

## Versioning a running workflow: rename a step, or patch

Because step durability is keyed on the **name**, not the source position, the
*common* way to evolve a workflow whose instances are already running needs no
special API: **rename the step**. Change `step (StepName "charge") …` to
`step (StepName "charge-v2") …` and the new name has no journaled history, so its
action runs fresh on the next replay — exactly what you want when one step's
behaviour changed. The rule of thumb: *if a single rename makes the change
correct, rename.*

The `patch` primitive is the escape hatch for the *rare* case a rename cannot
express — a change that **cross-cuts several steps**, where an instance already
past some of them must take one stable branch for the rest of its life:

```haskell
patch :: (Workflow :> es) => PatchId -> Eff es Bool
```

`patch (PatchId "fraud-check-v2")` returns `True` for an instance that is fresh at
this point (run the new branch) and `False` for one already in flight when the
patch shipped (keep the old branch); the decision is journaled once under
`patch:<id>` and replayed verbatim forever. For example, wrapping two existing
steps in a fraud check:

```haskell
orderFlow orderId = do
  useFraudCheck <- patch (PatchId "fraud-check-v2")
  if useFraudCheck
    then do
      _ <- step (StepName "reserve-inventory") (reserveInventoryWithHold orderId)
      _ <- step (StepName "fraud-review")      (fraudReview orderId)
      _ <- step (StepName "charge")            (chargeWithHold orderId)
      pure ()
    else do
      _ <- step (StepName "reserve-inventory") (reserveInventory orderId)
      _ <- step (StepName "charge")            (chargeCard orderId)
      pure ()
```

An order already mid-flight (it reserved inventory under the old logic, with no
hold to release) observes `useFraudCheck == False` and finishes on the old path; a
fresh order observes `True`. Reach for `patch` *only* when an in-flight instance
would be left incoherent by the new code, and never reuse a retired `PatchId`.

For a workflow that runs an *unbounded* number of steps (a poller, a per-day
rolling process), `continueAsNew seed` rotates its journal onto a fresh generation
so the per-generation history stays bounded; read the carried state back at the
top of the body with `restoreSeed`. A rotating run returns `ContinuedAsNew`, and
the resume worker drives it forward on its current generation.

## The resume worker

A background **resume worker** finds workflows whose journal lacks a terminal
`WorkflowCompleted` and re-invokes them, short-circuiting already-journaled steps.

```haskell
data WorkflowDef es = forall a. (ToJSON a) => WorkflowDef { runDef :: WorkflowId -> Eff (Workflow : es) a }
type WorkflowRegistry es = Map WorkflowName (WorkflowDef es)
resumeWorkflowsOnce :: (IOE :> es, Store :> es) => WorkflowResumeOptions -> WorkflowRegistry es -> Eff es ResumeSummary
```

You supply a `WorkflowRegistry` mapping each workflow name to a `WorkflowDef` that
rebuilds the workflow body from its id alone (the worker only knows the journal's
id). The example registers both the parent and the child:

```haskell
jitsureiWorkflowRegistry :: (Store :> es, IOE :> es) => WorkflowRegistry es
jitsureiWorkflowRegistry =
  Map.fromList
    [ (orderFulfillmentWorkflowName, WorkflowDef (\wid -> orderFulfillmentWorkflow (orderIdFromWf wid)))
    , (shipOrderWorkflowName, WorkflowDef (\wid -> shipOrderWorkflow (orderIdFromWf wid)))
    ]
```

`resumeWorkflowsOnce` runs one discover-and-reinvoke pass and returns a
`ResumeSummary`
(`discovered`/`resumed`/`completed`/`stillSuspended`/`unknownName`/`failed`/
`transientErrors`/`leaseSkipped`);
`runWorkflowResumeWorker` loops it on a poll interval. Discovery uses the
`keiro_workflow_steps` index (a "workflows lacking a terminal marker" query) plus
the running-children union — it does **not** use a kiroku `wf:` prefix
subscription, so the runtime has no upstream dependency. An unfinished workflow
whose name is absent from the registry is surfaced as `unknownName`, never
silently dropped.

### Lease sizing and lease loss

The resume worker claims each instance for `leaseTtl` and passes those
coordinates to the workflow as a `LeaseHeartbeat`. Before every fresh step
action and unresolved await arm, the runtime renews the lease for another full
TTL. Replay hits do not write or renew.

Set `leaseTtl` longer than the slowest single step action or await arm, including
its normal timeout. It no longer needs to cover the entire multi-step advance,
because each fresh boundary renews it. If another worker owns the row at a
boundary, the runtime throws `WorkflowLeaseLost` before running further side
effects; the resume worker counts that as `leaseSkipped` and consumes no crash
attempt. Direct `runWorkflow` calls use no heartbeat by default.

### Failure, retries, and resurrection

A synchronous exception escaping a workflow body consumes one workflow attempt.
The worker schedules retries with exponential delays of 2, 4, 8, 16, 32, then
64 seconds (capped there). With the default `maxAttempts = 5`, the fifth failure
is terminal, so there are about 30 seconds of scheduled backoff before it, plus
polling time and the duration of each workflow attempt. Store errors are
classified separately as transient and do not consume attempts.

Choose `maxAttempts` for the longest application outage you expect the worker to
ride through, taking both the backoff sum and the workflow's own runtime into
account. Once the ceiling is reached, the runtime appends `WorkflowFailed`, sets
the instance status to `failed`, and excludes it from ordinary resume discovery.
A direct `runWorkflow` then returns `Failed`.

After repairing the underlying problem, an operator can return the instance to
the runnable pool through the supported API:

```haskell
outcome <-
  resurrectFailedWorkflow
    (WorkflowName "order-fulfillment")
    (WorkflowId "order-123")

case outcome of
  WorkflowResurrected -> pure ()
  WorkflowNotFailed   -> putStrLn "instance is not terminally failed"
  WorkflowNotFound    -> putStrLn "instance does not exist"
```

`resurrectFailedWorkflow` is transactional: it resets attempts, error, retry,
and lease state; removes the current generation's derived failure-marker index
row; and revives a failed child link when the instance is a child. It does not
delete journal history. The old `WorkflowFailed` event remains for audit, and
the next resume replays every completed step instead of repeating its side
effects. If the workflow fails again in the same generation, a new failure event
is appended. A failure sentinel already delivered to a parent journal is also
immutable; resurrect the parent separately if its own terminal failure should
be retried.

## Awakeables in depth

The external signaller must target the *same* deterministic id the workflow
registered. The example computes it without reading the journal back:

```haskell
paymentWebhookAwakeableId :: OrderId -> AwakeableId
paymentWebhookAwakeableId orderId =
  deterministicAwakeableId orderFulfillmentWorkflowName (workflowIdFor orderId) "payment-webhook"
```

`signalAwakeable` is idempotent and crash-safe: it returns `True` only on the
`pending → completed` transition, but re-appends the stored payload to the journal
whenever the row is `completed`, so a crash between the row update and the journal
append heals on a later signal. A workflow parked on an awakeable that will never
arrive is repaired with `cancelAwakeable`.

## Child workflows

The parent records the child as a journal step at spawn, so a parent replay never
re-spawns it; `awaitChild` parks the parent like an awakeable until the child's
`child:<id>:result` entry is journaled. The relationship survives a crash because
both the spawn record and the parent↔child link row are durable. When the resume
worker drives a workflow that is some parent's child, it propagates the child's
result to the parent on completion, which wakes the awaiting parent on the next
pass.

## Snapshots

For long journals, enable snapshots so a resume does not replay every step:

```haskell
data WorkflowRunOptions = WorkflowRunOptions
  { snapshotPolicy :: SnapshotPolicy WorkflowState
  , pageSize        :: Int32
  , metrics         :: Maybe KeiroMetrics
  , tracer          :: Maybe Tracer
  , activePatches   :: Set PatchId
  , leaseHeartbeat  :: Maybe LeaseHeartbeat
  }
runWorkflowWith :: (IOE :> es, Store :> es) => WorkflowRunOptions -> WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)
```

Set the policy with the generic-lens label (a bare record update is ambiguous —
`WorkflowRunOptions.snapshotPolicy` shares a name with keiki's `EventStream`
field):

```haskell
defaultWorkflowRunOptions & #snapshotPolicy .~ Every 2
```

The accumulated step-result map is snapshotted via `workflowStateCodec`, whose
shape hash is the fixed sentinel `"keiro.workflow.stepmap.v1"` — per-step
result-type evolution stays each step's own `ToJSON`/`FromJSON` concern.
Snapshots are safe to combine with awakeables, child workflows, and sleeps: if
a snapshot shadows a wake completion journaled concurrently with its run, an
await miss falls back to the transactionally maintained workflow-step index
before arming or suspending.

## Observability

When you thread a `KeiroMetrics`/`Tracer` through `WorkflowRunOptions`
(`opts & #metrics .~ Just m`), the runtime records six instruments under the
`keiro.workflow.*` namespace — `steps.executed`, `steps.replayed`, `resumed`,
`active`, `journal.length`, `awakeables.pending` — and opens a `workflow <name>`
span. The resume worker reads its handle from `WorkflowResumeOptions.runOptions`,
so a resumed run instruments itself. See [Operations](../user/operations.md).

## Operational notes

- Run `resumeWorkflowsOnce` on a polling loop in production (the same
  claim-process-commit-poll shape as the timer and outbox workers) so suspended
  workflows resume after their waits resolve and after process restarts.
- Set `leaseTtl` above the longest individual step or await-arm timeout. A live
  worker renews at fresh boundaries; expiry remains the dead-worker takeover
  delay.
- Repair a stuck awakeable with `cancelAwakeable awkId`; repair a parent stuck on
  a never-finishing child by driving or cancelling the child.
- Enable a `snapshotPolicy` for workflows with long journals.

See [Operations](../user/operations.md) for the consolidated operational
checklist and [Durable Workflows (user reference)](../user/durable-workflows.md)
for the API surface.

## Running it

```bash
cabal run jitsurei:exe:jitsurei-demo -- workflow
```

The demo runs the workflow to its first suspension, fires the cooling-off sleep
timer, resumes past it, signals the payment-webhook awakeable, drives the resume
worker until the parent and its child both complete, dumps both journals, and
re-opens the store to prove the completed workflow is *not* re-executed from
scratch. The full source is
[`../../jitsurei/src/Jitsurei/DurableWorkflow.hs`](../../jitsurei/src/Jitsurei/DurableWorkflow.hs).
