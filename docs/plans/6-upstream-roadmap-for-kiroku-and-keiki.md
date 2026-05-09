---
id: 6
slug: upstream-roadmap-for-kiroku-and-keiki
title: "Upstream Roadmap for Kiroku and Keiki"
kind: exec-plan
created_at: 2026-05-04T20:12:12Z
intention: "intention_01kqt8d9t8ehb84kgs19qa1rs9"
master_plan: "docs/masterplans/1-keiro-research-foundation.md"
---

# Upstream Roadmap for Kiroku and Keiki

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The user explicitly stated that "Both kiroku and keiki still need more features to support keiro, we'll develop them in parallel." This plan is the synthesis step that consolidates every upstream feature gap identified by the previous five plans into a single prioritized list, ready to feed an *implementation* MasterPlan in each upstream project.

After this plan is complete, anyone with the keiro source tree can read `docs/research/11-upstream-roadmap.md` and answer:

- What new features must kiroku add for keiro v1 to work? With what priority? Which are blocking, which are nice-to-haves?
- What new features must keiki add for keiro v1 to work? Same priority breakdown.
- What is the recommended sequencing? Which features can land in parallel? Which serialize?
- What design constraints do the upstream changes carry over from keiro's design (e.g., "kiroku's new `runInTransaction` must accept arbitrary `Hasql.Session`s")?

This plan is *design-only*: no spike. The substance is consolidation across earlier plans. It cannot start before EP-1 through EP-5 have produced their design documents (hard deps).

The user-visible behaviour the eventual library will deliver: when keiro v1 is being implemented in a future MasterPlan, the upstream maintainers (kiroku and keiki) will already have a clear, prioritized backlog with rationale, ready to schedule.


## Progress

- [x] M1.1 — Read EP-1's `docs/research/06-command-cycle-design.md`; extracted gaps. Completed 2026-05-06.
- [x] M1.2 — Read EP-2's `docs/research/07-codec-strategy.md`; extracted gaps. Completed 2026-05-06.
- [x] M1.3 — Read EP-3's `docs/research/08-subscription-and-process-manager-design.md`; extracted gaps. Completed 2026-05-06.
- [x] M1.4 — Read EP-4's `docs/research/09-snapshot-strategy.md`; extracted gaps. Completed 2026-05-06.
- [x] M1.5 — Read EP-5's `docs/research/10-workflow-roadmap.md`; extracted gaps. Completed 2026-05-06.
- [x] M1.6 — Cross-checked against gap lists in `docs/research/01-kiroku-read-side.md` and `docs/research/02-keiki-decide-loop.md`. Completed 2026-05-06.
- [x] M1.7 — Grouped, deduplicated, and prioritised gaps into Blocking / Wanted / Optional buckets across kiroku-store, shibuya-kiroku-adapter, shibuya-core, and keiki. Completed 2026-05-06.
- [x] M1.8 — Spot-checked three load-bearing citations against the live upstream sources (`kiroku-store/src/Kiroku/Store/Effect.hs:160,190` for the `TxSessions.transaction` boundary; `kiroku-store/sql/schema.sql:2,25,74-78` for the Postgres-18/`uuidv7()` requirement and the subscriptions table; `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs:42-47` for the "checkpoint managed internally" comment). All three matched. Completed 2026-05-06.
- [x] M2.1 — Wrote `docs/research/11-upstream-roadmap.md`: 13 sections, 17 prioritised entries plus 3 cross-cutting items plus 6 explicitly-not-gaps, four-block sequencing recommendation, three open questions forwarded to upstream maintainers, citation snapshot for forward-compatibility. Completed 2026-05-06.
- [x] M2.2 — Updated `docs/research/00-overview.md` to add the `11-upstream-roadmap.md` entry after the `10-workflow-roadmap.md` entry. Completed 2026-05-06.


## Surprises & Discoveries

