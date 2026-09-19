---
id: 44
slug: add-checked-value-mappings-while-preserving-stream-and-workflow-replay-across-refactors
title: "Add checked value mappings while preserving stream and workflow replay across refactors"
kind: master-plan
intention: "intention_01m2xtfnt7ewg9ptt7ztf0tary"
created_at: 2026-09-19T21:46:02Z
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-19T21:46:02Z
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
      note: "Apply validation review: gates separated, wire-token authority, package-release freeze point, capabilityFoldSegment decision, derived evidence inventory, normalization law; cascaded to children and linked IR-42..46."
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-19T22:13:44Z
      verdict: "changes-requested"
      note: "Feature designs sound in principle; gating gaps: wire policies freeze at package release not language publication, shared candidate language publishes atomically, replay-verdict wire tokens and evidence inventory under-specified."
---

# Add checked value mappings while preserving stream and workflow replay across refactors


This MasterPlan is a living document. Keep its registry and execution sections current and distill durable architectural decisions into ADRs during implementation.


## Vision & Scope


Honor IR-42 through IR-46 without making existing stream or workflow history unreadable or changing its meaning silently. Named bare containers, calendar days, structural text sets, base16 byte refinements, and explicit mixed UUID admission become checked capabilities. A developer can demonstrate a source-only refactor preserving historical state and workflow continuations, and observe the gate refuse an incompatible codec, binding, proof domain, or journal change.

The guarantee sought is preservation of retained history and forward/serialized-replay agreement under explicit binding and constructor laws. It is not a claim that any future Haskell refactor is automatically safe. Checked declarations, immutable wire contracts, versioned historical readers, conservative Keiki evidence, and executable old/new comparisons jointly enforce the boundary. Required missing or unverified evidence blocks adoption. Snapshot invalidation prevents using a stale cache; it cannot recover lost event information or repair a changed fold.

Initial scope is whole-value transport for containers, dates, sets, and refined bytes, plus truthful declaration-scoped ID equality. Arbitrary refinements, collection operators, date arithmetic, direct aggregate containers, and automatic workflow schema ownership are excluded. Workflows retain their application-owned result codecs and need their own compatibility tests. Production mutation, deployment, and package publication are not authorized by this plan-creation request.


## Decomposition Strategy


Seven plans separate one shared preservation gate, five independently testable capabilities, and one integration/adoption gate. Building safety evidence first prevents each feature from treating decoder success as sufficient replay proof. Combining everything in one compiler plan would obscure distinct risks: null ambiguity, calendar range, set quotient semantics, refinement admission, and symbolic-domain soundness. A final rehearsal catches combinations and consumer histories that isolated feature examples cannot cover.

Plan 289 extends protections that already exist rather than inventing them, and every plan must preserve them. The generated harness (`forwardReplayDecl` in `keiro-dsl/src/Keiro/Dsl/Harness.hs`, from plan 147) already runs each event-emitting transition forward, pushes the emitted chain through the generated event codec, replays it with `applyEventsEither`, and compares the final vertex and every register; it also emits a `parse . encode == Right` golden round trip per event. `keiro-dsl/src/Keiro/Dsl/MappedDiff.hs` already reports `MappedModeCrossed` when a declaration crosses the structural/opaque boundary. `decodeStored` in `keiro/src/Keiro/Workflow.hs` already throws `WorkflowStepDecodeError` when a persisted step result fails to decode, so a decode failure is never a cache miss today. What does not exist is: a law for non-canonical wire input (needed by the set, base16, and date features, whose decoders accept more spellings than their encoders write), multi-transition prefix comparison, independent baseline/candidate interpretation, workflow refactor regression tests, and an enforced evidence inventory. Plan 289 owns exactly that delta.

Feature plans 290–294 complete on repository fixtures and committed codec-comparison payloads. Evidence from a consumer's real retained history is owned only by Plan 295, so that no feature plan's completion depends on access to consumer data.

