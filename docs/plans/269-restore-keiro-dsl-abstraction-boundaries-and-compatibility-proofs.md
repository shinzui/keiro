---
id: 269
slug: restore-keiro-dsl-abstraction-boundaries-and-compatibility-proofs
title: "Restore keiro-dsl abstraction boundaries and compatibility proofs"
kind: exec-plan
created_at: 2026-08-30T11:53:37Z
intention: intention_01m199s6p5eb5tdzyg6q7qmmqc
---

# Restore keiro-dsl abstraction boundaries and compatibility proofs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The record modernization between `keiro-0.14.0.0` and the prospective 0.15 release made
record fields concise, but it also made several constructors public that were intentionally
hidden. Most seriously, a library caller can now manufacture values named
`PreparedSidecarMove` and `PreparedGeneratedHaskellEditionMigration` instead of obtaining them
from the filesystem preflight that proves an apply is safe. One fabricated sidecar value can
reach an `error` branch in `applyPreparedSidecarMoves`; a fabricated generated-edition value can
ask the apply function to copy or write caller-selected paths. Three other types that represented
checked or internally consistent state also became constructible solely so internal modules could
use record-dot syntax.

After this plan, the public package surface again distinguishes descriptive values from checked
capabilities. A caller may inspect the public impact of a prepared migration, but only the
preflight functions can create a value accepted by an apply function. `AggregateHaskellSource`,
`NominalTypeRegistry`, and `ChangeContext` recover their 0.14 abstract boundaries and their
supported projection functions. The lexical generated-Haskell rewriter remains directly testable
inside the package without publishing its state machine as a supported `keiro-dsl` module.

The test story also becomes literal. Repository-only migration inventories run as repository
policy, not three identically implemented Hspec claims and not a test that fails from the Hackage
source distribution when `scripts/` is absent. Package tests compare named JSON and ledger
contracts to exact checked-in bytes. A small API-boundary policy fails if a protected constructor
or any future `Prepared*` constructor is exported. A maintainer can demonstrate the result by
running the focused policy and package tests, building every `keiro-dsl` component, testing the
unpacked source distribution, and finally running `just verify`.

This plan intentionally excludes version bumps, dependency-bound rewrites, upgrade blueprints,
release-note edits, tags, uploads, and every other release-preparation task. It fixes the code and
test findings from the 0.14-to-HEAD review only.


## Progress

- [x] (2026-08-30T12:21:45Z) Created and attached intention
  `intention_01m199s6p5eb5tdzyg6q7qmmqc`; captured a green pre-change baseline for both repository
  policies and all three focused Hspec groups. The branch was `master`, one commit ahead of
  `origin/master`, with no pre-existing worktree edits beyond this plan's new intention field.
- [x] (2026-08-30T12:32:45Z) Implemented Milestone 1's opaque constructor boundaries, restored
  the 0.14 projections, and made prepared sidecar application total. Both migration-focused Hspec
  groups pass; a full 720-example package run reached 717 passes and only the three identical
  migration-inventory aliases failed because the restored public-field counts made the checked-in
  manifest stale.
- [x] (2026-08-30T12:33:54Z) Regenerated and rechecked the migration inventories early so the
  Milestone 1 commit remains a green repository state; this completed the originally
  Milestone 2-owned regeneration ahead of schedule.
- [x] (2026-08-30T12:33:54Z) Milestone 1: restored opaque semantic and prepared-migration types
  and made prepared sidecar application total. The two focused migration suites and refreshed
  inventory policy pass; `git diff --check` is clean, and the full-suite evidence is the prior
  717 behavioral passes plus the now-green inventory alias.
- [x] (2026-08-30T12:38:21Z) Added the Milestone 2 private Cabal component and executable API
  boundary policy with accepted/rejected self-tests. The first component build proved that a
  module under the main library's `hs-source-dirs: src` remains a GHC home-module candidate even
  when Cabal also exposes it from a same-package dependency.
- [x] (2026-08-30T12:38:21Z) Moved `Keiro.Dsl.GeneratedHaskellLanguage` to the private
  component's dedicated source root, updated the API and inventory policies for that ownership,
  and reran the component build matrix successfully.
- [x] (2026-08-30T12:45:35Z) Finished Milestone 2 validation after repository formatting. The
  policy self-test, real-tree policy, `just dsl-api-boundaries`, inventory freshness check, exact
  component build, one-occurrence Cabal inspection, focused generated-language and migration
  suites, and `git diff --check` all pass.
- [x] (2026-08-30T12:45:35Z) Milestone 2: made the generated-Haskell language implementation
  package-private and added an executable public-boundary policy.
- [x] (2026-08-30T13:33:33Z) Removed the three repository-script Hspec aliases, added the honest
  `record-migration-policy` repository gate, and replaced broad compatibility claims with five
  separately named exact byte oracles. The focused check-report, diff-report, and record-migration
  groups pass, as do all 719 main-suite examples and every `keiro-dsl:tests` conformance component.
- [x] (2026-08-30T13:59:23Z) The first unpacked-sdist run proved the new byte fixtures portable but
  exposed nine older repository-layout assumptions. Packaged the complete test corpus and made the
  Git scan, consumer compilation probes, generic failure fixtures, and sibling-package integration
  boundary source-distribution aware. The final clean archive at
  `/tmp/keiro-dsl-sdist-test.AzgSaQ/keiro-dsl-0.14.0.0.tar.gz` passed all 719 examples with zero
  failures.
- [x] (2026-08-30T13:59:23Z) Milestone 3: separate repository inventory policy from portable
  package tests and add exact compatibility byte oracles.
- [x] (2026-08-30T14:24:52Z) Renamed the three library bindings that shadowed record labels or
  Prelude names. Both libraries build with `-Werror=name-shadowing`; formatting, API-boundary,
  inventory, extension, Cabal-package, and strict ADR validation all pass.
