---
id: 290
slug: support-named-bare-container-structural-mappings-with-transitive-nullability
title: "Support named bare container structural mappings with transitive nullability"
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

# Support named bare container structural mappings with transitive nullability


This ExecPlan is a living document. Keep its execution sections current; distill durable decisions into ADRs during implementation. This document authorizes planned implementation scope, not production migration or a claim of completed replay proof.


## Purpose / Big Picture


Implement IR-42 so a named structural mapping can encode a bare optional value, list, or text-keyed map while retaining the consumer Haskell type and the existing total binding laws. Users can remove unnecessary opaque container boundaries without inserting an object wrapper or silently collapsing null alternatives.


## Progress


- [ ] Milestone 1: Introduce checked bare-expression declarations.
- [ ] Milestone 2: Make nullability recursive and lower bare codecs.
- [ ] Milestone 3: Propagate identity and prove migration behavior.


## Surprises & Discoveries


None recorded during implementation yet.


## Decision Log


2026-09-19: Add a checked bare-shape constructor with recursive nullability. Preserve named aggregate use sites and direct-container restrictions. An opaque-to-structural migration always requires explicit compatibility evidence. The user requires streams and workflows to retain replayability after refactors. Tests and explicit compatibility boundaries enforce that requirement without claiming arbitrary Haskell behavior is statically provable.


## Outcomes & Retrospective


Not implemented. Record results and remaining adoption obligations here; plan creation is not implementation completion.


## Context and Orientation


Hard dependency: [289](289-gate-mapping-evolution-with-serialized-and-cross-version-replay-evidence.md) supplies the serialized replay tests and compatibility report contract. This plan owns the bare-expression declaration mechanism consumed by Plans 291–293.

Research baseline is Keiro commit `98f07213` on 2026-09-19. Recheck the working tree before implementation. `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, `Parser/Mapped.hs`, `PrettyPrint.hs`, and `TypeGraph.hs` own syntax and its checked meaning. `AggregateType.hs` and `ConsumerTypePlan.hs` select supported Haskell types. `MappedCodecPlan.hs` and `Scaffold.hs` lower codecs and generated modules; `StructuralConformance.hs`, `Harness.hs`, and `ServiceHarness.hs` produce checks. Paths abbreviated after the first module in this paragraph are relative to `keiro-dsl/src/Keiro/Dsl/`.

The same directory's `MappedDiff.hs`, `SemanticImpact.hs`, `ReplayImpact.hs`, `FoldFingerprint.hs`, `CanonicalEncoding.hs`, `Coverage.hs`, and `ScaffoldRecord.hs` connect recursive type changes to persisted surfaces, stable identities, and generated provenance. `LanguageVersion.hs` selects capabilities; do not hard-code a guessed next language number. `keiro-core/src/Keiro/Codec/Structural.hs` and `Nominal.hs` contain consumer binding contracts. `keiro-core/src/Keiro/EventStream/Validate.hs` constructs validated runnable streams. `keiro/src/Keiro/ReplayAudit.hs` checks candidate replay and candidate snapshot/full agreement, not automatic old/new semantic equivalence.

A codec converts domain values to stored JSON and back. A total binding must satisfy both domain-to-shape-to-domain and shape-to-domain-to-shape identity. A fingerprint detects declared changes; it does not make a breaking change safe. A golden is committed historical input with provenance, never regenerated from the candidate to make a failure disappear.

The governing local decisions are [ADR-12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md), which assigns private-event JSON authority to checked declarations and requires total domain/shape bindings; [ADR-3](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md), which treats snapshots as disposable caches; [ADR-4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md), which separates single-spec checks, evolution findings, runtime validation, historical codec tests, and real-history replay; and [ADR-18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md), which freezes released behavior and canonical fingerprint encodings. [ADR-46](../adr/0046-nominal-declarations-are-structural-leaves-with-keiro-owned-admission.md) preserves nominal admission inside structural values, keyed maps, and declared public IDs. These decisions remain binding; the implementation must update their relevant explanations when adding a new supported surface.

Keiki's decisions `mori://shinzui/keiki/okf/adrs/concepts/ADR-2`, `mori://shinzui/keiki/okf/adrs/concepts/ADR-3`, and `mori://shinzui/keiki/okf/adrs/concepts/ADR-5` respectively require forward/replay agreement, conservative proof gates, and stable wire identity independent of Haskell names. A transducer is the pure machine that selects a transition, updates registers, and emits events. Replay reconstructs its input from the first event of a transition; subsequent events check the expected tail. An exact projection domain is a symbolic description of every possible concrete key, with reconstruction for every admitted key. Omitting real keys can manufacture false proofs of impossibility. Never weaken validation or invent exact evidence to get a fixture through.

