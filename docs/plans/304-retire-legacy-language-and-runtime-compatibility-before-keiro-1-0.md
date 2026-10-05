---
id: 304
slug: retire-legacy-language-and-runtime-compatibility-before-keiro-1-0
title: "Retire legacy language and runtime compatibility before Keiro 1.0"
kind: exec-plan
created_at: 2026-10-05T17:20:06Z
intention: "intention_01m46h492de0srrr02wm5y0ybv"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-05T17:20:06Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-05T17:29:20Z
      mode: "other"
      note: "Draft the seven-milestone pre-1.0 language and runtime retirement plan and verify repository paths and commands"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-05T17:41:43Z
      mode: "update"
      note: "End retired data support and historical coverage; migrate retained functionality tests to Language 6 and prepare migration requests for every consumer"
---


# Retire legacy language and runtime compatibility before Keiro 1.0

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Use the period before `1.0.0.0` to reduce Keiro's maintenance cost across the DSL toolchain, runtime, compilation, and tests. After Language 6 is finalized, the next release will deprecate Languages 1–5, unversioned source, obsolete public APIs, and retired data contracts. A distinct later breaking release, still before `1.0.0.0`, will accept only Language 6 for DSL authoring and generation and end support for retired data contracts. It will delete their implementation paths, historical fixtures, comparison programs, and recurring release checks.

Every old test of functionality that remains supported must be migrated to Language 6 before the old test is removed. At completion there is one positive DSL coverage baseline: Language 6. Runtime tests without DSL input remain current-runtime tests. Small negative tests prove that retired source and identifiable unsupported data are refused; they do not retain old positive compatibility coverage. Current-contract replay, crash recovery, idempotence, and workflow continuation remain tested because current services need those functions.

Every known consumer will be asked to migrate to Language 6 soon, during the preparation/deprecation period. Consumer readiness includes both source/API migration and a decision about existing data and in-flight work. An updated language declaration alone does not migrate stored data. Release R requires a fresh supported environment or an explicit application-owned migration/rebuild into its current data contract; it does not promise a seamless upgrade for old histories. Producing the migration requests and readiness inventory is in scope; sending notices, changing consumer checkouts, deployment, and data deletion are separate actions.

This document plans the change. No implementation, package publication, deployment, or production data operation has happened. Package mergers and general build-system replacement are outside this plan. The separately authored Plan 305 concerns build reuse; this plan reduces the obsolete work those builds would otherwise perform.


## Progress


- [ ] M1: Inventory exact compatibility implementations, data contracts, test functions, consumers, and baseline compile/test costs.
- [ ] M2: Finalize Language 6, specify the supported data baseline, prepare deprecation release D and requests for every known consumer to migrate soon.
- [ ] M3: Migrate every retained function's old test to Language 6 and consolidate redundant generated corpora; record consumer readiness.
- [ ] Release boundary: record D publication and its source/data cutoff guidance before removal.
- [ ] M4: Remove Languages 1–5 and unversioned execution, old Spec-only entry points, and exclusive legacy generator branches.
- [ ] M5: Consolidate public runtime APIs, removing their obsolete implementations.
- [ ] M6: End retired data support; delete historical readers, coverage, comparison harnesses, and recurring old-release gates while retaining current-contract replay/recovery coverage.
- [ ] M7: Verify current-only coverage and actual compile/test work reduction, prepare release R, and distill the final policy into ADRs.


## Surprises & Discoveries


Discovery (2026-10-05): The current `keiro-dsl/test/conformance-baseline.json` has 51 compiled corpus entries: 26 Language 4 compatibility, eight Language 5 stable, 13 Language 6 candidate, and four without a primary language. `keiro-dsl/keiro-dsl.cabal` declares 55 test suites. Migrating 26 suites by changing their preambles alone would preserve their build cost. Savings require deleting obsolete-only suites, consolidating duplicate generated modules, and removing historical comparison builds. Record measured savings during implementation; these counts are not a speedup estimate.


## Decision Log


Decision (2026-10-05): Expand the user's initial DSL retirement request to old compatibility paths across the toolchain and runtime. The user identified this as the opportunity for breaking changes before `1.0.0.0`. Source/API compatibility may end at an announced breaking release; retained-data correctness remains a separate obligation.

Decision (2026-10-05): Use two release boundaries. The deprecation release, called D below, follows Language 6 finalization and still executes old supported source contracts. The removal release, called R, is a distinct later breaking release below `1.0.0.0`. Do not combine warnings and removal into the same published release. Select actual package versions during implementation using the then-current shared release convention, registry, and upstream tags; this plan does not invent version numbers or a calendar deadline.

Decision (2026-10-05): Retire all older source languages, including Language 5 and missing declarations. Missing declarations must never silently start meaning Language 6. Recognizing a historical language number in a ledger or migration diagnostic does not mean accepting its source for execution.

