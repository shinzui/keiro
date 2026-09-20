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
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-19T22:13:45Z
      mode: "update"
      note: "Thread admission domain through wire token, contract selectors, ledger rows, and diff finding; two-way validator/pattern property; rescope M4 to fixtures."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-19T22:32:10Z
      mode: "update"
      note: "Checked direct/nested domain propagation and exact evidence obligations; added API matrix and retained-history release gates."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T13:49:09Z
      mode: "implement"
      note: "Begin explicit UUID admission-domain implementation."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T15:26:22Z
      mode: "implement"
      note: "Complete explicit UUIDv5-or-v7 admission with exact Keiki evidence, replay-visible identity, public conformance coverage, and full validation."
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-19T22:13:44Z
      verdict: "changes-requested"
      note: "nominalWireToken and idDomainContractFor hard-wire v7, so a domain change could be reported replay-neutral; M4 duplicated Plan 295 consumer rehearsal."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-19T22:32:10Z
      verdict: "approved"
      note: "Checked direct/nested domain propagation and exact evidence obligations; added API matrix and retained-history release gates."
---

# Add explicit versioned UUID admission domains with sound Keiki evidence


This ExecPlan is a living document. Keep its execution sections current; distill durable decisions into ADRs during implementation. This document authorizes planned implementation scope, not production migration or a claim of completed replay proof.


## Purpose / Big Picture


This is a pre-1.0 DSL/API work stream. The improvement request below is a concrete use case; success also requires a usable public authoring path and compatibility evidence that makes later implementation consolidation safe.

Implement IR-46 so a declaration can explicitly admit canonical prefixed UUIDv5 and UUIDv7 values while existing ID declarations retain their released behavior. Runtime decoding, constructor admission, canonical equality, map keys, public IDs, and Keiki exact evidence must agree.


## Progress


- [x] (2026-09-20T15:26:22Z) Milestone 1: Define explicit domain identity and canonical membership.
- [x] (2026-09-20T15:26:22Z) Milestone 2: Prove runtime and symbolic agreement before exposing equality.
- [x] (2026-09-20T15:26:22Z) Milestone 3: Propagate admission to nested and public consumers.
- [x] (2026-09-20T15:26:22Z) Milestone 4: Rehearse mixed-domain history and immutable identities.


## Surprises & Discoveries


The released TypeID dependency exposes generic parsing but its v7 checker collapses all UUID failures to `Invalid UUID part!`. Keiro therefore owns the UUID version and RFC-variant character table for both runtime admission and the exact text pattern, while retaining the old v7 failure constructor and rendered text byte-for-byte.

Generated transducers need unqualified nominal types only when a nominal projection adds a typed `Index` annotation or a literal constructor/parser is rendered. Importing every nominal expression makes write-only IDs fail the generated-output unused-import gate; excluding all enforced IDs makes projected guards fail to compile. Selecting precisely literal and projected nominals keeps both cases warning-clean.

The full DSL suite's closed inventories caught the new candidate fixture and compiled conformance component, as intended. The final corpus contains 52 registered invocations and regenerates without drift beyond the committed new fixture plus the removal of one pre-existing unused generated import.

The 1.0 review clarified that mapped wire equality is only one compatibility input and candidate-language status does not prevent persisted writes. This feature must contribute its complete supported-surface cases to Plan 289 and its public adoption example to Plan 295.


## Decision Log


2026-09-19: Add an explicit v5-or-v7 admission domain alongside the unchanged v7 default. Admission does not select or change ID generation. Exact symbolic evidence is emitted only when it covers every value that can reach the transducer, including historical decoder paths. The user requires streams and workflows to retain replayability after refactors. Tests and explicit compatibility boundaries enforce that requirement without claiming arbitrary Haskell behavior is statically provable.

2026-09-19 (validation review): Thread the selected domain into `NominalIdLeaf`, `nominalWireToken`, `idDomainContractFor`, and `contractIdDomainContractFor`. Review found all of them select the v7 contract from a constant or from the language alone, so a per-declaration domain change would have left `wireFingerprint` unchanged and could have been reported replay-neutral, letting a deploy skip its audit. Implicit-v7 tokens and ledger rows stay byte-identical.

