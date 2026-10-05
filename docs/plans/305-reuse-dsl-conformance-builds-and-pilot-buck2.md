---
id: 305
slug: reuse-dsl-conformance-builds-and-pilot-buck2
title: "Reuse DSL conformance builds and pilot Buck2"
kind: exec-plan
created_at: 2026-10-05T17:24:51Z
intention: "intention_01m46hftype0cszkfpah40nscp"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-05T17:24:51Z
---

# Reuse DSL conformance builds and pilot Buck2

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro releases require a large DSL conformance gate: generate Haskell from service specifications, compile that Haskell, execute its assertions, and prove that deliberate behavior changes are caught. Maintainers currently pay for disposable builds even when the relevant inputs have not changed. First make the existing Cabal workflow retain and correctly invalidate its compiled artifacts. Then build a small, independently runnable Buck2 conformance pilot and compare it with the improved Cabal workflow. The observable result is repeatable timing evidence, passing positive and failing negative proofs, and an explicit recommendation about whether Buck2 merits expansion.

Deliver one sequential effort with seven milestones. Milestones 1–4 complete build reuse and establish the improved baseline before milestones 5–7 implement and evaluate Buck2. Cabal remains the release and Hackage packaging authority during the pilot. The pilot must compile generated Haskell as explicit Buck2 targets; placing the existing Cabal commands behind one Buck2 action does not satisfy this plan. A pilot that proves correct but does not improve performance is a valid completed experiment, with a documented decision to stop expansion.


## Progress

- [ ] Milestone 1: record phase timings and compilation evidence for the current conformance workflow.
- [ ] Milestone 2: retain isolated hydration-probe compilation state and prove correct invalidation.
- [ ] Milestone 3: retain service-package mutation build state and preserve its positive/negative/positive proof.
- [ ] Milestone 4: reduce repeated CLI planning, validate the complete Cabal gate, and record the improved baseline.
- [ ] Milestone 5: pin and bootstrap an explicit Buck2 Haskell compilation prototype.
- [ ] Milestone 6: execute representative conformance and mutation proofs with equivalent compiler and dependency contracts.
- [ ] Milestone 7: measure both implementations, record an expansion or stop decision, and distill durable context into ADRs.


## Surprises & Discoveries

(None recorded during implementation yet. The source observations below are planning evidence, not benchmark results.)


## Decision Log

Decision: complete and measure Cabal reuse before starting the Buck2 pilot. Rationale: the user requested that order, and comparing Buck2 against disposable builds would attribute ordinary cache repairs to a new build system. Date: 2026-10-05.

Decision: retain compilation artifacts while rerunning assertions and mutation proofs on every gate invocation. Rationale: a compiled binary and a passing test result have different freshness requirements, especially when PostgreSQL or a deliberate mutation is involved. Date: 2026-10-05.

Decision: move the repository-only nested service-package compilation proof into an explicit repository gate, retaining the package-owned scaffold and immutable-Expectations assertions in the Hspec suite. Rationale: the expensive proof needs a persistent source/build area and locking, whereas unpacked source distributions must remain independently testable. Date: 2026-10-05.

Decision: bound the Buck2 pilot to five existing conformance components, use the current GHC and dependency solution, and keep local execution as the required experiment. Rationale: this tests real compilation and behavior without a whole-workspace migration or an external cache service becoming a prerequisite. Shared caching and remote execution are conditional follow-on measurements, with no subscription or infrastructure deployment required by this plan. Date: 2026-10-05.

Decision: preserve generated provenance, supported-language coverage, compiler warnings, and create-once expectations. Rationale: optimizing verification does not authorize changing generated contracts, dropping historical fixtures, or making assertions self-fulfilling. Date: 2026-10-05.


## Outcomes & Retrospective

(To be filled during implementation. Record before/after timings, compilation counts, complete gate results, pilot correctness, the expansion decision, and the ADR distillation here.)


## Context and Orientation

Run commands from the repository root unless a command explicitly changes directory. Keiro is a multi-package Haskell workspace. Cabal reads `cabal.project` and each package's `.cabal` file, solves package dependencies, builds components, and stores local build state in `dist-newstyle`. A component is one library, executable, or test suite. GHC is the Haskell compiler. Its compiled interface and object files can be reused when sources, compiler options, and dependency identities remain compatible. Reuse here means avoiding unnecessary compilation, not skipping execution of assertions.

