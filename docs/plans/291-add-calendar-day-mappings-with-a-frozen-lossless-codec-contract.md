---
id: 291
slug: add-calendar-day-mappings-with-a-frozen-lossless-codec-contract
title: "Add calendar-day mappings with a frozen lossless codec contract"
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
      note: "Specify Day wire token, package-release freeze point, Aeson writer parity; move consumer history to Plan 295."
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-19T22:13:44Z
      verdict: "changes-requested"
      note: "Day wire token and policy freeze point unspecified; consumer history mixed into a feature milestone. Aeson writer parity confirmed from source."
---

# Add calendar-day mappings with a frozen lossless codec contract


This ExecPlan is a living document. Keep its execution sections current; distill durable decisions into ADRs during implementation. This document authorizes planned implementation scope, not production migration or a claim of completed replay proof.


## Purpose / Big Picture


Implement IR-43 with a genuine calendar-day value, preserving complete date values in structural mappings and optional bare mappings. The implementation demonstrates old date payloads decoding and replaying without converting dates to instants or inventing timezone behavior.


## Progress


- [ ] Milestone 1: Prove a frozen full-carrier date contract.
- [ ] Milestone 2: Lower Day only on complete supported surfaces.
- [ ] Milestone 3: Prove date and optional-date replay.


## Surprises & Discoveries


None recorded during implementation yet.


## Decision Log


2026-09-19: Start with a structural Day leaf and a named bare Day mapping, including Optional Day through the common mechanism. Direct aggregate Day fields and nominal Day wrappers are deferred and must be rejected with useful guidance. The initial feature has no symbolic date operations. The user requires streams and workflows to retain replayability after refactors. Tests and explicit compatibility boundaries enforce that requirement without claiming arbitrary Haskell behavior is statically provable.

2026-09-19 (validation review): Freeze the calendar-day v1 policy at first package release rather than at language publication, embed the policy identity in the `wireFingerprint` token so a policy change can never be replay-neutral, and complete this plan on repository fixtures, leaving real consumer history to Plan 295. Aeson's year writer was read from source and matches the chosen canonical form; the read side remains to be settled by vectors.


## Outcomes & Retrospective


Not implemented. Record results and remaining adoption obligations here; plan creation is not implementation completion.


## Context and Orientation


Hard dependencies: [289](289-gate-mapping-evolution-with-serialized-and-cross-version-replay-evidence.md) for evidence and [290](290-support-named-bare-container-structural-mappings-with-transitive-nullability.md) for named bare shapes and nullability. No dependency on sets, refined bytes, or alternative ID domains.

Research baseline is Keiro commit `98f07213` on 2026-09-19. Recheck the working tree before implementation. `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, `Parser/Mapped.hs`, `PrettyPrint.hs`, and `TypeGraph.hs` own syntax and its checked meaning. `AggregateType.hs` and `ConsumerTypePlan.hs` select supported Haskell types. `MappedCodecPlan.hs` and `Scaffold.hs` lower codecs and generated modules; `StructuralConformance.hs`, `Harness.hs`, and `ServiceHarness.hs` produce checks. Paths abbreviated after the first module in this paragraph are relative to `keiro-dsl/src/Keiro/Dsl/`.

The same directory's `MappedDiff.hs`, `SemanticImpact.hs`, `ReplayImpact.hs`, `FoldFingerprint.hs`, `CanonicalEncoding.hs`, `Coverage.hs`, and `ScaffoldRecord.hs` connect recursive type changes to persisted surfaces, stable identities, and generated provenance. `LanguageVersion.hs` selects capabilities; do not hard-code a guessed next language number. `keiro-core/src/Keiro/Codec/Structural.hs` and `Nominal.hs` contain consumer binding contracts. `keiro-core/src/Keiro/EventStream/Validate.hs` constructs validated runnable streams. `keiro/src/Keiro/ReplayAudit.hs` checks candidate replay and candidate snapshot/full agreement, not automatic old/new semantic equivalence.

A codec converts domain values to stored JSON and back. A total binding must satisfy both domain-to-shape-to-domain and shape-to-domain-to-shape identity. A fingerprint detects declared changes; it does not make a breaking change safe. A golden is committed historical input with provenance, never regenerated from the candidate to make a failure disappear.

The governing local decisions are [ADR-12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md), which assigns private-event JSON authority to checked declarations and requires total domain/shape bindings; [ADR-3](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md), which treats snapshots as disposable caches; [ADR-4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md), which separates single-spec checks, evolution findings, runtime validation, historical codec tests, and real-history replay; and [ADR-18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md), which freezes released behavior and canonical fingerprint encodings. [ADR-46](../adr/0046-nominal-declarations-are-structural-leaves-with-keiro-owned-admission.md) preserves nominal admission inside structural values, keyed maps, and declared public IDs. These decisions remain binding; the implementation must update their relevant explanations when adding a new supported surface.

Keiki's decisions `mori://shinzui/keiki/okf/adrs/concepts/ADR-2`, `mori://shinzui/keiki/okf/adrs/concepts/ADR-3`, and `mori://shinzui/keiki/okf/adrs/concepts/ADR-5` respectively require forward/replay agreement, conservative proof gates, and stable wire identity independent of Haskell names. A transducer is the pure machine that selects a transition, updates registers, and emits events. Replay reconstructs its input from the first event of a transition; subsequent events check the expected tail. An exact projection domain is a symbolic description of every possible concrete key, with reconstruction for every admitted key. Omitting real keys can manufacture false proofs of impossibility. Never weaken validation or invent exact evidence to get a fixture through.

