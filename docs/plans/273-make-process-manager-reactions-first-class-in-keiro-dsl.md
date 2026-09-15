---
id: 273
slug: make-process-manager-reactions-first-class-in-keiro-dsl
title: "Make process-manager reactions first-class in keiro-dsl"
kind: exec-plan
created_at: 2026-09-10T00:48:02Z
intention: "intention_01m24dv27ze9gak6fc30mhqrsg"
provenance:
  reviews:
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-10T12:42:20Z
      verdict: "changes-requested"
      note: "Recorded retrospectively for this session: review found absent implementation, unsound batch recovery, import cycles, and inconsistent timer acceptance; runtime feasibility required before DSL implementation."
  revisions:
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-10T12:42:20Z
      mode: "update"
      note: "Applied review corrections, recorded validation evidence, and extracted runtime API hardening into prerequisite plan 279; provenance recorded retrospectively for this session."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-15T17:40:03Z
      mode: "update"
      note: "Reconcile completed process-manager runtime handoff, unconditional effects, recovery, timer lifecycle, worker wiring, and DSL acceptance."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-15T17:50:53Z
      mode: "update"
      note: "Refine M3 generated worker proof, mixed-effects semantics, and actionable hydration measurement."
---

# Make process-manager reactions first-class in keiro-dsl


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


After this change, an author can describe an event-driven coordination process completely in a
`.keiro` file under the new candidate `language keiro-dsl 6`, and `keiro-dsl scaffold` emits the
executable process manager for it instead of a comment-only hole. A process block may declare
several typed input variants (for example an incident being reported and a responder acknowledging
it), react to each variant with ordered guarded arms whose guards read the input's typed fields,
advance the saga, dispatch commands to the target aggregate, schedule or cancel any number of
named durable timers with typed input-derived payloads, or deliberately do nothing. A process may
also have no timers at all. A reaction whose fan-out depends on saga state expresses that
dependency through the saga's own transducer: the follow-up runs only when the saga accepted the
advance command, and the recorded saga event witnesses acceptance so redelivery reproduces accepted follow-ups.
Silent decisions have no persisted witness and can be re-evaluated after saga state changes.

The behavior is visible in three new database-backed conformance packages and in
`keiro-dsl check`. Given a Language 6 process with two input variants, the generated manager selects
the guarded arm and appends the saga's accepted event batch with its first event under the
deterministic manager id. Eventful target commands deduplicate under target-keyed deterministic
ids; silent target commands have no persisted receipt. Scheduling re-arms or preserves a timer
according to its declared mode. Redelivery of an accepted source with eventful targets returns
duplicate results without repeating timer writes or target appends. `keiro-dsl check` refuses a binding whose input field type differs from
the target command field, a schedule of an undeclared timer, a guard that reads saga state, two
`on` blocks for one input, an input variant with no `on` block, an arm list without an
`otherwise` arm, and two timers that share an identity prefix. `keiro-dsl diff` classifies reaction
reordering, guard changes, conditional dispatch changes, timer payload and identity changes, and the
migration of a legacy positional-identity process to the reaction form.

The runtime prerequisite is now [plan 279](279-harden-process-manager-reaction-apis-before-dsl-generation.md). It owns the feasibility gate, additive reaction
API, transactional timer cancellation, dispatch identity, handwritten runtime example, and recovery
proofs. It completed on 2026-09-14 and M0 has accepted it; the next work is M1, registering
Language 6. This plan owns the DSL surface and
its generated conformance, consuming the supported runtime API rather than implementing one.
The source request remains
`docs/improvement-requests/make-process-manager-reactions-first-class-in-keiro-dsl.md` (IR-39).
Milestone labels below are retained for continuity: M0 is prerequisite acceptance and M3 proves
the first generated worker using the existing runtime. M4 extends that generator to the full surface.


## Progress


Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-10) Validate the plan against the current tree: implementation is absent; record and correct the design defects below. This is a source review, not a passing M0 feasibility gate.
- [x] (2026-09-14 20:41Z) M0: accepted completed runtime prerequisite [plan 279](279-harden-process-manager-reaction-apis-before-dsl-generation.md), recording its tests, exported API, frozen vectors, ADR-41, and measurement deviations before grammar implementation.
- [x] (2026-09-15) Reconcile all sections with the delivered reaction runtime at `edd142c1`, including unconditional effects, recovery, timer lifecycle, and worker integration; retain M1–M6 as pending.
- [x] (2026-09-15) Refine sequencing and acceptance: move a generated timer-free worker proof into M3, define mixed-effects examples before grammar implementation, and specify opt-in hydration observations.
- [ ] M1: register candidate Language 6 with the `ProcessReactionSyntax` feature and extend the frontend profile, baseline, and skeleton tests.
- [ ] M1: add the `ProcessBody` sum to `Keiro.Dsl.Grammar` and update every consumer so Language 1 through 5 sources keep their exact AST and generated bytes.
- [ ] M1: parse, pretty-print, and round-trip the reaction body, multiple inputs, guarded arms, `accepted`/`silent` blocks, schedule/cancel follow-ups, typed timer payloads, and the process-level timer policy.
- [ ] M1: commit the positive fixtures `process-reactions.keiro`, `process-timers.keiro`, and `process-state-authority.keiro`.
- [ ] M2: add `Keiro.Dsl.ProcessReaction` with the checked reaction model, typed binding resolution, guard resolution, totality rules, identity rules, and the SHA-256 reaction fingerprint.
- [ ] M2: add the new diagnostic codes, negative fixtures, source subjects, and check-report rows.
- [ ] M3: implement the initial timer-free generator, typed decoder hole, and worker wrapper; register the reactions conformance package and prove acceptance and redelivery through the generated worker.
- [ ] M4: extend M3's generator and conformance to guarded variants, timer payload codecs, timer fire functions, harness facts, and ledger rows.
- [ ] M4: add the timers and state-authority conformance packages, mutation coverage, baseline roles, and scaling evidence using the specified opt-in hydration probe.
- [ ] M5: add reaction and timer diff codes, process coordination impact, migration diagnostics, and diff fixtures.
- [ ] M6: update user documentation, guides, the authoring skill, changelogs, OKF logs, the prerequisite runtime ADR with DSL-specific decisions, and the IR-39 record, then run the full repository gate.


## Surprises & Discoveries


Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

The 2026-09-10 validation at commit `3837e1ea` found no implementation of this plan.
`LanguageVersion.hs:243` registers only Languages 1–5; neither proposed reaction module,
none of the three positive fixtures, and no `process reaction spikes` test exists. IR-39
remains `proposed`. Existing process tests can validate the substrate only.

The proposed batch replay contract was unsound: `runDomainCommandWithSqlEvents` returns all
accepted events, but `assignEventIds [managerId]` identifies only the first one. A scan for that
id cannot reconstruct the original batch boundary. The DSL only tests whether an advance was
accepted, so the revised runtime carries a fixed input-derived accepted follow-up list and uses
the first recorded event solely as an acceptance witness. It must never pass a fabricated
singleton to a callback promising the original batch.

Both proposed import graphs contained cycles. A generated `Process` defining the input type
cannot import a decoder from `ProcessHoles` when that hole imports `Process` for the input type.
Likewise `Keiro.ProcessManager` cannot re-export `Reaction` while `Reaction` imports its command
and result types from that module. Milestones 3 and 4 now specify acyclic module boundaries.

The original timer acceptance mixed three distinct cases. A duplicate accepted saga append
must not replay its timer SQL; re-arming is tested with a new source event and later injected
time. An exception inside the append transaction rolls back timers and saga events, whereas a
crash after commit preserves both. Cancellation of a scheduled row prevents subsequent claims but cannot revoke an
already-running worker's target dispatch. The target aggregate must reject obsolete firing.

`keiro_command_decision` is a telemetry attribute (`Keiro.Telemetry`, value
`keiro.command.decision`), not a hydration counter. The scaling proof needs direct instrumentation
of saga hydration and must allow additional attempts on optimistic conflict.

The planned ADR-40 is already allocated to the inspection-UI boundary in
`docs/adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md`.
Plan 279 subsequently allocated ADR-41 for reactions; extend that record at DSL closeout.
CLI diff also compares the same path at the chosen Git
revision, not two differently named fixtures; the corrected commands below use an isolated
scratch repository.

The 2026-09-15 source review found that the earlier M0 handoff had updated signatures and outcomes
but left stale prerequisite and timer-cancellation claims elsewhere. The runtime is implemented in
`keiro/src/Keiro/ProcessManager/Reaction.hs`; `Keiro.Timer` exports `cancelTimerTx`. Its engine
selects `unconditional <> acceptedOnly` on acceptance and only `unconditional` on silence. Thus
`silent no-action` suppresses the accepted block, not sibling unconditional effects. The runtime
also separates ordered timer statements from ordered target attempts; it promises no global commit
order across targets. Generated conformance must preserve these distinctions.

The follow-up source review found a concrete observation point for the outstanding measurement:
`hydrate` in `keiro/src/Keiro/Command.hs` is called inside `domainCommandAttemptLoop` on each
attempt, while `recoverWitness` in `keiro/src/Keiro/ProcessManager/Reaction.hs` bypasses it.
Neither currently exposes a hydration counter. M4 therefore specifies an opt-in test build that
records these entry points separately, rather than equating persisted event counts with reads.


## Decision Log


Record every decision made while working on the plan.

- Decision: Implement IR-39 through a runtime prerequisite, [plan 279](279-harden-process-manager-reaction-apis-before-dsl-generation.md), followed by this DSL plan.
  Rationale: The public API and its recovery semantics must be useful and proven in handwritten
  Haskell before generation depends on them. The two plans have a simple prerequisite relationship
  and do not require a MasterPlan. This supersedes the original single-plan scoping decision.
  Date: 2026-09-10
- Decision: Open candidate `language keiro-dsl 6` with exactly one new syntax feature,
  `ProcessReactionSyntax`, and reuse runtime profile `keiro-dsl/runtime-semantics/4`.
  Rationale: Language 5 is `Stable PublishedLanguage` with no active candidate
  (`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`, `languageRegistry`), so new syntax must be a
  successor per ADR-16. The reaction body changes no aggregate replay or fold behavior, so
  ADR-18 gives no reason to add a `RuntimeCapability`; languages 1 and 2 already share one
  runtime profile, so reuse has precedent.
  Date: 2026-09-10
- Decision: Preserve the legacy process body as a distinct constructor
  (`LegacyProcessBody`) and never widen it; the reaction body is a second constructor.
  Rationale: Languages 1 through 5 must keep byte-identical generated output and existing
  fixtures. A sum type with `-Werror=incomplete-patterns` forces every consumer to choose a
  branch explicitly instead of accidentally lowering a reaction body through legacy code.
  Date: 2026-09-10
- Decision: Guards read only the input variant's declared fields. Arms are ordered,
  first-match wins, and any `on` block with a `when` arm must end in an `otherwise` arm. Saga
  state is reachable only through the saga's own transducer via `accepted` follow-ups.
  Rationale: A pure input-only guard makes the reaction a pure function of the input, which is
  what keeps deterministic dispatch identity sound under redelivery. `ProcessManager.handle`
  receives no hydrated state today, and IR-39 forbids an unguarded state read that could
  dispatch from stale state. The saga transducer is already evaluated by the manager command
  path with optimistic retry, so it is the only decision authority that is both hydrated and
  durable.
  Date: 2026-09-10
- Decision: Silent saga decisions (typed rejection, typed no-op, or an eventless accepted
  transition) never execute accepted-only follow-ups. Unconditional follow-ups remain eligible.
  An `accepted` block requires every accepting saga transition for the
  advance command to emit at least one event, and a `silent no-action` line is mandatory
  beside it.
  Rationale: A silent decision appends nothing, so a redelivery could not reproduce the branch
  it took; only the recorded saga event is durable. ADR-29 already establishes that rejection and
  no-op decisions execute no acceptance callback. ADR-41 separately permits unconditional
  reaction effects after silence. The mandatory `silent` line follows the
  DSL's rule that dangerous defaults are stated, not assumed.
  Date: 2026-09-10
