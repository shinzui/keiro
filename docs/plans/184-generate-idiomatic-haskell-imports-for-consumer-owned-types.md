---
id: 184
slug: generate-idiomatic-haskell-imports-for-consumer-owned-types
title: "Generate idiomatic Haskell imports for consumer-owned types"
kind: exec-plan
created_at: 2026-08-03T13:04:36Z
intention: "intention_01kz3vdgp7ecttr8wnsrr8p66f"
---

# Generate idiomatic Haskell imports for consumer-owned types

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro currently renders consumer-owned Haskell types by spelling their complete module
path at every use site. A Mori declaration therefore becomes code such as:

```haskell
artifactId :: !Mori.Modules.Project.Domain.Types.ProjectArtifactId
```

That code compiles, but it is noisy, unlike ordinary hand-written Haskell, and becomes
especially hard to scan in generated records and codecs. After this change Keiro will
plan imports for every generated Haskell module and render the same declaration in an
idiomatic form, normally:

```haskell
import Mori.Modules.Project.Domain.Types (ProjectArtifactId)

artifactId :: !ProjectArtifactId
```

When two imported modules expose the same type name, or when a generated value or
constructor needs qualification, Keiro will allocate stable short aliases instead of
falling back to complete module paths. For example, two colliding `Status` types may be
rendered as `OrderTypes.Status` and `InvoiceTypes.Status`. The exact alias is generated
deterministically from the shortest unique module suffix, so regenerating an unchanged
workspace remains byte-for-byte stable.

The result is visible by scaffolding the checked-in conformance workspaces and by
scaffolding the current Mori workspace in a disposable copy. Generated Haskell must
compile, contain no type reference prefixed by a complete consumer module path, and
remain identical on a second scaffold run.


## Progress

- [x] (2026-08-03T13:34:16Z) Milestone 0: recorded the presentation contract in
      seven intentionally failing planner examples, added the checked collision fixture, and
      confirmed all 514 pre-existing unit examples still pass.
- [ ] Milestone 1: implement the central Haskell import and reference planner.
- [ ] Milestone 2: migrate every Haskell emitter and new-file skeleton to the planner.
- [ ] Milestone 3: add compiled collision conformance coverage and regenerate baselines.
- [ ] Milestone 4: prove the result against a disposable Mori adoption, update durable
      documentation, and pass the full release gates.


## Surprises & Discoveries

- Observation: the undesirable spelling is deliberate rather than a formatter artifact.
  `aggregateHaskellType` in `keiro-dsl/src/Keiro/Dsl/AggregateType.hs` concatenates the
  consumer module and type with `.` while `aggregateImports` emits the module as an
  unaliased qualified import.

- Observation: this is not confined to aggregate record fields. `Keiro.Dsl.Scaffold`
  and `Keiro.Dsl.Harness` independently construct fully qualified references for nominal
  representations, structural shapes, bindings, fixtures, initial values, codecs, and
  transducers. Fixing only `aggregateHaskellType` would leave the output inconsistent.

- Observation: the current Mori adoption contains 1,461 `Mori.Modules...` references
  across 34 generated Haskell modules. Its generated codec also contains an identical
  qualified import twice. Import planning should therefore own deduplication as well as
  reference spelling.

- Observation: generated conformance directories are intentionally excluded from
  Fourmolu in `nix/treefmt.nix`. Keiro's renderer, not a later formatter pass, must own
  readable layout and deterministic bytes.

- Observation: Hackage and the upstream `keiro-dsl-0.9.0.0` tag both identify 0.9.0.0
  as the current release, and Mori pins that version. This plan makes Keiro release-ready
  and proves downstream compatibility without changing Mori's pin or publishing a release.

- Observation: a test component cannot import a library module listed under `other-modules`,
  while adding the complete `src` directory to the existing `keiro-dsl-test` source roots
  makes every library module a test home module and exposes undeclared transitive dependencies.
  Evidence: the attempted shared source root produced `-Wmissing-home-modules` followed by
  hidden-package errors for `prettyprinter`, `megaparsec`, and `time`. The focused tests now
  compile only `Keiro.Dsl.HaskellImport` beside a small test driver.


