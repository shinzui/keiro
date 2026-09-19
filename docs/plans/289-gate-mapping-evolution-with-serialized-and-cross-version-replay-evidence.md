---
id: 289
slug: gate-mapping-evolution-with-serialized-and-cross-version-replay-evidence
title: "Gate mapping evolution with serialized and cross-version replay evidence"
kind: exec-plan
intention: "intention_01m2xtfnt7ewg9ptt7ztf0tary"
created_at: 2026-09-19T21:46:12Z
master_plan: "docs/masterplans/44-add-checked-value-mappings-while-preserving-stream-and-workflow-replay-across-refactors.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-19T21:46:12Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-19T21:52:45Z
      mode: "update"
      note: "Link Mina intention and clarify retained-history, strict replay, audit-tail, and rollout obligations."
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-19T22:13:45Z
      mode: "update"
      note: "Rescope M2 as delta over plan 147 with shared normalization law; derive evidence inventory from MappedConsequence; pin replay verdicts."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-19T22:32:09Z
      mode: "update"
      note: "Whole-service inventory now covers direct, transition, process and Hole changes; process continuation evidence and recurring verify gate specified."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-19T22:48:17Z
      mode: "implement"
      note: "Implement Milestone 1 compatibility report and independent inventory contract."
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-19T22:13:44Z
      verdict: "changes-requested"
      note: "M2 ignores existing plan-147 forward/replay check; required-evidence inventory hand-selected rather than derived from MappedConsequence; no shared normalization law for quotient codecs."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-19T22:32:09Z
      verdict: "approved"
      note: "Whole-service inventory now covers direct, transition, process and Hole changes; process continuation evidence and recurring verify gate specified."
---

# Gate mapping evolution with serialized and cross-version replay evidence


This ExecPlan is a living document. Keep its execution sections current; distill durable decisions into ADRs during implementation. This document authorizes planned implementation scope, not production migration or a claim of completed replay proof.


## Purpose / Big Picture


Build the reusable pre-1.0 compatibility gate for DSL and API evolution, rejecting refactors which still decode but change aggregate replay, process-manager recovery, or workflow meaning. A developer must be able to demonstrate both a harmless Haskell refactor passing and a lossy mapping or changed workflow result failing before adopting the new features. This plan establishes reusable tests and an evidence format; it does not promise a static proof of arbitrary application code.


## Progress


- [x] (2026-09-19T22:48:01Z) Milestone 1: Defined the compatibility report and capture contract in `Keiro.Test.ReplayCompatibility`; 9 focused examples pass.
- [ ] Milestone 2: Exercise serialized aggregate replay and meaningful refactors.
- [ ] Milestone 3: Exercise workflow refactors without repeating effects.
- [ ] Milestone 4: Compare process-manager redelivery and partial recovery across builds.
- [ ] Milestone 5: Enforce complete evidence in routine verification and document the limits.


## Surprises & Discoveries


None recorded during implementation yet.

The evidence inventory cannot be inferred safely from report rows, but the same obligation can arise from several independent sources. The implementation therefore requires one explicit contribution from every v1 source and permits repeated case IDs only when their complete definitions agree. Evidence: the focused test rejects old-only, direct-ID, transition-only, process-only, and application-Hole omissions while a complete report passes.

The 1.0 review found that `MappedConsequence` has no process-reaction or direct-nominal-only cases and `replayImpactServices` iterates aggregates. Deriving the complete report inventory from mapped changes alone can omit an incompatible process or direct-ID refactor. The runtime already tests same-build reaction recovery; this plan adds cross-build evidence and omission detection.


## Decision Log


2026-09-19: Require serialized same-version tests and independent baseline/candidate historical interpretation. Candidate snapshot/full agreement is a separate check, because both paths can agree on a newly wrong meaning. The user requires streams and workflows to retain replayability after refactors. Tests and explicit compatibility boundaries enforce that requirement without claiming arbitrary Haskell behavior is statically provable.

