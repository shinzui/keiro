---
id: 139
slug: validate-codecs-and-deprecated-event-replayability-at-the-stream-boundary
title: "Validate codecs and deprecated-event replayability at the stream boundary"
kind: exec-plan
created_at: 2026-07-23T04:18:42Z
intention: intention_01ky7q57fbevsszaj32g77f6vt
master_plan: "docs/masterplans/24-close-the-evolution-and-replayability-gate-gaps-surfaced-by-the-2026-07-evolution-review.md"
---

# Validate codecs and deprecated-event replayability at the stream boundary

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

keiro has a codec validator that would catch real, shipped-today misconfigurations —
duplicate upcaster rungs, chain gaps, duplicate tags — and nothing calls it. `mkCodec`
(`keiro-core/src/Keiro/Codec.hs:142-165`) has zero production call sites; every stream,
including all DSL-generated ones, builds its `Codec` with the raw record constructor. The
July 2026 evolution review proved two *reachable* DSL evolutions that generate
mkCodec-rejectable codecs and pass every existing gate: bump two events in one release and
one of the two upcasters silently never runs (first `lookup` match wins); bump one event
twice across two releases and a chain rung vanishes, so every v1-stamped payload of every
kind fails `GapInUpcasterChain` at hydration — with both deploys reported ADDITIVE by
`diff`. Separately, "deprecated" does not mean "replayable": removing (or re-pointing) the
transition that emits an event passes `check`, `diff`, the harness, and
`mkEventStreamOrThrow`, and then the first command on any live stream containing that event
fails `HydrationNoInvertingEdge` — and `diff`'s removal message actively *recommends* that
unsound path.

