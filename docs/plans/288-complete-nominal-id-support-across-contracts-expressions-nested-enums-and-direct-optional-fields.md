---
id: 288
slug: complete-nominal-id-support-across-contracts-expressions-nested-enums-and-direct-optional-fields
title: "Complete nominal ID support across contracts, expressions, nested enums, and direct optional fields"
kind: exec-plan
created_at: 2026-09-17T03:43:16Z
intention: "intention_01m2pqc9aaev4ty6cfvcwpwn2m"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-17T03:43:16Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-17T13:27:35Z
      mode: "update"
      note: "Added identifier-keyed maps as Milestone 4; contract containers postponed to a research note"
---

# Complete nominal ID support across contracts, expressions, nested enums, and direct optional fields

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Plan 287 (`docs/plans/287-support-nominal-ids-inside-structural-mapped-types.md`) lets an
`id` or `mapped nominal` declaration appear inside structural records, unions, containers,
workqueue payload rows, and read-model query expressions. On 2026-09-17 an audit of every other
place a `.keiro` author can write an identifier found four remaining gaps, each verified
against the built keiro-dsl 0.16.0.0 compiler, plus one shape that IR-40 had marked as not
required: a map keyed by an identifier. This plan closes all of them so that one `id`
declaration is usable everywhere an identifier is meaningful, with one admission contract and
one diff story.

After this plan an author can do the following. Use a declared `enum` as a structural leaf
(`kind as "kind" : TemplateKind optional on-missing=Draft`) instead of duplicating it as a
`mapped structural enum`. Reference a declared `id` from an integration contract event
(`templateId: TemplateId`) instead of repeating its prefix as the string literal
`typeid "template"`, so that a prefix change on the shared declaration is reported on the
public contract too. Compare a nested identifier in a guard
(`guard cmd.template.templateId == reg.activeTemplateId`) and select router recipients by an
identifier column, with the same nominal equality that direct fields already have. Key a map
by a declared identifier (`byTemplate as "by_template" : Map TemplateId Text`) so the checked
key domain survives at the one place a model naturally indexes by ID. And, when a command
needs an optional identifier, get a diagnostic that names the exact working pattern
rather than advice that leads to another failure.

One thing this plan deliberately does not do: it does not make `Optional TemplateId` a legal
direct aggregate field. ADR 12 fixes direct aggregate shapes to scalars and routes every
container through a structural declaration; after plan 287 that route works for identifiers,
so the fix here is precise guidance, not a new direct shape.


## Progress

- [ ] M1. Nominal enums (generated and consumer-bound) resolve as structural leaves with
      constructor defaults, leaf codecs, wire token, coverage, and diff contexts.
- [ ] M1. The structural-nominals corpus carries an enum leaf with an `on-missing`
      constructor default and passes; IR-1's deferred nested-enum bullet is recorded as
      delivered.
- [ ] M2. Contract event fields accept a declared `id` name under a Language 6 syntax feature,
      lower to the declaration's Haskell type with Keiro admission, and `diff` links a shared
      prefix change to the public contract.
- [ ] M2. Contract conformance fixtures cover a declared-ID field, a literal-to-declared
      migration with identical bytes, and a mismatched prefix.
- [ ] M3. Expression paths ending at a nominal leaf type-check as that nominal; equality
      between two paths or a path and an ID literal is checked and projected with the
      existing nominal equality contract.
- [ ] M3. Declarative router selection accepts nominal ID columns as recipient, key, and
      comparison operands; projection witnesses exist for nested nominal leaves.
- [ ] M4. `Map <Id> V` parses and pretty-prints under a Language 6 syntax feature, resolves
      as a keyed map whose key is a nominal ID leaf, and generates a shape keyed by the ID's
      Haskell type with admission on every key.
- [ ] M4. Consumer-bound key types carry an ordering obligation that conformance checks
      against canonical TypeID text order; coverage, diff, and the corpus cover keyed maps.
- [ ] M5. `AggregateTypeUnsupportedAtUse` for `Optional <nominal>` names the one-field
      structural record pattern; documentation, changelog, and the ADR are updated; the plan
      287 corpus and goldens are regenerated once.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Depend on plan 287 as a hard prerequisite; do not start any milestone here before
  plan 287's Milestone 3 is complete.
  Rationale: every milestone builds on the `RNominal` leaf, the per-context `NominalLeaves`
  codec module, `nominalUsePaths`, and the `StructuralNominalLeaves` capability that plan 287
  introduces. Re-deriving them here would fork the design.
  Date: 2026-09-17
- Decision: Deliver nested enums as a `NominalEnumLeaf` kind of the same leaf, gated by the
  same `StructuralNominalLeaves` capability on candidate Language 6, with constructor
  `on-missing` defaults typed from the leaf's declared constructors and no per-arm
  branch-coverage obligation on the enclosing record's fixtures.
  Rationale: plan 287 excluded enums only because of these extra surfaces. The nominal
  declaration's own fixtures already prove every arm through the nominal binding laws, so
  repeating an arm obligation on every record that embeds the enum would only add fixture
  burden without new evidence. The language gate is shared because Language 6 is still an
  amendable candidate.
  Date: 2026-09-17
