---
id: 192
slug: decouple-wire-keys-from-generated-haskell-selectors-with-field-aliases
title: "Decouple wire keys from generated Haskell selectors with field aliases"
kind: exec-plan
created_at: 2026-08-05T04:54:27Z
intention: "intention_01kz84b5jre3187dmmyjmd02fc"
master_plan: "docs/masterplans/29-stabilize-keiro-dsl-for-wide-adoption.md"
---

# Decouple wire keys from generated Haskell selectors with field aliases

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today the unreleased keiro-dsl refuses to scaffold Mori's committed, previously working
workspace. The contract field `family: text` in `mori://shinzui/mori`, project-relative path
`domain/project-signals.keiro` (artifact-level source URI pending), is refused
with `error[GeneratedOccurrenceReserved]: contract field 'family' normalizes to reserved Haskell
occurrence 'family'`, printed twice, and `scaffold` exits 1 without writing a file. The refusal
is doubly wrong. First, `family` is not actually reserved: GHC accepts it as an ordinary
identifier under the exact compilation contract keiro-dsl generates (`family` is special only
inside `type family …` declarations). Second, even for a genuinely reserved word such as `type`,
the refusal is a dead end: a spec field's one name is simultaneously its DSL identity, its
generated Haskell record selector, and its serialized JSON wire key, so the only remedy —
renaming the field — changes the bytes on a live Kafka topic (`mori.project.v1`). A naming
refusal must never force a wire break.

After this plan, two things are true. The reserved-word policy matches what GHC actually rejects
under the generated-language contract, so `family`, `via`, `qualified`, and nine other contextual
words are ordinary field names again and Mori's workspace scaffolds unchanged. And every direct
aggregate command/event field and every contract event field can optionally declare an
independent generated Haskell selector (`haskell <name>`) and/or an independent quoted wire key
(`as "<key>"`) while its DSL identity stays stable, so the residual hard-keyword refusals
(`type`, `case`, `default`, …) become actionable: give the field a selector alias and keep the
wire key. A field with DSL identity `type`, selector alias `payloadType`, and unchanged wire key
`"type"` scaffolds, encodes `"type": …` on the wire, and exposes `payload.payloadType` in
Haskell. Changing only a selector is a rebuild advisory; changing a wire key is classified as
the wire break it really is. An alias-free spec produces byte-identical generated output, proven
by the existing committed conformance corpus.

This plan is EP-192 of `docs/masterplans/29-stabilize-keiro-dsl-for-wide-adoption.md` (Phase 1,
release unblock). It implements
`docs/improvement-requests/allow-independent-haskell-selector-and-wire-key-aliases-on-direct-aggregate-fields.md`
(IR-6) and deliberately widens it from direct aggregate fields to contract event fields, because
the motivating regression is a contract field.


## Progress

- [x] (2026-08-04 PDT) Verified the regression and researched the implementation surface:
  `haskellKeywords` in `keiro-dsl/src/Keiro/Dsl/HaskellName.hs`, the raise site in
  `keiro-dsl/src/Keiro/Dsl/Validate.hs`, the contract and domain emitters in
  `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, the fold-identity encoder, the diff classifier, and the
  language feature-gate mechanism. Authored this plan under MasterPlan 29.
- [x] (2026-08-05 05:02 PDT) Milestone 1: trimmed the reserved-word policy to the generated-language contract, added the
  resolved field-identity model, admit `haskell`/`as` alias syntax on direct aggregate and
  contract fields under language 4, and round-tripped it through the pretty printer. Verified
  with `cabal build keiro-dsl`, 22 naming examples plus 100 collision-order properties, five
  released-profile examples, the focused alias round trip, and all six frontend-0.7
  compatibility examples.
- [x] (2026-08-05 05:14 PDT) Milestone 2: completed checked resolution — selector validation, reserved residuals, selector and
  wire-key collision refusal at `check` with per-field locations, including the contract-field
  location fix that removes the doubled diagnostic. The nine focused identifier-hygiene examples
  cover selector validity/collisions, empty/duplicate/envelope wire keys, copied command fields,
  field-local contract diagnostics, and workspace member mapping; the Mori-shape CLI check exits
  0 with `OK`.
- [x] (2026-08-05 06:08 PDT) Milestone 3: made records consume selectors and codecs/goldens consume wire keys while
  `fields(Command)` and hand-owned output hooks continue pairing by DSL identity. Regenerated
  the contract and aggregate-scalars conformance trees through the public scaffolder; both
  compiled suites pass, including all eleven contextual selectors. Added the ordinary
  aggregate-field-alias fixture and regressions for copied identities, golden keys,
  deterministic/single-workspace generation, and exact fold-fingerprint neutrality. The full
  557-example unit run found two stale fixture-shape expectations; both focused reruns pass
  after anchoring the TypeID diagnostic at its field and retaining the language declaration in
  the alias-bearing pretty-print round trip. The frozen fold baseline remains bit-identical.
- [x] (2026-08-05 PDT) Milestone 4: classified selector-only changes as build advisories and
  aggregate event wire-key changes as breaking `EvtFieldWireKeyChanged` replay hazards, while
  contract wire changes reuse `ContractFieldChanged`. Published ADR 0021, amended ADRs 0019 and
  0004, closed IR-6 with its contract-field scope, and updated user docs and changelogs. The full
  560-example DSL suite and every conformance component pass, as do `cabal build all`, both
  generated-code policy scripts, strict ADR validation, and `git diff --check`. Strict
  improvement-request validation reaches the pre-existing IR-19 record and fails only because
  that unrelated record lacks the profile-recommended `reviews` field; this inherited
  repository baseline is recorded below rather than repaired without review evidence.


## Surprises & Discoveries

- Observation: the doubled diagnostic has a structural cause, not a rendering bug. `ContractField`
  in `keiro-dsl/src/Keiro/Dsl/Grammar.hs` carries no source location, so `validateNames` anchors
  every contract-field diagnostic at the contract's own line (`ctrLoc`), and Mori declares
  `family: text` in two different events of one contract — two legitimate refusals that render as
  the same line and message twice.
  Evidence: `contractFieldName contract field = fieldNameRule "contract field" (cfName field)
  (ctrLoc contract)` at `keiro-dsl/src/Keiro/Dsl/Validate.hs:1203`, and `family` appearing in
  both `ProjectChanged` and `ProjectArtifactChanged` in `mori://shinzui/mori`, project-relative
  path `domain/project-signals.keiro` (an artifact-level URI for this source file is pending).

- Observation: the repository already contains three divergent Haskell keyword sets:
  `HaskellName.haskellKeywords` (34 words, the over-broad set behind the regression), a private
  25-word copy in `keiro-dsl/src/Keiro/Dsl/NominalType.hs` used for consumer binding symbols, and
  `HaskellImport.hs` reusing the broad set for import aliases. The trim must leave exactly one
  authoritative set.

