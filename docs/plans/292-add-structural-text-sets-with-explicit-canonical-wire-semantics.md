---
id: 292
slug: add-structural-text-sets-with-explicit-canonical-wire-semantics
title: "Add structural text sets with explicit canonical wire semantics"
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
      note: "State canonical order normatively as code-point order; specify set wire token, freeze point, normalization cases."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-19T22:32:10Z
      mode: "update"
      note: "Checked set normalization and total binding design; added complete-surface API acceptance and retained-history release gates."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T03:34:56Z
      mode: "implement"
      note: "Begin Plan 292 structural text-set implementation."
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-19T22:13:44Z
      verdict: "changes-requested"
      note: "Canonical order deferred to the text library instead of a normative code-point definition; set wire token and freeze point unspecified."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-19T22:32:10Z
      verdict: "approved"
      note: "Checked set normalization and total binding design; added complete-surface API acceptance and retained-history release gates."
---

# Add structural text sets with explicit canonical wire semantics


This ExecPlan is a living document. Keep its execution sections current; distill durable decisions into ADRs during implementation. This document authorizes planned implementation scope, not production migration or a claim of completed replay proof.


## Purpose / Big Picture


This is a pre-1.0 DSL/API work stream. The improvement request below is a concrete use case; success also requires a usable public authoring path and compatibility evidence that makes later implementation consolidation safe.

Implement IR-44 as structural Set Text with canonical array output and explicit normalization of duplicate or unordered input. Users can replace opaque text-set mappings while live execution and replay operate on the same set value.


## Progress


- [x] Milestone 1: Define native checked text-set values and wire policy. (2026-09-19: added the versioned Keiro codec, code-point-order vectors, duplicate/permutation normalization, invalid-input checks, and arbitrary round trips.)
- [ ] Milestone 2: Integrate total lowering and evolution consequences.
- [ ] Milestone 3: Demonstrate normalization without replay divergence.


## Surprises & Discoveries


The resolved `text-2.1.4` implementation compares UTF-8 bytes, whose lexicographic order is Unicode code-point order, but that is an implementation fact rather than the durable contract. Upstream tag `2.1.4` matches the resolved package, so the codec uses `Set.toAscList` while its public policy remains library-independent.

The existing Aeson `Set` instance has the same operational quotient—`Set.toList` on write and `Set.fromList` on read—but Keiro needs its own versioned policy identity so declaration fingerprints can distinguish this set from both ordered lists and future set-policy revisions.

The 1.0 review clarified that mapped wire equality is only one compatibility input and candidate-language status does not prevent persisted writes. This feature must contribute its complete supported-surface cases to Plan 289 and its public adoption example to Plan 295.


## Decision Log


2026-09-19: Limit v1 to Text elements. Canonical encoding sorts by the defined Data.Text Ord order; decoding accepts permutations and duplicates and constructs the set before binding or execution. No List-to-Set total binding and no consumer-defined ordering. The user requires streams and workflows to retain replayability after refactors. Tests and explicit compatibility boundaries enforce that requirement without claiming arbitrary Haskell behavior is statically provable.

2026-09-19 (validation review): Define the canonical order normatively as lexicographic Unicode code-point order, superseding the earlier wording that deferred to the Data.Text `Ord` instance. The two agree today, confirmed empirically and in the text 2.1.4 source, but the text package changed its internal representation across major versions, so the durable contract must not be defined by reference to it. No Unicode normalization or case folding is performed.

2026-09-19 (validation review): Freeze the text-set v1 policy at first package release, give the set a `wireFingerprint` token distinct from `list(text)` that embeds the policy identity, and supply duplicate and permuted arrays as cases for Plan 289's shared normalization law.


2026-09-19 (1.0 review): Follow [ADR-47](../adr/0047-dsl-retirement-requires-complete-retained-history-evidence.md): report complete affected surfaces, preserve any already-written candidate history, and supply an executable public API example for the final adoption and retirement rehearsal. Wire equality never waives changed binding/fold or application-owned continuation evidence.

2026-09-19 (implementation): Own the structural text-set quotient in `Keiro.Codec.TextSet` with policy identity `keiro-core/text-set/1`. Add `Set Text` as a checked expression in the existing candidate language; give `TextSetMappings` no capability fold segment because its declaration-level wire token carries the policy identity.


## Outcomes & Retrospective


Not implemented. Record results and remaining adoption obligations here; plan creation is not implementation completion.


## Context and Orientation


