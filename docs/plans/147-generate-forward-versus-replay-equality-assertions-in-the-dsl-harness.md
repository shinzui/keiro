---
id: 147
slug: generate-forward-versus-replay-equality-assertions-in-the-dsl-harness
title: "Generate forward-versus-replay equality assertions in the DSL harness"
kind: exec-plan
created_at: 2026-07-28T10:48:59Z
intention: "intention_01kym5dc4ve69sxsjtzd81pbbz"
master_plan: "docs/masterplans/25-structural-consumer-type-ergonomics-and-soundness-preserving-adoption-for-keiro-dsl.md"
---

# Generate forward-versus-replay equality assertions in the DSL harness

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Every aggregate scaffolded by `keiro-dsl` today ships a generated test module (the
"harness") that proves the hand-filled transducer is valid, clock-free, that each event's
codec round-trips, that each initial-state command lands on its declared vertex, and that
old payload versions still decode. What no generated assertion proves is the central promise
of event sourcing: that the events an aggregate emits are, by themselves, enough to rebuild
the exact state the aggregate computed when it emitted them. Today that question is answered
only after deployment — by the database-backed replay audit
(`keiro/src/Keiro/ReplayAudit.hs`) and by an advisory, telemetry-only post-append
verification inside the command runner (`keiro/src/Keiro/Command.hs`) that increments a
`keiro.replay.divergence` counter but never fails anything.

After this plan, every generated aggregate harness ALSO steps the transducer forward from
its initial state through its fixture commands, collects the emitted event chain, pushes
that chain through the generated wire codec (encode then parse), structurally replays the
decoded chain with keiki's replay entry point, and asserts that the replayed final vertex
equals the forward final vertex AND that every declared register equals its forward value.
A developer sees it working by running `cabal test keiro-dsl-conformance` from the repo
root and watching new `PASS  forward/replay equality: …` lines; a mutation script proves
the assertion has teeth by making a deliberately dishonest wire constructor turn exactly
those lines red while every pre-existing assertion stays green.

This implements, ahead of the consumer-owned-types work, the forward/replay clause of the
"Conformance Harness Contract" in
`docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md` (IR-1):
"forward stepping followed by structured replay of the emitted event chain, comparing both
the final vertex and every register value." It is EP-4 of MasterPlan 25
(`docs/masterplans/25-structural-consumer-type-ergonomics-and-soundness-preserving-adoption-for-keiro-dsl.md`).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").

- [ ] M1: `sampleValue` takes the field name; `Text` samples become per-field-distinct.
- [ ] M1: `emitHarness` emits `forwardReplay<Command>` blocks and splices their labelled
      assertions into `harnessAssertions`.
- [ ] M1: Firewall `restrictedImports` allowlist extended for the new `Keiki.Core` imports.
- [ ] M1: New `keiro-dsl-test` expectations for the emitted text land and pass.
- [ ] M1: All committed generated aggregate harnesses regenerated; every `keiro-dsl` test
      suite is green.
- [ ] M2: `replay-divergence.keiro` fixture, `keiro-dsl-conformance-replay` suite, honest
      Holes with a dormant dishonest wire ctor, all green at baseline.
- [ ] M2: `keiro-dsl/test/replay-mutation-test.sh` proves the mutation turns only the
      forward/replay assertions red.
- [ ] M3: ADR 0004 gate-inventory row added, `log.md` updated via `okf log add`, strict OKF
      validation passes.
- [ ] M3: Living sections finalized; MasterPlan 25 progress entries for EP-4 ticked.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Replay the emitted chain only after routing it through the generated wire codec
  (`encode<Agg>Event` then `parse<Agg>Event`), rather than replaying the in-memory events
  directly the way `Keiro.Command.verifyAndSnapshot` does.
  Rationale: The persisted boundary is bytes. The existing per-event round-trip assertion
  covers only the synthetic `sampleEvent<Ctor>` values; emitted events can carry different
  (derived) values. Decoding before replay makes the assertion cover codec asymmetry on the
  values the transducer actually emits, strictly strengthening the check at no soundness
  cost — if decode changes the chain, forward and replay genuinely disagree about persisted
  history.
  Date: 2026-07-28

- Decision: Make `Text` sample values per-field distinct (`"sample-<fieldName>"` instead of
  the uniform `"sample"`), leaving `Int`, `Bool`, id, and enum samples unchanged.
  Rationale: With every `Text` field carrying the identical value, swapping any two
  same-typed field sources produces a byte-identical event and the equality assertion has
  zero discriminating power. Distinct samples are what give the mutation test (and the
  assertion generally) teeth. Guards in the DSL compare names, enum constructors, and
  booleans — never `Text` literals (`exprNames` in
  `keiro-dsl/src/Keiro/Dsl/Harness.hs` shows guard atoms are `AName`/`ABool` only) — so no
  accept assertion can change verdict. The remaining uniform sample kinds are a recorded
  discriminating-power limitation that plan 150's fixture bindings will remove for mapped
  types.
  Date: 2026-07-28

