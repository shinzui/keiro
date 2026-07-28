---
id: 145
slug: write-the-brownfield-migration-and-transducer-modeling-guide
title: "Write the brownfield migration and transducer modeling guide"
kind: exec-plan
created_at: 2026-07-28T10:48:59Z
intention: "intention_01kym5dc4ve69sxsjtzd81pbbz"
master_plan: "docs/masterplans/25-structural-consumer-type-ergonomics-and-soundness-preserving-adoption-for-keiro-dsl.md"
---

# Write the brownfield migration and transducer modeling guide

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A developer who wants to move an *existing* service onto keiro — a service whose wire
shapes, stored history, and consumers already exist — currently has the least guidance of
any keiro audience. The guides corpus in `docs/guides/` teaches greenfield construction
(`build-the-command-side.md`), post-adoption evolution (`evolution-and-replayability.md`),
and one framework-specific comparison (`adopting-keiro-from-tan-event-source.md`), but
nothing teaches the two things a brownfield migration actually needs: how to *model* the
domain well as a keiki transducer (which decisions belong in solver-visible scalars, how to
design registers, how to represent "not yet initialized", when to split streams), and how
to *walk the migration path* from historical bytes to a keiro-owned codec without ever
rewriting history or restoring a second codec authority.

After this plan is complete, a new guide exists at
`docs/guides/brownfield-migration-and-transducer-modeling.md`, it is registered in
`docs/guides/README.md`, every code example in it names a real symbol that exists in the
`jitsurei` package today, every relative link resolves, and it carries clearly named anchor
points where two later plans (`docs/plans/151-reduce-binding-boilerplate-skeleton-scaffolds-derived-nominal-bindings-and-explain-bindings.md`
and `docs/plans/152-prove-migrations-with-shadow-codec-comparison-and-structural-coverage-reporting.md`)
will append sections documenting their new tooling. A reader can open the guide, follow
Part A to model a transducer that passes keiro's validation gates on the first try, and
follow Part B to migrate a service with real stored history onto keiro with checkable
evidence at every step.

This is documentation-only work. No Haskell code, no schema, and no tooling changes. It is
child plan EP-2 of the MasterPlan at
`docs/masterplans/25-structural-consumer-type-ergonomics-and-soundness-preserving-adoption-for-keiro-dsl.md`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: Part A (transducer modeling) chapters drafted in the new guide file.
- [ ] Milestone 1: All Part A code examples verified against `jitsurei/src/Jitsurei/` sources.
- [ ] Milestone 2: Part B (brownfield migration path) chapters drafted.
- [ ] Milestone 2: Anchor comments for plans 151 and 152 placed and named.
- [ ] Milestone 3: Guide registered in `docs/guides/README.md`.
- [ ] Milestone 3: Link check passes; cited-symbol check passes; Proposal Test passage recorded.
- [ ] Outcomes & Retrospective written; ADR distillation pass done (expected outcome: no new ADR — see Validation).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Name the new guide file `docs/guides/brownfield-migration-and-transducer-modeling.md`
  and give it the two-part structure (Part A modeling, Part B migration) rather than two
  separate guides.
  Rationale: The MasterPlan's Vision names one "brownfield guide" covering both halves, and
  the halves reinforce each other — the migration path (Part B) repeatedly depends on the
  modeling doctrine (Part A), e.g. declaring the spec from historical wire shapes requires
  first knowing which values are decision scalars. One file also gives plans 151/152 a
  single append target.
  Date: 2026-07-28

- Decision: Teach the shadow-comparison step (Part B) as a *manual technique* today and
  leave a named anchor for plan 152's scaffolded comparison-runner workflow.
  Rationale: The generated runner and reusable comparison engine are delivered by
  `docs/plans/152-prove-migrations-with-shadow-codec-comparison-and-structural-coverage-reporting.md`
  (EP-9), which hard-depends on the IR-1 generation layer (EP-7) and does not exist yet.
  The MasterPlan's Integration Points section commits EP-8/EP-9 to appending their tooling
  sections to this guide as part of their own acceptance, "so the guides never describe
  tooling that does not exist." The manual technique (decode historical goldens and compare
  both encoders as parsed JSON `Value` semantics) is valid today and remains valid after the
  runner lands. Raw bytes remain provenance for the historical corpus, but Keiro's codec API
  does not own whitespace or object-key order.
  Date: 2026-07-28

- Decision: Position the new guide as the *how* companion to
  `docs/guides/adopting-keiro-from-tan-event-source.md`, which is the *why*.
  Rationale: The tan-ES guide is an argumentative comparison for engineers evaluating the
  migration decision from one specific in-house framework; it walks change classes and
  defends the single-edge-set trade. It deliberately does not teach modeling or migration
  mechanics. The new guide assumes the adoption decision is made, addresses any existing
  service (event-sourced under another framework, or CRUD), and teaches the mechanics. The
  two cross-link; neither duplicates the other.
  Date: 2026-07-28

