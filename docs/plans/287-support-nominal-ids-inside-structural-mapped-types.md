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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-17T13:21:18Z
      mode: "update"
      note: "Correct root-only nominal support, snapshot fingerprints, diff routing, qualification reuse, and validation commands"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-17T13:54:12Z
      mode: "update"
      note: "Final value and release assessment; prioritize nominal composition and distinguish candidate implementation from production closure"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-17T13:22:03Z
      verdict: "changes-requested"
      note: "Original plan omitted root-only gating/emission, actual nested snapshot fingerprints, and independent diff producers; findings applied in this update"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-17T13:55:00Z
      verdict: "comments"
      note: "Final value/release assessment recommends Plan 287 first; reproduced existing refusal; runtime and publication gates remain pending"
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


### Release recommendation (2026-09-17)


Implement this plan first, through Milestone 4. It removes an observed consumer blocker
while preserving the DSL's existing nominal types, total bindings, admission policy, and
structural coverage. Queue/query roots belong in the same delivery because they use the
same resolver and otherwise immediately recreate the composition gap. This is a substantial
compiler change, so checker acceptance alone is insufficient: codec rejection tests,
snapshot invalidation, exact impact locality, and workspace compilation are release gates.

Do not make this feature a new prerequisite for the already scoped 0.17.0.0 remediation in
[MasterPlan 43](../masterplans/43-address-the-rev-17-keiro-0-17-0-0-release-readiness-findings.md).
Target the next feature release after that remediation. Package delivery and language
publication are separate: code delivered while Language 6 remains `Candidate` is preview
support. Claiming that IR-40's production need is delivered also requires a supported
published language containing this capability and consumer migration/replay evidence.
[Plan 285](285-harden-the-language-6-reaction-candidate-before-it-is-published.md) remains a
prerequisite to publishing Language 6. If Language 6 publishes before implementation,
allocate a successor capability/profile instead of editing its published entry.

Plan 288 is useful follow-through, not a prerequisite to this plan. Its nested enums,
declared contract IDs, and required-path expression support improve consistency; its keyed
maps are a separate expansion and should not delay this delivery.

## Progress


- [x] 2026-09-17: Final value/release assessment; reproduced the current nested-ID refusal and separated feature completion from production-language publication.
- [x] 2026-09-17: Review graph, generator, diff, fingerprints, and completed Plan 228;
      revise missing paths and validation instructions.
- [ ] M1–M3. Qualify isolated queue/query roots, nested binding fingerprint changes,
      and exact consumer locality with Plan 228's existing infrastructure.
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


- Final assessment, 2026-09-17: The existing built CLI still rejects the Purpose example
  with `MappedUnresolvedName` at line 13 and `AggregateTypeUnknown` at line 20 (exit 1).
  MasterPlan 43 explicitly excludes Language 6 publication; a package release alone cannot
  establish supported production availability for this candidate-only feature.
- Correctness review, 2026-09-17: `UsePath.root` requires a mapped-key-bearing `UseSite`,
  and `SemanticImpact` inventories are keyed by `MappedKey`. Direct queue/query nominal
  roots need a common key-free root identity and separate nominal dependency inventories.
- Correctness review, 2026-09-17: `FoldFingerprint.mappedRegisterSegment` includes the
  root mapped binding and recursive wire shape, but `nominalUseNames` only sees direct
  nominal fields. Nested binding changes require explicit fingerprint propagation.
- Correctness review, 2026-09-17: `Diff.idPairDiff`, `nominalScalarDiff`, and the ID-domain
  pass in `diffServices` emit declaration findings independently of `nominalUses`.
  Extending that function alone cannot produce the promised path-specific findings.


## Decision Log


- Decision: Recommend full Plan 287 delivery before Plan 288, without adding it to the
  existing 0.17.0.0 tag prerequisites. Track production publication separately from
  implementation completion and keep IR-40 open until its release evidence exists.
  Rationale: The consumer blocker is concrete; candidate availability alone does not meet
  the request for a supported strict production specification.
  Date: 2026-09-17
