---
id: 45
slug: durable-workflow-worked-example-and-guide
title: "Durable workflow worked example and guide"
kind: exec-plan
created_at: 2026-06-03T14:39:45Z
intention: "intention_01kt6y4cb6eqz9mq48kf2xw8n1"
master_plan: "docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md"
---

# Durable workflow worked example and guide

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, a reader can run one command — `cabal run jitsurei:exe:jitsurei-demo --
workflow` — and watch a long-running **durable workflow** drive itself from start to
finish across a simulated process restart, then read the workflow's journal and see every
named checkpoint that made the resumption possible. They can then follow a long-form guide
and a short user-reference page that explain the four durable-execution primitives in their
own words, copy real, compiling code out of the `jitsurei` package, and see the project's
own roadmap and production-status pages declare the durable-execution runtime *Available*
rather than *Planned*.

A **durable workflow** here means an ordinary imperative Haskell function of type
`Workflow es a` whose side effects are recorded ("journaled") at *named checkpoints* so the
function can be paused — across a crash, a redeployment, or an idle wait — and resumed by
re-invoking it from the top while *short-circuiting* the checkpoints it already completed.
"Short-circuit" means: on a re-run, a `step "charge"` that already ran returns its recorded
result instead of charging the card a second time. This is the capability MasterPlan 5
(`docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md`) set out to
deliver, and this plan is its Wave 5 — the worked example, the guide, and the documentation
that can only be honest once every API it references exists.

Concretely, this plan delivers four things:

1. **A runnable worked example** in the sibling `jitsurei` Cabal package: a new module
   `jitsurei/src/Jitsurei/DurableWorkflow.hs` defining an order-fulfillment workflow that
   reserves inventory (a named `step`), waits out a short cooling-off period (a durable
   `sleepNamed`), waits for a payment webhook (an `awakeableNamed` resolved by an external
   `signalAwakeable`), charges the card (a named `step`), and spawns a "ship-order" *child
   workflow* it then waits on (`spawnChild`/`awaitChild`). A new `jitsurei-demo` CLI
   subcommand `workflow` runs it to its first suspension, fires the sleep timer, signals the
   awakeable, runs the resume worker to completion, prints the journal, and then *re-opens
   the store and re-runs the resume worker* to prove the workflow resumes from the journal
   rather than from scratch.

2. **A long-form guide** `docs/guides/durable-workflows.md` (prose-first, in the style of
   `docs/guides/process-managers-and-timers.md`) that explains what durable execution is,
   when to reach for it versus a process manager, the four primitives, journaling and
   replay, the resume worker, awakeables, child workflows, snapshots, and operational notes
   — every code snippet copy-pasteable from the `jitsurei` source above.

3. **A user-reference page** `docs/user/durable-workflows.md` (shorter, API-oriented, in the
   style of `docs/user/process-managers-and-timers.md`), linked from `docs/user/README.md`.

4. **Documentation reconciliation**: flip the `docs/user/roadmap.md` capability-matrix row
   "Durable execution runtime" from `Planned v2` to `Available now`, reframe the roadmap's
   Phase 5 section from "planned" to "shipped", revise `docs/user/production-status.md` so
   the "Durable execution is deferred" subsection and the "Template-style deterministic
   durable execution" Not-A-Good-Fit line reflect the now-available **named-step** runtime,
   and add a short operations note to `docs/user/operations.md` (resume worker, awakeable
   repair via `cancelAwakeable`, journal snapshot policy) reconciled with what EP-40, EP-41,
   and EP-42 actually shipped.

**Why this matters from a user's perspective:** before this plan, the durable runtime exists
in the library (EP-38…EP-44) but a newcomer has no single, runnable, end-to-end story that
*proves* durability, and the project's own user-facing docs still say durable execution is
deferred. After this plan, a newcomer can run one command, read a guide, copy working code,
and trust the roadmap.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1: write `jitsurei/src/Jitsurei/DurableWorkflow.hs` (the workflow, its child
  workflow, the `WorkflowRegistry`, deterministic ids, and the demo-driver helpers) and add
  it to `jitsurei/jitsurei.cabal` `exposed-modules` and to the `Jitsurei` umbrella module.
- [x] Milestone 1: confirm `cabal build jitsurei:lib:jitsurei` is green.
- [x] Milestone 2: add the `workflow` subcommand to `jitsurei/app/Main.hs` (dispatcher, the
  `all` path, and the usage string) and implement `runDurableWorkflowDemo`.
- [x] Milestone 2: run `cabal run jitsurei:exe:jitsurei-demo -- workflow` against the
  repo-local PostgreSQL and capture the real transcript; reconcile it with the expected
  transcript in this plan (see Validation and Surprises).
- [x] Milestone 3: write `docs/guides/durable-workflows.md` and add it to the
  `docs/guides/README.md` index (and a routing row in `docs/guides/choosing-a-primitive.md`).
- [x] Milestone 3: write `docs/user/durable-workflows.md` and link it from
  `docs/user/README.md`.
- [ ] Milestone 4: flip the `docs/user/roadmap.md` capability-matrix row and reframe Phase 5;
  revise `docs/user/production-status.md`; add the `docs/user/operations.md` note.
- [ ] Milestone 5: full-repo green — `cabal build all`, `cabal test keiro`,
  `cabal test jitsurei-test`, and the demo command — recorded in Validation and Acceptance.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-03 (M2): **A parent and its child workflow must use distinct `WorkflowId`s.** The
  first draft reused the order id text for both (parent `wf:order-fulfillment-<order>`, child
  `wf:ship-order-<order>` — same id, different name). The demo then "completed" without the
  parent ever journaling a `WorkflowCompleted`: `findUnfinishedWorkflowIds`
  (`keiro/src/Keiro/Workflow/Schema.hs`) groups by `workflow_id` *alone* (the `NOT EXISTS`
  subquery matches `c.workflow_id = s.workflow_id`, ignoring `workflow_name`), so the child's
  `__workflow_completed__` row masked the parent's incompleteness and the parent dropped out of
  resume discovery prematurely. Fix: `shipChildId orderId = WorkflowId (orderIdText orderId <>
  "-ship")`, distinct from `workflowIdFor orderId`. With distinct ids the resume worker drives
  the parent to completion in a final pass (transcript pass 4: `completed = 1, stillSuspended =
  0`) and the parent journal correctly ends with `WorkflowCompleted` at version 7. This matches
  the keiro test suite, which always uses distinct parent/child ids (parent `p1`, child
  `ship-1`). Recorded to the MasterPlan Surprises as a cross-cutting contract for EP-43 users.
- 2026-06-03 (M2): **The awakeable journal step is `awk:<uuid>`, not `awk:<label>`.**
  `awakeableNamed (StepName "payment-webhook")` derives a deterministic `AwakeableId` from the
  label and journals its completion under `awakeableStepPrefix <> awakeableIdText aid` — i.e.
  `awk:<uuid>`. The external `signalAwakeable (paymentWebhookAwakeableId orderId) …` targets the
  *same* deterministic id (computed via `deterministicAwakeableId`), which is the
  idempotent-arming contract working as designed. The guide and transcript cite `awk:<uuid>`.
- 2026-06-03 (M2): **Demo environment — workflow tables and the `kiroku` schema.** The kiroku
  `Store` connects with `search_path = kiroku` (`Store.defaultConnectionSettings`), so the
  `keiro_workflow_steps` / `keiro_awakeables` / `keiro_workflow_children` tables must live in
  the `kiroku` schema. The `keiro-migrations` files issue unqualified `CREATE TABLE`, so they
  land in `kiroku` only when applied in the same codd batch as the schema-creating kiroku
  migration (a fresh database, as in `cabal test` and `just jitsurei-migrate` against a clean
  db). On a pre-existing dev database where only the three new migrations are pending, they
  land in `public` and the demo cannot see them; recreate the `jitsurei` database (or
  `ALTER TABLE … SET SCHEMA kiroku`) so the demo's Store finds them. This is a migration/dev-DB
  property, not an EP-45 code concern.