- Decision: Handle the soft dependency on EP-1 (the guarantee ledger,
  `docs/plans/144-document-the-guarantee-ledger-what-the-dsl-buys-and-what-hand-written-services-lose.md`)
  exactly as the MasterPlan's Dependency Graph prescribes: at implementation time, check
  whether the ledger guide exists in `docs/guides/`; if it does, link it where the
  brownfield guide needs the layered-gate exposition; if not, carry a short temporary
  summary paragraph (three to five sentences on the gate layering, drawn from
  `docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md`) that EP-1
  later replaces with a link.
  Rationale: EP-2 has no hard dependencies and must be able to land first.
  Date: 2026-07-28

- Decision: Use `jitsurei` (this repository's worked-example package) as the sole source of
  code examples, verified against the tree, rather than inventing a hypothetical brownfield
  service's code.
  Rationale: The guides corpus's stated contract (`docs/guides/README.md`) is that examples
  are not pseudocode — `jitsurei` builds in this workspace and `cabal test jitsurei-test`
  exercises the behavior. `Jitsurei.OrderStream` already contains a genuine two-version
  codec with an upcaster (`upcastOrderPlacedV1`, the `qty` → `quantity` rename with a
  defaulted `sku`) — a real, compiling instance of exactly the version-not-normalize
  doctrine Part B teaches. `Jitsurei.Incident` contains a genuine lifecycle vertex
  (`Unreported`). Hypothetical brownfield fragments (e.g. a legacy CRUD table sketch) are
  allowed only in `text`/`json` fences that make no compilation claim.
  Date: 2026-07-28

- Decision: The guide's negative doctrine is fixed up front and non-negotiable: it must
  never teach a technique that (a) restores dual codec authority (an old codec kept as a
  live alternative writer/reader for current values), (b) hides an opaque Haskell guard
  behind checked-looking syntax, or (c) rewrites stored history. Every chapter of Part B is
  checked against the research note's ten-question Proposal Test before acceptance (see
  Validation and Acceptance).
  Rationale: Mandated by the MasterPlan's binding non-negotiable ("no ergonomic improvement
  may compromise soundness") and by the research note
  `docs/research/14-structural-consumer-type-tradeoffs.md`, whose central conclusion is that
  the constraints stay and only their cost falls.
  Date: 2026-07-28


- Decision: Teach generated Keiki 0.4 field projections as an optional Holes-level tool after
  plan 150, while keeping explicit decision scalars as the default modeling advice and clearly
  denying checked nested `.keiro` syntax.
  Rationale: The upstream prerequisite now exists, but the current DSL does not lower guard text
  into the executable transducer. This distinction is useful to all consumers and prevents both
  needless scalar duplication and false claims of DSL enforcement.
  Date: 2026-07-28


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This section makes the plan self-contained. Read it fully before drafting anything.

### What keiro and keiki are, in this repository

This repository (`/Users/shinzui/Keikaku/bokuno/keiro`, referred to below by
repository-relative paths) contains the keiro runtime: an event-sourcing framework for
Haskell services. An *aggregate* is one entity whose state is rebuilt by replaying its
stored events. keiro delegates the pure state machine to **keiki** (a separate library,
package `mori://shinzui/keiki/packages/keiki`): a keiki *transducer* is a set of edges,
each edge being "guard → (emit events, write registers, go to a vertex)". A *vertex* is a
named control state (like `Placed` or `Triaging`); a *register* is a typed data slot
carried alongside the vertex. Crucially, keiki has no separate decide/evolve pair: the same
edges execute commands forward *and* replay history — hydration re-inverts each stored
event back to the command that produced it and re-checks the edge's guard. Every modeling
decision in Part A of the guide flows from that single fact.

keiro wraps a transducer, an initial state, an event codec, and a stream-naming function
into an `EventStream` record, and only a validated wrapper (`ValidatedEventStream`,
produced by `mkEventStream`/`mkEventStreamOrThrow` in
`keiro-core/src/Keiro/EventStream/Validate.hs`) can reach a command runner. Services may be
hand-written against these APIs or generated from a typed `.keiro` spec by the
**keiro-dsl** toolchain (check/scaffold/diff), which adds static evolution gates that
hand-written services do not get.

### The worked example package

`jitsurei/` is a sibling Cabal package in this repository whose sole purpose is to be the
guides' living example; `cabal test jitsurei-test` exercises it. The modules this guide
draws on, all verified present in the tree today:

- `jitsurei/src/Jitsurei/OrderStream.hs` — the order aggregate. Exports `orderCodec`
  (a `Codec OrderEvent` with `schemaVersion = 2` and
  `upcasters = [(1, const upcastOrderPlacedV1)]`), `upcastOrderPlacedV1` (the version-1
  payload used `qty` and had no `sku`; the upcaster reads `qty`, defaults `sku` to
  `"UNKNOWN"`, and returns the version-2 shape), `orderTransducer` (built with
  `Keiki.Builder`, initial vertex `NotStarted`), `orderEventStream` and
  `snapshotOrderEventStream` (both `ValidatedEventStream` values built with
  `mkEventStreamOrThrow`), and `orderStream :: OrderId -> Stream OrderEventStream`
  (one stream per order entity, named from the order id via `Stream.entityStream`).
