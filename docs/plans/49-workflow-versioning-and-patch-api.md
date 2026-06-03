---
id: 49
slug: workflow-versioning-and-patch-api
title: "Workflow versioning and patch API"
kind: exec-plan
created_at: 2026-06-03T21:28:37Z
intention: "intention_01kt7npy22e5tb3ybycsgeqdnm"
master_plan: "docs/masterplans/6-v2-durable-execution-phase-2-rotation-versioning-push-delivery-and-sharding.md"
---

# Workflow versioning and patch API

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, an author of a durable workflow can change the *logic* of a
workflow whose instances are already running — in a way that touches more than one
step — and be sure that every instance that was already in flight keeps taking the
old branch, while every brand-new instance takes the new branch. The author does
this with one new primitive:

```haskell
patch :: (Workflow :> es) => PatchId -> Eff es Bool
```

`patch (PatchId "p1")` returns `True` when the calling instance should run the *new*
code and `False` when it should run the *old* code. The very first time a given
instance reaches a `patch` call, the runtime decides which branch that instance
takes, **writes that decision into the workflow's journal**, and from then on every
replay of that instance reads the journaled decision and returns the same `Bool`
forever. A decision, once made, never changes — even across a crash, a redeploy, or
a code change.

Concretely, a workflow that today does:

```haskell
orderFlow orderId = do
  _ <- step (StepName "reserve-inventory") (reserveInventory orderId)
  _ <- step (StepName "charge")            (chargeCard orderId)
  pure ()
```

and that the author now wants to extend with a fraud check that *wraps* both
existing steps (so the fraud decision must be consistent with how inventory was
reserved and how the card was charged) becomes:

```haskell
orderFlow orderId = do
  useFraudCheck <- patch (PatchId "fraud-check-v2")
  if useFraudCheck
    then do
      _ <- step (StepName "reserve-inventory") (reserveInventoryWithHold orderId)
      _ <- step (StepName "fraud-review")       (fraudReview orderId)
      _ <- step (StepName "charge")             (chargeWithHold orderId)
      pure ()
    else do
      _ <- step (StepName "reserve-inventory") (reserveInventory orderId)
      _ <- step (StepName "charge")            (chargeCard orderId)
      pure ()
```

An order that was already mid-flight when this code shipped (it had already reserved
inventory under the *old* logic and was waiting to charge) must not suddenly switch
into the fraud-check branch — its inventory reservation has no "hold" to release, so
the new path would be incoherent. With `patch`, that in-flight instance observes
`useFraudCheck == False` on every replay and finishes on the old path; a fresh order
observes `True` and runs the new path. The decision is recorded once in the
instance's journal and is stable forever.

**What you can see working after this change:** a keiro test (`cabal test keiro`)
that runs one workflow instance to a suspension *before* the patched code exists,
then re-runs the *same instance id* with the patched code present, and asserts the
in-flight instance keeps observing the old branch on every replay while a fresh
instance id observes the new branch — and that the journal records exactly one patch
decision per instance, stable across re-invocations.

**Why this is an escape hatch, not the common case.** keiro v2 deliberately keys
durability on **named steps**, not on the position of a step in the source (see
`docs/research/10-workflow-roadmap.md` §4, the "named steps, not positional history"
decision, lines ~126 and ~345-347). That choice means the *common* kind of code
change needs no patch API at all: to opt an instance out of old behaviour, you
**rename the step**. A renamed step (`StepName "charge-v2"` instead of
`StepName "charge"`) has no journaled history under its new name, so its action runs
fresh on the next replay — exactly the behaviour you want for "this one step changed".
The `patch` API is for the case the rename mechanic *cannot* express: a change that
**cross-cuts several steps** and where an in-flight instance, already past some of
those steps, must take a single stable branch for the rest of its life. That is
rare; this plan delivers it as the explicit escape hatch the research doc (§6.5)
names, and contrasts it everywhere with the rename-a-step mechanic so a reader never
reaches for `patch` when a rename would do.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

- [ ] Milestone 1: add the `PatchId` newtype, the `patchStepName` helper, and the
  reserved `patch:` prefix to `keiro/src/Keiro/Workflow/Types.hs`; confirm
  `cabal build keiro` is green.
- [ ] Milestone 2: add the `Patch` operation to the `Workflow` effect and the
  `patch` smart constructor in `keiro/src/Keiro/Workflow.hs`, and interpret it in
  the `handler` of `runWorkflowWith`; confirm `cabal build keiro` is green.
- [ ] Milestone 3: add the acceptance test to `keiro/test/Main.hs` (a new
  `describe "Keiro.Workflow patch API"` block) proving stable-branch semantics and
  exactly-once journaling; confirm `cabal test keiro` is green.
- [ ] Milestone 4: document the primitive — a short note in
  `docs/guides/durable-workflows.md` (the rename-vs-patch contrast) and a signature
  entry in `docs/user/durable-workflows.md`; flip the `docs/user/roadmap.md` /
  `docs/user/production-status.md` lines that still mark "versioning / patch API" as
  deferred.
- [ ] Milestone 5: full-repo green — `cabal build all`, `cabal test keiro` — recorded
  in Validation and Acceptance.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Journal the patch decision as an ordinary `StepRecorded` event whose
  `stepName` carries a new reserved prefix `patch:` (so the journaled step name is
  `patch:<patchId>`) and whose `result` is the JSON `Bool` decision — **not** a new
  `WorkflowPatched` constructor on `WorkflowJournalEvent`.
  Rationale: The existing wake-source primitives (sleep, awakeable, child) all
  journal their completions as `StepRecorded` events with reserved prefixes
  (`sleep:`, `awk:`, `child:` — see `Keiro.Workflow.Types`), precisely so the replay
  loop in `loadJournal` and the index in `keiro_workflow_steps` stay uniform and need
  no new wire tag. A patch decision is exactly the same shape: a name keyed in the
  journal whose recorded value (here a `Bool`) is replayed verbatim. Reusing
  `StepRecorded` means **zero changes** to `workflowJournalCodec`, `loadJournal`'s
  `accumulate` fold, `recordStepTx`/`stepExists`/`findUnfinishedWorkflowIds`, the
  snapshot codec, and EP-48's generation/rotation plumbing — the decision rides every
  one of them for free. The MasterPlan Integration Points offer either a
  `WorkflowPatched { patchId, applied, recordedAt }` constructor *or* a reserved
  `patch:` prefix; the prefix is strictly less surface area and is the convention the
  shipped runtime already established, so we take it. A patch decision is also not a
  *terminal* marker, which a new constructor would risk being mistaken for; a prefixed
  `StepRecorded` is unambiguously a non-terminal recorded value.
  Date: 2026-06-03.