- Decision: Reaction-form dispatches use a new target-keyed, length-prefixed identity
  derivation (`deterministicReactionCommandId`) seeded by manager name, correlation id, source
  event id, physical target stream, and same-target occurrence in declared order. The manager
  state append keeps the legacy emit-index `-1` derivation. Legacy processes keep positional ids.
  Rationale: The positional emit index is sound only while the command list is a fixed function
  of the input; conditional arms and reordered dispatch lists would silently reuse an index for
  a different action, which IR-39 forbids. The router already proved the target-keyed shape and
  ADR-24 requires new derivations to follow its length-prefixed UTF-8 encoding. Keeping the
  manager id unchanged preserves the state-duplicate probe for every existing saga stream.
  Date: 2026-09-10
- Decision: Unlike declarative routers, reaction dispatches keep declared source order and do
  not reject two different commands to one target; the occurrence index counts same-target
  dispatches in declared order.
  Rationale: ADR-30 normalizes router output because an effectful query can return targets in
  any order. A reaction's dispatch list is pure and source-ordered, so declared order is stable,
  and two commands to one aggregate in sequence are a legitimate coordination step.
  Date: 2026-09-10
- Decision: Timer identity remains `uuidv5 "<prefix>" <> correlationId` per timer name; every
  timer and fired-event prefix must be distinct across the whole spec; `schedule` re-arms
  through `scheduleTimerTx`, `schedule once` preserves the first deadline through
  `scheduleTimerOnceTx`, and `cancel` uses the delivered `cancelTimerTx` inside the manager
  append transaction. `max-attempts` and `dead-letter` become one process-level `timers` policy.
  Rationale: The runtime's upsert already refuses to resurrect fired or cancelled rows, so
  correlation-keyed identity is safe as long as two timers of one saga never share a prefix,
  which is the collapse IR-39 warns about. One timer worker claims every timer of a process and
  has a single attempt ceiling, so per-timer ceilings could not be honored.
  Date: 2026-09-10
- Decision: The source-event decoder stays hand-owned as a typed, versioned create-once hole
  (`decode<Process>Input :: RecordedEvent -> Maybe <Process>Input`); everything else in the
  process is generated. Binding an input variant directly to a declared aggregate event is
  recorded as a follow-up request, not built here.
  Rationale: IR-39 asks for generated action construction and explicit typed holes for custom
  behavior. Source message decoding is the one behavior the current spec cannot describe
  without a new cross-node reference form, and adding that form would widen the grammar beyond
  the request.
  Date: 2026-09-10
- Decision: Reaction verification uses the router vocabulary: a generated reaction body is
  `generated-declarative`, a legacy `handle` body is `custom-unverified`, and the ledger,
  harness, and check report all say which one applies.
  Rationale: IR-39 requires that custom holes are never reported as declaratively verified;
  reusing the exact ledger vocabulary from ADR-30 keeps one meaning for the words.
  Date: 2026-09-10
- Decision: Reaction bodies carry `reactions version N` and a SHA-256 fingerprint over the
  checked semantics. A fingerprint change without a version bump is breaking in `diff`; with a
  bump it is an advisory that names the drain procedure.
  Rationale: This mirrors ADR-30 so an operator reviews process fan-out changes the same way
  as router selection changes. Version and fingerprint never enter any identity seed.
  Date: 2026-09-10
- Decision: Out of scope, per the request: heterogeneous target aggregate dispatch, effectful
  recipient selection (routers keep that), and imperative workflow constructs.
  Rationale: IR-39 states these boundaries explicitly.
  Date: 2026-09-10
- Decision: Routers are a boundary of this plan, not a deliverable. The router grammar, the
  `Keiro.Router` runtime, and the declarative selection contract from ADR-30 are unchanged.
  Routers do not gain multiple typed inputs or guarded arms, and a process reaction cannot
  delegate recipient selection to a router inline. Process-to-router composition stays at the
  stream level: a reaction dispatches to its target aggregate, and that aggregate's events feed
  the router's subscription. Reaction dispatch identity borrows the router's length-prefixed,
  target-keyed derivation shape under a distinct `process-reaction` seed kind so the two
  families can never produce one id.
  Rationale: IR-39 states that effectful recipient selection remains the router capability
  unless a separate need is demonstrated, and IR-9 fixed the router as a single-input effectful
  selector. Inline delegation would reintroduce an effectful seam into the reaction and break
  the input purity that keeps reaction dispatch identity sound. Either extension is a separate
  improvement request.
  Date: 2026-09-10

- Decision: Treat accepted saga events as an acceptance witness, not a recoverable batch API.
  `onAccepted` is a fixed list computed from the immutable input; it cannot inspect event values.
  Rationale: The DSL has no event-dependent bindings, and the existing deterministic id locates
  only the first event. This keeps first delivery and replay equivalent for multi-event commands.
  Date: 2026-09-10
- Decision: Keep silent decisions explicitly non-durable and require M0 to demonstrate their
  redelivery behavior before approving implementation. A silent attempt runs no accepted effects,
  but after unrelated saga progress the same source may accept on a later delivery. Stable replay
  of rejection/no-op is outside this design unless a separate durable receipt is introduced.
  Rationale: The current command path writes no evidence for silent outcomes. Input purity alone
  cannot freeze a state-dependent decision. Do not claim exactly-once command evaluation.
  Date: 2026-09-10
- Decision: The review updates the proposed design and leaves M0 open; it does not mark absent
  implementation complete or allocate a durable ADR before feasibility is established.
  Rationale: Existing runtime tests cannot prove the proposed runner or generated wiring.
  Date: 2026-09-10


- Decision: Consume the completed ADR-41 runtime contract and begin at M1. Normalize selected
  effects as unconditional follow-ups followed by accepted-only follow-ups, preserving order
  within each list and then within the runtime's timer and dispatch phases.
  Rationale: The public `AdvanceReaction` has two lists and the delivered engine concatenates
  them in that order. Textual nesting must not imply interleaving or cross-stream commit order.
  `silent no-action` applies only to the accepted block; unconditional effects have no durable
  silent receipt. The DSL must expose these existing semantics without inventing a runner.
  Date: 2026-09-15


- Decision: Deliver a minimal generated timer-free worker in M3, retaining its modules and
  conformance package as the foundation for M4. Keep `silent no-action` as block-local syntax,
  with an explicit mixed-effects example and acceptance/silence/replay expectations before M1.
  Measure hydration through default-disabled test instrumentation at the actual runtime entry.
  Rationale: A compiling DSL library alone does not prove executable lowering. Early worker
  coverage exposes wiring defects before timer generation; the example removes a misleading
  reading of silence; direct observations distinguish hydration from witnesses and event counts.
  Date: 2026-09-15


## Outcomes & Retrospective


Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Validation outcome (2026-09-10): the feature was not implemented in that working tree. The plan
was corrected for the concrete source-level defects found in review, and runtime delivery moved to
[plan 279](279-harden-process-manager-reaction-apis-before-dsl-generation.md).

Runtime prerequisite outcome (2026-09-14): plan 279 delivered the additive public reaction module,
transactional timer cancellation, frozen target-keyed identities, shared once/worker execution,
and a handwritten public-only consumer. Its focused Reaction group passed 16 examples, the broader
process-manager group passed 41, the full `keiro` suite passed 658 examples, all `keiro-dsl:tests`
components passed (including the 719-example main DSL suite), and the 39-entry generated corpus
remained byte-current. [ADR-41](../adr/0041-process-manager-reactions-use-accepted-witnesses-and-target-keyed-recovery.md)
is the durable runtime contract. M0 accepts the concrete API below; grammar and generation
remain unimplemented and owned by this plan.

Plan update outcome (2026-09-15): the remaining work is M1–M6 under this plan's original intention.
The runtime and ADR-41 are available; generated reaction syntax, checking, and conformance remain
unimplemented. The update reconciles the runtime handoff across the plan and retains the explicit
M4 hydration measurement obligation. The test counts above are plan 279's recorded evidence, not
tests rerun during this documentation update.

Sequencing refinement (2026-09-15): M3 now has an observable generated-worker acceptance gate;
M4 extends that same implementation. The mixed-effects notation retains its existing keyword
spelling with explicit block-local meaning, and the hydration measurement now identifies source
locations, build isolation, collection, and expected counts. These are plan changes only; the
generator and instrumentation remain unimplemented.


## Context and Orientation


This repository is a Haskell multi-package Cabal project whose root contains `cabal.project` and
the `Justfile`; every command in this plan runs from that root unless stated otherwise. The
packages that matter are `keiro` (the runtime library, including `keiro/src/Keiro/ProcessManager.hs`
and `keiro/src/Keiro/Timer.hs`), `keiro-core` (codec and event-stream contracts), and `keiro-dsl`
(the specification language, checker, generator, and `keiro-dsl` executable). The source request
is `docs/improvement-requests/make-process-manager-reactions-first-class-in-keiro-dsl.md`
(IR-39). Its related requests are IR-9, completed by
`docs/plans/230-make-declarative-dynamic-router-fan-out-first-class-in-keiro-dsl.md`, and IR-7,
delivered by `docs/plans/231-add-typed-domain-command-outcomes.md` and
`docs/plans/232-add-typed-domain-outcomes-to-the-dsl.md`. Both precedents are reused heavily below.

A few terms are used throughout. A *process manager* (also called a *saga*) is a small state
machine that reacts to an incoming event by appending an event to its own private event stream,
dispatching commands to another aggregate (the *target*), and scheduling *durable timers*, which
are rows in the `keiro.keiro_timers` table that a worker claims and fires later. The saga's own
aggregate is the *saga aggregate*. The *correlation id* is the text derived from the input that
selects which saga instance handles the event; saga streams are named `<category>-<correlationId>`.
A *deterministic id* is a version-5 UUID computed from public coordinates so that an at-least-once
delivery collapses to one write. A *reaction* in this plan is the complete response to one typed
input variant: an ordered list of guarded *arms*, each holding an optional saga *advance*, and
*follow-ups* (dispatches, schedules, cancels), or the explicit `no-action`. A *hole* is a
create-once, hand-owned module the scaffolder never overwrites.


### The process node today


`keiro-dsl/src/Keiro/Dsl/Grammar.hs` defines `ProcessNode` (around line 828) with exactly one
`input :: InputDecl`, one `handle :: HandleNode`, and one mandatory `timer :: TimerNode`.
`HandleNode` (line 755) requires an `advance`, allows zero or more `dispatch` entries, and requires
one `schedule` name. `InputDecl` fields are generic `Field { name, valueType :: Maybe Name }`
values, not aggregate fields, so their types are plain names such as `Int` or `Time`. Bindings
(`FieldBinding`) are bare copies, `input.<field>` references, quoted literals, or the exact token
`timer.id`; there is no expression surface.

`keiro-dsl/src/Keiro/Dsl/Parser/Coordination.hs` parses this shape in `pProcess`, `pHandle`,
`pDispatch`, and `pTimerNode`. `pProcess` does not receive the `FrontendContext`, so it cannot
gate new syntax on a language feature today; `pRouter` shows the pattern it must adopt
(`requireLanguageFeatureAt context DeclarativeRouterSelectionSyntax (spanOf marker)` in
`pDeclarativeResolve`). `pFixedDispatchIdLine` accepts only the exact runtime-owned tuple.