- 2026-05-06: The four-block sequencing collapses cleanly to a single Block-1 item: kiroku-store's single-stream `runInTransaction` combinator (§4.1 of `docs/research/11-upstream-roadmap.md`). Every other gap is either Wanted or Optional; the implementation MasterPlan's gating reduces to "wait for one combinator." The pre-synthesis expectation (informed by the EP-1 anticipated-gaps list) was that two or three Blocking items would emerge; in practice, EP-3's at-least-once async-projection design and EP-4's snapshot-as-advisory design absorbed the would-be-Blocking items into Wanted. **Cascade**: the implementation MasterPlan can begin work as soon as kiroku-store ships §4.1; everything else parallelises. Recorded in `docs/research/11-upstream-roadmap.md` §3 Block 1.

- 2026-05-06: Three keiki-side requests collapse onto a single keiki PR: §7.1 (register-file `<-> Aeson.Value` helper), §7.2 (register-file shape hash), and the §7.3 structured-error-model on `step`/`omega`. The first two share a compile-time slot-list walk and a shared customer set (EP-1, EP-2, EP-4 for the helper; EP-4 alone for the hash); the third is a separate pure-keiki signature change. Landing all three together is the natural keiki-side scoping. **Cascade**: EP-6's recommendation to keiki is "one PR" rather than "three small PRs"; the keiki maintainer can decide. Recorded in `docs/research/11-upstream-roadmap.md` §7.

- 2026-05-06: The shibuya-kiroku-adapter `HandlerInTransaction` shape (§5.1) is a kiroku-store change as well as a shibuya-kiroku-adapter change — the runner needs to call kiroku's checkpoint-advance SQL inside the user's `Hasql.Transaction.Transaction`, which means the SQL must be exposed through the kiroku-store boundary. Co-scheduling §4.1 and §5.1 in one upstream coordination window (likely a single shared release of kiroku-store + shibuya-kiroku-adapter) is the recommended shape. The §5.1 entry's *Suggested sequencing* paragraph records this. **Cascade**: the implementation MasterPlan can use this co-scheduling as a marker — when both items land, the at-least-once → exactly-once async projection migration is unblocked.

- 2026-05-06: §9 ("Explicitly NOT gaps") records six items that earlier drafts (or a maintainer reading only the surveys) might have logged as gaps. Three were absorbed by deliberate design choices in the parent MasterPlan or the child plans (Strategy E supersedes HWM; `SymTransducer` already is the right process-manager primitive; `Codec e` and `StateCodec` asymmetry is intentional, not an inconsistency); two by the existing Streamly substrate; one by the prior-art-survey rejection of server-side scripted projections. The "explicitly NOT" framing prevents the next reader from re-litigating decisions that have already cost discussion time. **Cascade**: future EP-6-readers can stop a "wait, shouldn't we …?" thread by pointing at §9.

- 2026-05-06: The MasterPlan's anticipated mention of `hs-opentelemetry` version skew between shibuya-core and pgmq-hs (recorded in the MasterPlan's Surprises & Discoveries entry of 2026-05-05, EP-3) was not captured by any single child plan's gap list — it surfaces only when both libraries land in the same workspace. EP-6 picked it up at synthesis time and added §8.3 as a cross-cutting "Wanted" item to be coordinated by shibuya/pgmq-hs at the build-environment level. **Cascade**: the implementation MasterPlan's first build pass should treat this as a known-coordination point rather than a surprise.


## Decision Log

- Decision: Consolidate the gap list into a single document rather than splitting it into "kiroku-roadmap" and "keiki-roadmap".
  Rationale: The cross-cutting features (typed `StreamId`, codec interop, transactional step) involve both libraries and need to be discussed together. The single document has clearly separated sections per upstream project.
  Date: 2026-05-04.

- Decision: Prioritize each gap as **Blocking**, **Wanted**, or **Optional** for keiro v1.
  Rationale: A flat list invites scope creep. Three labels with explicit semantics let the upstream maintainers schedule.
  Date: 2026-05-04.

- Decision: Record the *rationale and provenance* for each gap (which child plan identified it).
  Rationale: When the upstream maintainer asks "why do you need this?" the answer must be one click away.
  Date: 2026-05-04.

- Decision: Do not attempt to design the upstream features in this plan; only enumerate them with constraints.
  Rationale: Designing kiroku/keiki changes is the upstream's responsibility. This plan provides the requirements; each upstream MasterPlan will design and implement.
  Date: 2026-05-04.

