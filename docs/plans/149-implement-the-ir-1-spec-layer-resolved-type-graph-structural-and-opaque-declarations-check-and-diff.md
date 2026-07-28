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
  `List`, `Map`, `Natural`, `Timestamp`, `Json`, nominal references to other mapped types, ids,
  and enums) and explicit per-field wire metadata (wire key, presence, nullability, on-missing
  default) and per-union encoding metadata (strategy, tag/contents fields, stable per-arm tags);
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

- [ ] Milestone 1: grammar constructors (`TypeExpr`, `MappedDecl`, wire metadata) added to `Keiro.Dsl.Grammar`; `Spec` carries `specMapped`.
- [ ] Milestone 1: parser support for `mapped` declarations and type expressions in `Keiro.Dsl.Parser`.
- [ ] Milestone 1: pretty-printer support in `Keiro.Dsl.PrettyPrint`; property and fixture round trips green in `keiro-dsl-test`.
- [ ] Milestone 1: `test/fixtures/consumer-types.keiro` canonical fixture committed; QuickCheck `genSpec` extended with mapped declarations.
- [ ] Milestone 2: `Keiro.Dsl.TypeGraph` module with `resolveTypeGraph`, use-site index, root-to-leaf paths, and the total `typeExprRegistry`.
- [ ] Milestone 2: registry closedness enforced (family enum coverage test + `-Werror` incomplete-pattern pragmas on the new modules).
- [ ] Milestone 3: all new `DiagnosticCode` constructors appended; `validateSpec` wired to the resolved graph.
- [ ] Milestone 3: every IR-1 check rejection implemented with a negative fixture under `keiro-dsl/test/fixtures/` and a test asserting its code.
- [ ] Milestone 3: guard-semantics rules (whole-value copy only; `Natural` guard rejection; mapped equality/ordering guard rejection) landed with fixtures.
- [ ] Milestone 4: `Keiro.Dsl.MappedDiff` recursive differ with per-root use-site paths; wired into `diffSpecs` shared-declaration phase.
- [ ] Milestone 4: full Evolution Contract classification matrix implemented and covered by evolution fixture pairs.
- [ ] Milestone 4: `Keiro.Dsl.ReplayImpact` extended so nested mapped breaks name affected event types and snapshot streams in the JSON output.
- [ ] Milestone 5: `Keiro.Dsl.Goldens` synthesizes nested old-shape fixtures through the registry; `--emit-goldens` end-to-end test.
- [ ] Milestone 5: exhaustive wire-mutation coverage suite (every field, arm, and enum spelling) green; deliberate differ-arm deletion demonstrated red.
- [ ] Milestone 5: ADR 0004 inventory amended; new codec-authority ADR created via okf; `just adr-validate` green; CHANGELOG updated.
- [ ] Final: Outcomes & Retrospective written; ADR distillation pass done; masterplan registry row updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


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

- Decision: Emit the existing three-way `Additive | Advisory (WARNING) | Breaking`
  classification, with one stable `DiagnosticCode` per distinct change class (field-add-without-
  default, arm-added, mode-crossing, and so on — the full list is in Milestone 4).
  Rationale: The soft dependency, plan `docs/plans/148-report-evolution-as-a-compatibility-vector-with-remediation-explanations.md`,
  has not landed (it is fully drafted but not implemented as of 2026-07-28). Choosing one code
  per change class means plan 148's per-surface compatibility vector (five surfaces including
  `persisted-identity`; report schema `keiro-dsl/diff-report/1`) can later attach dimensions to
  codes without renaming or splitting any code — the adoption is purely additive, as the
  masterplan's dependency section requires. If 148 lands mid-implementation, adopt its vector
  output shape for the new mapped codes directly. Note also that plan 148 owns the minimal
  `CEnum` contract-field grammar extension to `ContractType`; this plan leaves `ContractType`
  untouched — contract nodes keep their own field grammar, and mapped declarations never
  appear in contracts.
  Date: 2026-07-28