2026-09-19 (validation review, correction): Carry the domain on the direct-ID path as well: `IdRepresentation`, `nominalRepresentationSurface`, and `nominalRepresentationSegment`. The first pass of this review threaded only the nested `nominalWireToken` path and set `capabilityFoldSegment = Nothing`; together those would have left a domain change on a directly-used ID invisible to both the replay verdict and the snapshot discriminator. The `Nothing` decision stands because identity belongs at declaration granularity, but it is only safe with this change.

2026-09-19 (validation review): Derive the runtime check and the symbolic pattern from one table of admitted versions and prove two-way agreement by property test. The pattern is exact evidence; any text the runtime admits and the pattern excludes lets the solver prove impossible something that happens.

2026-09-19 (validation review): Complete Milestone 4 on repository fixtures and move the consumer comparison to Plan 295 Milestone 3, so this plan is completable without consumer data and one plan owns consumer-history evidence.


2026-09-19 (1.0 review): Follow [ADR-47](../adr/0047-dsl-retirement-requires-complete-retained-history-evidence.md): report complete affected surfaces, preserve any already-written candidate history, and supply an executable public API example for the final adoption and retirement rehearsal. Wire equality never waives changed binding/fold or application-owned continuation evidence.

2026-09-20 (implementation): Freeze `keiro-dsl/id-domain/typeid-v5-or-v7/1` beside the unchanged `keiro-dsl/id-domain/typeid-v7/1`. Keep implicit declarations byte-identical, add explicit Language-6 syntax for the wider admission, derive runtime and symbolic membership from the same version/variant table, and carry the selected identity through direct and nested replay surfaces, ledgers, diffs, generated codecs, keys, queues, and public contracts. Generation remains unchanged and process/workflow persistence remains application-owned.


## Outcomes & Retrospective


Keiro now supports `domain=typeid-v5-or-v7` on Language-6 ID declarations while preserving the implicit v7 default and all released v7 identities. The runtime accepts only canonical prefixed Crockford encodings with UUID version 5 or 7 and an RFC variant; generated exact Keiki domains use the same table. A focused solver test proves a v5-only guard overlap satisfiable, rejects a deliberately stale v7 witness through the owner law, and leaves an opaque proof path unverified.

The compiled `id-admission-domains` corpus passes 36 assertions across direct aggregate fields and registers, required and optional nested IDs, ID-keyed maps, queue payloads, public contract payloads, mixed v5/v7 multi-event serialization, replay-only history, first-event information-loss rejection, strict replay, binding laws, projection agreement, wrong prefixes, and excluded versions. Direct and nested admission changes in either direction change their fold/replay identities, raise `IdDomainContractChanged`, and produce direction-specific rollout guidance; existing implicit-v7 bytes and fingerprints remain pinned.

Validation completed with `keiro-dsl:keiro-dsl-test` at 790 examples and zero failures, all `keiro-dsl:tests` components green, `keiro:keiro-test` at 711 examples and zero failures, all 52 corpus invocations regenerated consistently, and strict validation of all 47 ADR concepts. Real retained consumer identifiers, streams, process recovery, and workflow journals remain assigned to Plan 295; this repository proof neither claims that audit nor publishes Language 6.


## Context and Orientation


Hard dependency: [289](289-gate-mapping-evolution-with-serialized-and-cross-version-replay-evidence.md). Integration dependency with Plan 290: both extend TypeGraph and complete recursive dependency/fingerprint traversal, but this feature can use existing record shapes and does not require bare containers.

