---
id: 345
slug: let-integration-contracts-declare-optional-fields-and-an-envelope-discriminator
title: "Let integration contracts declare optional fields and an envelope discriminator"
kind: exec-plan
created_at: 2026-11-18T16:27:00Z
intention: "intention_01m7qqq7a0e8rtk6y4h0tnft3v"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-18T16:27:00Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-18T18:22:01Z
      mode: "implement"
      note: "Milestones 1-4 implemented"
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-18T20:09:35Z
      mode: "update"
      note: "Reopen implementation work in M5 with regression checks for all five review findings."
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-18T20:48:16Z
      mode: "update"
      note: "Verified all five review findings; widened the fieldless fix to body mode and changed the added-Optional verdict to consumer-build advisory."
  reviews:
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-18T20:09:35Z
      verdict: "changes-requested"
      note: "Implementation review found rollout, fieldless code generation, constructor compatibility, and two documentation defects."
---

# Let integration contracts declare optional fields and an envelope discriminator

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A keiro-dsl *integration contract* is the `contract` declaration in a `.keiro` source. It
names the public events a service exchanges with other services over Kafka, and
`keiro-dsl scaffold` turns it into a Haskell module with one record per event, an encoder
and a decoder. Today that decoder only fits events whose producer follows Keiro's own
conventions: every declared field must be present, and the JSON body must carry a key (the
*body discriminator*, usually `messageType`) that names the event.

Improvement request IR-64
([docs/improvement-requests/let-integration-contracts-describe-events-owned-by-other-producers.md](../improvement-requests/let-integration-contracts-describe-events-owned-by-other-producers.md)),
raised from `mori://tan/agent-reputation-service`, shows an event that fits neither rule.
`mori://tan/registration-service-v2` publishes `RegistrationCompleted` on the topic
`registration.completed.v1` as a bare JSON object. Two of its fields (`ownerEmail` and
`mlsMemberId`) are left out when unknown, and the event's name travels in a Kafka header,
not in the body. The consumer therefore hand-writes its payload decoder.

After this plan, a candidate Language 6 source can mirror such an event:

```keiro
language keiro-dsl 6
context registration-intake

id MemberId prefix=member

contract registration {
  schemaVersion 1
  discriminator from envelope

  topic completed "registration.completed.v1"

  event RegistrationCompleted on completed {
    registrationId: typeid "registration"
    occurredAt: text
    ownerEmail: Optional text
    mlsMemberId: Optional MemberId
  }
}
```

`keiro-dsl check` prints `OK` for it. `keiro-dsl scaffold` generates a record whose optional
fields are `Maybe` values, an encoder that writes no key for an absent value and no
discriminator key, and a decoder `parseRegistrationPayloadAs` that takes the event type from
the envelope. A committed, compiled test suite proves the behavior by running it: the bare
object `{"registrationId":"registration_…","occurredAt":"…"}` decodes with both optional
fields absent, the same object with `"ownerEmail":null` decodes the same way, and an
envelope whose `keiro-event-type` is not `RegistrationCompleted` is rejected.


## Progress

**Reopened 2026-11-18 after implementation review.** Milestone 5 is the next
implementation work. M1–M4 record the original delivery and its verification.

- [x] M1: Optional contract fields. A Language 6 contract with `Optional <scalar>` fields
  passes `keiro-dsl check`, pretty-prints back to itself, and scaffolds a `Maybe` field with
  an omit-when-absent encoder and an absent-or-null decoder. Language 5 refuses the syntax
  with `LanguageFeatureRequiresVersion`. `Optional List …` and `List Optional …` are refused.
  An optional field used as an identity is refused, and `diff` classifies every optional
  transition as decided in the Decision Log. `keiro-dsl:test:keiro-dsl-test` passes.
  Done 2026-11-18, committed with M2 because both change `Grammar.hs` records: the base
  fixture checks `OK`, both Language 5 fixtures fail with `LanguageFeatureRequiresVersion`
  on the feature's line, `pretty` output re-checks `OK`, and the suite reports 977
  examples, 0 failures.
- [x] M2: Envelope discriminator. A contract with `discriminator from envelope` checks,
  pretty-prints and scaffolds a decoder keyed by the envelope's event type, with no
  discriminator key on the wire. `Keiro.Integration.Event.decodeJsonIntegrationEventWith`
  exists in keiro-core. `diff` reports a change of discriminator source as breaking, and
  `keiro-dsl topology` exports such a contract with `discriminator: null`.
  `keiro-dsl:test:keiro-dsl-test` and `nix develop -c just topology-schema-validate` pass.
  Done 2026-11-18: the schema gate reports 5 goldens valid and 4 examples as expected; the
  new `contract-envelope-discriminator.valid.json` example fails against the unamended
  schemas, so it guards the change.
- [x] M3: Compiled proof. The suite `keiro-dsl-conformance-contract-foreign-event` compiles
  the generated modules and passes every check listed in Validation and Acceptance, covering
  IR-64's AC-1 and AC-2 in a running program. `scripts/check-conformance-corpus.sh` and
  `nix develop -c just verify` pass.
  Done 2026-11-18 (`ea1a548f`, inventories `2b3225be`): the suite prints 26 `PASS` lines,
  focused regeneration reports no changes, the corpus check reports `conformance corpus:
  ok`, and `just verify` exits 0 with 71 test suites passing.
- [x] M4: Documentation and records. The user documentation describes both forms and the
  refused forms (IR-64 AC-3), a new ADR records the decisions, the changelogs announce the
  change, and IR-64 reads `completed`. Done 2026-11-18 (`a50da90e` and `2f300199`).
  All four OKF bundles and `just user-documentation-validate` passed. The release item
  owns the consumer handoff drafted in Outcomes & Retrospective.