- Decision: The total-traversal guarantee (G6) is implemented by replicating the
  `familyRegistry` technique from `keiro-dsl/src/Keiro/Dsl/Diff.hs` at the type-expression
  level, strengthened to a genuine compile error: all case analyses over `TypeExpr` live in the
  new registry-owning modules, which carry
  `{-# OPTIONS_GHC -Werror=incomplete-patterns -Werror=incomplete-uni-patterns #-}`, and a
  closed `TypeExprFamily` enum with `Enum`/`Bounded` instances is covered by a registry unit
  test (`sort (map fst typeExprRegistry) == [minBound .. maxBound]`).
  Rationale: The instruction and IR-1 both require that adding a new type-expression
  constructor "must be a compile error until every subsystem handles it". `familyRegistry`
  achieves closedness today via a total `familyOf` case plus a coverage unit test
  (`keiro-dsl/test/Main.hs` line ~1000); `-Wall` alone makes an omitted arm only a warning, so
  the module-scoped `-Werror` pragmas upgrade it to an error without risking latent warnings
  elsewhere in the package.
  Date: 2026-07-28

- Decision: Timestamps (`Timestamp` type expression) are pinned to Haskell
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

- Decision: This plan creates the new codec-authority ADR (status Proposed, completed by plan
  150) and amends ADR 0004's gate inventory; both via the strict okf workflow, with the docId
  allocated by `okf id next docs/adr --profile docs/adr/profile.dhall ADR` — never by counting
  files.
  Rationale: Required by the masterplan's Integration Points ("Cross-plan decisions expected to
  become new ADRs: codec authority for consumer-owned types … EP-6/EP-7") and by
  `.claude/skills/exec-plan/ADR.md`'s handle-allocation rule.
  Date: 2026-07-28


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


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
  the scaffold/manifest/binding-drift portions belong to plan 150.
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

IR-1's verified baseline (2026-07-28): `keiki` released and tagged at `0.3.1.0`; `keiro-dsl`
released and tagged at `0.3.0.0`; the local checkout contains unreleased post-`0.3.0.0` DSL
work. Before choosing any dependency bound or declaring anything released, **re-verify against
Hackage and upstream release tags** — per the repository's global guidance, use `mori` to
locate sources and docs but treat the package registry and upstream tags as authoritative for
versions (a mori corpus checkout may lag upstream or carry local patches). Note that
`keiro-dsl` does **not** depend on `keiki` (see `build-depends` in `keiro-dsl/keiro-dsl.cabal`:
aeson, base, containers, directory, filepath, megaparsec, parser-combinators, prettyprinter,
text) and this plan adds **no new dependency**. The one keiki-facing fact this plan encodes —
the curated symbolic set used by the guard-semantics rules (Milestone 3) — must be verified by
reading keiki `0.3.1.0` source located via `mori registry show shinzui/keiki --full` at
implementation time, and the verified finding recorded in Surprises & Discoveries.

### Terms used in this plan

- **Mapped declaration**: a top-level `.keiro` declaration binding a consumer-owned Haskell
  type into the spec, in one of two modes — *structural* (Keiro declares and will own the wire
  shape) or *opaque* (an external codec identity is pinned; no nested claims).
- **Type expression**: the sublanguage of nested types usable inside structural wire shapes
  and (by nominal reference) in command/event/register positions.
- **Resolved type graph**: the single post-name-resolution data structure over all mapped
  declarations, ids, and enums, plus the index of every use site, that all subsystems traverse.
- **Use site / root**: a place a mapped type is reachable from a persisted or public surface.
  In this plan's scope the roots are aggregate command fields (decode surface for new
  commands), aggregate event fields (private history), and registers (snapshot state). A
  **root-to-leaf path** names the root and every intermediate declaration/field/arm down to
  the changed leaf, e.g.
  `Reservation event TransferReservationCreated .doc : DocInfo .location : DocLocation arm "local_file"`.
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
mapped structural record DocInfo {
  haskell package=mori-core module=Mori.Config.Types type=DocInfo
  binding = "Mori.Modules.Project.Domain.KeiroBindings.docInfo"
  canonical-type = "mori.project.DocInfo.v1"
  fixture = "Mori.Modules.Project.Domain.KeiroBindings.sampleDocInfo"
  initial = "Mori.Modules.Project.Domain.KeiroBindings.emptyDocInfo"
  wire object {
    key         as "key"         : Text                  required
    kind        as "kind"        : DocKind               required
    description as "description" : Optional Text         optional on-missing=null
    location    as "location"    : DocLocation           required
    tags        as "tags"        : List Text             optional on-missing=[]
    attributes  as "attributes"  : Map Text              optional on-missing={}
    revision    as "revision"    : Natural               required
    observedAt  as "observedAt"  : Timestamp             required
    extra       as "extra"       : Json                  optional
  }
}

