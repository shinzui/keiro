---
id: 157
slug: unify-aggregate-type-capabilities-and-lower-time-and-natural
title: "Unify aggregate type capabilities and lower Time and Natural"
kind: exec-plan
created_at: 2026-07-31T13:21:58Z
intention: "intention_01kyw51eekej8sxqepg5pc1s2s"
---

# Unify aggregate type capabilities and lower Time and Natural

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, an aggregate author can use `Time` and `Natural` directly in command
fields, event fields, and registers, run `keiro-dsl check`, scaffold the service, and compile
and exercise the generated code without hand-editing generated modules. A timestamp such as
`2026-01-02T03:04:05.123456789012Z` retains its sub-second precision through JSON and replay,
and a natural number accepts zero and positive values while rejecting negative and fractional
JSON. Equality and ordering guards over both types are checked through Keiki, while arithmetic
over `Natural` remains deliberately outside the DSL.

The larger gain is one checked aggregate-type model. Today parsing, semantic validation,
Haskell type rendering, imports, Cabal dependencies, register initial values, deterministic
samples, codecs, snapshots, fingerprints, diffs, and scaffold refusals answer type-support
questions independently. The implementation will resolve a source type once, attach explicit
capabilities for each aggregate use site, and make every later consumer use that resolution.
The compiled aggregate-scalar conformance suite will demonstrate the result end to end.

This work had an external release gate, and that gate passed on 2026-07-31. Hackage's
preferred-version metadata now lists `0.5.0.0` for both `keiki` and `keiki-codec-json`, matching the
upstream `v0.5.0.0` tag. The tagged source contains the required Natural symbolic equality and
ordering support, non-negative solver-domain constraint, deliberate omission from symbolic numeric
arithmetic, and canonical type name. Implementation can begin with the release preflight in
Milestone 1 and must use the released packages rather than a sibling checkout.


## Progress

- [x] Release prerequisite — Keiki and keiki-codec-json `0.5.0.0` appeared in Hackage's
  preferred-version metadata and Keiki's upstream `v0.5.0.0` tag was verified on 2026-07-31.
- [x] Milestone 1 (resolver checkpoint) — On 2026-07-31, re-ran the release preflight, committed
  the Keiki `0.5` dependency floor, introduced the canonical aggregate-type and capability
  resolver, and changed aggregate fields and registers to parse `TypeExpr` with source locations.
- [x] Milestone 1 (remaining) — On 2026-07-31, pinned the five append-only aggregate diagnostic
  codes plus the localized arithmetic parser error with positive, negative, alias, and exact-row
  tests; both focused test groups pass.
- [x] Milestone 2 (lowering checkpoint) — On 2026-07-31, threaded resolved types through the
  library's generated domain, codec, snapshot, golden, harness, fingerprint, replay-impact, diff,
  refusal, and workspace paths; `cabal build lib:keiro-dsl` succeeds.
- [x] Milestone 2 (remaining) — On 2026-07-31, proved type-directed minimal imports and packages,
  byte-identical repeated scaffolds, and absence of generated `error`, `read`, runtime ISO-8601
  parsing, and ambient clock access; the complete `keiro-dsl-test` regression suite passes.
- [x] Milestone 3 — On 2026-07-31, added total explicit `Time` and `Natural` register initials and
  the compiled `keiro-dsl-conformance-aggregate-scalars` suite. All 16 Keiki, codec, snapshot,
  forward/replay, precision, rejection, canonical-name, and opaque-arithmetic assertions pass.
- [x] Milestone 4 — On 2026-07-31, added the exhaustive capability matrix, clean-spec QuickCheck
  property, negative and alias fixtures, one-member workspace parity, generated-tree freshness,
  and a restoring mutation test that turns exactly the dishonest Natural replay register red.
- [ ] Milestone 5 — Update authoring and user documentation, amend durable ADRs, add the
  changelog entry, and pass focused, full Cabal, Nix, and OKF validation.


## Surprises & Discoveries

- 2026-07-31: The formatter's standalone GHC parser did not inherit Cabal's `GHC2024` language
  defaults, so newly tracked conformance files containing the repository-standard postpositive
  qualified imports failed the pre-commit hook even though they compiled. Fourmolu now parses the
  whole repository with the same global `GHC2024` edition already declared by every Cabal common
  stanza, rather than copying an `ImportQualifiedPost` pragma into each generated module.

- 2026-07-31: Cabal 3.16 splits whitespace inside a single `--test-options` value before Hspec
  receives it, so the plan's literal `--match aggregate type capabilities` form was interpreted as
  three arguments. The equivalent whitespace-free regex forms
  `--match=aggregate.*type.*capabilities` and `--match=aggregate.*scalar.*diagnostics` select the
  intended groups and pass. The concrete commands below now use that reproducible form.

- 2026-07-31: An explicit `UTCTime` constructor is syntactically total but still needs parentheses
  when inserted as a generated constructor argument. Disposable scaffold inspection caught the
  missing grouping before the committed conformance tree; the central sample and initial renderers
  now emit parenthesized constructor expressions, and the compiled suite pins the result.