Decision (2026-10-05): Remove redundant public construction and execution paths, beginning with the concrete read-model compatibility implementation, rather than merely hiding deprecated exports around unchanged duplication. Preserve useful hand-written service capabilities through the current APIs. A name containing `legacy`, `v1`, or `compatibility` is a discovery signal, not deletion evidence.

Decision (2026-10-05): Reuse the existing layered replay evidence and corpus machinery. A registry with no known users is not proof of no durable use. Historical readers may remain narrowly internal with explicit evidence requirements; they must not keep obsolete authoring and generation support alive indefinitely.

The earlier historical-reader retention defaults above are superseded by the following explicit user decisions; they describe the original plan, not the final R requirements.

Decision (2026-10-05, supersedes the earlier retained-reader defaults): The user explicitly chose to end retired-contract data support and remove its coverage. Release R will not retain compatibility readers or cross-release historical test matrices solely for retired contracts. Absence of consumer history does not block package removal when the contract is explicitly unsupported; it prevents that consumer from claiming a seamless data-preserving adoption.

Decision (2026-10-05): The user requires only Language 6 positive coverage. Every old assertion about supported functionality must have a passing Language 6 replacement before removal. Retire tests for obsolete behavior and deduplicate equivalent current tests; do not delete current replay/recovery functionality to reduce test time.

Decision (2026-10-05): All known consumers will be asked to migrate to Language 6 soon to facilitate the major breaking change. Track each source/API migration and data/work disposition; do not assume a preamble edit drains queues or converts journals. Prepare requests and readiness evidence without sending unsolicited messages.

Decision (2026-10-05): Data support is defined by exact runtime/wire/identity/ledger policies, not the historical author's DSL language number or a timestamp. Language 6 already uses some long-lived encodings; those current encodings and accepted forms remain part of Language 6. An old test name is not evidence that its assertion is obsolete.


## Outcomes & Retrospective


Planning revision (2026-10-05): The plan now targets retirement of old data support and old coverage, rather than indefinite internal compatibility readers. It requires migration of all retained functionality to Language 6 and a consumer migration campaign. Implementation remains unstarted. At completion report deleted readers/suites/build targets, migrated function coverage, the precise data cutoff, consumer readiness, and measured build/test changes.


## Context and Orientation


The repository has Haskell packages `keiro-core`, `keiro`, `keiro-pgmq`, `keiro-migrations`, `keiro-dsl`, `keiro-ops`, and test helper `keiro-test-support`. Their checked-in Cabal files currently say `0.19.0.1`; this is not a claim about the latest published release. `cabal.project` includes the packages, corpus tool, and generated service-package proofs. `Justfile` owns `verify`, `haskell-test`, `corpus-regen`, `conformance-corpus-policy`, `process-reaction-proof`, `replay-compatibility`, and `checked-mapping-adoption`. Run commands from the repository root. Never traverse `/` or `/nix/store` for code.

A DSL language selects source syntax and runtime meaning through `language keiro-dsl N`. `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` recognizes 1–6: 1–4 are compatibility-only, 5 stable, and 6 candidate. The syntax/runtime profile numbers differ from language numbers: Language 6 uses profile 5. `supportedLanguageVersions` currently includes every registry definition. `keiro-dsl/src/Keiro/Dsl/Parser/Preamble.hs` treats a missing declaration as `LegacyUnversioned`, meaning Language 1. `keiro-dsl/src/Keiro/Dsl/Parser.hs` and the modules under `keiro-dsl/src/Keiro/Dsl/Parser/` provide the frontend. Selection happens before body parsing.

`keiro-dsl/src/Keiro/Dsl/SemanticContract.hs` wraps a graph in `CheckedService`, an explicit execution contract, but its `legacyCheckedService` invents Language 1 for bare graphs. `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` exposes old wrappers alongside service-aware functions. `keiro-dsl/src/Keiro/Dsl/Harness.hs` also has `harnessFor`, `harnessForWithGoldens`, and `harnessReadModel` wrapping a bare `Spec`. The CLI is `keiro-dsl/app/Main.hs`; it supports source inspection, validation, generation, and diff. A Hole is an application-owned Haskell module generated once; regeneration must preserve its bytes.