Hard dependencies: [289](289-gate-mapping-evolution-with-serialized-and-cross-version-replay-evidence.md) and [290](290-support-named-bare-container-structural-mappings-with-transitive-nullability.md). Sets use the shared bare-shape and nullability machinery; date and byte features are independent.

Research baseline is Keiro commit `98f07213` on 2026-09-19. Recheck the working tree before implementation. `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, `Parser/Mapped.hs`, `PrettyPrint.hs`, and `TypeGraph.hs` own syntax and its checked meaning. `AggregateType.hs` and `ConsumerTypePlan.hs` select supported Haskell types. `MappedCodecPlan.hs` and `Scaffold.hs` lower codecs and generated modules; `StructuralConformance.hs`, `Harness.hs`, and `ServiceHarness.hs` produce checks. Paths abbreviated after the first module in this paragraph are relative to `keiro-dsl/src/Keiro/Dsl/`.

The same directory's `MappedDiff.hs`, `SemanticImpact.hs`, `ReplayImpact.hs`, `FoldFingerprint.hs`, `CanonicalEncoding.hs`, `Coverage.hs`, and `ScaffoldRecord.hs` connect recursive type changes to persisted surfaces, stable identities, and generated provenance. `LanguageVersion.hs` selects capabilities; do not hard-code a guessed next language number. `keiro-core/src/Keiro/Codec/Structural.hs` and `Nominal.hs` contain consumer binding contracts. `keiro-core/src/Keiro/EventStream/Validate.hs` constructs validated runnable streams. `keiro/src/Keiro/ReplayAudit.hs` checks candidate replay and candidate snapshot/full agreement, not automatic old/new semantic equivalence.

A codec converts domain values to stored JSON and back. A total binding must satisfy both domain-to-shape-to-domain and shape-to-domain-to-shape identity. A fingerprint detects declared changes; it does not make a breaking change safe. A golden is committed historical input with provenance, never regenerated from the candidate to make a failure disappear.

The governing local decisions are [ADR-12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md), which assigns private-event JSON authority to checked declarations and requires total domain/shape bindings; [ADR-3](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md), which treats snapshots as disposable caches; [ADR-4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md), which separates single-spec checks, evolution findings, runtime validation, historical codec tests, and real-history replay; and [ADR-18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md), which freezes released behavior and canonical fingerprint encodings. [ADR-46](../adr/0046-nominal-declarations-are-structural-leaves-with-keiro-owned-admission.md) preserves nominal admission inside structural values, keyed maps, and declared public IDs. These decisions remain binding; the implementation must update their relevant explanations when adding a new supported surface.

Keiki's decisions `mori://shinzui/keiki/okf/adrs/concepts/ADR-2`, `mori://shinzui/keiki/okf/adrs/concepts/ADR-3`, and `mori://shinzui/keiki/okf/adrs/concepts/ADR-5` respectively require forward/replay agreement, conservative proof gates, and stable wire identity independent of Haskell names. A transducer is the pure machine that selects a transition, updates registers, and emits events. Replay reconstructs its input from the first event of a transition; subsequent events check the expected tail. An exact projection domain is a symbolic description of every possible concrete key, with reconstruction for every admitted key. Omitting real keys can manufacture false proofs of impossibility. Never weaken validation or invent exact evidence to get a fixture through.

The source request is [IR-44](../improvement-requests/support-structural-set-mappings.md). Aeson source located at `mori://haskell/aeson/packages/aeson` encodes Set through ordered traversal and decodes with Set.fromList. That is the compatibility candidate, not proof of historical consumer parity. Arbitrary lists retain more information than sets and cannot be used as the generated set shape.


## Plan of Work


### Milestone 1 — Define native checked text-set values and wire policy


