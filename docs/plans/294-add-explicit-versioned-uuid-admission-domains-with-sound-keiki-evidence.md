---
id: 294
slug: add-explicit-versioned-uuid-admission-domains-with-sound-keiki-evidence
title: "Add explicit versioned UUID admission domains with sound Keiki evidence"
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

# Add explicit versioned UUID admission domains with sound Keiki evidence


This ExecPlan is a living document. Keep its execution sections current; distill durable decisions into ADRs during implementation. This document authorizes planned implementation scope, not production migration or a claim of completed replay proof.


## Purpose / Big Picture


Implement IR-46 so a declaration can explicitly admit canonical prefixed UUIDv5 and UUIDv7 values while existing ID declarations retain their released behavior. Runtime decoding, constructor admission, canonical equality, map keys, public IDs, and Keiki exact evidence must agree.


## Progress


- [ ] Milestone 1: Define explicit domain identity and canonical membership.
- [ ] Milestone 2: Prove runtime and symbolic agreement before exposing equality.
- [ ] Milestone 3: Propagate admission to nested and public consumers.
- [ ] Milestone 4: Rehearse mixed-domain history and immutable identities.


## Surprises & Discoveries


None recorded during implementation yet.


## Decision Log


2026-09-19: Add an explicit v5-or-v7 admission domain alongside the unchanged v7 default. Admission does not select or change ID generation. Exact symbolic evidence is emitted only when it covers every value that can reach the transducer, including historical decoder paths. The user requires streams and workflows to retain replayability after refactors. Tests and explicit compatibility boundaries enforce that requirement without claiming arbitrary Haskell behavior is statically provable.


## Outcomes & Retrospective


Not implemented. Record results and remaining adoption obligations here; plan creation is not implementation completion.


## Context and Orientation


Hard dependency: [289](289-gate-mapping-evolution-with-serialized-and-cross-version-replay-evidence.md). Integration dependency with Plan 290: both extend TypeGraph and complete recursive dependency/fingerprint traversal, but this feature can use existing record shapes and does not require bare containers.

Research baseline is Keiro commit `98f07213` on 2026-09-19. Recheck the working tree before implementation. `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, `Parser/Mapped.hs`, `PrettyPrint.hs`, and `TypeGraph.hs` own syntax and its checked meaning. `AggregateType.hs` and `ConsumerTypePlan.hs` select supported Haskell types. `MappedCodecPlan.hs` and `Scaffold.hs` lower codecs and generated modules; `StructuralConformance.hs`, `Harness.hs`, and `ServiceHarness.hs` produce checks. Paths abbreviated after the first module in this paragraph are relative to `keiro-dsl/src/Keiro/Dsl/`.

The same directory's `MappedDiff.hs`, `SemanticImpact.hs`, `ReplayImpact.hs`, `FoldFingerprint.hs`, `CanonicalEncoding.hs`, `Coverage.hs`, and `ScaffoldRecord.hs` connect recursive type changes to persisted surfaces, stable identities, and generated provenance. `LanguageVersion.hs` selects capabilities; do not hard-code a guessed next language number. `keiro-core/src/Keiro/Codec/Structural.hs` and `Nominal.hs` contain consumer binding contracts. `keiro-core/src/Keiro/EventStream/Validate.hs` constructs validated runnable streams. `keiro/src/Keiro/ReplayAudit.hs` checks candidate replay and candidate snapshot/full agreement, not automatic old/new semantic equivalence.

A codec converts domain values to stored JSON and back. A total binding must satisfy both domain-to-shape-to-domain and shape-to-domain-to-shape identity. A fingerprint detects declared changes; it does not make a breaking change safe. A golden is committed historical input with provenance, never regenerated from the candidate to make a failure disappear.

The governing local decisions are [ADR-12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md), which assigns private-event JSON authority to checked declarations and requires total domain/shape bindings; [ADR-3](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md), which treats snapshots as disposable caches; [ADR-4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md), which separates single-spec checks, evolution findings, runtime validation, historical codec tests, and real-history replay; and [ADR-18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md), which freezes released behavior and canonical fingerprint encodings. [ADR-46](../adr/0046-nominal-declarations-are-structural-leaves-with-keiro-owned-admission.md) preserves nominal admission inside structural values, keyed maps, and declared public IDs. These decisions remain binding; the implementation must update their relevant explanations when adding a new supported surface.

Keiki's decisions `mori://shinzui/keiki/okf/adrs/concepts/ADR-2`, `mori://shinzui/keiki/okf/adrs/concepts/ADR-3`, and `mori://shinzui/keiki/okf/adrs/concepts/ADR-5` respectively require forward/replay agreement, conservative proof gates, and stable wire identity independent of Haskell names. A transducer is the pure machine that selects a transition, updates registers, and emits events. Replay reconstructs its input from the first event of a transition; subsequent events check the expected tail. An exact projection domain is a symbolic description of every possible concrete key, with reconstruction for every admitted key. Omitting real keys can manufacture false proofs of impossibility. Never weaken validation or invent exact evidence to get a fixture through.

