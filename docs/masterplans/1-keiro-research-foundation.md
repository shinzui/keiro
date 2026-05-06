---
id: 1
slug: keiro-research-foundation
title: "keiro Research Foundation"
kind: master-plan
created_at: 2026-05-04T20:11:59Z
intention: "intention_01kqt8d9t8ehb84kgs19qa1rs9"
---

# keiro Research Foundation

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

経路 ("keiro") is a Haskell library that turns the existing components — kiroku (Postgres event store), keiki (pure decider/evolve core), shibuya (subscription engine), shibuya-pgmq-adapter, shibuya-kiroku-adapter, pgmq-hs — into a single, production-quality event-sourcing and workflow engine. The framework will replace an in-production system, so correctness, observability, and operational simplicity are non-negotiable. The framework is library-shaped: applications import keiro and connect to a Postgres database; there is no separate server to operate.

The runtime substrate is already opinionated and *shared across these components*: Postgres for storage, `hasql` for SQL, `effectful` for the effect system, and **`streamly` (composewell) for every stream of messages or events the framework moves**. Shibuya's adapter abstraction is `Stream (Eff es) (Ingested es msg)` and its runners are built on `Stream.fold Fold.drain`-shaped pipelines; kiroku-store's subscription bridge (`Kiroku.Store.Subscription.Stream`) returns a `Streamly.Data.Stream.Stream`. keiro's own abstractions — hydration pipelines, projection runners, process-manager loops, outbox relays, snapshot-accelerated replay — are expected to be expressed with the same `Stream` and `Fold` types and the broader Streamly primitive set (e.g. `Stream.unfoldrM`, `Stream.morphInner`, `Fold.foldlM'`, `Stream.foldMany`). This is not a future bet; it is the shape the dependencies already impose.

The single user-visible behavior keiro must enable is the canonical command-handling cycle: a caller submits a command targeting an aggregate, the framework loads that aggregate's events from kiroku, folds them into state via keiki, runs the decider, and appends new events back to kiroku with optimistic concurrency. The same primitive supports projections (synchronous or asynchronous), process managers (event-sourced workflow coordinators), and — in a later phase — durable execution of long-running workflows.

This MasterPlan is **not** the implementation plan. Its purpose is to take keiro from "scaffold" to "ready to implement". After the surveys in `docs/research/01-...` through `docs/research/05-...` (which describe the current state of the dependencies and the prior art), each child ExecPlan in this MasterPlan produces a concrete *design document* — and where appropriate a small Haskell *spike* — that resolves a specific design question. Together they yield a complete, internally consistent design for keiro v1.

In scope: the design and validation of (1) the load → fold → decide → append cycle including its transactional semantics and retry behaviour, (2) the codec / event-schema layer, (3) projections, subscriptions, and process managers (including the transactional outbox), (4) snapshots, (5) the workflow / durable-execution roadmap, and (6) the consolidated set of upstream feature gaps that kiroku and keiki must close in parallel.

Out of scope: writing the production keiro library itself; that is a separate MasterPlan to be authored after this one is complete. Stretch features identified for v2 (full deterministic-replay durable execution, awakeables, child workflows, multi-region, schema registry, LISTEN/NOTIFY-based push delivery, consumer-group sharding, field-level encryption) are documented in the workflow roadmap but are deliberately deferred.


## Decomposition Strategy

The decomposition is by functional concern, with one ExecPlan per top-level keiro capability. The choice of six plans follows the principle in `MASTERPLAN.md` (two-to-seven plans per MasterPlan; introduce phases when more are needed). Each plan owns a coherent design surface, can be reviewed independently by a domain expert, and produces an artifact (a `docs/research/NN-*.md` design document, sometimes accompanied by a Haskell spike under a clearly labelled directory) that is independently verifiable.

The user explicitly identified the load → fold → decide → append cycle as the most important research surface. That cycle is therefore plan 1 and is the only plan with a substantive *implementation* spike — every other plan validates its design with prose and (where necessary) a tiny throwaway prototype rather than production-shaped code. Plan 1 is also the foundation that the other plans assume: codecs (plan 2), subscriptions and process managers (plan 3), and snapshots (plan 4) all extend or accelerate the same cycle, and the workflow roadmap (plan 5) builds on top of process managers introduced in plan 3.

Alternatives considered:

- **One mega-plan covering the entire framework design.** Rejected: it would breach the "fewer than seven" guidance only by replacing six well-bounded plans with one unwieldy plan. Independent reviewability would be lost.
- **Splitting the command cycle into separate "hydration" and "command bus" plans.** Rejected: hydration without an append target is meaningless, and the optimistic-retry loop straddles both halves. Splitting would create artificial integration points where there are none.
- **A separate plan per upstream gap (kiroku-side, keiki-side).** Rejected: gaps can only be enumerated correctly *after* the keiro-facing design is settled, so they collapse naturally into a single synthesis plan (plan 6).
- **A plan dedicated to the transactional outbox.** Rejected: the outbox is one feature inside the projections / process-managers concern (plan 3) and does not warrant its own plan.

The result is one foundation plan, four parallel research plans, and one synthesis plan, in a phased shape:

- **Phase A — Foundation.** Plan 1 (command cycle) must complete first, because every other plan refers to its types and combinators.
- **Phase B — Parallel research.** Plans 2, 3, 4, and 5 can run concurrently after Phase A. Each is self-contained relative to the others: plan 2 does not need plan 3's snapshots, and so on.
- **Phase C — Synthesis.** Plan 6 (upstream roadmap) reads the outputs of plans 1–5 and produces a single consolidated list of upstream feature work to land in kiroku and keiki.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Command Cycle Design and Spike | docs/plans/1-command-cycle-design-and-spike.md | None | None | Complete |
| 2 | Codec and Event Schema Strategy | docs/plans/2-codec-and-event-schema-strategy.md | EP-1 | None | In Progress |
| 3 | Subscriptions, Projections and Process Managers | docs/plans/3-subscriptions-projections-and-process-managers.md | EP-1 | EP-2 | Not Started |
| 4 | Snapshot Strategy and Hydration Acceleration | docs/plans/4-snapshot-strategy-and-hydration-acceleration.md | EP-1 | EP-2 | Not Started |
| 5 | Workflow Engine and Durable Execution Roadmap | docs/plans/5-workflow-engine-and-durable-execution-roadmap.md | None | EP-3 | Not Started |
| 6 | Upstream Roadmap for Kiroku and Keiki | docs/plans/6-upstream-roadmap-for-kiroku-and-keiki.md | EP-1, EP-2, EP-3, EP-4, EP-5 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled. Hard Deps and Soft Deps reference other rows by their `EP-N` prefix.


## Dependency Graph

The plan order is foundation → parallel research → synthesis.

EP-1 (command cycle) is the foundation. It defines the types and combinators every other plan refers to: `AggregateId a`, `runCommand`, the optimistic-retry loop, and the transactional-step primitive. Until those types are written down, EP-2 cannot pick a codec signature, EP-3 cannot describe how a process manager runs a mini command cycle, and EP-4 cannot describe how a snapshot accelerates the hydration phase. EP-1 therefore has no dependencies and must complete first.

EP-2 (codecs) hard-depends on EP-1 because the codec layer must produce the exact types the command cycle expects (typed events going into `EventData.payload`, decoded back into the keiki domain type). EP-2 can be drafted in parallel with EP-1 once the latter has fixed its public types in the design document, but a clean validation of EP-2 requires EP-1's spike.

EP-3 (subscriptions, projections, process managers) hard-depends on EP-1 because a subscription handler that reacts to events and emits commands runs a *miniature* command cycle internally, including optimistic retry. It soft-depends on EP-2 because subscription handlers prefer typed events over raw `Value` payloads. If EP-2 slips, EP-3 can use untyped payloads in its prototype with a clearly labelled "TODO swap to typed".

EP-4 (snapshots) hard-depends on EP-1 because the snapshot path is an optimization of EP-1's hydration phase, and the snapshot decoder must agree with the codec layer (soft dep on EP-2). It does not block any other plan; it can be deferred safely.

EP-5 (workflow roadmap) does not hard-depend on any other plan: it is mostly literature work derived from `docs/research/05-workflow-prior-art.md`. It soft-depends on EP-3 because process managers are the v1 stand-in for a "real" workflow engine, and the roadmap must align with what EP-3 actually delivers. EP-5 can run early and in parallel with the others.

EP-6 (upstream roadmap) hard-depends on every other plan because it consolidates the feature gaps each plan identifies in kiroku and keiki. It is the final synthesis step.

Plans that can proceed in parallel: EP-2, EP-3, EP-4, and EP-5 once EP-1 is complete.


## Integration Points

Several artifacts are touched by more than one child plan; each must be defined once and consumed elsewhere identically.

**`Keiro.Command.runCommand` and supporting types.** Defined in EP-1's design document and demonstrated by EP-1's spike. Consumed verbatim by EP-3 (process managers wrap `runCommand` for their internal write path) and EP-4 (snapshot-accelerated hydration must produce a result indistinguishable from full replay). EP-2 must agree with the codec types `runCommand` expects on its event payload boundary. The canonical type signature, error model, and retry semantics live in EP-1 and are referenced by file path from the other plans.

**`AggregateId a` newtype and aggregate-type machinery.** Defined in EP-1. Consumed by every other plan whenever a stream is named at a type level. EP-2 may extend it with a `HasCodec` superclass; EP-3 reuses it for process-manager identity; EP-4 keys snapshots by it; EP-6 lists "no typed `StreamId` per aggregate" as a kiroku-side gap and decides whether the typed wrapper lives in keiro or migrates upstream.

**Codec typeclass / interface for events.** Defined in EP-2. Consumed by EP-1 (encode/decode at the kiroku boundary), EP-3 (subscription handlers decode `RecordedEvent.payload` into the typed event sum), and EP-4 (snapshot serialization). EP-2 owns the version-evolution / upcaster story; the other plans reference EP-2 for the canonical signature and *do not* invent their own. Prior art to evaluate: the `hindsight` Haskell library at `/Users/shinzui/Keikaku/hub/haskell/hindsight` — see `hindsight-core/src/Hindsight/Events.hs` and `hindsight-core/src/Hindsight/Events/Internal/Versioning.hs`. Hindsight encodes event identity as a type-level `Symbol`, payload versions as a `Versions` type-family list with a separate `MaxVersion`, schema migrations as one `Upcast n` instance per consecutive transition that the compiler automatically composes via a `MigrateVersion` class, and supplies a `parseMap` that yields a version-indexed JSON parser map plus a test-generation toolkit (`hindsight-core/event-test-lib/Test/Hindsight/Generate.hs`) that derives roundtrip and golden tests for every declared version. EP-2 must read this code, decide whether the type-level versioning approach earns its keep relative to the simpler `[(Int, Value -> Either String Value)]` upcaster chain currently sketched in the EP-2 plan, and record the verdict in `docs/research/07-codec-strategy.md`. The answer may be "adopt", "borrow ideas selectively", or "reject with rationale" — but it must be argued, not omitted.

**Transactional-step primitive.** Defined in EP-1 (combinator that opens a hasql `TxSessions.transaction ReadCommitted Write` block, performs the append plus user-supplied SQL, commits as one). Consumed by EP-3 for inline projections (append events + update read-model rows in one tx) and the outbox (append events + insert outbox rows). EP-4 may use it for the snapshot write path. EP-6 must record any kiroku-store change required for the primitive to be expressible cleanly (currently single-stream append does not open a Haskell-layer transaction).

**Subscription checkpoint table.** Defined in EP-3 in the new `subscriptions` Postgres table layout (extending kiroku's existing `subscriptions(subscription_name, last_seen)` row). EP-4 must not collide with this table when writing snapshots. EP-6 records any required schema migrations for kiroku.

**Process-manager state stream.** Defined in EP-3: a process manager is itself event-sourced, with its own kiroku stream (e.g., `pm-OrderFulfillment-<id>`). EP-5 references this stream as the v1 substrate for "workflow state" and must explain how a future v2 durable-execution layer relates to it.

**Streamly `Stream` and `Fold` substrate.** Not owned by any single plan because it is *already in use* by the dependencies: shibuya's `Adapter` interface is `source :: Stream (Eff es) (Ingested es msg)` and shibuya's runners (`Shibuya/Runner/Serial.hs`, `Shibuya/Runner/Ingester.hs`, `Shibuya/Runner/Supervised.hs`) consume those sources via `Stream.fold Fold.drain` plus combinators like `Stream.mapM`, `Stream.unfoldrM`, `Stream.morphInner`, and `Fold.take`/`Fold.toList`. Kiroku-store's subscription bridge (`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`) similarly returns a `Streamly.Data.Stream.Stream`. Every keiro abstraction that moves more than one event — hydration (EP-1's read-decode-fold of a stream's events), inline projections, async projections (EP-3), the outbox relay (EP-3), process-manager event consumption (EP-3), and snapshot-accelerated tail replay (EP-4) — is expected to be expressed as a Streamly `Stream` produced upstream and folded into the relevant terminal effect (`Fold.foldlM'` for state, `Fold.drain` for side effects, `Fold.take`/`Fold.toList` for batching). Each child plan must, in its own design document, name the specific `Stream`/`Fold` shape its primitives expose, and must not introduce a parallel streaming abstraction (`conduit`, `pipes`, lazy lists, `Vector`-of-events held in memory) where streamly suffices. The version of streamly is fixed by shibuya's `cabal.project`; keiro tracks it.

