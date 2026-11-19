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
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-19T01:16:54Z
      mode: "update"
      note: "Refresh against 0.26.0.0 and redirect the Buck2 pilot to try cabal-buck2 first in a dedicated worktree"
---

# Reuse DSL conformance builds and pilot Buck2

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro releases require a large DSL conformance gate: generate Haskell from service specifications, compile that Haskell, execute its assertions, and prove that deliberate behavior changes are caught. Maintainers currently pay for disposable builds even when the relevant inputs have not changed. First make the existing Cabal workflow retain and correctly invalidate its compiled artifacts. Then build a small, independently runnable Buck2 conformance pilot and compare it with the improved Cabal workflow. The observable result is repeatable timing evidence, passing positive and failing negative proofs, and an explicit recommendation about whether Buck2 merits expansion.

Deliver one sequential effort with seven milestones. Milestones 1–4 complete build reuse and establish the improved baseline before milestones 5–7 implement and evaluate Buck2. Cabal remains the release and Hackage packaging authority during the pilot. The pilot must compile generated Haskell as explicit Buck2 targets; placing the existing Cabal commands behind one Buck2 action does not satisfy this plan. The pilot first tries cabal-buck2, a new Cabal external command that generates Buck2 targets from the existing `.cabal` files, and falls back to a hand-written adapter only if that tool fails for a recorded reason. A pilot that proves correct but does not improve performance is a valid completed experiment, with a documented decision to stop expansion.


## Progress

- [ ] Milestone 1: record phase timings and compilation evidence for the current conformance workflow.
- [ ] Milestone 2: retain isolated hydration-probe compilation state and prove correct invalidation.
- [ ] Milestone 3: retain service-package mutation build state and preserve its positive/negative/positive proof.
- [ ] Milestone 4: reduce repeated CLI planning, validate the complete Cabal gate, and record the improved baseline.
- [ ] Milestone 5: pin and bootstrap Buck2 through cabal-buck2 in a dedicated pilot worktree, answer its feasibility questions, and build one conformance suite.
- [ ] Milestone 6: execute the five representative conformance components and mutation proofs with equivalent compiler and dependency contracts.
- [ ] Milestone 7: measure both implementations, record an expansion or stop decision, and distill durable context into ADRs.


## Surprises & Discoveries

(None recorded during implementation yet. The source observations below are planning evidence, not benchmark results.)


## Decision Log

Decision: complete and measure Cabal reuse before starting the Buck2 pilot. Rationale: the user requested that order, and comparing Buck2 against disposable builds would attribute ordinary cache repairs to a new build system. Date: 2026-10-05.

Decision: retain compilation artifacts while rerunning assertions and mutation proofs on every gate invocation. Rationale: a compiled binary and a passing test result have different freshness requirements, especially when PostgreSQL or a deliberate mutation is involved. Date: 2026-10-05.

Decision: move the repository-only nested service-package compilation proof into an explicit repository gate, retaining the package-owned scaffold and immutable-Expectations assertions in the Hspec suite. Rationale: the expensive proof needs a persistent source/build area and locking, whereas unpacked source distributions must remain independently testable. Date: 2026-10-05.

Decision: bound the Buck2 pilot to five existing conformance components, use the current GHC and dependency solution, and keep local execution as the required experiment. Rationale: this tests real compilation and behavior without a whole-workspace migration or an external cache service becoming a prerequisite. Shared caching and remote execution are conditional follow-on measurements, with no subscription or infrastructure deployment required by this plan. Date: 2026-10-05.

Decision: preserve generated provenance, supported-language coverage, compiler warnings, and create-once expectations. Rationale: optimizing verification does not authorize changing generated contracts, dropping historical fixtures, or making assertions self-fulfilling. Date: 2026-10-05.

Decision: generate the pilot's Buck2 targets with cabal-buck2 first, keeping the hand-written stock-prelude adapter as a recorded fallback. Rationale: cabal-buck2 solves with Cabal's own solver, lets Cabal provision dependencies, and generates one Buck2 target per Cabal component whose rules invoke GHC directly. That keeps the `.cabal` files as the only module inventory (ADR-22), removes the need for a custom inventory exporter and hand-enumerated dependency artifacts, and covers test suites, C sources, and Template Haskell. It is a young tool (first tag 2026-10-07, 144 commits on 2026-11-18) with a forked prelude, so milestone 5 opens with ordered feasibility questions and pins a commit. Date: 2026-11-18.

Decision: run the pilot in a detached git worktree under `dist-conformance/buck2-pilot/checkout`, never in the authored tree. Rationale: cabal-buck2 writes build files into every package directory and the project root, including corpus paths that must stay clean, and the pilot's mutations need an owned copy anyway. A worktree also fixes the measured input revision. Date: 2026-11-18.

Decision: the proof helpers use their own lock files under `dist-conformance` and do not take the release workspace lock. Rationale: `just verify` already holds the non-blocking release lock in the git directory while `_verify` runs; a helper that tried to take it again from a child process would fail against its own ancestor. A helper started on its own while a gate holds the release lock is still unsafe for scripts that edit the tracked tree, so standalone runs of tracked-tree mutation scripts go through `python3 scripts/release_workflow.py locked -- <command>`. Date: 2026-11-18.

Decision: this plan changes only the hydration script, the service-package proof, and the checked-mapping adoption script; it does not restructure the other mutation scripts. Rationale: `docs/plans/346-evaluate-adopting-heni-for-keiro-dsl-mutation-testing.md` owns the question of how mutation scripts are written. Milestone 1 still times every proof recipe so that plan 346 and this plan's final recommendation share one cost picture. Date: 2026-11-18.


## Outcomes & Retrospective

(To be filled during implementation. Record before/after timings, compilation counts, complete gate results, pilot correctness, the expansion decision, and the ADR distillation here.)


## Context and Orientation

