---
id: 61
slug: keiro-dsl-process-manager-and-durable-timer-nodes
title: "keiro-dsl process manager and durable timer nodes"
kind: exec-plan
created_at: 2026-06-10T01:05:27Z
intention: "intention_01ktqdn85xe2btqzr2zghxgrpr"
master_plan: "docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md"
---

# keiro-dsl process manager and durable timer nodes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A **keiro service** is a bounded context built on event sourcing. Two of its hardest node
types to hand-write correctly are the **process manager** (a "saga": a small state machine
that reacts to an incoming event by advancing its own private event stream *and*
dispatching commands to other aggregates *and* scheduling timers, all in one crash-safe
turn) and the **durable timer** (a row in a database table that a background worker wakes
up at a future time to fire an action — a deadline, a retry delay, a timeout). These are
exactly where the most dangerous, easy-to-get-wrong decisions live: inverted error
semantics (a rejected command that actually means "success, already done"), runtime-owned
ids that must not be hand-supplied, and a default timer policy that silently retries
forever.

`keiro-dsl` is a toolchain over a **typed specification** of a keiro service — a plain-text
file with extension `.kdsl` written in a terse, readable notation, which is the permanent,
machine-checkable source of truth for the service. The foundation (parser, validator,
scaffolder, harness, CLI) and the `aggregate` node are built by **EP-1**
(`docs/plans/59-keiro-dsl-foundations-grammar-parser-validator-scaffold-and-harness-engine-aggregate-vertical.md`),
which this plan hard-depends on. This plan, **EP-3** of the MasterPlan
`docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md`, adds two node types on
top of that foundation: `process` (process manager) and `timer` (durable timer).

After this plan, a developer (or a coding agent planning a feature) can write a `process`
block plus a nested `timer` block in a `.kdsl` file, then:

1. Run `keiro-dsl check service.kdsl` and have the tool **reject the spec** — with a
   precise, line-numbered diagnostic, *before any Haskell is written* — if the timer
   deadline samples the wall clock instead of an injected timestamp, if a dispatched
   command supplies its own id (which must be runtime-owned), if any dispatch or timer-fire
   omits a complete error-disposition table, if `max-attempts`/`dead-letter` is absent (the
   dangerous "retry forever" default), or if a deterministic fired-event-id or timer-id is
   missing.
2. Run `keiro-dsl scaffold service.kdsl --out <dir>` and get the **symbol-free
   deterministic layer** for the process manager and timer — the `ProcessManager` record
   wiring whose fields are derivable, the `TimerRequest` builder, the timer-worker
   skeleton, the codecs and stream handles — emitted into `-- @generated` modules, plus
   precisely-typed **holes** (created only if absent) for the behavior-bearing bodies: the
   `handle` reaction, the timer `fire` action, the deadline window, and the id
   derivations. A spec-derived **harness** then pins the filled behavior.
3. Fill the holes (by hand or with a coding agent) against the generated signatures, and
   run the harness to confirm the behavior matches the spec.

The user-visible proof at the end of this plan: take the real, hand-written hospital-surge
process manager captured from the external corpus
(`keiro-runtime-jitsurei/services/hospital-capacity/src/HospitalCapacity/SurgeManager.hs`
and its own aggregate `Surge/Transducer.hs`), check it, scaffold it, hand-fill the holes to
match the captured reference, and show (a) the `-- @generated` modules compile, (b) the
tested **firewall invariant** holds — *no `-- @generated` line ever contains a keiki
symbolic operator* (`B.slot`, `B.requireGuard`, `=:`, `./=`, `lit`, …) — and (c) the
emitted harness goes **green**, while a mutation (e.g. flipping the `on-reject` timer-fire
disposition from `Fired` to `Retry`, or dropping the `max-attempts` ceiling) turns a
**specific** harness test **red**.

The single most important scope boundary, repeated because everything depends on it:
**keiro-dsl does not emit the symbolic transducer logic, and it does not emit the
behavior-bearing handler/fire bodies.** A `process`/`timer` spec is a *typed spec*; the
scaffolder emits only the symbol-free deterministic wiring plus typed holes. The
`handle` reaction body, the timer `fire` action body, the deadline window function, and
the id derivations are agent-written holes pinned by the harness. A tested firewall
invariant guarantees the generated layer never contains a keiki symbolic operator.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — Grammar + parser for `process`/`timer`: **DONE 2026-06-10**

- [x] Add `NProcess`/`ProcessNode` + nested `TimerNode` (and `InputDecl`, `CorrelateDecl`, `SagaRef`, `HandleNode`, `AdvanceNode`, `DispatchNode`, `DispatchDisposition`/`Disp`, `FireNode`, `FireDisposition`/`FireOutcome`, `IdExpr`/`IdStrategy`, `FireAtExpr`, `FieldBinding`) to `Keiro.Dsl.Grammar`. (2026-06-10)
- [x] Extend `Keiro.Dsl.Parser` with `pProcess`/`pTimerNode` wired into the top-level node parser; the `dispatch-id` line is a fixed `strategy=uuidv5` form (parsed and discarded; the AST has no user-id field). (2026-06-10)
- [x] Extend `Keiro.Dsl.PrettyPrint` so a parsed `process`/`timer` round-trips. (2026-06-10)
- [x] `keiro-dsl parse hospital-surge.kdsl` echoes the process + nested timer byte-identically; round-trip + shape unit tests green. (2026-06-10)

Milestone 2 — Validator rules: **DONE 2026-06-10**

- [x] Implement `validateProcess` rules in `Keiro.Dsl.Validate`: `ProcessFireAtNotInjected` (fireAt field must be a declared `:Time` input field — TIME IS INJECTED), `ProcessDispatchIdSupplied` (no `commandId`/`id` binding on a dispatch or fire), `ProcessUnresolvedRef` (saga/target/fire-target resolve to declared aggregates), and `ProcessBenignInversion` *warnings* surfacing `on-reject => Fired` / `on-duplicate => AckOk`. The mandatory `max-attempts`/`dead-letter`, complete disposition tables, deterministic ids, and decode-strictness ack are enforced by the grammar/parser (their absence is a parse error). (2026-06-10)
- [x] `keiro-dsl check` now exits non-zero only on *errors* (warnings pass): the hospital-surge spec passes clean (exit 0, two benign-inversion warnings); the clock/dispatch-id/bad-ref mutated fixtures each fail with the expected `error[Process…]`. Unit tests via `errorCodesOf`. (2026-06-10)

Milestone 3 — Scaffold emitters: **DONE 2026-06-10**

- [x] `scaffoldProcess` emits a `-- @generated` `Process` module with the derivable wiring: the define-once process name, the `TimerRequest` builder (deterministic id from the correlation key, processManagerName, payload, fireAt), the timer-fire disposition table (derived from the spec, `on-reject => Fired` benign inversion), and the `max-attempts`/`dead-letter` ceiling (never `defaultTimerWorkerOptions`). (2026-06-10)
- [x] Emit the create-if-absent `ProcessHoles` module documenting the holes: the `handle` reaction, the deadline window (TIME INJECTED), the fire command, and the deterministic ids. (2026-06-10)
- [x] Firewall + determinism tests pass for the process scaffold; the CLI emits the process modules alongside the saga/target aggregate scaffolds and the firewall holds across all Generated modules. (Full ProcessManager compilation is M5 conformance.) (2026-06-10)