- [x] (2026-08-30T14:24:52Z) Updated ADR 0038 and its OKF log to state that concise labels do not
  widen constructor authority, prepared values preserve preflight provenance, and private Cabal
  components provide implementation observability without public exposure.
- [x] (2026-08-30T14:24:52Z) `just verify` passed the complete repository matrix, including all
  719 `keiro-dsl` examples and 39 conformance-corpus invocations. A final archive at
  `/tmp/keiro-dsl-final-sdist.lQjjUf/keiro-dsl-0.14.0.0.tar.gz` also passed all 719 examples.
- [x] (2026-08-30T14:24:52Z) Milestone 4: remove the record-migration warning regressions, distill
  the durable boundary, and pass the full validation matrix.


## Surprises & Discoveries

- Observation: The prescribed no-`sidecarMove` search also matches the unrelated plural report
  field `.sidecarMoves`, so its stated expectation of no output is impossible without a word
  boundary. The constructor-authority search itself is clean.
  Evidence:

  ```text
  keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs:897:    sidecarMoveSection = case (.sidecarMoves) report of
  keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs:1976:    sidecarMoveSection = case (.sidecarMoves) report of
  ```

- Observation: Every behavioral example passed after the Milestone 1 refactor; all three full-suite
  failures were aliases of the same stale generated-inventory check, not runtime or API behavior.
  Evidence:

  ```text
  Finished in 214.7096 seconds
  720 examples, 3 failures
  stale record migration manifest: keiro-dsl/record-field-migration-0.15.md
  ```

- Observation: A named private sublibrary cannot exclusively own a module while that module's
  source file remains under the main library's source root. GHC discovers it as a home module,
  compiles main-unit references, and the executable cannot link those references against the
  private unit.
  Evidence:

  ```text
  warning: [-Wmissing-home-modules]
  These modules are needed for compilation but not listed in your .cabal file's other-modules:
      Keiro.Dsl.GeneratedHaskellLanguage
  Undefined symbols ... keiro-dsl-0.14.0.0-inplace_Keiro.Dsl.GeneratedHaskellLanguage
  ```

- Observation: The repository Cabal formatter canonicalizes a one-module `exposed-modules` field
  onto the field's own line, so validation must count the module occurrence rather than require a
  multiline indentation shape.
  Evidence:

  ```text
  exposed-modules: Keiro.Dsl.GeneratedHaskellLanguage
  ```

- Observation: The existing check-report and diff-report text goldens carried a final newline only
  because their previous assertions stripped trailing whitespace. The CLI and `Aeson.encode`
  produce no final newline.
  Evidence: the first exact check-report comparison differed only by byte 0x0a at EOF.

- Observation: Cabal rejects an extensionless `test/**/*` `extra-source-files` glob as
  non-portable, and an unpacked package has no repository `cabal.project` to enable tests.
  Evidence: `cabal check` reported `glob-syntax-error`; the first standalone invocation required
  `cabal test --enable-tests keiro-dsl-test` before the solver included the test component.

- Observation: After packaging the fixture corpus, the first archive-only main-suite run reached
  710 passes and nine failures. All nine were older repository assumptions: two Git/worktree
  queries, two ad-hoc GHC package-environment probes, four sibling `keiro-core` fixture paths, and
  one nested build whose project named sibling source packages.
  Evidence:

  ```text
  Finished in 21.8467 seconds
  719 examples, 9 failures
  ```

- Observation: Selecting `-package keiro-core` fixed repository compile probes but exposed every
  installed unit with that package name in a standalone build. The second archive reduced the
  failures to the six compile probes, all reporting ambiguous `keiro-core-0.14.0.0` modules.
  Reading Cabal's `dist-newstyle/cache/plan.json` selects the one configured library unit in both
  layouts: `keiro-core-0.14.0.0-inplace` in the repository and `kr-cr-0.14.0.0-ec1d0c37` in the
  source archive.
  Evidence:

  ```text
  Finished in 22.6571 seconds
  719 examples, 0 failures
  ```


## Decision Log

- Decision: Treat a type consumed by an apply function after filesystem preflight as an opaque
  capability, not as a public record merely because internal code wants record-dot projections.
  Rationale: The useful guarantee is that successful preflight is the only construction path.
  Exporting a constructor converts that guarantee into a naming convention and makes invalid or
  unchecked filesystem operations representable.
  Date: 2026-08-30

- Decision: Restore the exact 0.14 abstraction intent for `AggregateHaskellSource`,
  `NominalTypeRegistry`, `ChangeContext`, and `PreparedSidecarMove`; add only the explicit
  projections needed by callers. Leave `BehaviorRequirement` constructible.
  Rationale: The first four types were abstract at `keiro-0.14.0.0`. `BehaviorRequirement` was
  already exported with its constructor at that tag, so hiding it would be a new design change,
  not a repair of the record migration.
  Date: 2026-08-30

- Decision: Put `Keiro.Dsl.GeneratedHaskellLanguage` in a named private Cabal sublibrary rather
  than expose it from the main library or duplicate its source into the test suite.
  Rationale: The main library and same-package test suite both need the module, but consumers do
  not. The package already declares `cabal-version: 3.0`; a named sublibrary is private by default
  at that specification version and can be depended on by other components in the same package.
  This preserves one compiled implementation and one test target without creating public API.
  Date: 2026-08-30

- Decision: Keep migration manifests as repository policy and make compatibility claims through
  exact byte tests whose names identify the concrete contract they freeze.
  Rationale: Regenerating a Markdown inventory proves source coverage, not JSON or wire equality.
  Conversely, invoking a repository-root Python script from `keiro-dsl-test` makes the published
  package test depend on files and tools the package does not ship. The two jobs need different
  gates.
  Date: 2026-08-30

