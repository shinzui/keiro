---
id: 54
slug: validateeventstream-and-mkeventstream-validate-keiki-transducers-at-the-eventstream-boundary
title: "validateEventStream and mkEventStream: validate keiki transducers at the EventStream boundary"
kind: exec-plan
created_at: 2026-06-06T15:00:00Z
intention: "intention_01ktensqv9ecmv5cd5jrbcfej7"
---

# validateEventStream and mkEventStream: validate keiki transducers at the EventStream boundary

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

keiro runs event-sourced aggregates by pairing a pure keiki state machine (a
`SymTransducer`) with the durable plumbing needed to replay it against an event store. That
pairing is the `EventStream` record (defined in `keiro-core/src/Keiro/EventStream.hs`). Today
an `EventStream` is built with a bare record literal: any transducer at all can be dropped into
the `transducer` field, and nothing checks that the transducer is *replay-safe* until a real
hydration fails in production.

"Replay-safe" has a precise meaning in keiki. keiki never lets you hand-write the event→state
fold; it *derives* it by inverting each edge's emitted event back into the command that produced
it (`solveOutput`). For that to work, every command field an edge consumes must be recoverable
from the emitted event(s). keiki ships pure, no-solver build-time checks that flag edges that
violate this. The umbrella entry point is `validateTransducer` (delivered by keiki MasterPlan 14,
child plan EP-56), which runs the hidden-input check **plus** non-determinism (overlapping guards)
and dead-edge (unreachable edges) analyses; the narrower `checkHiddenInputs` and the structured
`hiddenInputWarnings` cover the hidden-input case alone. The trouble is that calling these is a
downstream *convention*: each service has to remember to test each transducer. The Seihou consumer
audit (`../keiro-runtime-jitsurei/docs/keiki-dsl-feature-requirements.md`, Requirement 8) hit
exactly this — a Hospital event once omitted two command fields its edge guard read, and the gap
was discovered only when replay failed during hydration.

> Revision note (2026-06-06, validation pass): this plan was originally drafted assuming
> `validateTransducer` was unlanded future work and that M1/M2 had to be built on the narrower
> `checkHiddenInputs`. A cross-repo check found that keiki EP-56 **shipped the same day** — 
> `validateTransducer`, `ValidationOptions`/`defaultValidationOptions`, and the structured
> `TransducerValidationWarning s` are all exported from `Keiki.Core` in the keiki version keiro
> already depends on. The plan below has been rewritten to build directly on `validateTransducer`
> (the former M3 is folded into M1/M2), and three keiro-side inaccuracies in the original draft
> have been corrected. See the Decision Log and the revision note at the bottom for details.

After this change, a keiro user can:

- Call `validateEventStream "hospital-reservation" reservationEventStream` and get back a list of
  warnings (empty when the stream is replay-safe), each tagged with a caller-supplied label so a
  multi-aggregate service can tell *which* stream is broken. An application test can then assert
  every event stream in the service validates clean with a single `concatMap`-style assertion.
- Build a stream through the smart constructor `mkEventStream`, which returns
  `Left [warnings]` for an unsafe stream and `Right eventStream` for a safe one — turning a
  latent runtime hydration failure into a fail-fast at construction. The bare record literal
  stays available for low-level callers who do not want the check.

You can see it working by writing a deliberately-broken transducer (an edge whose guard reads a
command field that is never emitted), wrapping it in an `EventStream`, and watching
`validateEventStream` report the offending stream by label and `mkEventStream` reject it — and
by confirming every real keiro/jitsurei stream validates clean.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here, even
if it requires splitting a partially completed task into two ("done" vs. "remaining"). This
section must always reflect the actual current state of the work.

- [x] M-1 (newly discovered prerequisite, 2026-06-06): bump the pinned `keiki` commit in
      `cabal.project` from `869253a` (predates EP-56, exports only `checkHiddenInputs`) to
      `344c4ca` (keiki master HEAD, ships `validateTransducer` et al.). The plan's premise that
      EP-56 was already in the depended-on keiki was wrong — it validated against the local
      `../keiki` working copy, not the `cabal.project` pin. Also fixed three shibuya `Envelope`
      construction sites (new required `headers` field in shibuya-core 0.7.0.0) so the tree builds.
- [x] M0 (prerequisite, 2026-06-06): added `Enum, Bounded, Ord` to `CounterState`
      (`keiro/test/Main.hs`), the only control-state type a validated keiro-test stream uses, so it
      satisfies `(Bounded s, Enum s, Ord s, Show s)`. `OrderState` is jitsurei-side and not pulled
      into the keiro-test assertion, so it was left unchanged.
- [x] M1 (2026-06-06): `validateEventStream` (+ `validateEventStreamWith`) and `EventStreamWarning`
      in the new `Keiro.EventStream.Validate` module (keiro-core), backed by keiki's
      `validateTransducer` (`defaultValidationOptions`). Re-exported from the `keiro` package.
- [x] M1 (2026-06-06): application test asserting keiro-test's production-intent EventStreams
      validate clean via one suite-local assertion over `counterEventStream` and
      `snapshotCounterEventStream`. Degenerate fixtures excluded as planned. Passes (3 examples,
      0 failures).
- [x] M2 (2026-06-06): `mkEventStream` smart constructor returning
      `Either [EventStreamWarning] (EventStream …)`; record-literal construction left intact.
- [x] M2 (2026-06-06): negative test — `brokenHiddenInputEventStream` (an ε-edge whose update
      reads `amount` but emits nothing) is rejected by `mkEventStream` and reported by
      `validateEventStream` with label `"broken"`; a good stream returns `Right`. Passes.
- [x] Changelog (2026-06-06): added an `### Added` (and `### Changed` for the keiki pin bump) entry
      under `## [Unreleased]` in `keiro/CHANGELOG.md` announcing `Keiro.EventStream.Validate` and the
      keiki bump.
- [ ] M3 (optional follow-up): cross-check that the transducer's emitted event-type tags are
      covered by the `Codec`'s `eventTypes`. **Blocked on keiki**: there is currently no exported
      keiki function that enumerates the event tags a `SymTransducer` can emit (confirmed by audit
      of `Keiki.Core` exports), so this stays a recorded follow-up, not in-scope work.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- keiro-core already declares `keiki >=0.1` as a dependency (`keiro-core/keiro-core.cabal` line
  55) and `Keiro.Command` already imports `Keiki.Core` and calls `Keiki.applyEventStreaming` for
  replay (`keiro/src/Keiro/Command.hs` lines 51–52, 252–257). So importing keiki's analysis
  functions adds no new package dependency.