## Decision Log

Record every decision made while working on the plan.

- Decision: Model the worked example as an **order-fulfillment** durable workflow
  (`reserve-inventory` → `cooling-off` sleep → `payment-webhook` awakeable → `charge` →
  `ship-order` child workflow), reusing the order vocabulary already established across the
  `jitsurei` package (`Jitsurei.Domain`, `Jitsurei.OrderStream`).
  Rationale: MasterPlan 5's Vision sketches exactly this `orderFulfillment` shape, and the
  `jitsurei` package already centres on orders, so the example reads as a continuation of the
  existing guides rather than a new domain a reader must learn. It exercises all four
  primitives plus a child workflow in one believable narrative.
  Date: 2026-06-03.

- Decision: The new demo is a separate `jitsurei-demo` subcommand `workflow`, added to the
  dispatcher, the `all` path, and the usage string — mirroring how `snapshots`, `paging`,
  `escalation`, and `agent-qual` were each added as independent subcommands.
  Rationale: Keeps each demo independently runnable and verifiable, matching the existing
  CLI shape in `jitsurei/app/Main.hs` (the dispatcher at lines ~45–58). A reader can run just
  the workflow story without the unrelated demos.
  Date: 2026-06-03.

- Decision: This plan writes the *plan only*. It does **not** implement the demo module, edit
  the guides, or flip the roadmap. Those edits are the implementation of this plan, performed
  in the milestones below by whoever executes it.
  Rationale: The skill brief for authoring this ExecPlan is explicit: write the PLAN, not the
  demo. The plan must nonetheless be self-contained enough that a novice can perform every
  edit from it alone.
  Date: 2026-06-03.

- Decision: The expected transcript captured in Validation and Acceptance is the *contract*
  the demo must satisfy. If the real run differs (timestamps, generated ids, exact event
  counts), the implementer updates the transcript in this plan to match the real output and
  records the difference in Surprises & Discoveries.
  Rationale: PLANS.md requires observable acceptance with expected output; a living plan keeps
  the captured transcript truthful rather than aspirational.
  Date: 2026-06-03.

- Decision: Reference only the surfaces EP-38…EP-44 actually export. Where a downstream plan
  (EP-42 resume worker, EP-43 child workflows, EP-44 observability) was still a skeleton at
  the time this plan was authored, this plan names the surface the MasterPlan's Integration
  Points fix (`resumeWorkflowsOnce`, `WorkflowRegistry`/`WorkflowDef`,
  `spawnChild`/`awaitChild`/`cancelChild`, the `keiro.workflow.*` metrics) and instructs the
  implementer to reconcile the exact spellings against the as-shipped modules before writing
  any copy-pasteable code.
  Rationale: EP-45 is Wave 5 and soft-depends on every other plan; it must reference functions
  that exist. The MasterPlan's Integration Points are the authoritative contract for the
  not-yet-fleshed plans, and the implementer runs after they ship.
  Date: 2026-06-03.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

**The repository.** Keiro is a Haskell event-sourcing framework built on three libraries —
`kiroku` (a PostgreSQL event store), `keiki` (event-sourcing transducers/codecs), and
`shibuya` (message-stream adapters) — using the `effectful` effect system. The Cabal packages
are `keiro-core` (the codec/event-stream contract), `keiro` (the runtime: commands, process
managers, routers, timers, outbox, inbox, telemetry, and — new in MasterPlan 5 — workflows),
`keiro-migrations` (embedded SQL migrations), `keiro-test-support` (test fixtures), and
`jitsurei` (worked examples that back the guides). All Cabal commands in this plan run from
the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

**`jitsurei` is the worked-examples package.** It is *not* pseudocode: it compiles as part of
this workspace and `cabal test jitsurei-test` exercises it. Its layout:

- `jitsurei/jitsurei.cabal` declares a library (`exposed-modules` at lines ~35–48), an
  executable `jitsurei-demo` (`main-is: Main.hs`, `hs-source-dirs: app`), an executable
  `jitsurei-diagrams`, and a test-suite `jitsurei-test`.
- `jitsurei/src/Jitsurei.hs` is the umbrella module that re-exports every `Jitsurei.*`
  submodule. Adding a new submodule means adding it both to the cabal `exposed-modules` and
  to this umbrella's export list and import list.
- `jitsurei/src/Jitsurei/*.hs` are the example modules: `Domain` (order/incident
  vocabulary), `OrderStream` (the order `EventStream`, command codec, deterministic
  `orderStream`/`orderCommandStream` naming, and a snapshot variant
  `snapshotOrderEventStream`), `FulfillmentProcess` (a process manager), `EscalationProcess`
  (a saga + timer), `Paging`/`AgentQualRouter` (routers), `Timers` (a `keiro_timers`
  example), `ReadModels`, `Database` (`initializeJitsureiTables`, `withJitsureiStore`).
- `jitsurei/app/Main.hs` is the demo CLI. `main` dispatches on `getArgs`: an empty argument
  list or `fulfillment` runs the fulfillment demo; `snapshots`, `paging`, `escalation`,
  `agent-qual` run their demos; `all` runs every demo in sequence; anything else fails with a
  usage string (`"usage: jitsurei-demo [fulfillment|snapshots|paging|escalation|agent-qual|all]"`).
  Each demo follows one pattern: `withJitsureiStore $ \store -> do …` opens a Kiroku store,
  `requireEither =<< Store.runStoreIO store initializeJitsureiTables` creates the framework
  tables, the demo appends events / runs workers, then `readEvents store "<stream>"` reads
  back and `printDecoded codec events` prints them. Helpers in `Main.hs` worth reusing:
  `withJitsureiStore`, `requireEither`, `readEvents`, `printDecoded`, `freshTextId`,
  `freshOrderId`.

**The durable-workflow runtime (MasterPlan 5, EP-38…EP-44).** These plans add a
`Keiro.Workflow` module family to the `keiro` package. The reader of *this* plan needs the
following surface, which the sibling plans fix (full signatures are repeated in Interfaces
and Dependencies). A **workflow** is a value of type `Workflow es a` written as a `do`-block.
A **named step** `step (StepName "reserve-inventory") action` runs `action` once and journals
its JSON-encoded result; on replay it returns the recorded result without re-running
`action`. A **journal** is a kiroku stream named `wf:<workflow-name>-<workflow-id>` (built by
`workflowStreamName`); it is where every step result and the terminal `WorkflowCompleted`
event are appended. `runWorkflow name wfId action` runs the workflow and returns a
`WorkflowOutcome a` that is either `Completed a` (the workflow finished) or `Suspended` (it
hit an unresolved wait — a sleep, an awakeable, or a child it is waiting on — and parked). A
**durable sleep** `sleepNamed (StepName "cooling-off") delta` (EP-39) schedules a row in the
existing `keiro_timers` table; when the timer worker fires, it appends a `sleep:` completion
to the journal so the next run continues past the sleep. An **awakeable** `awakeableNamed
(StepName "payment-webhook")` (EP-40) returns an `(AwakeableId, Eff es a)` pair: the workflow
blocks on the second component until an external caller invokes `signalAwakeable awkId
payload`, which records the payload in the journal; `cancelAwakeable awkId` aborts a stuck
one. The **resume worker** `resumeWorkflowsOnce` (EP-42) discovers journals lacking a
terminal `WorkflowCompleted` event and re-invokes them through a `WorkflowRegistry` (a lookup
from workflow name to a `WorkflowDef` describing how to rebuild and re-run that workflow),
short-circuiting already-journaled steps. **Snapshots** (EP-41): `runWorkflowWith` takes a
`WorkflowRunOptions` whose `snapshotPolicy` field controls when the accumulated step-result
map is snapshotted via the workflow-specific `workflowStateCodec` (shape-hash sentinel
`"keiro.workflow.stepmap.v1"`). **Child workflows** (EP-43): `spawnChild` records a child
handle in the parent's journal and starts the child; `awaitChild` blocks the parent (like an
awakeable) until the child completes; `cancelChild` cancels it.