mapped structural enum DocKind {
  haskell package=mori-core module=Mori.Config.Types type=DocKind
  binding = "Mori.Modules.Project.Domain.KeiroBindings.docKind"
  canonical-type = "mori.config.DocKind.v1"
  fixture = "Mori.Modules.Project.Domain.KeiroBindings.sampleDocKind"
  wire string { Guide as "guide"  Reference as "reference" }
}

mapped structural union DocLocation {
  haskell package=mori-core module=Mori.Config.Types type=DocLocation
  binding = "Mori.Modules.Project.Domain.KeiroBindings.docLocation"
  canonical-type = "mori.config.DocLocation.v1"
  fixture = "Mori.Modules.Project.Domain.KeiroBindings.sampleDocLocation"
  wire tagged-object tag="tag" contents="contents" {
    LocalFile as "local_file" : Text
    RepoPath  as "repo_path"  : Text
    Canonical as "canonical"  : Text
    Unknown   as "unknown"
  }
}

mapped opaque VendorGeometry {
  haskell package=vendor-geometry module=Vendor.Geometry type=Geometry
  codec = "vendor.geometry.json" version = "3"
  fixture = "Vendor.Geometry.KeiroBindings.sampleGeometry"
}
```

Semantics, fixed here: the `haskell` line names the Cabal package, Haskell module, and Haskell
type generated code will import (plan 150 consumes them; this plan validates and diffs them).
`binding` is the qualified symbol of the typed construction/destruction binding (structural
only). `canonical-type` is the stable application-owned type identity for snapshot shape and
diagnostics. `fixture` is the qualified symbol of a sample-value binding. `initial` is
optional; it is the qualified symbol of the initial register value and is required by `check`
exactly when the resolved graph shows the type used as a register type. In a record row,
`name` is the Haskell-side field name, `"wire"` after `as` is the wire key, the type
expression follows `:`, then a mandatory presence token (`required` | `optional`), then an
optional `on-missing=<default>` decode policy, legal only with `optional`. `Optional T` means
JSON null is a legal value (nullability), which is deliberately distinct from the presence
token (missing key); the four combinations are all expressible. Defaults are decode policy,
not documentation: `on-missing=null` (only for `Optional` types), `on-missing="text"`,
`on-missing=0`, `on-missing=true|false`, `on-missing=[]` (lists), `on-missing={}` (maps), or
`on-missing=<EnumCtor>` for enum-typed fields. In a union, `tagged-object` is the only
encoding strategy this plan supports (matching IR-1's example; others reject in Milestone 3),
`tag`/`contents` name the discriminator and payload keys, each arm is
`HaskellCtor as "wire_tag" [: TypeExpr]` with a stable wire tag and an optional single payload
type (absent = unit arm). Enum arms are `Ctor as "wire"` only. The opaque form has no
`binding`, no `wire`, and a mandatory `codec` identity plus `version` (a version or
fingerprint string).

Type expressions: `Text | Int | Bool | Natural | Timestamp | Json | Optional <T> |
List <T> | Map <T> | <Name>`, with parentheses for nesting (`List (Optional Text)`).
`Map <T>` always has text keys. A bare `<Name>` is a nominal reference resolved (in Milestone
2) against mapped declarations, id declarations, and enum declarations — this is how "existing
DSL IDs and enums by nominal match" and "nested mapped types" enter, and how aggregate
command/event fields and registers reference a mapped type today without any use-site grammar
change (`doc : DocInfo` in a command; `docInfo DocInfo = initial` as a register, where the
bare initial token `initial` defers to the declaration's `initial` symbol).

Edits:

1. `keiro-dsl/src/Keiro/Dsl/Grammar.hs` — add, in a new "Consumer-owned mapped types (EP-149)"
   section: `TypeExpr` (constructors `TText`, `TInt`, `TBool`, `TNatural`, `TTimestamp`,
   `TJson`, `TOptional !TypeExpr`, `TList !TypeExpr`, `TMap !TypeExpr`, `TRef !Name`),
   `Presence (PRequired | POptional)`, `OnMissing (OmNull | OmText !Text | OmInt !Int |
   OmBool !Bool | OmEmptyList | OmEmptyMap | OmCtor !Name)`, `WireField { wfHaskell :: !Name,
   wfKey :: !Text, wfType :: !TypeExpr, wfPresence :: !Presence, wfOnMissing :: !(Maybe
   OnMissing), wfLoc :: !Loc }`, `UnionEncoding (TaggedObject { ueTagField :: !Text,
   ueContentsField :: !Text })`, `WireArm { waCtor :: !Name, waTag :: !Text, waPayload ::
   !(Maybe TypeExpr), waLoc :: !Loc }`, `MappedShape (ShapeRecord ![WireField] | ShapeEnum
   ![(Name, Text)] | ShapeUnion !UnionEncoding ![WireArm])`, `HaskellSource { hsPackage ::
   !Text, hsModule :: !Text, hsType :: !Name }`, and `MappedDecl` with two constructors
   (`MappedStructural { msName :: !Name, msHaskell :: !HaskellSource, msBinding :: !Text,
   msCanonical :: !Text, msFixture :: !Text, msInitial :: !(Maybe Text), msShape ::
   !MappedShape, msLoc :: !Loc }` and `MappedOpaque { moName :: !Name, moHaskell ::
   !HaskellSource, moCodecId :: !Text, moCodecVersion :: !Text, moFixture :: !Text,
   moInitial :: !(Maybe Text), moLoc :: !Loc }`), all with `Eq`/`Show`/`Generic` stock
   deriving and export-list entries. Add `specMapped :: ![MappedDecl]` to `Spec` (this touches
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
   command, event, and register use `DocInfo` and `VendorGeometry` nominally, with an event
   carrying scalar decision fields beside the mapped payload (modeling the research note's
   section 4 guidance).

Acceptance: `cabal test keiro-dsl-test` green including the extended property;
`cabal run keiro-dsl -- parse keiro-dsl/test/fixtures/consumer-types.keiro` prints the spec
back and a second `parse` of that output succeeds (demonstrated in Concrete Steps).

### Milestone 2 — The resolved type graph and the total traversal registry

Scope: one new module, `keiro-dsl/src/Keiro/Dsl/TypeGraph.hs` (added to `exposed-modules` in
`keiro-dsl/keiro-dsl.cabal`), that every later consumer traverses. This is guarantee G6 made
mechanical, and the artifact plan 150's generation layer will consume.

The module provides:

- `data ResolvedRef = RefMapped !MappedDecl | RefId !IdDecl | RefEnum !EnumDecl | RefBuiltin
  !Name` — what a `TRef`/field-type `Name` resolves to (`RefBuiltin` covers the legacy
  `Text`/`Int`/`Bool`/`Time` spellings so aggregate fields keep working unchanged).
- `resolveTypeGraph :: Spec -> Either [Diagnostic] TypeGraph` — name resolution over all
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
- The **registry**, replicating the `familyRegistry` technique from
  `keiro-dsl/src/Keiro/Dsl/Diff.hs` (lines ~153–166) one level down:

```haskell
data TypeExprFamily
    = TefText | TefInt | TefBool | TefNatural | TefTimestamp | TefJson
    | TefOptional | TefList | TefMap | TefRef
    deriving stock (Eq, Ord, Show, Enum, Bounded)

