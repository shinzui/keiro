---
id: 188
slug: generate-one-runnable-conformance-package-per-keiro-dsl-service
title: "Generate one runnable conformance package per Keiro DSL service"
kind: exec-plan
created_at: 2026-08-03T17:47:44Z
intention: "intention_01kz4bg44te47t68y68g6bjcjd"
---

# Generate one runnable conformance package per Keiro DSL service

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, one checked Keiro service produces one local Cabal package that runs all
of that service's generated conformance evidence. A workspace whose durable identity is
`service mori` produces one package such as `keiro-mori-conformance`; it does not produce one
package per member file, aggregate, read model, or harness module. A standalone `.keiro` file
uses its context as the one-file service identity and follows the same rule.

The normal developer and CI interaction becomes `cabal test keiro-mori-conformance` after a
one-time `cabal.project` glob and service-library exposure. Developers no longer write a
`Main.hs`, copy every harness into a hand-maintained test stanza, or translate
`keiro-dsl-manifest.*.txt` into another conformance component whenever the service graph
changes. The existing text manifest remains available as the service runtime's build inventory
and as a compatibility path; this plan replaces its use as instructions for constructing a
runnable harness, not the independent requirement to compile generated runtime modules into the
service library.

The package boundary is deliberately narrow. Per-node harness implementations remain compiled
inside the service library, where they can use private generated and hand-owned modules without
creating a dependency cycle. Keiro additionally generates one stable service-level conformance
facade and exposes only that facade to the generated runner package. The generated package owns
the runner plus create-once expectations for facts whose value only becomes meaningful when
compared with a hand-owned baseline.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-03) Investigated the current Keiro scaffold, manifest, harness APIs, accepted
  ADRs, the existing local proof package, and the active Mori Language 4 migration represented
  by `mori://shinzui/mori/packages/mori-core`.
- [x] (2026-08-03 18:23Z) M1: Recorded the package boundary in ADR 0020 and added
  the validated workspace/CLI runtime-package setting without changing existing unconfigured
  scaffold output. `cabal test keiro-dsl-test` passed 525 examples.
- [ ] M2: Generate one stable, service-level conformance facade that normalizes every current
  harness family into executable checks and review-owned facts.
- [ ] M3: Generate, preflight, write, and report exactly one local Cabal conformance package per
  workspace service or standalone service.
- [ ] M4: Prove the complete workflow with a Mori-shaped multi-member fixture, update the user
  documentation, and validate the repository and ADR bundle.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: The plan named `just check-adr`, but this checkout exposes the strict ADR recipe as
  `just adr-validate`.
  Evidence: `just check-adr` returned `justfile does not contain recipe 'check-adr'`; the corrected
  command ran `okf validate ... --log-enforce` and reported `OK: 20 concepts`.


## Decision Log

- Decision: Generate exactly one conformance package for the workspace `service` identity; use
  the context only for the backward-compatible standalone `.keiro` path.
  Rationale: ADR 0014 makes the workspace service name the durable whole-service identity and
  defines a single file as a one-member workspace. Member files and nodes are graph ownership
  units, not separately deployed services.
  Date: 2026-08-03

- Decision: Put the service-level runner and create-once expectations in the generated package,
  but keep per-node harness implementations in the service runtime library behind one generated
  conformance facade.
  Rationale: Moving the complete generated runtime and Hole modules into another package can
  make the service depend on its generated package while hand-owned holes depend back on the
  service. Keeping the harness implementations beside their runtime closes that cycle and avoids
  making every generated internal module public. The downstream package imports one stable
  facade only.
  Date: 2026-08-03

- Decision: Require an explicit Cabal package name for the service runtime rather than deriving
  it from the Keiro service name.
  Rationale: The current consumer proves the names are different: `service mori` is implemented
  by `mori-core`. Inferring `mori` would generate a package that cannot build. Workspace manifests
  may persist `runtime-package`; a CLI option supplies or overrides it for standalone and
  transitional use.
  Date: 2026-08-03

