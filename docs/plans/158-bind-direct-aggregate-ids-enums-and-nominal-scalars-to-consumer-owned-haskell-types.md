---
id: 158
slug: bind-direct-aggregate-ids-enums-and-nominal-scalars-to-consumer-owned-haskell-types
title: "Bind direct aggregate IDs enums and nominal scalars to consumer-owned Haskell types"
kind: exec-plan
created_at: 2026-07-31T14:46:35Z
intention: intention_01kywm9cd8ey1t3rg8ngsa9fxr
---

# Bind direct aggregate IDs enums and nominal scalars to consumer-owned Haskell types

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, an aggregate author can use an existing domain type for a direct aggregate
identifier, enum, or scalar instead of accepting a second generated wrapper. For example, an
`OrderId` declared by an application as a type synonym or wrapper around `KindID "ord"` remains
the type used by generated commands, events, registers, snapshot caches, and harness fixtures. A
nominal `AccountNumber` over `Text` likewise remains distinct from every other text-valued field
without being flattened to `Text` in generated domain code.

Keiro still owns the private-event wire representation. A bound ID crosses a typed
`KindID "ord"` representation, a bound enum crosses a generated closed representation, and a
bound scalar crosses exactly one built-in representation. These conversions are total in both
directions. Consequently the existing pure event encoder cannot emit an invalid ID prefix or an
unknown enum spelling, while the decoder rejects malformed or wrong-prefix ID text before it can
construct the consumer type. A scalar whose constructor can reject a built-in value is refined,
not merely nominal, and remains outside this feature; it must use `mapped opaque` until Keiro has
an explicit refined-mapping contract.

The behavior is visible by scaffolding and compiling a fixture whose ID, enum, and nominal scalar
all point at consumer-owned types. The generated domain module contains no duplicate public type,
the generated event codec round-trips the declared wire values, a wrong TypeID prefix fails at
decode, snapshots round-trip through the existing consumer-owned cache instances, and forward
execution reaches the same registers as replay.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-07-31: Validated this plan against the current parser, resolver, generator, codec,
  snapshot, record, workspace, and Keiki symbolic APIs; ADRs 3, 4, 12, and 15; and the released
  `mmzk-typeid` 0.7.1.1 source and upstream tag.
- [x] 2026-07-31: Confirmed plan 160 is complete: its Progress section has no unchecked rows,
  version 1 is the released parser contract, and the successor syntax can be allocated without
  widening version 1 or legacy-unversioned sources.
- [x] 2026-07-31: Milestone 1 published the total `Keiro.Codec.Nominal` contract and registered
  the canonical direct-ID, direct-enum, and nominal-scalar forms exclusively in language version
  2. Focused runtime tests report 2 examples and the nominal parser/checker slice reports 5
  examples, both with zero failures.
- [x] 2026-07-31: Milestone 2 added the checked `NominalTypeRegistry`, integrated it with aggregate
  type resolution, initials and capabilities, and allocated located diagnostics for incomplete
  provenance, invalid Haskell or qualified names, invalid identity and TypeID prefix, unsupported
  or empty representations, missing register initials, and cross-category name collisions.
- [x] 2026-07-31: Milestone 3 drove domain, codec, projection, fixture, manifest, record,
  fingerprint, diff, replay-impact, scaffold, and workspace output from the checked model while
  preserving unbound ID/enum generation. Two clean scaffolds produced identical trees, the
  firewall scanned 8 generated modules with zero forbidden operators, and both record formats
  round-trip 7 additive `nominal-mapping` rows without changing ordinary `mapping` rows.
- [x] 2026-07-31: Milestone 4 added the compiled conformance ring, negative and mutation tests,
  authoring/toolchain documentation, changelog, and ADR 4/12 amendments. Focused tests report 2
  runtime, 8 DSL, and 28 conformance checks with zero failures; the full DSL suite reports 402
  examples with zero failures; `cabal build all`, strict validation of all 17 ADR concepts, and
  the native `nix flake check` treefmt/pre-commit checks all pass.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-31: The current `idPrefix` is used by validation, pretty printing, golden samples, and
  diffing, but generated IDs are still `newtype X = X Text`; no generated decoder enforces the
  prefix. The nominal binding therefore has to carry executable conversion behavior, not just a
  Haskell type name.
- 2026-07-31: Adopting a bound ID tightens the decoder even when its declared prefix and valid
  wire bytes are unchanged: historical payloads that the old `Text` wrapper accepted may fail the
  new `KindID` parser. Diff and conformance must expose this brownfield read risk and require the
  targeted real-log audit before deployment.
- 2026-07-31: Existing plan 151's “nominal bindings” are exact bindings between consumer-owned
  structural records and generated wire shapes. They do not bind direct aggregate scalar, ID, or
  enum declarations, so this work is not covered by that completed plan.
- 2026-07-31: The proposed partial inverse was incompatible with both the current pure
  `Codec.encode :: event -> Value` contract and ADR 12. A total binding through a typed or closed
  intermediate representation keeps encoding total; `Either` belongs only to parsing wire bytes
  into that representation.
- 2026-07-31: Keiki discovers symbolic support by exact `Typeable` equality with its curated
  built-in types. Wrapping a consumer value with `TApp1 toRepresentation` would remain opaque and
  each occurrence would become an unrelated symbolic variable. The existing `FieldProjection`
  and `FieldWitness` API is the sound reusable boundary for a whole-value nominal projection.
