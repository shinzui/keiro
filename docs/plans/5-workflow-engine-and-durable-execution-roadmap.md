---
id: 5
slug: workflow-engine-and-durable-execution-roadmap
title: "Workflow Engine and Durable Execution Roadmap"
kind: exec-plan
created_at: 2026-05-04T20:12:11Z
intention: "intention_01kqt8d9t8ehb84kgs19qa1rs9"
master_plan: "docs/masterplans/1-keiro-research-foundation.md"
---

# Workflow Engine and Durable Execution Roadmap

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The user described keiro as "a comprehensive event sourcing and workflow engine framework, possibly supporting durable execution in the future". This plan turns that intent into a concrete two-version roadmap and fixes the v1/v2 boundary so the rest of the keiro design (EP-1 through EP-4 and EP-6) can be specified without ambiguity about what is in scope today and what is deferred.

After this plan is complete, anyone with the keiro source tree can read `docs/research/10-workflow-roadmap.md` and answer:

- What does "workflow" mean in keiro v1? What primitives ship?
- What does it explicitly *not* mean in v1?
- What stretch features (durable execution, awakeables, child workflows, etc.) belong in v2, and what is the upgrade path on top of the v1 substrate?
- What operational complexity does v1 avoid by deferring v2?

This plan is *design-only*: no spike. The substance is selection, not feasibility — the prior-art survey at `docs/research/05-workflow-prior-art.md` already enumerates the design space and synthesizes a recommendation. This plan turns that recommendation into a roadmap that the rest of the project can refer to.

The user-visible behaviour the eventual library will deliver: in v1, workflow authors compose process managers (designed in EP-3) plus durable timers; in v2, they additionally compose journaled durable functions with named steps, sleeps, and external-completion handles. The roadmap fixes which features land in which version and why.


## Progress

- [x] M1.1 — Synthesize the v1 minimum-viable feature set from `docs/research/05-workflow-prior-art.md`. Completed 2026-05-06 (`docs/research/10-workflow-roadmap.md` §2).
- [x] M1.2 — Synthesize the v2 stretch feature set. Completed 2026-05-06 (`docs/research/10-workflow-roadmap.md` §6).
- [x] M1.3 — Pick the v2 durable-execution shape (named steps vs positional history) and justify. Completed 2026-05-06 (`docs/research/10-workflow-roadmap.md` §4 — named steps, with the rationale anchored against `docs/research/05-workflow-prior-art.md` §1 vs §4).
- [x] M1.4 — Specify how v1 process managers (EP-3) provide the substrate for v2 durable execution. Completed 2026-05-06 (`docs/research/10-workflow-roadmap.md` §5 — substrate continuity in terms of `SymTransducer phi rs sP cP cmd` for v1 and journaled `step` calls for v2; the migration story is mechanical, not a rewrite).
- [x] M1.5 — Identify the schema additions v2 will need and confirm none invalidate v1 schemas. Completed 2026-05-06 (`docs/research/10-workflow-roadmap.md` §7 — five v1 tables consolidated; v2 adds two more (`keiro_workflow_steps` index, `keiro_awakeables`); v1-to-v2 upgrade is in place with no migration of v1 tables).
- [x] M1.6 — Specify the durable-timer mechanism (a v1 feature; minimal table layout). Completed 2026-05-06 (`docs/research/10-workflow-roadmap.md` §3 — `keiro_timers` table with partial index on `status = 'pending'`, fire path via `FOR UPDATE SKIP LOCKED` plus a `TimerFired` append-and-status-flip in one `TxSessions.transaction`, cancellation via idempotent `status = 'cancelled'` flip).
- [x] M2.1 — Write `docs/research/10-workflow-roadmap.md`. Completed 2026-05-06 (eleven sections; cross-references EP-1 through EP-4 by file path; positions keiro v1 against Temporal/Restate/DBOS in §8).
- [x] M2.2 — Update `docs/research/00-overview.md`. Completed 2026-05-06 (new entry summarising §§2–8 with the v1/v2 split and the three forwarded EP-6 questions).


## Surprises & Discoveries