`keiro-dsl/src/Keiro/Dsl/Validate.hs` checks the node in `validateProcess` (line 3607). It resolves
saga, target, commands, projections, the scheduled timer name, and binding *names*, but it never
compares binding *types*: `resolveCommand` only checks that a bound name exists on the target
command. The fixture `keiro-dsl/test/fixtures/hospital-surge-inputtype.keiro`, which changes
`availableIcuBeds` to `Text` while the saga command keeps `Int`, is used only by `diff` tests and
passes `check` cleanly. Under Language 4 and later, `strictSurfaceResolution` additionally requires
the correlate field, dispatch keys, and binding scopes to resolve, and `idFieldRules` requires
both id expressions to end in `correlationId`.

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` lowers the node in `scaffoldProcess` (line 5458). The
generated `Process.hs` contains the process name, the saga category, the worker options, a
`TimerRequest` builder whose payload includes only quoted-literal bindings (`payloadExpr` drops
bare and reference bindings), and the fire-disposition function. `emitProcessHoles` writes a
`ProcessHoles.hs` that exports nothing and consists entirely of comments describing what to write
by hand. The filled example `keiro-dsl/test/conformance-process-full/SurgeDemo/SurgeFlow/Manager.hs`
shows that the input type, the correlate function, the `handle` body, and the stream wiring are all
hand-written today. `keiro-dsl/src/Keiro/Dsl/Harness.hs` emits a facts harness with ten label/value
pairs (`processHarnessFactValues`), and `keiro-dsl/test/process-mutation-test.sh` proves one
disposition flip reddens it.

`keiro-dsl/src/Keiro/Dsl/Diff.hs` classifies process changes in `processPairDiff` (line 2664):
input field changes are breaking `ProcessInputChanged`; identity changes to the name, correlate
derivation, category, timer id prefix, or fired-event id prefix are breaking
`DerivedIdentityChanged`; a `fireAt` change is advisory `TimerWindowChanged`; any change to the
rendered handle surface is advisory `ProcessDecideSurfaceChanged`; and a payload change is advisory
`ProcessTimerPayloadChanged`. `keiro-dsl/src/Keiro/Dsl/CoordinationImpact.hs` reports versioned
coordination drift for routers only. `keiro-dsl/src/Keiro/Dsl/ScaffoldRecord.hs` persists
`router-selection` rows with `declarative-verified` or `custom-unverified`; there is no process row.


### The runtime today: legacy and reaction APIs


`keiro/src/Keiro/ProcessManager.hs` defines `ProcessManager` with a pure
`handle :: input -> ProcessManagerAction ci targetCi`, where the action holds a mandatory saga
`command`, a list of `PMCommand` values, and a list of `TimerRequest` values. `runProcessManagerOnce`
(line 531) derives the manager event id with `deterministicCommandIdProbes name correlationId
sourceEventId (-1)`, probes the saga stream with `firstExistingEventId`, appends through
`runCommandWithSql` with the timers scheduled by `scheduleTimerTx` in the same transaction, and then
dispatches each target command in its own transaction under
`deterministicCommandId name correlationId sourceEventId emitIndex`, where `emitIndex` is the
position in the list. A duplicate manager append still re-runs the dispatch loop so a crash between
the state append and a dispatch recovers on replay. `DomainProcessManager` uses a
`DomainCommandHandler` for the *target* but keeps the legacy path for the saga append. The module's
header documents that the manager event and its timers commit together, each target command commits
separately, and a timer-only no-op reaction schedules in a separate transaction; the generated code
must not imply anything stronger. This is the legacy API; Language 6 reaction bodies use the
separate `Keiro.ProcessManager.Reaction` module, whose concrete public types are recorded at M0.
Legacy `ProcessManager` does not re-export that module, so its import graph remains acyclic.

The reaction manager has a saga `DomainCommandHandler`, a validated target event stream, target
projections, and a pure `react` function. `NoAdvance` skips saga reads entirely. Advancing acceptance
commits saga events and selected timer statements together, then attempts targets independently.
Typed silent outcomes run only unconditional effects, with timers in a separate transaction.
Accepted redelivery validates the exact saga witness, skips all timer SQL, and retries both lists'
target commands. Silent and no-advance deliveries have no saga receipt and may repeat effects.
Even a final negative witness probe cannot exclude acceptance racing with the separate silent timer
transaction; acceptance-exclusive effects must be placed in `accepted`.

`keiro/src/Keiro/Command.hs` exports `runDomainCommandWithSqlEvents`, whose in-transaction callback
receives every emitted event paired with its `RecordedEvent` and which runs only for an accepted
non-empty batch; `RunCommandOptions.eventIds` assigns caller ids to the emitted events in order
(`assignEventIds`), so only the first emitted event carries the deterministic manager id. Optimistic
conflicts are retried by rehydrating up to `retryLimit`, so a decision always reflects the state at
the successful append. The private `recoverWitness` in
`keiro/src/Keiro/ProcessManager/Reaction.hs` captures a finite stream-version ceiling, pages the
intended stream in batches of 256, and decodes only the exact matched event. It returns
`ReactionWitnessMissing` or `ReactionWitnessUndecodable` on integrity failure. Generated code must
not scan witnesses itself or reconstruct an accepted batch from that one event.

`keiro/src/Keiro/Timer/Schema.hs` shows that `scheduleTimerTx` upserts by `timer_id` but re-arms a
row only while it is still `scheduled`, `scheduleTimerOnceTx` inserts only when absent, and
`cancelTimerStmt` cancels `scheduled` or `firing` rows without a resume token; `cancelTimer` wraps it
in its own transaction, while the public `cancelTimerTx :: TimerId -> Tx.Transaction Bool` exposes
the guarded operation for reaction transactions. `Once` preserves any existing row; `Rearm`
changes only Scheduled rows. Neither revives Firing, Fired, Cancelled, Dead, or foreground-owned
rows. Cancelling an absent id leaves no tombstone. `runTimerWorkerWith` claims one
due row, dead-letters it when `attempts` exceeds one worker-wide `maxAttempts`, and otherwise calls
the caller's fire action, marking the row fired only when that action returns an event id.

The once runner returns detailed state, timer, and target results. Its timer statement count
includes SQL that changes no row; only `onceInserted` and `timersCancelled` count changed rows.
The worker shares the private engine but reduces results before fan-out and retains duplicate
counts and failures. `runReactiveProcessManagerWorkerWith` uses the existing `WorkerOptions`,
adapter, and decoder contracts. Manager failures use dispatch position -1; target failures use the
overall dispatch position. Witness failures halt with bounded reasons, and asynchronous
cancellation escapes without acknowledgement. Targets use `PMCommandResult`, not a second typed
domain handler; eventless target results have no durable receipt. The runtime rechecks exact target
ids after failure or eventless results to reconcile concurrent accepted delivery.

`jitsurei/src/Jitsurei/EscalationProcess.hs` is the hand-written example this plan turns into a
spec: it reacts to two input variants, schedules a severity-dependent timer on one and dispatches
on the other, and relies on the incident aggregate's guards to make a late timer firing benign.


### Language registry and precedents


`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` registers Languages 1 through 5; Language 5 is the
sole `Stable` `PublishedLanguage` and the authoring default, and there is no `CandidateLanguage`.
`LanguageFeature` is the closed list of grammar gates and `SyntaxProfile` values are private, so the
only way to admit new syntax is a new registry row with a new feature. Adding a feature also
requires a `FeatureCase` in `keiro-dsl/test/Keiro/Dsl/FrontendProfiles.hs` (which proves every
older language refuses the feature at its marker), a conformance-baseline update in
`keiro-dsl/test/conformance-baseline.json` and `keiro-dsl/test/Keiro/Dsl/ConformanceBaseline.hs`
(which currently allows only the roles `stable-primary`, `published-compatibility`,
`compatibility-proof`, and `version-independent`; `candidate-primary` was removed when Language 5
published and must return for Language 6 suites), and skeleton updates in
`keiro-dsl/src/Keiro/Dsl/Skeleton.hs` because `keiro-dsl new` uses
`currentAuthoringLanguageVersion`, which becomes 6 as soon as the candidate exists.

The declarative router work is the closest precedent. `keiro-dsl/src/Keiro/Dsl/RouterSelection.hs`
turns parsed syntax into a checked model (`CheckedRouterSelection`) with typed scalar expressions
and a SHA-256 fingerprint; `emitDeclarativeRouterGen` in `Scaffold.hs` (line 5189) lowers it to a
complete generated `Router.hs`; `CoordinationImpact.hs` reports drift; and
`keiro-dsl/test/conformance-declarative-router/Main.hs` proves ordering, deduplication,
redelivery, and conflict behavior against PostgreSQL through `Keiro.Test.Postgres`. The typed
domain outcome work provides `DomainCommandHandler`, `DomainDecision`, and the generated
`<aggregate>DomainCommandHandler` export (`keiro-dsl/test/conformance-domain-outcomes/Generated/DomainOutcomes/Reservation/EventStream.hs`).


### Relevant ADRs


The following local records constrain this plan. ADR-41 already owns the runtime decision;
extend it with DSL decisions at M6 rather than allocating a competing record.

[ADR-41](../adr/0041-process-manager-reactions-use-accepted-witnesses-and-target-keyed-recovery.md)
fixes accepted-witness recovery, non-durable unconditional effects after silence or no advance,
target-keyed identity, timer lifecycle limits, and the shared once/worker engine. Timer SQL precedes
target attempts; replay can change target commit order. Adoption requires draining old source
deliveries, partial fan-out, timers, and permitted historical replays. No version label changes
these identities or supplies a compatibility fallback.

[ADR-4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) requires that
`check` reject what one spec can prove invalid, that `diff` classify what needs two revisions, and
that machine-readable diagnostic codes be append-only. Every new rule in this plan is placed at the
earliest boundary with enough evidence and every code is new rather than reused.

[ADR-16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) freezes
published languages, requires new syntax to be registered under a successor with a predecessor
relation, and states that registration is not release: a candidate may be corrected in place until
a package containing it is published. Language 6 is opened as that candidate and amended in place.

[ADR-17](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
establishes that each behavior has exactly one owner, generated or hole, and that a hole may not
replace behavior the DSL claims to own. The reaction body is generated-owned; the only hole is the
source decoder, and the generated module imports it by name so it cannot be silently omitted.

[ADR-18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md)
requires released runtime behavior to be selected by named capabilities and fold identity to come
only from `Keiro.Dsl.CanonicalEncoding`. This plan adds no capability and touches no fold surface;
the reaction fingerprint is a separate coordination identity computed in the new module.

[ADR-19](../adr/0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md)
and [ADR-38](../adr/0038-keiro-dsl-records-use-concise-labels-without-product-selectors.md) fix the
generated Haskell edition: concise record labels under `DuplicateRecordFields`, `NoFieldSelectors`,
and `OverloadedRecordDot`, explicit signatures, no warning pragmas, and a closed local-extension
set. Generated input records and payload records follow it.

[ADR-24](../adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md)
freezes every deterministic derivation and its seed text and requires new derivations to hash UTF-8
seed bytes with their own frozen fixture. The new reaction dispatch derivation follows the router's
length-prefixed encoding and already has frozen vectors in `keiro/test/Main.hs` from plan 279.

[ADR-29](../adr/0029-typed-domain-decisions-are-successful-additive-command-outcomes.md) makes the
selected Keiki edge the only classification authority and states that rejection and no-op decisions
execute no acceptance callback. The `accepted`/`silent` split relies on this, while ADR-41
governs the separate unconditional reaction effects.

[ADR-30](../adr/0030-declarative-router-selection-is-bounded-target-normalized-and-coordination-versioned.md)
defines the verification vocabulary, the versioned fingerprint, and the frozen target-keyed router
identity that this plan mirrors for processes, and explains why routers normalize output while a
pure reaction need not.

[ADR-39](../adr/0039-foreground-timer-resume-uses-expiring-token-ownership.md) reserves guarded
dead-timer claims for foreground consumers; the generated fire function uses only the ordinary
worker path and never mutates a token-bearing row.


### Validation findings for IR-39


The request fits the DSL. Its three requested shapes (multiple typed inputs with guarded arms,
optional and multiple timers, and generated executable wiring) are all closed, checkable subsets of
what `Keiro.ProcessManager` already executes, and none requires an effectful seam inside the
process. The router precedent shows the toolchain can carry a checked model through canonical
identity, generation, ledger, harness, diff, and coordination impact.

Four gaps shaped the design; the runtime portions are now delivered by plan 279. First,
`handle` today receives only the input, so state-dependent fan-out has no sound home; the
`accepted`-arm design routes it through the saga command path that is already hydrated, retried,
and durable, through the delivered additive reaction runner. Second, positional dispatch identity cannot
survive conditional or reordered dispatch lists, so reaction-form processes need the target-keyed
derivation now provided by the runtime, and the DSL must classify legacy-to-reaction migration
as breaking. Same-target
occurrence is still positional within one target: swapping two commands to that target or changing
a binding reuses ids for different actions. A version bump does not repair this; rollout must drain
old source deliveries, pending timers, partial fan-out, and permitted historical replays before
activating changed semantics. Test this limitation explicitly and never include version in the seed. Third, binding
types are not checked today, so typed mappings are a genuine new checker responsibility. Fourth,
one worker-wide attempt ceiling means per-timer ceilings cannot be honored, so the policy moves to
the process level. One more finding shapes the plan: opening the candidate moves the authoring
default to Language 6 for every `keiro-dsl new` skeleton, which is intended by the registry design
but must be carried through the frozen skeleton corpus, the baseline roles, and the authoring
guide in the same milestone.


## Plan of Work


The completed [plan 279](279-harden-process-manager-reaction-apis-before-dsl-generation.md) supplies the runtime. This plan retains seven milestone labels: M0 has accepted its evidence;
M1 and M2 build the language surface and checker; M3 proves a minimal generated worker against
the supported runtime; M4 extends generation and conformance; M5 adds evolution diagnostics; and M6 documents and closes the
DSL work. Runtime feasibility, implementation, and runtime documentation are owned exclusively by
the prerequisite. Each implementation milestone ends in a passing build and a committed state.


### The Language 6 process notation this plan introduces


The complete reaction form is shown once here so every milestone refers to the same text. The
example is the escalation process from `jitsurei/src/Jitsurei/EscalationProcess.hs`, rewritten.

```text
language keiro-dsl 6
context incident-response

