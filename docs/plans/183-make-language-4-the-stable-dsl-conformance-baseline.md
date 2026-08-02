---
id: 183
slug: make-language-4-the-stable-dsl-conformance-baseline
title: "Make language 4 the stable DSL conformance baseline"
kind: exec-plan
created_at: 2026-08-02T22:13:50Z
intention: "intention_01kz28awzeenp9wx9ypnykapap"
---

# Make language 4 the stable DSL conformance baseline

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro DSL language version 4 is the first language contract intended for general use in the
planned `keiro-dsl-0.9.0.0` release. It combines the version-2 syntax profile, the version-3
TypeID-v7 and nominal-equality behavior, the version-4 typed public-contract TypeIDs, and the
strict service-surface checks completed before version 4 ships. The repository nevertheless
teaches new authors to start at language 1, emits language-1 skeletons, requires almost every
ordinary fixture to stay on language 1, and runs most compiled conformance components against
language-1 generated code. This makes the compatibility path the best-tested path and leaves the
version users are about to adopt with little compositional evidence.

After this change, version 4 is machine-readable as the sole stable language for new authoring.
Versions 1 through 3 remain accepted, immutable compatibility contracts: existing sources can
still be parsed, inspected, checked, diffed, replay-planned, and scaffolded under their historical
semantics, but examples and new skeletons no longer recommend them. `keiro-dsl new contract`
starts with `language keiro-dsl 4`; `keiro-dsl inspect` reports version 4 as `stable` and older
versions as `compatibility-only`; and the main contract, aggregate, workspace, intake, publisher,
queue, read-model, workflow, process, router, structural, and nominal conformance paths compile
generated version-4 code. Focused compatibility fixtures continue to prove the deliberate older
boundaries without dominating the suite.

The result is observable in three ways. A new skeleton selects version 4. The main compiled
contract test exposes `KindID "inc"` rather than `Text` and rejects malformed or wrong-prefix
JSON. Finally, a repository test inventories every ordinary `.keiro` fixture and every compiled
conformance component, failing if a primary scenario falls behind the stable version without an
explicit compatibility reason.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-02T23:01:34Z) Milestone 1: represented version 4 as the sole stable authoring
  language and made all new skeletons and inspection output expose that status without removing
  versions 1 through 3.
- [x] (2026-08-02T23:26:01Z) Milestone 2: separated the current conformance corpus from the
  frozen frontend-compatibility corpus, made semantic test helpers service-aware by default, and
  added an enforced baseline manifest with explicit transitional migration rows for Milestone 3.
- [ ] Milestone 3: migrate coherent fixture families and primary compiled conformance components
  to version 4, regenerate their generated modules, and repair consumers against the complete
  version-4 API.
- [ ] Milestone 4: update authoring and release documentation, amend the language ADR, run the
  mutation and repository-wide gates, and record the final v4/compatibility inventory.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Surprise: The aggregate starter's version-1 graph carried a redundant `state ThingVertex`
  register and `write state := Done`; version-4 strict expression validation rejected the bare
  vertex constructor as `AggregateExpressionRootUnknown`. The lifecycle vertex is already moved
  by `goto Done`, so removing the mirror register and write made all eleven skeleton kinds pass
  checked version-4 validation and scaffolding. Evidence: the focused skeleton group initially
  failed one of eleven stable cases and then passed all eleven after the repair.

- Surprise: Routing the in-memory fold, diff, and replay helpers through the stable contract made
  ten existing unit examples fail immediately. The failures were useful evidence rather than
  infrastructure defects: old reservation fixtures use an unqualified enum constructor, the
  scalar fixture intentionally leaves command/register roots ambiguous, and one replay pairing
  test invents names that resolve to no field. Evidence: the full `keiro-dsl-test` run reported
  `FoldGuardResolutionFailed` for `TotalDivert`, `observedAt`, `revision`, and the synthetic guard
  names. Those examples remain explicitly routed through locally named `legacy...` helpers until
  their fixture families are repaired together in Milestone 3; the full 512-example unit suite is
  green at this checkpoint.


## Decision Log

Record every decision made while working on the plan.

- Decision: Version 4 is the only stable language for new authoring in the next release; versions
  1 through 3 remain accepted as compatibility-only contracts.
  Rationale: Removing or silently changing an older registered version would violate the released
  language guarantee and could break replay or generated consumers. Keeping it parseable does not
  require presenting it as the recommended starting point or using it for primary conformance.
  Date: 2026-08-02