**`docs/research/` numbering convention.** EP-1 produces `docs/research/06-command-cycle-design.md`. EP-2 produces `07-codec-strategy.md`. EP-3 produces `08-subscription-and-process-manager-design.md`. EP-4 produces `09-snapshot-strategy.md`. EP-5 produces `10-workflow-roadmap.md`. EP-6 produces `11-upstream-roadmap.md`. The numbers continue from the surveys (01–05) already in place. Each plan must use exactly its assigned number to keep the index in `docs/research/00-overview.md` accurate.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan and the milestone.

- [x] EP-1 M1: Spike — minimal `runCommand` end-to-end against a Postgres test database. Completed 2026-05-05 (`spikes/command-cycle/`; transcript ends `[spike] OK`).
- [x] EP-1 M2: Design document — types, error model, retry semantics, transactional step, multi-aggregate command shape. Completed 2026-05-05 (`docs/research/06-command-cycle-design.md`).
- [ ] EP-2 M1: Spike — round-trip a sample aggregate's events through the codec.
- [ ] EP-2 M2: Design document — codec interface, schema versioning, upcasters, unknown-event policy.
- [ ] EP-3 M1: Spike — inline projection + async projection + tiny process manager.
- [ ] EP-3 M2: Design document — projection lifecycles, transactional outbox, process-manager state.
- [ ] EP-4 M1: Design document — sidecar snapshots table, write/read path, GC, rebuild on schema change.
- [ ] EP-5 M1: Roadmap document — v1 process-manager substrate and v2 named-step durable execution.
- [ ] EP-6 M1: Synthesis — consolidated kiroku/keiki feature list with priority and rationale.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected interactions between child plans. Provide concise evidence.