id   IncidentId prefix=inc
enum Severity { Sev1="sev1" Sev2="sev2" Sev3="sev3" }

process IncidentEscalation
  name "incident-escalation"
  reactions version 1
  input IncidentReported { incidentId:IncidentId severity:Severity raisedAt:Time }
  input ResponderAcked   { incidentId:IncidentId ackedAt:Time }
  input IncidentNoted    { incidentId:IncidentId }
  correlate input.incidentId via idText
  saga Escalation category "escalation"
  target Incident
  projections [ ]

  on IncidentReported
    when input.severity == Severity.Sev1
      advance NoteRaised { incidentId }
      schedule escalation fireAt input.raisedAt + 5m { incidentId severity }
    otherwise
      advance NoteRaised { incidentId }
      schedule escalation fireAt input.raisedAt + 60m { incidentId severity }

  on ResponderAcked
    advance NoteAcknowledged { incidentId }
      accepted
        dispatch Incident@input.incidentId AcknowledgeIncident { incidentId }
          on-appended AckOk ; on-duplicate AckOk ; on-failed Retry
        cancel escalation
      silent no-action

  on IncidentNoted
    no-action

  dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId, targetStreamName, occurrence)
  rejected => halt
  poison => halt

  timers max-attempts 5 dead-letter "escalation timer exceeded ceiling"

  timer escalation
    id uuidv5 "incident-escalation-timer:" <> correlationId
    payload { kind="escalation" incidentId:IncidentId severity:Severity }
    fire dispatch Incident@correlationId EscalateIncident { incidentId }
      fired-event-id uuidv5 "incident-escalation-fired:" <> correlationId
      on-ok Fired ; on-reject Fired ; on-ambiguous Retry ; on-error Retry ; not-mine Retry
    decode unknown-status => Cancelled
```

Reading it: `reactions version 1` opens the reaction body and is the marker that Language 6 gates.
Each `input` declares one typed variant; the correlate field must exist in every variant with one
type. Each input variant name must be unique. Each `on` block names exactly one variant and holds either a single unconditional arm, or
ordered `when` arms ending in `otherwise`, or `no-action`. An arm holds at most one `advance`,
followed by follow-ups in source order within the timer and dispatch phases: `dispatch` (unchanged syntax), `schedule <timer> [once]
fireAt input.<Time field> + <window> { bindings }`, and `cancel <timer>`. Follow-ups written directly
in the arm run regardless of the saga decision because they depend only on the input. Follow-ups
written under `accepted` run only when the saga accepted the advance with at least one event, and
the `silent no-action` line acknowledges that rejection, no-op, and eventless outcomes execute
none of that accepted block. Sibling unconditional follow-ups still run. The selected list is
unconditional follow-ups followed by accepted-only follow-ups, regardless of their textual nesting;
timer statements execute first in their relative order, then target commands in their relative
attempt order. This does not guarantee target commit order across retries or concurrent deliveries.
`timers max-attempts N dead-letter "..."` is required exactly when the process declares a
timer. A `timer` block declares a typed payload shape: quoted fields are constants emitted by every
schedule, typed fields must be bound at every schedule site. The timer's `fireAt` moved to the
schedule site because different variants carry different injected timestamps. A timer-free process
simply has no `timers` policy and no `timer` block, and a reaction may schedule nothing.

Keep the spelling `silent no-action` for the candidate, but define its scope as the `accepted`
block's silent alternative, never the entire enclosing arm. Before implementing M1, use this
mixed-effects fragment as the parser and documentation example. It assumes the input, saga,
target and escalation timer declarations in the complete notation above; `NoteAcknowledged`
has both an eventful accepting transition and a typed silent transition in the fixture.

```text
  on ResponderAcked
    advance NoteAcknowledged { incidentId }
      accepted
        dispatch Incident@input.incidentId AcknowledgeIncident { incidentId }
          on-appended AckOk ; on-duplicate AckOk ; on-failed Retry
      silent no-action
    cancel escalation
```

On first eventful acceptance, the saga event and unconditional cancellation commit together,
then the accepted dispatch is attempted. On a silent decision with no concurrent accepted witness,
the cancellation still executes in a separate timer transaction, but the accepted dispatch does
not run. On accepted redelivery, the runtime recovers the witness, skips cancellation SQL entirely,
and retries the accepted dispatch under the same deterministic target id. If a previous silent
delivery later accepts after saga progress, it follows the first-acceptance path. These outcomes
are required fixture assertions, not merely documentation. A whole-arm `no-action` instead lowers
to `NoAdvance []` and has no effects. No new grammar keyword or renamed construct is introduced
by this clarification; copy this explanation into the authoring guide in M6.


### Milestone 0: accept the hardened runtime prerequisite


Completed on 2026-09-14. The following is the accepted gate and a regression check if the runtime
changes before implementation resumes; M1 is the next unfinished milestone.

Read the completed [plan 279](279-harden-process-manager-reaction-apis-before-dsl-generation.md) and its Outcomes, validation transcript, public API, and runtime ADR.
It must demonstrate accepted-witness recovery for multi-event commands, post-conflict decisions,
same-source concurrency, silent redelivery, partial target recovery, timer rollback versus
post-commit persistence, frozen identities, and a handwritten consumer with no DSL dependency.
Do not count existing legacy tests or an unimplemented plan as completion.

Run the prerequisite's focused reaction tests from Concrete Steps and confirm they execute a
nonzero number of examples. Check that the separate `Keiro.ProcessManager.Reaction` module exports
its documented API and that `Keiro.Timer` exports `cancelTimerTx`. Record the runtime ADR link and
actual signatures here. If an implementation gap appears, resolve it in the prerequisite before
starting grammar work; the scaffolder must not implement deduplication or transaction logic itself.

Confirm `LanguageVersion.hs` still has no competing active candidate before opening Language 6.
Language registration is owned by this plan, not by the runtime prerequisite.

Prerequisite evidence accepted on 2026-09-14: the runtime ADR is
[ADR-41](../adr/0041-process-manager-reactions-use-accepted-witnesses-and-target-keyed-recovery.md).
`Keiro.ProcessManager.Reaction` exports the following concrete model:

```haskell
data ReactionPlan ci targetCi
  = NoAdvance [FollowUp targetCi]
  | AdvanceReaction
      { command :: ci
      , followUps :: [FollowUp targetCi]
      , onAccepted :: [FollowUp targetCi]
      }

data FollowUp targetCi
  = FollowDispatch (PMCommand targetCi)
  | FollowSchedule ScheduleMode TimerRequest
  | FollowCancel TimerId

data ScheduleMode = Rearm | Once

data ReactionStateResult target co rejection noOp
  = ReactionNotAdvanced
  | ReactionEvaluated (DomainCommandOutcome target co rejection noOp)
  | ReactionDuplicate EventId

data ReactionTimerEffects = ReactionTimerEffects
  { statementsCommitted :: Int
  , onceInserted :: Int
  , timersCancelled :: Int
  }

data ReactionError
  = ReactionCommandFailed CommandError
  | ReactionWitnessMissing StreamName EventId
  | ReactionWitnessUndecodable StreamName EventId

data ReactiveProcessManagerResult managerTarget co rejection noOp commandTarget =
  ReactiveProcessManagerResult
    { managerResult :: ReactionStateResult managerTarget co rejection noOp
    , commandResults :: [PMCommandResult commandTarget]
    , timerEffects :: ReactionTimerEffects
    }

data ReactiveProcessManager input phi rs s ci co targetPhi targetRs targetState targetCi targetCo rejection noOp =
  ReactiveProcessManager
    { name :: Text
    , correlate :: input -> Text
    , sagaHandler :: DomainCommandHandler phi rs s ci co rejection noOp
    , streamFor :: Text -> Stream (EventStream phi rs s ci co)
    , targetEventStream :: ValidatedEventStream targetPhi targetRs targetState targetCi targetCo
    , targetProjections :: Stream targetCi -> [InlineProjection targetCo]
    , react :: input -> ReactionPlan ci targetCi
    }
```

With the module's `HasCallStack`, Effectful store/resource, `BoolAlg`, and output-equality
constraints, its public functions have these exact argument and result shapes:

```haskell
runReactiveProcessManagerOnce
  :: RunCommandOptions
  -> ReactiveProcessManager input phi rs s ci co targetPhi targetRs targetState targetCi targetCo rejection noOp
  -> RecordedEvent
  -> input
  -> Eff es
       (Either ReactionError
         (ReactiveProcessManagerResult
           (EventStream phi rs s ci co)
           co rejection noOp
           (EventStream targetPhi targetRs targetState targetCi targetCo)))

runReactiveProcessManagerWorkerWith
  :: WorkerOptions es msg
  -> RunCommandOptions
  -> ReactiveProcessManager input phi rs s ci co targetPhi targetRs targetState targetCi targetCo rejection noOp
  -> Adapter es msg
  -> (msg -> Maybe (RecordedEvent, input))
  -> Eff es ()

runReactiveProcessManagerWorker
  :: RunCommandOptions
  -> ReactiveProcessManager input phi rs s ci co targetPhi targetRs targetState targetCi targetCo rejection noOp
  -> Adapter es msg
  -> (msg -> Maybe (RecordedEvent, input))
  -> Eff es ()

deterministicReactionCommandId
  :: Text -> Text -> EventId -> StreamName -> Int -> EventId

