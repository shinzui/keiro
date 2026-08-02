---
id: 182
slug: ship-closed-named-and-diagnosable-generated-runtime-apis-in-keiro-0-9
title: "Ship closed, named, and diagnosable generated runtime APIs in Keiro 0.9"
kind: exec-plan
created_at: 2026-08-02T04:56:03Z
intention: "intention_01kz0d81xaewwvq8b7avsbebf1"
---

# Ship closed, named, and diagnosable generated runtime APIs in Keiro 0.9

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The planned `0.9.0.0` release already breaks the generated Haskell API once
(ExecPlan 179 removes the generated `Expressions` module).  A 2026-08-01 audit
of every generated module kind found a second family of problems that are
wire-neutral — no JSON byte, fold fingerprint, or replay behavior changes —
but that make generated services error-prone to operate and unpleasant to
read: stringly-typed disposition tables whose typos silently become retries,
exported witness names that are hex soup, decode failures that name no
offending value, generated files that do not say which language produced them,
and output that contradicts the repository's own formatter.  Because they are
API-breaking at the Haskell level, deferring them past `0.9.0.0` means a
second breaking wave later; because they are wire-neutral, bundling them into
`0.9.0.0` costs consumers nothing beyond the migration they already face.

After this plan, a hand-written hole that names a workqueue disposition
misspells it as a compile error instead of a silent retry; an inbox
disposition carries the retry delay and dead-letter reason the spec declared;
a structural-projection witness is named `artifactInfoArtifactKeyWitness`
instead of `structuralProjectionC41Z...Witness`; a poison message's decode
failure names the unknown tag and the expected set; every generated file's
banner states the language version and generator version that produced it;
and the regenerated fixtures changed here pass the repository's Fourmolu
configuration untouched; converting every unrelated historical emitter is
tracked separately after validation found the repository-wide baseline is not
clean.  All implementation in this plan is provably representation-only: the
same wire-byte and fingerprint pins ExecPlan 179 establishes must hold through
every milestone here.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-08-02 12:10 PDT: Milestone 0 extended wire-byte and
  accepted/rejected-outcome invariance across the queue, inbox, contract, and
  event-codec conformance suites while retaining the aggregate
  fold-fingerprint pin.  All five focused compiled suites passed.
- [x] 2026-08-02 12:23 PDT: Milestone 1 replaced stringly queue outcomes and
  lossy inbox acknowledgements with closed generated outcome/disposition
  types, covered every live `InboxResult` constructor, preserved runtime
  failure detail, regenerated affected fixtures through the scaffolder, and
  passed the unit, queue, inbox, contract, typed-contract, and full integration
  suites.
- [x] 2026-08-02 12:38 PDT: Milestone 2 replaced hex-mangled structural
  witness/type names with owner-and-path names, added deterministic
  collision-only suffix allocation, resolved transducer use sites through the
  same global table, migrated hand-owned fixture consumers, and passed the
  structural, scalar-expression, and behavior-complete suites.
- [x] 2026-08-02 12:59 PDT: Milestone 3 made every emitted unknown
  discriminator/tag failure name the offending value and complete expected
  set, moved custom object-field decoders onto Aeson's path-preserving parser
  boundary, regenerated the byte-current codec/contract fixtures, and passed
  the unit plus focused contract, aggregate, nominal, structural, behavior,
  workspace, skeleton, and new-surface suites.
- [ ] Milestone 4: provenance-stamped generated banners with migration-safe
  recognition of the legacy banner.
- [ ] Milestone 5: module hygiene — exports, warnings, formatter conformance,
  typed workflow facts, and concrete stream-category phantoms.
- [ ] Milestone 6: full regeneration, migration guide, and `0.9.0.0`
  changelog entries.
- [x] 2026-08-02 12:00 PDT: validated the plan against the clean `master`
  tree, the completed prerequisite milestones in ExecPlan 179, ADRs 0012,
  0015, 0016, 0017, and 0018, Mori-resolved Aeson/Kiroku sources, and the
  focused baseline suites.  The validation corrected the read-model,
  empty-sum, banner-version, category-phantom, and formatter assumptions
  before implementation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (pre-plan audit, 2026-08-01, spot-reverified against the current
  tree): the generated workqueue policy maps disposition strings with a silent
  catch-all — `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` emits
  `jobOutcomeFor :: Text -> JobOutcome` (near line 2987) whose final arm
  defaults to retry, so `jobOutcomeFor "storeFailur"` type-checks and retries
  instead of dead-lettering.  The inbox path drops declared detail the same
  way: `Just (IRetry _) -> "InboxRetry"` and `Nothing -> "InboxRetry"` (near
  line 2731) erase the spec's retry window and default missing lookups to
  retry.