- 2026-05-05 (EP-1): keiki's `solveOutput` only inverts direct term shapes (`TLit`, `TReg`, `TInpCtorField`). Computed terms (`TApp1`, `TApp2`) cause replay to fail with `Nothing`. Aggregate authors must restrict event payloads to direct projections of input fields; the state delta lives on the edge's `update`. **Cascade**: EP-2 must call this out in its codec-design document; EP-6 should record an upstream request that keiki lift the constraint to compile-time. EP-3 and EP-4 are not affected (they consume the same constraint indirectly via the `Aggregate` contract). Evidence: spike's first run crashed on `Incremented {newValue = counter + 1}` at scenario 1's second command; `docs/plans/1-command-cycle-design-and-spike.md` Surprises log; `docs/research/06-command-cycle-design.md` §5 invariant.
- 2026-05-05 (EP-1): kiroku's embedded `schema.sql` uses Postgres 18's `uuidv7()` function. Production deployments must run PG 18+; the user's outer nix profile ships PG 17.9, kiroku-project's flake pins `pkgs.postgresql_18`. **Cascade**: EP-6 must record this as a deployment prerequisite for the production keiro library. No EP-2/EP-3/EP-4/EP-5 impact at the design layer; the constraint surfaces only at the running-process layer.
- 2026-05-05 (EP-1): kiroku-store's single-stream `appendToStream` does not open a Haskell-layer transaction (only `appendMultiStream` does). The transactional-step combinator (§10 of `docs/research/06-command-cycle-design.md`) cannot be implemented cleanly until kiroku-store exposes a public combinator that wraps a single-stream append plus a user-supplied `Hasql.Transaction.Transaction a` in one tx. **Cascade**: EP-3's inline projections and outbox depend on this; the EP-3 design doc must explicitly describe the workaround (route through `appendMultiStream` with a singleton list) until the upstream lands. EP-6 records the request.
- 2026-05-05 (EP-1): The Effectful effect-stack ordering for `runStorePool` plus `Error StoreError` is non-obvious — the StoreError handler must be applied *outside* `runStorePool` because `runStorePool` requires `Error StoreError :> es` to throw. The spike's first runner-composition put the handler in the wrong position and produced `[GHC-64725] There is no handler for 'Error StoreError'`. **Cascade**: design-doc §4 records the working order. Every plan that wires keiro's effects (EP-3 process managers, EP-4 snapshot writes, EP-5 workflow runtime) needs to follow the same convention.


