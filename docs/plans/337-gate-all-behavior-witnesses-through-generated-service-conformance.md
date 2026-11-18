---
id: 337
slug: gate-all-behavior-witnesses-through-generated-service-conformance
title: "Gate all behavior witnesses through generated service conformance"
kind: exec-plan
created_at: 2026-11-17T04:40:56Z
intention: intention_01m7qnn0j2e1ctggvgypjgd4fe
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-17T04:40:56Z
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-18T15:47:09Z
      mode: "update"
      note: "Review against 43c9cdcb: per-key rows via contract export, reuse service-package fixture, add gates and guarantee evidence; no open IR absorbed"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-18T16:09:06Z
      mode: "implement"
      note: "Milestones 1-3 implemented: contract rows, facade action, runner flag, compiled matrix, docs, ADR-20 amendment"
---

# Gate all behavior witnesses through generated service conformance

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Distill durable decisions into the relevant ADRs at implementation completion.

## Purpose / Big Picture


Provide an explicit `--behavior-complete` mode in the generated conformance test executable. Applications that deliberately require every declared behavior witness can then enforce that policy without writing a second runner or exposing private aggregate modules. A witness is a concrete history, command or event sequence, and expected result supplied by the application; it provides finite evidence, not a universal proof.

This is an optional integration improvement, not a fix for incorrect default conformance behavior. The current default deliberately exercises hole-owned initial live edges, as documented. Preserve that default. Rejecting missing, pending, duplicate, stale, or false evidence across the entire inventory must be an explicit application choice.

The terms used below mean the following in this repository. A hole is a module the application owns and fills by hand; `keiro-dsl scaffold` creates it once and never overwrites it (create-once). A generated module is rewritten on every scaffold. `BehaviorContract` is the generated per-aggregate module listing the required behavior keys and the evaluator for them; `BehaviorHoles` is the create-once module where the application lists one witness per key, initially `Pending`. The facade is the single generated module `<Context>.Generated.Conformance` that the runtime library exposes; the generated conformance package is a separate Cabal package whose `Main.hs` imports only that facade. The corpus is the set of committed scaffold outputs under `keiro-dsl/test/conformance-*` that `just corpus-regen` rewrites and `just conformance-corpus-policy` checks for drift.

## Progress


- [x] Expose full behavior checks through the existing generated service facade, with execution tests for all report failure classes. (2026-11-18) The contract exports `behaviorConformanceRows` and the facade exports `runServiceBehaviorChecks`. On the committed fixture the full rows are exactly: Alpha `missing/` for its four required keys, Alpha `stale/behavior-v1-e2c1eef1cb7848f5`, Beta `pending/behavior-v1-6ab7fee2c8aa4e1d`, and one summary row per aggregate, Assignment's passing with `verified=1 unverified=3`.
- [x] Add and exercise the generated runner's explicit full-witness mode across the runtime-package boundary. (2026-11-18) The runner takes `--behavior-complete` and `--help`, and any other argument exits with status 2. The test "keeps the default run free of witness evaluation and gates every witness only under --behavior-complete (plan 337)" in `keiro-dsl/test/Main.hs` compiles the generated package against the private runtime library. It also proves default-green/full-red on the committed witnesses and full-green once the witnesses are filled.
- [x] Regenerate affected corpus fixtures and document the policy, with existing default behavior preserved. (2026-11-18) The corpus regen touched only `BehaviorContract.hs` (50 files), the service-package facade, and its runner `Main.hs`. The default run's 43 check lines are byte-identical to the pre-change baseline. The user guide, changelog, and ADR-20 are updated.

## Surprises & Discoveries


The originating report describes a green default conformance run as a bug, but `docs/user/keiro-dsl-workspaces-and-generated-code.md` explicitly limits that runner to hole-owned live initial edges. The full `behaviorCoverageReport` already exists. The missing capability is generated service-level integration of that report.

