---
id: 296
slug: add-checked-dsl-source-upgrades-and-mori-fleet-planning
title: "Add checked DSL source upgrades and Mori fleet planning"
kind: exec-plan
created_at: 2026-09-22T02:05:06Z
intention: "intention_01m33ee8ybesgbj7yy4rq4f1hw"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-22T02:05:06Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-22T02:17:30Z
      mode: "update"
      note: "Link the intention created through mina ci at user request"
---

# Add checked DSL source upgrades and Mori fleet planning


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Implement [IR-5](../improvement-requests/add-version-aware-keiro-dsl-upgrade-and-fleet-rewrite-tooling.md): let an operator inspect, preview, and apply checked upgrades of `.keiro` sources, including every member of a service workspace. Each upgrade follows registered predecessor-to-successor steps, explains compatibility consequences, and refuses changes whose meaning cannot be established. A separate fleet command discovers registered Keiro dependents through Mori and produces per-repository plans without rewriting those repositories.

The request is implementable with the current source-aware frontend, checked semantic service, workspace content-loader abstraction, and compatibility differ. It needs new transformation, reporting, transaction, and fleet orchestration code. This plan delivers six milestones. It does not implement general modernization, deploy services, rewrite generated Haskell, migrate databases, or retire historical language support.

Two qualifications are essential. A transition may legitimately require only a declaration edit when its checked body is unaffected; the guarantee is that no transition *blindly* changes the declaration. Also, separate filesystem renames cannot make several existing paths change simultaneously for arbitrary readers. Workspace atomicity here means full validation before writes, rollback on handled failures, and explicit recovery after process interruption. Readers must not consume a workspace while its upgrade transaction is incomplete.


## Progress


No implementation work has started. Populate the implementation checklist when implementation begins.


## Surprises & Discoveries


(None yet.)


## Decision Log


Decision (2026-09-21): default to the published stable language, currently 5, and require `--allow-candidate` together with an explicit `--to 6` for the current candidate. The source registry already distinguishes supported, stable, and candidate contracts; an authoring default must not silently become an upgrade target.

Decision (2026-09-21): preserve original text with located edits, rather than reprint an entire source. The frontend does not retain comments and whitespace, so canonical pretty printing is a validation tool, not the rewrite serializer. A verified body-preserving step is allowed and must include its checks and runtime-profile delta in the report. This interprets IR-5 acceptance item 4 as a prohibition on unchecked preamble bumps, not a demand to invent body changes.

Decision (2026-09-21): stop on unknown or incompatible semantics and report manual obligations. A manual obligation is a named action with source locations, evidence, and an explanation of why the tool cannot establish a safe automatic rewrite. No general `--force` or blanket acknowledgement bypass is provided. Candidate selection does not waive compatibility gates.

Decision (2026-09-21): use recoverable multi-file transactions, documenting the visibility limitation explicitly. Preserve workspace paths and manifest identity; introducing generation directories or teaching all external readers a new indirection protocol would be a separate architecture change.

Decision (2026-09-21): use Mori as an optional subprocess for fleet inventory, with recorded JSON inputs in tests. Mori itself depends on Keiro, so importing its Haskell library into Keiro would introduce an undesirable dependency cycle. No dependency version changes are required by this plan.


## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


`keiro-dsl/app/Main.hs` defines the command parser and single-file/workspace dispatch. It currently has no source upgrade command. Its `Check` route parses an exact source document, constructs a checked service, and calls `checkIndexedServiceDiagnostics` from `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`. Reuse that semantic checking boundary; parsing alone does not establish a valid specification.

`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` owns `languageRegistry`, `LanguageDefinition.predecessor`, syntax capabilities, runtime capabilities, support, and maturity. At research time it registers published Languages 1–5, stable Language 5, and candidate Language 6. Unversioned input has effective version 1 but no declared version. Language versions are distinct from package versions. The request's statement that Languages 1–5 exist is incomplete for this working tree.