2026-09-19 (validation review): Scope Milestone 2 as a delta over the existing plan-147 forward/replay check, and own one normalization law shared by the set, base16, and date features. Generate new harness assertions only where a constructor can have non-canonical wire forms, so published-language generated bytes do not drift.

2026-09-19 (validation review): Derive the required-evidence inventory from `MappedConsequence`, including workqueue history and projection rebuild. A hand-selected surface list would make `--require-all` vacuous for any surface the author forgot.

2026-09-19 (validation review): Pin the replay-verdict authority with diff-level regressions, because `ReplayImpact` converts wire-token equality into a `replay-neutral` verdict that lets a deploy skip its audit.


2026-09-19 (1.0 review): Extend the existing layered replay gate to complete old/new inventories and process recovery, as required by ADR-47. Keep wire identity, aggregate replay impact, and whole-service compatibility separate. Routine `verify` must exercise omission and semantic-drift mutations so this protection survives future refactors.

2026-09-19 (implementation): Represent each inventory input as applicable, not applicable with a reason, or unverified. Require all seven v1 inputs and bind the inventory plus both reports to one exact build pair. This makes absence explicit without forcing unrelated packages into `keiro-test-support`, and leaves DSL/runtime adapters responsible for translating their own findings into the stable contract.


## Outcomes & Retrospective


Not implemented. Record results and remaining adoption obligations here; plan creation is not implementation completion.


## Context and Orientation


This plan has no hard dependencies. It defines the compatibility evidence consumed by the five feature plans and the final adoption rehearsal.

Research baseline is Keiro commit `98f07213` on 2026-09-19. Recheck the working tree before implementation. `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, `Parser/Mapped.hs`, `PrettyPrint.hs`, and `TypeGraph.hs` own syntax and its checked meaning. `AggregateType.hs` and `ConsumerTypePlan.hs` select supported Haskell types. `MappedCodecPlan.hs` and `Scaffold.hs` lower codecs and generated modules; `StructuralConformance.hs`, `Harness.hs`, and `ServiceHarness.hs` produce checks. Paths abbreviated after the first module in this paragraph are relative to `keiro-dsl/src/Keiro/Dsl/`.

The same directory's `MappedDiff.hs`, `SemanticImpact.hs`, `ReplayImpact.hs`, `FoldFingerprint.hs`, `CanonicalEncoding.hs`, `Coverage.hs`, and `ScaffoldRecord.hs` connect recursive type changes to persisted surfaces, stable identities, and generated provenance. `LanguageVersion.hs` selects capabilities; do not hard-code a guessed next language number. `keiro-core/src/Keiro/Codec/Structural.hs` and `Nominal.hs` contain consumer binding contracts. `keiro-core/src/Keiro/EventStream/Validate.hs` constructs validated runnable streams. `keiro/src/Keiro/ReplayAudit.hs` checks candidate replay and candidate snapshot/full agreement, not automatic old/new semantic equivalence.

A codec converts domain values to stored JSON and back. A total binding must satisfy both domain-to-shape-to-domain and shape-to-domain-to-shape identity. A fingerprint detects declared changes; it does not make a breaking change safe. A golden is committed historical input with provenance, never regenerated from the candidate to make a failure disappear.

The governing local decisions are [ADR-12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md), which assigns private-event JSON authority to checked declarations and requires total domain/shape bindings; [ADR-3](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md), which treats snapshots as disposable caches; [ADR-4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md), which separates single-spec checks, evolution findings, runtime validation, historical codec tests, and real-history replay; and [ADR-18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md), which freezes released behavior and canonical fingerprint encodings. [ADR-46](../adr/0046-nominal-declarations-are-structural-leaves-with-keiro-owned-admission.md) preserves nominal admission inside structural values, keyed maps, and declared public IDs. These decisions remain binding; the implementation must update their relevant explanations when adding a new supported surface.

Keiki's decisions `mori://shinzui/keiki/okf/adrs/concepts/ADR-2`, `mori://shinzui/keiki/okf/adrs/concepts/ADR-3`, and `mori://shinzui/keiki/okf/adrs/concepts/ADR-5` respectively require forward/replay agreement, conservative proof gates, and stable wire identity independent of Haskell names. A transducer is the pure machine that selects a transition, updates registers, and emits events. Replay reconstructs its input from the first event of a transition; subsequent events check the expected tail. An exact projection domain is a symbolic description of every possible concrete key, with reconstruction for every admitted key. Omitting real keys can manufacture false proofs of impossibility. Never weaken validation or invent exact evidence to get a fixture through.

