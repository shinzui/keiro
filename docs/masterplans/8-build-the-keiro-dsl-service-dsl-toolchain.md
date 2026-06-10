---
id: 8
slug: build-the-keiro-dsl-service-dsl-toolchain
title: "Build the keiro-dsl service DSL toolchain"
kind: master-plan
created_at: 2026-06-10T01:05:18Z
intention: "intention_01ktqdn85xe2btqzr2zghxgrpr"
---

# Build the keiro-dsl service DSL toolchain

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This initiative was originally drafted as a single ExecPlan,
`docs/plans/58-build-the-keiro-dsl-service-dsl-toolchain.md`, which is now a redirect to
this MasterPlan. All of 58's research, decisions, and surprises are carried forward here
and into the child plans.


## Vision & Scope

A keiro **service** (a bounded context using event sourcing, process managers, durable
timers, durable workflows, and Kafka/PGMQ integration) is today hand-written as a large
amount of highly regular Haskell. An empirical audit of two real services (recorded in
`keiro-runtime-jitsurei/docs/dsl/`) found that 67%–96% of the code per feature is a
deterministic template, and the non-derivable remainder collapses into a closed set of
**eight hole-kinds** — and that the few genuinely dangerous decisions (inverted error
semantics, opaque id derivations, fields whose names lie about their semantics) are
exactly the ones a human or coding agent gets wrong when left implicit.

After this initiative, a `.keiro` file is **a typed specification** of a keiro service —
the permanent, machine-checkable source of truth — and `keiro-dsl` is the toolchain
around it. A developer (or a coding agent planning a feature) can:

1. Write a service spec in terse, readable notation that covers keiro's full node
   surface: `aggregate`, `process` + `timer`, `intake`/`emit`/`publisher` (+ `contract`),
   `workqueue`/`dispatch`, `workflow`, and `operation`.
2. `keiro-dsl check` the spec — rejecting any missing required decision *before any
   Haskell is written*.
3. `keiro-dsl scaffold` the spec — emitting the **symbol-free deterministic layer**
   (domain ADTs, ids, codecs, EventStream/projection wiring, register lists, the TH
   splice) into `-- @generated` modules, plus precisely-typed **holes** in hand-owned
   modules, plus a verification **harness**.
4. Fill the transducer body and holes (by hand or with a coding agent) against the
   generated signatures, and run the harness to confirm behavior matches the spec.
5. `keiro-dsl diff --since <ref>` to classify each spec change across the service's
   lifetime as safe (additive) or breaking (needs an upcaster/deprecation).

**In scope:** the notation + checker + scaffolder + harness emitter + evolution differ,
covering every keiro node type, conformance-tested against the external
`keiro-runtime-jitsurei` corpus, plus an agent-facing authoring skill.

**Explicitly out of scope** (the load-bearing scope decision — see Decision Log):
keiro-dsl does **not** emit the symbolic transducer logic (lowering guards/register
writes to keiki's `./=`/`lit`/`B.slot`/`B.requireGuard` surface and matching
Template-Haskell-produced identifiers). That is the most brittle, most framework-coupled
piece and exactly the code a coding agent writes well from a spec + examples; it is left
as a hole and pinned by the harness. **Firewall invariant:** no `-- @generated` line
ever contains a keiki symbolic operator. Also out of scope: read-model table migrations
(delegated to `codd`), and arbitrary in-body computation/control-flow (branching, raw
SQL, string surgery, inter-step data-flow), which is by design an agent-written,
harness-checked hole rather than something the spec expresses.


## Decomposition Strategy

The initiative is one **shared engine** plus **independent node verticals**, decomposed
by functional concern (each node family maps to a distinct keiro primitive cluster with
its own forced decisions and its own corpus conformance target), not by file.

- **EP-1 Foundations** builds the walking skeleton everything else plugs into — the
  grammar AST, parser, pretty-printer, validator framework, scaffold engine, harness
  engine, and CLI — and proves it end-to-end on the **aggregate** vertical (the only
  node every service has). Drawing the boundary here keeps every later vertical a pure
  extension of stable shared types rather than a co-design.
- **EP-2 Evolution** adds the lifecycle layer (`schemaVersion`/`upcast`/`deprecated` +
  `diff --since`). It is separable because it reasons about *spec deltas*, orthogonal to
  any single node's codegen.