- Decision: Reuse the completed Plan 228 qualification infrastructure for nominal roots,
  retaining queue/query support here as assumed by Plan 288. Add isolated roots with no
  structural declarations to expose missing language gates, helpers, and dependency facts.
  Rationale: Plan 228 delivered mapped queue/query support and cross-surface qualification;
  it did not add nominal leaves. Plan 288 explicitly builds on this plan for those leaves.
  Date: 2026-09-17
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


Correctness review and plan revision completed on 2026-09-17. Implementation has not
started. The milestones now address direct-root completeness, actual snapshot identity,
all nominal diff producers, and reuse of the existing cross-surface qualification gates.
Runtime acceptance remains to be demonstrated during implementation. The final value assessment
recommends implementation first in the next feature cycle; it does not approve a release or
claim that candidate Language 6 is production-supported.


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

[Plan 228](228-qualify-the-complete-mapped-consumer-surface-before-fleet-adoption.md)
completed mapped queue/query/projection qualification. Reuse
the `MappedSurfaceQualification` helper and `mapped surface qualification` group in
`keiro-dsl/test/Main.hs`,
`keiro-dsl/test/mapped-surface-locality-test.sh`, and
`keiro-dsl/test/mapped-surface-mutation-test.sh` to extend its exact consumer, consequence,
and generated-file locality checks to nominal leaves. Queue envelopes stay at version 1;
query aliases remain Haskell APIs with no generated JSON or SQL contract. Plan 288 assumes
this plan delivers nominal queue/query roots and adds the remaining nominal features.
The 2026-09-17 review of Plan 228 found stale mutation substitutions and growth coverage
limited to one event mapping. When extending these tests, require every mutation to change
its intended source exactly once and fail for the expected reason, and repeat the complete
nominal edit matrix after unrelated growth. Do not rely on Plan 228's completed label as
evidence that the current mutation script is healthy.


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
`nominalRootSites` inventory on the graph for direct nominal roots with outer containers;
paths through mapped declarations come from mapped use sites without duplication. To
do that without giving `UseSite` a second key, factor the root identity that its six
constructors currently repeat (root kind, owner, field) into a `RootRef` record, so a
`UseSite` pairs a `RootRef` with a `MappedKey` and a `NominalRootSite` pairs a `RootRef` with a
nominal name and its outer container segments; `siteKey` stays total; `refsInExpr` contributes nothing for a nominal
leaf, while a new `nominalRefsInExpr` populates `nominalReachability`; `pathsInExpr` ends a
path at `SegNominal name`, and a new `nominalUsePaths :: TypeGraph -> Name -> [UsePath]`
returns every root path reaching that nominal, whether through structural declarations or
directly from a nominal root site;
change `UsePath.root` to the key-free `RootRef` too and migrate its consumers. Never invent
a mapped key for a nominal to satisfy the old path type.
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
thread `EffectiveLanguageContract` from `validateWithAnalysis` into `validateMapped`.
When it lacks `StructuralNominalLeaves`, inspect structural declarations and direct typed
queue/query expressions for `RNominal`, emitting `MappedNominalLeafRequiresLanguage` at
each field, arm, or query-clause location. Existing direct aggregate nominal fields retain
their current language contract. Render
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