Milestone 4 — Harness emission: **DONE 2026-06-10**

- [x] `harnessProcess` emits a self-contained, firewall-clean `ProcessHarness` Generated module exporting the spec's deterministic decisions (time-injection field, deterministic timer-id/fired-event-id prefixes, runtime-owned dispatch-id, the dispatch/fire disposition tables, the max-attempts ceiling) as plain values. The `keiro-dsl-conformance-process` suite compiles + runs it (7/7 green). (2026-06-10)

Milestone 5 — Conformance vs `SurgeManager`: **PARTIAL 2026-06-10** (spec→behaviour pin delivered; full-corpus source compilation deferred)

- [x] Author `hospital-surge.kdsl` (+ minimal Surge/Hospital aggregate decls); `check` passes clean (benign-inversion warnings only). (2026-06-10)
- [x] Mutation test (`keiro-dsl/test/process-mutation-test.sh`): flipping the timer-fire `on-reject` from `Fired` to `Retry` in the spec, re-scaffolding, turns the *specific* `onReject` assertion red against the hand-written expectation in `test/conformance-process/Main.hs`; restoring returns to green. This is the headline spec→behaviour pin. (2026-06-10)
- [ ] **Deferred:** capturing the external `SurgeManager.hs` + `Surge/Transducer.hs` and compiling the runtime-coupled Generated `Process` module against the full effectful/hasql/kiroku stack (a much heavier integration than the aggregate codec). The aggregate-level compilation conformance is already proven in EP-1; the process facts harness + mutation pin demonstrate the spec→behaviour link without it.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **M2: `check` had to stop failing on warnings.** The process validator surfaces the benign
  inversions (`on-reject => Fired`, `on-duplicate => AckOk`) as *warnings*, but the EP-1
  `check` CLI exited non-zero on any diagnostic. Fixed to exit non-zero only when a
  diagnostic has `severity == Error`, so a valid process spec passes clean (exit 0) while
  still printing its warnings. Evidence: `check hospital-surge.kdsl` → exit 0 with two
  warnings.

- **M4: a generated facts harness is circular unless the expectation is hand-written.** The
  first process harness compared spec-derived values against spec-derived literals — both
  regenerated from the spec, so flipping `on-reject` in the spec changed *both* and the test
  still passed (the mutation slipped through). Fixed by having the Generated `ProcessHarness`
  module export the raw values and the *hand-written* conformance `Main` hold the expected
  values; now a spec change diverges from the committed expectation and reddens exactly the
  affected assertion. Evidence: `process-mutation-test.sh` — flipping `on-reject Fired`→
  `Retry` turns only `onReject` red. (Lesson echoing EP-1 M4: a behaviour pin is only as
  good as having an independent reference to pin against.)

- **M5 scope: the runtime-coupled process scaffold is much heavier to compile than the
  aggregate codec.** The aggregate Generated layer compiles against base/text/aeson/keiki/
  keiro-core; the `ProcessManager` wiring pulls in effectful, hasql-transaction,
  kiroku-store, and both the saga and target aggregates. Full source-level compilation of
  the captured `SurgeManager.hs` is therefore deferred; the deterministic spec→behaviour
  decisions are pinned by the self-contained facts harness + mutation test instead.


## Decision Log

Record every decision made while working on the plan.

- Decision: A `process` node owns two distinct aggregate references — its own saga
  aggregate (`saga`) and the foreign aggregate it drives (`target`) — and contains the
  `timer` as a nested sub-node, rather than the timer being a sibling top-level node.
  Rationale: the corpus
  (`keiro-runtime-jitsurei/.../SurgeManager.hs`) ties the timer's `processManagerName`,
  `correlationId`, and fired-event-id derivation to the owning process manager; nesting
  keeps that coupling local and lets the validator resolve cross-references without a
  global lookup. The audit's LEAK-G/LEAK-K (`surgemanager-slice-proof.md`) independently
  reached the same shape. Date: 2026-06-10
- Decision: The dispatched-command id is surfaced as a fixed, non-editable strategy
  (`dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId, emitIndex)`),
  and the grammar provides **no** way to supply a per-command id.
  Rationale: `runProcessManagerOnce` derives every write id via
  `deterministicCommandId name correlationId sourceEventId emitIndex`
  (`keiro/src/Keiro/ProcessManager.hs:166-180`, dispatch at `:256-259`); a user-supplied id
  would defeat the crash-safe idempotency the manager relies on. The corpus literally
  passes a `placeholderCommandId` that the runtime overwrites (`SurgeManager.hs:195`), so
  the field is vestigial and must not be exposed. Date: 2026-06-10
- Decision: Every dispatch and every timer-fire requires a **complete** disposition table,
  and the validator forces the author to confront the benign inversions explicitly rather
  than defaulting them.
  Rationale: the corpus timer-fire maps `Left CommandRejected -> Fired` (a *benign success*)
  and `Left _ -> Nothing` (retry) (`SurgeManager.hs:235-238`), and the process manager
  treats `PMCommandFailed` as fatal while `PMCommandDuplicate` is benign
  (`ProcessManager.hs:131,135,276-277`). An author who guesses these wrong produces a
  worker that wedges or a timer that never acks. Forcing the table makes the dangerous
  decision loud. Date: 2026-06-10
- Decision: `max-attempts N dead-letter "<reason>"` is **mandatory** on every timer; an
  absent ceiling is a `check` error, not a silent default.
  Rationale: `defaultTimerWorkerOptions` sets `maxAttempts = Nothing`, which *never*
  auto-dead-letters (`keiro/src/Keiro/Timer.hs:72-74`); both corpus workers take this
  default and a stuck timer ping-pongs forever. The DSL forces the dangerous default OFF.
  Date: 2026-06-10
- Decision: Multi-source sum-typed input fan-in, conditional dispatch, payload-driven fire
  field binding, timer-fires-into-wrong-saga-state coupling, the shared `keiro_timers`
  partition-by-name, opaque captured-fixture ids, and the stuck-timer reaper are recorded
  as known limitations / grammar TODOs, not implemented in this plan.
  Rationale: this plan's conformance target is the single-source `SurgeManager`; the
  escalation/fulfillment processes (`jitsurei/src/Jitsurei/{EscalationProcess,FulfillmentProcess}.hs`)
  exercise those gaps and are deferred to keep EP-3 independently verifiable. Date: 2026-06-10


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
`/Users/shinzui/Keikaku/bokuno/keiro-runtime-jitsurei` (not part of this Cabal project).
Its hospital-capacity service holds the rich process-manager + timer example this plan
conforms against. There are also two simpler, in-repo process managers under
`jitsurei/src/Jitsurei/` (`EscalationProcess.hs`, `FulfillmentProcess.hs`, `Timers.hs`)
used to scope out coverage gaps. Per the MasterPlan's corpus decision, conformance fixtures
are captured **read-only** under `keiro-dsl/test/fixtures/`.

### Terms of art (plain language)

- **Aggregate.** An event-sourced entity: a state machine whose transitions emit events
  appended to a per-entity *event stream*. In keiro it is an `EventStream` value plus a
  *transducer* (the symbolic state machine). EP-1 defines the `aggregate` node and its
  scaffold; this plan reuses that machinery for the saga's own state.
