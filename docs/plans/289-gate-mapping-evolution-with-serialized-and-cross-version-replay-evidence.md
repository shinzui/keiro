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
---

# Gate mapping evolution with serialized and cross-version replay evidence


This ExecPlan is a living document. Keep its execution sections current; distill durable decisions into ADRs during implementation. This document authorizes planned implementation scope, not production migration or a claim of completed replay proof.


## Purpose / Big Picture


Build an executable gate that rejects mapping refactors which still decode but change historical stream or workflow meaning. A developer must be able to demonstrate both a harmless Haskell refactor passing and a lossy mapping or changed workflow result failing before adopting the new features. This plan establishes reusable tests and an evidence format; it does not promise a static proof of arbitrary application code.


## Progress


- [ ] Milestone 1: Define the compatibility report and capture contract.
- [ ] Milestone 2: Exercise serialized aggregate replay and meaningful refactors.
- [ ] Milestone 3: Exercise workflow refactors without repeating effects.
- [ ] Milestone 4: Enforce evidence and document the limits.


## Surprises & Discoveries


None recorded during implementation yet.


## Decision Log


2026-09-19: Require serialized same-version tests and independent baseline/candidate historical interpretation. Candidate snapshot/full agreement is a separate check, because both paths can agree on a newly wrong meaning. The user requires streams and workflows to retain replayability after refactors. Tests and explicit compatibility boundaries enforce that requirement without claiming arbitrary Haskell behavior is statically provable.


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


## Plan of Work


### Milestone 1 — Define the compatibility report and capture contract


Add `keiro-test-support/src/Keiro/Test/ReplayCompatibility.hs` and expose it in `keiro-test-support/keiro-test-support.cabal`. Define a versioned JSON evidence envelope with baseline/candidate source revisions, language/runtime profiles, dependency-lock or build-plan hashes, input corpus hash, per-stream high-water marks, observation-contract version, selected persisted surfaces, and case results. Separate historical-read, semantic-equivalence, old-reader/new-writer, snapshot, and workflow verdicts as passed, failed, or unverified. The release predicate must reject required unverified or missing cases; test an empty report and unequal corpus identifiers as failures. Avoid linking old and new application types in one executable: separate baseline/candidate capture processes emit this stable format. State observations must cover all durable registers and control state; a renamed type gets an explicit lossless observation adapter. Include selected follow-up commands and resulting event identities where state equivalence alone could hide changed behavior. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 2 — Exercise serialized aggregate replay and meaningful refactors


Extend `keiro-dsl/src/Keiro/Dsl/Harness.hs`, `ServiceHarness.hs`, and the existing `keiro-dsl/test/conformance-replay` suite with wire-round-trip replay assertions. Capture complete prefixes ending after each transition output word and compare baseline/candidate observations; test truncated multi-event words separately as failures. Add source-module/selector moves with pinned wire keys as passing refactors. Add negative mutations for codec normalization, changed writes despite successful decoding, retired inverse edge, and lost head data. Use declared stable behavior identities or semantic observations rather than Keiki edge indices, which change with declaration order. Connect provenance-changing declarations to affected roots through `SemanticImpact.hs`, `MappedDiff.hs`, and `ReplayImpact.hs`; opaque or hand-owned behavior remains unverified rather than neutral. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 3 — Exercise workflow refactors without repeating effects


Add `keiro/test/WorkflowReplayCompatibilitySpec.hs`, register it from `keiro/test/Main.hs` and Cabal, and use isolated PostgreSQL fixtures. Create a baseline workflow, persist it at each representative suspension point, then resume the candidate with actions instrumented to record unexpected execution. Test ordinary steps, awaits, timer/child completions, recorded patch sets, rotation seeds, and old generations. A pure module rename keeps all durable keys and does not rerun recorded actions. A changed decoder under the same key fails with a decode error, not a cache miss; an unguarded renamed/reordered step is a failed semantic comparison. A patch test proves existing generations follow their recorded old branch while new generations select the new branch. Preserve the await step-index fallback under incomplete snapshots and test snapshot-free replay. Workflow actions remain at-least-once on a genuine action/append crash; do not claim exactly-once behavior. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 4 — Enforce evidence and document the limits


Add `scripts/check-replay-compatibility.py` as a report validator and comparator, with deterministic fixture reports and a small Python unittest suite under `scripts/tests/test_replay_compatibility.py`. Its CLI is `--baseline FILE --candidate FILE --require-all`, returning 0 only for complete matching evidence and 1 for mismatch, missing required evidence, or unsupported contract versions. Define explicit matched stream/prefix sets and comparison semantics, so two empty observations cannot pass. Keep database access and application capture in consumer-owned tools. Integrate the fixture gate into `justfile`, document it in `docs/guides/evolution-and-replayability.md`, and explain that finite evidence is scoped evidence, not an arbitrary-refactor theorem. Freeze report v1 goldens and add negative tests for an omitted register, omitted workflow surface, stale build identity, and a changed corpus hash. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


## Concrete Steps


Run from the repository root, using the existing Nix development environment. PostgreSQL-backed tests use `Keiro.Test.Postgres` isolated migrated databases, not production credentials.