- Decision: `patch pid` semantics — on the **first** encounter of `pid` for an
  instance (no `patch:<pid>` row journaled yet), the decision is computed from
  whether the instance is **brand-new at this point** or **already in flight past
  it**, then journaled. The discriminator is: *does this instance's journal already
  contain at least one ordinary step recorded under the new logic's lifetime?* We
  implement the standard model precisely: a `patch` call returns `True` (run the new
  branch) for an instance whose journal does **not** already carry a marker saying
  "this patch was not yet active", and `False` for one that does. The runtime journals
  the chosen `Bool` immediately on first encounter so every later replay returns the
  same value.
  Rationale: This is the Temporal `patched`/`getVersion` and Cadence `GetVersion`
  model, reduced to a single deterministic `Bool` because keiro does not need
  positional version *ranges* (named steps already absorb single-step changes). See
  "How the first-encounter decision is computed" in Context and Orientation for the
  exact rule and why a journal pre-scan is the right discriminator in a named-step
  runtime.
  Date: 2026-06-03.

- Decision: No database migration and no codec change. The patch decision is a
  `StepRecorded` row in the *existing* `keiro_workflow_steps` index and a
  `StepRecorded` event on the *existing* `wf:<name>-<id>` journal stream.
  Rationale: The MasterPlan Integration Points explicitly anticipate "EP-49 ... is not
  expected to need a migration (a patch decision is journaled, not tabled)"; the
  reserved-prefix decision above confirms it. Confirmed against
  `keiro/src/Keiro/Workflow/Schema.hs`: `recordStepTx` upserts any `(workflow_id,
  step_name)` row, so a `patch:<pid>` step name needs no schema change.
  Date: 2026-06-03.

- Decision: Scope `deprecatePatch` / patch cleanup as **future work**, documented but
  not implemented.
  Rationale: A patch decision becomes dead once every instance that could ever observe
  `False` has terminated. Removing the `patch` call from source and renaming the
  affected steps is then safe (the named-step model makes the *next* version's steps
  fresh). A `deprecatePatch` helper that asserts "no instance still carries
  `patch:<pid> == False`" is a nice-to-have, but it needs a query over historical
  journals that earns its keep only at scale; the research doc (§6.5) treats the whole
  patch API as a v2.5 escape hatch, so the cleanup story is deferred and only noted
  here. See "The cleanup / deprecation story" in Interfaces and Dependencies.
  Date: 2026-06-03.

- Decision: Soft-depend on EP-48 (continue-as-new), do not hard-depend.
  Rationale: The MasterPlan Dependency Graph records EP-49 soft-depends on EP-48: if
  EP-48 lands first, EP-49 reuses the "additive journal entry within
  `schemaVersion = 1`, read on replay" plumbing and the generation-aware replay loop.
  Because EP-49 journals via the existing `StepRecorded`/prefix mechanism it touches
  nothing EP-48 owns, so the order is genuinely free; this plan is written to apply
  cleanly whether or not EP-48 has landed.
  Date: 2026-06-03.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before
