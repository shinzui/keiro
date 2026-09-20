---
type: Architecture Decision Record
title: DSL retirement requires complete retained-history evidence
description: DSL and API simplification must preserve aggregate replay, process recovery, and workflow continuation through complete compatibility evidence and an explicit implementation-retirement gate.
timestamp: 2026-09-20T20:55:54Z
docId: ADR-47
status: Accepted
date: 2026-09-19
originatingPlan: docs/masterplans/44-add-checked-value-mappings-while-preserving-stream-and-workflow-replay-across-refactors.md
---

# DSL retirement requires complete retained-history evidence

## Context

Keiro is preparing its DSL and public APIs for 1.0. Checked domain-value mappings
should simplify adoption and let the implementation consolidate obsolete authoring
paths. A successful new example, unchanged JSON, or an unused old writer does not
establish that an old implementation can be removed. Retained events, queued jobs,
process witnesses and timers, and workflow results may still depend on it.

The existing mapped consequence inventory is intentionally narrower than the whole
service. Aggregate replay impact also does not describe process redelivery or
workflow continuation. A process reaction can recover the same saga witness and
then recompute different target commands from the same source event. An unchanged
binding or workflow function name can conceal different Haskell behavior.

Candidate language code ships in package releases. Language publication therefore
cannot be the only point at which persisted behavior becomes an obligation.

## Decision

Replay correctness controls DSL/API simplification. Maintain one checked authoring
path where possible and reduce redundant implementation, while preserving every
retained-history interpretation still covered by the supported contract. Removing
old syntax or a writer and removing historical semantics are separate decisions.

The compatibility gate consumes an independently derived inventory bound to the
baseline and candidate builds. Its required surfaces are the union of old and new
service inventories, ordinary diff compatibility findings, aggregate replay impact,
mapped consequences, checked process coordination facts, and explicit application-owned
workflow and Hole obligations. Removed declarations remain obligations. Missing
metadata or unknown impact cannot reduce the inventory; require a full applicable
comparison or record an unverified result. Equal wire fingerprints are one input,
not proof of equal interpretation. Compare complete semantic observations and
selected continuations over identical immutable history, with explicit lossless
adapters and coverage. Finite tests remain scoped evidence, not a theorem about
arbitrary future Haskell refactors.

Aggregate replay, process recovery, and workflow continuation have separate verdicts.
Process evidence preserves source/manager/correlation identities, saga witnesses,
target commands and occurrences, identity families, and timer behavior through
partial completion. Workflow evidence preserves generations, durable keys, stored
results, seeds, and recorded patch decisions. Preserve existing at-least-once retry
semantics rather than claiming exactly-once effects. A changed identity family or
step key cannot be called a source refactor merely because a version was bumped.

Package release, language publication, consumer adoption, and implementation
retirement have distinct predicates. A new Keiro-owned wire policy introduced by
MasterPlan 44 freezes at its first package release, even in a candidate language;
commit its contract vectors before that release. A later correction needs a new
policy identity and a reachable old reader. The candidate amendment policy in
[ADR-16](0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
allows authoring changes but does not waive preservation of data already written.
Removing a candidate capability requires a retained compatible replay path or
evidence that it has no durable use; otherwise delay the removal/publication.

An implementation-retirement decision names exact symbols/files, their replacement,
known dependents, supported source/build contracts, retained-data obligations, and
evidence. Prove a bounded removal or consolidation in an isolated checkout using
the supported-language corpus and old-history comparisons. Keep minimal compatibility
adapters where needed. A registry with no known dependent is not universal proof of
non-use. In particular, preserve ADR-24's legacy identity-probe removal conditions
and ADR-41's positional versus target-keyed process identity boundary.

Unavailable consumer history blocks that consumer's adoption and any retirement
claim depending on it. It need not block additive feature publication backed by
complete repository evidence. Known failures are never recast as unavailable data.
New public APIs also require executable clean-scaffold examples, regeneration that
preserves user code, and actionable unsupported-use diagnostics; ergonomics cannot
be obtained by weakening validation or hiding manual compatibility obligations.

## Consequences

Plan 289 implements the shared evidence contract, recurring verification, and
process/workflow continuation cases. Plan 295 adds the integrated checked-
mapping corpus, real generated aggregate replay, negative semantic mutations,
and a machine-checked manifest with separate package-release, language-
publication, consumer-adoption, and implementation-retirement results. The
repository evidence makes the first two eligible without performing either
action.

An immutable rehearsal for `mori://shinzui/rei` now makes that consumer's
adoption eligible. Identical baseline and candidate restores selected 10,061
retained streams, produced byte-identical replay reports with zero unexpected
failures, inventoried the five adopted value families, and completed
effect-isolated process redelivery without changing durable observations or
creating dead letters. Rei's workflow inventory was verified as empty and is
reported explicitly as `not-applicable-empty-history`, rather than as missing
access or a synthetic continuation pass. Private payloads remain outside this
repository.

The same rehearsal approves one exact bounded retirement: replace Rei's
`ActionId mapped opaque rei.disruption.ActionId.json@1` authoring declaration
and its 40 mapped-surface expectations with the checked v5-or-v7 nominal path.
The rehearsal does not authorize deletion of Keiro's generic mapped-opaque
support, any historical reader, replay-only transition, workflow branch,
process identity family, or published-language implementation. The consumer
source edit and deployment remain separately authorized actions.

The 1.0 preparation can remove redundant code incrementally without coupling every
new capability to access to every consumer database. A required historical reader,
replay-only transition, workflow branch, process runner, or identity probe may remain
after its authoring path is consolidated. That is a correctness requirement, not an
exception that a release deadline can waive.

## Related decisions

- [ADR-4](0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) defines layered evolution evidence.
- [ADR-12](0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md) defines schema authority and total bindings.
- [ADR-18](0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md) defines aggregate fold identity.
- [ADR-24](0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md) defines frozen identity and legacy-probe retirement conditions.
- [ADR-41](0041-process-manager-reactions-use-accepted-witnesses-and-target-keyed-recovery.md) defines process recovery and identity migration.
