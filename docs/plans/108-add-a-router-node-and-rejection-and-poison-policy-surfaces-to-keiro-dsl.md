---
id: 108
slug: add-a-router-node-and-rejection-and-poison-policy-surfaces-to-keiro-dsl
title: "Add a router node and rejection and poison policy surfaces to keiro-dsl"
kind: exec-plan
created_at: 2026-07-13T18:56:58Z
intention: "intention_01kxed7haee7ja78qm70cc6qm5"
master_plan: "docs/masterplans/15-harden-and-extend-the-keiro-dsl-toolchain-surfaced-by-the-2026-07-dsl-audit.md"
---

# Add a router node and rejection and poison policy surfaces to keiro-dsl

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The keiro runtime has a first-class stateless coordination primitive — the **Router**
(`keiro/src/Keiro/Router.hs`): for each incoming event it resolves a data-dependent set of
target streams *effectfully* (typically via a read-model query) and dispatches one command
to each target, idempotently. The keiro-dsl notation cannot express it at all. A team that
uses the DSL as its source of truth simply cannot author a router-shaped service, even
though the runtime, its stable target-keyed idempotency ids (MasterPlan 14, EP-97), and
its worker policies (EP-100) are all delivered and documented.

Worse, the policies that EP-100 added — what a process-manager or router worker does with
a rejection-class dispatch failure (`RejectedCommandPolicy`) and with an undecodable
message (`PoisonPolicy`) — are invisible to the DSL. A `.keiro` spec can write
`on-failed deadLetter "reason"` on a dispatch today, but the scaffolder never lowers any
of it: the generated process module carries only a name constant, a timer builder, and a
fire-disposition function. At runtime the worker takes `defaultWorkerOptions`
(`PoisonHalt` / `RejectedHalt`), so **a spec that says "dead-letter this rejection"
produces a service that silently halts instead**. Finally, the generated timer
fire-disposition function lumps `CommandAmbiguous` — a deterministic aggregate-definition
bug — into the generic `on-error` arm with no vocabulary for the author to see or decide
it.

After this plan:

1. A `.keiro` file can declare a `router` node — stable name, source input shape, key
   derivation, a `resolve stable via read-model …` clause naming the effectful seam, the
   target aggregate + command + field bindings, per-target projections, a complete
   dispatch disposition table, and the fixed runtime-owned dispatch-id derivation — and
   `keiro-dsl check` / `scaffold` / the harness all work on it, conformance-tested against
   the live `Keiro.Router`.
2. Both `process` and `router` nodes carry mandatory node-level `rejected => halt |
   deadLetter | skip` and `poison => halt | deadLetter | skip` clauses that the scaffolder
   lowers to a generated `Keiro.ProcessManager.WorkerOptions` value, so the spec's policy
   actually reaches the runtime knob. The validator rejects the contradiction the audit
   found (a per-dispatch `deadLetter` arm under a node-level `halt` policy).
3. The disposition vocabulary acknowledges `CommandAmbiguous`: the timer-fire table gains
   a mandatory explicit `on-ambiguous` arm (with `on-ambiguous Fired` rejected as an
   error — ambiguity is never benign), and node-level policy documentation states that at
   the dispatch level ambiguity is rejection-class and follows the node's `rejected =>`
   policy, with a warning diagnostic when that policy would acknowledge it.

The observable proof: `keiro-dsl check` on the new `incident-paging.keiro` fixture exits
0; mutated copies fail with precise diagnostics; `keiro-dsl scaffold` emits a
firewall-clean generated `Router` module plus a resolver hole; two new conformance suites
(`keiro-dsl-conformance-router-runtime`, `keiro-dsl-conformance-router-full`) compile the
scaffold output against the live `Keiro.Router`/`Keiro.ProcessManager` and pin the lowered
`WorkerOptions`; and a mutation script proves the spec→behaviour link (flipping
`rejected => deadLetter` to `halt` reddens exactly one hand-written assertion).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `Keiro.Dsl.Grammar` — add `RouterNode` (+ `ResolveDecl`, `RouterDispatchNode`,
  `PolicyChoice`), `NRouter` in the node sum, `procRejected`/`procPoison` on
  `ProcessNode`, `onAmbiguous` on `FireDisposition`.
- [ ] M1: `Keiro.Dsl.Parser` — `pRouter` registered in the node parser; mandatory
  `rejected =>`/`poison =>` clauses in `pProcess`; mandatory `on-ambiguous` fire arm;
  mandatory `stable` keyword in `resolve`.
- [ ] M1: `Keiro.Dsl.PrettyPrint` — `docRouter`; render the new process clauses and the
  `on-ambiguous` arm; round-trip property arm for router specs in `test/Main.hs`.
- [ ] M1: update every process-bearing fixture, skeleton, and unit-test source text for
  the new mandatory clauses; author `keiro-dsl/test/fixtures/incident-paging/incident-paging.keiro`.
- [ ] M2: validator rules + new `DiagnosticCode`s (`RouterUnresolvedRef`,
  `RouterKeyFieldUnknown`, `RouterBindingUnscoped`, `RouterCommandUnknown`,
  `RouterReadModelUnverified`, `PolicyContradiction`, `PolicyDeadLetterUnused`,
  `AmbiguousMarkedBenign`, `AmbiguousFollowsRejectedPolicy`) with unit tests via
  `errorCodesOf`.
- [ ] M3: `scaffoldRouter` (Generated `Router` module + `RouterHoles` stub);
  `emitProcessGen` extended with the lowered `WorkerOptions` and the `CommandAmbiguous`
  fire arm; `confirmBenignDuplicate` guidance in both hole modules; firewall +
  determinism tests green; `app/Main.hs` dispatch wired.
- [ ] M4: `harnessRouter` facts module; `processHarnessValues` extended with
  `rejectedPolicy`/`poisonPolicy`/`onAmbiguous`; hand-written expectations in the
  conformance drivers; `router-mutation-test.sh`.
- [ ] M5: `keiro-dsl-conformance-router-runtime` and `keiro-dsl-conformance-router-full`
  suites compiling scaffold output against the live runtime;
  `keiro-dsl-conformance-process-runtime` extended to pin the lowered `WorkerOptions`
  and the ambiguous arm.
- [ ] M6: `Keiro.Dsl.Skeleton` `new router` kind; NOTATION.md router + policy +
  ambiguity sections; diff-interface note recorded for
  docs/plans/103-make-keiro-dsl-diff-sound-over-the-full-decode-and-identity-surface.md.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: The `router` node reuses the process vertical's shapes wherever the runtime
  reuses them (`InputDecl`, `CorrelateDecl` for the key, `FieldBinding`, the
  `DispatchDisposition` table), and introduces new types only where the runtime differs
  (`ResolveDecl` for the effectful seam, `RouterDispatchNode` without a per-dispatch
  target key expression, `PolicyChoice` for the node-level policies).
  Rationale: the runtime `Router` is literally "the stateless sibling of
  `ProcessManager`" (`keiro/src/Keiro/Router.hs:91-99`) — it shares `PMCommand`,
  `PMCommandResult`, `WorkerOptions`, and `decideForFailures`. A bijective notation should
  share exactly what the runtime shares. Date: 2026-07-13
- Decision: The router's dispatch clause is `dispatch-each <Command> { bindings }` with no
  `Target@key` expression, and bindings may reference `input.<field>` and
  `resolved.<field>` (the latter scoped by a `row { … }` declaration on the `resolve`
  clause).
  Rationale: unlike a process dispatch, the router's target streams are not derivable
  from the input — `resolve` returns them effectfully as `[PMCommand targetCi]`. The
  notation therefore describes the per-target command *shape*; the concrete streams are
  the resolver hole's output. Declaring the resolver's row shape gives the validator a
  scope to check `resolved.*` references against. Date: 2026-07-13
- Decision: The `resolve` clause requires the literal keyword `stable`
  (`resolve stable via read-model service_oncall row { responderId }`), and the generated
  resolver-hole documentation restates the union-of-attempts caveat verbatim.
  Rationale: the runtime documents that dispatch ids are keyed by resolved target
  identity, so a drifting resolver makes the cumulative dispatched set the UNION of
  attempt outputs (`Router.hs:10-14,105-111`). This is the router's one
  dangerous-by-default semantic; MP-8 precedent (the timer's `decode unknown-status`
  acknowledgement) is to force the author to write the acknowledgement down.
  Date: 2026-07-13