The source request is [IR-43](../improvement-requests/support-calendar-day-scalars.md). Consumer `mori://shinzui/rei`, project-relative `rei-core/src/Rei/Domain/KeiroShapes.hs` (artifact URI pending), aliases LocalDay to Data.Time.Calendar.Day. Arbitrary Text is not an honest total representation. A Haskell Day can represent dates outside a four-digit year range, so an encoder limited to those years would not cover its carrier.


## Plan of Work


### Milestone 1 — Prove a frozen full-carrier date contract


Add `keiro-core/src/Keiro/Codec/CalendarDay.hs`. Define a proleptic Gregorian representation with full integer-year support, no timezone and no normalization of invalid month/day combinations. First write a codec prototype and compatibility vectors against the actual consumer Aeson/date versions located via Mori. Canonical output uses a minimum four-digit absolute year, a minus sign for negative years, no plus sign, and two-digit month/day, including year zero; document larger positive years without truncation. Accept the canonical grammar with valid Gregorian dates. Test encoder/decoder totality on constructed Day values including negative and very large years. If historical Aeson accepts additional spellings, retain an explicitly versioned historical reader for those spellings rather than silently changing the v1 contract or claiming universal parity. Do not release until baseline canonical output and accepted historical inputs have been compared. The chosen canonical output is byte-compatible with Aeson's writer: `encodeYear` in project `mori://haskell/aeson`, project-relative `aeson/src/Data/Aeson/Encoding/Builder.hs` (artifact URI pending), writes the decimal year unpadded from 1000 upward, zero-padded to four digits from 0 to 999, a minus sign with four-digit padding down to -999, and an unpadded negative decimal below that, never a plus sign. Pin that equivalence with vectors rather than relying on this reading, and check the consumer's actual Aeson version. Parity on the read side is the open question the vectors must settle. The calendar-day v1 policy identity freezes at the first package release that contains this module, even while the language capability is still a candidate, because a consumer on the candidate language can write durable events from that release onward; any later correction is a v2 policy with the v1 reader retained. Commit the vectors and frozen goldens before such a release. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 2 — Lower Day only on complete supported surfaces


Add Day to checked structural TypeExpr and bare-shape support in `Grammar.hs`, `TypeGraph.hs`, `MappedCodecPlan.hs`, `ConsumerTypePlan.hs`, `Scaffold.hs`, and their total folds. Use the Keiro-owned codec helper instead of acquiring arbitrary consumer JSON behavior. Add required imports/packages, deterministic sample dates, declared register initials, branch coverage, source capability checks, recursive fingerprints, and diff consequences. Name the codec domain/version in identity; policy changes are visible. Concretely, the new `wireExpr` case in `wireFingerprint` (`TypeGraph.hs`) renders Day as a token that embeds the calendar-day policy identity and version, because `ReplayImpact.hs` turns token equality into a `replay-neutral` verdict and a replay-neutral deploy skips its audit. Test that a policy-version change, a Text-to-Day change, and a Time-to-Day change are each `replay-affected`, and that tokens for every existing declaration are byte-identical. The new `RuntimeCapability` constructor takes `capabilityFoldSegment = Nothing`, like `StructuralNominalLeaves`. Reject date guards, arithmetic, ordering, direct fields, and nominal wrappers outside this release scope rather than silently lowering Day through Text or UTCTime. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


### Milestone 3 — Prove date and optional-date replay


Add `keiro-dsl/test/fixtures/calendar-days.keiro` and registered `conformance-calendar-days` with bare Day, record fields, Optional Day, nested lists/maps, registers, queue fields, query results, and workspace bindings. Exercise leap-year boundaries (1900 invalid leap day, 2000 valid), month boundaries, year zero, negative/extended years, nulls and omissions. Compare old LocalDay/MaybeLocalDay codecs through the existing codec-comparison path and Plan 289 reports, using committed payload fixtures modeled on the consumer's codec source as located through Mori. These are repository fixtures and must be labeled as such; evidence from the consumer's real retained history is owned by Plan 295 Milestone 3 and is not required to complete this plan. If the v1 reader accepts any spelling the encoder does not write, supply those spellings as cases for Plan 289's normalization law. Verify a date parser narrowing and an accidental midnight conversion fail compatibility; retain explicit old-version readers when required. Run the focused new tests in the components named under Concrete Steps; the milestone passes only when its positive behavior is observed and its negative case fails for the intended reason.


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


The codec accepts 2000-02-29 and rejects 1900-02-29 and 2026-02-30. Every generated valid Day in the boundary/property suite round-trips exactly, including dates outside years 0000–9999. Optional dates preserve null versus absence policy. No clock, locale, or timezone affects bytes. All accepted declarations scaffold and compile; unsupported date expressions fail check.