- `jitsurei/src/Jitsurei/Incident.hs` — the incident aggregate. Its `IncidentState` starts
  at `Unreported`: a vertex meaning "no incident exists yet", from which only
  `RaiseIncident` is accepted. This is the lifecycle-vertex pattern in compiled form —
  the aggregate models absence as a vertex, not as a record full of dummy values.

### The requirement inputs this plan translates into local guidance

The guide is EP-2 of MasterPlan 25 and implements specific sections of two documents. The
guide itself must cite both by these repository-relative paths and say which sections it
implements; this plan does the same:

**`docs/research/14-structural-consumer-type-tradeoffs.md`** (the research note). The guide
implements its sections 4, 5, 6, and 12:

- *Section 4 ("Whole-Value Semantics Give Up Ad Hoc Nested Keiki Logic")* — guards should
  default to explicit solver-visible scalar fields. A command may carry a rich payload (e.g. a
  `DocInfo` record) that is copied wholesale into events and registers for replay and
  projection, but the transducer's guard compares an explicit scalar such as a
  `contentHash :: Text` field carried beside it (`when register.contentHash !=
  command.contentHash`). Promoting frequently guarded values to explicit scalars is
  usually the better domain model: identity, revision, lifecycle, and
  content hash are decision state; the full payload is event/projection data. An opaque
  Haskell predicate over a payload is never hidden behind checked syntax.
  After plan 150, a hand-written Hole may instead use a generated Keiki 0.4
  `FieldProjection` witness for a genuine scalar field when its base/result satisfy Keiki's
  guard-only/direct-base/curated-registry rules. This is a typed Holes API, not nested `.keiro`
  syntax; the current DSL still renders guard intent as comments rather than exact executable
  lowering.
- *Section 5 ("Separate Artifact Streams Give Up Monolithic Atomicity")* — stable entities
  get independently keyed streams (one stream per entity), not one monolithic stream
  holding a catalog map of every entity. A reconciler dispatches per-entity observations;
  each hydrated transducer decides Added/Updated/no-op/Removed from scalar state. What is
  given up is all-or-nothing visibility of a large catalog update; what is gained is
  solver visibility, per-entity concurrency, and bounded replay. Recovery becomes
  convergence across idempotent streams.
- *Section 6 ("Explicit Initial Values and Fixtures Give Up Convenient Defaults")* — never
  fake an initial value. `ProjectId ""` is type-correct and domain-invalid;
  `error "unset"` compiles and detonates during hydration. Prefer a lifecycle vertex: an
  Absent-style vertex makes a payload register unavailable until an import/add event
  initializes it.
- *Section 12 ("Existing History Makes Structural Adoption a Migration")* — the four
  migration doctrines Part B is built around: import real goldens before declaring the
  shape (declare from the historical wire contract, never from Haskell constructor
  spelling); run shadow comparison of old and new codecs over the corpus; version rather
  than normalize silently (a representational change is a new codec version plus an
  explicit upcaster, never a rewrite of history and never dismissed as "formatting");
  retain legacy decoders only at the version boundary (a historical decoder may remain as
  an upcaster input, never as a second authority for newly emitted values).

The research note also supplies the ten-question **Proposal Test** ("A Proposal Test for
Future Keiro Improvements": authority, replay, visibility, compatibility direction,
ownership, completeness, migration, recovery, performance, negative proof) that this plan's
Validation section applies to the guide.

**`docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md`**
(IR-1). The guide implements its modeling constraints as reader-facing doctrine: whole
mapped values in Keiki's symbolic language (copy wholesale; compare only where constraints
exist; no nested lookup/membership/quantified guards); the head-invertibility rule ("a
mapped value needed to recover a command must be present as an invertible field in the
first emitted private event of a multi-event edge"); explicit initial values for registers
(Keiro must not invent `Default` instances or emit a latent `error` as valid initial
state); and the private/public contract separation. The guide does *not* document IR-1's
structural/opaque declaration syntax — that code does not exist yet (EP-6/EP-7) and the
guide never describes tooling that does not exist.

"Invertible from the first emitted event" is keiki's head-recoverability rule, enforced by
the validator: every command field an edge reads must be recoverable from the *first* event
the edge emits, because replay reconstructs the command from that head event before
re-checking the guard. keiki diagnoses violations as `HirHeadUnrecoverable`
(`Keiki.Core`, in the keiki repository at `/Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Core.hs`);
keiro's stream boundary renders it as the `HeadUnrecoverable` warning case in
`keiro-core/src/Keiro/EventStream/Validate.hs` and fails validated construction on it.

### Relevant ADRs (read during creation; the guide cites all three)

- `docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md`
  (ADR 0002). Tightening a guard is replay-relevant: a stored event appended under the old
  guard may no longer invert, and the next command on such a stream fails
  `HydrationReplayFailed HydrationNoInvertingEdge`. The sanctioned remedy is a
  `replay-only` twin transition carrying the removed guard region (`old-guard ∧
  ¬new-guard`): Keiki 0.4's `EdgeMode = Live | ReplayOnly` with two-phase inversion (live
  edges tried first), `keiro-dsl diff` printing a paste-ready twin via the
  `AggGuardTightened` advisory, and retirement of the twin once the replay audit proves no
  live stream exercises the removed region. Part A's guard-evolution chapter teaches this.