In `keiro/src/Keiro/ReadModel.hs`, modern `ReadModelBlueprint` builders still store deprecated `subscriptionName`, `defaultConsistency`, and `strongScope` inside `ReadModel`, translating between current `QueryFreshness` and old `ConsistencyMode`/`StrongScope`. `runQueryWith`, old consistency constructors/options, and the fields are deprecated. The replacements are current blueprint builders, `QueryCursorAuthority`, `QueryFreshness`, `HeadScope`, and `runQueryWithFreshness`. `keiro/src/Keiro/Projection.hs` has unmanaged command/projection paths alongside catalog paths; `keiro/src/Keiro/ReadModel/Schema.hs` and `keiro/src/Keiro/ReadModel/Rebuild.hs` retain legacy registration/rebuild logic beside `keiro/src/Keiro/ReadModel/Rebuild/Group.hs`. `recordProjectionLag` and `mintIntegrationEvent` in `keiro/src/Keiro/Outbox.hs` are deprecated aliases/construction paths.

Durable data includes events, snapshots, queued jobs, process accepted witnesses, timers, and workflow journals. Replay reconstructs state by decoding stored events; recovery resumes partially completed work after a crash. Current versions need both. Older compatibility paths include pre-UTF-8/positional ids in `keiro/src/Keiro/DeterministicId.hs` and `keiro/src/Keiro/Router.hs`; old manager execution in `keiro/src/Keiro/ProcessManager.hs` beside `keiro/src/Keiro/ProcessManager/Reaction.hs`; generation-0 adoption in `keiro/src/Keiro/Workflow/Awakeable/Compatibility.hs`; and fallbacks in `keiro/src/Keiro/Workflow/Sleep.hs` and `keiro/src/Keiro/Workflow/Child.hs`. Exact accepted policies, not a name containing `legacy`, determine what is retired. Raw identity constructors in `keiro/src/Keiro/Workflow/Types.hs` coexist with checked constructors.

`keiro-dsl/src/Keiro/Dsl/ScaffoldRecord.hs`, `keiro-dsl/src/Keiro/Dsl/WorkspaceRecord.hs`, `keiro-dsl/src/Keiro/Dsl/WorkspaceAdoption.hs`, `keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs`, and `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` read generation ledgers and handle adoption without overwriting user code. R may reject obsolete ledgers and require D-based migration; it need not maintain their full readers. Minimal header recognition for a refusal is not a historical execution path.

`keiro-dsl/test/conformance-baseline.json` assigns compiled suites their source, role, and language owner. `keiro-dsl/test/conformance-corpus-manifest.txt`, `keiro-dsl/tools/corpus-regen/src/CorpusPlan.hs`, and `keiro-dsl/tools/corpus-regen/src/Main.hs` drive corpus checks. Use `cabal test keiro-dsl:tests` to run all suites, not the bare package target. Old-only examples include `keiro-dsl/test/conformance-contract-v1-compat` and `keiro-dsl/test/conformance-id-domain-migration`. `keiro-dsl/test/conformance-codec-compare` mixes migration comparisons and reusable codec behavior: split its assertions before deleting retired comparison code. A fixture such as `keiro-dsl/test/conformance-calendar-days/fixtures/codec-compare/historical-plus-year.json` can still exercise an accepted Language 6 form and therefore needs a current test even when its old comparison harness is removed.

`scripts/check-replay-compatibility.py`, its `scripts/tests/test_replay_compatibility.py` tests and fixture reports, and `scripts/check-checked-mapping-release.py` with its tests validate cross-build/history adoption evidence. `Justfile` invokes them in routine verification. Their retired-only work must be deleted or disconnected, not relabeled current. `keiro-dsl/test/checked-mapping-adoption-test.sh` proves fresh scaffold and repeat-generation user-code preservation, which remain current functions. Preserve those assertions under the current baseline.

Mori currently reports dependent projects including `mori://shinzui/rei`, `mori://shinzui/mori`, `mori://shinzui/keiei`, `mori://shinzui/kikan`, `mori://shinzui/kawa`, and `mori://shinzui/shikigami`; refresh the full list. Record durable cross-repository references using canonical Mori URIs, with project URI plus project-relative path when an artifact URI is pending. Registry absence is not proof of no users.

Related checked-in plans are [Plan 296](296-add-checked-dsl-source-upgrades-and-mori-fleet-planning.md), whose declaration-only 5-to-6 recipe is planned rather than implemented, [Plan 244](244-introduce-truthful-query-freshness-runtime-apis-with-compatibility.md), and [MasterPlan 44](../masterplans/44-add-checked-value-mappings-while-preserving-stream-and-workflow-replay-across-refactors.md). Their old evidence remains in Git history and does not become a recurring R requirement.

Relevant local ADRs are [ADR-16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md), source selection; [ADR-18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md), fold identity; [ADR-22](../adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md), ledgers; [ADR-24](../adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md), deterministic ids; [ADR-41](../adr/0041-process-manager-reactions-use-accepted-witnesses-and-target-keyed-recovery.md), process recovery; [ADR-47](../adr/0047-dsl-retirement-requires-complete-retained-history-evidence.md), retained-history evidence; [ADR-4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md), layered validation; and [ADR-28](../adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md), operator boundaries. [ADR-49](../adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md) records the user's new support cutoff. Older retention requirements apply while their contracts remain supported; they do not override the explicit R retirement. Current-contract identity/replay correctness and consumer adoption limits still apply.