- Decision: `rejected =>` and `poison =>` are grammar-mandatory on both `process` and
  `router` (a missing clause is a parse error, not a validator default), even though this
  breaks existing `.keiro` fixtures until they are updated in M1.
  Rationale: E2's failure mode is precisely a defaulted policy — the spec's per-dispatch
  `deadLetter` intent silently loses to `defaultWorkerOptions`' `RejectedHalt`. MP-8's
  standing rule ("the dangerous default is forced OFF, explicitly") applies; the same
  choice was made for `max-attempts` in EP-3. Fixture updates are cheap and loud.
  Date: 2026-07-13
- Decision: `CommandAmbiguous` gets an explicit mandatory `on-ambiguous` arm in the
  timer-fire disposition (the table keiro-dsl itself lowers to code), and *documented
  lumping* at the dispatch level (both process and router): dispatch-level ambiguity is
  rejection-class at runtime and follows the node-level `rejected =>` policy, surfaced by
  a Warning when that policy is `deadLetter` or `skip`.
  Rationale: post-MP-14, `isRejectionClass` returns `True` for both `CommandRejected` and
  `CommandAmbiguous{}` (`keiro/src/Keiro/ProcessManager.hs:321-325`), so at the worker
  level the DSL cannot promise a separate ambiguity policy without lying about the
  runtime. But the timer-fire function is DSL-generated code with its own `case`, where an
  explicit arm is honest and cheap. `on-ambiguous Fired` is rejected outright because
  `CommandAmbiguous` "is a deterministic aggregate-definition bug rather than a business
  rejection" (`keiro/src/Keiro/Command.hs:157-162`) — there is no benign reading, unlike
  `CommandRejected` after `confirmBenignDuplicate`. The safe timer arm is `Retry`: the
  fire returns `Nothing`, the attempts ceiling trips, and the timer dead-letters with the
  spec's declared reason — a loud, durable witness. Date: 2026-07-13
- Decision: The lowered `WorkerOptions` is emitted as a *fully constructed* record (all
  four fields written out), with `transientRetryDelay = RetryDelay 5` annotated as
  matching `defaultWorkerOptions` and `metrics = Nothing` annotated as hole-kind 8
  (runtime config, override at the call site). When the spec's `poison` policy is
  `deadLetter` or `skip`, the generated value takes the poison callback as a parameter
  (`(Envelope msg -> Eff es ()) -> WorkerOptions es msg`); when it is `halt` there is no
  parameter.
  Rationale: full construction avoids record-update ambiguity against keiro's
  duplicate-field-name records and makes the conformance pin trivial; the poison
  callback is behaviour-bearing (it decides what "skip"/"dead-letter" *records*), so it
  must be caller-supplied, not generated as a silent no-op. `transientRetryDelay` and
  `metrics` are runtime tuning (hole-kind 8), deliberately not spec surface.
  Date: 2026-07-13
- Decision: Diagnostic granularity for the policy-consistency family: an Error when any
  dispatch declares `on-failed deadLetter …` and the node policy is not
  `rejected => deadLetter` (`PolicyContradiction`); an Error when two dispatches of one
  node declare different rejection-class dispositions (the runtime decides per node, via
  one `decideForFailures` call — per-dispatch divergence is unimplementable); a Warning
  when the node declares `rejected => deadLetter` but no dispatch arm mentions
  `deadLetter` (`PolicyDeadLetterUnused`).
  Rationale: `decideForFailures` takes the whole failure group and one
  `RejectedCommandPolicy` (`ProcessManager.hs:333-395`); the DSL must not suggest
  per-dispatch policy the runtime cannot honor. Date: 2026-07-13
- Decision: This plan edits only the `keiro-dsl` package, its tests, and
  `agents/skills/keiro-dsl-authoring/NOTATION.md` (the minimal, accurate notation
  section for its own surface). The holistic skill/corpus refresh and cold-start re-proof
  belong to docs/plans/110-align-keiro-dsl-with-the-safe-apis-and-refresh-the-authoring-skill-and-corpus.md.
  Rationale: MasterPlan 15 scope rule; per-vertical NOTATION.md additions are part of
  MP-8's per-vertical template, but the cross-cutting documentation pass is 110's job.
  Date: 2026-07-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge. It names every file by full repository-relative
path and embeds the runtime surface this plan binds to, so the plan is executable from
this file and the working tree alone.

### Standing assumption

Keiro MasterPlan 14
(`docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md`)
— including EP-97's stable router idempotency keys (target-stream-keyed
`deterministicRouterCommandId`) and EP-100's rejection policies plus durable dispatch
dead-letter records — is implemented **before** this plan begins. Everything quoted below
from `keiro/src/Keiro/{Router,ProcessManager,DeadLetter}.hs` is the post-MP-14 runtime and
was verified against those sources on 2026-07-13. This plan changes **only** the
`keiro-dsl` package (`keiro-dsl/src/Keiro/Dsl/*.hs`, `keiro-dsl/app/Main.hs`,
`keiro-dsl/keiro-dsl.cabal`, `keiro-dsl/test/**`) and the authoring-skill notation file
`agents/skills/keiro-dsl-authoring/NOTATION.md`. It never touches a runtime package.

### What keiro-dsl is (one paragraph)

`keiro-dsl` (package directory `keiro-dsl/`) is a toolchain over a typed specification of
a keiro service: a plain-text `.keiro` file in a terse notation. `keiro-dsl check` rejects
a spec with missing or dangerous decisions before any Haskell exists; `keiro-dsl scaffold`
emits the *symbol-free deterministic layer* into `-- @generated` modules (overwritten on
every run) plus precisely-typed **holes** in hand-owned modules (created only if absent);
a spec-derived **harness** pins the filled behaviour; `keiro-dsl diff --since <ref>`
classifies spec changes as additive or breaking. The **firewall invariant** is the tested
guarantee that no `-- @generated` line contains a keiki symbolic operator (the transducer
logic is always an agent-written hole). The engine modules this plan extends are
`keiro-dsl/src/Keiro/Dsl/Grammar.hs` (the AST; node sum `data Node` at lines 793-803),
`Parser.hs` (megaparsec; `pProcess` at line 884), `PrettyPrint.hs` (`docNode` dispatch at
line 66), `Validate.hs` (`validateNode` dispatch at lines 114-124, `DiagnosticCode` sum at
line 32), `Scaffold.hs` (`ScaffoldModule`/`ModuleKind`, `Context`, `genPrefixFor`/
`holePrefixFor`, `forbiddenOperators` at line 131, `scaffoldProcess` at line 652),
`Harness.hs` (`harnessProcess` at line 52), `Skeleton.hs` (`skeletonFor`), and the CLI
`keiro-dsl/app/Main.hs` (per-node scaffold dispatch around line 122-124). MasterPlan 8
(`docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md`) defines the
per-vertical template this plan instantiates; the closest sibling vertical is the process
manager plan `docs/plans/61-keiro-dsl-process-manager-and-durable-timer-nodes.md`.

### Terms of art

- **Router.** The keiro runtime's stateless, content-based router (Enterprise Integration
  Patterns "content-based router" / "recipient list"): for each incoming event it
  *effectfully* computes a set of target streams (usually by querying a read model) and
  dispatches one command to each. It has no state stream of its own — that is the
  difference from a process manager.
- **Process manager (saga).** The stateful coordinator: reacts to an event by advancing
  its own private event stream, dispatching commands to target aggregates, and scheduling
  timers, crash-safely. The DSL's existing `process` node maps to it.
- **Dispatch.** One command sent to one target aggregate stream as part of a router or
  process-manager reaction.
- **Rejection-class failure.** A dispatch failure whose `CommandError` is `CommandRejected`
  (no transducer edge matched — often a business "no") or `CommandAmbiguous` (two or more
  edges matched — a definition bug). The worker groups these and applies one policy.
- **Poison message.** A message the worker's decoder cannot parse at all.
- **Dead letter.** A durable record of a failure, written instead of halting: either a
  keiro-owned `DispatchDeadLetter` row (a rejected dispatch, EP-100) or a Kiroku-owned
  `kiroku.dead_letters` row (a source event whose retries exhausted).