Add a checked Set Text expression and a Keiro-owned codec helper in `keiro-core/src/Keiro/Codec/TextSet.hs`. Encode an ascending unique array, decode arrays of strings using set construction, and reject non-string elements. Define the canonical order normatively as lexicographic order of Unicode code points, and state it that way in the policy text, not as "whatever the text package's `Ord` does". `Ord Text` implements exactly this order today, so `Set.toAscList` is a correct implementation. This was checked two ways during plan review: `compare "\xE000" "\x10000"` evaluates to `LT` in the project's development shell, and in project `mori://haskell/text` (version 2.1.4 in the local corpus), project-relative `text/src/Data/Text.hs` (artifact URI pending), `compareText` compares the underlying UTF-8 byte arrays, with a source comment noting that UTF-8 byte order matches code-point order whereas UTF-16 does not. That comment is also the reason not to define the contract by reference to the library: the text package changed its internal representation from UTF-16 to UTF-8 between major versions and had to take care to keep this order, so the durable contract is the code-point definition, which survives a dependency change and is implementable by a non-Haskell writer. Verify the consumer's resolved text version against the package registry before relying on the corpus copy. It is not UTF-16 code-unit order, which would place U+10000 before U+E000 and is what JavaScript's default sort produces. Add vectors that separate the two orders, including U+E000 against U+10000, plus combining-character and case examples to prevent accidental locale or normalization substitution; the policy performs no Unicode normalization and no case folding, so distinct code-point sequences are distinct elements. Domain values and shapes are Set Text, so deduplication occurs while parsing wire input, before the transducer sees a value. Reject arbitrary element types in the checker. Give the acceptance/order policy a versioned identity. That text-set v1 identity freezes at the first package release that contains this module, even while the language capability is still a candidate, because a consumer on the candidate language can write durable events from that release onward; a later correction is a v2 policy with the v1 reader retained. Canonical output bytes matter even though the decoder ignores order, because goldens, payload hashes, and any identity derived from encoded bytes depend on them. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 2 — Integrate total lowering and evolution consequences


Extend grammar/parser/printing, graph folds, codec and consumer type plans, bare-shape admissibility, imports, deterministic samples, nullability, conformance, fingerprinting, coverage, diff, and scaffold history. Set is non-null and Optional Set is admissible. Use common whole-value storage and binding paths for aggregate named mappings, structural fields, registers, queues, queries, and workspace generation. Keep membership, size, ordering comparisons, insertion/removal expressions, and symbolic collection access unsupported. A change from List to Set is a semantic change even if some fixtures have equal JSON; classify it as affected historical interpretation. The mechanism is the `wireFingerprint` token in `TypeGraph.hs`: `ReplayImpact.hs` consumes that identity alongside fold, transition, and direct nominal surfaces; the whole-service gate additionally checks process/workflow and application-owned behavior. Render the set as a token that is distinct from `list(text)` and embeds the text-set policy identity and version. Test that List-to-Set, Set-to-List, opaque-to-Set, and a policy-version change are each `replay-affected`, and that tokens for every existing declaration are byte-identical. The new `RuntimeCapability` constructor takes `capabilityFoldSegment = Nothing`, like `StructuralNominalLeaves`. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 3 — Demonstrate normalization without replay divergence


Add `keiro-dsl/test/fixtures/structural-text-sets.keiro` and registered `conformance-structural-text-sets`. Show ["b","a","a"] and ["a","b"] decode to the same Set, whose canonical output is ["a","b"]. Supply duplicate and permuted arrays as the non-canonical cases for Plan 289's shared normalization law, which also requires that replaying a chain containing the non-canonical array reaches the same vertex and registers as replaying the canonical one. This is the property that keeps live execution and replay in agreement: live execution folds the in-memory set while replay folds the decoded bytes, and they coincide only because deduplication happens during parsing and `decode (encode s) == s` for every set. Exercise empty sets and optional branches, binding inverse laws over set values, and serialized aggregate/workflow evidence. A mutation that keeps a List during live updates and deduplicates only in encoding must fail the replay gate. A strict duplicate-rejecting candidate must fail historical-input compatibility against permissive baseline examples. Inspect actual consumer fixtures and full retained history before migration. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


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

Both permutations and duplicates are accepted under the declared v1 policy; repeated encoding is stable. Ordered lists elsewhere remain unchanged. Invalid elements fail with a located parse error. Pure source refactors retain bytes and replay state. Removing a set element during encoding or changing duplicate policy is caught before adoption.

For every admitted value, generated encoding followed by decoding must recover the same domain value, and the generated binding must satisfy both inverse laws. Exercise forward execution followed by actual event-envelope serialization, decoding, and strict replay; compare control state and all durable registers at every completed transition. Include multi-event output, replay-only transitions, and a negative head-information-loss case. A same-version in-memory replay test alone does not pass this requirement.

For each affected persisted surface, run the compatibility gate from Plan 289. Preserve genuine old bytes, tags, versions, and readers. Compare baseline and candidate interpretations under the same versioned, non-lossy observation contract; investigate the first divergent prefix. Test old-reader/new-writer compatibility separately. A narrowed domain, altered normalization, or opaque-to-checked conversion is never automatically replay-neutral. Keep historical adapters total for retained history; if history cannot be represented without loss, retain the old representation/handler and refuse adoption.

