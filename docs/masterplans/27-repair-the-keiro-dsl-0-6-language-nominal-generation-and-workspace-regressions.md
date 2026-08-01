---
id: 27
slug: repair-the-keiro-dsl-0-6-language-nominal-generation-and-workspace-regressions
title: "Repair the Keiro DSL 0.6 language, nominal, generation, and workspace regressions"
kind: master-plan
created_at: 2026-08-01T00:15:17Z
intention: "intention_01kyxarnbbet3ajn0995gt65w9"
---

# Repair the Keiro DSL 0.6 language, nominal, generation, and workspace regressions

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Keiro 0.6.0.0 delivered language dispatch, typed aggregate expressions, nominal bindings, and
multi-file workspaces, but several implementations satisfied internal tests while violating the
original consumer outcomes. When this initiative is complete, released language preambles are
contextual and collision-free; one shared nominal declaration has one generated Haskell owner;
generated and consumer-bound IDs/enums participate in exact type-safe equality; declarative
`fields(Command)` events have generated output mappings rather than identity-copy Holes; and a new
language contract enforces ID prefixes without breaking historical replay.

The initiative repairs
[IR-11](../improvement-requests/parse-language-preambles-contextually-without-colliding-with-domain-identifiers.md),
[IR-12](../improvement-requests/make-nominal-id-and-enum-equality-first-class-in-aggregate-expressions.md),
[IR-13](../improvement-requests/generate-declarative-event-output-mappings-from-fields-command.md),
[IR-14](../improvement-requests/make-id-prefix-declarations-enforceable-and-evolution-safe.md),
and the reopened acceptance failure in
[IR-2](../improvement-requests/support-composable-multi-file-service-specifications-in-keiro-dsl.md).
It includes `keiro-core` only for published nominal contracts and `keiro-dsl` for parsing,
checking, generation, harnesses, evolution, workspaces, and documentation. Keiki `0.7.0.0` is now
the integration baseline: public `master` implements
`mori://shinzui/keiki/okf/improvement-requests/concepts/IR-2`,
`mori://shinzui/keiki/okf/improvement-requests/concepts/IR-3`, and
`mori://shinzui/keiki/okf/improvement-requests/concepts/IR-4`. Keiro work may start against that
API contract. Hackage and the upstream `v0.7.0.0` tag now publish the same release, so affected
plans may adopt the normal Keiro range `>=0.7 && <0.8` after repeating the authority check at the
dependency-edit milestone. General arbitrary nominal ordering, arithmetic, refined mappings, and
unbounded collection expressions remain out of scope.


## Decomposition Strategy

The six workstreams follow independently observable boundaries. EP-167 repairs parser dispatch and
feature gating without changing semantics. EP-168 repairs generated nominal ownership, the shared
module seam used by both equality and validated constructors. EP-169 threads the effective
language contract into semantic planning. EP-170 adds exact nominal equality using Keiki 0.7's
truthful projection domains. EP-159 is the existing unfinished behavioral-conformance plan; it is
reused and expanded for declarative event outputs and Keiki 0.7 edge attribution rather than
duplicated. EP-171 uses the semantic contract, shared owner, and Keiki 0.7 exact textual domains to
introduce versioned ID enforcement and legacy replay.

Completed MasterPlans 15, 25, and 26 remain historical records. Reopening their completed child
plans would erase the fact that their acceptance suites missed these regressions. A single giant
repair ExecPlan was rejected because parser compatibility, Haskell type identity, dependency-level
symbolic proof, output ownership, and replay migration have different failure modes and can be
verified independently. Separate nominal-equality and ID-domain consumer typeclasses were rejected
because the existing total `NominalBinding` is already the one schema authority.