- [ ] M5. Resolve the five implementation review findings, complete the hardening steps
  (shape-matrix compile, executed rollout proofs, mutation check, second review), and
  record the verification described in
  [Milestone 5](#milestone-5-resolve-the-implementation-review-findings).
- [ ] Pre-release gate. The generated decoder reads the producer's own sample payloads
  and agrees with the consumer's hand-written decoder on every existing test input.
- [ ] Release. The change ships in the next keiro-dsl and keiro-core release under the
  shared release convention. Record the version here and notify the consumer.


## Surprises & Discoveries

These were found while drafting on 2026-11-18 and shaped the design.

- The generated contract module never sees the envelope. `parse<Contract>Payload` takes an
  aeson `Value` and nothing else (`emitContractGen` in
  `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`), and the generated intake module only lowers the
  disposition table. No library function joins an envelope to a contract decoder today, and
  `decodeJsonIntegrationEvent` has no caller in the repository's Haskell sources. IR-64's
  AC-2 asks for a decoder that rejects a mismatched envelope, so this plan adds that join in
  keiro-core.
- registration-service-v2's event-type header value is `RegistrationCompleted`, a legal
  contract event name. The topic is `registration.completed.v1`. So the motivating event
  needs no way to give an event a wire name that differs from its declared name.
- The topology export writes `discriminator` as a required string
  (`keiro-dsl/src/Keiro/Dsl/Topology.hs`, and `contractDetails` in both schema files under
  `docs/user/schemas/`). A contract without a body discriminator has no such string.
- The working tree held uncommitted work for
  [docs/plans/337-gate-all-behavior-witnesses-through-generated-service-conformance.md](337-gate-all-behavior-witnesses-through-generated-service-conformance.md)
  when this plan was written, in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`,
  `keiro-dsl/test/Main.hs` and many committed corpus files. The corpus check refuses a dirty
  corpus, so that work must be committed before Milestone 3.
- (Implementation, 2026-11-18) Plan 337's work had been committed by the time
  implementation began; the tree was clean.
- (Implementation) A Language 6 test asserted that `Optional text` is refused even when an id
  named `Optional` is declared (`rejects genuine container applications even when their names
  are declared IDs` in `keiro-dsl/test/Main.hs`). Now that `Optional` is a container, it
  reads as an optional field whatever ids exist, exactly as `List text` already did. The test
  now excludes `Optional text` the way it excluded `List text`, and a new test pins the three
  readings of `value: Optional`, `values: Optional text` and `nested: Optional Optional`.
- (Implementation) In envelope mode `explicitParseField` is used only by typed required
  scalars and lists, so its import is conditional there; an envelope contract whose events
  all lack fields binds `go _` to stay warning-free. Both are covered by unit tests.
- (Implementation) aeson 2.2's `(.:?)` is `explicitParseFieldMaybe parseJSON`, and
  `explicitParseFieldMaybe` hands a present value to the `Maybe` instance's `liftParseJSON`,
  which maps `null` to `Nothing` (`aeson/src/Data/Aeson/Types/FromJSON.hs` in the aeson
  checkout Mori lists). So both decoders read an omitted key and `null` as absent.
- (Review verification, 2026-11-18) The unused `payload` binding for a fieldless contract
  event predates this plan. A body-discriminated fieldless event has failed `-Werror`
  since the original contract scaffold (`f77b281b`); no conformance suite declares one, so
  the corpus never compiled it. M5 item 2 fixes both modes.
- (Review verification) `remediationFor` in `keiro-dsl/src/Keiro/Dsl/DiffReport.hs` gives
  every contract code a fixed `producer-last` remedy and ignores the vector. Two
  consequences are outside M5 and are left as they are: a required field added without a
  `schemaVersion` bump is also told `producer-last` although the new reader requires a
  key old producers omit, and the build-only literal-to-declared advisory is told to
  "revise the independently owned public contract" and deploy `producer-last` although
  its wire bytes are unchanged. Rendering the vector's rollout, as item 1 requires, is
  the natural place to fix them later.


## Decision Log

- Decision: An optional field is written `<name>: Optional <scalar>`, where the scalar is
  `typeid "prefix"`, a declared `id`, `text` or `int`. `Optional List …`, `List Optional …`,
  and any other nesting stay refused.
  Rationale: IR-64 asks for optional scalars and declared ids and puts nested optional
  containers and optional list elements out of scope. `Optional` is the spelling the rest of
  the language already uses. An optional list would add a second way to say "nothing"
  beside the empty array.
  Date: 2026-11-18

- Decision: On the wire an absent optional value is an omitted key. The generated encoder
  never writes `null`. The generated decoder reads an omitted key and an explicit `null` as
  absent. Any other value must satisfy the scalar's existing parser, so a wrong type or a
  wrong TypeID prefix still rejects the payload at the field's path.
  Rationale: This answers the absent-key versus `null` question that
  [RES-18](../research/15-containers-in-public-contract-fields.md) left open and that
  [ADR-52](../adr/0052-integration-contracts-admit-lists-of-scalar-fields.md) said must be
  resolved first. It is IR-64's AC-1, and it matches the motivating producer, which omits
  the key. Accepting `null` on read costs nothing and tolerates producers in languages that
  serialize an absent value as `null`. A consumer in any language can implement the rule,
  and JSON Schema states it as a property that is not required and admits `null`.
  Date: 2026-11-18

- Decision: Adding an `Optional` field to an existing event is additive on the wire and
  needs no `schemaVersion` bump. Regeneration adds a strict `Maybe` argument to the
  exported constructor. M5 reports this separately as a consumer-build advisory (see the
  decision below). Changing a field between required and optional is breaking in
  both directions. Changing between `Optional` and `List`, or changing the scalar under
  `Optional`, is breaking. Moving the scalar under `Optional` between a literal
  `typeid "p"` and a declared id is build-only when prefix and admission domain are equal,
  as for scalars and lists. Removing an optional field stays breaking, like any removed
  field.
  Rationale: Generated decoders ignore keys they do not declare, so an older consumer reads
  a message carrying the new key, and a newer consumer reads an older message without it.
  Making a required field optional lets a producer omit a key that deployed consumers still
  require. Making an optional field required rejects retained messages that lack it. This
  follows ADR-52's rule that widening and narrowing both break public consumers.
  Date: 2026-11-18

- Decision: An optional field cannot be a publisher `outboxId` or an intake `dedupe` key.
  The validator reports the new code `ContractOptionalFieldUsedAsKey`.
  Rationale: An identity that may be absent identifies nothing. This mirrors
  `ContractListFieldUsedAsKey`, and it is the ambiguous position IR-64's AC-3 asks the
  validator to keep refusing.
  Date: 2026-11-18

- Decision: A contract without a body discriminator is written `discriminator from envelope`.
  Its generated decoder always takes the event type as an argument and rejects a type the
  contract does not declare, even when the contract has one event. A declared event's name
  must equal the envelope's event type exactly.
  Rationale: The phrase cannot collide with an existing source, because the word after a
  body discriminator name is always `topic`, `event` or `}`. Keiro's envelope always names
  the event type: `Keiro.Inbox.Kafka.integrationEventFromKafka` requires the
  `keiro-event-type` header. So IR-64's "one-event topic" case needs no separate rule, and
  always checking gives AC-2's rejection of a mismatched envelope.
  Date: 2026-11-18

- Decision: In envelope mode the generated module exports
  `parse<Contract>PayloadAs :: Text -> Value -> Either Text <Contract>Payload` and does not
  export `parse<Contract>Payload`. keiro-core gains
  `decodeJsonIntegrationEventWith`, which passes an envelope's event type and decoded JSON
  body to such a parser.
  Rationale: A distinct name keeps a caller from decoding without the event type, and keeps
  every existing generated module byte-identical. The contract module stays free of Keiro
  envelope types, as it is today; the one-line join lives in the library that owns the
  envelope.
  Date: 2026-11-18

- Decision: Event names that are not identifiers (for example `registration.completed.v1`
  as an event type) are out of scope.
  Rationale: The motivating event's type is `RegistrationCompleted`. A wire-name alias for
  events is a separate grammar change with its own diff rules and has no requester.
  Date: 2026-11-18

- Decision: `keiro-dsl topology` writes `discriminator: null` for a contract with
  `discriminator from envelope`. The two existing schema files are amended in place to admit
  `null`; no new schema id and no extra field are added.
  Rationale: The repository owner stated on 2026-11-18 that the topology export has not been
  released and has no consumer yet, so its compatibility policy in
  [ADR-62](../adr/0062-the-service-topology-is-a-versioned-keiro-owned-contract-emitted-under-the-lowest-sufficient-schema-id.md)
  has nothing to protect here. `null` says plainly that the body has no discriminator key.
  Documents for existing services keep their exact bytes.
  Date: 2026-11-18

- Decision: Both syntaxes are gated to candidate Language 6 by adding
  `ContractOptionalFieldSyntax` and `ContractEnvelopeDiscriminatorSyntax` to `profileV5`.
  Rationale: Language 6 is still the candidate and is amended in place
  ([ADR-49](../adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md)).
  Published languages 1 through 5 keep their grammar.
  Date: 2026-11-18

- Decision: The library types change without a compatibility shim. `ContractType` gains
  `COptional`, and `ContractNode.discriminator` changes from `Name` to
  `ContractDiscriminator`.
  Rationale: ADR-52 set this precedent for the same module. The next keiro-dsl release is a
  PVP-major bump.
  Date: 2026-11-18

- Decision: Mapping a foreign producer's own Kafka header names onto Keiro's envelope stays
  out of scope, as IR-64 says. Intake `bind … from header` rows stay descriptive.
  Rationale: The consumer keeps a small adapter until
  `mori://tan/registration-service-v2/okf/improvement-requests/concepts/IR-6` is done.
  Date: 2026-11-18