- **Disposition.** The explicit table mapping each outcome of a dispatch or timer fire to
  an action (`AckOk`/`Retry`/`DeadLetter` for dispatches; `Fired`/`Retry` for timer
  fires). The DSL forces these tables to be complete so benign inversions (a "failure"
  that means success) are conscious decisions.
- **Hole / hole-kinds.** A precisely-typed gap the scaffolder leaves for a human or agent
  (created once, never overwritten). MP-8's closed set of eight hole-kinds classifies
  them; the ones used here are hole-kind 1 (derivation), 2 (disposition), 3 (mapping),
  4 (field-source), 5 (cross-node coupling), 7 (explicit optionality), and 8 (runtime
  config).

### The runtime surface, embedded (verify against the named files)

**The Router record** (`keiro/src/Keiro/Router.hs:118-134`):

```haskell
data Router input targetPhi targetRs targetState targetCi targetCo es = Router
    { name :: !Text
    -- ^ Stable identifier; part of every dispatched command's deterministic id.
    , key :: !(input -> Text)
    -- ^ Correlation string for the source event (e.g. the transaction id).
    , resolve :: !(input -> Eff es [PMCommand targetCi])
    -- ^ The effectful seam: compute the data-dependent target set, typically
    --   @runQuery readModel q@.
    , targetEventStream :: !(ValidatedEventStream targetPhi targetRs targetState targetCi targetCo)
    -- ^ The aggregate every resolved command is dispatched to.
    , targetProjections :: !(Stream targetCi -> [InlineProjection targetCo])
    -- ^ Inline projections run in the same transaction as each dispatch. [] = append-only.
    }
```

`newtype RouterResult target = RouterResult { commandResults :: [PMCommandResult target] }`
(`Router.hs:143-146`) — one `PMCommandResult` per resolved target, no manager-state result
because there is no state stream. Runners: `runRouterOnce` (single event),
`runRouterWorker = runRouterWorkerWith defaultWorkerOptions`, and

```haskell
runRouterWorkerWith ::
    ( HasCallStack, IOE :> es, Store :> es, Error StoreError :> es
    , BoolAlg targetPhi (RegFile targetRs, targetCi), Eq targetCo ) =>
    WorkerOptions es msg ->
    RunCommandOptions ->
    Router input targetPhi targetRs targetState targetCi targetCo es ->
    Adapter es msg ->
    (msg -> Maybe (RecordedEvent, input)) ->
    Eff es ()
```

**The idempotency key (EP-97).** Every dispatched command is appended under

```haskell
deterministicRouterCommandId :: Text -> Text -> EventId -> StreamName -> Int -> EventId
-- (router name, key input, source event id, resolved target stream name, occurrence)
```

(`Router.hs:165-188`) — a v5 UUID whose name encodes every field length-prefixed (no
delimiter ambiguity). The **occurrence** is the index among commands in the same resolve
batch that address the same target stream (0 for the first). Unlike the process manager's
positional `deterministicCommandId`, this id is keyed by *target identity*, because
`resolve` is effectful and a redelivery may see the same targets reordered. A transitional
probe for pre-EP-97 positional ids remains in `runRouterOnce` (`Router.hs:249-270`);
it is runtime-internal and invisible to the DSL.

**The resolver-stability caveat** (module header, `Router.hs:10-14`, and the record doc at
`:105-111`): dispatch is idempotent per resolved target identity, so a redelivery
deduplicates every target it resolves *again* — but a target resolved only on an earlier
attempt keeps its immutable dispatch, and a newly resolved target dispatches on the later
attempt. **The cumulative dispatched set is the union of attempt outputs.** Callers that
require one exact recipient set must keep `resolve` stable for a given source event.

**The worker ack ladder** (both workers, `Router.hs:288-325` and
`ProcessManager.hs:19-24`): an undecodable message follows `PoisonPolicy`; if every result
is `PMCommandAppended`/`PMCommandDuplicate` the message finalizes `AckOk`; transient
failures finalize `AckRetry`; systemic deterministic failures halt; an all-rejection-class
failure group follows `RejectedCommandPolicy`. The shared decision function:

```haskell
decideForFailures ::
    (IOE :> es, Store :> es) =>
    WorkerOptions es msg ->
    DispatcherKind ->      -- DispatcherRouter | DispatcherProcessManager
    Text ->                -- dispatcher name
    Text ->                -- correlation id
    RecordedEvent ->       -- the source event
    Int ->                 -- attempt count
    [DispatchFailure] ->
    Eff es AckDecision
```

(`ProcessManager.hs:333-395`). Note it takes ONE policy for the whole failure group — the
policy is node-granular, not per-dispatch. Its rejection classifier
(`ProcessManager.hs:321-325`):

```haskell
isRejectionClass :: CommandError -> Bool
isRejectionClass = \case
    CommandRejected -> True
    CommandAmbiguous{} -> True
    _ -> False
```

**The policy types and the worker knob (EP-100)** (`ProcessManager.hs:251-290`):

```haskell
data PoisonPolicy es msg
    = PoisonHalt
    | PoisonSkip !(Envelope msg -> Eff es ())
    | PoisonDeadLetter !(Envelope msg -> Eff es ())

data RejectedCommandPolicy
    = RejectedHalt        -- halt without acking so the source event replays (DEFAULT)
    | RejectedDeadLetter  -- persist a durable dispatch dead letter, ack the source event
    | RejectedSkip        -- ack and count the rejection without persisting a record
    deriving stock (Generic, Eq, Show)

data DispatchFailure = DispatchFailure
    { emitIndex :: !Int
    , targetStreamName :: !StoreTypes.StreamName
    , commandError :: !CommandError
    }

data WorkerOptions es msg = WorkerOptions
    { poisonPolicy :: !(PoisonPolicy es msg)
    , rejectedCommandPolicy :: !RejectedCommandPolicy
    , transientRetryDelay :: !RetryDelay
    , metrics :: !(Maybe KeiroMetrics)
    }

defaultWorkerOptions :: WorkerOptions es msg
defaultWorkerOptions = WorkerOptions
    { poisonPolicy = PoisonHalt
    , rejectedCommandPolicy = RejectedHalt
    , transientRetryDelay = RetryDelay 5
    , metrics = Nothing
    }
```

`RetryDelay` and `Envelope` come from `Shibuya.Core.Ack` / `Shibuya.Core.Types`.
`PoisonPolicy` has **no** `Eq` (it carries functions); `RejectedCommandPolicy` has `Eq`.
Under `RejectedDeadLetter`, `decideForFailures` writes one idempotent
`Keiro.DeadLetter.DispatchDeadLetter` per failure — a durable record carrying
`dispatcherKind`, `dispatcherName`, `correlationId`, `sourceEventId`,
`sourceGlobalPosition`, `emitIndex`, `targetStreamName`, `errorClass`
(`commandErrorClass`, e.g. `"command_rejected"` / `"command_ambiguous"`), `errorDetail`,
and `attemptCount` — inspectable via `listDispatchDeadLetters`
(`keiro/src/Keiro/DeadLetter.hs`). Source events whose bounded retries exhaust are parked
in Kiroku's `kiroku.dead_letters` and replayable via
`Keiro.DeadLetter.Replay.replaySubscriptionDeadLetters`, which relies on exactly the
deterministic dispatch ids above to make replay collapse to duplicates
(`keiro/src/Keiro/DeadLetter/Replay.hs:1-32`).

**The benign-duplicate confirmation (EP-97)** (`ProcessManager.hs:717-727`):

```haskell
confirmBenignDuplicate ::
    (Store :> es) => StoreTypes.StreamName -> EventId -> CommandError -> Eff es Bool
```

It decides whether a failed append is a benign duplicate of *the write just attempted* —
the store's event-id uniqueness is global, so even a matching `DuplicateEvent` id must be
confirmed present in the *target* stream with a point lookup. `runRouterOnce` and
`runProcessManagerOnce` both call it before folding a duplicate into
`PMCommandDuplicate`. **This function is what makes an `on-duplicate AckOk` arm correct
per-target**; the DSL's generated hole guidance must name it (audit finding F2's slice
for these two nodes).