- Decision: The mutation vector is a deliberately dishonest `WireCtor` (a `wcBuild` that
  swaps two same-typed field values) in the hand-owned Holes module of a dedicated
  conformance package, switched on by a one-line sed, not a guard or write mutation.
  Rationale: With honest TH-derived `InCtor`/`WireCtor` values, forward/replay equality is
  close to a theorem — replay re-executes the same transducer on the command recovered from
  the event, so guard flips and wrong writes replay identically and are invisible to this
  assertion (they are caught by the existing accept assertions instead). keiki's own
  `validateTransducer` documentation states its replay guarantee holds only "subject to
  honest 'InCtor' and 'WireCtor' implementations" (`/Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Core.hs`
  around line 1928). The new assertion is precisely the check that catches dishonesty in
  that disclaimed region — which is also exactly the risk class consumer-owned structural
  bindings (plan 150) introduce, since bindings are hand-owned code on the same boundary.
  The mutation test therefore mutates the wire constructor, the one hand-ownable artifact
  whose dishonesty every pre-existing assertion provably misses.
  Date: 2026-07-28

- Decision: Generate forward/replay assertions only for initial-state transitions whose
  spec is `TmLive` and emits at least one event; label each per-transition check
  individually per register plus one for the final vertex.
  Rationale: Replay-only transitions (`TmReplayOnly`, plan 143) cannot be stepped forward;
  a no-emit transition persists nothing, so runtime replay never observes it and
  forward-after-command state is intentionally not reconstructible from the log — asserting
  equality there would assert a falsehood about the runtime model. Per-register labels make
  the mutation test's expected failure precise and give plan 150 a stable convention to
  extend with mapped-register rows instead of reshaping one opaque conjunction.
  Date: 2026-07-28

- Decision: Reuse the accept-assertion fixture commands (single-step, from the initial
  state) rather than inventing multi-step command sequences in this plan.
  Rationale: The harness's only source of commands today is `ctorExpr`'s per-field samples,
  and sample values are not guaranteed to satisfy guards anywhere except where the specs
  already rely on them (the initial-state accepts). Fabricating deeper sequences would
  either fail spuriously on guard-rejecting samples or require a fixture-sequence grammar,
  which is IR-1 generation-layer work (fixture and generator bindings, plan 150). The
  assertion's shape — step forward, decode, replay, compare vertex and each register — is
  sequence-length-agnostic, so plan 150 can extend coverage without changing the convention.
  Date: 2026-07-28


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This repository is `keiro`, a Haskell event-sourcing runtime. Everything below is stated
from scratch; no prior plan is required reading.

**The DSL and its generated ring.** `keiro-dsl` (package directory `keiro-dsl/`, listed in
`cabal.project` at the repo root) is a toolchain for `.keiro` specification files: a parser,
a validator (`check`), a code generator (`scaffold`), a cross-version differ (`diff`), and a
test-module generator (the "harness"). Scaffolding an aggregate produces a "generated ring"
of modules — `Domain.hs` (types), `Codec.hs` (JSON wire codec), `EventStream.hs`,
`Projection.hs`, `Harness.hs` — plus one hand-owned `Holes.hs` created once and never
overwritten, in which the developer writes the transducer body (the decision logic) against
generated type signatures.

**Transducers, registers, replay.** The behavioural core comes from the `keiki` library
(a dependency; source readable at `/Users/shinzui/Keikaku/bokuno/keiki`, but always verify
symbols against the version the build resolves — `keiro` itself already imports the entry
points named below, so they exist in the pinned keiki, which IR-1 records as released
`0.3.1.0`). A `SymTransducer` is a state machine whose nodes are "vertices" (the
lifecycle states), whose edges consume a command and emit zero or more events, and whose
mutable state beyond the vertex lives in a typed "register file" (`RegFile`, a heterogeneous
list of named slots defined in `Keiki.Core`). The entry points that matter here, all in
`Keiki.Core` (module file `src/Keiki/Core.hs` in the keiki source):

- `step :: … -> (s, RegFile rs) -> ci -> Maybe (s, RegFile rs, [co])` — one forward step:
  from a vertex and registers, apply a command, get the new vertex, new registers, and the
  emitted event chain (empty for no-emit edges, longer than one for multi-event edges).
- `applyEventsEither :: … -> (s, RegFile rs) -> [co] -> Either (ReplayFailure s co) (s, RegFile rs)`
  — structured replay: from a seed vertex and registers, consume an observed event chain by
  inverting each event back to the command that produced it and re-executing the transducer
  forward, failing with a precise `ReplayFailure` if any event cannot be matched or a
  multi-event chain is truncated. (`reconstituteEither` is the same thing seeded at
  `(initial t, initialRegs t)`; the harness passes the explicit initial seed so the code
  reads symmetrically with the forward step.)
- `(!) :: RegFile rs -> Index rs r -> r` with the `IsLabel` instance for `Index` — reads a
  single register by label, e.g. `regs ! #reservationState` under `OverloadedLabels` and
  `DataKinds`. `RegFile` deliberately has no `Eq` instance; register-by-register comparison
  through `(!)` is the supported way to compare two register files, and every register type
  the DSL can declare (generated id newtypes, generated enums, the vertex type, `Text`,
  `Int`, `Bool`) derives `Eq` (see `emitId`/`emitEnum`/`emitVertex` in
  `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`).
- Inversion is driven by declared structure: each emitted event is described by an `OPack`
  tying an `InCtor` (how to rebuild the command) to a `WireCtor co fields` — a record
  `WireCtor { wcName, wcMatch :: co -> Maybe fields, wcBuild :: fields -> co }` — plus one
  term per event field. `validateTransducer` proves replayability statically, but its own
  documentation scopes the guarantee: it holds "subject to honest 'InCtor' and 'WireCtor'
  implementations". Those values are ordinarily derived by Template Haskell
  (`deriveAggregateCtorsAll` / `deriveWireCtorsAll` in the generated `Domain.hs`), but the
  hand-owned Holes module may pass any `WireCtor` value to the builder — that is the
  honesty boundary this plan's assertion patrols.