Relevant durable decisions are [ADR 3](../adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md),
[ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md),
[ADR 12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md),
[ADR 14](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md),
[ADR 15](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md),
[ADR 16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md), and
[ADR 17](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md).
EP-168 must clarify ADR 14's generated owner, EP-169 must amend ADR 16's semantic boundary, and
EP-159/EP-171 must update ADR 17/ADR 3 consequences where implementation changes durable behavior.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 167 | Parse Keiro language preambles and feature gates from grammar context | docs/plans/167-parse-keiro-language-preambles-and-feature-gates-from-grammar-context.md | None | None | Not Started |
| 168 | Give shared workspace nominal declarations one generated Haskell owner | docs/plans/168-give-shared-workspace-nominal-declarations-one-generated-haskell-owner.md | None | None | Not Started |
| 169 | Thread the effective Keiro language contract through semantic planning | docs/plans/169-thread-the-effective-keiro-language-contract-through-semantic-planning.md | None | EP-167 | Not Started |
| 170 | Make nominal ID and enum equality exact in aggregate expressions | docs/plans/170-make-nominal-id-and-enum-equality-exact-in-aggregate-expressions.md | EP-168 | None | Not Started |
| 159 | Generate complete reachable-state Holes and spec behavioral conformance, including declarative event outputs | docs/plans/159-generate-complete-reachable-state-holes-and-spec-behavioral-conformance.md | None | EP-170 | Not Started |
| 171 | Enforce versioned ID prefix domains across construction decode replay and evolution | docs/plans/171-enforce-versioned-id-prefix-domains-across-construction-decode-replay-and-evolution.md | EP-168, EP-169 | EP-170 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-167, EP-168, and EP-169 can begin immediately. EP-167 touches parser mechanics while preserving
`ParsedSource`; EP-169 consumes that stable result and can proceed against the current parser, with
a final integration rebase if both land concurrently. EP-168 owns generated nominal placement and
is independent of language semantics.

EP-170 hard-depends on EP-168 because declaration-scoped projection tags and instances must be
emitted by the one shared nominal owner, not by duplicate aggregate modules. The former external
implementation dependency is satisfied by released Keiki 0.7.0.0, so API inspection and
Keiro-side integration planning may proceed. EP-170 itself still begins after EP-168 provides the
one shared nominal owner.

EP-159 can start checked `fields(Command)` output ownership, adopt released Keiki 0.7.0.0, and
consume its detailed-step/detailed-replay contract immediately. Its soft dependency on EP-170
means the final behavior fixture should include nominal equality, while neither workstream's core
implementation blocks the other.

EP-171 hard-depends on EP-169 because successor runtime semantics must reach validation and
generation, and on EP-168 because safe constructors/codecs must have one generated owner. It
integrates with EP-170's exact textual ID domain but can implement admission/replay policy without
waiting for nominal equality. The critical child-plan paths are EP-168 → EP-170 and
EP-169 plus EP-168 → EP-171; EP-167 and EP-159 run alongside them.


## Integration Points

1. **Parsed source and effective contract (EP-167, EP-169, EP-171).** EP-167 preserves
   `ParsedSource`; EP-169 defines `CheckedService` with one effective contract; EP-171 registers the
   first successor runtime semantic through that type. ADR 16 records the lasting boundary.

2. **Shared nominal generated module (EP-168, EP-170, EP-171).** EP-168 defines its stable module
   placement and use closure. EP-170 adds declaration-tagged equality witnesses; EP-171 adds safe
   constructors and internal legacy decoders. Neither later plan may emit aggregate-local duplicate
   types or instances. ADR 14 records the owner.

3. **Checked nominal registry and `NominalBinding` (EP-170, EP-171).** The existing registry and
   total binding remain authoritative. EP-170 derives equality; EP-171 derives validation. Binding
   name/version, representation, equality domain, and ID-domain version must agree in fingerprints,
   explain output, scaffold records, and conformance. ADR 12 owns the one-authority rule.

4. **Generated-versus-hand-owned behavior (EP-159, EP-170).** EP-170 produces authoritative guard
   terms. EP-159 defines checked event-output mappings and behavioral obligations. Both extend the
   generated transducer assembled by Plan 161 and preserve explicit Hole ownership. ADR 17 owns the
   durable boundary.

5. **Compatibility and replay surfaces (EP-168, EP-169, EP-170, EP-159, EP-171).** All plans touch
   fold fingerprints, diff, replay impact, scaffold records, and harness evidence. Each adds a typed
   segment from its checked model; no plan re-derives another's metadata from generated text. ADRs
   3 and 4 determine snapshot and earliest-gate consequences.

6. **Keiki 0.7 adoption (EP-170, EP-159, EP-171).** EP-170 consumes
   `mori://shinzui/keiki/okf/improvement-requests/concepts/IR-3` and
   `mori://shinzui/keiki/okf/improvement-requests/concepts/IR-4`; EP-159 consumes
   `mori://shinzui/keiki/okf/improvement-requests/concepts/IR-2`; EP-171 consumes the exact textual
   projection-domain surface from `mori://shinzui/keiki/packages/keiki`. Hackage `0.7.0.0` and the
   matching `v0.7.0.0` tag are the verified development and dependency baseline. Mori locates the
   source; the authority check is repeated immediately before bounds change.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-167: adversarial language collision corpus and grammar-positioned preamble parsing.
