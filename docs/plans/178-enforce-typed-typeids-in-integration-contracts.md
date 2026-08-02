---
id: 178
slug: enforce-typed-typeids-in-integration-contracts
title: "Enforce typed TypeIDs in integration contracts"
kind: exec-plan
created_at: 2026-08-02T03:19:29Z
intention: "intention_01kz07mj57e00rsxkcqgqxrnhs"
---

# Enforce typed TypeIDs in integration contracts

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today `keiro-dsl` recognizes a contract field such as `incidentId: typeid "inc"`, but the
contract scaffolder erases the prefix and emits `incidentId :: Text`. Its generated JSON decoder
therefore accepts `"inc-1"`, a TypeID with the wrong prefix, a non-canonical spelling, or a UUID
whose version is not 7. The syntax is present, but the generated type and admission boundary do
not enforce what it declares.

After this change, a source that selects `language keiro-dsl 4` gets a generated field of type
`KindID "inc"`. Its JSON codec continues to use canonical JSON text on the wire, but decoding
admits only the declared prefix, canonical lowercase TypeID spelling, and UUIDv7 payloads. A
consumer can see the improvement both at compile time--an `"inc"` ID cannot be passed where an
`"rsv"` ID is required--and at runtime, where a rejected value reports the contract field's JSON
path. Released language versions 1 through 3, including their generated Haskell bytes and their
historically permissive `Text` decoding, remain unchanged.

The result is observable by scaffolding the same contract under language 3 and language 4. The
language-3 module still contains `incidentId :: !Text`; the language-4 module contains
`incidentId :: !(KindID "inc")`, round-trips
`inc_01h455vb4pex5vsknk084sn02q`, and rejects `inc-1` at `$.incidentId`.


## Progress

- [x] (2026-08-02 04:01Z) Read the governing ExecPlan/ADR specifications, confirmed the active
  intention, inspected the clean worktree and profiled ADR bundle, resolved `mmzk-typeid` and
  `aeson` through Mori, and verified `mmzk-typeid` 0.7.1.1 against Hackage and upstream tags.
- [x] (2026-08-02 04:01Z) Captured the legacy baseline with
  `cabal test keiro-dsl-conformance-contract --test-show-details=direct`; both
  `IncidentTransferNeedDeclared` and `TransferReservationAccepted` passed.
- [x] (2026-08-02 04:13Z) Implemented and validated milestone 1: language 4 now selects syntax
  profile 2 and runtime semantics 3; typed `KindID` construction applies Keiro's frozen policy;
  contract prefixes validate only at the v4 boundary; and v3/v4 aggregate fold fingerprints,
  semantic diffs, and replay classifications remain equal. `cabal build keiro-core keiro-dsl`,
  all 468 `keiro-dsl-test` examples (plus property cases), and
  `keiro-dsl-conformance-id-domain-migration` passed.
- [x] (2026-08-02 04:34Z) Implemented and validated milestone 2: semantic scaffold and manifest
  routes now retain the checked language contract; language 4 emits prefix-indexed `KindID`
  fields, frozen field-path decoders, complete dependencies, and durable per-field identities in
  single-file and workspace records. The checked module is byte-identical to fresh scaffold
  output, the six-case typed conformance target and two-case legacy target pass, and all 470
  `keiro-dsl-test` examples (plus property cases) pass.
- [x] (2026-08-02 04:51Z) Implemented and validated milestone 3: graph-identical v3-to-v4
  contract fields emit `ContractTypeIdDomainChanged` with public-consumer and consumer-build
  breakage, producer-first plus drain-required rollout, and the ordered operational remedy; source
  field edits are not duplicated. Text/JSON goldens, gate assertions, v1-to-v3 and same-version
  negative cases, and all 471 DSL examples pass. ADRs 4, 12, and 16 and both package changelogs
  record the boundary; the single bundle-log update was added and strict validation reports
  `OK: 17 concepts`.