The source request is [IR-42](../improvement-requests/support-bare-container-structural-mappings.md). Today `MappedShape` contains records, enums, and unions. `hasNonInjectiveOptional` in `keiro-dsl/src/Keiro/Dsl/Validate.hs` assumes all structural references are non-null; that assumption must be removed before accepting aliases of nullable shapes.


## Plan of Work


### Milestone 1 — Introduce checked bare-expression declarations


Extend `Grammar.hs`, `Parser/Mapped.hs`, `PrettyPrint.hs`, `TypeGraph.hs`, and `LanguageVersion.hs` with one explicit bare-expression declaration branch and a named candidate capability. Choose and document an unambiguous spelling in parser/pretty-print tests before generation; examples in IR-42 are semantic, not previously accepted syntax. The initial outer constructors are Optional, List, and text-keyed Map, with recursive existing admissible expressions and nominal leaves. Resolve references with the current cycle rejection rules. Expose a checked shape branch containing one ResolvedTypeExpr; reserve extension to the checked scalar and set constructors supplied by dependent plans. Older-language parsing/checking behavior stays frozen. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 2 — Make nullability recursive and lower bare codecs


Replace the structural-is-non-null assumption with graph-derived top-level nullability and invalid-optional facts, computed through references with cycle-safe traversal. Reject `Optional (Optional Text)`, the same shape hidden behind multiple aliases, and optional Json/opaque leaves. Lists/maps remain non-null while their element errors propagate. In `MappedCodecPlan.hs`, `ConsumerTypePlan.hs`, and `Scaffold.hs`, generate leaf shape modules and codecs without an object wrapper. Use domain/shape binding at consumer boundaries and shape codecs for nested structural references. Preserve field-presence behavior independently: a required field whose value is Optional must be present; explicit null is a value, not omission. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 3 — Propagate identity and prove migration behavior


Extend all TypeGraph folds, `MappedDiff.hs`, `FoldFingerprint.hs`, `Coverage.hs`, `Goldens.hs`, `StructuralConformance.hs`, and scaffold records. Add `keiro-dsl/test/fixtures/bare-containers.keiro` and a registered `conformance-bare-containers` suite with empty/present optionals, ordered duplicate lists, text maps, nested nominal values, unused declarations, register initials, workspace ownership, queues, and read-model query types. Queries remain Haskell-value contracts without invented JSON policy. Keep public-contract containers unsupported unless separately implemented. Compare old opaque codecs through `CodecCompare.hs` and Plan 289; do not turn finite parity into a structural proof for opaque leaves. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


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


A Maybe Text mapping encodes Nothing as null and Just "x" as "x"; a list ["b","a","a"] keeps all three entries; a map encodes as an object. The checker refuses nullable aliases before scaffold writes anything. Missing required enclosing fields fail while present null succeeds. Serialized replay reproduces values and state. A changed source selector with unchanged wire identity passes the refactor gate; inserting a record wrapper fails.

For every admitted value, generated encoding followed by decoding must recover the same domain value, and the generated binding must satisfy both inverse laws. Exercise forward execution followed by actual event-envelope serialization, decoding, and strict replay; compare control state and all durable registers at every completed transition. Include multi-event output, replay-only transitions, and a negative head-information-loss case. A same-version in-memory replay test alone does not pass this requirement.