**The harness generator, current state.** `keiro-dsl/src/Keiro/Dsl/Harness.hs` emits the
aggregate harness in `emitHarness` (starting around line 370). The emitted module exposes
`harnessAssertions :: [(String, Bool)]`; a hand-written driver (for example
`keiro-dsl/test/conformance/Main.hs`) prints `PASS`/`FAIL` per label and exits non-zero on
any `False`. The current assertions are exactly: (1) `validateTransducer
defaultValidationOptions` returns `[]`; (2) a clock-free literal baked from the spec;
(3) one codec round trip per event over a synthetic `sampleEvent<Ctor>`; (4) one "accept"
check per transition leaving the initial vertex — `step` with a synthetic sample command
must land on the declared `goto` vertex (see `acceptDecl`, line ~514; it inspects only the
vertex, never the registers, never the events); (5) one `decodeRaw` upcaster check per
version-bumped event. Sample values come from `sampleValue` (line ~535): id types get
`(<Id> "sample")`, enums their first constructor, `Bool` `False`, `Int` `0`, `Text`
`"sample"`. `initialTransitions` (line ~499) selects transitions whose source is the first
declared state. There is NO forward-versus-replay property anywhere in the generated
harness — confirmed by reading the file and the committed instance at
`keiro-dsl/test/conformance/Generated/HospitalCapacity/Reservation/Harness.hs`.

**Where the question is currently answered.** Two places, both after the code ships.
`keiro/src/Keiro/ReplayAudit.hs` replays real stored histories from the database
(`auditExitCode` returns 1 on divergence) — an operational gate, not CI.
`keiro/src/Keiro/Command.hs` (the `RunCommandOptions` documentation around lines 244–296
and `verifyAndSnapshot` around lines 876–900) replays every just-appended batch via
`Keiki.applyEventsEither` when `verifyReplayOnAppend` is set, but divergence is a
"post-commit advisory": it increments a metric and annotates the span; the command still
succeeds. This plan adds the missing static, conformance-CI witness.

**The firewall.** Generated modules are scanned by `firewallBreaches` in
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (the `FirewallSurface` value around line 152).
Its `restrictedImports` entry currently allows generated code to import only
`RegFile`, `HsPred`, `defaultValidationOptions`, `step`, and `validateTransducer` from
`Keiki.Core`. The new harness code needs `applyEventsEither` and `(!)` added to that
allowlist (and nothing else — the symbolic-operator and `Keiki.Builder` prohibitions are
untouched).

**Committed generated code and the sync tests.** Conformance suites compile committed
copies of generated modules. `keiro-dsl-test` (in `keiro-dsl/test/Main.hs`) asserts that a
fresh scaffold of `test/fixtures/reservation.keiro` matches the committed modules under
`test/conformance/` ("matches the committed compiling Generated conformance modules",
line ~1644), likewise for `test/conformance-newsurface/` (from
`test/fixtures/transfer-routing.keiro`) and for the skeleton scaffolds under
`test/conformance-skeletons/` (line ~1957). Every directory holding a committed aggregate
`Harness.hs` must be regenerated after the generator changes; find them with
`grep -rln "harnessAssertions" keiro-dsl/test --include="*.hs"`. At the time of writing
they are: `conformance`, `conformance-v2`, `conformance-coldstart`,
`conformance-newsurface`, `conformance-process`, `conformance-process-full`,
`conformance-process-runtime`, `conformance-router`, `conformance-router-full`,
`conformance-router-runtime`, and the `Skel*` trees under `conformance-skeletons`. Each
non-skeleton directory contains a `keiro-dsl-scaffold-record.<context>.txt` recording the
source spec, module-root, and layout used to produce it — the regeneration recipe.
The drivers that actually EXECUTE aggregate `harnessAssertions` (as opposed to merely
compiling the module) are the `Main.hs` files of `conformance`, `conformance-v2`,
`conformance-coldstart`, `conformance-newsurface`, and `conformance-skeletons`.

**Fixture specs.** `keiro-dsl/test/fixtures/` holds 129 `.keiro` files (plus the
`incident-paging/` pair), spanning positive specs (`reservation.keiro`, `order.keiro`,
`intake.keiro`, `emit.keiro`, `hospital-surge.keiro`, `contract.keiro`, …) and negative
fixtures whose file names describe the defect (`reservation-chain-gap.keiro`,
`duplicate-names.keiro`, `aggregate-bad-refs.keiro`, …). Negative behaviour is organized
two ways: invalid specs asserted through `check` diagnostics in `keiro-dsl-test`, and
behaviour mutations proven by shell scripts that sed a hand-owned file and expect a
specific red assertion — `keiro-dsl/test/mutation-test.sh` is the model this plan follows
(baseline green, one-line sed in `Holes.hs`, expect the suite to fail, restore on exit).

