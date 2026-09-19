---
id: 293
slug: add-declarative-base16-byte-refinements-with-total-consumer-bindings
title: "Add declarative base16 byte refinements with total consumer bindings"
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

# Add declarative base16 byte refinements with total consumer bindings


This ExecPlan is a living document. Keep its execution sections current; distill durable decisions into ADRs during implementation. This document authorizes planned implementation scope, not production migration or a claim of completed replay proof.


## Purpose / Big Picture


Implement the bounded initial slice of IR-45: byte-backed refined mappings with a declared base16 codec and total consumer bindings. Hash types can become inspectable schema declarations without treating arbitrary Text as valid or hiding consumer rejection in a structural binding.


## Progress


- [ ] Milestone 1: Specify and implement a bounded refinement contract.
- [ ] Milestone 2: Compose refinement through all admitted checked roots.
- [ ] Milestone 3: Prove byte identity and preserve old hash semantics.


## Surprises & Discoveries


None recorded during implementation yet.


## Decision Log


2026-09-19: Use unrestricted bytes as the v1 representation, lowercase canonical hex output, case-insensitive valid hex input, and even-length validation. Accept empty bytes; do not impose digest length. Defer arbitrary predicates and optional length refinements to separately versioned work. The user requires streams and workflows to retain replayability after refactors. Tests and explicit compatibility boundaries enforce that requirement without claiming arbitrary Haskell behavior is statically provable.


## Outcomes & Retrospective


Not implemented. Record results and remaining adoption obligations here; plan creation is not implementation completion.


## Context and Orientation


Hard dependencies: [289](289-gate-mapping-evolution-with-serialized-and-cross-version-replay-evidence.md) for compatibility evidence and [290](290-support-named-bare-container-structural-mappings-with-transitive-nullability.md) for bare-shape/nullability integration. This plan owns the separate refinement contract, not a weakened nominal binding.

Research baseline is Keiro commit `98f07213` on 2026-09-19. Recheck the working tree before implementation. `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, `Parser/Mapped.hs`, `PrettyPrint.hs`, and `TypeGraph.hs` own syntax and its checked meaning. `AggregateType.hs` and `ConsumerTypePlan.hs` select supported Haskell types. `MappedCodecPlan.hs` and `Scaffold.hs` lower codecs and generated modules; `StructuralConformance.hs`, `Harness.hs`, and `ServiceHarness.hs` produce checks. Paths abbreviated after the first module in this paragraph are relative to `keiro-dsl/src/Keiro/Dsl/`.

The same directory's `MappedDiff.hs`, `SemanticImpact.hs`, `ReplayImpact.hs`, `FoldFingerprint.hs`, `CanonicalEncoding.hs`, `Coverage.hs`, and `ScaffoldRecord.hs` connect recursive type changes to persisted surfaces, stable identities, and generated provenance. `LanguageVersion.hs` selects capabilities; do not hard-code a guessed next language number. `keiro-core/src/Keiro/Codec/Structural.hs` and `Nominal.hs` contain consumer binding contracts. `keiro-core/src/Keiro/EventStream/Validate.hs` constructs validated runnable streams. `keiro/src/Keiro/ReplayAudit.hs` checks candidate replay and candidate snapshot/full agreement, not automatic old/new semantic equivalence.

A codec converts domain values to stored JSON and back. A total binding must satisfy both domain-to-shape-to-domain and shape-to-domain-to-shape identity. A fingerprint detects declared changes; it does not make a breaking change safe. A golden is committed historical input with provenance, never regenerated from the candidate to make a failure disappear.

The governing local decisions are [ADR-12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md), which assigns private-event JSON authority to checked declarations and requires total domain/shape bindings; [ADR-3](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md), which treats snapshots as disposable caches; [ADR-4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md), which separates single-spec checks, evolution findings, runtime validation, historical codec tests, and real-history replay; and [ADR-18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md), which freezes released behavior and canonical fingerprint encodings. [ADR-46](../adr/0046-nominal-declarations-are-structural-leaves-with-keiro-owned-admission.md) preserves nominal admission inside structural values, keyed maps, and declared public IDs. These decisions remain binding; the implementation must update their relevant explanations when adding a new supported surface.

Keiki's decisions `mori://shinzui/keiki/okf/adrs/concepts/ADR-2`, `mori://shinzui/keiki/okf/adrs/concepts/ADR-3`, and `mori://shinzui/keiki/okf/adrs/concepts/ADR-5` respectively require forward/replay agreement, conservative proof gates, and stable wire identity independent of Haskell names. A transducer is the pure machine that selects a transition, updates registers, and emits events. Replay reconstructs its input from the first event of a transition; subsequent events check the expected tail. An exact projection domain is a symbolic description of every possible concrete key, with reconstruction for every admitted key. Omitting real keys can manufacture false proofs of impossibility. Never weaken validation or invent exact evidence to get a fixture through.

