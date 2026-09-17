---
id: 287
slug: support-nominal-ids-inside-structural-mapped-types
title: "Support nominal IDs inside structural mapped types"
kind: exec-plan
created_at: 2026-09-16T23:02:46Z
intention: "intention_01m2p79tjte5ftry3pdmgbqtjw"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-16T23:02:46Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-17T03:43:16Z
      mode: "update"
      note: "Widened scope to workqueue payload rows and read-model query expressions"
---

# Support nominal IDs inside structural mapped types

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today a `.keiro` author can declare an identifier type once, for example
`id TemplateId prefix=template`, and use it as a direct field of an aggregate command or
event. Keiro then owns the whole contract for that field: the generated Haskell type is
nominal (a `TemplateId` cannot be confused with a `ClaimId`), the JSON text is a canonical
TypeID (`template_01h455vb4pex5vsknk084sn02q`), decoding rejects a wrong prefix or a malformed
suffix, and `keiro-dsl diff` reports a prefix change as a breaking change.

The same identifier cannot be placed inside a `mapped structural record`, union, `Optional`,
`List`, or `Map`. `keiro-dsl check` rejects it with `MappedUnresolvedName`, because the
structural type resolver only knows the names of other mapped declarations. The consumer that
filed this request (`mori://tan/notification-render-service`, improvement request
[IR-40](../improvement-requests/support-nominal-ids-inside-structural-mapped-types.md))
models a notification type whose state is a list of template records, each carrying a
`TemplateId`. Its only workaround is to declare a second, `mapped opaque` twin of the same
Haskell type, which turns every persisted root containing it into an opaque boundary. That
trips the `CoverageOpaqueSurface` warning, which the consumer's `--deny-warnings` production
gate turns into a failure, and an optional opaque ID is separately rejected by
`MappedNonInjectiveNullability`, forcing a third wrapper type just to carry `Maybe`.

After this plan, the following specification checks, scaffolds, compiles, and passes its
generated conformance suite under candidate Language 6:

```text
language keiro-dsl 6
context nested-id-repro

id TemplateId prefix=template

mapped structural record TemplateState {
  haskell package=example-core module=Example.Model type=TemplateState
  binding = "Example.Bindings.templateStateBinding"
  binding-version = "1"
  canonical-type = "example.TemplateState.v1"
  fixtures = "Example.Bindings.templateStateFixtures"
  wire object constructor=TemplateState unknown-fields=reject {
    templateId as "templateId" : TemplateId required
  }
}

aggregate NotificationType
  regs
  states NotCreated Active!
  command Create { template:TemplateState }
  event Created = fields(Create)
  NotCreated -- Create -->
    emit Created
    goto Active
  wire kind=ctorName fields=camelCase schemaVersion=1
```

Inside the record the `TemplateId` field keeps its nominal Haskell type, is encoded as
canonical TypeID text, is decoded through Keiro's own prefix and UUID-version-7 admission
(never through an arbitrary consumer `FromJSON` instance), counts as structural coverage, and
is followed by `diff`, semantic impact, and snapshot invalidation exactly as a direct field
is. `Optional TemplateId`, `List TemplateState`, `List (Optional TemplateId)`, union arms
carrying an ID, and `Map TemplateId` (a text-keyed map whose values are IDs) all work the same
way. Consumer-bound IDs (`id ... using { ... }`) and `mapped nominal` scalars are supported as
the same kind of leaf. Nominal enums are deliberately rejected with a diagnostic that names
the limitation, so nothing is silently lowered to text or mislabelled as opaque. The same
leaves are accepted at the two other consumer roots that resolve through the structural type
graph: typed workqueue payload rows (`holder -> "holder" : Optional ClaimId`) and read-model
`query input` and `query result` expressions (`query result = List TemplateId`).


## Progress

- [ ] M1. Add the nominal leaf to the resolved type graph, resolve `id` and `mapped nominal`
      names inside structural declarations, and gate the capability on candidate Language 6.
- [ ] M1. Classify nullability, `on-missing` defaults, wire fingerprint token, use paths,
      nominal reachability, and nominal root sites at workqueue and read-model roots.
- [ ] M1. Add the `MappedNominalLeafRequiresLanguage` and `MappedNominalLeafUnsupported`
      diagnostics with fixtures, and extend the stable code table in `keiro-dsl/test/Main.hs`.
- [ ] M1. `cabal test keiro-dsl:test:keiro-dsl-test` is green and the IR-40 reproduction
      checks `OK` at Language 6 and reports the language diagnostic at Language 5.
- [ ] M2. Render nominal leaf shape types and imports; emit the per-context
      `Structural.NominalLeaves` codec module; wire `MappedCodecPlan`, `ConsumerTypePlan`,
      `ExplainBindings`, and the binding skeleton.
- [ ] M2. Extend `StructuralConformance` with nominal-leaf declaration laws and remove the
      generated-source `error` for non-enum defaults in `Harness.hs`.
- [ ] M2. Add the `keiro-dsl-conformance-structural-nominals` corpus with positive round
      trips, negative decoders with located errors, and a mutation script that turns the
      suite red when admission is bypassed.
- [ ] M2. The corpus also compiles a workqueue payload and a read-model query pair typed by
      nominal leaves; the queue codec round-trips TypeID text and rejects a wrong prefix at
      the payload path.
- [ ] M3. Coverage reports nominal boundaries as structural, including workqueue payload
      roots; the strict gate passes on the fully structural fixture.
- [ ] M3. `MappedDiff` compares nominal leaves; `Diff.nominalUses` includes structural use
      paths; mutants for prefix, binding-version, opaque-to-nominal, and text-to-nominal are
      classified and golden-tested; `CodecCompare` branch schema handles the leaf.
- [ ] M4. Workspace fixture proves one shared ID owner reachable from two members' records
      without duplicate declarations or import cycles; corpus regeneration is byte-stable.
- [ ] M4. User documentation, changelog, a new ADR, and IR-40 status updates are written
      and validated by `just verify`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Represent a nominal reference as a third leaf constructor `RNominal` on
  `ResolvedTypeExpr`, carrying the checked leaf facts inline, instead of widening
  `ResolvedMappedDecl` with a nominal constructor so `RRef` keeps working.
  Rationale: every consumer of `RRef` resolves it through `Map.lookup` against the mapped
  declaration map, and several of those sites have silent fallbacks (`toJSON`/`parseJSON` in
  `MappedCodecPlan`, `()` in `renderShapeType`, `missing:` in `wireFingerprint`). A new
  constructor makes each of them a compile error under the repository's
  `-Werror=incomplete-patterns` policy, which is how this codebase forces every checker,
  differ, fingerprinter, and generator to take an explicit position.
  Date: 2026-09-16
- Decision: Support `id` declarations (generated and consumer-bound) and `mapped nominal`
  scalars as leaves. Reject nominal enums (generated `enum` and `enum ... using`) with
  `MappedNominalLeafUnsupported`; authors keep using `mapped structural enum` for nested
  enumerations.
  Rationale: IDs and scalars have one non-null scalar JSON image and reuse existing admission
  and binding code. Enums would additionally need constructor `on-missing` defaults, arm
  branch-coverage obligations in `StructuralConformance`, and the generated representation
  module inside shapes. IR-40 requires nested TypeIDs and allows enum composition to be
  tracked separately as long as it is not silently erased.
  Date: 2026-09-16