**Relevant ADRs (all local, read during planning).**
`docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md` (ADR-4) is
the layered gate model: each evolution hazard is checked at the earliest boundary with
enough evidence, with a "landed inventory" table mapping change classes to `check`, `diff`,
and runtime/CI gates, and a Consequences bullet stating "The inventory is amended when a
later child plan changes a gate's ownership". Today the forward/replay question appears in
that inventory only as the DB audit rows and the sampled-seed runtime witness; this plan
adds a conformance-CI row and so must amend the table.
`docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md`
(ADR-2) explains `TmReplayOnly` transitions — why the new assertion must skip them.
`docs/adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md` (ADR-3) is
background for why register state matters beyond the vertex. No other local ADR bears on
this work, and no cross-repository ADR lookup is required beyond the references IR-1
already carries; the two normative documents this plan implements are cited by path:
`docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md` (IR-1,
its "Conformance Harness Contract" and "A mapped value read by a state update but omitted
from the first emitted event must make validation or the replay assertion fail") and
`docs/research/14-structural-consumer-type-tradeoffs.md` (guarantee G2 "Private events
mechanically reproduce forward state", the ten-question Proposal Test, and the
mutation-test spirit of its acceptance items).

**Integration point with plan 150 (state it, do not build it).**
`docs/plans/150-implement-the-ir-1-generation-layer-bindings-api-generated-codecs-scaffold-and-conformance-harness.md`
will later extend this same assertion to aggregates carrying structurally mapped registers
(consumer-owned types behind typed bindings). This plan therefore defines the assertion's
shape and labeling convention and must not hard-code assumptions that would break that
extension: register comparisons must be generated by traversing the aggregate's declared
register list (so a new register kind extends the same traversal), labels must follow the
stable `forward/replay equality: <Command> from <Vertex> — …` convention, the per-register
comparison must go through `Eq` (which IR-1 already requires of mapped types used by
generated private events), and the helper functions must be named `forwardReplay<Command>`
so plan 150 extends existing declarations rather than inventing parallel ones.


## Plan of Work

The work is three milestones: change the generator and re-sync every committed harness;
prove the assertion has teeth with a dedicated divergence fixture and mutation script;
record the new gate in ADR 0004.

### Milestone 1 — Generate the assertion; keep the whole tree green

Scope: `keiro-dsl/src/Keiro/Dsl/Harness.hs`, the firewall allowlist in
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, new expectations in `keiro-dsl/test/Main.hs`, and
regeneration of every committed aggregate `Harness.hs`. At the end, every generated
aggregate harness carries labelled forward/replay assertions, and the full `keiro-dsl`
test-suite set passes.

First, make samples distinguishable. In `keiro-dsl/src/Keiro/Dsl/Harness.hs`, change
`sampleValue :: Agg -> Text -> Text` to also receive the field name (its caller `ctorExpr`
already iterates `rcFields rc`, which are `(name, type)` pairs) and emit
`"sample-<fieldName>"` for `Text` fields. Leave id, enum, `Bool`, `Int`, and vertex samples
exactly as they are: ids and enums feed identity/guard logic in existing fixtures, and the
`keiro-dsl-test` expectation `"CountBumpedData 0"` (line ~1550) pins the `Int` sample. Note
in the module documentation that uniform samples for non-`Text` kinds are a known
discriminating-power limitation until plan 150's fixture bindings.

Second, emit the assertion. In `emitHarness`:

- Add `{-# LANGUAGE DataKinds #-}` and `{-# LANGUAGE OverloadedLabels #-}` to the emitted
  pragma block (unconditionally; unused language pragmas do not warn).
- Extend the `Keiki.Core` import in the emitted module with `applyEventsEither` and `(!)`.
- Define, in the generator, the qualifying transition list: transitions in
  `initialTransitions a` whose `tMode` is `TmLive` and whose `tEmits` is non-empty
  (`Transition` is defined in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, line ~378; note the
  existing `initialTransitions` does not filter — do not change the accept assertions'
  behaviour, filter only for the new blocks).
- For each qualifying transition, emit a declaration shaped like this (for an aggregate
  `Note` with initial vertex `NoteEmpty`, command `WriteNote`, registers `note`):

```haskell
-- forward/replay equality (plan 147): step forward, encode/decode the emitted
-- chain through the generated codec, structurally replay it, and require the
-- replayed vertex and every register to equal the forward result.
forwardReplayWriteNote :: [(String, Bool)]
forwardReplayWriteNote =
  case step noteTransducer (NoteEmpty, initialNoteRegs) (WriteNote (WriteNoteData "sample-noteText" "sample-echo")) of
    Nothing -> [(prefix <> "forward step accepted", False)]
    Just (forwardVertex, forwardRegs, emitted) ->
      case mapM (\e -> parseNoteEvent (eventType noteCodec e) (encodeNoteEvent e)) emitted of
        Left _ -> [(prefix <> "emitted chain decodes", False)]
        Right decoded ->
          case applyEventsEither noteTransducer (NoteEmpty, initialNoteRegs) decoded of
            Left _ -> [(prefix <> "replay succeeds", False)]
            Right (replayVertex, replayRegs) ->
              (prefix <> "final vertex", replayVertex == forwardVertex)
                : [ (prefix <> "register note", (replayRegs ! #note) == (forwardRegs ! #note))
                  ]
  where
    prefix = "forward/replay equality: WriteNote from NoteEmpty" <> " -- "
```

  The register list line is generated per declared register by traversing `aRegs a` (the
  same list `emitRegsType`/`emitInitialRegs` traverse in
  `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`), one labelled pair per register; a register-free
  aggregate (for example `test/fixtures/order.keiro`'s `OrderStream`) gets only the vertex
  pair. The command sample expression is the same `ctorExpr` output `acceptDecl` uses —
  the accept fixtures are reused, not duplicated. The exact label prefix convention,
  which plan 150 must keep, is:
  `forward/replay equality: <Command> from <InitialVertex> -- <check>` where `<check>` is
  `forward step accepted`, `emitted chain decodes`, `replay succeeds`, `final vertex`, or
  `register <name>`.
- Splice each `forwardReplay<Command>` list into `harnessAssertions` after the accept
  entries (the emitted list literal becomes a concatenation, e.g. close the literal after
  the accepts and append `++ forwardReplayWriteNote ++ …` before the upcast entries, or
  restructure the whole emission as concatenated sections — either is fine as long as
  ordering is: validate, clock-free, round trips, accepts, forward/replay, upcasts).

Third, extend the firewall allowlist. In `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, change the
`restrictedImports` entry for `Keiki.Core` to also permit `applyEventsEither` and `(!)`.
Do not touch `forbiddenSymbolic` (`!` alone is not listed there; verify the emitted `!`
and `#label` tokens do not trip `codeTokens` by running the existing firewall unit tests,
which live in the "firewall self-check (M3)" describe block of `keiro-dsl/test/Main.hs`).

Fourth, pin the new emission in `keiro-dsl-test`. Add to the harness-related describe
blocks of `keiro-dsl/test/Main.hs`: an expectation that the harness generated from
`test/fixtures/reservation.keiro` contains
`forward/replay equality: RequestTransferReservation from ReservationUnrequested` labels
including `register reservationState`; an expectation that a register-free aggregate
(`test/fixtures/order.keiro`) gets the vertex pair and no register pairs; an expectation
that a replay-only-twin spec (`test/fixtures/reservation-guard-tightened-twin.keiro`)
emits no forward/replay block for the replay-only transition; and an expectation that
`Text` samples are field-distinct (`"sample-noteText"`-style, via the existing
`loweringAggregateSpec` inline spec which has a `note Text` register and `count Int`
fields).

Fifth, regenerate every committed aggregate harness. For each directory listed in Context
holding a committed aggregate `Harness.hs`, consult its
`keiro-dsl-scaffold-record.<context>.txt` for the spec path, module-root, and layout, then
rerun the scaffolder, e.g. for the canonical one:

```bash
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/reservation.keiro \
  --out keiro-dsl/test/conformance --force-generated-overwrite
```

(add `--goldens keiro-dsl/test/golden-payloads` where the record/existing harness embeds
goldens, as `conformance-v2` does; add `--module-root`/`--collocate` per the record). Holes
files are create-if-absent and are never overwritten. For the `conformance-skeletons`
trees, the committed modules are pinned by the `keiro-dsl-test` check "fresh skeleton
scaffolds match the committed compiling modules" — regenerate them by scaffolding the
output of `cabal run keiro-dsl -- new <kind>` with the module roots evident in the
committed module headers (e.g. `SkelAggregate.Generated.MyService.Thing` means
`--module-root SkelAggregate`), or, equivalently, update the files until that test's diff
output is empty. Commit the regenerated files.

Acceptance for M1: `cabal build all` succeeds;
`cabal test keiro-dsl-test keiro-dsl-conformance keiro-dsl-conformance-v2
keiro-dsl-conformance-coldstart keiro-dsl-conformance-newsurface
keiro-dsl-conformance-skeletons` all pass, and the conformance driver output shows the new
`PASS  forward/replay equality: …` lines; the remaining `keiro-dsl` suites (which compile
committed harnesses without running aggregate assertions) also pass. The full suite list
is in `keiro-dsl/keiro-dsl.cabal` (`grep '^test-suite'`); run them all.

### Milestone 2 — Prove the assertion has teeth (mutation test)

Scope: a new fixture spec, a new conformance suite, and a mutation script, mirroring the
structure of `keiro-dsl/test/mutation-test.sh` and `keiro-dsl/test/conformance/`. At the
end, a one-line mutation in a hand-owned Holes file turns exactly the forward/replay
register assertion red while `validateTransducer is empty`, the round trips, and the
accept assertion all stay green — the negative proof IR-1's mutation-test items and the
research note's Proposal Test question 10 demand.

Why this mutation and not a guard/write flip: replay re-executes the same transducer on
the command recovered from the observed event, so any mutation confined to guards or
writes replays identically (the accept assertions catch those instead). Divergence
requires dishonesty on the inversion boundary — a `WireCtor` whose `wcBuild` writes
different values into the event than its declared field terms promise. That is exactly the
"honest WireCtor" caveat `validateTransducer` disclaims, and exactly the boundary
consumer-owned bindings will later occupy.

Create `keiro-dsl/test/fixtures/replay-divergence.keiro`, a minimal aggregate with two
same-typed `Text` command fields and a register fed by one of them (spec syntax modeled on
`test/fixtures/reservation.keiro`):

```text
context replay-divergence

aggregate Note
  regs
    note NoteText = ""
  states Empty Written!

  command WriteNote { noteText:Text echo:Text }
  event NoteWritten = fields(WriteNote)

  Empty -- WriteNote --> write note := noteText ; emit NoteWritten ; goto Written

  wire kind=ctorName fields=camelCase schemaVersion=1
```

Adjust to the real grammar as `check` demands (the register type spelling, `Text` register
initial syntax `note Text = "..."` per `loweringAggregateSpec` in `test/Main.hs`, and the
projection/wire requirements the validator enforces — run
`cabal run keiro-dsl -- check keiro-dsl/test/fixtures/replay-divergence.keiro` until it is
clean, and keep the essential shape: two `Text` command fields, both carried by the event,
one register written from `noteText`). Scaffold it into a new
`keiro-dsl/test/conformance-replay/` directory with `--out` as in M1, add a
`keiro-dsl-conformance-replay` test-suite stanza to `keiro-dsl/keiro-dsl.cabal` copied
from the `keiro-dsl-conformance` stanza (adjusting `hs-source-dirs` and `other-modules`),
and write its `Main.hs` driver as a copy of `keiro-dsl/test/conformance/Main.hs` importing
the new harness module.

Fill the hand-owned Holes module honestly, following
`keiro-dsl/test/conformance/HospitalCapacity/Reservation/Holes.hs` as the model: emit via
an indirection `emitWire` bound to the generated honest wire constructor, and define the
dormant dishonest twin beside it:

```haskell
-- The honest generated wire ctor, behind an indirection the mutation test flips.
emitWire = wireNoteWritten

-- DISHONEST twin for the mutation test: builds the event with the two Text
-- field values swapped relative to the declared field terms, while wcMatch
-- stays honest. validateTransducer cannot see wcBuild's body; only the
-- forward/replay equality assertion catches this.
dishonestWireNoteWritten = wireNoteWritten { wcBuild = wcBuild wireNoteWritten . swapFields }
```

where `swapFields` swaps the two `Text` components of the wire ctor's field tuple (the
tuple is nested-pair shaped, `(f1, (f2, ()))`-style per `OutFields` in `Keiki.Core`;
verify the exact shape from the TH-derived value or a type hole, and import
`WireCtor (..)` — this is a Holes module, so the firewall does not constrain it). The
transducer body uses `B.emit emitWire NoteWrittenTermFields{ noteText = d.noteText, echo = d.echo }`
and `B.slot @"note" =: d.noteText`.