- [ ] EP-167: parsed/token-aware feature gates and complete compatibility validation.
- [ ] EP-168: one planned nominal owner and use closure for single files and workspaces.
- [ ] EP-168: compiled two-aggregate identity proof and non-destructive adoption.
- [ ] EP-169: checked effective semantic contract routed through all semantic consumers.
- [ ] EP-169: paired-version/workspace proof and ADR 16 amendment.
- [ ] EP-170: Keiki 0.7 exact-projection adoption and checked nominal equality model.
- [ ] EP-170: generated/bound equality, finite-domain proof, mutations, and fleet adoption.
- [ ] EP-159: checked declarative event-output mapping and removal of identity-copy Holes.
- [ ] EP-159: edge-attributed complete behavioral conformance and regeneration proof.
- [ ] EP-171: successor ID-domain contract, safe constructors, and boundary-specific codecs.
- [ ] EP-171: legacy replay migration, evolution classification, properties, and release proof.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- 2026-08-01: the full `keiro-dsl-test` suite passes 413 examples while the five target regressions
  remain. Capability tests explicitly expect IDs/enums to be `OpaqueOnly`; committed conformance
  Holes preserve identity-copy outputs; workspace tests never compile both rings; parser tests lack
  lexical collisions; generated-ID tests lack wrong-prefix public decoder cases.
- 2026-08-01: Keiki's released field-projection documentation admits one-way symbolic agreement,
  while `predicateTranslationExact` labels `TFieldProj` exact. A finite enum projected to
  unrestricted `Text` demonstrates why a Keiro-only typeclass would not close IR-12.
- 2026-08-01: unfinished Plan 159 already owns behavior obligations, output hooks, and runtime
  conformance. Updating and registering it avoids a duplicate IR-13 plan; all other nearby 0.6
  expression, language, nominal-binding, and workspace plans are complete.
- 2026-08-01: Keiki `0.7.0.0` is published on Hackage and tagged upstream as `v0.7.0.0` at commit
  `7c5d433ef4455e9e626347f89cb3a416bad62e72`. The authoritative source exposes the detailed
  step/replay attribution, conservative projection classification, exact projection domains, and
  reconstructible models required by EP-159, EP-170, and EP-171.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Create a corrective MasterPlan instead of reopening completed MasterPlans 15, 25, or
  26, and reuse unfinished Plan 159 as one child.
  Rationale: completed plans are evidence of the acceptance gaps. New work needs current progress
  and dependencies, while duplicate unfinished scope would split authority.
  Date: 2026-08-01

- Decision: Keep parser repair, nominal ownership, semantic-version threading, equality, output
  ownership/conformance, and ID migration as separate workstreams.
  Rationale: each produces independently verifiable user behavior and has different dependencies;
  combining them would hide release gates and make regression isolation difficult.
  Date: 2026-08-01

- Decision: Treat a declaration-scoped checked witness as nominal equality authority; a
  projection-tagged class may implement generated integration but `NominalEquality a` is rejected.
  Rationale: type-global instances are invisible to DSL planning, cannot express per-declaration
  domains, and duplicate the total versioned `NominalBinding` contract.
  Date: 2026-08-01

- Decision: Split the Keiki prerequisite into conservative exactness
  `mori://shinzui/keiki/okf/improvement-requests/concepts/IR-3` and exact domain/reconstruction
  `mori://shinzui/keiki/okf/improvement-requests/concepts/IR-4`.
  Rationale: Keiki can correct the false proof classification independently, while the larger
  domain capability can evolve without delaying that correctness release.
  Date: 2026-08-01

- Decision: Adopt released Keiki `0.7.0.0` as the shared API and dependency baseline for EP-159,
  EP-170, and EP-171.
  Rationale: Hackage and `v0.7.0.0` now publish the required producer work with matching versioned
  source. There is no remaining external release blocker; repository-local plan dependencies still
  determine execution order, and each dependency edit repeats the authority check rather than
  pinning a sibling checkout.
  Date: 2026-08-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

(Planning is updated for released Keiki 0.7.0.0; Keiro implementation has not started.)


Revision note: Updated the initiative for released Keiki `0.7.0.0`, verified on Hackage and through
the matching `v0.7.0.0` tag. EP-159 can begin now; EP-170/EP-171 can adopt the released API once
their repository-local hard dependencies are satisfied. No external Keiki release gate remains,
2026-08-01.
