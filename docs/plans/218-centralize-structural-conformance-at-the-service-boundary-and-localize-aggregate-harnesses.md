---
id: 218
slug: centralize-structural-conformance-at-the-service-boundary-and-localize-aggregate-harnesses
title: "Centralize structural conformance at the service boundary and localize aggregate harnesses"
kind: exec-plan
created_at: 2026-08-09T19:29:29Z
intention: "intention_01kzkzswbae5dan7x42gx8fv1c"
master_plan: "docs/masterplans/34-make-keiro-dsl-regeneration-semantically-local-and-source-stable-before-wide-adoption.md"
---

# Centralize structural conformance at the service boundary and localize aggregate harnesses

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, a mapped declaration has one generated home for declaration-wide conformance,
while each aggregate harness contains only evidence for declarations in that aggregate's checked
semantic closure. Adding an optional field used only by Aggregate A changes A's use-specific
codec assertions and one context `StructuralConformance` module; Aggregate B's generated files are
byte-identical. Running the service conformance facade still exercises every binding law, fixture
branch, opaque boundary, and structural projection exactly once.

This is an output-affecting refactor with a one-time regeneration cost. It must preserve every
wire, fold, snapshot, behavior-key, and runtime semantic identity and must make the existing
structural mutation suite fail through the new service-owned checks.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1: generate one context-level structural-conformance module from EP-1's service
  inventory and integrate it into scaffold planning and build manifests.
- [x] Milestone 2: make aggregate harness imports and declaration helpers follow only the checked
  aggregate closure while retaining use-specific codec/replay evidence.
- [x] Milestone 3: run service structural checks exactly once through the runtime-owned facade and
  update compiled conformance fixtures and restoring mutations.
- [x] Milestone 4: publish the ownership boundary in ADRs and user guidance and pass focused/full
  validation without performing the final whole-corpus refresh.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The original EP-1 semantic-impact fixture intentionally omits complete transition surfaces, so
  it is valid evidence for checked graph projections but cannot pass the scaffold lowering gate.
  A dedicated, complete two-aggregate workspace fixture now exercises generated-tree locality.

- The existing structural mutation suite did not need new mutations. After regeneration, its
  binding transpose, wrong union binding, and missing union fixture fail under the new
  `structural/` context prefix, while event omission continues to fail in the aggregate harness.
  The script's existing trap restores the baseline after every path.

- Adding the context module makes every mapped corpus target's generated-module inventory grow by
  one before the final corpus refresh. `ConformanceBaseline` temporarily excludes only
  `StructuralConformance.hs` from the legacy inventory comparison; Plan 222 removes that
  transition after it performs the policy-selected corpus regeneration.

- The structural fixture proves the full binding and opaque surface, while the scalar-expression
  fixture caught a distinct generated-import requirement for structural-only declarations. Both
  focused trees were regenerated here so the new context renderer is compiled across those two
  representative shapes without refreshing unrelated corpus targets.


## Decision Log

Record every decision made while working on the plan.

- Decision: Put declaration-wide laws in a dedicated context module, not in an arbitrary owner
  aggregate.
  Rationale: A declaration may be shared or unused. Selecting one aggregate would make that
  aggregate churn for unrelated schema edits and would make ownership change when uses move.
  Date: 2026-08-09

- Decision: Keep event codec/wire-policy and forward-versus-replay evidence in every aggregate
  whose semantic use requires it.
  Rationale: Those checks exercise aggregate-specific generated codecs and transition/register
  behavior. Deduplicating them at declaration scope would lose use-site evidence.
  Date: 2026-08-09

- Decision: Emit `StructuralConformance` whenever checked mapped declarations exist, independent
  of whether the optional runnable conformance package is configured.
  Rationale: Module generation and build inventory must remain truthful for standalone users; the
  service facade and optional package provide execution wiring without controlling whether the
  evidence exists.
  Date: 2026-08-09

- Decision: Reserve `StructuralConformance` as the deterministic facade import alias and allocate
  a suffixed alias if an aggregate has the same generated occurrence.
  Rationale: The service-owned gate must be imported exactly once without reintroducing an
  import-order or node-name collision.
  Date: 2026-08-09

- Decision: Normalize only the new context module out of the legacy corpus inventory assertion
  until Plan 222 performs the single coordinated corpus refresh.
  Rationale: This plan must compile focused generated evidence without creating the repeated
  whole-corpus churn that the MasterPlan assigns exclusively to its final qualification plan.
  Date: 2026-08-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Completed on 2026-08-09. `Keiro.Dsl.StructuralConformance` now renders one context-level module
from the checked service inventory. It owns binding shape/domain laws, canonical identity,
fixture-label and branch coverage, opaque codec fixtures, and structural projection witness
agreement. Aggregate harnesses consume only `aggregateMappedClosure` and retain their local event
codec/wire-policy, register replay, and expression evidence. The service facade imports and runs
the context assertions once under `structural/`, outside the review-owned facts baseline.

