---
id: 7
slug: internal-decider-style-ergonomic-facade-over-runcommand
title: "Internal Decider-style ergonomic facade over runCommand"
kind: exec-plan
created_at: 2026-05-09T14:41:34Z
---

# Internal Decider-style ergonomic facade over runCommand

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

**Status: exploratory.** This plan exists to investigate a hedge against the v1 contract
decision's ergonomic costs. It MAY land as a shipped feature, MAY be downgraded to a
documentation-only cookbook entry, or MAY be rejected outright. The decision sits with
the implementation MasterPlan, which is downstream of this exploration.


## Purpose / Big Picture

The 2026-05-09 cost-benefit audit on the keiro `SymTransducer`-vs-`Decider` contract
decision (recorded in the parent MasterPlan's Surprises & Discoveries entry of the same
date, and as a candid ledger in `docs/research/06-command-cycle-design.md` §2) confirmed
the choice **for users with workflow features**: the `tick`/`delta` access (timers,
child-workflow completion), the precise 3-way `step` return, and the future-bet `phi`
symbolic carrier all justify the contract for process managers and v2 workflows.

The audit also surfaced a real ergonomic cost paid by **users without workflow features
— pure event-sourced aggregates** (`Order`, `Account`, `Invoice`, the modal CQRS
shape):

- The five-parameter type `EventStream phi rs s ci co` is heavier than necessary for an
  aggregate that has no register file, no ε-edges, and no symbolic predicates.
- The hidden-input / `solveOutput` constraint (event payload fields must be direct
  projections of input fields; `TApp1`/`TApp2` cause replay failures) is an ongoing
  burden the simpler `Decider` shape `(c -> s -> [e])` / `(s -> e -> s)` does not
  impose.
- The `BoolAlg phi (RegFile rs, ci)` constraint plumbed through every `runCommand`
  signature looks like noise to a CQRS author whose aggregates do not exercise `phi` or
  the register file.

The hypothesis under exploration: **a thin internal facade `Keiro.Decider` could give
pure-CQRS users `Decider`-shaped ergonomics while preserving `SymTransducer` underneath
for users who do need workflow features.** Concretely, a record:

    data PureAggregate c e s = PureAggregate
      { paInitialState :: s
      , paIsTerminal   :: s -> Bool
      , paDecide       :: c -> s -> Either AggError [e]
      , paEvolve       :: s -> e -> s
      , paEventCodec   :: Codec e
      , paEventTag     :: e -> Text
      }

    runPureCommand :: PureAggregate c e s -> Stream a -> c -> Eff es ...

Internally `runPureCommand` builds an `EventStream phi rs s ci co` (with `phi ~ NoSym`,
`rs ~ '[]`, `ci ~ c`, `co ~ e`) on the fly from the `PureAggregate` record and dispatches
to `runCommand`. Users with workflow needs continue to author `EventStream` directly.

If realised, the user-visible win is: a CQRS author's aggregate definition fits in 30
lines of straightforward `decide`/`evolve`-shaped code (no `Term`s, no `OutTerm`s, no
`InCtor` machinery, no `BoolAlg` constraint), while keiro v2 workflows continue to work
unchanged.

If rejected, the documented analysis tells future maintainers (and the keiro v1
retrospective) why we chose to expose `EventStream` directly to all users.

The exit criterion is a decision recorded in this plan's Decision Log: **ship**,
**ship as cookbook only**, or **reject**.


## Progress

- [ ] M1 — Survey the actual ergonomic shape a pure-CQRS aggregate hits today using
      the EP-1 spike's contract. Author a "before" example: a 3-state Order aggregate
      (`Pending → Submitted → Delivered`) with two commands and three events, written
      against `EventStream phi rs s ci co` directly. Count lines, type annotations,
      keiki-specific constructs (`InCtor`, `Term`, `OutTerm`).
- [ ] M2 — Author the same aggregate against the proposed `Keiro.Decider`-style
      facade. Count the same metrics. Compare side-by-side.