- 2026-07-31: Adding a source location to aggregate fields caused the generic workspace AST
  relocation traversal to fail compilation until `HasLocs AggregateField` was declared. This is a
  useful compile-time guard: composed-workspace diagnostics cannot silently retain member-local
  line numbers when the aggregate AST grows.

- 2026-07-31: The implementation preflight reproduced the published `0.5.0.0` packages and tag,
  but the first constrained `cabal build all` failed during dependency solving because the local
  Cabal index only knew `keiki-codec-json` through `0.4.0.0`. Hackage's live preferred-version
  endpoint already listed `0.5.0.0`, so this was a stale local package-index cache rather than a
  missing release. After `cabal update`, the exact constrained `cabal build all` completed against
  `keiki == 0.5.0.0` and `keiki-codec-json == 0.5.0.0` without source-compatibility changes.

- 2026-07-31: The Hackage upload completed while the plan was under readiness review. Both `keiki`
  and `keiki-codec-json` now list `0.5.0.0` in preferred-version metadata, and the matching tag
  resolves to commit `3250780cffa1397cb320ebae69a326ee7554685f`. Inspection of that tag confirms
  `Sym Natural`, ordered discovery, the non-negative domain constraint, omission from numeric
  discovery, and `CanonicalTypeName Natural = "Natural"`.

- 2026-07-31: Keiki's `0.5.0.0` PVP-major change adds `constrainSymDomain` to `Sym` with a default
  implementation and generalizes the `OpaqueGuard` detail text. Existing hand-written `Sym`
  instances remain source-compatible. Keiro renders `tvwDetail` without interpreting it and its
  validation tests use substring matching, so the release notes expose no additional migration
  blocker beyond updating bounds and running the planned build.


## Decision Log

- Decision: Treat the published Keiki Natural release as a hard implementation gate and require
  `keiki >=0.5 && <0.6`, rather than compiling against an unreleased sibling checkout.
  Rationale: Keiki `v0.5.0.0` is the Natural-capable release. Its upstream tag and Hackage package
  are now authoritative and agree, so Keiro can require and test the capability without relying on
  a sibling checkout.
  Date: 2026-07-31

- Decision: Declare EP-157 ready to implement now that the `0.5.0.0` release precondition is
  satisfied; retain the release commands as a repeatable Milestone 1 preflight.
  Rationale: The plan's design, files, interfaces, diagnostics, milestones, validation commands,
  recovery path, ADR constraints, and observable acceptance behaviors are specified, and the only
  external blocker has cleared. Re-running the preflight protects a fresh implementation session
  from transient registry or resolver inconsistencies.
  Date: 2026-07-31

- Decision: Add one aggregate-specific checked type model and make all validation and lowering
  consumers use it.
  Rationale: The defect is systemic drift between independent allowlists. A new isolated case in
  the scaffolder would make `Time` and `Natural` work temporarily without preventing the next
  type from failing elsewhere.
  Date: 2026-07-31

- Decision: Parse aggregate command/event fields and register types with the existing `TypeExpr`
  syntax, canonicalize both `Time` and `UTCTime` to `TTime`, but keep aggregate fields distinct
  from the generic `Field` used by process and router nodes.
  Rationale: `TypeExpr` already represents the built-ins and containers and already gives mapped
  declarations one grammar. A separate `AggregateField` prevents this work from silently
  expanding support for unrelated node kinds. Parsing a type does not imply that every aggregate
  use site supports it; the capability resolver makes that decision with a located diagnostic.
  Date: 2026-07-31

- Decision: Keep direct aggregate `Json`, `Optional`, `List`, and `Map` values unsupported; mapped
  structural declarations remain the aggregate boundary for those shapes.
  Rationale: The requested scalar support does not define direct container guard, snapshot,
  sampling, or compatibility semantics. Parsing these forms and rejecting them semantically
  produces a better diagnostic without inventing those semantics.
  Date: 2026-07-31

- Decision: Distinguish a type's legality at a use site from its Keiki visibility using
  `SolverVisible`, `OpaqueOnly`, and `Unsupported` capabilities.
  Rationale: Equality can be a legal aggregate operation without making every Haskell operation
  symbolically visible. Keiki deliberately omits `Natural` from its numeric symbolic registry
  because Haskell `Natural` subtraction throws `Underflow` for a negative mathematical result.
  The model must not infer arithmetic support from equality or ordering support.
  Date: 2026-07-31

- Decision: Make equality solver-visible for `Text`, `Int`, `Bool`, `Time`, and `Natural`, retain
  id/enum/vertex equality as `OpaqueOnly`, reject mapped equality, and make ordering
  solver-visible only for `Int`, `Time`, and `Natural`.
  Rationale: This is the exact registry exposed by released Keiki `0.5.0.0`; in particular Keiki
  does not claim ordered `Text`/`Bool`, mapped values have no single symbolic representation, and
  opaque nominal values remain legal whole values without claiming solver visibility.
  Date: 2026-07-31