## Plan of Work


### Milestone 1 — Inventory implementation and function coverage


Create `docs/maintenance/pre-1.0-compatibility-retirement.json` and a small standard-library checker, `scripts/check-compatibility-retirement.py`, with mutation tests in `scripts/tests/test_compatibility_retirement.py`. Add `just compatibility-retirement-policy` to `Justfile` and `verify`. This manifest records a finite deletion/coverage inventory, not a new universal historical comparison gate.

Inventory exact symbols/files across runtime and DSL packages, generated tests, package declarations, scripts, and docs. Seed it with Languages 1–5/unversioned selection; Spec-only scaffold/harness APIs; deprecated read-model storage/translation; unmanaged projection/registration/rebuild; deprecated aliases; raw workflow constructors; old process execution/identity bridges; old workflow payload readers; and obsolete ledger readers. For each entry choose `remove-at-R` or `keep-current-function`, name the replacement and any retired data policy. `unresolved` blocks completing the implementation inventory. There is no indefinite `retain-historical-reader` disposition for retired contracts.

Map each old positive test to either a supported function with a named Language 6 replacement, a duplicated assertion already covered by a current test, or retired behavior to delete. Preserve unique supported assertions, including negative codec admission and failure-path assertions. Runtime-only functions map to current-runtime tests rather than fabricated DSL versions. Record current source ownership, suite/component count, generated module count, old comparison build invocations, and repeatable cold-build, incremental-build, and warm-test timings with machine/environment facts.

Acceptance: the checker rejects missing mappings, non-6 replacement sources, replacements without the named test, and deleted supported functionality. The pre-change build/tests pass or have recorded pre-existing failures. The inventory identifies which work will actually disappear instead of equating preamble edits with savings.


### Milestone 2 — Finalize Language 6 and prepare deprecation and consumer migration


Call the deprecation release D and the later breaking pre-1.0 release R. Select real versions using the shared release convention during implementation. Finalize 6 at an exact revision using its full feature/admission tests, generated examples, repeated scaffold preservation, and current replay/process/workflow proofs. Existing published candidate wire policies that remain current are still frozen. Define R's supported data baseline by exact event/codec policies, identity families, queued/timer/workflow formats, snapshots, and ledger schemas. Enumerate the retired ones; language number alone does not describe data.

In `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`, introduce deprecated/retired lifecycle metadata separate from publication maturity. At D mark 6 stable and 1–5 deprecated, with unchanged old execution meaning until removal. Add `DeprecatedLanguageVersion` warning through `keiro-dsl/src/Keiro/Dsl/Validate.hs`, `keiro-dsl/src/Keiro/Dsl/SemanticContract.hs`, `keiro-dsl/src/Keiro/Dsl/CheckReport.hs`, and `keiro-dsl/app/Main.hs`; `check --deny DeprecatedLanguageVersion` fails without rewriting warning severity. Include notices in commands loading old source, keep JSON valid, identify affected workspace members, and generate new skeletons as 6. Deprecate each obsolete public API with its real replacement.

Write `docs/guides/migrating-keiro-pre-1.0-compatibility.md` using the existing guide profile/metadata/log. Prepare a request for each known consumer to migrate soon, naming D/R, source/API changes, its affected runtime/data policies, and a readiness owner/result. Store the request/readiness records in the manifest or its linked repository artifacts; do not send them automatically. Ask consumers to adopt Language 6 during D preparation, while old tooling still works. Readiness states are `requested`, `ready`, or `blocked`; blocked adoption never becomes an implied compatibility promise in R.

The guide must say that R supports fresh current data or an explicit application-owned migration/rebuild, and that old queues, archives, pending timers, partially completed process work, workflow generations, and operator replay can reintroduce retired data. Finish, migrate, or isolate that work using D before R adoption. Retain D's immutable tag/build recipe for a consumer staying on its old environment; do not add an old-mode switch to R.

Update `CHANGELOG.md`, `docs/user/keiro-dsl-reference.md`, `docs/user/keiro-dsl-validation-and-evolution.md`, `docs/user/keiro-dsl-workspaces-and-generated-code.md`, and `agents/skills/keiro-dsl-authoring/`. Align relevant ADR lifecycle/support wording with ADR-49. Acceptance: D warnings and current examples pass, current data policies and retired policies are explicit, every known consumer has a prepared request/readiness row, and the R break is clearly advertised. Record D's publication tag/version before removal begins.


### Milestone 3 — Migrate supported assertions to Language 6