2026-11-18 (plan review at `43c9cdcb`): `renderBehaviorConformanceText` cannot satisfy the acceptance requirement that a failure names its behavior key. Its `countLine` helper prints only a count for pending, missing, duplicate, and stale; only `failed` rows carry a key.

```haskell
countLine :: Text -> [BehaviorKey] -> Text
countLine label values = label <> ": " <> tshow (length values)
```

A `Pending` witness therefore renders as `pending: 1` with no key. The facade needs per-key rows, not that text.

2026-11-18: the report's record fields are not spelled the same in the generator source and in generated output. `emitBehaviorContract` writes `reportRequired`, `reportPending`, and so on, while every committed `BehaviorContract.hs` in the corpus has `required`, `pending`, and so on. Facade text that reads those fields directly would have to follow the same renaming; calling exported contract functions avoids the question.

2026-11-18: the motivating case is already committed and already a project package. `keiro-dsl/test/conformance-service-package/` is a three-aggregate workspace (`Alpha`, `Beta`, `Assignment`) whose runtime library and generated package `keiro-workspace-proof-conformance` are both listed in `cabal.project`. `Alpha` and `Beta` have no hole-owned initial edge and each has exactly one `Pending` witness; `Assignment` has four filled witnesses including a replay witness. Its default run is green today. No new fixture is needed to prove the package boundary.

2026-11-18 (implementation): Alpha's committed witness is stale, not Pending. `domain/alpha.keiro` was extended after `BehaviorHoles.hs` was created, so the one committed row names a retired key while all four current keys are missing. Full mode reports `stale/behavior-v1-e2c1eef1cb7848f5` and four `missing/` rows instead of a `pending/` row. This is a better demonstration of create-once drift, so the committed file is kept as it is. Beta's row is a genuine `Pending`.

2026-11-18 (implementation): the field renaming lives in `keiro-dsl/internal/Keiro/Dsl/GeneratedHaskellLanguage.hs` (`idiomaticV2LabelMigrations`). It rewrites identifiers, but not strings or comments, in every generated module after emission. Emitter code therefore keeps writing `report.reportPending`, and the new `behaviorConformanceRows` does the same.

2026-11-18 (implementation): `Alpha`'s `LegacyPingAlpha` rejection cell (`behavior-v1-c062ccf5e9b6f5c4`) supplies the rejection case. The runtime returns `NoMatchingEdge` there, because `Active` has outgoing live edges but none for that command. No new rejection cell or fixture was needed.

2026-11-18 (implementation): `just corpus-regen` does not rewrite `keiro-dsl/test/conformance-newsurface/Generated/TransferRouting/Conformance.hs`. It is a `legacy-generated` row in `keiro-dsl/test/conformance-corpus-manifest.txt`: a hand-maintained golden with the pre-version banner, compared by the test "normalizes aggregate and read-model checks behind one base-only API". Its body was updated from current `keiro-dsl scaffold --runtime-package` output, keeping its banner. That facade is compiled by `keiro-dsl-conformance-newsurface`, so the suite now also lists `Generated.TransferRouting.Hospital.BehaviorContract` and `TransferRouting.Hospital.BehaviorHoles` and depends on `containers`. The contract's `uncompiled-generated` exemption was removed, because the corpus policy rejects an exemption for a module that is now compiled.

2026-11-18 (implementation): `cabal test keiro-dsl:tests --test-options=...` passes the options to every keiro-dsl test suite, and the non-hspec suites reject hspec `--match`. Focused runs must target `keiro-dsl:test:keiro-dsl-test`.

2026-11-18: Mori resolution works again. `mori path mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-2` and `mori path mori://shinzui/keiro/okf/adrs/concepts/ADR-20` both resolve. Since the plan's baseline `fd869833`, the only change to the files named in Context and Orientation is a 25-line topology-related edit to `Scaffold.hs`; every function this plan names still exists.

## Decision Log


2026-11-17: Preserve default conformance semantics and add an explicit policy flag. The user specifically excludes changes motivated by misuse. Treat the expectation that default conformance proves all witnesses as incorrect usage, while addressing only the independently demonstrable integration gap.