- Observation: the generated event-output canonical text that feeds the frozen fold fingerprint
  already carries separate `outputSelector` and `outputWireName` slots
  (`keiro-dsl/src/Keiro/Dsl/EventOutput.hs`), both currently populated with the DSL field name.
  Fingerprint neutrality therefore requires pinning both slots to the DSL identity forever;
  resolved aliases must never flow into them.

- Observation: the pre-change Mori-shape fixture reproduced the regression exactly before any
  policy edit: `keiro-dsl check` exited 1 and printed two byte-identical
  `GeneratedOccurrenceReserved` errors at contract line 4. After Milestone 1's truthful keyword
  set, the same source exits 0 and prints `OK`; Milestone 2 still owns proving field-local errors
  for genuinely reserved selectors.
  Evidence:

  ```console
  $ nix develop -c cabal run keiro-dsl -- check keiro-dsl/test/fixtures/contract-reserved-family.keiro
  # before: exit 1 and two identical line-4 errors
  # after:  exit 0 and OK
  ```

- Observation: the stable contract component now names `contract-v4.keiro` in the conformance
  baseline, while older generator and diff tests continue to use the byte-identical
  `contract.keiro`. The alias proof must update both source fixtures and their single-fault diff
  derivatives so existing evolution tests remain single-variable comparisons.
  Evidence: the public scaffold record reported the prior `contract-v4.keiro` source when the
  plan-prescribed `contract.keiro` command regenerated the same module; the focused contract
  test group passes after both fixtures and seven derivatives carry the common fields.

- Observation: repository-wide strict improvement-request validation has an inherited failure
  outside EP-192. It accepts the implemented IR-6 record and log far enough to report only IR-19,
  whose existing concept lacks the profile-recommended `reviews` field. Adding fabricated review
  evidence would be worse than preserving the truthful baseline, so EP-192 records the exception;
  strict ADR validation succeeds for all 21 ADR concepts.
  Evidence: `okf validate docs/improvement-requests --strict --profile
  mori/improvement-requests-profile.dhall --profile-enforce --log-enforce` reports
  `give-keiro-dsl-generated-sidecars-honest-names-and-one-durability-contract: missing
  profile-recommended field: reviews`.


## Decision Log

- Decision: Trim `haskellKeywords` to the 23 words GHC actually rejects as term-level
  identifiers under the ADR 0019 contract (GHC2024, `OverloadedStrings` default, closed local
  set `BlockArguments`, `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`,
  `OverloadedRecordDot`, `QualifiedDo`, `TemplateHaskell`, `TypeFamilies`): the Haskell 2010
  reserved identifiers `case class data default deriving do else foreign if import in infix
  infixl infixr instance let module newtype of then type where` plus `forall`, which modern GHC
  (9.10+, the GHC2024 generation) rejects as an identifier unconditionally. Remove the eleven
  contextual or wrong-extension words `as family mdo proc qualified rec safe signature stock
  unsafe via`: `family` is special only in `type family`/`data family` positions even with
  `TypeFamilies` enabled; `as`/`qualified`/`safe`/`unsafe`/`signature` are contextual in import
  and Backpack headers; `via`/`stock` are contextual inside `deriving` clauses; and
  `mdo`/`rec`/`proc` belong to `RecursiveDo`/`Arrows`, which the closed local set does not
  contain. Each removed word is compile-proven by a committed conformance fixture selector.
  Rationale: the reserved set is a refusal surface; every false positive is a forced wire break
  for a brownfield contract. The set must be exactly the compilation contract's rejections, no
  wider and no narrower.
  Date: 2026-08-04

- Decision: Implement IR-6 for direct aggregate command/event fields and widen it to contract
  event fields in the same plan. Registers, process/router input fields, workqueue payload
  fields, and structural mapped records (which already have `as "wire_key"`) are out of scope.
  Rationale: the motivating regression is a contract field, which IR-6 as written does not
  cover; trimming without aliases leaves hard keywords as wire-breaking dead ends, and aliases
  without trimming keep false refusals. Registers have no wire key, and the other node-family
  fields have no generated JSON codec of their own.
  Date: 2026-08-04

- Decision: Canonical alias syntax places both optional clauses between the field name and the
  type annotation, in fixed order: `<name> [haskell <selector>] [as "<wireKey>"] [: <Type>]` on
  aggregate fields and `<name> [haskell <selector>] [as "<wireKey>"] : <contractType>` on
  contract fields.
  Rationale: `as "<key>"` reuses the exact structural-record vocabulary of ADR 0012
  (`keiro-dsl/src/Keiro/Dsl/Parser/Mapped.hs` `pWireField`), and `haskell` reuses the existing
  mapped-declaration keyword for consumer Haskell facts. Placing the clauses before the colon
  avoids any ambiguity with the mapped type-expression grammar that follows the colon.
  Date: 2026-08-04

- Decision: Gate alias syntax on a new `FieldAliasSyntax` grammar feature owned by a new
  immutable syntax profile `keiro-dsl/syntax-profile/3` (profile 2 plus `FieldAliasSyntax`),
  selected by the language-4 registry row from the next release. Languages 1–3 refuse the
  `haskell`/`as` markers with the existing `LanguageFeatureRequiresVersion` failure.
  Rationale: this is an additive optional production — every previously accepted source parses
  to identical `Grammar` values — and the two frontend freeze oracles permit it: the 0.7 corpus
  (ExecPlan 172, `keiro-dsl/test/frontend-0.7/manifest.json`) freezes accept/reject behavior for
  released contracts 1–3, which keep refusing the markers, and the stable baseline (ExecPlan
  183, `keiro-dsl/test/conformance-baseline.json`) pins fixtures, not the universe of inputs.
  Profiles themselves stay immutable: profile 2 is untouched and versions 2–3 keep their exact
  released grammar, honoring their compatibility-only support status. The syntax-profile
  identifier is not persisted in any serialized record (verified: no serialization site outside
  `LanguageVersion.hs`), so no stored artifact changes meaning. The rejected alternative — a new
  language version 5 — would either need a second `Stable` registry entry (forbidden: the
  registry requires exactly one) or force re-baselining all ~239 fixtures and ~33 compiled
  components for one optional production.
  Date: 2026-08-04

- Decision: The resolved default selector is the raw DSL field name bytes, not the segmented
  lowerCamel derivation; an explicit `haskell` alias is validated verbatim and never re-cased.
  Rationale: alias-free byte identity is a hard requirement. Today's emitters use the raw field
  name as the selector, so any silently re-derived default would change released output. The
  existing quirk that the collision inventory normalizes (`serviceOncall`) while the emitter
  writes raw bytes is pre-existing and is preserved for byte stability; the identity model makes
  it explicit instead of accidental.
  Date: 2026-08-04

