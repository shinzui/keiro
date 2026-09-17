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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-17T13:54:12Z
      mode: "update"
      note: "Stage release priorities and fix prior parser, bound-enum default, branch schema, contract-only emission, and router fixture findings"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-17T17:57:28Z
      mode: "update"
      note: "Refresh against completed Plan 287 and start Milestone 1 with landed resolver, default, contract, and router authorities"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-17T13:40:55Z
      verdict: "changes-requested"
      note: "Validated diff producers, fingerprint propagation, CLI syntax and ADR links; fix keyed-map parsing ambiguity, consumer-bound enum default conversion, and branch-schema admission conflation."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-17T13:55:00Z
      verdict: "comments"
      note: "Final value/release assessment recommends staged delivery; prior three blockers and contract/router gaps corrected in this update; implementation unverified"
---

# Complete nominal ID support across contracts, expressions, nested enums, and direct optional fields


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Completed plan 287 (`docs/plans/287-support-nominal-ids-inside-structural-mapped-types.md`) lets an
`id` or `mapped nominal` declaration appear inside structural records, unions, containers,
workqueue payload rows, and read-model query expressions. On 2026-09-17 an audit of every other
place a `.keiro` author can write an identifier found four remaining gaps, each verified
against the built keiro-dsl 0.16.0.0 compiler, plus one shape that IR-40 had marked as not
required: a map keyed by an identifier. This plan closes those specific gaps so declared identifiers retain their identity and
admission rules across more supported surfaces. The exclusions below remain explicit.

After this plan an author can do the following. Use a declared `enum` as a structural leaf
(`kind as "kind" : TemplateKind optional on-missing=Draft`) instead of duplicating it as a
`mapped structural enum`. Reference a declared `id` from an integration contract event
(`templateId: TemplateId`) instead of repeating its prefix as the string literal
`typeid "template"`, so that a prefix change on the shared declaration is reported on the
public contract too. Compare a nested identifier in a guard
(`guard cmd.template.templateId == reg.activeTemplateId`) and select router recipients by an
identifier column, with the same nominal equality that direct fields already have. Key a map
by a declared identifier (`byTemplate as "by_template" : Map[TemplateId] Text`) so the checked
key domain survives at the one place a model naturally indexes by ID. And, when a command
needs an optional identifier, get a diagnostic that names the exact working pattern
rather than advice that leads to another failure.

One thing this plan deliberately does not do: it does not make `Optional TemplateId` a legal
direct aggregate field. ADR 12 fixes direct aggregate shapes to scalars and routes every
container through a structural declaration; after plan 287 that route works for identifiers,
so the fix here is precise guidance, not a new direct shape.


### Release recommendation (2026-09-17)


This work improves the DSL by making existing declarations compose consistently. Plan 287's
workspace/documentation milestone is complete at `539a0580`. Prioritize the optional-ID
guidance from Milestone 5, nested enums (Milestone 1), and declared contract IDs (Milestone 2).
Milestone 3 is valuable when consumers need nested IDs in guards or routing, but must preserve
required-path totality and existing nominal equality restrictions. Milestone 4's keyed maps
remain planned; they add grammar and an ordering obligation beyond IR-40's required scope and
should not be a release blocker for the preceding features.

The five milestones describe full plan completion, not an all-or-nothing release bundle. A
release may include completed milestones with their own compiled, compatibility, workspace,
documentation, and regeneration evidence. Run the applicable closure work from Milestone 5
for each shipped subset and leave all unfinished Progress entries unchecked. Do not advertise
“complete nominal support”: direct aggregate containers, optional-path traversal, and public
contract containers remain deliberately unavailable. This plan does not add prerequisites to
MasterPlan 43's 0.17.0.0 remediation release. Candidate-language delivery remains preview;
production availability requires publication of a language containing the shipped subset.
If Language 6 has published by a later milestone, use a successor syntax/runtime profile for
that milestone rather than amending the frozen profile.

## Progress