The governing local decisions are [ADR-12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md), which assigns private-event JSON authority to checked declarations and requires total domain/shape bindings; [ADR-3](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md), which treats snapshots as disposable caches; [ADR-4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md), which separates single-spec checks, evolution findings, runtime validation, historical codec tests, and real-history replay; and [ADR-18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md), which freezes released behavior and canonical fingerprint encodings. [ADR-46](../adr/0046-nominal-declarations-are-structural-leaves-with-keiro-owned-admission.md) preserves nominal admission inside structural values, keyed maps, and declared public IDs. These decisions remain binding; the implementation must update their relevant explanations when adding a new supported surface.

Keiki's decisions `mori://shinzui/keiki/okf/adrs/concepts/ADR-2`, `mori://shinzui/keiki/okf/adrs/concepts/ADR-3`, and `mori://shinzui/keiki/okf/adrs/concepts/ADR-5` respectively require forward/replay agreement, conservative proof gates, and stable wire identity independent of Haskell names. A transducer is the pure machine that selects a transition, updates registers, and emits events. Replay reconstructs its input from the first event of a transition; subsequent events check the expected tail. An exact projection domain is a symbolic description of every possible concrete key, with reconstruction for every admitted key. Omitting real keys can manufacture false proofs of impossibility. Never weaken validation or invent exact evidence to get a fixture through.

Workflow persistence is a separate boundary. `keiro/src/Keiro/Workflow.hs` stores step results using application Aeson instances and returns the decoded stored value even on fresh execution. `keiro/src/Keiro/Workflow/Types.hs`, `Journal.hs`, and `Snapshot.hs` own journal envelopes, append/index behavior, and cache seeds. These are not automatically covered by generated private-event codecs. Preserve workflow name, instance identity, generation, step/await/child/timer keys, patch decisions, carried seeds, and result decoding. [ADR-5](../adr/0005-workflow-awaits-fall-back-to-the-step-index-on-replay-misses.md) requires generation-scoped index fallback for await misses. [ADR-24](../adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md) freezes deterministic identity derivations. Renaming a step intentionally creates a new action; it is not a safe decoder migration. Keep old result readers and patch branches for retained histories. `continueAsNew` does not erase the obligation to interpret retained old generations or decode their carried seed.


## Exec-Plan Registry


| Plan | Scope | Path | Hard dependencies | Soft dependencies | Status |
|---|---|---|---|---|---|
| 289 | Gate mapping evolution with serialized and cross-version replay evidence | [docs/plans/289-gate-mapping-evolution-with-serialized-and-cross-version-replay-evidence.md](../plans/289-gate-mapping-evolution-with-serialized-and-cross-version-replay-evidence.md) | None | None | Not Started |
| 290 | Support named bare container structural mappings with transitive nullability | [docs/plans/290-support-named-bare-container-structural-mappings-with-transitive-nullability.md](../plans/290-support-named-bare-container-structural-mappings-with-transitive-nullability.md) | 289 | None | Not Started |
| 291 | Add calendar-day mappings with a frozen lossless codec contract | [docs/plans/291-add-calendar-day-mappings-with-a-frozen-lossless-codec-contract.md](../plans/291-add-calendar-day-mappings-with-a-frozen-lossless-codec-contract.md) | 289, 290 | None | Not Started |
| 292 | Add structural text sets with explicit canonical wire semantics | [docs/plans/292-add-structural-text-sets-with-explicit-canonical-wire-semantics.md](../plans/292-add-structural-text-sets-with-explicit-canonical-wire-semantics.md) | 289, 290 | None | Not Started |
| 293 | Add declarative base16 byte refinements with total consumer bindings | [docs/plans/293-add-declarative-base16-byte-refinements-with-total-consumer-bindings.md](../plans/293-add-declarative-base16-byte-refinements-with-total-consumer-bindings.md) | 289, 290 | None | Not Started |
| 294 | Add explicit versioned UUID admission domains with sound Keiki evidence | [docs/plans/294-add-explicit-versioned-uuid-admission-domains-with-sound-keiki-evidence.md](../plans/294-add-explicit-versioned-uuid-admission-domains-with-sound-keiki-evidence.md) | 289 | None | Not Started |
| 295 | Rehearse checked-mapping adoption against historical streams and workflow journals | [docs/plans/295-rehearse-checked-mapping-adoption-against-historical-streams-and-workflow-journals.md](../plans/295-rehearse-checked-mapping-adoption-against-historical-streams-and-workflow-journals.md) | 289, 290, 291, 292, 293, 294 | None | Not Started |