- 2026-05-06: Drafting §3 (durable timers) surfaced an open question that does not fit cleanly into any prior plan: the timer-firing worker is not adapter-shaped, so reusing shibuya's supervisor (which today supervises `(Adapter es msg, Handler es msg)` pairs) requires either a non-adapter-shaped worker entry point in shibuya or a degenerate adapter wrapper in keiro. Recorded in `docs/research/10-workflow-roadmap.md` §9 and forwarded to EP-6 as the third v1-substrate-driven question (alongside kiroku-side prefix-style category subscriptions for `pm:`/`wf:` streams and a keiki-side `compensate` direction on `SymTransducer`). **Cascade**: EP-6 gains three new shibuya/kiroku/keiki questions whose origin is the workflow surface rather than the command-cycle / codec / projection / snapshot surfaces. None are blockers for v1; all are quality-of-life choices that EP-6 prioritises against the existing backlog.
- 2026-05-06: The substrate-continuity argument (§5 of `docs/research/10-workflow-roadmap.md`) lands cleanly on EP-1's choice to make `SymTransducer phi rs s ci co` the keiro ⇄ keiki contract rather than the legacy `Decider` facade. Without `RegFile rs` exposed in the contract, the v1 PM could not carry timer fire-times and retry counters, and the v2 workflow could not store its journaled step results in a register-file-shaped value. The earlier MasterPlan Decision Log entry (2026-05-04) that rejected the `Decider` facade as the contract was load-bearing for the v2 roadmap; the workflow story would have been substantially weaker if it had stood. **Cascade**: no plan update needed — the decision is already recorded; this surprise is a positive validation that the foundation choice held up under v2 scrutiny.


## Decision Log

- Decision: Promote durable timers from "an unspecified v1 feature" to a fully-designed v1 primitive owned by this document (`docs/research/10-workflow-roadmap.md` §3). Schema, write path, cancel path, fire path, concurrency policy, and the question of whether to host the worker on shibuya's supervisor are all fixed.
  Rationale: M1.6 in this plan's Progress required a "minimal table layout" for timers. While drafting, it became clear that "minimal" is misleading — without specifying the cancellation contract (idempotent `status = 'cancelled'` flip), the fire-path atomicity (`TimerFired` append plus `status = 'fired'` flip in one `TxSessions.transaction`), and the `FOR UPDATE SKIP LOCKED` polling shape, the production implementer would have to re-derive the design. The full §3 is still ~70 lines and serves as the unambiguous source of truth without bloating the roadmap. Recorded here so future readers know §3's depth was deliberate, not feature creep.
  Date: 2026-05-06.

- Decision: Frame the v1 substrate continuity argument (§5) in terms of `SymTransducer phi rs sP cP cmd` rather than the `(state, event) -> (state, [command])` decider shape, even though the `Decider` shape is more pedagogically familiar.
  Rationale: The MasterPlan's 2026-05-04 Decision Log already retracted the "adopt Chassaing's decider as the keiki API" guidance. The v2 durable-execution roadmap depends on the register file `RegFile rs` being exposed in the contract — without it, the v2 workflow cannot store journaled step results in a register-file-shaped value, and the upgrade from v1 PM to v2 workflow becomes a rewrite rather than a re-expression. Sticking with `SymTransducer` keeps the substrate continuity story honest. The §5 prose still gives the `(state, event) -> (state, [command])` shape as the user's mental model — both are true; the contract is the transducer, the user-facing pattern is the decider shape.
  Date: 2026-05-06.

- Decision: keiro v1 ships event-sourced process managers (designed in EP-3) plus durable timers; deterministic-replay durable execution is deferred to v2.
  Rationale: Process managers cover ~90% of workflow use cases (sagas, choreography, multi-stream coordination) without the operational tax of a deterministic-replay runtime. Temporal/Restate-class systems are powerful but the cost of running them is enormous and most of it is paid to enable the determinism story (`docs/research/05-workflow-prior-art.md` "Opinionated synthesis"). Keep the upgrade door open.
  Date: 2026-05-04.

- Decision: When v2 durable execution lands, it will use *named-step* durability (Inngest-style), not positional-history determinism (Temporal-style).
  Rationale: Named steps make durability identifiers explicit (`step "charge-card" $ ...`), so cross-version evolution becomes a compile-time/lint problem instead of a runtime non-determinism nightmare. Identified as the single biggest UX win in `docs/research/05-workflow-prior-art.md` §1 vs §4.
  Date: 2026-05-04.

