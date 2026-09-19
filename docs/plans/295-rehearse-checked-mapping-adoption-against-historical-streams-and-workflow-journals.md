---
id: 295
slug: rehearse-checked-mapping-adoption-against-historical-streams-and-workflow-journals
title: "Rehearse checked-mapping adoption against historical streams and workflow journals"
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
      note: "Own all consumer-history evidence; add publication predicate and per-release wire-policy freeze check."
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-19T22:13:45Z
      verdict: "changes-requested"
      note: "Publication gate not separated from adoption gate; no predicate for publishing the shared candidate language."
---

# Rehearse checked-mapping adoption against historical streams and workflow journals


This ExecPlan is a living document. Keep its execution sections current; distill durable decisions into ADRs during implementation. This document authorizes planned implementation scope, not production migration or a claim of completed replay proof.


## Purpose / Big Picture


Complete the initiative with an executable adoption rehearsal for all five capabilities, preserving historical streams and workflow journals across source refactors and opaque-to-checked changes. Publication remains blocked when a required compatibility result is missing, failed, or unverified.


## Progress


- [ ] Milestone 1: Assemble one integrated workspace and historical corpus.
- [ ] Milestone 2: Prove refactor and evolution matrices.
- [ ] Milestone 3: Run an isolated consumer adoption rehearsal.
- [ ] Milestone 4: Close release gates and retain recovery paths.


## Surprises & Discoveries


None recorded during implementation yet.


## Decision Log


2026-09-19: Separate implementation completion, candidate capability availability, and consumer adoption. A successful library build or fixture suite cannot close historical adoption. Obtain evidence for the consumer history actually in scope and record explicit coverage and exclusions. The user requires streams and workflows to retain replayability after refactors. Tests and explicit compatibility boundaries enforce that requirement without claiming arbitrary Haskell behavior is statically provable.

2026-09-19 (validation review): Make Milestone 3 the single owner of consumer-history evidence, absorbing the identifier comparison formerly in Plan 294 Milestone 4, so feature plans are completable without consumer data.

2026-09-19 (validation review): Separate the publication gate from the adoption gate and state the publication predicate. The capabilities share one candidate language whose publication is atomic and irreversible, and that candidate ships in releases consumers already write history on, so wire policies freeze at first package release rather than at language publication. Review found the earlier instruction to keep a feature on an unpublished capability gave no protection for wire bytes.


## Outcomes & Retrospective


Not implemented. Record results and remaining adoption obligations here; plan creation is not implementation completion.


## Context and Orientation


Hard dependencies: [289](289-gate-mapping-evolution-with-serialized-and-cross-version-replay-evidence.md), [290](290-support-named-bare-container-structural-mappings-with-transitive-nullability.md), [291](291-add-calendar-day-mappings-with-a-frozen-lossless-codec-contract.md), [292](292-add-structural-text-sets-with-explicit-canonical-wire-semantics.md), [293](293-add-declarative-base16-byte-refinements-with-total-consumer-bindings.md), [294](294-add-explicit-versioned-uuid-admission-domains-with-sound-keiki-evidence.md). This plan composes their evidence and owns final acceptance; it does not substitute for any feature-specific test.