- Decision: The frozen fold-identity encoder never sees aliases. `eventOutputCanonical`,
  `canonicalExpr`, and every `FoldFingerprint.hs` segment continue to encode only DSL
  identities; resolved selectors and wire keys are applied downstream in renderers, goldens,
  and diff. Consequently a selector alias is replay-neutral and fingerprint-neutral, and a
  wire-key alias changes wire bytes without changing fold identity — the diff layer, not the
  fingerprint, carries the wire hazard.
  Rationale: fold fingerprints answer "does the same history fold to the same state", which is
  independent of both Haskell presentation and JSON spelling; the encoder is frozen by ADR 0018
  and `keiro-dsl/test/fixtures/fold-identity-baseline.golden`.
  Date: 2026-08-04

- Decision: Evolution classification. A selector-only change (alias added, removed, or edited
  while the resolved wire key is unchanged) reuses the existing `GeneratedHaskellNameChanged`
  advisory (consumer-build only, replay-neutral), matching ADR 0019's naming-edition precedent
  and the mapped-record selector rule in ADR 0012. A wire-key change on an aggregate event
  field is a new append-only breaking code `EvtFieldWireKeyChanged` with the same
  private-history-read and old-binary-read-new-events verdicts and replay-impact contribution as
  a same-version field remove/add today. A wire-key change on a contract field reuses
  `ContractFieldChanged` (public-consumer breaking) with a wire-key message. A command-field
  wire-key change is classified at every event that copies it through `fields(Command)`.
  Date: 2026-08-04

- Decision: New check-time diagnostics are the append-only codes `FieldWireKeyCollision`
  (duplicate resolved wire key inside one record, or a wire key equal to the record's envelope
  key — `"kind"` for aggregate events, the declared discriminator for contract events) and
  `FieldWireKeyInvalid` (empty wire key). Selector problems reuse the existing codes:
  `GeneratedOccurrenceReserved` for residual reserved selectors, `IdentUnsafeNormalization` for
  invalid explicit selectors, and `GeneratedOccurrenceCollision` for normalized collisions.
  All flow through the existing `Validate.hs` diagnostic pipeline (EP-193 integration rule: no
  parallel rendering).
  Date: 2026-08-04

- Decision: Fix the doubled Mori diagnostic by giving `ContractField` its own `cfLoc` and
  anchoring every contract-field diagnostic there. Two occurrences of `family` in two events
  then produce two distinct, correctly located diagnostics — which is the truthful output — and
  the same field can no longer produce two identical lines.
  Date: 2026-08-04


## Outcomes & Retrospective

EP-192 shipped the planned three-part field identity without syntax deviation: direct aggregate
and contract fields accept `<name> [haskell <selector>] [as "<wireKey>"] : <type>` under language
4, defaulting both aliases to the DSL name. The Haskell refusal set is now the exact 23-word
generated-language set; the committed aggregate scalar conformance component compile-proves all
eleven removed contextual words (`as`, `family`, `mdo`, `proc`, `qualified`, `rec`, `safe`,
`signature`, `stock`, `unsafe`, and `via`) as selectors.

Validation adds append-only `FieldWireKeyCollision` and `FieldWireKeyInvalid` diagnostics with
field-local evidence. Evolution adds append-only `EvtFieldWireKeyChanged`; selector changes remain
`GeneratedHaskellNameChanged`, contract wire changes remain `ContractFieldChanged`, and
alias-free renames retain the old add/remove classification. The full DSL run finished with 560
examples and zero failures, including selector/wire diff, replay-impact, workspace, generated
codec, and copied `fields(Command)` coverage. Both compiled alias-bearing conformance components,
all contextual-selector probes, and the Mori-shaped `family` regression pass.

The frozen fold-identity baseline is bit-identical, alias edits are fingerprint-neutral, ordinary
single-file and workspace scaffolds are deterministic, and no generated file outside the
deliberately refreshed contract and aggregate-scalar fixtures changed. No external Mori source or
workspace required a compatibility edit: its reproduced contract shape now checks successfully.
ADR 0021 captures the durable identity contract, ADRs 0019 and 0004 carry the reserved-set and
inventory consequences, and IR-6 is implemented with the widened contract-field scope. The sole
closure exception is the inherited IR-19 metadata failure described above; all code, build,
policy, ADR, and whitespace gates pass.


## Context and Orientation

Read this section as if you know nothing about the repository. All paths are relative to the
repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless absolute.

keiro-dsl is a typed specification language for event-sourced services. An author writes a
`.keiro` file (or a `.keiro-workspace` composing several member files), runs `keiro-dsl check`
to validate it, `keiro-dsl scaffold` to generate deterministic Haskell plus explicit typed
holes, and `keiro-dsl diff` to classify evolution hazards between two spec revisions. The CLI
lives in `keiro-dsl/app/Main.hs`; the library modules under `keiro-dsl/src/Keiro/Dsl/` do the
work.

Three name domains meet at every field, and today they are one string:

- The _DSL identity_ is the field's name in the spec. Guard expressions (`cmd.family`),
  `fields(Command)` event bodies, intake `bind` rows, publisher stream-field references, and
  diff pairing all use it.
- The _generated Haskell selector_ is the record-field name in generated code
  (`family :: !Text` inside `ProjectChangedData`, read as `payload.family`).
- The _wire key_ is the JSON object key the generated codec writes and reads
  (`"family" .= payload.family`, `o .: "family"`). For aggregate events this is the private
  event-log encoding; for contracts it is a public cross-service Kafka schema.

The regression. ExecPlan 190 (unreleased, in `keiro-dsl/CHANGELOG.md` under Unreleased)
introduced checked generated-Haskell occurrence planning. `checkedLowerOccurrence` in
`keiro-dsl/src/Keiro/Dsl/HaskellName.hs` (line ~195) refuses any lower-case occurrence in
`haskellKeywords` (line ~323). That set contains 34 words: the Haskell 2010 reserved
identifiers plus contextual and extension-only words (`family`, `via`, `stock`, `rec`, `mdo`,
`proc`, `safe`, `unsafe`, `signature`, `as`, `qualified`). GHC treats most of these as ordinary
identifiers even with the relevant extension on — they are contextual keywords, special only in
positions such as `type family …` or `deriving … via …` — and the generated compilation
contract (ADR 0019:
`docs/adr/0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md`) is a
closed set that does not even enable `DerivingVia`, `RecursiveDo`, or `Arrows`. `validateNames`
in `keiro-dsl/src/Keiro/Dsl/Validate.hs` (the `GeneratedOccurrenceReserved` constructor near
line 178 is raised near line 1235) applies the set to every field, so Mori's `family: text`
fails `check`, and `scaffold` (which validates first through
`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`) exits 1 with zero files written. Because
`ContractField` in `keiro-dsl/src/Keiro/Dsl/Grammar.hs` (line ~814) has no `Loc`, both
occurrences of `family` anchor at the contract header line and render as an identical doubled
diagnostic.