- Decision: Keep semantic validation diagnostics on the repository's established exact-row `Loc`
  contract; pin the arithmetic syntax error to Megaparsec's exact line and column.
  Rationale: `Diagnostic` and the composed-workspace relocation protocol deliberately carry rows,
  while parser failures carry line and column. Expanding every persisted and workspace diagnostic
  location solely for these append-only aggregate codes would create a second location contract;
  the new field, register, and transition rows are precise within the existing semantic boundary.
  Date: 2026-07-31

- Decision: Accept quoted ISO-8601 values for `Time` register initials, parse them during checking,
  retain the resolved `UTCTime`, and emit explicit `UTCTime`/`fromGregorian`/
  `picosecondsToDiffTime` constructors. Accept only non-negative integral literals for `Natural`.
  Rationale: Generated production code must not contain `read`, `error`, ambient clock access, or
  runtime parsing for a value that the DSL can validate once. Constructor emission also preserves
  deterministic picosecond precision.
  Date: 2026-07-31

- Decision: Keep arithmetic syntax out of `Expr` and improve the parser's localized message for an
  arithmetic operator instead of adding an executable arithmetic node.
  Rationale: The request requires an early failure for Natural arithmetic, not a new arithmetic
  language. The existing expression grammar contains atoms, boolean operations, and comparisons
  only.
  Date: 2026-07-31

- Decision: Add a dedicated compiled `keiro-dsl-conformance-aggregate-scalars` suite rather than
  relying only on string-based scaffold tests.
  Rationale: The claimed behavior crosses Keiro DSL parsing, generated Haskell, Aeson, Keiro replay,
  and Keiki validation. Compilation and execution against the released dependencies are the
  shortest honest proof.
  Date: 2026-07-31

- Decision: Canonical resolved identities, not source aliases, feed diff, fold fingerprint,
  replay-impact, and any scaffold-record constraint. Do not bump the scaffold-record schema unless
  the implementation proves that new persisted information is necessary.
  Rationale: `Time` and `UTCTime` are source aliases, so they must not create compatibility churn.
  At the same time, a real resolved type or register-initial change must affect all relevant cache
  and compatibility identities.
  Date: 2026-07-31


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The triggering request is
`docs/improvement-requests/support-first-class-aggregate-time-and-natural-lowering.md` (IR-4).
Technical validation corrected one important premise: Haskell `Natural` subtraction does not
saturate at zero; it throws `Underflow` if the mathematical result is negative. IR-4 is otherwise
valid against the current repository. Its profile validation succeeds. Strict validation of the
whole improvement-request bundle still reports pre-existing missing review metadata in IR-2 and
IR-3; those unrelated records are not part of this plan.

The Keiro DSL library is in `keiro-dsl/`. `keiro-dsl/src/Keiro/Dsl/Grammar.hs` defines the parsed
syntax. Its `TypeExpr` already has `TText`, `TInt`, `TBool`, `TNatural`, `TTime`, `TJson`, references,
and container constructors, and the mapped-type parser already canonicalizes `Time` and `UTCTime`
to `TTime`. Direct aggregate declarations are less expressive: `RegDecl.regType` is a raw `Name`,
and command and event fields use the generic `Field` with `fieldType :: Maybe Name`.
`keiro-dsl/src/Keiro/Dsl/Parser.hs` therefore accepts only an identifier for those aggregate type
positions. Its `Expr` parser admits comparisons and boolean operators, not arithmetic.

`keiro-dsl/src/Keiro/Dsl/Validate.hs` is the earliest semantic boundary used by the `check` command.
It resolves mapped types and checks several guard rules, but has no single direct aggregate-type
resolution and no use-site capability model. It currently rejects `Natural` in mapped guard
handling even though Keiki `0.5.0.0` supports Natural equality and ordering. The
workspace implementation in `keiro-dsl/src/Keiro/Dsl/Workspace.hs` merges members and delegates to
`validateSpec`; preserving that seam keeps single-file and workspace behavior aligned.

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` currently performs its own field inference in `resolveAgg`.
A bare field first matches a register, then an ID, enum, or aggregate vertex, and otherwise falls
back to `Text`. `ResolvedCtor.rcFields` stores `(Text, Text)`, which loses the semantic distinction
between source tokens and resolved types. The module separately renders domain types, imports,
register initials, harness samples, and scaffold refusals. Unsupported paths can still emit
`error`; a clean validation result does not currently prove total lowering.

Other independent aggregate consumers are
`keiro-dsl/src/Keiro/Dsl/Goldens.hs`, which chooses JSON samples;
`keiro-dsl/src/Keiro/Dsl/Manifest.hs`, which chooses generated package dependencies;
`keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs`, which hashes raw register types and initials;
`keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs`, which assesses replay consequences;
`keiro-dsl/src/Keiro/Dsl/Diff.hs`, which compares raw optional field names; and
`keiro-dsl/src/Keiro/Dsl/ScaffoldRecord.hs`, which persists scaffold constraints. The generated
Domain, Codec, EventStream, Projection, ReplayAudit, Harness, and consumer-owned Holes modules all
need to agree with the same resolution. `keiro-dsl/test/Main.hs` contains unit, property, CLI, and
scaffold tests. Existing generated-code conformance suites live under `keiro-dsl/test/conformance*`
and are declared in `keiro-dsl/keiro-dsl.cabal`.

In this plan, a “use site” means a place where an aggregate type needs a specific capability: a
command field, event field, register, equality guard, ordering guard, register write, JSON codec,
snapshot, harness sample, Haskell import, or package dependency. A “resolved aggregate type” is the
canonical semantic result after applying explicit syntax and existing bare-field inference. A
“clean spec” is a parsed spec for which `validateSpec` returns no errors.

Dependency details were inspected through Mori at
`mori://shinzui/keiki/packages/keiki` and directly in the resolved Keiki source. The released
`v0.5.0.0` code
defines `Sym Natural` with an integer representation constrained to values greater than or equal to
zero, enables equality and ordering, uses the canonical type name `Natural`, and intentionally
does not claim numeric support. Its JSON codec accepts zero and positive integral values and rejects
negative and fractional values. Mori has no curated Keiki documentation or cross-repository ADR for
this feature, so there is no dependency ADR to cite. The implementation must re-run Mori lookup and
the authoritative release checks as its first preflight rather than relying on the current checkout.
Keiki's `0.5.0.0` changelog identifies two compatibility details: `Sym` gains
`constrainSymDomain` with a source-compatible default, and the human-readable `OpaqueGuard` detail
no longer names only `TApp`. Keiro's `keiro-core/src/Keiro/EventStream/Validate.hs` passes that
detail through and current tests assert warning substrings, so no separate API migration is known;
the post-bound-update build remains the proof.