**The documentation set this plan owns.** Per the MasterPlan's "`docs/user/` documentation
set" integration point, EP-45 owns the *final consolidated state* of:

- `docs/user/roadmap.md` — a phase-by-phase roadmap with a "Capability Matrix" table (lines
  ~26–44). The row `| Durable execution runtime | Planned v2 | … |` (line ~44) must flip to
  `Available now`. The "Phase 5: v2 Durable Execution" section (lines ~316–351) currently
  frames the runtime as planned; it must read as shipped. The phase-summary row for Phase 5
  (line ~22) must likewise read as delivered.
- `docs/user/production-status.md` — the "Not A Good Fit Yet" list (lines ~51–59) contains
  "you need Temporal-style deterministic durable execution"; and the "Durable execution is
  deferred" subsection (lines ~71–76) says the v2 runtime is intentionally deferred. Both must
  be revised to reflect the now-available **named-step** runtime — and must be careful to say
  *named-step*, not *positional-determinism*: the design is explicitly named steps (stable
  across source reordering), not Temporal-style positional history.
- `docs/user/operations.md` — has sections `## Runtime Processes`, `## Timers`, `## Snapshots`,
  `## Observability` (with a "Metric catalogue" subsection). This plan adds a short
  "Durable workflows" operations note: how to run the resume worker, how to repair a stuck
  awakeable with `cancelAwakeable`, and the journal snapshot policy.
- `docs/user/README.md` — the user-guide index (the "Start here" list, lines ~16–47). This
  plan inserts a link to the new `docs/user/durable-workflows.md` after the process-managers
  entry.
- `docs/guides/durable-workflows.md` — **new** long-form guide.
- `docs/guides/README.md` — the guides index (lines ~10–35). This plan inserts a link to the
  new guide after the process-managers entry.

**Terms defined.** *Replay* = re-running a workflow function from the top, returning recorded
step results instead of re-executing side effects. *Suspension* = a workflow parking at an
unresolved wait, returning `Suspended` from `runWorkflow`. *Resume* = the resume worker
re-invoking a suspended workflow after its wait resolved. *Awakeable* = a durable promise an
external system resolves out-of-band. *Child workflow* = a workflow spawned and awaited by
another (parent) workflow, with the handle recorded in the parent's journal so the
relationship survives a crash. *Idempotent arming* = re-running a wait's setup (scheduling
the same timer id, registering the same awakeable id, spawning the same child id) collapses to
a no-op on every resume, because the ids are deterministic.


## Plan of Work

The work is five milestones. Milestones 1–2 build and verify the runnable demo; milestone 3
writes the two documentation pages and wires them into their indexes; milestone 4 flips the
roadmap and production-status framing; milestone 5 proves the whole repository stays green.
Each milestone is independently verifiable.

**Before starting, reconcile the surface.** EP-42 (resume worker), EP-43 (child workflows),
and EP-44 (observability) were skeletons when this plan was authored; the implementer of this
plan runs after they ship. Before writing any copy-pasteable code, open the as-shipped
modules and confirm the exact spellings of `resumeWorkflowsOnce`, `WorkflowRegistry`,
`WorkflowDef`, `spawnChild`/`awaitChild`/`cancelChild`, and the `keiro.workflow.*` metric
names. The MasterPlan's Integration Points fix the *contract* (names, shapes, reserved
prefixes); the modules fix the *exact identifiers*. Run, from the repository root:

```bash
grep -rn "resumeWorkflowsOnce\|WorkflowRegistry\|WorkflowDef\|spawnChild\|awaitChild\|cancelChild" keiro/src/Keiro/Workflow
ls keiro/src/Keiro/Workflow
```

and read the `exposed-modules` of `keiro/keiro.cabal` to see which `Keiro.Workflow.*` modules
exist. Adjust the import lists in the steps below to match. The signatures repeated in
Interfaces and Dependencies are the as-designed contract; treat any mismatch as a Surprise to
record, then follow the real surface.


### Milestone 1: the durable-workflow example module

**Scope.** Create `jitsurei/src/Jitsurei/DurableWorkflow.hs` defining the order-fulfillment
durable workflow, its "ship-order" child workflow, the deterministic ids, the
`WorkflowRegistry` the resume worker uses, and small driver helpers. Wire the module into
`jitsurei/jitsurei.cabal` and `jitsurei/src/Jitsurei.hs`. **At the end of this milestone**,
`cabal build jitsurei:lib:jitsurei` is green and the new module is importable, but nothing
runs it yet.

**The workflow.** Define the parent workflow as a `Workflow es a` do-block that exercises all
four primitives plus a child workflow, in this exact order so the demo narrative and the
expected transcript line up:

```haskell
-- jitsurei/src/Jitsurei/DurableWorkflow.hs  (illustrative; reconcile imports with the shipped surface)
module Jitsurei.DurableWorkflow
  ( orderFulfillmentWorkflowName
  , shipOrderWorkflowName
  , orderFulfillmentWorkflow
  , shipOrderWorkflow
  , paymentWebhookAwakeableId
  , jitsureiWorkflowRegistry
  , coolingOffDelay
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Time (NominalDiffTime)
import Effectful (Eff, IOE, (:>))
import GHC.Generics (Generic)
import Keiro.Workflow
  ( Workflow, WorkflowName (..), WorkflowId (..), StepName (..)
  , step, runWorkflow )
import Keiro.Workflow.Sleep (sleepNamed)
import Keiro.Workflow.Awakeable (AwakeableId, awakeableNamed, deterministicAwakeableId)
import Keiro.Workflow.Child (spawnChild, awaitChild)   -- reconcile against the shipped EP-43 module
import Kiroku.Store.Effect (Store)
import Jitsurei.Domain (OrderId, orderIdText)

orderFulfillmentWorkflowName :: WorkflowName
orderFulfillmentWorkflowName = WorkflowName "order-fulfillment"

shipOrderWorkflowName :: WorkflowName
shipOrderWorkflowName = WorkflowName "ship-order"

-- A short, demo-friendly cooling-off period. Real workflows would sleep minutes/hours.
coolingOffDelay :: NominalDiffTime
coolingOffDelay = 2

-- The parent: reserve inventory, cool off, wait for the payment webhook, charge,
-- then ship via a child workflow and return the tracking number.
orderFulfillmentWorkflow
  :: (Workflow :> es, Store :> es, IOE :> es)
  => OrderId -> Eff es Text
orderFulfillmentWorkflow orderId = do
  _reservation <- step (StepName "reserve-inventory") (reserveInventory orderId)
  sleepNamed (StepName "cooling-off") coolingOffDelay
  (_awkId, awaitPayment) <- awakeableNamed (StepName "payment-webhook")
  payment <- awaitPayment :: Eff es PaymentConfirmation
  _charge <- step (StepName "charge") (chargeCard orderId payment)
  childId <- spawnChild shipOrderWorkflowName (shipChildId orderId) (shipOrderWorkflow orderId)
  tracking <- awaitChild childId :: Eff es Text
  pure tracking

-- The child: a one-step workflow that produces a shipment tracking number.
shipOrderWorkflow
  :: (Workflow :> es, Store :> es, IOE :> es)
  => OrderId -> Eff es Text
shipOrderWorkflow orderId =
  step (StepName "create-shipment") (createShipment orderId)
```