`keiro-dsl/src/Keiro/Dsl/Frontend.hs`, `keiro-dsl/src/Keiro/Dsl/Parser.hs`, `keiro-dsl/src/Keiro/Dsl/Source.hs`, and `keiro-dsl/src/Keiro/Dsl/SourceIndex.hs` expose located syntax and `parseSourceDocument`. A span is a half-open interval from one text position to another; offsets are positions in the parser's `Text` stream, not UTF-8 byte offsets. The resulting document contains a `ParsedSource` plus an exact semantic source index. The semantic graph, `Spec`, deliberately excludes source provenance. `CheckedService` in `keiro-dsl/src/Keiro/Dsl/SemanticContract.hs` pairs it with the selected runtime contract.

`keiro-dsl/src/Keiro/Dsl/Parser/Aggregate.hs` has a critical 1→2 default change: an unannotated transition becomes `GeneratedImplementation` in a language supporting typed aggregate expressions, whereas Language 1 produces `LegacyHoleImplementation`. A Hole delegates behavior to application-owned Haskell. A naive preamble change can therefore transfer behavior ownership. Language 2→3 introduces generated-ID admission and nominal equality semantics. Language 3→4 tightens public-contract TypeID admission and surface validation. Language 4→5 changes projection/query policy syntax and adds runtime capabilities. Language 5→6 adds candidate capabilities that must also be inspected, not inferred safe from numeric ordering.

`keiro-dsl/src/Keiro/Dsl/Parser/ReadModel.hs` preserves legacy consistency/feed/subscription policy for earlier languages, but Language 5 uses `freshness` and projection-owner-derived supply. [Plan 250](250-report-legacy-strong-consistency-weakening-across-the-language-4-to-5-migration-in-diff.md) already fixes classification of Strong-to-immediate weakening. Legacy read models may lack information needed to choose a new projection owner. Preserve that uncertainty as an obligation.

`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` offers `renderSource` and `renderSpec`, which canonicalize presentation and discard trivia. `keiro-dsl/src/Keiro/Dsl/Diff.hs` offers `diffSources` and `diffServices`; `keiro-dsl/src/Keiro/Dsl/WorkspaceDiff.hs` offers `diffWorkspaces`; `keiro-dsl/src/Keiro/Dsl/DiffReport.hs` serializes findings and compatibility vectors. A compatibility vector classifies consequences separately for persisted and consumer-facing surfaces. Reuse existing mapped and coordination impact analyses as the CLI diff route does, and include aggregate replay impact. Do not equate an unchanged graph or a provenance-only finding with unchanged runtime behavior.

`keiro-dsl/src/Keiro/Dsl/Workspace.hs` parses explicit `.keiro-workspace` manifests and loads members through `ContentSource`. This allows staged text to be checked in memory without first overwriting files. Members must select one effective language version, so transform all members for a step before composing the next workspace. Validate the composed service; a member can refer to declarations owned by another member and need not pass standalone semantic checking. Manifest paths and membership are input evidence even when the manifest bytes do not change.

Tests live in `keiro-dsl/test/Main.hs`, dedicated test modules, fixtures, and CLI shell tests such as `keiro-dsl/test/diff-test.sh`. `keiro-dsl/keiro-dsl.cabal` declares the main `keiro-dsl-test` suite and separate generated-code conformance suites. `justfile` provides corpus and API-boundary checks. Existing published fixtures are retained compatibility evidence and must not be bulk upgraded.

Relevant ADRs were discovered by scanning local filenames and headings. [ADR-14](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md) requires explicit membership, one declaration owner, manifest identity, and composition before checking; its existing atomicity promise covers preflight only. [ADR-16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) separates provenance from semantics, freezes published contracts, and explicitly reserves rewriting for this request. [ADR-18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md) requires checked runtime profiles and frozen replay identity. [ADR-47](../adr/0047-dsl-retirement-requires-complete-retained-history-evidence.md) distinguishes source changes, consumer adoption, and implementation retirement: source checks cannot certify application-owned behavior or historical data safety. Preserve those boundaries.

The external inventory provider is `mori://shinzui/mori`, whose registry documentation is discoverable at `mori://shinzui/mori/docs/user-guide`. Research verified `mori registry dependents shinzui/keiro --json`: it returns an array with dependent `namespace`, `name`, package, dependency, scope, and optional resolved-target facts. Multiple rows can identify one dependent. `mori registry show <namespace/name> --json` supplies its checkout `path`. The local registry returned 18 unique projects, including documentation projects; this count is observation, not a test expectation or a production inventory. The JSON serializer was inspected in that project's `mori-cli/src/Mori/Command/Registry.hs` (artifact-level source URI pending; project identity is `mori://shinzui/mori`).