Why the mutation is invisible to every pre-existing assertion, and visible to the new one:
`validateTransducer` inspects declared structure only — empty. The accept assertion checks
the vertex — unchanged. The round trips exercise `sampleEvent<Ctor>` against the generated
codec — Holes is not involved. Forward, the emitted event carries
`noteText = "sample-echo", echo = "sample-noteText"` (swapped by `wcBuild`); replay's
honest `wcMatch` hands inversion the swapped values, inversion assigns them to the
structurally declared command slots, the recovered command has its two fields exchanged,
re-execution writes `note := "sample-echo"`, and
`forward/replay equality: WriteNote from NoteEmpty -- register note` compares
`"sample-echo"` with the forward `"sample-noteText"` and goes red. This is precisely why
M1's per-field-distinct `Text` samples are load-bearing: with uniform `"sample"` values the
swap would be byte-invisible.

Write `keiro-dsl/test/replay-mutation-test.sh` (mark executable) modeled line-for-line on
`keiro-dsl/test/mutation-test.sh`: back up the Holes file with `mktemp`, restore on EXIT;
assert the baseline `cabal test keiro-dsl-conformance-replay` is green; sed
`emitWire = wireNoteWritten` to `emitWire = dishonestWireNoteWritten`; rerun and require
failure; additionally capture the driver output and require BOTH that a line matching
`FAIL  forward/replay equality: WriteNote .* register note` is present AND that
`PASS  validateTransducer is empty` and the accept `PASS` line are still present — that
second grep is the literal proof of "fails with this assertion and passes without it".
Exit 0 only when all three conditions hold.