The `time` source located through Mori supplies `Data.Time.Clock.UTCTime(..)`,
`Data.Time.Clock.picosecondsToDiffTime`, and `Data.Time.Format.ISO8601.iso8601ParseM`. The Aeson source
located through Mori supplies `ToJSON` and `FromJSON` instances for `UTCTime` and `Natural`; its
Natural decoder rejects negative and non-integral numbers. These APIs are the intended parser and
wire boundary. `keiro-dsl` already uses bounds `time >=1.12 && <1.15` elsewhere, so use that range
for the library and new conformance suite.

The following local decisions constrain the work. ADR
`docs/adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md` requires cached generated
artifacts to be discriminated by tool, DSL, and fold/shape identity, so canonical aggregate types
and resolved initials must influence the appropriate fold and shape components. ADR
`docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md` requires `check` to reject
unsound changes at the earliest boundary and requires append-only stable diagnostic codes. ADR
`docs/adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md` establishes
one resolved schema graph and total consumer lowering; the aggregate resolver extends that design
to direct aggregate types. ADR
`docs/adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md` requires
a one-member workspace to preserve single-spec validation semantics. Amend ADRs 0004 and 0012 if
the completed interfaces make the aggregate capability policy durable as expected. Amend ADR 0003
only if implementation changes its compatibility contract rather than merely satisfying it.


## Plan of Work

Milestone 1 re-verifies the released dependency and establishes one semantic authority. First verify the new
Keiki version with `mori registry show shinzui/keiki --full`, Hackage preferred versions, and
upstream tags. Read the released source through the Mori path and confirm the Natural `Sym`, shape,
domain, and JSON behavior described above. The readiness review confirmed `0.5.0.0`; stop only if
the fresh preflight cannot reproduce that result. Tighten every direct Keiki bound that exercises
the new behavior from `>=0.4 && <0.5` to
`>=0.5 && <0.6` in `keiro-core/keiro-core.cabal`, `keiro/keiro.cabal`,
`jitsurei/jitsurei.cabal`, the Keiki-dependent test components in `keiro-dsl/keiro-dsl.cabal`, and
`keiro-dsl/test/keiro-dsl-codec-compare-artifact-info.cabal`. Tighten `keiki-codec-json` where the
corresponding released codec capability is required. Keep the `keiro-dsl` library itself independent
of Keiki; only the compiled conformance components depend on it. Before aggregate implementation,
build all existing components with the new bounds. Treat an exhaustive-match failure or an exact
`OpaqueGuard` detail assertion as release migration work within this milestone and record it in
Surprises & Discoveries; do not loosen the bounds to bypass it.

Add the exposed module `keiro-dsl/src/Keiro/Dsl/AggregateType.hs`. It will resolve built-in
`Text`, `Int`, `Bool`, `Time`, and `Natural`; ID, enum, and aggregate-vertex names; and mapped
declarations. It will retain an explicit unsupported result for `Json` and containers at direct
aggregate use sites. Model capabilities separately for field storage, register storage, equality,
ordering, whole-value write, codec, snapshot, sample, Haskell lowering, and solver visibility.
Resolution must return either a canonical value or an error carrying the source location, use site,
and reason; downstream renderers must not re-resolve raw text.