- [ ] M3 — Verify the facade can be implemented purely as a wrapper over `runCommand`
      (no changes to `EventStream`, no changes to keiki). Sketch the wrapper's type
      signature and the translation from `PureAggregate c e s` to
      `EventStream NoSym '[] s c c` (or whatever phi/rs phantoms work for a no-workflow
      case). Identify any load-bearing complications.
- [ ] M4 — Make the decision. Three possible outcomes, each with a follow-up artifact:
      (a) **Ship** → upgrade this plan with concrete implementation milestones (M5+);
      (b) **Cookbook only** → close this plan; produce a docs cookbook entry showing
      authoring patterns that approximate Decider-shaped ergonomics without the
      facade;
      (c) **Reject** → close this plan; record rationale here and append to the
      MasterPlan's Decision Log.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Frame this plan as **exploratory**, not implementation-bound. The goal is
  the M4 decision (ship / cookbook only / reject), not a particular implementation
  shape.
  Rationale: A facade that turns out to be either unnecessary (v1 ergonomics are
  acceptable) or unworkable (the no-workflow case can't be expressed as a wrapper) is
  a cheaper outcome than committing to ship something that adds maintenance burden
  without clear payoff. The MasterPlan validation pass surfaced the question; this
  plan answers it.
  Date: 2026-05-09.

- Decision: Defer implementation milestones until after M4's go/no-go decision.
  Rationale: Authoring detailed M5+ implementation steps for a facade we may not ship
  is wasted work. M1–M3 are cheap (one example aggregate written twice); M4 is the
  branch point.
  Date: 2026-05-09.


## Outcomes & Retrospective

(To be filled at M4 and again at any post-implementation milestone.)


## Context and Orientation

### What kicked this off

The parent MasterPlan's Surprises & Discoveries entry of 2026-05-09 (the
`SymTransducer`-vs-`Decider` cost-benefit audit) flagged that v1 keiro pays real
ergonomic complexity for workflow features that pure-CQRS users do not exercise. The
five-parameter `EventStream phi rs s ci co`, the `BoolAlg phi (RegFile rs, ci)`
constraint, the `solveOutput`-driven hidden-input check (`docs/research/06-command-cycle-design.md`
§5 invariant), and the `Term`/`OutTerm`/`InCtor` machinery in keiki's `Keiki.Builder`
together form a non-trivial learning curve for an author whose mental model is "decide
returns events, evolve folds events into state".

### What `Keiki.Decider` already provides

Read `keiki/src/Keiki/Decider.hs` for the upstream baseline. It exports:

- `data Decider c e s` with the four classical fields (`decide :: c -> s -> [e]`,
  `evolve :: s -> e -> s`, `initialState :: s`, `isTerminal :: s -> Bool`).
- `toDecider :: SymTransducer phi rs s ci co -> Decider ci co (s, RegFile rs)` —
  projects a transducer to a `Decider` whose state carrier is the joint `(s, RegFile
  rs)`.
- `toMultiDecider` for multi-event commands via internal vertex chains.

The keiki facade has two semantic gaps documented in its haddock:

1. ε-edges are invisible to `decide` (it returns `[]`). `evolve` over the returned list
   does not replay ε-transitions.
2. `omega`'s "at most one event per command" caps `decide`'s return list length at 1
   (single `toDecider`); `toMultiDecider` lifts this for chains.

### Why keiro can't just re-export `Keiki.Decider`

`Keiki.Decider`'s state carrier is `(s, RegFile rs)`. A keiro user importing it as the
authoring shape would still have to declare the slot list `rs` (even if empty: `'[]`)
and would still see the `RegFile` in their `evolve` signature. The proposed facade is
keiro-side because keiro can hide the slot list entirely (defaulting to `'[]`), can
hide `phi` (defaulting to a no-symbolic-feature placeholder), and can lift `decide`'s
return type from `[e]` to `Either AggError [e]` to match the v1 error model (§9 of
`docs/research/06-command-cycle-design.md`).

### Where this plan fits relative to the v1 roadmap

This plan is exploratory and additive. It does not block any other v1 work. The
implementation MasterPlan (yet to be authored as of 2026-05-09) may adopt this plan's
M4 outcome as one of its v1 milestones, or may defer the decision to v1.x. The keiki
EP-36 work (`keiki/docs/plans/36-...`) is contract-orthogonal and proceeds regardless.