- Decision: An added `Optional` field is reported as `consumer-build=advisory`, not
  `consumer-build=breaking`. This replaces the verdict the implementation review proposed
  for its third finding.
  Rationale: `consumer-build` is in `defaultGate` (`keiro-dsl/src/Keiro/Dsl/Diff.hs`), so
  a `breaking` verdict would make `keiro-dsl diff` exit non-zero for every added optional
  field. That contradicts the decision above and ADR-65, which make this the one field
  addition that passes without a `schemaVersion` bump, and it would rank a wire-compatible
  addition as more severe than adding a required field with a bump, which today prints an
  advisory, exits 0 and reports no consumer-build verdict even though it changes the same
  constructor. The existing contract precedent for a source-level change with unchanged
  wire bytes is advisory: moving a field between `typeid "p"` and a declared id changes
  the generated Haskell type, breaks callers the same way, and reports
  `consumer-build=advisory`. The constructor change also cannot reach a deployed service:
  it appears only when a service regenerates its own committed module, where the compiler
  names every call site.
  Date: 2026-11-18


## Outcomes & Retrospective

Initial implementation (2026-11-18). A candidate Language 6 source can now mirror registration-service-v2's
`RegistrationCompleted`: the base fixture checks `OK`, its `registration` contract scaffolds
`parseRegistrationPayloadAs`, and the compiled suite decodes the plain producer object with
both optional fields absent, decodes it the same way with `"ownerEmail": null`, and rejects
an envelope whose event type is not declared. IR-64's three acceptance criteria are met:
AC-1 and AC-2 by `keiro-dsl-conformance-contract-foreign-event`, AC-3 by the unit tests and
the "Optional fields" section of `docs/user/keiro-dsl-integration.md`.

The original verification found byte-identical output for existing contracts (the
corpus check regenerates all 60 suites with no diff); the existing topology goldens are
unchanged and the new schema example fails against the old schemas; command, replay,
snapshot and projection paths were not touched. `keiro-dsl:test:keiro-dsl-test`
(977 examples), the new suite, the corpus check, the topology schema gate and the full
`just verify` measure the affected paths, and all pass.

The design held as drafted. Two adjustments came from the code, not the plan: the
envelope-mode decoder imports `explicitParseField` only when a field uses it and binds
`go _` when no event has fields, and the new suite needs `bytestring` and `time` to build an
`IntegrationEvent`, beyond what the list-fields suite uses. One existing test had encoded
the old refusal of `Optional text` even beside an id named `Optional`; it now matches the
`List` precedent.

The 2026-11-18 review reproduced two incorrect rollout remedies, a fieldless generated
module that fails compilation with warnings promoted to errors, and an unreported
constructor break. It also found two documentation errors. The review reran all 977 DSL
examples, the foreign-event conformance suite, the topology schema gate and the 60-entry
corpus check successfully. Milestone 5 adds coverage for the cases those checks missed.
Release and consumer notification follow the review fixes. No registered
dependent of keiro-dsl (`mori://shinzui/keiei`, `mori://shinzui/kotei`,
`mori://shinzui/shikigami`) imports `Keiro.Dsl.Grammar` or `ContractNode`, so the library type
change needs no downstream notice. `mori://shinzui/keiro-syntax` already highlights `from`
and `envelope` as keywords; as for List fields, a follow-up there can copy
`keiro-dsl/test/fixtures/contract-foreign-event.keiro` into its corpus to pin `Optional` in
the contract-field position and `discriminator from envelope`.

Handoff to send to the owner of `mori://tan/agent-reputation-service` once the release is
published:

```text
keiro-dsl and keiro-core <version> resolve IR-64 (mori://shinzui/keiro/okf/improvement-requests/concepts/IR-64).
mori://tan/agent-reputation-service/plans/8-resolve-invitations-from-registration-service-v2-completion-events
can now declare registration-service-v2's event as a Language 6 contract with
`discriminator from envelope` and `ownerEmail: Optional text` / `mlsMemberId: Optional MemberId`,
delete its hand-written payload decoder, and decode with
`decodeJsonIntegrationEventWith parseRegistrationPayloadAs` behind its existing header adapter,
which still maps the producer's own headers onto Keiro's envelope.
See mori://shinzui/keiro/okf/adr/concepts/ADR-65 for the wire and evolution rules.
```


## Context and Orientation

All paths are relative to the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`. Run
every build and test inside the Nix development shell, from the root. Entering the shell
from a package directory creates a stray PostgreSQL cluster there.

### Vocabulary

*keiro-dsl* is the package under `keiro-dsl/`. It parses `.keiro` sources, validates them,
compares two versions of a source (`keiro-dsl diff`), and generates Haskell
(`keiro-dsl scaffold`).

A *language version* is the number in a source's first line, `language keiro-dsl N`.
Versions 1 to 5 are published and frozen. Version 6 is the *candidate*: it is accepted for
authoring and may still be amended. Each grammar addition is a constructor of
`LanguageFeature` in `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`, and a *syntax profile*
is the set of features one version admits. `profileV5` is the profile of Language 6. Using
a feature in an older language fails with the diagnostic `LanguageFeatureRequiresVersion`.

A *contract scalar* is one of four field types: `typeid "prefix"` (a TypeID with that
prefix), a *declared id* (the name of a top-level `id` declaration), `text`, or `int`.

The *envelope* is `IntegrationEvent` in `keiro-core/src/Keiro/Integration/Event.hs`: the
metadata around a payload, including `eventType :: Text` and `payloadBytes`. Keiro's
canonical Kafka header is `keiro-event-type`. The registration producer sends `event-type`,
which its consumer's adapter maps to `IntegrationEvent.eventType`.
`keiro/src/Keiro/Inbox/Kafka.hs` rebuilds an envelope from a Kafka record and fails with
`MissingHeader` when that header is absent.

The *body discriminator* is the JSON key a contract declares with `discriminator <name>`.
The generated encoder writes the event's name under that key and the generated decoder
reads it to choose the event.

The *conformance corpus* is the set of directories `keiro-dsl/test/conformance-*`. Each
holds committed scaffold output plus a `Main.hs`, and is compiled and run as a Cabal test
suite. `keiro-dsl/test/README.md` explains how to add one.

### Where a contract field type is handled today

`keiro-dsl/src/Keiro/Dsl/Grammar.hs` defines the syntax tree:

```haskell
data ContractScalarType = CTypeId !Text | CDeclaredId !Name | CText | CInt
data ContractType = CScalar !ContractScalarType | CList !ContractScalarType
contractScalar :: ContractType -> ContractScalarType
contractIsList :: ContractType -> Bool
data ContractNode = ContractNode
  { name :: !Name, schemaVersion :: !Int, discriminator :: !Name,
    topics :: ![(Name, Text)], events :: ![ContractEvent], loc :: !Loc }