Run commands from the repository root unless a command explicitly changes directory. Keiro is a multi-package Haskell workspace. Cabal reads `cabal.project` and each package's `.cabal` file, solves package dependencies, builds components, and stores local build state in `dist-newstyle`. A component is one library, executable, or test suite. GHC is the Haskell compiler. Its compiled interface and object files can be reused when sources, compiler options, and dependency identities remain compatible. Reuse here means avoiding unnecessary compilation, not skipping execution of assertions.

`Justfile` defines `verify` as `python3 scripts/release_workflow.py locked -- just _verify`. The `locked` command takes a non-blocking exclusive `fcntl.flock` on `release-workflow.lock` inside the git directory, so a second release or verification writer fails immediately with a retry message, and it requires the Nix shell. The private recipe `_verify` lists the gate's dependencies; a new mandatory proof is added there. The release gate proper (`release_workflow.py gate`) runs `just _verify` as its `correctness` stage and reuses stage receipts between attempts when inputs are unchanged, so time saved inside `_verify` is saved on every non-reused correctness stage. `haskell-build` runs `cabal build all`; `haskell-test` runs `cabal test keiro-dsl:tests` along with the other packages' suites. The `:tests` selector deliberately covers every declared DSL suite; do not replace it with the bare package name, which previously selected only one component. At the 2026-11-18 refresh (commit `fd179d77`, release 0.26.0.0), `keiro-dsl/keiro-dsl.cabal` declares 64 test suites, 60 containing `conformance` in their names, up from 55 and 51 at plan creation. There are 912 Haskell files bearing the `-- @generated by keiro-dsl` banner beneath `keiro-dsl/test`, up from 767. `cabal.project` lists fifteen packages and still carries a git `source-repository-package` stanza for `codd`, although no default build uses it: `keiro-migrations` depends on `codd` only under its `legacy-codd-tools` flag, which defaults to off. The stanza alone keeps two `codd` units (library and executable) in the install plan. The project also sets `keiro-dsl +werror-generated` and `keiro-ops-http +compose-example`, and relaxes `haxl:time`. The active install plan has 432 units: 294 external, 101 local components, and 37 compiler-provided. These are inventories, not measured costs, and must be refreshed at implementation time.

`process-reaction-proof` in `Justfile` runs `keiro-dsl/test/process-reaction-mutation-test.sh` and `keiro-dsl/test/process-hydration-test.sh`. The hydration script puts `BUILD_DIR` under a newly created temporary directory and deletes it on exit. It builds two components with `--constraint='keiro +reaction-hydration-probe'`, then reruns the ordinary reaction component to prove that the default build emits no probe markers. Keeping probe and ordinary builds separate is essential: the flag changes the compiled runtime. The current mutation script also changes tracked generated output and regenerates it during cleanup; its assertions must remain covered, and it must never run concurrently with corpus checking or another writer of those paths. `_verify` also runs `initial-hole-proof`, `mapped-structural-enum-equality-proof`, `consumer-enum-literal-proof`, `mapped-register-construction-proof`, `replay-compatibility`, and `checked-mapping-adoption`. Twenty-two scripts match `keiro-dsl/test/*mutation*.sh`; most rebuild in the default build directory after editing tracked files, and only the hydration script passes its own `--builddir`.

In `keiro-dsl/test/Main.hs`, the example named `keeps Expectations fixed and turns the generated target red for a changed workflow fact` copies `keiro-dsl/test/conformance-service-package`, mutates the workflow name, and scaffolds into the copy. In a repository checkout it then creates a temporary Cabal project including the local `keiro` and `keiro-core` source packages and a temporary build directory. It requires a particular runtime failure, not merely a failed compilation. This is an integration proof of application-owned expectations, but its temporary project discards all its local compilation state. The helper `activeCabalPackageId` reads the active Cabal install plan to distinguish exact package builds; an unqualified package name can be ambiguous when the Cabal store contains multiple builds of the same version. A later example in the same file, `passes both runner modes for a service with no aggregates and rejects unknown options (plan 337)`, also builds a temporary Cabal project, but its runtime is a synthetic library depending only on `base`; it is package-owned, stays in Hspec, and is only timed by this plan.

`keiro-dsl/test/conformance-service-package/runtime/keiro-dsl-conformance-service-runtime.cabal` owns the generated runtime library and its one exposed conformance facade. Its nested generated package is `keiro-dsl/test/conformance-service-package/runtime/src/keiro-dsl-conformance.workspace.workspace-proof/keiro-workspace-proof-conformance.cabal`, whose test runner depends on that runtime. This distinction must survive the refactor and the pilot.

`scripts/check-conformance-corpus.sh` calls `keiro-dsl/tools/corpus-regen/src/Main.hs` in `check` mode. `runRegeneration` loads the tracked corpus plan, refuses dirty corpus paths, resolves the CLI once, executes entries sequentially, and verifies byte and inventory consistency. `CorpusPlan.hs` derives entries from tracked scaffold records and `keiro-dsl/test/conformance-corpus-manifest.txt`, including frozen historical corpora and ordered skeleton invocations. Already resolving the CLI once means there is no repeated `cabal run` per entry in this driver. Measure generation separately rather than assuming it has the same defect as the build proofs. Corpus parallelization is outside this effort; measured generation costs belong in the final recommendation.

`keiro-dsl/test/checked-mapping-adoption-test.sh` does repeatedly use `cabal run` for one CLI across check/scaffold operations, then reruns a conformance component. It is a concrete opportunity to resolve the CLI once. Several runtime components specify `-with-rtsopts=-N`, asking the Haskell runtime to use all available CPU capabilities. Running many of these executables simultaneously can contend for resources. Record concurrency and runtime settings in timings; do not silently speed up the gate by weakening its concurrency-sensitive proofs.