## Dependency Graph


Plan 289 defines the evidence/report and serialized replay harness all feature plans consume. Plan 290 adds the bare-expression and transitive-nullability interfaces. Plans 291, 292, and 293 require both. Plan 294 requires Plan 289 but can use existing structural records; it has an integration dependency with Plan 290 on checked graph traversal and nominal leaf identity. Plan 295 requires all six, assembles mixed-feature fixtures, and performs the consumer evidence and release gate closure.

Plans 291–294 can be implemented independently once their hard dependencies exist, but changes to shared graph algebras, Scaffold.hs, language capabilities, and Cabal corpus inventory must be reconciled before merging. No parallel work is required. A feature may be implementation-complete as a candidate while consumer adoption remains pending; all registry rows must be complete before this initiative is marked complete.

Plan 294's mixed-domain rehearsal uses repository fixtures only. The comparison of historical and newly produced v5/v7 identities in consumer `mori://shinzui/rei` belongs to Plan 295 Milestone 3, alongside the other consumer-history evidence. This keeps Plan 294 independently completable and avoids two plans owning the same consumer rehearsal.

Three distinct gates apply, and they must not be conflated. The per-feature gate (each of Plans 290–294, using Plan 289) decides whether a capability's implementation is complete. The publication gate (Plan 295 Milestone 4) decides whether a capability may be part of a published language. The adoption gate (Plan 295 Milestone 3) decides, per consumer, whether that consumer may switch retained history to a checked mapping. Unavailable consumer data blocks only the adoption gate for that consumer; it never blocks the publication gate and is never replaced by synthetic evidence.


## Integration Points


Plan 289 owns the compatibility report v1, baseline/candidate comparison semantics, and the release predicate. Features supply cases without weakening required verdicts. The report records immutable corpus/build identity and a versioned complete observation contract; separate executables permit old/new Haskell representations. Plan 295 owns the integrated corpus and adoption manifest, including high-water marks and consumer-specific evidence.

Plan 290 owns the bare checked-shape algebra and recursive nullability query. Plans 291–293 extend that common representation, not independent generators. Plan 294 owns ID admission-domain selection and projection evidence, which all structural/public/keyed-map consumers reuse. All feature plans share TypeGraph.hs, MappedCodecPlan.hs, Scaffold.hs, SemanticImpact.hs, MappedDiff.hs, FoldFingerprint.hs, Coverage.hs, StructuralConformance.hs, and LanguageVersion.hs under keiro-dsl/src/Keiro/Dsl. Add candidate capabilities without changing published behavior; constructors force exhaustive handling.

Each feature must define canonical type identity, admitted domain, canonical encoding, parser policy, and version before claiming support. Source presentation and wire identity remain separate. No new operation is solver-visible merely because its Haskell type has Eq or Ord. An exact ID domain must include every runtime-reachable owner, including historical internal construction paths; narrowing only the solver domain is prohibited.