cancelTimerTx :: TimerId -> Tx.Transaction Bool
```

The frozen reaction UUIDs are `5a89007a-a634-58bf-8002-5ea7843155f2` for the ASCII
fixture and `ca7f7bd8-2b54-508f-a542-1e24da394d95` for the Unicode fixture. The
handwritten consumer is `keiro/test/ReactionExample.hs` and has no `keiro-dsl` dependency.

Two planned measurements were accepted with narrower executable evidence rather than new public
instrumentation: witness tests persisted and recovered depths 256, 1024, and 4096 but did not
expose store read/decode counters or mutate a witness concurrently after the ceiling capture; the
finite ceiling and one-witness decode are established by the private implementation and review.
Fan-out tests held the saga stream at two events across 8, 32, and 128 commands rather than adding
a saga-hydration counter to the public store effect. Milestone 4's generated conformance still owns
the plan's direct hydration instrumentation requirement. No runtime signature, persistence schema,
legacy identity, or DSL surface deviated from the prerequisite design.

`Keiro.Dsl.LanguageVersion` still contains no Language 6 registry row and selects no active
`CandidateLanguage`; opening the candidate remains Milestone 1 work.


### Milestone 1: candidate Language 6 and the reaction grammar


The goal is that `keiro-dsl parse` accepts the notation above under `language keiro-dsl 6`, refuses
it under Language 5 at the `reactions` marker with `LanguageFeatureRequiresVersion`, round-trips it
through the pretty-printer, and leaves every Language 1 through 5 fixture byte-identical.

In `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` add `version6`, a `profileV5` syntax profile equal to
`profileV4` plus the new constructor `ProcessReactionSyntax` of `LanguageFeature`, and the registry
row `LanguageDefinition version6 (Just version5) LanguageBodyParserV2 profileV5 runtimeProfileV4
Candidate CandidateLanguage`. Keep Language 5 `Stable PublishedLanguage`. Update
`languageFeatureMinimumVersion` consumers only through the registry; no textual list may be added.

In `keiro-dsl/src/Keiro/Dsl/Grammar.hs` replace the three legacy fields on `ProcessNode` with
`body :: !ProcessBody`, where `data ProcessBody = LegacyProcessBody !InputDecl !HandleNode !TimerNode
| ReactionProcessBody !ReactionBody`. Add the reaction types listed in Interfaces and Dependencies.
Give `IdExpr`, `FireNode`, `DispatchNode`, and `FieldBinding` no new fields; reuse them.

In `keiro-dsl/src/Keiro/Dsl/Parser/Coordination.hs` change `pProcess` to take the `FrontendContext`
(update its single call site in `keiro-dsl/src/Keiro/Dsl/Parser/Document.hs`). After `name`, try the
reaction body: parse `reactions` with `withOwnedSpan`, call
`requireLanguageFeatureAt context ProcessReactionSyntax (spanOf marker)`, then `version`, one or more
`input` declarations, `correlate`, `saga`, `target`, `projections`, one or more `on` blocks, the
reaction dispatch-id line (`pFixedDispatchIdLine ["name","correlationId","sourceEventId",
"targetStreamName","occurrence"]`), `rejected`, `poison`, the optional `timers` policy, and zero or
more `timer` blocks in the payload-typed form. Otherwise fall through to the existing legacy body
unchanged. Guards use `pExpr context` from `keiro-dsl/src/Keiro/Dsl/Parser/Expression.hs`; the
`input.` prefix parses as an `EPath` with `UnqualifiedRoot`, exactly as `row.` does for routers, and
is interpreted by the checker. `when`, `otherwise`, `accepted`, `silent`, `no-action`, `schedule`,
`cancel`, `once`, `reactions`, and `timers` become contextual keywords recognized only in their
grammatical position, following the `outcome` precedent in
`docs/plans/233-gate-the-outcome-reserved-words-on-the-language-5-syntax-profile.md`; do not add
them to `reservedWords` in `keiro-dsl/src/Keiro/Dsl/Parser/Core.hs`.

In `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` extend `docProcess` to render both bodies and keep
`renderHandleSurface` and `renderTimerPayloadSurface` for the legacy body; add
`renderReactionSurface :: ReactionBody -> Text` for diff. Update `Skeleton.hs` so `new process`
emits the reaction form under the authoring language and keep the frozen Language 4 skeleton corpus
untouched (it is listed as `frozen` in `keiro-dsl/test/conformance-corpus-manifest.txt`).

Add the fixtures `keiro-dsl/test/fixtures/process-reactions.keiro` (two input variants, a guarded
`on` with `otherwise`, a `no-action` block, and a second timer-free process in the same file),
`process-timers.keiro` (two named timers with distinct prefixes, one `schedule once`, a `cancel`,
and a payload with a typed input-derived field), and `process-state-authority.keiro` (the
escalation example above). Add a Language 5 twin of the first fixture that must fail at the
`reactions` marker. Add a `FeatureCase ProcessReactionSyntax "reactions" processReactionFeatureBody`
to `keiro-dsl/test/Keiro/Dsl/FrontendProfiles.hs` and the constructor to `allFeatures`. Update
`keiro-dsl/test/conformance-baseline.json` to `authoringLanguageVersion: 6`,
`primaryLanguageVersions: [4, 5, 6]`, and re-admit the `candidate-primary` role in
`ConformanceBaseline.hs` with the rule that a candidate-primary suite must name the current
authoring language. Extend the `describe "process/timer (EP-3)"` block in `keiro-dsl/test/Main.hs`
with parse, round-trip, and language-gate examples for the three fixtures.

Acceptance: `cabal run -v0 keiro-dsl -- parse keiro-dsl/test/fixtures/process-state-authority.keiro`
prints the spec; the Language 5 twin fails with `LanguageFeatureRequiresVersion` at the
`reactions` line; `cabal test keiro-dsl:keiro-dsl-test` passes; and `just conformance-corpus-policy`
reports zero drift because no generated byte changed.


### Milestone 2: the checked reaction model and diagnostics


The goal is that `keiro-dsl check` accepts the three positive fixtures and rejects each negative
fixture with one source-local diagnostic, and that the checked model carries everything the
generator and diff need.

Create `keiro-dsl/src/Keiro/Dsl/ProcessReaction.hs` modelled on `RouterSelection.hs`. Its entry
point `checkProcessReaction :: EffectiveLanguageContract -> TypeGraph -> Spec -> ProcessNode ->
Either (NonEmpty ProcessReactionDiagnostic) CheckedProcessReaction` resolves, for every input
variant, each field to a `ResolvedAggregateType` through the same vocabulary as
`nameTypeExpr` in `Validate.hs` (`Text` for a bare field, `Int`, `Integer`, `Bool`, `Natural`,
`Time`, and `TRef` for declared ids and enums) using `resolveAggregateType` from
`keiro-dsl/src/Keiro/Dsl/AggregateType.hs`. It then resolves each binding on an advance, dispatch,
fire, or schedule to the target field's type through `inferAggregateFieldType` for aggregate command
fields and the declared payload type for timer payload fields, and reports
`ProcessBindingTypeMismatch` when they differ. Guards resolve every `input.<field>` path against the
arm's variant, every comparison to two operands of one type, ordering comparisons only on numeric,
`Time`, or `Text` operands, and qualified literals (`Severity.Sev1`) only against a declared enum;
a `reg.`, `cmd.`, `saga.`, or unqualified root reports `ProcessStateAccessUnsupported`. Totality
rules also report `ProcessReactionUnknownInput` for undeclared `on` variants,
`ProcessInputDuplicateDeclaration` for duplicate input declarations, `ProcessTimerDuplicateName`
for duplicate timer names, and `ProcessReactionGuardNotBoolean` for non-Boolean guards. Add a
negative fixture for each. The specified totality rules report `ProcessReactionInputUnhandled` for a variant without an `on` block,
`ProcessReactionDuplicateInput` for two blocks naming one variant,
`ProcessReactionOtherwiseMissing` for `when` arms without a terminal `otherwise`, and
`ProcessReactionOtherwiseUnreachable` for an `otherwise` that is not last. Identity rules report
`ProcessTimerPrefixCollision` when two timer id prefixes or two fired-event prefixes collide within
the spec, `ProcessScheduleUnknownTimer` and `ProcessCancelUnknownTimer` for undeclared names,
`ProcessSchedulePayloadIncomplete` when a typed payload field is unbound at a schedule site,
`ProcessTimerPolicyMissing` when a timer exists without the process-level policy (and
`ProcessTimerPolicyUnused` for the reverse), and `ProcessAcceptedArmRequiresEvent` when an
`accepted` block is attached to an advance whose accepting saga transitions include an eventless
one; `ProcessSilentArmMissing` fires when `accepted` is present without `silent no-action`. The
existing rules for the fire disposition table, `not-mine`, `on-ambiguous`, `decode unknown-status`,
the saga category, and the runtime-owned id fields apply unchanged to reaction timers.

For saga transitions implemented by a hand-owned hole, static syntax cannot prove an accepted
non-empty event batch. Report `ProcessAcceptedArmUnverified` for `accepted` against such a command; do not report its acceptance behavior as generated-declarative.

The checked model records, per input variant, the ordered arms with their checked guard, the
resolved advance, and follow-ups; per timer, the resolved payload shape; and a canonical rendering
that distinguishes unconditional and accepted-only lists and their respective order. The runtime
concatenates these lists before extracting timer and dispatch phases; retain that boundary in the
checked model and harness facts so moving an effect into or out of `accepted` changes the
fingerprint. This canonical rendering is the input
that `processReactionFingerprint` hashes with SHA-256 exactly as `routerSelectionFingerprint`
does, excluding locations, comments, and the declared version. Add every new code to
`DiagnosticCode` in `Validate.hs` with an origin classification, call the new checker from
`validateProcess` for the reaction body, and keep the legacy branch's rules unchanged. Extend
`SourceSubject` in `keiro-dsl/src/Keiro/Dsl/SourceIndex.hs` with
`ProcessReactionSubject !Name !Name !Int` (process id, input variant, arm ordinal) and emit exact
spans from the parser so diagnostics and the later source map anchor on the arm. Add a
`processReactions` array to the check report in `keiro-dsl/src/Keiro/Dsl/CheckReport.hs` listing each
process, its verification (`generated-declarative` or `custom-unverified`), its version, its
fingerprint, and its hole obligations.

Add one negative fixture per new code under `keiro-dsl/test/fixtures/process-reactions-*.keiro`
and examples in `keiro-dsl/test/Main.hs` asserting the exact code list. Acceptance: `cabal run -v0
keiro-dsl -- check keiro-dsl/test/fixtures/process-reactions-badmapping.keiro` exits 1 and prints one
`ProcessBindingTypeMismatch` at the binding's line; each positive fixture prints `OK`.


### Milestone 3: prove a generated timer-free worker against the supported runtime API


The runtime implementation and its PostgreSQL tests are delivered by [plan 279](279-harden-process-manager-reaction-apis-before-dsl-generation.md). This milestone
proves that the DSL model lowers to an executable generated worker against that public surface;
do not create another runner,
result family, timer mutation wrapper, witness scanner, or identity derivation in `keiro-dsl`.

A no-advance arm lowers to qualified `Reaction.NoAdvance followUps`. An advancing arm lowers to
`Reaction.AdvanceReaction command unconditional accepted`, with both follow-up lists computed
solely from the typed input. `accepted` means enable a fixed list when the runtime proves acceptance;
it does not inspect the original event batch. `no-action` lowers to an empty no-advance plan.
Schedules map to runtime `Rearm` or `Once`; cancels carry `TimerId`; dispatches carry the existing
`PMCommand`. Keep parsed and runtime constructors qualified because both layers use reaction names.

The runtime selects `unconditional <> accepted` after a non-empty acceptance or recovered witness;
it selects only `unconditional` after a silent decision. Preserve each list's declared order and
never flatten them by textual indentation. Target occurrence numbers count dispatches in the
selected list by physical target stream; timers do not consume occurrences. Lower `silent
no-action` as an empty silent alternative to the accepted block, without discarding unconditional
siblings. Do not promise target commit order from source ordering.

Consume `ReactionStateResult`, `ReactiveProcessManagerResult`, and `ReactionError` directly when
needed. Preserve the runtime distinctions between NotAdvanced, original typed decision, duplicate
witness, command failure, and witness integrity failure. The generator supplies a saga
`DomainCommandHandler` and target validated stream; it does not define another domain-outcome type.
The runtime owns timer transaction phases, counts, target occurrence ids, recovery, and worker
acknowledgement. The generated module only constructs the manager record and binds the decoder.
Import `Keiro.ProcessManager.Reaction` qualified for the manager and runners and
`Keiro.ProcessManager` for `PMCommand` and `WorkerOptions`. Bind the generated worker entry point
to `runReactiveProcessManagerWorkerWith` using `<p>ProcessWorkerOptions`, caller-supplied
`RunCommandOptions`, the generated manager, the caller's adapter, and the typed decoder. For an
adapter carrying `RecordedEvent`, convert successful `decode<P>Input event` results into
`Just (event, input)` and preserve `Nothing` for the runtime poison policy. Do not drive the
detailed once runner in a hand-written worker loop or recreate failure classification.

Move the initial timer-free portion of M4 into this milestone. Add `emitReactionProcessGen` in
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` and generate the input module, process identity and category,
correlation function, one advance with an accepted dispatch, typed versioned decoder hole, manager
record, and `<p>RunProcessWorker` wrapper. Preserve the acyclic module boundary specified below.
Create `keiro-dsl/test/fixtures/process-reactions-minimal.keiro` with one typed input, a saga
command that emits an event, one target command that emits an event, and no timers. Scaffold it
into `keiro-dsl/test/conformance-process-reactions`, register that package in
`keiro-dsl/keiro-dsl.cabal`, and add its candidate-primary baseline and corpus-manifest entries.
Its hand-written `Main.hs` supplies the adapter and assertions; only the decoder hole is filled
by hand in the generated behavior. Do not construct a substitute manager or reaction in the test.