Research baseline is Keiro commit `98f07213` on 2026-09-19. Recheck the working tree before implementation. `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, `Parser/Mapped.hs`, `PrettyPrint.hs`, and `TypeGraph.hs` own syntax and its checked meaning. `AggregateType.hs` and `ConsumerTypePlan.hs` select supported Haskell types. `MappedCodecPlan.hs` and `Scaffold.hs` lower codecs and generated modules; `StructuralConformance.hs`, `Harness.hs`, and `ServiceHarness.hs` produce checks. Paths abbreviated after the first module in this paragraph are relative to `keiro-dsl/src/Keiro/Dsl/`.

The same directory's `MappedDiff.hs`, `SemanticImpact.hs`, `ReplayImpact.hs`, `FoldFingerprint.hs`, `CanonicalEncoding.hs`, `Coverage.hs`, and `ScaffoldRecord.hs` connect recursive type changes to persisted surfaces, stable identities, and generated provenance. `LanguageVersion.hs` selects capabilities; do not hard-code a guessed next language number. `keiro-core/src/Keiro/Codec/Structural.hs` and `Nominal.hs` contain consumer binding contracts. `keiro-core/src/Keiro/EventStream/Validate.hs` constructs validated runnable streams. `keiro/src/Keiro/ReplayAudit.hs` checks candidate replay and candidate snapshot/full agreement, not automatic old/new semantic equivalence.

A codec converts domain values to stored JSON and back. A total binding must satisfy both domain-to-shape-to-domain and shape-to-domain-to-shape identity. A fingerprint detects declared changes; it does not make a breaking change safe. A golden is committed historical input with provenance, never regenerated from the candidate to make a failure disappear.

The governing local decisions are [ADR-12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md), which assigns private-event JSON authority to checked declarations and requires total domain/shape bindings; [ADR-3](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md), which treats snapshots as disposable caches; [ADR-4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md), which separates single-spec checks, evolution findings, runtime validation, historical codec tests, and real-history replay; and [ADR-18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md), which freezes released behavior and canonical fingerprint encodings. [ADR-46](../adr/0046-nominal-declarations-are-structural-leaves-with-keiro-owned-admission.md) preserves nominal admission inside structural values, keyed maps, and declared public IDs. These decisions remain binding; the implementation must update their relevant explanations when adding a new supported surface.

Keiki's decisions `mori://shinzui/keiki/okf/adrs/concepts/ADR-2`, `mori://shinzui/keiki/okf/adrs/concepts/ADR-3`, and `mori://shinzui/keiki/okf/adrs/concepts/ADR-5` respectively require forward/replay agreement, conservative proof gates, and stable wire identity independent of Haskell names. A transducer is the pure machine that selects a transition, updates registers, and emits events. Replay reconstructs its input from the first event of a transition; subsequent events check the expected tail. An exact projection domain is a symbolic description of every possible concrete key, with reconstruction for every admitted key. Omitting real keys can manufacture false proofs of impossibility. Never weaken validation or invent exact evidence to get a fixture through.

The source request is [IR-46](../improvement-requests/support-explicit-legacy-id-admission-domains.md). `keiro-core/src/Keiro/Codec/IdDomain.hs` currently fixes canonical parsing, v7 validation, an SMT-compatible text pattern, and a sample. `keiro-dsl/src/Keiro/Dsl/IdDomain.hs` selects that contract by capability. `NominalType.hs` and nominal leaves use these facts. Existing legacy-language event decoders can retain historical values outside modern admission; blindly applying a narrower exact witness to them is unsound.