The replay verdict has one authority, and every feature plan must extend it truthfully. `wireFingerprint`, `wireExpr`, and `nominalWireToken` in `keiro-dsl/src/Keiro/Dsl/TypeGraph.hs` render each mapped declaration's wire form to a token string; `keiro-dsl/src/Keiro/Dsl/ReplayImpact.hs` compares those tokens to decide between `replay-neutral` and `replay-affected`, and `keiro/src/Keiro/ReplayAudit.hs` documents that a replay-neutral deploy touches no data. A token that fails to change when wire meaning changes therefore lets a deploy skip its audit. Three rules follow. First, every new checked constructor's token embeds its frozen codec-policy identity and version (calendar day, text set, base16 bytes), so a policy change can never be replay-neutral. Second, tokens describe wire form, not declaration structure: `RRef` already inlines the referenced declaration without its name, so a bare alias renders as its inner expression and extracting `Optional Text` into a named alias is truthfully wire-neutral, while opaque-to-checked still differs because the opaque token is `opaque(identity,version)` and `MappedModeCrossed` fires. Third, tokens for every existing declaration stay byte-identical. Plan 294 carries the sharpest instance: `NominalIdLeaf` holds only a prefix, and `nominalWireToken` renders it with the module constant `nominalIdDomainVersion`, so as the code stands an admission-domain change would produce an identical token. Plan 294 owns threading the selected domain into the leaf and its token while keeping the implicit-v7 token unchanged, and likewise into `idDomainContractFor` and `contractIdDomainContractFor` in `keiro-dsl/src/Keiro/Dsl/IdDomain.hs`, which today select a contract from the language and prefix alone and feed both the scaffold ledger's `id-domain` rows and the `IdDomainContractChanged` finding in `keiro-dsl/src/Keiro/Dsl/Diff.hs`. `wireFingerprint` is not the only path. A declared ID used directly as an aggregate field, register, or event field never enters the mapped graph: `IdRepresentation` in `keiro-dsl/src/Keiro/Dsl/NominalType.hs` holds only a prefix, and `nominalRepresentationSurface` in `ReplayImpact.hs` and `nominalRepresentationSegment` in `keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs` both render it as `id:<prefix>`. Plan 294 must carry the domain there as well, again byte-identical for implicit v7. The general rule for every plan: before relying on a token, confirm which of the two paths, mapped reference or direct nominal field, each admitted use site takes, and cover both. Each feature plan adds a negative test proving that its policy, domain, or mode change is reported replay-affected.

All five capabilities are staged in the single active candidate language. `languageRegistry` in `keiro-dsl/src/Keiro/Dsl/LanguageVersion.hs` holds exactly one `CandidateLanguage` entry (version 6 at the research baseline) and enforces at most one; that candidate already carries keyed maps, structural nominal leaves, and other capabilities, ships in package releases marked candidate, and is used by consumers. Two consequences bind every plan. Publication is atomic: publishing the candidate language publishes every capability in its profiles at once, so a capability whose own plan and Plan 289 evidence are incomplete must be removed from the candidate profiles before that language is published, which the candidate's amend-in-place rule permits. And language maturity is not the freeze point for wire bytes: a consumer on the candidate can write durable events the day a package release contains the codec. Each Keiro-owned wire-policy identity (calendar day v1, text set v1, base16 bytes v1, the v5-or-v7 ID domain v1) is therefore frozen at the first package release that contains it, regardless of language maturity. Correcting a released policy means a new policy version with the old reader retained, never an in-place edit. Do not release a package containing a policy whose compatibility vectors and frozen goldens are not yet committed.

Each new `RuntimeCapability` constructor requires an explicit `capabilityFoldSegment` decision. The initiative's decision is `Nothing` for all five, matching `StructuralNominalLeaves`: these capabilities change generated codecs and admission, not transition or fold semantics, and their identity flows through declaration-level wire tokens and the mapped-register surface instead. Returning a segment would re-fingerprint every candidate-language service, including those that never use the feature. A plan that finds it needs a segment must record why in its Decision Log and here.