- **EP-56 already shipped (validation pass, 2026-06-06).** The original draft treated
  `validateTransducer` as unlanded future work gated on keiki MasterPlan 14 / EP-56. In fact
  EP-56 is **complete** in the keiki version keiro depends on (keiki `0.1.0.0`). `Keiki.Core`
  exports `validateTransducer`, `ValidationOptions (..)`, `defaultValidationOptions`,
  `TransducerValidationWarning (..)`, `EdgeRef (..)`, and `hiddenInputWarnings` (verified in the
  keiki repo `../keiki/src/Keiki/Core.hs` export list, lines 133/150–154). This removes the
  cross-repo gate entirely, so the plan builds directly on the richer umbrella.
- **The shipped `validateTransducer` signature is tighter than the original guess.** Actual:
  `validateTransducer :: (Bounded s, Enum s, Ord s, Show s) => ValidationOptions -> SymTransducer
  (HsPred rs ci) rs s ci co -> [TransducerValidationWarning s]` (`../keiki/src/Keiki/Core.hs`
  ~1699). Two consequences for keiro: (a) it adds an **`Ord s`** constraint (for structural
  reachability via `Data.Set`); (b) it pins **`phi ~ HsPred rs ci`** rather than an arbitrary
  guard alphabet. Both real keiro transducers use `HsPred` (`orderTransducer ::
  SymTransducer (HsPred OrderRegs OrderCommand) …`, `counterTransducer ::
  SymTransducer (HsPred '[] CounterCommand) …`), so the `phi` pin is satisfiable.
- **`Ord s` is NOT already satisfied — the original "already derives Bounded/Enum/Show" claim was
  wrong about `Ord`.** `OrderState` derives `Generic, Eq, Show, Enum, Bounded` but **not `Ord`**
  (`jitsurei/src/Jitsurei/Domain.hs` line 146); `CounterState` derives only `Generic, Eq, Show`
  (`keiro/test/Main.hs` line 4286) — it lacks `Ord`, `Enum`, and `Bounded`. So M0 must add the
  missing instances to any control-state type a validated stream uses. (Fallback if adding `Ord`
  is undesirable for some type: `hiddenInputWarnings :: (Bounded s, Enum s) => SymTransducer phi
  rs s ci co -> [TransducerValidationWarning s]` runs only the hidden-input check, keeps arbitrary
  `phi`, and needs neither `Ord` nor `Show`.)
- **`TransducerValidationWarning s` is parameterized over `s` and has four constructors**, not the
  flat `hiwEdgeSource`/`hiwReason` record the original draft assumed:
  `HiddenInput { tvwEdge :: EdgeRef s, tvwInCtor, tvwMissingSlots, tvwDetail }`,
  `NondeterministicPair { tvwSource :: s, tvwEdgeA, tvwEdgeB, tvwInCtor, tvwDetail }`,
  `PossiblyDeadEdge { tvwEdge :: EdgeRef s, tvwDetail }`, and
  `OpaqueGuard { tvwEdge :: EdgeRef s, tvwDetail }` (`../keiki/src/Keiki/Core.hs` ~1608–1654).
  `EdgeRef s = EdgeRef { edgeSource :: s, edgeIndex :: Int }` (~971). Each carries a
  human-readable `tvwDetail :: String`; the source vertex is `edgeSource (tvwEdge w)` (or
  `tvwSource` for the nondeterministic pair). Rendering `eswReason` must pattern-match the four
  constructors (needs `Show s`).
- **`ValidationOptions` has four fields, with a `defaultValidationOptions`.** Fields:
  `failOnEpsilonReadsInput`, `checkDeterminism`, `checkReachability` (all default `True`) and
  `warnOpaqueGuards` (default `False`). `defaultValidationOptions` enables hidden-input +
  determinism + reachability. Because `validateTransducer` now also runs determinism and
  dead-edge checks, the "validates clean" assertion is *stricter* than a hidden-input-only check
  — a real stream that happens to trip a conservative `PossiblyDeadEdge` or a `NondeterministicPair`
  warning would surface here. The remedy is a `validateEventStreamWith :: ValidationOptions -> …`
  variant so a stream with a benign warning can be validated under narrowed options (or its
  expected warnings asserted explicitly).
- **The keiro-test suite builds transducers as bare `SymTransducer` record literals, not via
  `Keiki.Builder`.** `counterTransducer` (`keiro/test/Main.hs` ~4305) is a hand-written
  `SymTransducer { edgesOut = …, initial = …, initialRegs = …, isFinal = … }` using `Edge`,
  `matchInCtor`, `UKeep`, `pack`, `inpCtor`; `Keiki.Builder` is **not imported** in the test file.
  The M2 negative transducer should follow this existing record-literal style (jitsurei's
  `orderTransducer`, by contrast, *does* use `Keiki.Builder` as `B.buildTransducer`).
- **`keiro-test` does not depend on `jitsurei`.** The `keiro-test` test-suite build-depends
  (`keiro/keiro.cabal` ~124–149) lists `keiki` and `keiro` but **not** `jitsurei`, so the M1
  assertion cannot reference `orderEventStream` without first adding that dependency. Per the
  validation-pass decision, M1 is scoped to keiro-test's own streams instead.
- No exported keiki function enumerates the event-type tags a `SymTransducer` can emit, so the M3
  codec-coverage cross-check cannot be implemented cheaply today; it stays a recorded follow-up.
- **The plan's central premise was wrong: EP-56 was NOT in the depended-on keiki (implementation
  pass, 2026-06-06).** The validation pass concluded EP-56 had shipped by inspecting the local
  `../keiki` working copy (at master HEAD `344c4ca`). But keiro does not depend on that working
  copy — it pins keiki via `cabal.project` `source-repository-package tag:
  869253ab49e2380bcc4556d6d6332913ff0ef52c`, which **predates** EP-56. The first build failed with
  `Module 'Keiki.Core' does not export 'validateTransducer'` (only `checkHiddenInputs` /
  `HiddenInputWarning` exist at that pin). `validateTransducer` actually landed in keiki `0f44e80`
  (`feat(core): add validateTransducer … (EP-56)`), which is a descendant of the pinned commit.
  Resolution (user-chosen): bump the pin to `344c4ca` (keiki master HEAD on the remote, contains
  EP-56) for both keiki `source-repository-package` stanzas in `cabal.project`. After the bump
  `cabal build all` and the validation tests are green. Lesson: verify a cross-repo dependency
  claim against the *pin in `cabal.project`*, not a local sibling checkout.
