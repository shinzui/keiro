---
id: 169
slug: thread-the-effective-keiro-language-contract-through-semantic-planning
title: "Thread the effective Keiro language contract through semantic planning"
kind: exec-plan
created_at: 2026-08-01T00:15:25Z
intention: "intention_01kyxarnbbet3ajn0995gt65w9"
master_plan: "docs/masterplans/27-repair-the-keiro-dsl-0-6-language-nominal-generation-and-workspace-regressions.md"
---

# Thread the effective Keiro language contract through semantic planning

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, semantic checking and generation know which effective Keiro language contract
they are implementing. Version-specific behavior can no longer disappear after parser dispatch
because downstream APIs receive a checked service value containing the normalized `Spec` and its
effective language version. Per-member declared-versus-legacy provenance remains separately
attributable.

The behavior is visible with paired version-2 and successor-version fixtures containing the same
semantic declaration: the parser can normalize both to similar graph nodes, while validation,
scaffolding, fingerprints, and compatibility reports deliberately choose the correct versioned
runtime contract. This is the prerequisite for Plan 171's safe ID-prefix enforcement.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: define the semantic-contract wrapper and invariants for single sources and
  same-version workspaces.
- [ ] Milestone 2: route check, scaffold, harness, fingerprint, replay-impact, and diff planning
  through the wrapper without contaminating `Spec` with source provenance.
- [ ] Milestone 3: add paired-version and workspace parity tests, compatibility serialization, and
  refusal-before-write evidence.
- [ ] Milestone 4: amend ADR 16, update public API/documentation, and run repository validation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-08-01: `parseSource` retains `SourceLanguage`, and workspace members reject mixed effective
  versions, but `wsMergedSpec`, `validateSpec`, `scaffoldAggregate`, fingerprints, and replay-impact
  functions receive only `Spec`. `executeScaffoldWithLanguage` explicitly documents that semantic
  planning still receives only `Spec`; source language is written to history after modules have
  already been planned. A new version can therefore select a different grammar but cannot select a
  different runtime semantic honestly.


## Decision Log

Record every decision made while working on the plan.

- Decision: Introduce a checked service-level semantic contract containing one effective language
  version plus the normalized `Spec`; do not add declared provenance to `Spec`.
  Rationale: a workspace already guarantees one effective version but may combine legacy and
  explicitly declared member provenance. Semantic consumers need the shared effective contract,
  while diagnostics and history still need each member's original declaration state.
  Date: 2026-08-01

- Decision: Make the versioned wrapper the normal input to semantic entry points and keep old
  `Spec`-only functions as explicitly legacy/internal compatibility wrappers during migration.
  Rationale: an optional parameter or ambient lookup would let new code accidentally repeat the
  0.6 bug. Type-directed routing makes version loss visible at compile time.
  Date: 2026-08-01

- Decision: Amend ADR 16 rather than replace it.
  Rationale: its separation of per-source provenance from the merged graph remains correct; only
  its stronger claim that all semantic consumers need solely `Spec` proved incomplete once a
  language version changes runtime semantics.
  Date: 2026-08-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(Implementation not started.)


## Context and Orientation

This plan is architectural support for
[IR-14](../improvement-requests/make-id-prefix-declarations-enforceable-and-evolution-safe.md).
`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` defines declared and effective versions.
`keiro-dsl/src/Keiro/Dsl/Parser.hs` returns `ParsedSource`, which contains `SourceLanguage` and
`Spec`. `keiro-dsl/src/Keiro/Dsl/Workspace.hs` retains member languages, refuses different
effective versions, and exposes a merged `Spec` without the common version.

`keiro-dsl/src/Keiro/Dsl/Validate.hs`, `Scaffold.hs`, `FoldFingerprint.hs`, `ReplayImpact.hs`, and
`Diff.hs` consume semantic graphs. `ScaffoldRun.hs` and `WorkspaceScaffold.hs` bridge planning to
filesystem writes and records. Inventory every public and internal `Spec ->` entry point before
editing so the migration does not leave a silent unversioned path.

