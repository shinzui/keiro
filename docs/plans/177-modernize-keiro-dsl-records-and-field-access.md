---
id: 177
slug: modernize-keiro-dsl-records-and-field-access
title: "Modernize keiro-dsl records and field access"
kind: exec-plan
created_at: 2026-08-01T20:05:19Z
intention: "intention_01kyzdr07ge299bk2axrgwssht"
master_plan: "docs/masterplans/28-build-a-modular-source-aware-keiro-dsl-language-frontend.md"
---

# Modernize keiro-dsl records and field access

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Status: Cancelled on 2026-08-01 at the maintainer's direction. No implementation from this plan is
part of MasterPlan 28. The plan is retained as a historical record of the removed scope; existing
production records and selectors remain unchanged by the frontend initiative.

After this change, production records owned by `keiro-dsl` use the record-pattern conventions:
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`
Field names express the field's meaning instead of repeating an abbreviated type name, fields are
strict, deriving strategies are explicit, and records support `Generic`. Newtypes retain
descriptive `unTypeName` accessors. The
new language-frontend records introduced by later plans therefore begin with names such as
`offset`, `line`, `column`, `span`, and `value`, rather than adding another family of
`sourceOffset`, `spanStart`, or `locatedValue` selectors.

This is an intentional Haskell API cleanup immediately after the 0.7.0.0 baseline and before broad
adoption. It belongs in the next PVP-breaking release rather than a 0.7 patch: callers that use
exported selectors receive a checked migration table, while `.keiro` syntax, semantic values, JSON
keys, CLI output, canonical rendering, generated Haskell bytes, and runtime behavior remain
identical to the EP-172 oracle. A compile guard proves that adopting the record convention does not
bring generic-lens's orphan `IsLabel` instance into modules that also use Keiki labels.


## Progress

- [x] Cancelled before implementation so MasterPlan 28 can focus on the source-aware frontend
  (2026-08-01).
- [ ] Milestone 1: inventory production records, selectors, serialization contracts, and import closures.
- [ ] Milestone 2: modernize `Grammar`, language-contract, and parser-boundary records.
- [ ] Milestone 3: modernize analysis, report, workspace, scaffold, and CLI records.
- [ ] Milestone 4: migrate access/update sites and prove API, wire, generated-code, and Keiki-label safety.


## Surprises & Discoveries

- Observation: Only the original DSL is used by downstream projects today; language versions 2
  and 3 have no adopters yet.
  Evidence: Maintainer report on 2026-08-01 while this plan was written.
  Impact: Preserve v2/v3 as released regression contracts, but do not design downstream selector
  shims or source migrations for users that do not exist. Complete the cleanup before those
  dialects gain adoption.


## Decision Log

- Decision: Remove redundant datatype prefixes from all production record fields in
  `keiro-dsl/src` and `keiro-dsl/app`, not only from records added by the frontend plans.
  Rationale: A partial convention would preserve the ambiguity that led to prefixes and would make
  every new frontend type choose between two competing local styles.
  Date: 2026-08-01

- Decision: Treat `unTypeName` on a single-field newtype as an accessor, not as a prohibited record
  prefix.
  Rationale: The record-pattern guide distinguishes newtype unwrapping from redundant
  datatype-qualified product fields, and names such as `unLoc` remain unambiguous and useful.
  Date: 2026-08-01

- Decision: Preserve every external serialization key and rendered/generated artifact explicitly
  instead of deriving those schemas from renamed Haskell selectors.
  Rationale: A Haskell API cleanup must not silently become a wire-format or language-contract
  change. Several report and workspace types have hand-written Aeson instances that already make
  this separation possible.
  Date: 2026-08-01

- Decision: Never import `Data.Generics.Labels` from a prelude, record-definition module, or an
  import closure visible to a Keiki-facing consumer. Use record construction and pattern matching
  with puns in those paths; use generic-lens labels only in a demonstrably isolated leaf module.
  Rationale: `Data.Generics.Labels` supplies an orphan `IsLabel` instance and orphan visibility is
  transitive. `keiro-dsl` depends on Keiki and its conformance callers use Keiki's overloaded
  labels, so convenience cannot be allowed to change `#label` resolution downstream.
  Date: 2026-08-01