Four places in the current code hard-wire the v7 domain, and each must be driven by the selected domain or the feature is unsound or invisible. First, `validateIdDomainText` in `keiro-core/src/Keiro/Codec/IdDomain.hs` never reads the contract's `idDomainVersion`: it always finishes with `TypeID.checkTypeID`, the v7 check. Second, `idDomainTextPattern` in the same module hard-codes the version position as the characters `e` and `f`. The suffix is 26 Crockford base32 characters encoding two zero bits followed by the 128 UUID bits, so the UUID version nibble is the top four bits of suffix character 10 (zero-based): version 7 is `0111x`, giving `e` or `f`, and version 5 is `0101x`, giving `a` or `b`. The variant bits fall in character 13 as `x10xx`, giving the existing set `8 9 a b r s t v`. The symbolic pattern and the runtime validator must agree exactly on both positions; if the runtime admits a variant or version the pattern excludes, the solver can prove impossible something that happens. Third, `parseKindIdV7Text` and `parseKindIdV7Value` are v7-only entry points called by generated integration-contract codecs. Fourth, and most important for replay, `NominalIdLeaf` in `keiro-dsl/src/Keiro/Dsl/TypeGraph.hs` carries only a prefix, and `nominalWireToken` renders it as `nominal-id(<prefix>,<nominalIdDomainVersion>)` using a module-level constant kept byte-identical to `enforcedIdDomainVersion`. `wireFingerprint` is built from these tokens, `keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs` compares them to choose `replay-neutral` or `replay-affected`, and `keiro/src/Keiro/ReplayAudit.hs` documents that a replay-neutral deploy touches no data. As the code stands, changing a declaration's admission domain would leave its token unchanged, so a widening or narrowing could be reported replay-neutral and the deploy would skip its audit.

That token covers only IDs nested inside mapped declarations. A declared ID used directly as an aggregate field, register, or event field takes a second path that omits the domain entirely. `NominalRepresentation` in `keiro-dsl/src/Keiro/Dsl/NominalType.hs` models it as `IdRepresentation !Text`, holding only the prefix. `nominalRepresentationSurface` in `ReplayImpact.hs` renders it as `id:<prefix>` for the per-event replay surface, and `nominalRepresentationSegment` in `keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs` renders the same `id:<prefix>` into the fold fingerprint that discriminates snapshots under ADR-3. Neither mentions a domain, not even the constant. The language-level switch to enforced v7 stayed visible because its capability contributes a fold segment through `capabilityFoldSegment`; this plan's capability deliberately contributes none, so without the change below a narrowing from v5-or-v7 to v7 on a directly-used ID would be reported `replay-neutral` and leave snapshots valid while retained v5 events stop decoding. The nested and direct paths must both carry the domain.


## Plan of Work


### Milestone 1 — Define explicit domain identity and canonical membership


Extend the runtime IdDomainContract with a closed supported domain selector while preserving the existing serialized v7 identity and byte behavior. The new domain accepts only canonical existing prefixed Crockford-encoded identifiers whose UUID has RFC variant bits and version 5 or 7. It is not a second hyphenated UUID syntax. Preserve prefix, separator, length, leading-bit, and lowercase rules; reject wrong prefix/variant/version and malformed text. Add an explicit declaration option through Grammar, Parser/Declaration, TypeGraph, and LanguageVersion. Keep existing generation APIs and deterministic namespace/seed derivations unchanged. A declaration chooses admission; generation policy must produce values inside that admission. Make `validateIdDomainText` dispatch on the closed selector instead of always calling the v7 check, and keep Keiro as the owner of the version and variant test rather than delegating the v5 decision to the TypeID dependency, so the frozen contract cannot drift with a dependency upgrade. The existing v7 contract keeps its identity string `keiro-dsl/id-domain/typeid-v7/1` and its `idDomainIdentity` rendering byte-for-byte; the new domain gets its own versioned identity string. `IdDomainFailure` is an exported sum type, so adding a failure constructor for the new domain is a breaking API change to `keiro-core`; keep `IdDomainNotUuidV7` and its rendered message unchanged for the v7 domain and record the version-bound consequence. The v5-or-v7 domain v1 identity freezes at the first package release that contains it, even while the language capability is still a candidate, because a consumer on the candidate language can write durable events from that release onward. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 2 — Prove runtime and symbolic agreement before exposing equality


Generate the exact text-domain union using the same checked domain facts as decoding, through the released Keiki ProjectionDomain APIs. For the v5-or-v7 domain the only difference from the existing pattern is the version position's character set, `a b e f` instead of `e f`; derive both the runtime check and the pattern from one table of admitted versions so they cannot disagree, and add a property test that every text the pattern admits passes `validateIdDomainText` and every text the validator admits matches the pattern, over generated boundary values at the version and variant positions. Test owners-to-domain and keys-to-owner-to-key laws for generated and consumer-bound IDs, positive v5/v7 samples, excluded versions, variants, boundary encodings, and a deliberately stale v7-only witness. Add a guard-overlap case reachable only through v5 that must never be blessed as disjoint. Test proof-unknown paths conservatively. Audit historical constructors: if a transducer may receive arbitrary legacy text, its domain must truthfully include that reachable carrier or remain one-way/unverified; historical decoder support cannot be traded for a dishonest exact claim. Preserve declaration-scoped equality and do not add ID ordering expressions. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 3 — Propagate admission to nested and public consumers


