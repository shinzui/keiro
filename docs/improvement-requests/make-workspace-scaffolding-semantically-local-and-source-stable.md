---
type: Improvement Request
title: Make workspace scaffolding semantically local and source-stable
description: >-
  Keep a local DSL change from rewriting generated harnesses and behavior contracts for unrelated
  aggregates, while preserving complete workspace conformance and source-located diagnostics.
timestamp: 2026-08-10T03:36:12Z
requestId: IR-21
status: completed
origin: mori://shinzui/mori
completedAt: 2026-08-10T03:36:12Z
resolution: >-
  MasterPlan 34 and Plan 222 delivered checked semantic locality, one service structural owner,
  stable behavior source maps, impact reporting, restoring mutations, a pinned Mori replay, and a
  byte-clean regenerated corpus; fleet adoption still requires MasterPlan 35 and a release that
  contains both gates.
plan: docs/plans/222-certify-source-stable-semantic-locality-before-fleet-adoption.md
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-08-09T18:41:22Z
    document_timestamp: 2026-08-09T18:41:22Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Reviewed against Mori's Keiro Language-4 workspace regeneration for ExecPlan 181. Three
      optional fields changed Project/ProjectArtifact payloads, but every aggregate harness gained
      the same global structural assertions and unrelated behavior contracts changed only
      absolute source-line metadata.
  - kind: model
    reviewer: codex
    reviewed_at: 2026-08-09T21:37:23Z
    document_timestamp: 2026-08-09T18:41:22Z
    scope: technical-accuracy
    outcome: changes_requested
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Requested corrections before implementation: the checked TypeGraph has mapped roots only
      for command fields, private-event fields, and registers; declaration-owned binding and
      fixture laws must run once at service scope rather than be deleted from or duplicated across
      aggregate harnesses; queue, public-contract, read-model, and projection consumers require a
      future typed-root design.
---

# Improvement Request: Make Workspace Scaffolding Semantically Local and Source-Stable

## Status

**Completed.** [MasterPlan 34](../masterplans/34-make-keiro-dsl-regeneration-semantically-local-and-source-stable-before-wide-adoption.md)
and [Plan 222](../plans/222-certify-source-stable-semantic-locality-before-fleet-adoption.md)
delivered the corrected checked-root model, localized aggregate evidence, one service structural
owner, stable behavior source maps, semantic-versus-artifact impact reporting, restoring
mutations, and the regenerated conformance corpus. This closes the Keiro locality prerequisite;
wide fleet adoption remains blocked on MasterPlan 35's mapped-consumer qualification and on a
Keiro release containing both complete gates.

The pinned regression for
`mori://shinzui/mori/plans/181-add-dependency-version-constraints-and-upstream-pointers`
changes only Project and ProjectArtifact as aggregate consumers and the three intended payload
declarations. Generated churn falls from 22 files/1,869 lines to 9 files/629 lines, or 8 files/27
lines when the deliberately isolated 602-line positional source map is excluded. The minimized
fixture keeps its four-file semantic delta constant while ten unrelated aggregates are added, and
source movement changes only the context source map plus source-bearing ledger provenance while a
failing witness reports the new exact position.

## Context

Mori's
`mori://shinzui/mori/plans/181-add-dependency-version-constraints-and-upstream-pointers`
added three optional fields to structural payloads:

- `ProjectMetadataPayload.upstream`;
- `DependencyArtifactPayload.versionConstraint`; and
- `RepositoryRefArtifactPayload.upstream`.

The expected generated changes were local: the three structural shapes, their bindings and
fixtures, and the Project and ProjectArtifact codecs, harnesses, and behavior contracts. Workspace
scaffolding also rewrote outputs for aggregates that have no command field, private-event field, or
register capable of reaching those payloads.

Two independent amplification mechanisms were visible.

First, each aggregate harness embeds coverage for the workspace's complete structural-shape
inventory. App, Automation, Group, Reaction, Repository, SignalDelivery, SignalEmission, and
Workflow therefore all gained the same assertions for the three new optional fields even though
none of those aggregates can reach the changed shapes. Whole-service conformance should prove
each mapped shape, but repeating the full inventory in every aggregate harness makes every shape
change look service-wide.

Second, generated behavior contracts persist absolute `.keiro` line numbers in
`requirementLine` values and source-location comments. Adding lines in an earlier workspace member
rewrote otherwise unchanged contracts in later members. Requirement keys, transition identity,
behavior witnesses, and runtime semantics remained stable; only the positional evidence moved.
The generated files are checked in, so volatile positions become source churn rather than an
ephemeral diagnostic detail.

The result in Mori was over a thousand changed generated lines for a three-field feature. The
output was deterministic and could not safely be edited down by the consumer: removing unrelated
changes by hand would make the next `keiro-dsl scaffold` run non-idempotent. The tool must own the
locality guarantee.

## Requested Change

Make generated impact follow semantic reachability and give durable behavior requirements stable
source anchors.

### Checked semantic impact and conformance ownership

Compute the structural mapped-type closure reachable from each aggregate's command fields,
private-event fields, and registers. Snapshot impact follows register use because snapshots cache
the register file. Emit aggregate harness evidence only for uses in that closure. Shared shapes
used by several aggregates may contribute use-specific codec, wire-policy, replay, snapshot, or
projection-witness evidence to each relevant harness; shapes unreachable from an aggregate's
checked roots must not.