-- Total by construction: one explicit arm per TypeExpr constructor, no wildcard.
typeExprFamily :: TypeExpr -> TypeExprFamily

-- One entry per family; every subsystem's handling is a field, so a new
-- constructor cannot reach one subsystem and silently miss another.
data TypeExprSupport = TypeExprSupport
    { tesGuard :: !GuardSupport        -- Milestone 3: symbolic / not-symbolic
    , tesWireForm :: !WireForm         -- JSON category (string/number/bool/array/object/any)
    , tesGolden :: !(GoldenSynth)      -- Milestone 5: old-shape sample synthesis
    , tesDiffLeaf :: !(DiffLeaf)       -- Milestone 4: wire-identity comparison at this leaf
    , tesScaffoldNote :: !Text         -- non-empty note for plan 150's consumers (manifest,
                                       -- codec, harness) — the explicit hand-off contract
    }

typeExprRegistry :: [(TypeExprFamily, TypeExprSupport)]
```

Closedness enforcement, exactly as decided in the Decision Log: (a) `typeExprFamily` and every
other case analysis over `TypeExpr`, `MappedShape`, `OnMissing`, and `MappedDecl` live in
`TypeGraph.hs` (or the Milestone 4 `MappedDiff.hs`), and both modules carry
`{-# OPTIONS_GHC -Werror=incomplete-patterns -Werror=incomplete-uni-patterns #-}` so a new
constructor is a **compile error** in the registry-owning modules; (b) `Validate`, `Diff`,
`Goldens`, and `ReplayImpact` consume type expressions only through `TypeGraph`/`MappedDiff`
functions, never by matching `TypeExpr` themselves (enforce by convention and review; the
module boundary makes violations visible in imports); (c) a unit test in
`keiro-dsl/test/Main.hs` mirrors the family test at line ~1000:
`sort (map fst typeExprRegistry) == ([minBound .. maxBound] :: [TypeExprFamily])` and every
`tesScaffoldNote` is non-empty.

Acceptance: unit tests for resolution (a `TRef` to each of mapped/id/enum/builtin), for cycle
detection (direct, mutual, through `List`/`Optional`/`Map`/arm payload), for use-path
completeness on `consumer-types.keiro` (the expected path set is written out in the test), and
the registry coverage test. `cabal test keiro-dsl-test` green.

### Milestone 3 — `check` rejections and negative fixtures

Scope: wire the graph into `validateSpec` and implement IR-1's Validation and Scaffolding
Contract for the spec layer. IR-1's list, verbatim, with the parenthesized owner in this plan:

> `keiro-dsl check` must reject: unresolved or ambiguous type and binding names (graph
> resolution); duplicate record wire keys, duplicate union arm names, or duplicate union wire
> tags (shape rules); recursive structural mappings and unbounded structural recursion (graph
> cycle detection); unsupported map keys or unsupported wire encodings (shape rules); missing
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
   name), `MappedDuplicateWireKey`, `MappedDuplicateArmName`, `MappedDuplicateWireTag`,
   `MappedRecursiveType`, `MappedUnsupportedMapKey`, `MappedUnsupportedEncoding`,
   `MappedMissingIngredient` (with the missing ingredient — package/module/type, binding,
   canonical-type, fixture — named in the message), `MappedMissingInitialValue`,
   `MappedInvalidHaskellName`, `MappedImportConflict`, `MappedDefaultIllTyped`,
   `MappedGuardUnsupported`. Add a `validateMapped :: Spec -> [Diagnostic]` pass invoked from
   `validateSpec` that first runs `resolveTypeGraph` (its `Left` diagnostics flow straight
   through) and then the graph-dependent rules.