For every admitted value, generated encoding followed by decoding must recover the same domain value, and the generated binding must satisfy both inverse laws. Exercise forward execution followed by actual event-envelope serialization, decoding, and strict replay; compare control state and all durable registers at every completed transition. Include multi-event output, replay-only transitions, and a negative head-information-loss case. A same-version in-memory replay test alone does not pass this requirement.

For each affected persisted surface, run the compatibility gate from Plan 289. Preserve genuine old bytes, tags, versions, and readers. Compare baseline and candidate interpretations under the same versioned, non-lossy observation contract; investigate the first divergent prefix. Test old-reader/new-writer compatibility separately. A narrowed domain, altered normalization, or opaque-to-checked conversion is never automatically replay-neutral. Keep historical adapters total for retained history; if history cannot be represented without loss, retain the old representation/handler and refuse adoption.

Reject unsupported symbolic operations during checking. Exact-domain evidence must include concrete-owner membership and admitted-key reconstruction, not merely a successful solver model. Unknown evidence stays unverified and blocks a release claiming preservation. Published-language acceptance, generated bytes, and frozen identities remain unchanged unless an explicit migration is part of a separate reviewed change. Any opaque nested boundary keeps its unverified status; wrapping it in a checked container does not certify it.

Workflow adoption must additionally preserve journal semantics with actual application codecs. Run old journal prefixes through candidate continuation in an isolated test environment with recorded effects; do not execute production side effects in an audit. Persisted-result decode failure must fail clearly, never be treated as a missing step and rerun. Pure refactors must retain stable names and existing results without extra actions. No snapshot invalidation, token bump, or green finite fixture suite alone proves compatibility with all stored history.


A pure refactor must preserve wire kinds/keys, version dispatch, canonical identities, initial-state meaning, and historical readers. An intentional semantic change is not relabeled a refactor: introduce explicit event versions/upcasters or retained replay-only behavior, and preserve the old interpretation for old history. Never skip an undecodable event, drop a failed workflow result, relax Keiki validation, or rewrite historical bytes to obtain a green result. Replay-only guard remedies do not repair a codec that has already rejected or changed the event.

Evidence is tied to the audited high-water marks. Concurrent writes beyond those marks require a tail audit or a controlled writer cutover before adoption. An old-reader/new-writer failure requires a documented staged rollout that keeps incompatible writes disabled until old readers are gone; it is not historical-read success. The report must retain the failed direction and the explicit rollout precondition, and automatic simultaneous-version compatibility must remain refused.

## Idempotence and Recovery


All generation and tests run in the repository checkout or an isolated fixture database. Regenerate replaceable modules through the public corpus driver; preserve create-once bindings and historical fixtures. Retry failures after fixing the owning implementation, never by accepting new historical goldens. Do not rewrite production events, journal rows, IDs, step keys, or deterministic seeds. Keep the feature on an unpublished capability until its evidence passes. Before new-format writes, rollback can retain the previous readers; after incompatible writes, use a documented forward repair or retain compatible readers rather than assuming a binary downgrade is safe. A production migration, release, or cross-repository rollout is a separate authorized action.


## Interfaces and Dependencies


The CalendarDay module exposes a pure encoder and failing JSON parser with a stable codec-policy identity, used everywhere Day is supported. Day is non-null evidence. Binding is total to Day, not a partial Text conversion. Keiki remains unchanged and does not gain Day symbolic dictionaries.

Use the existing checked graph and total folds rather than separate per-generator allowlists. New checked constructors must be handled exhaustively by codecs, nullability, dependency traversal, fingerprints, diff, coverage, scaffolding, deterministic fixtures, and every admitted use-site lowerer. A clean check must imply complete generation. Keep consumer binding signatures total; JSON validation happens before binding conversion. Stable wire identity is independent of source module names, selectors, constructor presentation, and dependency traversal order.

Before using dependency APIs run `mori registry list`, `mori registry search <package>`, `mori registry show <qualified-project> --full`, and `mori registry docs <qualified-project>`, then read the located source. Relevant projects are `mori://shinzui/keiki`, `mori://haskell/aeson`, and consumer `mori://shinzui/rei`. If changing a dependency bound, verify the authoritative package registry and upstream release tags first; local source is not release evidence. No Keiki dependency change is assumed. If required evidence cannot be expressed by the released API, stop capability promotion and coordinate an explicit upstream change, never substitute a dishonest witness.

Revision note (2026-09-19): Linked the Mina-created intention and clarified retained-reader, strict-failure, audit-tail, and rolling-reader obligations during authoring review. No implementation or historical audit has run.

Revision note (2026-09-19, validation review): Milestone 1 records the Aeson writer equivalence and the package-release freeze point. Milestone 2 specifies the Day wire token, its replay-verdict tests, and `capabilityFoldSegment = Nothing`. Milestone 3 separates repository codec-comparison fixtures from consumer history owned by Plan 295. No implementation has run.