- Decision: Do not retain deprecated top-level aliases for the old selectors.
  Rationale: Aliases such as `idName`, `wfKey`, and `aggName` would preserve the old vocabulary,
  enlarge an already broad public surface, and collide as records converge on shared labels. A
  PVP-breaking release plus a complete migration table is clearer.
  Date: 2026-08-01


## Outcomes & Retrospective

Cancelled before production changes. The proposed package-wide selector, strictness, deriving, and
Generic migration was judged independently large and unnecessary for the frontend architecture.
EP-173 now depends directly on EP-172. New frontend records may use concise semantic fields, but
existing production records remain within the frozen 0.7 public-API contract.


## Context and Orientation

`keiro-dsl/keiro-dsl.cabal` already enables `DuplicateRecordFields`, but the production tree still
contains hundreds of record fields, many using historical datatype prefixes or abbreviations. The
largest concentration is `keiro-dsl/src/Keiro/Dsl/Grammar.hs`: examples include `idName`,
`enumName`, `wfKey`, `aggName`, `procName`, `rmName`, and `wfName`. Similar conventions appear in
`LanguageVersion.hs`, `SemanticContract.hs`, `Validate.hs`, `Workspace.hs`, `CodecCompare.hs`,
`Coverage.hs`, `ScaffoldRun.hs`, and the remaining exposed modules. `keiro-dsl/app/Main.hs` owns the
CLI option records. The implementation audit must classify fields by meaning; it must not remove a
word merely because it matches part of the datatype name. For example, `sourceLanguage` and
`runtimeSemantics` name real concepts, while `definitionRuntimeSemantics` redundantly repeats its
owner.

The authoritative cross-repository convention is:
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`
It requires unprefixed shared labels, strict fields, explicit deriving strategies, `Generic`,
entity identifiers first in event/command data, and local record manipulation. It also warns that
`Data.Generics.Labels` defines an orphan
`IsLabel` instance which must not be placed in a prelude and which can conflict with Keiki's own
overloaded labels. The `keiro-dsl` library directly depends on `keiki`; conformance sources under
`keiro-dsl/test/conformance*` import `Keiki.Builder`, `Keiki.Core`, and `Keiki.Generics`. This makes
the import-closure check an acceptance condition, not a stylistic suggestion.

`keiro-dsl/src/Keiro/Dsl/Grammar.hs` exports the semantic graph consumed by validation, generation,
diffing, replay, and workspaces. Its `Loc` intentionally has location-insensitive equality, which
must remain unchanged. Numerous report and workspace modules define explicit `ToJSON`/`FromJSON`
instances with literal keys. Field renames must leave those keys alone. The scaffolder already emits
unprefixed domain fields such as `reservationId`, `hospitalId`, and `commandId`, with the aggregate
identifier first in command/event data; those generated bytes are frozen by EP-172 and are not a
rename target.

[EP-172](172-freeze-the-keiro-dsl-0-7-language-frontend-contract.md) is the hard dependency and
provides exact external-behavior and public-API evidence. This plan deliberately changes the public
selector portion of that API, documents the delta, and requires every non-selector observation to
remain equal. Only the original DSL has current downstream users. Released v2/v3 behavior remains
in the oracle, but there is no adopted v2/v3 fleet to migrate.

[ADR 16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) keeps `Spec`
as the normalized semantic graph and therefore forbids field cleanup from changing its meaning.
[ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) protects stable
diagnostic codes and rendering. No existing ADR establishes Haskell record naming; record
conventions should be documented in contributor-facing package guidance unless implementation
reveals an architectural decision that warrants a new ADR.


## Plan of Work

Milestone 1 produces an auditable migration manifest before renaming anything. Inventory every
product-record declaration under `keiro-dsl/src` and `keiro-dsl/app` and record, for each field, its
owning type, current name, target semantic name, strictness, deriving strategy, and whether the
selector participates in a public API, JSON schema, pretty/diagnostic output, generated source, or
Generic-based behavior. Store the checked manifest in
`keiro-dsl/record-field-migration-0.8.md`; include unchanged fields so omissions are visible. Group
the work by module and flag any proposed target collision within one constructor. Capture exact JSON
goldens for every explicit report/workspace schema and compile the EP-172 public probe before the
first rename.

Audit the module graph at the same time. Record every current or proposed
`Data.Generics.Labels ()` import and every module whose transitive clients import Keiki. The safe
default for library code is record construction and pattern matching with field puns. Only if a
leaf is proven isolated may it import `Data.Generics.Labels ()` and use `#field`; never add that
import to a shared prelude or a type-definition module. If any production module uses generic-lens,
add `OverloadedLabels`, `generic-lens >=2.3 && <2.4`, and `lens >=5.3 && <5.4` only to the Cabal
component that imports them. These bounds cover the registry-verified current releases
generic-lens 2.3.0.0 and lens 5.3.6 and fit the repository's existing `<2.4`/`<5.4` bounds. Do not
add either dependency merely to define records.