Why renaming is not a remedy. The generated contract codec (`emitContractGen` in
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, roughly lines 2770–2960) emits the spec field name as
both the record selector (`dataRecord` builds `cfName f <> " :: !" <> …`) and the wire key
(`encodeField` builds `tshow (cfName field) <> " .= … payload." <> cfName field`; `decodeField`
builds `o .: <key>`). The aggregate domain/codec emitters do the same through `rcFields`
(`resolveAgg` in `Scaffold.hs` line ~521 pairs `aggregateFieldName` with the resolved type;
`emitRecord`, `emitEncode`, `emitDecode` consume it, and `emitEncode` additionally writes the
fixed envelope key `"kind"`). Structural mapped records already separate the two namespaces —
`pWireField` in `keiro-dsl/src/Keiro/Dsl/Parser/Mapped.hs` parses `<haskellField> as
"<wireKey>" : <type>` into `WireField {wfHaskell, wfKey, …}` per ADR 0012
(`docs/adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md`) —
but direct aggregate fields (`AggregateField` in `Grammar.hs` line ~464: name, optional
`TypeExpr`, `Loc`) and contract fields have no equivalent.

Grammar and parser surface. `pAggregateField` in `keiro-dsl/src/Keiro/Dsl/Parser/Aggregate.hs`
(line ~152) parses `name [":" typeExpr]` for commands and events. `pContractField` inside
`pContract` in `keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs` (line ~52) parses `name ":"
(typeid "p" | text | int)` with no location capture. Language gating: each released language
version selects an immutable `SyntaxProfile` in the append-only `languageRegistry`
(`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`); grammar features are `LanguageFeature`
constructors checked by `requireLanguageFeatureAt`/`optionalLanguageFeature` in
`keiro-dsl/src/Keiro/Dsl/Parser/Core.hs`, which refuse a disabled marker with the stable
`LanguageFeatureRequiresVersion` failure at the marker's span. Versions 2–4 currently share
`profileV2` (`keiro-dsl/syntax-profile/2`); version 4 is the sole `Stable` entry.
`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` renders fields at `docAggregateField` (line ~726) and
`docContractField` (line ~496); the canonical round trip (parse → pretty → parse) is a tested
invariant.

Naming machinery. `HaskellName.hs` provides `NameSite`, `PlannedOccurrence`,
`plannedOccurrence`, `detectNameCollisions`, and `checkedLowerOccurrence`. `validateNames` in
`Validate.hs` inventories node modules, shared types, and aggregate field occurrences
(`aggregateFieldOccurrences`, line ~1273: `FieldSpace`, scoped by owning record so
`DuplicateRecordFields` permits equal selectors on different records) — contract fields are
absent from the collision inventory today. Duplicate DSL field names within one command, event,
or contract event are already refused (lines ~1537 and ~2536), and a contract field equal to
the discriminator is refused (line ~1553). `auditGeneratedHaskell` in `ScaffoldRun.hs` is the
pre-write lexical fallback over emitted modules; it audits top-level declarations, not record
fields, and needs no change here. Two sibling keyword sets exist: a private 25-word list in
`keiro-dsl/src/Keiro/Dsl/NominalType.hs` (line ~425, used to validate consumer binding
symbols) and `HaskellImport.hs` (line ~203) reusing `HaskellName.haskellKeywords` for import
aliases.

Identity-sensitive consumers beyond the emitters. `EventOutput.hs` (`checkedCopy`, line ~111)
resolves `fields(Command)` copies into `CheckedFieldCopy {outputSelector, outputWireName,
outputFieldType}` — both name slots hold the DSL name — and `eventOutputCanonical` feeds the
frozen fold encoder. `FoldFingerprint.hs` composes state, register, transition, guard/write
(`canonicalExpr` over DSL names via `CanonicalEncoding.hs`), and output segments; payload
codecs are deliberately excluded, so wire keys never enter fold identity. `Goldens.hs` (line
~153) synthesizes old-payload JSON keyed by `rcFields` names — those must become wire keys.
`Harness.hs` builds sample payloads positionally from `rcFields` (selector text is not
emitted). `Diff.hs` pairs event fields by name (`eventFieldSigs`, line ~1233;
`sameVersionEventDiff` classifies added/removed/type changes as breaking `EvtField*` codes) and
contract fields by `cfName` (`contractEventDiff`, line ~1676, code `ContractFieldChanged`); the
`generatedNameChange` helper (line ~1825) already renders `GeneratedHaskellNameChanged`
consumer-build advisories. `ReplayImpact.hs` (line ~154) keys mapped/nominal event surfaces by
field name. Workspace composition (`composeWorkspace` in `Workspace.hs`) merges member nodes
whole, so alias data stored on `Grammar` values travels through workspaces automatically;
`checkWorkspace` maps diagnostic lines back to member files.

Fixtures and proofs. Ordinary generator, parser, naming, and diff tests live in
`keiro-dsl/test/Main.hs` (Hspec, run as `keiro-dsl-test`); the private naming component is
`keiro-dsl-haskell-name-test`. The compiled language-4 contract proof is
`keiro-dsl-conformance-contract` (`keiro-dsl/test/conformance-contract/` compiling
`keiro-dsl/test/fixtures/contract.keiro`, which already exercises typed `typeid` fields).
`keiro-dsl/test/conformance-baseline.json` (ExecPlan 183) inventories every fixture and
compiled component; new or changed fixtures must be reflected there. The frozen fold baseline
is `keiro-dsl/test/fixtures/fold-identity-baseline.golden`. Generated-source policies are
`scripts/check-extension-policy.sh` and `scripts/check-generated-name-policy.sh`.

Relevant ADRs, read for this plan: ADR 0019 (above — owns the compilation contract and naming
edition; its reserved-word policy is what Milestone 1 corrects; its "generated-name-only diff
is advisory and replay-neutral" rule is the selector-change precedent), ADR 0012 (above — the
`as "wire_key"` precedent and the rule that wire fingerprints ignore consumer-side naming),
ADR 0004 (`docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md` —
naming refusals stay at `check`, `DiagnosticCode` values are append-only, and its landed
inventory table must gain a row for field-identity changes), ADR 0018
(`docs/adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md` — the
frozen fold encoder this plan must not disturb), and ADR 0016
(`docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md` — language
provenance wrapping, relevant to the feature gate). No cross-repository ADR is required; the
Mori evidence is the workspace at `mori://shinzui/mori` (project-relative path
`domain/project-signals.keiro`, whose artifact-level source URI is pending; contract
`projectSignals`; topic `mori.project.v1`). The sibling highlighting repository
`mori://shinzui/keiro-syntax` follows grammar changes through existing cross-repository automation
and is out of scope here.


