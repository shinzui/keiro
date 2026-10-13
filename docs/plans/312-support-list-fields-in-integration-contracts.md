---
id: 312
slug: support-list-fields-in-integration-contracts
title: "Support list fields in integration contracts"
kind: exec-plan
created_at: 2026-10-13T15:13:00Z
intention: "intention_01m4tx3jnrevzsxfv5vwjh0344"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-13T15:13:00Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-13T23:28:57Z
      mode: "discuss"
      note: "Owner accepts the breaking ContractType API split; added plan 304 sequencing, M1 compile-at-each-step order, and three tree-checked corrections"
---

# Support list fields in integration contracts

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A `contract` declaration in the Keiro DSL is the public schema of the Kafka messages a
service publishes to, or consumes from, other systems. Today a contract event field can
be one of exactly four scalar types: `typeid "prefix"`, the name of a declared `id`,
`text`, or `int`. Private aggregate events, by contrast, can carry `List X`. A service whose
public message must name several entities at once therefore cannot keep that message in the
DSL at all: it hand-writes the payload type and its JSON codec, loses the generated
`Contract` module, and loses `keiro-diff` evolution reporting for the whole event.

After this plan, a source that declares `language keiro-dsl 6` can write

```keiro
contract uiEvents {
  schemaVersion 1
  discriminator messageType
  topic uiEvents "notification-renderer.ui-events.v1"
  event NotificationTypeChanged on uiEvents {
    typeId: NotificationTypeId
    templateIds: List TemplateId
    messagePosition: text
  }
}
```

and `keiro-dsl check` accepts it, `keiro-dsl scaffold` generates a record field
`templateIds :: ![Nominals.TemplateId]` whose codec writes a JSON array in list order and
decodes strictly with every element checked by the same TypeID admission as a scalar
`TemplateId` field, and `keiro-diff` classifies a change of the element type, a change of
the element's prefix, or a change between a scalar and a list on one wire key as public
contract evolution. A source on stable Language 5 that writes `List` in a contract field is
refused with the stable `LanguageFeatureRequiresVersion` diagnostic, and nested containers
are refused with a stable parse message. Nothing else about contracts changes: `Optional`,
`Map`, records, and unions stay out of contracts.

This plan resolves improvement request IR-54,
`docs/improvement-requests/support-list-fields-in-integration-contracts.md`, raised by the
consumer `mori://tan/notification-render-service`, and it is the revisit that research
note RES-18, `docs/research/15-containers-in-public-contract-fields.md`, asked for.


## Progress