- **The keiki bump cascaded a full reconfigure that surfaced a pre-existing shibuya drift.**
  shibuya-core `0.7.0.0` (resolved from the local hackage-style repo, not pinned in `cabal.project`)
  added a required strict field `headers :: Maybe Headers` to `Envelope`. Three `Envelope` record
  literals in the keiro tree had not been updated for it: `jitsurei/app/Main.hs:565`
  (`processManagerAdapter`) and `keiro/test/Main.hs` `routerTestEnvelope` (and the demo's). This is
  *not* caused by the keiki change — the keiki bump just forced a recompile that revealed it. Fixed
  by adding `headers = Nothing` (adapter does not surface headers) to each literal. Router/
  ProcessManager only pattern-match `Envelope{payload = …}` (partial patterns), so they needed no
  change.
- **`validateTransducer defaultValidationOptions` passes both real keiro-test streams as-is.**
  `counterEventStream` (single self-loop edge, `UKeep`, emits `amount`) and
  `snapshotCounterEventStream` (single edge, `USet lastAmount amount`, emits `amount`) trip no
  hidden-input, determinism, or dead-edge warning — no `validateEventStreamWith` narrowing was
  needed. The benign-warning escape hatch is exported but unused so far.


## Decision Log

Record every decision made while working on the plan.

- Decision (SUPERSEDED 2026-06-06): Ship M1/M2 against keiki's existing `checkHiddenInputs`, and
  treat the upgrade to keiki's richer `validateTransducer` (keiki MasterPlan 14, EP-56) as a
  later, non-blocking milestone (M3).
  Rationale at the time: `checkHiddenInputs` was the only validation export believed available;
  `validateTransducer` was believed unlanded.
  Superseded because: the validation pass found EP-56 already shipped (see next decision).

- Decision: Build directly on keiki's `validateTransducer` (`defaultValidationOptions`) from the
  start; fold the former M3 into M1/M2; drop the `checkHiddenInputs` intermediate step.
  Rationale: EP-56 is complete in the keiki version keiro depends on (`Keiki.Core` exports
  `validateTransducer`, `ValidationOptions`, `defaultValidationOptions`,
  `TransducerValidationWarning`). There is no longer a cross-repo gate, so there is no reason to
  ship the narrower check first and upgrade later — building on the umbrella once is less total
  churn and immediately gives Req 8 the hidden-input check plus determinism and dead-edge
  coverage. (The user chose this option explicitly during the validation pass.)
  Date: 2026-06-06

- Decision: Add an `Ord` instance (and `Enum`/`Bounded` where missing) to each control-state type
  a validated stream uses, as prerequisite M0.
  Rationale: `validateTransducer` requires `(Bounded s, Enum s, Ord s, Show s)`. The codebase does
  not yet satisfy `Ord s` anywhere (`OrderState` lacks `Ord`; `CounterState` lacks `Ord`, `Enum`,
  `Bounded`). These are cheap `deriving stock` additions on simple sum types and impose nothing
  semantically. Where adding `Ord` to a given type is undesirable, `hiddenInputWarnings` (only
  `Bounded`+`Enum`, arbitrary `phi`) is the documented fallback for the replay-safety check alone.
  Date: 2026-06-06

- Decision: Record the new validation surface in `keiro/CHANGELOG.md` under `## [Unreleased]` when
  M1/M2 merge (not before), in the same commit that lands the feature.
  Rationale: the repo already keeps a Keep-a-Changelog file for the `keiro` library, and the user
  wants the work reflected once implemented so keiro consumers know what changed and what to
  update. Writing the entry only at merge time keeps the changelog truthful (no entry for an
  unmerged feature). An `## [Unreleased]` section was added to anchor this.
  Date: 2026-06-06

- Decision: Provide both `validateEventStream` (using `defaultValidationOptions`) and
  `validateEventStreamWith :: ValidationOptions -> …`.
  Rationale: because `validateTransducer` now also runs the conservative determinism and
  dead-edge checks, the "validates clean" bar is stricter than hidden-input-only. A stream with a
  benign `PossiblyDeadEdge`/`NondeterministicPair` warning needs an escape hatch (narrowed
  options) without abandoning the default-strict path for everyone else.
  Date: 2026-06-06

- Decision: Identify streams by a caller-supplied `Text` label, not by `resolveStreamName`.
  Rationale: `resolveStreamName :: Stream (EventStream …) -> StreamName` needs a `Stream` handle
  to produce a name, which a pure validation pass does not have. A caller-supplied label
  ("hospital-reservation", "incident-root") is simple, satisfies Req 8's "warnings mention a
  caller-supplied stream label so multi-aggregate services can identify the failing aggregate",
  and keeps validation pure.
  Date: 2026-06-06

- Decision: Keep the bare `EventStream { … }` record literal available; add `mkEventStream` as an
  opt-in smart constructor rather than hiding the constructor.
  Rationale: Req 8 explicitly wants "existing record-literal construction can remain available
  for low-level users." Hiding the constructor would break existing call sites in jitsurei and
  the keiro test suite.
  Date: 2026-06-06

- Decision: Put `validateEventStream`/`mkEventStream` in keiro-core (where `EventStream` lives),
  in a new module `Keiro.EventStream.Validate`, and put tests in the existing `keiro-test`
  suite (hspec).
  Rationale: the new functions operate on the keiro-core type; keiro-core has no test stanza, and
  `keiro-test` already aggregates hspec specs and has access to real EventStreams. Adding a
  test-suite to keiro-core just for this would be heavier than reusing keiro-test.
  Date: 2026-06-06

- Decision: Scope the M1 "every stream validates clean" assertion to the streams `keiro-test`
  already constructs (`counterEventStream`, `snapshotCounterEventStream`), adding new streams to
  the suite where richer cases are worth exercising, and exclude the suite's deliberately-broken
  fixtures. Do **not** pull jitsurei's `orderEventStream` into the keiro-test assertion.
  Rationale: `keiro-test` does not depend on the `jitsurei` package, and the user chose to keep it
  that way rather than add a test dependency. jitsurei's own streams should be validated in a
  jitsurei-side test if/when desired. The suite also contains intentionally degenerate transducers
  (`noOpCounterTransducer`, `multiCounterTransducer`, `guardedSnapshotCounterTransducer`) that may
  legitimately produce warnings; a blanket "all validate clean" assertion over the whole suite
  would give false failures, so the assertion covers only production-intent streams (and any new
  ones added on purpose) and the degenerate fixtures get explicit expected-warning assertions if
  exercised at all.
  Date: 2026-06-06


- Decision (implementation pass): Bump the pinned `keiki` commit in `cabal.project` from `869253a`
  to `344c4ca` (both keiki stanzas) rather than fall back to `checkHiddenInputs`.
  Rationale: the pinned keiki predated EP-56, so the plan's `validateTransducer` did not exist at
  the pin. Presented the user with bump-vs-fallback; the user chose to bump to keiki master HEAD
  (which ships EP-56 and is already on the remote, so cabal can fetch it). The bump rebuilt the
  whole tree green (after the shibuya `Envelope.headers` fix below). This realigns reality with the
  validation-pass decision to build on `validateTransducer`.
  Date: 2026-06-06

- Decision (implementation pass): Re-export `Keiro.EventStream.Validate` from the `keiro` package
  (`reexported-modules`), not only from keiro-core.
  Rationale: the keiro-test suite build-depends on `keiro`, not `keiro-core` directly, and imports
  the validation API through `keiro`. Adding the re-export keeps the public surface consistent with
  the sibling `Keiro.EventStream` / `Keiro.Codec` re-exports and avoids adding a `keiro-core`
  test dependency.
  Date: 2026-06-06

- Decision (implementation pass): Fix the shibuya `Envelope` construction sites with
  `headers = Nothing` in the same body of work (user-requested mid-implementation).
  Rationale: shibuya-core 0.7.0.0 made `headers` a required strict field; the keiro tree had stale
  literals that blocked `cabal build all`. `Nothing` is the correct value (these adapters/test
  fixtures do not surface broker headers). Without this the tree would not build, so it is a
  prerequisite for the validation tests to run.
  Date: 2026-06-06

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare the
result against the original purpose.

M0–M2 are complete and green (2026-06-06). A keiro user can now call
`validateEventStream "<label>" stream` to get labelled replay-safety + determinism + dead-edge
warnings, and `mkEventStream "<label>" stream` to fail fast (`Left`) on an unsafe stream — exactly
the Req 8 behaviour. The new `Keiro.EventStream.Validate` module lives in keiro-core and is
re-exported from `keiro`; the bare `EventStream` record literal is untouched at every existing call
site. Tests: `every production-intent stream validates clean`, `rejects a hidden-input stream by
label`, `accepts a replay-safe stream` — 3 examples, 0 failures.

Gap vs. original purpose: the purpose is fully met for `HsPred`-guarded streams. M3 (codec-tag
coverage) remains a recorded follow-up blocked on a missing keiki emitted-tag enumerator.

Biggest lesson: the plan's validation pass verified EP-56 against the wrong artifact — a local
`../keiki` checkout instead of the `cabal.project` pin — and confidently rewrote the plan on that
false premise. The pin actually predated EP-56, so the build failed immediately. Cross-repo
"already shipped" claims must be checked against the dependency pin the build uses. The fix (bump
the pin) was clean, but it also forced a full reconfigure that exposed an unrelated, pre-existing
shibuya `Envelope.headers` drift that had to be repaired to get a green tree.


## Context and Orientation

This plan touches the keiro repository at `/Users/shinzui/Keikaku/bokuno/keiro`. The relevant
pieces, for a reader who knows nothing about keiro:

`EventStream` is keiro's description of one persistent event stream. It is defined in
`keiro-core/src/Keiro/EventStream.hs` (lines 48–56):

```haskell
data EventStream phi rs s ci co = EventStream
    { transducer :: !(SymTransducer phi rs s ci co)
    , initialState :: !s
    , initialRegisters :: !(RegFile rs)
    , eventCodec :: !(Codec co)
    , resolveStreamName :: !(Stream (EventStream phi rs s ci co) -> StreamName)
    , snapshotPolicy :: !(SnapshotPolicy (s, RegFile rs))
    , stateCodec :: !(Maybe (StateCodec (s, RegFile rs)))
    }
    deriving stock (Generic)
```

The type parameters thread through from the underlying keiki transducer: `phi` is the guard
alphabet, `rs` the register set, `s` the control state, `ci` the command input, `co` the event
output. The `transducer` field is the pure keiki `SymTransducer phi rs s ci co` (imported from
`Keiki.Core`).

`SymTransducer` is keiki's symbolic-register finite-state transducer — the pure decision logic
of an aggregate. The thing we want to validate lives entirely inside it. keiki ships a pure,
no-solver umbrella build-time check, `validateTransducer`, exported from `Keiki.Core` (keiki repo
`../keiki/src/Keiki/Core.hs` ~1699). Its **actual, shipped** signature is:

```haskell
validateTransducer
  :: (Bounded s, Enum s, Ord s, Show s)
  => ValidationOptions
  -> SymTransducer (HsPred rs ci) rs s ci co
  -> [TransducerValidationWarning s]
```

Note two things relative to a naive guess: it requires **`Ord s`** (used for structural
reachability via `Data.Set`), and it pins the guard alphabet to **`HsPred rs ci`** rather than an
arbitrary `phi`. Every real keiro transducer already uses `HsPred` (`orderTransducer`,
`counterTransducer`), so the pin is satisfiable; the `Ord s` requirement drives prerequisite M0.

`ValidationOptions` selects which checks run (`../keiki/src/Keiki/Core.hs` ~1659):

```haskell
data ValidationOptions = ValidationOptions
  { failOnEpsilonReadsInput :: Bool  -- hidden-input / replay-safety check
  , checkDeterminism        :: Bool  -- overlapping-guard (single-valuedness) check
  , checkReachability       :: Bool  -- dead-edge / unreachable-edge check
  , warnOpaqueGuards        :: Bool  -- opt-in audit of opaque TApp guards
  }

defaultValidationOptions :: ValidationOptions  -- first three True, warnOpaqueGuards False
```

The warning type is parameterized over the vertex type `s` and has four constructors
(`../keiki/src/Keiki/Core.hs` ~1608):

```haskell
data TransducerValidationWarning s
  = HiddenInput        { tvwEdge :: EdgeRef s, tvwInCtor :: Maybe String
                       , tvwMissingSlots :: [String], tvwDetail :: String }
  | NondeterministicPair { tvwSource :: s, tvwEdgeA :: Int, tvwEdgeB :: Int
                         , tvwInCtor :: Maybe String, tvwDetail :: String }
  | PossiblyDeadEdge   { tvwEdge :: EdgeRef s, tvwDetail :: String }
  | OpaqueGuard        { tvwEdge :: EdgeRef s, tvwDetail :: String }

data EdgeRef s = EdgeRef { edgeSource :: s, edgeIndex :: Int }
```

A `HiddenInput` warning is raised when an edge cannot be inverted on replay — for example an
ε-edge (an edge that emits no event) whose update reads the command, or a multi-event edge whose
emitted events together fail to carry every command field the edge consumes. An empty result list
means the transducer passed every enabled check. The checks are pure and need no SMT solver
(solver-backed variants live in `Keiki.Symbolic`), so they are cheap enough to run in a unit test.
Every constructor carries a human-readable `tvwDetail :: String`; the offending source vertex is
`edgeSource (tvwEdge w)` (or `tvwSource` for `NondeterministicPair`). Rendering a warning to text
therefore pattern-matches the four constructors and needs `Show s`.

For the narrower replay-safety-only case, `Keiki.Core` also exports
`hiddenInputWarnings :: (Bounded s, Enum s) => SymTransducer phi rs s ci co ->
[TransducerValidationWarning s]` — the same structured warning type, but only the hidden-input
check, keeping arbitrary `phi` and requiring neither `Ord s` nor `Show s`. It is the fallback if
adding `Ord` to a particular control-state type is undesirable. (The legacy
`checkHiddenInputs :: (Bounded s, Enum s, Show s) => … -> [HiddenInputWarning]` with the flat
`hiwEdgeSource`/`hiwReason` record still exists but is superseded by the structured forms.)

This plan builds on `validateTransducer defaultValidationOptions`. Because that enables the
determinism and dead-edge checks as well, the "validates clean" bar is stricter than
hidden-input-only: a stream that trips a conservative `PossiblyDeadEdge` or a real
`NondeterministicPair` will surface here. The `validateEventStreamWith` variant (below) lets a
caller narrow `ValidationOptions` for a stream with a known-benign warning.

`Codec` is keiro's event serializer (`keiro-core/src/Keiro/Codec.hs` ~77–85). Its
`eventTypes :: NonEmpty Text` field is the complete set of event-type tags the codec owns; it is
relevant only to the optional M3 stretch (checking that the transducer cannot emit an event the
codec does not know).

keiro already constructs `EventStream`s as bare record literals — for example
`jitsurei/src/Jitsurei/OrderStream.hs` lines 41–51 (`orderEventStream`) and several in
`keiro/test/Main.hs` (`counterEventStream` ~4289, `snapshotCounterEventStream` ~4363, plus an
anonymous literal in the "Keiro.EventStream" describe block ~365, and lens-derived variants such
as `noOpCounterEventStream`, `multiCounterEventStream`, `multiSnapshotCounterEventStream`,
`guardedSnapshotCounterEventStream`). The latter four wrap deliberately-degenerate transducers and
are *not* safe to include in a blanket "validates clean" assertion. There is no smart constructor
today, and nothing in keiro currently imports or wraps any keiki validation function (verified by
repo-wide grep — no matches for `checkHiddenInputs`, `hiddenInputWarnings`, or
`validateTransducer` outside this plan).

The test transducers are built as **bare `SymTransducer` record literals**, not via
`Keiki.Builder` — `counterTransducer` (`keiro/test/Main.hs` ~4305) is
`SymTransducer { edgesOut = …, initial = …, initialRegs = …, isFinal = … }`. The M2 negative
transducer follows that same style. (jitsurei's `orderTransducer` does use `Keiki.Builder` as
`B.buildTransducer`, but that module is not imported by the keiro-test suite.)

keiro-core depends on keiki already (`keiro-core/keiro-core.cabal` build-depends `keiki >=0.1`,
line 55), and `keiro` itself also depends on `keiki >=0.1` (`keiro/keiro.cabal` line 107). Tests
run under hspec in the `keiro-test` suite (`keiro/keiro.cabal` test-suite `keiro-test`,
`main-is: Main.hs`, `hspec >=2.11`); the suite is a single manually-aggregated
`keiro/test/Main.hs`. Its build-depends includes `keiki` and `keiro` but **not** `jitsurei`, so
M1's assertion is scoped to keiro-test's own streams (see Decision Log).

Term definitions used in this plan: a *transducer* is the pure keiki state machine; *replay* /
*hydration* is reconstructing an aggregate's current state by folding its stored events through
the transducer; a *hidden input* is a command field an edge consumes but does not emit, so it
cannot be recovered on replay; a *smart constructor* is a function that builds a value only if it
passes validation, returning `Either` to report failure.


## Plan of Work

The work is one prerequisite plus two milestones. M0 adds the `Ord` instances `validateTransducer`
requires. M1 and M2 deliver the full Req 8 behavior against keiki's `validateTransducer`. M3 is an
optional follow-up (codec coverage) that is currently blocked on a missing keiki API.

### Milestone M0 — satisfy `Ord s` (prerequisite)

Scope: `validateTransducer` requires `(Bounded s, Enum s, Ord s, Show s)`, and no control-state
type in keiro/jitsurei derives `Ord` today. Add the missing instances to every control-state type
a validated stream uses.

For the keiro-test streams in scope:

```haskell
-- keiro/test/Main.hs ~4284: today `deriving stock (Generic, Eq, Show)`
data CounterState
  = Counting
  deriving stock (Generic, Eq, Show, Enum, Bounded, Ord)  -- add Enum, Bounded, Ord
  deriving anyclass (FromJSON, ToJSON)
```

`OrderState` (`jitsurei/src/Jitsurei/Domain.hs` ~146) already derives `Enum, Bounded`; if a
jitsurei-side validation test is added later, append `Ord` there too. These are `deriving stock`
additions on simple finite sum types — they impose nothing semantically and cannot fail to derive.

Acceptance: `cabal build keiro` / `cabal build jitsurei` still green after the deriving change.

### Milestone M1 — `validateEventStream` (pure validation pass)

Scope: a new module `keiro-core/src/Keiro/EventStream/Validate.hs` exporting an
`EventStreamWarning` type and pure `validateEventStream` / `validateEventStreamWith`. At the end, a
keiro user can run the check on any `HsPred`-guarded `EventStream` and a suite-local test asserts
the production-intent streams validate clean.

Create the module with these definitions (uses plain record selectors here for a dependency-light
example; the `generic-lens` `es ^. #transducer` idiom keiro uses elsewhere is equivalent):

```haskell
module Keiro.EventStream.Validate
  ( EventStreamWarning (..)
  , validateEventStream
  , validateEventStreamWith
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import Keiki.Core
  ( EdgeRef (..)
  , HsPred
  , TransducerValidationWarning (..)
  , ValidationOptions
  , defaultValidationOptions
  , validateTransducer
  )
import Keiro.EventStream (EventStream (..))

-- | A validation warning about one event stream, tagged with the
-- caller-supplied label so a multi-aggregate service can tell which
-- stream is at fault.
data EventStreamWarning = EventStreamWarning
  { eswStreamLabel :: !Text
  , eswReason      :: !Text   -- rendered from the keiki warning
  } deriving stock (Eq, Show)

-- | Run keiki's pure umbrella check (hidden-input + determinism +
-- dead-edge) over a stream's transducer with the default options. An
-- empty list means the stream passed every enabled check. Pure; no solver.
validateEventStream
  :: (Bounded s, Enum s, Ord s, Show s)
  => Text                                  -- ^ caller-supplied stream label
  -> EventStream (HsPred rs ci) rs s ci co
  -> [EventStreamWarning]
validateEventStream = validateEventStreamWith defaultValidationOptions

-- | As 'validateEventStream', but with caller-chosen 'ValidationOptions'
-- (e.g. to narrow the checks for a stream with a known-benign warning).
validateEventStreamWith
  :: (Bounded s, Enum s, Ord s, Show s)
  => ValidationOptions
  -> Text
  -> EventStream (HsPred rs ci) rs s ci co
  -> [EventStreamWarning]
validateEventStreamWith opts label es =
  [ EventStreamWarning { eswStreamLabel = label, eswReason = renderWarning w }
  | w <- validateTransducer opts (transducer es)
  ]

-- | Render a keiki warning to a human-readable reason. All four
-- constructors carry @tvwDetail@; the source vertex is @edgeSource . tvwEdge@
-- (or @tvwSource@ for the nondeterministic pair).
renderWarning :: Show s => TransducerValidationWarning s -> Text
renderWarning w = case w of
  HiddenInput { tvwEdge = e, tvwDetail = d } ->
    "hidden-input @" <> showT (edgeSource e) <> ": " <> Text.pack d
  NondeterministicPair { tvwSource = s, tvwDetail = d } ->
    "nondeterministic @" <> showT s <> ": " <> Text.pack d
  PossiblyDeadEdge { tvwEdge = e, tvwDetail = d } ->
    "possibly-dead @" <> showT (edgeSource e) <> ": " <> Text.pack d
  OpaqueGuard { tvwEdge = e, tvwDetail = d } ->
    "opaque-guard @" <> showT (edgeSource e) <> ": " <> Text.pack d
  where showT = Text.pack . show
```

Register the new module in `keiro-core/keiro-core.cabal` under `exposed-modules`. Build with
`cabal build keiro-core`.

Then add an application-level test (M1's proof) in `keiro/test/Main.hs` — a single hspec
`describe` that asserts the suite's production-intent streams validate clean. Because the streams
are heterogeneously typed (each `EventStream` has different `rs s ci co`), you cannot put them in
one list; instead call `validateEventStream` on each and concatenate. Scope this to keiro-test's
own streams (not jitsurei's `orderEventStream`, which the suite cannot import) and exclude the
deliberately-degenerate fixtures:

```haskell
describe "EventStream replay-safety (validateEventStream)" $
  it "every production-intent stream validates clean" $
    concat
      [ validateEventStream "counter" counterEventStream
      , validateEventStream "snapshot-counter" snapshotCounterEventStream
      -- …add any NEW streams created to exercise richer cases…
      ] `shouldBe` []
```

If a real stream surfaces a conservative `PossiblyDeadEdge` or a benign `NondeterministicPair`,
decide per stream whether to fix the transducer or validate it under narrowed options via
`validateEventStreamWith` (and assert the expected warning explicitly). The degenerate fixtures
(`noOpCounterEventStream` etc.) are deliberately not in this list.

Acceptance: `cabal test keiro-test` is green, and the new assertion proves the real streams pass
(it would print the offending label + reason if any did not).

### Milestone M2 — `mkEventStream` smart constructor

Scope: add a smart constructor that validates at build time, returning `Either`. At the end, an
unsafe stream is rejected before it can be used.

Add to `Keiro.EventStream.Validate` (and to the export list):

```haskell
-- | Build a validated EventStream. Returns the warnings (Left) for an
-- unsafe stream, or the stream itself (Right) when it passes. The bare
-- record literal `EventStream { … }` remains available for low-level
-- callers who do not want the check.
mkEventStream
  :: (Bounded s, Enum s, Ord s, Show s)
  => Text                                  -- ^ caller-supplied stream label
  -> EventStream (HsPred rs ci) rs s ci co
  -> Either [EventStreamWarning] (EventStream (HsPred rs ci) rs s ci co)
mkEventStream label es =
  case validateEventStream label es of
    []    -> Right es
    warns -> Left warns
```

This deliberately takes an already-built `EventStream` and validates it, rather than re-listing
every field as a separate argument: it keeps the smart constructor a thin, total wrapper over
`validateEventStream`, and the bare record literal is what callers feed it. (A
`mkEventStreamWith :: ValidationOptions -> …` companion is a trivial addition if a caller needs
narrowed options at construction time.)

M2's proof is a negative test. Build a tiny transducer with a guaranteed hidden input — an edge
whose update reads a command field that the edge does not emit (the simplest is an ε-edge, i.e.
an edge with an empty `output`, whose `update` reads the command). Wrap it in an `EventStream` and
assert both that `validateEventStream "broken" brokenStream` is non-empty with
`eswStreamLabel == "broken"`, and that `mkEventStream "broken" brokenStream` returns `Left`. Then
assert a known-good stream returns `Right`. Build the broken transducer as a bare `SymTransducer`
record literal in the same style as `counterTransducer` (`keiro/test/Main.hs` ~4305) — the
keiro-test suite does **not** use `Keiki.Builder`, so do not reach for it.

Acceptance: `cabal test keiro-test` green; the negative test demonstrates a broken stream is
rejected by label and a good stream is accepted.

### Milestone M3 — optional codec coverage (blocked follow-up)

Scope: cross-check that every event tag the transducer can emit is present in the stream's `Codec`
`eventTypes :: NonEmpty Text`. This catches a different drift (the transducer emits an event the
codec cannot serialize).

Status: **blocked on a missing keiki API.** Implementing this requires enumerating the event-type
tags a `SymTransducer` can emit, and no exported keiki function does that today (audit of
`Keiki.Core` exports found `WireCtor` in the output DSL but no "all emitted tags" enumerator). Do
not force it here; record it as a follow-up and, if it is wanted, file a keiki feature request for
an emitted-tag enumerator first. The determinism and dead-edge coverage that the original draft
deferred to "M3" is already delivered by M1/M2 (it is part of `validateTransducer`).


## Concrete Steps

All commands run from the keiro repo root `/Users/shinzui/Keikaku/bokuno/keiro`.

First (M0) add the missing `Ord` (and, for `CounterState`, `Enum`/`Bounded`) instances to the
control-state types the validated streams use, then build:

```bash
# edit `deriving stock` clauses: CounterState (keiro/test/Main.hs ~4286), and any other
# control-state type whose stream you will validate, to include Ord (+ Enum, Bounded as needed)
cabal build keiro
```

Expected: keiro builds with the widened deriving clauses.

Then create the module and wire it into the cabal file:

```bash
# create keiro-core/src/Keiro/EventStream/Validate.hs (see Plan of Work for contents)
# add "Keiro.EventStream.Validate" to exposed-modules in keiro-core/keiro-core.cabal
cabal build keiro-core
```

Expected: keiro-core compiles with the new module.

Add the M1 application test and the M2 negative/positive tests to `keiro/test/Main.hs`, then:

```bash
cabal test keiro-test
```

Expected (abbreviated):

```text
EventStream replay-safety (validateEventStream)
  every production-intent stream validates clean [✔]
mkEventStream
  rejects a hidden-input stream by label [✔]
  accepts a replay-safe stream [✔]
```

When M1/M2 land, record the change for keiro consumers by adding an `### Added` entry under
`## [Unreleased]` in `keiro/CHANGELOG.md` (the repo's existing Keep-a-Changelog file), naming the
new `Keiro.EventStream.Validate` module and its exports. Do this in the same commit that merges the
feature, so the changelog never claims a feature that is not yet in the tree:

```text
### Added

- `Keiro.EventStream.Validate`: `validateEventStream` / `validateEventStreamWith` run keiki's
  pure `validateTransducer` over an `EventStream`'s transducer (replay-safety + determinism +
  dead-edge), returning labelled `EventStreamWarning`s; `mkEventStream` is a fail-fast smart
  constructor returning `Left [EventStreamWarning]` for an unsafe stream. The bare `EventStream`
  record literal remains available.
```

Commit after each green milestone. This is a standalone plan (not under a keiro MasterPlan), so
commits carry the ExecPlan and Intention trailers only:

```text
feat(eventstream): add validateEventStream replay-safety check

ExecPlan: docs/plans/54-validateeventstream-and-mkeventstream-validate-keiki-transducers-at-the-eventstream-boundary.md
Intention: intention_01ktensqv9ecmv5cd5jrbcfej7
```

Follow Conventional Commits; commit directly to the current branch (do not create a feature
branch unless asked).


## Validation and Acceptance

The change is effective when:

- Every control-state type a validated stream uses derives `(Bounded, Enum, Ord, Show)` (M0), so
  `validateTransducer`'s constraints are satisfied.
- `validateEventStream "<label>" stream` returns `[]` for every clean stream and a non-empty list
  whose `eswStreamLabel` is `"<label>"` for a stream with a hidden input.
- `mkEventStream "<label>" stream` returns `Right stream` for a clean stream and
  `Left warnings` for an unsafe one, with the bare `EventStream { … }` literal still compiling at
  every existing call site (jitsurei `orderEventStream`, the keiro-test streams).
- `cabal test keiro-test` is green, including the new "EventStream replay-safety" describe block
  and the `mkEventStream` accept/reject tests.
- The negative test demonstrably fails before the feature (there is no function to call) and
  passes after — and, to prove the check has teeth, temporarily breaking a real transducer (e.g.
  removing an emitted field) makes the M1 "every production-intent stream validates clean"
  assertion fail with the offending label printed, then restoring it makes it pass again.

Acceptance is behavioral: a service author can validate all of a service's event streams with one
assertion and can no longer silently construct a stream that will fail hydration. Note the
"validates clean" bar now also covers determinism and dead edges (via `validateTransducer`); a
stream tripping a benign conservative warning is validated under narrowed `validateEventStreamWith`
options rather than left unchecked.


## Idempotence and Recovery

All steps are additive and safe to repeat. The M0 deriving additions only widen instance sets and
change no behavior. The new module and functions do not change existing behavior: existing
`EventStream` record-literal call sites are untouched, and `validateEventStream` /
`validateEventStreamWith` / `mkEventStream` are new exports. Re-running `cabal build` / `cabal test`
is idempotent. M3 (codec coverage) is an optional follow-up blocked on a missing keiki API; the
feature is fully functional without it. Rolling back is reverting the deriving additions and
deleting the new module, its `exposed-modules` entry, and the added tests.


## Interfaces and Dependencies

New code lives in `keiro-core/src/Keiro/EventStream/Validate.hs` and is exported from keiro-core.
It depends on:

- `Keiro.EventStream` (`keiro-core/src/Keiro/EventStream.hs`) for the `EventStream` type and its
  field accessor `transducer`.
- keiki's `Keiki.Core` for `validateTransducer`, `ValidationOptions`, `defaultValidationOptions`,
  `TransducerValidationWarning (..)`, `EdgeRef (..)`, and `HsPred`. keiki is already a declared
  dependency of keiro-core, so no new package dependency is introduced.
- `Data.Text` for the label and reason text.

Required signatures at completion of each milestone:

```haskell
-- M1
data EventStreamWarning = EventStreamWarning { eswStreamLabel :: !Text, eswReason :: !Text }
validateEventStream
  :: (Bounded s, Enum s, Ord s, Show s)
  => Text -> EventStream (HsPred rs ci) rs s ci co -> [EventStreamWarning]
validateEventStreamWith
  :: (Bounded s, Enum s, Ord s, Show s)
  => ValidationOptions -> Text -> EventStream (HsPred rs ci) rs s ci co -> [EventStreamWarning]

-- M2
mkEventStream
  :: (Bounded s, Enum s, Ord s, Show s)
  => Text -> EventStream (HsPred rs ci) rs s ci co
  -> Either [EventStreamWarning] (EventStream (HsPred rs ci) rs s ci co)
```

Cross-repo dependency (satisfied): this plan consumes `validateTransducer` from the keiki repo,
delivered by keiki MasterPlan 14 child plan EP-56
(`../keiki/docs/plans/56-build-time-validation-and-diagnostics-validatetransducer-determinism-and-dead-edge-analysis.md`),
which is **complete** in the keiki version keiro depends on (keiki `0.1.0.0`, exported from
`Keiki.Core`). No version bump is required. The only remaining cross-repo gap is the optional M3
codec-coverage check, which needs a keiki emitted-event-tag enumerator that does not yet exist;
that is a follow-up, not a blocker for M0–M2.

Note on the `phi ~ HsPred rs ci` pin: `validateTransducer` (and therefore `validateEventStream`)
only applies to streams whose guard alphabet is `HsPred rs ci`. All real keiro/jitsurei
transducers satisfy this. A stream built over a different `phi` would need either the looser
`hiddenInputWarnings` backend (hidden-input check only) or a keiki widening; record it as a
follow-up if one ever appears.


## Revision Notes

### 2026-06-06 — validation pass (cross-team review)

This plan was authored by a different team and reviewed against the live keiro and keiki
codebases. The review verified the keiro-side claims (EventStream definition, exports, cabal
dependencies, generic-lens idiom, record-literal call sites — all confirmed) and audited the
current keiki validation API, which had changed since the draft was written. Changes made:

1. **EP-56 already shipped — build on `validateTransducer` directly.** The draft treated
   `validateTransducer` as future work gated on keiki EP-56 and built M1/M2 on the narrower
   `checkHiddenInputs`, deferring the richer check to a gated M3. The review found EP-56 complete
   in the depended-on keiki (`Keiki.Core` exports `validateTransducer`, `ValidationOptions`,
   `defaultValidationOptions`, `TransducerValidationWarning (..)`, `EdgeRef (..)`,
   `hiddenInputWarnings`). Per the user's decision, the plan now builds on `validateTransducer`
   from the start; the former M3 upgrade is folded into M1/M2.

2. **Corrected the shipped keiki signatures.** `validateTransducer` requires
   `(Bounded s, Enum s, Ord s, Show s)` (adds `Ord s`) and pins `phi ~ HsPred rs ci`; the warning
   type is `TransducerValidationWarning s` with four constructors (`HiddenInput`,
   `NondeterministicPair`, `PossiblyDeadEdge`, `OpaqueGuard`) carrying `EdgeRef s` and
   `tvwDetail :: String` — not the flat `hiwEdgeSource`/`hiwReason` record the draft assumed.
   Module code, signatures, and the warning-rendering helper were rewritten accordingly.

3. **Added prerequisite M0 (`Ord` instances).** The draft's claim that the codebase already meets
   the validation constraints was wrong about `Ord`: `OrderState` lacks `Ord`, and `CounterState`
   lacks `Ord`, `Enum`, and `Bounded`. M0 adds the missing `deriving stock` instances.

4. **Fixed the M1 test scope — `keiro-test` does not depend on `jitsurei`.** The draft's
   "validate every stream including `orderEventStream`" assertion would not compile. Per the
   user's decision, M1 is scoped to keiro-test's own streams (`counterEventStream`,
   `snapshotCounterEventStream`, plus any new streams added to exercise richer cases), and the
   suite's deliberately-degenerate fixtures are excluded from the blanket "validates clean"
   assertion. Added a `validateEventStreamWith` options variant so a benign conservative warning
   can be handled without leaving a stream unchecked.

5. **Fixed the M2 transducer-building guidance.** The keiro-test suite builds transducers as bare
   `SymTransducer` record literals and does not import `Keiki.Builder`; the negative transducer
   should follow that style, not the builder.

6. **Reclassified the codec-coverage stretch.** It is blocked on a keiki API (no exported
   enumerator of a transducer's emitted event tags), so it is recorded as a follow-up rather than
   a milestone.

### 2026-06-06 — implementation pass (corrects the validation pass)

The validation pass's headline claim — "EP-56 already shipped in the depended-on keiki" — was
**false**, and the first `cabal build` proved it (`Keiki.Core` does not export `validateTransducer`
at the pin). The validation pass had inspected the local `../keiki` working copy (master HEAD
`344c4ca`, which *does* contain EP-56) instead of the commit keiro actually pins in `cabal.project`
(`869253a`, which predates EP-56). Changes made during implementation:

1. **Added prerequisite M-1: bump the keiki pin.** Updated both keiki `source-repository-package`
   stanzas in `cabal.project` from `869253a` to `344c4ca` (keiki master HEAD on the remote, ships
   EP-56). User chose the bump over the `checkHiddenInputs` fallback. Everything in the validation
   pass about `validateTransducer`'s signature and warning type is correct *against `344c4ca`* — it
   was just not the pinned commit until now.

2. **Repaired pre-existing shibuya `Envelope` drift.** The full reconfigure the bump triggered
   surfaced shibuya-core 0.7.0.0's new required `headers :: Maybe Headers` field. Added
   `headers = Nothing` to the stale literals (`jitsurei/app/Main.hs`, `keiro/test/Main.hs`
   `routerTestEnvelope`). Not caused by this work, but required for a green tree; the user asked for
   it explicitly mid-implementation.

3. **Re-exported the new module from `keiro`.** `keiro-test` imports through the `keiro` package, so
   `Keiro.EventStream.Validate` was added to `keiro`'s `reexported-modules` alongside the existing
   keiro-core re-exports.

4. **M0 scoped to `CounterState` only.** Only `CounterState` (keiro-test) needed `Enum, Bounded,
   Ord`; `OrderState` is jitsurei-side and not in the keiro-test assertion, so it was left as-is.

Outcome: M0–M2 complete and green (3 examples, 0 failures). M3 remains a blocked follow-up.