2026-11-17: Keep aggregate `BehaviorHoles` and `Generated.BehaviorContract` private. ADR-20 intentionally exposes one service facade. Neither changing the Cabal fragment to expose every aggregate nor automatically editing consumer holes is required.

2026-11-17: Do not require opaque evidence to become universally verified. Use `behaviorConformancePassed`, whose existing policy rejects incomplete or false finite evidence but permits honestly unverified predicates. A new stricter unverified-evidence policy is outside this plan.

2026-11-18: Report one row per offending key through a new generated contract export instead of embedding `renderBehaviorConformanceText` in a label. The text renderer omits the keys the acceptance criteria require, its output is multi-line while the runner prints one `PASS`/`FAIL` line per row, and a contract-level function keeps the facade free of record-field names. This adds one export to every regenerated `BehaviorContract.hs`; it is needed to meet the existing acceptance, not a new guarantee.

2026-11-18: Use the committed `keiro-dsl/test/conformance-service-package/` workspace for the package-boundary proof instead of adding a fixture. It already contains the motivating case and three owners, and it is already compiled as a project package. Keep its committed `Alpha` and `Beta` witnesses `Pending` so the repository itself demonstrates default-green and full-mode-red; tests that need a passing full run fill them in a temporary copy.

2026-11-18: Do not expand this plan to absorb an open improvement request. Every request in `docs/improvement-requests/` with status `proposed`, `accepted`, or `in-progress` was checked (IR-5, IR-7, IR-8, IR-10, IR-25, IR-33, IR-34, IR-37, IR-38, IR-40, IR-47, IR-48, IR-49, IR-51, IR-52, IR-61). None concerns `ServiceHarness.hs`, `ConformancePackage.hs`, the behavior contract, or witness gating; they are runtime, language-surface, diff, or tooling requests with their own plans or none. The only contact point is that FRIC-3 is consumer evidence for IR-10, recorded in the triage section below.

2026-11-18 (implementation): Row labels are path-shaped, `aggregate/<Name>/behavior/<category>/<key>`, so they match the existing `aggregate/<Name>/<fact>` check keys. A failure row carries the same text `renderBehaviorConformanceText` prints after `FAIL`, and the summary is `summary required=N filled=N …`. The runner prints the unchanged default output first and the behavior rows after it. A duplicate-fact failure now records failure and continues instead of exiting immediately, so full mode still reports behavior rows. Default-mode output and exit status are unchanged.

2026-11-18 (implementation): The facade selects aggregates with a new `Keiro.Dsl.Scaffold.aggregateHasBehaviorContract :: Aggregate -> Bool`, which shares its body with `hasVersion2Ownership`. That is one additive export from an exposed library module, so the Interfaces claim that the public API does not change is slightly wrong. The changelog records it, and `just dsl-api-boundaries` checks only constructor boundaries.

2026-11-18 (implementation): Two acceptance cases have no witness-only lever, so the test simulates them in its temporary copy. The no-aggregate case compiles the scaffolded `contract-v4.keiro` facade, which has no imports, as a base-only runtime library next to its generated package. A false ordinary check while every behavior row passes is produced by inverting `validateTransducer is empty` in the copy's generated `Beta/Generated/Harness.hs`. All read-model checks are generated, and every hole-owned initial edge shares its evidence with a behavior witness.

2026-11-18: The stricter policy named in the 2026-11-17 entry is not new. `behaviorConformancePassedWith True` and the hand-written runner's `--fail-on-unverified` already exist, and the user guide says a consuming CI may choose it. This plan still does not surface it through the generated runner, so a consumer who wants it keeps a hand-written runner and the manual module exposure of FRIC-6 and FRIC-11. Adding a second generated flag is a scope decision for the user, not an implementation detail.

## Outcomes & Retrospective


