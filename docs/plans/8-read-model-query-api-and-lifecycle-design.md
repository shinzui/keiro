---
id: 8
slug: read-model-query-api-and-lifecycle-design
title: "Read Model Query API and Lifecycle Design"
kind: exec-plan
created_at: 2026-05-10T13:47:53Z
intention: "intention_01kqt8d9t8ehb84kgs19qa1rs9"
master_plan: "docs/masterplans/1-keiro-research-foundation.md"
---

# Read Model Query API and Lifecycle Design

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this plan, the keiro research foundation has a complete answer to the question "how do applications *read* state derived from events?" Today, EP-3 (`docs/plans/3-subscriptions-projections-and-process-managers.md`) and `docs/research/08-subscription-and-process-manager-design.md` describe the *write side* of read models — how a projection worker maintains denormalized rows in Postgres. Neither plan describes the *read side*: how an application's query code accesses those rows, what consistency it can rely on after a command appends events, how a read-model schema is evolved or rebuilt without losing data, or what relationship a "read model" has to a "snapshot" (EP-4) or a "projection" (EP-3). This is the gap this plan closes.

The user-visible behavior at the end is two artefacts. (1) A research design document at `docs/research/12-read-model-query-api-and-lifecycle.md` that fixes (a) the typed `ReadModel q r` query API exposed by keiro to applications, (b) the read-after-write consistency-mode taxonomy (strong / eventual / position-wait) and the API surface for selecting between them, (c) the read-model schema-evolution and rebuild-from-zero protocol, (d) the multi-stream read-model story, (e) the relationship between read models, snapshots, and projections, and (f) any new upstream gaps to feed into EP-6's roadmap. (2) A small Haskell spike under `spikes/read-model/` whose `cabal run read-model-spike` ends with `[read-model-spike] OK`, demonstrating end-to-end: an inline projection writing a read-model row, an async projection populating a different table, the position-wait helper successfully blocking until the async projection's checkpoint advances past a freshly-appended event's `globalPosition`, and a typed `runQuery` returning the expected denormalized record. The implementation MasterPlan that follows the research foundation will pick up both artefacts and turn them into production keiro code.

This plan does *not* implement production keiro code. Like EP-1 through EP-6, it produces a design document and a small validation spike — nothing more.


## Progress