- 2026-07-31: `defaultStateCodec` serializes registers through consumer `ToJSON` and `FromJSON`.
  Event-codec binding coverage must not be described as snapshot-codec authority; nominal
  provenance instead invalidates the rebuildable snapshot cache, as ADRs 3 and 12 require.
- 2026-07-31: ADR 15 explicitly keeps staged temporary-tree replacement out of scope for whole
  workspaces. Safety is complete-graph detection-before-write, byte comparison for generated
  modules, and recoverable deterministic reruns.
- 2026-07-31: Mori resolved `mori://MMZK1526/mmzk-typeid/packages/mmzk-typeid` to the source used
  for this audit. Hackage and upstream both identify 0.7.1.1 as the current release/tag;
  `Data.TypeID.checkPrefix`, `Data.KindID.parseText`, and `Data.KindID.toText` provide the required
  checked APIs.
- 2026-07-31: Plan 160 is still entirely unchecked. This plan may define the successor grammar,
  but implementation must not silently widen legacy or released version 1 syntax.
- 2026-07-31: The prerequisite changed after this plan's validation pass: plan 160 is now fully
  complete, with 15 focused source examples, 394 full DSL examples, a successful all-package
  build, native flake checks, and accepted ADR 16 recorded in its Outcomes section.
- 2026-07-31: The append-only validation codes allocated by the checked nominal registry are
  `NominalMissingIngredient`, `NominalInvalidHaskellSource`, `NominalInvalidQualifiedName`,
  `NominalInvalidIdentity`, `NominalInvalidIdPrefix`, `NominalUnsupportedRepresentation`,
  `NominalEmptyEnumRepresentation`, `NominalMissingInitialValue`, and `NominalNameCollision`.
  The version-1 boundary uses the source-language code `LanguageFeatureRequiresVersion`, so invalid
  successor syntax does not cascade into ordinary parser or nominal diagnostics.
- 2026-07-31: Provenance required six append-only diff/report codes:
  `NominalBindingChanged`, `NominalFixturesChanged`, `NominalCanonicalTypeChanged`,
  `NominalInitialChanged`, `NominalRepresentationChanged`, and
  `NominalIdDecoderTightened`. This keeps evidence/build, snapshot hydration, declared wire, and
  brownfield history risks distinct instead of overloading structural-mapping codes.
- 2026-07-31: Existing readers already ignore unknown record row kinds but reject an unknown mode
  inside a known `mapping` JSON row. Emitting `nominal-mapping` as its own row therefore preserved
  old readability and existing mapping bytes in both single-file and workspace records; new
  readers merge both kinds for duplicate detection and drift.
- 2026-07-31: The compiled conformance ring has 28 named passing checks. Each deliberate mutation
  failed its owning assertion: transposed enum representation, changed scalar expected wire, and
  a one-direction ID suffix. The partial `Either` inverse fixture failed to typecheck because its
  function cannot inhabit the total `representation -> domain` field.
- 2026-07-31: The first full DSL run exposed two compatibility seams hidden by the nominal slice.
  An unconditional `LambdaCase` pragma changed every legacy generated Domain/Codec golden, and a
  duplicate synthetic aggregate made the nominal registry discard otherwise valid ID/enum
  symbols before the path-collision gate ran. Nominal codecs now add the pragma only on the new
  path, and nominal collision validation rejects only cross-category collisions; the established
  duplicate-node/path gates retain ownership of same-category duplicates. The rerun passed all
  402 examples without changing legacy generated bytes.


## Decision Log

Record every decision made while working on the plan.

- Decision: Use `using { ... }` for the optional binding block on direct `id` and `enum`
  declarations, and retain `mapped nominal Name : Representation { ... }` for nominal scalars.
  Rationale: `using` makes the additive direct-declaration extension unambiguous and gives IDs and
  enums one canonical form. The scalar spelling stays adjacent to structural and opaque consumer
  mappings while the AST stores nominal scalars separately from the structural `TypeGraph`.
  Date: 2026-07-31

- Decision: A `NominalBinding domain representation` has two total functions and no semantic
  error channel. A bound ID's representation is `KindID prefix`; a bound enum's representation is
  a generated closed datatype; a scalar's representation is exactly one of `Text`, `Int`,
  `Natural`, `Bool`, or `UTCTime`.
  Rationale: Every representation value is valid, so `fromRepresentation` can be total and the
  pure event encoder cannot produce an invalid prefix or spelling. Wire parsing remains the only
  partial step. This extends rather than weakens ADR 12's total-binding rule.
  Date: 2026-07-31

- Decision: Exclude refined scalar types whose constructors reject, normalize, or quotient values
  of the declared built-in representation.
  Rationale: Such a consumer is not isomorphic to the built-in domain. Allowing a partial inverse
  would hide policy from `check` and `diff`; `mapped opaque` is the honest existing boundary until
  a separately designed refined mode exists.
  Date: 2026-07-31

- Decision: Every consumer binding requires `haskell`, `binding`, `binding-version`,
  `canonical-type`, and `fixtures`; `initial` is required only when the type is used by a
  register. Fixtures pair a consumer value with its expected JSON wire value.
  Rationale: Round-trip laws alone cannot detect a consistent but wrong permutation or
  normalization. Expected wire values check declared enum spellings, scalar representations, and
  ID text, while canonical identity and provenance keep snapshots, diffs, and scaffold drift
  attributable.
  Date: 2026-07-31