Add queue-only and query-only positive fixtures without mapped declarations, plus
Language 5 copies expecting `MappedNominalLeafRequiresLanguage`. Repeat the unsupported
enum case at these roots so both resolution entry points retain the precise diagnostic.

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
`context`, recorded in the scaffold ledger like `StructuralConformance`). Emit it when the
union of nominals reachable from structural declarations and direct queue roots is
non-empty. Queue-only specs must receive helpers; query-only roots need nominal type
imports but no JSON helpers. For every name in that union it defines
`encode<X>Leaf :: X -> Value` and `parse<X>Leaf :: Value -> Parser X`.
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
`nominalReachability` and direct root sites in separate nominal closures, identities,
evidence, and consequences keyed by `Name`. Existing mapped inventories remain keyed by
real `MappedKey` values. Add `nominalDependencies :: Set Name` to `ConsumerTypePlan` and
thread context/workspace ownership into generated nominal type/import planning. Persist
nominal impact as additive fields/rows, treating absent historical nominal evidence as
unavailable rather than empty. Update service conformance's exact impact inventory and
derived event-projection consequences. Verify exact locality for queue-only, query-only,
and shared nominal edits, including unrelated consumer growth, with Plan 228's machinery.
In `ExplainBindings.hs`, compute a
nominal's use sites from both the existing aggregate list and `nominalUsePaths`, and keep
nominal leaves out of `holesFor` (they are checked leaves, not holes). The structural binding
skeleton from `renderBinding` needs no new fields, but its imports must include the nominal
types that appear in the shape.

In `keiro-dsl/src/Keiro/Dsl/StructuralConformance.hs`, add nominal-leaf assertions to the
inventory: for every consumer-bound nominal reached through a structural declaration or
direct queue/query root, assert
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
`parseTemplateIdLeaf` to return a known valid fixture ID for any text and asserts the
negative-admission test fails, then restores the file. The mutation must compile despite
the generated ID's abstract constructor; a compiler error does not count as falsification.

Acceptance: `cabal test keiro-dsl:test:keiro-dsl-conformance-structural-nominals` passes;
the mutation script exits zero only after detecting its named failing assertion, restoring
exact bytes with an EXIT trap, and rerunning the green suite;
`cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/structural-nominal-leaves.keiro
--explain-bindings` lists `TemplateState`, `TemplateRef`, `TemplateBook`, `ClaimId`, and
`AccountNumber` obligations, with `ClaimId`'s use sites including the structural paths and the queue payload row;
`scripts/check-conformance-corpus.sh` passes from a clean tree.
The isolated queue-only and query-only fixtures also scaffold and compile, proving that
the combined fixture is not hiding absent helpers or type imports.

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
picks up the new wire token. Separately extend
`keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs` with nested nominal runtime binding,
canonical identity, and representation facts at register/event uses consistently with
the existing direct-nominal policy. Keep these facts out of the wire-only fingerprint.
Test `aggregateFoldSurfaceForService` and the generated fingerprint: nested prefix,
binding-version, and canonical-type edits change the affected snapshot discriminator;
fixture-only and unrelated nominal edits do not. Snapshot encoding remains consumer JSON
cache serialization. A report-only snapshot context does not satisfy this acceptance.

In `keiro-dsl/src/Keiro/Dsl/MappedDiff.hs`, give `ExprView` an `ExprNominal !Name` arm; two
nominal views with equal names are equal, and any other pairing involving a nominal is
`MappedFieldTypeChanged`. In `keiro-dsl/src/Keiro/Dsl/Diff.hs`, extend `NominalUse` with a
structural use carrying the declaration name and the root path, populate it from
`nominalUsePaths` on both graphs in `nominalUses`, and map it in `nominalUseChange` to
`ContextPrivateEvent` for event roots, the context the mapped-declaration diff already assigns
to a workqueue payload root, `ContextSnapshot` for register roots, and `ContextConsumerBuild`
for command and read-model query roots, so `IdPrefixChanged`,
`NominalBindingChanged`, `NominalFixturesChanged`, `NominalCanonicalTypeChanged`,
`NominalRepresentationChanged`, and `IdDomainContractChanged` carry
the nested paths in their contexts and `--explain` output. Also update the producers
`idPairDiff`, `nominalScalarDiff`, `diffServices.idDomainContractChanges`, and the
`nominalBindingDeclDiff.includeUse` filters; these do not automatically acquire the
promised contexts from `nominalUses`. Preserve existing direct-use classifications and
derive nested contexts and queue rollout facts from the common root authority. Fixture
changes remain evidence-only. A nominal `initial` symbol is not invoked merely because
the type occurs within a structural register, whose own initial symbol constructs the
value; do not claim an initialization change there. Test each producer across event,
register, queue-only, and query-only uses, keeping query consequences build-only.