Update `NominalType.hs`, `TypeGraph.hs`, `MappedCodecPlan.hs`, `Scaffold.hs`, integration-contract lowering, keyed-map codecs, canonical ordering conformance, router recipient identities, ExplainBindings, fingerprints, snapshots, coverage, and diff. Every supported use preserves the selected domain; unsupported public combinations fail checking instead of calling the v7 parser. `parseKindIdV7Text` and `parseKindIdV7Value` stay v7-only and keep their names and behavior; add domain-parameterized entry points beside them and have generated contract codecs choose by the declaration's domain. Thread the selected domain into `NominalIdLeaf` and into `nominalWireToken`, replacing the module-level `nominalIdDomainVersion` constant with the leaf's own domain identity, while keeping the token for an implicit-v7 declaration byte-identical to today's `nominal-id(<prefix>,keiro-dsl/id-domain/typeid-v7/1)` so no existing `wireFingerprint` changes. This covers nominal leaves inside mapped declarations, keyed-map keys (`RKeyedMap` renders its key through the same token), and nested structural uses at once. It does not cover a declared ID used directly as an aggregate field, register, or event field. For that path, carry the selected domain in `IdRepresentation` (`NominalType.hs`) and render it in both `nominalRepresentationSurface` (`ReplayImpact.hs`) and `nominalRepresentationSegment` (`FoldFingerprint.hs`), keeping the rendering for an implicit-v7 declaration byte-identical to today's `id:<prefix>` so no existing replay surface, fold fingerprint, or snapshot discriminator changes. `IdRepresentation` is matched in about a dozen modules (Scaffold, Validate, AggregateType, MappedConsumer, Harness, Goldens, Manifest, ExplainBindings, RouterSelection among them); widening the constructor forces each to be revisited, which is the intent. The verdict tests must therefore use two fixtures, one with the ID nested in a structural record and one with the ID as a direct event field and register, and each must show the domain change is `replay-affected` and changes the fold fingerprint. Test that v7-to-v5-or-v7 and the reverse are each `replay-affected` through `ReplayImpact.hs`, never `replay-neutral`, and that the existing corpus's fingerprints are unchanged. The new `RuntimeCapability` constructor takes `capabilityFoldSegment = Nothing`: domain identity flows through the wire token, and a segment would re-fingerprint every candidate-language service. Two further consumers select a contract from the language alone and must learn the declaration's choice. `idDomainContractFor` and `contractIdDomainContractFor` in `keiro-dsl/src/Keiro/Dsl/IdDomain.hs` take only the language contract and a prefix; `idDomainIdentitiesForService` uses them to write the `id-domain` rows of the scaffold ledger (`ScaffoldRecord.hs`, `WorkspaceRecord.hs`), and `idDomainContractChanges` in `keiro-dsl/src/Keiro/Dsl/Diff.hs` uses them to raise the breaking `IdDomainContractChanged` finding when the old and new contracts differ. Pass the declaration so that a per-declaration domain change changes the recorded identity and raises that finding. Its current message promises that historical event replay retains its legacy decoder, which describes the legacy-language boundary and would be false for a narrowing from v5-or-v7 to v7, where retained v5 events stop decoding; make the message direction-specific and truthful. Report widening as an old-reader/new-writer hazard and narrowing as a historical-read hazard. Preserve released-language fixtures, including legacy historical decoding. Add `keiro-dsl/test/fixtures/id-admission-domains.keiro` and a registered conformance suite exercising direct/nested/optional-in-record IDs, ID map keys, public contracts, and queues. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 4 — Rehearse mixed-domain history and immutable identities


