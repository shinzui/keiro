---
id: 38
slug: finalize-projection-ownership-and-query-freshness-before-stable-language-5
title: "Finalize projection ownership and query freshness before stable Language 5"
kind: master-plan
created_at: 2026-08-12T12:12:45Z
intention: "intention_01kzty1w82ey5vg2b86nkw83sk"
---

# Finalize projection ownership and query freshness before stable Language 5

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

The 0.12.0.0 release is Keiro's first stable release and the point at which broad fleet
adoption begins. Before that boundary, candidate Language 5 must say plainly which
component writes projection targets and what, if anything, a query waits for. One
catalogued inline projection owner must be able to transactionally maintain several
targets that supply several separately typed query models, without duplicating a legacy
aggregate `projection` clause for each query. Language 5 source must then put
`delivery = inline | subscription` on that owner and
`freshness = immediate | wait-for-head ...` on the query model. Generated code and the
public runtime API must use the same honest concepts.

This initiative implements
`docs/improvement-requests/let-one-inline-projection-owner-supply-multiple-query-models.md`
(IR-23) and
`docs/improvement-requests/separate-projection-delivery-from-query-freshness.md`
(IR-24). After it completes, runtime catalog validation and DSL checking resolve a
catalog-bound query model to exactly one compatible target owner without relying on list
order; immediate queries require no cursor; head waits resolve one compatible durable
subscription cursor; and the old `Strong`, `Eventual`, and `PositionWait` runtime names
have a tested migration window rather than silently changing meaning.

Explicitly excluded is
`docs/improvement-requests/make-derived-and-conditional-event-payload-mappings-declarative.md`
(IR-25). That is a useful Language 6 feature, but it expands the expression/type checker,
Keiki output inversion, fingerprints, and generated behavior. It is not needed to make
the projection contract truthful and would enlarge the first-stable release surface.
Also excluded are the remaining runtime defects in
`docs/masterplans/37-fix-the-keiro-runtime-and-operational-defects-surfaced-by-the-pre-0-12-release-review.md`;
they retain their own release gate. Completed MasterPlan 36 remains closed. Release
versioning, tags, and the final Language 5 registry promotion happen only after this
MasterPlan and the required parts of MasterPlan 37 complete.


## Decomposition Strategy

The work is split into three independently reviewable contracts. EP-1 fixes the shared
semantic foundation: validated owner-to-query resolution in the runtime catalog and the
DSL checker. EP-2 changes the public Haskell vocabulary and waiting configuration while
preserving a deliberate compatibility path. EP-3 owns the candidate Language 5 grammar,
lowering, generation, diff, harness, corpus, and documentation changes. Splitting the
runtime API from the language change keeps the public-package migration independently
compilable and lets registered downstream Haskell packages be audited before generated
code switches to the new surface. EP-3 depends on both earlier contracts because it must
generate their final types and consume the authoritative resolution rather than invent a
second algorithm.

IR-23 is not folded into EP-3 alone because programmatically assembled
`ProjectionCatalog` values require the same closed-world validation as DSL-generated
catalogs; a DSL-only repair would leave an order-sensitive or ambiguous runtime escape
hatch. IR-24 is not one monolithic plan because public API compatibility and frozen
language compatibility have different evidence and rollback boundaries. IR-25 is not a
fourth child because its output-expression language is independent of projection
ownership and query waiting.