- [ ] M1. Move IR-54 to `in-progress` (frontmatter `status`, body Status, log entry).
- [ ] M1. Split `ContractType` into `ContractScalarType` and `ContractType` in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`; add `contractScalar` and `contractIsList`. Land this first with no producer of `CList`: the full build and every existing suite must pass before the lowering and the parser.
- [ ] M1. Add `ContractListFieldSyntax` to `LanguageFeature` and to `profileV5` in `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`.
- [ ] M1. Parse `List <scalar>` in `pContractType` (`keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs`), gate it, and refuse nested containers with a stable message.
- [ ] M1. Print `List <scalar>` in `docContractType` (`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`).
- [ ] M1. Update every scalar-only match site through `contractScalar`: `Validate.hs`, `IdDomain.hs`, `Manifest.hs`, `TypeGraph.hs`, `Diff.hs`, `Scaffold.hs`, `test/Main.hs`.
- [ ] M1. Lower list fields in `emitContractGen` (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`): record type, array encoder, `parseContractList` decoder and its imports.
- [ ] M1. Add fixtures `keiro-dsl/test/fixtures/contract-list-fields.keiro` and `contract-list-fields-language5.keiro`; register them in the fixture inventory test.
- [ ] M1. Update `keiro-dsl/test/Keiro/Dsl/FrontendProfiles.hs` (minimum version map, `allFeatures`, `FeatureCase`, feature body).
- [ ] M1. Write the ADR (handle from `okf id next`), add its log entry, and record the revisit outcome in RES-18.
- [ ] M1. `nix develop -c cabal build all --enable-tests --enable-benchmarks` passes; `check`, `pretty`, Language 5 refusal, and nested refusal behave as specified.
- [ ] M2. Add `ContractListFieldUsedAsKey` to `DiagnosticCode`; refuse a list field as publisher `outboxId` and as intake `dedupe` key.
- [ ] M2. Add diff fixtures `contract-list-fields-element-change.keiro`, `contract-list-fields-scalar-shape.keiro`, `contract-list-fields-literal-to-declared.keiro`, `contract-list-fields-prefix-change.keiro`; register them.
- [ ] M2. Add unit tests in `keiro-dsl/test/Main.hs`: lowering text, id-domain rows, binding use sites, nested refusal, key refusals, diff classification.
- [ ] M2. `nix develop -c cabal test keiro-dsl:test:keiro-dsl-test` passes.
- [ ] M3. Create the compiled corpus `keiro-dsl/test/conformance-contract-list-fields/` (scaffold, hand-owned `Domain.hs` and `Bindings.hs`, `Main.hs`), add its Cabal stanza and `conformance-baseline.json` entry.
- [ ] M3. `keiro-dsl-corpus-regen -- regenerate --only …` is a no-op, the new suite passes, `scripts/check-conformance-corpus.sh` passes, `nix develop -c just verify` passes.
- [ ] M4. Update `docs/user/keiro-dsl-integration.md`, `docs/user/keiro-dsl-reference.md`, `docs/user/keiro-dsl-validation-and-evolution.md`, `docs/user/log.md`; `just user-documentation-validate` passes.
- [ ] M4. Record the change in `keiro-dsl/CHANGELOG.md` and `CHANGELOG.md` under `[Unreleased]`.
- [ ] M4. Move IR-54 to `completed` with `completedAt` and `resolution`; log it; distill ADRs; write Outcomes & Retrospective.
- [ ] Release. Ship in the next keiro-dsl release per the shared release convention; tick this box with the version; notify the consumer (see Milestone 4).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Implement RES-18's Option B, restricted to `List`. A contract field may be
  `List <scalar>` where the scalar is one of the four existing contract types. `Optional`,
  `Map`, nested lists, records, and unions are not admitted, and contract fields do not
  reference `mapped structural` declarations (RES-18's Option C).
  Rationale: RES-18 recommended Option B once a producer brought a public event that cannot
  be flattened without loss; IR-54 is that event (one Kafka message must name every template
  one domain event touched because the gateway emits one tick per entity). Option C would
  make consumer-owned binding provenance a public compatibility fact, the opposite of ADR 12.
  The consumer asked for exactly a list and listed everything else as not requested.
  Date: 2026-10-13

- Decision: Represent the grammar as two types, `ContractScalarType` (the former four
  constructors `CTypeId`, `CDeclaredId`, `CText`, `CInt`) and
  `ContractType = CScalar ContractScalarType | CList ContractScalarType`, with helpers
  `contractScalar :: ContractType -> ContractScalarType` and `contractIsList`.
  Rationale: nesting becomes unrepresentable instead of a validator promise, and GHC's
  incomplete-pattern warnings lead the implementer to every site that must now decide
  between "same as the scalar" and "list-specific". Adding a recursive `CList ContractType`
  would compile the same number of sites while permitting `List List`.
  Date: 2026-10-13

- Decision: Gate the syntax with a new `LanguageFeature`, `ContractListFieldSyntax`, added
  to syntax profile 5, which is candidate Language 6. No new runtime capability and no new
  language number.
  Rationale: Language 6 is still the registered candidate (`languageRegistry` in
  `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` marks `version6` as `Candidate`), and the
  registry comment says a pre-release candidate is amended in place. The feature adds new
  syntax only; no existing generated code or persisted data changes meaning, so no runtime
  capability is needed. Declared contract IDs (plan 288) set this precedent.
  Date: 2026-10-13

- Decision: Decoding is strict in every direction. A non-array value is rejected at the
  field path; an element that fails the element parser is rejected at `$.<wireKey>[<index>]`;
  a missing key is rejected exactly as a missing scalar field is today. An empty array is a
  valid value. Encoding writes the list in order.
  Rationale: Every generated contract field is required today ("generated contract codecs
  decode every declared body field as required", `docs/user/keiro-dsl-integration.md`).
  Treating a missing key as an empty list would be the first optional contract field and
  would need the language-neutral null-versus-missing policy RES-18 lists as undecided. The
  producer always writes the key, possibly as `[]`. IR-54 left this policy to Keiro and
  asked for it to be stated; it is stated here and in the documentation.
  Date: 2026-10-13

- Decision: A list field is not an identity. A publisher `outboxId stable from <field>`
  and an intake `dedupe <field>` that name a list field are refused with a new diagnostic
  code `ContractListFieldUsedAsKey`. The emit `key` clause gets no new rule.
  Rationale: Outbox identity and dedupe identity must be scalar. The emit `key` is
  descriptive (`docs/user/keiro-dsl-integration.md`: "`source`, `key`, and the map's
  discriminant name are descriptive … their values are not field-resolution programs"), so
  there is nothing to resolve against; the documentation states that a list field is not a
  key. This satisfies IR-54's request that validation refuse a list used as a key.
  Date: 2026-10-13

- Decision: Evolution classification. A change between a scalar and a list on one wire key,
  or a change of the element type, is `ContractFieldChanged` and breaking for public
  consumers. A `List typeid "p"` to `List DeclaredId` move with the same prefix is the
  existing build-only advisory. An element prefix or admission change is reported through
  the existing `IdPrefixChanged` (facet `nominal-contract`) and
  `ContractTypeIdDomainChanged` findings because the list element shares the field's
  id-domain identity row.
  Rationale: These are the rules a direct field already has; the list adds the shape
  dimension and nothing else.
  Date: 2026-10-13

- Decision: Compose the element decoder exactly as the private structural codec does
  (`keiro-dsl/src/Keiro/Dsl/MappedCodecPlan.hs`, line 152): parse the value as
  `[Value]`, then `traverse` the element parser with `<?> Index i`. Do not add a `vector`
  dependency to generated contract modules.
  Rationale: The generated contract module's dependency list is `aeson` and `text` (plus
  `keiro-core` and `mmzk-typeid` for typed IDs) per `keiro-dsl/src/Keiro/Dsl/Manifest.hs`,
  and consumers in other languages see only a JSON array either way.
  Date: 2026-10-13

- Decision: Record the architecture decision as a new ADR in `docs/adr/` during Milestone 1,
  with `originatingPlan` pointing at this plan, and leave RES-18 as the record of the options
  with a revisit note rather than retiring it.
  Rationale: RES-18 says to record the outcome as an ADR when the decision is taken. The
  options analysis stays useful for the day `Optional` or `Map` is requested.
  Date: 2026-10-13

- Decision: Breaking the keiro-dsl library API is acceptable for this change. The split of
  `Keiro.Dsl.Grammar.ContractType` ships as a PVP-major keiro-dsl release with a
  "Breaking Changes" changelog entry, and no compatibility shim or pattern synonyms are
  added for the old constructors.
  Rationale: The owner stated on 2026-10-13 that breaking changes are welcome now because
  the APIs are being finalised before 1.0 (the same stance ADR-49 records for the language
  and runtime surfaces). A shim would preserve the very shape this plan removes.
  Date: 2026-10-13

- Decision: Sequence this plan before plan 304's Language 6 finalisation milestone, and
  inside Milestone 1 land the type split first with no producer of `CList`, then the
  scaffold lowering, then the parser and its gate.
  Rationale: The gate relies on Language 6 still being an amendable candidate; if plan 304
  finalises Language 6 first, the syntax must move to a new candidate and this plan is
  re-planned. Within Milestone 1, each step compiles and passes the existing suites, which
  keeps the tree releasable between commits and makes concurrent edits to `Scaffold.hs` and
  `Validate.hs` by other sessions easier to rebase.
  Date: 2026-10-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

### Vocabulary

The **Keiro DSL** is the `.keiro` specification language implemented by the `keiro-dsl`
package in this repository (`keiro-dsl/`). Its command-line tool `keiro-dsl` has `check`
(parse and validate), `pretty` (print canonical source), `scaffold` (generate Haskell
modules), and the separate `keiro-diff` evolution report. Run it from the repository root
with `nix develop -c cabal run -v0 keiro-dsl -- <command>`.

A **language version** is selected by the first line of a source, `language keiro-dsl N`.
Language 5 is the published stable contract; Language 6 is the registered **candidate**,
accepted for authoring and still amendable in place (`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`,
`languageRegistry`). Each language owns a **syntax profile**, a set of `LanguageFeature`
values; Language 6 uses `profileV5`. The parser calls `requireLanguageFeatureAt` (in
`keiro-dsl/src/Keiro/Dsl/Parser/Core.hs`) when it meets gated syntax, and on an older
language that raises the stable diagnostic `LanguageFeatureRequiresVersion` at the token.

A **contract** node declares public event names, topic aliases, a `schemaVersion`, a
`discriminator`, and flat payload fields. Its grammar lives in
`keiro-dsl/src/Keiro/Dsl/Grammar.hs` (`ContractType`, `ContractField`, `ContractEvent`,
`ContractNode`, near line 1063) and its parser in
`keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs` (`pContract`, `pContractField`,
`pContractType`, lines 19 to 72). The parser already uses `requireLanguageFeatureAt` for
`ContractDeclaredIdSyntax` so that a declared `id` name is accepted only at Language 6.
The private type language of aggregates and read models is `TypeExpr` in the same
`Grammar.hs` (lines 258 to 272, with `TList`); contracts do not use it, and its `List`
spelling is parsed in `keiro-dsl/src/Keiro/Dsl/Parser/Mapped.hs`, line 307, as
`keyword "List" *> pTypeArgument`. This plan copies the spelling, not the machinery.

**Scaffolding** a contract is done by `emitContractGen` in
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (lines 3830 to 4030). It emits one module
`<Prefix>.<Contract>.Contract` containing a record per event, a payload sum type, topic
constants, `encode<Payload> :: Payload -> Value`, and `parse<Payload> :: Value -> Either Text Payload`.
The relevant locals are `contractValueType` (Haskell type per field, line 3928),
`encodeField` and `decodeField` (lines 3995 to 4010), `hasTypedTypeIds`,
`hasLiteralTypedTypeIds`, `usesPlainFieldDecode` (which import lines to emit), and
`declaredLeaves` (which generated helpers to import). A field of a declared `id` is
encoded and parsed by **nominal leaf helpers**, `encode<Name>Leaf :: T -> Value` and
`parse<Name>Leaf :: Value -> Parser T`, generated into `<Prefix>.Structural.NominalLeaves`
(see `keiro-dsl/test/conformance-contract-declared-id/Generated/ContractDeclaredId/Structural/NominalLeaves.hs`).
A `typeid "prefix"` field is encoded with `KindID.toText` and parsed with
`parseKindIdV7Value @"prefix"` from `keiro-core/src/Keiro/Codec/IdDomain.hs` (line 166),
whose type is `Value -> Parser (KindID prefix)`. Both helper families are therefore
element parsers that a list decoder can apply per element.

The **type graph** (`keiro-dsl/src/Keiro/Dsl/TypeGraph.hs`) collects every place a declared
`id` is used as a **nominal root site**; `contractSites` (lines 932 to 942) records contract
fields as `RootContractField` so that `NominalLeaves` generation and
`keiro-dsl/src/Keiro/Dsl/StructuralConformance.hs` reachability (line 122) include them.
**Id-domain identity rows** are ledger lines such as
`id-domain|name=contract:templates.TemplateClaimed.templateId|contract=keiro-dsl/id-domain/typeid-v7/1|prefix=template|…`
produced by `idDomainIdentitiesForService` in `keiro-dsl/src/Keiro/Dsl/IdDomain.hs`
(lines 85 to 107); they name the admission policy of each public ID field.
`keiro-dsl/src/Keiro/Dsl/Manifest.hs` (`hasTypedContractId`, line 212) decides whether a
generated contract module depends on `keiro-core` and `mmzk-typeid`.

**Validation** is `keiro-dsl/src/Keiro/Dsl/Validate.hs`. `DiagnosticCode` is a
`Bounded`, `Enum` type (contract codes near lines 488 to 490, publisher codes near line
559); `diagnosticOrigin` (line 640) defaults any unlisted code to `CheckDiagnostic`, and
the test "round-trips every stable diagnostic code spelling" (`keiro-dsl/test/Main.hs`,
line 1157) proves every code's text spelling. Contract rules `typeIdPrefixErrors` and
`declaredIdErrors` are at lines 2425 to 2470. `intakeCoupling` (lines 3561 to 3650)
resolves an intake's `dedupe` key and `bind` rows against `resolvableFields`;
`validatePublisher` (lines 3700 to 3740) resolves `outboxId stable from <field>` against
`allowedOutboxFields`, which includes every field of every mapped contract event. Many
rules are gated on `enforcesSpecSurfaceClosures languageContract`, which is true for the
languages this plan touches.

**Evolution** is `keiro-dsl/src/Keiro/Dsl/Diff.hs`. `contractPairDiff` (line 2725) pairs
old and new fields; `fieldTypeChange` (line 2825) reports a changed `valueType` as breaking
`ContractFieldChanged`, except a `typeid`-to-declared move with the same prefix
(`isLiteralDeclaredTransition`, line 2841, and `contractTypePrefix`, line 2887), which is
a build-only advisory. `renderContractType` (line 2881) spells a type in reports.
`contractFieldIdDomain` (line 898) and `renderContractIdDomainChange` (line 921) report
`ContractTypeIdDomainChanged` when a field's admission policy changes with an equal type.
`publicBreakingCodes` (line 474) lists the codes that take the public-breaking
compatibility vector. The nominal root-site diff reports a declared ID's prefix change on a
contract field as `IdPrefixChanged` with facet `nominal-contract` (see the test at
`keiro-dsl/test/Main.hs`, line 9555).

The **pretty printer** `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` has `docContractType`
(lines 684 to 687). Canonical printing must round-trip through the parser.

The **conformance corpus** is the set of `keiro-dsl/test/conformance-*` directories holding
committed `scaffold` output plus hand-owned fills and a `Main.hs`, each wired as a Cabal
`test-suite` in `keiro-dsl/keiro-dsl.cabal` and listed in
`keiro-dsl/test/conformance-baseline.json`. `keiro-dsl/test/README.md` explains the
regeneration driver `keiro-dsl-corpus-regen` and the drift check
`scripts/check-conformance-corpus.sh`, both part of `just verify`. The closest precedent for
this plan is `keiro-dsl/test/conformance-contract-declared-id/` (Cabal stanza at line 1273,
baseline entry at line 47, fixture `keiro-dsl/test/fixtures/contract-declared-id.keiro`),
added by plan 288 in commit `6effec8d`, which is also the best map of every file a new
contract field type touches.

**OKF bundles** are the documentation directories validated by `okf`: improvement requests
(`docs/improvement-requests/`, profile `mori/improvement-requests-profile.dhall`), research
(`docs/research/`, profile `docs/research/profile.dhall`), ADRs (`docs/adr/`, profile
`docs/adr/profile.dhall`), and user documentation (`docs/user/`, `docs/guides/`, profile
`mori/user-documentation-profile.dhall`). Each has a reserved `log.md` that `okf log add`
appends to, and each is validated by a `just` recipe or the commands in Concrete Steps.

### The request and the research it reopens

IR-54 (`docs/improvement-requests/support-list-fields-in-integration-contracts.md`) was
filed by the consumer `mori://tan/notification-render-service` on 2026-10-07 and merged
as pull request #8 on 2026-10-13. Its change signal must name every template one event
touched: a publication displaces a holder (two templates), a retirement archives all of a
type's templates, and the gateway emits one tick per changed entity. The consumer's
private events already carry `claimChanges : List AssignmentChange` (project-relative
`notification-renderer-domain/domain/notification-type.keiro`, lines 252 and 326) but its
contract cannot carry `templateIds: List TemplateId`, so plan 17 of that project
(project-relative `docs/plans/17-publish-admin-change-signals-to-kafka-through-the-keiro-outbox.md`)
hand-writes the payload codec. Artifact-level `mori://` URIs for those files are pending;
the project URI above is canonical.

Validation on 2026-10-13 against master after 0.20.0.0 reproduced the gap. With the
scratch source from Purpose / Big Picture saved as `contract-list-field.keiro`:

```text
$ cabal run -v0 keiro-dsl -- check contract-list-field.keiro
contract-list-field.keiro:14:5:
   |
14 |     messagePosition: text
   |     ^
unexpected 'm'
expecting "as", "haskell", or ':'
```

The parser consumed `List` as a declared-id name, took `TemplateId` as the start of the
next field, and failed on the field after it. The same source with `templateIds: TemplateId`
prints `OK`. Today's grammar therefore has no spelling for a list, and the failure is not
even a validation diagnostic.

RES-18 (`docs/research/15-containers-in-public-contract-fields.md`, 2026-09-17) recorded
this decision as deliberately postponed. It describes three options: A, keep contracts
flat (the current state, completed by plan 288's declared-ID fields); B, containers of
scalars inside the contract emitter; C, route contract fields through the structural type
graph. It recommends postponing until "a producer has a concrete public event that cannot
be flattened without loss", then preferring B, and recording the outcome as an ADR. It
lists five questions to decide first; this plan answers them in the Decision Log: public
contracts stay expressible without Keiro (no Option C); the null-versus-missing policy is
avoided by admitting no `Optional` and rejecting a missing key; element admission rejects
the whole event and reports the element path; the evolution table is the existing one plus
the shape dimension; and a JSON array of scalars renders as an `array` of the element
schema under JSON Schema or Avro, so the schema-registry framing anticipated by
`docs/user/integration-events.md` is not constrained.

### Architecture decision records consulted

- `docs/adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md`
  (ADR-12) separates wire authority from consumer build provenance and distinguishes an
  absent key from a present `null` for private structural records. This plan keeps that
  separation by refusing Option C and avoids the nullability question by admitting no
  `Optional` in contracts.
- `docs/adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md`
  (ADR-13) labels public contracts "not-applicable (separately owned grammar)" in coverage
  reports. Option B keeps the contract grammar separately owned, so that label stays true;
  the new ADR records that the separately owned grammar now admits lists of scalars.
- `docs/adr/0021-direct-fields-have-independent-dsl-selector-and-wire-identities.md`
  (ADR-21): contract fields have a DSL name, an optional `haskell` selector, and an
  optional `as "wire-key"`. A list field uses all three unchanged.
- `docs/adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md`
  (ADR-49): Language 6 is the pre-1.0 baseline and is finalised at a later release
  boundary; until then it is the candidate this plan amends in place. New positive fixtures
  select Language 6. Plan 304
  (`docs/plans/304-retire-legacy-language-and-runtime-compatibility-before-keiro-1-0.md`)
  finalises Language 6 in its Milestone 2, which had not started on 2026-10-13; this plan's
  Milestone 1 must land before that, or the gate moves to the next candidate and this plan
  is re-planned.

No cross-repository ADR applies. The consumer's own plan 17 is evidence, not a decision
record for this repository.


## Plan of Work

The work is four milestones. The first makes the language accept, print, and lower list
fields and records the decision; the second proves validation and evolution rules with unit
tests; the third compiles and runs the generated code in a committed conformance corpus; the
fourth documents the feature, updates changelogs and bundles, and hands off to the consumer.
Each milestone ends in a commit that carries the trailers
`ExecPlan: docs/plans/312-support-list-fields-in-integration-contracts.md` and
`Intention: intention_01m4tx3jnrevzsxfv5vwjh0344`.

### Milestone 1: the language accepts, prints, and lowers list fields

At the end of this milestone the build passes, `keiro-dsl check` accepts a Language 6
contract with list fields of every admitted element type, `keiro-dsl pretty` prints them
back as `List <scalar>`, the Language 5 copy fails with `LanguageFeatureRequiresVersion`
pointing at `List`, a nested container fails with one stable message, and `scaffold` emits
the list lowering shown below. The ADR exists and validates. Begin by moving IR-54 to
`in-progress`: set `status: in-progress` in its frontmatter, say so in its body Status
section, and run `okf log add docs/improvement-requests --kind Update -m "IR-54 implementation started under ExecPlan 312."`.

Work in three compiling steps and commit after each. First split the type and update every
match site; nothing yet produces a `CList`, so the build, every test suite, and the corpus
drift check must pass unchanged. Second add the scaffold lowering for `CList`, still with no
parser producing it. Third add the parser branch, the language feature, the pretty printer
arm, the fixtures, and the frontend-profile tests. The compiler drives the first step: after
the type change, every old match on `ContractType` is a type error until it chooses between
"same as the scalar" and "list-specific".

**Grammar.** In `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, replace the single `ContractType`
with

```haskell
-- | A scalar contract field type: @typeid "inc"@, a declared ID, @text@, or @int@.
data ContractScalarType = CTypeId !Text | CDeclaredId !Name | CText | CInt
  deriving stock (Eq, Show, Generic)

-- | A contract field type: a scalar, or a list of one scalar (ExecPlan 312, IR-54).
-- Nesting is unrepresentable by construction.
data ContractType = CScalar !ContractScalarType | CList !ContractScalarType
  deriving stock (Eq, Show, Generic)

contractScalar :: ContractType -> ContractScalarType
contractScalar (CScalar scalar) = scalar
contractScalar (CList scalar) = scalar

contractIsList :: ContractType -> Bool
contractIsList CList {} = True
contractIsList CScalar {} = False
```

and export `ContractScalarType (..)`, `contractScalar`, and `contractIsList` beside
`ContractType (..)` in the module export list (line 113). Then build; every site that
matched the old constructors on a `ContractType` is now a type error, and the list below
tells you what each one becomes.

**Language feature.** In `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`, add
`ContractListFieldSyntax` as the last constructor of `LanguageFeature` (after
`ExplicitIdAdmissionDomainSyntax`, near line 416) and insert it into `profileV5` (line 322)
with another `Set.insert`. Do not touch `profileV4`, any runtime profile, or the registry.

**Parser.** In `keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs`, import
`ContractListFieldSyntax` beside `ContractDeclaredIdSyntax` and rewrite `pContractType`
so that the `List` keyword is tried first, gated, and followed by one scalar:

```haskell
    pContractType =
      choice
        [ do
            listKeyword <- withOwnedSpan (try (keyword "List"))
            requireLanguageFeatureAt context ContractListFieldSyntax (spanOf listKeyword)
            CList <$> pContractScalarType,
          CScalar <$> pContractScalarType
        ]
    pContractScalarType =
      choice
        [ CTypeId <$> (keyword "typeid" *> stringLit),
          CText <$ keyword "text",
          CInt <$ keyword "int",
          do
            offset <- getOffset
            declaredId <- withOwnedSpan ident
            when (locatedValue declaredId `elem` reservedContainerWords) $
              failAt offset nestedContainerMessage
            requireLanguageFeatureAt context ContractDeclaredIdSyntax (spanOf declaredId)
            pure (CDeclaredId (locatedValue declaredId))
        ]
    reservedContainerWords = ["List", "Optional", "Map", "Set"]
    nestedContainerMessage =
      "contract field types admit typeid \"prefix\", text, int, a declared id, or List of one of those; nested containers, Optional, Map, and records are not supported in public contracts"
```

`failAt :: Int -> String -> P a` (`keiro-dsl/src/Keiro/Dsl/Parser/Core.hs`, line 165) takes
a megaparsec source offset, not a span, so capture `getOffset` (from `Text.Megaparsec`,
already imported) before `ident` and pass it. `withOwnedSpan`, `spanOf`, and `locatedValue`
are exported by the same `Parser/Core.hs` (export list, lines 20 to 57); `when` needs
`Control.Monad`. The requirement is a stable message at the offending token. Because the gate is checked before the
declared-id branch, a Language 5 source fails at `List`, not at the element name. The
words in `reservedContainerWords` are reserved only in the contract type position; a
declared id named `Listing` still parses because `keyword` requires a word boundary.

**Pretty printer.** In `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`, line 684, replace
`docContractType` with a function on `ContractType` that prints `"List" <+> docContractScalar s`
for `CList s` and `docContractScalar s` for `CScalar s`, where `docContractScalar` is the
old four-way function.

**Sites that only need the scalar.** Each of these keeps its behaviour and reads the
scalar through `contractScalar`:

- `keiro-dsl/src/Keiro/Dsl/Validate.hs`, `typeIdPrefixErrors` (line 2439) and
  `declaredIdErrors` (line 2457): change `CTypeId prefix <- [(.valueType) field]` to
  `CTypeId prefix <- [contractScalar ((.valueType) field)]`, and likewise for
  `CDeclaredId`. Keep the messages unchanged so existing diagnostics stay stable.
- `keiro-dsl/src/Keiro/Dsl/IdDomain.hs`, `contractFieldAdmission` (line 103): match on
  `contractScalar ((.valueType) field)`. The id-domain row for a list field keeps the
  `contract:<contract>.<event>.<field>` name; it describes the admission of the field's
  elements.
- `keiro-dsl/src/Keiro/Dsl/Manifest.hs`, `hasTypedContractId` (line 214): match on the
  scalar. A list of typed IDs needs `keiro-core` and `mmzk-typeid` exactly as a scalar does.
- `keiro-dsl/src/Keiro/Dsl/TypeGraph.hs`, `contractSites` (line 940): bind
  `CDeclaredId nominalName <- [contractScalar ((.valueType) field)]` so a list of a
  declared id is a nominal root site and its leaf helpers are generated and reachable.
- `keiro-dsl/src/Keiro/Dsl/Diff.hs`: `contractFieldIdDomain` (line 899),
  `renderContractIdDomainChange` (line 926), and `contractTypePrefix` (line 2887) match on
  the scalar. `renderContractType` (line 2881) becomes
  `renderContractType (CScalar s) = renderContractScalar s` and
  `renderContractType (CList s) = "List " <> renderContractScalar s`, where
  `renderContractScalar` is the old function. `isLiteralDeclaredTransition` (line 2841)
  must require the same shape on both sides: `(CScalar CTypeId {}) (CScalar CDeclaredId {})`,
  `(CScalar CDeclaredId {}) (CScalar CTypeId {})`, `(CList CTypeId {}) (CList CDeclaredId {})`,
  `(CList CDeclaredId {}) (CList CTypeId {})` are `True`; everything else is `False`. With
  that, `fieldTypeChange` already reports a scalar-to-list change and an element-type change
  as breaking `ContractFieldChanged` with the detail
  `field type changed List text -> List int`, and no new change code is needed.
- `keiro-dsl/src/Keiro/Dsl/Workspace.hs`, line 1410, `instance HasLocs ContractType`:
  give `ContractScalarType` the same location-free instance and cover both `ContractType`
  constructors; the compiler reports this site among the first.
- `keiro-dsl/test/Main.hs` wherever it constructs or matches `ContractType` values (the
  compiler lists them).

**Scaffold lowering.** In `emitContractGen` (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`):

- `declaredLeaves` (line 3899) binds `CDeclaredId name <- [contractScalar ((.valueType) field)]`.
- `isTypedTypeId`, `isLiteralTypedTypeId` (lines 3961 to 3965, and the copies in
  `emitPayloadAdt` at 4025) take the scalar. Define
  `isPlainScalar (CScalar scalar) = not (isTypedTypeId scalar)` and
  `isPlainScalar CList {} = False`, and make `usesPlainFieldDecode` use it, because a list
  field never decodes through `(.:)`.
- `contractValueType` becomes a function on `ContractType`:
  `contractValueType (CScalar s) = contractScalarType s` and
  `contractValueType (CList s) = "[" <> contractScalarType s <> "]"`, where
  `contractScalarType` is the old four-way function (so a declared id lowers to
  `[Nominals.TemplateId]`, a typed `typeid` to `[KindID "template"]`, `text` to `[Text]`,
  `int` to `[Int]`).
- `encodeField`: for `CScalar s` keep the current cases. For `CList s`, when the element has
  an encoder (`KindID.toText` for a typed `typeid`, `renderedDeclaredLeafHelper "encode" name`
  for a declared id) emit `<wireKey> .= map <encoder> payload.<selector>`; for `text`,
  `int`, and an untyped `typeid` emit `<wireKey> .= payload.<selector>`.
- `decodeField`: for `CScalar s` keep the current cases. For `CList s` emit
  `explicitParseField (parseContractList <element>) o <wireKey>` where `<element>` is
  `(parseKindIdV7Value @"prefix")` for a typed `typeid`,
  `renderedDeclaredLeafHelper "parse" name` for a declared id, and `parseJSON` otherwise.
- Add `hasListFields = any (any (contractIsList . (.valueType)) . (.fields)) ((.events) c)`.
  When it is true, add `parseJSON` to the `Data.Aeson` import list (line 3840), change
  `aesonTypesImport` to also import `JSONPathElement (Index)` and `(<?>)`, and append this
  helper after `validateMessageType` at the end of the module:

```haskell
parseContractList :: (Value -> Parser a) -> Value -> Parser [a]
parseContractList element value = do
  items <- parseJSON value :: Parser [Value]
  traverse (\(index, item) -> element item <?> Index index) (zip [0 :: Int ..] items)
```

  Emit none of this when no field is a list, because generated output compiles under
  `-Wall` and an unused import would warn.

For the Milestone 3 fixture, the generated `Generated/ContractListFields/Templates/Contract.hs`
must contain these lines (whitespace aside):

```haskell
data TemplatesReassignedData = TemplatesReassignedData {typeId :: !Nominals.TemplateId, templateIds :: ![Nominals.TemplateId], claimIds :: ![ClaimId], legacyTemplateIds :: ![KindID "template"], labels :: ![Text], positions :: ![Int]}
        "templateIds" .= map NominalLeaves.encodeTemplateIdLeaf payload.templateIds,
        "claimIds" .= map NominalLeaves.encodeClaimIdLeaf payload.claimIds,
        "legacyTemplateIds" .= map KindID.toText payload.legacyTemplateIds,
        "labels" .= payload.labels,
        "positions" .= payload.positions
                    <*> explicitParseField (parseContractList NominalLeaves.parseTemplateIdLeaf) o "templateIds"
                    <*> explicitParseField (parseContractList NominalLeaves.parseClaimIdLeaf) o "claimIds"
                    <*> explicitParseField (parseContractList (parseKindIdV7Value @"template")) o "legacyTemplateIds"
                    <*> explicitParseField (parseContractList parseJSON) o "labels"
                    <*> explicitParseField (parseContractList parseJSON) o "positions"
```

**Fixtures.** Create `keiro-dsl/test/fixtures/contract-list-fields.keiro`:

```keiro
language keiro-dsl 6
context contract-list-fields

id TemplateId prefix=template

id ClaimId prefix=claim using {
  haskell package=keiro-dsl module=Conformance.ContractListFields.Domain type=ClaimId
  binding = "Conformance.ContractListFields.Bindings.claimIdBinding"
  binding-version = "1"
  canonical-type = "conformance.contract-list-fields.ClaimId.v1"
  fixtures = "Conformance.ContractListFields.Bindings.claimIdFixtures"
}

contract templates {
  schemaVersion 1
  discriminator messageType

  topic templateEvents "templates.events"

  event TemplatesReassigned on templateEvents {
    typeId: TemplateId
    templateIds: List TemplateId
    claimIds: List ClaimId
    legacyTemplateIds: List typeid "template"
    labels: List text
    positions: List int
  }
}
```

and `keiro-dsl/test/fixtures/contract-list-fields-language5.keiro`, a copy that declares
`language keiro-dsl 5`, context `contract-list-fields-language5`, only the generated
`TemplateId`, and one field `templateIds: List TemplateId`. The test "keeps only the named
source-version and candidate fixtures outside published Language 4" in
`keiro-dsl/test/Main.hs` (near line 1920) enumerates every fixture that is not Language 4;
add both names there in sorted position.

**Frontend profile tests.** In `keiro-dsl/test/Keiro/Dsl/FrontendProfiles.hs`: add
`ContractListFieldSyntax -> version 6` to the minimum-version case (line 82 area), append
`ContractListFieldSyntax` to `allFeatures` (line 374), add
`FeatureCase ContractListFieldSyntax "List" (featureBody ContractListFieldSyntax)` after
the `ContractDeclaredIdSyntax` case (line 209), and add a `featureBody` arm (near line 297)
that is the declared-id body with the field `profileIds: List ProfileId`. The marker `"List"`
tells the harness which token the Language 5 failure must point at.

**ADR and RES-18.** Allocate the handle with
`okf id next docs/adr --profile docs/adr/profile.dhall ADR` (it printed `ADR-51` on
2026-10-13; use whatever it prints when you run it) and create
`docs/adr/00NN-integration-contracts-admit-lists-of-scalar-fields.md` following the
frontmatter of `docs/adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md`
(`type`, `title`, `description`, `timestamp`, `docId`, `status: Accepted`, `date`,
`originatingPlan: docs/plans/312-support-list-fields-in-integration-contracts.md`). Its
Context names RES-18, IR-54, and the consumer; its Decision states Option B restricted to
`List`, the admitted element types, the JSON array representation in list order, strict
decoding with element paths, the missing-key rejection, the empty-array admission, the
evolution table, the refusal of list fields as outbox or dedupe identity, and the explicit
exclusion of `Optional`, `Map`, nesting, records, unions, and structural references; its
Consequences state that the contract grammar remains separately owned (ADR-13's coverage
label is unchanged), that non-Keiro consumers implement an array of the element scalar,
that JSON Schema and Avro both render it as an array of the element schema, and that any
future `Optional` must first settle RES-18's null-versus-missing question. Then run
`okf log add docs/adr --kind Addition -m "ADR-NN admits List fields of scalar types in integration contracts (Option B of RES-18) for IR-54."`
and the strict ADR validation in Concrete Steps. In
`docs/research/15-containers-in-public-contract-fields.md`, extend the "Revisit" section
that this plan's creation added so that it names the ADR, advance `timestamp`, and run
`okf log add docs/research --kind Update -m "RES-18 outcome recorded as ADR-NN."`.

Acceptance for Milestone 1: the full build passes; `check` on the Language 6 fixture prints
`OK`; `check` on the Language 5 copy prints an `error [LanguageFeatureRequiresVersion]`
whose location is the `List` token; `pretty` on the fixture prints each list field as
`List <scalar>` and `check` accepts the printed text; a scratch source with
`templateIds: List List TemplateId` fails with a message containing "nested containers";
every existing test suite still passes; the ADR and research bundles validate strictly.

### Milestone 2: validation and evolution rules are proven

At the end of this milestone, a list field used as an identity is refused with a stable
code, every diff classification from the Decision Log has a fixture and a passing test, and
the lowering text and ledger rows are asserted by unit tests.

**Diagnostic code.** In `keiro-dsl/src/Keiro/Dsl/Validate.hs`, add
`ContractListFieldUsedAsKey` to `DiagnosticCode` directly after `ContractTypeIdDomainChanged`
(line 490) with the comment `-- ExecPlan 312 / IR-54: list fields are values, never identities.`
No origin mapping is needed because `diagnosticOrigin` defaults to `CheckDiagnostic`, and
the spelling round-trip test at line 1157 covers the new code automatically.

**Publisher rule.** In `validatePublisher` (line 3700), compute

```haskell
    listContractFields emitNode =
      [ (.dslName) (resolveContractFieldIdentity field)
      | contract <- specContracts spec,
        (.name) contract == (.contract) emitNode,
        event <- (.events) contract,
        (.name) event `elem` map (.event) ((.map) emitNode),
        field <- (.fields) event,
        contractIsList ((.valueType) field)
      ]
```

exclude those names from `allowedOutboxFields`, and emit, before the existing unresolved
rule and gated the same way,

```text
publisher '<p>' outboxId field '<f>' is a List field of an event mapped by emit '<e>'; outbox identity must be messageId, idempotencyKey, or a scalar contract field
```

with code `ContractListFieldUsedAsKey`. Make the unresolved rule skip a name that the list
rule reported so one mistake yields one diagnostic.

**Intake rule.** In `intakeCoupling` (line 3561), exclude list fields of accepted events
from `resolvableFields` for the dedupe check only, and emit
`intake '<i>' dedupe key '<f>' is a List field of accepted event '<ev>'; dedupe identity must be a scalar envelope or event field`
with code `ContractListFieldUsedAsKey`, again before the unresolved rule and skipping the
unresolved rule for that name. `bind` rows are descriptive today (their flags raise
`IntakeBindFlagUnenforced`), so a bind row naming a list field is unchanged.

**Diff fixtures.** Beside the base fixture, add four one-line mutants of
`contract-list-fields.keiro` and register them in the fixture inventory test:
`contract-list-fields-element-change.keiro` changes `labels: List text` to
`labels: List int`; `contract-list-fields-scalar-shape.keiro` changes
`templateIds: List TemplateId` to `templateIds: TemplateId`;
`contract-list-fields-literal-to-declared.keiro` changes
`legacyTemplateIds: List typeid "template"` to `legacyTemplateIds: List TemplateId`;
`contract-list-fields-prefix-change.keiro` changes `id TemplateId prefix=template` to
`id TemplateId prefix=project`.

**Unit tests.** In `keiro-dsl/test/Main.hs`, beside the declared-id tests (line 7958 and
line 9555), add:

- "lowers list fields of every admitted element type": scaffold the base fixture with
  `scaffoldServiceModules`, take the module whose path ends in `Templates/Contract.hs`, and
  assert it contains each line shown in Milestone 1 and the `parseContractList` helper;
  assert the `Structural/NominalLeaves.hs` module exists and defines
  `parseTemplateIdLeaf` and `parseClaimIdLeaf`; assert `validateService service` is empty;
  assert `idDomainIdentitiesForService service` contains the rows for
  `contract:templates.TemplatesReassigned.templateIds` (prefix `template`),
  `…claimIds` (prefix `claim`), and `…legacyTemplateIds` (prefix `template`); assert the
  binding obligations for `ClaimId` include the use site
  `contract templates event TemplatesReassigned .claimIds : ClaimId` (the use-site text
  names the nominal, not the field shape: the site text comes from
  `keiro-dsl/src/Keiro/Dsl/TypeGraph.hs`, line 1183, and the existing declared-id test at
  `keiro-dsl/test/Main.hs`, line 7983, asserts the same `.claimId : ClaimId` form).
- "refuses nested containers in contract fields": `parseSource` on an inline Language 6
  source with `templateIds: List List TemplateId` is `Left` and the rendered failure
  contains "nested containers".
- "refuses a list element that is not a declared id": inline source with
  `enum Channel { Email=email }` and `channels: List Channel` yields exactly one
  `ContractIdUnknown` whose message contains "is an enum".
- "refuses list fields as outbox and dedupe identity": extend the Language 6 fixture
  inline with an `emit` mapping `TemplatesReassigned`, a `publisher` with
  `outboxId stable from templateIds`, and an `intake` accepting `TemplatesReassigned` with
  `dedupe templateIds`; the error codes contain `ContractListFieldUsedAsKey` exactly twice
  and contain neither `PublisherOutboxFieldUnresolved` nor `IntakeDedupeKeyUnresolved`. Use
  the existing emit, publisher, and intake fixtures (for example the hospital-capacity
  sources near line 7117) as the syntax reference.
- "classifies list field evolution": with `diffFixtures` from the base to
  `-element-change`, the breaking codes contain `ContractFieldChanged` and a finding's detail
  contains `List text -> List int`; from the base to `-scalar-shape`, breaking codes contain
  `ContractFieldChanged` with detail `List TemplateId -> TemplateId`; from the base to
  `-literal-to-declared`, there is no breaking `ContractFieldChanged` and exactly one
  advisory `ContractFieldChanged` whose `PublicConsumer` verdict is `VNotApplicable` and
  whose `ConsumerBuild` verdict is `VAdvisory`; from the base to `-prefix-change`, the
  breaking findings include `IdPrefixChanged` with facet `nominal-contract` and a subject
  ending in `.templateIds`, with `PublicConsumer` verdict `VBreaking`.
- Language gate: `runKeiroDsl ["check", "test/fixtures/contract-list-fields-language5.keiro"]`
  exits with failure and its stderr contains `LanguageFeatureRequiresVersion`.

Acceptance for Milestone 2: `nix develop -c cabal test keiro-dsl:test:keiro-dsl-test --test-show-details=direct`
passes, including the new tests, the spelling round-trip test, the fixture inventory
test, and the frontend-profile tests.

### Milestone 3: the generated code compiles and round-trips in a committed corpus

At the end of this milestone, `keiro-dsl/test/conformance-contract-list-fields/` holds the
scaffolded output of the base fixture, a hand-owned `Conformance/ContractListFields/Domain.hs`
and `Conformance/ContractListFields/Bindings.hs` (copy
`keiro-dsl/test/conformance-contract-declared-id/Conformance/ContractDeclaredId/Domain.hs`
and `Bindings.hs`, renaming the module and the `canonical-type` string to the fixture's
values), and a `Main.hs` that proves the codec. The suite is wired as
`test-suite keiro-dsl-conformance-contract-list-fields` in `keiro-dsl/keiro-dsl.cabal`
(copy the `keiro-dsl-conformance-contract-declared-id` stanza at line 1273, rename the
directory and the `other-modules`), and `keiro-dsl/test/conformance-baseline.json` gains,
after the line for `keiro-dsl-conformance-contract-declared-id`:

```json
    {"component": "keiro-dsl-conformance-contract-list-fields", "directory": "test/conformance-contract-list-fields", "source": "test/fixtures/contract-list-fields.keiro", "generation": "source", "role": "candidate-primary", "languageVersion": 6, "reason": "candidate Language 6 List fields of declared, consumer-bound, literal TypeID, text, and int elements in a public contract"},
```

`Main.hs` builds a `TemplatesReassigned` payload with two template ids, one claim id, one
legacy id, two labels, and two positions, and checks, printing `PASS`/`FAIL` lines and
exiting non-zero on any failure as the declared-id `Main.hs` does:

- encoding equals the expected `object` whose `templateIds`, `claimIds`, and
  `legacyTemplateIds` members are JSON arrays of canonical TypeID text in list order, whose
  `labels` is an array of strings, and whose `positions` is an array of numbers;
- `parseTemplatesPayload (encodeTemplatesPayload payload) == Right payload`, and the same
  for a payload whose every list is empty, whose encoding carries `[]` for each list member;
- reversing `templateIds` produces a different encoding and decodes back in the reversed
  order;
- a `templateIds` member that is a string (not an array) decodes to `Left` whose message
  mentions `$.templateIds`;
- a `templateIds` array whose second element is `claim_…` decodes to `Left` whose message
  mentions `$.templateIds[1]`;
- an object without the `templateIds` member decodes to `Left` whose message mentions
  `templateIds`;
- `structuralConformanceAssertions` from the generated `StructuralConformance` module all
  hold (contract-only nominal helper reachability, as in the declared-id suite).

Create the directory once with the CLI, then let the driver own it:

```bash
nix develop -c cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/contract-list-fields.keiro --out keiro-dsl/test/conformance-contract-list-fields
```

The scaffold writes the generated modules, the hole skeleton for `Bindings.hs`, the ledger
`keiro-dsl-ledger.context.contract-list-fields.txt`, and the Cabal fragment. Fill the hole,
add `Domain.hs` and `Main.hs`, add the Cabal stanza and the baseline entry, and then run
the regeneration driver for this directory only and the drift check; both must report no
change.

Acceptance for Milestone 3: the new test suite passes; the regeneration driver is a no-op
on a clean tree; `scripts/check-conformance-corpus.sh` passes; `nix develop -c just verify`
passes end to end (read the exit code from inside the log, because `just verify` stops at
the first failure).

### Milestone 4: documentation, changelogs, bundles, and consumer handoff

At the end of this milestone a reader of the user documentation can learn the feature
without this plan, the changelogs announce it, IR-54 is completed, and the consumer knows
what to change.

In `docs/user/keiro-dsl-integration.md` (DOC-29), add a row to the contract field type
table (line 46) reading `List <scalar>` (Language 6 candidate), generated type "a Haskell
list of the element's generated type; JSON array in declaration order", and after the
declared-id paragraph (line 86) add a paragraph with a `keiro` example using
`templateIds: List TemplateId`, stating: the element is one of the four scalar types;
nested containers, `Optional`, `Map`, and records are refused; the decoder rejects a
non-array at the field path, a bad element at `$.field[index]`, and a missing key, while
`[]` is valid; a list field cannot be a publisher `outboxId` or an intake `dedupe` key
(`ContractListFieldUsedAsKey`); and changing between a scalar and a list or changing the
element type is a breaking public change while an equal-prefix literal-to-declared move of
the element is build-only. Update the page's `generated.at` to the edit time and keep
`generated.by` as the process that edits it. In `docs/user/keiro-dsl-reference.md`
(DOC-23), add a row "List fields in public contracts" to the Language 6 feature table (line
42) linking to the integration page's contract section. In
`docs/user/keiro-dsl-validation-and-evolution.md` (DOC-34), mention the new code where the
intake and publisher surfaces are listed (line 87 area) if that page enumerates codes;
otherwise leave it. Append the log entry with
`okf log add docs/user --kind Update -m "Document List fields in integration contracts (Language 6 candidate): element types, codec policy, identity refusal, and evolution rules."`
and run `nix develop -c just user-documentation-validate`.

In `keiro-dsl/CHANGELOG.md` under `## [Unreleased]`, add a "Breaking Changes" entry that
`Keiro.Dsl.Grammar.ContractType` is now `CScalar ContractScalarType | CList ContractScalarType`
and the former constructors live on `ContractScalarType`, and an "Added" entry that
candidate Language 6 contracts accept `List <typeid | declared id | text | int>` fields
(`ContractListFieldSyntax`), lowered to a Haskell list and a JSON array, with the new
diagnostic `ContractListFieldUsedAsKey`, resolving IR-54. In the root `CHANGELOG.md` under
`## [Unreleased]`, add one line pointing at the keiro-dsl entry. Do not pick a version
number; the release that ships this follows the shared release convention and the
registry, and the person releasing records the version in the Progress release item.
Because the `ContractType` split is a breaking library change, that release is a PVP-major
bump of keiro-dsl with no compatibility shim (Decision Log). Before publishing, list the
library consumers with `mori registry dependents shinzui/keiro --packages` and tell each one
that imports `Keiro.Dsl.Grammar` (kotei-core's development dependency and the keiro-syntax
automation among them) what changed.

Move IR-54 to `completed`: set `status: completed`, `completedAt`, and a `resolution`
sentence in its frontmatter, update the body Status section, advance `timestamp`, and run
`okf log add docs/improvement-requests --kind Update -m "IR-54 completed under ExecPlan 312: …"`.
Validate with the improvement-request command in Concrete Steps.

Consumer handoff (outside this repository; record that it was sent, not done): tell the
owner of `mori://tan/notification-render-service` that, once the keiro-dsl release carrying
this change is published, plan 17 of that project can declare
`templateIds: List TemplateId` in its `integration.keiro`, delete the hand-owned payload
codec, re-scaffold, and run `keiro-diff`; if the diff reports the new event as a public
change the project raises its contract epoch per its own convention. Also check
`mori://shinzui/keiro-syntax` (the editor grammar fed by the keiro-dsl automation) for the
`List` spelling in the contract field position and note any follow-up there.

Finally write Outcomes & Retrospective and perform the ADR distillation pass: if
implementation taught anything durable beyond the ADR written in Milestone 1 (for example
a generated-code import rule), update that ADR in the same change.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` inside the
Nix development shell. Enter it once with `nix develop` or prefix each command with
`nix develop -c`. Confirm the shell first:

```bash
nix develop -c z3 --version
```

Build everything, including tests, after each milestone's edits:

```bash
nix develop -c cabal build all --enable-tests --enable-benchmarks
```

Milestone 1 checks:

```bash
nix develop -c cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/contract-list-fields.keiro
nix develop -c cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/contract-list-fields-language5.keiro
nix develop -c cabal run -v0 keiro-dsl -- pretty keiro-dsl/test/fixtures/contract-list-fields.keiro
nix develop -c cabal run -v0 keiro-dsl -- pretty keiro-dsl/test/fixtures/contract-list-fields.keiro > /tmp/pretty.keiro && nix develop -c cabal run -v0 keiro-dsl -- check /tmp/pretty.keiro
```

Expected: the first prints `OK`; the second exits non-zero and prints a line containing
`error [LanguageFeatureRequiresVersion]` whose column points at `List`; the third prints
the six fields with `List TemplateId`, `List ClaimId`, `List typeid "template"`,
`List text`, and `List int`; the fourth prints `OK`.

ADR and research bundle validation (Milestone 1 and whenever those bundles change):

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
okf validate docs/research --strict --profile docs/research/profile.dhall --profile-enforce --log-enforce
```

Improvement-request bundle validation (whenever IR-54 changes):

```bash
okf validate docs/improvement-requests --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
```

Expected: `OK: 54 concepts`.

Milestone 2 tests (the focused run first, then the whole suite):

```bash
nix develop -c cabal test keiro-dsl:test:keiro-dsl-test --test-show-details=direct --test-options='--match "list field"'
nix develop -c cabal test keiro-dsl:test:keiro-dsl-test --test-show-details=direct
```

Milestone 3 corpus:

```bash
nix develop -c cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/contract-list-fields.keiro --out keiro-dsl/test/conformance-contract-list-fields
nix develop -c cabal run -v0 keiro-dsl-corpus-regen -- regenerate --only keiro-dsl/test/conformance-contract-list-fields
git status --short -- keiro-dsl/test
nix develop -c cabal test keiro-dsl:test:keiro-dsl-conformance-contract-list-fields --test-show-details=direct
nix develop -c scripts/check-conformance-corpus.sh
nix develop -c just verify 2>&1 | tee /tmp/verify.log; tail -3 /tmp/verify.log
```

Expected: after the first scaffold and your hand-owned fills are committed, the
regeneration run changes nothing and `git status` lists nothing under `keiro-dsl/test`; the
suite prints seven `PASS` lines; the corpus check and `just verify` exit zero.

Milestone 4 documentation:

```bash
okf log add docs/user --kind Update -m "Document List fields in integration contracts (Language 6 candidate): element types, codec policy, identity refusal, and evolution rules."
nix develop -c just user-documentation-validate
```

Commit after each milestone with Conventional Commits and both trailers, for example:

```text
feat(dsl): accept List fields of scalar types in integration contracts

Split ContractType into ContractScalarType and a CScalar/CList shape, gate
the List spelling on ContractListFieldSyntax in candidate Language 6, print
it canonically, and lower it to a Haskell list with an ordered JSON array
codec whose element parsers are the existing scalar helpers.

ExecPlan: docs/plans/312-support-list-fields-in-integration-contracts.md
Intention: intention_01m4tx3jnrevzsxfv5vwjh0344
```


## Validation and Acceptance

The plan is complete when all of the following hold on a clean checkout.

Authoring: a Language 6 source with the `NotificationTypeChanged` event from Purpose / Big
Picture passes `keiro-dsl check` with `OK`. The same source on Language 5 fails with
`LanguageFeatureRequiresVersion` at `List`. A source with `List List TemplateId` fails with
a message containing "nested containers". A source with `List Channel` where `Channel` is an
enum fails with `ContractIdUnknown` and "is an enum".

Generated code: `keiro-dsl scaffold` on that source produces a `Contract` module with
`templateIds :: ![Nominals.TemplateId]`, an encoder line
`"templateIds" .= map NominalLeaves.encodeTemplateIdLeaf payload.templateIds`, a decoder
line `explicitParseField (parseContractList NominalLeaves.parseTemplateIdLeaf) o "templateIds"`,
and the `parseContractList` helper. The committed corpus compiles it and proves, in a
running Haskell program, that

```json
{"messageType":"NotificationTypeChanged","typeId":"notification_type_01h455vb4pex5vsknk084sn02q","templateIds":["template_01h455vb4pex5vsknk084sn02q","template_01h455vb4pex5vsknk084sn02r"],"messagePosition":"7"}
```

round-trips with the two template ids in that order, that `"templateIds":[]` round-trips,
that `"templateIds":"template_…"` is rejected at `$.templateIds`, that a wrong-prefix second
element is rejected at `$.templateIds[1]`, and that a payload without `templateIds` is
rejected. (The corpus uses the fixture's `TemplatesReassigned` event; the shape is the same.)

Identity: a publisher whose `outboxId` and an intake whose `dedupe` name a list field each
produce one `ContractListFieldUsedAsKey` error and no unresolved-field error.

Evolution: `keiro-diff` between the base fixture and each mutant reports the classification
in the Decision Log, and the unit tests assert the codes, facets, subjects, and verdicts.

Repository gates: `nix develop -c just verify` passes; the four OKF bundles validate with
their strict commands; `okf validate docs/improvement-requests …` reports IR-54 as
`completed`.


## Idempotence and Recovery

Every source edit is an ordinary file change under version control; re-running a build or
test is safe. `keiro-dsl scaffold --out` never overwrites a create-once hole module and only
overwrites generated modules that carry the `@generated` banner, so re-running it over the
corpus directory is safe; the regeneration driver refuses to run on a dirty corpus, so
commit or `git stash` first. If a regeneration changes bytes unexpectedly, inspect
`git diff -- keiro-dsl/test` and either accept the change (it means the generator changed)
or `git checkout -- keiro-dsl/test` to recover. `okf log add` appends; if you add a log entry
twice, delete the duplicate line by hand before validating. `okf id next` is read-only; if
another ADR lands first, re-run it and rename your file to the new handle before committing.
Each milestone is a separate commit so a failed milestone can be reverted alone.


## Interfaces and Dependencies

Milestone 1 ends with these definitions in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`:

```haskell
data ContractScalarType = CTypeId !Text | CDeclaredId !Name | CText | CInt
data ContractType = CScalar !ContractScalarType | CList !ContractScalarType
contractScalar :: ContractType -> ContractScalarType
contractIsList :: ContractType -> Bool
```

and in `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` a new `LanguageFeature` constructor
`ContractListFieldSyntax`, present in `profileV5` and therefore reported by
`languageFeatureMinimumVersion ContractListFieldSyntax == version6`. Generated contract
modules that contain a list field define

```haskell
parseContractList :: (Value -> Parser a) -> Value -> Parser [a]
```

and import `parseJSON` from `Data.Aeson` and `JSONPathElement (Index)` and `(<?>)` from
`Data.Aeson.Types`; their package dependencies are unchanged (`aeson`, `text`, and for typed
IDs `keiro-core` and `mmzk-typeid`, per `keiro-dsl/src/Keiro/Dsl/Manifest.hs`).

Milestone 2 ends with a new `DiagnosticCode` constructor `ContractListFieldUsedAsKey` in
`keiro-dsl/src/Keiro/Dsl/Validate.hs`, raised by `validatePublisher` and `intakeCoupling`.
No new `ChangeCode` is added in `Diff.hs`; `renderContractType` and
`isLiteralDeclaredTransition` are shape-aware.

Milestone 3 ends with the Cabal test suite `keiro-dsl-conformance-contract-list-fields`
depending on `aeson`, `base`, `keiki`, `keiro`, `keiro-core`, `keiro-dsl`, `mmzk-typeid`,
and `text` as the declared-id suite does.

External libraries: `aeson` for `Value`, `Parser`, `explicitParseField`, `parseJSON`,
`JSONPathElement`, and `(<?>)`; `mmzk-typeid` for `KindID`; `keiro-core` for
`parseKindIdV7Value`. No new dependency is added to any package.


## Revision Notes

- 2026-10-13 (discuss): After a risk review the owner confirmed that breaking the keiro-dsl
  library API is acceptable because the APIs are being finalised before 1.0, so the
  `ContractType` split ships without a shim and the release handoff lists library consumers.
  Recorded the sequencing constraint against plan 304's Language 6 finalisation and a
  compile-at-each-step order inside Milestone 1. Corrected three details found while
  checking the plan against the tree: `failAt` takes a megaparsec offset, the
  `HasLocs ContractType` instance in `Workspace.hs` is a match site, and binding use-site
  text names the nominal (`: ClaimId`) rather than the field shape.
