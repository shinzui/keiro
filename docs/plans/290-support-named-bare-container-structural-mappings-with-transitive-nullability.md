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
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-19T22:13:45Z
      mode: "update"
      note: "Specify bare wire token and verdict tests; extend on-missing defaults through bare references."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-19T22:32:09Z
      mode: "update"
      note: "Corrected wire-neutral alias versus full replay verdict; added executable API matrix and candidate-history obligations."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T01:11:01Z
      mode: "implement"
      note: "Implement named bare-container mappings, recursive nullability, lowering, and compatibility evidence."
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-19T22:13:44Z
      verdict: "changes-requested"
      note: "Bare wire token unspecified; on-missing defaults cannot reach named aliases, so histories omitting absent optionals could not adopt."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-19T22:32:09Z
      verdict: "approved"
      note: "Corrected wire-neutral alias versus full replay verdict; added executable API matrix and candidate-history obligations."
---

# Support named bare container structural mappings with transitive nullability


This ExecPlan is a living document. Keep its execution sections current; distill durable decisions into ADRs during implementation. This document authorizes planned implementation scope, not production migration or a claim of completed replay proof.


## Purpose / Big Picture


This is a pre-1.0 DSL/API work stream. The improvement request below is a concrete use case; success also requires a usable public authoring path and compatibility evidence that makes later implementation consolidation safe.

Implement IR-42 so a named structural mapping can encode a bare optional value, list, or text-keyed map while retaining the consumer Haskell type and the existing total binding laws. Users can remove unnecessary opaque container boundaries without inserting an object wrapper or silently collapsing null alternatives.


## Progress


- [x] (2026-09-20T01:11:01Z) Milestone 1: Introduced the language-6 `mapped structural value` declaration, checked graph branch, pretty-print round trip, and candidate syntax/runtime capabilities.
- [x] (2026-09-20T01:11:01Z) Milestone 2: Derived nullability and missing-value defaults transitively through bare aliases, rejected nested nullable forms, and lowered direct-container aliases/codecs without object wrappers.
- [ ] Milestone 3: Propagate identity and prove migration behavior.


## Surprises & Discoveries


The existing resolved-expression algebra already carried every recursive container and nominal-leaf case needed by bare declarations. Reusing it kept dependency traversal, Haskell type selection, and nested codec lowering authoritative rather than introducing a parallel allowlist.

The shape renderer parenthesizes a top-level container expression (`type MaybeTextShape = (Maybe Text)`). This is presentation-only; the checked wire token remains exactly the inner expression and therefore stays equal to the inline form.

The 1.0 review clarified that mapped wire equality is only one compatibility input and candidate-language status does not prevent persisted writes. This feature must contribute its complete supported-surface cases to Plan 289 and its public adoption example to Plan 295.


## Decision Log


2026-09-19: Add a checked bare-shape constructor with recursive nullability. Preserve named aggregate use sites and direct-container restrictions. An opaque-to-structural migration always requires explicit compatibility evidence. The user requires streams and workflows to retain replayability after refactors. Tests and explicit compatibility boundaries enforce that requirement without claiming arbitrary Haskell behavior is statically provable.

2026-09-19 (validation review): Render a bare declaration's wire token as its inner expression, so tokens describe wire form rather than declaration structure. Inline-to-alias extraction then preserves wire identity, while opaque-to-bare changes it. Complete replay and snapshot verdicts still consider provenance and fold surfaces; wire equality alone must not suppress those findings.

2026-09-19 (validation review): Admit on-missing defaults through bare references. Without this a consumer whose retained events omit the key for an absent optional could not adopt a named alias without losing the ability to read that history.


2026-09-19 (1.0 review): Follow [ADR-47](../adr/0047-dsl-retirement-requires-complete-retained-history-evidence.md): report complete affected surfaces, preserve any already-written candidate history, and supply an executable public API example for the final adoption and retirement rehearsal. Wire equality never waives changed binding/fold or application-owned continuation evidence.

2026-09-20 (implementation): Spell the new declaration `mapped structural value Name { ... wire <TypeExpr> }`. `value` is a language-6-gated declaration kind, while `wire` reuses the existing mapped expression grammar. Bare mappings are restricted to Optional, List, and text-keyed Map roots; nested expressions and references use the checked graph recursively.


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