In `Grammar.hs`, introduce an `AggregateField` with a field name, `Maybe TypeExpr`, and source
location. Use it only for aggregate command and event constructors. Change `RegDecl.regType` from
`Name` to `TypeExpr`; retain the original source location and initial token needed for diagnostics.
In `Parser.hs`, add aggregate-specific field and register parsers that reuse the complete
`TypeExpr` parser. In the pretty printer, emit the canonical spelling `Time`. Preserve existing
bare-field inference by placing it in `AggregateType`, not in parser or scaffolder code. Add a
targeted, located parser failure when `+`, `-`, `*`, or `/` appears in an aggregate expression; do
not add an arithmetic constructor to `Expr`.

In `Validate.hs`, build resolved aggregate schemas after symbol resolution and before individual
guard and write checks. Append stable `DiagnosticCode` constructors for an unknown aggregate type,
an unsupported type/use-site pair, an invalid register initial, a guard operand mismatch, and an
unsupported guard capability. Suggested names are `AggregateTypeUnknown`,
`AggregateTypeUnsupportedAtUse`, `AggregateRegisterInitialInvalid`,
`AggregateGuardTypeMismatch`, and `AggregateGuardCapabilityUnsupported`; retain different names only
if they better fit the existing diagnostic vocabulary. Report them at the type, initial, operand,
or operator location. Make `validateSpec` the only gateway to a lowering-ready resolved aggregate.
The same function continues to serve merged workspaces through `checkWorkspace`.

Milestone 1 is complete when direct `Time` and `Natural` fields and valid registers pass `check`,
`Time` and `UTCTime` pretty-print identically, and unknown types, direct containers/Json, negative or
malformed initials, mismatched comparisons, and unsupported comparison capabilities produce stable
located errors. The focused resolver and CLI tests must pass without invoking scaffold generation.

Milestone 2 makes lowering total. Change `ResolvedAggregate`, `ResolvedCtor`, and the resolved
register representation in `Scaffold.hs` to carry `ResolvedAggregateType` rather than raw `Text`.
Move or delegate Haskell type names, imports, package dependencies, deterministic sample values,
JSON values, register initial expressions, and Keiki capability claims to total functions in
`AggregateType`. Emit `Numeric.Natural (Natural)` only when needed. Emit
`Data.Time.Calendar (fromGregorian)` and
`Data.Time.Clock (UTCTime(..), picosecondsToDiffTime)` only when needed. Add `time` to the generated
aggregate manifest only when a resolved aggregate surface uses `Time`; `Natural` requires only
`base`. Preserve the existing generated-module ownership and banner behavior.

Update Domain, Codec, EventStream, Projection, ReplayAudit, Harness, and Holes rendering to consume
the resolved model. Update `Goldens.hs` to derive JSON samples from it. A stable Time sample is
`2026-01-02T03:04:05.123456789012Z`; Natural samples include zero and a positive integer. Delete all
aggregate-type branches that can emit `error` for a clean spec. `scaffoldRefusals` may retain
defensive checks for invalid internal states, but add a property proving they cannot report an
aggregate type refusal after clean validation.

Update `Manifest.hs`, `FoldFingerprint.hs`, `ReplayImpact.hs`, and `Diff.hs` to use canonical
resolved identities. `Time` and `UTCTime` must produce the same pretty output, fingerprint, shape,
and diff classification. A real scalar type or resolved register-initial change must produce the
same compatibility/replay consequences as the equivalent already-supported scalar change. Audit
`ScaffoldRecord.hs`; record only canonical names if a new constraint is truly necessary, and avoid a
record schema bump if the current record already captures the relevant generated artifacts.

Milestone 2 is complete when scaffolding the positive fixture produces total, deterministic Haskell
with exactly the needed imports and manifest dependencies, contains no `error`, `read`, or ambient
clock call, and repeated scaffolding is byte-identical. Unit tests must enumerate generated surface
consumers rather than checking only the Domain module.

Milestone 3 proves the feature against released Keiki. Add
`keiro-dsl/test/fixtures/aggregate-scalars.keiro` with direct Time and Natural command/event fields,
valid Time and Natural registers, equality and ordering guards, and transitions that emit and store
both values. Add checked-in generated modules under
`keiro-dsl/test/conformance-aggregate-scalars/Generated/` and a hand-owned Holes module under the
same conformance tree. The hand-written transducer must copy the command timestamp and revision into
the event and registers so that forward state and replay state can be compared honestly.

Declare `keiro-dsl-conformance-aggregate-scalars` in `keiro-dsl/keiro-dsl.cabal`. It depends on the
released Keiki version, Keiro, Aeson, text, time, and other packages actually imported by generated
code. Its executable assertions cover Keiki validator acceptance, equality and ordering guard
behavior, forward/replay equality, snapshots, Aeson round trips, the pinned sub-second timestamp,
Natural zero and positive values, rejection of negative and fractional Natural JSON, and Keiki's
canonical Natural name. Add an opaque-audit assertion showing that attempted Natural arithmetic is
not symbolically supported. Pin the checked-in generated tree byte-for-byte to fresh scaffold
output in `keiro-dsl-test`.

Milestone 3 is complete only when the dedicated conformance suite compiles against the released
packages and passes. Passing against the local Keiki checkout is not acceptable evidence.