- Decision: Make checked, service-aware helpers the default in tests that validate semantic
  behavior, scaffolding, fingerprints, diffs, replay, manifests, or durable identities.
  Rationale: A helper that calls `parseSpec` and a `Spec`-only compatibility wrapper necessarily
  selects legacy/version-1 semantics even when its fixture declares version 4. Merely rewriting
  source headers would otherwise create false coverage.
  Date: 2026-08-02

- Decision: Keep a small, explicitly inventoried compatibility lane instead of retaining the
  entire ordinary fixture corpus at old versions.
  Rationale: Compatibility evidence must prove immutable boundaries, but repeating every current
  feature scenario at language 1 obscures the stable product and multiplies maintenance without
  proportionate evidence. One focused proof per distinct historical boundary plus the frozen
  frontend vectors is sufficient; current feature interaction belongs to version 4.
  Date: 2026-08-02

- Decision: Migrate fixture families atomically and compare same-version candidates for ordinary
  evolution tests.
  Rationale: Moving only one member of a diff pair or workspace would introduce language-boundary
  findings unrelated to the field, policy, or ownership change the test intends to isolate.
  Date: 2026-08-02

- Decision: Do not introduce language version 5 and do not publish a release in this plan.
  Rationale: Version 4 is registered but has not shipped; the purpose is to certify it as the
  first stable contract for `0.9.0.0`. Release mechanics remain owned by the release workflow once
  this plan's acceptance gates are green.
  Date: 2026-08-02

- Decision: Keep the checked-in skeleton conformance tree on an explicitly named legacy
  compatibility comparison until Milestone 3 regenerates the compiled target as stable-primary.
  Rationale: Milestone 1 must prove that actual `skeletonFor` output retains version 4 through
  checked validation and scaffolding, while the coherent generated-tree and Cabal migration is a
  Milestone-3 change. Rewriting the comparison input to an explicit version-1 preamble avoids the
  old ambiguous `parseSpec` behavior and keeps the intermediate commit compiling.
  Date: 2026-08-02

- Decision: Permit the baseline manifest's temporary `migration-pending` role only at the
  Milestone-2 checkpoint, and eliminate every such row while migrating the corpus in Milestone 3.
  Rationale: The inventory must become enforceable before the large fixture and component rewrite
  begins, but classifying ordinary old fixtures as permanent compatibility evidence would defeat
  the policy. The temporary role makes the remaining work exact: 225 fixtures and 31 compiled
  components, with no prefix-wide exemption.
  Date: 2026-08-02


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Milestone 1 established version 4 as the single machine-readable stable entry without changing
the accepted registry or any runtime capability selection. New skeletons now render the stable
registry value, semantic-contract JSON derives `stable` or `compatibility-only` from that registry,
and source/workspace inspection exposes it. Focused validation passed 2 language-support examples,
15 skeleton examples, 5 released-profile examples, 7 fold/replay examples, and the compiled
skeleton component. The aggregate starter needed one strict-validation repair; the remaining ten
starter bodies were already valid under version 4.

Milestone 2 split the frozen frontend oracle into 15 dedicated source vectors and two dedicated
workspace scenarios (seven member/manifest files) while retaining the released exact diagnostic
bytes. The new baseline accounts for all 239 fixture sources and all 33 compiled components: at
this transitional checkpoint it records 13 fixture compatibility proofs, 225 migration-pending
fixtures, one stable component, one compatibility component, and 31 migration-pending components.
The service-aware regression observes version-4 `KindID "inc"`/`KindID "rsv"` output and the
durable contract-field identity. Both required mutations were exercised: changing the unlisted
stable contract fixture to version 1 named its path in two baseline failures, and routing the
scaffold helper through `legacyCheckedService` changed the generated fields to `Text` and failed
the capability assertion. Restoring both mutations returned the focused groups and the complete
512-example unit suite to green.


## Context and Orientation

The Keiro DSL is a versioned source language for `.keiro` service specifications. A language
version selects an immutable syntax profile and a runtime capability profile. A syntax profile
controls which source forms parse. A runtime capability profile controls behavior that can change
validation, generated Haskell, codecs, fold fingerprints, diff classification, or replay. The
append-only registry is `languageRegistry` in
`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`. It currently contains versions 1 through 4 but has
no lifecycle or stability field: `supportedLanguageVersions` means every registry entry the
parser accepts. Version 4 selects syntax profile 2 and runtime semantics 3, whose capabilities are
`GeneratedIdDomainTypeIdV7`, `NominalEqualityV2`, `ContractIdDomainTypeIdV7`, and
`StrictSpecSurfaceValidation`.

