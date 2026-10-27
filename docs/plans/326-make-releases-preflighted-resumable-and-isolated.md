---
id: 326
slug: make-releases-preflighted-resumable-and-isolated
title: "Make releases preflighted resumable and isolated"
kind: exec-plan
created_at: 2026-10-27T18:50:10Z
intention: "intention_01m5zayr6cegk9sannrhjy6h1k"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-27T18:50:10Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-27T18:52:30Z
      mode: "implement"
      note: "Implement the five approved release workflow improvements with staged evidence and isolated consumer checks"
---

# Make releases preflighted resumable and isolated

## Purpose / Big Picture

A maintainer can prepare one final version, discover missing infrastructure and stale generated inventories before long tests, and retry a failed release stage without repeating matching successful checks. Publication consumes prebuilt archives; a clean HTTPS consumer proves the staged archives before upload and the published packages afterward. No command in this work publishes or tags a new release.

## Progress

- [x] (2026-10-27) Preparation regenerated the 0.22 corpus and inventories with no drift; live preflight passed terminology connectivity, upgrade-chain publication, eight package checks and 216 released external dependencies before the long gate.
- [x] (2026-10-27) Locked/fail-fast stages passed 27 controls, full correctness and all six guards through the accepted 20:48 manifest. The resumed run reused six stages and reran inbox in 184.432 seconds, versus 1621.761 seconds for the full refused attempt; ceilings and baselines are unchanged.
- [x] (2026-10-27) All sixteen archives and exact-version staged/published consumers pass; both health responses have no schema drift. Readiness passes for the accepted evidence and archive checksums. A separate Nix-shell gate reused all seven stages in 67.552 seconds. The release skill and ADR-58 describe the implemented policy.

## Surprises & Discoveries

The existing release recipe unconditionally starts benchmarks after correctness failure. The skill additionally reruns suites after the full gate. The 0.22 release spent 92 minutes across four gate attempts, compared with 24 minutes for the final passing attempt; sixteen uploads took about twelve seconds. These measurements motivate orchestration changes, not weaker numerical thresholds. A live preflight also exposed a supposedly static name-policy recipe compiling a test suite; preflight now runs its path/declaration scan only, while full verification retains the original runtime assertions. Separate Nix shell entries change NIX_BUILD_TOP even with the same toolchain; only that scratch location and the logging descriptor are excluded from the relevant-environment fingerprint.

Two resume attempts encountered truncated Hackage metadata (`IncompleteRead`) before
any expensive work resumed. Metadata reads now re-fetch complete responses with bounded
per-dependency retries; missing/unpreferred releases still refuse immediately. A full
82ad8439 attempt passed correctness and five guards but refused two command no-op cases
at roughly 25–26 percent over baseline. Those failures remain diagnostic evidence;
baselines and thresholds have not moved. The revised helper recovered a real truncated pgmq-config response during a successful 216-dependency preflight. A focused command guard passed all 15 cases (54.23 seconds); both no-op cases were about 14 percent above baseline. The final 522fd54c candidate passed full correctness and five guards, refused three inbox fresh cases, then passed inbox on a matching-input resumed run. Those cases returned to 385–397 ms without source or baseline changes. The accepted manifest references all original stage records explicitly.

## Decision Log

On 2026-10-27 the user authorized all five retrospective recommendations: early preflight, a single prepared candidate and serialized build writers, fail-fast correctness, explicit resumability, and an isolated HTTPS consumer. The active intention is inherited from the approved session capture. Upstream blueprint publication means its complete local payload matches the remote default branch, rather than merely appearing on some remote feature branch; a real Git control demonstrates that distinction.

Successful stages may be reused only for a clean candidate with identical tested inputs, resolved dependency plan, toolchain and selected environment, within 24 hours. Retained evidence files and Markdown ExecPlan and MasterPlan documents are excluded from source identity; source, package versions, flags, recipes, baselines and all other tracked changes invalidate it. Preflight always reruns. A failed or interrupted latest attempt cannot be replaced with an older pass. Original logs remain separate and a manifest references them; logs are never spliced into a fictional uninterrupted run. A fresh option bypasses reuse.

## Outcomes & Retrospective

All five improvements are implemented and accepted at source commit `522fd54c`.
The [retained summary](../../keiro/bench/results/release-gates/workflow-326/summary.json)
links the full refused attempt, accepted resumed run and fully cached run. The full
attempt took 1621.761 seconds; its three inbox failures remained red. A matching-input
retry reused six stages and reran inbox in 184.432 seconds, accepting all seven stages.
A separate Nix-shell invocation reused every stage in 67.552 seconds, including mandatory
preflight. This demonstrates a retry saving of almost 24 minutes without changing a
baseline, ceiling, test assertion or benchmark workload.

All 27 focused controls, native Nix checks, strict ADR validation, sixteen archive
checksums, both isolated consumer builds and HTTP health proofs, and the final
`release-ready` check pass. The PGMQ suite retains its two previously optional pending
checks. The existing 0.22.0.0 cohort was the workflow fixture; no new tags or uploads
were performed. There is no remaining required work in this plan.

Review caught an exclusion tied to this plan number, prompting one intentional development
gate interruption. Markdown ExecPlan/MasterPlan documents now share that execution-note
rule, while source files in those directories and ADR/guide policy remain inputs.
Interrupted records cannot authorize reuse and a manifest is written before work starts.
Live Hackage response truncations prompted bounded per-dependency re-fetching; partial
JSON is never accepted. Both findings and rejected benchmark runs remain in the evidence.
[ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md)
holds the durable input, receipt, isolation and publication rules; implementation detail
and measured acceptance remain here and in the evidence bundle.