- Decision: Do not add a compatibility wrapper for the new tri-state `readRecord` and
  `readWorkspaceRecord` results in this plan.
  Rationale: The fail-closed `LedgerRead` result is an intentional 0.15 API change, and the Mori
  downstream audit found no use of those functions in the only direct package consumer,
  `mori://shinzui/rei`. The review finding is constructor authority, not the deliberate result
  type change.
  Date: 2026-08-30

- Decision: Regenerate the migration inventories at the end of Milestone 1 rather than waiting
  for Milestone 2.
  Rationale: The existing package tests enforce inventory freshness, and all three failures after
  the boundary refactor were the same stale-manifest condition. Moving this generated output
  forward keeps the milestone commit green without changing the intended inventory contents or
  the later repository-policy separation.
  Date: 2026-08-30

- Decision: Give `generated-haskell-language-internal` a dedicated `keiro-dsl/internal` source
  root and move `Keiro.Dsl.GeneratedHaskellLanguage` there.
  Rationale: Cabal dependency metadata alone does not prevent GHC from discovering a source file
  beneath the importing component's home-module search path. Physical source-root separation makes
  the ownership literal, compiles the implementation once, and preserves the intended private
  package boundary.
  Date: 2026-08-30

- Decision: Freeze direct serializer bytes for the three JSON oracles, including the absence of a
  final newline, and retain semantic decoding/assertions beside every exact comparison.
  Rationale: This matches the established `Aeson.encodeFile` and `Aeson.encode` output instead of
  preserving a newline introduced by text-file tooling. The ledger renderers continue to freeze
  their intentional `Text.unlines` newline.
  Date: 2026-08-30

- Decision: Ship the complete package test corpus through extension-scoped `extra-source-files`
  globs and make compile probes use `cabal exec --enable-tests` plus the exact configured
  `keiro-core` unit ID from Cabal's build plan.
  Rationale: A published package test must select the test component's exact dependency units and
  must not depend on the repository's package environment, Git index, or sibling test directories.
  The Git diff example now creates its own temporary repository, generic failures synthesize their
  small consumer modules, and the generated-module scan walks the shipped test tree.
  Date: 2026-08-30

- Decision: Keep the generated service-package compilation as a repository integration proof, while
  running its package-owned scaffold and immutable-Expectations assertions in the source
  distribution.
  Rationale: That final compilation intentionally targets current sibling `keiro` and `keiro-core`
  source packages and can deadlock when nested beneath the standalone package's Cabal test. The
  package-local behavior remains exercised without pretending sibling source belongs in the sdist.
  Date: 2026-08-30


## Outcomes & Retrospective

The package again represents checked authority in its types. Prepared sidecar and generated-edition
migrations can be inspected and applied but cannot be fabricated by callers; the other types that
were abstract in 0.14 are abstract again with explicit supported projections. Sidecar application
is total over the prepared value, so the previously reachable `error` branch no longer exists.

The generated-Haskell lexical implementation remains directly exercised by package tests through
one private named library and is absent from the installed public module surface. The executable
API-boundary policy protects the repaired constructors and fails closed for future public
`Prepared*` records.

Compatibility evidence now says exactly what it proves. Repository inventories are one explicit
`record-migration-policy` omission detector, while package tests freeze the check-report JSON,
diff-report JSON, behavior-obligations JSON, single-file ledger, and workspace ledger as exact
bytes. The complete fixture corpus and component-aware compile probes make those package tests pass
from an unpacked source archive without the repository's scripts, Git index, or sibling fixture
directories.

Final validation passed: strict shadowing compilation, formatting, all three repository policies,
`cabal check`, strict ADR validation, the complete `just verify` matrix, and a fresh 719-example
source-distribution run. The work intentionally leaves versions, bounds, release notes, tags, and
publishing unchanged for a later release-preparation plan.


## Context and Orientation

The review anchor is the annotated tag `keiro-0.14.0.0`, whose release commit is
`0bdd4b7d`. The reviewed implementation is the current branch after the record migration in
[ExecPlan 177](177-modernize-keiro-dsl-records-and-field-access.md) and the generated-edition
hardening in [ExecPlan 268](268-gate-every-pre-v2-generated-haskell-edition-and-harden-idiomatic-v2-adoption.md).
The record migration enabled `DuplicateRecordFields`, `NoFieldSelectors`, and
`OverloadedRecordDot` in `keiro-dsl/keiro-dsl.cabal`, renamed package-owned record labels, and
removed ordinary selector functions. Under `NoFieldSelectors`, record-dot works inside a module
when the field is in scope, but exporting `Type (..)` also exports the constructor and therefore
grants construction and pattern-matching authority. Concise labels do not require that authority.

A *prepared migration* in this plan is a value returned only after code has inspected the current
filesystem, checked conflicts, and assembled the exact operations an apply step may execute. It
is capability-like: possession authorizes the apply function to perform those operations. The
public descriptive counterpart is an impact or move value, such as `SidecarMove` or
`GeneratedHaskellEditionImpact`, which is safe for callers to construct and render because apply
does not accept it as proof of preflight.

`keiro-dsl/src/Keiro/Dsl/SidecarMigration.hs` currently exports
`PreparedSidecarMove (..)` and stores a public `SidecarMove` beside
`convertedContents :: Maybe Text`. `applyPreparedSidecarMoves` calls `error` if a fabricated
conversion lacks converted text or a fabricated retirement lacks a backup path. At 0.14 the type
was exported abstractly with `preparedSidecarMove :: PreparedSidecarMove -> SidecarMove`.
`Keiro.Dsl.ScaffoldRun` and `Keiro.Dsl.WorkspaceScaffold` need only that projection for refusal
and report output; the converted contents are apply-private.