## Plan of Work

### M1 — "Before" example: authoring a pure-CQRS aggregate directly against `EventStream`

Pick a small but representative aggregate: an `Order` with three states
(`Pending → Submitted → Delivered`), two commands (`SubmitOrder`, `MarkDelivered`),
three events (`OrderSubmitted`, `OrderDelivered`, `OrderRejected`). The aggregate has
**no register file** (slot list `'[]`), **no ε-edges**, **no symbolic predicates**.

Author it end-to-end as if writing v1 production code. Use the spike at
`spikes/command-cycle/` as the reference for what compiles. Capture:

- The full `EventStream phi rs s ci co` declaration (with explicit type annotations).
- The keiki `SymTransducer` value built via `Keiki.Builder` or hand-rolled GADT.
- The `Codec OrderEvent` (the EP-2 codec interface) with three event constructors.
- The boilerplate count: lines of code, count of `InCtor`/`Term`/`OutTerm` invocations,
  count of explicit type annotations the user must write.
- The compile errors the user sees when they get a type wrong (record three
  representative ones).

Acceptance: a single Haskell file (under `docs/research/cookbook/order-aggregate-direct.hs`
or in a research-only sandbox), commented with the line counts and complaints. Worth
being completely honest about what the user sees today.

### M2 — "After" example: same aggregate against the proposed `Keiro.Decider` facade

Sketch the API of the proposed facade. Author the same `Order` aggregate against it.
The hypothesised API:

    data PureAggregate c e s = PureAggregate
      { paInitialState :: s
      , paIsTerminal   :: s -> Bool
      , paDecide       :: c -> s -> Either AggError [e]
      , paEvolve       :: s -> e -> s
      , paEventCodec   :: Codec e
      , paEventTag     :: e -> Text
      }

    runPureCommand
      :: ( Store :> es, Error CommandError :> es )
      => PureAggregate c e s
      -> Stream a
      -> c
      -> Eff es (Maybe e)

    runPureCommandRetry  :: ... -- mirrors runCommandRetry

Author the `Order` aggregate against this. Capture the same metrics from M1: lines,
annotations, named-error sites, compile-error shapes when the user gets a type wrong.

Acceptance: a parallel Haskell file (`docs/research/cookbook/order-aggregate-facade.hs`)
with the same line-count commentary. The comparison tells the story.

### M3 — Implementability check

Verify `runPureCommand` can be implemented as a thin wrapper over `runCommand` without
changes to `EventStream`, `runCommand`, or keiki. Sketch:

    runPureCommand pa aid cmd = do
      let es = EventStream
            { esTransducer    = liftDeciderToTransducer pa  -- new keiro helper
            , esEventCodec    = paEventCodec pa
            , esStateCodec    = trivialStateCodec           -- new keiro helper
            , esEventTag      = paEventTag pa
            , esSnapshotPolicy = SnapshotPolicyNever
            }
      runCommand es aid cmd

    liftDeciderToTransducer
      :: PureAggregate c e s
      -> SymTransducer NoSym '[] s c e

The load-bearing question: can `liftDeciderToTransducer` be written as a pure function
in keiro, or does it need keiki-side help?

Investigate concretely:

- The `step :: SymTransducer phi rs s ci co -> (s, RegFile rs) -> ci -> Maybe (s, RegFile rs, Maybe co)`
  signature: with `rs ~ '[]`, `RegFile '[]` is `RNil`. Threading `RNil` through is
  trivial. The `paDecide` and `paEvolve` slot in cleanly.
- The hidden-input / `solveOutput` constraint: `paEvolve` does NOT need to satisfy
  this — it's running directly, not via `solveOutput`. **This is the major ergonomic
  win.** Keiro's `liftDeciderToTransducer` implements `applyEvent` by using
  `paEvolve` directly rather than walking the transducer's edges and calling
  `solveOutput`. The constraint disappears for pure-CQRS users.
- The `phi` parameter: pick a `NoSym` placeholder (a singleton type with a trivial
  `BoolAlg` instance over `(RegFile '[], c)` that always answers `True`). Plumbed
  through the `SymTransducer` shape but unused.