- Decision (superseded by the next entry): A nominal leaf is accepted only inside a structural declaration (record field,
  union arm payload, and containers within those). A nominal leaf reached directly from a
  workqueue field or a read-model query input/result without passing through a structural
  declaration is rejected with `MappedNominalLeafUnsupported` naming the surface.
  Rationale: those roots are `UseSite`s keyed by `MappedKey`, have their own persisted
  envelope and conformance suites, and are outside the request's scope. A deliberate
  diagnostic is better than today's misleading `MappedUnresolvedName`.
  Date: 2026-09-16
- Decision: Accept nominal leaves at workqueue payload rows and read-model query input and
  result expressions, with or without a structural declaration in between. This supersedes
  the previous entry.
  Rationale: both surfaces were verified on 2026-09-16 to fail with the same
  `MappedUnresolvedName` as records (`maybeJob -> "maybe_job" : Optional TemplateId` in a
  workqueue payload; `query result = List TemplateId` on a read model) for the same root
  cause. `ConsumerTypePlan` and `MappedCodecPlan` already serve these roots, so the marginal
  work is a nominal root-site inventory beside the mapped use sites; excluding them would
  leave the consumer's next specification in today's situation.
  Date: 2026-09-17
- Decision: Gate the capability on the unpublished candidate Language 6 through a new
  `RuntimeCapability` named `StructuralNominalLeaves` on runtime profile 5, with
  `capabilityFoldSegment` returning `Nothing`. Published Languages 1 through 5 keep rejecting
  the reference, but with `MappedNominalLeafRequiresLanguage` instead of
  `MappedUnresolvedName`.
  Rationale: `Keiro.Dsl.LanguageVersion` documents that published registry entries are
  immutable and the active candidate may be amended in place. The change alters generated
  wire behaviour and diff classification, which is a runtime capability, not syntax. Because
  Language 6 already carries `GeneratedIdDomainTypeIdV7`, every nested ID is always under the
  enforced `keiro-dsl/id-domain/typeid-v7/1` domain, so the leaf never needs a legacy
  unrestricted-text mode. Fold identity is unaffected because the capability changes codecs,
  not transitions.
  Date: 2026-09-16
- Decision: Inside a generated shape, a nominal leaf field has the nominal domain type itself
  (the generated `TemplateId`, or the consumer's type for a consumer-bound ID or nominal
  scalar), not its representation (`KindID "template"`, `Text`). Admission and the nominal
  binding are applied by leaf codec helpers emitted once per context in a generated module
  `<Context>.Structural.NominalLeaves`.
  Rationale: the consumer's structural binding then moves IDs without conversion, which is the
  ergonomics the request asks for, and one generated module keeps a single admission
  authority per context without touching the existing generated nominal modules of every
  corpus.
  Date: 2026-09-16
- Decision: The wire fingerprint token for a nominal leaf is `nominal-id(<prefix>,<domain>)`
  for IDs and `nominal-scalar(<representation>)` for scalars. Binding symbol, binding version,
  and Haskell source are excluded.
  Rationale: ADR 12 fixes the wire fingerprint to schema-authority facts only; a nested
  structural declaration is already hashed by its shape, not its binding. The prefix and
  domain version are the facts that change bytes on the wire.
  Date: 2026-09-16
- Decision: Nominal leaf fields accept no literal `on-missing` default. An absent-capable
  nominal field is written `Optional TemplateId optional on-missing=null`.
  Rationale: a literal ID default would have to be admitted against the prefix domain at
  check time and would bake an identifier into the schema; `Optional` with `null` already
  expresses absence and is injective because a nominal leaf is never JSON null.
  Date: 2026-09-16
- Decision: In `MappedDiff`, two nominal leaves compare equal when their declaration names
  are equal. Prefix, binding, fixture, canonical-type, and initial changes of the nominal
  declaration are reported once by the existing nominal diff in `Keiro.Dsl.Diff`, whose use
  list is extended with every structural path that reaches the nominal. Replacing an opaque
  twin or `Text` with a nominal leaf in a field is `MappedFieldTypeChanged` on every persisted
  path, the conservative wire-breaking classification.
  Rationale: one finding per fact avoids duplicate reports; the consumer proves byte parity
  for the opaque-to-nominal migration with the historical codec comparison from plan 152, and
  the existing evolution rules decide what parity permits.
  Date: 2026-09-16
- Decision: Leave `mappedConflictRules` unchanged, so a consumer-bound nominal and a mapped
  opaque declaration may still name the same Haskell type and canonical type.
  Rationale: the consumer's transitional specification declares exactly that twin today; it
  must remain checkable while the migration to nominal leaves is in progress.
  Date: 2026-09-16
- Decision: Nested nominal leaves are not exposed as aggregate expression paths, router
  selection keys, or generated projection witnesses in this plan.
  Rationale: IR-40 concerns composition and codecs, and IR-12 (nominal equality in
  expressions) covers direct fields only; extending symbolic projection through structural
  records is a separate design.
  Date: 2026-09-16
- Decision: Deliver this as one ExecPlan with four dependent milestones rather than a
  MasterPlan.
  Rationale: the work is one coherent DSL capability whose stages share a single new
  constructor and cannot ship independently.
  Date: 2026-09-16


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Keiro is a Haskell event-sourcing runtime. `keiro-dsl` is its specification language and
compiler: an author writes a `.keiro` file, `keiro-dsl check` validates it, and
`keiro-dsl scaffold` generates Haskell modules (codecs, transducers, harnesses) that the
consumer's Cabal package compiles. All paths below are relative to the repository root
`/Users/shinzui/Keikaku/bokuno/keiro`, and `keiro-dsl` is the package under
`keiro-dsl/`.

A *nominal declaration* is a `.keiro` declaration that introduces a distinct Haskell type
over one scalar representation. There are three kinds today: `id Name prefix=p`, which is a
TypeID-prefixed identifier; `enum Name { Ctor=wire ... }`, a closed enumeration; and
`mapped nominal Name : Text { ... }`, a consumer-owned wrapper over `Text`, `Int`, `Natural`,
`Bool`, or `Time`. An `id` or `enum` may carry `using { haskell=... binding=... }` to bind to
a consumer-owned Haskell type instead of a generated one; a `mapped nominal` always does.
They are resolved by `keiro-dsl/src/Keiro/Dsl/NominalType.hs` (`resolveNominalTypes`) into
`ResolvedNominalType` values with a `NominalRepresentation` (`IdRepresentation prefix`,
`EnumRepresentation`, or `ScalarRepresentation`) and a `NominalOwnership`
(`GeneratedNominal` or `ConsumerNominal ConsumerNominalBinding`). A consumer binding is a
record of the consumer's Haskell source, a qualified binding symbol, a binding version, a
canonical type identity, a fixtures symbol, and an optional initial symbol.

A *structural mapped type* is a consumer-owned record, string enum, or tagged union whose
JSON shape the `.keiro` file fully describes (`mapped structural record ...`). Keiro
generates an intermediate *shape* datatype and a codec for it; the consumer supplies a total
isomorphism (`StructuralBinding domain shape`, from `Keiro.Codec.Structural`) between its own
type and the shape, plus fixtures. An *opaque mapped type* (`mapped opaque`) instead delegates
JSON entirely to the consumer's codec and is reported as an *opaque boundary*.