## Plan of Work


### Milestone 1 — Checked upgrade planning and an explicit step registry


Add `keiro-dsl/src/Keiro/Dsl/Upgrade.hs`, `keiro-dsl/src/Keiro/Dsl/Upgrade/Types.hs`, and `keiro-dsl/src/Keiro/Dsl/Upgrade/Registry.hs`. Keep prepared writes opaque. Build the chain from actual predecessor links, then require one implemented transformation per edge. Reject unknown versions, downgrades, missing edges, ambiguous paths, and implicit candidate targets. Legacy-to-declared-1 is a separate provenance normalization; an already explicit target version is a byte-preserving no-op. An unversioned target-1 request adds the declaration after checking.

Define deterministic reports with schema `keiro-dsl/upgrade-report/1`, source and target versions/maturity, per-member declared/effective versions, ordered step identifiers, exact proposed edits, diagnostics, compatibility reports, obligations, and final status `unchanged`, `ready`, or `blocked`. Each step records syntax/runtime profile identifiers and its validation results even if no body edit is needed. Use stable obligation codes and file-qualified spans. A failure must not masquerade as an empty diff. The report must distinguish a fully validated proposal from partial suggestions produced before a blocked step.

Add `keiro-dsl/test/Keiro/Dsl/UpgradeSpec.hs`, register it in the existing suite, and use an `upgrade` test group. Prove registry-chain selection, stable/candidate policy, unknown versions, and no-op behavior with `cabal test keiro-dsl:keiro-dsl-test --test-options='--match upgrade'`. Passing tests must show that a missing transformation blocks rather than falls back to editing the preamble.

### Milestone 2 — Located sequential transformations with semantic proof


Add `keiro-dsl/src/Keiro/Dsl/Upgrade/Edits.hs` and `keiro-dsl/src/Keiro/Dsl/Upgrade/Validate.hs`. Read and retain original bytes, decode UTF-8 explicitly, parse located syntax, and edit text only at verified token boundaries. Preserve untouched comments, whitespace, newline style, and final-newline presence. Detect unsupported encodings as obligations. Apply disjoint edits in descending offset order; check each expected original slice before applying. Add narrow private parser anchors where the current surface lacks a required insertion site, without changing released parsing behavior or making a general lossless frontend.

Implement 1→2 by detecting every legacy transition and proposing explicit `implementation hole`, never silently generating its behavior. Inserting the clause must preserve the transition's original guard/write/emit/goto text. Reparse and report the resulting ownership and compatibility changes. Existing diff or replay findings about Hole behavior remain obligations; do not suppress them merely because both implementations involve user code. The first automatic end-to-end fixture can be a nonempty context with compatible declarations and no aggregate transitions; add a separate realistic legacy-transition fixture proving the body rewrite and any necessary manual obligations.

Implement 2→3 and 3→4 as dedicated capability-aware assessments. For generated IDs, nominal equality, contract TypeID fields, stricter validation, and aggregate fold changes, include the actual checked findings. A body-preserving result is ready only when the step's applicable semantic checks establish compatibility. Invalid historical IDs, changed admission, unknown user-code behavior, or replay consequences become obligations. Do not invent replacement ID prefixes, validators, event upcasters, or application Haskell.

Implement 4→5 with a conservative boundary: sources without legacy read-model supply can pass through checked profile transition; any legacy supply requiring a projection owner produces a located `ProjectionOwnerRequired` obligation and the exact old freshness/delivery/subscription facts. Supply a manual migration recipe in the guide; do not invent physical projection names, ownership, or checkpoint policy. A Strong legacy policy must never become immediate freshness without a blocking finding. Register 5→6 only for explicit candidate requests and inspect the full candidate capability delta. Unused additive capabilities may require no body edit; affected or unknown surfaces must be reported.