- Decision: Bound nominal scalars expose equality and the existing ordering subset through a
  generated whole-value `FieldProjection` facade; bound IDs and enums remain opaque to Keiki.
  Rationale: Keiki's `TApp1` is intentionally opaque. Its existing coherent witness API supplies
  shared solver variables for a direct register or matched input and needs no cross-repository API
  change. Current `.keiro` guards still scaffold as Hole comments, so the plan promises a typed
  helper and compiled conformance evidence, not automatic guard lowering. The DSL does not add
  arithmetic syntax or capability in this plan.
  Date: 2026-07-31

- Decision: Event codecs use the nominal binding, while snapshot caches continue to use consumer
  `ToJSON`, `FromJSON`, and `CanonicalTypeName` instances and are invalidated by nominal
  provenance changes.
  Rationale: This is the existing snapshot architecture recorded by ADRs 3 and 12. Replacing the
  register-file state codec is a materially larger feature and is unnecessary for safe consumer
  type reuse.
  Date: 2026-07-31

- Decision: Treat a binding source, symbol, or version change as wire-byte neutral but not as
  provably replay-neutral.
  Rationale: Keiro cannot inspect hand-written conversion behavior. Diff therefore reports the
  consumer rebuild everywhere, targets historical event types when the nominal appears in an old
  event, and includes snapshot-bearing streams when it appears in a register. A fixture-symbol-only
  change reruns conformance but does not by itself claim runtime behavior changed.
  Date: 2026-07-31

- Decision: Classify adoption of a bound ID at an existing event use as a decoder-tightening
  historical-read advisory even when the prefix fingerprint is unchanged.
  Rationale: The former generated `Text` wrapper accepted malformed and wrong-prefix historical
  values. Committed old-payload fixtures verify known history and the targeted real-log audit checks
  production streams; valid declared TypeID bytes need no upcast.
  Date: 2026-07-31

- Decision: Plan 160 is a hard prerequisite and this syntax is registered in the next unreleased
  language version, expected to be version 2 after plan 160 lands version 1.
  Rationale: Version 1 must not silently widen. Version 1 and legacy sources reject the new forms;
  an author opts in by changing the preamble and performing the documented source rewrite.
  Date: 2026-07-31

- Decision: Persist nominal mapping provenance in a new `nominal-mapping` record row while keeping
  existing `mapping` row JSON unchanged.
  Rationale: Current v1 record readers ignore unknown row kinds but fail an unknown mode inside a
  known `mapping` row. A new row kind preserves backward readability and lets new readers detect
  duplicates and drift across both row kinds.
  Date: 2026-07-31

- Decision: Preserve ADR 15's detection-before-write workspace contract; do not add a staging and
  rename protocol in this plan.
  Rationale: All spec, ownership, collision, golden-root, and obligation preflights run before the
  first write. A later GHC failure in hand-owned consumer code leaves deterministic generated
  output that can be corrected and regenerated, not a falsely claimed transaction.
  Date: 2026-07-31

- Decision: Generated types remain the default when a direct ID or enum has no consumer binding.
  Rationale: Existing specs retain their current behavior and can adopt consumer-owned domain types
  deliberately rather than through a repository-wide breaking change.
  Date: 2026-07-31

- Decision: Keep this audit follow-on as a standalone ExecPlan rather than reopening the completed
  structural-consumer-type MasterPlan.
  Rationale: The feature can be implemented and accepted independently; reviving a completed
  initiative would obscure both its shipped outcome and this plan's actual implementation state.
  Date: 2026-07-31


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

The 2026-07-31 plan-validation pass replaced a partial, potentially lossy codec boundary with a
total category-specific representation model and corrected the solver, snapshot, record, and
workspace claims to match released code. Milestones 1 and 2 now provide the public total binding
API, version-2 syntax and pretty printer, workspace relocation, one checked nominal registry,
aggregate lowering, exact text/JSON binding obligations, and stable earliest-boundary diagnostics.
Generation now imports consumer-owned types directly, lowers prefix-checked IDs, closed enums and
built-in nominal scalars through total bindings, emits whole-value nominal projections, and
preserves nominal provenance across manifests, records, fold fingerprints, replay impact, and
compatibility findings. A 28-check compiled conformance ring plus three mutation gates and one
compile-fail fixture cover the executable boundary. Authoring/toolchain documentation, the
changelog, and ADRs 4 and 12 record the landed contract. Version 1 and legacy syntax remain
isolated, existing unbound generated bytes remain pinned, and version 2 authors opt into the
consumer-owned boundary explicitly. Final validation passed 2 focused runtime examples, 8
focused DSL examples, 28 nominal conformance checks, all 402 DSL examples, all-package Cabal
build, strict validation of 17 ADR concepts, and the native Nix treefmt/pre-commit checks. The
purpose is met with no known implementation gap; refined/partial consumer values, nested or
computed projections, ID/enum symbolic visibility, nominal arithmetic, and automatic source
upgrade remain deliberately outside this plan.


## Context and Orientation