`Justfile` defines `verify`, the release gate. `haskell-build` runs `cabal build all`; `haskell-test` runs `cabal test keiro-dsl:tests` along with the other packages' suites. The `:tests` selector deliberately covers every declared DSL suite; do not replace it with the bare package name, which previously selected only one component. At plan creation, `keiro-dsl/keiro-dsl.cabal` declares 55 test suites, 51 containing `conformance` in their names. There are 767 Haskell files bearing the generator banner beneath `keiro-dsl/test`. These are inventories, not measured costs, and must be refreshed at implementation time.

`process-reaction-proof` in `Justfile` runs `keiro-dsl/test/process-reaction-mutation-test.sh` and `keiro-dsl/test/process-hydration-test.sh`. The hydration script puts `BUILD_DIR` under a newly created temporary directory and deletes it on exit. It builds two components with `--constraint='keiro +reaction-hydration-probe'`, then reruns the ordinary reaction component to prove that the default build emits no probe markers. Keeping probe and ordinary builds separate is essential: the flag changes the compiled runtime. The current mutation script also changes tracked generated output and regenerates it during cleanup; its assertions must remain covered, and it must never run concurrently with corpus checking or another writer of those paths.

In `keiro-dsl/test/Main.hs`, the example named `keeps Expectations fixed and turns the generated target red for a changed workflow fact` copies `keiro-dsl/test/conformance-service-package`, mutates the workflow name, and scaffolds into the copy. In a repository checkout it then creates a temporary Cabal project including the local `keiro` and `keiro-core` source packages and a temporary build directory. It requires a particular runtime failure, not merely a failed compilation. This is an integration proof of application-owned expectations, but its temporary project discards all its local compilation state. The helper `activeCabalPackageId` reads the active Cabal install plan to distinguish exact package builds; an unqualified package name can be ambiguous when the Cabal store contains multiple builds of the same version.

`keiro-dsl/test/conformance-service-package/runtime/keiro-dsl-conformance-service-runtime.cabal` owns the generated runtime library and its one exposed conformance facade. Its nested generated package is `keiro-dsl/test/conformance-service-package/runtime/src/keiro-dsl-conformance.workspace.workspace-proof/keiro-workspace-proof-conformance.cabal`, whose test runner depends on that runtime. This distinction must survive the refactor and the pilot.

`scripts/check-conformance-corpus.sh` calls `keiro-dsl/tools/corpus-regen/src/Main.hs` in `check` mode. `runRegeneration` loads the tracked corpus plan, refuses dirty corpus paths, resolves the CLI once, executes entries sequentially, and verifies byte and inventory consistency. `CorpusPlan.hs` derives entries from tracked scaffold records and `keiro-dsl/test/conformance-corpus-manifest.txt`, including frozen historical corpora and ordered skeleton invocations. Already resolving the CLI once means there is no repeated `cabal run` per entry in this driver. Measure generation separately rather than assuming it has the same defect as the build proofs. Corpus parallelization is outside this effort; measured generation costs belong in the final recommendation.

`keiro-dsl/test/checked-mapping-adoption-test.sh` does repeatedly use `cabal run` for one CLI across check/scaffold operations, then reruns a conformance component. It is a concrete opportunity to resolve the CLI once. Several runtime components specify `-with-rtsopts=-N`, asking the Haskell runtime to use all available CPU capabilities. Running many of these executables simultaneously can contend for resources. Record concurrency and runtime settings in timings; do not silently speed up the gate by weakening its concurrency-sensitive proofs.

`nix/haskell.nix` selects the GHC 9.12.4 development shell and provisions PostgreSQL/native-library tooling. It is managed by Seihou; project-specific developer-tool additions belong in `flake.module.nix`, as explained in `flake.module.nix.example`. `.gitignore` already ignores `dist-*`. Put persistent proof workspaces and reports under a new root `dist-conformance/` directory; never put authored sources there. Do not traverse `/nix/store` to discover libraries or build dependencies. Existing commands may execute the provisioned tools, but source discovery must use Mori and ordinary source checkouts.