- Discovery: witness name mangling is hex-per-character —
  `encodeIdentifier = T.concatMap (\c -> "C" <> hex (ord c) <> "Z")`
  (`Scaffold.hs`, near line 1870) — so the exported witness for
  `ArtifactInfo/artifact_key` is unreadable and ungreppable.  Wire identity
  does not depend on these names (it lives in field shape identifiers), so
  they are free to change.
- Discovery: decode failures are anonymous: `fail "unknown message type"`
  (contract discriminator, near line 2541), `fail "unknown event type"` (event
  codec, near line 3978), and enum/nominal equivalents name neither the
  offending value nor the expected set.
- Discovery (Milestone 3, 2026-08-02): decoding a field as `Value` with `.:`
  and then binding a custom parser loses the owning JSON key because the
  custom parser runs after Aeson's path annotation has completed.  The
  path-preserving form is `explicitParseField customParser object key`; text
  parsers additionally need `withText` at that boundary.  Evidence: the
  scalar-expression enum initially failed to typecheck when its `Text ->
  Parser a` parser was passed directly, and the structural diagnostic now
  reports `$.location.contents` rather than only the nested key.
- Discovery: seven generated module kinds carry
  `{-# OPTIONS_GHC -Wno-unused-top-binds #-}` partly to hide unexported
  generated bindings such as contract topic constants, which consumers then
  re-type by hand.
- Discovery: the generated banner is a single fixed line (`generatedBanner`,
  near line 5555) with no language version, generator version, or origin, and
  the repository's `fourmolu.yaml` (trailing commas) disagrees with the
  leading-comma export lists the emitters produce, so formatting the repo
  would churn "do not edit" files.
- Discovery (validation, 2026-08-02): `ReadModelNode` records registry,
  table, consistency, scope, and subscription facts, but no aggregate or
  event-codec source.  The representative read-model-only fixture therefore
  has no generated event type or codec that a typed dispatch shim could
  import.  Treating the free-text category scope as a codec authority would
  be an unchecked guess, contrary to this plan's closed/generated-API goal.
  Evidence: `keiro-dsl/src/Keiro/Dsl/Grammar.hs` fields `rmScope` and
  `rmFeed`, and `keiro-dsl/test/fixtures/readmodel-runtime.keiro`.
- Discovery (validation, 2026-08-02): the `emitSum []` branch is live, not
  dead.  The checked process fixtures deliberately contain saga and target
  aggregates with no commands or events and currently generate
  `data HospitalCommand = ()` and similar declarations.  The branch must be
  replaced by an explicit empty datatype, not deleted as unreachable.
- Discovery (validation, 2026-08-02): the plan's repository-wide Fourmolu
  command fails before this work.  It passes 245 generated files without
  `-XImportQualifiedPost`, so many files do not parse; after supplying the
  extension, numerous untouched module kinds still need formatting.  Making
  every historical emitter byte-conformant is a separate generator-wide
  rewrite, not a safe incidental step in this API plan.
- Discovery (validation, 2026-08-02): the pre-release tree still declares
  `keiro-dsl-0.8.0.0`.  A truthful banner must read the build's package
  version, producing `0.8.0.0` during this plan and naturally changing to
  `0.9.0.0` when ExecPlan 179 performs the coordinated version bump.
- Discovery (validation, 2026-08-02): `Keiro.Stream.StreamCategory a`
  supplies the phantom type of the `Stream a` it constructs.  Both process
  saga categories and aggregate target categories are currently polymorphic,
  so pinning only the process module would leave target-category mixups
  typable.  Both generated category surfaces must name their concrete raw
  event-stream definition types.