Use `keiro-dsl/test/conformance-baseline.json`, `keiro-dsl/test/conformance-corpus-manifest.txt`, `keiro-dsl/tools/corpus-regen/src/CorpusPlan.hs`, and `keiro-dsl/keiro-dsl.cabal` to port each old suite's supported functionality. Classify each assertion through M1's mapping. Rewrite fixtures, generated code, Holes, expected outputs, and failure cases for 6's actual semantics; a source preamble edit is insufficient when policies differ. Reuse an existing Language 6 generated corpus for equivalent behavior where possible so two suites do not compile duplicate generated modules.

Cover current aggregates, guards/outcomes, codec admission, snapshots, replay, queues/order, integration receipts, projection/query waits/rebuild, processes/partial fan-out/timers, and workflow recovery. Retire old-only assertions such as Language 1 permissive contract behavior or an obsolete identity-probe contract. Re-home currently accepted codec forms from old comparison directories into ordinary Language 6 round-trip/admission/normalization tests. Keep helper/runtime-only tests independent of source language with explicit current ownership.

Use D for one-time source/API migration checks: 5-to-6 is declaration-only only if both check and diff reports only source-language changes; 1–4 require actual reviewed changes. Do not retain D builds or old positive test matrices in R's tree or CI. Git history and the D tag are the archive. Convert obsolete ledgers with D before R, preserving Hole hashes; R may keep minimal obsolete-header refusal logic, not their full execution/adoption readers.

Add `keiro-dsl/test/compatibility-retirement-test.sh` for current scaffold, round trip, repeat-generation preservation, and small retired-input rejection cases. Update consumer readiness with source/API migration results and separate data adoption dispositions. Acceptance: every supported old function has a passing named current test, all positive DSL fixtures select 6, no generated-primary role claims 1–5, and current coverage can run without invoking an old build. Every known consumer has a recorded readiness result; production mutation/deployment remains outside this implementation.


### Milestone 4 — Delete old DSL execution


After D publication, `supportedLanguageVersions` must contain only 6. Keep minimal retired numbers/status metadata for messages, not old profile implementations needed only for execution/evidence. `keiro-dsl/src/Keiro/Dsl/Parser/Preamble.hs` refuses 1–5 as `RetiredLanguageVersion` in `SourceSelectionPhase`, and a missing declaration as `MissingLanguageDeclaration`; never reinterpret it as 6. Unknown positive numbers remain unsupported. Zero, malformed, duplicate, misplaced preambles, and contextual domain identifiers named `language` retain their precise behavior.

Apply this policy to every public parser, CLI source loader, workspace loader, and explicit checked-service construction. A workspace with one retired/missing member fails at its location before creating output. `--min-language` cannot bypass refusal. R diff against retired source explains use of D for migration, while diff between current sources still reports current evolution consequences.

Delete retired-only parser/validator/pretty-print/scaffold/harness branches, profile helpers, and old public Spec-only wrappers including `legacyCheckedService`. Migrate remaining callers to checked Language 6 construction or workspace composition. Remove obsolete module declarations, registry execution data, old generation matrices, and boundary checker allowances. Acceptance: current source checks/scaffolds/runs, retired source fails precisely with no writes, obsolete entry points cannot execute, and the coverage checker finds no positive old-language fixture.


### Milestone 5 — Consolidate runtime APIs


In `keiro/src/Keiro/ReadModel.hs`, store current `QueryCursorAuthority` and `QueryFreshness` directly. Keep existing checked blueprint builders and current query/accessor functions; expose `ReadModel` abstractly. Remove `ConsistencyMode`, `StrongScope`, their deprecated options/fields, `runQueryWith`, sentinel storage, and bidirectional translations. `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` emits current builders only. Immediate queries do not poll; head waits capture the visible reachable head; position waits require a concrete target; missing cursor fails before polling. Test all of these through current 6 examples and runtime tests.

Replace unmanaged projection/registration/rebuild callers with current catalog/group APIs, including hand-written services, `jitsurei`, and `keiro-ops`. Remove the obsolete execution paths and retired registration adoption helpers after providing current examples. Old persisted registration is outside R's support baseline and must be migrated/rebuilt externally before adoption. Preserve immutable schema-migration files needed to construct current fresh databases; they are not old runtime coverage.

Remove `recordProjectionLag` and obsolete metric aliases with documented current replacements. Remove `mintIntegrationEvent` after each caller explicitly chooses replay-safe producer enqueue or intentionally fresh envelope construction. Make `WorkflowName`/`WorkflowId` opaque with checked constructors and text accessors. Remove readers solely for retired invalid identity forms; current accepted identities retain correct stream/step behavior.

