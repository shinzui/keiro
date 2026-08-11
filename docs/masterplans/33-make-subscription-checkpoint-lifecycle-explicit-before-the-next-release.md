---
id: 33
slug: make-subscription-checkpoint-lifecycle-explicit-before-the-next-release
title: "Make subscription checkpoint lifecycle explicit before the next release"
kind: master-plan
created_at: 2026-08-09T17:50:18Z
intention: intention_01kzrnkgtcey6a8ar7xqn9tjxx
---

# Make subscription checkpoint lifecycle explicit before the next release

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Before the next Keiro release, a service author must state what a subscription means when its
exact durable checkpoint is absent: replay from the beginning, start at the current store head, or
refuse to start. Kiroku applies that choice atomically and owns the supported rewind statement.
Keiro records the choice in its typed projection catalog, rejects combinations that would make a
replayable projection silently skip history, exposes the choice to operators, and uses Kiroku's
transaction API during coordinated rebuilds. Candidate Language 5 requires and generates the same
choice, so the next service cannot inherit today's implicit position-zero behavior by accident.

The initiative includes the Kiroku prerequisite, Keiro runtime/catalog adoption, coordinated
rebuild integration, candidate Language 5 syntax and generation, structural diff classification,
tests, examples, and documentation. It excludes publishing packages, choosing final release
versions, changing Mori now, deleting checkpoints, arbitrary forward checkpoint movement, or
inventing consumer-group members that do not exist in Kiroku. Release work begins only after this
MasterPlan and the other accumulated breaking improvements are complete.


## Decomposition Strategy

The work follows ownership boundaries rather than repository convenience. The external Kiroku
prerequisite, `mori://shinzui/kiroku/plans/70-make-subscription-checkpoint-initialization-and-reset-semantics-explicit`,
defines atomic initialization and reset semantics beside the schema and SQL. EP-1 consumes that
contract in Keiro's hand-written runtime surface: catalog types, fingerprints, operator inventory,
validation, and coordinated rebuild. EP-2 then makes the unreleased candidate Language 5 express
and generate the EP-1 types and classify later policy changes. This ordering makes each boundary
independently testable and prevents the DSL from inventing runtime semantics.

Putting Kiroku SQL directly in Keiro was rejected because [ADR 28](../adr/0028-library-owned-operator-commands.md)
requires operator commands to use the owning library's public API. Treating the policy as an
unfingerprinted worker-only option was rejected because [ADR 26](../adr/0026-projection-catalog-identities.md)
makes catalog identity the shared authority for startup, planning, and operations. Adding an
optional Language 5 field or postponing it to Language 6 was rejected because Language 5 is still
unreleased; [ADR 4](../adr/0004-versioned-api-evolution-gates.md) permits correcting that candidate
now and avoids preserving an unsafe default as public language. The Mori ownership and write-path
criteria are recorded in `mori://shinzui/mori/okf/adrs/concepts/ADR-20` and
`mori://shinzui/mori/okf/adrs/concepts/ADR-21`.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Adopt explicit checkpoint lifecycle semantics in the projection catalog | [Plan 215](../plans/215-adopt-explicit-checkpoint-lifecycle-semantics-in-the-projection-catalog.md) | `mori://shinzui/kiroku/plans/70-make-subscription-checkpoint-initialization-and-reset-semantics-explicit` | None | In Progress |
| 2 | Generate and classify missing-checkpoint policy in candidate Language 5 | [Plan 216](../plans/216-generate-and-classify-missing-checkpoint-policy-in-candidate-language-5.md) | EP-1 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

The external
`mori://shinzui/kiroku/plans/70-make-subscription-checkpoint-initialization-and-reset-semantics-explicit`
is a hard gate for EP-1 because it supplies the closed policy type, atomic missing-row resolution,
typed failure, and transaction-composable reset report. EP-1 must not reproduce those statements
privately. Source-level work may be drafted in parallel, but EP-1 cannot pass acceptance until it
compiles and runs against the completed Kiroku source contract.

EP-2 depends on EP-1's final `SubscriptionDeclaration` and inventory shapes. Its parser, validator,
and diff tests may start once those shapes are agreed, but generated conformance output cannot be
accepted before EP-1 is stable. Documentation in the external runtime-patterns corpus is an
integration tail: update it only after both child plans prove the terminology and behavior.


## Integration Points