- [x] M1: Prior-art survey and consistency-mode taxonomy. Completed 2026-05-10. Output: `spikes/read-model/notes/prior-art.md` (Marten/Eventide/Axon/EventStoreDB/Restate read-side lens; eight synthesis recommendations); draft §1–§4 of `docs/research/12-read-model-query-api-and-lifecycle.md` (purpose, definitions, three-mode taxonomy with mode-selection decision tree and comparison table, substrate facts inherited from kiroku Strategy E + `subscriptions(subscription_name, last_seen)` + `shibuya-kiroku-adapter`'s separate-connection checkpoint advance + EP-1's transactional-step combinator + Streamly).
- [x] M2: Design the typed `ReadModel q r` API and schema-evolution/rebuild story. Completed 2026-05-10. Output: §5–§10 of `docs/research/12-read-model-query-api-and-lifecycle.md` — §5 typed wrapper (record fields, `ConsistencyMode` constructors, `runQuery`/`runQueryWith`/`waitFor` signatures, `WaitTimeout`/`ReadModelStaleSchema` errors, worked example); §6 rebuild protocol (eight-step shadow-table swap with `keiro_read_models` metadata table, failure recovery, inline-projection variant, non-pause variant); §7 multi-stream read models with the upstream gap cascaded; §8 idempotency-token propagation via `source_event_id UUID UNIQUE`; §9 read-model-vs-snapshot-vs-projection three-way distinction with the rejected consolidations spelled out; §10 polling-loop position-wait implementation with LISTEN/NOTIFY deferred to v2.
- [x] M3: Build the validation spike under `spikes/read-model/`. Completed 2026-05-10. Output: `cabal run read-model-spike` ends with `[read-model-spike] OK`; transcript captured in `spikes/read-model/transcript.txt`. All three scenarios pass — inline (Strong), async + position-wait (Eventual / PositionWait), position-wait timeout (the failure mode). Notable M3 finding: kiroku-store has shipped `runTransactionAppending`, closing EP-6 §4.1's Blocking item; recorded in the MasterPlan's Surprises & Discoveries 2026-05-10. PG 18 is required for `uuidv7()`; the spike runs against a `PATH=` override pointing at a nix-store PG 18 (the system's PG is 17.9).
- [x] M4: Published `docs/research/12-read-model-query-api-and-lifecycle.md` (drafted in M1+M2 at its final path; M4 was the formal publication pass). `docs/research/00-overview.md` updated with the §12 entry plus a note recording that EP-6 §4.1's Blocking item shipped (kiroku-store `runTransactionAppending`). Three Surprises & Discoveries entries added to the MasterPlan: the `runTransactionAppending` discovery, the multi-stream / category-subscription gap widening, and the EP-8 closure summary. EP-8 marked Complete in the MasterPlan registry; the MasterPlan's Outcomes & Retrospective gains a 2026-05-10 supersession close-out. Completed 2026-05-10.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: This plan ships both a design document and a validation spike (not design-only).
  Rationale: The user explicitly chose "Design + small spike" when scoping this plan in the MasterPlan's update of 2026-05-10. The ergonomic risk in the typed `ReadModel q r` shape and the position-wait helper is real enough that prose-only validation would leave the implementation MasterPlan inheriting unverified design choices. EP-1, EP-2 shipped spikes for the same reason; EP-3 deferred its spike only because of an upstream blocker. Read-model design has no such blocker — kiroku already exposes `globalPosition`, and shibuya-kiroku-adapter already advances `subscriptions.last_seen`, which together suffice to validate the position-wait helper.
  Date: 2026-05-10.

- Decision: Design document numbered `docs/research/12-read-model-query-api-and-lifecycle.md`, continuing from EP-6's `11-upstream-roadmap.md`.
  Rationale: Preserves the linear `docs/research/` index. The MasterPlan's Integration Points section already enumerates the `06-` through `11-` numbering; `12-` is the natural next slot. `00-overview.md` will be updated in M4 to include the new entry.
  Date: 2026-05-10.

- Decision: Treat read models, snapshots, and projections as three distinct primitives with overlapping mechanisms but distinct purposes. Read models are externally queryable and lifecycle-managed; snapshots are *advisory* and internal to `runCommand`'s hydration phase; projections are the *workers* that maintain read-model rows.
  Rationale: EP-4's snapshot design (`docs/research/09-snapshot-strategy.md`) deliberately makes snapshots fall-through-on-failure; making them externally queryable would couple `runCommand` correctness to read-model consistency. Conversely, read models must survive arbitrary schema evolution and explicit rebuilds — semantics snapshots intentionally lack. Conflating the three would either make snapshots load-bearing (rejected by EP-4) or strip read models of features applications need.
  Date: 2026-05-10.


## Outcomes & Retrospective

EP-8 closed on 2026-05-10. The Purpose section's two artefact promises are met:

1. **Design document** at `docs/research/12-read-model-query-api-and-lifecycle.md` (ten sections, ~700 lines) covering: §1 purpose, §2 definitions, §3 the consistency-mode taxonomy with mode-selection decision tree and comparison table, §4 substrate facts inherited from kiroku/shibuya, §5 the typed `ReadModel q r` wrapper with full record fields and `Keiro.ReadModel` module surface, §6 schema-evolution and rebuild protocol with `keiro_read_models` metadata table and eight-step shadow-table swap, §7 multi-stream read models with the upstream gap path, §8 idempotency-token propagation via `source_event_id UUID UNIQUE`, §9 the read-model / snapshot / projection three-way distinction with rejected consolidations spelled out, §10 the polling-based position-wait helper.

2. **Validation spike** at `spikes/read-model/`: `cabal run read-model-spike` exits 0 with `[read-model-spike] OK` (transcript at `spikes/read-model/transcript.txt`). All three scenarios pass — Strong/inline returns the post-write value with no waiting; Eventual+PositionWait blocks until `subscriptions.last_seen` catches the appended position then returns the new audit row; PositionWait timeout returns `WaitTimeout` in `Eff es`'s error channel rather than blocking forever.

What changed during the milestones, vs the original plan:

- *M1 stayed mostly inline with the plan*. The prior-art notes at `spikes/read-model/notes/prior-art.md` produced eight synthesis recommendations that fed §1–§4 of the design doc. The Marten/Eventide/Axon/EventStoreDB/Restate read-side lens converged cleanly on a single typed wrapper with the three-mode taxonomy.
- *M2 added §6's non-pause-variant rebuild as a documented opt-in* once the analysis revealed that some workloads cannot tolerate the brief pause-event-appends window the default protocol uses.
- *M3 surfaced two findings worth recording outside this plan*. First, kiroku-store has shipped `runTransactionAppending` (the EP-6 §4.1 SOLE Blocking item — see MasterPlan Surprises & Discoveries 2026-05-10). The spike's `runCommandInline` consumes this combinator directly. Second, the spike runs against PG 18 via a `PATH=/nix/store/.../postgresql-18.3/bin:$PATH` override because the system PG is 17.9; `transcript.txt` records the exact invocation. Both findings cascade out of this plan's scope into the MasterPlan and the (closed) EP-6 roadmap document is preserved unchanged — the cascades land in the MasterPlan's Surprises & Discoveries section.
- *M4 was a thin publication pass* because M1+M2 wrote the design doc directly at its final path. The M4 work was: update `docs/research/00-overview.md` to include §12 (plus the EP-6 §4.1 closure note), append the three Surprises & Discoveries entries to the MasterPlan, mark EP-8 Complete in the Exec-Plan Registry, write the MasterPlan's 2026-05-10 supersession close-out, and tick milestones across all four progress checklists (this plan, the MasterPlan's progress section).