## Decision Log

- Decision: represent Haskell imports and references as structured data and render them
  once per generated module; do not post-process generated text.
  Rationale: all emitters need the same collision, alias, deduplication, and ordering rules.
  Rewriting text after generation would be unable to distinguish code references from
  strings, provenance, or comments and would make correctness depend on incidental layout.
  Date: 2026-08-03.

- Decision: import a consumer-owned type unqualified when its occurrence name is unique
  in the module and does not conflict with a locally declared or reserved name.
  Rationale: this is the least noisy normal Haskell style and directly addresses the
  reported `ProjectArtifactId` output.
  Date: 2026-08-03.

- Decision: keep consumer-owned values, constructors, generated shape APIs, and nominal
  representation APIs qualified, but use a stable short alias.
  Rationale: qualification communicates provenance where names such as `toDomain`,
  `shape`, `initial`, or constructors are otherwise ambiguous, without repeating a full
  module path.
  Date: 2026-08-03.

- Decision: derive aliases from the shortest unique suffix of module components, joined
  in UpperCamelCase, expanding leftward until unique. Avoid aliases already used by a
  local module, a planned import, or the renderer's reserved qualifier set. If joined
  suffixes themselves collide, use an underscore-joined full-component fallback.
  Rationale: aliases such as `Types`, `OrderTypes`, and `ConsumerOrderTypes` remain short,
  meaningful, deterministic, and total even for unusual module names.
  Date: 2026-08-03.

- Decision: do not add an alias clause to the `.keiro` language and do not bump a language
  or runtime version.
  Rationale: qualification is a Haskell presentation concern. The resolved semantic graph,
  ownership, wire contract, fingerprints, and runtime behavior do not change.
  Date: 2026-08-03.

- Decision: preserve complete module names in manifests, scaffold history, fingerprints,
  binding explanations, diagnostics, and provenance strings.
  Rationale: those values identify source declarations; shortening them would change data
  or make diagnostics ambiguous. Only emitted Haskell syntax changes.
  Date: 2026-08-03.

- Decision: update templates used only when Keiro creates a missing skeleton, but never
  rewrite an existing hand-owned skeleton merely to change its import style.
  Rationale: ADR-0015's ownership boundary takes precedence over cosmetic consistency.
  Date: 2026-08-03.

- Decision: keep publishing Keiro and changing Mori's dependency pin outside this plan.
  Rationale: the implementation can be validated from a local Keiro checkout in a
  disposable Mori copy. Release and downstream upgrade are separate reversible operations.
  Date: 2026-08-03.

- Decision: exercise the internal planner through the private
  `keiro-dsl-import-planning-test` Cabal component rather than expose it or add `src` to the
  existing test component.
  Rationale: this keeps `Keiro.Dsl.HaskellImport` out of the package API while giving its
  deterministic allocation rules direct white-box coverage without recompiling the full
  library as test-owned modules.
  Date: 2026-08-03.


## Outcomes & Retrospective

Milestone 0 added `keiro-dsl/test/import-planning/Main.hs`, the internal-module stub at
`keiro-dsl/src/Keiro/Dsl/HaskellImport.hs`, and
`keiro-dsl/test/fixtures/import-planning-collisions.keiro`. The seven new examples fail with
`HaskellImportPlanningUnavailable "Generated.Example"`, which is the expected pre-implementation
state. `cabal test keiro-dsl-test` passes all 514 pre-existing examples, and `cabal run keiro-dsl
-- check keiro-dsl/test/fixtures/import-planning-collisions.keiro` reports `OK`.

At each later milestone, record the files changed, tests run, and any deviation from the import
contract here. Before completion, distill the final presentation rules into ADR-0012 and summarize
whether the disposable Mori proof removed the 1,461 baseline references without changing semantic
artifacts.


## Context and Orientation

Keiro DSL reads one or more `.keiro` files, resolves them into a semantic workspace, and
scaffolds Haskell modules. A **consumer-owned type** is a Haskell type named in the DSL but
defined by the application that consumes generated code. A **generated shape** or
**generated nominal representation** is a Keiro-emitted Haskell module that supplies the
structural or nominal boundary selected by the resolved workspace. An **occurrence name**
is the last Haskell identifier, such as `ProjectArtifactId`, used at a reference site.