Acceptance for M2: `cabal test keiro-dsl-conformance-replay` green;
`bash keiro-dsl/test/replay-mutation-test.sh` from the repo root prints its `PASS:` line
and exits 0; running the sed by hand and the suite verbosely shows exactly the
forward/replay register line red.

### Milestone 3 — Record the gate in ADR 0004 and close the plan

Scope: documentation and governance. ADR-4's Consequences say the inventory is amended
when a gate's ownership changes; this plan changes ownership of the forward/replay
question by adding a static conformance-CI witness ahead of the DB audit and the
runtime advisory.

Edit `docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md`: add a
row to the landed-inventory table, e.g.

| Change class | Single-spec `check` | Cross-spec `diff` | Runtime boundary / CI |
|---|---|---|---|
| Forward/replay state divergence (dishonest wire/inversion boundary, later mapped-register bindings) | `validateTransducer` in the generated harness proves the declared structure; honesty of `WireCtor`/`InCtor` is not spec-expressible | Not required | Generated harness steps fixture commands forward, decodes the emitted chain through the generated codec, replays via `applyEventsEither`, and compares final vertex and every register in conformance CI; the DB-backed replay audit and the advisory post-append verification remain the stored-history and production gates |

and advance the frontmatter `timestamp` to the edit time (keep `docId: ADR-4`, `status`,
and `date` untouched — the decision itself is unchanged; this is an inventory amendment
its Consequences explicitly anticipate). Then append the bundle log entry and validate
strictly, per the repo's profiled ADR contract (`.claude/skills/exec-plan/ADR.md`):

```bash
okf log add docs/adr -m "Record the generated-harness forward/replay equality assertion as the conformance-CI gate for forward-versus-replay state divergence (plan 147)."
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

(`just adr-validate` runs the same validation.) Finally update this plan's living sections,
tick MasterPlan 25's two EP-4 progress boxes in
`docs/masterplans/25-structural-consumer-type-ergonomics-and-soundness-preserving-adoption-for-keiro-dsl.md`,
set the registry row for EP-4 to its new status, and perform the ADR distillation pass
(the ADR-4 amendment above is the expected durable output; create nothing new unless
implementation surfaces a durable decision).

Acceptance for M3: `okf validate` command above exits 0; the ADR table row renders; the
masterplan and this plan reflect completion.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` (the
project provides its toolchain via the flake devShell; if `cabal` is missing, enter
`nix develop` first).

