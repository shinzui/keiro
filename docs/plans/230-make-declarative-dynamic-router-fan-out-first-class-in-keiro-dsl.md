---
id: 230
slug: make-declarative-dynamic-router-fan-out-first-class-in-keiro-dsl
title: "Make declarative dynamic router fan-out first-class in keiro-dsl"
kind: exec-plan
created_at: 2026-08-10T15:04:21Z
intention: "intention_01kzp2qnh4enqbzgeac5q2x13d"
---

# Make declarative dynamic router fan-out first-class in keiro-dsl

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, an author can describe a bounded, data-dependent router fan-out in a
`language keiro-dsl 5` source file without hand-writing the recipient-selection function.
The declaration names a typed read-model query, filters its returned rows, maps each row to
a target stream and command, fixes the ordering and deduplication rules, caps the recipient
set, and states what empty and failed selections mean.  `keiro-dsl check` rejects selections
that cannot be proved bounded, stable, total, or type-correct; `keiro-dsl scaffold` emits the
selection implementation when it can prove those properties and retains the existing
explicit `Hole` escape hatch for custom logic.

The behavior is visible in a new conformance service and in runtime tests.  Given a transfer
request and an unordered read-model result with duplicate hospitals, the generated router
sorts by physical target stream, collapses exact duplicate commands, rejects conflicting
commands for one target, and dispatches at most the declared positive limit.  On redelivery,
a target reached before and after a query-result change receives the same deterministic
command identity, while newly selected targets extend the stable union.  The diff report
also explains changes to selection identity, version, fingerprint, and policy instead of
silently treating them as ordinary source edits.


## Progress

- [x] (2026-08-10T19:49:48Z) External prerequisite: Shibuya Plan 32 released
  `shibuya-core` and `shibuya-metrics` 0.9.0.0 with opaque validated
  `DeadLetterCode`, `ApplicationFailure`, total code/detail projections, canonical rendering,
  tracing evidence, documentation, and the immutable `v0.9.0.0` tag.
- [x] (2026-08-10T21:26:56Z) External prerequisite: PGMQ adapter Plan 5 released
  `shibuya-pgmq-adapter` 0.14.0.0 with total projection-based serialization, compatibility and
  structured reason fields, property/database evidence, documentation, and the immutable
  `v0.14.0.0` tag.
- [x] (2026-08-11T01:54:22Z) Milestone 0 Keiro adoption: updated every direct workspace
  constraint to `shibuya-core ^>=0.9.0.0` and the existing adapter constraints to
  `shibuya-pgmq-adapter ^>=0.14.0.0`, added the public-API vocabulary proof, and proved all five
  intended Keiro selection reason-code literals, total projections, and canonical renderings.
  `cabal build keiro:lib:keiro` and `cabal test keiro-dsl-runtime-vocabulary-test` pass, and the
  resolved plan selects the two required released versions.
- [x] (2026-08-11T02:32:01Z) Milestone 1: added the candidate-only declarative router AST and
  grammar, mapped-type-backed checked representation, total scalar/path and command-mapping
  checks, bounded policy validation, canonical SHA-256 fingerprint, append-only diagnostic
  codes, source relocation, pretty-printing, and valid/unbounded fixtures.  Focused language
  profile and declarative selection tests pass; 23 isolated rejection mutations prove the
  dedicated diagnostics, the executable accepts the bounded fixture, and it refuses the
  unbounded twin at line 79 with `RouterSelectionRecipientLimitMissing`.
- [x] (2026-08-11T02:48:08Z) Milestone 2: added the public runtime selection contract and smart
  positive limit/version constructors, target-stream sort/dedup/conflict/overflow normalization,
  safe application dead-letter reasons, additive `DeclarativeRouter` once/worker runners, and one
  shared legacy-compatible dispatch loop.  Seven focused database-backed runtime examples and all
  22 router examples pass, including zero callbacks before conflict/overflow, exact-cap dispatch,
  partial target success, stable-union redelivery, the full empty/failure policy matrix, and the
  existing router runtime conformance component.
- [ ] Milestone 3: generate executable selection code and compiled/database-backed evidence.
- [ ] Milestone 4: report mapped semantic and coordination impact.
- [ ] Milestone 5: document, record the final ADR, and run complete qualification.


## Surprises & Discoveries

- The released Shibuya API is stronger and more precise than the provisional plan vocabulary.
  `DeadLetterCode` is opaque; `mkDeadLetterCode` validates a bounded dotted ASCII code;
  `ApplicationFailure DeadLetterCode Text` carries application policy failure; and
  `deadLetterReasonCode`, `deadLetterReasonDetail`, and `renderDeadLetterReason` are total for
  built-in and application reasons.  Keiro can therefore validate its finite code set once and
  reuse values without matching on Shibuya constructors in adapters.

- Shibuya did not need to change `AckHandle` or runner/adapter mechanics.  The existing finalizer
  already transports the complete `AckDecision`; the 0.9 change extends the semantic value and
  supplies total projections.  Evidence: Shibuya Plan 32's public-only, supervised, batch, and
  telemetry suites all passed before the 0.9.0.0 release.

- The PGMQ-compatible rollout deliberately dual-writes three fields:
  `dead_letter_reason` retains the historical rendering, `dead_letter_reason_code` contains the
  stable code, and the always-present `dead_letter_reason_detail` contains text or JSON `null`.
  Removing the legacy field is separately gated by PGMQ adapter Plan 6 and is not part of this
  Keiro plan.

- Keiro has three bounded `shibuya-core >=0.8.0.1 && <0.9` constraints in
  `keiro/keiro.cabal`, not two.  The external releases are complete, but Milestone 0 remains open
  until every constraint selects 0.9 and a Keiro-owned public API test passes.

- Cabal solves the whole local workspace even for the targeted `keiro:lib:keiro` build.  The first
  Milestone 0 build therefore exposed five additional 0.8-only `shibuya-core` constraints in
  `keiro-pgmq/keiro-pgmq.cabal` and `jitsurei/jitsurei.cabal`, plus three adapter 0.13-only
  constraints.  Evidence: the initial solver rejected `keiro-0.11.0.0` against
  `jitsurei => shibuya-core >=0.8.0.1 && <0.9`; after aligning every direct workspace constraint,
  `dist-newstyle/cache/plan.json` selected `shibuya-core-0.9.0.0` and
  `shibuya-pgmq-adapter-0.14.0.0`.

- Compiling `keiro-pgmq` against Shibuya 0.9 exposed an old exhaustive local
  `deadLetterReasonText` match.  GHC's incomplete-pattern warning named the new
  `ApplicationFailure _ _` case.  Replacing that duplicate renderer with Shibuya's public total
  `renderDeadLetterReason` removed the warning and kept Keiro aligned with the dependency-owned
  wire vocabulary.

- The workspace line-relocation walker makes AST source ownership compiler-enforced.  Adding
  `RouterSelectionDecl` caused `Keiro.Dsl.Workspace` to fail until the new syntax and its
  `Natural` leaves received `HasLocs` coverage; this gave direct evidence that selection policy
  and expression locations survive multi-file composition.

- Existing identifiers do not admit hyphens, while the selection policy vocabulary deliberately
  uses values such as `target-stream` and `stable-union`.  The selection parser therefore owns a
  small hyphenated-name parser and the checker, rather than the lexer, decides whether the parsed
  value is one of the closed admitted policies.