If `liftDeciderToTransducer` is a clean pure function with no keiki-side support
needed, M3's verdict is "implementable as a pure keiro wrapper". If it needs keiki to
expose a `liftFromDecider` primitive, document the requirement and decide whether to
route through EP-6's keiki upstream backlog or live with the boilerplate.

Acceptance: a one-page note (`docs/research/cookbook/decider-facade-implementability.md`)
recording the verdict and any keiki-side dependencies.

### M4 — Decision

Take the M1, M2, M3 evidence and decide. Three possible outcomes:

**(a) Ship.** The ergonomic delta from M1 to M2 is large (≥2× line reduction, no
  hidden-input fragility, no `Term`/`OutTerm` machinery), and M3 confirms a clean
  wrapper. Upgrade this plan with M5+ implementation milestones: define `Keiro.Decider`
  module, ship `runPureCommand`/`runPureCommandRetry`, write a cookbook entry, port the
  spike's Counter to use the facade as an end-to-end demonstration.

**(b) Cookbook only.** The ergonomic delta is real but small, OR M3 surfaces a keiki
  dependency we don't want to take. Close this plan; ship a docs cookbook entry that
  shows the M1 example with annotated authoring patterns to minimise boilerplate (e.g.,
  template `phi`/`rs` placeholders, helper functions in user code, copy-paste skeletons).
  The patterns can later become a real facade if a real user pulls on them.

**(c) Reject.** The ergonomic delta is small AND M3 surfaces complications (e.g., the
  facade leaks abstraction; users who start with `Keiro.Decider` and later need a
  register file face a non-trivial migration). Close this plan; record rationale in
  the Decision Log; append a short note to the MasterPlan's Decision Log so the
  decision is durable.

Acceptance: this plan's Decision Log entry of M4 records the verdict with rationale.
The MasterPlan's Decision Log gains a corresponding entry. If outcome (a), M5+ are
authored; if (b), the cookbook entry exists; if (c), no further artifacts.


## Concrete Steps

### M1

1. From `/Users/shinzui/Keikaku/bokuno/keiro`, study the spike at
   `spikes/command-cycle/src/Spike/EventStream.hs`. The Counter aggregate there is
   the closest existing example.

2. Author `docs/research/cookbook/order-aggregate-direct.hs` (or under a
   `research-fixtures/` directory; placement to be decided). Use the spike's nix dev
   shell to compile-check; if not available in the harness PATH, leave the file as
   `.hs` text and note the user must `cabal build` in the spike workspace to verify.

3. Annotate the file with line-count comments and explicit `-- BOILERPLATE:` markers
   on each line of plumbing the user must write.

### M2

1. Sketch the proposed facade module in `docs/research/cookbook/keiro-decider-sketch.hs`
   as a Haskell text file (no compile yet). Define `PureAggregate c e s`,
   `runPureCommand`, `runPureCommandRetry`.

2. Author `docs/research/cookbook/order-aggregate-facade.hs` against the sketch. Same
   annotation discipline.

3. Compare the two files side-by-side in
   `docs/research/cookbook/comparison-notes.md`.

### M3

1. In a fresh sandbox under the spike workspace (or as a new Haskell module in the
   spike's `src/Spike/`), implement `liftDeciderToTransducer` and one
   `runPureCommand` call site that exercises the Counter. Verify it compiles.

2. If it does NOT compile due to a keiki-side gap, document the gap concretely.
   Decide whether to route through EP-6's upstream backlog or accept the gap as a
   facade limitation.

3. Commit the implementability note.

### M4

1. Read M1, M2, M3 outputs.

2. Make the decision. Update this plan's Decision Log. Update the MasterPlan's
   Decision Log.

3. If outcome (a), author M5+ milestones in this plan.


## Validation and Acceptance

**Plan-level acceptance.** This plan is complete when M4's decision is recorded with
rationale, and any artifact required by the chosen outcome (M5+ milestones, cookbook
entry, or rejection note) exists.

**Outcome-(a)-specific acceptance.** If shipping the facade: a keiro user can author a
3-state aggregate in ≤30 lines of straightforward `decide`/`evolve`-shaped code, no
`Term`/`OutTerm`/`InCtor` invocations, no explicit `BoolAlg` constraints, and have it
participate in keiro's `runCommand` cycle (verified by an end-to-end test against a
real Postgres).