Workflow persistence is a separate boundary. `keiro/src/Keiro/Workflow.hs` stores step results using application Aeson instances and returns the decoded stored value even on fresh execution. `keiro/src/Keiro/Workflow/Types.hs`, `Journal.hs`, and `Snapshot.hs` own journal envelopes, append/index behavior, and cache seeds. These are not automatically covered by generated private-event codecs. Preserve workflow name, instance identity, generation, step/await/child/timer keys, patch decisions, carried seeds, and result decoding. [ADR-5](../adr/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md) requires generation-scoped index fallback for await misses. [ADR-24](../adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md) freezes deterministic identity derivations. Renaming a step intentionally creates a new action; it is not a safe decoder migration. Keep old result readers and patch branches for retained histories. `continueAsNew` does not erase the obligation to interpret retained old generations or decode their carried seed.

Three protections already exist and this plan extends them; it must not reimplement or weaken them. First, `forwardReplayDecl` in `keiro-dsl/src/Keiro/Dsl/Harness.hs` (plan 147) generates, for each live event-emitting transition, a check that runs the command forward, passes the emitted chain through the generated `encode`/`parse` event codec, replays it with `applyEventsEither`, and compares the final vertex and every declared register. The same module generates a `parse (encode e) == Right e` golden round trip per event. These cover the law `decode (encode v) == v` for sampled domain values at the JSON value level. They do not cover non-canonical wire input, byte-level envelope serialization through the store, multi-transition prefixes, or any comparison between two builds. Second, `diffDeclaration` in `keiro-dsl/src/Keiro/Dsl/MappedDiff.hs` already emits `MappedModeCrossed` when a declaration crosses the structural/opaque boundary. Third, `decodeStored` in `keiro/src/Keiro/Workflow.hs` already throws `WorkflowStepDecodeError` when a persisted step result fails to decode, so a changed decoder is never treated as a missing step today; Milestone 3's decode-failure case is a regression test that pins this behavior.

The aggregate replay verdict combines wire fingerprints, direct nominal surfaces, fold/initial surfaces, and transitions; wire-token equality is not the complete decision. `wireFingerprint`, `wireExpr`, and `nominalWireToken` in `keiro-dsl/src/Keiro/Dsl/TypeGraph.hs` render a declaration's wire form; `keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs` compares them to choose `replay-neutral` or `replay-affected`; `keiro/src/Keiro/ReplayAudit.hs` documents that a replay-neutral deploy touches no data. `MappedConsequence` in `keiro-dsl/src/Keiro/Dsl/SemanticImpact.hs` enumerates the durable consequences of a mapped change: `MappedPrivateEventHistory`, `MappedSnapshotHydration`, `MappedWorkqueueHistory`, `MappedQueryApi`, `MappedRouterSelectionBuild`, `MappedRouterSelectionCoordinationReview`, `MappedProjectionHandlerReview`, and `MappedProjectionRebuild`.


Process managers need an independent comparison. `keiro/src/Keiro/ProcessManager/Reaction.hs` validates an existing accepted saga witness, skips timer SQL, and recomputes target follow-ups from the decoded source event. The old `keiro/src/Keiro/ProcessManager.hs` and reaction runner use different target identity families. `keiro-dsl/src/Keiro/Dsl/ProcessReaction.hs` records coordination fingerprints and `Diff.hs` reports process input, timer, fan-out, and identity changes. Existing PostgreSQL tests are in `keiro/test/Main.hs` under `Keiro.ProcessManager.Reaction`; `just process-reaction-proof` runs the generated reaction mutation and hydration probes. [ADR-41](../adr/0041-process-manager-reactions-use-accepted-witnesses-and-target-keyed-recovery.md) requires exact witness recovery and keeps silent outcomes at-least-once. [ADR-47](../adr/0047-dsl-retirement-requires-complete-retained-history-evidence.md) requires complete historical evidence before implementation retirement.