Deliver one recorded source through the generated worker, then deliver it again. Assert one saga
event and one target event carrying the intended command payload after both deliveries, and one
successful acknowledgement per delivery. Assert no timer rows or timer exports. Also call the
generated manager through the public once runner to inspect duplicate results, without replacing
the worker proof. Retain this minimal fixture and package in M4; expand the fixture's contents to
the full `process-reactions.keiro` scenario when broadening coverage and retain its original
acceptance/redelivery assertions. Update the corpus manifest's fixture source at that point.

Acceptance: the scaffolded package compiles and its real PostgreSQL worker test passes acceptance
and duplicate delivery. `just conformance-corpus-policy` remains clean and focused runtime reaction
tests pass. A DSL library build alone is insufficient. Timer lowering and broader guarded-reaction
coverage remain M4 work; do not claim those capabilities verified by this minimal example.


### Milestone 4: generation, holes, harness, and conformance


The goal is that scaffolding a Language 6 process emits a compiling, executable manager and timer
firer with one typed hole, and that three database-backed conformance packages plus a mutation
script prove the generated behavior.

Extend M3's `emitReactionProcessGen` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` and its dispatch on
`ProcessBody`; do not create a second generator. The complete output contract is as follows.
Generate `Input.hs` as `Generated.<C>.<P>.Input`, owning the input sum type and importing
only shared/nominal types. `ProcessHoles.hs` imports that input module. The generated `Process.hs`
imports both modules and re-exports the input sum type (one
constructor per variant with an idiomatic-v2 record whose field types are lowered through the same
renderer as aggregate command records, importing nominal types from the context's `Nominals`
module), the process name, category, worker options, the reaction fingerprint and version, one
`TimerRequest` builder per timer taking the bound payload values, one payload record and
`FromJSON`/`ToJSON` codec per timer, `<process>React :: <Process>Input -> ReactionPlan ...`,
`<process>ProcessManager :: ReactiveProcessManager ...`, `<process>TimerWorkerOptions ::
TimerWorkerOptions` (the process-level ceiling, never the default), and
`<process>FireTimer :: RunCommandOptions -> TimerRow -> Eff es (Maybe EventId)`, which identifies the
timer by recomputing each declared id from the row's correlation id, decodes the payload, builds the
fire command, runs it with the deterministic fired-event id, and applies the disposition table. A timer-free process emits neither timer worker options nor
a fire function, because it has no timer policy or payload cases.
Also export `<process>RunProcessWorker`, accepting `RunCommandOptions` and an `Adapter es
RecordedEvent` and returning `Eff es ()` with the public worker's constraints. It binds the
generated worker options and decoder to `Reaction.runReactiveProcessManagerWorkerWith` as described
in M3, making the decoder hole part of executable wiring. Applications with other message types
can use the public runner with their own message-to-recorded-event adapter.
Guards lower to plain Haskell comparisons on generated types. The correlate function lowers
`via idText` to the nominal's canonical text projection from `Nominals` or the identity for `Text`.
`ProcessHoles.hs` becomes a create-once module that exports `decode<Process>Input ::
RecordedEvent -> Maybe <Process>Input` with a `-- keiro-dsl process-hole contract v1` header and a
body of `error "fill decode<Process>Input"`; the generated module imports it, and scaffold refuses
with a `hole contract drift` message when an existing hole's header version differs from the
current contract instead of overwriting it. The legacy emitters stay byte-identical.

Extend `processHarnessFactValues` in `Harness.hs` with facts for the reaction form: the ownership
(`reactionOwnership = generated-declarative` versus `custom-unverified`), the version and
fingerprint, one fact per arm listing its guard rendering, advance, dispatch commands, schedules,
and cancels, and one fact per timer listing its prefix, payload fields, and fire command. Add a
`process-reaction` row to `ScaffoldRecord` (JSON after the prefix, ignored by older readers) with
the process name, verification, version, fingerprint, and hole obligations, and print the hole
obligation in the scaffold stdout summary. Keep `renderTimerPayloadSurface` for legacy diff.

Extend M3's reactions conformance package and add the timers and state-authority packages following
`keiro-dsl/test/conformance-declarative-router/`. Register the two additions in
`keiro-dsl/keiro-dsl.cabal`, the baseline as `candidate-primary` with
`languageVersion: 6`, and `docs/corpus/keiro-dsl-corpus.md`. `conformance-process-reactions` drives
`process-reactions.keiro`: it fills the decoder hole, runs the generated manager against PostgreSQL
through `Keiro.Test.Postgres`, and asserts the guarded arm selection for two variants, the
`no-action` variant appending nothing while acknowledging, the timer-free process, duplicate
delivery, and partial target success followed by retry. `conformance-process-timers` drives
`process-timers.keiro`: two timers are scheduled from one reaction with distinct ids, a second distinct source event with a later input timestamp keeps the
`schedule once` timer's first deadline while moving the still-scheduled re-arming timer; replay of
either accepted source changes neither deadline, the
dynamic payload field round-trips through the generated codec, `cancel` makes a scheduled row unclaimable, a worker that already claimed a row may still
attempt firing and is made harmless by the target aggregate's state guard,
each firing dispatches its fire command exactly once under the fired-event id, a redelivered firing
is benign, and the ceiling dead-letters. Exercise both schedule modes against existing terminal
rows to prove they are not revived, and cancel an absent id before scheduling it to prove absence
creates no tombstone. Assert `timerEffects` counts committed statements separately from rows
changed, including zero timer effects on accepted replay. `conformance-process-state-authority` drives
`process-state-authority.keiro`: two source events for one incident delivered concurrently
produce accepted-only fan-out that matches the recorded saga events, a silent advance executes no
accepted-only effects, and redelivery after a partial dispatch completes only the missing target.
Add a separate silent arm with unconditional schedule and dispatch effects, and a no-advance arm
with effects: both remain eligible on redelivery, with no accepted-only effects and no saga read
for the no-advance arm. Use a mixed-list fixture to pin unconditional-before-accepted ordering,
timer-before-dispatch phases, and same-target occurrence numbering; assert declared attempt order
without asserting global commit order. Drive the generated worker entry point through an adapter
to check acknowledgement for success, duplicate and typed silence, configured poison handling,
and inherited target failure policy. Add
`keiro-dsl/test/process-reaction-mutation-test.sh` in the style of `process-mutation-test.sh`:
it flips a guard operator, drops a dynamic payload binding, swaps a dispatched command, and changes
a timer prefix, re-scaffolds, and expects the reactions harness or conformance to fail each time.
Add scaling evidence with a small generator bench (`keiro-dsl/bench/process-scaling`) that measures
generated bytes and scaffold time at 8, 32, and 128 dispatches per arm, and a runtime assertion in
the reactions conformance that one uncontended advancing reaction performs one saga hydration regardless of
dispatch count. Use the concrete observation method below; optimistic conflicts legitimately
add hydration attempts. `keiro_command_decision` is a decision attribute and cannot prove a
hydration count.

Add a manual Cabal flag `reaction-hydration-probe`, default False, to `keiro/keiro.cabal`. Only
when enabled, define `KEIRO_REACTION_HYDRATION_PROBE` for CPP in `Keiro.Command` and
`Keiro.ProcessManager.Reaction`. In that build, emit one stderr line at entry to `hydrate`, before
snapshot lookup, containing a fixed `reaction-probe` marker, the operation `hydrate`, and the
resolved physical stream name. Emit a separate `witness` marker at entry to `recoverWitness`.
Use an unambiguous escaped string representation for the stream name and the existing IO effect;
do not use a pure callback with hidden IO, change exported signatures, or add a production metric.
Compile out the marker calls and their imports in the default build. This is opt-in test
instrumentation of the existing execution path, not a replacement command runner.

Add `keiro-dsl/test/process-hydration-test.sh` to run the reactions conformance executable in a
dedicated `--hydration-probe` mode with the flag enabled and capture stderr in a fresh temporary
directory. Add this argument mode to its `Main.hs`; it runs only the sequential measurement cases
through generated managers, with fresh uniquely named saga and target streams per case. Reuse
those streams and the identical source for the accepted-redelivery phase of each case.
Use the normal PostgreSQL fixture, disable snapshots, and seed history before emitting case-start
markers; perform assertion reads after case-end markers. The script counts only probe lines
between those markers, groups by physical stream and operation, and fails if markers are missing
or a case contains unexpected streams. Record raw counts and the case coordinates in its output.
Use existing shell tools for parsing the controlled fixture names; no event-log parser dependency
is needed. Keep target hydration counts and witness-entry counts in separate columns.

At 8, 32, and 128 dispatches, for both same-target and distinct-target cases, first delivery must
record exactly one saga `hydrate` entry and zero saga `witness` entries. Accepted redelivery must
record zero saga hydration entries and one witness entry. A no-advance case must record neither.
Add the same `--hydration-probe` argument mode to the state-authority suite for one forced-conflict
case, and have the script collect that executable's markers in a separate log. Require an additional
saga hydration entry after the synchronized conflict; do not impose the uncontended count on it.
Each marker counts entry into hydration or witness recovery, not SQL pages or decoded events, so
report it as such. Target counts are reported separately and are not added to saga counts.
The existing 256/1024/4096 witness-depth evidence remains distinct from this measurement.
Use `cabal test` with a temporary `--builddir`, `--constraint='keiro +reaction-hydration-probe'`,
`--test-options='--hydration-probe'`, and `--test-show-details=direct` for both named conformance
targets, capturing combined stdout and stderr because Cabal may forward the test process's output.
Run the ordinary uninstrumented conformance after the probe build and assert it emits no probe
markers. Include the probe script in the repository verification gate so the obligation cannot
silently regress into a persisted-event-count assertion.

Acceptance: `cabal test keiro-dsl:keiro-dsl-conformance-process-reactions`,
`keiro-dsl-conformance-process-timers`, and `keiro-dsl-conformance-process-state-authority` pass;
`bash keiro-dsl/test/process-reaction-mutation-test.sh` prints `PASS`; `just
conformance-corpus-policy` passes from a clean tree.


### Milestone 5: evolution diagnostics and migration


The goal is that `keiro-dsl diff` names every reaction, timer, and identity change with the
consequence an operator must act on, that coordination impact covers processes, and that moving a
process from the legacy body to the reaction body is refused unless reviewed.