- Discovery (Milestone 1, 2026-08-02): live `InboxResult` has five constructors,
  not the four documented by the old emitter and Milestone 0 description.
  `InboxHandlerFailed !Text !Int`, added by the poison-message retry path, was
  absent from generated `inboxDisposition`, so the supposedly total runtime
  table had an incomplete pattern.  Evidence: `Keiro.Inbox.Types` and the
  pre-change four-arm `emitIntakeGen`.  The closed replacement now maps it via
  the declared `storeFailed` row and retains its reason and attempt count.


## Decision Log

Record every decision made while working on the plan.

- Decision: Bundle these wire-neutral but Haskell-API-breaking changes into
  the same coordinated `0.9.0.0` release as ExecPlan 179, and sequence
  implementation after 179's Milestone 3 (guarantee ledger closed, `Expressions`
  removal landed).
  Rationale: one breaking wave instead of two, one regeneration of every
  conformance tree instead of repeated churn, and no emitter merge conflicts
  with 179's inlining work, which edits the same functions in
  `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`.
  Date: 2026-08-01
- Decision: Stamp the banner with the effective language version and the
  keiro-dsl package version, plus the owning source node, but not the spec
  fold fingerprint.
  Rationale: language and generator provenance answer "which frontend wrote
  this file" — the question migrations actually ask — while a fingerprint in
  the banner would churn every generated file on every behavioral edit and
  duplicate a value the Transducer already exports.  This also keeps banner
  bytes stable across ExecPlan 181's later hash widening.
  Date: 2026-08-01
- Decision: Banner recognition (the generated firewall's overwrite check and
  the stale-report evidence introduced by ExecPlan 179) must accept both the
  legacy single-line banner and the new stamped banner.
  Rationale: every file scaffolded before `0.9.0.0` carries the legacy line;
  recognizing only the new form would make the scaffolder treat all existing
  generated files as hand-modified and refuse to regenerate them — breaking
  the exact migration `0.9.0.0` asks consumers to perform.
  Date: 2026-08-01
- Decision: Achieve formatter conformance by emitting fourmolu-conformant text
  directly, not by invoking fourmolu at scaffold time.
  Rationale: scaffolding must stay deterministic and dependency-free for
  consumers; a formatter subprocess would add a toolchain requirement and a
  version-drift axis.  The repository's own CI can still run fourmolu over
  committed fixtures as the conformance proof.
  Date: 2026-08-01
- Decision: Out of scope, listed here so they are not silently forgotten:
  the workqueue `required`-flag admission fix (optional fields decode as
  required — wire admission change), the `namedUuid` Unicode truncation fix
  (changes derived timer identities for non-ASCII correlation IDs), contract
  field type vocabulary growth (`bool`/`timestamp`), unifying the dual
  snapshot-versus-event JSON spellings of enums and nominal IDs, and
  closed-world (unknown-key-rejecting) decoding.  Each changes wire or
  identity semantics and needs its own gated plan in the ExecPlan 178/180
  lineage.
  Rationale: this plan's safety argument is precisely wire-byte invariance;
  mixing in admission changes would destroy the property every milestone here
  is validated against.
  Date: 2026-08-01
- Decision: Defer typed subscription read-model Hole dispatch until the
  language declares and validates the read model's aggregate/event-codec
  source; keep the existing honest `RecordedEvent` boundary in this plan.
  Rationale: the current semantic graph contains no source codec to select.
  Inferring one from `scope = category "..."` would turn a free-text runtime
  filter into an unvalidated type authority and cannot work for entire-log or
  read-model-only specifications.  Adding the missing declaration is a
  language-surface design with its own compatibility and evolution rules, not
  representation-only generator hygiene.
  Date: 2026-08-02
- Decision: Keep repository-wide direct Fourmolu emission out of this plan;
  format regenerated committed fixtures as repository artifacts and check the
  module kinds changed here with the required parser extension.  A follow-up
  generator-format plan must convert every emitter and add a byte-currentness
  gate before claiming all scaffold output is formatter-idempotent.
  Rationale: the validated baseline is neither parseable by the written
  command nor formatter-clean, and repairing 245 files across unrelated
  emitters would make the representation-invariance review materially less
  sound.
  Date: 2026-08-02