The set, base16, and date decoders accept more wire spellings than their encoders write, so each is a quotient of wire text onto domain values. Live execution folds in-memory event values while replay folds decoded bytes; the two agree only because normalization happens while parsing, before any value reaches the transducer, and because `decode (encode v) == v` holds on the whole domain carrier. Plan 289 owns the shared normalization law used by Plans 291–293: for every accepted non-canonical wire form `w`, `encode (decode w)` is canonical and `decode (encode (decode w)) == decode w`, and no generated or bound value ever retains pre-normalization information. The text-set canonical order is defined normatively as lexicographic order of Unicode code points, which is what `Ord Text` implements; it is not UTF-16 code-unit order, and the contract must not be stated as "whatever the text package does".

Plan 289's required-evidence inventory is derived mechanically, never hand-selected. `MappedConsequence` in `keiro-dsl/src/Keiro/Dsl/SemanticImpact.hs` already enumerates the durable consequences of a mapped change: private event history, snapshot hydration, workqueue history, query API, router selection, projection handler review, and projection rebuild. The report's required cases are computed from that set for the declarations that changed, plus the workflow surfaces the consumer declares. In-flight workqueue messages and projection rebuilds are durable history written by an old writer and read by a new reader, exactly like events, and must not be omitted because the initiative's title names streams and workflows.

Workflow codecs, step keys, generations, seeds, patch sets, await/index fallback, and deterministic identities remain independently owned. Plan 289 supplies regression checks, and Plan 295 supplies consumer journal evidence. The initiative adds no workflow-generated codec authority by implication. Renaming a step can execute a new side effect and is never an automatic migration remedy.

The total-binding/refinement distinction, historical interpretation gate, fixed wire-policy versions, proof-domain ownership, the rule that wire policies freeze at first package release rather than at language publication, and the wire-token rules above deserve ADR updates during implementation. Follow agents/skills/exec-plan/ADR.md for stable handle allocation, log updates, and strict profile validation. This planning pass retains existing architectural decisions and proposes no retroactive claim that new features already exist.


## Progress


- [ ] Plan 289: Define the compatibility report and capture contract.
- [ ] Plan 289: Exercise serialized aggregate replay and meaningful refactors.
- [ ] Plan 289: Exercise workflow refactors without repeating effects.
- [ ] Plan 289: Enforce evidence and document the limits.
- [ ] Plan 290: Introduce checked bare-expression declarations.
- [ ] Plan 290: Make nullability recursive and lower bare codecs.
- [ ] Plan 290: Propagate identity and prove migration behavior.
- [ ] Plan 291: Prove a frozen full-carrier date contract.
- [ ] Plan 291: Lower Day only on complete supported surfaces.
- [ ] Plan 291: Prove date and optional-date replay.
- [ ] Plan 292: Define native checked text-set values and wire policy.
- [ ] Plan 292: Integrate total lowering and evolution consequences.
- [ ] Plan 292: Demonstrate normalization without replay divergence.
- [ ] Plan 293: Specify and implement a bounded refinement contract.
- [ ] Plan 293: Compose refinement through all admitted checked roots.
- [ ] Plan 293: Prove byte identity and preserve old hash semantics.
- [ ] Plan 294: Define explicit domain identity and canonical membership.
- [ ] Plan 294: Prove runtime and symbolic agreement before exposing equality.
- [ ] Plan 294: Propagate admission to nested and public consumers.
- [ ] Plan 294: Rehearse mixed-domain history and immutable identities.
- [ ] Plan 295: Assemble one integrated workspace and historical corpus.
- [ ] Plan 295: Prove refactor and evolution matrices.
- [ ] Plan 295: Run an isolated consumer adoption rehearsal.
- [ ] Plan 295: Close release gates and retain recovery paths.


## Surprises & Discoveries


None recorded during implementation yet. Research findings are included in the child contexts and are not implementation evidence.