- [ ] Complete milestone 4: mutation-style compatibility evidence, repository-wide checks, and
  final ADR distillation.


## Surprises & Discoveries

- Observation: `mmzk-typeid` 0.7.1.1 rejects uppercase TypeID suffix characters during parsing,
  before Keiro's byte-for-byte canonical-render comparison can classify them.
  Evidence: the dependency's `Data.TypeID.Internal.decodeUUID` table accepts only canonical
  lowercase Crockford characters, while the plan requires a stable failure distinct from a
  structurally malformed value. `validateIdDomainText` now retries only the lowercase spelling
  for classification; acceptance remains unchanged.


## Decision Log

- Decision: Introduce the behavior as language version 4, selecting syntax profile 2 and a new
  `keiro-dsl/runtime-semantics/3`, rather than changing versions 1 through 3.
  Rationale: Released language meanings are immutable. The contract syntax already exists, so the
  successor needs a semantic profile change rather than a grammar change.
  Date: 2026-08-01

- Decision: Lower a version-4 `typeid "inc"` contract field to `KindID "inc"`, not to unqualified
  `TypeID` or a generated newtype around `Text`.
  Rationale: `KindID` carries the prefix in the Haskell type, so different contract ID domains are
  not interchangeable. The existing Keiro ID-domain validator remains the authority for canonical
  spelling and UUIDv7 admission.
  Date: 2026-08-01

- Decision: Add service-aware contract scaffold and manifest entry points while retaining the
  current `Spec`-only functions as legacy/version-1 wrappers.
  Rationale: CLI and workspace routes already own a `CheckedService`; discarding it is the bug.
  Removing the old entry points would create an unnecessary Haskell API break for callers that
  intentionally request legacy generation.
  Date: 2026-08-01

- Decision: Keep language-4 aggregate ID admission and aggregate fold fingerprints equal to
  language 3, and add a separate contract-ID-domain capability that is enabled only by runtime
  semantics 3.
  Rationale: Contract DTO decoding changes in language 4, but aggregate folds and the language-3
  generated-ID contract do not. A coarse numeric inheritance rule would either disable existing
  enforcement or invalidate unrelated snapshots.
  Date: 2026-08-01

- Decision: Classify language-3-to-4 contract TypeID tightening separately from a source-level
  field-type edit, with public-consumer and consumer-build breakage plus producer-first and drain
  rollout constraints.
  Rationale: The normalized contract graph is unchanged, yet newly generated consumers reject
  legacy-invalid messages and expose a different Haskell field type. Producers must emit valid
  values before strict consumers deploy, and invalid in-flight messages must leave the channel.
  Date: 2026-08-01

- Decision: Classify an input as `IdDomainNonCanonical` when its lowercase spelling parses and
  renders canonically, even though the current dependency rejects the original uppercase bytes
  before canonical rendering.
  Rationale: This preserves the frozen lowercase admission rule, keeps malformed and
  non-canonical evidence distinct as required, and does not admit or normalize the input.
  Date: 2026-08-02


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

An integration contract is the public Kafka message schema represented by `ContractNode` in
`keiro-dsl/src/Keiro/Dsl/Grammar.hs`. Each `ContractField` has a `ContractType`; the relevant
constructor is `CTypeId Text`, whose `Text` stores the prefix from the source spelling
`typeid "prefix"`. `keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs` already parses that spelling.
No grammar or semantic-AST addition is required.