editing. All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/keiro`.

**The repository.** Keiro is a Haskell event-sourcing framework built on three
libraries — `kiroku` (a PostgreSQL event store), `keiki` (event-sourcing
transducers/codecs), and `shibuya` (message-stream adapters) — using the `effectful`
effect system. The Cabal packages relevant here are `keiro` (the runtime, including
the durable-workflow engine added in MasterPlan 5) and its test suite at
`keiro/test/Main.hs`. The durable-workflow code lives under
`keiro/src/Keiro/Workflow.hs` and `keiro/src/Keiro/Workflow/` (the
`Types`, `Schema`, `Snapshot`, `Sleep`, `Awakeable`, `Child`, and `Resume` modules).

**Terms of art, defined plainly.**

- *Durable workflow* — an ordinary imperative Haskell function of type
  `Eff (Workflow : es) a` (the `Workflow` effect is in scope), written as a `do`
  block. Its side effects are recorded ("journaled") at *named checkpoints* so the
  function can pause and resume by being re-invoked from the top while skipping the
  checkpoints it already completed.

- *Step* — a named checkpoint. `step (StepName "charge") action` runs `action` once,
  records ("journals") its JSON-encoded result, and on a later replay returns the
  recorded result *without re-running* `action`. The identifier is the **name**
  (`"charge"`), not the position of the call in the source. This is the named-step
  durability model.

- *Journal* — the durable record of an instance's progress. It is a kiroku event
  stream named `wf:<workflow-name>-<workflow-id>` (built by `workflowStreamName` in
  `keiro/src/Keiro/Workflow/Types.hs`), holding one `StepRecorded` event per
  journaled step and a terminal `WorkflowCompleted` event. A second, derived copy
  lives in the Postgres table `keiro_workflow_steps` (the *step index*, in
  `keiro/src/Keiro/Workflow/Schema.hs`) for fast `(workflow_id, step_name)` lookups;
  the journal stream and the index are kept consistent inside one transaction by
  `appendJournalTx` in `keiro/src/Keiro/Workflow.hs`.

- *Replay* — re-running the workflow function from the top. On replay, every `step`
  whose name is already in the journal returns the recorded result; the first
  un-journaled step runs for real. A replay happens on a crash-restart, on a resume
  after a wait resolves, and on any plain second invocation of the same
  `(name, id)`.

- *In-flight instance* — a single workflow instance (one `(WorkflowName, WorkflowId)`
  pair) that has *started* — its journal already has at least one `StepRecorded`
  event — but has not yet finished (no `WorkflowCompleted`). "In flight" is the
  opposite of "fresh": a *fresh* instance is one whose journal is empty when the
  workflow function first reaches a given point in the code.

- *Branch* — one of the two code paths in an `if useNew then ... else ...` guarded by
  a `patch` call. The *new branch* is the `then`; the *old branch* is the `else`. A
  workflow may have several patch-guarded branches, each keyed by its own `PatchId`.

- *Patch* — the act of evolving a running workflow's logic across step boundaries.
  The `patch :: PatchId -> Eff es Bool` primitive lets an author gate a cross-cutting
  change so that in-flight instances keep the old branch and fresh instances take the
  new one, with the decision journaled once and stable forever.

**Rename-a-step vs patch — when to reach for which.** This is the single most
important orientation point, because reaching for `patch` when a rename would do adds
unnecessary journal entries and a permanent `PatchId` you must never reuse.

- *Rename a step* — the common case. You changed **one step's** behaviour and want
  in-flight instances to run the new behaviour from here on. Just change its
  `StepName`. The old name's journaled result is now orphaned (harmless); the new
  name has no journaled history, so its action runs fresh on the next replay. No
  patch needed. Example: `step (StepName "charge") ...` becomes
  `step (StepName "charge-v2") ...`.

- *Patch* — the escape hatch. Your change **cross-cuts several steps** (it adds,
  removes, or reorders steps, or it changes the *meaning* of an existing step's
  result so that an in-flight instance which already journaled the old-meaning result
  would be incoherent under the new code). An in-flight instance must take **one
  stable branch** for the rest of its life because its already-journaled steps belong
  to the old branch. Renaming cannot express "all of these steps as a unit"; `patch`
  can. Example: the fraud-check rewrite in Purpose / Big Picture.

The rule of thumb the guide will state: *if a single rename makes the change correct,
rename; only if an in-flight instance would be left in an incoherent state by the new
code do you need `patch`.*

**The `Workflow` effect today** (`keiro/src/Keiro/Workflow.hs`, lines ~135-185). It
is an `effectful` dynamic-dispatch effect with four operations:

```haskell
data Workflow :: Effect where
  Step :: (Aeson.ToJSON a, Aeson.FromJSON a) => StepName -> m a -> Workflow m a
  Await :: (Aeson.FromJSON a) => StepName -> m () -> Workflow m a
  CurrentWorkflow :: Workflow m (WorkflowName, WorkflowId)
  FreshOrdinal :: Text -> Workflow m Int