`keiro-dsl/src/Keiro/Dsl/Grammar.hs` represents `IdDecl` with only a name, prefix, and source
location, and `EnumDecl` with only a name, constructor/wire pairs, and location.
`keiro-dsl/src/Keiro/Dsl/Parser.hs` parses one-line direct declarations. Consumer-owned structural
and opaque declarations already use `HaskellSource`, a qualified binding or codec symbol, a
version, fixtures, and an initial value. `keiro-dsl/src/Keiro/Dsl/TypeGraph.hs` checks those facts,
and `Keiro.Dsl.ExplainBindings`, `MappedConsumer`, `ScaffoldRecord`, and `WorkspaceRecord` preserve
their obligations and provenance.

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` currently emits every direct ID as a newtype over `Text` and
every enum as a generated Haskell data type. It also owns most generated imports and direct-value
samples. `keiro-dsl/src/Keiro/Dsl/AggregateType.hs` is the emerging single resolver for aggregate
type identities and capabilities; this plan must extend that resolver instead of creating another
allowlist. Its current `ResolvedAggregateType` treats direct IDs and enums as opaque and discovers
mapped types through `TypeGraph`. `Goldens.hs`, `Manifest.hs`, `FoldFingerprint.hs`,
`ReplayImpact.hs`, `Diff.hs`, and the generated codec, snapshot, projection, and harness paths all
consume parts of the resolved identity and must be reconciled.

`keiro-core/src/Keiro/Codec/Structural.hs` publishes the existing total structural binding. Add
the parallel generic nominal contract in `keiro-core/src/Keiro/Codec/Nominal.hs`; it is a
consumer-facing runtime integration point and must carry the same stability warning. `keiro-core`
does not need a TypeID dependency because the representation is a type parameter. The DSL checker
and generated ID codec do need the checked TypeID APIs.

`keiro-core/src/Keiro/Codec.hs` fixes event encoding at `event -> Value`, so an encoding-time
semantic failure cannot be added locally by the generator. `keiro/src/Keiro/Snapshot/Codec.hs`
uses the consumer instances required by `RegFileToJSON`; nominal event-codec conformance therefore
does not replace snapshot-cache conformance. `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` and
`WorkspaceScaffold.hs` preflight before writing but do not stage a temporary tree.

The Keiki dependency is `mori://shinzui/keiki/packages/keiki`. Its `FieldProjection` and
`FieldWitness` API gives a generated facade a coherent, total projection from a consumer type to a
built-in scalar for direct register and matched-input guards. Its `TApp1` escape hatch is opaque to
the symbolic translator, so this plan must not implement nominal visibility as an ordinary
function application.

The authoritative `KindID` dependency is
`mori://MMZK1526/mmzk-typeid/packages/mmzk-typeid`. Its `Data.KindID` API provides
`KindID prefix`, checked `parseText`, and `toText`; `Data.TypeID.checkPrefix` validates a prefix
available only at DSL-check time. Hackage and the upstream `v0.7.1.1` tag agreed on release 0.7.1.1
during this audit. The repository already uses `mmzk-typeid >=0.7 && <0.8` in `keiro/keiro.cabal`.