Implemented 2026-11-18. The generated runner now offers `--behavior-complete`. An application can require every declared witness without a hand-written runner or exposing private modules, and the default gate is unchanged.

Tests actually run, all inside `nix develop` at the implementation commit:

- `z3 --version`: 4.16.0.
- Baseline before any change: `cabal test keiro-dsl:keiro-dsl-conformance-behavior-complete` passed (19 required, 17 verified, 2 unverified), and `cabal test keiro-workspace-proof-conformance` passed with 43 check lines.
- After regeneration, the default run of `keiro-workspace-proof-conformance` printed exactly those 43 lines (`diff` empty) and exited 0. `--test-options=--behavior-complete` exited 1 with the rows listed in Progress. The compiled binary's `--help` exited 0, and `--bogus` exited 2.
- `keiro-dsl:test:keiro-dsl-test` `--match "plan 337"`: three examples, all passing. The compiled matrix took 278 s. In both modes on one temporary copy, it covers the committed witnesses and correct witnesses for all nine keys, and each of these breaks full mode with the aggregate and key while the default stays green: missing, duplicate, stale, incorrect live (`event-value-mismatch`), incorrect rejection (`rejection-class`), incorrect replay, and a history-dependent Assignment replay. A changed Expectations fact and a false ordinary check both fail full mode while every behavior row passes. Re-scaffolding leaves all three `BehaviorHoles.hs`, `Expectations.hs`, and the Cabal fragment byte-identical, and the generated `Main.hs` imports only the facade. The no-aggregate package passes `[]`, `--behavior-complete`, and `--help`, and rejects `--behavior-completed`.
- Full gate on committed `c60e8a96`:
  - `cabal test keiro-dsl:tests`: 61 suites passed, none failed; `keiro-dsl-test` ran 963 examples with 0 failures.
  - `keiro-dsl-conformance-behavior-complete` and `keiro-workspace-proof-conformance` (default mode) both passed.
  - `just conformance-corpus-policy` passed (`conformance corpus: ok`).
  - `keiro-dsl/test/behavior-complete-mutation-test.sh` caught all 13 report mutations, then stopped at "reset source-wide predicate edge indices". That mutation's `perl` target `let edgeIndex = layoutOutgoingIndex entry` has been absent from `keiro-dsl/src` since `7b06bc52`, before this plan's baseline `43c9cdcb`, so the mutation is a no-op unrelated to this plan; the script is not part of `just verify`.
  - `just verify` first failed on a stale `keiro-dsl/generated-haskell-edition-idiomatic-v2.md`. The newsurface facade had been updated after the inventory was regenerated, so the inventory was regenerated again. On `2c3e5333`, `just verify` then passed end to end, with exit 0.

Guarantees, each with the check that shows it:

- Default semantics: the 43-line baseline diff, and `expectDefaultGreen` after every mutation in the matrix.
- Opt-in compatibility: the corpus regen diff touches no fixture without a runtime package except its `BehaviorContract.hs`.
- Module privacy: the fragment is byte-identical after re-scaffold, enforced by the corpus drift gate and asserted in the matrix test.
- Ownership: hole and Expectations bytes are asserted unchanged.
- Report schema: no change to `ToJSON` or `renderBehaviorConformanceText`, covered by `keiro-dsl-conformance-behavior-complete` and the mutation script.
- Witness strength: rows come from the same `behaviorCoverageReport`, and the summary boolean is `behaviorConformancePassed`.
- Performance: no runtime, codec, wire, snapshot, or solver path is touched, and the default mode never calls the new action.

Remaining limitations: the stricter `behaviorConformancePassedWith True` policy is still not a runner flag; see the 2026-11-18 decision. The consumer command in Concrete Steps has not been run, because the consumer has not regenerated.

## Context and Orientation


