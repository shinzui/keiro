---
id: 227
slug: extend-semantic-impact-conformance-and-evolution-reporting-to-every-mapped-surface
title: "Extend semantic impact conformance and evolution reporting to every mapped surface"
kind: exec-plan
created_at: 2026-08-09T20:45:31Z
intention: "intention_01kzkzswbae5dan7x42gx8fv1c"
master_plan: "docs/masterplans/35-make-mapped-types-first-class-across-queues-read-models-and-projections-before-fleet-adoption.md"
---

# Extend semantic impact conformance and evolution reporting to every mapped surface

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, every supported mapped consumer surface is governed by one checked impact and
conformance architecture. Given a mapped declaration, Keiro reports aggregate roots, workqueue
fields, read-model query positions, projection handlers, and service structural conformance from
the same graph. It separately explains persisted event, snapshot, queued-job, query API, and
projection rebuild consequences. No renderer or generator infers impact from which files happened
to change.

The service conformance facade still executes declaration-wide binding/fixture/canonical laws once.
It adds only surface-specific evidence where semantics differ: queue envelope round trips,
read-model query compilation, and projection source/fingerprint agreement. The resulting text,
JSON, scaffold ledgers, coverage reports, and diff compatibility vectors are deterministic,
extension-tolerant, and honest when an older ledger lacks new consumer evidence.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: extend MP-34's semantic-impact consumer/root algebra and snapshot format with
  all explicit and derived surfaces.
- [ ] Milestone 2: centralize surface-specific conformance under the one service facade without
  duplicating declaration-wide laws.
- [ ] Milestone 3: extend coverage, mapped diff, compatibility vectors, scaffold/diff reports, and
  ledgers with separate event/snapshot/queue/query/projection semantics.
- [ ] Milestone 4: mutation-test every classification, legacy record, ordering, and locality rule;
  update ADR/docs and pass focused/full validation before corpus qualification.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Extend the landed MP-34 model directly; no adapter or successor impact graph is
  permitted.
  Rationale: The purpose of MP-34 is one dependency authority. A second “external surface” graph
  would recreate drift between harnesses, reports, and generation.
  Date: 2026-08-09

- Decision: Encode consumers and consequences as orthogonal typed dimensions.
  Rationale: A projection may inherit an event root, a queue field is persisted but not event
  history, and a query result is a build/API consumer but not persisted. One flat severity or
  aggregate name cannot represent those facts soundly.
  Date: 2026-08-09

- Decision: Keep declaration conformance exactly once at service scope.
  Rationale: New consumer roots do not create new binding laws. Duplicating fixtures in each queue,
  read model, or projection harness would reintroduce the churn MP-34 removes.
  Date: 2026-08-09

- Decision: Treat missing historical consumer snapshots as unknown.
  Rationale: A legacy ledger cannot prove that a removed queue/query/projection consumer never
  existed. Rendering an empty previous set would be a false locality claim.
  Date: 2026-08-09

- Decision: Preserve existing compatibility fields and add surface data append-only.
  Rationale: Existing tooling may consume `keiro-dsl/diff-report/1` and coverage/ledger schemas.
  New facts must not silently reinterpret event history, replay, or snapshot flags.
  Date: 2026-08-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This plan hard-depends on [Plan 224](224-generate-mapped-workqueue-payloads-with-honest-persisted-wire-compatibility.md),
[Plan 225](225-make-read-model-query-inputs-and-results-checked-mapped-types.md), and
[Plan 226](226-derive-projection-mapped-consumers-from-authoritative-event-sources.md). It also
assumes MP-34 is complete. Read the final `Keiro.Dsl.SemanticImpact`,
`StructuralConformance`, `MappedDiff`, scaffold report, and snapshot types before implementation.
If their interfaces differ from the sketches here, update this plan and extend them in place.

MP-34 Plan 217 establishes explicit aggregate consumers from `TypeGraph.UseSite`; Plan 218 moves
declaration-wide laws into one context structural module and retains aggregate-use evidence; Plan
221 persists `SemanticImpactSnapshot` and appends semantic impact to diff/scaffold reports. This
plan generalizes those landed types after the new explicit roots and derived projection relations
exist.

