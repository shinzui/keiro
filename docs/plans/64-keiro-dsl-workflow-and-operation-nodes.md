---
id: 64
slug: keiro-dsl-workflow-and-operation-nodes
title: "keiro-dsl workflow and operation nodes"
kind: exec-plan
created_at: 2026-06-10T01:05:27Z
intention: "intention_01ktqdn85xe2btqzr2zghxgrpr"
master_plan: "docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md"
---

# keiro-dsl workflow and operation nodes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A **keiro service** is a bounded context built on event sourcing. Two of its node types
coordinate *long-running, cross-time* behavior rather than a single command turn. A
**durable workflow** is an ordinary program — reserve inventory, wait out a cooling-off
period, wait for an external approval, charge a card, ship via a sub-workflow — whose
side effects are *journaled* at named checkpoints so the program can crash, redeploy, or
sit idle for hours and then resume exactly where it left off without re-running work that
already happened. An **operation** is the thin entry point that *drives* a service from
the outside: run a command durably, query a read model with an explicit freshness
guarantee, signal a waiting workflow, or kick off a workflow run.

These are precisely where the most dangerous, easy-to-get-wrong decisions live. A workflow
body **re-executes from the top on every resume**, so any line that samples the wall clock
(`getCurrentTime`), draws randomness, or reads mutable state silently corrupts replay — the
resumed run computes a *different* value than the journal recorded. A step's result is
journaled as JSON, so a careless type change makes every in-flight workflow fail to decode
(`WorkflowStepDecodeError`). An awakeable's id is a *deterministic* UUID that a *separate*
operation must reproduce byte-for-byte to wake the workflow; get the label wrong on either
side and the workflow waits forever. A child workflow that shares its parent's id lets the
child's terminal marker mask the parent's incompleteness. A read-model query that asks for
`Eventual` consistency where the caller needs read-your-writes returns stale data.

`keiro-dsl` is a toolchain over a **typed specification** of a keiro service — a plain-text
file with extension `.kdsl` written in a terse, readable notation, which is the permanent,
machine-checkable source of truth for the service. The foundation (parser, validator,
scaffolder, harness, CLI) and the `aggregate` node are built by **EP-1**
(`docs/plans/59-keiro-dsl-foundations-grammar-parser-validator-scaffold-and-harness-engine-aggregate-vertical.md`),
which this plan hard-depends on. This plan, **EP-6** of the MasterPlan
`docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md`, adds two node types on
top of that foundation: `workflow` (a durable workflow definition: ordered steps, awaitable
external resolution points, durable sleeps, and child workflows) and `operation` (the four
service entry shapes: command, query, signal, workflow-run).

After this plan, a developer (or a coding agent planning a feature) can write a `workflow`
block and one or more `operation` blocks in a `.kdsl` file, then:

1. Run `keiro-dsl check service.kdsl` and have the tool **reject the spec** — with a
   precise, line-numbered diagnostic, *before any Haskell is written* — if a workflow's body
   samples the wall clock outside a journaled step, if a `sleep` deadline comes from a fresh
   clock read instead of injected data, if two steps share a journal name, if an `await`
   label has no matching `signal` operation (or is not flagged external-only), if a spawned
   child resolves to no registered workflow or could share the parent's id, or if a query
   operation asks for `Eventual`/`PositionWait` on a `Strong` read model without an explicit
   override.
2. Run `keiro-dsl scaffold service.kdsl --out <dir>` and get the **symbol-free
   deterministic layer** — the workflow runner wiring, the stable `WorkflowName`, the
   `WorkflowId` derivation, the *structural* skeleton of the body (the ordered
   `step`/`await`/`sleep`/`child` calls with their journal names and result types), the
   awakeable-id and child-id helper functions, and the operation wiring
   (`runCommand`/projections, the `ReadModel` record, `signalAwakeable`, `runWorkflowWith`)
   — emitted into `-- @generated` modules, plus precisely-typed **holes** (created only if
   absent) for the behavior-bearing step *bodies*. A spec-derived **harness** then pins the
   filled behavior.
3. Fill the holes (by hand or with a coding agent) against the generated signatures, and run
   the harness to confirm the behavior matches the spec.