[ADR-19](../adr/0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md) requires generated output to compile under its advertised GHC2024/default-extension contract rather than inheriting the generator's broader extensions, and preserves generated warning checks. [ADR-20](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md) separates the runtime facade from the generated test package and makes expectations create-once application property. [ADR-22](../adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md) makes role-bearing Cabal fragments the generated build inventory and scaffold/conformance ledgers durable history; do not replace that authority with a separate handwritten Buck module inventory. [ADR-47](../adr/0047-dsl-retirement-requires-complete-retained-history-evidence.md) requires retained-history and negative semantic evidence before compatibility can be removed. This performance plan retires no such coverage. No existing ADR was found that selects Buck2 or defines proof build-cache ownership.

The ADR bundle is governed by `docs/adr/profile.dhall`, discovered through `mori show --full`. Before an ADR edit, read and type-check that descriptor, preserve existing stable IDs, and allocate any new ID with `okf id next`. Validate strict profile and log enforcement after an edit.

Buck2 schedules actions, which are compiler or other commands with declared inputs and outputs, and identifies named groups of these actions as targets. Its Haskell prelude is the shipped collection of build rules. The inspected upstream implementation compiles a target's group of sources as one action; it does not automatically produce one remotely cacheable action per Haskell module. Thus target boundaries and downstream invalidation are part of the experiment. The Haskell ecosystem page lists available rules but limited documentation, so toolchain and dependency interoperability are feasibility work rather than assumptions. Planning consulted the [official Haskell rule documentation](https://buck2.build/docs/prelude/rules/haskell/haskell_library/) and [ecosystem support documentation](https://buck2.build/docs/about/language_support/).

Mori searches for `buck2` and `Cabal` returned no registered projects at plan creation. The intended upstream project reference is `mori://facebook/buck2`; the inspected project-relative source paths are `prelude/haskell/compile.bzl` and `prelude/haskell/haskell.bzl`, with artifact-level URI coverage pending. Acquire/register a scoped upstream source checkout if still absent when implementing, then use Mori to locate and read it. Inspect the exact selected revision rather than treating today's main branch as a stable API. Verify Buck2 distributions against upstream release tags before selecting a pin; never use its moving `latest` tag as the durable pin. This plan intentionally selects no Buck2 version without that check.


## Plan of Work

### Milestone 1: establish an honest timing baseline


Add `scripts/measure-conformance.py`, using Python's standard library, to run named conformance phases, capture each command's exit status and elapsed monotonic time, and keep its full output in a run-specific directory under `dist-conformance/reports/`. Expose `baseline`, `reuse`, and eventually `pilot` measurement scenarios. Print phase start/progress information while commands run; a long-running build must not appear stalled. A failed command must fail the measurement command and remain visible in the report; expected mutation failures are accepted only by a proof wrapper that checks the specific diagnostic.

The baseline scenario measures ordinary DSL build/test, corpus checking, process mutation, hydration, service-package mutation, and checked-mapping adoption as separate phases. For the current combined Hspec suite, use its exact example match to measure the nested service-package proof separately and label overlap rather than adding overlapping phase times into a fictitious total. Record one full gate elapsed time independently. Capture compiler/Cabal versions, operating system and CPU budget, commit and dirty-input status, optimization flags, source inventory, and relevant PostgreSQL configuration with credentials removed. Record observed GHC compilation/relink messages alongside timings so a slow phase can be distinguished from a cached build running expensive assertions.

Use three consecutive runs after dependencies are available to distinguish the first local compilation from warm runs, where existing artifacts are present. A run with an empty *dedicated local build area* but an existing external dependency store is an explicitly labeled local-cold run, not a completely cold machine. Do not clear the developer's default build directory or Cabal dependency store. Existing proof scripts already have disposable local state; measure that cost as it stands. Reports must use the same machine and CPU budget for before/after comparisons. Acceptance is a machine-readable report with real exit codes and logs identifying where compilation was repeated; no numerical speed claim is required before evidence exists.

### Milestone 2: preserve the hydration variant's build state


Add `scripts/conformance-workspace.py` for repository proof storage and exclusive access, and adapt `keiro-dsl/test/process-hydration-test.sh` to run through it. The stable hydration build directory belongs beneath `dist-conformance/hydration/<configuration>/build`. Configuration distinguishes compiler executable identity/version, platform, profiling/link mode, and the hydration flag. Source edits and ordinary commits must not allocate a fresh configuration directory: let Cabal track source/dependency changes in the existing directory. Use the same project policy as the ordinary repository build, with only the explicit probe constraint differing. If the dependency solution differs, report it and reconcile the solutions before comparison.