`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` newly defines and exports
`PreparedGeneratedHaskellEditionMigration (..)`. Its fields contain backup source/destination
pairs, a report path and report bytes, and source moves. The same module owns the preflight and
apply functions, while `keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs` needs only the public
`GeneratedHaskellEditionImpact` for refusals plus the opaque prepared value for the supplied
transform and apply functions. An explicit
`preparedGeneratedHaskellEditionImpact :: PreparedGeneratedHaskellEditionMigration -> GeneratedHaskellEditionImpact`
is therefore sufficient outside `ScaffoldRun`.

Three pre-existing semantic types also lost opacity:

* `keiro-dsl/src/Keiro/Dsl/AggregateType.hs` now exports
  `AggregateHaskellSource (..)`. Its two alternative payloads are stored as separate `Maybe`
  fields, and `renderAggregateHaskellSource` calls `error` for neither-or-both states. The module's
  smart constructor and render/reference functions already provide the supported interface.
* `keiro-dsl/src/Keiro/Dsl/NominalType.hs` now exports `NominalTypeRegistry (..)`. The module
  describes this registry as the checked boundary after nominal declarations have been validated.
  Version 0.14 exported the type abstractly plus
  `nominalTypes :: NominalTypeRegistry -> Map Name ResolvedNominalType`.
* `keiro-dsl/src/Keiro/Dsl/Diff.hs` now exports `ChangeContext (..)`, despite the adjacent Haddock
  saying the constructor stays private so callers cannot manufacture contradictory ownership and
  surface claims. Version 0.14 exported the type abstractly plus `changeContextRoot` and
  `changeContextPaths`.

`keiro-dsl/internal/Keiro/Dsl/GeneratedHaskellLanguage.hs` contains the implementation that was an
`other-modules` module under `keiro-dsl/src/` at 0.14. ExecPlan 268 moved it into the main
library's `exposed-modules` only so
`keiro-dsl/test/Main.hs`, a separate Cabal component, could inspect the final `RewriteState` of
the lexical presentation rewriter. That exposes the whole one-off migration table and state
machine to external consumers. The module depends only on `base`, `containers`, and `text`, so it
can form a leaf private sublibrary without a dependency cycle. The main library modules
`Scaffold`, `ScaffoldRun`, `Harness`, and `Manifest`, and the test suite can all depend on that
private component.

`keiro-dsl/test/Keiro/Dsl/RecordMigration.hs` currently declares three Hspec examples, but all
three call the same helper, which runs
`python3 scripts/generate-record-migration-manifests.py --check`. The generator regenerates two
Markdown files and compares their bytes. Its `JSON/wire bytes` annotation is selected by a regular
expression; it does not serialize a value or compare bytes. The test also fails when run from a
published source distribution because that distribution does not contain the repository-root
`scripts/` directory, and Python is not a declared package test tool. The repository already has
real contract oracles that should remain package tests: the check-report JSON fixture at
`keiro-dsl/test/fixtures/check-report/legacy-min-language.golden.json`, the exact diff JSON fixture
at `keiro-dsl/test/fixtures/contract-typeid-domain.diff.json.golden`, tracked scaffold ledgers, and
the conformance corpus. The check-report test currently decodes both files before comparison, so
it proves JSON value equality but not byte equality. Behavior-obligation JSON, whose record labels
changed heavily, has semantic assertions but no exact byte golden.

The local architecture records relevant to this work are:

* [ADR 0038](../adr/0038-keiro-dsl-records-use-concise-labels-without-product-selectors.md),
  which says construction and matching remain public where constructors were already public and
  external identities remain explicit. Restoring the 0.14 abstract types implements that existing
  decision rather than revising it.
* [ADR 0019](../adr/0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md),
  which owns the `idiomatic-v2` generated record contract and its lexical modernization step.