The `reserveInventory`, `chargeCard`, and `createShipment` "side effects" should be small,
deterministic, side-effect-free-but-believable actions (e.g. returning a derived reservation
id / charge id / tracking number from the `OrderId`), printing a line so the transcript shows
*when a step actually ran* versus *when it was replayed from the journal*. Define
`PaymentConfirmation` as a tiny `Generic`/`ToJSON`/`FromJSON` record (e.g. `{ paymentRef ::
Text, amountCents :: Int }`) so the awakeable payload round-trips through JSON. Define
`paymentWebhookAwakeableId :: OrderId -> AwakeableId` using `deterministicAwakeableId
orderFulfillmentWorkflowName (workflowIdFor orderId) "payment-webhook"` so the demo can
compute the exact id to signal without reading it back from the journal. (`awakeableNamed`
derives the same id from the same inputs — this is the idempotent-arming contract from the
MasterPlan: the demo's external `signalAwakeable` must target the *same* id the workflow
registered.)

**The registry.** The resume worker (EP-42) needs a `WorkflowRegistry` mapping each workflow
name to a `WorkflowDef` that tells it how to rebuild and re-run the workflow body from the
workflow id. Build `jitsureiWorkflowRegistry` registering both `order-fulfillment` and
`ship-order`. The exact `WorkflowDef` constructor/field shape is owned by EP-42; reconcile it
against the shipped module. Conceptually:

```haskell
-- Reconcile WorkflowDef / WorkflowRegistry / registerWorkflow against the shipped EP-42 surface.
jitsureiWorkflowRegistry :: WorkflowRegistry
jitsureiWorkflowRegistry =
  registerWorkflow orderFulfillmentWorkflowName (\wfId -> orderFulfillmentWorkflow (orderIdFromWf wfId))
    (registerWorkflow shipOrderWorkflowName (\wfId -> shipOrderWorkflow (orderIdFromWf wfId)) emptyWorkflowRegistry)
```

where `orderIdFromWf :: WorkflowId -> OrderId` and the inverse `workflowIdFor :: OrderId ->
WorkflowId` round-trip the order id through the workflow id so the registry can reconstruct
the workflow argument from the id alone (the resume worker only knows the journal's workflow
id). Keep this round-trip total and obvious (e.g. `WorkflowId . orderIdText` and `OrderId .
unWorkflowId`).

**Wiring.** Add `Jitsurei.DurableWorkflow` to the `exposed-modules` stanza of
`jitsurei/jitsurei.cabal` (append it to the list at lines ~35–48; do not reorder existing
entries). Add it to both the export list and the import list of `jitsurei/src/Jitsurei.hs`.
If `keiro`'s workflow modules require a build-dep not already present in the `jitsurei`
library stanza, add it (the library already depends on `keiro`, `aeson`, `effectful`,
`kiroku-store`, `text`, `time`, `uuid` — likely sufficient).

**Acceptance.** `cabal build jitsurei:lib:jitsurei` reports success with no warnings
(`-Wall -Wcompat` are on for the package). `cabal repl jitsurei:lib:jitsurei` can
`:browse Jitsurei.DurableWorkflow` and see the exported names.


### Milestone 2: the `workflow` demo subcommand

**Scope.** Add a `workflow` subcommand to `jitsurei/app/Main.hs` and implement
`runDurableWorkflowDemo`. **At the end of this milestone**, `cabal run
jitsurei:exe:jitsurei-demo -- workflow` runs end-to-end against the ephemeral PostgreSQL and
prints the suspend → wake → resume → complete narrative plus the journal dump and the
simulated-restart section.

**Dispatcher edits** in `jitsurei/app/Main.hs` `main` (lines ~45–58): add `["workflow"] ->
runDurableWorkflowDemo` to the case; add `runDurableWorkflowDemo` to the `["all"]` block; and
extend the usage string to
`"usage: jitsurei-demo [fulfillment|snapshots|paging|escalation|agent-qual|workflow|all]"`.

**The demo driver** `runDurableWorkflowDemo :: IO ()`. Follow the existing demo pattern
(`withJitsureiStore`, `initializeJitsureiTables`, `requireEither`, `readEvents`,
`printDecoded`). The narrative, in order:

1. Open the store and initialize tables. Generate a fresh order id with `freshOrderId
   "workflow"` so repeated runs use distinct journals (idempotence — see Idempotence and
   Recovery). Build `wfId = workflowIdFor orderId`.
2. **First run to suspension.** Call `runWorkflow orderFulfillmentWorkflowName wfId
   (orderFulfillmentWorkflow orderId)` and print the `WorkflowOutcome`. It must print
   `Suspended` — the workflow ran `reserve-inventory`, scheduled the `cooling-off` timer, and
   parked. (If it reaches the awakeable before the sleep, it still parks; the order of
   suspension causes is fixed by the workflow body — sleep first.)
3. **Fire the sleep timer.** Advance a clock past `coolingOffDelay` and run the
   workflow-sleep timer worker (`runWorkflowTimerWorker Nothing now workflowSleepFireAction`
   — reconcile the exact entry point and fire action against EP-39's shipped
   `Keiro.Workflow.Sleep`). This appends the `sleep:cooling-off` completion to the journal.
4. **Resume past the sleep (still suspended on the awakeable).** Run `resumeWorkflowsOnce
   jitsureiWorkflowRegistry` and print the outcome. The workflow now replays
   `reserve-inventory` (from journal) and `cooling-off` (from journal), reaches the
   `payment-webhook` awakeable, finds it unresolved, and parks again → `Suspended`.
5. **Signal the awakeable (simulate the webhook).** Call `signalAwakeable
   (paymentWebhookAwakeableId orderId) (PaymentConfirmation "pay_demo" 4200)` and print the
   returned `Bool` (`True` = a pending awakeable was completed). This records the payment
   payload in the journal.
6. **Resume to completion.** Run `resumeWorkflowsOnce jitsureiWorkflowRegistry` again. The
   workflow replays the first three checkpoints, reads the signalled payment, runs `charge`,
   spawns the `ship-order` child, and waits on it. The child may itself be resumed by the
   same worker pass or a follow-up `resumeWorkflowsOnce`; loop the worker (e.g. up to 5
   passes) until the parent's outcome is `Completed tracking`. Print `Completed <tracking>`.
7. **Dump the journal.** `readEvents store (workflowStreamNameText orderFulfillmentWorkflowName
   wfId)` and print each journal event with `printDecoded workflowJournalCodec` (the journal
   codec is exported by `Keiro.Workflow` per EP-38). Also dump the child journal
   `wf:ship-order-<order-id>`.
8. **Simulated restart.** Print a banner, then *re-open the store* with a second
   `withJitsureiStore` block (or re-run `resumeWorkflowsOnce` after explicitly discarding any
   in-memory state) and run `resumeWorkflowsOnce jitsureiWorkflowRegistry` once more. Because
   the parent journal already carries `WorkflowCompleted`, the resume worker must find
   *nothing to do* for this workflow — print a line such as `restart: resume worker found no
   unfinished work for order-fulfillment-<id>` to prove the workflow resumes (or, here,
   *stays completed*) from the journal, not from scratch. This is the durability proof: a
   fresh process, the same journal, no re-execution of side effects.