```

`keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs` parses a contract in `pContract`.
`pContractType` recognizes `List` only when an operand follows it, so `List` and `Optional`
alone stay legal declared-id names. A type must end at `;`, `}` or the next field head
(`pContractTypeBoundary`); anything else fails with the message that begins "contract field
types admit". That check is what refuses `Optional text` today, because `Optional` parses
as a declared-id name and `text` is not a boundary.

`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` prints a contract in `docContract`.

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` generates the module in `emitContractGen`. Per
contract it emits `<Contract>Payload` (a sum of `<Event>Data` records), `messageTypeOf`,
`encode<Contract>Payload`, and `parse<Contract>Payload :: Value -> Either Text …`. The
decoder reads the discriminator with `explicitParseField (withText …)`, validates it with
`validateMessageType`, and decodes each field with `o .: "key"` or `explicitParseField`.
Generated modules compile under `-Werror`, so every import is emitted only when used; see
`usesPlainFieldDecode` and `hasListFields`.

`keiro-dsl/src/Keiro/Dsl/Validate.hs` checks a contract in `validateContract`
(`discriminatorShadows` and `fieldWireKeyRules` use the discriminator name), an intake in
`validateIntake` and `intakeCoupling`, and a publisher in `validatePublisher`. The last two
raise `ContractListFieldUsedAsKey`. `DiagnosticCode` in the same file lists every code,
including the diff codes.

`keiro-dsl/src/Keiro/Dsl/Diff.hs` classifies contract evolution in `contractPairDiff` and
`contractEventDiff`. An added field is breaking without a `schemaVersion` bump and advisory
with one. `isLiteralDeclaredTransition` and `renderContractType` are shape-aware.

`keiro-dsl/src/Keiro/Dsl/Topology.hs` exports a contract node with a `discriminator` string.
The schemas are `docs/user/schemas/keiro-dsl-service-topology-1.schema.json` and
`…-2.schema.json`, checked by `scripts/check-topology-schemas.sh`.

Other modules reach a field's scalar through `contractScalar` and need no change beyond the
new equation: `IdDomain.hs`, `Manifest.hs`, `TypeGraph.hs`.

Tests live in `keiro-dsl/test/Main.hs` (unit tests, a fixture inventory near line 1952, and
the list-field tests near line 8639), `keiro-dsl/test/Keiro/Dsl/FrontendProfiles.hs`
(one `FeatureCase` per language feature), `keiro-dsl/test/Keiro/Dsl/TopologySpec.hs`, and
`keiro-dsl/test/fixtures/`.

### Precedent to follow

[docs/plans/312-support-list-fields-in-integration-contracts.md](312-support-list-fields-in-integration-contracts.md)
added `List` fields to the same grammar. Its fixtures
(`keiro-dsl/test/fixtures/contract-list-fields*.keiro`), its tests, and its suite
`keiro-dsl/test/conformance-contract-list-fields/` are the working model for every step
here. When this plan says "as the list tests do", read those.

### Architecture decision records consulted

- [ADR-52](../adr/0052-integration-contracts-admit-lists-of-scalar-fields.md) admits lists
  of scalars, keeps `Optional` excluded, and says a future optional field must first settle
  absent key versus `null`. It also fixes contextual, case-sensitive container recognition.
  This plan extends it and records the outcome in a new ADR.
- [ADR-49](../adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md)
  makes Language 6 the candidate that new syntax lands in.
- [ADR-46](../adr/0046-nominal-declarations-are-structural-leaves-with-keiro-owned-admission.md)
  keeps TypeID admission with Keiro. An optional declared id uses the same admission when
  the value is present.
- [ADR-21](../adr/0021-direct-fields-have-independent-dsl-selector-and-wire-identities.md)
  gives fields independent `haskell` selector and `as "wire-key"` aliases. Optional fields
  keep them.
- [ADR-13](../adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md)
  classifies contracts as a separately owned grammar. That stays true.
- [ADR-62](../adr/0062-the-service-topology-is-a-versioned-keiro-owned-contract-emitted-under-the-lowest-sufficient-schema-id.md)
  owns the topology document's compatibility policy. See the Decision Log for why this plan
  amends the schemas in place.
- [ADR-43](../adr/0043-delegated-inbox-intake-uses-a-downstream-event-receipt.md) covers
  intake idempotence. It is unaffected.

[RES-18](../research/15-containers-in-public-contract-fields.md) lists the questions an
optional contract field must answer. The Decision Log answers them for this scope.


## Plan of Work

### Milestone 1: optional contract fields

At the end of this milestone the language accepts, prints, lowers, validates and diffs
`Optional <scalar>` fields, proven by unit tests.

Move IR-64 to `in-progress` first: set `status: in-progress` and `plan:` to this file in
its frontmatter, advance `timestamp`, and add a log entry with `okf log add` (see Concrete
Steps).

In `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, add the constructor `COptional !ContractScalarType`
to `ContractType`, the equation `contractScalar (COptional scalar) = scalar`, the equation
`contractIsList COptional {} = False`, and a new exported predicate `contractIsOptional`.
Build once and let the compiler list the incomplete matches.

In `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`, add `ContractOptionalFieldSyntax` to
`LanguageFeature` and to `profileV5`.

In `pContractType`, add a branch shaped like the `List` branch: look ahead for the exact
word `Optional` followed by something that is not a type boundary, claim its span with
`withOwnedSpan`, require the feature with `requireLanguageFeatureAt`, then parse one
scalar. Keep the feature check outside the backtracking `try`, as the comment above the
`List` branch explains. The existing boundary check then refuses `Optional List text` and
`List Optional text` with no new rule. Reword its message to:

```text
contract field types admit typeid "prefix", text, int, a declared id, List of one of those, or Optional of one of those; nested containers, Optional List, List Optional, Map, and Set applications and records are not supported in public contracts
```

`value: Optional` alone must still name a declared id called `Optional`, and
`value: Optional Optional` is an optional field of that id.

In `docContractType` (`PrettyPrint.hs`) print `Optional <scalar>`. In `renderContractType`
(`Diff.hs`) render it the same way.

In `emitContractGen`, lower an optional field as follows. The record field is
`!(Maybe <scalar type>)`. The decoder uses aeson's `.:?` for `text` and `int` and
`explicitParseFieldMaybe <parser>` for typed TypeIDs and declared ids; both read an omitted
key and `null` as `Nothing`. Confirm that against the aeson version in the shell, and the
Milestone 3 suite proves it. The encoder omits the key. Only for an event that has an
optional field, build the object from the required entries plus one list comprehension per
optional field:

```haskell
  RegistrationCompleted payload ->
    object
      ( [ "registrationId" .= KindID.toText payload.registrationId,
          "occurredAt" .= payload.occurredAt
        ]
          <> ["ownerEmail" .= value | Just value <- [payload.ownerEmail]]
          <> ["mlsMemberId" .= NominalLeaves.encodeMemberIdLeaf value | Just value <- [payload.mlsMemberId]]
      )