The source review compared Keiro commit `fd869833fc369ee6bcdbf9fbf9f3f9ef10c85272` with consumer `mori://tan/agent-reputation-service` at commit `4e58fd0221fa2a739192668d77317354b8abf978`. Consumer generated files identify keiro-dsl 0.25.1.0. No dependency bounds or versions are proposed. Mori registry discovery failed during the original source review; on 2026-11-18 the URIs below resolve with `mori path`, the consumer is at `6f5578b1dc402e4f26d67dae0c36a71bdf92baa4`, and Keiro is at `43c9cdcb`.

The originating evidence is `mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-2`. Related visibility reports are `mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-6` and `mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-11`. Their attempted manual full-report gate explains the repaste cost, but private modules are intentional.

`keiro-dsl/src/Keiro/Dsl/Harness.hs` emits aggregate `harnessAssertions`. Its `initialWitnessProbeEntries` filters live transitions from the initial vertex to those with Hole implementation. It imports witness contracts only when that subset is nonempty. `keiro-dsl/src/Keiro/Dsl/ServiceHarness.hs` collects those assertions through `checkExpression`; it does not execute all behavior requirements. `keiro-dsl/src/Keiro/Dsl/ConformancePackage.hs` emits the runnable package and its Main, importing only `runServiceConformanceChecks` and `serviceConformanceFacts`. `keiro-dsl/src/Keiro/Dsl/Manifest.hs` exposes only the service facade and keeps other modules private.

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, in `emitBehaviorContract`, already emits `behaviorCoverageReport`, `behaviorConformancePassed`, and `renderBehaviorConformanceText`. Reuse those functions. `keiro-dsl/test/conformance-behavior-complete/Main.hs` is an existing hand-written full-report runner, demonstrating the machinery independently of generated service integration. `keiro-dsl/test/Main.hs` owns generator tests. `keiro-dsl/test/fixtures/behavior-complete.keiro` and its committed `keiro-dsl/test/conformance-behavior-complete/` output provide the behavior cases.

[ADR-17](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md) separates generated behavior from consumer-owned holes and defines finite witness evidence. [ADR-20](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md) requires one runtime-owned facade rather than exposing every internal module. Preserve both boundaries. Update ADR-20 when the optional mode ships.

## Plan of Work


Milestone 1 adds `runServiceBehaviorChecks :: IO [(String, Bool)]` to the generated service facade emitted by `renderServiceHarness` in `keiro-dsl/src/Keiro/Dsl/ServiceHarness.hs`. A behavior-bearing aggregate is one for which `scaffoldAggregateForService` in `Scaffold.hs` emits `BehaviorContract` and `BehaviorHoles`, that is, one satisfying `hasVersion2Ownership`; use that same predicate so the facade never imports a module that was not generated. For each such aggregate, import its contract and its create-once witness module under qualified aliases derived from the alias `aliasNodes` already assigns to the aggregate (for example `AlphaBehaviorContract` and `AlphaBehaviorHoles`), so the existing collision numbering carries over.

Add one export to the generated contract in `emitBehaviorContract`, `behaviorConformanceRows :: BehaviorConformanceReport -> [(Text, Bool)]`. It returns one false row for every pending, missing, duplicate, and stale key and for every failure, each a single line that contains the key and the category (for a failure, the same text `renderBehaviorConformanceText` prints after `FAIL`), followed by one summary row whose boolean is `behaviorConformancePassed report` and whose label carries the counts. Unverified keys produce no false row. The facade computes `behaviorCoverageReport behaviorWitnesses` once per aggregate and prefixes each row with `aggregate/<Name>/behavior/`. This returns simple base types across the package boundary and keeps all aggregate-specific types private. Return an empty list for services without behavior-bearing aggregates. Do not put full-report calls into the existing `harnessAssertions` or `runServiceConformanceChecks`, which would change established semantics.

Verify Milestone 1 on the committed service-package fixture after regeneration: `runServiceConformanceChecks` is unchanged and all true, while `runServiceBehaviorChecks` contains false rows naming `Alpha` with `behavior-v1-e2c1eef1cb7848f5` and `Beta` with `behavior-v1-6ab7fee2c8aa4e1d`, a true summary row for `Assignment`, and each aggregate exactly once.