In `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, extend `branchSchemaFor`'s expression algebra
with `onNominal = const BranchScalar`. `CodecCompare.BranchSchema` describes branch
coverage, not scalar admission; generated leaf parsers own admission. The new corpus's
`extra-args` row in `keiro-dsl/test/conformance-corpus-manifest.txt` must supply both
`--codec-comparison TemplateState` and `--comparison-out` with the exact generated
comparison-module path under its output directory. Execute historical comparison against
explicit historical goldens and codec functions, asserting parity for valid migration
samples and rejection of malformed IDs; compilation alone is not parity evidence.

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
workaround, an ADR records the decision, and IR-40 records implementation evidence and its remaining publication status.

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
type inside shapes, the wire token, the enum exclusion, supported queue/query roots, and the migration
classification; add a one-line pointer under ADR 12's related decisions with a timestamp
advance and `okf log add`. Set IR-40's frontmatter `status` to `in-progress` when Milestone 1
starts and to `completed` with `completedAt` and a `resolution` line only once this milestone and
the supported-language release and consumer migration evidence are available. Otherwise retain
`in-progress` and explicitly record implementation complete, publication/adoption pending;
update its `## Status` section, and add `docs/improvement-requests/log.md` entries.

Acceptance: `just verify` passes, which covers the Haskell build and all test suites, the
ADR, research, user-documentation, and reviews bundle validations, the extension and naming
policies, and the conformance-corpus check.


## Concrete Steps


Run everything from the repository root. The repository's development shell is
`nix develop`; prefix commands with `nix develop -c` if `cabal` is not already on the path.

First save the complete Purpose example to
`keiro-dsl/test/fixtures/mapped-nominal-leaf.keiro`; this is a new fixture. Build the CLI
and run that reproduction before changing the resolver to record the baseline:

```bash
cabal build keiro-dsl:exe:keiro-dsl
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/mapped-nominal-leaf.keiro
```

Expected before Milestone 1: `MappedUnresolvedName`, possibly followed by a cascading
aggregate diagnostic. The following is illustrative; capture actual locations from the run:

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
keiro-dsl/test/diff-test.sh
```

Expected: the check exits 0 with zero opaque persisted roots. The CLI accepts one source
file and `--since GIT-REF`, not two paths. Exercise each baseline/mutant pair in an isolated
temporary Git repository, as the integration script does:

```bash
nominal_dsl_exe="$(cabal list-bin keiro-dsl:exe:keiro-dsl)"
nominal_diff_dir="$(mktemp -d "${TMPDIR:-/tmp}/keiro-nominal-diff.XXXXXX")"
cp keiro-dsl/test/fixtures/structural-nominal-leaves.keiro "$nominal_diff_dir/service.keiro"
git -C "$nominal_diff_dir" init -q
git -C "$nominal_diff_dir" add service.keiro
git -C "$nominal_diff_dir" -c user.name=Qualification -c user.email=qualification@example.invalid \
  -c commit.gpgsign=false commit -qm 'test: establish nominal diff baseline' \
  -m 'ExecPlan: docs/plans/287-support-nominal-ids-inside-structural-mapped-types.md' \
  -m 'Intention: intention_01m2p79tjte5ftry3pdmgbqtjw'