```

Each has a smart constructor (`step`, `awaitStep`, `currentWorkflow`, `freshOrdinal`)
that calls `send`. The handler lives inside `runWorkflowWith` (lines ~361-413): it
holds the journal as an `IORef (Map Text Aeson.Value)` (`journalRef`) pre-loaded by
`loadJournal`, and interprets each operation. The `Step` case looks the step name up
in the map; on a hit it decodes and returns the stored value (a replay), on a miss it
runs the action, encodes the result, appends it to the journal stream + index via
`recordStep`, and inserts it into the in-memory map. This is exactly the shape `patch`
needs.

**How the journal is keyed.** `journalKey` (lines ~528-533) maps a
`WorkflowJournalEvent` to the `Text` key it indexes under;
`StepRecorded{stepName = key}` indexes under `key` directly. The reserved prefixes
`sleepStepPrefix = "sleep:"`, `awakeableStepPrefix = "awk:"`,
`childStepPrefix = "child:"` (in `keiro/src/Keiro/Workflow/Types.hs`, lines ~234-247)
are just conventions on that key string; they are not separate constructors. We add
`patchStepPrefix = "patch:"` the same way, so a patch decision is journaled as
`StepRecorded { stepName = "patch:" <> pid, result = Bool decision, recordedAt = now }`
and keys under `patch:<pid>` in both the journal stream and `keiro_workflow_steps`.

**How the first-encounter decision is computed (the core semantic).** When the
handler reaches a `Patch (PatchId pid)` operation, it looks up the key
`patch:<pid>` in `journalRef`:

1. **Hit (decision already journaled).** Return the stored `Bool`. This is the replay
   path: the decision was made on a prior run and is now stable. This is the case
   that gives the whole feature its guarantee — every replay of an instance returns
   the same branch.

2. **Miss (first encounter for this instance).** Decide, then journal. The decision
   rule is: *the patch is "active" (return `True`, run the new branch) for an instance
   that is fresh at this point, and "inactive" (return `False`, run the old branch)
   for an instance that is already in flight past this point.* In a named-step runtime
   the right, deterministic discriminator for "already in flight past this point" is:
   **does the instance's journal already contain any `StepRecorded` event for an
   ordinary (non-reserved) step name?** If the journal map (as pre-loaded by
   `loadJournal`, *before* this run executes any new step) holds at least one ordinary
   step key, the instance had already begun executing under the old code before this
   `patch` call existed, so the decision is `False`. If the journal map holds no
   ordinary step key — the instance is reaching its first real step on this very run —
   the decision is `True`. Either way the chosen `Bool` is appended as
   `patch:<pid>` and inserted into the in-memory map, so the *next* lookup (this run
   or any later replay) is a hit.

   The discriminator must be evaluated against the **pre-loaded** journal snapshot
   (the `Map` as it was when the run started), not the live map after this run has
   journaled new steps — otherwise a fresh instance that runs a step *before* the
   patch call in the same function would be misclassified. We capture the
   pre-execution ordinary-step count once at handler-construction time (an
   `IORef Bool` seeded from the initial journal) so the `Patch` case reads a stable
   "was this instance already in flight when the run began" flag rather than
   re-deriving it from a mutating map. See Plan of Work, Milestone 2, for the exact
   wiring.

   Why this rule is correct for the escape-hatch use case: an instance that had
   already journaled an ordinary step before the patch call shipped is, by
   construction, one whose earlier steps ran under the old logic — exactly the
   in-flight instance that must keep the old branch. An instance with no ordinary
   step journaled yet is reaching the patched region for the first time and is safe to
   run the new branch. This mirrors Temporal's `patched(id)` returning `false` for
   histories that predate the patch and `true` for fresh ones, collapsed to a single
   `Bool` because keiro has no positional version range to track.

**Acceptance harness.** The keiro test suite (`keiro/test/Main.hs`) uses `hspec` with
an ephemeral PostgreSQL: `around (withFreshStore fixture)` (imported from
`Keiro.Test.Postgres`) gives each example a fresh, migrated store handle, and
`Store.runStoreIO storeHandle` runs an `Eff` action against it. The existing
`describe "Keiro.Workflow"` block (lines ~2022-2104) is the model: it runs workflows
with `runWorkflow (WorkflowName ...) (WorkflowId ...) (someWorkflow ...)`, asserts on
the `WorkflowOutcome`, and reads back the journal with
`Store.readStreamForward (StreamName "wf:<name>-<id>") (StreamVersion 0) N` decoded
through `workflowJournalCodec`. Re-running `runWorkflow` with the same `(name, id)` is
"the crash-restart scenario" (the existing replay test, lines ~2039-2055, says so).
Our test reuses every one of these utilities.


## Plan of Work

The work is five milestones, each independently verifiable. Milestone 1 adds the
identity and naming pieces; Milestone 2 adds the effect operation and its handler
interpretation (the behavioural core); Milestone 3 proves the semantics with a test;
Milestone 4 documents it and flips the roadmap; Milestone 5 is the full-repo green
gate.


### Milestone 1: `PatchId`, the reserved prefix, and `patchStepName`

**Scope.** Add to `keiro/src/Keiro/Workflow/Types.hs`: a `PatchId` newtype, a reserved
prefix `patchStepPrefix = "patch:"`, and a helper `patchStepName :: PatchId -> Text`
that builds the journal key `patch:<pid>`. Export all three from the module. **At the
end of this milestone**, `cabal build keiro` is green and the new names are importable;
nothing uses them yet.

Add the newtype next to the other identity newtypes (after `StepName`, around line
77):

```haskell
{- | The stable identifier of a /patch/ — a guarded, cross-cutting change to a
running workflow's logic. The author chooses an opaque, never-reused string
(for example @"fraud-check-v2"@). A patch decision is journaled under the key
@patch:\<patchId\>@, so the id must not contain the structural @:@ in a way that
makes the prefix boundary ambiguous, mirroring the 'sleepStepPrefix' caveat.
-}
newtype PatchId = PatchId {unPatchId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
```

Add the prefix and helper next to the other reserved prefixes (after
`childStepPrefix`, around line 247):

```haskell
{- | Reserved step-name prefix this plan (EP-49) uses to journal a 'patch'
decision. A patch decision is journaled as an ordinary 'StepRecorded' event
whose 'stepName' is @'patchStepPrefix' <> unPatchId pid@ and whose 'result' is
the JSON 'Bool' branch decision, so the replay loop and the step index stay
uniform — no new journal-event constructor is added. -}
patchStepPrefix :: Text
patchStepPrefix = "patch:"

-- | The journal key a patch decision is recorded under: @patch:\<patchId\>@.
patchStepName :: PatchId -> Text
patchStepName (PatchId pid) = patchStepPrefix <> pid
```

Add `PatchId (..)`, `patchStepPrefix`, and `patchStepName` to the module's export
list (the `-- * Identity` and `-- * Reserved step names` sections, lines ~22-45).

**Acceptance.** `cabal build keiro` succeeds with no warnings.


### Milestone 2: the `Patch` operation, the `patch` constructor, and the handler

**Scope.** Add a `Patch` operation to the `Workflow` effect in
`keiro/src/Keiro/Workflow.hs`, a `patch` smart constructor, and interpret `Patch` in
the `handler` inside `runWorkflowWith`. Re-export `patch` from `Keiro.Workflow`. **At
the end of this milestone**, `cabal build keiro` is green and a workflow can call
`patch (PatchId "p1")`; the behaviour is exercised by Milestone 3's test.

Add the operation to the `Workflow` GADT (after `FreshOrdinal`, line ~148):

```haskell
  -- | Decide and journal a cross-cutting branch: returns the stable 'Bool'
  -- branch decision for the given patch. Fresh instances get 'True' (new
  -- branch); instances already in flight when the patch shipped get 'False'
  -- (old branch). The decision is journaled on first encounter and replayed
  -- verbatim thereafter.
  Patch :: PatchId -> Workflow m Bool
```

Add the smart constructor (next to `freshOrdinal`, around line 185), with a doc
comment that states the rename-vs-patch contrast in the source so the reader who only
has Haddock sees it:

```haskell
{- | Decide a cross-cutting branch for an in-flight-vs-fresh code change, and
journal the decision so every later replay observes the same branch.

@patch (PatchId "fraud-check-v2")@ returns 'True' for an instance that is fresh
at this point (run the new branch) and 'False' for an instance that was already
in flight when this patch shipped (keep the old branch). On the first encounter
the decision is journaled under @patch:\<patchId\>@; every replay returns the
recorded 'Bool'.

This is an /escape hatch/ for changes that cross-cut multiple steps. For the
common case — one step changed — do __not__ use 'patch': rename the step's
'StepName' instead. A renamed step has no journaled history under its new name,
so its action runs fresh on the next replay, which is exactly the right
behaviour for a single-step change. Reach for 'patch' only when an in-flight
instance would be left incoherent by the new code (e.g. the change adds, removes,
or reorders steps, or changes the meaning of an already-journaled step result).
-}
patch :: (Workflow :> es) => PatchId -> Eff es Bool
patch pid = send (Patch pid)
```

Add `patch` to the module export list under `-- * The effect and authoring surface`
(line ~55, after `freshOrdinal`). `PatchId`, `patchStepName`, and `patchStepPrefix`
re-export automatically through `module Keiro.Workflow.Types` (line ~76), which is
already re-exported; confirm by building.

**Interpret `Patch` in the handler.** The handler is constructed inside
`runActive.interpreted` (lines ~329-413). Two edits:

1. Capture, once at handler setup, whether the instance was **already in flight when
   this run began** — i.e. whether the *pre-loaded* journal map (`initial`) holds any
   ordinary (non-reserved) step key. Reserved keys are those starting with one of the
   `sleep:`/`awk:`/`child:`/`patch:` prefixes or equal to a terminal marker; an
   *ordinary* step is any other. Add, right after `journalRef <- liftIO (newIORef
   initial)` (line ~331):

   ```haskell
   let startedInFlight = any isOrdinaryStepKey (Map.keys initial)
   ```

   with a local helper (place beside `decodeStored`, around line 415):

   ```haskell
   -- | A journal key counts as an /ordinary/ step (evidence the instance had
   -- already begun executing user logic) when it is neither a terminal marker
   -- nor a reserved wake-source/patch prefix.
   isOrdinaryStepKey :: Text -> Bool
   isOrdinaryStepKey k =
     not
       ( k `elem` [completedStepName, cancelledStepName, failedStepName]
           || any (`Text.isPrefixOf` k) [sleepStepPrefix, awakeableStepPrefix, childStepPrefix, patchStepPrefix]
       )
   ```

   `Text.isPrefixOf` is already available (`Data.Text` is imported qualified as
   `Text`); `completedStepName`, `cancelledStepName`, `failedStepName`, and the four
   prefixes all come from the already-imported `Keiro.Workflow.Types`.

2. Add the `Patch` case to the `handler`'s `case operation of` (after the
   `FreshOrdinal` case, line ~413). It mirrors the `Step` hit/miss structure but the
   miss path computes the decision from `startedInFlight` rather than running a user
   action, and journals a `Bool`:

   ```haskell
   Patch pid -> do
     let key = patchStepName pid
     journal <- liftIO (readIORef journalRef)
     case Map.lookup key journal of
       Just stored ->
         -- Hit: the decision was made on an earlier run; replay it verbatim.
         decodeStored key stored
       Nothing -> do
         -- Miss: first encounter. A fresh instance (nothing ordinary journaled
         -- when the run began) takes the new branch (True); an in-flight one
         -- takes the old branch (False). Journal the decision so it is stable.
         let decision = not startedInFlight
             encoded = Aeson.toJSON decision
         _ <- recordStep name wid (StepName key) encoded
         liftIO
           ( atomicModifyIORef' journalRef $ \m ->
               (Map.insert key encoded m, ())
           )
         pure decision
   ```

   Notes on the implementation choices, so a novice can follow:

   - `recordStep name wid (StepName key) encoded` is the *same* helper the `Step`
     miss path uses (lines ~462-465); it appends a `StepRecorded` to the journal
     stream and upserts the `keiro_workflow_steps` index row in one transaction, under
     the deterministic id `deterministicJournalId name wid key`. Because the id is
     deterministic and `recordStepTx` is an `INSERT ... ON CONFLICT DO NOTHING`, a
     concurrent or retried append of the same patch decision collapses to one row —
     the decision is journaled **exactly once** even under a race.
   - We insert into `journalRef` after recording so a *second* `patch` call for the
     same `pid` in the same run is a hit (it will not re-decide). This matches how the
     `Step` miss path updates the map.
   - We deliberately do **not** thread the patch decision through the snapshot-policy
     evaluation that the `Step` miss path does (`shouldSnapshot`). A patch decision is
     a tiny `Bool`; it does not change the accumulated user-state map in a way the
     snapshot needs to capture eagerly, and the next ordinary step's append re-checks
     the policy. Keeping the `Patch` case free of snapshot logic keeps it minimal and
     avoids coupling to EP-41's machinery. (If a later measurement shows a snapshot
     should also fire here, it is an additive one-line change; record it as a Surprise.)

**Why `startedInFlight` and not a count after the run starts.** If a fresh workflow
runs an ordinary `step` *before* its `patch` call, the live journal map would by then
contain an ordinary key, and a naive "any ordinary key now?" check would wrongly
classify that fresh instance as in-flight. Capturing `startedInFlight` from the
pre-loaded `initial` map (the journal as it was when the run began, before this run
executes anything) is the correct, replay-stable discriminator: it answers "had this
instance already begun, on a *previous* run, before this code path existed?" — which
is exactly "is it in flight?".

**Acceptance.** `cabal build keiro` succeeds with no warnings. A throwaway `cabal
repl keiro` can `:browse Keiro.Workflow` and see `patch`, `PatchId`, `patchStepName`.


### Milestone 3: the acceptance test

**Scope.** Add a `describe "Keiro.Workflow patch API"` block to `keiro/test/Main.hs`,
after the existing `describe "Keiro.Workflow"` block (around line 2104). Add the
helper workflows it needs to the helpers section (around lines 2979-3015, beside
`demoWorkflow`). Add `patch`, `PatchId (..)` to the `Keiro.Workflow` import list at
the top of the file (lines ~110-125). **At the end of this milestone**,
`cabal test keiro` is green and the new examples pass.

**The helper workflows.** Add two helpers that share a patch id and gate a branch on
it. The "old" shape (the workflow as it existed before the patch) and the "new" shape
(after) must use the *same* workflow function written once, parameterised so the test
can drive both an in-flight instance and a fresh one through identical code. The
cleanest expression is one patched workflow plus one un-patched predecessor:

```haskell
-- The patch id under test.
fraudPatchId :: PatchId
fraudPatchId = PatchId "fraud-check-v2"

-- The workflow BEFORE the patch shipped: reserve, then await an external step
-- (so an instance can be left in flight, mid-journal, with one ordinary step
-- recorded and no completion). Used to create the in-flight instance.
prePatchWorkflow :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es Text
prePatchWorkflow counter = do
  _ <- step (StepName "reserve-inventory") (liftIO (incrementAndRead counter) >> pure ())
  _ <- awaitStep (StepName "awk:gate") (pure ())   -- park here, in flight
  pure "old-done"

-- The workflow AFTER the patch shipped: the same first step, then a patch-gated
-- cross-cutting branch. The in-flight instance (which already journaled
-- reserve-inventory under the pre-patch code) must observe False and take the
-- OLD branch; a fresh instance must observe True and take the NEW branch.
postPatchWorkflow :: (Workflow :> es, IOE :> es) => IORef Int -> Eff es Text
postPatchWorkflow counter = do
  _ <- step (StepName "reserve-inventory") (liftIO (incrementAndRead counter) >> pure ())
  useNew <- patch fraudPatchId
  if useNew
    then step (StepName "new-charge") (pure "new-branch")
    else step (StepName "old-charge") (pure "old-branch")
```

Note: `prePatchWorkflow`'s `awaitStep (StepName "awk:gate")` leaves the instance
suspended with exactly one ordinary journaled step (`reserve-inventory`) and no
completion — the canonical in-flight state. We then run `postPatchWorkflow` against
that *same instance id*, simulating the redeploy.

**The examples.** Add the block:

```haskell
  describe "Keiro.Workflow patch API" $ around (withFreshStore fixture) $ do
    it "an in-flight instance observes the OLD branch; a fresh instance the NEW branch; the decision is journaled once and stable" $ \storeHandle -> do
      counter <- newIORef (0 :: Int)
      let name = WorkflowName "patchwf"
          inflight = WorkflowId "inflight-1"
          fresh = WorkflowId "fresh-1"

      -- 1. Run the in-flight instance to a suspension under the PRE-patch code.
      pre <- Store.runStoreIO storeHandle $ runWorkflow name inflight (prePatchWorkflow counter)
      pre `shouldBe` Right Suspended

      -- 2. Redeploy: re-run the SAME instance id under the POST-patch code.
      --    It already journaled reserve-inventory, so it is in flight -> False.
      r1 <- Store.runStoreIO storeHandle $ runWorkflow name inflight (postPatchWorkflow counter)
      r1 `shouldBe` Right (Completed "old-branch")

      -- 3. Replay the in-flight instance again: same OLD branch, every time.
      r2 <- Store.runStoreIO storeHandle $ runWorkflow name inflight (postPatchWorkflow counter)
      r2 `shouldBe` Right (Completed "old-branch")

      -- 4. A fresh instance under the POST-patch code takes the NEW branch.
      f1 <- Store.runStoreIO storeHandle $ runWorkflow name fresh (postPatchWorkflow counter)
      f1 `shouldBe` Right (Completed "new-branch")
      -- and stays on the new branch on replay.
      f2 <- Store.runStoreIO storeHandle $ runWorkflow name fresh (postPatchWorkflow counter)
      f2 `shouldBe` Right (Completed "new-branch")

      -- 5. The patch decision is journaled exactly once per instance, with the
      --    expected Bool, on the patch:<id> key.
      Right inflightJournal <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "wf:patchwf-inflight-1") (StreamVersion 0) 20
      let inflightDecisions =
            [ v
            | Right ev <- map (decodeRecorded workflowJournalCodec) (Vector.toList inflightJournal)
            , StepRecorded k v _ <- [ev]
            , k == patchStepName fraudPatchId
            ]
      inflightDecisions `shouldBe` [toJSON False]

      Right freshJournal <- Store.runStoreIO storeHandle $
        Store.readStreamForward (StreamName "wf:patchwf-fresh-1") (StreamVersion 0) 20
      let freshDecisions =
            [ v
            | Right ev <- map (decodeRecorded workflowJournalCodec) (Vector.toList freshJournal)
            , StepRecorded k v _ <- [ev]
            , k == patchStepName fraudPatchId
            ]
      freshDecisions `shouldBe` [toJSON True]