## Plan of Work


### Milestone 1 — Define the compatibility report and capture contract


Add `keiro-test-support/src/Keiro/Test/ReplayCompatibility.hs` and expose it in `keiro-test-support/keiro-test-support.cabal`. Define a versioned JSON evidence envelope with baseline/candidate source revisions, language/runtime profiles, dependency-lock or build-plan hashes, input corpus hash, per-stream high-water marks, observation-contract version, selected persisted surfaces, and case results. Separate historical-read, semantic-equivalence, old-reader/new-writer, snapshot, process-manager, and workflow verdicts as passed, failed, or unverified. The release predicate must reject required unverified or missing cases; test an empty report and unequal corpus identifiers as failures. Required cases come from the union of baseline and candidate persisted-surface inventories, all relevant ordinary diff compatibility findings, aggregate replay impacts, `MappedConsequence` values, process-reaction facts, and explicit application-owned workflow/Hole declarations. Include old-only removed surfaces, direct nominal changes, transition/initial changes with no mapped declarations, and source/dependency changes behind unchanged binding or codec names. A checked source inventory enumerates declared processes; application-owned declarations supplement it rather than replacing it. Unknown impact requires a full applicable inventory and comparison or an unverified result; it must never shrink the inventory. Capture the inventory as a versioned, build-pair-bound input and make the comparator verify it independently of whichever case rows a candidate report supplies. Include queued payloads and rebuildable projections wherever their actual diff consequences require them, keeping query build-only checks distinct. Negative cases must omit an old-only surface, a direct-ID case, a transition-only case, a process-only case, and an unchanged-name Hole edit; every omission fails even when the remaining rows pass. Avoid linking old and new application types in one executable: separate baseline/candidate capture processes emit this stable format. State observations must cover all durable registers and control state; a renamed type gets an explicit lossless observation adapter. Include selected follow-up commands and resulting event identities where state equivalence alone could hide changed behavior. Pin the clock, randomness, external responses, and failure schedule for baseline/candidate captures. Preserve actual historical IDs and compare deterministic IDs exactly; explicitly separate genuinely fresh random allocations from durable identity rather than normalizing away a mismatch. Capture processes must report unsupported nondeterminism as unverified. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 2 — Exercise serialized aggregate replay and meaningful refactors


Build on the existing plan-147 forward/replay check described in Context; do not replace it. Extend `keiro-dsl/src/Keiro/Dsl/Harness.hs`, `ServiceHarness.hs`, and the existing `keiro-dsl/test/conformance-replay` suite with what that check lacks. Add a reusable normalization law for codecs whose decoder accepts more wire spellings than the encoder writes: for each declared non-canonical wire form `w`, `encode (decode w)` is canonical, `decode (encode (decode w)) == decode w`, and replaying a chain that contains `w` reaches the same vertex and registers as replaying the chain with `w` replaced by its canonical form. Plans 291, 292, and 293 supply the `w` cases; this plan owns the law and its test helper. Generate the new assertions only for declarations that use a constructor able to have non-canonical wire forms, so harness output for every existing fixture and every published language stays byte-identical and `just conformance-corpus-policy` reports no drift. Add byte-level serialization through the actual event envelope in the PostgreSQL-backed suite, since the generated check stops at the JSON value. Capture complete prefixes ending after each transition output word and compare baseline/candidate observations; test truncated multi-event words separately as failures. Add source-module/selector moves with pinned wire keys as passing refactors. Add negative mutations for codec normalization, changed writes despite successful decoding, retired inverse edge, and lost head data. Use declared stable behavior identities or semantic observations rather than Keiki edge indices, which change with declaration order. Connect provenance-changing declarations to affected roots through `SemanticImpact.hs`, `MappedDiff.hs`, and `ReplayImpact.hs`; opaque or hand-owned behavior remains unverified rather than neutral. Add a diff-level regression that pins the verdict authority: an opaque-to-structural change must yield `MappedModeCrossed` and a `replay-affected` verdict, a change to an opaque codec version must be `replay-affected`, and a selector-only rename with otherwise unchanged semantic surfaces must be `replay-neutral`. Feature plans add the analogous case for their own policy or domain change; none may be reported `replay-neutral`. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 3 — Exercise workflow refactors without repeating effects