The 2026-09-19 validation review checked the plans' claims against the working tree at `ba36ce58`. Every file, recipe, Cabal component, ADR, improvement request, and Keiki ADR URI the plans name exists or resolves. The review found the following, none of which is implementation evidence:

- The generated harness already crosses the persisted codec boundary for forward/replay equality (`forwardReplayDecl`, plan 147), so Plan 289 Milestone 2 is a delta, not a first implementation.
- `decodeStored` in `keiro/src/Keiro/Workflow.hs` already fails closed with `WorkflowStepDecodeError`; Plan 289 Milestone 3's decode-failure case is a regression test of existing behavior, not a fix.
- `hasNonInjectiveOptional` in `keiro-dsl/src/Keiro/Dsl/Validate.hs` does treat every structural reference as non-null (`onRef`), exactly as Plan 290 states. `referencedDefaultType` in the same module returns `DefaultOther` for every non-enum shape, so an `optional on-missing=null` field cannot currently reference a named optional alias.
- `nominalWireToken` renders ID leaves with a module-level constant domain version, and `NominalIdLeaf` carries only a prefix. An admission-domain change would be invisible to `wireFingerprint`, and so to the replay verdict, unless Plan 294 threads the domain through.
- `validateIdDomainText` ignores the contract's version field and always applies the v7 check; `idDomainTextPattern` hard-codes the v7 version characters; `parseKindIdV7Text` and `parseKindIdV7Value` are v7-only entry points used by generated contract codecs.
- Directly-used declared IDs bypass `wireFingerprint`: `IdRepresentation` holds only a prefix and is rendered `id:<prefix>` into both the per-event replay surface and the fold fingerprint. Combined with `capabilityFoldSegment = Nothing`, a domain change on a direct ID field would have been invisible to the replay verdict and to snapshot discrimination. This was found in a follow-up check after the first pass of the review had threaded only the nested path.
- `idDomainContractFor` and `contractIdDomainContractFor` select a contract from the language contract and a prefix only. The scaffold ledger's `id-domain` rows and the breaking `IdDomainContractChanged` diff finding are both computed from them, so neither can currently see a per-declaration domain choice. That finding's message also promises that historical replay retains a legacy decoder, which would be false for a narrowing.
- The language registry has exactly one candidate (version 6), already shipping in releases with other capabilities. "Keep the feature on an unpublished capability" therefore does not by itself keep durable bytes from being written.
- `Ord Text` is code-point order, confirmed empirically (`compare "\xE000" "\x10000" == LT`) and in source: in project `mori://haskell/text` 2.1.4, project-relative `text/src/Data/Text.hs` (artifact URI pending), `compareText` compares UTF-8 byte arrays and notes that this matches code-point order where UTF-16 would not. The library changed representation across major versions while preserving this order, which is why the text-set contract is stated as code-point order and not by reference to the library.
- Aeson's `encodeYear` (project `mori://haskell/aeson`, project-relative `aeson/src/Data/Aeson/Encoding/Builder.hs`, artifact URI pending) writes exactly the canonical year form Plan 291 chose, and Aeson's default `allowOmittedFields = True` accepts a missing key for an optional field, which is the history Plan 290's on-missing extension must keep readable.
- IR-42 through IR-46 were still `proposed` with no plan links although this plan accepts them.


## Decision Log


2026-09-19: Accept all five feature directions with a mandatory preservation gate before implementation and an independent final adoption rehearsal. Prioritize truthful guarantees over making every consumer declaration checked immediately.

2026-09-19: Keep dates and byte refinements transport-only and restrict sets to Text initially. Mixed ID domains keep frozen generation policy and require complete runtime/symbolic agreement. All old-language contracts remain unchanged.

2026-09-19: Compare baseline and candidate interpretation, not only candidate snapshot/full replay. Bind evidence to input corpus, build identities, stable observations, and coverage. Unknown results block adoption; fixture success alone is not universal proof.