`nix/haskell.nix` selects the GHC 9.12.4 development shell, which provides cabal-install 3.16.1.0, and provisions PostgreSQL/native-library tooling. Per `AGENTS.md`, run every build and test through `nix develop`, and confirm `z3 --version` there before symbolic conformance tests. It is managed by Seihou; project-specific developer-tool additions belong in `flake.module.nix`, as explained in `flake.module.nix.example`. `.gitignore` already ignores `dist-*`. Put persistent proof workspaces and reports under a new root `dist-conformance/` directory; never put authored sources there. Do not traverse `/nix/store` to discover libraries or build dependencies. Existing commands may execute the provisioned tools, but source discovery must use Mori and ordinary source checkouts.

[ADR-19](../adr/0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md) requires generated output to compile under its advertised GHC2024/default-extension contract rather than inheriting the generator's broader extensions, and preserves generated warning checks. [ADR-20](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md) separates the runtime facade from the generated test package and makes expectations create-once application property. [ADR-22](../adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md) makes role-bearing Cabal fragments the generated build inventory and scaffold/conformance ledgers durable history; do not replace that authority with a separate handwritten Buck module inventory. [ADR-47](../adr/0047-dsl-retirement-requires-complete-retained-history-evidence.md) requires retained-history and negative semantic evidence before compatibility can be removed. This performance plan retires no such coverage. No existing ADR was found that selects Buck2 or defines proof build-cache ownership.

The ADR bundle is governed by `docs/adr/profile.dhall`, discovered through `mori show --full`. Before an ADR edit, read and type-check that descriptor, preserve existing stable IDs, and allocate any new ID with `okf id next`. Validate strict profile and log enforcement after an edit.

Buck2 schedules actions, which are compiler or other commands with declared inputs and outputs, and identifies named groups of these actions as targets. Its Haskell prelude is the shipped collection of build rules. The upstream prelude compiles a target's group of sources as one action; it does not automatically produce one remotely cacheable action per Haskell module. Thus target boundaries and downstream invalidation are part of the experiment. Planning consulted the [official Haskell rule documentation](https://buck2.build/docs/prelude/rules/haskell/haskell_library/) and [ecosystem support documentation](https://buck2.build/docs/about/language_support/).