```bash
nix develop -c cabal test keiro-dsl:keiro-dsl-test
nix develop -c cabal test keiro-dsl:tests
nix develop -c cabal test keiro:keiro-test
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


The new script must pass a baseline/candidate module-rename fixture and fail every listed mutation with a surface, stream or workflow identity, and first divergent prefix/key. Run `python3 -m unittest discover -s scripts/tests -p test_replay_compatibility.py`. All feature acceptance invokes the same verdict semantics; no feature invents its own compatibility waiver.

For every admitted value, generated encoding followed by decoding must recover the same domain value, and the generated binding must satisfy both inverse laws. Exercise forward execution followed by actual event-envelope serialization, decoding, and strict replay; compare control state and all durable registers at every completed transition. Include multi-event output, replay-only transitions, and a negative head-information-loss case. A same-version in-memory replay test alone does not pass this requirement.

For each affected persisted surface, run the compatibility gate from Plan 289. Preserve genuine old bytes, tags, versions, and readers. Compare baseline and candidate interpretations under the same versioned, non-lossy observation contract; investigate the first divergent prefix. Test old-reader/new-writer compatibility separately. A narrowed domain, altered normalization, or opaque-to-checked conversion is never automatically replay-neutral. Keep historical adapters total for retained history; if history cannot be represented without loss, retain the old representation/handler and refuse adoption.

Reject unsupported symbolic operations during checking. Exact-domain evidence must include concrete-owner membership and admitted-key reconstruction, not merely a successful solver model. Unknown evidence stays unverified and blocks a release claiming preservation. Published-language acceptance, generated bytes, and frozen identities remain unchanged unless an explicit migration is part of a separate reviewed change. Any opaque nested boundary keeps its unverified status; wrapping it in a checked container does not certify it.

Workflow adoption must additionally preserve journal semantics with actual application codecs. Run old journal prefixes through candidate continuation in an isolated test environment with recorded effects; do not execute production side effects in an audit. Persisted-result decode failure must fail clearly, never be treated as a missing step and rerun. Pure refactors must retain stable names and existing results without extra actions. No snapshot invalidation, token bump, or green finite fixture suite alone proves compatibility with all stored history.


A pure refactor must preserve wire kinds/keys, version dispatch, canonical identities, initial-state meaning, and historical readers. An intentional semantic change is not relabeled a refactor: introduce explicit event versions/upcasters or retained replay-only behavior, and preserve the old interpretation for old history. Never skip an undecodable event, drop a failed workflow result, relax Keiki validation, or rewrite historical bytes to obtain a green result. Replay-only guard remedies do not repair a codec that has already rejected or changed the event.

Evidence is tied to the audited high-water marks. Concurrent writes beyond those marks require a tail audit or a controlled writer cutover before adoption. An old-reader/new-writer failure requires a documented staged rollout that keeps incompatible writes disabled until old readers are gone; it is not historical-read success. The report must retain the failed direction and the explicit rollout precondition, and automatic simultaneous-version compatibility must remain refused.

## Idempotence and Recovery


All generation and tests run in the repository checkout or an isolated fixture database. Regenerate replaceable modules through the public corpus driver; preserve create-once bindings and historical fixtures. Retry failures after fixing the owning implementation, never by accepting new historical goldens. Do not rewrite production events, journal rows, IDs, step keys, or deterministic seeds. Keep the feature on an unpublished capability until its evidence passes. Before new-format writes, rollback can retain the previous readers; after incompatible writes, use a documented forward repair or retain compatible readers rather than assuming a binary downgrade is safe. A production migration, release, or cross-repository rollout is a separate authorized action.


## Interfaces and Dependencies


The new report stores canonical JSON observations with an explicit field inventory and observation-contract ID. Observations use injective representations for the durable facts compared; hashes may identify artifacts but cannot replace the semantic comparison. Workflow traces distinguish replayed existing steps from authorized new steps and side-effect attempts. The comparator consumes two immutable reports and writes no database state.

Use the existing checked graph and total folds rather than separate per-generator allowlists. New checked constructors must be handled exhaustively by codecs, nullability, dependency traversal, fingerprints, diff, coverage, scaffolding, deterministic fixtures, and every admitted use-site lowerer. A clean check must imply complete generation. Keep consumer binding signatures total; JSON validation happens before binding conversion. Stable wire identity is independent of source module names, selectors, constructor presentation, and dependency traversal order.

Before using dependency APIs run `mori registry list`, `mori registry search <package>`, `mori registry show <qualified-project> --full`, and `mori registry docs <qualified-project>`, then read the located source. Relevant projects are `mori://shinzui/keiki`, `mori://haskell/aeson`, and consumer `mori://shinzui/rei`. If changing a dependency bound, verify the authoritative package registry and upstream release tags first; local source is not release evidence. No Keiki dependency change is assumed. If required evidence cannot be expressed by the released API, stop capability promotion and coordinate an explicit upstream change, never substitute a dishonest witness.

Revision note (2026-09-19): Linked the Mina-created intention and clarified retained-reader, strict-failure, audit-tail, and rolling-reader obligations during authoring review. No implementation or historical audit has run.
