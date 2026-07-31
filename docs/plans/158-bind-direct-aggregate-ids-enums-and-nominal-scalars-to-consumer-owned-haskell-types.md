---
id: 158
slug: bind-direct-aggregate-ids-enums-and-nominal-scalars-to-consumer-owned-haskell-types
title: "Bind direct aggregate IDs enums and nominal scalars to consumer-owned Haskell types"
kind: exec-plan
created_at: 2026-07-31T14:46:35Z
---

# Bind direct aggregate IDs enums and nominal scalars to consumer-owned Haskell types

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, an aggregate author can use an existing domain type for a direct aggregate
identifier, enum, or scalar instead of accepting a second generated wrapper. For example, an
`OrderId` declared by an application as `KindID "ord"` can remain the type used by commands,
events, registers, snapshots, JSON codecs, and harness fixtures. A nominal `AccountNumber` over
`Text` likewise remains distinct from every other text-valued field without being flattened to
`Text` in generated code.

The behavior is visible by scaffolding a fixture whose ID, enum, and nominal scalar all point at
consumer-owned modules, compiling the generated service without duplicate type declarations, and
round-tripping values through JSON, snapshot, forward execution, and replay. Prefix validation for
an ID must happen at decode and fixture boundaries, not merely remain descriptive metadata.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: specify and parse consumer bindings for direct IDs, enums, and nominal scalars.
- [ ] Milestone 2: resolve the declarations into one checked nominal-type model and diagnose
  missing or incompatible binding facts at `keiro-dsl check`.
- [ ] Milestone 3: make every scaffold, codec, snapshot, manifest, diff, fingerprint, and harness
  consumer use the checked model.
- [ ] Milestone 4: add compiled conformance fixtures, mutation tests, documentation, ADR updates,
  and full validation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-31: The current `idPrefix` is used by validation, pretty printing, golden samples, and
  diffing, but generated IDs are still `newtype X = X Text`; no generated decoder enforces the
  prefix. The nominal binding therefore has to carry executable conversion behavior, not just a
  Haskell type name.
- 2026-07-31: Existing plan 151's “nominal bindings” are exact bindings between consumer-owned
  structural records and generated wire shapes. They do not bind direct aggregate scalar, ID, or
  enum declarations, so this work is not covered by that completed plan.


## Decision Log

Record every decision made while working on the plan.

- Decision: Add an explicit `mapped nominal` declaration for scalar wrappers and optional
  consumer-binding blocks to direct `id` and `enum` declarations.
  Rationale: Nominality and wire representation are different facts. Reusing the checked mapped
  binding vocabulary keeps package, module, type, binding symbol, fixture, and version provenance
  explicit while preserving the convenient direct aggregate syntax.
  Date: 2026-07-31

- Decision: A nominal scalar must declare exactly one built-in representation from `Text`, `Int`,
  `Natural`, `Bool`, or `Time`; IDs use their declared TypeID prefix and enums use their existing
  wire spellings as their representations.
  Rationale: Keiro can only validate, sample, compare, snapshot, and lower a consumer type when its
  semantic and wire domains are known. `mapped opaque` remains the escape hatch for types without
  a Keiro-visible representation.
  Date: 2026-07-31

- Decision: Bindings are total bidirectional conversions and versioned provenance, not Haskell
  type aliases or unchecked coercions.
  Rationale: Generated command/event code, codecs, fixtures, and Keiki terms must agree on one
  representation. A type name alone cannot enforce ID prefixes or detect lossy conversions.
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

(To be filled during and after implementation.)


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
allowlist. `Goldens.hs`, `Manifest.hs`, `FoldFingerprint.hs`, `ReplayImpact.hs`, `Diff.hs`, and the
generated codec, snapshot, and harness paths all consume the same resolved identity.

The authoritative `KindID` dependency is
`mori://MMZK1526/mmzk-typeid/packages/mmzk-typeid`. Its `Data.KindID` API provides
`KindID prefix`, checked `parseText`, and `toText`; a generated `Text` wrapper does not provide the
same type-level or decode-time prefix guarantee.

