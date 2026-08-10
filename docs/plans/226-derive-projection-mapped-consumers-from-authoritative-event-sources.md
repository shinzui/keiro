---
id: 226
slug: derive-projection-mapped-consumers-from-authoritative-event-sources
title: "Derive projection mapped consumers from authoritative event sources"
kind: exec-plan
created_at: 2026-08-09T20:45:31Z
intention: "intention_01kzkzswbae5dan7x42gx8fv1c"
master_plan: "docs/masterplans/35-make-mapped-types-first-class-across-queues-read-models-and-projections-before-fleet-adoption.md"
---

# Derive projection mapped consumers from authoritative event sources

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, Keiro can answer which projection handlers consume a changed mapped event type
without asking authors to declare that type twice. Aggregate inline projections inherit their
aggregate's private-event mapped roots. Projection-catalog owners with
`source = aggregate <Name>` inherit the same event roots and, where replayable, the authoritative
aggregate codec identity. Diff and scaffold output can therefore name the exact handlers, rebuild
groups, targets, and observing read models affected by an event mapping change.

This plan adds no source syntax and generates no arbitrary conversion. Command-only and
register-only mappings are not projection inputs. Category and all-history catalog sources remain
heterogeneous `RecordedEvent` decoder boundaries and receive no fabricated mapped type. Projection
SQL, row codecs, target schemas, and live/replay handler bodies remain application-owned; Keiro
reports review/rebuild impact without asserting that a mapped event change necessarily changes a
table schema.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1: define one deterministic projection-source dependency projection over the
  checked service and MP-34 semantic impact.
- [x] Milestone 2: connect aggregate inline and catalog aggregate owners to exact mapped event
  paths, handlers, groups, targets, and query-model observers.
- [x] Milestone 3: integrate derived projection dependencies with generated catalog codec/fingerprint
  assembly and source-aware evolution findings.
- [x] Milestone 4: prove local projection impact and unsupported heterogeneous boundaries with
  compiled fixtures, restoring mutations, ADR/docs, and full validation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The historical aggregate catalog source fingerprint was a literal
  `aggregate:<Name>/generated-codec/v1`. Preserving that exact text for aggregates without mapped
  event roots kept all unrelated candidate fixtures byte-stable while allowing mapped-event
  authorities to append a deterministic path/wire digest.
- Expanding the compiled catalog fixture with a live-only aggregate source exposed an unused
  generated codec import under `-Werror`. Codec imports are required only for replayable aggregate
  owners; live-only owners need the generated event domain but no replay codec.
- The existing projection-catalog conformance fixture already compiled aggregate, catalog,
  query-model, and handler seams. Extending it to two aggregates provided stronger integrated
  evidence than introducing a parallel synthetic component.


## Decision Log

Record every decision made while working on the plan.

- Decision: Derive projection dependencies only from private-event roots of an authoritative
  aggregate source.
  Rationale: Projection handlers receive events. Commands and register caches are not handler
  inputs merely because they belong to the same aggregate.
  Date: 2026-08-09

- Decision: Keep projection dependencies as relations over `SemanticImpact`, not new `UseSite`
  constructors containing copied mapped keys.
  Rationale: The mapped type is explicitly used by an event field; the projection consumes that
  already-typed event union. Copying roots into `TypeGraph` would duplicate source authority and
  complicate recursive path identity.
  Date: 2026-08-09

- Decision: Model target/read-model effects separately from typed mapped consumers.
  Rationale: A handler writes declared targets and query models observe them, but unrestricted SQL
  prevents static proof that one mapped field determines one column. The relationship supports
  operational review/rebuild reporting, not a query API or migration claim.
  Date: 2026-08-09

- Decision: Leave category/all owners outside mapped coverage.
  Rationale: They decode a heterogeneous recorded-event stream through an application-owned total
  relevance/decoder function. Naming one mapped declaration would be false evidence.
  Date: 2026-08-09

- Decision: Reuse the aggregate codec and fingerprint in replayable catalog owners.
  Rationale: The generated event stream is the single historical wire authority. A projection
  replay adapter must not carry a copied codec identity that can drift.
  Date: 2026-08-09

- Decision: Preserve the released aggregate-source fingerprint byte when no mapped private-event
  root exists, and append a digest of sorted complete event paths plus transitive wire identities
  otherwise.
  Rationale: Existing catalogs remain source-stable while mapped event evolution becomes visible
  to generated runtime assembly without admitting command, register, queue, or query roots.
  Date: 2026-08-10