For each affected persisted surface, run the compatibility gate from Plan 289. Preserve genuine old bytes, tags, versions, and readers. Compare baseline and candidate interpretations under the same versioned, non-lossy observation contract; investigate the first divergent prefix. Test old-reader/new-writer compatibility separately. A narrowed domain, altered normalization, or opaque-to-checked conversion is never automatically replay-neutral. Keep historical adapters total for retained history; if history cannot be represented without loss, retain the old representation/handler and refuse adoption.

Reject unsupported symbolic operations during checking. Exact-domain evidence must include concrete-owner membership and admitted-key reconstruction, not merely a successful solver model. Unknown evidence stays unverified and blocks a release claiming preservation. Published-language acceptance, generated bytes, and frozen identities remain unchanged unless an explicit migration is part of a separate reviewed change. Any opaque nested boundary keeps its unverified status; wrapping it in a checked container does not certify it.

Workflow adoption must additionally preserve journal semantics with actual application codecs. Run old journal prefixes through candidate continuation in an isolated test environment with recorded effects; do not execute production side effects in an audit. Persisted-result decode failure must fail clearly, never be treated as a missing step and rerun. Pure refactors must retain stable names and existing results without extra actions. No snapshot invalidation, token bump, or green finite fixture suite alone proves compatibility with all stored history.


A pure refactor must preserve wire kinds/keys, version dispatch, canonical identities, initial-state meaning, and historical readers. An intentional semantic change is not relabeled a refactor: introduce explicit event versions/upcasters or retained replay-only behavior, and preserve the old interpretation for old history. Never skip an undecodable event, drop a failed workflow result, relax Keiki validation, or rewrite historical bytes to obtain a green result. Replay-only guard remedies do not repair a codec that has already rejected or changed the event.

Evidence is tied to the audited high-water marks. Concurrent writes beyond those marks require a tail audit or a controlled writer cutover before adoption. An old-reader/new-writer failure requires a documented staged rollout that keeps incompatible writes disabled until old readers are gone; it is not historical-read success. The report must retain the failed direction and the explicit rollout precondition, and automatic simultaneous-version compatibility must remain refused.

## Idempotence and Recovery


All generation and tests run in the repository checkout or an isolated fixture database. Regenerate replaceable modules through the public corpus driver; preserve create-once bindings and historical fixtures. Retry failures after fixing the owning implementation, never by accepting new historical goldens. Do not rewrite production events, journal rows, IDs, step keys, or deterministic seeds. Keep the feature on an unpublished capability until its evidence passes. Before new-format writes, rollback can retain the previous readers; after incompatible writes, use a documented forward repair or retain compatible readers rather than assuming a binary downgrade is safe. A production migration, release, or cross-repository rollout is a separate authorized action.


## Interfaces and Dependencies


Add a single shape-algebra branch for a bare ResolvedTypeExpr and one authoritative graph nullability query. Dependent plans extend supported checked expression constructors through this branch; they must not reimplement nullable-reference checks. Existing `StructuralBinding domain shape` remains unchanged.

Use the existing checked graph and total folds rather than separate per-generator allowlists. New checked constructors must be handled exhaustively by codecs, nullability, dependency traversal, fingerprints, diff, coverage, scaffolding, deterministic fixtures, and every admitted use-site lowerer. A clean check must imply complete generation. Keep consumer binding signatures total; JSON validation happens before binding conversion. Stable wire identity is independent of source module names, selectors, constructor presentation, and dependency traversal order.

Before using dependency APIs run `mori registry list`, `mori registry search <package>`, `mori registry show <qualified-project> --full`, and `mori registry docs <qualified-project>`, then read the located source. Relevant projects are `mori://shinzui/keiki`, `mori://haskell/aeson`, and consumer `mori://shinzui/rei`. If changing a dependency bound, verify the authoritative package registry and upstream release tags first; local source is not release evidence. No Keiki dependency change is assumed. If required evidence cannot be expressed by the released API, stop capability promotion and coordinate an explicit upstream change, never substitute a dishonest witness.

Revision note (2026-09-19): Linked the Mina-created intention and clarified retained-reader, strict-failure, audit-tail, and rolling-reader obligations during authoring review. No implementation or historical audit has run.