Add a small helper `workflowStreamNameText :: WorkflowName -> WorkflowId -> Text` in
`Main.hs` if `workflowStreamName` returns a `StreamName` (unwrap it to the `Text` `readEvents`
expects). Reuse `readEvents`/`printDecoded`/`requireEither` verbatim.

**Acceptance.** The command prints a transcript matching the expected block in Validation and
Acceptance: `Suspended` after the first run, the sleep firing, a second `Suspended` after the
sleep, `signalAwakeable … True`, `Completed <tracking>`, a journal dump showing
`StepRecorded` entries for `reserve-inventory`, `sleep:cooling-off`, `awk:payment-webhook`,
`charge`, the child handle, and a terminal `WorkflowCompleted`, then the simulated-restart
"no unfinished work" line.


### Milestone 3: the guide and the user-reference page

**Scope.** Write `docs/guides/durable-workflows.md` (long-form, prose-first) and
`docs/user/durable-workflows.md` (short, API-oriented), and add each to its index
(`docs/guides/README.md`, `docs/user/README.md`). **At the end of this milestone**, both pages
exist, link correctly, and every code snippet is copy-pasteable from
`jitsurei/src/Jitsurei/DurableWorkflow.hs` and references only shipped functions.

**`docs/guides/durable-workflows.md`** (model on `docs/guides/process-managers-and-timers.md`:
prose paragraphs, fenced `haskell` snippets pulled from the real module with a relative link
to the source file, fenced `bash` for commands). Cover, in this order:

1. *What durable execution is and when to use it.* Define a durable workflow in plain
   language (an imperative function whose named checkpoints are journaled so it can pause and
   resume). Contrast with a process manager: a process manager reacts to *one event at a time*
   and emits commands (stateless between deliveries except for its own event-sourced state); a
   durable workflow is *one long-lived function* that drives a multi-step process with waits.
   Link `docs/guides/choosing-a-primitive.md` and recommend a one-line addition there (see
   below): "A single long-running function with in-line waits (sleep, external callback, child
   work) → a durable `Workflow`."
2. *The four primitives.* `step` (named, journaled, replay-skipping), `sleepNamed`/`sleep`
   (durable delay on `keiro_timers`), `awakeableNamed`/`awakeable` + `signalAwakeable` /
   `cancelAwakeable` (external completion), and child workflows
   (`spawnChild`/`awaitChild`/`cancelChild`). Show the real `orderFulfillmentWorkflow`
   do-block.
3. *Journaling and replay.* Explain the `wf:<name>-<id>` journal stream, that each `step`
   appends a `StepRecorded` event, that replay returns recorded results, and that the
   reserved step-name prefixes (`sleep:`, `awk:`, `child:`) keep the journal uniform. Show the
   journal dump from the demo transcript as a fenced `text` block.
4. *The resume worker.* Explain `resumeWorkflowsOnce` + `WorkflowRegistry`/`WorkflowDef`: it
   discovers journals lacking `WorkflowCompleted` and re-invokes them. Note it does **not**
   use a `wf:` prefix subscription (it scans the `keiro_workflow_steps` index), so there is
   no upstream dependency.
5. *Awakeables in depth.* The idempotent-id contract (the external signaller must target the
   same deterministic id the workflow registered), and repair via `cancelAwakeable`.
6. *Child workflows.* Parent records the child handle as a journal step; `awaitChild` parks
   the parent like an awakeable; the relationship survives a crash.
7. *Snapshots.* `runWorkflowWith`/`WorkflowRunOptions.snapshotPolicy` and the
   `workflowStateCodec` sentinel `"keiro.workflow.stepmap.v1"`; when to enable for long
   journals.
8. *Operational notes.* Run the resume worker on a loop in production; how to repair a stuck
   awakeable; journal snapshot policy. Cross-link `docs/user/operations.md`.
9. *Running it.* The exact `cabal run jitsurei:exe:jitsurei-demo -- workflow` command and a
   pointer to the source module.

Add a one-line routing entry to `docs/guides/choosing-a-primitive.md`'s "By shape, reach
for…" table (after the `ProcessManager` row): a long-running single function with in-line
waits → a durable `Workflow`, linking the new guide.

Add the guide to `docs/guides/README.md`'s bullet list (after the Process Managers And Timers
entry, before Routers): "[Durable Workflows](durable-workflows.md) walks a named-step durable
workflow end to end — steps, a durable sleep, an awakeable, a child workflow, the resume
worker, and the kill-and-restart durability proof."

**`docs/user/durable-workflows.md`** (model on `docs/user/process-managers-and-timers.md`:
shorter, API-oriented, module-and-signature focused). Cover: the `Keiro.Workflow` import
surface; the `Workflow es a` type and `runWorkflow`/`runWorkflowWith`/`WorkflowOutcome`; each
primitive's signature in a fenced `haskell` block; the journal stream naming; the
`keiro_workflow_steps` and `keiro_awakeables` tables; the resume worker entry point and
registry; the snapshot option; and a "see also" pointing at the long-form guide and the
`jitsurei` demo. Reference only the exact signatures repeated in Interfaces and Dependencies
of this plan (reconciled against the shipped modules).

Link the new user page from `docs/user/README.md`'s "Start here" list, inserting after the
"[Process Managers And Timers]" bullet (line ~30): "[Durable Workflows](durable-workflows.md):
named-step workflows, durable sleep, awakeables, child workflows, the resume worker, and
journal snapshots."

**Acceptance.** Both files exist; their internal links resolve (verify with the link-check
command in Concrete Steps); every `haskell` snippet appears verbatim (modulo elision) in
`jitsurei/src/Jitsurei/DurableWorkflow.hs`; no snippet references a function absent from the
shipped `Keiro.Workflow*` surface.


### Milestone 4: flip the roadmap and production-status framing

**Scope.** Edit `docs/user/roadmap.md`, `docs/user/production-status.md`, and
`docs/user/operations.md` so the user-facing docs declare durable execution *Available*. **At
the end of this milestone**, the capability matrix reads `Available now`, Phase 5 reads as
shipped, production-status no longer says durable execution is deferred, and operations has a
durable-workflow note.

**`docs/user/roadmap.md`:**

- Capability matrix (line ~44): change `| Durable execution runtime | Planned v2 | Named-step
  Workflow es a, awakeables, child workflows, continue-as-new. |` to status `Available now`
  with notes reflecting what shipped: `Keiro.Workflow`: named-step `Workflow es a`, durable
  `sleep`, awakeables, child workflows, a resume worker, and journal snapshots
  (`keiro_workflow_steps` + `keiro_awakeables`). Continue-as-new remains deferred — keep an
  honest note that long-history rotation (continue-as-new) is still future work, so the row
  is accurate rather than over-claiming.
- Phase-summary table row for Phase 5 (line ~22): reword the user-visible outcome to
  past/shipped framing, e.g. "Complete: a named-step `Workflow es a` runtime with durable
  sleep, awakeables, child workflows, a resume worker, and journal snapshots ships on top of
  the v1 substrate; continue-as-new remains deferred."