- Decision: Stamp provenance with the package version compiled into the
  running `keiro-dsl`, not a hard-coded future release number.
  Rationale: pre-release builds are currently `0.8.0.0`; claiming `0.9.0.0`
  before the coordinated release bump would make provenance false.  Reading
  the Cabal-generated version keeps identical binaries deterministic and lets
  ExecPlan 179's version bump update the stamp honestly.
  Date: 2026-08-02
- Decision: Pin both aggregate and process-manager stream categories to their
  concrete generated event-stream definition phantoms.
  Rationale: a process category alone protects its saga stream, while a
  polymorphic aggregate category still permits the wrong target category to
  unify with an expected target stream.  Both sides are required for the
  compile-time guarantee.
  Date: 2026-08-02
- Decision: Generate both a closed, intake-named classification type and a
  closed, intake-named detailed disposition type.  Keep
  `inboxDisposition :: InboxResult a -> ...` as the runtime bridge and expose
  `inboxDispositionFor` for all seven spec classifications.
  Rationale: `InboxResult` cannot represent decode/dedupe failures, while the
  spec table is deliberately complete across those handler boundaries.  Two
  closed layers make every declared row observable without inventing runtime
  constructors, and they eliminate the emitter's missing-row retry default.
  Re-exporting Shibuya's existing `RetryDelay` through `Keiro.Inbox.Types`
  gives generated applications the live retry type without a new direct
  package dependency.
  Date: 2026-08-02
- Decision: Name a structural projection from its root declaration and every
  normalized JSON-pointer segment (for example
  `ArtifactInfoArtifactKeyProjection` /
  `artifactInfoArtifactKeyWitness`).  When multiple paths normalize to the
  same stem, suffix every member of that collision group with the first eight
  hexadecimal digits of FNV-1a-64 over canonical owner plus pointer; only an
  actual digest collision receives a stable ordinal.
  Rationale: unsuffixed common names stay readable, colliding names remain
  deterministic regardless of declaration order, and the explicit final
  ordinal prevents the generator from ever emitting duplicate Haskell
  declarations.  Transducer references look the name up in `projectionSpecs`
  rather than reimplementing naming, keeping declarations and use sites one
  authority.
  Date: 2026-08-02


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)

Milestone 0 completed on 2026-08-02.  The queue payload is pinned to its exact
four-field JSON bytes and missing-field rejection; both contract messages are
pinned to exact bytes plus unknown-discriminator and missing-field rejection;
and the aggregate event is pinned to exact bytes plus known/unknown event-type
outcomes.  The inbox suite continues to exercise all four runtime result
constructors.  The focused queue, inbox, contract, typed-contract, and
aggregate suites all passed before generator changes.

Milestone 1 completed on 2026-08-02.  Queue policy modules now export a
queue-named sum such as `ReservationWorkOutcome` and a total
`jobOutcomeFor :: ReservationWorkOutcome -> JobOutcome`; the open `Text`
input and retry catch-all are gone.  Inbox modules now export all seven
declared classifications, a detailed disposition carrying the live
`RetryDelay`, declared dead-letter reason, and optional runtime failure
detail, plus a total bridge over all five live `InboxResult` constructors.
The exact queue wire bytes and all focused decode acceptance/rejection pins
remained green, confirming that the change is Haskell-API-only.

Milestone 2 completed on 2026-08-02.  The representative exported witness is
now `artifactInfoArtifactKeyWitness`; scalar and behavior fixtures similarly
use `limitsMinimumWitness` and `startPayloadDisplayLabelWitness`.  The old
`structuralProjectionC...` pattern is absent from source and tests.  A unit
fixture proves that `/foo-bar` and `/foo_bar` receive distinct stable
eight-hex suffixes while `/key` remains the unsuffixed
`artifactInfoKeyWitness`.  Structural, scalar-expression, and behavior
conformance remained green, proving that witness values and projection
semantics did not change.

Milestone 3 completed on 2026-08-02.  Contract discriminators and mapped
union tags are validated inside their owning Aeson field parser, while
generated/consumer nominals, mapped records, optional fields, and union
contents use `explicitParseField`.  Unknown values now render the rejected
value and stable complete expected set; the representative proofs cover
`$.messageType`, `$.tag`, `$.location.contents`, a root mapped enum, and an
out-of-band aggregate `EventType`.  Exact accepted wire bytes and all prior
rejection outcomes remained green.


