---
id: 9
slug: integrate-keiki-codec-json-into-keiro-snapshot-path
title: "Integrate keiki-codec-json into keiro snapshot path"
kind: exec-plan
created_at: 2026-05-10T15:01:32Z
intention: "intention_01kr96cnxhee3sf8m3da0wrcpj"
---

# Integrate keiki-codec-json into keiro snapshot path

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

**Status: queued.** Waits on `keiki-codec-json` v0.1 being published to Hackage (per
the keiki MasterPlan at
`/Users/shinzui/Keikaku/bokuno/keiki/docs/masterplans/11-keiki-codec-json-package-implementation-and-rollout.md`).
Track the upstream EP-36 progress via the cross-references in §"Context and
Orientation".


## Purpose / Big Picture

keiro's EP-4 snapshot strategy (`docs/research/09-snapshot-strategy.md`) defines a
`StateCodec (s, RegFile rs)` that writes the joint state to a `keiro_snapshots` row,
discriminated by two columns: `state_codec_version :: Int` (consumer-managed) and
`regfile_shape_hash :: Text` (keiki-managed). The plan published before keiki shipped
the primitives says, in §3 and §15:

- "The `RegFile rs <-> Aeson.Value` helper, the register-file shape hash, and the
  structured error model on `step`/`omega` … the first two share a compile-time
  slot-list walk."
- "Until the helper lands, every aggregate author hand-rolls the register-file
  encoder by walking the slot list themselves; this is tedious but mechanical."

This ExecPlan **closes that gap**. Once `keiki-codec-json` v0.1 is on Hackage with
`Keiki.Shape.regFileShapeHash` and `Keiki.Codec.JSON.regFileToJSON`/`regFileFromJSON`,
keiro's snapshot path can stop describing them as upstream gaps and start using them.

After this plan is complete:

- keiro's cabal depends on `keiki ^>= …` (with `Keiki.Shape`) and `keiki-codec-json
  ^>= …`.
- keiro's `StateCodec (s, RegFile rs)` is implemented using `regFileToJSON` and
  `regFileShapeHash` instead of hand-rolled walkers.
- An end-to-end snapshot write/read cycle against a real Postgres demonstrates the
  joint state survives the round trip with the §10-case-style RegFile shapes from
  `keiki/docs/plans/36-...` exercised.
- Documentation captures **when keiro authors should reach for `regFileToJSON`
  directly** (custom `StateCodec` implementations, ad-hoc debugging tooling,
  observability dashboards reading in-flight RegFile state) **vs** when they should
  use keiro's `StateCodec` abstraction (the typical snapshot path; the default for
  any aggregate with `esSnapshotPolicy /= SnapshotPolicyNever`).

The user-visible win: a keiro author with a non-trivial register file gets snapshot
encoding for free (`deriveRegFileToJSON` after EP-38 lands; explicit instances in
the meantime), and operators get a stable, browseable JSON for incident response.


## Progress

- [ ] M0 — Wait for `keiki-codec-json` v0.1 on Hackage. Capture the version in this
      plan's Surprises log when it lands.
- [ ] M1 — Add cabal dependencies in keiro's project. Verify `cabal build all`
      compiles after the new deps land. No keiro code changes yet.
- [ ] M2 — Replace any hand-rolled `RegFile` walkers in keiro's snapshot codec
      sketches with calls to `regFileToJSON`/`regFileFromJSON`. Adopt
      `regFileShapeHash` for the `regfile_shape_hash` column. Update
      `docs/research/09-snapshot-strategy.md`'s §3 / §15 prose to remove the "hand-
      rolled walker" workaround language.
- [ ] M3 — End-to-end test: a fixture aggregate with a non-trivial RegFile (modelled
      after EP-36 §10 Case A or C — small enough for a unit test) writes a snapshot,
      crashes, restarts, reads the snapshot back, replays a tail event, and produces
      the same joint state as full replay would. Verify against a real Postgres via
      the existing kiroku test harness.
- [ ] M4 — Documentation: a `Usage Patterns` section in `docs/research/09-snapshot-
      strategy.md` (or a new `docs/research/regfile-codec-usage.md`) covering when
      to reach for `Keiki.Codec.JSON` directly vs through keiro's `StateCodec`. See
      §"Usage guidance" below for the content this section must capture.
- [ ] M5 — Performance check: against a representative aggregate with a moderately
      large RegFile (matched to EP-36 §10 Case B-style shape), measure encode/decode
      latency in the snapshot hot path and verify the streaming-encoder path (R10
      from EP-36) is wired correctly when `esSnapshotPolicy` is aggressive. Numbers
      recorded in this plan's Surprises log; not a release gate.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Frame this plan as **queued** rather than active. M0 is "wait for the
  upstream landing"; the rest of the milestones are real work that begins when
  `keiki-codec-json` v0.1 ships.
  Rationale: Authoring an active plan whose first step is "wait" misrepresents the
  current state. The queued framing makes it clear that no keiro implementation
  effort is required until upstream lands. The plan exists to capture the design
  intent so it isn't lost in the gap between authoring keiki EP-36 and starting
  keiro v1 implementation.
  Date: 2026-05-10.

- Decision: Use `keiki-codec-json`'s `RegFileToJSON` directly for keiro's
  `StateCodec (s, RegFile rs)` rather than wrapping it in a keiro-side abstraction
  (e.g., a new typeclass over `(s, RegFile rs)`).
  Rationale: keiro EP-4 §3 (`docs/research/09-snapshot-strategy.md`) defines
  `StateCodec` as a record-of-functions, not a typeclass. The `RegFileToJSON`
  derivation is one input to building a `StateCodec` value; wrapping it in another
  typeclass would add complexity without offsetting benefit. Direct use of
  `regFileToJSON`/`regFileShapeHash` keeps the dependency chain shallow.
  Date: 2026-05-10.

- Decision: Defer adopting `keiki-codec-json` 's TH derivation helpers (the keiki
  EP-38 plan, when authored) until they ship. Until then, keiro fixtures explicitly
  declare `RegFileToJSON` instances by hand for their slot types.
  Rationale: M2's acceptance does not require TH; the v1 codec is usable with
  hand-written instances. TH is a quality-of-life improvement that can land in a
  follow-up keiro release without blocking integration.
  Date: 2026-05-10.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

### The upstream work

The codec lands in keiki via the MasterPlan at:

- **`keiki/docs/masterplans/11-keiki-codec-json-package-implementation-and-rollout.md`** — coordinates the four child plans below.
- **`keiki/docs/plans/36-regfile-json-codec-and-shape-hash-for-snapshot-persistence.md`** — Phase A, the implementation. This is the plan to follow during M0; its M5 (cross-GHC CI gate) is the trigger to re-evaluate whether to begin M1 here.
- Phase B plans (TBA in keiki when authored): Hackage release (EP-37 on the keiki side), TH ergonomics (EP-38), property-test toolkit (EP-39).

The driving keiro requirement was articulated at:

- **`docs/research/11-upstream-roadmap.md` §7.1** ("Register-file `<-> Aeson.Value`
  helper, Wanted, Blocking for EP-4") and **§7.2** ("Register-file shape hash, Wanted,
  Blocking for EP-4"). EP-7 of the parent MasterPlan and the 2026-05-09 cost-benefit
  audit (Surprises & Discoveries on the parent MasterPlan) confirmed the work is
  contract-orthogonal — it proceeds regardless of any future keiro contract evolution.

The published snapshot strategy that consumes the upstream output is:

- **`docs/research/09-snapshot-strategy.md`** — §3 declares `StateCodec (s, RegFile
  rs)`; §6 declares the `keiro_snapshots` table including the `regfile_shape_hash
  TEXT NOT NULL` column; §15 #1 and #2 enumerate the keiki-side gaps this plan
  closes from the keiro side.

### What "available" means

`keiki-codec-json` is "available" for keiro consumption when:

1. The package is on Hackage at v0.1.x (per the keiki MasterPlan's EP-37). Until
   then, depending on `keiki-codec-json` requires a git source-repository pin in
   keiro's cabal — workable for prototyping but unsuitable for keiro v1 release.
2. EP-36's M5 cross-GHC CI gate is green for the GHC version keiro builds against.
3. EP-36's M4 performance baseline shows acceptable encode/decode for representative
   `RegFile` shapes (cf. §10 Case B for the worst-case shape keiro should expect to
   handle).

These three preconditions are checked at M0; if any fails, M1 cannot begin.

### The driving consumer's RegFile shapes

This plan does not introduce new RegFile shapes; it inherits the shapes already
documented in keiki EP-36 §10. For testing purposes (M3, M5), the keiki §10 cases
provide ready-made shape descriptions. M3's fixture should be modelled after Case A
(multi-party signing — bounded slots, moderate value sizes) since it exercises the
codec without needing to build infrastructure for very large RegFiles.


## Usage guidance

This is the content M4 must capture in the documentation. Carrying it here so it
isn't lost between plan authoring and M4 execution.

### When to use `Keiki.Codec.JSON.regFileToJSON` directly

A keiro author has direct cause to call `regFileToJSON` (or `regFileToEncoding`) in
these situations:

1. **Custom `StateCodec` implementation.** When the default `StateCodec` produced by
   keiro's helpers doesn't fit — e.g., the consumer needs to embed the encoded
   RegFile inside a wrapping JSON envelope, or wants to compress only the registers
   half — they construct a `StateCodec` manually. `regFileToJSON` is the building
   block.

2. **Operational dashboards reading in-flight RegFile state.** A monitoring tool
   that queries `keiro_snapshots` rows and renders the joint state for a human
   operator (incident response, debugging) decodes the JSONB `state` column via
   `regFileFromJSON`. This is read-only consumption outside the command cycle.

3. **Ad-hoc analytical queries.** A consumer running PostgreSQL JSONB queries
   directly against `keiro_snapshots.state` to compute derived metrics. They need
   to understand the JSON shape `regFileToJSON` produces (Symbol-keyed object) so
   they can write `WHERE state -> 'registers' ->> 'retryCount' > '3'` queries
   without ambiguity.

4. **Cross-keiki-version migration tooling.** A future operator-facing tool that
   migrates snapshot rows when an aggregate's slot list changes (per `keiki/docs/
   research/schema-evolution.md`'s "snapshot invalidation" path) reads old rows via
   `regFileFromJSON`, transforms, and writes new rows. **This is application-level
   work, not in keiro's scope, but the helper is what makes it possible.**

### When to use keiro's `StateCodec` abstraction (the default)

Use `StateCodec` (which internally calls `regFileToJSON`/`regFileShapeHash`) for:

1. **The typical snapshot path.** Any aggregate with `esSnapshotPolicy` other than
   `SnapshotPolicyNever`. The cycle calls `StateCodec` automatically; the user
   never invokes `regFileToJSON` themselves.

2. **Process manager state persistence.** Per keiro EP-3 §5, process managers are
   themselves event-sourced aggregates and benefit from snapshots in exactly the
   same way. They use the same `StateCodec` slot in `EventStream`.

3. **Future workflow journals (keiro v2).** The durable-execution journal stream
   (`wf-<workflowId>`) uses `StateCodec` for its journaled state per the EP-5
   roadmap. Same shape.

### What NOT to use `regFileToJSON` for

- **Event payload encoding.** Events use `Codec co` (per keiro EP-2's design,
  `docs/research/07-codec-strategy.md`); the codec layer there carries per-record
  versioning and upcasters, which `regFileToJSON` deliberately does not. Mixing
  layers is a category error.

- **Partial-RegFile encoding.** EP-36 R7 documents that encoding an unwritten slot
  (the `error "uninit:..."` sentinel) throws. Operators wanting to inspect a
  partially-written RegFile during debugging should use a future
  `regFileToJSONPartial` (EP-36 §6 deferred); until then, hand-roll it.

- **Cross-language interop without slot-type co-design.** EP-36 §9.A7 caveats:
  slot types whose `ToJSON` produces Haskell-idiomatic shapes (`Either` as
  `{"Left":...}`/`{"Right":...}`) are not idiomatic in other languages. A non-
  Haskell consumer of `keiro_snapshots.state` expects the keiro author has chosen
  cross-language-friendly slot types.

### When to use `regFileShapeHash` directly

`regFileShapeHash` always lives behind keiro's `StateCodec` — operators do not
typically call it themselves. The exception is **migration tooling** (the same case
as above): a tool that reads the `regfile_shape_hash` column and decides whether to
attempt decoding the row needs to compute the current code's hash for comparison.

The shape hash is **not** a content hash — two semantically-equal RegFile values
produce different content but the same shape hash. This distinction is critical for
operators reasoning about cache invalidation: changing the *value* in a slot does
not change the hash; only changing the *type* of a slot does.


## Plan of Work

Single-track. Five milestones (M0–M5) executed sequentially.

### M0 — Wait for upstream availability

Track the keiki MasterPlan at
`/Users/shinzui/Keikaku/bokuno/keiki/docs/masterplans/11-...` for completion of
EP-36 (its first child plan). When EP-36 reaches M5 (cross-GHC CI gate), check
keiki EP-37's progress for Hackage publication. When v0.1 is on Hackage **and** the
cross-GHC gate is green for keiro's target GHC, M0 is complete.

Acceptance: a Surprises log entry on this plan recording the upstream version used,
the date keiki published it, and the GHC version validated.

### M1 — Add cabal dependencies

Add `keiki-codec-json ^>= 0.1` to the cabal file(s) of any keiro library or
test-suite that consumes the snapshot path. Bump the existing `keiki ^>= …` lower
bound to the version that ships `Keiki.Shape`.

Acceptance: `cabal build all` succeeds on a clean checkout. No code changes in
keiro yet — this is dependency wiring only.

### M2 — Replace hand-rolled walkers; adopt `regFileShapeHash`

Find any place in keiro's design docs or test fixtures that currently sketches a
hand-rolled `RegFile` walker (per `docs/research/09-snapshot-strategy.md` §15 #1
and §3, the workaround language). Replace those sketches with explicit calls to
`regFileToJSON`/`regFileFromJSON`. Update §15 #1 and #2 prose to record that the
upstream gap is closed; the discussion moves from "this is what we'll do when keiki
ships" to "here's how we use it".

Update §6 of `09-snapshot-strategy.md` if the schema column type or constraints
have changed in light of EP-36's shipped hash format (it shouldn't; `Text` works
for any hex string).

Acceptance: a grep for "hand-rolled" / "TODO: replace with keiki-codec-json" /
similar TODO markers in the snapshot-strategy doc returns no results. The doc
references `Keiki.Codec.JSON` and `Keiki.Shape` directly.

### M3 — End-to-end snapshot test

Author a fixture aggregate with a non-trivial RegFile patterned after EP-36 §10
Case A (multi-party signing — bounded slot count, moderate values). Wire it through
keiro's existing kiroku-based test harness so the test:

1. Runs N commands against the aggregate, building up RegFile state.
2. Triggers a snapshot via `esSnapshotPolicy = snapshotPolicyEvery k` for some
   `k < N`.
3. Restarts (simulated by recreating the runtime).
4. Hydrates from the snapshot row.
5. Replays one more event (the tail).
6. Asserts the resulting joint state equals the result of full replay from
   version 0.

Acceptance: `cabal test keiro-snapshot-integration` (or the suite name we pick)
passes against a real Postgres.

### M4 — Documentation: usage guidance

Author the content described in §"Usage guidance" above as a new section in
`docs/research/09-snapshot-strategy.md` (or as a new doc
`docs/research/regfile-codec-usage.md` if it grows beyond a few sub-sections).
Cross-reference from EP-36 (keiki side) so a keiki user looking for "how do
downstream consumers use this?" finds keiro's writeup.

Acceptance: the section exists; an external reader (someone new to keiro) can
answer "should I call `regFileToJSON` directly here?" by reading the section
without asking the maintainers.

### M5 — Performance check

Run the M3 fixture again at a larger scale (modelled after EP-36 §10 Case B —
larger value sizes, moderate slot count) and measure the snapshot encode/decode
times. Verify that:

- The streaming-encoder path (`regFileToEncoding`, EP-36 R10) is wired correctly
  when `esSnapshotPolicy` is aggressive; check via `tasty-bench`-style measurements
  if the keiro test harness has the infrastructure, or via crude `getCurrentTime`
  bracketing if it does not.
- The encode latency in the `runCommand` tail (snapshot post-cycle hook) does not
  produce P99 spikes that would be visible to consumers at the keiro-cycle level.

Numbers recorded in this plan's Surprises log. **Not a release gate** — this is
information-gathering. If the numbers reveal a problem, open a follow-up plan.

Acceptance: numbers recorded; reasoning documented for whether they are acceptable
for keiro v1.


## Concrete Steps

### M0

1. Periodically (weekly is fine) check
   `/Users/shinzui/Keikaku/bokuno/keiki/docs/masterplans/11-keiki-codec-json-package-implementation-and-rollout.md`
   Progress section. The trigger condition is: EP-36 M5 checkbox marked, EP-37 (when
   authored) Hackage release marked complete.

2. Verify on Hackage that `keiki-codec-json` is published at v0.1.x and inspect its
   cabal `tested-with` to confirm GHC compatibility.

3. Update this plan's Surprises log with the version captured.

### M1

1. Edit keiro's cabal (path TBD until keiro implementation begins) to add
   `keiki-codec-json` as a dep.

2. Run `cabal build all` on a clean checkout. Verify green.

### M2

1. Identify the files containing snapshot-related "hand-rolled walker" language.
   Likely candidates: `docs/research/09-snapshot-strategy.md` §3, §15, plus any
   test fixtures.

2. Replace with concrete `regFileToJSON`/`regFileFromJSON`/`regFileShapeHash` calls.

3. Update prose to remove the "upstream gap" framing.

### M3

1. Author the fixture aggregate (roughly 50–100 lines of Haskell modelling §10
   Case A).

2. Wire through the existing test harness.

3. Run; verify all six assertion steps pass.

### M4

1. Author the `Usage Patterns` section, drawing from §"Usage guidance" above
   verbatim with light editing for the doc's tone.

2. Cross-reference from the keiki side: drop a pointer in keiki's M6 (documentation)
   so a keiki haddock reader can find the keiro guidance.

### M5

1. Author the larger-scale fixture (Case B-style; ~10K-entry slot value).

2. Measure encode/decode times.

3. Decide whether the numbers are acceptable for v1. Record reasoning.


## Validation and Acceptance

**Plan-level acceptance**: a keiro user can declare an aggregate with a register
file, configure a non-trivial `esSnapshotPolicy`, run commands against it, restart
the runtime, and have their state hydrated via the snapshot row written by EP-36's
helpers — all using `keiki-codec-json` from Hackage with no hand-rolled walkers
anywhere in keiro's codebase.

**M3-specific acceptance**: the end-to-end test demonstrates the round trip with
identifiable inputs and outputs (a specific sequence of commands → a known final
joint state). The test name and command lives in keiro's CI matrix.

**M4-specific acceptance**: a reviewer reading the usage guidance can correctly
answer the four "when to use directly vs through StateCodec" cases without reading
this plan.


## Idempotence and Recovery

Implementation steps are idempotent at the cabal-build level. M0 has no side
effects (it's monitoring upstream). M1's cabal edit can be repeated safely. M2's
doc edits are diffs; revertable. M3's test addition is isolated to a new file or a
new test module; revertable. M4's doc additions are isolated. M5 is read-only
measurement.

If `keiki-codec-json` ships with a behaviour that doesn't match keiro's M3 test
expectations (e.g., a JSON-encoding shape we didn't anticipate), the recovery is
to file an issue against the keiki MasterPlan, pin keiro to a known-good upstream
version, and adapt M3's test or §"Usage guidance" to match. The keiki MasterPlan
becomes the durable place for cross-cutting issues.


## Interfaces and Dependencies

### Libraries used

- **`keiki ^>= …`** — the version that ships `Keiki.Shape`. Specific lower bound
  determined at M1 once the version is known.
- **`keiki-codec-json ^>= 0.1`** — new keiro dependency. The package's interface is
  documented in keiki EP-36 §3 / §7.
- **`aeson`** — already a transitive dep through `keiki-codec-json`; keiro may pull
  it in directly if needed for non-RegFile encoding.
- **Existing keiro deps** — `hasql`, `effectful`, `streamly`, `kiroku`, etc. — no
  changes from this plan.

### Type signatures consumed

From `keiki-codec-json` (per EP-36 §7):

    class RegFileToJSON (rs :: [Slot]) where
      regFileToJSON     :: RegFile rs -> Aeson.Value
      regFileFromJSON   :: Aeson.Value -> Either String (RegFile rs)
      regFileToEncoding :: RegFile rs -> Aeson.Encoding

From `keiki` (per EP-36 §7):

    class CanonicalTypeName a where
      canonicalTypeName :: Proxy a -> Text

    class KnownRegFileShape (rs :: [Slot]) where
      regFileShapeHash :: Proxy rs -> Text

These are the only new symbols keiro consumes from this plan.

### Interfaces produced

This plan does not introduce new keiro public types. The `StateCodec (s, RegFile
rs)` shape was already declared in keiro EP-1 (`docs/research/06-command-cycle-design.md`
§4) and EP-4 (`docs/research/09-snapshot-strategy.md` §3). M2 implements them
against the upstream primitives; the shapes are unchanged.


## References

- This ExecPlan: `docs/plans/9-integrate-keiki-codec-json-into-keiro-snapshot-path.md`
- Upstream MasterPlan:
  `/Users/shinzui/Keikaku/bokuno/keiki/docs/masterplans/11-keiki-codec-json-package-implementation-and-rollout.md`
- Upstream implementation plan (EP-36):
  `/Users/shinzui/Keikaku/bokuno/keiki/docs/plans/36-regfile-json-codec-and-shape-hash-for-snapshot-persistence.md`
- Driving keiro requirement: `docs/research/11-upstream-roadmap.md` §7.1, §7.2.
- Consuming keiro design: `docs/research/09-snapshot-strategy.md` §3, §6, §15.
- Validation context (the 2026-05-09 SymTransducer-vs-Decider audit confirming
  contract-orthogonality of this work): `docs/masterplans/1-keiro-research-foundation.md`
  Surprises & Discoveries entry of 2026-05-09.