Milestone 4 closes drift paths. In `keiro-dsl/test/Main.hs`, add a table-driven test that enumerates
every `ResolvedAggregateType` and every `AggregateUseSite`, asserting the expected capability. For
each supported pair, require total Haskell type, import, package, codec/snapshot, and deterministic
sample lowering as applicable. Add a QuickCheck property stating that a clean aggregate spec never
produces `FieldTypeUnrepresentable`, `RegTypeUnsupported`, or another aggregate type scaffold
refusal. Keep internal total functions non-exported where possible, but expose enough typed data to
test the policy without parsing rendered Haskell.

Add negative fixtures for unknown names, direct Json and containers, negative Natural initials,
malformed and out-of-range Time initials, cross-type comparisons, unsupported ordering, and
arithmetic syntax. Assert exact diagnostic codes, file names, line/column locations, and short
remediation text. Add a one-member workspace fixture and prove it reports exactly the same semantic
diagnostics as the single file. Add alias tests proving `Time`/`UTCTime` equivalence across parse,
pretty-print, diff, and fold fingerprint. Extend the existing replay mutation approach so a changed
timestamp or revision in the hand-owned transducer makes the replay assertion fail; restore the
honest implementation after the test.

Milestone 4 is complete when every capability has a policy test, every requested refusal is
localized, and mutation tests demonstrate that the new conformance assertions fail for dishonest
code rather than passing vacuously.

Milestone 5 documents and validates the contract. Update
`agents/skills/keiro-dsl-authoring/NOTATION.md` with direct scalar syntax, inference, initial-value
examples, canonical `Time` spelling, and the direct Json/container boundary. Update
`docs/user/typed-spec-toolchain.md` with the end-to-end behavior and diagnostics. Update
`keiro-dsl/CHANGELOG.md`. Amend ADR 0012 with the aggregate resolved-capability authority and ADR
0004 with earliest-boundary aggregate diagnostics if implementation confirms those durable choices;
update their ADR bundle log as required by the profile. Record unexpected compatibility decisions in
the appropriate ADR rather than only in this plan.

Milestone 5 is complete when all focused and full tests pass, generated trees are fresh, `nix flake
check` succeeds, the relevant ADR bundle validates strictly, the improvement-request bundle validates
with profile enforcement, and `git diff --check` reports no formatting errors.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/keiro` unless a command explicitly changes
directory. At the start of implementation, re-establish dependency locations through Mori and stop
if the authoritative registries do not show the release:

```bash
mori registry list
mori registry search keiki
mori registry show shinzui/keiki --full
curl -fsSL https://hackage.haskell.org/package/keiki/preferred.json
git ls-remote --tags https://github.com/shinzui/keiki.git
```

The relevant output must contain the actual Natural-capable version in Hackage's `normal-version`
list and a matching `refs/tags/v<version>` entry. For the expected release, the short comparison is:

```text
Hackage preferred versions: ... "0.5.0.0" ...
Git tags:                    ... refs/tags/v0.5.0.0
```

This comparison passed during readiness review on 2026-07-31 for both `keiki` and
`keiki-codec-json`. The commands remain here so implementation begins from reproducible evidence.

If Hackage does not yet include `0.5.0.0`, or if the matching tag is absent, do not update Keiro
dependency bounds or mark Milestone 1 complete. Once published, inspect the released checkout
resolved by Mori. After updating all direct bounds, prove the existing workspace accepts the PVP
major release before adding aggregate behavior:

```bash
cabal build all \
  --constraint='keiki == 0.5.0.0' \
  --constraint='keiki-codec-json == 0.5.0.0'
```

Expected output ends with successful builds for the existing Keiro packages and test components.
Then run the new focused unit tests as they are added:

```bash
cabal test keiro-dsl-test \
  --test-options='--match=aggregate.*type.*capabilities' \
  --test-show-details=direct
cabal test keiro-dsl-test \
  --test-options='--match=aggregate.*scalar.*diagnostics' \
  --test-show-details=direct
```

Both commands should end with zero failures. Exercise the positive CLI boundary directly:

```bash
cabal run -v0 keiro-dsl -- \
  check keiro-dsl/test/fixtures/aggregate-scalars.keiro
```

Expected output is:

```text
OK
```

Exercise the negative fixture separately. The final fixture name may be split by failure family if
that gives clearer source locations, but each invocation must exit non-zero:

```bash
cabal run -v0 keiro-dsl -- \
  check keiro-dsl/test/fixtures/aggregate-scalars-unsupported.keiro
```

Expected output contains the stable codes and their exact locations, with no Haskell exception:

```text
... AggregateTypeUnsupportedAtUse ... Json ... aggregate field ...
... AggregateRegisterInitialInvalid ... Natural ... non-negative integer ...
... AggregateRegisterInitialInvalid ... Time ... ISO-8601 ...
... AggregateGuardTypeMismatch ...
```

Scaffold to a disposable directory and inspect the generated result. `mktemp -d` makes retries safe:

```bash
scalar_out="$(mktemp -d)"
cabal run -v0 keiro-dsl -- \
  scaffold keiro-dsl/test/fixtures/aggregate-scalars.keiro \
  --out "$scalar_out"