- **EP-3…EP-6** are the four non-aggregate node verticals (process+timer; integration;
  pgmq; workflow+operation). Each was independently mapped against the real primitive and
  its real corpus usage (see Surprises). Each carries its own grammar additions, validator
  rules (including the dangerous-default checks), scaffold output, harness, and a distinct
  conformance target — so each is independently verifiable and the four can proceed in
  parallel once EP-1 lands.
- **EP-7 Delivery** packages the authoring loop as a reusable skill and registers the
  corpus, which only makes sense once the verticals exist.

Why per-vertical and not coarser: the coverage audit showed each node family is a
substantial body of work (its own primitive surface, hole-kinds, ~7–10 validator rules,
and a separate corpus slice). A single "all nodes" plan would be one ~80%-of-the-work
giant blocking everything; per-vertical maximizes independent verifiability and
parallelism. Alternatives considered and rejected: a **single ExecPlan** (would exceed
five milestones and touch many unrelated modules — the MASTERPLAN threshold); a **coarse
4-plan split** (one oversized serial node plan, less parallel clarity). A **full code
generator** for the symbolic transducer was rejected at the scope level (brittleness +
permanent keiki lockstep maintenance), which is what makes the verticals tractable: each
vertical emits symbol-free scaffold + holes + harness, never a symbolic compiler.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Foundations: grammar, parser, validator, scaffold/harness engine, aggregate vertical | docs/plans/59-keiro-dsl-foundations-grammar-parser-validator-scaffold-and-harness-engine-aggregate-vertical.md | None | None | Complete |
| EP-2 | Evolution: schema versioning, upcasters, deprecation, diff | docs/plans/60-keiro-dsl-evolution-schema-versioning-upcasters-deprecation-and-diff.md | EP-1 | None | Complete |
| EP-3 | Process manager + durable timer nodes | docs/plans/61-keiro-dsl-process-manager-and-durable-timer-nodes.md | EP-1 | EP-2 | Complete (M1–M5: a full process service — scaffolded Surge+Hospital aggregates with filled transducers + a filled ProcessManager handle — compiles + runs against the live keiro/keiki runtime; keiro-dsl-conformance-process-full) |
| EP-4 | Integration nodes: inbox, outbox, Kafka, contract | docs/plans/62-keiro-dsl-integration-nodes-inbox-outbox-kafka-and-contract.md | EP-1 | EP-2 | Complete (M1–M5: all 4 nodes parse+validate incl. the inbox inversions/skip-totality/coupling; contract codec, intake disposition, publisher config, and a full integration service — inbox transaction runner + outbox IntegrationProducer with filled bodies — compile against the live keiro runtime; conformance: contract / intake-runtime / publisher-runtime / intake-full) |
| EP-5 | PGMQ workqueue + dispatch nodes | docs/plans/63-keiro-dsl-pgmq-workqueue-and-dispatch-nodes.md | EP-1 | EP-4 | Complete (M1–M5: a full pgmq dispatch service — scaffolded Job codec + retry policy + a filled worker handler assembled into a live Keiro.PGMQ.Job value — compiles against keiro-pgmq; keiro-dsl-conformance-dispatch-full) |
| EP-6 | Workflow + operation nodes | docs/plans/64-keiro-dsl-workflow-and-operation-nodes.md | EP-1 | EP-2 | Complete (M1–M5: workflow+operation parse+validate incl. await<->signal match; facts harness + mutation pin; await<->signal id over the live deterministicAwakeableId; and a full durable workflow — scaffolded runtime + a filled ordered step/await body — compiles against the live Keiro.Workflow effect; conformance: workflow / workflow-runtime / workflow-full) |
| EP-7 | Authoring skill + corpus registration | docs/plans/65-keiro-dsl-authoring-skill-and-corpus-registration.md | EP-1, EP-3, EP-4, EP-5, EP-6 | EP-2 | Complete (skill + corpus index + symlink + mori; cold-start proven: a fresh subscription spec went check->scaffold->fill->green harness) |

Status values: Not Started, In Progress, Complete, Cancelled.


## Dependency Graph