- Decision: Emit projection mapped impact as a distinct scaffold section on standalone and
  workspace runs, even when no mapping drift occurred in that invocation.
  Rationale: The checked typed/operational relation is current service inventory, while mapping
  drift is historical evidence. Hiding the relation behind a drift gate would make first-run and
  steady-state review incomplete.
  Date: 2026-08-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

The implementation now derives projection consumers from complete private-event paths through one
`ProjectionMappedImpact` projection. It separates typed inline/catalog consumers from groups,
targets, observing read models, replay policy, source fingerprints, and explicit unsupported
category/all boundaries. Generated aggregate catalog sources incorporate mapped event wire
authority; diff preserves the original event finding and adds exact projection build findings;
catalog replay impact includes only affected replayable owners.

The expanded committed fixture contains an Orders-only payload, a shared Orders/Shipments payload,
one inline projection, replayable and live-only aggregate owners in disjoint groups, observing
query models, and a category decoder. Its aggregate codecs, inline/catalog handlers, query models,
structural conformance, and catalog runtime all compile and execute. The 653-example DSL suite,
every compiled `keiro-dsl` test component, `cabal build all`, the shell diff harness, Nix
formatting, ADR validation, and diff hygiene pass. The plan's documented `just check-adr` spelling
was stale; the repository's current equivalent is `just adr-validate`.


## Context and Orientation

This plan hard-depends on
[Plan 223](223-register-the-mapped-consumer-surface-contract-in-candidate-language-5.md) and the
completed MP-34. Plan 223 freezes projection typing as derived. MP-34 supplies the checked mapping
from aggregate event roots to declaration closures. Read those final interfaces before editing and
represent projection dependencies as an extension/projection of them.

`Grammar.Aggregate` has `aggProjection :: Maybe ProjectionSpec`. `ProjectionSpec` names a read
model/table, consistency, aggregate field key, and optional event-to-status map. In
`Scaffold.emitProjection`, the generated apply hole has the type
`<Aggregate>Event -> recorded -> txn ()`; it therefore consumes the aggregate event union even
though the projection clause contains no `TypeExpr`.

Candidate-language-5 projection catalogs are represented by `ProjectionOwnerNode`. A
`CatalogAggregate aggregateName` source uses `<Aggregate>Event` and the generated validated event
stream. A `CatalogCategory` or `CatalogAll` source creates an application-owned event type and total
decoder/relevance hole. `poFeed`, `poGroup`, `poTargets`, and `poReplay` connect the owner to live
and rebuild behavior. `ReadModelNode.rmGroup/rmObservedTargets` says which query models observe a
group's targets.

`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` emits the context-level projection catalog and create-once
`ProjectionCatalogHoles`. `keiro-dsl/src/Keiro/Dsl/Diff.hs` already classifies catalog source,
handler order, group/target, feed identity, and replay policy changes. Runtime
`Keiro.Projection.Catalog` and the replay runner use catalog and source/codec fingerprints.
This plan connects mapped-event evolution to those existing typed identities; it does not create a
second catalog.

