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
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-19T22:13:45Z
      mode: "update"
      note: "Specify refined wire token and freeze point; add permissive-reader and identity-stability checks; move consumer history to Plan 295."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-19T22:32:10Z
      mode: "update"
      note: "Checked byte-refinement laws, identity preservation and parser policy; added API acceptance and retained-history release gates."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T04:40:21Z
      mode: "implement"
      note: "Begin Plan 293 declarative base16 byte-refinement implementation."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T05:39:29Z
      mode: "implement"
      note: "Complete Plan 293 with the frozen base16-bytes policy, exhaustive checked lowering, compiled replay evidence, and clean-corpus validation."
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-19T22:13:44Z
      verdict: "changes-requested"
      note: "Refined wire token and freeze point unspecified; no check that canonicalization preserves hash-derived durable identities."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-19T22:32:10Z
      verdict: "approved"
      note: "Checked byte-refinement laws, identity preservation and parser policy; added API acceptance and retained-history release gates."
---

# Add declarative base16 byte refinements with total consumer bindings


This ExecPlan is a living document. Keep its execution sections current; distill durable decisions into ADRs during implementation. This document authorizes planned implementation scope, not production migration or a claim of completed replay proof.


## Purpose / Big Picture


This is a pre-1.0 DSL/API work stream. The improvement request below is a concrete use case; success also requires a usable public authoring path and compatibility evidence that makes later implementation consolidation safe.

Implement the bounded initial slice of IR-45: byte-backed refined mappings with a declared base16 codec and total consumer bindings. Hash types can become inspectable schema declarations without treating arbitrary Text as valid or hiding consumer rejection in a structural binding.


## Progress


- [x] Milestone 1: Specify and implement a bounded refinement contract.
- [x] Milestone 2: Compose refinement through all admitted checked roots.
- [x] Milestone 3: Prove byte identity and preserve old hash semantics.


## Surprises & Discoveries


Strict generated-module warnings exposed that a refined-only scaffold had inherited codec imports for declarations its harness did not assert. Restricting harness codec imports to the declarations it actually exercises kept generated modules warning-clean without weakening coverage.

The conformance package uses `NoFieldSelectors`, so the total consumer binding must unwrap the byte wrapper by constructor pattern rather than through a generated selector. The create-once domain module also had to export its constructor so the generated projection hole could remain a total application-owned boundary; corpus regeneration preserved that hand-owned edit.

The nested `HashEnvelope` example requires `containers` even though its aggregate root mentions only a consumer type. Existing graph-wide dependency inference handled the transitive `Map Text` shape once the new refined leaf participated in the same checked graph.

The full DSL suite's closed inventories caught both integration omissions immediately: the new compiled component needed a conformance-baseline row, and the Language-6 fixture needed inclusion in the explicit non-Language-4 fixture list.

The 1.0 review clarified that mapped wire equality is only one compatibility input and candidate-language status does not prevent persisted writes. This feature must contribute its complete supported-surface cases to Plan 289 and its public adoption example to Plan 295.


## Decision Log


2026-09-19: Use unrestricted bytes as the v1 representation, lowercase canonical hex output, case-insensitive valid hex input, and even-length validation. Accept empty bytes; do not impose digest length. Defer arbitrary predicates and optional length refinements to separately versioned work. The user requires streams and workflows to retain replayability after refactors. Tests and explicit compatibility boundaries enforce that requirement without claiming arbitrary Haskell behavior is statically provable.

2026-09-19 (validation review): Freeze the base16-bytes v1 policy at first package release, give the refined declaration a `wireFingerprint` token distinct from text and nominal Text that embeds the policy identity, and check whether the consumer's historical reader was more permissive than this parser. Complete this plan on repository fixtures, leaving real consumer history to Plan 295.

2026-09-19 (validation review): Require proof that canonicalization changes no durable identity. A hash whose hex text feeds a deterministic identity, stream name, or router key must produce the same identity from an uppercase historical payload after adoption as was recorded before it.


2026-09-19 (1.0 review): Follow [ADR-47](../adr/0047-dsl-retirement-requires-complete-retained-history-evidence.md): report complete affected surfaces, preserve any already-written candidate history, and supply an executable public API example for the final adoption and retirement rehearsal. Wire equality never waives changed binding/fold or application-owned continuation evidence.