## Context and Orientation

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` emits every generated module kind;
checked-in examples live under `keiro-dsl/test/conformance-*/Generated/`.
The kinds this plan touches: workqueue policy modules (`QueuePolicy.hs` under
`keiro-dsl/test/conformance-queue-runtime/`), inbox modules
(`conformance-intake-runtime/`), contract modules (`conformance-contract/`),
event codec modules (`Codec.hs` under `conformance/`), structural projection
modules (`StructuralProjections.hs` under `conformance-structural/`), process
modules (`conformance-process/`), workflow fact modules
(`conformance-workflow-full/.../WorkflowFacts.hs`), and aggregate event-stream
modules throughout the conformance trees.  A "hole" is a create-once
hand-written module the scaffolder generates as a stub and never overwrites;
workqueue hole authors are consumers of the generated API surface this plan
changes.

The specific defects, beyond the discoveries above: generated
`StreamCategory a` values in process and aggregate modules are unconstrained,
so any saga or target category composes with any stream type; `WorkflowFacts` is
`[(String, String)]` with pipeline stages packed into comma-joined strings;
the event-codec decode arms are single ~330-character applicative lines; the
live `emitSum []` arm renders the misleading `data X = ()`; and contract topic
constants are generated but unexported.  The read-model hole receives a raw
undecoded event (`applyTransferDecisions :: RecordedEvent -> Tx.Transaction
()`), but the current grammar does not name a source aggregate or codec, so a
truthful typed shim is deferred by the validated decision above.

Wire-byte invariance means: for every conformance fixture, the JSON bytes
produced by encoding sample events/jobs/messages, and accepted by decoding
them, are identical before and after each milestone; fingerprints and
fold surfaces are untouched (this plan edits no expression, fold, or
fingerprint machinery).  ExecPlan 179's Milestone 0 harness already pins
forward/replay behavior and fingerprints for aggregates; Milestone 0 here
extends the same style of pinning to queue, inbox, contract, and codec
suites (the suite names appear in `keiro-dsl/keiro-dsl.cabal`:
`keiro-dsl-conformance-queue-runtime`, `keiro-dsl-conformance-intake-runtime`,
`keiro-dsl-conformance-contract`, `keiro-dsl-conformance-contract-typeid`,
and the aggregate `keiro-dsl-conformance` suites).

Relevant ADRs:
[ADR 0012](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
makes projection witnesses authoritative — Milestone 2 renames exported
witnesses but must not alter their construction or replace their use;
[ADR 0015](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
governs scaffold history and non-destructive migration — Milestone 4's banner
change must keep old files attributable;
[ADR 0017](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
owns generated-versus-Hole ownership — the closed disposition types change
what hole authors write but not who owns which behavior.  ExecPlans 178, 179,
180, and 181 are the coordinated siblings; 179 defines the release vehicle.


## Plan of Work

Milestone 0 extends invariance evidence.  For the queue, contract, and
event-codec conformance suites, add assertions that pin the exact encoded
JSON bytes of representative values and the exact accepted/rejected decoding
outcomes.  The inbox has no wire codec, so its suite pins the success/retry/
dead-letter classification of every runtime `InboxResult` constructor while
later detail assertions prove the declared retry delay and dead-letter reason.
The aggregate suite retains ExecPlans 179 and 181's exact fold fingerprint
pin; queues, inboxes, and contracts have no fold fingerprint to invent.  These
pins are the safety net every later milestone must keep green; they run
against the unchanged generator first.

Milestone 1 closes the disposition tables.  For each workqueue, generate a
closed sum type named after the queue (for example
`data ReservationWorkOutcome = StoreFailure | CommandRejected | ...` with
constructors derived from the spec's disposition table) and change
`jobOutcomeFor` to the total `ReservationWorkOutcome -> JobOutcome`; delete
the string catch-all.  For inboxes, generate a disposition type that carries
what the spec declared — the retry delay and the dead-letter reason — and
remove the silent `Nothing -> InboxRetry` default in favor of an exhaustive
generated table.  Hole signatures change accordingly; regenerate hole stubs in
fixtures and document the hand-migration (a consumer updates their hole to
use constructors instead of strings).  Wire bytes are untouched: dispositions
never cross the wire as these strings.

Milestone 2 renames witnesses.  Replace `encodeIdentifier`'s hex mangling
with names derived from the owning type and JSON-pointer path, lower-camel
(for example `artifactInfoArtifactKeyWitness`), with a short stable hash
suffix appended only on collision after Haskell-name normalization; the
generation is deterministic.  Update every generated use site and fixture.
The witness *values* — construction, types, and semantics — are unchanged
(ADR 0012); if ExecPlan 179 has landed, its transition-local `let` bindings
reference the new names.

Milestone 3 makes decode failures diagnosable.  Every generated
`fail "unknown ..."` interpolates the offending tag or value and the expected
set (for example
`fail ("unknown message type " <> show kind <> "; expected one of incidentTransferNeedDeclared, transferReservationAccepted")`),
and object decoders attach field context with Aeson's path combinators so
errors carry `$.field` paths, matching the standard ExecPlan 178 set for
typed contract fields.  Error *message* text is not wire format; the pinned
accepted/rejected outcomes from Milestone 0 must hold while the rejection
texts improve, and fixtures asserting exact error strings are updated
deliberately.

Milestone 4 stamps provenance.  The banner becomes one line carrying the
marker, the effective language version, the running keiro-dsl package version,
and the owning
source node, in a fixed format decided during implementation (for example
`-- @generated by keiro-dsl 0.9.0.0 (language keiro-dsl 4) from context HospitalCapacity, aggregate Reservation; do not edit.`),
keeping the leading `-- @generated` token for tooling compatibility.  Teach
every banner consumer — the generated firewall's overwrite check, and the
stale-evidence path ExecPlan 179 adds — to accept the legacy line or any
stamped line as generated provenance.  Add tests for both recognitions and
for the stamped banner's byte-stability across two identical scaffold runs.

Milestone 5 is focused module hygiene, in one regeneration pass: export
contract topic constants and remove `-Wno-unused-top-binds` from every module
kind that becomes warning-clean; break event-codec decode arms to one field
per line; replace `emitSum []` with an explicit empty datatype and the needed
language pragma; pin aggregate and process `StreamCategory` phantoms to their
concrete raw event-stream definition types so mismatched saga and target
categories stop unifying; and replace `WorkflowFacts`' `[(String, String)]`
with a small generated record whose body, await labels, and patch identifiers
are real lists rather than comma-packed strings.  Run Fourmolu with
`-XImportQualifiedPost` over the regenerated fixture files changed by this
plan, but do not claim the unrelated historical emitters are byte-conformant.

Milestone 6 regenerates every affected conformance tree, verifies the Milestone 0
pins and the full test suite, runs Fourmolu check over generated fixtures
changed by this plan,
and writes the `0.9.0.0` migration guide section covering: disposition sum
migration for hole authors, witness rename mapping (old mangled name to new
readable name per fixture), banner recognition, read-model hole signature
change, and the new exported topic constants.  Update
`keiro-dsl/CHANGELOG.md` (and `keiro-core/CHANGELOG.md` if any runtime
support type moves), amend ADR 0015 with the stamped-banner contract, and run
the ADR distillation pass.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/keiro`.