- Decision: Make package generation opt-in through an effective runtime-package setting in this
  release, and preserve the existing manifest and scaffold bytes when no setting is present.
  Rationale: Existing users have not exposed a conformance facade and may scaffold into source
  trees not covered by a Cabal project glob. Additive opt-in lets them adopt intentionally while
  preserving Language 4 compatibility.
  Date: 2026-08-03

- Decision: Store process, router, and workflow expectations in one create-once module per
  service package; generated aggregate and read-model self-checks do not get copied into that
  baseline.
  Rationale: Generating both the actual fact and a replaceable expected value would be tautological.
  A create-once baseline passes on first adoption, survives later scaffolds, and makes added,
  removed, or changed facts fail until a developer reviews the change. One module reinforces the
  one-package-per-service model without weakening per-fact failure labels.
  Date: 2026-08-03

- Decision: Keep `keiro-dsl-manifest.*.txt` as a compatibility and runtime-build artifact.
  Rationale: A runnable conformance package removes hand-authored drivers and test stanzas, but it
  cannot eliminate the service library's need to compile the generated runtime. Removing the
  manifest would overstate this feature and break existing consumers.
  Date: 2026-08-03

- Decision: Extract the existing mapped-source Cabal package-name predicate into
  `Keiro.Dsl.RuntimePackage` and make `RuntimePackageName` its only validated constructor path.
  Rationale: Workspace parsing, CLI parsing, and mapped Haskell sources must accept exactly the
  same package language without copying a rule that can drift. A dependency-free shared module
  avoids introducing a cycle between workspace and scaffold/package planning.
  Date: 2026-08-03


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

- Milestone 1 established the durable package boundary in ADR 0020, added the optional persisted
  `runtime-package` clause and CLI override, and preserved all existing unconfigured manifest and
  scaffold evidence. Focused validation passed 525 examples; the only plan correction was the
  repository's actual ADR recipe name, `adr-validate`.


## Context and Orientation

Work from `/Users/shinzui/Keikaku/bokuno/keiro`. In this plan, a **service** is the complete
checked graph supplied to one `keiro-dsl` invocation. For a `.keiro-workspace`, it is the durable
`service <name>` declared by the manifest and may contain many member specs and nodes. For a bare
`.keiro` file, it is the existing single checked context, treated as a one-member service. A
**runtime package** is the consumer's Cabal library that compiles the generated service modules;
it is not the new conformance package. A **conformance facade** is one generated module in that
runtime library which presents every per-node harness through a stable service-level API. A
**conformance package** is the new local, non-publishable Cabal package with one
`exitcode-stdio-1.0` test suite.

`keiro-dsl/src/Keiro/Dsl/Harness.hs` emits five relevant harness shapes today. Aggregate modules
export `harnessAssertions :: [(String, Bool)]`. Read-model modules export
`runReadModelFacts :: IO Bool`, backed by expected-versus-derived facts. Process and router
modules export `[(String, String)]` values intended to be compared with a hand-written baseline.
Workflow modules export a typed `WorkflowFacts` value with the same expectation. These are all
generated per node, but none gives a workspace one command that discovers and runs the complete
set.

`keiro-dsl/src/Keiro/Dsl/Manifest.hs` computes the Haskell edition, extension baseline, module
inventory, runtime dependencies, and explicitly declared consumer packages. Its header says the
result is Cabal-pasteable. `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` writes the single-file
`keiro-dsl-manifest.<context>.txt`; `keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs` writes the
workspace-keyed variant using helpers from `keiro-dsl/src/Keiro/Dsl/WorkspaceRecord.hs`.
[ExecPlan 80](80-reduce-keiro-dsl-authoring-friction-and-make-module-placement-configurable.md)
explicitly chose a paste aid rather than editing consumer Cabal files. This plan preserves that
safety decision while generating a complete new Cabal package at a deterministic path.