- **Process manager (saga).** A *stateful* coordinator. It reacts to an incoming event by
  (1) advancing its own private event stream, (2) dispatching commands to *target*
  aggregates, and (3) scheduling timers — atomically and crash-safely. The runtime type is
  `Keiro.ProcessManager.ProcessManager` (`keiro/src/Keiro/ProcessManager.hs:91-102`).
- **Durable timer.** A row in the `keiro_timers` table scheduled to become due at a future
  time, claimed and fired by a background worker. Runtime: `Keiro.Timer`
  (`keiro/src/Keiro/Timer.hs`, `keiro/src/Keiro/Timer/{Schema,Types}.hs`).
- **Correlation id.** A `Text` key identifying *which instance* of the saga handles an
  input. It is load-bearing identity: it keys the manager's own stream, the timer rows,
  the dedup ids, and the timer worker's routing back to the saga.
- **Disposition.** The decision of what to do with a command/timer-fire *outcome*: ack as
  success, retry, or dead-letter. The danger is that some outcomes that look like failure
  are actually benign success.
- **Hole.** A precisely-typed gap the scaffolder leaves for a human/agent to fill (e.g. the
  `handle` body). Holes live in create-if-absent modules; generated wiring lives in
  overwrite-on-scaffold `-- @generated` modules.
- **Firewall invariant.** The tested guarantee that **no `-- @generated` line contains a
  keiki symbolic operator** (`B.slot`, `B.requireGuard`, `=:`, `./=`, `.==`, `.||`, `lit`).
  The brittle symbolic logic is always a hole, never generated.
- **TIME IS INJECTED NOT SAMPLED (cross-cutting rule).** A timer's deadline must be
  computed from a timestamp *carried in the input event*, never from sampling the wall
  clock (`getCurrentTime`). In the corpus, `surgeDeadline = addUTCTime surgeWindow
  observedAt` where `observedAt` is a field of `SurgeInput`
  (`SurgeManager.hs:241-246,147`). This keeps reactions deterministic and replay-safe.

### Shared EP-1 signatures this plan relies on (restated)

EP-1 defines the shared engine. This plan extends it; the signatures below are the contract
this plan codes against. (EP-1's plan file currently carries these as its own
deliverables — referenced here by path, restated here so this plan is self-contained.)

- `Keiro.Dsl.Grammar` — the abstract syntax. EP-1 provides a `Spec` record aggregating all
  nodes, the shared declarations (`IdDecl`, `EnumDecl`, `RuleDecl`), the eight hole types,
  the `Aggregate` node constructor, and an `Expr` sublanguage (a small expression grammar
  for field references, string splices `<>`, and id derivations — e.g. `input.hospitalId`,
  `"hospital-surge-" <> correlationId`). This plan adds `Process` and `Timer` constructors
  and the disposition/strategy/window types.
- `Keiro.Dsl.Parser` — `parseSpec :: FilePath -> Text -> Either ParseError Spec`, a
  megaparsec parser. This plan adds `pProcess`/`pTimer` and wires them into the node parser.
- `Keiro.Dsl.PrettyPrint` — a prettyprinter renderer such that parse-then-print round-trips.
- `Keiro.Dsl.Validate` — `validateSpec :: Spec -> [Diagnostic]`, where a `Diagnostic`
  carries a severity, a source span (line/column), and a message. EP-1 provides the
  cross-cutting rules (reachability, the time-injected-not-sampled check, `Expr`
  scope-checking, and the eight hole-kind presence checks). This plan adds the
  process/timer-specific rules listed under *Validator rules* below. `keiro-dsl check`
  prints diagnostics and exits non-zero if any are errors.
- `Keiro.Dsl.Scaffold` — `ScaffoldModule { modulePath :: FilePath, moduleText :: Text,
  kind :: ModuleKind }` and `data ModuleKind = Generated | HoleStub`. A `Generated` module
  is overwritten on every scaffold; a `HoleStub` is created only if absent (so hand edits
  survive re-scaffolding). EP-1 provides the firewall-invariant test asserting no
  `Generated` `moduleText` contains a keiki symbolic operator. This plan adds the
  process/timer emitters.
- `Keiro.Dsl.Harness` — the emitter producing test modules modeled on the corpus's
  `keiro-runtime-jitsurei/services/hospital-capacity/test/{IdentitySpec,SymbolicSpec}.hs`,
  asserting the spec's pinned behavior. This plan adds process/timer harness emission.
- The CLI (`keiro-dsl/app/Main.hs`) — an optparse-applicative tree with `parse`, `check`,
  `scaffold`. This plan adds no subcommands; it extends what they emit/validate.

### The eight hole-kinds (the closed set of non-derivable decisions)

Every non-template decision in a keiro service collapses into one of eight hole-kinds. This
plan's `process`/`timer` nodes exercise all eight; naming them keeps the validator's
required-decision checks systematic:

1. **Derivation** — a deterministic id-from-key function (e.g. `surgeTimerId(hospitalId)`).
2. **Disposition** — the `AckOk | Retry n | DeadLetter reason` decision, *with the
   dangerous inversions* (a rejection that means success).
3. **Mapping** — a pure transform (e.g. input fields → a command; `Severity → window`).
4. **Field-source / envelope-binding** — which input/envelope field feeds which slot.
5. **Cross-node coupling** — a reference from one node to a declared other (saga ↔ target ↔
   projections ↔ name).
6. **Decode strictness** — what an unknown/missing wire value decodes to.
7. **Optionality** — an explicit empty (`[]` projections = append-only; `[]` dispatch).
8. **Runtime config** — knobs delegated to the runtime worker (page size, reaper cadence).

### The bijection (DSL node → keiro primitive)

A `keiro-dsl` node is faithful only if it maps onto a named keiro primitive. The two new
nodes this plan adds map as follows:

- `process` → `Keiro.ProcessManager.ProcessManager` (the 10-field record) **plus** the
  timer scheduling done inside the manager's append transaction via
  `Keiro.Timer.scheduleTimerTx`.
- `timer` → `Keiro.Timer` (the schedule / claim / fire / cancel / dead-letter lifecycle),
  with at-least-once firing semantics.

The guards and register writes inside the saga's *own* aggregate reuse EP-1's `aggregate`
machinery unchanged (the corpus's `Surge/Transducer.hs` is a plain `aggregate` — Idle →
Requested → FollowedUp, no guards).

### The runtime primitives in detail (read these files to verify)