rg -n 'UTCTime|picosecondsToDiffTime|Natural|error|read|getCurrentTime' "$scalar_out"
```

The matches must show `UTCTime`, `picosecondsToDiffTime`, and `Natural` in the expected generated
types and imports. There must be no generated `error`, `read`, or `getCurrentTime` match. Scaffold a
second time and compare the trees:

```bash
scalar_out_again="$(mktemp -d)"
cabal run -v0 keiro-dsl -- \
  scaffold keiro-dsl/test/fixtures/aggregate-scalars.keiro \
  --out "$scalar_out_again"
diff -ru "$scalar_out" "$scalar_out_again"
```

Expected output is empty. Run the compiled proof and the generated-tree freshness test:

```bash
cabal test keiro-dsl-conformance-aggregate-scalars \
  --test-show-details=direct
cabal test keiro-dsl-test \
  --test-options='--match aggregate scalar scaffold conformance' \
  --test-show-details=direct
```

The conformance transcript should explicitly report successful Keiki validation, forward/replay
equality, Time and Natural codec round trips, precise Time golden equality, invalid Natural JSON
rejection, and Natural canonical-name equality before exiting successfully.

Run the focused compatibility and workspace tests after Milestone 4:

```bash
cabal test keiro-dsl-test \
  --test-options='--match aggregate scalar' \
  --test-show-details=direct
```

Before completion, validate the entire repository and document bundles:

```bash
cabal build all
cabal test all --test-show-details=direct
nix flake check
okf validate docs/improvement-requests \
  --profile mori/improvement-requests-profile.dhall \
  --profile-enforce --log-enforce
okf validate docs/adr --strict \
  --profile docs/adr/profile.dhall \
  --profile-enforce --log-enforce
git diff --check
```

All commands must exit zero. The improvement-request command is intentionally non-strict because
IR-2 and IR-3 currently lack profile-recommended reviews; do not silently edit those unrelated
records as part of this plan. If that pre-existing debt is resolved before implementation, add
`--strict` and record the change here.

Every implementation commit made from this plan must use a Conventional Commit message and include
both trailers:

```text
ExecPlan: docs/plans/157-unify-aggregate-type-capabilities-and-lower-time-and-natural.md
Intention: intention_01kyw51eekej8sxqepg5pc1s2s
```


## Validation and Acceptance

Acceptance is behavioral, not merely a successful build. A spec with a command and event containing
explicit `Time` and `Natural` fields passes `check`, pretty-prints `UTCTime` as canonical `Time`, and
scaffolds Haskell fields of type `UTCTime` and `Natural`. An otherwise identical bare field still
uses the existing register/ID/enum/vertex inference and finally falls back to `Text`; moving that
policy into the resolver must not change its result.

A `Time` register initialized from `"2026-01-02T03:04:05.123456789012Z"` and a `Natural` register
initialized with `0` pass checking and compile without partial generated code. The generated Time
expression is an explicit `UTCTime` value with picosecond `DiffTime`, and the generated Natural
expression is a total numeric literal. Malformed Time text, a negative Natural, or a fractional
Natural fails at the initial token with `AggregateRegisterInitialInvalid` or its final documented
equivalent.

The positive conformance transducer copies both scalar values from a command into an emitted event
and its registers. Keiki accepts equality and ordering guards for both types. Forward execution and
replay produce equal final registers. Snapshot encode/decode and event codec round trips retain the
timestamp exactly and retain Natural zero and positive values. Decoding Natural from negative or
fractional JSON fails. Keiki reports the canonical type name `Natural`.

Writing an arithmetic expression involving a Natural fails in `check` at the arithmetic operator
with a message explaining that aggregate arithmetic is unsupported; it never reaches scaffolding.
The Keiki opaque-audit conformance assertion independently proves that the dependency does not
claim symbolic Natural arithmetic. This behavior must not be described as saturating subtraction.

Direct aggregate `Json`, `Optional`, `List`, and `Map` syntax parses far enough to report a stable
type/use-site diagnostic and remediation toward a mapped structural declaration. An unknown type,
a comparison between different resolved types, and an ordering comparison on a type without that
capability each report their own stable code and exact source location. A clean spec never reaches
an aggregate type scaffold refusal.

Generated imports and packages are minimal and deterministic: Time introduces `time` and the
required calendar/clock imports, Natural introduces `Numeric.Natural` but no non-base package, and a
spec using neither remains unchanged. There is no `error`, `read`, current-clock access, or runtime
ISO-8601 parsing in generated production modules. Two scaffold runs from the same input are
byte-identical.

`Time` and `UTCTime` are aliases for parsing, rendering, diff, replay impact, and fingerprinting. A
real type or initial-value change is visible to compatibility and cache identities according to the
existing snapshot ADR. A one-member workspace produces the same diagnostics and generated aggregate
meaning as its single-file spec.

Finally, the dedicated conformance suite must compile and run against the published Keiki version,
all repository tests and `nix flake check` must pass, generated fixtures must match fresh scaffold
output, and the updated ADR and improvement-request bundles must satisfy their stated validation
commands.


## Idempotence and Recovery

Mori lookup, registry checks, builds, tests, `check`, OKF validation, and scaffolding into a fresh
`mktemp -d` directory are read-only or repeatable. The scaffold command must never target the
hand-owned conformance tree until the disposable output has compiled and its diff has been reviewed.
Regenerate only generated-banner files; preserve Holes modules and other consumer-owned files.

If a fresh release preflight cannot fetch Keiki `0.5.0.0`, stop before changing dependency bounds and
diagnose the package-index or network state. The release was verified on 2026-07-31, so a later miss
is a transient environment problem rather than permission to fall back to a sibling checkout.

If a parser/AST migration causes broad failures, keep the change mechanical first: introduce
`AggregateField`, convert aggregate-only accessors, and preserve old semantics through the resolver
before enabling Time or Natural. This gives a testable checkpoint and avoids mixing representation
errors with capability changes. If a lowering consumer lacks enough semantic data, extend the
resolved model; do not restore a raw-name allowlist in that consumer.

Generated conformance modules are recoverable from the fixture and scaffold command. When a mutation
test intentionally corrupts hand-owned behavior, arrange the test script to restore the exact file
on exit and verify `git diff --check` afterward. Do not use destructive Git reset or checkout to
recover; inspect the diff and apply a narrow patch.


## Interfaces and Dependencies

The implementation should provide an aggregate authority equivalent to the following interface in
`Keiro.Dsl.AggregateType`. Exact constructor names may follow repository style, but the separation
between source syntax, canonical type, use site, capability, and lowering must remain:

```haskell
data AggregateUseSite
  = CommandFieldUse
  | EventFieldUse
  | RegisterUse
  | EqualityGuardUse
  | OrderingGuardUse
  | WholeValueWriteUse
  | CodecUse
  | SnapshotUse
  | HarnessSampleUse