- `docs/adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md` (ADR 0003).
  Snapshot compatibility is the triple (`stateCodecVersion`, register-layout `shapeHash`,
  control-state/fold `stateShapeHash`); hand-written fold changes carry a manual bump
  obligation (or an explicit `withFoldFingerprint` token). The guide cites this wherever
  the migration path touches snapshots (pre-cutover audit, cutover expectations).
- `docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md` (ADR 0004).
  The layered gate inventory (`check` → `diff` → stream-boundary validation → versioned
  goldens in CI → database-backed replay audit) and the rollout rules Part B's final
  chapter teaches verbatim: an aggregate codec version bump cannot run with mixed old/new
  replicas (stop-the-world or blue/green only), and after the first new-version event
  rollback is roll-forward-only because old code returns `VersionAhead`.

No relevant cross-repository ADR beyond Mori's `mori://shinzui/mori/okf/adrs/concepts/ADR-6`
(cited by IR-1 as origin context) was found; the guide does not need it.

### The existing guides, and what the new guide must not duplicate

The new guide complements — and links to, rather than restates — the following, all under
`docs/guides/` unless noted:

- `adopting-keiro-from-tan-event-source.md` — the *why* for one specific legacy framework:
  a change-class-by-change-class comparison defending the single-edge-set trade, the
  guard-tightening concession, and what migration buys (the one-time `AuditFull` replay
  audit). The new guide is the *how* for any brownfield service and cross-links this for
  readers who still need the argument. It must not repeat the comparison table.
- `evolution-and-replayability.md` — the exhaustive post-adoption change-class reference
  (gates, procedures, deploy ordering). The new guide links into it for every procedure
  that applies after cutover; it does not restate the gate table.
- `evolve-events-safely.md` — the worked upcaster (`orderCodec`, `upcastOrderPlacedV1`,
  `decodeRaw` testing). Part B's versioning chapter builds on this example instead of
  inventing a new one.
- `snapshots-and-hydration.md` — snapshot mechanics and metrics; linked from the
  pre-cutover chapter.
- `choosing-a-primitive.md` — the routing map (one transducer per stream; when to use
  projections/process managers/routers). Part A's one-stream-per-entity chapter links here
  for the cross-stream primitives instead of re-teaching them.
- `build-the-command-side.md` — the greenfield construction walkthrough (`Keiki.Builder`
  DSL, `deriveAggregateCtors`/`deriveWireCtors`, `runCommand`). Part A assumes it as the
  construction reference. (Note: `Jitsurei.OrderStream` and `Jitsurei.Incident` today use
  the combined `deriveAggregate` splice; the guide must cite whichever splice the cited
  module actually uses.)
- `migrating-to-validated-event-stream.md` — the compiler-driven `ValidatedEventStream`
  source migration (Path A DSL / Path B hand-written, the `…Def` rename pattern, the
  latent-bug escape). Part B's stream-boundary chapter is a cross-link to this guide plus
  brownfield-specific framing, not a restatement.
- `docs/guides/README.md` — the corpus index. The new guide must be registered here.
- The user-reference pages the corpus links (`docs/user/replay-safety.md`,
  `docs/user/codecs-and-event-evolution.md`, `docs/user/deploy-ordering.md`,
  `docs/user/typed-spec-toolchain.md`) are cross-link targets, not content to duplicate.

### Terms used by this plan, defined

- *Brownfield* — a service that already exists in production, with stored data and live
  consumers, being migrated onto keiro; opposed to *greenfield* (built on keiro from day
  one).
- *Golden* — a checked-in file containing a genuine wire payload (captured from
  production), used as finite evidence that the current code still decodes that historical value.
- *Shadow comparison* — running the old (historical) codec and the new (keiro-owned) codec
  over the same corpus during development, comparing parsed/canonical JSON meaning and decode
  results, before the new codec takes authority.
- *Upcaster* — a pure function from an old payload version's JSON to the next version's
  JSON, registered in the codec and run at decode time forever (payloads are never
  rewritten).
- *Replay audit* — the database-backed pre-deploy check (`keiro/src/Keiro/ReplayAudit.hs`:
  `AuditTargeted` over affected event types, `AuditFull` for one-time cutovers;
  `auditExitCode` non-zero blocks deployment) that replays real stored streams through the
  candidate binary.


## Plan of Work

All work happens in two files: the new guide
`docs/guides/brownfield-migration-and-transducer-modeling.md` (created) and
`docs/guides/README.md` (one entry inserted). Three milestones, each independently
verifiable.

### Milestone 1 — Part A: transducer modeling