The two-aggregate locality fixture proves an Alpha-only optional-field edit changes the context
module and Alpha artifacts while every Beta artifact remains byte-identical. The public CLI
no-write regression rejects a missing fixture before creating output. The existing structural
mutation suite still turns red for all four mutations and restores its baseline. Repeating both
focused scaffold invocations produced an identical Git diff hash.

Validation passed with `cabal build all`, the full `keiro-dsl:tests` target (623 examples, zero
failures), the compiled structural and scalar-expression conformance targets, the restoring
structural mutation script, generated extension/name policy checks, strict ADR validation, and
`git diff --check`. The deliberate gap is the complete policy-selected 35-invocation generated
corpus refresh; Plan 222 owns that one-time migration and removal of the temporary inventory
normalization.


## Context and Orientation

This plan hard-depends on
[Plan 217](217-define-one-checked-semantic-impact-model-for-keiro-dsl-consumers.md), which exposes
the checked aggregate closures and service declaration inventory. Do not start by adding another
filter in the harness generator.

`keiro-dsl/src/Keiro/Dsl/Harness.hs` emits one aggregate `Harness` module. Its
`mappedHarnessDeclarationsResolved` currently returns all `tgDeclarations`; its
`mappedProjectionSpecs` returns every structural projection. The resulting
`mappedConformanceAssertions` mixes two scopes:

- declaration-wide binding round trips, canonical identity, fixture-label validity, branch
  coverage, opaque codec fixture checks, and structural projection witness agreement; and
- aggregate-use evidence such as mapped event round trips, generated aggregate codec missing/null/
  unknown-field policy, register forward/replay equality, and expression projection behavior.

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` plans context-level shape and
`StructuralProjections` modules and aggregate rings. `scaffoldServiceFor` and the workspace planner
are the correct places to add one new context module to the complete pre-write module set.
`keiro-dsl/src/Keiro/Dsl/ServiceHarness.hs` generates `<context>.Conformance`, the one runtime-owned
facade imported by `keiro-dsl/src/Keiro/Dsl/ConformancePackage.hs`. Today it imports aggregate and
read-model harnesses for executable checks and process/router/workflow harnesses for facts.

The representative compiled fixture is `keiro-dsl/test/conformance-structural`. Its generated
aggregate harness currently owns the structural assertions, and
`keiro-dsl/test/structural-mutation-test.sh` proves a transposed binding, a wrong union binding, a
missing union arm, and an omitted event value turn the gate red. This plan relocates the first
three declaration-law failures to the context module while keeping the aggregate event omission
red through its use-specific path.

[ADR 0012](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
defines all required laws and finite-evidence limits. [ADR 0015](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
requires context modules to have context-level provenance and generated-file idempotence.
[ADR 0020](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md) requires one
facade and one optional package, not a package per aggregate. [ADR 0019](../adr/0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md)
governs generated imports, language edition, and warning-free output. EP-1 records the new
semantic-impact authority. No cross-repository dependency or ADR changes this ownership boundary.


## Plan of Work

Milestone 1 extracts declaration conformance into a generator-owned source module,
`keiro-dsl/src/Keiro/Dsl/StructuralConformance.hs`, and lists it in
`keiro-dsl/keiro-dsl.cabal`. Given `Context` and `CheckedService`, resolve the checked graph once,
consume `serviceMappedInventory`, and emit
`<context generated prefix>.StructuralConformance`. The generated module exports
`structuralConformanceAssertions :: [(String, Bool)]`. Move binding round trips, canonical type
identity, fixture-label validity, structural branch/optional coverage, opaque fixture round trips,
and projection witness agreement into this renderer. Reuse the existing Haskell import planner;
do not duplicate qualified-name or collision logic. Empty mapped inventory emits no module.

Add the module to single and workspace scaffold plans before collision/import-cycle checks and
give it context-level workspace provenance. Build fragments and ledgers must list it like every
other generated module. Missing binding/fixture facts still fail through `checkMappedDecl` before
planning; add a no-write regression at the public CLI boundary.

Milestone 2 rewrites `Harness.hs` around EP-1's `aggregateMappedClosure`. Replace the global
`mappedHarnessDeclarationsResolved` and `mappedProjectionSpecs` behavior with local declarations
needed to construct samples, compile mapped fields, or exercise aggregate expressions. Keep
`mappedEventAssertionDecl`, aggregate codec wire-policy assertions, snapshot/register round trips,
and forward/replay checks in each relevant harness. Remove declaration-law exports and imports
from aggregate harnesses. An aggregate with no mapped closure must not import consumer binding,
shape, `StructuralProjections`, Aeson wire-policy helpers, or structural codec law helpers merely
because another aggregate uses them.

Milestone 3 extends `Keiro.Dsl.ServiceHarness`. When the service inventory is non-empty, import
`StructuralConformance` once under a deterministic reserved alias and prepend its assertions under
the stable `structural/` key prefix to `runServiceConformanceChecks`. Do not put these values in the
review-owned facts baseline. The optional conformance package continues to import only the facade.
Update `conformance-structural/Main.hs`, its Cabal module inventory, generated fixtures, and the
restoring mutation script. Add a two-aggregate workspace fixture proving declaration-law labels
occur once, Aggregate A retains its use checks, and every Aggregate B generated byte stays equal
when an A-only structural field changes.

Milestone 4 updates ADR 0012 and ADR 0020, or creates one focused successor ADR, with the durable
declaration-versus-use ownership rule. Update the typed-spec guide and changelog with the one-time
regeneration and the requirement to run service structural checks. Refresh only focused fixtures
owned by this plan; EP-6 owns the final live policy-selected 35-invocation corpus regeneration
after every emitter has settled. Run generated-name, extension, warning, and full package tests.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
```