**`CommandError` and ambiguity** (`keiro/src/Keiro/Command.hs:138-178`): the constructors
are `HydrationDecodeFailed`, `HydrationReplayFailed`, `HydrationGapDetected`,
`CommandRejected` ("no transducer edge matched the command in the hydrated state"),
`CommandAmbiguous ![Int]` ("two or more transducer edges matched … a deterministic
aggregate-definition bug rather than a business rejection; the list contains the matched
edge indices"), `EncodeFailed`, `StoreFailed`, `RetryExhausted`, `ConflictFixpoint`.
`commandErrorClass` maps them to low-cardinality strings (`"command_ambiguous"` etc.,
`Command.hs:652-666`).

### The gaps this plan closes (audit findings E2, E3, F3)

**E3 — no router node.** The DSL has nothing that maps to `Keiro.Router`. A real usage
shape exists in the repo:
`docs/plans/28-worked-example-incident-escalation-combining-a-router-and-a-process-manager.md`
builds `pagingRouter` — `name = "jitsurei-paging"`, `key` = the incident id, `resolve` =
`runQuery serviceOncallReadModel raised.service` producing one `SendPage` `PMCommand` per
rostered responder targeting `page-<incident>-<responder>` streams. That worked example is
this plan's fixture model.

**E2 — policies never lowered.** `emitProcessGen`
(`keiro-dsl/src/Keiro/Dsl/Scaffold.hs:670-723`) emits only the process name constant, the
`TimerRequest` builder, and the fire-disposition function. The spec's per-dispatch
`on-failed … deadLetter` arms are parsed, validated for completeness, and then dropped on
the floor: no `WorkerOptions` is generated, so a deployed worker takes
`defaultWorkerOptions` (`PoisonHalt`/`RejectedHalt`) and a spec that says "dead-letter"
halts.

**F3 — ambiguity has no vocabulary.** The generated timer fire function
(`Scaffold.hs:709-714`) is

```haskell
hospitalSurgeFireOutcome result = case result of
  Right{} -> Just ()                 -- on-ok
  Left CommandRejected -> Just ()    -- on-reject (benign inversion)
  Left{} -> Nothing                  -- on-error — CommandAmbiguous lumped in here
```

so `CommandAmbiguous` silently rides the `on-error` arm, and neither the notation nor the
skill ever mentions ambiguity.

### Proposed notation

The `router` node (new; shown filled with the plan-28 worked-example values):

```text
router PagingRouter
  name "jitsurei-paging"                       # STABLE IDENTITY: part of every dispatch id
  input IncidentRaised { incidentId service }
  key input.incidentId via idText              # correlation string; captured-fixture discipline
  resolve stable via read-model service_oncall row { responderId }
                                               # the effectful seam; 'stable' acknowledges the
                                               # union-of-attempts caveat; 'row' scopes resolved.*
  target Page                                  # the aggregate every resolved command targets
  projections [ ]                              # explicit; [] = append-only dispatch
  dispatch-each SendPage { incidentId=input.incidentId responderId=resolved.responderId }
    on-appended AckOk ; on-duplicate AckOk ; on-failed Retry
  dispatch-id strategy=uuidv5 from=(name, key, sourceEventId, targetStreamName, occurrence)
                                               # runtime-owned; fixed; NOT positional
  rejected => deadLetter                       # halt | deadLetter | skip — also governs CommandAmbiguous
  poison => halt                               # halt | deadLetter | skip
```

The alternative resolve form when no read model is named (the resolution hole):
`resolve stable via hole row { responderId }`.

The `process` node gains the same two mandatory policy lines (between `dispatch-id` and
`timer`), and the timer-fire disposition gains the mandatory `on-ambiguous` arm:

```text
  dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId, emitIndex)
  rejected => halt
  poison => halt
  timer surgeFollowUp
    ...
    fire dispatch Surge@correlationId MarkSurgeTimerFired { hospitalId timerId }
      fired-event-id uuidv5 "hospital-surge-fired:" <> correlationId
      on-ok Fired ; on-reject Fired ; on-ambiguous Retry ; on-error Retry ; not-mine Retry
    ...
```

`on-ambiguous Retry` is the recommended (and only sensible) value: the fire returns
`Nothing`, the timer's `max-attempts` ceiling trips, and the timer dead-letters with the
declared reason — a loud, durable witness of a definition bug. `on-ambiguous Fired` is a
validator **error** (see below); `Retry` is not defaulted — the author must write the arm.

### Integration points with sibling plans (state of the world: all are MasterPlan-15 peers)

- **Differ (hard dependency for the identity gate):**
  `docs/plans/103-make-keiro-dsl-diff-sound-over-the-full-decode-and-identity-surface.md`
  makes `diff --since` sound over identity-bearing surfaces. Today `diffSpecs`
  (`keiro-dsl/src/Keiro/Dsl/Diff.hs:52-58`) inspects only `NAggregate`. **Interface
  expectation this plan states and depends on:** plan 103 extends `diffSpecs` with
  per-node-kind identity diffing (match old/new nodes of each kind by name; classify
  identity-field changes as `Breaking` with dedicated `DiagnosticCode`s). This plan
  registers the router's identity surface with that machinery: `rtName` (Breaking —
  renaming re-keys every `deterministicRouterCommandId`, so on redelivery or dead-letter
  replay every previously-routed source event re-dispatches its full resolved set under
  new ids: a full duplicate fan-out), the `key` derivation (field + `via` — same blast
  radius), and the `target` aggregate. If this plan executes before 103 lands, it adds a
  minimal free-standing `routerIdentityDiff :: Spec -> Spec -> [Change]` wired into
  `diffSpecs` with code `RouterStableNameChanged`, and 103 subsumes it into the general
  machinery; if 103 lands first, this plan registers through 103's interface. Either
  way the acceptance contract is fixed: renaming a router in a spec makes
  `keiro-dsl diff --since` print a Breaking change and exit non-zero.