Capture current behavior before editing (expected: both greps find the
defects; record transcripts here):

```bash
rg -n "jobOutcomeFor|InboxRetry" keiro-dsl/test/conformance-queue-runtime keiro-dsl/test/conformance-intake-runtime -g '*.hs'
rg -n "structuralProjectionC" keiro-dsl/test/conformance-structural -g '*.hs' | head -5
```

After each milestone:

```bash
cabal test keiro-dsl-test --test-show-details=direct
cabal test keiro-dsl-conformance-queue-runtime --test-show-details=direct
cabal test keiro-dsl-conformance-intake-runtime --test-show-details=direct
cabal test keiro-dsl-conformance-contract --test-show-details=direct
cabal test keiro-dsl-conformance-contract-typeid --test-show-details=direct
```

After Milestone 5, prove formatter conformance for the regenerated files
changed by this plan and the absence of the old names.  Build the file list
from `git diff --name-only --diff-filter=ACM` so the check does not silently
make a false repository-wide claim:

```bash
fourmolu --mode check --ghc-opt -XImportQualifiedPost \
  $(git diff --name-only --diff-filter=ACM -- 'keiro-dsl/test/*/Generated/**/*.hs')
rg -n "structuralProjectionC[0-9a-f]" keiro-dsl/test keiro-dsl/src
```