Scope: create the guide file with its front matter (title, audience statement, the
positioning paragraph naming `adopting-keiro-from-tan-event-source.md` as the *why*
companion, and the normative-source citation block naming
`docs/research/14-structural-consumer-type-tradeoffs.md` sections 4, 5, 6, 12 and
`docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md` by
path), then draft the five Part A chapters. At the end of the milestone the file exists,
Part A is complete, and every Haskell fence in it names symbols verified against
`jitsurei/src/Jitsurei/`. Acceptance: the six named headings below exist; the verification
grep in Concrete Steps finds every cited symbol.

The chapters, with the exact content each must carry (headings must use these names so the
acceptance check can find them):

**"Part A: Modeling the domain as a transducer"** — a short orientation: one edge set is
both execution and replay (state the fact and its consequence — every modeling choice is
also a replay choice), and the layered-gate summary or EP-1 ledger link per the Decision
Log's soft-dependency decision.

**"Decision scalars versus payload data"** (research §4). Teach the default split: guards decide
from explicit solver-visible scalar fields; payloads are copied wholesale for replay and
projection. Show the shape in DSL-flavored `text` fences (the research note's
`when register.contentHash != command.contentHash` example with the full `doc` payload
carried beside it), and the doctrine that promoting frequently guarded values to explicit
scalars (identity, revision, lifecycle, content hash) is the better domain model.
Then describe plan 150's optional generated Keiki 0.4 projection facade for scalar nested
decisions in hand-written Holes, including its guards-only/direct-base/curated-result limits and
the fact that `.keiro` has no checked nested-path lowering yet. Explicitly state the negative rule: an opaque Haskell predicate over a payload must never
masquerade as a checked guard — if a predicate cannot be expressed over scalars, it is
opaque, named as such, and audited (IR-1's opaque-guard diagnostic contract). Use
`Jitsurei.OrderStream`'s command records (`PlaceOrderData` with `orderId`, `sku`,
`quantity` — all scalars the guards and emits use directly) as the compiled illustration
that jitsurei's aggregates are already scalar-first.

**"Register design and head invertibility"** (IR-1's replay constraints). Define
registers, then teach the rule that makes register design non-arbitrary: every command
field an edge reads must be recoverable from the first event that edge emits (keiki
`HirHeadUnrecoverable`; keiro's `HeadUnrecoverable` warning in
`keiro-core/src/Keiro/EventStream/Validate.hs` fails `mkEventStream`). Consequences: if a
register write needs a value, the head event carries that value; a value computed in a
side effect and never emitted cannot feed a register. Cross-link
`docs/user/replay-safety.md` and `migrating-to-validated-event-stream.md`'s "latent
replay-safety bug" section for what it looks like when this rule is violated in an
existing design.

**"Lifecycle vertices instead of fake initial values"** (research §6). The doctrine:
never `error`, never a domain-invalid zero value (`ProjectId ""`), never an invented
`Default`. Model absence as a vertex: the aggregate starts in an Absent/uninitialized
vertex from which only the initializing command is accepted, and payload registers are
populated by the import/add event. Cite the compiled example: `Jitsurei.Incident`'s
`IncidentState` starts at `Unreported` and only `RaiseIncident` leaves it
(`jitsurei/src/Jitsurei/Incident.hs`); `Jitsurei.OrderStream`'s `NotStarted` plays the
same role. For brownfield specifically: an import event ("BackfilledFromLegacy" style)
that initializes the register file is the sanctioned way to seed migrated entities —
never a synthetic initial state pretending history existed.

**"One stream per entity, not a catalog map"** (research §5). Teach why a monolithic
stream holding a map of all entities fights the model (opaque membership/diff logic,
solver blindness, one version counter contended by unrelated updates, unbounded replay)
and the correct shape: independently keyed streams per stable entity —
`orderStream :: OrderId -> Stream OrderEventStream` via `Stream.entityStream` in
`jitsurei/src/Jitsurei/OrderStream.hs` is the compiled pattern. Cover what is given up
(atomic catalog visibility) and the recovery model (idempotent convergence; first-class
orchestration state when a coherent generation matters). Route cross-entity cooperation
to `choosing-a-primitive.md` rather than re-teaching projections/process managers.

**"Guard evolution with replay-only edges"** (ADR 0002). Brownfield services tighten
rules constantly, so Part A closes by teaching the guard-evolution contract *before* the
reader models anything: tightening a guard strands history
(`HydrationNoInvertingEdge`); the sanctioned remedy is the `replay-only` twin carrying
`old-guard ∧ ¬new-guard`; `keiro-dsl diff` prints the paste-ready twin
(`AggGuardTightened`); twins retire when the replay audit proves the region dead. Cite
`docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md` by
path and link `evolution-and-replayability.md`'s decisions section for the full
procedure. The modeling payoff to state explicitly: model guards so that future
tightening is *scalar-visible* (a new scalar comparison), because that is what makes the
computed twin and the targeted audit possible.

### Milestone 2 — Part B: the brownfield migration path

Scope: draft the seven Part B chapters (research §12 expanded into a walkable path) plus
the two tooling anchors. At the end of the milestone the guide is content-complete.
Acceptance: the named headings exist, the two anchor comments are present verbatim, and
no chapter teaches a forbidden technique (checked in Milestone 3's gate pass).

**"Part B: The migration path"** — orientation: the path's invariant (stored bytes are
facts; every step produces evidence, not confidence) and its stations in order.

**"Inventory the existing wire shapes"**. First station: enumerate every persisted
surface of the legacy service — event/row payloads, queues, timers, cached state,
public messages — and for each record where bytes live, who reads them, and what the
*actual* serialized shape is (not what the Haskell types suggest). Concrete technique:
sample real rows per shape into a corpus directory (suggest
`test/goldens/legacy/<shape>/`), including the rare variants (missing keys, explicit
nulls, every union tag observed). The chapter states why constructor spelling lies:
codecs omit `Nothing` fields, generic encodings choose tag layouts, and old bug eras
leave shapes the types no longer admit.

**"Capture goldens before declaring the spec"** (research §12, first doctrine). The
ordering rule that gives the chapter its name: goldens are captured from production
*before* any `.keiro` spec or codec is declared, and the declaration is then derived
from the historical wire contract. Declaring first and testing after invites declaring
the Haskell spelling. Cross-link `evolve-events-safely.md` for the `decodeRaw` testing
pattern and ADR 0004's rule that hand-captured production payloads are authoritative
(golden synthesis never overwrites them). State what a golden proves and does not prove
(ADR 0004: decode compatibility only — never that an event still inverts or folds
identically).

**"Shadow comparison of old and new codecs"** (research §12, second doctrine). The
manual technique, today: with the corpus in place, write a temporary test that (1)
decodes each golden with the *new* codec, (2) encodes representative domain values with
*both* codecs and compares parsed/canonical JSON meaning, and (3) classifies every difference as either exact
parity or explicit version/upcaster work — there is no third bucket called "close
enough". Use `orderCodec`'s v1/v2 split as the worked classification: `qty` vs
`quantity` is not parity; it is version work, and `upcastOrderPlacedV1` is what that
work looks like. Immediately after this chapter's body, place the plan-152 anchor
(below).

**"Version, never silently normalize"** (research §12, third doctrine). If the desired
new representation differs from history, that is a new codec version plus an explicit
upcaster — never a rewrite of stored events, never "just formatting". Ground it in the
repository's ground truth (`evolution-and-replayability.md`: kiroku is append-only,
there is no data-migration tool, upcasters run at decode time forever) and the worked
upcaster in `evolve-events-safely.md`. Include the aggregate-global `schemaVersion`
rule (next version is aggregate-max+1).