After each edge, parse every rewritten member under the successor, compose the entire workspace through an in-memory `ContentSource`, run the same indexed checks as `check`, and compare before/after services through the existing diff and impact APIs. Canonically render and reparse to verify semantic equivalence of the result, comparing normalized semantics rather than relocated source positions. Check the final result against the original baseline too: a later step must not cancel an earlier unresolved obligation. Reject unrecognized impact, breaking surfaces, or opaque changed behavior; preserve known informational findings without pretending deployment has been validated.

Create `keiro-dsl/test/fixtures/upgrade/` with paired inputs, exact expected outputs, and JSON goldens for every edge, legacy declaration normalization, comments/non-ASCII/CRLF, mixed legacy-and-explicit-v1 workspace members, and known blockers. Focused `upgrade` tests must pass and mutation tests must fail when the implementation is replaced with only a preamble edit, checking/diffing is skipped, or the 1→2 ownership edit is omitted. Also prove an honestly checked body-preserving step succeeds; do not force meaningless changes into every golden.

### Milestone 3 — Preview and check CLI


Extend `keiro-dsl/app/Main.hs` with `upgrade FILE [--to N] [--allow-candidate] [--check | --dry-run | --write] [--format text|json]`. With no mode, behave as `--dry-run`. The three modes are mutually exclusive. `--check` returns 0 only when there are no necessary edits or blockers, 1 for pending edits, and 2 for blockers or invalid input. Dry-run returns 0 for ready/unchanged and 2 for blocked. Write is wired to the transaction engine in milestone 4; before that it must refuse without touching inputs. All modes produce the same structured planning facts; text is a projection of JSON data. JSON goes to stdout, human notices to stderr. Do not let preview create report files, backup directories, or lock files.

Provide a deterministic unified text patch alongside the structured edits. The report names exact files, old and target provenance, body edits, semantic changes, and manual remedies. A blocked workspace has no applicable final patch; diagnostic suggestions must be labeled incomplete. Reuse extension-based workspace dispatch and indexed checking. `--help` documents the stable default, candidate opt-in, exit codes, and transaction visibility limitation.

Add `keiro-dsl/test/upgrade-test.sh`, using temporary fixture copies and the repository's existing CLI-test conventions. `bash keiro-dsl/test/upgrade-test.sh` must prove dry-run/check leave a complete before/after directory inventory and bytes unchanged, including blocked and successful paths, and JSON remains parseable when warnings occur.

### Milestone 4 — Recoverable single-file and workspace writes


Add `keiro-dsl/src/Keiro/Dsl/Upgrade/Transaction.hs` and a testable filesystem-operation boundary. A transaction covers exactly one input file or one manifest's full member set. Refuse symlink targets, aliased file identities, paths outside the input root, and unsafe transaction paths; preserve file permissions. Capture the manifest and every member's original bytes and identity. Check for stale inputs immediately before commit, including unchanged members and membership. Require exclusive operator access to these sources during commit; an advisory tool lock cannot prevent an unrelated editor from racing after the final check.

Only a ready plan can enter a transaction. Exclusively create `.keiro-upgrade/active` under the input root, with a transaction identifier and journal; refuse another active transaction. Stage all candidate bytes and original-byte backups on the same filesystem, validate the staged workspace again, and persist the prepared journal before replacing any source. Each replacement uses same-filesystem rename. Journal state must support determining whether each current file contains original bytes, proposed bytes, or unexpected bytes even if interruption occurs between rename and journal update. Mark committed only after all replacements and verification succeed. Archive successful backup/journal data under the transaction identifier and clear the active marker last.

On a handled write failure, restore all already-replaced members from backups before returning failure. If rollback fails, retain the active marker and exact recovery instructions. Add `upgrade recover INPUT --rollback [--format text|json]` for interrupted transactions. Recovery is idempotent, validates journal paths and backups, restores only files still matching known original or proposed bytes, and refuses to overwrite unrelated edits. Do not silently delete a stale lock or interrupted journal. Dry-run/check encountering an active transaction report `RecoveryRequired` without modifying it. Ensure recover mode does not require successfully parsing a partially written workspace.