**EP-1 Foundations is the only hard prerequisite for everything.** It defines the shared
types every other plan extends — `Keiro.Dsl.Grammar` (the AST), `Keiro.Dsl.Parser`,
`Keiro.Dsl.Validate` (the `Diagnostic` framework), `Keiro.Dsl.Scaffold` (the
`ScaffoldModule`/`ModuleKind` engine and the firewall invariant), `Keiro.Dsl.Harness`,
and the CLI dispatcher. No vertical can add a node type until these exist, because a new
node is literally a new `Grammar` constructor, new `Validate` rules, and new `Scaffold`
cases. Hence EP-2…EP-7 hard-depend on EP-1.

**EP-3, EP-4, EP-6 can run fully in parallel** once EP-1 is Complete — they touch
disjoint node types and disjoint corpus slices. Their only contact is additive edits to
the shared engine modules (see Integration Points), coordinated through the bijection
table, not through code dependencies.

**EP-5 (pgmq) soft-depends on EP-4 (integration)** because a pgmq `dispatch` is driven by
a read-model→enqueue coupling and the `contract`/envelope-binding machinery EP-4 defines
is reused; EP-5 can start with a temporary local notion of contracts and reconcile once
EP-4's `contract` block lands.

**EP-2 (evolution) hard-depends on EP-1** and is a soft input to the verticals (each
vertical's events may carry `schemaVersion`/`upcast`); the verticals can scaffold without
it and adopt evolution constructs once EP-2 lands, so it is a soft dep, not a serializer.

**EP-7 (delivery) hard-depends on EP-1 and all four verticals (EP-3…EP-6)** — the
authoring skill demonstrates the full node surface and registers the conformance corpus,
which requires the verticals to exist.

Critical path: EP-1 → (EP-3 ∥ EP-4 ∥ EP-6, with EP-5 after EP-4) → EP-7. EP-2 hangs off
EP-1 and rejoins opportunistically.


## Integration Points

Every vertical extends the same shared engine. These are the artifacts multiple child
plans touch; **EP-1 defines all of them**, and EP-2…EP-6 extend them additively. A new
node type **must** extend the bijection table and `Keiro.Dsl.Grammar` in the same change
(this is the faithfulness contract).

1. **`Keiro.Dsl.Grammar` (the AST).** Defined by EP-1 with the shared declarations
   (`IdDecl`, `EnumDecl`, `RuleDecl`, the hole types, the `Expr` sublanguage) and the
   `Aggregate` node. Each vertical adds its node constructor(s): EP-3 `Process`/`Timer`,
   EP-4 `Contract`/`Intake`/`Emit`/`Publisher`, EP-5 `Workqueue`/`Dispatch`, EP-6
   `Workflow`/`Operation`. EP-2 adds versioning fields to `Event`. Shared `Spec` type
   aggregates all nodes.
2. **`Keiro.Dsl.Validate` (`validateSpec :: Spec -> [Diagnostic]`).** EP-1 defines the
   `Diagnostic` type, the diagnostic-rendering, and the cross-cutting rules (reachability,
   clock-free / **time-injected-not-sampled**, scope-checking the `Expr` sublanguage,
   the eight hole-kind presence checks). Each vertical adds its node-specific rules
   (e.g. EP-3 forbids clock samples in timer deadlines and forces explicit `max-attempts`;
   EP-4 forces a complete inbox disposition table and flags the duplicate⇒ack /
   previouslyFailed⇒deadLetter inversions; EP-5 forces the physical-table-name fixture).
3. **`Keiro.Dsl.Scaffold` (`scaffoldAggregate`-style emitters) + the firewall invariant.**
   EP-1 defines `ScaffoldModule { modulePath, moduleText, kind }`,
   `ModuleKind = Generated | HoleStub`, the create-if-absent hole discipline, and the
   tested invariant that **no `Generated` module contains a keiki symbolic operator**.
   Every vertical adds emitters that must satisfy that invariant.
4. **`Keiro.Dsl.Harness`.** EP-1 defines the harness emitter (`validateTransducer` +
   golden wire fixtures + clock-free assertion), modeled on the corpus's existing
   `test/SymbolicSpec.hs` / `test/IdentitySpec.hs`. Each vertical emits node-appropriate
   harness tests.
5. **The bijection table + the eight hole-kinds + the cross-cutting rules.** Documented
   in EP-1's Context section and mirrored in this MasterPlan's lineage; the single source
   of truth that keeps every node faithful to a named keiro primitive. Every vertical
   appends its rows.
6. **The CLI dispatcher (`keiro-dsl/app/Main.hs`).** EP-1 owns the optparse-applicative
   command tree (`parse`/`check`/`scaffold`); EP-2 adds `diff`. Verticals add no new
   subcommands (they extend the existing ones' behavior).
   **Reconciliation note (cross-plan, 2026-06-10):** EP-1 defines
   `parseSpec :: Text -> Either ParseError Spec`, while EP-4 (and references elsewhere)
   assume `parseSpec :: FilePath -> Text -> Either ParseError Spec` — a source-name
   parameter that megaparsec wants for line-numbered diagnostics. **Canonical decision:**
   EP-1's implementation adopts the source-name form
   `parseSpec :: FilePath -> Text -> Either ParseError Spec` (better diagnostics, which
   EP-1's own `Diagnostic`/`check` story needs), and may expose a `parseSpecText :: Text -> …`
   convenience wrapper. Every plan's `parseSpec` reference resolves to the source-name
   form; the no-FilePath occurrences in the child plans are shorthand, not a competing
   signature.
7. **The captured-fixture corpus (`keiro-dsl/test/fixtures/`).** EP-1 establishes the
   convention (a `.keiro` plus the hand-written reference modules captured read-only from
   `keiro-runtime-jitsurei`). Each vertical captures its own slice. EP-7 registers the
   corpus for agent use.
8. **The `contract` block.** Defined by EP-4 (cross-service message schema, define-once,
   referenced by both producer and consumer). EP-5 consumes it for pgmq queue/contract
   coupling. This is the one cross-*vertical* integration point (hence EP-5 soft-depends
   on EP-4).
9. **The `cabal.project` packages list and `keiro-dsl.cabal`.** EP-1 creates the package
   and the `cabal.project` entry; all later plans add modules/deps within it. Additive;
   touches no existing keiro package.


## Progress

Track milestone-level progress across all child plans.

- [x] EP-1: package skeleton + `cabal.project` wiring; Grammar AST (incl. `Expr`); parser; pretty-printer + round-trip; `parse` CLI. (2026-06-10)
- [x] EP-1: validator framework + `check` CLI (hole-kinds, reachability, clock-free, `Expr` scope-check). (2026-06-10)
- [x] EP-1: scaffold engine (`ScaffoldModule`/`ModuleKind`, create-if-absent holes, firewall invariant) + `scaffold` CLI. (2026-06-10)
- [x] EP-1: harness engine; aggregate vertical conformance against captured `HospitalCapacity/Reservation` fixture (scaffold compiles, holes filled, harness green 5/5; mutation turns a specific test red). (2026-06-10)
- [x] EP-2: `schemaVersion`/`upcast`/`deprecated` grammar + `diff --since` classifying additive vs breaking. (2026-06-10)
- [x] EP-3: `process`/`timer` nodes — grammar, validator, scaffold, facts harness + mutation pin, the Process wiring compiling against live Keiro.Timer/Command, AND a full process service (Surge+Hospital aggregates + filled ProcessManager handle) compiling against the live runtime (conformance-process-full). Complete. (2026-06-10)
- [x] EP-4: `contract`/`intake`/`emit`/`publisher` — schema + inbox binding/dedupe/decode/disposition + dangerous-inversion validator; contract codec, intake disposition, publisher config, and a full integration service (inbox transaction runner + outbox producer) all compiling against the live keiro runtime. Complete. (2026-06-10)
- [x] EP-5: `workqueue`/`dispatch` — validators (physical-name divergence, store/decode inversions, dlq ceiling, enqueue resolution); Job codec + RetryPolicy/JobOutcome disposition + a full dispatch service (live Keiro.PGMQ.Job.Job value + filled worker handler) compiling against keiro-pgmq. Complete. (2026-06-10)
- [x] EP-6: `workflow`/`operation` — ordered step/await/sleep/child body + command/query/signal/run shapes + validators (await<->signal match, run resolution); facts harness + mutation pin; await<->signal id over the live deterministicAwakeableId; and a full workflow body compiling against the live Keiro.Workflow effect. Complete. (2026-06-10)
- [x] EP-7: authoring skill (SKILL/NOTATION/LOOP/WALKTHROUGH covering all 7 node families + the loop + hole-filling contract), corpus index docs/corpus/keiro-dsl-corpus.md, .claude/skills symlink, keiro-dsl registered in mori.dhall. Live cold-start test remaining. (2026-06-10)


## Surprises & Discoveries

Cross-plan insights carried forward from the #58 feasibility + coverage audits
(2026-06-10). Full per-node detail lives in each vertical's child plan.

- **Substrate verified real.** All primitives, the harness target
  (`Keiki.Core.validateTransducer`/`defaultValidationOptions`), `GHC2024` + GHC ≥9.12,
  and the additive deps (megaparsec/optparse-applicative/prettyprinter — none yet used in
  keiro) check out. The audit corpus
  (`keiro-runtime-jitsurei/docs/dsl/{grammar-consolidated,reservation-slice-proof,surgemanager-slice-proof}.md`)
  is real.
- **The rich corpus is external.** Every in-repo `jitsurei` aggregate is
  register/guard/projection-free (`type …Regs = '[]`, plain emit+goto). The features the
  DSL exists for — registers, guards, status-map projections, PMs, timers, workflows,
  Kafka/PGMQ integration — live in `keiro-runtime-jitsurei` (`hospital-capacity`,
  `incident-command`), which also ships harness-style `SymbolicSpec.hs`/`IdentitySpec.hs`.
  So the conformance corpus is external-primary, in-repo-secondary.
- **`keiro-dsl` does not emit symbolic transducer code (scope decision).** The brittle,
  keiki-coupled lowering is left to a human/agent and pinned by the harness. This
  dissolved an earlier "conformance gap." The firewall invariant (no symbolic operator in
  `-- @generated`) is the engine-level guard EP-1 must implement and every vertical must
  satisfy.
- **Integration primitive source lives in `keiro-core`, not `keiro`** (the
  `keiro/src/Keiro/Integration/` dir is empty; the envelope contract is
  `keiro-core/src/Keiro/Integration/Event.hs`). EP-4 must point there.
- **Two dangerous inbox disposition inversions** (EP-4): *duplicate ⇒ ackOk* and
  *previouslyFailed ⇒ deadLetter, not retry* (`KafkaConsumer.hs:111-123`). The validator
  must force an explicit, complete disposition table and flag these.
- **Dangerous timer defaults** (EP-3): `maxAttempts = Nothing` ⇒ infinite ping-pong
  (`Timer.hs:72-74`); unknown `TimerStatus` ⇒ silent `Cancelled` (`Schema.hs:383`);
  dispatch-ids are runtime-owned (`deterministicCommandId`) and must be un-overridable.
- **pgmq has only one real corpus instance** (EP-5): hospital-capacity reservation-work;
  incident-command's `ProjectionWorker` is an event-store drainer, not pgmq. Generality
  is unproven and the physical table name needs a captured fixture (opaque `queueRef`
  sanitizer + `pgmq.q_` prefix), re-spelled as a raw-SQL literal at the dedup site — a
  real drift hazard.
- **Workflow step bodies are opaque** (EP-6): inter-step data-flow and conditional
  control flow are not expressible — by design they are agent-written holes. The
  expressible surface is steps/await/sleep/child + the deterministic-id and await↔signal
  couplings.
- **Boundary insight:** nearly every coverage "gap" is in-body computation, which under
  scaffold+verify is the agent-written hole — not a spec failure. The only true grammar
  TODOs (not body-logic) are PM multi-source input fan-in, conditional dispatch,
  contract-union-across-topics, and the await↔signal coupling. Each is assigned to its
  vertical.


## Decision Log

- Decision: Decompose into a MasterPlan with 7 per-vertical child ExecPlans (EP-1
  Foundations+aggregate; EP-2 Evolution; EP-3 Process+Timer; EP-4 Integration; EP-5 PGMQ;
  EP-6 Workflow+Operation; EP-7 Delivery), converting `docs/plans/58`.
  Rationale: the coverage audit showed each node family is a substantial, independently
  verifiable body of work with its own primitive surface, hole-kinds, validator rules,
  and corpus slice — the MASTERPLAN profile (3+ functional concerns, shared interfaces,
  >5 milestones, >10 files). Per-vertical maximizes parallelism after the shared engine
  lands. Coarser splits and a single ExecPlan were rejected (oversized serial work /
  exceeds single-plan threshold). Date: 2026-06-10
- Decision: keiro-dsl is a **typed spec** with `check` + `scaffold` + `harness` + `diff`,
  **not** a full transducer generator; the scaffolder emits only the symbol-free
  deterministic layer + typed holes, never a keiki symbolic operator (firewall invariant).
  Rationale: emitting the symbolic transducer is the largest, most brittle,
  keiki-lockstep-coupled piece and exactly what a coding agent writes well from a spec +
  examples; the determinism guarantee the project needs is behavioral and delivered by
  the harness. This is the load-bearing scope decision that makes the verticals tractable.
  Date: 2026-06-10
- Decision: Primary conformance corpus is the external `keiro-runtime-jitsurei`, captured
  as read-only fixtures under `keiro-dsl/test/fixtures/`; in-repo `jitsurei` is a
  register-free smoke target.
  Rationale: the rich features live only in the external repo; capturing fixtures keeps
  tests hermetic. Date: 2026-06-10
- Decision: keiro-dsl lives in the **keiro** repo as a new package; canonical surface is a
  bespoke terse notation (megaparsec parser, optparse-applicative CLI, prettyprinter);
  generated code and hand-filled holes live in separate modules (`-- @generated` overwrite
  vs create-if-absent holes).
  Rationale: carried forward from #58 — the DSL is a bijection with keiro primitives
  (co-location keeps node+primitive changes atomic); the terse notation is the cleanest
  human/agent surface; the generated/hole split makes the Nth scaffold as safe as the
  first. Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

### Progress snapshot (2026-06-10)

The shared engine and the complete typed-spec surface are delivered and green; the
runtime-coupled scaffold/harness tail and the EP-7 cold-start remain.

**Done and proven (green tests / conformance):**

- **Engine (EP-1):** `Keiro.Dsl.{Grammar,Parser,PrettyPrint,Validate,Scaffold,Harness,Diff}`
  + the `parse`/`check`/`scaffold`/`diff` CLI. The firewall invariant holds across every
  Generated module and is tested. `parse . pretty == id` is a QuickCheck property.
- **All seven node families parse, validate, and round-trip:** `aggregate`, `process`+`timer`,
  `contract`/`intake`/`emit`/`publisher`, `workqueue`/`dispatch`, `workflow`/`operation`,
  plus evolution (`vN`/`upcast`/`deprecated`). 44 unit tests.
- **The dangerous-decision checkers (the project's core value):** status-map totality,
  clock-free guards, event-version upcasters, process time-injection + runtime-owned
  dispatch-id + benign-inversion warnings, the three inbox-disposition inversions +
  skip-totality + contract coupling, the pgmq physical-name-divergence + store/decode
  inversions, and the workflow await↔signal match — each rejected with a line-numbered
  diagnostic, each with a passing/failing fixture.
- **Six compiled conformance components** (build against keiki/keiro + run):
  `keiro-dsl-conformance` (aggregate: scaffold + filled holes compile, harness green,
  guard-mutation reddens a specific test), `-v2` (evolution: v2 codec + filled upcaster),
  `-process` (process facts harness + spec→behaviour mutation pin), `-contract` (EP-4
  contract codec round-trip), `-queue` (EP-5 Job codec round-trip). Plus the
  `mutation-test.sh` / `diff-test.sh` / `process-mutation-test.sh` gates.
- **EP-7 delivery:** the `keiro-dsl-authoring` skill (SKILL/NOTATION/LOOP/WALKTHROUGH),
  `docs/corpus/keiro-dsl-corpus.md`, the `.claude/skills` symlink, and the `keiro-dsl`
  package registered in `mori.dhall` (typechecks).

**Update (2026-06-10, later): every vertical's deterministic layer now compiles
against the LIVE keiro runtime.** Beyond the self-contained codecs, the scaffolder
now emits, and a conformance component compiles + runs against the real runtime
types, the deterministic wiring for each non-aggregate vertical — thirteen
keiro-dsl conformance suites total:

- EP-3 process: the `Process` module (timer-request builder → real
  `Keiro.Timer.TimerRequest` with a v5 `TimerId`; fire disposition over
  `Keiro.Command.CommandError`) — `keiro-dsl-conformance-process-runtime`.
- EP-4 intake: the `Inbox` module (dedupe policy → `InboxDedupePolicy`;
  disposition over the real `InboxResult`, pinning duplicate⇒ackOk /
  previouslyFailed⇒deadLetter) — `keiro-dsl-conformance-intake-runtime`.
- EP-4 publisher: the `Publisher` config (`OrderingPolicy` / `BackoffSchedule`)
  — `keiro-dsl-conformance-publisher-runtime`.
- EP-5 pgmq: the `QueuePolicy` (`RetryPolicy` + `JobOutcome` disposition, pinning
  storeFailure⇒Retry / decodeFailure⇒Dead) — `keiro-dsl-conformance-queue-runtime`.
- EP-6 workflow: the `WorkflowRuntime` (await↔signal id via the real
  `deterministicAwakeableId`) — `keiro-dsl-conformance-workflow-runtime`.

So the **dangerous-decision semantics for every vertical are now pinned as
compiled code over the actual keiro runtime types**, not just text or
self-contained facts.

**Update (2026-06-10, final): all seven child ExecPlans are Complete — every M5
full-service integration now compiles against the live runtime.** The behaviour-
bearing holes were filled and a whole reference service compiled for each
non-aggregate vertical, each behind a new conformance suite:

- **EP-3 M5** — `keiro-dsl-conformance-process-full`: a full process service
  (scaffolded Surge saga + Hospital target aggregates with filled transducers + a
  hand-written `ProcessManager` value filling the `handle`) compiles + runs against
  `Keiro.ProcessManager`; the pure handle is exercised (1 advance, 1 dispatch, 1 timer).
- **EP-4 M5** — `keiro-dsl-conformance-intake-full`: the inbox transaction runner
  (real `runInboxTransaction` over the scaffolded dedupe policy + the `Kiroku.Store`
  effect) and the outbox `IntegrationProducer` (filled `mapEvent`) compile.
- **EP-5 M5** — `keiro-dsl-conformance-dispatch-full`: a live `Keiro.PGMQ.Job.Job`
  value (scaffolded codec + `RetryPolicy` via `queueRef`) + a filled
  `p -> Eff es JobOutcome` worker handler compile against keiro-pgmq.
- **EP-6 M5** — `keiro-dsl-conformance-workflow-full`: a filled ordered step/await
  body compiles against the live `Keiro.Workflow` `step`/`awaitStep`, its journal
  labels matching the scaffolded runtime.

Eighteen keiro-dsl test suites are green (1 unit + 17 conformance). The whole
MasterPlan vision is realized: `check` rejects bad specs before any Haskell; `scaffold`
emits the symbol-free deterministic layer (firewall held) for every node type;
filling the holes yields a service that compiles against the live keiro stack; `diff`
gates evolution; and the authoring skill + corpus + proven cold-start close the loop.

**Remaining: none for the MasterPlan's scope.** The "heavy, framework-locked tail" that
this section once tracked — full runtime compilation of the behaviour-bearing bodies (the
process `handle`, inbox/outbox transaction, pgmq dispatch worker, workflow body) — has been
completed for every vertical via the M5 full-service conformance suites listed above, and
EP-7's cold-start is proven. What is intentionally NOT done remains out of scope by the
Vision: the scaffolder still does not *emit* those symbolic/effectful bodies (the firewall);
they are agent-filled holes, now demonstrated filled-and-compiling for all verticals.

### Lessons

- **The validation surface is where the value concentrates.** Catching the dangerous
  inversions (duplicate⇒retry, previouslyFailed⇒retry, decodeFailed⇒unbounded-retry,
  storeFailure⇒deadLetter, on-reject⇒Fired, await/signal mismatch, physical-name drift)
  before any Haskell exists is the bulk of the payoff, and it landed for every vertical.
- **Behaviour pins need an independent reference.** Both the EP-1 guard mutation and the
  EP-3 process facts harness only became real tests once the expectation was hand-written
  (not regenerated from the spec) — a generated-vs-generated assertion is a tautology.
- **Self-contained codegen compiles cheaply; runtime-coupled codegen is the hard tail.** The
  domain/codec/contract/Job layers compile against base/text/aeson/keiki/keiro-core and were
  conformance-proven; the `ProcessManager`/`Inbox`/`Workflow` wiring pulls the whole
  effectful/hasql stack and is the deferred work — which validates the original scope
  decision to leave behaviour-bearing bodies as harness-pinned holes.