**"Legacy decoders only at the version boundary"** (research §12, fourth doctrine). The
old decoder's one legitimate afterlife: as the reader of its own version rung (an
upcaster input). The forbidden afterlife: as a second live authority — a fallback
decode path for current-version values, or an alternate encoder "kept just in case".
State the dual-authority test plainly: after cutover, exactly one codec writes and one
chain reads; if any current value can round-trip through the legacy codec in
production, the migration is not done.

**"Migrate the stream boundary to ValidatedEventStream"**. The brownfield-specific
framing over `migrating-to-validated-event-stream.md` (cross-linked, not restated): a
ported legacy aggregate meets `mkEventStream` for the first time here, and a
construction-time failure (`HeadUnrecoverable`, determinism, dead edges) is the checker
finding a real porting bug or a latent legacy bug — the resolution paths are in that
guide. `mkEventStreamUnchecked` is named once, as the forensics bypass that is never a
migration step (ADR 0004).

**"Pre-cutover replay audit and deploy ordering"** (ADR 0004). The final station: run
the one-time full audit (`AuditFull`, `Keiro.ReplayAudit`,
`keiro/src/Keiro/ReplayAudit.hs`) of the ported service's entire history through the
candidate binary against a production-copy database; `auditExitCode` non-zero means do
not cut over. Then the cutover rules verbatim from
`docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md`: codec
version bumps need stop-the-world or blue/green (one codec version writes and decodes;
mixed replicas are unsound); after the first new-version event, rollback is
roll-forward-only (`VersionAhead`). Snapshot expectations at cutover cite ADR 0003
(`docs/adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md`) and
`snapshots-and-hydration.md` (misses and full replays are the expected one-time cost).
Close by handing the reader to `evolution-and-replayability.md` as the guide that
governs every change *after* this one.

**Anchor points for later plans.** Two HTML comments, placed exactly and named so plans
151/152 can find them mechanically; each sits under a short one-sentence "tooling to
come" note so readers are not confused by the comment-only anchor:

```text
<!-- appended-by: docs/plans/152-prove-migrations-with-shadow-codec-comparison-and-structural-coverage-reporting.md
     anchor: codec-compare-tooling
     (the scaffolded comparison-runner section lands here; the manual technique above remains valid) -->
```

placed at the end of "Shadow comparison of old and new codecs", and