- **Validator registry:**
  `docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md`
  builds the command-resolution rule family (resolving `dispCommand`/`fireCommand` and
  field bindings against the target aggregate's declared commands). The router's
  `RouterCommandUnknown`/`RouterBindingUnscoped` rules are the same family: if 104's
  shared resolution helpers exist when M2 runs, use them; otherwise implement locally
  and leave a marker comment so 104 unifies. Diagnostic-code names in this plan are
  reserved here to avoid collisions.
- **Scaffolder hygiene:**
  `docs/plans/106-harden-the-keiro-dsl-scaffolder-template-injection-firewall-completeness-collision-and-stale-module-detection-and-faithful-policy-lowering.md`
  adds shared escaping helpers and firewall completeness. Until it lands, every
  spec-derived splice in the new emitters (router name, dead-letter reasons) must go
  through `tshow` (which escapes) — never raw quote-wrapping (the audit's D1 injection
  hazard). The new emitters are additive inputs to 106's firewall/collision sweeps.
- **Read models:**
  `docs/plans/107-add-a-first-class-read-model-node-with-registration-schema-and-consistency-to-keiro-dsl.md`
  adds a first-class `readmodel` node. The router's `resolve … via read-model <name>`
  is exactly the reference that needs it. Deferral pattern: until 107's node exists,
  a read-model name that resolves to nothing in the spec produces a **Warning**
  (`RouterReadModelUnverified` — "declared read model 'service_oncall' cannot be
  verified; add a readmodel node (docs/plans/107) or keep the resolver hole honest");
  once 107 lands, the same check upgrades to an Error through the ordinary cross-node
  coupling rule, and the resolver-hole guidance names `Keiro.ReadModel.runQuery` plus
  107's registration requirement.
- **Skill refresh:**
  `docs/plans/110-align-keiro-dsl-with-the-safe-apis-and-refresh-the-authoring-skill-and-corpus.md`
  performs the holistic SKILL/NOTATION/LOOP/WALKTHROUGH + corpus refresh and the
  cold-start re-proof. This plan lands only the minimal, accurate NOTATION.md sections
  for its own surface (router node, policy clauses, `on-ambiguous`), so the notation
  file is never wrong in the interim.


## Plan of Work

Six milestones, following the engine's data flow (the MP-8 per-vertical template):
grammar+parser → validator → scaffold → harness → conformance against the live runtime →
notation/skeleton. All edits are additive to `keiro-dsl`; the one deliberately breaking
edit is the new mandatory clauses, whose fixture fallout is absorbed inside M1.

### Milestone 1 — Grammar, parser, pretty-printer, round-trip

Scope: make `router` a first-class node and the policy/ambiguity clauses part of the
`process` notation, with `parse . pretty == id` preserved.

In `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, next to the process types (lines 400-530), add:

```haskell
-- | Node-level worker policy literal: @rejected => halt | deadLetter | skip@,
-- @poison => halt | deadLetter | skip@. Lowered to RejectedCommandPolicy /
-- PoisonPolicy constructors by the scaffolder.
data PolicyChoice = PolHalt | PolDeadLetter | PolSkip
    deriving stock (Eq, Show, Generic)

-- | The router's effectful resolution seam. The parser requires the literal
-- keyword 'stable' (the union-of-attempts acknowledgement); the row fields
-- scope @resolved.<field>@ references in dispatch bindings.
data ResolveSource = ResolveReadModel !Name | ResolveHole
    deriving stock (Eq, Show, Generic)

data ResolveDecl = ResolveDecl
    { rvSource :: !ResolveSource
    , rvRow :: ![Name]
    , rvLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

-- | @dispatch-each <Command> { bindings }@ + a complete disposition table.
-- No @Target\@key@ expression: the concrete target streams are the resolver's
-- effectful output, not derivable from the input.
data RouterDispatchNode = RouterDispatchNode
    { rdCommand :: !Name
    , rdFields :: ![FieldBinding]
    , rdDisposition :: !DispatchDisposition
    , rdLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)

data RouterNode = RouterNode
    { rtId :: !Name          -- block identifier (module names)
    , rtName :: !Text        -- the stable, identity-bearing runtime name
    , rtInput :: !InputDecl
    , rtKey :: !CorrelateDecl
    , rtResolve :: !ResolveDecl
    , rtTarget :: !Name
    , rtProjections :: ![Name]
    , rtDispatch :: !RouterDispatchNode
    , rtRejected :: !PolicyChoice
    , rtPoison :: !PolicyChoice
    , rtLoc :: !Loc
    }
    deriving stock (Eq, Show, Generic)
```

and extend the existing types: `data Node` gains `| NRouter RouterNode`; `ProcessNode`
gains `procRejected :: !PolicyChoice` and `procPoison :: !PolicyChoice`;
`FireDisposition` gains `onAmbiguous :: !FireOutcome` (between `onReject` and `onError`,
matching the generated `case` order). Note `RouterDispatchNode` and `ResolveDecl` carry a
`Loc` from day one — the audit's B12 complaint (rules anchored to block headers because
rows carry no `Loc`) must not be reproduced in new grammar.

In `keiro-dsl/src/Keiro/Dsl/Parser.hs`: add `pRouter :: P RouterNode` (mirroring
`pProcess` at line 884 — same clause-per-line style), register it in the top-level node
parser alongside the other node keywords; extend `pProcess` to require the
`rejected =>` / `poison =>` lines; extend the fire-disposition parser to require the
`on-ambiguous` arm; the router `dispatch-id` line is fixed text (parsed and discarded,
exactly like the process one — the AST has no user-id field). `pPolicyChoice` accepts
exactly `halt`, `deadLetter`, `skip`.

In `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`: add `docRouter` and a `docNode (NRouter r)`
arm (dispatch at line 66); render the new process clauses and the `on-ambiguous` arm in
canonical positions so round-trip holds.

In `keiro-dsl/test/Main.hs`: extend the QuickCheck round-trip generator (`genSpec`,
around lines 554-563) with a router-node arm over the same safe alphabets (the audit's C7
notes the generator is aggregate-only; the new arm covers only this plan's node — the
full generator overhaul is
docs/plans/105-fix-keiro-dsl-notation-integrity-string-escaping-duplicate-clauses-numeric-bounds-and-identifier-hygiene.md
territory). Add shape unit tests for `pRouter`.

Fixture fallout (same milestone, because `check` must stay green): every process-bearing
spec gains the two policy lines and the `on-ambiguous` arm. Find them with:

```bash
grep -rln '^process \|^  timer ' keiro-dsl/test/fixtures agents/skills/keiro-dsl-authoring
```

Known population: `keiro-dsl/test/fixtures/hospital-surge/hospital-surge.keiro`, the
process specs embedded in `keiro-dsl/test/Main.hs` unit-test strings, the
conformance-process/-process-runtime/-process-full fixture specs, the process skeleton in
`keiro-dsl/src/Keiro/Dsl/Skeleton.hs`, and the NOTATION.md example (updated in M6).
Choose `rejected => halt` / `poison => halt` (the runtime defaults, loudest) for existing
fixtures except one, which uses `rejected => deadLetter` so the lowering path is
exercised. Author the new router fixture
`keiro-dsl/test/fixtures/incident-paging/incident-paging.keiro`: the notation block from
Context (the `PagingRouter`), plus a minimal `Page` aggregate declaring `SendPage` and a
`PageSent` event so cross-references resolve.

Acceptance: `cabal run keiro-dsl -- parse keiro-dsl/test/fixtures/incident-paging/incident-paging.keiro`
echoes the router block; the round-trip property and all parser unit tests are green.

### Milestone 2 — Validator rules

Scope: line-numbered diagnostics for every dangerous omission or contradiction. All edits
in `keiro-dsl/src/Keiro/Dsl/Validate.hs`: new `DiagnosticCode` constructors
(`RouterUnresolvedRef`, `RouterKeyFieldUnknown`, `RouterBindingUnscoped`,
`RouterCommandUnknown`, `RouterReadModelUnverified`, `PolicyContradiction`,
`PolicyDeadLetterUnused`, `AmbiguousMarkedBenign`, `AmbiguousFollowsRejectedPolicy`), a
`validateNode spec (NRouter r) = validateRouter spec r` arm in the dispatch (lines
114-124), and `policyConsistency` applied from both `validateRouter` and
`validateProcess`.

The rules, each with its diagnostic (rendered here exactly as `check` should print them):

1. **Cross-references resolve** (`RouterUnresolvedRef`, Error): `rtTarget` and every
   `rtProjections` entry name a declared node.

```text
incident-paging.keiro:7:3: error[RouterUnresolvedRef]: router 'PagingRouter' targets aggregate 'Pge' but no such aggregate is declared
```

2. **Key field resolves** (`RouterKeyFieldUnknown`, Error): the `key input.<f>` field is
   declared in `rtInput`.

```text
incident-paging.keiro:4:3: error[RouterKeyFieldUnknown]: key references 'input.incidntId' but input 'IncidentRaised' declares { incidentId service }
```

3. **Dispatch bindings scoped** (`RouterBindingUnscoped`, Error): every non-literal
   binding value is `input.<declared input field>` or `resolved.<declared row field>`.

```text
incident-paging.keiro:9:3: error[RouterBindingUnscoped]: dispatch binding 'responderId=resolved.responder' references no field of the resolve row { responderId }
```

4. **Command resolves against the target** (`RouterCommandUnknown`, Error): `rdCommand`
   is a declared command of the target aggregate, and the bound field names are that
   command's fields (the plan-104 rule family; reuse its helpers if present).

```text
incident-paging.keiro:9:3: error[RouterCommandUnknown]: dispatch command 'SendPag' is not a declared command of aggregate 'Page' (declared: SendPage, AcknowledgePage)
```

5. **Read-model reference** (`RouterReadModelUnverified`, Warning until plan 107's
   `readmodel` node exists, then Error through the coupling rule):

```text
incident-paging.keiro:5:3: warning[RouterReadModelUnverified]: resolve names read model 'service_oncall' which cannot be verified from this spec; declare it once docs/plans/107's readmodel node lands, or switch to 'resolve stable via hole'
```

6. **Policy consistency** (`PolicyContradiction`, Error; both node kinds): any dispatch
   arm `on-failed deadLetter "…"` while the node policy is not `rejected => deadLetter`;
   and any two dispatches of one node declaring *different* rejection-class dispositions
   (the runtime applies ONE `RejectedCommandPolicy` per node via `decideForFailures` —
   per-dispatch divergence is unimplementable and today silently halts).

```text
incident-paging.keiro:10:5: error[PolicyContradiction]: dispatch 'SendPage' declares 'on-failed deadLetter "page rejected"' but the node policy is 'rejected => halt'; at runtime rejection-class failures follow the node-level RejectedCommandPolicy (Keiro.ProcessManager.decideForFailures), so this spec halts and never writes the dead letter — align the arms
```

7. **Declared dead-letter policy unused** (`PolicyDeadLetterUnused`, Warning): node says
   `rejected => deadLetter` but no dispatch arm mentions `deadLetter` — the policy is
   live but the spec's per-dispatch story does not acknowledge it.

8. **Ambiguity is never benign** (`AmbiguousMarkedBenign`, Error): `on-ambiguous Fired`.

```text
hospital-surge.keiro:29:7: error[AmbiguousMarkedBenign]: 'on-ambiguous Fired' — CommandAmbiguous means two or more transducer edges matched (an aggregate-definition bug, Keiro.Command); it is never a benign success and confirmBenignDuplicate does not cover it. Use 'on-ambiguous Retry' (retries to the max-attempts ceiling, then dead-letters loudly)
```

9. **Documented lumping at the dispatch level** (`AmbiguousFollowsRejectedPolicy`,
   Warning, once per node with `rejected => deadLetter` or `skip`): reminds the author
   that `isRejectionClass` groups `CommandAmbiguous` with `CommandRejected`, so the
   acknowledging policy also acknowledges definition bugs; the dead-letter row's
   `errorClass = "command_ambiguous"` is then the only witness.

Acceptance: `check` on `incident-paging.keiro` and the updated `hospital-surge.keiro`
exits 0 (warnings allowed); one mutated copy per rule fails with the expected code
(unit-tested via the existing `errorCodesOf` helper in `keiro-dsl/test/Main.hs`).

### Milestone 3 — Scaffold emitters

Scope: the deterministic layer plus holes, firewall-clean. Edits in
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` plus the CLI dispatch in `keiro-dsl/app/Main.hs`
(add `scaffoldRouter`/`harnessRouter` to the per-node comprehension at lines 122-124 and
the import list).

`scaffoldRouter :: Context -> RouterNode -> [ScaffoldModule]` emits one `Generated`
module at `genPrefixFor ctx (rtId r) <> ".Router"` and one `HoleStub` at
`holePrefixFor ctx (rtId r) <> ".RouterHoles"`. The Generated module (sketch — the shape
the emitter must produce for the fixture; every spec-derived splice through `tshow`):

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- @generated by keiro-dsl. Do not edit.
module Generated.Jitsurei.PagingRouter.Router
  ( pagingRouterName
  , pagingRouterWorkerOptions
  ) where

import Data.Text (Text)
import Keiro.ProcessManager
  ( PoisonPolicy (..)
  , RejectedCommandPolicy (..)
  , WorkerOptions (..)
  )
import Shibuya.Core.Ack (RetryDelay (..))

-- The STABLE router name (hole-kind 5: referenced, never retyped). It is an
-- input to every dispatched command's deterministic id
-- (Keiro.Router.deterministicRouterCommandId), so renaming it re-keys every
-- dispatch: on redelivery or dead-letter replay, every already-routed source
-- event re-dispatches its full resolved set under new ids.
pagingRouterName :: Text
pagingRouterName = "jitsurei-paging"

-- dispatch-id: runtime-owned. deterministicRouterCommandId derives a v5 UUID
-- from (name, key input, source event id, resolved target stream name,
-- occurrence); occurrence = index among same-target commands in one resolve
-- batch. Target-keyed, NOT positional: safe when the effectful resolve
-- reorders targets between attempts.

-- Node-level worker policy lowered from the spec:
--   rejected => deadLetter ; poison => halt.
-- Pass to Keiro.Router.runRouterWorkerWith. Never fall back to
-- defaultWorkerOptions (PoisonHalt/RejectedHalt) when the spec differs.
pagingRouterWorkerOptions :: WorkerOptions es msg
pagingRouterWorkerOptions =
  WorkerOptions
    { poisonPolicy = PoisonHalt
    , rejectedCommandPolicy = RejectedDeadLetter
    , transientRetryDelay = RetryDelay 5 -- matches defaultWorkerOptions (hole-kind 8)
    , metrics = Nothing                  -- hole-kind 8: install KeiroMetrics at the call site
    }
```

When the spec's `poison` policy is `deadLetter` or `skip`, the emitted signature becomes
`pagingRouterWorkerOptions :: (Envelope msg -> Eff es ()) -> WorkerOptions es msg` (adding
`import Effectful (Eff)` and `import Shibuya.Core.Types (Envelope)`), applying the
caller's callback to the `PoisonDeadLetter`/`PoisonSkip` constructor — the callback is
behaviour-bearing (what "skip" *records*) and must not be generated as a silent no-op.

The `RouterHoles` stub documents the typed holes (create-if-absent; never overwritten):

```haskell
-- HAND-OWNED hole module for the router's behaviour-bearing bodies.
-- keiro-dsl creates it once and never overwrites it.
module Jitsurei.PagingRouter.RouterHoles () where

-- HOLE resolve :: IncidentRaised -> Eff es [PMCommand PageCommand]
--   The effectful seam (spec: resolve stable via read-model service_oncall).
--   Typically 'runQuery <readModel> …' (Keiro.ReadModel).
--   STABILITY CONTRACT (the spec's 'stable' keyword): dispatch ids are keyed by
--   resolved target identity, so a redelivery deduplicates every target it
--   resolves AGAIN — but a drifting target set accumulates as the UNION of
--   attempt outputs. Keep resolution stable for a given source event when the
--   exact recipient set matters.
-- HOLE router value :: Keiro.Router.Router IncidentRaised phi rs s ci co es
--   Assemble Router { name = pagingRouterName, key, resolve, targetEventStream,
--   targetProjections }; run with runRouterWorkerWith pagingRouterWorkerOptions.
-- HOLE targetProjections :: Stream PageCommand -> [InlineProjection PageEvent]
--   Spec: projections [ ] — return [] to preserve append-only dispatch.
-- NOTE on-duplicate AckOk: the arm is correct because runRouterOnce confirms a
--   store DuplicateEvent against the TARGET stream via
--   Keiro.ProcessManager.confirmBenignDuplicate before folding it into
--   PMCommandDuplicate. Any hand-rolled dispatch path must call it too.
```

`emitProcessGen` gains the same two pieces for the process node: a
`<lo>WorkerOptions` value lowered from `procRejected`/`procPoison` (identical shape and
rules as above; export it from the module head), and the extended fire function:

```haskell
hospitalSurgeFireOutcome :: Either CommandError a -> Maybe ()
hospitalSurgeFireOutcome result = case result of
  Right{} -> Just ()                    -- on-ok Fired
  Left CommandRejected -> Just ()       -- on-reject Fired (benign inversion)
  Left (CommandAmbiguous _) -> Nothing  -- on-ambiguous Retry (definition bug;
                                        --   ceiling trips => timer dead-letters)
  Left{} -> Nothing                     -- on-error Retry
```

with each arm's comment derived from the spec's declared outcome. `emitProcessHoles`
gains the same `confirmBenignDuplicate` NOTE next to its dispatch guidance.

The firewall: the new emitters splice no keiki operator (nothing here is symbolic), and
the existing firewall test plus `firewallBreaches` must stay green over the new modules.

Acceptance: `keiro-dsl scaffold` on the two fixtures emits the modules;
`grep -nE 'B\.slot|B\.requireGuard|\blit\b|=:|\./=|\.==|\.\|\|'` over the Generated files
finds nothing; re-running scaffold leaves `RouterHoles` untouched; scaffold output is
byte-deterministic across runs.

### Milestone 4 — Harness emission and the mutation pin

Scope: spec-derived facts modules pinned by hand-written expectations, so a spec change
reddens a specific assertion. Edits in `keiro-dsl/src/Keiro/Dsl/Harness.hs` (new
`harnessRouter :: Context -> RouterNode -> [ScaffoldModule]`, modeled on `harnessProcess`
at line 52) and the CLI dispatch.

`emitRouterHarness` emits `<genPrefix>.RouterHarness` exporting:

```haskell
routerHarnessValues :: [(String, String)]
routerHarnessValues =
  [ ("routerName", "jitsurei-paging")
  , ("keyField", "incidentId")
  , ("resolveSource", "read-model service_oncall")
  , ("resolveRow", "responderId")
  , ("dispatchCommand", "SendPage")
  , ("dispatchIdInputs", "(name, key, sourceEventId, targetStreamName, occurrence)")
  , ("onDuplicate", "AckOk")
  , ("onFailed", "Retry")
  , ("rejectedPolicy", "deadLetter")
  , ("poisonPolicy", "halt")
  ]
```

`emitProcessHarness` (`Harness.hs:63-91`) gains three rows: `("rejectedPolicy", …)`,
`("poisonPolicy", …)`, `("onAmbiguous", …)`. The expectations live hand-written in the
conformance drivers (the EP-3 lesson: a generated-vs-generated assertion is a tautology —
the expectation must be independent).

Add `keiro-dsl/test/router-mutation-test.sh` (modeled on
`keiro-dsl/test/process-mutation-test.sh`): flip `rejected => deadLetter` to
`rejected => halt` in `incident-paging.keiro`, re-scaffold, run the router conformance
driver, assert exactly the `rejectedPolicy` assertion reddens, restore, assert green.

Acceptance: harness modules compile; the mutation script demonstrates the red/green
cycle.

### Milestone 5 — Conformance against the live runtime

Scope: the scaffold output compiles and runs against the real `Keiro.Router` /
`Keiro.ProcessManager`, pinning the dangerous decisions as compiled code (the MP-8 M5
pattern). Two new test suites in `keiro-dsl/keiro-dsl.cabal` (same stanza shape as
`keiro-dsl-conformance-process-runtime` at cabal line 307), each with committed copies of
the fixture's scaffold output plus a hand-written `Main.hs`:

**`keiro-dsl-conformance-router-runtime`** (`keiro-dsl/test/conformance-router-runtime/`)
compiles the Generated `Router` module against the live keiro package and asserts:

- `pagingRouterName == "jitsurei-paging"`;
- the lowered `WorkerOptions` pins: `rejectedCommandPolicy pagingRouterWorkerOptions ==
  RejectedDeadLetter` (`RejectedCommandPolicy` has `Eq`), and the poison policy via a
  `case … of PoisonHalt -> True; _ -> False` match (`PoisonPolicy` has no `Eq` — it
  carries callbacks);
- live id-derivation facts over `Keiro.Router.deterministicRouterCommandId` with fixed
  inputs: stable across two calls; different for two target stream names; different for
  occurrences 0 and 1 on the same target; equal name/key/source/target/occurrence gives
  the equal id — pinning target-keyed (not positional) semantics as compiled code;
- the extended process pin (in the existing `keiro-dsl-conformance-process-runtime`
  suite): `hospitalSurgeFireOutcome (Left (CommandAmbiguous [0,1])) == Nothing` (the
  explicit ambiguous arm) alongside the existing `on-reject` benign-inversion pin, plus
  the process node's own `WorkerOptions` pins.

**`keiro-dsl-conformance-router-full`** (`keiro-dsl/test/conformance-router-full/`) is
the filled-hole integration (the analogue of `keiro-dsl-conformance-process-full`): the
scaffolded `Page` target aggregate with a filled transducer, plus a hand-written `Router`
value filling the resolver hole with a deterministic stub (a pure-in-`Eff` list of two
`PMCommand`s built from a fixed input — no database), compiled against the live
`Keiro.Router.Router` type and exercised with `runPureEff`: assert the resolver returns
two commands with the expected target streams and that `key` produces the expected
correlation string. (Running `runRouterOnce` needs a `Store` effect and is out of scope,
exactly as `process-full` stops short of a live subscription.)

Acceptance: both suites listed in `cabal.project`'s test set build and pass via
`cabal test keiro-dsl-conformance-router-runtime keiro-dsl-conformance-router-full`; the
committed scaffold copies match fresh scaffold output (guarding D7-style drift is plan
106's business; here the copies are regenerated in-place during this milestone).

### Milestone 6 — Skeleton, notation, and the diff note

Scope: authoring affordances. Add a `"router"` kind to `skeletonKinds`/`skeletonFor` in
`keiro-dsl/src/Keiro/Dsl/Skeleton.hs` whose skeleton is self-contained and checks clean —
it must include a minimal target aggregate **with at least one command and one event** (the
audit's D4 shows command-less skeleton aggregates scaffold invalid Haskell; do not
reproduce that trap — coordinate with plan 106). Add the router section, the
`rejected`/`poison` clause documentation (including the ambiguity-lumping sentence), and
the `on-ambiguous` arm to `agents/skills/keiro-dsl-authoring/NOTATION.md` (the process
example at NOTATION.md line 66 onward gets the new lines). Record the plan-103 interface
expectation as a comment next to `diffSpecs` in `keiro-dsl/src/Keiro/Dsl/Diff.hs` (and, if
plan 103 has not yet landed, implement the minimal `routerIdentityDiff` described in
Context so a router rename is Breaking today rather than invisible).

Acceptance: `cabal run keiro-dsl -- new router` prints a spec that `check`s clean;
NOTATION.md matches the delivered grammar (spot-check by parsing its fenced examples).


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless
noted. Note one standing caveat (audit C8): the `keiro-dsl-test` unit suite assumes
`cwd = keiro-dsl/`, so run the unit suite from the package directory.

Build first:

```bash
cabal build keiro-dsl
```

M1 — parse and round-trip:

```bash
cabal run keiro-dsl -- parse keiro-dsl/test/fixtures/incident-paging/incident-paging.keiro
cd keiro-dsl && cabal test keiro-dsl-test
```

Expected: the router block echoes byte-identically (modulo normalized whitespace); the
round-trip property and shape tests pass.

M2 — check accepts the fixtures and rejects each mutation:

```bash
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/incident-paging/incident-paging.keiro
echo "exit=$?"
```

Expected: warnings only (`RouterReadModelUnverified`, `AmbiguousFollowsRejectedPolicy`),
`exit=0`. Then, for example, the policy contradiction:

```bash
sed 's/rejected => deadLetter/rejected => halt/; s/on-failed Retry/on-failed deadLetter "page rejected"/' \
  keiro-dsl/test/fixtures/incident-paging/incident-paging.keiro > /tmp/contradiction.keiro
cabal run keiro-dsl -- check /tmp/contradiction.keiro
echo "exit=$?"
```

Expected:

```text
/tmp/contradiction.keiro:10:5: error[PolicyContradiction]: dispatch 'SendPage' declares 'on-failed deadLetter "page rejected"' but the node policy is 'rejected => halt'; at runtime rejection-class failures follow the node-level RejectedCommandPolicy (Keiro.ProcessManager.decideForFailures), so this spec halts and never writes the dead letter — align the arms
exit=1
```

Analogous single-rule mutations for `RouterKeyFieldUnknown` (misspell the key field),
`RouterCommandUnknown` (misspell `SendPage`), `RouterBindingUnscoped` (bind
`resolved.responder`), `AmbiguousMarkedBenign` (set `on-ambiguous Fired` in
`hospital-surge.keiro`), and a missing `poison =>` line (a parse error naming the
expected clause).

M3 — scaffold and firewall:

```bash
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/incident-paging/incident-paging.keiro --out /tmp/paging-scaffold
grep -nE 'B\.slot|B\.requireGuard|\blit\b|=:|\./=|\.==|\.\|\|' -r /tmp/paging-scaffold/Generated ; echo "exit=$?"
```

Expected: `Generated/.../Router.hs` and `.../RouterHoles.hs` exist; the grep finds
nothing (`exit=1`). Re-run scaffold; confirm `RouterHoles.hs` mtime/content unchanged.

M4 — mutation pin:

```bash
bash keiro-dsl/test/router-mutation-test.sh
```

Expected transcript tail:

```text
mutated spec: rejectedPolicy assertion FAILED (expected)
restored spec: all router harness assertions green
```

M5 — conformance:

```bash
cabal test keiro-dsl-conformance-router-runtime keiro-dsl-conformance-router-full keiro-dsl-conformance-process-runtime
```

Expected: all pass, with the router-runtime suite printing the id-derivation and policy
pins, e.g.:

```text
router name: True
rejected policy lowered (RejectedDeadLetter): True
poison policy lowered (PoisonHalt): True
id stable across calls: True
id discriminates target stream: True
id discriminates occurrence: True
fire on-ambiguous => Retry: True
```

M6 — skeleton and notation:

```bash
cabal run keiro-dsl -- new router > /tmp/new-router.keiro
cabal run keiro-dsl -- check /tmp/new-router.keiro && echo OK
```

Finally the whole package (unit suite from the package dir):

```bash
cd keiro-dsl && cabal test keiro-dsl-test && cd .. && cabal build keiro-dsl && cabal test keiro-dsl-conformance-process keiro-dsl-conformance-process-runtime keiro-dsl-conformance-process-full keiro-dsl-conformance-router-runtime keiro-dsl-conformance-router-full
```

Commit at each milestone boundary with conventional-commit messages and the trailer
`ExecPlan: docs/plans/108-add-a-router-node-and-rejection-and-poison-policy-surfaces-to-keiro-dsl.md`.


## Validation and Acceptance

The plan is accepted when all of the following hold, each demonstrable by the commands in
Concrete Steps:

1. **The router notation is a real language.** `keiro-dsl parse` round-trips
   `incident-paging.keiro`; the QuickCheck round-trip property covers router nodes.
2. **Check forces every dangerous decision before any Haskell exists.** The fixture
   passes (exit 0, warnings only); each mutated spec fails with its named code:
   unresolved target/command, unscoped binding, unknown key field, per-dispatch
   `deadLetter` under node `halt` (`PolicyContradiction`), `on-ambiguous Fired`
   (`AmbiguousMarkedBenign`), and a missing `rejected =>`/`poison =>`/`on-ambiguous`
   clause (parse errors).
3. **The spec's policy reaches the runtime knob.** The Generated modules for BOTH the
   process and router fixtures export a fully-constructed `WorkerOptions` value lowered
   from the spec, and the conformance suites pin it against the live types:
   `rejectedCommandPolicy == RejectedDeadLetter` by `Eq`, the poison constructor by
   pattern match. This is the E2 fix made observable: the same spec that yesterday
   silently halted now compiles into the exact `WorkerOptions` the worker must be run
   with.
4. **Ambiguity is a decision, not an accident.** The generated fire function has a
   dedicated `Left (CommandAmbiguous _)` arm; the conformance suite pins
   `on-ambiguous => Retry`; `on-ambiguous Fired` cannot pass `check`; nodes whose
   `rejected` policy acknowledges get the lumping warning.
5. **The idempotency story is pinned as compiled code.** The router-runtime suite
   exercises the live `deterministicRouterCommandId` and proves stability plus
   target-stream and occurrence discrimination — the EP-97 semantics the notation's
   fixed `dispatch-id` line documents.
6. **The spec→behaviour link is load-bearing.** `router-mutation-test.sh` turns exactly
   one hand-written assertion red under a policy flip and returns to green on restore.
7. **A filled router compiles against the live runtime.** The router-full suite builds a
   real `Keiro.Router.Router` value from scaffold output plus a filled resolver hole.
8. **Firewall and hole discipline hold.** No Generated line contains a keiki symbolic
   operator; re-scaffolding never touches `RouterHoles`; scaffold output is
   deterministic.


## Idempotence and Recovery

Every step is safe to repeat. `parse`/`check` are pure reads. `scaffold` overwrites
`Generated` modules verbatim and creates `HoleStub` modules only if absent; to force a
clean hole regen, delete the stub and re-scaffold; scaffolding into `/tmp` never touches
the working tree. The mutation scripts take `.bak` copies and restore them; if
interrupted, `git checkout -- keiro-dsl/test/fixtures/incident-paging/incident-paging.keiro`
restores the fixture. The committed conformance scaffold copies are regenerated by
re-running scaffold with the suite's `--out` path; drift between committed copy and fresh
output is caught by re-running M5. No database, no migration, no runtime package is
touched; everything is additive `keiro-dsl` source plus fixtures and is revertible with
ordinary git operations.

One deliberate compatibility note: the new mandatory clauses (`rejected =>`, `poison =>`,
`on-ambiguous`) make **pre-existing** process-bearing `.keiro` files fail to parse until
they add the lines. That is the designed loud gate (the alternative — defaulting — is
exactly the E2 bug), and M1 updates every spec in this repository. External spec owners
get a parse error naming the missing clause, which is the migration instruction.


## Interfaces and Dependencies

Runtime bijection targets (read-only; never edited by this plan):
`Keiro.Router` (`keiro/src/Keiro/Router.hs`) — `Router (..)`, `RouterResult (..)`,
`deterministicRouterCommandId`, `runRouterOnce`, `runRouterWorkerWith`, `runRouterWorker`;
`Keiro.ProcessManager` (`keiro/src/Keiro/ProcessManager.hs`) — `WorkerOptions (..)`,
`defaultWorkerOptions`, `PoisonPolicy (..)`, `RejectedCommandPolicy (..)`,
`DispatchFailure (..)`, `decideForFailures`, `isRejectionClass`, `confirmBenignDuplicate`,
`PMCommand (..)`, `PMCommandResult (..)`; `Keiro.Command` (`keiro/src/Keiro/Command.hs`) —
`CommandError (..)` including `CommandAmbiguous ![Int]`, `commandErrorClass`;
`Keiro.DeadLetter` / `Keiro.DeadLetter.Replay` — the durable dead-letter record and
operator replay the policies lower onto; `Shibuya.Core.Ack` (`RetryDelay (..)`) and
`Shibuya.Core.Types` (`Envelope`) for the generated `WorkerOptions` construction.

`keiro-dsl` modules extended (all additive within the package):

- `Keiro.Dsl.Grammar` — `RouterNode`, `ResolveDecl`/`ResolveSource`,
  `RouterDispatchNode`, `PolicyChoice`, `NRouter`; `ProcessNode.procRejected/.procPoison`;
  `FireDisposition.onAmbiguous`.
- `Keiro.Dsl.Parser` — `pRouter`, `pPolicyChoice`, extended `pProcess` and fire-arm
  parser. Signature unchanged: `parseSpec :: FilePath -> Text -> Either ParseError Spec`.
- `Keiro.Dsl.PrettyPrint` — `docRouter` + extended `docProcess`.
- `Keiro.Dsl.Validate` — `validateRouter`, `policyConsistency`, the nine new
  `DiagnosticCode`s (names reserved in coordination with plan 104's registry).
- `Keiro.Dsl.Scaffold` — `scaffoldRouter :: Context -> RouterNode -> [ScaffoldModule]`;
  `emitProcessGen` extended (lowered `WorkerOptions`, ambiguous fire arm);
  `emitProcessHoles` extended (`confirmBenignDuplicate` note). Firewall invariant
  preserved; all splices via `tshow` pending plan 106's shared escaping helpers.
- `Keiro.Dsl.Harness` — `harnessRouter :: Context -> RouterNode -> [ScaffoldModule]`;
  `emitProcessHarness` extended with the policy/ambiguity rows.
- `Keiro.Dsl.Skeleton` — `"router"` kind.
- `Keiro.Dsl.Diff` — the plan-103 interface note; optionally the interim
  `routerIdentityDiff` (see Context, Integration points).
- `keiro-dsl/app/Main.hs` — scaffold/harness dispatch arms for `NRouter`.
- `keiro-dsl/keiro-dsl.cabal` — the two new conformance test-suite stanzas (which link
  the live `keiro` package, like the existing `-process-runtime`/`-process-full`
  stanzas).
- `agents/skills/keiro-dsl-authoring/NOTATION.md` — router + policy + ambiguity sections
  (minimal; the holistic refresh is plan 110's).

Sibling-plan interfaces (stated in full under Context → Integration points):
docs/plans/103-…md (differ identity registration — hard dependency for the diff gate;
interim `routerIdentityDiff` fallback defined), docs/plans/104-…md (validator
code registry + command-resolution rule family), docs/plans/106-…md (escaping/firewall
helpers; skeleton D4 trap), docs/plans/107-…md (read-model node; Warning→Error upgrade
of `RouterReadModelUnverified`), docs/plans/110-…md (skill/corpus refresh + cold-start
re-proof over a router-bearing spec).

No new third-party dependencies: the emitters produce text; the conformance suites link
only packages already linked by existing suites (`keiro`, `keiro-core`, `effectful-core`,
`shibuya` transitively via keiro).