[ADR 16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) is the main
decision to amend. [ADR 14](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
requires a workspace to compose one semantic service; its mixed-version refusal justifies one
effective contract on that service. [ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
requires the selected contract to reach the earliest semantic boundary that can enforce it.


## Plan of Work

Milestone 1 adds a module such as `Keiro.Dsl.SemanticContract`. Define `EffectiveLanguageContract`
from the supported-version registry and `CheckedService` from that contract, `Spec`, and optional
source ownership/provenance indexes. Construction from one `ParsedSource` is total after parsing;
construction from a `WorkspaceSpec` succeeds only after its existing equal-effective-version
check. Keep declared member provenance outside the semantic contract value or in a separate
attribution field that semantic fingerprints cannot accidentally serialize.

Milestone 2 migrates semantic consumers. Add contract-aware validation, lowering, scaffold,
harness, fingerprint, replay-impact, diff, and report entry points. Where version-independent logic
is reusable, pass only the normalized graph internally after a version-aware planner selects the
policy. Mark compatibility `Spec` wrappers as legacy-version semantics and keep them out of CLI and
workspace routes. Change `ScaffoldRun` so source language reaches module planning before any write,
not merely the history record.

Milestone 3 proves the boundary. Add paired parsed sources with equivalent declarations under two
effective contracts and a test-only semantic policy whose output differs, demonstrating that every
route preserves the version. Add one-member and multi-member workspace parity, mixed-version
refusal, diff-from-revision, record round trips, and refusal-before-write tests. Fingerprints must
include a semantic contract discriminator only when runtime/fold behavior can differ; a purely
declared legacy-to-v1 provenance rewrite remains compatible as ADR 16 requires.

Milestone 4 updates exports, Haddocks, authoring documentation, and migration guidance. Amend ADR
16 and its log to distinguish source provenance from effective semantic contract. Update ADR 4's
boundary inventory if necessary. Run strict ADR validation and the complete test/build suite.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
rg -n ":: .*Spec|Spec ->|-> Spec" keiro-dsl/src
cabal test keiro-dsl-test --test-option=--match --test-option='source language'
cabal test keiro-dsl-test --test-option=--match --test-option='workspace source language'
cabal test keiro-dsl-test
cabal build all
nix flake check
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

The initial `rg` output is an implementation inventory, not a mechanical rewrite list. At
completion, all CLI/workspace semantic routes construct `CheckedService`; focused and full tests
exit zero.


## Validation and Acceptance

Acceptance requires every command that parses a source or workspace and then validates, scaffolds,
diffs, fingerprints, or analyzes replay to preserve the effective contract. A mixed-version
workspace still fails before merge or write. Legacy-unversioned and declared v1 remain provenance-
distinct but semantically compatible. A test-only successor semantic produces different planned
behavior through every route, proving the contract was not dropped.


## Idempotence and Recovery

The migration is additive until all callers use the wrapper. Keep old `Spec` functions temporarily
and make their legacy semantics explicit; remove or hide them only after `rg` and compiler errors
show no production route depends on them. Filesystem tests use temporary directories and existing
preflight checks, so a failed version construction changes nothing.


## Interfaces and Dependencies

The central interface should be equivalent to:

```haskell
data CheckedService = CheckedService
  { checkedLanguageContract :: EffectiveLanguageContract
  , checkedSpec :: Spec
  }

checkedSource :: ParsedSource -> CheckedService
checkedWorkspace :: WorkspaceSpec -> Either (NonEmpty WorkspaceDiagnostic) CheckedService

validateService :: CheckedService -> [Diagnostic]
scaffoldService :: Context -> CheckedService -> [ScaffoldModule]
```

Exact names may follow repository conventions. Plan 171 consumes this interface and owns the first
real successor runtime semantic. Plan 167 changes parser mechanics but must preserve the
`ParsedSource` input to this contract.