[ADR 12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
requires a single schema authority and total consumer bindings. This plan extends that rule to
nominal values without introducing a partial inverse. [ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
requires invalid or incomplete mappings to fail during checking, before scaffolding.
[ADR 3](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md) keeps snapshots
as invalidatable replay caches, and
[ADR 15](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
requires whole-workspace detection-before-write rather than staged replacement. The completed
[plan 149](149-implement-the-ir-1-spec-layer-resolved-type-graph-structural-and-opaque-declarations-check-and-diff.md) supplies
the structural binding pattern, while
[plan 151](151-reduce-binding-boilerplate-skeleton-scaffolds-derived-nominal-bindings-and-explain-bindings.md) does
not cover scalar/ID nominality.

In this plan, the “wire value” is the JSON stored in an event. A “representation” is the total,
typed value immediately inside that wire boundary: `KindID prefix` for an ID, a generated closed
datatype for an enum, or a built-in scalar for a nominal scalar. The “consumer type” is the
application's nominal Haskell type. A “nominal binding” is a versioned total isomorphism between
the consumer and representation types. A “wire fixture” pairs a consumer value with the JSON that
the generated codec must emit. A “refined scalar” is a consumer type that accepts only a subset of
its proposed built-in representation and is deliberately not a nominal binding.


## Plan of Work

Milestone 1 first reconciles plan 160's landed version types and publishes the generic runtime
contract. Add `Keiro.Codec.Nominal` under `keiro-core/src/Keiro/Codec/Nominal.hs`, with total
`NominalBinding`, labelled expected-wire fixtures, and two law helpers. Add focused tests to the
existing `keiro-test` suite before any generator consumes it. Then extend `Grammar.hs`,
`Parser.hs`, and `PrettyPrint.hs` so the next language-version parser, expected to be version 2,
accepts and round-trips these canonical declarations:

```keiro
language keiro-dsl 2
context orders

id OrderId prefix=ord using {
  haskell package=orders-domain module=Orders.Id type=OrderId
  binding = "Orders.KeiroBindings.orderIdBinding"
  binding-version = "1"
  canonical-type = "orders.OrderId.v1"
  fixtures = "Orders.KeiroBindings.orderIdFixtures"
}

enum OrderStatus {
  Draft=draft
  Submitted=submitted
} using {
  haskell package=orders-domain module=Orders.Order type=OrderStatus
  binding = "Orders.KeiroBindings.orderStatusBinding"
  binding-version = "1"
  canonical-type = "orders.OrderStatus.v1"
  fixtures = "Orders.KeiroBindings.orderStatusFixtures"
}

mapped nominal AccountNumber : Text {
  haskell package=orders-domain module=Orders.Account type=AccountNumber
  binding = "Orders.KeiroBindings.accountNumberBinding"
  binding-version = "1"
  canonical-type = "orders.AccountNumber.v1"
  fixtures = "Orders.KeiroBindings.accountNumberFixtures"
  initial = "Orders.KeiroBindings.initialAccountNumber"
}
```

The exact delimiters and clause order above are acceptance requirements. The combined parser route
for the `mapped` keyword must select nominal, structural, or opaque before parsing mode-specific
clauses; do not add a later alternative that fails after consuming `mapped`. Version 1 and legacy
unversioned parsers must reject these forms with the language-version diagnostic rather than
partially accepting them. Store nominal scalar declarations separately from `MappedDecl` so the
existing structural `TypeGraph` folds do not gain a semantically unrelated partial case. Extend
workspace relocation, merged-spec construction, and `HasLocs` instances in the same milestone.

Milestone 2 adds `keiro-dsl/src/Keiro/Dsl/NominalType.hs`. Reuse `HaskellSource`,
`QualifiedValueName`, `BindingVersion`, and `CanonicalTypeId`, but expose only checked values after
validation. One registry covers unbound and bound direct IDs, unbound and bound direct enums, and
bound nominal scalars. Integrate it into `AggregateType.hs` so type identity, Haskell lowering,
imports, packages, samples, capability checks, initial values, and canonical fingerprints consume
the same resolved nominal value.

At this boundary, call `Data.TypeID.checkPrefix` for every bound ID prefix. Require all binding
facts when a consumer block is present, require a non-empty fixture symbol, validate qualified
names, reject a nominal scalar representation outside the five built-ins, and require `initial`
only for actual register use. A direct bound enum register initial never renders a DSL constructor
as though it were a consumer constructor; it uses the declared consumer initial symbol. Add stable,
located, append-only diagnostics for each omission or incompatibility and extend name-collision
checks across ID, enum, nominal scalar, mapped, rule, and node declarations. Extend
`ExplainBindings.hs` to print the exact category-specific binding, fixture, canonical identity,
and conditional initial signatures in text and JSON.

Milestone 3 makes code generation and compatibility reporting consume the registry. For bound IDs
and enums, `Scaffold.hs` imports the consumer type and omits the public generated domain
declaration. It generates a private enum representation leaf module, a create-once binding
skeleton, and codec functions. ID decoding first parses JSON text with
`Data.KindID.parseText @prefix`, then applies the total binding; encoding applies the binding then
`Data.KindID.toText`. Enum JSON maps only between declared wire spellings and its closed generated
representation. Scalar JSON uses the existing built-in Aeson parser and encoder around the total
binding. No generated runtime codec path uses `coerce`, `read`, an unsafe TypeID parser, `error`,
or a partial pattern. Create-once hand-owned skeletons may use the repository's labelled `HOLE`
stubs until the consumer supplies a binding.

Generate one context-level `NominalProjections` facade for bound scalar types used by direct
register or matched-input guards. Each type gets one stable nominal tag with `FieldOwner` equal to
the consumer type, `FieldResult` equal to the built-in representation, `fieldShapeId` equal to the
declared canonical type, and `projectFieldValue` equal to `nominalToRepresentation binding`.
Holes use `regProj` and `inpProj`; event/command codecs do not use this facade. Do not claim or
generate `.keiro` guard execution, computed-base projections, output/update projections, ID/enum
symbolic visibility, or nominal arithmetic.

Update `Goldens.hs`, `Manifest.hs`, `FoldFingerprint.hs`, `ReplayImpact.hs`, `Diff.hs`,
`MappedConsumer.hs`, `ScaffoldRun.hs`, `ScaffoldRecord.hs`, `WorkspaceRecord.hs`,
`WorkspaceScaffold.hs`, and every scaffold/harness helper that exhaustively consumes aggregate
types. Wire fingerprints contain ID prefix, enum constructor/wire pairs, or scalar representation,
not consumer naming. Consumer package/module/type, canonical type, binding symbol/version, fixture
symbol, and optional initial remain separately diff-visible provenance. A binding source, symbol,
or version change leaves the declared JSON bytes unchanged but is not provably replay-neutral:
report consumer rebuild at every use, target affected old event types for event uses, and include
snapshot-bearing streams plus snapshot invalidation for register uses. A fixture-symbol-only
change is an evidence/build finding. Representation, prefix, or enum wire changes retain their
existing use-site-specific wire and replay classifications. Binding adoption/removal receives the
same conservative use-site treatment and must not silently reuse a prior generated type. In
addition, adopting a bound ID at an existing event field reports the decoder-tightening
historical-read advisory even when the prefix fingerprint is unchanged; its deployment gate is a
passing committed old-payload fixture plus the targeted real-log audit, not a fabricated upcast of
already-valid bytes.

Persist nominal provenance using `nominal-mapping` rows in both record formats. New readers merge
ordinary and nominal rows for duplicate-name checks and drift; old readers ignore the new row kind.
Do not change the JSON emitted for existing `mapping` rows or the single-file record header. Add
the consumer package and, for bound IDs, `mmzk-typeid` to generated Cabal requirements. Keep
snapshot execution honest: bound nominal registers require consumer `ToJSON`, `FromJSON`, and
`CanonicalTypeName`; the harness verifies their cache round trip and canonical identity, while the
event binding and its version contribute to fold/snapshot invalidation.

Milestone 4 adds `keiro-dsl-conformance-nominal-scalars` under
`keiro-dsl/test/conformance-nominal-scalars/` and source fixtures under
`keiro-dsl/test/fixtures/`. Cover a consumer `OrderId` over `KindID "ord"`, a consumer enum whose
constructors deliberately differ from the generated representation, and nominal wrappers over
Text, Int, Natural, Bool, and Time. Include command-only, event-only, and register use sites. The
suite proves expected JSON bytes, both binding laws, canonical identity, ID wrong-prefix and
malformed-text rejection, unknown enum rejection, snapshot-cache round trip, scalar projection
witness agreement, supported equality/ordering checks, forward execution, decoded replay, and
deterministic scaffolding. Enum fixtures must cover every generated representation constructor
and every declared wire spelling exactly once. For each fixture, the harness parses the expected
wire into the representation, compares it with `nominalToRepresentation`, and exercises both laws;
ID and scalar fixtures remain explicitly finite evidence.

For the bound-ID adoption case, keep a versioned pre-adoption event payload containing a valid
`ord` TypeID and prove the new decoder still reads it. Keep explicit malformed and wrong-prefix
payloads as rejection cases. Diff the unbound and bound fixtures and assert the named
decoder-tightening finding targets the containing event and replay audit without claiming that
valid bytes require an upcast.

Add check-fail fixtures for incomplete facts, bad qualified names, invalid TypeID prefix,
unsupported representation, missing register initial, cross-category name collision, and
version-1 syntax use. Add a compile-fail fixture showing that the former partial `Either` inverse
does not inhabit `NominalBinding`; refined types remain rejected at the DSL check boundary. Add
mutations that transpose enum representations, change an expected scalar wire value, and change
the ID suffix in only one binding direction; each must turn the owning conformance gate red.
Update the authoring guide, typed toolchain guide, language-version migration note, changelog, ADR
12's total-binding inventory, and ADR 4's earliest-boundary inventory. ADRs 3 and 15 need changes
only if implementation changes their existing contracts, which this plan does not intend.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/keiro`.

Before implementation, prove the hard prerequisite is complete. The first command must produce no
unchecked progress rows; otherwise stop this plan and finish plan 160.

```bash
rg -n '^- \[ \]' docs/plans/160-add-an-explicit-keiro-dsl-language-version-contract.md
sed -n '1,280p' docs/plans/160-add-an-explicit-keiro-dsl-language-version-contract.md
```

Reconfirm dependency ownership and the released API before changing a Cabal dependency. At the
time of this revision, Hackage's first normal version and the highest upstream tag are both
0.7.1.1.

```bash
mori registry search mmzk-typeid
mori registry show MMZK1526/mmzk-typeid --full
mori path mori://MMZK1526/mmzk-typeid/packages/mmzk-typeid
curl -fsSL https://hackage.haskell.org/package/mmzk-typeid/preferred.json
git ls-remote --tags https://github.com/MMZK1526/mmzk-typeid.git
```

Implement milestone tests incrementally, then run the focused gates:

```bash
cabal test keiro-test --test-options='--match=Keiro.Codec.Nominal'
cabal test keiro-dsl-test --test-options='--match=nominal'
cabal test keiro-dsl-conformance-nominal-scalars
```

The focused tests must report no failures. The conformance output must name successful checks for
the two binding laws, expected wire parity, wrong-prefix rejection, every scalar representation,
projection agreement, snapshot cache, forward execution, and replay. Inspect a version-2 fixture
and then two clean scaffolds:

```bash
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/nominal-scalars.keiro
cabal run keiro-dsl -- pretty keiro-dsl/test/fixtures/nominal-scalars.keiro
tmp_a=$(mktemp -d)
tmp_b=$(mktemp -d)
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/nominal-scalars.keiro --out "$tmp_a"
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/nominal-scalars.keiro --out "$tmp_b"
diff -ru "$tmp_a" "$tmp_b"
```

Expected final output from `diff` is empty. Prove version isolation with a fixture containing the
new syntax under language version 1; `check` must fail once with the language-version diagnostic,
not with downstream parser noise. Run the mutation scripts and assert that each exits non-zero for
the intended named assertion.

Finish with the repository gates:

```bash
cabal test keiro-dsl-test
cabal test keiro-dsl-conformance-nominal-scalars
cabal build all
just adr-validate
nix flake check
```

The implementation session must record the allocated diagnostic codes, record-schema behavior,
dependency version verification, mutation outputs, and actual test counts in Progress and
Surprises & Discoveries.


## Validation and Acceptance

Acceptance requires all of the following:

1. The three declaration forms above are accepted only by the registered successor language
   parser, pretty-print canonically, survive workspace merging and location relocation, and appear
   with exact category-specific obligations in text/JSON explanation and both scaffold records.
2. A clean spec imports and uses the consumer types directly. Generated domain modules contain no
   second `OrderId`, `OrderStatus`, or `AccountNumber` declaration. Generated runtime modules
   contain no `coerce`, unchecked TypeID parser, `read`, partial pattern, or generated `error`.
   Create-once skeletons may contain only the established labelled `HOLE` stubs and must fail the
   owning compiled gate until the consumer replaces them.
3. The public nominal API has total conversions. The generated ID representation is
   `KindID "ord"`; wrong-prefix and malformed JSON text fail before consumer construction, and the
   encoder can emit only the type-level prefix. The checked prefix, runtime codec, fixture evidence,
   diff, golden, and fingerprint all agree on `ord`.
4. The generated enum representation has exactly the declared constructors and JSON spellings.
   Unknown spellings fail parsing. A consumer enum with different constructor names round-trips
   through total binding cases that cover every representation constructor and declared wire
   spelling exactly once, proving the generator never assumes consumer constructors equal DSL
   constructors.
5. Text, Int, Natural, Bool, and Time nominal wrappers round-trip their expected JSON values. A
   scalar projection facade exposes equality for all five and ordering only for the existing Int,
   Natural, and Time subset. The DSL and generated facade add no arithmetic capability; IDs and
   enums remain opaque.
6. Missing Haskell source, binding, binding version, canonical type, fixtures, or a required
   register initial fails `keiro-dsl check` at the owning declaration. Invalid prefix, unsupported
   representation, bad qualified symbol, and cross-category name collision have distinct stable
   codes. GHC and conformance, not `check`, validate hand-written function bodies.
7. Bound event fields use the generated wire codec; bound registers use the consumer type and the
   existing snapshot cache instances. Canonical identity is checked, a snapshot round trip passes,
   and changing binding/canonical/initial provenance invalidates the snapshot discriminator without
   being misreported as event-wire proof.
8. Binding law, expected-wire, wrong-prefix, enum-transposition, and one-direction ID mutations each
   fail their named compiled assertion. A passing finite fixture corpus is described as evidence,
   never as a proof for all consumer values.
9. Specs without binding blocks preserve the current generated ID/enum domain and codec bytes when
   interpreted under their existing language version. Under the successor version, any changed
   formatter or provenance bytes are pinned and explained; no silent wrapper-to-consumer fallback
   occurs.
10. Diff output separates consumer build, snapshot hydration, wire history, and replay surfaces.
    Binding/source/fixture-only changes are JSON-byte neutral, but source/symbol/version changes
    conservatively target old event uses and register snapshot streams because hand-written
    behavior is opaque; fixture-symbol-only changes rerun conformance without claiming runtime
    change. Prefix, enum spelling, and scalar representation changes retain ADR 4's
    earliest-sound use-site classifications.
    Adopting a bound ID at an existing event use additionally emits the decoder-tightening
    historical-read advisory, names the affected event, and requires the targeted real-log audit.
11. Existing `mapping` rows remain byte-identical. Old record readers ignore new
    `nominal-mapping` rows, new readers round-trip both row kinds, and duplicate declaration names
    across them are rejected before scaffold output changes.
12. Single-file and workspace scaffolds run all complete-graph preflights before writing; an
    unchanged rerun writes no generated module bytes and produces an empty clean-tree diff.


## Idempotence and Recovery

Parser, validation, scaffold, and test generation are deterministic and safe to repeat. Keep the
runtime API, AST/version parser, checked resolver, generation, record, and conformance changes in
separate working checkpoints so a failure can be traced to one boundary. Follow ADR 15: perform
every spec, workspace, ownership, collision, golden-root, path, and binding-obligation preflight
over the complete input before creating the output directory or writing the first byte. Compare
generated bytes and skip unchanged files. Do not introduce a staging/rename claim or transaction.

A consumer binding or snapshot instance is hand-owned Haskell and can still fail after generation
when GHC compiles the service. That failure may leave new deterministic generated modules and
create-once skeletons on disk. Correct the hand-owned module and rerun scaffold; generated modules
are reproducible, Hole stubs are never overwritten, record history is written only after the
scaffold write phase succeeds, and no file is deleted automatically.

If the syntax proves ambiguous, retain the parsed AST tests, adjust only the surface delimiters,
and regenerate fixtures through the version-specific canonical pretty-printer. Do not widen
version 1 as a recovery shortcut. If a binding-version change makes a consumer tree stale, update
the application binding, expected-wire fixtures, and any register snapshot version obligation,
then rerun scaffold. Never weaken provenance comparison, accept a partial inverse, or fall back to
generated wrappers silently.


## Interfaces and Dependencies

`Keiro.Codec.Nominal` in `keiro-core` must publish a stable contract equivalent to:

```haskell
data NominalBinding domain representation = NominalBinding
  { nominalToRepresentation :: domain -> representation
  , nominalFromRepresentation :: representation -> domain
  }

data NominalFixture domain = NominalFixture
  { nominalFixtureLabel :: Text
  , nominalFixtureWire :: Value
  , nominalFixtureDomain :: domain
  }

newtype NominalFixtureCases domain = NominalFixtureCases
  { nominalFixtureCases :: NonEmpty (NominalFixture domain)
  }

nominalDomainRoundTrip
  :: Eq domain
  => NominalBinding domain representation
  -> domain
  -> Bool

nominalRepresentationRoundTrip
  :: Eq representation
  => NominalBinding domain representation
  -> representation
  -> Bool
```

The module Haddock must say that both conversions are total, the generated codec remains the wire
authority, and a refined consumer must not use this API. If plan 151's generic representation
machinery can be reused without weakening its exactness checks, add
`genericNominalBinding`; otherwise explicit skeletons are sufficient for this plan.

`Keiro.Dsl.Grammar` must expose parser-facing fields equivalent to:

```haskell
data NominalBindingDecl = NominalBindingDecl
  { nominalHaskell :: Maybe HaskellSource
  , nominalBinding :: Maybe Text
  , nominalBindingVersion :: Maybe Text
  , nominalCanonicalType :: Maybe Text
  , nominalFixtures :: Maybe Text
  , nominalInitial :: Maybe Text
  , nominalLoc :: Loc
  }

data NominalScalarDecl = NominalScalarDecl
  { nominalScalarName :: Name
  , nominalScalarRepresentation :: Name
  , nominalScalarBinding :: NominalBindingDecl
  , nominalScalarLoc :: Loc
  }
```

`IdDecl` and `EnumDecl` gain `Maybe NominalBindingDecl`; `Spec` gains a separate nominal-scalar
collection. The parser retains the scalar representation as a located name so `check`, rather
than low-level parser failure, owns the stable unsupported-representation diagnostic. Parser
binding fields remain optional only so `check` can issue complete located diagnostics. The
checked `NominalType` layer must make missing facts unrepresentable, resolve the raw name to the
closed representation set, and expose values equivalent to:

```haskell
data NominalScalarRepresentation
  = NominalText
  | NominalInt
  | NominalNatural
  | NominalBool
  | NominalTime

data NominalRepresentation
  = IdRepresentation Text
  | EnumRepresentation (NonEmpty (Name, Text))
  | ScalarRepresentation NominalScalarRepresentation

data NominalOwnership
  = GeneratedNominal
  | ConsumerNominal ConsumerNominalBinding

data ResolvedNominalType = ResolvedNominalType
  { resolvedNominalName :: Name
  , resolvedNominalRepresentation :: NominalRepresentation
  , resolvedNominalOwnership :: NominalOwnership
  }

data ConsumerNominalBinding = ConsumerNominalBinding
  { consumerNominalHaskell :: HaskellSource
  , consumerNominalBinding :: QualifiedValueName
  , consumerNominalBindingVersion :: BindingVersion
  , consumerNominalCanonical :: CanonicalTypeId
  , consumerNominalFixtures :: QualifiedValueName
  , consumerNominalInitial :: Maybe QualifiedValueName
  }
```

`AggregateType.hs` should contain one nominal constructor backed by this resolved value rather
than separate downstream binding lookups for IDs, enums, and scalars. Its exhaustive functions for
canonical name, Haskell type, imports, packages, sample, capabilities, and register initial must
all pattern-match the resolved ownership and representation.

Generated binding signatures are category-specific and appear exactly in `--explain-bindings`:

```haskell
orderIdBinding
  :: NominalBinding Orders.Id.OrderId (KindID "ord")

orderStatusBinding
  :: NominalBinding
       Orders.Order.OrderStatus
       Generated.Orders.Nominal.Shape.OrderStatus.OrderStatusRepresentation

accountNumberBinding
  :: NominalBinding Orders.Account.AccountNumber Text

orderIdFixtures :: NominalFixtureCases Orders.Id.OrderId
initialAccountNumber :: Orders.Account.AccountNumber
```

The generated enum representation module imports neither a binding nor a consumer module. Binding
skeletons may import the consumer module and representation leaf; generated codecs may then import
the binding without a module cycle, following the structural shape discipline in ADR 12.

Plan 160's released language-version registry is a hard prerequisite. This plan must register the
nominal-binding syntax under the next allocated language version (or a jointly allocated version
when deliberately released with another syntax plan), preserve older parser behavior, and document
the manual source rewrite until IR-5 provides `keiro-dsl upgrade`. If version 2 has already been
allocated by implementation time, select the next unreleased version and update every example and
fixture in this plan before writing code.

Use `Data.TypeID.checkPrefix`, checked `Data.KindID.parseText`, and `Data.KindID.toText` from
`mori://MMZK1526/mmzk-typeid/packages/mmzk-typeid`; do not reconstruct or validate TypeIDs with
string splitting. Add a direct `mmzk-typeid >=0.7 && <0.8` dependency to the `keiro-dsl` library
and the new conformance suite, matching `keiro/keiro.cabal`, only after repeating the registry and
tag verification in Concrete Steps. Generated manifests add `mmzk-typeid` only for a bound ID.
`keiro-core`'s generic nominal API adds no new external dependency.

For a nominal consumer used in a generated domain ADT, GHC must see the existing `Eq` and `Show`
requirements. A register use additionally requires `CanonicalTypeName`, `ToJSON`, and `FromJSON`
for the snapshot cache. The harness checks `canonicalTypeName (Proxy @consumer)` against the
declared `canonical-type`; Keiro does not generate an orphan instance. Binding, fixtures, and
initial symbols are hand-owned modules in the scaffold target component; `haskell package=` names
the package that owns the consumer type and is the external dependency added to the manifest.

Extend `MappingIdentity` with nominal provenance for internal drift/diff use, but render it under a
new `nominal-mapping` row in `ScaffoldRecord` and `WorkspaceRecord`. New parsers accept both row
kinds, ignore unknown JSON keys, reject duplicate spec names across the combined set, and continue
to parse existing records byte-for-byte. Existing `mapping` JSON schema and row bytes do not
change.


Revision note: Detached this plan from the completed structural-consumer-type MasterPlan so it is
an independent implementation unit, 2026-07-31.

Revision note (2026-07-31): Validated the design against the landed Keiro and Keiki APIs, ADRs 3,
4, 12, and 15, Mori-resolved `mmzk-typeid` source, Hackage 0.7.1.1, and upstream tag v0.7.1.1.
Replaced the unsafe partial inverse with total category-specific representations, required
canonical and expected-wire evidence, version-gated the syntax behind plan 160, corrected solver
and snapshot claims, made opaque binding changes and bound-ID adoption conservatively
replay-visible, preserved record backward compatibility with a new row kind, and aligned recovery
with workspace detection-before-write.

Revision note (2026-07-31): Implemented and validated all four milestones. The completed plan now
records the generated nominal codec/projection/record surfaces, append-only diagnostics, compiled
conformance and mutation evidence, two full-suite compatibility fixes, documentation and ADR
distillation, and the final repository-wide validation results.