- The legacy router computes dispatch identity through the target event stream's
  `resolveStreamName`, while declarative normalization is explicitly keyed by
  `Keiro.Stream.streamName` on `PMCommand.target`.  Extracting the dispatch helper initially made
  that distinction easy to erase.  The final helper retains the exact legacy resolver and
  positional-ID compatibility probe; normalization remains a separate pre-dispatch phase.


## Decision Log

- Decision: Introduce declarative router selection only in candidate language version 5;
  keep version 4 parsing, checking, and scaffold bytes unchanged.
  Rationale: The surface adds new semantics and generated code, and the repository's
  language-profile mechanism is the earliest sound compatibility boundary.
  Date: 2026-08-10

- Decision: Add a `DeclarativeRouter` runtime surface and keep the existing `Router` API as
  a compatibility surface.
  Rationale: Existing applications own arbitrary effectful resolver code.  Reinterpreting
  that type would turn a DSL feature into a runtime breaking change.
  Date: 2026-08-10

- Decision: The first declarative subset accepts one mapped read-model query whose result is
  a list of structural rows, scalar boolean predicates over `input` and `row`, a `Text`
  recipient projection, and a total structural command mapping.
  Rationale: These constraints reuse the current mapped type graph and generated field
  witnesses while excluding joins, arbitrary SQL, effects, and partial expressions that the
  checker cannot prove safe.
  Date: 2026-08-10

- Decision: Normalize selected commands by physical target stream: sort ascending, collapse
  exact duplicates, and fail if two unequal commands select the same target.  Apply the
  positive cap after deduplication, and never truncate or write a prefix on overflow.
  Rationale: Target-keyed normalization makes database row order irrelevant, preserves the
  frozen dispatch identity, and avoids silently choosing between conflicting commands.
  Date: 2026-08-10

- Decision: Selection identity, version, and fingerprint are coordination metadata and do
  not enter `deterministicRouterCommandId`.
  Rationale: The existing identity tuple `(name, key, sourceEventId, targetStreamName,
  occurrence)` is frozen replay identity.  Keeping it stable gives the requested stable-union
  behavior when selection logic or query results change.
  Date: 2026-08-10

- Decision: Version 5 initially admits only `order = target-stream`, `dedupe =
  target-stream`, `redelivery = stable-union`, and `partial = retain-successes`.
  Rationale: Making the policies explicit allows future extension without pretending that
  unsupported policies are verified today.
  Date: 2026-08-10

- Decision: Empty selection permits `ack`, `retry`, `deadLetter`, or `halt`; selection
  failure permits `retry`, `deadLetter`, or `halt`, but not `ack`.
  Rationale: Empty can be a legitimate business result.  Treating an evaluation, query,
  conflict, or overflow failure as success would lose work.
  Date: 2026-08-10

- Decision: Depend on the application-defined permanent-processing reason requested by
  `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-2` before lowering selection
  `deadLetter`, and require the PGMQ adoption tracked by
  `mori://shinzui/shibuya-pgmq-adapter/okf/improvement-requests/concepts/IR-1` before claiming
  end-to-end PGMQ support.  Do not encode the outcome as `PoisonPill`, `InvalidPayload`, or
  `MaxRetriesExceeded`, and do not add a catch-all adapter renderer.
  Rationale: Those existing Shibuya reasons assert facts that are false for a valid source event
  whose router selection is empty, conflicting, or over its declared cap.  The current PGMQ
  adapter also exhaustively reimplements the closed reason renderer.  Improving the upstream
  contracts preserves honest DLQ data and avoids Keiro-specific or adapter-specific workarounds.
  Date: 2026-08-10

- Decision: Adopt the released `shibuya-core ^>=0.9.0.0` API exactly: Keiro owns five validated
  `DeadLetterCode` values, constructs `ApplicationFailure code safeDetail`, and uses Shibuya's
  total projections/rendering rather than matching the complete reason datatype.
  Rationale: The opaque smart-constructed code prevents malformed operational identities, while
  total projections preserve the dependency's ownership boundary and remain usable by every
  adapter.  Validation happens once for static Keiro literals, not once per routed message.
  Date: 2026-08-10

- Decision: Treat `shibuya-pgmq-adapter` 0.14.0.0's three-field dual write as the supported PGMQ
  compatibility contract; do not make Keiro depend on the adapter and do not wait for or assume
  the breaking legacy-field removal in its Plan 6.
  Rationale: Keiro produces an `AckDecision` through the core abstraction.  Adapter 0.14 already
  proves that the stable code/detail survive a real PGMQ DLQ, while field removal is a separate
  consumer-adoption decision with no bearing on declarative selection semantics.
  Date: 2026-08-10

- Decision: SQL and query execution remain application-owned.  The verified declarative
  boundary begins at the typed rows returned by the named read-model query.
  Rationale: The current read-model query contract is intentionally a typed `Hole` backed by
  application code.  This plan makes post-query selection declarative without claiming to
  verify database behavior.
  Date: 2026-08-10

- Decision: Preserve the existing custom resolver as an explicit `custom-unverified` branch
  and retain its generated `RouterHoles` ownership boundary.
  Rationale: Arbitrary selection remains necessary, but users and diff tooling must be able
  to distinguish unverified custom behavior from generated declarative behavior.
  Date: 2026-08-10

- Decision: Extend mapped semantic impact for dependencies inside declarative selection and
  add an append-only top-level `coordinationImpact` section to the diff report; do not change
  the aggregate replay-impact JSON contract.
  Rationale: Selection changes can affect both schema consumers and redelivery coordination.
  Keeping coordination separate preserves existing replay-report consumers.
  Date: 2026-08-10

- Decision: Align the existing direct Shibuya and PGMQ-adapter constraints in `keiro-pgmq` and
  `jitsurei` with the Milestone 0 releases in addition to the three planned `keiro` constraints.
  Rationale: these packages are members of `cabal.project`, so their incompatible upper bounds
  prevent Cabal from constructing any one-version workspace plan.  Adapter 0.14 keeps its public
  Haskell API unchanged and is the required Shibuya 0.9-compatible release.
  Date: 2026-08-11

- Decision: Remove `keiro-pgmq`'s local exhaustive dead-letter renderer and call
  `renderDeadLetterReason` from the public Shibuya API.
  Rationale: Shibuya owns the complete reason vocabulary and canonical compatibility rendering;
  duplicating its constructors would drift on every future additive reason.
  Date: 2026-08-11

- Decision: A typed router input is the declarative branch marker and omits the legacy `via`
  clause; a field-list input plus explicit `via` remains the byte-compatible custom resolver
  grammar.  The checker still resolves the declarative key as a required `Text` path.
  Rationale: This preserves the released version-4 surface exactly while giving generated
  selection an input type that is provably identical to the named read-model query contract.
  Date: 2026-08-11

- Decision: Keep selection checking in `Keiro.Dsl.RouterSelection`, with its located internal
  error vocabulary exhaustively projected into append-only public `DiagnosticCode` constructors
  by `Validate`.
  Rationale: Downstream generation and impact analysis need one checked value and one field/type
  model, while CLI consumers still require the repository's central stable diagnostic registry.
  Date: 2026-08-11

- Decision: Fingerprint checked semantic evidence with `cryptohash-sha256` and a local lowercase
  hexadecimal rendering; do not add a base16 dependency.
  Rationale: SHA-256 provides the required cryptographic identity, the direct dependency's
  released API was verified through Mori and Hackage, and the 32-byte fixed output needs only a
  total two-digit byte rendering.
  Date: 2026-08-11