The loss occurs in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`. `scaffoldContract` calls
`emitContractGen`, whose local type renderer currently defines `hsType (CTypeId _) = "Text"`.
The same emitter encodes every field with Aeson's `(.=)` and decodes every field with `(.:)`, so
the declared prefix is unused. The checked fixture
`keiro-dsl/test/conformance-contract/Generated/HospitalCapacity/Emergency/Contract.hs` shows that
output, and `keiro-dsl/test/conformance-contract/Main.hs` currently passes values such as
`"inc-1"` and `"rsv-1"`. Running
`cabal test keiro-dsl-conformance-contract --test-show-details=direct` before this plan passed both
events; that is the reproducible defect, not evidence that those strings are valid TypeIDs.

Language provenance is already available. `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` registers
versions 1, 2, and 3. Versions 2 and 3 share syntax profile 2, while version 3 selects runtime
semantics 2. `keiro-dsl/src/Keiro/Dsl/SemanticContract.hs` resolves the registry entry into an
`EffectiveLanguageContract` and pairs it with `Spec` as `CheckedService`. `ScaffoldRun.hs` and
`WorkspaceScaffold.hs` carry a checked service but currently call `scaffoldContract ctx contract`
and `renderManifest ... spec`, discarding the semantic profile at precisely the two places that
need it. `validateCheckedSpec` in `keiro-dsl/src/Keiro/Dsl/Validate.hs` also ignores the effective
contract when it reaches `NContract`; it currently returns no contract-local diagnostics.

Keiro's runtime ID authority lives in `keiro-core/src/Keiro/Codec/IdDomain.hs`. The frozen
`keiro-dsl/id-domain/typeid-v7/1` contract parses text with `mmzk-typeid`, compares the actual and
declared prefixes, requires byte-for-byte canonical rendering, and calls the dependency's UUIDv7
check. `keiro-dsl/src/Keiro/Dsl/IdDomain.hs` selects that contract for generated and consumer-bound
IDs only under runtime semantics 2. It also creates durable identity strings stored by
`ScaffoldRecord.hs` and `WorkspaceRecord.hs`. Language 4 must explicitly retain that version-3
selection and add contract-field identities without replacing either record format.

The dependency at `mori://MMZK1526/mmzk-typeid/packages/mmzk-typeid` provides
`Data.KindID.KindID`, `parseText`, and `toText`. `KindID "inc"` is prefix-distinct at the type level,
but the dependency's parser alone does not own Keiro's complete frozen admission policy; Keiro must
still perform its canonical-render and UUIDv7 checks. The authoritative package registry and
upstream tags both report 0.7.1.1 as the current release, so the existing
`mmzk-typeid >=0.7 && <0.8` bounds in `keiro-core` and `keiro-dsl` need no change. Aeson
`explicitParseField` from `mori://haskell/aeson/packages/aeson` applies the key path to a custom
`Value -> Parser a`, allowing the typed decoder to preserve errors such as `$.incidentId`.

`keiro-dsl/src/Keiro/Dsl/Manifest.hs` currently assigns a contract only `aeson` and `text`.
Language-4 generated contract modules additionally import `keiro-core` for the frozen parser and
`mmzk-typeid` for `KindID`; language-1-to-3 manifests must remain unchanged. The generated encoder
must call `Data.KindID.toText` explicitly because `KindID` has no Aeson instance in the verified
dependency source.

`keiro-dsl/src/Keiro/Dsl/Diff.hs` compares `CheckedService` values and already reports semantic
ID-domain changes for aggregate declarations. It does not compare the admission domain of
contract fields. `CompatibilityVector` has independent `PublicConsumer` and `ConsumerBuild`
surfaces, while `RolloutConstraint` currently has no producer-first value.
`keiro-dsl/src/Keiro/Dsl/DiffReport.hs` serializes these vectors and chooses remedies. A
language-3-to-4 comparison of an otherwise identical contract therefore needs its own append-only
diagnostic code, vector, rollout spelling, remedies, and text/JSON regression fixtures.