## Plan of Work

### Milestone 1: One field identity, a truthful reserved set, and alias syntax that round-trips

Scope: after this milestone the parser accepts alias syntax under language 4 and refuses it
below, the reserved set matches the compilation contract, the resolved field identity exists as
one shared value, and pretty-printing round-trips — with no generation change yet.

Trim `haskellKeywords` in `keiro-dsl/src/Keiro/Dsl/HaskellName.hs` to exactly the 23 words in
the Decision Log (22 Haskell 2010 reserved identifiers plus `forall`) and rewrite its comment to
state the policy: the set contains precisely the words GHC rejects as term-level identifiers
under the manifest contract of ADR 0019, and widening it requires new GHC evidence. Replace the
private list in `keiro-dsl/src/Keiro/Dsl/NominalType.hs` with an import of the authoritative
set (consumer modules with exotic extensions are defended by their own GHC compile, not by this
set), and leave `HaskellImport.hs` consuming the shared set unchanged.

Extend `keiro-dsl/src/Keiro/Dsl/Grammar.hs`: `AggregateField` gains
`aggregateFieldSelector :: !(Maybe Name)` and `aggregateFieldWireKey :: !(Maybe Text)`;
`ContractField` gains `cfSelector :: !(Maybe Name)`, `cfWireKey :: !(Maybe Text)`, and
`cfLoc :: !Loc`. Add the private module `keiro-dsl/src/Keiro/Dsl/FieldIdentity.hs` (listed in
the library `other-modules` of `keiro-dsl/keiro-dsl.cabal` beside `Keiro.Dsl.HaskellName`, and
re-listed in the test components that import it) owning the resolved identity described under
Interfaces and Dependencies: DSL name, selector (explicit alias verbatim, else the raw DSL name
bytes), wire key (explicit alias bytes, else the DSL name bytes), and the field's `Loc`. This
module is pure and total over parsed fields; refusals belong to Milestone 2.

Register the syntax gate in `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`: append
`FieldAliasSyntax` to `LanguageFeature`, add `profileV3` with identifier
`keiro-dsl/syntax-profile/3` containing profile 2's features plus `FieldAliasSyntax`, and point
the version-4 `languageRegistry` row at `profileV3`. Do not touch profiles 1 and 2 or any other
row. Extend `pAggregateField` in `keiro-dsl/src/Keiro/Dsl/Parser/Aggregate.hs` and
`pContractField` in `keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs` to parse, between the name
and the optional/mandatory colon, an optional `haskell <ident>` clause then an optional
`as <stringLit>` clause, each behind the feature via the `optionalLanguageFeature` helper
(`keiro-dsl/src/Keiro/Dsl/Parser/Core.hs`) so a marker under languages 1–3 fails with
`LanguageFeatureRequiresVersion` at the marker span. Wrap marker consumption in `try` so a field
literally named `haskell` or `as` (legal DSL identifiers) followed by another field or `}` still
parses; capture `cfLoc` with `getLoc` at the field start. Update `docAggregateField` and
`docContractField` in `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` to render `name haskell sel as
"key": type` in canonical order and spacing.

Add focused tests in `keiro-dsl/test/Main.hs` and the naming component: `family` (and each of
the eleven removed words) derives a valid occurrence while each of the 23 kept words is still
`ReservedGeneratedOccurrence`; a language-4 inline spec with aliased aggregate and contract
fields parses to the expected `Grammar` values and round-trips through the pretty printer
byte-stably; the same source under `language keiro-dsl 3` fails with
`LanguageFeatureRequiresVersion` at the `haskell` marker; fields named `haskell` and `as`
without clauses still parse. Run the frontend compatibility spec to prove the 0.7 corpus is
untouched. Acceptance: those suites pass and `cabal build keiro-dsl` compiles.

### Milestone 2: Checked resolution refuses bad identities at the field, before any write

Scope: every invalid or colliding identity fails `keiro-dsl check` with a useful location; the
Mori doubled diagnostic is gone; nothing reaches the emitters unvalidated.

In `validateNames` (`keiro-dsl/src/Keiro/Dsl/Validate.hs`), rework field handling to consume the
Milestone 1 resolver:

- Anchor contract-field diagnostics at the new `cfLoc` (replace the `ctrLoc contract` anchor at
  line ~1203). Mori's two `family` fields now produce, pre-trim, two distinct diagnostics at
  their own lines — and post-trim, none.
- Validate explicit selectors with `HaskellName.checkedLowerOccurrence` through the
  `ExplicitHaskellName` source kind (verbatim, never re-cased): a reserved selector is
  `GeneratedOccurrenceReserved`, an invalid identifier is `IdentUnsafeNormalization`, both at
  the field line. The DSL name itself is still checked as today, so a residual reserved DSL
  name without a selector alias remains a located, and now actionable, refusal.