Milestone 2 changes `renderMain` in `keiro-dsl/src/Keiro/Dsl/ConformancePackage.hs` to recognize `--behavior-complete` and `--help` with explicit usage and a nonzero exit for unknown options. Always run the existing checks and fact comparison, printing the same lines in the same order as today. Only when the full mode is selected, run `runServiceBehaviorChecks` and print its rows after the existing output; any false row fails the executable. In default mode the action must not be run at all, so a default run does no witness evaluation it does not do today. The help and documentation must state that default checks are not a complete witness gate.

Verify Milestone 2 across the real package boundary with the two project packages already in `cabal.project`: the runtime library keeps `BehaviorHoles` and `BehaviorContract` under `other-modules` exactly as the generated fragment lists them, and the generated `Main.hs` imports only the facade. The default run exits zero. The full run exits nonzero and prints the `Alpha` and `Beta` keys above. Then, in the style of the existing test "keeps Expectations fixed and turns the generated target red for a changed workflow fact" in `keiro-dsl/test/Main.hs` (copy the fixture with `copyTextTree`, write a temporary project file, run `cabal test` with `readProcessWithExitCode`), replace the two `Pending` rows with correct witnesses in the copy and assert that the full run exits zero. This package-boundary proof is required before expanding test variants.

Milestone 3 extends the compiled matrix, again by mutating a temporary copy: missing, duplicate, and stale keys, and incorrect live, rejection, and replay evidence, each failing full mode with the aggregate and key in the output while the default run of the same copy stays green wherever the mutated key is not a hole-owned initial edge. `Assignment` supplies the history-dependent and replay cases; if the workspace has no reachable rejection cell, add one to `Alpha` or `Beta` rather than a new fixture. Keep unverified-but-otherwise-valid evidence passing under the established report policy. Assert that a scaffold without a runtime package produces the same bytes as before apart from the regenerated `BehaviorContract.hs`, and that a service with no aggregates passes both modes. Regenerate affected output through the corpus tool, preserving hand-owned witness files. Update `docs/user/keiro-dsl-workspaces-and-generated-code.md` (the "Aggregate behavior evidence" section, which today describes only the initial-edge scope) with explicit default versus full-mode commands and migration instructions, add an Unreleased entry to `keiro-dsl/CHANGELOG.md`, and amend ADR-20. Consumers may remove manual exposure only after switching their CI gate and confirming they have no other direct imports.

## Concrete Steps


Run from the Keiro repository root. All build and repository checks use its Nix shell. First establish the solver and existing report baseline:

```bash
nix develop -c z3 --version
nix develop -c cabal test keiro-dsl:keiro-dsl-conformance-behavior-complete --test-show-details=direct
```

Record the default baseline of the generated package before changing anything; it must exit zero:

```bash
nix develop -c cabal test keiro-workspace-proof-conformance --test-show-details=direct
```

Implement the contract export, facade, and runner in the files above and add regression cases to `keiro-dsl/test/Main.hs`. No new test component or corpus row is expected, because the service-package workspace is already a `workspace` row in `keiro-dsl/test/conformance-corpus-manifest.txt` and already a project package. Do not depend on the external consumer checkout.

Editing `Scaffold.hs` shifts line numbers that a committed inventory records, so regenerate that inventory together with the corpus, then run the focused suites and the full gate:

```bash
nix develop -c just corpus-regen
nix develop -c python3 scripts/generate-record-migration-manifests.py
nix develop -c cabal test keiro-dsl:tests --test-show-details=direct
nix develop -c cabal test keiro-dsl:keiro-dsl-conformance-behavior-complete --test-show-details=direct
nix develop -c cabal test keiro-workspace-proof-conformance --test-show-details=direct
nix develop -c just conformance-corpus-policy
nix develop -c just verify
nix develop -c git diff --check
```