- [x] 2026-09-17: Final release assessment and prior-review corrections; staged release priorities, explicit keyed-map syntax, bound-enum defaults, and branch-schema separation.
- [x] 2026-09-17: Refreshed after plan 287 completed at `539a0580`; reconciled the plan with
      the landed `NominalLeaf`, `collectNominalLeaves`, `RootRef`, `nominalUsePaths`, and
      `RNominal` authorities and corrected enum defaults, codecs, contract reachability, and
      router literal/projection work before implementation.
- [x] 2026-09-17: M1. Nominal enums (generated and consumer-bound) resolve as structural leaves with
      constructor defaults, leaf codecs, wire token, coverage, and diff contexts.
- [x] 2026-09-17: M1. The structural-nominals corpus carries generated and consumer-bound enum
      leaves with `on-missing`
      constructor defaults and passes; IR-1's deferred nested-enum bullet is recorded as
      delivered. Evidence: commit `74b9206b`; 747 `keiro-dsl-test` examples, the focused
      structural-nominals suite, the shell diff matrix, and all 46 clean-tree corpus
      invocations pass.
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
- [ ] M4. `Map[Id] V` parses and pretty-prints under a Language 6 syntax feature, resolves
      as a keyed map whose key is a nominal ID leaf, and generates a shape keyed by the ID's
      Haskell type with admission on every key.
- [ ] M4. Consumer-bound key types carry an ordering obligation that conformance checks
      against canonical TypeID text order; coverage, diff, and the corpus cover keyed maps.
- [ ] M5. `AggregateTypeUnsupportedAtUse` for `Optional <nominal>` names the one-field
      structural record pattern; documentation, changelog, and the ADR are updated; the plan
      287 corpus and goldens are regenerated once.


## Surprises & Discoveries


- 2026-09-17 implementation refresh: Plan 287 landed a single `NominalLeaf` authority rather
  than the earlier hypothetical `nominalByName`: `collectNominalLeaves` currently admits IDs
  and nominal scalars, `resolveTypeGraph` carries the result, `RNominal` preserves the leaf,
  and `RootRef` plus `nominalUsePaths` carries nested contexts. Enum support must extend those
  exhaustive matches rather than introduce a parallel lookup.
- 2026-09-17 implementation refresh: `Harness.missingExpectedValue` compares JSON, so an enum
  default there must be the declared wire spelling. Only `Scaffold.renderMissingDefault`
  constructs the generated domain value or converts a consumer representation constructor
  with `nominalFromRepresentation`. Generated enum Aeson instances are generic and are not
  the declared spelling authority; leaf codecs must use the generated `<name>Text` function
  and explicit spelling parsers.
- 2026-09-17 final check: The preceding review's three blockers remained in the text.
  `Parser/Mapped.hs` parses one argument followed by presence or enclosing grammar;
  speculative consumption of a second identifier can steal those tokens. Consumer-bound
  enum constructors belong to a representation type, while shape fields hold the domain
  type. `CodecCompare.BranchSchema` has `BranchMap valueSchema` and no admission-domain
  field. The instructions below now address all three explicitly.
- The M3 example attempted to traverse the optional `holder` introduced by Plan 287, but
  `Expression.hs` and `RouterSelection.hs` only traverse required record paths. The fixture
  now introduces separate required ID fields. Nominal scalars also include non-text
  representations, so they cannot all be accepted as recipient/key text.
- 2026-09-17: A Codex correctness review of plan 287 (recorded in its provenance and Surprises
  sections) found that `Diff.nominalUses` is not the producer of nominal findings:
  `idPairDiff`, `nominalScalarDiff`, `enumDiff`, and the ID-domain pass in `diffServices`
  emit declaration findings independently, `UsePath.root` must become a key-free `RootRef`,
  and nested nominal binding changes need explicit propagation into
  `Keiro.Dsl.FoldFingerprint` register segments. Every milestone here that promised
  path-specific contexts "through `nominalUses`" was rewritten to update the producers
  and the fold fingerprint directly.