```

Emit `(.:?)` and `explicitParseFieldMaybe` imports only when used. Output for every
contract without an optional field must not change by a byte; the corpus drift check in
Milestone 3 enforces that.

In `Validate.hs`, add `ContractOptionalFieldUsedAsKey` to `DiagnosticCode` after
`ContractListFieldUsedAsKey`. In `validatePublisher` and `intakeCoupling`, apply to
optional fields the same rule the list fields get, with the same precedence: a canonical
envelope name stays valid even if a payload field shares it, and one mistake yields one
diagnostic, not also an unresolved-field error. Messages:

```text
publisher '<p>' outboxId field '<f>' is an Optional field of an event mapped by emit '<e>'; outbox identity must be messageId, idempotencyKey, or a required scalar contract field
intake '<i>' dedupe key '<f>' is an Optional field of accepted events <events>; dedupe identity must be a required scalar envelope or event field
```

In `validateIntake`, the `decodePosture` message says every declared field is required.
Reword it so it stays true: generated codecs require every field not declared `Optional`
and emit no lenient fallback. `body strict` remains the only accepted posture.

In `contractEventDiff` (`Diff.hs`), implement the Decision Log's evolution table. Add the
wire-additive code `ContractOptionalFieldAdded` beside `ContractEventAdded` in `DiagnosticCode`,
and use it for an added field whose type is `COptional`, whatever the `schemaVersion`.
A change between required and optional falls into the existing breaking
`ContractFieldChanged` branch; make its detail name the direction, for example
`field type changed text -> Optional text; deployed consumers still require the key`.
Extend `isLiteralDeclaredTransition` with the two `COptional` cases.

Add fixtures under `keiro-dsl/test/fixtures/` and register each in the fixture inventory
test in `keiro-dsl/test/Main.hs`:

- `contract-foreign-event.keiro`, the base. It declares `id MemberId prefix=member` and two
  contracts. Contract `audit` keeps `discriminator messageType` and has one event
  `MemberNoted` with `memberId: MemberId` and `note: Optional text`. Contract `registration`
  is added in Milestone 2; until then the file holds only `audit`, plus a second `audit`
  event `RegistrationSeen` with one optional field of each scalar family:
  `ownerEmail: Optional text`, `mlsMemberId: Optional MemberId`,
  `legacyAccountId: Optional int`, `referrerId: Optional typeid "member"`, and a required
  `registrationId: typeid "registration"`.
- `contract-foreign-event-language5.keiro`: the same optional field under
  `language keiro-dsl 5`, using only literal types so the declared-id gate does not fire
  first.
- Diff mutants of the base, one change each: `-optional-to-required` (`note: text`),
  `-optional-added` (a new `reason: Optional text` on `MemberNoted`),
  `-optional-scalar-change` (`note: Optional int`), and `-optional-literal-to-declared`
  (`referrerId: Optional MemberId`).

Add unit tests beside the list tests: lowering text for each scalar family; the Language 5
refusal with its line; refusal of `Optional List text`, `List Optional text` and
`optional text` (lower case); `Optional` as a declared-id name alone and under `Optional`;
aliases (`note haskell memberNote as "member_note": Optional text`); both identity refusals
and the canonical-name precedence; and the diff classifications in both directions. Add a
`FeatureCase` and the minimum-version entry for the new feature in `FrontendProfiles.hs`.

### Milestone 2: envelope discriminator

At the end of this milestone a contract can declare that its payload has no body
discriminator, and the envelope can be joined to its decoder.

In `Grammar.hs`, add and export:

```haskell
data ContractDiscriminator = DiscriminatorBodyKey !Name | DiscriminatorEnvelope
contractBodyDiscriminator :: ContractNode -> Maybe Name
```

and change `ContractNode.discriminator` to `!ContractDiscriminator`. Add
`ContractEnvelopeDiscriminatorSyntax` to `LanguageFeature` and `profileV5`.

In `pContract`, after `keyword "discriminator"`, recognize `from envelope` before falling
back to an identifier, and gate it on the new feature at the span of `from`. In
`docContract` print `discriminator from envelope`.

In `validateContract`, run `discriminatorShadows` only for a body key, and pass `Nothing`
as the reserved key to `wireKeyRulesForRecord` in envelope mode.

In `emitContractGen`, for `DiscriminatorEnvelope`: the encoder writes only the fields, and
an event with no fields encodes as `object []`. `messageTypeOf` is unchanged; a producer
puts its result in the envelope's `eventType`. The decoder is

```haskell
parseRegistrationPayloadAs :: Text -> Value -> Either Text RegistrationPayload
parseRegistrationPayloadAs eventType = mapLeftText . parseEither (withObject "RegistrationPayload" go)
  where
    go o = do
      kind <- validateMessageType eventType
      case kind of
        "RegistrationCompleted" -> …
```

Export `parse<Contract>PayloadAs` in place of `parse<Contract>Payload`, change the section
comment to say the set is discriminated by the envelope's event type, and drop the
`withText` import, which this mode does not use.

In `contractPairDiff`, compare the discriminators as values. A change between a body key
and the envelope is breaking `ContractDiscriminatorChanged`, rendered as
`discriminator changed messageType -> from envelope`.

In `Topology.hs`, write `("discriminator", maybe Null String (contractBodyDiscriminator contract))`.
In both schema files change `contractDetails.properties.discriminator` to
`{"type": ["string", "null"]}` with a description saying `null` means the event type comes
from the envelope. Add a `TopologySpec.hs` test for an envelope contract, and a
`*.valid.json` example under `keiro-dsl/test/fixtures/topology/schema-examples/`. Existing
golden documents must not change.

In `keiro-core/src/Keiro/Integration/Event.hs`, add and export:

```haskell
decodeJsonIntegrationEventWith ::
  (Text -> Value -> Either Text a) ->
  IntegrationEvent ->
  Either IntegrationEventError a
```

It refuses a non-JSON content type with `UnsupportedContentType`, reports unparsable bytes
as `MalformedPayload`, calls the parser with the envelope's `eventType` and the decoded
`Value`, and reports the parser's `Left` as `DecodeFailed`. Run
`nix develop -c just keiro-reexports` afterwards; the module is already re-exported, so no
change is expected.

Extend the base fixture with the `registration` contract shown in Purpose / Big Picture,
plus `legacyAccountId: Optional int`. Add `contract-foreign-event-envelope-language5.keiro`
and the diff mutant `contract-foreign-event-discriminator-body.keiro` (`registration`
declared with `discriminator messageType`). Add unit tests: parse and pretty round trip;
Language 5 refusal; lowering text, including the absent `withText` import and the export
list; a field named `messageType` is legal in envelope mode and still refused in body
mode; the diff classification in both directions; and a `FeatureCase`.

### Milestone 3: the generated code compiles and behaves in a committed suite

Create `keiro-dsl/test/conformance-contract-foreign-event/` from the base fixture, following
"Adding a conformance suite" in `keiro-dsl/test/README.md`. Add the Cabal stanza
`test-suite keiro-dsl-conformance-contract-foreign-event` to `keiro-dsl/keiro-dsl.cabal` by
copying the `keiro-dsl-conformance-contract-list-fields` stanza and taking `other-modules`
from the generated Cabal fragment. Add a `candidate-primary`, `languageVersion: 6` entry to
`keiro-dsl/test/conformance-baseline.json` after the list-fields entry. The fixture has no
consumer-bound id, so the suite needs no hand-owned `Domain.hs` or `Bindings.hs`.

`Main.hs` prints one `PASS` or `FAIL` line per check and exits non-zero on any failure, as
the list-fields `Main.hs` does. The checks are listed in Validation and Acceptance.

Commit the new suite, then run focused regeneration, the corpus check, and `just verify`.
Refresh any generated inventory the full gate reports, as plan 312 had to
(`nix develop -c just record-migration-policy` names them).

### Milestone 4: documentation, records and handoff

Write the ADR. Take its handle from `okf id next` (it was `ADR-65` on 2026-11-18). Title it
"Integration contracts admit optional scalar fields and envelope-discriminated payloads",
set `originatingPlan` to this file, and record the Decision Log's wire policy, evolution
table, identity rule, discriminator rule and topology representation. Add a dated "Revisit"
paragraph to `docs/research/15-containers-in-public-contract-fields.md` saying IR-64
supplied the `Optional` case and how its questions were answered. Log both bundles.

In `docs/user/keiro-dsl-integration.md`: add the `Optional <scalar>` row to the field type
table; add a section with the example from Purpose / Big Picture; state the wire policy,
the allowed and refused forms (this is IR-64's AC-3), the identity refusal and the
evolution rules; describe `discriminator from envelope`, the generated
`parse<Contract>PayloadAs`, and `decodeJsonIntegrationEventWith`; and correct the sentences
that say `Optional` is refused and that every body field is required. Add both features to
the Language 6 table in `docs/user/keiro-dsl-reference.md`. Mention the two new codes where
`docs/user/keiro-dsl-validation-and-evolution.md` lists `ContractListFieldUsedAsKey`. In
`docs/user/keiro-dsl-service-topology.md` say the contract `discriminator` is `null` for an
envelope-discriminated contract. Mention the new helper beside
`decodeJsonIntegrationEvent` in `docs/user/integration-events.md`. Advance each page's
`generated.at`, add one `okf log add docs/user` entry, and validate.

Under `## [Unreleased]`: in `keiro-dsl/CHANGELOG.md` add a Breaking Changes entry for the
two type changes and a New Features entry for both syntaxes, the two diagnostic codes and
the nullable topology field; in `keiro-core/CHANGELOG.md` add the helper; in the root
`CHANGELOG.md` add one line pointing at them. Do not choose a version number.