**`ProcessManager` is a 10-field record** (`keiro/src/Keiro/ProcessManager.hs:91-102`):
`name`, `correlate`, `eventStream` (the saga's own stream), `streamFor`,
`targetEventStream`, `targetProjections`, `handle`. Its `handle` returns a
`ProcessManagerAction { command, commands :: [PMCommand], timers :: [TimerRequest] }`
(`:110-115`) — the *triple*: one self-command advancing the saga, N dispatched target
commands, M timers. Field-by-field this plan maps it to hole-kinds:

- `name :: Text` — Hole 5 (cross-node coupling): a define-once identifier written into
  every timer row (`processManagerName`) and into every deterministic write id. The corpus:
  `hospitalSurgeProcessName = "hospital-surge"` (`SurgeManager.hs:165-166`). It must be
  *referenced*, never retyped, and it is **forbidden** inside the dispatch-id form.
- `correlate :: input -> Text` — Hole 1 (derivation) + Hole 4 (field-source). The corpus:
  `\input -> idText input.hospitalId` (`:172`). It is referenced by `streamFor`, the timer
  `correlationId`, and the dedup ids (LEAK-L).
- `eventStream` — the saga's own aggregate, a referenced `aggregate` node (Hole 5).
- `streamFor :: Text -> Stream …` — Hole 1: a suffix-splice of the correlation key, e.g.
  `stream ("hospital-surge-" <> idText hospitalId)` (`:81-82,174`).
- `targetEventStream` — the foreign aggregate driven by dispatch (Hole 5; `:175`).
- `targetProjections :: Stream targetCi -> [InlineProjection targetCo]` — Hole 7
  (optionality: `[]` means append-only) + Hole 5. Corpus:
  `const [hospitalReadinessProjection]` (`:176`).
- `handle` — Hole 3 (the self-command mapping), Hole 3+7 (the dispatch set, possibly empty),
  Hole 7 + the timer sub-node (the timers list).

**Dispatch ids are runtime-owned.** `deterministicCommandId name corr sourceEventId
emitIndex` derives a v5 UUID (`:166-180`). The manager-state append uses `emitIndex = -1`
(`:214`); dispatched commands use `0..` in order (`:256-259`). The corpus passes a
`placeholderCommandId` the runtime overwrites (`SurgeManager.hs:195`). The DSL **forbids** a
user-supplied per-command id and surfaces the strategy as fixed only.

**Benign-vs-fatal command results** (`:124-136,276-277`): `PMCommandAppended` = success;
`PMCommandDuplicate` = idempotent replay, **benign**; `PMCommandFailed` = treated as fatal,
the source event is retried (and the worker wedges if a *benign* target rejection surfaces
as a hard `CommandError`). This is the dispatch disposition the validator must force the
author to confront.

**Timer lifecycle** (`keiro/src/Keiro/Timer/Schema.hs`): the `TimerStatus` lifecycle is
`Scheduled → Firing → Fired`, with off-ramps `Cancelled` and `Dead` (`:51-68`).
`scheduleTimerTx` inserts/re-arms inside the manager's append transaction, re-arming a
conflicting row **only while it is still `Scheduled`** (`:102-117,207-214`). `claimDueTimer`
atomically claims the earliest due timer with `FOR UPDATE SKIP LOCKED`, **incrementing
`attempts` before** the ceiling check (`:119-127,226-249`). The worker's `fire` action
returns `Just eventId` → `markTimerFired`, or `Nothing` → the timer is left `Firing` to be
retried (`keiro/src/Keiro/Timer.hs:93-131`). A crash that leaves a timer `Firing` makes it
claimable again — hence **at-least-once** firing, so **fire actions must be idempotent**
(use a deterministic fired-event-id).

**Deadline from injected time** (`SurgeManager.hs:241-246`): `surgeDeadline observedAt =
addUTCTime surgeWindow observedAt`, `surgeWindow = 5*60`, with `observedAt :: UTCTime`
carried in `SurgeInput` (`:147`) and never sampled. The escalation example instead maps the
window from a `Severity` (a Hole 3 mapping; `EscalationProcess.hs:296-300`).

**Timer id** is a v5 UUID of a prefixed correlation key (Hole 1 derivation):
`TimerId (namedUuid ("hospital-surge-timer:" <> idText hospitalId))` (`SurgeManager.hs:251`).
The in-repo `Jitsurei.Timers` uses a captured `TypeID` fixture instead (the opaque variant;
`Timers.hs:39-49`) — recorded as a known-limitation alternative.

### Three dangerous defaults this plan's validator must neutralize

1. **`maxAttempts = Nothing` never auto-dead-letters** (`keiro/src/Keiro/Timer.hs:72-74`).
   Both corpus workers take `defaultTimerWorkerOptions` (`runTimerWorker Nothing …`,
   `SurgeManager.hs:218`, `EscalationProcess.hs:335`), so a stuck timer ping-pongs forever.
   The validator requires explicit `max-attempts N dead-letter "<reason>"`, forcing the
   ceiling ON.
2. **Unknown stored `TimerStatus` decodes to `Cancelled`** — a silent terminal
   (`keiro/src/Keiro/Timer/Schema.hs:376-383`, the `_ -> Cancelled` fallthrough). The
   validator requires the author to acknowledge this decode-strictness choice (Hole 6).
3. **Timer-fire error inversion** (`SurgeManager.hs:235-238`): `Right{} -> Fired`,
   `Left CommandRejected -> Fired` (a **benign success**!), `Left _ -> Nothing` (retry).
   This is a Hole 2 table the spec must capture explicitly; defaulting it silently is the
   classic "timer that never acks / retries forever" bug.

### Proposed notation

A `process` node references its saga `aggregate`, its target `aggregate`, and contains a
nested `timer` sub-node. The dispatch-id is a *derived, non-editable* strategy. The timer
deadline is an injected-timestamp field plus a window. Worked example (the hospital-surge
manager):

```text
process HospitalSurge
  name "hospital-surge"                          # Hole 5: define-once; forbidden in dispatch-id
  input SurgeInput { hospitalId availableIcuBeds redDemand observedAt:Time }
  correlate input.hospitalId via idText          # Hole 1 (derivation) + Hole 4 (field-source)
  saga    Surge stream="hospital-surge-" <> correlationId   # Hole 1: suffix-splice of correlation key
  target  Hospital                               # Hole 5: foreign aggregate
  projections [ hospitalReadiness ]              # Hole 7: [] => append-only

  on SurgeInput                                  # the handle reaction (triple output)
    advance NoteSurgeThreshold { hospitalId availableIcuBeds redDemand timerId=timer.id }  # Hole 3
    dispatch Hospital@input.hospitalId ActivateSurge { hospitalId }   # Hole 3 mapping
      on-appended AckOk ; on-duplicate AckOk ; on-failed Retry        # Hole 2: dispatch disposition
    schedule surgeFollowUp

  dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId, emitIndex)  # DERIVED, not editable

  timer surgeFollowUp
    id     uuidv5 "hospital-surge-timer:" <> correlationId            # Hole 1 derivation (deterministic)
    fireAt input.observedAt + 5m                  # TIME INJECTED: addUTCTime window observedAt
    payload { kind="hospital-surge-follow-up" hospitalId }  # written, unread by worker (vestigial)
    fire dispatch Surge@correlationId MarkSurgeTimerFired { hospitalId timerId }   # into the OWN saga
      fired-event-id uuidv5 "hospital-surge-fired:" <> correlationId  # Hole 1: deterministic dedup id
      on-ok Fired ; on-reject Fired ; on-error Retry ; not-mine Retry # Hole 2: the inversion, explicit
    decode unknown-status => Cancelled            # Hole 6: ack the silent-terminal fallback
    max-attempts 5 dead-letter "surge timer exceeded ceiling"        # forces the dangerous default OFF
```

The `on-reject Fired` line is the load-bearing one: it states that a `CommandRejected` from
the saga (the command was already applied) is *benign success*, so the timer is marked
`Fired` rather than retried.

### Coverage gaps (recorded honestly as known limitations + grammar TODOs)

This plan's notation deliberately covers the *single-source* process manager. The following
are **not** expressible yet and are deferred (each is exercised by a corpus example that is
out of EP-3's conformance scope):

- **Multi-source sum-typed input fan-in.** The escalation process consumes *two*
  subscriptions and its input is a sum type (`EscalationInput = IncidentReported … |
  ResponderAcked …`, `EscalationProcess.hs:226-229`), needing multiple `on <Ctor>` arms,
  each with its own upstream stream and envelope binding. Grammar TODO.
- **Conditional dispatch.** The fulfillment process dispatches only on one input
  constructor (`case event of PaymentApproved{} -> [PMCommand …]; _ -> []`,
  `FulfillmentProcess.hs:132-139`). The notation above has no `when`/`case` guard on
  dispatch. Grammar TODO.
- **Timer-fires-into-wrong-saga-state coupling.** A fire that targets a saga state which
  cannot accept the command (relying on the aggregate's own guards to no-op) is a coupling
  the validator does not yet check.
- **The shared `keiro_timers` table is partitioned only by `processManagerName`.** Two
  processes sharing the table is implicit; not modeled.
- **Opaque captured-fixture ids.** The `TypeID`-fixture variant (`Timers.hs`) is not a
  first-class strategy yet — only `uuidv5` is.
- **Payload-driven fire field binding.** The corpus timer `payload` is written but unread
  (the worker keys off `TimerRow.correlationId`); binding fire fields *from* the payload is
  not modeled (flagged vestigial).
- **Stuck-timer reaper.** `requeueStuckTimer` / `findStuckTimers`
  (`keiro/src/Keiro/Timer/Schema.hs:157-178`) are delegated runtime config (Hole 8), not
  emitted by scaffold.

### Validator rules to implement (M-level, this plan's additions to `validateSpec`)

Each rule produces a line-numbered `Diagnostic` of error severity when violated:

- **No wall-clock sample.** A `timer.fireAt` must be `<injected-timestamp-field> + <window>`
  (lowering to `addUTCTime window injectedField`). Reject any reference to a clock-sampling
  primitive (`getCurrentTime`, `now`) inside `fireAt`. The injected field must be a declared
  `:Time` field of the process `input`.
- **Runtime-owned dispatch-id.** Reject any user-supplied id on a `dispatch` command; the
  only legal form is the fixed `dispatch-id strategy=uuidv5 from=(name, correlationId,
  sourceEventId, emitIndex)`. `name` must not be re-bound inside it.
- **Complete disposition table.** Every `dispatch` must cover `on-appended`/`on-duplicate`/
  `on-failed`; every timer `fire` must cover `on-ok`/`on-reject`/`on-error`/`not-mine`.
  A missing arm is an error. The author must write each arm explicitly (no defaulting), so
  the benign inversion (`on-reject Fired`) is a conscious decision.
- **Explicit `max-attempts` + `dead-letter`.** A timer without `max-attempts N dead-letter
  "<reason>"` is rejected — the absent-default must NOT silently map to `Nothing`.
- **Deterministic fired-event-id and timer-id.** Both must be present and derived
  (`uuidv5` of a correlation-keyed string). A missing or non-deterministic id is an error
  (at-least-once firing requires idempotence).
- **Cross-node coupling resolves.** `saga`, `target`, and each `projections` entry must
  resolve to declared nodes; `name` is referenced, not retyped; the timer's `fire dispatch`
  target must resolve to the `saga` or `target` aggregate.
- **Explicit optionality.** `projections [ … ]` and the dispatch set must be written
  explicitly, including `[]` for append-only / no-dispatch.
- **Decode-strictness ack.** The `decode unknown-status => Cancelled` line must be present,
  acknowledging the silent-terminal fallback (`Schema.hs:383`).


## Plan of Work

The work is five milestones, each independently verifiable. They follow the engine's data
flow: grammar+parser → validator → scaffold → harness → conformance. All edits are additive
to the shared `keiro-dsl` modules EP-1 created; this plan introduces no new runtime package
and touches no existing one.

### Milestone 1 — Grammar and parser for `process`/`timer`

Scope: make a `process` block (with its nested `timer`) a first-class part of the AST and a
parseable, round-trippable part of the notation. At the end, `keiro-dsl parse` accepts a
`.kdsl` containing a `process` and prints it back out identically.

Edits:

- In `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, add to the node sum a `Process !ProcessNode`
  constructor and define the records. `ProcessNode` carries: `procName :: Text` (the
  define-once `name`), `procInput :: InputDecl` (a named record of typed fields, one of
  which is a `:Time` field), `procCorrelate :: CorrelateDecl` (field-source + derivation
  rule), `procSaga :: SagaRef` (the own-aggregate name + the `streamFor` suffix-splice
  `Expr`), `procTarget :: AggRef`, `procProjections :: [ProjectionRef]` (Hole 7, possibly
  empty), `procHandle :: HandleNode`, `procDispatchId :: DispatchIdStrategy` (a *closed*
  type with a single inhabitant — `UuidV5FromManagerTuple` — so there is no field for a
  user id), and `procTimer :: TimerNode`. `HandleNode` carries the self-command mapping
  (`advance`), the dispatch list (each a `DispatchNode` with target ref, command mapping,
  and a `Disposition` table), and the `schedule` reference to the timer. Define
  `data Disposition = Disposition { onAppended :: Disp, onDuplicate :: Disp, onFailed ::
  Disp }` and `data Disp = AckOk | Retry Int | DeadLetter Text`. Define `TimerNode { timerId
  :: IdExpr, fireAt :: FireAtExpr, payload :: PayloadExpr, fire :: FireNode, decodeUnknown
  :: TimerStatusLit, maxAttempts :: Int, deadLetterReason :: Text }` where `FireAtExpr` is
  structurally `<inputTimeField> + <window>` (so the no-wall-clock rule is *representable*
  by construction — there is no constructor that samples a clock). `FireNode` carries the
  fire target ref + command mapping, the deterministic `firedEventId :: IdExpr`, and a
  `FireDisposition { onOk, onReject, onError, notMine :: FireOutcome }` where
  `data FireOutcome = Fired | Retry`.
- In `keiro-dsl/src/Keiro/Dsl/Parser.hs`, add `pProcess :: Parser ProcessNode` and
  `pTimer :: Parser TimerNode`, and register `pProcess` in the top-level node parser
  (`pNode`). The `dispatch-id` line parses to the single `DispatchIdStrategy` inhabitant and
  *errors at parse time* if a user attempts to add an id field. Reuse EP-1's `Expr` parser
  for the `streamFor`, `id`, `fired-event-id`, and `fireAt` expressions.
- In `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`, add `prettyProcess`/`prettyTimer` so that
  `parse` then pretty-print is idempotent on a `process`-bearing spec.

Acceptance: `cabal run keiro-dsl -- parse keiro-dsl/test/fixtures/hospital-surge/hospital-surge.kdsl`
prints a model that, re-parsed, equals the first (round-trip test green).

### Milestone 2 — Validator rules

Scope: turn the *Validator rules to implement* list (Context) into code, so `keiro-dsl
check` rejects every dangerous omission. At the end, a deliberately-broken spec fails with a
precise diagnostic and the corpus spec passes clean.

Edits, all in `keiro-dsl/src/Keiro/Dsl/Validate.hs`, added to the `validateSpec` rule set:

- `ruleNoWallClock` — the `fireAt`'s injected field must be a declared `:Time` field of the
  process `input`; because `FireAtExpr` has no clock-sampling constructor this is mostly a
  field-resolution check, but it also rejects a `fireAt` that references no input field.
- `ruleRuntimeOwnedDispatchId` — the dispatch-id must be the single legal strategy and
  `name` must not be re-bound inside it (defensive; the parser already forbids a user id).
- `ruleCompleteDispatchDisposition` and `ruleCompleteFireDisposition` — every arm present.
  Because the records are total, this rule's real job is to **surface** the benign
  inversion: emit an *informational* diagnostic naming `on-reject Fired` / `on-duplicate
  AckOk` as the dangerous-by-default decisions the author has confirmed.
- `ruleExplicitMaxAttempts` — error if `maxAttempts`/`deadLetterReason` absent. (Represented
  as `Maybe` in the parse tree before validation; validation rejects `Nothing`.)
- `ruleDeterministicIds` — `timerId` and `firedEventId` must be `uuidv5`-strategy
  derivations over a correlation-keyed string.
- `ruleCrossNodeCoupling` — `saga`/`target`/`projections` and the fire target resolve to
  declared nodes; `name` referenced not retyped.
- `ruleExplicitOptionality` — `projections` and the dispatch list are written explicitly
  (the parser preserves an empty-vs-absent distinction; absent is an error, `[]` is fine).
- `ruleDecodeStrictnessAck` — the `decode unknown-status => …` line is present.

Acceptance: `cabal run keiro-dsl -- check` on the corpus spec exits 0; on each mutated spec
(one per rule) it exits non-zero with the expected message (see Validation and Acceptance).

### Milestone 3 — Scaffold emitters (symbol-free wiring + holes)

Scope: emit the deterministic layer and the typed holes. At the end, `keiro-dsl scaffold`
produces a `-- @generated` module with the `ProcessManager` record wiring and timer
builder, plus a create-if-absent hole module — and the firewall-invariant test passes.

Edits, in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, adding `scaffoldProcess :: ProcessNode ->
[ScaffoldModule]`:

- A `Generated` module emitting the parts of the `ProcessManager` record that **are**
  derivable: `name = "<procName>"`; `eventStream`/`targetEventStream` references;
  `streamFor` from the `Expr`; `targetProjections = const [ … ]` (or `const []`); the
  `TimerRequest` builder (id, `processManagerName = name`, `correlationId`, `payload`,
  and `fireAt` *applied to* the deadline hole); and the timer-worker skeleton that calls
  `runTimerWorkerWith` with the spec's `maxAttempts`/`dead-letter` (NOT the dangerous
  `defaultTimerWorkerOptions`), routing by `processManagerName == "<procName>"` and applying
  the `FireDisposition` as a pure `Either CommandError _ -> Maybe EventId` table. This
  module must contain **no** keiki symbolic operator (the saga's transducer body is the
  separate aggregate hole from EP-1).
- A `HoleStub` module emitting *signatures only* for: `handle :: input ->
  ProcessManagerAction ci targetCi` (the `advance`/`dispatch` mappings — Hole 3); the
  deadline window function `surgeWindow :: NominalDiffTime` and `surgeDeadline :: UTCTime ->
  UTCTime` (the duration policy — Hole 3 mapping); the id derivations (Hole 1); and the
  timer `fire` body where the disposition is already wired but the command construction is a
  hole. The emitter **never** emits `B.requireGuard` or `B.slot` (firewall).

Critical constraint restated: the dispatch-id is emitted as the runtime-owned strategy —
the generated `handle` passes a placeholder id the runtime overwrites; the scaffold never
emits a hole *for* the dispatch id.

Acceptance: scaffold runs; the firewall test (`grep`-style assertion over every `Generated`
`moduleText`) finds no symbolic operator; re-running scaffold does not clobber the hole
module.

### Milestone 4 — Harness emission

Scope: emit a spec-derived test module pinning the behavior the spec asserts. At the end,
the harness compiles against filled holes and goes green; a mutation turns one test red.

Edits, in `keiro-dsl/src/Keiro/Dsl/Harness.hs`, adding `harnessProcess :: ProcessNode ->
ScaffoldModule`. The emitted module asserts:

- **Time-injection**: the deadline equals `addUTCTime window observedAt` for a fixed
  injected `observedAt`, and does not depend on the wall clock (call it twice; equal).
- **Disposition tables**: the dispatch table and the fire table map each outcome to the
  spec's `Disp`/`FireOutcome` (e.g. `Left CommandRejected` ⇒ `Fired`).
- **Runtime-owned dispatch-id**: the dispatched command's id equals
  `deterministicCommandId name correlationId sourceEventId 0` (pinning that the runtime, not
  the author, owns it).
- **Deterministic ids**: `timerId` and `firedEventId` are stable across calls and equal the
  spec's `uuidv5` of the keyed string.

Acceptance: `cabal test` on the emitted harness is green with filled holes.

### Milestone 5 — Conformance vs `SurgeManager`

Scope: prove the whole vertical against the real corpus. At the end, the captured fixtures,
the authored `.kdsl`, and the round-trip check → scaffold → fill → harness loop all pass,
and a mutation demonstrably breaks a specific test.

Edits and steps:

- Capture read-only fixtures under `keiro-dsl/test/fixtures/hospital-surge/`:
  `SurgeManager.hs` and `Surge/Transducer.hs` from
  `/Users/shinzui/Keikaku/bokuno/keiro-runtime-jitsurei/services/hospital-capacity/src/HospitalCapacity/`.
- Author `keiro-dsl/test/fixtures/hospital-surge/hospital-surge.kdsl` (the notation above),
  plus the `Surge` aggregate block (reusing EP-1's `aggregate` node) and the two `derive
  strategy=uuidv5` declarations.
- Run check → scaffold → fill holes to match the captured reference → run harness; confirm
  green.
- Mutation test: change the spec's `fire … on-reject` from `Fired` to `Retry`, re-scaffold,
  and confirm the harness's fire-disposition assertion turns **red** (proving the test pins
  the inversion). Restore.

Acceptance: see Validation and Acceptance.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless
noted. The `keiro-dsl` package and its CLI are provided by EP-1; this plan assumes EP-1 is
Complete (the `keiro-dsl` executable builds and `parse`/`check`/`scaffold` work on an
aggregate-only spec).

Confirm the toolchain builds before starting:

```bash
cabal build keiro-dsl
```

Expected: a successful build line ending in the `keiro-dsl` library and exe components.

### Milestone 1 — parse a process spec

After the Grammar/Parser/PrettyPrint edits, capture the fixtures and author the spec, then:

```bash
cabal run keiro-dsl -- parse keiro-dsl/test/fixtures/hospital-surge/hospital-surge.kdsl
```

Expected (abridged): a pretty-printed echo of the spec, including the `process HospitalSurge`
block with its nested `timer surgeFollowUp`, the `dispatch-id strategy=uuidv5` line, and the
`max-attempts 5 dead-letter "…"` line — byte-identical to the input modulo normalized
whitespace. The round-trip unit test:

```bash
cabal test keiro-dsl --test-options='--match "parser/round-trip process"'
```

Expected: `1 example, 0 failures` (or the project's test-runner equivalent).

### Milestone 2 — check rejects dangerous omissions

```bash
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/hospital-surge/hospital-surge.kdsl
echo "exit=$?"
```

Expected: no diagnostics, `exit=0`.

For each rule, a mutated copy must fail. Example (drop the attempt ceiling):

```bash
sed '/max-attempts/d' keiro-dsl/test/fixtures/hospital-surge/hospital-surge.kdsl > /tmp/no-ceiling.kdsl
cabal run keiro-dsl -- check /tmp/no-ceiling.kdsl
echo "exit=$?"
```

Expected: a line-numbered error such as

```text
hospital-surge.kdsl:NN:C: error: timer 'surgeFollowUp' must declare 'max-attempts N dead-letter "<reason>"'; an absent ceiling never auto-dead-letters and retries forever
exit=1
```

Analogous mutations and expected messages for the other rules: removing the `on-reject`
fire arm (`error: timer fire disposition incomplete: missing 'on-reject'`); adding a
`commandId=` to a `dispatch` (`error: dispatched-command id is runtime-owned; remove
'commandId='`); replacing `fireAt input.observedAt + 5m` with `fireAt now + 5m` (`error:
timer 'fireAt' must be an injected timestamp field + window, not a wall-clock sample`);
removing the `decode unknown-status` line (`error: timer must acknowledge the unknown-status
=> Cancelled decode fallback`).

### Milestone 3 — scaffold and firewall

```bash
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/hospital-surge/hospital-surge.kdsl --out /tmp/surge-scaffold
ls /tmp/surge-scaffold
```

Expected: a `-- @generated` module (e.g. `Generated/HospitalSurgeProcess.hs`) and a hole
module (e.g. `HospitalSurgeProcessHoles.hs`). Firewall check:

```bash
grep -nE 'B\.slot|B\.requireGuard|\blit\b|=:|\./=|\.==|\.\|\|' /tmp/surge-scaffold/Generated/*.hs
echo "exit=$?"
```

Expected: no matches, `exit=1` (grep found nothing) — the generated layer is symbol-free.
The harness-backed firewall unit test:

```bash
cabal test keiro-dsl --test-options='--match "scaffold/firewall process"'
```

Expected: `0 failures`.

### Milestone 4 — harness green

```bash
cabal test keiro-dsl --test-options='--match "harness/hospital-surge"'
```

Expected: all process/timer harness examples pass.

### Milestone 5 — conformance and mutation

With the holes filled to match the captured `SurgeManager.hs` reference, the full suite is
green:

```bash
cabal test keiro-dsl
```

Mutation (prove the harness pins the inversion):

```bash
sed -i.bak 's/on-reject Fired/on-reject Retry/' keiro-dsl/test/fixtures/hospital-surge/hospital-surge.kdsl
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/hospital-surge/hospital-surge.kdsl --out /tmp/surge-mut
cabal test keiro-dsl --test-options='--match "harness/hospital-surge/fire-disposition"'
echo "exit=$?"
mv keiro-dsl/test/fixtures/hospital-surge/hospital-surge.kdsl.bak keiro-dsl/test/fixtures/hospital-surge/hospital-surge.kdsl
```

Expected: the `fire-disposition` example **fails** (`exit` non-zero) under the mutated spec,
then the restore returns the suite to green. This is the user-visible proof that the spec's
benign-inversion decision is genuinely pinned.


## Validation and Acceptance

The plan is accepted when all of the following observable behaviors hold, each demonstrable
by the commands in *Concrete Steps*:

1. **Parse + round-trip.** `keiro-dsl parse` on `hospital-surge.kdsl` echoes a `process`
   block with a nested `timer`, and re-parsing the output yields an equal model
   (`parser/round-trip process` test green). This proves the notation is a real language,
   not freeform text.
2. **Check forces every dangerous decision.** `keiro-dsl check` passes the corpus spec
   (exit 0) and rejects each of these mutated specs with a precise, line-numbered
   diagnostic and a non-zero exit: missing `max-attempts`/`dead-letter`; an incomplete
   dispatch or fire disposition table; a user-supplied `commandId=` on a dispatch; a
   wall-clock `fireAt` (`now + 5m`) instead of an injected field; a missing
   `decode unknown-status` acknowledgement; a `saga`/`target`/`projections` reference that
   does not resolve. This proves the checker catches the omissions *before any Haskell is
   written*.
3. **Scaffold emits a symbol-free deterministic layer + holes.** `keiro-dsl scaffold`
   produces a `-- @generated` `ProcessManager`/timer wiring module containing **no** keiki
   symbolic operator (`grep` finds nothing; the `scaffold/firewall process` test is green),
   plus a create-if-absent hole module with signatures for `handle`, the deadline window,
   the id derivations, and the timer `fire` body. The generated timer-worker calls
   `runTimerWorkerWith` with the spec's ceiling, *not* `defaultTimerWorkerOptions`.
4. **Harness pins behavior.** With the holes filled to match the captured `SurgeManager.hs`,
   `cabal test keiro-dsl` is green. The harness asserts: the deadline equals
   `addUTCTime window observedAt` and is wall-clock-independent; the dispatch id equals
   `deterministicCommandId name correlationId sourceEventId 0` (runtime-owned); `timerId`
   and `firedEventId` are the deterministic `uuidv5`s; and the fire table maps
   `Left CommandRejected ⇒ Fired`.
5. **Mutation breaks a specific test.** Flipping `on-reject Fired` to `on-reject Retry` in
   the spec, re-scaffolding, and running the suite turns the
   `harness/hospital-surge/fire-disposition` example **red** (and only that family),
   demonstrating the spec→behavior link is load-bearing rather than cosmetic. Restoring the
   spec returns the suite to green.

Acceptance is behavioral throughout: each item is a command with an observable pass/fail,
not an internal attribute. The conformance target is the real, external
`HospitalCapacity/SurgeManager.hs`; passing it is the proof the vertical is faithful to the
`ProcessManager` + `Timer` primitives.


## Idempotence and Recovery

Every step in this plan is safe to repeat.

- **`parse` and `check`** are pure reads of a `.kdsl` file and produce no side effects; run
  them as often as you like.
- **`scaffold`** is idempotent by construction (the EP-1 discipline this plan inherits):
  `Generated` modules are overwritten verbatim on every run, so re-scaffolding after a spec
  edit simply refreshes them; `HoleStub` modules are created **only if absent**, so filled
  holes are never clobbered. To force a clean regen of a hole module, delete it and
  re-scaffold. Scaffolding into a fresh `--out` directory (as the steps do, using
  `/tmp/...`) never touches the working tree.
- **The captured fixtures** under `keiro-dsl/test/fixtures/hospital-surge/` are read-only
  copies of external corpus files; re-copying them is harmless. If a fixture drifts from the
  corpus, re-copy from
  `/Users/shinzui/Keikaku/bokuno/keiro-runtime-jitsurei/services/hospital-capacity/src/HospitalCapacity/`.
- **The mutation test** edits the spec in place; the step takes a `.bak` and restores it, so
  the working tree returns to its prior state. If interrupted mid-mutation, restore with
  `git checkout -- keiro-dsl/test/fixtures/hospital-surge/hospital-surge.kdsl`.

This plan adds no migrations, touches no database, and modifies no runtime package, so there
is nothing destructive to roll back. The only durable artifacts are new `keiro-dsl` source
modules and test fixtures; all are additive and revertible with ordinary `git` operations.

A note on the *runtime* idempotence this DSL encodes (not a step you run here, but the
property the generated code preserves): the `ProcessManager` makes every write under a
`deterministicCommandId`, so replaying a source event appends nothing new
(`keiro/src/Keiro/ProcessManager.hs:158-180,217,263-277`); and `scheduleTimerTx` upserts on
`timerId` re-arming only a still-`Scheduled` row, so re-scheduling is idempotent and a fired
timer is never resurrected (`keiro/src/Keiro/Timer/Schema.hs:102-117,207-214`). The
validator's deterministic-id and runtime-owned-id rules exist precisely to keep this
property intact in scaffolded services.


## Interfaces and Dependencies

### Runtime primitives this plan binds to (the bijection targets)

- `Keiro.ProcessManager` (`keiro/src/Keiro/ProcessManager.hs`) — the `ProcessManager`
  10-field record (`:91-102`), `ProcessManagerAction { command, commands, timers }`
  (`:110-115`), `PMCommand { target, command }` (`:118-122`), the result types
  `PMCommandResult`/`PMStateResult` with the benign-vs-fatal cases (`:124-145`),
  `deterministicCommandId :: Text -> Text -> EventId -> Int -> EventId` (`:166-180`), and
  the runners `runProcessManagerOnce` (`:194`) / `runProcessManagerWorker` (`:291`). The
  `process` node scaffolds onto this record and the runtime owns dispatch ids here.
- `Keiro.Timer` (`keiro/src/Keiro/Timer.hs`) and `Keiro.Timer.{Schema,Types}` — the
  lifecycle types `TimerStatus` / `TimerRow` (`Schema.hs:51-84`), `TimerId` / `TimerRequest`
  (`Types.hs:17-35`), `scheduleTimerTx :: TimerRequest -> Tx.Transaction ()`
  (`Schema.hs:107`), `claimDueTimer` (`:124`), `markTimerFired` (`:132`), the recovery
  surface `cancelTimer`/`deadLetterTimer`/`requeueStuckTimer`/`findStuckTimers`
  (`:175-197`), and the worker entrypoints `TimerWorkerOptions { maxAttempts :: Maybe Int }`
  with `defaultTimerWorkerOptions` (the dangerous `Nothing` default, `Timer.hs:63-74`),
  `runTimerWorkerWith` (`:93`) and `runTimerWorker` (`:138`). The `timer` node scaffolds the
  `TimerRequest` builder and a worker call to `runTimerWorkerWith` with the spec's ceiling.
- The saga's *own* aggregate reuses EP-1's `aggregate` machinery and the keiki transducer
  surface (`Keiki.Builder`, `Keiki.Core`) — but only inside hole modules; never in
  `Generated` modules (firewall).

### Shared `keiro-dsl` engine modules this plan extends (additively)

- `Keiro.Dsl.Grammar` (`keiro-dsl/src/Keiro/Dsl/Grammar.hs`) — **add** `Process !ProcessNode`
  and `Timer` to the node AST, plus `ProcessNode`, `InputDecl`, `CorrelateDecl`, `SagaRef`,
  `AggRef`, `ProjectionRef`, `HandleNode`, `DispatchNode`, `Disposition`/`Disp`,
  `DispatchIdStrategy` (single inhabitant `UuidV5FromManagerTuple`), `TimerNode`,
  `FireAtExpr` (structurally `field + window`, no clock constructor), `FireNode`,
  `FireDisposition`/`FireOutcome`, `IdExpr`/`IdStrategy` (`= UuidV5`), `PayloadExpr`,
  `TimerStatusLit`.
- `Keiro.Dsl.Parser` (`keiro-dsl/src/Keiro/Dsl/Parser.hs`) — **add** `pProcess :: Parser
  ProcessNode`, `pTimer :: Parser TimerNode`, register in `pNode`; the `dispatch-id` parser
  yields the single strategy and rejects a user id at parse time. Signature unchanged:
  `parseSpec :: FilePath -> Text -> Either ParseError Spec`.
- `Keiro.Dsl.PrettyPrint` (`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`) — **add**
  `prettyProcess`/`prettyTimer`; round-trip preserved.
- `Keiro.Dsl.Validate` (`keiro-dsl/src/Keiro/Dsl/Validate.hs`) — **add** the eight rules
  named in *Context* (`ruleNoWallClock`, `ruleRuntimeOwnedDispatchId`,
  `ruleCompleteDispatchDisposition`, `ruleCompleteFireDisposition`, `ruleExplicitMaxAttempts`,
  `ruleDeterministicIds`, `ruleCrossNodeCoupling`, `ruleExplicitOptionality`,
  `ruleDecodeStrictnessAck`) to the `validateSpec :: Spec -> [Diagnostic]` rule set.
- `Keiro.Dsl.Scaffold` (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`) — **add** `scaffoldProcess
  :: ProcessNode -> [ScaffoldModule]` emitting one `Generated` wiring module and one
  `HoleStub` module, using `ScaffoldModule { modulePath, moduleText, kind }` and
  `ModuleKind = Generated | HoleStub`. Must satisfy the firewall invariant.
- `Keiro.Dsl.Harness` (`keiro-dsl/src/Keiro/Dsl/Harness.hs`) — **add** `harnessProcess ::
  ProcessNode -> ScaffoldModule` emitting the time-injection, disposition-table,
  runtime-owned-id, and deterministic-id assertions.
- The CLI (`keiro-dsl/app/Main.hs`) — no new subcommands; `parse`/`check`/`scaffold` pick up
  the new node via the shared engine.

### Per-milestone interface checkpoints

- **End of M1:** `Keiro.Dsl.Grammar` exports `ProcessNode`/`TimerNode` (and the
  disposition/strategy/window types); `Keiro.Dsl.Parser.parseSpec` parses a `process` block;
  pretty-print round-trips.
- **End of M2:** `validateSpec` includes the nine new rules; `check` exits non-zero on each
  mutated spec.
- **End of M3:** `scaffoldProcess` returns `[ScaffoldModule]` with one `Generated` and one
  `HoleStub`; firewall test green.
- **End of M4:** `harnessProcess` returns a `ScaffoldModule`; emitted harness compiles and
  passes against filled holes.
- **End of M5:** fixtures captured under `keiro-dsl/test/fixtures/hospital-surge/`; full
  `cabal test keiro-dsl` green; mutation reddens `harness/hospital-surge/fire-disposition`.

### External library dependencies

No new third-party dependencies beyond those EP-1 already introduces to `keiro-dsl`
(megaparsec for parsing, optparse-applicative for the CLI, prettyprinter for rendering).
This plan reuses keiro's existing `aeson`, `time`, and `uuid` deps (already in the runtime
packages) only indirectly, by *emitting* code that imports them — `keiro-dsl` itself does
not link the runtime. The conformance fixtures depend on the external
`keiro-runtime-jitsurei` corpus only as read-only captured copies, not as a build
dependency.
