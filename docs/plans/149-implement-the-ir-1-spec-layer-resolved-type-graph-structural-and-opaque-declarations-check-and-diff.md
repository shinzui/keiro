---
id: 149
slug: implement-the-ir-1-spec-layer-resolved-type-graph-structural-and-opaque-declarations-check-and-diff
title: "Implement the IR-1 spec layer: resolved type graph, structural and opaque declarations, check and diff"
kind: exec-plan
created_at: 2026-07-28T10:48:59Z
intention: "intention_01kym5dc4ve69sxsjtzd81pbbz"
master_plan: "docs/masterplans/25-structural-consumer-type-ergonomics-and-soundness-preserving-adoption-for-keiro-dsl.md"
---

# Implement the IR-1 spec layer: resolved type graph, structural and opaque declarations, check and diff

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today a `.keiro` specification can only describe aggregate fields built from `Text`, `Int`,
`Bool`, `Time`, declared id newtypes, and declared enums. A consumer with an existing Haskell
domain model — nested records, tagged unions, optional values, lists, maps, natural numbers,
timestamps, deliberately opaque JSON leaves — must either flatten everything into lossy `Text`
surrogates or keep those values entirely outside the checked spec. The improvement request
`docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md` (called
**IR-1** throughout this plan) asks for two explicit kinds of consumer-owned type binding:
**structural mapped types**, where the spec declares the exact wire shape and a Keiro-generated
codec will be the single wire-schema authority, and **opaque external-codec types**, where Keiro
stores and emits the value but honestly declines to make any nested compatibility claim.

This plan implements the **spec layer** of IR-1: everything that operates on `.keiro` text
alone. After this plan, a user can:

- write `mapped structural record`, `mapped structural enum`, `mapped structural union`, and
  `mapped opaque` declarations in a `.keiro` file, with nested type expressions (`Optional`,
  `List`, `Map`, `Natural`, existing `Time`/`UTCTime`, `Json`, and nominal references to other
  mapped declarations) and explicit per-field wire metadata (wire key, presence, nullability,
  mandatory on-missing policy for optional fields), record-level unknown-field policy, and
  per-union encoding metadata (strategy, tag/contents fields, stable per-arm tags);
- run `keiro-dsl parse` and get the declaration pretty-printed back, with the round trip
  `parseSpec . renderSpec == Right` holding for every new construct;
- run `keiro-dsl check` and have every rejection in IR-1's Validation and Scaffolding Contract
  enforced with stable machine-readable diagnostic codes (unresolved names, duplicate wire
  keys/tags, recursion, missing ingredients, ill-typed defaults, unsupported guard semantics,
  and the rest — the full list is carried into this plan below);
- run `keiro-dsl diff --since <ref>` and have nested structural changes classified recursively
  at every use site, with the complete path from the persisted root (event, snapshot register)
  to the changed nested declaration, comparing wire identities rather than Haskell names, and
  with replay-impact JSON naming affected event types and snapshot streams;
- run `keiro-dsl diff --since <ref> --emit-goldens <dir>` and get synthesized old-shape JSON
  fixtures that include the nested mapped shapes, never overwriting hand-captured files.

**Not** in this plan: no code generation, no `StructuralBinding` runtime API, no generated
codecs, no scaffold/manifest/harness changes. Those are the generation layer, plan
`docs/plans/150-implement-the-ir-1-generation-layer-bindings-api-generated-codecs-scaffold-and-conformance-harness.md`,
which hard-depends on the grammar constructors, resolved graph, and diagnostic codes this plan
lands. The seam is the module boundary the toolchain already uses:
`Keiro.Dsl.Grammar`/`Parser`/`PrettyPrint`/`Validate`/`Diff`/`ReplayImpact`/`Goldens` (this
plan) versus `Keiro.Dsl.Scaffold`/`Harness`/`Manifest` (plan 150).

The proof of success is observable without any generated Haskell: fixture `.keiro` files that
parse, round-trip, check, and diff exactly as IR-1's Evolution and Validation contracts demand,
plus mutation tests proving that an unvisited nested field or union arm makes the suite fail.


## Progress

- [x] 2026-07-28T18:56:47Z: Milestone 1 grammar constructors (`TypeExpr`, `MappedDecl`, wire metadata) added to `Keiro.Dsl.Grammar`; `Spec` carries `specMapped`.
- [x] 2026-07-28T18:56:47Z: Milestone 1 parser support for `mapped` declarations and type expressions added to `Keiro.Dsl.Parser`.
- [x] 2026-07-28T18:56:47Z: Milestone 1 pretty-printer support landed; 249 `keiro-dsl-test` examples and generated/fixture round trips pass.
- [x] 2026-07-28T18:56:47Z: Milestone 1 `test/fixtures/consumer-types.keiro` canonical fixture landed; QuickCheck `genSpec` now covers mapped declarations and bounded nested type expressions.
- [x] 2026-07-28T19:09:15Z: Milestone 2 `Keiro.Dsl.TypeGraph` module landed with checked declarations, resolved expressions, ambiguity/unresolved-name/recursion rejection, root reachability, exact use-site paths, and deterministic wire fingerprints.
- [x] 2026-07-28T19:09:15Z: Milestone 2 total traversal algebras and folds landed; package-wide `-Werror=missing-fields` plus module-local `-Werror=incomplete-patterns` make constructor/algebra omissions compile failures.
- [x] 2026-07-28T19:21:45Z: Milestone 3 appended all single-spec mapped `DiagnosticCode` constructors and wired raw declaration checks plus the resolved graph into `validateSpec`.
- [x] 2026-07-28T19:21:45Z: Milestone 3 validation contract landed with 24 one-fault negative fixtures, exact-code assertions, numeric default-bound coverage, and canonical `check` output `OK`; 257 examples pass.
- [x] 2026-07-28T19:21:45Z: Milestone 3 guard semantics landed: whole-value writes/copies remain legal, mapped and `Natural` guard operands reject, and the parallel `Time` guard fixture passes.
- [x] 2026-07-28T19:36:36Z: Milestone 4 `Keiro.Dsl.MappedDiff` recursive differ landed and is wired into shared-declaration diff, expanding complete command/event/register use paths.
- [x] 2026-07-28T19:36:36Z: Milestone 4 Evolution Contract landed with all mapped codes, context-sensitive compatibility vectors/remedies, 17 fixture variants, remaining-row AST tests, and an end-to-end merge-gate stage.
- [x] 2026-07-28T19:36:36Z: Milestone 4 replay impact now fingerprints transitively reachable mapped wire shapes for events and registers; nested changes name `ArtifactObserved` and require Catalog snapshot auditing while Haskell-only changes remain replay-neutral.
- [x] 2026-07-28T19:50:11Z: Milestone 5 `Keiro.Dsl.Goldens` synthesizes deterministic nested old-shape fixtures through the complete checked algebras, labels them weak stand-ins, and never overwrites captured evidence; CLI stage 11 passes.
- [x] 2026-07-28T19:50:11Z: Milestone 5 exhaustive wire-mutation coverage visits every record field, enum spelling, union arm, and opaque codec version at every complete root path; deleting the union-tag comparator made the focused test fail before restoration.
- [x] 2026-07-28T19:50:11Z: Milestone 5 ADR 0004 inventory amended; ADR 0012 reconciled with the landed spec layer; CHANGELOG updated; strict `just adr-validate` passes all 12 concepts.
- [x] 2026-07-28T19:50:11Z: Final outcomes and ADR distillation written; masterplan registry and progress updated; repository-wide `just verify` passes.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The proposed `TypeExprFamily` registry could be bypassed by a new ad hoc traversal and therefore
  did not satisfy its compile-failure claim. Exported algebra records/folds make constructor
  additions fail every subsystem construction site.
- `Timestamp` duplicated the existing DSL `Time`/`UTCTime` concept; optional fields lacked total
  missing-key construction; unknown-field behavior was unstated; and direct refs to existing
  ids/enums would cycle the generated leaf stratum. The revised grammar resolves all four.
- `WireField.wfLoc`, required by the planned public AST, shares its field label with the existing
  `WorkflowNode.wfLoc`. Enabling `DuplicateRecordFields` preserves both contracts, while the new
  `wireFieldLoc` and `workflowNodeLoc` accessors keep internal call sites unambiguous. Evidence:
  the full library and 249-example `keiro-dsl-test` suite compile and pass with both fields.
- GHC treats an omitted record field in an algebra construction as `-Wmissing-fields`, not an
  incomplete-pattern warning. Making that warning fatal package-wide is required for the stated
  compile-time traversal guarantee. Evidence: a temporary `onProbe` field added to
  `TypeExprAlgebra` made `cabal build keiro-dsl` fail at the reachability algebra construction;
  after restoring the algebra, all 254 examples pass.
- Graph construction intentionally stops at missing mandatory declaration facts, so lexical and
  identity checks that should still be visible on an incomplete declaration cannot depend on a
  resolved graph. `validateMapped` therefore runs raw fact checks first and reserves all recursive
  shape/default/nullability work for the resolved folds. The 24 fixture matrix demonstrates that
  each one-fault input retains its intended single diagnostic.
- Making `MappedDiff` import the ordinary `Change` type would create a `Diff` module cycle.
  Returning typed mapped findings (code, detail, declaration leaf, complete use paths, and the old
  unknown-field fact) keeps recursive comparison independent; `Diff` remains the sole owner of
  compatibility vectors and report labels. The 262-example suite and CLI merge-gate stage cover
  the composed seam.
- A passing fixture matrix alone did not demonstrate that every structural ingredient reaches the
  differ. The exhaustive mutation suite derives mutations from the checked graph and demands the
  exact complete root-path set for each one. Evidence: temporarily deleting the union-tag
  comparator made the focused test fail at `test/Main.hs:1254` with an empty finding list; after
  restoration it passes, as do all 265 examples.
- A synthesized mapped golden can be structurally complete without being historical evidence.
  The emitter now attaches `SynthesizedWeakStandIn`, prints that qualification at the CLI, and
  refuses to overwrite a file-owned capture; the nested v1-to-v2 integration case demonstrates
  all three properties.


## Decision Log

- Decision: Scope this plan to the spec layer only — grammar, parser, pretty-printer, resolved
  type graph, `check`, `diff`, replay impact, and golden synthesis. No scaffold, manifest,
  binding API, codec, or harness work.
  Rationale: The masterplan (`docs/masterplans/25-structural-consumer-type-ergonomics-and-soundness-preserving-adoption-for-keiro-dsl.md`,
  Decision Log) split IR-1 at the `Grammar`/`Validate`/`Diff` versus `Scaffold`/`Harness` seam
  so a spec that parses, checks, and diffs correctly is an independently verifiable milestone
  before any generated code exists. Plan 150 hard-depends on this plan's artifacts.
  Date: 2026-07-28