This plan uses three distinct terms. An **accepted language** is a registry entry the parser still
honors. A **stable authoring language** is the version recommended for newly written services and
used by primary conformance. A **compatibility-only language** remains accepted so historical
sources retain their exact meaning, but it is tested by focused compatibility vectors rather than
ordinary product examples. After this plan, versions 1 through 4 are accepted, version 4 is the
sole stable authoring language, and versions 1 through 3 are compatibility-only.

`keiro-dsl/src/Keiro/Dsl/SemanticContract.hs` resolves a parsed source to an
`EffectiveLanguageContract` and pairs it with the normalized graph as `CheckedService`. Production
single-file and workspace CLI routes preserve this value through validation and generation.
Older functions that take only `Spec` use `legacyCheckedService` and therefore select version 1;
they are compatibility bridges, not a default. `keiro-dsl/src/Keiro/Dsl/Skeleton.hs` currently
contradicts that distinction by prepending `language keiro-dsl 1` to every `keiro-dsl new <kind>`
skeleton. `keiro-dsl/app/Main.hs` renders source and workspace inspection JSON but has no stable
versus compatibility status to report.

The unit and fixture suite reinforces the old default. The pre-implementation inventory finds 237
explicit language headers below `keiro-dsl/test/fixtures`: 214 say version 1, 16 say version 2,
one says version 3, one says version 4, and five are intentionally malformed or future-version
source-selection cases. `keiro-dsl/test/Main.hs` contains a test named `keeps only the named
source-version compatibility fixtures outside canonical v1`, so ordinary fixtures are required to
remain old. Its `specOf` helper calls `parseSpec`, which discards source-language provenance.
`scaffoldFixture` then calls `scaffoldAggregate` and `harnessFor`, and `diffFixtures` calls
`diffSpecs`; each is a graph-only compatibility wrapper that selects version 1. Those helpers can
make a declared-version-4 fixture appear covered while bypassing every version-4 runtime
capability.

Compiled conformance components are Cabal test suites declared in
`keiro-dsl/keiro-dsl.cabal`, with checked-in generated Haskell below
`keiro-dsl/test/conformance*/`. There are 33 `keiro-dsl-conformance*` components. A banner audit
finds at least 24 component directories whose generated modules say `language keiro-dsl 1`.
`keiro-dsl/test/conformance-contract-typeid/` is the one dedicated version-4 contract component;
it correctly generates prefix-indexed `KindID` fields and rejects malformed, wrong-prefix,
non-canonical, and non-v7 input. The main `keiro-dsl-conformance-contract` component still compiles
the language-1 `Text` DTO. Version-2 nominal, scalar-expression, behavior, and workspace fixtures
and the version-3 ID-domain migration target exercise predecessor boundaries, but they do not give
the stable version broad compositional coverage.

`keiro-dsl/test/frontend-0.7/manifest.json` and
`keiro-dsl/test/Keiro/Dsl/FrontendCompatibility.hs` are a release-compatibility oracle created by
[ExecPlan 172](172-freeze-the-keiro-dsl-0-7-language-frontend-contract.md). The current helper also
uses that release manifest as a census of ordinary current fixtures. That coupling makes it hard
to move product examples forward without rewriting a historical oracle. This plan separates the
two responsibilities: the 0.7 corpus retains curated immutable compatibility vectors, while a new
stable-conformance manifest owns the current fixture and compiled-suite inventory.

Several completed plans define the behavior this work must finally exercise together.
[ExecPlan 169](169-thread-the-effective-keiro-language-contract-through-semantic-planning.md)
introduced `CheckedService` and declared graph-only APIs to be version-1 bridges.
[ExecPlan 171](171-enforce-versioned-id-prefix-domains-across-construction-decode-replay-and-evolution.md)
made version 3 enforce TypeID-v7 admission for generated IDs while preserving an internal legacy
replay seam. [ExecPlan 178](178-enforce-typed-typeids-in-integration-contracts.md) made version-4
public contract `typeid` fields lower to `KindID prefix`. [ExecPlan 180](180-close-accepted-but-unenforced-spec-surfaces-before-language-4-ships.md)
put ambiguous or unlowerable service surfaces behind version-4 strict validation.
[ExecPlan 181](181-replace-runtime-semantics-strings-with-capability-profiles-and-a-frozen-fingerprint-encoder.md)
made these capabilities explicit, and [ExecPlan 182](182-ship-closed-named-and-diagnosable-generated-runtime-apis-in-keiro-0-9.md)
regenerated the current generated API surface for the same planned release.