## Decision Log

- Decision: Decompose research into six child plans (command cycle, codecs, subscriptions/projections/process-managers, snapshots, workflow roadmap, upstream roadmap).
  Rationale: One plan per functional concern; satisfies MASTERPLAN.md's two-to-seven guidance; matches the user's stated priority that the load → fold → decide → append cycle is the single most important surface.
  Date: 2026-05-04.

- Decision: Treat EP-1 as the foundation; gate every other plan on it (hard dep for EP-2, EP-3, EP-4, EP-6; soft for EP-5).
  Rationale: Every other capability extends or consumes the command cycle's types, error model, and transactional primitives. Letting them race ahead with placeholders would force expensive rework when EP-1 lands.
  Date: 2026-05-04.

- Decision: Ship a working spike (Haskell code under a `spikes/` directory the plan creates) for EP-1, EP-2, and EP-3; treat EP-4, EP-5, and EP-6 as design-only.
  Rationale: The cycle, codecs, and subscriptions are where unknowns concentrate; a small executable end-to-end demo is the only way to retire those risks. Snapshots (EP-4), the workflow roadmap (EP-5), and the upstream synthesis (EP-6) are dominated by literature and design choices, not feasibility.
  Date: 2026-05-04.

- Decision: Number new design documents `docs/research/06-…` through `docs/research/11-…`, continuing from the five current-state surveys (01–05).
  Rationale: Preserves a single linear index. EP-6 (the upstream roadmap) lands at `11-` so reviewers can read the synthesis last.
  Date: 2026-05-04.