- Decision: IR-1's example syntax is treated as semantic, not a spelling commitment. This plan
  fixes the concrete surface syntax (specified in full in Plan of Work, Milestone 1) in the
  repository's existing declaration style: a `mapped` keyword family of top-level shared
  declarations using braced blocks with `key=value` facts (the `readmodel` block style) and
  `name as "wire" : Type presence` rows for fields and arms.
  Rationale: IR-1 says "the exact surface syntax belongs to Keiro". The existing grammar mixes
  line-oriented shared declarations (`id`, `enum`, `rule`) and braced nodes (`readmodel`);
  mapped declarations carry many keyed facts, so the braced style parses and pretty-prints
  most naturally and round-trips under the existing whitespace-insensitive parser conventions.
  Date: 2026-07-28

- Decision: Mapped declarations are top-level shared declarations (a new `specMapped` field on
  `Spec`), not a new `Node` constructor, and their diff runs in `sharedDeclarationDiff`
  expanded to per-root changes through the use-site index — not as a new `NodeFamily`.
  Rationale: Like `id` and `enum` declarations, mapped types are referenced by name from many
  nodes; they own no stream, no persisted surface of their own. Every persisted consequence is
  expressed at a containing root (event, snapshot register), which is exactly what IR-1's
  Evolution Contract requires the differ to report.
  Date: 2026-07-28

- Decision: A mapped change expands command roots as `ConsumerBuild` advisories, event roots as
  private-history findings, and register roots as separate snapshot-invalidation advisories.
  Declaration evidence/source facts remain declaration-level build findings unless their contract
  explicitly depends on a persisted root.
  Rationale: command payloads are in-memory consumer API surfaces rather than stored bytes, while
  `fields(Command)` events and mapped registers own distinct persisted obligations. Keeping three
  findings preserves every graph path without prescribing an event upcaster for cached register
  JSON or falsely treating a command shape as private history.
  Date: 2026-07-28

- Decision: Recursive structural mappings are rejected (`MappedRecursiveType`), including
  mutual recursion through any `TypeExpr` position. No bounded-recursion mode is added.
  Rationale: IR-1 lists recursion rejection in the Validation Contract; the research note
  `docs/research/14-structural-consumer-type-tradeoffs.md` section 11 classifies recursion
  support as a distinct research milestone that must not enter "through a generic external-type
  loophole". The masterplan's exclusion list confirms it.
  Date: 2026-07-28

- Decision: Equality/ordering guards over mapped-typed values, and over `Natural`-typed
  values, are rejected as errors (`MappedGuardUnsupported`); no opaque-guard escape spelling is
  added in this plan. Whole-value copy (`write reg := command.field`, `emit` of an event whose
  field carries the mapped value) remains the only mapped-value operation the spec may claim.
  Rationale: IR-1: guards outside Keiki's curated symbolic set "must be rejected or carry an
  explicit opaque-guard diagnostic and audit obligation", and "`Natural` is not currently in
  Keiki's curated symbolic set, whereas `UTCTime` is". Rejection is the sound default; an
  opaque-guard marker can be added later additively without changing any accepted spec. The
  curated-set table must be re-verified against keiki source (located via mori) at
  implementation time, not assumed from memory.
  Date: 2026-07-28

- Decision: Activate the stricter mapped guard-domain audit when a spec opts into mapped
  declarations. Existing unmapped specs retain their established enum/id guard behavior; a mapped
  spec is audited against the IR-1 curated scalar set (`Text`, `Int`, `Bool`, `Time`) across all
  typed register and command-field operands.
  Rationale: IR-1 introduces the new consumer-type soundness boundary and must not retroactively
  reinterpret older specs outside that boundary. Within the boundary, ids, enums, `Natural`, JSON
  containers, and all mapped values remain rejected while whole-value writes and event copies stay
  legal.
  Date: 2026-07-28

- Decision: Hard-depend on plan 148's context-sensitive compatibility API. Emit one stable
  `DiagnosticCode` per distinct mapped change class (field-add-without-default, arm-added,
  mode-crossing, source change, and so on — the full list is in Milestone 4), and add an explicit
  `CompatibilityVector` plus non-empty `remediationFor` row for every
  `ChangeContext`/code pair. The three-way `Additive | Advisory | Breaking` labels in this plan
  are derived headlines, not a parallel classifier.
  Rationale: Plan 148 has no all-compatible default; adding mapped codes without vector and
  remediation rows would fail totality and could silently omit a surface. A hard dependency keeps
  the six current surfaces (`private-history-read`, `old-binary-read-new-events`,
  `snapshot-hydration`, `public-consumer`, `persisted-identity`, `consumer-build`) explicit and makes plan 149's
  root-specific expansion reusable by other consumers. This plan leaves `ContractType` untouched:
  public contract nodes keep their own field grammar and mapped private types never appear in
  contracts. Plan 148 no longer adds a `CEnum -> Text` shortcut solely for a research fixture.
  Date: 2026-07-28

- Decision: The total-traversal guarantee is implemented with exported algebra records and
  folds (`TypeExprAlgebra`/`foldTypeExpr` and `MappedShapeAlgebra`/`foldMappedShape`), with all
  subsystems constructing a complete algebra. The defining modules also use
  `-Werror=incomplete-patterns` for the folds themselves, and the package uses
  `-Werror=missing-fields` for every algebra construction site.
  Rationale: A registry totality test proves only that registry keys are present; it cannot make
  an independently written traversal fail to compile. Adding an AST constructor changes the
  algebra and fold, forcing codec, validation, diff, golden, coverage, and projection consumers
  to update at compile time.
  Date: 2026-07-28

- Decision: Reuse the DSL's existing `Time` spelling for the type expression and pin it to Haskell
  `Data.Time.Clock.UTCTime` with the RFC 3339 / ISO-8601 UTC wire format aeson emits for
  `UTCTime` (e.g. `"2026-01-01T00:00:00Z"`); `Natural` is pinned to Haskell
  `Numeric.Natural.Natural` with a JSON-number representation, decode rejecting negative and
  non-integral numbers; `Map` supports text keys only (a JSON object).
  Rationale: IR-1 requires "natural numbers with a defined non-negative range and JSON-number
  representation" and "timestamps with a pinned Haskell type and wire format"; these pins match
  the sample conventions already used by `Keiro.Dsl.Goldens.sampleValue` for `Time`.
  Date: 2026-07-28

- Decision: The mapped-register initial value is declared once on the mapped declaration
  (`initial = "<qualified symbol>"`) and demanded only when the resolved graph shows the type
  used as a register; commands and event-only payloads need none.
  Rationale: Research note section 2 ("Scope initial values to actual registers"): the resolved
  graph computes the requirement from use sites rather than demanding meaningless defaults
  globally. IR-1: "Every mapped register requires an explicit initial value; Keiro must not
  invent `Default` instances or emit a latent `error`".
  Date: 2026-07-28

- Decision: Reconcile and amend proposed ADR 0012 rather than allocating a codec-authority ADR;
  amend ADR 0004's gate inventory through the strict okf workflow.
  Rationale: MasterPlan 25 now records the shared authority, total-binding, snapshot-boundary,
  and projection-provenance decisions before either implementation plan begins.
  Date: 2026-07-28

- Decision: Every structural record declares its consumer constructor, and every record and tagged-object envelope declares
  `unknown-fields = reject|ignore`; every `optional`
  field declares `on-missing`; generated encoders always emit every declared key (using JSON
  null for `Optional Nothing`), while presence policy governs decoding only. A mapped
  declaration has one mandatory non-empty `fixtures = Module.symbol` of type `FixtureCases a`.
  Rationale: Old/new compatibility depends on unknown-key behavior, a missing optional key needs
  a total construction rule, one fixture interface avoids divergent sample/generator APIs, and
  explicit constructor metadata lets per-type generated shapes support exact generic bindings
  without inspecting consumer source or guessing a `Mk` convention.
  Date: 2026-07-28

- Decision: Structural nullability must remain injective. Reject `Optional T` when `T` can itself
  encode as top-level JSON null: `Json`, another `Optional`, or an opaque mapped declaration whose
  external codec is unconstrained. Also reject a tagged-object union whose tag and contents keys
  are identical, and reject duplicate Haskell-side field names before generation.
  Rationale: `Nothing` and `Just Null` (or `Nothing` and `Just Nothing`) otherwise have the same
  wire representation, so generated decode cannot satisfy the shape round-trip law. Equal tag and
  contents keys collapse two required envelope facts into one JSON object member. These are
  structural encoding defects that `check` can reject for every consumer; fixture tests alone
  would only expose selected collisions.
  Date: 2026-07-28

- Decision: Separate the parser-facing declaration from the checked API. The raw `MappedDecl`
  stores mandatory facts as `Maybe`; `resolveTypeGraph` first produces `CheckedMappedDecl` with
  mandatory, validation-specific newtypes for canonical identities, qualified value symbols,
  structural binding versions, and
  opaque codec identity/version. Generation, diff, coverage, and projection consumers receive
  only checked declarations.
  Rationale: A non-optional raw field cannot represent the missing-ingredient diagnostics this
  plan promises without an empty-string sentinel. Conversely, exposing `Maybe` throughout every
  downstream consumer makes partial handling easy. Phase separation keeps parse/pretty total and
  makes invalid incompleteness unrepresentable after `check`. `TypeGraph` owns typed graph errors;
  `Validate` maps them to stable diagnostic codes so the two modules do not import each other.
  Date: 2026-07-28

- Decision: Version 1 `TRef` resolves only other mapped declarations. Existing DSL IDs and enums
  are deferred until those existing leaves themselves move below aggregate `Domain` modules;
  plan 150's per-declaration `Structural.Shape.*` stratum cannot safely import types that remain
  generated above it without recreating a `Domain -> Bindings -> Structural.Shape -> Domain` cycle.
  Rationale: A nominal reference that cannot be generated without a module cycle is not a valid
  spec-layer promise. This restriction is general and can be relaxed additively after the leaf
  architecture exists.
  Date: 2026-07-28


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

EP-6 delivered the full IR-1 spec boundary without crossing into generated bindings or codecs.
Mapped structural records, enums, unions, and opaque declarations parse and pretty-print; a
checked resolved graph makes mandatory provenance, recursive reachability, complete use paths,
and wire fingerprints available to downstream work. `check` owns invalid facts visible within
one spec. `diff` recursively classifies every old/new change at its command, event, register, or
declaration boundary, and replay impact follows the same transitive graph.

The final evidence is 265 passing `keiro-dsl-test` examples, the 11-stage CLI diff gate, and a
deliberate mutation that proved the exhaustive traversal test goes red when a comparator arm is
removed. Nested old-shape goldens are deterministic and complete, but are labelled weak stand-ins
and never overwrite captured payloads. ADR 0004 now records the resulting gate ownership, while
ADR 0012 records total folds, root-path expansion, wire-only fingerprints, and evidence strength.

The intended seam remains intact: EP-7 receives checked declarations and total algebras but still
owns `StructuralBinding`, generated codecs and shape modules, projection facades, scaffold
integration, and conformance execution. No generated-code claim was added here.


## Context and Orientation

### The repository and the toolchain