Add `keiro/test/WorkflowReplayCompatibilitySpec.hs`, register it from `keiro/test/Main.hs` and Cabal, and use isolated PostgreSQL fixtures. Create a baseline workflow, persist it at each representative suspension point, then resume the candidate with actions instrumented to record unexpected execution. Test ordinary steps, awaits, timer/child completions, recorded patch sets, rotation seeds, and old generations. A pure module rename keeps all durable keys and does not rerun recorded actions. A changed decoder under the same key fails with `WorkflowStepDecodeError`, not a cache miss; this is existing `decodeStored` behavior, so the test pins it against regression and must fail if anyone converts the error into a rerun. Also mutate a result decoder so it succeeds but changes the returned value or subsequent action; the semantic comparison must fail even without `WorkflowStepDecodeError`. An unguarded renamed/reordered step is a failed semantic comparison. A patch test proves existing generations follow their recorded old branch while new generations select the new branch. Preserve the await step-index fallback under incomplete snapshots and test snapshot-free replay. Workflow actions remain at-least-once on a genuine action/append crash; do not claim exactly-once behavior. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 4 — Compare process-manager redelivery and partial recovery across builds


Add `keiro/test/ProcessManagerReplayCompatibilitySpec.hs` and register it from Main and Cabal, reusing the isolated PostgreSQL fixture support and the existing reaction tests. Capture a baseline source delivery before saga acceptance, after acceptance but before target dispatch, and after each partial target dispatch. Restore each capture separately for baseline and candidate runs. Compare saga state and accepted witness identity, target stream/command payload/command identity and per-target occurrence, persisted target results, timer identity/payload/status, and worker acknowledgement/retry outcomes. Baseline continuations provide the expected trace; pure source refactors reproduce it without extra durable target appends or acceptance-only timer effects.

Test both unchanged legacy positional dispatch and unchanged reaction target-keyed dispatch. A migration between them must fail refactor compatibility, even if the saga codec and final state are identical. Add mutations for same-target command reorder or payload change, manager/correlation rename, an input decoder changing interpretation under an unchanged name, a pending timer decoder becoming narrower, and an undecodable recovered witness. The witness case must fail explicitly before fan-out; a version bump or aggregate-neutral verdict cannot waive any failure. Preserve the existing at-least-once semantics of silent/eventless decisions and action/append crash windows; record expected retries rather than asserting exactly-once execution. Run `keiro:keiro-test` and `just process-reaction-proof`; acceptance is identical cross-build continuation traces for the positive cases and the first divergent durable coordinate for each mutation.


### Milestone 5 — Enforce evidence and document the limits


Add `scripts/check-replay-compatibility.py` as a report validator and comparator, with deterministic fixture reports and a small Python unittest suite under `scripts/tests/test_replay_compatibility.py`. Its CLI is `--baseline FILE --candidate FILE --inventory FILE --require-all`, returning 0 only for complete matching evidence and 1 for mismatch, missing required evidence, or unsupported contract versions. Define explicit matched stream/prefix sets and comparison semantics, so two empty observations cannot pass. Keep database access and application capture in consumer-owned tools. Add a `replay-compatibility` recipe in `justfile`, make the existing `verify` recipe depend on it, and run the comparator plus its negative-test suite in that recipe, document it in `docs/guides/evolution-and-replayability.md`, and explain that finite evidence is scoped evidence, not an arbitrary-refactor theorem. Assert that a pure Haskell binding/Hole or dependency edit with unchanged DSL still requires the declared application evidence; do not let a wire-neutral result skip it. Freeze report v1 goldens and add negative tests for an omitted register, omitted workflow surface, stale build identity, and a changed corpus hash. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