Acquire an operating-system file lock around shared build state with Python `fcntl.flock`, which releases the lock when its owning process exits on macOS and Linux. Keep the lock held by the parent while its child commands run; do not implement a stale directory lock that remains after interruption. Keep logs in run-specific directories. A second invocation waits or fails with an actionable message and must not write concurrently. The temporary-directory cleanup trap may remove that invocation's disposable logs only; it must not remove the build directory. A command for clearing just the owned cache namespace belongs in the helper and must refuse paths outside `dist-conformance` after resolving symlinks.

Retain all existing entry-count assertions and the default-build silence check. After one successful run, a second run must execute both probe suites and their assertions without recompiling unchanged runtime sources. In a dedicated disposable checkout or proof copy, change a runtime source, change the probe flag/configuration, and interrupt a run. The next invocation must rebuild the necessary inputs, preserve probe/default separation, and recover automatically. Changing dependency metadata must still force Cabal to replan; do not introduce a handwritten success marker that bypasses it.

### Milestone 3: reuse the service-package mutation proof


Add `scripts/check-service-package-mutation.py`, using the workspace helper, and a `service-package-proof` recipe in `Justfile`. Add that recipe to `verify` so moving work out of Hspec does not drop a release gate. The Hspec example in `keiro-dsl/test/Main.hs` retains its independent assertions that scaffold does not overwrite accepted `Expectations.hs`. Remove only its repository-only nested Cabal compilation block after the explicit gate provides the stronger proof. Package-owned scaffold checks must still run from an unpacked source distribution.

The script keeps a stable copied fixture, stable project file, and build directory under `dist-conformance/service-package/<configuration>/`. Its project includes current local `keiro` and `keiro-core` source directories, the copied fixture runtime, and its nested generated conformance package. Preserve the active project's constraints, source-repository dependency policy, and required flags; compare external package identities against the active install plan instead of silently choosing newer packages. Copy authored fixture inputs by content: overwrite only changed files, preserve timestamps for equal bytes, and remove only obsolete fixture files owned by the copy manifest. Do not delete the whole source area before every run. Lock the entire copy/scaffold/build/mutation/restore sequence.

Execute a positive/negative/positive sequence in the same workspace. First the pristine generated package must build and pass. Then replace the workflow fact `workspace-proof-workflow` with `workspace-proof-workflow-v2` in the copied specification and re-scaffold without rewriting the accepted expectations. The package must compile and fail with this exact semantic evidence:

```text
FAIL  workflow/WorkspaceProofWorkflow/name expected="workspace-proof-workflow" actual="workspace-proof-workflow-v2"
```

Finally restore the original fixture inputs, re-scaffold, and require the package to pass again. Compiler errors, solver errors, missing libraries, and timeouts are failures of the proof, never acceptable negative results. Restore owned fixture inputs in a `finally` block; the next run reconciles them from the authored fixture even after a hard interruption. This intentionally rebuilds mutated runtime modules as needed, but a second entire invocation must reuse unchanged `keiro`, `keiro-core`, and unrelated runtime modules. Preserve the facade/package boundary rather than replacing the proof with an in-memory comparison or only type-checking the runner.

### Milestone 4: close the Cabal phase and measure reuse


Change `keiro-dsl/test/checked-mapping-adoption-test.sh` to build `exe:keiro-dsl` once, resolve it with `cabal list-bin exe:keiro-dsl`, and invoke that binary for every existing check/scaffold step. Keep its hand-owned hashes, generated-tree comparisons, and compiled harness execution. The corpus-regeneration driver already resolves once and needs no equivalent rewrite. Where the newly factored proofs require the CLI, pass the resolved absolute executable as an explicit script argument rather than starting another planning pass for every invocation.

Add focused tests in `scripts/tests/test_conformance_workspace.py` for real stale-cache hazards: interrupted lock release, concurrent access exclusion, unchanged-copy timestamp preservation, changed-input replacement, restoration after a failing command, and cleanup containment. Add an integration assertion that the mutation failure must have the expected runtime diagnostic. Avoid tests that merely assert the helper's own implementation details. Re-run complete DSL tests, corpus policy, process proofs, service-package proof, and adoption proof; then run `just verify` once and capture its actual exit status. Respect the corpus tool's clean-tree precondition by committing implementation-owned corpus edits first if any are required; do not use `--allow-dirty` to satisfy the gate.