The full-mode fixture command is below. Against the committed fixture it must exit nonzero and name the `Alpha` and `Beta` keys, because their witnesses stay `Pending` on purpose:

```bash
nix develop -c cabal test keiro-workspace-proof-conformance --test-options=--behavior-complete --test-show-details=direct
```

The generated consumer command, from a consumer's development shell, will be:

```bash
cabal test keiro-agent-reputation-service-conformance:conformance --test-options=--behavior-complete --test-show-details=direct
```

This consumer command describes the intended interface; do not run it against an unregenerated released runner and mistake its behavior for implementation acceptance. The passing full-mode run exists only inside the test that fills the witnesses in a temporary copy; that test asserts the process exit status.

## Validation and Acceptance


A service with valid initial checks and Pending non-initial evidence passes the unchanged default but fails `--behavior-complete`. Replacing Pending with a correct history-backed witness makes full mode pass. Missing, duplicate, stale, and behaviorally incorrect evidence each fail with the relevant aggregate and key. Include replay-only and rejection obligations, not just live commands. False ordinary checks or changed expectation facts still fail even when full behavior evidence passes.

A runtime library assembled from the generated fragment compiles with BehaviorHoles and BehaviorContract under `other-modules`; the separate generated test package executes full checks using only the exposed facade. Re-scaffolding requires no manual exposure edits and preserves hand-owned witnesses byte-for-byte. No-aggregate services pass both modes, and multi-aggregate workspaces report each owner exactly once. Help describes policy accurately and unknown flags fail visibly.

Generator string assertions alone are insufficient: retain an actual generated-package compile and process-exit test. Do not call the plan complete based solely on the existing hand-written full-report runner passing. Record tests actually run separately from proposed commands.

Existing guarantees must be shown intact, each by a named check rather than by argument. Default semantics: the default run of `keiro-workspace-proof-conformance` prints the same lines before and after and still exits zero with `Alpha` and `Beta` pending. Opt-in compatibility from ADR-20: a scaffold with no runtime package emits no facade and no package, and its only byte change is the added contract export. Module privacy: the Cabal fragment and `Manifest.hs` output are unchanged, checked by the corpus drift gate. Ownership: create-once `BehaviorHoles.hs` and `Expectations.hs` are byte-identical after regeneration. Report schema: `keiro/behavior-conformance/1` JSON and `renderBehaviorConformanceText` are unchanged, checked by `keiro-dsl-conformance-behavior-complete` and `keiro-dsl/test/behavior-complete-mutation-test.sh`. Witness strength: the new rows come from the same `behaviorCoverageReport` and `behaviorConformancePassed`, so nothing passes in full mode that the hand-written runner would fail. This change emits test-only generated code and touches no codec, wire format, snapshot, solver query, language-version gate, or runtime path, so no `keiro-bench` guard measures it and none is needed; the only cost is witness evaluation in a test process that asked for it.

## Idempotence and Recovery


Regeneration may overwrite generated files but must preserve create-once expectations and witnesses. Save the current diff before corpus regeneration; if it changes unrelated output, inspect and restore only task-owned changes. No database migration, dependency upgrade, consumer rewrite, or release is part of this plan. A consumer can stop requesting full mode without changing persisted data. Do not delete hand-owned holes to obtain regenerated defaults.

## Interfaces and Dependencies


Add the generated facade export `runServiceBehaviorChecks :: IO [(String, Bool)]`, the generated contract export `behaviorConformanceRows :: BehaviorConformanceReport -> [(Text, Bool)]`, and the generated runner flag `--behavior-complete` (plus help and argument validation). Retain existing default facade signatures and report schema. Use the existing generated behavior contract, no new witness evaluator. The facade converts `Text` to `String`, and the runtime fragment already lists `text` for behavior-bearing services. The public API of the `keiro-dsl` library does not change, so `just dsl-api-boundaries` should stay green without edits. No package dependency is expected; argument handling uses base. Consult Mori before introducing any dependency API and verify registry versions if a dependency change becomes necessary.

## Friction triage and excluded work