Migrate old process authoring/API functionality to current reaction execution where supported, with explicit semantic changes and current tests. If a hand-written function remains a genuinely supported current capability, consolidate it and test it as current; do not retain a separate runner solely to resume retired identity families. Never silently switch an old live manager's unfinished fan-out to new ids. Acceptance: current generated and hand-written examples compile/run through current APIs, old APIs fail client compilation, and all runtime/component tests pass using the migrated functionality.


### Milestone 6 — Delete retired data coverage and implementations


At R, delete readers, probes, runners, ledger fallbacks, fixtures, generated history programs, and mutation cases whose sole contract is now unsupported. Remove pre-UTF-8/positional-router bridges together, old generation-0 adoption and payload/result fallbacks if outside the defined current baseline, and historical-only codec/identity snapshots. Do not remove a decoder form merely because its test file says historical if that form remains accepted by current 6. M1's contract and function map determines the difference.

Remove the old-only work in `keiro-dsl/test/conformance-contract-v1-compat`, `keiro-dsl/test/conformance-id-domain-migration`, `keiro-dsl/test/id-domain-migration-mutation-test.sh`, and `keiro-dsl/test/conformance-codec-compare` after migrating their retained function assertions. Remove retired standalone comparison packages/runner declarations from Cabal and `cabal.project`, and their source-directory/glob/manifest entries. If reusable codec comparison is still a public current tool, test it on current contracts only; delete its old concrete historical implementation and build dependencies.

Retire `scripts/check-replay-compatibility.py`, its retired-build report fixtures/tests, and `scripts/check-checked-mapping-release.py` with its checked-mapping historical release manifest/tests when their only purpose is old-build adoption certification. Extract any current codec normalization, scaffold-preservation, inventory-validation, or recovery assertions first. Remove `replay-compatibility` from `Justfile` and routine `verify`; replace only the current-contract functionality with `current-replay-proof`. Keep `process-reaction-proof` and fresh/repeated scaffold coverage from `checked-mapping-adoption` as current proofs, without old-build/consumer-capture requirements. Old report schemas/manifests remain recoverable from D/Git, not runnable routine R artifacts.

Current replay proof writes through the current writer, serializes actual envelopes, decodes/replays them using the current reader, and checks state; recovery tests crash/retry current partial process work and resume current workflows. Current-policy fixed vectors still defend identity stability. Mutations that alter current decoding/fold, duplicate a current target, lose a workflow step, or overwrite a Hole must fail. A mutation deleting an unsupported old reader is no longer expected to fail.

Document that old data outside the baseline cannot be replayed/resumed under R. Refuse recognizable retired tags/ledger headers with actionable current-baseline guidance. Where old bytes have no distinct marker, do not claim a universal automatic detector: migration/readiness records control adoption, and incidental successful decoding does not restore a supported old interpretation. No new compatibility reader or huge all-consumer history collector is required to certify intentional retirement.

Acceptance: routine `verify` executes no old build, cross-version history comparison, historical consumer capture, or retired compatibility suite. The checker detects any orphaned old component, fixture, or CI invocation. Every retained function still has current positive coverage. Current replay/recovery passes and its negative mutations fail. Release removal can proceed without every consumer's private history; a blocked consumer stays on D or migrates/rebuilds before adopting R.


### Milestone 7 — Verify actual work reduction and prepare R


Run the current-only full gate. Compare with M1 on the same machine/environment: accepted DSL versions, compiled/generated module counts, component counts, historical runner invocations, cold/incremental compile times, and warm test times. Record deleted work separately from migrated assertions; porting a suite does not save its build. Require actual obsolete module/target deletion and no historical rebuild workload. Consolidate equivalent current suites where M1 shows duplication. Do not invent a percentage improvement; record measurements and explain retained current costs.

Update current docs/authoring guidance, corpus index, and release notes to name Language 6, the supported data baseline, removed policies, and the D fallback. Every known consumer has a readiness result and a migration request prepared soon enough for D/R. A blocked consumer's production adoption is not automatically authorized by package publication. Choose a real breaking R version later than D and below `1.0.0.0`, verifying registry versions/upstream tags before any bounds or pins. Publication follows the release workflow when requested.

Distill lifecycle, data support, and current-only coverage into the relevant ADRs and log. Acceptance: `just verify` and the retirement checker pass, all positive DSL coverage is 6, no supported old assertion lacks a current replacement, no retired historical reader/test/build remains active, measurements show what work was removed, and the release preparation is reviewable. Populate Outcomes & Retrospective with implementation evidence, final costs, and consumer readiness. Only then mark the plan implemented.


## Concrete Steps


Run from the root of the Keiro checkout on the current branch. Use `nix develop` if tools are missing; never inspect the Nix store. Record unrelated working-tree changes and leave them intact.