Inventory the current assertion scopes and dependency source before editing:

```bash
mori registry show shinzui/keiro --full
rg -n 'mappedHarnessDeclarationsResolved|mappedProjectionSpecs|bindingAssertionDecl|coverageDecl|projectionAssertionDecls|wirePolicyAssertionDecls' \
  keiro-dsl/src/Keiro/Dsl
rg -n 'serviceHarnessModule|runServiceConformanceChecks|serviceConformanceFacts' \
  keiro-dsl/src keiro-dsl/test
```

Run focused generation and conformance tests during each milestone:

```bash
cabal test keiro-dsl:keiro-dsl-test --test-option=--match --test-option='structural conformance ownership'
cabal test keiro-dsl:keiro-dsl-conformance-structural
bash keiro-dsl/test/structural-mutation-test.sh
```

Before closing the plan, run:

```bash
cabal build all
cabal test keiro-dsl:tests
scripts/check-extension-policy.sh
scripts/check-generated-name-policy.sh
just adr-validate
git diff --check
git status --short
```

The mutation transcript must name the context structural gate for binding/coverage mutations and
the aggregate gate for the omitted event mutation. All scripts restore exact baseline bytes.


## Validation and Acceptance

For a service declaring `SharedPayload` used only by Aggregate A, generated output contains one
`StructuralConformance.hs`. Its declaration-wide labels occur once in the generated service
facade's check results. Aggregate A's harness contains only its mapped event/codec or register/
replay evidence. Aggregate B's harness has no `SharedPayload`, binding, fixture, shape, structural
projection, or mapped-codec import.

When both aggregates have genuine mapped uses, both retain their applicable aggregate-use checks,
but the declaration-wide binding and branch-coverage labels still occur exactly once. A checked
unused mapped declaration appears in `StructuralConformance` and nowhere in an aggregate harness.
Removing a required fixture or binding from source fails `keiro-dsl check`; running `scaffold`
against the same invalid input returns a stable diagnostic and leaves the output tree unchanged.

The structural mutation script must catch all existing mutations after regeneration and restore
all files byte-for-byte. Compiled output is `-Wall` clean. Fold baselines, behavior keys, snapshot
discriminators, generated codec bytes for unchanged aggregate uses, and wire goldens remain equal.
The two-aggregate locality test compares complete file trees, not selected lines.

The complete DSL test suite and all compiled conformance suites pass. Final corpus-wide byte
acceptance is deliberately deferred to EP-6; this plan records any focused generated diffs it
introduces so EP-6 can distinguish intended migration from accidental drift.


## Idempotence and Recovery

Generation remains plan-then-write and repeatable. A second scaffold over unchanged input must
report the context structural module and every aggregate module unchanged. The new module is
Generated, never create-once; recognized banners retain overwrite authority. No stale file is
deleted automatically.

Mutation scripts must use their existing backup/trap pattern and restore exact bytes on success,
failure, or interruption. If a partial renderer extraction makes generated code fail, repair the
generator and regenerate the focused fixture; never hand-edit committed generated Haskell into a
state the next scaffold cannot reproduce. Do not run or accept the full corpus refresh before
EP-6.


## Interfaces and Dependencies

No new package dependency. Consume the EP-1 module and existing `containers`, `aeson`, Keiki shape,
and `Keiro.Codec.Structural` APIs already used by the harness. The generator-facing interface must
be equivalent to:

```haskell
structuralConformanceModuleName :: Context -> Text

structuralConformanceModule ::
  Context ->
  CheckedService ->
  Either [StructuralConformanceFailure] (Maybe ScaffoldModule)
```

The generated module contract is:

```haskell
module Generated.Context.StructuralConformance
  ( structuralConformanceAssertions
  ) where

structuralConformanceAssertions :: [(String, Bool)]
```

Use a typed generator failure only for internal checked-model inconsistencies such as a service
inventory key missing from `tgDeclarations`; source-authored missing binding/fixture facts remain
ordinary `check` diagnostics. `ServiceHarness` imports this module exactly once when present.

EP-5 depends on the stable generated module role/name for reporting, and EP-6 depends on the final
assertion ownership and labels. Do not expose a second service package or make aggregate selection
depend on source member ownership.
