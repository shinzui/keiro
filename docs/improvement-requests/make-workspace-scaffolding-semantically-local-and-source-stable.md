---
type: Improvement Request
title: Make workspace scaffolding semantically local and source-stable
description: >-
  Keep a local DSL change from rewriting generated harnesses and behavior contracts for unrelated
  aggregates, while preserving complete workspace conformance and source-located diagnostics.
timestamp: 2026-08-09T18:41:22Z
requestId: IR-21
status: proposed
origin: mori://shinzui/mori
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
---

# Improvement Request: Make Workspace Scaffolding Semantically Local and Source-Stable

## Status

Proposed for the next Keiro release. This is not a generated-runtime correctness defect: current
output compiles and the whole-service conformance package passes. It is an adoption and review
quality defect because a small, local contract change creates a large semantically unrelated diff
that reviewers must audit and downstream repositories must carry.

## Context

Mori's
`mori://shinzui/mori/plans/181-add-dependency-version-constraints-and-upstream-pointers`
added three optional fields to structural payloads:

- `ProjectMetadataPayload.upstream`;
- `DependencyArtifactPayload.versionConstraint`; and
- `RepositoryRefArtifactPayload.upstream`.

The expected generated changes were local: the three structural shapes, their bindings and
fixtures, and the Project and ProjectArtifact codecs, harnesses, and behavior contracts. Workspace
scaffolding also rewrote outputs for aggregates that cannot command, emit, register, queue, or
project any of those payloads.

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

### Aggregate-local structural coverage

Compute the structural mapped-type closure reachable from each aggregate's commands, private
events, registers, snapshots, queue payloads, and aggregate-owned projections. Emit aggregate
harness assertions only for that closure. Shared shapes used by several aggregates may appear in
each relevant harness; shapes reachable by none of an aggregate's surfaces must not.

Keep one service-level structural inventory in the generated conformance package so every mapped
shape and fixture is still proved at least once. Locality must reduce duplicate output, not weaken
coverage. The checker should fail before writes if a reachable mapped shape has no fixture or
binding evidence.

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
shape should report the aggregates and read models that consume it, plus the service-level
conformance inventory. Unrelated aggregates must not appear as impacted merely because their
harness currently repeats global assertions or because their source begins later in a combined
workspace position space.

## Acceptance

1. A two-aggregate workspace maps structural shape `SharedPayload`, but only Aggregate A can reach
   it. Adding a defaulted optional field changes A's shape/codec/harness output and the
   service-level conformance inventory; every generated Aggregate B file is byte-identical.
2. A shared shape reachable from both aggregates still produces coverage in both relevant
   aggregate harnesses, and deleting either aggregate's fixture/binding evidence fails check
   before scaffold writes.
3. Adding a comment, blank line, unrelated declaration, or optional field in an earlier workspace
   member leaves every semantically unchanged later behavior contract and witness byte-identical.
4. Behavior diagnostics still report the current file, line, and column after source movement,
   and a stale or unresolvable semantic anchor fails with a stable diagnostic rather than silently
   pointing at the old line.
5. `keiro-dsl diff` and scaffold impact output name only aggregates/read models in the changed
   type's semantic reachability closure, while separately naming service-conformance impact.
6. The generated whole-service conformance package continues to prove every mapped structural
   type exactly once or through an explicitly deduplicated shared assertion; no fixture, codec,
   replay, snapshot, or projection evidence is lost.
7. A regression modeled on
   `mori://shinzui/mori/plans/181-add-dependency-version-constraints-and-upstream-pointers`
   adds the three optional payload fields and proves that only Project, ProjectArtifact, the three
   shapes, and service-level conformance change.
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
build system: correct semantic dependency closure and stable checked-in artifacts are the target.

## Requested Deliverables

- One checked per-aggregate mapped-type reachability model shared by harness generation and impact
  classification.
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