`keiro-dsl/src/Keiro/Dsl/Workspace.hs` parses and canonically renders `.keiro-workspace` files.
Today the manifest has `service`, optional `module` and `layout`, and one or more `spec` clauses.
The implementation will add an optional `runtime-package` clause after `service`. It is build
metadata and never becomes another service identity. Existing manifests without it continue to
parse, render, check, diff, and scaffold exactly as before. The `scaffold` command in
`keiro-dsl/app/Main.hs` will also accept `--runtime-package PACKAGE`; the CLI value wins over the
workspace value, following the existing module-root override precedent. A package is generated
only when the effective value is present.

The generated package lives under the same `--out` root so the existing path safety and
detection-before-write model can cover all output before any bytes change. A workspace named
`mori` uses this slot:

```text
<out>/keiro-dsl-conformance.workspace.mori/
  keiro-mori-conformance.cabal
  keiro-dsl-conformance-record.txt
  src/Main.hs
  src/KeiroConformance/Expectations.hs
```

A standalone context `hospital-capacity` uses
`<out>/keiro-dsl-conformance.hospital-capacity/`. The Cabal package name is
`keiro-<cabalised-service>-conformance`. The cabalisation helper must be total and deterministic
over the wire-word grammar, must preserve `mori` as `mori`, and must be tested against `_`/`-`
collision cases. It must not inspect nearby `.cabal` files or infer an owner package from a
directory name.

The current Mori migration is the representative consumer, not Kotei. The registered package
`mori://shinzui/mori/packages/mori-core` contains the generated service code for the project
manifest at `domain/mori.keiro-workspace`. That manifest declares `service mori`, composes four
members, and currently yields two aggregate harnesses and two read-model harnesses. Its runtime
package is `mori-core`, not `mori`, and its current Cabal library exposes the generated harness
modules. Its Just recipe scaffolds the complete workspace into `mori-core/src`. This is direct
evidence that one package per workspace is the useful unit and that runtime-package inference is
unsafe. The repository is undergoing its own migration, so this Keiro plan uses a local
Mori-shaped fixture rather than writing into that separate worktree. No relevant cross-repository
ADR was found in the registered corpus.

The ADR discovery workflow scanned local filenames and headings, then read the four records that
govern this work. `dhall type --file docs/adr/profile.dhall` succeeds for the local ADR profile.