- Decision: Reclassify the `shibuya-kiroku-adapter` `HandlerInTransaction` shape from Blocking to Wanted (Blocking-for-exactly-once). Recorded in `docs/research/11-upstream-roadmap.md` §5.1.
  Rationale: EP-3's published design (`docs/research/08-subscription-and-process-manager-design.md` §3) explicitly accepts at-least-once async projections as the v1 default with user-side idempotency; v1 keiro can ship without the shape. The "Blocking-for-exactly-once" qualifier preserves the urgency for the implementation MasterPlan's v1.x window without overstating the v1 gating.
  Date: 2026-05-06.

- Decision: Group the kiroku-store roadmap by upstream package, not by priority. Each subsection (`§4`, `§5`, `§6`, `§7`) is one upstream package; within each, entries are ordered Blocking → Wanted → Optional.
  Rationale: An upstream maintainer reading the document is interested in their own package, not in cross-package priority. The four-block sequencing recommendation (`§3`) provides the cross-package view for the implementation MasterPlan; the per-package sections serve the upstream maintainers.
  Date: 2026-05-06.

- Decision: Add an "Explicitly NOT a gap" section (§9) recording six items that might be mistaken for gaps with the rationale for each rejection.
  Rationale: Earlier drafts of this plan logged some of these (HWM, parallel `Process` primitive in keiki). Recording the rejections inline prevents the next reader from re-litigating settled decisions and gives EP-6 a place to point future readers at when they re-raise the question.
  Date: 2026-05-06.

- Decision: Add a "Citation snapshot" section (§11) listing every cited file:line.
  Rationale: Citations rot. A future reader checking against then-current upstream needs a single index of "what we cited and where" to quickly identify which gaps have been closed by upstream changes since synthesis. The §12 "How to verify" point #6 makes this index a load-bearing artifact, not a courtesy.
  Date: 2026-05-06.

- Decision: Forward three open questions to upstream maintainers (§10) — codec ownership to keiki, compensate direction to keiki, supervisor generalisation to shibuya — without prejudging the answer.
  Rationale: Each question is one the upstream maintainer is better positioned to answer than EP-6 (it depends on roadmap items keiro has no visibility into). EP-6's job is to identify and forward, not to decide unilaterally.
  Date: 2026-05-06.


## Outcomes & Retrospective

EP-6 closed on 2026-05-06 with `docs/research/11-upstream-roadmap.md` published. The synthesis identified one Blocking item (kiroku-store's single-stream `runInTransaction` combinator), six Wanted items in Block 2, six Wanted items in Block 3, and eight Optional items in Block 4, plus three cross-cutting items, plus six explicitly-not-gaps. The pre-synthesis expectation (recorded in this plan's anticipated-gaps section, written 2026-05-04) was that two-to-three Blocking items would emerge; in practice, EP-3's at-least-once async-projection design and EP-4's snapshot-as-advisory design absorbed the would-be-Blocking items into Wanted, leaving exactly one true gate.

Compared to the original vision: the plan delivered exactly what was asked — a single, prioritised, rationale-bearing backlog that an upstream maintainer can schedule against without further keiro-side conversation. The §12 verification questions are answerable from the document alone; the §11 citation snapshot makes future drift detectable without re-running the whole synthesis. Three open questions (§10) are forwarded to the relevant upstream maintainers — none of these questions could be answered unilaterally by EP-6.

What remains: nothing in this plan. EP-6 is a terminal plan in the research-foundation MasterPlan; the implementation MasterPlan that follows will consume `docs/research/11-upstream-roadmap.md` as its upstream-gating artefact.

Lessons for future synthesis plans:

- *Spot-checking citations before drafting saves rework.* Three citations were spot-checked against the live upstream (recorded in M1.8); all three matched. If any had drifted, the synthesis would have surfaced wrong file:line numbers and a future reader could not have validated the gap. The cost of the spot-check was ~5 minutes; the value is permanent (the §11 snapshot records the verified citations).
- *"Explicitly NOT a gap" entries earn their keep.* Three of the §9 entries (HWM, `Process` primitive, codec layer changes) were items that earlier draft thinking logged as gaps and that later design work absorbed. Recording the rejection with rationale prevents the next reader from re-litigating; without it, the conversation would re-occur in every implementation MasterPlan that touches the relevant surface.
- *Upstream PRs cluster by maintainer's mental model, not by keiro-customer priority.* §7.1 + §7.2 (and possibly §7.3) all touch keiki's pure core; landing them in one keiki PR is the natural shape for the keiki maintainer even though they are scattered across keiro plans. EP-6's per-package grouping (Decision Log entry of 2026-05-06) reflects this.