```bash
git status --short
mori registry list
mori registry dependents shinzui/keiro --packages --json
rg -n 'DEPRECATED|CompatibilityOnly|legacyCheckedService' keiro/src keiro-core/src keiro-pgmq/src keiro-ops/src keiro-dsl/src
rg -n -i 'historical|compatibility|legacy|baseline' keiro-dsl/test scripts Justfile
cabal build all
cabal test keiro-dsl:tests --test-show-details=direct
just conformance-corpus-policy
just replay-compatibility
```

This is the one-time pre-removal baseline, not an R command list. Record actual component/module counts and timing environment. The old replay command is removed in M6. Use `/usr/bin/time -p` for repeated measured build/test commands on the same machine; capture cold and incremental runs in isolated task-owned build directories without deleting shared caches or other work. Report exact commands, revisions, and outputs in the manifest.

After adding the M1 checker and M3 shell proof, run:

```bash
just compatibility-retirement-policy
python3 scripts/check-compatibility-retirement.py docs/maintenance/pre-1.0-compatibility-retirement.json --phase deprecation
bash keiro-dsl/test/compatibility-retirement-test.sh deprecation
python3 -m unittest discover -s scripts/tests -p test_compatibility_retirement.py
```

The deprecation phase is transient until D is published. At removal use `--phase removal` and `compatibility-retirement-test.sh removal`, then delete any old positive/D-only test inputs and invocations from the final R tree. Expected checker success is `ok: compatibility retirement removal gate`; it must fail for a positive non-6 fixture, unmapped supported assertion, or remaining historical-only build invocation. The `just` recipe runs the current manifest phase plus its mutation tests without silently falling back.

The integrated current workspace exists and its members declare 6. Final current proof commands are:

```bash
cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/checked-mapping-replay-workspace/service.keiro-workspace --min-language 6
cabal run -v0 keiro-dsl -- new aggregate
cabal test keiro-dsl:tests --test-show-details=direct
just current-replay-proof
just process-reaction-proof
just checked-mapping-adoption
just conformance-corpus-policy
just keiro-reexports
just dsl-api-boundaries
just verify
```

`current-replay-proof` is a new M6 recipe; it invokes current-contract tests, not old baseline/candidate programs. `new aggregate` starts with `language keiro-dsl 6`. `checked-mapping-adoption` retains fresh/repeated scaffold preservation only. After intended migrations run `just corpus-regen`, inspect `git diff --stat` and the actual diff, and require a clean second regeneration.

For changed ADRs and guide metadata run:

```bash
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just user-documentation-validate
```

Use `okf id next docs/adr --profile docs/adr/profile.dhall ADR` only to allocate a new ADR, and `okf log add` when a bundle timestamp advances. Every implementation commit uses Conventional Commits and both trailers:

```text
ExecPlan: docs/plans/304-retire-legacy-language-and-runtime-compatibility-before-keiro-1-0.md
Intention: intention_01m46h492de0srrr02wm5y0ybv
```


## Validation and Acceptance


Before D, run minimal old-input/API deprecation smoke checks while the old release is still supported. These are implementation/release-D checks, not retained R positive coverage. At R, test source 6 success, current pretty/scaffold round trips, create-once Hole preservation, precise retired/missing-source rejection, invalid/unknown/duplicate/misplaced preamble errors, mixed workspace refusal before output writes, and explicit retired diff guidance. Build negative old declarations from a current fixture in a temporary directory rather than keeping a compiled old-language corpus.

The M1 assertion map is the coverage acceptance authority. A supported old case must point to a current test exercising the same retained function and its meaningful error paths; a passing compilation-only replacement does not suffice. If 6 intentionally changes the old result, name the new intended behavior and test it. Every positive `.keiro` used by an active corpus/test selects 6, including sources embedded in Haskell/shell strings. Runtime-only and negative unsupported-input tests are explicitly identified so the checker does not misclassify them. Validate every retained function after old fixtures/components are deleted; old source syntax may not be an escape hatch for a helper.

Current-data correctness is checked by current serialized round trips, forward/replay state equality, snapshot admission, process partial-completion recovery, timer lifecycle, queue/idempotence behavior, and workflow continuation. Wire/identity vectors pin the current contract, not a retired package. Mutation tests prove that breaking those current functions fails. No final gate requires all-consumer retained-history captures or old-version binary comparisons. Ended data support is documented and old behavior is not labeled replay-compatible.

Use `cabal test keiro-test`, `cabal test keiro-pgmq-test`, `cabal test keiro-ops-test`, `cabal test jitsurei-test`, `cabal test keiro-dsl:tests`, and finally `just verify`. Shared suite fixtures in `keiro-test-support/src/Keiro/Test/Postgres.hs` start ephemeral PostgreSQL and clone migrated templates; PostgreSQL tools must be on PATH. Live `jitsurei` demonstrations in `verify` additionally use local databases: `just postgres-start`, `just create-database`, and `just jitsurei-db-create`, or the configured `just process-compose` stack. Use local environment overrides where needed; never run tests against production.