```

The list-comprehension pattern `[ ... | Right ev <- ..., StepRecorded k v _ <- [ev], k == ... ]`
collects only the `patch:fraud-check-v2` decisions; asserting it equals a one-element
list proves the decision is recorded **exactly once** (idempotent re-appends collapse,
per the `INSERT ... ON CONFLICT DO NOTHING` in `recordStepTx`), and its value proves
the branch.

If `Text.isPrefixOf` or `toJSON` need imports the test file already provides them
(the file imports `Data.Aeson (toJSON)` and uses `decodeRecorded` and
`workflowJournalCodec` in the neighbouring `Keiro.Workflow` block). Add `patch` and
`PatchId (..)` to the `Keiro.Workflow` import list and `patchStepName` (which
re-exports through `Keiro.Workflow`).

**Acceptance.** `cabal test keiro` passes, with the new block reporting its examples
green. The example count rises by the number of `it` blocks added (one here).


### Milestone 4: documentation and roadmap reconciliation

**Scope.** Document the primitive and flip the user-facing "deferred" framing. **At
the end of this milestone**, the guide explains rename-vs-patch, the user reference
lists the signature, and the roadmap / production-status no longer mark the
versioning / patch API as deferred.

- `docs/guides/durable-workflows.md` — add a short subsection "Versioning a running
  workflow: rename a step, or patch" after the journaling/replay discussion. State the
  rename-a-step common case first (one step changed → change its `StepName`), then the
  `patch` escape hatch for cross-cutting changes, with the fraud-check example from
  this plan's Purpose section as the fenced `haskell` block. Be explicit that `patch`
  is the *rare* case.

- `docs/user/durable-workflows.md` — add `patch :: PatchId -> Eff es Bool` and the
  `PatchId` newtype to the API surface list, in a fenced `haskell` block, with a
  one-line gloss: "stable, journaled branch decision for a cross-cutting change;
  prefer renaming a step for single-step changes."

- `docs/user/roadmap.md` — the "Durable Execution Boundaries" / capability notes that
  list "versioning / patch API" as still-deferred (per EP-45 Milestone 4, which kept
  continue-as-new and the versioning-patch-API as the genuinely-deferred items) must
  move the patch API from deferred to available. Leave continue-as-new's status to
  EP-48.

- `docs/user/production-status.md` — wherever it lists the versioning/patch API as a
  deferred piece of the named-step runtime, mark it available; keep the named-vs-
  positional design statement intact (it is the central selling point).

If any of these files do not yet contain a "versioning / patch API" line at
implementation time (because EP-45 / EP-48 edits interleave), search for the nearest
"deferred" list under the durable-execution heading and add the patch-API-available
line there. Record any such reconciliation as a Surprise.

**Acceptance.** `grep -rn "patch" docs/guides/durable-workflows.md
docs/user/durable-workflows.md` shows the new content; the roadmap / production-status
no longer list the patch API among deferred items.


### Milestone 5: full-repo green and acceptance capture

**Scope.** Build the whole workspace and run the keiro test suite; record the real
output into Validation and Acceptance. **At the end of this milestone**, every command
in Validation and Acceptance has run and its output is reconciled here.

This milestone adds no new source; it is the verification gate. Run `cabal build all`
and `cabal test keiro`, and paste the relevant tail of the test output into Validation
and Acceptance (updating expectations if reality differs and recording the difference
in Surprises & Discoveries).


## Concrete Steps

Run all commands from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`. The
`keiro` DB tests use an ephemeral PostgreSQL provided by the test harness
(`Keiro.Test.Postgres.withFreshStore`); no external database setup is needed for
`cabal test keiro`.

