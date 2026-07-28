---
id: 152
slug: prove-migrations-with-shadow-codec-comparison-and-structural-coverage-reporting
title: "Gather migration evidence with historical codec comparison and supported-root coverage reporting"
kind: exec-plan
created_at: 2026-07-28T10:49:00Z
intention: "intention_01kym5dc4ve69sxsjtzd81pbbz"
master_plan: "docs/masterplans/25-structural-consumer-type-ergonomics-and-soundness-preserving-adoption-for-keiro-dsl.md"
---

# Gather migration evidence with historical codec comparison and supported-root coverage reporting

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today a team migrating an existing event-sourced service onto `keiro-dsl`'s structural
consumer-owned types has no tool that tells them whether the codec Keiro will generate
produces the same JSON meaning as the historical codec
that wrote their history. They either eyeball JSON, or they cut over on faith. Separately,
once the opaque escape hatch exists (an "opaque external-codec type" is a declaration where
Keiro stores and round-trips a value using the consumer's own `ToJSON`/`FromJSON` instances
but makes no claim about the JSON inside it), nothing measures how much of a service's
persisted wire surface is actually structurally declared versus opaque. Years later, most
of the surface could be opaque and the `diff` gate would be theater — every review would
pass because Keiro was honestly claiming nothing.

After this plan, two things exist. First, scaffold can emit a non-production comparison runner
module for one structural mapped type. A hand-owned test or small executable compiles that module
with the consumer package, passes an explicit `HistoricalCodec a` value and a historical-golden
directory, and receives a `CompareReport`. The runner encodes declared typed fixture cases with
both codecs, decodes the parsed historical JSON corpus with both, and reports canonical JSON equality, decode
differences, and missing historical coverage (declared union arms and optional/null branches
with no decodable historical golden; plan 150 separately enforces typed-case coverage). Every
difference is classified as exact parity or as explicit version/upcaster
work — never "close enough". The runner's rendered output states, verbatim, that a passing
comparison is migration evidence only and that the generated codec is the sole wire
authority after cutover. Second, `check` (and `diff`) can emit a machine-readable
structural-versus-opaque report for the roots the mapped type graph actually supports: private
aggregate event payloads, plus mapped snapshot registers explicitly labeled as a consumer-JSON
cache/invalidation boundary. Queue payloads and public contracts are reported as unsupported,
not assigned invented coverage. An optional, off-by-default policy gate can reject opaque roots
or opaque growth. You can see both working by running the transcripts in Concrete Steps against
the conformance fixtures this plan adds.

This plan implements the shadow-comparison and coverage-reporting improvements from
`docs/research/14-structural-consumer-type-tradeoffs.md` (sections 1, 3, and 12, and
Experiment B) for the capability requested by
`docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md` (IR-1).


## Progress

- [x] 2026-07-28: Milestone 1 completed: `Keiro.Dsl.CodecCompare` exposes RFC 8785
      classification, structured pointer-addressed differences, invalid-input and branch-gap
      reporting, stable JSON/human rendering, success semantics, and atomic report writing;
      `keiro-dsl-test` passes 294 examples.
- [x] 2026-07-28: Milestone 2 completed: scaffold emits an explicitly requested,
      non-production comparison module; the consumer-owned runner and generalized Experiment B
      corpus prove omitted-key and legacy-tag differences while covering every optional/null and
      five-arm union branch; `keiro-dsl-test` passes 297 examples and
      `keiro-dsl-conformance-codec-compare` passes all eight assertions.
- [x] 2026-07-28: Milestone 3 completed: `Keiro.Dsl.Coverage` reports named private-event,
      explicit-`Json`, opaque, and consumer-JSON register boundaries; `check` and `diff` write
      stable JSON and human summaries; diff records previous counts/deltas; the two rejection
      policies remain opt-in; six registry codes were appended; `keiro-dsl-test` passes 302
      examples.
- [ ] Milestone 4: documentation — brownfield-guide shadow-comparison section, evolution-guide
      update, new coverage-policy ADR, ADR 0004 inventory amendment if a gate row was added.
- [ ] Final: Proposal Test answers recorded, ADR distillation pass, plan marked complete.


## Surprises & Discoveries

- Keiro's codec abstraction returns `Value`, so byte parity is not an owned contract; comparison
  is canonical JSON/decode evidence through an explicit historical codec value.
- The mapped graph covers private event/register roots, not queue payloads or public contracts,
  and the current snapshot cache uses consumer JSON. Ratios across all four surfaces would be
  fabricated evidence; the revised report names supported roots, cache boundaries, and
  unsupported surfaces separately.
- Mori has no registered upstream Aeson project, so dependency discovery stopped there rather
  than consulting a package-store checkout. Hackage currently lists Aeson 2.2.5.0 as the newest
  release inside Keiro's existing `<2.3` line (2.3.1.0 is newest overall), upstream publishes
  matching `v2.2.5.0` and `v2.3.1.0` tags, and the upstream source marks
  `Data.Aeson.RFC8785.encodeCanonical` as available since 2.2.1.0. The library bound is therefore
  `aeson >=2.2.1 && <2.3`.
- A historical union-arm spelling can differ from the generated spelling while still proving
  that the same semantic arm was exercised. Historical coverage therefore observes both the raw
  input (which preserves missing/null evidence) and the successfully decoded value re-encoded by
  the generated codec (which supplies the canonical semantic arm); the raw spelling mismatch
  remains a comparison failure.
- A mapped register is a consumer-JSON cache boundary even when its aggregate currently has no
  snapshot policy. The report therefore inventories every mapped register, carries
  `snapshotEnabled` separately, and never calls its wire fingerprint structural snapshot-codec
  coverage.


## Decision Log

- Decision: The comparison engine's semantic-equality check uses RFC 8785 canonical JSON
  bytes, obtained from aeson's own `Data.Aeson.RFC8785.encodeCanonical`, not from the
  `keiro` package.
  Rationale: The repository already standardizes on RFC 8785 canonical bytes for replay-audit
  correctness (ADR 0004: "Correctness compares RFC 8785 canonical bytes"). The implementation
  the runtime uses is `keiro/src/Keiro/ReplayDigest.hs` (`canonicalJsonBytes`), but that lives
  in the `keiro` package, and the `keiro-dsl` library deliberately does not depend on `keiro`
  (its build-depends are aeson/base/containers/megaparsec/etc. only). `canonicalJsonBytes` is
  itself a one-line wrapper over `Data.Aeson.RFC8785.encodeCanonical`, which ships in aeson
  (>= 2.2.1), already inside keiro-dsl's dependency footprint. Using the same aeson primitive
  keeps the algorithm identical to the replay audit without inverting the package layering.
  Date: 2026-07-28