Move IR-64 to `completed` with `completedAt` and a `resolution` sentence, log it, and
validate the bundle. On release, send the handoff and record delivery. Tell the owner of
`mori://tan/agent-reputation-service` that, once the release is published,
`mori://tan/agent-reputation-service/plans/8-resolve-invitations-from-registration-service-v2-completion-events`
can declare the contract, delete its hand-written payload decoder, and call
`decodeJsonIntegrationEventWith parse<Contract>PayloadAs` behind its header adapter. List
library consumers with `mori registry dependents shinzui/keiro --packages` and tell each one
that imports `Keiro.Dsl.Grammar` about the type changes. Check `mori://shinzui/keiro-syntax`
for the `Optional` and `from envelope` spellings in contract position and note any
follow-up.

Finish with Outcomes & Retrospective and the ADR distillation pass.


### Milestone 5: resolve the implementation review findings

The review used the committed fixtures in `keiro-dsl/test/fixtures/` and compiled
scaffold output in the project Nix shell. Each finding was re-verified independently on
2026-11-18 against the working tree (HEAD `c8bf96e8`); the evidence is recorded with each
item. Findings 1, 2, 4 and 5 are confirmed as stated. Finding 3's observation is
confirmed, but its proposed `breaking` verdict was replaced with `advisory`; see the
Decision Log. Address each finding before closing M5.

1. **P1 — Deployment order (confirmed).** Comparing `contract-foreign-event.keiro` with
   either `contract-foreign-event-optional-to-required.keiro` or
   `contract-foreign-event-discriminator-body.keiro` makes `diff --explain` print
   `vector: public-consumer=breaking rollout=producer-last` and
   `remedy: deploy in producer-last order`. In both cases the new reader requires a body
   key that old producers omit, so deploying readers first rejects every message. For
   the optional-to-required pair the remedy also contradicts the finding's own detail
   line, `retained messages that omit the key no longer decode`. The diff already exits
   non-zero for all four directions, so the defect is wrong operator guidance, not a
   missed gate.

   There are two causes, and both must change. `classifyCompatibility` in
   `keiro-dsl/src/Keiro/Dsl/Diff.hs` sends every `ContractFieldChanged` and
   `ContractDiscriminatorChanged` through `publicBreakingVector`, whose rollout is always
   `producer-last`. Separately, `remediationFor` in
   `keiro-dsl/src/Keiro/Dsl/DiffReport.hs` maps every code in `contractCodes` to a
   hardcoded `RemedyDeploymentOrder RolloutProducerLast` and never reads the vector, so
   correcting the vector alone leaves the explanation unchanged. Give the two forward
   transitions the rollout `producer-first` plus `drain-required`, as
   `contractTypeIdDomainVector` already does for a tightened TypeID domain, and make the
   remedy render the vector's rollout: deploy writers that supply the key, then drain or
   migrate retained messages before deploying the stricter reader. The reverse fixtures
   (required to optional, body key to envelope) must keep `producer-last`: readers must
   tolerate omission before writers drop the key. Test the report vector and the CLI
   explanation in all four directions. `docs/user/deploy-ordering.md` lists the rollout
   names without `producer-first`; add it there.

   `keiro-dsl diff` takes one file and `--since GIT-REF`, so reproduce a fixture pair by
   committing the old fixture as `spec.keiro` in a scratch Git repository, overwriting it
   with the new one, and running `diff spec.keiro --since HEAD --explain` there.