Milestone 2 modernizes the central semantic and frontend-adjacent records. Start with
`Grammar.hs`, then `LanguageVersion.hs`, `SemanticContract.hs`, `Parser.hs`, `PrettyPrint.hs`, and
`Validate.hs`. Rename redundant selectors to shared semantic labels, add missing strictness, add
`Generic` where a product record lacks it, and make every deriving clause explicit. Keep
single-field newtype accessors such as `unLoc`. Preserve constructor names, field order, semantic
types, custom instances, `Loc` equality, and all `.keiro` parser/pretty behavior. Use construction
and matching with puns while migrating call sites; do not replace old prefixes with underscore
prefixes or datatype-qualified synonyms.

Milestone 3 applies the same manifest-driven conversion to `AggregateType.hs`,
`BehaviorCoverage.hs`, `CodecCompare.hs`, `Coverage.hs`, `Diff*.hs`, `EventOutput.hs`,
`ExplainBindings.hs`, `Expression.hs`, `Mapped*.hs`, `NominalType.hs`, `ReplayImpact.hs`,
`Scaffold*.hs`, `TypeGraph.hs`, `Workspace*.hs`, the remaining production modules, and
`app/Main.hs`. For event or command payload records, ensure the entity identifier is first; do not
misclassify grammar declarations named `Command` or `Event` as runtime payload data. Keep explicit
Aeson key strings stable. Keep generated domain records and their field order byte-identical; test
their already compliant output rather than rewriting templates for cosmetic differences.

Milestone 4 removes remaining uses of the old selectors from production and tests, then locks in
the result. Add a compile-only migration fixture that exercises representative new labels from
`Grammar`, `LanguageVersion`, workspace, reports, and CLI parsing. Add a second compile fixture that
imports the public `keiro-dsl` facade together with representative bare Keiki labels; it must compile
without an ambiguous `IsLabel` instance. Fail review if `Data.Generics.Labels` appears in a prelude,
definition module, generated module, or the transitive dependency report for that fixture.