- Decision: Historical comparison is split into a pure classification engine in the
  `keiro-dsl` library and an opt-in generated runner module that the consumer compiles. The
  `keiro-dsl` executable emits that module through scaffold; it does not pretend it can receive
  or execute a Haskell value across a process boundary.
  Rationale: Historical behavior must be supplied as an explicit `HistoricalCodec a` record,
  not rediscovered through global `ToJSON`/`FromJSON` instances that may have changed since the
  bytes were written. The `keiro-dsl` executable cannot call arbitrary Haskell at runtime, so
  a thin CLI "orchestrator" would require an unspecified build/plugin protocol and would be a
  misleading public API. The honest execution boundary is generated code compiled against the
  consumer package, exactly as the conformance harness already executes fixture bindings.
  The engine (corpus loading, canonical comparison, classification, report rendering) stays
  in the library so it is unit-testable without any consumer package.
  Date: 2026-07-28

- Decision: The coverage report is reporting-first; rejection is behind explicit opt-in policy
  (`--fail-on-opaque` for one spec or `--fail-on-opaque-increase` for diff), and default behavior
  never fails a build.
  Rationale: How much opacity is acceptable is an operator policy choice, not a soundness
  fact. Research note section 3 is explicit that conformance evidence must not upgrade the
  claim, and symmetrically a coverage number must not silently become a new rejection —
  that would punish honest opaque declarations and push authors toward dishonest structural
  ones. The report makes named-boundary drift visible; rejection policy belongs to the operator. This decision is
  the seed of the new ADR in Milestone 4.
  Date: 2026-07-28