[ADR 12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
requires a single schema authority and total consumer bindings. This plan extends that rule to
nominal values. [ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
requires invalid or incomplete mappings to fail during checking, before scaffolding. The completed
[plan 149](149-implement-the-ir-1-spec-layer-resolved-type-graph-structural-and-opaque-declarations-check-and-diff.md) supplies
the structural binding pattern, while
[plan 151](151-reduce-binding-boilerplate-skeleton-scaffolds-derived-nominal-bindings-and-explain-bindings.md) does
not cover scalar/ID nominality.

In this plan, the “representation” is the Keiro-visible built-in value used for guards and wire
encoding. The “consumer type” is the application's nominal Haskell type. A “nominal binding” is a
versioned total conversion between those two types plus deterministic fixtures and an initial
value where the declaration is used by a register.


## Plan of Work

Milestone 1 adds syntax and a lossless AST. Extend `Grammar.hs`, `Parser.hs`, and
`PrettyPrint.hs` so the following declarations round-trip:

```keiro
id OrderId prefix=ord {
  haskell package=orders-domain module=Orders.Id type=OrderId
  binding = "Orders.KeiroBindings.orderIdBinding"
  binding-version = "1"
  fixtures = "Orders.KeiroBindings.orderIdFixtures"
}

enum OrderStatus {
  Draft=draft
  Submitted=submitted
} using {
  haskell package=orders-domain module=Orders.Order type=OrderStatus
  binding = "Orders.KeiroBindings.orderStatusBinding"
  binding-version = "1"
  fixtures = "Orders.KeiroBindings.orderStatusFixtures"
}

mapped nominal AccountNumber : Text {
  haskell package=orders-domain module=Orders.Account type=AccountNumber
  binding = "Orders.KeiroBindings.accountNumberBinding"
  binding-version = "1"
  fixtures = "Orders.KeiroBindings.accountNumberFixtures"
  initial = "Orders.KeiroBindings.initialAccountNumber"
}
```

The exact delimiters above are part of acceptance: pretty printing must produce one canonical
form and parse it back. Add located, append-only diagnostic codes for duplicate clauses,
unsupported nominal representations, missing binding facts, and name collisions. Update workspace
relocation and merge instances at the same time.

Milestone 2 introduces checked nominal declarations in a focused module such as
`keiro-dsl/src/Keiro/Dsl/NominalType.hs` and integrates them into `AggregateType.hs`. Reuse
`HaskellSource`, `QualifiedValueName`, and `BindingVersion`. Resolve a direct type to either a
generated definition or a consumer-owned nominal binding with its representation and capabilities.
Validate ID prefixes both as legal TypeID prefixes and as part of the binding's conformance
fixtures. Add `explain-bindings --json` obligations for the binding, fixtures, and optional initial
symbol just as structural declarations already do.

Milestone 3 removes direct-name special cases from downstream consumers. `Scaffold.hs` must import
consumer modules and binding symbols, omit the generated ID/enum/scalar declaration, and lower
commands, events, registers, snapshots, and Keiki terms through the binding. Update `Goldens.hs`,
`Manifest.hs`, `FoldFingerprint.hs`, `ReplayImpact.hs`, `Diff.hs`, `MappedConsumer.hs`,
`ScaffoldRun.hs`, `ScaffoldRecord.hs`, and `WorkspaceRecord.hs` so binding identity/version and
representation changes are visible. A change of package/module/type/binding/version is a source
compatibility change; a change of ID prefix, enum wire spelling, or scalar representation retains
its existing wire/replay severity.

Milestone 4 adds a compiled conformance service under `keiro-dsl/test/conformance-nominal-scalars/`
and fixtures under `keiro-dsl/test/fixtures/`. Cover `KindID "ord"`, a consumer enum, and Text,
Natural, and Time nominal wrappers. The suite must prove JSON and snapshot round trips, exact ID
prefix rejection, command execution, replay, deterministic scaffolding, binding-version diffing,
and a mutation that makes an intentionally dishonest conversion fail. Update the authoring guide,
typed toolchain guide, changelog, ADR 12, and ADR 4 if the implementation adds new diagnostic or
binding invariants.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/keiro`.

```bash
cabal test keiro-dsl-test --test-options='--match=nominal.*binding'
cabal test keiro-dsl-conformance-nominal-scalars
cabal test keiro-dsl-test
cabal build all
nix flake check
```

The focused tests should report no failures, and the conformance executable should print one pass
for generated-definition compatibility, consumer ID prefix rejection, consumer enum wire parity,
each scalar representation, snapshot round trip, forward execution, and replay. Inspect two clean
scaffolds to prove determinism:

```bash
tmp_a=$(mktemp -d)
tmp_b=$(mktemp -d)
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/nominal-scalars.keiro --out "$tmp_a"
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/nominal-scalars.keiro --out "$tmp_b"
diff -ru "$tmp_a" "$tmp_b"
```

Expected final output from `diff` is empty. The implementation session must record the allocated
diagnostic codes and replace these example transcripts with actual test counts.


## Validation and Acceptance

Acceptance requires all of the following:

1. The three declaration forms above parse, pretty-print canonically, survive workspace merging,
   and appear with their binding provenance in `explain-bindings --json` and scaffold records.
2. A clean spec imports and uses the consumer types directly. Generated modules contain no second
   `OrderId`, `OrderStatus`, or `AccountNumber` declaration and no unchecked `coerce`, `read`, or
   partial conversion.
3. `KindID "ord"` values round-trip, while JSON containing a different prefix fails decoding at a
   typed boundary. The DSL's `prefix=ord` affects executable behavior, fixtures, diffing, and
   fingerprints.
4. Bound scalar values retain the built-in representation's equality/ordering capability and no
   additional arithmetic capability. Bound enums and IDs remain opaque in Keiki unless a later
   plan explicitly adds a symbolic binding.
5. Missing binding, version, fixtures, or a required register initial fails `keiro-dsl check` at the
   declaration. An invalid binding fixture fails the compiled conformance target.
6. Specs without binding blocks generate byte-for-byte equivalent domain types to the current
   behavior, apart from deliberate formatter or scaffold-record version changes.
7. Binding identity/version and representation changes are reported by `keiro-dsl diff`; wire or
   replay-affecting changes retain the earliest-sound-boundary classifications required by ADR 4.


## Idempotence and Recovery

Parser, validation, scaffold, and test generation are deterministic and safe to repeat. Keep AST,
resolver, and downstream lowering changes in separate checkpoints so a failed conformance compile
can be traced to one boundary. The scaffolder must stage generated output and replace it only after
all binding obligations validate; an invalid consumer module must never leave a half-updated tree.

If the syntax proves ambiguous, retain the parsed AST tests, adjust only the surface delimiters,
and regenerate fixtures through the canonical pretty-printer. If a binding-version change makes a
consumer tree stale, rerun scaffold after updating the application binding; never weaken the
version comparison or fall back to generated wrappers silently.


## Interfaces and Dependencies

`Keiro.Dsl.Grammar` must expose declaration fields equivalent to:

```haskell
data NominalRepresentation = NominalText | NominalInt | NominalNatural | NominalBool | NominalTime

data NominalBindingDecl = NominalBindingDecl
  { nominalHaskell :: Maybe HaskellSource
  , nominalBinding :: Maybe Text
  , nominalBindingVersion :: Maybe Text
  , nominalFixtures :: Maybe Text
  , nominalInitial :: Maybe Text
  , nominalLoc :: Loc
  }
```

`IdDecl` and `EnumDecl` gain `Maybe NominalBindingDecl`; a new nominal-scalar declaration carries
its representation. The checked layer must expose a resolved type containing `GeneratedNominal`
or `ConsumerNominal` plus `QualifiedValueName`, `BindingVersion`, representation, fixtures, and
optional initial symbol.

Plan 160's released language-version registry is a hard prerequisite. This plan must register the
nominal-binding syntax under the next allocated language version (or a jointly allocated version
when deliberately released with another syntax plan), preserve older parser behavior, and document
the manual source rewrite until IR-5 provides `keiro-dsl upgrade`.

Generated code must consume a public binding contract equivalent to:

```haskell
data NominalBinding consumer representation = NominalBinding
  { toRepresentation :: consumer -> representation
  , fromRepresentation :: representation -> Either Text consumer
  }
```

The actual home may be Keiki if symbolic conversion must be shared, but Keiro owns the JSON,
snapshot, fixture, and prefix-conformance requirements. Use checked `Data.KindID.parseText` and
`Data.KindID.toText` from `mori://MMZK1526/mmzk-typeid/packages/mmzk-typeid`; do not reconstruct
or validate TypeIDs with string splitting. No dependency bound changes are allowed without
verifying the authoritative package registry and upstream release tag at implementation time.


Revision note: Detached this plan from the completed structural-consumer-type MasterPlan so it is
an independent implementation unit, 2026-07-31.