2. Rule details fixed here so the implementer decides nothing silently:
   - *Lexical Haskell-name rules* (`MappedInvalidHaskellName`): package names match Cabal's
     grammar (alphanumeric/hyphen words, no leading/trailing hyphen, at least one letter per
     word); module names are dot-separated `Upper` identifiers; the Haskell type is an `Upper`
     identifier; binding/fixture/initial symbols are a module path plus a `lower`-initial
     identifier. Reuse the identifier-hygiene helpers from the EP-105 rules
     (`IdentHaskellKeyword`, `IdentNotConstructorSafe`) where they fit.
   - *Conflict rules* (`MappedImportConflict`): two mapped declarations naming the same
     Haskell `module.type` with different spec names or different canonical identities; two
     declarations with the same `canonical-type` string; a mapped declaration whose spec name
     collides with a built-in type name (`Text`, `Int`, `Bool`, `Time`, plus the new
     `Natural`, `Timestamp`, `Json`, `Optional`, `List`, `Map` keywords), an id, or an enum
     (also `MappedAmbiguousName`). Generated-path collisions proper are plan 150's scaffold
     concern; the spec-layer conflict rules cover everything decidable from text.
   - *Default typing* (`MappedDefaultIllTyped`): `on-missing=null` only for `TOptional` types;
     `on-missing=[]` only for `TList`; `on-missing={}` only for `TMap`; text/int/bool
     literals only for the matching scalar; `OmCtor` only for enum-typed fields naming a
     declared constructor; `on-missing` on a `required` field is ill-formed; a negative
     integer default for `TNatural` is ill-typed.
   - *Guard rules* (`MappedGuardUnsupported`, error severity): resolve every guard atom and
     comparison operand (the existing scope-check machinery in `Validate.hs` already resolves
     atoms against registers/command fields); when an operand's declared type resolves through
     the graph to a type expression whose `tesGuard` is not symbolic — any mapped record,
     union, or opaque type, any `List`/`Map`/`Json`, and `TNatural` — reject the guard. The
     symbolic set to encode in `tesGuard` (verify against keiki 0.3.1.0 source via mori before
     hard-coding, and record the verification in Surprises & Discoveries): `Text`, `Int`,
     `Bool`, `Timestamp`/`Time` (UTCTime is curated), ids, and declared enums. Writes and
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
   `mapped-dup-wirekey.keiro`, `mapped-dup-armname.keiro`, `mapped-dup-tag.keiro`,
   `mapped-recursive.keiro` (direct), `mapped-recursive-mutual.keiro`,
   `mapped-bad-encoding.keiro`, `mapped-missing-binding.keiro`,
   `mapped-missing-canonical.keiro`, `mapped-missing-fixture.keiro`,
   `mapped-missing-initial.keiro` (mapped register, no `initial`),
   `mapped-bad-haskell-name.keiro`, `mapped-import-conflict.keiro`,
   `mapped-illtyped-default.keiro`, `mapped-guard.keiro` (equality guard over a mapped
   value), `mapped-guard-natural.keiro` (ordering guard over a `Natural` field — proves the
   curated-set asymmetry: the same spec with a `Timestamp` comparison must pass). Each gets a
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
changes through the registry's `tesDiffLeaf` comparators, and then **expands every change to
every containing root** using both specs' `TypeGraph` use-site indexes, emitting one `Change`
per (root, path) with `ckNode` = the aggregate, `ckFacet` = the root surface kind, `ckSubject`
= the rendered root-to-leaf path, and `ckCode` = the class code. Wire identities are compared,
never Haskell spellings: a changed `wfHaskell` or `waCtor` with an unchanged wire key/tag is
**not** a wire change.