[ADR 16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) freezes
released language versions, requires semantic consumers to use `CheckedService`, and documents
`Spec`-only APIs as legacy/version-1 wrappers. It must be amended with version 4, runtime semantics
3, and the fact that a runtime profile may preserve the predecessor's aggregate-fold projection.
[ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) requires validation,
diff, generated-code, and runtime evidence to be placed at the earliest boundary that owns it; its
gate inventory must include contract prefix validation and contract decoder tightening.
[ADR 12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
keeps private schemas and public contract DTOs separate and establishes the Keiro-owned exact ID
domain for generated and consumer-bound IDs. It must record that language-4 public contract DTOs
reuse that authority without becoming private aggregate types.


## Plan of Work

### Milestone 1: Register and validate the language-4 admission contract

Add version 4 to the append-only registry in `LanguageVersion.hs`, with predecessor 3, syntax
profile 2, and `keiro-dsl/runtime-semantics/3`. Update the registry, parser-dispatch, JSON, and
frontend-profile tests that currently enumerate versions 1 through 3 or expect version 4 to be
unsupported. Do not add a syntax feature or widen the language-1-to-3 parser profiles.

In `keiro-core/src/Keiro/Codec/IdDomain.hs`, add reusable typed parsing functions that first apply
`validateIdDomainText` to the prefix reflected from the type-level symbol and only then construct
the corresponding `KindID`. Provide both a `Text` entry point and an Aeson `Value -> Parser` entry
point so generated decoders share one policy and one error rendering. Unit coverage in
`keiro-dsl-test` must prove valid construction and the four distinct failures: malformed text,
wrong prefix, non-canonical spelling, and a non-v7 UUID.

Refine `keiro-dsl/src/Keiro/Dsl/IdDomain.hs` with an explicit selection table. Existing
`idDomainContractFor` returns the same TypeID-v7 contract for runtime semantics 2 and 3. A new
`contractIdDomainContractFor` returns it only for runtime semantics 3. Update
`runtimeSemanticsFingerprintSegment` in `SemanticContract.hs` so versions 3 and 4 deliberately
produce the same aggregate-fold segment, then prove their unchanged aggregate fold fingerprints
and replay classification are equal.

Thread `EffectiveLanguageContract` into contract validation in `Validate.hs`. For every
`CTypeId prefix` under the language-4 contract, call `Data.TypeID.checkPrefix`; append a stable
`ContractInvalidTypeIdPrefix` diagnostic for an invalid prefix and report the owning contract,
event, field, prefix, and reason at the contract's available source line. Language 1 through 3
continue accepting the same graph because they still lower the field as text.

Milestone 1 is complete when language 4 parses and validates, invalid contract prefixes fail at
`check`, generated/consumer-bound ID behavior remains equal between versions 3 and 4, and no
unchanged aggregate receives a fold or replay change merely because its source declares version 4.

### Milestone 2: Generate typed contract modules through service-aware APIs

In `Scaffold.hs`, retain `scaffoldContract :: Context -> ContractNode -> [ScaffoldModule]` as the
legacy wrapper and add `scaffoldContractForService :: Context -> CheckedService -> ContractNode ->
[ScaffoldModule]`. Make the internal emitter accept the effective contract. For versions 1 through
3, execute the existing branch byte-for-byte. For version 4, emit `DataKinds` and
`TypeApplications`, import `KindID` plus its qualified renderer and Keiro's typed parser, render
`CTypeId "inc"` as `KindID "inc"`, encode it through `KindID.toText`, and decode it through
`explicitParseField` and the typed Keiro parser. `CText` and `CInt` stay unchanged.

Change only semantic routes to use the new function: the `NContract` cases in `ScaffoldRun.hs` and
`WorkspaceScaffold.hs`. Apply the same compatibility pattern in `Manifest.hs`: add
`manifestDependenciesForService` and `renderManifestForService`, keep the current functions as
legacy wrappers, and make CLI/workspace scaffold output use the service-aware functions. A
language-4 contract contributes `keiro-core` and `mmzk-typeid` in addition to `aeson`, `base`, and
`text`; older language contracts retain their exact dependency list.

Extend `idDomainIdentitiesForService` to include one stable identity per enforcing contract field,
using an unambiguous owner such as `contract:<contract>.<event>.<field>` and the existing
`idDomainIdentity` format. The current `id-domain` row kind in `ScaffoldRecord.hs` and
`WorkspaceRecord.hs` can persist these identities without a schema change; add parse/render,
duplicate, drift, and workspace attribution tests rather than adding a parallel record field.

Keep `keiro-dsl/test/fixtures/contract.keiro` and the existing
`keiro-dsl-conformance-contract` target as the language-1 compatibility proof. Add
`contract-v4.keiro` and a separate `keiro-dsl-conformance-contract-typeid` Cabal test component
whose checked-in generated module is byte-identical to the service-aware scaffold. Its driver
constructs prefix-distinct `KindID` values, round-trips both events, and checks field-path-bearing
rejections. This avoids rewriting the historical fixture into evidence for the new semantics.

Milestone 2 is complete when the v4 module compiles with `KindID "inc"`, valid JSON bytes are
unchanged, every invalid sample is rejected at its field path, v4 manifests name all imports, and
the original permissive conformance target and generated bytes still pass unchanged.

### Milestone 3: Make the semantic tightening visible to diff and operations

Append `ContractTypeIdDomainChanged` to `DiagnosticCode` in `Validate.hs` and
`RolloutProducerFirst` to `RolloutConstraint` in `Diff.hs`. In `diffServices`, align old and new
contract fields by contract, event, and field name and compare their
`contractIdDomainContractFor` results after the ordinary graph diff. An unchanged `CTypeId "inc"`
moving from version 3 to version 4 produces one dedicated finding; a source-level prefix or field
type edit continues to use the established `ContractFieldChanged` path and must not be duplicated.

Give the new finding a vector with `PublicConsumer = VBreaking`, `ConsumerBuild = VBreaking`, all
unrelated surfaces not applicable, and both `RolloutProducerFirst` and `RolloutDrainRequired`.
Update `DiffReport.hs` so text, JSON, `--gate public-consumer`, and `--gate consumer-build` agree.
The ordered remedy is: make all producers emit the frozen TypeID-v7 domain, drain or remediate
legacy-invalid in-flight messages, re-scaffold and recompile consumers, then run contract
conformance. Add focused text and JSON goldens for v3-to-v4; also prove v1-to-v3 and same-version
comparisons do not report the new code.

Amend ADRs 4, 12, and 16 with the landed boundary decisions, append one bundle-log entry with
`okf log add`, and update `keiro-core/CHANGELOG.md` and `keiro-dsl/CHANGELOG.md`. The documentation
must call out the generated Haskell type change, unchanged JSON representation for valid values,
runtime rejection policy, dependencies, and rollout sequence.

Milestone 3 is complete when diff output tells an operator why the graph-identical upgrade is
breaking and gives a safe deployment order, ADR strict validation passes, and the change is
represented in both package changelogs.

### Milestone 4: Close conformance and compatibility evidence

Run the focused and full suites from a clean build context. Pin service-aware single-file and
workspace generated output, manifests, scaffold-record identities, diff text/JSON, and compiled
contract behavior. Add mutation-style negative assertions that would fail if the generator
returned `Text`, skipped the frozen validator, used plain `(.:)` for typed fields, omitted either
new dependency, applied v4 behavior to an older language, or changed the aggregate fold segment.

Inspect the final diff for accidental edits to the language-1 contract module and for diagnostic
or rollout constructor reordering. Build all packages, run the Nix flake checks, and run the strict
ADR bundle validator. Record command results and any deviations in this plan's living sections.

Milestone 4 is complete when the focused tests demonstrate the behavior, the historical contract
target proves backward compatibility, and the repository-wide build and checks pass.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/keiro`.

Capture the current defect before editing. This target is intentionally retained as the legacy
proof after the fix:

```bash
cabal test keiro-dsl-conformance-contract --test-show-details=direct
```

The current short transcript is:

```text
PASS  IncidentTransferNeedDeclared
PASS  TransferReservationAccepted
```

Those events currently contain `inc-1`, `rsv-1`, and `hsp-1`; language-1 acceptance is expected.

After milestone 1, run the language, validation, ID-domain, fold, diff, and record unit suite plus
the existing ID-domain migration conformance:

```bash
cabal build keiro-core keiro-dsl
cabal test keiro-dsl-test --test-show-details=direct
cabal test keiro-dsl-conformance-id-domain-migration --test-show-details=direct
```

Expected result: version 4 appears after version 3 in the registry, invalid v4 contract prefixes
produce `ContractInvalidTypeIdPrefix`, and all suites report `PASS` with no v3-to-v4 aggregate
fingerprint drift.

After milestone 2, compile and run both contract contracts:

```bash
cabal test keiro-dsl-conformance-contract --test-show-details=direct
cabal test keiro-dsl-conformance-contract-typeid --test-show-details=direct
```

The new target's transcript must include successful round trips and named rejections resembling:

```text
PASS  IncidentTransferNeedDeclared round-trip
PASS  TransferReservationAccepted round-trip
PASS  malformed $.incidentId
PASS  wrong-prefix $.incidentId
PASS  non-canonical $.incidentId
PASS  non-v7 $.incidentId
```

After milestone 3, update the ADR bundle log once and validate it:

```bash
okf log add docs/adr --kind Update -m "Record language-4 typed integration-contract TypeID admission and rollout semantics (plan 178)."
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Expected result: `okf validate` exits zero with no stale-log or profile error.

Finish with the relevant compiled workspace proof and repository-wide checks:

```bash
cabal test keiro-dsl-conformance-workspace-nominals --test-show-details=direct
cabal test keiro-dsl-test --test-show-details=direct
cabal build all
nix flake check
git diff --check
```

Record the final test counts and the exact v3-to-v4 diff transcript in Progress and Outcomes before
marking the ExecPlan complete.


## Validation and Acceptance

Acceptance is behavioral, not just successful compilation.

For language versions 1, 2, and 3, scaffolding `contract.keiro` must continue to render every
`CTypeId` field as strict `Text`, use the existing imports and `(.:)` decoder, and produce the same
module bytes and manifest dependencies as the pre-change fixture. `inc-1` remains accepted by the
language-1 conformance component because changing that behavior would mutate a released language.

For language version 4, `incidentId: typeid "inc"` must render as
`incidentId :: !(KindID "inc")`; a field declared with `"rsv"` must be a different Haskell type.
Encoding a valid value produces the same JSON string as `KindID.toText`. Decoding must accept
`inc_01h455vb4pex5vsknk084sn02q` and round-trip the complete payload. It must reject all of:

- `inc-1`, as malformed;
- `rsv_01h455vb4pex5vsknk084sn02q`, as the wrong prefix;
- an uppercase or otherwise non-canonical spelling of the valid suffix;
- `inc_00041061050r3gg28a1c60t3gf`, because the UUID is not version 7.

Each decoder error must contain `$.incidentId` (or the actual failing field path), not merely a
module-level parse error. A v4 contract declaration with a prefix rejected by
`Data.TypeID.checkPrefix` must fail `keiro-dsl check` with `ContractInvalidTypeIdPrefix` before any
Haskell is written.

The language-4 manifest must include exactly the older contract dependencies plus `keiro-core` and
`mmzk-typeid`. Single-file and workspace scaffold routes must generate the same contract bytes and
persist the same contract-field ID-domain identity. Calling the compatibility wrappers directly
must still select legacy behavior.

Comparing graph-identical language-3 and language-4 services must produce
`ContractTypeIdDomainChanged` for every `CTypeId` contract field and no `ContractFieldChanged`,
`IdDomainContractChanged`, `AggFoldSurfaceChanged`, snapshot invalidation, or replay impact. Its
vector must break `public-consumer` and `consumer-build`, and name both `producer-first` and
`drain-required`. Comparisons that do not cross the enforcing boundary must not produce that code.

The work is accepted only when both contract conformance targets, `keiro-dsl-test`, the existing
ID-domain migration conformance, the relevant workspace conformance, `cabal build all`,
`nix flake check`, and strict ADR validation all pass.


## Idempotence and Recovery

Registry additions, diagnostic constructors, rollout constructors, fixtures, and record identities
are deterministic edits and can be rebuilt or retested repeatedly. Generate candidate modules in a
temporary output directory first; copy them into the checked conformance tree only after their
bytes and manifest match the expected service-aware output. Re-running scaffold over generated
files is safe, but hand-owned files and unrelated dirty worktree changes must not be overwritten.

If a milestone fails, revert only that milestone's uncommitted edits or correct the generator and
regenerate its fixtures. Do not remove or reorder an already released language registry entry,
diagnostic code, or rollout spelling to make a golden pass. The existing language-1 conformance
module is the recovery oracle: any unexpected change there means the semantic branch leaked into
the legacy wrapper and must be fixed before proceeding.

Scaffold and workspace record formats remain forward-compatible because the implementation adds
values to the existing `id-domain` row kind. Older records without contract identities continue to
parse. If identity rendering changes during implementation, settle the canonical rendering before
checking in fixtures; do not add a migration for a shape that was never released.


## Interfaces and Dependencies

`keiro-core/src/Keiro/Codec/IdDomain.hs` will export typed helpers with the effective interfaces:

```haskell
parseKindIdV7Text
  :: forall prefix
   . ValidPrefix prefix
  => Text
  -> Either IdDomainFailure (KindID prefix)

parseKindIdV7Value
  :: forall prefix
   . ValidPrefix prefix
  => Value
  -> Parser (KindID prefix)
```

The value parser first parses JSON text, delegates to `parseKindIdV7Text`, and renders a stable
failure for Aeson. It does not define a competing ID-domain policy.

`keiro-dsl/src/Keiro/Dsl/IdDomain.hs` retains the existing generated-ID selector and adds the
contract-specific selector:

```haskell
idDomainContractFor
  :: EffectiveLanguageContract -> Text -> Maybe IdDomainContract

contractIdDomainContractFor
  :: EffectiveLanguageContract -> Text -> Maybe IdDomainContract
```

The first returns the same enforcing contract for runtime semantics 2 and 3. The second returns it
only for runtime semantics 3. `idDomainIdentitiesForService :: CheckedService -> [Text]` remains the
record-facing aggregate and includes contract field identities only when the latter selector is
active.

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` adds:

```haskell
scaffoldContractForService
  :: Context -> CheckedService -> ContractNode -> [ScaffoldModule]
```

The existing `scaffoldContract` selects `effectiveLanguageContract LegacyUnversioned`, while the
service-aware function selects `checkedLanguageContract`; both share the same internal emitter.
The emitter accepts an `EffectiveLanguageContract` and is not a second public semantic authority.

`keiro-dsl/src/Keiro/Dsl/Manifest.hs` adds:

```haskell
manifestDependenciesForService :: CheckedService -> [Text]

renderManifestForService
  :: Text -> [ScaffoldModule] -> CheckedService -> Text
```

`manifestDependencies` and `renderManifest` retain their current signatures and delegate through
`legacyCheckedService`. CLI and workspace code use only the service-aware variants.

`keiro-dsl/src/Keiro/Dsl/Validate.hs` appends
`ContractInvalidTypeIdPrefix` and `ContractTypeIdDomainChanged` to `DiagnosticCode`.
`keiro-dsl/src/Keiro/Dsl/Diff.hs` appends `RolloutProducerFirst` and maps it to
`"producer-first"` in `DiffReport.hs`; existing constructor order and spellings are preserved.

The implementation uses the already bounded packages
`mori://MMZK1526/mmzk-typeid/packages/mmzk-typeid` and
`mori://haskell/aeson/packages/aeson`. No new package or bound change is expected in the Keiro
libraries. Generated language-4 consumer components must declare `keiro-core` and `mmzk-typeid` in
addition to their existing contract dependencies.