- Decision: Draft this plan against the local generation-layer API (the total
  `StructuralBinding` binding type, generated structural codecs, one non-empty fixture
  binding, and the conformance-harness contract) as its hard dependency
  `docs/plans/150-implement-the-ir-1-generation-layer-bindings-api-generated-codecs-scaffold-and-conformance-harness.md`
  will land it, and require the implementer to read plan 150's landed state before writing
  any code.
  Rationale: Plan 150 (the MasterPlan's EP-7) is a hard dependency and is not yet
  implemented at drafting time. Module names and exact signatures below are therefore
  targets defined by IR-1 and the MasterPlan's integration points ("EP-7 must publish the
  API in a dedicated module with a stability note before EP-8/EP-9 begin"); the landed API
  is authoritative and this plan must be revised to match it, recording any divergence in
  this Decision Log.
  Date: 2026-07-28

- Decision: Compare `Value` semantics, not serialization bytes. `HistoricalCodec a` encodes to
  and decodes from `Value`; the engine canonicalizes Values for deterministic paths/digests.
  Rationale: Keiro's codec abstraction returns `Value`, so it does not own whitespace or object
  key ordering. Claiming byte equality would test a chosen final renderer rather than either
  codec's API contract.
  Date: 2026-07-28

- Decision: Coverage reports only actual mapped-graph roots. Private event payloads are counted
  structurally/opaquely; mapped snapshot registers are a cache boundary with invalidation status,
  not structural codec coverage; queue payloads and public contracts are unsupported/not-applicable.
  Rationale: The proposed graph does not model those other surfaces, and current snapshots use
  consumer JSON instances. A broad percentage would manufacture evidence and blur ownership.
  Date: 2026-07-28

- Decision: The acceptance scenario generalizes research-note Experiment B instead of using
  Mori's `DocInfo` directly.
  Rationale: Experiment B names Mori's `DocInfo` goldens, but `DocInfo` lives downstream in
  the Mori repository, and IR-1's Out of Scope section keeps Mori transducer work out of
  Keiro. The scenario's shape — a hand-written historical Aeson codec with missing-field,
  explicit-null, and unknown-field quirks plus a multi-arm tagged union — is reproduced with
  repo-local fixture types in a keiro-dsl conformance suite, preserving Experiment B's
  success criterion verbatim: differences are classified as exact parity or explicit
  version/upcaster work, nothing else.
  Date: 2026-07-28

- Decision: Keep comparison branch-inventory types in `Keiro.Dsl.CodecCompare`; generated code
  will construct `DeclaredBranch` and `ObservedBranch` by traversing the landed
  `Keiro.Dsl.TypeGraph` total algebras.
  Rationale: Plan 150 landed the checked graph and complete folds, but deliberately did not
  publish the placeholder branch-inventory types assumed by this draft. The comparison engine
  owns the migration-evidence vocabulary while the generator remains responsible for deriving
  it exhaustively from the schema authority.
  Date: 2026-07-28

- Decision: Reuse the plan-150 `ArtifactInfo` structural conformance ring for Experiment B and
  place its comparison runner outside the ordinary scaffold module/manifest/record inventory.
  Rationale: The landed fixture already has the exact required optional fields, defaults, nullable
  fields, and five-arm union plus real generated bindings and mapped codecs. A second near-identical
  model would test duplication rather than integration. Keeping the opt-in output out of the
  production inventory makes its migration-evidence-only authority mechanically visible.
  Date: 2026-07-28

- Decision: Compile the hand-owned runner as the sole executable of a small local conformance
  package rooted at `keiro-dsl/test`, while keeping the assertions as a
  `keiro-dsl` test-suite.
  Rationale: Adding a second executable to the `keiro-dsl` package makes Cabal interpret the
  established `cabal run keiro-dsl -- ...` command as an ambiguous package target. The separate
  local package preserves that public developer workflow and still lets
  `cabal run keiro-dsl-codec-compare-artifact-info` compile exactly the consumer-owned historical
  codec, generated runner, binding, fixtures, and generated codec together.
  Date: 2026-07-28

- Decision: Put coverage traversal and stable report types in the new exposed
  `Keiro.Dsl.Coverage` module, with explicit total `TypeExprAlgebra`, `MappedShapeAlgebra`, and
  `MappedDeclAlgebra` values for nested `Json` and mode discovery.
  Rationale: Coverage is a reporting boundary rather than validation or compatibility
  classification. Keeping it separate makes the report reusable by both `check` and `diff`, while
  the total folds ensure a future resolved-expression constructor cannot be silently omitted.
  Event roots and register-cache roots remain separate inventories, and only the former produces
  opaque-surface policy findings.
  Date: 2026-07-28


## Outcomes & Retrospective

(To be filled during and after implementation.)

Milestone 1 delivered the pure comparison boundary independently of generated consumer code.
The engine has only parity and explicit-version-work verdicts, treats rejection by the selected
historical codec as invalid corpus/provenance input, reports typed and historical branch gaps
separately, and carries the authority framing in both JSON and human output. The package build
and the 294-example unit suite pass.

Milestone 2 connected that engine to real generated/consumer code without adding a runtime
fallback. Scaffold refuses opaque or unreachable declarations and protects the explicitly named
output with its own banner, while the compiled consumer fixture demonstrates that omitted optional
keys and a legacy union tag are never accepted as parity. The complete corpus has no coverage gaps;
the deliberately incomplete corpus proves the missing-arm gate fires.

Milestone 3 made adoption drift visible without redefining soundness. A report request emits named
roots and boundaries plus advisory codes, while an ordinary `check` or `diff` performs no coverage
work and retains its prior output/exit behavior. The check gate rejects existing opaque private
event boundaries only when asked; the diff gate rejects only newly added named boundaries. A live
CLI mutation added a second opaque event root and produced
`CoverageOpaqueBoundaryAdded`/`CoverageOpaqueGateExceeded`, then the fixture was restored.


## Context and Orientation

This repository is a Cabal multi-package Haskell project (see `cabal.project` at the repo
root: packages `keiro`, `keiro-core`, `keiro-migrations`, `keiro-pgmq`, `keiro-test-support`,
`jitsurei`, `keiro-dsl`). All work in this plan happens in the `keiro-dsl` package and under
`docs/`. `keiro-dsl` is a specification toolchain: you write a service description in a
`.keiro` text file, and the toolchain parses it (`keiro-dsl/src/Keiro/Dsl/Parser.hs`),
validates it (`keiro-dsl/src/Keiro/Dsl/Validate.hs`), classifies changes between two spec
versions (`keiro-dsl/src/Keiro/Dsl/Diff.hs`), and emits generated Haskell plus typed holes
(`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`) and a conformance harness
(`keiro-dsl/src/Keiro/Dsl/Harness.hs`). The CLI in `keiro-dsl/app/Main.hs` currently exposes
the subcommands `parse`, `check`, `scaffold`, `diff`, and `new` via optparse-applicative.

Terms used throughout, in plain language:

- A *structural mapped type* (from IR-1) is a consumer-owned Haskell type (record, enum, or
  tagged union) whose wire shape is declared inside the `.keiro` spec — field keys, union
  tags, presence, nullability, defaults — and whose encoder/decoder Keiro generates. A typed
  *binding* (`StructuralBinding`) converts between the consumer type and the declared shape;
  it never supplies a second JSON schema.
- An *opaque external-codec type* is the honest alternative: Keiro stores and round-trips
  the value using the consumer's own codec identity and version, and makes no claim about
  the JSON below the boundary.
- The *historical consumer codec* is an explicit `HistoricalCodec a` value that reconstructs
  the writer/reader behavior relevant to the selected release; it is not a lookup of today's
  global instances.
- A *historical corpus* is a directory of JSON files captured from production or old tests; it
  exercises decoding. The declaration's one non-empty `FixtureCases a` binding is a separate,
  typed corpus compiled into the runner and exercises both encoders. Successful decodes are
  normalized through the structural binding and generated shape encoder before comparison, so
  the API does not require an `Eq a` instance merely for migration tooling.
- *Semantic JSON equality* means equality of RFC 8785 canonical bytes — JSON with sorted
  object keys and normalized number/string forms, so two encodings that differ only in key
  order or whitespace compare equal, while a real difference (a missing key versus an
  explicit `null`) does not.
- *Opaque creep* is the drift failure mode where, over years, more and more of the persisted
  surface is declared opaque, so `diff`'s structural guarantees quietly cover less and less.

Hard dependency. This plan builds directly on the IR-1 generation layer delivered by
`docs/plans/150-implement-the-ir-1-generation-layer-bindings-api-generated-codecs-scaffold-and-conformance-harness.md`
(the MasterPlan's EP-7): the `StructuralBinding` API and its published module, the generated
structural codecs, the fixtures binding, and the conformance-harness
architecture that compiles generated modules against consumer types (the existing pattern
is visible in the `keiro-dsl-conformance` test-suite in `keiro-dsl/keiro-dsl.cabal`, whose
`Generated.*` modules under `keiro-dsl/test/conformance/` are pinned byte-identical to
scaffold output). **Before writing any code, read plan 150 in its landed state** — its
Interfaces and Dependencies section names the real module paths and signatures — and revise
the module names and signatures in this plan to match, logging any divergence in the
Decision Log. At drafting time plan 150 is not yet implemented, so everything below that
references the binding API uses IR-1's specified semantics
(`docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md`,
sections "Structural mapped types", "Conformance Harness Contract").

Soft dependency. `docs/plans/151-reduce-binding-boilerplate-skeleton-scaffolds-derived-nominal-bindings-and-explain-bindings.md`
(EP-8) makes binding fixtures cheaper to author via skeleton scaffolds. If it has landed,
use its skeleton scaffolder to author this plan's conformance fixtures; if not, write the
bindings by hand — nothing here requires EP-8 to compile.

Background requirement sources, checked in and translated through ADR 0012 and the local APIs:

- `docs/research/14-structural-consumer-type-tradeoffs.md`. Section 1 ("We Give Up Arbitrary
  Codec Reuse in Structural Mode") motivates and sketches a `codec compare` command. This plan
  preserves the behavior but moves execution into a consumer-compiled runner because a standalone
  executable cannot receive a Haskell codec value. The research requirements include semantic
  JSON equality, decode differences,
  missing coverage) and the authority rule: "Passing the comparison is migration evidence;
  the generated codec remains the authority after cutover." Section 3 ("Opaque Mode Gives Up
  Nested Compatibility Knowledge") states the rule this plan must never violate:
  "Support conformance evidence without upgrading the claim" — fixture corpora and passing
  comparisons may justify operator trust "but must not silently change an opaque diagnostic
  into a structural guarantee." Section 12 ("Existing History Makes Structural Adoption a
  Migration") defines the migration discipline the runner serves: import real goldens, run
  shadow comparison, version rather than normalize silently, retain legacy decoders only at
  the version boundary. Experiment B ("Historical shadow comparison") supplies the
  acceptance scenario and its success criterion: "differences are classified as exact parity
  or explicit version/upcaster work." Its "A Proposal Test for Future Keiro Improvements"
  section defines the ten-question soundness gate answered in Validation and Acceptance.
- `docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md`
  (IR-1). Its Design Principles (one wire-schema authority; bindings typed and explicit),
  Conformance Harness Contract (fixture bindings, branch and union-arm coverage), and Out of
  Scope list ("Proving that an arbitrary external `ToJSON` or `FromJSON` instance matches a
  structural declaration" is out of scope — which is exactly why the comparison runner produces
  evidence over a finite corpus, not a proof) bound this plan's claims.

Relevant local ADRs (filenames scanned in `docs/adr/`; only these are relevant):

- `docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md` (ADR-4).
  Defines the layered gate model, the machine-readable `DiagnosticCode` correlation between
  `check` and `diff`, the gate-inventory table, its amendment protocol ("The inventory is
  amended when a later child plan changes a gate's ownership"), and the canonical-bytes rule
  ("Correctness compares RFC 8785 canonical bytes; SHA-256 digests are review identifiers").
  This plan appends DiagnosticCodes, reuses the canonical-bytes convention, and amends the
  inventory if the optional coverage gate constitutes a new gate row (it does — see
  Milestone 4).
- `docs/adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md` (ADR-3) is
  background for why snapshots are one of the four persisted surfaces the coverage report
  enumerates; no change to it is planned.

No existing local ADR covers shadow comparison or coverage policy; Milestone 4 creates one.
The `docs/adr/` directory is a profile-governed OKF bundle (`docs/adr/profile.dhall`,
reserved `log.md`); ADR authoring must follow the ID-allocation and strict-validation
workflow in `.claude/skills/exec-plan/ADR.md`, restated concretely in Milestone 4.
Cross-repository context: IR-1 cites Mori's originating plan
`mori://shinzui/mori/plans/171-extend-keiro-dsl-for-structural-mori-domain-contracts` and
Mori's ADR `mori://shinzui/mori/okf/adrs/concepts/ADR-6`; neither needs to be read to
implement this plan.

Documentation surfaces this plan touches: the brownfield migration guide created by
`docs/plans/145-write-the-brownfield-migration-and-transducer-modeling-guide.md` (EP-2; the
MasterPlan states EP-9 appends its comparison-workflow section to that guide, and plan 145 leaves a
named anchor point for it — the `codec-compare-tooling` `appended-by` comment in
`docs/guides/brownfield-migration-and-transducer-modeling.md`, at the end of its "Shadow
comparison of old and new codecs" chapter),
and `docs/guides/evolution-and-replayability.md` (a landed guide; its "The gates, at a
glance" and "Gate coverage summary" sections are where the coverage report is mentioned).

Where the diagnostic registry lives: `keiro-dsl/src/Keiro/Dsl/Validate.hs` defines the
`DiagnosticCode` enum beginning near line 39. It is the single append-only registry shared
by `check` and `diff` (ADR 0004). New codes go at the end of the enum; never rename or
reuse an existing constructor.

Build and test commands (verified against `cabal.project`, `Justfile`, and
`keiro-dsl/keiro-dsl.cabal`): development happens inside the Nix dev shell (`nix develop`
from the repo root; `flake.nix` provides GHC 9.12 and tooling). From the repo root:
`cabal build keiro-dsl` builds the package; `cabal test keiro-dsl-test` runs the unit
suite; `cabal test keiro-dsl-conformance` (and siblings such as
`keiro-dsl-conformance-snapshot`) run the conformance suites; `just adr-validate` runs the
strict OKF check over `docs/adr`; `just verify` is the full repository gate
(process-compose check, jitsurei, `cabal build all`, tests, adr-validate).


## Plan of Work

The work proceeds in four milestones. Each is independently verifiable and the plan's story
is: first make comparison classification a pure, testable fact; then wire it to explicit real
codecs through generated code and gather finite corpus evidence; then make opacity measurable;
then write down the policy and teach the migration path.

### Milestone 1 — The comparison engine as a pure library

Scope: a new module `keiro-dsl/src/Keiro/Dsl/CodecCompare.hs` (exposed in
`keiro-dsl/keiro-dsl.cabal` under `exposed-modules`) that defines the report model and the
classification logic with no IO against consumer code. At the end of this milestone you can
feed the engine two lists of encode/decode results and a coverage inventory and get back a
deterministic, machine-readable report; `cabal test keiro-dsl-test` exercises it.

Define, in prose here and in Haskell there: a `CompareInput` per fixture (fixture path,
origin — historical golden or generated-from-binding — parsed historical/generated `Value`,
historical decode outcome, generated decode outcome, and for decode
outcomes a re-encode of the decoded value so semantic decode agreement is checkable); a
`FixtureVerdict` with exactly two constructors: `JsonParity` (canonical Values equal) and
`RequiresVersionWork` (canonical Values differ, or decode outcomes disagree) carrying a
structured `ComparisonDifference` with the first divergent JSON Pointer and reason. Human
prose is rendered from that value rather than stored as the machine contract. There is deliberately no
"close enough" constructor; Experiment B's success criterion is that every difference is
parity or explicit version/upcaster work. A historical golden that the declared historical
codec itself cannot decode is not a compatibility verdict: it is a fatal `CompareInputIssue`
identifying a corrupt corpus or wrong historical codec version. It must never be called parity
merely because the generated decoder also rejects it. Coverage is a separate list of origin-tagged
`CoverageGap` values naming each declared union arm, optional-field presence branch, and
null branch that the historical corpus did not exercise; typed `FixtureCases` coverage remains
plan 150's conformance failure and is also shown separately in the report (the declared branches come from the
resolved type-expression graph plan 149 lands, consumed here through plan 150's generation
layer; the engine takes the branch inventory as
input so it stays pure). The report renderer produces both the human transcript shown in
Concrete Steps and a JSON document (via aeson) with stable field names; the JSON top level
carries `"authority"` prose stating the migration-evidence-only framing and a mandatory
`CompareProvenance` object containing the historical codec id/version, structural canonical
type, binding symbol/version, and generated wire fingerprint. The pure report constructor
receives this provenance explicitly; it must not recover it from global instances or free-form
observation labels.

Deterministic comparison/digests use `Data.Aeson.RFC8785.encodeCanonical` from aeson (see Decision Log:
same algorithm as the runtime's `Keiro.ReplayDigest.canonicalJsonBytes`, without a
package-layering inversion; raise keiro-dsl's aeson lower bound to `>=2.2.1` if the module
is not present at the current `>=2.2` bound). Unit tests in `keiro-dsl/test/` cover: key
order and whitespace disappear while parsing and classify as `JsonParity`; omitted-key versus
explicit-`null` classifies as `RequiresVersionWork`; a historical-accepts/generated-rejects
decode disagreement classifies as `RequiresVersionWork`; an uncovered union arm
produces a `CoverageGap`; a historical decoder failure produces `CompareInputIssue` and no
fixture verdict; and the JSON report round-trips.

### Milestone 2 — The scaffolded comparison runner and the Experiment B fixture

Scope: opt-in runner generation, a hand-owned runner executable, and finite conformance evidence. At
the end of this milestone the transcripts in Concrete Steps work against a repo-local
fixture, and `cabal test keiro-dsl-conformance-codec-compare` passes.

Extend `keiro-dsl scaffold` with opt-in `--codec-comparison NAME --comparison-out FILE` (the
two options are required together). It resolves `NAME` to one
structural mapped declaration and rejects an opaque declaration with a clear message: Keiro has
no structural claim to compare below an opaque boundary. It emits a deterministic, machine-owned
module such as `Generated.<Context>.Structural.CodecCompare.<MappedName>`, imports that type's
consumer type, generated codec, binding, shape module, and declared `FixtureCases`, and embeds the
declared branch inventory. It exports a runner roughly shaped as
`compareWithHistorical :: HistoricalCodec Domain -> FilePath -> IO CompareReport`; the path is a
directory of historical JSON goldens. The runner uses typed fixture cases for encode observations,
uses historical goldens for decode observations, normalizes successful decoder results through
`bindingToShape` plus the generated shape encoder, and feeds only those observations to the pure
engine. This avoids an unnecessary `Eq Domain` constraint and makes the compared semantics exactly
the structure Keiro claims.

The generated module constructs `CompareProvenance` from the supplied historical codec and the
checked declaration/generated fingerprint, then returns a report; it does not call `exitFailure`. A tiny hand-owned test or
executable chooses rendering, report paths, and process exit through library helpers such as
`reportSucceeded`. Provide `writeCompareReportAtomic` for the normal JSON-file path (temporary
file in the destination directory, then rename) so an interrupted evidence run never leaves a
valid-looking partial report. In this repository that caller lives in the
`keiro-dsl-conformance-codec-compare` test-suite. Downstream consumers compile the emitted module
in a test/tool component with a development dependency on `keiro-dsl`; it is not added to their
production library's exposed modules or import graph. The `HistoricalCodec` value is supplied by
that hand-owned caller, never by a `.keiro` symbol or a global instance lookup.

The comparison module is explicit tooling output, not part of the production generated ring: it
is not added to the production manifest or scaffold record, and ordinary scaffold runs neither
create nor report it as stale. The writer may overwrite exactly the `--comparison-out` file after
the same preflight checks as other generation, marks it machine-owned in the banner, and refuses
an existing file without that exact generated-tool ownership marker or an output path equal to a
hand-owned Holes/binding/caller path. This keeps opting into development
tooling from changing a consumer library's dependency surface.

CRITICAL FRAMING, stated here and emitted by the report renderer in both human and JSON
output: a passing comparison is MIGRATION EVIDENCE ONLY. The generated structural codec is
the sole wire authority after cutover. The runner must never be wired as a runtime
fallback path, must never select which codec runs, and must never upgrade an opaque
declaration to structural (research note section 3: conformance evidence must not upgrade
the claim). The runner imports both codecs solely to compare them; nothing it emits is
importable by production code paths, and the generated module carries a header comment
saying so.

The acceptance scenario generalizes Experiment B (see Decision Log). Add a new test-suite
`keiro-dsl-conformance-codec-compare` to `keiro-dsl/keiro-dsl.cabal` (modeled on the
existing `keiro-dsl-conformance` stanza) with hand-owned fixture code under
`keiro-dsl/test/conformance-codec-compare/`: a record type with an optional field, a
five-arm tagged union chosen as a consumer-neutral branch-coverage example, and a deliberately quirky
hand-written `HistoricalCodec` value that (a) omits the optional key when `Nothing` rather
than emitting `null`, (b) tolerates and drops unknown fields on decode, and (c) uses
constructor-spelled union tags that differ from the spec's declared wire tags for exactly
one arm. A `.keiro` spec under the same directory declares the structural shape matching
the historical wire contract for everything except that one arm and the null policy. The
historical corpus contains goldens covering missing fields, explicit nulls,
unknown fields, and every union arm. The suite asserts: the arms and fields where the
historical contract was faithfully transcribed report `JsonParity`;
the omitted-versus-null field and the renamed-tag arm report `RequiresVersionWork` with
the divergent path named; removing one arm's fixture from the corpus produces a
`CoverageGap` and a non-zero exit; and the report never contains any third category. This
is also the plan's required negative/falsification evidence (Proposal Test question 10): the
suite pins a corpus where the historical codec genuinely differs and asserts the runner refuses
to call it parity — if classification were incomplete or lenient, this test fails.

### Milestone 3 — Structural-versus-opaque coverage reporting

Scope: per-surface coverage accounting in `check` and `diff`, new DiagnosticCodes, an
optional gate flag. At the end of this milestone
`keiro-dsl check SPEC --coverage-report PATH` writes a JSON document CI can track, and the
default behavior of `check`/`diff` on any existing spec is unchanged.

Walk the resolved type-expression graph using plan 149's exported total fold/algebra; this
module constructs a complete coverage algebra so a new expression constructor breaks its
compilation. Report only roots present in that graph:

- private aggregate event payloads: root counts and the canonical identities/paths of
  structural declarations, opaque declarations, and explicit `Json` boundaries;
- mapped aggregate registers: root counts plus `snapshotEncoding = consumer-json-cache` and
  the generated fingerprint/invalidation status, never a structural snapshot-codec claim;
- queue payloads and public contracts: `support = unsupported`/`not-applicable`, with no ratio.

Do not combine arbitrary type and field counts into one percentage. Emit stable per-root counts,
opaque-boundary paths, and unsupported surfaces as JSON. Add `--coverage-report PATH` to both
`check` and `diff` in `keiro-dsl/app/Main.hs` (on `diff`, the report additionally carries
the previous ref's numbers and the delta, so CI can alert on drift direction, not just
level). Also print a one-line human summary per surface when the flag is given.

This is reporting, NOT a new rejection. Add optional `--fail-on-opaque` to `check` and
`--fail-on-opaque-increase` to `diff`, accepted only with `--coverage-report`. These policies
operate on named roots/boundaries rather than ratios. The default emits Advisory diagnostics only.

Append to the end of the `DiagnosticCode` enum in `keiro-dsl/src/Keiro/Dsl/Validate.hs`
(the shared append-only registry beginning near line 39; per ADR 0004, tests and tooling
match on codes, not prose): `CoverageOpaqueSurface` (advisory: this persisted root contains
opaque declarations; carries the roots), `CoverageOpaqueBoundaryAdded` (advisory, diff
only: a named opaque boundary appeared since the compared ref), and
`CoverageOpaqueGateExceeded` (error, emitted only under an explicit policy flag). For the
comparison report, also append `CodecCompareDifference` (an observation classified as
`RequiresVersionWork`), `CodecCompareCoverageGap` (a declared branch with no fixture), and
`CodecCompareInvalidInput` (the chosen historical codec cannot decode one of its alleged
goldens) so
the compare report's machine consumers key on registry codes too. Do not rename or reuse
any existing constructor. Unit tests pin each new code's trigger and severity, and pin that
a spec with zero opaque declarations produces a report with zero opaque counts and no
advisory.

### Milestone 4 — Documentation and the coverage-policy ADR

Scope: teach the migration path and record the policy decision durably. At the end of this
milestone the brownfield guide's shadow-comparison anchor is filled, the evolution guide
names both new capabilities, a new ADR records the reporting-first coverage policy, ADR
0004's inventory is amended, and `just adr-validate` passes.

Append the shadow-comparison section to the brownfield migration guide created by
`docs/plans/145-write-the-brownfield-migration-and-transducer-modeling-guide.md` at the
named anchor point it leaves for EP-9 — the `codec-compare-tooling` `appended-by` comment
in `docs/guides/brownfield-migration-and-transducer-modeling.md`, at the end of its
"Shadow comparison of old and new codecs" chapter (if plan 145 has not landed yet, do not block — add the
section to a new appendix file only as a last resort and record the deviation in the
Decision Log, since the MasterPlan sequences EP-2 well before EP-9). The section walks the
migration discipline of research-note section 12 with the real generated-runner workflow:
capture goldens first, declare the shape from the historical wire contract, scaffold the
comparison module, run the consumer-owned comparison executable, then
either cut over on parity or write an explicit version bump and upcaster for every
`RequiresVersionWork` fixture — never normalize silently, and retain the legacy decoder
only as upcaster input at the version boundary, never as a second authority.

Update `docs/guides/evolution-and-replayability.md`: in "The gates, at a glance" and "Gate
coverage summary", add the coverage report as an observability aid (explicitly labeled as
reporting, not a gate, unless the operator opts into an explicit named-root policy flag), and mention
the scaffolded comparison runner in the persisted-payloads discussion as the migration-evidence tool.

Create the new ADR recording the structural-versus-opaque coverage policy: reporting-first;
opaque is honest and permitted; named-root rejection is operator policy via an explicit flag; a
passing shadow comparison never upgrades a claim; the comparison runner is migration
evidence only and never a runtime authority. Follow `.claude/skills/exec-plan/ADR.md`
exactly: allocate the docId with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`
(do not guess or count files), write the record at the bundle root with the required
frontmatter (`type: Architecture Decision Record`, `title`, one-sentence `description`,
`docId`, `status`, `date`, `timestamp`), maintain the reserved `docs/adr/log.md` with
`okf log add`, and run the strict validation shown in Concrete Steps.

Amend ADR 0004's gate-inventory table: the optional named-root opaque policy is a new gate
row (change class "opaque root present/growth beyond declared policy"; single-spec `check` emits
the report and, under the flag, `CoverageOpaqueGateExceeded`; cross-spec `diff` adds the
delta; no runtime boundary — the runtime is unaffected). Update ADR 0004's `timestamp`,
add a log entry, and re-run strict validation. Follow conventional commits for every
commit (e.g. `feat(dsl): add historical codec comparison runner`, `docs(adr): record
structural-versus-opaque coverage policy`); commit directly to the current branch.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`, inside the
Nix dev shell (`nix develop`). Update this section with actual transcripts as work lands.

Read the dependency's landed state first:

```bash
cat docs/plans/150-implement-the-ir-1-generation-layer-bindings-api-generated-codecs-scaffold-and-conformance-harness.md
```

Confirm its Progress section shows the `StructuralBinding` API, generated codecs, and
fixture bindings landed, and note the real module paths from its Interfaces and
Dependencies section. If plan 150 is not complete, stop: this plan's hard dependency is
unmet.

Build and unit-test after each milestone:

```bash
cabal build keiro-dsl
cabal test keiro-dsl-test
```

Expected tail of a passing unit run:

```text
Finished in ... seconds
... examples, 0 failures
```

Milestone 2's generated-runner workflow, against the conformance fixture (paths are targets;
keep them in sync with what you create):

```bash
cabal run keiro-dsl -- scaffold \
  keiro-dsl/test/conformance-codec-compare/artifact-store.keiro \
  --out keiro-dsl/test/conformance-codec-compare \
  --codec-comparison ArtifactRef \
  --comparison-out keiro-dsl/test/conformance-codec-compare/Generated/ArtifactStore/Structural/CodecCompare/ArtifactRef.hs
cabal run keiro-dsl-codec-compare-artifact-ref -- \
  --historical-goldens keiro-dsl/test/conformance-codec-compare/fixtures/artifact-ref \
  --report /tmp/artifact-ref-compare.json
```

The second executable is the repo-local, hand-owned `Main` that supplies the explicit
`HistoricalCodec ArtifactRef`; scaffold generates its imported comparison module but never edits
the caller.

Expected output shape (values illustrative; the framing lines are mandatory and verbatim
in intent):

```text
codec comparison: ArtifactRef (canonical-type "keiro.conformance.ArtifactRef.v1", binding-version "1")
historical codec: "keiro.conformance.ArtifactRef.aeson" version "legacy-v3"
observations: 12 (9 historical decode goldens, 3 typed encode cases)
  encode parity: 2/3 (RFC 8785 canonical form)
  structural decode agreement: 8/9
requires explicit version/upcaster work: 2 observations  [CodecCompareDifference]
  typed-case/absent-description [encode] at /description
    historical encoder omits "description" when absent; generated codec emits null
  fixtures/artifact-ref/arm-canonical.json [decode] at /tag
    union tag "Canonical" (historical) vs declared wire tag "canonical"
coverage gaps: 0
result: NOT PARITY — 2 differences
This comparison is MIGRATION EVIDENCE ONLY. After cutover the generated structural
codec is the sole wire authority. This runner is never a runtime fallback and never
upgrades an opaque declaration to structural. Resolve each difference with an explicit
version bump and upcaster, or correct the declaration to match the historical wire
contract; "close enough" is not an outcome.
```

The hand-owned executable exits `1` on that transcript (differences present) and `0` only when
every applicable observation is `JsonParity`, no input issue exists, and no coverage gap exists; on the passing
case the same authority framing block still prints. `/tmp/artifact-ref-compare.json` contains
the machine report with an `"authority"` field carrying the same statement, a structured
`"provenance"` object, and per-difference `"pointer"`/`"reason"` fields.

Run the Experiment B conformance suite:

```bash
cabal test keiro-dsl-conformance-codec-compare
```

Expected: the suite passes, meaning the quirky-historical-codec scenario produced exactly
the classifications described in Milestone 2 — including the negative-proof assertions
that the two genuine differences were refused parity.

Milestone 3's coverage report:

```bash
cabal run keiro-dsl -- check \
  keiro-dsl/test/conformance-codec-compare/artifact-store.keiro \
  --coverage-report /tmp/coverage.json
```

Expected human summary (shape, not exact numbers):

```text
structural/opaque boundaries (reporting only):
  private-event-payloads artifact-store/Artifact: 5 mapped roots (4 structural, 1 opaque)
  snapshot-registers     artifact-store/Artifact: 2 mapped roots; encoding=consumer-json-cache; invalidation=tracked
  queue-payloads: unsupported
  public-contracts: not-applicable (separately owned grammar)
coverage report written to /tmp/coverage.json
```

And the JSON document has stable keys: top-level `spec`, `roots`, `opaqueBoundaries`,
`snapshotBoundaries`, and `unsupportedSurfaces`. With `--fail-on-opaque` the same invocation
exits non-zero and names each offending root; without it the report never fails. On `diff`,
`--fail-on-opaque-increase` adds previous roots/delta and fails only on new opaque boundaries.

Milestone 4's ADR workflow:

```bash
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
# write docs/adr/NNNN-<slug>.md using the returned docId; then:
okf log add docs/adr --profile docs/adr/profile.dhall   # consult okf log add --help for exact form
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just adr-validate
```

Expected: validation reports no deviations. Finish with the repository gate:

```bash
just verify
```


## Validation and Acceptance

Acceptance is behavioral. The plan is done when all of the following are observable:

1. Running the scaffold-plus-consumer-runner transcript in Concrete Steps against the conformance fixture
   produces the report shown: canonical JSON and decode tallies; each difference named
   with its divergent JSON Pointer; every applicable observation classified as JSON parity or
   requires-version-work; historical and typed-case coverage listed separately; the mandatory
   authority framing printed; exit code `1` because differences exist. Deleting the two
   quirky behaviors from the historical codec and re-running yields `0` with the framing
   still printed.
2. `cabal test keiro-dsl-test` and `cabal test keiro-dsl-conformance-codec-compare` pass,
   and the latter fails if you weaken classification (e.g. temporarily make
   omitted-key-versus-null compare equal) — run that mutation once, observe the failure,
   revert. A golden that the supplied historical codec rejects yields
   `CodecCompareInvalidInput`, never `JsonParity` or `RequiresVersionWork`.
3. The coverage-report transcript works on the fixture spec; the JSON is stable and
   machine-readable; the default run never exits non-zero because of coverage; with
   `--fail-on-opaque` it exits non-zero with `CoverageOpaqueGateExceeded`; diff's
   `--fail-on-opaque-increase` reacts only to newly introduced opaque boundaries.
4. `keiro-dsl check`/`diff` behavior on existing specs without the new flags is
   byte-identical to before (pin with the existing test suites; `cabal test
   keiro-dsl-test` includes the diff fixtures).
5. The brownfield guide contains the shadow-comparison section at plan 145's anchor, the
   evolution guide names both capabilities, the new ADR exists with an OKF-allocated docId,
   `docs/adr/log.md` is current, ADR 0004's inventory has the new gate row, and
   `just adr-validate` and `just verify` pass.

Soundness gate — the ten-question Proposal Test from
`docs/research/14-structural-consumer-type-tradeoffs.md` ("A Proposal Test for Future Keiro
Improvements"), answered for this plan. Questions 1, 7, and 10 are the load-bearing ones
and are answered in depth; do not mark this plan complete until each answer is verified
against the landed code.

1. **Authority (in depth).** The `.keiro` spec owns the wire schema and the generated
   structural codec from plan 150 is the executed codec — before, during, and after this
   plan. The generated comparison runner adds no authority: it is a read-only comparator that executes both
   codecs side by side and returns a report, never a value used
   by production code. The comparison must never become a second authority, in any of the
   ways that could sneak in: the runner module is machine-owned and regenerated, documented as
   non-production, and exports nothing the scaffold's production modules import; the
   runner never selects which codec runs at runtime and has no "fallback to historical on
   mismatch" mode; a passing report changes no spec, no diagnostic, and no generated code —
   in particular it never flips an opaque declaration to structural or suppresses an opaque
   diagnostic (research note section 3). Scaffold refuses `--codec-comparison` selections that
   resolve to opaque declarations rather than "helpfully" comparing them, because
   accepting them is the first step of the silent-upgrade path. Verification: code review
   of the runner's import graph plus the conformance suite's assertion that an opaque
   name an opaque declaration, with a message naming this rule.
2. **Replay.** Unaffected. This plan generates no events, edges, or registers; replay
   semantics are exactly plan 150's. The coverage walk is a read-only traversal of the
   resolved graph.
3. **Visibility.** No new Keiki claims. Neither the comparator nor the coverage report adds
   guard or update syntax; nothing here is presented as solver-visible.
4. **Compatibility direction.** The compare report distinguishes encode differences (what
   the new codec would write) from decode differences over the historical corpus (whether
   the new binary reads old bytes), which is the private-history direction; the coverage
   report covers private events and names the snapshot consumer-JSON cache boundary; queues and
   contracts are explicitly unsupported/not-applicable rather than averaged into a false score.
5. **Ownership.** Private and public surfaces stay separately owned; the coverage report
   reports them as separate surface kinds and the comparator operates on one declared type
   at a time without bridging contracts.
6. **Completeness.** The coverage walk and compare branch inventory each construct plan 149's
   exported total algebra, so a new type-expression constructor that misses them is a compile
   error. The new DiagnosticCodes live in the shared
   append-only registry with pinned tests.
7. **Migration (in depth).** This plan is migration-evidence tooling. Existing JSON behavior is
   assessed only over a real corpus — historical goldens captured before the declaration was
   written (research note section 12: derive the declaration from the historical wire
   contract, not from Haskell spelling), with historical coverage and the independently
   required typed fixture-case coverage reported separately as first-class failures so a
   passing run cannot rest on an unexercised arm. Tags and defaults are compared through
   actual encode/decode execution of both codecs, not by inspecting declarations. When the
   corpus shows any difference, the only sanctioned path is Experiment B's: an explicit
   version bump and upcaster for each difference, with the legacy decoder retained solely
   as upcaster input at the version boundary. The runner's report and the brownfield
   guide both state this; "close enough" is unrepresentable in the verdict type. And the
   limits are honest: a corpus is evidence, not proof (IR-1's Out of Scope: proving an
   arbitrary instance matches a declaration is out of scope), which is exactly why passing
   comparison never upgrades any claim.
8. **Recovery.** Comparison execution and reporting are read-only over specs and fixtures; the
   report helper writes by atomic replacement, so interruption leaves either the previous complete
   report or no report. Re-running overwrites it. The generated runner is deterministic and safe to overwrite; the hand-owned
   caller that supplies `HistoricalCodec` is separate. Nothing here touches runtime
   deployment, so the old release path is untouched.
9. **Performance.** The comparator runs at development/CI time, not on any hot path; corpus
   size bounds its cost linearly. No production overhead is introduced, so no benchmark
   gate is required; if a consumer's corpus grows large, the report's per-fixture cost is
   the two codec executions they were going to need evidence for anyway.
10. **Negative proof (in depth).** The Experiment B conformance suite supplies the required
    negative/falsification evidence, not a universal proof, and it must be present before the
    plan is accepted: a fixture corpus where the
    historical codec genuinely differs (omitted-key-versus-null on one field; a wire tag
    that differs on one union arm) and the suite asserts the runner classifies both as
    `RequiresVersionWork`, names the divergent paths, exits non-zero, and never emits
    parity for them. A second negative asserts an uncovered declared arm yields
    `CodecCompareCoverageGap` and non-zero exit, so a green run cannot be produced by
    starving the corpus. A third asserts the opaque-selection refusal (question 1). A fourth
    gives the runner a golden rejected by the historical codec and asserts
    `CodecCompareInvalidInput`, preventing two decoder failures from being mistaken for parity. The
    mutation check in acceptance item 2 (weaken canonical comparison, watch the suite
    fail) demonstrates the suite actually guards the classification rather than the
    transcript text. If any of these can be made to pass while the machinery is
    incomplete, the guarantee is not landed.


## Idempotence and Recovery

Every step is safe to repeat. Scaffold deterministically overwrites only the machine-owned
comparison module, and the hand-owned runner reads fixtures and writes only its report file.
`check --coverage-report` overwrites its output file
deterministically. Test suites are hermetic. The ADR steps are the only ones with ordering
sensitivity: allocate the docId with `okf id next` immediately before writing the file, and
if validation fails after a partial edit, fix frontmatter and re-run `okf validate` — no
state is corrupted by retries. If a milestone stalls, earlier milestones remain
independently valuable and shippable (the engine without generated-runner integration is still a tested
library; the generated comparison runner without coverage reporting is still useful finite-evidence
tooling); record the stopping point in Progress.


## Interfaces and Dependencies

Dependencies: the `keiro-dsl` library's existing footprint (aeson `>=2.2.1` for
`Data.Aeson.RFC8785` — raise the lower bound in `keiro-dsl/keiro-dsl.cabal` from `>=2.2`
if needed; megaparsec, containers, text, filepath, directory as already declared) and
optparse-applicative in the executable. No dependency on the `keiro` package is added to
the `keiro-dsl` library or executable; the new conformance suite may depend on `keiro`
and `keiki` like the existing `keiro-dsl-conformance` suite does. From plan 150 (read its
landed Interfaces section for authoritative names): the total `StructuralBinding` API module
(`Keiro.Codec.Structural`), the generated structural codec entry points, and the
single-fixtures convention (`FixtureCases`); and from plan 149 (consumed via plan 150): the
resolved type-expression graph (`Keiro.Dsl.TypeGraph`) and its total folds/algebras.

At the end of Milestone 1, `Keiro.Dsl.CodecCompare` (new module,
`keiro-dsl/src/Keiro/Dsl/CodecCompare.hs`) exposes at minimum:

```haskell
data FixtureOrigin = HistoricalGolden | FromBinding
data DecodeOutcome = DecodedShape Value | DecodeFailed Text
newtype JsonPointer = JsonPointer Text
data ComparisonDifference
  = EncodedValueDifference JsonPointer Value Value
  | DecodedValueDifference JsonPointer Value Value
  | GeneratedDecodeRejected Text
data HistoricalCodec a = HistoricalCodec
  { hcIdentity :: Text
  , hcVersion :: Text
  , hcEncode :: a -> Value
  , hcDecode :: Value -> Either Text a
  }
data CompareObservation
  = EncodeObservation
      { coCaseName :: Text
      , coHistoricalValue :: Value
      , coGeneratedValue :: Value
      }
  | DecodeObservation
      { coFixturePath :: FilePath
      , coInputValue :: Value
      , coHistoricalDecode :: DecodeOutcome
      , coGeneratedDecode :: DecodeOutcome
      }
data FixtureVerdict = JsonParity | RequiresVersionWork ComparisonDifference
data CompareInputIssue
  = HistoricalGoldenUnreadable FilePath Text
  | HistoricalCodecRejected FilePath Text
  | HistoricalCodecProvenanceInvalid Text
data CoverageGap -- origin plus declared branch (union arm / presence / null) with no observation
data CompareProvenance = CompareProvenance
  { cpHistoricalCodecIdentity :: Text
  , cpHistoricalCodecVersion :: Text
  , cpCanonicalType :: CanonicalTypeId
  , cpBindingSymbol :: QualifiedValueName
  , cpBindingVersion :: BindingVersion
  , cpWireFingerprint :: Text
  }
data CompareReport -- provenance, verdicts, input issues, gaps, tallies,
                   -- authority framing; ToJSON with stable keys
data ReportWriteError = ReportWriteError FilePath Text
classifyObservation :: CompareObservation -> Either CompareInputIssue FixtureVerdict
compareReport :: CompareProvenance -> [CompareInputIssue] -> [CompareObservation] -> [DeclaredBranch] -> [ObservedBranch] -> CompareReport
renderCompareReport :: CompareReport -> Text  -- the human transcript
reportSucceeded :: CompareReport -> Bool
writeCompareReportAtomic :: FilePath -> CompareReport -> IO (Either ReportWriteError ())
```

`hcIdentity` and `hcVersion` are mandatory report provenance, not dispatch keys; the hand-owned
caller still supplies the functions directly. The runner rejects blank identity/version as
`HistoricalCodecProvenanceInvalid` before classifying observations. Up-front corpus read/parse
failures are passed to `compareReport` as input issues, so they cannot disappear merely because
no `CompareObservation` was constructed. (`DeclaredBranch`/`ObservedBranch` are the branch-inventory types computed from plan 149's
resolved graph; adopt the landed graph's naming. A generated runner turns each successful
decode into `DecodedShape` through `bindingToShape` and the generated shape encoder.) At the
end of Milestone 2, scaffold accepts opt-in
`--codec-comparison NAME --comparison-out FILE` and emits a generated
module exporting approximately
`compareWithHistorical :: HistoricalCodec Domain -> FilePath -> IO CompareReport`;
the new test-suite `keiro-dsl-conformance-codec-compare` exists in
`keiro-dsl/keiro-dsl.cabal`. At the end of Milestone 3, `Keiro.Dsl.Validate` carries the
six appended `DiagnosticCode` constructors (`CoverageOpaqueSurface`,
`CoverageOpaqueBoundaryAdded`, `CoverageOpaqueGateExceeded`, `CodecCompareDifference`,
`CodecCompareCoverageGap`, `CodecCompareInvalidInput`), and the coverage walk lives with the
graph traversal (either a new `Keiro.Dsl.Coverage` module or inside the module plan 149 gives
the resolved graph; record the choice in the Decision Log). The selected module must construct
a complete plan-149 algebra so a new resolved-type constructor breaks coverage compilation. At
the end of Milestone 4, the new ADR exists under
`docs/adr/` with its OKF-allocated docId, and ADR 0004 carries the amended inventory row.


---

Revision note: Aligned cross-plan references during MasterPlan 25 consistency review, 2026-07-28.

Revision note: Replaced global historical instances with an explicit `HistoricalCodec`, limited
comparison to `Value` semantics, qualified finite-corpus evidence, and narrowed coverage to
private event roots plus an explicit consumer-JSON snapshot boundary; unsupported queues and
contracts are no longer assigned fabricated ratios, 2026-07-28.

Revision note: Replaced the unexecutable standalone `codec compare` API with an opt-in
consumer-compiled runner, separated typed encode cases from historical decode goldens, and
normalized successful decodes through the declared structural shape, 2026-07-28.

Revision note: Classified historical-codec failures on alleged historical goldens as invalid
comparison input rather than parity, and made runner ownership, output collision refusal, and
codec/binding provenance explicit for reusable consumer migrations, 2026-07-28.

Revision note: Made comparison differences structured and JSON-pointer-addressed, passed report
provenance explicitly into the pure engine, and added atomic report writing so CI consumers do
not parse prose or observe interrupted partial output, 2026-07-28.