**Step 1 — add the identity/naming pieces and build:**

```bash
$EDITOR keiro/src/Keiro/Workflow/Types.hs   # add PatchId, patchStepPrefix, patchStepName + exports
cabal build keiro
```

Expected tail:

```text
[N of M] Compiling Keiro.Workflow.Types ( ... )
...
Linking ... (or "Up to date" on a repeat)
```

with no warnings.

**Step 2 — add the effect operation, constructor, and handler case; build:**

```bash
$EDITOR keiro/src/Keiro/Workflow.hs         # add Patch op, patch ctor, handler case, isOrdinaryStepKey, startedInFlight
cabal build keiro
```

Expected: a clean build. If GHC reports a non-exhaustive `case operation of`, the
`Patch` case was not added to the handler — add it.

**Step 3 — add the test and run the keiro suite:**

```bash
$EDITOR keiro/test/Main.hs                  # add the describe block + helper workflows + imports
cabal test keiro
```

Expected: the suite passes; the new `Keiro.Workflow patch API` example is green. See
Validation and Acceptance for the expected shape.

**Step 4 — documentation and roadmap edits:**

```bash
$EDITOR docs/guides/durable-workflows.md
$EDITOR docs/user/durable-workflows.md
$EDITOR docs/user/roadmap.md
$EDITOR docs/user/production-status.md
grep -rn "patch" docs/guides/durable-workflows.md docs/user/durable-workflows.md
```