The *resolved type graph* is `keiro-dsl/src/Keiro/Dsl/TypeGraph.hs`. `resolveTypeGraph ::
Spec -> Either (NonEmpty TypeGraphError) TypeGraph` checks every mapped declaration, builds
`keyByName` from mapped declaration names only (line 334), and resolves each field or arm type
expression with `resolveExpr` (lines 489 to 501) into a `ResolvedTypeExpr`:
`RText | RInt | RInteger | RBool | RNatural | RTime | RJson | ROptional | RList | RMap |
RRef MappedKey`. An unknown `TRef` name is `TGUnresolvedRef`, which
`keiro-dsl/src/Keiro/Dsl/Validate.hs` renders as `MappedUnresolvedName` (lines 1174 to
1181). This is the exact failure IR-40 reproduces; it was re-verified on 2026-09-16 with the
built 0.16.0.0 `keiro-dsl` at both Language 5 and Language 6, while the same ID checks fine as
a direct aggregate field (that path goes through `resolveAggregateType` in
`keiro-dsl/src/Keiro/Dsl/AggregateType.hs`, lines 127 to 150, which tries nominals, vertices,
then mapped names in order, the precedent this plan mirrors).

The graph is folded by total algebras: `TypeExprAlgebra` (with an `onRef` field),
`MappedShapeAlgebra`, and `MappedDeclAlgebra`. Adding a constructor to `ResolvedTypeExpr` and
a field to `TypeExprAlgebra` makes every consumer fail to compile until it handles the new
leaf. The consumers, and what each does with `RRef` today, are:

- `TypeGraph.hs` itself: `rootReference` (624 to 636) decides whether a consumer-root
  expression names a mapped root; `refsInExpr` feeds reachability and the cycle check;
  `usePaths`/`pathsInExpr` (647 to 704) enumerate root-to-declaration paths as `PathSeg`
  lists (`SegOptional`, `SegElem`, `SegMapValue`, `SegDecl name`, and field/arm segments);
  `wireFingerprint` (795 to 869) hashes a canonical wire string and currently writes
  `missing:<name>` for an unknown key.
- `Validate.hs`: `hasNonInjectiveOptional` (1482 to 1499) classifies whether `Optional` wraps
  a null-capable value (`MappedNonInjectiveNullability`); `referencedDefaultType` (1424 to
  1478) types `on-missing` defaults; `mappedIdentityRules` and `mappedConflictRules` (1282 to
  1321) iterate mapped declarations only.
- `keiro-dsl/src/Keiro/Dsl/MappedCodecPlan.hs`: `MappedAuthorityMode` (24 to 29),
  `planMappedCodec`, `renderMappedEncode` (78 to 110), and `renderMappedParse` (112 to 136)
  choose encoder and decoder expressions; a missing key silently falls back to `toJSON` and
  `parseJSON`.
- `keiro-dsl/src/Keiro/Dsl/ConsumerTypePlan.hs`: renders the consumer-facing Haskell type,
  import requirements, and transitive mapped dependencies for a root.
- `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`: `emitShape` (2020 to 2075), `exprRequirements`
  (2097 to 2123), `renderShapeType` (2125 to 2151, unit `()` for a missing key),
  `renderMissingDefault` (6906 to 6919), the structural codec emitter (3704 to 3890) calling
  `encodeShapeExpr`/`decodeShapeExpr`, and the aggregate codec's nominal helpers
  `encodeNominalValue` (6903 to 6917) and `decodeNominalField` (6944 to 6980), which already
  encode a consumer-bound ID as `KindID.toText (nominalToRepresentation binding value)` and
  decode with `explicitParseField (withText ... parseXNominal)`.
- `keiro-dsl/src/Keiro/Dsl/ExplainBindings.hs`: lists binding, fixture, and initial
  obligations for both structural and nominal declarations (`obligationsFor`,
  `nominalObligationsFor` at 295 to 330) but computes nominal use sites from aggregate
  fields only (`useSites`, 351 to 372).
- `keiro-dsl/src/Keiro/Dsl/StructuralConformance.hs`: emits the per-context
  `StructuralConformance` module asserting binding laws, canonical identities, fixture
  branch coverage, and opaque round trips for every declaration in the service inventory.
- `keiro-dsl/src/Keiro/Dsl/Harness.hs`: `missingExpectedValue` (1591 to 1607) resolves a
  constructor default and otherwise writes `error "non-enum constructor default"` into
  generated source.
- `keiro-dsl/src/Keiro/Dsl/Coverage.hs`: builds the `keiro-dsl/coverage-report/1` JSON with
  structural, opaque, JSON, and snapshot boundary inventories and raises
  `CoverageOpaqueSurface` (Warning) for a persisted root containing an opaque boundary.
- `keiro-dsl/src/Keiro/Dsl/MappedDiff.hs`: `ExprView` (79 to 91) mirrors `ResolvedTypeExpr`
  and `diffExprViews` (394 to 433) classifies field type changes.
  `keiro-dsl/src/Keiro/Dsl/Diff.hs`: `nominalUses` (2420 to 2447) lists aggregate uses of a
  nominal for `IdPrefixChanged`, `NominalBindingChanged`, and related codes, and
  `nominalUseChange` (2498 to 2508) maps each use to a change context.
- `keiro-dsl/src/Keiro/Dsl/CodecCompare.hs`: builds a branch schema for historical codec
  comparison; `keiro-dsl/src/Keiro/Dsl/SemanticImpact.hs`: computes consumer closures over
  the graph; `keiro-dsl/src/Keiro/Dsl/RouterSelection.hs` and
  `keiro-dsl/src/Keiro/Dsl/Expression.hs`: resolve scalar paths into structural records.

*Language versions* live in `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`. Each version pairs a
syntax profile (`LanguageFeature` values such as `NominalBindingSyntax`) with a runtime
profile (`RuntimeCapability` values such as `GeneratedIdDomainTypeIdV7` and
`NominalEqualityV2`). Language 5 is the current stable published language; Language 6 (syntax
profile 5, runtime profile 5) is the unpublished candidate that plan 285 is hardening. The
module's comments state that published entries are immutable and the candidate may be
amended in place. `capabilityFoldSegment` (166 to 174) must decide for every capability
whether it contributes to the frozen fold fingerprint.

*ID admission* is defined once in `keiro-core/src/Keiro/Codec/IdDomain.hs`: `typeIdV7Domain
prefix`, `validateIdDomainText` (canonical parse, prefix equality, canonical round trip,
UUID-version-7 check), and `parseKindIdV7Text`. `keiro-dsl/src/Keiro/Dsl/IdDomain.hs` selects
the domain when the runtime profile has `GeneratedIdDomainTypeIdV7`, and
`enforcedIdDomainVersion` is the string `keiro-dsl/id-domain/typeid-v7/1`. Consumer-bound
IDs use `NominalBinding domain (KindID prefix)` from `Keiro.Codec.Nominal`.