This repository (`keiro`) is a Haskell cabal multi-package project. The package this plan
touches is `keiro-dsl` (directory `keiro-dsl/`, version `0.3.0.0` in
`keiro-dsl/keiro-dsl.cabal`): the toolchain over a typed `.keiro` specification of a keiro
service — a parser, checker, differ, scaffolder, and harness emitter. This plan touches only
the parse/check/diff half. The relevant modules, all under `keiro-dsl/src/Keiro/Dsl/`:

- `Grammar.hs` (~1046 lines) — the abstract syntax. A `.keiro` file parses to `Spec`, which
  carries a context name, optional module/layout clauses, shared declarations (`specIds ::
  [IdDecl]`, `specEnums :: [EnumDecl]`, `specRules :: [RuleDecl]`), and `specNodes :: [Node]`.
  `Node` is a closed sum of twelve node families (aggregate, process, router, contract, intake,
  emit, publisher, workqueue, pgmq-dispatch, read model, workflow, operation). Aggregate
  commands and events carry `Field { fieldName :: Name, fieldType :: Maybe Name }` — a field
  type today is a bare `Name` resolved nominally against `Text`/`Int`/`Bool`/`Time`, id
  declarations, and enum declarations. Registers are `RegDecl { regName, regType :: Name,
  regInitial :: RegInitial }`. Events carry schema versions and upcaster holes (`evVersion`,
  `evUpcastFrom` at ~line 345). The `Hole` type (`Hole | Filled Text`, ~line 372) marks values
  the author must supply. `Loc` wraps a source line whose `Eq` ignores the line number so the
  `parse . pretty == id` round trip holds without byte-identical layout.
- `Parser.hs` (~1560 lines) — megaparsec parser; `parseSpec :: FilePath -> Text -> Either
  ParseError Spec`. Top-level items are parsed into an item sum and partitioned into the `Spec`
  fields (see ~line 252). Identifier hygiene (ASCII alphabet) is parser-enforced; category
  rules (case, keywords) live in the validator.
- `PrettyPrint.hs` (~679 lines) — `renderSpec :: Spec -> Text` via `prettyprinter` with
  unbounded page width. The contract is `parseSpec (renderSpec s) == Right s` modulo `Loc`.
- `Validate.hs` (~1681 lines) — `validateSpec :: Spec -> [Diagnostic]`. `DiagnosticCode`
  (lines ~39–201) is the single shared, machine-checkable registry of rule codes for both
  `check` and `diff`, per ADR 0004. **Codes are append-only**: new constructors go at the end
  of the enum; no code is ever renamed or reused. `Diagnostic` carries line, severity
  (`Error`/`Warning`), code, and message; `renderDiagnostic` prints
  `<file>:<line>: error[<Code>]: <message>`.
- `Diff.hs` (~1376 lines) — `diffSpecs :: Spec -> Spec -> [Change]` with `Change = Additive
  ChangeKind | Advisory ChangeKind | Breaking ChangeKind` and `ChangeKind { ckNode, ckFacet,
  ckSubject, ckCode :: Maybe DiagnosticCode, ckDetail }`. The CLI prints `ADDITIVE:`/
  `WARNING:`/`BREAKING:` lines and exits non-zero only when a breaking change exists.
  `diffSpecs` runs `sharedDeclarationDiff` (enum + id declarations) then one differ per node
  family through `familyRegistry :: [(NodeFamily, FamilyDiff)]` (lines ~153–166): every `Node`
  constructor maps to a `NodeFamily` via the total, wildcard-free `familyOf` case, every family
  occurs exactly once in the registry, and a family is either `DiffFamily <differ>` or
  `OutOfDiffScope <non-empty rationale>`. A unit test (`keiro-dsl/test/Main.hs` ~line 1000)
  asserts `sort (map fst familyRegistry) == [minBound .. maxBound]` and that every
  out-of-scope rationale is non-empty. This is the closedness technique this plan replicates
  for type expressions.
- `ReplayImpact.hs` (~200 lines) — `replayImpact :: Spec -> Spec -> ReplayImpact`, the
  conservative stored-data audit input: `ReplayNeutral` or `ReplayAffected (Map Name
  AggregateImpact)` where `AggregateImpact` carries a set of affected event-type names and an
  `includeSnapshotStreams` flag. Its JSON shape (`{"verdict":"replay-neutral"}` /
  `{"verdict":"affected","aggregates":{...}}`) is a machine contract recorded in ADR 0004.
  `decodeSurfaceAffected` compares per-event decode surfaces (`evBody`, `evVersion`,
  `evUpcastFrom`) — today it cannot see inside a field type.
- `Goldens.hs` (~170 lines) — synthesizes old-shape JSON payload fixtures at diff time for
  events whose version increases, written to
  `<root>/<context>/<aggregate>/<event>.v<version>.json`, **never overwriting existing files**
  (a hand-captured production payload is always more authoritative). `sampleValue` currently
  produces flat samples: id prefix strings, first enum wire spelling, `Int` 1, `Bool` true,
  `Time` `"2026-01-01T00:00:00Z"`, otherwise `"sample"`.
- `app/Main.hs` (~209 lines) — the `keiro-dsl` CLI: `parse`, `check [--emit]`, `scaffold`,
  `diff --since <ref> [--emit-goldens DIR] [--replay-impact-out FILE]`, `new`.

Tests live in `keiro-dsl/test/`. `Main.hs` (`keiro-dsl-test` suite, hspec + QuickCheck,
~2937 lines) holds the `parse . pretty` property over a `genSpec` generator (line ~2905), a
per-vertical `describe` block per feature (round trips of fixture files, validator rejection
tests matching on `DiagnosticCode`, `diffSpecs` classification tests, replay-impact tests,
golden tests), and the `familyRegistry` coverage test. Fixture `.keiro` files live flat under
`keiro-dsl/test/fixtures/` — one positive spec per vertical (`reservation.keiro`,
`hospital-surge.keiro`, `contract.keiro`, …) and many single-fault negative variants
(`reservation-fieldadd.keiro`, `intake-dup-retry.keiro`, `duplicate-names.keiro`, …).
Evolution pairs are separate files diffed in-memory (`diffFixtures` helper, ~line 1843).
Shell integration tests (`keiro-dsl/test/diff-test.sh`, `mutation-test.sh`, and per-vertical
mutation scripts) run the built CLI against scratch git repositories; they are run manually
from the repo root, not by `cabal test`.

Build and test commands (working directory: the repository root, inside the nix dev shell —
`nix develop` or direnv if tools are not already on PATH):

```bash
cabal build keiro-dsl            # library + CLI
cabal test keiro-dsl-test        # the unit/property suite this plan extends
bash keiro-dsl/test/diff-test.sh # CLI-level diff gate integration test
just adr-validate                # strict OKF enforcement for docs/adr
just verify                      # full repository gate (includes haskell-build/test, adr-validate)
```

### The normative sources this plan implements

Read both in full before implementing; this plan restates their binding content but they
remain the authority on intent:

- **IR-1** — `docs/improvement-requests/support-structural-consumer-owned-types-in-keiro-dsl.md`.
  This plan implements its "The Request" (resolved type-expression graph, structural mapped
  types, opaque external-codec types, type expressions and wire semantics), "Evolution
  Contract", and "Validation and Scaffolding Contract" sections as they apply to `.keiro` text,
  and the spec-layer bullets of its "Acceptance" section. The Conformance Harness Contract and
  the scaffold/manifest/mapping-drift portions belong to plan 150.
- **The research note** — `docs/research/14-structural-consumer-type-tradeoffs.md`. Its
  guarantees G1–G6 are the invariants; sections 3 (opaque mode), 4 (whole-value semantics), 7
  (usage-aware evolution), 11 (recursion rejection), and 12 (migration/goldens) directly shape
  this plan; its ten-question "Proposal Test for Future Keiro Improvements" is answered in
  Validation and Acceptance below, as the masterplan mandates for every child plan.

Key IR-1 contract text carried into this plan (self-containment; see Milestones 3 and 4 for
the operational form):

*Design principles.* One wire-schema authority: a structurally checked mapping uses a
Keiro-owned generated codec; an arbitrary consumer codec is supported only through an
explicitly opaque mapping. Consumer ownership remains nominal. Bindings are typed and explicit.
Compatibility is usage-aware. Keiki structure remains visible: whole values may be copied
through command fields, event fields, and registers, but no opaque collection guards or
first-class nested collection mutation. Public contracts keep their boundary.

*Keiki constraints.* A command field may be copied wholesale to an event field or register; no
nested field lookup, map membership, element update, collection fold, or quantified guard is
added; a mapped value needed to recover a command must be present as an invertible field in the
first emitted private event of a multi-event edge. The validator must reject DSL constructs
that claim solver-visible nested collection semantics. Equality or ordering guards over mapped
types outside Keiki's curated symbolic set must be rejected (this plan's choice) — compilation
alone is not proof of determinism. `Natural` is not in Keiki's curated symbolic set; `UTCTime`
is.

*Opaque mode.* Changing the opaque codec identity or version, or crossing between opaque and
structural modes, is breaking. An explicit `Json` leaf inside a structural declaration is the
nested form of the same policy: Keiro checks where the opaque boundary exists but makes no
compatibility claim about the value below it. Opaque mode never silently upgrades to a
structural claim.

### Relevant ADRs

Scanned `docs/adr/` filenames and headings; read the relevant records:

- `docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md` (ADR-4) — the
  layered gate model: `check` rejects what one spec can prove, `diff` classifies what needs
  both specs, runtime boundaries independently defend assembly. Machine-readable
  `DiagnosticCode` values correlate `check` and `diff`; golden synthesis never overwrites; its
  gate-inventory table "is amended when a later child plan changes a gate's ownership". **This
  plan amends that inventory** with the new structural/opaque change classes (Milestone 5).
- `docs/adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md` (ADR-3) —
  snapshot compatibility background: the `canonical-type` identity a mapped declaration pins is
  the stable name a snapshot shape and diagnostics will use (generation-layer wiring is plan
  150; this plan only records and diffs the identity).
- `docs/adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md` (ADR-2)
  — context for why replay-affecting classifications matter; not modified here.

No keiro-local ADR covers consumer-owned type binding yet; this plan creates one (Milestone
5). Cross-repository context, cited by IR-1 and the masterplan with exact Mori handles: the
originating request `mori://shinzui/mori/plans/171-extend-keiro-dsl-for-structural-mori-domain-contracts`
and Mori's decision `mori://shinzui/mori/okf/adrs/concepts/ADR-6`.

### Compatibility baseline and dependency verification