## Context and Orientation

The repository's `justfile` owns `verify`, `corpus-regen`, `bench-regression` and `release-gate`. `scripts/bench-regression.sh` runs six guards and reports every failure; this continuation within the benchmark stage remains intentional. The release skill is `agents/skills/release/SKILL.md`. `scripts/generate-record-migration-manifests.py` refreshes two checked inventories, and the corpus regeneration tool refuses dirty output paths, so preparation must check them before invoking Cabal. All verification runs in `nix develop`.

[ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md) requires unchanged benchmark workloads, ceilings and attributed baseline changes, and previously required a single uninterrupted combined log. This work deliberately replaces only that orchestration restriction with explicit stage receipts: a small JSON record of inputs, command, exit status, log checksum and completion time. The six guard definitions remain unchanged. Follow `agents/skills/exec-plan/ADR.md` to update the existing ADR and its reserved log; no new ADR handle is needed.

Cabal configuration and project target behavior were checked against the local corpus at `mori://haskell/cabal`. Seihou blueprint evaluation and lookup were checked against `mori://shinzui/seihou`. These are consulted projects; artifact-level references for their source files are pending.

## Plan of Work

First add a standard-library Python release driver and early metadata recipes. Preparation formats and regenerates the final version without running a full old-version build. Preflight checks Nix tools, the Mori terminology connection, documentation and inventory policies, package checks, blueprint validity and dependency solving before correctness.

Next add a shared workspace lock, stage logging, input identities, receipt checks and manifests. `just verify`, corpus regeneration and release preparation/documentation participate in the same lock. Gate execution stops immediately after failed preflight or correctness; once correctness passes, all six benchmark guards are attempted and individually resumable. Preserve the existing guard script rather than reproducing its thresholds. Test refusal, interrupted receipts, changed inputs, log tampering, freshness and lock contention using disposable repositories and harmless commands.

Finally stage all eight source/documentation archives before uploads. Add a self-contained consumer fixture that depends on every released package at the exact version. Its explicit secure HTTPS config and separate package cache avoid global mirror and index mutations. Stage mode consumes the exact source archives; published mode accepts only Hackage sources and waits a bounded number of times for newly published versions to enter the index. Both run a disposable migrated database and check the HTTP health response. Update the release skill to prescribe these commands and remove redundant builds and test reruns.

## Concrete Steps

From the repository root, implement `scripts/release_workflow.py`, `scripts/release_consumer.py`, `scripts/release-consumer/Main.hs`, and `scripts/tests/test_release_workflow.py`; expose the commands in `justfile`. Run focused verification in the Nix shell:

```bash
nix develop -c python3 -m unittest discover -s scripts/tests -p 'test_release*.py'
nix develop -c just release-prepare
# Review and commit the prepared candidate before the gate.
nix develop -c just release-preflight
nix develop -c just release-gate
nix flake check
nix develop -c just release-artifacts
nix develop -c just release-consumer staged
nix develop -c just release-ready keiro/bench/results/release-gates/<run>-manifest.json
# Published mode verifies the existing Hackage release; it never uploads.
nix develop -c just release-consumer published
```

Stage and commit the implementation before a real gate because the corpus check requires committed generated inputs. Use a Conventional Commit with both the ExecPlan and Intention trailers. Keep the release version at 0.22.0.0; this is workflow work, not another release.

## Validation and Acceptance

Focused controls must prove that failed correctness invokes no guard, a guard-only retry reuses matching correctness and passing guards, and any tested-source/resolved-dependency-plan/toolchain/environment/baseline change invalidates reuse. Missing or changed logs, stale receipts, interrupted stages and the most recent failed attempt must not authorize acceptance. A concurrent workflow command must refuse while a writer holds the lock. Generated-file and connectivity checks must execute before expensive tests.

A real preflight and gate exercise the live command wiring. Staged and published consumer modes must solve, build and serve `/keiro/health` as `{"status":"ok","schema_drift":[],"mutations_enabled":false}` with disposable database cleanup. Tests must establish bounded index retries and refusal of unexpected sources/versions. Neither consumer nor artifacts command uploads anything. Preserve all six benchmark workloads, baselines and thresholds. Native Nix checks and strict ADR validation must pass.

## Idempotence and Recovery

All writes are local and reversible. Preparation never commits automatically. Interrupted stage records are ineligible for reuse; rerun the same command. Use `just release-gate --fresh` to require new evidence. Keep stage logs and JSON manifests together when committing release evidence. Isolated consumers keep their own HTTPS cache and build directories, never rewrite the user's Cabal config/cache, and remove only their freshly created scratch database. Release publication remains an explicitly authorized skill step.

## Interfaces and Dependencies

Use Python's standard library (Python 3 is explicitly included in `flake.module.nix`), existing Cabal/GHC/Nix/PostgreSQL/Z3 tooling, Mori, Seihou and OKF. No new application dependency or package API is introduced. The release driver owns identity and receipts; the existing `scripts/bench-regression.sh` owns guard selection and thresholds. JSON receipts are versioned and rejected when their schema or required fields differ. The consumer uses the existing public HTTP application fixture from the completed 0.22 release proof.