IR-1's Evolution Contract, restated as the classification matrix to implement (each row: a new
appended `DiagnosticCode`, its classification, and the obligation text the change's
`ckDetail` must carry):

- `MappedFieldAddedWithDefault` — Additive for private-history read: a field added with an
  explicit `on-missing` default that preserves old meaning. Detail names the default.
- `MappedFieldAddedNoDefault` — Breaking: adding a field without an on-missing default means
  old stored payloads no longer decode under the declared shape; the containing event or
  snapshot requires a versioned migration (version bump + upcaster at the root).
- `MappedFieldRemoved` — Breaking at every private-event root (replay-relevant field removal
  is replay-affecting even when a tolerant JSON decoder would ignore the historical key — the
  detail must say this) and at snapshot roots.
- `MappedFieldTypeChanged`, `MappedPresenceChanged`, `MappedNullabilityChanged`,
  `MappedDefaultRemoved`, `MappedDefaultChanged`, `MappedWireKeyChanged`,
  `MappedUnionEncodingChanged`, `MappedEnumSpellingChanged` — Breaking (removing an
  on-missing default, changing a field's wire type, presence, or nullability, changing union
  encoding, renaming a wire identity: all breaking unless an outer migration handles it; the
  detail names the remedy — version bump + upcaster at each affected root).