Extend the measurement tool's `reuse` scenario to capture three runs of the improved workflow. Record per-phase medians and the full gate's separately measured elapsed time in `docs/conformance/build-reuse-and-buck2-results.md`. Include negative proofs and compilation counts. Milestone acceptance requires demonstrably eliminated unchanged local runtime recompilation on repeated hydration and service-package proofs, all original obligations present in `verify`, and a passing complete gate. Do not invent a mandatory percentage improvement for the entire release: remaining assertion or generation cost may dominate. Finish and record this milestone before bootstrapping Buck2.

### Milestone 5: bootstrap a bounded Buck2 Haskell prototype


Create an optional pilot workspace under `tools/buck2-conformance/`, with `.buckconfig`, `BUCK`, toolchain definitions, `dependencies.json`, a pinned-prelude bootstrap script, and a README. Put downloaded source checkouts outside authored fixtures and build outputs beneath ignored pilot storage; `.gitignore` may add only narrowly scoped Buck output/dependency paths. If a developer-shell addition is needed, use `flake.module.nix` rather than editing Seihou-managed `nix/haskell.nix`. Keep Buck2 out of mandatory release prerequisites throughout this plan.

Before selecting versions, run Mori discovery, acquire the upstream source if necessary, and verify the actual distributed Buck2 release and its matching prelude revision against official tags. Record immutable revisions and download checksums in `dependencies.json`, including the supported host platforms and the GHC identity. Use one compatible Buck2/prelude pair, not an arbitrary mixture of current prelude and old binary. Read the selected Haskell compile/library/toolchain rules directly. Bootstrap must be rerunnable, verify checksums, and print an actionable unsupported-platform message rather than guessing. No new Hackage bounds are changed by this pilot.

The first explicit compilation target is the existing `keiro-dsl-conformance` suite at `keiro-dsl/test/conformance`. Stage its source files and exact dependency inputs as Buck artifacts, compile them, link an executable, and run its existing `Main.hs`. Start with imported prebuilt dependencies from the improved Cabal solution, including current Keiro libraries, using exact package unit identities and declared interface/object/library/configuration artifacts. Cabal may provision those dependencies outside the Buck action graph, but the compile/link action itself must call the compiler directly and must not hide a `cabal build` underneath it. Pin compiler, flags, unit IDs, headers and native libraries as input identity. Fail closed if dependency artifacts cannot be enumerated safely without inspecting `/nix/store`; use a Cabal-owned export area, a scoped source build, or report an unsupported prototype instead of an undeclared ambient package database.

Prove a runnable executable and repeatability before expanding. Changing an imported Keiro dependency artifact must invalidate the target. This first prototype tests interoperability; its performance report must include dependency provisioning time separately and in end-to-end totals when provisioning occurs. It cannot claim that Buck2 has accelerated compilation of libraries still built by Cabal. If interoperability fails after a concrete compiler/linker investigation, record the failure and exact scope in the plan and results document; do not quietly replace explicit compilation with a shell wrapper.

### Milestone 6: add representative targets and correctness parity


Extend the pilot to exactly five components: `keiro-dsl-conformance`, `keiro-dsl-conformance-structural-nominals`, `keiro-dsl-conformance-codec-compare`, `keiro-workspace-proof-conformance`, and `keiro-dsl-conformance-process-reactions`. These cover basic generated aggregate code, large structural/nominal output, file-based codec assertions, runtime-facade/package separation, and database-backed process behavior. The last two are essential correctness probes even if their timings are not the fastest wins.

Add an inventory export command to the existing corpus tool in `keiro-dsl/tools/corpus-regen/src/Main.hs` and `CorpusPlan.hs`. Use its existing Cabal-syntax parsing and role-bearing generated inventory to export resolved component source files, language/default extensions, warnings, dependencies, fixture files, runtime options, and expected working directory. Resolve conditionals for the active flags before exporting; do not merely read `condTreeData` and discard conditional branches. Export to versioned JSON and have the pilot prepare/validate its target descriptions from it. Check all selected sources and dependencies for disagreement with the Cabal declarations or scaffold records. Do not export all generator-authored extensions into conformance compilation; retain the independent generated-output contract and `+werror-generated` behavior.