The *conformance corpus* under `keiro-dsl/test/conformance-*/` holds compiled Cabal test
suites whose `Generated/` trees are produced by running the public `keiro-dsl scaffold` CLI on
a fixture. `keiro-dsl/test/README.md` documents the workflow, the driver
`keiro-dsl-corpus-regen` replays every scaffold from the committed ledgers, and
`scripts/check-conformance-corpus.sh` (part of `just verify`) fails if regeneration changes a
byte. The closest existing suites are `keiro-dsl-conformance-structural`
(`keiro-dsl/test/conformance-structural/`, fixture
`keiro-dsl/test/fixtures/structural-conformance.keiro`), `keiro-dsl-conformance-nominal-scalars`,
and `keiro-dsl-conformance-workspace-nominals` (fixture directory
`keiro-dsl/test/fixtures/workspace-nominals/`).

Typed workqueue payload rows (`field -> "key" : <expression>`) and read-model `query input`
and `query result` clauses are Language 5 consumer roots resolved through the same graph by
`resolveTypeExpression`; on 2026-09-16 both were verified to fail with the same
`MappedUnresolvedName` when typed by a declared `id`. Their generation paths are the
workqueue payload codec and the generated `QueryContract` aliases, exercised today by
`keiro-dsl-conformance-mapped-queue` (fixture `keiro-dsl/test/fixtures/mapped-workqueue.keiro`)
and `keiro-dsl-conformance-mapped-readmodel` (`mapped-readmodel.keiro`), both on published
Language 5 and therefore left untouched by this plan.

Relevant ADRs, all under `docs/adr/`:

- [ADR 12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
  fixes that a structural mapped type has one wire-schema authority (its `.keiro`
  declaration, executed by the generated codec), that bindings are total isomorphisms, that
  nominal bindings use `KindID prefix` for IDs with Keiro owning the admission domain, and that
  the wire fingerprint contains schema-authority facts only. This plan extends that authority
  to nominal leaves inside structural shapes without introducing a second one.
- [ADR 13](../adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md)
  makes coverage reporting-first, names opaque boundaries, and states that
  `--deny-warnings` escalates `CoverageOpaqueSurface`. A nominal leaf must count as structural
  so the consumer's strict gate passes without an exception.
- [ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) places each
  evolution check at the earliest boundary with enough evidence; nested prefix and binding
  changes must therefore surface in `diff`, not only at runtime.
- [ADR 18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md)
  requires new behaviour to be selected by explicit monotone capabilities with an explicit
  fold-segment decision, which is why the gate is a `RuntimeCapability`.
- [ADR 21](../adr/0021-direct-fields-have-independent-dsl-selector-and-wire-identities.md)
  applies to direct fields only and is unchanged; a nested nominal keeps its declaration name
  as identity.

No ADR yet records that nominal declarations are structural leaves; Milestone 4 writes one.
Prior plans this work extends: plan 149 delivered the type graph and structural checking,
plan 150 the generated shapes, codecs, and bindings, plan 151 `check --explain-bindings`
and binding skeletons, plan 152 coverage reporting and historical codec comparison,
plan 158 consumer-bound nominal declarations (`NominalType.hs`, `Keiro.Codec.Nominal`), and
plan 171 the enforced TypeID-v7 domain (`Keiro.Codec.IdDomain`, the
`GeneratedIdDomainTypeIdV7` capability). The owning request is IR-40; IR-1 (structural types),
IR-14 (enforceable ID domains), and IR-12 (nominal equality in expressions) are its related
requests. This plan is not part of MasterPlan 43 (the 0.17.0.0 release remediation); it lands
on the candidate Language 6 line after that release.


## Plan of Work

### Milestone 1: Resolve nominal leaves in the type graph and check them

Scope: after this milestone, `keiro-dsl check` accepts `id` and `mapped nominal` names as
leaves of structural type expressions at Language 6, rejects them with precise diagnostics
elsewhere, and every downstream module compiles with an explicit, conservative position on
the new leaf. No generated output changes yet.

In `keiro-dsl/src/Keiro/Dsl/TypeGraph.hs`, move `NominalScalarRepresentation` and
`ConsumerNominalBinding` here from `NominalType.hs` (re-export them from `NominalType.hs` so
existing importers keep compiling) and add the leaf vocabulary: `NominalLeafKind`
(`NominalIdLeaf prefix` or `NominalScalarLeaf representation`), `NominalLeafOwnership`
(`GeneratedLeaf` or `ConsumerLeaf ConsumerNominalBinding`), and `NominalLeaf` with `name`,
`kind`, `ownership`, and `loc`. Add `RNominal !NominalLeaf` to `ResolvedTypeExpr`, an
`onNominal :: NominalLeaf -> r` field to `TypeExprAlgebra`, and `SegNominal !Name` to
`PathSeg`. Add two fields to `TypeGraph`: `nominalLeaves :: Map Name NominalLeaf` and
`nominalReachability :: Map MappedKey (Set Name)` (the nominal names transitively reachable
from each mapped declaration).

Write pure checkers `checkIdLeaf :: IdDecl -> Either NominalLeafError NominalLeaf` and
`checkScalarLeaf :: NominalScalarDecl -> Either NominalLeafError NominalLeaf` that perform the
same ingredient checks `resolveNominalTypes` performs for IDs and scalars (prefix validity,
complete `using` block, supported representation name), and make `resolveNominalTypes` build
its `ResolvedNominalType` for those two kinds from these leaves so there is one authority.
`resolveTypeGraph` builds `nominalByName` from every well-formed leaf of `spec.ids` and
`spec.nominalScalars`; a malformed nominal is reported by `NominalType` and stays unresolved
in the graph. Change `resolveExpr` to take both maps and resolve `TRef name` as mapped key
first, then nominal leaf, then (for a name in `spec.enums`) the new error
`TGUnsupportedNominalLeaf owner name "enum" loc`, then `TGUnresolvedRef` as today.
`resolveTypeExpression` must use the graph's `nominalLeaves` so both entry points agree.

Set the conservative positions in the same module: `rootReference` returns `Nothing` for
`RNominal`; in `collectUseSites`, every consumer root (workqueue field, read-model query input or
result) whose resolved expression contains a nominal leaf is recorded in a new
`nominalRootSites` inventory on the graph, whether or not a mapped root is also present. To
do that without giving `UseSite` a second key, factor the root identity that its six
constructors currently repeat (root kind, owner, field) into a `RootRef` record, so a
`UseSite` pairs a `RootRef` with a `MappedKey` and a `NominalRootSite` pairs a `RootRef` with a
nominal name and its outer container segments; `siteKey` stays total; `refsInExpr` contributes nothing for a nominal
leaf, while a new `nominalRefsInExpr` populates `nominalReachability`; `pathsInExpr` ends a
path at `SegNominal name`, and a new `nominalUsePaths :: TypeGraph -> Name -> [UsePath]`
returns every root path reaching that nominal, whether through structural declarations or
directly from a nominal root site;
`renderUsePath` renders `SegNominal name` as `" : " <> name` exactly like `SegDecl` (names are
unambiguous because `ambiguityErrors` already forbids a nominal and a mapped declaration
sharing a spelling); `wireExpr` renders `nominal-id(<prefix>,keiro-dsl/id-domain/typeid-v7/1)`
or `nominal-scalar(<representation>)`. Replace the `missing:` fallback in `wireDecl` with an
`error` naming the invariant, since a checked graph never reaches it.

In `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`, add `StructuralNominalLeaves` to
`RuntimeCapability`, include it in the candidate runtime profile that Language 6 selects,
and return `Nothing` from `capabilityFoldSegment` with a comment saying that it changes
structural codecs, not transition semantics. The registry test that checks published profiles
are unchanged and successors are monotone must stay green without edits to Languages 1 to 5.

In `keiro-dsl/src/Keiro/Dsl/Validate.hs`, add the diagnostic codes
`MappedNominalLeafRequiresLanguage` and `MappedNominalLeafUnsupported`. In `validateMapped`,
when the effective language contract (obtain it the same way `nominalEqualityContractForService`
in `NominalType.hs` receives the checked service) lacks `StructuralNominalLeaves` and any
declaration contains an `RNominal`, emit `MappedNominalLeafRequiresLanguage` at each field or
arm location, naming the nominal and stating that candidate Language 6 is required. Render
`TGUnsupportedNominalLeaf` as `MappedNominalLeafUnsupported` with a message that names the
category (`enum`). In `typeGraphDiagnostic`, when a
`TGUnresolvedRef` names a declared but malformed nominal, say so in the message. Set
`hasNonInjectiveOptional`'s `onNominal` to non-null, so `Optional TemplateId` is legal, and make
`referencedDefaultType` return a `DefaultNominal` that matches no literal, so a bare nominal
field with `optional on-missing=<literal>` fails `MappedDefaultIllTyped` with a message
telling the author to write `Optional X optional on-missing=null`. Leave `mappedIdentityRules`
and `mappedConflictRules` unchanged.

Give every other algebra site a compiling, conservative arm now, to be refined in later
milestones: `MappedDiff.exprView` (`ExprNominal name`), `Coverage` folds (nominal leaf is
neither opaque nor JSON), `MappedCodecPlan` (`NominalAuthority name`, and encoder/parser
arms that call the helpers Milestone 2 will emit), `ConsumerTypePlan`, `Scaffold`
(`exprRequirements`, `renderShapeType`, `renderMissingDefault`, the projection lookups near
lines 2201, 2216, 2253, and 7273 return no witness), `ExplainBindings.renderExprType` (the
nominal name), `RouterSelection` (a nominal leaf is not a selectable scalar; reuse the
existing "must be a mapped structural record" message), `Expression.hs` line 434
(`ScalarPathInvalid` for a path into a nominal leaf), and `Harness.missingExpectedValue`
(unreachable for a checked graph; replace the generated-source `error` with a generator-side
invariant failure).

Fixtures under `keiro-dsl/test/fixtures/`: `mapped-nominal-leaf.keiro` (Language 6, a
generated ID, a consumer-bound ID, and a nominal scalar used as a record field, a union arm
payload, `Optional`, `List (Optional ...)`, and `Map` values, plus a workqueue payload row
`: Optional TemplateId` and a read model with `query result = List TemplateId`, all of which
must check `OK`),
`mapped-nominal-leaf-language.keiro` (the same at `language keiro-dsl 5`, expecting
`MappedNominalLeafRequiresLanguage`), `mapped-nominal-leaf-enum.keiro` (an `enum` used as a
leaf, expecting `MappedNominalLeafUnsupported`), and
`mapped-nominal-leaf-default.keiro` (a bare nominal field with a literal `on-missing`,
expecting `MappedDefaultIllTyped`). Register the negative fixtures in the stable
diagnostic-code table in `keiro-dsl/test/Main.hs` (around lines 4367 to 4394) and add
`parse`/`pretty` round-trip and `check --emit` cases for the positive one.

Acceptance: the IR-40 reproduction from the Purpose section prints `OK` at Language 6 and the
language diagnostic at Language 5; each negative fixture prints exactly its expected code;
`cabal build all` and `cabal test keiro-dsl:test:keiro-dsl-test` pass; the conformance corpus
check still passes because no generated byte changed.

### Milestone 2: Generate shapes, codecs, bindings, and conformance for nominal leaves

Scope: after this milestone, `keiro-dsl scaffold` produces compiling Haskell for a
specification with nominal leaves, the generated codecs apply Keiro's admission at every
nesting level, `check --explain-bindings` names structural use sites of a nominal, and a new
compiled conformance suite proves round trips, negative decoding with located errors, and
that bypassing admission turns the suite red.

In `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, make `renderShapeType`'s `onNominal` render the
nominal domain type: for `GeneratedLeaf` the generated nominal module's type (the same
reference `aggregateConsumerHaskellSource` in `AggregateType.hs` produces for a direct
field), and for `ConsumerLeaf` the `haskell` target of the binding. `exprRequirements` adds
the matching `HaskellReference` so `planHaskellImports` (in `HaskellImport.hs`) never reports
`MissingHaskellReference`. Emit a new generated module per context,
`<ContextPrefix>.Structural.NominalLeaves` (module-role family `NominalLeaves`, owner kind
`context`, recorded in the scaffold ledger like `StructuralConformance`), only when
`nominalReachability` is non-empty. For every nominal name reachable from a structural
declaration it defines `encode<X>Leaf :: X -> Value` and `parse<X>Leaf :: Value -> Parser X`.
For a generated ID these call the public `parse<X>`/`<x>Text` that
`emitGeneratedNominalInternals` already exports; for a consumer-bound ID they encode with
`KindID.toText (nominalToRepresentation <binding> value)` and decode with `withText`,
`parseKindIdV7Text (typeIdV7Domain "<prefix>")`, then `nominalFromRepresentation <binding>`,
mirroring `decodeNominalField`; for a nominal scalar they apply the binding around the
representation's existing JSON policy (`Time` uses the same policy as direct `Time` fields).
Leave `encodeNominalValue` and `decodeNominalField` untouched so existing corpora do not churn.

In `keiro-dsl/src/Keiro/Dsl/MappedCodecPlan.hs`, `renderMappedEncode` and `renderMappedParse`
render `encode<X>Leaf`/`parse<X>Leaf` for `RNominal`, and `planMappedCodec` records the
import of the `NominalLeaves` module. Replace the silent `toJSON`/`parseJSON` fallbacks for a
missing mapped key with an invariant failure. Ensure the parser for a record field attaches
the JSON key context and that `List` and `Map` parsers attach index and key contexts, so a
rejected leaf reports a path such as `$.templates[1].templateId`; if the current container
renderers lack those contexts, add them for all leaves, because the message text is part of
this milestone's acceptance.

In `keiro-dsl/src/Keiro/Dsl/ConsumerTypePlan.hs`, `planConsumerType` renders the nominal
domain type, adds its `ImportRequirement`, and records nominal dependencies so aggregate
harnesses import consumer nominal fixture symbols for nominals reached through structural
records. The workqueue payload codec emitter and the read-model `QueryContract` alias emitter
already obtain their field expressions through these two plans; confirm that a nominal root
site makes the queue codec import the `NominalLeaves` module and the query aliases import the
nominal type modules. In `keiro-dsl/src/Keiro/Dsl/SemanticImpact.hs`, include nominal names from
`nominalReachability` in each consumer's declaration closure, so the ledger's
`semantic-impact` rows name them and scaffold locality regenerates the `NominalLeaves`
module and the consumers that reach a changed nominal. In `ExplainBindings.hs`, compute a
nominal's use sites from both the existing aggregate list and `nominalUsePaths`, and keep
nominal leaves out of `holesFor` (they are checked leaves, not holes). The structural binding
skeleton from `renderBinding` needs no new fields, but its imports must include the nominal
types that appear in the shape.

In `keiro-dsl/src/Keiro/Dsl/StructuralConformance.hs`, add nominal-leaf assertions to the
inventory: for every consumer-bound nominal reachable from a structural declaration, assert
the two `NominalBinding` laws and the canonical-type equality over its `NominalFixtureCases`
(reuse the assertion the aggregate harness generates for a direct consumer-bound field; find
it in `Harness.hs` rather than writing a second law), and for every generated ID leaf assert
that each structural fixture containing it re-encodes to canonical TypeID text. Import the
nominal modules through `conformanceImportPlan`.

Add the fixture `keiro-dsl/test/fixtures/structural-nominal-leaves.keiro` (Language 6,
context `structural-nominal-leaves`) declaring a generated `id TemplateId prefix=template`, a
consumer-bound `id ClaimId prefix=claim using { ... }`, a `mapped nominal AccountNumber :
Text { ... }`, a record `TemplateState` with fields `templateId : TemplateId required`,
`holder : Optional ClaimId optional on-missing=null`, and `account : AccountNumber required`,
a union `TemplateRef` with arms `ById : TemplateId`, `ByAccount : AccountNumber`, and a
payload-less `Unknown`, a record `TemplateBook` with `templates : List TemplateState`,
`holders : List (Optional ClaimId)`, and `byKey : Map TemplateId`, and an aggregate with a
register `book TemplateBook = initial`, snapshots enabled, and commands and events carrying
`TemplateState` and `TemplateRef`. Add a workqueue `template_work` whose payload has
`templateId -> "template_id" : TemplateId` and `holder -> "holder" : Optional ClaimId`, and a
read model with `query input = TemplateState` and `query result = List TemplateId`. Scaffold it once into
`keiro-dsl/test/conformance-structural-nominals/`, fill the create-once
`Conformance/StructuralNominals/Bindings.hs` and `Domain.hs` (consumer types with a `ClaimId`
newtype over `KindID "claim"` and an `AccountNumber` newtype over `Text`), force-add the
ledger and Cabal fragment, add the `keiro-dsl-conformance-structural-nominals` test-suite
stanza to `keiro-dsl/keiro-dsl.cabal` next to `keiro-dsl-conformance-structural`, and write
`Main.hs` to assert: every `structuralConformanceAssertions` entry is true; an event payload
containing all three leaf kinds round-trips through the generated codec with canonical
TypeID text; a snapshot of a `TemplateBook` holding two `TemplateState` values round-trips
and replay reproduces it; decoding rejects a `claim_` prefix where `template_` is expected, a
non-canonical suffix, a UUID whose version nibble is not 7, and JSON `null` where an ID is
required, with each error message containing the field path; and `holder` distinguishes
`null` from a present ID. A queued payload round-trips through the generated queue codec with
TypeID text and a wrong prefix is rejected at `$.template_id`; the generated `QueryContract`
aliases are asserted at the type level to equal `TemplateState` and `[TemplateId]`. Add `keiro-dsl/test/structural-nominal-mutation-test.sh`, modelled
on `keiro-dsl/test/structural-mutation-test.sh`, that rewrites the generated
`parseTemplateIdLeaf` to accept any text and asserts the suite fails, then restores the file.

Acceptance: `cabal test keiro-dsl:test:keiro-dsl-conformance-structural-nominals` passes;
the mutation script exits non-zero on the mutated tree and zero after restore;
`cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/structural-nominal-leaves.keiro
--explain-bindings` lists `TemplateState`, `TemplateRef`, `TemplateBook`, `ClaimId`, and
`AccountNumber` obligations, with `ClaimId`'s use sites including the structural paths and the queue payload row;
`scripts/check-conformance-corpus.sh` passes from a clean tree.

### Milestone 3: Coverage, semantic diff, and compatibility for nested nominals

Scope: after this milestone, the coverage report and the strict production gate treat nominal
leaves as structural, `diff` reports nested prefix, binding, and representation changes at
every affected persisted path, snapshot invalidation follows nested IDs, and the historical
codec comparison can prove parity for the opaque-to-nominal migration.

In `keiro-dsl/src/Keiro/Dsl/Coverage.hs`, add a `nominalBoundaries` inventory to the report
(each row: `path`, `root`, `nominal`, `kind` as `id` or `scalar`, `prefix` and
`domainVersion` for IDs, `canonicalType` and `ownership` for consumer-bound leaves) computed
from `nominalUsePaths` filtered by `isWireSite`, which includes nominal root sites at workqueue
payload rows; leave `structuralRoots`, `opaqueRoots`, and
`jsonBoundaries` semantics unchanged so a root that contains only nominal leaves is a
structural root with no opaque boundary. Keep the schema tag `keiro-dsl/coverage-report/1`;
the addition is a new array that old readers ignore. Confirm `snapshotBoundaryInventory`
picks up the new wire token by diffing `structural-nominal-leaves.keiro` against a
`-prefix-change` mutant and observing register snapshot invalidation.

In `keiro-dsl/src/Keiro/Dsl/MappedDiff.hs`, give `ExprView` an `ExprNominal !Name` arm; two
nominal views with equal names are equal, and any other pairing involving a nominal is
`MappedFieldTypeChanged`. In `keiro-dsl/src/Keiro/Dsl/Diff.hs`, extend `NominalUse` with a
structural use carrying the declaration name and the root path, populate it from
`nominalUsePaths` on both graphs in `nominalUses`, and map it in `nominalUseChange` to
`ContextPrivateEvent` for event roots, the context the mapped-declaration diff already assigns
to a workqueue payload root, `ContextSnapshot` for register roots, and `ContextConsumerBuild`
for command and read-model query roots, so `IdPrefixChanged`,
`NominalBindingChanged`, `NominalFixturesChanged`, `NominalCanonicalTypeChanged`,
`NominalInitialChanged`, `NominalRepresentationChanged`, and `IdDomainContractChanged` carry
the nested paths in their contexts and `--explain` output. In
`keiro-dsl/src/Keiro/Dsl/CodecCompare.hs`, add the nominal leaf to the branch schema as a
scalar leaf with its declared domain, and add an `extra-args` manifest row for the new corpus
with `--codec-comparison TemplateState` so the comparison module compiles.

Add mutants beside the fixture: `structural-nominal-leaves-prefix-change.keiro` (`TemplateId`
prefix becomes `tmpl`), `-binding-change.keiro` (`ClaimId` binding-version `2`),
`-text-to-nominal.keiro` (baseline field `Text`, mutant `TemplateId`), and
`-opaque-to-nominal.keiro` (baseline uses a `mapped opaque TemplateIdValue` twin in the
field, mutant uses `TemplateId`). Add expectations to `keiro-dsl/test/Main.hs` and
`keiro-dsl/test/diff-test.sh` and extend the compatibility-vector golden for the new
contexts.

Acceptance: `cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/structural-nominal-leaves.keiro
--deny-warnings --coverage-report /tmp/cov.json --fail-on-opaque` exits 0 and the report has
`opaqueRoots` 0 with three or more `nominalBoundaries`, one of them the workqueue payload row; `diff` between the fixture and the
prefix mutant reports `IdPrefixChanged` with a private-event context for the `TemplateState`
event path and a snapshot context for the `book` register; the binding mutant reports
`NominalBindingChanged` on the same paths; the two type-change mutants report
`MappedFieldTypeChanged`; all suites pass.

### Milestone 4: Workspace composition, documentation, changelog, and request closure

Scope: after this milestone, a shared consumer-bound ID owned by one workspace member is
usable in another member's structural record, regeneration is deterministic, the user
documentation and changelog describe the capability and the migration from the opaque
workaround, an ADR records the decision, and IR-40 is closed.

Extend `keiro-dsl/test/fixtures/workspace-nominals/` so that a structural record in each of the
two member specs references the shared consumer-bound ID, regenerate the
`keiro-dsl-conformance-workspace-nominals` corpus, and assert in its `Main.hs` that both
generated `NominalLeaves` modules import the single nominal owner module and that values pass
between the two members' records with one `ClaimId` type (a duplicate declaration would fail
to compile). Run `cabal run -v0 keiro-dsl-corpus-regen -- check` twice to prove byte
stability.

Update `docs/user/typed-spec-toolchain.md`: in `### Mapped type expressions` add the declared
`id` and `mapped nominal` leaves with the Language 6 requirement and the enum exclusion; in
`### Structural records` show a field typed by an ID and an `Optional ClaimId optional
on-missing=null` field; in `### Consumer-owned nominal declarations` note nested use; in
`### Structural binding obligations` describe the `NominalLeaves` module and the nominal-law
assertions; in `### check` document `nominalBoundaries`; in `### diff` document structural
contexts on nominal findings; and add `### Migrating from an opaque ID workaround` describing
the pattern the consumer uses today (a `mapped opaque` twin of a bound ID plus an opaque
option wrapper), the replacement, the `MappedFieldTypeChanged` classification, and the
historical codec comparison as parity evidence, deferring to the rules already stated in
`docs/user/codecs-and-event-evolution.md` for what parity permits. Update that file's
`## Structural Consumer-Owned Payloads` and `docs/user/mapped-consumer-adoption.md`'s
`## Act On A Mapped Change` for nominal consequences. Advance each edited document's OKF
`timestamp` and record the change with `okf log add` in `docs/user/`.

Add to `keiro-dsl/CHANGELOG.md` under `[Unreleased]`: a New Features entry that candidate
Language 6 accepts `id` and `mapped nominal` declarations as structural leaves with the
`StructuralNominalLeaves` capability, and Other Changes entries for `nominalBoundaries` in
the coverage report and structural contexts on nominal diff findings. Allocate a new ADR with
`okf id next docs/adr --profile docs/adr/profile.dhall ADR` titled "Nominal declarations are
structural leaves with Keiro-owned admission", recording the leaf representation, the domain
type inside shapes, the wire token, the enum and consumer-root exclusions, and the migration
classification; add a one-line pointer under ADR 12's related decisions with a timestamp
advance and `okf log add`. Set IR-40's frontmatter `status` to `in-progress` when Milestone 1
starts and to `completed` with `completedAt` and a `resolution` line when this milestone ends,
update its `## Status` section, and add `docs/improvement-requests/log.md` entries.

Acceptance: `just verify` passes, which covers the Haskell build and all test suites, the
ADR, research, user-documentation, and reviews bundle validations, the extension and naming
policies, and the conformance-corpus check.


## Concrete Steps

Run everything from the repository root. The repository's development shell is
`nix develop`; prefix commands with `nix develop -c` if `cabal` is not already on the path.

Build the CLI and run the reproduction before any change to record the baseline:

```bash
cabal build keiro-dsl:exe:keiro-dsl
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/mapped-nominal-leaf.keiro
```

Expected before Milestone 1 (the fixture does not exist yet; use the IR-40 reproduction
saved as a scratch file):

```text
nested-id.keiro:13: error[MappedUnresolvedName]: mapped declaration 'TemplateState' references unresolved mapped type 'TemplateId'
nested-id.keiro:20: error[AggregateTypeUnknown]: unknown aggregate type 'TemplateState' at command field
```

After Milestone 1:

```bash
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/mapped-nominal-leaf.keiro
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/mapped-nominal-leaf-language.keiro
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/mapped-nominal-leaf-enum.keiro
cabal test keiro-dsl:test:keiro-dsl-test
```

```text
OK
mapped-nominal-leaf-language.keiro:13: error[MappedNominalLeafRequiresLanguage]: mapped declaration 'TemplateState' field 'templateId' uses nominal 'TemplateId'; nominal leaves require candidate language 6
mapped-nominal-leaf-enum.keiro:14: error[MappedNominalLeafUnsupported]: mapped declaration 'TemplateState' field 'kind' uses enum 'TemplateKind'; nominal enums are not supported as structural leaves, declare a mapped structural enum instead
```

Milestone 2, scaffold the new corpus once and register it:

```bash
cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/structural-nominal-leaves.keiro \
  --out keiro-dsl/test/conformance-structural-nominals
git add -f keiro-dsl/test/conformance-structural-nominals/keiro-dsl-ledger.*.txt \
  keiro-dsl/test/conformance-structural-nominals/keiro-dsl-cabal-fragment.*.txt
cabal test keiro-dsl:test:keiro-dsl-conformance-structural-nominals
keiro-dsl/test/structural-nominal-mutation-test.sh
cabal run -v0 keiro-dsl-corpus-regen -- regenerate --only keiro-dsl/test/conformance-structural-nominals
git status --short keiro-dsl/test/conformance-structural-nominals
```

The last command must print nothing after a committed baseline. The exact scaffold flags the
existing structural corpus used are recorded in
`keiro-dsl/test/conformance-structural/keiro-dsl-ledger.context.structural-conformance.txt`
(layout `prefixed`, no module root); copy them.

Milestone 3, the strict gate and the diff classifications:

```bash
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/structural-nominal-leaves.keiro \
  --deny-warnings --coverage-report /tmp/structural-nominal-coverage.json --fail-on-opaque
cabal run -v0 keiro-dsl -- diff keiro-dsl/test/fixtures/structural-nominal-leaves.keiro \
  keiro-dsl/test/fixtures/structural-nominal-leaves-prefix-change.keiro --explain
keiro-dsl/test/diff-test.sh
```

Expected: the first command exits 0 and prints the coverage summary with
`private-event-payloads: ... (N structural, 0 opaque, 0 Json boundaries)`; the second lists
`IdPrefixChanged` with contexts naming `TemplateState` event paths and the `book` register.
Check the `diff` invocation form against `cabal run -v0 keiro-dsl -- diff --help` and the
`### diff` section of `docs/user/typed-spec-toolchain.md`, which is authoritative.

Milestone 4, the full gate:

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
okf validate docs/improvement-requests --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
just verify
```

Every commit while implementing this plan carries the trailers:

```text
ExecPlan: docs/plans/287-support-nominal-ids-inside-structural-mapped-types.md
Intention: intention_01m2p79tjte5ftry3pdmgbqtjw
```


## Validation and Acceptance

The plan is complete when all of the following are observable.

The specification in the Purpose section, saved to a file, prints `OK` from
`keiro-dsl check` at Language 6, and the same file at Language 5 prints
`MappedNominalLeafRequiresLanguage`. A copy that uses an `enum` as a leaf prints
`MappedNominalLeafUnsupported`.

`cabal test keiro-dsl:test:keiro-dsl-conformance-structural-nominals` passes, proving that a
register holding `List TemplateState` survives snapshot and replay, that union arms,
`Optional ClaimId`, `List (Optional ClaimId)`, and `Map TemplateId` values round-trip with
canonical TypeID text, and that decoding rejects a wrong prefix, malformed or non-canonical
text, a non-version-7 UUID, and JSON `null` where an ID is required, each with a message that
names the nested location. `keiro-dsl/test/structural-nominal-mutation-test.sh` fails the
suite when admission is bypassed, which is the evidence that no arbitrary consumer JSON
instance can weaken the contract.

The check with `--deny-warnings --coverage-report ... --fail-on-opaque` on the fixture exits
0, and the report lists the nominal leaves under `nominalBoundaries` with zero opaque roots.
This is the consumer's production gate shape from IR-40 passing without an exception.

The same fixture's workqueue payload row and read-model query pair check, scaffold, and
compile; the queue codec round-trips TypeID text and rejects a wrong prefix at the payload
path.

`keiro-dsl diff` classifies the prefix, binding-version, text-to-nominal, and
opaque-to-nominal mutants as described in Milestone 3, with contexts naming the nested paths,
and the compatibility-vector golden matches.

The workspace corpus compiles with one `ClaimId` owner reachable from two members'
structural records, and `cabal run -v0 keiro-dsl-corpus-regen -- check` reports no drift on
two consecutive runs.

`just verify` passes, IR-40 reads `completed`, and the new ADR validates strictly.


## Idempotence and Recovery

All fixture, test, documentation, and changelog additions are additive and can be re-applied.
The corpus driver refuses to run over a dirty corpus directory; discard a broken regeneration
with `git checkout -- keiro-dsl/test/conformance-structural-nominals` and re-run. Never pass
a force-overwrite flag to `scaffold` in a corpus directory, and never hand-edit a generated
module to make regeneration pass; fix the generator or the fixture. `--allow-dirty` is for
local iteration only.

Because the capability is gated on the unpublished candidate Language 6, no published
language changes behaviour and no existing generated corpus changes bytes until a fixture
opts in; if `scripts/check-conformance-corpus.sh` reports drift in a corpus other than the
new ones, that is a regression to fix, not a golden to accept. Moving
`NominalScalarRepresentation` and `ConsumerNominalBinding` between modules is safe as long as
`NominalType.hs` re-exports them; if an external package imported them from `NominalType`,
the re-export preserves the import.

If the `NominalLeaves` module design proves unworkable (for example an import cycle between a
generated nominal module and a structural shape module), the recorded fallback is to emit the
leaf helpers into each structural shape module that needs them; record the change in the
Decision Log before switching.


## Interfaces and Dependencies

`keiro-dsl/src/Keiro/Dsl/TypeGraph.hs` must export, in addition to today's surface:

```haskell
data NominalScalarRepresentation = NominalText | NominalInt | NominalNatural | NominalBool | NominalTime

data ConsumerNominalBinding = ConsumerNominalBinding
  { haskell :: !HaskellSource
  , binding :: !QualifiedValueName
  , bindingVersion :: !BindingVersion
  , canonical :: !CanonicalTypeId
  , fixtures :: !QualifiedValueName
  , initial :: !(Maybe QualifiedValueName)
  }

data NominalLeafKind = NominalIdLeaf !Text | NominalScalarLeaf !NominalScalarRepresentation
data NominalLeafOwnership = GeneratedLeaf | ConsumerLeaf !ConsumerNominalBinding
data NominalLeaf = NominalLeaf { name :: !Name, kind :: !NominalLeafKind, ownership :: !NominalLeafOwnership, loc :: !Loc }

data ResolvedTypeExpr = RText | RInt | RInteger | RBool | RNatural | RTime | RJson
  | ROptional !ResolvedTypeExpr | RList !ResolvedTypeExpr | RMap !ResolvedTypeExpr
  | RRef !MappedKey | RNominal !NominalLeaf

data PathSeg = {- existing segments -} | SegNominal !Name

data TypeGraphError = {- existing -} | TGUnsupportedNominalLeaf !Name !Name !Text !Loc

data RootRef = {- the root kind, owner, and field identity currently repeated across the UseSite constructors -}
data NominalRootSite = NominalRootSite { root :: !RootRef, nominal :: !Name, segments :: ![PathSeg] }

checkIdLeaf :: IdDecl -> Either NominalLeafError NominalLeaf
checkScalarLeaf :: NominalScalarDecl -> Either NominalLeafError NominalLeaf
nominalUsePaths :: TypeGraph -> Name -> [UsePath]
-- TypeGraph gains: nominalLeaves :: Map Name NominalLeaf, nominalReachability :: Map MappedKey (Set Name),
--                  nominalRootSites :: [NominalRootSite]
-- TypeExprAlgebra gains: onNominal :: NominalLeaf -> r
```

`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` adds `StructuralNominalLeaves` to
`RuntimeCapability`, present in the runtime profile that candidate Language 6 selects and in
no published profile. `keiro-dsl/src/Keiro/Dsl/Validate.hs` adds the codes
`MappedNominalLeafRequiresLanguage` and `MappedNominalLeafUnsupported` to the stable
diagnostic-code type. `keiro-dsl/src/Keiro/Dsl/MappedCodecPlan.hs` adds
`NominalAuthority !Name` to `MappedAuthorityMode`. `keiro-dsl/src/Keiro/Dsl/MappedDiff.hs`
adds `ExprNominal !Name` to `ExprView`. `keiro-dsl/src/Keiro/Dsl/Coverage.hs` adds a
`NominalBoundary` record and a `nominalBoundaries` field to the report.

Each generated `<ContextPrefix>.Structural.NominalLeaves` module exports, per reachable
nominal `X`:

```haskell
encodeXLeaf :: X -> Data.Aeson.Value
parseXLeaf :: Data.Aeson.Value -> Data.Aeson.Types.Parser X
```

Runtime dependencies are already in `keiro-dsl`'s and the generated code's build-depends:
`aeson` for `Value`, `Parser`, `withText`, and `explicitParseField`; `mmzk-typeid` for
`KindID` and `toText`; `keiro-core`'s `Keiro.Codec.IdDomain` (`typeIdV7Domain`,
`parseKindIdV7Text`, `validateIdDomainText`), `Keiro.Codec.Nominal` (`NominalBinding`,
`nominalToRepresentation`, `nominalFromRepresentation`), and `Keiro.Codec.Structural`
(`StructuralBinding`, `bindingToShape`, `bindingFromShape`). No new package dependency is
introduced.


## Revision Notes

- 2026-09-17: Widened the scope to accept nominal leaves at workqueue payload rows and read-model
  query expressions after verifying that both fail with the same `MappedUnresolvedName` as
  records. Replaced the consumer-root rejection with a nominal root-site inventory (and the
  `RootRef` factoring of `UseSite`), dropped the `mapped-nominal-leaf-root.keiro` negative
  fixture, extended the corpus, coverage, diff contexts, and acceptance accordingly, and
  superseded the corresponding Decision Log entry. The remaining gaps (nested enums, contract
  references to declared IDs, expressions and router selection over nested nominals, and the
  direct optional-ID diagnostic) are planned in `docs/plans/288-complete-nominal-id-support-across-contracts-expressions-nested-enums-and-direct-optional-fields.md`.