- Decision: Contract fields gain a fourth type form, a bare declared `id` name, behind a new
  `LanguageFeature` named `ContractDeclaredIdSyntax` on syntax profile 5 (candidate Language
  6). `typeid "prefix"` literals remain valid forever.
  Rationale: contracts have a separately owned grammar and compatibility surface (ADR 13),
  so the gate is a parser feature, not a runtime capability. Existing published contracts must
  keep parsing and generating byte-identical code.
  Date: 2026-09-17
- Decision: A contract field that moves from `typeid "template"` to a declared `TemplateId`
  whose prefix is `template` is classified as a consumer-build change; any other move to or
  from a declared ID is a breaking public-contract change.
  Rationale: the wire text is identical when the prefixes agree, and the generated decoder
  applies the same TypeID-v7 admission; only the Haskell type changes. When prefixes differ
  the bytes differ, and public contracts follow consumers-deploy-first rules.
  Date: 2026-09-17
- Decision: Nested nominal leaves become expression scalars with equality only, typed as the
  nominal declaration, projected through the existing exact nominal text domain; ordering
  remains unsupported, exactly as for direct nominal fields under IR-12.
  Rationale: IR-12 already fixed the equality semantics and Keiki projection for nominal
  values; the only new element is the JSON-pointer path through the structural record, which
  `ResolvedScalarProjection` already carries for primitive leaves.
  Date: 2026-09-17
- Decision: Router declarative selection treats a nominal ID leaf as a distinct
  `SelectionNominal name` scalar type. It is accepted as `recipient` and `key` (rendered
  through its text), and compared only against another operand of the same declaration or
  an ID literal of that declaration.
  Rationale: a recipient is a target stream derived from identifier text, which is the
  dominant use of ID columns; comparing two different ID declarations by text would defeat
  the nominal distinction that the whole feature exists to preserve.
  Date: 2026-09-17
- Decision: Keep direct `Optional` unsupported as an aggregate shape and improve the
  diagnostic and documentation instead.
  Rationale: ADR 12's single aggregate type authority deliberately confines containers to the
  structural boundary; with plan 287 that boundary now carries identifiers, so the remaining
  defect is that the current message sends authors to a pattern that used to fail.
  Date: 2026-09-17
- Decision (superseded by the next two entries): Exclude identifier-keyed maps (`Map` keyed by an `id`) and containers inside
  contract fields from this plan.
  Rationale: IR-40 states typed map keys are not required; a keyed map needs new grammar for
  the key type and a JSON-object-key admission story, and no consumer has asked for it.
  Contract containers belong to the separately owned contract grammar. Both are recorded as
  deliberate exclusions rather than silent omissions.
  Date: 2026-09-17
- Decision: Deliver identifier-keyed maps in this plan as Milestone 4. The spelling is
  `Map <Id> <Value>`: when `Map` is followed by a declared `id` name and then a second type
  argument, the map is keyed by that ID; `Map <Value>` alone keeps meaning a text-keyed map.
  Keys may be declared IDs only (not enums or nominal scalars). The form is gated by a new
  `KeyedMapSyntax` language feature on candidate Language 6. The resolved graph gets a
  distinct `RKeyedMap` constructor rather than a key field on `RMap`.
  Rationale: the case is legitimate and recurs (a model indexes templates or claims by their
  own identifier), and it does not weaken any Keiki guarantee: `Map` is not an expression
  path leaf, so nothing symbolic changes. Today `Map` takes exactly one type argument
  (`pMappedTypeExpr`, `keiro-dsl/src/Keiro/Dsl/Parser/Mapped.hs:263`), so `Map TemplateId Text`
  is a parse error and the keyed form is a purely additive extension; a distinct constructor
  forces every algebra to take a position on keys instead of silently treating them as text.
  Date: 2026-09-17
- Decision: A keyed map's shape is a Haskell `Map` keyed by the ID's domain type. Generated
  IDs already derive `Ord` over their text. A consumer-bound key type carries an explicit
  ordering obligation, listed by `--explain-bindings` and asserted by generated conformance
  as agreement with canonical TypeID text order over the fixture keys. Keys are encoded and
  decoded through the ID's leaf codec, never through `ToJSONKey`/`FromJSONKey` instances.
  Rationale: `Data.Map` needs `Ord`; if a consumer's `Ord` disagreed with text order, encoded
  key order and byte goldens would drift with consumer code. Making the agreement a checked
  law keeps encoding deterministic without depending on an unverifiable instance, and routing
  keys through the leaf codec keeps Keiro the single admission authority (ADR 12).
  Date: 2026-09-17
- Decision: Postpone containers (`Optional`, `List`, `Map`) inside contract fields. The
  options, costs, and prerequisites are recorded in the research note
  `docs/research/15-containers-in-public-contract-fields.md`; this plan only adds declared-ID
  references to contracts (Milestone 2).
  Rationale: contracts are a public, cross-language surface with a separately owned grammar
  and evolution rules (ADR 13); containers there are a policy decision about the public
  promise, not an engineering gap, and no producer needs them yet.
  Date: 2026-09-17


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All paths are relative to the repository root `/Users/shinzui/Keikaku/bokuno/keiro`. Read
plan 287's Context and Orientation first; this plan uses its vocabulary (nominal declaration,
structural mapped type, resolved type graph, leaf, `TypeExprAlgebra`, conformance corpus,
language candidate, runtime capability) without repeating every definition. The facts below
are the ones specific to this plan's four areas, verified on 2026-09-17.