```text
<!-- appended-by: docs/plans/151-reduce-binding-boilerplate-skeleton-scaffolds-derived-nominal-bindings-and-explain-bindings.md
     anchor: binding-authoring-tooling
     (binding skeleton scaffolds and `check --explain-bindings` sections land here) -->
```

placed at the end of Part A (after "Guard evolution with replay-only edges"), where
consumer-owned-type binding authoring guidance will naturally attach once EP-7/EP-8
exist.

### Milestone 3 — Registration, verification, and the soundness gate

Scope: insert the README entry, run the mechanical checks, and perform the Proposal Test
pass. At the end of the milestone the plan's acceptance criteria all hold. Acceptance: the
commands in Concrete Steps succeed with the expected output; the Validation section's gate
questions are answered in this plan file.

Edit `docs/guides/README.md`: insert one bullet after the literal
`[Migrating To ValidatedEventStream](migrating-to-validated-event-stream.md)` entry
(keeping the index's adoption-path ordering — this guide follows the stream migration it
links to):

```markdown
- [Brownfield Migration And Transducer Modeling](brownfield-migration-and-transducer-modeling.md)
  is for migrating an existing service onto keiro: modeling decisions as
  solver-visible scalars, lifecycle vertices, one stream per entity, and the
  goldens-first shadow-compared versioned migration path.
```


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`.

1. Create `docs/guides/brownfield-migration-and-transducer-modeling.md` and write Part A
   per Milestone 1, then Part B per Milestone 2. Prose-first; every fence carries a
   language tag (`haskell` for compiled jitsurei citations, `text` for DSL-flavored or
   hypothetical shapes, `json` for payload examples, `bash` for commands).

2. Verify every cited Haskell symbol exists (repeat after any edit that adds a citation).
   Expected: every grep prints at least one match; any silent miss is a broken citation.

    ```bash
    grep -n "upcastOrderPlacedV1\|orderCodec\|orderTransducer\|orderStream ::" jitsurei/src/Jitsurei/OrderStream.hs
    grep -n "Unreported\|incidentTransducer\|RaiseIncident" jitsurei/src/Jitsurei/Incident.hs
    grep -n "HeadUnrecoverable" keiro-core/src/Keiro/EventStream/Validate.hs
    grep -n "AuditFull\|AuditTargeted\|auditExitCode" keiro/src/Keiro/ReplayAudit.hs
    grep -n "HirHeadUnrecoverable" /Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Core.hs
    ```

3. Register the guide in `docs/guides/README.md` per Milestone 3.

4. Check that every relative link in the new guide resolves. Expected output: nothing (an
   empty result means all targets exist); any printed path is a broken link to fix.

    ```bash
    cd docs/guides && grep -o '](\([^)#]*\))' brownfield-migration-and-transducer-modeling.md \
      | sed 's/](\(.*\))/\1/' | sort -u \
      | while read -r f; do [ -e "$f" ] || echo "BROKEN: $f"; done
    ```

   Run the same loop over `README.md` to confirm the new index entry resolves.

5. Confirm the two anchor comments are present and named. Expected: two lines, one per
   plan number.

    ```bash
    grep -n "appended-by: docs/plans/15[12]" docs/guides/brownfield-migration-and-transducer-modeling.md
    ```

6. Perform the Proposal Test pass (Validation and Acceptance below), recording the
   answers in this plan's Validation section context and fixing any chapter that fails.

7. Update this plan's Progress, Decision Log (for any judgment calls made while
   drafting), and Outcomes & Retrospective. Commit with conventional-commit style and
   both required trailers:

    ```text
    docs(guides): add the brownfield migration and transducer modeling guide

    Part A teaches decision scalars, register head-invertibility, lifecycle
    vertices, one-stream-per-entity, and replay-only guard evolution; Part B
    walks the goldens-first, shadow-compared, versioned migration path with
    anchors for the plan-151/152 tooling sections.

    ExecPlan: docs/plans/145-write-the-brownfield-migration-and-transducer-modeling-guide.md
    Intention: intention_01kym5dc4ve69sxsjtzd81pbbz
    ```


## Validation and Acceptance

Because this is a documentation change, acceptance is observable properties of the tree
plus a doctrine gate, not a test suite.

**Observable acceptance.** All of the following hold, checkable by the commands in
Concrete Steps:

- `docs/guides/brownfield-migration-and-transducer-modeling.md` exists and contains the
  named chapter headings: "Part A: Modeling the domain as a transducer", "Decision
  scalars versus payload data", "Register design and head invertibility", "Lifecycle
  vertices instead of fake initial values", "One stream per entity, not a catalog map",
  "Guard evolution with replay-only edges", "Part B: The migration path", "Inventory the
  existing wire shapes", "Capture goldens before declaring the spec", "Shadow comparison
  of old and new codecs", "Version, never silently normalize", "Legacy decoders only at
  the version boundary", "Migrate the stream boundary to ValidatedEventStream",
  "Pre-cutover replay audit and deploy ordering".
- The guide cites, by repository-relative path,
  `docs/research/14-structural-consumer-type-tradeoffs.md` (stating it implements
  sections 4, 5, 6, and 12),
  `docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md`,
  `docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md`,
  `docs/adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md`, and
  `docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md`.
- Every relative link resolves (step 4 prints nothing) and every cited code symbol is
  found in the tree by step 2's greps.
- The two `appended-by` anchor comments for plans 151 and 152 are present (step 5 prints
  exactly two matching locations).
- `docs/guides/README.md` lists the guide and the link resolves.

**The soundness gate (mandatory, from the MasterPlan and the research note's ten-question
Proposal Test).** Before the guide is accepted, walk each Part B chapter — and Part A's
guard-evolution and decision-scalar chapters — against the Proposal Test in
`docs/research/14-structural-consumer-type-tradeoffs.md` ("A Proposal Test for Future
Keiro Improvements"). For a documentation plan the test is applied to *what the guide
teaches*: the guide must never teach a technique that restores dual codec authority
(question 1 — after cutover exactly one codec is the executed authority; the legacy
decoder survives only as an upcaster input), hides an opaque guard behind checked syntax
(question 3 — predicates not expressible over scalars are named opaque and audited, never
dressed as checked), or rewrites history (question 7 — migration is versions and
upcasters over append-only bytes, with goldens as the migration evidence). Questions 4
(compatibility direction) and 8 (recovery) are answered by the deploy-ordering chapter
(stop-the-world/blue-green, roll-forward-only after the first new-version event) and the
audit chapter (a failed audit means the old release continues untouched and the migration
retries). Record the pass — chapter by chapter, one line each — in this plan (Surprises &
Discoveries if anything needed rework, otherwise a Decision Log entry stating the pass
was clean) before marking Milestone 3 complete.

**Human read-through.** One full read of the guide checking the complement-don't-duplicate
contract: no restatement of the tan-ES comparison table, the evolution gate table, or the
ValidatedEventStream migration steps — links instead.

**ADR distillation (plan completion).** Expected outcome: no new ADR — the guide creates
no new architectural decision; it teaches existing ones (ADRs 0002/0003/0004) and the
research note's doctrine. If drafting surfaces a durable decision not yet recorded
(surprises only), create or amend an ADR in `docs/adr/` per the repository's ADR workflow
and note it here.


## Idempotence and Recovery

Every step is safe to repeat. Writing the guide file again overwrites only the guide
file; the README edit is a single idempotent bullet insertion (check for the link's
presence before inserting to avoid a duplicate entry); the verification commands are
read-only. There is no generated code, no database, and no external state. If drafting is
interrupted, the Progress checklist plus the committed partial file are sufficient to
resume: re-read this plan's Plan of Work, find the first unchecked item, continue. If a
cited jitsurei symbol has drifted by the time of implementation (the tree moves), do not
cite from memory — re-read the module, cite what exists, and record the drift in
Surprises & Discoveries. Rollback of the whole plan is `git revert` of its commits; no
other cleanup exists.


## Interfaces and Dependencies

No code interfaces are created or changed. The deliverable interfaces are documents:

- `docs/guides/brownfield-migration-and-transducer-modeling.md` — created; the chapter
  headings named in Validation are its stable structure, and the two `appended-by` anchor
  comments (`anchor: codec-compare-tooling`, `anchor: binding-authoring-tooling`) are the
  integration contract consumed by
  `docs/plans/151-reduce-binding-boilerplate-skeleton-scaffolds-derived-nominal-bindings-and-explain-bindings.md`
  and
  `docs/plans/152-prove-migrations-with-shadow-codec-comparison-and-structural-coverage-reporting.md`,
  which append their tooling sections at those anchors as part of their own acceptance.
- `docs/guides/README.md` — one entry added.

Documents and code this plan reads but does not modify: the research note
(`docs/research/14-structural-consumer-type-tradeoffs.md`), IR-1
(`docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md`),
ADRs 0002/0003/0004 under `docs/adr/`, the existing guides under `docs/guides/` and the
user-reference pages under `docs/user/` named in Context and Orientation, the jitsurei
sources `jitsurei/src/Jitsurei/OrderStream.hs` and `jitsurei/src/Jitsurei/Incident.hs`,
`keiro-core/src/Keiro/EventStream/Validate.hs`, `keiro/src/Keiro/ReplayAudit.hs`, and
(cross-repository, read-only, for the head-invertibility citation) keiki's
`src/Keiki/Core.hs` via the Mori-registered checkout at
`/Users/shinzui/Keikaku/bokuno/keiki`.

Plan-level dependencies: none hard. Soft dependency on EP-1
(`docs/plans/144-document-the-guarantee-ledger-what-the-dsl-buys-and-what-hand-written-services-lose.md`):
if its guarantee-ledger guide exists in `docs/guides/` at implementation time, link it for
the layered-gate exposition; otherwise carry the temporary summary paragraph described in
the Decision Log, to be replaced by EP-1.


---

Revision note: Updated modeling guidance for released Keiki 0.4 projections: explicit decision
scalars remain the default, eligible projections are a generated Holes-level API, and checked
nested `.keiro` syntax remains unavailable without exact lowering, 2026-07-28.