- Decision: Normalize the complete declarative command set before invoking the shared dispatch
  helper, but keep target dispatch transactionality unchanged.
  Rationale: Conflict and overflow must cause zero writes, while a later target failure must retain
  earlier successes and recover through redelivery plus the frozen target-keyed command identity.
  Date: 2026-08-11

- Decision: Lower declarative empty/failure `deadLetter` directly to Shibuya
  `AckDeadLetter (ApplicationFailure code safeDetail)` and ignore raw query/evaluation text in the
  transported detail.
  Rationale: The adapter owns DLQ mechanics and structured serialization; omitting unrestricted
  backend and payload text preserves the released Shibuya safety contract.
  Date: 2026-08-11


## Outcomes & Retrospective

The two external API improvements are complete and released.  Shibuya 0.9.0.0 provides the honest
application-defined permanent-processing reason and total adapter-facing projections; PGMQ adapter
0.14.0.0 preserves the stable code and optional detail through a real database-backed DLQ without
losing the legacy compatibility rendering.  Hackage preferred metadata and annotated upstream tags
independently confirm both releases.

Keiro has now adopted those releases across the local workspace, and the cross-package vocabulary
proof validates the five planned selection reason codes through Shibuya's public API.  Candidate
language version 5 now owns a bounded declarative selection grammar and a checked semantic value;
version 4 refuses the feature at its marker and retains its custom-router syntax.  The runtime now
also exposes checked-contract normalization and additive declarative runners without changing the
legacy router path.  Generator, new declarative conformance, diff, and documentation acceptance
items remain open, so implementation continues at Milestone 3 and IR-9 remains open.


## Context and Orientation

The source request is
`docs/improvement-requests/make-declarative-dynamic-router-fan-out-first-class-in-keiro-dsl.md`
(IR-9).  In this plan, a *router* consumes one source event and emits zero or more process-
manager commands.  *Selection* is the query/filter/map stage that determines those commands.
A *physical target* is the final `Keiro.Stream.Stream` name used for dispatch.  *Stable union*
means that repeated processing may add newly selected targets, while a target selected on
multiple attempts is protected by the same deterministic command identity.  A *fingerprint*
is a canonical digest of the checked selection semantics, excluding source locations and
formatting.

The runtime already supports effectful dynamic fan-out in `keiro/src/Keiro/Router.hs`.
`Router.resolve` returns `[PMCommand targetCi]`, and `runRouterOnce` dispatches each item using
`deterministicRouterCommandId`.  Its seed includes router name, correlation key, source event
identity, target stream name, and occurrence.  It checks both current and legacy identities,
confirms duplicates, and performs each target write in its own transaction.  This produces
stable-union behavior across redelivery, but the list type cannot distinguish an intentional
empty selection from a query or evaluation failure.  `keiro/src/Keiro/ProcessManager.hs`
defines `PMCommand`; `keiro-core/src/Keiro/Stream.hs` defines the ordered stream identity.

The DSL representation is in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`.  Today `ResolveSource` is
either `ResolveReadModel Name` or `ResolveHole`, and `ResolveDecl` carries only the source and
row binding.  `RouterNode` combines that resolver with the input, correlation key, target,
projections, dispatch mapping, outcomes, and the frozen dispatch-id declaration.
`keiro-dsl/src/Keiro/Dsl/Parser/Coordination.hs` parses forms such as `resolve stable via
read-model ServiceOncall row oncall`.  It does not contain a typed predicate, recipient map,
bound, or policy.

`keiro-dsl/src/Keiro/Dsl/Validate.hs` currently validates router references, names, binding
scope, command existence, and whether a referenced read model is verified.  It has no checked
selection intermediate representation.  The mapped type system lives in
`keiro-dsl/src/Keiro/Dsl/TypeGraph.hs`; `emitStructuralProjections` in
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` lowers that checked graph into generated field witnesses.
Use these as the sole schema authority for selection fields and expressions.

`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` has stable language version 4 and candidate
version 5.  Candidate syntax already permits typed read-model query input and result
declarations.  `ReadModelNode` stores those optional types, and generated query contracts
provide typed input/result aliases.  The application still supplies the actual query
function, which returns a `Tx.Transaction result`.  At runtime,
`keiro/src/Keiro/ReadModel.hs` exposes `runQuery`, returning `Either ReadModelError result`.
Declarative router selection must compose with that boundary rather than generate SQL.

Generation flows through `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`.  Current router output emits a
small generated `Router` module and a create-once `RouterHoles` module that owns the resolver
and assembled value.  `keiro-dsl/src/Keiro/Dsl/Harness.hs` emits fact-level router evidence.
Existing fixtures and snapshots are under `keiro-dsl/test/fixtures/incident-paging/`,
`keiro-dsl/test/fixtures/transfer-routing.keiro`, and the `keiro-dsl/test/conformance-router*` and
`keiro-dsl/test/conformance-newsurface` directories.  These fixtures protect the old custom
surface and must remain byte-for-byte stable under language version 4.

Evolution reporting is split across `keiro-dsl/src/Keiro/Dsl/Diff.hs`,
`keiro-dsl/src/Keiro/Dsl/SemanticImpact.hs`, `keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs`, and
`keiro-dsl/src/Keiro/Dsl/DiffReport.hs`.  Router diffs currently cover stable name, key,
target, decide surface, and drain rules, but resolver details are invisible.  Semantic impact
has mapped consumers for aggregates, work queues, read-model queries, and derived projections;
the new selection's input, predicate, recipient, and dispatch expressions must join that same
checked graph.  Aggregate replay impact is a deliberately separate JSON contract.  The diff
report schema is append-compatible, so coordination evidence belongs in a new optional
top-level field.

The following local ADRs constrain the work:

- [ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
  requires rejecting an invalid change at the earliest boundary that has enough information.
  Therefore syntax capability is gated by language profile, type errors are checker errors,
  and unsafe evolution is reported by diff before generation or runtime.
- [ADR 0012](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
  requires mapped consumers to use the checked structural graph and total bindings.  The
  selection checker must not invent a parallel field/type model.
- [ADR 0016](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
  requires language provenance and capability checks to remain distinct from the semantic
  graph.  Version 5 capability admission belongs in `LanguageVersion`, not scattered parser
  conditions.
- [ADR 0017](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
  establishes the generated-or-Hole ownership pattern.  Declarative selection is generated;
  custom selection remains a plainly named application-owned Hole.
- [ADR 0020](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md)
  requires compiled conformance services to consume the runtime-owned API rather than test
  doubles or private generator helpers.
- [ADR 0024](../adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md)
  freezes deterministic identity seed bytes.  Selection metadata must not alter the current
  router command-id seed.
- [ADR 0026](../adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md)
  separates query, target, group, and handler identities.  The selection identity/version is
  likewise explicit coordination metadata and cannot substitute for query or stream identity.

Implementation should add a new local ADR because the combination of normalization,
selection-version evolution, failure policies, and frozen dispatch identity is durable
architecture not fully covered by an existing decision.  Allocate its identifier with
`okf id next docs/adr --profile docs/adr/profile.dhall ADR`; do not guess the next number.

Dependency APIs were located through Mori rather than inferred.  Structural field access is
provided by `mori://shinzui/keiki/packages/keiki`, where `fieldWitnessGet` projects a generated
`FieldWitness` from its owner.  Runtime acknowledgement constructors are provided by
`mori://shinzui/shibuya/packages/shibuya-core`: `AckOk`, `AckRetry`, `AckDeadLetter`, and
`AckHalt`, with typed retry, dead-letter, and halt reasons.  The gap recorded by
`mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-2` was completed by
`mori://shinzui/shibuya/plans/32-add-application-defined-dead-letter-reasons` and released as
`shibuya-core` 0.9.0.0 under annotated tag `v0.9.0.0`.  The public API adds opaque
`DeadLetterCode`, `mkDeadLetterCode`, `ApplicationFailure`, `deadLetterReasonCode`,
`deadLetterReasonDetail`, and `renderDeadLetterReason`.  Code validation permits at most 128 ASCII
characters, requires two or more dot-separated `[a-z][a-z0-9_]*` segments, and reserves the first
segment `shibuya` for framework-owned codes.  Detail is transported verbatim, so Keiro must keep it
bounded and exclude secrets, full payloads, raw SQL, credentials, and unrestricted backend errors.

The downstream request
`mori://shinzui/shibuya-pgmq-adapter/okf/improvement-requests/concepts/IR-1` was completed by
`mori://shinzui/shibuya-pgmq-adapter/plans/5-preserve-structured-dead-letter-reasons-in-pgmq-dlq-payloads`
and released as `shibuya-pgmq-adapter` 0.14.0.0 under annotated tag `v0.14.0.0`.  Production uses
only Shibuya's total projections and writes `dead_letter_reason`, `dead_letter_reason_code`, and
the always-present `dead_letter_reason_detail`; its database suite proves the representative
`keiro.router.selection.recipient_overflow` reason is separately queryable.  Keiro does not acquire
a dependency on that adapter.  The adapter's repository-local Plan 6 may later remove the legacy
rendering after consumer adoption, but that change is neither a prerequisite nor part of this
plan.  Keiki needs no source or release change.


## Plan of Work

### Milestone 0: Fulfil the acknowledgement prerequisites

The ordered external work is complete.  Shibuya Plan 32 released `shibuya-core` 0.9.0.0 with
`ApplicationFailure` and total code/detail/rendering functions; PGMQ adapter Plan 5 released
0.14.0.0 and proved the stable code/detail through PostgreSQL while retaining the compatibility
string.  The authoritative Hackage metadata and annotated tags listed in Concrete Steps confirm
those immutable handoff points.  Do not wait for the PGMQ adapter's separately gated legacy-field
removal.

Complete the Keiro portion by changing all three `shibuya-core` constraints in
`keiro/keiro.cabal` from `>=0.8.0.1 && <0.9` to `^>=0.9.0.0`.  Because Cabal solves all local
packages in one workspace plan, also align the existing direct constraints in
`keiro-pgmq/keiro-pgmq.cabal` and `jitsurei/jitsurei.cabal`, using
`shibuya-pgmq-adapter ^>=0.14.0.0` where those packages already depend on the adapter.  Do not add
`shibuya-pgmq-adapter` to the `keiro` runtime package.  Add a focused public-API test to
`keiro-dsl-runtime-vocabulary-test` or the smallest existing cross-package vocabulary suite.  It
must import only public Shibuya/Keiro modules, validate all five static codes, construct an
`ApplicationFailure`, and prove its projected code, optional detail, and canonical rendering.

In that focused proof, validate the five intended literals:
`keiro.router.selection.empty`, `keiro.router.selection.query_failed`,
`keiro.router.selection.evaluation_failed`, `keiro.router.selection.target_conflict`, and
`keiro.router.selection.recipient_overflow`.  A static invalid literal is a programmer error that
must fail the proof.  Milestone 2 promotes the validated literals to top-level runtime values so
message handling never repeatedly calls `mkDeadLetterCode`.  This milestone is complete when the
Keiro solver selects `shibuya-core-0.9.0.0` and the public API proof passes.

### Milestone 1: Parse and check a bounded declarative selection

Add `DeclarativeRouterSelectionSyntax` to the candidate profile in
`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`; stable version 4 must report no support.  Add the
matching runtime capability only when all generated/runtime pieces exist, with the existing
profile fold returning `Nothing` for older versions.  Change the router resolver AST in
`keiro-dsl/src/Keiro/Dsl/Grammar.hs` from an under-specified source into a sum with two explicit
branches: `custom-unverified` retains the current read-model-or-Hole information, while
`declarative` stores identity, positive version, query, row predicate, recipient expression,
cap, command mapping context, and the admitted policies.  Preserve source locations on every
user-written expression and policy.

Extend `keiro-dsl/src/Keiro/Dsl/Parser/Coordination.hs` to accept this candidate form:

```keiro
language keiro-dsl 5
context transfer-routing

router HospitalTransferRouter
  name "hospital-transfer-router"
  input AcceptedHospitalTransferNeed : TransferRouteInput
  key input.transferNeedId
  resolve declarative {
    identity = "hospital-transfer-selection"
    version = 1
    query = read-model hospital_load with input
    where = row.region == input.region && row.availableBeds > 0
    recipient = row.hospitalId
    order = target-stream
    dedupe = target-stream
    max-recipients = 64
    empty => ack
    failure => retry
    redelivery = stable-union
    partial = retain-successes
  }
  target Hospital
  projections [ ]
  dispatch-each RouteAcceptedTransferNeed {
    transferNeedId=input.transferNeedId
    hospitalId=row.hospitalId
  }
    on-appended AckOk ; on-duplicate AckOk ; on-failed Retry
  dispatch-id strategy=uuidv5 from=(name, key, sourceEventId, targetStreamName, occurrence)
  rejected => deadLetter
  poison => halt
```

Create `keiro-dsl/src/Keiro/Dsl/RouterSelection.hs` as the checked representation and checker.
Resolve the input and query result through `TypeGraph`; require the query result to be
`List Row` with structural field evidence; type-check the predicate as total `Bool`, the
recipient as non-optional `Text`, and every dispatched command field as a total expression.
Require a non-empty identity, a strictly positive version and cap, and exactly the fixed
policy values in the Decision Log.  Reject missing query contracts, nominal/opaque row
results, nullable recipient paths, unsupported operators, row references outside selection,
unknown fields, cross-target commands, ambiguous physical targets, unstable order/dedupe,
and unbounded selections with dedicated diagnostics and source spans.  The validator should
consume this checked value rather than repeat these rules in `Validate.hs`.

Add parser, capability, diagnostic, type-checking, use-site, and golden tests in the existing
`keiro-dsl/test` suites.  Include one valid declaration and one isolated mutation per rejection
class.  At the end of the milestone, `keiro-dsl check` accepts the example above and rejects
an identical declaration with `max-recipients` omitted before any scaffold files are written.

### Milestone 2: Add the runtime selection contract and safe dispatch runner

Create `keiro/src/Keiro/Router/Selection.hs` and expose it from the `keiro` package.  Define a
positive `RecipientLimit`, typed empty/failure dispositions, a selection contract carrying
identity/version/fingerprint and fixed policies, and `normalizeRecipients`.  Normalization
must derive the physical stream for every `PMCommand`, sort ascending by that stream, group by
stream, collapse equal commands, fail on unequal commands in a group, then enforce the cap.
It must return a failure before invoking any dispatch callback when a conflict or overflow is
present.  Empty is a distinct successful normalized result.

Add `DeclarativeRouter` beside the legacy `Router` in `keiro/src/Keiro/Router.hs`.  Its
selection function returns `Either RouterSelectionFailure [PMCommand targetCi]`.  Refactor the
existing target-keyed dispatch loop into an internal helper used by both router types; do not
change the deterministic or legacy command-id seed bytes.  Add direct and worker runners that
map empty and failed selection through the contract's dispositions into the existing Shibuya
acknowledgement domain.  `deadLetter` must use the released application-defined reason from
`mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-2`, with stable Keiro reason codes
that distinguish empty, query failure, evaluation failure, target conflict, and overflow.  Define
the five successfully preflighted `DeadLetterCode` values once at module initialization and lower
policies with `ApplicationFailure code safeDetail`; do not validate codes for every message or put
raw backend errors into detail.
`retain-successes` means already committed targets remain committed when a later target dispatch
fails and the source is retried; it does not allow a selection conflict or overflow to write a
prefix.

Add runtime tests covering unordered rows, exact duplicates, conflicting commands for one
target, cap-at-boundary, overflow, empty policies, query failure policies, partial target
failure, and redelivery after target-set drift.  Record every dispatch callback invocation so
the tests prove both selected identities and absence of writes on pre-dispatch failures.  At
the end of the milestone the legacy runner tests remain unchanged, while the new runner proves
that `{A,B}` followed by `{B,C}` dispatches `A`, `B`, and `C` at most once under current IDs.

### Milestone 3: Generate executable selection code and compiled evidence

Teach `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` and its import planner to branch on the checked
selection.  For a declarative router, generate a `Router` module that constructs the query
input, invokes the generated read-model query contract, evaluates the checked predicate using
generated structural projections, constructs typed target streams and commands, and assembles
a `DeclarativeRouter`.  Export the selection contract and fingerprint as named values so tests,
diff tooling, and operators observe the same identity.  Do not generate `RouterHoles` for the
selection itself; an application query Hole may still be imported through the existing
read-model boundary.  Continue generating `RouterHoles` and byte-identical outputs for the
custom-unverified branch.

Extend `keiro-dsl/src/Keiro/Dsl/Harness.hs` with facts for resolver ownership, query identity,
selection identity/version/fingerprint, limit, and policies.  Add a database-backed compiled
conformance package under `keiro-dsl/test/conformance-declarative-router/`.  Its seed data must
return eligible rows in deliberately unstable order with an exact duplicate; its executable
proof must show deterministic target order and exact deduplication.  A second transaction
changes the eligible result from `{A,B}` to `{B,C}` and reprocesses the same source identity;
the ledger must contain no second command for `B` and one command each for `A` and `C`.  Add a
mutation proof that conflicting commands for one physical target fail with zero target writes.

Refresh only the fixtures whose declared language version and feature coverage opt into the
new surface.  Run the existing version-4 router fixture through scaffold before and after the
change and compare generated bytes.  The milestone is complete when the new package compiles
against the public runtime facade, passes against PostgreSQL, and old custom-router snapshots
have no diff.

### Milestone 4: Make schema and coordination impact reviewable

Extend `keiro-dsl/src/Keiro/Dsl/SemanticImpact.hs` so a declarative selection contributes
mapped consumers for query input, predicate, recipient, and dispatch mappings.  Derive these
use sites from `CheckedRouterSelection`, not the parser AST.  Add selection-specific root and
consequence labels while preserving the current evidence schema's append-only behavior.  A
nested mapped-field change used only by a selection must still appear in mapped semantic
impact.

Define one canonical encoder for checked selection semantics and hash those bytes into the
fingerprint.  Include resolved query identity, normalized typed expressions, command mapping,
target identity derivation, limit, and every policy; exclude locations, comments, formatting,
and declared version.  Use the same encoder in generated code, scaffold records, harness facts,
and diff.  Extend `keiro-dsl/src/Keiro/Dsl/ScaffoldRecord.hs` and scaffold reconciliation so
selection identity/version/fingerprint changes are visible in ownership ledgers without
claiming ownership of application query files.

Create `keiro-dsl/src/Keiro/Dsl/CoordinationImpact.hs` and add optional
`coordinationImpact` output in `keiro-dsl/src/Keiro/Dsl/DiffReport.hs`.  Extend router pairing
in `keiro-dsl/src/Keiro/Dsl/Diff.hs` with these rules:

- Changing selection identity is breaking because continuity cannot be established.
- Decreasing version is breaking.
- Changing fingerprint without increasing version is breaking.
- Changing fingerprint with a version increase is advisory and requires a drain/replay review;
  report old/new identity, version, fingerprint, and affected target semantics.
- Increasing only the version is an advisory metadata-only change.
- Crossing between declarative and custom-unverified requires drain review and reports the
  custom side as unverified rather than inventing a fingerprint.
- A mapped schema change that reaches selection must appear in both semantic impact and the
  coordination section when it can change recipient membership, target identity, or command
  content.

Keep `ReplayImpact` and its aggregate JSON byte contract unchanged.  Add golden diff cases for
each rule plus a control where whitespace/source-location changes preserve the fingerprint.
The milestone is complete when a selection edit cannot disappear from diff output and existing
diff-report consumers accept reports with or without the new optional field.

### Milestone 5: Document, decide, and qualify the complete surface

Update `docs/guides/routers-and-effectful-fan-out.md` with the declarative syntax, the verified
boundary, normalization rules, empty/failure matrix, cap behavior, stable-union example,
version-bump workflow, and custom-unverified fallback.  Update relevant command/reference
documentation and fixture READMEs.  Create the ADR identified in Context and Orientation,
recording the final semantics and alternatives actually implemented; use the profiled ADR OKF
bundle and validate it.

Run focused tests after each milestone, then the whole repository build/test, conformance
corpus, formatters, flake checks, ADR checks, and diff hygiene commands listed below.  Inspect
the final diff for accidental version-4 snapshot churn and for generated create-once files.
The plan is complete only when every behavioral acceptance item is demonstrated, IR-9 links to
the completed plan/outcome as appropriate, and the living sections above reflect actual work.


## Concrete Steps

Run all commands from the repository root,
`/Users/shinzui/Keikaku/bokuno/keiro`.  Before changing dependency-facing code, refresh the
local source locations and curated documentation required by the repository instructions:

```sh
mori registry show shinzui/keiki --full
mori registry docs shinzui/keiki
mori registry show shinzui/shibuya --full
mori registry docs shinzui/shibuya
mori registry show shinzui/shibuya-pgmq-adapter --full
mori registry docs shinzui/shibuya-pgmq-adapter
```

Expected output includes the local project paths, the `keiki` package, and the
`shibuya-core` package.  Read the reported source paths directly; never inspect
`/nix/store`.

The ordered external plans for
`mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-2` and
`mori://shinzui/shibuya-pgmq-adapter/okf/improvement-requests/concepts/IR-1` are complete.  Before
editing Keiro's dependency bound, re-verify their authoritative Hackage metadata and exact
annotated tags:

```sh
curl -fsSL https://hackage.haskell.org/package/shibuya-core/preferred.json
curl -fsSL https://hackage.haskell.org/package/shibuya-pgmq-adapter/preferred.json
git ls-remote --tags https://github.com/shinzui/shibuya.git \
  refs/tags/v0.9.0.0 'refs/tags/v0.9.0.0^{}'
git ls-remote --tags https://github.com/shinzui/shibuya-pgmq-adapter.git \
  refs/tags/v0.14.0.0 'refs/tags/v0.14.0.0^{}'
mori registry show shinzui/shibuya --full
mori registry show shinzui/shibuya-pgmq-adapter --full
```

The 2026-08-10 reconciliation produced this concise evidence:

```text
shibuya-core normal-version: 0.9.0.0
v0.9.0.0 peels to: d958a5748475a4b84075feda7a2a4f5cc7471c60
shibuya-pgmq-adapter normal-version: 0.14.0.0
v0.14.0.0 peels to: 301652375ecdec01c4e1ff50902900ad3a078ea3
```

If later output withdraws either normal version or moves an immutable tag, stop and investigate.
Otherwise read the released API through Mori's reported source path, update all direct local
workspace bounds as described in Milestone 0, add the vocabulary proof, and run:

```sh
cabal build keiro:lib:keiro
cabal test keiro-dsl-runtime-vocabulary-test
```

Both commands must exit 0.  The vocabulary test constructs `ApplicationFailure` through public
Shibuya/Keiro modules and asserts the stable code, optional detail, and canonical rendering for all
five intended literals.  PGMQ adapter Plan 5 already proves the representative code/detail in a
real DLQ.  Do not substitute another `DeadLetterReason` or an adapter catch-all.

After Milestone 1, run the parser/checker and language-profile tests, narrowing Hspec with
stable labels introduced for this feature:

```sh
cabal test keiro-dsl-test --test-options='--match RouterSelection'
cabal test keiro-dsl-test --test-options='--match FrontendProfiles'
cabal test keiro-dsl-runtime-vocabulary-test
```

The transcript should end with zero failures.  Exercise both a valid fixture and a boundedness
mutation through the executable:

```sh
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/declarative-router/valid.keiro
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/declarative-router/unbounded.keiro
```

The first command exits 0.  The second exits non-zero and names the missing positive
`max-recipients` at its source span.

After Milestone 2, run the runtime tests under a feature-specific Hspec label and rerun all
legacy router tests:

```sh
cabal test keiro-test --test-options='--match RouterSelection'
cabal test keiro-test --test-options='--match Router'
cabal test keiro-dsl-conformance-router-runtime
```

Expected output is zero failures.  The feature cases must print/assert no dispatch callbacks
for conflict and overflow, and exactly one current deterministic identity per physical target
in the redelivery case.

After Milestone 3, generate into a disposable directory, inspect the declared outputs, and
compile/run the new and legacy conformance components:

```sh
router_scratch=$(mktemp -d /tmp/keiro-declarative-router.XXXXXX)
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/declarative-router/valid.keiro --out "$router_scratch"
rg -n 'DeclarativeRouter|selectionContract|selectionFingerprint' "$router_scratch"
cabal test keiro-dsl-conformance-declarative-router
cabal test keiro-dsl-conformance-router
cabal test keiro-dsl-conformance-router-full
cabal test keiro-dsl-conformance-newsurface
```

The generated declarative router contains the three named runtime artifacts and no
selection-owned `RouterHoles` file.  All four conformance components exit 0.  Remove the
disposable directory only after its path is visually confirmed to begin with
`/tmp/keiro-declarative-router.`.

After Milestone 4, run focused semantic/diff/scaffold tests and compare representative JSON:

```sh
cabal test keiro-dsl-test --test-options='--match RouterSelectionImpact'
cabal test keiro-dsl-test --test-options='--match CoordinationImpact'
cabal test keiro-dsl-test --test-options='--match RouterSelectionScaffold'
cabal run keiro-dsl -- diff \
  keiro-dsl/test/fixtures/declarative-router/evolution/v1.keiro \
  keiro-dsl/test/fixtures/declarative-router/evolution/changed-without-bump.keiro \
  --json
```

The diff command exits according to the existing breaking-change convention.  Its JSON
contains `coordinationImpact`, the unchanged selection identity and version, distinct old/new
fingerprints, and a breaking fingerprint-without-version-bump finding.  Existing aggregate
replay-impact goldens remain byte-identical.

During Milestone 5, allocate and validate the ADR through its OKF bundle:

```sh
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Use the identifier printed by `okf id next`; update `docs/adr/log.md` through the repository's
normal OKF workflow.  The final command must exit 0.

Run the complete qualification after focused checks pass:

```sh
cabal build all
cabal test keiro-test
cabal test keiro-dsl:tests
scripts/check-conformance-corpus.sh
nix fmt
nix flake check
just adr-validate
git diff --check
git status --short
```

Expected results are successful builds/tests/checks, no whitespace errors, no unexpected
generated files, and only intentional source, fixture, documentation, and plan changes in
`git status --short`.

When implementation is ready to commit, use a Conventional Commit subject and retain the
execution lineage in trailers, for example:

```text
feat(dsl): generate bounded declarative router fan-out

ExecPlan: docs/plans/230-make-declarative-dynamic-router-fan-out-first-class-in-keiro-dsl.md
Intention: intention_01kzp2qnh4enqbzgeac5q2x13d
```


## Validation and Acceptance

Acceptance is behavioral, not merely successful compilation:

The external acceptance condition and Milestone 0 are satisfied: Shibuya 0.9.0.0 and PGMQ adapter
0.14.0.0 are normal Hackage releases with immutable annotated tags, adapter Plan 5 contains the
real-DLQ code/detail proof, all direct local constraints admit the compatible releases, and the
public-API vocabulary test proves the five Keiro literals and projections.  Using an old reason
constructor under a Keiro-formatted message would not satisfy this prerequisite.

1. A version-5 source with a typed `List Row` query result, total scalar filter, `Text` target
   identity, total command map, fixed policies, and positive cap passes `keiro-dsl check` and
   scaffolds an executable `DeclarativeRouter` without a selection Hole.
2. The same source under language version 4 fails with one capability diagnostic at the
   declarative selection, while existing version-4 custom router fixtures and generated bytes
   remain unchanged.
3. Independent mutations for unknown/nullable fields, non-boolean predicates, non-text
   recipients, unsupported operators, absent/zero cap, unsupported order/dedupe/redelivery/
   partial policies, missing query contracts, ambiguous target identity, and partial command
   mappings fail `check` with stable codes and precise spans.
4. For query rows in order `[B, A, B]` that produce equal commands, the generated runner
   dispatches `[A, B]` in ascending physical-stream order and never invokes `B` twice.
5. If two rows produce unequal commands for the same physical target, selection returns a
   conflict, applies the declared failure policy, and performs zero target writes.
6. If deduplication yields exactly `max-recipients`, dispatch proceeds.  If it yields one more,
   selection returns overflow, applies the failure policy, and performs zero target writes;
   no truncation is observable.
7. An empty successful query is observably distinct from query/evaluation failure and maps to
   the separately declared empty or failure disposition.  The checker never permits `ack` for
   failure.  A `deadLetter` disposition carries the upstream application-defined reason and one
   of Keiro's documented stable codes, never a poison, invalid-payload, or retry-exhaustion reason.
8. Reprocessing one source identity after recipients change from `{A,B}` to `{B,C}` preserves
   the same deterministic target command identity for `B`, confirms it as a duplicate, and
   writes `C` once.  The final target set is the stable union `{A,B,C}` with no silent double
   target.
9. Diff reports identity change, version regression, fingerprint-without-bump, versioned
   semantic change, metadata-only bump, and declarative/custom crossings at their specified
   severities.  Formatting-only edits preserve the fingerprint.  A nested schema change used
   by selection appears in mapped semantic and coordination evidence.
10. The new database-backed conformance package imports the public runtime facade, executes
    its generated router against real query rows, and passes.  `cabal build all`,
    `cabal test keiro-dsl:tests`, `scripts/check-conformance-corpus.sh`, formatter/flake checks,
    and strict ADR validation all succeed.


## Idempotence and Recovery

Parser, checker, unit-test, build, diff, and scaffold-to-temporary-directory commands are safe
to repeat.  Scaffold committed fixtures only after the focused checker and generator tests
pass.  The scaffold reconciliation ledger must continue to protect application-owned files;
if generation stops halfway, rerun the same scaffold command and inspect its record rather than
deleting or overwriting a `Holes` file manually.

Keep Milestone 1 AST/checker changes separate from Milestone 2 runtime changes until each
compiles, then add generation.  If the new conformance package fails, regenerate only its
`Generated/` subtree into a fresh temporary directory and compare it with `git diff --no-index`;
do not replace its application-owned query implementation.  A failed query, conflict, or
overflow is retryable according to policy because normalization occurs before dispatch.
Target dispatch itself is intentionally not atomic across targets; recovery is redelivery plus
target-keyed idempotency, so never add a broad cross-target transaction as a repair.

Do not renumber or reuse a selection version after a fingerprint has shipped.  If semantics
change accidentally, restore the checked declaration or increase the version and review the
reported coordination impact.  Do not change deterministic router ID bytes to make a test pass;
ADR 0024 and existing compatibility tests are the recovery authority.  Before removing any
temporary directory, resolve and inspect its explicit path; never use a broad glob or workspace
root as a deletion target.


## Interfaces and Dependencies

The implementation of
`mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-2` has shipped in
`mori://shinzui/shibuya/packages/shibuya-core` 0.9.0.0.  Consume this exact public contract from
`Shibuya.Core.Ack` (also re-exported by `Shibuya`):

```haskell
newtype DeadLetterCode -- constructor is private

mkDeadLetterCode :: Text -> Either Text DeadLetterCode
deadLetterCodeText :: DeadLetterCode -> Text

data DeadLetterReason
  = PoisonPill Text
  | InvalidPayload Text
  | MaxRetriesExceeded
  | ApplicationFailure DeadLetterCode Text

deadLetterReasonCode :: DeadLetterReason -> DeadLetterCode
deadLetterReasonDetail :: DeadLetterReason -> Maybe Text
renderDeadLetterReason :: DeadLetterReason -> Text
```

The downstream transport work in
`mori://shinzui/shibuya-pgmq-adapter/okf/improvement-requests/concepts/IR-1` has shipped in
`mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter` 0.14.0.0.  Its
`mkDlqPayload` uses only the total functions above and writes compatibility text, code, and
optional detail.  Keiro does not import that adapter package, so this plan records release
compatibility and evidence but does not add it to the `keiro` runtime's Cabal dependency list.

All remaining implementation changes belong to packages in this repository.  The `keiro` runtime
package changes every `shibuya-core` bound to `^>=0.9.0.0` and otherwise continues using
`keiro-core`, `keiki`, and `kiroku-store`.  The `keiro-dsl` package continues using its existing
`keiki` and `keiro-core` dependencies; it must not acquire a dependency on the `keiro` runtime
merely to validate a spec.  Mirror any small closed runtime vocabulary in the DSL checker and
protect it with `keiro-dsl-runtime-vocabulary-test`, following the existing pattern.

The same Cabal workspace contains `keiro-pgmq` and `jitsurei`, whose direct dependency bounds must
admit the one selected Shibuya version.  Their existing adapter dependencies therefore use
`shibuya-pgmq-adapter ^>=0.14.0.0`; this alignment does not add the adapter to `keiro` or
`keiro-dsl`.

`keiro/src/Keiro/Router/Selection.hs` must export these semantic types.  Constructor names may
be adjusted for repository naming conventions, but the admitted states and smart-constructor
invariants must not be weakened:

```haskell
newtype RecipientLimit = RecipientLimit Natural

mkRecipientLimit :: Natural -> Either RouterSelectionFailure RecipientLimit

newtype SelectionIdentity = SelectionIdentity Text
newtype SelectionVersion = SelectionVersion Natural
newtype SelectionFingerprint = SelectionFingerprint Text

data SelectionOrder = OrderByTargetStream
data SelectionDedupe = DedupeByTargetStream
data RedeliveryPolicy = StableUnion
data PartialDispatchPolicy = RetainSuccesses

data EmptySelectionPolicy
  = EmptyAck
  | EmptyRetry
  | EmptyDeadLetter
  | EmptyHalt

data SelectionFailurePolicy
  = FailureRetry
  | FailureDeadLetter
  | FailureHalt

data RouterSelectionContract = RouterSelectionContract
  { identity :: SelectionIdentity
  , version :: SelectionVersion
  , fingerprint :: SelectionFingerprint
  , limit :: RecipientLimit
  , order :: SelectionOrder
  , dedupe :: SelectionDedupe
  , emptyPolicy :: EmptySelectionPolicy
  , failurePolicy :: SelectionFailurePolicy
  , redeliveryPolicy :: RedeliveryPolicy
  , partialPolicy :: PartialDispatchPolicy
  }

data RouterSelectionFailure
  = SelectionQueryFailed Text
  | SelectionEvaluationFailed Text
  | SelectionConflictingCommands StreamName
  | SelectionRecipientOverflow RecipientLimit Natural

normalizeRecipients
  :: Eq targetCi
  => RecipientLimit
  -> [PMCommand targetCi]
  -> Either RouterSelectionFailure [PMCommand targetCi]

emptySelectionDeadLetterReason
  :: RouterSelectionContract
  -> DeadLetterReason

selectionFailureDeadLetterReason
  :: RouterSelectionContract
  -> RouterSelectionFailure
  -> DeadLetterReason
```

`RecipientLimit` and `SelectionVersion` receive public smart constructors that reject zero;
their data constructors should be hidden if that best fits the current package style.  The
fingerprint text is lowercase hexadecimal over the repository's chosen cryptographic digest.
`normalizeRecipients` obtains the physical identity with `Keiro.Stream.streamName` from each
`PMCommand.target`; it does not compare DSL row identities.  The two dead-letter helpers return
`ApplicationFailure` using top-level `DeadLetterCode` values constructed once with
`mkDeadLetterCode`.  The stable codes are
`keiro.router.selection.empty`, `keiro.router.selection.query_failed`,
`keiro.router.selection.evaluation_failed`, `keiro.router.selection.target_conflict`, and
`keiro.router.selection.recipient_overflow`.  Human detail must be useful to an operator but must
not include raw SQL, credentials, full payloads, or unrestricted backend error text.  Focused
tests call `deadLetterReasonCode`, `deadLetterReasonDetail`, and `renderDeadLetterReason` on every
helper result so Keiro never depends on a partial constructor match.

`keiro/src/Keiro/Router.hs` must add an additive definition and runners while retaining every
legacy `Router` field and function:

```haskell
data DeclarativeRouter input targetPhi targetRs targetState targetCi targetCo es =
  DeclarativeRouter
    { name :: Text
    , key :: input -> Text
    , selectionContract :: RouterSelectionContract
    , select :: input -> Eff es (Either RouterSelectionFailure [PMCommand targetCi])
    , targetEventStream :: ValidatedEventStream targetPhi targetRs targetState targetCi targetCo
    , targetProjections :: Stream targetCi -> [InlineProjection targetCo]
    }

data DeclarativeRouterResult target
  = DeclarativeSelectionFailed RouterSelectionFailure
  | DeclarativeSelectionEmpty
  | DeclarativeSelectionDispatched (RouterResult target)

runDeclarativeRouterOnce
  :: (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es,
      KirokuStoreResource :> es, BoolAlg targetPhi (RegFile targetRs, targetCi),
      Eq targetCi, Eq targetCo)
  => RunCommandOptions
  -> DeclarativeRouter input targetPhi targetRs targetState targetCi targetCo es
  -> RecordedEvent
  -> input
  -> Eff es (DeclarativeRouterResult (EventStream targetPhi targetRs targetState targetCi targetCo))

runDeclarativeRouterWorkerWith
  :: (HasCallStack, IOE :> es, Store :> es, Error StoreError :> es,
      KirokuStoreResource :> es, BoolAlg targetPhi (RegFile targetRs, targetCi),
      Eq targetCi, Eq targetCo)
  => WorkerOptions es msg
  -> RunCommandOptions
  -> DeclarativeRouter input targetPhi targetRs targetState targetCi targetCo es
  -> Adapter es msg
  -> (msg -> Maybe (RecordedEvent, input))
  -> Eff es ()
```

Also export `runDeclarativeRouterWorker` with `defaultWorkerOptions`, parallel to the legacy API.
The `Once` runner returns the typed selection result; only worker runners lower empty/failure
policies to Shibuya `AckDecision` values.  Both router families call one internal dispatch helper
that preserves `deterministicRouterCommandId` and the legacy-id compatibility check exactly.

`keiro-dsl/src/Keiro/Dsl/RouterSelection.hs` must expose the checker-owned value used by all
downstream phases:

```haskell
data CheckedRouterSelection = CheckedRouterSelection
  { checkedIdentity :: Text
  , checkedVersion :: Natural
  , checkedQuery :: CheckedReadModelQuery
  , checkedInputBinding :: CheckedMappedExpr
  , checkedRowBinding :: CheckedMappedType
  , checkedPredicate :: CheckedScalarExpr
  , checkedRecipient :: CheckedScalarExpr
  , checkedCommandFields :: Map Name CheckedScalarExpr
  , checkedLimit :: Natural
  , checkedOrder :: CheckedSelectionOrder
  , checkedDedupe :: CheckedSelectionDedupe
  , checkedEmptyPolicy :: CheckedEmptySelectionPolicy
  , checkedFailurePolicy :: CheckedSelectionFailurePolicy
  , checkedRedeliveryPolicy :: CheckedRedeliveryPolicy
  , checkedPartialPolicy :: CheckedPartialDispatchPolicy
  , checkedFingerprint :: Text
  , checkedUseSites :: [UseSite]
  }

checkRouterSelection
  :: EffectiveLanguageContract
  -> TypeGraph
  -> Spec
  -> RouterNode
  -> Either (NonEmpty Diagnostic) CheckedRouterSelection

routerSelectionFingerprint :: CheckedRouterSelection -> Text
```

Here `CheckedReadModelQuery`, `CheckedMappedExpr`, `CheckedMappedType`, and
`CheckedScalarExpr` mean the repository's existing checked equivalents; if no public alias has
exactly that name, introduce the smallest selection-specific wrapper over the existing
`TypeGraph` evidence rather than storing parser expressions.  The fingerprint function must
consume the canonical checked encoder and ignore `checkedFingerprint` itself.

Extend the semantic-impact vocabularies in
`keiro-dsl/src/Keiro/Dsl/SemanticImpact.hs` with one router-selection consumer and distinct
roots/consequences:

```haskell
data RouterSelectionPosition
  = SelectionQueryInput
  | SelectionPredicate
  | SelectionRecipient
  | SelectionCommandField Name

-- Add to MappedConsumer:
RouterSelectionConsumer Name RouterSelectionPosition

-- Add to MappedRootKind:
MappedRouterSelectionQueryInputRoot
MappedRouterSelectionPredicateRoot
MappedRouterSelectionRecipientRoot
MappedRouterSelectionCommandFieldRoot

-- Add to MappedConsequence:
MappedRouterSelectionBuild Name
MappedRouterSelectionCoordinationReview Name
```

Create `keiro-dsl/src/Keiro/Dsl/CoordinationImpact.hs` with an append-only report vocabulary:

```haskell
data SelectionVerification = DeclarativeVerified | CustomUnverified

data CoordinationSeverity = CoordinationAdvisory | CoordinationBreaking

data CoordinationReason
  = SelectionIdentityChanged
  | SelectionVersionDecreased
  | SelectionFingerprintChangedWithoutVersionBump
  | SelectionFingerprintChangedWithVersionBump
  | SelectionVersionMetadataOnly
  | SelectionVerificationBoundaryChanged
  | SelectionMappedDependencyChanged

data CoordinationImpact = CoordinationImpact
  { router :: Name
  , severity :: CoordinationSeverity
  , reason :: CoordinationReason
  , previousVerification :: SelectionVerification
  , currentVerification :: SelectionVerification
  , previousIdentity :: Maybe Text
  , currentIdentity :: Maybe Text
  , previousVersion :: Maybe Natural
  , currentVersion :: Maybe Natural
  , previousFingerprint :: Maybe Text
  , currentFingerprint :: Maybe Text
  , affectedUseSites :: [UseSite]
  }

coordinationImpact
  :: CheckedService
  -> CheckedService
  -> [MappedImpactDelta]
  -> [CoordinationImpact]
```

Add `Maybe [CoordinationImpact]` fields to `DiffReport` and `WorkspaceDiffReport`, plus additive
smart constructors analogous to `diffReportWithSemanticImpact`.  JSON renders the value under
`coordinationImpact`; legacy constructors omit the key.  Human-readable output must render the
same records.  Do not add these fields to `ReplayImpact` or reinterpret its aggregate-focused
types.


## Revision Notes

- 2026-08-10: Reconciled the completed upstream implementations.  Recorded Shibuya Plan 32 and
  `shibuya-core` 0.9.0.0, PGMQ adapter Plan 5 and adapter 0.14.0.0, their authoritative Hackage/tag
  evidence, the exact `ApplicationFailure`/`DeadLetterCode` API, and the adapter's three-field
  dual-write contract.  Split Milestone 0 progress between completed external releases and the
  still-pending Keiro bound/API adoption so the plan does not imply that IR-9 implementation has
  begun.  No local ADR changed because this revision records a completed dependency handoff; the
  Keiro normalization/versioning ADR remains a Milestone 5 deliverable.
- 2026-08-11: Completed Milestone 0 and revised its workspace scope after Cabal demonstrated that
  local `keiro-pgmq` and `jitsurei` upper bounds participate in the same solver plan.  Recorded the
  aligned direct constraints, replacement of the old exhaustive adapter-side renderer, public
  vocabulary proof, exact resolved versions, and the remaining Milestone 1 starting point.
- 2026-08-11: Completed Milestone 1.  Recorded the typed declarative/custom grammar boundary,
  checker-owned semantic IR and diagnostics, mapped-path totality rules, positive bound and fixed
  policy checks, SHA-256 fingerprint choice, workspace location coverage, focused mutation tests,
  and the bounded/unbounded executable evidence.  Milestone 2 now starts from a checked value and
  does not need to reinterpret parser expressions.
- 2026-08-11: Completed Milestone 2.  Recorded the runtime contract, pre-dispatch physical-target
  normalization, safe application dead-letter lowering, additive once/worker APIs, extraction of
  the byte-compatible legacy dispatch path, and database-backed evidence for the cap, conflict,
  partial-success, redelivery, and policy guarantees.  Milestone 3 can now generate only checked
  declarations into this public runtime surface.