- 2026-09-17 implementation: The existing `mapped-nominal-leaf-default.keiro` already pins
  the required refusal for a literal default on an ID leaf. Adding the planned
  `mapped-nominal-leaf-enum-default.keiro` would have duplicated that exact contract, so M1
  reuses the existing fixture and adds only the new Language 5 enum refusal fixture.
- 2026-09-17 implementation: Query-contract import planning treated every generated nominal
  reachable beneath a consumer mapped input as a direct generated query alias. Adding a
  generated enum leaf exposed the redundant import. Restricting that plan to direct generated
  nominal query roots removed the unused import while the mapped input continued to use its
  generated shape authority.
- 2026-09-17 implementation: The broad suite found one stale type-graph assertion that still
  expected enums to be unsupported. Replacing it with an explicit `NominalEnumLeaf` kind and
  reachability assertion made the intended resolver contract executable instead of merely
  deleting the old expectation.


## Decision Log


- Decision: Recommend staged feature releases, with Plan 287 complete first and keyed maps
  retained as a later milestone rather than a prerequisite to shipping nominal composition.
  Rationale: Composition removes a demonstrated blocker; keyed maps are useful additional
  modeling power with a separate parser, ordering, and compatibility cost.
  Date: 2026-09-17
- Decision: Use `Map[Id] Value` for keyed maps, superseding the unbracketed syntax below.
  Keep `Map Value` unchanged; parse key validity in resolution, not through symbol-aware
  grammar. Treat map branch coverage separately from key admission and explicitly test both.
  Rationale: A delimiter makes arity unambiguous even before declarations are resolved and
  prevents consuming presence markers or tokens from the next enclosing clause.
  Date: 2026-09-17
- Decision: Depend on plan 287 as a hard prerequisite; this prerequisite was fulfilled by its
  completed Milestone 4 and closing documentation commit `539a0580` on 2026-09-17.
  Rationale: every milestone builds on the `RNominal` leaf, the per-context `NominalLeaves`
  codec module, `nominalUsePaths`, and the `StructuralNominalLeaves` capability that plan 287
  introduces. Milestone 4 also supplies the workspace evidence and ADR this plan amends.
  Re-deriving them here would fork the design.
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
- Decision (syntax superseded by the 2026-09-17 final assessment): Deliver identifier-keyed maps in this plan as Milestone 4. The spelling is
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


Plan 287 completed on 2026-09-17 and this plan was refreshed against its landed resolver,
context, codec, conformance, and fingerprint authorities before implementation. Milestone 1
completed at `74b9206b`: generated and consumer-bound enums now share the nominal structural
leaf authority, preserve exact declared spellings, support generated- and consumer-domain
constructor defaults, contribute coverage/fold/diff facts, and compile in the structural
nominals corpus. The 747-example main suite, focused compiled corpus, shell diff matrix, strict
documentation profiles, generated-inventory check, and 46-invocation clean-tree corpus gate
all pass. Milestones 2 through 5 remain unstarted. The recommendation remains staged delivery,
with keyed maps optional for the next feature release.


## Context and Orientation


All paths are relative to the repository root `/Users/shinzui/Keikaku/bokuno/keiro`. Read
plan 287's Context and Orientation first; this plan uses its vocabulary (nominal declaration,
structural mapped type, resolved type graph, leaf, `TypeExprAlgebra`, conformance corpus,
language candidate, runtime capability) without repeating every definition. The facts below
are the ones specific to this plan's five areas, verified on 2026-09-17.