Add `scripts/run-buck2-conformance.py` with prepare, build, test, mutation, and invalidation-check operations, exposed by optional `Justfile` recipes. Choose target boundaries at complete fixture/runtime-library groups initially. Reuse shared sources where the resolved contracts are actually identical; module names alone are insufficient when independent fixtures contain different versions of similarly named modules. Record that the stock prelude compiles groups of sources in one action. Module-level custom rules are outside this pilot unless the selected upstream revision already supports them.

The runner must supply all fixture files and reproduce the existing test working directories. Codec comparison reads package-relative files; a binary that starts with the wrong directory is not a conformance pass. Database tests execute locally against the same provisioned PostgreSQL contract as Cabal and rerun every time, with test-result reuse disabled. Bound simultaneous runtime processes to the baseline CPU budget and retain required runtime options. Keep mutation outputs in pilot-owned source areas, never write the authored corpus. Reproduce the service workflow-name mutation, plus a process reaction guard mutation adapted from `process-reaction-mutation-test.sh`; both must compile and fail for their specific expected semantic observations under both backends, then pass after restoration.

Add executable invalidation probes for a changed generated source, a hand-owned Hole or expectations change, an imported runtime dependency change, compiler/default-extension changes, and a version-banner-only source edit. Warm builds must rebuild affected targets rather than reuse a stale success. Unrelated fixture targets should remain reusable when their declared inputs are unchanged; capture the action trace instead of assuming this property. A deliberately missing source/fixture/dependency must cause a clear error. Acceptance requires the same existing assertion outcomes and negative-proof diagnostics with current compiler contracts, plus recorded target invalidation. Local path-bound imported dependencies must be explicitly labeled non-portable; shared-cache eligibility cannot be claimed without an isolated-checkout test.

### Milestone 7: compare fairly and decide whether to expand


Measure the selected Cabal and Buck2 workloads on the same machine and same input revisions after milestone 4. Separate dependency bootstrap, generation, compilation/linking, test execution, and total wall time. Use three repeats for local-cold builds with dependencies available, unchanged warm builds, one-fixture edits, current-runtime-library edits, and provenance-only edits representing a release restamp. Revert benchmark mutations inside their owned copies before the next case. Report medians and ranges, compilation/action counts, concurrency, and cache mode. No Buck timing may omit a needed Cabal provisioning step from its corresponding end-to-end scenario.