The source request is [IR-45](../improvement-requests/support-explicit-refined-scalar-mappings.md). In `mori://shinzui/rei`, project-relative `rei-core/src/Rei/Modules/Knowledge/Domain/Task/Types.hs` and `rei-core/src/Rei/Modules/Note/Domain/Types.hs` (artifact URIs pending), TaskContentHash and EmbedHash are ByteString wrappers. Their current JSON readers validate hex but do not constrain decoded length. Existing total nominal Text bindings cannot represent this honestly.


## Plan of Work


### Milestone 1 — Specify and implement a bounded refinement contract


Add `keiro-core/src/Keiro/Codec/Refined.hs` containing the base16 bytes policy, stable typed failure categories, pure canonical encoder, and parser. Introduce an explicit refined declaration branch in the DSL rather than widening mapped nominal Text. Its checked facts name representation bytes, base16 wire policy/version, consumer provenance, binding version, fixtures, canonical type identity, and register initial where used. Retain total domain-to-bytes and bytes-to-domain binding laws; failures happen before bytes cross the binding. Reject odd length, non-hex, whitespace, and prefixes; accept uppercase/lowercase digits and empty input. Canonical output is lowercase. Pin examples against actual consumer libraries; historical differences require an old reader rather than a hidden policy change. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 2 — Compose refinement through all admitted checked roots


Extend TypeGraph and all total folds, MappedCodecPlan, ConsumerTypePlan, Scaffold, StructuralConformance, Coverage, MappedDiff, and fingerprints with refined representation and policy facts. Permit references inside existing structural expressions and named aggregate mappings, including optional/list/map compositions, queues, queries, and workspace consumers. Mark the JSON string representation non-null only because Keiro owns this parser/encoder. Keep symbolic equality/ordering/arithmetic and use as map keys unsupported initially. Reject arbitrary validation callbacks and length options with useful diagnostics; do not implement a generic callback escape hatch under a checked proof label. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 3 — Prove byte identity and preserve old hash semantics


Add `keiro-dsl/test/fixtures/refined-base16.keiro` and registered `conformance-refined-base16` suites with empty bytes, leading zero bytes, mixed-case input, odd-length/non-hex rejection, and lengths other than SHA-256. Prove decoder(encoder(bytes)) is identity and canonicalization preserves decoded bytes. Test consumer binding transposition/normalization mutations, optional composition, public unsupported surfaces, and serialized replay. Compare TaskContentHash/EmbedHash historical payloads using the existing codec-comparison path and Plan 289. A new length restriction, dropped leading zeros, or a hidden rejecting binding must fail. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


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


"00aF" and "00af" decode to the same two bytes, which encode as "00af"; "", arbitrary-length valid hex, and leading zeros remain valid. "0", "0x00", "gg", and whitespace-bearing input fail. The domain/shape laws apply to byte values, not every accepted textual spelling. No digest recomputation or content normalization occurs during replay.

For every admitted value, generated encoding followed by decoding must recover the same domain value, and the generated binding must satisfy both inverse laws. Exercise forward execution followed by actual event-envelope serialization, decoding, and strict replay; compare control state and all durable registers at every completed transition. Include multi-event output, replay-only transitions, and a negative head-information-loss case. A same-version in-memory replay test alone does not pass this requirement.