Relevant decisions are
`docs/adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md`
(Languages 1-4 are immutable while candidate 5 may be corrected in place),
`docs/adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md`
(semantic capabilities and fingerprints, not surface spelling alone, define behavior),
`docs/adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md`
(generated facts need compiled conformance),
`docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
(the catalog owns distinct query, target, group, and handler identities),
`docs/adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md`
(a durable subscription cursor and its missing-checkpoint policy are operational
identity), and
`docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`
(canonical identity changes require explicit prefix changes and reviewed adoption).
No cross-repository ADR changes this decomposition. The originating consumer is named by
the canonical project URI `mori://tan/notification-render-service`.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Make projection owners authoritative for catalog-bound query models | docs/plans/243-make-projection-owners-authoritative-for-catalog-bound-query-models.md | None | None | Complete |
| 2 | Introduce truthful query-freshness runtime APIs with compatibility | docs/plans/244-introduce-truthful-query-freshness-runtime-apis-with-compatibility.md | EP-1 | None | In Progress |
| 3 | Separate Language 5 projection delivery from query freshness | docs/plans/245-separate-language-5-projection-delivery-from-query-freshness.md | EP-1, EP-2 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 is the foundation. It produces a deterministic, validated owner/query relationship
that includes the supplying projection, rebuild group, observed targets, delivery
capability, and optional subscription cursor authority. EP-2 consumes that relationship
when deriving a `ReadModel`'s cursor configuration, so it has a hard dependency on EP-1.
EP-3 consumes both the relationship and the final runtime names and therefore follows
EP-1 and EP-2. This sequencing also makes each intermediate commit compile: first the
runtime understands the semantic facts, then it offers the new API, then Language 5 emits
it.

EP-2 has a soft external dependency on Plan 238 in MasterPlan 37,
`docs/plans/238-target-strong-consistency-waits-at-the-visible-store-head.md`. That plan
corrects which head a captured-head wait may safely target. EP-2 can develop its types and
compatibility layer before Plan 238, but final wait-behavior acceptance and documentation
must be run after both changes are present. If EP-2 lands first, it must preserve the
`storeHeadPosition` seam so Plan 238 changes one implementation rather than reintroducing
old terminology.

Completed Plan 237,
`docs/plans/237-canonicalize-catalog-fingerprint-preimages-and-support-catalog-evolution.md`,
is a prerequisite already satisfied, not a child to reopen. EP-1's relationship is
derivable from already fingerprinted target-owner and observed-target facts. EP-2/EP-3 add
query freshness as a new catalog policy; under ADR 0032 they own the corresponding
canonical-format prefix bump and adoption evidence. Plan 237 remains an accurate record
of the implementation it completed.


## Integration Points

`keiro/src/Keiro/Projection/Catalog.hs` is shared by all three plans. EP-1 owns the
normalized `ResolvedQuerySupply` relation and its diagnostics. EP-2 extends the normalized
inventory with freshness and cursor configuration while preserving the public query-binding
record during the compatibility window. EP-3 only constructs the underlying runtime values
from checked Language 5 declarations; it must not reproduce owner lookup.

`keiro/src/Keiro/ReadModel.hs` is owned by EP-2. EP-1 may name delivery and cursor
capabilities but must not perform the public API rename. EP-3 consumes EP-2's final
`QueryFreshness`, wait-option, and cursor interfaces in generated code. Plan 238 may edit
the visible-head query in the same module; EP-2 preserves that function boundary and
coordinates tests rather than duplicating head SQL.

`CatalogInventory`, `fingerprintInventory`, `groupSliceFingerprint`, and the replay
contract connect EP-2 and EP-3 to completed Plan 237. Query freshness is operational
query-binding policy, so it enters both whole-catalog and owning-group slice preimages.
The canonical tags/prefixes advance together (`catalog-v3`, `slice-v2`, `contract-v3`,
and replay format v3), with tests showing unrelated groups remain slice-stable and a
freshness change produces reviewed slice drift. The existing adoption API is reused; no
direct SQL escape hatch or rewrite of Plan 237 is allowed.

The Language 5 semantic graph and consumers in
`keiro-dsl/src/Keiro/Dsl/Grammar.hs`, `Parser/`, `Validate.hs`, `PrettyPrint.hs`,
`Diff.hs`, `Scaffold.hs`, `ScaffoldRecord.hs`, and `Harness.hs` are owned by EP-3 after
EP-1 supplies shared owner resolution. Languages 1-4 continue to lower their frozen
`feed`/`consistency`/`scope` syntax into the new semantic concepts, and language-aware
rendering/scaffolding preserves their bytes.