## Context and Orientation

Repository layout. Working tree at `/Users/shinzui/Keikaku/bokuno/keiro`. The five surveys at `docs/research/01-...md` through `docs/research/05-...md` already enumerate gaps from the surveys' perspective; this plan consolidates them with the gaps identified by the design plans EP-1 through EP-5 to form a single, complete list.

Sister projects under their respective `mori` registry entries:

- `shinzui/kiroku` — `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. Subprojects: `kiroku-store` (the event store), `shibuya-kiroku-adapter` (subscription bridge to shibuya).
- `shinzui/keiki` — `/Users/shinzui/Keikaku/bokuno/keiki`. Single library; pure decider/evolve core.

Term definitions:

- *Blocking* — a gap that prevents keiro v1 from working at all. Examples: a primitive that does not exist and cannot be reasonably worked around.
- *Wanted* — a gap that is not blocking but materially improves correctness, ergonomics, or performance. keiro can ship v1 without it; we want it within the v1.x window.
- *Optional* — a gap that is small, isolated, or whose absence is easily worked around at the keiro layer. Schedule when convenient.

What does **not** exist as input to this plan today:

- The five `docs/research/06-...md` through `10-...md` design documents. They are produced by EP-1 through EP-5 and must be in place before this plan can run.

What *does* exist:

- The five surveys (`01-...` through `05-...`) and the consolidated overview (`00-overview.md`).
- The current state of kiroku and keiki on disk; this plan can `mori registry show shinzui/kiroku --full` and read sources directly to verify each gap.

Anticipated gaps (preliminary; the final list lives in `docs/research/11-upstream-roadmap.md` when M2 is complete). These come from the existing surveys and pre-empt what EP-1 through EP-5 will record:

### Kiroku-side anticipated gaps

- **Blocking**: A `runInTransaction :: Hasql.Session a -> Eff es (Either StoreError a)` primitive that lets keiro append events plus run user-supplied SQL (projection updates, outbox inserts, snapshot writes) inside one Postgres transaction. Today only `appendMultiStream` opens a Haskell-layer transaction. EP-1 design and EP-3's inline-projection design depend on this. (Source: `docs/research/04-kiroku-keiki-integration.md` "Transaction Model".)
- **Wanted**: A `keiro_snapshots`-friendly migration story (kiroku's schema initialization is currently a single embedded `schema.sql`; a real migration tool — codd or hasql-migration — is wanted for evolutionary changes). (Source: `docs/research/01-kiroku-read-side.md` "Storage & Migrations".)
- **Wanted**: A `readStreamUntil` API for point-in-time replay (read events up to a `GlobalPosition` or timestamp). Useful for debugging and time-travel queries; not required for v1 cycle. (Source: `docs/research/01-kiroku-read-side.md` Gap #10.)
- **Optional**: A first-class `enrichEvent` / encoder hook in the interpreter so cross-cutting concerns (encryption, compression) need not be reimplemented per call site. (Source: `docs/research/01-kiroku-read-side.md` Gap #8.)
- **Optional**: Helpers around `correlation_id` / `causation_id` (chain walking, OpenTelemetry context injection). (Source: `docs/research/01-kiroku-read-side.md` Gap #9.)
- **Optional**: A combined "snapshot + tail-events" read query (`LEFT JOIN keiro_snapshots ON streams.stream_id = ...` returning the latest snapshot row plus the events newer than it in one round-trip). EP-4 design mentions this as a v2 optimization. (Source: EP-4.)
- **Wanted**: A Streamly-native single-stream forward read — i.e., `readStreamForward sn fromVersion :: Stream (Eff es) RecordedEvent` (analogous to the existing `Kiroku.Store.Subscription.Stream` returning a `Stream IO RecordedEvent`, but for non-subscription single-stream reads). EP-1's hydration pipeline is expressed as a Streamly `Stream → Fold` (`docs/plans/1-command-cycle-design-and-spike.md`'s Streamly decision); without this primitive keiro must wrap the existing `Vector`-returning `readStreamForward` in `Stream.unfoldrM` and paginate manually. The wrapper is a few dozen lines and acceptable for v1, hence Wanted rather than Blocking. The kiroku-side change is mechanical: lift the existing batched-read loop to return a `Stream` instead of a `Vector`. Sequencing: independent of every Blocking item; can land in any v1.x release. (Source: EP-1.)

**Explicitly NOT a gap**: a `highWaterMark` query for async-subscriber gap detection. Kiroku's Strategy E (atomic counter on the `$all` row, `stream_id = 0`, claimed inside the same transaction that inserts events) produces *gap-free* contiguous `globalPosition`s with immediate read-your-own-writes. Documented in `kiroku/docs/DESIGN.md`. The bigserial-gap problem famously addressed by Marten's HWM does not exist here. EP-3 was revised to remove the HWM design after this distinction was confirmed.

**Explicitly NOT a gap**: a Streamly dependency or any Streamly-shaped `Stream`/`Fold` adapter at the kiroku-store layer beyond what already exists. Kiroku-store already exposes `Kiroku.Store.Subscription.Stream` (returns a `Streamly.Data.Stream.Stream IO RecordedEvent`); `shibuya-kiroku-adapter` already lifts that into a shibuya `Stream (Eff es) (Ingested es RecordedEvent)`; shibuya's runners (`Shibuya/Runner/{Serial,Ingester,Supervised}.hs`) consume those streams via `Stream.fold Fold.drain`. Streamly is therefore already a transitive dependency on every keiro user's path. The MasterPlan's "Streamly substrate" Integration Point makes this canonical. The single Streamly-related kiroku item that *is* a gap — a `Stream`-returning single-stream forward read — is captured in the Wanted list above; it is an *additive* API on the existing read path, not a substrate change.

### Keiki-side anticipated gaps

The proper contract between keiro and keiki is the native `SymTransducer phi rs s ci co` (and operations `step`, `delta`, `omega`, `applyEvent`, `applyEvents`, `reconstitute`), not the `Keiki.Decider` legacy facade. The gaps below are framed against that contract.

- **Blocking**: A structured error model for `step`/`omega`. Today these return `Maybe (s, RegFile rs, Maybe co)` / `Maybe co`; `Nothing` conflates "no edge fires" (legitimate model rejection) with "guard failed unexpectedly" (likely a model bug). Keiro needs to distinguish them. Likely shape: a richer return like `data StepResult s rs co = Fired (s, RegFile rs) (Maybe co) | NoEdge | GuardFailed Reason`. (Source: `docs/research/02-keiki-decide-loop.md` Gap #3, reinterpreted.)
- **Wanted (Blocking for EP-4)**: A register-file serialization helper. The joint state keiro must persist for snapshots is `(s, RegFile rs)`; `s` is a user-defined sum and serializes trivially, but `RegFile rs` is keiki's typed heterogeneous tuple of `(Symbol, Type)` slots and cannot be serialized without keiki-side machinery. The cleanest interface is `regFileToJSON :: RegFile rs -> Aeson.Value` and `regFileFromJSON :: Aeson.Value -> Either String (RegFile rs)` constrained appropriately (likely an extension of `Keiki.Generics`'s `mkInCtor` style). (Source: EP-4.)
- **Wanted**: A way to permit *effectful read* in the decide phase under explicit constraints (read-only, deterministic, memoizable). Today keiki forbids it entirely; the runtime adapter must pre-fetch and embed reads in the command payload. For workflows that lookup external state on every step, the pre-fetch dance is awkward. (Source: `docs/research/02-keiki-decide-loop.md` Gap #4.)
- **Wanted**: A `Saga`/`compensate` direction on edges, or a clear documented pattern for composing forward + compensating transducers. EP-5's open questions reference this; without it, sagas are an application-level convention rather than a typed primitive. (Source: EP-5.)
- **Optional**: Property-test helpers (Given/When/Then over `step`/`reconstitute`). v1 of keiro does not need them; aggregate authors do. (Source: `docs/research/02-keiki-decide-loop.md` Testing section.)
- **Optional**: A schema-evolution / upcaster framework in keiki (today, codecs and upcasters are entirely keiro's responsibility per EP-2's design). (Source: keiki's `docs/research/schema-evolution.md`.)

**Explicitly NOT a gap**: a `Process` or `ProcessManager` primitive in keiki distinct from `SymTransducer`. The previous draft of this list called for one; that was a mistake. `SymTransducer phi rs s ci co` already *is* the right primitive — its register file carries process-manager state, ε-edges express silent transitions, and `Keiki.Composition`'s `compose`/`alternative`/`feedback1` express coordination. Process managers are a *use* of `SymTransducer`, not a separate type to add to keiki.


## Plan of Work

One milestone, design-only.

### Milestone 1 — Synthesis document

Write `docs/research/11-upstream-roadmap.md`. Self-contained. Structure:

- *Problem statement* — keiro v1 cannot ship without specific upstream features; this document is the prioritized, rationale-bearing backlog the upstream maintainers can schedule.
- *How to read this document* — definitions of Blocking / Wanted / Optional; meaning of "provenance" lines.
- *Kiroku roadmap*:
  - **Blocking** (each item: short title, signature sketch, rationale paragraph, provenance — which child plan and section, design constraints, suggested sequencing).
  - **Wanted** (same shape).
  - **Optional** (same shape).
- *Keiki roadmap* (same three priority sections).
- *Cross-cutting items* — features that span both libraries (e.g., a typed `StreamId` per aggregate: keiro defines the wrapper, kiroku may eventually adopt it). For each, identify which side owns the change.
- *Sequencing recommendation* — a small DAG showing which upstream items can be developed in parallel and which serialize. Specifically, separate the items that block keiro v1 from those that do not.
- *Open questions* — items where the upstream maintainer's input is needed before scheduling (e.g., "should keiki's `SymTransducer.step` gain a `compensate` direction, or is compensation an application-level event?" from EP-5; the question is framed against the native `SymTransducer` contract, not the legacy `Keiki.Decider` facade keiro does not use).
- *Snapshot of the kiroku/keiki source as of this writing* — reference the exact file paths and line numbers cited in the surveys, so a future reader can compare against current state and identify which gaps have been closed.

For every gap, the document must answer:

1. What is missing today? (One sentence; cite file:line where applicable.)
2. What does keiro need? (One sentence with a sketch type signature.)
3. Why? (One paragraph linking back to the child plan that depends on it.)
4. Priority?
5. What design constraint does keiro impose on the upstream change?

Acceptance: doc exists, lists every gap from EP-1 through EP-5 (verified by re-reading those plans' "Open questions / upstream gaps" sections), groups them, prioritizes them, and produces a sequencing recommendation a kiroku or keiki maintainer could schedule against.


## Concrete Steps

Working directory `/Users/shinzui/Keikaku/bokuno/keiro` unless noted.

Pre-flight check that hard dependencies are met:

    test -f docs/research/06-command-cycle-design.md
    test -f docs/research/07-codec-strategy.md
    test -f docs/research/08-subscription-and-process-manager-design.md
    test -f docs/research/09-snapshot-strategy.md
    test -f docs/research/10-workflow-roadmap.md

If any check fails, the corresponding child plan has not produced its document. This plan must wait.

Synthesize:

    # read each docs/research/06-...md through 10-...md "Open questions / upstream gaps" section
    # author docs/research/11-upstream-roadmap.md per Plan of Work milestone 1
    # update docs/research/00-overview.md to add the new entry

Sanity-check by spot-reading the upstream sources:

    # confirm each cited file:line still matches the current source in
    # /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku and
    # /Users/shinzui/Keikaku/bokuno/keiki


## Validation and Acceptance

All must hold:

1. `docs/research/11-upstream-roadmap.md` exists and is referenced from `docs/research/00-overview.md`.
2. Every "Open questions / upstream gaps" item in EP-1 through EP-5's design documents appears in this roadmap, classified into one of the three priorities.
3. Every Blocking item has at least: a signature sketch, a rationale paragraph, a provenance line, and a design constraint.
4. The sequencing section identifies which Blocking items must land before keiro v1 implementation can begin and which can land later.
5. A spot-check on three randomly picked file:line citations against the current kiroku/keiki source shows the citation is still valid (or the divergence is recorded in Surprises & Discoveries).

Phrased as observable behaviour: a kiroku or keiki maintainer can read this document and schedule each item into a sprint without any further keiro-side conversation.


## Idempotence and Recovery

The document is plain Markdown. If a child plan's design changes after this synthesis is written, update this plan's content accordingly and append a revision note. Maintaining accuracy is the cost of the synthesis being load-bearing for the upstream maintainers.

If a citation drifts (kiroku or keiki changes a line number under us), note the drift, update the citation, and commit. Do not let the document silently rot.


## Interfaces and Dependencies

This plan does not introduce code. It depends on:

- `docs/research/06-command-cycle-design.md` (EP-1).
- `docs/research/07-codec-strategy.md` (EP-2).
- `docs/research/08-subscription-and-process-manager-design.md` (EP-3).
- `docs/research/09-snapshot-strategy.md` (EP-4).
- `docs/research/10-workflow-roadmap.md` (EP-5).
- `docs/research/01-kiroku-read-side.md` and `docs/research/02-keiki-decide-loop.md` (the original surveys, used for cross-checking).
- The current state of `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` and `/Users/shinzui/Keikaku/bokuno/keiki` for spot-checking citations.

Downstream consumers:

- A future implementation MasterPlan for keiro v1 — schedules its work *around* the upstream items, treating Blocking items as gates.
- A future implementation MasterPlan for kiroku — schedules its kiroku-side items per priority.
- A future implementation MasterPlan for keiki — schedules its keiki-side items per priority.

This is the terminal plan in this MasterPlan. Once it is complete, the keiro research foundation phase is over and the implementation phase can begin.


## Revisions

- 2026-05-06: Closed EP-6. `docs/research/11-upstream-roadmap.md` published (13 sections); `docs/research/00-overview.md` updated; M1.1–M1.8 and M2.1–M2.2 ticked off in Progress; five new entries appended to Surprises & Discoveries (the single-Blocking-item collapse, the keiki one-PR grouping, the §4.1+§5.1 co-scheduling marker, the §9 "explicitly NOT" framing as a regret-prevention device, and the `hs-opentelemetry` skew lift); five new Decision-Log entries (the `HandlerInTransaction` reclassification, the per-package grouping, the §9 addition, the §11 citation snapshot, the §10 forwarded questions); Outcomes & Retrospective filled in. EP-6 is the terminal plan; the research-foundation MasterPlan's implementation phase can begin once kiroku-store ships §4.1.

- 2026-05-04: Removed `highWaterMark` from kiroku-side anticipated gaps; added an "Explicitly NOT a gap" subsection citing kiroku's Strategy E (`kiroku/docs/DESIGN.md`). Reframed keiki-side gaps around the native `SymTransducer` contract: structured error model targets `step`/`omega` instead of the legacy `Decider.decide`; the register-file serialization helper is added as a Wanted (Blocking for EP-4); a saga/compensate-direction question is added; and the previous "Process or ProcessManager primitive" gap is moved to "Explicitly NOT a gap" because `SymTransducer` already is that primitive. Added an EP-4-derived optional kiroku gap (combined snapshot + tail-events query). Reason: aligning EP-6 with the keiki-team's clarification that `Decider` is a legacy compat facade and with kiroku's deliberate Strategy-E choice.

- 2026-05-04: Added a Wanted kiroku-side gap for a Streamly-native single-stream forward read (`readStreamForward sn fromVersion :: Stream (Eff es) RecordedEvent`), sourced from EP-1's hydration-pipeline Streamly decision. Added a corresponding "Explicitly NOT a gap" entry stating that Streamly itself, the existing `Kiroku.Store.Subscription.Stream`, and shibuya's `Stream`-shaped adapters require *no* upstream work — Streamly is already a transitive dependency on every keiro user's path, and the MasterPlan's new "Streamly substrate" Integration Point makes that canonical. Reason: capturing the single concrete kiroku request the new Streamly substrate produces, while pre-empting any "should kiroku adopt Streamly?" debate (it already has, where it matters).