Test failure before staging, during staging, after each rename, during rollback, and during recovery through injected filesystem failures. Use subprocess interruption tests at deterministic checkpoints as well. The acceptance is byte-identical restoration for handled failures, an explicit recoverable state after interruption, and no transaction creation for a repeated no-op. This contract covers process interruption and filesystem-operation errors; do not claim power-loss durability without implementing and testing the platform's file/directory synchronization guarantees. Focused tests and `bash keiro-dsl/test/upgrade-test.sh` must pass on supported development platforms.

### Milestone 5 — Mori fleet inventory and per-repository plans


Add `keiro-dsl/src/Keiro/Dsl/Upgrade/Fleet.hs` and a thin subprocess adapter, with `upgrade fleet --to N [--allow-candidate] [--project namespace/name] [--format text|json]`. It is always read-only. Invoke `mori registry dependents shinzui/keiro --json`, deduplicate by the dependent's namespace/name, and resolve each selected checkout with `mori registry show namespace/name --json`. The optional project filter narrows the discovered set; it does not authorize writes. Use argument-vector process APIs, never shell-interpolated command strings. Decode required fields strictly, tolerate unknown fields, and report unavailable registry/checkout/schema errors as failures rather than an empty successful fleet.

For Git checkouts, enumerate tracked files through `git -C ROOT ls-files -z` and inspect only `.keiro` and `.keiro-workspace` candidates. Parse manifest membership first. Analyze each workspace as a unit and each unowned source individually. Members shared by multiple manifests produce an ownership blocker. Honor canonical filesystem boundaries, refuse symlinks leaving the root, and do not recursively scan unregistered directories, submodules, `/`, or `/nix/store`. Non-Git checkouts are explicit unsupported-inventory records in this first version. Tracked fixtures and historical examples are inventory, not presumed adoption targets; mark source role unknown unless explicit metadata establishes it. Record that untracked files are outside inventory coverage.

Emit schema `keiro-dsl/upgrade-fleet-report/1` with canonical `mori://namespace/name` identities, dependency evidence, checkout location, Git HEAD and dirty status, source paths, declared/effective versions, status, blockers, and nested local upgrade proposals. Record missing sources as `no-sources`, not upgraded. Per-repository plans include exact local invocation argument arrays, baseline bytes/digests for freshness checking, and source-selection scope. They are review artifacts; do not offer fleet `--write`, run Git mutations, or treat a ready source plan as production/deployment approval. Operators explicitly invoke local `upgrade FILE --write` for selected inputs, which recomputes and revalidates the plan against current bytes.

Extend tests with fake Mori and Git process results for duplicate dependency rows, documentation-only projects, missing roots, malformed JSON, dirty worktrees, same-named projects in different namespaces, shared members, and one blocked member among healthy projects. Continue inventory after per-project failures and return exit 2 if any blockers/inventory failures remain. Successful read-only plans return 0. `bash keiro-dsl/test/upgrade-test.sh` must verify no writes across two temporary repositories. A live Mori smoke test is inspection only and must not assert a fixed fleet count.

### Milestone 6 — Authoring guide, conformance, and durable decisions


Add `docs/user/dsl-source-upgrades.md` and link it from `docs/user/typed-spec-toolchain.md`. Explain stable versus candidate selection, the step-author contract, body-preserving validation, ownership and projection migration examples, report schemas, manual obligations, transaction visibility, exclusive-write requirement, and recovery. Register the new user document with the existing bundle conventions. Update `docs/user/api-reference.md` and `keiro-dsl/CHANGELOG.md`. Reconcile IR-5's Status and acceptance wording with the actual delivered guarantees and link this plan, following the improvement-request bundle's metadata/log contract.

Run the focused tests, full DSL tests, CLI regression tests, and corpus policy checks below. Add a compiled/runtime proof wherever a transformation is claimed to preserve generated behavior; body text or semantic graph equality alone is insufficient for user-owned Haskell. Preserve all historical fixtures, generated output, and released parser semantics. The source upgrade tool may truthfully stop with obligations on realistic services while still automatically upgrading the compatible subset.

Distill the new upgrade and transaction boundaries into an ADR and update ADR-14/ADR-16 only where the implemented contract changes their text. Before ADR edits, run `mori show --full`, read the declared `docs/adr` profile, use `okf id next` for allocation, and follow `agents/skills/exec-plan/ADR.md` for timestamps, bundle log, and strict validation. No ADR is adopted merely by creating this plan. Populate Progress, evidence, and Outcomes as implementation proceeds, and record one provenance revision for that implementation session.