The user-visible proof at the end of this plan: take the real, hand-written
`HospitalCapacity.ReservationWorkflow` and `IncidentCommand.EvacuationWorkflow` captured
from the external corpus, plus the real `Reservation/CommandProcessor.hs`,
`Reservation/Projection.hs`, and the `Store.hs` operation wrappers, check them, scaffold
them, hand-fill the step-body holes to match the captured reference, and show (a) the
`-- @generated` modules compile, (b) the tested **firewall invariant** holds — *no
`-- @generated` line ever contains a keiki symbolic operator* — and (c) the emitted harness
goes **green** (a replay-determinism test, an await↔signal id-match test, and golden
step-result codec round-trips), while a mutation (e.g. renaming a `WorkflowName`, changing
a step's result type, or changing one side of an await↔signal label) turns a **specific**
harness test **red**.

The single most important scope boundary, repeated because everything depends on it:
**keiro-dsl does not emit the behavior-bearing step bodies, and it never emits a keiki
symbolic operator.** A `workflow`/`operation` spec is a *typed spec*; the scaffolder emits
the symbol-free deterministic layer plus the *structure* of the body (the ordered
checkpoint calls with their names and types) and leaves each step's actual computation as a
typed, harness-pinned hole. Inter-step data flow and conditional/branching control flow
inside a body are by design agent-written holes, not something the spec expresses (see
*Coverage gaps*). A tested firewall invariant guarantees the generated layer never contains
a keiki symbolic operator.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — Grammar + parser for `workflow`/`operation`: **DONE 2026-06-10** (NWorkflow + NOperation parse/pretty/round-trip)


- [ ] Add a `Workflow !WorkflowNode` and an `Operation !OperationNode` constructor (and their field records) to `Keiro.Dsl.Grammar`, including the ordered `BodyItem` sum (`StepItem`/`AwaitItem`/`SleepItem`/`ChildItem`), the `OperationShape` sum (`CommandOp`/`QueryOp`/`SignalOp`/`RunOp`), and the `Consistency` type.
- [ ] Extend `Keiro.Dsl.Parser` with `pWorkflow` and `pOperation`, wired into the top-level node parser; the workflow `id from <field>` clause, the body lines (`step`/`await`/`sleep`/`child`), and the four operation forms all parse.
- [ ] Extend `Keiro.Dsl.PrettyPrint` so a parsed `workflow`/`operation` round-trips (`parse` then pretty-print is idempotent).
- [ ] `keiro-dsl parse` on a `workflow`-bearing spec prints the parsed model back out.

Milestone 2 — Validator rules: **PARTIAL 2026-06-10** (headline await<->signal + run resolution done; remaining rules deferred)


- [ ] Implement the rules in `Keiro.Dsl.Validate`: no wall-clock/randomness outside a journaled step; sleep deadline from injected data only; step + await labels unique per workflow; every `await` has a matching `signal` operation (or is flagged external-only) deriving the same `(name,id,label)`; `child` resolves to a declared+registered workflow with a provably-distinct id; step/await result types require JSON codecs (a type change is breaking); `WorkflowName` and read-model `shapeHash`/`version` are stable (warn on rename); command `stream … from <field>` and `via`/`project` resolve; reject `Eventual`/`PositionWait` on a `Strong` read model without an explicit override.
- [ ] `keiro-dsl check` rejects each violation with a line-numbered diagnostic; a complete spec passes clean.

Milestone 3 — Scaffold emitters:

- [ ] Emit the `-- @generated` workflow wiring module: `WorkflowName`, the `WorkflowId` derivation, the awakeable-id + child-id helpers, the resume-registry entry, and the *structural* body skeleton (ordered `step`/`awaitStep`/`sleepNamed`/`spawnChild`+`awaitChild` calls with journal names + result types), with no keiki symbolic operator and no step-body logic.
- [ ] Emit the `-- @generated` operation wiring: `runCommand`/inline-projection plumbing, the `ReadModel` record, `signalAwakeable`, and `runWorkflowWith`.
- [ ] Emit the create-if-absent hole module (signatures for each step body and each id/field derivation); firewall invariant test passes.

Milestone 4 — Harness emission:

- [ ] Emit a harness test module that pins: replay determinism (a body re-run from a journal produces identical results and runs no replayed side effect twice); the await↔signal id match (`deterministicAwakeableId` of the workflow equals the signal operation's derived id); and golden step-result codec round-trips (each step/await result type encodes-then-decodes identically).

Milestone 5 — Conformance vs `ReservationWorkflow` + `EvacuationWorkflow`:

- [ ] Capture `ReservationWorkflow.hs`, `EvacuationWorkflow.hs`, `Reservation/CommandProcessor.hs`, `Reservation/Projection.hs`, and the relevant `Store.hs` operation wrappers as read-only fixtures under `keiro-dsl/test/fixtures/`.
- [ ] Author `hospital-reservation.kdsl` and `incident-evacuation.kdsl`; `check` passes; `scaffold` produces modules that compile once step bodies are filled to match the captured reference; harness green.
- [ ] Mutation test: changing one side of the await↔signal label (or a step result type) turns a specific harness test red.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: A `workflow` body is modeled as an **ordered list of typed checkpoint items**
  (`step <name> -> <Type>`, `await <label> -> <Type>`, `sleep <name> after <injected-expr>`,
  `child <name> id <expr> -> <Type>`) and **nothing else**; the step's *computation* is an
  opaque, agent-written hole. Inter-step data flow and conditional/branching control flow are
  deliberately **not** expressible.
  Rationale: the corpus workflows are exactly this shape — an ordered sequence of named
  `step`/`awakeableNamed` calls (`ReservationWorkflow.hs:82-87`,
  `EvacuationWorkflow.hs:81-87`), with the bodies being pure mappings over the input and
  prior results. The runtime replay model matches a checkpoint on its **label, not its
  source position** (`Keiro.Workflow.Types`, `StepName` Haddock at `Types.hs:78-83`), so the
  *ordered set of named checkpoints with their result types* is the faithful, replay-stable
  surface; the body computation is the brittle part a coding agent writes well from a spec +
  examples, mirroring the MasterPlan's load-bearing scope decision. Date: 2026-06-10
- Decision: Use only the **named** suspension primitives in the notation — `step (StepName
  …)`, `awakeableNamed (StepName …)`, `sleepNamed (StepName …)`, `spawnChild (WorkflowName …)
  (WorkflowId …)` — and forbid the ordinal forms (`sleep`, `awakeable`).
  Rationale: the ordinal forms derive their journal name from a per-run counter
  (`freshOrdinal`), so inserting or reordering a checkpoint between deploys shifts every
  later ordinal and **corrupts an in-flight workflow** (`Sleep.hs:230-238` and its module
  header; `Awakeable.hs:179-191`). The named forms are unconditionally stable. The corpus
  uses only named forms. The DSL forbids the fragile variant. Date: 2026-06-10
- Decision: TIME IS INJECTED, NOT SAMPLED. A `sleep`'s delay is a `NominalDiffTime` **datum**
  carried by the workflow input (or a spec constant), and any *absolute* deadline must be
  computed from an injected timestamp field, never a fresh `getCurrentTime` inside the body's
  control flow. The validator rejects clock/random samples outside a journaled `step` (and
  flags them even inside one).
  Rationale: the body re-runs on every resume; a wall-clock sample in control flow yields a
  different value each run and breaks replay. `sleepNamed` already arms its timer with
  `addUTCTime delta now` *inside* the idempotent arming action where `now` is harmless
  (`Sleep.hs:214-228`), and the corpus's `coolingOffDelay = 2` is a constant
  (`DurableWorkflow.hs:80`). The delta is the injected datum; the absolute fire time is the
  runtime's business. Date: 2026-06-10
- Decision: The await↔signal coupling is a **first-class, cross-node** spec relationship: a
  `workflow` declares an `await <label>` *and* the spec must contain a `signal <label> of
  <thisWorkflow>` operation whose `key from <field>` derives the **same** `(WorkflowName,
  WorkflowId, label)` triple — unless the author explicitly marks the await `external-only`
  (signalled by a system outside this service).
  Rationale: the awakeable id is a deterministic v5 UUID over
  `("keiro":"awakeable":name:id:label)` (`Awakeable.hs:131-137`); the workflow allocates it
  with `awakeableNamed` and a *separate* operation must reproduce it with
  `deterministicAwakeableId` to signal it. The corpus does exactly this:
  `reservationConfirmationAwakeableId reservationId = deterministicAwakeableId
  reservationWorkflowName (reservationWorkflowId reservationId) "reservation-confirmation"`
  (`ReservationWorkflow.hs:74-76`), signalled by `signalAwakeable
  (reservationConfirmationAwakeableId reservationId)` (`Store.hs:302-313`). A label mismatch
  is a workflow that hangs forever; the validator makes both sides agree. Date: 2026-06-10
- Decision: A spawned `child` must resolve to a workflow that is **declared in the spec and
  registered in the resume registry**, and its `WorkflowId` must be **provably distinct** from
  the parent's.
  Rationale: `spawnChild` does not run the child inline — the resume worker drives it from a
  `WorkflowRegistry` keyed by `WorkflowName` (`Child.hs:151-183` and module header), so
  spawning an unregistered name hangs at runtime. And the `keiro_workflow_steps` index is
  keyed by `(workflow_id, step_name)` with discovery grouping by `workflow_id` alone, so a
  child sharing the parent's id lets the child's terminal marker mask the parent's
  incompleteness — the corpus suffixes the id (`shipChildId orderId = WorkflowId (orderIdText
  orderId <> "-ship")`, `DurableWorkflow.hs:95-103`). The validator enforces both.
  Date: 2026-06-10
- Decision: Read-model consistency defaults to the model's declared `defaultConsistency`, and
  a query operation may **only** override it explicitly; in particular asking for `Eventual`
  or `PositionWait` against a model whose `defaultConsistency` is `Strong` requires an
  explicit `override` keyword, and a `PositionWait` requires a target `GlobalPosition`
  source.
  Rationale: `runQuery` honours `defaultConsistency` (`ReadModel.hs:128-135`); the corpus
  read model is `Strong` (`Projection.hs:42-53`). Silently weakening a Strong model to
  Eventual is a read-your-writes bug; `PositionWait` with `target = Nothing` skips waiting
  entirely (`ReadModel.hs:101-106,235-238`), so a forgotten target is a silent no-wait. The
  validator forces both to be deliberate. Date: 2026-06-10
- Decision: The following are recorded as **known limitations / grammar TODOs**, not
  implemented here: inter-step data flow and conditional/branching control flow inside a body
  (the biggest gap — a workflow whose checkpoint *sequence* depends on a prior result is not
  expressible); `continueAsNew`/`patch` (rolling workflows + in-flight migrations);
  `cancelAwakeable`/`cancelChild` compensation paths; the ordinal `sleep`/`awakeable` forms;
  cross-operation `PositionWait` target plumbing (a query that waits on the position a prior
  command returned); bespoke `afterAppend` transactions beyond a single named inline
  projection; and deterministic command-id derivation for idempotent commands.
  Rationale: each is in-body computation or cross-operation data flow, which under the
  scaffold+verify model is an agent-written hole pinned by the harness, not a spec failure;
  the conformance target (`ReservationWorkflow` + `EvacuationWorkflow` + the reservation
  command/query/signal operations) does not exercise them, so deferring keeps EP-6
  independently verifiable. Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge. It defines every term, names every file by full
path, and restates the shared signatures from EP-1 that this plan depends on.

### Repository layout and where this plan's code lives

This repository (`/Users/shinzui/Keikaku/bokuno/keiro`) is a multi-package Cabal project.
The runtime primitives this plan targets live under `keiro/src/Keiro/`. The DSL toolchain
package, `keiro-dsl`, is created by **EP-1**
(`docs/plans/59-keiro-dsl-foundations-grammar-parser-validator-scaffold-and-harness-engine-aggregate-vertical.md`),
which adds `keiro-dsl` to the `packages:` list in `cabal.project` (currently `keiro`,
`keiro-core`, `keiro-migrations`, `keiro-pgmq`, `keiro-test-support`). This plan adds
modules and cases *within* `keiro-dsl`; it does not touch any existing runtime package.

The conformance corpus is the **external** sibling repository
`/Users/shinzui/Keikaku/bokuno/keiro-runtime-jitsurei` (not part of this Cabal project). Its
`hospital-capacity` and `incident-command` services hold the rich workflow + operation
examples this plan conforms against. There is also one runnable, in-repo durable workflow at
`jitsurei/src/Jitsurei/DurableWorkflow.hs` that exercises every workflow primitive
(`step`/`sleepNamed`/`awakeableNamed`/child) and is used here to scope notation for `sleep`
and `child`, which the two service corpus workflows do not use. Per the MasterPlan's corpus
decision, conformance fixtures are captured **read-only** under `keiro-dsl/test/fixtures/`.

### Terms of art (plain language)

- **Durable workflow.** An ordinary `effectful` program whose side effects are recorded
  ("journaled") at named checkpoints so it can pause and resume across crashes without
  re-running completed work. The runtime is `Keiro.Workflow`
  (`keiro/src/Keiro/Workflow.hs`) and the suspension primitives in `keiro/src/Keiro/Workflow/`
  (`Sleep.hs`, `Awakeable.hs`, `Child.hs`, `Types.hs`, `Resume.hs`).
- **Journal.** The kiroku event stream `wf:<name>-<id>` (`workflowStreamName`,
  `Types.hs:101-103`) holding one `StepRecorded` event per executed checkpoint plus a
  terminal `WorkflowCompleted` marker. There is no separate history table.
- **Step.** `step (StepName "…") action` runs `action` **once**, journals its JSON-encoded
  result, and on a later resume returns the recorded result *without re-running the action*
  (`Workflow.hs:179-180,468-497`). The step name is the journal key.
- **Replay / resume.** Re-invoking `runWorkflow` with the same id; each already-journaled
  checkpoint short-circuits to its recorded result and only the un-journaled tail runs.
  Because the runtime matches on the checkpoint **label, not source position**, renaming a
  step is a *semantic reset* (the new name has no history, so the action runs fresh).
- **Awakeable.** A durable promise an external system resolves: `awakeableNamed (StepName
  label)` returns `(AwakeableId, await)`; the workflow hands the id out and suspends on
  `await` until something calls `signalAwakeable` with a result (`Awakeable.hs:168-177`).
- **Durable sleep.** `sleepNamed (StepName suffix) delta` arms a deterministic `keiro_timers`
  row and suspends; a timer worker wakes the workflow when the row becomes due
  (`Sleep.hs:165-178,209-227`).
- **Child workflow.** A second workflow spawned from a parent with `spawnChild` and awaited
  with `awaitChild` (`Child.hs:158-208`); the child runs on its **own** journal stream and is
  driven to completion by the resume worker from a `WorkflowRegistry`, not inline.
- **Operation.** A service entry point: a function the application's CLI/HTTP layer calls to
  *do* something. Four shapes (command / query / signal / workflow-run) — see *The four
  operation shapes* below.
- **Read model.** A named, versioned SQL projection table plus the query that reads it,
  represented by `Keiro.ReadModel.ReadModel` (`ReadModel.hs:72-92`); queried via `runQuery`
  with an explicit `ConsistencyMode`.
- **Hole.** A precisely-typed gap the scaffolder leaves for a human/agent to fill (e.g. a
  step body). Holes live in create-if-absent modules; generated wiring lives in
  overwrite-on-scaffold `-- @generated` modules.
- **Firewall invariant.** The tested guarantee that **no `-- @generated` line contains a
  keiki symbolic operator** (`B.slot`, `B.requireGuard`, `=:`, `./=`, `.==`, `.||`, `lit`).
  The brittle symbolic logic is always a hole, never generated. (Workflows contain no keiki
  symbolic logic at all, but operations may reference an aggregate's `EventStream`, whose
  transducer is an EP-1 aggregate hole; the invariant still must hold over everything this
  plan generates.)
- **DETERMINISTIC ON REPLAY (cross-cutting rule).** Because the body re-executes top-to-bottom
  on every resume, anything *outside* a journaled `step` that samples wall-clock, randomness,
  or mutable process state runs again on each resume and produces a different value, corrupting
  the replay. The DSL forbids such samples in body control flow, in sleep deltas-as-deadlines,
  and in child-id expressions, and flags them even inside a step.
- **TIME IS INJECTED, NOT SAMPLED (cross-cutting rule).** A sleep's `delta` is a value carried
  by the input (or a constant); an absolute deadline must be derived from an injected
  timestamp field. The runtime samples `now` only inside the idempotent arming action, where
  the value never reaches the workflow's logic (`Sleep.hs:214-228`).

### Shared EP-1 signatures this plan relies on (restated)

EP-1 defines the shared engine. This plan extends it; the signatures below are the contract
this plan codes against. (EP-1's plan file carries these as its own deliverables — referenced
here by path, restated here so this plan is self-contained.)

- `Keiro.Dsl.Grammar` — the abstract syntax. EP-1 provides a `Spec` record aggregating all
  nodes, the shared declarations (`IdDecl`, `EnumDecl`, `RuleDecl`), the eight hole types,
  the `Aggregate` node constructor, and an `Expr` sublanguage (a small expression grammar
  for field references, string splices `<>`, and id derivations — e.g. `input.reservationId`,
  `idText reservationId`). This plan adds `Workflow` and `Operation` constructors and the
  body-item / operation-shape / consistency types.
- `Keiro.Dsl.Parser` — `parseSpec :: FilePath -> Text -> Either ParseError Spec`, a
  megaparsec parser. This plan adds `pWorkflow`/`pOperation` and wires them into the node
  parser.
- `Keiro.Dsl.PrettyPrint` — a prettyprinter renderer such that parse-then-print round-trips.
- `Keiro.Dsl.Validate` — `validateSpec :: Spec -> [Diagnostic]`, where a `Diagnostic` carries
  a severity, a source span (line/column), and a message. EP-1 provides the cross-cutting
  rules (reachability, the time-injected-not-sampled check, `Expr` scope-checking, and the
  eight hole-kind presence checks). This plan adds the workflow/operation-specific rules
  listed under *Validator rules* below. `keiro-dsl check` prints diagnostics and exits
  non-zero if any are errors.
- `Keiro.Dsl.Scaffold` — `ScaffoldModule { modulePath :: FilePath, moduleText :: Text, kind
  :: ModuleKind }` and `data ModuleKind = Generated | HoleStub`. A `Generated` module is
  overwritten on every scaffold; a `HoleStub` is created only if absent (so hand edits
  survive re-scaffolding). EP-1 provides the firewall-invariant test asserting no `Generated`
  `moduleText` contains a keiki symbolic operator. This plan adds the workflow/operation
  emitters.
- `Keiro.Dsl.Harness` — the emitter producing test modules modeled on the corpus's harness
  specs, asserting the spec's pinned behavior. This plan adds workflow/operation harness
  emission.
- The CLI (`keiro-dsl/app/Main.hs`) — an optparse-applicative tree with `parse`, `check`,
  `scaffold`. This plan adds no subcommands; it extends what they emit/validate.

### The eight hole-kinds (the closed set of non-derivable decisions)

Every non-template decision in a keiro service collapses into one of eight hole-kinds. This
plan's `workflow`/`operation` nodes exercise all eight; naming them keeps the validator's
required-decision checks systematic, and the *Validator rules* below are organized by which
hole each defends:

1. **Derivation** — a deterministic id-from-key function. Workflow: the `WorkflowId` from a
   domain id (`WorkflowId (idText reservationId)`, `ReservationWorkflow.hs:71`); a child id
   (`shipChildId`, `DurableWorkflow.hs:95-103`). Operation: a command's target *stream* from
   a field.
2. **Disposition** — what to do with an outcome (`Completed`/`Suspended`/`Cancelled`/
   `ContinuedAsNew`, `Types.hs:254-266`; a `signal` returning `False`,
   `Awakeable.hs:240-268`). The operation must map the runtime outcome to a service result.
3. **Mapping** — a pure transform: input fields → a step result; a `ReadModel` query row → a
   domain value. This is the *opaque step body* (an agent-written hole).
4. **Field-source** — the journal keys: each step/await/sleep/child **name** is an author-chosen,
   must-be-unique-per-workflow label; and which input field feeds the `WorkflowId`, the `signal`
   key, the command `stream`.
5. **Cross-node coupling** — a reference from one node to a declared other: the await↔signal
   label match; a `child` to a declared+registered workflow; a command op's inline `project`
   to a declared projection; a `PositionWait` query's read-your-writes target.
6. **Decode strictness** — a step/await result type needs `ToJSON`+`FromJSON` and must stay
   decode-compatible across deploys, or replay throws `WorkflowStepDecodeError`
   (`Workflow.hs:304-308`).
7. **Optionality** — an explicit empty (no inline projections on a command op; no `child`).
8. **Runtime config** — knobs delegated to the runtime worker: `WorkflowRunOptions`
   (snapshot policy, page size, telemetry, `Workflow.hs:263-294`), `RunCommandOptions`
   (retry limit, page size, `Command.hs:134-170`), the resume-worker poll cadence,
   `PositionWaitOptions` timeout/poll (`ReadModel.hs:101-106`). These are scaffolded with the
   runtime defaults and not modeled in the body.

### The bijection (DSL node → keiro primitive)

A `keiro-dsl` node is faithful only if it maps onto a named keiro primitive. The two new
nodes this plan adds map as follows:

- `workflow` → `Keiro.Workflow` — a `WorkflowName`/`WorkflowId` identity plus an ordered body
  built from `step` (`Workflow.hs:179`), `awakeableNamed` (`Awakeable.hs:168`), `sleepNamed`
  (`Sleep.hs:209`), and the child pair `spawnChild`/`awaitChild` (`Child.hs:158,194`), run by
  `runWorkflowWith` (`Workflow.hs:376`), plus a `WorkflowRegistry` entry
  (`Resume.hs:48-70`) so the resume worker can re-invoke it.
- `operation` → one of four runtime entry points: `Keiro.Command.runCommand` (and its
  in-transaction variants `runCommandWithSql`/`runCommandWithSqlEvents`,
  `Command.hs:355,400,420`) plus inline projections; `Keiro.ReadModel.runQuery` over a
  `ReadModel` record (`ReadModel.hs:72-92,128`); `Keiro.Workflow.Awakeable.signalAwakeable`
  (`Awakeable.hs:240`); or `Keiro.Workflow.runWorkflowWith` (`Workflow.hs:376`).

### The runtime primitives in detail (read these files to verify)

**Workflow identity** (`keiro/src/Keiro/Workflow/Types.hs`). `WorkflowName` is the *stable
literal* name of a workflow definition (`newtype WorkflowName = WorkflowName Text`,
`Types.hs:63-69`); it is part of the journal stream name **and** of every deterministic id
(journal-event id `Workflow.hs:829-836`, awakeable id `Awakeable.hs:131-137`, sleep timer id
`Sleep.hs:165-178`), so it must not change for a given definition across deploys — this is
**Hole 8** (a runtime-config-class stable identifier). The corpus:
`reservationWorkflowName = WorkflowName "hospital-transfer-reservation"`
(`ReservationWorkflow.hs:68-69`). `WorkflowId` identifies a single instance and is **derived
from a domain id** — **Hole 1**: `reservationWorkflowId reservationId = WorkflowId (idText
reservationId)` (`ReservationWorkflow.hs:71-72`).

**Steps** (`keiro/src/Keiro/Workflow.hs`). `step (StepName "…") action` requires the result
to have `ToJSON` *and* `FromJSON` (`Workflow.hs:148`): the result is journaled on the miss
path and decoded on the hit (replay) path. The replay handler matches on the `StepName`
**label, not source position** (`Types.hs:78-83`), so renaming a step is a semantic reset.
Step names are **Hole 4** (journal keys, author-chosen, must be unique per workflow — a
collision means two steps overwrite each other's journal entry). The result type is **Hole
6**: it must stay decode-compatible across deploys, or a replay throws
`WorkflowStepDecodeError` (`Workflow.hs:304-308`). The corpus reservation order is
`create-transfer-hold` → (await `reservation-confirmation`) → `release-or-retain-capacity` →
`summarize-reservation` (`ReservationWorkflow.hs:83-87`).

**Awakeables** (`keiro/src/Keiro/Workflow/Awakeable.hs`). `awakeableNamed (StepName label)`
returns `(AwakeableId, await)` (`:168-177`). The id is a **deterministic** v5 UUID over
`("keiro":"awakeable":workflowName:workflowId:label)` (`deterministicAwakeableId`,
`:131-137`). Determinism is essential because a resumed run re-runs from the top and must
allocate the *same* id it already handed out and journaled, so the `await` hit path matches.
The **cross-node coupling (Hole 5)** is that the workflow declares the awakeable **and** an
externally-callable id helper so a separate operation can signal it. The corpus declares
`reservationConfirmationAwakeableId reservationId = deterministicAwakeableId
reservationWorkflowName (reservationWorkflowId reservationId) "reservation-confirmation"`
(`ReservationWorkflow.hs:74-76`), and the signal operation calls `signalAwakeable
(reservationConfirmationAwakeableId reservationId) confirmation` (`Store.hs:302-313`). The
label (`"reservation-confirmation"`) must be unique per workflow **and identical on both
sides**.

**Durable sleep** (`keiro/src/Keiro/Workflow/Sleep.hs`). `sleepNamed (StepName suffix) delta`
arms a deterministic `keiro_timers` row and suspends (`:165-178,209-227`). The `delta ::
NominalDiffTime` is the **injected datum** (the in-repo example uses a constant `coolingOffDelay
= 2`, `DurableWorkflow.hs:80-81`). An absolute deadline must come from injected data, never a
fresh `getCurrentTime` in the body — the arming action samples `now` only to compute
`addUTCTime delta now` *inside* the idempotent arm (`Sleep.hs:214-228`), where it never reaches
workflow logic. The notation uses only `sleepNamed`; the ordinal `sleep` is conditionally
deterministic (`Sleep.hs:230-238`) and forbidden.

**Child workflows** (`keiro/src/Keiro/Workflow/Child.hs`). `spawnChild name id childDef`
records a spawn step in the *parent* journal and inserts a link row, then `awaitChild`
suspends the parent until the child completes (`:158-208`). The child is **not run inline** —
the resume worker drives it from a `WorkflowRegistry` keyed by `WorkflowName` (module header;
`Resume.hs:48-70`), so a child's name **must be registered** there (Hole 5 coupling — spawning
an unregistered name hangs at runtime). The child id **must differ from the parent's** (Hole
1): the `keiro_workflow_steps` index is keyed by `(workflow_id, step_name)` and discovery
groups by `workflow_id` alone, so a shared id lets the child's terminal marker mask the
parent's incompleteness (`DurableWorkflow.hs:95-103`). The corpus suffixes the id:
`shipChildId orderId = WorkflowId (orderIdText orderId <> "-ship")`.

**The resume registry** (`keiro/src/Keiro/Workflow/Resume.hs`). A workflow's body is
application code; only its journal lives in the database. To re-invoke a crashed or
suspended workflow the worker turns a stored `WorkflowName` into a body via an
application-supplied `WorkflowRegistry` (`Map WorkflowName WorkflowDef`, `Resume.hs:48-70`).
The corpus registry maps each name to a `WorkflowDef` rebuilding the body from the id
(`jitsureiWorkflowRegistry`, `DurableWorkflow.hs:233-238`). Every declared workflow — and
every spawned child — must appear here.

**Determinism is the master constraint.** `runWorkflowWith` interprets each `step` as a
hit/miss on the journal map (`Workflow.hs:467-497`): a miss runs the action and journals the
JSON; a hit returns the recorded JSON decoded. Everything *between* checkpoints runs on every
resume. So any wall-clock/randomness/mutable-state sample *outside* a journaled step runs
again each resume and corrupts replay. The DSL forbids clock/random in body control flow,
sleep deltas-as-deadlines, and child-id expressions, except as an injected input field or
inside a journaled `step` (and even there it flags it as a determinism hazard for review).

### The four operation shapes (read the corpus to verify)

An `operation` is a service entry point. The corpus realizes four shapes, all visible in
`HospitalCapacity/Store.hs` and the reservation processors:

- **(a) Command op** → `runCommand`-family on an aggregate's `EventStream`, with inline
  projections in the same transaction. The corpus wires
  `runReservationCommandDurably store reservationId command` →
  `runDurableCommand … reservationEventStream (reservationStream reservationId) command
  [transferDecisionProjection]` (`CommandProcessor.hs:46-62`), where `runDurableCommand` is a
  thin wrapper over `runCommandWithProjections` (`Store.hs:451-468`). The **target stream**
  comes from a field — `reservationStream reservationId` (Hole 1 derivation) — and the inline
  projections are the in-transaction read-model writes (Hole 5 coupling; here
  `transferDecisionProjection` from `Projection.hs:55-60`).
- **(b) Read-model query op** → `runQuery metrics readModel input` over a `ReadModel { name,
  tableName, subscriptionName, version, shapeHash, defaultConsistency, query }`
  (`ReadModel.hs:72-92`). The corpus `transferDecisionReadModel` has `defaultConsistency =
  Strong` (`Projection.hs:42-53`) and is queried via `queryTransferDecision … queryReadModel
  … transferDecisionReadModel` (`Store.hs:441-477`). `ConsistencyMode` is
  `Strong | Eventual | PositionWait PositionWaitOptions` (`ReadModel.hs:88-92`); `PositionWait`
  needs a target `GlobalPosition` for read-your-writes (Hole 5 cross-operation; `:101-106`).
- **(c) Signal op** → `signalAwakeable awakeableId result` (the awakeable partner of a
  workflow's `await`, Hole 5). The corpus `signalReservationConfirmation store reservationId
  confirmation` → `signalAwakeable (reservationConfirmationAwakeableId reservationId)
  confirmation` (`Store.hs:298-313`).
- **(d) Workflow-run op** → `runWorkflowWith opts name id (body input)`. The corpus
  `runReservationWorkflowDurably store input` → `runWorkflowWith
  (workflowOptionsWithTelemetry …) reservationWorkflowName (reservationWorkflowId
  input.reservationId) (reservationWorkflow input)` (`Store.hs:273-296`), mapping the
  `WorkflowOutcome` (`Completed`/`Suspended`/`Cancelled`/`ContinuedAsNew`) to a service result
  (`toReservationWorkflowRun`, `:624-645`) — that mapping is **Hole 2 disposition**.

### Proposed notation

A `workflow` node names its definition, derives its `WorkflowId` from an input field, gives
its `in`/`out` types, and lists an **ordered body** of checkpoint items. An `operation` node
appears in one of four forms. The two service workflows (reservation, evacuation) have no
`sleep` or `child`, so the `sleep`/`child` forms are illustrated with the in-repo
order-fulfillment example. Worked example (the hospital-transfer-reservation workflow plus
its three operations):

```text
workflow HospitalTransferReservation
  name "hospital-transfer-reservation"            # Hole 8: stable literal (journal stream + every det. id)
  in   ReservationWorkflowInput { reservationId:Id hospitalId:Id patientAcuity requiredBedType }
  out  ReservationWorkflowSummary
  id   from input.reservationId via idText        # Hole 1 derivation -> WorkflowId

  body                                            # ORDERED; replay matches on label, not position
    step  create-transfer-hold        -> ReservationHold          # Hole 3 body (opaque) + Hole 6 codec
    await reservation-confirmation     -> ReservationConfirmation  # Hole 4 label + Hole 5 await<->signal
    step  release-or-retain-capacity   -> CapacityRelease
    step  summarize-reservation        -> ReservationWorkflowSummary

# (a) command operation — run a durable command + inline projection, in one transaction
operation ConfirmReservation
  command on Reservation                          # Hole 5: the aggregate EventStream
    stream from reservationId via reservationStream   # Hole 1: target stream derivation
    project [ transferDecision ]                  # Hole 5/7: inline in-txn projections ([] = append-only)

# (b) read-model query operation
operation QueryTransferDecision
  query transferDecision                          # Hole 5: the declared ReadModel
    input  TransferReservationId
    result Maybe TransferDecision
    consistency Strong                            # default; Eventual/PositionWait need `override`

# (c) signal operation — the await partner of HospitalTransferReservation
operation SignalReservationConfirmation
  signal reservation-confirmation of HospitalTransferReservation   # Hole 5: must match the await label
    key   from reservationId via reservationWorkflowId             # derives the SAME (name,id,label)
    value ReservationConfirmation

# (d) workflow-run operation
operation RunReservationWorkflow
  run HospitalTransferReservation                 # Hole 5: the declared workflow
    input ReservationWorkflowInput
    outcome -> ReservationWorkflowRun             # Hole 2: WorkflowOutcome -> service result
```

The `await reservation-confirmation` line and the `signal reservation-confirmation of
HospitalTransferReservation` operation are the **load-bearing coupling**: both sides derive
the *same* deterministic awakeable id from `(WorkflowName, WorkflowId, label)`, so the signal
actually wakes the workflow. The `sleep` and `child` forms (illustrated against the in-repo
order-fulfillment workflow) extend the body vocabulary:

```text
workflow OrderFulfillment
  name "order-fulfillment"
  in   OrderId
  out  Text
  id   from input via workflowIdFor

  body
    step  reserve-inventory  -> Text
    sleep cooling-off  after coolingOffDelay        # TIME INJECTED: NominalDiffTime datum, not a clock read
    await payment-webhook    -> PaymentConfirmation  # await<->signal (external webhook here)
    step  charge             -> Text
    child ship-order  id input via shipChildId  -> Text   # Hole 1: id MUST differ from parent's (suffix "-ship")
```

The `sleep cooling-off after coolingOffDelay` line states that the delay is an injected
`NominalDiffTime` (here a spec constant), **not** a wall-clock deadline; and the `child
ship-order id input via shipChildId` line names a *declared, registered* child workflow whose
id derivation is provably distinct from the parent's.

### Coverage gaps (recorded honestly as known limitations + grammar TODOs)

Most of these are agent-written holes by design, not spec failures; they are recorded so a
future contributor knows the boundary. (See the matching Decision Log entry.)

- **Inter-step data flow and conditional/branching control flow are NOT expressible — the
  biggest gap.** A workflow body is an *opaque-bodied ordered list*; the spec captures the
  checkpoint *sequence and types*, not how a step's result flows into a later step or whether
  a checkpoint is taken at all. A workflow whose **step sequence depends on a prior result**
  (`if confirmation.accepted then … else …` controlling *which* steps run) cannot be written;
  the corpus encodes such conditionals *inside* the (opaque) step bodies
  (`releaseOrRetainCapacity … if confirmation.accepted`, `ReservationWorkflow.hs:98-105`),
  which is exactly the agent-written hole.
- **`continueAsNew` / `patch` are unrepresentable.** Rolling/unbounded workflows
  (`continueAsNew`, `restoreSeed`, `Workflow.hs:207-232`) and in-flight migrations (`patch`,
  `:234-252`) have no notation. Grammar TODO.
- **`cancelAwakeable` / `cancelChild` compensation paths are not modeled.** The cancel APIs
  (`Awakeable.hs:276`, `Child.hs:228`) and their `WorkflowAwakeableCancelled` /
  `WorkflowChildCancelled` compensation catches are out of scope.
- **The ordinal `sleep` / `awakeable` forms are forbidden, not supported** (they are
  positionally fragile; see Decision Log).
- **Cross-operation `PositionWait` target plumbing is not modeled.** A query that must wait on
  the `GlobalPosition` a *prior command operation* returned (read-your-writes across two
  operations) is a cross-operation data-flow the notation does not thread; `PositionWait` with
  a `Nothing` target is a silent no-wait (`ReadModel.hs:235-238`), which the validator flags.
- **Bespoke `afterAppend` transactions beyond a single named inline projection** are not
  modeled. `runCommandWithSqlEvents` lets a command run arbitrary in-transaction SQL
  (`Command.hs:420-428`); the notation supports only a list of declared inline `project`
  references.
- **Deterministic command-id derivation for idempotent commands** is not modeled. The corpus
  derives a stable command id from a source message
  (`confirmationCommandIdText`/`deterministicCommandSuffix`, `CommandProcessor.hs:180-191`)
  to make confirmation idempotent; that derivation is an opaque hole here.

### Validator rules to implement (this plan's additions to `validateSpec`)

Each rule produces a line-numbered `Diagnostic` of error severity (unless noted as a warning)
when violated:

- **`ruleNoClockOrRandomOutsideStep`** — the body's *structural* expressions (a `child` id
  expr, a `sleep` delta used as a deadline, any `id from` derivation) must not reference a
  clock-sampling or randomness primitive (`getCurrentTime`, `now`, `today`, `random`, a
  fresh-`uuid-v4` generator). A clock/random reference outside a journaled `step` is an error;
  inside a step body (which the scaffolder does not see) the rule cannot fire, so the harness's
  replay-determinism test is the backstop.
- **`ruleSleepDeadlineInjected`** — a `sleep <name> after <expr>` must be a `NominalDiffTime`
  datum (an injected input field of `:Duration` type or a declared spec constant), never an
  absolute deadline computed from a fresh clock read.
- **`ruleUniqueJournalNames`** — every `step`/`await`/`sleep`/`child` name within one workflow
  must be unique; a duplicate is a journal-key collision (two checkpoints would overwrite each
  other's `StepRecorded`).
- **`ruleAwaitHasSignal`** — every `await <label>` must either (a) have a matching `signal
  <label> of <thisWorkflow>` operation in the spec whose `key from <field>` derives the same
  `(WorkflowName, WorkflowId, label)` triple, or (b) be explicitly marked `external-only` (the
  signaller lives outside this service). An unmatched, non-external await is an error.
- **`ruleSignalMatchesAwait`** — conversely, a `signal <label> of <wf>` operation must
  reference a declared workflow `<wf>` that *contains* an `await <label>`, and its key
  derivation must use the workflow's own `WorkflowId` derivation (so the ids agree).
- **`ruleChildResolvesAndRegistered`** — a `child <name>` must resolve to a workflow declared
  in the spec (and therefore scaffolded into the resume registry); spawning an undeclared name
  is an error.
- **`ruleChildIdDistinct`** — a `child`'s `id … via <f>` derivation must be provably distinct
  from the parent's `id from … via <g>` derivation (e.g. a distinct suffix); an identical
  derivation is an error (terminal-marker masking).
- **`ruleStepResultHasCodec`** — every `step`/`await`/`child` result type must be a declared
  type with `ToJSON`+`FromJSON` (Hole 6); the rule also emits an *informational* diagnostic
  noting that a later change to any such type is a **breaking** change requiring an upcaster or
  a new step name.
- **`ruleStableIdentifiers`** (warning) — `WorkflowName` and a query op's read-model
  `shapeHash`/`version` are stable identifiers; renaming `WorkflowName` orphans every in-flight
  journal stream, and changing `shapeHash`/`version` forces a rebuild (`ReadModel.hs:206-225`).
  The rule warns on a rename detected against the captured fixture (and EP-2's `diff` upgrades
  this to a breaking classification).
- **`ruleCommandStreamAndProjections`** — a command op's `stream … from <field>` must
  reference a real input field, and each `via`/`project` reference must resolve to a declared
  derivation / inline projection.
- **`ruleConsistencyOverride`** — a query op may use the read model's `defaultConsistency`
  silently, but `Eventual` or `PositionWait` against a `Strong`-default model requires an
  explicit `override` keyword; a `PositionWait` additionally requires a target
  `GlobalPosition` source (a `Nothing` target is a silent no-wait).


## Plan of Work

The work is five milestones, each independently verifiable. They follow the engine's data
flow: grammar+parser → validator → scaffold → harness → conformance. All edits are additive
to the shared `keiro-dsl` modules EP-1 created; this plan introduces no new runtime package
and touches no existing one.

### Milestone 1 — Grammar and parser for `workflow`/`operation`

Scope: make a `workflow` block (with its ordered body) and an `operation` block (in all four
forms) first-class parts of the AST and parseable, round-trippable parts of the notation. At
the end, `keiro-dsl parse` accepts a `.kdsl` containing a `workflow` and its operations and
prints it back out identically.

Edits:

- In `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, add to the node sum a `Workflow !WorkflowNode` and
  an `Operation !OperationNode` constructor. `WorkflowNode` carries: `wfName :: Text` (the
  define-once stable `name`), `wfInput :: TypeRef`, `wfOutput :: TypeRef`, `wfId ::
  IdDerivation` (the input field + derivation `Expr` producing the `WorkflowId`), and `wfBody
  :: [BodyItem]`. Define `data BodyItem = StepItem StepDecl | AwaitItem AwaitDecl | SleepItem
  SleepDecl | ChildItem ChildDecl` where `StepDecl { stepLabel :: Text, stepResult ::
  TypeRef }`, `AwaitDecl { awaitLabel :: Text, awaitResult :: TypeRef, awaitExternalOnly ::
  Bool }`, `SleepDecl { sleepLabel :: Text, sleepDelta :: Expr }` (the delta is structurally a
  duration datum, *not* a clock expression — there is no clock constructor), and `ChildDecl {
  childWorkflow :: Text, childIdFrom :: Expr, childResult :: TypeRef }`. `OperationNode`
  carries `opName :: Text` and `opShape :: OperationShape` where `data OperationShape =
  CommandOp CommandOpDecl | QueryOp QueryOpDecl | SignalOp SignalOpDecl | RunOp RunOpDecl`.
  `CommandOpDecl` carries the target aggregate ref, the `stream from <field> via <Expr>`
  derivation, and `project :: [ProjectionRef]` (Hole 7, possibly empty). `QueryOpDecl` carries
  the `ReadModelRef`, the input/result type refs, and `consistency :: Consistency` where `data
  Consistency = UseDefault | Override ConsistencyMode` and `ConsistencyMode = Strong | Eventual
  | PositionWait PositionTarget`. `SignalOpDecl` carries the await label, the owning workflow
  ref, the key derivation `Expr`, and the value type ref. `RunOpDecl` carries the workflow ref,
  the input type ref, and the outcome-mapping ref.
- In `keiro-dsl/src/Keiro/Dsl/Parser.hs`, add `pWorkflow :: Parser WorkflowNode` and
  `pOperation :: Parser OperationNode`, registered in the top-level node parser (`pNode`). The
  body parser reads ordered `step`/`await`/`sleep`/`child` lines; the operation parser
  dispatches on the leading keyword (`command`/`query`/`signal`/`run`). Reuse EP-1's `Expr`
  parser for the `id from … via …`, `stream from … via …`, `key from … via …`, and `sleep …
  after …` expressions. The ordinal `sleep`/`awakeable` keyword forms are rejected at parse
  time with a fix-it message ("use a named `sleep <name>` / `await <label>`").
- In `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`, add `prettyWorkflow`/`prettyOperation` so that
  `parse` then pretty-print is idempotent on a `workflow`-bearing spec, preserving body order.

Acceptance: `cabal run keiro-dsl -- parse keiro-dsl/test/fixtures/hospital-reservation/hospital-reservation.kdsl`
prints a model that, re-parsed, equals the first (round-trip test green).

### Milestone 2 — Validator rules

Scope: turn the *Validator rules to implement* list (Context) into code, so `keiro-dsl check`
rejects every dangerous omission and every broken coupling. At the end, a deliberately-broken
spec fails with a precise diagnostic and the corpus spec passes clean.

Edits, all in `keiro-dsl/src/Keiro/Dsl/Validate.hs`, added to the `validateSpec` rule set, one
function per rule named in *Context*: `ruleNoClockOrRandomOutsideStep`,
`ruleSleepDeadlineInjected`, `ruleUniqueJournalNames`, `ruleAwaitHasSignal`,
`ruleSignalMatchesAwait`, `ruleChildResolvesAndRegistered`, `ruleChildIdDistinct`,
`ruleStepResultHasCodec`, `ruleStableIdentifiers` (warning), `ruleCommandStreamAndProjections`,
and `ruleConsistencyOverride`. The await↔signal pair (`ruleAwaitHasSignal` /
`ruleSignalMatchesAwait`) is the cross-node heart of this milestone: it walks every workflow's
`AwaitItem`s and every `SignalOp`, builds the `(WorkflowName, WorkflowId-derivation, label)`
triple for each, and requires a bijection (modulo `external-only` awaits). `ruleChildIdDistinct`
compares the parent's `wfId` derivation `Expr` against the `childIdFrom` `Expr` and rejects a
structural equality.

Acceptance: `cabal run keiro-dsl -- check` on the corpus spec exits 0; on each mutated spec
(one per rule) it exits non-zero with the expected message (see Validation and Acceptance).

### Milestone 3 — Scaffold emitters (symbol-free wiring + body skeleton + holes)

Scope: emit the deterministic layer and the typed holes. At the end, `keiro-dsl scaffold`
produces a `-- @generated` workflow-wiring module (identity, id helpers, registry entry, and
the *structural* body skeleton), a `-- @generated` operation-wiring module, and a
create-if-absent hole module for the step bodies — and the firewall-invariant test passes.

Edits, in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`:

- `scaffoldWorkflow :: WorkflowNode -> [ScaffoldModule]`. A `Generated` module emitting: the
  `WorkflowName` literal; the `WorkflowId` derivation function (from `wfId`); a
  `deterministicAwakeableId`-based id helper for **each** `AwaitItem` (so a signal operation
  can import the exact id, exactly as `reservationConfirmationAwakeableId` does); a child-id
  helper for each `ChildItem` (from `childIdFrom`); the `WorkflowRegistry` entry mapping
  `wfName` to a `WorkflowDef` that rebuilds the body from the id; and the **body skeleton** —
  an ordered `do` block of `step (StepName "…") (<hole>)`, `awakeableNamed (StepName "…")` +
  its `await`, `sleepNamed (StepName "…") <delta>`, and `spawnChild … <childId> …` /
  `awaitChild` calls, each carrying its journal name and result type but delegating the
  *computation* to a hole function. This module contains **no** keiki symbolic operator and
  **no** step-body logic — only the structural wiring.
- `scaffoldOperation :: OperationNode -> [ScaffoldModule]`. A `Generated` module per operation
  shape: a command op emits the `runCommandWithProjections`-style wrapper binding the
  spec-named `EventStream`, the `stream`-from-field derivation, and the inline `project` list;
  a query op emits the `ReadModel { name, tableName, subscriptionName, version, shapeHash,
  defaultConsistency, query }` record (the `query` body itself is a hole — the SQL) and the
  `runQuery`/`runQueryWith` wrapper honouring the spec consistency; a signal op emits the
  `signalAwakeable (<awakeable-id-helper> key) value` wrapper, *importing the very id helper
  the workflow module generated* (closing the coupling); a run op emits the `runWorkflowWith
  opts name id (body input)` wrapper plus the outcome-mapping call.
- A shared `HoleStub` module emitting *signatures only* for: each step body (`<stepLabel> ::
  <inputs> -> Eff es <stepResult>`); each id/field/stream derivation that is genuinely an
  author choice (e.g. the `via` function if not a library helper); the query op's SQL `query`
  function; and the run op's `WorkflowOutcome -> <service result>` mapping. The emitter
  **never** emits a step's computation and **never** emits `B.requireGuard`/`B.slot`.

Critical constraint restated: the scaffolder emits the body's *structure* (which named
checkpoints run, in what order, with which result types) but **never** a step body's logic —
that is the agent-written hole — and the generated layer never contains a keiki symbolic
operator.

Acceptance: scaffold runs; the firewall test (a `grep`-style assertion over every `Generated`
`moduleText`) finds no symbolic operator; re-running scaffold does not clobber the hole module.

### Milestone 4 — Harness emission

Scope: emit a spec-derived test module pinning the behavior the spec asserts. At the end, the
harness compiles against filled holes and goes green; a mutation turns one test red.

Edits, in `keiro-dsl/src/Keiro/Dsl/Harness.hs`, adding `harnessWorkflow :: WorkflowNode ->
ScaffoldModule` and `harnessOperation :: OperationNode -> ScaffoldModule`. The emitted module
asserts:

- **Replay determinism.** Run the (filled) workflow body once against an empty journal,
  capture the journaled step results; run it a second time *from that journal* and assert (a)
  the final result is identical and (b) no step that was replayed ran its side effect again
  (the corpus side-effect-printing pattern in `DurableWorkflow.hs:184-220` is the model —
  a replayed step prints nothing). This is the backstop for `ruleNoClockOrRandomOutsideStep`:
  a body that samples the wall clock in control flow produces a *different* second run and
  fails this test.
- **Await↔signal id match.** For every `AwaitItem` with a matching `SignalOp`, assert that the
  workflow's `deterministicAwakeableId wfName (wfId input) label` **equals** the signal
  operation's derived id for the same input. A label drift on either side reddens this test.
- **Golden step-result codec round-trips.** For each step/await/child result type, assert
  `decode (encode x) == Just x` on a representative value, pinning the JSON shape so a careless
  type change is caught here rather than at runtime (`WorkflowStepDecodeError`).

Acceptance: `cabal test keiro-dsl` on the emitted harness is green with filled holes.

### Milestone 5 — Conformance vs `ReservationWorkflow` + `EvacuationWorkflow`

Scope: prove the whole vertical against the real corpus. At the end, the captured fixtures, the
authored `.kdsl` files, and the round-trip check → scaffold → fill → harness loop all pass, and
a mutation demonstrably breaks a specific test.

Edits and steps:

- Capture read-only fixtures under `keiro-dsl/test/fixtures/`:
  `hospital-reservation/` ← `ReservationWorkflow.hs`, `Reservation/CommandProcessor.hs`,
  `Reservation/Projection.hs`, and the relevant `Store.hs` operation wrappers from
  `/Users/shinzui/Keikaku/bokuno/keiro-runtime-jitsurei/services/hospital-capacity/src/HospitalCapacity/`;
  `incident-evacuation/` ← `EvacuationWorkflow.hs` from
  `/Users/shinzui/Keikaku/bokuno/keiro-runtime-jitsurei/services/incident-command/src/IncidentCommand/`.
- Author `keiro-dsl/test/fixtures/hospital-reservation/hospital-reservation.kdsl` (the notation
  above: the `workflow` plus the four `operation`s) and
  `keiro-dsl/test/fixtures/incident-evacuation/incident-evacuation.kdsl` (the evacuation
  workflow plus its capacity-acknowledgement signal — `EvacuationWorkflow.hs:73-86`).
- Run check → scaffold → fill the step-body holes to match the captured reference → run
  harness; confirm green.
- Mutation test: change one side of the await↔signal label (e.g. the signal operation's label
  from `reservation-confirmation` to `reservation-confirmed`), re-scaffold, and confirm the
  harness's await↔signal id-match assertion turns **red**. Separately, change a step's result
  type and confirm the golden codec round-trip reddens. Restore.

Acceptance: see Validation and Acceptance.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless noted.
The `keiro-dsl` package and its CLI are provided by EP-1; this plan assumes EP-1 is Complete
(the `keiro-dsl` executable builds and `parse`/`check`/`scaffold` work on an aggregate-only
spec).

Confirm the toolchain builds before starting:

```bash
cabal build keiro-dsl
```

Expected: a successful build line ending in the `keiro-dsl` library and exe components.

### Milestone 1 — parse a workflow spec

After the Grammar/Parser/PrettyPrint edits, capture the fixtures and author the spec, then:

```bash
cabal run keiro-dsl -- parse keiro-dsl/test/fixtures/hospital-reservation/hospital-reservation.kdsl
```

Expected (abridged): a pretty-printed echo of the spec, including the `workflow
HospitalTransferReservation` block with its ordered `body` (the `create-transfer-hold` step,
the `reservation-confirmation` await, the `release-or-retain-capacity` and
`summarize-reservation` steps), and the four `operation` blocks — byte-identical to the input
modulo normalized whitespace. The round-trip unit test:

```bash
cabal test keiro-dsl --test-options='--match "parser/round-trip workflow"'
```

Expected: `1 example, 0 failures` (or the project's test-runner equivalent).

### Milestone 2 — check rejects dangerous omissions

```bash
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/hospital-reservation/hospital-reservation.kdsl
echo "exit=$?"
```

Expected: no diagnostics, `exit=0`.

For each rule, a mutated copy must fail. Example (break the await↔signal label coupling):

```bash
sed 's/signal reservation-confirmation/signal reservation-confirmed/' \
  keiro-dsl/test/fixtures/hospital-reservation/hospital-reservation.kdsl > /tmp/bad-signal.kdsl
cabal run keiro-dsl -- check /tmp/bad-signal.kdsl
echo "exit=$?"
```

Expected: a line-numbered error such as

```text
hospital-reservation.kdsl:NN:C: error: signal 'reservation-confirmed' of HospitalTransferReservation has no matching 'await' (workflow declares await 'reservation-confirmation'); the deterministic awakeable id will not match and the workflow will wait forever
exit=1
```

Analogous mutations and expected messages for the other rules: duplicating a step name
(`error: workflow 'HospitalTransferReservation' reuses journal name 'create-transfer-hold'; step/await/sleep/child names must be unique per workflow`); giving a `child` the parent's id
derivation (`error: child 'ship-order' id derivation is identical to the parent's; a shared workflow id lets the child's terminal marker mask the parent — use a distinct suffix`);
spawning an undeclared child (`error: child 'ship-order' resolves to no declared workflow; declare and register it`); replacing `sleep cooling-off after coolingOffDelay` with `sleep
cooling-off after now` (`error: sleep 'cooling-off' deadline must be an injected duration datum, not a wall-clock sample`); weakening the query op (`error: 'transferDecision' read model defaults to Strong; Eventual requires an explicit 'override'`).

### Milestone 3 — scaffold and firewall

```bash
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/hospital-reservation/hospital-reservation.kdsl --out /tmp/reservation-scaffold
ls /tmp/reservation-scaffold
```

Expected: a `-- @generated` workflow module (e.g.
`Generated/HospitalTransferReservationWorkflow.hs`), a `-- @generated` operations module (e.g.
`Generated/HospitalReservationOperations.hs`), and a hole module (e.g.
`HospitalTransferReservationWorkflowHoles.hs`). Firewall check:

```bash
grep -nE 'B\.slot|B\.requireGuard|\blit\b|=:|\./=|\.==|\.\|\|' /tmp/reservation-scaffold/Generated/*.hs
echo "exit=$?"
```

Expected: no matches, `exit=1` (grep found nothing) — the generated layer is symbol-free. The
harness-backed firewall unit test:

```bash
cabal test keiro-dsl --test-options='--match "scaffold/firewall workflow"'
```

Expected: `0 failures`. Confirm the body skeleton is structural-only: the generated workflow
module's body should contain the ordered `step (StepName "create-transfer-hold") …` /
`awakeableNamed (StepName "reservation-confirmation")` / … calls but **no** step computation
(each delegates to a hole), and the hole module should carry the matching signatures.

### Milestone 4 — harness green

```bash
cabal test keiro-dsl --test-options='--match "harness/hospital-reservation"'
```

Expected: all workflow/operation harness examples pass — the replay-determinism test, the
await↔signal id-match test, and the golden codec round-trips.

### Milestone 5 — conformance and mutation

With the step bodies filled to match the captured `ReservationWorkflow.hs` and
`EvacuationWorkflow.hs` references, the full suite is green:

```bash
cabal test keiro-dsl
```

Mutation (prove the harness pins the await↔signal coupling):

```bash
sed -i.bak 's/signal reservation-confirmation/signal reservation-confirmed/' \
  keiro-dsl/test/fixtures/hospital-reservation/hospital-reservation.kdsl
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/hospital-reservation/hospital-reservation.kdsl --out /tmp/reservation-mut
cabal test keiro-dsl --test-options='--match "harness/hospital-reservation/await-signal"'
echo "exit=$?"
mv keiro-dsl/test/fixtures/hospital-reservation/hospital-reservation.kdsl.bak keiro-dsl/test/fixtures/hospital-reservation/hospital-reservation.kdsl
```

Expected: the `await-signal` example **fails** (`exit` non-zero) under the mutated spec — and
`check` would have rejected it first — then the restore returns the suite to green. A second
mutation (changing the `summarize-reservation` step's result type) reddens
`harness/hospital-reservation/codec`. This is the user-visible proof that the spec's couplings
and codecs are genuinely pinned.


## Validation and Acceptance

The plan is accepted when all of the following observable behaviors hold, each demonstrable by
the commands in *Concrete Steps*:

1. **Parse + round-trip.** `keiro-dsl parse` on `hospital-reservation.kdsl` echoes a `workflow`
   block with its ordered `body` and the four `operation` blocks, and re-parsing the output
   yields an equal model (`parser/round-trip workflow` test green). This proves the notation is
   a real language with a stable body order, not freeform text.
2. **Check forces every dangerous decision and coupling.** `keiro-dsl check` passes the corpus
   spec (exit 0) and rejects each of these mutated specs with a precise, line-numbered
   diagnostic and a non-zero exit: a duplicated journal name; an `await` with no matching
   `signal` (label drift); a `child` sharing the parent's id derivation; an undeclared/
   unregistered child; a `sleep` whose deadline samples the clock; a `step` body or `child` id
   that references a clock/random primitive in control flow; a query op weakening a `Strong`
   read model to `Eventual`/`PositionWait` without `override`; a command op `stream from` field
   or `project` reference that does not resolve. This proves the checker catches the omissions
   *before any Haskell is written*.
3. **Scaffold emits a symbol-free deterministic layer + body structure + holes.** `keiro-dsl
   scaffold` produces `-- @generated` workflow- and operation-wiring modules containing **no**
   keiki symbolic operator (`grep` finds nothing; the `scaffold/firewall workflow` test is
   green) and **no** step-body logic — only the `WorkflowName`/`WorkflowId`, the awakeable-id
   and child-id helpers, the registry entry, the ordered structural body skeleton, and the
   operation wrappers (`runCommand`/projections, the `ReadModel` record, `signalAwakeable`,
   `runWorkflowWith`) — plus a create-if-absent hole module with one signature per step body
   and per author-chosen derivation.
4. **Harness pins behavior.** With the step bodies filled to match the captured
   `ReservationWorkflow.hs`/`EvacuationWorkflow.hs`, `cabal test keiro-dsl` is green. The
   harness asserts: a body re-run from its journal yields an identical result and re-runs no
   replayed side effect (replay determinism); each `await`'s `deterministicAwakeableId` equals
   its `signal` operation's derived id (the coupling); and each step/await/child result type
   round-trips through JSON (`decode . encode == id`).
5. **Mutation breaks a specific test.** Drifting one side of an await↔signal label,
   re-scaffolding, and running the suite turns the `harness/hospital-reservation/await-signal`
   example **red** (and only that family); changing a step result type reddens
   `harness/hospital-reservation/codec`. Restoring the spec returns the suite to green. This
   demonstrates the spec→behavior link is load-bearing rather than cosmetic.

Acceptance is behavioral throughout: each item is a command with an observable pass/fail, not an
internal attribute. The conformance targets are the real, external
`HospitalCapacity/ReservationWorkflow.hs` and `IncidentCommand/EvacuationWorkflow.hs` plus the
reservation command/query/signal operations; passing them is the proof the vertical is faithful
to the `Keiro.Workflow` and `Keiro.Command`/`Keiro.ReadModel` primitives.


## Idempotence and Recovery

Every step in this plan is safe to repeat.

- **`parse` and `check`** are pure reads of a `.kdsl` file and produce no side effects; run them
  as often as you like.
- **`scaffold`** is idempotent by construction (the EP-1 discipline this plan inherits):
  `Generated` modules are overwritten verbatim on every run, so re-scaffolding after a spec edit
  simply refreshes the workflow/operation wiring and the body skeleton; `HoleStub` modules
  (the step bodies) are created **only if absent**, so filled bodies are never clobbered. To
  force a clean regen of a hole module, delete it and re-scaffold. Scaffolding into a fresh
  `--out` directory (as the steps do, using `/tmp/...`) never touches the working tree.
- **The captured fixtures** under `keiro-dsl/test/fixtures/hospital-reservation/` and
  `…/incident-evacuation/` are read-only copies of external corpus files; re-copying them is
  harmless. If a fixture drifts from the corpus, re-copy from
  `/Users/shinzui/Keikaku/bokuno/keiro-runtime-jitsurei/services/hospital-capacity/src/HospitalCapacity/`
  and `…/services/incident-command/src/IncidentCommand/`.
- **The mutation test** edits the spec in place; the step takes a `.bak` and restores it, so the
  working tree returns to its prior state. If interrupted mid-mutation, restore with
  `git checkout -- keiro-dsl/test/fixtures/hospital-reservation/hospital-reservation.kdsl`.

This plan adds no migrations, touches no database, and modifies no runtime package, so there is
nothing destructive to roll back. The only durable artifacts are new `keiro-dsl` source modules
and test fixtures; all are additive and revertible with ordinary `git` operations.

A note on the *runtime* idempotence this DSL encodes (not a step you run here, but the property
the generated code preserves): the workflow journal makes every `step` a hit/miss replay, so a
re-invocation short-circuits completed checkpoints and never repeats a side effect
(`Workflow.hs:467-497`); the awakeable, sleep, and child ids are all **deterministic** v5 UUIDs
(`Awakeable.hs:131-137`, `Sleep.hs:165-178`, `Child.hs:123-130`) so an arming action re-run on
every resume collapses to a no-op and a separate signal operation reproduces the exact id; and
`signalAwakeable` is itself idempotent and crash-safe (a double signal returns `False` and
re-appends the journal entry from the stored payload, `Awakeable.hs:225-268`). The validator's
deterministic-id, unique-name, and await↔signal-coupling rules exist precisely to keep these
properties intact in scaffolded services.


## Interfaces and Dependencies

### Runtime primitives this plan binds to (the bijection targets)

- `Keiro.Workflow` (`keiro/src/Keiro/Workflow.hs`) — the authoring surface `step :: (Workflow
  :> es, ToJSON a, FromJSON a) => StepName -> Eff es a -> Eff es a` (`:179`), `awaitStep`
  (`:191`), `currentWorkflow` (`:195`); the runners `runWorkflow` (`:358`) / `runWorkflowWith ::
  WorkflowRunOptions -> WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es
  (WorkflowOutcome a)` (`:376`); `WorkflowRunOptions`/`defaultWorkflowRunOptions` (`:263-294`,
  Hole 8); and `WorkflowError (WorkflowStepDecodeError …)` (`:303-308`). The `workflow` node
  scaffolds onto these.
- `Keiro.Workflow.Types` (`keiro/src/Keiro/Workflow/Types.hs`) — `WorkflowName`/`WorkflowId`/
  `StepName` (`:63-83`), `workflowStreamName` (`:101-103`), and `WorkflowOutcome (Completed |
  Suspended | Cancelled | ContinuedAsNew)` (`:254-266`, the run op's Hole 2 disposition target).
- `Keiro.Workflow.Awakeable` (`keiro/src/Keiro/Workflow/Awakeable.hs`) — `awakeableNamed ::
  StepName -> Eff es (AwakeableId, Eff es a)` (`:168`), `deterministicAwakeableId :: WorkflowName
  -> WorkflowId -> Text -> AwakeableId` (`:131-137`, the id both the workflow and the signal op
  derive), and `signalAwakeable :: AwakeableId -> r -> Eff es Bool` (`:240`, the signal op
  target).
- `Keiro.Workflow.Sleep` (`keiro/src/Keiro/Workflow/Sleep.hs`) — `sleepNamed :: StepName ->
  NominalDiffTime -> Eff es ()` (`:209`); only the named form is used (the ordinal `sleep` at
  `:235` is forbidden).
- `Keiro.Workflow.Child` (`keiro/src/Keiro/Workflow/Child.hs`) — `spawnChild :: WorkflowName ->
  WorkflowId -> Eff (Workflow : es) a -> Eff es (ChildHandle a)` (`:158`) and `awaitChild ::
  ChildHandle a -> Eff es a` (`:194`), plus `childSpawnStepName` (`:123-130`). The child must be
  registered (Hole 5) and its id distinct (Hole 1).
- `Keiro.Workflow.Resume` (`keiro/src/Keiro/Workflow/Resume.hs`) — `WorkflowDef` /
  `WorkflowRegistry` (`:48-70`); the scaffolder emits a registry entry per declared workflow
  and per child.
- `Keiro.Command` (`keiro/src/Keiro/Command.hs`) — `runCommand` (`:355`), `runCommandWithSql`
  (`:400`), `runCommandWithSqlEvents` (`:420`), `RunCommandOptions`/`defaultRunCommandOptions`
  (`:134-170`, Hole 8), `CommandResult`/`CommandError` (`:95-121`). The command op scaffolds onto
  these (via the corpus's `runCommandWithProjections` convenience).
- `Keiro.ReadModel` (`keiro/src/Keiro/ReadModel.hs`) — `ReadModel { name, tableName,
  subscriptionName, version, shapeHash, defaultConsistency, query }` (`:72-92`), `ConsistencyMode
  (Strong | Eventual | PositionWait PositionWaitOptions)` (`:88-92`),
  `PositionWaitOptions { target :: Maybe GlobalPosition, … }` (`:101-106`), `runQuery` (`:128`) /
  `runQueryWith` (`:141`). The query op scaffolds the `ReadModel` record (SQL `query` is a hole)
  and the `runQuery` wrapper.

### Shared `keiro-dsl` engine modules this plan extends (additively)

- `Keiro.Dsl.Grammar` (`keiro-dsl/src/Keiro/Dsl/Grammar.hs`) — **add** `Workflow !WorkflowNode`
  and `Operation !OperationNode` to the node AST, plus `WorkflowNode`, `BodyItem` (`StepItem`/
  `AwaitItem`/`SleepItem`/`ChildItem`) and the `StepDecl`/`AwaitDecl`/`SleepDecl`/`ChildDecl`
  records, `IdDerivation`, `OperationNode`, `OperationShape` (`CommandOp`/`QueryOp`/`SignalOp`/
  `RunOp`) and the `CommandOpDecl`/`QueryOpDecl`/`SignalOpDecl`/`RunOpDecl` records,
  `Consistency`/`ConsistencyMode`/`PositionTarget`, `ProjectionRef`, `ReadModelRef`. The
  `SleepDecl.sleepDelta` and the various id derivations reuse EP-1's `Expr`; `SleepDecl` is
  structurally a duration datum with no clock constructor.
- `Keiro.Dsl.Parser` (`keiro-dsl/src/Keiro/Dsl/Parser.hs`) — **add** `pWorkflow :: Parser
  WorkflowNode`, `pOperation :: Parser OperationNode`, register in `pNode`; the body parser
  reads ordered checkpoint lines and rejects the ordinal `sleep`/`awakeable` forms at parse
  time. Signature unchanged: `parseSpec :: FilePath -> Text -> Either ParseError Spec`.
- `Keiro.Dsl.PrettyPrint` (`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`) — **add**
  `prettyWorkflow`/`prettyOperation`; round-trip preserved (including body order).
- `Keiro.Dsl.Validate` (`keiro-dsl/src/Keiro/Dsl/Validate.hs`) — **add** the rules named in
  *Context* (`ruleNoClockOrRandomOutsideStep`, `ruleSleepDeadlineInjected`,
  `ruleUniqueJournalNames`, `ruleAwaitHasSignal`, `ruleSignalMatchesAwait`,
  `ruleChildResolvesAndRegistered`, `ruleChildIdDistinct`, `ruleStepResultHasCodec`,
  `ruleStableIdentifiers`, `ruleCommandStreamAndProjections`, `ruleConsistencyOverride`) to the
  `validateSpec :: Spec -> [Diagnostic]` rule set.
- `Keiro.Dsl.Scaffold` (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`) — **add** `scaffoldWorkflow ::
  WorkflowNode -> [ScaffoldModule]` and `scaffoldOperation :: OperationNode -> [ScaffoldModule]`,
  each emitting `Generated` wiring (+ the structural body skeleton for a workflow) and a
  `HoleStub` step-body module, using `ScaffoldModule { modulePath, moduleText, kind }` and
  `ModuleKind = Generated | HoleStub`. Must satisfy the firewall invariant.
- `Keiro.Dsl.Harness` (`keiro-dsl/src/Keiro/Dsl/Harness.hs`) — **add** `harnessWorkflow ::
  WorkflowNode -> ScaffoldModule` and `harnessOperation :: OperationNode -> ScaffoldModule`
  emitting the replay-determinism, await↔signal id-match, and golden-codec assertions.
- The CLI (`keiro-dsl/app/Main.hs`) — no new subcommands; `parse`/`check`/`scaffold` pick up the
  new nodes via the shared engine.

### Per-milestone interface checkpoints

- **End of M1:** `Keiro.Dsl.Grammar` exports `WorkflowNode`/`OperationNode` (and the body-item /
  operation-shape / consistency types); `Keiro.Dsl.Parser.parseSpec` parses a `workflow` block
  and all four operation forms; pretty-print round-trips with body order preserved.
- **End of M2:** `validateSpec` includes the eleven new rules; `check` exits non-zero on each
  mutated spec and clean on the corpus spec.
- **End of M3:** `scaffoldWorkflow`/`scaffoldOperation` return `[ScaffoldModule]` with the
  `Generated` wiring (+ structural body skeleton) and a `HoleStub` step-body module; firewall
  test green; the body skeleton contains no step-body logic.
- **End of M4:** `harnessWorkflow`/`harnessOperation` return a `ScaffoldModule`; the emitted
  harness compiles and passes against filled holes.
- **End of M5:** fixtures captured under `keiro-dsl/test/fixtures/hospital-reservation/` and
  `…/incident-evacuation/`; full `cabal test keiro-dsl` green; mutation reddens
  `harness/hospital-reservation/await-signal` (and a type change reddens `…/codec`).

### External library dependencies

No new third-party dependencies beyond those EP-1 already introduces to `keiro-dsl`
(megaparsec for parsing, optparse-applicative for the CLI, prettyprinter for rendering). This
plan reuses keiro's existing `aeson`, `time`, and `uuid` deps (already in the runtime packages)
only indirectly, by *emitting* code that imports them — `keiro-dsl` itself does not link the
runtime. The conformance fixtures depend on the external `keiro-runtime-jitsurei` corpus only
as read-only captured copies, not as a build dependency.