Reject unsupported symbolic operations during checking. Exact-domain evidence must include concrete-owner membership and admitted-key reconstruction, not merely a successful solver model. Unknown required evidence stays unverified and blocks the preservation claim at the applicable feature, publication, adoption, or retirement gate. Published-language acceptance, generated bytes, and frozen identities remain unchanged unless an explicit migration is part of a separate reviewed change. Any opaque nested boundary keeps its unverified status; wrapping it in a checked container does not certify it.

Workflow adoption must additionally preserve journal semantics with actual application codecs. Run old journal prefixes through candidate continuation in an isolated test environment with recorded effects; do not execute production side effects in an audit. Persisted-result decode failure must fail clearly, never be treated as a missing step and rerun. Pure refactors must retain stable names and existing results without extra actions. No snapshot invalidation, token bump, or green finite fixture suite alone proves compatibility with all stored history.


A pure refactor must preserve wire kinds/keys, version dispatch, canonical identities, initial-state meaning, and historical readers. An intentional semantic change is not relabeled a refactor: introduce explicit event versions/upcasters or retained replay-only behavior, and preserve the old interpretation for old history. Never skip an undecodable event, drop a failed workflow result, relax Keiki validation, or rewrite historical bytes to obtain a green result. Replay-only guard remedies do not repair a codec that has already rejected or changed the event.

Evidence is tied to the audited high-water marks. Concurrent writes beyond those marks require a tail audit or a controlled writer cutover before adoption. An old-reader/new-writer failure requires a documented staged rollout that keeps incompatible writes disabled until old readers are gone; it is not historical-read success. The report must retain the failed direction and the explicit rollout precondition, and automatic simultaneous-version compatibility must remain refused.

## Idempotence and Recovery


All generation and tests run in the repository checkout or an isolated fixture database. Regenerate replaceable modules through the public corpus driver; preserve create-once bindings and historical fixtures. Retry failures after fixing the owning implementation, never by accepting new historical goldens. Do not rewrite production events, journal rows, IDs, step keys, or deterministic seeds. Keep new authoring capability promotion blocked until its evidence passes. Candidate status does not prevent durable writes: any package release containing a new wire policy requires committed compatibility vectors and freezes that policy identity. Removing an already-shipped candidate capability must preserve its historical read/replay path or be blocked. Before new-format writes, rollback can retain the previous readers; after incompatible writes, use a documented forward repair or retain compatible readers rather than assuming a binary downgrade is safe. A production migration, release, or cross-repository rollout is a separate authorized action.


## Interfaces and Dependencies


Set Text is a distinct checked constructor with a real Set Text generated representation and versioned wire policy. StructuralBinding remains a bijection between consumer set and generated set. Keiki receives whole set values without new symbolic evidence or ordering capabilities.

Use the existing checked graph and total folds rather than separate per-generator allowlists. New checked constructors must be handled exhaustively by codecs, nullability, dependency traversal, fingerprints, diff, coverage, scaffolding, deterministic fixtures, and every admitted use-site lowerer. A clean check must imply complete generation. Keep consumer binding signatures total; JSON validation happens before binding conversion. Stable wire identity is independent of source module names, selectors, constructor presentation, and dependency traversal order.

Before using dependency APIs run `mori registry list`, `mori registry search <package>`, `mori registry show <qualified-project> --full`, and `mori registry docs <qualified-project>`, then read the located source. Relevant projects are `mori://shinzui/keiki`, `mori://haskell/aeson`, and consumer `mori://shinzui/rei`. If changing a dependency bound, verify the authoritative package registry and upstream release tags first; local source is not release evidence. No Keiki dependency change is assumed. If required evidence cannot be expressed by the released API, stop capability promotion and coordinate an explicit upstream change, never substitute a dishonest witness.

Revision note (2026-09-19): Linked the Mina-created intention and clarified retained-reader, strict-failure, audit-tail, and rolling-reader obligations during authoring review. No implementation or historical audit has run.

Revision note (2026-09-19, validation review): Milestone 1 states the canonical order normatively with its verification and the package-release freeze point. Milestone 2 specifies the set wire token, its replay-verdict tests, and `capabilityFoldSegment = Nothing`. Milestone 3 ties the normalization cases to Plan 289's shared law and states why live execution and replay agree. No implementation has run.

Revision note (2026-09-19, 1.0 review): Added the pre-1.0 API acceptance contract, complete evidence obligations, and safe candidate-policy retention. Accepted language and runtime behavior remain unchanged. See ADR-47. No implementation or historical audit has run.