## Concrete Steps


Run commands from the repository root. Use the existing configured Haskell development environment; if GHC/Cabal are unavailable, enter the repository's `nix develop` shell without inspecting its store. These are implementation-time commands and expected results, not checks already executed during plan creation.

```bash
cabal build keiro-dsl:exe:keiro-dsl
cabal test keiro-dsl:keiro-dsl-test --test-options='--match upgrade'
bash keiro-dsl/test/upgrade-test.sh
```

After milestone 3, the following read-only demonstration must report ordered 1→2→3→4→5 steps and no manual obligations for the existing context-only fixture. It must leave the input unchanged. The empty body's lack of edits is specifically reported as checked, not assumed.

```bash
cabal run -v0 keiro-dsl -- upgrade keiro-dsl/test/fixtures/language-v1.keiro --to 5 --dry-run --format json
cabal run -v0 keiro-dsl -- upgrade keiro-dsl/test/fixtures/language-v1.keiro --to 5 --check
```

Expected statuses are `ready` with exit 0 for dry-run and pending-upgrade exit 1 for check. After milestone 4, use a disposable copy for the write demonstration:

```bash
upgrade_demo_dir=$(mktemp -d)
cp keiro-dsl/test/fixtures/language-v1.keiro "$upgrade_demo_dir/service.keiro"
cabal run -v0 keiro-dsl -- upgrade "$upgrade_demo_dir/service.keiro" --to 5 --write
cabal run -v0 keiro-dsl -- check "$upgrade_demo_dir/service.keiro"
cabal run -v0 keiro-dsl -- upgrade "$upgrade_demo_dir/service.keiro" --to 5 --check
cabal run -v0 keiro-dsl -- upgrade "$upgrade_demo_dir/service.keiro" --to 5 --write
```

Expect successful write, `OK`, check exit 0, then `unchanged` with no new transaction. Keep the temporary directory if recovery evidence is needed. The CLI test script must create richer workspace and fault-injection cases itself and print a concise success line describing atomic preflight, rollback, and recovery.

```bash
cabal run -v0 keiro-dsl -- upgrade fleet --to 5 --format json
cabal test keiro-dsl:tests
bash keiro-dsl/test/diff-test.sh
just dsl-api-boundaries
just conformance-corpus-policy
git diff --check
```

The live fleet command may return 2 for real inventory blockers; inspect its structured records instead of treating that as a test infrastructure failure. Automated fake-registry tests establish deterministic success and failure behavior. Full tests and policy checks must exit 0; record counts and any environmental blockers in this plan.


## Validation and Acceptance


Acceptance requires a compatible Language-1 fixture to traverse every published edge to stable, validate at every intermediate version, and become byte-stable on a repeated invocation. Candidate-6 planning requires both explicit target and candidate opt-in. Unknown future languages and downgrades must fail before writes. Existing published source fixtures continue parsing and producing their previous outputs.

A legacy transition fixture must show explicit Hole ownership in its proposed 1→2 rewrite, with unresolved application/replay consequences blocking write. A generated-ID fixture crossing 2→3 and a contract-TypeID fixture crossing 3→4 must surface changed admission. A legacy Strong read model crossing 4→5 must produce an actionable projection/freshness obligation and never silently select immediate freshness. Goldens must pin exact source edits, profile evidence, compatibility findings, and obligation codes for every registered edge, including 5→6 candidate behavior.

Dry-run and check are observationally read-only: compare directory inventories, file bytes, and permissions before/after. Single-file and workspace results contain the same substantive checks. A workspace with one invalid member, unresolved reference, stale manifest, or failed intermediate step leaves all members untouched. A successfully transformed workspace contains only one effective language at each composed validation boundary. Fault injection proves restoration after every partial replacement, and interrupted-process tests prove explicit recovery without overwriting subsequent user edits.

Fleet tests prove canonical identities, dependency-row deduplication, honest `no-sources` and unknown-role outcomes, complete per-project failure reporting, and zero cross-repository writes. Neither a clean source diff nor a registry entry may be reported as historical replay proof or production readiness. Reports distinguish source transformation validation from any separate adoption evidence demanded by ADR-47.