* [ADR 0015](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
  and [ADR 0022](../adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md),
  which define preflighted, recoverable edition and sidecar migration. Opaque prepared values
  preserve those protocols at the library API boundary.

No new external library is required. Mori has no registered Cabal source project, so the Cabal
mechanism was checked against the current Cabal package-description specification after local
lookup failed: named private sublibraries are available from Cabal specification 2.0, the
`visibility` field is available from 3.0, and same-package components may depend on them. The
existing `cabal-version: 3.0` is sufficient.


## Plan of Work

### Milestone 1: restore checked construction boundaries

At the end of this milestone, public callers can inspect each prepared migration but cannot
construct one, the three 0.14 semantic abstractions are restored, and sidecar apply has no
impossible-state `error` branches. The existing single-file and workspace migration examples must
still pass unchanged.

In `keiro-dsl/src/Keiro/Dsl/SidecarMigration.hs`, export `PreparedSidecarMove` without `(..)`
and restore the explicit `preparedSidecarMove` projection. Replace the record containing
`convertedContents :: Maybe Text` with private constructors that encode the three valid prepared
forms: rename, retirement with a concrete backup path, and conformance-ledger conversion with a
concrete backup path and converted text. Each private constructor carries the public
`SidecarMove` used for reporting. Implement `preparedSidecarMove` by total pattern matching and
rewrite `applyPreparedSidecarMoves` to pattern-match on the private constructors. It must no
longer inspect optional proof fields or call `error`. Keep `SidecarMove (..)` public; it is report
data, not apply authority.

Replace `.sidecarMove` reads in `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` and
`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs` with `preparedSidecarMove`, and import that function
explicitly. Do not add an accessor for converted contents.

In `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`, export
`PreparedGeneratedHaskellEditionMigration` abstractly. Add and export
`preparedGeneratedHaskellEditionImpact`, implemented inside the defining module. Keep
`preflightGeneratedHaskellEditionMigration`,
`withGeneratedHaskellEditionSourceMoves`, and
`applyPreparedGeneratedHaskellEditionMigration` as the only construction, transformation, and
consumption operations. In `keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs`, import the prepared
type abstractly and replace `.impact` with the explicit projection. No backup, report, or source
move field is exported.

Restore `AggregateHaskellSource` to an abstract export in
`keiro-dsl/src/Keiro/Dsl/AggregateType.hs`; all its field reads remain inside the defining module.
Restore `NominalTypeRegistry` to an abstract export in
`keiro-dsl/src/Keiro/Dsl/NominalType.hs` and define the 0.14-compatible positional projection
`nominalTypes (NominalTypeRegistry values) = values`. Replace internal and test record-dot reads
of that field with the function. Restore `ChangeContext` to an abstract export in
`keiro-dsl/src/Keiro/Dsl/Diff.hs`, restore `changeContextRoot` and `changeContextPaths`, and keep
all four constructor fields private. Update consumers to use the supported projections or
existing functions such as `classifyCompatibility`; do not expose `contextKind` merely to retain
record-dot syntax.

Run the focused scaffold migration examples and the core `keiro-dsl-test` suite. Acceptance for
this milestone is not just compilation: the sidecar source contains no `error` branch in apply,
the prepared constructors occur only in their defining modules, and the existing interruption,
tamper, legacy, and workspace migration examples remain green.


### Milestone 2: keep test observability private and enforce the public surface

At the end of this milestone, `Keiro.Dsl.GeneratedHaskellLanguage` is importable by the main
library and test suite but absent from the installed main-library API, and a fast repository gate
detects a recurrence of every constructor-boundary regression from the review.

In `keiro-dsl/keiro-dsl.cabal`, add a named sublibrary such as
`library generated-haskell-language-internal`. Move the implementation to
`keiro-dsl/internal/Keiro/Dsl/GeneratedHaskellLanguage.hs`, import the existing `warnings` and
`shared` common stanzas, set `visibility: private` explicitly, use `hs-source-dirs: internal`, and
list `Keiro.Dsl.GeneratedHaskellLanguage` as its exposed module. Give the sublibrary only `base`,
`containers`, and `text`. Remove the module from the main library's `exposed-modules`; do not add
it to the main library's `other-modules`. Add
`keiro-dsl:generated-haskell-language-internal` to the main library and `keiro-dsl-test`
`build-depends`. The private library must not depend on the main library, so the component graph
remains acyclic. Keep the module name and its state-observation function unchanged inside the
package; no source duplication or public facade is needed.

Add `scripts/check-keiro-dsl-api-boundaries.py`. It should parse the main library's
`exposed-modules` and the explicit export lists of the protected source modules, then exit nonzero
with file/type-specific diagnostics when any of these conditions is false:

* `Keiro.Dsl.GeneratedHaskellLanguage` is absent from the main library's exposed modules and is
  owned by a private named sublibrary.
* `AggregateHaskellSource`, `NominalTypeRegistry`, `ChangeContext`,
  `PreparedSidecarMove`, and `PreparedGeneratedHaskellEditionMigration` are exported abstractly.
* Every exported type whose name begins with `Prepared` is abstract unless a reviewed allowlist
  in the script explains why construction itself is public API. Start with an empty allowlist.
* `nominalTypes`, `changeContextRoot`, `changeContextPaths`, `preparedSidecarMove`, and
  `preparedGeneratedHaskellEditionImpact` are exported.

The checker is a source-policy test, not a Haskell parser. Make it deliberately narrow around the
repository's formatted module-header and Cabal shapes, report a parse failure instead of silently
passing an unfamiliar shape, and give it unit fixtures or a `--self-test` mode containing both
accepted and rejected export lists. Add a `dsl-api-boundaries` recipe to `Justfile` and include it
in `verify`. This gate may rely on repository files and Python because it is not run from the
package test suite.

Regenerate `keiro-dsl/record-field-migration-0.15.md` and
`keiro-dsl/generated-haskell-edition-idiomatic-v2.md` with
`scripts/generate-record-migration-manifests.py`. The package inventory must now derive the lower
public-field count from the restored constructor exports. Review the diff: it should change public
status only for the repaired abstract types and should not erase the retained 0.14-to-0.15 label
map.


### Milestone 3: make inventory and compatibility tests say what they prove

At the end of this milestone, repository inventory drift still fails `just verify`, the published
package test no longer looks for repository-root scripts or an undeclared Python executable, and
the selected serialized compatibility contracts are compared byte-for-byte.

Remove `keiro-dsl/test/Keiro/Dsl/RecordMigration.hs` from `keiro-dsl-test`, remove its import and
`recordMigrationSpec` call from `keiro-dsl/test/Main.hs`, and remove the module from the Cabal
`other-modules` list. Add a `record-migration-policy` recipe to `Justfile` that runs
`python3 scripts/generate-record-migration-manifests.py --check`, and include that recipe in
`verify`. Its name and comments must call the files migration inventories and omission detectors;
do not call the check a JSON, wire, or runtime compatibility test. Update the generator's
introductory prose and column heading if necessary so `JSON/wire bytes` is clearly a review-risk
classification rather than an asserted oracle.

Strengthen the existing check-report example in `keiro-dsl/test/Main.hs` to compare the exact
bytes written by the CLI with
`keiro-dsl/test/fixtures/check-report/legacy-min-language.golden.json`, including its newline
policy, before decoding the JSON for semantic assertions. Keep the exact
`contract-typeid-domain.diff.json.golden` assertion as the diff-report byte oracle and make its
example description say that explicitly.

Add an exact behavior-obligations JSON golden under `keiro-dsl/test/fixtures/record-migration/`.
Reuse the source-aware `behavior-complete.keiro` path in the existing “joins every source-stable
behavior origin” example: derive requirements, plan the source map, attach exact source locations,
construct `BehaviorObligationsReport`, and pass it to `encodeBehaviorObligationsJson`. Compare the
UTF-8 bytes of the returned `Text` to the checked-in file, then decode or inspect the value so a
corrupt golden cannot pass merely because both sides are treated as opaque text. That fixture contains exact
locations, live transitions, rejections, and replay obligations, so the golden covers the renamed
`BehaviorExactLocation` and `BehaviorRequirement` fields and their explicit external keys. The
ledger golden below covers `BehaviorRecordRow`.

Add a focused ledger byte oracle rather than claiming every record is frozen. Construct a
representative `ScaffoldRecord` and `WorkspaceRecord` using existing test helpers, render each,
encode the rendered `Text` as UTF-8, and compare it to checked-in bytes under the same
`record-migration` fixture directory. Include at
least a behavior row, semantic-impact row, query-contract row, and naming-edition row. Parse the
golden back and compare with the source record to retain the forward-compatible reader proof.
The golden names and example descriptions must identify the exact single-file and workspace
ledger contracts they freeze.

Run `cabal sdist keiro-dsl`, unpack the archive into a `mktemp -d` directory, and run the main
`keiro-dsl-test` from that directory after building the root dependencies. This exercise proves
that the removed repository-script dependency is gone. It is not a release or upload step. Record
the archive path and result in Surprises & Discoveries; do not add the archive to the repository.


### Milestone 4: warning cleanup, durable context, and complete verification

At the end of this milestone, the package source has no name-shadowing warning introduced by the
record-label migration, ADR 38 names the restored opacity enforcement, and the whole repository
gate is green.

Rename the local bindings that now shadow broader names in
`keiro-dsl/src/Keiro/Dsl/MappedConsumer.hs`,
`keiro-dsl/src/Keiro/Dsl/AggregateType.hs`, and
`keiro-dsl/src/Keiro/Dsl/Workspace.hs`. Use semantic names such as
`resolvedNominalCategory`, `builtinTypeName`, and `failureSpan`; do not suppress
`-Wname-shadowing`. Compile the main and private libraries with
`-Werror=name-shadowing` as a one-off validation flag. If that reveals another package-source
site introduced by the record migration, fix it and record the extra site; do not expand this
milestone into cleanup of frozen generated fixtures or other packages' historical warnings.

Update [ADR 0038](../adr/0038-keiro-dsl-records-use-concise-labels-without-product-selectors.md)
to state explicitly that record-dot does not change constructor authority: a type abstract before
the migration stays abstract, and a same-package private component is preferred when tests need
implementation observability. Add the API-boundary policy to its enforcement consequences, update
the ADR timestamp, and add one `docs/adr/log.md` entry using `okf log add`. No new ADR is expected;
the implementation is correcting drift from ADR 38 rather than choosing a new architecture.
During the final distillation pass, create or update another ADR only if implementation discovers
a durable rule not already owned by ADRs 15, 19, 22, or 38.

Run formatting, the focused policies, every `keiro-dsl` test component, the source-distribution
test, strict ADR validation, and `just verify`. Review `git diff --check` and the final diff to
ensure the only generated changes are the intentional inventory counts/status rows and no
conformance output changed. Finish this plan's Progress, Surprises & Discoveries, Decision Log,
and Outcomes & Retrospective sections before declaring completion.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/keiro` unless a command explicitly changes
into a temporary source-distribution directory.

Before editing, capture the boundary regression and the focused green baseline:

```bash
git status --short --branch
git diff --unified=3 keiro-0.14.0.0..HEAD -- \
  keiro-dsl/src/Keiro/Dsl/AggregateType.hs \
  keiro-dsl/src/Keiro/Dsl/NominalType.hs \
  keiro-dsl/src/Keiro/Dsl/Diff.hs \
  keiro-dsl/src/Keiro/Dsl/SidecarMigration.hs \
  keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs \
  keiro-dsl/keiro-dsl.cabal
python3 scripts/generate-record-migration-manifests.py --check
scripts/check-extension-policy.sh
cabal test keiro-dsl-test --test-options='--match "Haskell.name-migration"'
cabal test keiro-dsl-test --test-options='--match "generated Haskell edition migration"'
cabal test keiro-dsl-test --test-options='--match "record API migration"'
```

The first command must show the current branch and any pre-existing worktree entries; record those
entries and preserve them during implementation. The two policy commands should exit 0. All three
focused test commands should pass before the obsolete `record API migration` group is removed.

After Milestone 1, prove the constructors are absent from consumers and the behavior still works:

```bash
rg -n 'PreparedSidecarMove \(\.\.\)|PreparedGeneratedHaskellEditionMigration \(\.\.\)|AggregateHaskellSource \(\.\.\)|NominalTypeRegistry \(\.\.\)|ChangeContext \(\.\.\)' \
  keiro-dsl/src
rg -n 'error "prepared sidecar|\.convertedContents|\.sidecarMove' \
  keiro-dsl/src/Keiro/Dsl/SidecarMigration.hs \
  keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs \
  keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs
cabal test keiro-dsl-test --test-options='--match "Haskell.name-migration"'
cabal test keiro-dsl-test --test-options='--match "generated Haskell edition migration"'
```

Both searches should print nothing. The focused suite should report zero failures.

After Milestone 2, build both libraries, run the boundary policy, and inspect the main exposed
surface:

```bash
python3 scripts/check-keiro-dsl-api-boundaries.py --self-test
python3 scripts/check-keiro-dsl-api-boundaries.py
cabal build keiro-dsl:lib:generated-haskell-language-internal keiro-dsl:lib:keiro-dsl keiro-dsl:test:keiro-dsl-test
rg -n 'Keiro\.Dsl\.GeneratedHaskellLanguage' keiro-dsl/keiro-dsl.cabal
python3 scripts/generate-record-migration-manifests.py
python3 scripts/generate-record-migration-manifests.py --check
```

The two policy invocations must exit 0. The `rg` command should print exactly one occurrence,
inside the named private sublibrary, and none inside the main library's exposed list. The final
inventory check must exit 0.

After Milestone 3, run the byte oracles and all package tests:

```bash
cabal test keiro-dsl-test --test-options='--match "check report"'
cabal test keiro-dsl-test --test-options='--match "diff report byte contract"'
cabal test keiro-dsl-test --test-options='--match "record migration byte contracts"'
cabal test keiro-dsl:tests
just record-migration-policy
```

All five commands must exit 0. The package test output must contain separately named examples
for the check-report JSON bytes, diff-report JSON bytes, behavior-obligations JSON bytes,
single-file ledger bytes, and workspace ledger bytes. It must not contain the old three
`record API migration`, `JSON contracts`, and `generated Haskell edition` manifest aliases.

Test the source distribution in a disposable directory. Direct Cabal to that directory and resolve
the one archive it creates rather than guessing a versioned filename:

```bash
cabal build keiro-core keiro-dsl
SDIST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/keiro-dsl-sdist-test.XXXXXX")
cabal sdist keiro-dsl --output-directory="$SDIST_DIR"
SDIST_PATH=$(rg --files "$SDIST_DIR" | rg '/keiro-dsl-[^/]+\.tar\.gz$')
test -n "$SDIST_PATH"
SDIST_ROOT=$(tar -tzf "$SDIST_PATH" | sed -n '1s#/.*##p')
test -n "$SDIST_ROOT"
tar -xzf "$SDIST_PATH" -C "$SDIST_DIR"
cd "$SDIST_DIR/$SDIST_ROOT"
cabal test --enable-tests keiro-dsl-test
```

The test must pass without `record migration inventory generator is not available` and without
invoking `python3`. Keep `SDIST_DIR` for inspection if the test fails; it is disposable after a
successful run.

For Milestone 4 and final acceptance:

```bash
cabal build keiro-dsl:lib:generated-haskell-language-internal keiro-dsl:lib:keiro-dsl \
  --ghc-options=-Werror=name-shadowing
nix fmt
python3 scripts/check-keiro-dsl-api-boundaries.py
python3 scripts/generate-record-migration-manifests.py --check
scripts/check-extension-policy.sh
(cd keiro-dsl && cabal check)
okf log add docs/adr --kind Update -m "Restore the abstract constructor boundary while retaining concise keiro-dsl record labels (plan 269)."
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just verify
git diff --check
git status --short
```

The build must have no name-shadowing error. Both Python policies and the extension policy must
exit 0. `cabal check` must report no package errors or warnings, strict ADR validation must print
an `OK` result, and `just verify` must exit 0. Review the final status rather than requiring a
clean tree: the plan and its implementation are expected edits, while unrelated pre-existing
changes must remain untouched.

Commit after each independently green milestone. Every commit follows Conventional Commits and
includes this plan trailer, for example:

```text
fix(dsl): restore prepared migration opacity

Make preflighted migration values abstract and make sidecar application total.

ExecPlan: docs/plans/269-restore-keiro-dsl-abstraction-boundaries-and-compatibility-proofs.md
```


## Validation and Acceptance

The implementation is accepted when all of the following are observable.

An external module importing `Keiro.Dsl.SidecarMigration` can pattern-match and construct
`SidecarMove`, call `planSidecarMigrations`, inspect each result through
`preparedSidecarMove`, and pass it to `applyPreparedSidecarMoves`, but the
`PreparedSidecarMove` constructors and converted contents are not exported. The apply function
contains no `error` path for a missing backup or conversion body because those invalid prepared
states no longer exist.

An external module importing `Keiro.Dsl.ScaffoldRun` can inspect
`GeneratedHaskellEditionImpact` and obtain it through
`preparedGeneratedHaskellEditionImpact`, but cannot construct or modify
`PreparedGeneratedHaskellEditionMigration`. Existing single-file and workspace tests still prove
legacy refusal, combined apply, byte-identical backup, tamper refusal, interruption recovery, and
idempotent rerun.

The main installed `keiro-dsl` library exports `AggregateHaskellSource`,
`NominalTypeRegistry`, and `ChangeContext` without constructors. The supported 0.14 projections
`nominalTypes`, `changeContextRoot`, and `changeContextPaths` compile. The API-boundary policy
fails in its self-test when any protected type or a synthetic `PreparedExample (..)` is made
constructible, and passes on the real source. `BehaviorRequirement (..)` remains public because
that is the released baseline.

`Keiro.Dsl.GeneratedHaskellLanguage` is compiled once in a private named library. The main
library and `keiro-dsl-test` build against it, the corpus rewriter end-state examples pass, and the
module is absent from the main library's exposed-module list. No public wrapper exposes
`RewriteState`, the label migration table, or the state-returning modernization function.

The repository inventory check has one honest policy entry in `just verify` and continues to fail
on stale migration documents. The package Hspec suite contains no subprocess call to the
repository-root inventory generator. Running that suite from an unpacked `keiro-dsl` source
distribution passes without `scripts/` or Python.

Exact byte comparisons pass for the check-report JSON, contract TypeID diff-report JSON,
behavior-obligations JSON, representative single-file ledger, and representative workspace
ledger. Each golden also has a semantic parse or field assertion. The tests do not claim these
five oracles exhaust every JSON boundary; the generated inventory labels other boundaries as
review risks rather than tested byte contracts.

The package libraries compile with name shadowing promoted to an error, the record migration and
extension policies pass, all `keiro-dsl:tests` pass, the source distribution test passes, strict
ADR validation passes, and `just verify` exits 0. No tracked generated Haskell, `.keiro` source,
or conformance ledger changes except the deliberately regenerated migration inventories.


## Idempotence and Recovery

All code changes are local API and test refactors; this plan does not run a scaffold migration
against a consumer tree. Re-running the inventory generator must produce no diff after its first
successful run. Re-running the focused and full tests may rebuild Cabal artifacts but must not
modify tracked fixtures.

The sidecar prepared-type refactor should be implemented additively: introduce private valid-form
constructors and the projection, update every constructor site, then rewrite apply and consumers
before removing the old record. If a focused migration test fails, no repository data migration
has occurred; inspect the temporary directory retained by Hspec and retry after fixing the code.
Do not weaken a refusal or delete a backup to make a test pass.

The private sublibrary has one important recovery rule: the module must be owned by exactly one
Cabal component. If Cabal reports a duplicate, ambiguous, or missing home module, keep its source
under `keiro-dsl/internal`, outside the main library's `keiro-dsl/src` root, and remove it from the
main library's `exposed-modules` and `other-modules` rather than copying the source. If
Cabal reports a dependency cycle, the private sublibrary has accidentally imported a main-library
module; move that dependency out or narrow the internal module, because making the sublibrary
public does not solve the cycle.

The byte goldens are authority, not update-on-failure snapshots. When a golden differs, inspect
the semantic diff and compare with the 0.14 contract before accepting a change. This plan expects
no external byte change. Regenerate a golden only when the produced value is confirmed identical
in meaning and the difference is an explicitly approved byte-policy correction recorded in the
Decision Log; otherwise fix the serializer.

The source-distribution test uses a directory created by `mktemp -d` and never writes into the
repository. Preserve it on failure. After success it can be removed by naming that exact printed
directory; never use an unresolved variable or a broad recursive target. Build products under
`dist-newstyle` are ordinary Cabal cache and can be reused.


## Interfaces and Dependencies

No new Hackage dependency is introduced. The private generated-language component uses only the
existing `base`, `containers`, and `text` bounds. The public main library depends on the private
same-package component through Cabal's qualified component dependency. The repository-only policy
uses Python 3 just as the existing inventory generator does, but Python remains outside the
published package test contract.

At the end of Milestone 1, `Keiro.Dsl.SidecarMigration` exposes these relevant signatures:

```haskell
data PreparedSidecarMove

preparedSidecarMove :: PreparedSidecarMove -> SidecarMove

planSidecarMigrations
  :: FilePath
  -> SidecarScope
  -> Maybe ConformancePackagePlan
  -> IO (Either [Text] [PreparedSidecarMove])

applyPreparedSidecarMoves :: FilePath -> [PreparedSidecarMove] -> IO ()
```

The private representation must distinguish rename, retirement-with-backup, and
conversion-with-backup-and-bytes without optional proof fields.

`Keiro.Dsl.ScaffoldRun` exposes:

```haskell
data PreparedGeneratedHaskellEditionMigration

preparedGeneratedHaskellEditionImpact
  :: PreparedGeneratedHaskellEditionMigration
  -> GeneratedHaskellEditionImpact

preflightGeneratedHaskellEditionMigration
  :: FilePath
  -> Maybe GeneratedHaskellNamingEdition
  -> [(ModuleKind, FilePath)]
  -> [FilePath]
  -> IO (Either [Text] (Maybe PreparedGeneratedHaskellEditionMigration))

withGeneratedHaskellEditionSourceMoves
  :: [SourceMove]
  -> Maybe PreparedGeneratedHaskellEditionMigration
  -> Maybe PreparedGeneratedHaskellEditionMigration

applyPreparedGeneratedHaskellEditionMigration
  :: FilePath
  -> Maybe PreparedGeneratedHaskellEditionMigration
  -> IO ()
```

`Keiro.Dsl.AggregateType` exports `AggregateHaskellSource` abstractly and keeps
`aggregateConsumerHaskellSource`, `aggregateSourceReferences`,
`aggregateSourceStaticImports`, and `renderAggregateHaskellSource` as its supported operations.
`Keiro.Dsl.NominalType` and `Keiro.Dsl.Diff` expose the restored projections:

```haskell
data NominalTypeRegistry
nominalTypes :: NominalTypeRegistry -> Map Name ResolvedNominalType

data ChangeContext
changeContextRoot :: ChangeContext -> Name
changeContextPaths :: ChangeContext -> [Text]
```

The named Cabal component has this dependency direction:

```text
generated-haskell-language-internal
  -> base, containers, text

keiro-dsl main library
  -> generated-haskell-language-internal

keiro-dsl-test
  -> keiro-dsl main library
  -> generated-haskell-language-internal
```

The policy interfaces are command-line programs with exit status as their contract:

```text
python3 scripts/check-keiro-dsl-api-boundaries.py [--self-test]
python3 scripts/generate-record-migration-manifests.py --check
```

Both print a concise success line and exit 0 on the accepted tree. On failure they exit nonzero
and name the module, type, or manifest whose boundary drifted.


Revision note (2026-08-30): Milestone 2 now gives the private generated-language component a
dedicated `keiro-dsl/internal` source root. The first implementation build proved that leaving the
file under the main library's `src` root makes GHC compile it as a main-unit home module despite the
same-package dependency, which fails at executable link time.

Revision note (2026-08-30): The Milestone 2 Cabal inspection now counts the generated-language
module occurrence without requiring a multiline field shape because the repository formatter
canonicalizes a singleton `exposed-modules` field inline.