Expected: the grep shows the new rename-vs-patch guidance and the `patch` signature.

**Step 5 — full-repo green:**

```bash
cabal build all
cabal test keiro
```

Expected: every package builds; the keiro suite passes.


## Validation and Acceptance

Acceptance is **observable behavior**, not the presence of code. The checks below must
all pass.

**Check 1 — the stable-branch semantics (the load-bearing acceptance).** Running
`cabal test keiro` runs the new `Keiro.Workflow patch API` example, which proves, in
one ephemeral-Postgres run:

- An instance run to a suspension under the *pre-patch* code (`prePatchWorkflow`,
  which journals `reserve-inventory` then parks on `awk:gate`) returns `Suspended`.
- Re-running that **same instance id** under the *post-patch* code
  (`postPatchWorkflow`) completes on the **old** branch — `Completed "old-branch"` —
  because the instance was already in flight when the patch shipped (it had a journaled
  ordinary step), so `patch fraudPatchId` returned `False`.
- Replaying that same instance again still returns `Completed "old-branch"` — the
  decision is **stable across re-invocations**.
- A **fresh** instance id under the post-patch code completes on the **new** branch —
  `Completed "new-branch"` — because `patch fraudPatchId` returned `True`, and stays
  there on replay.
- The journal of the in-flight instance carries **exactly one** `patch:fraud-check-v2`
  decision, equal to JSON `false`; the journal of the fresh instance carries exactly
  one, equal to JSON `true`. Exactly-one proves the decision is journaled once
  (idempotent re-appends collapse via `INSERT ... ON CONFLICT DO NOTHING`).

Expected hspec tail (event counts/timestamps will differ; reconcile during M5):

```text
  Keiro.Workflow patch API
    an in-flight instance observes the OLD branch; a fresh instance the NEW branch; the decision is journaled once and stable [✔]

Finished in N.NNNN seconds
M examples, 0 failures
```

**Check 2 — no regression.** The existing `Keiro.Workflow` and
`Keiro.Workflow snapshots` blocks still pass unchanged — the `Patch` case is purely
additive to the handler and changes no existing operation, and the `patch:` prefix
collides with no existing reserved prefix or ordinary step name.

**Check 3 — the whole workspace builds.** `cabal build all` is green, proving the
additive `PatchId`/`patch`/`Patch` surface breaks no downstream package (notably the
`jitsurei` worked-examples package, which imports `Keiro.Workflow`).


## Idempotence and Recovery

Every step in this plan is safe to repeat.