- Extend the collision inventory: `aggregateFieldOccurrences` plans the resolved selector
  (falling back to today's derived rendering only where it already does), and a new
  `contractFieldOccurrences` plans every contract field selector in `FieldSpace` with target
  module `Generated.<Context>.<Contract>.Contract` and scope `<Event>Data`, flowing through the
  existing `detectNameCollisions`/`GeneratedOccurrenceCollision` path with primary and related
  lines.
- Add wire-key rules over resolved identities: within one command, event, or contract event,
  duplicate wire keys are `FieldWireKeyCollision` at the later field with the earlier field as
  a related location; an aggregate event field whose wire key equals the codec envelope key
  `"kind"` and a contract field whose wire key equals the declared discriminator are also
  `FieldWireKeyCollision`; an empty wire key is `FieldWireKeyInvalid`. Append both codes to
  `DiagnosticCode` (append-only per ADR 0004) and extend the existing duplicate-field and
  discriminator checks (lines ~1537, ~1553, ~2536) to compare resolved wire keys rather than
  raw names.

`fields(Command)` events copy the command's resolved identities, so the event-side inventory
uses the copied selectors; verify a command alias cannot collide undetected inside the copying
event's record. Keep `checkWorkspace` mapping primary and related lines to member files.

Add regressions: selector collision (two fields in one record resolving to one selector, with
both lines), wire-key collision, `"kind"`/discriminator collisions, empty wire key, reserved
explicit selector, invalid explicit selector, a `fields(Command)` copy inheriting a collision,
and a workspace member reporting the correct member path. Add the Mori-shape check fixture
`keiro-dsl/test/fixtures/contract-reserved-family.keiro`: a `language keiro-dsl 4` contract with
two events that both declare `family: text` (shape below, under Concrete Steps). Write its test
first — asserting `check` yields zero diagnostics — observe it fail red on the pre-trim tree if
Milestone 1 landed separately (or document the red run from HEAD before Milestone 1), then
green. Acceptance: the focused naming/preflight suites and `keiro-dsl-haskell-name-test` pass.

### Milestone 3: Alias-aware generation with committed compiled evidence and byte neutrality

Scope: generated records use selectors, codecs use wire keys, goldens and samples follow, the
committed corpus proves an alias-free spec is byte-identical, and the Mori shape plus a
selector-independence alias compile in a committed conformance component.

Widen `rcFields` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (`resolveAgg`, line ~521) from
`(Text, ResolvedAggregateType)` to carry the full resolved field identity, and let the compiler
drive every consumer to an explicit choice: `emitRecord`/`recordFields` render the selector;
`emitEncode`/`emitDecode` render the wire key on the JSON side and the selector on the
`payload.<selector>` side; `domainNeedsDuplicateRecordFields` compares selectors;
`Harness.hs` sample builders stay positional (types only); `Goldens.hs` synthesized payload
keys become wire keys; read-model, publisher, and expression consumers keep the DSL identity.
Apply the same split in the contract emitter (`emitContractGen`: `dataRecord` and the module
export list use `cfSelector`-resolved names, `encodeField`/`decodeField` use the resolved wire
key, `contractNeedsDuplicateRecordFields` compares selectors). In `EventOutput.hs`, keep
`outputSelector` and `outputWireName` populated with the DSL identity so `eventOutputCanonical`
— and therefore the fold fingerprint — is untouched; the renderer obtains resolved identities
from the command's fields at emission time. Confirm by inspection that no `FoldFingerprint.hs`
or `CanonicalEncoding.hs` input changes.

Fixtures. Extend `keiro-dsl/test/fixtures/contract.keiro` (compiled by
`keiro-dsl-conformance-contract`) with, on one existing event or a new event: `family: text`
(trim proof on the public contract surface), `type haskell payloadType: text` (hard keyword
made actionable; wire key stays `"type"`), and `region haskell serviceRegion as
"region_code": text` (brownfield wire key). Regenerate the committed
`keiro-dsl/test/conformance-contract/Generated/…/Contract.hs` through the public scaffolder and
extend `Main.hs` there to assert: encoding writes `"family"`, `"type"`, and `"region_code"`;
decoding round-trips them; and the record exposes `payloadType` and `serviceRegion`. Extend one
aggregate compiled component that ExecPlan 191 does not touch — `keiro-dsl-conformance-aggregate-scalars`
(locate its fixture via `hs-source-dirs` in `keiro-dsl/keiro-dsl.cabal`) — with an event field
named `family` and one selector-aliased, wire-key-aliased field, regenerating its committed
Generated tree and updating its assertions, so the aggregate Domain/Codec split is also
compile-proven. Add an ordinary (non-compiled) generation test over a new fixture
`keiro-dsl/test/fixtures/aggregate-field-alias.keiro` asserting the emitted Domain/Codec/Golden
texts place each name on the correct side, `fields(Command)` events inherit the command's
aliases, a second scaffold is byte-stable, and single-file versus one-member-workspace planning
agree. Update `keiro-dsl/test/conformance-baseline.json` rows for every touched fixture and
component.

Neutrality proof. Run the complete `cabal test keiro-dsl` and `git status`: no committed
generated file outside the deliberately extended fixtures may change, and
`keiro-dsl/test/fixtures/fold-identity-baseline.golden` must be bit-identical. Additionally
assert in a unit test that the fold fingerprint of an aggregate is unchanged when a selector
alias is added and when a wire-key alias is added (fingerprint neutrality is exact), while the
generated codec text changes only for the wire-key alias.

### Milestone 4: Classify evolution, publish the contract, and close

Scope: diff and replay classification, ADR/IR/docs closure, and repository-wide green.

In `keiro-dsl/src/Keiro/Dsl/Diff.hs`, extend `eventFieldSigs` and the contract pairing to carry
resolved identities while pairing stays by DSL name. Over paired fields: a selector-only change
emits the existing `GeneratedHaskellNameChanged` advisory via `generatedNameChange` (line
~1825) with occurrence kinds naming the field ("command field selector", "event field
selector", "contract field selector"); an aggregate event wire-key change emits the new
append-only `EvtFieldWireKeyChanged` breaking finding whose compatibility vector matches a
same-version field removal (private-history-read and old-binary-read-new-events breaking) and
whose message names old and new keys plus the remedy (restore the key, or version the event
with an upcaster); a contract wire-key change emits `ContractFieldChanged` breaking with a
wire-key message (public-consumer surface, consumer-first rollout). Wire-key changes on command
fields are reported at each event copying them through `fields(Command)`. Wire the new code
into the compatibility-vector function (line ~273 region), `DiffReport.hs` remedies, and the
replay-impact classification with the same treatment as `EvtFieldRemovedSameVersion`. Add diff
regressions: selector-only change (advisory only, replay-neutral verdict), event wire-key
change (breaking plus affected replay impact), contract wire-key change, and an alias-free
rename still classifying exactly as today.

ADR work, per `agents/skills/exec-plan/ADR.md`. Amend
`docs/adr/0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md`: the
naming edition's reserved-word policy is exactly the GHC-rejection set of the manifest
contract, listing the 23 words and the compile-probe evidence. Amend
`docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md`: add an inventory
row for field-identity changes (selector-only = consumer-build advisory; wire-key = codec-side
breaking with the vectors above; alias validity and collisions = single-spec `check` errors).
Create a new ADR for the three-namespace field identity (DSL name / generated selector / wire
key; default rules; which surfaces consume which namespace; why fold identity sees only DSL
names): allocate its handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`
(never by counting files), keep one decision per file, maintain `docs/adr/log.md` with `okf log
add`, and run the strict validation shown under Concrete Steps.

Documentation and closure. Update `docs/user/typed-spec-toolchain.md`: the "Commands and
events" and "Integration contracts" authoring sections gain the alias syntax with the
`type haskell payloadType` and `as "region_code"` examples, and the lexical/naming discussion
states the trimmed reserved policy and the alias remedy. Update IR-6
(`docs/improvement-requests/allow-independent-haskell-selector-and-wire-key-aliases-on-direct-aggregate-fields.md`):
frontmatter `status: implemented`, a Status section noting the widened contract-field scope and
linking this plan by repository-relative path, and a matching dated `Implemented` entry in
`docs/improvement-requests/log.md` (match the existing entry style). Add release notes to
`CHANGELOG.md` and `keiro-dsl/CHANGELOG.md` (Unreleased): breaking `DiagnosticCode` additions
(`FieldWireKeyCollision`, `FieldWireKeyInvalid`, `EvtFieldWireKeyChanged` — exhaustive matches
must extend), the reserved-set narrowing (specs previously refused now check), the language-4
alias syntax, and the syntax-profile-3 registry change. Finish with the full closure command
block below.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/keiro`. Capture the pre-change failure as
evidence before Milestone 1 lands, using an inline copy of the Mori shape (this exact content
becomes `keiro-dsl/test/fixtures/contract-reserved-family.keiro`):

```text
language keiro-dsl 4
context signals

contract projectSignals {
  schemaVersion 1
  discriminator messageType

  topic projectEvents "signals.project.v1"

  event ProjectChanged on projectEvents {
    projectId: typeid "proj"
    family: text
    action: text
  }

  event ProjectArtifactChanged on projectEvents {
    projectId: typeid "proj"
    family: text
    artifact: text
  }
}
```

```console
$ nix develop -c cabal run keiro-dsl -- check keiro-dsl/test/fixtures/contract-reserved-family.keiro
...
error[GeneratedOccurrenceReserved]: contract field 'family' normalizes to reserved Haskell occurrence 'family'
error[GeneratedOccurrenceReserved]: contract field 'family' normalizes to reserved Haskell occurrence 'family'
$ echo $?
1
```

The doubled, contract-line-anchored output is the recorded defect. After Milestones 1–2 the
same command exits 0 with no output, and a temporary mutation renaming one `family` to `where`
must produce exactly one error at that field's own line.

During Milestones 1 and 2, run the narrow suites after each change. Substitute the final Hspec
descriptions chosen by the implementation for the indicative match strings and record them in
Progress:

```console
$ nix develop -c cabal test keiro-dsl-haskell-name-test
...
Test suite keiro-dsl-haskell-name-test: PASS

$ nix develop -c cabal test keiro-dsl-test --test-options='--match "field alias"'
...
0 failures

$ nix develop -c cabal test keiro-dsl-test --test-options='--match "identifier hygiene"'
...
0 failures

$ nix develop -c cabal test keiro-dsl-test --test-options='--match "compatibility"'
...
0 failures
```

For Milestone 3, inspect fresh output with the public scaffolder in a disposable directory
before regenerating committed trees, then regenerate through the same public commands and
review every diff. Never hand-edit generated files:

```console
$ proof_dir=$(mktemp -d)
$ nix develop -c cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/contract.keiro --out "$proof_dir"
...
$ rg -n '"family"|"type"|"region_code"|payloadType|serviceRegion' "$proof_dir" -g '*Contract.hs'
...
```

The inspection must show `"type" .=`-style encoding beside a `payloadType` selector and
`"region_code"` beside `serviceRegion`. Remove only this explicitly created disposable
directory afterwards. Then run the compiled proofs and the neutrality check:

```console
$ nix develop -c cabal test keiro-dsl-conformance-contract
...
Test suite keiro-dsl-conformance-contract: PASS

$ nix develop -c cabal test keiro-dsl-conformance-aggregate-scalars
...
Test suite keiro-dsl-conformance-aggregate-scalars: PASS

$ git status --short keiro-dsl/test
```

`git status` may list only the files this plan deliberately changed; any other modified
committed generated file is a neutrality failure. For the new ADR handle:

```console
$ okf id list docs/adr --profile docs/adr/profile.dhall
$ okf id next docs/adr --profile docs/adr/profile.dhall ADR
ADR-21
```

Use whatever handle `okf id next` actually returns. Full closure after Milestone 4:

```console
$ nix develop -c cabal test keiro-dsl
...
All ... test suites passed

$ nix develop -c cabal build all
...

$ scripts/check-extension-policy.sh
extension policy: ok

$ scripts/check-generated-name-policy.sh
generated Haskell naming policy: ok

$ okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
OK: 21 concepts

$ okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
profile: give-keiro-dsl-generated-sidecars-honest-names-and-one-durability-contract: missing profile-recommended field: reviews

$ git diff --check
```

A blank `git diff --check` is success. The improvement-request command's sole failure is the
pre-existing IR-19 metadata omission recorded in Surprises & Discoveries; IR-6 itself is
implemented and logged. Update the transcripts and exact counts in this plan as implementation
proceeds.


## Validation and Acceptance

Acceptance is behavioral, not merely a successful build:

1. `keiro-dsl check keiro-dsl/test/fixtures/contract-reserved-family.keiro` — the exact Mori
   shape, a language-4 contract with `family: text` in two events — exits 0 with no
   diagnostics, where HEAD today prints the doubled `GeneratedOccurrenceReserved` error and
   scaffolding exits 1 with zero files written. Scaffolding the fixture writes a Contract module
   whose record carries a `family` selector and whose codec writes the `"family"` wire key.
2. Every kept reserved word (`case`, `type`, `default`, `where`, `forall`, …) is still refused
   as a bare field name — but at the field's own line, once per field occurrence — and adding
   `haskell <alias>` to that field makes the same spec check and scaffold with the original
   wire key. The eleven removed words (`family`, `via`, `stock`, `rec`, `mdo`, `proc`, `safe`,
   `unsafe`, `signature`, `as`, `qualified`) all compile as selectors in committed conformance
   components.
3. A field with DSL identity `type`, selector alias `payloadType`, and no `as` clause encodes
   and decodes under the wire key `"type"`; a field with `as "region_code"` encodes and decodes
   under `"region_code"` while guards and `fields(Command)` still reference the DSL name.
   `fields(Command)` events inherit the command's resolved selectors and wire keys without
   recomputation, proven by generated-text assertions.
4. Selector collisions, wire-key collisions (including a wire key equal to `"kind"` on an
   aggregate event or to the discriminator on a contract event), invalid or reserved explicit
   selectors, and empty wire keys all fail `keiro-dsl check` at the owning field with related
   locations where a second declaration is involved, and the same refusals hold through the
   workspace path with member-mapped lines. No such spec reaches a write.
5. Alias syntax parses only under language 4: the same source with `language keiro-dsl 3` fails
   with `LanguageFeatureRequiresVersion` at the `haskell` or `as` marker span. The frontend-0.7
   compatibility suite and the conformance-baseline check pass unchanged.
6. Pretty-printing an aliased spec and re-parsing it yields the identical `Grammar` value, and
   the printed form is byte-stable across a second round trip.
7. Fingerprint and byte neutrality: `keiro-dsl/test/fixtures/fold-identity-baseline.golden` is
   bit-identical; adding a selector alias or a wire-key alias to a test aggregate leaves its
   fold fingerprint unchanged; and after the full test suite, `git status` shows no modified
   committed generated file outside the fixtures this plan deliberately extended.
8. `keiro-dsl diff` classifies: a selector-only change as `GeneratedHaskellNameChanged`
   (consumer-build advisory, replay verdict `replay-neutral`); an aggregate event wire-key
   change as breaking `EvtFieldWireKeyChanged` with private-history-read and
   old-binary-read-new-events breaking verdicts and an affected replay-impact target; a
   contract wire-key change as breaking `ContractFieldChanged` naming both keys. An alias-free
   field rename classifies exactly as on HEAD today.
9. ADR 0019 states the corrected reserved policy, ADR 0004's inventory has the field-identity
   row, the new field-identity ADR exists under its `okf id next` handle, and IR-6 is
   `implemented` with the widened-scope note and both logs updated. Strict ADR validation passes;
   repository-wide strict improvement-request validation reports only the inherited IR-19
   `reviews` omission documented above.
10. `cabal test keiro-dsl`, `cabal build all`, both policy scripts, and `git diff --check`
    pass.


## Idempotence and Recovery

Parsing, identity resolution, validation, and generation are pure functions of the source, so
every test and scaffold command here is safely repeatable. Scaffold new fixture output into a
disposable `mktemp -d` directory first; when refreshing committed conformance trees, let the
public scaffold command overwrite only files with generated provenance and never replace
create-once hole modules — update those deliberately with explicit edits. A second scaffold of
any fixture must report no byte changes; that is itself an acceptance check.

The grammar change is additive and the trimmed keyword set only widens acceptance, so no
existing checked spec, persisted scaffold record, workspace record, fold fingerprint, or wire
byte changes for alias-free sources; there is no migration and no destructive step. If a
milestone fails midway, the committed corpus plus `conformance-baseline.json` are the recovery
oracle: revert only the files this plan touched with an explicit patch (never a worktree
reset), re-run `cabal test keiro-dsl`, and resume from the last green milestone. Land the
Milestone 1 registry change (`profileV3`) and the parser change in the same commit so no
intermediate state advertises a feature the grammar cannot parse. The new diagnostic and diff
codes are append-only; if a code must be withdrawn before release, remove it in the same
unreleased line rather than renumbering anything.

Mori adoption is external to this plan: Mori needs no source change at all for `family` (the
trim alone repairs it), and should adopt aliases only where it wants selector ergonomics, after
a released keiro-dsl containing this plan.


## Interfaces and Dependencies

No new package dependency is added; the work uses the existing `megaparsec`, `aeson`,
`containers`, and `text` surfaces already in `keiro-dsl/keiro-dsl.cabal`.

`keiro-dsl/src/Keiro/Dsl/FieldIdentity.hs` (library `other-modules`; exact record-field
prefixes may follow local style, but the information and defaulting rules are fixed):

```haskell
-- | One resolved field identity: the three namespaces of a direct aggregate
-- or contract event field. Selector defaults to the raw DSL name bytes;
-- wire key defaults to the DSL name bytes. Resolution is total over parsed
-- fields; validity and collisions are refused by Keiro.Dsl.Validate.
data ResolvedFieldIdentity = ResolvedFieldIdentity
  { fieldDslName :: !Name,
    fieldSelector :: !Text,
    fieldWireKey :: !Text,
    fieldLoc :: !Loc
  }

resolveAggregateFieldIdentity :: AggregateField -> ResolvedFieldIdentity

resolveContractFieldIdentity :: ContractField -> ResolvedFieldIdentity
```

`keiro-dsl/src/Keiro/Dsl/Grammar.hs` additions (all other constructors and fields unchanged):

```haskell
data AggregateField = AggregateField
  { aggregateFieldName :: !Name,
    aggregateFieldSelector :: !(Maybe Name),
    aggregateFieldWireKey :: !(Maybe Text),
    aggregateFieldType :: !(Maybe TypeExpr),
    aggregateFieldLoc :: !Loc
  }

data ContractField = ContractField
  { cfName :: !Name,
    cfSelector :: !(Maybe Name),
    cfWireKey :: !(Maybe Text),
    cfType :: !ContractType,
    cfLoc :: !Loc
  }
```

`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`: `LanguageFeature` gains `FieldAliasSyntax`;
`profileV3 :: SyntaxProfile` with identifier `keiro-dsl/syntax-profile/3` = profile 2's feature
set plus `FieldAliasSyntax`; the version-4 registry row selects `profileV3`. Parsers gate with
the existing helpers:

```haskell
requireLanguageFeatureAt :: FrontendContext -> LanguageFeature -> SourceSpan -> P ()
optionalLanguageFeature :: FrontendContext -> LanguageFeature -> Text -> P a -> P (Maybe a)
```

`keiro-dsl/src/Keiro/Dsl/HaskellName.hs`: `haskellKeywords :: Set Text` becomes the 23-word
set; its consumers (`checkedLowerOccurrence`, `HaskellImport.validOccurrence`, and the
consolidated `NominalType` validator) are otherwise unchanged. Explicit selectors are validated
with the existing:

```haskell
checkedLowerOccurrence :: NameSite -> Text -> Either HaskellNameError LowerCamelName
plannedOccurrence :: Text -> HaskellOccurrenceSpace -> Text -> Text -> NameSite -> PlannedOccurrence
detectNameCollisions :: [PlannedOccurrence] -> [HaskellNameError]
```

`keiro-dsl/src/Keiro/Dsl/Validate.hs`: `DiagnosticCode` appends `FieldWireKeyCollision` and
`FieldWireKeyInvalid`. `keiro-dsl/src/Keiro/Dsl/Diff.hs`: `DiagnosticCode` consumers append
`EvtFieldWireKeyChanged`; selector-only findings reuse `GeneratedHaskellNameChanged` through
the existing `generatedNameChange` helper; `DiffReport.hs` gains the new code's remedies, and
the replay-impact classification treats `EvtFieldWireKeyChanged` like
`EvtFieldRemovedSameVersion`. `keiro-dsl/src/Keiro/Dsl/EventOutput.hs` keeps
`CheckedFieldCopy.outputSelector` and `outputWireName` bound to the DSL identity —
`eventOutputCanonical` and everything in `keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs` and
`keiro-dsl/src/Keiro/Dsl/CanonicalEncoding.hs` are frozen and must not change.

At the end of Milestone 3, `rcFields` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` carries
`ResolvedFieldIdentity` alongside the resolved type, and every emitter names its namespace
explicitly: selectors in `emitRecord`, `emitPayloadAdt`, and `payload.<selector>` accessors;
wire keys in `emitEncode`, `emitDecode`, `emitContractGen`'s `encodeField`/`decodeField`, and
`Goldens.hs`; DSL identities everywhere else.