data SolverVisibility
  = SolverVisible
  | OpaqueOnly
  | Unsupported

data ResolvedAggregateType
  = AggregateText
  | AggregateInt
  | AggregateBool
  | AggregateTime
  | AggregateNatural
  | AggregateId Name
  | AggregateEnum Name
  | AggregateVertex Name
  | AggregateMapped MappedKey

resolveAggregateType
  :: AggregateSymbols
  -> AggregateUseSite
  -> TypeExpr
  -> Either AggregateTypeError ResolvedAggregateType

inferAggregateFieldType
  :: AggregateSymbols
  -> Aggregate
  -> AggregateField
  -> Either AggregateTypeError ResolvedAggregateType

aggregateCapability
  :: AggregateUseSite
  -> ResolvedAggregateType
  -> AggregateCapability

aggregateHaskellType :: ResolvedAggregateType -> Text
aggregateImports :: ResolvedAggregateType -> Set HaskellImport
aggregatePackages :: ResolvedAggregateType -> Set PackageName
aggregateSample :: ResolvedAggregateType -> TotalSample
```

Register resolution also needs a typed value so validation and rendering cannot disagree:

```haskell
data ResolvedRegisterInitial
  = InitialText Text
  | InitialInt Integer
  | InitialBool Bool
  | InitialTime UTCTime
  | InitialNatural Natural
  | InitialNamed ResolvedAggregateType Text

resolveRegisterInitial
  :: ResolvedAggregateType
  -> Located InitialSyntax
  -> Either AggregateTypeError ResolvedRegisterInitial

renderRegisterInitial
  :: ResolvedRegisterInitial
  -> Text
```

If IDs, enums, vertices, or mapped declarations already have richer resolved value types, reuse
those instead of the illustrative `InitialNamed` constructor. The required invariant is that
`renderRegisterInitial` is total over values admitted by `resolveRegisterInitial` and has no
fallback that emits `error`.

`ResolvedCtor` and resolved registers in `Scaffold.hs` must carry these types directly. Renderers,
Goldens, Manifest, FoldFingerprint, ReplayImpact, Diff, and ScaffoldRecord consume canonical
accessors from this model. None may match raw strings such as `"Time"`, `"UTCTime"`, or
`"Natural"` to decide support.

The direct dependencies are `time >=1.12 && <1.15` for parsing and constructor-level `UTCTime`
lowering; `aeson >=2.2 && <2.3` for the existing wire boundary and its released `UTCTime`/`Natural`
instances; and the newly released Keiki floor, `keiki >=0.5 && <0.6`, for compiled
symbolic conformance. Use `keiki-codec-json` at the corresponding release floor wherever its
Natural codec instance is directly required. Confirm all APIs in source paths returned by Mori and
confirm release versions against Hackage and upstream tags before editing bounds.


## Revision Note

2026-07-31: Marked the external release prerequisite complete after Hackage listed `keiki` and
`keiki-codec-json` `0.5.0.0`, verified the matching upstream tag and its Natural implementation, and
updated every release-gate reference. Reviewed the release's PVP-major compatibility notes and
added their bound-update build check to Milestone 1. The plan is now ready for implementation; the
same release checks remain as a repeatable preflight.