2026-09-20 (implementation): Add explicit `mapped refined` syntax with `wire base16-bytes`, represented in the checked graph as `RRefined Base16BytesV1` and lowered through a total `StructuralBinding domain ByteString`. Freeze policy identity `keiro-core/base16-bytes/1`; write lowercase, read case-insensitively, preserve empty values, arbitrary lengths, and leading zeroes, and reject malformed JSON before the consumer binding.

2026-09-20 (implementation): Register `RefinedBase16Mappings` only in candidate Language 6 with no capability-wide fold segment. Carry the policy identity in each declaration's wire fingerprint, keep map keys and symbolic operations unsupported, reject callback/length escape hatches, and leave public contracts plus process/workflow persistence application-owned.


## Outcomes & Retrospective


Implemented in `e548fffd`. Keiro now exposes a frozen base16-bytes codec and public refined-codec façade; the DSL parses, checks, pretty-prints, diffs, fingerprints, scaffolds, manifests, and records explicit refined declarations through the same exhaustive graph algebras as other checked mappings.

The compiled `refined-base16` corpus passes 79 assertions covering empty and leading-zero bytes, arbitrary lengths, mixed-case normalization, malformed-input rejection before binding, both total binding laws, nested optional/list/map values, aggregate commands/events/registers, queue and query consumers, multi-event serialized replay, replay-only history, head-information-loss and transposing-binding mutations, historical codec parity, generated codec comparison, and content-derived identity stability. Its supported-use matrix marks public contracts unsupported and workflow codecs application-owned.

Validation completed with all 53 `keiro-dsl:tests` components green, the main DSL suite at 784 examples with zero failures, the runtime suite at 711 examples with zero failures, strict validation of all 47 ADR concepts, and a clean 51-invocation conformance corpus with no drift. Real retained consumer streams and workflow journals remain deliberately assigned to Plan 295; this repository proof does not claim that audit or publish Language 6.


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


Add `keiro-core/src/Keiro/Codec/Refined.hs` containing the base16 bytes policy, stable typed failure categories, pure canonical encoder, and parser. Introduce an explicit refined declaration branch in the DSL rather than widening mapped nominal Text. Its checked facts name representation bytes, base16 wire policy/version, consumer provenance, binding version, fixtures, canonical type identity, and register initial where used. Retain total domain-to-bytes and bytes-to-domain binding laws; failures happen before bytes cross the binding. Reject odd length, non-hex, whitespace, and prefixes; accept uppercase/lowercase digits and empty input. Canonical output is lowercase. Pin examples against actual consumer libraries; historical differences require an old reader rather than a hidden policy change. Check in particular whether the consumer's historical reader was more permissive than this policy, for example a lenient base16 decoder that returned a partial result on invalid input instead of failing: a payload the old reader accepted and this parser rejects is a historical-read failure, and the remedy is a retained versioned reader, never a quietly widened v1. The base16-bytes v1 policy identity freezes at the first package release that contains this module, even while the language capability is still a candidate, because a consumer on the candidate language can write durable events from that release onward; a later correction is a v2 policy with the v1 reader retained. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 2 — Compose refinement through all admitted checked roots


Extend TypeGraph and all total folds, MappedCodecPlan, ConsumerTypePlan, Scaffold, StructuralConformance, Coverage, MappedDiff, and fingerprints with refined representation and policy facts. Permit references inside existing structural expressions and named aggregate mappings, including optional/list/map compositions, queues, queries, and workspace consumers. Mark the JSON string representation non-null only because Keiro owns this parser/encoder. Keep symbolic equality/ordering/arithmetic and use as map keys unsupported initially. Map keys stay excluded for a replay reason as well as a scope reason: two hex spellings of the same bytes would be one key after decoding but two keys on the wire. Render the refined declaration in `wireFingerprint` (`TypeGraph.hs`) as a token that is distinct from `text` and from a nominal Text scalar and embeds the base16-bytes policy identity and version, because `ReplayImpact.hs` uses wire identity alongside fold, transition, and direct nominal surfaces to classify aggregate replay impact. Test that nominal-Text-to-refined, opaque-to-refined, and a policy-version change are each `replay-affected`, and that tokens for every existing declaration are byte-identical. The new `RuntimeCapability` constructor takes `capabilityFoldSegment = Nothing`, like `StructuralNominalLeaves`. Reject arbitrary validation callbacks and length options with useful diagnostics; do not implement a generic callback escape hatch under a checked proof label. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 3 — Prove byte identity and preserve old hash semantics