At the start of this plan, completed plan 287 left these behaviours in place, each with a
deliberate diagnostic: a declared `enum` used as a structural leaf was
`MappedNominalLeafUnsupported`; an expression path that
ends at a nominal leaf is `ScalarPathInvalid`; a nominal leaf in router selection is rejected
with the existing "must be a mapped structural record" message; and `projectionScalar` in
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (near line 2241) returns no witness for it.
Milestone 1 removes only the first diagnostic; the expression, router, and projection gaps
remain for Milestone 3.

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
`Map[TemplateId] Text` is a parse error today. The pretty-printer (`docTypeExpr`,
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
(contract fields have selector and wire-key identities that this plan does not change), and
[ADR 46](../adr/0046-nominal-declarations-are-structural-leaves-with-keiro-owned-admission.md)
(nominal declarations are structural leaves with Keiro-owned admission). This plan amends
ADR 46 rather than adding a second nominal-leaf decision. Prior plans: 149 to 152 (IR-1 structural
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
`NominalLeafKind`, add `LeafEmptyEnum` and
`checkEnumLeaf :: EnumDecl -> Either NominalLeafIssue NominalLeaf` beside plan 287's ID and
scalar checkers, and have `NominalType.resolveNominalTypes` use it so ownership and binding
validation stay centralized. Include enum leaves in `collectNominalLeaves` and stop placing
ordinary enum references in `unsupportedNominalLeafKinds`; retain `TGUnsupportedNominalLeaf`
because Milestone 4 uses it for enum map keys. Render the wire token
`nominal-enum(<tag>;<tag>;...)` over the sorted wire spellings, matching how `wireShape` hashes
a structural enum. Update every exhaustive `NominalLeafKind` match, including
`Goldens.sampleNominalLeaf`, `Coverage.nominalBoundaryInventory`,
`FoldFingerprint.nominalLeafRepresentationSegment`, `Scaffold` leaf generation/import
planning, and `NominalType.resolvedFromLeaf`. In `Validate.hs`, make `defaultType`'s
`TypeExprAlgebra.onNominal` arm return `DefaultEnum` with an enum leaf's constructor names,
so `kind as "kind" : TemplateKind optional on-missing=Draft` type-checks. Do not change
`referencedDefaultType`, which handles mapped declaration references rather than `RNominal`
leaves. ID and scalar leaves keep the no-literal rule from plan 287. Leave
`StructuralConformance.coverageExpression` without a new obligation for enum leaves and say
why in a comment; the nominal declaration's own fixtures cover the arms. In `Harness.hs`,
make `missingExpectedValue` emit the declared JSON string for an enum constructor because the
harness compares re-encoded JSON. In `Scaffold.renderMissingDefault`, generated enum defaults
use their domain constructor directly; consumer-bound defaults qualify the representation
constructor and apply `nominalFromRepresentation <binding>` to produce the consumer domain
value expected by the shape. Add the required nominal, binding, and representation imports
through the shared import planner. The `NominalLeaves` module gains
`encode<X>Leaf`/`parse<X>Leaf` for enums: a generated enum encodes with its generated
`<lowerName>Text` function and decodes through explicit declared-wire-spelling cases; a
consumer-bound enum encodes by applying `nominalToRepresentation` then the generated
representation encoder and decodes through explicit representation spelling cases before
applying `nominalFromRepresentation`. Do not delegate either case to generic derived Aeson,
which is not the declared spelling authority. Coverage lists the leaf with `kind: enum`. In
`Diff.hs`, update the enum producer `enumDiff` (spelling added, removed,
renamed, binding changed) the same way plan 287 updates `idPairDiff` and `nominalScalarDiff`:
derive nested contexts from the common root authority (`nominalUsePaths` over the key-free
`RootRef`) rather than from `nominalUses`, keep existing direct-use classifications, and add a
mutant to prove each context. In `keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs`, propagate a
nested enum leaf's binding, canonical-identity, and spelling facts into the register and
event segments exactly as plan 287 does for ID and scalar leaves, and test that a spelling
or binding-version edit changes the affected snapshot discriminator while a fixture-only
edit does not.

Extend `keiro-dsl/test/fixtures/structural-nominal-leaves.keiro` with a generated
`enum TemplateKind { Draft=draft Published=published }` and a consumer-bound
`enum Channel { Email=email Sms=sms } using { ... }`, a required `channel : Channel` field
an optional `kind : TemplateKind optional on-missing=Draft` field on `TemplateState`, an
optional `fallbackChannel : Channel optional on-missing=Email` field, and a union arm
carrying `Channel`. Regenerate the `keiro-dsl-conformance-structural-nominals`
corpus, fill the new binding for `Channel`, and assert in `Main.hs` that a payload omitting
`kind` decodes to `Draft`, that an unknown spelling is rejected at `$.channel`, and that both
enums round-trip. Omitting `fallbackChannel` must produce the consumer-domain Email value
and re-encode as `email`, with the representation and domain deliberately distinct types. Add `structural-nominal-leaves-enum-spelling.keiro` as a diff mutant and
assert the spelling-change code carries the `TemplateState` event path. Add
or reuse a fixture for an ID leaf with a literal default, still `MappedDefaultIllTyped`, to
keep the ID rule pinned; implementation reused the existing
`mapped-nominal-leaf-default.keiro`. Move `mapped-nominal-leaf-enum.keiro` into positive
Language 6 coverage and retain a
Language 5 enum-leaf refusal. M4 supplies the unsupported enum-map-key diagnostic case;
do not expect an unrelated unresolved vertex name to produce that diagnostic. Record in
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
that module from the contract module. The current `scaffoldContractWithLanguage` and
`emitContractGen` path receives only a `Context` and `EffectiveLanguageContract`; thread the
checked `Spec` or resolved graph through `scaffoldContractForService` and the service emit path
so declared-ID lowering cannot rebuild nominal truth. Preserve the legacy wrapper's behavior
for callers without a checked service. Extend helper emission, type/import/package planning,
workspace attribution, binding explanations, and nominal conformance reachability to contract
roots, including a contract-only fixture with no aggregates, queues, or mapped declarations;
that fixture must still make its nominal leaf helper reachable even though no structural root
otherwise references it.
The prefix comes from the declaration, so
`contractIdDomainContractFor` is consulted with it. Contract fields still may not be
`Optional` or containers.

In `Diff.hs`, add contract roots (contract name, event name, field selector and wire key)
to the common root authority that plan 287 introduces, and update the producers that emit
nominal findings, `idPairDiff`, `nominalBindingDeclDiff` and its `includeUse` filters, and
`diffServices.idDomainContractChanges`, to consult it, so `IdPrefixChanged`,
`NominalBindingChanged`, and `IdDomainContractChanged` name the contract field under the
public-contract context used by `contractTypeIdDomainChanges`. Do not route this through
`nominalUses` alone; plan 287's review established that it is not the producer. Add a contract field diff classification:
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
`projectionScalar`, `StructuralProjection`, and `projectionsForRoot` so a nominal projection
stores and applies terminal encoder metadata rather than pretending the leaf is already
primitive `Text`. Emit a witness over the nominal's exact text domain
(`idDomainTextPattern (typeIdV7Domain prefix)` for IDs, the finite spelling set for enums,
the representation for scalars), reusing the projection rendering of
`emitGeneratedNominalEquality`, and make `StructuralConformance`'s
`projectionAssertionDecls` assert `fieldWitnessAgrees` for it. In `RouterSelection.hs`, add
`SelectionNominal !Name` to `SelectionScalarType`; `selectionTypeFromResolved` maps an ID
leaf to it, and `requireScalarType` accepts that ID-specific nominal type for recipient and
key rather than demanding `SelectionText`. Render those values with the structural nominal
leaf encoder's canonical text conversion. Keep nominal scalars and enums unsupported in
router selection in this milestone; they do not all have ID text semantics. The checked
router scalar AST currently has path, text, integral, and boolean cases but rejects
`LiteralId`; add an ID-literal case carrying the declaration identity and literal text (or an
equivalent checked parsed form), and cover its canonicalization, fingerprint, rendering, and
imports. Update direct input nominal resolution consistently with nested row resolution;
comparisons require both sides to be the same `SelectionNominal name` or an ID literal of that
declaration. `RouterSelection`'s `canonicalResolvedType` includes the nominal name so the
selection identity changes when a column's declaration changes.

Extend `structural-nominal-leaves.keiro` with a register `activeTemplateId TemplateId =
placeholder`, a transition guarded by `cmd.template.templateId == reg.activeTemplateId`, and
a declarative router over the read model from plan 287 with `recipient = row.templateId` and
a `where` comparing a new required `row.claimId : ClaimId` field against a required
`input.claimId : ClaimId`. Use a structural query-result row containing required
`templateId : TemplateId` and `claimId : ClaimId`, instead of the earlier `List TemplateId`
alias. Do not traverse the existing optional `holder`; pin its rejection as a negative case. Regenerate the corpus and
assert that the guard admits and rejects as expected in the behavior harness, that the router
selection compiles and its `hospital-transfer-selection`-style identity is recorded, and that
the projection witness assertions pass. Add negative fixtures for comparing two different ID
declarations and for ordering a nominal path.

Acceptance: `cabal test keiro-dsl:test:keiro-dsl-test` covers the new typing cases; the
corpus passes with the guard, router, and witness assertions; `check` on the negative
fixtures prints `AggregateGuardTypeMismatch` and `AggregateGuardCapabilityUnsupported`.

### Milestone 4: Identifier-keyed maps


Scope: after this milestone a structural record or union may declare `Map[Id] Value`,
the generated shape is keyed by the identifier's Haskell type, every key is admitted through
the ID's leaf codec on decode, the consumer's key ordering is a checked obligation, and
coverage and `diff` treat the key as a nominal use.

In `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, add `TKeyedMap !Name !TypeExpr` to `TypeExpr`. In
`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`, add `KeyedMapSyntax` to `LanguageFeature`,
present only in syntax profile 5. In `pMappedTypeExpr`, after `keyword "Map"`, look for an explicit `[` key identifier `]`, then parse one `pTypeArgument`, calling
`requireLanguageFeatureAt` with `KeyedMapSyntax` outside any backtracking fallback. Without
`[`, parse exactly one argument as today. Resolve whether the key is a declared ID later; extend
`docTypeExpr` to print `Map[Key] Value` with `docTypeArgument` on the value, and add
parse/pretty round-trip cases. Pin unchanged parsing for `Map TemplateId required`,
`Map Text optional on-missing={}`, parenthesized nested maps, adjacent union arms, and
queue/query clauses. Verify a Language 5 bracketed form reports the feature gate. In `TypeGraph.hs`, add `RKeyedMap !NominalLeaf !ResolvedTypeExpr`
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
changing is `MappedFieldTypeChanged`. Because the key is recorded as a nominal use at
`SegMapKey` in the common root authority, the producers plan 287 updates report a key ID's
prefix, binding, or domain change at the map's paths; add a mutant to prove it rather than
assuming it. In `FoldFingerprint.hs`, include the key ID's nested facts in register segments
the same way as value-position leaves. In `Scaffold.branchSchemaFor`, lower a keyed map to `BranchMap valueSchema`.
`CodecCompare.BranchSchema` measures branch coverage and carries no ID admission domain.
Test invalid keys through the generated decoder and explicit historical-comparison samples;
do not add scalar admission policy to branch coverage. Expressions, router
selection, and projection witnesses keep rejecting maps, unchanged.

Extend `structural-nominal-leaves.keiro`: `TemplateBook` gains
`byTemplate as "by_template" : Map[TemplateId] Text required` and
`claims as "claims" : Map[ClaimId] TemplateState optional on-missing={}`. Regenerate the
corpus and assert in `Main.hs`: both maps round-trip with canonical TypeID keys; a key with
the wrong prefix is rejected at `$.by_template.<key>`; a missing `claims` decodes to an empty
map; the ordering law holds for `ClaimId`'s fixtures, and the mutation script additionally
reverses the consumer `Ord` on `ClaimId` and asserts that the named ordering assertion
fails. As in plan 287, the mutation must compile, the script must detect its named failing
assertion, restore exact bytes with an EXIT trap, and rerun the green suite; a compiler
error does not count as falsification. Add
`structural-nominal-leaves-keyed-map-key-change.keiro` (`Map[ClaimId] TemplateState` becomes
`Map[TemplateId] TemplateState`) expecting `MappedFieldTypeChanged`, `mapped-keyed-map-enum-key.keiro`
(`Map[Channel] Text`) expecting `MappedNominalLeafUnsupported`, and a Language 5 copy expecting
`LanguageFeatureRequiresVersion`. Document the form in `### Mapped type expressions` and
`### Structural records` of `docs/user/typed-spec-toolchain.md`.

Acceptance: the fixture checks `OK` and pretty-prints back to the same text; the corpus
passes with the map assertions and the ordering mutation turns it red; legacy single-argument map
forms retain their parse trees and published corpus bytes; the enum-key and Language 5
negative fixtures print their codes; `diff` against the key-change mutant reports
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
Start only after plan 287's Milestone 4 is checked off in its Progress section.

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

Diff classifications for Milestones 2 and 4. `keiro-dsl diff` takes one source file and
`--since GIT-REF`, not two paths, so exercise each baseline/mutant pair in a throwaway Git
repository, exactly as plan 287's Concrete Steps do:

```bash
dsl_exe="$(cabal list-bin keiro-dsl:exe:keiro-dsl)"
diff_dir="$(mktemp -d "${TMPDIR:-/tmp}/keiro-nominal-diff.XXXXXX")"
cp keiro-dsl/test/fixtures/contract-declared-id.keiro "$diff_dir/service.keiro"
git -C "$diff_dir" init -q && git -C "$diff_dir" add service.keiro
git -C "$diff_dir" -c user.name=Qualification -c user.email=qualification@example.invalid \
  -c commit.gpgsign=false commit -qm 'test: establish contract diff baseline'
cp keiro-dsl/test/fixtures/contract-declared-id-prefix-change.keiro "$diff_dir/service.keiro"
(cd "$diff_dir" && "$dsl_exe" diff service.keiro --since HEAD --explain)
```

The last command exits non-zero for the breaking prefix change and lists `IdPrefixChanged`
with a public-contract context naming the event and field. Repeat the recipe with
`structural-nominal-leaves.keiro` as the baseline and
`structural-nominal-leaves-keyed-map-key-change.keiro` as the mutant, expecting
`MappedFieldTypeChanged` on the `TemplateBook` paths. The negative keyed-map fixture is a
plain check:

```bash
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


The full plan is complete when all of the following are observable. A staged release must
meet the relevant milestone acceptance and closure gates, with omitted milestones still open.

A record field typed by a generated or consumer-bound `enum` checks, scaffolds, compiles, and
round-trips; omitting an optional enum field yields its declared constructor default; an
unknown spelling is rejected at the field path; a consumer-bound enum default is converted
from its representation constructor into the consumer domain and round-trips; a spelling change on the enum is reported by
`diff` at the event path that embeds it.

A contract event field typed by a declared `id` checks at Language 6 and fails at Language 5
with `LanguageFeatureRequiresVersion`; the generated contract payload uses the declaration's
Haskell type; the encoded JSON for `typeid "template"` and `TemplateId` (prefix `template`)
is byte-identical and `diff` calls that move consumer-build only; a prefix change on the
shared `id` is reported by `diff` with a public-contract context naming the event and field. A contract-only specification
with generated and consumer-bound IDs scaffolds and compiles without another root forcing
helper emission, and its binding/conformance inventory includes both declarations.

A guard comparing a nested identifier path with a register of the same declaration admits
and rejects correctly in the generated behavior harness; comparing two different declarations
is `AggregateGuardTypeMismatch`; ordering a nominal path is
`AggregateGuardCapabilityUnsupported`; a declarative router with `recipient = row.templateId`
compiles and dispatches; projection witness assertions for nested nominal leaves pass.

A record field `Map[TemplateId] Text` checks, pretty-prints back to itself, and round-trips
with canonical TypeID keys; a wrong-prefix key is rejected at its object-key path; an ID-keyed
map over a consumer-bound ID whose `Ord` disagrees with text order fails conformance; a
Text-keyed map becoming ID-keyed is reported by `diff` as `MappedFieldTypeChanged`.

`Optional TemplateId` as a direct command field prints the guidance message with the exact
one-field record pattern, and a documented complete declaration (including Haskell source,
binding, version, canonical identity, and fixtures) checks `OK`. The abbreviated diagnostic
is guidance rather than a complete declaration to paste verbatim.

`just verify` passes and both corpora are byte-stable across two regeneration runs.


## Idempotence and Recovery


Every step is additive to plan 287's work and can be re-run. The corpus driver refuses to run
over a dirty corpus; preserve hand-owned edits and inspect a failed regeneration in a
temporary checkout or against a saved baseline before retrying. Never hand-edit
generated modules. Because nested enums and contract declared IDs are gated on the Language 6
candidate (runtime capability and syntax feature respectively), no published language changes
and no published-language corpus may change bytes; drift in any corpus other than the ones
this plan extends is a regression. If `SelectionNominal` proves too disruptive to the
declarative router's selection identity, the recorded fallback is to accept nominal ID
columns only as `recipient` and `key` in this plan and leave `where` comparisons for a
follow-up; note the change in the Decision Log first. The explicit bracketed keyed-map grammar is fixed by this plan; a legacy parsing
regression must be repaired before shipping. If a milestone lands after Language 6 publishes,
move its new feature/capability to a successor profile and update its fixtures and docs.



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


- 2026-09-17: Completed Milestone 1 at `74b9206b`. Enum leaves now extend the landed nominal
  graph, codec, default, coverage, fingerprint, and diff authorities; generated and
  consumer-bound cases compile and round-trip in the structural-nominals corpus. Recorded
  the reused ID-default fixture, query import-planner correction, full test evidence, and
  clean-tree corpus verification. No provenance entry is added because this session already
  recorded its revision.
- 2026-09-17: Refreshed after plan 287 completed at `539a0580` and began Milestone 1.
  Replaced hypothetical resolver names with the landed `NominalLeaf`,
  `collectNominalLeaves`, `RootRef`, `nominalUsePaths`, and `RNominal` authorities; corrected
  enum default JSON/domain responsibilities and declared-spelling codecs; and made the later
  contract checked-graph threading plus router ID-literal/projection work explicit.
- 2026-09-17: Added identifier-keyed maps as Milestone 4 (the closure milestone became 5) after
  deciding the case is legitimate, recurring, and neutral to Keiki guarantees because `Map`
  is never an expression path leaf. Superseded the exclusion decision, recorded the keyed
  syntax, the distinct `RKeyedMap` constructor, the `KeyedMapSyntax` gate, and the
  consumer-bound ordering law. Containers inside contract fields remain postponed and are
  captured in `docs/research/15-containers-in-public-contract-fields.md`. The plan title is
  unchanged to keep its path stable.
- 2026-09-17: Aligned with the Codex correctness review applied to plan 287 the same day.
  Milestones 1, 2, and 4 now update the nominal diff producers and the fold fingerprint
  directly instead of assuming `nominalUses` routes contexts; the keyed-map mutation follows
  plan 287's stricter falsification standard; and the `diff` recipes use the real
  single-file `--since` form. No provenance entry is added because this session already
  recorded its revision.

- 2026-09-17: Final value/release assessment recommends staged delivery after full Plan 287,
  without holding the existing remediation release for keyed maps. Fixed the prior review's
  parser, consumer-bound enum default, and branch-schema findings; added contract-only helper
  reachability, required router fixture paths, and ID-only router typing. Kept publication
  separate from candidate delivery and preserved pending milestone status.