Lessons for the implementation MasterPlan that follows:

- *The typed `ReadModel q r` wrapper is the right shape*. The spike's three scenarios validate the API ergonomics. Production keiro should ship `Keiro.ReadModel` with the record fields documented in §5, the `ConsistencyMode` taxonomy in §3, and the polling-loop `waitFor` in §10 — verbatim. The two simplifications the spike made (no `keiro_read_models` metadata table; no `rmRowCodec`) are *not* permitted in production: the rebuild protocol depends on both.
- *Inline projections are the killer feature for read-after-write*. Scenario 1 demonstrates that `runCommandInline` plus `runTransactionAppending` gives the application zero-latency read-after-write semantics. The implementation MasterPlan should treat the inline-projection lifecycle as the default for read models that need Strong consistency and the user does not flag the projection as too slow / fallible to put on the write path.
- *Position-wait is the cheap-and-correct middle ground*. Scenario 2 demonstrates that `waitFor` plus an async projection gives read-after-write semantics with zero write-path latency — exactly what most application code wants. Default new read models to `Eventual` and let calls upgrade to `PositionWait` per call site.
- *The PG 18 prerequisite is the only setup friction*. Once PG 18 is on PATH, ephemeral-pg + kiroku-store + the read-model spike Just Work. The implementation MasterPlan can treat PG 18 as a hard prerequisite (already noted by EP-1 §"deployment prerequisites") without re-litigating.

Two things the spike did *not* validate that the implementation MasterPlan should pick up:

- *The `keiro_read_models` metadata table and the rebuild protocol*. §6 of the design doc fixes the protocol; the spike does not exercise it (rebuild is a heavyweight scenario that needs operational tooling). The implementation MasterPlan should ship a unit test that runs through a rebuild end-to-end against an ephemeral PG.
- *The shape-hash mismatch detection*. §5.6's `ReadModelStaleSchema` error is documented but never raised by the spike (no schema change happens during the spike's lifetime). The implementation MasterPlan should ship a test that bumps a `ReadModel`'s `rmShapeHash` and asserts `runQuery` raises `ReadModelStaleSchema`.

The research foundation is now complete (for the second time, this time honestly). Authoring the implementation MasterPlan is the next step; it lives in a separate document.


## Context and Orientation

The reader has only this plan and the current working tree. Everything needed is either embedded here or named by full repository-relative path.

**The repository.** This is the `keiro` repository at `/Users/shinzui/Keikaku/bokuno/keiro/`. It is *design-only* today: there are zero Haskell source files. Output of this plan is a Markdown design document under `docs/research/` and a Haskell spike under `spikes/read-model/`. The MasterPlan that owns this child plan is `docs/masterplans/1-keiro-research-foundation.md`.

**The dependencies.** keiro is a Haskell library that will compose six existing components:

- *kiroku* — Postgres-backed event store. Source: `/Users/shinzui/Keikaku/hub/haskell/kiroku/`. Use `mori registry show kiroku --full` to confirm. Key facts the read-model design uses: (1) every appended event is assigned a contiguous, gap-free `globalPosition :: Int64` by kiroku's "Strategy E" (an atomic `UPDATE … RETURNING` on the row `streams WHERE stream_id = 0` inside the same transaction that inserts events). See `kiroku/docs/DESIGN.md` §"Core Design Choice: Strategy E". (2) Kiroku exposes a `subscriptions(subscription_name, last_seen)` table; the worker (or the adapter) advances `last_seen` after each event is processed. (3) `appendToStream` (single-stream) does *not* open a Haskell-layer transaction; only `appendMultiStream` does. This matters for the position-wait helper if it has to coordinate with a write tx.

- *keiki* — pure decider/evolve core (`SymTransducer phi rs s ci co` is the central type). Source: `/Users/shinzui/Keikaku/hub/haskell/keiki/`. Read models do not consume keiki directly; they consume kiroku events that have already been folded by keiki on the write path.

- *shibuya* — subscription engine. Source: `/Users/shinzui/Keikaku/hub/haskell/shibuya/`. Adapter abstraction: `source :: Stream (Eff es) (Ingested es msg)`. Runner abstraction: `Stream.fold Fold.drain`-shaped pipelines. Async-projection workers run on shibuya runners.

- *shibuya-kiroku-adapter* — Source: `/Users/shinzui/Keikaku/hub/haskell/shibuya-kiroku-adapter/`. Bridges shibuya's `source` to kiroku's subscription stream. Crucially, as of 2026-05-05 the adapter advances kiroku's `subscriptions.last_seen` *internally* in a separate SQL connection from the user's projection write — so async projections are *at-least-once*, and projection functions must be idempotent. EP-6 §5.1 records this as a Wanted-Blocking-for-exactly-once gap. The position-wait helper this plan designs reads `subscriptions.last_seen` directly to determine projection progress.

- *streamly* (composewell) — `Streamly.Data.Stream.Stream` and `Streamly.Data.Fold.Fold` are the canonical in-process streaming substrate, fixed by the MasterPlan's 2026-05-04 streamly-substrate decision. The spike's projection workers use it; the read-model query API may or may not (M2 decides — likely the query API itself is `Eff`-shaped and streamly stays on the projection side).

- *hasql* — the SQL library. Read-model queries and projection writes both go through it.

- *effectful* — the effect system. The read-model query API is `Eff es`-shaped.

**Already-completed research.** Read in this order before starting M1:

1. `docs/research/00-overview.md` — index of the research foundation.
2. `docs/research/01-kiroku-read-side.md` — kiroku's read-side primitives, including `subscriptions(subscription_name, last_seen)` and gap-free `globalPosition`.
3. `docs/research/06-command-cycle-design.md` — EP-1's design. Most importantly §3 (event-stream identity, `EventStream phi rs s ci co`), §4 (transactional-step combinator), §5 (the `solveOutput` constraint affecting event payload shape), §10 (transactional step / `appendMultiStream`-shaped multi-stream commit).
4. `docs/research/07-codec-strategy.md` — EP-2's value-level `Codec e` record. Read models that decode events from `EventData.payload` use this codec.
5. `docs/research/08-subscription-and-process-manager-design.md` — EP-3's design. *This is the closest neighbour to this plan.* §3 covers projection lifecycles (inline / async / live); §4 covers the gap-free-read guarantee; §5 covers the transactional outbox; §6 covers process managers. Read this entire file before drafting M2.
6. `docs/research/09-snapshot-strategy.md` — EP-4's design. The "advisory snapshot" framing (§3, §12) is *the* anchor for the read-model-vs-snapshot distinction this plan must articulate.
7. `docs/research/10-workflow-roadmap.md` — EP-5's roadmap. Skim §3 ("v1 PMs as substrate") and §5 ("v1-to-v2 substrate continuity"). Workflow read models (queries against `wf:<workflow-name>-<workflow-id>` streams) are a v2 concern; this plan should mention but not design them.
8. `docs/research/11-upstream-roadmap.md` — EP-6's synthesis. Section §5.1 (`HandlerInTransaction` shape) and §4.1 (single-stream `runInTransaction`) are the two upstream items most likely to interact with read-model design.

**Key terms used in this plan.** Define each in the design doc as well.