[ADR 16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
requires released language meanings to remain immutable and semantic consumers to retain
`CheckedService`; it is the main ADR to amend with stable-versus-compatibility lifecycle.
[ADR 18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md)
requires runtime behavior to be selected by exact capabilities rather than numeric version tests.
[ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
requires admission, diff, generated-code, and runtime evidence at their owning boundaries.
[ADR 12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
owns the generated and consumer-bound TypeID representations that version-4 conformance must
exercise. [ADR 14](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
requires every member of one workspace to select one semantic service, so workspace fixtures must
migrate as whole sets. [ADR 15](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
requires generated banners and scaffold history to remain attributable during regeneration. No
cross-repository ADR is needed, and this plan adds no external dependency.


## Plan of Work

### Milestone 1: Make version 4 the explicit stable authoring contract

Add `LanguageSupport` with the closed values `CompatibilityOnly` and `Stable` to
`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`, store it on each `LanguageDefinition`, and mark
versions 1 through 3 compatibility-only and version 4 stable. Export
`currentStableLanguageVersion` and a total lookup that reports the support classification of any
registered version. Keep `languageRegistry` append-only and keep the existing accepted-version
parser behavior; do not reinterpret `supportedLanguageVersions` as a reason to reject old sources.
Add registry invariants proving exactly one entry is stable, it is version 4, and it is the final
registered predecessor successor. A future release can add a new stable entry only by explicitly
reclassifying version 4 and updating these tests.

Expose the classification from `keiro-dsl/src/Keiro/Dsl/SemanticContract.hs`, and add a
`languageSupport` field to the JSON encoding of `EffectiveLanguageContract`. Decoding remains
compatible with existing JSON: derive support from the registered version rather than trusting a
serialized override. Update source and workspace inspection tests in `keiro-dsl/test/Main.hs` so a
version-4 source reports `stable` and version 1 reports `compatibility-only`.

Change the shared `versioned` prefix in `keiro-dsl/src/Keiro/Dsl/Skeleton.hs` to render
`currentStableLanguageVersion`, not a duplicated literal. Every `skeletonFor` result must parse,
validate through `CheckedService`, and report version 4. The focused proof is
`cabal run -v0 keiro-dsl -- new contract`: its first line becomes `language keiro-dsl 4`, and its
`typeid "thing"` field scaffolds as `KindID "thing"` when the output is checked and generated.

Milestone 1 is complete when new skeletons and inspection expose the stable status, all registered
older sources remain accepted under their original runtime profiles, and focused registry,
skeleton, inspection, fold, and replay tests pass without adding version 5.


### Milestone 2: Make the test infrastructure preserve the stable semantic contract

Create `keiro-dsl/test/conformance-baseline.json` with schema
`keiro-dsl/conformance-baseline/1`. It names stable language version 4, explicitly lists every
non-v4 fixture with its role, expected source form/version, and human-readable compatibility
reason, and inventories all 33 compiled conformance components as `stable-primary`,
`compatibility-proof`, or `version-independent`. Stable compiled rows also name the source fixture
or workspace that owns their generated tree. Avoid prefix or directory-wide exemptions: a newly
added old fixture must fail until a reviewer records why it is compatibility evidence.

Add `keiro-dsl/test/Keiro/Dsl/ConformanceBaseline.hs`, list it in the `keiro-dsl-test`
`other-modules`, and invoke its Hspec group from `keiro-dsl/test/Main.hs`. The group walks only
`keiro-dsl/test/fixtures` and `keiro-dsl/test/conformance*`, checks that every ordinary parseable
fixture declares version 4, proves every exception exists and matches its recorded reason, checks
that all members of each stable workspace are version 4, and verifies every generated banner in a
stable compiled component says language 4. It also checks that the manifest names every
`keiro-dsl-conformance*` stanza in `keiro-dsl/keiro-dsl.cabal`, so adding a suite cannot bypass the
policy.

Decouple `keiro-dsl/test/Keiro/Dsl/FrontendCompatibility.hs` from the current corpus census. Keep
`keiro-dsl/test/frontend-0.7/manifest.json` as a curated compatibility oracle with dedicated source
vectors below `keiro-dsl/test/frontend-0.7/sources/`: legacy-unversioned input, one valid declared
source for each language the 0.7 release owned, each predecessor feature rejection, representative
single-source and workspace diagnostics, and the existing exact diagnostic goldens. Do not make
the 0.7 manifest enumerate ordinary version-4 fixtures. Preserve the old bytes for every retained
vector, and document why any redundant row is retired; this is a focus change, not permission to
rewrite an old expected result.

Refactor semantic helpers in `keiro-dsl/test/Main.hs`. `checkedServiceOf` and `parsedSourceOf`
become the normal fixture readers for validation, scaffolding, fingerprints, diffs, replay,
manifests, records, and identities. `scaffoldFixture` must use `scaffoldServiceModules` or the
corresponding `...ForService` functions, and `diffFixtures` must use `parseSource` plus
`diffSources`. In-memory graph mutation tests use a test-only `stableCheckedService` constructed
from the registered `currentStableLanguageVersion`. Keep `specOf`, `diffSpecs`, `scaffoldModules`,
and other graph-only wrappers only where a test explicitly proves parsing/graph behavior or the
legacy compatibility API; rename local helpers with `legacy` when that choice is intentional.

Add a restoring regression that turns red if the stable scaffold helper is routed through
`parseSpec` or `legacyCheckedService`. The regression should inspect an output affected by a v4
capability—for example, the contract field type is `KindID "inc"` and the contract-field ID-domain
identity is present—rather than merely checking the generated banner.

Milestone 2 is complete when the baseline test fails on an unlisted language-1 fixture, the
restoring regression fails when version provenance is discarded, the 0.7 frontend oracle passes
from its dedicated vectors, and all existing graph-only compatibility tests remain explicit and
green.


### Milestone 3: Move primary fixtures and compiled conformance to version 4

Migrate ordinary fixtures by coherent family. This includes the base and every mutation/diff
variant for aggregates and event evolution (`reservation*.keiro`), mapped consumer types,
contracts and integration (`contract-v4.keiro`, `intake*.keiro`, and `emit*.keiro`), work queues,
read models, workflows, processes, routers, structural mappings, and all ordinary workspace member
sets. Version-selection fixtures, predecessor syntax-gate fixtures, the version-3 ID-domain
migration, and any retained 0.7 source vector stay in the compatibility manifest with a precise
reason. When version-4 strict validation exposes a fixture that was accepted only because an older
language allowed an ambiguous graph, repair the fixture so it represents a valid current service;
do not add a compatibility exemption simply to preserve a stale example.

Make `keiro-dsl-conformance-contract` the stable version-4 contract component by moving the typed
contract driver and generated module from `keiro-dsl/test/conformance-contract-typeid/` into the
main component. Preserve the old language-1 bytes and permissive driver under the explicitly named
`keiro-dsl-conformance-contract-v1-compat` component and directory. Remove the redundant
`keiro-dsl-conformance-contract-typeid` name after its round-trip and four rejection assertions are
present in the main target. The component that developers naturally run will then exercise the stable
contract while retaining the historical proof required by ExecPlan 178.

Regenerate every stable component's `Generated` modules through the checked CLI or
`scaffoldServiceModules`, never by editing a generated file. Preserve hand-owned hole/value
modules and update them against the newly generated signatures. Version 4 will expose real gaps:
contract-bearing intake and publisher components need `KindID` construction and the generated
`keiro-core`/`mmzk-typeid` dependencies; generated aggregate IDs require safe current constructors
instead of public raw-text construction; strict validation may require corrected names, bindings,
or coupling declarations. Update each component's `build-depends` in
`keiro-dsl/keiro-dsl.cabal` from the generated manifest rather than adding one global dependency.

Upgrade the remaining primary compiled components—including aggregate, snapshot, behavior,
nominal, workspace, structural, cold-start, intake, publisher, queue, read-model, dispatch,
workflow, process, router, and new-surface targets—to checked version-4 output. The version-3
`keiro-dsl-conformance-id-domain-migration` target remains a compatibility proof because its
purpose is to replay legacy-invalid data across the v2-to-v3 boundary. Any other compiled
compatibility exception must appear in `conformance-baseline.json` with the unique behavior that a
stable target cannot prove.

Add a deterministic check mode, either to `ConformanceBaseline.hs` or a small
`keiro-dsl/test/conformance-baseline-test.sh`, that scaffolds each stable source into a fresh
temporary directory and compares its generated banner/module set with the checked-in component
inventory without touching hand-owned files. If multiple components intentionally reuse a subset
of one service's generated tree, record that mapping explicitly. This check is the repeatable
regeneration oracle for future language releases.

Milestone 3 is complete when every stable-primary component compiles version-4 generated code,
the main contract suite proves typed TypeID behavior, the named v1 and v3 compatibility targets
still pass, fresh scaffolding matches the checked-in stable inventory, and
`cabal test all --test-show-details=direct` is green.


### Milestone 4: Teach and release the stable baseline

Update `agents/skills/keiro-dsl-authoring/SKILL.md`, `LOOP.md`, `NOTATION.md`, and
`WALKTHROUGH.md`; `docs/user/typed-spec-toolchain.md`; and
`docs/corpus/keiro-dsl-corpus.md`. New examples start at language 4 and explain that versions 1
through 3 are compatibility-only. The walkthrough must use a version-4 fixture and show the
observable TypeID/current-constructor behavior. The corpus document should lead with the stable
suite matrix, then list the smaller historical lane separately; it must not describe version 1 as
the canonical ordinary fixture contract.

Add the stable-language designation, changed skeleton default, conformance migration, and test
component rename to `keiro-dsl/CHANGELOG.md` under the planned `0.9.0.0` section and to the existing
0.9 migration guide if one exists. State explicitly that source language versions 1 through 3 are
still accepted and are not silently upgraded. This plan does not bump package versions, tag, or
publish artifacts.

Amend [ADR 16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) so
the durable contract distinguishes accepted historical versions from the one stable authoring
version and requires primary conformance to follow the stable registry entry. Amend ADR 18 only if
implementation changes how the stable entry selects capabilities; ordinary test rearrangement
does not justify an unrelated ADR edit. Add one `docs/adr/log.md` update with `okf log add`, then
run strict profile and log enforcement.

Run the language-baseline mutation: temporarily change one stable fixture to version 1 and prove
the baseline test fails with its path and expected version 4, then restore it. Run the
service-aware mutation: temporarily route the stable helper through `legacyCheckedService` and
prove the v4 capability assertion fails, then restore it. Finish with all tests, all-package build,
native flake checks, strict ADR validation, generated-file formatting checks for files changed by
the plan, and `git diff --check`.

Milestone 4 is complete when every authoring entry point teaches version 4, the automated policy
prevents the corpus from drifting back, the compatibility lane remains green and explicit, all
repository gates pass, and the living sections of this plan record the final stable/compatibility
inventory and any repaired fixture defects.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/keiro`.

Capture the current skew before editing:

```bash
rg '^language keiro-dsl [0-9]+' keiro-dsl/test/fixtures -g '*.keiro' --no-filename | sort | uniq -c
rg -n 'keeps only the named source-version compatibility fixtures outside canonical v1|scaffoldFixture|diffFixtures' keiro-dsl/test/Main.hs
cabal run -v0 keiro-dsl -- new contract
```

The initial counts include 214 version-1 headers and one version-4 header. The skeleton transcript
begins:

```text
language keiro-dsl 1
context my-service
```

After Milestone 1, rerun the skeleton and inspect both support classes:

```bash
cabal run -v0 keiro-dsl -- new contract
cabal run -v0 keiro-dsl -- inspect keiro-dsl/test/fixtures/contract-v4.keiro --format=json
cabal run -v0 keiro-dsl -- inspect keiro-dsl/test/frontend-0.7/sources/language-v1.keiro --format=json
cabal test keiro-dsl-test --test-option=--match --test-option='language support'
```

Expected leading output and JSON fragments are:

```text
language keiro-dsl 4
"languageVersion":4
"languageSupport":"stable"
"languageVersion":1
"languageSupport":"compatibility-only"
```

After Milestone 2, run the policy, frontend oracle, and service-aware focused groups:

```bash
cabal test keiro-dsl-test --test-option=--match --test-option='conformance baseline'
cabal test keiro-dsl-test --test-option=--match --test-option='frontend 0.7 compatibility'
cabal test keiro-dsl-test --test-option=--match --test-option='service-aware fixture helpers'
```

Each exits zero. The baseline output identifies version 4 as stable, reports no unclassified old
ordinary fixture, and accounts for every Cabal conformance component.

During Milestone 3, validate each migrated family before moving to the next, then run the complete
DSL closure:

```bash
cabal test keiro-dsl-test --test-show-details=direct
cabal test keiro-dsl-conformance-contract keiro-dsl-conformance-contract-v1-compat --test-show-details=direct
cabal test keiro-dsl-conformance-id-domain-migration --test-show-details=direct
cabal test all --test-show-details=direct
```

The stable contract target prints successful typed round trips plus malformed, wrong-prefix,
non-canonical, and non-v7 rejections. The v1 compatibility target still accepts its historical
`inc-1` sample. The v3 migration target still accepts legacy-invalid text only through historical
event replay and rejects it at current admission.

Run the deterministic baseline checker in its non-writing mode after regeneration. If the final
implementation keeps the check inside Hspec, the first command is sufficient; if it adds the
named script, run both:

```bash
cabal test keiro-dsl-test --test-option=--match --test-option='conformance baseline'
bash keiro-dsl/test/conformance-baseline-test.sh --check
```

Close with the repository gates:

```bash
cabal build all
cabal test all --test-show-details=direct
nix flake check
okf log add docs/adr --kind Update -m "Make language 4 the stable authoring and primary conformance contract (plan 183)."
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
git diff --check
```

Record exact test counts, migrated component counts, compatibility exceptions, and any deviations
in Progress, Surprises & Discoveries, and Outcomes & Retrospective before marking the plan
complete.


## Validation and Acceptance

Acceptance is behavioral and policy-enforced.

`keiro-dsl new` for every skeleton kind must emit a complete source whose first non-comment line
is `language keiro-dsl 4`; parsing, checking, scaffolding, and inspecting each skeleton must retain
version 4. Inspection of version 4 must report `stable`. Inspection of a retained version-1,
version-2, or version-3 compatibility source must report `compatibility-only`, and its effective
runtime profile must remain byte-for-byte equal to the pre-plan registry selection.

The fixture policy must account for every `.keiro` source below `keiro-dsl/test/fixtures`.
Ordinary feature, negative-validation, diff, and workspace fixtures must be version 4. Every
non-v4 file must be a manifest row with an expected version/source form and a specific reason tied
to a language, migration, or release-compatibility boundary. Adding a new unlisted version-1 file
must fail the test and name its path. Leaving a nonexistent exception in the manifest must also
fail, preventing the allowlist from becoming a graveyard.

Every compiled `keiro-dsl-conformance*` Cabal stanza must appear in the manifest. Every generated
module owned by a `stable-primary` component must carry a version-4 banner and be reproducible from
the row's checked source or workspace. The compatibility component set must be small and named as
such. At minimum, it retains the language-1 permissive contract proof and the language-3 ID-domain
migration proof; any additional predecessor component needs a non-duplicated behavior rationale.

The main `keiro-dsl-conformance-contract` component must compile fields with distinct
`KindID "inc"`, `KindID "rsv"`, and `KindID "hsp"` types, encode canonical JSON text, and reject
malformed, wrong-prefix, uppercase/non-canonical, and non-v7 samples at the field path. Contract,
intake, and publisher components must consume those typed values through their real generated APIs,
not convert them back into unchecked `Text` at their boundaries.

Stable aggregate and nominal suites must use the version-4 generated ID admission contract. New
values enter through safe current constructors and decoders, while the dedicated version-3
migration proof alone may use the internal historical replay seam. Workspace, fold, diff, replay,
manifest, and durable-identity assertions must receive `CheckedService`; a mutation to a
graph-only wrapper must redden a v4-specific assertion.

The curated 0.7 frontend compatibility group must retain exact representative source-selection,
grammar-feature, diagnostic, and workspace results without depending on current version-4 product
fixtures. Versions 1 through 3 remain accepted; no command silently rewrites their preamble, and no
registry entry or capability is removed.

The work is accepted only when the baseline mutations fail for the expected reason and restore to
green, every focused compatibility and stable component passes, `cabal test all`, `cabal build
all`, `nix flake check`, strict ADR validation, generated-file checks, and `git diff --check` all
exit zero.


## Idempotence and Recovery

Language metadata, fixture headers, manifest rows, Cabal dependencies, and documentation are
deterministic edits. Repeat the baseline scan after each fixture family so an interruption leaves a
clear list of migrated and remaining paths. Never delete or reorder language registry entries to
make the stable-version invariant pass; correct the explicit status field or test instead.

Regenerate candidate Haskell into a fresh temporary directory first. Compare only generated files
against their checked-in target, then copy reviewed generated files while preserving hand-owned
holes and value modules. The baseline check mode must never write. If a generated tree becomes
partially updated, discard only the temporary candidate, fix the generator or source fixture, and
regenerate that family; do not hand-edit a `-- @generated` module.

Move coherent diff pairs and every member of one workspace together. If strict v4 validation
reveals a new diagnostic, keep the v1 original only when the scenario is explicitly historical;
otherwise repair the current fixture and its variants so the intended diagnostic remains isolated.
Do not weaken version-4 validation or add a broad compatibility exemption as a recovery shortcut.

Build the dedicated 0.7 source set and make its tests green before removing the old global-census
coupling. Keep the old manifest available in the Git history and preserve every retained vector's
bytes. The compatibility tests are the recovery oracle for accidental historical drift; the
stable baseline and fresh-scaffold comparisons are the recovery oracle for accidental fallback to
legacy helpers.

This plan does not publish, tag, or perform a database migration. If implementation overlaps
unrelated dirty generated fixtures, preserve those edits, regenerate into temporary directories,
and resolve the overlap file by file rather than overwriting the tree wholesale.


## Interfaces and Dependencies

`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` owns the stable classification. The final public
surface should be equivalent to:

```haskell
data LanguageSupport
  = CompatibilityOnly
  | Stable
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data LanguageDefinition = LanguageDefinition
  { definitionVersion :: !LanguageVersion,
    definitionPredecessor :: !(Maybe LanguageVersion),
    definitionBodyParser :: !LanguageBodyParser,
    definitionSyntaxProfile :: !SyntaxProfile,
    definitionRuntimeSemanticsProfile :: !RuntimeSemanticsProfile,
    definitionSupport :: !LanguageSupport
  }

currentStableLanguageVersion :: LanguageVersion
languageSupportForVersion :: LanguageVersion -> Maybe LanguageSupport
languageSupportText :: LanguageSupport -> Text
```

The constructor order and exact record formatting may follow Fourmolu, but the semantics are fixed:
versions 1 through 3 return `CompatibilityOnly`, version 4 returns `Stable`, and there is exactly
one stable entry. `supportedLanguageVersions` continues to describe parseable registry entries for
source-selection compatibility; callers choosing a new authoring default use
`currentStableLanguageVersion`.

`keiro-dsl/src/Keiro/Dsl/SemanticContract.hs` adds:

```haskell
effectiveLanguageSupport :: EffectiveLanguageContract -> LanguageSupport
```

Its JSON encoding includes `"languageSupport":"stable"` or
`"languageSupport":"compatibility-only"`, derived from the registered language version. No caller
can fabricate a different support classification for an existing version.

`keiro-dsl/test/Keiro/Dsl/ConformanceBaseline.hs` owns test-only manifest decoding and Hspec
assertions. The JSON shape is equivalent to:

```json
{
  "schema": "keiro-dsl/conformance-baseline/1",
  "stableLanguageVersion": 4,
  "fixtureExceptions": [
    {
      "path": "test/fixtures/id-domain-migration-v3.keiro",
      "sourceForm": "declared",
      "effectiveVersion": 3,
      "reason": "v2-to-v3 historical replay compatibility"
    }
  ],
  "compiledSuites": [
    {
      "component": "keiro-dsl-conformance-contract",
      "directory": "test/conformance-contract",
      "source": "test/fixtures/contract-v4.keiro",
      "role": "stable-primary"
    }
  ]
}
```

The implementation may add fields for workspace members or reused generated subsets, but it must
not replace explicit paths and reasons with a blanket version allowlist.

Test-only helpers in `keiro-dsl/test/Main.hs` should be equivalent to:

```haskell
stableCheckedService :: Spec -> CheckedService
stableCheckedService = checkedService stableSourceLanguage

stableSourceLanguage :: SourceLanguage
stableSourceLanguage =
  DeclaredLanguage
    { declaredLanguageVersion = currentStableLanguageVersion,
      languageVersionLoc = noLoc
    }
```

Fixture-based helpers should prefer `parseSource` and `checkedSource` rather than constructing this
value; the test-only constructor exists for in-memory `Spec` mutations that have no source text.
Production CLI and workspace code already owns real provenance and must continue to use it.

No new external library is required. The baseline decoder can use the existing `aeson`,
`directory`, `filepath`, and `text` dependencies of `keiro-dsl-test`. Individual compiled
components add existing `keiro-core` and `mmzk-typeid` dependencies only when their version-4
generated modules import those packages. Cross-repository dependency APIs do not change.


## Revision Notes

2026-08-02: Recorded the completed Milestone-1 implementation, validation evidence, the aggregate
starter repair exposed by strict version-4 checking, and the temporary explicit compatibility
status of the checked-in skeleton conformance tree.

2026-08-02: Recorded the completed Milestone-2 compatibility-oracle split, enforced transitional
inventory, service-aware helper boundary, mutation evidence, and exact remaining Milestone-3
migration counts.