The durable outcome should amend ADRs 0026 and 0032, and add or amend the reachable-wait
decision produced by Plan 238. It should record that delivery belongs to the projection
owner, freshness belongs to the query, and cursor capability is derived from a validated
relationship rather than declaration order.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1 (243) M1: runtime owner/query resolution type, capability matrix, and deterministic catalog diagnostics
- [x] EP-1 (243) M2: Language 5 catalog-managed read-model validation uses owner/target resolution; legacy standalone behavior remains version-gated
- [x] EP-1 (243) M3: generated catalog, scaffold, diff, harness, and fixture evidence for one owner supplying several query models
- [x] EP-1 (243) M4: documentation, ADR amendments, changelog, and full verification
- [x] EP-2 (244) M1: compatibility matrix and truthful runtime `QueryFreshness`/cursor types
- [x] EP-2 (244) M2a: query execution derives and validates wait capability; old names retain tested semantics
- [ ] EP-2 (244) M2b: run visible-tail-GC and genuinely-behind acceptance after external Plan 238 completes
- [x] EP-2 (244) M3: canonical inventory/slice/runner format bump and adoption regressions
- [x] EP-2 (244) M4a: registered dependent audit, API/ADR documentation, changelog, and full repository verification
- [ ] EP-2 (244) M4b: record the external Plan-238 integration evidence from M2b
- [ ] EP-3 (245) M1: Language 5 owner-only `delivery` and query-only `freshness` grammar/AST/pretty-print
- [ ] EP-3 (245) M2: capability-based validation and generated runtime configuration
- [ ] EP-3 (245) M3: separate diff, scaffold-ledger, harness, workspace, and compiled-corpus facts
- [ ] EP-3 (245) M4: Languages 1-4 byte-compatibility proof, migration/reference docs, ADRs, changelog, and full verification


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Planning audit (2026-08-12): completed Plan 237 already fingerprints each target's
  projection owner, each query's observed targets/group, handler delivery kind, and async
  subscription identity. IR-23's resolved supplier is therefore a deterministic view over
  existing identity rather than a new independent catalog fact. IR-24's freshness policy
  is new identity and triggers ADR 0032's mandatory format-prefix rule.
- Planning audit (2026-08-12): runtime `ReadModel` stores `subscriptionName`,
  `defaultConsistency`, and `strongScope` even for immediate inline models. A constructor
  rename alone cannot make this honest; EP-2 needs an explicit optional cursor authority
  and must document the source-compatibility limit for direct record construction.
- Planning audit (2026-08-12): Plan 238 is not yet implemented and changes the exact
  captured-head behavior that `WaitForHead` will expose. It remains a soft development
  dependency but a hard release integration gate for EP-2's behavioral acceptance.
- EP-1 M1 (2026-08-12): the current canonical inventory does not sort a projection's
  set-valued `ownedTargets`; changing their order therefore changes `catalog-v2` and
  `slice-v1`. The supply relation itself now resolves independently of that order. ADR
  0032 requires the fingerprint correction to ride Plan 244's explicit format-prefix
  bump and adoption evidence instead of silently changing the existing formats in EP-1.
- EP-1 M3 (2026-08-12): a full 39-entry corpus regeneration changed only the three
  candidate Language 5 catalog suites. Languages 1-4 remained byte-identical while all
  affected catalog conformance packages compiled and passed; mutation coverage proves
  query count cannot duplicate source-selected inline handlers or truncate suppliers.
- EP-1 M4 (2026-08-12): repository-wide verification passed the runtime, operations,
  PGMQ, DSL, integration, migration, ADR, and 39-entry corpus gates. The full DSL suite
  also exposed five stale aggregate-consumer, coverage, compatibility, and fixture-
  inventory expectations; correcting them confirmed that catalog ownership is now the
  sole mapped projection authority rather than leaving hidden legacy ownership facts.
- EP-2 M2a (2026-08-12): truthful and legacy query execution now share schema/liveness,
  polling, timeout telemetry, and SQL execution, and the focused 27-example runtime group
  passes. Plan 238 remains Not Started in MasterPlan 37, so EP-2 preserves the
  `storeHeadPosition` seam and keeps visible-tail-GC acceptance as an explicit pending gate.