Plan 287 leaves these behaviours in place, each with a deliberate diagnostic: a declared
`enum` used as a structural leaf is `MappedNominalLeafUnsupported`; an expression path that
ends at a nominal leaf is `ScalarPathInvalid`; a nominal leaf in router selection is rejected
with the existing "must be a mapped structural record" message; and `projectionScalar` in
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (near line 2241) returns no witness for it.

*Nested enums.* `Keiro.Dsl.NominalType` represents an enum as `EnumRepresentation
(NonEmpty (Name, Text))`, a constructor name paired with its wire spelling. Generated enums
are emitted by `emitGeneratedNominal` into the context's `Nominals` module
(`generatedNominalModule`, `Scaffold.hs:255`); consumer-bound enums get a generated
representation module under `Nominal.Shape.<Name>` (`Scaffold.hs:1339`) and a
`NominalBinding domain representation`. In `keiro-dsl/src/Keiro/Dsl/Validate.hs` the
`on-missing` default checker (`defaultType`, `referencedDefaultType`, lines 1424 to 1478)
resolves a constructor default (`OmCtor`) only against a referenced structural enum's
`DefaultEnum` set. `keiro-dsl/src/Keiro/Dsl/StructuralConformance.hs` (`coverageExpression`,
lines 304 to 318) adds an "every entry appears in the fixtures" obligation for a structural
enum declaration; `keiro-dsl/src/Keiro/Dsl/Harness.hs` (`missingExpectedValue`, lines 1591
to 1607) resolves a constructor default for harness expectations.

*Contracts.* `keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs:65` parses contract field types
as `CTypeId <$> (keyword "typeid" *> stringLit)` beside `text` and `int`; the grammar type is
`ContractField` in `keiro-dsl/src/Keiro/Dsl/Grammar.hs:1039`. A contract cannot name a declared
`id`: on 2026-09-17 `templateId: TemplateId` produced a parse error expecting `int`, `text`, or
`typeid`. Lowering is `emitContractGen` (`Scaffold.hs:3157` to about 3310): a `typeid` field
becomes `KindID "<prefix>"` and decodes through `contractIdDomainContractFor`
(`keiro-dsl/src/Keiro/Dsl/IdDomain.hs:36`), which applies the TypeID-v7 domain when the
runtime profile has `ContractIdDomainTypeIdV7`. `keiro-dsl/src/Keiro/Dsl/Diff.hs` classifies
`ContractTypeIdDomainChanged` (line 388, vector at `contractTypeIdDomainVector`) and computes
`contractTypeIdDomainChanges` (line 822); `nominalUses` (2420 to 2447) does not look at
contracts, so a prefix change on a shared `id` never mentions a contract that repeats it.
The contract conformance suites are `keiro-dsl-conformance-contract` and
`keiro-dsl-conformance-contract-v1-compat` in `keiro-dsl/keiro-dsl.cabal`.

*Expressions and selection.* `keiro-dsl/src/Keiro/Dsl/Expression.hs` (lines 415 to 460) walks
a version-2 scalar path through required structural record fields and types the leaf with
`resolvedLeaf`, which maps primitives to `AggregateText`, `AggregateInt`, and so on, and
rejects `Json`, `Optional`, `List`, and `Map`. Direct nominal equality is typed through
`CheckedNominalEquality` and `nominalEqualityContractForService` in `NominalType.hs` (lines
125 to 183) and projected with `ExactFieldProjection` over `idDomainTextPattern` (see
`emitGeneratedNominalEquality`, `Scaffold.hs:1522` to 1578). Projection witnesses for
structural roots are planned by `projectionsForRoot` (`Scaffold.hs:2190` to 2230) using
`projectionScalar`. Router declarative selection is `keiro-dsl/src/Keiro/Dsl/RouterSelection.hs`:
`SelectionScalarType` (line 71) has `SelectionText` and siblings, `resolvePath` (line 448)
walks row and input paths, and `requireScalarType` (line 482) demands `SelectionText` for the
router key and recipient (lines 218 and 222).

*Keyed maps.* `pMappedTypeExpr` (`keiro-dsl/src/Keiro/Dsl/Parser/Mapped.hs:263` to 281)
parses `Map` with exactly one `pTypeArgument` (a parenthesised expression or an atom), so
`Map TemplateId Text` is a parse error today. The pretty-printer (`docTypeExpr`,
`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs:267` to 275) prints `Map` with one argument and
parenthesises compound arguments. `Keiro.Dsl.MappedCodecPlan` encodes a map as
`toJSON (Map.map encode m)` (line 91) and decodes it as `parseJSON :: Parser (Map Text Value)`
followed by `traverse` (line 125), so keys are `Text` and never pass through admission.
Generated ID newtypes derive `Ord` (`Scaffold.hs:1498`); consumer-bound IDs have no ordering
obligation today. `Map` is rejected as an expression path leaf (`Expression.hs`, `resolvedLeaf`)
and as a projection scalar, so keyed maps cannot touch Keiki projections.