Replace the structural-is-non-null assumption with graph-derived top-level nullability and invalid-optional facts, computed through references with cycle-safe traversal. Reject `Optional (Optional Text)`, the same shape hidden behind multiple aliases, and optional Json/opaque leaves. Lists/maps remain non-null while their element errors propagate. In `MappedCodecPlan.hs`, `ConsumerTypePlan.hs`, and `Scaffold.hs`, generate leaf shape modules and codecs without an object wrapper. Use domain/shape binding at consumer boundaries and shape codecs for nested structural references. Preserve field-presence behavior independently: a required field whose value is Optional must be present; explicit null is a value, not omission. Extend `defaultMatches`, `defaultType`, and `referencedDefaultType` in `Validate.hs` through bare references: today `referencedDefaultType` returns `DefaultOther` for every non-enum shape, so a field declared `optional on-missing=null` cannot reference a named optional alias, and likewise `on-missing=[]` or an empty map cannot reference a named list or map alias. This matters for retained history, not only ergonomics. Consumer records written by Aeson with `omitNothingFields` omit the key for `Nothing`, and Aeson's generic reader accepts a missing key for a `Maybe` field, so a consumer replacing an opaque optional with a named alias must be able to declare the same missing-key policy or its old events stop decoding. Admit the on-missing default exactly when it would be admitted for the alias's inner expression written inline, and reject it otherwise. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 3 — Propagate identity and prove migration behavior


Extend all TypeGraph folds, `MappedDiff.hs`, `FoldFingerprint.hs`, `Coverage.hs`, `Goldens.hs`, `StructuralConformance.hs`, and scaffold records. The fold that matters most for replay is `wireFingerprint` in `TypeGraph.hs`: `ReplayImpact.hs` combines this wire identity with transitions, initial state, binding/fold provenance, and direct nominal surfaces. Render a bare declaration as the token of its inner expression with no wrapper and no declaration name. `RRef` already inlines a referenced declaration this way, so extracting an inline `Optional Text` field into a named alias preserves mapped wire identity, while an opaque-to-bare change still differs because the opaque token is `opaque(identity,version)` and `MappedModeCrossed` fires. Tokens for every existing declaration stay byte-identical. Test all three wire identities: inline-to-alias is equal, opaque-to-bare differs, and inserting a record wrapper differs. Also assert the full diff/replay and snapshot outcomes at actual use sites. An alias added inside a mapped event or register can preserve JSON while changing graph/provenance or register type identity; a conservative affected verdict or cache invalidation is legitimate and must not be suppressed to force a neutral result. The baseline/candidate semantic comparison, not a neutral label, establishes the refactor's compatibility. The new `RuntimeCapability` constructor takes `capabilityFoldSegment = Nothing`, like `StructuralNominalLeaves`, so services that do not use bare declarations keep their fold fingerprints. Add `keiro-dsl/test/fixtures/bare-containers.keiro` and a registered `conformance-bare-containers` suite with empty/present optionals, ordered duplicate lists, text maps, nested nominal values, unused declarations, register initials, workspace ownership, queues, and read-model query types. Queries remain Haskell-value contracts without invented JSON policy. Keep public-contract containers unsupported unless separately implemented. Compare old opaque codecs through `CodecCompare.hs` and Plan 289; do not turn finite parity into a structural proof for opaque leaves. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


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

A Maybe Text mapping encodes Nothing as null and Just "x" as "x"; a list ["b","a","a"] keeps all three entries; a map encodes as an object. The checker refuses nullable aliases before scaffold writes anything. Missing required enclosing fields fail while present null succeeds. Serialized replay reproduces values and state. A changed source selector with unchanged wire identity passes the refactor gate; inserting a record wrapper fails. A field declared `optional on-missing=null` that references a named optional alias checks cleanly, decodes a payload that omits the key to the empty optional, and decodes an explicit null to the same value; the same on-missing default against a non-nullable alias is rejected by the checker.

For every admitted value, generated encoding followed by decoding must recover the same domain value, and the generated binding must satisfy both inverse laws. Exercise forward execution followed by actual event-envelope serialization, decoding, and strict replay; compare control state and all durable registers at every completed transition. Include multi-event output, replay-only transitions, and a negative head-information-loss case. A same-version in-memory replay test alone does not pass this requirement.

For each affected persisted surface, run the compatibility gate from Plan 289. Preserve genuine old bytes, tags, versions, and readers. Compare baseline and candidate interpretations under the same versioned, non-lossy observation contract; investigate the first divergent prefix. Test old-reader/new-writer compatibility separately. A narrowed domain, altered normalization, or opaque-to-checked conversion is never automatically replay-neutral. Keep historical adapters total for retained history; if history cannot be represented without loss, retain the old representation/handler and refuse adoption.

