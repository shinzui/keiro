---
id: 337
slug: gate-all-behavior-witnesses-through-generated-service-conformance
title: "Gate all behavior witnesses through generated service conformance"
kind: exec-plan
created_at: 2026-11-17T04:40:56Z
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-17T04:40:56Z
---

# Gate all behavior witnesses through generated service conformance

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Distill durable decisions into the relevant ADRs at implementation completion.

## Purpose / Big Picture


Provide an explicit `--behavior-complete` mode in the generated conformance test executable. Applications that deliberately require every declared behavior witness can then enforce that policy without writing a second runner or exposing private aggregate modules. A witness is a concrete history, command or event sequence, and expected result supplied by the application; it provides finite evidence, not a universal proof.

This is an optional integration improvement, not a fix for incorrect default conformance behavior. The current default deliberately exercises hole-owned initial live edges, as documented. Preserve that default. Rejecting missing, pending, duplicate, stale, or false evidence across the entire inventory must be an explicit application choice.

## Progress


- [ ] Expose full behavior checks through the existing generated service facade, with execution tests for all report failure classes.
- [ ] Add and exercise the generated runner's explicit full-witness mode across the runtime-package boundary.
- [ ] Regenerate affected corpus fixtures and document the policy, with existing default behavior preserved.

Planning and source validation are complete; implementation and runtime reproduction have not been performed.

## Surprises & Discoveries


The originating report describes a green default conformance run as a bug, but `docs/user/keiro-dsl-workspaces-and-generated-code.md` explicitly limits that runner to hole-owned live initial edges. The full `behaviorCoverageReport` already exists. The missing capability is generated service-level integration of that report.

## Decision Log


2026-11-17: Preserve default conformance semantics and add an explicit policy flag. The user specifically excludes changes motivated by misuse. Treat the expectation that default conformance proves all witnesses as incorrect usage, while addressing only the independently demonstrable integration gap.

2026-11-17: Keep aggregate `BehaviorHoles` and `Generated.BehaviorContract` private. ADR-20 intentionally exposes one service facade. Neither changing the Cabal fragment to expose every aggregate nor automatically editing consumer holes is required.

2026-11-17: Do not require opaque evidence to become universally verified. Use `behaviorConformancePassed`, whose existing policy rejects incomplete or false finite evidence but permits honestly unverified predicates. A new stricter unverified-evidence policy is outside this plan.

## Outcomes & Retrospective


Not implemented. Record executable acceptance evidence and any remaining limitations here when implementation completes.

## Context and Orientation


The source review compared Keiro commit `fd869833fc369ee6bcdbf9fbf9f3f9ef10c85272` with consumer `mori://tan/agent-reputation-service` at commit `4e58fd0221fa2a739192668d77317354b8abf978`. Consumer generated files identify keiro-dsl 0.25.1.0. No dependency bounds or versions are proposed. Mori registry discovery failed because its local PostgreSQL connection was refused; canonical source identities were verified from the consumer's `mori.dhall` and friction frontmatter, but URI resolution was unavailable.

The originating evidence is `mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-2`. Related visibility reports are `mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-6` and `mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-11`. Their attempted manual full-report gate explains the repaste cost, but private modules are intentional.

`keiro-dsl/src/Keiro/Dsl/Harness.hs` emits aggregate `harnessAssertions`. Its `initialWitnessProbeEntries` filters live transitions from the initial vertex to those with Hole implementation. It imports witness contracts only when that subset is nonempty. `keiro-dsl/src/Keiro/Dsl/ServiceHarness.hs` collects those assertions through `checkExpression`; it does not execute all behavior requirements. `keiro-dsl/src/Keiro/Dsl/ConformancePackage.hs` emits the runnable package and its Main, importing only `runServiceConformanceChecks` and `serviceConformanceFacts`. `keiro-dsl/src/Keiro/Dsl/Manifest.hs` exposes only the service facade and keeps other modules private.

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, in `emitBehaviorContract`, already emits `behaviorCoverageReport`, `behaviorConformancePassed`, and `renderBehaviorConformanceText`. Reuse those functions. `keiro-dsl/test/conformance-behavior-complete/Main.hs` is an existing hand-written full-report runner, demonstrating the machinery independently of generated service integration. `keiro-dsl/test/Main.hs` owns generator tests. `keiro-dsl/test/fixtures/behavior-complete.keiro` and its committed `keiro-dsl/test/conformance-behavior-complete/` output provide the behavior cases.