- EP-2 M3 (2026-08-12): catalog validation derives wait cursor authority from compatible
  owner handlers and rejects missing or ambiguous cursor capabilities deterministically.
  The identity boundary advanced to `catalog-v3:`, `slice-v2:`, `contract-v3:`, and replay
  v3; focused adoption tests prove old slices are stale-format and active v2 runs cannot
  resume under the new runner.
- EP-2 M4a (2026-08-12): Mori found no Language 5 adopters. Four actual runtime
  dependents exercise the preserved direct-record/legacy override surface, one uses only
  an unaffected cursor helper, and nine project-level dependents have no Haskell
  `Keiro.ReadModel` imports. Full verification passed after the supported operator command
  previewed and explicitly adopted Jitsurei's live `slice-v1:` metadata to `slice-v2:`.
- EP-2 M4a (2026-08-12): frozen Languages 1-4 generated artifacts compile under a
  generated-output `-Werror` gate. Their Cabal stanza now disables only Haskell
  deprecation warnings so their bytes remain frozen; handwritten callers still see the
  0.12 warnings, and Plan 245 owns truthful candidate-Language-5 generation.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Create MasterPlan 38 instead of reopening completed MasterPlan 36.
  Rationale: MasterPlan 36 achieved and verified its four declared language-surface
  repairs. IR-23 and IR-24 are newly accepted release work with their own intention,
  dependencies, and acceptance evidence; rewriting completed history would obscure what
  was actually delivered.
  Date: 2026-08-12
- Decision: Include IR-23 and IR-24 in 0.12, split across three ExecPlans; defer IR-25 to
  Language 6.
  Rationale: Ownership and truthful waiting semantics would otherwise freeze a misleading
  first-stable contract and block the originating consumer. Declarative derived event
  payloads are useful but independent, much larger, and retain a hand-owned escape hatch.
  Date: 2026-08-12
- Decision: Runtime catalog validation, not only DSL validation, owns the authoritative
  owner/query relationship.
  Rationale: programmatic catalogs are public and must receive the same closed-world,
  order-independent guarantees as generated catalogs.
  Date: 2026-08-12
- Decision: Keep Plan 237 complete and place all new fingerprint-format work in EP-2.
  Rationale: Plan 237 correctly implemented ADR 0032's current canonical formats and
  adoption path. Adding a new policy is a later identity revision; its own plan must bump
  prefixes and prove adoption rather than retrospectively changing a completed plan.
  Date: 2026-08-12
- Decision: Include set-valued projection-owned-target normalization in EP-2's canonical
  format revision rather than EP-1's derived relation.
  Rationale: EP-1 found that current `catalog-v2`/`slice-v1` hashes preserve owned-target
  declaration order. ADR 0032 forbids changing that canonical identity under the same
  prefix. EP-2 already owns the next prefix, adoption, and compatibility evidence, while
  EP-1 can make owner/query resolution order-independent without changing persisted
  identity.
  Date: 2026-08-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

EP-1 is complete. Programmatic and Language 5 catalogs now share an order-independent,
validated query-supplier relation derived from target ownership. Generated code selects
one source handler per owner even when that owner supplies several typed queries, while
query backing stays independently explicit. The relation is visible in runtime
inventory access, scaffold ledgers, diffs, and compiled harness facts; ambiguity and
legacy double ownership fail before generation or execution.

EP-1 completed IR-23's semantic foundation without changing Languages 1-4 or the then-
current canonical fingerprint prefixes. EP-2 subsequently advanced those formats under
its own reviewed identity revision.

EP-2 is implemented and fully verified within MasterPlan 38's repository authority.
Truthful runtime construction/execution, catalog-derived wait cursors, canonical v3/v2/v3
identity, explicit adoption, documentation, and downstream compatibility evidence are in
place. The child remains In Progress solely for its external Plan 238 visible-tail
integration gate; therefore EP-3 has not started.