In `Diff.hs` extend `processPairDiff` to dispatch on both bodies. For two reaction bodies emit
`ProcessReactionAdded` (additive) and `ProcessReactionRemoved` (advisory naming the drain) per
input variant, `ProcessReactionFanOutChanged` (advisory) when an arm's rendered follow-ups differ,
`ProcessReactionGuardChanged` and `ProcessReactionArmsReordered` (advisory) from the arm ordinals,
`ProcessTimerAdded` (additive), `ProcessTimerRemoved` (breaking, because scheduled rows may still
fire), `ProcessTimerIdentityChanged` (breaking) for prefix changes, `ProcessTimerPayloadChanged`
(existing advisory) for shape changes, `ProcessTimerCeilingChanged` (advisory), and
`ProcessReactionVersionDecreased` and `ProcessReactionFingerprintChangedWithoutVersionBump`
(breaking) with `ProcessReactionFingerprintChangedWithVersionBump` (advisory), mirroring the router
codes. For a legacy-to-reaction pair emit `ProcessDispatchIdentityModelChanged` (breaking) with a
message pointing at the drain rule in `docs/user/deploy-ordering.md`, and for reaction-to-legacy
the same code. Extend `CoordinationImpact.hs` with process snapshots and drift beside the router
ones, keeping the existing JSON fields and adding a `process-reaction` ledger row type; report
custom bodies as `custom-unverified` with no invented metadata. Add diff fixtures for reordering with and without a version bump,
conditional dispatch changes, timer payload and identity changes, a version bump, and the
`hospital-surge.keiro` to `hospital-surge-reactions.keiro` migration, with examples in the
`describe "diff"` block of `keiro-dsl/test/Main.hs`. Register every new code's origin and severity.

Acceptance: the same-path scratch-repository commands in Concrete Steps compare each base
against its changed content. The reordered fixture must also increase `reactions version` to
produce an advisory-only exit 0; a twin without a bump must exit 1 for fingerprint drift.
The migration pair lists `ProcessDispatchIdentityModelChanged` as BREAKING and exits 1.


### Milestone 6: documentation, ADR, and closeout


The goal is that a reader can author both example shapes from the documentation alone and that the
repository gate passes. Update `docs/user/typed-spec-toolchain.md` (the Processes and timers
section) with the Language 6 form and every new diagnostic, `docs/user/api-reference.md` with generated-manager usage linked to the prerequisite's existing
`Keiro.ProcessManager.Reaction` and `cancelTimerTx` documentation, `docs/user/deploy-ordering.md` rules 4
and 6 with the reaction version bump and timer removal consequences,
`docs/guides/process-managers-and-timers.md` with a generated timer-free process and the
multi-reaction escalation process, the authoring skill files
`.claude/skills/keiro-dsl-authoring/SKILL.md` (rule 1 now names candidate 6) and `NOTATION.md`
(the process section), `docs/corpus/keiro-dsl-corpus.md`, and `keiro-dsl/CHANGELOG.md` under
`Unreleased`. Record each documentation change with `okf log add` in `docs/user/log.md` and
`docs/guides/log.md`. Extend the runtime ADR created by [plan 279](279-harden-process-manager-reaction-apis-before-dsl-generation.md) with DSL-specific decisions
on input-only guards, checked acceptance ownership, coordination fingerprints, and generated holes.
Preserve its allocated handle and validate strictly; do not create a competing runtime ADR. Read
the local profile and update `docs/adr/log.md` whenever the record's timestamp advances. Update IR-39's `status` and add
the completion entry to `docs/improvement-requests/log.md`. Finish with `just verify`.


## Concrete Steps


Validation-only checks run on 2026-09-10 (these do not substitute for the prerequisite’s new runtime tests):

```bash
cabal test keiro-dsl:keiro-dsl-test --test-options='--match "process/timer"' --test-show-details=direct
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/hospital-surge-inputtype.keiro
```

The first passed with `10 examples, 0 failures`. The second exited 0 with `OK` and two
`ProcessBenignInversion` warnings, confirming the current legacy binding-type gap.
`just conformance-corpus-policy` also passed all 39 corpus entries, reporting
`conformance corpus: ok` with no generated-file drift.

```bash
cabal test keiro:keiro-test --test-options='--match "Keiro.ProcessManager"' --test-show-details=direct
just conformance-corpus-policy
git diff --check
```

The runtime check passed against ephemeral PostgreSQL with `25 examples, 0 failures`, covering
legacy scheduling, deduplication races, worker policies, dead letters, and snapshots. The plan's
required sections and language-tagged fences were also checked, and `git diff --check` passed.
These are focused substrate checks; the absent reaction suites and full `just verify` were not run.

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` inside the Nix
development shell (`nix develop`), which provides `cabal`, `bun`, `okf`, and `just`. An ephemeral
PostgreSQL is started by the test fixtures themselves. The diff scratch repository is disposable
and isolated from this checkout; retain it for inspecting failed comparisons or remove it manually
after review.

Milestone 0 regression checks (prerequisite accepted on 2026-09-14):

```bash
cabal build keiro:tests
cabal test keiro:keiro-test --test-options='--match "Keiro.ProcessManager.Reaction"' --test-show-details=direct
cabal test keiro:keiro-test --test-options='--match "Keiro deterministic id derivation"' --test-show-details=direct
```

The accepted prerequisite recorded 16 reaction examples and 7 deterministic-id examples, all
passing, with its frozen vectors unchanged. These commands must continue to execute nonzero
example counts with zero failures. The handwritten runtime example is `keiro/test/ReactionExample.hs`
and the runtime decision is ADR-41; both already exist. The broader prerequisite results are
recorded in Outcomes & Retrospective. This documentation update does not rerun those suites.

Milestone 1 grammar:

```bash
cabal build keiro-dsl
cabal run -v0 keiro-dsl -- parse keiro-dsl/test/fixtures/process-state-authority.keiro
cabal run -v0 keiro-dsl -- parse keiro-dsl/test/fixtures/process-reactions-language5.keiro
cabal test keiro-dsl:keiro-dsl-test --test-options='--match "process/timer"'
just conformance-corpus-policy
```

The second `parse` must fail with a message containing `LanguageFeatureRequiresVersion` and the
line of `reactions version 1`; the corpus policy must print no drift.

Milestone 2 checks:

```bash
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/process-reactions.keiro
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/process-reactions-badmapping.keiro; echo "exit=$?"
cabal test keiro-dsl:keiro-dsl-test
```

The first prints `OK`; the second prints one line naming `ProcessBindingTypeMismatch` with the
binding's line number and then `exit=1`.

Milestone 3 minimal generated worker:

```bash
cabal build keiro-dsl
cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/process-reactions-minimal.keiro --out keiro-dsl/test/conformance-process-reactions
cabal test keiro-dsl:keiro-dsl-conformance-process-reactions --test-show-details=direct
cabal test keiro:keiro-test --test-options='--match "Keiro.ProcessManager.Reaction"' --test-show-details=direct
just conformance-corpus-policy
```

The generated worker test must execute initial and duplicate delivery against PostgreSQL and
report PASS with exactly one persisted saga event and target event and two acknowledgements.
No hand-written action builder is allowed. The scaffold emits the decoder obligation and the
corpus check reports no drift. These are required M3 results before timer generation begins.

Milestone 4 generation and conformance:

```bash
cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/process-reactions.keiro --out keiro-dsl/test/conformance-process-reactions
cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/process-timers.keiro --out keiro-dsl/test/conformance-process-timers
cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/process-state-authority.keiro --out keiro-dsl/test/conformance-process-state-authority
cabal test keiro-dsl:keiro-dsl-conformance-process-reactions --test-show-details=direct
cabal test keiro-dsl:keiro-dsl-conformance-process-timers --test-show-details=direct
cabal test keiro-dsl:keiro-dsl-conformance-process-state-authority --test-show-details=direct
bash keiro-dsl/test/process-reaction-mutation-test.sh
bash keiro-dsl/test/process-hydration-test.sh
cabal bench keiro-dsl:process-scaling
just conformance-corpus-policy
```

Each scaffold run prints the module dispositions, one `hole:` line naming
`ProcessHoles.hs decode<Process>Input (contract v1)`, and the ledger path. Each conformance run ends
with `process ... conformance: PASS`. The mutation script ends with `PASS: the reaction harness pins
the spec's guards, payloads, commands, and identities`.

Milestone 5 diff:

```bash
cabal build exe:keiro-dsl
reaction_dsl_bin="$(cabal list-bin exe:keiro-dsl)"
reaction_diff_dir="$(mktemp -d "${TMPDIR:-/tmp}/keiro-reaction-diff.XXXXXX")"
git -C "$reaction_diff_dir" init -q
cp keiro-dsl/test/fixtures/process-reactions.keiro "$reaction_diff_dir/reactions.keiro"
cp keiro-dsl/test/fixtures/hospital-surge.keiro "$reaction_diff_dir/migration.keiro"
git -C "$reaction_diff_dir" add reactions.keiro migration.keiro
git -C "$reaction_diff_dir" -c user.name=Conformance -c user.email=conformance@example.invalid commit -qm 'test: establish diff baselines' -m 'ExecPlan: docs/plans/273-make-process-manager-reactions-first-class-in-keiro-dsl.md' -m 'Intention: intention_01m24dv27ze9gak6fc30mhqrsg'
cp keiro-dsl/test/fixtures/process-reactions-reordered.keiro "$reaction_diff_dir/reactions.keiro"
cp keiro-dsl/test/fixtures/hospital-surge-reactions.keiro "$reaction_diff_dir/migration.keiro"
"$reaction_dsl_bin" diff --since HEAD "$reaction_diff_dir/reactions.keiro"
# Expect exit 0: reordered fixture includes a reaction version bump.
"$reaction_dsl_bin" diff --since HEAD "$reaction_diff_dir/migration.keiro"
# Expect exit 1: positional-to-target-keyed migration is breaking.
cabal test keiro-dsl:keiro-dsl-test --test-options='--match "diff"'
```