Build a repository fixture history that mixes historical-style and newly produced v5 and v7 values, modeled on how consumer `mori://shinzui/rei` derives its identifiers as read from its source through Mori. Test unchanged stream names, event identities, router keys, workflow/child/timer identities, and deterministic content-derived IDs before and after binding adoption. Use Plan 289 baseline/candidate replay and rolling-reader reports. This milestone completes on repository fixtures, labeled as such. The comparison against the consumer's real retained identifiers is owned by [Plan 295](295-rehearse-checked-mapping-adoption-against-historical-streams-and-workflow-journals.md) Milestone 3 and is not required here, so this plan does not depend on access to consumer data. Adding a domain is not permission to regenerate an identifier. Retain old historical readers or representation paths where required; if total historical reconstruction is impossible, keep the opaque consumer mapping and mark adoption unverified. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


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

Existing implicit-v7 declarations still reject v5; explicit-v5-or-v7 declarations accept valid samples of both and reject all tested wrong variants/prefixes/versions. Exact witness owner coverage includes historical reachable values, not only newly constructible IDs. A stale v7-only domain mutation fails conformance or remains unverified, never producing a successful proof. Mixed streams replay with identical identifiers and durable state. The symbolic pattern and the runtime validator admit exactly the same texts under the two-way property test. Changing a declaration's domain in either direction raises `IdDomainContractChanged` and yields a `replay-affected` verdict and a changed fold fingerprint, shown separately for an ID nested in a structural record (through `wireFingerprint`) and for an ID used as a direct event field and register (through the nominal replay surface); every declaration in the existing corpus keeps its fingerprint and ledger `id-domain` row byte-for-byte.

For every admitted value, generated encoding followed by decoding must recover the same domain value, and the generated binding must satisfy both inverse laws. Exercise forward execution followed by actual event-envelope serialization, decoding, and strict replay; compare control state and all durable registers at every completed transition. Include multi-event output, replay-only transitions, and a negative head-information-loss case. A same-version in-memory replay test alone does not pass this requirement.

For each affected persisted surface, run the compatibility gate from Plan 289. Preserve genuine old bytes, tags, versions, and readers. Compare baseline and candidate interpretations under the same versioned, non-lossy observation contract; investigate the first divergent prefix. Test old-reader/new-writer compatibility separately. A narrowed domain, altered normalization, or opaque-to-checked conversion is never automatically replay-neutral. Keep historical adapters total for retained history; if history cannot be represented without loss, retain the old representation/handler and refuse adoption.

Reject unsupported symbolic operations during checking. Exact-domain evidence must include concrete-owner membership and admitted-key reconstruction, not merely a successful solver model. Unknown required evidence stays unverified and blocks the preservation claim at the applicable feature, publication, adoption, or retirement gate. Published-language acceptance, generated bytes, and frozen identities remain unchanged unless an explicit migration is part of a separate reviewed change. Any opaque nested boundary keeps its unverified status; wrapping it in a checked container does not certify it.

Workflow adoption must additionally preserve journal semantics with actual application codecs. Run old journal prefixes through candidate continuation in an isolated test environment with recorded effects; do not execute production side effects in an audit. Persisted-result decode failure must fail clearly, never be treated as a missing step and rerun. Pure refactors must retain stable names and existing results without extra actions. No snapshot invalidation, token bump, or green finite fixture suite alone proves compatibility with all stored history.


A pure refactor must preserve wire kinds/keys, version dispatch, canonical identities, initial-state meaning, and historical readers. An intentional semantic change is not relabeled a refactor: introduce explicit event versions/upcasters or retained replay-only behavior, and preserve the old interpretation for old history. Never skip an undecodable event, drop a failed workflow result, relax Keiki validation, or rewrite historical bytes to obtain a green result. Replay-only guard remedies do not repair a codec that has already rejected or changed the event.