Add `keiro-dsl/test/fixtures/refined-base16.keiro` and registered `conformance-refined-base16` suites with empty bytes, leading zero bytes, mixed-case input, odd-length/non-hex rejection, and lengths other than SHA-256. Prove decoder(encoder(bytes)) is identity and canonicalization preserves decoded bytes. Test consumer binding transposition/normalization mutations, optional composition, public unsupported surfaces, and serialized replay. Compare TaskContentHash/EmbedHash payloads using the existing codec-comparison path and Plan 289, with committed payload fixtures modeled on the consumer's codec source as located through Mori. These are repository fixtures and must be labeled as such; evidence from the consumer's real retained history is owned by Plan 295 Milestone 3 and is not required to complete this plan. Supply mixed-case and uppercase spellings as the non-canonical cases for Plan 289's shared normalization law. Add a case proving that no durable identity changes under canonicalization: where a hash value feeds a deterministic or content-derived identity, stream name, or router key, the identity computed after adoption from an uppercase historical payload must equal the identity recorded before adoption, or adoption is refused for that surface. A new length restriction, dropped leading zeros, or a hidden rejecting binding must fail. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


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


Commit a supported-use matrix and compiled public-API example for this feature: bare and nested uses, aggregate commands/events/registers, queue payloads, query types, workspace ownership, public contracts, and process/workflow hand-owned codecs must each be supported with a tested path, explicitly unsupported with a located diagnostic, or explicitly application-owned. Do not imply that sharing a value type grants process/workflow codec ownership. Exercise clean generation and regeneration without editing generated modules, and document the smallest total consumer binding. Plan 295 reuses these examples. API convenience cannot weaken domain admission, binding laws, or replay validation.

"00aF" and "00af" decode to the same two bytes, which encode as "00af"; "", arbitrary-length valid hex, and leading zeros remain valid. "0", "0x00", "gg", and whitespace-bearing input fail. The domain/shape laws apply to byte values, not every accepted textual spelling. No digest recomputation or content normalization occurs during replay.

For every admitted value, generated encoding followed by decoding must recover the same domain value, and the generated binding must satisfy both inverse laws. Exercise forward execution followed by actual event-envelope serialization, decoding, and strict replay; compare control state and all durable registers at every completed transition. Include multi-event output, replay-only transitions, and a negative head-information-loss case. A same-version in-memory replay test alone does not pass this requirement.

For each affected persisted surface, run the compatibility gate from Plan 289. Preserve genuine old bytes, tags, versions, and readers. Compare baseline and candidate interpretations under the same versioned, non-lossy observation contract; investigate the first divergent prefix. Test old-reader/new-writer compatibility separately. A narrowed domain, altered normalization, or opaque-to-checked conversion is never automatically replay-neutral. Keep historical adapters total for retained history; if history cannot be represented without loss, retain the old representation/handler and refuse adoption.

Reject unsupported symbolic operations during checking. Exact-domain evidence must include concrete-owner membership and admitted-key reconstruction, not merely a successful solver model. Unknown required evidence stays unverified and blocks the preservation claim at the applicable feature, publication, adoption, or retirement gate. Published-language acceptance, generated bytes, and frozen identities remain unchanged unless an explicit migration is part of a separate reviewed change. Any opaque nested boundary keeps its unverified status; wrapping it in a checked container does not certify it.

Workflow adoption must additionally preserve journal semantics with actual application codecs. Run old journal prefixes through candidate continuation in an isolated test environment with recorded effects; do not execute production side effects in an audit. Persisted-result decode failure must fail clearly, never be treated as a missing step and rerun. Pure refactors must retain stable names and existing results without extra actions. No snapshot invalidation, token bump, or green finite fixture suite alone proves compatibility with all stored history.