The current spelling originates in several places:

* `keiro-dsl/src/Keiro/Dsl/AggregateType.hs` contains `aggregateHaskellType`, which emits
  `hsModule <> "." <> hsType`, and `aggregateImports`, which emits qualified imports.
* `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` renders Domain, Codec, NominalProjections,
  StructuralProjections, and Transducer modules. Helpers including `renderHaskellSource`
  and `qualifiedModule` construct references independently.
* `keiro-dsl/src/Keiro/Dsl/Harness.hs` renders conformance harness bindings, fixtures,
  owner types, and structural shapes and also constructs complete qualified references.
* `keiro-dsl/test/conformance-baseline.json` inventories generated conformance artifacts.
  Existing compiled suites include `keiro-dsl-conformance-nominal-scalars`,
  `keiro-dsl-conformance-structural`, and
  `keiro-dsl-conformance-behavior-complete` in `keiro-dsl/keiro-dsl.cabal`.
* `nix/treefmt.nix` excludes generated conformance directories from Fourmolu, so tests must
  compare Keiro's bytes directly.

The downstream proof target is the current adoption in the canonical project
`mori://shinzui/mori/repos/mori`. Mori's `Justfile` pins `keiro-dsl-0.9.0.0` and exposes
`keiro-check` and `keiro-scaffold` commands for `domain/mori.keiro-workspace`. Its current
working tree contains adoption work, so validation must copy it with `rsync` to a temporary
directory and must not edit the registered checkout.

The relevant durable decisions are:

* [ADR-0012](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
  requires one resolved authority for aggregate lowering and imports, and requires shape
  imports to remain qualified. This plan extends that central-authority rule to presentation
  planning and interprets “qualified” as a stable alias rather than a complete module name.
* [ADR-0014](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
  requires generation from the complete workspace graph and order-independent bytes. Alias
  allocation must therefore consider the complete target module, not traversal order.
* [ADR-0015](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
  requires byte-idempotent scaffolding and forbids overwriting existing hand-owned
  skeletons. Import cleanup cannot weaken either property.
* [ADR-0016](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
  freezes released DSL language surfaces and separates source provenance from the semantic
  graph. The change remains a renderer presentation change, not a language feature.

Checked-in historical context is in
`docs/plans/150-add-structural-consumer-type-mappings-to-the-keiro-language.md`,
`docs/plans/158-add-nominal-consumer-bindings-to-the-keiro-language.md`, and
`docs/plans/179-generate-human-readable-transducers.md`. The first two introduced the
consumer references now being rendered; the third establishes readable deterministic
generated Haskell as an accepted goal.


## Plan of Work

### Milestone 0: Freeze the presentation contract

Add focused unit tests to `keiro-dsl/test/import-planning/Main.hs` in the private
`keiro-dsl-import-planning-test` component. The component compiles only the internal planner
module beside the test driver, keeping the planner out of the package API. The tests must describe
the desired result before implementation: a unique external
type is explicitly imported and unqualified; duplicate occurrence names are qualified by
different short aliases; value and constructor references are short-qualified; imports are
deduplicated and sorted; local and reserved names force qualification; input declaration
order does not change the rendered result.

Add `keiro-dsl/test/fixtures/import-planning-collisions.keiro`. It must include at least two
consumer type modules exporting the same occurrence name, two module paths whose shortest
suffix is the same, a consumer type whose occurrence name conflicts with a locally emitted
name, repeated references to one binding module, a structural shape, and a nominal
representation. Keep the fixture intentionally small: its purpose is to exercise namespace
planning, not every domain feature.

At the end of this milestone the new tests fail for explicit, reviewed reasons while the
existing suite remains green. Record the expected failures in Progress rather than leaving
the plan state ambiguous.

### Milestone 1: Centralize import and reference planning

Add the internal module `keiro-dsl/src/Keiro/Dsl/HaskellImport.hs` and list it under
`other-modules` in `keiro-dsl/keiro-dsl.cabal`; do not expose a new package API. This module
accepts all external Haskell references and all locally declared names for one generated
module, validates module/type/value identifiers using the same assumptions as the existing
renderer, allocates imports and aliases over the complete set, and returns an opaque plan.

The planner has three presentation choices. A unique external type prefers an explicit
unqualified import. A colliding or reserved type becomes qualified. Values and constructors
always prefer qualification. A qualified reference gets the shortest alias derived from a
unique suffix of its module; aliases and imports are then sorted independently of discovery
order. Identical imports collapse to one declaration, while distinct explicit imports from
the same module merge into one sorted import list.

Keep Haskell syntax rendering in this module. Callers request a reference by its semantic
module/name/namespace key rather than concatenating strings. Missing keys and impossible
alias allocations are programmer errors reported with target-module context; they must not
silently reintroduce a full module reference.

At the end of this milestone all Milestone 0 planner tests pass. Existing generators need
not use the planner yet.

### Milestone 2: Migrate every emitter

Change `aggregateHaskellType` and `aggregateImports` in
`keiro-dsl/src/Keiro/Dsl/AggregateType.hs` to contribute structured references to the plan.
Expose a single aggregate-source description to callers rather than separate spelling logic
for a field and its import. Preserve the resolved consumer authority selected by ADR-0012.

Change `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` so each target module first gathers its local
declarations and external references, builds one import plan, then renders Domain, Codec,
NominalProjections, StructuralProjections, and Transducer through that plan. Remove or narrow
`qualifiedModule`, `renderHaskellSource`, and any helper that can emit an arbitrary
`module.name` string. Do not route manifest JSON, fingerprints, diagnostics, history, or
binding explanations through the Haskell presentation planner.

Change `keiro-dsl/src/Keiro/Dsl/Harness.hs` in the same way for owner types, bindings,
fixtures, initial values, shape constructors/selectors, and nominal representations. Ensure
every source module has one final import set so repeated binding references cannot produce
duplicate import lines.

Update templates for newly created consumer skeletons to follow the same explicit-import
style. Retain the existing “create only when absent” guards: this change must not rewrite a
file owned by the consumer. At the end of this milestone the existing focused conformance
suites compile, and a repository search finds no remaining renderer concatenation that can
produce a complete consumer reference in Haskell syntax.

### Milestone 3: Compile collisions and regenerate baselines

Add a `keiro-dsl-conformance-import-planning` test-suite component to
`keiro-dsl/keiro-dsl.cabal`. Scaffold the collision fixture into a checked-in generated
directory, add the minimal consumer modules needed for its imports, and compile representative
Domain, Codec, projection, transducer, and harness modules. A text snapshot alone is
insufficient because ambiguous imports and incorrect constructor namespaces are compiler
errors.

Regenerate every affected conformance snapshot and update
`keiro-dsl/test/conformance-baseline.json` through the existing scaffold/baseline workflow.
Inspect the diff rather than mechanically accepting it. Expected differences are imports,
short aliases, deduplication, and corresponding reference spellings only. Semantic values,
wire names, declaration order, manifests, fingerprints, and provenance must be unchanged.

Run each focused conformance suite and the new collision suite twice: once after deleting or
refreshing generated outputs through the established scripts, then again without edits. The
second run must leave `git diff` empty relative to the first generated state.

### Milestone 4: Downstream proof, durable decisions, and release gates

Use `mori path mori://shinzui/mori/repos/mori` to locate the registered Mori checkout. Copy
it into a `mktemp -d` directory with `rsync`, excluding `.git`, `dist-newstyle`, `.direnv`,
and `result*`. In that disposable copy, invoke the Keiro DSL executable from this checkout
to check and scaffold `domain/mori.keiro-workspace`, then build `mori-core`. Never run the
new renderer directly against Mori's dirty registered checkout.

Compare the disposable result with its pre-scaffold copy. Confirm that the known 1,461
complete `Mori.Modules...` Haskell references become explicit imports or short aliases,
that duplicate imports disappear, that generated artifacts compile, and that a second
scaffold is byte-idempotent. Preserve exact module names in non-Haskell identity data.

Update the `keiro-dsl` changelog and user-facing generation documentation with the new
presentation contract and collision behavior. Amend ADR-0012 using the repository's OKF
workflow only after compiled Keiro and Mori evidence establishes the final rule. State that
qualification is deterministic short aliasing, consumer types prefer explicit imports, and
semantic authority is unchanged. Finish with all package, sdist, mutation, formatting,
flake, and strict ADR validation gates.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/keiro` unless a command explicitly
changes directory. Begin by preserving the release baseline and dependency evidence:

```bash
curl -fsSL https://hackage.haskell.org/package/keiro-dsl/preferred.json
git rev-parse HEAD
git rev-list -n 1 keiro-dsl-0.9.0.0
mori registry show shinzui/mori --full
```

The Hackage result should include `0.9.0.0`; the peeled release tag and starting checkout
should identify the same source revision. If the registry name changes, rediscover it with
`mori registry list` and update the canonical reference in this plan before proceeding.

During Milestones 0 and 1, run the focused unit test:

```bash
cabal test keiro-dsl-import-planning-test
```

Expected final transcript includes:

```text
Test suite keiro-dsl-import-planning-test: PASS
```

Exercise existing generator surfaces during Milestone 2:

```bash
cabal test keiro-dsl-conformance-nominal-scalars
cabal test keiro-dsl-conformance-structural
cabal test keiro-dsl-conformance-behavior-complete
rg -n 'hsModule|qualifiedModule|renderHaskellSource|<>[[:space:]]*"\\."' keiro-dsl/src/Keiro/Dsl
```

The three suites must pass. Review every remaining search hit; a remaining concatenation is
acceptable only when it creates identity/provenance data rather than emitted Haskell syntax,
and that distinction must be recorded in Surprises & Discoveries.

In Milestone 3, scaffold through the repository's existing conformance commands discovered
from `keiro-dsl/keiro-dsl.cabal` and the neighboring mutation scripts, then run:

```bash
cabal test keiro-dsl-conformance-import-planning
cabal test keiro-dsl-conformance-nominal-scalars
cabal test keiro-dsl-conformance-structural
cabal test keiro-dsl-conformance-behavior-complete
git diff -- keiro-dsl/test keiro-dsl/src
git diff --check
```

The collision component and existing components must pass. The diff must show only intended
presentation changes plus the new fixture and tests.

For the Mori proof, derive every path explicitly and validate it before mutation:

```bash
KEIRO_ROOT="$PWD"
MORI_SOURCE="$(mori path mori://shinzui/mori/repos/mori)"
MORI_PROOF="$(mktemp -d)/mori-import-proof"
test -d "$MORI_SOURCE/domain"
mkdir -p "$MORI_PROOF"
rsync -a --exclude=.git --exclude=dist-newstyle --exclude=.direnv --exclude='result*' "$MORI_SOURCE/" "$MORI_PROOF/"
cd "$MORI_PROOF"
cabal run --project-file="$KEIRO_ROOT/cabal.project" keiro-dsl -- check domain/mori.keiro-workspace
cabal run --project-file="$KEIRO_ROOT/cabal.project" keiro-dsl -- scaffold domain/mori.keiro-workspace
cabal build mori-core
```

If the executable component name or CLI argument order differs, inspect the local
`keiro-dsl/keiro-dsl.cabal` and `--help` output and update this plan before using the corrected
command. Do not guess and do not substitute the released Mori-pinned executable.

Before the first scaffold, save a second disposable copy or a checksummed file inventory.
After it, search only the disposable source tree:

```bash
rg -n 'Mori\.Modules\.[A-Z][A-Za-z0-9_.]*\.[A-Z][A-Za-z0-9_]*' domain src test
cabal run --project-file="$KEIRO_ROOT/cabal.project" keiro-dsl -- scaffold domain/mori.keiro-workspace
cabal build mori-core
```

Run the `rg` command separately because exit status 1 is the expected success result: no
complete consumer module reference remains in generated Haskell. The second scaffold must
make no further changes. Keep the temporary proof directory for diagnosis until all checks
pass; afterwards it may be removed by its exact printed path.

After the implementation has proved the contract, update ADR-0012 through OKF and validate:

```bash
okf log add docs/adr ADR-12 --profile docs/adr/profile.dhall --content-file /tmp/keiro-adr-12-import-planning.md
dhall type --file docs/adr/profile.dhall
okf validate docs/adr --profile docs/adr/profile.dhall --strict
```

Use a task-specific temporary file created with `mktemp` instead of the illustrative `/tmp`
name if the command is executed. The content must summarize durable evidence and decisions,
not copy the ExecPlan's task log.

Finish from the Keiro root with:

```bash
cabal test all
cabal build all
cabal sdist all
bash keiro-dsl/test/structural-mutation-test.sh
bash keiro-dsl/test/conformance-nominal-scalars/mutations/dishonest-exact.sh
bash keiro-dsl/test/conformance-nominal-scalars/mutations/enum-transpose.sh
bash keiro-dsl/test/conformance-nominal-scalars/mutations/id-one-direction.sh
bash keiro-dsl/test/conformance-nominal-scalars/mutations/scalar-wire.sh
nix fmt
nix flake check
git diff --check
git status --short
```

If mutation script names have changed, enumerate `keiro-dsl/test/*mutation*.sh`, document
the replacement, and run every applicable structural and nominal script. Commit only after
all gates pass, using a Conventional Commit and these traceability trailers:

```text
refactor(keiro-dsl): generate idiomatic Haskell imports

ExecPlan: docs/plans/184-generate-idiomatic-haskell-imports-for-consumer-owned-types.md
Intention: intention_01kz3vdgp7ecttr8wnsrr8p66f
```


## Validation and Acceptance

The change is accepted only when all of these behaviors are demonstrated:

1. Given one consumer type
   `Mori.Modules.Project.Domain.Types.ProjectArtifactId`, a generated module contains an
   explicit import of `ProjectArtifactId` and uses `ProjectArtifactId` at the field site.
   It does not contain the complete module-qualified occurrence.

2. Given two external `Status` types, generated code compiles and renders distinct stable
   qualified references such as `OrderTypes.Status` and `InvoiceTypes.Status`. Reordering
   their DSL declarations does not change either alias or any generated bytes.

3. Given repeated references to one external value or generated shape constructor, the
   target module contains one qualified import with one short alias and all sites use that
   alias. Exact duplicate import declarations are absent.

4. Given a consumer type that conflicts with a local declaration, a reserved qualifier, or
   another imported occurrence, the planner selects qualification rather than producing an
   ambiguous import. The collision conformance component compiles this behavior.

5. Existing nominal, structural, behavior-complete, codec, projection, transducer, and
   harness conformance components compile. Snapshot changes are limited to import/reference
   presentation and expected deduplication.

6. Scaffolding any checked-in workspace twice produces identical bytes on the second run.
   Reordering equivalent workspace inputs remains byte-stable.

7. Scaffolding the disposable Mori workspace with the local Keiro executable removes the
   baseline complete `Mori.Modules...` references from generated Haskell, removes known
   duplicate imports, and `cabal build mori-core` succeeds. Mori's registered checkout is
   unchanged.

8. Manifests, fingerprints, source provenance, scaffold history, wire names, and diagnostics
   retain exact semantic module identities. No DSL language version, runtime version, or
   released package bound changes.

9. `cabal test all`, `cabal build all`, `cabal sdist all`, applicable mutation scripts,
   `nix fmt`, `nix flake check`, strict ADR validation, and `git diff --check` all succeed.


## Idempotence and Recovery

Unit tests, Cabal builds, searches, formatting, and validations are repeatable. Existing
conformance regeneration is intended to be repeatable; always inspect `git diff` after a
run and preserve unrelated user changes. Never use `git reset --hard` or a broad restore to
recover. Revert only files introduced or changed by this plan with an explicit patch.

The Mori proof is isolated by design. Resolve the source with Mori, validate that the
result contains `domain/mori.keiro-workspace`, then copy it into a fresh `mktemp -d`
directory. A failed proof can be retried from a new copy without touching the registered
checkout. Do not interpolate an unchecked or empty variable into a deletion command; print
and verify the exact temporary path before removing it.

If alias planning uncovers a collision not covered by the suffix algorithm, first add it as
a failing planner and compiled conformance case. Extend the deterministic allocator rather
than special-casing a project or emitting a complete module path. If an emitter cannot be
migrated safely in one edit, retain the old behavior behind that emitter, record the partial
state in Progress, and do not regenerate its accepted snapshot until its compiled coverage
passes.

ADR amendment is deliberately late. If implementation evidence changes the intended rule,
update the Decision Log first, rerun the focused proof, and only then record the proven rule
in ADR-0012. Publishing packages or updating Mori's released dependency pin requires a
separate explicit task and is not a recovery step for this plan.


## Interfaces and Dependencies

Add an internal `Keiro.Dsl.HaskellImport` module with an interface equivalent to the
following. Exact constructor visibility may be narrowed, but callers must not be able to
render a planned reference by concatenating module and occurrence strings themselves.

```haskell
data HaskellNamespace
  = TypeNamespace
  | ValueNamespace
  | ConstructorNamespace

data QualificationPreference
  = PreferUnqualified
  | RequireQualified

data HaskellReference = HaskellReference
  { referenceModule :: Text
  , referenceName :: Text
  , referenceNamespace :: HaskellNamespace
  , referenceQualification :: QualificationPreference
  }

data ImportEnvironment = ImportEnvironment
  { targetModule :: Text
  , localNames :: Set Text
  , reservedQualifiers :: Set Text
  }

data HaskellImportPlan

planHaskellImports
  :: ImportEnvironment
  -> Set HaskellReference
  -> Either HaskellImportError HaskellImportPlan

renderPlannedImports :: HaskellImportPlan -> Text

renderPlannedReference
  :: HaskellImportPlan
  -> HaskellReference
  -> Either HaskellImportError Text
```

Use the project's existing `text`, `containers`, and rendering dependencies; do not add a
Haskell parser, pretty-printer, or formatter dependency solely for this change. Prefer typed
module and occurrence wrappers already present in the resolved DSL graph if they can satisfy
the contract without lossy conversion. `HaskellImportPlan` should internally retain a map
from the full `HaskellReference` key to its rendered occurrence and a normalized set of
import declarations.

`Keiro.Dsl.AggregateType` must expose an aggregate source description that carries both the
type syntax tree/reference keys and the imports needed to render it. The final name can fit
the surrounding API, but its role should be equivalent to:

```haskell
aggregateConsumerHaskellSource
  :: ResolvedAggregateType
  -> Either HaskellImportError HaskellSourceReferences
```

`Keiro.Dsl.Scaffold` and `Keiro.Dsl.Harness` gather all
`HaskellSourceReferences` for one target module, add local declarations, call
`planHaskellImports` once, and use that one plan for its imports and every reference site.
No emitter may independently choose an alias.

Alias allocation must reserve the qualifiers already used by generated code, including at
least `Map`, `Set`, `T`, `K`, `B`, `S`, and `KindID`, plus each locally declared module
alias. Treat the actual current import sets in Scaffold and Harness as authoritative while
implementing this list; add every discovered fixed qualifier to the planner input and tests.

There is no new external service or runtime dependency. Mori is used to locate the
downstream source and its documentation; Hackage and upstream tags establish the current
released baseline. The Mori project remains referenced canonically as
`mori://shinzui/mori/repos/mori` in durable text.


## Revisions

- 2026-08-03: Created the ExecPlan from intention
  `intention_01kz3vdgp7ecttr8wnsrr8p66f` after tracing all Haskell emitters, inspecting the
  current Mori adoption, verifying the 0.9.0.0 release baseline, and reviewing ADR-0012,
  ADR-0014, ADR-0015, and ADR-0016.
- 2026-08-03: Recorded Milestone 0 evidence and moved direct planner coverage into a dedicated
  private Cabal test component after Cabal proved that the hidden library module could not be
  imported safely through the existing test component.