- [ADR 0014](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
  makes `service` the durable workspace identity, treats membership as a set, emits one merged
  graph, and defines a single `.keiro` file as a one-member workspace. The package key must follow
  that identity and never a member or node.

- [ADR 0015](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
  reserves workspace-keyed artifact slots, requires all refusals before the first write, never
  deletes stale files, and distinguishes replaceable Generated files from create-once hand-owned
  files. Package files need the same provenance and recovery behavior.

- [ADR 0017](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
  makes generated-versus-Hole behavior ownership explicit. Expectations must therefore be
  create-once evidence; the generator may not overwrite an application's accepted behavior
  baseline or generate both sides on every run.

- [ADR 0019](../adr/0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md)
  assigns generated Haskell the GHC2024 plus `OverloadedStrings` baseline and keeps specialized
  extensions local. The facade and package runner must compile under that contract rather than
  inheriting Keiro's broader test defaults.

No accepted ADR defines a generated package boundary, the runtime-package declaration, or the
facade API. Milestone 1 therefore creates a new ADR for those durable decisions before code that
depends on them lands.


## Plan of Work

The work has four milestones. Each milestone ends with a compiling repository and an observable
acceptance boundary. Do not edit Mori from this plan; model its relevant four-member, collocated,
single-runtime-package shape in Keiro's own fixture.

### Milestone 1 — Persist the package boundary and runtime-package authority

First record the durable architecture decision in a new accepted ADR under `docs/adr/`. Use the
OKF ID allocator and the existing ADR template/profile rather than choosing a document ID by hand.
The ADR must state that a workspace service produces at most one local conformance package, the
service runtime and conformance package are distinct Cabal packages, the runner imports one stable
facade, package generation is additive opt-in for Language 4, and the text manifest remains the
runtime build inventory. Link ADRs 0014, 0015, 0017, and 0019.

Then extend `WorkspaceManifest` and its parser/renderer in
`keiro-dsl/src/Keiro/Dsl/Workspace.hs` with an optional `runtime-package <cabal-name>` clause.
It appears at most once, canonically immediately after `service`, and follows the same Cabal
package-name grammar already enforced for mapped Haskell sources in
`keiro-dsl/src/Keiro/Dsl/Validate.hs`. Preserve source location so duplicate or malformed clauses
point at the manifest line. Update all direct `WorkspaceManifest` constructors and parser,
round-trip, canonical-order, duplicate-clause, and backward-compatibility tests in
`keiro-dsl/test/Main.hs`.

Extend the `Scaffold` command in `keiro-dsl/app/Main.hs` with optional
`--runtime-package PACKAGE`. Compute one effective value: CLI override, then workspace manifest,
then absent. The bare `.keiro` path has no persisted workspace setting and therefore uses the CLI
option. Checking, parsing, inspection, behavior obligations, and diffing do not require the
setting. With no effective runtime package, scaffold behavior and bytes remain pinned to today's
output. With a setting, planning receives a `RuntimePackageName` smart constructor rather than a
raw `Text`.

At the end of M1 these interfaces exist, or equivalent names with the same responsibilities:

```haskell
newtype RuntimePackageName = RuntimePackageName {unRuntimePackageName :: Text}

mkRuntimePackageName :: Text -> Either Text RuntimePackageName

data WorkspaceManifest = WorkspaceManifest
  { wmfService :: !Text
  , wmfServiceLoc :: !Loc
  , wmfRuntimePackage :: !(Maybe RuntimePackageName)
  , wmfRuntimePackageLoc :: !Loc
  -- existing fields follow
  }

effectiveRuntimePackage
  :: Maybe RuntimePackageName
  -> WorkspaceManifest
  -> Maybe RuntimePackageName
```

M1 is accepted when existing workspace fixtures render byte-for-byte unchanged, a manifest with
`runtime-package mori-core` round-trips canonically, malformed and duplicate clauses fail at the
right line, and the CLI accepts the option without generating package files yet.

### Milestone 2 — Generate one service-level conformance facade

Add `keiro-dsl/src/Keiro/Dsl/ServiceHarness.hs`. It consumes the complete `CheckedService`, not
individual workspace members, and emits exactly one context-level Generated module whenever a
runtime package is configured. Reuse the context-level prefix policy already used for Nominals
and ReplayAudit. For Mori's `module Mori`, `context modules`, and collocated layout, the output is
`Mori.Modules.Generated.Conformance`; prefixed layout follows the corresponding
`Generated.<Context>` convention. Factor the existing local context-prefix helper rather than
copying its rules a third time.

The emitted facade imports all per-node harness modules in stable node-identity order and exports
only base-library shapes:

```haskell
runServiceConformanceChecks :: IO [(String, Bool)]

serviceConformanceFacts :: [(String, String)]
```

`runServiceConformanceChecks` prefixes every aggregate assertion with the node kind and name. It
also runs each read-model fact set and returns a labelled Boolean for each fact. Extend the
read-model harness additively with a pure `readModelFactResults :: [(String, Bool)]`; keep
`readModelFacts` and `runReadModelFacts` working so existing consumers do not break.

`serviceConformanceFacts` flattens process, router, and workflow facts into unique, stable keys of
the form `<kind>/<node>/<fact>`. Process and router values already have string forms. Add a pure
workflow fact projection beside `WorkflowFacts` so the facade does not duplicate workflow-field
knowledge. Reject duplicate normalized keys in the generator's pure plan rather than silently
letting `lookup` choose one.

Include the facade in single-file and workspace scaffold planning only when a runtime package is
configured. Mark it context-level in workspace provenance. Enhance
`keiro-dsl/src/Keiro/Dsl/Manifest.hs` so the configured manifest names this one stable facade as a
module the runtime library must expose; all per-node harness and runtime modules remain normal
internal modules. Existing unconfigured manifest snapshots remain unchanged.

Add pure renderer tests in `keiro-dsl/test/Main.hs` covering an aggregate-only service, a service
with aggregate and read-model self-checks, a service with process/router/workflow facts, a
multi-member workspace, and a service with no harness-producing nodes. The last case still emits
one facade whose two collections are empty, so the package identity does not appear and disappear
as nodes are added.

M2 is accepted when the generated facade compiles under the advertised GHC2024 plus
`OverloadedStrings` baseline, invokes every supported harness exactly once, produces stable
service-wide labels regardless of workspace member order, and imports no application module
except through the already compiled per-node harnesses.

### Milestone 3 — Plan and emit the runnable package safely

Add `keiro-dsl/src/Keiro/Dsl/ConformancePackage.hs` with pure naming, rendering, and comparison
logic. A `ConformanceServiceKey` distinguishes a workspace service from a standalone context so
their on-disk slots retain ADR 0015's non-aliasing rule. The planner receives one facade module
name and one explicit runtime package. It returns exactly one package plan, never a collection
indexed by nodes.

The generated Cabal file declares a local package at version `0.0.0.0`, a synopsis and license,
and one `exitcode-stdio-1.0` test suite named `conformance`. Its only direct dependencies are
`base` and the declared runtime package because `Main.hs` imports the stable facade rather than
all runtime internals. It uses `default-language: GHC2024`; any specialized syntax in generated
files gets a local pragma under ADR 0019. The package is a local build artifact and is never added
to Keiro's release cohort.

The generated `src/Main.hs` runs `runServiceConformanceChecks`, compares
`serviceConformanceFacts` with `expectedServiceConformanceFacts`, prints one `PASS` or `FAIL` line
per fully qualified key, reports missing and unexpected keys separately, and exits non-zero when
any check or comparison fails. Comparison is by a validated unique-key map, not list order. An
empty facts baseline is valid for an aggregate/read-model-only service such as Mori's current
workspace.

The first scaffold creates `src/KeiroConformance/Expectations.hs` as a HoleStub containing the
current fact list:

```haskell
module KeiroConformance.Expectations (expectedServiceConformanceFacts) where

expectedServiceConformanceFacts :: [(String, String)]
expectedServiceConformanceFacts =
  []
```

For a service with process, router, or workflow facts the initial list is populated and clearly
commented as an application-owned reviewed baseline. Later scaffolds never overwrite it. A newly
added or changed fact therefore makes the runner fail until the developer accepts the new
baseline by editing this file. Do not create one expectations package or module per node.

Package file handling must obey the existing scaffold safety model. Introduce a package-local
record that stores schema version, service key, runtime package, facade module, and every generated
or create-once file. Preflight the package root before the runtime writer changes any bytes:
Generated files may be overwritten only with a recognized current or historical Keiro banner,
the Expectations file is create-if-absent, absolute and parent-escaping paths are refused, and
stale files are reported but never deleted. Compare generated bytes and report `unchanged` without
rewriting when possible. The runtime and package preflights must both succeed before either writer
runs, preserving ADR 0015's detection-before-write meaning of atomicity.

Integrate the plan and report into `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`,
`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs`, and `keiro-dsl/app/Main.hs` through additive
wrappers so existing library callers retain their signatures. Extend the scaffold report with the
package path and exact Cabal target. A successful configured run ends with output equivalent to:

```text
conformance-package: src/keiro-dsl-conformance.workspace.mori/keiro-mori-conformance.cabal
conformance-target: cabal test keiro-mori-conformance
expectations: src/keiro-dsl-conformance.workspace.mori/src/KeiroConformance/Expectations.hs (created)
```

At the end of M3 these interfaces exist, or equivalent types that preserve the same invariants:

```haskell
data ConformanceServiceKey
  = WorkspaceConformanceService !Text
  | StandaloneConformanceService !Text

data ConformancePackagePlan = ConformancePackagePlan
  { cppServiceKey :: !ConformanceServiceKey
  , cppPackageName :: !Text
  , cppRuntimePackage :: !RuntimePackageName
  , cppFacadeModule :: !Text
  , cppFiles :: ![ConformanceFile]
  }

planConformancePackage
  :: ConformanceServiceKey
  -> RuntimePackageName
  -> Text
  -> CheckedService
  -> Either [Refusal] ConformancePackagePlan

preflightConformancePackage
  :: FilePath
  -> Bool
  -> ConformancePackagePlan
  -> IO (Either [Refusal] PreparedConformancePackage)

executePreparedConformancePackage
  :: PreparedConformancePackage
  -> IO ConformancePackageReport

compareConformanceFacts
  :: [(String, String)]
  -> [(String, String)]
  -> Either [DuplicateFactKey] [ConformanceFactResult]
```

M3 is accepted when a first run creates one package and one expectation module, a second run is
observably unchanged, editing the expectation is preserved, a changed fact turns the generated
test red, a bannerless generated package file refuses the entire scaffold before runtime files
change, and a two-aggregate workspace still produces exactly one `.cabal` file.

### Milestone 4 — Mori-shaped acceptance proof and user workflow

Add a checked-in integration fixture under
`keiro-dsl/test/conformance-service-package/`. Its `.keiro-workspace` declares one service,
`runtime-package keiro-dsl-conformance-service-runtime`, a collocated module layout, and multiple
member specs. Include at least two aggregates, two read models, and one facts-producing node so
the fixture simultaneously proves one package across members, multiple self-check harnesses, and
the create-once expectation boundary. Its small runtime Cabal library compiles the generated
modules and exposes only the stable conformance facade. Check in the generated package and add
both packages to the repository `cabal.project` as test fixtures, not release packages.

Add CLI tests or a fixture regeneration script that scaffold into a temporary directory and
assert the exact package count, deterministic names, package record, stable facade, and preserved
expectations. Include a mutation acceptance: change one process/router/workflow fact in a
temporary spec, scaffold again, build without rewriting Expectations, and observe the generated
conformance test fail on the qualified fact key. Restore the source or use only the temporary tree;
never mutate a tracked expectation during the test.

Update `docs/user/typed-spec-toolchain.md` and any harness instructions in `LOOP.md`. Show a
workspace with `runtime-package`, the deterministic generated directory, one `optional-packages`
glob in the root `cabal.project`, `cabal test keiro-<service>-conformance` for developers, and the
same command in CI. Explain that the package is one per service, that member/node count does not
change package count, that Expectations is hand-owned after creation, and that the text manifest
still describes runtime-library wiring. Include a short migration note for services already
running hand-written harness drivers: configure the runtime package, expose the generated facade,
add the stable project glob, run both paths once, then remove the old driver and stanza after
equivalent results are observed.

M4 is accepted when the local fixture compiles and runs from a clean checkout, the mutation proof
turns red for the intended fact, all Keiro tests pass, formatting is clean, and the ADR bundle
validates.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/keiro` unless a command says otherwise.

Before editing, reconfirm the dependency and ADR sources rather than relying on package-memory:

```bash
mori registry show shinzui/keiro --full
mori registry show shinzui/mori --full
mori path mori://shinzui/mori/packages/mori-core
dhall type --file docs/adr/profile.dhall
```

Allocate and create the new ADR using the repository's OKF workflow, then validate it with the
documented repository command:

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
just adr-validate
```

During M1 and M2, run the focused library tests after each parser or renderer slice:

```bash
cabal test keiro-dsl-test
```

Expected tail:

```text
Test suite keiro-dsl-test: PASS
```

Regenerate the checked-in M4 fixture through the public CLI, never by calling a renderer directly:

```bash
cabal run -v0 keiro-dsl -- scaffold \
  keiro-dsl/test/conformance-service-package/service.keiro-workspace \
  --out keiro-dsl/test/conformance-service-package/runtime/src
```

The report must name one package and one target even though the fixture has several members and
nodes:

```text
conformance-package: .../keiro-dsl-conformance.workspace.workspace-proof/keiro-workspace-proof-conformance.cabal
conformance-target: cabal test keiro-workspace-proof-conformance
```

Run the generated target directly and through the repository-wide build graph:

```bash
cabal test keiro-workspace-proof-conformance
cabal build all
```

Expected result:

```text
Test suite conformance: PASS
```

Exercise idempotence with the fixture regeneration test. The second scaffold report must label
the generated Cabal file, Main, facade, and record `unchanged`, and must label Expectations
`skipped: already present`. Exercise the mutation helper; it must return non-zero and include a
specific line such as:

```text
FAIL  process/hospital-surge/maxAttempts expected="8" actual="9"
```

Before handoff or any implementation commit, format and run the complete checks required by the
repository:

```bash
nix fmt
git diff --check
cabal test keiro-dsl-test
cabal test keiro-workspace-proof-conformance
cabal build all
dhall type --file docs/adr/profile.dhall
just adr-validate
```

Implementation commits use Conventional Commits and include both required trailers:

```text
ExecPlan: docs/plans/188-generate-one-runnable-conformance-package-per-keiro-dsl-service.md
Intention: intention_01kz4bg44te47t68y68g6bjcjd
```


## Validation and Acceptance

The feature is complete only when all of these behaviors are demonstrated.

1. A workspace manifest with `service workspace-proof`, several `spec` members, and
   `runtime-package keiro-dsl-conformance-service-runtime` scaffolds exactly one directory named
   `keiro-dsl-conformance.workspace.workspace-proof` containing exactly one `.cabal` file. Adding
   a second aggregate or read model changes the facade and runner evidence but does not add a
   package.

2. Two workspaces with different `service` values and the same member context produce distinct
   package slots and distinct Cabal package names. A one-member workspace and the equivalent bare
   `.keiro` service produce the same conformance behavior, while retaining the intentionally
   distinct workspace-versus-standalone history slots.

3. `cabal test keiro-workspace-proof-conformance` executes every aggregate assertion and every
   read-model result. The output uses qualified labels, and any false result makes the test exit
   non-zero.

4. Process, router, and workflow facts are compared with the create-once service Expectations
   module. Changing a spec fact without editing Expectations produces one focused failure;
   accepting the change in Expectations restores green. Missing and unexpected keys also fail,
   so adding or deleting a node cannot silently reduce coverage.

5. A second identical scaffold does not rewrite generated package files and never overwrites
   Expectations. A bannerless Cabal file or Main at a planned generated path refuses the complete
   operation before any runtime module is changed. Removed package files are reported for review
   and never deleted.

6. A workspace or standalone scaffold with no effective runtime package has exactly the old
   generated module set, manifest bytes, record behavior, and report. Existing CLI invocations and
   library APIs remain supported.

7. The generated package compiles with only `base` and the declared runtime package. The runtime
   manifest identifies one stable facade for exposure; no per-node runtime implementation module
   becomes a new public dependency of the runner.

8. The user guide shows the complete dev and CI loop. With a one-time root project entry such as:

   ```cabal
   optional-packages:
     mori-core/src/keiro-dsl-conformance.workspace.*/*.cabal
   ```

   subsequent node/member changes require no hand-written conformance stanza or driver. The guide
   accurately says the runtime build manifest may still need reconciliation when generated runtime
   modules or dependencies change.

9. `cabal test keiro-dsl-test`, `cabal test keiro-workspace-proof-conformance`, `cabal build all`,
   `dhall type --file docs/adr/profile.dhall`, and `just adr-validate` all exit zero after `nix fmt`.


## Idempotence and Recovery

All parsing, naming, facade rendering, package rendering, and fact comparison are pure and may be
repeated. The configured scaffold remains detection-before-write: it validates the service,
runtime output, package output, banners, records, path containment, and fact-key uniqueness before
creating or changing either output tree.

Generated facade, Cabal, Main, and record files are replaceable only when their exact recognized
Keiro provenance is present. Byte-identical files are reported unchanged. The Expectations module
is created only when absent and is never overwritten, including under
`--force-generated-overwrite`; that option applies only to generated ownership. If package
generation fails after planning, fix the refusal and rerun the same scaffold command.

The tool never deletes. If a service is renamed, the old service-keyed package directory is stale
and remains for human review. Prove a stale directory is generated and clean in version control
before removing it manually. If a generated package adoption collides with a bannerless existing
file, move the existing directory aside or choose a fresh `--out`, compare the newly rendered
package, and reconcile it; never force-clobber unknown bytes.

Disabling the feature is reversible: remove the `runtime-package` clause or CLI option and rerun.
The pre-feature module and manifest paths continue to work, and the now-unused generated package
directory is left untouched. During migration, keep the old hand-written test and generated target
running together until their results agree, then delete the old test only in a separately reviewed
consumer change.


## Interfaces and Dependencies

`keiro-dsl/src/Keiro/Dsl/Workspace.hs` owns persisted workspace build metadata. Add
`wmfRuntimePackage` and its location, parser clause, canonical renderer position, and equality
behavior there. Reuse or extract the existing Cabal package-name validation rule from
`keiro-dsl/src/Keiro/Dsl/Validate.hs`; do not add the `Cabal` package merely to parse one name.

`keiro-dsl/src/Keiro/Dsl/ServiceHarness.hs` is the sole service-level facade renderer. It consumes
`CheckedService` from `keiro-dsl/src/Keiro/Dsl/SemanticContract.hs`, the `Context` placement policy
from `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, and per-node module/value names from
`keiro-dsl/src/Keiro/Dsl/Harness.hs`. It must not reparse source text or workspace members.

`keiro-dsl/src/Keiro/Dsl/ConformancePackage.hs` owns service-key-to-path naming, collision-safe
Cabal package names, the Cabal and Main renderers, the create-once expectation renderer, the
package-local record, and expected-versus-actual fact comparison. Keep the runner's generated
source limited to `base`; the runtime package already owns Keiro, Keiki, database, and application
dependencies.

`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` and
`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs` coordinate the optional package plan with existing
module planning and execution. Preserve current exported functions as wrappers passing `Nothing`;
add configured variants rather than breaking library callers. Workspace provenance treats the
facade and all package artifacts as context-level service output.

`keiro-dsl/src/Keiro/Dsl/Manifest.hs` remains authoritative for generated Haskell language and
runtime inventory. Its configured renderer identifies the stable facade that the runtime library
must expose and keeps per-node harnesses internal. Its unconfigured renderer remains byte-for-byte
compatible.

`keiro-dsl/app/Main.hs` owns CLI precedence, report rendering, and exit behavior. It passes a
validated `RuntimePackageName` into both single-file and workspace scaffold paths, and it never
discovers a package by searching the filesystem.

No new Hackage dependency is required. Continue using `base`, `text`, `containers`, and existing
Keiro DSL types already present in the package. Before changing a dependency bound or adopting a
new Cabal API, use Mori to locate the dependency source and verify the released version against
the authoritative package registry and upstream tags, as required by the repository instructions.

Revision note (2026-08-03 18:23Z): Milestone 1 implementation recorded ADR 0020, the shared
runtime-package validation seam, its passing focused evidence, and corrected the stale ADR recipe
name from `check-adr` to the repository's `adr-validate`.