Completion requires deleted historical build/test/reader work and measured compile/test costs, not just six becoming one in a registry. If porting current functionality preserves many suites, report that honestly and consolidate only demonstrably duplicated generated/test work. Do not weaken current correctness to manufacture a timing result.


## Idempotence and Recovery


Inventory, discovery, and tests are repeatable. Use task-owned temporary directories for scaffolds/mutations/builds and preserve unrelated work. Commit clean milestones and retain D's immutable source/tag/build instructions. Regeneration twice must leave no extra changes and no Hole hash changes. Retired active fixtures are archived in Git/D, not preserved as frozen build components in R.

Do not begin removal before D publication and its source/data cutoff announcement. An old environment remains on D until it can adopt R's current source/API/data contracts. Every consumer has a readiness row; updating a source declaration does not grant data readiness. Finish, migrate, rebuild, or isolate old queues/timers/process/workflow work externally before adopting R. Missing data access does not require restoring retired coverage in R or falsely marking a consumer ready.

This plan authorizes code/test retirement planning and later implementation, not deletion of live data or deployment. Before any separately authorized migration, back up the old environment, rehearse the application-owned conversion/rebuild, and establish rollback limits. Do not delete old histories, queue archives, or migration records to make a check green. Once R writes current data, D might not read it; a code revert alone is not a safe data rollback. Keep the old environment isolated or use an explicitly rehearsed application rollback.

Within the current supported contract, identity seeds, accepted wire meaning, workflow step keys, and replay correctness remain stable. Removing a retired reader is intentional; altering a current reader is still a current correctness change requiring tests and, when needed, a new versioned policy.


## Interfaces and Dependencies


No new runtime dependency is required. Use existing Haskell/Python tools, current PostgreSQL fixtures, Mori discovery, and OKF validation. Before guessing any external API, locate its source/docs through Mori and read them. Verify authoritative package registry versions and upstream tags before changing bounds/pins.

The retirement manifest schema is `keiro.compatibility-retirement/v1`. It carries baseline/candidate revisions; D/R versions/tags; current phase; supported/retired runtime data policy identities; consumer migration request/readiness records; coverage mappings; build/test metrics; and exact implementation entries. Each entry identifies `key`, `symbols`, `files`, `replacement`, `disposition`, `knownDependents`, `retiredDataContracts`, `coverageMappings`, and `evidence`. A coverage mapping names an old case and either its passing current test/source, an existing equivalent current assertion, or explicit retired behavior. No historical-reader exception is allowed solely for an ended contract. Consumer data readiness is separate from source readiness, and neither is inferred from registry presence or from package publication.

`scripts/check-compatibility-retirement.py MANIFEST --phase deprecation|removal` exits nonzero for unknown mappings, non-6 positive source, missing named function coverage, orphaned old components/fixtures/CI invocations, lingering deleted exports/readers, or removal before D publication. It checks the real corpus/Cabal/script inventories, including embedded source; recording `removed` alone is not proof. Known consumer rows are complete even if some adoption is blocked. A blocked deployment does not prevent an explicit package support cutoff from being described honestly.

`Keiro.Dsl.LanguageVersion` distinguishes retired-number recognition from supported execution; at R only 6 executes. `Keiro.Dsl.SemanticContract.CheckedService` stays explicit and opaque, without bare-Spec legacy construction. `Keiro.ReadModel` stores current cursor authority and freshness, exposes current read-only accessors, and uses existing blueprint builders and query functions. `Keiro.Workflow.Types` exposes abstract `WorkflowName`/`WorkflowId`, checked `mkWorkflowName`/`mkWorkflowId`, and text accessors. Unsupported historical constructor forms no longer carry an R promise.

Current data policy identities, codec forms, deterministic seeds, workflow keys, and reaction identities continue to be tested. Remove obsolete concrete history comparisons and fallback policies, not the current replay mechanism. Identifiable unsupported contracts receive an actionable refusal; indistinguishable old bytes do not imply supported old semantics. No `--legacy` execution mode or retained old positive test matrix remains.

Creation note (2026-10-05): Researched the toolchain/runtime and created the original seven-milestone plan under the Mina intention. No implementation or release was performed.

Revision note (2026-10-05): At the user's explicit request, ended the default requirement to preserve retired data readers and coverage. Reframed all milestones, validation, recovery, and interfaces around one positive Language 6 baseline; required migration of every old test of supported functionality; added the all-consumer migration/readiness campaign and explicit breaking data cutoff; and replaced recurring historical comparisons with current-contract replay/recovery proofs. ADR-49 and scoped ADR clarifications record the policy. No runtime/test deletion, messages to consumers, deployment, or data mutation has been performed.