Research baseline is Keiro commit `98f07213` on 2026-09-19. Recheck the working tree before implementation. `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, `Parser/Mapped.hs`, `PrettyPrint.hs`, and `TypeGraph.hs` own syntax and its checked meaning. `AggregateType.hs` and `ConsumerTypePlan.hs` select supported Haskell types. `MappedCodecPlan.hs` and `Scaffold.hs` lower codecs and generated modules; `StructuralConformance.hs`, `Harness.hs`, and `ServiceHarness.hs` produce checks. Paths abbreviated after the first module in this paragraph are relative to `keiro-dsl/src/Keiro/Dsl/`.

The same directory's `MappedDiff.hs`, `SemanticImpact.hs`, `ReplayImpact.hs`, `FoldFingerprint.hs`, `CanonicalEncoding.hs`, `Coverage.hs`, and `ScaffoldRecord.hs` connect recursive type changes to persisted surfaces, stable identities, and generated provenance. `LanguageVersion.hs` selects capabilities; do not hard-code a guessed next language number. `keiro-core/src/Keiro/Codec/Structural.hs` and `Nominal.hs` contain consumer binding contracts. `keiro-core/src/Keiro/EventStream/Validate.hs` constructs validated runnable streams. `keiro/src/Keiro/ReplayAudit.hs` checks candidate replay and candidate snapshot/full agreement, not automatic old/new semantic equivalence.

A codec converts domain values to stored JSON and back. A total binding must satisfy both domain-to-shape-to-domain and shape-to-domain-to-shape identity. A fingerprint detects declared changes; it does not make a breaking change safe. A golden is committed historical input with provenance, never regenerated from the candidate to make a failure disappear.

The governing local decisions are [ADR-12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md), which assigns private-event JSON authority to checked declarations and requires total domain/shape bindings; [ADR-3](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md), which treats snapshots as disposable caches; [ADR-4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md), which separates single-spec checks, evolution findings, runtime validation, historical codec tests, and real-history replay; and [ADR-18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md), which freezes released behavior and canonical fingerprint encodings. [ADR-46](../adr/0046-nominal-declarations-are-structural-leaves-with-keiro-owned-admission.md) preserves nominal admission inside structural values, keyed maps, and declared public IDs. These decisions remain binding; the implementation must update their relevant explanations when adding a new supported surface.

Keiki's decisions `mori://shinzui/keiki/okf/adrs/concepts/ADR-2`, `mori://shinzui/keiki/okf/adrs/concepts/ADR-3`, and `mori://shinzui/keiki/okf/adrs/concepts/ADR-5` respectively require forward/replay agreement, conservative proof gates, and stable wire identity independent of Haskell names. A transducer is the pure machine that selects a transition, updates registers, and emits events. Replay reconstructs its input from the first event of a transition; subsequent events check the expected tail. An exact projection domain is a symbolic description of every possible concrete key, with reconstruction for every admitted key. Omitting real keys can manufacture false proofs of impossibility. Never weaken validation or invent exact evidence to get a fixture through.

Workflow persistence is a separate boundary. `keiro/src/Keiro/Workflow.hs` stores step results using application Aeson instances and returns the decoded stored value even on fresh execution. `keiro/src/Keiro/Workflow/Types.hs`, `Journal.hs`, and `Snapshot.hs` own journal envelopes, append/index behavior, and cache seeds. These are not automatically covered by generated private-event codecs. Preserve workflow name, instance identity, generation, step/await/child/timer keys, patch decisions, carried seeds, and result decoding. [ADR-5](../adr/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md) requires generation-scoped index fallback for await misses. [ADR-24](../adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md) freezes deterministic identity derivations. Renaming a step intentionally creates a new action; it is not a safe decoder migration. Keep old result readers and patch branches for retained histories. `continueAsNew` does not erase the obligation to interpret retained old generations or decode their carried seed.


## Plan of Work


### Milestone 1 — Assemble one integrated workspace and historical corpus


Add `keiro-dsl/test/fixtures/checked-mapping-replay-workspace/` and registered `conformance-checked-mapping-replay` output. Include the five mapping kinds across named aggregate fields/registers, nested nominal structures, supported queues/query surfaces, public IDs, and consumer-owned workflow result codecs. Include a baseline opaque implementation and candidate checked implementation in separate capture executables where linking would conflate types. Pin baseline source/build identity and retain genuine old envelopes plus malformed/previously accepted variants. Capture observations using Plan 289, not new candidate-generated history relabeled historical. Include nested combinations such as Optional Set Text, a list of Day, optional base16 bytes, and a map keyed by mixed-domain IDs where supported. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 2 — Prove refactor and evolution matrices


Run positive module/selector renames with unchanged explicit wire identities and stable workflow keys, and negative changes to date admission, set semantics, hash length/case interpretation, ID domains, binding behavior, event writes, and workflow step/result keys. Compare all durable state at every complete transition prefix; exercise representative future commands, emitted identities, and projection observations where mappings affect them. Test old-reader/new-writer behavior independently and preserve old-version upcasters. Test retained deprecated events via replay-only edges, stale snapshot rejection, full replay without any snapshot, and workflow seeded versus full/index-fallback behavior. An observation adapter must be explicit and lossless; it may rename fields but cannot omit changed data to force equality. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 3 — Run an isolated consumer adoption rehearsal