Reject unsupported symbolic operations during checking. Exact-domain evidence must include concrete-owner membership and admitted-key reconstruction, not merely a successful solver model. Unknown required evidence stays unverified and blocks the preservation claim at the applicable feature, publication, adoption, or retirement gate. Published-language acceptance, generated bytes, and frozen identities remain unchanged unless an explicit migration is part of a separate reviewed change. Any opaque nested boundary keeps its unverified status; wrapping it in a checked container does not certify it.

Workflow adoption must additionally preserve journal semantics with actual application codecs. Run old journal prefixes through candidate continuation in an isolated test environment with recorded effects; do not execute production side effects in an audit. Persisted-result decode failure must fail clearly, never be treated as a missing step and rerun. Pure refactors must retain stable names and existing results without extra actions. No snapshot invalidation, token bump, or green finite fixture suite alone proves compatibility with all stored history.


A pure refactor must preserve wire kinds/keys, version dispatch, canonical identities, initial-state meaning, and historical readers. An intentional semantic change is not relabeled a refactor: introduce explicit event versions/upcasters or retained replay-only behavior, and preserve the old interpretation for old history. Never skip an undecodable event, drop a failed workflow result, relax Keiki validation, or rewrite historical bytes to obtain a green result. Replay-only guard remedies do not repair a codec that has already rejected or changed the event.

Evidence is tied to the audited high-water marks. Concurrent writes beyond those marks require a tail audit or a controlled writer cutover before adoption. An old-reader/new-writer failure requires a documented staged rollout that keeps incompatible writes disabled until old readers are gone; it is not historical-read success. The report must retain the failed direction and the explicit rollout precondition, and automatic simultaneous-version compatibility must remain refused.

## Idempotence and Recovery


All generation and tests run in the repository checkout or an isolated fixture database. Regenerate replaceable modules through the public corpus driver; preserve create-once bindings and historical fixtures. Retry failures after fixing the owning implementation, never by accepting new historical goldens. Do not rewrite production events, journal rows, IDs, step keys, or deterministic seeds. Keep new authoring capability promotion blocked until its evidence passes. Candidate status does not prevent durable writes: any package release containing a new wire policy requires committed compatibility vectors and freezes that policy identity. Removing an already-shipped candidate capability must preserve its historical read/replay path or be blocked. Before new-format writes, rollback can retain the previous readers; after incompatible writes, use a documented forward repair or retain compatible readers rather than assuming a binary downgrade is safe. A production migration, release, or cross-repository rollout is a separate authorized action.


## Interfaces and Dependencies


Add a single shape-algebra branch for a bare ResolvedTypeExpr and one authoritative graph nullability query. Dependent plans extend supported checked expression constructors through this branch; they must not reimplement nullable-reference checks. Existing `StructuralBinding domain shape` remains unchanged.

Use the existing checked graph and total folds rather than separate per-generator allowlists. New checked constructors must be handled exhaustively by codecs, nullability, dependency traversal, fingerprints, diff, coverage, scaffolding, deterministic fixtures, and every admitted use-site lowerer. A clean check must imply complete generation. Keep consumer binding signatures total; JSON validation happens before binding conversion. Stable wire identity is independent of source module names, selectors, constructor presentation, and dependency traversal order.

Before using dependency APIs run `mori registry list`, `mori registry search <package>`, `mori registry show <qualified-project> --full`, and `mori registry docs <qualified-project>`, then read the located source. Relevant projects are `mori://shinzui/keiki`, `mori://haskell/aeson`, and consumer `mori://shinzui/rei`. If changing a dependency bound, verify the authoritative package registry and upstream release tags first; local source is not release evidence. No Keiki dependency change is assumed. If required evidence cannot be expressed by the released API, stop capability promotion and coordinate an explicit upstream change, never substitute a dishonest witness.

Revision note (2026-09-19): Linked the Mina-created intention and clarified retained-reader, strict-failure, audit-tail, and rolling-reader obligations during authoring review. No implementation or historical audit has run.

Revision note (2026-09-19, validation review): Milestone 2 now extends on-missing defaults through bare references so histories that omit absent optionals remain readable. Milestone 3 specifies the bare declaration's `wireFingerprint` token, the three replay-verdict tests, and the `capabilityFoldSegment = Nothing` decision. No implementation has run.

Revision note (2026-09-19, 1.0 review): Added the pre-1.0 API acceptance contract, complete evidence obligations, and safe candidate-policy retention. Accepted language and runtime behavior remain unchanged. See ADR-47. No implementation or historical audit has run.