- Decision: Adopt the prior-art guidance from `docs/research/05-workflow-prior-art.md` as the starting opinion: Postgres-only, `hasql`-only, `effectful`-only, **`streamly`-only** for in-process streaming pipelines; defer Temporal/Restate-style deterministic replay to v2; v1 ships event-sourced process managers.
  Rationale: The five reference systems converge on this trade-off. Litigating it again per child plan would waste effort. Streamly is added to the locked substrate list because shibuya and kiroku-store already hand back Streamly `Stream`s; introducing `conduit` or `pipes` at the keiro layer would force impedance-matching at every adapter boundary.
  Date: 2026-05-04.

- Decision: Develop kiroku and keiki feature gaps in parallel with keiro design (recorded in EP-6) rather than blocking keiro on upstream releases.
  Rationale: User stated explicitly that both libraries still need more features and that the work would proceed in parallel. EP-6 produces the prioritized list for the upstream maintainers; the keiro design proceeds against the current versions plus EP-6's anticipated additions documented as TODOs.
  Date: 2026-05-04.

- Decision: Reject `Keiki.Decider` as the keiro ⇄ keiki contract. EP-1 must derive the proper contract from first principles, anchored on keiki's native `SymTransducer phi rs s ci co` (and the operations `step`, `delta`, `omega`, `applyEvent`, `applyEvents`, `reconstitute`).
  Rationale: User clarified that `Keiki.Decider` is a legacy compatibility facade. The richer keiki primitive — `SymTransducer` with its register file `RegFile rs`, ε-edges, and symbolic predicates — is what supports both event sourcing *and* workflows. Adopting the facade as the contract would amputate every workflow feature keiki actually offers (timers and retry counters in registers, silent state transitions via ε-edges, future symbolic verification via z3). Supersedes the earlier "Adopt Chassaing's decider" guidance in EP-5's preliminary Decision Log.
  Date: 2026-05-04.