Use Mori to locate `mori://shinzui/rei` and its declared fixture/history tooling; no absolute cross-repository source paths belong in durable evidence. Obtain an authorized read-only export or isolated restored copy covering affected retained event streams and workflow journals, recording IDs/counts/high-water marks and input hashes without committing private payloads. Run baseline and candidate capture against identical immutable data. This milestone is the single owner of evidence from a consumer's real retained history for the whole initiative; Plans 290–294 complete on repository fixtures and defer here. That includes the comparison formerly scoped to Plan 294: for the consumer's retained and newly produced v5 and v7 identifiers, stream names, event identities, router keys, workflow, child, and timer identities, and deterministic content-derived IDs must be identical before and after binding adoption, and no identifier is regenerated. It also includes the retained date, text-set, and hash payloads behind Plans 291–293, checked for spellings the v1 policies reject, for keys omitted where an optional was absent, and for any durable identity derived from a hash's hex text. Aggregate ReplayAudit may identify failures and candidate snapshot discrepancies, but the independent baseline/candidate comparison is mandatory. Workflow replay is only in an isolated database with outbound effects disabled or replaced by recorded test interpreters; do not run ordinary workflow resumption against production as an audit. Missing access means adoption remains pending for that consumer, never a synthetic substitute or a request to rewrite history. It does not block the publication gate in Milestone 4, which rests on repository evidence; the two gates answer different questions and a pending adoption must not be reported as a failed or passed publication check. Consumer source edits and production deployment remain separately authorized work. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 4 — Close release gates and retain recovery paths


Document a concrete reader-before-writer rollout and post-write forward recovery policy in `docs/guides/evolution-and-replayability.md`, with separate workflow instructions in `docs/guides/durable-workflows.md`. Enforce required Plan 289 evidence in the release verification recipe and record exact build/corpus identities. State and enforce the publication predicate. All five capabilities live in the single active candidate language in `languageRegistry` (`keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs`), which permits at most one `CandidateLanguage` entry and already carries other capabilities; publishing that language publishes every capability in its profiles at once and makes them immutable. A capability may be part of a published language only when its own plan and Plan 289 are complete, its wire-policy vectors and frozen goldens are committed, its replay-verdict tests pass, and Milestones 1 and 2 of this plan pass for it. If the candidate language must be published before a capability meets that bar, remove the capability from the candidate's syntax and runtime profiles first, which the candidate's amend-in-place rule permits, and record the removal in the MasterPlan. Separately, because the candidate ships in package releases and consumers write durable history on it, check before every package release that no Keiro-owned wire policy introduced by this initiative is included without its committed vectors and goldens: the policy identity freezes at that release regardless of language maturity, and any later correction is a new policy version with the old reader retained. Keep readers/upcasters and recorded patch branches for retained histories; retiring old writers does not authorize deleting their readers. Preserve published-language baselines and complete corpus regeneration. Update the five improvement requests with truthful implementation/adoption evidence using their existing OKF metadata workflow, not an unqualified fulfilled claim. Distill decisions through ADR-12, ADR-18, ADR-46 and a new ADR if the refined contract needs its own record, following `agents/skills/exec-plan/ADR.md`. Do not publish packages or migrate production as part of this planning task. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


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


The integrated positive refactor must pass all required verdicts. Each negative mutation must fail for its intended reason. Report consumer history coverage separately from generated examples, and separate true unavailable evidence from successful empty-history evidence with an explicit inventory. No retained stream may be skipped on decode failure. No retained workflow prefix may silently rerun an already recorded effect or lose its seed/result. Unknown historical payloads block adoption for the affected consumer, even when the library feature is ready.

For every admitted value, generated encoding followed by decoding must recover the same domain value, and the generated binding must satisfy both inverse laws. Exercise forward execution followed by actual event-envelope serialization, decoding, and strict replay; compare control state and all durable registers at every completed transition. Include multi-event output, replay-only transitions, and a negative head-information-loss case. A same-version in-memory replay test alone does not pass this requirement.

For each affected persisted surface, run the compatibility gate from Plan 289. Preserve genuine old bytes, tags, versions, and readers. Compare baseline and candidate interpretations under the same versioned, non-lossy observation contract; investigate the first divergent prefix. Test old-reader/new-writer compatibility separately. A narrowed domain, altered normalization, or opaque-to-checked conversion is never automatically replay-neutral. Keep historical adapters total for retained history; if history cannot be represented without loss, retain the old representation/handler and refuse adoption.