[ADR-17](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md) separates generated behavior from consumer-owned holes and defines finite witness evidence. [ADR-20](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md) requires one runtime-owned facade rather than exposing every internal module. Preserve both boundaries. Update ADR-20 when the optional mode ships.

## Plan of Work


Milestone 1 adds `runServiceBehaviorChecks :: IO [(String, Bool)]` to the generated service facade. For each aggregate with a behavior contract, import that contract and its create-once witness module under deterministic qualified aliases. Compute `behaviorCoverageReport behaviorWitnesses` once, use `behaviorConformancePassed` for the result, and include the aggregate name and `renderBehaviorConformanceText` output in the result label. This returns simple base types across the package boundary and keeps all aggregate-specific types private. Return an empty list for services without behavior-bearing aggregates. Do not put full-report calls into the existing `harnessAssertions` or default runner, which would change established semantics. Verify the new facade against a compiled fixture with no hole-owned initial transition and a pending non-initial witness: normal checks remain green, but the new function contains a false result.

Milestone 2 changes generated Main in `ConformancePackage.hs` to recognize `--behavior-complete` and `--help` with explicit usage and a nonzero exit for unknown options. Always run the existing checks and fact comparison. Only when the full mode is selected, evaluate and print the additional behavior results; any false result fails the executable. The help and documentation must state that default checks are not a complete witness gate. Verify a generated runtime library and separate generated conformance package using the fragment unchanged. The test must import only the facade. Pending evidence must cause the actual test process to exit nonzero and identify its aggregate and behavior key; filling that witness must make it exit zero. This package-boundary proof is required before expanding test variants.

Milestone 3 extends the compiled fixture matrix to missing, duplicate, stale, incorrect live/rejection/replay evidence, and valid history-dependent witnesses. Add a generated-owned initial edge with non-initial obligations so the motivating case cannot accidentally become an initial-Hole test. Include a workspace with two aggregate owners to detect omissions or duplicate checking. Keep unverified-but-otherwise-valid evidence passing under the established report policy. Regenerate affected output through the corpus tool, preserving hand-owned witness files. Update `docs/user/keiro-dsl-workspaces-and-generated-code.md` with explicit default versus full-mode commands and migration instructions. Consumers may remove manual exposure only after switching their CI gate and confirming they have no other direct imports.

## Concrete Steps


Run from the Keiro repository root. All build and repository checks use its Nix shell. First establish the solver and existing report baseline:

```bash
nix develop -c z3 --version
nix develop -c cabal test keiro-dsl:keiro-dsl-conformance-behavior-complete --test-show-details=direct
```

Implement the facade and runner in the files above and add regression cases to `keiro-dsl/test/Main.hs`, plus a generated-package integration fixture beside the existing conformance fixtures. Register any new test component in `keiro-dsl/keiro-dsl.cabal` and the corpus inventory used by the regeneration tool. Use the existing generated-package test helpers in `keiro-dsl/test/Main.hs` rather than depending on the external consumer checkout.

```bash
nix develop -c just corpus-regen
nix develop -c cabal test keiro-dsl:tests --test-show-details=direct
nix develop -c cabal test keiro-dsl:keiro-dsl-conformance-behavior-complete --test-show-details=direct
nix develop -c just conformance-corpus-policy
nix develop -c git diff --check
```

The generated consumer command, from a consumer's development shell, will be:

```bash
cabal test keiro-agent-reputation-service-conformance:conformance --test-options=--behavior-complete --test-show-details=direct
```

This consumer command describes the intended interface; do not run it against an unregenerated released runner and mistake its behavior for implementation acceptance. In the repository integration fixture, run the equivalent command for the generated fixture package and assert its process exit status. Record that exact fixture command here once the fixture is registered.

## Validation and Acceptance


A service with valid initial checks and Pending non-initial evidence passes the unchanged default but fails `--behavior-complete`. Replacing Pending with a correct history-backed witness makes full mode pass. Missing, duplicate, stale, and behaviorally incorrect evidence each fail with the relevant aggregate and key. Include replay-only and rejection obligations, not just live commands. False ordinary checks or changed expectation facts still fail even when full behavior evidence passes.