After this plan: `mkEventStream` (via `validateEventStreamWith`) runs `mkCodec` over the
stream's event codec, so a duplicate-rung or vanished-rung codec fails loudly at startup
instead of corrupting or blocking streams in production; the DSL validator refuses to
*generate* those codecs in the first place (duplicate upcaster sources across events →
error; a hole anywhere in the aggregate's 1..max-1 rung range → error) and warns when an
event is deprecated on a non-terminal aggregate, with honest guidance; `diff` stops calling
deprecation ADDITIVE and stops recommending the unsound removal path; and genuine
old-version payloads are checked in as golden fixtures and decoded through the current
chain in CI.

You can see it working by feeding the two poisoned codec shapes to
`mkEventStreamOrThrow` (they now throw at construction with a codec-config reason), by
running `keiro-dsl check` on the new fixture specs (each is refused with a machine-readable
code), and by watching the golden-payload decode test fail if anyone breaks the upcaster
chain for a stored v1 payload.


## Progress

- [x] (2026-07-23T17:03:52Z) M1: `validateEventStreamWith` runs `mkCodec`; duplicate-rung and vanished-rung codecs fail at `mkEventStreamOrThrow`; keiro tests green; CHANGELOG entry.
- [x] (2026-07-23T17:13:55Z) M2: `retiring event` marker (grammar/parser/pretty-print); DSL validator rules `DuplicateUpcasterSource`, `UpcasterChainGap`, `DeprecatedEventReplayHazard`, `EventRetirementInProgress` implemented with fixture specs; `keiro-dsl-test` green.
- [ ] M3: diff deprecation reclassified to advisory-with-warning; `Diff.hs:404` message fixed; diff tests (incl. the 830-835 assertion) updated; golden old-payload fixture format defined and the conformance-v2 decodeRaw golden test green; all 24 keiro-dsl suites green.
- [ ] Close-out: master plan 24 boxes ticked; externally visible contracts recorded in this Decision Log for plan 141 to quote; ADR distillation pass done.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The focused pre-implementation test run supplied the intended red evidence: 16
  `mkEventStream` examples produced three failures (duplicate source, incomplete chain,
  and the throwing constructor), while the unchecked-constructor example already passed.
  After wiring `mkCodec` into the shared validator, the same 16 examples passed, followed
  by the full `keiro-test` and `keiro-dsl` acceptance run (346 and 214 examples
  respectively, zero failures).
- Plan 143 had already landed the native `replay-only` transition before this plan began.
  That makes `deprecated` plus replay-only the safe post-cutover shape, rather than a
  hazard: the focused DSL suite now has 223 passing examples, and manual CLI checks prove
  duplicate/gap fixtures exit 1 while retiring, hazardous deprecated, and replay-safe
  deprecated fixtures exit 0 with distinct machine-readable warnings.


## Decision Log

- Decision: `mkCodec` runs inside `validateEventStreamWith` (so every constructor path —
  `validateEventStream`, `mkEventStream`, `mkEventStreamWith`, `mkEventStreamOrThrow` —
  inherits it), surfacing `CodecConfigError` as an `EventStreamWarning`;
  `mkEventStreamUnchecked` remains the only bypass.
  Rationale: The boundary already exists and is already mandatory for command runners
  (`ValidatedEventStream`); adding a second entry point would leave the generated code
  (`mkEventStreamOrThrow` at `keiro-dsl/src/Keiro/Dsl/Scaffold.hs:1683-1686`) unprotected.
  A warning (which fails construction — every warning does at this boundary) rather than a
  new error channel keeps the API shape unchanged.
  Date: 2026-07-23

- Decision: Deprecating an event on a non-terminal aggregate without a replay-only
  emitting transition is a *Warning* (`DeprecatedEventReplayHazard`), not an Error.
  Deprecation with a replay-only emitter is the replay-safe cutover and instead warns
  `EventRetirementInProgress`, reminding operators to retain the edge until old payloads
  no longer need hydration.
  Rationale: The validator sees one spec and cannot know whether live streams still contain
  the event. An Error would block the legitimate endgame, while treating the native
  replay-only edge as a hazard would contradict ADR 0002. The diff side gets the matching
  advisory at the moment the cutover is introduced.
  Date: 2026-07-23

- Decision (reconciled with ADR 0002 after plan 143 landed first): retirement has two
  safe stages. `retiring event` is the pre-cutover marker and requires the original live
  emitting transition. The cutover is `deprecated event` plus an equivalent
  `replay-only` emitting transition; the event then leaves the write path without losing
  its inverting edge. That replay-only edge remains until affected streams are terminal,
  truncated, or pass the replay audit.
  Rationale: `deprecated` has one clear documented invariant ("retired from the write
  path"), which the validator, differ, and existing specs rely on. Replay-only emission
  does not relax that invariant because such an edge cannot execute forward. A separate
  `retiring` marker keeps the pre-cutover invariant equally sharp. The drop-emit
  half-measure remains unsound and is refused by the forced `StateChangingEpsilon`
  boundary check.
  Date: 2026-07-23

- Decision: The sanctioned retained-edge shape (recorded for plan 141 and the generated
  guidance to quote): the retained emitting transition must remain *statically reachable*
  with a guard that is not literally false. keiki's default dead-edge check is enabled at
  the durable boundary and every enabled warning fails construction, so a retained edge on
  an orphaned state, or one guarded by a literal-false predicate, is rejected at startup
  as `PossiblyDeadEdge`; the check is structural reachability plus a literal-bottom test
  with no false positives (`keiki/src/Keiki/Core.hs:1888-1891`; defaults with
  `checkReachability = True` at `Core.hs:1853-1864`), so a *guarded-but-inert* edge — one
  whose guard reads command data that operations simply never send any more (a legacy-only
  command constructor or flag) — passes validation and is the sanctioned way to keep an
  event emitting-capable while effectively retired from live traffic.
  Rationale: The retirement window needs a shape that is simultaneously replay-sound
  (inverting edge present), gate-clean (not statically dead), and operationally inert;
  guard-on-command-input is the only shape meeting all three under the current checks.
  Date: 2026-07-23
  SUPERSEDED 2026-07-23 by plan 143 (landed second-to-none: plan 143 landed first, so
  this plan performs the reconciliation): keiki now has a native `ReplayOnly` edge mode
  and the DSL a `replay-only` transition marker (docs/adr/0002). The sanctioned
  retained-edge shape is a `replay-only` transition — replay-only transitions are exempt
  from `DeprecatedEventStillEmitted` (they are not the write path), forward-unreachable
  by definition rather than by phantom guard, and already dead-edge-clean. This plan's
  validator/diff work should prescribe `replay-only` in its guidance text and treat the
  guarded-but-inert shape as the legacy fallback for hand-written machines only.

- Decision: Landing order with plan 140 (which rewrites the upcaster lowering to a
  per-rung, per-event dispatch): this plan's `DuplicateUpcasterSource` error is correct for
  the current `const`-based lowering and lands first; plan 140 is soft-dependent on this
  plan and relaxes that one rule when its dispatch lowering makes same-version multi-event
  upcasts sound. Recorded in both plans (master plan 24's dependency graph requires the
  choice recorded in both Decision Logs).
  Rationale: EP-2 before EP-3 is the master plan's suggested CI order; the boundary check
  plus validator must never be looser than the code generator's real semantics at any
  intermediate commit.
  Date: 2026-07-23

- Decision: Golden old-payload fixtures are plain JSON files at
  `keiro-dsl/test/golden-payloads/<context>/<Aggregate>/<EventName>.v<N>.json`, containing
  exactly the stored payload JSON as written at version N; version and event type are
  encoded in the path, mirroring `decodeRaw`'s inputs.
  Rationale: `decodeRaw codec (EventType tag) version payload`
  (`keiro-core/src/Keiro/Codec.hs:247-254`) is the exact decode entry the fixture must
  exercise; a self-describing path keeps the fixture format free of envelope invention.
  Plan 140 consumes the same format from the generated harness (its scaffold `--goldens`
  option) — the format is shared by path convention, and this plan owns defining it.
  Date: 2026-07-23

- Decision: The multi-event bump guidance (carried by `DuplicateUpcasterSource`) is: when a
  second event changes shape in the same or a later release, assign it version
  aggregate-max+1 (not its own previous version +1) and declare `upcast from` that new
  source.
  Rationale: Schema-version stamps are aggregate-global
  (`encodeForAppendWithMetadata`, `keiro-core/src/Keiro/Codec.hs:192-228`, stamps the
  codec's single `schemaVersion` = the aggregate's max event version), so per-event version
  numbers are only meaningful when aligned to the aggregate's version sequence. Analysis
  during plan authoring (from the verified stamping code) shows the misaligned bump is
  doubly unsound: besides the duplicate rung, old-shape payloads of the second event stored
  while the aggregate was already at the higher version are stamped *current* and would
  never be migrated at all. The guidance text names both consequences.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation. At completion, feed the evolution-gate
inventory rows this plan changes — what is now caught where — into the candidate ADR named
by master plan 24.)


## Context and Orientation

This repository (`/Users/shinzui/Keikaku/bokuno/keiro`) contains the keiro runtime.
Packages relevant here: `keiro-core` (pure contracts — `Keiro.Codec`,
`Keiro.EventStream`, `Keiro.EventStream.Validate`), `keiro` (the Postgres runtime and its
test suite), and `keiro-dsl` (the `.keiro` spec toolchain: `Keiro.Dsl.Validate` is the
single-spec checker behind `keiro-dsl check`; `Keiro.Dsl.Diff` is the cross-spec differ
behind `keiro-dsl diff --since <git-ref>`; `Keiro.Dsl.Scaffold` emits generated Haskell;
`Keiro.Dsl.Harness` emits a generated assertion module).

Architectural ground truth. keiki (the pure state-machine library at
`/Users/shinzui/Keikaku/bokuno/keiki`) uses one transducer for forward stepping and
replay, but ADR 0002 adds a `ReplayOnly` edge mode that is excluded from forward
execution and included during inversion. Replay re-inverts each stored event to a command;
when no live or replay-only edge's first output can reconstruct the stored event, replay
fails and keiro surfaces it as
`HydrationNoInvertingEdge` (`keiki/src/Keiki/Core.hs:1191-1203`;
`keiro/src/Keiro/Command.hs:457-462`). There is no lenient replay API — an event without an
inverting edge is unreplayable, full stop. Upcasters run at decode-time forever: hydration
(`keiro/src/Keiro/Command.hs:410`), the workflow journal
(`keiro/src/Keiro/Workflow.hs:690`), and the versioned pgmq job codec
(`keiro-pgmq/src/Keiro/PGMQ/Codec.hs:85-106`) all decode through the chain on every read,
and no stored-data migration exists. Upcasters also cannot re-tag an event: `decodeRaw`
passes the original stored tag to `decode` (`keiro-core/src/Keiro/Codec.hs:247-254`), so
"migrate old event A into new event B" is not expressible at decode time.

The unused validator. `mkCodec` (`keiro-core/src/Keiro/Codec.hs:142-165`) checks: schema
version ≥ 1, no duplicate event-type tags, no duplicate upcaster source versions, sources
in range `[1, schemaVersion)`, and chain completeness (`missingSources` — every version
`1..schemaVersion-1` present). Its only call sites are its own module and the codec unit
tests at `keiro/test/Main.hs:609-616`. `validateEventStreamWith`
(`keiro-core/src/Keiro/EventStream/Validate.hs:101-113`) currently composes exactly three
things — `snapshotWarnings`, `initialSnapshotEncodeWarnings`, and keiki's
`validateTransducer` — and never reads `eventCodec`. The generated code path is
`mkEventStreamOrThrow` (`Validate.hs:156-170`), and generated codecs are raw record
literals (`Scaffold.hs:1529-1543`; checked-in example
`keiro-dsl/test/conformance-v2/Generated/HospitalCapacity/Reservation/Codec.hs:40-51`).

The two reachable generated-codec bugs (verified during master plan 24's review). (a) Two
events bumped to v2 in one release, each declaring `upcast from v1`: `upcasterEntries`
(`Scaffold.hs:1558-1563`) yields two `(1, …)` pairs and `upcastersExpr` (1565-1567) emits
both; `migrateToCurrent` resolves rungs with `Prelude.lookup`
(`keiro-core/src/Keiro/Codec.hs:276`) so the first match wins and the second event's
upcaster silently never runs. `mkCodec` would reject this exact shape as
`CodecDuplicateUpcasterSources`. (b) An event bumped v2→v3 in a later release: the grammar
stores a single `evUpcastFrom :: Maybe (Int, Hole)`
(`keiro-dsl/src/Keiro/Dsl/Grammar.hs:316`), so declaring `upcast from v2` *replaces* the
v1 rung; every v1-stamped payload of every kind then fails `GapInUpcasterChain`
(`Codec.hs:277-280`) at hydration. Both evolutions are reported ADDITIVE because `diff`
only compares adjacent spec pairs — its version check (`Diff.hs:371-397`) accepts any
single-step bump with a matching upcaster, and its test suite pins exactly that
(`keiro-dsl/test/Main.hs:814-816` catches only the *same-deploy* v1→v3 jump). The DSL
validator's only chain rule is per-event contiguity — `versionUpcasterRule`
(`keiro-dsl/src/Keiro/Dsl/Validate.hs:1447-1453`) requires `upcast from v(N-1)` on a
version-N event and nothing else.

Deprecation vs replayability. The grammar marks an event `deprecated` (decode arms stay;
`evDeprecated`, `Grammar.hs:320-323`); the validator forbids *emitting* one
(`deprecatedEmitRule`, `Validate.hs:1456-1462`); the scaffolder has no deprecated-specific
handling at all (edges come only from transitions), so the moment the emitting transition
is removed or re-pointed at a replacement event, the machine simply has no inverting edge
for the stored payloads — and nothing notices until the first command on an affected live
stream. `diff` classifies deprecation ADDITIVE ("event deprecated (still decodable)",
`Diff.hs:457-459` — decodable, yes; replayable, no) and its removal message recommends the
unsound path verbatim: "event removed entirely; keep it as a 'deprecated event' so old
payloads still decode" (`Diff.hs:404`). The diff test at `keiro-dsl/test/Main.hs:830-835`
asserts deprecation is non-breaking. The first safe retirement stage keeps the live
transition *with* its emit — the event remains fully replayable — and this plan gives
that state a first-class marker (`retiring`, M2). The second safe stage, available because
plan 143 landed first, marks the event `deprecated` and changes the emitting transition
to `replay-only`; this obeys `DeprecatedEventStillEmitted` because replay-only edges are
not the write path while preserving the inverting edge required by old payloads.
The drop-emit half-measure *is* caught loudly today: keeping the transition but dropping
its emit produces a state-changing output-free edge, which the always-forced
`StateChangingEpsilon` check refuses at startup (`keiki/src/Keiki/Core.hs:2141-2166`;
forced at `keiro-core/src/Keiro/EventStream/Validate.hs:116-121`); the repo fixture
`keiro-dsl/test/fixtures/reservation-deprecated.keiro` is exactly this shape (its `Held --
ConfirmReservation -->` transition writes and moves state with no emit) — that loud
refusal is what makes the keep-emitting prescription safe to attempt, because the
tempting half-measure cannot ship. Two adjacent facts shape the sanctioned retained-edge
form: keiki's dead-edge check is on by default (`checkReachability = True`,
`keiki/src/Keiki/Core.hs:1853-1864`) and every enabled warning fails construction at the
durable boundary, so a retained legacy edge made *statically* unreachable (orphaned
source state, literal-false guard) is rejected at startup as `PossiblyDeadEdge`; the
check is structural reachability plus a literal-bottom test with no false positives
(`Core.hs:1888-1891`), so a guarded-but-inert edge — guard over command input that
operations no longer send — passes and stays replay-capable. Masking: a covering
snapshot defers the hydration failure until any snapshot miss, which makes the
detonation *later and rarer*, not absent.

Ownership boundaries from master plan 24 (Integration Points): this plan owns
`keiro-core/src/Keiro/EventStream/Validate.hs`, `keiro-core/src/Keiro/Codec.hs`, and —
within keiro-dsl — `Validate.hs` plus the *deprecation and upcaster-chain* rules in
`Diff.hs`. Plan 138 adds one unrelated advisory (`AggFoldSurfaceChanged`, transition
surface) to `Diff.hs` and one enum constructor to `Validate.hs`'s `DiagnosticCode`; plan
140 owns `Scaffold.hs`/`Harness.hs`. Each plan adds distinct top-level functions and
distinct enum constructors, so merges stay textual-conflict-free. Conformance fixtures
regenerate once per landed plan; the 24-suite keiro-dsl green bar is the shared acceptance
floor.

Relevant ADRs: `docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md`
defines the native replay-only edge used by the retirement cutover. ADR 0001 is unrelated.

Term definitions. "Rung" — one `(sourceVersion, migration)` entry in a codec's `upcasters`
list; reading a version-n payload applies rungs n, n+1, … up to the current version.
"Stamp" — the `schemaVersion` integer written into event metadata on append; it is
aggregate-global (the codec's single `schemaVersion`), not per-event. "Live stream" — a
stream a service will hydrate again (non-terminal, or terminal but still receiving reads
that can miss the snapshot). "Golden payload" — a checked-in copy of a stored payload
exactly as an old binary wrote it, used to prove today's chain still decodes it.


## Plan of Work

### Milestone 1 — run mkCodec at the stream boundary

Scope: `keiro-core` grows one validation component; the two poisoned codec shapes become
startup failures. At the end, no stream — hand-written or generated — can be constructed
through the validated path with a misconfigured codec.

Edit `keiro-core/src/Keiro/EventStream/Validate.hs`. Add a private
`codecConfigWarnings :: Text -> EventStream phi rs s ci co -> [EventStreamWarning]` that
runs `Keiro.Codec.mkCodec (eventCodec es)` and, on `Left err`, yields one warning with
`eswReason = "event codec misconfigured: " <> <rendered err>` — render each
`CodecConfigError` constructor (`Codec.hs:125-131`) into a specific human sentence
(duplicate sources must name the versions; the incomplete chain must name the missing
versions and the target). Compose it into `validateEventStreamWith` (lines 108-113)
alongside `snapshotWarnings` — this automatically covers `validateEventStream`,
`mkEventStream`, `mkEventStreamWith`, and `mkEventStreamOrThrow`.
`mkEventStreamUnchecked` (lines 178-181) remains the bypass; extend its haddock to name
codec validation among the skipped checks. Update the module header's enumeration of what
validation covers.

Tests in `keiro/test/Main.hs` (the keiro suite already exercises this boundary and has the
codec fixtures): under the existing validation describe group, add examples asserting that
(a) a codec with `schemaVersion = 3, upcasters = [(1,…),(1,…)]` (the duplicate rung — reuse
the shapes from lines 609-616) makes `mkEventStream` return `Left` with a reason mentioning
"duplicate" and version 1; (b) `schemaVersion = 3, upcasters = [(2,…)]` (the vanished v1
rung) returns `Left` naming missing version 1; (c) `mkEventStreamOrThrow` on shape (b)
throws with the label in the message; (d) `mkEventStreamUnchecked` still accepts both
(pinning the escape hatch). Also confirm no existing fixture stream in `keiro-test`,
`jitsurei`, or the keiro-dsl conformance suites fails the new check — they should all be
well-formed already; if one is not, that is a real latent bug: fix the fixture and record
it in Surprises & Discoveries.

Write the CHANGELOG entry (repo `CHANGELOG.md`, Unreleased): behavior change — stream
construction now fails on mkCodec-invalid codecs; `mkEventStreamUnchecked` is the
documented bypass.

Acceptance: from `/Users/shinzui/Keikaku/bokuno/keiro`, `cabal test keiro-test` green with
the new examples; `cabal test keiro-dsl` green (proves generated fixtures pass the
boundary check).

### Milestone 2 — DSL validator rules that refuse to generate the poison, plus the `retiring` marker

Scope: `keiro-dsl check` refuses duplicate upcaster sources and chain gaps; the grammar
gains a `retiring event` marker so the safe retirement state is expressible; and
deprecation of an event on a non-terminal aggregate warns with honest guidance — each with
a machine-checkable code and a fixture spec. This plan owns `Validate.hs` per the master
plan split (the `Grammar.hs`/`Parser.hs`/`PrettyPrint.hs` touches for the marker are
unowned by any sibling plan; keep them additive — a new `Event` field defaulting to
False — so plan 140's `Scaffold.hs`/`Harness.hs` work is unaffected: retiring events
scaffold as ordinary live events, which is exactly their semantics).

First, the marker. In `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, add `evRetiring :: !Bool` to
`Event` (haddock: "Retirement in progress: the event MUST keep at least one emitting
transition — it stays fully live and replayable — while operators terminalize or truncate
the streams that contain it; flip to `deprecated` only afterwards."). In `Parser.hs`'s
`pEvent` (around line 478), accept `retiring` in the same leading-keyword position as
`deprecated` (`retiring event Foo …`); reject both markers on one event with a parse
error. Update `PrettyPrint.hs` to round-trip the keyword, and every `Event` construction
site the compiler flags.

Add four `DiagnosticCode` constructors in `keiro-dsl/src/Keiro/Dsl/Validate.hs` (append in
the evolution block near `EvtVersionMissingUpcaster`, lines 48-55):
`DuplicateUpcasterSource`, `UpcasterChainGap`, `DeprecatedEventReplayHazard`,
`EventRetirementInProgress`. Implement the rules next to the existing `evolutionRules`
(lines 1441-1462), leaving `DeprecatedEventStillEmitted` exactly as it is (deprecated
still means off-the-write-path; see the Decision Log reconciliation entry):

*Duplicate source (Error).* Group `[(m, evName e) | e <- aggEvents agg, Just (m, _) <-
[evUpcastFrom e]]` by `m`; any group with two or more events yields an error at each later
event's location: "events '<A>' and '<B>' both declare 'upcast from v<m>'; the generated
chain keys rungs by source version, so only one upcaster would run. Give the later-changed
event version v<max+1> (the aggregate's next version), not its own previous version + 1 —
aggregate-global schema stamps also mean a same-version re-shape of '<B>' would leave its
old payloads stamped current and never migrated." (The guidance wording is a contract for
plan 141 to quote; keep it stable.)

*Chain gap (Error).* With `maxV = maximum (1 : map evVersion (aggEvents agg))` (the
existing `maxEventVersion` binding) and `sources = {m | Just (m,_) <- evUpcastFrom}`: every
version in `1..maxV-1` absent from `sources` yields an error naming the missing rung and
its consequence: "no event declares 'upcast from v<m>'; stored payloads stamped v<m> can
never reach v<maxV> (GapInUpcasterChain at hydration). A rung, once shipped, must exist
forever — restore the upcaster for v<m> (re-declare it on the event whose shape changed at
v<m>+1)." Note the interaction: the grammar's single-valued `evUpcastFrom`
(`Grammar.hs:316`) means an event cannot yet declare two historical rungs — until the
grammar grows multi-rung support (plan 140's dispatch lowering is where multi-rung becomes
expressible; see the Decision Log's landing-order entry), the practical remedy the message
gives is correct: the vanished rung's upcaster must remain declared. This rule is what
turns the silent cross-release regression into a check-time refusal.

*Retirement in progress (Error + Warning pair).* A `retiring` event with no *live*
emitting transition is an Error (reuse the retirement code with an "either keep it
emitting or cut over to `deprecated` plus replay-only" message). A `retiring` event with a
live emitting transition yields `EventRetirementInProgress`: keep the live emitter while
terminalizing/truncating affected streams, then flip to `deprecated` and retain an
equivalent replay-only emitter for as long as old payloads may be hydrated.

*Deprecation hazard (Warning).* For each `evDeprecated` event on an aggregate with a
non-terminal state and no replay-only emitting transition, emit
`DeprecatedEventReplayHazard`: the payload remains decodable but hydration fails with
`HydrationNoInvertingEdge`. If a replay-only emitter exists, emit
`EventRetirementInProgress` instead: the cutover is replay-safe, and the edge must remain
until every affected stream is terminal, truncated, or passes the replay audit. Both are
warnings, so `check` prints them and exits zero.

Fixture specs in `keiro-dsl/test/fixtures/`: `reservation-dup-upcast-source.keiro` (copy
`reservation-v2.keiro`, additionally bump `TransferReservationConfirmed` to v2 with
`upcast from v1 = HOLE`), `reservation-chain-gap.keiro` (copy `reservation-v2.keiro`, move
`TransferReservationCreated` to v3 with only `upcast from v2 = HOLE`),
`reservation-retiring.keiro` (copy `reservation.keiro`, mark
`TransferReservationConfirmed` as `retiring` while its emitting `Held --
ConfirmReservation -->` transition stays), and reuse `reservation-deprecated.keiro` for
the hazard warning. Add `reservation-deprecated-replay-only.keiro` for the replay-safe
cutover. Tests in `keiro-dsl/test/Main.hs` follow the existing pattern
(match on codes, not prose): the two new Errors carry their codes and fail `check`; the
retiring fixture warns `EventRetirementInProgress` and passes `check` (exit zero); a
retiring event stripped of its emitting transition fails with the retirement Error; the
deprecated fixture yields `DeprecatedEventReplayHazard`, while deprecated plus
replay-only yields `EventRetirementInProgress` and no hazard; both pass `check`. A spec
marking one event both `retiring` and `deprecated` fails to parse. Also
assert `reservation-v2.keiro` itself stays clean — proving the rules do not fire on the
sound single-bump evolution — and that scaffolding `reservation-retiring.keiro` emits the
same modules as its unmarked twin (retiring is validator/diff surface only; the generated
machine keeps the event fully live).

Acceptance: `cabal test keiro-dsl-test` green; manual spot check from the repo root:

```bash
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/reservation-chain-gap.keiro
```

prints an `error[UpcasterChainGap]` line and exits non-zero.

### Milestone 3 — diff truthfulness and golden old-payload fixtures

Scope: `diff` stops blessing the hazard, its removal message stops recommending the
unsound path, and genuine old payloads are pinned in CI. This milestone covers this plan's
share of `Diff.hs` per the master plan split (deprecation + upcaster-chain rules).

Edit `keiro-dsl/src/Keiro/Dsl/Diff.hs`. In `sameVersionEventDiff`'s `deprecationChanges`
(lines 457-462): replace the `additive … "event deprecated (still decodable)"` arm with
the advisory selected from the new aggregate: `DeprecatedEventReplayHazard` when no
replay-only transition emits the event, or `EventRetirementInProgress` when such a
transition makes the cutover replay-safe. Add the retirement transitions to the same
function: live →
`retiring` yields an `advisory` with `EventRetirementInProgress` ("retirement started;
keep the emitting transition until affected streams are terminal or truncated");
`retiring` → live is a plain additive note (retirement abandoned); `retiring` →
`deprecated` yields the appropriate replay-safe or hazard advisory above. (Reuse the
validator's codes so tooling correlates the two surfaces.) In `removedEvents`
(lines 402-407): rewrite the detail from "keep it as a 'deprecated event' so old payloads
still decode" to "event removed entirely; its stored payloads can neither decode nor
replay. Deprecating instead restores decode-ability only — replay still fails on live
streams; truncate/terminalize affected streams as part of retirement (see
docs/guides/evolution-and-replayability.md)." Keep the classification Breaking with the
existing `EvtRemovedNotDeprecated` code. Add the cross-release chain rule (this plan's
"upcaster-chain" diff share): in `eventDiff`, when the new event's version increases by
exactly one *with* a matching upcaster (the currently-additive arm, lines 377-379), ALSO
check whether the *old* spec's event had `evUpcastFrom = Just (m, _)` that the new spec no
longer declares anywhere in the aggregate; if so, emit an additional `breaking` change
with code `UpcasterChainGap` and detail naming the vanished rung ("bumping v<old> to
v<new> replaced the 'upcast from v<m>' rung; stored v<m> payloads can no longer decode").
This makes the sequential-bump regression visible at diff time as well as check time.

Update the diff tests in `keiro-dsl/test/Main.hs`: the assertion at lines 830-835 changes
from "keeps deprecation additive" to: deprecation yields an `Advisory` with `ckCode = Just
DeprecatedEventReplayHazard` and no `Breaking`; un-deprecation keeps its existing
`EventUndeprecated` advisory. Add a fixture pair for the vanished-rung diff (old:
`reservation-v2.keiro`; new: `reservation-chain-gap.keiro` from M2) asserting a `Breaking`
with `Just UpcasterChainGap`, and a retirement pair (old: `reservation.keiro`; new:
`reservation-retiring.keiro`) asserting an `Advisory` with
`Just EventRetirementInProgress` and no `Breaking`.

Golden old-payload fixtures. Create the directory and first fixture:
`keiro-dsl/test/golden-payloads/hospital-capacity/Reservation/TransferReservationCreated.v1.json`
containing the genuine v1 payload shape (the wire shape before the v2 `triageNote` field
was added — `kind`, `reservationId`, `hospitalId`, `commandId`, `patientAcuity`,
`divertStatus`, `lifeCriticalOverride`, camelCase per the spec's wire clause, values
matching the harness's sample data so expectations stay readable):

```json
{
  "kind": "TransferReservationCreated",
  "reservationId": "rsv_01hzy3v7q2e8kaw2m5x0d41n9c",
  "hospitalId": "hosp_01hzy3v7q2e8kaw2m5x0d41n9d",
  "commandId": "cmd_01hzy3v7q2e8kaw2m5x0d41n9e",
  "patientAcuity": "red",
  "divertStatus": "open",
  "lifeCriticalOverride": true
}
```

Extend `keiro-dsl/test/conformance-v2/Main.hs` (an ordinary IO `main` that runs the
generated harness assertions): after the harness loop, read every
`test/golden-payloads/<ctx>/<Agg>/<Event>.v<N>.json` under the vertical's context, parse
the version and tag from the filename, and assert
`decodeRaw reservationCodec (EventType "<Event>") <N> <payload>` is `Right` — print
`PASS golden <Event>.v<N>` / `FAIL …` in the harness's output style and exit non-zero on
any failure. This is the *direct* decodeRaw test; making the generated `Harness.hs` itself
consume goldens is plan 140's milestone (coordinate strictly by the path convention in the
Decision Log — do not touch `Harness.hs` here). The fixture path is package-relative
(cabal runs test suites from `keiro-dsl/`), so open it as `test/golden-payloads/…`.

Regenerate conformance fixtures if any generated text changed in this plan (M1-M3 change
no scaffolder output, so expect none; verify with `git status` after a scaffold re-run of
the v2 vertical):

```bash
cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/reservation-v2.keiro \
  --out keiro-dsl/test/conformance-v2
```

Acceptance: all 24 keiro-dsl suites green (`cabal test keiro-dsl` from the repo root runs
every suite of the package; the individual names are the `test-suite` stanzas in
`keiro-dsl/keiro-dsl.cabal`); the golden decode line appears in
`keiro-dsl-conformance-v2` output; mutation check — temporarily empty the `upcasters`
list in the checked-in
`conformance-v2/Generated/HospitalCapacity/Reservation/Codec.hs`, re-run the v2 suite, and
watch the golden test fail with a chain error; revert.

Close-out: tick master plan 24's two EP-2 progress boxes, update the registry row, and run
the ADR distillation pass (the gate-inventory ADR rows: duplicate rung — caught at check
and startup; vanished rung — caught at check, diff, and startup; deprecation — warned at
check, advised at diff).


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/keiro`.

```bash
# M1
cabal build keiro-core keiro
cabal test keiro-test

# M2
cabal build keiro-dsl
cabal test keiro-dsl-test
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/reservation-dup-upcast-source.keiro ; echo "exit: $?"
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/reservation-chain-gap.keiro ; echo "exit: $?"
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/reservation-retiring.keiro ; echo "exit: $?"
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/reservation-deprecated.keiro ; echo "exit: $?"

# M3
cabal test keiro-dsl          # all 24 suites
cabal test keiro-dsl-conformance-v2
```

Expected transcript shapes: the two poisoned `check` runs print one
`error[DuplicateUpcasterSource]` / `error[UpcasterChainGap]` line each and echo
`exit: 1`; the retiring fixture prints `warning[EventRetirementInProgress] …` and echoes
`exit: 0`; the deprecated fixture prints `warning[DeprecatedEventReplayHazard] …` and
echoes `exit: 0`; `keiro-dsl-conformance-v2` output ends with the harness PASS lines plus
`PASS  golden TransferReservationCreated.v1`.

Red-then-green checkpoints: write the M1 duplicate-rung boundary test before touching
`Validate.hs` and watch it fail (construction currently succeeds); write the M3 golden
test before creating the fixture and watch it fail to find files. Record both in
Surprises & Discoveries with the failing output.


## Validation and Acceptance

Acceptance is behavioral. (1) Constructing a stream whose codec has upcasters
`[(1,f),(1,g)]` at `schemaVersion 3` via `mkEventStream` returns `Left [EventStreamWarning
…"duplicate"…]`; via `mkEventStreamOrThrow` it throws with the stream label in the
message; via `mkEventStreamUnchecked` it still constructs. (2) The same for `[(2,f)]`
(missing rung 1), with the message naming version 1. (3) `keiro-dsl check` refuses the two
poisoned fixture specs with the exact codes, warns-and-passes the retiring fixture,
refuses a retiring event without an emitting transition, and accepts
`reservation-v2.keiro` unchanged. (4)
`diffFixtures "test/fixtures/reservation.keiro" "test/fixtures/reservation-deprecated.keiro"`
yields an Advisory carrying `DeprecatedEventReplayHazard` and no Breaking, while the
replay-only cutover fixture carries `EventRetirementInProgress` and no hazard; the
removal message for a dropped event no longer contains the words "so old payloads still
decode".
(5) The checked-in v1 golden payload decodes through the current chain in
`keiro-dsl-conformance-v2`, and breaking the chain makes that suite fail. (6) The full
24-suite keiro-dsl bar and `keiro-test` are green.


## Idempotence and Recovery

All steps are additive code and fixtures; re-running builds, checks, and scaffolds is
safe. The one behavior change with rollout risk is M1: a *deployed* service with a latent
misconfigured codec would stop starting after upgrading keiro. That is the intended
fail-fast, but the recovery path must be documented in the CHANGELOG entry: fix the codec
(restore the missing rung / deduplicate sources) — or, for emergency forensics only,
construct via `mkEventStreamUnchecked`. If M3's diff reclassification breaks a downstream
consumer that grepped for the old ADDITIVE line, the machine-readable code
(`DeprecatedEventReplayHazard`) is the stable interface going forward. Landing order with
plan 140 is recorded in the Decision Log; if plan 140 lands first instead, re-run this
plan's M2 against the new dispatch lowering and adjust the `DuplicateUpcasterSource`
severity in the same commit that adjusts the lowering (never leave the validator looser
than the emitted code's semantics).


## Interfaces and Dependencies

At the end of M1, `keiro-core/src/Keiro/EventStream/Validate.hs` contains (private):

```haskell
codecConfigWarnings :: Text -> EventStream phi rs s ci co -> [EventStreamWarning]
```

composed into `validateEventStreamWith`; no public signature changes. At the end of M2,
`Keiro.Dsl.Grammar.Event` has field `evRetiring :: !Bool` (parsed from `retiring event`,
round-tripped by the pretty-printer, mutually exclusive with `deprecated`), and
`Keiro.Dsl.Validate.DiagnosticCode` has constructors `DuplicateUpcasterSource`,
`UpcasterChainGap`, `DeprecatedEventReplayHazard`, `EventRetirementInProgress` (the last
two also consumed by `Diff.hs` in M3). At the end of M3, the golden fixture convention
`keiro-dsl/test/golden-payloads/<context>/<Aggregate>/<EventName>.v<N>.json` exists with
the first fixture, and `conformance-v2/Main.hs` decodes every golden through
`Keiro.Codec.decodeRaw :: Codec e -> EventType -> Int -> Value -> Either CodecError e`.

Dependencies: no new packages. Coordination: plan 138 (one `DiagnosticCode` constructor +
one Diff rule, disjoint), plan 140 (consumes the golden path convention from its generated
harness; relaxes `DuplicateUpcasterSource` when its dispatch lowering lands — soft
dependency EP-3→EP-2 in master plan 24's registry), plan 142 (adds its own disjoint
`Diff.hs` share — decide-surface advisories — and owns the *replay* half of old-log
safety: this plan's golden fixtures prove old payloads still *decode* through
`decodeRaw`; whether they still *invert* through the current transducer against real
stream histories is the pre-deploy replay audit of
docs/plans/142-add-a-pre-deploy-replay-audit-and-decide-surface-change-advisories.md,
not a gap in this plan). Companion guide:
`docs/guides/evolution-and-replayability.md` documents the operator-facing retirement
procedure this plan's messages point at; plan 141 owns all user-doc edits and will quote
this plan's Decision Log wording.


## Revision Note

- 2026-07-23: Reconciled M2 and M3 with ADR 0002 after plan 143 landed before this
  plan. The native `replay-only` transition is now the sanctioned post-cutover
  inverting edge; deprecation is hazardous only when that edge is absent. This changes
  the implementation details without changing the plan's user-visible purpose.