Verified dependency state (2026-07-28): Hackage and upstream tag `v0.4.0.0` identify Keiki
0.4.0.0 as the released typed-projection API; `keiro-dsl` remains released at `0.3.0.0` and the
local checkout contains unreleased post-`0.3.0.0` DSL work. Before choosing any later bound or
declaring anything released, re-verify Hackage and upstream tags — use `mori` to
locate sources and docs but treat the package registry and upstream tags as authoritative for
versions (a mori corpus checkout may lag upstream or carry local patches). Note that
`keiro-dsl` does **not** depend on `keiki` (see `build-depends` in `keiro-dsl/keiro-dsl.cabal`:
aeson, base, containers, directory, filepath, megaparsec, parser-combinators, prettyprinter,
text) and this plan adds **no new dependency**. The one keiki-facing fact this plan encodes —
the curated symbolic set used by the guard-semantics rules (Milestone 3) was verified against
Keiki 0.4.0.0 source located via `mori registry show shinzui/keiki --full`; re-check it if the
bound advances.

### Terms used in this plan

- **Mapped declaration**: a top-level `.keiro` declaration binding a consumer-owned Haskell
  type into the spec, in one of two modes — *structural* (Keiro declares and will own the wire
  shape) or *opaque* (an external codec identity is pinned; no nested claims).
- **Type expression**: the sublanguage of nested types usable inside structural wire shapes
  and (by nominal reference) in command/event/register positions.
- **Resolved type graph**: the single post-name-resolution data structure over all mapped
  declarations plus the index of every aggregate use site that all subsystems traverse. Existing
  DSL ids and enums are not legal nested mapped references in version 1.
- **Use site / root**: a place a mapped type is reachable from a persisted or public surface.
  In this plan's scope the roots are aggregate command fields (decode surface for new
  commands), aggregate event fields (private history), and registers (snapshot state). A
  **root-to-leaf path** names the root and every intermediate declaration/field/arm down to
  the changed leaf, e.g.
  `Catalog event ArtifactObserved .artifact : ArtifactInfo .location : ArtifactLocation arm "local_file"`.
- **Wire identity**: the wire-visible facts of a leaf — wire key, presence, nullability,
  on-missing default, type expression, union encoding, arm tag, enum spelling — as opposed to
  Haskell-side facts (package/module/type/binding symbol), which are source-compatibility
  facts. Renaming a Haskell selector while pinning its wire key is not a wire change.


## Plan of Work

The work is five milestones, each independently verifiable, each ending with
`cabal test keiro-dsl-test` green and demonstrable CLI behavior. Sequence: surface syntax
first (nothing else can be tested without it), then the resolved graph (everything else
consumes it), then single-spec rejection, then cross-spec classification, then goldens,
mutation coverage, and ADR work.

### Milestone 1 — Grammar, parser, and pretty-printer round trips

Scope: the new abstract syntax and its concrete syntax, with the round-trip property extended.
At the end, `keiro-dsl parse` accepts and re-prints every new construct; no validation or diff
behavior changes yet (a spec using mapped types will still fail `check` name resolution until
Milestone 3 — that is acceptable mid-plan state, and the canonical fixture is exercised through
`parse` and the round-trip tests until then).

**The concrete surface syntax this plan commits to.** A `mapped` declaration is a top-level
shared declaration appearing after `rule` declarations and before nodes. Four forms:

```text
mapped structural record ArtifactInfo {
  haskell package=artifact-domain module=Example.Artifact.Domain type=ArtifactInfo
  binding = "Example.Artifact.KeiroBindings.artifactInfoBinding"
  binding-version = "1"
  canonical-type = "example.artifact.ArtifactInfo.v1"
  fixtures = "Example.Artifact.KeiroBindings.artifactInfoCases"
  initial = "Example.Artifact.KeiroBindings.emptyArtifactInfo"
  wire object constructor=ArtifactInfo unknown-fields=reject {
    key         as "key"         : Text                  required
    kind        as "kind"        : ArtifactKind          required
    description as "description" : Optional Text         optional on-missing=null
    location    as "location"    : ArtifactLocation      required
    tags        as "tags"        : List Text             optional on-missing=[]
    attributes  as "attributes"  : Map Text              optional on-missing={}
    revision    as "revision"    : Natural               required
    observedAt  as "observedAt"  : Time                  required
    extra       as "extra"       : Json                  required
  }
}

mapped structural enum ArtifactKind {
  haskell package=artifact-domain module=Example.Artifact.Domain type=ArtifactKind
  binding = "Example.Artifact.KeiroBindings.artifactKindBinding"
  binding-version = "1"
  canonical-type = "example.artifact.ArtifactKind.v1"
  fixtures = "Example.Artifact.KeiroBindings.artifactKindCases"
  wire string { Guide as "guide"  Reference as "reference" }
}

mapped structural union ArtifactLocation {
  haskell package=artifact-domain module=Example.Artifact.Domain type=ArtifactLocation
  binding = "Example.Artifact.KeiroBindings.artifactLocationBinding"
  binding-version = "1"
  canonical-type = "example.artifact.ArtifactLocation.v1"
  fixtures = "Example.Artifact.KeiroBindings.artifactLocationCases"
  wire tagged-object tag="tag" contents="contents" unknown-fields=reject {
    LocalFile as "local_file" : Text
    RepoPath  as "repo_path"  : Text
    Canonical as "canonical"  : Text
    Unknown   as "unknown"
  }
}

mapped opaque VendorGeometry {
  haskell package=vendor-geometry module=Vendor.Geometry type=Geometry
  codec = "vendor.geometry.json" version = "3"
  fixtures = "Vendor.Geometry.KeiroBindings.geometryCases"
}
```