Keep one service-level structural inventory in the generated conformance package. That boundary
owns declaration-wide binding round trips, canonical identity, fixture labels, enum/union/optional
branch coverage, unknown-field policy, opaque-boundary checks, and the declaration's projection
witness laws. Each declaration-wide law executes exactly once even when several aggregates use the
declaration or none currently does. Locality must reduce duplicate output, not weaken coverage.
The checker must fail before writes if any mapped declaration lacks mandatory fixture or binding
evidence.

The current checked `TypeGraph` has no mapped `TypeExpr` roots for queue payloads, public
contracts, read-model query schemas, or aggregate-owned projections. Those surfaces must remain
explicitly unsupported by this impact model until a future language change adds typed roots and
extends checking, generation, reporting, and conformance together.

### Stable behavior-source anchors

Keep semantic requirement identity independent of absolute line numbers. Checked-in behavior
contracts should use the existing stable requirement key, or another file-qualified semantic
anchor, as durable identity. Current line and column may still be rendered in diagnostics and
reports by resolving the anchor against the current source map, but inserting comments, blank
lines, declarations, or fields before an unchanged requirement must not rewrite its generated
contract row.

If exact positions must remain in a generated artifact for offline diagnostics, isolate them in
one source-map artifact whose change does not rewrite behavior contracts and witnesses. Source
maps must be deterministic, file-qualified, and validated against the semantic anchors they
describe.

### Impact classification

Use the same reachability and stable-anchor model in workspace diff/scaffold planning. A changed
shape should report the aggregates that consume it through current checked roots, plus the
service-level conformance inventory. It must not manufacture queue, public-contract, read-model,
or projection consumers from untyped notation. Unrelated aggregates must not appear as impacted
merely because their harness currently repeats global assertions or because their source begins
later in a combined workspace position space.

## Acceptance

1. A two-aggregate workspace maps structural shape `SharedPayload`, but only Aggregate A can reach
   it through a command field, private-event field, or register. Adding a defaulted optional field
   changes the shape, A's use-specific codec/harness output, and the service-level conformance
   inventory; every generated Aggregate B file is byte-identical.
2. A shared shape reachable from both aggregates still produces use-specific evidence in both
   relevant aggregate harnesses. Its declaration-wide binding, canonical-identity, fixture-label,
   branch-coverage, opaque-boundary, and projection-witness laws execute once at service scope;
   removing mandatory declaration evidence fails check before scaffold writes.
3. Adding a comment, blank line, unrelated declaration, or optional field in an earlier workspace
   member leaves every semantically unchanged later behavior contract and witness byte-identical.
4. Behavior diagnostics still report the current file, line, and column after source movement,
   and a stale or unresolvable semantic anchor fails with a stable diagnostic rather than silently
   pointing at the old line.
5. `keiro-dsl diff` and scaffold impact output name only aggregates in the changed type's checked
   semantic reachability closure, while separately naming service-conformance impact and keeping
   unsupported root kinds explicit.
6. The generated whole-service conformance package executes every declaration-owned law exactly
   once, while each aggregate retains every codec, wire-policy, replay, snapshot, and generated
   projection assertion tied to its own checked uses. No fixture or use-specific evidence is lost.
7. A regression modeled on
   `mori://shinzui/mori/plans/181-add-dependency-version-constraints-and-upstream-pointers`
   adds the three optional payload fields and proves that only Project, ProjectArtifact, the three
   shapes, the context source map, and service-level conformance change.
8. Repeated single-spec and workspace scaffolds are byte-stable, the complete Keiro DSL and
   generated-conformance suites pass, and release notes identify the reduced-diff behavior for
   downstream consumers.

## Compatibility and Scope

This request changes generated development artifacts and impact reports, not event wire formats,
Keiki runtime semantics, persisted streams, or public integration contracts. Existing consumers
should regenerate once when adopting the release; subsequent unrelated edits should produce
smaller diffs.

The request does not remove source locations from diagnostics, weaken aggregate or service
conformance, or make structural coverage optional. It also does not require a general incremental
build system or invent mapped roots for queue, public-contract, read-model, or projection surfaces:
correct dependency closure over the checked language and stable checked-in artifacts are the
target. Adding any future root kind must extend the exhaustive semantic-impact fold before the
toolchain compiles.

## Requested Deliverables

- One checked per-aggregate mapped-type reachability model and service declaration inventory,
  shared by harness generation and impact classification.
- A deduplicated service-level structural conformance inventory.
- Stable behavior requirement anchors with current-location resolution for diagnostics.
- Workspace fixtures proving byte-local regeneration and restoring mutations proving coverage was
  not weakened.
- Adoption and release documentation describing the one-time regeneration and future locality
  guarantee.

## References

- Originating consumer: `mori://shinzui/mori`.
- Reproducer and acceptance evidence:
  `mori://shinzui/mori/plans/181-add-dependency-version-constraints-and-upstream-pointers`.
- Affected toolchain package: `mori://shinzui/keiro/packages/keiro-dsl`.