2026-09-19: Retain old workflow result readers and recorded patch branches for retained histories. A renamed step, continueAsNew, or disabled snapshot is not a substitute for journal compatibility. Run workflow historical checks only in isolated environments without production effects.

2026-09-19 (validation review): Freeze each Keiro-owned wire-policy identity at the first package release that contains it, not at language publication. The candidate language ships in releases and consumers write durable history on it, so "unpublished capability" is not a safe holding area for wire bytes. A released policy is corrected only by a new policy version with the old reader retained.

2026-09-19 (validation review): Treat publication of the candidate language as atomic across all its capabilities. A capability whose own plan and Plan 289 evidence are incomplete is removed from the candidate profiles before that language is published. Separate the per-feature, publication, and adoption gates; missing consumer data blocks only that consumer's adoption.

2026-09-19 (validation review): Make `wireFingerprint` tokens the single replay-verdict authority for the new constructors. Tokens embed codec-policy identity, describe wire form rather than declaration structure, and stay byte-identical for existing declarations. Rationale: `ReplayImpact` turns token equality into `replay-neutral`, which lets a deploy skip its audit, so an under-specified token is a silent replay hazard. Plan 294 must thread the admission domain into `NominalIdLeaf` and `nominalWireToken`.

2026-09-19 (validation review): Default `capabilityFoldSegment` to `Nothing` for all five capabilities, so services that do not use a feature keep their fold fingerprints and snapshots. This is safe only because identity is carried at declaration granularity on every path; for Plan 294 that means both the nested wire token and the direct `IdRepresentation` rendering, the second of which was added as a correction after the first pass missed it.

2026-09-19 (validation review): Derive Plan 289's required-evidence inventory from `MappedConsequence`, including workqueue history and projection rebuild, instead of a hand-selected surface list. A hand-selected list makes `--require-all` vacuous for whatever the author forgot.

2026-09-19 (validation review): Move the consumer `mori://shinzui/rei` identity comparison from Plan 294 Milestone 4 to Plan 295 Milestone 3. Feature plans complete on repository fixtures; only Plan 295 depends on consumer data.

2026-09-19 (validation review): Define the text-set canonical order normatively as Unicode code-point order, and have Plan 289 own one normalization law shared by the three quotient codecs.

2026-09-19 (validation review): Mark IR-42 through IR-46 accepted and link each to its owning child plan, with Plans 289 and 295 as related plans.


## Outcomes & Retrospective


Planning only. Seven child plans were created; no capability, migration, or historical replay check has been implemented by this document. Completion requires all child acceptance evidence and ADR distillation, with unavailable consumer data recorded as an outstanding adoption obligation.

Revision note (2026-09-19): Linked the Mina-created intention and clarified retained-reader, strict-failure, audit-tail, and rolling-reader obligations during authoring review. No implementation or historical audit has run.

Revision note (2026-09-19, validation review): Verified the plans' claims against the tree at `ba36ce58` and applied the findings. Added the existing-coverage baseline to Decomposition Strategy; separated the per-feature, publication, and adoption gates in Dependency Graph; added Integration Points for the wire-token replay-verdict authority, candidate-language staging and the package-release freeze point, the `capabilityFoldSegment` decision, the shared quotient-codec normalization law and normative set order, and the derived evidence inventory; moved the consumer identity comparison from Plan 294 to Plan 295; recorded the review's discoveries and decisions. Cascaded the corresponding changes into Plans 289–295 and linked IR-42 through IR-46. The feature designs were found sound in principle; the gaps were in gating and in under-specified identity plumbing. No implementation or historical audit has run.

Revision note (2026-09-19, validation review correction): Added the direct-ID path (`IdRepresentation`, `nominalRepresentationSurface`, `nominalRepresentationSegment`) to the wire-token integration point, discoveries, and the `capabilityFoldSegment` decision, and cascaded it into Plan 294. The first pass covered only IDs nested in mapped declarations.