- *Read model.* A denormalized, queryable representation of state derived from one or more event streams. Lives in Postgres tables maintained by a projection worker. Externally queryable by application code via a typed API.
- *Projection (worker).* The process that consumes events and writes/updates read-model rows. EP-3 covers this in detail. Three lifecycles: inline (same tx as the event append), async (separate worker, eventual consistency), live (in-memory, non-persistent — rare).
- *Read-after-write consistency.* The guarantee a caller has when reading a read model immediately after a command. Three modes:
  - *Strong* — inline projection. The read-model row is updated in the same Postgres transaction as the event append. Reads after the write see the new state immediately. Trade-off: a slow projection slows every command on that aggregate; an exception in the projection rolls back the append.
  - *Eventual* — async projection. The read-model row is updated by a worker after the write commits. Reads may briefly see stale state. Trade-off: write-path latency unaffected; the application must tolerate or hide the lag (e.g., via optimistic UI).
  - *Position-wait* — async projection plus a caller-side wait. After the command returns its appended `globalPosition`, the caller invokes `waitFor :: ReadModel q r -> GlobalPosition -> Eff es ()` which blocks until the projection's `subscriptions.last_seen` advances past that position. Reads after `waitFor` returns see the new state. Trade-off: write-path latency unaffected, but the caller pays the projection-lag cost on the read path.
- *Read-model rebuild.* The act of truncating a read-model table and re-running the projection from `globalPosition = 0`. Required when (a) the read-model schema changes incompatibly, (b) the projection logic is fixed, or (c) an operator decides to repair drift. The protocol must allow rebuild to run alongside the live projection without serving stale state during the rebuild window.

**Why this plan exists.** A user observation on 2026-05-10: "we didn't research how we're going to handle read models, which are crucial in event-sourced systems." Recorded in this MasterPlan's Surprises & Discoveries entry of 2026-05-10 and the Revisions entry of the same date. EP-3 covers projections-as-write; EP-4 covers snapshots-as-internal-acceleration. Neither covers read models as a first-class queryable surface — the typed query API, the consistency-mode taxonomy, the schema-evolution/rebuild protocol. This plan closes that gap.


## Plan of Work

Four milestones. M1 and M2 produce design content; M3 validates the API choices with a small Haskell spike; M4 publishes and indexes the design doc and cascades upstream gaps.


### Milestone 1 — Prior-art survey and consistency-mode taxonomy

Read `docs/research/05-workflow-prior-art.md` for the existing five-system survey (Marten, Eventide, Axon, EventStoreDB, Restate). Re-read those references with a *read-side* lens — what query API does each expose; what consistency modes; how do they handle schema evolution; how do they support rebuilds. Specifically:

- *Marten*: `Marten.IDocumentStore.Query<T>()` plus inline-projection support; consistency mode is implicit in the projection's lifecycle. Survey §"Marten" for prior-art notes; cross-reference Marten's docs (`https://martendb.io/`) by name only — do not embed external URLs in the design doc per `agents/skills/exec-plan/PLANS.md`.
- *Eventide*: read models are plain Postgres tables; queries are application code. No typed wrapper. Note this as the "raw access" baseline.
- *Axon*: `QueryGateway` plus `@QueryHandler` annotations. Stronger typing than Eventide; introduces a bus-and-handler pattern that may be heavier than keiro needs.
- *EventStoreDB*: subscriptions feed the application's read-model code; the read store is application-chosen. Note as the "BYO read store" pattern.
- *Restate*: orthogonal — its "queries" are workflow-local reads, not CQRS read models.

Produce the *consistency-mode taxonomy* in §3 of the design doc. The taxonomy must cover the three modes (strong / eventual / position-wait), the trade-offs between them, the API shape for selecting one, and a recommendation per use case (UI showing the just-saved entity, dashboards, reports, search indexes). Cross-reference EP-3 §3 for inline-vs-async lifecycles — this plan extends that with the position-wait variant, which EP-3 does not name.

Acceptance: §1–§4 of the design doc are draft-complete and self-consistent. The taxonomy table (§3) names all three modes, their write/read latency profiles, their failure modes (what happens when the projection crashes, when the read-model schema is mid-rebuild), and the API surface. A reviewer reading only §1–§4 can answer "if my UI must show the just-saved entity, which mode do I pick and what's the API call".


### Milestone 2 — Typed `ReadModel q r` API and schema-evolution/rebuild design

Resolve the four design choices in §5–§10 of the design doc:

- *§5 — The typed `ReadModel q r` wrapper.* Decide between (a) a typed wrapper analogous to `EventStream phi rs s ci co` (a record bundling table name, query function, codec, consistency mode), and (b) raw hasql access against projection tables with no keiro-side typing. Recommendation: (a), to keep the read-model surface symmetrical with the write surface. Justify with the same argument EP-1 used for `EventStream`: typed identity prevents cross-wiring (a query meant for `OrderView` cannot accidentally be run against `InvoiceView`'s table).
- *§6 — Schema evolution and rebuild protocol.* Specify (1) read-model versioning (a `readModelVersion :: Int` carried in the `ReadModel` record, persisted in a `keiro_read_models` metadata table alongside the projection's checkpoint); (2) the rebuild protocol (truncate-and-replay-from-zero with a shadow table; the live projection continues serving the old table until the shadow catches up, at which point the projection is repointed); (3) the schema-change detection (a shape hash similar to EP-4's `regfile_shape_hash`, but over the read-model row schema). Cite EP-4 §3 (advisory failure semantics) and §6 (shape-hash promotion) as analogues; explicitly note that read-model rebuild is *not* fall-through-on-failure — a stale read model must not silently serve old data.
- *§7 — Multi-stream read models.* Specify how a read model derived from events across more than one event-stream type (e.g., `OrderView` aggregating events from `Order` and `Payment` streams) is wired. The projection consumes a kiroku category subscription (per EP-5 §9 — note EP-5 records the prefix-style category subscription as an upstream gap if not already supported). The read-model record references multiple `Codec e` values (one per source event type). Note any new upstream gap surfaced.
- *§8 — Idempotency-token propagation.* If the source command carries an idempotency token (per EP-3's §3 idempotency requirement), the projection should propagate it onto the read-model row so duplicate writes (under the at-least-once async lifecycle) are detectable. Specify the column name (`source_event_id`) and the `INSERT … ON CONFLICT (source_event_id) DO NOTHING` pattern.
- *§9 — Read-model vs snapshot vs projection.* Single section explaining the three primitives:
  - *Snapshot* (EP-4): internal to `runCommand`'s hydration phase; advisory; falls through on failure; never queried by application code; rebuildable but rebuild is opportunistic.
  - *Projection* (EP-3): the *worker*; the verb. Maintains read-model rows. Three lifecycles.
  - *Read model* (this plan): the *queryable artefact*; the noun. Externally queried via the typed API. Lifecycle managed (versioned, rebuildable, shape-hashed).
- *§10 — Position-wait implementation.* Specify the helper `waitFor :: ReadModel q r -> GlobalPosition -> Eff es ()`. It polls `subscriptions.last_seen WHERE subscription_name = <projection-name>` (kiroku's existing subscription table) and returns when the value is ≥ the target `GlobalPosition`. Specify the polling interval default (start at 50 ms exponential to 500 ms cap), the timeout default (5 s, configurable per call), and the failure mode (a `WaitTimeout` error returned in `Eff es`'s error channel). Note the alternative — Postgres LISTEN/NOTIFY — and reject it for v1 per the MasterPlan's general "no LISTEN/NOTIFY" stance (deferred to v2).

Acceptance: §5–§10 of the design doc are draft-complete. The typed `ReadModel q r` record signature is fixed. The rebuild protocol is unambiguous (a reader can implement it). The position-wait helper's signature, polling cadence, and timeout semantics are fixed.


### Milestone 3 — Validation spike

Build a small Haskell spike at `spikes/read-model/` (modelled on the existing `spikes/command-cycle/` and `spikes/codec/`). Structure:

    spikes/read-model/
      cabal.project
      read-model-spike.cabal
      app/
        Main.hs                  -- runs all scenarios, prints [read-model-spike] OK on success
      src/
        Spike/ReadModel.hs       -- the typed ReadModel q r record + runQuery + waitFor
        Spike/CounterView.hs     -- read model deriving from the EP-1 Counter event stream
        Spike/InlineExample.hs   -- inline projection scenario
        Spike/AsyncExample.hs    -- async projection scenario + position-wait demo
      notes/
        prior-art.md             -- M1 working notes

The spike pins the same compiler and dependency versions as the existing spikes (`with-compiler: ghc-9.12.3`, hasql, effectful, streamly, the local kiroku/shibuya/shibuya-kiroku-adapter checkouts via `cabal.project`'s `source-repository-package` blocks — copy the shape from `spikes/command-cycle/cabal.project`).

Three scenarios, each printing its own `[read-model-spike scenario N] OK` on success:

1. *Inline projection — strong consistency.* Reuse the EP-1 Counter event stream. Define `CounterView` as a single-row table `counter_view(counter_name TEXT PRIMARY KEY, current_value INT, source_event_id UUID UNIQUE)`. Wire an inline projection (per EP-3 §3) that updates the row in the same tx as the `Incremented` event append. After the command returns, `runQuery counterView "main"` returns the new value immediately. Assertion: read-after-write returns the post-increment value with no wait.

2. *Async projection — eventual consistency + position-wait.* Add a second read model `CounterAuditView` populated by an async projection. After appending an event, immediately call `waitFor counterAuditView appendedPosition` and assert that `runQuery counterAuditView ...` then returns the new audit row. Assertion: `waitFor` blocks for non-zero time and returns; subsequent `runQuery` sees the new row. Also assert that without `waitFor`, an immediate read may miss the row (drive this by injecting a deliberate 100 ms pause in the async worker's per-event handler — the contention test must be reproducible).

3. *Position-wait timeout.* Stop the async projection worker entirely. Append an event. Call `waitFor counterAuditView appendedPosition` with a 1-second timeout. Assert that it returns a `WaitTimeout` error. This validates the failure mode chosen in §10 of the design doc.

Acceptance: `cabal run read-model-spike` exits 0 and prints `[read-model-spike] OK` as its final line. All three scenarios pass. The transcript is captured (either inline in this plan's Concrete Steps section, or in `spikes/read-model/transcript.txt` referenced from there). If a scenario reveals a design flaw, update §5–§10 of the design doc *before* fixing the spike — the spike validates the design, not the other way around.


### Milestone 4 — Publish and cascade

Move the design doc from working draft into final form at `docs/research/12-read-model-query-api-and-lifecycle.md`. Update `docs/research/00-overview.md` to reference §12 in its index. Cascade any new upstream gaps surfaced during M2/M3 into the MasterPlan (`docs/masterplans/1-keiro-research-foundation.md`) Surprises & Discoveries section, naming each gap and pointing at the new design doc section that motivated it. This lets the next iteration of EP-6 (or its successor) absorb the new gaps; EP-6 itself is closed and its synthesis doc (`docs/research/11-upstream-roadmap.md`) is preserved as-is.

Update this plan's Progress checklist (mark M1–M4 as complete with dates and artefact pointers), fill in Outcomes & Retrospective comparing the result to the Purpose section, and update the MasterPlan's Exec-Plan Registry (mark EP-8 Complete) and Progress (tick the EP-8 milestones).

Acceptance: `docs/research/12-read-model-query-api-and-lifecycle.md` exists. `docs/research/00-overview.md` references it. The MasterPlan's registry shows EP-8 Complete. The MasterPlan's Outcomes & Retrospective is updated to reflect the re-closure (the prior 2026-05-06 close-out remains in the file with the 2026-05-10 reopening note).


## Concrete Steps

Working directory for spike commands: `/Users/shinzui/Keikaku/bokuno/keiro/spikes/read-model/`.

1. Create the spike directory structure (M3 start). Use the existing `spikes/command-cycle/` as a template for `cabal.project`, `.cabal`, and the GHC 9.12.3 nix dev shell pin. Mirror the layout.

2. Run a fresh Postgres 18 against which the spike will append events. The MasterPlan records (Surprises & Discoveries 2026-05-05, EP-1) that kiroku's embedded `schema.sql` uses Postgres 18's `uuidv7()` function. The user's outer profile ships PG 17.9; the spike must use kiroku-project's flake which pins `pkgs.postgresql_18`. Source from `kiroku/flake.nix` if needed; otherwise launch via `nix run nixpkgs#postgresql_18` on a temporary directory. Apply kiroku's embedded `schema.sql` plus a per-spike migration creating `counter_view` and `counter_audit_view`.

3. Run scenario 1 (inline). Expected transcript tail:

        [read-model-spike scenario 1] OK
        [read-model-spike scenario 2] OK
        [read-model-spike scenario 3] OK
        [read-model-spike] OK

4. Capture the transcript. Replace the placeholder above with the actual transcript before marking M3 complete.

5. Move the design doc to `docs/research/12-read-model-query-api-and-lifecycle.md`. Update `docs/research/00-overview.md` (line range to be confirmed during M4) to add a §12 entry.

6. Update the MasterPlan's Exec-Plan Registry status row for EP-8 from "Not Started" to "Complete", tick the four EP-8 milestones in the MasterPlan's Progress section, and add a Revisions entry recording the closure.


## Validation and Acceptance

The plan is complete when *all* of the following hold:

1. `docs/research/12-read-model-query-api-and-lifecycle.md` exists, has §1 through (at least) §10, and is internally self-consistent. A reviewer reading it without prior context can answer: (a) what is a read model, (b) how do I pick a consistency mode, (c) what's the typed API, (d) how do I rebuild a read model whose schema changed, (e) what's the difference between a read model, a snapshot, and a projection.
2. `docs/research/00-overview.md` references the new §12.
3. `cabal run read-model-spike` (in `spikes/read-model/`) exits 0 with `[read-model-spike] OK` as the final transcript line. The transcript is captured.
4. All three spike scenarios pass: inline (strong), async + position-wait (eventual), position-wait timeout (failure mode).
5. The MasterPlan's Exec-Plan Registry shows EP-8 = Complete; the four EP-8 milestones are ticked in the MasterPlan's Progress section; any new upstream gaps surfaced by §7 (multi-stream / category subscriptions) or §10 (position-wait) are added to the MasterPlan's Surprises & Discoveries with a `**Cascade**:` line indicating which existing gap entry they extend (typically EP-6 §5.1 or §9.x).
6. This plan's Outcomes & Retrospective is filled in.


## Idempotence and Recovery

All steps are repeatable. The spike's database is per-run (use a fresh temp directory or a per-run schema). The design doc is a Markdown file overwritten in place. The MasterPlan registry edits are line-level and idempotent. If M3 reveals a design flaw, revert the M3 spike commits (do *not* edit history) and re-do M2 against the new finding before re-running M3 — the spike is the validation of the design, so a failing spike is a signal to revise the design, not to massage the spike.

If the design document drifts during a long M3, re-anchor against the spike's actual signatures before publishing in M4.


## Interfaces and Dependencies

External dependencies (consumed; not modified by this plan):

- `kiroku` and `kiroku-store` — for `globalPosition`, `subscriptions(subscription_name, last_seen)`, and the embedded `schema.sql`. No upstream change required by this plan; if §7 (multi-stream) surfaces a need for a prefix-style category subscription, the gap is recorded but not implemented here (EP-6's roadmap or its successor absorbs it).
- `shibuya` + `shibuya-kiroku-adapter` — for the async projection worker. Same at-least-once semantics as EP-3 (§3). The position-wait helper does *not* require the `HandlerInTransaction` shape EP-6 §5.1 records; that gap is about exactly-once write-side, whereas position-wait is a read-side consistency tool.
- `streamly`, `hasql`, `effectful` — substrate, fixed by the MasterPlan's 2026-05-04 streamly-substrate decision and the wider project conventions.
- `keiki` — not directly consumed by read models. Read models decode kiroku events through EP-2's `Codec e` (per `docs/research/07-codec-strategy.md`); they do not invoke `SymTransducer`.

Types and signatures that must exist at the end of M2 and M3 (the design doc fixes these; the spike instantiates them):

- `data ReadModel q r` — keiro-side typed wrapper. Fields (working draft, finalized in §5): `rmName :: Text`, `rmTable :: Text`, `rmVersion :: Int`, `rmShapeHash :: Text`, `rmConsistency :: ConsistencyMode`, `rmQuery :: q -> Hasql.Statement.Statement q r`, `rmCodec :: Codec r`. The exact shape is M2's deliverable; treat the above as a starting point.
- `data ConsistencyMode = Strong | Eventual | PositionWait { pwTimeoutMs :: Int }`.
- `runQuery :: ReadModel q r -> q -> Eff es r`.
- `waitFor :: ReadModel q r -> GlobalPosition -> Eff es ()` — the position-wait helper.
- `data WaitTimeout = WaitTimeout { wtTarget :: GlobalPosition, wtObserved :: GlobalPosition }` — error type returned in `Eff es`'s error channel.
- `keiro_read_models(name TEXT PRIMARY KEY, version INT NOT NULL, shape_hash TEXT NOT NULL, last_built_at TIMESTAMPTZ)` — the read-model metadata table introduced in §6 (rebuild protocol). Distinct from `subscriptions` (kiroku-owned) and `keiro_snapshots` (EP-4).

The exact column names and signatures may shift during M2; the design doc is authoritative and this section must be updated to match before M3 begins.