Reject unsupported symbolic operations during checking. Exact-domain evidence must include concrete-owner membership and admitted-key reconstruction, not merely a successful solver model. Unknown evidence stays unverified and blocks a release claiming preservation. Published-language acceptance, generated bytes, and frozen identities remain unchanged unless an explicit migration is part of a separate reviewed change. Any opaque nested boundary keeps its unverified status; wrapping it in a checked container does not certify it.

Workflow adoption must additionally preserve journal semantics with actual application codecs. Run old journal prefixes through candidate continuation in an isolated test environment with recorded effects; do not execute production side effects in an audit. Persisted-result decode failure must fail clearly, never be treated as a missing step and rerun. Pure refactors must retain stable names and existing results without extra actions. No snapshot invalidation, token bump, or green finite fixture suite alone proves compatibility with all stored history.


A pure refactor must preserve wire kinds/keys, version dispatch, canonical identities, initial-state meaning, and historical readers. An intentional semantic change is not relabeled a refactor: introduce explicit event versions/upcasters or retained replay-only behavior, and preserve the old interpretation for old history. Never skip an undecodable event, drop a failed workflow result, relax Keiki validation, or rewrite historical bytes to obtain a green result. Replay-only guard remedies do not repair a codec that has already rejected or changed the event.

Evidence is tied to the audited high-water marks. Concurrent writes beyond those marks require a tail audit or a controlled writer cutover before adoption. An old-reader/new-writer failure requires a documented staged rollout that keeps incompatible writes disabled until old readers are gone; it is not historical-read success. The report must retain the failed direction and the explicit rollout precondition, and automatic simultaneous-version compatibility must remain refused.

## Idempotence and Recovery


All generation and tests run in the repository checkout or an isolated fixture database. Regenerate replaceable modules through the public corpus driver; preserve create-once bindings and historical fixtures. Retry failures after fixing the owning implementation, never by accepting new historical goldens. Do not rewrite production events, journal rows, IDs, step keys, or deterministic seeds. Keep the feature on an unpublished capability until its evidence passes. Before new-format writes, rollback can retain the previous readers; after incompatible writes, use a documented forward repair or retain compatible readers rather than assuming a binary downgrade is safe. A production migration, release, or cross-repository rollout is a separate authorized action.


## Interfaces and Dependencies


The final evidence bundle consumes Plan 289 report v1 without new waiver fields. Build identity, corpus identity, observation contract, and high-water marks must match comparison requirements. Consumer-private evidence stays outside the repository with a reproducible manifest; repository fixtures are anonymized only when the transformation preserves the tested semantics and the distinction is recorded.

Use the existing checked graph and total folds rather than separate per-generator allowlists. New checked constructors must be handled exhaustively by codecs, nullability, dependency traversal, fingerprints, diff, coverage, scaffolding, deterministic fixtures, and every admitted use-site lowerer. A clean check must imply complete generation. Keep consumer binding signatures total; JSON validation happens before binding conversion. Stable wire identity is independent of source module names, selectors, constructor presentation, and dependency traversal order.

Before using dependency APIs run `mori registry list`, `mori registry search <package>`, `mori registry show <qualified-project> --full`, and `mori registry docs <qualified-project>`, then read the located source. Relevant projects are `mori://shinzui/keiki`, `mori://haskell/aeson`, and consumer `mori://shinzui/rei`. If changing a dependency bound, verify the authoritative package registry and upstream release tags first; local source is not release evidence. No Keiki dependency change is assumed. If required evidence cannot be expressed by the released API, stop capability promotion and coordinate an explicit upstream change, never substitute a dishonest witness.

Revision note (2026-09-19): Linked the Mina-created intention and clarified retained-reader, strict-failure, audit-tail, and rolling-reader obligations during authoring review. No implementation or historical audit has run.

Revision note (2026-09-19, validation review): Milestone 3 now owns all consumer-history evidence, including the v5/v7 identifier comparison moved from Plan 294, and states that missing access blocks only that consumer's adoption. Milestone 4 adds the publication predicate, the remove-before-publish rule for the shared candidate language, and the per-release wire-policy freeze check. No implementation or historical audit has run.