- Decision: Treat Streamly's `Stream` and `Fold` (and the broader Streamly primitive set — `unfoldrM`, `morphInner`, `mapM`, `foldlM'`, `foldMany`, `take`, `drain`, `repeatM`, `catMaybes`, `filter`, …) as the canonical in-process streaming substrate for keiro, alongside `hasql` and `effectful`.
  Rationale: Shibuya and kiroku-store already expose every multi-event boundary as a Streamly `Stream` (verified in `Shibuya/Adapter.hs`, `Shibuya/Stream.hs`, `Shibuya/Runner/{Serial,Ingester,Supervised}.hs`, and `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`). Keiro will be expressed in the *same* primitives so adapter boundaries are zero-cost composition, not impedance-matching shims. Each child plan must pick the concrete `Stream`/`Fold` shape its own primitives expose (hydration as `Stream → Fold` over a stream's events, projection lifecycles as `Stream` ⇒ `Fold.drain`, outbox relay as `Stream` ⇒ pgmq enqueue, snapshot-accelerated tail replay as `Stream` from `snapshot.version + 1`). EP-1, EP-3, and EP-4's design documents must each name the streamly types they introduce; EP-2 (pure codecs) and EP-5 (workflow roadmap) are unaffected at the substrate level. EP-6 records that no upstream streamly-related work is needed (it is already a transitive dependency through shibuya and kiroku-store).
  Date: 2026-05-04.

- Decision: Remove the recommendation to adopt Marten's high-water-mark for async-subscription gap handling. Rely on kiroku's existing Strategy E global-position guarantees instead.
  Rationale: Kiroku's `docs/DESIGN.md` documents Strategy E (atomic `UPDATE ... RETURNING` on the `$all` row, `stream_id = 0`, claiming contiguous positions inside the same transaction that inserts events). This produces *gap-free contiguous* `globalPosition`s (1, 2, 3, …), immediate read-your-own-writes, and no MVCC vulnerability — explicitly chosen to *avoid* Marten's HWM operational tax. Recommending HWM would have re-introduced the very complexity kiroku rejected. The earlier guidance in EP-3's Decision Log and `docs/research/05-workflow-prior-art.md`'s synthesis (which was authored without seeing kiroku's design notes) is superseded.
  Date: 2026-05-04.

- Decision: EP-2 must evaluate the `hindsight` Haskell library (`/Users/shinzui/Keikaku/hub/haskell/hindsight`) as prior art for event schema evolution before settling its codec design. Outcome of the evaluation may be adopt, selectively borrow, or reject — but the reasoning must be recorded in `docs/research/07-codec-strategy.md`.
  Rationale: Hindsight's compile-time versioning machinery (`MaxVersion` / `Versions` type families, consecutive `Upcast n` instances composed automatically by `MigrateVersion`, version-indexed `parseMap`, and the auto-generated roundtrip/golden test toolkit in `Test.Hindsight.Generate`) is closer to a finished answer to "how do typed Haskell events evolve over time" than the `[(Int, Value -> Either String Value)]` chain currently sketched in EP-2. The user flagged it as potentially useful but uncertain; this decision converts that uncertainty into an explicit research item rather than letting it drop. The library is BSD-3 and self-contained, so adoption is technically viable; the live question is whether the type-level machinery's complexity earns its keep against keiro's simpler value-level alternative, given keiro's existing constraints (Postgres-only, kiroku already stores `Aeson.Value`, codec must coexist with keiki's `SymTransducer co` output type).
  Date: 2026-05-05.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare the result against the original vision.

(To be filled during and after the research is complete. The expected exit criterion is: a self-consistent design across `docs/research/06-` through `docs/research/11-`, three working spikes, and a kiroku/keiki upstream-feature backlog ready to feed an implementation MasterPlan.)


## Revisions

- 2026-05-04: Added Streamly to the framework's locked runtime substrate (Vision & Scope paragraph 2; Integration Points new entry; expanded the prior-art Decision Log entry; new Decision Log entry making the choice explicit). Cascaded to EP-1, EP-3, EP-4, and EP-6. Reason: kiroku-store and shibuya already expose every multi-event boundary as a Streamly `Stream`, so any keiro abstraction that consumes those boundaries — hydration, projections, process managers, the outbox relay, snapshot-accelerated replay — must be expressed in the same `Stream` and `Fold` primitives rather than a parallel streaming abstraction. EP-2 (pure codecs) and EP-5 (workflow roadmap) were not touched because they sit above the streaming substrate.

- 2026-05-05: Added `hindsight` (`/Users/shinzui/Keikaku/hub/haskell/hindsight`) as required prior-art reading for EP-2. Updated the "Codec typeclass / interface for events" entry in Integration Points to point at the relevant hindsight modules (`Hindsight.Events`, `Hindsight.Events.Internal.Versioning`, `Test.Hindsight.Generate`) and added a Decision Log entry mandating that EP-2 record an explicit verdict — adopt, selectively borrow, or reject — in `docs/research/07-codec-strategy.md`. Cascaded to EP-2 only (a new M0 prior-art milestone, an extended design-doc outline, and a Revisions note). EP-1, EP-3, EP-4, EP-5, and EP-6 untouched: the codec interface they consume is owned by EP-2, so any verdict change propagates through EP-2's published signature rather than per-plan rework. Reason: user flagged hindsight as potentially useful but uncertain ("MIGHT have something useful but i am not sure"); converting that to an explicit research checkpoint prevents the question from quietly disappearing.