- The source edits are additive (a new newtype, a new prefix, a new effect operation
  and its handler case, a new test block); re-applying them on top of a partial edit
  is a textual merge, and a half-applied edit surfaces as a compile error
  (`cabal build keiro`) that names exactly what is missing (e.g. a non-exhaustive
  `case operation of` if the `Patch` case is absent). Build after each step.

- The runtime behaviour is itself idempotent by construction. A patch decision is
  journaled under a **deterministic** event id (`deterministicJournalId name wid
  "patch:<pid>"`) and upserted with `INSERT ... ON CONFLICT (workflow_id, step_name)
  DO NOTHING` (`recordStepTx`), so re-running a workflow — the crash-restart scenario
  — never writes a second decision and never changes the first. Running the acceptance
  test repeatedly is safe: each example gets a fresh ephemeral store via
  `withFreshStore`, so there is no cross-run state.

- There is **no migration** and **no codec change**, so there is nothing to roll back
  at the schema level. If you decide mid-implementation to use a dedicated
  `WorkflowPatched` constructor instead of the `patch:` prefix (we chose against it —
  see the Decision Log), that would be an additive codec change within
  `schemaVersion = 1` requiring no upcaster, and old journals (which never carry it)
  remain decodable; but this plan does not take that path.

- Recovery from a wrong decision in *production* (an operator realises a patch was
  mis-gated) is a workflow-authoring action, not a runtime one: because each instance's
  decision is permanent, the remedy is to ship a *new* `PatchId` (never reuse the old
  one) gating the corrected branch, exactly as Temporal recommends for `patched`.


## Interfaces and Dependencies

This plan builds only on the **already-shipped MasterPlan 5 surface** — the
`Keiro.Workflow` effect, the `wf:<name>-<id>` journal, the `keiro_workflow_steps`
index, and `WorkflowRunOptions` — plus the additive convention the runtime already
uses for reserved-prefix journal entries. It adds no upstream (kiroku/keiki/shibuya)
dependency and **no database migration** (confirmed: a patch decision is a
`StepRecorded` row in the existing index and a `StepRecorded` event on the existing
journal stream; `recordStepTx` upserts any `(workflow_id, step_name)` without schema
change). It **soft-depends on EP-48** (continue-as-new) per the MasterPlan Dependency
Graph: if EP-48 lands first, EP-49 inherits its generation-aware replay loop for free
because the patch decision rides the same `StepRecorded` mechanism EP-48 leaves
intact; this plan applies cleanly with or without EP-48.

**New types and functions (full signatures).**

In `keiro/src/Keiro/Workflow/Types.hs`:

```haskell
newtype PatchId = PatchId {unPatchId :: Text}
  deriving stock (Eq, Ord, Show, Generic)

patchStepPrefix :: Text          -- = "patch:"
patchStepName   :: PatchId -> Text  -- = patchStepPrefix <> unPatchId pid
```

In `keiro/src/Keiro/Workflow.hs`:

```haskell
-- new Workflow effect operation
data Workflow :: Effect where
  ...
  Patch :: PatchId -> Workflow m Bool

-- new smart constructor (re-exported from Keiro.Workflow)
patch :: (Workflow :> es) => PatchId -> Eff es Bool
patch pid = send (Patch pid)
```

The handler interpretation of `Patch` lives inside `runWorkflowWith` and reuses the
existing `recordStep`, `decodeStored`, `journalRef`, and the new `startedInFlight`
flag / `isOrdinaryStepKey` helper, as specified in Plan of Work, Milestone 2.

**Existing surface relied upon (unchanged).**

- `Keiro.Workflow.Types`: `WorkflowName (..)`, `WorkflowId (..)`, `StepName (..)`,
  `WorkflowJournalEvent (StepRecorded ...)`, `workflowJournalCodec`,
  `workflowStreamName`, the reserved prefixes `sleepStepPrefix`/`awakeableStepPrefix`/
  `childStepPrefix`, and the terminal markers `completedStepName`/`cancelledStepName`/
  `failedStepName`. The patch decision is a `StepRecorded` event keyed under
  `patch:<pid>` — no new constructor, no codec edit.
- `Keiro.Workflow`: `runWorkflow`, `runWorkflowWith`, the handler's `journalRef`,
  `recordStep` (appends a `StepRecorded` + index row in one transaction under a
  deterministic id), `decodeStored`, `appendJournalEntry`.
- `Keiro.Workflow.Schema`: `recordStepTx` (the `INSERT ... ON CONFLICT DO NOTHING`
  upsert that makes the decision exactly-once), `stepExists`,
  `findUnfinishedWorkflowIds` — all consume the `patch:<pid>` row transparently
  because they are step-name-agnostic.
- Test harness: `Keiro.Test.Postgres.withFreshStore`, `hspec`,
  `Store.runStoreIO`/`Store.readStreamForward`, `decodeRecorded`,
  `workflowJournalCodec`.

**The cleanup / deprecation story (future work, noted not built).** A patch decision
becomes dead once every instance that could observe `False` for it has terminated. At
that point the author may delete the `patch` call and (per the named-step model)
rename the affected steps for the next version. A future `deprecatePatch :: PatchId ->
Eff es Bool` helper could *assert* — by querying historical journals — that no live
instance still carries `patch:<pid> == False` before the call is removed, turning a
folklore "is it safe to drop this patch yet?" question into a checkable one. That
query earns its keep only at scale and is out of scope here (the research doc §6.5
frames the whole patch API as a v2.5 escape hatch); a `PatchId` must **never be
reused** once retired, exactly as with Temporal's patch ids.

---

**Git trailers.** Every commit made while working on this ExecPlan must carry these
three trailers at the end of the commit message body, separated from the summary by a
blank line:

```text
MasterPlan: docs/masterplans/6-v2-durable-execution-phase-2-rotation-versioning-push-delivery-and-sharding.md
ExecPlan: docs/plans/49-workflow-versioning-and-patch-api.md
Intention: intention_01kt7npy22e5tb3ybycsgeqdnm
```