[ADR 0026](../adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md)
is normative for source typing, target ownership, closed-world validation, and the unchecked SQL
boundary. [ADR 0012](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
defines mapped event wire authority. [ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
separates event compatibility from projection runtime/rebuild evidence.
[ADR 0020](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md) requires
the derived inventory to execute through one service facade. The motivating external table-owner
decision remains `mori://shinzui/mori/okf/adrs/concepts/ADR-20`; it does not define mapped Haskell
types.


## Plan of Work

Milestone 1 adds a focused pure module, for example
`keiro-dsl/src/Keiro/Dsl/ProjectionMappedImpact.hs`. Its input is the checked `Spec`/service plus
MP-34's `SemanticImpact`; its output contains typed projection consumer identities and separate
operational observer relations. For each aggregate, select only roots whose kind is private event.
Preserve each root's complete `UsePath` and transitive mapped declaration closure.

Represent aggregate inline projections by aggregate and projection/read-model identity. Represent
catalog consumers by projection owner and aggregate source. Sort/deduplicate by stable semantic
identity, not declaration order. A single catalog owner may receive one source by current
validation; keep the relation total if future syntax stores a non-empty collection. Emit an
explicit unsupported boundary for category/all owners in coverage/reporting without associating a
`MappedKey`.

Milestone 2 joins the typed projection consumers to the existing catalog graph. For an inline
aggregate projection, record the referenced read model if declared. For a catalog owner, record its
group and targets, then derive observing read models from matching group plus observed target
intersection. These are operational observers: label them separately from Haskell type consumers
and do not add their query roots unless Plan 225 independently declares the same mapping.

Use the relation in scaffold/Cabal import planning so only a projection owner whose generated
signature/codec needs an aggregate event closure is rebuilt. Do not import structural bindings into
unrelated read-model query modules. Existing aggregate projection holes are create-once and are
never overwritten; reports name required recompilation/review.

Milestone 3 verifies generated catalog assembly consumes the aggregate's one validated event stream
and codec fingerprint. A mapped event wire change must invalidate a replayable owner's source
contract/fingerprint and identify affected rebuild groups. An inline handler or live-only owner
still receives a consumer-build/review finding but does not claim replay capability it lacks.
Deduplicate the derived projection finding with existing catalog source findings while retaining
both event compatibility and projection operational dimensions.

Do not alter the canonical projection catalog fingerprint for a command-only/register-only mapping
or a read-model query-only mapping. Do not add target/schema diff findings unless those declarations
actually changed. Workspace ownership moves with equal semantic sources remain dependency-neutral.

Milestone 4 adds a fixture with Aggregate A and B, A-only and shared mapped event types, one inline
projection, two catalog aggregate owners with different groups, a category owner, and observing
read models. Compile the catalog and handlers. Mutate a mapped event, source aggregate, replay
policy, target observation, and category decoder; assert exact typed/operational consumers and
restoration. Update projection/read-model guidance and amend ADR 0026 only if the durable relation
requires clarification.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
mori registry show shinzui/keiro --full
rg -n 'ProjectionSpec|CatalogAggregate|ownerEventType|poSources|rmObservedTargets|projectionSurface' \
  keiro-dsl/src keiro-dsl/test keiro/src
```

Run focused semantic, diff, and compiled catalog tests:

```bash
cabal test keiro-dsl:keiro-dsl-test --test-option=--match --test-option='mapped projection impact'
cabal test keiro-dsl:keiro-dsl-test --test-option=--match --test-option='projection catalog evolution'
cabal test keiro-dsl:keiro-dsl-conformance-projection-catalog
bash keiro-dsl/test/diff-test.sh
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

Expected A-only output names only A's inline/catalog owners, their exact groups/targets/observers,
and no Aggregate B or heterogeneous category owner.


## Validation and Acceptance

For a mapped type present only in Aggregate A's private event, the result names A's aggregate
inline projection and every catalog owner sourced from A. It names the owners' rebuild groups,
targets, and observing read models in a separate operational relation. Aggregate B, its handlers,
and read models observing disjoint targets are absent.

A command-only or register-only mapped type produces no projection consumer. A type shared by A
and B's events names both real owner sets. A category/all source has an explicit unsupported typed
boundary but no mapped declaration path. No test may make it pass by assigning the category owner a
convenient type manually.

Changing a mapped event's wire authority preserves the existing event compatibility finding and
also invalidates the exact replayable catalog source contracts. Live-only/inline consumers require
build and handler review without a false replay claim. Unchanged projection catalog, target, SQL
schema, query contract, aggregate fold, and snapshot identities remain byte-stable.

Compiled aggregate and catalog fixtures, exact consumer tests, restoring mutations, full DSL tests,
diff/corpus policy, ADR validation, and diff hygiene pass. Existing source syntax and create-once
handler bodies are unchanged.


## Idempotence and Recovery

Projection dependency derivation is pure, closed-world, and deterministic. It reads only the
checked semantic graph and catalog relations; it performs no SQL or replay effects. Repeating
scaffold/diff produces identical consumer ordering and findings.

If a derived relation disagrees with generated catalog assembly, fail preflight as an internal
invariant before writes rather than choosing either inventory. Never repair the mismatch by adding
a manual projection type annotation or scanning handler Haskell/SQL. Existing create-once handlers
remain recoverable application code and are not modified by this plan.


## Interfaces and Dependencies

No new dependency. Reuse MP-34 `SemanticImpact`, the checked projection catalog nodes, and
`containers`. The pure result must be equivalent to:

```haskell
data ProjectionMappedConsumer
  = AggregateInlineProjection
      { aggregate :: !Name
      , projection :: !Name
      }
  | CatalogAggregateProjection
      { owner :: !Name
      , aggregate :: !Name
      }

data ProjectionOperationalImpact = ProjectionOperationalImpact
  { consumer :: !ProjectionMappedConsumer
  , group :: !(Maybe Name)
  , targets :: !(Set Name)
  , readModels :: !(Set Name)
  , replayable :: !Bool
  }

projectionMappedConsumers
  :: CheckedService
  -> SemanticImpact
  -> Map MappedKey (Set ProjectionMappedConsumer)
```

Retain complete inherited root paths in the real type even if this compact sketch omits them.
Category/all unsupported boundaries belong to coverage/report structures and must not be encoded as
a fake `MappedKey`.