- `MappedArmAdded` — **not universally additive**: Advisory (WARNING) at private-history
  roots with a rollout advisory in the detail ("backward-readable for existing history, but
  an older binary cannot read the new arm once emitted; deploy readers before writers").
  Public integration contracts do not carry mapped types in this plan's roots (the private/
  public boundary from IR-1's Usage Boundaries; contract nodes keep their own field grammar),
  so the closed-public-consumer Breaking case is recorded in the detail text as the rule that
  applies if a future surface exposes the union publicly — and the research note's Experiment
  D (one arm addition producing distinct per-root results) is re-verified against nested
  paths here with an evolution fixture whose union is used by an event root and a snapshot
  register root, asserting two distinct classifications/paths.
- `MappedArmRemoved`, `MappedArmTagChanged` — Breaking at every root still decoding history.
- `MappedHaskellBindingChanged` — Advisory, reported separately as a source/build
  compatibility change (package, module, type, binding, fixture, or initial symbol changed;
  wire unchanged). Either may gate a release, but it must never be conflated with a wire
  break.
- `MappedCanonicalTypeChanged` — Breaking at snapshot roots (the identity a snapshot shape
  pins), Advisory elsewhere.
- `MappedOpaqueCodecChanged` — Breaking: opaque codec identity or version changed; Keiro
  cannot inspect the internal claim.
- `MappedModeCrossed` — Breaking in both directions (structural→opaque and opaque→structural).
- `MappedDeclRemoved` — Breaking at every root that still references it in the old spec
  (paired with the unresolved-name error in single-spec check of the new spec if uses
  remain).

A nested breaking change propagates to **every** containing private event and snapshot root;
each emitted `Change` is per-root so each root's obligation (its own version bump, upcaster,
or deployment note) appears once per root, as IR-1 demands. The `diff` exit-code invariant is
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
pinned — must produce *no* wire change, only `MappedHaskellBindingChanged`),
`consumer-types-armadd.keiro`, `consumer-types-tagchange.keiro`,
`consumer-types-encoding.keiro`, `consumer-types-opaque-version.keiro`,
`consumer-types-mode-cross.keiro`, `consumer-types-nested-propagation.keiro` (a leaf change
in `DocLocation` reached through `DocInfo` from two roots — asserts two complete paths).
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
synthesize nested old-shape JSON through the **old** spec's `TypeGraph` and the registry's
`tesGolden` synthesizers (moving JSON construction to `aeson` `Value` with stable key order
rather than growing the manual text builder). Sample policy, fixed here for determinism:
required fields present; `optional` fields with an `on-missing` default *omitted* (so the
fixture exercises the old decode policy); `Optional` values non-null; unions use the first
declared arm; lists carry one element; maps carry one `"sample"` key; `Natural` is `1`;
`Timestamp` is `"2026-01-01T00:00:00Z"`; `Json` is `{}`; ids/enums keep the existing sample
conventions. Trigger stays the same as today (an event whose version increases while both
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
2. Create the new codec-authority ADR: allocate the handle first —

   ```bash
   okf id list docs/adr --profile docs/adr/profile.dhall
   okf id next docs/adr --profile docs/adr/profile.dhall ADR
   ```

   — then write `docs/adr/<NNNN>-consumer-owned-types-have-a-single-generated-codec-authority.md`
   with the allocated `docId`, status `Proposed` (plan 150 moves it to Accepted when the
   generated codec exists), recording: structural mode's wire schema is owned by the spec and
   its (future) generated codec — the executed codec must come from the declaration, and a
   consumer instance may delegate to the generated codec, never the reverse; opaque mode pins
   an external codec identity/version and never silently upgrades to a structural claim; the
   spec layer's `check`/`diff` therefore classify only declared wire identities and treat
   opaque interiors and all Haskell-symbol facts as out of wire scope. Cite IR-1, the
   research note, and `mori://shinzui/mori/okf/adrs/concepts/ADR-6`. Update `log.md`.
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
mapped structural record DocInfo {
  haskell package=mori-core module=Mori.Config.Types type=DocInfo
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
BREAKING: Catalog event DocObserved .doc : DocInfo field "contentHash": field added without
  an on-missing default; old stored payloads no longer decode under the declared shape —
  bump the containing event version and supply an upcaster [MappedFieldAddedNoDefault]
replay-affected: run the candidate binary's targeted replay audit for Catalog
  events=[DocObserved] snapshots=yes
exit=1
$ cat "$DEMO/impact.json"
{"verdict":"affected","aggregates":{"Catalog":{"eventTypes":["DocObserved"],"includeSnapshotStreams":true}}}
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
   every type expression (`Optional`, `List`, `Map`, `Natural`, `Timestamp`, `Json`, nominal
   refs), explicit wire metadata, every `on-missing` form, JSON leaves — the QuickCheck
   property and the fixture tests prove `parseSpec "<gen>" (renderSpec s) == Right s`.
   Command: `cabal test keiro-dsl-test` (round-trip describe blocks).
2. **Negative fixtures**: each of the seventeen `mapped-*.keiro` fixtures makes
   `keiro-dsl check` exit non-zero with its exact expected `DiagnosticCode` — covering
   unresolved, ambiguous, recursive, duplicate (wire key/arm/tag), unsupported (encoding, map
   key), binding-incomplete (missing binding/canonical/fixture/initial), guard-opaque
   (mapped-value and `Natural` guards), and import/package-collision faults.
3. **Evolution fixtures**: the fixture pairs distinguish wire changes, Haskell-binding
   (source-compat) changes, replay-affecting changes, rollout advisories (union arm add), and
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
   (canonical-type and register roots), and source compatibility (binding changes reported
   separately); codes are one-per-class so plan 148's per-surface vector adopts them
   additively.
5. **Ownership** — Mapped types are usable only at private roots (commands, events,
   registers); contract nodes keep their own field grammar, so a private domain type cannot
   become a public contract by reuse.
6. **Completeness** — The `typeExprRegistry` with module-scoped
   `-Werror=incomplete-patterns`, the registry coverage unit test, and the exhaustive
   wire-mutation suite make an omitted parser/pretty/check/diff/golden case a compile error
   or a red test.
7. **Migration** — Wire identities, not Haskell names, are compared; defaults are decode
   policy; version bumps with upcasters at each affected root are the named remedy; goldens
   synthesize the old nested shape while both specs exist and never overwrite hand-captured
   bytes (research note section 12).
8. **Recovery** — This plan changes only the toolchain: no generated file, no runtime, no
   migration. Every step is re-runnable; a bad state is recovered by `git checkout` of the
   touched sources. `--emit-goldens` is idempotent by the never-overwrite rule.
9. **Performance** — Text-tool only; graph resolution is linear in spec size with a
   cycle-detection DFS. No runtime codec exists yet to benchmark; the registry's
   `tesScaffoldNote` hand-off explicitly leaves encoder fusion to plan 150 with the research
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
rename. ADR edits are guarded by `just adr-validate`; if `okf id next` was consumed but the
ADR is abandoned, do not reuse the handle — allocate again next time (gaps are legal, reuse is
not). If a milestone is interrupted, the Progress section's done/remaining split plus the last
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
expected; if any bound must move, first re-verify released versions against Hackage and
upstream tags (baseline: keiki `0.3.1.0`, keiro-dsl `0.3.0.0`, local checkout ahead of the
released tag).

Module-level interface contract at the end of each milestone (full paths; signatures are the
minimum that must exist — implementers may add, not subtract):

Milestone 1, `Keiro.Dsl.Grammar` (`keiro-dsl/src/Keiro/Dsl/Grammar.hs`): `TypeExpr`,
`Presence`, `OnMissing`, `WireField`, `UnionEncoding`, `WireArm`, `MappedShape`,
`HaskellSource`, `MappedDecl` (all exported, `Eq`/`Show`/`Generic`); `Spec` gains
`specMapped :: ![MappedDecl]`. `Keiro.Dsl.Parser.parseSpec` and
`Keiro.Dsl.PrettyPrint.renderSpec` keep their signatures and cover the new syntax.

Milestone 2, `Keiro.Dsl.TypeGraph` (new file `keiro-dsl/src/Keiro/Dsl/TypeGraph.hs`):

```haskell
resolveTypeGraph :: Spec -> Either [Diagnostic] TypeGraph
data ResolvedRef = RefMapped !MappedDecl | RefId !IdDecl | RefEnum !EnumDecl | RefBuiltin !Name
data UseSite   -- root surface + referenced declaration (constructors in Milestone 2 text)
usePaths :: TypeGraph -> Name -> [UsePath]
renderUsePath :: UsePath -> Text
data TypeExprFamily  -- Eq, Ord, Show, Enum, Bounded
typeExprFamily :: TypeExpr -> TypeExprFamily
data TypeExprSupport -- tesGuard, tesWireForm, tesGolden, tesDiffLeaf, tesScaffoldNote
typeExprRegistry :: [(TypeExprFamily, TypeExprSupport)]
wireFingerprint :: TypeGraph -> Name -> Text   -- wire-identity-only fingerprint (Milestone 4 uses it)
```

Milestone 3, `Keiro.Dsl.Validate`: `DiagnosticCode` extended (append-only) with the fourteen
single-spec codes named in Milestone 3; `validateSpec` unchanged in signature, now covering
mapped rules through `resolveTypeGraph`.

Milestone 4, `Keiro.Dsl.MappedDiff` (new file `keiro-dsl/src/Keiro/Dsl/MappedDiff.hs`):
`mappedDiff :: DiffEnv -> [Change]`, invoked from `Keiro.Dsl.Diff.sharedDeclarationDiff`;
`DiagnosticCode` extended with the seventeen diff codes named in Milestone 4;
`Keiro.Dsl.ReplayImpact.replayImpact` unchanged in signature, decode surfaces now including
`wireFingerprint` of reachable mapped declarations.

Milestone 5, `Keiro.Dsl.Goldens`: `goldensForDiff`/`emitGoldenPayloads` unchanged in
signature, synthesis now registry-driven for nested shapes. Consumed-by contract: plan 150
builds its scaffold planning, manifests, codecs, and harness on `Keiro.Dsl.TypeGraph`
(`resolveTypeGraph`, `typeExprRegistry`, `usePaths`, `wireFingerprint`) and the
`MappedDecl` grammar — treat their exported names as stable once this plan completes; breaking
them afterward requires coordinating with plan 150.


---

Revision note: Aligned cross-plan references during MasterPlan 25 consistency review, 2026-07-28.