Orientation and baseline:

```bash
cabal build all
cabal test keiro-dsl-test
cabal test keiro-dsl-conformance
grep '^test-suite' keiro-dsl/keiro-dsl.cabal
grep -rln "harnessAssertions" keiro-dsl/test --include="*.hs"
```

Expected baseline conformance output (abridged):

```text
PASS  validateTransducer is empty
PASS  clock-free: spec samples no wall clock
PASS  golden round-trip: TransferReservationCreated
PASS  golden round-trip: TransferReservationConfirmed
PASS  accepts RequestTransferReservation from ReservationUnrequested
```

M1 edits: `keiro-dsl/src/Keiro/Dsl/Harness.hs` (samples, imports, pragmas,
`forwardReplay<Command>` emission, `harnessAssertions` splice),
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (`restrictedImports`), `keiro-dsl/test/Main.hs`
(new expectations). Then regenerate committed harnesses; the canonical one:

```bash
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/reservation.keiro \
  --out keiro-dsl/test/conformance --force-generated-overwrite
git -C . status --short keiro-dsl/test
```

Repeat per directory using each `keiro-dsl-scaffold-record.<context>.txt` (spec path,
module-root, layout; add `--goldens keiro-dsl/test/golden-payloads` where recorded or
where the committed harness embeds goldens). Re-run the whole suite list until green:

```bash
for t in $(grep '^test-suite' keiro-dsl/keiro-dsl.cabal | awk '{print $2}'); do
  cabal test "$t" || break
done
```

Expected new lines in the conformance driver output:

```text
PASS  forward/replay equality: RequestTransferReservation from ReservationUnrequested -- final vertex
PASS  forward/replay equality: RequestTransferReservation from ReservationUnrequested -- register reservationId
PASS  forward/replay equality: RequestTransferReservation from ReservationUnrequested -- register hospitalId
PASS  forward/replay equality: RequestTransferReservation from ReservationUnrequested -- register patientAcuity
PASS  forward/replay equality: RequestTransferReservation from ReservationUnrequested -- register reservationState
```

M2 steps:

```bash
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/replay-divergence.keiro
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/replay-divergence.keiro \
  --out keiro-dsl/test/conformance-replay
# fill the Holes module by hand (honest emitWire + dormant dishonest twin),
# add the keiro-dsl-conformance-replay stanza and driver Main.hs, then:
cabal test keiro-dsl-conformance-replay
bash keiro-dsl/test/replay-mutation-test.sh
```

Expected mutation-script transcript:

```text
== baseline: harness is green ==
ok: baseline green
== mutate: swap emitWire to the dishonest wire ctor ==
== rebuild + run harness (expect the forward/replay assertion red) ==
ok: forward/replay register assertion went red; validateTransducer and accept stayed green
PASS: forward/replay equality has teeth (mutation caught)
```

M3 steps:

```bash
$EDITOR docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md
okf log add docs/adr -m "Record the generated-harness forward/replay equality assertion as the conformance-CI gate for forward-versus-replay state divergence (plan 147)."
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Commit per milestone with conventional messages, e.g.
`feat(dsl): generate forward/replay equality assertions in aggregate harnesses`,
`test(dsl): prove forward/replay assertions with a dishonest-wire mutation fixture`,
`docs(adr): record the forward/replay conformance-CI gate in ADR-4's inventory`.


## Validation and Acceptance

Observable acceptance, in behaviour terms:

1. Running `cabal test keiro-dsl-conformance` from the repo root prints, alongside the
   pre-existing assertions, one `PASS  forward/replay equality: … -- final vertex` line and
   one `PASS  forward/replay equality: … -- register <name>` line per declared register for
   each live, event-emitting initial transition — and the suite exits 0. The same holds for
   `keiro-dsl-conformance-v2`, `-coldstart`, `-newsurface`, `-skeletons`, and the new
   `-replay` suite.
2. Every suite named by `grep '^test-suite' keiro-dsl/keiro-dsl.cabal` passes, proving the
   assertion generates correctly for every existing DSL fixture spec that reaches a
   compiled harness, and that all 129 fixture specs under `keiro-dsl/test/fixtures/` still
   parse/check/diff/scaffold as before (`keiro-dsl-test` covers them).
3. `bash keiro-dsl/test/replay-mutation-test.sh` exits 0, and its captured output shows
   the dishonest-wire mutation turning `forward/replay equality: WriteNote … register note`
   red while `validateTransducer is empty` and the accept assertion remain `PASS` — the
   suite passes without the new assertion and fails with it.
4. `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce
   --log-enforce` exits 0 with the amended ADR-4 and log entry in place.