2. **P2 — Fieldless events (confirmed, and wider than reported).** Scaffolding the unit
   test's `Pinged`/`Ponged` envelope contract and compiling the module with
   `ghc -fno-code -Wall -Werror` fails with `-Wunused-imports` on `(.=)` and
   `-Wunused-matches` on `payload` in both encoder arms. The unit test in
   `keiro-dsl/test/Main.hs` (near line 9001) asserts those exact fragments, so it pins
   the defect. The repository's `generated-output` stanza treats any warning in
   generated code as a generator defect.

   The unused `payload` is not limited to envelope mode. A body-discriminated contract
   with one fieldless event (`event Pinged on events { }` beside an event that has
   fields) emits `Pinged payload -> object [ "messageType" .= ("Pinged" :: Text) ]` and
   fails the same way. That arm head dates from the original contract scaffold
   (`f77b281b`), and no committed conformance suite has a fieldless contract event, which
   is why the corpus never caught it.

   In `emitContractGen` (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`), bind `payload` in an
   encoder arm only when the event has at least one field, in both discriminator modes,
   and import `(.=)` only when some encoder entry uses it (a body discriminator or any
   field). Output for every event that has a field must not change by a byte. Update the
   rendered-text assertions. Add to the conformance fixture an envelope contract whose
   events are all fieldless and a fieldless event in the body-discriminated `audit`
   contract, so both shapes compile under the generated-code warning policy. Check that
   the fieldless envelope events encode to `{}`, that the fieldless body event encodes to
   exactly its discriminator key, and that each event type selects its constructor on
   decode.
3. **P2 — Generated constructor compatibility (observation confirmed, verdict changed).**
   Comparing the base fixture with `contract-foreign-event-optional-added.keiro` prints
   only `ADDITIVE: audit contract-field MemberNoted.reason` with no vector and exits 0.
   Regeneration does add a strict third field to `MemberNotedData`, so an existing
   `MemberNoted (MemberNotedData memberId note)` stops compiling until the caller adds
   `Nothing`. The report is silent about that, which is the defect.

   Report it as `consumer-build=advisory`, not `breaking`. In `Diff.hs` keep
   `ContractOptionalFieldAdded`, keep `public-consumer` compatible with no
   `schemaVersion` bump, and set `consumerBuild = VAdvisory` (remove the code from
   `additiveCodes` and give it its own row). The finding then prints as a `WARNING` whose
   explanation tells the reader to re-scaffold and recompile, and the default gate still
   exits 0. Verify the vector, the explanation and the zero exit status, then compile the
   updated caller with `Nothing` and decode an older message omitting `reason`. The
   Decision Log records why `breaking` was rejected.
4. **P3 — Producer header in ADR-65 (confirmed).** The Context of
   [ADR-65](../adr/0065-integration-contracts-admit-optional-scalar-fields-and-envelope-discriminated-payloads.md)
   says the producer "names the event only in the Kafka `keiro-event-type` header". The
   registration producer sends `event-type` with the value `RegistrationCompleted`
   (asserted by `Completion/PublisherSmokeTest.hs` in
   `mori://tan/registration-service-v2`), and
   `mori://tan/registration-service-v2/okf/improvement-requests/concepts/IR-6`, still
   `proposed`, asks it to add `keiro-event-type` beside it. The consumer's adapter maps
   `event-type` onto `IntegrationEvent.eventType`. Correct the sentence, and update
   ADR-65's evolution guidance with the rollout and build verdicts from items 1 and 3.
5. **P3 — Error paths in the integration guide (confirmed).** The Optional fields
   section of [the integration guide](../user/keiro-dsl-integration.md) says
   "`"note": 7` or a wrong-prefix ID rejects the payload at `$.note`". A wrong-prefix
   `referrerId` is rejected at `$.referrerId`. Reword the sentence so each input names
   its own path. The conformance suite already asserts both path shapes on the
   `registration` contract (`$.ownerEmail` and `$.mlsMemberId`); add the equivalent
   checks for `audit` only if the suite does not already decode a wrong-type optional
   `text` and a wrong-prefix optional literal TypeID there. Align the guide's evolution
   table with the verified wire, rollout and build verdicts.

#### Hardening: close the gaps that let the findings through

Every gate passed while the five defects existed. Three gaps explain that, and fixing
the five findings alone leaves all three open. The steps below close them and are part
of M5's acceptance.

- Generated code was asserted as text and not compiled. The fieldless unit test pinned
  the broken fragments, and the conformance suite compiles only the shapes its one
  fixture declares.
- Diff tests asserted a finding's code and label, never the rollout or the remedy an
  operator reads.
- The producer's behavior was written from this repository's understanding of it, which
  ADR-65 shows was wrong in one place.

6. **Compile the shape matrix.** Add a test that builds small contract sources covering
   discriminator mode (body key, envelope) × event shape (no fields, required only,
   optional only, both) × field family (`text`, `int`, literal TypeID, declared id, list),
   including a contract whose events are all fieldless and one that mixes a fieldless
   event with others. Scaffold each and compile the contract module with
   `-Wall -Werror`. The conditional imports in `emitContractGen` (`(.=)`, `(.:)`, `(.:?)`,
   `withText`, `explicitParseField`, `explicitParseFieldMaybe`) are where one untested
   combination breaks, so every combination that changes an import must appear. Choose
   the mechanism that fits the existing harness: either one committed conformance fixture
   per distinct import set, or a test that scaffolds to a temporary directory and runs
   `ghc -fno-code`. A compile failure for any shape fails the suite.
7. **Prove each rollout verdict by running both versions.** For the four directions of
   item 1, compile the old and the new generated module in one test program (two source
   directories with distinct module prefixes). A `producer-first` verdict holds when the
   old decoder accepts the new encoder's output and the new decoder rejects the old
   encoder's output with the key absent. A `producer-last` verdict holds when the new
   decoder accepts the old encoder's output. Assert both the accepting and the rejecting
   side, so a reversed verdict fails. Do the same for the added optional field: old
   decoder reads the new message, new decoder reads the old one.
8. **Mutation-check the new tests.** For each of items 1, 2, 3, 6 and 7, temporarily
   revert the fix or flip the verdict, confirm a named test fails, restore it, and record
   the test name here. A test that still passes against the defect is not evidence.
9. **Second review.** After the steps above pass, request an implementation review from
   a model that did not write the code, giving it the diff and this plan, and record it
   with `record-provenance.ts review`. M5 closes on an `approved` verdict.

#### Pre-release gate: the real producer and the real consumer

Do this before the Release item, against a local build, not a published version.

- Decode the producer's own sample payloads with the generated decoder. Take them from
  the contract document and publisher smoke tests in `mori://tan/registration-service-v2`
  (`docs/contracts/flow-2/registration-completed-event.md` and
  `test/RegistrationServiceV2/Completion/PublisherSmokeTest.hs`), with and without
  `ownerEmail` and `mlsMemberId`. Commit them as fixtures in the conformance suite and
  cite their source.
- In `mori://tan/agent-reputation-service`, point the build at the local keiro-dsl and
  keiro-core, declare the contract, and run the generated decoder beside the existing
  hand-written one over that service's current test inputs
  (`agent-reputation-service-core/test/AgentReputation/Registration/CompletedSpec.hs`).
  Both must agree on every input, accepted and rejected, before the hand-written decoder
  is deleted. Record any disagreement as a finding here. That repository is another
  owner's; make the trial on a scratch copy and send results, not commits.

Run the DSL unit and foreign-event conformance suites, corpus regeneration check, ADR
and user documentation validation, and final `nix develop -c just verify` using the
commands below. Record the results under Progress and Outcomes & Retrospective when M5
passes. State the no-regression evidence per guarantee, naming the gate that measures
it: byte-identical output for existing contracts (the corpus check; it is vacuous for
fieldless contract events, which no earlier suite declared, so the new fixtures carry
that case), unchanged topology goldens (`just topology-schema-validate`), and no file
touched under the command, replay, snapshot or projection paths (read it from
`git diff --stat` for M5's commits, do not assume it).


## Concrete Steps

Run everything from `/Users/shinzui/Keikaku/bokuno/keiro`. Confirm the shell first:

```bash
nix develop -c z3 --version
git status --short
```

`git status` must list nothing under `keiro-dsl/test/conformance-*` before Milestone 3.

Build after each milestone's edits:

```bash
nix develop -c cabal build all --enable-tests --enable-benchmarks
```

Milestone 1 and 2 checks:

```bash
nix develop -c cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/contract-foreign-event.keiro
nix develop -c cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/contract-foreign-event-language5.keiro
nix develop -c cabal run -v0 keiro-dsl -- pretty keiro-dsl/test/fixtures/contract-foreign-event.keiro
nix develop -c cabal test keiro-dsl:test:keiro-dsl-test --test-show-details=direct
nix develop -c just topology-schema-validate
```

Expected: the first prints `OK`. The second exits non-zero with a line containing
`error [LanguageFeatureRequiresVersion]` on the optional field's line. The third prints
`Optional text` and, after Milestone 2, `discriminator from envelope`; saving that output
to a file under a `mktemp -d` directory and running `check` on it prints `OK`. The test
suite and the schema gate exit zero.

Milestone 3:

```bash
nix develop -c cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/contract-foreign-event.keiro --out keiro-dsl/test/conformance-contract-foreign-event
# Write Main.hs, add the Cabal stanza and the baseline entry, then:
git add -f keiro-dsl/test/conformance-contract-foreign-event/keiro-dsl-ledger.context.contract-foreign-event.txt keiro-dsl/test/conformance-contract-foreign-event/keiro-dsl-cabal-fragment.context.contract-foreign-event.txt
git add keiro-dsl/test/conformance-contract-foreign-event keiro-dsl/test/conformance-baseline.json keiro-dsl/keiro-dsl.cabal
# Commit with both trailers before regenerating.
nix develop -c cabal run -v0 keiro-dsl-corpus-regen -- regenerate --only keiro-dsl/test/conformance-contract-foreign-event
git status --short -- keiro-dsl/test
nix develop -c cabal test keiro-dsl:test:keiro-dsl-conformance-contract-foreign-event --test-show-details=direct
nix develop -c scripts/check-conformance-corpus.sh
nix develop -c just verify
```

Expected: regeneration changes nothing, the suite prints only `PASS` lines, and both gates
exit zero. `just verify` stops at the first failure, so read its exit status, not only its
last lines.

Records and documentation:

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
okf validate docs/research --strict --profile docs/research/profile.dhall --profile-enforce --log-enforce
okf validate docs/improvement-requests --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
nix develop -c just user-documentation-validate
```

Commit at each milestone with Conventional Commits and both trailers:

```text
feat(dsl): accept Optional scalar fields in integration contracts

Add COptional to ContractType, gate the Optional spelling on
ContractOptionalFieldSyntax in candidate Language 6, lower it to a Maybe
field whose key is omitted when absent and read as absent when null, refuse
it as an identity, and classify its evolution.

ExecPlan: docs/plans/345-let-integration-contracts-declare-optional-fields-and-an-envelope-discriminator.md
Intention: intention_01m7qqq7a0e8rtk6y4h0tnft3v
```


## Validation and Acceptance

The plan is accepted when the following hold on a clean checkout. Each IR-64 acceptance
criterion names the checks that prove it.

AC-1, optional fields. The suite `keiro-dsl-conformance-contract-foreign-event` runs these
against the generated `audit` and `registration` modules:

- a payload with every optional field present round-trips through encode and decode, for
  `text`, `int`, a literal TypeID and a declared id;
- a payload with every optional field `Nothing` encodes to an object that has none of those
  keys, compared against an exact expected `object`, and decodes back to the same payload;
- the same JSON with each optional key set to `null` decodes to `Nothing` for that field;
- `"ownerEmail": 7` is rejected with a message naming `$.ownerEmail`, and a wrong-prefix
  `mlsMemberId` is rejected with a message naming `$.mlsMemberId`;
- a payload missing the required `registrationId` is still rejected;
- an unknown extra key is ignored.

AC-2, no body discriminator. The same suite checks that:

- `encodeRegistrationPayload` produces an object with no `messageType` key;
- `parseRegistrationPayloadAs "RegistrationCompleted"` decodes the bare object
  `{"registrationId":"registration_01h455vb4pex5vsknk084sn02q","occurredAt":"2026-11-18T00:00:00Z"}`;
- `parseRegistrationPayloadAs "SomethingElse"` on that object is `Left` with a message
  naming the unknown message type;
- `decodeJsonIntegrationEventWith parseRegistrationPayloadAs` on an `IntegrationEvent`
  whose `eventType` is `RegistrationCompleted` and whose `payloadBytes` are that object
  returns the payload, and on the same envelope with `eventType = "RegistrationStarted"`
  returns `Left (DecodeFailed _)`;
- the body-discriminated `audit` contract still requires its `messageType` key.

AC-3, refused forms. Unit tests show that `Optional List text`, `List Optional text` and
`optional text` fail to parse with the stated message, that an optional field as
`outboxId` or `dedupe` key yields exactly one `ContractOptionalFieldUsedAsKey`, and that
both syntaxes are refused under Language 5. `docs/user/keiro-dsl-integration.md` lists the
allowed and refused forms.

Evolution. Unit tests over the mutant fixtures show that an added optional field is
wire-compatible without a `schemaVersion` bump, carries a `consumer-build` advisory for
the generated constructor, and passes the default gate; required to optional is breaking
`ContractFieldChanged` with rollout `producer-last`, and optional to required is breaking
with `producer-first` and `drain-required`; a changed scalar under `Optional` is breaking; a literal-to-declared
move under `Optional` with equal prefix and admission is a build-only advisory; and a
change of discriminator source is breaking `ContractDiscriminatorChanged`, with
`producer-first` and `drain-required` from envelope to body key and `producer-last` from
body key to envelope.

No regression. The corpus check proves every existing generated module is byte-identical,
and the existing topology goldens are unchanged. Nothing in the command, replay, snapshot
or projection paths is touched: the change is confined to contract parsing, contract code
generation, contract validation and diff, one topology field, and one new pure function in
keiro-core. The gates that measure the affected path are `keiro-dsl:test:keiro-dsl-test`,
the new conformance suite, `scripts/check-conformance-corpus.sh` and
`just topology-schema-validate`; `nix develop -c just verify` runs all of them.

Reopened review acceptance. M5 closes when the CLI produces the specified rollout
and build verdicts, fieldless events compile under `-Werror` and round-trip in both
discriminator modes, and both corrected documentation passages agree with the producer
and decoder evidence in Milestone 5. It also requires that every shape in the matrix
compiles under `-Wall -Werror`, that each rollout verdict is demonstrated by old and new
generated modules decoding each other's output in the stated order and failing in the
opposite one, that each new test is shown to fail against its defect, and that a second
implementation review is `approved`. Release additionally requires the pre-release gate.

Records. The four OKF bundles validate, and IR-64 reads back as `completed`.


## Idempotence and Recovery

Every edit is an ordinary tracked change, and every build, test and validation command can
be re-run. `keiro-dsl scaffold --out` never overwrites a hand-owned module and only
rewrites files that carry the generated banner. The regeneration driver and the corpus
check refuse a dirty corpus, so commit first. If regeneration changes an existing suite's
bytes, the generator changed output it should not have: inspect `git diff -- keiro-dsl/test`
and fix the generator, then restore only the files that run changed. Do not discard the
whole test tree; it may hold other work. `okf id next` is read-only; if another ADR lands
first, re-run it and rename the file before committing. Check a bundle's `log.md` before
retrying `okf log add`, which appends. Each milestone is its own commit and can be reverted
alone.


## Interfaces and Dependencies

`keiro-dsl/src/Keiro/Dsl/Grammar.hs` ends with:

```haskell
data ContractType
  = CScalar !ContractScalarType
  | CList !ContractScalarType
  | COptional !ContractScalarType
contractIsOptional :: ContractType -> Bool

data ContractDiscriminator = DiscriminatorBodyKey !Name | DiscriminatorEnvelope
contractBodyDiscriminator :: ContractNode -> Maybe Name
-- ContractNode { …, discriminator :: !ContractDiscriminator, … }
```

`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` gains `ContractOptionalFieldSyntax` and
`ContractEnvelopeDiscriminatorSyntax`, both in `profileV5`.

`keiro-dsl/src/Keiro/Dsl/Validate.hs` gains the `DiagnosticCode` constructors
`ContractOptionalFieldUsedAsKey` and `ContractOptionalFieldAdded`.

A generated contract module with `discriminator from envelope` exports
`parse<Contract>PayloadAs :: Text -> Value -> Either Text <Contract>Payload`. Every other
generated contract module keeps `parse<Contract>Payload :: Value -> Either Text …`.

`keiro-core/src/Keiro/Integration/Event.hs` exports `decodeJsonIntegrationEventWith` with
the signature given in Milestone 2.

No package gains a dependency. Generated modules use `aeson` (`.:?`,
`explicitParseFieldMaybe`), and for typed ids `keiro-core` and `mmzk-typeid`, as today. The
new test suite depends on what the list-fields suite depends on.

Revision note (2026-11-18). Reopened the plan with M5 after implementation review and
updated acceptance to cover rollout direction, generated-code compilation and the two
documentation corrections.

Revision note (2026-11-18, second). Re-verified the five review findings against the
working tree. All five observations reproduce. M5 now records the evidence, names both
causes of the wrong rollout remedy, widens the fieldless-event fix to body-discriminated
contracts, and reports an added optional field as a consumer-build advisory instead of a
gate-failing break.

Revision note (2026-11-18, third). Added hardening steps to M5 and a pre-release gate,
because every existing gate passed while the five defects existed. The additions compile
all generated shapes, execute the rollout verdicts, mutation-check the new tests, require
a second review, and test against the real producer's payloads and the real consumer's
decoder before release.