If a shared remote cache service is already available and explicitly authorized, run an additional second-checkout experiment using declared, portable inputs. The Buck2 cache stores action outputs by their input identity; it is not an automatic cache of PostgreSQL assertion outcomes. Do not purchase a service or provision infrastructure under this plan. Without a service or portable toolchain, report shared caching as unmeasured and retain the useful local experiment. Consult the [official remote-execution documentation](https://buck2.build/docs/users/remote_execution/) when configuring an available service, and embed the exact successful configuration and input requirements in the pilot README.

Recommend expansion only if all correctness/invalidation proofs pass and the pilot's end-to-end median is at least 25% faster than improved Cabal in either the one-fixture-edit scenario or a release-like provenance edit, without a greater than 10% regression in the local-cold scenario. This threshold is an experiment decision rule, not a promised result. An unchanged warm win alone, or a win that disappears after dependency provisioning is counted, does not establish faster releases. If timing variance crosses the threshold, run three additional repeats and record uncertainty instead of selecting favorable samples. Require a supported, reproducible dependency/toolchain path before recommending shared-cache adoption.

Write the recommendation, maintenance cost, observed unsupported cases, and estimated effect on the separately measured whole gate into `docs/conformance/build-reuse-and-buck2-results.md`. Expansion means a recommendation and follow-up scope, not replacing `just verify` or migrating the remaining conformance suites in this plan. If Buck2 is slower or impractical, retain the completed Cabal improvements and mark the optional pilot as an experiment with a documented stop decision. Run the final appropriate repository gates once after the last implementation changes. Distill cache ownership and the pilot decision into a new ADR or a focused amendment, using the existing OKF profile workflow.


## Concrete Steps


These are implementation commands, not claims that this planning session ran the conformance gate. New script commands become available in their milestones. Begin at the repository root in the provisioned shell:

```bash
nix develop
command -v ghc
command -v cabal
command -v python3
ghc --numeric-version
cabal --numeric-version
git status --short
just process-compose-check
```

The last command must provision or validate the PostgreSQL prerequisite as the existing gate expects. If it fails, resolve that concrete environment failure before interpreting database-test timings. Source discovery and version verification precede dependency adapters:

```bash
mori registry list
mori registry search buck2
mori registry search Cabal
```

For each actual result, run `mori registry show <qualified-project> --full` and `mori registry docs <qualified-project>` using the discovered qualified name. If absent, acquire/register a scoped source checkout and record its canonical project URI and revision before proceeding. Consult upstream tags through the official repository, for example:

```bash
git ls-remote --tags https://github.com/facebook/buck2.git
```

Milestone 1 adds the measurement interface and runs it before any optimization:

```bash
python3 scripts/measure-conformance.py baseline --runs 3 --output dist-conformance/reports/baseline.json
```

Milestones 2–4 verify both reuse and execution:

```bash
python3 -m unittest discover -s scripts/tests -p test_conformance_workspace.py
bash keiro-dsl/test/process-hydration-test.sh
bash keiro-dsl/test/process-hydration-test.sh
python3 scripts/check-service-package-mutation.py
python3 scripts/check-service-package-mutation.py
cabal test keiro-dsl-test --test-options='--match "keeps Expectations fixed and turns the generated target red for a changed workflow fact"'
bash keiro-dsl/test/checked-mapping-adoption-test.sh
cabal test keiro-dsl:tests
just conformance-corpus-policy
just process-reaction-proof
just service-package-proof
python3 scripts/measure-conformance.py reuse --runs 3 --output dist-conformance/reports/reuse.json
just verify
```

Repeated hydration runs must print the original success line and report reused compilation; the service-package helper supplies a concise three-part proof summary:

```text
PASS: reaction hydration and witness entry counts are explicit; the default build is silent
service-package proof: baseline pass
service-package proof: expected workflow-name mutation failure
service-package proof: restored baseline pass
```

Full implementation validation uses the standard formatting/checks when relevant:

```bash
nix fmt
nix flake check
```

Do not run `just corpus-regen` simply because build orchestration changed. If intentional generated bytes did change, explain that separate contract change, review the diff, and follow the existing clean-corpus release procedure; no such change is planned here.

Milestones 5–7 add these root-level pilot interfaces:

```bash
python3 scripts/run-buck2-conformance.py prepare
python3 scripts/run-buck2-conformance.py build
python3 scripts/run-buck2-conformance.py test
python3 scripts/run-buck2-conformance.py mutation
python3 scripts/run-buck2-conformance.py invalidation-check
python3 scripts/measure-conformance.py pilot --runs 3 --output dist-conformance/reports/pilot.json
```

`prepare` must print resolved compiler, dependency-unit identities, immutable Buck2/prelude pins, selected components, and whether imported dependencies are local-only. `test` reports each of the five components as passed only after executing its assertions. `mutation` reports the expected behavior failure and restored baseline; it fails on compilation errors. `invalidation-check` reports affected versus reused actions for each input-change case and fails if changed inputs reuse a stale artifact. The final results document contains real measured numbers and links to scoped log artifacts or sanitized committed excerpts; do not paste fabricated sample timings.

After any ADR change, allocate/check IDs and update the reserved log as required by the descriptor, then validate:

```bash
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Use Conventional Commits on the current branch. Every implementation commit for this effort includes both trailers:

```text
ExecPlan: docs/plans/305-reuse-dsl-conformance-builds-and-pilot-buck2.md
Intention: intention_01m46hftype0cszkfpah40nscp
```


## Validation and Acceptance


Phase one succeeds when the unchanged second hydration/service-package runs rerun assertions while eliminating unchanged Keiro runtime compilation, a changed input is rebuilt, concurrent/interrupted invocations cannot corrupt their shared state, and the complete `just verify` gate remains green. Compare active external dependency solutions as well as source file identities. The moved integration proof must remain mandatory, while the package-owned Hspec assertions remain usable without the surrounding repository. Validate an unpacked DSL source distribution using a dedicated project against the current published dependency set where available; report any unavailable dependency concretely rather than weakening the assertions.

Phase two succeeds as an experiment when five explicit Buck2-compiled components run the same assertions as Cabal, negative semantic proofs fail for the correct reasons, restoration turns them green, and invalidation evidence prevents stale compilation from being accepted. If the Haskell/toolchain prototype proves infeasible, completion requires a reproducible scoped failure, a recorded investigation of the exact selected source rules, and an explicit stop decision; do not mark unimplemented target parity as passed. Such an outcome keeps phase one complete and reports phase two as a rejected pilot rather than a successful implementation.

The whole plan requires an evidence-backed expansion or stop recommendation and ADR distillation. Faster unchanged builds do not automatically prove a faster release: banner changes, package-version/dependency-unit changes, corpus generation, PostgreSQL assertions, Hackage packaging, and Haddock can still cost time. The final report must state which of those costs were measured and which remain outside the pilot. No fixture, warning gate, immutable expectation, supported-language test, or required database assertion may disappear to satisfy a performance target.


## Idempotence and Recovery


All scripts are repeatable from the root and store generated work only beneath `dist-conformance` or explicitly ignored pilot output. Separate build configuration namespaces prevent probe flags or incompatible compilers from contaminating the default build. Cabal and Buck inputs drive freshness; neither helper stores a durable “test already passed” bypass. Synchronizing fixture inputs preserves timestamps when content is unchanged and restores original inputs before every proof. Cache clearing is limited to one resolved owned namespace and is never a reason to remove the global Cabal store or developer build state.

Operating-system locks release on process termination. Interruptions leave reusable compilation files but cannot leave accepted semantic success; the next invocation restores authored inputs and reruns the sequence. Keep specific failed run logs for diagnosis. A second process must not access the same mutable build/source area until it holds the lock. Tracked-source mutation proofs run serially and start from clean relevant paths. For any new mutation, prefer a pilot/proof copy over editing the tracked corpus, and preserve independent expectations through both mutation and recovery.

The Buck pilot is additive and optional. If it is rejected, remove only its optional recipes/configuration in a focused follow-up or retain them clearly labeled experimental; keep the Cabal reuse helpers and evidence. No release, package upload, repository push, compiler migration, or paid remote infrastructure change is authorized by this plan. Unrelated working-tree files remain untouched, including the untracked plan 304 present during authoring.


## Interfaces and Dependencies


`scripts/conformance-workspace.py` owns path containment, configuration namespaces, content-preserving fixture synchronization, and lock lifetime. Its Python API must provide `configuration_key(metadata) -> str`, `locked_workspace(root, namespace, metadata)` as a context manager, and `sync_owned_tree(source, destination, manifest) -> SyncReport`. `SyncReport` reports copied, unchanged, and removed owned files. The key records tool/platform/configuration identity; it excludes ordinary commit IDs and source content so source edits reuse the same local build area. The child command interface uses argument arrays and propagates exit status rather than constructing a shell command from strings. Persistent fixture cleanup operates only on manifest-owned files inside the locked destination.

`scripts/check-service-package-mutation.py` implements the repository integration proof, returns nonzero on any unexpected result, and accepts an optional explicit `--dsl-executable` path. `scripts/measure-conformance.py` accepts `baseline|reuse|pilot`, positive `--runs`, and `--output`; its versioned JSON records metadata plus scenario/phase/command/elapsed-seconds/exit-code/log-path for every executed command. Report summaries retain expected negative-proof outcomes separately from unexpected failures and include median/range calculations without overlapping-duration summation.

The corpus inventory exporter is repository tooling, not a new public DSL API. Version its JSON schema, use Cabal's resolved build information for conditional branches, and include generated/hand-owned source roles and fixture paths. `scripts/run-buck2-conformance.py` translates that inventory into declared pilot inputs and invokes the pinned Buck2 tool. It must not use an ambient GHC package environment or expose multiple ambiguous same-name units. The first adapter imports exact Cabal-built units; the report distinguishes that from native Buck2 compilation of Keiro libraries. Runtime-package/facade separation and create-once expectations remain as required by ADR-20.

Existing Cabal, GHC, Python, PostgreSQL and native libraries remain the phase-one dependencies. Buck2 and its prelude are pilot-only additions pinned after authoritative verification. Prefer standard-library helpers and the corpus tool's existing Cabal-syntax dependency; do not add a new parsing or locking library by memory. Use Mori for any dependency-source lookup, and verify released versions upstream before changing dependency bounds or pins. References to external repositories remain canonical `mori://` project/artifact references, with project-relative paths explicitly labeled when artifact URI coverage is pending.