cp keiro-dsl/test/fixtures/structural-nominal-leaves-prefix-change.keiro "$nominal_diff_dir/service.keiro"
(cd "$nominal_diff_dir" && "$nominal_dsl_exe" diff service.keiro --since HEAD --explain)
```

The last command is expected to exit non-zero for the breaking prefix change and list
`IdPrefixChanged` at event and register paths. Keep that expected failure separate from
success-only shell pipelines. For text-to-nominal and opaque-to-nominal comparisons,
commit the Text/opaque form as the baseline and copy the nominal form over the same path;
the migration direction is old Text/opaque to new nominal. Leave the scratch directory
available for inspection.

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

Isolated queue-only and query-only specs without mapped declarations check and compile
under Language 6 and fail the nominal-leaf capability gate under Language 5. Their impact
inventories retain exact queue/query consequences. The full nominal edit matrix has the
same generated-file delta after unrelated consumer growth. Nested binding-version and
canonical-type edits alter the actual affected snapshot fingerprint; fixture-only and
unrelated edits leave it unchanged. Historical comparison runs with explicit goldens and
asserts valid-byte parity, rather than merely compiling its module.

`keiro-dsl diff` classifies the prefix, binding-version, text-to-nominal, and
opaque-to-nominal mutants as described in Milestone 3, with contexts naming the nested paths,
and the compatibility-vector golden matches.

The workspace corpus compiles with one `ClaimId` owner reachable from two members'
structural records, and `cabal run -v0 keiro-dsl-corpus-regen -- check` reports no drift on
two consecutive runs.

`just verify` passes and the new ADR validates strictly. IR-40 records implementation evidence;
it reads `completed` only with supported-language publication and consumer migration/replay
evidence. Pending publication does not prevent this implementation plan completing, but does
prevent claiming the production request is closed.


## Idempotence and Recovery


All fixture, test, documentation, and changelog additions are additive and can be re-applied.
The corpus driver refuses to run over a dirty corpus directory. Preserve existing changes
and compare failed regeneration in a temporary checkout or against a saved baseline before
retrying; do not discard hand-owned bindings or unrelated edits. Never pass
a force-overwrite flag to `scaffold` in a corpus directory, and never hand-edit a generated
module to make regeneration pass; fix the generator or the fixture. `--allow-dirty` is for
local iteration only.

Because the capability is gated on the unpublished candidate Language 6, no published
language changes behaviour and no existing generated corpus changes bytes until a fixture
opts in; if `scripts/check-conformance-corpus.sh` reports drift in a corpus other than the
new or explicitly upgraded workspace-nominal fixtures, that is a regression to fix, not
a golden to accept. Moving
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
data UseSite = UseSite { root :: !RootRef, mapped :: !MappedKey }
data UsePath = UsePath { root :: !RootRef, segments :: ![PathSeg] }
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


- 2026-09-17: Correctness review applied. Completed direct queue/query language gates,
  helper emission, key-free root paths, and nominal impact planning; added real nested
  binding fingerprint validation and all nominal diff producers. Reused completed Plan
  228's qualification machinery, clarified Plan 288's dependency, corrected comparison
  CLI/branch-schema instructions, and made mutation/recovery requirements precise.
- 2026-09-17: Widened the scope to accept nominal leaves at workqueue payload rows and read-model
  query expressions after verifying that both fail with the same `MappedUnresolvedName` as
  records. Replaced the consumer-root rejection with a nominal root-site inventory (and the
  `RootRef` factoring of `UseSite`), dropped the `mapped-nominal-leaf-root.keiro` negative
  fixture, extended the corpus, coverage, diff contexts, and acceptance accordingly, and
  superseded the corresponding Decision Log entry. The remaining gaps (nested enums, contract
  references to declared IDs, expressions and router selection over nested nominals, and the
  direct optional-ID diagnostic) are planned in `docs/plans/288-complete-nominal-id-support-across-contracts-expressions-nested-enums-and-direct-optional-fields.md`.

- 2026-09-17: Final value/release assessment recommends Plan 287 first, preserves the
  existing 0.17 remediation scope, and separates implementation acceptance from supported
  Language 6 publication and IR-40 production closure.