A pure refactor must preserve wire kinds/keys, version dispatch, canonical identities, initial-state meaning, and historical readers. An intentional semantic change is not relabeled a refactor: introduce explicit event versions/upcasters or retained replay-only behavior, and preserve the old interpretation for old history. Never skip an undecodable event, drop a failed workflow result, relax Keiki validation, or rewrite historical bytes to obtain a green result. Replay-only guard remedies do not repair a codec that has already rejected or changed the event.

Evidence is tied to the audited high-water marks. Concurrent writes beyond those marks require a tail audit or a controlled writer cutover before adoption. An old-reader/new-writer failure requires a documented staged rollout that keeps incompatible writes disabled until old readers are gone; it is not historical-read success. The report must retain the failed direction and the explicit rollout precondition, and automatic simultaneous-version compatibility must remain refused.

## Idempotence and Recovery


All generation and tests run in the repository checkout or an isolated fixture database. Regenerate replaceable modules through the public corpus driver; preserve create-once bindings and historical fixtures. Retry failures after fixing the owning implementation, never by accepting new historical goldens. Do not rewrite production events, journal rows, IDs, step keys, or deterministic seeds. Keep new authoring capability promotion blocked until its evidence passes. Candidate status does not prevent durable writes: any package release containing a new wire policy requires committed compatibility vectors and freezes that policy identity. Removing an already-shipped candidate capability must preserve its historical read/replay path or be blocked. Before new-format writes, rollback can retain the previous readers; after incompatible writes, use a documented forward repair or retain compatible readers rather than assuming a binary downgrade is safe. A production migration, release, or cross-repository rollout is a separate authorized action.


## Interfaces and Dependencies


The refined declaration is diff-visible and separately identified from nominal scalars. Consumer conversion is still total; the v1 shape is bytes, not raw hex text. Keiro owns the canonicalization and failure rules. Any future bounded byte carrier must enforce its bound at construction as well as decoding and carry a new explicit contract.

Use the existing checked graph and total folds rather than separate per-generator allowlists. New checked constructors must be handled exhaustively by codecs, nullability, dependency traversal, fingerprints, diff, coverage, scaffolding, deterministic fixtures, and every admitted use-site lowerer. A clean check must imply complete generation. Keep consumer binding signatures total; JSON validation happens before binding conversion. Stable wire identity is independent of source module names, selectors, constructor presentation, and dependency traversal order.

Before using dependency APIs run `mori registry list`, `mori registry search <package>`, `mori registry show <qualified-project> --full`, and `mori registry docs <qualified-project>`, then read the located source. Relevant projects are `mori://shinzui/keiki`, `mori://haskell/aeson`, and consumer `mori://shinzui/rei`. If changing a dependency bound, verify the authoritative package registry and upstream release tags first; local source is not release evidence. No Keiki dependency change is assumed. If required evidence cannot be expressed by the released API, stop capability promotion and coordinate an explicit upstream change, never substitute a dishonest witness.

Revision note (2026-09-19): Linked the Mina-created intention and clarified retained-reader, strict-failure, audit-tail, and rolling-reader obligations during authoring review. No implementation or historical audit has run.

Revision note (2026-09-19, validation review): Milestone 1 adds the permissive-historical-reader check and the package-release freeze point. Milestone 2 specifies the refined wire token, its replay-verdict tests, the replay reason map keys stay excluded, and `capabilityFoldSegment = Nothing`. Milestone 3 separates repository fixtures from consumer history owned by Plan 295, supplies normalization-law cases, and adds the identity-stability case. No implementation has run.

Revision note (2026-09-19, 1.0 review): Added the pre-1.0 API acceptance contract, complete evidence obligations, and safe candidate-policy retention. Accepted language and runtime behavior remain unchanged. See ADR-47. No implementation or historical audit has run.

Revision note (2026-09-20, implementation): Completed the frozen unrestricted-byte base16 policy, explicit refined syntax, exhaustive checked-graph lowering, policy-versioned replay identity, compiled supported-use matrix, historical codec comparison, serialized normalization/replay evidence, mutation checks, ADR updates, full regression suites, and clean-corpus validation. Consumer retained-history adoption, candidate publication, and legacy retirement remain open in Plan 295.
