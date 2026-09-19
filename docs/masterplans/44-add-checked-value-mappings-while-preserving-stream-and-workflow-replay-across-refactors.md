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
---

# Add checked value mappings while preserving stream and workflow replay across refactors


This MasterPlan is a living document. Keep its registry and execution sections current and distill durable architectural decisions into ADRs during implementation.


## Vision & Scope


Honor IR-42 through IR-46 without making existing stream or workflow history unreadable or changing its meaning silently. Named bare containers, calendar days, structural text sets, base16 byte refinements, and explicit mixed UUID admission become checked capabilities. A developer can demonstrate a source-only refactor preserving historical state and workflow continuations, and observe the gate refuse an incompatible codec, binding, proof domain, or journal change.

The guarantee sought is preservation of retained history and forward/serialized-replay agreement under explicit binding and constructor laws. It is not a claim that any future Haskell refactor is automatically safe. Checked declarations, immutable wire contracts, versioned historical readers, conservative Keiki evidence, and executable old/new comparisons jointly enforce the boundary. Required missing or unverified evidence blocks adoption. Snapshot invalidation prevents using a stale cache; it cannot recover lost event information or repair a changed fold.

Initial scope is whole-value transport for containers, dates, sets, and refined bytes, plus truthful declaration-scoped ID equality. Arbitrary refinements, collection operators, date arithmetic, direct aggregate containers, and automatic workflow schema ownership are excluded. Workflows retain their application-owned result codecs and need their own compatibility tests. Production mutation, deployment, and package publication are not authorized by this plan-creation request.


## Decomposition Strategy


Seven plans separate one shared preservation gate, five independently testable capabilities, and one integration/adoption gate. Building safety evidence first prevents each feature from treating decoder success as sufficient replay proof. Combining everything in one compiler plan would obscure distinct risks: null ambiguity, calendar range, set quotient semantics, refinement admission, and symbolic-domain soundness. A final rehearsal catches combinations and consumer histories that isolated feature examples cannot cover.

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


## Integration Points


Plan 289 owns the compatibility report v1, baseline/candidate comparison semantics, and the release predicate. Features supply cases without weakening required verdicts. The report records immutable corpus/build identity and a versioned complete observation contract; separate executables permit old/new Haskell representations. Plan 295 owns the integrated corpus and adoption manifest, including high-water marks and consumer-specific evidence.

Plan 290 owns the bare checked-shape algebra and recursive nullability query. Plans 291–293 extend that common representation, not independent generators. Plan 294 owns ID admission-domain selection and projection evidence, which all structural/public/keyed-map consumers reuse. All feature plans share TypeGraph.hs, MappedCodecPlan.hs, Scaffold.hs, SemanticImpact.hs, MappedDiff.hs, FoldFingerprint.hs, Coverage.hs, StructuralConformance.hs, and LanguageVersion.hs under keiro-dsl/src/Keiro/Dsl. Add candidate capabilities without changing published behavior; constructors force exhaustive handling.

Each feature must define canonical type identity, admitted domain, canonical encoding, parser policy, and version before claiming support. Source presentation and wire identity remain separate. No new operation is solver-visible merely because its Haskell type has Eq or Ord. An exact ID domain must include every runtime-reachable owner, including historical internal construction paths; narrowing only the solver domain is prohibited.

Workflow codecs, step keys, generations, seeds, patch sets, await/index fallback, and deterministic identities remain independently owned. Plan 289 supplies regression checks, and Plan 295 supplies consumer journal evidence. The initiative adds no workflow-generated codec authority by implication. Renaming a step can execute a new side effect and is never an automatic migration remedy.

The total-binding/refinement distinction, historical interpretation gate, fixed wire-policy versions, and proof-domain ownership deserve ADR updates during implementation. Follow agents/skills/exec-plan/ADR.md for stable handle allocation, log updates, and strict profile validation. This planning pass retains existing architectural decisions and proposes no retroactive claim that new features already exist.


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


## Decision Log


2026-09-19: Accept all five feature directions with a mandatory preservation gate before implementation and an independent final adoption rehearsal. Prioritize truthful guarantees over making every consumer declaration checked immediately.

2026-09-19: Keep dates and byte refinements transport-only and restrict sets to Text initially. Mixed ID domains keep frozen generation policy and require complete runtime/symbolic agreement. All old-language contracts remain unchanged.

2026-09-19: Compare baseline and candidate interpretation, not only candidate snapshot/full replay. Bind evidence to input corpus, build identities, stable observations, and coverage. Unknown results block adoption; fixture success alone is not universal proof.

2026-09-19: Retain old workflow result readers and recorded patch branches for retained histories. A renamed step, continueAsNew, or disabled snapshot is not a substitute for journal compatibility. Run workflow historical checks only in isolated environments without production effects.


## Outcomes & Retrospective


Planning only. Seven child plans were created; no capability, migration, or historical replay check has been implemented by this document. Completion requires all child acceptance evidence and ADR distillation, with unavailable consumer data recorded as an outstanding adoption obligation.

Revision note (2026-09-19): Linked the Mina-created intention and clarified retained-reader, strict-failure, audit-tail, and rolling-reader obligations during authoring review. No implementation or historical audit has run.