The source request is [IR-46](../improvement-requests/support-explicit-legacy-id-admission-domains.md). `keiro-core/src/Keiro/Codec/IdDomain.hs` currently fixes canonical parsing, v7 validation, an SMT-compatible text pattern, and a sample. `keiro-dsl/src/Keiro/Dsl/IdDomain.hs` selects that contract by capability. `NominalType.hs` and nominal leaves use these facts. Existing legacy-language event decoders can retain historical values outside modern admission; blindly applying a narrower exact witness to them is unsound.


## Plan of Work


### Milestone 1 — Define explicit domain identity and canonical membership


Extend the runtime IdDomainContract with a closed supported domain selector while preserving the existing serialized v7 identity and byte behavior. The new domain accepts only canonical existing prefixed Crockford-encoded identifiers whose UUID has RFC variant bits and version 5 or 7. It is not a second hyphenated UUID syntax. Preserve prefix, separator, length, leading-bit, and lowercase rules; reject wrong prefix/variant/version and malformed text. Add an explicit declaration option through Grammar, Parser/Declaration, TypeGraph, and LanguageVersion. Keep existing generation APIs and deterministic namespace/seed derivations unchanged. A declaration chooses admission; generation policy must produce values inside that admission. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 2 — Prove runtime and symbolic agreement before exposing equality


Generate the exact text-domain union using the same checked domain facts as decoding, through the released Keiki ProjectionDomain APIs. Test owners-to-domain and keys-to-owner-to-key laws for generated and consumer-bound IDs, positive v5/v7 samples, excluded versions, variants, boundary encodings, and a deliberately stale v7-only witness. Add a guard-overlap case reachable only through v5 that must never be blessed as disjoint. Test proof-unknown paths conservatively. Audit historical constructors: if a transducer may receive arbitrary legacy text, its domain must truthfully include that reachable carrier or remain one-way/unverified; historical decoder support cannot be traded for a dishonest exact claim. Preserve declaration-scoped equality and do not add ID ordering expressions. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 3 — Propagate admission to nested and public consumers


Update `NominalType.hs`, `TypeGraph.hs`, `MappedCodecPlan.hs`, `Scaffold.hs`, integration-contract lowering, keyed-map codecs, canonical ordering conformance, router recipient identities, ExplainBindings, fingerprints, snapshots, coverage, and diff. Every supported use preserves the selected domain; unsupported public combinations fail checking instead of calling the v7 parser. Report widening as an old-reader/new-writer hazard and narrowing as a historical-read hazard. Preserve released-language fixtures, including legacy historical decoding. Add `keiro-dsl/test/fixtures/id-admission-domains.keiro` and a registered conformance suite exercising direct/nested/optional-in-record IDs, ID map keys, public contracts, and queues. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 4 — Rehearse mixed-domain history and immutable identities


Compare historical and newly produced v5/v7 values in consumer `mori://shinzui/rei`. Test unchanged stream names, event identities, router keys, workflow/child/timer identities, and deterministic content-derived IDs before and after binding adoption. Use Plan 289 baseline/candidate replay and rolling-reader reports. Adding a domain is not permission to regenerate an identifier. Retain old historical readers or representation paths where required; if total historical reconstruction is impossible, keep the opaque consumer mapping and mark adoption unverified. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


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


Existing implicit-v7 declarations still reject v5; explicit-v5-or-v7 declarations accept valid samples of both and reject all tested wrong variants/prefixes/versions. Exact witness owner coverage includes historical reachable values, not only newly constructible IDs. A stale v7-only domain mutation fails conformance or remains unverified, never producing a successful proof. Mixed streams replay with identical identifiers and durable state.