## Concrete Steps


Run from the repository root, using the existing Nix development environment. PostgreSQL-backed tests use `Keiro.Test.Postgres` isolated migrated databases, not production credentials.

```bash
nix develop -c cabal test keiro-dsl:keiro-dsl-test
nix develop -c cabal test keiro-dsl:tests
nix develop -c cabal test keiro:keiro-test
nix develop -c just process-reaction-proof
```

After Milestone 5 adds the recipe, run its report and mutation checks:

```bash
nix develop -c just replay-compatibility
```

The expected result is exit 0 with all assertions passing, including the newly named tests below; record actual counts and failure diagnostics during implementation. Add new generated fixtures using `keiro-dsl/test/README.md`, registering their Cabal components and corpus provenance. Regenerate through the public CLI driver:

```bash
nix develop -c cabal run -v0 keiro-dsl-corpus-regen -- regenerate
```

Review generated diffs without modifying historical input evidence. On a committed clean corpus baseline run:

```bash
nix develop -c just conformance-corpus-policy
```

It must report no regeneration drift; this command deliberately refuses a dirty corpus. Use an isolated clean checkout of the implementation commit when unrelated work prevents that check. Do not remove other work to satisfy it. These commands are implementation instructions, not claims of execution during plan authoring.


## Validation and Acceptance


The new script must pass a baseline/candidate module-rename fixture and fail every listed mutation with a surface, stream or workflow identity, and first divergent prefix/key. Run `python3 -m unittest discover -s scripts/tests -p test_replay_compatibility.py`. All feature acceptance invokes the same verdict semantics; no feature invents its own compatibility waiver. Run `nix develop -c just replay-compatibility` after adding the recipe and verify that the existing `just verify` dependency list invokes it. Process-only, direct-ID-only, removed-surface, and undeclared Hole changes must not pass with an empty mapped diff. A report claiming no affected history must carry the independently checked inventory and explicit applicability result.

For every admitted value, generated encoding followed by decoding must recover the same domain value, and the generated binding must satisfy both inverse laws. Exercise forward execution followed by actual event-envelope serialization, decoding, and strict replay; compare control state and all durable registers at every completed transition. Include multi-event output, replay-only transitions, and a negative head-information-loss case. A same-version in-memory replay test alone does not pass this requirement.

For each affected persisted surface, run the compatibility gate from Plan 289. Preserve genuine old bytes, tags, versions, and readers. Compare baseline and candidate interpretations under the same versioned, non-lossy observation contract; investigate the first divergent prefix. Test old-reader/new-writer compatibility separately. A narrowed domain, altered normalization, or opaque-to-checked conversion is never automatically replay-neutral. Keep historical adapters total for retained history; if history cannot be represented without loss, retain the old representation/handler and refuse adoption.

Reject unsupported symbolic operations during checking. Exact-domain evidence must include concrete-owner membership and admitted-key reconstruction, not merely a successful solver model. Unknown required evidence stays unverified and blocks the preservation claim at the applicable feature, publication, adoption, or retirement gate. Published-language acceptance, generated bytes, and frozen identities remain unchanged unless an explicit migration is part of a separate reviewed change. Any opaque nested boundary keeps its unverified status; wrapping it in a checked container does not certify it.

Workflow adoption must additionally preserve journal semantics with actual application codecs. Run old journal prefixes through candidate continuation in an isolated test environment with recorded effects; do not execute production side effects in an audit. Persisted-result decode failure must fail clearly, never be treated as a missing step and rerun. Pure refactors must retain stable names and existing results without extra actions. No snapshot invalidation, token bump, or green finite fixture suite alone proves compatibility with all stored history.