Expected: fourmolu reports no changes needed; the witness grep returns
nothing.

Close with the full sweep:

```bash
cabal build all
cabal test all --test-show-details=direct
nix flake check
okf log add docs/adr --kind Update -m "Record stamped generated banners and the 0.9 generated-API hygiene contract (plan 182)."
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
git diff --check
```


## Validation and Acceptance

Acceptance is behavioral:

- A fixture hole that writes a misspelled disposition constructor fails to
  compile; the spec's retry window and dead-letter reason are observable in
  the generated inbox disposition value (asserted by a runtime conformance
  test, not by reading the source).
- Feeding the contract decoder an unknown discriminator produces an error
  containing the offending tag and the expected constructor list; feeding an
  invalid field produces an error containing its `$.field` path.
- The structural conformance tree exports human-readable witness names, the
  hex-mangled pattern appears nowhere, and the structural runtime suite
  passes unchanged — proving the rename touched names only.
- Two consecutive scaffold runs produce byte-identical output including the
  stamped banner; a tree containing legacy-banner files regenerates without
  any spurious hand-modified refusal.
- Fourmolu check passes over regenerated fixtures changed by this plan; the Milestone
  0 wire-byte pins pass unchanged at every milestone boundary; every
  conformance suite, `cabal build all`, `nix flake check`, and strict ADR
  validation pass at the end.


## Idempotence and Recovery

Scaffolding remains deterministic; every milestone is a source change plus a
fixture regeneration that can be re-run or reverted independently.  The
Milestone 0 wire-byte pins are the recovery oracle: if any pin fails, the
change was not representation-only — stop, record it in Surprises &
Discoveries, and fix the generator rather than the pin.  Regenerate fixtures
only through the scaffolder; never hand-edit a generated fixture to satisfy a
test.  Banner-recognition changes must land in the same commit as the banner
format change, so no intermediate state refuses to regenerate legacy trees.
This plan publishes nothing; release mechanics belong to ExecPlan 179's
Milestone 5 and `agents/skills/release/SKILL.md`.


## Interfaces and Dependencies

All work is inside `keiro-dsl` (canonical URI
`mori://shinzui/keiro/packages/keiro-dsl`), possibly with small runtime
support types in `keiro-core` (canonical URI
`mori://shinzui/keiro/packages/keiro-core`) if the inbox disposition value
type lives there; no new external dependency.  Representative generated
interfaces at the end (names follow each fixture's own conventions):

```haskell
-- workqueue policy module
data ReservationWorkOutcome = StoreFailure | CommandRejected | TimedOut
jobOutcomeFor :: ReservationWorkOutcome -> JobOutcome

-- inbox module
data IncidentInboxDisposition
  = InboxRetryAfter !RetryDelay !(Maybe InboxFailure)
  | InboxDeadLetter !(Maybe Text) !(Maybe InboxFailure)
  | InboxAccept

-- structural projections module
artifactInfoArtifactKeyWitness :: {- unchanged witness type -}

-- read-model holes remain raw until the language declares a source codec
applyTransferDecisions :: RecordedEvent -> Tx.Transaction ()
```

The generated banner format, once shipped in `0.9.0.0`, is frozen the same
way generated module names are: later changes must extend recognition, never
retire it.  This plan depends on ExecPlan 179 having landed through its
Milestone 3 (the emitters it edits must already be in their inlined form) and
must complete before ExecPlan 179's Milestone 5 cuts the `0.9.0.0` release;
ExecPlan 181's hash widening is independent of every surface here except
that both regenerate fixtures, so coordinate regeneration ordering in
whichever lands second.


Revision note (2026-08-02): validated the plan before implementation against
the current semantic graph, generated fixtures, prerequisite plan state, ADRs,
Mori-resolved dependency sources, and focused tests.  Corrected five unsound
assumptions: typed read-model dispatch lacks a declared codec authority;
`emitSum []` is live; truthful pre-release banners must use the running package
version; category safety requires concrete aggregate and process phantoms; and
the repository-wide formatter command neither parses nor passes on the current
baseline.  The revised milestones retain the representation-only API work and
defer the two generator-wide/language-surface projects that need independent
design and gates.