Milestone 6 closeout (extend the prerequisite's allocated runtime ADR):

```bash
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
just verify
```

Commit after every milestone with a Conventional Commits subject and the trailer
`ExecPlan: docs/plans/273-make-process-manager-reactions-first-class-in-keiro-dsl.md`, adding an
`Intention:` trailer when the frontmatter names one.


## Validation and Acceptance


The plan is complete when each IR-39 acceptance item can be demonstrated as follows.

M3 has its own earlier gate: a scaffolded timer-free process consumes its decoded source through
the generated worker, commits one saga event and one target event, and acknowledges initial and
duplicate delivery without additional appends. M4 must retain those assertions while extending
the same generator and suite. The mixed-effects fragment beside the notation must be covered for
first acceptance, silence with unconditional cancellation, and accepted replay with no timer SQL.
The hydration probe script must report one saga hydration for uncontended first delivery at each
fan-out size, none for accepted replay or no advance, and a separately observed retry hydration
after an induced conflict. Witness entries and target hydration are reported separately.

For item 1, `keiro-dsl/test/conformance-process-reactions/Main.hs` consumes two typed input
variants through the generated input type, and its assertions show the guarded arm chosen for each,
the `no-action` variant acknowledging without any saga or target append, and a process with no
timer block compiling and running; the generated behavior has only the decoder hole; the test driver and assertions are hand-written. For item 2, the timers package schedules two independently named timers from one reaction,
proves the dynamic payload field survives the generated codec, fires both, and exercises re-arm,
first-arm-wins, cancel, redelivery, and the ceiling. For item 3, the negative fixtures each produce
the expected diagnostic code at the offending line (isolated negative fixtures avoid cascading
errors). For item 4, the state-authority package
runs two source events concurrently against one saga and asserts that every accepted-only dispatch corresponds to
a recorded saga event, that the induced optimistic retry produces the post-conflict decision, and
that a silent attempt dispatches no accepted follow-ups, and that silent redelivery has the
explicit non-durable behavior proved by plan 279 and accepted at M0. Same-source concurrency and multi-event acceptance
witness tests are required alongside distinct-source concurrency; unsupported state access is refused by
`ProcessStateAccessUnsupported` and documented. For item 5, the prerequisite runtime tests and this plan's
conformance packages cover duplicate delivery, partial target success then retry, timer rollback
with the append, and timer redelivery, and the mutation script proves that changed guards, dropped
dynamic payload fields, wrong commands, and wrong timer or dispatch identities are caught. For item
6, the diff fixtures exercise reordering, conditional dispatch changes, and timer payload and
identity changes, every existing Language 1 through 5 fixture and hand-owned hole is unchanged, and
the legacy-to-reaction migration is an explicit breaking diagnostic. For item 7, the guide shows a
timer-free process and the multi-reaction escalation process, and the authoring guide distinguishes
the generated body from the decoder hole.

Generated acceptance also pins ADR-41's boundaries: unconditional effects remain eligible after
silence or no advance; the selected effect list puts unconditional entries before accepted-only
entries; timer statements precede target attempts; terminal timer rows are not revived; and timer
statement counts are distinct from changed-row counts. Tests exercise the generated worker wrapper
and its typed decoder through the shared public worker. They must not infer durable silence,
exactly-once target evaluation, or global target commit order from successful event deduplication.

The repository-level proof is `just verify` passing, which includes the full `keiro-dsl:tests`
target, the corpus policy, strict ADR validation, and the user-documentation validation.


## Idempotence and Recovery


Accepted source replay validates the exact saga witness and skips timer SQL while retrying target
fan-out. Missing or undecodable witnesses are integrity failures; do not bypass them in generated
code. Silent and no-advance effects may repeat, and a silent source may later accept after saga
progress. Timer cancellation cannot revoke an already-claimed callback, so target state guards
must make late firing benign. Before migrating an existing manager to reaction identities or
changing same-target command order or payload meaning, drain old source deliveries, incomplete
fan-out, pending timers, and permitted historical replays. A reaction version bump alone does not
make replay safe, and the runtime supplies no positional-id fallback.

Every step is additive and repeatable. Re-running a scaffold over a conformance directory rewrites
only `-- @generated` modules and refuses to overwrite the create-once hole, so a filled decoder is
never lost; if a scaffold refuses with `hole contract drift`, the recorded hole header is older than
the current contract, and the remedy is to update the hole by hand and rerun. The prerequisite's runtime tests create their own ephemeral database and can be rerun freely. If the corpus policy reports
drift after a generator change, run `cabal run -v0 keiro-dsl-corpus-regen -- regenerate --only
<directory>` for the affected suite, review the diff, and commit; never hand-edit a generated file.
If a frozen identity vector in `keiro/test/Main.hs` fails, the prerequisite's derivation moved,
and the fix is in the derivation, not the fixture. Language 6 is a candidate: any grammar mistake
found before publication is corrected in place under the same version number, per ADR-16, and no
Language 7 is allocated for that reason. Every commit leaves the build green; if a milestone must be
abandoned mid-way, revert to the last milestone commit rather than leaving a half-lowered body.

The hydration probe uses its own temporary Cabal build directory and a default-disabled manual
flag, so its instrumented objects cannot be mistaken for ordinary conformance builds. Retain the
temporary logs and printed directory on failure for diagnosis. The probe script must propagate
build and test failures and clean up only its own validated temporary directory on success.


## Interfaces and Dependencies


No new external dependencies are needed; `cryptohash-sha256` (already used by
`RouterSelection.hs`), `aeson`, `uuid`, `hasql-transaction`, and the existing Kiroku, Keiki, and
Shibuya packages suffice.

At the end of Milestone 1, `keiro-dsl/src/Keiro/Dsl/Grammar.hs` exports:

```haskell
data ProcessBody
  = LegacyProcessBody !InputDecl !HandleNode !TimerNode
  | ReactionProcessBody !ReactionBody

data ReactionBody = ReactionBody
  { version :: !Natural, versionLoc :: !Loc,
    inputs :: !(NonEmpty InputDecl),
    reactions :: !(NonEmpty ReactionNode),
    timerPolicy :: !(Maybe TimerPolicy),
    timers :: ![ReactionTimerNode] }

data ReactionNode = ReactionNode { on :: !Name, arms :: !(NonEmpty ReactionArm), loc :: !Loc }
data ReactionArm = ReactionArm { guard :: !ArmGuard, body :: !ArmBody, loc :: !Loc }
data ArmGuard = UnconditionalArm | WhenArm !Expr | OtherwiseArm
data ArmBody = NoAction | ArmActions { advance :: !(Maybe AdvanceReaction), followUps :: ![FollowUp] }
data AdvanceReaction = AdvanceReaction
  { command :: !Name, fields :: ![FieldBinding], accepted :: !(Maybe [FollowUp]), silentNoAction :: !Bool, loc :: !Loc }
data FollowUp = FollowDispatch !DispatchNode | FollowSchedule !ScheduleNode | FollowCancel !Name !Loc
data ScheduleNode = ScheduleNode { timer :: !Name, mode :: !ScheduleMode, fireAt :: !FireAtExpr, bindings :: ![FieldBinding], loc :: !Loc }
data ScheduleMode = ScheduleRearm | ScheduleOnce
data TimerPolicy = TimerPolicy { maxAttempts :: !Int, deadLetter :: !Text, loc :: !Loc }
data ReactionTimerNode = ReactionTimerNode
  { name :: !Name, id :: !IdExpr, payload :: ![PayloadField], fire :: !FireNode, decodeUnknown :: !Name, loc :: !Loc }
data PayloadField = PayloadConstant !Name !Text | PayloadTyped !Name !(Maybe Name)
```

and `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` adds `ProcessReactionSyntax` to `LanguageFeature`
and the Language 6 registry row.

At the end of Milestone 2, `keiro-dsl/src/Keiro/Dsl/ProcessReaction.hs` exports
`CheckedProcessReaction`, `CheckedReactionArm`, `CheckedReactionGuard`, `CheckedFollowUp`,
`CheckedReactionTimer`, `ProcessReactionDiagnosticCode`, `ProcessReactionDiagnostic`,
`checkProcessReaction`, and `processReactionFingerprint :: CheckedProcessReaction -> Text`;
`Validate.hs` adds the diagnostic codes named in Milestone 2 to `DiagnosticCode`; `SourceIndex.hs`
adds `ProcessReactionSubject`; `CheckReport.hs` adds the `processReactions` rows.

Milestone 3 consumes the runtime interfaces owned by [plan 279](279-harden-process-manager-reaction-apis-before-dsl-generation.md):
`ReactiveProcessManager`, `ReactionPlan` with `NoAdvance` and `AdvanceReaction`, `FollowUp`,
`ScheduleMode`, `ReactionStateResult`, `ReactionTimerEffects`, `ReactionError`,
`ReactiveProcessManagerResult`, `deterministicReactionCommandId`,
`runReactiveProcessManagerOnce`, `runReactiveProcessManagerWorkerWith`, and
`runReactiveProcessManagerWorker`. Their delivered shapes are recorded in M0; the generator uses
`Reaction.Rearm` and `Reaction.Once`, and `PMCommand` and `WorkerOptions` remain legacy-module exports.
`ReactionPlan ci targetCi` has no accepted-event callback. `Keiro.Timer.cancelTimerTx` is also
supplied by the prerequisite. Its concrete signatures and handwritten example are the authority;
do not redeclare the runtime model here or in generated code.

At the end of Milestone 4, a scaffolded Language 6 process `<P>` in context `<C>` yields
`Generated.<C>.<P>.Input` owning the input type and
`Generated.<C>.<P>.Process` importing the input and decoder modules and exporting the input sum type, `<p>ProcessName`, `<p>Category`,
`<p>ProcessWorkerOptions`, `<p>ReactionVersion`, `<p>ReactionFingerprint`,
one `<p><Timer>TimerRequest` and `<Timer>Payload` per timer, `<p>React`, `<p>ProcessManager`,
`<p>RunProcessWorker :: RunCommandOptions -> Adapter es RecordedEvent -> Eff es ()`
(with the runtime worker's effect and aggregate constraints), and
`<p>FireTimer` and `<p>TimerWorkerOptions` only when timers exist, plus the create-once `<C>.<P>.ProcessHoles` exporting `decode<P>Input ::
RecordedEvent -> Maybe <P>Input`; `Generated.<C>.<P>.ProcessHarness` keeps
`processHarnessValues :: [(String, String)]`; and the context ledger gains one `process-reaction`
row per process.

M3 delivers the timer-free subset of this interface first: input and decoder modules, process
name and category, worker options, reaction construction, manager value, and worker wrapper. M4
adds the remaining timer and metadata surface without replacing those modules. The opt-in
`reaction-hydration-probe` Cabal flag adds no exported Haskell interface; its markers are a private
test protocol consumed by `keiro-dsl/test/process-hydration-test.sh`.

At the end of Milestone 5, `Diff.hs` emits the codes named in that milestone and
`CoordinationImpact.hs` exports `ProcessReactionSnapshot`, `processReactionSnapshots`, and
`processReactionDrift` alongside the router functions.


## Revision Notes


2026-09-14: Accepted plan 279 as the completed runtime prerequisite. Recorded ADR-41, the concrete
public constructors and runner shapes, frozen identity vectors, full validation evidence, the
public-only handwritten consumer, and the narrower witness/hydration measurement deviations. M0 is
complete; Language 6 registration and every grammar/checker/generator milestone remain pending.

2026-09-10: Added the Decision Log entry that fixes routers as a boundary of this plan rather
than a deliverable, after a discussion asking whether the plan also addresses the router. No
milestone, interface, or acceptance text changed, because the plan already left router grammar
and runtime untouched; the entry makes that scope explicit and names the two extensions that
would require a separate improvement request.

2026-09-10: Validated the plan against the current implementation and recorded that the feature
is absent. Corrected batch/witness recovery, generated and runtime import cycles, timer replay
and crash semantics, hydration evidence, ADR allocation, and diff fixture instructions. Expanded
M0 for same-source races and non-durable silent decisions; no implementation milestone is complete.

2026-09-10: Extracted API hardening into [plan 279](279-harden-process-manager-reaction-apis-before-dsl-generation.md) under its own intention. M0 now accepts that
completed prerequisite, M3 maps checked DSL values to its public API, and runtime ADR/documentation
ownership moved to the prerequisite. Grammar, checking, generation, generated conformance, and DSL
evolution remain here. This supersedes the earlier plan to implement the runtime after grammar.

2026-09-10: Recorded the review and update provenance omitted earlier in this session. The review entry captures the original changes-requested assessment; the revision entry captures the fixes and runtime-plan extraction. Original authorship remains unknown. Harness is recorded as codex; model is gpt-6, as identified by the session instructions. No implementation or acceptance status changed.

2026-09-10: Corrected this session's provenance model from unknown to gpt-6 at the user's request; preserved timestamps, verdicts, and authorship attribution.

2026-09-15: Reconciled the full plan with the completed process-manager runtime at `edd142c1` and
ADR-41. Removed stale prerequisite, cancellation, and ADR-allocation instructions; clarified
unconditional versus accepted-only effects, list and transaction ordering, bounded witness
recovery, timer lifecycle and accounting, target reconciliation, and shared worker wiring.
Extended generated acceptance accordingly, retained M4's outstanding hydration instrumentation,
and kept M1–M6 pending. Runtime test counts are attributed to the prerequisite's recorded run;
this update is documentation-only and changes no runtime architecture.

2026-09-15: Applied the agreed implementation refinements. M3 now delivers and tests the first
generated timer-free worker; M4 extends its existing generator and conformance package. Added a
mixed-effects notation example that pins the block-local meaning of `silent no-action` for
acceptance, silence, and replay. Specified default-disabled hydration and witness entry probes,
isolated builds, measurement cases, expected counts, and a verification script. Updated progress,
milestones, commands, acceptance, recovery, and interface handoffs; no implementation is marked done.