For each affected persisted surface, run the compatibility gate from Plan 289. Preserve genuine old bytes, tags, versions, and readers. Compare baseline and candidate interpretations under the same versioned, non-lossy observation contract; investigate the first divergent prefix. Test old-reader/new-writer compatibility separately. A narrowed domain, altered normalization, or opaque-to-checked conversion is never automatically replay-neutral. Keep historical adapters total for retained history; if history cannot be represented without loss, retain the old representation/handler and refuse adoption.

Reject unsupported symbolic operations during checking. Exact-domain evidence must include concrete-owner membership and admitted-key reconstruction, not merely a successful solver model. Unknown evidence stays unverified and blocks a release claiming preservation. Published-language acceptance, generated bytes, and frozen identities remain unchanged unless an explicit migration is part of a separate reviewed change. Any opaque nested boundary keeps its unverified status; wrapping it in a checked container does not certify it.

Workflow adoption must additionally preserve journal semantics with actual application codecs. Run old journal prefixes through candidate continuation in an isolated test environment with recorded effects; do not execute production side effects in an audit. Persisted-result decode failure must fail clearly, never be treated as a missing step and rerun. Pure refactors must retain stable names and existing results without extra actions. No snapshot invalidation, token bump, or green finite fixture suite alone proves compatibility with all stored history.


A pure refactor must preserve wire kinds/keys, version dispatch, canonical identities, initial-state meaning, and historical readers. An intentional semantic change is not relabeled a refactor: introduce explicit event versions/upcasters or retained replay-only behavior, and preserve the old interpretation for old history. Never skip an undecodable event, drop a failed workflow result, relax Keiki validation, or rewrite historical bytes to obtain a green result. Replay-only guard remedies do not repair a codec that has already rejected or changed the event.

Evidence is tied to the audited high-water marks. Concurrent writes beyond those marks require a tail audit or a controlled writer cutover before adoption. An old-reader/new-writer failure requires a documented staged rollout that keeps incompatible writes disabled until old readers are gone; it is not historical-read success. The report must retain the failed direction and the explicit rollout precondition, and automatic simultaneous-version compatibility must remain refused.

## Idempotence and Recovery


All generation and tests run in the repository checkout or an isolated fixture database. Regenerate replaceable modules through the public corpus driver; preserve create-once bindings and historical fixtures. Retry failures after fixing the owning implementation, never by accepting new historical goldens. Do not rewrite production events, journal rows, IDs, step keys, or deterministic seeds. Keep the feature on an unpublished capability until its evidence passes. Before new-format writes, rollback can retain the previous readers; after incompatible writes, use a documented forward repair or retain compatible readers rather than assuming a binary downgrade is safe. A production migration, release, or cross-repository rollout is a separate authorized action.


## Interfaces and Dependencies


The refined declaration is diff-visible and separately identified from nominal scalars. Consumer conversion is still total; the v1 shape is bytes, not raw hex text. Keiro owns the canonicalization and failure rules. Any future bounded byte carrier must enforce its bound at construction as well as decoding and carry a new explicit contract.

Use the existing checked graph and total folds rather than separate per-generator allowlists. New checked constructors must be handled exhaustively by codecs, nullability, dependency traversal, fingerprints, diff, coverage, scaffolding, deterministic fixtures, and every admitted use-site lowerer. A clean check must imply complete generation. Keep consumer binding signatures total; JSON validation happens before binding conversion. Stable wire identity is independent of source module names, selectors, constructor presentation, and dependency traversal order.

Before using dependency APIs run `mori registry list`, `mori registry search <package>`, `mori registry show <qualified-project> --full`, and `mori registry docs <qualified-project>`, then read the located source. Relevant projects are `mori://shinzui/keiki`, `mori://haskell/aeson`, and consumer `mori://shinzui/rei`. If changing a dependency bound, verify the authoritative package registry and upstream release tags first; local source is not release evidence. No Keiki dependency change is assumed. If required evidence cannot be expressed by the released API, stop capability promotion and coordinate an explicit upstream change, never substitute a dishonest witness.

Revision note (2026-09-19): Linked the Mina-created intention and clarified retained-reader, strict-failure, audit-tail, and rolling-reader obligations during authoring review. No implementation or historical audit has run.