- Decision: v2's durable-execution journal will be persisted in kiroku, not in a separate "journal" table.
  Rationale: Uniformity with the rest of keiro; avoids a parallel storage mechanism; lets operators view a workflow's journal alongside the events it consumed. The journal is just another stream.
  Date: 2026-05-04.

- Decision: Durable timers are a v1 feature, not v2.
  Rationale: Process managers genuinely need them ("retry in 5 minutes if no payment confirmation"). Without timers, every timeout-based saga forces the application to integrate an external scheduler, which contradicts the "library, not server" thesis.
  Date: 2026-05-04.

- Decision: Durable-timer table is owned by keiro (`keiro_timers`), not by kiroku.
  Rationale: Timers are a workflow concern, not an event-store concern. Putting them in kiroku would force every event-store user to opinions about scheduling. EP-6 may revise this if a strong reason emerges.
  Date: 2026-05-04.

- Decision: v2 features (awakeables, child workflows, continue-as-new, versioning/patch API, multi-region, schema registry, LISTEN/NOTIFY push, consumer-group sharding, encryption) are explicitly out of v1 scope and not blockers for the upstream roadmap (EP-6).
  Rationale: Each adds operational complexity. Defer until v1 is in production and a real customer demand justifies the cost.
  Date: 2026-05-04.

- Decision: Retract the "Adopt Chassaing's decider as the user-facing API" guidance from `docs/research/05-workflow-prior-art.md`'s synthesis. The user-facing API is built on keiki's native `SymTransducer`, not the `Keiki.Decider` facade.
  Rationale: `Keiki.Decider` is a legacy compatibility shim; its `decide :: c -> s -> [e]` shape silently drops the register file `RegFile rs`, masks ε-edges, and discards the symbolic predicate carrier `phi`. v1 process managers (designed in EP-3) and v2 named-step durable execution both rely on register-file state (timers, retry counters, child-workflow handles) and on ε-edges to model silent state advancement. Adopting the Chassaing facade as the contract would force the workflow layer to reach around it on every interesting transition, defeating the purpose of using keiki at all. The decider/evolve *shape* remains a useful pedagogy for explaining ordinary aggregates to users; the actual contract is `SymTransducer` per EP-1.
  Date: 2026-05-04.


## Outcomes & Retrospective

EP-5 closed 2026-05-06. The single artifact is `docs/research/10-workflow-roadmap.md` (eleven sections, ~7300 words). Every `Validation and Acceptance` clause holds:

1. The doc exists and is referenced from `docs/research/00-overview.md` (new entry mirroring the §§2–8 split).
2. Every v1 feature has a paragraph in §2 with a cross-link to the EP that designs it (EP-1 for idempotent commands, EP-3 for projections + outbox + inbox + PMs + sagas-via-PMs, EP-4 for snapshots; durable timers are owned by §3 of the new doc).
3. Every v2 feature has a paragraph in §6 explaining why it is deferred — twelve features, each with a "what it is / why deferred" pair.
4. The v2 durable-execution API shape (§4) is fixed to four signatures: `step :: StepName -> Eff es a -> Workflow es a`, `sleep :: NominalDiffTime -> Workflow es ()`, `awakeable :: Workflow es (AwakeableId, Eff es a)`, `runWorkflow :: WorkflowId -> Workflow es a -> Eff es a`.
5. §5 explains the v1-to-v2 substrate continuity in terms of `SymTransducer phi rs sP cP cmd` for v1 PMs and journaled `step` calls for v2 workflows; the migration story is mechanical (re-express, don't rewrite) and concretely worked through with a fulfilment-saga example.
6. §9 forwards three open questions to EP-6: a kiroku-side prefix-style category subscription for `pm:`/`wf:` streams, a keiki-side `compensate` direction on `SymTransducer`, and a shibuya-side decision on whether to host the timer-firing worker on the supervised-worker substrate.

Phrased as observable behaviour: a reviewer who reads only `docs/research/10-workflow-roadmap.md` and `docs/research/05-workflow-prior-art.md` can explain (a) what keiro v1 is, (b) what it deliberately is not, and (c) what v2 will add — without consulting external Temporal/Restate/DBOS material. The "competitive position" statement in §8 ("a Haskell-first, Postgres-native, library-shaped event-sourcing engine with first-class process managers and durable timers in v1, and an explicit upgrade path to named-step durable execution in v2") is anchored in concrete API shapes and concrete deferral rationales, not in marketing prose.

Lessons learned:

- *§3's depth was the right call.* The original plan-of-work called for "minimal table layout" for timers. Producing only a `CREATE TABLE` would have left the fire-path atomicity, the idempotent-cancellation contract, and the `FOR UPDATE SKIP LOCKED` polling shape under-specified. Fixing them in §3 means the production implementer has one source of truth.
- *Substrate continuity (§5) is load-bearing.* The argument that a v1 PM is "a v2 workflow with one explicit step" — and conversely a v2 workflow is "a PM whose step function happens to be journaled call-by-call" — is the single most important claim the roadmap makes. Without it, v2 looks like a rewrite; with it, v2 is an extension. The `SymTransducer` framing (rather than `Decider`) was essential to make the claim precise.
- *Twelve v2 deferrals is the right number.* Splitting "stretch features" into a list of one-paragraph entries keeps each deferral honest — each one names what it is, why it is deferred, and (often) what the v1 alternative is. Three deferrals would have been too coarse; twenty would have been make-work.

Gaps remaining:

- v2 implementation is out of scope for the research MasterPlan. The v2 surface (`step`/`sleep`/`awakeable`/`runWorkflow`) is fixed at the type-signature level only; the effect handler implementation, the journal-stream-per-workflow infrastructure, the re-entry-on-crash logic, and the v1-to-v2 migration tooling are all future work.
- The three open questions in §9 await EP-6's synthesis. None block v1; all three are quality-of-life choices that affect the v1 substrate's polish rather than its correctness.

The next plan in the MasterPlan's dependency graph is EP-6 (`docs/plans/6-upstream-roadmap-for-kiroku-and-keiki.md`), which consolidates the upstream feature gaps from EP-1 through EP-5 into the kiroku/keiki/shibuya backlog.


## Context and Orientation

Repository layout. Working tree at `/Users/shinzui/Keikaku/bokuno/keiro`.

Existing surveys this plan synthesizes:

- `docs/research/05-workflow-prior-art.md` — Temporal, Restate, DBOS, Inngest, Eventide, Akka, EventStoreDB/Marten, Reactive Manifesto + DDD, Haskell prior art. Distils a v1 / v2 split.
- `docs/research/02-keiki-decide-loop.md` — keiki's pure decider/evolve. Notes that keiki has *no* process-manager primitive today; one must live in keiro (EP-3).
- `docs/research/03-shibuya-subscriptions.md` — shibuya's subscription engine. Notes "no durable timer / scheduled-event generation" as a gap.

Term definitions (precise, since this plan defines the vocabulary the rest of the docs use):

- *Workflow* — the general, vague term users will reach for. In v1 it means "process manager", documented in EP-3. In v2 it means a journaled durable function whose execution is checkpointed at named steps.
- *Process manager* — an event-sourced coordinator with a `(state, event) -> (state, [command])` step function. Subscribes to one or more event categories. Maintains its state in its own kiroku stream. v1 substrate for workflow.
- *Durable execution* — execution model where a function can be paused and resumed across crashes/redeployments by replaying recorded checkpoints. The hallmark of Temporal, Restate, Inngest, DBOS.
- *Named step* — a fragment of a durable function uniquely identified by a string label, not by source position. A retry replays only un-checkpointed steps.
- *Positional history* — the alternative durability discriminator: the position of the step in the function's call sequence. Brittle under code changes.
- *Awakeable* — a durable promise resolved by an external system, identified by an opaque id. Useful for human-in-the-loop, third-party callbacks, agentic AI loops.
- *Child workflow* — a workflow spawned by a parent workflow, recorded in the parent's journal so the parent can wait/cancel.
- *Continue-as-new* — explicit primitive for unbounded workflows: snapshot state, rotate journal stream, resume.
- *Durable timer* — a `(fire_at, payload)` row in a database, polled by a worker; on fire, the payload is dispatched (typically as a command into a stream).

What does **not** exist today in keiro:

- No process-manager primitive (EP-3 will introduce it).
- No durable-timer table.
- No durable-execution runtime.
- No "step" abstraction.

What *does* exist in the dependency stack:

- Postgres advisory locks, transactions, JSONB.
- shibuya supervised workers.
- pgmq-hs durable queue.
- kiroku append/read with optimistic concurrency.

The substrate for v1 workflows is therefore: kiroku (event log + process-manager state streams) + shibuya (subscription engine) + a new `keiro_timers` table polled by a worker. The substrate for v2 durable execution adds: named-step journal streams (one per durable-function instance), an effect handler that records steps, and a replay loop that re-enters the function and short-circuits already-recorded steps.


## Plan of Work

One milestone, design-only.

### Milestone 1 — Roadmap document

Write `docs/research/10-workflow-roadmap.md`. Self-contained. Structure:

- *Problem statement* — why "workflow" needs explicit scope; why deterministic-replay durable execution is dangerous to ship without justification.
- *v1 minimum* — the feature set that ships in v1, with one paragraph each:
  1. Process managers (designed in EP-3).
  2. Durable timers (`keiro_timers` table, polling worker, fires payloads as kiroku appends).
  3. Transactional outbox / inbox (designed in EP-3).
  4. Saga pattern via process managers + explicit compensation events (no separate saga primitive — sagas *are* process managers with compensation).
  5. Inline projections for read models (designed in EP-3).
  6. Snapshots (designed in EP-4).
  7. Idempotent commands (designed in EP-1).
- *v2 stretch* — the feature set deliberately deferred:
  1. Deterministic-replay durable execution with named steps.
  2. Awakeables.
  3. Child workflows.
  4. Continue-as-new.
  5. Versioning/patch API.
  6. Multi-region.
  7. Server-side scripted projections (rejected outright — `docs/research/05-workflow-prior-art.md` §7 "Avoid").
  8. Consumer-group sharding for category subscriptions.
  9. Cluster-aware leadership.
  10. Schema registry.
  11. LISTEN/NOTIFY push delivery.
  12. Field-level encryption / GDPR crypto-shredding.
- *v2 design preview* — for the durable-execution feature specifically, sketch the API:

      step :: StepName -> Eff es a -> Workflow es a
      sleep :: NominalDiffTime -> Workflow es ()
      awakeable :: Workflow es (AwakeableId, Eff es a)
      runWorkflow :: WorkflowId -> Workflow es a -> Eff es a

  With prose explaining: every `step` is journaled to a kiroku stream `wf:<workflow-name>-<workflow-id>` with a `StepRecorded { name, result }` event; replay re-enters the function and short-circuits any `step` whose name appears in the journal. Sleep is a durable timer. Awakeable allocates an id and yields a continuation that resolves when the id is signalled.
- *Substrate continuity* — explain how v1 process managers become a special case of v2 workflows. A process manager is itself a `SymTransducer phi rs sP cP cmd` whose input alphabet `cP` includes the source-aggregate's events (often via `compose`/`alternative`) and whose output alphabet `cmd` is the targeted aggregates' commands. The register file `RegFile rs` carries timer fire-times, retry counters, and correlation IDs. v2 durable execution sits on top: a workflow function is sugar over a journaled execution of `step` calls keyed by named steps, where each step's result becomes a register-file slot and replay short-circuits on already-recorded slot values.
- *Schema additions* — list the tables v1 introduces (`keiro_timers`, plus EP-3's `subscriptions`-extension and EP-4's `keiro_snapshots`) and confirm v2 adds at most one more (a `keiro_workflow_steps` index for fast step lookup; the journal itself is in kiroku).
- *Operational comparison* — one paragraph each: keiro v1 vs Temporal, vs Restate, vs DBOS. Cite `docs/research/05-workflow-prior-art.md` for evidence. Conclude with the positioning statement: "a Haskell-first, Postgres-native, library-shaped event-sourcing engine with first-class process managers and an explicit upgrade path to durable execution".
- *Open questions* — explicit list of items for EP-6 to consume:
  - kiroku-side: should the process-manager state stream be a special category, or an arbitrary one named by convention?
  - keiki-side: does `SymTransducer`'s `step` need a `compensate` direction (a separate map from event-and-state to compensating command) for sagas, or is compensation just an application-level event handled by an ordinary edge in the transducer?
  - shibuya-side: does the durable-timer worker reuse shibuya's supervisor, or is it a stand-alone worker?

Acceptance: doc exists, references EP-1/EP-3/EP-4 by file path for substrate features, and a reviewer can answer "is durable execution coming?" with "in v2, with this specific shape, on top of this specific v1 substrate".


## Concrete Steps

Working directory `/Users/shinzui/Keikaku/bokuno/keiro` unless noted.

Write the roadmap doc:

    # author docs/research/10-workflow-roadmap.md per Plan of Work milestone 1
    # update docs/research/00-overview.md to add the new entry


## Validation and Acceptance

All must hold:

1. `docs/research/10-workflow-roadmap.md` exists and is referenced from `docs/research/00-overview.md`.
2. The doc lists every v1 feature with a sentence and a cross-link to the plan that designs it.
3. The doc lists every v2 feature with a sentence explaining why it is deferred.
4. The doc fixes the v2 durable-execution API shape (the four function signatures above).
5. The doc explains the substrate continuity: how a v1 process manager becomes a v2 workflow without rewriting.
6. The doc identifies the open questions to forward to EP-6.

Phrased as observable behaviour: a reviewer who reads only this document and `docs/research/05-workflow-prior-art.md` can explain what keiro v1 is, what it isn't, and what v2 will add — without consulting any external Temporal/Restate/DBOS material.


## Idempotence and Recovery

The roadmap is a Markdown file; saving twice is a no-op. If a downstream plan (EP-3, EP-4) materially shifts the v1 substrate, update this plan's v1 list accordingly and append a revision note.


## Interfaces and Dependencies

This plan does not introduce code; it consumes:

- `docs/research/05-workflow-prior-art.md` — the literature survey.
- EP-1's design — for the command-cycle substrate.
- EP-3's design — for the process-manager and outbox substrate.
- EP-4's design — for the snapshot substrate.

Downstream consumers:

- EP-6 (upstream roadmap) — receives the open questions identified here, particularly anything that touches kiroku or keiki schemas.

Function signatures the design must fix (preview only; v2 implementation is out of MasterPlan scope):

    -- Keiro.Workflow (v2 preview)
    data WorkflowId
    data StepName = StepName Text
    data AwakeableId
    step       :: StepName -> Eff es a -> Workflow es a
    sleep      :: NominalDiffTime -> Workflow es ()
    awakeable  :: Workflow es (AwakeableId, Eff es a)
    runWorkflow :: WorkflowId -> Workflow es a -> Eff es a


## Revisions

- 2026-05-04: Retracted the "Adopt Chassaing's decider as the user-facing API" recommendation that originated in `docs/research/05-workflow-prior-art.md`'s synthesis. The proper contract is keiki's native `SymTransducer` per EP-1; `Decider` is a legacy compat facade. Reframed the substrate-continuity section to describe v1 process managers as `SymTransducer`s whose register file carries timer/retry state, and v2 durable execution as a journaled overlay on top of `step`. Reframed the keiki-side open question about saga compensation in terms of `step`'s direction rather than `Decider`. Reason: workflow features depend on register-file slots and ε-edges that the Chassaing facade hides.

- 2026-05-06: EP-5 closed. `docs/research/10-workflow-roadmap.md` published (eleven sections); `docs/research/00-overview.md` updated; M1.1–M2.2 ticked off; two new entries appended to Surprises & Discoveries (the §3 depth lesson and the substrate-continuity validation against the 2026-05-04 `SymTransducer`-as-contract decision); two new entries appended to Decision Log (the deliberate depth of §3 and the choice to frame substrate continuity in `SymTransducer` terms rather than the `Decider` shape). The MasterPlan's `Exec-Plan Registry` marks EP-5 Complete; only EP-6 (synthesis) remains. No cascade to other ExecPlans: EP-1's `esSnapshotPolicy` slot (renamed from `aggSnapshotPolicy` on 2026-05-08), EP-3's PM substrate, and EP-4's snapshot path are all referenced by EP-5 without modification. Reason: M1.1–M2.2 acceptance criteria all hold; the v1/v2 vocabulary is now fixed in a single document the rest of the project can refer to.