Update `keiro-dsl/CHANGELOG.md` and package documentation with the 0.7-to-next-major selector map
and state that serialized and generated contracts did not change. Later EPs must use this plan's
names: `SourcePoint {offset, line, column}`, `SourceSpan {source, start, end}`, `Located {span,
value}`, `LanguageDefinition {version, predecessor, syntaxProfile, runtimeSemantics}`, and
`FrontendFailure {phase, code, span, message}`. Run the full EP-172 oracle after each module family;
an unexplained external difference blocks the milestone.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`. First capture the inventory and dependency context:

```bash
rg -n '^data |^newtype ' keiro-dsl/src keiro-dsl/app
rg -n '^ *[a-z][A-Za-z0-9_]* *::' keiro-dsl/src keiro-dsl/app
rg -n 'ToJSON|FromJSON|toJSON|parseJSON|\.=' keiro-dsl/src keiro-dsl/app
rg -n 'Data\.Generics\.Labels|^import .*Keiki|#[_A-Za-z]' keiro-dsl/src keiro-dsl/app keiro-dsl/test
```

Update `keiro-dsl/record-field-migration-0.8.md` from those results and review every row. During
each module-family conversion, run focused compilation and tests, followed by the frozen oracle:

```bash
cabal build keiro-dsl:lib:keiro-dsl keiro-dsl:exe:keiro-dsl
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='record conventions'
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='JSON contracts'
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='Keiki label isolation'
cabal test keiro-dsl-test --test-show-details=direct --test-option=--match --test-option='frontend 0.7 compatibility'
```

The expected result is zero missing migration rows, no changed external JSON or generated bytes,
and successful compilation of both the new-field fixture and the Keiki-label fixture. Finish with:

```bash
cabal test keiro-dsl-test --test-show-details=direct
cabal build all
nix flake check
```

Record exact record/field counts, the number of renamed selectors, any justified unchanged legacy
spelling, dependency changes, test counts, and the final public compile-probe result in this living
plan.


## Validation and Acceptance

Every production record row in the manifest must be accounted for. No remaining field may carry a
redundant owner prefix or abbreviation merely to avoid selector collisions; shared names compile
under `DuplicateRecordFields`. All product fields are strict, derivations use explicit strategies,
and records derive `Generic` unless the manifest records a concrete technical reason. Newtype
unwrap fields retain the `unTypeName` form. Entity IDs remain first in generated command/event data.

Representative downstream code compiles using the new public fields. The migration guide covers
every removed public selector and identifies the next PVP-breaking package version. The EP-172
oracle shows no change to source acceptance, semantic graph, canonical pretty output, diagnostic
text/codes, JSON keys, generated Haskell bytes, workspace records, diff/replay results, or CLI
output. JSON goldens compare decoded shape and exact encoded bytes wherever ordering is already a
pinned contract.

No prelude or record-definition module imports `Data.Generics.Labels`. A compile fixture importing
public Keiro DSL APIs and using representative Keiki `#label` expressions succeeds. Any allowed
generic-lens label import is listed in the migration manifest with evidence that it cannot enter
that fixture's transitive import closure. The plan is incomplete if new records in EP-173 or EP-175
reintroduce prefixes.


## Idempotence and Recovery

The work is a source refactor with no data migration. Apply it one module family at a time and keep
the migration manifest synchronized with compiling code. A partially converted module may be
completed by following its manifest rows; avoid compatibility aliases that make a half-converted
state look complete. If a rename changes a JSON golden, generated file, parser result, or rendered
diagnostic, restore the explicit external key/rendering at its encoder or renderer rather than
accepting a new baseline. If a generic-lens import breaks the Keiki fixture, remove the orphan
import and convert that module to construction/pattern matching before proceeding.

Do not regenerate or approve EP-172 expectations as part of recovery. Because the selector rename
is intentionally breaking, recovery means returning to a compiling module-family boundary, not
supporting both selector vocabularies indefinitely.


## Interfaces and Dependencies

The target naming model is:

```haskell
data IdDecl = IdDecl
  { name :: !Name
  , prefix :: !Text
  , binding :: !(Maybe NominalBindingDecl)
  , loc :: !Loc
  }
  deriving stock (Eq, Show, Generic)

data SourcePoint = SourcePoint
  { offset :: !Int
  , line :: !Int
  , column :: !Int
  }
  deriving stock (Eq, Show, Generic)

data Located a = Located
  { span :: !SourceSpan
  , value :: !a
  }
  deriving stock (Eq, Show, Generic)
```

Record construction and field-pun matching are valid in all modules and are the required fallback
where overloaded-label instance isolation cannot be proven. Direct selector calls and Haskell
record-update syntax should not be introduced merely to avoid the import-closure constraint.

The governing guide is:
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`
If isolated generic-lens access is used, its dependencies are:
`mori://ekmett/lens/packages/generic-lens`
`mori://ekmett/lens/packages/lens`
Add their verified bounds only to importing components. No dependency is required for `DuplicateRecordFields`, strict
fields, explicit deriving strategies, `Generic`, record construction, or field puns.


## Revision Note

2026-08-01: Cancelled the plan before implementation at the maintainer's direction. Its work was
removed from MasterPlan 28 and from EP-173 through EP-176 dependency assumptions.