Evidence is tied to the audited high-water marks. Concurrent writes beyond those marks require a tail audit or a controlled writer cutover before adoption. An old-reader/new-writer failure requires a documented staged rollout that keeps incompatible writes disabled until old readers are gone; it is not historical-read success. The report must retain the failed direction and the explicit rollout precondition, and automatic simultaneous-version compatibility must remain refused.

## Idempotence and Recovery


All generation and tests run in the repository checkout or an isolated fixture database. Regenerate replaceable modules through the public corpus driver; preserve create-once bindings and historical fixtures. Retry failures after fixing the owning implementation, never by accepting new historical goldens. Do not rewrite production events, journal rows, IDs, step keys, or deterministic seeds. Keep new authoring capability promotion blocked until its evidence passes. Candidate status does not prevent durable writes: any package release containing a new wire policy requires committed compatibility vectors and freezes that policy identity. Removing an already-shipped candidate capability must preserve its historical read/replay path or be blocked. Before new-format writes, rollback can retain the previous readers; after incompatible writes, use a documented forward repair or retain compatible readers rather than assuming a binary downgrade is safe. A production migration, release, or cross-repository rollout is a separate authorized action.


## Interfaces and Dependencies


One checked IdDomainContract drives admission, text pattern, canonical identity, samples, generated/public codecs, and nested key/value uses. Add domains by versioned constructors, not caller-supplied regexes. Public construction restrictions and historical internal constructors are distinct surfaces whose combined reachable carrier determines proof strength.

Use the existing checked graph and total folds rather than separate per-generator allowlists. New checked constructors must be handled exhaustively by codecs, nullability, dependency traversal, fingerprints, diff, coverage, scaffolding, deterministic fixtures, and every admitted use-site lowerer. A clean check must imply complete generation. Keep consumer binding signatures total; JSON validation happens before binding conversion. Stable wire identity is independent of source module names, selectors, constructor presentation, and dependency traversal order.

Before using dependency APIs run `mori registry list`, `mori registry search <package>`, `mori registry show <qualified-project> --full`, and `mori registry docs <qualified-project>`, then read the located source. Relevant projects are `mori://shinzui/keiki`, `mori://haskell/aeson`, and consumer `mori://shinzui/rei`. If changing a dependency bound, verify the authoritative package registry and upstream release tags first; local source is not release evidence. No Keiki dependency change is assumed. If required evidence cannot be expressed by the released API, stop capability promotion and coordinate an explicit upstream change, never substitute a dishonest witness.

Revision note (2026-09-19): Linked the Mina-created intention and clarified retained-reader, strict-failure, audit-tail, and rolling-reader obligations during authoring review. No implementation or historical audit has run.

Revision note (2026-09-19, validation review): Context now names the four places that hard-wire the v7 domain and explains the version and variant character positions. Milestone 1 makes validation dispatch on the selector and records the identity, API, and freeze-point consequences. Milestone 2 derives validator and pattern from one table with a two-way property test. Milestone 3 threads the domain through the wire token, the contract selectors, the ledger rows, and the `IdDomainContractChanged` finding. Milestone 4 is rescoped to repository fixtures, with the consumer comparison moved to Plan 295. No implementation has run.

Revision note (2026-09-19, validation review correction): A follow-up check found that directly-used declared IDs reach the replay surface and the fold fingerprint through `IdRepresentation`, which renders `id:<prefix>` with no domain. Context, Milestone 3, the acceptance criteria, and the Decision Log now require the domain on that path too, with separate nested and direct fixtures.

Revision note (2026-09-19, 1.0 review): Added the pre-1.0 API acceptance contract, complete evidence obligations, and safe candidate-policy retention. Accepted language and runtime behavior remain unchanged. See ADR-47. No implementation or historical audit has run.

Revision note (2026-09-20, implementation): Completed the explicit UUIDv5-or-v7 admission domain, shared runtime/symbolic membership table, conservative Keiki proof cases, direct and nested replay identity propagation, generated/public/keyed-map/queue consumers, compiled repository history, supported-use documentation, and ADR updates. Marked Plan 294 complete after full regression and corpus validation; consumer history, Language 6 publication, and retirement remain Plan 295 work.