## Idempotence and Recovery

Steps M1–M3 produce documentation artifacts only; reversible by deletion. M4's
decision is durable in two Decision Logs (this plan + MasterPlan); reversal would
require explicit follow-up entries.

Outcome (a)'s implementation milestones (M5+) would be additive to keiro's API; no
existing code changes. Rolling back would mean deprecating `Keiro.Decider`'s exports
and migrating any v1 users — same shape as any API deprecation.


## Interfaces and Dependencies

This is an exploratory plan; no interface commitments at M1–M4. Outcome-(a)-specific
interfaces would be authored in M5+.

The plan does not introduce new keiki dependencies. M3's implementability check
deliberately scopes to "purely a keiro-side wrapper".


## References

- This ExecPlan: `docs/plans/7-internal-decider-style-ergonomic-facade-over-runcommand.md`
- Driving validation pass: `docs/masterplans/1-keiro-research-foundation.md` Surprises
  & Discoveries entry of 2026-05-09.
- Cost-benefit ledger: `docs/research/06-command-cycle-design.md` §2 sub-section
  "Cost-benefit ledger".
- Open question on keiki's z3 commitment: `docs/research/11-upstream-roadmap.md` §10.4.
- keiki upstream baseline: `keiki/src/Keiki/Decider.hs` (the existing facade).
- Reference aggregate: `spikes/command-cycle/src/Spike/EventStream.hs` (the spike's
  Counter).
- Hidden-input constraint: `docs/research/06-command-cycle-design.md` §5 invariant
  (the constraint a Decider-style facade can side-step for pure-CQRS users).
- EP-36 (keiki): `/Users/shinzui/Keikaku/bokuno/keiki/docs/plans/36-regfile-json-codec-and-shape-hash-for-snapshot-persistence.md`
  — contract-orthogonal; proceeds independently of this plan's outcome.


## Revisions

- 2026-05-13: **Renamed the typed event-stream-id wrapper `AggregateId a` → `Stream a`** in this plan body, cascaded from the parent MasterPlan's 2026-05-13 rename decision. **Updates this revision applied (this plan only)**: line 56 (the §"Purpose / Big Picture" sketch of the proposed `runPureCommand` signature) and line 216 (the M2 design-target full signature). The plan-internal type `PureAggregate c e s` is *not* renamed because it is a *deliberate* DDD-flavoured ergonomic facade — the entire point of this plan is to give pure-CQRS aggregate authors a Decider/Aggregate-shaped API; "Aggregate" in `PureAggregate` is the *thing being modelled*, not the framework type. Same for the `paDecide`/`paEvolve`/`paEventCodec`/`paEventTag`/`AggError` field/error names: they are local to the facade and intentionally evoke the DDD vocabulary the facade caters to. The general-purpose framework type that this facade reduces to (`EventStream phi rs s ci co`) and the framework's typed-id wrapper (`Stream a`) carry the keiro-general framing; the facade's local names carry the DDD framing it adapts to. **Streamly-collision note**: the parent MasterPlan's 2026-05-13 Decision Log entry records that an intermediate `StreamRef a` selection was discarded after team feedback in favour of the bare `Stream a`, accepting the name collision with `Streamly.Data.Stream.Stream` and resolving it at use sites with qualified imports — when the implementation MasterPlan ships EP-7's facade module, it should follow the same convention (`import qualified Streamly.Data.Stream as Stream` only if the facade module also consumes Streamly streams; the facade itself does not, so a plain unqualified `Stream` import from keiro is sufficient at the facade boundary). The parent MasterPlan's 2026-05-13 Decision Log + Revisions entries record the cross-plan cascade. EP-7 status is unchanged by this rename pass; only the type name carried in the proposed signatures is refreshed. Reason: cascade from the MasterPlan rename; the user observed that `AggregateId` is too tied to DDD and keiro is a more general framework — but the facade's local DDD-flavoured names are the facade's whole purpose and stay.