*Direct optional fields.* `resolveAggregateType` in `keiro-dsl/src/Keiro/Dsl/AggregateType.hs`
(lines 127 to 150) rejects `TOptional`, `TList`, `TMap`, and `TJson` with
`UnsupportedAggregateShape`, rendered by `Validate.hs` (lines 1099 to 1111) as
`AggregateTypeUnsupportedAtUse` with the text "use a mapped structural declaration for Json
or container shapes". On 2026-09-17 `command Create { templateId:Optional TemplateId }` printed
exactly that, and following the advice failed until plan 287.

Relevant ADRs: [ADR 12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
(direct aggregate shapes are scalars; containers cross the structural boundary; nominal
bindings and Keiro-owned ID admission), [ADR 13](../adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md)
(public contracts have a separately owned grammar and compatibility surface),
[ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) (a public
prefix change must surface in `diff`), [ADR 18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md)
(explicit capabilities and fold-segment decisions), and
[ADR 21](../adr/0021-direct-fields-have-independent-dsl-selector-and-wire-identities.md)
(contract fields have selector and wire-key identities that this plan does not change). Plan
287's Milestone 4 adds an ADR stating that nominal declarations are structural leaves; this
plan amends it rather than adding a second one. Prior plans: 149 to 152 (IR-1 structural
types; IR-1 asked for nested "existing DSL IDs and enums" and plan 149 deferred them on
2026-07-28 because of a generated-module import cycle that plans 158 and 171 later removed),
158 (consumer-bound nominals), 171 (TypeID-v7 domains, including `ContractIdDomainTypeIdV7`),
and 231 and related work for IR-12 (nominal equality in expressions). No improvement request
owns this plan; it completes the deferred IR-1 bullet and the audit that followed IR-40.


## Plan of Work

### Milestone 1: Nominal enums as structural leaves

Scope: after this milestone a generated or consumer-bound `enum` checks, generates, and
round-trips as a structural leaf under candidate Language 6, with a constructor default
allowed on optional-presence fields, and `diff` reports a spelling or binding change on the
enum at every structural path that reaches it.

In `keiro-dsl/src/Keiro/Dsl/TypeGraph.hs`, add `NominalEnumLeaf !(NonEmpty (Name, Text))` to
`NominalLeafKind`, add `checkEnumLeaf :: EnumDecl -> Either NominalLeafError NominalLeaf`
beside the ID and scalar checkers from plan 287, include enum leaves in `nominalByName`, and
delete the `TGUnsupportedNominalLeaf` path for enums (keep the constructor for any future
category). Render the wire token `nominal-enum(<tag>;<tag>;...)` over the sorted wire
spellings, matching how `wireShape` hashes a structural enum. In `Validate.hs`, make
`referencedDefaultType`'s nominal arm return `DefaultEnum` with the leaf's constructor names
for an enum leaf, so `kind as "kind" : TemplateKind optional on-missing=Draft` type-checks,
while ID and scalar leaves keep the no-literal rule from plan 287. Leave
`StructuralConformance.coverageExpression` without a new obligation for enum leaves and say
why in a comment; the nominal declaration's own fixtures cover the arms. In `Harness.hs`,
resolve a constructor default for an enum leaf through the leaf's constructors and the nominal
module (generated) or representation module (consumer-bound) rather than a structural shape
module. In `Scaffold.hs`, `renderMissingDefault` renders the qualified constructor from the
right module, and the `NominalLeaves` module gains `encode<X>Leaf`/`parse<X>Leaf` for enums:
a generated enum delegates to its generated `ToJSON`/`FromJSON` spelling table; a
consumer-bound enum decodes the representation and applies `nominalFromRepresentation`, and
encodes with `nominalToRepresentation` then the spelling table. Coverage lists the leaf with
`kind: enum`. `Diff.nominalUses` already includes structural paths after plan 287; confirm
that the enum diff codes emitted by `enumDiff` (spelling added, removed, renamed, binding
changed) receive those contexts and add a mutant to prove it.

Extend `keiro-dsl/test/fixtures/structural-nominal-leaves.keiro` with a generated
`enum TemplateKind { Draft=draft Published=published }` and a consumer-bound
`enum Channel { Email=email Sms=sms } using { ... }`, a required `channel : Channel` field
and an optional `kind : TemplateKind optional on-missing=Draft` field on `TemplateState`, and
a union arm carrying `Channel`. Regenerate the `keiro-dsl-conformance-structural-nominals`
corpus, fill the new binding for `Channel`, and assert in `Main.hs` that a payload omitting
`kind` decodes to `Draft`, that an unknown spelling is rejected at `$.channel`, and that both
enums round-trip. Add `structural-nominal-leaves-enum-spelling.keiro` as a diff mutant and
assert the spelling-change code carries the `TemplateState` event path. Add
`mapped-nominal-leaf-enum-default.keiro` (an ID leaf with a literal default, still
`MappedDefaultIllTyped`) to keep the ID rule pinned. Retire
`mapped-nominal-leaf-enum.keiro` from the negative table, or repoint it at a vertex name if
one is still needed to prove `MappedNominalLeafUnsupported` fires. Record in
`docs/improvement-requests/log.md` and in IR-1's `relatedPlans` that the nested-enum bullet
deferred by plan 149 is delivered by plans 287 and 288.

Acceptance: `cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/structural-nominal-leaves.keiro`
prints `OK`; `cabal test keiro-dsl:test:keiro-dsl-conformance-structural-nominals` passes
with the enum cases; `scripts/check-conformance-corpus.sh` passes from a clean tree.

### Milestone 2: Contract fields reference declared IDs

Scope: after this milestone a contract event field may be typed by a declared `id` name at
candidate Language 6, the generated payload uses that declaration's Haskell type and Keiro's
admission, and `diff` reports a prefix change on the shared declaration as a public-contract
change with the affected event and field named.

In `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, add `CDeclaredId !Name` to the contract field type
beside `CTypeId`, `CText`, and `CInt`. In `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`, add
`ContractDeclaredIdSyntax` to `LanguageFeature` and include it in syntax profile 5 only. In
`keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs:65`, parse a bare identifier as `CDeclaredId`
after the three keywords and call `requireLanguageFeatureAt` with the new feature so Languages
1 through 5 report `LanguageFeatureRequiresVersion` at the field. In `Validate.hs`, add
`ContractIdUnknown` (the name is not a declared `id`; an `enum`, `mapped nominal`, or
mapped declaration is rejected with a message naming the category) and reuse the existing
selector and wire-key rules. In `emitContractGen` (`Scaffold.hs:3157` onward), lower
`CDeclaredId` to the declaration's Haskell type (generated module type or consumer type),
encode with `<x>Text` or `KindID.toText (nominalToRepresentation ...)`, and decode through
the same admission expression the `NominalLeaves` module uses for that declaration, importing
that module from the contract module; the prefix comes from the declaration, so
`contractIdDomainContractFor` is consulted with it. Contract fields still may not be
`Optional` or containers.

In `Diff.hs`, extend `nominalUses` with contract uses (contract name, event name, field
selector and wire key) mapped through `nominalUseChange` to the public-contract context used
by `contractTypeIdDomainChanges`, so `IdPrefixChanged`, `NominalBindingChanged`, and
`IdDomainContractChanged` name the contract field. Add a contract field diff classification:
`typeid "p"` to `CDeclaredId X` with `X`'s prefix `p` is a consumer-build change; any other
change between the four forms is breaking on the public-contract vector. Extend the
compatibility-vector golden.

Add `keiro-dsl/test/fixtures/contract-declared-id.keiro` (Language 6, a generated
`TemplateId`, a consumer-bound `ClaimId`, and a contract event with one field of each plus a
`typeid "legacy"` field), mutants `-prefix-change.keiro` and `-literal-to-declared.keiro`,
and a Language 5 copy expecting `LanguageFeatureRequiresVersion`. Extend the
`keiro-dsl-conformance-contract` corpus (or add `keiro-dsl-conformance-contract-declared-id`
if that corpus must stay on a published language) so the generated contract module compiles,
round-trips both fields, rejects a wrong prefix at the field path, and produces byte-identical
JSON for the literal and declared forms with equal prefixes. Document the fourth type form in
the contract field table of `docs/user/typed-spec-toolchain.md`.

Acceptance: the fixture checks `OK`; the Language 5 copy reports
`LanguageFeatureRequiresVersion`; `diff` against the prefix mutant reports `IdPrefixChanged`
with a public-contract context naming the event and field; `diff` against the
literal-to-declared mutant reports a consumer-build-only change; the contract corpus passes.

### Milestone 3: Expressions, router selection, and projection witnesses over nested nominals

Scope: after this milestone a guard may compare a nested identifier path with another path
or an ID literal, a declarative router may select recipients and keys by an identifier
column, and generated projection witnesses exist for nested nominal leaves.

In `Expression.hs`, make `resolvedLeaf` map `RNominal leaf` to `AggregateNominal` of the
matching `ResolvedNominalType` (look it up by name through the aggregate symbols already in
scope), and keep `Optional`, `List`, `Map`, and `Json` unsupported. The equality checker then
treats the path exactly as a direct nominal operand: equality against another operand of the
same declaration or a `LiteralId` of that declaration type-checks; a different declaration is
`AggregateGuardTypeMismatch`; ordering is `AggregateGuardCapabilityUnsupported`. The
`ResolvedScalarProjection` pointer already carries the wire keys; in `Scaffold.hs` extend
`projectionScalar` and `projectionsForRoot` to emit a witness for a nominal leaf using the
nominal's exact text domain (`idDomainTextPattern (typeIdV7Domain prefix)` for IDs, the
finite spelling set for enums, the representation for scalars), reusing the projection
rendering of `emitGeneratedNominalEquality`, and make `StructuralConformance`'s
`projectionAssertionDecls` assert `fieldWitnessAgrees` for it. In `RouterSelection.hs`, add
`SelectionNominal !Name` to `SelectionScalarType`; `selectionTypeFromResolved` maps an ID or
scalar nominal leaf to it; `requireScalarType` accepts `SelectionNominal` for the router key
and recipient (render through the leaf's text encoder); comparisons require both sides to be
the same `SelectionNominal name` or an ID literal of that declaration. `RouterSelection`'s
`canonicalResolvedType` includes the nominal name so the selection identity changes when a
column's declaration changes.

Extend `structural-nominal-leaves.keiro` with a register `activeTemplateId TemplateId =
placeholder`, a transition guarded by `cmd.template.templateId == reg.activeTemplateId`, and
a declarative router over the read model from plan 287 with `recipient = row.templateId` and
a `where` comparing `row.holder`'s owner against `input.claimId`. Regenerate the corpus and
assert that the guard admits and rejects as expected in the behavior harness, that the router
selection compiles and its `hospital-transfer-selection`-style identity is recorded, and that
the projection witness assertions pass. Add negative fixtures for comparing two different ID
declarations and for ordering a nominal path.

Acceptance: `cabal test keiro-dsl:test:keiro-dsl-test` covers the new typing cases; the
corpus passes with the guard, router, and witness assertions; `check` on the negative
fixtures prints `AggregateGuardTypeMismatch` and `AggregateGuardCapabilityUnsupported`.

### Milestone 4: Identifier-keyed maps

Scope: after this milestone a structural record or union may declare `Map <Id> <Value>`,
the generated shape is keyed by the identifier's Haskell type, every key is admitted through
the ID's leaf codec on decode, the consumer's key ordering is a checked obligation, and
coverage and `diff` treat the key as a nominal use.

In `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, add `TKeyedMap !Name !TypeExpr` to `TypeExpr`. In
`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`, add `KeyedMapSyntax` to `LanguageFeature`,
present only in syntax profile 5. In `pMappedTypeExpr`, after `keyword "Map"`, first `try` an
identifier followed by a `pTypeArgument` (calling `requireLanguageFeatureAt` with
`KeyedMapSyntax`), and otherwise fall back to the existing single-argument form; extend
`docTypeExpr` to print `Map <Key> <Value>` with `docTypeArgument` on the value, and add
parse/pretty round-trip cases. In `TypeGraph.hs`, add `RKeyedMap !NominalLeaf !ResolvedTypeExpr`
to `ResolvedTypeExpr`, `onKeyedMap :: NominalLeaf -> r -> r` to `TypeExprAlgebra`, and
`SegMapKey` to `PathSeg`; `resolveExpr` requires the key name to resolve to a `NominalIdLeaf`
and otherwise fails with `TGUnsupportedNominalLeaf` carrying the category (`enum`,
`nominal scalar`, or `mapped`) so `Validate` renders `MappedNominalLeafUnsupported` with
"map keys must be declared ids"; `pathsInExpr` and `nominalUsePaths` record the key as a
nominal use at `SegMapKey` and recurse into the value at `SegMapValue`; `rootReference`
follows the value; `refsInExpr` follows the value; the wire token is
`map(key=nominal-id(<prefix>,<domain>);<value token>)`. In `Validate.hs`, a keyed map is
non-null for `hasNonInjectiveOptional`, and `on-missing={}` types it like a text-keyed map.

In `Scaffold.hs`, `renderShapeType` renders `Map <IdHaskellType> <valueShape>` and
`exprRequirements` adds the ID's reference. In `MappedCodecPlan.hs`, `renderMappedEncode`
builds an Aeson object from `Map.toList` with each key rendered by the ID's text encoder
(`<x>Text` or `KindID.toText (nominalToRepresentation ...)`) and each value by the value
encoder; `renderMappedParse` uses `withObject`, parses each key with `parse<X>Leaf` applied to
the key text under a `Key` context so a bad key reports `$.by_template.<key>`, decodes each
value, and builds the map with `Map.fromList` (distinct canonical keys are distinct IDs, so no
post-admission collision is possible). In `ExplainBindings.hs`, list an ordering obligation
for every consumer-bound ID used as a map key: "`Ord <ConsumerType>` must agree with canonical
TypeID text order". In `StructuralConformance.hs`, for each such ID assert, over every pair of
fixture domain values, `compare a b == compare (toText a') (toText b')` where `a'` and `b'`
are the representations from the nominal binding. In `Coverage.hs`, add `position: key` to
`nominalBoundaries` rows produced from `SegMapKey`. In `MappedDiff.hs`, add
`ExprKeyedMap !Name !ExprView`; a text-keyed map becoming ID-keyed or the key declaration
changing is `MappedFieldTypeChanged`; a key ID's prefix or binding change reaches the map's
paths through `nominalUses` automatically. In `CodecCompare.hs`, add the keyed map to the
branch schema as a map whose key branch carries the ID domain. Expressions, router
selection, and projection witnesses keep rejecting maps, unchanged.

Extend `structural-nominal-leaves.keiro`: `TemplateBook` gains
`byTemplate as "by_template" : Map TemplateId Text required` and
`claims as "claims" : Map ClaimId TemplateState optional on-missing={}`. Regenerate the
corpus and assert in `Main.hs`: both maps round-trip with canonical TypeID keys; a key with
the wrong prefix is rejected at `$.by_template.<key>`; a missing `claims` decodes to an empty
map; the ordering law holds for `ClaimId`'s fixtures, and the mutation script additionally
flips the consumer `Ord` on `ClaimId` and asserts the suite goes red. Add
`structural-nominal-leaves-keyed-map-key-change.keiro` (`Map ClaimId` becomes
`Map TemplateId`) expecting `MappedFieldTypeChanged`, `mapped-keyed-map-enum-key.keiro`
(`Map Channel Text`) expecting `MappedNominalLeafUnsupported`, and a Language 5 copy expecting
`LanguageFeatureRequiresVersion`. Document the form in `### Mapped type expressions` and
`### Structural records` of `docs/user/typed-spec-toolchain.md`.

Acceptance: the fixture checks `OK` and pretty-prints back to the same text; the corpus
passes with the map assertions and the ordering mutation turns it red; the three negative
fixtures print their codes; `diff` against the key-change mutant reports
`MappedFieldTypeChanged` on the `TemplateBook` paths.

### Milestone 5: Direct optional identifiers, guidance, documentation, and closure

Scope: after this milestone the `Optional <nominal>` diagnostic names the working pattern,
the user documentation covers every surface this plan and plan 287 added, the changelog and
ADR are current, and both plans' corpora are regenerated and byte-stable.

In `Validate.hs` (`aggregateTypeDiagnostic`, around line 1110), when the unsupported shape is
`TOptional (TRef name)` and `name` is a nominal declaration, append to the message: "declare
`mapped structural record <Name>Ref { ... <field> as \"<key>\" : Optional <Name> optional
on-missing=null }` and use it as the field type (candidate Language 6)". Add a fixture
`direct-optional-id.keiro` and pin the message in the diagnostic table. Add
`### Optional identifiers on commands` to the Types section of
`docs/user/typed-spec-toolchain.md`, update `## Aggregate expressions` (nominal path leaves),
`## Routers` (`SelectionNominal`), `## Integration contracts` (declared-ID form, if not done
in Milestone 2), and the nested-enum notes in `### Mapped type expressions`; advance
timestamps and `okf log add`. Add `keiro-dsl/CHANGELOG.md` entries under `[Unreleased]` for
each milestone. Amend the ADR that plan 287 created with the enum, contract, expression, and
direct-optional decisions (advance its `timestamp`, `okf log add` in `docs/adr/`, strict
validation). Run the whole corpus check twice.

Acceptance: `just verify` passes; the diagnostic fixture prints the new guidance; all user
documentation bundles validate.


## Concrete Steps

Run from the repository root; prefix with `nix develop -c` if `cabal` is not on the path.
Start only after plan 287's Milestone 3 is checked off in its Progress section.

```bash
cabal build keiro-dsl:exe:keiro-dsl
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/structural-nominal-leaves.keiro
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/contract-declared-id.keiro
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/direct-optional-id.keiro
```

Expected after Milestones 1, 2, and 5 respectively:

```text
OK
OK
direct-optional-id.keiro:9: error[AggregateTypeUnsupportedAtUse]: direct aggregate type 'Optional(TemplateId)' is unsupported at command field; declare `mapped structural record TemplateIdRef { templateId as "templateId" : Optional TemplateId optional on-missing=null }` and use it as the field type (candidate Language 6)
```

Regenerate and test the corpora after each milestone:

```bash
cabal run -v0 keiro-dsl-corpus-regen -- regenerate --only keiro-dsl/test/conformance-structural-nominals
cabal test keiro-dsl:test:keiro-dsl-conformance-structural-nominals
cabal test keiro-dsl:test:keiro-dsl-conformance-contract
cabal test keiro-dsl:test:keiro-dsl-test
scripts/check-conformance-corpus.sh
```

Diff classifications for Milestone 2:

```bash
cabal run -v0 keiro-dsl -- diff keiro-dsl/test/fixtures/contract-declared-id.keiro \
  keiro-dsl/test/fixtures/contract-declared-id-prefix-change.keiro --explain
```

Check the `diff` invocation form against `cabal run -v0 keiro-dsl -- diff --help`; the
`### diff` section of `docs/user/typed-spec-toolchain.md` is authoritative.

Keyed-map classification for Milestone 4:

```bash
cabal run -v0 keiro-dsl -- diff keiro-dsl/test/fixtures/structural-nominal-leaves.keiro \
  keiro-dsl/test/fixtures/structural-nominal-leaves-keyed-map-key-change.keiro --explain
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/mapped-keyed-map-enum-key.keiro
```

```text
mapped-keyed-map-enum-key.keiro:N: error[MappedNominalLeafUnsupported]: mapped declaration 'TemplateBook' field 'byChannel' uses enum 'Channel' as a map key; map keys must be declared ids
```

Closing gate:

```bash
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
okf validate docs/improvement-requests --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
just verify
```

Every commit while implementing this plan carries the trailers:

```text
ExecPlan: docs/plans/288-complete-nominal-id-support-across-contracts-expressions-nested-enums-and-direct-optional-fields.md
Intention: intention_01m2pqc9aaev4ty6cfvcwpwn2m
```


## Validation and Acceptance

The plan is complete when all of the following are observable.

A record field typed by a generated or consumer-bound `enum` checks, scaffolds, compiles, and
round-trips; omitting an optional enum field yields its declared constructor default; an
unknown spelling is rejected at the field path; a spelling change on the enum is reported by
`diff` at the event path that embeds it.

A contract event field typed by a declared `id` checks at Language 6 and fails at Language 5
with `LanguageFeatureRequiresVersion`; the generated contract payload uses the declaration's
Haskell type; the encoded JSON for `typeid "template"` and `TemplateId` (prefix `template`)
is byte-identical and `diff` calls that move consumer-build only; a prefix change on the
shared `id` is reported by `diff` with a public-contract context naming the event and field.

A guard comparing a nested identifier path with a register of the same declaration admits
and rejects correctly in the generated behavior harness; comparing two different declarations
is `AggregateGuardTypeMismatch`; ordering a nominal path is
`AggregateGuardCapabilityUnsupported`; a declarative router with `recipient = row.templateId`
compiles and dispatches; projection witness assertions for nested nominal leaves pass.

A record field `Map TemplateId Text` checks, pretty-prints back to itself, and round-trips
with canonical TypeID keys; a wrong-prefix key is rejected at its object-key path; an ID-keyed
map over a consumer-bound ID whose `Ord` disagrees with text order fails conformance; a
Text-keyed map becoming ID-keyed is reported by `diff` as `MappedFieldTypeChanged`.

`Optional TemplateId` as a direct command field prints the guidance message with the exact
one-field record pattern, and that pattern checks `OK`.

`just verify` passes and both corpora are byte-stable across two regeneration runs.


## Idempotence and Recovery

Every step is additive to plan 287's work and can be re-run. The corpus driver refuses to run
over a dirty corpus; discard a broken regeneration with
`git checkout -- keiro-dsl/test/conformance-structural-nominals` and re-run. Never hand-edit
generated modules. Because nested enums and contract declared IDs are gated on the Language 6
candidate (runtime capability and syntax feature respectively), no published language changes
and no published-language corpus may change bytes; drift in any corpus other than the ones
this plan extends is a regression. If `SelectionNominal` proves too disruptive to the
declarative router's selection identity, the recorded fallback is to accept nominal ID
columns only as `recipient` and `key` in this plan and leave `where` comparisons for a
follow-up; note the change in the Decision Log first. If the `try`-based keyed `Map` parse
turns out to conflict with an existing spelling in the corpus, the recorded fallback is an
explicit bracketed key (`Map[TemplateId] Text`); record the change in the Decision Log and
update the pretty-printer and documentation together.


## Interfaces and Dependencies

`keiro-dsl/src/Keiro/Dsl/TypeGraph.hs`:

```haskell
data NominalLeafKind
  = NominalIdLeaf !Text
  | NominalScalarLeaf !NominalScalarRepresentation
  | NominalEnumLeaf !(NonEmpty (Name, Text))

checkEnumLeaf :: EnumDecl -> Either NominalLeafError NominalLeaf

data ResolvedTypeExpr = {- plan 287 constructors -} | RKeyedMap !NominalLeaf !ResolvedTypeExpr
data PathSeg = {- existing segments -} | SegMapKey
-- TypeExprAlgebra gains: onKeyedMap :: NominalLeaf -> r -> r
```

`keiro-dsl/src/Keiro/Dsl/Grammar.hs`: `TypeExpr` gains `TKeyedMap !Name !TypeExpr`.
`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`: `LanguageFeature` gains `KeyedMapSyntax`,
present only in syntax profile 5. `keiro-dsl/src/Keiro/Dsl/MappedDiff.hs`: `ExprView` gains
`ExprKeyedMap !Name !ExprView`.

`keiro-dsl/src/Keiro/Dsl/Grammar.hs`: the contract field type gains `CDeclaredId !Name`.
`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`: `LanguageFeature` gains
`ContractDeclaredIdSyntax`, present only in syntax profile 5. `keiro-dsl/src/Keiro/Dsl/Validate.hs`:
new code `ContractIdUnknown`. `keiro-dsl/src/Keiro/Dsl/RouterSelection.hs`:

```haskell
data SelectionScalarType = SelectionText | {- existing -} | SelectionNominal !Name
```

`keiro-dsl/src/Keiro/Dsl/Expression.hs`: `resolvedLeaf :: ResolvedTypeExpr -> Either ... ResolvedAggregateType`
returns `AggregateNominal` for a nominal leaf. The generated `NominalLeaves` module from plan
287 gains enum helpers with the same signatures (`encode<X>Leaf :: X -> Value`,
`parse<X>Leaf :: Value -> Parser X`). No new package dependency is introduced; `aeson`,
`mmzk-typeid`, `keiki` (projection witnesses), and `keiro-core` already provide every runtime
symbol used.


## Revision Notes

- 2026-09-17: Added identifier-keyed maps as Milestone 4 (the closure milestone became 5) after
  deciding the case is legitimate, recurring, and neutral to Keiki guarantees because `Map`
  is never an expression path leaf. Superseded the exclusion decision, recorded the keyed
  syntax, the distinct `RKeyedMap` constructor, the `KeyedMapSyntax` gate, and the
  consumer-bound ordering law. Containers inside contract fields remain postponed and are
  captured in `docs/research/15-containers-in-public-contract-fields.md`. The plan title is
  unchanged to keep its path stable.