Soundness gate — the ten-question Proposal Test from
`docs/research/14-structural-consumer-type-tradeoffs.md` ("A Proposal Test for Future
Keiro Improvements"), answered for this change; per MasterPlan 25 this gate is mandatory
and the change may not land if any answer regresses:

1. Authority: unchanged — the generated codec remains the only wire authority; the harness
   consumes it (`encode<Agg>Event`/`parse<Agg>Event`), it does not add a second codec.
2. Replay (emphasized): this plan is a strengthening of exactly this question. The
   assertion mechanically demonstrates, in CI, that every forward register update on the
   exercised transitions is reconstructed from the emitted private events alone — seed
   state plus decoded events, nothing else, via `applyEventsEither`. A value read by a
   state update but not recoverable from the emitted chain makes either
   `validateTransducer` (statically) or this assertion (behaviourally, through the honest-
   ctor gap) fail, which is the IR-1 sentence this plan implements.
3. Visibility: no new guard or update semantics are claimed; nothing is hidden behind
   checked syntax.
4. Compatibility direction: unaffected; `diff` classifications and their directions are
   untouched (no `Diff.hs` change).
5. Ownership: unaffected; no public/private contract surface changes.
6. Completeness: the assertion is emitted from the same resolved `Agg` the other harness
   sections traverse; a transition or register added to the spec flows into the
   forward/replay block through the same `initialTransitions`/`aRegs` traversals, and the
   committed-versus-fresh sync tests in `keiro-dsl-test` fail if emission and committed
   conformance code drift.
7. Migration: no wire bytes, tags, defaults, or upcasters change; the only migration is
   regenerating committed `-- @generated` harness modules, which the sync tests enforce.
8. Recovery: generator changes are additive text emission; regeneration is deterministic
   and repeatable; the mutation script restores the Holes file on EXIT via `trap`.
9. Performance: test-time only; a handful of extra pure steps and codec calls per
   aggregate in CI, nothing on any runtime path.
10. Negative proof (emphasized): the M2 mutation test is the demonstration — a dishonest
    `wcBuild` that every pre-existing assertion provably accepts is caught only by the new
    assertion, with the script asserting both halves (specific red line; specific
    still-green lines). Without the new machinery the guarantee would silently not hold.

Interpreting failures: a red `-- register <name>` line means forward and replayed register
values differ (the mutation case, or a genuine inversion bug); a red `-- replay succeeds`
means the decoded chain did not replay (`ReplayFailure` — usually a codec/inversion
mismatch); a red `-- emitted chain decodes` means the generated codec cannot read its own
emitted event (codec asymmetry on emitted values, which the sampleEvent round trips cannot
see); a red `-- forward step accepted` means the fixture command no longer satisfies the
transition guard (a sample-value regression — check the `sampleValue` change against the
spec's guards).


## Idempotence and Recovery

Every step is repeatable. Scaffolding with `--force-generated-overwrite` deterministically
rewrites only `-- @generated` modules ("is deterministic (re-scaffolding yields
byte-identical text)" is an existing `keiro-dsl-test` case); Holes files are
create-if-absent and never clobbered. If a regeneration targets the wrong directory or
flags, `git checkout -- keiro-dsl/test/<dir>` restores it; the scaffold-record file in each
directory is the authoritative recipe. The mutation script backs the Holes file up to a
`mktemp` path and restores it in an EXIT trap, so an interrupted run leaves the tree clean;
if a crash ever bypasses the trap, `git checkout -- keiro-dsl/test/conformance-replay` (and
the Holes path under it) recovers. The ADR edit is a plain text amendment; if `okf
validate` rejects it, fix frontmatter/log and re-run — `okf log add` appends, so avoid
duplicate entries by checking `docs/adr/log.md` before re-adding. Nothing in this plan
touches a database or any destructive operation.


## Interfaces and Dependencies

Libraries and modules, with the surface that must exist at each milestone's end:

- `keiki` (resolved by the build; IR-1 records the released baseline as `0.3.1.0`, and
  `keiro/src/Keiro/Command.hs` already imports the replay surface, so no bound change is
  expected — verify before touching bounds, per the compatibility-baseline discipline in
  IR-1). Consumed from `Keiki.Core`: `step`, `applyEventsEither`, `validateTransducer`,
  `defaultValidationOptions`, `RegFile`, `(!)`, the `IsLabel` instance for `Index`, and
  (Holes-side only, M2) `WireCtor (..)`.
- `keiro-dsl` internals: `Keiro.Dsl.Harness` (all emission changes), `Keiro.Dsl.Scaffold`
  (`FirewallSurface.restrictedImports` only), `Keiro.Dsl.Grammar` (read-only:
  `Transition`, `TransitionMode`, `RegDecl`), `Keiro.Dsl.Goldens` (unchanged, still feeds
  `harnessForWithGoldens`).

End of M1 the emitted (not library) surface per aggregate harness is:
`harnessAssertions :: [(String, Bool)]` (unchanged type, extended contents) and one
`forwardReplay<Command> :: [(String, Bool)]` per qualifying initial transition, with the
label convention `forward/replay equality: <Command> from <InitialVertex> -- <check>`.
End of M2 the repo additionally contains
`keiro-dsl/test/fixtures/replay-divergence.keiro`, the committed
`keiro-dsl/test/conformance-replay/` tree (generated ring, hand-filled Holes with
`emitWire` and `dishonestWireNoteWritten`, driver `Main.hs`), the
`keiro-dsl-conformance-replay` stanza in `keiro-dsl/keiro-dsl.cabal`, and the executable
`keiro-dsl/test/replay-mutation-test.sh`. End of M3 ADR-4's inventory table carries the
conformance-CI forward/replay row and `docs/adr/log.md` the corresponding entry.

Downstream consumer of these interfaces: plan 150
(`docs/plans/150-implement-the-ir-1-generation-layer-bindings-api-generated-codecs-scaffold-and-conformance-harness.md`)
extends the per-register comparison rows to structurally mapped registers and widens
fixture coverage via fixture/generator bindings; it depends on the label convention, the
`forwardReplay<Command>` naming, the register-list traversal, and `Eq`-based comparison —
none of which this plan may specialize to today's scalar register kinds.