`keiro-dsl/src/Keiro/Dsl/Coverage.hs` currently separates private-event and snapshot-register
coverage and labels queues unsupported. Read-model queries and projection consumers were not part
of its old inventory. `MappedDiff.hs` emits recursive declaration findings with complete
`UsePath`s, while `Diff.hs` maps old root constructors to compatibility vectors. Every exhaustive
pattern match over `UseSite`, consumer identities, root surface, or report JSON must be found and
migrated.

`ScaffoldRecord.hs` and `WorkspaceRecord.hs` use extension-tolerant line-oriented records. MP-34
adds semantic-impact snapshots. `DiffReport.hs` owns `keiro-dsl/diff-report/1`; unknown JSON object
keys are append-compatible. `ServiceHarness.hs` and `ConformancePackage.hs` route one service
facade into a generated test component.

[ADR 0012](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
requires exhaustive type folds and one schema authority. [ADR 0013](../adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md)
requires named surface-specific evidence. [ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
governs compatibility boundaries. [ADR 0015](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
and [ADR 0022](../adr/0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md)
govern attributable, additive history. [ADR 0020](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md)
governs the service gate. No cross-repository ADR defines these report schemas.


## Plan of Work

Milestone 1 extends `SemanticImpact` with typed consumers for aggregates, workqueues, read-model
query positions, and projections. Explicit roots come from `TypeGraph`; derived projection
consumers join only through Plan 226. Retain the service declaration inventory independently.
Public projections return ordered sets/maps and every constructor is exhaustively handled under
`-Werror=incomplete-patterns`.

Extend `SemanticImpactSnapshot` with tagged consumer identities and root/surface facts sufficient
to compare removed consumers. Use an additive schema representation that old readers ignore and
new readers validate strictly for duplicate/unknown known tags. If MP-34's initial snapshot format
cannot safely add tags, add a versioned new row while continuing to parse the old row; never change
old bytes in place. A missing or old aggregate-only snapshot renders external baseline unavailable.

Milestone 2 updates context structural conformance and the service facade. Declaration-wide shape,
binding, canonical, fixture, branch, opaque-boundary, and projection-witness laws remain exactly
once regardless of consumer count. Queue modules add queue-specific envelope/field roundtrip facts.
Read-model query modules add type/import/signature inventory facts; their compiled query fixture is
the real type gate. Projection catalog conformance compares derived consumers, generated typed
source views, codec fingerprints, groups, and targets. No harness repeats declaration fixtures.

Generate stable evidence keys containing surface, consumer, root position, and mapped path. The
service facade verifies exact set equality: missing, duplicate, stale, or misattributed evidence
fails. Add restoring mutations for each consumer-specific layer while retaining MP-34 binding and
fixture mutations at service scope.

Milestone 3 migrates coverage and evolution. Coverage gains separate queue persisted roots,
read-model query compile roots, projection typed consumers, and heterogeneous projection
boundaries. Structural/opaque/Json modes remain named per applicable surface; no global percentage
is introduced.

Map each `UsePath`/derived relation to an explicit compatibility consequence record. Aggregate
command/event/register meanings remain unchanged. Queue roots set queued-history and producer/
consumer build consequences. Query roots set query input/result API and caller build consequences.
Projection consumers add handler build/review and, only when replayable, catalog source/rebuild
fingerprint consequences. Operational target/read-model observers are reported separately and do
not become persisted schema changes.

Append these typed dimensions to diff text/JSON and scaffold reports. Update single/workspace
ledgers with the complete snapshot. A source-only move, generated template drift, or changed file
disposition must never create semantic impact. Existing compatibility vector and gate fields retain
their exact meaning and ordering.

Milestone 4 constructs one old/new matrix covering direct/nested/shared/unused declarations across
all surfaces. Mutate or remove every root kind and derived relation, then assert the intended
finding disappears or changes so the guard is live. Test old aggregate-only snapshots, no snapshot,
unknown future tags/fields, corrupt known rows, reordered declarations/members, and workspace
ownership moves. Amend ADR 0012/0013/0004 and ledger ADRs with final durable surface semantics.


## Concrete Steps

Work from the repository root and inventory every exhaustive consumer:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
mori registry show shinzui/keiro --full
rg -n 'UseSite|MappedConsumer|MappedRoot|SemanticImpact|CoverageSurface|CompatibilityVector' \
  keiro-dsl/src keiro-dsl/test
rg -n 'semantic-impact|diff-report/1|ScaffoldReport|WorkspaceScaffoldReport|ServiceHarness' \
  keiro-dsl/src keiro-dsl/test
```

Run focused model, conformance, report, and ledger tests:

```bash
cabal test keiro-dsl:keiro-dsl-test --test-option=--match --test-option='complete mapped surfaces'
cabal test keiro-dsl:keiro-dsl-test --test-option=--match --test-option='mapped surface ledger'
cabal test keiro-dsl:keiro-dsl-test --test-option=--match --test-option='mapped compatibility vectors'
bash keiro-dsl/test/diff-test.sh
bash keiro-dsl/test/structural-mutation-test.sh
```

Before closure, run:

```bash
cabal build all
cabal test keiro-dsl:tests
cabal run -v0 keiro-dsl-corpus-regen -- check
scripts/check-conformance-corpus.sh
just check-adr
git diff --check
git status --short
```

The focused matrix must print distinct queue, query, projection, event, and snapshot dimensions and
must never name an unrelated consumer.


## Validation and Acceptance

For each mapped declaration, semantic impact returns the exact explicit roots and derived consumers
from old and new graphs. An A-only event type names A plus A's projection consumers; an A-only
queue type names that queue; a query-only type names its read models and positions. A shared type
names the union, an unused declaration names only service structural conformance, and unrelated
consumers never appear.

Conformance contains each declaration-wide law once and each consumer-use evidence key once.
Removing a binding fixture fails service structural conformance. Removing a queue codec field,
query type import/signature, or projection source/fingerprint fact fails only the corresponding
surface evidence. Mutation scripts restore exact bytes.

Compatibility vectors distinguish event history, snapshot cache, queued-job history, query API,
and projection rebuild/handler review. A queue mapping change does not trigger aggregate replay;
a query type change does not trigger table migration; a command-only mapping does not trigger
projection impact. Existing event/register classifications remain unchanged.

Current ledgers produce exact before/after consumers. Legacy or missing snapshots say baseline
unavailable. Unknown future fields/tags remain compatible; malformed known facts refuse before
writes. Reports are deterministic under declaration/member reordering and source-only movement is
semantically neutral. Full tests, corpus check, mutations, ADR validation, and diff hygiene pass.


## Idempotence and Recovery

All impact, coverage, compatibility, evidence, and snapshot projections are pure. Ledger parsing
and complete conformance/scaffold preflight occur before writes. Repeating a successful operation
produces identical ordering, JSON, text, and rows.

Never recover missing history by parsing generated Haskell, report prose, or filenames. Do not
collapse a new consequence into an old boolean because downstream code already recognizes it.
When a legacy baseline is absent, establish one through an accepted scaffold or compare source
history explicitly. Corrupt known rows remain a hard refusal with the prior files intact.


## Interfaces and Dependencies

No new dependency. Extend MP-34's public types rather than replacing them. The final information
boundary must be equivalent to:

```haskell
data MappedConsumer
  = AggregateConsumer Name
  | WorkqueueConsumer Name
  | ReadModelQueryConsumer Name QueryPosition
  | ProjectionConsumer ProjectionConsumerId

data MappedConsequence
  = ConsumerBuild
  | PrivateEventHistory
  | SnapshotHydration
  | WorkqueueHistory Name
  | QueryApi Name QueryPosition
  | ProjectionHandlerReview ProjectionConsumerId
  | ProjectionRebuild ProjectionConsumerId Name

data SemanticImpact = SemanticImpact
  { roots :: ![MappedRoot]
  , consumersByDeclaration :: !(Map MappedKey (Set MappedConsumer))
  , consequencesByDeclaration :: !(Map MappedKey (Set MappedConsequence))
  , serviceDeclarations :: !(Set MappedKey)
  }
```

The actual model may normalize roots and derived relations differently, but it must preserve every
typed dimension above, complete paths, deterministic ordering, and the declaration-wide service
inventory. Reports and ledgers serialize this authority; they do not recalculate it.