All source reports below belong to the canonical consumer bundle `mori://tan/agent-reputation-service/okf/friction-log`. The assessment is source-based; this planning session did not execute application database tests.

`mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-2`: reject the correctness-bug interpretation because the default scope is documented; retain only the explicit full-service witness integration improvement in this plan.

`mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-3`: reject as a Keiro bug. The application's projection holes explicitly call `Tx.condemn` on decode failure, then return unit. `applyAsyncProjectionUnfenced` runs that callback and returns `AsyncApplied`; it is a transaction computation, not a commit receipt. `keiro/test/Main.hs`, test “rolls back the append when inline SQL condemns the transaction”, already asserts that a condemned transaction returns its ordinary value while persisting no events. The caller must represent failure explicitly and refuse acknowledgement, as the application's worker now does. Ordinary SQL/driver failure is a distinct error path. Do not add a mechanism that promises to infer commit from an arbitrary callback's return value. The hazard is the one open [IR-10](../improvement-requests/support-atomic-async-projection-apply-and-checkpoint-advancement.md) describes from the other side: apply and checkpoint advancement are separate commits. [Plan 271](271-apply-async-projections-and-advance-checkpoints-atomically.md) still has "establish a concrete consumer requirement" unchecked, and FRIC-3 is a candidate for that evidence. That belongs to plan 271, not here.

`mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-4` and `mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-10`: reject as missing-constructor bugs or required minting support. The inspected consumer generated module exports both mkInvitationId and mkEndorsementId; their internal definitions alias the text parsers. Admission and minting are different operations. [ADR-46](../adr/0046-nominal-declarations-are-structural-leaves-with-keiro-owned-admission.md) explicitly leaves generation policy application-owned. No automatic ID generation belongs in this plan.

`mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-6` and `mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-11`: reject private-module placement as a bug; it implements ADR-20. This plan supplies the missing optional full-report path through the intended public facade instead of broadening exposure.

`mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-7`: reject failure to overwrite or extend a hand-owned hole module as a generator bug. `scaffoldProjectionCatalog` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` emits ProjectionCatalogHoles as HoleStub; create-once preservation is deliberate. Adding adapters after adding owners is application work. Automatic source merging is outside scope.

`mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-8`: reject missing-checkpoint refusal as a runtime bug. `beginGroupRebuild` in `keiro/src/Keiro/ReadModel/Rebuild/Group.hs` condemns the whole preparation transaction on missing subscriptions. [ADR-31](../adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md) forbids inventing runtime member topology. `docs/guides/offline-projection-rebuilds.md` already requires checkpoint initialization before rebuilding. Adding a writer requires updating test and operational setup.

`mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-9`: reject as a Keiro documentation defect. `docs/guides/guarded-catalog-commands.md` explicitly gives tentative append, fences, precondition, inline delivery, commit ordering, and excludes pure no-op/rejection decisions from the precondition. The log targets a separate patterns repository; whether that guide needs a cross-link remains unverified and is not a Keiro runtime defect. Do not claim this review disproves an omission in the external guide.

`mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-1` and `mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-5` concern Cabal and Servant respectively, are already accepted in the source log, and are outside this Keiro review.

The subsequently added `mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-12` concerns ephemeral-pg connection limits, not Keiro, and remains outside this review. `mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-13` concerns hurl-workbench and is already promoted to that project.

## Revision notes


2026-11-18: Plan review against the working tree at `43c9cdcb`. Replaced the label design that embedded `renderBehaviorConformanceText`, which prints counts but not keys, with per-key rows from a new contract export. Named the predicate that selects behavior-bearing aggregates. Replaced the proposed new fixture with the committed service-package workspace, which already holds the motivating case, and recorded its exact commands. Added the record-migration inventory regeneration, `just verify`, the changelog entry, and a per-guarantee acceptance paragraph. Checked every open improvement request and found none to absorb; linked FRIC-3 to IR-10 and plan 271 as evidence only.