- The Kiroku checkpoint contract is defined only by
  `mori://shinzui/kiroku/plans/70-make-subscription-checkpoint-initialization-and-reset-semantics-explicit`.
  EP-1 consumes `MissingCheckpointPolicy`, initialization behavior, and
  `resetSubscriptionCheckpointsTx`; neither Keiro plan may issue SQL against Kiroku's
  `subscriptions` table.
- `Keiro.Projection.Catalog.SubscriptionDeclaration` and its inventory/registration projections
  are defined by EP-1. EP-2 must generate those exact types and must not maintain a DSL-only policy
  model after lowering.
- The catalog fingerprint, operator JSON, workspace baseline, and structural diff all observe the
  same policy. EP-1 owns runtime encoding; EP-2 owns source syntax, snapshot persistence, and the
  policy-change diff code. A test crossing generation, loading, inspection, and diff is the seam.
- Coordinated rebuild uses declared subscription names but Kiroku reports persisted member keys.
  EP-1 owns the rule that any declared name with no persisted members condemns the entire
  preparation transaction; neither plan derives topology from configured group size.
- Durable ownership, existing-row precedence, replay-safety validation, and the deliberate absence
  of checkpoint deletion or arbitrary forward movement should be captured in ADRs before the child
  plans complete. Execution ordering remains in this MasterPlan.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1: consume the completed Kiroku source contract and extend catalog/inventory identity.
- [x] EP-1: validate lifecycle combinations and replace private rebuild SQL with the public reset.
- [ ] EP-1: prove operator, rollback, example, documentation, and full-repository acceptance.
- [ ] EP-2: require and round-trip `checkpoint-on-missing` in candidate Language 5.
- [ ] EP-2: generate the runtime policy and reject replay-unsafe combinations before scaffolding.
- [ ] EP-2: classify policy diffs, update conformance/docs/patterns, and pass full acceptance.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- The omission is two related but distinct contracts. Kiroku needs atomic behavior for a missing
  exact member row; Keiro needs domain rules about which behavior is valid for a projection. A
  single default at either layer cannot substitute for both.
- Kiroku's released 0.4.0.0 checkpoint inventory is intentionally read-only, while Keiro's current
  grouped rebuild updates the private table and silently accepts zero affected rows. The repair
  therefore requires a new owning-library mutation API and an explicit caller-side refusal rule.
- Kiroku EP-70 completed and was published as `kiroku-store` 0.5.0.0 before EP-1 began. Hackage,
  upstream tag `kiroku-store-v0.5.0.0`, and the sibling source exports agree, so EP-1 can consume
  the released owning-library contract rather than relying on an unpublished source override.
- Kiroku's reset report composes cleanly inside Keiro's existing condemned preparation
  transaction. A focused two-member test resets both rows, while a second test proves that one
  absent declared name rolls back the target clear, group fence, dedup deletion, and already
  matched member resets together.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Make policy explicit in the unreleased candidate Language 5 with no compatibility
  fallback in that language.
  Rationale: There is no released Language 5 syntax to preserve. Requiring the field now prevents
  a later breaking language version and makes omission visible to every new service.
  Date: 2026-08-09

- Decision: Keep atomic initialization and checkpoint SQL in Kiroku; keep catalog validity and
  rebuild condemnation in Keiro.
  Rationale: Schema ownership belongs with the library, while only Keiro knows whether skipping
  history would violate a declared replay contract.
  Date: 2026-08-09

- Decision: A missing persisted row during coordinated rebuild is an error, not an invitation to
  synthesize consumer-group topology.
  Rationale: The catalog declares subscription names, not authoritative member rows. Proceeding
  after target clearing would create a partial or unrecoverable rebuild.
  Date: 2026-08-09

- Decision: Do not publish, tag, or choose final dependency bounds in this initiative.
  Rationale: The user is intentionally collecting all breaking language/runtime improvements for
  one later coordinated release.
  Date: 2026-08-09

- Decision: Consume the published `kiroku-store` 0.5 series and advance direct source-package
  bounds to `>=0.5 && <0.6`; continue deferring Keiro version selection and publication.
  Rationale: Kiroku EP-70 was released after this MasterPlan was written. Keiro now requires API
  that does not exist in 0.4, and the authoritative Hackage release and upstream tag establish the
  compatible dependency series without deciding the later Keiro release version.
  Date: 2026-08-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

(To be filled during and after implementation.)
