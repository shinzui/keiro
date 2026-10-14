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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-14T01:10:14Z
      mode: "update"
      note: "Correct admission-aware evolution, envelope-key precedence, parser/gate cases, corpus registration, CLI validation, and observable acceptance after correctness review."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-14T04:06:31Z
      mode: "implement"
      note: "Implement list contract fields, strict generated codecs, validation, evolution and conformance coverage."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-14T01:07:58Z
      verdict: "changes-requested"
      note: "Initial correctness review: same-prefix ID transitions must compare admission domains; clarify envelope-key precedence, isolate the List gate, and track corpus sidecars before regeneration."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-14T01:12:53Z
      verdict: "approved"
      note: "Follow-up review of revised plan: initial findings addressed; repository/API paths, admission semantics, identity precedence, corpus sequencing, and document checks verified. Implementation remains pending."
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
`Contract` module, and loses `keiro-dsl diff` evolution reporting for the whole event.

After this plan, a source that declares `language keiro-dsl 6` can write

```keiro
language keiro-dsl 6
context notification-changes

id NotificationTypeId prefix=notification_type
id TemplateId prefix=template

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
`TemplateId` field, and `keiro-dsl diff` classifies a change of the element type, a change of
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

- [x] (2026-10-14 01:08Z) Correctness review completed and plan revised; reproduced the admission-transition gap in a Nix-shell probe. Implementation has not started.
- [x] (2026-10-14 04:08Z) M1. Move IR-54 to `in-progress` (frontmatter `status`, body Status, log entry).
- [x] (2026-10-14 04:23Z) M1. Split `ContractType` into `ContractScalarType` and `ContractType` in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`; add `contractScalar` and `contractIsList`. Land this first with no producer of `CList`: the full build and every existing suite must pass before the lowering and the parser.
- [x] (2026-10-14 04:45Z) M1. Add `ContractListFieldSyntax` to `LanguageFeature` and to `profileV5` in `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`.
- [x] (2026-10-14 04:45Z) M1. Parse `List <scalar>` in `pContractType` (`keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs`), gate it, and refuse nested containers with a stable message.
- [x] (2026-10-14 04:23Z) M1. Print `List <scalar>` in `docContractType` (`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`).
- [x] (2026-10-14 04:08Z) M1. Update every scalar-only match site through `contractScalar`: `Validate.hs`, `IdDomain.hs`, `Manifest.hs`, `TypeGraph.hs`, `Diff.hs`, `Scaffold.hs`, `Workspace.hs`, `test/Main.hs`.
- [x] (2026-10-14 04:08Z) M1. Require equal resolved ID admission domains for the literal-to-declared advisory; M2 proves widened/narrowed admission and both shape-change directions.
- [x] (2026-10-14 04:30Z) M1. Lower list fields in `emitContractGen` (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`): record type, array encoder, `parseContractList` decoder and its imports.
- [x] (2026-10-14 04:45Z) M1. Add fixtures `keiro-dsl/test/fixtures/contract-list-fields.keiro` and `contract-list-fields-language5.keiro`; register them in the fixture inventory test.
- [x] (2026-10-14 04:45Z) M1. Update `keiro-dsl/test/Keiro/Dsl/FrontendProfiles.hs` (minimum version map, `allFeatures`, `FeatureCase`, feature body).
- [x] (2026-10-14 04:23Z) M1. Write the ADR (handle from `okf id next`), add its log entry, and record the revisit outcome in RES-18.
- [x] (2026-10-14 04:45Z) M1. `nix develop -c cabal build all --enable-tests --enable-benchmarks` passes; `check`, `pretty`, Language 5 refusal, and nested refusal behave as specified.
- [x] (2026-10-14 05:03Z) M2. Add `ContractListFieldUsedAsKey` to `DiagnosticCode`; refuse a list field as publisher `outboxId` and as intake `dedupe` key.
- [x] (2026-10-14 05:03Z) M2. Add diff fixtures `contract-list-fields-element-change.keiro`, `contract-list-fields-scalar-shape.keiro`, `contract-list-fields-literal-to-declared.keiro`, `contract-list-fields-prefix-change.keiro`, and `contract-list-fields-admission-change.keiro`; register them.
- [x] (2026-10-14 05:03Z) M2. Add unit tests in `keiro-dsl/test/Main.hs`: lowering text, id-domain rows, binding use sites, nested refusal, aliases, envelope-key precedence, multi-event key refusals, and diff classification.
- [x] (2026-10-14 05:07Z) M2. `nix develop -c cabal test keiro-dsl:test:keiro-dsl-test` passes.
- [ ] M3. Create the compiled corpus `keiro-dsl/test/conformance-contract-list-fields/` (scaffold, hand-owned `Domain.hs` and `Bindings.hs`, `Main.hs`), add its Cabal stanza and `conformance-baseline.json` entry; force-add the ignored ledger and Cabal fragment, then commit the corpus before regeneration.
- [ ] M3. `keiro-dsl-corpus-regen -- regenerate --only …` is a no-op, the new suite passes, `scripts/check-conformance-corpus.sh` passes, `nix develop -c just verify` passes.
- [ ] M4. Update `docs/user/keiro-dsl-integration.md`, `docs/user/keiro-dsl-reference.md`, `docs/user/keiro-dsl-validation-and-evolution.md`, `docs/user/log.md`; `just user-documentation-validate` passes.
- [ ] M4. Record the change in `keiro-dsl/CHANGELOG.md` and `CHANGELOG.md` under `[Unreleased]`.
- [ ] M4. Move IR-54 to `completed` with `completedAt` and `resolution`; log it; distill ADRs; write Outcomes & Retrospective.
- [ ] Release. Ship in the next keiro-dsl release per the shared release convention; tick this box with the version; notify the consumer (see Milestone 4).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation (2026-10-14): prefix equality does not imply equal TypeID admission.
  `contractPairDiff.fieldTypeChange` in `keiro-dsl/src/Keiro/Dsl/Diff.hs` currently
  compares only prefixes for literal/declared transitions, while
  `contractTypeIdDomainChanges` visits only fields whose `valueType` is unchanged.
  A `nix develop -c cabal exec -- runghc -package=keiro-dsl` probe kept
  `id TemplateId prefix=template domain=typeid-v5-or-v7` unchanged on both sides and
  changed only a scalar field from `typeid "template"` to `TemplateId`. `diffSources`
  returned only `Advisory ContractFieldChanged`, with `PublicConsumer = VNotApplicable`,
  incorrectly claiming admission was unchanged. Milestone 1 must correct this shared
  predicate before extending it to lists; Milestone 2 must prove both directions.
- Observation (2026-10-14): `keiro-dsl/tools/corpus-regen/src/CorpusPlan.hs` discovers
  corpus entries through `git ls-files`; `.gitignore` excludes scaffold ledgers and Cabal
  fragments. `keiro-dsl/test/README.md` requires force-adding both. The driver in
  `keiro-dsl/tools/corpus-regen/src/Main.hs` also requires clean corpus paths before
  ordinary regeneration, so the initial corpus must be committed first.
- Observation (2026-10-14): the review assumed case-insensitive keywords; implementation found that
  `Parser/Core.hs` actually aliases its misleading `string'` name to case-sensitive
  `chunk`. `Validate.hs` resolves canonical envelope names independently of event fields. The new
  parser refusal must recognize keyword casing, and a payload list must not invalidate a
  canonical envelope identity with the same spelling.


- Observation (2026-10-14 implementation): `Parser/Core.hs:145-147` aliases
  `string'` to case-sensitive `chunk`; the review's assumption of case-insensitive
  keywords was incorrect. Use a contract-local case-insensitive container keyword
  parser with the same identifier boundary for List and forbidden containers. This
  preserves global keyword behavior and makes the specified mixed-case refusals stable.


- Observation (2026-10-14 implementation): the compatibility renderer in
  `LanguageVersion.hs:489-494` deliberately hard-codes column 1 because
  `SourceLanguageDiagnostic` retains only a line (`Loc`). The Language 5 CLI probe
  prints `contract-list-fields-language5.keiro:11:1`, while `withOwnedSpan` retains
  the exact List token in `FrontendFailure.span`. Test the exact frontend span;
  preserve the byte-compatible facade rather than broaden this feature into a
  diagnostic API redesign.


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
  Canonical envelope names retain precedence: `messageId` and `idempotencyKey` for
  publishers, and `canonicalIntakeEnvelopeFields` for intakes. A non-envelope name that
  denotes a list in any selected event is refused once per clause, even if another
  selected event has a scalar of that name.
  Rationale: Outbox identity and dedupe identity must be scalar. The emit `key` is
  descriptive (`docs/user/keiro-dsl-integration.md`: "`source`, `key`, and the map's
  discriminant name are descriptive … their values are not field-resolution programs"), so
  there is nothing to resolve against; the documentation states that a list field is not a
  key. This satisfies IR-54's request that validation refuse a list used as a key.
  Date: 2026-10-13; envelope precedence clarified 2026-10-14.

- Decision: Evolution classification. A change between a scalar and a list on one wire key,
  or a change of the element type, is `ContractFieldChanged` and breaking for public
  consumers. A `List typeid "p"` to `List DeclaredId` move is a build-only advisory only
  when shape, prefix, and resolved ID admission domain are all equal. The same requirement
  applies to scalar literal/declared transitions. A changed admission domain is public
  breaking in either direction, even when prefixes agree. An element prefix or admission
  change is reported through the existing `IdPrefixChanged` (facet `nominal-contract`) and
  `ContractTypeIdDomainChanged` findings because the list element shares the field's
  id-domain identity row. When the type spelling changes too, use breaking
  `ContractFieldChanged`; the existing `ContractTypeIdDomainChanged` path remains for
  unchanged type spelling with changed admission.
  Rationale: ADR-46 requires both widening and narrowing to be breaking. Correct the
  existing scalar exception while adding the list shape dimension.
  Date: 2026-10-13; admission condition corrected 2026-10-14.

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


- Decision: Preserve the released line-only compatibility CLI diagnostic format.
  Require the Language 5 refusal on the correct field line and prove the exact List
  token and column in the structured frontend span instead.
  Rationale: The working tree explicitly preserves byte-identical compatibility
  diagnostics; the plan's CLI-column assertion assumed a field the facade does not
  contain. Adding a column to that public API is unrelated to list support.
  Date: 2026-10-14


## Outcomes & Retrospective

Milestone 1 completed on 2026-10-14. The grammar separates scalar facts from field
shape; candidate Language 6 accepts and prints List fields of every admitted scalar;
scaffolding emits ordered arrays and strict required-field decoders with indexed element
errors. The first type-split and lowering steps each passed the full build, every existing
suite, and unchanged corpus regeneration before the parser produced lists. The syntax
step passed the full build and every DSL suite (806 unit examples), including profile
and fixture inventories. Compiled CLI checks inside Nix accepted the base fixture and
pretty round-trip and refused Language 5 and nested/mixed-case containers. ADR-52 records
the decision; ADR-46 now explicitly requires admission equality for build-only ID moves.

Milestone 2 implementation and its eight focused tests now pass: identity keys are
refused once per clause with envelope precedence, aliases and import selection are preserved,
and both shape and admission evolution directions are classified correctly. The full unit
suite passed: 814 examples, 0 failures, including stable diagnostic spelling and fixture
inventories. The compiled list corpus remains Milestone 3. User documentation and changelogs are drafted and their
validation passed, but IR-54 remains in progress until implementation gates close.
Release publication and downstream communication remain the separate Release item.


## Context and Orientation

### Vocabulary

The **Keiro DSL** is the `.keiro` specification language implemented by the `keiro-dsl`
package in this repository (`keiro-dsl/`). Its command-line tool `keiro-dsl` has `check`
(parse and validate), `pretty` (print canonical source), `scaffold` (generate Haskell
modules), and `diff FILE --since GIT-REF` (report evolution against the same file at a Git
revision). Run it from the repository root
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
(`isLiteralDeclaredTransition`, line 2841, and `contractTypePrefix`, line 2887), which currently becomes
a build-only advisory without checking admission equality; this is the correctness gap
that this plan fixes. `renderContractType` (line 2881) spells a type in reports.
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
contract cannot carry `templateIds: List TemplateId`, so
`mori://tan/notification-render-service/plans/17-publish-admin-change-signals-to-kafka-through-the-keiro-outbox`
hand-writes the payload codec. The source file above is identified by the canonical project
URI plus its project-relative path; its source-file artifact URI is pending. The plan
file and frontmatter were verified on disk during this review; `mori path` did not yet
resolve its canonical plan URI in the local registry.

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

- [docs/adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
  (ADR-12) separates wire authority from consumer build provenance and distinguishes an
  absent key from a present `null` for private structural records. This plan keeps that
  separation by refusing Option C and avoids the nullability question by admitting no
  `Optional` in contracts.
- [docs/adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md](../adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md)
  (ADR-13) labels public contracts "not-applicable (separately owned grammar)" in coverage
  reports. Option B keeps the contract grammar separately owned, so that label stays true;
  the new ADR records that the separately owned grammar now admits lists of scalars.
- [docs/adr/0021-direct-fields-have-independent-dsl-selector-and-wire-identities.md](../adr/0021-direct-fields-have-independent-dsl-selector-and-wire-identities.md)
  (ADR-21): contract fields have a DSL name, an optional `haskell` selector, and an
  optional `as "wire-key"`. A list field uses all three unchanged.
- [ADR-46](../adr/0046-nominal-declarations-are-structural-leaves-with-keiro-owned-admission.md):
  a declared ID owns its admission domain; widening is an old-reader/new-writer hazard and
  narrowing is a retained-history read hazard. Both directions are breaking. The
  literal-to-declared exception must therefore compare admission as well as prefix.
- [docs/adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md](../adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md)
  (ADR-49): Language 6 is the pre-1.0 baseline and is finalised at a later release
  boundary; until then it is the candidate this plan amends in place. New positive fixtures
  select Language 6. Plan 304
  (`docs/plans/304-retire-legacy-language-and-runtime-compatibility-before-keiro-1-0.md`)
  finalises Language 6 in its Milestone 2, which had not started on 2026-10-13; this plan's
  Milestone 1 must land before that, or the gate moves to the next candidate and this plan
  is re-planned.

No cross-repository ADR applies. The consumer plan cited above is evidence, not a
decision record for this repository.


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
on the List field line, with the structured frontend span pointing at `List`, a nested container fails with one stable message, and `scaffold` emits
the list lowering shown below. The ADR exists and validates. Begin by moving IR-54 to
`in-progress`: set `status: in-progress` in its frontmatter, say so in its body Status
section, and run `okf log add docs/improvement-requests --kind Update -m "IR-54 implementation started under ExecPlan 312."`.

Work in three compiling steps and commit after each. First split the type, wrap the
existing parser results in `CScalar`, and update every match site (including total printer
and renderer arms for both constructors). Nothing yet produces a `CList`, so the build,
every test suite, and the corpus drift check must pass unchanged. Second add the scaffold
lowering for `CList`, still with no parser producing it. Third add the parser branch, the
language feature, the fixtures, and the frontend-profile tests. The pretty printer already
handles both shapes from the first step. The compiler drives the first step: after
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

**Parser.** In `keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs`, import `string'` and `char` from `Text.Megaparsec.Char` for a local
case-insensitive container keyword parser with the existing identifier boundary. Import
`ContractListFieldSyntax` beside `ContractDeclaredIdSyntax` and rewrite `pContractType`
so that the `List` keyword is tried first, gated, and followed by one scalar:

```haskell
    pContractType =
      choice
        [ do
            listKeyword <- withOwnedSpan (try (contractContainerKeyword "List"))
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
            forbidden <- optional (lookAhead (choice (map contractContainerKeyword reservedContainerWords)))
            case forbidden of
              Just () -> failAt offset nestedContainerMessage
              Nothing -> pure ()
            declaredId <- withOwnedSpan ident
            requireLanguageFeatureAt context ContractDeclaredIdSyntax (spanOf declaredId)
            pure (CDeclaredId (locatedValue declaredId))
        ]
    reservedContainerWords = ["List", "Optional", "Map", "Set"]
    nestedContainerMessage =
      "contract field types admit typeid \"prefix\", text, int, a declared id, or List of one of those; nested containers, Optional, Map, and records are not supported in public contracts"
```

`failAt :: Int -> String -> P a` (`keiro-dsl/src/Keiro/Dsl/Parser/Core.hs`, line 165) takes
a megaparsec source offset, not a span, so capture `getOffset` (from `Text.Megaparsec`,
already imported) before the forbidden-keyword check and pass it. `withOwnedSpan`, `spanOf`, and `locatedValue`
are exported by the same `Parser/Core.hs` (export list, lines 20 to 57). Check forbidden
container keywords before `ident`, using the local `contractContainerKeyword` so case-insensitive spellings such as
`List list TemplateId` and `List map text` get the same refusal. The requirement is a
stable message at the offending token. Because the gate is checked before the
declared-id branch, a Language 5 source fails at `List`, not at the element name. The
words in `reservedContainerWords` are reserved only in the contract type position; a
declared id named `Listing` still parses because the local container keyword parser requires the same word boundary.

**Pretty printer.** In `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`, line 684, replace
`docContractType` with a function on `ContractType` that prints `"List" <+> docContractScalar s`
for `CList s` and `docContractScalar s` for `CScalar s`, where `docContractScalar` is the
old four-way function.

**Scalar facts and shape-aware sites.** Reuse `contractScalar` for element facts, while
rendering and compatibility decisions retain the outer shape:

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
  Additionally, change the advisory predicate in `fieldTypeChange` to require equal,
  resolved `Just` values from `contractFieldIdDomain` for the old and new checked language
  contracts and specs. Prefix equality alone is insufficient, and `Nothing == Nothing`
  is not evidence of an equal admission policy. Read those contracts from
  `checkedLanguageContract ((.oldService) env)` and
  `checkedLanguageContract ((.newService) env)` alongside `(.old) env` and `(.new) env`. When admission differs, fall through to
  breaking `ContractFieldChanged` and include `renderIdDomainDirection` in the detail.
  This applies to scalars and lists. Leave the equal-`valueType` filter on
  `contractTypeIdDomainChanges` intact: unchanged declared-list types with changed
  admission still emit that existing domain finding.
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
  `[Nominals.TemplateId]`, a typed `typeid` to `[(KindID "template")]`, `text` to `[Text]`,
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
data TemplatesReassignedData = TemplatesReassignedData {typeId :: !Nominals.TemplateId, templateIds :: ![Nominals.TemplateId], claimIds :: ![ClaimId], legacyTemplateIds :: ![(KindID "template")], labels :: ![Text], positions :: ![Int]}
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
on the List field line, with the structured frontend span selecting the `List` token; `pretty` on the fixture prints each list field as
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

Keep `messageId` and `idempotencyKey` as independently valid envelope names. For other
names, remove list-bearing names from the mapped-field portion of `allowedOutboxFields`
and emit one error if the selected name occurs in `listContractFields`, regardless of how
many events contain it. Place this before the existing unresolved rule and gate it the
same way:

```text
publisher '<p>' outboxId field '<f>' is a List field of an event mapped by emit '<e>'; outbox identity must be messageId, idempotencyKey, or a scalar contract field
```

with code `ContractListFieldUsedAsKey`. A list field named `messageId` or `idempotencyKey`
does not shadow the canonical envelope identity. Make the unresolved rule skip a name that
the list rule reported so one mistake yields one diagnostic.

**Intake rule.** In `intakeCoupling` (line 3561), keep the original `resolvableFields`
for bind validation and introduce a separate dedupe-name check. A name in
`canonicalIntakeEnvelopeFields` stays valid even if a payload list shares it. Otherwise,
if any accepted event has a list field of that DSL name, emit one
`ContractListFieldUsedAsKey` for the intake, listing the affected events in stable order:
`intake '<i>' dedupe key '<f>' is a List field of accepted events <events>; dedupe identity must be a scalar envelope or event field`.
A scalar field of the same name in another accepted event does not cancel this refusal.
Only when no list refusal applies should the existing unresolved check run. `bind` rows are descriptive today (their flags raise
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
Also add `contract-list-fields-admission-change.keiro`, changing only the base declaration
of `TemplateId` to `id TemplateId prefix=template domain=typeid-v5-or-v7`, and register it.
For the literal/declared admission regression, use two inline checked sources that both
contain this wider declaration from the start; change only `legacyTemplateIds` from
`List typeid "template"` to `List TemplateId`. Keeping the declaration identical prevents
an unrelated nominal-domain finding from hiding a missing field compatibility check.

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
  contains "nested containers"; repeat with `List list TemplateId` and `List map text`.
- "refuses a list element that is not a declared id": inline source with
  `enum Channel { Email=email }` and `channels: List Channel` yields exactly one
  `ContractIdUnknown` whose message contains "is an enum".
- "refuses list fields as outbox and dedupe identity": extend the Language 6 fixture
  inline with an `emit` mapping `TemplatesReassigned`, a `publisher` with
  `outboxId stable from templateIds`, and an `intake` accepting `TemplatesReassigned` with
  `dedupe templateIds`; the error codes contain `ContractListFieldUsedAsKey` exactly twice
  and contain neither `PublisherOutboxFieldUnresolved` nor `IntakeDedupeKeyUnresolved`. Use
  the existing emit, publisher, and intake fixtures (for example the hospital-capacity
  sources near line 7117) as the syntax reference. Also test canonical envelope names
  sharing a spelling with a payload list (still accepted), a non-envelope DSL name shared
  by scalar and list fields across selected events (one list refusal per clause), and a
  list present only in an unselected event (no list refusal). Bind rows naming list
  payloads retain their existing behavior.
- "classifies list field evolution": with `diffFixtures` from the base to
  `-element-change`, the breaking codes contain `ContractFieldChanged` and a finding's detail
  contains `List text -> List int`; from the base to `-scalar-shape`, breaking codes contain
  `ContractFieldChanged` with detail `List TemplateId -> TemplateId`; from the base to
  `-literal-to-declared`, there is no breaking `ContractFieldChanged` and exactly one
  advisory `ContractFieldChanged` whose `PublicConsumer` verdict is `VNotApplicable` and
  whose `ConsumerBuild` verdict is `VAdvisory`; from the base to `-prefix-change`, the
  breaking findings include `IdPrefixChanged` with facet `nominal-contract` and a subject
  ending in `.templateIds`, with `PublicConsumer` verdict `VBreaking`. Run the shape and
  equal-domain literal/declared checks in both directions; also compare a scalar literal
  to a declared list and the reverse, which must be breaking despite equal prefixes.
  The inline wider-admission pair above and its reverse must produce a breaking
  `ContractFieldChanged` on `legacyTemplateIds` with `PublicConsumer = VBreaking`, never
  the build-only advisory. Repeat that pair with scalar fields to cover the shared fix.
  The admission-change fixture and its reverse must include breaking
  `ContractTypeIdDomainChanged` for `.templateIds`, with public verdict `VBreaking`.
- "keeps list field aliases and import selection": use inline variants with
  `templateIds haskell selectedTemplates as "template_ids": List TemplateId` and assert
  that the generated selector, encoder key, and `explicitParseField` key use the resolved
  identities. Scaffold a list-only primitive contract and a list plus scalar-text
  contract: both need `parseJSON`, `Index`, and `(<?>)`, but only the latter needs `(.:)`.
  Existing scalar-only golden output must remain unchanged.
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
- explicit `null` for each list or a null element in each scalar family is refused; repeated
  IDs round-trip without deduplication; wrong-prefix claim and literal-ID elements name
  their own wire key and index;
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
add `Domain.hs` and `Main.hs`, and add the Cabal stanza and baseline entry. Follow
`keiro-dsl/test/README.md`: force-add the ignored ledger and Cabal fragment, add the source,
generated modules and hand-owned fills, and commit that initial corpus before invoking
ordinary regeneration. Both the focused regeneration and drift check must then report
no change. Adding the baseline JSON entry alone does not register a corpus invocation;
the driver discovers tracked ledgers.

Acceptance for Milestone 3: the new test suite passes; the regeneration driver is a no-op
on a clean tree; `scripts/check-conformance-corpus.sh` passes; `nix develop -c just verify`
passes end to end with the actual command exit status preserved, because `just verify`
stops at the first failure.

### Milestone 4: documentation, changelogs, bundles, and consumer handoff

At the end of this milestone a reader of the user documentation can learn the feature
without this plan, the changelogs announce it, IR-54 is completed, and the consumer knows
what to change.

In `docs/user/keiro-dsl-integration.md` (DOC-29), add a row to the contract field type
table (line 46) reading `List <scalar>` (Language 6 candidate), generated type "a Haskell
list of the element's generated type; JSON array in list order", and after the
declared-id paragraph (line 86) add a paragraph with a `keiro` example using
`templateIds: List TemplateId`, stating: the element is one of the four scalar types;
nested containers, `Optional`, `Map`, and records are refused; the decoder rejects a
non-array at the field path, a bad element at `$.field[index]`, and a missing key, while
`[]` is valid; a list field cannot be a publisher `outboxId` or an intake `dedupe` key
(`ContractListFieldUsedAsKey`); and changing between a scalar and a list or changing the
element type is a breaking public change. A literal-to-declared move of the element is
build-only only when both prefix and admission domain are unchanged. Correct the existing scalar paragraph to state that same
condition, and document canonical envelope-key precedence in the identity rule. Update the
page's `generated.at` to the edit time and keep
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
that imports `Keiro.Dsl.Grammar` what changed. Discover each canonical package/project URI
through Mori rather than assuming the consumer inventory is unchanged.

Move IR-54 to `completed`: set `status: completed`, `completedAt`, and a `resolution`
sentence in its frontmatter, update the body Status section, advance `timestamp`, and run
`okf log add docs/improvement-requests --kind Update -m "IR-54 completed under ExecPlan 312: …"`.
Validate with the improvement-request command in Concrete Steps.

Consumer handoff (outside this repository; record that it was sent, not done): tell the
owner of `mori://tan/notification-render-service` that, once the keiro-dsl release carrying
this change is published, `mori://tan/notification-render-service/plans/17-publish-admin-change-signals-to-kafka-through-the-keiro-outbox`
can declare
`templateIds: List TemplateId` in its `integration.keiro`, delete the hand-owned payload
codec, re-scaffold, and run `keiro-dsl diff integration.keiro --since <pre-migration-commit>`; if the diff reports the new event as a public
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
`error [LanguageFeatureRequiresVersion]` on the List field line (the compatibility CLI renderer prints column 1); the structured frontend span selects `List`; the third prints
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

Expected: successful validation with zero errors; the concept count may grow independently.
Read IR-54 back separately to verify its status and resolution rather than inferring them
from a successful bundle validation.

Milestone 2 tests (the focused run first, then the whole suite):

```bash
nix develop -c cabal test keiro-dsl:test:keiro-dsl-test --test-show-details=direct --test-options='--match "list field"'
nix develop -c cabal test keiro-dsl:test:keiro-dsl-test --test-show-details=direct
```

Milestone 3 corpus:

```bash
nix develop -c cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/contract-list-fields.keiro --out keiro-dsl/test/conformance-contract-list-fields
# After completing the hand-owned files and Cabal/baseline edits:
git add -f keiro-dsl/test/conformance-contract-list-fields/keiro-dsl-ledger.context.contract-list-fields.txt keiro-dsl/test/conformance-contract-list-fields/keiro-dsl-cabal-fragment.context.contract-list-fields.txt
git add keiro-dsl/test/conformance-contract-list-fields keiro-dsl/test/conformance-baseline.json keiro-dsl/test/fixtures/contract-list-fields*.keiro keiro-dsl/keiro-dsl.cabal
# Commit the reviewed M3 files with the ExecPlan and Intention trailers before proceeding.
nix develop -c cabal run -v0 keiro-dsl-corpus-regen -- regenerate --only keiro-dsl/test/conformance-contract-list-fields
git status --short -- keiro-dsl/test
nix develop -c cabal test keiro-dsl:test:keiro-dsl-conformance-contract-list-fields --test-show-details=direct
nix develop -c scripts/check-conformance-corpus.sh
nix develop -c bash -o pipefail -c 'just verify 2>&1 | tee /tmp/keiro-plan312-verify.log'
```

Expected: after the first scaffold and your hand-owned fills are committed, the
regeneration run changes nothing and `git status` lists nothing under `keiro-dsl/test`; the
suite prints `PASS` for every named check and no `FAIL` lines; the corpus check and `just verify` exit zero.

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

The four implementation milestones are complete when all of the following hold on a
clean checkout. The whole plan remains open until its separate Release item is completed.

Authoring: a Language 6 source with the `NotificationTypeChanged` event from Purpose / Big
Picture passes `keiro-dsl check` with `OK`. For the Language 5 refusal probe, replace the
preceding scalar `typeId: NotificationTypeId`
with `typeId: typeid "notification_type"` before lowering the preamble to Language 5. It
then fails with `LanguageFeatureRequiresVersion` on the List field line; its structured
frontend span selects `List`. Retaining the earlier declared
scalar field would instead trip `ContractDeclaredIdSyntax` first. A source with
`List List TemplateId` fails with
a message containing "nested containers". A source with `List Channel` where `Channel` is an
enum fails with `ContractIdUnknown` and "is an enum".

Generated code: `keiro-dsl scaffold` on that source produces a `Contract` module with
`templateIds :: ![Nominals.TemplateId]`, an encoder line
`"templateIds" .= map NominalLeaves.encodeTemplateIdLeaf payload.templateIds`, a decoder
line `explicitParseField (parseContractList NominalLeaves.parseTemplateIdLeaf) o "templateIds"`,
and the `parseContractList` helper. The committed corpus compiles the analogous `TemplatesReassigned`
fixture and proves, in a running Haskell program, that

```json
{"messageType":"TemplatesReassigned","typeId":"template_01h455vb4pex5vsknk084sn02q","templateIds":["template_01h455vb4pex5vsknk084sn02q","template_01h455vb4pex5vsknk084sn02r"],"claimIds":["claim_01h455vb4pex5vsknk084sn02q"],"legacyTemplateIds":["template_01h455vb4pex5vsknk084sn02q"],"labels":["first","second"],"positions":[1,2]}
```

round-trips with the two template ids in that order, that `"templateIds":[]` round-trips,
that `"templateIds":"template_…"` is rejected at `$.templateIds`, that a wrong-prefix second
element is rejected at `$.templateIds[1]`, and that a payload without `templateIds` is
rejected. Explicit `null` for the list, or for an element of each admitted scalar type,
is rejected too; duplicates and their positions are retained. Include these cases in
the corpus checks, together with wrong-prefix consumer-bound and literal ID elements.

Identity: a publisher whose `outboxId` and an intake whose `dedupe` name a list field each
produce one `ContractListFieldUsedAsKey` error and no unresolved-field error for a
non-envelope name. Canonical envelope names remain valid despite colliding payload names,
and a scalar/list name shared across selected events yields one refusal per clause.

Evolution: `diffFixtures` compares the base and mutant files directly and asserts the
Decision Log classifications, codes, facets, subjects, and verdicts. For a CLI proof, commit
the base fixture, temporarily apply one mutant to that same path, then run
`nix develop -c cabal run -v0 keiro-dsl -- diff keiro-dsl/test/fixtures/contract-list-fields.keiro --since <base-commit>`.
The CLI compares one path against Git history, not two positional fixture paths. Restore
only that temporary edit after inspection. Changed admission is public breaking in both
directions; equal prefix alone never grants the build-only exception.

Repository gates: `nix develop -c just verify` passes; the four OKF bundles validate with
their stated validation commands; IR-54 reads back as `completed` with the implementation
resolution. Publication and the consumer handoff remain the separately tracked Release item until actually performed.


## Idempotence and Recovery

Every source edit is an ordinary file change under version control; re-running a build or
test is safe. `keiro-dsl scaffold --out` never overwrites a create-once hole module and only
overwrites generated modules that carry the `@generated` banner, so re-running it over the
corpus directory is safe; the regeneration driver refuses to run on a dirty corpus, so
commit or `git stash` first. If a regeneration changes bytes unexpectedly, inspect
`git diff -- keiro-dsl/test` and either accept the change (it means the generator changed)
or restore only the generated files changed by that run from the known clean baseline.
Never discard the entire test tree when it contains unrelated work. `okf log add` updates
the bundle log; avoid duplicate entries by checking the existing log before retrying. `okf id next` is read-only; if
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

- 2026-10-14 (update, correctness review): Required admission-domain equality for the
  literal/declared compatibility exception and added widening/narrowing and shape regressions;
  clarified canonical envelope precedence and multi-event identity refusal; made nested
  keyword refusals case-insensitive and isolated the Language 5 List gate. Corrected the
  self-contained example, generated literal-ID type assertion, CLI diff invocation, corpus
  sidecar tracking/commit order, verification exit status, and corpus acceptance JSON.
  Added null, duplicate, alias, and import-selection coverage. Implementation remains pending.

- 2026-10-14 (implement): Started IR-54, split contract shape from scalar facts without
  a List parser producer, and corrected the literal/declared advisory predicate to compare
  resolved admission. Allocated ADR-52 to preserve the public array and identity policy.

- 2026-10-14 (implement): Corrected the parser instructions after reading Core.hs: its
  keyword helper is case-sensitive despite the misleading local alias. Keep mixed-case
  container refusal local to contracts rather than altering every language keyword.

- 2026-10-14 (implement): Type-split step passed the full build, every existing suite,
  and corpus drift check before introducing a List parser producer. Added ADR-52 and
  clarified ADR-46; user documentation is drafted for the later documentation milestone.

- 2026-10-14 (implement): Verified the `List` type keyword in both Vim and TextMate
  implementations owned by `mori://shinzui/keiro-syntax`; no spelling change is needed
  there. Release and downstream adoption communication remain the separate Release item.

- 2026-10-14 (implement): List lowering passed the all-components build while no
  parser produces CList. Existing suites are running against this generator before
  enabling the new syntax. The type split was committed as `8802f372`.

- 2026-10-14 (implement): The lowering step passed the full build, every existing
  suite (806 DSL examples), and the unchanged 55-entry corpus drift check before
  any parser could produce CList. Proceeding to the language feature and fixtures.

- 2026-10-14 (implement): CLI acceptance passed for Language 6, canonical pretty
  round-trip, nested/mixed-case container refusals, and scaffold list lowering. Corrected
  the CLI column expectation: its compatibility renderer is intentionally line-only,
  while frontend spans retain the precise List token for structured consumers.

- 2026-10-14 (implement): The Language 6 gate and fixtures passed the full build;
  direct compiled CLI checks inside the Nix shell accepted the fixture and canonical
  printing, refused Language 5 and nested/mixed-case containers, and proved list lowering.
  All DSL suites are running to close Milestone 1.

- 2026-10-14 (implement): Milestone 1 is complete. The List syntax and profiles passed
  all DSL suites (806 unit examples) and the full build; CLI authoring, printing, refusal,
  and scaffold checks passed. Starting identity and evolution regression coverage.

- 2026-10-14 (implement): Added identity refusal, five registered diff mutants, and
  eight focused examples covering lowering, domains, use sites, nested containers, enum
  refusal, exact gate spans, aliases/imports, selected-event key precedence, and evolution
  in both directions. Focused run passed: 8 examples, 0 failures. Full unit run is pending.

- 2026-10-14 (implement): Milestone 2 unit acceptance passed: 814 examples, 0 failures.
  Building every component before committing the validation and evolution coverage.

- 2026-10-14 (implement): Milestone 2 also passed the all-components build.
  Identity and evolution behavior is proven and ready for the compiled corpus.