## Idempotence and Recovery


Planning is deterministic for fixed input bytes, target, registry, and tool build. Repeating an explicit-target upgrade after success returns `unchanged`, retains exact bytes, and creates no backup. A blocked plan cannot be converted into a prepared transaction. New edits require a fresh plan; reports are not authority to replay stale offsets.

Recover with `keiro-dsl upgrade recover INPUT --rollback` when an active journal exists. Inspect the transaction report before restarting. Recovery restores all known changed files or reports exactly which unexpected files prevent safe restoration. Keep original backups and the journal until the operator has reviewed the result; never remove them automatically after a failed rollback. An interrupted transaction blocks further upgrades of that input, including manifests overlapping its member paths. Track active member ownership across local transaction roots or detect overlapping markers before allowing writes; a manifest-local lock alone cannot protect a shared member.

Manual obligations are resolved through reviewed source/application changes and a fresh planning run. Do not partially write the earlier safe steps of a blocked multi-step request. Operators may separately request an earlier target as its own validated transaction. Published compatibility corpus upgrades, real dependent writes, deployments, and retained-history migrations are separate explicit actions.


## Interfaces and Dependencies


Expose a small `Keiro.Dsl.Upgrade` facade from `keiro-dsl/keiro-dsl.cabal`; keep implementation modules private unless a concrete public caller needs them. Reuse existing `text`, `bytestring`, `containers`, `aeson`, `directory`, `filepath`, and process facilities. Do not add a Mori library dependency or change package bounds as incidental work. If implementation needs an additional filesystem primitive, first locate its library through Mori, inspect its source, and verify any newly chosen bound against the authoritative package registry and upstream tags.

The facade should provide these responsibilities; define supporting records in `Keiro.Dsl.Upgrade.Types`, using the repository's concise record-label style. `UpgradeInput` is a complete byte snapshot of a single source or manifest plus members, rooted at a verified path. `UpgradeRequest` carries target and candidate policy. `UpgradePlan` carries all proposals and reports, including blocked outcomes. `PreparedUpgrade` is opaque and can only be constructed from a ready plan after fresh filesystem preflight. `UpgradeFailure` carries structured input, validation, stale-input, transaction, or recovery failures.

```haskell
planUpgrade :: UpgradeRequest -> UpgradeInput -> UpgradePlan
prepareUpgrade :: UpgradePlan -> IO (Either UpgradeFailure PreparedUpgrade)
applyUpgrade :: PreparedUpgrade -> IO (Either UpgradeFailure UpgradeReport)
recoverUpgrade :: FilePath -> IO (Either UpgradeFailure RecoveryReport)
```

Keep transformation and in-memory checking pure where possible. If the existing `ContentSource` loader requires IO, perform loading/composition in a narrowly scoped adapter and expose the equivalent pure checked snapshot to `planUpgrade`; do not hide filesystem reads inside a nominally pure function. Tests inject filesystem operations into internal preparation/application functions without exposing fault controls as production CLI flags.

`TextEdit` records source path, start/end positions, expected original text, replacement, and step/reason. `UpgradeStep` records exact predecessor/successor, stable identifier, and a total assessment that returns edits, findings, and obligations. Registry coverage tests require an explicit disposition for every edge; a newly registered language cannot acquire an automatic header-bump fallback. Reports use stable schema identifiers and permit additive unknown fields for forward-compatible readers. Retain whole original bytes for stale-input comparison and recovery, even when report summaries also contain digests.

The fleet adapter receives a process runner and source enumerator for testing. Its production implementation only invokes Mori's inspected JSON commands and Git's tracked-file enumeration. Canonical project identity is authoritative; absolute checkout paths are local operational facts, not durable cross-repository references.

Creation note (2026-09-21): feasibility evaluated against current source, registry, workspace/diff APIs, relevant ADRs, and Mori's live inventory/JSON implementation. No implementation or Haskell test execution is claimed by this planning document.

Revision note (2026-09-21): linked the intention created with `mina ci --json` at the user's request; implementation scope is unchanged.