For every admitted value, generated encoding followed by decoding must recover the same domain value, and the generated binding must satisfy both inverse laws. Exercise forward execution followed by actual event-envelope serialization, decoding, and strict replay; compare control state and all durable registers at every completed transition. Include multi-event output, replay-only transitions, and a negative head-information-loss case. A same-version in-memory replay test alone does not pass this requirement.

For each affected persisted surface, run the compatibility gate from Plan 289. Preserve genuine old bytes, tags, versions, and readers. Compare baseline and candidate interpretations under the same versioned, non-lossy observation contract; investigate the first divergent prefix. Test old-reader/new-writer compatibility separately. A narrowed domain, altered normalization, or opaque-to-checked conversion is never automatically replay-neutral. Keep historical adapters total for retained history; if history cannot be represented without loss, retain the old representation/handler and refuse adoption.

Reject unsupported symbolic operations during checking. Exact-domain evidence must include concrete-owner membership and admitted-key reconstruction, not merely a successful solver model. Unknown evidence stays unverified and blocks a release claiming preservation. Published-language acceptance, generated bytes, and frozen identities remain unchanged unless an explicit migration is part of a separate reviewed change. Any opaque nested boundary keeps its unverified status; wrapping it in a checked container does not certify it.

Workflow adoption must additionally preserve journal semantics with actual application codecs. Run old journal prefixes through candidate continuation in an isolated test environment with recorded effects; do not execute production side effects in an audit. Persisted-result decode failure must fail clearly, never be treated as a missing step and rerun. Pure refactors must retain stable names and existing results without extra actions. No snapshot invalidation, token bump, or green finite fixture suite alone proves compatibility with all stored history.


A pure refactor must preserve wire kinds/keys, version dispatch, canonical identities, initial-state meaning, and historical readers. An intentional semantic change is not relabeled a refactor: introduce explicit event versions/upcasters or retained replay-only behavior, and preserve the old interpretation for old history. Never skip an undecodable event, drop a failed workflow result, relax Keiki validation, or rewrite historical bytes to obtain a green result. Replay-only guard remedies do not repair a codec that has already rejected or changed the event.

Evidence is tied to the audited high-water marks. Concurrent writes beyond those marks require a tail audit or a controlled writer cutover before adoption. An old-reader/new-writer failure requires a documented staged rollout that keeps incompatible writes disabled until old readers are gone; it is not historical-read success. The report must retain the failed direction and the explicit rollout precondition, and automatic simultaneous-version compatibility must remain refused.

## Idempotence and Recovery


All generation and tests run in the repository checkout or an isolated fixture database. Regenerate replaceable modules through the public corpus driver; preserve create-once bindings and historical fixtures. Retry failures after fixing the owning implementation, never by accepting new historical goldens. Do not rewrite production events, journal rows, IDs, step keys, or deterministic seeds. Keep the feature on an unpublished capability until its evidence passes. Before new-format writes, rollback can retain the previous readers; after incompatible writes, use a documented forward repair or retain compatible readers rather than assuming a binary downgrade is safe. A production migration, release, or cross-repository rollout is a separate authorized action.


## Interfaces and Dependencies


One checked IdDomainContract drives admission, text pattern, canonical identity, samples, generated/public codecs, and nested key/value uses. Add domains by versioned constructors, not caller-supplied regexes. Public construction restrictions and historical internal constructors are distinct surfaces whose combined reachable carrier determines proof strength.

Use the existing checked graph and total folds rather than separate per-generator allowlists. New checked constructors must be handled exhaustively by codecs, nullability, dependency traversal, fingerprints, diff, coverage, scaffolding, deterministic fixtures, and every admitted use-site lowerer. A clean check must imply complete generation. Keep consumer binding signatures total; JSON validation happens before binding conversion. Stable wire identity is independent of source module names, selectors, constructor presentation, and dependency traversal order.

Before using dependency APIs run `mori registry list`, `mori registry search <package>`, `mori registry show <qualified-project> --full`, and `mori registry docs <qualified-project>`, then read the located source. Relevant projects are `mori://shinzui/keiki`, `mori://haskell/aeson`, and consumer `mori://shinzui/rei`. If changing a dependency bound, verify the authoritative package registry and upstream release tags first; local source is not release evidence. No Keiki dependency change is assumed. If required evidence cannot be expressed by the released API, stop capability promotion and coordinate an explicit upstream change, never substitute a dishonest witness.

Revision note (2026-09-19): Linked the Mina-created intention and clarified retained-reader, strict-failure, audit-tail, and rolling-reader obligations during authoring review. No implementation or historical audit has run.