Semantics, fixed here: the `haskell` line names the Cabal package, Haskell module, and Haskell
type generated code will import (plan 150 consumes them; this plan validates and diffs them).
`binding` is the qualified symbol of the typed construction/destruction binding (structural
only). `binding-version` is a mandatory application-owned provenance token that changes whenever
the implementation's domain↔shape semantics change, even if the symbol and type stay fixed; it is
diff-visible and participates in mapped-register snapshot invalidation. `canonical-type` is the stable application-owned type identity for diagnostics and
snapshot invalidation. `fixtures` is the qualified symbol of one non-empty `FixtureCases a`
binding; its first case is the deterministic sample and the complete set supplies branch
evidence. `initial` is
optional; it is the qualified symbol of the initial register value and is required by `check`
exactly when the resolved graph shows the type used as a register type. In a record row,
the `wire object constructor=<Name>` fact names the consumer record constructor and the data
constructor generated for the shape type; keeping the generated module type-specific permits
that exact name without cross-declaration collisions. It is Haskell/source identity, not wire
identity. In each row,
`name` is the Haskell-side field name, `"wire"` after `as` is the wire key, the type
expression follows `:`, then a mandatory presence token (`required` | `optional`), then a
mandatory `on-missing=<default>` decode policy when the field is `optional`. `Optional T` means
JSON null is a legal value (nullability), which is deliberately distinct from the presence
token (missing key); the four combinations are all expressible. Defaults are decode policy,
not documentation: `on-missing=null` (only for `Optional` types), `on-missing="text"`,
`on-missing=0`, `on-missing=true|false`, `on-missing=[]` (lists), `on-missing={}` (maps), or
`on-missing=<EnumCtor>` for enum-typed fields. In a union, `tagged-object` is the only
encoding strategy this plan supports (matching IR-1's example; others reject in Milestone 3),
`tag`/`contents` name the discriminator and payload keys, each arm is
`HaskellCtor as "wire_tag" [: TypeExpr]` with a stable wire tag and an optional single payload
type (absent = unit arm). The encoder always emits both tagged-object keys; a unit arm uses
`contents: null`, and the decoder requires that canonical representation. Enum arms are
`Ctor as "wire"` only. Each record and tagged-object
envelope declares `unknown-fields=reject|ignore`. Generated encoders emit every declared key, representing
`Optional Nothing` as JSON null; presence policy affects decoding only. The opaque form has no
`binding`, no `wire`, and a mandatory `codec` identity plus `version` (a version or
fingerprint string).

Type expressions: `Text | Int | Bool | Natural | Time | Json | Optional <T> |
List <T> | Map <T> | <Name>`, with parentheses for nesting (`List (Optional Text)`).
`Map <T>` always has text keys. A bare `<Name>` is a nominal reference resolved (in Milestone
2) against mapped declarations only in version 1. Existing DSL IDs and enums are deferred until
a shared generated-leaf stratum prevents module cycles. This is how nested mapped types enter,
and how aggregate
command/event fields and registers reference a mapped type today without any use-site grammar
change (`artifact : ArtifactInfo` in a command; `artifactInfo ArtifactInfo = initial` as a register, where the
bare initial token `initial` defers to the declaration's `initial` symbol).

Edits:

1. `keiro-dsl/src/Keiro/Dsl/Grammar.hs` — add, in a new "Consumer-owned mapped types (EP-149)"
   section: `TypeExpr` (constructors `TText`, `TInt`, `TBool`, `TNatural`, `TTime`,
   `TJson`, `TOptional !TypeExpr`, `TList !TypeExpr`, `TMap !TypeExpr`, `TRef !Name`),
   `Presence (PRequired | POptional)`, `UnknownFields (RejectUnknown | IgnoreUnknown)`,
   `OnMissing (OmNull | OmText !Text | OmInt !Integer |
   OmBool !Bool | OmEmptyList | OmEmptyMap | OmCtor !Name)`, `WireField { wfHaskell :: !Name,
   wfKey :: !Text, wfType :: !TypeExpr, wfPresence :: !Presence, wfOnMissing :: !(Maybe
   OnMissing), wfLoc :: !Loc }`, `UnionEncoding (TaggedObject { ueTagField :: !Text,
   ueContentsField :: !Text, ueUnknownFields :: !UnknownFields })`,
   `WireEnum { weCtor :: !Name, weTag :: !Text, weLoc :: !Loc }`,
   `WireArm { waCtor :: !Name, waTag :: !Text, waPayload ::
   !(Maybe TypeExpr), waLoc :: !Loc }`, `MappedShape (ShapeRecord !Name !UnknownFields ![WireField] |
   ShapeEnum ![WireEnum] | ShapeUnion !UnionEncoding ![WireArm])`, `HaskellSource { hsPackage ::
   !Text, hsModule :: !Text, hsType :: !Name }`, and `MappedDecl` with two constructors
   (`MappedStructural { msName :: !Name, msHaskell :: !(Maybe HaskellSource), msBinding :: !(Maybe Text),
   msBindingVersion :: !(Maybe Text),
   msCanonical :: !(Maybe Text), msFixtures :: !(Maybe Text), msInitial :: !(Maybe Text), msShape ::
   !MappedShape, msLoc :: !Loc }` and `MappedOpaque { moName :: !Name, moHaskell ::
   !(Maybe HaskellSource), moCodecId :: !(Maybe Text), moCodecVersion :: !(Maybe Text), moFixtures :: !(Maybe Text),
   moInitial :: !(Maybe Text), moLoc :: !Loc }`), all with `Eq`/`Show`/`Generic` stock
   deriving and export-list entries. The parser-facing `MappedDecl` is deliberately a raw AST:
   mandatory facts that `check` diagnoses are stored as `Maybe` (`msHaskell`, `msBinding`, `msBindingVersion`,
   `msCanonical`, `msFixtures`, and the opaque `moHaskell`/`moCodecId`/`moCodecVersion`/
   `moFixtures`). Do not use empty-text sentinels. Add `specMapped :: ![MappedDecl]` to `Spec` (this touches
   every `Spec` construction site: the parser partition, `genSpec` in tests, and any literal
   `Spec` in tests/skeletons — the compiler will enumerate them).
2. `keiro-dsl/src/Keiro/Dsl/Parser.hs` — add a `TIMapped MappedDecl` top-level item and its
   parser (`mapped` keyword, mode/kind keywords, braced facts, wire block, type-expression
   parser with parenthesized nesting), partitioned into `specMapped`. Reuse the existing
   lexeme/identifier/string-literal machinery so escaping and hygiene rules hold. Duplicate
   *keys within one declaration block* (two `binding =` lines) are parse errors; duplicate
   *wire keys/tags* are AST-representable and rejected by the validator (Milestone 3) so the
   round trip stays total.
3. `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` — `docMapped :: MappedDecl -> Doc ann` rendered
   between rules and nodes in `docSpec`; a `docTypeExpr` with minimal parenthesization
   (parenthesize exactly the argument positions whose re-parse would differ). Follow the
   existing `docSpec` blank-line grouping (`blankAfter`).
4. `keiro-dsl/test/Main.hs` — extend `genSpec` with a generator for mapped declarations and a
   sized `TypeExpr` generator (depth-bounded, generating only `TRef` names that exist in the
   generated spec so later milestones can reuse the generator for valid specs); the existing
   `parse . pretty` property then covers the new constructs. Add a `describe "mapped types
   (EP-149)"` block: fixture round trip of the new canonical fixture, unit round trips for
   each `OnMissing` form, each presence/nullability combination, unit arms, and nested
   parenthesized type expressions.
5. New fixture `keiro-dsl/test/fixtures/consumer-types.keiro` — a full positive spec: context,
   the four mapped declarations above (record, enum, union, opaque), and an aggregate whose
   command, event, and register use `ArtifactInfo` and `VendorGeometry` nominally, with an event
   carrying scalar decision fields beside the mapped payload (modeling the research note's
   section 4 guidance).

Acceptance: `cabal test keiro-dsl-test` green including the extended property;
`cabal run keiro-dsl -- parse keiro-dsl/test/fixtures/consumer-types.keiro` prints the spec
back and a second `parse` of that output succeeds (demonstrated in Concrete Steps).

### Milestone 2 — The resolved type graph and compile-forcing total folds

Scope: one new module, `keiro-dsl/src/Keiro/Dsl/TypeGraph.hs` (added to `exposed-modules` in
`keiro-dsl/keiro-dsl.cabal`), that every later consumer traverses. This is guarantee G6 made
mechanical, and the artifact plan 150's generation layer will consume.

The module provides:

- `newtype QualifiedValueName`, `newtype CanonicalTypeId`, `newtype BindingVersion`,
  `newtype CodecIdentity`, and `newtype CodecVersion`, each with a smart constructor used by validation; plus
  `CheckedMappedDecl` mirroring the structural/opaque constructors but with every mandatory raw
  fact present and wrapped. There is no checked constructor that represents a missing binding,
  fixture symbol, canonical identity, binding version, or opaque codec identity/version.
- `data MappedDeclError` and `data TypeGraphError`, owned by `Keiro.Dsl.TypeGraph` and independent
  of `Keiro.Dsl.Validate`; `checkMappedDecl :: MappedDecl -> Either (NonEmpty MappedDeclError)
  CheckedMappedDecl`. Graph resolution calls this for every raw declaration before building
  indexes. Later subsystems never consume raw `MappedDecl` values.
- `newtype MappedKey`, `ResolvedTypeExpr`, `ResolvedWireField`, `ResolvedWireArm`,
  `ResolvedMappedShape`, `StructuralDecl`, `OpaqueDecl`, and
  `ResolvedMappedDecl = ResolvedStructural StructuralDecl ResolvedMappedShape |
  ResolvedOpaque OpaqueDecl`. Its constructors are distinct from the parser AST:
  `ResolvedTypeExpr = RText | RInt | RBool | RNatural | RTime | RJson |
  ROptional ResolvedTypeExpr | RList ResolvedTypeExpr | RMap ResolvedTypeExpr |
  RRef MappedKey`, and `ResolvedMappedShape` has explicit `RRecord`, `REnum`, and `RUnion`
  constructors carrying resolved fields/arms. `TypeGraph` owns
  `Map MappedKey ResolvedMappedDecl`. There is no generic
  `ResolvedRef`: built-ins are distinct `ResolvedTypeExpr` constructors, while the only legal v1
  nominal reference is `RRef MappedKey`. Existing DSL ids/enums fail resolution until their
  generated leaves move below aggregate `Domain`.
- `resolveTypeGraph :: Spec -> Either (NonEmpty TypeGraphError) TypeGraph` — name resolution over all
  mapped declarations and all node use sites, cycle detection (recursion rejection, including
  mutual recursion through any `TypeExpr` position, reported as `MappedRecursiveType` with the
  cycle path in the message), and the use-site index. `TypeGraph` carries the resolution map,
  the per-declaration reachability closure, and `tgUseSites :: [UseSite]` where `UseSite`
  names the root surface (`RootCommandField !Name !Name !Name` aggregate/command/field,
  `RootEventField !Name !Name !Name` aggregate/event/field, `RootRegister !Name !Name`
  aggregate/register) and the referenced declaration.
- `data PathSeg = SegField !Name !Text | SegArm !Name !Text | SegElem | SegMapValue |
  SegOptional | SegDecl !Name` and `usePaths :: TypeGraph -> Name -> [UsePath]` — every
  complete root-to-leaf path by which a mapped declaration is reachable from a root, and
  `renderUsePath :: UsePath -> Text` producing the human-readable path used in diagnostics and
  diff subjects. One rendering function, used by `check`, `diff`, and replay impact, so paths
  are identical everywhere.
- The **total folds**, which are the sole traversal entry points exported to later subsystems:

```haskell
data TypeExprAlgebra a = TypeExprAlgebra
    { onText :: a, onInt :: a, onBool :: a, onNatural :: a, onTime :: a, onJson :: a
    , onOptional :: a -> a, onList :: a -> a, onMap :: a -> a
    , onRef :: MappedKey -> a
    }

foldTypeExpr :: TypeExprAlgebra a -> ResolvedTypeExpr -> a

data MappedShapeAlgebra a = MappedShapeAlgebra
  { onRecord :: Name -> UnknownFields -> [ResolvedWireField] -> a
    , onEnum :: [WireEnum] -> a
    , onUnion :: UnionEncoding -> [ResolvedWireArm] -> a
  }

foldMappedShape :: MappedShapeAlgebra a -> ResolvedMappedShape -> a

data MappedDeclAlgebra a = MappedDeclAlgebra
  { onStructuralDecl :: StructuralDecl -> ResolvedMappedShape -> a
  , onOpaqueDecl :: OpaqueDecl -> a
  }

foldMappedDecl :: MappedDeclAlgebra a -> ResolvedMappedDecl -> a
```

Closedness enforcement: all three fold definitions use one explicit arm per constructor and the
module carries `-Werror=incomplete-patterns`. `Validate`, `MappedDiff`, `Goldens`,
`ReplayImpact`, plan 150's codec/harness/projection generation, and plan 152's coverage each
define a complete algebra value. Adding an algebra field breaks every construction site at
compile time, which is the promised failure mode; a runtime registry test is not substituted
for this property. Direct AST matching outside the defining module is rejected in review.

Acceptance: unit tests for resolution (nested mapped and every builtin; ids/enums reject), for cycle
detection (direct, mutual, through `List`/`Optional`/`Map`/arm payload), for use-path
completeness on `consumer-types.keiro` (the expected path set is written out in the test), and
each subsystem's fold behavior. A deliberate temporary `TypeExpr` constructor addition must
produce compile errors in all named algebra construction sites. `cabal test keiro-dsl-test` green.

### Milestone 3 — `check` rejections and negative fixtures

Scope: wire the graph into `validateSpec` and implement IR-1's Validation and Scaffolding
Contract for the spec layer. IR-1's list, verbatim, with the parenthesized owner in this plan:

> `keiro-dsl check` must reject: unresolved or ambiguous type and binding names (graph
> resolution); duplicate record wire keys, duplicate union arm names, or duplicate union wire
> tags (shape rules); recursive structural mappings and unbounded structural recursion (graph
> cycle detection); unsupported wire encodings (non-text map keys are unrepresentable in the
> unary `Map T` grammar); missing
> package/module/type, binding, stable type identity, fixture, or required initial value
> (ingredient rules; initial value demanded only at register use sites); invalid Haskell
> package, module, type, and binding names (lexical rules below); conflicting imports,
> aliases, generated paths, or package declarations (conflict rules below); structural
> declarations whose defaults are ill-typed for the field (default typing); and mapped uses
> that request unsupported Keiki guard or update semantics (guard rules below).

The last clause of IR-1's contract also binds this plan's honesty: Haskell compilation is the
final check that consumer bindings have the promised types and instances; `check` must not
claim to inspect Haskell source. Every diagnostic message for symbol-shaped facts must say
what compilation will verify, not pretend `check` verified it.

Edits:

1. `keiro-dsl/src/Keiro/Dsl/Validate.hs` — append to `DiagnosticCode` (at the end of the
   enum; append-only) the single-spec codes: `MappedUnresolvedName`, `MappedAmbiguousName`
   (a name declared as more than one of mapped/id/enum, or two mapped declarations sharing a
   name), `MappedDuplicateFieldName`, `MappedDuplicateWireKey`, `MappedDuplicateArmName`,
   `MappedDuplicateWireTag`, `MappedNonInjectiveNullability`,
   `MappedRecursiveType`, `MappedUnsupportedEncoding`,
   `MappedMissingIngredient` (with the missing ingredient — complete `haskell` source line, binding,
   binding-version, canonical-type, fixture, or opaque codec identity/version — named in the message),
   `MappedMissingInitialValue`,
   `MappedInvalidHaskellName`, `MappedInvalidIdentity`, `MappedImportConflict`, `MappedDefaultIllTyped`,
   `MappedGuardUnsupported`. Add a `validateMapped :: Spec -> [Diagnostic]` pass invoked from
   `validateSpec` that first runs `resolveTypeGraph`, maps every `TypeGraphError` to its stable
   `DiagnosticCode`, and then runs the graph-dependent rules. `TypeGraph` must not import
   `Validate`; keeping its typed errors local avoids a module cycle.
2. Rule details fixed here so the implementer decides nothing silently:
   - *Lexical Haskell-name rules* (`MappedInvalidHaskellName`): package names match Cabal's
     grammar (alphanumeric/hyphen words, no leading/trailing hyphen, at least one letter per
     word); module names are dot-separated `Upper` identifiers; the Haskell type is an `Upper`
     identifier; a record constructor and every enum/union constructor are `Upper` identifiers;
     binding/fixture/initial symbols are a module path plus a `lower`-initial
     identifier. Reuse the identifier-hygiene helpers from the EP-105 rules
     (`IdentHaskellKeyword`, `IdentNotConstructorSafe`) where they fit.
   - *Identity rules* (`MappedInvalidIdentity`): canonical identities, structural binding
     versions, and opaque codec identity/version strings must be non-empty and contain no ASCII control characters; their
     contents otherwise remain application-owned rather than imposing a Mori-specific namespace
     convention.
   - *Conflict rules* (`MappedImportConflict`): two mapped declarations naming the same
     Haskell `module.type` with different spec names or different canonical identities; two
     declarations with the same `canonical-type` string; a mapped declaration whose spec name
     collides with a built-in type name (`Text`, `Int`, `Bool`, `Time`, `Natural`, `Json`,
     `Optional`, `List`, or `Map`), an id, or an enum
     (also `MappedAmbiguousName`). Generated-path collisions proper are plan 150's scaffold
     concern; the spec-layer conflict rules cover everything decidable from text.
   - *Default typing* (`MappedDefaultIllTyped`): `on-missing=null` only for `TOptional` types;
     `on-missing=[]` only for `TList`; `on-missing={}` only for `TMap`; text/int/bool
     literals only for the matching scalar; `OmCtor` only for a mapped structural enum naming a
     declared constructor; `on-missing` on a `required` field is ill-formed. Parse integer
     defaults as `Integer`, then reject values outside `Int` bounds for `TInt` and negative
     values for `TNatural` before code generation.
   - *Injective structural encoding*: `MappedNonInjectiveNullability` rejects `ROptional`
     whose immediate resolved argument is `RJson`, `ROptional _`, or `RRef` to an opaque mapped
     declaration. `MappedUnsupportedEncoding` rejects a tagged-object envelope whose tag and
     contents keys are equal. `MappedDuplicateFieldName` rejects two record rows with the same
     Haskell selector even when their wire keys differ. These checks recurse through the total
     type-expression/shape folds and report the complete declaration path and relevant source
     locations.
   - *Guard rules* (`MappedGuardUnsupported`, error severity): resolve every guard atom and
     comparison operand (the existing scope-check machinery in `Validate.hs` already resolves
     atoms against registers/command fields); when an operand's declared type resolves through
     the graph to a type expression classified as non-symbolic by the guard-support algebra — any mapped record,
     union, or opaque type, any `List`/`Map`/`Json`, and `TNatural` — reject the guard. The
     symbolic set to encode in that algebra (verified against Keiki 0.4.0.0 source via Mori;
     re-check if the bound advances): `Text`, `Int`,
     `Bool` and `Time` (`UTCTime` is curated). Mapped values as wholes, ids, and declared enums
     remain rejected; generated field projections belong to plan 150's Holes facade. Writes and
     emits of whole mapped values (`write reg := field`, event fields typed by mapped names)
     remain legal — that is the whole-value contract. Any *nested* access spelling does not
     exist in the grammar, so nested guards are unrepresentable rather than rejected — state
     this in the rule's doc comment.
   - *Register initial*: a register whose `regType` resolves to a mapped declaration must use
     the bare initial token `initial`, and the declaration must carry `initial = "…"`;
     otherwise `MappedMissingInitialValue` (or `RegisterInitialOutOfScope` if a literal is
     given — reuse the existing code for the out-of-scope spelling).
3. Negative fixtures, one fault each, following the existing naming convention (flat files in
   `keiro-dsl/test/fixtures/`): `mapped-unresolved.keiro`, `mapped-ambiguous.keiro`,
   `mapped-dup-fieldname.keiro`, `mapped-dup-wirekey.keiro`, `mapped-dup-armname.keiro`,
   `mapped-dup-tag.keiro`,
   `mapped-recursive.keiro` (direct), `mapped-recursive-mutual.keiro`,
   `mapped-bad-encoding.keiro`, `mapped-union-key-collision.keiro`,
   `mapped-optional-json.keiro`, `mapped-optional-optional.keiro`,
   `mapped-optional-opaque.keiro`, `mapped-missing-binding.keiro`,
   `mapped-missing-binding-version.keiro`,
   `mapped-missing-canonical.keiro`, `mapped-missing-fixture.keiro`,
   `mapped-missing-initial.keiro` (mapped register, no `initial`),
   `mapped-bad-haskell-name.keiro`, `mapped-empty-identity.keiro`, `mapped-import-conflict.keiro`,
   `mapped-illtyped-default.keiro`, `mapped-guard.keiro` (equality guard over a mapped
   value), `mapped-guard-natural.keiro` (ordering guard over a `Natural` field — demonstrates the
   curated-set asymmetry: the same spec with a `Time` comparison must pass). Each gets a
   test in the `describe "mapped types (EP-149)"` validator block asserting the exact
   `DiagnosticCode` (match on code, not prose, per ADR 0004).

Acceptance: `cabal run keiro-dsl -- check keiro-dsl/test/fixtures/consumer-types.keiro`
prints `OK`; each negative fixture makes `check` exit non-zero printing its code;
`cabal test keiro-dsl-test` green.

### Milestone 4 — Recursive diff, evolution fixtures, and replay impact

Scope: cross-spec classification implementing IR-1's Evolution Contract, in a new module
`keiro-dsl/src/Keiro/Dsl/MappedDiff.hs` (exposed in the cabal file; carries the same
`-Werror` incomplete-pattern pragma) called from `sharedDeclarationDiff` in `Diff.hs`, plus
the replay-impact extension. The differ pairs mapped declarations by spec name (reusing the
`pairDeclarations` style used by `enumDiff`/`idDiff`), computes leaf-level wire-identity
changes through a complete diff algebra, and then **expands every change to
every containing root** using both specs' `TypeGraph` use-site indexes, emitting one `Change`
per (root, path) with `ckNode` = the aggregate, `ckFacet` = the root surface kind, `ckSubject`
= the rendered root-to-leaf path, and `ckCode` = the class code. Wire identities are compared,
never Haskell spellings: a changed `wfHaskell` or `waCtor` with an unchanged wire key/tag is
**not** a wire change.

IR-1's Evolution Contract, restated as the classification matrix to implement (each row: a new
appended `DiagnosticCode`, its classification, and the obligation text the change's
`ckDetail` must carry):

For every row below, classification text about decoding/history applies to private event roots.
If the changed declaration is reachable from a mapped register, emit an additional
snapshot-hydration Advisory whose sole remedy is invalidate/rebuild via the discriminator and
generated fingerprint; never prescribe an event upcaster for cached register JSON.

- `MappedFieldAddedWithDefault` — Additive for the new-binary/private-history direction when an
  explicit `on-missing` default preserves old meaning. The old-binary/new-payload direction is
  compatible only when the old record's `unknown-fields=ignore`; otherwise it is breaking.
  Detail names both facts.
- `MappedFieldAddedNoDefault` — Breaking: adding a field without an on-missing default means
  old stored payloads no longer decode under the declared shape; the containing event requires
  a versioned migration. A snapshot root is invalidate/rebuild Advisory, not an event upcaster.
- `MappedFieldRemoved` — Breaking at every private-event root (replay-relevant field removal
  is replay-affecting even when a tolerant JSON decoder would ignore the historical key — the
  detail must say this). A mapped-register use emits a separate snapshot invalidate/rebuild
  Advisory.
- `MappedFieldTypeChanged`, `MappedPresenceChanged`, `MappedNullabilityChanged`,
  `MappedDefaultRemoved`, `MappedDefaultChanged`, `MappedWireKeyChanged`,
  `MappedUnionEncodingChanged` — Breaking (removing an
  on-missing default, changing a field's wire type, presence, or nullability, changing union
  encoding, renaming a wire identity: all breaking unless an outer migration handles it; the
  detail names the remedy — version bump + upcaster at each affected private-event root).
- `MappedArmAdded` — **not universally additive**: Advisory (WARNING) at private-history
  roots with a rollout advisory in the detail ("backward-readable for existing history, but
  an older binary cannot read the new arm once emitted; deploy readers before writers").
  Public integration contracts do not carry mapped types in this plan's roots (the private/
  public boundary from IR-1's Usage Boundaries; contract nodes keep their own field grammar),
  so the closed-public-consumer Breaking case is recorded in the detail text as the rule that
  applies if a future surface exposes the union publicly — and the research note's Experiment
  D is only origin context. A consumer-neutral fixture uses the union at an event root and a
  snapshot register root, asserting event rollout risk separately from cache invalidation.
- `MappedArmRemoved`, `MappedArmTagChanged` — Breaking at every root still decoding history.
- `MappedEnumValueAdded` — the same directional rollout Advisory as `MappedArmAdded`: existing
  history remains readable, but older binaries cannot decode the new spelling after it is emitted.
- `MappedEnumValueRemoved`, `MappedEnumSpellingChanged` — Breaking at every root still decoding
  history. (`MappedEnumSpellingChanged` is not folded into add+remove, so remediation can name the
  exact constructor and old/new wire spellings.)
- `MappedHaskellSourceChanged` / `MappedRecordConstructorChanged` — source/build Advisories when
  package, module, type, or declared record constructor changes without a wire-identity change;
  remediation is `RemedyRecompileConsumers`.
- `MappedBindingChanged` — Advisory with `RemedyRunConformance` when the binding symbol or
  mandatory `binding-version` changes. The declared wire shape is unchanged, but binding behavior
  is opaque to `diff`; never describe this as proven wire parity. The generated
  two-law/codec/golden harness remains a mandatory release gate. Changing binding semantics
  without bumping `binding-version` violates the declaration contract.
- `MappedFixturesChanged` — tooling-evidence Advisory; it changes neither wire policy nor runtime
  dispatch, but the full conformance suite must run because evidence coverage changed.
- `MappedInitialChanged` — aggregate-behavior Advisory with `RemedyRunConformance`; it changes new
  stream initialization and snapshot fingerprints, not historical event decoding.

Vector rule for these non-wire codes: Haskell source/constructor changes put `VAdvisory` only on
`ConsumerBuild`; declared event bytes and runtime directions remain compatible or not applicable.
A binding change additionally puts `VAdvisory` on each reachable private-history and
old-binary/new-event direction because the domain interpretation or emitted shape may have
changed invisibly, and on reachable snapshot hydration because the fingerprint must invalidate
the cache. It does not fabricate persisted-identity impact: mapped declarations cannot occupy
stream/dedupe identity positions in version 1. Fixture-only changes put `VAdvisory` on
`ConsumerBuild` and `VCompatible`/`VNotApplicable` on runtime surfaces. Initial changes put
`VAdvisory` on `ConsumerBuild` and reachable snapshot hydration, with private-history reads
compatible. No source/evidence code receives a public-consumer verdict because mapped
declarations are private in v1.
- `MappedCanonicalTypeChanged` — `VAdvisory` on `ConsumerBuild` and reachable snapshot hydration:
  it changes generated nominal/projection provenance and forces discriminator/fingerprint
  invalidation, but declared event bytes and persisted identities are unchanged. Wire changes are
  classified by their own rows.
- `MappedOpaqueCodecChanged` — Breaking: opaque codec identity or version changed; Keiro
  cannot inspect the internal claim.
- `MappedModeCrossed` — Breaking in both directions (structural→opaque and opaque→structural).
- `MappedDeclAdded` — Additive by itself; use-site changes (new field/event/register) retain their
  own existing codes and vectors rather than inheriting a blanket declaration verdict.
- `MappedDeclRemoved` — Breaking at every root that still references it in the old spec
  (paired with the unresolved-name error in single-spec check of the new spec if uses
  remain); source-only Advisory when the old type graph proves there was no persisted root.

A nested breaking change propagates to every containing private event root. Every containing
mapped register also gets a separate snapshot invalidate/rebuild Advisory because the current
cache codec is consumer JSON, not the generated event codec. Each emitted `Change` is per-root
so event migration and cache invalidation obligations cannot be confused. The `diff` exit-code invariant is
preserved: non-zero only when a Breaking change exists.

Replay impact: extend `matchedAggregateImpact`/`decodeSurfaceAffected` in
`keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs` so an event's decode surface includes a wire
fingerprint of every mapped declaration reachable from its fields (computed by a `TypeGraph`
function — the fingerprint covers exactly the wire-identity facts, not Haskell facts), and a
register's mapped reachability feeds `includeSnapshotStreams`. Result: a nested
replay-affecting change makes the replay-impact JSON name the affected aggregate event types
and snapshot streams — not merely the mapped declaration — preserving the existing JSON
machine contract shape from ADR 0004.

Evolution fixture pairs (new files, diffed in-memory via the existing `diffFixtures` helper):
`consumer-types.keiro` as the base plus `consumer-types-fieldadd-default.keiro`,
`consumer-types-fieldadd-nodefault.keiro`, `consumer-types-fieldremove.keiro`,
`consumer-types-wirekey.keiro`, `consumer-types-haskell-rename.keiro` (Haskell rename, wire
pinned — must produce *no* wire change, only `MappedHaskellSourceChanged`),
`consumer-types-binding-change.keiro`, `consumer-types-fixtures-change.keiro`,
`consumer-types-initial-change.keiro`,
`consumer-types-armadd.keiro`, `consumer-types-tagchange.keiro`,
`consumer-types-enumadd.keiro`, `consumer-types-enumremove.keiro`,
`consumer-types-enumspelling.keiro`,
`consumer-types-encoding.keiro`, `consumer-types-opaque-version.keiro`,
`consumer-types-mode-cross.keiro`, `consumer-types-nested-propagation.keiro` (a leaf change
in `ArtifactLocation` reached through `ArtifactInfo` from two roots — asserts two complete paths).
Tests assert codes, classifications, and rendered paths, and a replay-impact test asserts the
JSON names the affected event types and snapshot flag.

Acceptance: `cabal test keiro-dsl-test` green; a CLI transcript (Concrete Steps) shows a
nested change reported with a complete path and non-zero exit; extend
`keiro-dsl/test/diff-test.sh` with a mapped-type stage (baseline commit of
`consumer-types.keiro`, then the no-default field add must be BREAKING and the Haskell rename
must exit 0).

### Milestone 5 — Goldens, mutation coverage, and ADR work

Scope: golden synthesis for nested shapes, the negative-proof suite IR-1's acceptance
demands, and the durable-memory obligations.

Goldens: extend `keiro-dsl/src/Keiro/Dsl/Goldens.hs` so `renderGolden`/`sampleValue`
synthesize nested old-shape JSON through the **old** spec's `TypeGraph` and a complete golden
algebra (moving JSON construction to `aeson` `Value` with stable key order
rather than growing the manual text builder). Sample policy, fixed here for determinism:
required fields present; `optional` fields with an `on-missing` default *omitted* (so the
fixture exercises the old decode policy); `Optional` values non-null; unions use the first
declared arm; lists carry one element; maps carry one `"sample"` key; `Natural` is `1`;
`Time` is `"2026-01-01T00:00:00Z"`; `Json` is `{}`; nested mapped values recurse through this
same structural synthesis. This spec-only command cannot import or execute the consumer's
`FixtureCases` symbol. Every synthesized file is therefore labeled in output/metadata as a weak
stand-in for capture while both specs exist; plan 150's compiled fixtures/goldens are the
authoritative conformance evidence. Trigger stays the same as today (an event whose version increases while both
specs are available) — now including events whose fields reach mapped declarations, so the
synthesized fixture contains the complete nested old shape. The never-overwrite rule is
already structural in `emitGoldenPayloads` (`writeIfMissing`); add a test proving a
pre-existing hand-captured file survives an emit and is not listed as written.

Mutation tests (IR-1 acceptance: "an unvisited nested field or union arm must make the diff,
codec, or harness suite fail" — the diff/check half is this plan's): add to
`keiro-dsl/test/Main.hs` an exhaustive **wire-mutation enumeration**: a function (test-local
or in `TypeGraph`) that, for a given spec, produces one mutant spec per mutable leaf — every
record field's wire key, every union arm's tag, every enum spelling, every default, every
presence flag, every opaque version — paired with its expected root-to-leaf paths. The suite
asserts, for `consumer-types.keiro`, that (a) every mutant produces at least one non-Additive
`Change`, (b) the change's rendered subject contains the mutated leaf's path, and (c) the set
of visited paths equals the enumeration's path set. If any differ arm or traversal case were
missing, its mutants would yield no change (or a path would be absent) and the suite fails —
the negative proof holds by construction. Demonstrate it once: delete the union-arm
comparator arm in `MappedDiff.hs` locally, observe the named test go red, restore, and record
the transcript in Surprises & Discoveries. Mirror the same enumeration over `check` for the
ingredient rules (delete each required ingredient from a copy of the AST; assert the specific
code fires).

ADR work, per `.claude/skills/exec-plan/ADR.md`:

1. Amend `docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md`: add
   gate-inventory rows for the new change classes (mapped wire-identity change classes gated
   at `diff` with per-root propagation; mapped single-spec rejections gated at `check`;
   nested replay impact feeding the targeted audit; goldens extended to nested shapes),
   advance its `timestamp`, and record the amendment in `docs/adr/log.md` via `okf log add`.
2. Reconcile the landed design with proposed ADR 0012; do not allocate another handle. Inspect
   it and validate the bundle:

   ```bash
   okf show docs/adr ADR-12 --profile docs/adr/profile.dhall
   okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
   ```

   Amend ADR 0012 only for implementation-discovered durable facts. Plan 150 may move it to
   Accepted after the generated codec, total binding laws, projection facade, and snapshot
   invalidation are observed.
3. Run the strict validation both times:

   ```bash
   just adr-validate
   ```

Also update `CHANGELOG.md` (repository root) under an Unreleased keiro-dsl heading, and tick
this plan's row in the masterplan registry when complete.

Acceptance: golden emit test green with a transcript showing a nested fixture; the mutation
suite green (and demonstrably red under the deliberate arm deletion); `just adr-validate`
green; `just verify` green as the final whole-repo gate.


## Concrete Steps

All commands run from the repository root (the directory containing `cabal.project`), inside
the dev shell (`nix develop` if needed). After each milestone, run the suite and commit with a
conventional message (`feat(dsl): …`, `test(dsl): …`, `docs(adr): …`) on the current branch.

```bash
# Baseline: confirm the world is green before touching anything.
cabal build keiro-dsl && cabal test keiro-dsl-test

# Milestone 1 loop:
cabal test keiro-dsl-test
cabal run keiro-dsl -- parse keiro-dsl/test/fixtures/consumer-types.keiro
# Round trip at the CLI: parse output must re-parse identically.
cabal run keiro-dsl -- parse keiro-dsl/test/fixtures/consumer-types.keiro \
  | cabal run -v0 keiro-dsl -- parse /dev/stdin
```

Expected (abridged) Milestone 1 transcript:

```text
$ cabal run keiro-dsl -- parse keiro-dsl/test/fixtures/consumer-types.keiro
context consumer-demo
...
mapped structural record ArtifactInfo {
  haskell package=artifact-domain module=Example.Artifact.Domain type=ArtifactInfo
  ...
}
```

```bash
# Milestone 3: check accepts the positive fixture, rejects each negative one.
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/consumer-types.keiro
# -> OK (exit 0)
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/mapped-guard.keiro
# -> keiro-dsl/test/fixtures/mapped-guard.keiro:NN: error[MappedGuardUnsupported]: ... (exit 1)

# Milestone 4: CLI-level nested diff against real git history.
DEMO=$(mktemp -d) && git -C "$DEMO" init -q
cp keiro-dsl/test/fixtures/consumer-types.keiro "$DEMO/svc.keiro"
git -C "$DEMO" add svc.keiro
git -C "$DEMO" -c user.email=t@t -c user.name=t commit -qm baseline
cp keiro-dsl/test/fixtures/consumer-types-fieldadd-nodefault.keiro "$DEMO/svc.keiro"
cabal run keiro-dsl -- diff --since HEAD "$DEMO/svc.keiro" \
  --replay-impact-out "$DEMO/impact.json"; echo "exit=$?"
cat "$DEMO/impact.json"
```

Expected (abridged) Milestone 4 transcript:

```text
BREAKING: Catalog event ArtifactObserved .artifact : ArtifactInfo field "contentHash": field added without
  an on-missing default; old stored payloads no longer decode under the declared shape —
  bump the containing event version and supply an upcaster [MappedFieldAddedNoDefault]
replay-affected: run the candidate binary's targeted replay audit for Catalog
  events=[ArtifactObserved] snapshots=yes
exit=1
$ cat "$DEMO/impact.json"
{"verdict":"affected","aggregates":{"Catalog":{"eventTypes":["ArtifactObserved"],"includeSnapshotStreams":true}}}
```

```bash
# Milestone 5: goldens and the shell gates.
cp keiro-dsl/test/fixtures/consumer-types-v2.keiro "$DEMO/svc.keiro"   # version-bumped variant
cabal run keiro-dsl -- diff --since HEAD "$DEMO/svc.keiro" --emit-goldens "$DEMO/goldens" || true
find "$DEMO/goldens" -name '*.json'   # nested old-shape fixture present
bash keiro-dsl/test/diff-test.sh
just adr-validate
just verify
```

Exact fixture names, line numbers, and transcripts must be updated in this section as work
proceeds; treat divergences as documentation bugs to fix here.


## Validation and Acceptance

### Behavior-level acceptance (IR-1's spec-layer acceptance bullets, restated as observables)

1. **Round trips**: for every construct — structural record/enum/union, opaque declaration,
   every type expression (`Optional`, `List`, `Map`, `Natural`, `Time`, `Json`, nominal
   refs), explicit wire metadata, every `on-missing` form, JSON leaves — the QuickCheck
   property and the fixture tests assert `parseSpec "<gen>" (renderSpec s) == Right s` over
   the generated cases.
   Command: `cabal test keiro-dsl-test` (round-trip describe blocks).
2. **Negative fixtures**: each named `mapped-*.keiro` fixture makes
   `keiro-dsl check` exit non-zero with its exact expected `DiagnosticCode` — covering
   unresolved, ambiguous, recursive, duplicate (Haskell field/wire key/arm/tag), unsupported
   (encoding and tag/content key collision), non-injective optional/null encodings,
   binding-incomplete (missing binding/binding-version/canonical/fixture/initial), invalid identity, guard-opaque
   (mapped-value and `Natural` guards), and import/package-collision faults.
3. **Evolution fixtures**: the fixture pairs distinguish wire changes, Haskell source changes,
   binding/fixture/initial changes whose behavior is opaque to `diff`, replay-affecting changes, rollout advisories
   (union or enum value add), and
   breaking changes with stable codes and complete root-to-leaf usage paths; a Haskell rename
   with a pinned wire key produces no wire change; nested breaks propagate to every containing
   root with per-root obligations; the replay-impact JSON names affected event types and
   snapshot streams.
4. **Mutation tests**: the exhaustive wire-mutation suite fails if any nested field, union
   arm, enum spelling, default, presence flag, or opaque version is unvisited by the differ;
   the ingredient-deletion suite fails if any `check` rule is unvisited. Demonstrated red
   once by deliberate arm deletion.
5. **Opaque honesty**: a fixture pair changing only the *interior* of an opaque type's
   consumer codec (represented as no spec change) produces zero diff output, while changing
   its declared identity/version is Breaking — proving Keiro makes no nested claims across
   the opaque boundary, and never silently upgrades opaque to structural
   (`MappedModeCrossed` is Breaking both ways).
6. **Goldens**: `diff --emit-goldens` writes nested old-shape fixtures for version-bumped
   events containing mapped values and never overwrites an existing file.

Suite commands and expected results: `cabal test keiro-dsl-test` exits 0 with all new
describe blocks listed; `bash keiro-dsl/test/diff-test.sh` prints its staged `ok:` lines and
exits 0; `just adr-validate` exits 0; `just verify` exits 0.

### The soundness gate: the research note's ten-question Proposal Test

Answered for this plan, as the masterplan requires of every child plan
(`docs/research/14-structural-consumer-type-tradeoffs.md`, "A Proposal Test for Future Keiro
Improvements"):

1. **Authority** — The `.keiro` declaration owns the wire schema. This plan generates no
   codec, and therefore *claims* none: `check`/`diff` classify only the declared shape, and
   the new ADR records that the executed codec (plan 150) must be generated from this
   declaration, with consumer instances allowed to delegate to it, never the reverse.
2. **Replay** — No new decide/evolve machinery is added; mapped values are whole values.
   The guard rules reject any spec whose decisions would depend on non-symbolic mapped
   internals, and replay-relevant nested field removal is classified replay-affecting with
   the affected event types and snapshot streams named in the replay-impact JSON.
3. **Visibility** — Every guard the spec accepts over mapped-adjacent data is over the
   curated symbolic set (verified against keiki source, with `Natural` excluded and
   `UTCTime` included per IR-1); nested access is unrepresentable in the grammar; no Haskell
   predicate hides behind checked syntax.
4. **Compatibility direction** — The classification matrix distinguishes old-history reads
   (defaults gate additivity), rolling deploys (arm-add rollout advisory), snapshots
   (canonical-type and register roots), and source/evidence compatibility (source, binding,
   fixture, and initial changes reported separately); every code/context pair extends plan 148's
   per-surface vector and remediation registries explicitly.
5. **Ownership** — Mapped types are usable only at private roots (commands, events,
   registers); contract nodes keep their own field grammar, so a private domain type cannot
   become a public contract by reuse.
6. **Completeness** — The exported total folds/algebras with module-scoped
   `-Werror=incomplete-patterns`, plus the exhaustive wire-mutation suite, make an omitted
   parser/pretty/check/diff/golden case a compile error or a red test.
7. **Migration** — Wire identities, not Haskell names, are compared; defaults are decode
   policy; version bumps with upcasters at each affected root are the named remedy; goldens
   synthesize the old nested shape while both specs exist and never overwrite hand-captured
   bytes (research note section 12).
8. **Recovery** — This plan changes only the toolchain: no generated file, no runtime, no
   migration. Every step is re-runnable; a bad state is recovered by `git checkout` of the
   touched sources. `--emit-goldens` is idempotent by the never-overwrite rule.
9. **Performance** — Text-tool only; graph resolution is linear in spec size with a
   cycle-detection DFS. No runtime codec exists yet to benchmark; the exported fold/algebra
   hand-off explicitly leaves encoder fusion to plan 150 with the research
   note's "never optimize by restoring dual authority" constraint.
10. **Negative proof** — Milestone 5's mutation suites are the constructive proof: an
    unvisited nested field or union arm makes the diff or check suite fail, demonstrated red
    under deliberate code deletion before completion.


## Idempotence and Recovery

Every step is additive source editing plus test runs; all commands are safe to re-run.
`cabal test` and the shell scripts create scratch state only under `mktemp -d` (the scripts
clean up via `trap`). `diff --emit-goldens` never overwrites existing files, so re-running it
is safe by construction. The `DiagnosticCode` enum is append-only — if a code lands with a
wrong name before release, the fix is a new code plus deprecating the old one in prose, not a
rename. ADR edits are guarded by `just adr-validate`; this plan amends already allocated
ADR 0012 and consumes no new handle. If a milestone is interrupted, the Progress section's
done/remaining split plus the last
green commit are sufficient to resume; nothing in this plan mutates state outside the working
tree.

One deliberate mid-plan inconsistency to manage: between Milestones 1 and 3,
`consumer-types.keiro` parses but does not `check` (mapped names are unresolved until the
graph lands). Keep the fixture's check-acceptance test commented in with an hspec `pendingWith
"milestone 3"` marker rather than deleted, so the suite documents the gap and closing it is
visible.


## Interfaces and Dependencies

No new package dependencies. Existing dependencies used: `megaparsec`/`parser-combinators`
(parser), `prettyprinter` (rendering), `aeson` (golden synthesis, replay-impact JSON),
`containers`, `text`. Tooling: `cabal`, `just`, `okf` (ADR bundle), `git` (diff CLI), `mori`
(dependency source lookup for the keiki curated-set verification). Version-bound changes: none
expected in this spec-only plan. Plan 150 owns the already-verified coordinated Keiki migration:
Hackage and upstream tags both identify `0.4.0.0` as the released projection API.
Hard plan dependency: plan 148's landed `ChangeContext`, `CompatibilityVector`,
`classifyCompatibility`, `remediationFor`, and `RemedyRunConformance`/
`RemedyRecompileConsumers` surface; re-read its landed names before Milestone 4 and record any
coordinated rename in both plans.

Module-level interface contract at the end of each milestone (full paths; signatures are the
minimum that must exist — implementers may add, not subtract):

Milestone 1, `Keiro.Dsl.Grammar` (`keiro-dsl/src/Keiro/Dsl/Grammar.hs`): `TypeExpr`,
`Presence`, `UnknownFields`, `OnMissing`, `WireField`, `UnionEncoding`, `WireEnum`, `WireArm`, `MappedShape`,
`HaskellSource`, raw `MappedDecl` (all exported, `Eq`/`Show`/`Generic`); `Spec` gains
`specMapped :: ![MappedDecl]`. `Keiro.Dsl.Parser.parseSpec` and
`Keiro.Dsl.PrettyPrint.renderSpec` keep their signatures and cover the new syntax.

Milestone 2, `Keiro.Dsl.TypeGraph` (new file `keiro-dsl/src/Keiro/Dsl/TypeGraph.hs`):

```haskell
resolveTypeGraph :: Spec -> Either (NonEmpty TypeGraphError) TypeGraph
checkMappedDecl :: MappedDecl -> Either (NonEmpty MappedDeclError) CheckedMappedDecl
data ResolvedTypeExpr
data ResolvedMappedShape
data ResolvedMappedDecl
data UseSite   -- root surface + referenced declaration (constructors in Milestone 2 text)
usePaths :: TypeGraph -> Name -> [UsePath]
renderUsePath :: UsePath -> Text
data TypeExprAlgebra a
foldTypeExpr :: TypeExprAlgebra a -> ResolvedTypeExpr -> a
data MappedShapeAlgebra a
foldMappedShape :: MappedShapeAlgebra a -> ResolvedMappedShape -> a
data MappedDeclAlgebra a
foldMappedDecl :: MappedDeclAlgebra a -> ResolvedMappedDecl -> a
wireFingerprint :: TypeGraph -> Name -> Text   -- wire-identity-only fingerprint (Milestone 4 uses it)
```

Milestone 3, `Keiro.Dsl.Validate`: `DiagnosticCode` extended (append-only) with the
single-spec codes named in Milestone 3; `validateSpec` unchanged in signature, now covering
mapped rules through `resolveTypeGraph`.

Milestone 4, `Keiro.Dsl.MappedDiff` (new file `keiro-dsl/src/Keiro/Dsl/MappedDiff.hs`):
`mappedDiff :: DiffEnv -> [Change]`, invoked from `Keiro.Dsl.Diff.sharedDeclarationDiff`;
`DiagnosticCode` extended with the diff codes named in Milestone 4;
`Keiro.Dsl.ReplayImpact.replayImpact` unchanged in signature, decode surfaces now including
`wireFingerprint` of reachable mapped declarations.

Milestone 5, `Keiro.Dsl.Goldens`: `goldensForDiff`/`emitGoldenPayloads` unchanged in
signature, synthesis now fold/algebra-driven for nested shapes. Consumed-by contract: plan 150
builds its scaffold planning, manifests, codecs, projection facade, and harness on
`Keiro.Dsl.TypeGraph` (`resolveTypeGraph`, the exported folds/algebras, `usePaths`,
`wireFingerprint`) and `CheckedMappedDecl`; raw `MappedDecl` remains a parser/pretty-print AST.
Treat the checked graph's exported names as stable once this plan completes; breaking
them afterward requires coordinating with plan 150.


---

Revision note: Aligned cross-plan references during MasterPlan 25 consistency review, 2026-07-28.

Revision note: Revalidated the spec API for general consumers: reuse `Time`, require one
non-empty fixture set, explicit optional defaults and unknown-field policy, restrict v1
references to mapped declarations, replace registry totality with compile-forcing folds, treat
snapshots as invalidate/rebuild roots, and consume ADR 0012, 2026-07-28.

Revision note: Gave enum wire entries their own source-located `WireEnum` type so diagnostics and
future consumers do not lose provenance through an unstructured `(Name, Text)` tuple,
2026-07-28.

Revision note: Added raw-to-checked declaration phase separation with typed graph errors and
resolved folds, removed an unreachable non-text-map-key diagnostic, and made non-injective null
encodings, duplicate Haskell fields, and union envelope-key collisions static rejections,
2026-07-28.

Revision note: Made record-constructor metadata and application-owned `binding-version`
mandatory, so exact generic derivation and semantic binding changes remain explicit, reviewable,
and consumer-neutral, 2026-07-28.