cabal-buck2 (`mori://simonmar/cabal-buck2`, upstream <https://github.com/simonmar/cabal-buck2>, BSD-3-Clause) appeared after this plan was written. The following is taken from its README, changelog, and package description on 2026-11-18 and has not been exercised against Keiro; treat each statement as a claim to verify at the pinned commit. It is a Cabal external command. `cabal buck2 --enable-tests`, run in a project root, runs Cabal's solver over `cabal.project` and the `.cabal` files, has Cabal build the external dependencies into its store, and writes Buck2 build files; `buck2 build //...` and `buck2 test //...` then compile and run the local packages. It writes a `BUCK` and `BUCK.cabal.bzl` into each package directory, generated `cabal_macros.h` and `Paths_<pkg>.hs` under `cabal-buck2/autogen`, `cabal-buck2/packages.bzl` at the root, prebuilt-package and toolchain definitions under `third-party/haskell`, and a `buck2/` directory containing its rules. Those rules are a fork of the Buck2 prelude (`mori://simonmar/haskell-buck2`) bundled with the tool. All packages must live in the root Buck2 cell, and the command must be re-run after any `.cabal` or `cabal.project` change. With `--source-deps`, Buck2 builds external dependencies from unpacked source instead of importing them prebuilt; `source-repository-package` entries are supported in that mode from version 0.6.0.0, which had no tag yet on 2026-11-18. Libraries, executables, test suites, and benchmarks are supported, as are C sources, `pkgconfig-depends`, `hsc2hs`, `alex`, `happy`, Template Haskell, and `build-type: Configure`. `build-type: Custom` is an error unless skipped with `--keep-going` or treated as Simple with `--enable-custom-setup`; `foreign-library` is unsupported; `hspec-discover` needs a hand-written rule, and no Keiro package uses it. Each component is compiled with one `ghc --make` action by default, with a documented opt-in per-module mode. The package description lists GHC 9.12.4 as tested and links cabal-install 3.18.1.0 as a library; the README says the `cabal` binary should match and that nothing checks this. macOS is supported from 0.5.0.0, and GHC builds from Nix are accommodated, with tool paths fixed when the command runs. A `--cache=grpc://...` flag configures a remote cache, and the README warns that sharing a cache between machines with different system software is not yet safe. The README does not state which Buck2 binary version is required, how Cabal flags and conditionals are resolved, or whether `default-language` and `default-extensions` are carried per component; milestone 5 answers these from the source and the generated output.

At the 2026-11-18 refresh Mori has `haskell/cabal` registered (including `Cabal-syntax` and `cabal-install`) and has no project matching `buck2`, `cabal-buck2`, or `haskell-buck2`. Before milestone 5, register `mori://facebook/buck2`, `mori://simonmar/cabal-buck2`, and `mori://simonmar/haskell-buck2` from scoped source checkouts, then use Mori to locate and read them at the exact pinned revisions rather than treating a default branch as a stable API. The files of interest are the project-relative paths `prelude/haskell/compile.bzl` and `prelude/haskell/haskell.bzl` in the Buck2 repository and their counterparts in the fork, plus the generator's flag handling in cabal-buck2; artifact-level URI coverage for these is pending. Verify Buck2 distributions against upstream release tags before selecting a pin; never use its moving `latest` tag as the durable pin. This plan intentionally selects no version without that check.

## Plan of Work

### Milestone 1: establish an honest timing baseline


Add `scripts/measure-conformance.py`, using Python's standard library, to run named conformance phases, capture each command's exit status and elapsed monotonic time, and keep its full output in a run-specific directory under `dist-conformance/reports/`. Expose `baseline`, `reuse`, and eventually `pilot` measurement scenarios. Print phase start/progress information while commands run; a long-running build must not appear stalled. A failed command must fail the measurement command and remain visible in the report; expected mutation failures are accepted only by a proof wrapper that checks the specific diagnostic.

The baseline scenario measures ordinary DSL build/test, corpus checking, process mutation, hydration, service-package mutation, checked-mapping adoption, and each remaining proof recipe that `_verify` runs (`initial-hole-proof`, the three mapped and consumer proofs, and `replay-compatibility`) as separate phases. Only the first six are optimization targets here; the others are timed so the report shows where the gate's time goes. For the current combined Hspec suite, use its exact example match to measure the nested service-package proof separately and label overlap rather than adding overlapping phase times into a fictitious total. Record one full gate elapsed time independently, by running `just verify` so the release workspace lock is held exactly as in a real gate; the measurement tool itself must not hold that lock around it. Capture compiler/Cabal versions, operating system and CPU budget, commit and dirty-input status, optimization flags, source inventory, and relevant PostgreSQL configuration with credentials removed. Record observed GHC compilation/relink messages alongside timings so a slow phase can be distinguished from a cached build running expensive assertions.

Use three consecutive runs after dependencies are available to distinguish the first local compilation from warm runs, where existing artifacts are present. A run with an empty *dedicated local build area* but an existing external dependency store is an explicitly labeled local-cold run, not a completely cold machine. Do not clear the developer's default build directory or Cabal dependency store. Existing proof scripts already have disposable local state; measure that cost as it stands. Reports must use the same machine and CPU budget for before/after comparisons. Acceptance is a machine-readable report with real exit codes and logs identifying where compilation was repeated; no numerical speed claim is required before evidence exists.

### Milestone 2: preserve the hydration variant's build state


Add `scripts/conformance-workspace.py` for repository proof storage and exclusive access, and adapt `keiro-dsl/test/process-hydration-test.sh` to run through it. The stable hydration build directory belongs beneath `dist-conformance/hydration/<configuration>/build`. Configuration distinguishes compiler executable identity/version, platform, profiling/link mode, and the hydration flag. Source edits and ordinary commits must not allocate a fresh configuration directory: let Cabal track source/dependency changes in the existing directory. Use the same project policy as the ordinary repository build, with only the explicit probe constraint differing. If the dependency solution differs, report it and reconcile the solutions before comparison.

Acquire an operating-system file lock on a lock file beneath `dist-conformance` around shared build state with Python `fcntl.flock`, which releases the lock when its owning process exits on macOS and Linux. Keep the lock held by the parent while its child commands run; do not implement a stale directory lock that remains after interruption. Keep logs in run-specific directories. A second invocation waits or fails with an actionable message and must not write concurrently. This lock is separate from the release workspace lock that `just verify` holds in the git directory: the helper never tries to take the release lock, because inside a gate an ancestor process already holds it. The temporary-directory cleanup trap may remove that invocation's disposable logs only; it must not remove the build directory. A command for clearing just the owned cache namespace belongs in the helper and must refuse paths outside `dist-conformance` after resolving symlinks.

Retain all existing entry-count assertions and the default-build silence check. After one successful run, a second run must execute both probe suites and their assertions without recompiling unchanged runtime sources. In a dedicated disposable checkout or proof copy, change a runtime source, change the probe flag/configuration, and interrupt a run. The next invocation must rebuild the necessary inputs, preserve probe/default separation, and recover automatically. Changing dependency metadata must still force Cabal to replan; do not introduce a handwritten success marker that bypasses it.

### Milestone 3: reuse the service-package mutation proof


Add `scripts/check-service-package-mutation.py`, using the workspace helper, and a `service-package-proof` recipe in `Justfile`. Add that recipe to the private `_verify` dependency list so moving work out of Hspec does not drop a release gate; the release gate's `correctness` stage then covers it without further change. The Hspec example in `keiro-dsl/test/Main.hs` retains its independent assertions that scaffold does not overwrite accepted `Expectations.hs`. Remove only its repository-only nested Cabal compilation block after the explicit gate provides the stronger proof. Package-owned scaffold checks must still run from an unpacked source distribution.

The script keeps a stable copied fixture, stable project file, and build directory under `dist-conformance/service-package/<configuration>/`. Its project includes current local `keiro` and `keiro-core` source directories, the copied fixture runtime, and its nested generated conformance package. Preserve the active project's constraints, source-repository dependency policy, and required flags; compare external package identities against the active install plan instead of silently choosing newer packages. Copy authored fixture inputs by content: overwrite only changed files, preserve timestamps for equal bytes, and remove only obsolete fixture files owned by the copy manifest. Do not delete the whole source area before every run. Lock the entire copy/scaffold/build/mutation/restore sequence.

Execute a positive/negative/positive sequence in the same workspace. First the pristine generated package must build and pass. Then replace the workflow fact `workspace-proof-workflow` with `workspace-proof-workflow-v2` in the copied specification and re-scaffold without rewriting the accepted expectations. The package must compile and fail with this exact semantic evidence:

```text
FAIL  workflow/WorkspaceProofWorkflow/name expected="workspace-proof-workflow" actual="workspace-proof-workflow-v2"
```

Finally restore the original fixture inputs, re-scaffold, and require the package to pass again. Compiler errors, solver errors, missing libraries, and timeouts are failures of the proof, never acceptable negative results. Restore owned fixture inputs in a `finally` block; the next run reconciles them from the authored fixture even after a hard interruption. This intentionally rebuilds mutated runtime modules as needed, but a second entire invocation must reuse unchanged `keiro`, `keiro-core`, and unrelated runtime modules. Preserve the facade/package boundary rather than replacing the proof with an in-memory comparison or only type-checking the runner.

### Milestone 4: close the Cabal phase and measure reuse


Change `keiro-dsl/test/checked-mapping-adoption-test.sh` to build `exe:keiro-dsl` once, resolve it with `cabal list-bin exe:keiro-dsl`, and invoke that binary for every existing check/scaffold step. Keep its hand-owned hashes, generated-tree comparisons, and compiled harness execution. The corpus-regeneration driver already resolves once and needs no equivalent rewrite. Where the newly factored proofs require the CLI, pass the resolved absolute executable as an explicit script argument rather than starting another planning pass for every invocation.

Add focused tests in `scripts/tests/test_conformance_workspace.py` for real stale-cache hazards: interrupted lock release, concurrent access exclusion, unchanged-copy timestamp preservation, changed-input replacement, restoration after a failing command, and cleanup containment. Add an integration assertion that the mutation failure must have the expected runtime diagnostic. Avoid tests that merely assert the helper's own implementation details. Re-run complete DSL tests, corpus policy, process proofs, service-package proof, and adoption proof; then run `nix develop -c just verify` once and capture its actual exit status. Respect the corpus tool's clean-tree precondition by committing implementation-owned corpus edits first if any are required; do not use `--allow-dirty` to satisfy the gate.

Extend the measurement tool's `reuse` scenario to capture three runs of the improved workflow. Record per-phase medians and the full gate's separately measured elapsed time in `docs/conformance/build-reuse-and-buck2-results.md`. Include negative proofs and compilation counts. Milestone acceptance requires demonstrably eliminated unchanged local runtime recompilation on repeated hydration and service-package proofs, all original obligations present in `verify`, and a passing complete gate. Do not invent a mandatory percentage improvement for the entire release: remaining assertion or generation cost may dominate. Finish and record this milestone before bootstrapping Buck2.

### Milestone 5: bootstrap Buck2 through cabal-buck2


The primary route is the cabal-buck2 generator described in Context and Orientation; a hand-written adapter is the fallback, used only after cabal-buck2 fails for a recorded, concrete reason. Create an optional pilot directory `tools/buck2-conformance/` holding a README, `dependencies.json` (the pins), and a rerunnable bootstrap script. Commit no generated `BUCK`, `BUCK.cabal.bzl`, `buck2/`, `cabal-buck2/`, or `third-party/haskell` file: they embed absolute local tool paths and are regenerated from the `.cabal` files. Keep Buck2 out of mandatory release prerequisites throughout this plan. If a developer-shell addition is needed, use `flake.module.nix` rather than editing Seihou-managed `nix/haskell.nix`.

Run the pilot in a dedicated checkout, not in the authored tree. cabal-buck2 writes into every package directory and the project root, and requires all packages in one root Buck2 cell; several of those directories are corpus paths that the corpus tool requires to be clean. The bootstrap script creates a detached git worktree of the commit under test at `dist-conformance/buck2-pilot/checkout` (a worktree is a second working copy of the same repository at a chosen commit) and removes and recreates it when the commit changes. All generation, Buck2 output, and pilot mutations happen inside that worktree. Verify with `git status --short` in the authored tree that a pilot run leaves it untouched.

Before selecting versions, register and read the sources as described in Context and Orientation, then pin: one Buck2 binary release verified against upstream tags (never the moving `latest` tag), with per-platform download checksums; one cabal-buck2 commit SHA; and the revision of the rule fork that cabal-buck2 bundles at that commit. Record them with the supported host platforms and the GHC identity in `dependencies.json`. Install the generator from the pinned source into a pilot-owned directory, for example with `cabal install --installdir` beneath `dist-conformance/buck2-pilot/bin`, compiled by the shell's GHC 9.12.4. Bootstrap must be rerunnable, verify checksums, and print an actionable unsupported-platform message rather than guessing. No Hackage bounds of any Keiro package change.

Resolve these feasibility questions in order, recording each answer in Surprises & Discoveries with the command and the decisive output. Stop at the first one that fails and apply the fallback rule below.

1. Cabal version skew. The shell provides cabal-install 3.16.1.0; cabal-buck2 links cabal-install 3.18.1.0 as a library and its README asks for a matching `cabal` binary without checking. Confirm on Hackage that this library version exists and builds under GHC 9.12.4. Determine whether a 3.18 `cabal` binary is required, and whether store entries built by 3.16 are reused or rebuilt. Count any rebuild as dependency provisioning time.
2. Solver equivalence. Run `cabal buck2 --enable-tests` in the pilot worktree. Compare the generated dependency set with `dist-newstyle/cache/plan.json` from an ordinary `cabal build all --enable-tests --dry-run` at the same commit: exact package versions, flag assignments (including `keiro-dsl +werror-generated` and `keiro-ops-http +compose-example`), and the `allow-newer: haxl:time` relaxation. cabal-buck2 permits one version per package in a plan; a disagreement is a finding, not something to paper over.
3. The leftover `codd` stanza. The maintainer intends to delete this stanza from `cabal.project` after the release in progress on 2026-11-18; check `cabal.project` first, and if the stanza is gone, record that and skip this question. Otherwise: nothing in the default dependency closure uses `codd`, but its `source-repository-package` stanza in `cabal.project` still puts it in the plan, and cabal-buck2 documents such entries only under `--source-deps`. Establish whether default mode, where Cabal builds dependencies into its store and Buck2 imports them prebuilt, tolerates the stanza. If it does not, do not switch the whole pilot to `--source-deps` for the sake of an unused package: give the pilot worktree a project file without the stanza, confirm the remaining plan is otherwise identical, and record that removing the stanza from `cabal.project` (keeping `legacy-codd-tools` buildable some other way) is a prerequisite for any expansion. Measuring `--source-deps` remains an optional extra mode in milestone 7.
4. Unsupported packages. List every dependency with `build-type: Custom`, `Hooks`, or a `foreign-library`. Do not pass `--keep-going` or `--enable-custom-setup` to make generation succeed unless the skipped or altered packages are named and shown to be outside the five pilot components' dependency closure.
5. Contract preservation. Read the generated `BUCK.cabal.bzl` for the pilot components and confirm each carries its own `default-language` and `default-extensions` (ADR-19), its `ghc-options` including the generated-output `-Werror` and any `-with-rtsopts`, its exact module list and source directories, and its dependency list, as the `.cabal` component declares them. A generated target that compiles conformance output under broader extensions or without the warning gate fails this milestone even if the build is green.

The first explicit compilation target is the existing `keiro-dsl-conformance` suite at `keiro-dsl/test/conformance`. Build it with `buck2 build` and run it with `buck2 test` from the pilot worktree, and confirm from Buck2's action log (`buck2 log what-ran`) that the compile and link actions invoke GHC directly, with no `cabal build` inside any Buck2 action. Prove repeatability: an unchanged rebuild runs no compile action, and changing one source in the `keiro` library invalidates the target. Re-run `cabal buck2` after any `.cabal` or `cabal.project` change, and have the pilot runner refuse to build when those files are newer than the generated output.

Fallback rule. If cabal-buck2 cannot generate, build, or preserve the contracts above after a concrete investigation of its source and the selected rules, record the failure and its exact scope in this plan and in the results document, with the upstream issue reference if one is filed. Then choose one of two outcomes and record it in the Decision Log. Either continue with a hand-written adapter for the stock Buck2 prelude: staged sources and exact dependency inputs for `keiro-dsl-conformance`, imported prebuilt dependencies from the improved Cabal solution using exact unit identities and declared interface, object, library, and package-configuration artifacts exported by Cabal, with compiler, flags, unit IDs, headers, and native libraries pinned as input identity, failing closed when artifacts cannot be enumerated without inspecting `/nix/store`. Or stop the pilot. The hand-written adapter is the larger effort and reintroduces a second module inventory that must be derived from the Cabal declarations, so choose it only when the cabal-buck2 failure is specific to that tool rather than to Buck2's Haskell support generally. In no case replace explicit compilation with a shell wrapper around Cabal.

This milestone tests interoperability. Its performance report must state which mode was used, list dependency provisioning time separately and inside end-to-end totals, and must not claim that Buck2 accelerated libraries that Cabal built.

### Milestone 6: prove the five representative components and correctness parity


The required correctness set is exactly five components: `keiro-dsl-conformance`, `keiro-dsl-conformance-structural-nominals`, `keiro-dsl-conformance-codec-compare`, `keiro-workspace-proof-conformance`, and `keiro-dsl-conformance-process-reactions`. These cover basic generated aggregate code, large structural/nominal output, file-based codec assertions, runtime-facade/package separation, and database-backed process behavior. The last two are essential correctness probes even if their timings are not the fastest wins. cabal-buck2 generates targets for the whole workspace, so a wider `buck2 build //...` may be attempted and reported as an additional datum, but it is neither required nor a substitute for the five.

Under the primary route the `.cabal` files remain the single module and dependency inventory, as ADR-22 requires, and no inventory exporter is written. Add instead a parity check to the pilot runner: for each of the five components, compare the generated target's sources, language edition, extensions, warning flags, dependencies, and runtime options against the component as parsed from its `.cabal` file with the active flags applied, and fail on any disagreement. Only under the hand-written fallback, add an inventory export command to `keiro-dsl/tools/corpus-regen/src/Main.hs` and `CorpusPlan.hs` that uses the tool's existing Cabal-syntax parsing, resolves conditionals for the active flags instead of reading unconditional fields only, and writes versioned JSON from which the pilot derives its targets.

Add `scripts/run-buck2-conformance.py` with prepare, build, test, mutation, and invalidation-check operations, exposed by optional `Justfile` recipes that are not dependencies of `_verify`. `prepare` creates or refreshes the worktree, runs the pinned generator, and runs the parity check. Record which compilation granularity is in effect: the upstream prelude and the fork's default compile one component's sources in a single `ghc --make` action, and the fork documents an opt-in per-module mode through a `DEFAULTS` setting. Verify that setting against the pinned fork source before relying on it, and measure both granularities in milestone 7 if it works.

The runner must reproduce the existing test contracts. Codec comparison reads package-relative files; establish which working directory `buck2 test` gives a test binary and how data files reach it, and treat a binary that starts in the wrong directory as a failure, not a pass. Database tests execute locally against the same provisioned PostgreSQL contract as Cabal; confirm that the connection environment variables reach the test process under Buck2's test executor, rerun them every time, and disable test-result reuse. Bound simultaneous runtime processes to the baseline CPU budget and retain required runtime options. Mutations edit the pilot worktree only. Reproduce the service workflow-name mutation, plus a process reaction guard mutation adapted from `process-reaction-mutation-test.sh`; both must compile and fail for their specific expected semantic observations under both backends, then pass after restoration. Each mutation step asserts that its edit changed the file, so a pattern that stops matching cannot yield a silent pass.

Add executable invalidation probes for a changed generated source, a hand-owned Hole or expectations change, a change to the `keiro` runtime library, a compiler-flag or default-extension change in a `.cabal` file followed by regeneration, and a version-banner-only source edit. Warm builds must rebuild affected targets rather than reuse a stale success. Unrelated fixture targets should remain reusable when their declared inputs are unchanged; capture the action trace instead of assuming this property. A deliberately missing source, fixture, or dependency must cause a clear error. Acceptance requires the same assertion outcomes and negative-proof diagnostics as Cabal under the current compiler contracts, plus recorded target invalidation. Generated toolchain and prebuilt-dependency paths are local to one machine and must be labeled non-portable; upstream states that sharing a cache between machines with different system software is not yet safe, so shared-cache eligibility cannot be claimed without an isolated-checkout test.

### Milestone 7: compare fairly and decide whether to expand


Measure the selected Cabal and Buck2 workloads on the same machine and same input revisions after milestone 4. Separate dependency bootstrap, generation, compilation/linking, test execution, and total wall time. Use three repeats for local-cold builds with dependencies available, unchanged warm builds, one-fixture edits, current-runtime-library edits, and provenance-only edits representing a release restamp. For Buck2, state for each number whether dependencies were prebuilt by Cabal or built from source by Buck2, and whether compilation was per component or per module; if both granularities work, measure the one-fixture and provenance edits under each. Time `cabal buck2` regeneration separately and include it in every scenario that changes a `.cabal` file. Revert benchmark mutations inside their owned copies before the next case. Report medians and ranges, compilation/action counts, concurrency, and cache mode. No Buck timing may omit a needed Cabal provisioning step from its corresponding end-to-end scenario.

If a shared remote cache service is already available and explicitly authorized, run an additional second-checkout experiment using declared, portable inputs. The Buck2 cache stores action outputs by their input identity; it is not an automatic cache of PostgreSQL assertion outcomes. Do not purchase a service or provision infrastructure under this plan. Without a service or portable toolchain, report shared caching as unmeasured and retain the useful local experiment. Consult the [official remote-execution documentation](https://buck2.build/docs/users/remote_execution/) when configuring an available service, and embed the exact successful configuration and input requirements in the pilot README.

Recommend expansion only if all correctness/invalidation proofs pass and the pilot's end-to-end median is at least 25% faster than improved Cabal in either the one-fixture-edit scenario or a release-like provenance edit, without a greater than 10% regression in the local-cold scenario. This threshold is an experiment decision rule, not a promised result. An unchanged warm win alone, or a win that disappears after dependency provisioning is counted, does not establish faster releases. If timing variance crosses the threshold, run three additional repeats and record uncertainty instead of selecting favorable samples. Require a supported, reproducible dependency/toolchain path before recommending shared-cache adoption.

Write the recommendation, maintenance cost (including dependence on a young generator and a forked prelude, each pinned by commit, and the Cabal version it requires), observed unsupported cases, and estimated effect on the separately measured whole gate into `docs/conformance/build-reuse-and-buck2-results.md`. Expansion means a recommendation and follow-up scope, not replacing `just verify` or migrating the remaining conformance suites in this plan. If Buck2 is slower or impractical, retain the completed Cabal improvements and mark the optional pilot as an experiment with a documented stop decision. Run the final appropriate repository gates once after the last implementation changes. Distill cache ownership and the pilot decision into a new ADR or a focused amendment, using the existing OKF profile workflow.


## Concrete Steps


These are implementation commands, not claims that this planning session ran the conformance gate. New script commands become available in their milestones. Begin at the repository root in the provisioned shell:

```bash
nix develop
command -v ghc
command -v cabal
command -v python3
ghc --numeric-version
cabal --numeric-version
z3 --version
git status --short
just process-compose-check
```

The last command must provision or validate the PostgreSQL prerequisite as the existing gate expects. If it fails, resolve that concrete environment failure before interpreting database-test timings. Source discovery and version verification precede dependency adapters:

```bash
mori registry list
mori registry search buck2
mori registry search cabal-buck2
mori registry search haskell-buck2
mori registry search Cabal
```

For each actual result, run `mori registry show <qualified-project> --full` and `mori registry docs <qualified-project>` using the discovered qualified name. If absent, acquire/register a scoped source checkout and record its canonical project URI and revision before proceeding. Consult upstream tags through the official repository, for example:

```bash
git ls-remote --tags https://github.com/facebook/buck2.git
git ls-remote --tags https://github.com/simonmar/cabal-buck2.git
git ls-remote --heads https://github.com/simonmar/haskell-buck2.git
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

`just verify` refuses to run outside the Nix shell and fails at once if another release or verification writer holds the workspace lock; wait for that writer instead of removing the lock file.

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

Milestone 5 first proves the generator by hand inside the pilot worktree, before the runner script wraps it. With the pinned `buck2` and `cabal-buck2` executables on `PATH`:

```bash
git worktree add --detach dist-conformance/buck2-pilot/checkout HEAD
cd dist-conformance/buck2-pilot/checkout
cabal buck2 --enable-tests
buck2 targets //keiro-dsl:
buck2 build //keiro-dsl:keiro-dsl-conformance
buck2 test //keiro-dsl:keiro-dsl-conformance
buck2 log what-ran
```

The target label shown is the expected shape, a package directory followed by the Cabal component name; take the real label from the `buck2 targets` output. If generation rejects the unused `codd` source-repository-package stanza, record the transcript and apply feasibility question 3 in milestone 5. Back in the repository root, `git status --short` must show no change caused by the pilot.

Milestones 5–7 add these root-level pilot interfaces:

```bash
python3 scripts/run-buck2-conformance.py prepare
python3 scripts/run-buck2-conformance.py build
python3 scripts/run-buck2-conformance.py test
python3 scripts/run-buck2-conformance.py mutation
python3 scripts/run-buck2-conformance.py invalidation-check
python3 scripts/measure-conformance.py pilot --runs 3 --output dist-conformance/reports/pilot.json
```

`prepare` must print the resolved compiler, the pilot worktree's commit, the immutable Buck2, cabal-buck2, and rule-fork pins, the dependency mode (prebuilt by Cabal or built from source), the compilation granularity, the selected components with their parity-check result, and whether imported dependencies are local-only. `test` reports each of the five components as passed only after executing its assertions. `mutation` reports the expected behavior failure and restored baseline; it fails on compilation errors. `invalidation-check` reports affected versus reused actions for each input-change case and fails if changed inputs reuse a stale artifact. The final results document contains real measured numbers and links to scoped log artifacts or sanitized committed excerpts; do not paste fabricated sample timings.

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

Phase two succeeds as an experiment when five explicit Buck2-compiled components, whose generated targets pass the parity check against their `.cabal` declarations, run the same assertions as Cabal, negative semantic proofs fail for the correct reasons, restoration turns them green, and invalidation evidence prevents stale compilation from being accepted. If cabal-buck2 fails, the fallback rule in milestone 5 decides between the hand-written adapter and stopping. If the Haskell/toolchain prototype proves infeasible, completion requires a reproducible scoped failure, a recorded investigation of the exact selected source rules, and an explicit stop decision; do not mark unimplemented target parity as passed. Such an outcome keeps phase one complete and reports phase two as a rejected pilot rather than a successful implementation.

The whole plan requires an evidence-backed expansion or stop recommendation and ADR distillation. Faster unchanged builds do not automatically prove a faster release: banner changes, package-version/dependency-unit changes, corpus generation, PostgreSQL assertions, Hackage packaging, and Haddock can still cost time. The final report must state which of those costs were measured and which remain outside the pilot. No fixture, warning gate, immutable expectation, supported-language test, or required database assertion may disappear to satisfy a performance target.


## Idempotence and Recovery


All scripts are repeatable from the root and store generated work only beneath `dist-conformance` or explicitly ignored pilot output. Separate build configuration namespaces prevent probe flags or incompatible compilers from contaminating the default build. Cabal and Buck inputs drive freshness; neither helper stores a durable “test already passed” bypass. Synchronizing fixture inputs preserves timestamps when content is unchanged and restores original inputs before every proof. Cache clearing is limited to one resolved owned namespace and is never a reason to remove the global Cabal store or developer build state.

Operating-system locks release on process termination. Interruptions leave reusable compilation files but cannot leave accepted semantic success; the next invocation restores authored inputs and reruns the sequence. Keep specific failed run logs for diagnosis. A second process must not access the same mutable build/source area until it holds the lock. Tracked-source mutation proofs run serially and start from clean relevant paths. For any new mutation, prefer a pilot/proof copy over editing the tracked corpus, and preserve independent expectations through both mutation and recovery.

The Buck pilot is additive and optional. Its worktree is disposable: `git worktree remove --force dist-conformance/buck2-pilot/checkout` followed by `prepare` rebuilds it, and `git worktree prune` clears a stale registration if the directory was deleted by hand. Stop the pilot's Buck2 daemon with `buck2 kill` run inside the worktree, never by process name. If it is rejected, remove only its optional recipes/configuration in a focused follow-up or retain them clearly labeled experimental; keep the Cabal reuse helpers and evidence. No release, package upload, repository push, compiler migration, or paid remote infrastructure change is authorized by this plan. Unrelated working-tree files remain untouched; at the 2026-11-18 refresh these were a modified plan 344 and two untracked benchmark result files under `keiro/bench/results/release-gates/`.


## Interfaces and Dependencies


`scripts/conformance-workspace.py` owns path containment, configuration namespaces, content-preserving fixture synchronization, and lock lifetime. Its Python API must provide `configuration_key(metadata) -> str`, `locked_workspace(root, namespace, metadata)` as a context manager, and `sync_owned_tree(source, destination, manifest) -> SyncReport`. `SyncReport` reports copied, unchanged, and removed owned files. The key records tool/platform/configuration identity; it excludes ordinary commit IDs and source content so source edits reuse the same local build area. The child command interface uses argument arrays and propagates exit status rather than constructing a shell command from strings. Persistent fixture cleanup operates only on manifest-owned files inside the locked destination.

`scripts/check-service-package-mutation.py` implements the repository integration proof, returns nonzero on any unexpected result, and accepts an optional explicit `--dsl-executable` path. `scripts/measure-conformance.py` accepts `baseline|reuse|pilot`, positive `--runs`, and `--output`; its versioned JSON records metadata plus scenario/phase/command/elapsed-seconds/exit-code/log-path for every executed command. Report summaries retain expected negative-proof outcomes separately from unexpected failures and include median/range calculations without overlapping-duration summation.

`scripts/run-buck2-conformance.py` owns the pilot worktree, runs the pinned cabal-buck2 generator and Buck2 tool inside it, and implements the parity check between generated targets and `.cabal` components. It refuses to build when a `.cabal` file or `cabal.project` is newer than the generated output, must not rely on an ambient GHC package environment, and must not expose multiple ambiguous same-name units. `tools/buck2-conformance/dependencies.json` records the Buck2 release and checksums, the cabal-buck2 commit, the bundled rule-fork revision, the cabal-install library version the generator links, supported platforms, and the GHC identity. The report distinguishes dependencies prebuilt by Cabal from native Buck2 compilation of Keiro libraries. The corpus inventory exporter exists only under the hand-written fallback; it is then repository tooling, not a new public DSL API, with a versioned JSON schema, Cabal's resolved build information for conditional branches, and generated/hand-owned source roles and fixture paths. Runtime-package/facade separation and create-once expectations remain as required by ADR-20.

Existing Cabal, GHC, Python, PostgreSQL and native libraries remain the phase-one dependencies. Buck2, cabal-buck2, and its bundled rule fork are pilot-only additions pinned after authoritative verification. Prefer standard-library helpers and the corpus tool's existing Cabal-syntax dependency; do not add a new parsing or locking library by memory. Use Mori for any dependency-source lookup, and verify released versions upstream before changing dependency bounds or pins. References to external repositories remain canonical `mori://` project/artifact references, with project-relative paths explicitly labeled when artifact URI coverage is pending.


## Revision Notes

2026-11-18: refreshed against commit `fd179d77` (release 0.26.0.0) and redirected the Buck2 pilot. Inventories were re-counted (64 suites, 912 generated files, 22 mutation scripts). `verify` is now a locked wrapper around the private `_verify` recipe, so the new proof recipe is added to `_verify` and the proof helpers keep a lock separate from the release workspace lock. Milestone 1 now times every proof recipe, and the boundary with plan 346, which owns the structure of mutation scripts, is explicit. Milestones 5 and 6 were rewritten to try cabal-buck2 first in a dedicated worktree, with ordered feasibility questions and a parity check replacing the custom inventory exporter; the original hand-written adapter remains as the recorded fallback. The expansion rule in milestone 7 is unchanged. No implementation has started. A same-day follow-up corrected the treatment of `codd`: it is no longer a default dependency, only a leftover project stanza, so it no longer forces the source-dependency mode.