A runtime library assembled from the generated fragment compiles with BehaviorHoles and BehaviorContract under `other-modules`; the separate generated test package executes full checks using only the exposed facade. Re-scaffolding requires no manual exposure edits and preserves hand-owned witnesses byte-for-byte. No-aggregate services pass both modes, and multi-aggregate workspaces report each owner exactly once. Help describes policy accurately and unknown flags fail visibly.

Generator string assertions alone are insufficient: retain an actual generated-package compile and process-exit test. Do not call the plan complete based solely on the existing hand-written full-report runner passing. Record tests actually run separately from proposed commands.

## Idempotence and Recovery


Regeneration may overwrite generated files but must preserve create-once expectations and witnesses. Save the current diff before corpus regeneration; if it changes unrelated output, inspect and restore only task-owned changes. No database migration, dependency upgrade, consumer rewrite, or release is part of this plan. A consumer can stop requesting full mode without changing persisted data. Do not delete hand-owned holes to obtain regenerated defaults.

## Interfaces and Dependencies


Add only the generated facade export `runServiceBehaviorChecks :: IO [(String, Bool)]` and generated runner flag `--behavior-complete` (plus help and argument validation). Retain existing default facade signatures and report schema. Use the existing generated behavior contract, no new witness evaluator. No package dependency is expected; argument handling uses base. Consult Mori before introducing any dependency API and verify registry versions if a dependency change becomes necessary.

## Friction triage and excluded work


All source reports below belong to the canonical consumer bundle `mori://tan/agent-reputation-service/okf/friction-log`. The assessment is source-based; this planning session did not execute application database tests.

`mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-2`: reject the correctness-bug interpretation because the default scope is documented; retain only the explicit full-service witness integration improvement in this plan.

`mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-3`: reject as a Keiro bug. The application's projection holes explicitly call `Tx.condemn` on decode failure, then return unit. `applyAsyncProjectionUnfenced` runs that callback and returns `AsyncApplied`; it is a transaction computation, not a commit receipt. `keiro/test/Main.hs`, test “rolls back the append when inline SQL condemns the transaction”, already asserts that a condemned transaction returns its ordinary value while persisting no events. The caller must represent failure explicitly and refuse acknowledgement, as the application's worker now does. Ordinary SQL/driver failure is a distinct error path. Do not add a mechanism that promises to infer commit from an arbitrary callback's return value.

`mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-4` and `mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-10`: reject as missing-constructor bugs or required minting support. The inspected consumer generated module exports both mkInvitationId and mkEndorsementId; their internal definitions alias the text parsers. Admission and minting are different operations. [ADR-46](../adr/0046-nominal-declarations-are-structural-leaves-with-keiro-owned-admission.md) explicitly leaves generation policy application-owned. No automatic ID generation belongs in this plan.

`mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-6` and `mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-11`: reject private-module placement as a bug; it implements ADR-20. This plan supplies the missing optional full-report path through the intended public facade instead of broadening exposure.

`mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-7`: reject failure to overwrite or extend a hand-owned hole module as a generator bug. `scaffoldProjectionCatalog` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` emits ProjectionCatalogHoles as HoleStub; create-once preservation is deliberate. Adding adapters after adding owners is application work. Automatic source merging is outside scope.

`mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-8`: reject missing-checkpoint refusal as a runtime bug. `beginGroupRebuild` in `keiro/src/Keiro/ReadModel/Rebuild/Group.hs` condemns the whole preparation transaction on missing subscriptions. [ADR-31](../adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md) forbids inventing runtime member topology. `docs/guides/offline-projection-rebuilds.md` already requires checkpoint initialization before rebuilding. Adding a writer requires updating test and operational setup.

`mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-9`: reject as a Keiro documentation defect. `docs/guides/guarded-catalog-commands.md` explicitly gives tentative append, fences, precondition, inline delivery, commit ordering, and excludes pure no-op/rejection decisions from the precondition. The log targets a separate patterns repository; whether that guide needs a cross-link remains unverified and is not a Keiro runtime defect. Do not claim this review disproves an omission in the external guide.

`mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-1` and `mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-5` concern Cabal and Servant respectively, are already accepted in the source log, and are outside this Keiro review.

The subsequently added `mori://tan/agent-reputation-service/okf/friction-log/concepts/FRIC-12` concerns ephemeral-pg connection limits, not Keiro, and remains outside this review.