- The "Phase 5: v2 Durable Execution" section (lines ~316–351): change the framing from
  "Planned v2 shape" to "shipped" — relabel the feature table header (e.g. "Shipped v2
  shape") and update the prose so "User impact: teams *can* write…" reads in the present
  shipped tense. Keep the named-step-not-positional-history design note (line ~345–347)
  verbatim — it is the central design statement and is now *the* selling point. In the
  "Durable Execution Boundaries" list (lines ~358–366), reframe the items that EP-38…EP-44
  delivered (step-result codecs, unfinished-workflow discovery / resume workers, stuck
  awakeable repair, observability for replay-versus-live) as *delivered*, and keep
  continue-as-new / versioning-patch-API as the genuinely-still-deferred items.

**`docs/user/production-status.md`:**

- "What Is Implemented" list (lines ~9–34): add a bullet for the durable-workflow runtime,
  e.g. "named-step durable workflows (`Keiro.Workflow`): `step`/`sleep`/`awakeable`/child
  workflows, a journal per workflow (`wf:<name>-<id>`), a crash-recovery resume worker, and
  journal snapshots."
- "Not A Good Fit Yet" list (lines ~51–59): replace "you need Temporal-style deterministic
  durable execution" — the runtime now exists. Rephrase to clarify the *boundary*: e.g. "you
  need positional-history durable execution (Temporal-style step identity derived from call
  order) — Keiro's runtime uses **named** steps that are stable across source reordering, by
  design", and/or "you need continue-as-new journal rotation for unbounded-length workflow
  histories (still deferred)." The point is to keep one honest not-yet line about the *named
  vs positional* distinction and the genuinely-deferred continue-as-new, while removing the
  blanket "no durable execution" claim.
- "Durable execution is deferred" subsection (lines ~71–76): retitle to "Durable execution is
  named-step" and rewrite: the v2 named-step durable-execution runtime *is available*
  (`Keiro.Workflow`); the deferred pieces are continue-as-new journal rotation and the
  versioning/patch API. Keep the contrast with v1 process managers/timers as the
  saga/time-based coordination layer.

**`docs/user/operations.md`:** add a new `## Durable Workflows` section (after `## Timers` or
`## Snapshots`) covering three operational tasks reconciled with what shipped:

- *Resume worker* (EP-42): run `resumeWorkflowsOnce <registry>` on a polling loop — the same
  claim-process-commit-poll shape as the timer/outbox workers — so suspended workflows resume
  after their waits resolve and after process restarts.
- *Awakeable repair* (EP-40): a workflow parked on an awakeable that will never be signalled
  is repaired with `cancelAwakeable awkId`, which flips the `keiro_awakeables` row to
  `Cancelled` and lets the next resume observe the cancellation. Note the `keiro_awakeables`
  table (`awakeable_id`, `owner_workflow_id`, `status`, `payload`).
- *Journal snapshots* (EP-41): enable `runWorkflowWith` with a `snapshotPolicy` for
  long-journal workflows; the workflow snapshot uses `workflowStateCodec` with the fixed shape
  hash `keiro.workflow.stepmap.v1` (distinct from the `regFileShapeHash` used by aggregate
  snapshots — this is intentional, because step names are dynamic).

If EP-39/EP-40/EP-41 already added a one-paragraph stub to `operations.md` for their surface,
*reconcile* it into this single section rather than duplicating (the MasterPlan assigns EP-45
the consolidation).

**Acceptance.** `grep -n "Planned v2" docs/user/roadmap.md` returns no line for the durable
row; `grep -n "Available now" docs/user/roadmap.md` includes the durable row; `grep -n
"Temporal-style deterministic durable execution" docs/user/production-status.md` returns
nothing; `docs/user/operations.md` contains a `## Durable Workflows` heading.


### Milestone 5: full-repo green and acceptance capture

**Scope.** Build the whole workspace, run the keiro and jitsurei test suites, run the demo,
and record the real transcript into this plan. **At the end of this milestone**, every command
in Validation and Acceptance has been run and its output reconciled with this plan.

This milestone adds no new source; it is the verification gate. Run `cabal build all`, `cabal
test keiro`, `cabal test jitsurei-test`, and `cabal run jitsurei:exe:jitsurei-demo --
workflow`, and paste the demo transcript into Validation and Acceptance (updating the expected
block if reality differs, and recording the difference in Surprises & Discoveries).


## Concrete Steps

Run all commands from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`. The
`jitsurei` demos and the `keiro` DB tests need a PostgreSQL (18+) reachable via
`PG_CONNECTION_STRING` (default `host=db dbname=jitsurei`, see `getConnectionString` in
`jitsurei/app/Main.hs`). The repo's test harness uses an ephemeral PostgreSQL; the demo
expects a running database.

**Step 0 — reconcile the shipped surface (do this first):**

```bash
ls keiro/src/Keiro/Workflow
grep -rn "resumeWorkflowsOnce\|WorkflowRegistry\|WorkflowDef\|registerWorkflow\|spawnChild\|awaitChild\|cancelChild\|signalAwakeable\|cancelAwakeable\|awakeableNamed\|sleepNamed\|runWorkflowTimerWorker\|workflowStreamName\|workflowJournalCodec\|runWorkflowWith\|WorkflowRunOptions" keiro/src/Keiro/Workflow
```

Expected: each name appears in some `Keiro.Workflow*` module. Adjust the imports in
`Jitsurei.DurableWorkflow` and `Main.hs` to match the real module that exports each.

**Step 1 — create the module, wire cabal + umbrella, build the library:**

```bash
$EDITOR jitsurei/src/Jitsurei/DurableWorkflow.hs   # author per Milestone 1
$EDITOR jitsurei/jitsurei.cabal                    # add Jitsurei.DurableWorkflow to exposed-modules
$EDITOR jitsurei/src/Jitsurei.hs                   # add to export + import lists
cabal build jitsurei:lib:jitsurei
```

Expected tail:

```text
[N of M] Compiling Jitsurei.DurableWorkflow ( ... )
Linking ... (or "Up to date" on a repeat)
```

with no warnings (the package builds with `-Wall -Werror`-adjacent flags `-Wall -Wcompat`;
treat any warning as a failure to fix).

**Step 2 — add the subcommand and run the demo:**

```bash
$EDITOR jitsurei/app/Main.hs                       # dispatcher + runDurableWorkflowDemo + usage
cabal build jitsurei:exe:jitsurei-demo
cabal run jitsurei:exe:jitsurei-demo -- workflow
```

Compare the output against the expected transcript in Validation and Acceptance. To run every
demo (verifying the `all` path includes the new one):

```bash
cabal run jitsurei:exe:jitsurei-demo -- all
```

**Step 3 — write the docs and check links:**

```bash
$EDITOR docs/guides/durable-workflows.md
$EDITOR docs/guides/README.md
$EDITOR docs/guides/choosing-a-primitive.md
$EDITOR docs/user/durable-workflows.md
$EDITOR docs/user/README.md
# verify the new files are referenced from their indexes:
grep -n "durable-workflows.md" docs/guides/README.md docs/user/README.md docs/guides/choosing-a-primitive.md
```

Expected: each index file shows a line linking `durable-workflows.md`.

**Step 4 — flip the roadmap / production-status / operations:**

```bash
$EDITOR docs/user/roadmap.md
$EDITOR docs/user/production-status.md
$EDITOR docs/user/operations.md
grep -n "Durable execution runtime" docs/user/roadmap.md
grep -n "Temporal-style deterministic durable execution" docs/user/production-status.md
grep -n "## Durable Workflows" docs/user/operations.md
```

Expected: the roadmap durable row no longer says `Planned v2`; the production-status grep for
the old Temporal line returns nothing; operations shows the new heading.

**Step 5 — full-repo green:**

```bash
cabal build all
cabal test keiro
cabal test jitsurei-test
cabal run jitsurei:exe:jitsurei-demo -- workflow
```

Expected: all builds and test suites pass; the demo prints the acceptance transcript.


## Validation and Acceptance

Acceptance is **observable behavior**, not the presence of code. The four checks below must
all pass.

**Check 1 — the demo proves durability end-to-end.** Running

```bash
cabal run jitsurei:exe:jitsurei-demo -- workflow
```

prints a transcript of this shape. This is the contract the implementation must satisfy;
generated ids, timestamps, and exact event counts will differ and are reconciled into this
block from the real run during Milestone 5. The *structure* — suspend, fire sleep, suspend
again, signal, complete, journal dump, restart proof — is the acceptance:

```text
[jitsurei] connecting to host=/…/db dbname=jitsurei user=…
[jitsurei:workflow] running durable order-fulfillment workflow for workflow-20260603…
[jitsurei:workflow] first run: invoking the workflow
  step reserve-inventory ran (reservation RES-workflow-20260603…)
[jitsurei:workflow] first run outcome: Suspended (armed the cooling-off sleep)
[jitsurei:workflow] firing the cooling-off sleep timer
  timer worker fired sleep:cooling-off -> journal
[jitsurei:workflow] resume pass 1: ResumeSummary {discovered = 1, resumed = 1, completed = 0, stillSuspended = 1, unknownName = 0}
  (replayed reserve-inventory + sleep:cooling-off, parked on the payment-webhook awakeable)
[jitsurei:workflow] signalling the payment-webhook awakeable (simulated webhook)
  signalAwakeable payment-webhook -> True
  step charge ran (charge CHG-workflow-20260603… for pay_demo)
[jitsurei:workflow] resume pass 2: ResumeSummary {discovered = 1, resumed = 1, completed = 0, stillSuspended = 1, unknownName = 0}
  child step create-shipment ran (tracking TRK-workflow-20260603…-ship)
[jitsurei:workflow] resume pass 3: ResumeSummary {discovered = 2, resumed = 2, completed = 1, stillSuspended = 1, unknownName = 0}
[jitsurei:workflow] resume pass 4: ResumeSummary {discovered = 1, resumed = 1, completed = 1, stillSuspended = 0, unknownName = 0}
[jitsurei:workflow] final outcome: Completed "TRK-workflow-20260603…-ship"
[jitsurei:workflow] order-fulfillment journal (wf:order-fulfillment-workflow-20260603…)
  StreamVersion 1 GlobalPosition 0 StepRecorded {stepName = "reserve-inventory", result = String "RES-workflow-20260603…", recordedAt = …}
  StreamVersion 2 GlobalPosition 0 StepRecorded {stepName = "sleep:cooling-off", result = Null, recordedAt = …}
  StreamVersion 3 GlobalPosition 0 StepRecorded {stepName = "awk:<uuid>", result = Object (fromList [("amountCents",Number 4200.0),("paymentRef",String "pay_demo")]), recordedAt = …}
  StreamVersion 4 GlobalPosition 0 StepRecorded {stepName = "charge", result = String "CHG-workflow-20260603…", recordedAt = …}
  StreamVersion 5 GlobalPosition 0 StepRecorded {stepName = "child:workflow-20260603…-ship", result = Array [], recordedAt = …}
  StreamVersion 6 GlobalPosition 0 StepRecorded {stepName = "child:workflow-20260603…-ship:result", result = String "TRK-workflow-20260603…-ship", recordedAt = …}
  StreamVersion 7 GlobalPosition 0 WorkflowCompleted {recordedAt = …}
[jitsurei:workflow] ship-order child journal (wf:ship-order-workflow-20260603…-ship)
  StreamVersion 1 GlobalPosition 0 StepRecorded {stepName = "create-shipment", result = String "TRK-workflow-20260603…-ship", recordedAt = …}
  StreamVersion 2 GlobalPosition 0 WorkflowCompleted {recordedAt = …}
[jitsurei:workflow] --- simulated restart: re-opening the store ---
[jitsurei] connecting to host=/…/db dbname=jitsurei user=…
  restart: resume worker discovery found no unfinished work for order-fulfillment-workflow-20260603…
[jitsurei:workflow] durability proven: the completed workflow was NOT re-executed from scratch
```

The load-bearing assertions a reader verifies by eye: the workflow returns `Suspended` (the
first run and the `stillSuspended = 1` resume passes) before completing; each step's `… ran`
line prints only the first time that step runs and never on a later pass (proving no double
side effects — the replayed steps print nothing); the journal contains exactly one
`StepRecorded` per checkpoint (note the child contributes *two*: the `child:<id>` spawn record
and the `child:<id>:result` completion the parent awaits) plus one terminal `WorkflowCompleted`
at version 7; the resume worker itself drives the parent to completion in pass 4
(`completed = 1, stillSuspended = 0`); and the simulated-restart discovery finds *no unfinished
work*, proving the completed state lives in the journal, not in the process.

**Transcript reconciliation (recorded per the Decision Log):** the as-authored sketch differed
from the real run in three honest ways, now folded into the block above. (1) The awakeable
journals under `awk:<uuid>` (the deterministic awakeable id), not `awk:payment-webhook` — the
reserved `awk:` prefix is followed by the awakeable's UUID, per `Keiro.Workflow.Awakeable`. (2)
A child contributes two journal entries (`child:<id>` spawn + `child:<id>:result`), not one. (3)
Resumes do not print "replayed … (from journal)" lines, because a replayed step does not run —
the absence of a step's `… ran` line on a later pass *is* the replay evidence. The parent and
child use *distinct* workflow ids (the child id carries a `-ship` suffix); see Surprises.

**Check 2 — the guide and user page are copy-pasteable and reference only shipped functions.**
Every `haskell` fence in `docs/guides/durable-workflows.md` and `docs/user/durable-workflows.md`
appears (modulo elision with `…`) in `jitsurei/src/Jitsurei/DurableWorkflow.hs` or names a
function that `grep` finds in `keiro/src/Keiro/Workflow`. Verify:

```bash
grep -rn "resumeWorkflowsOnce\|spawnChild\|awaitChild\|signalAwakeable\|cancelAwakeable\|sleepNamed\|awakeableNamed\|runWorkflowWith\|workflowStateCodec" keiro/src/Keiro/Workflow
```

returns a hit for every workflow function named in either doc page.

**Check 3 — the roadmap reads Available.** The capability-matrix row for the durable runtime
shows `Available now`:

```bash
grep -n "Durable execution runtime" docs/user/roadmap.md
```

Expected: a line whose status column is `Available now`, not `Planned v2`. And:

```bash
grep -n "Temporal-style deterministic durable execution" docs/user/production-status.md
```

Expected: no output (the old deferral line is gone, replaced by the named-vs-positional
boundary note).

**Check 4 — the whole repository stays green.**

```bash
cabal build all
cabal test keiro
cabal test jitsurei-test
```

Expected: `cabal build all` links every package including `jitsurei`; `cabal test keiro` and
`cabal test jitsurei-test` both report all specs passing. A build or test failure is a
non-acceptance and must be fixed before the milestone is checked off.


## Idempotence and Recovery

Every step here is safe to repeat.

**The demo is re-runnable.** `runDurableWorkflowDemo` derives a fresh order id from the wall
clock via `freshOrderId "workflow"` (the existing `Main.hs` helper appends
`%Y%m%d%H%M%S%q`), so each invocation uses a *distinct* journal stream `wf:order-fulfillment-<id>`
and never collides with a prior run's journal. `cabal run … workflow` can be run any number of
times; each produces an independent, complete narrative. `initializeJitsureiTables` is itself
idempotent (it is `CREATE … IF NOT EXISTS`-shaped, as the other demos rely on), so re-running
against an already-migrated database is a no-op.

**The resume worker is idempotent by design.** `resumeWorkflowsOnce` only re-invokes
workflows whose journal lacks a terminal `WorkflowCompleted` event; running it repeatedly on a
completed workflow finds nothing to do (this is exactly what the simulated-restart pass
proves). Re-invoking an in-flight workflow short-circuits all already-journaled steps, so no
side effect runs twice. The awakeable arming and child spawning use *deterministic* ids
(`deterministicAwakeableId`, the child id derived from the order id), so re-arming on every
resume collapses to a no-op INSERT — the central idempotent-arming contract from the
MasterPlan's Integration Points.

**Documentation edits are additive and reversible.** Milestones 3–4 add two new files and edit
existing prose. If a roadmap/production-status edit is wrong, revert that one file with `git
checkout -- docs/user/<file>.md` and redo it; no edit is destructive or cross-coupled.

**If the demo hangs or never completes:** the most likely cause is that a resume pass did not
drive the child to completion before the parent's `awaitChild`. The driver loops
`resumeWorkflowsOnce` up to a bounded number of passes (e.g. 5) and prints each pass; if the
parent is still `Suspended` after the bound, the transcript shows it and the implementer
inspects the child journal `wf:ship-order-<id>` to see whether `create-shipment` was recorded.
This is a bounded loop, not an infinite wait, so the demo always terminates.

**If `cabal build` reports "Up to date" after only editing a `.md` file:** that is expected —
documentation files are not compiled. Only the `.hs` and `.cabal` edits trigger a rebuild.
(Note: unlike a new SQL migration, a new `.hs` source file *does* trigger recompilation, so the
EP-34 `embedDir` recompilation gotcha does not apply to this plan.)


## Interfaces and Dependencies

This plan consumes the `Keiro.Workflow*` surface that EP-38…EP-44 ship; it adds **no** new
library code to `keiro` and **no** migration. It adds one module to the `jitsurei` package, one
CLI subcommand, two documentation pages, and edits to existing docs. The exact identifiers must
be reconciled against the as-shipped modules (see "Before starting, reconcile the surface" in
Plan of Work); the signatures below are the as-designed contract from the sibling plans'
Interfaces sections and the MasterPlan's Integration Points.

**From EP-38 (`Keiro.Workflow`, `Keiro.Workflow.Types`, `Keiro.Workflow.Schema`):**

```haskell
data Workflow :: Effect
newtype WorkflowName = WorkflowName Text
newtype WorkflowId   = WorkflowId Text
newtype StepName     = StepName Text
data WorkflowOutcome a = Completed a | Suspended
data WorkflowJournalEvent
  = StepRecorded { stepName :: Text, result :: Value, recordedAt :: UTCTime }
  | WorkflowCompleted { recordedAt :: UTCTime }
workflowStreamName   :: WorkflowName -> WorkflowId -> StreamName
workflowJournalCodec :: Codec WorkflowJournalEvent
step        :: (Workflow :> es, ToJSON a, FromJSON a) => StepName -> Eff es a -> Eff es a
runWorkflow :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)
```

**From EP-39 (`Keiro.Workflow.Sleep`):**

```haskell
sleepNamed             :: (Workflow :> es, Store :> es, IOE :> es) => StepName -> NominalDiffTime -> Eff es ()
runWorkflowTimerWorker :: (IOE :> es, Store :> es) => Maybe KeiroMetrics -> UTCTime -> (TimerRow -> Eff es (Maybe EventId)) -> Eff es (Maybe TimerRow)
workflowSleepFireAction :: (Store :> es, IOE :> es) => TimerRow -> Eff es (Maybe EventId)
```

**From EP-40 (`Keiro.Workflow.Awakeable`):**

```haskell
newtype AwakeableId = AwakeableId UUID
deterministicAwakeableId :: WorkflowName -> WorkflowId -> Text -> AwakeableId
awakeableNamed  :: (Workflow :> es, Store :> es, FromJSON a) => StepName -> Eff es (AwakeableId, Eff es a)
signalAwakeable :: (Store :> es, ToJSON r) => AwakeableId -> r -> Eff es Bool
cancelAwakeable :: (Store :> es) => AwakeableId -> Eff es Bool
```

**From EP-41 (`Keiro.Workflow.Snapshot`, plus the `runWorkflowWith` addition to
`Keiro.Workflow`):**

```haskell
data WorkflowRunOptions = WorkflowRunOptions { snapshotPolicy :: SnapshotPolicy WorkflowState, pageSize :: Int32 }
defaultWorkflowRunOptions :: WorkflowRunOptions
runWorkflowWith :: (IOE :> es, Store :> es) => WorkflowRunOptions -> WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)
workflowStateCodec :: StateCodec WorkflowState     -- shape hash "keiro.workflow.stepmap.v1"
```

**From EP-42 (`Keiro.Workflow.Resume`) — names per the MasterPlan's Integration Points; verify
exact spelling against the shipped module:**

```haskell
data WorkflowRegistry
data WorkflowDef
resumeWorkflowsOnce :: (IOE :> es, Store :> es) => WorkflowRegistry -> Eff es ...   -- discover + re-invoke unfinished workflows
```

**From EP-43 (`Keiro.Workflow.Child`) — names per the MasterPlan's Integration Points; verify
exact spelling:**

```haskell
spawnChild  :: (Workflow :> es, Store :> es, IOE :> es) => WorkflowName -> WorkflowId -> Eff es a -> Eff es ChildHandle
awaitChild  :: (Workflow :> es, FromJSON a) => ChildHandle -> Eff es a
cancelChild :: (Workflow :> es, Store :> es) => ChildHandle -> Eff es Bool
```

**From EP-44 (`Keiro.Telemetry`):** the `keiro.workflow.*` metric names
(`keiro.workflow.steps.executed`, `keiro.workflow.steps.replayed`, `keiro.workflow.resumed`,
`keiro.workflow.journal.length`, `keiro.workflow.awakeables.pending`, `keiro.workflow.active`)
are referenced only by the docs' operational notes; the demo does not need a metrics exporter.

**New artifacts this plan creates:**

- `jitsurei/src/Jitsurei/DurableWorkflow.hs` — exports `orderFulfillmentWorkflowName`,
  `shipOrderWorkflowName`, `orderFulfillmentWorkflow`, `shipOrderWorkflow`,
  `paymentWebhookAwakeableId`, `jitsureiWorkflowRegistry`, `coolingOffDelay`, and the id
  round-trip helpers `workflowIdFor`/`orderIdFromWf`.
- `jitsurei/app/Main.hs` — a `workflow` subcommand and `runDurableWorkflowDemo :: IO ()`.
- `docs/guides/durable-workflows.md`, `docs/user/durable-workflows.md` — new docs.
- Edits to `jitsurei/jitsurei.cabal`, `jitsurei/src/Jitsurei.hs`,
  `docs/guides/README.md`, `docs/guides/choosing-a-primitive.md`, `docs/user/README.md`,
  `docs/user/roadmap.md`, `docs/user/production-status.md`, `docs/user/operations.md`.

**Dependencies on the environment:** PostgreSQL 18+ reachable via `PG_CONNECTION_STRING` for
the demo and the `keiro`/`jitsurei` DB tests; the GHC/Cabal toolchain already configured for
the workspace (GHC 9.12, per `jitsurei.cabal` `tested-with`).

**Git trailers.** Every commit made while implementing this plan must carry all three trailers,
appended to the commit message body after a blank line:

```text
MasterPlan: docs/masterplans/5-v2-durable-execution-named-step-workflow-runtime.md
ExecPlan: docs/plans/45-durable-workflow-worked-example-and-guide.md
Intention: intention_01kt6y4cb6eqz9mq48kf2xw8n1
```