A pure refactor must preserve wire kinds/keys, version dispatch, canonical identities, initial-state meaning, and historical readers. An intentional semantic change is not relabeled a refactor: introduce explicit event versions/upcasters or retained replay-only behavior, and preserve the old interpretation for old history. Never skip an undecodable event, drop a failed workflow result, relax Keiki validation, or rewrite historical bytes to obtain a green result. Replay-only guard remedies do not repair a codec that has already rejected or changed the event.

Evidence is tied to the audited high-water marks. Concurrent writes beyond those marks require a tail audit or a controlled writer cutover before adoption. An old-reader/new-writer failure requires a documented staged rollout that keeps incompatible writes disabled until old readers are gone; it is not historical-read success. The report must retain the failed direction and the explicit rollout precondition, and automatic simultaneous-version compatibility must remain refused.

## Idempotence and Recovery


All generation and tests run in the repository checkout or an isolated fixture database. Regenerate replaceable modules through the public corpus driver; preserve create-once bindings and historical fixtures. Retry failures after fixing the owning implementation, never by accepting new historical goldens. Do not rewrite production events, journal rows, IDs, step keys, or deterministic seeds. Keep new authoring capability promotion blocked until its evidence passes. Candidate status does not prevent durable writes: any package release containing a new wire policy requires committed compatibility vectors and freezes that policy identity. Removing an already-shipped candidate capability must preserve its historical read/replay path or be blocked. Before new-format writes, rollback can retain the previous readers; after incompatible writes, use a documented forward repair or retain compatible readers rather than assuming a binary downgrade is safe. A production migration, release, or cross-repository rollout is a separate authorized action.


## Interfaces and Dependencies


The new report stores canonical JSON observations with an explicit field inventory and observation-contract ID. Observations use injective representations for the durable facts compared; hashes may identify artifacts but cannot replace the semantic comparison. Workflow traces distinguish replayed existing steps from authorized new steps and side-effect attempts. Process traces separately identify saga witnesses, target occurrences and payloads, timer state, and retries. The required inventory is an input to comparison, not a list inferred solely from successful rows. The comparator consumes two immutable capture reports plus the independently generated build-pair inventory and writes no database state. Reject mismatched inventory identity, incomplete old/new surface coverage, duplicated cases, or unsupported inventory versions.

Use the existing checked graph and total folds rather than separate per-generator allowlists. New checked constructors must be handled exhaustively by codecs, nullability, dependency traversal, fingerprints, diff, coverage, scaffolding, deterministic fixtures, and every admitted use-site lowerer. A clean check must imply complete generation. Keep consumer binding signatures total; JSON validation happens before binding conversion. Stable wire identity is independent of source module names, selectors, constructor presentation, and dependency traversal order.

Before using dependency APIs run `mori registry list`, `mori registry search <package>`, `mori registry show <qualified-project> --full`, and `mori registry docs <qualified-project>`, then read the located source. Relevant projects are `mori://shinzui/keiki`, `mori://haskell/aeson`, and consumer `mori://shinzui/rei`. If changing a dependency bound, verify the authoritative package registry and upstream release tags first; local source is not release evidence. No Keiki dependency change is assumed. If required evidence cannot be expressed by the released API, stop capability promotion and coordinate an explicit upstream change, never substitute a dishonest witness.

Revision note (2026-09-19): Linked the Mina-created intention and clarified retained-reader, strict-failure, audit-tail, and rolling-reader obligations during authoring review. No implementation or historical audit has run.

Revision note (2026-09-19, validation review): Added the existing-coverage baseline (plan-147 harness check, `MappedModeCrossed`, fail-closed `decodeStored`) and the wire-token verdict authority to Context. Milestone 1 now derives the required-evidence inventory from `MappedConsequence`. Milestone 2 is rescoped as a delta that owns the shared normalization law, keeps published-language harness output byte-identical, and pins replay verdicts with diff-level regressions. Milestone 3 records that the decode-failure case pins existing behavior. No implementation has run.

Revision note (2026-09-19, 1.0 review): Expanded required evidence beyond mapped changes, added cross-build process-manager recovery and routine verification, and corrected wire-identity and candidate-release assumptions. See ADR-47. No implementation or historical audit has run.
